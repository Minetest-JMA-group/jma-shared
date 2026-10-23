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
local arena = dofile(modpath .. "/arena.lua")
local reconstruct = dofile(modpath .. "/reconstruct.lua")
local sessions = dofile(modpath .. "/sessions.lua")

recovery.init(controls, arena)
sessions.init({
	sqlite = sqlite,
	reader = reader,
	ghost = ghost,
	recovery = recovery,
	arena = arena,
	reconstruct = reconstruct,
})
-- The storage object has to be taken while the mod loads; the arena keeps it
-- so a session can say where it is before touching the world.
arena.init({
	storage = core.get_mod_storage(),
	running = function()
		local boxes = {}
		for _, session in ipairs(sessions.list()) do
			if session.arena then boxes[#boxes + 1] = session.arena end
		end
		return boxes
	end,
})

-- Arenas of a previous run are still in a persistent world. The first server
-- step is the earliest moment the map can be written; the recorder starts its
-- first step the same way.
core.after(0, arena.recover)

-- The session registry and its lifecycle are part of the API: the game (or a
-- test) may want to see what is running or end a session it knows about.
recorder_replay.sessions = sessions
-- The arena module is here for the same reason: a game or a test can ask what
-- arena would be chosen, or mark one on a player's behalf.
recorder_replay.arena = arena
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

-- The recording chooser, per player: the file list the formspec was built from
-- and the index selected in it. Keeping the list here means a submission can
-- only name a recording the server actually offered, and adds no path of its
-- own. `deleting` holds the recording a confirmation is open for.
local choosing = {}
local deleting = {}

-- Deleting a recording touches the server's files, so it needs the privilege
-- that owns them, not just the one for watching them.
local function can_delete_recordings(name)
	return core.check_player_privs(name, {server = true})
end

local function recording_in_use(path)
	for _, session in ipairs(sessions.list()) do
		if session.path == path then
			return "it is being watched; leave the replay first"
		end
	end
	-- Capture may not be loaded on every server; when it is, it knows which
	-- files are still being written.
	if type(recorder) == "table" and recorder.list then
		for _, entry in ipairs(recorder.list()) do
			if entry.path == path then
				return "it is still being recorded; stop the recording first"
			end
		end
	end
	return nil
end

local function delete_recording_files(path)
	local removed, err = os.remove(path)
	if not removed and recorder_common.file_exists(path) then
		return nil, tostring(err)
	end
	-- The write-ahead sidecars belong to the recording; a stale one would only
	-- be litter next to a file that no longer exists.
	for _, suffix in ipairs({"-wal", "-shm"}) do
		os.remove(path .. suffix)
	end
	return true
end

-- A formspec shown from inside an input callback - a chat command, an item use
-- - can be delivered the very keypress or click that triggered it, and the
-- client then treats that as a click on the new form. That is how a bare
-- /replay used to go straight through the list and start the first recording.
-- Showing the form a moment later lets the input finish first.
local function show_formspec_later(name, formname, build)
	core.after(0.2, function()
		if not core.get_player_by_name(name) then return end
		local formspec = build()
		if formspec then core.show_formspec(name, formname, formspec) end
	end)
end

local function show_recording_chooser(name, choice, error)
	show_formspec_later(name, "recorder_replay:recordings", function()
		if choosing[name] ~= choice then return nil end
		return controls.recordings_formspec(choice.files, choice.selected, error,
			can_delete_recordings(name))
	end)
end

-- The remote control's actions. Looked up by the player's session, so one item
-- type drives whichever replay its holder is watching.
controls.register(function(kind, player, extra)
	local name = player:get_player_name()
	if kind == "recording_choice" then
		local choice = choosing[name]
		if not choice then return end
		local start_now = false
		if extra and extra.recordings then
			local event = core.explode_textlist_event(extra.recordings)
			if (event.type == "CHG" or event.type == "DCL") and choice.files[event.index] then
				choice.selected = event.index
				start_now = event.type == "DCL"
			end
		elseif extra and extra.watch then
			if not choice.selected then
				show_recording_chooser(name, choice, "Choose a recording first.")
				return
			end
			start_now = true
		elseif extra and extra.delete then
			if not choice.selected then
				show_recording_chooser(name, choice, "Choose a recording first.")
				return
			end
			if not can_delete_recordings(name) then
				show_recording_chooser(name, choice, "You do not have the server privilege.")
				return
			end
			local chosen = choice.files[choice.selected]
			if not chosen then return end
			deleting[name] = {
				choice = choice,
				entry = chosen,
				path = chosen.path,
				name = chosen.name,
			}
			-- The destructive button is the first one on the confirmation, so
			-- the form is shown only after this click has been handled.
			show_formspec_later(name, "recorder_replay:delete", function()
				local current = deleting[name]
				if not current or choosing[name] ~= current.choice then return nil end
				return controls.delete_formspec(chosen.name)
			end)
			return
		elseif extra and extra.key_enter then
			-- The Enter that submitted the command that opened the form can
			-- reach the form too; it is not a click.
			if not choice.selected then show_recording_chooser(name, choice) end
			return
		elseif extra and (extra.quit or extra.cancel) then
			choosing[name] = nil
			deleting[name] = nil
			return
		end
		if not start_now then return end
		local chosen = choice.files[choice.selected]
		if not chosen then return end
		local started, err = sessions.start(chosen.path, player)
		if not started then
			-- The recording or the arena could not be used; keep the list open
			-- with the reason in it so another one can be picked.
			show_recording_chooser(name, choice,
				"Cannot watch " .. chosen.name .. ": " .. tostring(err))
			return
		end
		choosing[name] = nil
		deleting[name] = nil
		core.close_formspec(name, "recorder_replay:recordings")
		return
	end

	if kind == "delete_confirm" then
		local pending = deleting[name]
		if not pending then return end
		if extra and extra.confirm then
			if not can_delete_recordings(name) then
				deleting[name] = nil
				core.close_formspec(name, "recorder_replay:delete")
				return
			end
			local reason = recording_in_use(pending.path)
			if not reason then
				local ok, err = delete_recording_files(pending.path)
				if not ok then reason = tostring(err) end
			end
			deleting[name] = nil
			if reason then
				if choosing[name] == pending.choice then
					show_recording_chooser(name, pending.choice,
						"Cannot delete " .. pending.name .. ": " .. tostring(reason))
				end
				return
			end
			local choice = pending.choice
			if choosing[name] == choice then
				for i, entry in ipairs(choice.files) do
					if entry == pending.entry then
						table.remove(choice.files, i)
						break
					end
				end
				choice.selected = nil
			end
			core.chat_send_player(name, "Deleted " .. pending.name .. ".")
			if choosing[name] == choice then
				if #choice.files == 0 then
					choosing[name] = nil
					core.close_formspec(name, "recorder_replay:recordings")
				else
					show_recording_chooser(name, choice)
				end
			end
			return
		end
		if extra and (extra.cancel or extra.quit) then
			deleting[name] = nil
			if choosing[name] == pending.choice then
				show_recording_chooser(name, pending.choice)
			end
			return
		end
		return
	end

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
		show_formspec_later(name, "recorder_replay:seek", function()
			return controls.seek_formspec(session)
		end)
	elseif kind == "light_toggle" then
		local mode = sessions.toggle_light(session)
		if not mode then
			core.chat_send_player(name, "This recording has no recorded lighting or time of day.")
		else
			for participant in pairs(session.participants) do
				local other = core.get_player_by_name(participant)
				if other then controls.set_light_item(other, mode) end
			end
		end
		return mode
	elseif kind == "leave" then
		-- The engine writes the used stack back into its slot after this
		-- callback returns, and leaving restores the player's own inventory.
		-- The restore therefore has to run after that write, or the control
		-- item lands in the restored list.
		core.after(0, function()
			local still_here = core.get_player_by_name(name)
			if still_here then
				sessions.leave(session, still_here)
			end
		end)
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
	choosing[player:get_player_name()] = nil
	deleting[player:get_player_name()] = nil
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

-- Every recording file in the directory, newest first. The UTC timestamp in
-- the name is fixed width, so descending name order is chronological order.
---@return table[], string  -- {name =, path =} newest first, and the directory
local function all_recordings()
	local dir = recorder_common.recordings_dir()
	local names = core.get_dir_list(dir, false) or {}
	table.sort(names, function(a, b) return a > b end)
	local out = {}
	for _, file in ipairs(names) do
		if file:sub(-7) == ".sqlite" then
			out[#out + 1] = {name = file, path = dir .. "/" .. file}
		end
	end
	return out, dir
end

local function list_recordings()
	local files, dir = all_recordings()
	local out = {}
	for i = 1, math.min(#files, 15) do out[i] = files[i].name end
	return out, dir
end

-- Recordings still being written are not offered for watching by default: a
-- recording is something to watch when it is finished, and one that is still
-- taking its snapshot has no snapshot row to rebuild from yet. Capture knows
-- which files those are; when it is not loaded there is nothing to ask, and
-- the file list is what it is. `replay.allow_unfinished` restores the older
-- behaviour and offers them too.
---@return table[], string
local function available_recordings()
	local files, dir = all_recordings()
	if core.settings:get_bool("replay.allow_unfinished") then return files, dir end
	if type(recorder) ~= "table" or not recorder.list then return files, dir end
	local active = {}
	for _, entry in ipairs(recorder.list()) do
		if entry.path then active[entry.path] = true end
	end
	local out = {}
	for _, entry in ipairs(files) do
		if not active[entry.path] then out[#out + 1] = entry end
	end
	return out, dir
end

core.register_chatcommand("replay", {
	description = "Play a recording back",
	params = "[list | join [id] | leave | end <id> | status | pos1 | pos2 | unset]",
	privs = {replay = true},
	---@param name string
	---@param params string
	func = function(name, params)
		local command, rest = params:match("^(%S+)%s*(.-)%s*$")
		local player = core.get_player_by_name(name)
		if not player then return false, "no player" end

		if command == nil or command == "" then
			-- Choosing a recording happens here, before the formspec, so that a
			-- player with nowhere to build is told what to do instead of being
			-- shown a list that cannot start anything.
			if sessions.for_player(name) then
				return false, "you are already watching a replay; /replay leave first"
			end
			local available, availability_err = arena.available(name)
			if not available then
				return false, availability_err or
					"there is no arena for this replay: mark one with /replay pos1 and /replay pos2," ..
					" ask the game to provide one, or set replay.arena"
			end
			local files, dir = available_recordings()
			if #files == 0 then
				return false, "no recordings in " .. dir
			end
			choosing[name] = {files = files, selected = nil}
			deleting[name] = nil
			show_recording_chooser(name, choosing[name])
			return true
		end

		if command == "list" then
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

		if command == "pos1" or command == "pos2" then
			local pos = player:get_pos()
			local marked, err = arena.set_mark(name, command, pos)
			if not marked then return false, err end
			if arena.has_marks(name) then
				return true, "Arena corner marked. Start a replay to build it here, or /replay unset to drop it."
			end
			return true, string.format("Arena %s marked at %s; mark the other corner with /replay %s.",
				command, core.pos_to_string(pos), command == "pos1" and "pos2" or "pos1")
		end

		if command == "unset" then
			arena.clear_marks(name)
			return true, "Arena marks cleared."
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
				return false, "no replay is running; start one with /replay"
			end
			if #active == 1 then
				local joined, err = sessions.join(active[1], player)
				if not joined then return false, err end
				return true, "Watching " .. active[1].name
			end
			show_formspec_later(name, "recorder_replay:sessions", function()
				return controls.sessions_formspec(active)
			end)
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

		return false, "Usage: /replay [list | join [id] | leave | end <id> | status |" ..
			" pos1 | pos2 | unset]"
	end,
})
