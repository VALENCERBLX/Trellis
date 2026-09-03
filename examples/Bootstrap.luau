--!nonstrict
-- Example: the two entry points. There is exactly one of each, and nothing else in
-- the game calls the framework.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

local Trellis = require(ReplicatedStorage.Packages.Trellis)

-- ============================== ServerScriptService/ServerBootstrap (Script) ===

local app = Trellis.Configure({
	-- The whole payload. Each DIRECT child folder of each root becomes a bin, and
	-- each bin generates its own getter. Junction, BootOrder and Registers are
	-- found in the Config bin by name.
	Hierarchy = {
		ReplicatedStorage.Shared.Modules, -- Packages, Utility, Config, Services
		ServerScriptService.Server, -- Managers, server Services
	},

	-- Optional. A table extends that bin; a function makes the bin a resolver.
	Inject = {
		Package = { Profiles = require(ServerScriptService.ProfileStore) },
	},

	-- Optional. Required only if a register declares Persist = true.
	Store = {
		Load = function(key)
			return nil
		end,
		Save = function(key, value) end,
		Release = function(key) end,
	},

	-- Optional diagnostics.
	Log = true, -- keep the last 64 events per path
})

print(app:Report()) -- routes, listeners, fences, registers, traffic

-- ================ StarterPlayer/StarterPlayerScripts/ClientBootstrap (Local) ===

Trellis.Configure({
	Hierarchy = {
		ReplicatedStorage.Shared.Modules,
		Players.LocalPlayer.PlayerScripts.Client, -- Controllers, client Services
	},
	Log = true,
	Panel = true, -- live on-screen topology, toggled with F4
})

--[[ ============================ the recommended layout ======================

ReplicatedStorage/
  Packages/Trellis                the framework
  Shared/Modules/
    Packages/                     shared third-party   -> :GetPackage
    Utility/                      shared helpers       -> :GetUtility
    Config/                       Junction, BootOrder, Registers, Manifests
    Services/                     shared + double-sided Services

ServerScriptService/
  ServerBootstrap
  Server/
    Managers/                     -> :GetManager   (never replicates)
    Services/                     server half of a side-split Service

StarterPlayer/StarterPlayerScripts/
  ClientBootstrap
  Client/
    Controllers/                  -> :GetController
    Services/                     client half of a side-split Service

Config sits beside Packages and Utility so it becomes its own bin. If you keep it
nested (Utility/Config), pass that folder as an extra root instead.

============================================================================ ]]

return nil
