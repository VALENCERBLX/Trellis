--!nonstrict
-- Example: testing YOUR modules with no Roblox instances and a clock you advance.
-- Runs under Lune, so this is a real test rather than a play-through.

local Trellis = require(game.ReplicatedStorage.Shared.Modules.Packages.Trellis)
local Config = require(game.ReplicatedStorage.Shared.Modules.Config)
local Modules = require(script.Parent.Modules)

local function combatTest()
	local T = Trellis.__Tenv_({
		Side = "Server",
		Junction = Config.Junction,
		BootOrder = Config.BootOrder,
		Registers = Config.Registers,
		Modules = {
			Managers = {
				CombatManager = Modules.CombatManager,
				SessionManager = Modules.SessionManager,
			},
		},
	})

	local ada = T:Join("Ada")
	assert(T:Reg("Session", ada):Access("Stats.Health") == 100, "the join default")

	-- as if a client sent it
	T:Send("Network.Combat.Swing", { Target = workspace, Combo = 2, Style = "Light" }, ada)
	assert(#T:Sent("Network.Combat.Hit") == 1, "the swing was answered")

	-- malformed traffic never reaches a handler
	T:Clear()
	T:Send("Network.Combat.Swing", { Combo = 99 }, ada)
	assert(#T:Sent("Network.Combat.Hit") == 0, "the Schema rejected it")

	-- a second of frames: heartbeats and timers, at their declared rates
	T:Wait(1)

	-- what actually happened, if something did not
	print(T:Dump())

	T:Stop()
end

combatTest()
return nil
