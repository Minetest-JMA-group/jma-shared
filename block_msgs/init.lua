-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

block_msgs = {}
local modname = core.get_current_modname()
local modpath = core.get_modpath(modname)

local function disable_backend()
	block_msgs.is_chat_blocked = function() return false end
	block_msgs.chat_send_all = function(_, message) core.chat_send_all(message) end
end

local backend_err = dofile(modpath.."/backend.lua")
if backend_err then
	core.log("error", "[block_msgs] Failed to initialize backend: "..tostring(backend_err))
	disable_backend()
	return
end

function block_msgs.chat_send_all(sender_name, message)
	for _, player in ipairs(core.get_connected_players()) do
		local receiver_name = player:get_player_name()
		if not block_msgs.is_chat_blocked(sender_name, receiver_name) then
			core.chat_send_player(receiver_name, message)
		end
	end
end

local registered_on_chat_messages_snapshot = {}
local our_index = 0
local our_callback_ref
local our_callback = function(sender_name, message)
	if core.registered_on_chat_messages[our_index] ~= our_callback_ref then
		-- Some mod inserted themselves into the table and messed our index, or we haven't found it yet
		for i, v in ipairs(core.registered_on_chat_messages) do
			if v == our_callback_ref then
				our_index = i
				break
			end
			our_index = 0
		end
		if our_index == 0 then
			error("block_msgs can't find its own callback in core.registered_on_chat_messages")
		end
	end

	-- Call other callbacks so that we're last
	local i = our_index + 1
	while core.registered_on_chat_messages[i] do
		if core.registered_on_chat_messages[i](sender_name, message) then
			return true
		end
	end

	if message:sub(1, 1) == "/" then
		return false -- let commands through unhandled
	end

	local formatted_message = core.format_chat_message(sender_name, message)
	block_msgs.chat_send_all(sender_name, formatted_message)
	core.log("action", "CHAT: <"..sender_name..">: "..message)

	return true
end
our_callback_ref = our_callback

core.register_on_chat_message(our_callback)

for _, func in ipairs(core.registered_on_chat_messages) do
	registered_on_chat_messages_snapshot[func] = true
end

local directed_chatcomms = {
	["msg"] = true,
	["bmsg"] = true,
	["mail"] = true,
	["donate"] = true,
}

local function make_checker(old_func)
	return function(sender_name, param)
		local iter = param:gmatch("%S+")
		local receiver_name = iter()
		if block_msgs.is_chat_blocked(sender_name, receiver_name) then
			core.chat_send_player(sender_name, "You cannot interact with "..receiver_name.."\nThey have blocked you.")
			return true
		end

		return old_func(sender_name, param)
	end
end

for name, def in pairs(core.registered_chatcommands) do
	if directed_chatcomms[name] then
		def.func = make_checker(def.func)
	end
end

local old_register_chatcommand = core.register_chatcommand
function core.register_chatcommand(name, def)
	if directed_chatcomms[name] then
		def.func = make_checker(def.func)
	end
	return old_register_chatcommand(name, def)
end

local old_override_chatcommand = core.override_chatcommand
function core.override_chatcommand(name, def)
	if directed_chatcomms[name] then
		def.func = make_checker(def.func)
	end
	return old_override_chatcommand(name, def)
end
