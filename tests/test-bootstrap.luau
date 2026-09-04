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

expectError("BootOrder naming a Manager that is missing on the server", function()
	local h = hierarchy()
	local bad = { Order = { "GhostManager" }, Config = {} }
	h[1]._children[1]._children[2] = module("BootOrder", bad)
	return Bootstrap.Configure({ Hierarchy = h }, opts())
end, 'BootOrder lists "GhostManager", which is a Manager but was not found on the Server')

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
end, "no Junction. Put it in a Config folder or a Config module")

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

-- The server keeps its half private in a non-replicating container, runs __Serve
-- there, and Trellis carries the DATA to the client's own module, which receives it
-- through __Recip before it starts.

local function servePair(hostBody)
	local trace = { Order = {} }

	local server = gameModule("TService")
	server.__Serve = function()
		table.insert(trace.Order, "server:__Serve")
		return { Difficulty = 3, Combos = { "Light", "Heavy" } }
	end

	local host = gameModule("TService")
	host.__Recip = hostBody or function(self, served)
		table.insert(trace.Order, "client:__Recip")
		self.Served = served
	end
	local hostStart = host.Start
	host.Start = function(self, Src)
		table.insert(trace.Order, "client:Start")
		hostStart(self, Src)
	end

	return server, host, trace
end

local function serveIO()
	local answer
	local remote = {}
	function remote:InvokeServer()
		return answer and answer() or nil
	end
	return remote, function(fn)
		answer = fn
	end
end

do
	log = {}
	local server, host, trace = servePair()
	local remote, setAnswer = serveIO()

	local io = {
		New = function(class, domain, event)
			if domain == "__Serve" then
				return remote
			end
			return { Class = class }
		end,
		Wait = function(domain)
			if domain == "__Serve" then
				return remote
			end
			return {}
		end,
	}

	local function place(side, mods)
		return {
			folder("Shared", {
				folder("Config", {
					module("Junction", BARE_MAP),
					module("BootOrder", { Order = {}, Config = {} }),
				}),
			}),
			mods,
		}
	end

	-- the server half lives where the client can never see it
	local serverApp = Bootstrap.Configure({
		Hierarchy = place("Server", folder("Server", { folder("Services", { module("TService", server) }) })),
	}, opts({ IO = io }))

	check("the server runs __Serve at boot", trace.Order[1] == "server:__Serve", table.concat(trace.Order, ","))
	setAnswer(function()
		return remote.OnServerInvoke()
	end)
	check("...and answers the fetch with it", remote.OnServerInvoke().TService.Difficulty == 3)

	-- the client's own module receives the data
	local clientApp = Bootstrap.Configure({
		Hierarchy = place("Client", folder("Client", { folder("Services", { module("TService", host) }) })),
	}, opts({ Side = "Client", IO = io }))

	check("__Recip runs on the client", host.Served ~= nil)
	check("...with the served data", host.Served.Difficulty == 3 and host.Served.Combos[2] == "Heavy")
	check("...BEFORE :Start", table.find(trace.Order, "client:__Recip") < table.find(trace.Order, "client:Start"))
	check("the host boots as an ordinary Service", clientApp:Get("TService") == host)

	serverApp:Stop()
	clientApp:Stop()
end

do
	-- a host that returns a table becomes that table
	local server, host = servePair(function(_, served)
		local replacement = { Served = served }
		function replacement:Start() end
		return replacement
	end)
	local remote, setAnswer = serveIO()
	local io = {
		New = function(_, domain)
			return domain == "__Serve" and remote or {}
		end,
		Wait = function(domain)
			return domain == "__Serve" and remote or {}
		end,
	}

	Bootstrap.Configure({
		Hierarchy = {
			folder("Shared", { folder("Config", { module("Junction", BARE_MAP), module("BootOrder", { Order = {}, Config = {} }) }) }),
			folder("Server", { folder("Services", { module("TService", server) }) }),
		},
	}, opts({ IO = io }))
	setAnswer(function()
		return remote.OnServerInvoke()
	end)

	local app = Bootstrap.Configure({
		Hierarchy = {
			folder("Shared", { folder("Config", { module("Junction", BARE_MAP), module("BootOrder", { Order = {}, Config = {} }) }) }),
			folder("Client", { folder("Services", { module("TService", host) }) }),
		},
	}, opts({ Side = "Client", IO = io }))

	check("a __Recip that returns a table replaces the module", app:Get("TService") ~= host)
	check("...and the replacement got the data", app:Get("TService").Served.Difficulty == 3)
	app:Stop()
end

expectError("__Serve returning functions is refused, naming the key", function()
	local bad = gameModule("BadService")
	bad.__Serve = function()
		return { Start = function() end }
	end
	return Bootstrap.Configure({
		Hierarchy = {
			folder("Shared", { folder("Config", { module("Junction", BARE_MAP), module("BootOrder", { Order = {}, Config = {} }) }) }),
			folder("Server", { folder("Services", { module("BadService", bad) }) }),
		},
	}, opts())
end, "BadService.Start is a function")

do
	-- a host with no server partner says so instead of starting silently wrong
	H.warnings.clear()
	local _, host = servePair()
	local remote = { InvokeServer = function()
		return {}
	end }
	local io = {
		New = function(_, domain)
			return domain == "__Serve" and remote or {}
		end,
		Wait = function(domain)
			return domain == "__Serve" and remote or {}
		end,
	}
	local app = Bootstrap.Configure({
		Hierarchy = {
			folder("Shared", { folder("Config", { module("Junction", BARE_MAP), module("BootOrder", { Order = {}, Config = {} }) }) }),
			folder("Client", { folder("Services", { module("TService", host) }) }),
		},
	}, opts({ Side = "Client", IO = io }))
	T.warned("a __Recip with no server __Serve warns", "no Service named \"TService\" on the server")
	app:Stop()
end

-- ======================================== BootOrder is shared across both sides ===
-- One BootOrder file lists Controllers and Managers together, so each side sees
-- names it cannot possibly have. Only a name that BELONGS here and is absent is a
-- mistake; the rest are the other side's business.

do
	local ran = {}
	local function mod(name)
		local m = {}
		function m:Start()
			table.insert(ran, name)
		end
		return m
	end

	local BOTH = {
		Order = { "SharedService", "HudController", "GameManager" },
		Config = { HudController = {}, GameManager = {} },
	}

	local function place()
		return {
			folder("Shared", {
				folder("Config", {
					module("Junction", { Local = {}, Network = {} }),
					module("BootOrder", BOTH),
				}),
				folder("Services", { module("SharedService", mod("SharedService")) }),
			}),
			folder("Server", { folder("Managers", { module("GameManager", mod("GameManager")) }) }),
			folder("Client", { folder("Controllers", { module("HudController", mod("HudController")) }) }),
		}
	end

	-- server: HudController is listed but is a Controller, so it is skipped
	ran = {}
	local h = place()
	table.remove(h, 3) -- the server does not pass the client root
	local server = Bootstrap.Configure({ Hierarchy = h }, opts())
	check("the server boots what it owns", table.concat(ran, ",") == "SharedService,GameManager", table.concat(ran, ","))
	check("...ignoring the Controller in the shared BootOrder", server:Get("HudController") == nil)
	server:Stop()

	-- client: GameManager is listed but is a Manager, so it is skipped
	ran = {}
	local h2 = place()
	table.remove(h2, 2) -- the client does not pass the server root
	local client = Bootstrap.Configure({ Hierarchy = h2 }, opts({ Side = "Client" }))
	check("the client boots what it owns", table.concat(ran, ",") == "SharedService,HudController", table.concat(ran, ","))
	check("...ignoring the Manager in the shared BootOrder", client:Get("GameManager") == nil)
	client:Stop()

	-- and Config for the other side's module is fine too
	check("BootOrder.Config for the other side is not an error", true)
end

expectError("a Controller missing on the CLIENT is still a typo", function()
	local h = {
		folder("Shared", {
			folder("Config", {
				module("Junction", { Local = {}, Network = {} }),
				module("BootOrder", { Order = { "GhostController" }, Config = {} }),
			}),
		}),
		folder("Client", { folder("Controllers", {}) }),
	}
	return Bootstrap.Configure({ Hierarchy = h }, opts({ Side = "Client" }))
end, 'BootOrder lists "GhostController", which is a Controller but was not found on the Client')

T.done()
