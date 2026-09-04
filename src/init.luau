--!nonstrict
-- Trellis
-- init.luau
-- Valence
--
-- A subset of Single Script Architecture: dependency injection whose surface is
-- DERIVED from the hierarchy you hand it, one declared Junction for every event,
-- capabilities a module opts into, and a replicating register tree.
--
-- One call per side, and nothing else in the game touches the framework:
--
--   local Trellis = require(ReplicatedStorage.Shared.Modules.Packages.Trellis)
--
--   local app = Trellis.Configure({
--       Hierarchy = {
--           ReplicatedStorage.Shared.Modules,   -- Packages, Utility, Config, Services
--           ServerScriptService.Server,         -- Managers, server Services
--       },
--   })
--
-- Junction, BootOrder and Registers are found in the Config bin by name, because the
-- registry already derived that bin from your tree. Everything else has a default.
--
--   app:Report()   -- the live topology as text
--   app:Restart()  -- tear down and boot again, without leaving Play mode
--   app:Stop()
--
-- Testing, with no Roblox instances and a clock you advance:
--
--   local T = Trellis.__Tenv_({ Junction = MAP, Modules = { Managers = { ... } } })
--   T:Join("Ada"); T:Send("Network.Combat.Swing", payload, ada); T:Step()

local Bootstrap = require(script.Bootstrap)
local Tenv = require(script.Tenv)
local Types = require(script.Types)

export type Src = Types.Src
export type App = Types.App
export type Module = Types.Module
export type Config = Types.Config
export type JunctionMap = Types.JunctionMap
export type BootOrder = Types.BootOrder
export type RegisterSpec = Types.RegisterSpec
export type Register = Types.Register
export type Reaction = Types.Reaction
export type Schema = Types.Schema

local Trellis = {}

Trellis.Version = "0.1.0"

-- Pieces a game may legitimately want directly. Everything else reaches modules
-- through Src.
Trellis.Reaction = require(script.Reaction)
Trellis.Trove = require(script.Trove)
Trellis.Schema = require(script.Schema)
Trellis.Inspect = require(script.Inspect)

-- The app from the most recent Configure on this side, so diagnostics can reach it
-- without the handle being threaded through everything.
local active = nil

-- Boots this side. Call exactly once per side, from one Script and one LocalScript.
function Trellis.Configure(config: Types.Config): Types.App
	active = Bootstrap.Configure(config)
	return active
end

function Trellis.App(): Types.App?
	return active
end

function Trellis.Inspected()
	return if active then active:Inspect() else nil
end

-- A whole app with no Roblox instances: plain-Lua channels, fake players, and a
-- clock you advance by hand. Runs under Lune or in a test place.
function Trellis.__Tenv_(spec)
	return Tenv.new(Bootstrap, spec)
end

return Trellis
