-- Class derivation, Defaults inheritance, "any",
-- Side scoping, Fence resolution, boot validation and materialization.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local BASE = {
	setmetatable = setmetatable,
	string = string,
	table = table,
	type = type,
	pcall = pcall,
	error = error,
	tostring = tostring,
	typeof = nil,
	os = { clock = function()
		return 0
	end },
}

local function loadSrc(name, extra)
	local env = {}
	for k, v in BASE do
		env[k] = v
	end
	for k, v in extra or {} do
		env[k] = v
	end
	return luau.load(fs.readFile("../src/" .. name .. ".luau"), { environment = env })()
end

local Schema = loadSrc("Schema")
local Junction = loadSrc("Junction", {
	require = function(name)
		return ({ Schema = Schema })[name]
	end,
	script = { Parent = setmetatable({}, { __index = function(_, k)
		return k
	end }) },
})

local passed, failed = 0, 0
local function check(label, ok, detail)
	if ok then
		passed += 1
		print(string.format("  ok   %s", label))
	else
		failed += 1
		print(string.format("  FAIL %s%s", label, detail and ("  -> " .. tostring(detail)) or ""))
	end
end
local function expectError(label, fn, fragment)
	local ok, err = pcall(fn)
	if ok then
		check(label, false, "expected an error, got none")
		return
	end
	check(label, string.find(tostring(err), fragment, 1, true) ~= nil, err)
end

-- a registry stub: only HasController / HasManager / HasService are used
local function registry(names)
	local set = {}
	for _, n in names do
		set[n] = true
	end
	local r = {}
	for _, bin in { "Controller", "Manager", "Service" } do
		r["Has" .. bin] = function(_, name)
			return set[name] == true
		end
	end
	return r
end

print("\nJunction\n")

-- the map, shaped like the real Fantasy Arena one --------------------------------
local MAP = {
	Network = {
		Session = {
			Sync = {},
			Update = {},
			Get = { Kind = "Resolve", Destination = "SessionManager" },
		},
		Combat = {
			Swing = { Destination = "CombatManager" },
			Block = { Destination = "CombatManager" },
		},
	},

	Local = {
		State = {
			Defaults = { Side = "Server" },
			Entered = {},
			Exited = {},
		},

		Animation = {
			Defaults = { Destination = "AnimationService" },
			Play = {},
			Stop = {},
			Check = { Kind = "Resolve" },
			MarkerReached = { Destination = "any" },
		},

		Input = {
			Defaults = { Side = "Client" },
			Pressed = {},
		},
	},

	Fence = {
		Combat = { "Network.Combat" }, -- a whole domain
		Session = { "Network.Session.Get" }, -- a single event
	},
}

local SERVER = registry({ "SessionManager", "CombatManager", "AnimationService" })

local j = Junction.new(MAP, "Server", { Registry = SERVER })

-- class derivation ---------------------------------------------------------------
check("Network + Static  -> RemoteEvent", j:Entry("Network.Session.Sync").Class == "RemoteEvent")
check("Network + Resolve -> RemoteFunction", j:Entry("Network.Session.Get").Class == "RemoteFunction")
check("Local + Static    -> BindableEvent", j:Entry("Local.Animation.Play").Class == "BindableEvent")
check("Local + Resolve   -> BindableFunction", j:Entry("Local.Animation.Check").Class == "BindableFunction")

-- defaults ------------------------------------------------------------------------
check("Kind defaults to Static", j:Entry("Network.Session.Sync").Kind == "Static")
check("Destination defaults to none", j:Entry("Network.Session.Sync").Destination == nil)

-- Defaults inheritance ------------------------------------------------------------
check("domain Defaults supply Side", j:Entry("Local.State.Entered").Side == "Server")
check("domain Defaults supply Destination", j:Entry("Local.Animation.Play").Destination == "AnimationService")
check("Defaults reach every entry", j:Entry("Local.Animation.Stop").Destination == "AnimationService")
check('"any" clears an inherited Destination', j:Entry("Local.Animation.MarkerReached").Destination == nil)
check("Defaults is not itself an event", j:Entry("Local.Animation.Defaults") == nil)
check("per-entry Kind beats the default", j:Entry("Local.Animation.Check").Kind == "Resolve")

-- fences ---------------------------------------------------------------------------
local combatFence = j:Fence("Combat")
check("a Fence may name a whole domain", table.concat(combatFence, ",") == "Network.Combat.Block,Network.Combat.Swing", table.concat(combatFence, ","))
check("a Fence may name one event", table.concat(j:Fence("Session"), ",") == "Network.Session.Get")
check("reverse lookup: event -> fences", table.concat(j:FencesFor("Network.Combat.Swing"), ",") == "Combat")
check("unfenced events have no fences", #j:FencesFor("Network.Session.Sync") == 0)

-- lookup errors ---------------------------------------------------------------------
expectError("a bad event name lists its siblings", function()
	return j:Resolve("Network", "Combat", "Swng")
end, 'no event "Swng" in Network.Combat. events there: Block, Swing')

expectError("a bad domain says so", function()
	return j:Resolve("Network", "Combt", "Swing")
end, 'no Network domain "Combt"')

-- validation -------------------------------------------------------------------------
expectError("a Local destination that isn't a module here", function()
	return Junction.new({
		Local = { Animation = { Play = { Destination = "AnimatoinService" } } },
	}, "Server", { Registry = SERVER })
end, 'routes to "AnimatoinService", which is not a module on the Server')

expectError("a typo IN the suffix is caught (the common case)", function()
	return Junction.new({
		Network = { Combat = { Swing = { Destination = "CombatMangaer" } } },
	}, "Server", { Registry = SERVER })
end, 'routes to "CombatMangaer", which does not end in Controller, Manager or Service')

expectError("a typo'd NETWORK Manager destination is caught server-side", function()
	return Junction.new({
		Network = { Combat = { Swing = { Destination = "GraveManager" } } },
	}, "Server", { Registry = SERVER })
end, 'routes to "GraveManager", which is not a module on the Server')

check("a Controller destination is NOT checked on the server", (function()
	local ok = pcall(function()
		return Junction.new({
			Network = { Combat = { Hit = { Destination = "CombatController" } } },
		}, "Server", { Registry = SERVER })
	end)
	return ok
end)())

expectError("...but IS checked on the client", function()
	return Junction.new({
		Network = { Combat = { Hit = { Destination = "HudController" } } },
	}, "Client", { Registry = registry({ "CombatController" }) })
end, 'routes to "HudController", which is not a module on the Client')

check("a Service destination is never side-checked", (function()
	return (pcall(function()
		return Junction.new({
			Network = { Combat = { Hit = { Destination = "GhostService" } } },
		}, "Server", { Registry = SERVER })
	end))
end)())

expectError("a bad Kind is rejected", function()
	return Junction.new({ Local = { A = { B = { Kind = "Signal" } } } }, "Server", { Registry = SERVER })
end, 'has Kind "Signal"')

expectError("an unknown namespace is rejected", function()
	return Junction.new({ Remote = { A = { B = {} } } }, "Server", { Registry = SERVER })
end, "unknown namespace")

expectError("Side on a Network entry is meaningless", function()
	return Junction.new({
		Network = { A = { B = { Side = "Server" } } },
	}, "Server", { Registry = SERVER })
end, "Side is meaningless")

expectError("a Fence naming nothing real is caught", function()
	return Junction.new({
		Network = { Combat = { Swing = {} } },
		Fence = { Combat = { "Network.Combat.Swng" } },
	}, "Server", { Registry = SERVER })
end, 'Fence "Combat" names "Network.Combat.Swng"')

-- Local Side scoping -------------------------------------------------------------------
do
	-- Input is Side = "Client"; its destination need not exist on the server
	local ok = pcall(function()
		return Junction.new({
			Local = { Input = { Defaults = { Side = "Client" }, Pressed = { Destination = "InputController" } } },
		}, "Server", { Registry = SERVER })
	end)
	check("a Local entry scoped to the other side isn't checked here", ok)
end

-- materialization -----------------------------------------------------------------------
do
	local created, waited = {}, {}
	local io = {
		New = function(class, domain, event)
			local key = string.format("%s/%s", domain, event)
			created[key] = class
			return { Class = class, Key = key }
		end,
		Wait = function(domain, event)
			local key = string.format("%s/%s", domain, event)
			waited[key] = true
			return { Key = key }
		end,
	}

	local server = Junction.new(MAP, "Server", { Registry = SERVER })
	server:Materialize(io)

	check("server creates a RemoteEvent per Static entry", created["Session/Sync"] == "RemoteEvent")
	check("server creates a RemoteFunction per Resolve entry", created["Session/Get"] == "RemoteFunction")
	check("instances mirror the map's nesting", server:Instance("Network.Combat.Swing").Key == "Combat/Swing")
	check("Local entries get a plain signal, not an instance", server:Instance("Local.Animation.Play") == nil)
	check("...and the signal exists", server:Signal("Local.Animation.Play") ~= nil)
	check("no Bindable was created", created["Animation/Play"] == nil)

	local clientIO = {
		New = function()
			error("the client must not create Network instances")
		end,
		Wait = io.Wait,
	}
	local client = Junction.new(MAP, "Client", { Registry = registry({ "SessionManager", "CombatManager", "AnimationService" }) })
	client:Materialize(clientIO)
	check("client waits rather than creating", waited["Session/Sync"] == true)
end

-- Instanced opt-in ---------------------------------------------------------------------
do
	local created = {}
	local j2 = Junction.new({
		Local = { Debug = { Ping = { Instanced = true } } },
	}, "Server", { Registry = SERVER })
	j2:Materialize({
		New = function(class, domain, event)
			created[domain .. "/" .. event] = class
			return {}
		end,
		Wait = function() end,
	})
	check("Instanced = true makes a real BindableEvent", created["Debug/Ping"] == "BindableEvent")
end

print(string.format("\n%d passed, %d failed\n", passed, failed))
if failed > 0 then
	process.exit(1)
end
