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

-- The controls replace the main list, so they sit in the hotbar.
---@param player ObjectRef
function controls.fill(player)
	local inv = player:get_inventory()
	if not inv then return end
	local size = inv:get_size("main")
	local list = {}
	for i = 1, size do
		local def = controls.ITEMS[i]
		list[i] = ItemStack(def and def.item or "")
	end
	inv:set_list("main", list)
end

---@param handle fun(kind: string, player: ObjectRef, extra: any)
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
	core.register_on_player_receive_fields(function(player, formname, fields)
		if formname == "recorder_replay:seek" then
			handle("seek_value", player, fields)
		elseif formname == "recorder_replay:sessions" then
			handle("session_choice", player, fields)
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
