-- Small, strict JSON codec for DCS Lua 5.1. No Lua evaluation is used to decode.
local Json = {}
local arrayTag = {}
Json.null = setmetatable({}, { __tostring = function() return "null" end })

function Json.array(value)
    return setmetatable(value or {}, arrayTag)
end

function Json.isArray(value)
    return type(value) == "table" and getmetatable(value) == arrayTag
end

function Json.copy(value)
    if value == Json.null or type(value) ~= "table" then return value end
    local result = Json.isArray(value) and Json.array() or {}
    for key, item in pairs(value) do result[key] = Json.copy(item) end
    return result
end

local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b',
    ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
local function quote(value)
    return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
        return escapes[char] or string.format("\\u%04x", char:byte())
    end) .. '"'
end

-- Optional cache is internal only: table keys must be immutable snapshots and
-- values must come from this encoder, never from external JSON/request fields.
function Json.encode(value, encodedTables)
    local active = {}
    local function encode(item, depth)
        if depth > 64 then error("JSON nesting limit exceeded") end
        if item == Json.null then return "null" end
        local kind = type(item)
        if kind == "boolean" then return item and "true" or "false" end
        if kind == "number" then
            if item ~= item or item == math.huge or item == -math.huge then error("Non-finite JSON number") end
            return string.format("%.17g", item)
        end
        if kind == "string" then return quote(item) end
        if kind ~= "table" then error("Unsupported JSON type: " .. kind) end
        if encodedTables and encodedTables[item] then return encodedTables[item] end
        if active[item] then error("Circular JSON data") end
        active[item] = true
        local parts = {}
        if Json.isArray(item) then
            local length, count = #item, 0
            for key in pairs(item) do
                if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > length then
                    error("Sparse or non-integer JSON array")
                end
                count = count + 1
            end
            if count ~= length then error("Sparse JSON array") end
            for index = 1, length do parts[index] = encode(item[index], depth + 1) end
            active[item] = nil
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for key in pairs(item) do
            if type(key) ~= "string" then error("JSON object keys must be strings") end
            keys[#keys + 1] = key
        end
        table.sort(keys)
        for _, key in ipairs(keys) do parts[#parts + 1] = quote(key) .. ":" .. encode(item[key], depth + 1) end
        active[item] = nil
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return encode(value, 0)
end

local function utf8(code)
    if code <= 0x7f then return string.char(code) end
    if code <= 0x7ff then return string.char(0xc0 + math.floor(code / 64), 0x80 + code % 64) end
    if code <= 0xffff then
        return string.char(0xe0 + math.floor(code / 4096), 0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
    end
    return string.char(0xf0 + math.floor(code / 262144), 0x80 + math.floor(code / 4096) % 64,
        0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
end

function Json.decode(text)
    if type(text) ~= "string" or #text > 1048576 then error("Invalid JSON input size/type") end
    local position, length = 1, #text
    local parse
    local function fail(message) error(message .. " at byte " .. position) end
    local function whitespace()
        while text:sub(position, position):match("[ \t\r\n]") do position = position + 1 end
    end
    local function hex4()
        local digits = text:sub(position, position + 3)
        if #digits ~= 4 or not digits:match("^%x%x%x%x$") then fail("Invalid Unicode escape") end
        position = position + 4
        return tonumber(digits, 16)
    end
    local function parseString()
        position = position + 1
        local parts, start = {}, position
        while position <= length do
            local char = text:sub(position, position)
            if char == '"' then
                parts[#parts + 1] = text:sub(start, position - 1)
                position = position + 1
                return table.concat(parts)
            elseif char == "\\" then
                parts[#parts + 1] = text:sub(start, position - 1)
                position = position + 1
                local escaped = text:sub(position, position)
                local decoded = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
                if escaped == "u" then
                    position = position + 1
                    local code = hex4()
                    if code >= 0xd800 and code <= 0xdbff then
                        if text:sub(position, position + 1) ~= "\\u" then fail("Missing low surrogate") end
                        position = position + 2
                        local low = hex4()
                        if low < 0xdc00 or low > 0xdfff then fail("Invalid low surrogate") end
                        code = 0x10000 + (code - 0xd800) * 1024 + low - 0xdc00
                    elseif code >= 0xdc00 and code <= 0xdfff then fail("Unpaired low surrogate") end
                    parts[#parts + 1] = utf8(code)
                else
                    if not decoded[escaped] then fail("Invalid escape") end
                    parts[#parts + 1] = decoded[escaped]
                    position = position + 1
                end
                start = position
            else
                if char:byte() < 32 then fail("Unescaped control character") end
                position = position + 1
            end
        end
        fail("Unterminated string")
    end
    local function digit() return text:sub(position, position):match("%d") ~= nil end
    local function parseNumber()
        local start = position
        if text:sub(position, position) == "-" then position = position + 1 end
        if text:sub(position, position) == "0" then
            position = position + 1
            if digit() then fail("Leading zero") end
        else
            if not digit() then fail("Expected number") end
            repeat position = position + 1 until not digit()
        end
        if text:sub(position, position) == "." then
            position = position + 1
            if not digit() then fail("Missing fraction") end
            repeat position = position + 1 until not digit()
        end
        if text:sub(position, position):match("[eE]") then
            position = position + 1
            if text:sub(position, position):match("[+-]") then position = position + 1 end
            if not digit() then fail("Missing exponent") end
            repeat position = position + 1 until not digit()
        end
        local number = tonumber(text:sub(start, position - 1))
        if not number or number == math.huge or number == -math.huge then fail("Invalid number") end
        return number
    end
    parse = function(depth)
        if depth > 64 then fail("JSON nesting limit exceeded") end
        whitespace()
        local char = text:sub(position, position)
        if char == '"' then return parseString() end
        if char == "{" or char == "[" then
            local isArray = char == "["
            local result = isArray and Json.array() or {}
            local closing = isArray and "]" or "}"
            position = position + 1
            whitespace()
            if text:sub(position, position) == closing then position = position + 1; return result end
            while true do
                local key
                if not isArray then
                    if text:sub(position, position) ~= '"' then fail("Expected object key") end
                    key = parseString()
                    if result[key] ~= nil then fail("Duplicate object key") end
                    whitespace()
                    if text:sub(position, position) ~= ":" then fail("Expected colon") end
                    position = position + 1
                end
                local item = parse(depth + 1)
                if isArray then result[#result + 1] = item else result[key] = item end
                whitespace()
                char = text:sub(position, position)
                position = position + 1
                if char == closing then return result end
                if char ~= "," then fail("Expected comma") end
                whitespace()
            end
        end
        local literals = { ["true"] = true, ["false"] = false, ["null"] = Json.null }
        for word, value in pairs(literals) do
            if text:sub(position, position + #word - 1) == word then position = position + #word; return value end
        end
        if char == "-" or char:match("%d") then return parseNumber() end
        fail("Unexpected token")
    end
    local value = parse(0)
    whitespace()
    if position <= length then fail("Trailing JSON data") end
    return value
end

return Json
