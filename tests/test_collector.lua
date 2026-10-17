local Json = require("src.shared.json")
local Collector = require("src.mission.collector")
local Mock = require("tests.mock_dcs")
local function fixture(config, options)
    local env = Mock.new()
    local unit = env.unit(17, "Blue-1", "Pilot-A")
    local collector = Collector.new(env, Json, { missionSessionId = "mission-a", collectorEpoch = "epoch-1" }, options)
    local function request(op, parameters)
        local req = Json.copy(parameters or {})
        req.protocolVersion = 1; req.requestId = "test-request"; req.op = op
        req.missionSessionId = "mission-a"; req.collectorEpoch = "epoch-1"
        return Json.decode(collector.handleJson(Json.encode(req)))
    end
    local function exchange(options)
        options = options or {}
        return request("exchange", { ackEventSeq = options.ack,
            read = { state = {enabled = options.state ~= false, cursor = options.cursor or Json.null},
                events = {enabled = options.events ~= false, afterSeq = options.after, maxCount = options.maxCount} },
            limits = {maxResponseBytes = options.budget or 262144} })
    end
    -- Existing lifecycle tests deliberately exercise a faster configurable sampler.
    local initialized = request("initialize", {config = config or {revision=1,sampling={aircraftHz=10,missileHz=20}}})
    truth(initialized.ok, initialized.error and initialized.error.code)
    return env, unit, collector, request, exchange, initialized
end
local function entity(response, kind)
    truth(response.ok, response.error and response.error.code)
    for _, record in ipairs(response.data.state.entities) do if record.kind == kind then return record end end
    error("Entity not found: " .. kind)
end

test("default 1 Hz sampling bundles all properties while events capture immediately", function()
    local env, unit, collector, request, exchange, initialized = fixture({revision=1})
    local sampling = initialized.data.acceptedConfig.sampling
    equal(sampling.aircraftHz,1); equal(sampling.missileHz,1); equal(sampling.slowFieldsHz,1)
    local missile = env.missile(88,unit,nil)
    env.emit("SHOT",{initiator=unit,weapon=missile}); env.advance(0.01)
    local aircraftSeq,missileSeq=collector.aircraftSeq,collector.missileSeq
    unit.velocity={x=300,y=0,z=0}; unit.fuel=0.4; unit.ammo[1].count=3
    env.advance(0.8)
    env.emit("HIT",{initiator=unit,weapon=missile,target=unit})
    equal(collector.latestEventSeq,2)
    equal(collector.aircraftSeq,aircraftSeq); equal(collector.missileSeq,missileSeq)
    local before=exchange(); equal(#before.data.eventLog.events,2)
    env.advance(0.21)
    equal(collector.aircraftSeq,aircraftSeq+1); equal(collector.missileSeq,missileSeq+1)
    local response=exchange(); local aircraft=entity(response,"aircraft")
    equal(aircraft.motion.speedMps,300); equal(aircraft.fuel.ratioRaw,0.4)
    equal(aircraft.armament.items[1].count,3); equal(aircraft.occupancy.isPlayer,true)
    equal(aircraft.motion.sampledSimTime,aircraft.fuel.sampledSimTime)
    equal(aircraft.motion.sampledSimTime,aircraft.armament.sampledSimTime)
    equal(entity(response,"missile").launch.launcher.object.entityId,aircraft.entityId)
    equal(response.data.eventLog.events[1].type,"weapon_fired")
end)

test("events are encoded once at capture and reused verbatim on reads until ACK", function()
    local J=assert(loadfile(PROJECT_ROOT .. "/src/shared/json.lua"))()
    local encode,isArray=J.encode,J.isArray
    local encoding,eventTraversals=false,0
    J.encode=function(value,cache)
        encoding=true
        local result=encode(value,cache)
        encoding=false
        return result
    end
    J.isArray=function(value)
        if encoding and type(value)=="table" and value.eventSeq then eventTraversals=eventTraversals+1 end
        return isArray(value)
    end
    local env=Mock.new(); local unit=env.unit(17,'Pilot-"\\-中文',nil)
    local collector=Collector.new(env,J,{missionSessionId="m",collectorEpoch="e"})
    local function request(op,fields)
        fields=fields or {}; fields.protocolVersion=1; fields.requestId="cached"; fields.op=op
        fields.missionSessionId="m"; fields.collectorEpoch="e"
        return J.decode(collector.handleJson(J.encode(fields)))
    end
    truth(request("initialize",{config={revision=1}}).ok)
    env.emit("TAKEOFF",{initiator=unit}); equal(eventTraversals,1)
    local original=collector.events[collector.eventHead].encoded
    equal(#original,collector.eventBytes)
    unit.name="Changed after capture"
    local function pull(ack)
        return request("exchange",{ackEventSeq=ack,read={state={enabled=true,cursor=J.null},
            events={enabled=true,afterSeq=ack or 0,maxCount=128}}})
    end
    for _=1,2 do
        local response=pull(); truth(response.ok)
        equal(encode(response.data.eventLog.events[1]),original)
        equal(eventTraversals,1) -- No recursive event traversal during budget checks/final serialization.
    end
    truth(pull(1).ok); equal(collector.eventBytes,0); equal(collector.events[collector.eventHead],nil)
end)

test("collector initializes idempotently without fabricated birth events", function()
    local env, unit, collector, request, exchange = fixture()
    equal(env.handlerRegistrations, 1); equal(env.scheduleRegistrations, 1)
    equal(entity(exchange(), "aircraft").discovery, "initial_scan")
    equal(collector.latestEventSeq, 0)
    truth(request("initialize", {config=collector.config}).ok)
    equal(env.handlerRegistrations, 1); equal(env.scheduleRegistrations, 1)
    env.emit("BIRTH", {initiator=unit}); env.emit("BIRTH", {initiator=unit})
    equal(collector.latestEventSeq, 1)
end)

test("aircraft exposes speed, fuel, weapons and player identity", function()
    local env, unit, collector, request, exchange = fixture()
    unit.velocity = {x=240,y=70,z=0}; unit.fuel = 1.2; env.advance(0.1)
    local record = entity(exchange(), "aircraft")
    equal(record.motion.speedMps, 250); equal(record.motion.groundSpeedMps, 240)
    -- Fuel refresh is independent of motion; an event marks slow data dirty.
    env.emit("PLAYER_ENTER_UNIT", {initiator=unit}); env.advance(0.05)
    record = entity(exchange(), "aircraft")
    equal(record.fuel.ratioRaw, 1.2); equal(record.fuel.massKgEstimate, Json.null)
    equal(record.fuel.referenceInternalCapacityKg, 3100)
    equal(record.occupancy.isPlayer, true); equal(record.occupancy.playerName, "Pilot-A")
    equal(record.armament.items[1].typeName, "AIM_120C"); equal(record.armament.items[1].count, 4)
end)

test("AI remains false in telemetry AND object references", function()
    local env, unit, collector, request, exchange = fixture()
    unit.playerName = nil; env.advance(1.1)
    local record = entity(exchange(), "aircraft")
    equal(record.occupancy.isPlayer, false); equal(record.occupancy.playerName, Json.null)
    env.emit("TAKEOFF", {initiator=unit})
    equal(exchange().data.eventLog.events[1].actor.isPlayer, false)
end)

test("unavailable fuel/ammo never masquerade as zero or an empty inventory", function()
    local env, unit, collector, request, exchange = fixture()
    unit.errors.getFuel = true; unit.errors.getAmmo = true; env.advance(1.1)
    local record = entity(exchange(), "aircraft")
    equal(record.fuel.status, "stale"); equal(record.fuel.ratioRaw, 0.62); equal(record.fuel.sampledSimTime, 0)
    equal(record.armament.status, "stale"); equal(#record.armament.items, 2)
    unit.errors.getAmmo = nil; unit.ammo = {}; env.advance(1.1)
    record = entity(exchange(), "aircraft"); equal(record.armament.status, "ok"); equal(Json.encode(record.armament.items), "[]")
    unit.ammo = nil; env.advance(1.1)
    equal(entity(exchange(), "aircraft").armament.status, "stale")
    local newUnit = env.unit(18, "NoData", nil); newUnit.errors.getFuel = true; newUnit.ammo = nil
    env.emit("BIRTH", {initiator=newUnit})
    local response = exchange()
    for _, candidate in ipairs(response.data.state.entities) do
        if candidate.identity.unitName == "NoData" then
            equal(candidate.fuel.status, "unavailable"); equal(candidate.fuel.ratioRaw, Json.null)
            equal(candidate.armament.items, Json.null); equal(candidate.occupancy.isPlayer, false)
        end
    end
end)

test("ammo preserves counts and separates unknown types with equal display names", function()
    local env, unit, collector, request, exchange = fixture()
    unit.ammo = { {count=2,desc={displayName="Same",category=1}}, {count=3,desc={displayName="Same",category=1}},
        {count=80,desc={displayName="Gun",category=0,wsType={4,6,7,8}}} }
    env.advance(1.1)
    local items = entity(exchange(), "aircraft").armament.items
    equal(#items, 3); truth(items[1].weaponKey ~= items[2].weaponKey)
    equal(items[3].count, 80); equal(items[3].identification, "ws_type")
end)

test("each missile freezes the launcher and firing-time player, including out-of-scope target refs", function()
    local env, unit, collector, request, exchange = fixture()
    local target = env.unit(23, "Red-1", "Pilot-B"); target.side = 1
    unit.playerName = "Pilot-At-Launch"
    local missile = env.missile(88, unit, target)
    env.emit("SHOT", {initiator=unit,weapon=missile})
    local record = entity(exchange(), "missile")
    equal(record.launch.launcher.object.name, "Blue-1")
    equal(record.launch.launcher.object.playerName, "Pilot-At-Launch")
    equal(record.targetObservation.object.name, "Red-1")
    equal(record.launch.initialTarget.object.playerName, "Pilot-B")
    unit.playerName = "Different-Player"; env.advance(1.1)
    record = entity(exchange(), "missile")
    equal(record.launch.launcher.object.playerName, "Pilot-At-Launch")
    local second = env.missile(89, unit, target); env.emit("SHOT", {initiator=unit,weapon=second})
    local ids = {}; for _, item in ipairs(exchange().data.state.entities) do if item.kind == "missile" then ids[item.entityId] = true end end
    local n = 0; for _ in pairs(ids) do n = n + 1 end; equal(n, 2)
end)

test("target observations distinguish object, no report, failure and retained history", function()
    local env, unit, collector, request, exchange = fixture()
    local target = env.unit(23, "Target", "Pilot-B")
    local missile = env.missile(88, unit, target); env.emit("SHOT", {initiator=unit,weapon=missile})
    missile.target = nil; env.advance(0.1)
    local record = entity(exchange(), "missile")
    equal(record.targetObservation.status, "none_reported"); equal(record.targetObservation.object, Json.null)
    equal(record.lastKnownTarget.object.name, "Target")
    missile.errors.getTarget = true; env.advance(0.1)
    record = entity(exchange(), "missile")
    equal(record.targetObservation.status, "stale"); equal(record.targetObservation.lastSuccessfulStatus, "none_reported")
    equal(record.targetObservation.object, Json.null)
    missile.errors.getTarget = nil; missile.target = target; env.advance(0.1)
    equal(entity(exchange(), "missile").targetObservation.status, "object")
    local n = 0; for _, event in ipairs(exchange().data.eventLog.events) do if event.type == "target_observation_changed" then n = n + 1 end end
    equal(n, 2)
end)

test("launcher fallback and conflicts are explicit, not guessed", function()
    local env, unit, collector, request, exchange = fixture()
    local other = env.unit(19, "Other", nil)
    local missile = env.missile(88, unit, nil); env.emit("SHOT", {weapon=missile})
    equal(entity(exchange(), "missile").launch.launcher.source, "weapon_getLauncher")
    local conflicting = env.missile(89, other, nil); env.emit("SHOT", {initiator=unit,weapon=conflicting})
    local found = false
    for _, item in ipairs(exchange().data.state.entities) do
        if item.kind == "missile" and item.launch.launcher.status == "conflict" then
            equal(item.launch.launcher.object.name, "Blue-1"); equal(item.launch.launcher.alternateObject.name, "Other"); found = true
        end
    end
    truth(found); equal(collector.incompleteLauncherCount, 1)
end)

test("short-lived missile retains launch and end even without an intervening read", function()
    local env, unit, collector, request, exchange = fixture()
    local missile = env.missile(88, unit, nil); env.emit("SHOT", {initiator=unit,weapon=missile})
    missile.exists = false; env.advance(0.1)
    local response = exchange(); equal(#response.data.eventLog.events, 2)
    equal(response.data.eventLog.events[1].type, "weapon_fired")
    local ended = response.data.eventLog.events[2]
    equal(ended.type, "weapon_track_ended"); equal(ended.details.reason, "object_gone")
    equal(ended.details.launch.launcher.object.playerName, "Pilot-A")
    equal(#response.data.state.entities, 1)
end)

test("read is non-destructive and ACK is bounded, scoped, repeatable and validated before mutation", function()
    local env, unit, collector, request, exchange = fixture()
    env.emit("TAKEOFF", {initiator=unit}); env.emit("LAND", {initiator=unit})
    equal(exchange({ack=1}).error.code, "INVALID_ACK")
    equal(exchange().data.eventLog.throughSeq, 2); equal(exchange().data.eventLog.throughSeq, 2)
    equal(exchange({ack=2,after=1}).error.code, "CURSOR_BEFORE_ACK"); equal(collector.ackEventSeq, 0)
    truth(exchange({ack=1,after=1}).ok); equal(collector.ackEventSeq, 1)
    truth(exchange({ack=1,after=1}).ok)
    local old = {protocolVersion=1,requestId="old",op="exchange",missionSessionId="mission-a",collectorEpoch="old",ackEventSeq=2}
    equal(collector.request(old).error.code, "EPOCH_MISMATCH"); equal(collector.ackEventSeq, 1)
    truth(exchange({ack=2,after=2}).ok); equal(collector.eventBytes, 0)
    equal(exchange({after=0}).error.code, "CURSOR_BEFORE_ACK")
end)

test("bounded log reports a contiguous loss prefix and can ACK across a recorded gap", function()
    local env, unit, collector, request, exchange = fixture({revision=1,eventBuffer={maxCount=2,maxBytes=16777216}})
    for _ = 1, 5 do env.emit("TAKEOFF", {initiator=unit}) end
    local batch = exchange({maxCount=1}).data.eventLog
    equal(batch.throughSeq, 3); equal(batch.gaps[1].fromSeq, 1); equal(batch.gaps[1].toSeq, 3)
    equal(#batch.events, 0); equal(batch.hasMore, true); equal(collector.droppedEventCount, 3)
    local response = exchange({ack=3,after=3,maxCount=1})
    equal(response.data.eventLog.throughSeq, 4); equal(response.data.eventLog.events[1].eventSeq, 4)
    equal(response.data.health.gapRangeCount, 0)
end)

test("byte-limit overflow and callback errors are different kinds of loss", function()
    local env, unit, collector, request, exchange = fixture({revision=1,eventBuffer={maxCount=100,maxBytes=1}})
    env.emit("TAKEOFF", {initiator=unit})
    local response = exchange(); equal(response.data.eventLog.gaps[1].toSeq, 1)
    equal(#response.data.eventLog.events, 0); equal(collector.latestEventSeq, 1)
    collector.onEvent(nil); equal(collector.captureErrorCount, 1); equal(collector.latestEventSeq, 1)
    truth(exchange().data.health.captureErrorCount > 0)
end)

test("same name and reused DCS ID allocate a new lifetime", function()
    local env, unit, collector, request, exchange = fixture()
    local first = entity(exchange(), "aircraft").entityId
    unit.exists = false
    local replacement = env.unit(17, "Blue-1", "Replacement")
    env.emit("BIRTH", {initiator=replacement})
    local record = entity(exchange(), "aircraft")
    truth(record.entityId ~= first); equal(record.occupancy.playerName, "Replacement")
end)

test("oversized event is explicit loss and cannot block the next event",function()
    local env,unit,c,request,exchange=fixture()
    unit.name=string.rep("x",40000);env.emit("TAKEOFF",{initiator=unit})
    unit.name="normal";env.emit("TAKEOFF",{initiator=unit})
    local r=exchange({state=false});truth(r.ok)
    equal(r.data.eventLog.throughSeq,2);equal(r.data.eventLog.events[1].type,"capture_record_rejected")
    equal(r.data.eventLog.events[2].type,"takeoff");equal(r.data.health.rejectedRecordCount,1)
    equal(r.data.health.captureContinuous,false)
    truth(exchange({ack=2,after=2}).ok);equal(c.eventBytes,0)
end)

test("oversized entity is excluded explicitly while healthy entities and events continue",function()
    local env,unit,c,request,exchange=fixture()
    local huge=env.unit(999,string.rep("x",40000),nil);env.emit("BIRTH",{initiator=huge})
    env.emit("TAKEOFF",{initiator=unit})
    local r=exchange();truth(r.ok);equal(#r.data.state.entities,1)
    equal(r.data.state.coverage.excludedEntityCount,1)
    equal(r.data.state.coverage.excludedEntities[1].reason,"record_too_large")
    equal(r.data.eventLog.throughSeq,2)
end)

test("snapshot pages are frozen and stale cursors do not mutate an ACK", function()
    local env, unit, collector, request, exchange = fixture()
    for index = 100, 159 do local extra = env.unit(index, "Extra-" .. index, nil); env.emit("BIRTH", {initiator=extra}) end
    local first = exchange({budget=65536}).data.state
    truth(first.pageCount > 1); local cursor = first.nextCursor
    unit.fuel = 0.1; env.advance(1.1)
    local nextPage = exchange({cursor=cursor,budget=65536})
    truth(nextPage.ok); equal(nextPage.data.state.snapshotId, first.snapshotId)
    equal(nextPage.data.state.eventSeqAtCapture, first.eventSeqAtCapture)
    local raw = Json.encode(nextPage); truth(#raw <= 65536)
    truth(exchange({budget=65536}).ok)
    equal(exchange({cursor=cursor,ack=1,budget=65536}).error.code, "STALE_CURSOR")
    equal(collector.ackEventSeq, 0)
end)

test("configure is versioned, idempotent and preserves event history", function()
    local env, unit, collector, request, exchange, initial = fixture()
    env.emit("TAKEOFF", {initiator=unit}); local oldCursor = exchange({budget=65536}).data.state.nextCursor
    local config = Json.copy(initial.data.acceptedConfig); config.revision = 2; config.scope.coalitions = Json.array({"red"})
    truth(request("configure", {baseRevision=1,config=config}).ok)
    equal(collector.latestEventSeq, 1); equal(#exchange().data.state.entities, 0)
    truth(request("configure", {baseRevision=1,config=config}).ok)
    equal(collector.scopeRevision, 2)
    config.revision = 3
    equal(request("configure", {baseRevision=1,config=config}).error.code, "CONFIG_CONFLICT")
end)

test("shutdown stops callbacks/timers but retains readable and confirmable events", function()
    local env, unit, collector, request, exchange = fixture()
    local missile = env.missile(88, unit, nil); env.emit("SHOT", {initiator=unit,weapon=missile})
    local stopped = request("shutdown"); truth(stopped.ok); equal(stopped.data.status, "stopped")
    equal(next(env.handlers), nil); equal(next(env.timers), nil)
    equal(request("shutdown").data.latestEventSeq, stopped.data.latestEventSeq)
    local response = exchange(); equal(response.data.status, "stopped")
    truth(exchange({ack=response.data.eventLog.throughSeq,after=response.data.eventLog.throughSeq}).ok)
    equal(collector.eventBytes, 0)
end)

test("reused missile ID cannot suppress a new launch before the next sample", function()
    local env, unit, collector, request, exchange = fixture()
    local first = env.missile(88, unit, nil); env.emit("SHOT", {initiator=unit,weapon=first})
    local oldId = entity(exchange(), "missile").entityId
    first.exists = false
    local second = env.missile(88, unit, nil); env.emit("SHOT", {initiator=unit,weapon=second})
    local record = entity(exchange(), "missile")
    truth(record.entityId ~= oldId)
    local fired = 0; for _, event in ipairs(exchange().data.eventLog.events) do if event.type == "weapon_fired" then fired=fired+1 end end
    equal(fired,2)
end)

test("log compaction preserves overflow gaps and exact ACK cleanup", function()
    local env, unit, collector, request, exchange = fixture({revision=1,eventBuffer={maxCount=2,maxBytes=16777216}})
    for _=1,4200 do env.emit("TAKEOFF",{initiator=unit}) end
    local response=exchange()
    equal(response.data.eventLog.gaps[1].toSeq,4198)
    equal(response.data.eventLog.events[1].eventSeq,4199)
    equal(response.data.eventLog.events[2].eventSeq,4200)
    truth(exchange({ack=4200,after=4200}).ok)
    equal(collector.eventBytes,0); equal(exchange().data.health.eventBufferCount,0)
end)

test("a frozen later page retains its data after live sampling changes", function()
    local env, unit, collector, request, exchange = fixture()
    local extras={}
    for id=100,179 do
        local extra=env.unit(id,"Extra-"..id,nil); extras[#extras+1]=extra; env.emit("BIRTH",{initiator=extra})
    end
    local response=exchange({budget=65536,events=false})
    truth(response.data.state.pageCount>1)
    local firstPage=response.data.state
    for _, extra in ipairs(extras) do extra.fuel=0.1 end
    env.advance(1.1)
    local cursor,checked=firstPage.nextCursor,0
    while cursor~=Json.null do
        local page=exchange({budget=65536,events=false,cursor=cursor}).data.state
        for _, record in ipairs(page.entities) do equal(record.fuel.ratioRaw,0.62); checked=checked+1 end
        cursor=page.nextCursor
    end
    truth(checked>0)
end)

test("non-aircraft targets are identifiable without becoming aircraft telemetry", function()
    local env, unit, collector, request, exchange = fixture()
    local ground=env.unit(45,"SAM-Target",nil,env.Unit.Category.GROUND_UNIT)
    local missile=env.missile(88,unit,ground); env.emit("SHOT",{initiator=unit,weapon=missile})
    local response=exchange()
    equal(entity(response,"missile").targetObservation.object.kind,"ground_unit")
    equal(entity(response,"missile").targetObservation.object.name,"SAM-Target")
    equal(#response.data.state.entities,2)
end)

test("partial object API failures are isolated and do not fabricate an AI or target", function()
    local env, unit, collector, request, exchange = fixture()
    unit.errors.getPlayerName=true
    local missile=env.missile(88,unit,nil); missile.errors.getTarget=true
    env.emit("SHOT",{initiator=unit,weapon=missile})
    local record=entity(exchange(),"missile")
    equal(record.launch.launcher.object.occupancyStatus,"stale")
    equal(record.targetObservation.status,"unavailable"); equal(record.targetObservation.object,Json.null)
    equal(exchange().data.status,"degraded")
end)

test("unknown and malformed protocol operations cannot mutate state", function()
    local env, unit, collector, request, exchange = fixture()
    equal(request("exec",{code="error('must never run')"}).error.code,"INVALID_REQUEST")
    local malformed=Json.decode(collector.handleJson('{"protocolVersion":1,}'))
    equal(malformed.error.code,"INVALID_REQUEST"); equal(collector.ackEventSeq,0)
    equal(request("initialize",{config={revision=1,sampling={missileHz=0}}}).error.code,"INVALID_REQUEST")
    equal(env.scheduleRegistrations,1)
end)

test("target respawn with reused ID gets a new identity before its birth is observed",function()
    local env,unit,collector,request,exchange=fixture()
    local old=env.unit(23,"Old-Target","Old-Pilot"); env.emit("BIRTH",{initiator=old})
    local missile=env.missile(88,unit,old); env.emit("SHOT",{initiator=unit,weapon=missile})
    env.advance(0.1)
    local oldId=entity(exchange(),"missile").targetObservation.object.entityId
    old.exists=false
    local replacement=env.unit(23,"Replacement-Target","New-Pilot")
    missile.target=replacement; env.advance(0.05)
    local ref=entity(exchange(),"missile").targetObservation.object
    truth(ref.entityId~=oldId); equal(ref.name,"Replacement-Target")
end)

test("non-finite derived speed is reported as unknown, not invalid JSON",function()
    local env,unit,collector,request,exchange=fixture()
    unit.velocity={x=1e308,y=1e308,z=0}; env.advance(0.1)
    local motion=entity(exchange(),"aircraft").motion
    equal(motion.speedMps,Json.null); equal(motion.groundSpeedMps,Json.null); equal(motion.status,"partial")
end)

test("fresh DCS target wrappers resolve through native id_ without inventing target changes",function()
    local env,unit,collector,request,exchange=fixture()
    local victim=env.unit(23,"Target","Target-Pilot"); victim.id_=100023
    env.emit("BIRTH",{initiator=victim})
    local missile=env.missile(88,unit,victim); missile.id_=200088
    missile.getTarget=function()
        return setmetatable({id_=victim.id_},{__index=function(_,key)
            if key=="getID" then return nil end
            return victim[key]
        end})
    end
    env.emit("SHOT",{initiator=unit,weapon=missile})
    local before=entity(exchange(),"missile").targetObservation.object
    local objectCount=collector.objectCount
    for _=1,40 do env.advance(0.05) end
    local response=exchange(); local after=entity(response,"missile").targetObservation.object
    equal(after.entityId,before.entityId); equal(after.runtimeObjectId,"100023")
    equal(after.dcsObjectId,"23"); equal(collector.objectCount,objectCount)
    for _,event in ipairs(response.data.eventLog.events) do truth(event.type~="target_observation_changed") end
end)

test("anonymous target wrappers cannot grow the registry or spam target changes",function()
    local env,unit,collector,request,exchange=fixture()
    local missile=env.missile(88,unit,nil)
    missile.getTarget=function() return {id_=0} end
    env.emit("SHOT",{initiator=unit,weapon=missile})
    local objectCount=collector.objectCount
    for _=1,100 do env.advance(0.05) end
    local response=exchange()
    equal(collector.objectCount,objectCount); equal(collector.latestEventSeq,1)
    equal(entity(response,"missile").targetObservation.object.entityId,Json.null)
end)

test("a weapon target is not classified using colliding Unit category numbers",function()
    local env,unit,collector,request,exchange=fixture()
    local weaponTarget=env.missile(99,unit,nil); weaponTarget.id_=200099
    local missile=env.missile(88,unit,weaponTarget); env.emit("SHOT",{initiator=unit,weapon=missile})
    local target=entity(exchange(),"missile").targetObservation.object
    equal(target.kind,"missile"); equal(target.runtimeObjectId,"200099")
end)

test("dead target wrappers and late events retain the retired aircraft identity",function()
    local env,unit,collector,request,exchange=fixture()
    local victim=env.unit(23,"Target","Target-Pilot"); victim.id_=100023
    env.emit("BIRTH",{initiator=victim})
    local missile=env.missile(88,unit,victim); env.emit("SHOT",{initiator=unit,weapon=missile})
    local original=entity(exchange(),"missile").targetObservation.object.entityId
    victim.exists=false
    victim.errors.getName=true; victim.errors.getTypeName=true; victim.errors.getID=true
    missile.getTarget=function() return {id_=100023,isExist=function() return false end} end
    for _=1,120 do env.advance(0.05) end -- Includes a reconciliation sweep.
    env.emit("KILL",{initiator=unit,target=victim,weapon=missile})
    env.emit("UNIT_LOST",{initiator=victim})
    local response=exchange(); local ref=entity(response,"missile").targetObservation.object
    equal(ref.entityId,original); equal(ref.name,"Target"); equal(ref.dcsObjectId,"23")
    equal(ref.occupancyStatus,"stale"); equal(collector.captureErrorCount,0)
    for _,event in ipairs(response.data.eventLog.events) do
        truth(event.type~="target_observation_changed")
        if event.type=="kill" then equal(event.target.entityId,original) end
        if event.type=="unit_lost" then equal(event.actor.entityId,original) end
    end
end)

test("live replacement gets a new identity while delayed dead refs keep the old one",function()
    local env,unit,collector,request,exchange=fixture()
    local victim=env.unit(23,"Old-Target",nil); victim.id_=100023
    env.emit("BIRTH",{initiator=victim})
    local missile=env.missile(88,unit,victim); env.emit("SHOT",{initiator=unit,weapon=missile})
    local original=entity(exchange(),"missile").targetObservation.object.entityId
    victim.exists=false; env.advance(0.1)
    local replacement=env.unit(23,"New-Target",nil); replacement.id_=100023
    missile.target=replacement; env.advance(0.05)
    local newId=entity(exchange(),"missile").targetObservation.object.entityId
    truth(newId~=original)
    env.emit("KILL",{initiator=unit,target=victim})
    local response=exchange(); equal(response.data.eventLog.events[#response.data.eventLog.events].target.entityId,original)
    equal(entity(response,"missile").targetObservation.object.entityId,newId)
end)

test("retired identity history is bounded and unknown dead references cannot allocate entities",function()
    local env,unit,collector,request,exchange=fixture(nil,{maxRetiredObjects=2})
    local first
    for index=1,5 do
        local victim=env.unit(100+index,"Target-"..index,nil); victim.id_=100000+index
        first=first or victim
        env.emit("BIRTH",{initiator=victim}); victim.exists=false; env.advance(0.1)
    end
    equal(collector.retiredTail-collector.retiredHead+1,2)
    local before=collector.nextEntity
    for _=1,10 do env.emit("HIT",{initiator=unit,target=first}) end
    equal(collector.nextEntity,before)
    local response=exchange(); equal(response.data.eventLog.events[#response.data.eventLog.events].target.entityId,Json.null)
    local found=false; for _,code in ipairs(response.data.health.issues) do if code=="identity_history_evicted" then found=true end end
    truth(found)
end)

test("event weapons use Weapon categories including unknown weapons rather than missile hints",function()
    local env,unit,collector,request,exchange=fixture()
    for index,constant in ipairs({"SHELL","ROCKET","BOMB","TORPEDO","MISSILE","UNKNOWN"}) do
        local weapon=env.missile(200+index,unit,nil)
        weapon.desc.category=env.Weapon.Category[constant] or 999
        env.emit("HIT",{initiator=unit,target=unit,weapon=weapon})
        env.emit("KILL",{initiator=unit,target=unit,weapon=weapon})
    end
    local events=exchange().data.eventLog.events
    for index,kind in ipairs({"shell","rocket","bomb","torpedo","missile","weapon"}) do
        equal(events[index*2-1].weapon.kind,kind); equal(events[index*2].weapon.kind,kind)
        equal(events[index*2].weapon.occupancyStatus,"not_applicable")
    end
    equal(next(collector.missiles),nil)
    local unknown=env.missile(300,unit,nil); unknown.errors.getDesc=true; unknown.errors.getCategory=true
    env.emit("HIT",{initiator=unit,weapon=unknown})
    equal(exchange().data.eventLog.events[13].weapon.kind,"weapon")
end)

test("mission end freezes capture locally and exposes an idempotent final watermark",function()
    local env,unit,collector,request,exchange=fixture()
    local missile=env.missile(88,unit,nil); env.emit("SHOT",{initiator=unit,weapon=missile})
    env.emit("MISSION_END")
    equal(collector.status,"stopped"); equal(next(env.handlers),nil); equal(next(env.timers),nil)
    local final=collector.latestEventSeq; equal(final,2)
    env.emit("TAKEOFF",{initiator=unit}); env.advance(1); equal(collector.latestEventSeq,final)
    local response=exchange({maxCount=1})
    equal(response.data.finalEventSeq,final); equal(response.data.stopReason,"mission_end_event")
    equal(response.data.eventLog.hasMore,true)
    local stopped=request("shutdown"); equal(stopped.data.latestEventSeq,final)
    equal(stopped.data.stopReason,"mission_end_event")
    truth(exchange({after=1}).ok)
    truth(exchange({ack=final,after=final}).ok); equal(collector.eventBytes,0)
end)
