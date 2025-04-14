local Packages = script.Parent.Parent
local Signal = require(Packages.Signal)

local AUTO_CLEAR_SIGNAL_TIMER = 30
local Data = {}
Data.__index = Data

type PlayerData<T> = T & {}
export type Path = string | { string }
type Signal<T> = Signal.Signal<T>

export type Data<T> = typeof(setmetatable(
	{} :: {
		_data: T,
		_autoClearThread: thread?,
		_signals: {
			changed: { [string]: Signal<any> },
			indexChanged: { [string]: Signal<any> },
			arrayInserted: { [string]: Signal<any> },
			arrayRemoved: { [string]: Signal<any> },
		},
	},
	Data
))

function Data.new<T>(data: T): Data<T>
	local self = {
		_data = data,
		_autoClearThread = nil,
		_signals = {
			changed = {},
			indexChanged = {},
			arrayInserted = {},
			arrayRemoved = {},
		},
	}

	setmetatable(self, Data)

	self._autoClearThread = task.spawn(function()
		while true do
			task.wait(AUTO_CLEAR_SIGNAL_TIMER)
			self:_clearSignals()
		end
	end)

	return self
end

local function pathToString(path: Path): string
	if type(path) == "string" then
		return path
	end

	local pathString = ""
	local maxIndex = #path - 1
	for i, key in ipairs(path) do
		if type(key) == "number" then
			pathString ..= "#"
		end

		pathString ..= key
		if i < maxIndex then
			pathString ..= "."
		end
	end

	return pathString
end

function Data.get<T>(self: Data<T>, path: Path?): T & any
	if not path then
		return self._data
	end

	local data = self._data
	if type(path) == "string" then
		return data[path]
	end

	for _, key in ipairs(path) do
		data = data[key]
	end

	return data
end

function Data.set<T>(self: Data<T>, path: Path, value: any): ()
	local data = self._data
	if type(path) == "string" then
		data[path] = value
		self:_firePathChangedSignals(path)
		return
	end

	for i = 1, #path - 1 do
		data = data[path[i]]
	end

	data[path[#path]] = value
	self:_firePathChangedSignals(path)
end

function Data.update<T>(self: Data<T>, path: Path, callback: (any) -> any): any
	local old = self:get(path)
	local new = callback(old)
	self:set(path, new)
	return new
end

function Data.arrayInsert<T>(self: Data<T>, path: Path, value: any, index: number?): ()
	local data = self:get(path)
	assert(type(data) == "table", "Data at path is not a table")

	if index then
		table.insert(data, index, value)
	else
		table.insert(data, value)
	end

	local pathString = self:_firePathChangedSignals(path)

	local signal = self._signals.arrayInserted[pathString]
	if signal then
		signal:Fire(index or #data, value)
	end
end

function Data.arrayRemove<T>(self: Data<T>, path: Path, index: number): any
	local data = self:get(path)
	assert(type(data) == "table", "Data at path is not a table")
	local value = table.remove(data, index)
	local pathString = self:_firePathChangedSignals(path)

	local signal = self._signals.arrayRemoved[pathString]
	if signal then
		signal:Fire(index, value)
	end

	return value
end

function Data.getChangedSignal<T>(self: Data<T>, path: Path): Signal<any>
	return self:_getSignal(path, "changed")
end

function Data.getIndexChangedSignal<T>(self: Data<T>, path: Path): Signal<any>
	return self:_getSignal(path, "indexChanged")
end

function Data.getArrayInsertedSignal<T>(self: Data<T>, path: Path): Signal<any>
	return self:_getSignal(path, "arrayInserted")
end

function Data.getArrayRemovedSignal<T>(self: Data<T>, path: Path): Signal<any>
	return self:_getSignal(path, "arrayRemoved")
end

function Data._firePathChangedSignals<T>(self: Data<T>, path: Path): string
	if type(path) == "string" then
		self:_fireChangedSignal(path, self:get(path))
		return path
	end

	local value = self._data
	local pathString = ""
	local maxIndex = #path - 1

	for i, key in ipairs(path) do
		value = value[key]

		if i > 1 then
			self:_fireIndexChangedSignal(pathString, key, value)
		end

		if type(key) == "number" then
			pathString ..= "#"
		end
		pathString ..= key

		self:_fireChangedSignal(pathString, value)

		if i < maxIndex then
			pathString ..= "."
		end
	end

	return pathString
end

function Data._fireChangedSignal<T>(self: Data<T>, pathString: string, value: any): ()
	local signal = self._signals.changed[pathString]
	if signal then
		signal:Fire(value)
	end
end

function Data._fireIndexChangedSignal<T>(self: Data<T>, pathString: string, index: string | number, value: any): ()
	local signal = self._signals.indexChanged[pathString]
	if signal then
		signal:Fire(index, value)
	end
end

function Data._getSignal<T>(self: Data<T>, path: Path, signalType: string): Signal<any>
	local pathString = pathToString(path)
	if not self._signals[signalType][pathString] then
		self._signals[signalType][pathString] = Signal.new()
	end

	return self._signals[signalType][pathString]
end

function Data._clearSignals<T>(self: Data<T>): ()
	for _, signals in self._signals do
		for i, signal: Signal<any> in signals do
			if #signal:GetConnections() > 0 then
				continue
			end

			signal:Destroy()
			signals[i] = nil
		end
	end
end

function Data.destroy<T>(self: Data<T>): ()
	if self._autoClearThread then
		task.cancel(self._autoClearThread)
		self._autoClearThread = nil
	end

	for _, signals in self._signals do
		for _, signal in signals do
			signal:Destroy()
		end
	end

	self._signals = nil :: any
end

return Data
