package.path = PROJECT_ROOT .. "/?.lua;" .. package.path
local Json = require("src.shared.json")
local Mock = require("tests.mock_dcs")
local mission = Mock.new()
mission.returnMode = "shifted"
mission.io = false; mission.lfs = false; mission.require = false; mission.dofile = false
local player = mission.unit(17, "Blue-1", "飞行员-A")
local victim = mission.unit(23, "Red-1", "飞行员-B"); victim.side = 1
player.id_=100017; victim.id_=100023
local callbacks, messages = nil, {}
-- Only the generated Hook is installed. Runtime reads of companion source,
-- configuration or filesystem modules are forbidden in this fixture.
local sourceReads,diagnosticReads = 0,0
local guardedIo = {
    open = function(path, mode)
        local normalized = path:gsub("\\", "/")
        if normalized:sub(1, #SMOKE_OUTPUT + 1) ~= SMOKE_OUTPUT .. "/" then
            sourceReads=sourceReads+1; error("Unexpected runtime file access: " .. path)
        end
        if mode and mode:find("r", 1, true) then diagnosticReads = diagnosticReads + 1 end
        local file,err=io.open(path,mode)
        if not file or not (SMOKE_IO_NO_RESULTS or SMOKE_DIAGNOSTIC_FAILURE) then return file,err end
        local function withoutSuccess(name,...)
            local value,reason=file[name](file,...)
            if value==false or reason~=nil then return value,reason end
        end
        return {
            write=function(_,...) return withoutSuccess("write",...) end,
            flush=function() return withoutSuccess("flush") end,
            close=function() return withoutSuccess("close") end,
            seek=function(_,...) if not SMOKE_DIAGNOSTIC_FAILURE then return file:seek(...) end end,
            read=function(_,...) return file:read(...) end
        }
    end
}
local hookEnvironment = setmetatable({
    net = mission.net,
    io = guardedIo,
    require = function() error("Standalone Hook must not require external modules") end,
    loadfile = function() error("Standalone Hook must not load external source files") end,
    dofile = function() error("Standalone Hook must not execute external source files") end,
    lfs = { writedir = function() return SMOKE_PROFILE end,
        attributes = function() return {mode="directory"} end, mkdir = function() return true end },
    DCS = { getRealTime = function() return mission._time end, setUserCallbacks = function(value) callbacks = value end },
    log = { INFO=1, write=function(_,_,message) messages[#messages+1]=message end }
}, {__index=_G})
local input=assert(io.open(SMOKE_PROFILE .. "Scripts/Hooks/DcsEsportHook.lua","rb"))
local text=input:read("*a");input:close()
text=text:gsub("diagnosticsEnabled = false","diagnosticsEnabled = true",1) -- Explicit diagnostic-only smoke profile.
local entry = assert(loadstring(text))
setfenv(entry, hookEnvironment); entry()
assert(callbacks, table.concat(messages,"\n"))
callbacks.onSimulationStart()
local function steps(n)
    for _=1,n do mission.advance(0.1); callbacks.onSimulationFrame() end
end
steps(20)
local bridge = assert(hookEnvironment.DcsEsportHookBridge)
bridge.deps.wallNow=function() return 0 end -- Deterministic callback budget; batch limits still apply.
assert(bridge.phase=="collecting", bridge.lastError)
if SMOKE_DIAGNOSTIC_FAILURE then
    assert(bridge:getStatus().diagnosticErrorCount > 0)
    assert(bridge.failureCount == 0 and bridge.lastError == nil)
end
local missile = mission.missile(88,player,victim)
mission.emit("SHOT",{initiator=player,weapon=missile})
steps(12)
assert(bridge.latestState and #bridge.latestState.entities==3)
local foundMissile, foundPlayer = false, false
for _, record in ipairs(bridge.latestState.entities) do
    if record.kind=="missile" then
        assert(record.launch.launcher.object.playerName=="飞行员-A")
        assert(record.targetObservation.object.name=="Red-1")
        foundMissile=true
    elseif record.identity.unitName=="Blue-1" then
        assert(record.motion.speedMps==250 and record.fuel.ratioRaw==0.62)
        assert(record.armament.items[1].count==4 and record.occupancy.isPlayer==true)
        foundPlayer=true
    end
end
assert(foundMissile and foundPlayer)
assert(bridge.actualAck==0 and mission.DcsEsportCollector.ackEventSeq==0)
local originalTarget
for _, record in ipairs(bridge.latestState.entities) do
    if record.kind=="missile" then originalTarget=record.targetObservation.object.entityId end
end
victim.exists=false
missile.getTarget=function() return {id_=victim.id_,isExist=function() return false end} end
steps(65) -- Fresh dead wrappers across a reconciliation sweep.
local tracked
for _,entry in pairs(mission.DcsEsportCollector.missiles) do tracked=entry.record end
assert(tracked.targetObservation.object.entityId==originalTarget)
for _,item in ipairs(bridge:getPendingBatches()) do for _,event in ipairs(item.events) do
    assert(event.type~="target_observation_changed")
end end
local bomb=mission.missile(99,player,nil); bomb.desc.category=mission.Weapon.Category.BOMB
mission.emit("HIT",{initiator=player,target=victim,weapon=bomb}); steps(12)
local hit
for _,item in ipairs(bridge:getPendingBatches()) do for _,event in ipairs(item.events) do
    if event.type=="hit" then hit=event end
end end
assert(hit.weapon.kind=="bomb" and hit.target.entityId==originalTarget)
missile.getTarget=nil
missile.target=nil; steps(12)
missile.exists=false; steps(12)
local through=bridge.readThrough
assert(through>=3)
assert(bridge:confirm(bridge.source,through)) -- Explicit local test receipt; no C++ durability claim.
steps(12)
assert(mission.DcsEsportCollector.ackEventSeq==through)
assert(mission.DcsEsportCollector.eventBytes==0)
local bufferBytesAfterAck=mission.DcsEsportCollector.eventBytes
for _=1,350 do mission.emit("TAKEOFF",{initiator=player}) end
mission.emit("MISSION_END")
assert(mission.DcsEsportCollector.status=="stopped")
callbacks.onSimulationStop()
assert(bridge.phase=="waiting")
assert(bridge.lastSessionEnd.tailComplete and bridge.readThrough==through+350)
assert(bridge.pendingCount==350 and bridge.actualAck==through)
assert(sourceReads==0)
return Json.encode({mode="offline_mock",runtime=SMOKE_RUNTIME,singleFileDeploymentVerified=true,
    externalSourceReads=sourceReads,diagnosticReadbacks=diagnosticReads,hostIoNoResults=SMOKE_IO_NO_RESULTS,
    diagnosticFailureAfterWrite=SMOKE_DIAGNOSTIC_FAILURE,
    diagnosticErrorCount=bridge:getStatus().diagnosticErrorCount,
    source=bridge.source,route=bridge.route.name,
    aircraftFieldsVerified=true,missileLauncherAndTargetVerified=true,
    retiredTargetIdentityVerified=true,eventWeaponClassificationVerified=true,
    multiPageTailVerified=true,tailEventCount=350,tailComplete=bridge.lastSessionEnd.tailComplete,
    readWithoutAutoAckVerified=true,confirmedThrough=through,
    collectorBufferBytesAfterAck=bufferBytesAfterAck,hookMessages=Json.array(messages)})
