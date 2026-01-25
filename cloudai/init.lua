local working = true
local http_api = core.request_http_api()
if not http_api then
	core.log("cloudai mod requires http_api. Add to secure.http_mods")
	working = false
end
local url = core.settings:get("cloudai.url") or "https://api.deepseek.com/beta/chat/completions"
local model = core.settings:get("cloudai.model") or "deepseek-chat"
local timeout = core.settings:get("cloudai.timeout") or 10
local api_key = core.settings:get("cloudai.api_key")
local auth_header
if not api_key then
	core.log("cloudai mod requires api_key. Add cloudai.api_key")
	working = false
else
	auth_header = "Authorization: Bearer "..api_key
end
cloudai = {}

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
	if not response.succeeded then
		local err = "Unknown error"
		if response.timeout then
			err = "Timeout"
		end
		context._callback(context._history, nil, err)
		context._callback = nil
		return true
	end
	if response.code ~= 200 then
		if #response.data == 0 then
			context._callback(context._history, nil, nil)
			context._callback = nil
			return true
		end
		-- Attempt to parse as JSON
		local parsed, _ = core.parse_json(response.data, nil, true)
		if parsed and parsed.error and parsed.error.message
		   and type(parsed.error.message) == "string" then
			parsed = parsed.error.message
		else
			parsed = response.data
		end
		context._callback(context._history, nil, parsed)
		context._callback = nil
		return true
	end
	local parsed, err = core.parse_json(response.data, nil, true)
	if not parsed then
		context._callback(context._history, nil, err)
		context._callback = nil
		return true
	end

	-- Now we have a proper response, let's parse it
	local usage = parsed.usage or {}
	context._input_tokens = context._input_tokens + (usage.prompt_cache_miss_tokens or 0)
	context._cached_tokens = context._cached_tokens + (usage.prompt_cache_hit_tokens or 0)
	context._output_tokens = context._output_tokens + (usage.completion_tokens or 0)

	if not parsed.choices or not parsed.choices[1] or not parsed.choices[1].message
	   or not parsed.choices[1].message.role then
		context._callback(context._history, nil, "Malformed response")
	else
		if parsed.choices[1].finish_reason == "tool_calls" then
			local msg = parsed.choices[1].message
			table.insert(context._history, msg)
			for _, tool_call in ipairs(msg.tool_calls) do
				local name = tool_call["function"].name
				local args = tool_call["function"].arguments
				local json_args, err = core.parse_json(args, nil, true)
				if json_args then
					args = json_args
				else
					if context._tools[name].strict then
						context._callback(context._history, nil, "Malformed arguments in tool call to "..name..": "..err)
						context._callback = nil
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
						return true
					end
				end
				result = tostring(result)
				table.insert(context._history, {role = "tool", content = result, tool_call_id = tool_call.id})
			end
			local result, err = context:_make_request()
			if not result then
				context._callback(context._history, nil, "Failed to continue after tool call: "..err)
				context._callback = nil
				return true
			end
			return false, "You cannot send a new message to the same conversation before the old response completes"
		else
			parsed.choices[1].message.content = parsed.choices[1].message.content or ""
			context._callback(context._history, parsed.choices[1].message)
			context._callback = nil
			return true
		end
	end
end

cloudai.get_context = function()
	if not working then
		return nil, "cloudai is not properly configured to work. Check minetest.conf"
	end
	return {
		_input_tokens = 0,
		_output_tokens = 0,
		_cached_tokens = 0,
		_system_prompt = "You are an AI assitant",
		_history = {},
		_tools = {},	-- The table of ["tool_name"] = tool_definition
		_formatted_tools = {},	-- Array of tool definitions formatted for API payload
		_handle = nil,      -- Active HTTP request
		_callback = nil,    -- Callback to call when the request completes
		_make_request = function(self)	-- After everything was made ready, this is called to form and send the request
			local payload = {
				model = model,
				messages = self._history
			}
			if #self._formatted_tools > 0 then
				payload.tools = self._formatted_tools
			end

			local data, err = core.write_json(payload)
			if not data then
				return false, err
			end
			self._handle = http_api.fetch_async({
				url = url,
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
			self._callback = callback
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
		end
	}
end

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