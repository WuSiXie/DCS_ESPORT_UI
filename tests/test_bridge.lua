local Json = require("src.shared.json")
local Bridge = require("src.hook.bridge")
local Mock = require("tests.mock_dcs")
local function read(path) local file = assert(io.open(PROJECT_ROOT .. "/" .. path, "rb")); local text=file:read("*a"); file:close(); return text end
local jsonSource, collectorSource = read("src/shared/json.lua"), read("src/mission/collector.lua")
local function fixture(config, env)
    config = config or {}
    if config.pollHz == nil then config.pollHz = 20 end -- Fast lifecycle fixture; defaults tested separately.
    env = env or Mock.new()
    local unit = env.unit(17, "Blue-1", "飞行员-A")
    local sink = {states={},batches={},ends={}}
    function sink:onEvents(source, batch)
        if self.reject then return false, "Disk failure" end
        self.batches[#self.batches+1] = {source=source,batch=batch}; return true
    end
    function sink:onState(source, state) self.states[#self.states+1]={source=source,state=state}; return true end
    function sink:onSessionEnd(source, details) self.ends[#self.ends+1]={source=source,details=details}; return true end
    local clock = 0
    local bridge = Bridge.new({Json=Json,net=env.net,now=function() return clock end,
        jsonSource=jsonSource,collectorSource=collectorSource,sink=sink}, config or {})
    local function step(n)
        for _=1,n or 1 do clock=clock+0.1; env.advance(0.1); bridge:tick() end
    end
    bridge:startMission()
    return bridge,env,unit,sink,step
end

test("final ACK is forwarded immediately and refreshes end metadata", function()
    local bridge,env,unit,sink,step=fixture({pollHz=1}); step(20)
    env.emit("TAKEOFF",{initiator=unit}); truth(bridge:stopMission())
    equal(bridge:getStatus().collectorAck.state,"waiting_server")
    truth(bridge:confirm(bridge.source,1))
    equal(bridge.actualAck,1); equal(env.DcsEsportCollector.eventBytes,0)
    equal(bridge:getStatus().collectorAck.state,"confirmed")
    equal(sink.ends[#sink.ends].details.actualAck,1)
    equal(bridge:getStatus().healthFresh,false)
    local attempts=bridge.finalAckAttempts; step(30); equal(bridge.finalAckAttempts,attempts)
end)

test("unavailable final ACK is visible and retries stop after three failures", function()
    local bridge,env,unit,sink,step=fixture(); step(10)
    env.emit("TAKEOFF",{initiator=unit}); truth(bridge:stopMission())
    local calls=0; bridge.deps.net={dostring_in=function() calls=calls+1;return nil end}
    truth(bridge:confirm(bridge.source,1)); equal(calls,1)
    step(9); equal(calls,1); step(25); equal(calls,3); step(100); equal(calls,3)
    local status=bridge:getStatus()
    equal(status.actualAck,0); equal(status.confirmedSeq,1); equal(status.pendingItems,0)
    equal(status.collectorAck.state,"unverified"); truth(status.collectorAck.lastError:find("No framed return"))
    equal(status.healthFresh,false); equal(sink.ends[#sink.ends].details.collectorAck.state,"unverified")
end)

test("transient final ACK failure recovers and refreshes confirmed metadata", function()
    local bridge,env,unit,sink,step=fixture(); step(10)
    env.emit("TAKEOFF",{initiator=unit}); truth(bridge:stopMission())
    bridge.deps.net={dostring_in=function() error("temporarily unavailable") end}
    truth(bridge:confirm(bridge.source,1)); equal(bridge.actualAck,0)
    bridge.deps.net=env.net; step(12)
    equal(bridge.actualAck,1); equal(bridge:getStatus().collectorAck.state,"confirmed")
    equal(bridge:getStatus().collectorAck.lastError,Json.null)
    equal(sink.ends[#sink.ends].details.collectorAck.state,"confirmed")
end)

test("new mission closes old cleanup without transferring its ACK", function()
    local bridge,env,unit,sink,step=fixture(); step(10)
    env.emit("TAKEOFF",{initiator=unit}); truth(bridge:stopMission())
    local old=Json.copy(bridge.source)
    env.DcsEsportCollector=nil; env.handlers={}; env.timers={}
    bridge:startMission(); step(20)
    truth(bridge:confirm(old,1)); equal(bridge.actualAck,0)
    local ending=sink.ends[#sink.ends].details
    equal(ending.collectorAck.state,"unverified"); equal(ending.collectorAck.lastError,"mission_environment_replaced")
    equal(env.DcsEsportCollector.ackEventSeq,0)
end)

test("Hook runs injection and collection in a distinct mission state", function()
    local bridge,env,unit,sink,step = fixture()
    step(10)
    equal(bridge.phase,"collecting"); equal(bridge.route.name,"mission_a_do_script")
    truth(#sink.states>0); equal(sink.states[1].state.entities[1].occupancy.playerName,"飞行员-A")
    equal(env.handlerRegistrations,1); equal(env.scheduleRegistrations,1)
end)

test("unread tail closes after three failures without fabricating a final watermark",function()
    local b,env,unit,sink,step=fixture({pollHz=1});step(20)
    env.emit("TAKEOFF",{initiator=unit})
    local calls=0;b.deps.net={dostring_in=function()calls=calls+1;return nil end}
    equal(b:stopMission(),false);step(40)
    equal(calls,3);equal(b.active,false);equal(b.phase,"waiting")
    equal(b.lastSessionEnd.tailComplete,false);equal(b.lastSessionEnd.latestEventSeq,Json.null)
    equal(b.lastSessionEnd.captureClosed,true);equal(b:getStatus().collectorAck.state,"unverified")
    truth(b.lastError:find("No framed return"));equal(b:getStatus().healthFresh,false)
    step(50);equal(calls,3)
end)

test("frozen snapshot continuations finish promptly without increasing sample rate",function()
    local env=Mock.new();for i=1,100 do env.unit(1000+i,"plane-"..i,nil) end
    local b,_,unit,sink,step=fixture({pollHz=1},env)
    step(20);truth(#sink.states>0);truth(sink.states[1].state.pageCount>1)
    equal(#sink.states[1].state.entities,101)
    local samples=env.DcsEsportCollector.aircraftSeq;local states=#sink.states
    step(1);equal(#sink.states,states);truth(env.DcsEsportCollector.aircraftSeq<=samples+1)
    step(35);truth(#sink.states>=4);truth(#sink.states<=6)
end)

test("default Hook polling is 1 Hz and carries state and cached events together",function()
    local bridge,env,unit,sink,step=fixture({pollHz=1})
    bridge.config.pollHz=nil -- Exercise the default, rather than only explicit configuration.
    step(30); equal(bridge.phase,"collecting")
    bridge.nextAction=bridge.deps.now(); step(1)
    local count=#sink.states
    env.emit("TAKEOFF",{initiator=unit})
    step(8); equal(#sink.states,count); equal(bridge.readThrough,0)
    step(3); equal(#sink.states,count+1); equal(bridge.readThrough,1)
    equal(sink.batches[1].batch.events[1].actor.entityId,sink.states[#sink.states].state.entities[1].entityId)
    equal(bridge.actualAck,0)
end)

test("Hook handles shifted a_do_script returns and ambiguous install responses", function()
    local env=Mock.new(); env.returnMode="shifted"; env.dropInstallOnce=true
    local bridge,_,unit,sink,step=fixture(nil,env)
    step(30)
    equal(bridge.phase,"collecting"); truth(#sink.states>0)
    equal(env.handlerRegistrations,1); equal(env.scheduleRegistrations,1)
end)

test("Hook chooses a verified direct route when the nested route is unavailable", function()
    local env=Mock.new(); env.routeMode="direct"
    local bridge,_,unit,sink,step=fixture(nil,env); step(12)
    equal(bridge.phase,"collecting"); equal(bridge.route.name,"mission_direct")
end)

test("Hook JSON-normalizes native Lua config arrays", function()
    local config=assert(loadfile(PROJECT_ROOT .. "/config/hook.example.lua"))()
    local bridge,env,unit,sink,step=fixture(config); step(25)
    equal(bridge.phase,"collecting"); truth(bridge.latestState)
end)

test("Hook reads without ACK and accepts only explicit source-scoped confirmations", function()
    local bridge,env,unit,sink,step=fixture(); step(10)
    env.emit("TAKEOFF",{initiator=unit}); step(2)
    equal(bridge.readThrough,1); equal(bridge.actualAck,0); equal(env.DcsEsportCollector.ackEventSeq,0)
    equal(bridge.pendingCount,1); truth(#sink.batches>0)
    equal(bridge:confirm({missionSessionId="old",collectorEpoch="old"},1),false)
    equal(bridge:confirm(bridge.source,2),false)
    truth(bridge:confirm(bridge.source,1)); step(2)
    equal(bridge.actualAck,1); equal(env.DcsEsportCollector.eventBytes,0); equal(bridge.pendingCount,0)
end)

test("sink failure does not advance delivery or ACK; retry rereads the event", function()
    local bridge,env,unit,sink,step=fixture(); step(10)
    sink.reject=true; env.emit("TAKEOFF",{initiator=unit}); step(3)
    equal(bridge.readThrough,0); equal(bridge.confirmedSeq,0); equal(env.DcsEsportCollector.ackEventSeq,0)
    sink.reject=false; step(30)
    equal(bridge.readThrough,1); equal(#sink.batches,1)
end)

test("pending capacity applies backpressure rather than auto-ACK or event loss", function()
    local bridge,env,unit,sink,step=fixture({maxPendingItems=2}); step(10)
    for _=1,3 do env.emit("TAKEOFF",{initiator=unit}) end
    step(3); equal(bridge.readThrough,2); equal(bridge.pendingCount,2); equal(bridge.actualAck,0)
    truth(bridge:confirm(bridge.source,2)); step(3)
    equal(bridge.readThrough,3); equal(bridge.actualAck,2); equal(bridge.pendingCount,1)
end)

test("diagnostic rejection after recording never replays accepted events", function()
    local bridge,env,unit,sink,step=fixture({maxPendingItems=2})
    local observed,initializations,states = {},0,0
    bridge.deps.sink=nil -- The deployed Hook has a memory queue and diagnostic observer only.
    bridge.deps.observer={
        onInitialized=function() initializations=initializations+1; return false,"verification failed" end,
        onEvents=function(_,source,batch)
            observed[#observed+1]=batch
            return false,"bytes written but verification failed"
        end,
        onState=function() states=states+1; error("state disk failed") end,
        onStatus=function() return false,"status disk failed" end
    }
    step(10)
    for _=1,3 do env.emit("TAKEOFF",{initiator=unit}) end
    step(25)
    equal(bridge.phase,"collecting"); equal(initializations,1); truth(states>0)
    equal(bridge.readThrough,2); equal(bridge.pendingCount,2); equal(#observed,1)
    equal(bridge.actualAck,0); equal(env.DcsEsportCollector.ackEventSeq,0)
    equal(env.DcsEsportCollector.latestEventSeq,3)
    equal(bridge.failureCount,0); equal(bridge.lastError,nil)
    truth(bridge:getStatus().diagnosticErrorCount>0)
    truth(bridge:confirm(bridge.source,2)); step(5)
    equal(bridge.readThrough,3); equal(bridge.actualAck,2); equal(bridge.pendingCount,1)
    equal(#observed,2); equal(observed[2].afterSeq,2); equal(observed[2].events[1].eventSeq,3)
    equal(bridge:getPendingBatches()[1].events[1].eventSeq,3)
end)

test("Hook assembles all pages before publishing a state", function()
    local bridge,env,unit,sink,step=fixture({maxResponseBytes=65536})
    for id=100,139 do env.unit(id,"Extra-"..id,nil) end
    step(5); equal(#sink.states,0)
    step(25); truth(#sink.states>0); equal(#sink.states[1].state.entities,41)
    equal(sink.states[1].state.pageCount>1,true)
end)

test("unknown existing source is preserved pending explicit verification", function()
    local bridge,env,unit,sink,step=fixture(); step(10)
    local before=env.DcsEsportCollector
    local nextBridge=Bridge.new({Json=Json,net=env.net,now=function() return env._time end,
        jsonSource=jsonSource,collectorSource=collectorSource},{bootId="different-hook"})
    nextBridge:startMission()
    for _=1,10 do env.advance(0.1); nextBridge:tick() end
    equal(nextBridge.phase,"verification_required"); equal(env.DcsEsportCollector,before)
    equal(env.handlerRegistrations,1)
end)

test("verified same-source restart rereads unconfirmed events", function()
    local bridge,env,unit,sink,step=fixture(); step(10)
    env.emit("TAKEOFF",{initiator=unit}); step(2); equal(bridge.readThrough,1)
    local second=Bridge.new({Json=Json,net=env.net,now=function() return env._time end,
        jsonSource=jsonSource,collectorSource=collectorSource},{bootId="restart",resumeSource=Json.copy(bridge.source)})
    second:startMission()
    for _=1,15 do env.advance(0.1); second:tick() end
    equal(second.readThrough,1); equal(second.actualAck,0); equal(env.handlerRegistrations,1)
end)

test("normal stop preserves unconfirmed events and reports a complete captured tail", function()
    local bridge,env,unit,sink,step=fixture(); step(10)
    local missile=env.missile(88,unit,nil); env.emit("SHOT",{initiator=unit,weapon=missile})
    bridge:stopMission()
    equal(bridge.phase,"waiting"); equal(env.DcsEsportCollector.status,"stopped")
    equal(sink.ends[1].details.tailComplete,true); equal(bridge.readThrough,2); equal(bridge.actualAck,0)
    equal(#bridge:getPendingBatches(),1)
end)

test("lost ACK response is recovered without losing or re-confirming unrelated data", function()
    local bridge,env,unit,sink,step=fixture(); step(10)
    env.emit("TAKEOFF",{initiator=unit}); step(2)
    truth(bridge:confirm(bridge.source,1))
    local original=env.net.dostring_in
    env.net.dostring_in=function(scope,code)
        local before=env.DcsEsportCollector.ackEventSeq
        local a,b=original(scope,code)
        if before==0 and env.DcsEsportCollector.ackEventSeq==1 then return nil,true end
        return a,b
    end
    step(1); equal(env.DcsEsportCollector.ackEventSeq,1)
    step(15); equal(bridge.actualAck,1); equal(bridge.confirmedSeq,1); equal(#sink.batches,1)
end)

test("collector loss changes epoch and old confirmations cannot affect the new collector", function()
    local bridge,env,unit,sink,step=fixture(); step(10)
    env.emit("TAKEOFF",{initiator=unit}); step(2)
    local oldSource=Json.copy(bridge.source)
    -- The old scheduler/handler disappear with the simulated lost collector segment.
    env.DcsEsportCollector=nil; env.handlers={}; env.timers={}
    step(30)
    equal(bridge.phase,"collecting"); truth(bridge.source.collectorEpoch~=oldSource.collectorEpoch)
    equal(bridge.readThrough,0); equal(bridge.actualAck,0)
    truth(bridge:confirm(oldSource,1)); step(2)
    equal(bridge.confirmedSeq,0); equal(env.DcsEsportCollector.ackEventSeq,0)
end)

test("old pending data survives a mission change and old receipts only release their own source", function()
    local bridge,env,unit,sink,step=fixture(); step(10)
    env.emit("TAKEOFF",{initiator=unit}); step(2)
    local oldSource=Json.copy(bridge.source); bridge:stopMission()
    env.DcsEsportCollector=nil; env.handlers={}; env.timers={}
    bridge:startMission(); step(20)
    truth(bridge.source.missionSessionId~=oldSource.missionSessionId)
    equal(#bridge:getRetainedSessions(),1); equal(#bridge:getPendingBatches(oldSource),1)
    env.emit("TAKEOFF",{initiator=unit}); step(2)
    truth(bridge:confirm(oldSource,1)); step(2)
    equal(#bridge:getRetainedSessions(),0); equal(bridge.pendingCount,1)
    equal(bridge.confirmedSeq,0); equal(env.DcsEsportCollector.ackEventSeq,0)
end)

test("stop drains several event pages without implicitly acknowledging the tail",function()
    local bridge,env,unit,sink,step=fixture(); step(10)
    bridge.deps.wallNow=function() return 0 end
    for _=1,350 do env.emit("TAKEOFF",{initiator=unit}) end
    truth(bridge:stopMission())
    equal(bridge.phase,"waiting"); equal(bridge.readThrough,350); equal(bridge.pendingCount,350)
    equal(bridge.actualAck,0); equal(env.DcsEsportCollector.ackEventSeq,0)
    truth(#sink.batches>=3); truth(sink.ends[#sink.ends].details.tailComplete)
    local copies={}
    for _,item in ipairs(sink.batches) do for _,event in ipairs(item.batch.events) do
        truth(not copies[event.eventSeq]); copies[event.eventSeq]=true
    end end
    local before=#sink.batches; truth(bridge:stopMission()); equal(#sink.batches,before)
end)

test("mission end in the injected collector starts draining before Hook stop callbacks",function()
    local bridge,env,unit,sink,step=fixture(); step(10)
    bridge.deps.wallNow=function() return 0 end
    for _=1,350 do env.emit("TAKEOFF",{initiator=unit}) end
    env.emit("MISSION_END"); equal(env.DcsEsportCollector.status,"stopped")
    step(8)
    equal(bridge.phase,"waiting"); equal(bridge.finalEventSeq,350); equal(bridge.readThrough,350)
    truth(bridge.lastSessionEnd.tailComplete); equal(bridge.confirmedSeq,0)
end)

test("stop drain observes batch limits and continues on later frames",function()
    local bridge,env,unit,sink,step=fixture({stopDrainMaxBatches=1}); step(10)
    bridge.deps.wallNow=function() return 0 end
    for _=1,350 do env.emit("TAKEOFF",{initiator=unit}) end
    equal(bridge:stopMission(),false); equal(bridge.phase,"draining"); equal(bridge.readThrough,128)
    equal(bridge.lastSessionEnd.tailReason,"drain_budget_exhausted")
    step(2); equal(bridge.phase,"waiting"); equal(bridge.readThrough,350)
    truth(bridge.lastSessionEnd.tailComplete)
end)

test("stop drain respects its time budget and resumes without replaying accepted pages",function()
    local bridge,env,unit,sink,step=fixture(); step(10)
    local elapsed=-0.2
    bridge.deps.wallNow=function() elapsed=elapsed+0.2; return elapsed end
    for _=1,350 do env.emit("TAKEOFF",{initiator=unit}) end
    equal(bridge:stopMission(),false); equal(bridge.readThrough,128)
    equal(bridge.lastSessionEnd.tailReason,"drain_budget_exhausted")
    bridge.deps.wallNow=function() return 0 end
    step(2); equal(bridge.readThrough,350); truth(bridge.lastSessionEnd.tailComplete)
    equal(sink.batches[2].batch.afterSeq,128)
end)

test("a lost shutdown response is retried against the same frozen event log",function()
    local bridge,env,unit,sink,step=fixture(); step(10)
    bridge.deps.wallNow=function() return 0 end
    local missile=env.missile(88,unit,nil); env.emit("SHOT",{initiator=unit,weapon=missile})
    local original=env.net.dostring_in
    local dropped=false
    env.net.dostring_in=function(scope,code)
        local before=env.DcsEsportCollector.status
        local a,b=original(scope,code)
        if not dropped and before~="stopped" and env.DcsEsportCollector.status=="stopped" then dropped=true; return nil,true end
        return a,b
    end
    equal(bridge:stopMission(),false); equal(bridge.finalEventSeq,nil)
    equal(env.DcsEsportCollector.latestEventSeq,2)
    step(2); truth(dropped); equal(bridge.readThrough,2); truth(bridge.lastSessionEnd.tailComplete)
    equal(env.DcsEsportCollector.latestEventSeq,2); equal(#sink.batches,1)
end)

test("a full pending queue keeps the tail incomplete until an explicit receipt frees capacity",function()
    local bridge,env,unit,sink,step=fixture({maxPendingItems=2}); step(10)
    bridge.deps.wallNow=function() return 0 end
    for _=1,3 do env.emit("TAKEOFF",{initiator=unit}) end
    equal(bridge:stopMission(),false); equal(bridge.phase,"draining")
    equal(bridge.readThrough,2); equal(bridge.lastSessionEnd.tailReason,"pending_buffer_full")
    equal(env.DcsEsportCollector.ackEventSeq,0)
    truth(bridge:confirm(bridge.source,2)); step(2)
    equal(bridge.phase,"waiting"); equal(bridge.readThrough,3); equal(bridge.actualAck,2)
    truth(bridge.lastSessionEnd.tailComplete); equal(bridge.pendingCount,1)
end)

test("a replaced mission reports its unread tail and retains already accepted pages",function()
    local bridge,env,unit,sink,step=fixture({stopDrainMaxBatches=1,maxPendingItems=200}); step(10)
    bridge.deps.wallNow=function() return 0 end
    for _=1,350 do env.emit("TAKEOFF",{initiator=unit}) end
    bridge:stopMission(); equal(bridge.readThrough,128)
    local source=Json.copy(bridge.source)
    env.DcsEsportCollector=nil; env.handlers={}; env.timers={}
    truth(bridge:startMission()); step(10)
    local retained=bridge:getRetainedSessions(); equal(#retained,1)
    equal(retained[1].sessionEnd.tailComplete,false)
    equal(retained[1].sessionEnd.tailReason,"mission_environment_replaced")
    equal(retained[1].sessionEnd.latestEventSeq,350)
    equal(#bridge:getPendingBatches(source),1)
    for _=1,100 do env.emit("TAKEOFF",{initiator=unit}) end
    step(5); equal(bridge.readThrough,72); equal(bridge:getStatus().totalPendingItems,200)
    truth(bridge:confirm(source,128)); step(3)
    equal(bridge.readThrough,100); equal(bridge.actualAck,0)
end)

test("an unavailable mission never produces a successful tail report",function()
    local bridge,env,unit,sink,step=fixture(); step(10)
    env.routeMode="unavailable"
    equal(bridge:stopMission(),false); equal(bridge.phase,"draining")
    equal(bridge.lastSessionEnd.tailComplete,false); equal(bridge.lastSessionEnd.latestEventSeq,Json.null)
    env.routeMode=nil; step(3)
    equal(bridge.phase,"waiting"); truth(bridge.lastSessionEnd.tailComplete)
end)

test("stop drains an explicit overflow gap without claiming its events were received",function()
    local bridge,env,unit,sink,step=fixture({collector={revision=1,eventBuffer={maxCount=2,maxBytes=16777216}}}); step(10)
    bridge.deps.wallNow=function() return 0 end
    for _=1,350 do env.emit("TAKEOFF",{initiator=unit}) end
    truth(bridge:stopMission()); equal(bridge.readThrough,350)
    equal(bridge.pendingCount,3); equal(sink.batches[1].batch.gaps[1].toSeq,348)
    equal(#sink.batches[1].batch.events,2); equal(bridge.actualAck,0)
end)

test("Hook rejects overlapping event ranges rather than skipping an unseen event", function()
    local bridge,env,unit,sink,step=fixture(); step(10)
    local batch={afterSeq=0,throughSeq=2,latestEventSeq=2,hasMore=false,
        events=Json.array({{eventSeq=2}}),gaps=Json.array()}
    equal(bridge:_acceptEvents(batch),false); equal(bridge.readThrough,0)
end)

test("Hook validates unsafe configuration bounds before entering callbacks", function()
    raises(function() fixture({pollHz=0}) end)
    raises(function() fixture({maxPendingBytes=100}) end)
    raises(function() fixture({stopDrainMaxBatches=0}) end)
    raises(function() fixture({stopDrainBudgetSec=0}) end)
end)
