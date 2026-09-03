<div align="center">

# Trellis

**A subset of Single Script Architecture for Roblox.**
The hierarchy you hand it *is* the API. Every event is declared. Everything expensive is opt-in.

<img src="https://img.shields.io/badge/Trellis-v0.1.0-3EA6A6?style=for-the-badge" alt="version" />
<img src="https://img.shields.io/badge/Luau-Roblox-00A2FF?style=for-the-badge" alt="luau" />
<img src="https://img.shields.io/badge/tests-308-22c55e?style=for-the-badge" alt="tests" />
<img src="https://img.shields.io/badge/License-MIT-666?style=for-the-badge" alt="license" />
<img src="https://img.shields.io/badge/Plinko%20Labs-Built%20By-e11d48?style=for-the-badge" alt="plinko labs" />

</div>

---

## The whole Bootstrap

```lua
local Trellis = require(ReplicatedStorage.Packages.Trellis)

local app = Trellis.Configure({
	Hierarchy = {
		ReplicatedStorage.Shared.Modules,   -- Packages, Utility, Config, Services
		ServerScriptService.Server,         -- Managers, server Services
	},
})
```

That's the entire server entry point. The client is the same call with its own root. `Junction`, `BootOrder` and `Registers` are found in the `Config` bin **by name** — because the registry already derived that bin from your tree, there is nothing left to hand it separately.

---

## Five pillars

| | |
|---|---|
| **Registry** | Dependency injection whose surface is *derived* from your hierarchy. |
| **Junction** | Every event declared once: namespace, kind, destination, schema. |
| **Src** | The only surface a module talks through. |
| **Reg** | A replicating register tree with declared authority. |
| **Capabilities** | `Req` — a module asks for what costs something; `BootOrder` tunes it. |

---

## 1 · The hierarchy is the API

Every direct child folder of every root becomes a **bin**, and every bin generates its own getter from the singular of its name:

```
Shared/Modules/
  Packages/     ->  Src:GetPackage("Lume")     ==  Src.Main.Packages.Lume
  Utility/      ->  Src:GetUtility("Maid")     ==  Src.Main.Utility.Maid
  Config/       ->  Src:GetConfig("Manifests")
  Services/     ->  Src:GetService("Combat")
```

Add a `Config/` folder and `:GetConfig` appears. No registration, no framework change.

- **Only direct children are scanned**, so `Packages/Icon/Packages` stays Icon's private business and can never collide with yours.
- **A name mounted twice is a boot error** naming both full paths — never a silent `FindFirstChild` win.
- **Entries resolve under both names**: `GetService("Combat")` and `GetService("CombatService")`.
- **Role shape is not special-cased.** A Controller has no `:GetManager` because the client roots have no `Managers/` folder. Calling a bin that isn't there errors naming the bins that are.

Luau can't type generated methods, so that cost is paid once by codegen:

```sh
lune run scripts/types -- src/Shared/Modules src/Server --out src/Shared/Modules/Config/Generated.luau
```

```lua
function CombatManager:Start(Src: Generated.Src) end   -- :GetService( now autocompletes
```

---

## 2 · The Junction

```lua
Junction.Network = {
	Combat = {
		Swing = {
			Destination = "CombatManager",
			Schema = { Combo = { Type = "number", Min = 1, Max = 5 } },
		},
		Hit = {},
	},
	Session = {
		Get = { Kind = "Resolve", Destination = "SessionManager" },
	},
}

Junction.Local = {
	State = {
		Defaults = { Side = "Server" },
		Entered = {}, Exited = {},
	},
	Animation = {
		Defaults = { Destination = "AnimationService" },
		Play = {}, Stop = {},
		MarkerReached = { Destination = "any" },   -- opts out of the inherited one
	},
}

Junction.Fence = {
	Combat = { Events = { "Network.Combat" }, Rate = 20, Per = 1 },
}
```

Two words cover four transports:

| | `Kind = "Static"` | `Kind = "Resolve"` |
|---|---|---|
| **`Junction.Local`** | BindableEvent | BindableFunction |
| **`Junction.Network`** | RemoteEvent | RemoteFunction |

**Entries materialize into real instances** mirroring the map's nesting — `ReplicatedStorage/Junction/Combat/Swing`. The server creates them, the client waits for the same paths. The channel name leaves the wire, every RemoteFunction gets its own `OnServerInvoke` instead of a hand-rolled dispatch, and Studio's Explorer shows your live topology.

**Local entries are plain-Lua signals** by default. `BindableEvent:Fire` deep-copies its arguments — metatables stripped, mixed keys mangled — which silently breaks any payload carrying a class instance or a thenable. Set `Instanced = true` on an entry when you actually want the Explorer node.

**Defaults inherit per domain.** `Defaults = { Side = "Server" }` reaches every entry; a per-entry field overrides; `Destination = "any"` clears an inherited one. The exceptions become the lines that carry text.

---

## 3 · Src

```lua
function CombatManager:Start(Src)
	Src:Network("Combat"):Subscribe("Swing", function(payload, from)
		if not from then return end        -- nil means internal, therefore trusted
		self:Apply(from, payload)
	end)

	Src:Network("Session"):Respond("Get", function(payload, from)
		return Src:Reg("Session", from):Access("Stats.Health")
	end)

	Src:Local("Round"):Post("Began", { round = 1 })
end
```

| | |
|---|---|
| Identity | `Src.Name` `Src.Role` `Src.Side` `Src.Player` `Src.Main` |
| Bus | `:Local(domain)` `:Network(domain)` |
| Static | `:Post` `:Subscribe` `:Once` — plus `:PostTo` `:PostAll` `:PostExcept` on Network |
| Resolve | `:Resolve` `:Respond` — plus `:ResolveFrom(player, …)` on the server |
| Cache | `:Reg(name)` `:Reg(name, player)` |
| Timing | `:Await(path)` `:OnCleanup(fn)` `:Inspect()` |
| By `Req` only | `Src.Trove` `:Delay` `:Every` `:Cancel` |

`Src` is mirrored onto the module, so everything is reachable from every method, not just `:Start`. The framework's keys are reserved — a module defining `Main` or `Local` is a boot error, never a silent shadow.

**`from` is always the second parameter, never a field.** `Src` is a per-module singleton, so a shared `From` slot would be overwritten by the next event whenever a handler yields — and it is the value authority is gated on.

### At the edge

Inbound payloads clear three gates before any handler sees them, cheapest first:

1. **Rate** — the per-player budget the Fence declared. First deliberately: a flood of *malformed* payloads is exactly what a rate limit exists to stop, so validating first would exempt garbage from the budget.
2. **Schema** — declared on the entry. Malformed traffic dies here, naming the offending field.
3. **Fences** — your own predicates. Many modules may fence one event and all must pass, so a shape check and a rate limiter coexist without knowing about each other.

```lua
CombatManager.Req = { "Fence" }

function CombatManager:Fence(event, payload, from)
	if not from then return true end
	return self:InRange(from, payload.Target), "range"
end
```

Usually the **domain owner fences its own domain** — the module that knows what a valid `Swing` looks like is `CombatManager`. A separate module earns its place only for cross-cutting concerns, like one rate limiter over `Combat`, `Economy` and `Chat`.

---

## 4 · Reg

```lua
Registers = {
	Session = {
		Replicate = "Owner",
		Persist = true,
		Cats = { Stats = {}, Inventory = { Dynamic = true } },
		Policies = { ["Stats.*"] = "Server", ["Settings.*"] = "Owner" },
	},
	Round = { Replicate = "All" },
	Secrets = { Replicate = false },
}
```

```lua
local Reg = Src:Reg("Session", player)

Reg:New("Stats.Health", 100)      Reg:Access("Stats.Health")
Reg:Edit("Stats", { Mana = 5 })   Reg:Bubble("Stats", fn)
Reg:Swap("Stats.Health", 50)      Reg:Rem("Stats.Health")
local Bag = Reg:Cat("Inventory")  -- scopes in, like Src:Local(domain)
```

**A tree, not a flat store.** `Cat` is *category*, and it is the **only** thing that creates one. `Access` and `Edit` traverse existing categories and throw on a path that doesn't resolve, naming the failed segment and listing its real siblings — so a typo'd write can't grow a phantom branch. A missing *value* still reads as `nil`; a missing *category* is a structural error.

**`Edit` merges, `Swap` replaces.** `Edit` recurses, so keys you didn't mention survive. You cannot delete a field with `Edit` — a `nil` in a Lua table isn't a key at all — so use `Swap` or `Rem`.

**The five mutation verbs are the replication protocol.** Each is a path-shaped delta `{ Op, Reg, Owner, Path, Value }`. Reads never leave the local mirror, which is why `Access` and `Bubble` sit outside that set.

**Authority is deny-by-default.** A client mutation is a *request*: the server checks the path against `Policies` and echoes the authoritative delta. A path matching no policy is server-only. Every verb returns a thenable on **both** sides, so a side-split Service can move sides without a rewrite.

```lua
Reg:Swap("Settings.Volume", 8, { Predict = true })   -- applies now, rolls back if refused
```

**`Bubble` bubbles.** A watcher on `"Stats"` fires for `"Stats.Health"` and is handed `(value, path, op)`.

**`Persist = true`** saves through a backend you supply (`Configure{ Store = … }`), flushes on player leave and on `app:Stop`, and hydrates on rejoin. Only values are stored, so the declared `Cats` shape is always the current one.

---

## 5 · Capabilities

A module declares what it needs; the deployment says how much of it. `Req` is only for things that **cost something at runtime or need configuration** — a hook that's merely called once if defined costs nothing when absent and needs no declaring.

| `Req` | Installs | Configured by |
|---|---|---|
| `Heart` | `:Heartbeat(dt)` | `Hz` |
| `Player` | `:PlayerAdded` / `:PlayerRemoving` (server) | — |
| `Tag` | `:TagAdded` / `:TagRemoved` | `Tags` |
| `Fence` | `:Fence(event, payload, from)` | `Fences` |
| `Timer` | `Src:Delay` `:Every` `:Cancel` | — |
| `Trove` | `Src.Trove` | — |
| `Profile` | every hook wrapped in `debug.profilebegin` | — |

No `Req` needed: `:Start(Src)`, `:Stop()`, and `:Ready()` — which runs after *every* module has started.

```lua
local StateManager = {}
StateManager.Req = { "Heart", "Trove" }

function StateManager:Start(Src)
	self.Trove:Add(workspace.ChildAdded:Connect(fn))   -- no :Stop needed
end

function StateManager:Heartbeat(dt) end                -- rate lives in BootOrder
```

**`Player` and `Tag` replay their backlog** at install: players who joined and instances already tagged before the module booted go through the same handler. Without that, a module that boots late misses them entirely — a bug that only shows on a live server.

**Timers are lifetime-bound.** They ride the scheduler's clock, not `task.delay`, so they cancel on `:Stop` and the commonest Roblox leak — a delayed call firing into a torn-down module — cannot happen.

Three things are boot errors, not runtime surprises: a `Req` the module has no hook for, a hook with no matching `Req` (a warning — it would never be called), and `BootOrder.Config` tuning a capability the module never asked for.

---

## BootOrder

```lua
return {
	Order = {
		{ "MemoryService", "SettingsService" },   -- one tier, no order among them
		"SessionManager",
		{ "StateManager", "CombatManager" },
	},
	Config = {
		StateManager     = { Hz = 20 },
		CameraController = { Hz = "Render" },     -- client only; errors on the server
		PickupService    = { Tags = { "Pickup" } },
		CombatManager    = { Hz = 30, Fences = { "Combat" } },
	},
}
```

Split by **concern** — `Order` is *when*, `Config` is *how*. The array index is the priority, so inserting a module is inserting a line; there are no numbers to renumber. **You only list what actually needs ordering** — anything absent boots after the last tier with one warning naming it.

One scheduler owns **one connection per driver for the whole app**, and staggers phases with golden-ratio offsets so forty modules at `Hz = 10` don't all land on the same frame. Throttled `:Heartbeat` receives *accumulated* dt, so integration stays correct at any rate.

---

## Double-sided Services

One shared module can serve both sides:

```lua
-- ReplicatedStorage/Shared/Modules/Services/CombatService   (must be replicated)
function CombatService:Start() end        -- the SERVER half

function CombatService:__Serve()          -- returns the CLIENT half
	local Client = {}
	function Client:Start() end
	return Client
end
```

**`__Serve` is a factory the client runs, not a table the server sends.** Server containers never replicate and functions don't cross remotes, so the client requires the same shared module and calls `__Serve` in its own VM. Two consequences: the module must live somewhere replicated — its server half is therefore readable by exploiters, so keep drop tables and anti-cheat thresholds in a Manager — and `__Serve` must be self-contained, because every upvalue it closes over is the client's copy.

Optionally a client host of the same name receives it:

```lua
-- StarterPlayerScripts/Client/Services/CombatService
function CombatService:__Recip(served)
	self.Served = served
end
```

That same-name pairing is the one duplicate the registry tolerates.

---

## The boot, in order

1. **Side** — from RunService.
2. **Registry** — walk `Hierarchy`, mount bins, apply `Inject`.
3. **Config** — `Junction` / `BootOrder` / `Registers` from the `Config` bin.
4. **Preload** — force-require the role bins, so a syntax error in module forty surfaces *here*. Side-filter in the same pass.
5. **Junction** — parse, apply `Defaults`, derive each transport class, validate every `Destination`, resolve Fences, materialize.
6. **Registers** — declared caches, policies, persistence.
7. **Order** — tiers, then leftovers with a warning.
8. **Inject** — validate `Req`, check reserved keys, build `Src`, grant `Trove`/`Timer`/`Profile`.
9. **`:Start`** — in order, each wrapped so one module erroring can't abort the boot.
10. **Install capabilities** — *after* `:Start`, so a module's state exists before its first callback. `Player` and `Tag` replay here.
11. **Arm** — one connection per driver. **Nothing ticks before this line.**
12. **`:Ready`** — every module, now that all of them are up.

```lua
app:Get("CombatManager")   app:List("Manager")
app:Inspect()              -- the topology, as data
app:Report()               -- the same thing as text: routes, listeners, fences, registers, traffic
app:Log()                  -- the event ring buffer; :Dump() is what you paste into a bug report
app:Restart()              -- tear down and boot again without leaving Play mode
app:Stop()
```

`Configure{ Panel = true }` builds a live on-screen panel on the client, toggled with **F4**.

---

## Testing

`__Tenv_` boots a whole app with no Roblox instances at all — plain-Lua channels, fake players, and a clock you advance:

```lua
local T = Trellis.__Tenv_({
	Side      = "Server",
	Junction  = require(Config.Junction),
	BootOrder = require(Config.BootOrder),
	Registers = require(Config.Registers),
	Modules   = { Managers = { CombatManager = require(...) } },
})

local ada = T:Join("Ada")
T:Send("Network.Combat.Swing", { Combo = 2 }, ada)   -- as if a client sent it
T:Wait(1)                                            -- a second of frames
assert(#T:Sent("Network.Combat.Hit") == 1)
T:Stop()
```

| | |
|---|---|
| Clock | `:Step(dt)` `:Wait(seconds)` `:Now()` |
| World | `:Join(name)` `:Leave(player)` `:Tag(inst, tag)` `:Untag(…)` |
| Wire | `:Send(path, payload, from)` `:Answer(path, fn)` `:Sent(path)` `:Clear()` |
| Access | `:Get(name)` `:Reg(name, owner)` `:Report()` `:Dump()` `:Stop()` |

It runs under Lune, so **your game's modules become testable** — not just the framework's.

---

## Rules Trellis enforces

| | Rule | Enforced by |
|---|---|---|
| 1 | Never `require` another Controller / Manager / Service | convention (use `Src`) |
| 2 | All inter-module talk goes through `Src` | the API surface |
| 3 | Only Trellis touches Remotes and Bindables | materialization is the sole path |
| 4 | The Junction is the only routing definition | boot validation, both sides |
| 5 | A module may not shadow an injected key | boot error naming the key |
| 6 | A `Req` must have its hook, and a hook its `Req` | boot error / warning |
| 7 | Config may not tune a capability never asked for | boot error |
| 8 | A client write to a register is a request, not a write | `Policies`, deny by default |
| 9 | A Manager may call its own domain Service | `Src:GetService` |

---

<div align="center">

**Trellis · an SSA subset · Plinko Labs**

</div>
