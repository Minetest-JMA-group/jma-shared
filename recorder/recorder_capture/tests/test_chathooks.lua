-- The chat witness: where the module attaches, what it forwards, and what it
-- must never change. The chat mods are stood in for, so the two funnels and
-- the fallback can all be driven here.

local function script_dir()
	local src = debug.getinfo(1, "S").source:sub(2)  -- strip the leading "@"
	if src:sub(1, 1) ~= "/" then
		src = (os.getenv("PWD") or ".") .. "/" .. src
	end
	return src:match("^(.*)/[^/]+$")
end

local testdir = script_dir()
local capturepath = testdir:gsub("/tests$", "")
local chathooks = dofile(capturepath .. "/chathooks.lua")

local checks = 0
local function check(condition, message)
	checks = checks + 1
	if not condition then
		error("FAILED: " .. message, 2)
	end
	print("  ok - " .. message)
end

-- A stand-in engine and chat plumbing. `block_msgs` is added only when the
-- test is about the primary funnel; a chat_lib with a priority-100 callback
-- is what marks its backend as initialized.
local function new_env(options)
	options = options or {}
	local env = {seen = {}, reports = {}}
	env.observe = function(sender, message, source)
		env.seen[#env.seen + 1] = {sender = sender, message = message, source = source}
	end
	env.report = function(message) env.reports[#env.reports + 1] = message end

	env.core = {
		format_chat_message = function(name, message)
			env.format_calls = (env.format_calls or 0) + 1
			return "[" .. name .. "] " .. message
		end,
		chat_send_all = function(message, source)
			env.broadcast_calls = (env.broadcast_calls or 0) + 1
			return "sent"
		end,
	}

	if options.chat_lib ~= false then
		local callbacks = {}
		env.chat_lib = {
			registered_on_chat_message = {},
			register_on_chat_send_all = function(func)
				callbacks[#callbacks + 1] = func
			end,
		}
		env.send_all = function(message, source)
			local returned = {}
			for i, func in ipairs(callbacks) do
				returned[i] = func(message, source)
			end
			return returned
		end
	end

	if options.block_msgs then
		env.block_msgs = {
			delivered = {},
			chat_send_all = function(...)
				env.block_msgs.delivered[#env.block_msgs.delivered + 1] = {...}
				return "delivered"
			end,
		}
		if not options.backend_failed and env.chat_lib then
			env.chat_lib.registered_on_chat_message[100] = function() end
		end
	end
	return env
end

local function install(env)
	return chathooks.install({
		core = env.core,
		chat_lib = env.chat_lib,
		block_msgs = env.block_msgs,
		observe = env.observe,
		report = env.report,
	})
end

print("=== the two delivery funnels ===")
do
	local env = new_env({block_msgs = true})
	local installed = install(env)
	check(installed.normal_chat == "block_msgs.chat_send_all",
		"with block_msgs active, normal chat is watched at its delivery call")
	check(installed.broadcast == "chat_lib.register_on_chat_send_all",
		"and broadcasts through chat_lib's callback list")

	local sent = env.block_msgs.chat_send_all("Alice", "Alice: hello")
	check(sent == "delivered", "the witness returns exactly what delivery returned")
	check(#env.block_msgs.delivered == 1
		and env.block_msgs.delivered[1][1] == "Alice"
		and env.block_msgs.delivered[1][2] == "Alice: hello",
		"and delivery still happened with the same arguments")
	check(#env.seen == 1 and env.seen[1].sender == "Alice"
		and env.seen[1].message == "Alice: hello" and env.seen[1].source == "block_msgs",
		"the final line and its funnel are observed")

	-- The formatter is inside block_msgs' path; watching it as well would
	-- store every line twice.
	check(env.core.format_chat_message("Alice", "x") == "[Alice] x", "the formatter is untouched")
	check(#env.seen == 1, "and formatting alone is not observed")

	local returned = env.send_all("Server restarting", "server_restart")
	check(#env.seen == 2 and env.seen[2].sender == nil
		and env.seen[2].message == "Server restarting"
		and env.seen[2].source == "server_restart",
		"a broadcast is observed with its origin tag")
	check(returned[1] == nil, "and the callback returns nothing, so the broadcast is not cancelled")
end

print("=== without block_msgs: the engine formatter ===")
do
	local env = new_env({})
	local installed = install(env)
	check(installed.normal_chat == "core.format_chat_message",
		"normal chat is watched at the engine's formatter")
	check(installed.broadcast == "chat_lib.register_on_chat_send_all",
		"broadcasts still go through chat_lib")

	check(env.core.format_chat_message("Bob", "hi") == "[Bob] hi",
		"the formatter's result is returned unchanged")
	check(#env.seen == 1 and env.seen[1].sender == "Bob"
		and env.seen[1].message == "[Bob] hi" and env.seen[1].source == "format_chat_message",
		"the formatted line is observed, not the raw one")
	check(env.core.chat_send_all("m", "s") == "sent",
		"chat_send_all is not wrapped when chat_lib is there")
	check(#env.seen == 1, "so a direct engine call adds nothing")

	-- A mod may format a line and then broadcast it (CTF's /g does); the same
	-- line must not be stored twice.
	local formatted = env.core.format_chat_message("Bob", "go")
	env.send_all(formatted, "ctf_chat")
	check(#env.seen == 2 and env.seen[2].source == "format_chat_message",
		"a formatted line that is then broadcast is recorded once")
	env.send_all("another announcement", nil)
	check(#env.seen == 3 and env.seen[3].message == "another announcement",
		"an unrelated broadcast after it is still recorded")

	env.send_all("announcement", nil)
	check(#env.seen == 4 and env.seen[4].source == "chat_send_all",
		"a broadcast with no source gets the generic tag")
end

print("=== a server without the chat plumbing ===")
do
	local env = new_env({chat_lib = false})
	local installed = install(env)
	check(installed.normal_chat == "core.format_chat_message" and installed.broadcast == "core.chat_send_all",
		"both the formatter and the broadcast call get wrapped")
	check(env.core.chat_send_all("hello", "src") == "sent",
		"the broadcast wrapper returns the original result")
	check(#env.seen == 1 and env.seen[1].message == "hello" and env.seen[1].source == "src",
		"and observes the broadcast")
end

print("=== a failed block_msgs backend ===")
do
	-- The table exists, but without the priority-100 callback it only forwards
	-- other mods' broadcasts; normal chat goes to the engine default path.
	local env = new_env({block_msgs = true, backend_failed = true})
	local installed = install(env)
	check(installed.normal_chat == "core.format_chat_message",
		"the formatter is watched instead")
	check(env.block_msgs.chat_send_all("Alice", "x") == "delivered",
		"the passthrough is left alone")
	check(#env.seen == 0, "and does not double-record")
end

print("=== a broken observer changes nothing ===")
do
	local env = new_env({block_msgs = true})
	env.observe = function() error("observer bug") end
	install(env)
	local sent = env.block_msgs.chat_send_all("Alice", "still delivered")
	check(sent == "delivered", "delivery and its result survive the observer's failure")
	check(#env.reports == 1 and env.reports[1]:find("observer bug", 1, true) ~= nil,
		"and the failure is reported")
	env.block_msgs.chat_send_all("Alice", "")
	check(#env.reports == 1, "an empty line is not an event at all")
end

print(("\n%d checks passed"):format(checks))
