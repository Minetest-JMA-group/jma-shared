-- CLI and GUI smoke test: loads the REAL init.lua with a mocked engine,
-- seeds a merge, and exercises the new chat subcommands and the merge_gui
-- formspec flow against a real database.
--
-- Usage: luajit test_cli.lua  (from the tests directory or anywhere)

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
local world = tmpbase .. "/ipdb_tests/world_cli"

local chatcommands = {}
local formspecs = {}
local receive_fields_handler

local core = {
	get_current_modname = function() return "ipdb" end,
	get_modpath = function() return modpath end,
	get_worldpath = function() return world end,
	log = function() end,
	get_dir_list = function(path)
		local out = {}
		local p = io.popen("ls -p " .. path .. " 2>/dev/null")
		for f in p:lines() do
			if not f:find("/$") then table.insert(out, f) end
		end
		p:close()
		return out
	end,
	register_on_authplayer = function() end,
	register_chatcommand = function(cmd, def) chatcommands[cmd] = def end,
	register_on_player_receive_fields = function(handler) receive_fields_handler = handler end,
	after = function() end,
	chat_send_player = function() end,
	formspec_escape = function(s)
		return (tostring(s):gsub("[\\%]]", {["\\"] = "\\\\", ["]"] = "%]"}))
	end,
	show_formspec = function(name, formname, fs) formspecs[#formspecs + 1] = fs end,
}
_G.core = core

local algorithms = {
	require = function(name) return require(name) end,
	is_ip = function(s) return s:match("^%d+%.%d+%.%d+%.%d+$") ~= nil end,
	parse_time = function() return 100 end,
	is_trusted = function() return true end,
}
_G.algorithms = algorithms

os.execute("mkdir -p " .. world)
os.remove(world .. "/ipdb.sqlite")

assert(loadfile(modpath .. "/init.lua"))()

local cmd = chatcommands["ipdb"]
assert(cmd, "chatcommand /ipdb not registered")
assert(cmd.privs.ban, "/ipdb requires ban priv")

local dbmanager = ipdb.dbmanager
local db = ipdb.get_internal(5, "database")
assert(db, "could not get database handle")

-- seed: entries A and B, then merge B into A (as register_new_ids would)
local A = dbmanager.new_entry()
dbmanager.add_name(A, "alice")
dbmanager.add_ip(A, "1.1.1.1")
dbmanager.insert_into_modstorage(A, "auth", "is_banned", "false")
local B = dbmanager.new_entry()
dbmanager.add_name(B, "bob")
dbmanager.add_ip(B, "2.2.2.2")
dbmanager.insert_into_modstorage(B, "auth", "is_banned", "true")
dbmanager.new_merge_event(B, A, "alice", "2.2.2.2")
local bob = dbmanager.user_exists("bob")
local ip22 = dbmanager.ip_exists("2.2.2.2")
dbmanager.reassociate_ids(A, bob.id, ip22.id)
dbmanager.delete_entry(B)
-- an identifier created after the merge
dbmanager.add_name(A, "carol")
db:exec("UPDATE Usernames SET created_at = datetime('now', '+1 minute') WHERE name = 'carol'")

local passed, failed = 0, 0
local function expect(params, want_ok, want_substr)
	local ok, ret = cmd.func("tester", params)
	local good = (ok == want_ok) and (not want_substr or (ret and ret:find(want_substr, 1, true)))
	if good then
		passed = passed + 1
		print("PASS: /ipdb " .. params)
	else
		failed = failed + 1
		print("FAIL: /ipdb " .. params .. "  -> got ok=" .. tostring(ok) .. " ret=" .. tostring(ret))
	end
end

expect("merges 10", true, "1")
expect("merges 0", false, "Usage")
expect("merge 1", true, "triggered by alice / 2.2.2.2")
expect("merge 1", true, "rollback possible")
expect("merge 999", true, "No such merge event")
expect("tree alice 3", true, "absorbed by #1")
expect("tree alice 3", true, "current")
expect("tree 999 3", true, "unknown")
expect("tree", false, "Usage")
expect("unmerge 1", false, "created after this merge")
expect("unmerge 1 keep", true, "rolled back")
expect("unmerge 1", false, "already been rolled back")
expect("merge 1", true, "rolled back on")
expect("tree alice 3", true, "current")
expect("merge_gui", true, "GUI opened")

-- seed a fresh merge for the GUI flow (the CLI section rolled the first one back)
local C = dbmanager.new_entry()
dbmanager.add_name(C, "dave")
dbmanager.add_ip(C, "4.4.4.4")
local D = dbmanager.new_entry()
dbmanager.add_name(D, "eve")
dbmanager.add_ip(D, "5.5.5.5")
dbmanager.new_merge_event(D, C, "dave", "5.5.5.5")
local eve = dbmanager.user_exists("eve")
local ip55 = dbmanager.ip_exists("5.5.5.5")
dbmanager.reassociate_ids(C, eve.id, ip55.id)
dbmanager.delete_entry(D)
dbmanager.add_name(C, "frank")
db:exec("UPDATE Usernames SET created_at = datetime('now', '+1 minute') WHERE name = 'frank'")

-- ── GUI flow: open -> show tree -> click node -> decide -> roll back ──────
local player = { get_player_name = function() return "tester" end }
local function gui(fields)
	assert(receive_fields_handler, "receive fields handler registered")
	receive_fields_handler(player, "ipdb:merge_gui", fields)
	return formspecs[#formspecs]
end

gui({ go = true, root = "dave", depth = "3" })
local tree_fs = formspecs[#formspecs]
assert(tree_fs:find("scroll_container"), "tree formspec has a scroll container")
assert(tree_fs:find("node_"), "tree formspec has node buttons")
assert(tree_fs:find("box%["), "tree formspec draws edges")
print("PASS: gui tree renders with nodes and edges")
assert(tree_fs:find("node_%d+_2"), "a node carries the merge id")
local eid = tree_fs:match("node_(%d+)_2")
print("clicking node", eid, "2")
gui({ ["node_" .. eid .. "_2"] = true })
local detail_fs = formspecs[#formspecs]
assert(detail_fs:find("frank"), "detail shows the post-merge identifier")
assert(detail_fs:find("ad_1_delete"), "detail offers per-identifier decisions")
print("PASS: gui detail shows additions with decisions")
gui({ ad_1_delete = true })
assert(formspecs[#formspecs]:find("delete", 1, true), "decision recorded")
gui({ rb = true })
assert(formspecs[#formspecs]:find("Confirm rollback"), "confirm screen shown")
gui({ rb_confirm = true })
local report_fs = formspecs[#formspecs]
assert(report_fs:find("rolled back"), "report screen shown")
print("PASS: gui rollback flow completes")

-- the merge is now reverted via the GUI
local ok4, ev = pcall(dbmanager.get_merge_event, 2)
assert(ok4 and ev.reverted_at ~= nil, "merge marked reverted by the GUI rollback")
print("PASS: gui rollback actually reverted the merge")

-- re-run the tree without the additions to see it as a leaf after rollback
local ok3, tree_out = cmd.func("tester", "tree alice 3")
assert(not tree_out:find("absorbed"), "tree is a leaf after rollback")
print("PASS: tree is a leaf after rollback")

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
