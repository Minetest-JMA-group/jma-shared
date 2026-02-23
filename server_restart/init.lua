-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2024 Nanowolf4 (n4w@tutanota.com)

server_restart = {}
local ie = core.request_insecure_environment()
if not ie then
	core.log("action", "[server_restart]: Insecure environment is not available, server restart will not work.")
	return
end

local shell_command = core.settings:get("restart_command")
local update_command = core.settings:get("update_command")
local disconnect_msg = "Server is restarting. Please reconnect in a couple seconds."

local do_restart = function()
	for _, p in ipairs(core.get_connected_players()) do
		core.disconnect_player(p:get_player_name(), disconnect_msg, true)
	end
	ie.os.execute(shell_command)
end


if not shell_command then
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
    core.log("action", "[server_restart]: " .. requestedby_msg)

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

core.register_chatcommand("update", {
	description = "Run the server update service without restarting",
	privs = { dev = true },
	func = function(name, param)
		if not update_command then
			return false, "Update command is not set. Not doing anything."
		end
		ie.os.execute(update_command)
	end
})

local restart_max_players
local requested_by

if not core.global_exists("ctf_modebase") then
	core.register_chatcommand("qrestart", {
		params = "[players]",
		description = "Request a server restart",
		privs = {dev = true},
		func = function(name, param)
			requested_by = name

			local players = tonumber(param)
			if players then
				restart_max_players = players
			end

			if not players then
				return false, "Please provide a player count"
			else
				core.log("[server_restart]: Restart queued by "..name.." when there are <="..players.." players online")
				return true, "Ok. The server will be restarted when there are <="..players.." players online."
			end
		end
	})

	core.register_chatcommand("qcancel", {
		description = "Cancel scheduled server restart",
		privs = {dev = true},
		func = function(name)
			if restart_max_players then
				restart_max_players = nil
				core.log("[server_restart]: Restart cancelled by "..name)
				return true, "Cancelled."
			end
			return false, "Nothing to cancel"
		end
	})

	core.register_on_leaveplayer(function(ObjectRef, timed_out)
		if restart_max_players then
			local players = core.get_connected_players()
			if restart_max_players >= #players then
				server_restart.request_restart(requested_by, 3)
			end
		end
	end)

	return
end

core.register_chatcommand("qrestart", {
	params = "[players]",
	description = "Request a server restart after the match",
	privs = {dev = true},
	func = function(name, param)
		requested_by = name
		ctf_modebase.restart_on_next_match = true

		local players = tonumber(param)
		if players then
			restart_max_players = players
			ctf_modebase.restart_on_next_match = false
		end

		if not players then
			core.log("[server_restart]: Restart queued by "..name.." after match end")
			return true, "Ok. The server will be restarted after the match."
		else
			core.log("[server_restart]: Restart queued by "..name.." when there are <="..players.." players online")
			return true, "Ok. The server will be restarted when there are <="..players.." players online."
		end
	end
})

core.register_chatcommand("qcancel", {
	description = "Cancel scheduled server restart",
	privs = {dev = true},
	func = function(name)
		if ctf_modebase.restart_on_next_match then
			requested_by = nil
			ctf_modebase.restart_on_next_match = false
			restart_max_players = nil
			core.log("[server_restart]: Restart cancelled by "..name)
			return true, "Cancelled."
		end
		return false, "Nothing to cancel"
	end
})

ctf_api.register_on_match_end(function()
	if ctf_modebase.restart_on_next_match then
		server_restart.request_restart(requested_by, 3)
	end

	if restart_max_players then
		local players = core.get_connected_players()
		if restart_max_players >= #players then
			server_restart.request_restart(requested_by, 3)
		else
			core.log("[server_restart]: Not restarting yet")
		end
	end
end)

core.register_on_leaveplayer(function(ObjectRef, timed_out)
	if restart_max_players then
		local players = core.get_connected_players()
		if restart_max_players <= 0 and #players <= 0 then
			server_restart.request_restart(requested_by, 3)
		end
	end
end)