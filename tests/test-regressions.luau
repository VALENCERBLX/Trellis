-- Bugs that were shipped once, found, and fixed. Each is pinned here by name so a
-- refactor that reintroduces one fails loudly rather than quietly.

local H = require("./harness")
local T = H.suite("Regressions")

local check = T.check
local folder, module = H.folder, H.module

local Scheduler = H.src("Scheduler")
local Registry = H.src("Registry")
local Reg = H.src("Reg")
local Junction = H.src("Junction")
local Src = H.src("Src")
local Bootstrap = H.src("Bootstrap")

-- ==============================================================================
-- 1. The scheduler zeroed its accumulator instead of carrying the remainder.
--
-- At Hz = 10 the period lands just past six frames, so every fire slipped to the
-- seventh: 17 calls in two seconds instead of 20. Exact RATE and exact DT are
-- different requirements and need separate counters -- one that carries its
-- remainder to keep the average rate, one that measures wall time and zeroes on
-- every call so each dt is counted once.
-- ==============================================================================
do
	local sched = Scheduler.new("Server")
	local calls, total = 0, 0
	sched:Add("M", {
		Heartbeat = function(_, dt)
			calls += 1
			total += dt
		end,
	}, 10)

	for _ = 1, 120 do
		sched:Step("Heart", 1 / 60)
	end

	T.equal("Hz=10 over 2s fires exactly 20 times, not 17", calls, 20)
	-- The tail of the final window has not been delivered yet, so the delivered
	-- total trails wall clock by less than one period -- never by more.
	T.near("...and accumulated dt still sums to wall clock", total, 2, 0.11)
	check("...never overshooting it", total <= 2 + 1e-9, total)
end

-- ==============================================================================
-- 2. Rate limiting ran AFTER schema validation.
--
-- A malformed payload was rejected before it ever reached the budget, so a flood
-- of garbage was exempt from the rate limit that exists to stop exactly that.
-- Rate must be checked first.
-- ==============================================================================
do
	H.clock.set(500)

	local map = {
		Network = {
			Guard = { Ping = { Schema = { N = "number" } } },
		},
		Fence = { Throttle = { Events = { "Network.Guard.Ping" }, Rate = 2, Per = 1 } },
	}

	local j = Junction.new(map, "Server")
	local delivered = 0
	local remote = { _handlers = {} }
	remote.OnServerEvent = {
		Connect = function(_, fn)
			table.insert(remote._handlers, fn)
			return { Disconnect = function() end }
		end,
	}
	j:Materialize({
		New = function()
			return remote
		end,
		Wait = function()
			return remote
		end,
	})

	local src = Src.new({ Name = "GuardManager", Role = "Manager" }, {
		Side = "Server",
		Junction = j,
		Latches = {},
	})
	src:Network("Guard"):Subscribe("Ping", function()
		delivered += 1
	end)

	local ada = { Name = "Ada", UserId = 1 }
	local function send(payload)
		for _, fn in remote._handlers do
			fn(ada, payload)
		end
	end

	-- two malformed sends: rejected by the schema, but they must still SPEND budget
	send("garbage")
	send("garbage")
	H.warnings.clear()
	send({ N = 1 }) -- well-formed, but the budget is already gone

	T.equal("malformed traffic spends the rate budget", delivered, 0)
	T.warned("...and the third is refused on rate, not shape", "rate: fence")
	H.clock.reset()
end

-- ==============================================================================
-- 3. `ROLES = { Service = nil }` silently dropped every Service.
--
-- A nil value in a Luau table literal removes the key entirely, so the role was
-- never iterated and no Service ever booted. The sentinel must be a real value.
-- ==============================================================================
do
	local booted = false
	local svc = {}
	function svc:Start()
		booted = true
	end

	local hierarchy = {
		folder("Shared", {
			folder("Config", { module("Junction", { Local = {}, Network = {} }) }),
			folder("Services", { module("OnlyService", svc) }),
		}),
	}

	local app = Bootstrap.Configure({ Hierarchy = hierarchy }, {
		Side = "Server",
		Loader = H.loader,
		Players = { GetPlayers = function()
			return {}
		end, PlayerRemoving = { Connect = function()
			return { Disconnect = function() end }
		end } },
		RunService = {},
		IO = { New = function()
			return {}
		end, Wait = function()
			return {}
		end },
	})

	check("a Service boots on the server", booted)
	check("...and appears in the app", app:Get("OnlyService") ~= nil)
	app:Stop()
end

-- ==============================================================================
-- 4. A client could request Op = "Cat" on a non-Dynamic category.
--
-- _apply created categories unconditionally, so a client request could grow the
-- register tree anywhere, without limit. A local apply (a client's request, seen
-- on the server) must obey Dynamic; only the server's own echo is trusted.
-- ==============================================================================
do
	local store = Reg.new({
		Session = { Replicate = "Owner", Cats = { Stats = {}, Bag = { Dynamic = true } } },
	}, "Server", nil)

	local ada = { UserId = 7 }
	local refused = not pcall(function()
		store:_apply({ Op = "Cat", Reg = "Session", Owner = ada, Path = "Stats.Sneaky" }, false)
	end)
	check("a client-requested Cat under a fixed category is refused", refused)

	local allowed = pcall(function()
		store:_apply({ Op = "Cat", Reg = "Session", Owner = ada, Path = "Bag.sword" }, false)
	end)
	check("...but a Dynamic parent still accepts one", allowed)

	local echoed = pcall(function()
		store:_apply({ Op = "Cat", Reg = "Session", Owner = ada, Path = "Stats.FromServer" }, true)
	end)
	check("...and the server's own echo is trusted", echoed)
end

-- ==============================================================================
-- 5. Registry:Reconcile left the suffix alias behind.
--
-- The alias ("Combat") and the real name ("CombatService") point at the SAME entry
-- object, so replacing only the real name left two distinct entries reporting the
-- same Name -- and the boot died with `two modules named "CombatService"`.
-- ==============================================================================
do
	local shared = folder("Shared", { folder("Services", { module("CombatService", { id = "shared" }) }) })
	local client = folder("Client", { folder("Services", { module("CombatService", { id = "client" }) }) })

	local registry = Registry.new({ shared, client }, { Loader = H.loader })
	registry:Reconcile("Service", "CombatService", { id = "reconciled" })

	local names = registry:Names("Service")
	T.equal("Names reports the module exactly once after Reconcile", #names, 1)
	T.equal("the real name resolves to the reconciled value", registry:GetService("CombatService").id, "reconciled")
	T.equal("...and so does the suffix alias", registry:GetService("Combat").id, "reconciled")
end

T.done()
