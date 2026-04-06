--    modified by Fhelron <fhelron@danielschlep.de>

--    Copyright (C) 2026 fancyfinn9 <fancyfinn9@proton.me>
--
--    This program is free software: you can redistribute it and/or modify
--    it under the terms of the GNU Affero General Public License as published
--    by the Free Software Foundation, either version 3 of the License, or
--    (at your option) any later version.
--
--    This program is distributed in the hope that it will be useful,
--    but WITHOUT ANY WARRANTY; without even the implied warranty of
--    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--    GNU Affero General Public License for more details.
--
--    You should have received a copy of the GNU Affero General Public License
--    along with this program.  If not, see <https://www.gnu.org/licenses/>.

local storage = core.get_mod_storage()

local joined = {}

local last_notified = {}

local notify_interval = 60*60 -- 1 hour

local player_data = {}

local default_bantime_index = 1

local bantime_display_table = {"30min", "1h", "1d", "10d", "30d"}
local bantime_value_table = {
	["30min"] = 1800,
	["1h"] = 3600,
	["1d"] = 86400,
	["10d"] = 864000,
	["30d"] = 2592000
}

break_reminder = {}

local function beautify_time(s)
	local h = math.floor(s / 3600)
	local m = math.floor((s % 3600) / 60)
	local sec = s % 60
	local parts = {}
	if h > 0 then table.insert(parts, h.."h") end
	if m > 0 then table.insert(parts, m.."m") end
	if sec > 0 or #parts == 0 then table.insert(parts, sec.."s") end
	return table.concat(parts, " ")
end

function break_reminder.show_reminder(playername)
	if storage:get_string(playername.."_pref") == "off" or not core.get_player_by_name(playername) then
		return
	end

	local time_str
    
	if joined[playername] then
		time_str = beautify_time(os.time()-joined[playername])
	else
		time_str = "a while"
	end

	local formspec =
	"formspec_version[6]"..
	"size[15,11]"..
	"hypertext[1,1;13,3;title;"..
		"<bigger><center>It's time to take a break</center></bigger>"..
	"]"..
	"image[5,2.5;5,5;break_reminder_sam_drinking.png]"..
	"hypertext[1,8.5;13,3;subtitle;"..
		"<big><center>You've been playing for "..time_str.."! Consider taking a break.</center></big>"..
	"]"..
	"button_exit[12.8,9.6;2,0.8;ban_menu;Ban Me]"..
	"button_exit[6,9.6;3,0.8;close;OK]"..
	"button_exit[0.2,9.6;2,0.8;kick_me;Kick me]"

	core.show_formspec(playername, "break_reminder:reminder", formspec)

	last_notified[playername] = os.time()
end

function break_reminder.show_ban_menu(playername)
	local data = player_data[playername]
	local selected_index = data and data.index or default_bantime_index

	local formspec =
		"formspec_version[6]"..
			"size[7,4.5]"..
			"hypertext[2.25,0.4;3,3;title;"..
				"<big>Timeout me</big>"..
			"]"..
			"label[2.4,1.4;3,3;Choose ban time:]"..
			"dropdown[2,2;3,0.8;BanTime;"..table.concat(bantime_display_table, ",") ..";"..selected_index.."]"..
			"button_exit[4.7,3.4;2,0.8;ban;Ban me]"..
			"button_exit[0.3,3.4;2,0.8;kick_me;Cancel]"

	core.show_formspec(playername, "break_reminder:ban_menu", formspec)
end

function break_reminder.show_confirm_menu(playername)
	local data = player_data[playername]
	if not data then
		core.chat_send_player(playername, "Invalid ban duration selection.")
		break_reminder.show_ban_menu(playername)
		return
	end

	local text = data.text

	local formspec =
		"formspec_version[6]"..
			"size[7,2.8]"..
			"hypertext[2.25,0.4;3,3;title;"..
				"<big>Are you sure?</big>"..
			"]"..
			"label[2.02,1.2;4,3;You will be banned for "..text.."]"..
			"button_exit[4.7,1.8;2,0.8;close;NO]"..
			"button_exit[0.3,1.8;2,0.8;confirm;YES]"

	core.show_formspec(playername, "break_reminder:confirm_menu", formspec)
end

core.register_on_player_receive_fields(function(player, formname, fields)
	local player_name = player:get_player_name()
	local selected_text = fields["BanTime"]

	if formname == "break_reminder:reminder" and fields.kick_me then
		core.kick_player(player_name, "You clicked 'Kick me' in the break reminder formspec.")
	elseif formname == "break_reminder:reminder" and fields.ban_menu then
		player_data[player_name] = nil
		break_reminder.show_ban_menu(player_name)
	elseif formname == "break_reminder:ban_menu" and fields.ban then
		local text = selected_text
		local index = table.indexof(bantime_display_table, text)
		if not text or not index or not bantime_value_table[text] then
			index = default_bantime_index
			text = bantime_display_table[index]
		end
		player_data[player_name] = {
			text = text,
			seconds = bantime_value_table[text],
			index = index
		}
		break_reminder.show_confirm_menu(player_name)
	elseif formname == "break_reminder:confirm_menu" and fields.confirm then
		local data = player_data[player_name]
		if not data then
			core.chat_send_player(player_name, "No ban duration selected.")
			break_reminder.show_ban_menu(player_name)
			return
		end
		simplemod.ban_name(player_name, "break_reminder", "You decided to take a break for " .. data.text, data.seconds)
		player_data[player_name] = nil
	end

end)

core.register_on_joinplayer(function(player)
	last_notified[player:get_player_name()] = os.time()
	joined[player:get_player_name()] = os.time()
end)

core.register_on_leaveplayer(function(player)
	local player_name = player:get_player_name()
	last_notified[player_name] = nil
	joined[player_name] = nil
	player_data[player_name] = nil
end)

core.register_chatcommand("break_reminder", {
	params = "<on|off>",
	description = "Toggle your break reminder",
	func = function(name, param)
		if param ~= "on" and param ~= "off" then
			return false, "Please provide a valid argument (on or off)"
		end

		storage:set_string(name.."_pref", param)

		return true, "Successfully set your break reminder to "..param
	end
})

core.register_chatcommand("show_reminder", {
	params = "<player>",
	description = "Show a break reminder to a player",
	privs = {
		server = true
	},
	func = function(name, param)
		local player = core.get_player_by_name(param)

		if param == "" then
			return false, "Please enter a player name."
		end

		if not player then
			return false, "Player " .. param .. " not found."
		end

		break_reminder.show_reminder(param)

		return true, "Successfully showed break reminder to ".. param
	end
})

core.register_chatcommand("timeout", {
	description = "Shows you the ban menu to take a break.",
	privs = {
		interact = true
	},
	func = function(name)
		local player_obj = core.get_player_by_name(name)

		if not player_obj then
			return false
		end

		break_reminder.show_ban_menu(name)
	end
})

local function check_playtime(name)
	local time = last_notified[name]
	if time then
		local currtime = os.time()
		if currtime - time > notify_interval then
			break_reminder.show_reminder(name)
		end
	end
end

if core.get_modpath("ctf_api") then -- We are running on a CTF server
	ctf_api.register_on_respawnplayer(function(player)
        check_playtime(player:get_player_name())
	end)

	ctf_api.register_on_new_match(function()
		for _, player in ipairs(core.get_connected_players()) do
			check_playtime(player:get_player_name())
		end
	end)
else
	local function check_all_playtimes()
		local currtime = os.time()

		for player, time in pairs(last_notified) do
			if currtime - time > notify_interval then
				break_reminder.show_reminder(player)
			end
		end

		core.after(60*2, check_all_playtimes)
	end

	check_all_playtimes()
end
