-- Lune harness for Tenv.luau — boots a whole fake game through the PUBLIC surface
-- and exercises every pillar together: registry, junction, capabilities, registers,
-- persistence, log, restart.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local warnings = {}
local DEPS = {}

local SCRIPT = setmetatable({}, {
	__index = function(t, k)
		if k == "Parent" then
			return t
		end
		return k
	end,
})

local function load(name)
	local env = {
		setmetatable = setmetatable,
		getmetatable = getmetatable,
		rawget = rawget,
		string = string,
		table = table,
		math = math,
		type = type,
		pcall = pcall,
		error = error,
		tostring = tostring,
		tonumber = tonumber,
		print = print,
		select = select,
		os = { clock = os.clock, time = os.time },
		debug = { profilebegin = function() end, profileend = function() end },
		task = {
			spawn = function(fn, ...)
				fn(...)
			end,
			delay = function() end,
			wait = function() end,
		},
		warn = function(m)
			table.insert(warnings, m)
		end,
		require = function(k)
			return DEPS[k]
		end,
		script = SCRIPT,
		game = { GetService = function()
			error("no live services in the harness")
		end },
	}
	DEPS[name] = luau.load(fs.readFile("../src/" .. name .. ".luau"), { environment = env })()
	return DEPS[name]
end

-- dependency order
load("Types")
load("Schema")
load("Reaction")
load("Trove")
load("Log")
load("Registry")
load("Junction")
load("Scheduler")
load("Reg")
load("Src")
load("Inspect")
local Bootstrap = load("Bootstrap")
local Tenv = load("Tenv")

local function makeEnv(spec)
	return Tenv.new(Bootstrap, spec)
end

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

-- ==================================================================== the game ===

local JUNCTION = {
	Network = {
		Combat = {
			Swing = {
				Destination = "CombatManager",
				Schema = { Combo = { Type = "number", Min = 1, Max = 5 } },
			},
			Hit = {},
		},
		Session = {
			Get = { Kind = "Resolve", Destination = "SessionManager" },
		},
	},
	Local = {
		Round = { Began = {}, Ended = {} },
	},
	Fence = {
		Combat = { Events = { "Network.Combat.Swing" }, Rate = 3, Per = 1 },
	},
}

local BOOT_ORDER = {
	Order = { "MemoryService", "SessionManager", { "CombatManager" } },
	Config = {
		CombatManager = { Hz = 20, Fences = { "Combat" } },
		SessionManager = { Tags = { "Spawn" } },
	},
}

local REGISTERS = {
	Session = {
		Replicate = "Owner",
		Persist = true,
		Cats = { Stats = {}, Bag = { Dynamic = true } },
		Policies = { ["Stats.*"] = "Server" },
	},
	Round = { Replicate = "All", Cats = { Scores = {} } },
}

local trace

local function buildModules()
	trace = { Ticks = 0, Timers = 0, Swings = {}, Joined = {}, Tagged = {}, Stopped = {} }

	local MemoryService = {}
	function MemoryService:Start() end

	local SessionManager = { Req = { "Player", "Tag", "Trove" } }
	function SessionManager:Start(Src)
		self.Src = Src
		Src:Network("Session"):Respond("Get", function(_, from)
			return { who = from and from.Name or "server" }
		end)
		self.Trove:Add(function()
			table.insert(trace.Stopped, "SessionManager.Trove")
		end)
	end
	function SessionManager:PlayerAdded(player)
		table.insert(trace.Joined, player.Name)
		-- A persisted register may already hold this player's data, so seed the
		-- default only when there is nothing there. This is the pattern; New on a
		-- hydrated key is (correctly) an error.
		local reg = self:Reg("Session", player)
		if reg:Access("Stats.Health") == nil then
			reg:New("Stats.Health", 100)
		end
	end
	function SessionManager:TagAdded(instance)
		table.insert(trace.Tagged, instance.Name)
	end

	local CombatManager = { Req = { "Heart", "Fence", "Timer" } }
	function CombatManager:Start(Src)
		Src:Network("Combat"):Subscribe("Swing", function(payload, from)
			table.insert(trace.Swings, { Combo = payload.Combo, From = from and from.Name })
			Src:Network("Combat"):PostAll("Hit", { Combo = payload.Combo })
		end)
		self:Every(0.5, function()
			trace.Timers += 1
		end)
	end
	function CombatManager:Heartbeat()
		trace.Ticks += 1
	end
	function CombatManager:Fence(_, payload)
		return payload.Combo ~= 4, "combo 4 is banned"
	end

	return {
		Services = { MemoryService = MemoryService },
		Managers = { SessionManager = SessionManager, CombatManager = CombatManager },
	}
end

-- a tiny in-memory persistence backend
local function makeStore()
	local data, released = {}, {}
	return {
		Load = function(key)
			return data[key]
		end,
		Save = function(key, value)
			data[key] = value
		end,
		Release = function(key)
			released[key] = true
		end,
	}, data, released
end

print("\nTenv\n")

-- boot ------------------------------------------------------------------------
local store, storeData, released = makeStore()
local T = makeEnv({
	Side = "Server",
	Junction = JUNCTION,
	BootOrder = BOOT_ORDER,
	Registers = REGISTERS,
	Store = store,
	Modules = buildModules(),
})

check("the app boots with no Roblox instances", T.App ~= nil)
check("boot order is honoured", table.concat(T.App.Order, ",") == "MemoryService,SessionManager,CombatManager", table.concat(T.App.Order, ","))
check("Managers booted on the server", #T.App:List("Manager") == 2)

-- players ----------------------------------------------------------------------
local ada = T:Join("Ada")
check("Join fires PlayerAdded", trace.Joined[1] == "Ada")
check("...and the module could write that player's register", T:Reg("Session", ada):Access("Stats.Health") == 100)

-- tags ------------------------------------------------------------------------
T:Tag({ Name = "SpawnPad" }, "Spawn")
check("Tag fires TagAdded", trace.Tagged[1] == "SpawnPad")

-- the wire ---------------------------------------------------------------------
T:Send("Network.Combat.Swing", { Combo = 2 }, ada)
check("an inbound remote reaches the handler", #trace.Swings == 1)
check("...with the sender", trace.Swings[1].From == "Ada")
check("...and the handler's reply left", #T:Sent("Network.Combat.Hit") == 1)
check("...as a broadcast", T:Sent("Network.Combat.Hit")[1].Dir == "ToAll")

T:Send("Network.Combat.Swing", { Combo = 99 }, ada)
check("a payload failing the Schema never lands", #trace.Swings == 1, #trace.Swings)

T:Send("Network.Combat.Swing", { Combo = 4 }, ada)
check("a payload refused by the Fence never lands", #trace.Swings == 1, #trace.Swings)

-- Rate runs FIRST, so the malformed and fenced sends above already spent budget:
-- three sends have been counted, and the next is over the limit.
warnings = {}
T:Send("Network.Combat.Swing", { Combo = 1 }, ada)
check("the rate budget counts refused traffic too", #trace.Swings == 1, #trace.Swings)
check("...naming the fence and the budget", (function()
	for _, w in warnings do
		if string.find(w, 'rate: fence "Combat" allows 3 per 1s', 1, true) then
			return true
		end
	end
	return false
end)(), warnings[1])

T:Wait(1.2, 0.01) -- the window rolls over
T:Send("Network.Combat.Swing", { Combo = 1 }, ada)
check("a fresh window lets traffic through again", #trace.Swings == 2, #trace.Swings)

-- the clock -----------------------------------------------------------------------
check("Hz = 20 ticks ~20x per second", math.abs(trace.Ticks - 24) <= 2, trace.Ticks)
check("a 0.5s repeating timer keeps its period", trace.Timers == 2, trace.Timers)

-- registers ------------------------------------------------------------------------
local round = T:Reg("Round")
round:New("Scores.Red", 0)
round:Edit("Scores.Red", 3)
check("a register mutation applies", round:Access("Scores.Red") == 3)

local seen
round:Bubble("Scores", function(_, path)
	seen = path
end)
round:Swap("Scores.Red", 9)
check("Bubble fires for a descendant", seen == "Scores.Red", seen)

-- persistence -------------------------------------------------------------------------
T:Reg("Session", ada):Swap("Stats.Health", 42)
check("nothing is written until it is flushed", storeData["Session/100"] == nil)

T:Leave(ada)
check("leaving flushes the player's register", storeData["Session/100"] ~= nil)
check("...with the values", storeData["Session/100"].C.Stats.V.Health == 42, storeData["Session/100"])
check("...and releases the backend's hold", released["Session/100"] == true)

local back = T:Join("Ada")
check("a rejoin hydrates from the store", T:Reg("Session", back):Access("Stats.Health") == 42, T:Reg("Session", back):Access("Stats.Health"))

-- diagnostics ---------------------------------------------------------------------------
do
	local report = T:Report()
	check("Report renders the topology", string.find(report, "ROUTES", 1, true) ~= nil)
	check("...naming a fenced route", string.find(report, "fenced:Combat", 1, true) ~= nil)
	check("...and the rate budget", string.find(report, "rate 3/1s", 1, true) ~= nil)
	check("...and the registers", string.find(report, "REGISTERS", 1, true) ~= nil)

	local dump = T:Dump()
	check("the log has a transcript", string.find(dump, "Network.Combat.Swing", 1, true) ~= nil)
	check("...including refusals", string.find(dump, "refused", 1, true) ~= nil)
end

-- errors ------------------------------------------------------------------------------------
expectError("Send to an unknown path lists the real ones", function()
	T:Send("Network.Combat.Swong", {})
end, '__Tenv_: no remote "Network.Combat.Swong"')

-- teardown -------------------------------------------------------------------------------------
T:Stop()
check(":Stop cleans a module's Trove", trace.Stopped[1] == "SessionManager.Trove")

-- restart ----------------------------------------------------------------------------------------
do
	local T2 = makeEnv({
		Side = "Server",
		Junction = JUNCTION,
		BootOrder = BOOT_ORDER,
		Registers = REGISTERS,
		Store = makeStore(),
		Modules = buildModules(),
	})
	T2:Wait(0.5)
	local before = trace.Ticks
	check("a second environment boots clean", before > 0, before)

	local app2 = T2.App:Restart()
	check("Restart returns a live app", app2 ~= nil and app2.Order[1] == "MemoryService")
	T2:Stop()
end

-- the client side -----------------------------------------------------------------------------------
do
	local C = makeEnv({
		Side = "Client",
		Junction = JUNCTION,
		Modules = { Controllers = { HudController = (function()
			local m = {}
			function m:Start(Src)
				self.Src = Src
			end
			return m
		end)() } },
	})
	check("a client environment boots Controllers", C.App:Get("HudController") ~= nil)
	check("...and no Managers", #C.App:List("Manager") == 0)
	check("...with a LocalPlayer", C.App.Src.Side == "Client")
	C:Stop()
end

print(string.format("\n%d passed, %d failed\n", passed, failed))
if failed > 0 then
	process.exit(1)
end
