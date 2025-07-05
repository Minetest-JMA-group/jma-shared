local rules_text = ""
local filename = "rules.txt"

minetest.register_on_mods_loaded(function()
	local content = jma_greeter.load_file(filename)
	if content then
		rules_text = minetest.formspec_escape(content)
		minetest.log("action", "[jma_greeter]: rules: " .. filename ..  " loaded")
	end
end)

if minetest.global_exists("sfinv") then
	sfinv.register_page("rules:rules", {
		title = "Rules",
		get = function(self, player, context)
			return sfinv.make_formspec(player, context,
				"hypertext[0,0;8.55,10.5;rules;" .. rules_text .. "]", false)
		end
	})
end

function jma_greeter.need_to_accept(pname)
	if jma_greeter.rules_mode == "no_priv_change" then
		-- In "no_priv_change" mode, no need to check privileges
		return false
	end
	return not minetest.check_player_privs(pname, { interact = true }) and
			not minetest.check_player_privs(pname, { shout = true })
end

function jma_greeter.show_rules(player)
	local pname = player:get_player_name()
	local fs = jma_greeter.get_base_formspec({
		title  = "Server Rules",
		size = {x = 11, y = 11},
	})
	.. "box[0,0.7;11,9.1;#00000055]"
	.. "hypertext[0.1,0.8;10.8,8.9;rules;" .. minetest.formspec_escape(rules_text) .. "]"

	if not jma_greeter.need_to_accept(pname) then
		fs = fs .. "button_exit[3.5,10;4,0.8;ok;Okay]"
	else
		local yes = minetest.formspec_escape("Yes, let me play!")
		local no = minetest.formspec_escape("No, get me out of here!")

		fs = fs .. "button_exit[1.25,10;4,0.8;yes; " .. yes .. "]button_exit[5.75,10;4,0.8;no;" .. no .. "]"
	end

	minetest.show_formspec(pname, "jma_greeter:rules", fs)
end

minetest.register_chatcommand("rules", {
	func = function(pname, param)
		if param ~= "" and minetest.check_player_privs(pname, {moderator = true}) then
			pname = param
		end

		local player = minetest.get_player_by_name(pname)
		if player then
			jma_greeter.show_rules(player)
			return true, "Rules shown."
		else
			return false, "Player " .. pname .. " does not exist or is not online"
		end
	end
})

minetest.register_chatcommand("rules_editor", {
	description = "Server rules editor",
	privs = {server = true},
	func = function(pname)
		local actions = {
			on_save = function(fields)
				if fields.text and jma_greeter.write_file(filename, fields.text) then
					rules_text = fields.text
					minetest.chat_send_player(pname, "Rules saved.")
				else
					minetest.chat_send_player(pname, "Failed to save")
				end
			end,
			on_cancel = function()
				minetest.chat_send_player(pname, "Cancelled")
				jma_greeter.editor_context[pname] = nil
			end
		}
		jma_greeter.show_editor(pname, jma_greeter.load_file(filename) or "", "Rules", actions)
		return true, "Rules editor shown"
	end
})

minetest.register_on_player_receive_fields(function(player, form, fields)
	if form ~= "jma_greeter:rules" then return end

	local pname = player:get_player_name()
	if jma_greeter.need_to_accept(pname) then
		if fields.yes then
			if jma_greeter.rules_mode == "grant_privs" then
				-- Grant privileges in "grant_privs" mode
				local privs = minetest.get_player_privs(pname)
				privs.shout = true
				privs.interact = true
				minetest.set_player_privs(pname, privs)
				minetest.chat_send_player(pname, minetest.colorize("lime", "Welcome ".. pname .."! You have now permission to play!"))
			else
				-- Just allow the player to play in "no_priv_change" mode
				minetest.chat_send_player(pname, minetest.colorize("lime", "Welcome ".. pname .."! You can now play!"))
			end
			jma_greeter.queue_next(player)
			return true
		elseif fields.no then
			minetest.kick_player(pname, "You need to agree to the rules to play on this server. Please rejoin and confirm another time.")
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
