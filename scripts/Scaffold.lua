-- Trellis
-- scripts/Scaffold.lua
-- Valence
--
-- PASTE THIS INTO THE STUDIO COMMAND BAR.
--
-- It lays down the recommended layout around Trellis and fills it with a small game
-- that exercises every pillar, then prints a pass/fail line per check on Play. It is
-- the smoke test the Lune suite cannot be: real remotes, real replication, real
-- RunService, a real player.
--
-- Requires ReplicatedStorage.Packages.Trellis to exist already (rojo build, or drag
-- the model in). Re-running replaces what it made and leaves everything else alone.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local Packages = ReplicatedStorage:FindFirstChild("Packages")
if not (Packages and Packages:FindFirstChild("Trellis")) then
	error("[Scaffold] put Trellis in ReplicatedStorage.Packages first")
end

-- ================================================================== helpers ===

local function folder(parent, name)
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing
	end
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

local function module(parent, name, source)
	local existing = parent:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end
	local m = Instance.new("ModuleScript")
	m.Name = name
	m.Source = source
	m.Parent = parent
	return m
end

local function script_(parent, name, className, source)
	local existing = parent:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end
	local s = Instance.new(className)
	s.Name = name
	s.Source = source
	s.Parent = parent
	return s
end

-- ================================================================== the tree ===

local Shared = folder(ReplicatedStorage, "Shared")
local SharedModules = folder(Shared, "Modules")
local Config = folder(SharedModules, "Config")
local SharedUtility = folder(SharedModules, "Utility")
local SharedServices = folder(SharedModules, "Services")

local Server = folder(ServerScriptService, "Server")
local Managers = folder(Server, "Managers")
local ServerServices = folder(Server, "Services")

local StarterScripts = StarterPlayer:FindFirstChild("StarterPlayerScripts")
local Client = folder(StarterScripts, "Client")
local Controllers = folder(Client, "Controllers")

-- =================================================================== config ===

module(Config, "Junction", [==[
local Junction = {}

Junction.Network = {
	Smoke = {
		Ping = {
			Destination = "SmokeManager",
			Schema = { N = { Type = "number", Min = 1, Max = 10 } },
		},
		Pong = {},
		Ask = { Kind = "Resolve", Destination = "SmokeManager" },
	},
}

Junction.Local = {
	Smoke = {
		Note = {},
	},
}

Junction.Fence = {
	Smoke = { Events = { "Network.Smoke.Ping" }, Rate = 5, Per = 1 },
}

return Junction
]==])

module(Config, "BootOrder", [==[
return {
	Order = { "SmokeService", "SmokeManager" },
	Config = {
		SmokeManager = { Hz = 10, Fences = { "Smoke" } },
	},
}
]==])

module(Config, "Registers", [==[
return {
	Session = {
		Replicate = "Owner",
		Cats = { Stats = {}, Bag = { Dynamic = true } },
		Policies = { ["Stats.*"] = "Server", ["Bag.*"] = "Owner" },
	},
	Round = { Replicate = "All", Cats = { Scores = {} } },
}
]==])

module(SharedUtility, "Report", [==[
-- Collects pass/fail lines from both sides so the Output window reads as a report.
local Report = {}

function Report.check(where, label, ok, detail)
	print(string.format("  %s  [%s] %s%s",
		ok and "PASS" or "FAIL",
		where,
		label,
		(not ok and detail) and ("  -> " .. tostring(detail)) or ""
	))
	return ok
end

return Report
]==])

-- ================================================================= the game ===

module(ServerServices, "SmokeService", [==[
local SmokeService = {}

function SmokeService:Start(Src)
	self.Booted = true
end

function SmokeService:Answer()
	return "service answered"
end

return SmokeService
]==])

module(Managers, "SmokeManager", [==[
local SmokeManager = {}
SmokeManager.Req = { "Heart", "Player", "Fence", "Trove", "Timer" }

function SmokeManager:Start(Src)
	local Report = Src:GetUtility("Report")
	self.Report = Report
	self.Ticks = 0
	self.Timers = 0
	self.Src = Src

	Report.check("server", "the Service booted before us",
		Src:GetService("Smoke").Booted == true)
	Report.check("server", "Main mirrors the tree",
		Src.Main.Utility.Report == Report)

	local Smoke = Src:Network("Smoke")

	Smoke:Subscribe("Ping", function(payload, from)
		Report.check("server", "a client Ping arrived with its sender", from ~= nil)
		Report.check("server", "...and its payload", payload.N == 3, payload.N)
		Smoke:PostTo(from, "Pong", { N = payload.N * 2 })
	end)

	Smoke:Respond("Ask", function(_, from)
		return Src:GetService("Smoke"):Answer()
	end)

	self.Trove:Add(function()
		print("  ....  [server] trove cleaned")
	end)

	self:Every(1, function()
		self.Timers += 1
	end)

	-- a round register every client can see
	Src:Reg("Round"):New("Scores.Total", 0)
end

function SmokeManager:PlayerAdded(player)
	self.Report.check("server", "PlayerAdded fired (backlog replay included)", true)

	local reg = self:Reg("Session", player)
	reg:New("Stats.Health", 100)
	reg:Cat("Bag"):New("Coins", 5)

	-- prove the client's mirror fills in
	task.delay(2, function()
		self:Reg("Round"):Swap("Scores.Total", 42)
	end)
end

function SmokeManager:Fence(event, payload, from)
	if not from then
		return true
	end
	return payload.N ~= 7, "seven is banned"
end

function SmokeManager:Heartbeat(dt)
	self.Ticks += 1
end

function SmokeManager:Ready()
	self.Report.check("server", "Ready ran after every Start", true)

	task.delay(3, function()
		self.Report.check("server", "Hz = 10 ticked ~30x in 3s",
			math.abs(self.Ticks - 30) <= 8, self.Ticks)
		self.Report.check("server", "a 1s repeating timer fired ~3x",
			math.abs(self.Timers - 3) <= 1, self.Timers)
	end)
end

return SmokeManager
]==])

module(Controllers, "SmokeController", [==[
local SmokeController = {}

function SmokeController:Start(Src)
	local Report = Src:GetUtility("Report")
	self.Report = Report
	self.Src = Src

	Report.check("client", "no :GetManager on the client", Src.GetManager == nil)

	local Smoke = Src:Network("Smoke")

	Smoke:Subscribe("Pong", function(payload)
		Report.check("client", "the server's Pong came back", payload.N == 6, payload.N)
	end)

	-- a valid ping, a malformed one, and a fenced one
	Smoke:Post("Ping", { N = 3 })
	Smoke:Post("Ping", { N = 99 })   -- Schema: out of range
	Smoke:Post("Ping", { N = 7 })    -- Fence: banned

	Smoke:Resolve("Ask")
		:Next(function(answer)
			Report.check("client", "Resolve got an answer", answer == "service answered", answer)
		end)
		:Toss(function(err)
			Report.check("client", "Resolve got an answer", false, err)
		end)

	local ok = pcall(function()
		Smoke:Post("Png", {})
	end)
	Report.check("client", "a typo'd event errors at bind time", not ok)
end

function SmokeController:Ready()
	local Src = self.Src
	local Report = self.Report

	task.delay(2, function()
		local session = Src:Reg("Session")
		Report.check("client", "an Owner register replicated to its owner",
			session:Access("Stats.Health") == 100, session:Access("Stats.Health"))
		Report.check("client", "a Dynamic category replicated",
			session:Cat("Bag"):Access("Coins") == 5)

		local round = Src:Reg("Round")
		round:Bubble("Scores", function(value, path)
			Report.check("client", "Bubble fired for a replicated change",
				path == "Scores.Total" and value == 42, path .. "=" .. tostring(value))
		end)

		-- a client write to a Server path must be refused
		session:Swap("Stats.Health", 9999)
			:Next(function()
				Report.check("client", "a client write to a Server path is refused", false, "it was allowed")
			end)
			:Toss(function()
				Report.check("client", "a client write to a Server path is refused", true)
			end)

		-- ...but an Owner path is allowed
		session:Cat("Bag"):Swap("Coins", 9)
			:Next(function()
				Report.check("client", "a client write to an Owner path is allowed", true)
			end)
			:Toss(function(err)
				Report.check("client", "a client write to an Owner path is allowed", false, err)
			end)
	end)

	task.delay(4, function()
		local Trellis = require(game.ReplicatedStorage.Packages.Trellis)
		print("\n" .. Trellis.App():Report())
	end)
end

return SmokeController
]==])

-- ================================================================ bootstraps ===

script_(ServerScriptService, "ServerBootstrap", "Script", [==[
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Trellis = require(ReplicatedStorage.Packages.Trellis)

print("\n=== Trellis smoke test ===")

local app = Trellis.Configure({
	Hierarchy = {
		ReplicatedStorage.Shared.Modules,
		ServerScriptService.Server,
	},
	Log = true,
})

task.delay(6, function()
	print("\n" .. app:Report())
	print("\n" .. app:Log():Dump(24))
end)
]==])

script_(StarterScripts, "ClientBootstrap", "LocalScript", [==[
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Trellis = require(ReplicatedStorage.Packages.Trellis)

Trellis.Configure({
	Hierarchy = {
		ReplicatedStorage.Shared.Modules,
		Players.LocalPlayer.PlayerScripts:WaitForChild("Client"),
	},
	Log = true,
	Panel = true,
})
]==])

print([[
[Scaffold] done.

  ReplicatedStorage/Shared/Modules   Config, Utility, Services
  ServerScriptService/Server         Managers, Services
  StarterPlayerScripts/Client        Controllers

Press Play. The Output window should fill with PASS lines from both sides, then
the topology report and the event log. F4 toggles the live panel.

If a line says FAIL, that is a real finding -- paste it back.
]])
