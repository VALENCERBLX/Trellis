<div align="center">

```
 ████████ ██████  ███████ ██      ██      ██ ███████
    ██    ██   ██ ██      ██      ██      ██ ██
    ██    ██████  █████   ██      ██      ██ ███████
    ██    ██   ██ ██      ██      ██      ██      ██
    ██    ██   ██ ███████ ███████ ███████ ██ ███████
```

**A game framework for Roblox. The folder tree you hand it becomes the API.**

![Version](https://img.shields.io/badge/version-0.1.0-6C3EF4?style=for-the-badge)
![Luau](https://img.shields.io/badge/Luau-Roblox-A78BFA?style=for-the-badge)
![Tests](https://img.shields.io/badge/tests-324-6C3EF4?style=for-the-badge)
![License](https://img.shields.io/badge/license-MIT-6C3EF4?style=for-the-badge)

</div>

---

Trellis is a subset of Single Script Architecture. One Bootstrap per side owns the
lifecycle, every event is declared in one map, and modules never require each other.

What makes it a *subset* rather than another SSA framework: the dependency-injection
surface is **derived from your hierarchy** instead of hand-registered, and anything
with a runtime cost is **opt-in** rather than injected into everything.

```lua
local Trellis = require(ReplicatedStorage.Shared.Modules.Packages.Trellis)

local app = Trellis.Configure({
    Hierarchy = {
        ReplicatedStorage.Shared.Modules,   -- Packages, Utility, Config, Services
        ServerScriptService.Server,         -- Managers, server Services
    },
})
```

That is the whole server entry point. The client is the same call with its own root.
Nothing else in the game touches the framework.

---

## Installation

```toml
# wally.toml
[dependencies]
Trellis = "valence/trellis@0.1.0"
```

```sh
wally install
```

Trellis has no dependencies. To scaffold a project around it, paste
[`scripts/Scaffold.lua`](scripts/Scaffold.lua) into the Studio command bar. It lays
down the recommended layout, fills it with a small working game, and prints a
pass/fail line per subsystem when you press Play.

---

## The idea

Every direct child folder of every root becomes a **bin**, and each bin generates its
own getter from the singular of its name.

```
Shared/Modules/
  Packages/   ->  Src:GetPackage("Lume")      ==  Src.Main.Packages.Lume
  Utility/    ->  Src:GetUtility("Maid")      ==  Src.Main.Utility.Maid
  Config/     ->  Src:GetConfig("Manifests")
  Services/   ->  Src:GetService("Combat")
```

Add a `Config/` folder and `:GetConfig` exists. There is no registration step and no
framework change. It follows that `Junction`, `BootOrder` and `Registers` need not be
passed to `Configure` at all. They are modules in the `Config` bin, found by name.

A Controller has no `:GetManager`, because the client roots contain no `Managers/`
folder. That is not a special case in the code; it falls out of which tree that side
was handed.

Four rules keep it honest:

- Only direct children are scanned, so a package's own nested `Packages/` folder stays
  private and can never collide with yours.
- A name mounted twice across two roots is a boot error naming both full paths.
- Entries resolve under their full name and their name minus the bin suffix, so
  `GetService("Combat")` and `GetService("CombatService")` are the same module.
- Calling a bin that does not exist on this side errors, listing the bins that do.

Luau cannot type generated methods. That cost is paid once, by codegen:

```sh
lune run scripts/types -- src/Shared/Modules src/Server \
    --out src/Shared/Modules/Config/Generated.luau
```

```lua
function CombatManager:Start(Src: Generated.Src) end   -- :GetService( autocompletes
```

---

## The Junction

Every event in the game is declared once, with its transport, its destination and the
shape of its payload.

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
    Animation = {
        Defaults = { Destination = "AnimationService" },
        Play = {}, Stop = {},
        MarkerReached = { Destination = "any" },
    },
}

Junction.Fence = {
    Combat = { Events = { "Network.Combat" }, Rate = 20, Per = 1 },
}
```

Two words cover four transports:

| | `Kind = "Static"` | `Kind = "Resolve"` |
| --- | --- | --- |
| **`Junction.Local`** | BindableEvent | BindableFunction |
| **`Junction.Network`** | RemoteEvent | RemoteFunction |

Network entries **materialize into real instances** mirroring the map's nesting, at
`ReplicatedStorage/Junction/Combat/Swing`. The server creates them; the client waits
for the same paths. Three things follow. The channel name never goes on the wire.
Every RemoteFunction gets its own `OnServerInvoke` instead of a hand-rolled dispatch
table. And the Explorer shows the live topology while the game runs.

Local entries are plain-Lua signals by default. `BindableEvent:Fire` serializes its
arguments, so metatables are stripped, table identity is lost and mixed keys are
mangled. That silently breaks any payload carrying a class instance or a promise. Set
`Instanced = true` on an entry when you want the Explorer node anyway.

A domain-level `Defaults` table is inherited by every entry in it. Per-entry fields
override, and `Destination = "any"` clears an inherited one. In practice this turns
the exceptions into the only lines carrying text.

Read more: [docs/junction.md](docs/junction.md)

---

## Src

`Src` is the injected context and the only surface a module talks through. It is
mirrored onto the module, so it is reachable from every method rather than only from
`:Start`.

```lua
function CombatManager:Start(Src)
    Src:Network("Combat"):Subscribe("Swing", function(payload, from)
        if not from then return end          -- nil means internal, so trusted
        self:Apply(from, payload)
    end)

    Src:Network("Session"):Respond("Get", function(_, from)
        return Src:Reg("Session", from):Access("Stats")
    end)
end
```

| | |
| --- | --- |
| Identity | `Src.Name` `Src.Role` `Src.Side` `Src.Player` `Src.Main` |
| Bus | `:Local(domain)` `:Network(domain)` |
| Static | `:Post` `:Subscribe` `:Once`, plus `:PostTo` `:PostAll` `:PostExcept` |
| Resolve | `:Resolve` `:Respond`, plus `:ResolveFrom(player, …)` on the server |
| Cache | `:Reg(name)` `:Reg(name, player)` |
| Timing | `:Await(path)` `:OnCleanup(fn)` `:Inspect()` |
| By `Req` | `Src.Trove` `:Delay` `:Every` `:Cancel` |

Event names are checked against the Junction when a handler binds, so a typo errors
immediately and lists the domain's real events. Calling `:Post` on a `Resolve` entry
is likewise an error rather than a confusing nil.

`from` is always the handler's second parameter and never a field. `Src` is a
per-module singleton, so a shared `From` slot would be overwritten by the next event
whenever a handler yields, and `from` is the value authority is gated on. It is `nil`
for anything that originated on this side.

Inbound payloads clear three gates before a handler sees them, cheapest first:

1. **Rate.** The per-player budget the Fence declared. This runs first on purpose: a
   flood of malformed payloads is exactly what a rate limit exists to stop, so
   validating first would exempt garbage from the budget.
2. **Schema.** Declared on the entry. The rejection names the offending field.
3. **Fences.** Your own predicates. Several modules may fence one event and all must
   pass, so a shape check and a rate limiter coexist without knowing about each other.

Read more: [docs/src.md](docs/src.md)

---

## Reg

A register is a replicating tree with declared authority.

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

Reg:New("Stats.Health", 100)       Reg:Access("Stats.Health")
Reg:Edit("Stats", { Mana = 5 })    Reg:Bubble("Stats", fn)
Reg:Swap("Stats.Health", 50)       Reg:Rem("Stats.Health")
local Bag = Reg:Cat("Inventory")
```

`Cat` means category, and it is the only thing that creates one. `Access` and `Edit`
walk existing categories and throw on a path that does not resolve, naming the segment
that failed and listing its siblings. Without that rule, one typo grows a phantom
branch and you are back to a bag of strings. A missing *value* still reads as `nil`;
a value may legitimately be unset, while a missing category is a structural mistake.

The five mutation verbs are the replication protocol. Each one is a path-shaped delta
`{ Op, Reg, Owner, Path, Value }`. Reads never leave the local mirror, which is why
`Access` and `Bubble` sit outside that set.

A client mutation is a request rather than a write. The server checks the path against
`Policies`, applies it, and echoes the authoritative delta. A path matching no policy is
server-only, so forgetting to write a policy fails closed. Every verb returns a promise
on both sides, so a side-split Service can move sides without a rewrite.

Read more: [docs/registers.md](docs/registers.md)

---

## Capabilities

A module declares what it needs. The deployment decides how much of it. `Req` covers
only things that cost something at runtime or need per-deployment configuration. A hook
that is simply called once if you defined it costs nothing when absent, and should not
need declaring.

| `Req` | Installs | Configured by |
| --- | --- | --- |
| `Heart` | `:Heartbeat(dt)` | `Hz` |
| `Player` | `:PlayerAdded` / `:PlayerRemoving` (server) | - |
| `Tag` | `:TagAdded` / `:TagRemoved` | `Tags` |
| `Fence` | `:Fence(event, payload, from)` | `Fences` |
| `Timer` | `Src:Delay` `:Every` `:Cancel` | - |
| `Trove` | `Src.Trove` | - |
| `Profile` | every hook wrapped in `debug.profilebegin` | - |

`:Start(Src)`, `:Stop()` and `:Ready()` need no `Req`. `:Ready` runs once every module
on that side has started, which is the timing question modules actually have.

```lua
local StateManager = {}
StateManager.Req = { "Heart", "Trove" }

function StateManager:Start(Src)
    self.Trove:Add(workspace.ChildAdded:Connect(fn))   -- no :Stop needed
end

function StateManager:Heartbeat(dt) end                -- rate lives in BootOrder
```

`Player` and `Tag` replay their backlog when they install: players who joined and
instances already tagged before the module booted go through the same handler. Without
that, a module which boots late misses them entirely, and that only shows up on a
populated live server.

Timers ride the scheduler's clock rather than `task.delay`, so they cancel on `:Stop`.
The commonest leak in Roblox code is a delayed call firing into a torn-down module,
and this makes it structurally impossible instead of a matter of discipline.

Read more: [docs/capabilities.md](docs/capabilities.md)

---

## BootOrder

```lua
return {
    Order = {
        { "MemoryService", "SettingsService" },   -- one tier, no order within it
        "SessionManager",
        { "StateManager", "CombatManager" },
    },
    Config = {
        StateManager     = { Hz = 20 },
        CameraController = { Hz = "Render" },
        PickupService    = { Tags = { "Pickup" } },
        CombatManager    = { Hz = 30, Fences = { "Combat" } },
    },
}
```

`Order` is when a module starts; `Config` is how it is set up when it does. The array
index is the priority, so inserting a module means inserting a line rather than
renumbering anything. Only list what genuinely needs ordering. Everything else boots
after the last tier, with one warning naming it.

One `BootOrder` covers both sides, so it lists Controllers and Managers together and
each side sees names it cannot have. The suffix settles it: a `*Controller` is skipped
on the server, a `*Manager` on the client, and a Service missing here is assumed to be
the other side's half. A name that belongs on this side and is absent is still an
error, since that is a real typo.

One scheduler owns one connection per driver for the whole app and staggers phases
with golden-ratio offsets, so forty modules at `Hz = 10` do not all land on the same
frame. A throttled `:Heartbeat` receives accumulated dt, so integration stays correct
at any rate.

---

## Double-sided Services

One module in a replicated container can serve both sides.

```lua
function CombatService:Start() end        -- the server half

function CombatService:__Serve()          -- returns the client half
    local Client = {}
    function Client:Start() end
    return Client
end
```

`__Serve` is a factory the client runs, not a table the server sends. Server containers
never replicate and functions do not cross remotes, so the client requires the same
shared module and calls `__Serve` in its own VM. Two consequences worth stating plainly.
The module must live somewhere replicated, so its server half is readable by exploiters;
keep drop tables and anti-cheat thresholds in a Manager. And `__Serve` must be
self-contained, because every upvalue it closes over is the client's copy.

A client module of the same name may receive it instead:

```lua
function CombatService:__Recip(served)
    self.Served = served
end
```

That pairing is the one duplicate name the registry tolerates.

---

## Diagnostics

```lua
app:Report()    -- routes with their real listeners, fences, registers, traffic
app:Inspect()   -- the same thing as data
app:Log():Dump()
app:Restart()   -- tear down and boot again without leaving Play mode
```

`Configure{ Panel = true }` builds a live panel on the client, toggled with **F4**.
`Configure{ Log = true }` keeps a ring buffer of the last events per path, summarized
by shape rather than by reference so it cannot pin payloads in memory. `:Dump()` is
what you paste into a bug report.

---

## Testing

`__Tenv_` boots a whole app with no Roblox instances: plain-Lua channels, fake players,
and a clock you advance by hand.

```lua
local T = Trellis.__Tenv_({
    Side      = "Server",
    Junction  = require(Config.Junction),
    BootOrder = require(Config.BootOrder),
    Modules   = { Managers = { CombatManager = require(...) } },
})

local ada = T:Join("Ada")
T:Send("Network.Combat.Swing", { Combo = 2 }, ada)
T:Wait(1)
assert(#T:Sent("Network.Combat.Hit") == 1)
T:Stop()
```

It runs under Lune, which means your game's modules are testable and not only the
framework's.

Read more: [docs/testing.md](docs/testing.md)

---

## Status

324 tests pass under Lune, and `rojo build` produces a clean model. **Trellis has not
yet run inside Roblox.** Every test stubs `Instance`, `RunService` and the remotes,
because Lune cannot run Roblox networking or physics. Run
[`scripts/Scaffold.lua`](scripts/Scaffold.lua) in Studio and press Play before trusting
it with a real game.

```sh
./run-tests.sh
```

---

## Documentation

| | |
| --- | --- |
| [Architecture](docs/architecture.md) | How the pieces fit, and what boots in what order |
| [The Junction](docs/junction.md) | Entry fields, transports, materialization, fences |
| [Src](docs/src.md) | The full injected surface |
| [Registers](docs/registers.md) | Categories, deltas, policies, persistence |
| [Capabilities](docs/capabilities.md) | `Req`, hooks, and the scheduler |
| [Testing](docs/testing.md) | `__Tenv_` and the Lune suite |
| [Coming from Junky](docs/from-junky.md) | What changed from SSJA, and why |

---

<div align="center">

**Trellis** · [Valence](https://github.com/VALENCERBLX) · MIT

</div>
