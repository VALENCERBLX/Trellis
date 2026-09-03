-- The register tree: categories, dot paths, bubbling,
-- path policies, client-request authority, prediction rollback, replication scope.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local ENV = {
	setmetatable = setmetatable,
	string = string,
	table = table,
	type = type,
	pcall = pcall,
	error = error,
	tostring = tostring,
	print = print,
	task = {
		spawn = function(fn, ...)
			fn(...)
		end,
		delay = function() end,
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
	env.warn = print
	return luau.load(fs.readFile(path), { environment = env })()
end

local Reaction = load("../src/Reaction.luau")
local Reg = load("../src/Reg.luau", { require = function()
	return Reaction
end, script = { Parent = {} } })

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

-- ============================================================== the declaration ===

local ADA = { UserId = 1, Name = "Ada" }
local LIN = { UserId = 2, Name = "Lin" }

local REGISTERS = {
	Session = {
		Replicate = "Owner",
		Cats = {
			Stats = {},
			Settings = {},
			Inventory = { Dynamic = true },
		},
		Policies = {
			["Stats.*"] = "Server",
			["Settings.*"] = "Owner",
		},
	},
	Round = { Replicate = "All", Cats = { Scores = {} } },
	Secrets = { Replicate = false },
}

-- a transport that wires a fake server and client together
local function pair()
	local sent = {}
	local onServerRequest, onClientDelta

	local serverTransport = {
		Broadcast = function(delta)
			table.insert(sent, { Kind = "All", Delta = delta })
			if onClientDelta then
				onClientDelta(delta)
			end
		end,
		To = function(player, delta)
			table.insert(sent, { Kind = "To", Player = player, Delta = delta })
			if onClientDelta then
				onClientDelta(delta)
			end
		end,
		OnRequest = function(fn)
			onServerRequest = fn
		end,
	}

	local clientTransport = {
		Broadcast = function() end,
		To = function() end,
		OnDelta = function(fn)
			onClientDelta = fn
		end,
		Request = function(delta)
			local ok, reason = onServerRequest(delta, ADA)
			return Reaction.resolve({ Ok = ok, Reason = reason })
		end,
	}

	local server = Reg.new(REGISTERS, "Server", serverTransport)
	local client = Reg.new(REGISTERS, "Client", clientTransport)
	return server, client, sent
end

print("\nReg\n")

-- declaration ------------------------------------------------------------------
do
	local server = pair()
	expectError("an undeclared register lists the declared ones", function()
		return server:Open("Ghost")
	end, 'no register "Ghost". declared: Round, Secrets, Session')

	expectError("an Owner register needs an owner", function()
		return server:Open("Session")
	end, 'replicates to "Owner", so it needs one')
end

-- categories and dot paths -------------------------------------------------------
do
	local server = pair()
	local session = server:Open("Session", ADA)

	session:New("Stats.Health", 100)
	check("a dot path writes into a declared category", session:Access("Stats.Health") == 100)

	check("a missing VALUE reads as nil", session:Access("Stats.Mana") == nil)

	expectError("a missing CATEGORY throws, listing real ones", function()
		return session:Access("Statz.Health")
	end, 'no category "Statz" under "(root)". categories there: Inventory, Settings, Stats')

	expectError("Access cannot create a branch", function()
		return session:New("Comabt.Health", 5)
	end, 'no category "Comabt"')

	expectError("a key may not contain a dot", function()
		return session:Cat("a.b")
	end, "contains a dot")
end

-- Cat scoping ---------------------------------------------------------------------
do
	local server = pair()
	local session = server:Open("Session", ADA)
	local stats = session:Cat("Stats")

	stats:New("Health", 50)
	check("Cat scopes in, like Src:Local(domain)", session:Access("Stats.Health") == 50)
	check("...and reads back through the scope", stats:Access("Health") == 50)

	expectError("Cat on a non-Dynamic category refuses", function()
		return stats:Cat("Deep")
	end, 'no category "Deep" under "Stats", and it is not Dynamic')

	local inv = session:Cat("Inventory")
	local slot = inv:Cat("sword_01")
	slot:New("Count", 2)
	check("a Dynamic category creates on Cat", session:Access("Inventory.sword_01.Count") == 2)
end

-- the five verbs --------------------------------------------------------------------
do
	local server = pair()
	local round = server:Open("Round")

	round:New("Scores.Red", { points = 1 })
	check("New creates", round:Access("Scores.Red").points == 1)

	round:Edit("Scores.Red", { bonus = 5 })
	check("Edit merges, keeping what was there", round:Access("Scores.Red").points == 1 and round:Access("Scores.Red").bonus == 5)

	round:Swap("Scores.Red", { points = 99 })
	check("Swap replaces wholesale", round:Access("Scores.Red").bonus == nil and round:Access("Scores.Red").points == 99)

	round:Rem("Scores.Red")
	check("Rem deletes", round:Access("Scores.Red") == nil)

	round:New("Scores.Blue", 1)
	expectError("New on an existing key refuses", function()
		return round:New("Scores.Blue", 2)
	end, "already exists -- use :Swap or :Edit")

	check("mutations return a thenable on the server", (function()
		local got
		round:Swap("Scores.Blue", 7):Next(function()
			got = true
		end)
		return got == true
	end)())
end

-- Bubble ------------------------------------------------------------------------------
do
	local server = pair()
	local round = server:Open("Round")
	round:New("Scores.Red", 0)

	local leaf, subtree, root = {}, {}, {}
	round:Bubble("Scores.Red", function(v, p, op)
		table.insert(leaf, { v, p, op })
	end)
	round:Bubble("Scores", function(v, p, op)
		table.insert(subtree, { v, p, op })
	end)

	round:Swap("Scores.Red", 3)
	check("the exact path fires", #leaf == 1 and leaf[1][1] == 3)
	check("an ancestor category fires too", #subtree == 1)
	check("...and is told WHERE it happened", subtree[1][2] == "Scores.Red", subtree[1][2])
	check("...and which op", subtree[1][3] == "Swap")

	local stop = round:Bubble("Scores.Red", function()
		table.insert(root, 1)
	end)
	stop()
	round:Swap("Scores.Red", 4)
	check("Bubble returns a working unsubscribe", #root == 0)

	round:Swap("Scores.Blue", 1)
	check("an unrelated leaf does not fire the first watcher", #leaf == 2, #leaf)
end

-- replication scope ---------------------------------------------------------------------
do
	local server, _, sent = pair()

	server:Open("Round"):New("Scores.Red", 1)
	check('Replicate = "All" broadcasts', sent[#sent].Kind == "All")

	server:Open("Session", ADA):New("Stats.Health", 100)
	check('Replicate = "Owner" targets the owner', sent[#sent].Kind == "To" and sent[#sent].Player == ADA)

	local before = #sent
	server:Open("Secrets"):New("Key", "hunter2")
	check("Replicate = false never leaves the server", #sent == before, #sent)
end

-- the mirror ------------------------------------------------------------------------------
do
	local server, client = pair()
	server:Open("Round"):New("Scores.Red", 7)
	check("a delta reaches the client mirror", client:Open("Round"):Access("Scores.Red") == 7)

	local seen
	client:Open("Round"):Bubble("Scores", function(v, p)
		seen = p
	end)
	server:Open("Round"):Swap("Scores.Red", 8)
	check("the client bubbles on an applied delta", seen == "Scores.Red", seen)
end

-- authority --------------------------------------------------------------------------------
do
	local server, client = pair()
	server:Open("Session", ADA):New("Stats.Health", 100)
	server:Open("Session", ADA):New("Settings.Volume", 5)

	local rejected
	client:Open("Session", ADA):Swap("Stats.Health", 9999):Toss(function(reason)
		rejected = reason
	end)
	check("a client write to a Server path is refused", rejected ~= nil)
	check("...with a reason naming the path", string.find(tostring(rejected), "Session.Stats.Health is server-authoritative", 1, true) ~= nil, rejected)
	check("...and the mirror did not move", client:Open("Session", ADA):Access("Stats.Health") == 100)

	local accepted
	client:Open("Session", ADA):Swap("Settings.Volume", 9):Next(function()
		accepted = true
	end)
	check('a client write to an "Owner" path is allowed', accepted == true)
	check("...and the server applied it", server:Open("Session", ADA):Access("Settings.Volume") == 9)

	-- deny by default: an unmatched path is server-only even with no policy for it
	local unmatched
	client:Open("Round"):Swap("Scores.Red", 1):Toss(function(r)
		unmatched = r
	end)
	check("an unmatched path denies by default", string.find(tostring(unmatched), "server-authoritative", 1, true) ~= nil, unmatched)
end

-- prediction ----------------------------------------------------------------------------------
do
	local server, client = pair()
	server:Open("Session", ADA):New("Stats.Health", 100)
	server:Open("Session", ADA):New("Settings.Volume", 5)

	local mirror = client:Open("Session", ADA)

	mirror:Swap("Settings.Volume", 8, { Predict = true })
	check("a predicted write applies at once", mirror:Access("Settings.Volume") == 8)

	mirror:Swap("Stats.Health", 9999, { Predict = true })
	check("a rejected prediction rolls back", mirror:Access("Stats.Health") == 100, mirror:Access("Stats.Health"))
end

-- owner isolation ---------------------------------------------------------------------------------
do
	local server = pair()
	server:Open("Session", ADA):New("Stats.Health", 100)
	server:Open("Session", LIN):New("Stats.Health", 50)

	check("owners get separate trees", server:Open("Session", ADA):Access("Stats.Health") == 100)
	check("...genuinely separate", server:Open("Session", LIN):Access("Stats.Health") == 50)

	server:Drop(LIN)
	check("Drop clears an owner's registers", server:Open("Session", LIN):Access("Stats.Health") == nil)
end

-- a client may not conjure categories -----------------------------------------------
do
	local server, client = pair()

	-- a client request to create a category under a NON-Dynamic parent is refused,
	-- even where the path policy would otherwise allow the write
	local refused
	local ok = pcall(function()
		server:_apply({ Op = "Cat", Reg = "Session", Owner = ADA, Path = "Stats.Sneaky" }, false)
	end)
	check("a local Cat under a fixed category is refused", not ok)

	-- the server's own echo IS trusted, so a client can still receive one
	local applied = pcall(function()
		client:_apply({ Op = "Cat", Reg = "Session", Owner = ADA, Path = "Stats.Sent" }, true)
	end)
	check("the server's echo is applied", applied)

	-- and a Dynamic parent still allows it
	local dynamic = pcall(function()
		server:_apply({ Op = "Cat", Reg = "Session", Owner = ADA, Path = "Inventory.sword" }, false)
	end)
	check("a Dynamic parent still accepts one", dynamic)
end

print(string.format("\n%d passed, %d failed\n", passed, failed))
if failed > 0 then
	process.exit(1)
end
