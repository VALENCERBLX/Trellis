--!nonstrict
-- Trellis
-- Src.luau
-- Valence
--
-- The injected context. One per module, bound to that module's name, and the only
-- surface a Controller / Manager / Service talks through.
--
--   Src:Local("Input"):Post("Pressed", key)
--   Src:Network("Combat"):Subscribe("Swing", function(payload, from) end)
--   Src:Network("Session"):Resolve("Get", query):Next(print)
--
-- Every event name is checked against the Junction AT BIND TIME, so a typo errors
-- immediately listing the domain's real events rather than going quietly nowhere.
--
-- `from` is always the handler's SECOND parameter, and is the sending Player or nil
-- when the event originated on this side. It is never a field: Src is a per-module
-- singleton, so a shared slot would be overwritten by the next event if a handler
-- yields, and it is the value authority is gated on.

local Reaction = require(script.Parent.Reaction)
local Schema = require(script.Parent.Schema)

local Src = {}
Src.__index = Src

-- Which verbs a Kind allows. Calling the wrong one is a mistake the map can catch.
local VERBS = {
	Static = { Post = true, Subscribe = true, Once = true, PostTo = true, PostAll = true, PostExcept = true },
	Resolve = { Resolve = true, Respond = true, ResolveFrom = true },
}

-- Forward-declared: Src:_scope references them before they are defined below.
local LocalScope
local NetworkScope

local function fail(...)
	error("[Trellis] " .. string.format(...), 0)
end

-- ==================================================================== the Src ===

function Src.new(entry, runtime)
	local self = setmetatable({
		Name = entry.Name,
		Role = entry.Role,
		Side = runtime.Side,
		Player = runtime.Player,
		Main = runtime.Registry and runtime.Registry.Main,

		_runtime = runtime,
		_junction = runtime.Junction,
		_scopes = {},
		_channels = {},
		_cleanups = {},
	}, {
		-- The derived getters are looked up on the registry rather than copied onto
		-- Src, because a bin can appear AFTER a Src exists. An adopted Worker creates
		-- the Worker bin at runtime, and every Src built before it still has to see
		-- :GetWorker.
		__index = function(t, key)
			local own = Src[key]
			if own ~= nil then
				return own
			end

			local registry = rawget(t, "_runtime").Registry
			local generated = registry and registry[key]
			if type(generated) == "function" then
				return generated
			end

			return nil
		end,
	})

	return self
end

-- ==================================================================== scopes ===

function Src:Local(domain: string)
	return self:_scope("Local", domain)
end

function Src:Network(domain: string)
	return self:_scope("Network", domain)
end

function Src:_scope(namespace: string, domain: string)
	local key = namespace .. "." .. domain
	local cached = self._scopes[key]
	if cached then
		return cached
	end

	local scope = setmetatable({
		_src = self,
		_namespace = namespace,
		_domain = domain,
	}, { __index = if namespace == "Network" then NetworkScope else LocalScope })

	self._scopes[key] = scope
	return scope
end

-- Resolve the entry and check the verb against its Kind. This is where a typo'd
-- event name and a Post-on-a-Resolve both die, with the domain's real events listed.
function Src:_entry(namespace: string, domain: string, event: string, verb: string)
	local entry = self._junction:Resolve(namespace, domain, event)

	if not VERBS[entry.Kind][verb] then
		fail(
			'%s is Kind "%s"; :%s is not one of its verbs (%s)',
			entry.Path,
			entry.Kind,
			verb,
			if entry.Kind == "Static" then "Post, Subscribe, Once" else "Resolve, Respond"
		)
	end

	return entry
end

-- ================================================================== delivery ===

-- Everything an inbound payload must clear, on the RECEIVING side, before any
-- handler sees it. Order matters and is cheapest-first:
--
--   1. RATE    -- the per-player budget the Fence declared. FIRST, deliberately:
--                 it is the cheapest check, and a flood of malformed payloads is
--                 exactly the traffic a rate limit exists to stop. Validating first
--                 would exempt garbage from the budget, which is backwards.
--   2. SCHEMA  -- declared on the Junction entry. Malformed traffic dies here, so
--                 no fence and no handler ever sees a payload of the wrong shape.
--   3. FENCES  -- your own predicates. Many may fence one event and ALL must pass,
--                 so a shape check and a rate limiter coexist without knowing about
--                 each other.
function Src:_admit(entry, payload, from): (boolean, string?)
	local allowed, why = self._junction:Allow(entry.Path, from)
	if not allowed then
		return false, why
	end

	if entry.Schema then
		local ok, reason = Schema.Check(entry.Schema, payload, entry.Path)
		if not ok then
			return false, reason
		end
	end

	for _, fencer in self._junction:FencersFor(entry.Path) do
		local ok, passed, reason = pcall(fencer.Fence, fencer, entry.Path, payload, from)
		if not ok then
			return false, "fence errored: " .. tostring(passed)
		end
		if not passed then
			return false, reason or "refused"
		end
	end

	return true
end

-- One place refusals are reported, so the log, the panel and the console all see
-- the same event rather than three half-versions of it.
function Src:_refuse(entry, payload, from, reason)
	local log = self._runtime.Log
	if log then
		log:Refused(entry.Path, payload, from, reason)
	end
	warn(string.format("[Trellis] %s refused: %s", entry.Path, tostring(reason)))
end

function Src:_record(entry, payload, from)
	local log = self._runtime.Log
	if log then
		log:Event(entry.Path, payload, from)
	end
	self:_latch(entry.Path, payload)
end

-- Src:Await resolves the FIRST time an event is delivered on this side, and latches
-- so a late awaiter resolves immediately. Delivery is the trigger, which is why this
-- lives beside the log rather than beside Post: an event posted from here but
-- delivered elsewhere has not happened *here*.
function Src:_latch(path: string, value: any)
	local latches = self._runtime.Latches
	if not latches then
		return
	end

	local latch = latches[path]
	if latch and latch.Done then
		return
	end

	if not latch then
		latch = { Waiting = {} }
		latches[path] = latch
	end

	latch.Done = true
	latch.Value = value

	local waiting = latch.Waiting
	latch.Waiting = {}
	for _, resolve in waiting do
		task.spawn(resolve, value)
	end
end

-- Destination is a delivery FILTER, not a direction: only subscribers owned by the
-- named module receive the event. Absent (or "any") means everyone in the domain.
local function addressed(entry, owner: string): boolean
	return entry.Destination == nil or entry.Destination == owner
end

function Src:_deliver(entry, payload, from)
	local signal = self._junction:Signal(entry.Path)
	if not signal then
		return
	end

	local passed, reason = self:_admit(entry, payload, from)
	if not passed then
		self:_refuse(entry, payload, from, reason)
		return
	end

	self:_record(entry, payload, from)

	for _, sub in table.clone(signal.Handlers) do
		if addressed(entry, sub.Owner) then
			task.spawn(sub.Handler, payload, from)
		end
	end
end

-- Subscribing to an event the Junction routes elsewhere is always a mistake: the
-- handler would never fire, silently. Say so at bind time.
function Src:_checkAddressed(entry)
	if entry.Destination and entry.Destination ~= self.Name then
		warn(
			string.format(
				"[Trellis] %s subscribed to %s, but the Junction routes it to %s -- it will never fire",
				self.Name,
				entry.Path,
				entry.Destination
			)
		)
	end
end

function Src:_subscribeLocal(entry, handler, once: boolean)
	local signal = self._junction:Signal(entry.Path)
	if not signal then
		fail("%s has no local signal on the %s (is it Side-scoped?)", entry.Path, self.Side)
	end

	local sub = { Owner = self.Name, Handler = handler, Once = once }
	table.insert(signal.Handlers, sub)

	local function cancel()
		local index = table.find(signal.Handlers, sub)
		if index then
			table.remove(signal.Handlers, index)
		end
	end

	if once then
		sub.Handler = function(payload, from)
			cancel()
			handler(payload, from)
		end
	end

	self:OnCleanup(cancel)
	return cancel
end

-- ============================================================== Local scope ===

LocalScope = {}

function LocalScope:Post(event: string, payload: any?)
	local src = self._src
	local entry = src:_entry(self._namespace, self._domain, event, "Post")
	src:_deliver(entry, payload, nil) -- in-process: no sender, therefore trusted
end

function LocalScope:Subscribe(event: string, handler)
	local src = self._src
	local entry = src:_entry(self._namespace, self._domain, event, "Subscribe")
	src:_checkAddressed(entry)
	return src:_subscribeLocal(entry, handler, false)
end

function LocalScope:Once(event: string, handler)
	local src = self._src
	local entry = src:_entry(self._namespace, self._domain, event, "Once")
	src:_checkAddressed(entry)
	return src:_subscribeLocal(entry, handler, true)
end

function LocalScope:Resolve(event: string, payload: any?)
	local src = self._src
	local entry = src:_entry(self._namespace, self._domain, event, "Resolve")
	local signal = src._junction:Signal(entry.Path)

	if not signal or not signal.Responder then
		return Reaction.reject(string.format("%s has no responder", entry.Path))
	end

	local ok, result = pcall(signal.Responder, payload, nil)
	if not ok then
		return Reaction.reject(result)
	end
	return Reaction.resolve(result)
end

function LocalScope:Respond(event: string, handler)
	local src = self._src
	local entry = src:_entry(self._namespace, self._domain, event, "Respond")
	local signal = src._junction:Signal(entry.Path)

	if signal.Responder then
		fail("%s already has a responder -- exactly one module answers an event", entry.Path)
	end
	signal.Responder = handler

	local function cancel()
		signal.Responder = nil
	end
	src:OnCleanup(cancel)
	return cancel
end

-- ============================================================ Network scope ===

NetworkScope = setmetatable({}, { __index = LocalScope })

-- Direction is implicit in the side: a client Post goes up to the server, a server
-- Post goes down to every client. :PostTo targets one.
function NetworkScope:Post(event: string, payload: any?)
	local src = self._src
	local entry = src:_entry(self._namespace, self._domain, event, "Post")
	local remote = src._junction:Instance(entry.Path)

	if src.Side == "Client" then
		remote:FireServer(payload)
	else
		remote:FireAllClients(payload)
	end
end

function NetworkScope:PostTo(player: Player, event: string, payload: any?)
	local src = self._src
	if src.Side ~= "Server" then
		fail("%s: :PostTo is server-only", src.Name)
	end
	local entry = src:_entry(self._namespace, self._domain, event, "PostTo")
	src._junction:Instance(entry.Path):FireClient(player, payload)
end

function NetworkScope:PostAll(event: string, payload: any?)
	local src = self._src
	if src.Side ~= "Server" then
		fail("%s: :PostAll is server-only", src.Name)
	end
	local entry = src:_entry(self._namespace, self._domain, event, "PostAll")
	src._junction:Instance(entry.Path):FireAllClients(payload)
end

function NetworkScope:PostExcept(except: Player, event: string, payload: any?)
	local src = self._src
	if src.Side ~= "Server" then
		fail("%s: :PostExcept is server-only", src.Name)
	end
	local entry = src:_entry(self._namespace, self._domain, event, "PostExcept")
	local remote = src._junction:Instance(entry.Path)

	for _, player in src._runtime.Players:GetPlayers() do
		if player ~= except then
			remote:FireClient(player, payload)
		end
	end
end

function NetworkScope:Subscribe(event: string, handler)
	local src = self._src
	local entry = src:_entry(self._namespace, self._domain, event, "Subscribe")
	src:_checkAddressed(entry)

	local remote = src._junction:Instance(entry.Path)
	local connection

	if src.Side == "Server" then
		connection = remote.OnServerEvent:Connect(function(player, payload)
			local passed, reason = src:_admit(entry, payload, player)
			if not passed then
				src:_refuse(entry, payload, player, reason)
				return
			end
			src:_record(entry, payload, player)
			handler(payload, player)
		end)
	else
		connection = remote.OnClientEvent:Connect(function(payload)
			-- Inbound from the server: no sender, therefore trusted. Still schema
			-- checked, because a mismatch here is a bug on our own side.
			local passed, reason = src:_admit(entry, payload, nil)
			if not passed then
				src:_refuse(entry, payload, nil, reason)
				return
			end
			src:_record(entry, payload, nil)
			handler(payload, nil)
		end)
	end

	local function cancel()
		connection:Disconnect()
	end
	src:OnCleanup(cancel)
	return cancel
end

function NetworkScope:Resolve(event: string, payload: any?)
	local src = self._src
	if src.Side ~= "Client" then
		fail("%s: on the server use :ResolveFrom(player, ...) -- there is no single peer", src.Name)
	end

	local entry = src:_entry(self._namespace, self._domain, event, "Resolve")
	local remote = src._junction:Instance(entry.Path)

	return Reaction.new(function(resolve, reject)
		task.spawn(function()
			local ok, result = pcall(remote.InvokeServer, remote, payload)
			if ok then
				resolve(result)
			else
				reject(result)
			end
		end)
	end)
end

-- RemoteFunction:InvokeClient blocks until that client answers, and a hung or hostile
-- client never does. The timeout is therefore not optional: without it, one player can
-- strand a server thread forever. Override per call if you must.
local RESOLVE_FROM_TIMEOUT = 10

function NetworkScope:ResolveFrom(player: Player, event: string, payload: any?, options: any?)
	local src = self._src
	if src.Side ~= "Server" then
		fail("%s: :ResolveFrom is server-only", src.Name)
	end

	local entry = src:_entry(self._namespace, self._domain, event, "ResolveFrom")
	local remote = src._junction:Instance(entry.Path)

	local reaction = Reaction.new(function(resolve, reject)
		task.spawn(function()
			local ok, result = pcall(remote.InvokeClient, remote, player, payload)
			if ok then
				resolve(result)
			else
				reject(result)
			end
		end)
	end)

	local seconds = (options and options.Timeout) or RESOLVE_FROM_TIMEOUT
	if seconds and seconds > 0 then
		reaction:Timeout(seconds, string.format("%s: client did not answer in %gs", entry.Path, seconds))
	end
	return reaction
end

function NetworkScope:Respond(event: string, handler)
	local src = self._src
	local entry = src:_entry(self._namespace, self._domain, event, "Respond")
	local remote = src._junction:Instance(entry.Path)

	if src.Side == "Server" then
		if remote.OnServerInvoke then
			fail("%s already has a responder -- exactly one module answers an event", entry.Path)
		end
		remote.OnServerInvoke = function(player, payload)
			local passed, reason = src:_admit(entry, payload, player)
			if not passed then
				src:_refuse(entry, payload, player, reason)
				return nil, reason
			end
			src:_record(entry, payload, player)
			return handler(payload, player)
		end
	else
		remote.OnClientInvoke = function(payload)
			return handler(payload, nil)
		end
	end

	local function cancel()
		if src.Side == "Server" then
			remote.OnServerInvoke = nil
		else
			remote.OnClientInvoke = nil
		end
	end
	src:OnCleanup(cancel)
	return cancel
end

-- ================================================================ the rest ===

function Src:Reg(register: string, owner: Player?)
	if not self._runtime.Reg then
		fail("%s asked for register %q, but no Registers config was found", self.Name, register)
	end
	return self._runtime.Reg:Open(register, owner or self.Player)
end

-- One-shot latch on "Namespace.Domain.Event". Resolves the first time that event is
-- posted on this side, and latches, so a late awaiter resolves immediately. Await
-- answers "has this happened yet"; Subscribe answers "tell me every time".
function Src:Await(path: string)
	local latches = self._runtime.Latches
	local latch = latches[path]

	if latch and latch.Done then
		return Reaction.resolve(latch.Value)
	end

	if not latch then
		latch = { Waiting = {} }
		latches[path] = latch
	end

	return Reaction.new(function(resolve)
		table.insert(latch.Waiting, resolve)
	end)
end

-- =================================================================== Channels ===
--
-- Service to Service, directly. Not through the Junction, not over the wire: a plain
-- call into the other Service on this side, so it is synchronous and returns whatever
-- the handler returns.
--
--   local Memory = Src:Channel("Memory")
--   local profile = Memory:Get("profile", { UserId = id })
--   Memory:Patch("profile", { Coins = 5 })
--
-- The verbs are the REST methods and nothing else. That is the whole vocabulary, so
-- a Service's surface to its peers is seven names rather than however many someone
-- felt like inventing, and reading a call tells you what it does to the other side.
--
--   Get      read, changes nothing
--   Post     submit something new
--   Put      replace it wholesale
--   Patch    change part of it
--   Delete   remove it
--   Head     does it exist, how big is it: no body
--   Options  what does this Service answer
--
-- The other side implements the verbs it supports, taking (route, payload, from),
-- where `from` is the calling Service's name:
--
--   function MemoryService:Get(route, payload, from)
--       if route == "profile" then return self.profiles[payload.UserId] end
--   end
--
-- ONLY Services may open a channel, and only to a Service. A Controller or Manager
-- reaching for one is an error: this is the seam between Services, and widening it to
-- everything would make it just another way to call anything.

local REST = { "Get", "Post", "Put", "Patch", "Delete", "Head", "Options" }

local Channel = {}
Channel.__index = Channel

function Channel:_call(verb: string, route: string?, payload: any?)
	local src = self._src
	local entry = src._runtime.Modules[self._target]

	if not entry then
		fail("%s: no Service named %q on the %s", src.Name, self._target, src.Side)
	end

	local target = entry.Module
	local handler = target[verb]

	if type(handler) ~= "function" then
		-- Options is answerable without the Service implementing it: the framework
		-- already knows which verbs it defines.
		if verb == "Options" then
			local supported = {}
			for _, name in REST do
				if type(target[name]) == "function" then
					table.insert(supported, name)
				end
			end
			return supported
		end

		local supported = {}
		for _, name in REST do
			if type(target[name]) == "function" then
				table.insert(supported, name)
			end
		end
		fail(
			"%s answers no :%s. it implements: %s",
			self._target,
			verb,
			#supported > 0 and table.concat(supported, ", ") or "(nothing)"
		)
	end

	return handler(target, route, payload, src.Name)
end

for _, verb in REST do
	Channel[verb] = function(self, route: string?, payload: any?)
		return self:_call(verb, route, payload)
	end
end

-- A channel to another Service on this side. Cached, so repeated calls are free.
function Src:Channel(service: string)
	if self.Role ~= "Service" then
		fail(
			"%s is a %s, and channels are between Services. Use the Junction to reach "
				.. "a Service from a %s.",
			self.Name,
			self.Role,
			self.Role
		)
	end
	if service == self.Name then
		fail("%s opened a channel to itself", self.Name)
	end

	local cached = self._channels[service]
	if cached then
		return cached
	end

	local entry = self._runtime.Modules[service]
	if not entry then
		local services = {}
		for name, other in self._runtime.Modules do
			if other.Role == "Service" and name ~= self.Name then
				table.insert(services, name)
			end
		end
		table.sort(services)
		fail(
			"%s opened a channel to %q, which is not on the %s. Services here: %s",
			self.Name,
			service,
			self.Side,
			#services > 0 and table.concat(services, ", ") or "(none)"
		)
	end
	if entry.Role ~= "Service" then
		fail(
			"%s opened a channel to %q, which is a %s. Channels are between Services.",
			self.Name,
			service,
			entry.Role
		)
	end

	local channel = setmetatable({ _src = self, _target = service }, Channel)
	self._channels[service] = channel
	return channel
end

-- ==================================================================== Workers ===

-- Send a Worker to a client and start it there. Server only: the module lives in
-- ServerStorage and never replicates until this is called, so a client that is never
-- deployed to never receives the code.
--
--   Src:Deploy("Scout", player, { Target = boss })
--   Src:Deploy("Scout", "all", payload)
function Src:Deploy(worker: string, target: any, payload: any?): boolean
	if self.Side ~= "Server" then
		fail("%s: :Deploy is server-only", self.Name)
	end
	if not self._runtime.Deploy then
		fail("%s: no Workers bin in the hierarchy, so there is nothing to deploy", self.Name)
	end
	return self._runtime.Deploy(worker, target, payload)
end

-- Stop a deployed Worker and remove it. The client runs its :Stop and cleans up.
function Src:Recall(worker: string, target: any): boolean
	if self.Side ~= "Server" then
		fail("%s: :Recall is server-only", self.Name)
	end
	if not self._runtime.Recall then
		return false
	end
	return self._runtime.Recall(worker, target)
end

function Src:OnCleanup(fn)
	table.insert(self._cleanups, fn)
end

-- ============================================================ granted by Req ===

-- Req "Trove": one container, cleaned on :Stop.
function Src:_grantTrove(trove)
	self.Trove = trove
	self:OnCleanup(function()
		trove:Clean()
	end)
end

-- Req "Timer": every timer is bound to this module's lifetime, so the commonest
-- Roblox leak, a delayed call firing into a torn-down module, cannot happen.
function Src:_grantTimers(scheduler)
	self.Delay = function(_, seconds: number, fn)
		return scheduler:Timer(seconds, fn, false, self.Name)
	end
	self.Every = function(_, seconds: number, fn)
		return scheduler:Timer(seconds, fn, true, self.Name)
	end
	self.Cancel = function(_, handle)
		scheduler:CancelTimer(handle)
	end

	self:OnCleanup(function()
		scheduler:CancelOwned(self.Name)
	end)
end

function Src:Inspect()
	return {
		Name = self.Name,
		Side = self.Side,
		Scopes = (function()
			local keys = {}
			for key in self._scopes do
				table.insert(keys, key)
			end
			table.sort(keys)
			return keys
		end)(),
		Routes = self._junction:Paths(),
	}
end

function Src:_teardown()
	for i = #self._cleanups, 1, -1 do
		local fn = self._cleanups[i]
		if type(fn) == "function" then
			pcall(fn)
		elseif type(fn) == "table" and fn.Disconnect then
			pcall(fn.Disconnect, fn)
		end
	end
	self._cleanups = {}
	self._scopes = {}
	self._channels = {}
end

return Src
