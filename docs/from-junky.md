# Coming from Junky

Trellis is the successor to Junky, which implemented SSJA — Single Script Junction
Architecture. If you have a game on Junky, this is what moved and why.

## What survived

One `Configure` per side. A declared routing map called the Junction. A single injected
context, with modules never requiring each other. Suffix-based classification into
Controllers, Managers and Services. Managers in a server-only container.

## What Configure stopped needing

Junky took six things:

```lua
Junky.Configure({
    Junction           = require(Utility.Junction),
    Manifest           = require(Utility.Manifest),
    ClassPriority      = require(Utility.ClassPriorityMap),
    StandalonePriority = require(Utility.StandalonePriorityMap),
    Inject             = { … },
    Modules            = { ServerStorage.Modules },
})
```

Trellis takes one:

```lua
Trellis.Configure({
    Hierarchy = { ReplicatedStorage.Shared.Modules, ServerScriptService.Server },
})
```

- `ClassPriority` + `StandalonePriority` merged into one `BootOrder`, split by concern
  rather than by role: `Order` is when, `Config` is how.
- `Manifest` is now just a module in the `Config` bin, reached with
  `:GetConfig("Manifests")`. There was never a reason for the framework to know about it.
- `Junction`, `BootOrder` and `Registers` are found in the `Config` bin by name.
- `Modules` is gone. `Hierarchy` does both jobs, because the folders you scanned for
  modules and the folders your dependencies lived in were always the same folders.

## The getters are derived

Junky had three fixed getters: `GetPackage`, `GetUtility`, `GetService`. Trellis
generates one per bin from the folder name, so a `Config/` folder produces `:GetConfig`
with no framework change. `Src.Main.Packages.Lume` reaches the same cache by path.

This also removed a class of bug. Junky resolved by `FindFirstChild`, so two modules
with the same name in different roots silently picked one — the exact failure that put
a stale `Lume` into production. A duplicate is now a boot error naming both paths.

## Namespaces still exist, direction no longer does

Junky bound the transport into every call site:

```lua
local Network = context:Network("Character")
local Ability = context:Local("Ability")
```

Trellis keeps the two namespaces, but the entry now declares `Kind`, so the transport
class is derived rather than implied:

| | `Static` | `Resolve` |
| --- | --- | --- |
| `Local` | BindableEvent | BindableFunction |
| `Network` | RemoteEvent | RemoteFunction |

## Local events are no longer Bindables

Junky's Local namespace was resolved in-process by the Router. Trellis materializes
Network entries into real instances but keeps Local entries as plain-Lua signals,
because `BindableEvent:Fire` serializes and would strip metatables from any payload
carrying a class instance or a promise. `Instanced = true` opts an entry back in.

## Router and Network.lua are gone

Junky's `Router` existed to resolve a Junction destination and filter delivery, and
`Network.lua` wrapped every message in a `{ d, n, to, a }` envelope so the destination
could cross the wire. With one instance per entry, neither is needed: the channel name
never goes on the wire, and every RemoteFunction has its own `OnServerInvoke` instead
of a hand-rolled responder table. That also removed the Substance dependency.

## The player argument moved, and stopped being positional

Junky passed the sending Player as a trailing argument; the Network library that
replaced its messaging in one project passed it first. Trellis fixes the position at
second, for every transport:

```lua
function(payload, from)
```

`from` is `nil` for anything internal. It is not a field on the context, because a
per-module singleton's field gets overwritten by the next event whenever a handler
yields — and this is the value authority is gated on.

## Guards became Fences

Junky's guards were registered ad hoc at the call site, so nothing could tell you what
was guarded without grepping. A Fence is declared in the map, may be enforced by several
modules at once, and can carry a per-player rate budget the framework enforces:

```lua
Junction.Fence = {
    Combat = { Events = { "Network.Combat" }, Rate = 20, Per = 1 },
}
```

## Capabilities are new

Junky injected the same context into everything. Trellis makes anything with a runtime
cost opt-in through `Req` — heartbeats, player events, tag events, timers, troves,
profiling — and moves their configuration into `BootOrder`, so performance is tuned in
one file rather than across forty.

## Registers are new

Junky had no cache. Trellis has a declared register tree with path policies, deltas,
prediction and persistence, which is roughly the session-manager-with-policies that
every SSJA game ended up writing by hand.

## Rough migration order

1. Move `ClassPriorityMap` and `StandalonePriorityMap` into one `BootOrder`.
2. Move `Junction`, `BootOrder` and `Manifest` into a `Config` folder beside `Packages`
   and `Utility`; delete those arguments from both Bootstraps.
3. Add `Kind = "Resolve"` to every request-shaped entry. Everything else defaults to
   `Static`.
4. Collapse repeated `Side` and `Destination` fields into domain-level `Defaults`.
5. Replace `context:Network(d)` / `context:Local(d)` with `Src:Network(d)` /
   `Src:Local(d)`; the surface is otherwise close.
6. Move the sending player from the trailing argument to the second parameter.
7. Convert guards to Fences, adding `Req = { "Fence" }` to whichever module owns each.
8. Add `Schema` to the entries that were validating payloads by hand, and delete the
   hand-written checks.
9. Run `lune run scripts/types` and annotate `:Start(Src: Generated.Src)`.
