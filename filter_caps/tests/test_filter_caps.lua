-- Test suite for filter_caps. Runs with plain Lua, no Minetest needed:
--     lua test_filter_caps.lua
--
-- It stubs core/shareddb and loads the real utf8_simple, so this file must
-- live in a tests/ subdirectory of the mod in a checkout where filter_caps
-- and utf8_simple are siblings. All paths are relative to this file's
-- location.
--
-- get_player_by_name is stubbed case-insensitive, like the real engine
-- (ServerEnvironment::getPlayer uses strcasecmp). shareddb keys are the
-- chat command names: capsSpace, capsMax, capsWrap.

local script_path = arg and arg[0]
	or debug.getinfo(1, "S").source:match("^@(.+)$")
local script_dir = script_path and script_path:match("^(.*)/[^/]*$") or "."

local online = { ["Bob"] = true, ["č"] = true, ["Ana-Marija"] = true }
local storage = {}
local listener
local chatcmd
local db_error = false
local log_lines = {}

core = {
	registered_privileges = {},
	register_privilege = function() end,
	register_chatcommand = function(name, def) chatcmd = def end,
	register_on_chat_message = function() end,
	log = function(level, msg) table.insert(log_lines, { level = level, msg = msg }) end,
	deserialize = function(s) return s end,
	serialize = function(t) return t end,
	get_player_by_name = function(name)
		if name == nil or name == "" then return nil end
		for p in pairs(online) do
			if p:lower() == name:lower() then return {} end
		end
		return nil
	end,
	get_current_modname = function() return "filter_caps" end,
	get_modpath = function() return nil end,
}

shareddb = {
	get_mod_storage = function()
		return {
			get_context = function()
				return {
					get_string = function(_, key)
						if db_error then return nil, "simulated DB error" end
						return storage[key]
					end,
					set_string = function(_, key, value) storage[key] = value end,
					finalize = function() end,
				}
			end,
		}
	end,
	register_listener = function(l) listener = l end,
}

dofile(script_dir .. "/../../utf8_simple/init.lua")
dofile(script_dir .. "/../init.lua")

local passed, failed = 0, 0
local function dump_keys(t)
	local k = {}
	for kk in pairs(t) do k[#k + 1] = kk end
	return table.concat(k, ", ")
end
local function test(name, cond, detail)
	if cond then
		passed = passed + 1
		print("PASS " .. name)
	else
		failed = failed + 1
		print("FAIL " .. name)
		print("  " .. (detail or ""))
	end
end

-- --- default bound 2 behavior ---
test("wrapped both sides", filter_caps.parse("t", "@bob!") == "@bob!", "")
test("trailing comma", filter_caps.parse("t", "bob,") == "bob,", "")
test("three wrappers: bound 2", filter_caps.parse("t", "@@@bob") == "@@@bob", "")
test("unicode name wrapped", filter_caps.parse("t", "(č)") == "(č)", "")
test("dash not stripped", filter_caps.parse("t", "-bob") == "-bob", "")
test("caps word not player", filter_caps.parse("t", "BOBBY") == "BObby", "")

-- --- set capsWrap via chat command ---
local ok, msg = chatcmd.func("t", "capsWrap 1")
test("capsWrap set ok", ok == true and msg == "capsWrap set to: 1", tostring(msg))
test("stored under capsWrap key", storage["capsWrap"] == "1",
	"stored keys: " .. dump_keys(storage))

-- --- capsMax persists under its legacy key ---
local ok2, msg2 = chatcmd.func("t", "capsMax 3")
test("capsMax set ok", ok2 == true and msg2 == "capsMax set to: 3", tostring(msg2))
test("capsMax stored under capsMax", storage["capsMax"] == "3",
	"capsMax: " .. tostring(storage["capsMax"]))

-- --- live reload via shareddb listener ---
listener("capsWrap")
listener("capsMax")
test("bound 1: one wrapper ok", filter_caps.parse("t", "@bob") == "@bob", "")
test("bound 1: two wrappers exceed", filter_caps.parse("t", "@@bob") == "@@bob", "")
test("bound is per side", filter_caps.parse("t", "(č)") == "(č)", "")
test("capsMax 3 keeps 3 caps", filter_caps.parse("t", "BOBBY") == "BOBby",
	filter_caps.parse("t", "BOBBY"))

-- --- invalid value ---
local ok3, msg3 = chatcmd.func("t", "capsWrap abc")
test("invalid value rejected", ok3 == false and msg3:match("is currently at value: 1"), tostring(msg3))

-- --- cross-process write arrives via listener under legacy key name ---
storage["capsWrap"] = "3"
listener("capsWrap")
test("listener reloads capsWrap", filter_caps.parse("t", "@@@bob") == "@@@bob",
	filter_caps.parse("t", "@@@bob"))

-- --- restart simulation with a legacy capsMax row from the old code ---
storage["capsMax"] = "5"  -- as written by the pre-fix set_setting
dofile(script_dir .. "/../init.lua")
test("legacy capsMax row picked up", filter_caps.parse("t", "BOBBY") == "BOBBY",
	filter_caps.parse("t", "BOBBY"))
test("capsWrap 3 survives restart", filter_caps.parse("t", "@@@bob") == "@@@bob",
	filter_caps.parse("t", "@@@bob"))

-- --- capsWrap 0 disables stripping ---
chatcmd.func("t", "capsWrap 0")
listener("capsWrap")
test("capsWrap 0 disables stripping", filter_caps.parse("t", "@bob!") == "@bob!", "")

-- --- DB errors must not be mistaken for missing values ---
chatcmd.func("t", "capsMax 2")   -- pin caps_max so "@BOB!" discriminates the wrap bound
listener("capsMax")
db_error = true
listener("capsWrap")
test("DB error: current value kept, not reset to default",
	filter_caps.parse("t", "@BOB!") == "@BOb!", filter_caps.parse("t", "@BOB!"))
local has_err = false
for _, l in ipairs(log_lines) do
	if l.msg:match("shareddb error") then has_err = true end
end
test("DB error: logged", has_err, "")

-- --- boot with DB error: settings stay at code defaults ---
storage["capsMax"] = "5"
db_error = true
dofile(script_dir .. "/../init.lua")
db_error = false
test("boot DB error: capsMax stays code default 2, not the stored 5",
	filter_caps.parse("t", "BOBBY") == "BObby", filter_caps.parse("t", "BOBBY"))

print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
