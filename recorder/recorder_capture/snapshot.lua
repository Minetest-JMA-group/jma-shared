-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

-- The baseline a replay starts from: the region as it was when the recording
-- began. The work happens in steps, because it must not stall a server step:
-- the region is emerged first, then read with one VoxelManip, then walked in
-- slices and encoded.
--
-- The walk also leaves the region's content ids and param2 values in memory, in
-- the region's flat-array order. That is what the mapblock-changed callback
-- diffs against later: a changed block is read back and compared with what the
-- recording last knew, and only the nodes that differ become rows.

local snapshot = {}

-- How long the emerge phase may take before the snapshot gives up. The operator
-- can always /recorder stop, but a snapshot that is stuck should not hold the
-- recording open for ever.
local EMERGE_TIMEOUT = 120

local region = recorder_common.region
local codec = recorder_common.snapshot

---@param pos1 table
---@param pos2 table
---@param record_light boolean?  -- false leaves the light layers out
---@return table|nil, string?
function snapshot.new(pos1, pos2, record_light)
	local normalized, err = region.normalize(pos1, pos2)
	if not normalized then return nil, err end
	pos1, pos2 = normalized.pos1, normalized.pos2
	local snap = {
		region = {pos1 = pos1, pos2 = pos2},
		size = region.size({pos1 = pos1, pos2 = pos2}),
		phase = "emerge",
		emerged = {done = false, errors = 0},
		deadline = os.time() + EMERGE_TIMEOUT,
		node_index = 0,
		entries = {},
		names = {},
		name_index = {},   -- content id -> index into names
		ids = {},          -- region flat index -> content id (the known state)
		param2 = {},       -- region flat index -> param2
		record_light = record_light ~= false,
		light = {},        -- region flat index -> light byte, when recorded
		light_data = nil,  -- the emerged area's light, while walking
		failure = nil,
	}
	core.emerge_area(pos1, pos2, function(blockpos, action, calls_remaining)
		if action == core.EMERGE_CANCELLED or action == core.EMERGE_ERRORED then
			snap.emerged.errors = snap.emerged.errors + 1
		end
		if calls_remaining == 0 then
			snap.emerged.done = true
		end
	end)
	return snap
end

-- 0 when the emerge phase is still running, then the part of the walk done.
---@param snap table
---@return number
function snapshot.progress(snap)
	if snap.phase == "done" then return 1 end
	if snap.phase ~= "encode" then return 0 end
	local volume = region.volume(snap.region)
	if volume == 0 then return 0 end
	return snap.node_index / volume
end

local function begin_walk(snap)
	local vm = core.get_voxel_manip(snap.region.pos1, snap.region.pos2)
	if not vm then
		snap.failure = "cannot create a VoxelManip for the region"
		return "failed", snap.failure
	end
	if not vm:read_from_map(snap.region.pos1, snap.region.pos2) then
		vm:close()
		snap.failure = "cannot read the region from the map"
		return "failed", snap.failure
	end
	local emerged1, emerged2 = vm:get_emerged_area()
	local data = vm:get_data()
	local param2 = vm:get_param2_data()
	local light = snap.record_light and vm:get_light_data() or nil
	vm:close()
	snap.data, snap.param2_data = data, param2
	snap.light_data = light
	snap.emerged1 = emerged1
	snap.emerged_size = {
		x = emerged2.x - emerged1.x + 1,
		y = emerged2.y - emerged1.y + 1,
		z = emerged2.z - emerged1.z + 1,
	}
	snap.phase = "encode"
	return "working", nil
end

local function encode_step(snap, budget)
	local volume = region.volume(snap.region)
	local emerged1, emerged_size = snap.emerged1, snap.emerged_size
	local data, param2 = snap.data, snap.param2_data
	local light_data = snap.light_data
	local walked = 0

	while snap.node_index < volume and walked < budget do
		local index = snap.node_index + 1
		local pos = region.position(snap.region, index)
		-- The VoxelManip may have loaded a larger, mapblock-aligned area than the
		-- region; its flat index differs from the region's, so compute it.
		local lvm_index = (pos.z - emerged1.z) * emerged_size.y * emerged_size.x
			+ (pos.y - emerged1.y) * emerged_size.x
			+ (pos.x - emerged1.x) + 1
		local id = data[lvm_index]
		local value = param2[lvm_index]

		snap.ids[index] = id
		snap.param2[index] = value
		if snap.record_light then
			snap.light[index] = light_data and light_data[lvm_index] or 0
		end

		if id == core.CONTENT_IGNORE then
			-- The area did not finish emerging; storing it would put "ignore"
			-- nodes into the recording, which no replay can place.
			snap.failure = "the region is not fully emerged (ignore node at "
				.. core.pos_to_string(pos) .. ")"
			return "failed", snap.failure
		end

		if id ~= core.CONTENT_AIR then
			local name_index = snap.name_index[id]
			if not name_index then
				local name = core.get_name_from_content_id(id)
				if name then
					snap.names[#snap.names + 1] = name
					name_index = #snap.names
					snap.name_index[id] = name_index
				end
			end
			if name_index then
				snap.entries[#snap.entries + 1] = {i = index, n = name_index, p = value}
			end
		end

		snap.node_index = index
		walked = walked + 1
	end

	if snap.node_index < volume then
		return "working", nil
	end

	local body, err = codec.encode(snap.entries)
	if not body then
		snap.failure = err or "cannot encode the snapshot"
		return "failed", snap.failure
	end
	local encoding = "raw"
	if core.compress then
		local packed = core.compress(body, "deflate", 9)
		if packed then
			body, encoding = packed, "deflate"
		end
	end
	snap.entries = nil
	snap.data, snap.param2_data = nil, nil
	snap.light_data = nil
	snap.phase = "done"
	return "done", {
		names = snap.names,
		encoding = encoding,
		data = body,
		ids = snap.ids,
		param2 = snap.param2,
		light = snap.record_light and snap.light or nil,
	}
end

-- One server step of the snapshot. Returns "working", "done" or "failed"; the
-- second value is the result on success and the reason on failure.
---@param snap table
---@param budget integer  -- region nodes to examine this step
---@return string, table|string|nil
function snapshot.step(snap, budget)
	if snap.failure then return "failed", snap.failure end

	if snap.phase == "emerge" then
		if not snap.emerged.done then
			if os.time() > snap.deadline then
				snap.failure = "the region did not finish emerging"
				return "failed", snap.failure
			end
			return "working", nil
		end
		if snap.emerged.errors > 0 then
			snap.failure = string.format("%d map block(s) of the region could not be emerged",
				snap.emerged.errors)
			return "failed", snap.failure
		end
		local state, err = begin_walk(snap)
		if state ~= "working" then return state, err end
		-- The read succeeded; spend this step's budget on the walk as well.
	end

	if snap.phase == "encode" then
		return encode_step(snap, budget)
	end

	snap.failure = "the snapshot is in an unknown phase"
	return "failed", snap.failure
end

-- Let go of the large temporary tables when a snapshot is abandoned.
---@param snap table
function snapshot.free(snap)
	snap.entries = nil
	snap.data, snap.param2_data = nil, nil
	snap.light_data = nil
	snap.ids, snap.param2 = nil, nil
	snap.light = nil
	snap.names = nil
end

return snapshot
