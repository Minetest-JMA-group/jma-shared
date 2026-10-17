-- The capture-side snapshot: emerge, read, walk the region in slices, encode,
-- and leave the known state behind for the mapblock-changed diff.

local function script_dir()
	local src = debug.getinfo(1, "S").source:sub(2)  -- strip the leading "@"
	if src:sub(1, 1) ~= "/" then
		src = (os.getenv("PWD") or ".") .. "/" .. src
	end
	return src:match("^(.*)/[^/]+$")
end

local testdir = script_dir()
local modpath = testdir:gsub("/tests$", "")
local commonpath = modpath:gsub("/recorder_capture$", "/recorder_common")
local tmpbase = os.getenv("TMPDIR") or "/tmp"
local world = tmpbase .. "/recorder_tests/snapshot"
os.execute("rm -rf " .. world)
os.execute("mkdir -p " .. world)

local mocklib = dofile(commonpath .. "/tests/mocklib.lua")
local mock = mocklib.new({
	modpaths = {recorder_capture = modpath, recorder_common = commonpath},
	world = world,
})
core = mock.core
dofile(commonpath .. "/init.lua")
local snapshot = dofile(modpath .. "/snapshot.lua")
local region = recorder_common.region
local codec = recorder_common.snapshot

local checks = 0
local function check(condition, message)
	checks = checks + 1
	if not condition then
		error("FAILED: " .. message, 2)
	end
	print("  ok - " .. message)
end

local function step_until_done(snap, budget)
	local steps = 0
	while true do
		local state, result = snapshot.step(snap, budget)
		steps = steps + 1
		if state == "done" then return result, steps end
		if state == "failed" then error("snapshot failed: " .. tostring(result)) end
		if steps > 1000 then error("snapshot did not finish") end
	end
end

local p1, p2 = {x = 0, y = 0, z = 0}, {x = 3, y = 2, z = 1}  -- 4 x 3 x 2 = 24 nodes
local whole = {pos1 = p1, pos2 = p2}

----------------------------------------------------------------------------
print("=== a region with three nodes ===")
----------------------------------------------------------------------------
mock.set_node({x = 0, y = 0, z = 0}, {name = "default:stone"})
mock.set_node({x = 1, y = 1, z = 0}, {name = "default:stone"})
mock.set_node({x = 3, y = 2, z = 1}, {name = "default:dirt", param2 = 5})

local snap = snapshot.new(p1, p2)
check(snap ~= nil, "a snapshot is created")
local result = step_until_done(snap, 1000)
check(type(result.data) == "string" and #result.data > 0, "it produces a body")
check(result.encoding == "deflate", "compressed with the engine's deflate")

local entries = codec.decode(result.data)
check(entries ~= nil and #entries == 3, "three non-air nodes are stored")
local by_index = {}
for _, entry in ipairs(entries) do by_index[entry.i] = entry end
check(result.names[1] == "default:stone", "the first node names the first name")
check(by_index[region.index(whole, {x = 0, y = 0, z = 0})] ~= nil, "the low corner is an entry")
check(by_index[region.index(whole, {x = 1, y = 1, z = 0})] ~= nil, "so is a node in the middle")
local last = by_index[region.index(whole, {x = 3, y = 2, z = 1})]
check(last ~= nil, "and the far corner")
check(last and result.names[last.n] == "default:dirt", "with its name from the table")
check(last and last.p == 5, "and its param2")

check(#result.ids == region.volume(whole), "the known state covers every node in the region")
check(result.ids[region.index(whole, {x = 0, y = 0, z = 0})] == core.get_content_id("default:stone"),
	"a node's content id is in the known state")
check(result.ids[region.index(whole, {x = 2, y = 0, z = 0})] == core.CONTENT_AIR,
	"air is in the known state as air")
check(result.param2[region.index(whole, {x = 3, y = 2, z = 1})] == 5,
	"param2 is in the known state too")

----------------------------------------------------------------------------
print("=== the walk is sliced across steps ===")
----------------------------------------------------------------------------
local sliced = snapshot.new(p1, p2)
local states = {}
while true do
	local state = snapshot.step(sliced, 8)
	states[#states + 1] = state
	if state ~= "working" then break end
end
check(#states == 4, "24 nodes at 8 per step is three working steps and a done (got " .. #states .. ")")
check(states[#states] == "done", "the last step is the one that finishes")

local halfway = snapshot.new(p1, p2)
snapshot.step(halfway, 8)   -- emerge -> walk begins
snapshot.step(halfway, 8)
check(snapshot.progress(halfway) > 0 and snapshot.progress(halfway) < 1,
	"progress is reported while walking: " .. tostring(snapshot.progress(halfway)))
step_until_done(halfway, 8)
check(snapshot.progress(halfway) == 1, "and reaches 1 when done")

----------------------------------------------------------------------------
print("=== a region that is not fully emerged ===")
----------------------------------------------------------------------------
mock.set_node({x = 2, y = 2, z = 1}, {name = "ignore"})
local broken = snapshot.new(p1, p2)
local state, err
for _ = 1, 10 do
	state, err = snapshot.step(broken, 1000)
	if state ~= "working" then break end
end
check(state == "failed", "the snapshot fails rather than storing ignore nodes")
check(tostring(err):find("not fully emerged", 1, true) ~= nil, "and says why: " .. tostring(err))
mock.set_node({x = 2, y = 2, z = 1}, {name = "air"})

----------------------------------------------------------------------------
print("=== an empty region ===")
----------------------------------------------------------------------------
local empty = step_until_done(snapshot.new({x = 10, y = 10, z = 10}, {x = 11, y = 11, z = 11}), 1000)
check(#codec.decode(empty.data) == 0, "there are no entries")
check(#empty.names == 0, "and no names")
check(#empty.ids == 8, "but the known state still covers the region")

----------------------------------------------------------------------------
print("=== bad corners ===")
----------------------------------------------------------------------------
check(snapshot.new(nil, p2) == nil, "a snapshot needs two positions")
check(snapshot.new(p1, {x = "one", y = 0, z = 0}) == nil, "with numeric coordinates")

print(("\n%d checks passed"):format(checks))
