--!strict
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

if RunService:IsClient() then
	return {} :: DataServiceServer
end

local Packages = script.Parent.Parent
local Signal = require(Packages.Signal)
local Networker = require(Packages.Networker)
local ProfileStore = if RunService:IsServer() then require(Packages.ProfileStore) else nil :: any
local Data = require(script.Parent.Data)
local DataServiceUtils = require(script.Parent.DataServiceUtils)

local DATA_PREFIX = "PLAYER_"
local DEFAULT_PROFILE_STORE_INDEX = "Default"

type Path = Data.Path
type Signal<T> = Signal.Signal<T>

type MessageData = {
	key: string,
	data: { any },
}

--[=[
	@type DataTemplate { [string]: any }
	@within DataServiceServer
	
	Defines the structure of player data used by the DataServiceServer.

	```lua
	local datatemplate = {
		currency = 0,
		level = 1,
		xp = 0,
		inventory = {},
		tutorial = {
			completed = false,
			step = 0,
		},
		stats = {
			enemiesDefeated = 0,
			timePlayed = 0,
			questsCompleted = 0,
		}
	}
	```

	
	:::note
	Player data automatically reconciles the template on join if new keys are added.
	:::
	:::warning
	Follow JSON rules for all data. (e.g., no Vector3, CFrame, etc.)
	:::
]=]
type DataTemplate = { [string]: any }

--[=[
	@interface DataOptions
	@within DataServiceServer
	.template DataTemplate -- Template dictionary for player data.
	.profileStoreIndex string -- Index for the ProfileStore.
	.useMock boolean? -- Use Mock data for testing.
	.viewedUserId number? -- User ID to view data for. Use to view a specific player's data without saving.
	.overridenUserId number? -- User ID to override for the profile. Use to play on another player's save.
	.dontSave boolean? -- Prevent saving the profile. Use for testing without saving.
	.resetData boolean? -- Reset the data on player join. Use to wipe data for testing.
	
	```lua
	local options = {
		template = require(path.to.datatemplate),
		profileStoreIndex = "Public",
	}
	```

	Provides options for initializing the DataServiceServer.
]=]
type DataOptions = {
	template: any,
	useMock: boolean?,
	viewedUserId: number?,
	overridenUserId: number?,
	dontSave: boolean?,
	resetData: boolean?,
	profileStoreIndex: string?,
	profileStoreDataPrefix: string?,
}

type Profile = ProfileStore.Profile<any>

--[=[
	@class DataServiceServer
	The server-side service for managing player data.
]=]
local DataServiceServer = {
	_profiles = {} :: { [Player]: Profile },
	_data = {} :: { [Player]: Data.Data<any> },
	_waitSignals = {} :: { [Player]: Signal.Signal<any> },
	_globalCallbacks = {} :: { [string]: (player: Player, { any }) -> boolean? },
	_globalCallbackAdded = Signal.new() :: Signal.Signal<string>,
	_removalFunctions = {} :: { (player: Player, data: any) -> () },
	options = {} :: DataOptions,
}

--[=[
	@method init
	@within DataServiceServer
	@param options DataOptions
	Initializes DataServiceServer with the provided options.
	```lua
	local DataService = require(path.to.DataService).server
	local dataTemplate = require(path.to.datatemplate)

	DataService:init({
		template = dataTemplate,
		profileStoreIndex = "Testing",
		useMock = true,
	})
	```
	:::warning
	`:init(...)` must be called before using any other methods. Attempting to `init` more than once will throw an error.
	:::
]=]
function DataServiceServer.init(self: DataServiceServer, options: DataOptions): ()
	assert(RunService:IsServer(), "DataServiceServer can only be used on the server.")
	assert(not self.playerStore, "DataServiceServer has already been initialized.")
	self.options = options
	self.playerStore = ProfileStore.New(options.profileStoreIndex or DEFAULT_PROFILE_STORE_INDEX, options.template)
	self.networker = Networker.server.new("DataService", self, { self.get })

	for _, player: Player in Players:GetPlayers() do
		task.spawn(function()
			self:_playerAdded(player)
		end)
	end

	Players.PlayerAdded:Connect(function(player: Player)
		self:_playerAdded(player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self:_playerRemoving(player)
	end)
end

local function storeCancel(player: Player)
	return {
		Cancel = function()
			return player.Parent ~= Players
		end,
	}
end

--[=[
	@method resetData
	@within DataServiceServer
	@param player Player

	Resets the data for the specified player by removing their profile from the store.
	The player is then kicked from the game with a message to rejoin.

	```lua
	local DataService = require(path.to.DataService).server
	DataService:resetData(player)
	```
]=]
function DataServiceServer.resetData(self: DataServiceServer, player: Player): ()
	local index = self:_getProfileKey(player.UserId)
	self:_playerRemoving(player)
	self.playerStore:RemoveAsync(index)
	player:Kick("Your data has been reset. Please rejoin.")
end

function DataServiceServer._playerAdded(self: DataServiceServer, player: Player): ()
	local userId = self.options.overridenUserId or self.options.viewedUserId or player.UserId
	local index = self:_getProfileKey(userId)

	if self.options.resetData and not self.options.viewedUserId then
		self.playerStore:RemoveAsync(index)
	end

	local profile: Profile = if self.options.useMock
		then self.playerStore.Mock:StartSessionAsync(index, storeCancel(player))
		elseif self.options.viewedUserId or self.options.dontSave then self.playerStore:GetAsync(index)
		else self.playerStore:StartSessionAsync(index, storeCancel(player))

	if not profile then
		player:Kick(`Profile load fail - Please rejoin`)
		return
	end

	profile:AddUserId(userId)
	profile:Reconcile()
	profile.OnSessionEnd:Connect(function()
		self._profiles[player] = nil
		player:Kick(`Profile session end - Please rejoin`)
	end)

	if not player:IsDescendantOf(Players) then
		player:Kick(`Profile load fail - Please rejoin`)
		return
	end

	self._profiles[player] = profile
	self:_initPlayer(player, profile.Data)

	if not player:IsDescendantOf(Players) then
		player:Kick(`Profile load fail - Please rejoin`)
		return
	end

	profile:MessageHandler(function(messageData: MessageData, processed: () -> ())
		local cb = self._globalCallbacks[messageData.key]
		if cb then
			if cb(player, messageData.data) ~= false then
				processed()
			end
			return
		end

		local waitConnection
		waitConnection = self._globalCallbackAdded:Connect(function(key: string)
			if key ~= messageData.key then
				return
			end
			if self._globalCallbacks[messageData.key](player, messageData.data) ~= false then
				processed()
			end
			waitConnection:Disconnect()
		end)
	end)
end

function DataServiceServer._getProfileKey(self: DataServiceServer, userId: number | string): string
	return (self.options.profileStoreDataPrefix or DATA_PREFIX) .. tostring(userId)
end

--[=[
	@method sendGlobalMessage
	@within DataServiceServer
	@param key string
	@param userId number | string
	@param data { any }
	@return boolean

	Sends a global message to the specified user's profile.
	Returns true if the message was sent successfully, false otherwise.

	```lua
	local DataService = require(path.to.DataService).server
	DataService:sendGlobalMessage("SendGift", userId, { currency = 100, from = "Friend" })
	```
]=]
function DataServiceServer.sendGlobalMessage(
	self: DataServiceServer,
	key: string,
	userId: number | string,
	data: { any }
): boolean
	local messageData: MessageData = { key = key, data = data }
	return self.playerStore:MessageAsync(self:_getProfileKey(userId), messageData)
end

--[=[
	@method addGlobalCallback
	@within DataServiceServer
	@param key string
	@param cb (player: Player, data: { any }) -> boolean?

	Adds a global callback function for handling messages with the specified key.
	The callback receives the player and data as parameters.
	If the callback returns false, the message is not processed further.

	```lua
	local DataService = require(path.to.DataService).server
	DataService:addGlobalCallback("SendGift", function(player: Player, data: { any }): boolean?
		print("Received gift for", player.Name, "with data:", data)
		-- Process the gift here
	end)
	```
]=]
function DataServiceServer.addGlobalCallback(
	self: DataServiceServer,
	key: string,
	cb: (player: Player, { any }) -> boolean?
): ()
	assert(self._globalCallbacks[key] == nil, "Global callback already exists for key: " .. key)
	self._globalCallbacks[key] = cb
	self._globalCallbackAdded:Fire(key)
end

function DataServiceServer._playerRemoving(self: DataServiceServer, player: Player): ()
	local profile = self._profiles[player]

	if not profile then
		return
	end

	for _, fn in self._removalFunctions do
		local success, err: any? = pcall(fn, player, profile.Data)
		if not success then
			warn(err or "Error in removal function for " .. player.Name)
		end
	end

	profile:EndSession()
	self._profiles[player] = nil

	local waitSignal = self._waitSignals[player]
	if waitSignal then
		waitSignal:Destroy()
		self._waitSignals[player] = nil
	end

	local data = self._data[player]
	if data then
		data:destroy()
		self._data[player] = nil
	end
end

--[=[
	@method onPlayerInit
	@within DataServiceServer
	@tag Override
	@param player Player
	@param data DataTemplate

	Overridable method called when a player initializes their data.
	You can use this method to set initial values or perform actions when a player joins.

	```lua
	local DataService = require(path.to.DataService).server
	function DataService:onPlayerInit(player: Player, data: DataTemplate): ()
		print(player.Name .. " has initialized with data:", data)
		data.sessionJoinTime = os.time() -- We can directly modify data since no connections exist yet.
	end
	```

	:::note
	`onPlayerInit` is called after a player's data has loaded but before it is sent to the client or is available to the server.
	:::
]=]
function DataServiceServer.onPlayerInit(_self: DataServiceServer, _player: Player, _data: any): () end

--[=[
	@method addPlayerRemovingCallback
	@within DataServiceServer
	@param fn (player: Player, data: any) -> ()

	Add any number of functions to be called when a player is removed.
	Used to perform cleanup or save data before the player leaves.

	```lua
	DataService:addPlayerRemovingCallback(function(player: Player, data: any): ()
		print(player.Name .. " is leaving with data:", data)
		-- Perform any cleanup or save operations here
	end)
	```

	```lua
	local disconnect = DataService:addPlayerRemovingCallback(function(player: Player, data: any): ()
		data.currency = 0
	end)

	-- Later, you can disconnect this function if needed
	disconnect()
	```
]=]
function DataServiceServer.addPlayerRemovingCallback(
	self: DataServiceServer,
	fn: (player: Player, data: any) -> ()
): () -> ()
	table.insert(self._removalFunctions, fn)
	return function()
		local index = table.find(self._removalFunctions, fn)
		if index then
			table.remove(self._removalFunctions, index)
		end
	end
end

--[=[
	@method asyncGetProfile
	@within DataServiceServer
	@param userId number | string
	@return Profile?

	Asynchronously retrieves the profile for the given user ID using internal ProfileStore.
]=]
function DataServiceServer.asyncGetProfile(self: DataServiceServer, userId: number | string): Profile?
	local profileKey = DATA_PREFIX .. tostring(userId)
	return self.playerStore:GetAsync(profileKey)
end

function DataServiceServer._initPlayer(self: DataServiceServer, player: Player, data: any): ()
	self._data[player] = Data.new(data)
	self:onPlayerInit(player, data)
	self.networker:fire(player, DataServiceUtils.enums.actions.init, data)

	local waitSignal = self._waitSignals[player]
	if waitSignal then
		waitSignal:Fire()
		waitSignal:Destroy()
		self._waitSignals[player] = nil
	end
end

--[=[
	@method hasProfile
	@within DataServiceServer
	@param player Player
	@return boolean

	Checks if a profile exists for the given player.
]=]
function DataServiceServer.hasProfile(self: DataServiceServer, player: Player): boolean
	return self._profiles[player] ~= nil
end

--[=[
	@method getProfile
	@within DataServiceServer
	@param player Player
	@return Profile

	Retrieves the profile for the given player.
	Throws an error if the profile does not exist.
]=]
function DataServiceServer.getProfile(self: DataServiceServer, player: Player): Profile
	assert(self._profiles[player], "Profile does not exist for " .. player.Name)
	return self._profiles[player]
end

--[=[
	@method waitForData
	@within DataServiceServer
	@yields
	@param player Player
	@return Data

	Waits for the player's data to be initialized and returns it.
	If the data is already available, it returns immediately.
]=]
function DataServiceServer.waitForData(self: DataServiceServer, player: Player): Data.Data<any>
	local data = self._data[player]
	if data then
		return data
	end

	local waitSignal = self._waitSignals[player]
	if not waitSignal then
		waitSignal = Signal.new()
		self._waitSignals[player] = waitSignal
	end

	waitSignal:Wait()
	return self._data[player]
end

--[=[
	@method get
	@within DataServiceServer
	@param player Player
	@param path Path?
	@return any

	Retrieves the value at the specified path for the given player.
	If no path is provided, it returns the entire data object.

	```lua
	local DataService = require(path.to.DataService).server
	local currency = DataService:get(player, { "currency" })
	local tutorialStep = DataService:get(player, { "tutorial", "step" })
	```
]=]
function DataServiceServer.get(self: DataServiceServer, player: Player, path: Path?): any
	return self._data[player]:get(path)
end

--[=[
	@method set
	@within DataServiceServer
	@param player Player
	@param path Path
	@param value any
	@param dontReplicate boolean? -- Optional, defaults to false

	Sets the value at the specified path for the given player.
	If `dontReplicate` is true, it does not replicate the change to the client.

	```lua
	local DataService = require(path.to.DataService).server
	DataService:set(player, { "currency" }, 100)
	DataService:set(player, { "tutorial", "step" }, 2)
	```
]=]
function DataServiceServer.set(self: DataServiceServer, player: Player, path: Path, value: any, dontReplicate: boolean?)
	if not dontReplicate then
		self.networker:fire(player, DataServiceUtils.enums.actions.set, path, value)
	end

	self._data[player]:set(path, value)
end

--[=[
	@method update
	@within DataServiceServer
	@param player Player
	@param path Path
	@param callback (any) -> any
	@param dontReplicate boolean? -- Optional, defaults to false
	@return any

	Updates the value at the specified path for the given player using a callback function.
	If `dontReplicate` is true, it does not replicate the change to the client.

	```lua
	local updatedCurrency = DataService:update(player, { "currency" }, function(currentValue)
		return currentValue + 50
	end)
	```
]=]
function DataServiceServer.update(
	self: DataServiceServer,
	player: Player,
	path: Path,
	callback: (any) -> any,
	dontReplicate: boolean?
): any
	local value = self._data[player]:update(path, callback)

	if not dontReplicate then
		self.networker:fire(player, DataServiceUtils.enums.actions.set, path, value)
	end

	return value
end

--[=[
	@method arrayInsert
	@within DataServiceServer
	@param player Player
	@param path Path
	@param value any
	@param index number? -- Optional, defaults to nil (appends to the end)
	@param dontReplicate boolean? -- Optional, defaults to false

	Inserts a value into an array at the specified path for the given player.
	If `dontReplicate` is true, it does not replicate the change to the client.

	```lua
	DataService:arrayInsert(player, { "inventory" }, newItem)
	DataService:arrayInsert(player, { "inventory" }, newItem, 1) -- Inserts at index 1
	```

	:::note
	This mimics the behavior of `table.insert`
	:::
]=]
function DataServiceServer.arrayInsert(
	self: DataServiceServer,
	player: Player,
	path: Path,
	value: any,
	index: number?,
	dontReplicate: boolean?
)
	if not dontReplicate then
		self.networker:fire(player, DataServiceUtils.enums.actions.arrayInsert, path, value, index)
	end

	self._data[player]:arrayInsert(path, value, index)
end

--[=[
	@method arrayRemove
	@within DataServiceServer
	@param player Player
	@param path Path
	@param index number
	@param dontReplicate boolean? -- Optional, defaults to false

	Removes a value from an array at the specified path for the given player.
	If `dontReplicate` is true, it does not replicate the change to the client.

	```lua
	DataService:arrayRemove(player, { "inventory" }, 1) -- Removes the item at index 1
	```

	:::note
	This mimics the behavior of `table.remove`
	:::
]=]
function DataServiceServer.arrayRemove(
	self: DataServiceServer,
	player: Player,
	path: Path,
	index: number,
	dontReplicate: boolean?
): any
	local value = self._data[player]:arrayRemove(path, index)

	if not dontReplicate then
		self.networker:fire(player, DataServiceUtils.enums.actions.arrayRemove, path, index)
	end

	return value
end

--[=[
	@method getChangedSignal
	@within DataServiceServer
	@param player Player
	@param path Path
	@return Signal<any>

	Retrieves a signal that fires when the value at the specified path changes.

	```lua
	DataService:getChangedSignal(player, { "currency" }):Connect(function(newValue)
		print("Currency changed to:", newValue)
	end)
	```
]=]
function DataServiceServer.getChangedSignal(self: DataServiceServer, player: Player, path: Path): Signal<any>
	return self._data[player]:getChangedSignal(path)
end

--[=[
	@method getIndexChangedSignal
	@within DataServiceServer
	@param player Player
	@param path Path
	@return Signal<any>

	Retrieves a signal that fires when any child at the specified path changes.

	```lua
	DataService:getIndexChangedSignal(player, { "tutorial" }):Connect(function(index, newValue)
		print("Tutorial changed at index", index, "changed to:", newValue)
	end)
	```
]=]
function DataServiceServer.getIndexChangedSignal(self: DataServiceServer, player: Player, path: Path): Signal<any>
	return self._data[player]:getIndexChangedSignal(path)
end

--[=[
	@method getArrayInsertedSignal
	@within DataServiceServer
	@param player Player
	@param path Path
	@return Signal<any>

	Retrieves a signal that fires when an item is inserted into an array at the specified path.

	```lua
	DataService:getArrayInsertedSignal(player, { "inventory" }):Connect(function(index, value)
		print("Item inserted at index", index, "with value:", value)
	end)
	```
]=]
function DataServiceServer.getArrayInsertedSignal(self: DataServiceServer, player: Player, path: Path): Signal<any>
	return self._data[player]:getArrayInsertedSignal(path)
end

--[=[
	@method getArrayRemovedSignal
	@within DataServiceServer
	@param player Player
	@param path Path
	@return Signal<any>

	Retrieves a signal that fires when an item is removed from an array at the specified path.

	```lua
	DataService:getArrayRemovedSignal(player, { "inventory" }):Connect(function(index, value)
		print("Item removed from index", index, "with value:", value)
	end)
	```
]=]
function DataServiceServer.getArrayRemovedSignal(self: DataServiceServer, player: Player, path: Path): Signal<any>
	return self._data[player]:getArrayRemovedSignal(path)
end

export type DataServiceServer = typeof(DataServiceServer) & {
	playerStore: ProfileStore.ProfileStore<any>,
	networker: Networker.Server,
}

return DataServiceServer
