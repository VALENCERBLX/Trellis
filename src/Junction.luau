--!strict
-- Trellis
-- Junction.luau
-- Valence
--
-- The routing map: parsed, validated, and materialized into real instances.
--
--   Junction.<Namespace>.<Domain>.<Event> = { entry }
--
--   Namespace   Network | Local | Fence
--   Kind        Static (an Event) | Resolve (a Function)
--
-- The transport class is a concat, so two words in the map cover four transports:
--
--   class = (namespace == "Local" and "Bindable" or "Remote") .. KIND[entry.Kind]
--
--                | Kind = "Static"  | Kind = "Resolve"
--     Local      | BindableEvent    | BindableFunction
--     Network    | RemoteEvent      | RemoteFunction
--
-- Network entries become one instance each, mirroring the map's nesting, so the
-- channel name leaves the wire, a RemoteFunction gets its own OnServerInvoke rather
-- than a hand-rolled dispatch, and Studio's Explorer shows the live topology.
--
-- Local entries are plain-Lua signals by default: BindableEvent:Fire deep-copies its
-- arguments, stripping metatables and mangling mixed keys, which silently breaks any
-- payload carrying a class instance or a thenable. Set `Instanced = true` on an entry
-- when you actually want the Explorer node.

local Schema = require(script.Parent.Schema)

local Junction = {}
Junction.__index = Junction

local KIND_CLASS = { Static = "Event", Resolve = "Function" }
local NAMESPACES = { Network = true, Local = true, Fence = true }
local SIDES = { Server = true, Client = true }

-- The one reserved key: a domain-level table of defaults every entry inherits.
local DEFAULTS_KEY = "Defaults"

export type Entry = {
	Path: string,
	Namespace: string,
	Domain: string,
	Event: string,
	Kind: string,
	Class: string,
	Destination: string?,
	Side: string?,
	Instanced: boolean,
}

-- ==================================================================== parsing ===

local function classOf(namespace: string, kind: string): string
	return (if namespace == "Local" then "Bindable" else "Remote") .. KIND_CLASS[kind]
end

-- Entry fields fall back to the domain's Defaults, then to the framework defaults.
-- "any" explicitly clears an inherited Destination. That is the requests-in /
-- reports-out split most domains have, expressed in the structure instead of a comment.
local function inherit(raw: { [string]: any }, defaults: { [string]: any }, field: string): any
	local value = raw[field]
	if value == nil then
		value = defaults[field]
	end
	return value
end

function Junction.new(map: { [string]: any }, side: string, opts: { [string]: any }?)
	local self = setmetatable({
		_side = side,
		_entries = {} :: { [string]: Entry },
		_fences = {} :: { [string]: { string } }, -- fence name -> event paths
		_fenceOf = {} :: { [string]: { string } }, -- event path -> fence names
		_fencers = {} :: { [string]: { any } },
		_fenceSpecs = {} :: { [string]: any }, -- fence name -> { Rate, Per }
		_buckets = {} :: { [string]: any }, -- fence name -> player key -> window
		_clock = (opts and opts.Clock) or os.clock,
		_instances = {} :: { [string]: any },
		_signals = {} :: { [string]: any },
		_problems = {} :: { string },
	}, Junction)

	self:_parse(map)
	self:_resolveFences(map.Fence)

	local registry = opts and opts.Registry
	if registry then
		self:_validate(registry)
	end

	return self
end

function Junction:_parse(map: { [string]: any })
	for namespace, domains in map do
		if not NAMESPACES[namespace] then
			table.insert(
				self._problems,
				string.format("unknown namespace %q (expected Network, Local or Fence)", namespace)
			)
			continue
		end
		if namespace == "Fence" then
			continue -- fences are event lists, not entries; handled separately
		end

		for domain, events in domains do
			local defaults = events[DEFAULTS_KEY] or {}

			for event, raw in events do
				if event == DEFAULTS_KEY then
					continue
				end

				local path = string.format("%s.%s.%s", namespace, domain, event)

				if type(raw) ~= "table" then
					table.insert(self._problems, string.format("%s is not a table", path))
					continue
				end

				local kind = inherit(raw, defaults, "Kind") or "Static"
				if not KIND_CLASS[kind] then
					table.insert(
						self._problems,
						string.format("%s has Kind %q (expected \"Static\" or \"Resolve\")", path, tostring(kind))
					)
					continue
				end

				local entrySide = inherit(raw, defaults, "Side")
				if entrySide ~= nil and not SIDES[entrySide] then
					table.insert(
						self._problems,
						string.format("%s has Side %q (expected \"Server\" or \"Client\")", path, tostring(entrySide))
					)
					continue
				end

				if namespace == "Network" and entrySide ~= nil then
					table.insert(
						self._problems,
						string.format("%s is Network, so Side is meaningless -- it crosses by definition", path)
					)
				end

				local destination = inherit(raw, defaults, "Destination")
				if destination == "any" then
					destination = nil -- explicit opt-out from an inherited Destination
				end

				self._entries[path] = {
					Path = path,
					Namespace = namespace,
					Domain = domain,
					Event = event,
					Kind = kind,
					Class = classOf(namespace, kind),
					Destination = destination,
					Side = entrySide,
					Instanced = inherit(raw, defaults, "Instanced") == true,
					Schema = inherit(raw, defaults, "Schema"),
				}

				Schema.Validate(self._entries[path].Schema, path, self._problems)
			end
		end
	end
end

-- A Fence lists either a full event path ("Network.Combat.Swing") or a domain path
-- ("Network.Combat"), which encloses every event in it. Both resolve the same way,
-- so the choice is the map author's per fence rather than a design fork.
function Junction:_resolveFences(fences: { [string]: any }?)
	if not fences then
		return
	end

	for name, list in fences do
		local paths = {}

		-- A Fence is either a plain list of targets, or a table carrying a rate
		-- budget alongside them. Declaring the budget beside the events means the
		-- framework enforces it, rather than every project hand-rolling it badly.
		local targets = list
		if type(list) == "table" and list.Events then
			targets = list.Events
			self._fenceSpecs[name] = { Rate = list.Rate, Per = list.Per or 1 }
			if list.Rate ~= nil and (type(list.Rate) ~= "number" or list.Rate <= 0) then
				table.insert(self._problems, string.format("Fence %q has Rate %s (expected a positive number)", name, tostring(list.Rate)))
			end
		end

		for _, target in targets do
			if self._entries[target] then
				table.insert(paths, target)
				continue
			end

			local matched = false
			for path, entry in self._entries do
				if string.format("%s.%s", entry.Namespace, entry.Domain) == target then
					table.insert(paths, path)
					matched = true
				end
			end

			if not matched then
				table.insert(
					self._problems,
					string.format("Fence %q names %q, which is neither an event nor a domain", name, tostring(target))
				)
			end
		end

		table.sort(paths)
		self._fences[name] = paths

		for _, path in paths do
			local owners = self._fenceOf[path]
			if not owners then
				owners = {}
				self._fenceOf[path] = owners
			end
			table.insert(owners, name)
		end
	end
end

-- ================================================================= validation ===

-- A Controller only ever exists on the client and a Manager only on the server, so a
-- destination naming one of those can be checked from the side that owns it, which is
-- how a typo in a NETWORK destination gets caught at boot rather than never.
local function impliedSide(destination: string): string?
	if string.sub(destination, -10) == "Controller" then
		return "Client"
	elseif string.sub(destination, -7) == "Manager" then
		return "Server"
	end
	return nil -- a Service is side-split; we cannot tell from the name
end

function Junction:_validate(registry: any)
	for path, entry in self._entries do
		local destination = entry.Destination
		if not destination then
			continue
		end

		-- A Local entry scoped to the other side isn't ours to check.
		if entry.Namespace == "Local" and entry.Side ~= nil and entry.Side ~= self._side then
			continue
		end

		-- Every module ends in one of the three role suffixes, so a destination that
		-- doesn't is wrong regardless of side. This has to come first: a transposed
		-- letter usually lands IN the suffix ("CombatMangaer"), and reading the suffix
		-- to decide which side to check would then skip the check entirely.
		if not impliedSide(destination) and string.sub(destination, -7) ~= "Service" then
			table.insert(
				self._problems,
				string.format(
					"%s routes to %q, which does not end in Controller, Manager or Service",
					path,
					destination
				)
			)
			continue
		end

		local shouldExistHere = if entry.Namespace == "Local"
			then true
			else impliedSide(destination) == self._side

		if not shouldExistHere then
			continue
		end

		if not self:_moduleExists(registry, destination) then
			table.insert(
				self._problems,
				string.format("%s routes to %q, which is not a module on the %s", path, destination, self._side)
			)
		end
	end

	if #self._problems > 0 then
		error("[Trellis] Junction:\n    " .. table.concat(self._problems, "\n    "), 0)
	end
end

function Junction:_moduleExists(registry: any, name: string): boolean
	for _, bin in { "Controller", "Manager", "Service" } do
		local has = registry["Has" .. bin]
		if has and has(registry, name) then
			return true
		end
	end
	return false
end

-- =============================================================== materializing ===

-- Network entries become instances mirroring the map's nesting:
--     <Container>/<Domain>/<Event>
-- The server creates them; the client waits for the same paths. Local entries get a
-- plain-Lua signal unless the entry opted into a real Bindable.
-- The framework's own channels. They are not in your map, since you should not have to
-- declare the plumbing that carries register deltas, but they materialize the same way
-- so there is exactly one path that creates remotes.
local BUILTIN = {
	{ Path = "Network.__Reg.Delta", Domain = "__Reg", Event = "Delta", Class = "RemoteEvent" },
	{ Path = "Network.__Reg.Request", Domain = "__Reg", Event = "Request", Class = "RemoteFunction" },
}

function Junction:Materialize(io: { [string]: any })
	for _, builtin in BUILTIN do
		if self._side == "Client" then
			self._instances[builtin.Path] = io.Wait(builtin.Domain, builtin.Event)
		else
			self._instances[builtin.Path] = io.New(builtin.Class, builtin.Domain, builtin.Event)
		end
	end

	for path, entry in self._entries do
		if entry.Namespace == "Local" and not entry.Instanced then
			self._signals[path] = { Handlers = {} }
			continue
		end

		if entry.Side ~= nil and entry.Side ~= self._side then
			continue
		end

		if entry.Namespace == "Network" and self._side == "Client" then
			self._instances[path] = io.Wait(entry.Domain, entry.Event)
		else
			self._instances[path] = io.New(entry.Class, entry.Domain, entry.Event)
		end
	end
end

-- ======================================================================= reads ===

function Junction:Entry(path: string): Entry?
	return self._entries[path]
end

function Junction:Resolve(namespace: string, domain: string, event: string): Entry
	local path = string.format("%s.%s.%s", namespace, domain, event)
	local entry = self._entries[path]
	if entry then
		return entry
	end

	local siblings = {}
	for other, candidate in self._entries do
		if candidate.Namespace == namespace and candidate.Domain == domain then
			table.insert(siblings, candidate.Event)
		end
		local _ = other
	end
	table.sort(siblings)

	if #siblings == 0 then
		error(string.format("[Trellis] no %s domain %q in the Junction", namespace, domain), 0)
	end
	error(
		string.format(
			"[Trellis] no event %q in %s.%s. events there: %s",
			event,
			namespace,
			domain,
			table.concat(siblings, ", ")
		),
		0
	)
end

function Junction:Instance(path: string): any
	return self._instances[path]
end

function Junction:Signal(path: string): any
	return self._signals[path]
end

-- Which fences enclose this event; the Src layer runs every fencing module and
-- requires all of them to pass.
function Junction:FencesFor(path: string): { string }
	return self._fenceOf[path] or {}
end

function Junction:Fence(name: string): { string }?
	return self._fences[name]
end

function Junction:FenceSpec(name: string): any
	return self._fenceSpecs[name]
end

-- Per-player call budget, enforced by the framework because the Fence declared it.
-- A fixed window: cheap, and the worst case (a burst straddling the boundary) is
-- 2x the budget for one window, which is the right trade for an anti-spam guard.
function Junction:Allow(path: string, from: any): (boolean, string?)
	if from == nil then
		return true -- internal traffic is not rate limited
	end

	for _, fence in self:FencesFor(path) do
		local spec = self._fenceSpecs[fence]
		if not spec or not spec.Rate then
			continue
		end

		local buckets = self._buckets[fence]
		if not buckets then
			buckets = {}
			self._buckets[fence] = buckets
		end

		local key = tostring(from.UserId or from)
		local now = self._clock()
		local bucket = buckets[key]

		if not bucket or now - bucket.Start >= spec.Per then
			bucket = { Start = now, Count = 0 }
			buckets[key] = bucket
		end

		bucket.Count += 1
		if bucket.Count > spec.Rate then
			return false, string.format("rate: fence %q allows %d per %gs", fence, spec.Rate, spec.Per)
		end
	end

	return true
end

function Junction:ForgetRates(from: any)
	local key = tostring((from and from.UserId) or from)
	for _, buckets in self._buckets do
		buckets[key] = nil
	end
end

-- Bootstrap registers each module that asked to fence. MANY modules may fence one
-- Fence and ALL must pass. That is how layered validation gets written: a rate limiter
-- and a shape check watching the same events without knowing about each other.
function Junction:AddFencer(name: string, module: any)
	local list = self._fencers[name]
	if not list then
		list = {}
		self._fencers[name] = list
	end
	table.insert(list, module)
end

-- Every module fencing any Fence that encloses this event.
function Junction:FencersFor(path: string): { any }
	local fencers = {}
	for _, fence in self:FencesFor(path) do
		for _, module in self._fencers[fence] or {} do
			table.insert(fencers, module)
		end
	end
	return fencers
end

function Junction:Paths(): { string }
	local paths = {}
	for path in self._entries do
		table.insert(paths, path)
	end
	table.sort(paths)
	return paths
end

function Junction:Problems(): { string }
	return self._problems
end

return Junction
