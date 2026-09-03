-- The boot sequence end to end: preload, junction, order, inject, start, install,
-- arm, ready -- and the failures that must happen at boot rather than at runtime.

local H = require("./harness")
local T = H.suite("Bootstrap")

local Bootstrap = H.src("Bootstrap")

local check, expectError = T.check, T.throws
local folder, module = H.folder, H.module

-- ================================================================== the game ===

local log = {}
local function note(what)
	table.insert(log, what)
end

-- a module factory whose every hook records into the shared log
local function gameModule(name, extra)
	local m = { Name_ = name }
	function m:Start()
		note(name .. ":Start")
	end
	function m:Ready()
		note(name .. ":Ready")
	end
	function m:Stop()
		note(name .. ":Stop")
	end
	for k, v in extra or {} do
		m[k] = v
	end
	return m
end

local heartbeats = 0

-- Fresh module tables per boot: Configure injects a metatable onto each one, and
-- reusing them across boots would (correctly) trip the "already has a metatable"
-- guard on the second Configure.
local function buildModules()
	return {
		MemoryService = gameModule("MemoryService"),
		SessionManager = gameModule("SessionManager", {
			Req = { "Player" },
			PlayerAdded = function(_, p)
				note("SessionManager:PlayerAdded(" .. p.Name .. ")")
			end,
		}),
		StateManager = gameModule("StateManager", {
			Req = { "Heart" },
			Heartbeat = function()
				heartbeats += 1
				note("StateManager:Heartbeat")
			end,
		}),
		CombatManager = gameModule("CombatManager", {
			Req = { "Fence" },
			Fence = function(_, event, payload)
				return type(payload) == "table", "shape"
			end,
		}),
		LonelyManager = gameModule("LonelyManager"), -- absent from BootOrder on purpose
	}
end

local JUNCTION_MAP = {
	Network = {
		Combat = { Swing = { Destination = "CombatManager" }, Block = {} },
		Session = { Get = { Kind = "Resolve", Destination = "SessionManager" } },
	},
	Local = {
		State = { Defaults = { Side = "Server" }, Entered = {}, Exited = {} },
	},
	Fence = { Combat = { "Network.Combat" } },
}

local BOOT_ORDER = {
	Order = {
		"MemoryService",
		"SessionManager",
		{ "StateManager", "CombatManager" },
	},
	Config = {
		StateManager = { Hz = 20 },
		CombatManager = { Fences = { "Combat" } },
	},
}

local function hierarchy(mods, extraManagers)
	mods = mods or buildModules()
	local managers = {
		module("SessionManager", mods.SessionManager),
		module("StateManager", mods.StateManager),
		module("CombatManager", mods.CombatManager),
		module("LonelyManager", mods.LonelyManager),
	}
	for _, m in extraManagers or {} do
		table.insert(managers, m)
	end
	return {
		folder("Shared", {
			folder("Config", {
				module("Junction", JUNCTION_MAP),
				module("BootOrder", BOOT_ORDER),
			}),
			folder("Packages", { module("Lume", { id = "Lume" }) }),
		}),
		folder("Server", {
			folder("Managers", managers),
			folder("Services", { module("MemoryService", mods.MemoryService) }),
		}),
	}
end

-- ================================================================== stub opts ===

local function connection()
	return {
		Disconnect = function()
			note("disconnect")
		end,
	}
end
local function signal()
	return {
		Connect = function(_, fn)
			return connection()
		end,
	}
end

local armedAt = nil

local function opts(overrides)
	local players = {
		GetPlayers = function()
			return { { Name = "Ada" }, { Name = "Lin" } }
		end,
		PlayerAdded = signal(),
		PlayerRemoving = signal(),
	}

	local o = {
		Side = "Server",
		Loader = H.loader,
		Players = players,
		CollectionService = {
			GetInstanceAddedSignal = function()
				return signal()
			end,
			GetInstanceRemovedSignal = function()
				return signal()
			end,
			GetTagged = function()
				return {}
			end,
		},
		RunService = {
			Heartbeat = {
				Connect = function()
					armedAt = #log
					note("ARMED")
					return connection()
				end,
			},
		},
		IO = {
			New = function(class, domain, event)
				return { Class = class, Key = domain .. "/" .. event }
			end,
			Wait = function() end,
		},
		-- a minimal Src: enough for Bootstrap to inject and for OnCleanup to work
		Src = function(entry, runtime)
			local cleanups = {}
			return {
				Name = entry.Name,
				Role = entry.Role,
				Side = runtime.Side,
				Main = runtime.Registry and runtime.Registry.Main,
				OnCleanup = function(_, fn)
					table.insert(cleanups, fn)
				end,
				GetPackage = function(_, n)
					return runtime.Registry:GetPackage(n)
				end,
				_teardown = function()
					cleanups = {}
				end,
			}
		end,
	}
	for k, v in overrides or {} do
		o[k] = v
	end
	return o
end

-- ==================================================================== running ===

local function indexOf(entry)
	for i, v in log do
		if v == entry then
			return i
		end
	end
	return nil
end

local MODS = buildModules()
local app = Bootstrap.Configure({ Hierarchy = hierarchy(MODS) }, opts())

-- config discovered, not passed ------------------------------------------------
check("Junction found in the Config bin", app:Inspect().Routes[1] ~= nil)
check("BootOrder found in the Config bin", app.Order[1] == "MemoryService")

-- order ------------------------------------------------------------------------
check("tiers boot in order", table.concat(app.Order, ",") == "MemoryService,SessionManager,StateManager,CombatManager,LonelyManager", table.concat(app.Order, ","))
check("a module absent from BootOrder boots last", app.Order[#app.Order] == "LonelyManager")
check("...and it is warned about", (function()
	for _, w in H.warnings.peek() do
		if string.find(w, "not in BootOrder, booting last: LonelyManager", 1, true) then
			return true
		end
	end
	return false
end)())

-- the sequence -------------------------------------------------------------------
check("every :Start ran before any :Ready", indexOf("LonelyManager:Start") < indexOf("MemoryService:Ready"))
check("Start order matches BootOrder", indexOf("MemoryService:Start") < indexOf("SessionManager:Start"))
check("capabilities install AFTER :Start", indexOf("SessionManager:PlayerAdded(Ada)") > indexOf("SessionManager:Start"))
check("drivers arm AFTER every :Start", armedAt > indexOf("CombatManager:Start"))
check("nothing ticked during boot", heartbeats == 0, heartbeats)
check(":Ready runs after arming", indexOf("MemoryService:Ready") > armedAt)

-- player backlog -------------------------------------------------------------------
check("players who joined earlier are replayed", indexOf("SessionManager:PlayerAdded(Ada)") ~= nil)
check("...all of them", indexOf("SessionManager:PlayerAdded(Lin)") ~= nil)

-- injection --------------------------------------------------------------------------
check("Src is mirrored onto the module", MODS.MemoryService.Name == "MemoryService")
check("...reachable from any method, not just :Start", MODS.MemoryService:GetPackage("Lume").id == "Lume")
check("app:Get returns a booted module", app:Get("StateManager") == MODS.StateManager)
check("app:List filters by role", #app:List("Manager") == 4, #app:List("Manager"))

-- fences ------------------------------------------------------------------------------
check("a fencing module is registered against its events", #app:Inspect().Routes > 0)

-- teardown -------------------------------------------------------------------------
log = {}
app:Stop()
check(":Stop runs in reverse order", indexOf("LonelyManager:Stop") < indexOf("MemoryService:Stop"))
check("the injected metatable is removed", getmetatable(MODS.MemoryService) == nil)

-- ============================================================== boot failures ===

expectError("BootOrder naming an unknown module", function()
	local h = hierarchy()
	local bad = { Order = { "GhostManager" }, Config = {} }
	h[1]._children[1]._children[2] = module("BootOrder", bad)
	return Bootstrap.Configure({ Hierarchy = h }, opts())
end, 'BootOrder lists "GhostManager", which is not a module on this side')

expectError("tuning a capability the module never asked for", function()
	local h = hierarchy()
	local bad = { Order = { "MemoryService" }, Config = { MemoryService = { Hz = 10 } } }
	h[1]._children[1]._children[2] = module("BootOrder", bad)
	return Bootstrap.Configure({ Hierarchy = h }, opts())
end, 'BootOrder.Config.MemoryService sets Hz, but MemoryService never asks for Req "Heart"')

expectError("a module defining a reserved key", function()
	local clash = gameModule("ClashManager")
	clash.Main = "mine"
	local h = hierarchy(nil, { module("ClashManager", clash) })
	return Bootstrap.Configure({ Hierarchy = h }, opts())
end, 'ClashManager defines "Main", which the framework injects')

expectError("an unknown capability", function()
	local bad = gameModule("BadManager")
	bad.Req = { "Telepathy" }
	local h = hierarchy(nil, { module("BadManager", bad) })
	return Bootstrap.Configure({ Hierarchy = h }, opts())
end, 'BadManager requests unknown capability "Telepathy"')

expectError("a server-only capability requested on the client", function()
	local bad = gameModule("HudController")
	bad.Req = { "Player" }
	bad.PlayerAdded = function() end
	local h = {
		folder("Shared", {
			folder("Config", {
				module("Junction", JUNCTION_MAP),
				module("BootOrder", { Order = {}, Config = {} }),
			}),
		}),
		folder("Client", { folder("Controllers", { module("HudController", bad) }) }),
	}
	return Bootstrap.Configure({ Hierarchy = h }, opts({ Side = "Client" }))
end, 'HudController requests "Player", which is Server-only (this is the Client)')

expectError("no Junction anywhere", function()
	return Bootstrap.Configure({ Hierarchy = { folder("Empty", { folder("Packages", {}) }) } }, opts())
end, "no Junction. Put it in the Config bin")

expectError("Configure without a Hierarchy", function()
	return Bootstrap.Configure({}, opts())
end, "Configure needs a Hierarchy")

-- a hook with no Req is dead code, and says so
do
	H.warnings.clear()
	local dead = gameModule("DeadManager")
	dead.Heartbeat = function() end
	local h = hierarchy(nil, { module("DeadManager", dead) })
	Bootstrap.Configure({ Hierarchy = h }, opts())

	check("a hook without its Req warns as dead code", (function()
		for _, w in H.warnings.peek() do
			if string.find(w, 'DeadManager defines :Heartbeat but never asked for Req "Heart"', 1, true) then
				return true
			end
		end
		return false
	end)())
end

-- ======================================================== double-sided Services ===

-- a map with no Destinations, so these cases exercise Services rather than routing
local BARE_MAP = { Network = { Ping = { Send = {} } } }

local function doubleSided(withHost)
	local served = { Built = 0 }

	local shared = gameModule("CombatService")
	shared.__Serve = function()
		served.Built += 1
		local Client = {}
		function Client:Start()
			note("CombatService(client):Start")
		end
		function Client:Hello()
			return "from __Serve"
		end
		return Client
	end

	local host
	if withHost then
		host = gameModule("CombatService")
		host.__Recip = function(self, t)
			note("CombatService:__Recip")
			self.Served = t
		end
	end

	local clientServices = { module("HudService", gameModule("HudService")) }
	if host then
		table.insert(clientServices, module("CombatService", host))
	end

	local h = {
		folder("Shared", {
			folder("Config", {
				module("Junction", BARE_MAP),
				module("BootOrder", { Order = {}, Config = {} }),
			}),
			folder("Services", { module("CombatService", shared) }),
		}),
		folder("Client", { folder("Services", clientServices) }),
	}

	return h, served, host
end

do
	log = {}
	local h, served = doubleSided(false)
	local app = Bootstrap.Configure({ Hierarchy = h }, opts({ Side = "Client" }))

	check("the client runs __Serve itself", served.Built == 1, served.Built)
	check("the served table boots as the Service", indexOf("CombatService(client):Start") ~= nil)
	check("...under the shared module's name", app:Get("CombatService"):Hello() == "from __Serve")
end

do
	log = {}
	local h, served, host = doubleSided(true)
	local app = Bootstrap.Configure({ Hierarchy = h }, opts({ Side = "Client" }))

	check("a same-name client host receives it via __Recip", indexOf("CombatService:__Recip") ~= nil)
	check("...and gets the served table", host.Served.Hello() == "from __Serve")
	check("the HOST is what boots, not the served table", app:Get("CombatService") == host)
	check("the served table did not also boot", indexOf("CombatService(client):Start") == nil)
end

do
	-- the server ignores __Serve entirely: it boots the shared module's own body
	log = {}
	local h, served = doubleSided(false)
	table.remove(h, 2) -- drop the client root
	local app = Bootstrap.Configure({ Hierarchy = h }, opts())

	check("the server never calls __Serve", served.Built == 0, served.Built)
	check("...it boots the shared module itself", indexOf("CombatService:Start") ~= nil)
end

do
	-- two same-named Services with no __Serve is still a genuine collision
	expectError("a real duplicate Service still fails", function()
		local h = {
			folder("Shared", {
				folder("Config", {
					module("Junction", BARE_MAP),
					module("BootOrder", { Order = {}, Config = {} }),
				}),
				folder("Services", { module("GhostService", gameModule("GhostService")) }),
			}),
			folder("Client", { folder("Services", { module("GhostService", gameModule("GhostService")) }) }),
		}
		return Bootstrap.Configure({ Hierarchy = h }, opts({ Side = "Client" }))
	end, 'duplicate Service "GhostService", mounted from:')
end

T.done()
