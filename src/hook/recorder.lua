-- Diagnostic file sink, NOT a durable C++ receipt. Successful writes never ACK.
local Recorder = {}
Recorder.__index = Recorder

function Recorder.new(Json, directory, options)
    options = options or {}
    return setmetatable({ Json = Json, directory = directory, io = options.io or io,
        now = options.now or os.clock, lastState = -math.huge, lastStatus = -math.huge }, Recorder)
end

function Recorder:_write(name, value, append)
    local path = self.directory .. "/" .. name
    local file, err = self.io.open(path, append and "ab" or "wb")
    if not file then return false, err end
    local ok, encoded = pcall(self.Json.encode, value)
    if not ok then pcall(function() file:close() end); return false, "Diagnostic JSON encoding failed" end
    local payload = encoded .. (append and "\n" or "")
    local ambiguous, failure = false, nil
    local function operation(stage, body)
        local succeeded, result, reason = pcall(body)
        if not succeeded then failure = failure or (stage .. " exception: " .. tostring(result))
        elseif result == false or reason ~= nil then failure = failure or (stage .. " failed: " .. tostring(reason or result))
        elseif result == nil then ambiguous = true end
    end
    operation("write", function() return file:write(payload) end)
    operation("flush", function() return file:flush() end)
    operation("close", function() return file:close() end)
    if failure then return false, path .. ": " .. failure end
    if ambiguous then
        -- Some host bindings do not expose the standard truthy success result.
        -- Do not assume nil means success: verify the exact bytes after closing.
        local checked, verified = pcall(function()
            local reader = self.io.open(path, "rb")
            if not reader then return false end
            local readOk, matches = pcall(function()
                local size = reader:seek("end", 0)
                if type(size) ~= "number" or size < #payload or (not append and size ~= #payload) then return false end
                if reader:seek("set", size - #payload) == nil then return false end
                return reader:read(#payload) == payload
            end)
            local closeOk, closeResult, closeError = pcall(function() return reader:close() end)
            return readOk and matches and closeOk and closeResult ~= false and closeError == nil
        end)
        if not checked or not verified then return false, path .. ": missing I/O success result; byte verification failed" end
    end
    return true
end

function Recorder:onInitialized(response) return self:_write("initialized.json", response) end

function Recorder:onEvents(source, batch)
    return self:_write("events.jsonl", { missionSessionId = source.missionSessionId,
        collectorEpoch = source.collectorEpoch, eventLog = batch }, true)
end

function Recorder:onState(source, state)
    if self.now() - self.lastState < 1 then return true end
    self.lastState = self.now() -- Limit attempts even when the host reports failure.
    local ok, err = self:_write("latest-state.json", { missionSessionId = source.missionSessionId,
        collectorEpoch = source.collectorEpoch, state = state })
    return ok, err
end

function Recorder:onStatus(status, force)
    if not force and self.now() - self.lastStatus < 1 then return true end
    self.lastStatus = self.now()
    local ok, err = self:_write("status.json", status)
    return ok, err
end

function Recorder:onDiscontinuity(source, reason)
    return self:_write("lifecycle.jsonl", { source = source, reason = reason }, true)
end

function Recorder:onSessionEnd(source, details)
    return self:_write("lifecycle.jsonl", { source = source, details = details }, true)
end

function Recorder:readManualConfirmation()
    local file = self.io.open(self.directory .. "/manual-ack.json", "rb")
    if not file then return nil end
    local text = file:read(65537); file:close()
    if not text or #text > 65536 then return nil end
    local ok, receipt = pcall(self.Json.decode, text)
    if ok and type(receipt) == "table" and receipt ~= self.Json.null then return receipt end
    return nil
end

return Recorder
