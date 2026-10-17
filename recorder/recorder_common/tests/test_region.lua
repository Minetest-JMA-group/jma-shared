-- Unit tests for the recording region: the box arithmetic both halves share.

local function script_dir()
	local src = debug.getinfo(1, "S").source:sub(2)  -- strip the leading "@"
	if src:sub(1, 1) ~= "/" then
		src = (os.getenv("PWD") or ".") .. "/" .. src
	end
	return src:match("^(.*)/[^/]+$")
end

local modpath = script_dir():gsub("/tests$", "")
local region = dofile(modpath .. "/region.lua")

local checks = 0
local function check(condition, message)
	checks = checks + 1
	if not condition then
		error("FAILED: " .. message, 2)
	end
	print("  ok - " .. message)
end

local function pos(x, y, z)
	return {x = x, y = y, z = z}
end

print("=== corners ===")
local r = region.normalize(pos(10, 20, 30), pos(0, -5, 15))
check(r.pos1.x == 0 and r.pos1.y == -5 and r.pos1.z == 15, "the corners are put in order")
check(r.pos2.x == 10 and r.pos2.y == 20 and r.pos2.z == 30, "both ways round")
local size = region.size(r)
check(size.x == 11 and size.y == 26 and size.z == 16, "the size counts both ends")
check(region.volume(r) == 11 * 26 * 16, "the volume is the product")

local floored = region.normalize(pos(0.7, 1.2, -0.1), pos(2, 3, 4))
check(floored.pos1.x == 0 and floored.pos1.y == 1 and floored.pos1.z == -1,
	"fractional coordinates are floored into the node they are in")
check(region.normalize(nil, pos(0, 0, 0)) == nil, "two positions are required")
check(region.normalize(pos(0, 0, 0), pos(0, "x", 0)) == nil, "coordinates must be numbers")
check(region.normalize({}, pos(0, 0, 0)) == nil, "a position must have x, y and z")

print("=== containment ===")
check(region.contains(r, pos(0, -5, 15)), "the low corner is inside")
check(region.contains(r, pos(10, 20, 30)), "the high corner is inside")
check(not region.contains(r, pos(-1, 0, 20)), "just outside on x is outside")
check(not region.contains(r, pos(0, 21, 20)), "just outside on y is outside")
check(not region.contains(r, pos(0, 0, 31)), "just outside on z is outside")
check(region.contains(r, pos(9.9, 0.5, 20.2)), "a fractional position is judged by its node")
check(not region.contains(r, nil), "nil is not inside")

print("=== flat indexes ===")
local small = region.normalize(pos(5, 10, 20), pos(7, 11, 21))  -- 3 x 2 x 2 = 12
check(region.index(small, pos(5, 10, 20)) == 1, "the low corner is index 1")
check(region.index(small, pos(6, 10, 20)) == 2, "x advances first")
check(region.index(small, pos(5, 11, 20)) == 4, "then y, by the x length")
check(region.index(small, pos(5, 10, 21)) == 7, "then z, by x*y")
check(region.index(small, pos(4, 10, 20)) == nil, "a position below the region has no index")
check(region.index(small, pos(5, 10, 22)) == nil, "nor one beyond it")

local first = region.position(small, 1)
check(first and first.x == 5 and first.y == 10 and first.z == 20, "index 1 maps back to the low corner")
local last = region.position(small, 12)
check(last and last.x == 7 and last.y == 11 and last.z == 21, "the last index maps back")
for i = 1, 12 do
	local back = region.position(small, i)
	check(back ~= nil and region.index(small, back) == i, "index " .. i .. " survives a round trip")
end
check(region.position(small, 0) == nil, "index 0 is outside")
check(region.position(small, 13) == nil, "index volume+1 is outside")
check(region.position(small, 1.5) == nil, "a fractional index is refused")

print("=== mapblocks ===")
local b1, b2 = region.blocks(region.normalize(pos(0, 0, 0), pos(15, 15, 15)))
check(b1.x == 0 and b1.y == 0 and b2.x == 0 and b2.y == 0, "a region inside one block touches one block")
b1, b2 = region.blocks(region.normalize(pos(0, 0, 0), pos(16, 0, 0)))
check(b1.x == 0 and b2.x == 16, "one node into the next block touches two")
b1, b2 = region.blocks(region.normalize(pos(-1, -1, -1), pos(-17, 0, 0)))
check(b1.x == -32 and b1.y == -16 and b2.x == -16, "negative coordinates round down to block bases")

print("=== overlapping ===")
local a = region.normalize(pos(0, 0, 0), pos(15, 15, 15))
local b = region.normalize(pos(16, 0, 0), pos(31, 15, 15))
check(not region.overlaps(a, b), "regions touching at a face do not overlap")
check(region.overlaps(a, region.normalize(pos(15, 15, 15), pos(30, 30, 30))), "sharing one node is an overlap")
check(region.overlaps(a, region.normalize(pos(1, 1, 1), pos(2, 2, 2))), "a nested region overlaps")
check(region.overlaps(a, a), "a region overlaps itself")

print(("\n%d checks passed"):format(checks))
