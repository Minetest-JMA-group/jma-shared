jma_greeter = {
	players_greeting_events = {},
	editor_context = {},
	events_on_newplayer = {"new_player_rules", "news"},
	events_on_join = {"news"},
	rules_mode = minetest.settings:get("jma_greeter_rules_mode") or "grant_privs"
	-- Modes:
	-- "grant_privs" - Grant privileges after accepting rules
	-- "no_priv_change" - Do not modify privileges, just allow the player to play
}

local worldpath = minetest.get_worldpath()

local game_title
do
	local game = minetest.get_game_info()
	game_title = game.title ~= "" and game.title or "JMA"
end

function jma_greeter.get_base_formspec(def)
	local size = def.size
	return "formspec_version[7]"
	.. string.format("size[%d,%d]", size.x, size.y)
	.. "bgcolor[#00000000;false]"
	.. string.format("box[0,0;%d,0.7;%s]", size.x, def.bar_color or "#000000ff")
	.. string.format("hypertext[0,0;%d,0.7;title;<global valign=middle><b>%s — %s</b>]",
	size.x, game_title, minetest.formspec_escape(def.title))
end

function jma_greeter.load_file(filename)
	local filepath = worldpath .. "/" .. filename
	local file = io.open(filepath, "r")
	if file then
		local content = file:read("*a")
		file:close()
		return content
	end
end

function jma_greeter.write_file(filename, content)
	local file = io.open(worldpath .. "/" .. filename, "w")
	if file then
		file:write(content)
		file:close()
		minetest.log("action", "[jma_greeter]: written " .. filename)
		return true
	end
	return false
end

function jma_greeter.show_editor(pname, txt, title, actions)
	local ctx = {}
	for key, value in pairs(actions) do
		ctx[key] = value
	end
	jma_greeter.editor_context[pname] = ctx

	local fs = jma_greeter.get_base_formspec({
		title  = "Editor: " .. title,
		size = {x = 11, y = 11},
		bar_color = "#8547e8"
	})
	.. "box[0,0.7;11,9.1;black]"
	.. "textarea[0.1,0.8;10.8,8.9;text;;" .. minetest.formspec_escape(txt or "") .. "]"
	.. "button_exit[1.25,10;4,0.8;save;Save]"
	.. "button_exit[5.75,10;4,0.8;cancel;Cancel]"

	minetest.show_formspec(pname, "jma_greeter:rules_editor", fs)
end

minetest.register_on_player_receive_fields(function(player, form, fields)
	if form ~= "jma_greeter:rules_editor" then return end

	local pname = player:get_player_name()
	local new_txt = fields.text
	local ctx = jma_greeter.editor_context[pname]
	if not ctx then return true end

	if fields.save and new_txt then
		ctx.on_save(fields)
	elseif fields.cancel then
		if ctx.on_cancel then
			ctx.on_cancel(fields)
		else
			jma_greeter.editor_context[pname] = nil
		end
	end

	return true
end)

minetest.register_on_leaveplayer(function(player)
	local pname = player:get_player_name()
	if jma_greeter.editor_context[pname] then
		jma_greeter.editor_context[pname] = nil
	end
end)

dofile(minetest.get_modpath("jma_greeter") .. "/rules.lua")
dofile(minetest.get_modpath("jma_greeter") .. "/news.lua")

jma_greeter.events = {
	new_player_rules = function(player)
		local pname = player:get_player_name()
		local msg = "——————————————————————————————————————————————————————————————\n"
		.. "Welcome! To start playing, please familiarize yourself with the server rules.\n"
		.. "If you don't see the rules window, enter the \"/rules\" command to the chat.\n"
		.. "——————————————————————————————————————————————————————————————"
		minetest.chat_send_player(pname, minetest.colorize("#2af7b6", msg))

		if jma_greeter.rules_mode == "grant_privs" then
			local privs = minetest.get_player_privs(pname)
			privs.shout = nil
			privs.interact = nil
			minetest.set_player_privs(pname, privs)
		end

		jma_greeter.show_rules(player)
	end,

	news = function(player)
		jma_greeter.show_news(player:get_player_name())
	end
}

function jma_greeter.add_queue(player, queue_list)
	local pname = player:get_player_name()

	local events = jma_greeter.players_greeting_events[pname] or {}
	for _, name_or_func in ipairs(queue_list) do
		local event
		if type(name_or_func) == "function" then
			event = name_or_func
		else
			event = jma_greeter.events[name_or_func]
		end
		table.insert(events, event)
	end

	jma_greeter.players_greeting_events[pname] = events
end

function jma_greeter.queue_next(player)
	local pname = player:get_player_name()
	local events = jma_greeter.players_greeting_events[pname]
	if not events then return end
	if events[1] then
		local func = events[1]
		table.remove(events, 1)
		func(player)
	end

	if #events == 0 then
		jma_greeter.players_greeting_events[pname] = nil
	end
end

minetest.register_on_joinplayer(function(player, last_login)
	local pname = player:get_player_name()
	minetest.after(0.5, function()
		if player:is_player() then
			if jma_greeter.need_to_accept(pname) or not last_login then
				-- If the player needs to accept rules, add the rules event first
				jma_greeter.add_queue(player, jma_greeter.events_on_newplayer)
			else
				-- Otherwise, just add the news event
				jma_greeter.add_queue(player, jma_greeter.events_on_join)
			end
			jma_greeter.queue_next(player)
		end
	end)
end)

minetest.register_on_leaveplayer(function(player)
	local pname = player:get_player_name()
	if jma_greeter.players_greeting_events[pname] then
		jma_greeter.players_greeting_events[pname] = nil
	end
end)