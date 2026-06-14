local rules_text = ""
local filename = "rules.txt"
local storage = core.get_mod_storage()
local pending_confirmations = {}
local confirmation_timeout = 10

if not storage:contains("rules_version") then
	storage:set_int("rules_version", 1)
end

local function get_current_rules_version()
	return storage:get_int("rules_version")
end

local function bump_rules_version()
	local new_version = get_current_rules_version() + 1
	storage:set_int("rules_version", new_version)
	return new_version
end

core.register_on_mods_loaded(function()
	local content = jma_greeter.load_file(filename)
	if content then
		rules_text = content
		core.log("action", "[jma_greeter]: rules: " .. filename .. " loaded")
	end
end)

if core.global_exists("sfinv") then
	sfinv.register_page("rules:rules", {
		title = "Rules",
		get = function(self, player, context)
			return sfinv.make_formspec(player, context, "hypertext[0,0;8.55,10.5;rules;" .. core.formspec_escape(rules_text) .. "]", false)
		end,
	})
end

function jma_greeter.has_accepted_rules(player)
	local accepted_version = player:get_meta():get_int("jma_greeter_rules_accepted")
	return accepted_version >= get_current_rules_version()
end

function jma_greeter.need_to_accept(player)
	if not player then
		return false
	end
	return not jma_greeter.has_accepted_rules(player)
end

function jma_greeter.old_rules_accepted(player)
	local accepted_version = player:get_meta():get_int("jma_greeter_rules_accepted")
	return accepted_version > 0 and accepted_version < get_current_rules_version()
end

function jma_greeter.show_rules(player)
	local pname = player:get_player_name()

	local text = rules_text
	local header
	local buttons = "button_exit[3.5,10;4,0.8;ok;Okay]"
	if jma_greeter.need_to_accept(player) then
		local accepted_version = player:get_meta():get_int("jma_greeter_rules_accepted") or 0
		if accepted_version > 0 and accepted_version < get_current_rules_version() then
			header = core.formspec_escape(
				"<style color=orange><big>The server rules have been updated. Please accept the new rules to continue playing.</big></style>"
			)
		else
			header = core.formspec_escape(
				"<style color=red><b>Please read and accept the server rules before proceeding.</b></style>"
			)
		end

		local yes = core.formspec_escape("Yes, let me play!")
		local no = core.formspec_escape("No, get me out of here!")

		buttons = "button_exit[1.25,10;4,0.8;yes; " ..
		yes .. "]button_exit[5.75,10;4,0.8;no;" .. no .. "]"
	end

	if header then
		text = header .. "\n" .. text
	end

	local fs = jma_greeter.get_base_formspec({
		title = "Server Rules",
		size = { x = 11, y = 11.5},
	}) ..
		"box[0,0.7;11,9.1;#00000055]" ..
		"hypertext[0.1,0.8;10.8,8.9;rules;" ..
		core.formspec_escape(text) .. "]" ..
		buttons

	core.show_formspec(pname, "jma_greeter:rules", fs)
end

core.register_chatcommand("rules", {
	func = function(pname, param)
		if param ~= "" and core.check_player_privs(pname, { moderator = true }) then
			pname = param
		end

		local player = core.get_player_by_name(pname)
		if player then
			jma_greeter.show_rules(player)
			return true, "Rules shown."
		else
			return false, "Player " .. pname .. " does not exist or is not online"
		end
	end,
})

core.register_chatcommand("update_rules", {
	description = "Update rules version and text. Usage: /update_rules [new text]",
	privs = { server = true },
	params = "",
	func = function(pname, param)
		if pending_confirmations[pname] then
			pending_confirmations[pname]:cancel()
			pending_confirmations[pname] = nil

			local new_version = bump_rules_version()

			core.chat_send_all(
				"The server rules have been updated. Please type /rules to review and accept the new rules."
			)
			return true, "Rules version updated to " .. new_version .. ". Action confirmed."
		else
			pending_confirmations[pname] = core.after(confirmation_timeout, function()
				pending_confirmations[pname] = nil
				core.chat_send_player(
					pname,
					"Confirmation for /update_rules timed out. Please re-enter the command if you still wish to proceed."
				)
			end)
			core.chat_send_player(
				pname,
				"Please repeat the /update_rules command within "
					.. confirmation_timeout
					.. " seconds to confirm the action."
			)
			return true, "Confirmation required."
		end
	end,
})

core.register_chatcommand("rules_editor", {
	description = "Server rules editor",
	privs = { server = true },
	func = function(pname)
		local actions = {
			on_save = function(fields)
				local new_text = fields.text
				if new_text and #new_text > 0 and jma_greeter.write_file(filename, new_text) then
					rules_text = new_text
					core.chat_send_player(pname, "Rules saved. Note: Use /update_rules to bump the rules version and notify players")
				else
					core.chat_send_player(pname, "Failed to save rules. Please ensure the text is not empty and try again.")
				end
			end,
			on_cancel = function()
				core.chat_send_player(pname, "Cancelled rules editing.")
				jma_greeter.editor_context[pname] = nil
			end,
		}
		jma_greeter.show_editor(pname, jma_greeter.load_file(filename) or "", "Rules",
		actions)
		return true, "Rules editor shown"
	end,
})

core.register_on_player_receive_fields(function(player, form, fields)
	if form ~= "jma_greeter:rules" then
		return
	end

	local pname = player:get_player_name()
	if jma_greeter.need_to_accept(player) then
		if fields.yes then
			core.log("action", "[jma_greeter]: Player " .. pname .. " accepted rules.")
			player:get_meta():set_int("jma_greeter_rules_accepted", get_current_rules_version())
			if jma_greeter.rules_mode == "grant_privs" then
				-- Grant privileges in "grant_privs" mode
				local privs = core.get_player_privs(pname)
				privs.shout = true
				privs.interact = true
				core.set_player_privs(pname, privs)
				core.chat_send_player(
					pname,
					core.colorize("lime", "Welcome " .. pname .. "! You have now permission to play!")
				)
			else
				-- Just allow the player to play in "no_priv_change" mode
				core.chat_send_player(pname, core.colorize("lime", "Welcome " .. pname .. "! You can now play!"))
			end
			jma_greeter.queue_next(player)
			return true
		elseif fields.no then
			core.log("action", "[jma_greeter]: Player " .. pname .. " declined rules.")
			core.kick_player(
				pname,
				"You must accept the server rules to play. If you change your mind, please rejoin and accept the rules."
			)
			if jma_greeter.players_greeting_events[pname] then
				jma_greeter.players_greeting_events[pname] = nil
			end
		elseif fields.quit then
			jma_greeter.show_rules(player)
		end
	else
		if fields.quit then
			jma_greeter.queue_next(player)
		end
	end

	return true
end)
