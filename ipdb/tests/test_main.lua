-- Integration test: runs the REAL dbmanager.lua against a real SQLite file
-- with a mocked Minetest core. Covers: fresh install -> v5, merge logging,
-- history queries, rollback with original id restoration, AUTOINCREMENT.
--
-- Usage: luajit test_main.lua  (from the tests directory or anywhere)

local function script_dir()
	local src = debug.getinfo(1, "S").source:sub(2)  -- strip the leading "@"
	if src:sub(1, 1) ~= "/" then
		src = (os.getenv("PWD") or ".") .. "/" .. src
	end
	return src:match("^(.*)/[^/]+$")
end

local testdir = script_dir()
local modpath = testdir:gsub("/tests$", "")
local tmpbase = os.getenv("TMPDIR") or "/tmp"
local world = tmpbase .. "/ipdb_tests/world_main"

local core = {
	get_current_modname = function() return "ipdb" end,
	get_modpath = function() return modpath end,
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
os.remove(world .. "/ipdb.sqlite")

local dbmanager = dofile(modpath .. "/dbmanager.lua")
local sqlite = require("lsqlite3")

-- ── 1. Fresh install: v0 -> v5 =========================================
local dbconn = dbmanager.init_ipdb(sqlite)
check(dbconn ~= nil, "init_ipdb succeeds on fresh database")
check(dbconn.version == 5, "fresh database lands on version 5")
local db = dbconn.db
local row = {}
for r in db:nrows("SELECT sql FROM sqlite_master WHERE name='UserEntry'") do row = r end
check(row.sql and row.sql:find("AUTOINCREMENT", 1, true) ~= nil, "UserEntry has AUTOINCREMENT")
local tcount = 0
for r in db:nrows("SELECT COUNT(*) AS c FROM sqlite_master WHERE type='trigger'") do tcount = r.c end
check(tcount == 4, "fresh install has 4 cleanup triggers")
local icol = 0
for r in db:nrows("SELECT COUNT(*) AS c FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%'") do icol = r.c end
check(icol == 10, "fresh install has 10 indexes")
local reverted_col = false
for r in db:nrows("PRAGMA table_info(MergeEvent)") do if r.name == "reverted_at" then reverted_col = true end end
check(reverted_col, "MergeEvent.reverted_at exists")
local idx2 = 0
for r in db:nrows("SELECT COUNT(*) AS c FROM sqlite_master WHERE name='idx_mergeevent_dst_timestamp'") do idx2 = r.c end
check(idx2 == 1, "idx_mergeevent_dst_timestamp exists")

-- ── 2. Seed data and simulate a merge B -> A =============================
local A = dbmanager.new_entry()
dbmanager.add_name(A, "alice")
dbmanager.add_ip(A, "1.1.1.1")
dbmanager.insert_into_modstorage(A, "auth", "is_banned", "false")
local B = dbmanager.new_entry()
dbmanager.add_name(B, "bob")
dbmanager.add_ip(B, "2.2.2.2")
dbmanager.insert_into_modstorage(B, "auth", "is_banned", "true")
-- the merge path as done by register_new_ids
local okm, errm = pcall(function()
	dbmanager.new_merge_event(B, A, "alice", "2.2.2.2")
	local bob = dbmanager.user_exists("bob")
	local ip22 = dbmanager.ip_exists("2.2.2.2")
	dbmanager.reassociate_ids(A, bob.id, ip22.id)
	dbmanager.delete_entry(B)
end)
check(okm, "simulated merge succeeds")
local merges = dbmanager.get_merge_events(10)
check(#merges == 1, "get_merge_events returns 1 event")
check(merges[1].name_count == 1 and merges[1].ip_count == 1, "event has snapshot counts")
local logt = dbmanager.get_merge_log(merges[1].id)
check(#logt.names == 1 and #logt.ips == 1 and #logt.modstorage == 2, "merge log has 1 name, 1 ip, 2 modstorage rows")
local log_bob = logt.names[1]
local log_ip = logt.ips[1]

-- an identifier created after the merge (ownership ambiguous)
dbmanager.add_name(A, "carol")
db:exec("UPDATE Usernames SET created_at = datetime('now', '+1 minute') WHERE name = 'carol'")

-- ── 3. History queries ==================================================
local ok_t, tree, terr = pcall(dbmanager.get_merge_tree, A, 4)
check(ok_t and tree ~= nil, "get_merge_tree on live entry succeeds")
check(tree.root.children ~= nil and #tree.root.children == 2, "root has two children (src + continuation)")
check(tree.root.children[1].kind == "src" and tree.root.children[1].entry_id == B, "src child is the absorbed entry")
check(tree.root.children[2].kind == "cont" and tree.root.children[2].entry_id == A, "cont child is the same entry before the merge")
check(#tree.root.children[1].names == 1 and tree.root.children[1].names[1] == "bob", "src child shows the logged identifiers")
check(tree.root.children[2].names[1] == "alice", "cont child shows identifiers as of the merge")
local ok_t2, tree2 = pcall(dbmanager.get_merge_tree, B, 4)
check(not ok_t2 or tree2 == nil, "tree of a dead entry id is refused")

-- ── 4. Rollback info and rollback =======================================
local ok_i, info, reason = pcall(dbmanager.get_merge_rollback_info, merges[1].id)
check(ok_i and info ~= nil, "rollback info available")
check(#info.additions == 1 and info.additions[1].value == "carol", "carol identified as post-merge addition")

local ok_r, report, rreason = pcall(dbmanager.rollback_merge, merges[1].id, { carol = "keep" })
check(ok_r and report ~= nil, "rollback succeeds")
check(report.src_id == B, "source entry recreated with its ORIGINAL id")
local b2 = dbmanager.get_userentry(B)
check(b2 ~= nil, "entry #B exists again after rollback")
check(dbmanager.user_exists("bob").userentry_id == B, "bob moved back to entry #B")
check(dbmanager.ip_exists("2.2.2.2").userentry_id == B, "2.2.2.2 moved back to entry #B")
check(dbmanager.user_exists("bob").created_at == log_bob.created_at, "bob's created_at restored from the log")
check(dbmanager.user_exists("bob").last_seen == log_bob.last_seen, "bob's last_seen restored from the log")
local a_ban = dbmanager.get_from_modstorage(A, "auth", "is_banned")
local b_ban = dbmanager.get_from_modstorage(B, "auth", "is_banned")
check(next(a_ban) ~= nil and next(b_ban) ~= nil, "both entries have modstorage again")
local a_val, b_val
for _, v in pairs(a_ban) do a_val = v.value end
for _, v in pairs(b_ban) do b_val = v.value end
check(a_val == "false", "A's modstorage restored to pre-merge value")
check(b_val == "true", "B's modstorage restored to pre-merge value")
check(dbmanager.user_exists("carol").userentry_id == A, "carol kept at the destination (plan=keep)")
check(dbmanager.get_merge_event(merges[1].id).reverted_at ~= nil, "merge marked as reverted")
local ok_r2, rep2, reason2 = pcall(dbmanager.rollback_merge, merges[1].id)
check(ok_r2 and rep2 == nil and reason2:find("already been rolled back", 1, true), "second rollback refused")

-- ── 5. Tree after rollback ==============================================
local ok_t3, tree3 = pcall(dbmanager.get_merge_tree, A, 4)
check(ok_t3 and tree3.root.children == nil, "tree from A is a leaf after rollback (reverted merges skipped)")

-- ── 6. AUTOINCREMENT: ids are never reused ===============================
local max_before = 0
for r in db:nrows("SELECT MAX(id) AS m FROM UserEntry") do max_before = r.m end
dbmanager.delete_entry(max_before)
local fresh = dbmanager.new_entry()
check(fresh > max_before, "new entry id is greater than the deleted max (no reuse)")
dbmanager.delete_entry(fresh)

print(string.format("\n%d passed, %d failed", ok, fail))
if fail > 0 then os.exit(1) end
