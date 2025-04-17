block_msgs = {}
if not algorithms.load_library() then
	block_msgs.is_chat_blocked = function() return false end
	return
end

function block_msgs.chat_send_all(sender_name, message)
	for _, player in ipairs(core.get_connected_players()) do
		local receiver_name = player:get_player_name()
		if not block_msgs.is_chat_blocked(sender_name, receiver_name) then
			core.chat_send_player(receiver_name, formatted_message)
		end
	end
end

local registered_on_chat_messages_snapshot = {}

core.register_on_chat_message(function(sender_name, message)
	-- Call other callbacks so that we're last
	for _, func in ipairs(core.registered_on_chat_messages) do
		if not registered_on_chat_messages_snapshot[func] then
			if func(sender_name, message) then
				return true
			end
		end
	end

	if message:sub(1, 1) == "/" then
		return false -- let commands through unhandled
	end

	local formatted_message = core.format_chat_message(sender_name, message)
	block_msgs.chat_send_all(sender_name, formatted_message)
	core.log("action", "CHAT: <"..sender_name..">: "..message)

	return true
end)

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
			return false
		end

		return old_func(sender_name, param)
	end
end

for name, def in pairs(minetest.registered_chatcommands) do
	if directed_chatcomms[name] then
		def.func = make_checker(def.func)
	end
end

local old_register_chatcommand = minetest.register_chatcommand
function minetest.register_chatcommand(name, def)
	if directed_chatcomms[name] then
		def.func = make_checker(def.func)
	end
	return old_register_chatcommand(name, def)
end

local old_override_chatcommand = minetest.override_chatcommand
function minetest.override_chatcommand(name, def)
	if directed_chatcomms[name] then
		def.func = make_checker(def.func)
	end
	return old_override_chatcommand(name, def)
end
