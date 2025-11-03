jma_greeter = {
	is_checking_persistent_forms = false,
	players_greeting_events = {},
	editor_context = {},
	events_on_newplayer = {"tos", "new_player_rules", "news"},
	events_on_join = {"news"},
	rules_mode = core.settings:get("jma_greeter_rules_mode") or "grant_privs"
	-- Modes:
	-- "grant_privs" - Grant privileges after accepting rules
	-- "no_priv_change" - Do not modify privileges, just allow the player to play
}

local worldpath = core.get_worldpath()

local game_title
do
	local game = core.get_game_info()
	game_title = game.title ~= "" and game.title or "JMA"
end

function jma_greeter.get_base_formspec(def)
	local size = def.size
	local title = def.title_override or string.format("%s — %s", game_title, def.title)
	return "formspec_version[7]"
	.. string.format("size[%d,%d]", size.x, size.y)
	.. "bgcolor[#00000000;false]"
	.. string.format("box[0,0;%d,0.7;%s]", size.x, def.bar_color or "#000000ff")
	.. string.format("hypertext[0,0;%d,0.7;title;<global valign=middle><b>%s</b>]",
	size.x, core.formspec_escape(title))
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
		core.log("action", "[jma_greeter]: written " .. filename)
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
	.. "textarea[0.1,0.8;10.8,8.9;text;;" .. core.formspec_escape(txt or "") .. "]"
	.. "button_exit[1.25,10;4,0.8;save;Save]"
	.. "button_exit[5.75,10;4,0.8;cancel;Cancel]"

	core.show_formspec(pname, "jma_greeter:rules_editor", fs)
end

core.register_on_player_receive_fields(function(player, form, fields)
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

core.register_on_leaveplayer(function(player)
	local pname = player:get_player_name()
	if jma_greeter.editor_context[pname] then
		jma_greeter.editor_context[pname] = nil
	end
end)

dofile(core.get_modpath("jma_greeter") .. "/rules.lua")
dofile(core.get_modpath("jma_greeter") .. "/news.lua")
dofile(core.get_modpath("jma_greeter") .. "/faq.lua")
dofile(core.get_modpath("jma_greeter") .. "/tos.lua")

jma_greeter.events = {
	tos = {
		func = function(player)
			jma_greeter.show_tos(player)
		end,
		on_reshow = function(player)
			jma_greeter.show_tos(player)
		end,
		unskippable = true,
	},

	new_player_rules = {
		func = function(player)
			local pname = player:get_player_name()
			local msg = "——————————————————————————————————————————————————————————————\n"
			.. "Welcome! To start playing, please familiarize yourself with the server rules.\n"
			.. "If you don't see the rules window, enter the \"/rules\" command to the chat.\n"
			.. "——————————————————————————————————————————————————————————————"
			core.chat_send_player(pname, core.colorize("#2af7b6", msg))

			if jma_greeter.rules_mode == "grant_privs" then
				local privs = core.get_player_privs(pname)
				privs.shout = nil
				privs.interact = nil
				core.set_player_privs(pname, privs)
			end
			jma_greeter.show_rules(player)
		end,
		on_reshow = function(player)
			jma_greeter.show_rules(player)
		end,
		unskippable = true,
	},

	news = {
		func = function(player)
			jma_greeter.show_news(player:get_player_name())
		end,
	}
}

function jma_greeter.add_queue(player, queue_list)
	local pname = player:get_player_name()

	local events = jma_greeter.players_greeting_events[pname] or {}
	for _, name_or_func in ipairs(queue_list) do
		local event_obj
		if type(name_or_func) == "function" then
			event_obj = {func = name_or_func}
		else
			event_obj = jma_greeter.events[name_or_func]
		end
		if event_obj then
			table.insert(events, event_obj)
		end
	end

	jma_greeter.players_greeting_events[pname] = events
end

function jma_greeter.queue_next(player)
	local pname = player:get_player_name()
	local events = jma_greeter.players_greeting_events[pname]
	if not events then return end

	-- Remove the completed event
	table.remove(events, 1)

	-- If there's a next event, run it
	if events[1] then
		events[1].func(player)
	end

	if #events == 0 then
		jma_greeter.players_greeting_events[pname] = nil
	end
end

core.register_on_joinplayer(function(player, last_login)
	local pname = player:get_player_name()
	core.after(0.5, function()
		if not player:is_player() then
			return
		end

		local queue = {}
		if not jma_greeter.has_accepted_tos(player) then
			table.insert(queue, "tos")
		end

		if not jma_greeter.has_accepted_rules(pname) then
			if last_login and core.check_player_privs(pname, {interact = true, shout = true}) then
				player:get_meta():set_int("jma_greeter_rules_accepted", 1)
			else
				table.insert(queue, "new_player_rules")
			end
		end

		table.insert(queue, "news")

		jma_greeter.add_queue(player, queue)

		-- Start the first event
		local events = jma_greeter.players_greeting_events[pname]
		if events and events[1] then
			events[1].func(player)
			jma_greeter.start_persistent_check_if_needed()
		end
	end)
end)

core.register_on_leaveplayer(function(player)
	local pname = player:get_player_name()
	if jma_greeter.players_greeting_events[pname] then
		jma_greeter.players_greeting_events[pname] = nil
	end
end)

function jma_greeter.check_persistent_forms()
	local has_unskippable_events = false
	for pname, events in pairs(jma_greeter.players_greeting_events) do
		local player = core.get_player_by_name(pname)
		if player and events and events[1] and events[1].unskippable then
			has_unskippable_events = true
			local event_to_show = events[1]
			if event_to_show.on_reshow then
				event_to_show.on_reshow(player)
			else
				event_to_show.func(player)
			end
		end
	end

	if has_unskippable_events then
		core.after(3, jma_greeter.check_persistent_forms)
	else
		jma_greeter.is_checking_persistent_forms = false
	end
end

function jma_greeter.start_persistent_check_if_needed()
	if jma_greeter.is_checking_persistent_forms then
		return
	end
	jma_greeter.is_checking_persistent_forms = true
	jma_greeter.check_persistent_forms()
end
