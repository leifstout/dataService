# DataService
Data handler and replication

# Server

```luau
local DataService = require(path.to.service).server

DataService:init({
	template = {
		currency = 0,
		inventory = {
			item1 = {
				...
			},
			item2 = {
				...
			},
		},
		foo = {
			bar = 4,
			nest = {
				apple = "pie",
				dog = "bone",
			},
		},
		arr = { 1, 2, 3, 4 },
	},
	profileStoreIndex = "Official"
	useMock = false,
})

-- output: 0
print(DataService:get(player, "currency"))

DataService:set(player, {"foo", "nest", "dog"}, "good boy")

DataService:update(player, "currency", function(amount: number)
	return amount + 1
end)

```

# Client

```luau
local DataService = require(path.to.service).client

DataService:getChangedSignal("currency"):Connect(function(amount: number)
	print("Currency changed to " .. amount)
end)

DataService:getIndexChangedSignal({"foo", "nest"}):Connect(function(index: string, value: any)
	print("Index: " .. index .. " changed to: " .. value .. " in the nested table!")
end)

print(DataService:get("inventory"))

```