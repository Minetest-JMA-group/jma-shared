-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

local retention = {}
local common = recorder_common
local suffixes = {"", "-wal", "-shm"}

local function size(path)
	local total = 0
	for _, suffix in ipairs(suffixes) do
		local file = io.open(path .. suffix, "rb")
		if file then
			local bytes = file:seek("end")
			file:close()
			if not bytes then return nil end
			total = total + bytes
		end
	end
	return total
end

-- The generated name contains UTC start time. Convert civil dates directly,
-- without os.time's local timezone or daylight-saving interpretation.
local function started_at(name)
	local stamp = name:match("%-(%d%d%d%d%d%d%d%dT%d%d%d%d%d%dZ)%.sqlite$")
		or name:match("%-(%d%d%d%d%d%d%d%dT%d%d%d%d%d%dZ)%-%d+%.sqlite$")
	if not stamp then return nil end
	local y, m, d, h, min, sec = stamp:match("^(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)Z$")
	y, m, d = tonumber(y), tonumber(m), tonumber(d)
	if m <= 2 then y = y - 1 end
	local era = math.floor(y / 400)
	local year = y - era * 400
	local month = m + (m > 2 and -3 or 9)
	local days = era * 146097 + year * 365 + math.floor(year / 4)
		- math.floor(year / 100) + math.floor((153 * month + 2) / 5) + d - 1 - 719468
	local epoch = days * 86400 + tonumber(h) * 3600 + tonumber(min) * 60 + tonumber(sec)
	if os.date("!%Y%m%dT%H%M%SZ", epoch) ~= stamp then return nil end
	return epoch, tonumber(name:match("Z%-(%d+)%.sqlite$")) or 1
end

local function identity(path)
	local file = io.open(path, "rb")
	if not file then return false end
	local header = file:read(72)
	file:close()
	-- SQLite stores application_id big-endian at byte 69. Only recordings of
	-- this pack are eligible; unrelated databases in the directory are ignored.
	return header and #header == 72 and header:sub(1, 16) == "SQLite format 3\0"
		and header:sub(69, 72) == "JMAR"
end

local function normalized(path)
	local parts = {}
	for part in path:gmatch("[^/]+") do
		if part == ".." and #parts > 0 and parts[#parts] ~= ".." then
			table.remove(parts)
		elseif part ~= "." then
			parts[#parts + 1] = part
		end
	end
	return (path:sub(1, 1) == "/" and "/" or "") .. table.concat(parts, "/")
end

local function in_use()
	local paths = {}
	if type(recorder) == "table" and recorder.list then
		for _, entry in ipairs(recorder.list()) do
			if entry.path then paths[normalized(entry.path)] = true end
		end
	end
	if type(recorder_replay) == "table" and recorder_replay.sessions then
		for _, session in ipairs(recorder_replay.sessions.list()) do
			paths[normalized(session.path)] = true
		end
	end
	return paths
end

function retention.prune(now)
	local count_limit = tonumber(common.settings:get("recorder.retention_count"))
	local size_limit = tonumber(common.settings:get("recorder.retention_size_mb")) * 1024 * 1024
	local age_limit = tonumber(common.settings:get("recorder.retention_age"))
	if count_limit == 0 and size_limit == 0 and age_limit == 0 then return 0 end
	local dir = common.recordings_dir()
	local protected = in_use()
	local files, bytes = {}, 0
	for _, name in ipairs(core.get_dir_list(dir, false) or {}) do
		local path = dir .. "/" .. name
		local timestamp, sequence = started_at(name)
		if timestamp and identity(path) then
			local amount = size(path)
			if amount then
				files[#files + 1] = {
					path = path, started = timestamp, bytes = amount, sequence = sequence,
					stem = name:gsub("Z%-%d+%.sqlite$", "Z.sqlite"),
				}
				bytes = bytes + amount
			end
		end
	end
	table.sort(files, function(a, b)
		if a.started ~= b.started then return a.started < b.started end
		if a.stem ~= b.stem then return a.stem < b.stem end
		return a.sequence < b.sequence
	end)
	local count, removed = #files, 0
	now = now or os.time()
	for _, file in ipairs(files) do
		local expired = age_limit > 0 and now - file.started > age_limit
		local over = (count_limit > 0 and count > count_limit)
			or (size_limit > 0 and bytes > size_limit)
		if not protected[normalized(file.path)] and (expired or over) then
			local ok, err = os.remove(file.path)
			if ok then
				for i = 2, #suffixes do
					local path = file.path .. suffixes[i]
					local deleted, sidecar_err = os.remove(path)
					if not deleted and common.file_exists(path) then
						core.log("warning", "[recorder] cannot remove " .. path .. ": " .. tostring(sidecar_err))
					end
				end
				count, bytes, removed = count - 1, bytes - file.bytes, removed + 1
			else
				core.log("warning", "[recorder] retention cannot remove " .. file.path .. ": " .. tostring(err))
			end
		end
	end
	if removed > 0 then
		core.log("action", string.format("[recorder] retention removed %d recording(s)", removed))
	end
	return removed
end

-- Load-time cleanup also runs on worlds which only load the replay half.
-- Both active registries are consulted afresh before every cleanup.
retention.prune()
local elapsed = 0
core.register_globalstep(function(dtime)
	elapsed = elapsed + dtime
	if elapsed >= 60 then
		elapsed = 0
		retention.prune()
	end
end)
return retention
