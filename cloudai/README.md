# CloudAI Mod for Minetest

A lightweight Minetest mod that integrates cloud-based AI assistants (like DeepSeek) with function calling capabilities directly into your game.

## Features

- 🤖 **Cloud AI Integration** - Connect to AI APIs like DeepSeek, OpenAI, etc.
- 🔧 **Function Calling** - Define custom Lua functions that the AI can call
- 💬 **Conversation Context** - Maintains chat history and context
- ⚙️ **Configurable** - Customizable API endpoints, models, and timeouts
- 🔐 **Secure** - API keys stored in `minetest.conf`
- 🛠️ **Developer-Friendly API** - Easy integration into other mods

## Installation

1. Place the `cloudai` folder in your Minetest `mods/` directory
2. Enable `http_api` in your `minetest.conf`:
   ```conf
   secure.http_mods = cloudai
   ```
3. Configure your API settings in `minetest.conf`:
   ```conf
   cloudai.api_key = "your-api-key-here"
   cloudai.url = "https://api.deepseek.com/chat/completions"  # optional
   cloudai.model = "deepseek-chat"  # optional
   cloudai.timeout = 10  # optional, in seconds
   ```

## Usage

### In-Game Commands

- `/cloudai help` - Show help message
- `/cloudai timeout [value]` - View or set the API timeout

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
context:call("Tell me about player default", function(history, response, error)
    if error then
        core.log("error", "AI Error: " .. tostring(error))
        return
    end
    
    if response then
        core.chat_send_all("AI: " .. response.content)
    end
end)
```

### Tool Function Guidelines

- Tool functions receive arguments as a Lua table, or a string if JSON parsing failed in non-strict mode
- Return values can be strings or tables (automatically converted to JSON)
- Set `strict = true` to require valid JSON arguments
- Define `properties` following JSON Schema format for parameter validation

## Configuration Settings

| Setting | Default | Description |
|---------|---------|-------------|
| `cloudai.api_key` | *Required* | Your API key |
| `cloudai.url` | DeepSeek API | API endpoint URL |
| `cloudai.model` | `deepseek-chat` | Model name |
| `cloudai.timeout` | `10` | Request timeout in seconds |

## Requirements

- Minetest 5.0.0 or later
- `http_api` enabled
- Valid API key from a supported AI service

## License

GPL-3.0-or-later © 2026 Marko Petrović