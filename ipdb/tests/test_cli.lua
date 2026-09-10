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
local chat_output  -- last message sent to a player, for commands that print

local core = {
	get_current_modname = function() return "ipdb" end,
	get_modpath = function() return modpath end,
	get_worldpath = function() return world end,
	log = function() end,
	get_dir_list = function(path)
		local out = {}
		-- %q quotes it: a modpath with a space would break 'ls' and hide the migrations
		local p = io.popen(string.format("ls -p %q 2>/dev/null", path))
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
	chat_send_player = function(_, msg) chat_output = msg end,
	formspec_escape = function(s)
		return (tostring(s):gsub("[\\%]]", {["\\"] = "\\\\", ["]"] = "%]"}))
	end,
	show_formspec = function(name, formname, fs) formspecs[#formspecs + 1] = fs end,
}
_G.core = core

local algorithms = {
	require = function(name) return require(name) end,
	is_ip = function(s) return s:match("^%d+%.%d+%.%d+%.%d+$") ~= nil end,
	-- same grammar as the real algorithms.parse_time: number followed by an
	-- optional unit (s/m/h/d/w/M/y; bare numbers are seconds)
	parse_time = function(t)
		if type(t) ~= "string" then return 0 end
		local unit_to_secs = { s = 1, m = 60, h = 3600, d = 86400, D = 86400, w = 604800, W = 604800, M = 2592000, y = 31536000, Y = 31536000 }
		local secs = 0
		for num, unit in t:gmatch("(%d+)([smhdDwWMYy]?)") do
			secs = secs + (tonumber(num) * (unit_to_secs[unit] or 1))
		end
		return secs
	end,
	is_trusted = function() return true end,
}
_G.algorithms = algorithms

-- the engine ships a global dump() for printing tables; `list` prints with it
_G.dump = function(t)
	local out = {}
	for k, v in pairs(t) do
		if type(v) == "table" then
			out[#out + 1] = k .. "={" .. table.concat(v, ",") .. "}"
		else
			out[#out + 1] = k .. "=" .. tostring(v)
		end
	end
	return table.concat(out, " ")
end

os.execute(string.format("mkdir -p %q", world))
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
expect("log_retention", true, "kept for 1296000")
expect("log_retention 2D", true, "2D (172800 seconds)")
expect("log_retention", true, "kept for 172800")
expect("log_retention 0", false, "Usage")
expect("log_retention nonsense", false, "Usage")
-- the value must actually land in Metadata (it is re-read on server restart)
local stored_retention = dbmanager.get_meta("merge_log_retention")
assert(stored_retention == "172800", "log_retention persists to Metadata, got " .. tostring(stored_retention))
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

-- every scrollbar[] element in a formspec must carry its required value field
-- (5 semicolon-separated parts) - the engine drops the element otherwise
local function assert_valid_scrollbars(fs, ctx)
	local total = 0
	for _ in fs:gmatch("scrollbar%[") do total = total + 1 end
	local valid = 0
	for _ in fs:gmatch("scrollbar%[[^]]*;[^]]*;[^]]*;[^]]*;[%d]+%]") do valid = valid + 1 end
	assert(valid == total, ctx .. ": " .. total .. " scrollbar element(s), only " .. valid .. " have all 5 fields")
	return total
end

gui({ go = true, root = "dave", depth = "3" })
local tree_fs = formspecs[#formspecs]
assert(tree_fs:find("node_"), "tree formspec has node buttons")
assert(tree_fs:find("box%["), "tree formspec draws edges")
assert_valid_scrollbars(tree_fs, "single-merge tree")
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

-- ── deep chain: the canvas overflows and gets working scrollbars ──────────
-- eight sequential merges into one entry, all within the same wall-clock
-- second: the history walk orders merges by event id, so the whole chain
-- must still be visible (a timestamp-based walk would stop after the first)
local base_entry = dbmanager.new_entry()
dbmanager.add_name(base_entry, "target")
dbmanager.add_ip(base_entry, "10.0.0.1")
for i = 1, 8 do
	local p = dbmanager.new_entry()
	dbmanager.add_name(p, "p" .. i)
	dbmanager.add_ip(p, "10.0.0." .. (i + 1))
	db:exec("BEGIN")
	dbmanager.new_merge_event(p, base_entry, "target", "10.0.0." .. (i + 1))
	dbmanager.reassociate_entry(p, base_entry)
	db:exec("COMMIT")
end

gui({ go = true, root = "target", depth = "8" })
local deep_fs = formspecs[#formspecs]
assert(deep_fs:find("merge_scroll_h"), "deep tree gets a horizontal scrollbar")
assert(deep_fs:find("scroll_container%["), "deep tree content is inside a scroll container")
assert_valid_scrollbars(deep_fs, "deep tree")
-- the oldest chain merge and the newest one both have nodes: the whole
-- same-second chain was walked, not just its last event
assert(deep_fs:find("node_%d+_10"), "newest chain merge is in the tree")
assert(deep_fs:find("node_%d+_3"), "oldest same-second chain merge is in the tree")
print("PASS: gui deep tree renders with a valid horizontal scrollbar")
-- clicking a deep node (carrying merge id 8) opens its detail; the scroll
-- position sent along with the click is remembered
gui({ merge_scroll_h = "33", ["node_" .. (deep_fs:match("node_(%d+)_8") or "") .. "_8"] = true })
assert(formspecs[#formspecs]:find("Merge #8", 1, true), "clicking a deep node opens its merge detail")
print("PASS: gui deep node click works")
gui({ back = true })
assert(formspecs[#formspecs]:find(";merge_scroll_h;33]"), "scroll position survives re-renders")
print("PASS: gui scroll position is kept across re-renders")

-- ── the production merge path (register_new_ids): identifier timestamps ───
-- must survive the move, so that created_at keeps meaning "first seen"
local zoe = dbmanager.new_entry()
dbmanager.add_name(zoe, "zoe")
dbmanager.add_ip(zoe, "9.9.9.9")
local ghost = dbmanager.new_entry()
dbmanager.add_name(ghost, "ghost")
dbmanager.add_ip(ghost, "8.8.8.8")
db:exec("UPDATE Usernames SET created_at = datetime('now', '-30 days'), last_seen = datetime('now', '-30 days') WHERE name = 'ghost'")
db:exec("UPDATE IPs SET created_at = datetime('now', '-30 days'), last_seen = datetime('now', '-30 days') WHERE ip = '8.8.8.8'")
local g_name_before = dbmanager.user_exists("ghost")
local g_ip_before = dbmanager.ip_exists("8.8.8.8")
local month_ago = os.date("!%Y-%m-%d %H:%M:%S", os.time() - 25 * 86400)
assert(g_name_before.created_at < month_ago, "ghost's identifiers are backdated")
-- zoe logs in from ghost's IP: ghost's entry is absorbed into zoe's entry
assert(not ipdb.register_new_ids("zoe", "8.8.8.8"), "register_new_ids performs the merge")
local g_name = dbmanager.user_exists("ghost")
local g_ip = dbmanager.ip_exists("8.8.8.8")
assert(g_name and g_name.userentry_id == zoe, "ghost now lives on zoe's entry")
assert(g_ip and g_ip.userentry_id == zoe, "8.8.8.8 now lives on zoe's entry")
assert(dbmanager.get_userentry(ghost) == nil, "the emptied source entry was removed by the cleanup triggers")
assert(g_name.created_at == g_name_before.created_at, "name created_at preserved through the merge")
assert(g_name.last_seen == g_name_before.last_seen, "name last_seen preserved through the merge")
assert(g_ip.created_at == g_ip_before.created_at, "ip created_at preserved through the merge")
assert(g_ip.last_seen ~= g_ip_before.last_seen, "the triggering ip's last_seen was bumped")
print("PASS: production merge preserves identifier timestamps")

-- ── depth truncation: the tree reports history cut off by the limit ───────
local tr = dbmanager.new_entry()
dbmanager.add_name(tr, "trunc")
dbmanager.add_ip(tr, "11.0.0.1")
for i = 1, 5 do
	local p = dbmanager.new_entry()
	dbmanager.add_name(p, "q" .. i)
	dbmanager.add_ip(p, "11.0.0." .. (i + 1))
	db:exec("BEGIN")
	dbmanager.new_merge_event(p, tr, "trunc", "11.0.0." .. (i + 1))
	dbmanager.reassociate_entry(p, tr)
	db:exec("COMMIT")
end
local ok_tn, trunc_ret = cmd.func("tester", "tree trunc 2")
assert(ok_tn and trunc_ret:find("3 older merge", 1, true),
       "shallow tree reports the hidden history: " .. tostring(trunc_ret))
print("PASS: shallow tree reports hidden older merges")
local ok_tn2, full_ret = cmd.func("tester", "tree trunc 8")
assert(ok_tn2 and not full_ret:find("older merge", 1, true), "full-depth tree has no truncation note")
print("PASS: full-depth tree has no truncation note")
-- the GUI shows the same note below the canvas
gui({ go = true, root = "trunc", depth = "2" })
assert(formspecs[#formspecs]:find("older merge", 1, true), "gui tree shows the truncation note")
print("PASS: gui tree shows the truncation note")
-- the tree's "before the merge" node must not list what arrived in the merge
local ok_t, troot = pcall(dbmanager.get_merge_tree, zoe, 4)
assert(ok_t and troot and troot.children and troot.children[1].kind == "src"
       and troot.children[1].entry_id == ghost, "absorbed entry is the src child")
assert(#troot.children[2].names == 1 and troot.children[2].names[1] == "zoe",
       "before-node lists only identifiers that predate the merge")
print("PASS: before-node excludes identifiers that arrived in the merge")

-- ── '#' entry ids: an id is spelled #N, a bare number is a username ───────
-- An all-digit username is legal, so a bare number must always be read as a
-- username - otherwise entry #N and the username "N" could never coexist.
do
	local numentry = dbmanager.new_entry()
	dbmanager.add_name(numentry, "1234")
	dbmanager.add_ip(numentry, "12.0.0.1")

	expect("tree "..numentry, true, "unknown to ipdb")
	expect("tree 1234", true, "current")
	expect("tree #"..numentry, true, "current")
	expect("tree #999", true, "does not exist")
	expect("tree #abc", true, "Malformed entry id")
	expect("tree #", true, "Malformed entry id")

	gui({ go = true, root = "#"..numentry, depth = "3" })
	assert(formspecs[#formspecs]:find("node_"..numentry.."_0", 1, true),
		"gui accepts an #id root")
	print("PASS: gui accepts an #id root")

	gui({ go = true, root = "#999", depth = "3" })
	assert(formspecs[#formspecs]:find("does not exist", 1, true),
		"gui reports a missing #id")
	gui({ go = true, root = "#abc", depth = "3" })
	assert(formspecs[#formspecs]:find("Malformed entry id", 1, true),
		"gui rejects a malformed #id")
	print("PASS: gui reports bad #ids the same way the CLI does")
end

-- ── /ipdb move: the destination may be an #id, the source may not ─────────
do
	local src = dbmanager.new_entry()
	dbmanager.add_name(src, "mvasrc")
	dbmanager.add_ip(src, "13.0.0.1")
	local dst = dbmanager.new_entry()
	dbmanager.add_name(dst, "mvdst")
	dbmanager.add_ip(dst, "13.0.0.2")

	expect("move", false, "Usage")
	-- An entry id names an entry, not one of its identifiers, so it cannot
	-- say what would move - only the destination side can take one.
	expect("move #"..src.." mvdst", true, "not an entry id")
	assert(dbmanager.user_exists("mvasrc").userentry_id == src, "a refused move changes nothing")

	expect("move mvasrc mvdst", true, "Move successful")
	assert(dbmanager.user_exists("mvasrc").userentry_id == dst, "the name moved to the destination entry")
	assert(dbmanager.get_userentry(src) ~= nil, "source entry survives while an identifier is still on it")

	expect("move 13.0.0.1 #"..dst, true, "Move successful")
	assert(dbmanager.ip_exists("13.0.0.1").userentry_id == dst, "the IP moved to the entry named as #id")
	assert(dbmanager.get_userentry(src) == nil, "the emptied source entry was removed by the cleanup triggers")

	expect("move mvasrc #999", true, "does not exist")
	expect("move nosuchname mvdst", true, "unknown to ipdb")
	expect("move 13.0.0.1 #notanumber", true, "Malformed entry id")
end

-- ── isolate / unisolate: the no_merging flag ──────────────────────────────
do
	expect("isolate iso", true, "Isolated entry created")
	local iso = dbmanager.user_exists("iso")
	assert(iso and dbmanager.get_userentry(iso.userentry_id).no_merging, "isolate sets no_merging")

	-- the type is inferred from the identifier, as in list/move/tree
	expect("isolate 10.9.9.7", true, "Isolated entry created")
	local newip = dbmanager.ip_exists("10.9.9.7")
	assert(newip and dbmanager.get_userentry(newip.userentry_id).no_merging, "an IP alone creates an isolated entry")
	-- a mistyped address is neither a name nor an address
	expect("isolate 10.9.9", false, "Invalid IP address format")
	expect("isolate 10.9.9.7.8", false, "Invalid IP address format")
	-- ...but nothing rejects a plain name
	expect("isolate 10", true, "Isolated entry created")

	-- an isolated entry is what register_new_ids refuses to absorb
	assert(not dbmanager.can_merge(iso.userentry_id, zoe), "an isolated entry cannot be merged")

	expect("unisolate iso", true, "is no longer isolated")
	assert(not dbmanager.get_userentry(iso.userentry_id).no_merging, "unisolate clears no_merging")
	assert(dbmanager.can_merge(iso.userentry_id, zoe), "the entry can be merged again")

	expect("unisolate iso", true, "is not isolated")
	expect("unisolate 12.0.0.1", true, "is not isolated")
	expect("unisolate #999", true, "does not exist")
	expect("unisolate nosuchname", true, "unknown to ipdb")
	expect("unisolate", false, "Usage")

	-- unisolate takes an #id too, and is the only way to clear a flag
	-- on an entry that sits on an identifier you would rather not name
	expect("isolate 12.0.0.1", true, "Isolated entry created")
	local isoip = dbmanager.ip_exists("12.0.0.1")
	expect("unisolate #"..isoip.userentry_id, true, "is no longer isolated")
	assert(not dbmanager.get_userentry(isoip.userentry_id).no_merging, "unisolate by #id clears no_merging")
end

-- ── a mistyped address is reported as one, not as an unknown name ─────────
do
	local function entry_count()
		local n = 0
		for _ in db:nrows("SELECT id FROM UserEntry") do n = n + 1 end
		return n
	end
	local before = entry_count()

	-- These shapes can never be a playername: a dot or a colon is an address.
	-- Commands that only look things up report it like any other miss (ok, as
	-- they already did for an unknown name); isolate creates a row, so a bad
	-- argument there is a command failure like it is for add_ip/rm_ip.
	expect("tree 1.2.3", true, "Invalid IP address format")
	expect("list 1.2.3", true, "Invalid IP address format")
	expect("unisolate 1.2.3", true, "Invalid IP address format")
	expect("move 1.2.3 mvdst", true, "Invalid IP address format")
	expect("isolate 1.2.3", false, "Invalid IP address format")
	assert(entry_count() == before, "a rejected isolate leaves no empty entry behind")

	-- add_ip/rm_ip name themselves and say what is actually wrong
	expect("add_ip 1.2.3", false, "Invalid IP address format")
	expect("add_ip", false, "Usage: /ipdb add_ip")
	expect("rm_ip 1.2.3", false, "Invalid IP address format")
	expect("rm_ip", false, "Usage: /ipdb rm_ip")

	-- ...but a name of that shape that really is in the database still wins
	local dotted = dbmanager.new_entry()
	dbmanager.add_name(dotted, "dotted.name")
	expect("tree dotted.name", true, "current")
	expect("isolate dotted.name", true, "Isolated entry created")
	assert(dbmanager.user_exists("dotted.name").userentry_id ~= dotted, "isolate moved the dotted name")
	assert(dbmanager.get_userentry(dotted) == nil, "the entry it left behind was cleaned up")

	-- list resolves like everything else now, so it takes an #id too
	local dstentry = dbmanager.user_exists("mvdst").userentry_id
	chat_output = nil
	expect("list #"..dstentry, true)
	assert(chat_output and chat_output:find("mvdst", 1, true), "list accepts an #id")
	assert(chat_output:find("mvasrc", 1, true), "list #id dumps the whole entry, not just one identifier")
end

-- ── Enter in a text field shows the tree; it does not close the window ───
do
	-- a client with the default close-on-enter sends quit along with the
	-- key_enter that names the focused field
	cmd.func("tester", "merge_gui")
	local n = #formspecs
	gui({ key_enter = "true", key_enter_field = "root", quit = "true", root = "trunc", depth = "2" })
	assert(#formspecs > n, "Enter in the entry field is handled, not treated as a close")
	assert(formspecs[#formspecs]:find("node_"), "Enter shows the tree, like the Show tree button")
	print("PASS: Enter in a text field shows the tree")

	-- the same for the depth field
	local n2 = #formspecs
	gui({ key_enter = "true", key_enter_field = "depth", quit = "true", root = "trunc", depth = "2" })
	assert(#formspecs > n2 and formspecs[#formspecs]:find("node_"), "Enter in the depth field shows the tree")
	print("PASS: Enter in the depth field shows the tree")

	-- with the focus nowhere or on a button, Enter really does close it
	cmd.func("tester", "merge_gui")
	local n3 = #formspecs
	gui({ key_enter = "true", quit = "true" })
	assert(#formspecs == n3, "Enter with no field focused closes the window")
	print("PASS: Enter with no field focused still closes")

	-- and so do Escape / the window button, and the Close button itself
	cmd.func("tester", "merge_gui")
	local n4 = #formspecs
	gui({ quit = "true" })
	assert(#formspecs == n4, "escape closes the window")
	cmd.func("tester", "merge_gui")
	local n5 = #formspecs
	gui({ close = "true" })
	assert(#formspecs == n5, "the Close button closes the window")
	print("PASS: escape and the Close button still close the window")
end

-- the depth cap is 20 in the CLI too, not just in the message
do
	expect("tree alice 20", true, "current")
	expect("tree alice 21", false, "between 1 and 20")
end

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
