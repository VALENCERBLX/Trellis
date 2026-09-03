--!nonstrict
-- Example: everything that lives in the Config bin.
-- In a real game these are three files: Config/Junction, Config/BootOrder,
-- Config/Registers. Configure finds them by name -- you never pass them.

-- ============================================ Shared/Modules/Config/Junction ===

local Junction = {}

Junction.Network = {
	Session = {
		Sync = {}, -- server -> all clients
		Update = { Destination = "SessionManager" },
		Get = { Kind = "Resolve", Destination = "SessionManager" },
	},

	Combat = {
		-- Declared shapes are checked at the edge, so no handler below needs a
		-- `if type(payload) ~= "table"` prologue.
		Swing = {
			Destination = "CombatManager",
			Schema = {
				Target = "Instance",
				Combo = { Type = "number", Min = 1, Max = 5 },
				Style = { Type = "string", One = { "Light", "Heavy" } },
			},
		},
		Hit = {}, -- no Destination: every subscriber in the domain
	},
}

Junction.Local = {
	-- A domain-level Defaults saves repeating the same field on every line, and
	-- makes the exceptions the lines that carry text.
	State = {
		Defaults = { Side = "Server" },
		Entered = {},
		Exited = {},
	},

	Animation = {
		Defaults = { Destination = "AnimationService" },

		Play = {}, -- requests INTO the service
		Stop = {},
		Check = { Kind = "Resolve" },

		MarkerReached = { Destination = "any" }, -- reports back OUT of it
		TrackEnded = { Destination = "any" },
	},

	Input = {
		Defaults = { Side = "Client" },
		Pressed = {},
		Released = {},
	},
}

-- A Fence names a set of events and, optionally, a per-player budget the framework
-- enforces for you. Targets may be a whole domain or a single event.
Junction.Fence = {
	Combat = { Events = { "Network.Combat" }, Rate = 20, Per = 1 },
}

-- =========================================== Shared/Modules/Config/BootOrder ===

local BootOrder = {
	-- WHEN. The array index is the priority; an inner array is one tier whose
	-- members have no guaranteed order among themselves. Only list what actually
	-- needs ordering -- anything absent boots last, with a warning naming it.
	Order = {
		{ "MemoryService", "SettingsService" },
		"SessionManager",
		{ "StateManager", "CombatManager", "AnimationService" },
		{ "InputController", "InterfaceController" },
	},

	-- HOW. Where a Req'd capability gets its parameters, so performance and policy
	-- are tuned here without opening a module.
	Config = {
		StateManager = { Hz = 20 },
		CombatManager = { Hz = 30, Fences = { "Combat" } },
		CameraController = { Hz = "Render" }, -- client only; errors on the server
		PickupService = { Tags = { "Pickup", "Chest" } },
	},
}

-- =========================================== Shared/Modules/Config/Registers ===

local Registers = {
	Session = {
		Replicate = "Owner", -- per player, only they receive it
		Persist = true, -- saved through Configure's Store backend
		Cats = {
			Stats = {},
			Settings = {},
			Inventory = { Dynamic = true }, -- arbitrary ids beneath
		},
		-- Who may WRITE each path. Anything unmatched is server-only: a cache
		-- anyone can write is not a cache.
		Policies = {
			["Stats.*"] = "Server",
			["Settings.*"] = "Owner",
		},
	},

	Round = { Replicate = "All", Cats = { Scores = {} } },
	Secrets = { Replicate = false }, -- never leaves the server
}

return { Junction = Junction, BootOrder = BootOrder, Registers = Registers }
