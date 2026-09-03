--!nonstrict
-- Trellis
-- Bootstrap.luau
-- Valence
--
-- Configure. One call per side, and the only entry point the game touches.
--
-- The whole sequence lives here in order, so the boot is readable top to bottom:
-- registry, config, preload, junction, registers, order, inject, start, install,
-- arm, ready. Every step that can fail names what failed and what it expected.

local Registry = require(script.Parent.Registry)
local Junction = require(script.Parent.Junction)
local Scheduler = require(script.Parent.Scheduler)
local Reaction = require(script.Parent.Reaction)
local Trove = require(script.Parent.Trove)
local Log = require(script.Parent.Log)
local Reg = require(script.Parent.Reg)
local Inspect = require(script.Parent.Inspect)

local Bootstrap = {}

-- Role bins, and which side each may boot on. A Service is side-split: it boots on
-- whichever side discovered it, so it is scoped by where you put it.
-- NOTE: "Any" rather than nil. A nil value in a Luau table literal removes the key
-- entirely, so `Service = nil` would silently drop Services from the boot.
local ROLES = {
	Controller = "Client",
	Manager = "Server",
	Service = "Any",
}

-- Src mirrors onto the module, so these keys belong to the framework. A module
-- defining one would silently shadow it, so it is a boot error instead.
local RESERVED = {
	"Name", "Role", "Side", "Player", "Main",
	"Local", "Network", "Reg", "Await", "OnCleanup", "Inspect",
	"Trove", "Delay", "Every", "Cancel",
	"Start", "Stop", "Ready", -- hooks: yours to define, not to be overwritten
}

-- Capability -> the hook it requires, and the side it is legal on.
local CAPABILITIES = {
	Heart = { Hooks = { "Heartbeat" }, Side = nil, Config = { "Hz" } },
	Player = { Hooks = { "PlayerAdded", "PlayerRemoving" }, Side = "Server", Any = true },
	Tag = { Hooks = { "TagAdded", "TagRemoved" }, Side = nil, Any = true, Config = { "Tags" } },
	Fence = { Hooks = { "Fence" }, Side = nil, Config = { "Fences" } },
	Timer = { Hooks = {}, Side = nil },
	Trove = { Hooks = {}, Side = nil },
	Profile = { Hooks = {}, Side = nil },
}

-- Which capability a BootOrder.Config key belongs to, so tuning a capability the
-- module never asked for is caught rather than silently ignored.
local CONFIG_OWNER = { Hz = "Heart", Tags = "Tag", Fences = "Fence" }

local PROFILED_HOOKS = {
	"Start", "Stop", "Ready", "Heartbeat",
	"PlayerAdded", "PlayerRemoving", "TagAdded", "TagRemoved", "Fence",
}

local function fail(...)
	error("[Trellis] " .. string.format(...), 0)
end

-- =============================================================== 1. the side ===

local function detectSide(opts): string
	if opts and opts.Side then
		return opts.Side
	end
	local RunService = game:GetService("RunService")
	return if RunService:IsServer() then "Server" else "Client"
end

-- ========================================================== 3. loading config ===

-- Junction / BootOrder / Registers are ordinary modules in the Config bin, so the
-- normal Bootstrap passes none of them. An explicit value in the payload wins.
local function loadConfig(registry, config, name: string, required: boolean)
	if config[name] ~= nil then
		return config[name]
	end

	local has = registry.HasConfig
	if has and has(registry, name) then
		return registry:GetConfig(name)
	end

	if required then
		fail(
			"no %s. Put it in the Config bin as Config.%s, or pass %s = require(...) to Configure",
			name,
			name,
			name
		)
	end
	return nil
end

-- ======================================================== 4. preloading roles ===

-- Force-require every role module now, so a syntax error in module forty surfaces
-- here rather than on first use. Side-filtering happens in the same pass: a shared
-- root may legitimately contain Controllers the server must not boot.
local function collectModules(registry, side: string)
	local modules, order = {}, {}

	for role, onlySide in ROLES do
		if onlySide ~= "Any" and onlySide ~= side then
			continue
		end
		if not registry._bins[role] then
			continue
		end

		for _, name in registry:Names(role) do
			if modules[name] then
				fail("two modules named %q", name)
			end
			local value = registry:Resolve(role, name)
			if type(value) ~= "table" then
				fail("%s returned a %s, not a module table", name, type(value))
			end
			modules[name] = { Name = name, Role = role, Module = value }
			table.insert(order, name)
		end
	end

	table.sort(order)
	return modules, order
end

-- ================================================ 4b. double-sided Services ===

-- A Service may serve BOTH sides from one shared module:
--
--   -- ReplicatedStorage/Shared/Modules/Services/CombatService  (must be replicated)
--   function CombatService:Start() end          -- the SERVER half
--   function CombatService:__Serve()            -- returns the CLIENT half
--       local Client = {}
--       function Client:Start() end
--       return Client
--   end
--
-- __Serve is NOT a transfer. Server containers never replicate and functions do not
-- cross remotes, so the client requires the same shared module and runs __Serve
-- ITSELF, in its own VM. Two things follow: the module must live somewhere
-- replicated, so its server half is readable by exploiters; keep secrets in a Manager.
-- And __Serve must be self-contained, because every upvalue it closes over is the
-- client's copy.
--
-- Optionally the client tree holds a host of the same name that receives the served
-- table instead of the framework booting it directly:
--
--   -- StarterPlayerScripts/Client/Services/CombatService
--   function CombatService:__Recip(served) self.Served = served end
--
-- That same-name pairing is the one duplicate the registry tolerates.
local function pairServices(registry, side: string)
	if side ~= "Client" then
		return -- the server boots the shared module's own body; __Serve is the client's
	end

	if not registry._bins.Service then
		return
	end

	local function serve(name: string, server, host)
		local ok, served = pcall(server.__Serve, server)
		if not ok then
			fail("%s:__Serve errored: %s", name, tostring(served))
		end
		if type(served) ~= "table" then
			fail("%s:__Serve returned a %s, not a module table", name, type(served))
		end

		if host then
			local recipOk, err = pcall(host.__Recip, host, served)
			if not recipOk then
				fail("%s:__Recip errored: %s", name, tostring(err))
			end
			registry:Reconcile("Service", name, host)
		else
			registry:Reconcile("Service", name, served)
		end
	end

	-- Contested names first: a shared __Serve module paired with a client __Recip
	-- host is the one duplicate the registry tolerates.
	for _, name in registry:ClaimedNames("Service") do
		local server, host
		for _, claim in registry:Claims("Service", name) do
			local value = registry:Load(claim)
			if type(value) ~= "table" then
				continue
			end
			if type(value.__Serve) == "function" then
				server = value
			elseif type(value.__Recip) == "function" then
				host = value
			end
		end

		if server then
			serve(name, server, host)
		end
		-- otherwise it is a genuine collision; Resolve reports it with every origin
	end

	-- Then the uncontested ones: a shared Service that serves but has no client host
	-- is simply replaced by what __Serve returns.
	for _, name in registry:Names("Service") do
		if registry:Claims("Service", name) then
			continue
		end
		local value = registry:Resolve("Service", name)
		if type(value) == "table" and type(value.__Serve) == "function" then
			serve(name, value, nil)
		end
	end
end

-- ============================================================ 7. the boot order ===

-- Order is a list of tiers; a tier is a name or an array of names with no guaranteed
-- order among them. Anything the map doesn't mention boots after the last tier, so
-- you only list what actually needs ordering.
local function resolveOrder(bootOrder, modules, discovered: { string }): { string }
	local resolved, placed = {}, {}

	for _, tier in (bootOrder and bootOrder.Order) or {} do
		local names = if type(tier) == "table" then tier else { tier }
		for _, name in names do
			if not modules[name] then
				fail("BootOrder lists %q, which is not a module on this side", name)
			end
			if placed[name] then
				fail("BootOrder lists %q twice", name)
			end
			placed[name] = true
			table.insert(resolved, name)
		end
	end

	local leftovers = {}
	for _, name in discovered do
		if not placed[name] then
			table.insert(resolved, name)
			table.insert(leftovers, name)
		end
	end

	if #leftovers > 0 then
		warn(
			string.format(
				"[Trellis] not in BootOrder, booting last: %s",
				table.concat(leftovers, ", ")
			)
		)
	end

	return resolved
end

-- =========================================================== 8. checking Req ===

local function checkModule(entry, side: string, tuning)
	local module, name = entry.Module, entry.Name

	for _, key in RESERVED do
		if rawget(module, key) ~= nil and key ~= "Start" and key ~= "Stop" and key ~= "Ready" then
			fail("%s defines %q, which the framework injects. Rename it.", name, key)
		end
	end

	if type(module.Start) ~= "function" and entry.Role ~= "Service" then
		warn(string.format("[Trellis] %s has no :Start", name))
	end

	local asked = {}
	for _, capability in module.Req or {} do
		local spec = CAPABILITIES[capability]
		if not spec then
			fail("%s requests unknown capability %q", name, tostring(capability))
		end
		if spec.Side and spec.Side ~= side then
			fail("%s requests %q, which is %s-only (this is the %s)", name, capability, spec.Side, side)
		end

		-- Any = the module may define either hook; otherwise every hook is required.
		local found = 0
		for _, hook in spec.Hooks do
			if type(module[hook]) == "function" then
				found += 1
			end
		end
		if #spec.Hooks > 0 then
			if spec.Any and found == 0 then
				fail("%s requests %q but defines none of: %s", name, capability, table.concat(spec.Hooks, ", "))
			elseif not spec.Any and found < #spec.Hooks then
				fail("%s requests %q but does not define :%s", name, capability, spec.Hooks[1])
			end
		end

		asked[capability] = true
	end

	-- A hook with no Req is dead code: it will never be called.
	for capability, spec in CAPABILITIES do
		if asked[capability] then
			continue
		end
		for _, hook in spec.Hooks do
			if type(module[hook]) == "function" then
				warn(
					string.format(
						'[Trellis] %s defines :%s but never asked for Req "%s" -- it will never be called',
						name,
						hook,
						capability
					)
				)
			end
		end
	end

	-- Tuning a capability the module never requested would silently do nothing.
	for key in tuning or {} do
		local owner = CONFIG_OWNER[key]
		if owner and not asked[owner] then
			fail('BootOrder.Config.%s sets %s, but %s never asks for Req "%s"', name, key, name, owner)
		end
	end

	return asked
end

-- ============================================== register replication transport ===

-- Deltas ride the framework's own channels rather than anything you declared. The
-- server broadcasts or targets; the client applies what arrives and sends mutations
-- back as REQUESTS, which the server validates against the register's Policies.
local function regTransport(junction, side: string)
	local delta = junction:Instance("Network.__Reg.Delta")
	local request = junction:Instance("Network.__Reg.Request")

	if side == "Server" then
		return {
			Broadcast = function(d)
				delta:FireAllClients(d)
			end,
			To = function(player, d)
				delta:FireClient(player, d)
			end,
			OnRequest = function(fn)
				request.OnServerInvoke = function(player, d)
					local ok, result, reason = pcall(fn, d, player)
					if not ok then
						return { Ok = false, Reason = tostring(result) }
					end
					return { Ok = result, Reason = reason }
				end
			end,
		}
	end

	return {
		Broadcast = function() end,
		To = function() end,
		OnDelta = function(fn)
			delta.OnClientEvent:Connect(fn)
		end,
		Request = function(d)
			return Reaction.new(function(resolve, reject)
				task.spawn(function()
					local ok, result = pcall(request.InvokeServer, request, d)
					if ok then
						resolve(result or { Ok = false, Reason = "no answer" })
					else
						reject(result)
					end
				end)
			end)
		end,
	}
end

-- Req "Profile": wrap every hook in debug.profilebegin(Module.Hook). Turn it on for
-- a suspect module, read the microprofiler, turn it off. The module never changes.
local function installProfile(entry)
	for _, hook in PROFILED_HOOKS do
		local original = rawget(entry.Module, hook)
		if type(original) == "function" then
			local label = entry.Name .. "." .. hook
			entry.Module[hook] = function(...)
				debug.profilebegin(label)
				local a, b = original(...)
				debug.profileend()
				return a, b
			end
		end
	end
end

-- ================================================================= Configure ===

function Bootstrap.Configure(config, opts)
	config = config or {}
	opts = opts or {}

	if not config.Hierarchy then
		fail("Configure needs a Hierarchy: the root folders to derive bins from")
	end

	-- 1 ------------------------------------------------------------------ side
	local side = detectSide(opts)

	-- 2 -------------------------------------------------------------- registry
	local registry = Registry.new(config.Hierarchy, {
		Inject = config.Inject,
		Aliases = config.Aliases,
		Loader = opts.Loader,
	})

	-- 3 ---------------------------------------------------------------- config
	local junctionMap = loadConfig(registry, config, "Junction", true)
	local bootOrder = loadConfig(registry, config, "BootOrder", false)
	local registers = loadConfig(registry, config, "Registers", false)

	-- 4 --------------------------------------------------------------- preload
	pairServices(registry, side)
	local modules, discovered = collectModules(registry, side)

	-- 5 -------------------------------------------------------------- junction
	local junction = Junction.new(junctionMap, side, { Registry = registry, Clock = opts.Clock })
	junction:Materialize(opts.IO or Bootstrap.defaultIO(side))

	-- 6 ------------------------------------------------------------- registers
	local log = if config.Log then Log.new(config.Log, opts.Clock) else nil
	local reg = nil
	if registers then
		local transport = (opts.Transport and opts.Transport(junction, side)) or regTransport(junction, side)
		reg = Reg.new(registers, side, transport, { Store = config.Store, Log = log })
	end

	-- 7 ------------------------------------------------------------------ order
	local order = resolveOrder(bootOrder, modules, discovered)
	local tuning = (bootOrder and bootOrder.Config) or {}

	for name in tuning do
		if not modules[name] then
			fail("BootOrder.Config names %q, which is not a module on this side", name)
		end
	end

	-- 8 ------------------------------------------------------------- inject Src
	local housekeeping = {}
	local scheduler = Scheduler.new(side)
	local runtime = {
		Side = side,
		Player = if side == "Client" then ((opts.Players or game:GetService("Players")).LocalPlayer) else nil,
		Registry = registry,
		Junction = junction,
		Reg = reg,
		Scheduler = scheduler,
		Modules = modules,
		Latches = {},
		Log = log,
		Players = opts.Players or (if side == "Server" then game:GetService("Players") else nil),
	}

	local makeSrc = opts.Src or function(...)
		return require(script.Parent.Src).new(...)
	end

	for _, name in order do
		local entry = modules[name]
		entry.Asked = checkModule(entry, side, tuning[name])
		entry.Src = makeSrc(entry, runtime)

		-- Mirror Src onto the module so it is reachable from every method, not just
		-- :Start. The module's own fields always win; Src fills the gaps.
		local existing = getmetatable(entry.Module)
		if existing and existing.__index then
			fail("%s already has a metatable with __index; Trellis cannot inject into it", name)
		end
		setmetatable(entry.Module, { __index = entry.Src })

		-- Granted BEFORE :Start, because modules use self.Trove and self:Delay
		-- inside :Start. Heart / Player / Tag / Fence install afterwards.
		if entry.Asked.Trove then
			entry.Src:_grantTrove(Trove.new())
		end
		if entry.Asked.Timer then
			entry.Src:_grantTimers(scheduler)
		end
		if entry.Asked.Profile or config.Profile then
			installProfile(entry)
		end
	end

	-- 9 --------------------------------------------------------------- :Start
	for _, name in order do
		local entry = modules[name]
		if type(entry.Module.Start) == "function" then
			local ok, err = pcall(entry.Module.Start, entry.Module, entry.Src)
			if not ok then
				warn(string.format("[Trellis] %s:Start errored: %s", name, tostring(err)))
			end
		end
	end

	-- 10 ------------------------------------------------- install capabilities
	-- After :Start, so a module's state exists before its first callback, and
	-- before the drivers are armed, so nothing fires mid-boot.
	for _, name in order do
		local entry = modules[name]
		local setup = tuning[name] or {}

		if entry.Asked.Heart then
			entry.Hz = setup.Hz
			scheduler:Add(name, entry.Module, setup.Hz)
		end
		if entry.Asked.Player then
			Bootstrap.installPlayer(entry, opts)
		end
		if entry.Asked.Tag then
			Bootstrap.installTag(entry, setup.Tags or {}, opts)
		end
		if entry.Asked.Fence then
			for _, fence in setup.Fences or {} do
				if not junction:Fence(fence) then
					fail("%s fences %q, which is not in Junction.Fence", name, fence)
				end
				junction:AddFencer(fence, entry.Module)
			end
		end
	end

	-- 10b ------------------------------------------- framework-owned housekeeping
	-- A player leaving must flush their persisted registers, release the backend's
	-- hold and forget their rate buckets. No module should have to remember this.
	if side == "Server" then
		local players = opts.Players or game:GetService("Players")
		table.insert(housekeeping, players.PlayerRemoving:Connect(function(player)
			if reg then
				reg:Drop(player)
			end
			junction:ForgetRates(player)
		end))
	end

	-- 11 ------------------------------------------------------- arm the drivers
	-- One connection per driver for the whole app. Nothing ticks before this line.
	local connections = Bootstrap.arm(scheduler, opts)

	-- 12 --------------------------------------------------------------- :Ready
	for _, name in order do
		local entry = modules[name]
		if type(entry.Module.Ready) == "function" then
			local ok, err = pcall(entry.Module.Ready, entry.Module)
			if not ok then
				warn(string.format("[Trellis] %s:Ready errored: %s", name, tostring(err)))
			end
		end
	end

	-- ------------------------------------------------------------- app handle
	local app = {
		Side = side,
		Src = makeSrc({ Name = "App", Role = "App" }, runtime),
		Order = order,
	}

	function app:Get(name: string)
		local entry = modules[name]
		return entry and entry.Module
	end

	function app:List(role: string): { string }
		local names = {}
		for _, name in order do
			if modules[name].Role == role then
				table.insert(names, name)
			end
		end
		return names
	end

	function app:Inspect()
		return Inspect.Snapshot(runtime, modules, order)
	end

	-- The snapshot as text, for the console. `app:Report()` is the thing you paste.
	function app:Report(): string
		return Inspect.Render(self:Inspect())
	end

	function app:Log()
		return log
	end

	-- Tear down and boot again from the same payload, without leaving Play mode.
	-- app:Stop already unwinds everything, so this is mostly honesty about the fact
	-- that the second boot must see fresh module tables.
	function app:Restart()
		self:Stop()
		return Bootstrap.Configure(config, opts)
	end

	function app:Stop()
		-- Persisted registers are written BEFORE modules go away, since a module's
		-- :Stop may be the thing that sets the last value worth keeping.
		for i = #order, 1, -1 do
			local entry = modules[order[i]]
			if type(entry.Module.Stop) == "function" then
				pcall(entry.Module.Stop, entry.Module)
			end
		end
		if reg then
			reg:Flush()
		end
		for _, connection in housekeeping do
			pcall(function()
				connection:Disconnect()
			end)
		end

		for i = #order, 1, -1 do
			local entry = modules[order[i]]
			if entry.Src and entry.Src._teardown then
				entry.Src:_teardown()
			end
			setmetatable(entry.Module, nil)
		end
		for _, connection in connections do
			connection:Disconnect()
		end
	end

	-- The live panel needs the finished handle, so it is built last. F4 toggles it.
	if config.Panel and side == "Client" then
		local panel = Inspect.Panel(app, runtime, opts)
		if panel then
			table.insert(housekeeping, { Disconnect = function()
				panel.Gui:Destroy()
			end })
		end
	end

	return app
end

-- ============================================================ default plumbing ===

function Bootstrap.defaultIO(side: string)
	local ReplicatedStorage = game:GetService("ReplicatedStorage")

	if side == "Server" then
		-- Clear any previous tree first, so app:Restart() replaces the topology
		-- rather than leaving a stale folder beside the new one.
		local previous = ReplicatedStorage:FindFirstChild("Junction")
		if previous then
			previous:Destroy()
		end

		local container = Instance.new("Folder")
		container.Name = "Junction"
		container.Parent = ReplicatedStorage

		return {
			New = function(class: string, domain: string, event: string)
				local folder = container:FindFirstChild(domain)
				if not folder then
					folder = Instance.new("Folder")
					folder.Name = domain
					folder.Parent = container
				end
				local instance = Instance.new(class)
				instance.Name = event
				instance.Parent = folder
				return instance
			end,
			Wait = function() end,
		}
	end

	-- Waiting forever is the wrong failure: if the server never materialized (it
	-- errored during its own boot), the client should say so rather than hang.
	local TIMEOUT = 30

	local container = ReplicatedStorage:WaitForChild("Junction", TIMEOUT)
	if not container then
		error(
			"[Trellis] no Junction tree after " .. TIMEOUT .. "s -- did the server Bootstrap error?",
			0
		)
	end

	return {
		New = function()
			error("[Trellis] the client must not create Junction instances")
		end,
		Wait = function(domain: string, event: string)
			local folder = container:WaitForChild(domain, TIMEOUT)
			if not folder then
				error(
					string.format(
						"[Trellis] Junction.%s never appeared. The server's map does not have that domain.",
						domain
					),
					0
				)
			end
			local instance = folder:WaitForChild(event, TIMEOUT)
			if not instance then
				error(
					string.format("[Trellis] Junction.%s.%s never appeared.", domain, event),
					0
				)
			end
			return instance
		end,
	}
end

function Bootstrap.installPlayer(entry, opts)
	local Players = (opts and opts.Players) or game:GetService("Players")
	local module = entry.Module

	if type(module.PlayerAdded) == "function" then
		entry.Src:OnCleanup(Players.PlayerAdded:Connect(function(player)
			module:PlayerAdded(player)
		end))

		-- Replay whoever joined before this module existed. Without it, a module that
		-- boots late misses them entirely -- a bug that only shows on a live server.
		for _, player in Players:GetPlayers() do
			task.spawn(module.PlayerAdded, module, player)
		end
	end

	if type(module.PlayerRemoving) == "function" then
		entry.Src:OnCleanup(Players.PlayerRemoving:Connect(function(player)
			module:PlayerRemoving(player)
		end))
	end
end

function Bootstrap.installTag(entry, tags: { string }, opts)
	local CollectionService = (opts and opts.CollectionService) or game:GetService("CollectionService")
	local module = entry.Module

	for _, tag in tags do
		if type(module.TagAdded) == "function" then
			entry.Src:OnCleanup(CollectionService:GetInstanceAddedSignal(tag):Connect(function(instance)
				module:TagAdded(instance, tag)
			end))
			-- Same replay reasoning as players: already-tagged and streamed-in take
			-- one code path.
			for _, instance in CollectionService:GetTagged(tag) do
				task.spawn(module.TagAdded, module, instance, tag)
			end
		end
		if type(module.TagRemoved) == "function" then
			entry.Src:OnCleanup(CollectionService:GetInstanceRemovedSignal(tag):Connect(function(instance)
				module:TagRemoved(instance, tag)
			end))
		end
	end
end

function Bootstrap.arm(scheduler, opts)
	local RunService = (opts and opts.RunService) or game:GetService("RunService")
	local connections = {}

	local SIGNALS = {
		Heart = "Heartbeat",
		Render = "RenderStepped",
		Step = "Stepped",
	}

	for _, driver in scheduler:Drivers() do
		local signal = RunService[SIGNALS[driver]]
		table.insert(
			connections,
			signal:Connect(function(a, b)
				-- Stepped passes (time, delta); the others pass delta alone.
				scheduler:Step(driver, if driver == "Step" then b else a)
			end)
		)
	end

	return connections
end

return Bootstrap
