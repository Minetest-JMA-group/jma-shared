-- SPDX-License-Identifier: MIT
-- ABNF from RFC 3629
--
-- UTF8-octets = *( UTF8-char )
-- UTF8-char = UTF8-1 / UTF8-2 / UTF8-3 / UTF8-4
-- UTF8-1 = %x00-7F
-- UTF8-2 = %xC2-DF UTF8-tail
-- UTF8-3 = %xE0 %xA0-BF UTF8-tail / %xE1-EC 2( UTF8-tail ) /
-- %xED %x80-9F UTF8-tail / %xEE-EF 2( UTF8-tail )
-- UTF8-4 = %xF0 %x90-BF 2( UTF8-tail ) / %xF1-F3 3( UTF8-tail ) /
-- %xF4 %x80-8F 2( UTF8-tail )
-- UTF8-tail = %x80-BF

-- 0xxxxxxx                            | 007F   (127)
-- 110xxxxx	10xxxxxx                   | 07FF   (2047)
-- 1110xxxx	10xxxxxx 10xxxxxx          | FFFF   (65535)
-- 11110xxx	10xxxxxx 10xxxxxx 10xxxxxx | 10FFFF (1114111)

utf8_simple = {}
local utf8_simple = _G.utf8_simple

local byte = string.byte
local sub = string.sub
local concat = table.concat

local function resolve_case_path()
	if core and core.get_modpath then
		local modname = core.get_current_modname()
		if modname then
			local mp = core.get_modpath(modname)
			if mp then
				return mp .. '/utf8_simple_case.lua'
			end
		end

		local mp = core.get_modpath('utf8_simple')
		if mp then
			return mp .. '/utf8_simple_case.lua'
		end
	end

	if debug and debug.getinfo then
		local info = debug.getinfo(1, 'S')
		if info and info.source and info.source:sub(1, 1) == '@' then
			local dir = info.source:match('^@(.+)/[^/]+$')
			if dir then
				return dir .. '/utf8_simple_case.lua'
			end
		end
	end

	return 'utf8_simple_case.lua'
end

local case_map = dofile(resolve_case_path())
local lower_map = case_map.lower
local upper_map = case_map.upper
local uppercase_chars = case_map.upper_chars
case_map = nil

-- helper function
local posrelat =
	function (pos, len)
		if pos < 0 then
			pos = len + pos + 1
		end

		return pos
	end

local function next_char(s, byte_index)
	local b1, b2, b3, b4 = byte(s, byte_index, byte_index + 3)

	if not b1 then
		return nil
	end

	if b1 <= 0x7F then
		return 1, b1, b1
	end

	local function is_cont(b)
		return b and b >= 0x80 and b <= 0xBF
	end

	if b1 >= 0xC2 and b1 <= 0xDF then
		if is_cont(b2) then
			local cp = ((b1 - 0xC0) * 0x40) + (b2 - 0x80)
			return 2, b1, cp
		end
		return 1, b1, b1
	end

	if b1 == 0xE0 then
		if b2 and b2 >= 0xA0 and b2 <= 0xBF and is_cont(b3) then
			local cp = ((b1 - 0xE0) * 0x1000) + ((b2 - 0x80) * 0x40) + (b3 - 0x80)
			return 3, b1, cp
		end
		return 1, b1, b1
	end

	if b1 >= 0xE1 and b1 <= 0xEC then
		if is_cont(b2) and is_cont(b3) then
			local cp = ((b1 - 0xE0) * 0x1000) + ((b2 - 0x80) * 0x40) + (b3 - 0x80)
			return 3, b1, cp
		end
		return 1, b1, b1
	end

	if b1 == 0xED then
		if b2 and b2 >= 0x80 and b2 <= 0x9F and is_cont(b3) then
			local cp = ((b1 - 0xE0) * 0x1000) + ((b2 - 0x80) * 0x40) + (b3 - 0x80)
			return 3, b1, cp
		end
		return 1, b1, b1
	end

	if b1 >= 0xEE and b1 <= 0xEF then
		if is_cont(b2) and is_cont(b3) then
			local cp = ((b1 - 0xE0) * 0x1000) + ((b2 - 0x80) * 0x40) + (b3 - 0x80)
			return 3, b1, cp
		end
		return 1, b1, b1
	end

	if b1 == 0xF0 then
		if b2 and b2 >= 0x90 and b2 <= 0xBF and is_cont(b3) and is_cont(b4) then
			local cp = ((b1 - 0xF0) * 0x40000) + ((b2 - 0x80) * 0x1000) + ((b3 - 0x80) * 0x40) + (b4 - 0x80)
			return 4, b1, cp
		end
		return 1, b1, b1
	end

	if b1 >= 0xF1 and b1 <= 0xF3 then
		if is_cont(b2) and is_cont(b3) and is_cont(b4) then
			local cp = ((b1 - 0xF0) * 0x40000) + ((b2 - 0x80) * 0x1000) + ((b3 - 0x80) * 0x40) + (b4 - 0x80)
			return 4, b1, cp
		end
		return 1, b1, b1
	end

	if b1 == 0xF4 then
		if b2 and b2 >= 0x80 and b2 <= 0x8F and is_cont(b3) and is_cont(b4) then
			local cp = ((b1 - 0xF0) * 0x40000) + ((b2 - 0x80) * 0x1000) + ((b3 - 0x80) * 0x40) + (b4 - 0x80)
			return 4, b1, cp
		end
		return 1, b1, b1
	end

	return 1, b1, b1
end

local function walk(s, handler)
	local byte_index = 1
	local slen = #s
	local visual = 0

	while byte_index <= slen do
		local width, lead, codepoint = next_char(s, byte_index)

		if not width then
			break
		end

		visual = visual + 1
		local stop = handler(visual, byte_index, width, lead, codepoint)

		byte_index = byte_index + width

		if stop then
			break
		end
	end
end

-- THE MEAT

-- maps f over s's utf8 characters f can accept args: (visual_index, utf8_character, byte_index)
utf8_simple.map =
	function (s, f, no_subs)
		walk(s, function (i, byte_index, width)
			if no_subs then
				f(i, width, byte_index)
			else
				f(i, sub(s, byte_index, byte_index + width - 1), byte_index)
			end
		end)
	end

-- THE REST

-- generator for the above -- to iterate over all utf8 chars
utf8_simple.chars =
	function (s, no_subs)
		return coroutine.wrap(function () return utf8_simple.map(s, coroutine.yield, no_subs) end)
	end

-- returns the number of characters in a UTF-8 string
utf8_simple.len =
	function (s)
		local count = 0

		walk(s, function ()
			count = count + 1
		end)

		return count
	end

-- replace all utf8 chars with mapping
	utf8_simple.replace =
		function (s, map)
			if not map then
				return s
			end

		local out = {}

		walk(s, function (_, byte_index, width)
			local chunk = sub(s, byte_index, byte_index + width - 1)
			local replacement = map[chunk]

			out[#out + 1] = replacement ~= nil and replacement or chunk
		end)

		return concat(out)
	end

-- reverse a utf8 string
utf8_simple.reverse =
	function (s)
		local chars = {}

		walk(s, function (_, byte_index, width)
			chars[#chars + 1] = sub(s, byte_index, byte_index + width - 1)
		end)

		local i, j = 1, #chars

		while i < j do
			chars[i], chars[j] = chars[j], chars[i]
			i = i + 1
			j = j - 1
		end

		return concat(chars)
	end

-- strip non-ascii characters from a utf8 string
utf8_simple.strip =
	function (s)
		local ascii = {}

		walk(s, function (_, byte_index, width, lead)
			if lead and lead <= 0x7F then
				ascii[#ascii + 1] = sub(s, byte_index, byte_index + width - 1)
			end
		end)

		return concat(ascii)
	end

-- like string.sub() but i, j are utf8 strings
-- a utf8-safe string.sub()
utf8_simple.sub =
	function (s, i, j)
		local l = utf8_simple.len(s)

		i =       posrelat(i, l)
		j = j and posrelat(j, l) or l

		if i < 1 then i = 1 end
		if j > l then j = l end

		if i > j or l == 0 then return '' end

		local start_byte, end_byte

		walk(s, function (idx, byte_index, width)
			if idx == i then
				start_byte = byte_index
			end

			if idx == j then
				end_byte = byte_index + width - 1
				return true
			end
		end)

			return sub(s, start_byte, end_byte)
		end

local function apply_case_map(s, mapping)
	if type(s) ~= 'string' then
		return ''
	end

	if s == '' then
		return ''
	end

	local out = {}
	local changed

	walk(s, function (_, byte_index, width, _, codepoint)
		local chunk = sub(s, byte_index, byte_index + width - 1)
		local replacement = mapping[codepoint]

		if replacement and replacement ~= chunk then
			changed = true
			out[#out + 1] = replacement
		else
			out[#out + 1] = chunk
		end
	end)

	if not changed then
		return s
	end

	return concat(out)
end

-- count uppercase characters using Unicode data
utf8_simple.count_caps =
	function (s)
		if type(s) ~= 'string' or s == '' then
			return 0
		end

		local count = 0

		walk(s, function (_, _, _, _, codepoint)
			if uppercase_chars[codepoint] then
				count = count + 1
			end
		end)

		return count
	end

-- convert to uppercase / lowercase using Unicode case mappings
utf8_simple.lower =
	function (s)
		return apply_case_map(s, lower_map)
	end

utf8_simple.upper =
	function (s)
		return apply_case_map(s, upper_map)
	end

-- return the codepoint of a single-character UTF-8 string
utf8_simple.codepoint =
	function (s)
		if type(s) ~= 'string' or s == '' then
			error('utf8_simple.codepoint: Non-string argument')
		end

		local value
		local seen = 0

		walk(s, function (_, _, _, _, codepoint)
			seen = seen + 1

			if seen == 1 then
				value = codepoint
			else
				return true
			end
		end)

		if seen ~= 1 then
			error('utf8_simple.codepoint: Not a single Unicode char')
		end

		return value
	end

return utf8_simple
