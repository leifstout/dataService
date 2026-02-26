---
sidebar_position: 1
---

# Getting Started with DataService

DataService provides a simple way to manage player data on the server while keeping clients in sync automatically.

## 1) Install

Add DataService to your `wally.toml`:

```toml
[dependencies]
DataService = "leifstout/dataService@^1.0.0"
```

Then run:

```bash
wally install
```

## 2) Define your data template

Create a module for your default player data:

```lua
return {
	currency = 0,
	level = 1,
	xp = 0,
	inventory = {},
	settings = {
		musicVolume = 0.5,
		sfxVolume = 0.5,
	},
}
```

> Keep values JSON-compatible (numbers, strings, booleans, arrays, dictionaries).

## 3) Initialize on the server

In a server script, initialize DataService once:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage.Packages

local DataService = require(Packages.DataService).server
local dataTemplate = require(script.Parent.dataTemplate)

DataService:init({
	template = dataTemplate,
	profileStoreIndex = "Default",
})
```

## 4) Read and react on the client

Use the client module to read data and subscribe to changes:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage.Packages

local DataService = require(Packages.DataService).client

local currency = DataService:get({ "currency" })
print("Currency:", currency)

DataService:getChangedSignal({ "currency" }):Connect(function(newValue)
	print("Currency updated:", newValue)
end)
```

## 5) Update data on the server

When game logic changes player values, mutate data on the server:

```lua
-- Example: add currency when a player completes a reward
DataService:update(player, { "currency" }, function(current)
	return current + 100
end)
```

## Next steps

- Browse the **complete API reference**: https://leifstout.github.io/dataService/api
- Review options like `useMock`, `dontSave`, and `resetData` in the server API.
