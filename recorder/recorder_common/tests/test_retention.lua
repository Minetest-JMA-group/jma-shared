-- Retention's file recognition, ordering, limits, and protection of open files.
local root = debug.getinfo(1, "S").source:sub(2):match("^(.*)/tests/[^/]+$") or ".."
local mocklib = dofile(root .. "/tests/mocklib.lua")
local world = (os.getenv("TMPDIR") or "/tmp") .. "/recorder_common_tests/retention"
os.execute("rm -rf " .. world)
os.execute("mkdir -p " .. world .. "/recordings")
local mock = mocklib.new({modpaths = {recorder_common = root}, world = world})
core = mock.core
recorder, recorder_replay = nil, nil
dofile(root .. "/init.lua")
local common = recorder_common
local checks = 0
local function check(ok, message)
	assert(ok, message)
	checks = checks + 1
	print("  ok - " .. message)
end
local files = {}
local function clear()
	for _, path in ipairs(files) do
		for _, suffix in ipairs({"", "-wal", "-shm"}) do os.remove(path .. suffix) end
	end
	files = {}
	for _, key in ipairs({"count", "size_mb", "age"}) do
		common.settings:reset("recorder.retention_" .. key)
	end
	recorder, recorder_replay = nil, nil
end
local function write(path, data)
	local f = assert(io.open(path, "wb")); assert(f:write(data)); f:close()
end
local function fixture(name, extra)
	local path = world .. "/recordings/" .. name .. ".sqlite"
	files[#files + 1] = path
	-- The on-disk identity checked by retention is independent of SQL tables.
	write(path, "SQLite format 3\0" .. string.rep("\0", 52) .. "JMAR" .. (extra or ""))
	return path
end
local old = fixture("z-map-20260101T000000Z")
local newest = fixture("a-map-20260103T000000Z")
local middle = fixture("m-map-20260102T000000Z")
check(common.retention.prune() == 0 and common.file_exists(old), "all limits are disabled by default")
common.settings:set("recorder.retention_count", "2")
check(common.retention.prune() == 1 and not common.file_exists(old), "oldest means timestamp, not map-name order")
check(common.file_exists(newest) and common.file_exists(middle), "the newest two recordings remain")
clear()
old = fixture("old-20260101T000000Z")
middle = fixture("middle-20260102T000000Z")
newest = fixture("new-20260103T000000Z")
recorder = {list = function() return {{path = old}} end}
recorder_replay = {sessions = {list = function() return {{path = world .. "/recordings/./middle-20260102T000000Z.sqlite"}} end}}
common.settings:set("recorder.retention_count", "1")
check(common.retention.prune() == 1 and not common.file_exists(newest), "in-use recordings are protected even when the quota cannot be met")
check(common.file_exists(old) and common.file_exists(middle), "capture and replay paths are both protected")
recorder, recorder_replay = nil, nil
check(common.retention.prune() == 1 and not common.file_exists(old), "an unprotected recording becomes eligible on the next cleanup")
clear()
old = fixture("old-20260101T000000Z")
newest = fixture("new-20260103T000000Z")
write(old .. "-wal", string.rep("x", 1024))
write(old .. "-shm", string.rep("x", 128))
common.settings:set("recorder.retention_size_mb", tostring(200 / (1024 * 1024)))
check(common.retention.prune() == 1 and not common.file_exists(old), "sidecars count toward the storage budget")
check(not common.file_exists(old .. "-wal") and not common.file_exists(old .. "-shm"), "sidecars are deleted with their recording")
check(common.file_exists(newest), "the smaller newest recording fits the budget")
clear()
old = fixture("old-20260101T000000Z")
middle = fixture("middle-20260102T000000Z")
newest = fixture("new-20260103T000000Z")
local foreign = fixture("foreign-20260101T000000Z")
write(foreign, "not a recording")
local renamed = fixture("unrecognized-name")
common.settings:set("recorder.retention_age", "1d")
common.settings:set("recorder.retention_count", "1")
-- Jan 3 2026 12:00 UTC: first delete Jan 1 and Jan 2 by age, leaving Jan 3.
check(common.retention.prune(1767441600) == 2, "age and count limits are applied together")
check(common.file_exists(newest), "age is measured from the UTC recording start time")
check(common.file_exists(foreign) and common.file_exists(renamed), "foreign files and unrecognized names are untouched")
clear()
old = fixture("old-20200101T000000Z")
common.settings:set("recorder.retention_age", "1d")
mock.step(60)
check(not common.file_exists(old), "periodic cleanup expires recordings without a new match")
clear()
old = fixture("old-20200101T000000Z")
common.settings:set("recorder.retention_age", "1d")
dofile(root .. "/retention.lua")
check(not common.file_exists(old), "load-time cleanup applies enabled retention defaults")
clear()
old = fixture("old-20260101T000000Z")
middle = fixture("middle-20260102T000000Z")
newest = fixture("new-20260103T000000Z")
common.settings:set("recorder.retention_count", "1")
local remove = os.remove
os.remove = function(path)
	if path == old then return nil, "simulated deletion failure" end
	return remove(path)
end
local removed = common.retention.prune()
os.remove = remove
check(removed == 2 and common.file_exists(old), "failed deletions remain counted while cleanup tries other eligible files")
check(#mock.logs > 0 and mock.logs[#mock.logs].message:find("retention", 1, true), "cleanup reports its outcome")
clear()
old = fixture("leap-20240229T235959Z-2")
local invalid = fixture("invalid-20240230T235959Z")
common.settings:set("recorder.retention_age", "1s")
check(common.retention.prune(1709251200) == 0, "a leap-day recording remains at the exact age boundary")
check(common.retention.prune(1709251201) == 1 and not common.file_exists(old),
	"leap-day dates and generated collision suffixes have the correct UTC age")
check(common.file_exists(invalid), "invalid calendar timestamps are not eligible")
clear()
old = fixture("same-20260101T000000Z")
middle = fixture("same-20260101T000000Z-2")
newest = fixture("same-20260101T000000Z-10")
common.settings:set("recorder.retention_count", "1")
check(common.retention.prune() == 2 and common.file_exists(newest),
	"same-second filename collisions are ordered by their numeric sequence")
clear()
print(checks .. " checks passed")
