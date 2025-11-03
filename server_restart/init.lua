-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2024 Nanowolf4 (n4w@tutanota.com)

server_restart = {}
local ie = core.request_insecure_environment() or error("server_restart: Insecure environment required!")

local shell_command = core.settings:get("restart_command")
local disconnect_msg = "Server is restarting. Please reconnect in a couple seconds."

local do_restart = function()
	for _, p in ipairs(core.get_connected_players()) do
		core.disconnect_player(p:get_player_name(), disconnect_msg, true)
	end
	ie.os.execute(shell_command)
end

if not shell_command then
	core.log("warning", "server_restart: 'restart_command' parameter is not set in core.conf, using core.request_shutdown function")
	do_restart = function()
		core.request_shutdown(disconnect_msg, true)
	end
end

local formspec = "formspec_version[7]"
	.. "size[12,3]"
	.. "no_prepend[]"
	.. "hypertext[0,0;12,3;hypertext;<global valign=middle><center><b>%s</b>\n%s</center>]"

function server_restart.request_restart(playername, time, update)
    local requestedby_msg = "Restart requested by " .. playername
    core.log("warning", "server_restart: " .. requestedby_msg)

	if time == 0 then
		do_restart()
		return
	end

	core.after(time, function()
		local msg = "The server will be restarted, and it should only take a moment. Please reconnect afterward."
		core.chat_send_all(core.colorize("red", "- " .. msg .. "\n" .. requestedby_msg))
		for _, p in ipairs(core.get_connected_players()) do
			core.show_formspec(p:get_player_name(), "server_restart", string.format(formspec, msg, requestedby_msg))
		end
		core.after(8, do_restart)
	end)
end

core.register_chatcommand("restart", {
	params = "<time>",
	description = "Request a server restart",
	privs = {dev = true},
	func = function(name, param)
		local time = tonumber(param) or 0
		server_restart.request_restart(name, time)
		return true, "Ok"
	end
})

if not core.global_exists("ctf_modebase") then
	return
end

local requested_by

core.register_chatcommand("qrestart", {
	params = "",
	description = "Request a server restart after the match",
	privs = {dev = true},
	func = function(name, param)
		requested_by = name
		ctf_modebase.restart_on_next_match = true
		return true, "Ok. The server will be restarted after the match."
	end
})

core.register_chatcommand("qcancel", {
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
		server_restart.request_restart(requested_by, 3)
	end
end)