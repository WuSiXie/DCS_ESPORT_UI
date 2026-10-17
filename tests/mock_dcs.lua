-- Stateful DCS API fixture: real Lua objects, events, timers and isolated Lua states.
local Mock = {}
function Mock.new()
    local env = { _time = 0, groups = {}, handlers = {}, timers = {}, nextTimer = 0,
        handlerRegistrations = 0, scheduleRegistrations = 0, returnMode = "normal", dropInstallOnce = false }
    setmetatable(env, { __index = _G })
    env._G = env
    env.Object = { Category = { UNIT = 1, WEAPON = 2, STATIC = 3 } }
    env.Unit = { Category = { AIRPLANE = 0, HELICOPTER = 1, GROUND_UNIT = 2, SHIP = 3 } }
    env.Group = { Category = { AIRPLANE = 0, HELICOPTER = 1 } }
    env.Weapon = { Category = { SHELL = 0, MISSILE = 1, ROCKET = 2, BOMB = 3, TORPEDO = 4 } }
    env.coalition = { side = { NEUTRAL = 0, RED = 1, BLUE = 2 } }
    env.world = { event = {} }
    local names = { "BIRTH", "SHOT", "HIT", "KILL", "CRASH", "DEAD", "UNIT_LOST", "EJECTION", "PILOT_DEAD",
        "TAKEOFF", "LAND", "PLAYER_ENTER_UNIT", "PLAYER_LEAVE_UNIT", "MISSION_END" }
    for index, name in ipairs(names) do env.world.event["S_EVENT_" .. name] = index end
    env.world.addEventHandler = function(handler)
        env.handlers[handler] = true; env.handlerRegistrations = env.handlerRegistrations + 1
    end
    env.world.removeEventHandler = function(handler) env.handlers[handler] = nil end
    env.timer = { getTime = function() return env._time end }
    env.timer.scheduleFunction = function(fn, arg, at)
        env.nextTimer = env.nextTimer + 1
        env.timers[env.nextTimer] = { fn = fn, arg = arg, at = at }
        env.scheduleRegistrations = env.scheduleRegistrations + 1
        return env.nextTimer
    end
    env.timer.removeFunction = function(id) env.timers[id] = nil end
    env.advance = function(delta)
        env._time = env._time + delta
        local due = {}
        for id, timer in pairs(env.timers) do if timer.at <= env._time then due[#due + 1] = { id, timer } end end
        for _, item in ipairs(due) do
            local nextAt = item[2].fn(item[2].arg, env._time)
            if env.timers[item[1]] then
                if nextAt then item[2].at = nextAt else env.timers[item[1]] = nil end
            end
        end
    end
    env.emit = function(name, fields)
        fields = fields or {}; fields.id = env.world.event["S_EVENT_" .. name]; fields.time = fields.time or env._time
        local handlers = {}; for handler in pairs(env.handlers) do handlers[#handlers + 1] = handler end
        for _, handler in ipairs(handlers) do handler:onEvent(fields) end
    end
    env.coalition.getGroups = function(side, category)
        if env.scanError then error("scan failure") end
        local result = {}
        for _, group in ipairs(env.groups) do if group.side == side and group.category == category then result[#result + 1] = group end end
        return result
    end
    local common = {}
    local function checked(self, name, value)
        if self.errors[name] then error("mock " .. name .. " failed") end
        return value
    end
    function common:getID() return checked(self, "getID", self.id) end
    function common:getName() return checked(self, "getName", self.name) end
    function common:getTypeName() return checked(self, "getTypeName", self.typeName) end
    function common:getCategory() return checked(self, "getCategory", self.objectCategory) end
    function common:getDesc() return checked(self, "getDesc", self.desc) end
    function common:getCoalition() return checked(self, "getCoalition", self.side) end
    function common:getCountry() return checked(self, "getCountry", 2) end
    function common:isExist() return checked(self, "isExist", self.exists) end
    function common:isActive() return checked(self, "isActive", self.active) end
    function common:getPoint() return checked(self, "getPoint", self.point) end
    function common:getVelocity() return checked(self, "getVelocity", self.velocity) end
    function common:getPosition() return checked(self, "getPosition", { x = {x=1,y=0,z=0}, y = {x=0,y=1,z=0}, z = {x=0,y=0,z=1} }) end
    function common:inAir() return checked(self, "inAir", self.airborne) end
    function common:getPlayerName() return checked(self, "getPlayerName", self.playerName) end
    function common:getFuel() return checked(self, "getFuel", self.fuel) end
    function common:getAmmo() return checked(self, "getAmmo", self.ammo) end
    function common:getLife() return checked(self, "getLife", self.life) end
    function common:getLife0() return checked(self, "getLife0", 100) end
    function common:getGroup() return checked(self, "getGroup", self.group) end
    function common:getLauncher() return checked(self, "getLauncher", self.launcher) end
    function common:getTarget() return checked(self, "getTarget", self.target) end
    for _, name in ipairs({ "getFuel", "getAmmo", "getPlayerName" }) do env.Unit[name] = common[name] end
    env.Object.getVelocity = common.getVelocity; env.Object.getPoint = common.getPoint
    env.Weapon.getLauncher = common.getLauncher; env.Weapon.getTarget = common.getTarget
    local function object(id, name)
        return setmetatable({ id = id, name = name, errors = {}, exists = true, active = true,
            side = 2, point = {x=10000,y=5000,z=20000}, velocity = {x=240,y=0,z=70}, airborne = true, life = 100 }, { __index = common })
    end
    env.unit = function(id, name, player, category)
        local unit = object(id, name)
        unit.objectCategory = env.Object.Category.UNIT; unit.typeName = "F-16C_50"
        unit.desc = { category = category or 0, fuelMassMax = 3100 }
        unit.playerName = player; unit.fuel = 0.62
        unit.ammo = { {count=4,desc={typeName="AIM_120C",displayName="AIM-120C",category=1}},
            {count=2,desc={typeName="AIM_9X",displayName="AIM-9X",category=1}} }
        local group = { name = name .. "-Group", side = unit.side, category = category or 0, units = { unit } }
        function group:getName() return self.name end
        function group:getUnits() return self.units end
        unit.group = group; env.groups[#env.groups + 1] = group
        return unit
    end
    env.missile = function(id, launcher, target)
        local weapon = object(id, "weapon-" .. id)
        weapon.objectCategory = env.Object.Category.WEAPON; weapon.typeName = "AIM_120C"
        weapon.desc = { category = env.Weapon.Category.MISSILE }
        weapon.velocity = {x=650,y=0,z=0}; weapon.launcher = launcher; weapon.target = target
        weapon.side = launcher and launcher.side or 2
        return weapon
    end
    local function execute(text, state)
        local chunk = assert(loadstring(text)); setfenv(chunk, state); return chunk()
    end
    env.net = { dostring_in = function(scope, text)
        local state
        if env.routeMode == "unavailable" then return nil, false end
        if env.routeMode == "direct" then
            if scope ~= "mission" then return nil, false end
            state = env
        elseif env.routeMode == "server" then
            if scope ~= "server" then return nil, false end
            state = env
        else
            if scope ~= "mission" then return nil, false end
            state = setmetatable({}, { __index = _G })
            state.a_do_script = function(inner)
                local a, b, c = execute(inner, env)
                if env.returnMode == "shifted" then return nil, a, b end
                return a, b, c
            end
        end
        local value = execute(text, state)
        if env.dropInstallOnce and text:find("INSTALLED", 1, true) then env.dropInstallOnce = false; return nil, true end
        return value, true
    end }
    return env
end
return Mock
