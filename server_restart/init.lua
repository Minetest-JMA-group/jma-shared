-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2024 Nanowolf4 (n4w@tutanota.com)

server_restart = {}
local ie = minetest.request_insecure_environment() or error("server_restart: Insecure environment required!")

local shell_command = minetest.settings:get("restart_command")
local disconnect_msg = "Server is restarting. Please reconnect in a couple seconds."

local do_restart = function()
	for _, p in ipairs(minetest.get_connected_players()) do
		minetest.disconnect_player(p:get_player_name(), disconnect_msg)
	end
	ie.os.execute(shell_command)
end

if not shell_command then
	minetest.log("warning", "server_restart: 'restart_command' parameter is not set in minetest.conf, using minetest.request_shutdown function")
	do_restart = function()
		minetest.request_shutdown(disconnect_msg, true)
	end
end

local formspec = "formspec_version[7]"
	.. "size[12,3]"
	.. "no_prepend[]"
	.. "hypertext[0,0;12,3;hypertext;<global valign=middle><center><b>%s</b>\n%s</center>]"

function server_restart.request_restart(playername, time, update)
    local requestedby_msg = "Restart requested by " .. playername
    minetest.log("warning", "server_restart: " .. requestedby_msg)
	minetest.after(time, function()
		local msg = "The server will be restarted, and it should only take a moment. Please reconnect afterward."
		minetest.chat_send_all(minetest.colorize("red", "# " .. msg .. "\n" .. requestedby_msg))
		for _, p in ipairs(minetest.get_connected_players()) do
			minetest.show_formspec(p:get_player_name(), "server_restart", string.format(formspec, msg, requestedby_msg))
		end
		minetest.after(4, do_restart)
	end)
end

minetest.register_chatcommand("restart", {
	params = "<time>",
	description = "Request a server restart",
	privs = {dev = true},
	func = function(name, param)
		local time = tonumber(param) or 0
		server_restart.request_restart(name, time)
		return true, "Ok"
	end
})

if not minetest.global_exists("ctf_modebase") then
	return
end

local requested_by

minetest.register_chatcommand("qrestart", {
	params = "",
	description = "Request a server restart after the match",
	privs = {dev = true},
	func = function(name, param)
		requested_by = name
		ctf_modebase.restart_on_next_match = true
		return true, "Ok. The server will be restarted after the match."
	end
})

minetest.register_chatcommand("qcancel", {
	description = "Cancel scheduled server restart",
	privs = {dev = true},
	func = function()
		if ctf_modebase.restart_on_next_match then
			requested_by = nil
			ctf_modebase.restart_on_next_match = false
			return true, "Cancelled."
		end
		return false, "Nothing to cancel"
	end
})

ctf_api.register_on_match_end(function()
	if ctf_modebase.restart_on_next_match then
		server_restart.request_restart(requested_by, 0)
	end
end)