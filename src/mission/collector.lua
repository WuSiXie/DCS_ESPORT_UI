-- Mission-side collector. Lua 5.1; injected as a chunk, no require/io/socket needed.
local Collector = {}
local MAX_INTEGER = 9007199254740991

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end
local function integer(value) return finite(value) and value >= 0 and value % 1 == 0 and value <= MAX_INTEGER end
local function method(object, name, ...)
    local arguments = { ... }
    return pcall(function()
        if object == nil or type(object[name]) ~= "function" then error("Missing method " .. name) end
        return object[name](object, unpack(arguments))
    end)
end
local function invoke(fn, ...)
    if type(fn) ~= "function" then return false, nil end
    return pcall(fn, ...)
end
local function count(map) local n = 0; for _ in pairs(map) do n = n + 1 end; return n end

function Collector.new(env, Json, identity, options)
    options = options or {}
    local N, A, copy = Json.null, Json.array, Json.copy
    local self = {
        collectorVersion = "0.1.5", protocolVersion = 1,
        missionSessionId = assert(identity.missionSessionId), collectorEpoch = assert(identity.collectorEpoch),
        status = "installed", configRevision = 0, scopeRevision = 0,
        objects = {}, aircraft = {}, missiles = {}, objectCount = 0, nextEntity = 0,
        retiredObjects = {}, retiredOrder = {}, retiredHead = 1, retiredTail = 0,
        events = {}, eventHead = 1, eventTail = 0, eventBytes = 0,
        ackEventSeq = 0, latestEventSeq = 0, deliveredThrough = 0, lostThrough = 0,
        captureErrorCount = 0, samplingErrorCount = 0, samplingOverrunCount = 0,
        droppedEventCount = 0, incompleteLauncherCount = 0, rejectedRecordCount = 0,
        aircraftSeq = 0, missileSeq = 0, nextSnapshot = 0,
        limits = { maxResponseBytes = 262144, maxRecordBytes = 32768 },
        captureStartedSimTime = 0, baselineCompletedSimTime = 0,
        inventoryComplete = true, missileComplete = true, continuous = true,
        persistentIssues = {}, timerId = nil, snapshot = nil,
        maxObjects = options.maxObjects or 8192, maxMissiles = options.maxMissiles or 4096,
        maxRetiredObjects = options.maxRetiredObjects or 8192,
        maxReadFailures = options.maxReadFailures or 5
    }
    local function now()
        local ok, value = invoke(env.timer and env.timer.getTime)
        return ok and finite(value) and value or 0
    end
    -- Only frozen event copies and snapshot records/pages enter this cache.
    -- Weak keys release encoded strings when ACK/eviction or a new snapshot
    -- releases the corresponding tables; live entity records are never cached.
    local encodedTables = setmetatable({}, { __mode = "k" })
    local function encodeResponse(value) return Json.encode(value, encodedTables) end
    local function number(value) return finite(value) and value or N end
    local function stringValue(value) return type(value) == "string" and value or N end
    local function bool(value) if type(value) == "boolean" then return value end; return N end
    local function issue(list, code)
        for _, old in ipairs(list) do if old == code then return end end
        list[#list + 1] = code
    end
    local function vector(value)
        if type(value) ~= "table" or not finite(value.x) or not finite(value.y) or not finite(value.z) then return N end
        return { x = value.x, y = value.y, z = value.z }
    end
    local function dataFrom(object, name)
        local ok, value = method(object, name)
        if ok then return value end
        return nil
    end
    local function fail(code, message, retryable)
        error({ code = code, message = message or code, retryable = retryable == true }, 0)
    end
    local function objectTable(value) return type(value) == "table" and value ~= N and not Json.isArray(value) end
    local function requiredObject(value, label)
        if not objectTable(value) then fail("INVALID_REQUEST", label .. " must be an object") end
    end
    local function coalitionName(value)
        local sides = env.coalition and env.coalition.side or {}
        if value == sides.RED and value ~= nil then return "red" end
        if value == sides.BLUE and value ~= nil then return "blue" end
        if value == sides.NEUTRAL and value ~= nil then return "neutral" end
        return N
    end
    local function sideAllowed(side)
        if side == N then return true end -- Unknown ownership is explicit, never guessed or silently discarded.
        for _, configured in ipairs(self.config.scope.coalitions) do if configured == side then return true end end
        return false
    end
    local function objectKind(object, hint)
        if hint and hint ~= "weapon" then return hint end
        local objectCategory = dataFrom(object, "getCategory")
        local categories = env.Object and env.Object.Category or {}
        if categories.STATIC ~= nil and objectCategory == categories.STATIC then return "static" end
        local desc = dataFrom(object, "getDesc")
        if hint == "weapon" or (categories.WEAPON ~= nil and objectCategory == categories.WEAPON) then
            local weapon = env.Weapon and env.Weapon.Category or {}
            for constant, kind in pairs({ MISSILE = "missile", BOMB = "bomb", ROCKET = "rocket",
                SHELL = "shell", TORPEDO = "torpedo" }) do
                if type(desc) == "table" and weapon[constant] ~= nil and desc.category == weapon[constant] then return kind end
            end
            return "weapon"
        end
        local unit = env.Unit and env.Unit.Category or {}
        if type(desc) == "table" then
            if desc.category == unit.AIRPLANE and unit.AIRPLANE ~= nil then return "aircraft" end
            if desc.category == unit.HELICOPTER and unit.HELICOPTER ~= nil then return "aircraft" end
            if desc.category == unit.GROUND_UNIT and unit.GROUND_UNIT ~= nil then return "ground_unit" end
            if desc.category == unit.SHIP and unit.SHIP ~= nil then return "ship" end
        end
        return "other"
    end
    local function runtimeObjectId(object)
        -- DCS Scripts/Common/LuaClass.lua compares wrappers by id_, not table identity.
        local ok, id = pcall(function() return object.id_ end)
        if ok and ((finite(id) and id > 0) or (type(id) == "string" and id ~= "" and id ~= "0")) then return tostring(id) end
        id = dataFrom(object, "getObjectID")
        if (finite(id) and id > 0) or (type(id) == "string" and id ~= "" and id ~= "0") then return tostring(id) end
        return nil
    end
    local function objectKey(object)
        local runtimeId = runtimeObjectId(object)
        if runtimeId then return "runtime:" .. runtimeId, true end
        local id = dataFrom(object, "getID")
        if type(id) == "number" or type(id) == "string" then
            return tostring(dataFrom(object, "getCategory") or "object") .. ":id:" .. tostring(id), true
        end
        return object, false -- An unidentifiable wrapper is not a stable target identity.
    end
    local function unregister(entry)
        if self.objects[entry.key] == entry then self.objects[entry.key] = nil; self.objectCount = self.objectCount - 1 end
    end
    local function retire(entry)
        unregister(entry)
        if entry.retired then return end
        entry.retired = true
        self.retiredObjects[entry.key] = entry
        self.retiredTail = self.retiredTail + 1; self.retiredOrder[self.retiredTail] = entry
        while self.retiredTail - self.retiredHead + 1 > self.maxRetiredObjects do
            local old = self.retiredOrder[self.retiredHead]
            if self.retiredObjects[old.key] == old then self.retiredObjects[old.key] = nil end
            self.retiredOrder[self.retiredHead] = nil; self.retiredHead = self.retiredHead + 1
            self.persistentIssues.identity_history_evicted = true
        end
        if self.retiredHead > 2048 and self.retiredHead > self.retiredTail / 2 then
            local entries = {}
            for index = self.retiredHead, self.retiredTail do entries[#entries + 1] = self.retiredOrder[index] end
            self.retiredOrder = entries; self.retiredHead = 1; self.retiredTail = #entries
        end
    end
    local function register(object, hint)
        if object == nil then return nil end
        local objectType = type(object)
        if objectType ~= "table" and objectType ~= "userdata" then return nil end
        local key = objectKey(object)
        local incomingOk, incomingExists = method(object, "isExist")
        local previous = self.objects[key]
        if previous then
            if previous.retiring then return previous end
            local ok, exists = method(previous.object, "isExist")
            if not ok or exists ~= false then
                if incomingOk and incomingExists == false then return self.retiredObjects[key] end
                return previous
            end
            if previous.active then
                self.remove(previous, "object_gone", now())
            else retire(previous) end
        end
        local historical = self.retiredObjects[key]
        -- Only a positively live object can start a new lifetime for a retired key.
        if historical and (not incomingOk or incomingExists ~= true) then return historical end
        -- A dead reference with evicted/unknown history must not invent a new entity.
        if incomingOk and incomingExists == false then return nil end
        if self.objectCount >= self.maxObjects then
            self.inventoryComplete = false; self.missileComplete = false
            self.persistentIssues.object_limit = true
            return nil
        end
        self.nextEntity = self.nextEntity + 1
        local kind = objectKind(object, hint)
        local entry = { entityId = kind .. "-" .. self.nextEntity, kind = kind, object = object,
            key = key, failures = 0, active = false, dirty = true }
        self.objects[key] = entry
        self.objectCount = self.objectCount + 1
        return entry
    end
    local function stale(previous, time, code, empty)
        self.samplingErrorCount = self.samplingErrorCount + 1
        if previous and previous.sampledSimTime ~= N then
            local result = copy(previous)
            result.status = "stale"; result.lastAttemptSimTime = time; issue(result.issues, code)
            return result
        end
        empty.status = "unavailable"; empty.sampledSimTime = N; empty.lastAttemptSimTime = time
        empty.issues = A({ code })
        return empty
    end
    local function occupancy(entry, time, previous)
        local ok, name = method(entry.object, "getPlayerName")
        if not ok or (name ~= nil and type(name) ~= "string") then
            return stale(previous, time, "occupancy_read_failed", { isPlayer = N, playerName = N, source = "unavailable" })
        end
        return { status = "ok", sampledSimTime = time, lastAttemptSimTime = time, issues = A(),
            isPlayer = name ~= nil and name ~= "", playerName = name and name ~= "" and name or N,
            source = "unit_getPlayerName" }
    end
    local function reference(object, time, hint, refreshOccupancy)
        if object == nil then return N end
        local key, stable = objectKey(object)
        local entry = self.objects[key]
        if stable or entry then entry = register(object, hint) end
        if entry and entry.lastReference and (entry.retired or
            (entry.retiring and dataFrom(entry.object, "isExist") == false)) then
            local result = copy(entry.lastReference); result.capturedSimTime = time
            issue(result.issues, "object_retired")
            if result.occupancyStatus == "ok" then result.occupancyStatus = "stale" end
            return result
        end
        -- Prefer a registered Unit wrapper: generic getTarget() wrappers may lack Unit methods.
        if entry then object = entry.object end
        local kind = entry and entry.kind or objectKind(object, hint)
        local objectId = dataFrom(object, "getID")
        local occ
        if kind == "aircraft" or kind == "ground_unit" or kind == "ship" then
            if entry then
                if refreshOccupancy or not entry.occupancy then entry.occupancy = occupancy(entry, time, entry.occupancy) end
                occ = entry.occupancy
            end
        end
        local issues = A()
        if not entry then issue(issues, "reference_identity_unavailable") end
        local name, typeName = dataFrom(object, "getName"), dataFrom(object, "getTypeName")
        if type(name) ~= "string" then issue(issues, "name_unavailable") end
        if type(typeName) ~= "string" then issue(issues, "type_name_unavailable") end
        local isPlayer = N
        if occ then isPlayer = occ.isPlayer end
        local result = { entityId = entry and entry.entityId or N,
            dcsObjectId = objectId ~= nil and tostring(objectId) or N, kind = kind,
            runtimeObjectId = runtimeObjectId(object) or N,
            name = stringValue(name), typeName = stringValue(typeName),
            coalition = coalitionName(dataFrom(object, "getCoalition")),
            isPlayer = isPlayer, playerName = occ and occ.playerName or N,
            occupancyStatus = occ and occ.status or ((kind == "aircraft" or kind == "ground_unit" or kind == "ship") and "unavailable" or "not_applicable"),
            occupancySampledSimTime = occ and occ.sampledSimTime or N,
            capturedSimTime = time, issues = issues }
        if entry then entry.lastReference = copy(result) end
        return result
    end
    local function motion(entry, time, sequence)
        local old = entry.record and entry.record.motion
        local pointOk, point = method(entry.object, "getPoint")
        local velocityOk, velocity = method(entry.object, "getVelocity")
        local pos, vel = vector(point), vector(velocity)
        if (not pointOk or pos == N) and (not velocityOk or vel == N) then
            return stale(old, time, "motion_read_failed", { sampleSeq = N, position = N, velocity = N,
                speedMps = N, groundSpeedMps = N, basis = N, inAir = N })
        end
        local issues, basis = A(), N
        local ok, orientation = method(entry.object, "getPosition")
        if ok and type(orientation) == "table" then
            local forward, up, right = vector(orientation.x), vector(orientation.y), vector(orientation.z)
            if forward ~= N and up ~= N and right ~= N then basis = { forward = forward, up = up, right = right } end
        end
        local airOk, air = method(entry.object, "inAir")
        if pos == N then issue(issues, "position_unavailable") end
        if vel == N then issue(issues, "velocity_unavailable") end
        if basis == N then issue(issues, "basis_unavailable") end
        if not airOk or type(air) ~= "boolean" then issue(issues, "in_air_unavailable"); air = N end
        local speed, groundSpeed = N, N
        if vel ~= N then
            speed = number(math.sqrt(vel.x^2 + vel.y^2 + vel.z^2))
            groundSpeed = number(math.sqrt(vel.x^2 + vel.z^2))
            if speed == N or groundSpeed == N then issue(issues, "speed_out_of_range") end
        end
        if #issues > 0 then self.samplingErrorCount = self.samplingErrorCount + 1 end
        return { status = #issues == 0 and "ok" or "partial", sampledSimTime = time, lastAttemptSimTime = time,
            issues = issues, sampleSeq = sequence, position = pos, velocity = vel,
            speedMps = speed, groundSpeedMps = groundSpeed, basis = basis, inAir = bool(air) }
    end
    local function fuel(entry, time)
        local ok, ratio = method(entry.object, "getFuel")
        local desc = dataFrom(entry.object, "getDesc")
        local capacity = type(desc) == "table" and number(desc.fuelMassMax) or N
        local empty = { ratioRaw = N, source = "unavailable", referenceInternalCapacityKg = capacity,
            massKgEstimate = N, massMethod = "unavailable", massValidationId = N }
        if not ok or not finite(ratio) then return stale(entry.record.fuel, time, "fuel_read_failed", empty) end
        empty.ratioRaw = ratio; empty.source = "unit_getFuel"; empty.status = "ok"
        empty.sampledSimTime = time; empty.lastAttemptSimTime = time
        empty.issues = A({ "mass_conversion_unverified" })
        return empty
    end
    local function ammoCategory(value)
        for key, name in pairs({ MISSILE = "missile", BOMB = "bomb", ROCKET = "rocket", SHELL = "shell", TORPEDO = "torpedo" }) do
            local enum = env.Weapon and env.Weapon.Category and env.Weapon.Category[key]
            if enum ~= nil and enum == value then return name end
        end
        return "unknown"
    end
    local function armament(entry, time)
        local ok, items = method(entry.object, "getAmmo")
        if not ok or type(items) ~= "table" then
            return stale(entry.record.armament, time, "armament_read_failed", { source = "unavailable", items = N, coverage = "api_visible_ammunition" })
        end
        local result, issues = A(), A()
        for index, item in ipairs(items) do
            if type(item) ~= "table" or not integer(item.count) or type(item.desc) ~= "table" then
                issue(issues, "ammo_item_invalid")
            else
                local desc, ws, rawType = item.desc, N, stringValue(item.desc.typeName)
                if type(desc.wsType) == "table" and #desc.wsType > 0 then
                    ws = A()
                    for _, component in ipairs(desc.wsType) do
                        if not integer(component) then ws = N; break end
                        ws[#ws + 1] = component
                    end
                end
                local key, identification
                if rawType ~= N and rawType ~= "" then key = "type:" .. rawType; identification = "type_name"
                elseif ws ~= N then key = "ws:" .. table.concat(ws, "."); identification = "ws_type"
                else key = "unknown:" .. entry.entityId .. ":" .. index; identification = "unknown"; issue(issues, "ammo_type_unknown") end
                result[#result + 1] = { weaponKey = key, typeName = rawType, displayName = stringValue(desc.displayName),
                    category = ammoCategory(desc.category), count = item.count, wsType = ws, identification = identification }
            end
        end
        return { status = #issues == 0 and "ok" or "partial", sampledSimTime = time, lastAttemptSimTime = time,
            issues = issues, source = "unit_getAmmo", items = result, coverage = "api_visible_ammunition" }
    end
    local function condition(entry, time)
        local existsOk, exists = method(entry.object, "isExist")
        local lifeOk, life = method(entry.object, "getLife")
        local referenceOk, lifeReference = method(entry.object, "getLife0")
        local issues = A()
        if not existsOk or type(exists) ~= "boolean" then issue(issues, "existence_unavailable") end
        if not lifeOk or not finite(life) then issue(issues, "life_unavailable") end
        if not referenceOk or not finite(lifeReference) then issue(issues, "life_reference_unavailable") end
        return { status = #issues == 0 and "ok" or "partial", sampledSimTime = time, lastAttemptSimTime = time,
            issues = issues, exists = bool(exists), lifeRaw = number(life), lifeReference = number(lifeReference) }
    end
    local function aircraftAllowed(object)
        local desc = dataFrom(object, "getDesc")
        if type(desc) ~= "table" then return false end
        local category = env.Unit and env.Unit.Category or {}
        local included = (category.AIRPLANE ~= nil and desc.category == category.AIRPLANE and self.config.scope.includeAirplanes)
            or (category.HELICOPTER ~= nil and desc.category == category.HELICOPTER and self.config.scope.includeHelicopters)
        return included and sideAllowed(coalitionName(dataFrom(object, "getCoalition")))
    end
    local function refreshIdentity(entry)
        local object, record = entry.object, entry.record
        local desc = dataFrom(object, "getDesc")
        if type(desc) ~= "table" then desc = {} end
        local group = dataFrom(object, "getGroup")
        local id = dataFrom(object, "getID")
        local category = env.Unit and env.Unit.Category or {}
        record.dcsObjectId = id ~= nil and tostring(id) or N
        record.runtimeObjectId = runtimeObjectId(object) or N
        record.identity = { unitName = stringValue(dataFrom(object, "getName")),
            groupName = stringValue(group and dataFrom(group, "getName")), typeName = stringValue(dataFrom(object, "getTypeName")),
            coalition = coalitionName(dataFrom(object, "getCoalition")), countryId = number(dataFrom(object, "getCountry")),
            aircraftCategory = desc.category == category.HELICOPTER and "helicopter" or "airplane" }
    end
    local function sampleSlow(entry, time)
        entry.occupancy = occupancy(entry, time, entry.occupancy)
        entry.record.occupancy = copy(entry.occupancy)
        entry.record.fuel = fuel(entry, time)
        entry.record.armament = armament(entry, time)
        entry.record.condition = condition(entry, time)
        refreshIdentity(entry)
        entry.dirty = false
    end
    local function addAircraft(object, discovery, time)
        if not aircraftAllowed(object) then return nil end
        local ok, exists = method(object, "isExist")
        local activeOk, active = method(object, "isActive")
        if not ok or not activeOk then self.inventoryComplete = false end
        if not ok or exists ~= true or not activeOk or active ~= true then return nil end
        local key = objectKey(object)
        local prior = self.objects[key]
        if prior and prior.active then
            local priorOk, priorExists = method(prior.object, "isExist")
            if priorOk and priorExists == false then self.remove(prior, "object_gone", time) end
        end
        local entry = register(object, "aircraft")
        if not entry then return nil end
        if entry.active then return entry end
        entry.kind = "aircraft"; entry.active = true
        entry.record = { entityId = entry.entityId, kind = "aircraft", dcsObjectId = N,
            discovery = discovery, discoveredSimTime = time }
        entry.record.motion = motion(entry, time, self.aircraftSeq)
        self.aircraft[entry.entityId] = entry
        sampleSlow(entry, time)
        return entry
    end
    local function target(entry, time)
        local ok, object = method(entry.object, "getTarget")
        if object ~= nil and type(object) ~= "table" and type(object) ~= "userdata" then ok = false end
        if not ok then
            self.samplingErrorCount = self.samplingErrorCount + 1
            local previous = entry.record and entry.record.targetObservation
            if previous and previous.sampledSimTime ~= N then
                local result = copy(previous)
                result.status = "stale"; result.lastAttemptSimTime = time; issue(result.issues, "target_query_failed")
                return result
            end
            return { status = "unavailable", source = "unavailable", sampledSimTime = N,
                lastAttemptSimTime = time, lastSuccessfulStatus = N, object = N, issues = A({ "target_query_failed" }) }
        end
        local status = object == nil and "none_reported" or "object"
        local objectRef = object and reference(object, time, nil, true) or N
        local issues = A()
        if objectRef ~= N and objectRef.entityId == N and objectRef.runtimeObjectId == N and objectRef.dcsObjectId == N then
            issue(issues, "target_identity_unavailable")
        end
        return { status = status, source = "weapon_getTarget", sampledSimTime = time,
            lastAttemptSimTime = time, lastSuccessfulStatus = status,
            object = objectRef, issues = issues }
    end

    local function trimLog()
        local maxCount, maxBytes = self.config.eventBuffer.maxCount, self.config.eventBuffer.maxBytes
        while self.eventHead <= self.eventTail and
            (self.eventTail - self.eventHead + 1 > maxCount or self.eventBytes > maxBytes) do
            local item = self.events[self.eventHead]
            self.eventBytes = self.eventBytes - item.bytes
            self.lostThrough = item.record.eventSeq
            self.events[self.eventHead] = nil; self.eventHead = self.eventHead + 1
            self.droppedEventCount = self.droppedEventCount + 1; self.continuous = false
        end
    end
    local function compactLog()
        if self.eventHead > 2048 and self.eventHead > self.eventTail / 2 then
            local rebuilt, tail = {}, 0
            for index = self.eventHead, self.eventTail do tail = tail + 1; rebuilt[tail] = self.events[index] end
            self.events = rebuilt; self.eventHead = 1; self.eventTail = tail
        end
    end
    local function emit(kind, time, actor, victim, weapon, details, raw)
        local record = { eventSeq = self.latestEventSeq + 1, type = kind,
            origin = raw and "dcs_event" or "collector_observation", dcsEventId = raw and number(raw.id) or N,
            simTime = raw and finite(raw.time) and raw.time or time, capturedSimTime = time,
            timeSource = raw and finite(raw.time) and "dcs_event" or "capture_time",
            actor = actor or N, target = victim or N, weapon = weapon or N, details = details or {}, issues = A() }
        if record.eventSeq > MAX_INTEGER then error("Event sequence exhausted; new collector epoch required") end
        local frozen = copy(record)
        local encoded = Json.encode(frozen)
        local bytes = #encoded
        if bytes > self.limits.maxRecordBytes then
            -- Preserve the sequence and an explicit loss fact, so one bad
            -- record cannot prevent subsequent valid events from being read.
            self.rejectedRecordCount = self.rejectedRecordCount + 1
            self.continuous = false; self.persistentIssues.record_rejected = true
            frozen = { eventSeq = record.eventSeq, type = "capture_record_rejected", origin = "collector_observation",
                dcsEventId = record.dcsEventId, simTime = record.simTime, capturedSimTime = time,
                timeSource = record.timeSource, actor = N, target = N, weapon = N,
                details = { originalType = kind, originalBytes = bytes, reason = "record_too_large" },
                issues = A({ "event_payload_lost" }) }
            encoded = Json.encode(frozen); bytes = #encoded
        end
        self.latestEventSeq = record.eventSeq
        self.eventTail = self.eventTail + 1; self.events[self.eventTail] = { record = frozen, bytes = bytes, encoded = encoded }
        self.eventBytes = self.eventBytes + bytes
        trimLog(); compactLog()
        return record
    end
    self.remove = function(entry, reason, time)
        if not entry.active or entry.retiring then return end
        entry.retiring = true
        if entry.kind == "missile" then
            local record = entry.record
            emit("weapon_track_ended", time, record.launch.launcher.object, N, reference(entry.object, time, "missile"),
                { missileEntityId = entry.entityId, reason = reason, launch = record.launch,
                    lastMotion = record.motion or N, lastTargetObservation = record.targetObservation,
                    lastKnownTarget = record.lastKnownTarget })
            self.missiles[entry.entityId] = nil
        else
            emit("entity_removed", time, reference(entry.object, time, entry.kind), N, N,
                { entityId = entry.entityId, reason = reason, lastMotion = entry.record.motion or N })
            self.aircraft[entry.entityId] = nil
        end
        entry.active = false
        entry.retiring = false
        retire(entry)
    end
    local function launcher(event, object, time)
        local initiator = event.initiator
        local apiOk, api = method(object, "getLauncher")
        if not apiOk or (type(api) ~= "table" and type(api) ~= "userdata") then api = nil end
        local actor = initiator and reference(initiator, time, nil, true) or N
        local alternate = api and reference(api, time, nil, true) or N
        local result = { status = "unknown", source = "unavailable", object = N, alternateObject = N, issues = A() }
        if actor ~= N then result.object = actor; result.source = "event_initiator"
        elseif alternate ~= N then result.object = alternate; result.source = "weapon_getLauncher" end
        if result.object ~= N and (result.object.dcsObjectId ~= N or
            (result.object.name ~= N and result.object.typeName ~= N)) then result.status = "known" end
        if actor ~= N and alternate ~= N then
            if objectKey(initiator) == objectKey(api) then result.source = "both"
            else result.status = "conflict"; result.alternateObject = alternate; issue(result.issues, "launcher_source_conflict") end
        end
        if result.status ~= "known" then
            self.incompleteLauncherCount = self.incompleteLauncherCount + 1
            if result.status == "unknown" then issue(result.issues, "launcher_unknown") end
        end
        return result
    end
    local function fire(event, time)
        local object = event.weapon
        local actorEntry = event.initiator and register(event.initiator)
        if actorEntry then actorEntry.dirty = true end
        local desc = object and dataFrom(object, "getDesc")
        local missileCategory = env.Weapon and env.Weapon.Category and env.Weapon.Category.MISSILE
        if object and (type(desc) ~= "table" or missileCategory == nil or desc.category ~= missileCategory) then return end
        local firing = launcher(event, object, time)
        local side = object and coalitionName(dataFrom(object, "getCoalition")) or N
        if side == N and firing.object ~= N then side = firing.object.coalition end
        if not sideAllowed(side) then return end
        if self.config.scope.missileScope == "air_launched" and
            (firing.object == N or firing.object.kind ~= "aircraft") then return end
        if object then
            local existing = self.objects[objectKey(object)]
            if existing and existing.active and existing.kind == "missile" then
                local oldOk, oldExists = method(existing.object, "isExist")
                if oldOk and oldExists == false then self.remove(existing, "object_gone", time)
                else return end -- Duplicate notification of a still-live object.
            end
        end
        local entry = object and register(object, "missile") or nil
        if entry and entry.retired then return end -- Delayed duplicate notification of a finished missile.
        local canTrack = entry and count(self.missiles) < self.maxMissiles
        local initial = entry and target(entry, time) or { status = "unavailable", source = "unavailable",
            sampledSimTime = N, lastAttemptSimTime = time, lastSuccessfulStatus = N, object = N, issues = A({ "weapon_object_unavailable" }) }
        local launch = { simTime = finite(event.time) and event.time or time,
            timeSource = finite(event.time) and "dcs_event" or "capture_time", launcher = firing,
            initialTarget = initial, initialPosition = vector(object and dataFrom(object, "getPoint")),
            initialVelocity = vector(object and dataFrom(object, "getVelocity")), issues = A() }
        if firing.status ~= "known" then issue(launch.issues, "launcher_incomplete") end
        local trackingStatus = "object_unavailable"
        if entry then
            if canTrack then
                trackingStatus = "tracking"; entry.kind = "missile"; entry.active = true
                local id = dataFrom(object, "getID")
                entry.record = { entityId = entry.entityId, kind = "missile", dcsObjectId = id ~= nil and tostring(id) or N,
                    runtimeObjectId = runtimeObjectId(object) or N,
                    typeName = stringValue(dataFrom(object, "getTypeName")), coalition = side, launch = copy(launch),
                    targetObservation = copy(initial), lastKnownTarget = initial.status == "object" and copy(initial) or N }
                entry.record.motion = motion(entry, time, self.missileSeq)
                self.missiles[entry.entityId] = entry
            else
                trackingStatus = "unsupported"; self.missileComplete = false
                self.persistentIssues.missile_limit = true; issue(launch.issues, "resource_limit")
            end
        else self.missileComplete = false; issue(launch.issues, "weapon_object_unavailable") end
        emit("weapon_fired", time, firing.object, N, object and reference(object, time, "missile") or N,
            { missileEntityId = entry and entry.entityId or N, launch = launch, trackingStatus = trackingStatus }, event)
    end
    local shutdown
    local eventNames = {
        S_EVENT_BIRTH = "entity_born", S_EVENT_SHOT = "weapon_fired", S_EVENT_HIT = "hit", S_EVENT_KILL = "kill",
        S_EVENT_CRASH = "crash", S_EVENT_DEAD = "dead", S_EVENT_UNIT_LOST = "unit_lost",
        S_EVENT_EJECTION = "ejection", S_EVENT_PILOT_DEAD = "pilot_dead", S_EVENT_TAKEOFF = "takeoff", S_EVENT_LAND = "land",
        S_EVENT_PLAYER_ENTER_UNIT = "player_entered", S_EVENT_PLAYER_LEAVE_UNIT = "player_left"
    }
    local function processEvent(event)
        if type(event) ~= "table" then error("Invalid DCS event") end
        if env.world.event.S_EVENT_MISSION_END ~= nil and event.id == env.world.event.S_EVENT_MISSION_END then
            shutdown("mission_end_event"); return
        end
        local kind
        for constant, normalized in pairs(eventNames) do
            if env.world.event[constant] ~= nil and event.id == env.world.event[constant] then kind = normalized; break end
        end
        if not kind then return end
        local time = now()
        if kind == "weapon_fired" then fire(event, time); return end
        local actorSide = event.initiator and coalitionName(dataFrom(event.initiator, "getCoalition")) or N
        local targetSide = event.target and coalitionName(dataFrom(event.target, "getCoalition")) or N
        if actorSide ~= N and not sideAllowed(actorSide) and (targetSide == N or not sideAllowed(targetSide)) then return end
        local details = {}
        if kind == "entity_born" then
            local entry = event.initiator and addAircraft(event.initiator, "birth_event", time)
            if not entry then return end
            -- Initial scan and an actual birth are distinct facts; repeated births are not new lives.
            if entry.birthRecorded then return end
            entry.birthRecorded = true; details = { entityId = entry.entityId, entityKind = entry.kind }
        elseif kind == "takeoff" or kind == "land" then details.place = reference(event.place, time)
        elseif kind == "player_entered" or kind == "player_left" then
            local entry = event.initiator and register(event.initiator)
            details.reportedPlayerName = stringValue(event.playerName)
            if entry then
                entry.occupancy = occupancy(entry, time, entry.occupancy); entry.dirty = true
                details.occupancyAfter = copy(entry.occupancy)
            else details.occupancyAfter = { status = "unavailable", sampledSimTime = N, lastAttemptSimTime = time,
                issues = A({ "occupancy_read_failed" }), isPlayer = N, playerName = N, source = "unavailable" } end
        end
        local entry = event.initiator and self.objects[objectKey(event.initiator)]
        if entry then entry.dirty = true end
        emit(kind, time, reference(event.initiator, time, nil, true), reference(event.target, time, nil, true),
            reference(event.weapon, time, event.weapon and "weapon" or nil), details, event)
    end
    self.onEvent = function(event)
        if self.status == "installed" or self.status == "stopped" then return end
        local ok = pcall(processEvent, event)
        if not ok then self.captureErrorCount = self.captureErrorCount + 1; self.continuous = false end
    end
    local function reconcile(time)
        self.inventoryComplete = true
        local sides, categories = env.coalition.side, env.Group.Category
        for _, sideName in ipairs(self.config.scope.coalitions) do
            local side = sides[string.upper(sideName)]
            for _, groupKind in ipairs({ "AIRPLANE", "HELICOPTER" }) do
                local enabled = groupKind == "AIRPLANE" and self.config.scope.includeAirplanes or
                    groupKind == "HELICOPTER" and self.config.scope.includeHelicopters
                if enabled then
                    local category = categories[groupKind]
                    local ok, groups = invoke(env.coalition.getGroups, side, category)
                    if not ok or type(groups) ~= "table" or category == nil or side == nil then self.inventoryComplete = false
                    else
                        for _, group in ipairs(groups) do
                            local unitsOk, units = method(group, "getUnits")
                            if not unitsOk or type(units) ~= "table" then self.inventoryComplete = false
                            else for _, object in ipairs(units) do addAircraft(object, "reconcile", time) end end
                        end
                    end
                end
            end
        end
        local retired = {}
        for _, entry in pairs(self.objects) do
            if not entry.active then
                local ok, exists = method(entry.object, "isExist")
                if ok and exists == false then retired[#retired + 1] = entry end
            end
        end
        for _, entry in ipairs(retired) do retire(entry) end
    end
    local function targetIdentity(observation)
        if observation.lastSuccessfulStatus ~= "object" then return observation.lastSuccessfulStatus end
        local object = observation.object
        if object ~= N then
            if object.entityId ~= N then return "entity:" .. object.entityId end
            if object.runtimeObjectId and object.runtimeObjectId ~= N then return "runtime:" .. object.runtimeObjectId end
            if object.dcsObjectId ~= N then return "dcs:" .. object.dcsObjectId end
        end
        return "unresolved" -- Repeated anonymous wrappers do not prove a target change.
    end
    local function updateMissile(entry, time)
        entry.record.motion = motion(entry, time, self.missileSeq)
        local previous, observed = entry.record.targetObservation, target(entry, time)
        entry.record.targetObservation = observed
        if observed.status == "object" then entry.record.lastKnownTarget = copy(observed) end
        if (observed.status == "object" or observed.status == "none_reported") and previous.sampledSimTime ~= N and
            targetIdentity(previous) ~= targetIdentity(observed) then
            emit("target_observation_changed", time, entry.record.launch.launcher.object, observed.object,
                reference(entry.object, time, "missile"), { missileEntityId = entry.entityId,
                    previous = previous, current = observed })
        end
    end
    local function sampleEntries(entries, time, update)
        local list = {}; for _, entry in pairs(entries) do list[#list + 1] = entry end
        for _, entry in ipairs(list) do
            local ok, exists = method(entry.object, "isExist")
            if ok and exists == false then self.remove(entry, "object_gone", time)
            else
                if not ok or exists ~= true then entry.failures = entry.failures + 1 else entry.failures = 0 end
                if entry.failures >= self.maxReadFailures then
                    if entry.kind == "missile" then self.missileComplete = false else self.inventoryComplete = false end
                    self.remove(entry, "tracking_lost", time)
                else update(entry, time) end
            end
        end
    end
    self.tick = function(time)
        if self.status ~= "ready" and self.status ~= "degraded" then return end
        time = finite(time) and time or now()
        local sampling = self.config.sampling
        local function due(key, interval)
            if time + 1e-7 < self[key] then return false end
            if time > self[key] + interval then self.samplingOverrunCount = self.samplingOverrunCount + 1 end
            self[key] = time + interval
            return true
        end
        if due("nextReconcile", sampling.reconcileIntervalSec) then reconcile(time) end
        local slowDue = due("nextSlow", 1 / sampling.slowFieldsHz)
        if due("nextAircraft", 1 / sampling.aircraftHz) then
            self.aircraftSeq = self.aircraftSeq + 1
            sampleEntries(self.aircraft, time, function(entry)
                entry.record.motion = motion(entry, time, self.aircraftSeq)
            end)
        end
        for _, entry in pairs(self.aircraft) do if slowDue or entry.dirty then sampleSlow(entry, time) end end
        if due("nextMissile", 1 / sampling.missileHz) then
            self.missileSeq = self.missileSeq + 1; sampleEntries(self.missiles, time, updateMissile)
        end
    end
    local function capabilities()
        return { aircraftMotion = type(env.Object and env.Object.getVelocity) == "function" and
                type(env.Object and env.Object.getPoint) == "function",
            aircraftFuel = type(env.Unit and env.Unit.getFuel) == "function",
            aircraftArmament = type(env.Unit and env.Unit.getAmmo) == "function",
            playerOccupancy = type(env.Unit and env.Unit.getPlayerName) == "function",
            missileTracking = type(env.world and env.world.addEventHandler) == "function" and
                type(env.Weapon and env.Weapon.Category) == "table",
            weaponLauncherQuery = type(env.Weapon and env.Weapon.getLauncher) == "function",
            weaponTargetQuery = type(env.Weapon and env.Weapon.getTarget) == "function" }
    end
    local function coverageIssues()
        local result = A()
        for code in pairs(self.persistentIssues) do issue(result, code) end
        if not self.inventoryComplete then issue(result, "inventory_partial") end
        if not self.missileComplete then issue(result, "missile_inventory_partial") end
        if not self.continuous then issue(result, "capture_continuity_unknown") end
        table.sort(result)
        return result
    end
    local function health()
        local issues = coverageIssues()
        if self.lostThrough > self.ackEventSeq then issue(issues, "event_buffer_overflow") end
        if self.incompleteLauncherCount > 0 then issue(issues, "launcher_incomplete") end
        for _, entry in pairs(self.aircraft) do
            for _, key in ipairs({ "motion", "occupancy", "fuel", "armament" }) do
                local block = entry.record[key]
                if block.status ~= "ok" then issue(issues, key .. "_incomplete") end
            end
        end
        for _, entry in pairs(self.missiles) do
            if entry.record.motion.status ~= "ok" then issue(issues, "missile_motion_incomplete") end
            if entry.record.targetObservation.status == "stale" or entry.record.targetObservation.status == "unavailable" then
                issue(issues, "target_query_failed")
            end
            if #entry.record.targetObservation.issues > 0 then issue(issues, "target_observation_incomplete") end
        end
        local available = capabilities()
        for _, key in ipairs({ "aircraftMotion", "aircraftFuel", "aircraftArmament", "playerOccupancy", "missileTracking", "weaponTargetQuery" }) do
            if not available[key] then issue(issues, key .. "_api_unavailable") end
        end
        if self.status == "ready" or self.status == "degraded" then self.status = #issues == 0 and "ready" or "degraded" end
        return { eventBufferCount = self.eventTail - self.eventHead + 1, eventBufferBytesEstimate = self.eventBytes,
            gapRangeCount = self.lostThrough > self.ackEventSeq and 1 or 0,
            captureErrorCount = self.captureErrorCount, samplingErrorCount = self.samplingErrorCount,
            captureContinuous = self.continuous, rejectedRecordCount = self.rejectedRecordCount,
            samplingOverrunCount = self.samplingOverrunCount, droppedEventCount = self.droppedEventCount,
            incompleteLauncherCount = self.incompleteLauncherCount, aircraftCount = count(self.aircraft),
            missileCount = count(self.missiles), issues = issues, capabilities = available }
    end
    local function defaults()
        return { revision = 1, scope = { coalitions = A({ "red", "blue", "neutral" }), includeAirplanes = true,
            includeHelicopters = false, missileScope = "all" }, sampling = { aircraftHz = 1, missileHz = 1,
            slowFieldsHz = 1, reconcileIntervalSec = 5 }, eventBuffer = { maxCount = 10000, maxBytes = 16777216 } }
    end
    local function normalizeConfig(config)
        requiredObject(config, "config")
        local result = defaults()
        if not integer(config.revision) or config.revision < 1 then fail("INVALID_REQUEST", "Invalid config revision") end
        result.revision = config.revision
        for _, section in ipairs({ "scope", "sampling", "eventBuffer" }) do
            if config[section] ~= nil then
                requiredObject(config[section], "config." .. section)
                for key in pairs(result[section]) do if config[section][key] ~= nil then result[section][key] = copy(config[section][key]) end end
            end
        end
        local scope = result.scope
        if not Json.isArray(scope.coalitions) or #scope.coalitions < 1 or #scope.coalitions > 3 then fail("INVALID_REQUEST", "Invalid coalitions") end
        local seen = {}
        for _, side in ipairs(scope.coalitions) do
            if (side ~= "red" and side ~= "blue" and side ~= "neutral") or seen[side] then fail("INVALID_REQUEST", "Invalid/duplicate coalition") end
            seen[side] = true
        end
        if type(scope.includeAirplanes) ~= "boolean" or type(scope.includeHelicopters) ~= "boolean" or
            (scope.missileScope ~= "all" and scope.missileScope ~= "air_launched") then fail("INVALID_REQUEST", "Invalid scope") end
        for key, value in pairs(result.sampling) do
            if not finite(value) or value <= 0 then fail("INVALID_REQUEST", "Invalid sampling frequency/interval") end
            if key == "reconcileIntervalSec" then result.sampling[key] = math.max(value, 0.2)
            elseif key == "slowFieldsHz" then result.sampling[key] = math.min(value, 10)
            else result.sampling[key] = math.min(value, 60) end
        end
        for _, key in ipairs({ "maxCount", "maxBytes" }) do
            if not integer(result.eventBuffer[key]) or result.eventBuffer[key] < 1 then fail("INVALID_REQUEST", "Invalid event buffer limit") end
        end
        result.eventBuffer.maxCount = math.min(result.eventBuffer.maxCount, 100000)
        result.eventBuffer.maxBytes = math.min(result.eventBuffer.maxBytes, 134217728)
        return result
    end
    local function initialize(request)
        local config = normalizeConfig(request.config)
        if self.status == "stopped" then fail("COLLECTOR_STOPPED") end
        if self.config and Json.encode(config) ~= Json.encode(self.config) then fail("CONFIG_CONFLICT") end
        if not self.config then
            if config.revision ~= 1 then fail("INVALID_REQUEST", "Initial revision must be 1") end
            if type(env.world and env.world.addEventHandler) ~= "function" or type(env.world.event) ~= "table" or
                type(env.timer and env.timer.scheduleFunction) ~= "function" or type(env.timer.getTime) ~= "function" or
                type(env.coalition and env.coalition.getGroups) ~= "function" or type(env.Group and env.Group.Category) ~= "table" or
                type(env.coalition.side) ~= "table" then fail("NOT_READY", "Mission APIs unavailable", true) end
            self.config = config; self.configRevision = 1; self.scopeRevision = 1; self.status = "initializing"
            self.captureStartedSimTime = now()
        end
        if self.status == "initializing" then
            if not self.handlerRegistered then
                self.handler = { onEvent = function(_, event) self.onEvent(event) end }
                local ok = invoke(env.world.addEventHandler, self.handler)
                if not ok then fail("NOT_READY", "Could not register event handler", true) end
                self.handlerRegistered = true
            end
            reconcile(now())
            for _, entry in pairs(self.aircraft) do entry.record.discovery = "initial_scan" end
            self.baselineCompletedSimTime = now()
            if not self.timerId then
                local ok, id = invoke(env.timer.scheduleFunction, function()
                    if self.status == "stopped" then return nil end
                    local time = now()
                    local tickOk = pcall(self.tick, time)
                    if not tickOk then self.samplingErrorCount = self.samplingErrorCount + 1; self.persistentIssues.sampling_callback_failed = true end
                    local s = self.config.sampling
                    return time + math.min(1 / s.aircraftHz, 1 / s.missileHz, 1 / s.slowFieldsHz, s.reconcileIntervalSec)
                end, nil, now() + 0.001)
                if not ok or id == nil then fail("NOT_READY", "Could not schedule sampler", true) end
                self.timerId = id
            end
            self.nextAircraft = now(); self.nextMissile = now(); self.nextSlow = now()
            self.nextReconcile = now() + self.config.sampling.reconcileIntervalSec
            self.status = "ready"
        end
        health()
        return { collectorVersion = self.collectorVersion, status = self.status, configRevision = self.configRevision,
            scopeRevision = self.scopeRevision, acceptedConfig = copy(self.config), captureStartedSimTime = self.captureStartedSimTime,
            baselineCompletedSimTime = self.baselineCompletedSimTime, capabilities = capabilities(),
            coverage = { aircraft = "initial_scan_and_events", missiles = "shots_since_capture_start", events = "since_capture_start",
                continuous = self.continuous, issues = coverageIssues() },
            eventLog = { ackEventSeq = self.ackEventSeq, latestEventSeq = self.latestEventSeq }, limits = copy(self.limits) }
    end
    local function ack(sequence)
        if sequence <= self.ackEventSeq then return end
        self.ackEventSeq = sequence
        while self.eventHead <= self.eventTail and self.events[self.eventHead].record.eventSeq <= sequence do
            self.eventBytes = self.eventBytes - self.events[self.eventHead].bytes
            self.events[self.eventHead] = nil; self.eventHead = self.eventHead + 1
        end
        compactLog()
    end
    local function newSnapshot(budget, withEvents)
        local records = {}
        for _, entries in ipairs({ self.aircraft, self.missiles }) do
            for _, entry in pairs(entries) do records[#records + 1] = copy(entry.record) end
        end
        table.sort(records, function(a, b) return a.entityId < b.entityId end)
        local stateBudget = math.floor((budget - 8192) * (withEvents and 0.5 or 1))
        local groups, current, bytes = {}, A(), 4096
        local excluded, excludedCount = A(), 0
        for _, record in ipairs(records) do
            local encoded = Json.encode(record)
            encodedTables[record] = encoded
            local size = #encoded
            if size > self.limits.maxRecordBytes then
                excludedCount = excludedCount + 1
                if #excluded < 16 then excluded[#excluded + 1] = { entityId = record.entityId,
                    kind = record.kind, reason = "record_too_large", originalBytes = size } end
            else
            if size + 1024 > stateBudget then fail("RESPONSE_BUDGET_TOO_SMALL", "Entity cannot fit state page") end
            if bytes + size + 1 > stateBudget and #current > 0 then groups[#groups + 1] = current; current = A(); bytes = 4096 end
            current[#current + 1] = record; bytes = bytes + size + 1
            end
        end
        if #current > 0 or #groups == 0 then groups[#groups + 1] = current end
        self.nextSnapshot = self.nextSnapshot + 1
        local id = self.collectorEpoch .. ":snapshot:" .. self.nextSnapshot
        local pages, cursors = {}, {}
        local time, watermark = now(), self.latestEventSeq
        local issues = coverageIssues()
        if excludedCount > 0 then issue(issues, "oversized_entities_excluded") end
        for index, group in ipairs(groups) do
            local nextCursor = index < #groups and id .. ":page:" .. index or N
            pages[index] = { snapshotId = id, pageIndex = index - 1, pageCount = #groups, nextCursor = nextCursor,
                assembledSimTime = time, eventSeqAtCapture = watermark, scopeRevision = self.scopeRevision,
                coverage = { aircraftInventory = self.inventoryComplete and excludedCount == 0 and "complete" or "partial",
                    missileInventory = self.missileComplete and excludedCount == 0 and "tracked_since_capture_start" or "partial",
                    captureStartedSimTime = self.captureStartedSimTime, issues = issues,
                    excludedEntityCount = excludedCount, excludedEntities = excluded }, entities = group }
            encodedTables[pages[index]] = encodeResponse(pages[index])
            if nextCursor ~= N then cursors[nextCursor] = index + 1 end
        end
        self.snapshot = { pages = pages, cursors = cursors, budget = budget }
        return pages[1]
    end
    local function validateExchange(request)
        requiredObject(request.read, "read")
        requiredObject(request.read.state, "read.state"); requiredObject(request.read.events, "read.events")
        local state, events = request.read.state, request.read.events
        if type(state.enabled) ~= "boolean" or type(events.enabled) ~= "boolean" then fail("INVALID_REQUEST", "Invalid read flags") end
        local budget = self.limits.maxResponseBytes
        if request.limits ~= nil then
            requiredObject(request.limits, "limits")
            if request.limits.maxResponseBytes ~= nil then budget = request.limits.maxResponseBytes end
        end
        if not integer(budget) or budget < 65536 or budget > self.limits.maxResponseBytes then fail("INVALID_REQUEST", "Invalid response budget") end
        local submitted = request.ackEventSeq
        if submitted ~= nil and (not integer(submitted) or submitted > self.deliveredThrough) then fail("INVALID_ACK") end
        local effectiveAck = math.max(self.ackEventSeq, submitted or 0)
        if state.enabled then
            if state.cursor == nil or (state.cursor ~= N and type(state.cursor) ~= "string") then fail("INVALID_REQUEST", "State cursor required") end
            if state.cursor ~= N and (not self.snapshot or not self.snapshot.cursors[state.cursor]) then fail("STALE_CURSOR", nil, true) end
        end
        local after = events.afterSeq
        if after == nil then after = effectiveAck end
        local maxCount = events.maxCount or 128
        if events.enabled then
            if not integer(after) or after > self.latestEventSeq then fail("INVALID_EVENT_CURSOR") end
            if after < effectiveAck then fail("CURSOR_BEFORE_ACK") end
            if not integer(maxCount) or maxCount < 1 or maxCount > 512 then fail("INVALID_REQUEST", "Invalid event batch size") end
        end
        return budget, after, maxCount
    end
    local function exchange(request, response)
        local budget, after, maxCount = validateExchange(request)
        if request.ackEventSeq ~= nil then ack(request.ackEventSeq) end
        local state = N
        if request.read.state.enabled then
            if request.read.state.cursor == N then state = newSnapshot(budget, request.read.events.enabled)
            else state = self.snapshot.pages[self.snapshot.cursors[request.read.state.cursor]] end
        end
        local result = { collectorSimTime = now(), status = self.status, configRevision = self.configRevision,
            scopeRevision = self.scopeRevision, ackEventSeq = self.ackEventSeq, state = state, eventLog = N, health = health(),
            finalEventSeq = self.status == "stopped" and self.latestEventSeq or N, stopReason = self.stopReason or N }
        result.status = self.status; response.data = result
        if #encodeResponse(response) > budget then fail("RESPONSE_BUDGET_TOO_SMALL", "Frozen state page exceeds budget") end
        if request.read.events.enabled then
            local batch = { afterSeq = after, throughSeq = after, latestEventSeq = self.latestEventSeq,
                hasMore = after < self.latestEventSeq, gaps = A(), events = A() }
            result.eventLog = batch
            -- Bound work by the encoded item sizes, rather than re-encoding the
            -- entire state page for every event in an accumulated batch.
            local encodedBytes = #encodeResponse(response) + 64
            local added = 0
            local function add(item, isGap, cachedSize, cachedJson)
                if added >= maxCount then return false end
                local list = isGap and batch.gaps or batch.events
                local itemSize = cachedSize or #Json.encode(item)
                if not isGap and itemSize > self.limits.maxRecordBytes then fail("RECORD_TOO_LARGE", "Event exceeds record limit") end
                if encodedBytes + itemSize + 1 > budget then
                    if added == 0 then fail("RESPONSE_BUDGET_TOO_SMALL", "No pending log item fits with state") end
                    return false
                end
                local frozen = copy(item)
                list[#list + 1] = frozen
                if cachedJson then encodedTables[frozen] = cachedJson end
                batch.throughSeq = isGap and item.toSeq or item.eventSeq
                batch.hasMore = batch.throughSeq < self.latestEventSeq
                encodedBytes = encodedBytes + itemSize + 1
                added = added + 1
                return true
            end
            local continue = true
            if after < self.lostThrough then continue = add({ fromSeq = after + 1, toSeq = self.lostThrough, reason = "buffer_overflow" }, true) end
            if continue then
                for index = self.eventHead, self.eventTail do
                    local item = self.events[index].record
                    if item.eventSeq > batch.throughSeq and not add(item, false, self.events[index].bytes, self.events[index].encoded) then break end
                end
            end
            if #encodeResponse(response) > budget then fail("RESPONSE_BUDGET_TOO_SMALL", "Encoded response exceeds budget") end
            self.deliveredThrough = math.max(self.deliveredThrough, batch.throughSeq)
        end
        return result
    end
    local function configure(request)
        local config = normalizeConfig(request.config)
        if self.status == "stopped" then fail("COLLECTOR_STOPPED") end
        if config.revision == self.configRevision and Json.encode(config) == Json.encode(self.config) then
            return { configRevision = self.configRevision, scopeRevision = self.scopeRevision,
                acceptedConfig = copy(self.config), scopeChanged = false }
        end
        if request.baseRevision ~= self.configRevision or config.revision ~= self.configRevision + 1 then fail("CONFIG_CONFLICT") end
        local changed = Json.encode(config.scope) ~= Json.encode(self.config.scope)
        self.config = config; self.configRevision = config.revision
        if changed then
            self.scopeRevision = self.scopeRevision + 1; self.snapshot = nil
            for id, entry in pairs(self.aircraft) do
                if not aircraftAllowed(entry.object) then self.aircraft[id] = nil; entry.active = false end
            end
            for id, entry in pairs(self.missiles) do
                local firing = entry.record.launch.launcher.object
                if not sideAllowed(entry.record.coalition) or (config.scope.missileScope == "air_launched" and
                    (firing == N or firing.kind ~= "aircraft")) then self.missiles[id] = nil; entry.active = false end
            end
            self.missileComplete = false; self.persistentIssues.scope_change_missile_coverage = true
            reconcile(now())
        end
        local time = now()
        self.nextAircraft = time; self.nextMissile = time; self.nextSlow = time; self.nextReconcile = time
        trimLog(); compactLog()
        return { configRevision = self.configRevision, scopeRevision = self.scopeRevision,
            acceptedConfig = copy(self.config), scopeChanged = changed }
    end
    shutdown = function(reason)
        if self.status ~= "stopped" then
            local entries = {}; for _, entry in pairs(self.missiles) do entries[#entries + 1] = entry end
            for _, entry in ipairs(entries) do self.remove(entry, "collector_stopped", now()) end
            self.status = "stopped"; self.stoppedSimTime = now(); self.stopReason = reason or "hook_shutdown"
            if self.handlerRegistered then invoke(env.world.removeEventHandler, self.handler); self.handlerRegistered = false end
            if self.timerId then invoke(env.timer.removeFunction, self.timerId) end
        end
        return { status = "stopped", stoppedSimTime = self.stoppedSimTime, ackEventSeq = self.ackEventSeq,
            latestEventSeq = self.latestEventSeq, stopReason = self.stopReason,
            hasUnacknowledgedLog = self.latestEventSeq > self.ackEventSeq }
    end
    self.request = function(request)
        local response = { protocolVersion = 1, requestId = objectTable(request) and stringValue(request.requestId) or N,
            op = objectTable(request) and stringValue(request.op) or N, ok = true,
            missionSessionId = self.missionSessionId, collectorEpoch = self.collectorEpoch }
        local ok, result = pcall(function()
            requiredObject(request, "request")
            if request.protocolVersion ~= 1 then fail("PROTOCOL_MISMATCH") end
            if type(request.requestId) ~= "string" or request.requestId == "" or #request.requestId > 256 or
                type(request.op) ~= "string" or #request.op > 32 then fail("INVALID_REQUEST") end
            if request.op ~= "probe" or request.missionSessionId ~= nil or request.collectorEpoch ~= nil then
                if request.missionSessionId ~= self.missionSessionId then fail("SESSION_MISMATCH") end
                if request.collectorEpoch ~= self.collectorEpoch then fail("EPOCH_MISMATCH") end
            end
            if request.op == "probe" then
                return { collectorVersion = self.collectorVersion, status = self.status, collectorSimTime = now(),
                    configRevision = self.configRevision, scopeRevision = self.scopeRevision,
                    ackEventSeq = self.ackEventSeq, latestEventSeq = self.latestEventSeq }
            end
            if request.op == "initialize" then return initialize(request) end
            if request.op ~= "exchange" and request.op ~= "configure" and request.op ~= "shutdown" then fail("INVALID_REQUEST", "Unknown operation") end
            if not self.config or self.status == "initializing" then fail("NOT_READY", nil, true) end
            if request.op == "exchange" then return exchange(request, response) end
            if request.op == "configure" then return configure(request) end
            return shutdown()
        end)
        if ok then response.data = result
        else
            response.data = nil; response.ok = false
            local expected = type(result) == "table" and result.code
            response.error = { code = expected and result.code or "INTERNAL_ERROR",
                message = expected and result.message or "Collector operation failed",
                retryable = expected and result.retryable or false, context = { ackEventSeq = self.ackEventSeq } }
        end
        return response
    end
    self.handleJson = function(text)
        local ok, decoded = pcall(Json.decode, text)
        if not ok then
            return Json.encode({ protocolVersion = 1, requestId = N, op = N, ok = false,
                missionSessionId = self.missionSessionId, collectorEpoch = self.collectorEpoch,
                error = { code = "INVALID_REQUEST", message = "Malformed JSON", retryable = false, context = { ackEventSeq = self.ackEventSeq } } })
        end
        local response = self.request(decoded)
        local encodedOk, encoded = pcall(encodeResponse, response)
        if encodedOk then return encoded end
        return Json.encode({ protocolVersion = 1, requestId = stringValue(decoded.requestId), op = stringValue(decoded.op),
            ok = false, missionSessionId = self.missionSessionId, collectorEpoch = self.collectorEpoch,
            error = { code = "INTERNAL_ERROR", message = "Response encoding failed", retryable = false,
                context = { ackEventSeq = self.ackEventSeq } } })
    end
    return self
end

return Collector
