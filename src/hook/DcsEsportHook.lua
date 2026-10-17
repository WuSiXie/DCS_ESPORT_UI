-- Bootstrap template. tools/package.py embeds dependencies and invokes this factory.
-- Deploy the GENERATED single file, not this development module.
local function report(message)
    if log and log.write then log.write("DCS-ESPORT", log.INFO, tostring(message)) end
end

return function(embedded, config)
local ok, err = pcall(function()
    assert(type(embedded) == "table", "Build the single-file Hook with tools/package.py")
    config = config or {}
    assert(type(config) == "table", "Embedded config must return a table")
    local environment = getfenv(1)
    local function loadModule(name)
        local text = assert(embedded[name], "Missing embedded module: " .. name)
        local chunk = assert(loadstring(text, "@DcsEsport/" .. name .. ".lua"))
        setfenv(chunk, environment)
        return chunk()
    end
    local Json = loadModule("json")
    local Bridge = loadModule("bridge")
    local Recorder = loadModule("recorder")
    local function now()
        if DCS and type(DCS.getRealTime) == "function" then return DCS.getRealTime() end
        return os.clock()
    end
    local output = config.outputDirectory or (lfs.writedir() .. "Logs/DcsEsport")
    local function ensureDirectory(path)
        local normalized = path:gsub("\\", "/")
        local current = ""
        for part in normalized:gmatch("[^/]+") do
            current = current == "" and part or current .. "/" .. part
            if not current:match("^%a:$") then
                local attributes = lfs.attributes(current)
                if not attributes then assert(lfs.mkdir(current)) else assert(attributes.mode == "directory") end
            end
        end
    end
    local recorder
    if config.diagnosticsEnabled ~= false then
        ensureDirectory(output)
        recorder = Recorder.new(Json, output, { now = now })
    end
    local bridge = Bridge.new({ Json = Json, net = net, now = now, observer = recorder,
        jsonSource = assert(embedded.json), collectorSource = assert(embedded.collector), log = report,
        pollConfirmation = config.manualAckEnabled and recorder and function() return recorder:readManualConfirmation() end or nil }, config)
    -- Available inside this hook's isolated environment for the embedded transport.
    DcsEsportHookBridge = bridge
    local players=loadModule('players').new({Json=Json,net=net,now=now})
    local transport
    if config.network and config.network.enabled then
        local networkOk, result = pcall(function()
            -- DCS ships socket.core as a native module; the Lua helper is not required.
            local socket = require("socket.core")
            local Transport = loadModule("transport")
            return Transport.new({Json=Json,bridge=bridge,players=players,socket=socket,now=now,cpuNow=os.clock,log=report},config.network)
        end)
        if networkOk then
            transport=result;bridge.deps.sink=transport;DcsEsportHookTransport=transport
        else report("Network unavailable; capture remains active: "..tostring(result)) end
    end
    local function pump() if transport then transport:tick() end end
    local function boundary() if transport then transport:boundary() end end
    local callbacks = {}
    function callbacks.onMissionLoadBegin() bridge:stopMission();boundary() end
    function callbacks.onSimulationStart() players:reset();players:tick();bridge:startMission();pump() end
    function callbacks.onSimulationFrame() bridge:tick();players:tick();pump() end
    function callbacks.onPlayerDisconnect(id) players:disconnect(id) end
    function callbacks.onSimulationPause() bridge:setPaused(true);pump() end
    function callbacks.onSimulationResume() bridge:setPaused(false);pump() end
    function callbacks.onSimulationStop() bridge:stopMission();boundary() end
    local guarded = {}
    for name, callback in pairs(callbacks) do
        local selected = callback
        guarded[name] = function(...)
            local succeeded, reason = pcall(selected, ...)
            if not succeeded then report(name .. ": " .. tostring(reason)) end
            -- Do not return a non-nil value into the DCS callback chain.
        end
    end
    DCS.setUserCallbacks(guarded)
    report("Hook 0.3.2 loaded; diagnostics="..tostring(recorder~=nil).."; network="..tostring(transport~=nil)..
        "; ACK="..(transport and "server memory receipt" or "disabled"))
end)
if not ok then report("Hook installation failed: " .. tostring(err)) end
end
