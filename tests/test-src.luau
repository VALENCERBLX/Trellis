-- Lune harness for Src.luau — the bus over Registry + Junction: verbs vs Kind,
-- (payload, from), destination filtering, fences, remotes, teardown.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local warnings = {}
local scheduled = {}

local ENV = {
	setmetatable = setmetatable,
	getmetatable = getmetatable,
	string = string,
	table = table,
	type = type,
	pcall = pcall,
	error = error,
	tostring = tostring,
	print = print,
	os = { clock = function()
		return _G.NOW or 0
	end },
	task = {
		spawn = function(fn, ...)
			fn(...)
		end,
		delay = function(t, fn)
			table.insert(scheduled, { At = t, Fn = fn })
		end,
		wait = function() end,
	},
}

local function load(path, extra)
	local env = {}
	for k, v in ENV do
		env[k] = v
	end
	for k, v in extra or {} do
		env[k] = v
	end
	env.warn = function(m)
		table.insert(warnings, m)
	end
	return luau.load(fs.readFile(path), { environment = env })()
end

local SCRIPT = { Parent = setmetatable({}, { __index = function(_, k)
	return k
end }) }

local Schema = load("../src/Schema.luau")
local Reaction = load("../src/Reaction.luau")
local function deps(name)
	return ({ Schema = Schema, Reaction = Reaction })[name]
end

local Junction = load("../src/Junction.luau", { require = deps, script = SCRIPT })
local Src = load("../src/Src.luau", { require = deps, script = SCRIPT })

-- ============================================================== remote stubs ===

local function remoteEvent()
	local r = { _server = {}, _client = {}, Fired = {} }
	r.OnServerEvent = {
		Connect = function(_, fn)
			table.insert(r._server, fn)
			return { Disconnect = function()
				r._server = {}
			end }
		end,
	}
	r.OnClientEvent = {
		Connect = function(_, fn)
			table.insert(r._client, fn)
			return { Disconnect = function()
				r._client = {}
			end }
		end,
	}
	function r:FireServer(payload)
		table.insert(self.Fired, { Dir = "ToServer", Payload = payload })
	end
	function r:FireClient(player, payload)
		table.insert(self.Fired, { Dir = "ToClient", Player = player, Payload = payload })
	end
	function r:FireAllClients(payload)
		table.insert(self.Fired, { Dir = "ToAll", Payload = payload })
	end
	-- simulate a client's packet arriving at the server
	function r:Receive(player, payload)
		for _, fn in self._server do
			fn(player, payload)
		end
	end
	return r
end

local function remoteFunction()
	local r = {}
	function r:InvokeServer(payload)
		return self.OnServerInvoke(nil, payload)
	end
	return r
end

local MAP = {
	Network = {
		Guard = {
			Strict = { Schema = { Combo = { Type = "number", Min = 1, Max = 5 }, Style = "string?" } },
			Limited = {},
		},
		Combat = {
			Swing = { Destination = "CombatManager" },
			Hit = {}, -- no Destination: everyone in the domain
		},
		Session = { Get = { Kind = "Resolve", Destination = "SessionManager" } },
	},
	Local = {
		Input = { Pressed = {}, Held = { Destination = "InputController" } },
		Animation = { Check = { Kind = "Resolve" } },
	},
	Fence = {
		Combat = { "Network.Combat.Swing" },
		Throttle = { Events = { "Network.Guard.Limited" }, Rate = 2, Per = 1 },
	},
}

local function build(side)
	local j = Junction.new(MAP, side)
	j:Materialize({
		New = function(class, domain, event)
			return if string.find(class, "Function") then remoteFunction() else remoteEvent()
		end,
		Wait = function()
			return remoteEvent()
		end,
	})

	local runtime = {
		Side = side,
		Junction = j,
		Latches = {},
		Players = { GetPlayers = function()
			return {}
		end },
	}

	return j, runtime, function(name, role)
		return Src.new({ Name = name, Role = role or "Manager" }, runtime)
	end
end

-- ==================================================================== tests ===

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

print("\nSrc\n")

-- verbs vs Kind -------------------------------------------------------------------
do
	local _, _, make = build("Server")
	local src = make("CombatManager")

	expectError("Post on a Resolve entry", function()
		src:Network("Session"):Post("Get", {})
	end, 'is Kind "Resolve"; :Post is not one of its verbs')

	expectError("Resolve on a Static entry", function()
		src:Local("Input"):Resolve("Pressed")
	end, 'is Kind "Static"; :Resolve is not one of its verbs')

	expectError("a typo'd event lists the real ones", function()
		src:Local("Input"):Post("Presed", {})
	end, 'no event "Presed" in Local.Input. events there: Held, Pressed')
end

-- local delivery + (payload, from) ---------------------------------------------------
do
	local _, _, make = build("Server")
	local a, b = make("AManager"), make("BManager")
	local got = {}

	b:Local("Input"):Subscribe("Pressed", function(payload, from)
		table.insert(got, { Payload = payload, From = from })
	end)
	a:Local("Input"):Post("Pressed", { key = "M1" })

	check("a local post reaches the subscriber", #got == 1)
	check("payload arrives intact", got[1].Payload.key == "M1")
	check("from is nil for an in-process event (trusted)", got[1].From == nil)
end

-- destination filtering --------------------------------------------------------------
do
	local _, _, make = build("Server")
	local input, other = make("InputController"), make("OtherManager")
	local hits = { Input = 0, Other = 0 }

	input:Local("Input"):Subscribe("Held", function()
		hits.Input += 1
	end)

	warnings = {}
	other:Local("Input"):Subscribe("Held", function()
		hits.Other += 1
	end)
	check("subscribing to an event routed elsewhere warns", (function()
		for _, w in warnings do
			if string.find(w, "routes it to InputController -- it will never fire", 1, true) then
				return true
			end
		end
		return false
	end)())

	other:Local("Input"):Post("Held", {})
	check("the addressed module receives it", hits.Input == 1)
	check("an unaddressed subscriber does NOT", hits.Other == 0, hits.Other)
end

-- unsubscribe + Once ------------------------------------------------------------------
do
	local _, _, make = build("Server")
	local src = make("AManager")
	local count = 0

	local stop = src:Local("Input"):Subscribe("Pressed", function()
		count += 1
	end)
	src:Local("Input"):Post("Pressed", {})
	stop()
	src:Local("Input"):Post("Pressed", {})
	check("Subscribe returns a working unsubscribe", count == 1, count)

	local onces = 0
	src:Local("Input"):Once("Pressed", function()
		onces += 1
	end)
	src:Local("Input"):Post("Pressed", {})
	src:Local("Input"):Post("Pressed", {})
	check("Once fires exactly once", onces == 1, onces)
end

-- local Resolve / Respond ---------------------------------------------------------------
do
	local _, _, make = build("Server")
	local a, b = make("AManager"), make("BManager")

	b:Local("Animation"):Respond("Check", function(payload)
		return payload.n * 2
	end)

	local answer
	a:Local("Animation"):Resolve("Check", { n = 21 }):Next(function(v)
		answer = v
	end)
	check("Resolve reaches the responder", answer == 42, answer)

	expectError("two responders on one event", function()
		a:Local("Animation"):Respond("Check", function() end)
	end, "already has a responder")

	local err
	local c = make("CManager")
	c:Local("Input") -- unrelated
	local j2, _, make2 = build("Server")
	make2("DManager"):Local("Animation"):Resolve("Check"):Toss(function(e)
		err = e
	end)
	check("Resolve with no responder rejects", string.find(tostring(err), "has no responder") ~= nil, err)
end

-- network direction ------------------------------------------------------------------------
do
	local j, _, make = build("Client")
	local src = make("CombatController", "Controller")
	src:Network("Combat"):Post("Hit", { dmg = 5 })
	check("a client Post fires the server", j:Instance("Network.Combat.Hit").Fired[1].Dir == "ToServer")

	local js, _, makeS = build("Server")
	local srv = makeS("CombatManager")
	srv:Network("Combat"):Post("Hit", { dmg = 5 })
	check("a server Post fires all clients", js:Instance("Network.Combat.Hit").Fired[1].Dir == "ToAll")

	srv:Network("Combat"):PostTo({ Name = "Ada" }, "Hit", {})
	check("PostTo targets one client", js:Instance("Network.Combat.Hit").Fired[2].Dir == "ToClient")

	expectError("PostTo is server-only", function()
		src:Network("Combat"):PostTo({}, "Hit", {})
	end, ":PostTo is server-only")

	expectError("Resolve on the server tells you to use ResolveFrom", function()
		srv:Network("Session"):Resolve("Get")
	end, "use :ResolveFrom(player, ...)")
end

-- inbound network: from is the sender ----------------------------------------------------
do
	local j, _, make = build("Server")
	local src = make("CombatManager")
	local seen

	src:Network("Combat"):Subscribe("Swing", function(payload, from)
		seen = { Payload = payload, From = from }
	end)

	local ada = { Name = "Ada" }
	j:Instance("Network.Combat.Swing"):Receive(ada, { target = 1 })

	check("an inbound remote delivers the payload", seen.Payload.target == 1)
	check("from is the sending Player (untrusted)", seen.From == ada)
end

-- fences ------------------------------------------------------------------------------------
do
	local j, runtime, make = build("Server")
	local src = make("CombatManager")

	local shapeChecks, rateChecks = 0, 0
	j:AddFencer("Combat", {
		Fence = function(_, event, payload, from)
			shapeChecks += 1
			return type(payload) == "table", "shape"
		end,
	})
	j:AddFencer("Combat", {
		Fence = function(_, event, payload, from)
			rateChecks += 1
			return payload.n ~= 99, "rate"
		end,
	})

	local delivered = 0
	src:Network("Combat"):Subscribe("Swing", function()
		delivered += 1
	end)

	local remote = j:Instance("Network.Combat.Swing")
	remote:Receive({ Name = "Ada" }, { n = 1 })
	check("a payload passing every fence is delivered", delivered == 1, delivered)
	check("all fencers ran", shapeChecks == 1 and rateChecks == 1)

	warnings = {}
	remote:Receive({ Name = "Ada" }, { n = 99 })
	check("one refusing fence blocks delivery", delivered == 1, delivered)
	check("...and the reason is reported", (function()
		for _, w in warnings do
			if string.find(w, "refused: rate", 1, true) then
				return true
			end
		end
		return false
	end)())

	remote:Receive({ Name = "Ada" }, "not a table")
	check("a shape failure blocks too", delivered == 1, delivered)
end

-- Await latches ------------------------------------------------------------------------------
do
	local _, runtime, make = build("Server")
	local src = make("AManager")
	runtime.Latches["Local.Input.Pressed"] = { Done = true, Value = "already" }

	local got
	src:Await("Local.Input.Pressed"):Next(function(v)
		got = v
	end)
	check("a late Await resolves immediately", got == "already", got)
end

-- teardown ------------------------------------------------------------------------------------
do
	local _, _, make = build("Server")
	local a, b = make("AManager"), make("BManager")
	local count = 0

	b:Local("Input"):Subscribe("Pressed", function()
		count += 1
	end)
	a:Local("Input"):Post("Pressed", {})
	b:_teardown()
	a:Local("Input"):Post("Pressed", {})

	check("teardown cancels subscriptions", count == 1, count)
end

-- Reaction ---------------------------------------------------------------------------------------
do
	local chain
	Reaction.resolve(2):Map(function(v)
		return v * 10
	end):Next(function(v)
		chain = v
	end)
	check("Reaction:Map transforms", chain == 20, chain)

	local caught
	Reaction.reject("nope"):Toss(function(e)
		caught = e
	end)
	check("Reaction:Toss catches", caught == "nope")

    local late
	local r = Reaction.resolve("v")
	r:Next(function(v)
		late = v
	end)
	check("a settled Reaction runs a late Next", late == "v")

	local timedOut
	local pending = Reaction.new(function() end)
	pending:Timeout(5):Toss(function(e)
		timedOut = e
	end)
	scheduled[#scheduled].Fn()
	check("Reaction:Timeout rejects", timedOut == "timeout", timedOut)
end

-- schemas at the edge ------------------------------------------------------------
do
	local j, _, make = build("Server")
	local src = make("GuardManager")
	local got = 0
	src:Network("Guard"):Subscribe("Strict", function()
		got += 1
	end)

	local remote = j:Instance("Network.Guard.Strict")
	local ada = { Name = "Ada", UserId = 1 }

	remote:Receive(ada, { Combo = 3, Style = "Light" })
	check("a valid payload is delivered", got == 1, got)

	warnings = {}
	remote:Receive(ada, { Combo = 9 })
	check("a payload outside Min/Max never reaches the handler", got == 1, got)
	check("...and the reason names the field", (function()
		for _, w in warnings do
			if string.find(w, "Combo must be <= 5", 1, true) then
				return true
			end
		end
		return false
	end)(), warnings[1])

	remote:Receive(ada, "not a table")
	check("a payload of the wrong type is rejected", got == 1, got)

	remote:Receive(ada, { Combo = 2, Style = 7 })
	check("an optional field still type-checks", got == 1, got)

	remote:Receive(ada, { Combo = 2 })
	check("an absent optional is fine", got == 2, got)
end

-- declarative rate limits -----------------------------------------------------------
do
	_G.NOW = 100
	local j, _, make = build("Server")
	local src = make("GuardManager")
	local got = 0
	src:Network("Guard"):Subscribe("Limited", function()
		got += 1
	end)

	local remote = j:Instance("Network.Guard.Limited")
	local ada, lin = { Name = "Ada", UserId = 1 }, { Name = "Lin", UserId = 2 }

	remote:Receive(ada, {})
	remote:Receive(ada, {})
	check("calls within the budget pass", got == 2, got)

	warnings = {}
	remote:Receive(ada, {})
	check("the call over budget is dropped", got == 2, got)
	check("...naming the fence and the budget", (function()
		for _, w in warnings do
			if string.find(w, 'rate: fence "Throttle" allows 2 per 1s', 1, true) then
				return true
			end
		end
		return false
	end)(), warnings[1])

	remote:Receive(lin, {})
	check("the budget is PER PLAYER", got == 3, got)

	_G.NOW = 102
	remote:Receive(ada, {})
	check("the window resets", got == 4, got)

	-- internal traffic is not rate limited: `from` is nil, so there is no budget
	_G.NOW = 200
	for _ = 1, 10 do
		remote:Receive(nil, {})
	end
	check("internal traffic is never rate limited", got == 14, got)
	_G.NOW = 0
end

print(string.format("\n%d passed, %d failed\n", passed, failed))
if failed > 0 then
	process.exit(1)
end
