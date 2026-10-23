-- Unit tests for the snapshot body codec: the bytes that carry a region's
-- non-air nodes into a recording and back out of one.

local function script_dir()
	local src = debug.getinfo(1, "S").source:sub(2)  -- strip the leading "@"
	if src:sub(1, 1) ~= "/" then
		src = (os.getenv("PWD") or ".") .. "/" .. src
	end
	return src:match("^(.*)/[^/]+$")
end

local modpath = script_dir():gsub("/tests$", "")
local snapshot = dofile(modpath .. "/snapshot.lua")

local checks = 0
local function check(condition, message)
	checks = checks + 1
	if not condition then
		error("FAILED: " .. message, 2)
	end
	print("  ok - " .. message)
end

local function same(actual, expected)
	if not actual or #actual ~= #expected then return false end
	for i = 1, #expected do
		if actual[i].i ~= expected[i].i or actual[i].n ~= expected[i].n or actual[i].p ~= expected[i].p then
			return false
		end
	end
	return true
end

print("=== round-trip ===")
check(snapshot.encode({}) == "", "an empty snapshot is empty bytes")
local empty = snapshot.decode("")
check(empty ~= nil and #empty == 0, "and decodes to no entries")

local entries = {
	{i = 1, n = 1, p = 0},
	{i = 2, n = 2, p = 7},
	{i = 132, n = 1, p = 255},          -- delta 130 needs two varint bytes
	{i = 70132, n = 300, p = 1},        -- delta 70000, and a two-byte name index
	{i = 3070132, n = 65535, p = 0},    -- delta 3000000 needs four varint bytes
}
local body = snapshot.encode(entries)
check(type(body) == "string", "a snapshot encodes")
local back = snapshot.decode(body)
check(back ~= nil, "and decodes")
check(same(back, entries), "with every index, name and param2 unchanged")

print("=== the encoder fed one entry at a time ===")
local encoder = snapshot.encoder()
local fed = true
for _, entry in ipairs(entries) do
	if not encoder:add(entry.i, entry.n, entry.p) then fed = false end
end
check(fed and encoder:finish() == body, "an incremental encoder builds the same body")
local strict = snapshot.encoder()
check(strict:add(1, 1) == true and strict:add(1, 1) == nil,
	"an index that does not advance is refused")

print("=== air is not stored ===")
-- One node a million positions into the region costs a few bytes, not one
-- entry per air node.
local sparse = snapshot.encode({{i = 1000000, n = 1, p = 0}})
check(#sparse <= 10, "a lone far-away node costs a few bytes: " .. #sparse)
check(same(snapshot.decode(sparse), {{i = 1000000, n = 1, p = 0}}), "and decodes back")

print("=== rejected input ===")
check(snapshot.encode({{i = 2, n = 1}, {i = 2, n = 1}}) == nil, "indexes must strictly increase")
check(snapshot.encode({{i = 1, n = 0}}) == nil, "name index 0 is refused")
check(snapshot.encode({{i = 1, n = 65536}}) == nil, "name index beyond u16 is refused")
check(snapshot.encode({{i = 1, n = 1, p = 256}}) == nil, "param2 beyond 255 is refused")
check(snapshot.encode({{i = 1, n = 1, p = -1}}) == nil, "negative param2 is refused")
check(snapshot.encode({{i = 1.5, n = 1}}) == nil, "a fractional index is refused")
check(snapshot.encode({{i = 1, n = 1.5}}) == nil, "a fractional name index is refused")
check(snapshot.encode({{i = 1, n = 1, p = 0.5}}) == nil, "a fractional param2 is refused")

check(snapshot.decode(1) == nil, "a body that is not a string is refused")
check(snapshot.decode(body:sub(1, #body - 1)) == nil, "a truncated body is refused")
check(snapshot.decode(string.char(255)) == nil, "a body ending inside an index is refused")
check(snapshot.decode(string.rep("\255", 5)) == nil, "five continuation bytes are refused")
check(snapshot.decode(string.char(1, 0, 0, 0)) == nil, "a zero name index in the bytes is refused")

-- A zero delta would make the next entry repeat the previous position.
local zero_delta = snapshot.encode({{i = 5, n = 1}}) .. string.char(0, 1, 0)
check(snapshot.decode(zero_delta) == nil, "a zero delta is refused")

print(("\n%d checks passed"):format(checks))
