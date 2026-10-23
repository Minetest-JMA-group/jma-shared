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
			"SELECT pos1_x, pos1_y, pos1_z, size_x, size_y, size_z, names, encoding, data, " ..
			"light, light_encoding FROM Snapshot WHERE tick = 0") do
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

	-- The light layer is optional: a recording made with recorder.light off
	-- has none, and replay then recalculates the light instead. A layer that
	-- cannot be read is treated the same way rather than costing the session.
	local light_base
	if row.light ~= nil and #row.light > 0 then
		local light_body = row.light
		local encoding_ok = true
		if row.light_encoding == "deflate" then
			if core.decompress then
				local decompressed, unpacked = pcall(core.decompress, light_body, "deflate")
				if decompressed and type(unpacked) == "string" then
					light_body = unpacked
				else
					encoding_ok = false
				end
			else
				encoding_ok = false
			end
		elseif row.light_encoding ~= "raw" then
			encoding_ok = false
		end
		local values, light_err
		if encoding_ok then
			values, light_err = recorder_common.light.decode(light_body, volume)
		end
		if values then
			light_base = values
		else
			core.log("warning", "[replay] the recording's light layer is unusable" ..
				(light_err and (": " .. tostring(light_err)) or ""))
		end
	end

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
		light_base = light_base, -- the light at tick 0, or nil when not recorded
		has_light = light_base ~= nil,
		light = nil,         -- and the light for the current moment
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

-- The arena-space mapblock a recorded position falls in.
---@param blocks table
---@param pos table  -- recorded position
---@param offset table
function reconstruct.add_block(blocks, pos, offset)
	if not pos then return end
	local block = {
		x = math.floor((pos.x + offset.x) / 16) * 16,
		y = math.floor((pos.y + offset.y) / 16) * 16,
		z = math.floor((pos.z + offset.z) / 16) * 16,
	}
	blocks[block.x .. "," .. block.y .. "," .. block.z] = block
end

-- The mapblocks a light-change body touches, from the region indexes it holds.
---@param blocks table
---@param state table
---@param entries table?
---@param offset table
function reconstruct.add_light_blocks(blocks, state, entries, offset)
	if not entries then return end
	for _, entry in ipairs(entries) do
		local pos = region.position(state.region, entry.i)
		if pos then reconstruct.add_block(blocks, pos, offset) end
	end
end

-- Rebuild the state at a tick: the snapshot first, then every node change up
-- to that tick in the order it happened. Changes beyond the tick are not read,
-- which is what seeking backwards undoes them.
--
-- When `since_tick` is given, the mapblocks touched by the rows between that
-- tick and this one are collected and returned: they are the only blocks whose
-- content can differ between the state last written and this one, so a seek
-- only has to write those. The arrays themselves are reused rather than
-- allocated again - at millions of nodes, the allocation alone is a pause.
---@param state table
---@param rec table
---@param tick integer
---@param offset table?      -- needed when since_tick is given
---@param since_tick integer? -- the tick the arena's world was last at
---@return table|nil  -- touched blocks when since_tick is given
function reconstruct.seek(state, rec, tick, offset, since_tick)
	tick = math.floor(tonumber(tick) or 0)
	local touched, lo, hi
	if since_tick ~= nil then
		touched = {}
		lo, hi = math.min(since_tick, tick), math.max(since_tick, tick)
	end
	-- A backwards seek has to undo rows above its tick; they are not applied to
	-- the state, but they still say which blocks have to be written.
	local limit_tick = since_tick ~= nil and math.max(tick, since_tick) or tick

	local ids, param2 = state.ids, state.param2
	if not ids then ids, param2 = {}, {} end
	for i = 1, state.volume do
		ids[i] = core.CONTENT_AIR
		param2[i] = 0
	end
	state.ids, state.param2 = ids, param2
	for _, entry in ipairs(state.entries) do
		ids[entry.i] = entry.id
		param2[entry.i] = entry.p
	end

	-- Light is rebuilt from its own baseline and its own changes; the node
	-- changes above say nothing about it.
	if state.has_light then
		local light = state.light
		if not light then light = {} end
		for i = 1, state.volume do light[i] = state.light_base[i] end
		state.light = light
		local sql = string.format(
			"SELECT tick, data, encoding FROM LightChanges WHERE tick <= %d ORDER BY id", limit_tick)
		for row in rec.db:nrows(sql) do
			local in_interval = touched and row.tick > lo and row.tick <= hi
			if row.tick <= tick then
				local applied, entries = reconstruct.apply_light(state, row.data, row.encoding)
				if in_interval and applied then
					reconstruct.add_light_blocks(touched, state, entries, offset)
				end
			elseif in_interval then
				-- Not applied (it is past the seek's tick), but its blocks are
				-- some of the ones the arena currently has and this state does
				-- not.
				reconstruct.add_light_blocks(touched, state,
					reconstruct.decode_light(row.data, row.encoding), offset)
			end
		end
	else
		state.light = nil
	end

	-- tick is a number this module produced, so it is safe to put into SQL.
	local sql = string.format(
		"SELECT tick, pos_x, pos_y, pos_z, node, param2 FROM Events " ..
		"WHERE type = 'node_change' AND tick <= %d ORDER BY id", limit_tick)
	for row in rec.db:nrows(sql) do
		if row.tick <= tick then
			reconstruct.change(state,
				{x = row.pos_x, y = row.pos_y, z = row.pos_z}, row.node, row.param2)
		end
		if touched and row.tick > lo and row.tick <= hi then
			reconstruct.add_block(touched, {x = row.pos_x, y = row.pos_y, z = row.pos_z}, offset)
		end
	end
	return touched
end

-- Read one stored light-change body into entries, without applying them.
---@param body string
---@param encoding string
---@return table?
function reconstruct.decode_light(body, encoding)
	local decoded_body = body
	if encoding == "deflate" then
		if not core.decompress then return nil end
		local ok, unpacked = pcall(core.decompress, body, "deflate")
		if not ok or type(unpacked) ~= "string" then return nil end
		decoded_body = unpacked
	elseif encoding ~= "raw" then
		return nil
	end
	local entries, err = codec.decode(decoded_body)
	if not entries then
		core.log("warning", "[replay] cannot read light changes: " .. tostring(err))
		return nil
	end
	return entries
end

-- Apply one stored light-change body to the state. Returns whether anything
-- was applied, and the entries when it was; a body that cannot be read is
-- reported and skipped.
---@param state table
---@param body string
---@param encoding string
---@return boolean, table?
function reconstruct.apply_light(state, body, encoding)
	if not state.light then return false end
	local entries = reconstruct.decode_light(body, encoding)
	if not entries then return false end
	for _, entry in ipairs(entries) do
		if entry.i >= 1 and entry.i <= state.volume then
			state.light[entry.i] = entry.p
		end
	end
	return true, entries
end

-- Put one recorded metadata row into the arena. An empty data string is a
-- deliberate clearing; the position is translated like every other recorded
-- position. A row that cannot be read is reported and skipped rather than
-- taking the session down.
---@param offset table
---@param row table
function reconstruct.apply_metadata(offset, row)
	if not row or not row.pos then return end
	local pos = {
		x = row.pos.x + offset.x,
		y = row.pos.y + offset.y,
		z = row.pos.z + offset.z,
	}
	local ok, err = true, nil
	if row.data == "" then
		core.get_meta(pos):from_table(nil)
	else
		local read, data = pcall(core.deserialize, row.data)
		if read and type(data) == "table" then
			ok, err = pcall(function() core.get_meta(pos):from_table(data) end)
		else
			ok, err = false, "the metadata row cannot be deserialized"
		end
	end
	if not ok then
		core.log("warning", "[replay] cannot apply node metadata: " .. tostring(err))
	end
end

-- Write the whole region into the arena in one VoxelManip operation. The VM
-- pre-loads a mapblock-aligned area that can be larger than the region, so the
-- cells are addressed through the emerged area's origin.
--
-- `mode` is "recorded" to write the light the recording holds (with the engine
-- told not to recalculate it) or "live" to let the engine work it out. Without
-- recorded light the mode falls back to live.
---@param state table
---@param offset table
---@param mode string?  -- "recorded" or "live"
---@return boolean|nil, string?
function reconstruct.write(state, offset, mode)
	local recorded = mode == "recorded" and state.has_light and state.light ~= nil
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
	local light = recorded and vm:get_light_data() or nil
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
				if light then
					light[map_row + x] = state.light[state_row + x]
				end
			end
		end
	end
	vm:set_data(ids)
	vm:set_param2_data(param2)
	if light then
		vm:set_light_data(light)
	end
	-- update_liquids() is deliberately never called: it is what makes the
	-- engine start flowing whatever liquids were written, while a replay has to
	-- hold still when paused and show exactly the recorded moment when seeking.
	-- The light is not recalculated here either: recorded lighting was just put
	-- in, and live lighting is recalculated in one pass by the caller.
	vm:write_to_map(false)
	vm:close()
	return true
end

-- Write only some mapblocks of the region: the cells inside the region come
-- from the state, the rest of each block is left as the map had it. This is
-- how forward playback and seeks touch what changed rather than the whole
-- region, which on a large recording is the difference between a step and a
-- multi-second pause.
---@param state table
---@param offset table
---@param blocks table  -- key -> block base, in arena/world coordinates
---@param mode string?  -- "recorded" or "live"
---@return boolean|nil, string?
function reconstruct.write_blocks(state, offset, blocks, mode)
	local recorded = mode == "recorded" and state.has_light and state.light ~= nil
	local size = state.size
	local region_box = state.region
	local rx1, ry1, rz1 = region_box.pos1.x + offset.x,
		region_box.pos1.y + offset.y, region_box.pos1.z + offset.z
	local rx2, ry2, rz2 = region_box.pos2.x + offset.x,
		region_box.pos2.y + offset.y, region_box.pos2.z + offset.z
	local failed = false
	for _, block in pairs(blocks) do
		local p2 = {x = block.x + 15, y = block.y + 15, z = block.z + 15}
		local vm = core.get_voxel_manip(block, p2)
		if vm then
			if vm:read_from_map(block, p2) then
				local emerged1, emerged2 = vm:get_emerged_area()
				local ids = vm:get_data()
				local param2 = vm:get_param2_data()
				local light = recorded and vm:get_light_data() or nil
				local emerged_size = {
					x = emerged2.x - emerged1.x + 1,
					y = emerged2.y - emerged1.y + 1,
					z = emerged2.z - emerged1.z + 1,
				}
				local x1 = math.max(block.x, rx1)
				local x2 = math.min(block.x + 15, rx2)
				local y1 = math.max(block.y, ry1)
				local y2 = math.min(block.y + 15, ry2)
				local z1 = math.max(block.z, rz1)
				local z2 = math.min(block.z + 15, rz2)
				for z = z1, z2 do
					local dz = z - rz1
					local map_layer = (z - emerged1.z) * emerged_size.y * emerged_size.x
					local state_layer = dz * size.y * size.x
					for y = y1, y2 do
						local dy = y - ry1
						local map_row = map_layer + (y - emerged1.y) * emerged_size.x
						local state_row = state_layer + dy * size.x
						for x = x1, x2 do
							local dx = x - rx1
							local state_index = state_row + dx + 1
							local map_index = map_row + (x - emerged1.x) + 1
							ids[map_index] = state.ids[state_index]
							param2[map_index] = state.param2[state_index]
							if light then
								light[map_index] = state.light[state_index]
							end
						end
					end
				end
				vm:set_data(ids)
				vm:set_param2_data(param2)
				if light then vm:set_light_data(light) end
				-- write_to_map(false) when the light came from the recording: the
				-- engine must not recalculate what was just put in.
				vm:write_to_map(not recorded)
			else
				failed = true
			end
			vm:close()
		else
			failed = true
		end
	end
	if failed then
		return nil, "some changed mapblocks could not be written"
	end
	return true
end

return reconstruct
