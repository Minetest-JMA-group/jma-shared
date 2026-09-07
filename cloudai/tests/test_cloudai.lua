-- Test suite for cloudai. Runs with plain Lua (luajit or lua), no Minetest
-- needed:
--     luajit cloudai/tests/test_cloudai.lua   (from the repo root)
--     luajit test_cloudai.lua                 (from cloudai/tests/)
--
-- Stubs the Luanti globals (core, xmpp_relay, dump) and the HTTP API, loads
-- the real init.lua, then drives the context call()/handle_response()
-- lifecycle through scenarios against a scripted HTTP layer. Must live in a
-- tests/ subdirectory of the mod in a checkout.

local script_path = arg and arg[0] or debug.getinfo(1, "S").source:match("^@(.+)$")
local script_dir = script_path:match("^(.*)/[^/]*$") or "."
local MOD_PATH = script_dir .. "/../init.lua"


-------------------------------------------------------------------------------
-- Minimal JSON (sufficient for fixtures & payloads used here)
-------------------------------------------------------------------------------
local json = {}

function json.encode(v)
	local out = {}
	local function enc(x)
		local t = type(x)
		if t == "nil" then out[#out+1] = "null"
		elseif t == "boolean" then out[#out+1] = tostring(x)
		elseif t == "number" then out[#out+1] = tostring(x)
		elseif t == "string" then
			out[#out+1] = '"' .. x:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"'
		elseif t == "table" then
			local n = #x
			if n > 0 then
				out[#out+1] = "["
				for i = 1, n do
					if i > 1 then out[#out+1] = "," end
					enc(x[i])
				end
				out[#out+1] = "]"
			else
				out[#out+1] = "{"
				local first = true
				for k, val in pairs(x) do
					if val ~= nil then
						if not first then out[#out+1] = "," end
						first = false
						enc(k)
						out[#out+1] = ":"
						enc(val)
					end
				end
				out[#out+1] = "}"
			end
		else
			error("cannot encode " .. t)
		end
	end
	enc(v)
	return table.concat(out)
end

function json.decode(s)
	local pos = 1
	local function skipws()
		while s:sub(pos, pos):match("%s") do pos = pos + 1 end
	end
	local function parse_string()
		pos = pos + 1 -- opening quote
		local out = {}
		while true do
			local c = s:sub(pos, pos)
			if c == '"' then pos = pos + 1 break end
			if c == "\\" then
				local e = s:sub(pos+1, pos+1)
				if e == "n" then out[#out+1] = "\n"
				elseif e == "t" then out[#out+1] = "\t"
				elseif e == '"' then out[#out+1] = '"'
				elseif e == "\\" then out[#out+1] = "\\"
				elseif e == "/" then out[#out+1] = "/"
				else error("unsupported escape \\" .. e) end
				pos = pos + 2
			else
				out[#out+1] = c
				pos = pos + 1
			end
		end
		return table.concat(out)
	end
	local function parse_value()
		skipws()
		local c = s:sub(pos, pos)
		if c == '"' then return parse_string() end
		if c == "{" then
			pos = pos + 1
			local t = {}
			skipws()
			if s:sub(pos, pos) == "}" then pos = pos + 1 return t end
			while true do
				skipws()
				local k = parse_string()
				skipws()
				if s:sub(pos, pos) ~= ":" then error("expected :") end
				pos = pos + 1
				t[k] = parse_value()
				skipws()
				local sep = s:sub(pos, pos)
				if sep == "}" then pos = pos + 1 break end
				if sep ~= "," then error("expected , or }") end
				pos = pos + 1
			end
			return t
		end
		if c == "[" then
			pos = pos + 1
			local t = {}
			skipws()
			if s:sub(pos, pos) == "]" then pos = pos + 1 return t end
			while true do
				t[#t+1] = parse_value()
				skipws()
				local sep = s:sub(pos, pos)
				if sep == "]" then pos = pos + 1 break end
				if sep ~= "," then error("expected , or ]") end
				pos = pos + 1
			end
			return t
		end
		if c == "t" then pos = pos + 4 return true end
		if c == "f" then pos = pos + 5 return false end
		if c == "n" then pos = pos + 4 return nil end
		local num = s:match("^-?%d+%.?%d*", pos)
		if num then pos = pos + #num return tonumber(num) end
		error("cannot parse at " .. pos)
	end
	local val = parse_value()
	skipws()
	if pos ~= #s + 1 then error("trailing data at " .. pos) end
	return val
end

-------------------------------------------------------------------------------
-- Stubbed Luanti globals
-------------------------------------------------------------------------------
debuglog = {}

dump = function(v)
	local ok, res = pcall(json.encode, v)
	return ok and res or tostring(v)
end

-- scheduler: core.after queue
after_queue = {}
core = {
	log = function() end,
	global_exists = function(name) return name == "xmpp_relay" end,
	settings = {
		get = function(_, key)
			if key == "cloudai.api_key" then return "test-key" end
			return nil
		end,
	},
	register_privilege = function() end,
	register_chatcommand = function() end,
	after = function(_, f, ...)
		after_queue[#after_queue+1] = { f = f, args = { n = select("#", ...), ... } }
	end,
}

fail_write_json = false
core.parse_json = function(s) return json.decode(s) end
core.write_json = function(v)
	if fail_write_json then return nil, "forced write_json failure" end
	return json.encode(v)
end
core.request_http_api = function() return http_api end

-- HTTP layer mock
pending = {}
local function new_handle(request, cb)
	local h = { request = request, cb = cb, state = { completed = false } }
	pending[#pending+1] = h
	return h
end
http_api = {
	fetch_async = function(request) return new_handle(request) end,
	fetch = function(request, cb) new_handle(request, cb) end,
	fetch_async_get = function(h) return h.state end,
}
http_api.complete = function(h, code, data, succeeded, timeout)
	local st = h.state
	st.completed = true
	st.succeeded = succeeded ~= false
	st.code = code or 200
	st.data = data or ""
	st.timeout = timeout or false
	if h.cb then h.cb(st) end
end

xmpp_relay = { send = function(msg) debuglog[#debuglog+1] = msg end }

cb_errors = 0
-- Run queued core.after jobs, tolerating callback errors the way Luanti does
-- (it logs them instead of aborting). Bounded: a poll chain on a still-pending
-- request reschedules forever, so the caller completes responses between pumps.
local function pump(n)
	n = n or 20
	local guard = 0
	while #after_queue > 0 and guard < n do
		guard = guard + 1
		local job = table.remove(after_queue, 1)
		local ok, err = pcall(job.f, unpack(job.args, 1, job.args.n))
		if not ok then
			cb_errors = cb_errors + 1
			print("  callback error:", tostring(err):sub(1, 150))
		end
	end
	return #after_queue
end

-------------------------------------------------------------------------------
-- Test scaffolding
-------------------------------------------------------------------------------
local fails = 0
local function check(cond, label)
	if cond then
		print("PASS  " .. label)
	else
		fails = fails + 1
		print("FAIL  " .. label)
	end
end

local function load_mod()
	assert(loadfile(MOD_PATH))()  -- runs init.lua top level (registers models fetch)
	-- serve GET /models so `model` resolves
	local models_req = pending[#pending]
	http_api.complete(models_req, 200, json.encode({ data = { { id = "deepseek-v4-flash" } } }))
	assert(#after_queue == 0)
end

-- standard test tool; re-entry behavior driven by the reenter_from_tool flag
local tool_calls_made = 0
local active_ctx
local function add_tool_func(args)
	tool_calls_made = tool_calls_made + 1
	if reenter_from_tool then
		reenter_result = { active_ctx:call("reentrant message", function() end) }
	end
	return { sum = args.x + args.y }
end

local function make_ctx(debug)
	local c = cloudai.get_context()
	assert(c, "context unavailable")
	active_ctx = c
	c:set_debug(debug or false)
	local ok, err = c:add_tool({
		name = "add",
		func = add_tool_func,
		description = "Add two numbers",
		strict = true,
		properties = {
			x = { type = "number", description = "first addend" },
			y = { type = "number", description = "second addend" },
		},
	})
	assert(ok, "add_tool failed: " .. tostring(err))
	return c
end

local function fresh()
	debuglog = {}
	pending = {}
	after_queue = {}
	tool_calls_made = 0
	reenter_from_tool = false
	reenter_result = nil
	fail_write_json = false
	cb_errors = 0
end

local function final_resp(content)
	return json.encode({
		choices = { { finish_reason = "stop", message = { role = "assistant", content = content } } },
		usage = { prompt_cache_hit_tokens = 10, prompt_cache_miss_tokens = 5, completion_tokens = 7 },
	})
end

local function toolcall_resp(callid, name, args_json)
	return json.encode({
		choices = { {
			finish_reason = "tool_calls",
			message = { role = "assistant", tool_calls = { {
				id = callid, type = "function",
				["function"] = { name = name, arguments = args_json },
			} } },
		} },
		usage = { prompt_cache_hit_tokens = 10, prompt_cache_miss_tokens = 5, completion_tokens = 7 },
	})
end

-- helper: locate a request by fragment of its URL
local function find_req(frag)
	for i = #pending, 1, -1 do
		if pending[i].request.url:find(frag, 1, true) then return pending[i] end
	end
	return nil
end

local function count_debug_labels(label)
	local n = 0
	for _, msg in ipairs(debuglog) do
		if msg:find("] " .. label .. ":", 1, true) then n = n + 1 end
	end
	return n
end

-------------------------------------------------------------------------------
-- Load the real mod once; contexts are cheap afterwards.
-------------------------------------------------------------------------------
fresh()
load_mod()
print("mod loaded, model = " .. tostring(cloudai and "cloudai table ok"))

-------------------------------------------------------------------------------
-- Scenario 1: basic call -> final response; pending re-call rejected
-------------------------------------------------------------------------------
fresh()
local ctx1 = make_ctx(false)
local cb1_result = {}
ctx1:call("hello", function(history, response, err)
	cb1_result.response = response
	cb1_result.err = err
	cb1_result.history_len = #history
end)
local h1 = find_req("chat/completions")
check(h1 ~= nil, "S1: request dispatched")
check(ctx1._callback ~= nil and ctx1._handle ~= nil, "S1: in-flight markers set")

local ok2, err2 = ctx1:call("second message", function() end)
check(ok2 == false and tostring(err2):find("old response completes", 1, true) ~= nil,
	"S1: call while pending rejected: " .. tostring(err2))

http_api.complete(h1, 200, final_resp("Hello there"))
pump()
check(cb1_result.response ~= nil and cb1_result.response.content == "Hello there",
	"S1: callback fired with final content")
check(cb1_result.err == nil, "S1: no error passed")
check(ctx1._callback == nil and ctx1._handle == nil and ctx1._current_debug_id == nil,
	"S1: markers cleared after completion")

local ok3 = ctx1:call("after completion", function() end)
check(ok3 == true, "S1: new call works after completion")
check(cb_errors == 0, "S1: no callback errors")

-------------------------------------------------------------------------------
-- Scenario 2: drain path inside call() — response completed before next call()
-------------------------------------------------------------------------------
fresh()
local ctx2 = make_ctx(false)
local first_cb = {}
ctx2:call("first", function(history, response) first_cb.response = response end)
local h2a = find_req("chat/completions")
http_api.complete(h2a, 200, final_resp("answer one"))
-- DO NOT drain: let call()'s drain handle the completed response
local second_cb = {}
local ok4 = ctx2:call("second", function(history, response) second_cb.response = response end)
check(ok4 == true, "S2: call() drained completed response and dispatched next")
check(first_cb.response ~= nil and first_cb.response.content == "answer one",
	"S2: old callback invoked via drain")
local h2b = find_req("chat/completions")
check(h2b ~= h2a, "S2: second request dispatched")
http_api.complete(h2b, 200, final_resp("answer two"))
pump()
check(second_cb.response ~= nil and second_cb.response.content == "answer two",
	"S2: second callback fired")
check(cb_errors == 0, "S2: stale poll dies silently at the id check (no callback errors)")

-------------------------------------------------------------------------------
-- Scenario 3: multi-turn tool loop with continuation requests
-------------------------------------------------------------------------------
fresh()
local ctx3 = make_ctx(false)
local cb3 = {}
ctx3:call("calculate 2+3", function(history, response, err) cb3.response = response; cb3.err = err end)
local h3a = find_req("chat/completions")
http_api.complete(h3a, 200, toolcall_resp("call_1", "add", '{"x":2,"y":3}'))
pump()
check(tool_calls_made == 1, "S3: tool executed once")
check(cb3.response == nil, "S3: callback not yet fired (tool turn in progress)")
check(ctx3._callback ~= nil, "S3: still in-flight after tool turn")
local h3b = find_req("chat/completions")
check(h3b ~= nil and h3b ~= h3a, "S3: continuation request dispatched")
-- continuation payload must carry tools
local payload3 = json.decode(h3b.request.data)
check(payload3.tools ~= nil and #payload3.tools == 1 and payload3.tools[1]["function"].name == "add",
	"S3: continuation payload carries the tool definitions")
http_api.complete(h3b, 200, final_resp("5"))
pump()
check(cb3.response ~= nil and cb3.response.content == "5", "S3: final callback fired")
check(ctx3._callback == nil and ctx3._handle == nil, "S3: markers cleared after tool loop")
check(cb_errors == 0, "S3: no callback errors")

-------------------------------------------------------------------------------
-- Scenario 4: re-entrant call() from a tool function is rejected, loop survives
-------------------------------------------------------------------------------
fresh()
local ctx4 = make_ctx(false)
reenter_from_tool = true
local cb4 = {}
ctx4:call("calculate 4+5", function(history, response) cb4.response = response end)
local h4a = find_req("chat/completions")
http_api.complete(h4a, 200, toolcall_resp("call_1", "add", '{"x":4,"y":5}'))
pump()
check(reenter_result ~= nil and reenter_result[1] == false
	and tostring(reenter_result[2]):find("processing a call", 1, true) ~= nil,
	"S4: tool-func re-entry rejected: " .. tostring(reenter_result and reenter_result[2]))
check(tool_calls_made == 1, "S4: re-entry attempt did not corrupt the tool run")
http_api.complete(find_req("chat/completions"), 200, final_resp("9"))
pump()
check(cb4.response ~= nil and cb4.response.content == "9",
	"S4: original call completed normally after rejected re-entry")
check(cb_errors == 0, "S4: no callback errors")

-------------------------------------------------------------------------------
-- Scenario 5: re-entrant call() from inside the callback is rejected
-------------------------------------------------------------------------------
fresh()
local ctx5 = make_ctx(false)
local reenter_from_cb = {}
ctx5:call("question", function(history, response)
	if response then
		reenter_from_cb[1], reenter_from_cb[2] = ctx5:call("chained", function() end)
	end
end)
http_api.complete(find_req("chat/completions"), 200, final_resp("done"))
pump()
check(reenter_from_cb[1] == false
	and tostring(reenter_from_cb[2]):find("processing a call", 1, true) ~= nil,
	"S5: callback re-entry rejected: " .. tostring(reenter_from_cb[2]))
check(ctx5._callback == nil and ctx5._handle == nil, "S5: markers clean after callback")
local ok5 = ctx5:call("after callback", function() end)
check(ok5 == true, "S5: deferred follow-up call works")
check(cb_errors == 0, "S5: no callback errors")

-------------------------------------------------------------------------------
-- Scenario 6: mid-flight guards on setters; exemptions documented
-------------------------------------------------------------------------------
fresh()
local ctx6 = make_ctx(false)
ctx6:call("busy", function() end)
local r
r = { ctx6:add_tool({ name = "other", func = function() end, description = "d" }) }
check(r[1] == false and tostring(r[2]):find("add tools", 1, true) ~= nil, "S6: add_tool blocked mid-flight")
r = { ctx6:set_model("deepseek-v4-flash") }
check(r[1] == false and tostring(r[2]):find("model", 1, true) ~= nil, "S6: set_model blocked mid-flight")
r = { ctx6:set_thinking("enabled") }
check(r[1] == false, "S6: set_thinking blocked mid-flight")
r = { ctx6:set_temperature(0.5) }
check(r[1] == false, "S6: set_temperature blocked mid-flight")
r = { ctx6:set_reasoning_effort("high") }
check(r[1] == false, "S6: set_reasoning_effort blocked mid-flight")
r = { ctx6:set_frequency_penalty(0.1) }
check(r[1] == false, "S6: set_frequency_penalty blocked mid-flight")
r = { ctx6:set_presence_penalty(0.1) }
check(r[1] == false, "S6: set_presence_penalty blocked mid-flight")
r = { ctx6:set_max_steps(5) }
check(r[1] == true, "S6: set_max_steps allowed mid-flight (snapshot semantics)")
r = { ctx6:set_debug(true) }
check(r[1] == true, "S6: set_debug allowed mid-flight (diagnostics)")
-- and everything works again between calls
http_api.complete(find_req("chat/completions"), 200, final_resp("free"))
pump()
check(ctx6:set_model("deepseek-v4-flash") == true, "S6: set_model works between calls")
check(ctx6:set_temperature(1.0) == true, "S6: set_temperature works between calls")
check(cb_errors == 0, "S6: no callback errors")

-------------------------------------------------------------------------------
-- Scenario 7: failed initial dispatch rolls back — context not locked
-------------------------------------------------------------------------------
fresh()
local ctx7 = make_ctx(false)
fail_write_json = true
local ro1, re1 = ctx7:call("doomed", function() end)
check(ro1 == false and re1 ~= nil, "S7: dispatch failed cleanly: " .. tostring(re1))
check(ctx7._callback == nil and ctx7._handle == nil and ctx7._current_debug_id == nil,
	"S7: markers rolled back after failed dispatch")
fail_write_json = false
local ok7 = ctx7:call("retry", function() end)
check(ok7 == true, "S7: context usable after failed dispatch")
http_api.complete(find_req("chat/completions"), 200, final_resp("recovered"))
check(cb_errors == 0, "S7: no callback errors")
pump()

-------------------------------------------------------------------------------
-- Scenario 8: debug mode dumps tools exactly once per call (multi-turn)
-------------------------------------------------------------------------------
fresh()
local ctx8 = make_ctx(true)
local cb8 = {}
ctx8:call("two tool turns", function(history, response) cb8.response = response end)
http_api.complete(find_req("chat/completions"), 200, toolcall_resp("c1", "add", '{"x":1,"y":1}'))
pump()
http_api.complete(find_req("chat/completions"), 200, toolcall_resp("c2", "add", '{"x":2,"y":2}'))
pump()
http_api.complete(find_req("chat/completions"), 200, final_resp("sum"))
pump()
check(cb8.response ~= nil and cb8.response.content == "sum", "S8: call finished")
check(count_debug_labels("initial_history") == 1, "S8: initial_history dumped once")
check(count_debug_labels("tools") == 1, "S8: tools dumped exactly once across 3 requests")
check(count_debug_labels("tool_call") == 2, "S8: two tool_call dumps")
check(count_debug_labels("tool_response") == 2, "S8: two tool_response dumps")
check(count_debug_labels("final_response") == 1, "S8: one final_response dump")
local tools_msg
for _, msg in ipairs(debuglog) do
	if msg:find("] tools:", 1, true) then tools_msg = msg end
end
check(tools_msg ~= nil and tools_msg:find('"add"', 1, true) ~= nil
	and tools_msg:find("Add two numbers", 1, true) ~= nil,
	"S8: tools dump contains the actual definitions")
check(cb_errors == 0, "S8: no callback errors")

-------------------------------------------------------------------------------
-- Scenario 9: no debug output when debug is off, even with tools present
-------------------------------------------------------------------------------
fresh()
local ctx9 = make_ctx(false)
ctx9:call("quiet", function() end)
http_api.complete(find_req("chat/completions"), 200, final_resp("shh"))
pump()
check(#debuglog == 0, "S9: nothing sent to debug channel with debug off")
check(cb_errors == 0, "S9: no callback errors")

-------------------------------------------------------------------------------
-- Scenario 10: drain races a tool-call response (continuation dispatched from
-- inside the drain while the old chain's poll is still queued)
-------------------------------------------------------------------------------
fresh()
local ctx10 = make_ctx(false)
local cb10 = {}
ctx10:call("drain tool race", function(history, response) cb10.response = response end)
local h10a = find_req("chat/completions")
http_api.complete(h10a, 200, toolcall_resp("c1", "add", '{"x":1,"y":1}'))
-- call() again while the tool response is complete-but-unpolled: the drain
-- runs the tool loop and dispatches the continuation itself
local ok10, err10 = ctx10:call("second while draining", function() end)
check(ok10 == false, "S10: re-call during tool-loop drain reports busy")
http_api.complete(find_req("chat/completions"), 200, final_resp("2"))
pump()
check(cb10.response ~= nil and cb10.response.content == "2",
	"S10: original call's callback fired exactly once")
check(cb_errors == 0, "S10: no callback errors despite racing chains")
check(ctx10._callback == nil and ctx10._handle == nil and ctx10._current_request_id == nil,
	"S10: markers clean after the race")



-------------------------------------------------------------------------------
-- Scenario 11: destroy mid-flight with duplicated same-gen polls (drain race)
-- Regression test: the _destroyed branch did not clear _current_request_id,
-- so the second queued poll of the same generation passed the id check and
-- called fetch_async_get on a nil handle.
-------------------------------------------------------------------------------
fresh()
local ctx11 = make_ctx(false)
local cb11 = {}
ctx11:call("race then destroy", function(history, response) cb11.response = response end)
local h11a = find_req("chat/completions")
http_api.complete(h11a, 200, toolcall_resp("c1", "add", '{"x":1,"y":1}'))
-- drain race: the drain runs the tool loop and dispatches the continuation
-- itself, leaving two same-generation polls queued
local ok11 = ctx11:call("re-call during drain", function() end)
check(ok11 == false, "S11: drain re-call reports busy")
-- destroy mid-flight while the continuation is pending
ctx11:destroy()
http_api.complete(find_req("chat/completions"), 200, final_resp("2"))
pump()
check(cb11.response == nil, "S11: callback not invoked on destroyed context")
check(cb_errors == 0, "S11: duplicate poll dies at the id check, no fetch_async_get(nil)")
check(ctx11._current_request_id == nil, "S11: request id cleared by the destroy-terminal path")

print(fails == 0 and "\nALL SCENARIOS PASSED" or ("\n" .. fails .. " SCENARIO CHECK(S) FAILED"))
os.exit(fails == 0 and 0 or 1)
