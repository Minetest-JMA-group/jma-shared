# CloudAI Mod for Minetest

A lightweight Minetest mod that integrates cloud-based AI assistants (like DeepSeek) with function calling capabilities directly into your game.

## Features

- 🤖 **Cloud AI Integration** - Connect to AI APIs like DeepSeek, OpenAI, etc.
- 🔧 **Function Calling** - Define custom Lua functions that the AI can call
- 💬 **Conversation Context** - Maintains chat history and context
- ⚙️ **Configurable** - Customizable API endpoints, models, timeouts, and parameters
- 🔐 **Secure** - API keys stored in `minetest.conf`
- 🛠️ **Developer-Friendly API** - Easy integration into other mods
- 💾 **Persistent Settings** - Configuration changes persist across restarts via shareddb
- 🧠 **Model Management** - Auto-fetch available models from the API, per-context model selection
- 💰 **Balance Check** - View your account balance in-game

## Installation

1. Place the `cloudai` folder in your Minetest `mods/` directory
2. Enable `http_api` in your `minetest.conf`:
   ```conf
   secure.http_mods = cloudai
   ```
3. Configure your API settings in `minetest.conf`:
   ```conf
   cloudai.api_key = "your-api-key-here"
   cloudai.url = "https://api.deepseek.com"  # optional, base URL only (no /chat/completions)
   cloudai.model = "deepseek-v4-flash"   # optional
   cloudai.timeout = 10  # optional, in seconds
   ```

## Usage

### In-Game Commands

- `/cloudai help` - Show help message
- `/cloudai timeout [value]` - View or set the API timeout (persisted)
- `/cloudai url [value]` - View or set the API base URL (persisted)
- `/cloudai balance` - View your account balance from the provider
- `/cloudai models list` - List all available models from the provider
- `/cloudai models refresh` - Refresh the model list (fetches from API)
- `/cloudai models set <model>` - Set the default model (persisted)
- `/cloudai models get` - Show the current default model

### API Usage in Mods

```lua
-- Create a new AI context
local context, err = cloudai.get_context()
if not context then
    core.log("error", err)
    return
end

-- Set system prompt (must be before first message)
context:set_system_prompt("You are a helpful assistant in a Minetest game.")

-- Configure AI parameters
context:set_model("deepseek-v4-flash")     -- per-context model selection
context:set_thinking("enabled")            -- or "disabled" (default)
context:set_reasoning_effort("high")       -- "high" or "max"
context:set_max_steps(15)                  -- max tool calls per response

-- Add custom tools/functions
context:add_tool({
    name = "get_player_info",
    func = function(args)
        local player = core.get_player_by_name(args.player_name)
        if player then
            return {
                position = player:get_pos(),
                health = player:get_hp()
            }
        end
        return {error = "Player not found"}
    end,
    description = "Get information about a player",
    strict = true,
    properties = {
        player_name = {
            type = "string",
            description = "Name of the player"
        }
    }
})

-- Send a message and handle response
-- Returns true on success, false + error on immediate failure (e.g. JSON error)
local ok, err = context:call("Tell me about player default", function(history, response, error)
    if error then
        core.log("error", "AI Error: " .. tostring(error))
        return
    end

    if response then
        core.chat_send_all("AI: " .. response.content)
    end
end)
if not ok then
    core.log("error", "Failed to send message: " .. tostring(err))
end
```

### Tool Function Guidelines

- Tool functions receive arguments as a Lua table, or a string if JSON parsing failed in non-strict mode
- Return values can be strings or tables (automatically converted to JSON)
- Set `strict = true` to require valid JSON arguments
- Define `properties` following JSON Schema format for parameter validation

### Error Handling

The callback receives three arguments: `history`, `response`, `error`.
- If `error` is non-nil, something went wrong (timeout, API error, malformed response, tool hallucination, etc.)
- If `error` is nil, `response` contains the AI's message with `.content` and `.role`

In addition, `context:call()` itself returns `false, err` on immediate failures (e.g., JSON serialization error, destroyed context, or concurrent request still in flight).

## Configuration Settings

| Setting | Default | Description |
|---------|---------|-------------|
| `cloudai.api_key` | *Required* | Your API key |
| `cloudai.url` | `https://api.deepseek.com` | API base URL (endpoint path is appended automatically) |
| `cloudai.model` | `deepseek-v4-flash` | Model name |
| `cloudai.timeout` | `10` | Request timeout in seconds |

Settings can also be changed at runtime through in-game commands and are persisted across restarts via shareddb.

## Requirements

- Minetest 5.0.0 or later
- `http_api` enabled
- Valid API key from a supported AI service

## License

GPL-3.0-or-later © 2026 Marko Petrović
