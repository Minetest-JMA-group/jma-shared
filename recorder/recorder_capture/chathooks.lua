-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

-- Observe final global chat through two independent paths: formatted player
-- lines via block_msgs and mod broadcasts via chat_lib send-all callbacks.
-- Without a working block_msgs backend, core.format_chat_message is the last
-- Lua hook for player chat. Install after mods load, once chat overrides are
-- in place. Chat objects are injected for testing.

local chathooks = {}

local unpack = table.unpack or unpack

local function pack(...)
	return {n = select("#", ...), ...}
end

local function unpack_all(packed)
	return unpack(packed, 1, packed.n)
end

-- A recorder bug must never escape into the chat pipeline: this is a witness,
-- so a failure is reported and the message is still delivered unchanged.
local function observed(env, sender, message, source)
	if type(message) ~= "string" or message == "" then return end
	local ok, err = pcall(env.observe, sender, message, source)
	if not ok and env.report then
		env.report(tostring(err))
	end
end

-- Put the observer on the delivery funnels. Returns what was installed, for
-- the startup log and for tests.
---@param env table  -- {core =, chat_lib =, block_msgs =, observe = fun, report = fun?}
---@return table  -- {normal_chat = string?, broadcast = string?}
function chathooks.install(env)
	local core, chat_lib, block_msgs = env.core, env.chat_lib, env.block_msgs
	local installed = {}

	-- A mod may format and then broadcast the same line. Suppress that duplicate
	-- only for an exact string match in the same step.
	local pending_format
	local function now()
		return env.now and env.now() or nil
	end
	local function take_pending(message)
		if pending_format == nil or pending_format.message ~= message then return false end
		local same_step = pending_format.at == nil or now() == nil or pending_format.at == now()
		pending_format = nil
		return same_step
	end

	-- Normal player chat. The priority-100 callback in chat_lib is the proof
	-- that block_msgs' backend initialized; the table alone also exists when
	-- it failed, and then only forwards other mods' broadcasts.
	local active = type(chat_lib) == "table"
		and type(chat_lib.registered_on_chat_message) == "table"
		and chat_lib.registered_on_chat_message[100] ~= nil
	if active and type(block_msgs) == "table"
		and type(block_msgs.chat_send_all) == "function" then
		local original = block_msgs.chat_send_all
		block_msgs.chat_send_all = function(...)
			local args = pack(...)
			local result = pack(original(...))
			observed(env, args[1], args[2], "block_msgs")
			return unpack_all(result)
		end
		installed.normal_chat = "block_msgs.chat_send_all"
	elseif type(core.format_chat_message) == "function" then
		local original = core.format_chat_message
		core.format_chat_message = function(...)
			local args = pack(...)
			local result = pack(original(...))
			observed(env, args[1], result[1], "format_chat_message")
			if type(result[1]) == "string" then
				pending_format = {message = result[1], at = now()}
			end
			return unpack_all(result)
		end
		installed.normal_chat = "core.format_chat_message"
	end

	-- Broadcasts. chat_lib's own callback list is the documented way in; its
	-- callback must return nothing, because a truthy value cancels the send.
	if type(chat_lib) == "table"
		and type(chat_lib.register_on_chat_send_all) == "function" then
		chat_lib.register_on_chat_send_all(function(message, source)
			if take_pending(message) then return end
			observed(env, nil, message, source or "chat_send_all")
		end)
		installed.broadcast = "chat_lib.register_on_chat_send_all"
	elseif type(core.chat_send_all) == "function" then
		local original = core.chat_send_all
		core.chat_send_all = function(...)
			local args = pack(...)
			local result = pack(original(...))
			if not take_pending(args[1]) then
				observed(env, nil, args[1], args[2] or "chat_send_all")
			end
			return unpack_all(result)
		end
		installed.broadcast = "core.chat_send_all"
	end

	return installed
end

return chathooks
