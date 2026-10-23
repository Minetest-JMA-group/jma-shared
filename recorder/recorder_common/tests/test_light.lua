-- Unit tests for the light layer codec: one byte per node, in the snapshot's
-- flat-array order.

local function script_dir()
	local src = debug.getinfo(1, "S").source:sub(2)  -- strip the leading "@"
	if src:sub(1, 1) ~= "/" then
		src = (os.getenv("PWD") or ".") .. "/" .. src
	end
	return src:match("^(.*)/[^/]+$")
end

local modpath = script_dir():gsub("/tests$", "")
local light = dofile(modpath .. "/light.lua")

local checks = 0
local function check(condition, message)
	checks = checks + 1
	if not condition then
		error("FAILED: " .. message, 2)
	end
	print("  ok - " .. message)
end

print("=== round trip ===")
local values = {}
for i = 1, 300 do values[i] = (i * 7) % 256 end
local body = light.encode(values, 300)
check(#body == 300, "one byte per node")
local back, err = light.decode(body, 300)
check(back ~= nil, "the body decodes: " .. tostring(err))
local same = true
for i = 1, 300 do
	if back[i] ~= values[i] then same = false break end
end
check(same, "every value survives")

print("=== the encoder fed byte by byte ===")
local encoder = light.encoder()
for i = 1, 300 do encoder:add(values[i]) end
check(encoder:finish() == body, "an incremental encoder builds the same body")

print("=== byte boundaries ===")
local edges = light.encode({0, 1, 127, 128, 254, 255}, 6)
local edge_values = light.decode(edges, 6)
check(edge_values[1] == 0 and edge_values[6] == 255, "the ends of the byte range survive")
check(light.decode(light.encode({-4, 300}, 2), 2)[1] == 0, "a negative value is clamped")
check(light.decode(light.encode({-4, 300}, 2), 2)[2] == 255, "a value above 255 is clamped")
check(light.encode({}, 0) == "", "an empty layer is an empty string")

print("=== bad bodies ===")
local none, err_none = light.decode("abc", 4)
check(none == nil and tostring(err_none):find("3 bytes", 1, true) ~= nil,
	"a body of the wrong size is refused and says why")
check(light.decode(nil, 4) == nil, "a nil body is refused")

print(("\n%d checks passed"):format(checks))
