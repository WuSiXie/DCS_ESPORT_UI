package.path = PROJECT_ROOT .. "/?.lua;" .. PROJECT_ROOT .. "/?/init.lua;" .. package.path
local passed, failed = 0, 0
function test(name, body)
    local ok, reason = pcall(body)
    if ok then passed = passed + 1; print("PASS " .. name)
    else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(reason)) end
end
function equal(actual, expected, description)
    if actual ~= expected then error((description or "Values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2) end
end
function truth(value, description) if not value then error(description or "Expected truthy value", 2) end end
function raises(body) local ok = pcall(body); if ok then error("Expected an error", 2) end end

require("tests.test_json")
require("tests.test_collector")
require("tests.test_bridge")
require("tests.test_recorder")
require("tests.test_transport")
require("tests.test_players")
print(string.format("%d passed, %d failed (%s)", passed, failed, _VERSION))
if failed > 0 then error("Lua test suite failed") end
