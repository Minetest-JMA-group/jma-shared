-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2023-2026 Marko Petrović
---@diagnostic disable: need-check-nil

algorithms = {}
local utf8_simple = utf8_simple

-- Dummy implementations of C++ functions
algorithms.execute = function(argv_table) return "","[algorithms]: Function not implemented", 38 end

local modstorage = {}
local already_loaded = {}
local c_mods = {}
local trusted_mods = {}
local ie = core.request_insecure_environment()
local settings = core.settings
-- For messages on startup. Set to false if you're aware what doesn't work and are fine with it.
local verbose = settings:get_bool("algorithms.verbose", true)
local list = settings:get("secure.c_mods") or ""
local world_path = core.get_worldpath()
-- Attempt to avoid tampering with function used to guard insecure env
local get_current_modname = core.get_current_modname
algorithms.XATTR_CREATE = 1
algorithms.XATTR_REPLACE = 2
-- Btrfs default nodesize
local MAX_XATTR_SIZE = 16*1024

for word in list:gmatch("[^,%s]+") do
	c_mods[word] = true
end

list = settings:get("secure.trusted_mods") or ""
for word in list:gmatch("[^,%s]+") do
	trusted_mods[word] = true
end
---@diagnostic disable-next-line: cast-local-type
list = nil


-- A small wrapper around require that handles the issue when the loaded module uses require itself
-- Use this instead of ie.require directly
-- Require only secure.c_mods because in practice it's a shared object load like load_library
algorithms.require = function(libname)
	local modname = get_current_modname()
	if not modname then
		error("algorithms.require can only be called during load time")
	end
	if not ie then
		core.log("warning", "["..modname.."]: Attempted to use require through algorithms, but algorithms is not in secure.trusted_mods")
		return nil
	end

	if not c_mods[modname] and not trusted_mods[modname] then
		core.log("warning", "["..modname.."]: Attempted to use require without permission!")
		return nil
	end

	local old_require = require
	require = ie.require
	local lib = require(libname)
	require = old_require
	return lib
end

local jit = algorithms.require("jit")
if jit then
	algorithms.os = jit.os
elseif verbose then
	core.log("warning", "[algorithms]: Cannot determine the current platform")
end

-- Load the shared library lib<modname>.so in the mod folder of the calling mod, or on path libpath relative to the mod folder
algorithms.load_library = function(libpath)
	local modname = get_current_modname()
	if not modname then
		core.log("warning", "Cannot load library. Some mod called algorithms.load_library outside load time")
		return false
	end
	if not ie then
		core.log("warning", "["..modname.."]: Attempted to load shared object file through algorithms, but algorithms is not in secure.trusted_mods")
		return false
	end

	if not c_mods[modname] and not trusted_mods[modname] then
		core.log("warning", "["..modname.."]: Attempted to load shared object file without permission!")
		return false
	end

	if already_loaded[modname] then
		return true
	end

	local MP = core.get_modpath(modname)
	local libinit, err
	if type(libpath) == "string" then
		libinit, err = ie.package.loadlib(MP.."/"..libpath, "luaopen_mylibrary")
	else
		if algorithms.os == "Windows" then
			libinit, err = ie.package.loadlib(MP.."/lib"..modname..".dll", "luaopen_mylibrary")
		elseif algorithms.os == "Linux" then
			libinit, err = ie.package.loadlib(MP.."/lib"..modname..".so", "luaopen_mylibrary")
		else
			core.log("warning", "["..modname.."]: Cannot determine a shared object file extension on a platform unknown to algorithms")
			return false
		end
	end
	if not libinit and err then
		core.log("warning", "["..modname.."]: Failed to load shared object file")
		core.log("warning", "["..modname.."]: "..err)
		return false
	end

	local ret = libinit()
	if ret and ret ~= 0 then
		core.log("warning", "["..modname.."]: Failed to load shared object file")
		core.log("warning", "["..modname.."]: Exited with code: "..tostring(ret))
		return false
	end
	already_loaded[modname] = true
	return true
end

if not verbose then
	local old_core_log = core.log
	core.log = function() end
	algorithms.load_library()
	core.log = old_core_log
elseif not algorithms.load_library() then
	core.log("warning", "[algorithms]: C++ functions will not work")
end

-- Move privileged functions to a local guarded table
-- We can't do this immediately because the C module can only store execute in a global table
local insecure_env = {
	execute = algorithms.execute,
}
algorithms.execute = nil

if algorithms.os ~= "Linux" then
	local dummy = function() return "[algorithms]: Function not implemented", 38 end
	insecure_env.setxattr = dummy
	insecure_env.getxattr = dummy
	insecure_env.write = dummy
	insecure_env.read = dummy
	insecure_env.fcntl = dummy
	insecure_env.mkfifo = dummy
	insecure_env.signal = dummy
	insecure_env.open = dummy
	insecure_env.close = dummy
	algorithms.get_xattr_storage = function()
		return {
			setxattr = insecure_env.setxattr,
			getxattr = insecure_env.getxattr
		}
	end

	algorithms.errno = {}
	algorithms.fcntl = {}
	algorithms.signal = {}
else
	local MP = core.get_modpath(get_current_modname())
	algorithms.errno = dofile(MP.."/linuxerrno.lua")
	algorithms.fcntl = dofile(MP.."/linuxfcntl.lua")
	algorithms.signal = dofile(MP.."/linuxsignal.lua")

	local ffi = algorithms.require("ffi")
	ffi.cdef[[
		int setxattr(const char *path, const char *name, const void *value, size_t size, int flags);
		int removexattr(const char *path, const char *name);
		typedef long ssize_t;
		ssize_t getxattr(const char *path, const char *name, void *value, size_t size);
		int mkfifo(const char *pathname, mode_t mode);
		ssize_t read(int fd, void *buf, size_t count);
		ssize_t write(int fd, const void *buf, size_t count);
		int fcntl(int fd, int cmd, ...);
		char *strerror(int errnum);
		typedef void (*sighandler_t)(int);
		sighandler_t signal(int signum, sighandler_t handler);
		int open(const char *pathname, int flags, ...);
		int close(int fd);
		int unlink(const char *path);
	]]
	algorithms.signal.SIG_DFL = ffi.cast("sighandler_t", 0)
	algorithms.signal.SIG_IGN = ffi.cast("sighandler_t", 1)
	algorithms.signal.SIG_ERR = ffi.cast("sighandler_t", -1)

	-- Return: err (string or nil), errno (number or nil)
	insecure_env.setxattr = function(path, name, value, flags)
		flags = flags or 0
		if type(path) ~= "string" or type(name) ~= "string" or type(flags) ~= "number" or flags ~= math.floor(flags) then
			return "Invalid argument", algorithms.errno.EINVAL
		end
		local ret
		if not value then
			ret = ffi.C.removexattr(path, name)
		else
			if type(value) ~= "string" then
				return "Invalid argument", algorithms.errno.EINVAL
			end
			ret = ffi.C.setxattr(path, name, value, #value, flags)
		end
		if ret ~= 0 then
			local errnum = ffi.errno()
			return ffi.string(ffi.C.strerror(errnum)), errnum
		end
	end

	-- Return: value (string or nil), err (string or nil), errno (number or nil)
	insecure_env.getxattr = function(path, name)
		if type(path) ~= "string" or type(name) ~= "string" then
			return nil, "Invalid argument", algorithms.errno.EINVAL
		end
		-- No need to free in Lua; it's freed automatically
		local buf = ffi.new("uint8_t[?]", MAX_XATTR_SIZE)

		local ret = ffi.C.getxattr(path, name, buf, MAX_XATTR_SIZE)
		if ret < 0 then
			local errnum = ffi.errno()
			local errstr = ffi.string(ffi.C.strerror(errnum))
			return nil, errstr, errnum
		end
		return ffi.string(buf, ret)
	end

	-- Return: err (string or nil), errno (number or nil)
	insecure_env.mkfifo = function(path, mode)
		if type(path) ~= "string" or type(mode) ~= "number" or mode ~= math.floor(mode) then
			return "Invalid argument", algorithms.errno.EINVAL
		end
		local ret = ffi.C.mkfifo(path, mode)
		if ret ~= 0 then
			local errnum = ffi.errno()
			return ffi.string(ffi.C.strerror(errnum)), errnum
		end
	end

	-- Return: data (string or nil(on EOF or error)), err (string or nil), errno (number or nil)
	insecure_env.read = function(fd, size)
		if type(fd) ~= "number" or type(size) ~= "number" or fd ~= math.floor(fd) or size ~= math.floor(size) then
			return nil, "Invalid argument", algorithms.errno.EINVAL
		end
		if size <= 0 then
			return "", nil, nil
		end

		-- No need to free in Lua; it's freed automatically
		local buf = ffi.new("uint8_t[?]", size)
		local ret = ffi.C.read(fd, buf, size)

		if ret < 0 then
			local errnum = ffi.errno()
			local errstr = ffi.string(ffi.C.strerror(errnum))
			return nil, errstr, errnum
		end
		if ret == 0 then
			return nil, nil, nil -- EOF
		end
		return ffi.string(buf, ret)
	end

	-- Return: bytes_written (number or nil), err (string or nil), errno (number or nil)
	insecure_env.write = function(fd, buf)
		if type(buf) ~= "string" or type(fd) ~= "number" or fd ~= math.floor(fd) then
			return nil, "Invalid argument", algorithms.errno.EINVAL
		end
		if #buf == 0 then
			return 0, nil, nil
		end

		local ret = ffi.C.write(fd, buf, #buf)

		if ret < 0 then
			local errnum = ffi.errno()
			local errstr = ffi.string(ffi.C.strerror(errnum))
			return nil, errstr, errnum
		end
		return ret
	end

	-- Variadic fcntl implementation
	-- Return: result (number or nil), err (string or nil), errno (number or nil)
	insecure_env.fcntl = function(fd, op, ...)
		if type(fd) ~= "number" or type(op) ~= "number" or fd ~= math.floor(fd) or op ~= math.floor(op) then
			return nil, "Invalid argument", algorithms.errno.EINVAL
		end
		local args = {...}
		local arg_count = select('#', ...)

		local ret
		if arg_count == 0 then
			ret = ffi.C.fcntl(fd, op)
		elseif arg_count == 1 then
			local arg = args[1]
			if type(arg) == "number" and arg == math.floor(arg) then
				ret = ffi.C.fcntl(fd, op, arg)
			end
		elseif arg_count == 2 then
			local arg1, arg2 = args[1], args[2]
			if type(arg1) == "number" and type(arg2) == "number" and arg1 == math.floor(arg1) and arg2 == math.floor(arg2) then
				ret = ffi.C.fcntl(fd, op, arg1, arg2)
			end
		else
			return nil, "Too many arguments for fcntl", algorithms.errno.EINVAL
		end

		if not ret then
			return nil, "Invalid argument", algorithms.errno.EINVAL
		end
		if ret < 0 then
			local errnum = ffi.errno()
			local errstr = ffi.string(ffi.C.strerror(errnum))
			return nil, errstr, errnum
		end
		return ret
	end

	-- Return: err (string or nil), errno (number or nil)
	insecure_env.signal = function(signum, action)
		if type(signum) ~= "number" or signum ~= math.floor(signum)
		   or (action ~= algorithms.signal.SIG_DFL and action ~= algorithms.signal.SIG_IGN) then
			return "Invalid argument", algorithms.errno.EINVAL
		end
		local ret = ffi.C.signal(signum, action)
		if ret == algorithms.signal.SIG_ERR then
			local errnum = ffi.errno()
			local errstr = ffi.string(ffi.C.strerror(errnum))
			return errstr, errnum
		end
	end

	-- Return: new fd (number or nil), err (string or nil), errno (number or nil)
	insecure_env.open = function(path, flags, ...)
		if type(path) ~= "string" or type(flags) ~= "number" or flags ~= math.floor(flags) then
			return nil, "Invalid argument", algorithms.errno.EINVAL
		end
		local args = {...}
		local arg_count = select('#', ...)
		if arg_count > 1 then
			return nil, "Invalid argument", algorithms.errno.EINVAL
		end

		local ret
		if arg_count == 1 then
			local mode = args[1]
			if type(mode) ~= "number" or mode ~= math.floor(mode) then
				return nil, "Invalid argument", algorithms.errno.EINVAL
			end
			ret = ffi.C.open(path, flags, mode)
		else
			ret = ffi.C.open(path, flags)
		end
		if ret < 0 then
			local errnum = ffi.errno()
			local errstr = ffi.string(ffi.C.strerror(errnum))
			return nil, errstr, errnum
		end
		return ret
	end

	-- Return: err (string or nil), errno (number or nil)
	insecure_env.close = function(fd)
		if type(fd) ~= "number" or fd ~= math.floor(fd) then
			return "Invalid argument", algorithms.errno.EINVAL
		end
		local ret = ffi.C.close(fd)
		if ret == -1 then
			local errnum = ffi.errno()
			local errstr = ffi.string(ffi.C.strerror(errnum))
			return errstr, errnum
		end
	end

	-- Return: err (string or nil), errno (number or nil)
	insecure_env.unlink = function(path)
		if type(path) ~= "string" then
			return "Invalid argument", algorithms.errno.EINVAL
		end
		local ret = ffi.C.unlink(path)
		if ret == -1 then
			local errnum = ffi.errno()
			local errstr = ffi.string(ffi.C.strerror(errnum))
			return errstr, errnum
		end
	end

	local function normalize(path)
		local parts = {}
		for part in path:gmatch("[^/]+") do
			if part == ".." then
				table.remove(parts)
			elseif part ~= "." and part ~= "" then
				table.insert(parts, part)
			end
		end
		local prefix = path:sub(1,1) == "/" and "/" or ""
		return prefix .. table.concat(parts, "/")
	end
	local function check_path(path, prefix)
		if type(path) ~= "string" then
			return false
		end
		path = normalize(path)
		return path:sub(1, #prefix) == prefix
	end
	world_path = normalize(world_path)

	-- Unlike insecure functions, these ones allow only path under world_dir/modname and treat paths as relative to that.
	algorithms.get_xattr_storage = function()
		local modname = get_current_modname()
		if not modname then
			return nil
		end
		local prefix = world_path.."/"..modname.."/"
		core.mkdir(prefix)
		return {
			setxattr = function(path, name, value, flags)
				path = prefix..path
				if not check_path(path, prefix) then
					return "Invalid argument", algorithms.errno.EINVAL
				end
				return insecure_env.setxattr(path, name, value, flags)
			end,
			getxattr = function(path, name)
				path = prefix..path
				if not check_path(path, prefix) then
					return nil, "Invalid argument", algorithms.errno.EINVAL
				end
				return insecure_env.getxattr(path, name)
			end
		}
	end
end

algorithms.bit = algorithms.require("bit")
if not algorithms.bit and verbose then
	core.log("warning", "[algorithms]: bit module not available")
end

algorithms.request_insecure_environment = function()
	local modname = get_current_modname()
	if not ie then
		core.log("warning", "["..modname.."]: requested insecure_env from algorithms. algorithms cannot provide it because it is not in secure.trusted_mods")
		return nil
	end
	if not trusted_mods[modname] then
		return nil
	else
		return insecure_env
	end
end

-- Check whether the value `value` exists in an indexed table `t`
algorithms.table_contains = function(t, value)
	if type(t) ~= "table" then
		return false
	end
	for _, val in ipairs(t) do
		if val == value then
			return true
		end
	end
	return false
end

-- Return modstorage object, but also save it in modstorage[modname] for later use
algorithms.get_mod_storage = function()
	local modname = get_current_modname()
	if not modname then
		error("algorithms.get_mod_storage can only be called during load time")
	end
	modstorage[modname] = core.get_mod_storage()
	return modstorage[modname]
end

-- Deserialize and return the object stored under the key `key` in either `s` - the modstorage passed as an argument, or modstorage[modname]
-- If there is no object referenced under the key `key` return `default`
algorithms.getconfig = function(key, default, s)
	local modname = get_current_modname()
	local storage = s or modstorage[modname]
	if type(key) ~= "string" or not storage then
		return default
	end
	if storage:contains(key) then
		return core.deserialize(storage:get_string(key))
	else
		return default
	end
end

local unit_to_secs = {
	s = 1, m = 60, h = 3600,
	D = 86400, W = 604800, M = 2592000, Y = 31104000,
	[""] = 1,
}
-- Convert input using time labels (s, m, h, etc) into seconds
algorithms.parse_time = function(t)
	if type(t) ~= "string" then
		return 0
	end
	local secs = 0
	for num, unit in t:gmatch("(%d+)([smhDWMY]?)") do
		secs = secs + (tonumber(num) * (unit_to_secs[unit] or 1))
	end
	return secs
end

local function checkPlural(timeNum, timeStr)
	if timeNum == 1 then
		return timeStr
	end
	return timeStr.."s"
end
-- Convert time in seconds to rounded human-readable string
algorithms.time_to_string = function(sec)
	if type(sec) ~= "number" then
		return ""
	end
	sec = math.floor(sec)

	local min = math.floor(sec / 60)
	sec = sec % 60
	local hour = math.floor(min / 60)
	min = min % 60
	local day = math.floor(hour / 24)
	hour = hour % 24
	local month = math.floor(day / 30)
	day = day % 30
	local year = math.floor(month / 12)
	month = month % 12

	if year > 0 then
		return "more than a year"
	end
	if month > 0 then
		return tostring(month) .. " " .. checkPlural(month, "month")
	end
	if day > 0 then
		return tostring(day) .. " " .. checkPlural(day, "day")
	end
	if hour > 0 then
		return tostring(hour) .. " " .. checkPlural(hour, "hour")
	end
	if min > 0 then
		return tostring(min) .. " " .. checkPlural(min, "minute")
	end
	return tostring(sec) .. " " .. checkPlural(sec, "second")
end

-- Separate the string into n-grams
algorithms.nGram = function(string, window_size)
	if type(string) ~= "string" or type(window_size) ~= "number" then
		return {}
	end
	window_size = math.floor(window_size) - 1
	local string_len = utf8_simple.len(string)
	if window_size >= string_len then
		return {string}
	end
	local ret = {}
	for i = 1, string_len - window_size do
		table.insert(ret, utf8_simple.sub(string, i, i+window_size))
	end
	return ret
end

-- Create a matrix of integers with dimensions n x m
algorithms.createMatrix = function(n, m)
	if type(n) ~= "number" or type(m) ~= "number" then
		return nil
	end
	n = math.floor(n)
	m = math.floor(m)

	local matrix = {}
	for i = 1, n do
		matrix[i] = {}
		for j = 1, m do
			matrix[i][j] = 0
		end
	end
	return matrix
end

-- Matrix to human-readable string
algorithms.matostr = function(matrix)
	if type(matrix) ~= "table" then
		return "Error: algorithms.matostr didn't receive a matrix"
	end

	local pr = ""
	for _, row in ipairs(matrix) do
		if type(row) ~= "table" then
			return "Error: algorithms.matostr didn't receive a matrix"
		end
		for _, elem in ipairs(row) do
			pr = pr..tostring(elem) .. " "
		end
		pr = pr.."\n"
	end
	return pr
end

-- Check if two tables have a common key and what it is
algorithms.hasCommonKey = function(tbl1, tbl2)
	if type(tbl1) ~= "table" or type(tbl2) ~= "table" then
		return false
	end

	for key, _ in pairs(tbl1) do
		if tbl2[key] then
			return true, key
		end
	end
	return false
end

-- Longest Common Substring
algorithms.lcs = function(string1, string2)
	if type(string1) ~= "string" or type(string2) ~= "string" then
		return nil
	end
	local len1 = utf8_simple.len(string1)
	local len2 = utf8_simple.len(string2)

	local matrix = algorithms.createMatrix(len1+1, len2+1)
	for i = 2, len1 + 1 do
		for j = 2, len2 + 1 do
			if utf8_simple.sub(string1,i-1,i-1) == utf8_simple.sub(string2,j-1,j-1) then
				matrix[i][j] = matrix[i-1][j-1] + 1
			else
				matrix[i][j] = math.max(matrix[i-1][j], matrix[i][j-1])
			end
		end
	end

	local i = len1 + 1
	local j = len2 + 1
	local res = ""
	while matrix[i][j] ~= 0 do
		local oldi = i
		local oldj = j
		while matrix[oldi][oldj] == matrix[i][j] do
			i = i - 1
		end
		i = i + 1	-- Go back to the last pos where condition was true
		while matrix[oldi][oldj] == matrix[i][j] do
			j = j - 1
		end
		j = j + 1	-- Go back to the last pos where condition was true

		res = res..utf8_simple.sub(string1, i-1, i-1)
		i = i - 1
		j = j - 1
	end

	return utf8_simple.reverse(res)
end
