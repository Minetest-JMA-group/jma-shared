local http_api = core.request_http_api()
assert(http_api, "cloudai mod requires http_api. Add to secure.http_mods")
local url = core.settings:get("cloudai.url") or "https://api.deepseek.com/chat/completions"
local model = core.settings:get("cloudai.model") or "deepseek-chat"
local timeout = core.settings:get("cloudai.timeout") or 10
local api_key = core.settings:get("cloudai.api_key")
assert(api_key, "cloudai mod requires api_key. Add cloudai.api_key")
local auth_header = "Authorization: Bearer "..api_key
cloudai = {}

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
	   or not parsed.choices[1].message.role or not parsed.choices[1].message.content then
		context._callback(context._history, nil, "Malformed response")
	else
		context._callback(context._history, parsed.choices[1].message)
	end
	context._callback = nil
	return true
end

-- Callback gets history and AI response (nil in case of error, in which case third argument is the error string)
cloudai.get_context = function()
	return {
		_input_tokens = 0,
		_output_tokens = 0,
		_cached_tokens = 0,
		_system_prompt = "You are an AI assitant",
		_history = {},
		_handle = nil,      -- Active HTTP request
		_callback = nil,    -- Callback to call when the request completes
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
			local data, err = core.write_json({
				model = model,
				messages = self._history
			})
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
		end
	}
end