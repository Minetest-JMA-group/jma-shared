local news_text = ""
local showed = {}
local filename = "news.txt"
local storage = minetest.get_mod_storage()

-- CTF related stuff
if minetest.global_exists("ctf_settings") then
	ctf_settings.register("jma_greeter:news_disable", {
		type = "bool",
		label = "Disable news window",
		description = "Disables the news window when you join the game",
		default = "false",
	})
end

minetest.register_on_mods_loaded(function()
 	local content = jma_greeter.load_file(filename)
	if content then
		news_text = minetest.formspec_escape(content)
		minetest.log("action", "[jma_greeter]: news: " .. filename ..  " loaded")
	end
end)

function jma_greeter.show_news(pname, force)
	local is_news_disabled
	if minetest.global_exists("ctf_settings") then
		is_news_disabled = ctf_settings.get(minetest.get_player_by_name(pname), "jma_greeter:news_disable")
	else
		is_news_disabled = tostring(storage:get_int(pname .. ":news_disable") == 1)
	end
	if (is_news_disabled == "true" or showed[pname]) and not force then
		jma_greeter.queue_next(minetest.get_player_by_name(pname))
		return
	end

	local fs = jma_greeter.get_base_formspec({
		title  = "Server News",
		size = {x = 11, y = 11},
		bar_color = "#2d42fc",
	})
	.. "box[0,0.7;14,9.1;#00000055]"
	.. "hypertext[0.1,0.8;13.8,8.9;rules;" .. minetest.formspec_escape(news_text) .. "]"
	.. "button_exit[3.75,10;3.5,0.8;;Okay]"
	.. "checkbox[6,0.35;disable_news;Don't show me this again;" .. is_news_disabled .. "]"
	minetest.show_formspec(pname, "jma_greeter:news", fs)
end

minetest.register_on_player_receive_fields(function(player, form, fields)
	if form ~= "jma_greeter:news" then return end

	local pname = player:get_player_name()

	if fields.disable_news then
		if minetest.global_exists("ctf_settings") then
			ctf_settings.set(player, "jma_greeter:news_disable", fields.disable_news)
		else
			storage:set_int(pname .. ":news_disable", fields.disable_news == "true" and 1 or 0)
		end
		if fields.disable_news == "true" then
			minetest.chat_send_player(pname, "The news window will no longer be displayed. Use /news to check the news in the future.")
		end
	end

	jma_greeter.queue_next(player)
	return true
end)

minetest.register_chatcommand("news", {
	description = "Shows server news",
	func = function(name)
		jma_greeter.show_news(name, true)
		return true, "News shown."
	end
})

minetest.register_chatcommand("news_editor", {
	description = "Server rules editor",
	privs = {server = true},
	func = function(pname)
		local actions = {
			on_save = function(fields)
				if fields.text and jma_greeter.write_file(filename, fields.text) then
					news_text = fields.text
					minetest.chat_send_player(pname, "News saved.")
				else
					minetest.chat_send_player(pname, "Failed to save")
				end
			end,
			on_cancel = function()
				minetest.chat_send_player(pname, "Cancelled")
				jma_greeter.editor_context[pname] = nil
			end
		}
		jma_greeter.show_editor(pname, jma_greeter.load_file(filename) or "", "News", actions)
		return true, "News editor shown"
	end
})
