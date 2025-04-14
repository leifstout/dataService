local RunService = game:GetService("RunService")

if RunService:IsServer() then
	return {} :: DataServiceClient
end

local Packages = script.Parent.Parent
local Signal = require(Packages.Signal)
local Networker = require(Packages.Networker)
local DataServiceUtils = require(script.Parent.DataServiceUtils)
local Data = require(script.Parent.Data)

type Signal<T> = Signal.Signal<T>
type Path = Data.Path

local waitSignal = Signal.new()

local DataServiceClient = {
	_data = nil :: Data.Data<any>?,
}
DataServiceClient.networker = Networker.client.new("DataService", DataServiceClient)

function DataServiceClient.fetch(self: DataServiceClient, path: Path?, dontSet: boolean?): any
	local value = self.networker:fetch("get", path)
	if not dontSet then
		self._data:set(path, value)
	end
	return value
end

function DataServiceClient.get(self: DataServiceClient, path: Path?): any
	self:waitForData()
	return self._data:get(path)
end

function DataServiceClient.set(self: DataServiceClient, path: Path, value: any)
	self._data:set(path, value)
end

function DataServiceClient.update(self: DataServiceClient, path: Path, callback: (any) -> any): any
	return self._data:update(path, callback)
end

function DataServiceClient.arrayInsert(self: DataServiceClient, path: Path, value: any, index: number?)
	self._data:arrayInsert(path, value, index)
end

function DataServiceClient.arrayRemove(self: DataServiceClient, path: Path, index: number): any
	return self._data:arrayRemove(path, index)
end

function DataServiceClient.getChangedSignal(self: DataServiceClient, path: Path): Signal<any>
	return self._data:getChangedSignal(path)
end

function DataServiceClient.getIndexChangedSignal(self: DataServiceClient, path: Path): Signal<any>
	return self._data:getIndexChangedSignal(path)
end

function DataServiceClient.getArrayInsertedSignal(self: DataServiceClient, path: Path): Signal<any>
	return self._data:getArrayInsertedSignal(path)
end

function DataServiceClient.getArrayRemovedSignal(self: DataServiceClient, path: Path): Signal<any>
	return self._data:getArrayRemovedSignal(path)
end

function DataServiceClient.waitForData(self: DataServiceClient): any
	local data = self._data
	if data then
		return data
	end

	waitSignal:Wait()
	return self._data
end

DataServiceClient[DataServiceUtils.enums.actions.set] = DataServiceClient.set
DataServiceClient[DataServiceUtils.enums.actions.arrayInsert] = DataServiceClient.arrayInsert
DataServiceClient[DataServiceUtils.enums.actions.arrayRemove] = DataServiceClient.arrayRemove
DataServiceClient[DataServiceUtils.enums.actions.init] = function(self: DataServiceClient, data: any)
	assert(self._data == nil, "DataServiceClient: Data already initialized")
	self._data = Data.new(data)
	waitSignal:Fire()
end

export type DataServiceClient = typeof(DataServiceClient)

DataServiceClient:waitForData()

return DataServiceClient
