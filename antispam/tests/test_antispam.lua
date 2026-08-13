-- Test suite for antispam. Runs with plain Lua (luajit), no Minetest needed:
--     luajit test_antispam.lua
--
-- Stubs core/simplemod, loads the real init.lua, and drives the registered
-- on_chat_message callback with a controllable clock.

local script_path = arg and arg[0] or debug.getinfo(1, "S").source:match("^@(.+)$")
local script_dir = script_path:match("^(.*)/[^/]*$") or "."

local now_us = 1000000
local warns = {}
local mutes = {}
core = {}
core.get_us_time = function() return now_us end
core.register_on_leaveplayer = function() end
core.register_on_chat_message = function(f) core.on_chat = f end
core.chat_send_player = function(name, msg) warns[#warns + 1] = msg end
core.log = function() end
core.commands = {}
core.register_chatcommand = function(name, def) core.commands[name] = def end
core.get_color_escape_sequence = function() return "" end
core.get_current_modname = function() return "antispam" end
core.get_modpath = function() return nil end

simplemod = {
	mute_ip = function(name, source, reason, duration)
		mutes[#mutes + 1] = { name = name, reason = reason, duration = duration }
		return true
	end,
}

dofile(script_dir .. "/../../utf8_simple/init.lua")
dofile(script_dir .. "/../init.lua")

local chat = core.on_chat
local config = core.commands.antispam.func

local passed, failed = 0, 0
local function check(label, cond)
	if cond then
		passed = passed + 1
		print("ok: " .. label)
	else
		failed = failed + 1
		print("FAIL: " .. label)
	end
end

local function reset()
	warns, mutes = {}, {}
	antispam.players = {}
	now_us = 1000000
	-- restore defaults (tests like T4 change them via the config command)
	config("admin", "mute 2")
	config("admin", "rwarn 3")
	config("admin", "rmute 4")
end

-- say() advances the clock by gap_us (default 1s) before sending
local function say(name, msg, gap_us)
	now_us = now_us + (gap_us or 1e6)
	return chat(name, msg)
end

-- T1: the reported case — 4 identical spam messages
reset()
local ok1 = say("cockatiel", "SPAM spam spam spam")
local ok2 = say("cockatiel", "SPAM spam spam spam")
local ok3 = say("cockatiel", "SPAM spam spam spam")
local ok4 = say("cockatiel", "SPAM spam spam spam")
check("T1: first two pass", ok1 == false and ok2 == false)
check("T1: warning on 3rd repeat", ok3 == false and #warns == 1 and warns[1]:find("repeating") ~= nil)
check("T1: 4th repeat blocked and muted", ok4 == true and #mutes == 1)

-- T2: burst of distinct messages — warn once, sustained burst mutes
reset()
for i = 1, 4 do say("bob", "msg " .. i) end
check("T2: warn on 4th fast message", #warns == 1)
for i = 5, 7 do say("bob", "msg " .. i) end
check("T2: no re-warn within the same burst", #warns == 1)
check("T2: no mute before threshold", #mutes == 0)
say("bob", "msg 8")
check("T2: sustained burst mutes at 8", #mutes == 1)

-- T3: two bursts with a pause — second burst escalates to mute
reset()
for i = 1, 4 do say("carol", "m" .. i) end
check("T3: first burst warns once", #warns == 1)
say("carol", "m11", 7e6)
say("carol", "m12")
say("carol", "m13")
check("T3: second burst below threshold stays quiet", #warns == 1)
local blocked = say("carol", "m14")
-- the mute-triggering warning mutes before its warning text is sent
check("T3: 4th of second burst mutes", blocked == true and #warns == 1 and #mutes == 1)

-- T4: /antispam mute 1 takes effect (WARNS_BEFORE_KICK typo fix)
reset()
local cfg_ok, cfg_ret = config("admin", "mute 1")
check("T4: config command succeeds", cfg_ok == true)
for i = 1, 4 do say("dave", "x" .. i) end
check("T4: mutes at 1 warning", #mutes == 1)

-- T5: repeat counters reset after 30s
reset()
say("erin", "same")
say("erin", "same")
check("T5: two repeats quiet", #warns == 0)
now_us = now_us + 31e6
say("erin", "same")
say("erin", "same")
check("T5: still quiet after the 30s window", #warns == 0)
say("erin", "same")
check("T5: 3rd repeat in window warns", #warns == 1)

-- T6: /antispam rwarn / rmute options
reset()
config("admin", "rwarn 2")
config("admin", "rmute 3")
say("frank", "dup")
say("frank", "dup")
check("T6: warns at 2nd repeat", #warns == 1)
say("frank", "dup")
check("T6: mutes at 3rd repeat", #mutes == 1)

-- T7: the reported spam as a lone long message -> entropy warning; a second
-- such message (after a pause) escalates to a mute
local SPAM_BLAST = ("SPAM spam spam "):rep(66)
reset()
local s1 = say("grace", SPAM_BLAST, 7e6)
check("T7: lone spam blast warns, not mutes", s1 == false and #warns == 1
	and warns[1]:find("spam") ~= nil and #mutes == 0)
local s2 = say("grace", SPAM_BLAST, 7e6)
check("T7: second spam blast mutes", s2 == true and #mutes == 1)

-- T8: mixed-case and Cyrillic spam variants also warn
reset()
say("henry", ("SPAM spam Spam sPaM "):rep(25), 7e6)
check("T8: mixed-case variant warns", #warns == 1)
say("ivan", ("спам спам спам "):rep(25), 7e6)
check("T8: cyrillic variant warns", #warns == 2)

-- T9: exemptions — short laughter, Chinese, keyboard mash, normal long chat
reset()
say("judy", "hahaha lololol", 7e6)
check("T9: short laughter exempt", #warns == 0)
say("judy", ("的"):rep(40), 7e6)
check("T9: Chinese exempt (no Latin/Cyrillic letters)", #warns == 0)
say("judy", ("asdfghjkl"):rep(5), 7e6)
check("T9: keyboard mash above threshold", #warns == 0)
say("judy", ("the quick brown fox jumps over the lazy dog "):rep(2), 7e6)
check("T9: normal long chat exempt", #warns == 0)

-- T10: repeated low-entropy long message ("what what what...") warns
reset()
say("kevin", ("what what what what what "):rep(5), 7e6)
check("T10: long repetition warns", #warns == 1)

-- T11: entropy warning in a burst counts once (no double warning)
reset()
say("laura", "hi")
say("laura", SPAM_BLAST)
check("T11: entropy warn inside burst", #warns == 1 and #mutes == 0)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
