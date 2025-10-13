local Packages = script.Parent.Parent
local Signal = require(Packages.Signal)

local Data = {}
Data.__index = Data

type PlayerData<T> = T & {}
export type Path = string | { string }
type Signal<T> = Signal.Signal<T>
type WeakValueTable<T> = typeof(setmetatable({} :: { [string]: T }, { __mode = "v" }))

export type Data<T> = typeof(setmetatable(
	{} :: {
		_data: T,
		_signals: {
			changed: { [string]: Signal.Signal<any, any?> },
			indexChanged: { [string]: Signal.Signal<any, any?> },
			arrayInserted: { [string]: Signal<any> },
			arrayRemoved: { [string]: Signal<any> },
		},
		_weakSignals: {
			changed: WeakValueTable<Signal.Signal<any, any?>>,
			indexChanged: WeakValueTable<Signal.Signal<any, any?>>,
			arrayInserted: WeakValueTable<Signal<any>>,
			arrayRemoved: WeakValueTable<Signal<any>>,
		},
	},
	Data
))

function Data.new<T>(data: T): Data<T>
	local self = {
		_data = data,
		_signals = {
			changed = {},
			indexChanged = {},
			arrayInserted = {},
			arrayRemoved = {},
		},
		_weakSignals = {
			changed = setmetatable({}, { __mode = "v" }),
			indexChanged = setmetatable({}, { __mode = "v" }),
			arrayInserted = setmetatable({}, { __mode = "v" }),
			arrayRemoved = setmetatable({}, { __mode = "v" }),
		},
	}

	setmetatable(self, Data)

	return self
end

local function pathToString(path: Path): string
	if type(path) == "string" then
		return path
	end

	local pathString = ""
	local maxIndex = #path
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
		local prev = data[path]
		data[path] = value
		self:_firePathChangedSignals(path, prev)
		return
	end

	for i = 1, #path - 1 do
		data = data[path[i]]
	end

	local prev = data[path[#path]]
	data[path[#path]] = value
	self:_firePathChangedSignals(path, prev)
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

function Data._firePathChangedSignals<T>(self: Data<T>, path: Path, prev: any?): string
	if type(path) == "string" then
		self:_fireChangedSignal(path, self:get(path), prev)
		return path
	end

	local value = self._data
	local pathString = ""

	for i, key in ipairs(path) do
		value = value[key]

		if i > 1 then
			self:_fireIndexChangedSignal(pathString, key, value, prev)
			pathString ..= "."
		end

		if type(key) == "number" then
			pathString ..= "#"
		end
		pathString ..= key

		self:_fireChangedSignal(pathString, value, prev)
	end

	return pathString
end

function Data._fireChangedSignal<T>(self: Data<T>, pathString: string, value: any, prev: any?): ()
	local signal = self._signals.changed[pathString]
	if signal then
		signal:Fire(value, prev)
	end
end

function Data._fireIndexChangedSignal<T>(
	self: Data<T>,
	pathString: string,
	index: string | number,
	value: any,
	prev: any?
): ()
	local signal = self._signals.indexChanged[pathString]
	if signal then
		signal:Fire(index, value, prev)
	end
end

function Data._getSignal<T>(self: Data<T>, path: Path, signalType: string): Signal<any>
	local pathString = pathToString(path)
	local weakSignals = self._weakSignals[signalType]
	local signal = weakSignals[pathString]
	if signal then
		return signal
	end

	signal = Signal.new()
	weakSignals[pathString] = signal
	local connCreators = { Connect = signal.Connect, Once = signal.Once }
	local connCount = 0
	local strongSignals = self._signals[signalType]

	for funcName, originalFunc in connCreators do
		signal[funcName] = function(_, handler: (...any?) -> ())
			local conn = originalFunc(signal, handler)
			connCount += 1
			strongSignals[pathString] = signal

			local originalDisconnect = conn.Disconnect
			conn.Disconnect = function()
				if conn.Connected then
					connCount -= 1
					if connCount <= 0 then
						strongSignals[pathString] = nil
					end
				end
				originalDisconnect(conn)
			end

			conn.Destroy = conn.Disconnect
			return conn
		end
	end

	local originalDestroy = signal.Destroy
	signal.Destroy = function()
		connCount = 0
		strongSignals[pathString] = nil
		weakSignals[pathString] = nil
		originalDestroy(signal)
	end

	local originalDisconnectAll = signal.DisconnectAll
	signal.DisconnectAll = function()
		connCount = 0
		strongSignals[pathString] = nil
		originalDisconnectAll(signal)
	end

	return signal
end

function Data.destroy<T>(self: Data<T>): ()
	for _, signals in self._signals do
		for _, signal in signals do
			signal:Destroy()
		end
	end

	self._signals = nil :: any
end

return Data
