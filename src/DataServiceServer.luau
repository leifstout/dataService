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

	self:onPlayerRemoving(player, profile.Data)
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

function DataServiceServer.onPlayerInit(_self: DataServiceServer, _player: Player, _data: any): () end
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

function DataServiceServer.hasProfile(self: DataServiceServer, player: Player): boolean
	return self._profiles[player] ~= nil
end

function DataServiceServer.getProfile(self: DataServiceServer, player: Player): Profile
	assert(self._profiles[player], "Profile does not exist for " .. player.Name)
	return self._profiles[player]
end

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

function DataServiceServer.get(self: DataServiceServer, player: Player, path: Path?): any
	return self._data[player]:get(path)
end

function DataServiceServer.set(self: DataServiceServer, player: Player, path: Path, value: any, dontReplicate: boolean?)
	if not dontReplicate then
		self.networker:fire(player, DataServiceUtils.enums.actions.set, path, value)
	end

	self._data[player]:set(path, value)
end

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

function DataServiceServer.getChangedSignal(self: DataServiceServer, player: Player, path: Path): Signal<any>
	return self._data[player]:getChangedSignal(path)
end

function DataServiceServer.getIndexChangedSignal(self: DataServiceServer, player: Player, path: Path): Signal<any>
	return self._data[player]:getIndexChangedSignal(path)
end

function DataServiceServer.getArrayInsertedSignal(self: DataServiceServer, player: Player, path: Path): Signal<any>
	return self._data[player]:getArrayInsertedSignal(path)
end

function DataServiceServer.getArrayRemovedSignal(self: DataServiceServer, player: Player, path: Path): Signal<any>
	return self._data[player]:getArrayRemovedSignal(path)
end

export type DataServiceServer = typeof(DataServiceServer)

return DataServiceServer
