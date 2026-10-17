-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

-- recorder – play a recording back. A session reads one recording file, shows
-- its players as ghosts to the people watching, and gives them a remote control
-- for the clock. Anything the game has to know about - the arena, what happens
-- to a participant's inventory, whether the world persists - arrives through
-- recorder_common.game_hooks, so nothing here names a game.

recorder_replay = {}

-- The recording reader needs lsqlite3, the same library capture uses. Without
-- it there is nothing to play, and the command says so rather than being
-- unknown.
local sqlite = algorithms.require("lsqlite3")
if not sqlite then
	local message = "[replay] lsqlite3 needed for operation. Make sure that the library is" ..
		" installed and recorder_replay is added to secure.c_mods or secure.trusted_mods"
	core.log("error", message)
	local unavailable = "recorder_replay is unavailable: " .. message
	recorder_replay.unavailable = unavailable
	core.register_chatcommand("replay", {
		description = "Play a recording back",
		params = "",
		privs = {replay = true},
		func = function() return false, unavailable end,
	})
	return
end

local modpath = core.get_modpath(core.get_current_modname())
local reader = dofile(modpath .. "/reader.lua")
local ghost = dofile(modpath .. "/ghost.lua")
local controls = dofile(modpath .. "/controls.lua")
local recovery = dofile(modpath .. "/recovery.lua")
local sessions = dofile(modpath .. "/sessions.lua")

recovery.init(controls)
sessions.init({
	sqlite = sqlite,
	reader = reader,
	ghost = ghost,
	recovery = recovery,
})

-- The session registry and its lifecycle are part of the API: the game (or a
-- test) may want to see what is running or end a session it knows about.
recorder_replay.sessions = sessions
---@param id string|nil
---@param reason string?
function recorder_replay.end_session(id, reason)
	local session = sessions.find(id)
	if not session then return false end
	sessions.finish(session, reason or "api")
	return true
end

local SPEEDS = {1, 2, 4, 0.5}

local function next_speed(speed)
	for i, value in ipairs(SPEEDS) do
		if value == speed then return SPEEDS[i % #SPEEDS + 1] end
	end
	return 1
end

local function clock(seconds)
	seconds = math.max(0, math.floor(seconds + 0.5))
	return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- The remote control's actions. Looked up by the player's session, so one item
-- type drives whichever replay its holder is watching.
controls.register(function(kind, player, extra)
	local name = player:get_player_name()
	local session = sessions.for_player(name)
	if not session then
		core.chat_send_player(name, "You are not watching a replay.")
		return
	end
	if kind == "pause" then
		session.paused = not session.paused
		core.chat_send_player(name, session.paused and "Replay paused." or "Replay running.")
	elseif kind == "speed" then
		session.speed = next_speed(session.speed)
		core.chat_send_player(name, string.format("Replay speed %sx.", tostring(session.speed)))
	elseif kind == "back" then
		sessions.seek(session, session.T - 10)
	elseif kind == "forward" then
		sessions.seek(session, session.T + 10)
	elseif kind == "seek" then
		player:show_formspec("recorder_replay:seek", controls.seek_formspec(session))
	elseif kind == "leave" then
		sessions.leave(session, player)
	elseif kind == "seek_value" then
		local event = core.explode_scrollbar_event((extra and extra.seek) or "")
		if event.type == "CHG" then
			sessions.seek(session, event.value / 10)
		end
	elseif kind == "session_choice" then
		for field in pairs(extra or {}) do
			local id = field:match("^join_(%w+)$")
			if id then
				local chosen = sessions.find(id)
				if chosen then sessions.join(chosen, player) end
			end
		end
	end
end)

-- A player coming back after a disconnect: if the session they were watching is
-- still running they return to it, otherwise they get their things back.
core.register_on_joinplayer(function(player)
	local stash = recovery.pending(player)
	if not stash then return end
	local session = sessions.find(stash.session)
	recovery.clear(player)
	if session then
		local joined = sessions.join(session, player, true)
		if not joined then
			recovery.restore(player, stash)
		end
	else
		recovery.restore(player, stash)
	end
end)

core.register_on_leaveplayer(function(player)
	sessions.on_disconnect(player)
end)

core.register_globalstep(function(dtime)
	sessions.step_all(dtime)
end)

core.register_privilege("replay", {
	description = "Watch recorded replays",
	give_to_singleplayer = false,
})

local function describe(session)
	local watching = sessions.participant_count(session)
	return string.format("%s  %s  %s / %s  %s  %d watching",
		session.id, session.name, clock(session.T), clock(session.rec.duration),
		session.paused and "paused" or (tostring(session.speed) .. "x"), watching)
end

local function list_recordings()
	local dir = recorder_common.recordings_dir()
	local names = core.get_dir_list(dir, false) or {}
	table.sort(names, function(a, b) return a > b end)
	local out = {}
	for _, file in ipairs(names) do
		if file:sub(-7) == ".sqlite" then out[#out + 1] = file end
		if #out >= 15 then break end
	end
	return out, dir
end

core.register_chatcommand("replay", {
	description = "Play a recording back",
	params = "[list | start <recording> | join [id] | leave | end <id> | status]",
	privs = {replay = true},
	---@param name string
	---@param params string
	func = function(name, params)
		local command, rest = params:match("^(%S+)%s*(.-)%s*$")
		local player = core.get_player_by_name(name)
		if not player then return false, "no player" end

		if command == nil or command == "" or command == "list" then
			local lines = {"Active replays:"}
			local active = sessions.list()
			if #active == 0 then lines[#lines + 1] = "  (none)" end
			for _, session in ipairs(active) do
				lines[#lines + 1] = "  " .. describe(session)
			end
			local recordings, dir = list_recordings()
			lines[#lines + 1] = "Recordings in " .. dir .. ":"
			if #recordings == 0 then lines[#lines + 1] = "  (none)" end
			for _, file in ipairs(recordings) do
				lines[#lines + 1] = "  " .. file
			end
			for _, line in ipairs(lines) do
				core.chat_send_player(name, line)
			end
			return true
		end

		if command == "start" then
			local session, err = sessions.start(rest, player)
			if not session then return false, err end
			return true, string.format("Watching %s (%s), %s long. Controls are in your hotbar.",
				session.name, session.id, clock(session.rec.duration))
		end

		if command == "join" then
			if sessions.for_player(name) then
				return false, "you are already watching a replay; /replay leave first"
			end
			if rest ~= "" then
				local chosen = sessions.find(rest)
				if not chosen then
					for _, session in ipairs(sessions.list()) do
						if session.id:sub(1, #rest) == rest then
							chosen = session
							break
						end
					end
				end
				if not chosen then return false, "no replay " .. rest end
				local joined, err = sessions.join(chosen, player)
				if not joined then return false, err end
				return true, "Watching " .. chosen.name
			end
			local active = sessions.list()
			if #active == 0 then
				return false, "no replay is running; start one with /replay start <recording>"
			end
			if #active == 1 then
				local joined, err = sessions.join(active[1], player)
				if not joined then return false, err end
				return true, "Watching " .. active[1].name
			end
			player:show_formspec("recorder_replay:sessions", controls.sessions_formspec(active))
			return true
		end

		if command == "leave" then
			local session = sessions.for_player(name)
			if not session then return false, "you are not watching a replay" end
			sessions.leave(session, player)
			return true, "Left the replay."
		end

		if command == "end" then
			local chosen = sessions.find(rest)
			if not chosen then return false, "no replay " .. rest end
			sessions.finish(chosen, "ended by " .. name)
			return true, "Replay ended."
		end

		if command == "status" then
			local session = sessions.for_player(name)
			if not session then return true, "Not watching a replay." end
			return true, string.format("%s (%s): %s / %s, %s, %sx",
				session.name, session.id, clock(session.T), clock(session.rec.duration),
				session.paused and "paused" or "playing", tostring(session.speed))
		end

		return false, "Usage: /replay [list | start <recording> | join [id] | leave | end <id> | status]"
	end,
})
