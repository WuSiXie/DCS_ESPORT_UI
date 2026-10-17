-- Run in DCS's own Lua 5.1 executable against a real C++ receiver.
package.path=PROJECT_ROOT.."/?.lua;"..package.path
local Mock=require("tests.mock_dcs")
local Json=require("src.shared.json")
local socket=require("socket.core")
local mission=Mock.new();mission.io=false;mission.lfs=false;mission.require=false;mission.dofile=false
local unit=mission.unit(17,"Native-TCP-Pilot","Pilot-A")
local target=mission.unit(23,"Target",nil)
local callbacks
local start=socket.gettime()
local host=setmetatable({net=mission.net,
    DCS={getRealTime=function() return socket.gettime()-start end,setUserCallbacks=function(c) callbacks=c end},
    lfs={writedir=function() return PROJECT_ROOT.."/runtime/network-native/" end},
    log={INFO=1,write=function(_,_,message) if message:find("unavailable") then print(message) end end}}, {__index=_G})
local chunk=assert(loadfile(HOOK_FILE));setfenv(chunk,host);chunk()
assert(callbacks,"Hook entry failed")
callbacks.onSimulationStart()
local b=host.DcsEsportHookBridge;local t=assert(host.DcsEsportHookTransport,"TCP missing")
local function pump() mission.advance(0.01);callbacks.onSimulationFrame();socket.sleep(0.01) end
local function untilTrue(check,seconds)
    local deadline=socket.gettime()+seconds
    repeat pump();if check() then return end until socket.gettime()>deadline
    error("Network test timeout: "..Json.encode(t:status()).." bridge="..Json.encode(b:getStatus()))
end
untilTrue(function() return t.phase=="ready" and b.latestState~=nil end,8)
local epoch=t.serverEpoch
local missile=mission.missile(88,unit,target);mission.emit("SHOT",{initiator=unit,weapon=missile})
untilTrue(function() return b.actualAck>=1 end,5)
assert(b.pendingCount==0 and mission.DcsEsportCollector.eventBytes==0)
unit.velocity={x=300,y=0,z=0};unit.fuel=0.4
print("SAMPLE_START");io.stdout:flush()
local sampleUntil=socket.gettime()+3.2
while socket.gettime()<sampleUntil do pump() end
print("SAMPLE_END");io.stdout:flush()
t.socket:close() -- OS-level close: transport must discover and reconnect itself.
for _=1,20 do mission.emit("TAKEOFF",{initiator=unit}) end
untilTrue(function() return t.connections>=2 and b.actualAck>=21 end,7)
assert(t.serverEpoch==epoch)
print("RESTART_NOW");io.stdout:flush()
untilTrue(function() return t.phase=="ready" and t.serverEpoch~=epoch end,10)
mission.emit("LAND",{initiator=unit})
untilTrue(function() return b.actualAck>=22 end,5)
local firstSource=Json.copy(b.source)
for _=1,350 do mission.emit("TAKEOFF",{initiator=unit}) end
t.socket:close() -- End while disconnected: keep both event batches and end metadata for retry.
mission.emit("MISSION_END");callbacks.onSimulationStop()
assert(b.lastSessionEnd.tailComplete and b.finalEventSeq==373)
untilTrue(function() return b.pendingCount==0 and b.actualAck==373 and t:status().pendingSessionEnds==0 end,8)
assert(mission.DcsEsportCollector.eventBytes==0)
-- A new isolated mission must not mix with the completed source.
local replacement=Mock.new();replacement.unit(19,"Next-Mission",nil)
mission=replacement;host.net=replacement.net;b.deps.net=replacement.net
callbacks.onSimulationStart()
untilTrue(function() return b.latestState~=nil and t.phase=="ready" end,5)
mission.emit("TAKEOFF",{initiator=mission.groups[1].units[1]})
untilTrue(function() return b.actualAck==1 end,5)
callbacks.onSimulationStop()
untilTrue(function() return t:status().pendingSessionEnds==0 end,5)
print("RESULT "..Json.encode({firstSource=firstSource,secondSource=b.source,firstFinal=373,
    reconnects=t.connections,actualAck=b.actualAck,network=t:status(),singleFile=true}))
io.stdout:flush()
