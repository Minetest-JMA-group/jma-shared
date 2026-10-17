-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

-- The cuboid a recording covers, and the rules that keep everything in the
-- file inside it. Recording uses this to decide who is sampled, which events
-- are kept and which mapblocks are watched; replay uses it to size an arena and
-- to place the recording's region inside one. The flat-array order is the one
-- VoxelManip uses, so a snapshot's indexes and a replay's arrays agree.

local region = {}

-- Two corners in either order, with whole-number node coordinates.
---@param pos1 table
---@param pos2 table
---@return table|nil, string?
function region.normalize(pos1, pos2)
	local function coordinate(pos, key)
		if type(pos) ~= "table" then return nil end
		local value = tonumber(pos[key])
		if not value then return nil end
		return math.floor(value)
	end
	local x1, y1, z1 = coordinate(pos1, "x"), coordinate(pos1, "y"), coordinate(pos1, "z")
	local x2, y2, z2 = coordinate(pos2, "x"), coordinate(pos2, "y"), coordinate(pos2, "z")
	if not (x1 and y1 and z1 and x2 and y2 and z2) then
		return nil, "a region needs two positions with numeric x, y and z"
	end
	return {
		pos1 = {x = math.min(x1, x2), y = math.min(y1, y2), z = math.min(z1, z2)},
		pos2 = {x = math.max(x1, x2), y = math.max(y1, y2), z = math.max(z1, z2)},
	}
end

---@param reg table
---@return table  -- {x =, y =, z =} in nodes
function region.size(reg)
	return {
		x = reg.pos2.x - reg.pos1.x + 1,
		y = reg.pos2.y - reg.pos1.y + 1,
		z = reg.pos2.z - reg.pos1.z + 1,
	}
end

---@param reg table
---@return integer
function region.volume(reg)
	local size = region.size(reg)
	return size.x * size.y * size.z
end

---@param reg table
---@param pos table  -- node position; fractional positions count as the node they are in
---@return boolean
function region.contains(reg, pos)
	if type(pos) ~= "table" then return false end
	local x, y, z = math.floor(pos.x), math.floor(pos.y), math.floor(pos.z)
	return x >= reg.pos1.x and x <= reg.pos2.x
		and y >= reg.pos1.y and y <= reg.pos2.y
		and z >= reg.pos1.z and z <= reg.pos2.z
end

-- The flat index of a position inside the region: x fastest, then y, then z -
-- the order VoxelManip numbers nodes. Returns nil for a position outside.
---@param reg table
---@param pos table
---@return integer|nil
function region.index(reg, pos)
	local size = region.size(reg)
	local dx = math.floor(pos.x) - reg.pos1.x
	local dy = math.floor(pos.y) - reg.pos1.y
	local dz = math.floor(pos.z) - reg.pos1.z
	if dx < 0 or dy < 0 or dz < 0 or dx >= size.x or dy >= size.y or dz >= size.z then
		return nil
	end
	return dz * size.y * size.x + dy * size.x + dx + 1
end

-- The inverse of index(): the position of a flat index, or nil when the index
-- is outside the region.
---@param reg table
---@param index integer
---@return table|nil
function region.position(reg, index)
	if type(index) ~= "number" or index % 1 ~= 0 then return nil end
	local size = region.size(reg)
	if index < 1 or index > region.volume(reg) then return nil end
	local zero = index - 1
	return {
		x = reg.pos1.x + zero % size.x,
		y = reg.pos1.y + math.floor(zero / size.x) % size.y,
		z = reg.pos1.z + math.floor(zero / (size.x * size.y)),
	}
end

-- The mapblocks a region touches, as the positions the mapblock-changed
-- callback hands out (the block's base corner).
---@param reg table
---@return table, table  -- first and last mapblock positions
function region.blocks(reg)
	local function base(value)
		return math.floor(value / 16) * 16
	end
	return {
		x = base(reg.pos1.x), y = base(reg.pos1.y), z = base(reg.pos1.z),
	}, {
		x = base(reg.pos2.x), y = base(reg.pos2.y), z = base(reg.pos2.z),
	}
end

---@param a table
---@param b table
---@return boolean
function region.overlaps(a, b)
	return a.pos1.x <= b.pos2.x and a.pos2.x >= b.pos1.x
		and a.pos1.y <= b.pos2.y and a.pos2.y >= b.pos1.y
		and a.pos1.z <= b.pos2.z and a.pos2.z >= b.pos1.z
end

return region
