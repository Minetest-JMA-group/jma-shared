-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

-- The box a replay is built in: an invisible shell with the recording's region
-- reconstructed inside it. Where the box is depends on the session, so the
-- choice is made here, from the three sources a server can have - the player's
-- own marks, the game's provider, or the one static box in replay.arena - and
-- remembered in mod storage before the first node is placed, because after a
-- crash the arena's bounds are the only thing that can clean it up.

local arena = {}

local region = recorder_common.region

local BARRIER = "recorder_replay:barrier"
local FLAG_KEY = "recorder_replay:session"

local deps -- {storage = ModStorage, running = function() -> table of boxes}

local marks = {}  -- player name -> {pos1 = pos, pos2 = pos}

---@param dependencies table
function arena.init(dependencies)
	deps = dependencies
end

-- The shell is invisible and see-through - the viewers look through it at the
-- reconstruction - but solid, so nobody walks or falls out of the arena. Its
-- top face doubles as the viewing platform. It also has to be transparent to
-- light: a shell that blocked sunlight would turn the whole arena pitch black
-- and cast a shadow on the world around it, which is very visible from
-- outside where the shell itself is not.
core.register_node(BARRIER, {
	description = "Replay arena barrier",
	drawtype = "airlike",
	paramtype = "light",
	sunlight_propagates = true,
	walkable = true,
	pointable = false,
	diggable = false,
	buildable_to = false,
	floodable = false,
	drops = "",
})

----------------------------------------------------------------------------
-- Marks: a player's pending arena
----------------------------------------------------------------------------

---@param name string
---@param which string  -- "pos1" or "pos2"
---@param pos table
---@return boolean|nil, string?
function arena.set_mark(name, which, pos)
	if which ~= "pos1" and which ~= "pos2" then
		return nil, "an arena mark is pos1 or pos2"
	end
	local normalized, err = region.normalize(pos, pos)
	if not normalized then return nil, err end
	local mark = marks[name] or {}
	mark[which] = normalized.pos1
	marks[name] = mark
	return true
end

---@param name string
function arena.clear_marks(name)
	marks[name] = nil
end

-- Both corners are needed before marks can be used as an arena; one alone is
-- just a place somebody pointed at.
---@param name string
---@return boolean
function arena.has_marks(name)
	local mark = marks[name]
	return mark ~= nil and mark.pos1 ~= nil and mark.pos2 ~= nil
end

-- A mark dies with the player's connection: an arena chosen by someone who is
-- no longer here would block the box for everyone.
core.register_on_leaveplayer(function(player)
	if not player or not player.get_player_name then return end
	marks[player:get_player_name()] = nil
end)

----------------------------------------------------------------------------
-- Choosing an arena
----------------------------------------------------------------------------

---@param recorded table
---@return table  -- the smallest arena that can hold the recording
local function required_size(recorded)
	local size = region.size(recorded)
	return {x = size.x + 2, y = size.y + 2, z = size.z + 2}
end

-- The recording fills the arena's interior exactly when the arena is the
-- minimum size, and the outer layer of the box is the shell; one node in from
-- it on every side is what the region needs.
---@return boolean|nil, string?
local function check_size(box, recorded, what)
	local wanted = required_size(recorded)
	local got = region.size(box)
	if got.x < wanted.x or got.y < wanted.y or got.z < wanted.z then
		return nil, string.format(
			"%s is too small: this recording needs %d x %d x %d (its region plus a shell layer on each side)",
			what, wanted.x, wanted.y, wanted.z)
	end
	return true
end

local function overlaps_any(box, boxes)
	for _, other in ipairs(boxes) do
		if region.overlaps(box, other) then return other end
	end
	return nil
end

local function running_boxes()
	local boxes = {}
	if deps and deps.running then
		for _, box in ipairs(deps.running()) do boxes[#boxes + 1] = box end
	end
	return boxes
end

-- Everything another player has marked but not started yet. The caller's own
-- marks are not a conflict with themselves: those are the box being resolved.
local function pending_boxes(except_name)
	local boxes = {}
	for name, mark in pairs(marks) do
		if name ~= except_name and mark.pos1 and mark.pos2 then
			local box = region.normalize(mark.pos1, mark.pos2)
			if box then boxes[#boxes + 1] = box end
		end
	end
	return boxes
end

-- x1,y1,z1,x2,y2,z2; spaces around the commas are allowed, nothing else is.
---@return table|nil, string?
local function setting_box()
	local raw = core.settings:get("replay.arena")
	if not raw or raw == "" then return nil end
	local numbers = {}
	for token in raw:gmatch("[^,%s]+") do
		local value = tonumber(token)
		if not value then
			return nil, "replay.arena must be six numbers: x1,y1,z1,x2,y2,z2"
		end
		numbers[#numbers + 1] = value
	end
	if #numbers ~= 6 then
		return nil, "replay.arena must be six numbers: x1,y1,z1,x2,y2,z2"
	end
	local box, err = region.normalize(
		{x = numbers[1], y = numbers[2], z = numbers[3]},
		{x = numbers[4], y = numbers[5], z = numbers[6]})
	if not box then return nil, "replay.arena: " .. tostring(err) end
	return box
end

-- A candidate box is unusable when it sits on an arena in use or on one
-- somebody else is about to start.
local function overlap_reason(box, player_name, what)
	if overlaps_any(box, running_boxes()) then
		return what .. " overlaps an arena that is already in use"
	end
	if overlaps_any(box, pending_boxes(player_name)) then
		return what .. " overlaps an arena another player is marking"
	end
	return nil
end

-- A candidate box is usable when it holds the recording and does not overlap.
local function accept(box, recorded, player_name, what)
	local ok, err = check_size(box, recorded, what)
	if not ok then return nil, err end
	local overlap = overlap_reason(box, player_name, what)
	if overlap then return nil, overlap end
	return box
end

-- Is there a source that could give this player an arena? A recording has not
-- been chosen yet, so the box's size cannot be checked - only the source and
-- what can be known about it now. The size is decided when a recording is
-- selected.
---@param player_name string
---@return boolean, string?  -- false and a reason when no source can be used
function arena.available(player_name)
	if arena.has_marks(player_name) then
		local box = region.normalize(marks[player_name].pos1, marks[player_name].pos2)
		if box then
			local overlap = overlap_reason(box, player_name, "the arena you marked")
			if overlap then return false, overlap end
		end
		return true
	end
	if recorder_common.game_hooks.arena then return true end
	local configured, err = setting_box()
	if err then return false, err end
	if not configured then return false end
	if overlaps_any(configured, running_boxes()) then
		return false, "the configured arena is in use; mark another one or wait"
	end
	return true
end

-- The arena for a session, from the highest-priority source that has one.
--
-- The setting is consulted only when the game registers no provider: a
-- provider always has an answer, so a setting next to it would never be used.
-- It is one fixed box, so it can serve one session at a time; waiting for it
-- to be free or marking another arena are the ways out.
---@param player_name string
---@param recorded table  -- the recording's region
---@return table|nil, string?
function arena.resolve(player_name, recorded)
	local mark = marks[player_name]
	if mark and mark.pos1 and mark.pos2 then
		local box, err = region.normalize(mark.pos1, mark.pos2)
		if not box then return nil, "your arena marks are not usable: " .. tostring(err) end
		return accept(box, recorded, player_name, "the arena you marked")
	end

	local provider = recorder_common.game_hooks.arena
	if provider then
		local size = required_size(recorded)
		local taken = running_boxes()
		for _, box in ipairs(pending_boxes(player_name)) do taken[#taken + 1] = box end
		local called, pos1, pos2 = pcall(provider, size, taken)
		if not called then
			return nil, "the game's arena provider failed: " .. tostring(pos1)
		end
		if pos1 == nil then
			if type(pos2) == "string" and pos2 ~= "" then
				return nil, "the game could not provide an arena: " .. pos2
			end
			return nil, "the game could not provide an arena for this replay"
		end
		local box, err = region.normalize(pos1, pos2)
		if not box then
			return nil, "the game's arena provider returned an unusable box: " .. tostring(err)
		end
		return accept(box, recorded, player_name, "the game's arena")
	end

	local configured, setting_err = setting_box()
	if setting_err then return nil, setting_err end
	if configured then
		local ok, err = check_size(configured, recorded, "replay.arena")
		if not ok then return nil, err end
		if overlaps_any(configured, running_boxes()) then
			return nil, "the configured arena is in use; mark another one or wait"
		end
		return configured
	end

	return nil, "there is no arena for this replay: mark one with /replay pos1 and /replay pos2," ..
		" ask the game to provide one, or set replay.arena"
end

----------------------------------------------------------------------------
-- Moving the world
----------------------------------------------------------------------------

-- Write the cells of a box through a VoxelManip. `fill` gets the arrays the VM
-- pre-loaded and the emerged area's origin and size, because that area is
-- mapblock-aligned and may be larger than the box asked for; indexes in the
-- arrays are relative to its origin, not to the box.
local function write_box(box, fill)
	local vm = core.get_voxel_manip(box.pos1, box.pos2)
	if not vm then return nil, "cannot create a VoxelManip for the arena" end
	local emerged1, emerged2 = vm:get_emerged_area()
	local ids = vm:get_data()
	local param2 = vm:get_param2_data()
	local emerged_size = {
		x = emerged2.x - emerged1.x + 1,
		y = emerged2.y - emerged1.y + 1,
		z = emerged2.z - emerged1.z + 1,
	}
	fill(emerged1, emerged_size, ids, param2)
	vm:set_data(ids)
	vm:set_param2_data(param2)
	vm:write_to_map()
	vm:close()
	return true
end

-- write_to_map() recalculates the light of the blocks it writes, but the
-- engine's incremental update is known to leave artefacts around large
-- writes (the same thing WorldEdit runs into), and a dark arena is not
-- something the viewer can see past. A full recalculation over the arena is
-- cheap at the few moments a session builds or clears its world; during
-- forward playback the per-step write is left to write_to_map().
---@param box table
function arena.relight(box)
	if not core.fix_light then return end
	local ok, fixed = pcall(core.fix_light, box.pos1, box.pos2)
	if not ok then
		core.log("warning", "[replay] cannot recalculate the arena's light: " .. tostring(fixed))
	elseif fixed == false then
		core.log("warning", "[replay] the arena's light could not be recalculated")
	end
end

-- Every cell of the box is written - an explicit read_from_map() is not
-- needed, because get_voxel_manip() already loaded the area. The outer layer
-- becomes the barrier and the interior becomes air; the reconstruction then
-- fills the recording's part of the interior.
---@param box table
---@return boolean|nil, string?
function arena.prepare(box)
	-- Id 0 is the first node the game registered, not a missing one, so the
	-- registration is confirmed by resolving the name rather than by a value.
	local called, barrier = pcall(core.get_content_id, BARRIER)
	if not called or barrier == nil or barrier == core.CONTENT_UNKNOWN then
		return nil, "the replay barrier node is not registered"
	end
	local size = region.size(box)
	local written, err = write_box(box, function(origin, emerged_size, ids, param2)
		for z = 0, size.z - 1 do
			local layer = (box.pos1.z + z - origin.z) * emerged_size.y * emerged_size.x
			local edge_z = z == 0 or z == size.z - 1
			for y = 0, size.y - 1 do
				local row = layer + (box.pos1.y + y - origin.y) * emerged_size.x
				local edge_y = edge_z or y == 0 or y == size.y - 1
				for x = 0, size.x - 1 do
					local index = row + (box.pos1.x + x - origin.x) + 1
					local edge = edge_y or x == 0 or x == size.x - 1
					ids[index] = edge and barrier or core.CONTENT_AIR
					param2[index] = 0
				end
			end
		end
	end)
	if not written then return nil, err end
	arena.relight(box)
	return true
end

---@param box table
---@return boolean|nil, string?
function arena.clear(box)
	local size = region.size(box)
	local written, err = write_box(box, function(origin, emerged_size, ids, param2)
		for z = 0, size.z - 1 do
			local layer = (box.pos1.z + z - origin.z) * emerged_size.y * emerged_size.x
			for y = 0, size.y - 1 do
				local row = layer + (box.pos1.y + y - origin.y) * emerged_size.x
				for x = 0, size.x - 1 do
					local index = row + (box.pos1.x + x - origin.x) + 1
					ids[index] = core.CONTENT_AIR
					param2[index] = 0
				end
			end
		end
	end)
	if not written then return nil, err end
	arena.relight(box)
	return true
end

-- Where a participant stands while watching: the centre of the top face. The
-- top face is the shell itself, so the feet go one node above it - outside the
-- recorded volume, where nobody can dig the reconstruction.
---@param box table
---@return table
function arena.viewing_position(box)
	return {
		x = (box.pos1.x + box.pos2.x) / 2,
		y = box.pos2.y + 1,
		z = (box.pos1.z + box.pos2.z) / 2,
	}
end

-- The recording's region is rebuilt one node in from the arena's low corner.
---@param box table
---@param recorded table
---@return table
function arena.offset(box, recorded)
	return {
		x = box.pos1.x + 1 - recorded.pos1.x,
		y = box.pos1.y + 1 - recorded.pos1.y,
		z = box.pos1.z + 1 - recorded.pos1.z,
	}
end

---@param pos table?
---@param offset table
---@return table?
function arena.translate(pos, offset)
	if not pos then return nil end
	return {x = pos.x + offset.x, y = pos.y + offset.y, z = pos.z + offset.z}
end

----------------------------------------------------------------------------
-- The boot flag
----------------------------------------------------------------------------

-- One entry per running session, keyed by its id:
--   {[id] = {pos1 = {x, y, z}, pos2 = {x, y, z}}}
-- Several replays can run at once, and a crash leaves all of their shells in
-- the world, so one box per word of storage would forget the others.
local function read_flag()
	if not deps or not deps.storage then return {} end
	local raw = deps.storage:get_string(FLAG_KEY)
	if not raw or raw == "" then return {} end
	local ok, value = pcall(core.deserialize, raw)
	if not ok or type(value) ~= "table" then return {} end
	return value
end

local function write_flag(entries)
	if not deps or not deps.storage then return end
	deps.storage:set_string(FLAG_KEY, next(entries) ~= nil and core.serialize(entries) or "")
end

-- Remember an arena before the first node of it is placed. The bounds are
-- chosen at run time, so this is the only way a crash can know what to clean
-- up; a shell left behind is invisible, solid and impossible to find.
---@param box table
---@param session_id string
function arena.save_flag(box, session_id)
	local entries = read_flag()
	entries[session_id] = {pos1 = box.pos1, pos2 = box.pos2}
	write_flag(entries)
end

---@param session_id string
function arena.clear_flag(session_id)
	local entries = read_flag()
	if entries[session_id] == nil then return end
	entries[session_id] = nil
	write_flag(entries)
end

-- The first server step after boot: by then the world can be written. A
-- persistent world still holds the previous run's shells; a world the game
-- rebuilds from scratch does not, and is left alone. Either way the flag is
-- gone, because nothing it named survives the restart.
function arena.recover()
	local entries = read_flag()
	if recorder_common.game_hooks.world_persistent then
		for _, entry in pairs(entries) do
			if type(entry) == "table" then
				local box = region.normalize(entry.pos1, entry.pos2)
				if box then arena.clear(box) end
			end
		end
	end
	write_flag({})
end

return arena
