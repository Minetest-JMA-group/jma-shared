-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

-- Sparse non-air nodes in increasing VoxelManip flat-index order:
--   LEB128  index delta (first relative to 0)
--   u16 LE  1-based name-table index
--   u8      param2
-- The caller owns the name table and compression; replay starts from air.

local snapshot = {}

---@class SnapshotEntry
---@field i integer  -- 1-based index in the region's flat array
---@field n integer  -- 1-based index into the snapshot's name table
---@field p integer? -- param2, 0 when absent

-- Incremental encoding keeps the capture walk's final step bounded.
---@return table  -- {add = fun(index, name, param2): boolean|nil, string?, finish = fun(): string}
function snapshot.encoder()
	local parts = {}
	local previous = 0
	local encoder = {}

	---@param index integer
	---@param name integer
	---@param param2 integer?
	---@return boolean|nil, string?
	function encoder:add(index, name, param2)
		-- Validate before touching `previous`: a rejected entry must not leave
		-- the encoder believing it has advanced.
		if type(index) ~= "number" or index % 1 ~= 0 or index <= previous then
			return nil, "snapshot entries must have whole, increasing indexes"
		end
		if type(name) ~= "number" or name % 1 ~= 0 or name < 1 or name > 65535 then
			return nil, "snapshot name index must be a whole number in 1..65535"
		end
		param2 = param2 or 0
		if type(param2) ~= "number" or param2 % 1 ~= 0 or param2 < 0 or param2 > 255 then
			return nil, "snapshot param2 must be a whole number in 0..255"
		end

		local delta = index - previous
		previous = index
		repeat
			local byte = delta % 128
			delta = math.floor(delta / 128)
			if delta > 0 then byte = byte + 128 end
			parts[#parts + 1] = string.char(byte)
		until delta == 0
		parts[#parts + 1] = string.char(name % 256, math.floor(name / 256) % 256, param2)
		return true
	end

	---@return string
	function encoder:finish()
		return table.concat(parts)
	end

	return encoder
end

---@param entries SnapshotEntry[]
---@return string|nil, string?
function snapshot.encode(entries)
	local encoder = snapshot.encoder()
	for k = 1, #entries do
		local entry = entries[k]
		local ok, err = encoder:add(entry.i, entry.n, entry.p)
		if not ok then return nil, err end
	end
	return encoder:finish()
end

---@param body string
---@return SnapshotEntry[]|nil, string?
function snapshot.decode(body)
	if type(body) ~= "string" then
		return nil, "snapshot body is not a string"
	end
	local entries = {}
	local position, length = 1, #body
	local previous = 0
	while position <= length do
		local delta, shift = 0, 0
		while true do
			if position > length then
				return nil, "snapshot body ends inside an index"
			end
			local byte = body:byte(position)
			position = position + 1
			delta = delta + (byte % 128) * 2 ^ shift
			if byte < 128 then break end
			shift = shift + 7
			if shift > 28 then
				return nil, "snapshot index is too large"
			end
		end
		if position + 2 > length then
			return nil, "snapshot body ends inside a node"
		end
		local name = body:byte(position) + body:byte(position + 1) * 256
		local param2 = body:byte(position + 2)
		position = position + 3
		if delta == 0 then
			return nil, "snapshot entry does not advance"
		end
		if name == 0 then
			return nil, "snapshot name index is zero"
		end
		previous = previous + delta
		entries[#entries + 1] = {i = previous, n = name, p = param2}
	end
	return entries
end

return snapshot
