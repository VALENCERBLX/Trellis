-- Trellis
-- dist/Setup.luau
-- Valence
--
-- Paste into the Studio command bar, after dist/Adeal.luau has installed the package.
--
-- Over HTTP instead (Game Settings > Security > Allow HTTP Requests):
--
--   local h = game:GetService("HttpService")
--   loadstring(h:GetAsync("https://raw.githubusercontent.com/VALENCERBLX/Trellis/master/dist/Setup.luau"))()
--
-- Lays out a project around Trellis: the module folders, the Config module with its
-- children, the shared Bootstrap, and the two entry points.
--
-- IT NEVER OVERWRITES YOUR WORK. Folders already present are reused, and a script or
-- module that already exists is left exactly as it is. Re-running is safe: it fills
-- in whatever is missing and reports what it skipped.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local made, kept = {}, {}

local function folder(parent, name)
	local existing = parent:FindFirstChild(name)
	if existing then
		table.insert(kept, existing:GetFullName())
		return existing
	end
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	table.insert(made, f:GetFullName())
	return f
end

local function script_(parent, name, className, source)
	local existing = parent:FindFirstChild(name)
	if existing then
		table.insert(kept, existing:GetFullName())
		return existing
	end
	local s = Instance.new(className)
	s.Name = name
	s.Source = source
	s.Parent = parent
	table.insert(made, s:GetFullName())
	return s
end

-- ==================================================================== sources ===

local BOOTSTRAP = [==[
-- Shared/Modules/Utilities/Bootstrap
--
-- The layout, in one place. Both entry points read it, so ServerInit and Init stay
-- three lines each and there is only ever one description of where things live.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Bootstrap = {}

-- The Hierarchy is for ModuleScripts. Instance trees are reached through resolver
-- bins instead, which gives them the same :GetX shape without pretending they are
-- modules.
local function inject()
	local Shared = ReplicatedStorage.Shared

	return {
		-- Src:GetClass("Characters.Superman")
		Class = function(path: string)
			local node = Shared.Classes
			for segment in string.gmatch(path, "[^%.]+") do
				node = node and node:FindFirstChild(segment)
			end
			return node
		end,

		-- Src:GetAsset("HealthBar"), searched across Interface/Audio/Models/Builds
		Asset = function(name: string)
			return Shared.Assets:FindFirstChild(name, true)
		end,
	}
end

function Bootstrap.Server()
	local ServerStorage = game:GetService("ServerStorage")

	return {
		Hierarchy = {
			ReplicatedStorage.Shared.Modules, -- Packages, Utilities, Services
			ServerStorage.Modules, -- Managers, Packages, Utilities, Services
		},
		Inject = inject(),
		Log = true,
	}
end

function Bootstrap.Client()
	return {
		Hierarchy = {
			ReplicatedStorage.Shared.Modules,
			ReplicatedStorage.Client.Modules, -- Controllers, Packages, Utilities, Services
		},
		Inject = inject(),
		Log = true,
		Panel = true, -- F4 toggles the live topology panel
	}
end

return Bootstrap
]==]

local CONFIG = [==[
-- Shared/Modules/Utilities/Config
--
-- Everything the framework reads at boot, plus whatever else you keep here.
-- Trellis would find these as children on its own; re-exporting makes it explicit
-- and gives modules one place to read from: Src:GetUtility("Config").Manifests

return {
	Junction = require(script.Junction),
	BootOrder = require(script.BootOrder),
	Registers = require(script.Registers),
	Manifests = require(script.Manifests),
}
]==]

local JUNCTION = [==[
-- Every event in the game, declared once.
--
--   Namespace   Network (crosses the wire) | Local (stays on one side)
--   Kind        Static (an Event) | Resolve (a Function). Static is the default.
--
--                 Kind = "Static"   Kind = "Resolve"
--   Local         BindableEvent     BindableFunction
--   Network       RemoteEvent       RemoteFunction

local Junction = {}

Junction.Network = {
	-- Session = {
	--     Sync = {},                                          -- server -> clients
	--     Update = { Destination = "SessionManager" },         -- client -> server
	--     Get = { Kind = "Resolve", Destination = "SessionManager" },
	-- },
	--
	-- Combat = {
	--     Swing = {
	--         Destination = "CombatManager",
	--         -- checked at the edge, before any fence or handler
	--         Schema = { Combo = { Type = "number", Min = 1, Max = 5 } },
	--     },
	-- },
}

Junction.Local = {
	-- A domain-level Defaults is inherited by every entry in it. Per-entry fields
	-- override, and Destination = "any" clears an inherited one.
	--
	-- Animation = {
	--     Defaults = { Destination = "AnimationService" },
	--     Play = {}, Stop = {},
	--     MarkerReached = { Destination = "any" },
	-- },
	--
	-- Input = {
	--     Defaults = { Side = "Client" },
	--     Pressed = {}, Released = {},
	-- },
}

Junction.Fence = {
	-- A named set of events, with an optional per-player budget the framework
	-- enforces. A target may be one event or a whole domain.
	--
	-- Combat = { Events = { "Network.Combat" }, Rate = 20, Per = 1 },
}

return Junction
]==]

local BOOTORDER = [==[
-- Order is WHEN a module starts. Config is HOW it is set up when it does.
--
-- Only list what genuinely needs ordering. Anything absent boots after the last
-- tier, with one warning naming it.

return {
	Order = {
		-- { "MemoryService", "SettingsService" },   -- one tier, no order within it
		-- "SessionManager",
		-- { "StateManager", "CombatManager" },
	},

	Config = {
		-- StateManager     = { Hz = 20 },                  -- Req "Heart"
		-- CameraController = { Hz = "Render" },            -- client only
		-- PickupService    = { Tags = { "Pickup" } },      -- Req "Tag"
		-- CombatManager    = { Fences = { "Combat" } },    -- Req "Fence"
	},
}
]==]

local REGISTERS = [==[
-- Replicating caches. A register is a tree: Cat is a category, and it is the only
-- thing that creates one.
--
-- A path matching no policy is server-only, so forgetting a policy fails closed.

return {
	-- Session = {
	--     Replicate = "Owner",              -- "All" | "Owner" | false
	--     Persist = true,                    -- needs Configure{ Store = ... }
	--     Cats = { Stats = {}, Inventory = { Dynamic = true } },
	--     Policies = { ["Stats.*"] = "Server", ["Settings.*"] = "Owner" },
	-- },
	--
	-- Round = { Replicate = "All", Cats = { Scores = {} } },
}
]==]

local MANIFESTS = [==[
-- Read-only game data. Not touched by the framework; reach it with
-- Src:GetUtility("Config").Manifests, or Src:GetConfig("Manifests") if you keep
-- Config as a folder instead.

return {}
]==]

local SERVER_INIT = [==[
-- ServerScriptService/ServerInit
-- The single server entry point.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Trellis = require(ReplicatedStorage.Trellis)
local Bootstrap = require(ReplicatedStorage.Shared.Modules.Utilities.Bootstrap)

local app = Trellis.Configure(Bootstrap.Server())

-- print(app:Report())        -- routes, listeners, fences, registers, traffic
-- print(app:Log():Dump())    -- the event transcript
]==]

local CLIENT_INIT = [==[
-- StarterPlayerScripts/Init
-- The single client entry point.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Trellis = require(ReplicatedStorage:WaitForChild("Trellis"))
local Bootstrap = require(ReplicatedStorage.Shared.Modules.Utilities.Bootstrap)

Trellis.Configure(Bootstrap.Client())
]==]

-- ===================================================================== layout ===

if not ReplicatedStorage:FindFirstChild("Trellis") then
	warn("[Setup] ReplicatedStorage.Trellis is missing. Run dist/Adeal.luau first.")
end

-- Shared: content trees plus the module tree
local Shared = folder(ReplicatedStorage, "Shared")

local Assets = folder(Shared, "Assets")
folder(Assets, "Interface")
folder(Assets, "Audio")
folder(Assets, "Models")
folder(Assets, "Builds")

local Classes = folder(Shared, "Classes")
local template = folder(Classes, "__NameOfClassFolder__")
folder(template, "__NameOfClass__")

local SharedModules = folder(Shared, "Modules")
folder(SharedModules, "Packages")
folder(SharedModules, "Services")
local SharedUtilities = folder(SharedModules, "Utilities")

-- Client: replicated, but only the client Bootstrap passes it
local Client = folder(ReplicatedStorage, "Client")
local ClientModules = folder(Client, "Modules")
folder(ClientModules, "Controllers")
folder(ClientModules, "Services")
folder(ClientModules, "Packages")
folder(ClientModules, "Utilities")

-- Server: never replicates
local ServerModules = folder(ServerStorage, "Modules")
folder(ServerModules, "Managers")
folder(ServerModules, "Services")
folder(ServerModules, "Packages")
folder(ServerModules, "Utilities")

-- ===================================================================== config ===

script_(SharedUtilities, "Bootstrap", "ModuleScript", BOOTSTRAP)

local Config = script_(SharedUtilities, "Config", "ModuleScript", CONFIG)
script_(Config, "Junction", "ModuleScript", JUNCTION)
script_(Config, "BootOrder", "ModuleScript", BOOTORDER)
script_(Config, "Registers", "ModuleScript", REGISTERS)
script_(Config, "Manifests", "ModuleScript", MANIFESTS)

-- ================================================================ entry points ===

script_(ServerScriptService, "ServerInit", "Script", SERVER_INIT)

local StarterPlayerScripts = StarterPlayer:FindFirstChild("StarterPlayerScripts")
if StarterPlayerScripts then
	script_(StarterPlayerScripts, "Init", "LocalScript", CLIENT_INIT)
else
	warn("[Setup] no StarterPlayerScripts; the client Init was not created")
end

-- ===================================================================== report ===

print(string.format("[Setup] created %d, kept %d", #made, #kept))

for _, path in made do
	print("  +  " .. path)
end
if #kept > 0 then
	print(string.format("  ... %d already there, left alone", #kept))
end

print([[

[Setup] done. Press Play: the boot should be silent, since nothing is declared yet.

  Junction   Shared/Modules/Utilities/Config/Junction     every event
  BootOrder  Shared/Modules/Utilities/Config/BootOrder    when modules start
  Registers  Shared/Modules/Utilities/Config/Registers    replicating caches
  Layout     Shared/Modules/Utilities/Bootstrap           where things live

Write a Manager in ServerStorage/Modules/Managers, a Controller in
ReplicatedStorage/Client/Modules/Controllers, and declare the events they use.]])
