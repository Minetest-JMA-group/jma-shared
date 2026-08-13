-- Test suite for ai_filter_watcher's communication capture. Runs with plain
-- Lua (luajit or lua), no Minetest needed:
--     luajit test_ai_filter_watcher.lua
--
-- It stubs core/chat_lib/shareddb/cloudai/relays/algorithms and loads the
-- real init.lua in a sandbox, so this file must live in a tests/
-- subdirectory of the mod in a checkout. Two scenarios are loaded: email
-- absent (Mineclone2/Creative) and email present (CTF).

local script_path = arg and arg[0] or debug.getinfo(1, "S").source:match("^@(.+)$")
local script_dir = script_path:match("^(.*)/[^/]*$") or "."
local MOD_DIR = script_dir .. "/../"

-- Deterministic stand-ins for the engine's PcgRandom/sha1 so the privacy
-- salt and hashes are predictable: the salt is always "000000010000000200000003".
local function stub_sha1(s)
	return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end
local TEST_SALT = "000000010000000200000003"
local function test_hash(name)
	return stub_sha1(name .. TEST_SALT):sub(1, 12)
end

local function load_with_env(source, env)
	if setfenv then -- Lua 5.1 / LuaJIT
		local chunk = loadstring(source)
		setfenv(chunk, env)
		chunk()
	else -- Lua 5.2+
		load(source, "init.lua", "t", env)()
	end
end

local function make_env(globals, shareddb_values)
	local core = {}
	core.registered_chatcommands = {}
	core.registered_privileges = {}
	core.after_cb = nil
	core.globalstep_cb = nil
	core.chat_hook = nil
	core.send_all_hook = nil
	core.orig_msg_calls = {}
	core.global_exists = function(name)
		return globals[name] == true
	end
	core.get_current_modname = function() return "ai_filter_watcher" end
	core.get_modpath = function() return MOD_DIR end
	core.get_mod_storage = function()
		local store = {}
		return {
			get = function(self, k) return store[k] end,
			set_string = function(self, k, v) store[k] = v end,
		}
	end
	core.register_chatcommand = function(name, def)
		core.registered_chatcommands[name] = def
		return true
	end
	core.override_chatcommand = function(name, redef)
		local def = core.registered_chatcommands[name] or {}
		for k, v in pairs(redef) do def[k] = v end
		core.registered_chatcommands[name] = def
		return true
	end
	core.register_privilege = function() end
	core.register_globalstep = function(fn) core.globalstep_cb = fn end
	core.register_on_chat_message = function() end
	core.after = function(delay, fn) core.after_cb = fn end
	core.log = function() end
	core.serialize = function(t) return t end
	core.deserialize = function(s) return s end
	core.strip_colors = function(s) return s end
	core.PcgRandom = function()
		local n = 0
		return { next = function() n = n + 1 return n end }
	end
	core.sha1 = stub_sha1
	core.register_on_joinplayer = function(fn) core.join_cb = fn end

	local chat_lib = {}
	chat_lib.register_on_chat_message = function(priority, fn) core.chat_hook = fn end
	chat_lib.register_on_chat_send_all = function(fn) core.send_all_hook = fn end

	local cloudai = {}
	cloudai.last_prompt = nil
	cloudai.defer_cb = false
	cloudai.pending_cb = nil
	cloudai.get_context = function()
		local ctx = {}
		ctx.tools = {}
		ctx.set_system_prompt = function() end
		ctx.set_max_steps = function() end
		ctx.set_temperature = function() end
		ctx.set_frequency_penalty = function() end
		ctx.set_presence_penalty = function() end
		ctx.set_debug = function() end
		ctx.add_tool = function(self, def) table.insert(ctx.tools, def) end
		ctx.destroy = function() end
		ctx.call = function(self, prompt, cb)
			cloudai.last_prompt = prompt
			cloudai.last_ctx = ctx
			if cloudai.defer_cb then
				cloudai.pending_cb = cb
			else
				cb({}, nil, nil)
			end
			return true
		end
		return ctx
	end

	local shareddb = {}
	shareddb.get_mod_storage = function()
		return {
			get_context = function()
				local data = {}
				return {
					get_string = function(self, k) return shareddb_values and shareddb_values[k] end,
					set_string = function(self, k, v) data[k] = v return nil end,
					finalize = function(self) return nil end,
				}
			end,
		}
	end
	shareddb.register_listener = function() end

	local env
	env = setmetatable({
		core = core,
		chat_lib = chat_lib,
		cloudai = cloudai,
		shareddb = shareddb,
		relays = {
			send_action_report = function(fmt, ...)
				table.insert(env.relay_msgs, string.format(fmt, ...))
			end,
		},
		algorithms = {},
		essentials = {
			show_warn_formspec = function(name, reason, source)
				table.insert(env.essentials_calls, { name = name, reason = reason, source = source })
			end,
		},
		simplemod = {
			mute_name = function(target, source, reason, duration)
				table.insert(env.mute_calls, { target = target, source = source, reason = reason, duration = duration })
				return true
			end,
		},
		discord = {
			enabled = true,
			send_mention = function(msg, id)
				table.insert(env.discord_mentions, msg)
			end,
		},
		utf8_simple = {
			lower = function(s) return s:lower() end,
			sub = function(s, i, j) return string.sub(s, i, j) end,
			codepoint = function(s) return string.byte(s) end,
			chars = function(s)
				local i = 1
				return function()
					if i <= #s then
						local c = s:sub(i, i)
						i = i + 1
						return c
					end
				end
			end,
		},
	}, { __index = _G })

	env.relay_msgs = {}
	env.essentials_calls = {}
	env.mute_calls = {}
	env.discord_mentions = {}
	-- ASCII subset of the shared player name characters (tests use ASCII)
	env.utf8_simple.player_name_chars = {}
	for c in env.utf8_simple.chars("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_") do
		env.utf8_simple.player_name_chars[env.utf8_simple.codepoint(c)] = true
	end

	-- Commands registered before ai_filter_watcher loads (engine builtins and
	-- mods that load earlier). msg's original captures its call args.
	core.register_chatcommand("msg", {
		func = function(name, param)
			table.insert(core.orig_msg_calls, name .. "|" .. param)
			return true, "sent"
		end,
	})
	env.orig_msg = env.core.registered_chatcommands.msg.func
	core.register_chatcommand("t", { func = function() return true end })
	core.register_chatcommand("g", { func = function() return true end })
	core.register_chatcommand("me", { func = function() return true end })
	core.register_chatcommand("xmsg", { func = function() return true end })
	core.register_chatcommand("xdm", { func = function() return true end })
	core.register_chatcommand("tell", { alias = "msg" }) -- engine alias, no func
	core.register_chatcommand("mail", { func = function() return true end })
	env.orig_mail = env.core.registered_chatcommands.mail.func

	local source = io.open(MOD_DIR .. "init.lua"):read("*a")
	load_with_env(source, env)

	-- Boot callback: sweep + settings + prompt load
	env.core.after_cb()

	return env
end

local function dump_buffer(env)
	local _, out = env.core.registered_chatcommands.ai_watcher.func("tester", "dump")
	return out
end

local function buffer_count(env)
	return tonumber(dump_buffer(env):match("Current message buffer %((%d+) messages%)"))
end

local function check(cond, label)
	if not cond then
		error("FAIL: " .. label)
	end
	print("ok: " .. label)
end

local function contains(haystack, needle, label)
	if not haystack:find(needle, 1, true) then
		error("FAIL: " .. label .. " (missing: " .. needle .. ")")
	end
	print("ok: " .. label)
end

-- === Scenario A: no email mod (Mineclone2/Creative) ===
local envA = make_env({})
local cmdA = envA.core.registered_chatcommands

check(cmdA.msg.func ~= envA.orig_msg, "A: msg wrapped by sweep")
check(cmdA.mail.func == envA.orig_mail, "A: mail NOT wrapped without email mod")
check(cmdA.tell.func == nil, "A: alias not wrapped (no func)")

-- /msg <recipient> <message>
local ok, ret = cmdA.msg.func("alice", "bob hello world")
check(ok == true and ret == "sent", "A: msg returns original results")
check(envA.core.orig_msg_calls[1] == "alice|bob hello world", "A: msg original called with same args")
contains(dump_buffer(envA), "<alice> [PM to bob]: hello world", "A: msg recorded with tag")

-- second call -> one more entry (no double wrap)
cmdA.msg.func("alice", "bob again")
check(buffer_count(envA) == 2, "A: one entry per call, no double wrap")

-- recipient containing %-sequences must not break the wrapper
cmdA.msg.func("alice", "x%2l hello")
contains(dump_buffer(envA), "<alice> [PM to x%2l]: hello", "A: percent in recipient is safe")

-- bare /msg (no content) not recorded
local n_empty = buffer_count(envA)
cmdA.msg.func("alice", "")
check(buffer_count(envA) == n_empty, "A: empty param not recorded")

-- /t, /me, /xmsg: whole param is content
cmdA.t.func("bob", "  go left  ")
contains(dump_buffer(envA), "<bob> [TEAM]: go left", "A: /t content mode with trimming")
cmdA.me.func("carol", "waves at everyone")
contains(dump_buffer(envA), "<carol>: * carol waves at everyone", "A: /me rendered as regular message")
cmdA.xmsg.func("dave", "hi all")
contains(dump_buffer(envA), "<dave> [XMPP-DM]: hi all", "A: /xmsg")
cmdA.xdm.func("dave", "bob hi all")
contains(dump_buffer(envA), "<dave> [XMPP-DM to bob]: hi all", "A: /xdm")

-- command registered AFTER load gets wrapped via register_chatcommand
envA.core.register_chatcommand("bmsg", { func = function() return true end })
cmdA.bmsg.func("carol", "dave zdravo")
contains(dump_buffer(envA), "<carol> [BABEL PM to dave]: zdravo", "A: post-load registration wrapped")

-- override after load also wrapped
envA.core.override_chatcommand("msg", { func = function() return true end })
cmdA.msg.func("zed", "bob via override")
contains(dump_buffer(envA), "<zed> [PM to bob]: via override", "A: override after load wrapped")

-- add_message universal API
envA.ai_filter_watcher.add_message("erin", "subject: hello", "MAIL to frank")
contains(dump_buffer(envA), "<erin> [MAIL to frank]: subject: hello", "A: add_message API")

-- nil message via API is ignored
local n4 = buffer_count(envA)
envA.ai_filter_watcher.add_message("erin", nil, "MAIL to frank")
check(buffer_count(envA) == n4, "A: nil message ignored")

-- /mail re-registered after load, still not wrapped without email mod
local new_mail = function() return true end
envA.core.register_chatcommand("mail", { func = new_mail })
check(cmdA.mail.func == new_mail, "A: post-load /mail registration not wrapped without email mod")

-- inbound relays
envA.core.send_all_hook("<bob@Discord> hello there", "discordmt")
contains(dump_buffer(envA), "<bob> [DISCORD]: hello there", "A: discord inbound")
envA.core.send_all_hook("<alice> nick@XMPP: hi", "xmpp_relay")
contains(dump_buffer(envA), "<alice nick> [XMPP]: hi", "A: xmpp inbound (auth name)")

-- non-relay sources never captured
local n = buffer_count(envA)
envA.core.send_all_hook("<bob@Discord> nope", "random_messages")
envA.core.send_all_hook("<bob@Discord> nope", nil)
envA.core.send_all_hook("some system message", "server")
check(buffer_count(envA) == n, "A: non-relay sources not captured")

-- empty relay message not recorded
local n2 = buffer_count(envA)
envA.core.send_all_hook("<bob@Discord> ", "discordmt")
check(buffer_count(envA) == n2, "A: empty relay message skipped")

-- chat hook still works (public chat, no tag)
envA.core.chat_hook("frank", "regular public chat")
contains(dump_buffer(envA), "<frank>: regular public chat", "A: public chat captured untagged")

-- batch processing includes tagged lines in the prompt
envA.core.globalstep_cb(61)
local prompt = envA.cloudai.last_prompt
check(prompt ~= nil, "A: batch processed")
contains(prompt, "[PM to bob]: hello world", "A: batch prompt has PM line")
contains(prompt, "[TEAM]: go left", "A: batch prompt has TEAM line")
contains(prompt, "[BABEL PM to dave]: zdravo", "A: batch prompt has BABEL line")
contains(prompt, "[DISCORD]: hello there", "A: batch prompt has DISCORD line")
contains(prompt, "<frank>: regular public chat", "A: batch prompt has untagged line")

-- === Scenario B: email mod present (CTF) ===
local envB = make_env({ email = true })
local cmdB = envB.core.registered_chatcommands
check(cmdB.mail.func ~= envB.orig_mail, "B: mail wrapped when email mod exists")
cmdB.mail.func("alice", "bob mail body")
contains(dump_buffer(envB), "<alice> [MAIL to bob]: mail body", "B: /mail captured")

-- /mail without content not recorded (email mod would reject it anyway)
local n3 = buffer_count(envB)
cmdB.mail.func("alice", "bob")
check(buffer_count(envB) == n3, "B: /mail without content not recorded")

-- === Scenario C: watcher disabled ===
local envC = make_env({}, { mode = "disabled" })
local cmdC = envC.core.registered_chatcommands
cmdC.msg.func("alice", "bob hi")
envC.ai_filter_watcher.add_message("erin", "body", "MAIL to frank")
envC.core.chat_hook("frank", "public chat")
envC.core.send_all_hook("<bob@Discord> hello", "discordmt")
check(buffer_count(envC) == 0, "C: disabled mode records nothing")
envC.core.globalstep_cb(61)
check(envC.cloudai.last_prompt == nil, "C: disabled mode skips processing")

-- === Scenario D: hide_usernames enabled ===
local envD = make_env({ discord = true }, { hide_usernames = "true", mode = "permissive", min_batch_size = "1" })
local cmdD = envD.core.registered_chatcommands
local bh, ah = test_hash("bob"), test_hash("alice")

envD.core.join_cb({ get_player_name = function() return "bob" end })
envD.core.join_cb({ get_player_name = function() return "alice" end })

envD.core.chat_hook("alice", "bob hi")
envD.core.chat_hook("bob", "banana")
envD.core.chat_hook("alice", "(alice) <bob>: wrapped")
cmdD.msg.func("alice", "bob private")
envD.core.send_all_hook("<gl4iv3 [LmaoRocal_]@Discord> hi everyone", "discordmt")
envD.core.send_all_hook("<discordguy@Discord> hi", "discordmt")
envD.core.send_all_hook("<bob@Discord> hello", "discordmt")
envD.core.globalstep_cb(61)
local promptD = envD.cloudai.last_prompt
contains(promptD, "[" .. bh .. "] hi", "D: bob hashed in message")
contains(promptD, "banana", "D: normal words untouched")
contains(promptD, "PM to [" .. bh .. "]", "D: tag recipient hashed")
contains(promptD, "[" .. test_hash("gl4iv3 [LmaoRocal_]") .. "] [DISCORD]: hi everyone", "D: multi-token author masked as one hash")
contains(promptD, "[" .. test_hash("discordguy") .. "] [DISCORD]: hi", "D: relay author hashed")
check(not promptD:find("bob", 1, true), "D: no bare bob in prompt")
check(not promptD:find("alice", 1, true), "D: no bare alice in prompt")
check(not promptD:find("gl4iv3", 1, true), "D: no bare gl4iv3 in prompt")
check(not promptD:find("LmaoRocal_", 1, true), "D: no bare LmaoRocal_ in prompt")

-- tools from the last batch's context
local function find_tool(env, name)
	for _, def in ipairs(env.cloudai.last_ctx.tools) do
		if def.name == name then return def end
	end
end

-- warn in permissive mode relays a message with the REAL name
local warn_def = find_tool(envD, "warn_player")
local res = warn_def.func({ name = "[" .. bh .. "]", reason = "bad [" .. ah .. "] language" })
check(res.success == true, "D: warn tool succeeds")
contains(envD.relay_msgs[#envD.relay_msgs], "player 'bob' for: bad alice language", "D: tool args de-hashed to real names")

-- bracketless hash in name and reason also translates
warn_def.func({ name = bh, reason = "spam " .. ah })
contains(envD.relay_msgs[#envD.relay_msgs], "player 'bob' for: spam alice", "D: bracketless hashes de-hashed")

-- multi-token author name de-hashes to the full display name
warn_def.func({ name = "[" .. test_hash("gl4iv3 [LmaoRocal_]") .. "]", reason = "spam" })
contains(envD.relay_msgs[#envD.relay_msgs], "player 'gl4iv3 [LmaoRocal_]' for: spam", "D: multi-token author de-hashed")

-- unknown hex run is left as-is
warn_def.func({ name = "deadbeefcafe", reason = "x" })
contains(envD.relay_msgs[#envD.relay_msgs], "player 'deadbeefcafe'", "D: unknown hash left as-is")

-- report_player: moderator sees the real name, AI sees the hash again
local report_def = find_tool(envD, "report_player")
local res2 = report_def.func({ name = "[" .. bh .. "]", reason = "griefing" })
contains(envD.discord_mentions[#envD.discord_mentions], "Reported player bob", "D: discord mention has real name")
contains(res2.message, "[" .. bh .. "]", "D: report result re-hashed for the AI")

-- get_history result goes back to the AI masked
local gh_def = find_tool(envD, "get_history")
local res3 = gh_def.func({ messages = "5" })
contains(res3.history, "[" .. bh .. "]", "D: get_history result masked")
check(not res3.history:find("bob", 1, true), "D: get_history result has no real name")

-- command: no-arg reports state, off disables
local ok, ret = cmdD.ai_watcher.func("tester", "hide_usernames")
check(ok == true and ret == "Username hiding is enabled", "D: no-arg reports current state")
local ok2, ret2 = cmdD.ai_watcher.func("tester", "hide_usernames off")
check(ok2 == true and ret2 == "Username hiding disabled", "D: off disables")
envD.core.chat_hook("bob", "after disable")
envD.core.globalstep_cb(61)
contains(envD.cloudai.last_prompt, "<bob>: after disable", "D: disabled -> real names again")

-- === Scenario E: deferral while an AI run is active ===
local envE = make_env({}, { hide_usernames = "true", min_batch_size = "1" })
envE.core.join_cb({ get_player_name = function() return "alice" end })
envE.core.chat_hook("alice", "bob hello")
envE.cloudai.defer_cb = true
envE.core.globalstep_cb(61)
contains(envE.cloudai.last_prompt, "bob hello", "E: pre-join mention unmasked (bob not in table)")
envE.core.join_cb({ get_player_name = function() return "bob" end })  -- deferred while run active
envE.cloudai.pending_cb({}, nil, nil)  -- run ends -> pending names flushed
envE.cloudai.defer_cb = false
envE.core.chat_hook("alice", "bob again")
envE.core.globalstep_cb(61)
local promptE = envE.cloudai.last_prompt
contains(promptE, "[" .. test_hash("bob") .. "] again", "E: bob hashed in next batch after flush")
check(not promptE:find("bob", 1, true), "E: no bare bob after flush")

print("All tests passed.")
