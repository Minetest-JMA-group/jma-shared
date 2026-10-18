-- A stand-in for the parts of the engine the recorder touches, so that the real
-- init.lua and dbmanager.lua can be run outside a server. The tests drive the
-- server by hand: create players, move them, fire the callbacks, step the
-- globalsteps.

local M = {}

local unpack = table.unpack or unpack

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
		meta = {},
		privs = {},
	}
	player.get_player_name = function(self) return self.name end
	player.is_player = function(self) return true end
	player.get_pos = function(self) return { x = self.pos.x, y = self.pos.y, z = self.pos.z } end
	player.set_pos = function(self, pos)
		self.pos = { x = pos.x, y = pos.y, z = pos.z }
	end
	player.get_velocity = function(self) return { x = self.vel.x, y = self.vel.y, z = self.vel.z } end
	player.get_look_vertical = function(self) return self.pitch end
	player.get_look_horizontal = function(self) return self.yaw end
	player.get_player_control = function(self) return self.controls end
	player.get_hp = function(self) return self.hp end
	player.get_breath = function(self) return self.breath end
	player.get_properties = function(self)
		return {
			visual = "mesh",
			mesh = "character.b3d",
			textures = { self.texture or "character.png" },
		}
	end
	player.get_meta = function(self)
		return {
			set_string = function(_, key, value) self.meta[key] = value end,
			get_string = function(_, key) return self.meta[key] or "" end,
		}
	end
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
			get_size = function(_, listname)
				return #(who.inventory[listname] or {})
			end,
			get_list = function(_, listname)
				local out = {}
				for i, stack in ipairs(who.inventory[listname] or {}) do
					out[i] = wrap(stack)
				end
				return out
			end,
			set_list = function(_, listname, list)
				local stacks = {}
				for i, stack in ipairs(list) do
					stacks[i] = stack:to_string()
				end
				who.inventory[listname] = stacks
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
	"register_on_player_receive_fields",
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

-- One server step: due timers run, then the globalsteps do, as they do at the
-- end of a step.
local function step(self, dtime)
	dtime = dtime or 0.1
	if self.run_timers then self.run_timers(dtime) end
	for _, func in ipairs(self.callbacks.register_globalstep or {}) do
		func(dtime)
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

	core.get_current_modname = function() return mock.current_modname or "recorder_capture" end
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
	core.check_player_privs = function(name, wanted)
		local player = mock.by_name[name]
		local held = player and player.privs or {}
		local missing = {}
		for priv in pairs(wanted or {}) do
			if not held[priv] then missing[priv] = true end
		end
		if next(missing) == nil then return true end
		return false, missing
	end
	core.get_player_privs = function(name)
		local player = mock.by_name[name]
		return player and player.privs or {}
	end
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

	-- Timers run at the start of the next step, which is the ordering the mod
	-- code relies on when it defers work past an engine callback.
	mock.timers = {}
	mock.timer_clock = 0
	mock.run_timers = function(dtime)
		mock.timer_clock = mock.timer_clock + dtime
		local due = {}
		for i = #mock.timers, 1, -1 do
			if mock.timers[i].due <= mock.timer_clock then
				table.insert(due, 1, table.remove(mock.timers, i))
			end
		end
		for _, timer in ipairs(due) do
			timer.func(unpack(timer.args))
		end
	end
	core.after = function(delay, func, ...)
		mock.timers[#mock.timers + 1] = {
			due = mock.timer_clock + (delay or 0),
			func = func,
			args = {...},
		}
		return true
	end

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
	--
	-- The numbering follows the engine: a registered node gets an id from 0
	-- upwards, and the three special ids sit above them. That matters because
	-- 0 is a perfectly valid id for the first node registered.
	local node_names = {[125] = "unknown", [126] = "air", [127] = "ignore"}
	local node_ids = {unknown = 125, air = 126, ignore = 127}
	local next_node_id = 0
	mock.nodes = {}

	local function node_key(pos)
		return pos.x .. "," .. pos.y .. "," .. pos.z
	end

	mock.add_node_name = function(name)
		if node_ids[name] == nil then
			node_ids[name] = next_node_id
			node_names[next_node_id] = name
			next_node_id = next_node_id + 1
		end
		return node_ids[name]
	end

	mock.set_node = function(pos, node)
		mock.add_node_name(node.name)
		mock.nodes[node_key(pos)] = {
			name = node.name,
			param2 = node.param2 or 0,
			light = node.light or 0,
		}
	end

	mock.get_node = function(pos)
		return mock.nodes[node_key(pos)] or {name = "air", param2 = 0, light = 0}
	end

	core.CONTENT_UNKNOWN = 125
	core.CONTENT_AIR = 126
	core.CONTENT_IGNORE = 127
	-- The engine raises for a name it does not know; anything resolving a name
	-- from a recording has to survive that, so the mock raises too.
	core.get_content_id = function(name)
		local id = node_ids[name]
		if id == nil then
			error("Unknown node: " .. tostring(name), 2)
		end
		return id
	end
	core.get_name_from_content_id = function(id) return node_names[id] end
	core.set_node = function(pos, node) mock.set_node(pos, node) end
	core.get_node = function(pos) return mock.get_node(pos) end
	-- A registered node becomes a content id straight away, as it does in the
	-- engine; the definition itself is kept for tests that want to inspect it.
	mock.node_defs = {}
	core.register_node = function(name, def)
		mock.node_defs[name] = def
		mock.add_node_name(name)
	end

	-- Node metadata over a table, shaped like the engine's NodeMetaRef:
	-- to_table() hands inventory slots back as ItemStack userdata, which is
	-- exactly what the recorder has to normalize before serializing.
	mock.node_meta = {}
	local function copy_table(value)
		if type(value) ~= "table" then return value end
		local out = {}
		for k, v in pairs(value) do out[k] = copy_table(v) end
		return out
	end
	local function meta_entry(key)
		local entry = mock.node_meta[key]
		if not entry then
			entry = {fields = {}, inventory = {}}
			mock.node_meta[key] = entry
		end
		return entry
	end
	core.get_meta = function(pos)
		local key = node_key(pos)
		return {
			to_table = function()
				local entry = mock.node_meta[key]
				if not entry then return nil end
				local out = {fields = copy_table(entry.fields or {}), inventory = {}}
				for listname, list in pairs(entry.inventory or {}) do
					local items = {}
					for i, itemstring in ipairs(list) do
						items[i] = ItemStack(itemstring)
					end
					out.inventory[listname] = items
				end
				return out
			end,
			from_table = function(_, data)
				if type(data) ~= "table" then
					mock.node_meta[key] = nil
					return true
				end
				local entry = {fields = copy_table(data.fields or {}), inventory = {}}
				for listname, list in pairs(data.inventory or {}) do
					local items = {}
					for i, stack in ipairs(list) do
						if type(stack) == "string" then
							items[i] = stack
						elseif stack ~= nil and stack.to_string then
							items[i] = stack:to_string()
						else
							items[i] = ""
						end
					end
					entry.inventory[listname] = items
				end
				mock.node_meta[key] = entry
				return true
			end,
			set_string = function(_, field, value)
				meta_entry(key).fields[field] = tostring(value)
			end,
			get_string = function(_, field)
				local entry = mock.node_meta[key]
				return entry and entry.fields[field] or ""
			end,
			get_inventory = function()
				local entry = meta_entry(key)
				local function itemstrings(list)
					local items = {}
					for i, stack in ipairs(list or {}) do
						if type(stack) == "string" then
							items[i] = stack
						elseif stack ~= nil and stack.to_string then
							items[i] = stack:to_string()
						else
							items[i] = ""
						end
					end
					return items
				end
				return {
					set_list = function(_, listname, list)
						entry.inventory[listname] = itemstrings(list)
					end,
					get_list = function(_, listname)
						local items = {}
						for i, itemstring in ipairs(entry.inventory[listname] or {}) do
							items[i] = ItemStack(itemstring)
						end
						return items
					end,
					get_size = function(_, listname)
						return #(entry.inventory[listname] or {})
					end,
				}
			end,
		}
	end
	core.find_nodes_with_meta = function(p1, p2)
		local out = {}
		for key in pairs(mock.node_meta) do
			local x, y, z = key:match("^(%-?%d+),(%-?%d+),(%-?%d+)$")
			if x then
				x, y, z = tonumber(x), tonumber(y), tonumber(z)
				if x >= p1.x and x <= p2.x and y >= p1.y and y <= p2.y
					and z >= p1.z and z <= p2.z then
					out[#out + 1] = {x = x, y = y, z = z}
				end
			end
		end
		return out
	end
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

	-- The engine's hash is a plain unique encoding of a position, and the
	-- mapblock callback hashes mapblock positions (in mapblock units). The
	-- mock does the same, so a hash handed to the callback is decoded as-is.
	local HASH_BIAS = 32768
	core.hash_node_position = function(pos)
		local x = math.floor(pos.x) + HASH_BIAS
		local y = math.floor(pos.y) + HASH_BIAS
		local z = math.floor(pos.z) + HASH_BIAS
		return (x * 65536 + y) * 65536 + z
	end
	core.get_position_from_hash = function(hash)
		local z = hash % 65536
		hash = math.floor(hash / 65536)
		local y = hash % 65536
		local x = math.floor(hash / 65536)
		return {
			x = x - HASH_BIAS,
			y = y - HASH_BIAS,
			z = z - HASH_BIAS,
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

	mock.vms = {}
	mock.liquids_updated = false
	mock.relit = {}  -- boxes core.fix_light was asked to recalculate
	-- The engine's lighting pass, stood in for by plain daylight: enough for a
	-- test to tell a live recalculation from recorded light bytes.
	core.fix_light = function(p1, p2)
		mock.relit[#mock.relit + 1] = {
			pos1 = {x = p1.x, y = p1.y, z = p1.z},
			pos2 = {x = p2.x, y = p2.y, z = p2.z},
		}
		for z = p1.z, p2.z do
			for y = p1.y, p2.y do
				for x = p1.x, p2.x do
					local pos = {x = x, y = y, z = z}
					local node = mock.get_node(pos)
					mock.set_node(pos, {name = node.name, param2 = node.param2, light = 15})
				end
			end
		end
		return true
	end
	core.get_voxel_manip = function(p1, p2)
		local emerged1 = {x = p1.x, y = p1.y, z = p1.z}
		local emerged2 = {x = p2.x, y = p2.y, z = p2.z}
		local size = {x = p2.x - p1.x + 1, y = p2.y - p1.y + 1, z = p2.z - p1.z + 1}
		local volume = size.x * size.y * size.z
		local data, param2, light = {}, {}, {}

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
		mock.vms[#mock.vms + 1] = vm
		function vm:read_from_map()
			for i = 1, volume do
				local node = mock.get_node(position_of(i))
				data[i] = mock.add_node_name(node.name)
				param2[i] = node.param2 or 0
				light[i] = node.light or 0
			end
			return emerged1, emerged2
		end
		function vm:get_emerged_area() return emerged1, emerged2 end
		function vm:get_data() return data end
		function vm:get_param2_data() return param2 end
		function vm:get_light_data() return light end
		function vm:set_data(value) data = value end
		function vm:set_param2_data(value) param2 = value end
		function vm:set_light_data(value) light = value end
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
			light[index] = node.light or light[index]
		end
		function vm:update_liquids()
			vm.liquids_updated = true
			mock.liquids_updated = true
		end
		function vm:write_to_map(recalculate)
			for i = 1, volume do
				-- The engine recalculates light unless told not to; the stand-in
				-- uses daylight so recorded bytes are distinguishable in tests.
				local value = light[i]
				if recalculate ~= false then value = 15 end
				mock.set_node(position_of(i), {
					name = node_names[data[i]] or "air",
					param2 = param2[i],
					light = value,
				})
			end
		end
		function vm:close() end
		return vm
	end

	-- Entities, items, chat, metadata-friendly serialisers: what the replay
	-- suites drive ghosts and participants with.
	mock.entity_defs = {}
	mock.entities = {}
	mock.items = {}
	mock.chats = {}
	local entity_id = 0

	core.register_entity = function(name, def)
		mock.entity_defs[name] = def
	end
	core.add_entity = function(pos, name)
		entity_id = entity_id + 1
		local obj = {
			id = entity_id,
			name = name,
			pos = {x = pos.x, y = pos.y, z = pos.z},
			properties = {},
			removed = false,
		}
		function obj:set_properties(values)
			for key, value in pairs(values) do self.properties[key] = value end
		end
		function obj:set_observers(set) self.observers = set end
		function obj:move_to(target) self.pos = {x = target.x, y = target.y, z = target.z} end
		function obj:set_yaw(value) self.yaw = value end
		function obj:set_velocity(value) self.velocity = value end
		function obj:set_animation(frames, speed)
			self.animation = frames
			self.animation_speed = speed
		end
		function obj:set_bone_override(bone, override)
			self.bones = self.bones or {}
			self.bones[bone] = override
		end
		function obj:remove()
			self.removed = true
			mock.entities[self.id] = nil
		end
		mock.entities[entity_id] = obj
		return obj
	end

	core.register_craftitem = function(name, def)
		mock.items[name] = def
	end
	core.chat_send_player = function(name, message)
		mock.chats[#mock.chats + 1] = {name = name, message = message}
	end
	-- The engine shows formspecs through the server, not through an ObjectRef
	-- method; the mock does the same so a wrong call cannot pass a test.
	core.show_formspec = function(playername, formname, formspec)
		local player = mock.by_name[playername]
		if player then player.formspec = {name = formname, formspec = formspec} end
	end
	core.close_formspec = function(playername, formname)
		local player = mock.by_name[playername]
		if player then player.formspec = {name = formname, formspec = ""} end
	end
	core.formspec_escape = function(text)
		return tostring(text)
	end
	-- The engine's colour escape sequences, so a test can see the colour that
	-- was asked for.
	core.get_color_escape_sequence = function(color)
		return string.char(0x1b) .. "(c@" .. tostring(color) .. ")"
	end
	core.colorize = function(color, message)
		local code = core.get_color_escape_sequence(color)
		local lines = {}
		for line in (tostring(message) .. "\n"):gmatch("(.-)\n") do
			lines[#lines + 1] = code .. line
		end
		return table.concat(lines, "\n") .. core.get_color_escape_sequence("#fff")
	end
	core.explode_scrollbar_event = function(value)
		local kind, number = tostring(value):match("^(%a+):(%-?%d+)")
		return {type = kind or "INV", value = tonumber(number)}
	end
	core.explode_textlist_event = function(value)
		local kind, index = tostring(value):match("^(%a+):(%-?%d+)")
		return {type = kind or "INV", index = tonumber(index)}
	end
	core.get_dir_list = function(path, want_dirs)
		if want_dirs then return nil end
		local names = {}
		local pipe = io.popen("ls -1 '" .. path .. "' 2>/dev/null")
		if pipe then
			for line in pipe:lines() do names[#names + 1] = line end
			pipe:close()
		end
		return names
	end

	-- Mod storage is a table behind the two accessors the engine's ModStorage
	-- offers; a test can read what was saved by looking at mock.modstorage.
	mock.modstorage = {}
	core.get_mod_storage = function()
		local storage = mock.modstorage
		return {
			get_string = function(_, key) return storage[key] or "" end,
			set_string = function(_, key, value) storage[key] = value end,
		}
	end

	-- Just enough JSON for the event data the recorder writes.
	local function parse_json(text)
		local pos = 1
		local function fail() error("bad json at " .. pos) end
		local function skip()
			while pos <= #text and text:find("^%s", pos) do pos = pos + 1 end
		end
		local parse_value
		local function parse_string()
			pos = pos + 1
			local out = {}
			while true do
				local c = text:sub(pos, pos)
				if c == "" then fail() end
				if c == '"' then
					pos = pos + 1
					return table.concat(out)
				end
				if c == "\\" then
					local esc = text:sub(pos + 1, pos + 1)
					local map = {n = "\n", t = "\t", r = "\r", b = "\b", f = "\f",
						['"'] = '"', ["\\"] = "\\", ["/"] = "/"}
					if esc == "u" then
						out[#out + 1] = string.char((tonumber(text:sub(pos + 2, pos + 5), 16) or 63) % 256)
						pos = pos + 6
					else
						out[#out + 1] = map[esc] or esc
						pos = pos + 2
					end
				else
					out[#out + 1] = c
					pos = pos + 1
				end
			end
		end
		local function parse_number()
			local number = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
			if not number or number == "" then fail() end
			pos = pos + #number
			return tonumber(number)
		end
		local function parse_array()
			pos = pos + 1
			local out = {}
			skip()
			if text:sub(pos, pos) == "]" then
				pos = pos + 1
				return out
			end
			while true do
				out[#out + 1] = parse_value()
				skip()
				local c = text:sub(pos, pos)
				pos = pos + 1
				if c == "]" then return out end
				if c ~= "," then fail() end
			end
		end
		local function parse_object()
			pos = pos + 1
			local out = {}
			skip()
			if text:sub(pos, pos) == "}" then
				pos = pos + 1
				return out
			end
			while true do
				skip()
				if text:sub(pos, pos) ~= '"' then fail() end
				local key = parse_string()
				skip()
				if text:sub(pos, pos) ~= ":" then fail() end
				pos = pos + 1
				out[key] = parse_value()
				skip()
				local c = text:sub(pos, pos)
				pos = pos + 1
				if c == "}" then return out end
				if c ~= "," then fail() end
			end
		end
		parse_value = function()
			skip()
			local c = text:sub(pos, pos)
			if c == "{" then return parse_object() end
			if c == "[" then return parse_array() end
			if c == '"' then return parse_string() end
			if text:sub(pos, pos + 3) == "true" then pos = pos + 4 return true end
			if text:sub(pos, pos + 4) == "false" then pos = pos + 5 return false end
			if text:sub(pos, pos + 3) == "null" then pos = pos + 4 return nil end
			return parse_number()
		end
		return parse_value()
	end
	core.parse_json = function(text)
		local ok, value = pcall(parse_json, text)
		if ok then return value end
		return nil
	end

	local function serialize_value(value)
		local kind = type(value)
		if kind == "string" then return string.format("%q", value) end
		if kind == "number" or kind == "boolean" then return tostring(value) end
		if kind == "table" then
			local parts = {}
			for key, item in pairs(value) do
				parts[#parts + 1] = "[" .. serialize_value(key) .. "]=" .. serialize_value(item)
			end
			return "{" .. table.concat(parts, ",") .. "}"
		end
		return "nil"
	end
	core.serialize = serialize_value
	core.deserialize = function(text)
		local loader = loadstring or load
		local chunk = loader("return " .. tostring(text))
		if not chunk then return nil end
		local ok, value = pcall(chunk)
		if ok then return value end
		return nil
	end

	ItemStack = function(itemstring)
		return {to_string = function() return itemstring or "" end}
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
