-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

-- The recording's region, as nodes in an arena: the snapshot the recording
-- started from, then every node_change up to the moment being shown. The
-- arrays live on the session and are changed in place during forward playback;
-- a seek rebuilds them from the snapshot and writes the result once.
--
-- The recorded positions and the arena's positions differ by a constant
-- offset, and the two regions have the same size. The snapshot's own indexes
-- are relative to the recorded region, so those are what index the arrays; the
-- offset is only applied when the arrays are written, or a ghost is placed.

local reconstruct = {}

local codec = recorder_common.snapshot
local region = recorder_common.region

-- Content ids belong to this run of this server, so the recording only names
-- nodes and every name is resolved again here. The engine raises for a name it
-- does not know - a node from a mod the server no longer has - and that node
-- becomes CONTENT_UNKNOWN. Id 0 is a valid id (the first registered node), so
-- it must not be mistaken for a missing one.
---@param name string
---@return integer
local function content_id(name)
	local ok, id = pcall(core.get_content_id, name)
	if not ok or id == nil or id == core.CONTENT_UNKNOWN then
		return core.CONTENT_UNKNOWN
	end
	return id
end

-- Read and decode the snapshot, and resolve its names into the baseline the
-- session will rebuild from.
---@param rec table  -- the reader's recording handle
---@return table|nil, string?
function reconstruct.load(rec)
	local row
	local queried, query_err = pcall(function()
		for candidate in rec.db:nrows(
			"SELECT pos1_x, pos1_y, pos1_z, size_x, size_y, size_z, names, encoding, data " ..
			"FROM Snapshot WHERE tick = 0") do
			row = candidate
		end
	end)
	if not queried then
		return nil, "cannot read this recording's snapshot: " .. tostring(query_err)
	end
	if not row then
		return nil, "this recording has no snapshot; it cannot be rebuilt"
	end

	local pos1 = {x = row.pos1_x, y = row.pos1_y, z = row.pos1_z}
	local size = {x = row.size_x, y = row.size_y, z = row.size_z}
	if size.x < 1 or size.y < 1 or size.z < 1 then
		return nil, "this recording's snapshot covers an empty region"
	end
	local recorded = {
		pos1 = pos1,
		pos2 = {x = pos1.x + size.x - 1, y = pos1.y + size.y - 1, z = pos1.z + size.z - 1},
	}

	local body = row.data
	if row.encoding == "deflate" then
		if not core.decompress then
			return nil, "this recording's snapshot is deflated, but this server cannot decompress it"
		end
		local ok, unpacked = pcall(core.decompress, body, "deflate")
		if not ok or type(unpacked) ~= "string" then
			return nil, "cannot decompress this recording's snapshot"
		end
		body = unpacked
	elseif row.encoding ~= "raw" then
		return nil, "this recording's snapshot uses an unknown encoding: " .. tostring(row.encoding)
	end

	local entries, err = codec.decode(body)
	if not entries then
		return nil, "cannot read this recording's snapshot: " .. tostring(err)
	end

	local names = {}
	for name in (row.names or ""):gmatch("[^\n]+") do
		names[#names + 1] = name
	end

	local volume = size.x * size.y * size.z
	local resolved = {}
	for _, entry in ipairs(entries) do
		local name = names[entry.n]
		if not name then
			return nil, "this recording's snapshot refers to a node name that is not in it"
		end
		if entry.i <= volume then
			resolved[#resolved + 1] = {i = entry.i, id = content_id(name), p = entry.p or 0}
		end
	end

	return {
		region = recorded,
		size = size,
		volume = volume,
		entries = resolved,  -- the non-air baseline, in flat-array order
		ids = nil,           -- region flat index -> content id, for the current moment
		param2 = nil,        -- and the param2 that goes with it
	}
end

-- Change one node of the state. Returns whether anything was different, so
-- forward playback knows whether the world needs writing.
---@param state table
---@param pos table?
---@param name string?
---@param param2 integer?
---@return boolean
function reconstruct.change(state, pos, name, param2)
	if not pos or not name then return false end
	local index = region.index(state.region, pos)
	if not index then return false end
	local id = content_id(name)
	local value = tonumber(param2) or 0
	if state.ids[index] == id and state.param2[index] == value then
		return false
	end
	state.ids[index] = id
	state.param2[index] = value
	return true
end

-- Rebuild the state at a tick: the snapshot first, then every node change up
-- to that tick in the order it happened. Changes beyond the tick are not read,
-- which is what seeking backwards undoes them.
---@param state table
---@param rec table
---@param tick integer
function reconstruct.seek(state, rec, tick)
	tick = math.floor(tonumber(tick) or 0)
	local ids, param2 = {}, {}
	for i = 1, state.volume do
		ids[i] = core.CONTENT_AIR
		param2[i] = 0
	end
	state.ids, state.param2 = ids, param2
	for _, entry in ipairs(state.entries) do
		ids[entry.i] = entry.id
		param2[entry.i] = entry.p
	end

	-- tick is a number this module produced, so it is safe to put into SQL.
	local sql = string.format(
		"SELECT pos_x, pos_y, pos_z, node, param2 FROM Events " ..
		"WHERE type = 'node_change' AND tick <= %d ORDER BY id", tick)
	for row in rec.db:nrows(sql) do
		reconstruct.change(state, {x = row.pos_x, y = row.pos_y, z = row.pos_z}, row.node, row.param2)
	end
end

-- Write the whole region into the arena in one VoxelManip operation. The VM
-- pre-loads a mapblock-aligned area that can be larger than the region, so the
-- cells are addressed through the emerged area's origin.
---@param state table
---@param offset table
---@return boolean|nil, string?
function reconstruct.write(state, offset)
	local pos1 = {
		x = state.region.pos1.x + offset.x,
		y = state.region.pos1.y + offset.y,
		z = state.region.pos1.z + offset.z,
	}
	local pos2 = {
		x = state.region.pos2.x + offset.x,
		y = state.region.pos2.y + offset.y,
		z = state.region.pos2.z + offset.z,
	}
	local vm = core.get_voxel_manip(pos1, pos2)
	if not vm then
		return nil, "cannot create a VoxelManip for the reconstruction"
	end
	local emerged1, emerged2 = vm:get_emerged_area()
	local ids = vm:get_data()
	local param2 = vm:get_param2_data()
	local emerged_size = {
		x = emerged2.x - emerged1.x + 1,
		y = emerged2.y - emerged1.y + 1,
		z = emerged2.z - emerged1.z + 1,
	}
	local size = state.size
	local origin = {x = pos1.x - emerged1.x, y = pos1.y - emerged1.y, z = pos1.z - emerged1.z}
	for z = 0, size.z - 1 do
		local state_layer = z * size.y * size.x
		local map_layer = (origin.z + z) * emerged_size.y * emerged_size.x
		for y = 0, size.y - 1 do
			local state_row = state_layer + y * size.x
			local map_row = map_layer + (origin.y + y) * emerged_size.x + origin.x
			for x = 1, size.x do
				ids[map_row + x] = state.ids[state_row + x]
				param2[map_row + x] = state.param2[state_row + x]
			end
		end
	end
	vm:set_data(ids)
	vm:set_param2_data(param2)
	-- update_liquids() is deliberately never called: it is what makes the
	-- engine start flowing whatever liquids were written, while a replay has to
	-- hold still when paused and show exactly the recorded moment when seeking.
	vm:write_to_map()
	vm:close()
	return true
end

return reconstruct
