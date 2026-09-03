-- Lune harness for the support modules: Trove, Log and Reaction.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local warnings = {}
local scheduled = {}
local NOW = 0

local function load(name)
	return luau.load(fs.readFile("../src/" .. name .. ".luau"), {
		environment = {
			setmetatable = setmetatable,
			string = string,
			table = table,
			math = math,
			type = type,
			pcall = pcall,
			error = error,
			tostring = tostring,
			print = print,
			os = { clock = function()
				return NOW
			end },
			task = {
				spawn = function(fn, ...)
					fn(...)
				end,
				delay = function(t, fn)
					table.insert(scheduled, fn)
				end,
				wait = function() end,
			},
			warn = function(m)
				table.insert(warnings, m)
			end,
		},
	})()
end

local Trove = load("Trove")
local Log = load("Log")
local Reaction = load("Reaction")

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

print("\nSupport\n")

-- ======================================================================= Trove ===
do
	local order = {}
	local t = Trove.new()

	t:Add(function()
		table.insert(order, "first")
	end)
	t:Add({ Destroy = function()
		table.insert(order, "destroyed")
	end })
	t:Add({ Disconnect = function()
		table.insert(order, "disconnected")
	end })

	check("Trove counts what it holds", t:Count() == 3, t:Count())
	t:Clean()
	check("cleanup runs in REVERSE order", table.concat(order, ",") == "disconnected,destroyed,first", table.concat(order, ","))
	check("...and empties the trove", t:Count() == 0)

	-- Disconnect wins over Destroy: a connection that also has :Destroy must be
	-- disconnected, not destroyed.
	local which = nil
	local t2 = Trove.new()
	t2:Add({
		Disconnect = function()
			which = "disconnect"
		end,
		Destroy = function()
			which = "destroy"
		end,
	})
	t2:Clean()
	check("a connection is disconnected, not destroyed", which == "disconnect", which)

	local t3 = Trove.new()
	local removed = false
	local item = { Destroy = function()
		removed = true
	end }
	t3:Add(item)
	check("Remove tears down just that item", t3:Remove(item) and removed)
	check("...and it is gone from the trove", t3:Count() == 0)
	check("Removing something absent is false", t3:Remove({}) == false)

	local t4 = Trove.new()
	local nestedCleaned = false
	local child = t4:Extend()
	child:Add(function()
		nestedCleaned = true
	end)
	t4:Clean()
	check("a nested trove is cleaned with its parent", nestedCleaned)

	-- adding during teardown must not leak or loop
	local lateCleaned = false
	local t5 = Trove.new()
	t5:Add(function()
		t5:Add(function()
			lateCleaned = true
		end)
	end)
	t5:Clean()
	check("adding during teardown cleans immediately", lateCleaned)

	warnings = {}
	local t6 = Trove.new()
	t6:Add(function()
		error("boom")
	end)
	local survived = false
	t6:Add(function()
		survived = true
	end)
	t6:Clean()
	check("one erroring item does not stop the rest", survived)
	check("...and it is reported", #warnings == 1, #warnings)

	local t7 = Trove.new()
	local tracked = false
	local untrack = t7:Track(function()
		tracked = true
	end)
	untrack()
	check("Track returns a working remover", tracked and t7:Count() == 0)
end

-- ========================================================================= Log ===
do
	NOW = 0
	local log = Log.new(3)

	log:Event("Network.Combat.Swing", { Combo = 2 }, { Name = "Ada" })
	log:Event("Network.Combat.Swing", { Combo = 3 }, { Name = "Ada" })
	log:Refused("Network.Combat.Swing", { Combo = 9 }, { Name = "Ada" }, "out of range")

	local stats = log:Stats()
	check("counts events per path", stats[1].Count == 2, stats[1].Count)
	check("...and refusals separately", stats[1].Refused == 1, stats[1].Refused)

	NOW = 2
	check("rate is per second", math.abs(log:Stats()[1].Rate - 1) < 0.01, log:Stats()[1].Rate)

	for i = 1, 5 do
		log:Event("Local.Round.Began", i, nil)
	end
	check("the ring buffer keeps only Depth entries", #log:Tail("Local.Round.Began", 99) == 3)
	check("...the NEWEST ones", log:Tail("Local.Round.Began", 1)[1].Payload == "5")

	local dump = log:Dump()
	check("the dump is a transcript", string.find(dump, "Network.Combat.Swing", 1, true) ~= nil)
	check("...marking refusals with a reason", string.find(dump, "(out of range)", 1, true) ~= nil)
	check("...and naming the sender", string.find(dump, "from=Ada", 1, true) ~= nil)

	-- payloads are stored by shape, never by reference: holding the real table would
	-- pin every payload the game ever sent
	local pinned = { secret = "value" }
	log:Event("X.Y.Z", pinned, nil)
	local entry = log:Tail("X.Y.Z", 1)[1]
	check("payloads are summarised, not retained", type(entry.Payload) == "string", type(entry.Payload))
	check("...readably", string.find(entry.Payload, "secret=", 1, true) ~= nil, entry.Payload)

	check("a long string is truncated", string.find(Log.Summarize(string.rep("x", 100)), "..", 1, true) ~= nil)
	check("deep tables stop recursing", Log.Summarize({ a = { b = { c = { d = 1 } } } }) ~= nil)
	check("an unknown path tails empty", #log:Tail("nope") == 0)
end

-- ==================================================================== Reaction ===
do
	local chain = {}
	Reaction.resolve(1)
		:Next(function(v)
			table.insert(chain, "next:" .. v)
		end)
		:Conclude(function()
			table.insert(chain, "conclude")
		end)
	check("Next then Conclude", table.concat(chain, ",") == "next:1,conclude", table.concat(chain, ","))

	local mapped
	Reaction.resolve(3):Map(function(v)
		return v * 3
	end):Next(function(v)
		mapped = v
	end)
	check("Map transforms", mapped == 9)

	local mapErr
	Reaction.resolve(1):Map(function()
		error("nope")
	end):Toss(function(e)
		mapErr = e
	end)
	check("an erroring Map fails the chain instead of the caller", mapErr ~= nil)

	local concluded
	Reaction.reject("bad"):Conclude(function(v)
		concluded = v
	end)
	check("Conclude runs on failure too", concluded == "bad")

	local cancelled
	Reaction.new(function() end):Cancel():Toss(function(e)
		cancelled = e
	end)
	check("Cancel rejects with a reason", cancelled == "cancelled")

	local settledOnce = 0
	local r = Reaction.new(function(resolve)
		resolve(1)
		resolve(2)
	end)
	r:Next(function()
		settledOnce += 1
	end)
	check("a Reaction settles exactly once", settledOnce == 1 and r.Value == 1)

	local threw
	Reaction.new(function()
		error("in executor")
	end):Toss(function(e)
		threw = e
	end)
	check("an erroring executor rejects", threw ~= nil)

	scheduled = {}
	local timedOut
	Reaction.new(function() end):Timeout(1, "too slow"):Toss(function(e)
		timedOut = e
	end)
	scheduled[1]()
	check("Timeout uses the given reason", timedOut == "too slow", timedOut)

	scheduled = {}
	local late
	local done = Reaction.resolve("v")
	done:Timeout(1)
	scheduled[1]()
	done:Next(function(v)
		late = v
	end)
	check("Timeout cannot un-settle a finished Reaction", late == "v", late)
end

print(string.format("\n%d passed, %d failed\n", passed, failed))
if failed > 0 then
	process.exit(1)
end
