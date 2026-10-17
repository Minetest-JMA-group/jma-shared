-- A stand-in for the parts of the engine the recorder touches, so that the real
-- init.lua and dbmanager.lua can be run outside a server. The tests drive the
-- server by hand: create players, move them, fire the callbacks, step the
-- globalsteps.

local M = {}

----------------------------------------------------------------------------
-- Just enough JSON to check what the recorder hands to core.write_json
----------------------------------------------------------------------------

local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function quote(str)
	return '"' .. str:gsub('[%z\1-\31\\"]', function(c)
		return ESCAPES[c] or string.format("\\u%04x", c:byte())
	end) .. '"'
end

local function is_array(t)
	local count = 0
	for key in pairs(t) do
		if type(key) ~= "number" then return false end
		count = count + 1
	end
	for i = 1, count do
		if t[i] == nil then return false end
	end
	return true
end

local function encode(value)
	local kind = type(value)
	if kind == "boolean" then return tostring(value) end
	if kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return nil, "cannot serialize a number like that"
		end
		if math.floor(value) == value then return string.format("%d", value) end
		return string.format("%.17g", value)
	end
	if kind == "string" then return quote(value) end
	if kind ~= "table" then
		-- The engine refuses functions and userdata the same way
		return nil, "cannot serialize a " .. kind
	end
	if next(value) == nil then
		-- The engine builds a table with lua_next(), so an empty one comes out
		-- as JSON null rather than as [] or {}. Tests that pass with [] here
		-- would not pass against the real thing.
		return "null"
	end
	local parts = {}
	if is_array(value) then
		for i = 1, #value do
			local encoded, err = encode(value[i])
			if not encoded then return nil, err end
			parts[#parts + 1] = encoded
		end
		return "[" .. table.concat(parts, ",") .. "]"
	end
	for key, item in pairs(value) do
		if type(key) ~= "string" then
			return nil, "cannot serialize a table with this key"
		end
		local encoded, err = encode(item)
		if not encoded then return nil, err end
		parts[#parts + 1] = quote(key) .. ":" .. encoded
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

M.encode = encode

----------------------------------------------------------------------------
-- Mock players
----------------------------------------------------------------------------

local function new_player(name)
	local player = {
		is_player_object = true,
		name = name,
		pos = { x = 0, y = 0, z = 0 },
		vel = { x = 0, y = 0, z = 0 },
		pitch = 0,
		yaw = 0,
		controls = {},
		wield = "",
		hp = 20,
		breath = 10,
		inventory = {},
	}
	player.get_player_name = function(self) return self.name end
	player.get_pos = function(self) return { x = self.pos.x, y = self.pos.y, z = self.pos.z } end
	player.get_velocity = function(self) return { x = self.vel.x, y = self.vel.y, z = self.vel.z } end
	player.get_look_vertical = function(self) return self.pitch end
	player.get_look_horizontal = function(self) return self.yaw end
	player.get_player_control = function(self) return self.controls end
	player.get_hp = function(self) return self.hp end
	player.get_breath = function(self) return self.breath end
	player.get_wielded_item = function(self)
		local who = self
		return { to_string = function() return who.wield end }
	end
	player.get_inventory = function(self)
		local who = self
		local function wrap(stack)
			return { to_string = function() return stack or "" end }
		end
		-- Both are called as methods, so the mock takes the InvRef first, the
		-- way the engine's InvRef does
		return {
			get_lists = function(_)
				local lists = {}
				for listname, stacks in pairs(who.inventory) do
					local list = {}
					for i, stack in ipairs(stacks) do
						list[i] = wrap(stack)
					end
					lists[listname] = list
				end
				return lists
			end,
			get_stack = function(_, listname, index)
				local stacks = who.inventory[listname]
				return wrap(stacks and stacks[index])
			end,
		}
	end
	return player
end

----------------------------------------------------------------------------
-- The mock engine
----------------------------------------------------------------------------

local CALLBACKS = {
	"register_on_joinplayer", "register_on_leaveplayer", "register_on_dieplayer",
	"register_on_respawnplayer", "register_on_player_hpchange", "register_on_punchplayer",
	"register_on_punchnode", "register_on_dignode", "register_on_placenode",
	"register_on_rightclickplayer", "register_on_craft", "register_on_item_eat",
	"register_on_item_pickup", "register_on_player_inventory_action",
	"register_on_chat_message", "register_on_chatcommand",
	"register_on_protection_violation", "register_on_cheat",
	"register_on_mapblocks_changed",
	"register_globalstep", "register_on_shutdown",
}

local function add_player(self, name, fields)
	local player = new_player(name)
	for key, value in pairs(fields or {}) do
		player[key] = value
	end
	self.players[name] = player
	self.by_name[name] = player
	table.insert(self.connected, player)
	return player
end

---@return table?  -- the player object as it was before it was forgotten
local function remove_player(self, name)
	local player = self.by_name[name]
	if not player then return nil end
	self.by_name[name] = nil
	for i, other in ipairs(self.connected) do
		if other == player then
			table.remove(self.connected, i)
			break
		end
	end
	return player
end

-- Call every function the mod registered for this engine callback.
local function fire(self, name, ...)
	for _, func in ipairs(self.callbacks[name] or {}) do
		func(...)
	end
end

-- One server step: the globalsteps run, as they do at the end of a step.
local function step(self, dtime)
	for _, func in ipairs(self.callbacks.register_globalstep or {}) do
		func(dtime or 0.1)
	end
end

local function steps(self, count, dtime)
	for _ = 1, count do
		step(self, dtime)
	end
end

---@param opts table?  -- world: directory to use as the world directory
---@return table
function M.new(opts)
	opts = opts or {}
	local mock = {
		world = opts.world or "/tmp/recorder_tests/world",
		players = {},    -- name -> mock player
		connected = {},  -- the online players, in the order they joined
		by_name = {},
		callbacks = {},  -- engine callback name -> registered functions
		chatcommands = {},
		privs = {},
		logs = {},
		settings = {},
		gametime = 4242,
	}
	local core = {}

	core.get_current_modname = function() return "recorder_capture" end
	core.get_modpath = function(name)
		if type(opts.modpaths) == "table" then return opts.modpaths[name] end
		return opts.modpath
	end
	core.get_worldpath = function() return mock.world end
	core.mkdir = function(path) return os.execute("mkdir -p '" .. path .. "'") end
	core.get_version = function() return { project = "Luanti", string = "5.14.0-mock" } end
	core.get_game_info = function() return { id = "mockgame", title = "Mock Game" } end
	core.get_gametime = function() return mock.gametime end
	core.get_connected_players = function() return mock.connected end
	core.get_player_by_name = function(name) return mock.by_name[name] end
	core.is_player = function(obj) return type(obj) == "table" and obj.is_player_object == true end
	core.write_json = function(data) return encode(data) end
	core.log = function(a, b)
		local level, message = a, b
		if b == nil then level, message = nil, a end
		mock.logs[#mock.logs + 1] = { level = level, message = message }
		if opts.print_logs then print(("[log] %s %s"):format(tostring(level), tostring(message))) end
	end

	core.settings = {}
	function core.settings.get(self, key) return mock.settings[key] end
	function core.settings.set(self, key, value) mock.settings[key] = value end
	function core.settings.get_bool(self, key) return mock.settings[key] == "true" end

	for _, name in ipairs(CALLBACKS) do
		core[name] = function(func)
			mock.callbacks[name] = mock.callbacks[name] or {}
			table.insert(mock.callbacks[name], func)
		end
	end
	core.register_chatcommand = function(name, definition)
		mock.chatcommands[name] = definition
	end
	core.register_privilege = function(name, definition)
		mock.privs[name] = definition
	end

	-- A tiny world behind the engine stand-in: nodes by position, content ids,
	-- emerge and a VoxelManip, so the snapshot and reconstruction paths can be
	-- driven without a server.
	local node_names = {"air", "ignore"}
	local node_ids = {air = 1, ignore = 2}
	mock.nodes = {}

	local function node_key(pos)
		return pos.x .. "," .. pos.y .. "," .. pos.z
	end

	mock.add_node_name = function(name)
		if not node_ids[name] then
			node_names[#node_names + 1] = name
			node_ids[name] = #node_names
		end
		return node_ids[name]
	end

	mock.set_node = function(pos, node)
		mock.add_node_name(node.name)
		mock.nodes[node_key(pos)] = {name = node.name, param2 = node.param2 or 0}
	end

	mock.get_node = function(pos)
		return mock.nodes[node_key(pos)] or {name = "air", param2 = 0}
	end

	core.CONTENT_AIR = 1
	core.CONTENT_IGNORE = 2
	core.get_content_id = function(name) return node_ids[name] or 0 end
	core.get_name_from_content_id = function(id) return node_names[id] end
	core.set_node = function(pos, node) mock.set_node(pos, node) end
	core.get_node = function(pos) return mock.get_node(pos) end
	core.pos_to_string = function(pos)
		return string.format("(%s,%s,%s)", tostring(pos.x), tostring(pos.y), tostring(pos.z))
	end
	core.compress = function(data) return data end
	core.decompress = function(data) return data end

	core.EMERGE_GENERATED = 1
	core.EMERGE_FROM_MEMORY = 2
	core.EMERGE_FROM_DISK = 3
	core.EMERGE_CANCELLED = 4
	core.EMERGE_ERRORED = 5
	core.emerge_area = function(p1, p2, callback)
		-- The mock has everything already: one callback ends the phase.
		if callback then
			callback({x = p1.x, y = p1.y, z = p1.z}, core.EMERGE_FROM_MEMORY, 0)
		end
		return true
	end

	-- A block hash that can be undone, for the mapblock-changed callback.
	local BLOCK_BIAS = 512
	core.hash_node_position = function(pos)
		local bx = math.floor(pos.x / 16) + BLOCK_BIAS
		local by = math.floor(pos.y / 16) + BLOCK_BIAS
		local bz = math.floor(pos.z / 16) + BLOCK_BIAS
		return (bx * 1024 + by) * 1024 + bz
	end
	core.get_position_from_hash = function(hash)
		local bz = hash % 1024
		hash = math.floor(hash / 1024)
		local by = hash % 1024
		local bx = math.floor(hash / 1024)
		return {
			x = (bx - BLOCK_BIAS) * 16,
			y = (by - BLOCK_BIAS) * 16,
			z = (bz - BLOCK_BIAS) * 16,
		}
	end

	core.objects_in_area = function(min, max)
		local found = {}
		for _, player in ipairs(mock.connected) do
			-- The engine filters on the object's position; read the stored field
			-- so an object whose get_pos raises is still returned - the mod is
			-- expected to survive that, and a test can rely on it.
			local pos = player.pos
			if pos and pos.x >= min.x and pos.x <= max.x
				and pos.y >= min.y and pos.y <= max.y
				and pos.z >= min.z and pos.z <= max.z then
				found[#found + 1] = player
			end
		end
		local index = 0
		return function()
			index = index + 1
			return found[index]
		end
	end

	core.get_voxel_manip = function(p1, p2)
		local emerged1 = {x = p1.x, y = p1.y, z = p1.z}
		local emerged2 = {x = p2.x, y = p2.y, z = p2.z}
		local size = {x = p2.x - p1.x + 1, y = p2.y - p1.y + 1, z = p2.z - p1.z + 1}
		local volume = size.x * size.y * size.z
		local data, param2 = {}, {}

		local function index_of(pos)
			local dx = math.floor(pos.x) - emerged1.x
			local dy = math.floor(pos.y) - emerged1.y
			local dz = math.floor(pos.z) - emerged1.z
			if dx < 0 or dy < 0 or dz < 0 or dx >= size.x or dy >= size.y or dz >= size.z then
				return nil
			end
			return dz * size.y * size.x + dy * size.x + dx + 1
		end

		local function position_of(index)
			local zero = index - 1
			return {
				x = emerged1.x + zero % size.x,
				y = emerged1.y + math.floor(zero / size.x) % size.y,
				z = emerged1.z + math.floor(zero / (size.x * size.y)),
			}
		end

		local vm = {liquids_updated = false}
		function vm:read_from_map()
			for i = 1, volume do
				local node = mock.get_node(position_of(i))
				data[i] = node_ids[node.name] or 0
				param2[i] = node.param2 or 0
			end
			return emerged1, emerged2
		end
		function vm:get_emerged_area() return emerged1, emerged2 end
		function vm:get_data() return data end
		function vm:get_param2_data() return param2 end
		function vm:set_data(value) data = value end
		function vm:set_param2_data(value) param2 = value end
		function vm:get_node_at(pos)
			local index = index_of(pos)
			if not index then return nil end
			return {name = node_names[data[index]] or "unknown", param2 = param2[index]}
		end
		function vm:set_node_at(pos, node)
			local index = index_of(pos)
			if not index then return end
			mock.add_node_name(node.name)
			data[index] = node_ids[node.name]
			param2[index] = node.param2 or 0
		end
		function vm:update_liquids() vm.liquids_updated = true end
		function vm:write_to_map()
			for i = 1, volume do
				mock.set_node(position_of(i), {
					name = node_names[data[i]] or "air",
					param2 = param2[i],
				})
			end
		end
		function vm:close() end
		return vm
	end

	-- Asking for a callback the mock does not have is a bug in the mock, and
	-- not a reason for the mod to quietly stop recording something.
	setmetatable(core, {
		__index = function(_, key)
			if type(key) == "string" and key:match("^register_") then
				error("mock core has no " .. key .. " (add it to CALLBACKS)", 2)
			end
			return nil
		end,
	})

	mock.core = core
	mock.add_player = function(...) return add_player(mock, ...) end
	mock.remove_player = function(...) return remove_player(mock, ...) end
	mock.fire = function(...) return fire(mock, ...) end
	mock.step = function(...) return step(mock, ...) end
	mock.steps = function(...) return steps(mock, ...) end
	return mock
end

return M
