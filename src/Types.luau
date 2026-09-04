--!strict
-- Trellis
-- Types.luau
-- Valence
--
-- The shared type surface. Nothing here executes; it exists so Controllers,
-- Managers and Services can annotate against one Src type, and so the runtime
-- modules agree on the shape of a config, an entry and a delta.
--
-- The generated getters (:GetPackage, :GetService, ...) cannot be typed here --
-- they are derived from YOUR hierarchy at boot. `lune run scripts/types` walks the
-- tree and emits a companion file that declares them concretely; this module keeps
-- the open-ended index so untyped code still checks.

export type Side = "Server" | "Client"
export type Role = "Controller" | "Manager" | "Service"

-- ==================================================================== registry ===

export type RegistryConfig = {
	-- A table extends that bin; a function makes the bin a resolver.
	Inject: { [string]: any }?,
	-- Irregular plurals the singularizer cannot guess: { Utility = "Utilities" }
	Aliases: { [string]: string }?,
}

export type Registry = {
	-- The hierarchy exactly as you wrote it: Main.Packages.Lume == :GetPackage("Lume")
	Main: { [string]: { [string]: any } },

	Resolve: (self: Registry, bin: string, name: string, optional: boolean?) -> any,
	Bins: (self: Registry) -> { string },
	Names: (self: Registry, bin: string) -> { string },
	Preload: (self: Registry, bin: string) -> { [string]: any },

	Claims: (self: Registry, bin: string, name: string) -> { any }?,
	ClaimedNames: (self: Registry, bin: string) -> { string },
	Reconcile: (self: Registry, bin: string, name: string, value: any) -> (),
	Load: (self: Registry, entry: any) -> any,

	-- Get<Bin> / Has<Bin> / List<Bin>, generated per bin found in the hierarchy.
	[string]: any,
}

-- ==================================================================== junction ===

export type Kind = "Static" | "Resolve"
export type Namespace = "Network" | "Local" | "Fence"

-- A field may be set per entry, or inherited from the domain's `Defaults` table.
-- Destination = "any" explicitly clears an inherited Destination.
export type JunctionEntry = {
	Kind: Kind?,
	Destination: string?,
	Side: Side?,
	Instanced: boolean?,
	Schema: Schema?,
}

export type ParsedEntry = {
	Path: string,
	Namespace: string,
	Domain: string,
	Event: string,
	Kind: string,
	Class: string, -- RemoteEvent | RemoteFunction | BindableEvent | BindableFunction
	Destination: string?,
	Side: Side?,
	Instanced: boolean,
	Schema: Schema?,
}

export type FenceSpec = {
	Events: { string },
	Rate: number?, -- calls allowed per player
	Per: number?, -- ...within this many seconds (default 1)
}

-- A Fence is either a plain list of targets or a table with a rate budget.
export type JunctionMap = {
	Network: { [string]: { [string]: JunctionEntry } }?,
	Local: { [string]: { [string]: JunctionEntry } }?,
	Fence: { [string]: { string } | FenceSpec }?,
}

-- ====================================================================== schema ===

-- A payload shape, checked at the edge before any handler or fence runs.
--   "number" | "string" | "boolean" | "table" | "Instance" | "Vector3" | ...
--   { Type = "number", Min = 0, Max = 100 }
--   { Type = "table", Of = { ... } }          nested
--   { Type = "string", One = { "A", "B" } }   enumerated
--   append "?" to a type string to make it optional
export type Schema = { [string]: string | { [string]: any } } | string

-- =================================================================== bootorder ===

export type ModuleConfig = {
	Hz: (number | "Render" | "Step")?,
	Tags: { string }?,
	Fences: { string }?,
	Persist: boolean?,
}

export type BootOrder = {
	-- Ascending tiers. A string is its own tier; an array is one tier whose members
	-- have no guaranteed order among themselves.
	Order: { string | { string } },
	Config: { [string]: ModuleConfig }?,
}

-- =================================================================== registers ===

export type RegisterSpec = {
	Replicate: ("All" | "Owner" | false)?,
	Cats: { [string]: any }?,
	Policies: { [string]: "Server" | "Owner" }?,
	Persist: boolean?,
	Schema: Schema?,
}

export type Delta = {
	Op: "New" | "Edit" | "Swap" | "Rem" | "Cat",
	Reg: string,
	Owner: any?,
	Path: string,
	Value: any?,
}

export type Register = {
	New: (self: Register, path: string, value: any) -> Reaction,
	Edit: (self: Register, path: string, patch: any, options: MutateOptions?) -> Reaction,
	Swap: (self: Register, path: string, value: any, options: MutateOptions?) -> Reaction,
	Rem: (self: Register, path: string, options: MutateOptions?) -> Reaction,
	Cat: (self: Register, name: string) -> Register,
	Access: (self: Register, path: string) -> any,
	Bubble: (self: Register, path: string, handler: (any, string, string) -> ()) -> () -> (),
}

export type MutateOptions = {
	-- Apply locally at once and roll back if the server refuses. Off by default:
	-- silent rollback is worse than a frame of latency for most things.
	Predict: boolean?,
}

-- ==================================================================== reaction ===

export type Reaction = {
	State: "Pending" | "Done" | "Failed",
	Value: any,

	Next: (self: Reaction, handler: (any) -> ()) -> Reaction,
	Toss: (self: Reaction, handler: (any) -> ()) -> Reaction,
	Catch: (self: Reaction, handler: (any) -> ()) -> Reaction,
	Conclude: (self: Reaction, handler: (any) -> ()) -> Reaction,
	Map: (self: Reaction, transform: (any) -> any) -> Reaction,
	Timeout: (self: Reaction, seconds: number, reason: string?) -> Reaction,
	Cancel: (self: Reaction, reason: string?) -> Reaction,
	Await: (self: Reaction) -> any,
}

-- ========================================================================= bus ===

-- A handler always receives (payload, from). `from` is the sending Player, or nil
-- when the event originated on this side. A nil therefore means trusted.
export type Handler = (payload: any, from: any?) -> ()
export type Responder = (payload: any, from: any?) -> any

export type Scope = {
	Post: (self: Scope, event: string, payload: any?) -> (),
	Subscribe: (self: Scope, event: string, handler: Handler) -> () -> (),
	Once: (self: Scope, event: string, handler: Handler) -> () -> (),
	Resolve: (self: Scope, event: string, payload: any?) -> Reaction,
	Respond: (self: Scope, event: string, handler: Responder) -> () -> (),

	-- Network scopes only.
	PostTo: (self: Scope, player: any, event: string, payload: any?) -> (),
	PostAll: (self: Scope, event: string, payload: any?) -> (),
	PostExcept: (self: Scope, player: any, event: string, payload: any?) -> (),
	ResolveFrom: (self: Scope, player: any, event: string, payload: any?) -> Reaction,
}

-- Service to Service, on this side, directly. The verbs are the REST methods and
-- nothing else, so a Service's surface to its peers is seven names.
export type Channel = {
	Get: (self: Channel, route: string?, payload: any?) -> any,
	Post: (self: Channel, route: string?, payload: any?) -> any,
	Put: (self: Channel, route: string?, payload: any?) -> any,
	Patch: (self: Channel, route: string?, payload: any?) -> any,
	Delete: (self: Channel, route: string?, payload: any?) -> any,
	Head: (self: Channel, route: string?, payload: any?) -> any,
	Options: (self: Channel, route: string?, payload: any?) -> any,
}

export type Src = {
	Name: string,
	Role: string,
	Side: Side,
	Player: any?,
	Main: { [string]: { [string]: any } },

	Local: (self: Src, domain: string) -> Scope,
	Network: (self: Src, domain: string) -> Scope,
	Reg: (self: Src, register: string, owner: any?) -> Register,

	-- Services only, and only to another Service on this side.
	Channel: (self: Src, service: string) -> Channel,
	Deploy: (self: Src, worker: string, target: any) -> boolean,
	Recall: (self: Src, worker: string, target: any) -> boolean,
	Await: (self: Src, path: string) -> Reaction,
	OnCleanup: (self: Src, fn: (() -> ()) | any) -> (),
	Inspect: (self: Src) -> any,

	-- Granted by Req only.
	Trove: any?,
	Delay: (self: Src, seconds: number, fn: () -> ()) -> any,
	Every: (self: Src, seconds: number, fn: () -> ()) -> any,
	Cancel: (self: Src, handle: any) -> (),

	-- Generated getters, derived from the hierarchy.
	[string]: any,
}

-- ================================================================== the module ===

-- What you write. Every hook is optional except :Start on a Controller/Manager.
export type Module = {
	Req: { string }?,

	Start: ((self: any, Src: Src) -> ())?,
	Stop: ((self: any) -> ())?,
	Ready: ((self: any) -> ())?,

	Heartbeat: ((self: any, dt: number) -> ())?, -- Req "Heart"
	PlayerAdded: ((self: any, player: any) -> ())?, -- Req "Player"
	PlayerRemoving: ((self: any, player: any) -> ())?, -- Req "Player"
	TagAdded: ((self: any, instance: Instance, tag: string) -> ())?, -- Req "Tag"
	TagRemoved: ((self: any, instance: Instance, tag: string) -> ())?, -- Req "Tag"
	Fence: ((self: any, event: string, payload: any, from: any?) -> (boolean, string?))?,

	-- Channel handlers, on a Service. Each takes (route, payload, from), where
	-- `from` is the calling Service's name.
	Get: ((self: any, route: string?, payload: any?, from: string?) -> any)?,
	Post: ((self: any, route: string?, payload: any?, from: string?) -> any)?,
	Put: ((self: any, route: string?, payload: any?, from: string?) -> any)?,
	Patch: ((self: any, route: string?, payload: any?, from: string?) -> any)?,
	Delete: ((self: any, route: string?, payload: any?, from: string?) -> any)?,
	Head: ((self: any, route: string?, payload: any?, from: string?) -> any)?,
	Options: ((self: any, route: string?, payload: any?, from: string?) -> any)?,

	-- A double-sided Service: __Serve returns the client half, run BY the client.
	__Serve: ((self: any) -> Module)?,
	__Recip: ((self: any, served: Module) -> ())?,

	[string]: any,
}

-- ==================================================================== configure ===

export type Config = {
	Hierarchy: { Instance },

	-- Found in the Config bin by name when omitted.
	Junction: JunctionMap?,
	BootOrder: BootOrder?,
	Registers: { [string]: RegisterSpec }?,

	Inject: { [string]: any }?,
	Aliases: { [string]: string }?,

	-- Diagnostics.
	Log: (boolean | number)?, -- keep the last N events per path (true = 64)
	Panel: boolean?, -- build the live Inspect panel (client)
	Profile: boolean?, -- profile every module, not just those with Req "Profile"

	-- Persistence backend for registers declared Persist = true.
	Store: PersistBackend?,
}

export type PersistBackend = {
	Load: (key: string) -> any,
	Save: (key: string, value: any) -> (),
	Release: ((key: string) -> ())?,
}

export type App = {
	Side: Side,
	Src: Src,
	Order: { string },

	Get: (self: App, name: string) -> any,
	List: (self: App, role: string) -> { string },
	Inspect: (self: App) -> any,
	Stop: (self: App) -> (),
	Restart: (self: App) -> App,
}

return {}
