local Json = require("src.shared.json")
test("JSON preserves null, empty arrays, objects, booleans and UTF-8", function()
    local value = Json.decode('{"a":[],"b":{},"c":null,"d":false,"text":"中文\\n\\uD83D\\uDE80"}')
    truth(Json.isArray(value.a)); equal(Json.isArray(value.b), false); equal(value.c, Json.null); equal(value.d, false)
    local result = Json.decode(Json.encode(Json.copy(value)))
    equal(result.text, "中文\n🚀"); equal(Json.encode(result.a), "[]"); equal(Json.encode(result.b), "{}")
end)
test("JSON rejects malformed or executable input", function()
    for _, text in ipairs({ '[1,]', '{"x":1,}', '01', '1e', '1.', '1e999', 'true false',
        'return os.execute("x")', '{"x":null,"x":2}', '"\\uD800"', '"\\uDC00"', '"\\z"', '"\n"' }) do
        raises(function() Json.decode(text) end)
    end
end)
test("JSON refuses sparse arrays, cycles and non-finite numbers", function()
    raises(function() Json.encode(Json.array({[2]=1})) end)
    raises(function() Json.encode(0/0) end)
    raises(function() Json.encode(math.huge) end)
    local cyclic = {}; cyclic.self = cyclic; raises(function() Json.encode(cyclic) end)
end)
