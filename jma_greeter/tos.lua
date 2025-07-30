local tos_url = "https://github.com/Minetest-JMA-group/information"
local kick_message = "You must accept the Terms of Service to play on this server.\nSince you have declined, you cannot join at this time.\nIf you change your mind, please reconnect and accept the TOS."
local storage = minetest.get_mod_storage()
local pending_confirmations = {}
local confirmation_timeout = 10

local function get_current_tos_version()
	return storage:get_int("tos_version")
end

function jma_greeter.has_accepted_tos(player)
	local accepted_version = player:get_meta():get_int("jma_greeter_tos_accepted")
	return accepted_version >= get_current_tos_version()
end

function jma_greeter.show_tos(player)
	local pname = player:get_player_name()
	local fs = jma_greeter.get_base_formspec({
		title_override = "JMA Terms of Service",
		size = {x = 8, y = 8},
	})
	.. "box[0,0.8;8,5.35;#202232]"

	if jma_greeter.has_accepted_tos(player) then
		-- Player is up-to-date
		fs = fs .. "textarea[0.1,1.2;7.8,0.6;tos_url;;" .. tos_url .. "]"
		.. "button_url[2.5,2.5;3,1;tos_button;Open TOS;" .. tos_url .. "]"
		.. "button_exit[2.5,6.5;3,1;ok;Okay]"
	else
		-- Player needs to accept new or initial TOS
		local accepted_version = player:get_meta():get_int("jma_greeter_tos_accepted") or 0
		local hypertext
		local tos_text = storage:get_string("tos_text")
		-- TOS version 0 is equal to non-existent
		if accepted_version > 0 and accepted_version < get_current_tos_version() then
			hypertext = "hypertext[0.1,0.9;7.8,2.4;tos_text;" .. minetest.formspec_escape("<style color=orange><big>The Terms of Service have been updated. Please accept the new terms to continue playing.</big></style>\n" .. tos_text) .. "]"
		else
			hypertext = "hypertext[0.1,0.9;7.8,2.4;tos_text;<style color=red><big>Please read our Terms of Service before proceeding.</big></style>]"
		end

		fs = fs .. hypertext
		.. "textarea[0.1,3.5;7.8,0.6;tos_url;;" .. tos_url .. "]"
		.. "button_url[2.5,4.8;3,1;tos_button;Open TOS;" .. tos_url .. "]"
		.. "button_exit[1,6.5;2.5,1;yes;Accept]"
		.. "button_exit[4.5,6.5;2.5,1;no;Decline]"
	end

	minetest.show_formspec(pname, "jma_greeter:tos", fs)
end

minetest.register_chatcommand("tos", {
	description = "Show Terms of Service",
	func = function(pname, param)
		if param ~= "" and minetest.check_player_privs(pname, {moderator = true}) then
			pname = param
		end

		local player = minetest.get_player_by_name(pname)
		if player then
			jma_greeter.show_tos(player)
			return true, "TOS shown."
		else
			return false, "Player " .. pname .. " does not exist or is not online"
		end
	end
})

minetest.register_chatcommand("update_tos", {
	description = "Update TOS version and text. Usage: /update_tos [new text]",
	privs = {server = true},
	params = "[new text]",
	func = function(pname, param)
		local player = minetest.get_player_by_name(pname)
		if not player then
			return false, "Player not found."
		end

		if pending_confirmations[pname] then
			-- Second execution, confirm the action
			pending_confirmations[pname]:cancel()
			pending_confirmations[pname] = nil

			local new_version = get_current_tos_version() + 1
			storage:set_int("tos_version", new_version)

			if param and param ~= "" then
				storage:set_string("tos_text", param)
				minetest.chat_send_player(pname, "TOS text updated.")
			end

			minetest.chat_send_all("The Terms of Service have been updated. Please type /tos to review and accept the new terms.")
			return true, "TOS version updated to " .. new_version .. ". Action confirmed."
		else
			-- First execution, request confirmation
			pending_confirmations[pname] = minetest.after(confirmation_timeout, function()
				pending_confirmations[pname] = nil
				minetest.chat_send_player(pname, "Confirmation for /update_tos timed out. Please re-enter the command if you still wish to proceed.")
			end)
			minetest.chat_send_player(pname, "Please repeat the /update_tos command within " .. confirmation_timeout .. " seconds to confirm the action.")
			return true, "Confirmation required."
		end
	end
})

minetest.register_on_player_receive_fields(function(player, form, fields)
	if form ~= "jma_greeter:tos" then return end

	local pname = player:get_player_name()
	if fields.yes then
		player:get_meta():set_int("jma_greeter_tos_accepted", get_current_tos_version())
		jma_greeter.queue_next(player)
	elseif fields.no then
		minetest.kick_player(pname, kick_message)
	elseif fields.quit and not jma_greeter.has_accepted_tos(player) then
		jma_greeter.show_tos(player)
	end
	return true
end)
