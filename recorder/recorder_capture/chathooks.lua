-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

-- Where global chat becomes visible to clients, and how to watch it without
-- standing in its way.
--
-- Chat reaches the clients through two funnels that do not call each other:
--
--   * normal player chat is formatted and then handed to block_msgs, which
--     delivers the same final line to every player who has not blocked the
--     sender;
--   * everything a mod broadcasts - spectator chat, /g, /me, announcements,
--     messages relayed in from Discord or XMPP - goes through chat_lib's
--     send-all callbacks.
--
-- A recorder needs to see both, because neither funnel calls the other. When
-- block_msgs is absent (or its backend failed, in which case it registers no
-- chat callback), the engine formats and broadcasts player chat itself and
-- the formatter is the last Lua code in that path, so that is the fallback.
--
-- The module takes the chat objects as arguments instead of reading globals,
-- so a test can drive it with stand-ins. Installation belongs after
-- core.register_on_mods_loaded: the chat mods replace these functions while
-- they load, and a wrapper put in place earlier would be dropped.

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
			return unpack_all(result)
		end
		installed.normal_chat = "core.format_chat_message"
	end

	-- Broadcasts. chat_lib's own callback list is the documented way in; its
	-- callback must return nothing, because a truthy value cancels the send.
	if type(chat_lib) == "table"
		and type(chat_lib.register_on_chat_send_all) == "function" then
		chat_lib.register_on_chat_send_all(function(message, source)
			observed(env, nil, message, source or "chat_send_all")
		end)
		installed.broadcast = "chat_lib.register_on_chat_send_all"
	elseif type(core.chat_send_all) == "function" then
		local original = core.chat_send_all
		core.chat_send_all = function(...)
			local args = pack(...)
			local result = pack(original(...))
			observed(env, nil, args[1], args[2] or "chat_send_all")
			return unpack_all(result)
		end
		installed.broadcast = "core.chat_send_all"
	end

	return installed
end

return chathooks
