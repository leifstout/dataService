--!strict
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

if RunService:IsClient() then
	return {} :: DataServiceServer
end

local Packages = script.Parent.Parent
local Signal = require(Packages.Signal)
local Networker = require(Packages.Networker)
local ProfileService = if RunService:IsServer() then require(Packages.ProfileService) else nil :: any
local Data = require(script.Parent.Data)
local DataServiceUtils = require(script.Parent.DataServiceUtils)

local DATA_PREFIX = "PLAYER_"

type Path = Data.Path
type Signal<T> = Signal.Signal<T>

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
	profileStoreIndex: string,
	useMock: boolean?,
	viewedUserId: number?,
	overridenUserId: number?,
	dontSave: boolean?,
	resetData: boolean?,
}

type Profile = {
	Data: any,
	Release: (Profile) -> (),
	[any]: any,
}

--[=[
	@class DataServiceServer
	The server-side service for managing player data.
]=]
local DataServiceServer = {
	_profiles = {} :: { [Player]: Profile },
	_data = {} :: { [Player]: Data.Data<any> },
	_waitSignals = {} :: { [Player]: Signal.Signal<any> },
	options = {} :: DataOptions,
}

--[=[
	@method init
	@within DataServiceServer
	@param options DataOptions
	Initializes DataServiceServer with the provided options.
	```lua
	local dataTemplate = require(path.to.datatemplate)
	DataServiceServer:init({
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
	assert(not self.options, "DataServiceServer has already been initialized.")
	self.options = options
	self.profileStore = ProfileService.GetProfileStore(options.profileStoreIndex, options.template)
	self.networker = Networker.server.new("DataService", self, {
		self.get,
	})

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

function DataServiceServer._playerAdded(self: DataServiceServer, player: Player): ()
	local userId = self.options.overridenUserId or self.options.viewedUserId or player.UserId
	local index = DATA_PREFIX .. userId

	if self.options.resetData and not self.options.viewedUserId then
		self.profileStore:WipeProfileAsync(index)
	end

	local profile: Profile = if self.options.useMock
		then self.profileStore.Mock:LoadProfileAsync(index)
		elseif self.options.viewedUserId or self.options.dontSave then self.profileStore:ViewProfileAsync(index)
		else self.profileStore:LoadProfileAsync(index)

	if not profile then
		player:Kick()
		return
	end

	profile:AddUserId(userId)
	profile:Reconcile()
	profile:ListenToRelease(function()
		self._profiles[player] = nil
		player:Kick()
	end)

	if not player:IsDescendantOf(Players) then
		profile:Release()
		return
	end

	self._profiles[player] = profile
	self:_initPlayer(player, profile.Data)
end

function DataServiceServer._playerRemoving(self: DataServiceServer, player: Player): ()
	local profile = self._profiles[player]

	if not profile then
		return
	end

	local success, err: any? = pcall(self.onPlayerRemoving, self, player, profile.Data)
	if not success then
		warn(err or "Error onPlayerRemoving for " .. player.Name)
	end

	profile:Release()
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
	function DataServiceServer:onPlayerInit(player: Player, data: DataTemplate): ()
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
	@method onPlayerRemoving
	@within DataServiceServer
	@tag Override
	@param player Player
	@param data DataTemplate

	Overridable method called when a player is about to leave the game.
	You can use this method to perform cleanup or save data before the player leaves.

	```lua
	function DataServiceServer:onPlayerRemoving(player: Player, data: DataTemplate): ()
		data.totalPlayTime += os.time() - data.sessionJoinTime
	end
	```
]=]
function DataServiceServer.onPlayerRemoving(_self: DataServiceServer, _player: Player, _data: any): () end

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
	local currency = DataServiceServer:get(player, { "currency" })
	local tutorialStep = DataServiceServer:get(player, { "tutorial", "step" })
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
	DataServiceServer:set(player, { "currency" }, 100)
	DataServiceServer:set(player, { "tutorial", "step" }, 2)
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
	local updatedCurrency = DataServiceServer:update(player, { "currency" }, function(currentValue)
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
	DataServiceServer:arrayInsert(player, { "inventory" }, newItem)
	DataServiceServer:arrayInsert(player, { "inventory" }, newItem, 1) -- Inserts at index 1
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
	DataServiceServer:arrayRemove(player, { "inventory" }, 1) -- Removes the item at index 1
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
	DataServiceServer:getChangedSignal(player, { "currency" }):Connect(function(newValue)
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
	DataServiceServer:getIndexChangedSignal(player, { "tutorial" }):Connect(function(index, newValue)
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
	DataServiceServer:getArrayInsertedSignal(player, { "inventory" }):Connect(function(index, value)
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
	DataServiceServer:getArrayRemovedSignal(player, { "inventory" }):Connect(function(index, value)
		print("Item removed from index", index, "with value:", value)
	end)
	```
]=]
function DataServiceServer.getArrayRemovedSignal(self: DataServiceServer, player: Player, path: Path): Signal<any>
	return self._data[player]:getArrayRemovedSignal(path)
end

export type DataServiceServer = typeof(DataServiceServer)

return DataServiceServer
