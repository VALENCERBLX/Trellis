# Trellis - design log

> The **README** is authoritative. This is the running record of *why* each decision
> went the way it did, kept because the reasoning is easy to lose and expensive to
> re-derive. Some early sections were superseded during the build; where they
> disagree with the README, the README is right.

# (placeholder name: <LIB> for the framework, <NET> for the networking lib)

STATUS: design, nothing built. Successor to Junky (SSJA) / the Fantasy Arena Network lib.

## Pillars
1. Single Bootstrap per side (Configure).
2. Registry - DI whose Get* surface is DERIVED from the hierarchy you hand it.
3. Junction - declared routing map, transport stated not inferred.
4. Src - the bus surface (Post/Subscribe/Resolve/Respond), scoped per domain.
5. Reg - global cache, replicating over the Junction.

## 2. Registry - derived getters
Root.Packages.X  ==  Root:GetPackage("X")
Root["Get" .. singular(binName)] = function(_, n) return resolve(bin, n) end

- one bin per DIRECT child container of every root (no descent -> Packages/Icon/Packages
  is Icon's private business, and the two-Lume collision can't happen)
- singular(): ies->y, ches->ch, shes->sh, xes->x, ([^s])s->%1, else unchanged (Config->GetConfig)
- Aliases = { Utility = "Utilities" } for irregulars
- bin sources: Folder (require children) | table (Inject) | resolver fn
- collisions across roots = BOOT ERROR naming both full paths
- eager require for lifecycle bins (Controller/Manager/Service); lazy+cached for passive
  bins (Package/Utility/Config)
- entries register under full + suffix-stripped name (CombatService and Combat)
- missing bin -> __index error listing the bins that DO exist on this side
- COST: Luau can't type generated methods -> ship `lune run scripts/types` codegen
  emitting GetService("Combat"): CombatService

## 3. Junction
Shape: Junction.<Namespace>.<Domain>.<Event>   (Namespace: Network | Local | Fence) = { entry }
Namespace: Local | Network        Kind: Static (Event) | Resolve (Function)

	class = (namespace == "Local" and "Bindable" or "Remote") .. KIND[entry.Kind]

	          | Kind="Static"  | Kind="Resolve"
	Local     | BindableEvent  | BindableFunction
	Network   | RemoteEvent    | RemoteFunction

### Entry fields / defaults
	Kind        default "Static"
	Destination default none = no filter (explicit opt-out from an inherited one: "any")
	Side        default both  ("Server" | "Client")
	Instanced   default false for Local (see below)

### Domain-level Defaults (reserved key)
	State = { Defaults = { Side = "Server" }, Entered = {}, Exited = {}, ... }
	Animation = { Defaults = { Destination = "AnimationService" },
	              Play = {}, Stop = {},
	              MarkerReached = { Destination = "any" } }
"Defaults" is the only reserved key; no event may be named Defaults.

### Materialization
Build the instance tree from the map at boot, mirroring the nesting:
	ReplicatedStorage/Junction/<Domain>/<Event>   (Network only; server creates, client waits)
Why one instance per entry rather than one multiplexed remote:
  - channel string leaves the wire
  - a RemoteFunction has exactly ONE OnServerInvoke -> multiplexing forces a hand-rolled
    responder dispatch (Network/init.luau:66). Per-entry instances delete it and make
    "two modules answered the same event" a boot error.
  - Studio Explorer shows live topology; microprofiler labels per event
  - typo'd event can't reach runtime

### Local entries: plain-Lua signals by default
BindableEvent:Fire(t) SERIALIZES - deep copy, metatables stripped, mixed keys mangled.
A Local event carrying a Moody machine / Accede thenable breaks silently.
So Local = plain-Lua signal (same surface, faster, keeps identity); Instanced = true
per entry when you want the Explorer node or a third-party hookup.
Local Kind="Resolve" as a real BindableFunction buys nothing - it's a sync call + tax.

## 4. Src - the bus
	local Input = Src:Local("Input")
	Input:Post("Pressed", key)
	Input:Subscribe("Pressed", fn)     --> unsubscribe

	local Session = Src:Network("Session")
	Session:Post("Update", payload)          -- client->server, or server->all
	Session:PostTo(player, "Sync", state)    -- server->one
	Session:Resolve("Get", q):Next(fn)       -- Kind = "Resolve"
	Session:Respond("Get", fn)

- scope object binds {namespace, domain} and validates event names AT BIND TIME
- Src.From = sending Player on remote inbound, nil on local/internal.
  nil == trusted/internal. Same shape in every handler regardless of transport.
- Destination is a DELIVERY FILTER, not a direction. Direction = who called Post.
- subscribing to a Destination-filtered event you don't own = warn naming both modules
  (silent non-delivery is a miserable bug)

### Boot validation
	- Local entry Destination naming no module on this side          -> error (typo)
	- Network Destination ending "Controller" absent from client reg -> error
	- Network Destination ending "Manager" absent from server reg    -> error
	- verb/Kind mismatch (Post on Resolve, Resolve on Static)        -> error
	- two Respond on one Resolve entry                               -> error
	- Registry name collision across roots                           -> error
Server publishes its module-name set at handshake so the client can validate Network
destinations too - closes the hole Junky admits to in Bootstrap.lua:78.

## 4b. What is injected into Controllers / Managers / Services
Injection is a privilege of the three ROLES. Package/Utility/Config modules get nothing -
they are plain modules pulled through the derived getters.

Delivery: installed onto the module table via __index BEFORE :Start, AND passed as the
:Start argument. Available in every method, not just :Start - kills the `self._ctx = ctx`
boilerplate. Reserved keys; a module defining one is a boot error.

### Common to all three
	self.Name      "CombatManager"        the module's own name (Junky's `Source`)
	self.Role      "Manager"              from the suffix
	self.Side      "Server" | "Client"
	self.Src       the bus + Src:Reg
	Src.Main       the hierarchy as written: Main.Packages.Lume == :GetPackage("Lume")
	self:Await(key)
	self:OnCleanup(fn)
	self:Get<Bin>(name)                   every bin present on THIS side

### Client only
	self.Player    LocalPlayer            (nil on the server - no single player there)

### Role shape is not special-cased
A Controller has no :GetManager because the client roots have no Managers folder.
The role-appropriate surface falls out of the hierarchy + the registry, not from a table
of per-role rules. Calling a missing bin errors naming the bins that DO exist here.

### Pre-bound domain scopes
Because Domain is derived from the name, a module talking on its own domain is free:

	function CombatManager:Start()
		self.Network:Subscribe("Swing", function(hit) ... end)   -- Junction.Network.Combat.Swing
		self.Local:Post("Hit", result)                           -- Junction.Local.Combat.Hit
		local Combat = self:GetService("Combat")                 -- sanctioned same-domain call
	end

Cross-domain still explicit: self.Src:Local("Animation"):Post("Play", ...)

### OPEN
	- Counterpart: CombatController <-> CombatManager are a known pair (same Domain,
	  opposite roles). Could default a Network entry's Destination to the counterpart.
	  Clever, maybe too magic.
	- Should structural Reg ops (New/Swap/Rem) be Service-only, with Controllers/Managers
	  limited to Get/Watch/Edit? Enforces "Services own state" - opinionated.

## 5. Reg - global cache   (accessed ONLY via Src:Reg; never pre-bound to a module)
A TREE, not a flat store. Cat = CATEGORY.

	Registers = {
		Session = {
			Replicate = "Owner",              -- "Owner" | "All" | false
			Cats = {
				Stats     = {},
				Inventory = { Dynamic = true },  -- arbitrary ids created beneath
			},
			Policies = {                       -- path -> who may write
				["Stats.*"]    = "Server",
				["Settings.*"] = "Owner",
			},
		},
		Round   = { Replicate = "All" },
		Secrets = { Replicate = false },
	}
Declared, not conjured. Src:Reg("Undeclared") errors listing the declared ones.
Owner registers: server Src:Reg("Session", player); client Src:Reg("Session") = yours.
Owner registers drop on player leave.

### Surface
	Reg:New(path, value)          create; error if exists
	Reg:Edit(path, patch)         merge patch      [dot path]
	Reg:Swap(path, value)         replace wholesale, returns old
	Reg:Cat(name)                 scope into / create a sub-category -> a Reg with the
	                              same surface rooted there. Symmetric with Src:Local(domain).
	Reg:Rem(path)                 delete
	Reg:Access(path)              read             [dot path] synchronous, local mirror
	Reg:Bubble(path, fn)          fn(value, path, op)

### The rule that makes Cat load-bearing
ONLY Cat creates a category. Access/Edit TRAVERSE existing ones and error on an
unresolved path, naming the failed segment + listing real siblings. Otherwise
Reg:Edit("Comabt.Health", 5) silently grows a phantom branch = bag-of-strings.
Declared Cats are scoped into; only a Dynamic category creates on Cat(name).
KEYS MAY NOT CONTAIN A DOT - validated in New and Cat.

### Deltas are path-shaped
	{ Op = "Edit", Reg = "Session", Path = "Stats.Health", Value = 92 }
Mutations replicate (New/Edit/Swap/Rem/Cat-create); reads never do.
Path-shaped deltas -> per-path Policies = Manifests.Session.Policies + PrefixPolicies
from Fantasy Arena, promoted into the framework.

### Bubble
Reg:Bubble(path, fn) subscribes. A change notifies the exact path AND every ancestor
category, so a watcher on "Stats" fires for "Stats.Health". Handler gets
(value, path, op) so a subtree watcher can tell WHERE it happened.

### Authority + uniformity
Client mutation = REQUEST: validated server-side against Policies, echoed back as the
authoritative delta. ALL MUTATION VERBS RETURN A THENABLE on both sides (already-resolved
on the server) - otherwise a side-split Service can't move sides without a rewrite.
No optimistic local write by default:
	Reg:Edit(path, patch, { Predict = true })   -- applies locally, rolls back if refused

## What this deletes vs Junky
	Router.lua destination machinery  -> the map materializes instead
	Network.lua envelope {d,n,to,a}   -> per-entry instances, no envelope
	Substance dependency
	ClassPriorityMap + StandalonePriorityMap -> [OPEN] Module.Needs = {...} + toposort?
	hand-written GetPackage/GetUtility/GetService -> derived from the hierarchy

## 6. Lifecycle, BootOrder, Req
Hooks: :Start() and :Stop(). No :Init phase.

### BootOrder - replaces ClassPriorityMap + StandalonePriorityMap
ONE map. The ARRAY INDEX is the boot order - no tier numbers to renumber on insert.
	return {
		"MemoryService",
		"SessionManager",
		{ "StateManager", Hz = 20 },
		{ "CombatController", Hz = 30 },
		"AnimationController",
	}
Bare string or table-with-config. Modules absent boot last with a warning.

### Module.Req - CAPABILITIES, not dependencies
Ordering is BootOrder's job. Req declares what gets INSTALLED on the module.

RULE FOR WHAT EARNS A Req: it costs something at runtime, or needs per-deployment
config. A hook that is merely called once if defined costs nothing when absent and
must NOT need declaring.

Plain optional hooks, no Req:
	:Start()   :Stop()
	:Ready()   -- after EVERY module has started. The half of :Init worth keeping:
	              "everything is up now" is the timing question modules actually have.

	Req       Grants                                    BootOrder config   Side
	Heart     :Heartbeat(dt)                            Hz                 both
	Fence     :Fence(event, payload, from)              Fences = {"Combat"} both
	Player    :PlayerAdded(p) / :PlayerRemoving(p)      -                  SERVER
	Tag       :TagAdded(inst) / :TagRemoved(inst)       Tags = {"Pickup"}  both
	Timer     self:Delay(t,fn) self:Every(t,fn)         -                  both
	Trove     self.Trove (destroyed on :Stop)           -                  both
	Profile   hooks wrapped in debug.profilebegin(Name) -                  both

SYMMETRY: Req = the module saying what it needs. BootOrder = the deployment saying
how much of it. Tag follows Heart exactly (module declares it works on tagged
instances; config declares which tags).

REJECTED: Render/Step (now Hz VALUES, not Reqs) · Body (assumes Humanoid characters;
CollectionService is universal, characters are not) · Memory · persistence (a Service's
job) · input binding (too client-specific) · logging (costs nothing -> base surface).

Validation:
	- Hz = "Render" on a Manager -> boot error (client-only driver)
	- Req "Heart" without :Heartbeat defined -> boot error
	- :Heartbeat defined without Req "Heart" -> warning (dead code, never called)

Player BACKLOG REPLAY: a module booting after players joined misses PlayerAdded
entirely - a bug that only shows on live servers, never in Studio. Replay
Players:GetPlayers() through the handler at install time.
Timer LIFETIME BINDING: task.delay firing into a torn-down module is the most common
Roblox leak; capability-granted timers cancel on :Stop, so it can't happen.

### Hz - declared in BootOrder, not in the module
The module says it needs a heartbeat; the DEPLOYMENT says how fast and what drives it.
	{ "StateManager",     Hz = 20 }         throttled, accumulated dt
	{ "CameraController", Hz = "Render" }   PreRender / RenderStepped, CLIENT only
	{ "PhysicsManager",   Hz = "Step" }     PreSimulation / Stepped
	"VfxController"                          default: every Heartbeat
Same hook name (:Heartbeat) whatever the driver - retargeting is one word in one file.
	- ONE RunService connection per driver for the whole app; the scheduler dispatches.
	- STAGGERED PHASES: offset each accumulator so N modules at Hz=10 spread across
	  frames instead of spiking together every 6th frame. Only the scheduler sees all N.
	- dt on a throttled :Heartbeat is ACCUMULATED time since its last call, not the
	  frame delta - integration stays correct at any Hz.

## Open - decide before code
	1. FENCE GRANULARITY: does a Fence list EVENTS or wrap a whole DOMAIN?
	2. CONFIGURE PAYLOAD: exact config table shape.
	3. NAMES + home under Ker/ (proposed: Trellis = framework, Conduit = networking).

## 7. Fence - Guards, declared  (the veto is a FENCE; the word "gate" is not used)
Junction.Fence is the THIRD top-level category, beside Network and Local.
	Junction.Fence = {
		Combat  = { "Network.Combat.Swing", "Network.Combat.Block" },
		Economy = { "Network.Shop.Purchase" },
	}
	CombatManager.Req = { "Fence" }
	function CombatManager:Fence(event, payload, from) -> boolean, reason? end
	-- BootOrder: { "CombatManager", Fences = { "Combat" } }

USUALLY THE DOMAIN OWNER FENCES ITS OWN DOMAIN - the module that knows what a valid
Swing looks like is CombatManager. A separate module only earns its place for
cross-cutting concerns (one rate limiter fencing Combat + Economy + Chat).

Same Req/BootOrder split as Heart/Hz and Tag/Tags.
	- the fence runs on the RECEIVING side. For Network that means server-side; a client
	  gating its own outbound traffic is worthless for security.
	- MANY modules may fence one Fence; ALL must pass. That is how layered validation
	  gets written (a rate-limit module + a sanity module, neither knowing the other).
	- :Fence returns false, reason -> rejects the sender's Resolve, or warns on a Post.
	- a Fence naming an event that does not exist = boot error.

REPLACES Junky's Guards, and is strictly better: Junky registered guards ad-hoc at the
call site, so nothing could tell you what was guarded without grepping. A Fence is
declared in the map, so the Junction shows every fenced event and who watches it.

## Built
	- Registry.luau + test-registry.luau - 32/32 under Lune. Derived getters, Src.Main
	  (frozen, lazy, iterable), no-descent, collision errors, suffix aliasing,
	  lazy+cached, Preload, resolver bins.
	- Scheduler.luau + test-scheduler.luau - 18/18. Hz throttling, TWO counters (rate
	  vs dt), golden-ratio phase staggering (12 modules @ Hz=10 -> busiest frame 3),
	  lag-spike clamp, per-driver lists, client-only Render guard, error isolation.
	- examples.luau - one module per Req.

## Settled
	- Src IS the injected context (not a field on it); mirrored onto the module
	- NO Src.Domain - every bus call names its domain explicitly
	- `from` is a HANDLER PARAMETER (payload, from), never a field: a per-module Src.From
	  slot is overwritten across yields, and it is the field authority is gated on
	- Fence replaces Guards; there is no "Gate" - the thing is a Fence
	- thenables are PascalCase (:Next/:Toss/:Await) -> Accede needs aliases (non-breaking)
	- Cat = Category (a tree), Get -> Access, Watch -> Bubble, dot paths on Access/Edit
	- Reg reached only via Src:Reg

## Notes on the real Fantasy Arena map
	- Session.Get, Contract.List, Contract.Accept read as requests -> need Kind = "Resolve"
	- Animation.AnimationKeyframeReached stutters under the scope: rename KeyframeReached
	- State (6x Side="Server") and Input (3x Side="Client") collapse under Defaults
