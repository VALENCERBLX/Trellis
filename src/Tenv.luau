--!nonstrict
-- Trellis
-- Tenv.luau
-- Valence
--
-- `Trellis.__Tenv_(spec)` boots a whole app with no Roblox instances at all.
-- Plain-Lua signals for every channel, fake players, and a clock YOU advance, so a
-- test is deterministic rather than hopeful.
--
--   local T = Trellis.__Tenv_({
--       Junction  = require(Config.Junction),
--       BootOrder = require(Config.BootOrder),
--       Registers = require(Config.Registers),
--       Side      = "Server",
--       Modules   = {
--           Managers = { CombatManager = require(...) },
--           Services = { MemoryService = require(...) },
--       },
--   })
--
--   local ada = T:Join("Ada")
--   T:Send("Network.Combat.Swing", { Combo = 2 }, ada)   -- as if a client sent it
--   T:Step(1/60)                                          -- one frame: heartbeats + timers
--   T:Wait(2)                                             -- 2 seconds of frames
--   T:Sent("Network.Combat.Hit")                          -- what went out, and to whom
--   T.App:Get("CombatManager")
--   T:Stop()
--
-- The seam is the same one the framework's own suite runs on. Bootstrap already takes
-- its IO, its services and its clock as parameters, so a test environment is honest
-- about what it fakes rather than reimplementing the boot.

local Tenv = {}
Tenv.__index = Tenv

-- ============================================================== fake instances ===

-- Enough of the Instance surface for Registry to walk a hierarchy: children, class,
-- and a name. Modules are carried by identity, not by source, so the loader hands
-- back the very table you passed in.
local Node = {}
Node.__index = Node

function Node:GetChildren()
	return self._children
end

function Node:IsA(className: string): boolean
	return self.ClassName == className
end

function Node:GetFullName(): string
	local parts, node = {}, self
	while node do
		table.insert(parts, 1, node.Name)
		node = node._parent
	end
	return table.concat(parts, ".")
end

local function node(className: string, name: string)
	return setmetatable({ ClassName = className, Name = name, _children = {}, _parent = nil }, Node)
end

local function adopt(parent, child)
	child._parent = parent
	table.insert(parent._children, child)
	return child
end

-- ================================================================ fake signals ===

local function signal()
	local handlers = {}
	return {
		Connect = function(_, fn)
			table.insert(handlers, fn)
			return {
				Disconnect = function()
					local i = table.find(handlers, fn)
					if i then
						table.remove(handlers, i)
					end
				end,
			}
		end,
		Fire = function(...)
			for _, fn in table.clone(handlers) do
				fn(...)
			end
		end,
	}
end

-- A remote that records what left and lets a test inject what arrives.
local function remoteEvent(env, path: string)
	local r = { _server = signal(), _client = signal() }
	r.OnServerEvent = { Connect = function(_, fn)
		return r._server.Connect(nil, fn)
	end }
	r.OnClientEvent = { Connect = function(_, fn)
		return r._client.Connect(nil, fn)
	end }

	function r:FireServer(payload)
		table.insert(env.Outbox, { Path = path, Dir = "ToServer", Payload = payload })
	end
	function r:FireClient(player, payload)
		table.insert(env.Outbox, { Path = path, Dir = "ToClient", Player = player, Payload = payload })
	end
	function r:FireAllClients(payload)
		table.insert(env.Outbox, { Path = path, Dir = "ToAll", Payload = payload })
	end

	r._deliver = function(payload, from)
		if env.Side == "Server" then
			r._server.Fire(from, payload)
		else
			r._client.Fire(payload)
		end
	end
	return r
end

local function remoteFunction(env, path: string)
	local r = {}
	function r:InvokeServer(payload)
		table.insert(env.Outbox, { Path = path, Dir = "Invoke", Payload = payload })
		if r.OnServerInvoke then
			return r.OnServerInvoke(env.LocalPlayer, payload)
		end
		return nil
	end
	function r:InvokeClient(player, payload)
		table.insert(env.Outbox, { Path = path, Dir = "InvokeClient", Player = player, Payload = payload })
		if r.OnClientInvoke then
			return r.OnClientInvoke(payload)
		end
		return nil
	end
	return r
end

-- ==================================================================== building ===

local BIN_FOLDERS = {
	Controllers = true,
	Managers = true,
	Services = true,
	Packages = true,
	Utility = true,
	Utilities = true,
	Config = true,
}

function Tenv.new(Bootstrap, spec)
	spec = spec or {}

	local env = setmetatable({
		Side = spec.Side or "Server",
		Time = 0,
		Outbox = {},
		Players = {},
		Remotes = {},
		Modules = {},
		Store = spec.Store,
	}, Tenv)

	-- the hierarchy, as fake nodes; the loader maps a node back to its table
	local values = {}
	local root = node("Folder", "Root")

	local function mount(folder: string, entries)
		local container = adopt(root, node("Folder", folder))
		for name, value in entries or {} do
			local script = adopt(container, node("ModuleScript", name))
			values[script] = value
			env.Modules[name] = value
		end
	end

	local config = adopt(root, node("Folder", "Config"))
	local function mountConfig(name, value)
		if value == nil then
			return
		end
		local script = adopt(config, node("ModuleScript", name))
		values[script] = value
	end

	mountConfig("Junction", spec.Junction or { Local = {}, Network = {} })
	mountConfig("BootOrder", spec.BootOrder)
	mountConfig("Registers", spec.Registers)

	for folder, entries in spec.Modules or {} do
		if not BIN_FOLDERS[folder] then
			error(string.format("[Trellis] __Tenv_: unknown module folder %q", folder), 0)
		end
		mount(folder, entries)
	end
	for folder, entries in spec.Bins or {} do
		mount(folder, entries)
	end

	-- fake services -------------------------------------------------------------
	local playerAdded, playerRemoving = signal(), signal()
	env._playerAdded, env._playerRemoving = playerAdded, playerRemoving

	local players = {
		GetPlayers = function()
			return env.Players
		end,
		PlayerAdded = { Connect = function(_, fn)
			return playerAdded.Connect(nil, fn)
		end },
		PlayerRemoving = { Connect = function(_, fn)
			return playerRemoving.Connect(nil, fn)
		end },
		LocalPlayer = nil,
	}

	if env.Side == "Client" then
		env.LocalPlayer = { Name = "LocalPlayer", UserId = 1 }
		players.LocalPlayer = env.LocalPlayer
		table.insert(env.Players, env.LocalPlayer)
	end
	env._players = players

	local tagged, tagSignals = {}, {}
	local collection = {
		GetTagged = function(_, tag)
			return tagged[tag] or {}
		end,
		GetInstanceAddedSignal = function(_, tag)
			tagSignals[tag] = tagSignals[tag] or { Added = signal(), Removed = signal() }
			return { Connect = function(_, fn)
				return tagSignals[tag].Added.Connect(nil, fn)
			end }
		end,
		GetInstanceRemovedSignal = function(_, tag)
			tagSignals[tag] = tagSignals[tag] or { Added = signal(), Removed = signal() }
			return { Connect = function(_, fn)
				return tagSignals[tag].Removed.Connect(nil, fn)
			end }
		end,
	}
	env._tagged, env._tagSignals = tagged, tagSignals

	-- the drivers, stepped by hand ------------------------------------------------
	local drivers = {}
	local runService = {}
	for _, name in { "Heartbeat", "RenderStepped", "Stepped" } do
		local sig = signal()
		drivers[name] = sig
		runService[name] = { Connect = function(_, fn)
			return sig.Connect(nil, fn)
		end }
	end
	env._drivers = drivers

	-- boot -------------------------------------------------------------------------
	env.App = Bootstrap.Configure({
		Hierarchy = { root },
		Log = spec.Log ~= false,
		Store = spec.Store,
		Inject = spec.Inject,
		Aliases = spec.Aliases,
	}, {
		Side = env.Side,
		Players = players,
		CollectionService = collection,
		RunService = runService,
		Clock = function()
			return env.Time
		end,
		Loader = function(source)
			return values[source]
		end,
		IO = {
			New = function(class, domain, event)
				local path = string.format("Network.%s.%s", domain, event)
				local remote = if string.find(class, "Function")
					then remoteFunction(env, path)
					else remoteEvent(env, path)
				env.Remotes[path] = remote
				return remote
			end,
			Wait = function(domain, event)
				local path = string.format("Network.%s.%s", domain, event)
				local remote = env.Remotes[path] or remoteEvent(env, path)
				env.Remotes[path] = remote
				return remote
			end,
		},
	})

	return env
end

-- ====================================================================== driving ===

-- One frame. Advances the clock, then runs the drivers, so throttled heartbeats and
-- timers behave exactly as they would in game, at whatever rate you choose.
function Tenv:Step(dt: number?)
	local step = dt or (1 / 60)
	self.Time += step
	self._drivers.Heartbeat.Fire(step)
	self._drivers.Stepped.Fire(self.Time, step)
	self._drivers.RenderStepped.Fire(step)
	return self
end

function Tenv:Wait(seconds: number, dt: number?)
	local step = dt or (1 / 60)
	local frames = math.max(1, math.floor(seconds / step))
	for _ = 1, frames do
		self:Step(step)
	end
	return self
end

function Tenv:Now(): number
	return self.Time
end

-- ==================================================================== the world ===

function Tenv:Join(name: string)
	local player = { Name = name, UserId = #self.Players + 100 }
	table.insert(self.Players, player)
	self._playerAdded.Fire(player)
	return player
end

function Tenv:Leave(player)
	local index = table.find(self.Players, player)
	if index then
		table.remove(self.Players, index)
	end
	self._playerRemoving.Fire(player)
	return self
end

function Tenv:Tag(instance, tag: string)
	self._tagged[tag] = self._tagged[tag] or {}
	table.insert(self._tagged[tag], instance)
	local sigs = self._tagSignals[tag]
	if sigs then
		sigs.Added.Fire(instance)
	end
	return instance
end

function Tenv:Untag(instance, tag: string)
	local list = self._tagged[tag] or {}
	local index = table.find(list, instance)
	if index then
		table.remove(list, index)
	end
	local sigs = self._tagSignals[tag]
	if sigs then
		sigs.Removed.Fire(instance)
	end
	return self
end

-- ===================================================================== the wire ===

-- Deliver a payload as if it arrived over the network. `from` is the sending player
-- on the server; omit it for server-to-client traffic.
function Tenv:Send(path: string, payload: any, from: any?)
	local remote = self.Remotes[path]
	if not remote then
		local known = {}
		for known_path in self.Remotes do
			table.insert(known, known_path)
		end
		table.sort(known)
		error(
			string.format("[Trellis] __Tenv_: no remote %q. known: %s", path, table.concat(known, ", ")),
			0
		)
	end
	remote._deliver(payload, from)
	return self
end

-- Answer a Resolve as the far side would.
function Tenv:Answer(path: string, fn)
	local remote = self.Remotes[path]
	if remote then
		remote.OnClientInvoke = fn
	end
	return self
end

-- Everything that left this side, optionally filtered by path.
function Tenv:Sent(path: string?): { any }
	if not path then
		return self.Outbox
	end
	local out = {}
	for _, packet in self.Outbox do
		if packet.Path == path then
			table.insert(out, packet)
		end
	end
	return out
end

function Tenv:Clear()
	self.Outbox = {}
	return self
end

-- ======================================================================= access ===

function Tenv:Get(name: string)
	return self.App:Get(name)
end

function Tenv:Reg(name: string, owner: any?)
	return self.App.Src:Reg(name, owner)
end

function Tenv:Report(): string
	return self.App:Report()
end

function Tenv:Dump(limit: number?): string
	local log = self.App:Log()
	return if log then log:Dump(limit) else "(no log)"
end

function Tenv:Stop()
	self.App:Stop()
	return self
end

return Tenv
