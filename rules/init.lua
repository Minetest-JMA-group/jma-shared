rules = {txt = ""}

local rules_filepath = minetest.get_worldpath().."/rules.txt"

local function load_rules()
	local file = io.open(rules_filepath, "r")
	if file then
		local content = file:read("*a")
		file:close()
	    return content
	end
end

minetest.register_on_mods_loaded(function()
	local content = load_rules()
	if content then
		rules.txt = minetest.formspec_escape(content)
		minetest.log("action", "[rules]: " .. rules_filepath ..  " loaded successfully.")
	end
end)

if minetest.global_exists("sfinv") then
	sfinv.register_page("rules:rules", {
		title = "Rules",
		get = function(self, player, context)
			return sfinv.make_formspec(player, context,
				"hypertext[0,0;8.55,10.5;rules;" .. rules.txt .. "]", false)
		end
	})
end

local function need_to_accept(pname)
	return not minetest.check_player_privs(pname, { interact = true }) and
			not minetest.check_player_privs(pname, { shout = true })
end

local fsbase = "formspec_version[7]"
	.. "size[11,11]"
	.. "bgcolor[#00000000;false]"
	.. "box[0,0.7;11,9.1;#00000055]"
	.. "box[0,0;11,0.7;#000000ff]"

do
	local game = minetest.get_game_info()
	local game_title = game.title ~= "" and game.title or "JMA"
	fsbase = fsbase .. "hypertext[0,0;11,0.7;title;<global valign=middle><b>" .. game_title .. " — Server Rules</b>]"
end

function rules.show(player)
	local pname = player:get_player_name()
	local fs = fsbase .. "hypertext[0.1,0.8;10.8,8.9;rules;" .. rules.txt .. "]"

	if not need_to_accept(pname) then
		fs = fs .. "button_exit[3.5,10;4,0.8;ok;Okay]"
	else
		local yes = minetest.formspec_escape("Yes, let me play!")
		local no = minetest.formspec_escape("No, get me out of here!")

		fs = fs .. "button_exit[1.25,10;4,0.8;yes; " .. yes .. "]button_exit[5.75,10;4,0.8;no;" .. no .. "]"
	end

	-- minetest.show_formspec(pname, "rules:rules", fs)
	sfse.open_formspec(pname, "rules:rules", fs)
end

function rules.show_editor(pname)
	local content = load_rules() or ""
	local fs = fsbase
	.. "textarea[0.1,0.8;10.8,8.9;text;;" .. minetest.formspec_escape(content) .. "]"
	.. "button_exit[1.25,10;4,0.8;save;Save]"
	.. "button_exit[5.75,10;4,0.8;cancel;Cancel]"

	minetest.show_formspec(pname, "rules:rules_editor", fs)
end

minetest.register_chatcommand("rules", {
	func = function(pname, param)
		if param ~= "" and
				minetest.check_player_privs(pname, { moderator = true }) then
			pname = param
		end

		local player = minetest.get_player_by_name(pname)
		if player then
			rules.show(player)
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
		rules.show_editor(pname)
		return true, "Rules editor shown"
	end
})

minetest.register_on_newplayer(function(player)
	local pname = player:get_player_name()

	minetest.after(0.3, function ()
		if minetest.get_player_by_name(pname) then
			local privs = minetest.get_player_privs(pname)
			privs.shout = nil
			privs.interact = nil
			minetest.set_player_privs(pname, privs)

			rules.show(player)
		end
	end)
end)

minetest.register_on_joinplayer(function(player)
	if need_to_accept(player:get_player_name()) then
		rules.show(player)
	end
end)

minetest.register_on_player_receive_fields(function(player, form, fields)
	if form ~= "rules:rules" then return end

	local pname = player:get_player_name()
	if not need_to_accept(pname) then
		return true
	end

	if fields.yes then
		local privs = minetest.get_player_privs(pname)
		privs.shout = true
		privs.interact = true
		minetest.set_player_privs(pname, privs)
		minetest.chat_send_player(pname, minetest.colorize("lime", "Welcome ".. pname .."! You have now permission to play!"))
	elseif fields.no then
		minetest.kick_player(pname, "You need to agree to the rules to play on this server. Please rejoin and confirm another time.")
	-- elseif fields.guest then
	-- 	local msg = "To begin playing, please use the chat command \"/rules\" to review the server rules. Once you've read them, you'll need to accept them to play."
	-- 	minetest.chat_send_player(pname, minetest.colorize("orange", msg))
	elseif fields.quit then
		rules.show(player)
	end

	return true
end)

minetest.register_on_player_receive_fields(function(player, form, fields)
	if form ~= "rules:rules_editor" then return end

	local pname = player:get_player_name()
	if fields.save and fields.text then
		local new_txt = fields.text
		local file = io.open(rules_filepath, "w")
		if file then
			file:write(new_txt)
			file:close()

			rules.txt = minetest.formspec_escape(new_txt)
			minetest.chat_send_player(pname, "Rules saved")
			return true
		end
		minetest.chat_send_player(pname, "Failed to save")
	end

	return true
end)
