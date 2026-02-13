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
    "button_exit[6,9.6;3,0.8;close;OK]"

    core.show_formspec(playername, "break_reminder:reminder", formspec)

    last_notified[playername] = os.time()
end

core.register_on_joinplayer(function(player, last_login)
    last_notified[player:get_player_name()] = os.time()
    joined[player:get_player_name()] = os.time()
end)

core.register_on_leaveplayer(function(player, timed_out)
    last_notified[player:get_player_name()] = nil
    joined[player:get_player_name()] = nil
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
    params = "player",
    description = "Show a break reminder to a player",
    privs = {
        server = true
    },
    func = function(name, param)
        local player = core.get_player_by_name(name)
        if not player then
            return false, "Player "..name.." not found"
        end

        break_reminder.show_reminder(name)

        return true, "Successfully showed break reminder to "..name
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