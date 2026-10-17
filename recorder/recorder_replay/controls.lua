-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

-- The remote control: one item per action, put in the main list so they show in
-- the hotbar while watching. Actions are separate items rather than a formspec
-- so a moderator can click without opening a window; the seek slider is the one
-- thing that needs a formspec.

local controls = {}

controls.ITEMS = {
	{kind = "pause", item = "recorder_replay:pause", image = "recorder_replay_pause.png",
		description = "Replay: pause or resume"},
	{kind = "speed", item = "recorder_replay:speed", image = "recorder_replay_speed.png",
		description = "Replay: speed (1x, 2x, 4x, 0.5x)"},
	{kind = "back", item = "recorder_replay:back", image = "recorder_replay_back.png",
		description = "Replay: back 10 seconds"},
	{kind = "forward", item = "recorder_replay:forward", image = "recorder_replay_forward.png",
		description = "Replay: forward 10 seconds"},
	{kind = "seek", item = "recorder_replay:seek", image = "recorder_replay_seek.png",
		description = "Replay: choose a time"},
	{kind = "leave", item = "recorder_replay:leave", image = "recorder_replay_leave.png",
		description = "Replay: stop watching"},
}

-- The lighting switch: two items, one for each mode, and using one asks the
-- session to switch and puts the other in the same slot. The mode belongs to
-- the session (light is a property of the world), so every viewer sees the
-- same lighting; each viewer's item shows the mode as of their last switch.
controls.LIGHT_ITEMS = {
	recorded = {
		item = "recorder_replay:light_recorded",
		image = "recorder_replay_light_recorded.png",
		description = "Replay lighting: as recorded (use for live lighting)",
	},
	live = {
		item = "recorder_replay:light_live",
		image = "recorder_replay_light_live.png",
		description = "Replay lighting: recalculated live (use for recorded lighting)",
	},
}

-- The controls replace the main list, so they sit in the hotbar. The lighting
-- switch is only offered when the recording actually holds light.
---@param player ObjectRef
---@param session table?
function controls.fill(player, session)
	local inv = player:get_inventory()
	if not inv then return end
	local size = inv:get_size("main")
	local light = session and controls.LIGHT_ITEMS[session.light]
	local light_slot = #controls.ITEMS + 1
	local list = {}
	for i = 1, size do
		local def = controls.ITEMS[i]
		if i == light_slot and light then
			list[i] = ItemStack(light.item)
		else
			list[i] = ItemStack(def and def.item or "")
		end
	end
	inv:set_list("main", list)
end

---@param handle fun(kind: string, player: ObjectRef, extra: any): any
function controls.register(handle)
	for _, def in ipairs(controls.ITEMS) do
		core.register_craftitem(def.item, {
			description = def.description,
			inventory_image = def.image,
			stack_max = 1,
			-- Returning an empty stack keeps a control item from being dropped.
			on_drop = function() return ItemStack("") end,
			on_use = function(itemstack, user)
				if user and user:is_player() then handle(def.kind, user) end
				return itemstack
			end,
		})
	end
	for _, def in pairs(controls.LIGHT_ITEMS) do
		core.register_craftitem(def.item, {
			description = def.description,
			inventory_image = def.image,
			stack_max = 1,
			on_drop = function() return ItemStack("") end,
			on_use = function(itemstack, user)
				if user and user:is_player() then
					-- The handler returns the mode now in force; the item for
					-- that mode goes back into the wielded slot.
					local mode = handle("light_toggle", user)
					if mode and controls.LIGHT_ITEMS[mode] then
						return ItemStack(controls.LIGHT_ITEMS[mode].item)
					end
				end
				return itemstack
			end,
		})
	end
	core.register_on_player_receive_fields(function(player, formname, fields)
		-- A client can submit any formname it likes, including one it was never
		-- shown, so the privilege that lets a player use these forms is checked
		-- here as well as on the commands. A player who has it is a player the
		-- server would have let open the form in the first place.
		if not core.check_player_privs(player:get_player_name(), {replay = true}) then
			return
		end
		if formname == "recorder_replay:seek" then
			handle("seek_value", player, fields)
		elseif formname == "recorder_replay:sessions" then
			handle("session_choice", player, fields)
		elseif formname == "recorder_replay:recordings" then
			handle("recording_choice", player, fields)
		end
	end)
end

local function clock(seconds)
	seconds = math.max(0, math.floor(seconds + 0.5))
	return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- The seek slider: tenths of a second across the whole recording.
---@param session table
---@return string
function controls.seek_formspec(session)
	local max_value = math.max(1, math.floor((session.rec.duration or 0) * 10))
	local value = math.max(0, math.min(max_value, math.floor(session.T * 10)))
	local text = string.format("%s - %s / %s", session.name,
		clock(session.T), clock(session.rec.duration))
	return table.concat({
		"formspec_version[4]",
		"size[8,3.4]",
		"label[0.3,0.35;" .. core.formspec_escape(text) .. "]",
		string.format("scrollbaroptions[min=0;max=%d;smallstep=1;largestep=10;thumbsize=20]", max_value),
		string.format("scrollbar[0.3,1.2;7.4,0.6;horizontal;seek;%d]", value),
		"button_exit[3.1,2.4;1.8,0.7;close;Close]",
	}, "")
end

-- Labels do not wrap, so an error is broken into lines that fit the form. The
-- width is deliberately conservative: clients do not all use the same font,
-- and the text is laid out as one label per line so the vertical positions do
-- not depend on how a multi-line label is centred. A single word longer than
-- the line (a long recording name) is broken rather than allowed to overflow.
---@param text string
---@param width integer
---@param max_lines integer?
---@return string[]
local function wrap(text, width, max_lines)
	local words = {}
	for word in tostring(text):gmatch("%S+") do
		while #word > width do
			words[#words + 1] = word:sub(1, width)
			word = word:sub(width + 1)
		end
		if word ~= "" then words[#words + 1] = word end
	end
	local lines, line = {}, ""
	for _, word in ipairs(words) do
		if line == "" then
			line = word
		elseif #line + 1 + #word <= width then
			line = line .. " " .. word
		else
			lines[#lines + 1] = line
			line = word
		end
	end
	if line ~= "" then lines[#lines + 1] = line end
	if max_lines and #lines > max_lines then
		local truncated = {}
		for i = 1, max_lines do truncated[i] = lines[i] end
		truncated[max_lines] = truncated[max_lines] .. "..."
		lines = truncated
	end
	return lines
end

-- The recording chooser shown by a bare /replay. `files` is the list the
-- session will be started from, so the selection is an index into a list the
-- server already holds; a submission that names anything else is ignored.
-- `error` is shown under the list in red, and the form grows to make room.
---@param files table[]  -- {name = <file name>, path = <full path>}, newest first
---@param selected integer?
---@param error string?   -- why the last choice could not be started
---@return string
function controls.recordings_formspec(files, selected, error)
	local items = {}
	for i, entry in ipairs(files) do
		items[i] = core.formspec_escape(entry.name)
	end
	local lines = error and wrap(error, 60, 4) or {}
	local first_line_y, line_height = 5.7, 0.45
	local button_y = 5.6
	if #lines > 0 then
		button_y = first_line_y + (#lines - 1) * line_height + 0.45
	end
	local parts = {
		"formspec_version[4]",
		string.format("size[10,%.2f]", button_y + 1.2),
		"label[0.3,0.3;Watch a recording]",
		"label[0.3,0.65;Select one and press Watch, or double-click it.]",
		string.format("textlist[0.3,1.0;9.4,4.4;recordings;%s;%d;false]",
			table.concat(items, ","), math.max(0, selected or 0)),
	}
	for i, line in ipairs(lines) do
		parts[#parts + 1] = string.format("label[0.3,%.2f;%s]",
			first_line_y + (i - 1) * line_height,
			core.formspec_escape(core.colorize("#FF5555", line)))
	end
	parts[#parts + 1] = string.format("button_exit[2.6,%.2f;2,0.7;watch;Watch]", button_y)
	parts[#parts + 1] = string.format("button_exit[5.4,%.2f;2,0.7;cancel;Cancel]", button_y)
	return table.concat(parts, "")
end

-- The chooser shown by /replay join when more than one replay is running.
---@param list table[]
---@return string
function controls.sessions_formspec(list)
	local parts = {
		"formspec_version[4]",
		string.format("size[10,%.1f]", 1.2 + #list * 0.8),
		"label[0.3,0.3;Watch a replay]",
	}
	for i, session in ipairs(list) do
		local y = 0.8 + (i - 1) * 0.8
		local watching = 0
		for _ in pairs(session.participants) do watching = watching + 1 end
		parts[#parts + 1] = string.format(
			"button[0.3,%.1f;9.4,0.7;join_%s;%s - %d watching, %s / %s]",
			y, session.id, core.formspec_escape(session.name), watching,
			clock(session.T), clock(session.rec.duration))
	end
	return table.concat(parts, "")
end

return controls
