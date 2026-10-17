-- Hook-side bridge. All simulator execution is injected through net.dostring_in.
-- A separate Hook transport forwards explicit, mode-scoped server receipts.
local Bridge = {}
Bridge.__index = Bridge
local FRAME, PAD = "DCS_ESPORT_V1:", "DCS_ESPORT_RETURN_PADDING"

local function quote(value) return string.format("%q", value) end
local function finite(value) return type(value) == "number" and value == value and math.abs(value) < math.huge end
local function integer(value) return finite(value) and value >= 0 and value % 1 == 0 and value <= 9007199254740991 end
local function sameSource(a, b)
    return a and b and a.missionSessionId == b.missionSessionId and a.collectorEpoch == b.collectorEpoch
end

function Bridge.new(deps, config)
    assert(deps and deps.Json and deps.net and deps.now and deps.jsonSource and deps.collectorSource)
    config = config or {}
    assert(config.pollHz == nil or (finite(config.pollHz) and config.pollHz > 0 and config.pollHz <= 60), "pollHz must be in (0, 60]")
    assert(config.maxResponseBytes == nil or (integer(config.maxResponseBytes) and config.maxResponseBytes >= 65536 and
        config.maxResponseBytes <= 262144), "maxResponseBytes must be between 65536 and 262144")
    assert(config.maxPendingItems == nil or (integer(config.maxPendingItems) and config.maxPendingItems >= 1 and
        config.maxPendingItems <= 100000), "Invalid maxPendingItems")
    assert(config.maxPendingBytes == nil or (integer(config.maxPendingBytes) and config.maxPendingBytes >= 131072 and
        config.maxPendingBytes <= 134217728), "maxPendingBytes must be between 131072 and 134217728")
    assert(config.stopDrainMaxBatches == nil or (integer(config.stopDrainMaxBatches) and
        config.stopDrainMaxBatches >= 1 and config.stopDrainMaxBatches <= 1024), "Invalid stopDrainMaxBatches")
    assert(config.stopDrainBudgetSec == nil or (finite(config.stopDrainBudgetSec) and
        config.stopDrainBudgetSec > 0 and config.stopDrainBudgetSec <= 2), "Invalid stopDrainBudgetSec")
    -- Configuration is trusted Lua, while protocol arrays carry an explicit JSON tag.
    if config.collector and config.collector.scope and type(config.collector.scope.coalitions) == "table" then
        config = deps.Json.copy(config)
        config.collector.scope.coalitions = deps.Json.array(config.collector.scope.coalitions)
    end
    local self = setmetatable({ deps = deps, Json = deps.Json, config = config, phase = "waiting",
        active = false, paused = false, route = nil, nextAction = 0, requestNumber = 0,
        missionNumber = 0, epochNumber = 0, failureCount = 0, pending = {}, pendingBytes = 0, pendingCount = 0,
        retainedSessions = {},
        readThrough = 0, confirmedSeq = 0, actualAck = 0, snapshot = nil, latestState = nil,
        bootId = config.bootId or ("hook-" .. tostring(os.time()) .. "-" .. tostring({}):gsub("[^%w]", "")),
        lastError = nil, nextManualAck = 0 }, Bridge)
    return self
end

function Bridge:_notice(message)
    if self.deps.log then pcall(self.deps.log, message) end
end

function Bridge:_sink(name, ...)
    local sink = self.deps.sink
    if not sink or type(sink[name]) ~= "function" then return true end
    local ok, result, err = pcall(sink[name], sink, ...)
    if not ok then return false, tostring(result) end
    if result == false then return false, err or (name .. " rejected data") end
    return true
end

-- Diagnostics observe accepted data. They never gate delivery, ACK or retries.
function Bridge:_observe(name, ...)
    local observer = self.deps.observer
    if not observer or type(observer[name]) ~= "function" then return end
    local ok, result, err = pcall(observer[name], observer, ...)
    if ok and result ~= false then return end
    local message = name .. ": " .. tostring(ok and (err or "diagnostic rejected data") or result)
    self.diagnosticErrorCount = (self.diagnosticErrorCount or 0) + 1
    self.lastDiagnosticError = message
    self.diagnosticErrors = self.diagnosticErrors or {}
    if self.diagnosticErrors[name] ~= message then self:_notice("Diagnostic output failed: " .. message) end
    self.diagnosticErrors[name] = message
end

function Bridge:_evaluate(body, route)
    route = route or self.route
    if not route then return nil, "No verified mission route" end
    -- Padding protects against a_do_script implementations shifting/dropping a return.
    -- Only the framed business string is selected; booleans/errors are never payloads.
    local inner = "local __v=(function()\n" .. body .. "\nend)(); " ..
        "if type(__v)~='string' then error('Expected bridge string') end; return " .. quote(FRAME) .. "..__v," .. quote(PAD)
    local source = inner
    if route.nested then
        source = "local a,b,c,d=a_do_script(" .. quote(inner) .. "); local v={a,b,c,d}; " ..
            "for i=1,4 do if type(v[i])=='string' and string.sub(v[i],1," .. #FRAME .. ")==" .. quote(FRAME) ..
            " then return v[i] end end; return 'DCS_ESPORT_NO_RETURN'"
    end
    local ok, a, b, c, d, e = pcall(self.deps.net.dostring_in, route.environment, source)
    if not ok then return nil, "net.dostring_in failed: " .. tostring(a) end
    local values = { a, b, c, d, e }
    for index = 1, 5 do
        local value = values[index]
        if type(value) == "string" and value:sub(1, #FRAME) == FRAME then return value:sub(#FRAME + 1) end
    end
    return nil, "No framed return from " .. route.name
end

function Bridge:_detectRoute()
    local routes = {
        { name = "mission_a_do_script", environment = "mission", nested = true },
        { name = "mission_direct", environment = "mission", nested = false },
        { name = "server_direct", environment = "server", nested = false }
    }
    local nonce = self.bootId .. ":probe:" .. self.requestNumber
    local body = "if type(world)=='table' and type(world.addEventHandler)=='function' and " ..
        "type(world.event)=='table' and type(timer)=='table' and type(timer.getTime)=='function' and " ..
        "type(timer.scheduleFunction)=='function' and type(coalition)=='table' and type(coalition.getGroups)=='function' " ..
        "then return " .. quote(nonce) .. " else return 'NOT_MISSION' end"
    for _, route in ipairs(routes) do
        if not self.config.route or self.config.route == "auto" or self.config.route == route.name then
            local value = self:_evaluate(body, route)
            if value == nonce then self.route = route; return true end
        end
    end
    return false, "Mission environment/return path not ready"
end

function Bridge:_request(op, parameters, discovery)
    self.requestNumber = self.requestNumber + 1
    local request = self.Json.copy(parameters or {})
    request.protocolVersion = 1; request.requestId = self.bootId .. ":request:" .. self.requestNumber; request.op = op
    if not discovery then
        request.missionSessionId = self.source.missionSessionId; request.collectorEpoch = self.source.collectorEpoch
    end
    local text = self.Json.encode(request)
    local body = "if type(DcsEsportCollector)~='table' or type(DcsEsportCollector.handleJson)~='function' then return 'ABSENT' end; " ..
        "return DcsEsportCollector.handleJson(" .. quote(text) .. ")"
    local raw, err = self:_evaluate(body)
    if not raw then return nil, err end
    if raw == "ABSENT" then return nil, "COLLECTOR_ABSENT" end
    local decodedOk, response = pcall(self.Json.decode, raw)
    if not decodedOk or type(response) ~= "table" or response == self.Json.null or response.protocolVersion ~= 1 or
        response.requestId ~= request.requestId or response.op ~= op or type(response.ok) ~= "boolean" then
        return nil, "Invalid collector response"
    end
    if not discovery and not sameSource(self.source, response) then return nil, "SOURCE_CHANGED" end
    if not response.ok then return nil, response.error and response.error.code or "Collector error", response end
    return response
end

function Bridge:_pendingUsage()
    local items, bytes = self.pendingCount, self.pendingBytes
    for _, session in ipairs(self.retainedSessions) do items = items + session.pendingCount; bytes = bytes + session.pendingBytes end
    return items, bytes
end

function Bridge:_retainPending()
    if self.pendingCount > 0 then
        self.retainedSessions[#self.retainedSessions + 1] = {
            source = self.Json.copy(self.pendingSource or self.source), pending = self.pending,
            pendingCount = self.pendingCount, pendingBytes = self.pendingBytes,
            readThrough = self.readThrough, confirmedSeq = self.confirmedSeq, actualAck = self.actualAck,
            sessionEnd = self.lastSessionEnd and self.Json.copy(self.lastSessionEnd) or self.Json.null }
    end
    self.pending = {}; self.pendingCount = 0; self.pendingBytes = 0
end

function Bridge:_newEpoch()
    self:_retainPending()
    self.epochNumber = self.epochNumber + 1
    self.source.collectorEpoch = self.bootId .. ":collector:" .. self.epochNumber
    self.pendingSource = self.Json.copy(self.source)
    self.readThrough = 0; self.confirmedSeq = 0; self.actualAck = 0
    self.snapshot = nil; self.latestState = nil; self.installed = false
    self.stateCursor = nil; self.lastHealth = nil
    self.splitReads = false; self.splitNextEvents = false
    self.diagnosticErrorCount = 0; self.lastDiagnosticError = nil; self.diagnosticErrors = {}
    self.finalEventSeq = nil; self.lastSessionEnd = nil; self.endReport = nil
    self.finalAckAttempts = 0; self.finalAckFailures = 0; self.finalAckError = nil; self.finalAckClosed = false
    self.nextFinalAck = 0; self.lastHealthAt = nil
    self.tailFailures = 0
    self.exchangeMetrics = { calls = 0, lastCpuMs = 0, maxCpuMs = 0 }
end

function Bridge:startMission()
    if self.active then
        if self.phase ~= "draining" then return false, "Mission already active" end
        self:_finishSession(false, "mission_environment_replaced")
    end
    if self.lastSessionEnd and self.finalEventSeq and self.actualAck < self.finalEventSeq then
        self.finalAckClosed = true; self.finalAckError = "mission_environment_replaced"
        self:_refreshEnd()
    end
    self.missionNumber = self.missionNumber + 1
    self.source = { missionSessionId = self.bootId .. ":mission:" .. self.missionNumber }
    self:_newEpoch()
    self.active = true; self.paused = false; self.phase = "probing"; self.route = nil
    self.failureCount = 0; self.nextAction = self.deps.now(); self.lastError = nil
    self:_notice("Mission probe started")
    return true
end

function Bridge:_install()
    local source = "if DcsEsportCollector~=nil then return 'EXISTS' end; " ..
        "local Json=(function()\n" .. self.deps.jsonSource .. "\nend)(); " ..
        "local Collector=(function()\n" .. self.deps.collectorSource .. "\nend)(); " ..
        "DcsEsportCollector=Collector.new(getfenv(1),Json,{missionSessionId=" .. quote(self.source.missionSessionId) ..
        ",collectorEpoch=" .. quote(self.source.collectorEpoch) .. "}); return 'INSTALLED'"
    local result, err = self:_evaluate(source)
    if result == "INSTALLED" then self.installed = true; self.phase = "initializing"; return true end
    if result == "EXISTS" then self.phase = "inspecting"; return true end
    -- An ambiguous injection return is resolved by inspection, never unconditional reinstallation.
    self.phase = "inspecting"
    return false, err or "Injection return was not verified"
end

function Bridge:_inspect()
    local response, err = self:_request("probe", nil, true)
    if not response then
        if err == "COLLECTOR_ABSENT" then
            if self.installed then
                local recorded, recordingError = self:_sink("onDiscontinuity", self.Json.copy(self.source), "collector_lost")
                if not recorded then return false, recordingError end
                self:_observe("onDiscontinuity", self.Json.copy(self.source), "collector_lost")
                self:_newEpoch()
            end
            self.phase = "installing"; return true
        end
        return false, err
    end
    if response.data.collectorVersion ~= "0.1.5" then return false, "COLLECTOR_VERSION_MISMATCH" end
    if not sameSource(self.source, response) then
        if not sameSource(self.config.resumeSource, response) then
            self.phase = "verification_required"
            return false, "SOURCE_VERIFICATION_REQUIRED: existing collector preserved"
        end
        self:_retainPending()
        self.source = { missionSessionId = response.missionSessionId, collectorEpoch = response.collectorEpoch }
        self.pendingSource = self.Json.copy(self.source)
        self.readThrough = 0; self.confirmedSeq = 0; self.actualAck = 0
    end
    self.installed = true
    if response.data.status == "stopped" then
        if not integer(response.data.latestEventSeq) then return false, "Invalid final event sequence" end
        self.finalEventSeq = response.data.latestEventSeq; self.phase = "draining"; return true
    end
    self.phase = "initializing"
    return true
end

function Bridge:_initialize()
    local response, err = self:_request("initialize", { config = self.config.collector or { revision = 1 } })
    if not response then return false, err end
    local data = response.data
    if not integer(data.eventLog.ackEventSeq) or not integer(data.limits.maxResponseBytes) then return false, "Invalid initialize metadata" end
    self.actualAck = data.eventLog.ackEventSeq
    self.confirmedSeq = math.max(self.confirmedSeq, self.actualAck)
    -- A reconnect rereads unconfirmed data; no delivery cursor is treated as an ACK.
    if self.readThrough < self.actualAck then self.readThrough = self.actualAck end
    self.responseBudget = math.min(self.config.maxResponseBytes or 262144, data.limits.maxResponseBytes)
    self.acceptedConfig = data.acceptedConfig; self.phase = "collecting"
    local accepted, acceptanceError = self:_sink("onInitialized", self.Json.copy(response))
    if not accepted then return false, acceptanceError end
    self:_observe("onInitialized", self.Json.copy(response))
    return true
end

local function batchCount(batch) return #batch.events + #batch.gaps end

function Bridge:_acceptEvents(batch)
    if batch == self.Json.null then return true end
    if batch.afterSeq ~= self.readThrough or not integer(batch.throughSeq) or batch.throughSeq < batch.afterSeq or
        batch.throughSeq > batch.latestEventSeq or not self.Json.isArray(batch.events) or not self.Json.isArray(batch.gaps) then
        return false, "Invalid event batch bounds"
    end
    local intervals = {}
    for _, event in ipairs(batch.events) do
        if not integer(event.eventSeq) then return false, "Invalid event sequence" end
        intervals[#intervals + 1] = { event.eventSeq, event.eventSeq }
    end
    for _, gap in ipairs(batch.gaps) do
        if not integer(gap.fromSeq) or not integer(gap.toSeq) or gap.toSeq < gap.fromSeq then return false, "Invalid gap" end
        intervals[#intervals + 1] = { gap.fromSeq, gap.toSeq }
    end
    table.sort(intervals, function(a, b) return a[1] < b[1] end)
    local through = batch.afterSeq
    for _, range in ipairs(intervals) do
        if range[1] ~= through + 1 then return false, "Non-contiguous or overlapping event batch" end
        through = range[2]
    end
    if through ~= batch.throughSeq then return false, "Event batch has a hidden gap" end
    if through == self.readThrough then return true end
    local bytes, items = #self.Json.encode(batch), batchCount(batch)
    local pendingItems, pendingBytes = self:_pendingUsage()
    if pendingBytes + bytes > (self.config.maxPendingBytes or 8388608) or
        pendingItems + items > (self.config.maxPendingItems or 2048) then return false, "Hook pending buffer full" end
    local accepted, err = true, nil
    if self.deps.sink and type(self.deps.sink.onEvents) == "function" then
        accepted, err = self:_sink("onEvents", self.Json.copy(self.source), self.Json.copy(batch))
    end
    if not accepted then return false, err end
    self.pending[#self.pending + 1] = { batch = self.Json.copy(batch), bytes = bytes, items = items }
    self.pendingBytes = self.pendingBytes + bytes; self.pendingCount = self.pendingCount + items
    self.readThrough = batch.throughSeq
    if self.deps.observer and type(self.deps.observer.onEvents) == "function" then
        self:_observe("onEvents", self.Json.copy(self.source), self.Json.copy(batch))
    end
    return true
end

function Bridge:_acceptState(page)
    if page == self.Json.null then return true end
    if type(page.snapshotId) ~= "string" or not integer(page.pageIndex) or not integer(page.pageCount) or
        page.pageCount < 1 or page.pageIndex >= page.pageCount or not self.Json.isArray(page.entities) then
        return false, "Invalid snapshot page"
    end
    if page.pageIndex == 0 then
        self.snapshot = { snapshotId = page.snapshotId, pageCount = page.pageCount, scopeRevision = page.scopeRevision,
            assembledSimTime = page.assembledSimTime, eventSeqAtCapture = page.eventSeqAtCapture,
            coverage = self.Json.copy(page.coverage), entities = self.Json.array(), ids = {}, nextIndex = 0 }
    end
    local staging = self.snapshot
    if not staging or staging.snapshotId ~= page.snapshotId or staging.nextIndex ~= page.pageIndex or
        staging.pageCount ~= page.pageCount or staging.scopeRevision ~= page.scopeRevision or
        staging.eventSeqAtCapture ~= page.eventSeqAtCapture then return false, "Mixed or missing snapshot page" end
    for _, entity in ipairs(page.entities) do
        if type(entity.entityId) ~= "string" or staging.ids[entity.entityId] then return false, "Duplicate/invalid entity identity" end
        if entity.kind == "aircraft" then
            if not entity.motion or entity.motion.speedMps == nil or entity.motion.groundSpeedMps == nil or
                not entity.fuel or entity.fuel.ratioRaw == nil or not entity.armament or entity.armament.items == nil or
                not entity.occupancy or entity.occupancy.isPlayer == nil then return false, "Missing required aircraft fields" end
        elseif entity.kind == "missile" then
            if not entity.launch or not entity.launch.launcher or not entity.launch.initialTarget or
                not entity.targetObservation or entity.lastKnownTarget == nil then return false, "Missing required missile fields" end
        else return false, "Unexpected full telemetry entity kind" end
        staging.ids[entity.entityId] = true; staging.entities[#staging.entities + 1] = self.Json.copy(entity)
    end
    staging.nextIndex = staging.nextIndex + 1
    if staging.nextIndex == staging.pageCount then
        if page.nextCursor ~= self.Json.null then return false, "Final snapshot page has a cursor" end
        staging.ids = nil; staging.nextIndex = nil
        local accepted, err = true, nil
        if self.deps.sink and type(self.deps.sink.onState) == "function" then
            accepted, err = self:_sink("onState", self.Json.copy(self.source), self.Json.copy(staging))
        end
        if not accepted then self.snapshot = nil; return false, err end
        self.latestState = staging; self.snapshot = nil; self.stateCursor = nil
        if self.deps.observer and type(self.deps.observer.onState) == "function" then
            self:_observe("onState", self.Json.copy(self.source), self.Json.copy(staging))
        end
    else
        if type(page.nextCursor) ~= "string" then return false, "Missing next-page cursor" end
        self.stateCursor = page.nextCursor
    end
    return true
end

function Bridge:confirm(source, sequence)
    local session, retainedIndex = self, nil
    if not sameSource(source, self.source) then
        session = nil
        for index, retained in ipairs(self.retainedSessions) do
            if sameSource(source, retained.source) then session = retained; retainedIndex = index; break end
        end
        if not session then return false, "Confirmation source does not match" end
    end
    if not integer(sequence) or sequence > session.readThrough then return false, "Confirmation exceeds accepted data" end
    if sequence <= session.confirmedSeq then return true end
    session.confirmedSeq = sequence
    local remaining = {}
    for _, pending in ipairs(session.pending) do
        if pending.batch.throughSeq <= sequence then
            session.pendingBytes = session.pendingBytes - pending.bytes; session.pendingCount = session.pendingCount - pending.items
        else remaining[#remaining + 1] = pending end
    end
    session.pending = remaining
    if retainedIndex and session.pendingCount == 0 then table.remove(self.retainedSessions, retainedIndex) end
    if session == self and not self.active and self.finalEventSeq then
        -- The stop callback may still have access to the old mission environment.
        -- Do not wait for the next telemetry tick to forward its final receipt.
        self:flushFinalAck()
        self:_refreshEnd()
    end
    return true
end

function Bridge:_collectorAckStatus()
    local state = "running"
    if self.finalAckClosed and not self.active then state = "unverified" end
    if self.finalEventSeq then
        if self.actualAck >= self.finalEventSeq then state = "confirmed"
        elseif self.finalAckClosed then state = "unverified"
        elseif self.confirmedSeq < self.finalEventSeq then state = "waiting_server"
        else state = "pending" end
    end
    return { state = state, targetSeq = self.finalEventSeq or self.Json.null,
        confirmedSeq = self.confirmedSeq, actualAck = self.actualAck,
        attempts = self.finalAckAttempts or 0, consecutiveFailures = self.finalAckFailures or 0, retryLimit = 3,
        lastError = self.finalAckError or self.Json.null }
end

function Bridge:_refreshEnd()
    if self.lastSessionEnd then self:_reportEnd(self.lastSessionEnd.tailComplete, self.lastSessionEnd.tailReason) end
    self:_sink("onStatus", self:getStatus(), true)
    self:_observe("onStatus", self:getStatus(), true)
end

function Bridge:flushFinalAck()
    if self.active or not self.installed or not self.finalEventSeq or self.finalAckClosed or
        self.confirmedSeq <= self.actualAck or self.deps.now() < (self.nextFinalAck or 0) then return end
    self.nextFinalAck = self.deps.now() + 1
    self.finalAckAttempts = (self.finalAckAttempts or 0) + 1
    local ok, accepted, reason = pcall(self._poll, self, false, false)
    if ok and accepted then
        self.finalAckError = nil; self.finalAckFailures = 0
    else
        self.finalAckFailures = (self.finalAckFailures or 0) + 1
        self.finalAckError = tostring(ok and (reason or "ACK exchange rejected") or accepted)
        self:_notice("Final collector ACK attempt " .. self.finalAckAttempts .. "; failure " .. self.finalAckFailures .. "/3: " .. self.finalAckError)
        if self.finalAckError == "SOURCE_CHANGED" or self.finalAckError == "COLLECTOR_ABSENT" then self.finalAckClosed = true end
    end
    if self.finalAckFailures >= 3 then self.finalAckClosed = true end
    self:_refreshEnd()
end

function Bridge:_poll(stateEnabled, eventsEnabled)
    if self.splitReads and stateEnabled ~= false and eventsEnabled ~= false then
        if self.splitNextEvents then stateEnabled = false else eventsEnabled = false end
        self.splitNextEvents = not self.splitNextEvents
    end
    local pendingItems, pendingBytes = self:_pendingUsage()
    local free = (self.config.maxPendingItems or 2048) - pendingItems
    local eventRead = eventsEnabled ~= false and free > 0 and
        pendingBytes < (self.config.maxPendingBytes or 8388608) - 65536
    local cpuNow = self.deps.wallNow or os.clock
    local started = cpuNow()
    local response, err = self:_request("exchange", { ackEventSeq = self.confirmedSeq,
        read = { state = { enabled = stateEnabled ~= false, cursor = self.stateCursor or self.Json.null },
            events = { enabled = eventRead, afterSeq = self.readThrough, maxCount = math.max(1, math.min(128, free)) } },
        limits = { maxResponseBytes = self.responseBudget or 262144 } })
    local elapsed = math.max(0, (cpuNow() - started) * 1000)
    self.exchangeMetrics = self.exchangeMetrics or { calls = 0, maxCpuMs = 0 }
    self.exchangeMetrics.calls = self.exchangeMetrics.calls + 1
    self.exchangeMetrics.lastCpuMs = elapsed; self.exchangeMetrics.maxCpuMs = math.max(self.exchangeMetrics.maxCpuMs, elapsed)
    if not response then
        if err == "STALE_CURSOR" then self.snapshot = nil; self.stateCursor = nil end
        if err == "RESPONSE_BUDGET_TOO_SMALL" then
            self.splitReads = true; self.splitNextEvents = true
            self.snapshot = nil; self.stateCursor = nil
        end
        return false, err
    end
    if response.data.status == "stopped" then
        local final = response.data.finalEventSeq
        if not integer(final) or (self.finalEventSeq and final ~= self.finalEventSeq) then return false, "Invalid final event sequence" end
        self.finalEventSeq = final
    end
    if not integer(response.data.ackEventSeq) or response.data.ackEventSeq < self.actualAck or
        response.data.ackEventSeq ~= self.confirmedSeq then return false, "Invalid collector ACK" end
    self.actualAck = response.data.ackEventSeq; self.lastHealth = response.data.health; self.lastHealthAt = self.deps.now()
    local eventsOk, eventsErr = self:_acceptEvents(response.data.eventLog)
    local stateOk, stateErr = self:_acceptState(response.data.state)
    if not stateOk then self.snapshot = nil; self.stateCursor = nil end
    if not eventsOk then return false, eventsErr end
    if not stateOk then return false, stateErr end
    return true
end

function Bridge:_failure(err)
    self.failureCount = self.failureCount + 1
    self.lastError = tostring(err or "Unknown bridge error")
    self:_notice(self.lastError)
    self.nextAction = self.deps.now() + math.min(5, 0.1 * 2 ^ math.min(self.failureCount, 6))
    if self.finalEventSeq then self.phase = "draining"
    elseif self.lastError == "COLLECTOR_ABSENT" or self.lastError == "SOURCE_CHANGED" then
        self.phase = "inspecting"; self.snapshot = nil; self.stateCursor = nil
    elseif self.failureCount >= 3 and self.phase ~= "verification_required" and self.phase ~= "stopped" then
        self.phase = "probing"; self.route = nil; self.snapshot = nil; self.stateCursor = nil
    end
end

function Bridge:tick()
    local time = self.deps.now()
    if not self.active then
        -- A final server receipt can arrive after stopMission has finished.
        -- Forward it while the old environment is still accessible; never reinject.
        self:flushFinalAck()
        return
    end
    if self.phase == "verification_required" or self.phase == "stopped" then return end
    -- Continuations read an already frozen snapshot; they do not start another
    -- sample or increase the 1 Hz snapshot creation rate.
    if self.phase == "collecting" and self.stateCursor and not self.paused then
        local wallNow = self.deps.wallNow or os.clock
        local deadline = wallNow() + 0.002
        for _ = 1, 4 do
            if not self.stateCursor or wallNow() >= deadline then break end
            local ok, accepted, reason = pcall(self._poll, self, true, false)
            if not ok or not accepted then self:_failure(ok and reason or accepted); break end
        end
        return
    end
    if time < self.nextAction then return end
    if self.deps.pollConfirmation and time >= self.nextManualAck then
        self.nextManualAck = time + 1
        local ok, receipt = pcall(self.deps.pollConfirmation)
        if ok and receipt then
            local accepted, err = self:confirm(receipt, receipt.ackEventSeq)
            if not accepted and self.lastReceiptError ~= err then self:_notice(err); self.lastReceiptError = err end
        end
    end
    if self.phase == "draining" then
        local ok, err = pcall(self._drainTail, self, 4, 0.01)
        if not ok then self.lastError = tostring(err); self:_reportEnd(false, "drain_exception: " .. tostring(err)) end
        self.nextAction = time + 1 / (self.config.pollHz or 1)
        self:_observe("onStatus", self:getStatus())
        return
    end
    local ok, success, err = pcall(function()
        if self.phase == "probing" then
            local found, reason = self:_detectRoute()
            if found then self.phase = "inspecting" end
            return found, reason
        elseif self.phase == "inspecting" then return self:_inspect()
        elseif self.phase == "installing" then return self:_install()
        elseif self.phase == "initializing" then return self:_initialize()
        elseif self.phase == "collecting" then
            local success, reason = self:_poll(not self.paused, true)
            if self.finalEventSeq then self.phase = "draining" end
            return success, reason
        end
        return false, "Unknown bridge phase"
    end)
    if not ok then self:_failure(success)
    elseif not success then self:_failure(err)
    else
        self.failureCount = 0; self.lastError = nil
        -- Inject promptly so the 1 Hz telemetry setting does not delay event capture.
        self.nextAction = time + (self.phase == "collecting" and 1 / (self.config.pollHz or 1) or 0.05)
    end
    local statusOk, statusError = self:_sink("onStatus", self:getStatus())
    if not statusOk then self.lastError = "Diagnostic status write failed: " .. tostring(statusError); self:_notice(self.lastError) end
    self:_observe("onStatus", self:getStatus())
end

function Bridge:setPaused(paused) self.paused = paused == true end

function Bridge:getStatus()
    local items, bytes = self:_pendingUsage()
    return { phase = self.phase, active = self.active, paused = self.paused,
        source = self.source and self.Json.copy(self.source) or self.Json.null,
        route = self.route and self.route.name or self.Json.null, readThrough = self.readThrough,
        confirmedSeq = self.confirmedSeq, actualAck = self.actualAck,
        collectorAck = self:_collectorAckStatus(),
        pendingItems = self.pendingCount, pendingBytes = self.pendingBytes,
        retainedSessionCount = #self.retainedSessions, totalPendingItems = items, totalPendingBytes = bytes,
        finalEventSeq = self.finalEventSeq or self.Json.null,
        sessionEnd = self.lastSessionEnd and self.Json.copy(self.lastSessionEnd) or self.Json.null,
        lastError = self.lastError or self.Json.null, health = self.lastHealth or self.Json.null,
        healthFresh = self.active and self.lastError == nil and self.lastHealth ~= nil,
        healthObservedAt = self.lastHealthAt or self.Json.null,
        tailFailures = self.tailFailures or 0,
        exchangeMetrics = self.exchangeMetrics and self.Json.copy(self.exchangeMetrics) or self.Json.null,
        diagnosticErrorCount = self.diagnosticErrorCount or 0,
        lastDiagnosticError = self.lastDiagnosticError or self.Json.null }
end

function Bridge:getPendingBatches(source, maxBatches)
    local pending = self.pending
    if source and not sameSource(source, self.source) then
        pending = {}
        for _, session in ipairs(self.retainedSessions) do if sameSource(source, session.source) then pending = session.pending; break end end
    end
    local result = self.Json.array()
    for _, item in ipairs(pending) do
        if maxBatches and #result >= maxBatches then break end
        result[#result + 1] = self.Json.copy(item.batch)
    end
    return result
end

function Bridge:getRetainedSessions()
    local result = self.Json.array()
    for _, session in ipairs(self.retainedSessions) do
        result[#result + 1] = { source = self.Json.copy(session.source), readThrough = session.readThrough,
            confirmedSeq = session.confirmedSeq, pendingItems = session.pendingCount, pendingBytes = session.pendingBytes,
            sessionEnd = self.Json.copy(session.sessionEnd) }
    end
    return result
end

function Bridge:_reportEnd(complete, reason)
    local details = { tailComplete = complete, tailReason = reason, captureClosed = not self.active,
        latestEventSeq = self.finalEventSeq or self.Json.null, readThrough = self.readThrough, confirmedSeq = self.confirmedSeq,
        actualAck = self.actualAck, pendingItems = self.pendingCount, collectorAck = self:_collectorAckStatus() }
    local encoded = self.Json.encode(details)
    self.lastSessionEnd = self.Json.copy(details)
    if self.endReport == encoded then return end
    self.endReport = encoded
    self:_notice("Mission tail: " .. tostring(self.readThrough) .. "/" .. tostring(self.finalEventSeq or "unknown") ..
        "; complete=" .. tostring(complete) .. "; reason=" .. reason ..
        "; collectorAck=" .. details.collectorAck.state .. "; actualAck=" .. self.actualAck .. "; confirmedSeq=" .. self.confirmedSeq)
    self:_sink("onSessionEnd", self.Json.copy(self.source), self.Json.copy(details))
    self:_observe("onSessionEnd", self.Json.copy(self.source), self.Json.copy(details))
end

function Bridge:_finishSession(complete, reason)
    if complete then self.lastError = nil; self.failureCount = 0 end
    if not complete then
        self.lastError = self.lastError or reason; self.finalAckClosed = true
        self.finalAckError = self.finalAckError or ("tail_incomplete: " .. tostring(reason))
    end
    self.active = false; self.phase = "waiting"; self.snapshot = nil; self.stateCursor = nil
    self:_reportEnd(complete, reason)
    self:flushFinalAck()
    self:_sink("onStatus", self:getStatus(), true)
    self:_observe("onStatus", self:getStatus(), true)
    return complete, reason
end

function Bridge:_drainTail(maxBatches, budget)
    local wallNow = self.deps.wallNow or os.clock
    local deadline = wallNow() + budget
    if not self.installed then return self:_finishSession(false, "collector_not_installed") end
    if not self.route then self:_detectRoute() end
    if not self.route then return self:_tailFailure("mission_environment_unavailable") end
    if not self.finalEventSeq then
        local response, err = self:_request("shutdown")
        if not response then return self:_tailFailure(err or "shutdown_unverified") end
        if response.data.status ~= "stopped" or not integer(response.data.latestEventSeq) then
            return self:_tailFailure("shutdown_unverified")
        end
        self.finalEventSeq = response.data.latestEventSeq
    end
    local reason = "drain_budget_exhausted"
    for _ = 1, maxBatches do
        if self.readThrough == self.finalEventSeq then return self:_finishSession(true, "complete") end
        if wallNow() >= deadline then break end
        local items, bytes = self:_pendingUsage()
        if items >= (self.config.maxPendingItems or 2048) or bytes >= (self.config.maxPendingBytes or 8388608) - 65536 then
            reason = "pending_buffer_full"; break
        end
        local previous = self.readThrough
        local ok, err = self:_poll(false, true)
        if not ok then return self:_tailFailure(err or "tail_read_failed") end
        if self.readThrough <= previous then return self:_tailFailure("tail_read_no_progress") end
        self.tailFailures = 0; self.lastError = nil
    end
    if self.readThrough == self.finalEventSeq then return self:_finishSession(true, "complete") end
    self:_reportEnd(false, reason)
    return false, reason
end

function Bridge:_tailFailure(reason)
    self.lastError = tostring(reason)
    self.tailFailures = (self.tailFailures or 0) + 1
    if self.tailFailures >= 3 or reason == "COLLECTOR_ABSENT" or reason == "SOURCE_CHANGED" then
        self.finalAckClosed = true; self.finalAckError = "tail_incomplete: " .. tostring(reason)
        return self:_finishSession(false, "tail_unavailable: " .. tostring(reason))
    end
    self:_reportEnd(false, tostring(reason))
    return false, reason
end

function Bridge:stopMission()
    if not self.active then return self.lastSessionEnd and self.lastSessionEnd.tailComplete or false end
    self.phase = "draining"; self.snapshot = nil; self.stateCursor = nil
    local complete, reason = self:_drainTail(self.config.stopDrainMaxBatches or 128, self.config.stopDrainBudgetSec or 0.25)
    self:_observe("onStatus", self:getStatus(), true)
    return complete, reason
end

return Bridge
