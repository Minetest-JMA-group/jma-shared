-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

-- The lighting of a region, one byte per node in the same flat-array order the
-- snapshot uses (x fastest, then y, then z). A byte is the engine's own format:
-- the low 4 bits are skylight and the high 4 bits are artificial light.
--
-- Air is part of the layer and is the reason it cannot be sparse: the client
-- shades each face of a node with the light of the node in front of it, and
-- entities with the light of the node they stand in. A layer of non-air nodes
-- only would hold almost none of the values that make up the visible light.

local light = {}

local unpack = table.unpack or unpack

-- Bytes from a table of values, in chunks because string.char takes a bounded
-- number of arguments. Values outside a byte are clamped: a byte column is not
-- worth losing the snapshot over.
---@param values table
---@param volume integer
---@return string
function light.encode(values, volume)
	local parts = {}
	local chunk = {}
	for i = 1, volume do
		local value = math.floor(tonumber(values[i]) or 0)
		if value < 0 then
			value = 0
		elseif value > 255 then
			value = 255
		end
		chunk[#chunk + 1] = value
		if #chunk == 512 then
			parts[#parts + 1] = string.char(unpack(chunk))
			chunk = {}
		end
	end
	if #chunk > 0 then
		parts[#parts + 1] = string.char(unpack(chunk))
	end
	return table.concat(parts)
end

-- The values back, or nil when the body is not one byte per node.
---@param body string
---@param volume integer
---@return table|nil, string?
function light.decode(body, volume)
	if type(body) ~= "string" then
		return nil, "the light layer is not a string"
	end
	if #body ~= volume then
		return nil, string.format("the light layer has %d bytes for %d nodes", #body, volume)
	end
	local values = {}
	for i = 1, volume do
		values[i] = body:byte(i)
	end
	return values
end

return light
