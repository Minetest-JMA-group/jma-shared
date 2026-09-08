-- Two-phase upgrade test for the real dbmanager.lua. The mod is copied to a
-- temporary directory so that migration_4.sql can be toggled there:
--   luajit test_upgrade.lua build-v4   (migration_4.sql removed from the copy)
--   luajit test_upgrade.lua upgrade    (migration_4.sql copied back in)
-- Each phase runs in its own process because init_ipdb is a once-per-process
-- initializer. Run both phases in order via run_tests.sh.

local function script_dir()
	local src = debug.getinfo(1, "S").source:sub(2)  -- strip the leading "@"
	if src:sub(1, 1) ~= "/" then
		src = (os.getenv("PWD") or ".") .. "/" .. src
	end
	return src:match("^(.*)/[^/]+$")
end

local mode = arg[1]
local testdir = script_dir()
local modpath = testdir:gsub("/tests$", "")
local tmpbase = os.getenv("TMPDIR") or "/tmp"
local temp_mod = tmpbase .. "/ipdb_tests/mod"
local world = tmpbase .. "/ipdb_tests/world_upgrade"

local core = {
	get_current_modname = function() return "ipdb" end,
	get_modpath = function() return temp_mod end,
	get_worldpath = function() return world end,
	log = function(level, msg) print("[log]", level or "", msg or "") end,
	get_dir_list = function(path)
		local out = {}
		local p = io.popen("ls -p " .. path .. " 2>/dev/null")
		for f in p:lines() do
			if not f:find("/$") then table.insert(out, f) end
		end
		p:close()
		return out
	end,
}
_G.core = core

local ok, fail = 0, 0
local function check(cond, name)
	if cond then ok = ok + 1 print("PASS:", name)
	else fail = fail + 1 print("FAIL:", name) end
end

os.execute("mkdir -p " .. world)

if mode == "build-v4" then
	-- fresh copy of the mod without the v5 migration
	os.execute("rm -rf " .. temp_mod)
	os.execute("mkdir -p " .. temp_mod)
	os.execute("cp -r " .. modpath .. "/. " .. temp_mod .. "/")
	os.execute("rm -f " .. temp_mod .. "/migration_4.sql")
	os.execute("rm -rf " .. temp_mod .. "/tests")
	os.remove(world .. "/ipdb.sqlite")
	local dbmanager = dofile(temp_mod .. "/dbmanager.lua")
	local sqlite = require("lsqlite3")
	local dbconn = dbmanager.init_ipdb(sqlite)
	check(dbconn and dbconn.version == 4, "build-v4: lands on version 4")
	local db = dbconn.db
	-- Entries are created in an order that makes B4 the max id when it dies,
	-- so its id can be reused afterwards (as happened in production)
	local A4 = dbmanager.new_entry()  -- 1
	dbmanager.add_name(A4, "alice")
	dbmanager.add_ip(A4, "1.1.1.1")
	local C4 = dbmanager.new_entry()  -- 2
	dbmanager.add_name(C4, "carol")
	dbmanager.add_ip(C4, "3.3.3.3")
	local B4 = dbmanager.new_entry()  -- 3
	dbmanager.add_name(B4, "bob")
	dbmanager.add_ip(B4, "2.2.2.2")
	-- merge M1: C4 absorbed into B4
	local okm1 = pcall(function()
		dbmanager.new_merge_event(C4, B4, "bob", "3.3.3.3")
		local carol = dbmanager.user_exists("carol")
		local ip33 = dbmanager.ip_exists("3.3.3.3")
		dbmanager.reassociate_ids(B4, carol.id, ip33.id)
		dbmanager.delete_entry(C4)
	end)
	check(okm1, "build-v4: merge M1 logged")
	-- merge M2: B4 absorbed into A4; every identifier of B4 is moved, exactly
	-- like the real merge path does (B4's id is the max and gets freed)
	local okm2 = pcall(function()
		dbmanager.new_merge_event(B4, A4, "alice", "2.2.2.2")
		local bob = dbmanager.user_exists("bob")
		local carol = dbmanager.user_exists("carol")
		local ip22 = dbmanager.ip_exists("2.2.2.2")
		local ip33 = dbmanager.ip_exists("3.3.3.3")
		dbmanager.reassociate_ids(A4, bob.id, ip22.id)
		dbmanager.reassociate_ids(A4, carol.id, ip33.id)
		dbmanager.delete_entry(B4)
	end)
	check(okm2, "build-v4: merge M2 logged")
	local n = 0
	for r in db:nrows("SELECT COUNT(*) AS c FROM MergeEvent") do n = r.c end
	check(n == 2, "build-v4: two merge events logged")
	print("build-v4 done")
	if fail > 0 then os.exit(1) end
elseif mode == "upgrade" then
	-- the temporary mod copy from the build-v4 phase, with the migration back
	os.execute("cp " .. modpath .. "/migration_4.sql " .. temp_mod .. "/")
	local dbmanager = dofile(temp_mod .. "/dbmanager.lua")
	local sqlite = require("lsqlite3")
	local dbconn = dbmanager.init_ipdb(sqlite)
	check(dbconn and dbconn.version == 5, "upgrade: lands on version 5")
	check(dbmanager.user_exists("alice") ~= nil and dbmanager.user_exists("bob") ~= nil
	      and dbmanager.user_exists("carol") ~= nil, "upgrade: data preserved")
	local evs = dbmanager.get_merge_events(10)
	check(#evs == 2, "upgrade: merge history preserved")
	local m1, m2 = dbmanager.get_merge_event(1), dbmanager.get_merge_event(2)
	check(m1 and m1.entry_src == 2 and m1.entry_dst == 3, "upgrade: M1 (2 into 3) references intact")
	check(m2 and m2.entry_src == 3 and m2.entry_dst == 1, "upgrade: M2 (3 into 1) references intact")
	check(m1.reverted_at == nil and m2.reverted_at == nil, "upgrade: reverted_at column readable")
	-- Entry ids are unambiguous (AUTOINCREMENT): rolling M2 back restores id 3,
	-- and entry 3's own older history (M1) stays visible in its tree instead of
	-- being mistaken for a foreign entry's history
	local ok_r, report = pcall(dbmanager.rollback_merge, 2, {})
	check(ok_r and report ~= nil, "upgrade: rollback of M2 succeeds")
	local tree = dbmanager.get_merge_tree(3, 4)
	check(tree ~= nil and tree.children ~= nil, "upgrade: recreated entry #3 has a history")
	check(tree.children[1].kind == "src" and tree.children[1].entry_id == 2,
	      "upgrade: tree of #3 shows M1 (entry 2 absorbed into 3)")
	-- AUTOINCREMENT active after the upgrade
	local maxid = 0
	for r in dbconn.db:nrows("SELECT MAX(id) AS m FROM UserEntry") do maxid = r.m end
	dbmanager.delete_entry(maxid)
	local fresh = dbmanager.new_entry()
	check(fresh > maxid, "upgrade: no id reuse after upgrade")
	print("upgrade done")
	if fail > 0 then os.exit(1) end
else
	print("usage: build-v4|upgrade")
	os.exit(1)
end
