-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

local working = true
local http_api = core.request_http_api()
if not http_api then
	core.log("cloudai mod requires http_api. Add to secure.http_mods")
	working = false
end

local is_xmpp = core.global_exists("xmpp_relay")
local shareddb_storage
local has_shareddb = core.global_exists("shareddb")
if has_shareddb then
	shareddb_storage = shareddb.get_mod_storage()
end
local base_url = core.settings:get("cloudai.url") or "https://api.deepseek.com"
base_url = base_url:gsub("/$", "")
local default_model = "deepseek-v4-flash"
local model = core.settings:get("cloudai.model") or default_model
local timeout = core.settings:get("cloudai.timeout") or 10
local api_key = core.settings:get("cloudai.api_key")
local auth_header
local balance = "unknown"
local model_fetch_lock = 0
local balance_fetch_lock = 0
if not api_key then
	core.log("cloudai mod requires api_key. Add cloudai.api_key")
	working = false
else
	auth_header = "Authorization: Bearer "..api_key
end
if has_shareddb then
	local ctx = shareddb_storage:get_context()
	if ctx then
		local val = ctx:get_string("url")
		if val then base_url = val:gsub("/$", "") end
		val = ctx:get_string("model")
		if val then model = val end
		val = ctx:get_string("timeout")
		if val then timeout = tonumber(val) end
		ctx:finalize()
	end
	shareddb.register_listener(function(key)
		if key == "url" then
			local ctx = shareddb_storage:get_context()
			if ctx then
				local val = ctx:get_string("url")
				if val then base_url = val:gsub("/$", "") end
				ctx:finalize()
			end
		elseif key == "model" then
			local ctx = shareddb_storage:get_context()
			if ctx then
				local val = ctx:get_string("model")
				if val then model = val end
				ctx:finalize()
			end
		elseif key == "timeout" then
			local ctx = shareddb_storage:get_context()
			if ctx then
				local val = ctx:get_string("timeout")
				if val then timeout = tonumber(val) end
				ctx:finalize()
			end
		end
	end)
end
cloudai = {}
local models = {}

local function parse_response(response)
	if not response.succeeded then
		if response.timeout then
			return false, "Timeout"
		end
		return false, "Unknown error"
	end
	if response.code ~= 200 then
		if #response.data == 0 then
			return false, "Empty response"
		end
		-- Attempt to parse as JSON
		local parsed, _ = core.parse_json(response.data, nil, true)
		if parsed and parsed.error and type(parsed.error.message) == "string" then
			return false, parsed.error.message
		end
		return false, response.data
	end
	local parsed, err = core.parse_json(response.data, nil, true)
	if not parsed then
		return false, err
	end
	return true, parsed
end

local function refresh_models()
	local callback = function(response)
		model_fetch_lock = model_fetch_lock - 1
		local ok, parsed = parse_response(response)
		if not ok then
			core.log("[cloudai]: Failed to refresh the model list: "..parsed)
			return
		end
		if type(parsed.data) ~= "table" or #parsed.data == 0 then
			core.log("[cloudai]: Failed to refresh the model list: Invalid response form")
			return
		end
		local new_models = {}
		for _, value in ipairs(parsed.data) do
			if type(value) ~= "table" or type(value.id) ~= "string" then
				core.log("[cloudai]: Failed to refresh the model list: Invalid response form")
				return
			end
			new_models[value.id] = true
		end
		models = new_models
		if not models[model] then
			if models[default_model] then
				core.log("[cloudai]: Configured model "..model.." doesn't exist. Falling back to "..default_model)
				model = default_model
				return
			end
			model = nil
			core.log("[cloudai]: We cannot select the model. Waiting for configuration.")
		end
	end
	local request = {
		url = base_url.."/models",
		method = "GET",
		timeout = timeout,
		extra_headers = { "Content-Type: application/json", auth_header }
	}
	model_fetch_lock = model_fetch_lock + 1
	http_api.fetch(request, callback)
end
refresh_models()

local function send_debug(context, label, data)
	if not context._debug or not is_xmpp then return end
	local id = context._current_debug_id
	if not id then return end
	local data_str
	if type(data) == "table" then
		data_str = dump(data)
	else
		data_str = tostring(data)
	end
	local msg = string.format("[%s] %s: %s", id, label, data_str)
	xmpp_relay.send(msg, "debuglog@conference.jmaminetest.mooo.com")
end

-- Poll the HTTP request and process it when complete.
-- Returns are meaningful only when called from call() (auto_call = false):
--   true        → request finished, callback invoked, context free
--   false, err  → context still busy (response pending or tool recursion ongoing)
-- When called via core.after (auto_call = true), returns are discarded.
-- Callback should add response to history, but we add tool calls
local function handle_response(context, auto_call)
	local response = http_api.fetch_async_get(context._handle)
	if not response.completed then
		if auto_call then
			core.after(0, handle_response, context, true)
			return
		else
			return false, "You cannot send a new message to the same conversation before the old response completes"
		end
	end
	context._handle = nil  -- The request has completed, successfully or not
	if context._destroyed then
		return false, "Context destroyed, not triggering callback"
	end
	local ok, parsed = parse_response(response)
	if not ok then
		context._callback(context._history, nil, parsed)
		context._callback = nil
		context._current_debug_id = nil
		return true
	end

	-- Now we have a proper response, let's parse it
	local usage = parsed.usage or {}
	context.input_tokens = context.input_tokens + (usage.prompt_cache_miss_tokens or 0)
	context.cached_tokens = context.cached_tokens + (usage.prompt_cache_hit_tokens or 0)
	context.output_tokens = context.output_tokens + (usage.completion_tokens or 0)

	if not parsed.choices or not parsed.choices[1] or not parsed.choices[1].message
	   or not parsed.choices[1].message.role then
		context._callback(context._history, nil, "Malformed response")
		context._callback = nil
		context._current_debug_id = nil
		return true
	else
		if parsed.choices[1].finish_reason == "tool_calls" then
			local msg = parsed.choices[1].message
			table.insert(context._history, msg)
			send_debug(context, "tool_call", msg)
			if type(msg.tool_calls) ~= "table" or #msg.tool_calls == 0 then
				context._callback(context._history, nil, "Malformed response")
				context._callback = nil
				context._current_debug_id = nil
				return true
			end
			for _, tool_call in ipairs(msg.tool_calls) do
				if context._max_steps_now then
					context._max_steps_now = context._max_steps_now - 1
					if context._max_steps_now < 0 then
						context._callback(context._history, nil, "Exceeded the maximum number of tool calls")
						context._callback = nil
						context._current_debug_id = nil
						return true
					end
				end
				local name = tool_call["function"].name
				if not context._tools[name] then
					context._callback(context._history, nil, "Tool "..tostring(name).." doesn't exist")
					context._callback = nil
					context._current_debug_id = nil
					return true
				end
				local args = tool_call["function"].arguments
				local json_args, err = core.parse_json(args, nil, true)
				if json_args then
					args = json_args
				else
					if context._tools[name].strict then
						context._callback(context._history, nil, "Malformed arguments in tool call to "..name..": "..err)
						context._callback = nil
						context._current_debug_id = nil
						return true
					end
				end
				local result = context._tools[name].func(args)
				if type(result) == "table" then
					result, err = core.write_json(result)
					if not result then
						context._callback(context._history, nil, "Malformed response from tool "..name..
						": Returned table that couldn't be converted to JSON\n"..err)
						context._callback = nil
						context._current_debug_id = nil
						return true
					end
				end
				result = tostring(result)
				table.insert(context._history, {role = "tool", content = result, tool_call_id = tool_call.id})
				send_debug(context, "tool_response", {tool_call_id = tool_call.id, result = result})
			end
			local result, err = context:_make_request()
			if not result then
				context._callback(context._history, nil, "Failed to continue after tool call: "..err)
				context._callback = nil
				context._current_debug_id = nil
				return true
			end
			return false, "You cannot send a new message to the same conversation before the old response completes"
		else
			parsed.choices[1].message.content = parsed.choices[1].message.content or ""
			send_debug(context, "final_response", parsed.choices[1].message)
			context._callback(context._history, parsed.choices[1].message)
			context._callback = nil
			context._current_debug_id = nil
			return true
		end
	end
end

cloudai.get_context = function()
	if not working then
		return nil, "cloudai is not properly configured to work. Check minetest.conf"
	end
	if not model then
		return nil, "cloudai is waiting for model configuration"
	end
	return {
		input_tokens = 0,
		output_tokens = 0,
		cached_tokens = 0,
		_system_prompt = "You are an AI assitant",
		_history = {},
		_tools = {},	-- The table of ["tool_name"] = tool_definition
		_formatted_tools = {},	-- Array of tool definitions formatted for API payload
		_handle = nil,      -- Active HTTP request
		_callback = nil,    -- Callback to call when the request completes
		_destroyed = false,	-- If set, this context is not usable anymore
		_max_steps = nil,	-- How many tool calls may the AI make before giving a response
		_max_steps_now = nil,	-- How many steps are left available for the current prompt
		_temperature = nil,
		_frequency_penalty = nil,
		_presence_penalty = nil,
		_debug = false,
		_current_debug_id = nil,
		_model = model,
		_thinking = "disabled",
		_reasoning_effort = nil,
		_make_request = function(self)	-- After everything was made ready, this is called to form and send the request
			local payload = {
				model = self._model,
				messages = self._history,
				thinking = {
					type = self._thinking
				}
			}
			-- Add optional parameters if set
			if self._reasoning_effort ~= nil then
				payload.reasoning_effort = self._reasoning_effort
			end
			if self._temperature ~= nil then
				payload.temperature = self._temperature
			end
			if self._frequency_penalty ~= nil then
				payload.frequency_penalty = self._frequency_penalty
			end
			if self._presence_penalty ~= nil then
				payload.presence_penalty = self._presence_penalty
			end
			if #self._formatted_tools > 0 then
				payload.tools = self._formatted_tools
			end

			local data, err = core.write_json(payload)
			if not data then
				return false, err
			end
			self._handle = http_api.fetch_async({
				url = base_url.."/chat/completions",
				method = "POST",
				timeout = timeout,
				data = data,
				extra_headers = { "Content-Type: application/json", auth_header }
			})
			core.after(0, handle_response, self, true)
			return true
		end,
		-- Callback gets history and AI response (nil in case of error, in which case third argument is the error string)
		call = function(self, message, callback)
			if self._destroyed then
				return false, "Cannot use a destroyed context"
			end
			if self._handle then
				local handled, err = handle_response(self)
				if not handled then
					return false, err
				end
			end
			if #self._history == 0 then
				table.insert(self._history, {role = "system", content = self._system_prompt})
			end
			table.insert(self._history, {role = "user", content = message})

			if self._debug then
				self._current_debug_id = tostring(core.get_us_time())
				send_debug(self, "initial_history", self._history)
			end

			self._callback = callback
			self._max_steps_now = self._max_steps
			return self:_make_request()
		end,
		add_tool = function(self, tool_definition)
			tool_definition.name = tool_definition.name or "Unknown"
			if self._tools[tool_definition.name] then
				return false, "A tool with the same name already exists"
			end
			self._tools[tool_definition.name] = tool_definition
			local tool = {
				type = "function",
				["function"] = {
					name = tool_definition.name,
					description = tool_definition.description,
					strict = tool_definition.strict
				}
			}
			if tool_definition.properties then
				tool["function"].parameters = {
					type = "object",
					properties = tool_definition.properties,
					additionalProperties = false,
					required = {}
				}
				for k, _ in pairs(tool["function"].parameters.properties) do
					table.insert(tool["function"].parameters.required, k)
				end
			end
			table.insert(self._formatted_tools, tool)
			return true
		end,
		set_system_prompt = function(self, prompt)
			if #self._history ~= 0 then
				return false, "You cannot change the system prompt once the conversation has already begun"
			end
			if type(prompt) ~= "string" then
				return false, "System prompt must be a string"
			end
			self._system_prompt = prompt
			return true
		end,
		set_model = function(self, id)
			if type(id) ~= "string" then
				return false, "Model name must be a string"
			end
			if not models[id] then
				return false, "Model "..id.." doesn't exist"
			end
			self._model = id
			return true
		end,
		set_reasoning_effort = function(self, effort)
			if effort ~= "high" and effort ~= "max" then
				return false, string.format("Valid values are: high, max (got %s)", tostring(effort))
			end
			self._reasoning_effort = effort
			return true
		end,
		set_thinking = function(self, thinking)
			if thinking ~= "enabled" and thinking ~= "disabled" then
				return false, string.format("Valid values are: enabled, disabled (got %s)", tostring(thinking))
			end
			self._thinking = thinking
			return true
		end,
		set_max_steps = function(self, new_max_steps)
			if type(new_max_steps) ~= "number" then
				return false, "Max steps must be a number"
			end
			self._max_steps = new_max_steps
			return true
		end,
		set_temperature = function(self, temp)
			if temp ~= nil then
				if type(temp) ~= "number" or temp < 0 or temp > 2 then
					return false, "Temperature must be a number between 0 and 2"
				end
			end
			self._temperature = temp
			return true
		end,
		set_frequency_penalty = function(self, fp)
			if fp ~= nil then
				if type(fp) ~= "number" or fp < -2 or fp > 2 then
					return false, "Frequency penalty must be a number between -2 and 2"
				end
			end
			self._frequency_penalty = fp
			return true
		end,
		set_presence_penalty = function(self, pp)
			if pp ~= nil then
				if type(pp) ~= "number" or pp < -2 or pp > 2 then
					return false, "Presence penalty must be a number between -2 and 2"
				end
			end
			self._presence_penalty = pp
			return true
		end,
		set_debug = function(self, enable)
			self._debug = (enable == true)
			return true
		end,
		destroy = function(self)
			self._destroyed = true
		end
	}
end

core.register_privilege("cloudai", "Modify cloudai parameters")
core.register_chatcommand("cloudai", {
	description = "Set parameters for cloudai API",
	params = "<subcommand> arguments",
	privs = { cloudai = true },
	func = function(name, params)
		local iter = params:gmatch("%S+")
		local cmd = iter()
		if not cmd then
			return false, "Invalid usage. Check /cloudai help"
		end
		if cmd == "help" then
			return true, [[Usage:
/cloudai help: Print this help message
/cloudai timeout <new_value>: If the second argument is present, set timeout to <new_value> seconds, otherwise print the current value
/cloudai url <new_value>: If the second argument is present, set the base URL to <new_value>, otherwise print the current value
/cloudai balance: Print the current balance (in CNY and EUR)
/cloudai models list: List all models we got from the provider
                refresh: Refresh the list of models offered by the provider
                set <model>: Set the new default model
                get: Print the current default model]]
		end
		if cmd == "timeout" then
			local new_value = iter()
			if not new_value then
				return true, "Current timeout: "..tostring(timeout)
			end
			local new_timeout = tonumber(new_value)
			if not new_timeout or new_timeout <= 0 or new_timeout ~= math.ceil(new_timeout) then
				return false, "New timeout must be a whole number greater than zero"
			end
			timeout = new_timeout
			if shareddb_storage then
				local ctx = shareddb_storage:get_context()
				if ctx then
					ctx:set_string("timeout", tostring(new_timeout))
					ctx:finalize()
				end
			end
			return true, "New timeout: "..tostring(timeout)
		end
		if cmd == "balance" then
			local callback = function(response)
				balance_fetch_lock = balance_fetch_lock - 1
				local ok, parsed = parse_response(response)
				if not ok then
					balance = string.format("(Failed to fetch: %s)", parsed)
					return
				end
				if type(parsed.is_available) ~= "boolean" or type(parsed.balance_infos) ~= "table" or #parsed.balance_infos == 0 then
					balance = "(Failed to fetch: Invalid response form)"
					return
				end
				balance = parsed.is_available and "(Sufficient" or "(Insufficient"
				local amount = ""
				for _, info in ipairs(parsed.balance_infos) do
					local value = tonumber(info.total_balance)
					if type(info.currency) ~= "string" or not value then
						balance = balance.."; Failed to fetch amount: Invalid response form)"
						return
					end
					if value > 0 then
						amount = string.format("%s; %.2f %s", amount, value, info.currency)
					end
				end
				if amount == "" then
					amount = "; 0.00 USD"
				end
				balance = balance..amount..")"
			end
			local request = {
				url = base_url.."/user/balance",
				method = "GET",
				timeout = timeout,
				extra_headers = { "Content-Type: application/json", auth_header }
			}
			if balance_fetch_lock == 0 then
				balance_fetch_lock = balance_fetch_lock + 1
				http_api.fetch(request, callback)
			end
			return true, "The previously fetched balance was: "..balance.."\nThe current is being read now."
		end
		if cmd == "models" then
			local subcommand = iter()
			if subcommand == "list" then
				local res = ""
				for model, _ in pairs(models) do
					res = res..model.."\n"
				end
				return true, res
			end
			if subcommand == "get" then
				return true, "Current default model: "..tostring(model)
			end
			if subcommand == "set" then
				local new_value = iter()
				if new_value then
					if not models[new_value] then
						return true, "Model "..new_value.." doesn't exist"
					end
					model = new_value
					if shareddb_storage then
						local ctx = shareddb_storage:get_context()
						if ctx then
							ctx:set_string("model", new_value)
							ctx:finalize()
						end
					end
					return true, "New model: "..model
				end
			end
			if subcommand == "refresh" then
				if model_fetch_lock > 0 then
					return true, "A model list refresh is already in progress"
				end
				refresh_models()
				return true, "Model list is being refreshed"
			end
			return false, "Usage: /cloudai models list|refresh|set <model>|get"
		end
		if cmd == "url" then
			local new_value = iter()
			if not new_value then
				return true, "Current base URL: "..base_url
			end

			local pattern = "^https?://[%w-_%.~!$&'()*+,;=:@/?%%]+$"
			if string.match(new_value, pattern) == nil then
				return false, "Invalid URL: "..new_value
			end
			base_url = new_value:gsub("/$", "")
			if shareddb_storage then
				local ctx = shareddb_storage:get_context()
				if ctx then
					ctx:set_string("url", new_value)
					ctx:finalize()
				end
			end
			return true, "New base URL: "..tostring(base_url)
		end
		return false, "Invalid usage. Check /cloudai help"
	end
})

-- Below is a simple example of how this could be used:
--[[
test = {}
local function safe_send(str)
	if not str then
		str = "nil"
	end
	if type(str) == "table" then
		str = dump(str)
	end
	core.chat_send_all(str)
end
test.handler = function(history, response, error)
	core.chat_send_all("History:")
	safe_send(history)
	core.chat_send_all("Response:")
	safe_send(response)
	core.chat_send_all("Error:")
	safe_send(error)
end

test.context = cloudai.get_context()
test.context:add_tool({
	name = "add_office",
	func = function(args)
		core.chat_send_all(string.format("Added office in %s (%s)", args.location, args.email))
		return {success = true}
	end,
	description = "Add office to the list",
	strict = true,
	-- Descriptions of keys and values in that table, gets passed directly to properties in the API
	properties = {
		location = {
			type = "string",
			description = "The city and state, e.g. San Francisco, CA"
		},
		email = {
			type = "string",
			description = "Office email",
			format = "email"
		}
	}
})
test.context:call("Add office in Belgrade with email a1@example.com to the list", test.handler)
]]
