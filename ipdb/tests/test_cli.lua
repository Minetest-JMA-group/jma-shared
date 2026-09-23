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
local closed_form  -- formname the GUI asked the client to close, if any
local leave_handler  -- called when a player disconnects

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
	register_on_leaveplayer = function(handler) leave_handler = handler end,
	after = function() end,
	chat_send_player = function(_, msg) chat_output = msg end,
	-- the same character set the engine escapes (builtin/common/misc_helpers.lua);
	-- getting this wrong hides real bugs, e.g. an escaped comma in a table[]
	-- collapses every cell into one column
	formspec_escape = function(s)
		return (tostring(s):gsub("[\\%[%];,$]", {
			["\\"] = "\\\\", ["["] = "\\[", ["]"] = "\\]",
			[";"] = "\\;", [","] = "\\,", ["$"] = "\\$",
		}))
	end,
	show_formspec = function(name, formname, fs) formspecs[#formspecs + 1] = fs end,
	close_formspec = function(name, formname) closed_form = formname end,
	-- The engine sends "CHG:<row>:<col>" when a table row is picked, and this
	-- returns a table - not several values - so the stand-in must too, or code
	-- written against it will not work in the game.
	explode_table_event = function(evt)
		if evt ~= nil then
			local parts = {}
			for part in tostring(evt):gmatch("[^:]+") do
				parts[#parts + 1] = part
			end
			if #parts == 3 then
				local t, r, c = parts[1], tonumber(parts[2]), tonumber(parts[3])
				if r and c and t ~= "INV" then
					return { type = t, row = r, column = c }
				end
			end
		end
		return { type = "INV", row = 0, column = 0 }
	end,
	-- Stand-ins for the engine's JSON and serialization functions, which are
	-- C++ there. These check the plumbing - which text reaches them, whether
	-- the styled form was asked for, what is shown when they refuse - and echo
	-- their input so a test can tell what was passed.
	parse_json = function(s, nullvalue, return_error)
		s = tostring(s)
		if s:sub(1, 1) ~= "{" and s:sub(1, 1) ~= "[" then
			return nil, "invalid json near '"..s:sub(1, 8).."'"
		end
		return { __source = s }
	end,
	write_json = function(v, styled)
		if type(v) ~= "table" then
			return nil, "cannot write a "..type(v)
		end
		-- JSON takes only string and positive integer keys
		for k in pairs(v) do
			if type(k) ~= "string" and not (type(k) == "number" and k >= 1 and k == math.floor(k)) then
				return nil, "cannot write a table with a "..type(k).." key"
			end
		end
		return (styled and "PRETTY of " or "COMPACT of ")..tostring(v.__source or "the table")
	end,
	deserialize = function(s, safe)
		s = tostring(s)
		local loader = loadstring or load
		local fn = loader(s)
		if not fn then error("cannot load '"..s:sub(1, 8).."'") end
		local v = fn()
		if type(v) ~= "table" then error("does not evaluate to a table") end
		v.__source = s   -- so a test can see what was handed over
		return v
	end,
	serialize = function(v) return "return "..tostring(v) end,
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
	-- mirrors algorithms.time_to_string (algorithms/init.lua), which
	-- /ipdb log_retention now renders the retention with
	time_to_string = function(sec)
		if type(sec) ~= "number" then return "" end
		sec = math.floor(sec)
		local min = math.floor(sec / 60); sec = sec % 60
		local hour = math.floor(min / 60); min = min % 60
		local day = math.floor(hour / 24); hour = hour % 24
		local month = math.floor(day / 30); day = day % 30
		local year = math.floor(month / 12); month = month % 12
		local function plural(n, word) return n == 1 and word or (word .. "s") end
		if year > 0 then return "more than a year" end
		if month > 0 then return tostring(month).." "..plural(month, "month") end
		if day > 0 then return tostring(day).." "..plural(day, "day") end
		if hour > 0 then return tostring(hour).." "..plural(hour, "hour") end
		if min > 0 then return tostring(min).." "..plural(min, "minute") end
		return tostring(sec).." "..plural(sec, "second")
	end,
}
_G.algorithms = algorithms

-- the engine ships a global dump() for rendering a value readably; the value
-- screen falls back to it when the data will not go into JSON
_G.dump = function(v) return "DUMPED "..tostring(v.__source or v) end


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
expect("log_retention", true, "kept for 15 days")
expect("log_retention 2D", true, "2D (172800 seconds)")
expect("log_retention", true, "kept for 2 days")
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

	-- and so do Escape / the window button, and the Close button itself.
	-- Dropping the mod's state is not enough: the client has to be told, or
	-- the window stays on screen and the button looks dead.
	cmd.func("tester", "merge_gui")
	local n4 = #formspecs
	closed_form = nil
	gui({ quit = "true" })
	assert(#formspecs == n4, "escape shows no new screen")
	assert(closed_form == "ipdb:merge_gui", "escape asks the client to close the formspec")
	cmd.func("tester", "merge_gui")
	local n5 = #formspecs
	closed_form = nil
	gui({ close = "true" })
	assert(#formspecs == n5, "the Close button shows no new screen")
	assert(closed_form == "ipdb:merge_gui", "the Close button asks the client to close the formspec")
	print("PASS: escape and the Close button close the window")
end

-- ── the GUI must not hand the engine text that does not fit ───────────────
-- The engine clips a button label wider than its button and runs a label[]
-- past the right edge with nothing to mark the loss, so every string the GUI
-- emits has to fit. These mirror mergegui's own measure of the form font.
do
	local CHAR_W, TEXT_W = 0.15, 11.4
	local BUDGET = math.floor(TEXT_W / CHAR_W)

	-- the client renders an escape like "\," as a single comma, so what has
	-- to fit is the unescaped text
	local function unesc(s)
		return (s:gsub("\\(.)", "%1"))
	end

	local function labels(fs)
		local out = {}
		for w, h, text in fs:gmatch("button%[[%d%.]+,[%d%.]+;([%d%.]+),([%d%.]+);node_%d+_%d+;([^%]]*)%]") do
			table.insert(out, { w = tonumber(w), h = tonumber(h), text = unesc(text) })
		end
		return out
	end

	local function longest_label(fs)
		local max, worst = 0, ""
		for text in fs:gmatch("label%[[%d%.]+,[%d%.]+;([^%]]*)%]") do
			text = unesc(text)
			if #text > max then max, worst = #text, text end
		end
		return max, worst
	end

	-- two names and a pile of addresses, as in the report that found this
	local wide = dbmanager.new_entry()
	dbmanager.add_name(wide, "novaosoba")
	dbmanager.add_name(wide, "mpplayer")
	for i, ip in ipairs({ "89.142.200.97", "109.245.36.102", "89.142.163.253",
	                      "46.122.68.13", "212.200.181.53", "81.10.11.12" }) do
		dbmanager.add_ip(wide, ip)
	end

	-- Space the timestamps out before the tree is built - the tree caches each
	-- node's identifier rows as it is built, so ordering assertions below
	-- would otherwise see the same second for every row
	for i, ip in ipairs({ "89.142.200.97", "109.245.36.102", "89.142.163.253",
	                      "46.122.68.13", "212.200.181.53", "81.10.11.12" }) do
		db:exec(string.format("UPDATE IPs SET created_at = '2025-03-%02d 00:00:00', " ..
			"last_seen = '2026-07-%02d 00:00:00' WHERE ip = '%s'", i, i, ip))
	end
	db:exec("UPDATE Usernames SET created_at = '2025-01-01 00:00:00', last_seen = '2026-09-01 00:00:00' WHERE name = 'novaosoba'")
	db:exec("UPDATE Usernames SET created_at = '2025-02-01 00:00:00', last_seen = '2026-08-01 00:00:00' WHERE name = 'mpplayer'")

	cmd.func("tester", "merge_gui")
	gui({ go = true, root = "#"..wide, depth = "2" })
	local tfs = formspecs[#formspecs]

	local buttons = labels(tfs)
	assert(#buttons > 0, "the tree drew a node button")
	for _, b in ipairs(buttons) do
		local needed = #b.text * CHAR_W + 0.3
		assert(needed <= b.w + 0.001, string.format(
			"node label '%s' needs %.2f but the button is %.2f wide", b.text, needed, b.w))
	end
	print("PASS: node labels fit their buttons")

	local eid = tfs:match("node_(%d+)_0")
	assert(eid == tostring(wide), "the node carries the entry id")
	gui({ ["node_" .. eid .. "_0"] = true })
	local dfs = formspecs[#formspecs]
	assert(dfs:find("Entry #"..wide), "the detail screen is shown")
	assert(dfs:find("Last seen ▼", 1, true), "the default sort is last seen, newest first")

	-- the identifiers are one table, and its cells must be separated by raw
	-- commas - formspec_escape turns a comma into "\," (one literal comma
	-- inside a cell), so escaping the joined string would collapse the table
	-- into a single column
	local cells = select(4, dfs:match("table%[([^;]*);([^;]*);([^;]*);([^;]*);"))
	assert(cells, "the detail screen carries table cell data")
	assert(not cells:find("\\,", 1, true), "cell separators must not be escaped")
	local function split(s)
		local out = {}
		for piece in (s .. ","):gmatch("(.-),") do out[#out + 1] = piece end
		return out
	end
	local c = split(cells)
	-- 4 header cells + (2 names + 6 ips) * 4
	assert(#c == 4 + 8 * 4, "expected 4 header cells plus 8 rows of 4, got " .. #c)
	-- the row after the header is the most recently seen identifier
	assert(c[6] == "novaosoba", "newest last_seen leads by default, got " .. tostring(c[6]))
	assert(c[5] == "name" and c[7] == "2025-01-01 00:00:00" and c[8] == "2026-09-01 00:00:00",
		"a row carries kind, value, created and last seen")
	print("PASS: the detail list is a table, newest first by default")

	-- same key again flips the direction; a different key switches the column
	gui({ sort_seen = true })
	local asc = select(4, formspecs[#formspecs]:match("table%[([^;]*);([^;]*);([^;]*);([^;]*);"))
	assert(formspecs[#formspecs]:find("Last seen ▲", 1, true), "pressing the active key flips the arrow")
	assert(split(asc)[6] == "89.142.200.97", "oldest last_seen leads once ascending, got " .. tostring(split(asc)[6]))
	gui({ sort_created = true })
	local oldest = select(4, formspecs[#formspecs]:match("table%[([^;]*);([^;]*);([^;]*);([^;]*);"))
	assert(formspecs[#formspecs]:find("Created ▲", 1, true), "switching key keeps the direction")
	assert(split(oldest)[6] == "novaosoba", "oldest created_at leads, got " .. tostring(split(oldest)[6]))
	gui({ sort_created = true })
	local newestfirst = select(4, formspecs[#formspecs]:match("table%[([^;]*);([^;]*);([^;]*);([^;]*);"))
	assert(split(newestfirst)[6] == "81.10.11.12", "newest created_at leads once flipped, got " .. tostring(split(newestfirst)[6]))
	print("PASS: the sort buttons reorder and flip direction")

	-- the labels that remain around the table must still fit the window
	local max, worst = longest_label(dfs)
	assert(max <= BUDGET, string.format("detail line is %d chars, budget is %d: %s", max, BUDGET, worst))
end

-- ── /ipdb list: sorted, one identifier per row, both timestamps ──────────
do
	local le = dbmanager.new_entry()
	dbmanager.add_name(le, "listold")
	dbmanager.add_name(le, "listnew")
	dbmanager.add_ip(le, "172.16.0.1")
	dbmanager.add_ip(le, "172.16.0.2")
	db:exec("UPDATE Usernames SET created_at='2024-01-01 00:00:00', last_seen='2024-06-01 00:00:00' WHERE name='listold'")
	db:exec("UPDATE Usernames SET created_at='2025-01-01 00:00:00', last_seen='2026-06-01 00:00:00' WHERE name='listnew'")
	db:exec("UPDATE IPs SET created_at='2024-03-01 00:00:00', last_seen='2025-06-01 00:00:00' WHERE ip='172.16.0.1'")
	db:exec("UPDATE IPs SET created_at='2024-02-01 00:00:00', last_seen='2026-01-01 00:00:00' WHERE ip='172.16.0.2'")

	-- list prints through chat_send_player rather than returning its rows
	local function lines_of(s)
		local t = {}
		for l in (s .. "\n"):gmatch("(.-)\n") do t[#t + 1] = l end
		return t
	end
	local function listed(params)
		chat_output = nil
		local ok, ret = cmd.func("tester", params)
		if not ok or ret then return ok, ret end
		return true, chat_output
	end
	-- the summary line is first, the column headers second, so the first
	-- identifier sits on the third line
	local function first_row(params)
		local ok, out = listed(params)
		assert(ok and out, params .. " produced no output")
		local l = lines_of(out)
		assert(l[3], params .. " produced no data row")
		return l[3], out
	end

	local row, out = first_row("list #"..le)
	assert(row:find("listnew", 1, true), "newest last_seen leads by default, got: " .. row)
	assert(out:find("2026-06-01 00:00:00", 1, true), "the row carries last_seen")
	assert(out:find("2025-01-01 00:00:00", 1, true), "the row carries created_at")
	assert(out:find("kind", 1, true) and out:find("last seen", 1, true), "the output has headers")
	print("PASS: list is sorted by last seen, newest first, with both timestamps")

	assert(select(1, first_row("list #"..le.." seen asc")):find("listold", 1, true),
		"oldest last_seen leads when ascending")
	assert(select(1, first_row("list #"..le.." asc")):find("listold", 1, true),
		"a direction on its own keeps the default key")
	assert(select(1, first_row("list #"..le.." created desc")):find("listnew", 1, true),
		"newest created_at leads")
	assert(select(1, first_row("list #"..le.." created asc")):find("listold", 1, true),
		"oldest created_at leads")
	assert(select(1, first_row("list #"..le.." value asc")):find("172.16.0.1", 1, true),
		"value sorts by the name or address itself")
	print("PASS: list takes a sort key and a direction")

	expect("list #"..le.." nonsense", false, "Sort by 'created', 'seen' or 'value'")
	expect("list #"..le.." seen sideways", false, "Direction must be 'asc' or 'desc'")
	expect("list", false, "Usage: /ipdb list")

	-- an entry far past the display cap still prints a bounded number of rows
	local big = dbmanager.new_entry()
	dbmanager.add_name(big, "bigentry")
	for i = 1, 210 do
		dbmanager.add_ip(big, string.format("10.%d.%d.%d", math.floor(i / 256) % 256, i % 256, (i * 7) % 256))
	end
	local ok_big, out_big = listed("list #"..big)
	assert(ok_big and out_big, "list produced no output for a large entry")
	assert(out_big:find("211 identifier(s)", 1, true), "the count reports every identifier, not just the shown ones")
	assert(out_big:find("and 11 more", 1, true), "the overflow is reported")
	-- summary + header + 200 rows + the overflow note
	local nlines = #lines_of(out_big)
	assert(nlines == 203, "expected 203 lines for a capped listing, got " .. nlines)
	print("PASS: list caps what it prints and says how much it left out")
end

-- ── a message must not be drawn over the input row ───────────────────────
-- The Show tree and Close buttons start at x=6.8 and span y 0.3-1.2, and a
-- label[] is painted wherever it is put, text and all. Anything on that band
-- runs across them.
do
	local function y_values(fs)
		local ys = {}
		for y in fs:gmatch("label%[[%d%.]+,([%d%.]+);") do
			ys[#ys + 1] = tonumber(y)
		end
		return ys
	end
	local function assert_clear(fs, ctx)
		for _, y in ipairs(y_values(fs)) do
			assert(y >= 1.25, string.format("%s: a label sits at y=%.2f, inside the input row", ctx, y))
		end
	end

	cmd.func("tester", "merge_gui")
	gui({ go = true, root = "no-such-entry", depth = "3" })
	local efs = formspecs[#formspecs]
	assert(efs:find("unknown to ipdb", 1, true), "the error is shown at all")
	assert_clear(efs, "error on the empty screen")
	print("PASS: an error is not drawn across the buttons")

	-- and with a tree already loaded, where the message shares the screen
	-- with the canvas
	gui({ go = true, root = "trunc", depth = "2" })
	assert(formspecs[#formspecs]:find("node_"), "the tree rendered")
	gui({ go = true, root = "no-such-entry", depth = "3" })
	local efs2 = formspecs[#formspecs]
	assert(efs2:find("unknown to ipdb", 1, true), "the error is shown over a loaded tree")
	assert_clear(efs2, "error over a loaded tree")
	print("PASS: an error still clears the buttons with a tree loaded")

	-- the empty-state hint shares that line and must be clear of it too
	cmd.func("tester", "merge_gui")
	local hfs = formspecs[#formspecs]
	assert(hfs:find("Enter a name", 1, true), "the hint is shown")
	assert_clear(hfs, "empty-state hint")
end

-- ── every label stays inside the window and off its neighbours ───────────
-- A label[] is painted wherever it is put: text reaching an element to its
-- right is drawn over it, and text past the right edge is simply gone. These
-- mirror mergegui's own measure of the form font.
do
	local CHAR_W, TEXT_W = 0.15, 11.4
	local BUDGET = math.floor(TEXT_W / CHAR_W)
	local function unesc(s) return (s:gsub("\\(.)", "%1")) end

	-- a merge whose post-merge identifiers have awkwardly long values, and a
	-- separate merge with nothing left to roll back to
	local dec_src = dbmanager.new_entry()
	dbmanager.add_name(dec_src, "dectest-src")
	dbmanager.add_ip(dec_src, "192.0.2.31")
	local dec_dst = dbmanager.new_entry()
	dbmanager.add_name(dec_dst, "dectest-dst")
	dbmanager.add_ip(dec_dst, "192.0.2.32")
	dbmanager.new_merge_event(dec_src, dec_dst, "dectest-dst", "192.0.2.32")
	local dec_mid = dbmanager.get_merge_events(1)[1].id
	dbmanager.reassociate_ids(dec_dst, dbmanager.user_exists("dectest-src").id,
		dbmanager.ip_exists("192.0.2.31").id)
	dbmanager.delete_entry(dec_src)
	-- created after the merge, so they become the decisions to be made: a
	-- 20 character name is the longest a playername can be, and the IP is
	-- longer than a name would be
	dbmanager.add_name(dec_dst, "abcdefghijklmnopqrst")
	dbmanager.add_ip(dec_dst, "203.0.113.255")
	db:exec("UPDATE Usernames SET created_at = datetime('now', '+1 minute') WHERE name = 'abcdefghijklmnopqrst'")
	db:exec("UPDATE IPs SET created_at = datetime('now', '+1 minute') WHERE ip = '203.0.113.255'")

	cmd.func("tester", "merge_gui")
	gui({ go = true, root = "#"..dec_dst, depth = "2" })
	local tfs = formspecs[#formspecs]
	local node = tfs:match("node_(%d+)_"..dec_mid)
	assert(node, "the merge is in the tree")
	gui({ ["node_"..node.."_"..dec_mid] = true })
	local dfs = formspecs[#formspecs]
	assert(dfs:find("Identifiers created after the merge", 1, true), "the decision list is shown")

	-- the right edge of each row's label, and the left edge of its buttons
	local label_right = {}
	for x, y, text in dfs:gmatch("label%[([%d%.]+),([%d%.]+);([^%]]*)%]") do
		label_right[tonumber(y)] = tonumber(x) + #unesc(text) * CHAR_W
	end
	local checked = 0
	for x, y, name in dfs:gmatch("button%[([%d%.]+),([%d%.]+);[%d%.]+,[%d%.]+;(ad_%d+_%w+);") do
		local right = label_right[tonumber(y)]
		if right then
			assert(right <= tonumber(x) + 0.001, string.format(
				"%s: the row label reaches %.2f but its button starts at %.2f", name, right, tonumber(x)))
			checked = checked + 1
		end
	end
	assert(checked >= 6, "expected a decision row per addition, saw " .. checked)
	print("PASS: decision rows stop before their buttons")

	-- the actions can be explained on demand, naming the entry each one acts on
	assert(dfs:find("what do these do%?", 1), "the help button is offered")
	assert(not dfs:find("stays on entry #", 1, true), "the explanation starts hidden")
	gui({ help = true })
	local hfs = formspecs[#formspecs]
	assert(hfs:find("stays on entry #"..dec_dst, 1, true), "keep explains where it stays")
	assert(hfs:find("removed from the database", 1, true), "delete is explained")
	assert(hfs:find("moves to entry #"..dec_src, 1, true), "move names the entry recreated")
	assert(hfs:find("Identifiers created after the merge:", 1, true), "the decision list is still there")
	gui({ help = true })
	assert(not formspecs[#formspecs]:find("stays on entry #", 1, true), "pressing it again hides the explanation")
	print("PASS: the rollback actions can be explained on demand")

	-- nothing anywhere on the screen runs past the right edge either
	for x, label in dfs:gmatch("label%[([%d%.]+),[%d%.]+;([^%]]*)%]") do
		local right = tonumber(x) + #unesc(label) * CHAR_W
		assert(right <= 11.85, string.format("a label reaches %.2f, past the window: %s", right, unesc(label)))
	end
	print("PASS: no label runs past the right edge")

	-- a refusal is a whole sentence; it must survive onto the screen
	local vsrc = dbmanager.new_entry()
	dbmanager.add_name(vsrc, "vanish-src")
	dbmanager.add_ip(vsrc, "192.0.2.41")
	local vdst = dbmanager.new_entry()
	dbmanager.add_name(vdst, "vanish-dst")
	dbmanager.add_ip(vdst, "192.0.2.42")
	dbmanager.new_merge_event(vsrc, vdst, "vanish-dst", "192.0.2.42")
	local vmid = dbmanager.get_merge_events(1)[1].id
	-- drop what the merge logged, so its rollback has nothing to restore
	dbmanager.remove_name(dbmanager.user_exists("vanish-src").id)
	dbmanager.remove_ip(dbmanager.ip_exists("192.0.2.41").id)
	local info, reason = dbmanager.get_merge_rollback_info(vmid)
	assert(info == nil and reason, "the fixture refuses a rollback")
	assert(#reason > BUDGET, "the fixture's refusal is longer than one line: " .. #reason)

	cmd.func("tester", "merge_gui")
	gui({ go = true, root = "#"..vdst, depth = "2" })
	local vfs = formspecs[#formspecs]
	local vnode = vfs:match("node_(%d+)_"..vmid)
	assert(vnode, "the merge is in the tree")
	gui({ ["node_"..vnode.."_"..vmid] = true })
	local rfs = formspecs[#formspecs]
	local shown = {}
	for label in rfs:gmatch("label%[[%d%.]+,[%d%.]+;([^%]]*)%]") do
		local text = unesc(label)
		-- every line has to fit: one long label would be cut off in the
		-- window, however complete the string looks here
		assert(#text <= BUDGET, string.format("a line is %d chars, the budget is %d: %s", #text, BUDGET, text))
		shown[#shown + 1] = text
	end
	local joined = table.concat(shown, " ")
	for word in reason:gmatch("%S+") do
		assert(joined:find(word, 1, true), "the refusal lost the word '"..word.."'")
	end
	print("PASS: a long refusal wraps instead of being cut off")
end

-- ── merge history survives an entry being absorbed later ─────────────────
do
	-- chain-inner is absorbed by chain-mid, which is then absorbed by
	-- chain-outer: the middle entry no longer exists, so its own past has to
	-- come from the log of the merge that absorbed it
	local ch_d = dbmanager.new_entry()
	dbmanager.add_name(ch_d, "chain-inner")
	dbmanager.add_ip(ch_d, "198.51.100.61")
	local ch_e = dbmanager.new_entry()
	dbmanager.add_name(ch_e, "chain-mid")
	dbmanager.add_ip(ch_e, "198.51.100.62")
	dbmanager.new_merge_event(ch_d, ch_e, "chain-mid", "198.51.100.62")
	dbmanager.reassociate_ids(ch_e, dbmanager.user_exists("chain-inner").id, dbmanager.ip_exists("198.51.100.61").id)
	dbmanager.delete_entry(ch_d)
	local ch_f = dbmanager.new_entry()
	dbmanager.add_name(ch_f, "chain-outer")
	dbmanager.add_ip(ch_f, "198.51.100.63")
	dbmanager.new_merge_event(ch_e, ch_f, "chain-outer", "198.51.100.63")
	dbmanager.reassociate_ids(ch_f, dbmanager.user_exists("chain-mid").id, dbmanager.ip_exists("198.51.100.62").id)
	dbmanager.reassociate_ids(ch_f, dbmanager.user_exists("chain-inner").id, dbmanager.ip_exists("198.51.100.61").id)
	dbmanager.delete_entry(ch_e)

	local root = dbmanager.get_merge_tree(ch_f, 4)
	local mid = root.children[1]
	assert(mid.entry_id == ch_e and mid.kind == "src", "the absorbed entry is the src child")
	assert(#mid.names == 2, "it is shown holding both identifiers, got " .. #mid.names)
	local past = mid.children[2]
	assert(past.entry_id == ch_e and past.kind == "cont", "its earlier state is the cont child")
	assert(#past.names == 1 and past.names[1] == "chain-mid",
		"its own past is reconstructed without what arrived later, got: " .. table.concat(past.names, ","))
	assert(#past.ips == 1 and past.ips[1] == "198.51.100.62", "and likewise for its addresses")
	print("PASS: an absorbed entry's own past is still shown")

	-- and the screen that showed nothing now lists it
	cmd.func("tester", "merge_gui")
	gui({ go = true, root = "#"..ch_f, depth = "4" })
	local chfs = formspecs[#formspecs]
	local e_node = chfs:match("node_"..ch_e.."_(%d+)")
	assert(e_node, "the middle entry is in the tree")
	gui({ ["node_"..ch_e.."_"..e_node] = true })
	assert(formspecs[#formspecs]:find("chain%-mid"), "the entry's identifiers are listed on its node")
	print("PASS: the GUI lists them too")
end

-- ── a player who disconnects leaves no GUI state behind ──────────────────
do
	cmd.func("tester", "merge_gui")
	local before = #formspecs
	gui({ go = true, root = "trunc", depth = "2" })
	assert(#formspecs > before, "the screen answers while the player is here")
	assert(leave_handler, "a disconnect handler is registered")

	leave_handler({ get_player_name = function() return "tester" end })
	local after = #formspecs
	gui({ go = true, root = "trunc", depth = "2" })
	assert(#formspecs == after, "and stops answering once they have gone")

	-- the same player coming back gets a working screen again
	cmd.func("tester", "merge_gui")
	local back = #formspecs
	gui({ go = true, root = "trunc", depth = "2" })
	assert(#formspecs > back, "reopening after the disconnect works")
	print("PASS: a disconnect drops that player's GUI state")
end

-- ── unmerge forget actually deletes ──────────────────────────────────────
do
	local fsrc = dbmanager.new_entry()
	dbmanager.add_name(fsrc, "forget-src")
	dbmanager.add_ip(fsrc, "198.51.100.71")
	local fdst = dbmanager.new_entry()
	dbmanager.add_name(fdst, "forget-dst")
	dbmanager.add_ip(fdst, "198.51.100.72")
	dbmanager.new_merge_event(fsrc, fdst, "forget-dst", "198.51.100.72")
	local fmid = dbmanager.get_merge_events(1)[1].id
	dbmanager.reassociate_ids(fdst, dbmanager.user_exists("forget-src").id, dbmanager.ip_exists("198.51.100.71").id)
	dbmanager.delete_entry(fsrc)
	-- created after the merge, so it is what the decision is about
	dbmanager.add_name(fdst, "forget-later")
	db:exec("UPDATE Usernames SET created_at = datetime('now','+1 minute') WHERE name = 'forget-later'")

	-- undecided, it refuses and says what the choices are
	expect("unmerge "..fmid, false, "were created after this merge")
	assert(dbmanager.user_exists("forget-later"), "nothing happens while it is undecided")

	expect("unmerge "..fmid.." forget", true, "rolled back")
	assert(dbmanager.user_exists("forget-later") == nil, "forget deletes the post-merge identifier")
	local _, ev = pcall(dbmanager.get_merge_event, fmid)
	assert(ev and ev.reverted_at, "the merge is marked reverted")
	print("PASS: unmerge forget drops the post-merge identifiers")
end

-- ── the storage viewer ────────────────────────────────────────────────────
do
	-- 1 is absorbed by 2, then 2 by 3, and 2's storage changes in between: the
	-- two nodes for entry 2 must show the two different states, each read from
	-- the merge log that recorded it
	local long_value = "first-part " .. string.rep("pad ", 20) .. "final-tail"
	local s1 = dbmanager.new_entry()
	dbmanager.add_name(s1, "store-1")
	dbmanager.insert_into_modstorage(s1, "demomod", "k", "one-in-1")
	local s2 = dbmanager.new_entry()
	dbmanager.add_name(s2, "store-2")
	dbmanager.insert_into_modstorage(s2, "demomod", "k", "two-before-m1")
	dbmanager.insert_into_modstorage(s2, "othermod", "x", "two-x")
	dbmanager.insert_into_modstorage(s2, "longmod", "blob", long_value)
	-- one minified blob with nothing to break on, and one serialized value
	local minified = '{"is_banned":false,"privs":["interact","shout"],' ..
		'"homes":{"home":{"x":123.45,"y":42,"z":-987.65}},"n":123456789}'
	dbmanager.insert_into_modstorage(s2, "jsonmod", "blob", minified)
	dbmanager.insert_into_modstorage(s2, "sermod", "t", "return { foo = 'bar' }")
	-- deserializes fine, but JSON cannot hold a boolean key
	dbmanager.insert_into_modstorage(s2, "unjsonmod", "t", "return { [true] = 'x' }")
	local s3 = dbmanager.new_entry()
	dbmanager.add_name(s3, "store-3")
	dbmanager.insert_into_modstorage(s3, "demomod", "k", "three-own")

	dbmanager.new_merge_event(s1, s2, "store-2", "")
	local m1 = dbmanager.get_merge_events(1)[1].id
	dbmanager.reassociate_ids(s2, dbmanager.user_exists("store-1").id)
	dbmanager.delete_entry(s1)
	dbmanager.update_modstorage2(s2, "demomod", "k", "two-before-m2")

	dbmanager.new_merge_event(s2, s3, "store-3", "")
	local m2 = dbmanager.get_merge_events(1)[1].id
	dbmanager.reassociate_ids(s3, dbmanager.user_exists("store-2").id)
	dbmanager.delete_entry(s2)

	cmd.func("tester", "merge_gui")
	gui({ go = true, root = "#"..s3, depth = "4" })
	local stfs = formspecs[#formspecs]
	assert(stfs:find("node_"..s2.."_"..m2..";", 1, true), "the absorbed entry's node carries the later merge")
	gui({ ["node_"..s2.."_"..m2] = true })
	assert(formspecs[#formspecs]:find(";storage;", 1, true), "the detail screen offers the storage viewer")

	-- entry 2 as it was when merge m2 absorbed it
	gui({ storage = true })
	local v2 = formspecs[#formspecs]
	assert(v2:find("Storage of entry #"..s2, 1, true), "the screen names the entry")
	assert(v2:find("as of merge #"..m2, 1, true), "and which merge it is as of")
	assert(v2:find("two-before-m2", 1, true), "the state at that merge is shown")
	assert(not v2:find("two-before-m1", 1, true), "and not the earlier one")
	assert(v2:find("demomod", 1, true) and v2:find("othermod", 1, true), "every mod is offered")
	-- a long value is shortened in its cell
	assert(not v2:find("final-tail", 1, true), "the cell does not carry the whole value")

	-- picking a row shows it under the table
	gui({ ms = "CHG:4:1" })
	assert(formspecs[#formspecs]:find("mod longmod", 1, true), "the long-value row is picked")
	assert(formspecs[#formspecs]:find("final-tail", 1, true), "picking the row shows the whole value")

	-- The value screen. A minified blob is one enormous token with nothing to
	-- break on, so wrapping by word alone would shorten it away: the whole of
	-- it has to be reachable.
	gui({ ms = "CHG:3:1" })
	assert(formspecs[#formspecs]:find("mod jsonmod", 1, true), "the minified row is picked")
	assert(formspecs[#formspecs]:find(";ms_full;", 1, true), "the picked row offers the whole value")

	-- The button shares the header's row and the value lines start below it,
	-- clear of the button's lower edge.
	local pickfs = formspecs[#formspecs]
	local btn_y = tonumber(pickfs:match("button%[[%d%.]+,([%d%.]+);[%d%.]+,[%d%.]+;ms_full;"))
	assert(btn_y, "the whole-value button has a position")
	local hdr_y, val_y
	for _, y, text in pickfs:gmatch("label%[([%d%.]+),([%d%.]+);([^%]]*)%]") do
		if text:find("^mod ") then
			hdr_y = tonumber(y)
		elseif hdr_y and not val_y and tonumber(y) > hdr_y then
			val_y = tonumber(y)
		end
	end
	assert(hdr_y and val_y, "the panel has a header and a value line")
	assert(math.abs(btn_y - (hdr_y - 0.05)) < 0.001,
		string.format("the button is placed from the header's row (button %.2f, header %.2f)", btn_y, hdr_y))
	assert(val_y - hdr_y >= 0.5, string.format(
		"the value line starts %.2f below the header, so it clears the button", val_y - hdr_y))
	print("PASS: the picked-row panel spaces its button from its text")

	gui({ ms_full = true })
	local vfs = formspecs[#formspecs]
	assert(vfs:find("as stored", 1, true), "the value screen says how it is showing it")
	local items = vfs:match("textlist%[[^;]*;[^;]*;[^;]*;([^;]*);")
	assert(items, "the value screen carries its lines")
	local text = items:gsub("\\,", ",")
	assert(text:find("123456789}", 1, true), "the end of a minified blob is reachable")
	assert(text:find("is_banned", 1, true), "and so is its beginning")

	-- JSON: asked for the styled form, and shown what came back
	gui({ value_json = true })
	local jfs = formspecs[#formspecs]
	assert(jfs:find("reformatted as JSON", 1, true), "the JSON view is named")
	assert(jfs:find("PRETTY of {", 1, true), "the value was parsed and written back prettily")

	-- and a value that is not JSON says so instead
	gui({ value_back = true })
	gui({ ms = "CHG:4:1" })
	gui({ ms_full = true })
	gui({ value_json = true })
	local badfs = formspecs[#formspecs]
	assert(badfs:find("not JSON:", 1, true), "a value that is not JSON says so")
	assert(badfs:find("final-tail", 1, true), "and the stored text is shown instead")

	-- Serialization: reads a serialized value, and refuses anything else
	gui({ value_back = true })
	gui({ ms = "CHG:6:1" })
	assert(formspecs[#formspecs]:find("mod sermod", 1, true), "the serialized row is picked")
	gui({ ms_full = true })
	gui({ value_ser = true })
	assert(formspecs[#formspecs]:find("PRETTY of return {", 1, true), "a serialized value is read")
	gui({ value_back = true })
	gui({ ms = "CHG:3:1" })
	gui({ ms_full = true })
	gui({ value_ser = true })
	assert(formspecs[#formspecs]:find("not a serialized value", 1, true), "JSON is not a serialized value")

	-- Data JSON cannot hold is rendered by the engine's own dump. Falling back
	-- to serialize would write back the very text the value was stored as,
	-- leaving the button looking as though it had done nothing.
	gui({ value_back = true })
	gui({ ms = "CHG:7:1" })
	assert(formspecs[#formspecs]:find("mod unjsonmod", 1, true), "the awkward row is picked")
	gui({ ms_full = true })
	gui({ value_ser = true })
	-- the brackets of the value are escaped in the formspec, so match the
	-- prefix that tells the two renderings apart
	assert(formspecs[#formspecs]:find("DUMPED return {", 1, true),
		"data JSON cannot hold is dumped rather than echoed back")
	assert(not formspecs[#formspecs]:find("PRETTY", 1, true), "and not mistaken for JSON")
	gui({ value_back = true })
	assert(formspecs[#formspecs]:find("Storage of entry #"..s2, 1, true), "back returns to the storage list")
	print("PASS: the value screen converts for reading, and says when it cannot")

	-- the dropdown narrows to one mod
	gui({ ms_mod = "othermod" })
	local f2 = formspecs[#formspecs]
	assert(f2:find("two-x", 1, true), "the chosen mod's row is shown")
	assert(not f2:find("two-before-m2", 1, true), "and the other mods' are not")
	gui({ ms_mod = "all mods" })
	assert(formspecs[#formspecs]:find("two-before-m2", 1, true), "all mods brings them back")

	-- The dropdown's items are separate, and its value rides along with every
	-- submission: picking a row must survive that and must not re-filter.
	local dropscreen = formspecs[#formspecs - 1]
	local drop = dropscreen and dropscreen:match("dropdown%[[^%]]*%]")
	assert(drop, "the mod filter is a dropdown")
	assert(drop:find("all mods,", 1, true),
		"its items are separated by real commas, not escaped ones: "..drop)
	assert(not drop:find("\\,", 1, true), "and no separator is escaped")
	gui({ ms = "CHG:3:1", ms_mod = "all mods" })
	assert(formspecs[#formspecs]:find("mod jsonmod", 1, true),
		"a row pick is honoured even with the dropdown's value along for the ride")
	assert(formspecs[#formspecs]:find(";ms_full;", 1, true), "and still offers the whole value")
	gui({ ms_mod = "all mods" })
	assert(formspecs[#formspecs]:find("mod jsonmod", 1, true), "a repeat of the same filter changes nothing")


	-- and the entry below it holds the earlier state
	gui({ ms_back = true })
	assert(formspecs[#formspecs]:find("Back to tree", 1, true), "back returns to the detail screen")
	assert(stfs:find("node_"..s2.."_"..m1..";", 1, true), "the earlier state of entry 2 is a node of its own")
	gui({ ["node_"..s2.."_"..m1] = true })
	gui({ storage = true })
	local v1 = formspecs[#formspecs]
	assert(v1:find("as of merge #"..m1, 1, true), "the other node is as of the earlier merge")
	assert(v1:find("two-before-m1", 1, true), "and shows the earlier state")
	assert(not v1:find("two-before-m2", 1, true), "not the later one")

	-- A live entry has no merge to read from and no "as of" state, so it reads
	-- the table itself - a different path from the two above.
	cmd.func("tester", "merge_gui")
	gui({ go = true, root = "#"..s3, depth = "2" })
	assert(formspecs[#formspecs]:find("node_"..s3.."_0;", 1, true), "the live entry is the root node")
	gui({ ["node_"..s3.."_0"] = true })
	gui({ storage = true })
	local livefs = formspecs[#formspecs]
	assert(livefs:find("Storage of entry #"..s3.." · live", 1, true), "the live entry is shown as live")
	assert(livefs:find("demomod", 1, true), "its storage names the mod that holds it")
	assert(livefs:find("three-own", 1, true), "and lists the value")
	assert(not livefs:find("no storage", 1, true), "a live entry with storage does not report none")
	print("PASS: a live entry's storage is read from the table")

	-- and the filter's height is given, or the dropdown covers the first row
	local drop = livefs:match("dropdown%[[^%]]*%]")
	assert(drop, "the mod filter is a dropdown")
	assert(drop:find(";%d+%.?%d*,%d+%.?%d*;", 1), "with its height given rather than left to the engine: "..drop)

	-- An entry with more rows than the screen shows: the note for that pushes
	-- the picked row's panel down, and the button has to come with it. This is
	-- the only case where the panel does not start at 4.5, so it is the only
	-- one where the button's placement can be told from a fixed number.
	local big = dbmanager.new_entry()
	dbmanager.add_name(big, "bigstore")
	for i = 1, 210 do
		dbmanager.insert_into_modstorage(big, "bulkmod", "k"..i, "v"..i)
	end
	cmd.func("tester", "merge_gui")
	gui({ go = true, root = "#"..big, depth = "1" })
	gui({ ["node_"..big.."_0"] = true })
	gui({ storage = true })
	assert(formspecs[#formspecs]:find("showing 200 of 210", 1, true), "the row cap is reported")
	gui({ ms = "CHG:2:1" })
	local bigfs = formspecs[#formspecs]
	local big_btn = tonumber(bigfs:match("button%[[%d%.]+,([%d%.]+);[%d%.]+,[%d%.]+;ms_full;"))
	local big_hdr
	for _, y, text in bigfs:gmatch("label%[([%d%.]+),([%d%.]+);([^%]]*)%]") do
		if text:find("^mod ") then big_hdr = tonumber(y) end
	end
	assert(big_btn and big_hdr, "the panel and its button are both there")
	assert(big_hdr > 4.5, "the note really did move the panel down, to "..tostring(big_hdr))
	assert(math.abs(big_btn - (big_hdr - 0.05)) < 0.001, string.format(
		"the button follows the panel down (button %.2f, header %.2f)", big_btn, big_hdr))
	print("PASS: the panel's button follows it when the row cap note moves it")
end

-- the depth cap is 20 in the CLI too, not just in the message
do
	expect("tree alice 20", true, "current")
	expect("tree alice 21", false, "between 1 and 20")
end

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
