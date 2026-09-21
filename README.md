<div align="center">


<img width="512" height="256" alt="TRELLISSHORT" src="https://github.com/user-attachments/assets/64163f83-193b-4a37-971b-3807933b0bad" />


**A game framework for Roblox. The folder tree you hand it becomes the API.**

![Version](https://img.shields.io/badge/version-0.2.1-6C3EF4?style=for-the-badge)
![Luau](https://img.shields.io/badge/Luau-Roblox-A78BFA?style=for-the-badge)
![Tests](https://img.shields.io/badge/tests-389-6C3EF4?style=for-the-badge)
![License](https://img.shields.io/badge/license-MIT-6C3EF4?style=for-the-badge)

[![Star History Chart](https://api.star-history.com/svg?repos=VALENCERBLX/Trellis&type=Date)

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

# Contents

**Getting started**
- [Installing](#installing)
- [The layout](#the-layout)
- [Typing the generated getters](#typing-the-generated-getters)

**How it thinks**
- [Hierarchy as API](#hierarchy-as-api)
- [Roles](#roles)
- [What Configure does, in order](#what-configure-does-in-order)
- [What the framework refuses to guess](#what-the-framework-refuses-to-guess)

**The Junction**
- [Declaring events](#declaring-events)
- [Entry fields](#entry-fields)
- [Defaults and "any"](#defaults-and-any)
- [Transports](#transports)
- [Materialization](#materialization)
- [Why Local entries are not Bindables](#why-local-entries-are-not-bindables)
- [Schemas](#schemas)
- [Fences](#fences)

**Src**
- [Identity](#identity)
- [Dependencies](#dependencies)
- [The bus](#the-bus)
- [The handler contract](#the-handler-contract)
- [The three gates](#the-three-gates)
- [Destination filtering](#destination-filtering)
- [Channels](#channels)
- [Timing](#timing)
- [Reserved keys](#reserved-keys)

**Registers**
- [Declaring registers](#declaring-registers)
- [The surface](#the-surface)
- [Edit and Swap are not interchangeable](#edit-and-swap-are-not-interchangeable)
- [Only Cat creates a category](#only-cat-creates-a-category)
- [Replication and authority](#replication-and-authority)
- [Bubbling](#bubbling)
- [Persistence](#persistence)

**Capabilities**
- [What earns a Req](#what-earns-a-req)
- [The roster](#the-roster)
- [Heart](#heart)
- [Player](#player)
- [Tag](#tag)
- [Fence](#fence)
- [Timer](#timer)
- [Trove](#trove)
- [Profile](#profile)

**Lifecycle**
- [BootOrder](#bootorder)
- [Stopping and restarting](#stopping-and-restarting)

**Double-sided Services**
- [How it works](#how-it-works)
- [Which file gets delivered](#which-file-gets-delivered)
- [Deploying by hand](#deploying-by-hand)

**Working with it**
- [Diagnostics](#diagnostics)
- [Testing](#testing)
- [The framework's own suite](#the-frameworks-own-suite)
- [What the suite cannot tell you](#what-the-suite-cannot-tell-you)

**Reference**
- [Coming from Junky](#coming-from-junky)
- [Errors and warnings](#errors-and-warnings)
- [Status](#status)

---

# Getting started

## Installing

```toml
# wally.toml
[dependencies]
Trellis = "valence/trellis@0.2.1"
```

```sh
wally install
```

Trellis has no dependencies. Without Wally, paste [`dist/Adeal.luau`](dist/Adeal.luau)
into the Studio command bar; it carries every module inline and installs to
`ReplicatedStorage.Shared.Modules.Packages.Trellis`.

Over HTTP, with **Game Settings → Security → Allow HTTP Requests** on:

```lua
local h = game:GetService("HttpService")
loadstring(h:GetAsync("https://raw.githubusercontent.com/VALENCERBLX/Trellis/master/dist/Adeal.luau"))()
```

Then [`dist/Setup.luau`](dist/Setup.luau) lays out a project around it: the module
folders, the Config module with its children, the shared Bootstrap and the two entry
points. It never overwrites anything that already exists.

## The layout

Nothing here is enforced. It is the shape the getters fall out of.

```
ReplicatedStorage/
  Shared/
    Assets/            Interface, Audio, Models, Builds
    Classes/           plain classes both sides construct
    Modules/
      Packages/        libraries          -> :GetPackage
      Utilities/       singletons         -> :GetUtility
      Config/          Junction, BootOrder, Registers, Manifests -> :GetConfig
      Services/        both sides         -> :GetService
  Client/
    Modules/
      Controllers/     client only        -> :GetController
      Services/        client only
      Packages/
      Utilities/
ServerStorage/
  Modules/
    Managers/          server only        -> :GetManager
    Workers/           client halves, delivered on join
    Services/          server only
    Packages/
    Utilities/
ServerScriptService/
  ServerInit           three lines
StarterPlayer/StarterPlayerScripts/
  Init                 three lines
```

Both entry points read one shared `Bootstrap` module, so there is exactly one
description of where things live:

```lua
-- ServerScriptService/ServerInit
local Modules = ReplicatedStorage.Shared.Modules
local Trellis = require(Modules.Packages.Trellis)
local Bootstrap = require(Modules.Utilities.Bootstrap)

local app = Trellis.Configure(Bootstrap.Server())
```

## Typing the generated getters

Luau cannot type methods that are generated at runtime. That cost is paid once, by
codegen:

```sh
lune run scripts/types -- src/Shared/Modules src/Server \
    --out src/Shared/Modules/Config/Generated.luau
```

```lua
function CombatManager:Start(Src: Generated.Src) end   -- :GetService( autocompletes
```

---

# How it thinks

## Hierarchy as API

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

Every root is merged into the same bins, so on the server `GetPackage` already sees
Shared and ServerStorage packages together, and `GetService` already sees both halves
of a side-split Service. Writing a resolver in `Inject` to do that yourself adds
nothing except a second, worse answer for the names the bin misses.

`Inject` is for trees that **cannot** be bins, because they are not ModuleScripts:

```lua
Inject = {
    -- Src:GetClass("Characters.Superman")
    Class = function(path)
        local node = ReplicatedStorage.Shared.Classes
        for segment in string.gmatch(path, "[^%.]+") do
            node = node and node:FindFirstChild(segment)
        end
        return node
    end,

    -- Src:GetAsset("HealthBar")
    Asset = function(name)
        return ReplicatedStorage.Shared.Assets:FindFirstChild(name, true)
    end,
}
```

A function is a resolver, consulted only when the bin misses. A table mounts its keys
as entries.

## Roles

A module's suffix decides three things: which bin it lands in, which side it boots on,
and how the Junction validates destinations naming it.

| Suffix | Side | Notes |
| --- | --- | --- |
| `*Controller` | Client | Always. A Network destination naming one can be checked from the client. |
| `*Manager` | Server | Always. Checked from the server. |
| `*Service` | Either | Side-split: it boots wherever it was discovered. Never side-checked. |

Because the first two are unambiguous, a `Destination` naming a Controller that does
not exist on the client is a typo rather than a remote, so it is a boot error instead
of a silent nothing. A destination whose suffix is none of the three is rejected
outright, which catches the common case where the typo lands *in* the suffix
(`CombatMangaer`).

## What Configure does, in order

Twelve steps, and the order carries real weight.

1. **Side.** From `RunService`.
2. **Registry.** Walk `Hierarchy`, mount bins, apply `Inject`. A name mounted twice is
   recorded rather than thrown, so step 4 gets one chance to reconcile a double-sided
   Service; anything unreconciled throws when something asks for it.
3. **Config.** `Junction`, `BootOrder` and `Registers` from the `Config` bin, unless
   `Configure` was given them explicitly.
4. **Preload.** Force-require every role module, so a syntax error in the fortieth
   module surfaces here and not on first use. Side-filtering happens in the same pass,
   because a shared root may legitimately contain Controllers the server must not boot.
   Double-sided Services are paired here.
5. **Junction.** Parse, apply `Defaults`, derive each transport class, validate every
   `Destination` against the registry, resolve Fences, then materialize.
6. **Registers.** Declared caches, path policies, persistence backend.
7. **Order.** Resolve tiers; anything unlisted goes last with one warning naming it.
   `BootOrder.Config` is checked against what each module actually asked for.
8. **Inject.** Per module: validate `Req` against side and hooks, check for reserved
   keys, build `Src`, mirror it on, grant `Trove` / `Timer` / `Profile`.
9. **`:Start`.** In order, each wrapped so one module erroring cannot abort the boot.
10. **Install capabilities.** After `:Start`, so a module's state exists before its
    first callback. `Player` and `Tag` replay their backlogs here.
11. **Arm.** One `RunService` connection per driver, for the whole app. Nothing ticks
    before this line.
12. **`:Ready`.** Every module, now that all of them are up.

Steps 8–11 are why `Trove` and `Timer` are granted before `:Start` while `Heart`,
`Player`, `Tag` and `Fence` install after it. Modules use `self.Trove` and `self:Delay`
*inside* `:Start`; nothing should receive a callback before it has run.

## What the framework refuses to guess

Everything routable is declared. That is the price of admission, and these are what it
buys. Each one is a boot error:

- a `Destination` that names no module on the side that owns it
- a destination whose suffix is not a role
- a `Fence` naming an event or domain that does not exist
- a `Kind` or namespace that is not one of the two
- `Side` on a `Network` entry, which crosses by definition
- a `Schema` naming a type that does not exist
- a module defining a key the framework injects
- a `Req` the module has no hook for
- `BootOrder` naming a `*Controller` absent on the client, or a `*Manager` absent on
  the server, or naming anything twice
- `BootOrder.Config` tuning a capability the module never asked for
- two modules with the same name, unless they are a `__Serve` / `__Recip` pair

And two warnings, for things that are legal but almost certainly wrong: a hook defined
without its `Req` (it will never be called), and a module subscribing to an event the
Junction routes elsewhere (it will never fire).

---

# The Junction

## Declaring events

Every event in the game is declared once, with its transport, its destination and the
shape of its payload.

```lua
Junction.<Namespace>.<Domain>.<Event> = { entry }
```

`Namespace` is `Network`, `Local` or `Fence`. Domains group events; the domain is what
`Src:Local(domain)` and `Src:Network(domain)` bind to.

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

## Entry fields

| Field | Default | Meaning |
| --- | --- | --- |
| `Kind` | `"Static"` | `"Static"` is an Event, `"Resolve"` is a Function. |
| `Destination` | none | Delivery filter. Only that module's subscribers receive it. |
| `Side` | both | `"Server"` or `"Client"`. Local entries only. |
| `Schema` | none | The payload shape, checked at the edge. |
| `Instanced` | `false` | Local entries only: use a real Bindable. |

## Defaults and "any"

All five may be set per entry or inherited from the domain's `Defaults` table.

```lua
State = {
    Defaults = { Side = "Server" },
    Entered = {}, Exited = {}, Granted = {}, Revoked = {},
}
```

`Destination = "any"` explicitly clears an inherited destination. This is how a domain
expresses the common requests-in / reports-out split:

```lua
Animation = {
    Defaults = { Destination = "AnimationService" },

    Play = {}, Stop = {}, AdjustSpeed = {},          -- requests into the service

    MarkerReached = { Destination = "any" },          -- reports back out of it
    TrackEnded    = { Destination = "any" },
}
```

In practice this turns the exceptions into the only lines carrying text. `Defaults` is
the only reserved key, so no event may be named `Defaults`.

## Transports

```lua
class = (namespace == "Local" and "Bindable" or "Remote") .. (Static and "Event" or "Function")
```

| | `Kind = "Static"` | `Kind = "Resolve"` |
| --- | --- | --- |
| **`Junction.Local`** | BindableEvent | BindableFunction |
| **`Junction.Network`** | RemoteEvent | RemoteFunction |

Verbs are checked against `Kind` when a handler binds. `:Post` on a `Resolve` entry is
an error naming the path, as is a second `:Respond` on the same entry. Exactly one
module answers an event.

## Materialization

Network entries become one instance each, mirroring the map's nesting:

```
ReplicatedStorage/Junction/
    Combat/   Swing (RemoteEvent)   Block (RemoteEvent)
    Session/  Get   (RemoteFunction)
    __Reg/    Delta (RemoteEvent)   Request (RemoteFunction)
```

The server creates them, the client waits for the same paths with a 30 second timeout
and a clear error rather than an indefinite hang. `__Reg` is the framework's own
channel for register deltas; you do not declare it.

One instance per entry rather than one multiplexed remote, for four reasons. The
channel name leaves the wire. A RemoteFunction has exactly one `OnServerInvoke`, so
multiplexing forces a hand-rolled responder table. Per-entry instances make "two
modules answered the same event" a boot error instead of last-writer-wins. And the
Explorer shows the topology while the game runs.

## Why Local entries are not Bindables

`BindableEvent:Fire` serializes its arguments. Tables are deep-copied, metatables
stripped, table identity lost, mixed keys mangled. A Local event carrying a state
machine, a class instance or a promise breaks silently.

Local entries are therefore plain-Lua signals: same surface, no copy, faster. Set
`Instanced = true` on an entry when you want the Explorer node or a third-party script
hooking in.

A Local `Resolve` as a real BindableFunction buys nothing at all. It is a synchronous
call with a serialization tax.

## Schemas

```lua
Swing = {
    Destination = "CombatManager",
    Schema = {
        Target = "Instance",
        Combo  = { Type = "number", Min = 1, Max = 5 },
        Style  = { Type = "string", One = { "Light", "Heavy" } },
        Meta   = "table?",
        Origin = { Type = "table", Of = { X = "number", Y = "number" } },
    },
}
```

A field is either a type string or a spec table. A `?` suffix makes it optional.
Undeclared fields are ignored. A schema may also be a bare string for events whose
payload is a single value.

| Spec key | Effect |
| --- | --- |
| `Type` | The type name. Required: its presence is what marks a table as a spec. |
| `Min` / `Max` | Numeric bounds. |
| `One` | An allowed set. |
| `Of` | A nested schema. |

Rejections name the field and what was expected. Schemas are themselves validated at
boot, so a typo'd type string fails then rather than silently rejecting live traffic.

## Fences

A Fence is a named set of events plus, optionally, a per-player call budget.

```lua
Junction.Fence = {
    Combat  = { Events = { "Network.Combat" }, Rate = 20, Per = 1 },
    Economy = { "Network.Shop.Purchase" },
}
```

A target is either a full event path or a domain path, which encloses every event in
it. A plain array is shorthand for `{ Events = … }` with no budget.

A module volunteers as a fencer through `Req` and `BootOrder`:

```lua
CombatManager.Req = { "Fence" }

function CombatManager:Fence(event, payload, from)
    if not from then return true end
    return self:InRange(from, payload.Target), "range"
end

-- BootOrder.Config: CombatManager = { Fences = { "Combat" } }
```

Fences run on the receiving side. For a Network entry that means server-side; a client
gating its own outbound traffic would be pointless. Several modules may fence one
Fence and all must pass, which is how a rate limiter and a shape check coexist without
knowing about each other.

The rate budget is a fixed window per player. Its worst case is a burst straddling the
boundary giving twice the budget for one window, which is the right trade for an
anti-spam guard. Internal traffic, where `from` is nil, is never rate limited.

---

# Src

`Src` is what a Controller, Manager or Service receives. It arrives twice: as the
`:Start` argument, and mirrored onto the module itself through `__index`. That second
delivery is why `self:Local("Input")` works from any method, and why no module needs
the `self._ctx = ctx` line that every SSA framework otherwise collects.

Injection is a privilege of the three roles. Packages, Utilities and Config modules
receive nothing. They are plain modules pulled through the getters, which is what
keeps them reusable across projects.

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

## Identity

```lua
Src.Name     -- "CombatManager"
Src.Role     -- "Manager"
Src.Side     -- "Server" | "Client"
Src.Player   -- LocalPlayer on the client, nil on the server
Src.Main     -- the hierarchy as you wrote it
```

There is no `Src.Domain`. Every bus call names its domain, so nothing is implicit and
moving an event between domains does not change meaning at a distance.

**Src carries these five fields and nothing else.** Everything else is a method or a
generated getter, so `Src.Structs` or `Src.Config` is `nil` rather than a shortcut.
Reach config through `Src:GetConfig("Static")` or `Src:GetUtility("Config")`.

## Dependencies

Two views of one lazy cache:

```lua
Src.Main.Packages.Lume  ==  Src:GetPackage("Lume")
Src.Main.Utility.Maid   ==  Src:GetUtility("Maid")
```

`Main` is keyed by the container name as it appears in your tree; the getter is keyed
by the singular bin name. `Main` is frozen, so containers cannot be replaced and
entries cannot be written.

Each bin generates `Get<Bin>`, `Has<Bin>` and `List<Bin>`. `Has` is a soft miss
returning `false`; `Get` on a missing entry errors and lists the known names. Use
`Has` before `Get` for a dependency that is genuinely optional:

```lua
local Lume = if Src:HasPackage("Lume") then Src:GetPackage("Lume") else nil
```

A namespace under `Main` resolves lazily, so the table behind it is empty until you ask
it for something. `#` and `tostring` answer from the names rather than from the table,
so a populated bin does not read as one that failed to mount:

```lua
print(Src.Main.Packages)   --> Packages{ Lume, Trellis }
#Src.Main.Packages         --> 2

for name, package in Src.Main.Packages do end
```

Roblox's own rich table dump recurses raw and ignores `__tostring` on nested values, so
`print(Src)` still shows the namespaces as `{}`. Print the namespace itself.

## The bus

```lua
local Combat = Src:Network("Combat")
local Input  = Src:Local("Input")
```

A scope is bound to one namespace and one domain, and validates event names against
the Junction when you bind. Scopes are cached per `Src`, so calling
`Src:Network("Combat")` repeatedly is free.

**Static entries:**

```lua
Combat:Post("Hit", payload)
Combat:Subscribe("Hit", function(payload, from) end)   --> unsubscribe function
Combat:Once("Hit", handler)

Combat:PostTo(player, "Hit", payload)      -- server only
Combat:PostAll("Hit", payload)             -- server only
Combat:PostExcept(player, "Hit", payload)  -- server only
```

Direction is implicit in the side. On the client, `:Post` goes up to the server. On the
server it goes down to every client; `:PostTo` targets one.

**Resolve entries:**

```lua
Combat:Resolve("Query", payload):Next(print):Toss(warn)
Combat:Respond("Query", function(payload, from) return answer end)

Combat:ResolveFrom(player, "Query", payload, { Timeout = 5 })   -- server only
```

`:Resolve` on the server is an error telling you to use `:ResolveFrom`, since there is
no single peer. `:ResolveFrom` carries a mandatory ten second default timeout, because
`RemoteFunction:InvokeClient` blocks until that client answers and a hung or hostile
client would otherwise strand a server thread indefinitely.

Subscribing returns the function that unsubscribes, not a connection object, because
there is exactly one thing you can do with it.

## The handler contract

```lua
function(payload, from)
```

One payload, not varargs. `from` is the sending Player, or `nil` when the event
originated on this side.

`from` is a parameter and never a field: `Src` is a per-module singleton, so a shared
slot would be overwritten by the next event whenever a handler yields, and this is the
value authority is gated on. The shape is identical across all four transports.

```lua
Combat:Subscribe("Swing", function(payload, from)
    if from then
        -- a client sent this. untrusted.
    else
        -- internal. trusted.
    end
end)
```

## The three gates

Inbound payloads clear three gates before a handler sees them, cheapest first:

1. **Rate.** The per-player budget the Fence declared. This runs first on purpose: a
   flood of malformed payloads is exactly what a rate limit exists to stop, so
   validating first would exempt garbage from the budget.
2. **Schema.** Declared on the entry. The rejection names the offending field.
3. **Fences.** Your own predicates. Several modules may fence one event and all must
   pass, so a shape check and a rate limiter coexist without knowing about each other.

## Destination filtering

`Destination` filters delivery; it does not set direction. Only subscribers owned by
the named module receive the event. Subscribing to an event routed elsewhere is always
a mistake, so it warns at bind time naming both modules rather than silently never
firing.

## Channels

Service to Service, directly. Not through the Junction and not over the wire: a plain
call into the other Service on this side, so it is synchronous and returns whatever the
handler returns. Channels are cached per target.

```lua
-- CombatService
local Memory = Src:Channel("MemoryService")

local profile = Memory:GET("profile", { UserId = id })
Memory:PATCH("profile", { UserId = id, Changes = { Coins = 5 } })
```

```lua
-- MemoryService
function MemoryService:GET(route, payload, from)
    if route == "profile" then
        return self.profiles[payload.UserId]
    end
end
```

| Verb | Means |
| --- | --- |
| `GET` | read, changes nothing |
| `POST` | submit something new |
| `PUT` | replace it wholesale |
| `PATCH` | change part of it |
| `DELETE` | remove it |
| `HEAD` | does it exist, how big: no body |
| `OPTIONS` | what does this Service answer |

Those seven are the whole vocabulary, capitalised on purpose: they are protocol verbs
rather than Lua methods, and at a call site the shouting is the point. A Service's
surface to its peers is a fixed, small set of names with agreed meanings, so a call
site tells you what it does to the other side without reading the handler. A handler
receives `(route, payload, from)`, where `from` is the calling Service's name.

`OPTIONS` is answered by the framework when the Service does not implement it,
returning the verbs it does. A verb with no handler errors, naming what the target
implements.

Errors, all at the call:

- a Controller or Manager opening a channel
- a channel to a Manager, a Controller, or a name that is not here (lists the Services)
- a channel to itself
- a verb the target does not answer

## Timing

```lua
Src:Await("Local.Round.Began"):Next(handler)
Src:OnCleanup(fn)
Src:Inspect()
```

`:Await` resolves the first time an event is *delivered* on this side and then latches,
so a late awaiter resolves immediately. Delivery is the trigger rather than posting: an
event posted from here but delivered elsewhere has not happened here. Use `:Await` for
"has this happened yet" and `:Subscribe` for "tell me every time".

## Reserved keys

Because `Src` mirrors onto the module, these belong to the framework, and a module
defining one is a boot error rather than a silent shadow:

```
Name  Role  Side  Player  Main  Local  Network  Reg  Channel  Await  OnCleanup
Inspect  Deploy  Recall  Trove  Delay  Every  Cancel  Get*  Has*  List*
```

`Req` is read before injection, so it stays yours. `Hz`, `Tags` and `Fences` live in
`BootOrder` and are never injected.

---

# Registers

A register is a replicating tree with declared shape and declared authority.

## Declaring registers

```lua
Registers = {
    Session = {
        Replicate = "Owner",
        Persist = true,
        Cats = { Stats = {}, Settings = {}, Inventory = { Dynamic = true } },
        Policies = { ["Stats.*"] = "Server", ["Settings.*"] = "Owner" },
    },
    Round   = { Replicate = "All", Cats = { Scores = {} } },
    Secrets = { Replicate = false },
}
```

Registers are declared, not conjured. `Src:Reg("Undeclared")` errors and lists the
declared ones. `Replicate = "Owner"` needs a subject: `Src:Reg("Session", player)` on
the server, `Src:Reg("Session")` on the client, where it is implicitly yours.

| `Replicate` | Who receives deltas |
| --- | --- |
| `"All"` | Every client. |
| `"Owner"` | Only the owning player. |
| `false` | Nobody. Server-only. |

## The surface

```lua
Reg:New(path, value)      -- create; errors if the key exists
Reg:Edit(path, patch)     -- merge, recursively
Reg:Swap(path, value)     -- replace outright
Reg:Rem(path)             -- delete
Reg:Cat(name)             -- scope into, or create under a Dynamic parent

Reg:Access(path)          -- read; synchronous, local mirror, never yields
Reg:Bubble(path, fn)      -- subscribe to changes at or under path
```

`Access` and `Edit` take dot paths. Keys may not contain a dot, and that is checked
when they are created.

## Edit and Swap are not interchangeable

| | `Edit` | `Swap` |
| --- | --- | --- |
| Keys you did not mention | survive | deleted |
| Nested tables | merged recursively | replaced whole |
| On the wire | just the patch | the entire value |
| Can remove a field | no | yes |

You cannot delete a field with `Edit`. `{ Name = nil }` is not a table with a nil
value; it is a table with no `Name` key, so the merge never sees it. Use `Swap` or
`Rem`. And `Edit` on a non-table value has nothing to merge into, so it behaves as
`Swap`. The two are identical for scalars.

## Only Cat creates a category

`Access` and `Edit` walk existing categories and throw on a path that does not resolve,
naming the failed segment and listing its siblings:

```
no category "Statz" under "(root)". categories there: Inventory, Settings, Stats
```

Without that, `Reg:Edit("Comabt.Health", 5)` grows a phantom branch and the register
becomes a bag of strings. A missing *value* is different: it reads as `nil`, because a
value may legitimately be unset.

`Cat` scopes into a declared category and returns a register rooted there, the same
move as `Src:Local(domain)` scoping the bus. Under a category declared
`Dynamic = true`, `Cat` creates. Under any other, it refuses.

## Replication and authority

The five mutation verbs are the wire protocol. Each is a path-shaped delta:

```lua
{ Op = "Edit", Reg = "Session", Owner = player, Path = "Stats.Health", Value = 92 }
```

Reads never replicate, which is why `Access` and `Bubble` sit outside that set. Clients
apply deltas and never receive a whole table after boot.

A client mutation is a request. The server checks the path against `Policies`, applies
it, and echoes the authoritative delta.

| Policy | Who may write |
| --- | --- |
| `"Server"` | Only the server. |
| `"Owner"` | The owning client, or the server. |
| *(unmatched)* | Only the server. |

The default matters: **a path matching no policy is server-only**, so forgetting a
policy fails closed rather than open. The longest matching prefix wins, so
`["Stats.*"]` and `["Stats.Cosmetic.*"]` can differ.

Every verb returns a promise on both sides, already resolved on the server, so a
side-split Service can move sides without a rewrite.

The client mirror does not move until the server echoes. Opt into prediction per call:

```lua
Reg:Swap("Settings.Volume", 8, { Predict = true })
```

The value applies locally at once and rolls back if the server refuses. It is off by
default because a silent rollback is worse than a frame of latency for most things.

A client-requested `Cat` obeys `Dynamic`. Only the server's own echo is trusted to
create a category anywhere. Otherwise a client could grow the tree without limit.

## Bubbling

A change notifies the exact path and every ancestor category, so one watcher covers a
subtree:

```lua
Reg:Bubble("Stats", function(value, path, op)
    -- path = "Stats.Health", op = "Edit", value = 92
end)
```

The handler is told where the change happened, so a subtree watcher can tell one leaf
from another. `Bubble` returns an unsubscribe function.

## Persistence

`Persist = true` writes through a backend you supply:

```lua
Trellis.Configure({
    Hierarchy = { … },
    Store = {
        Load    = function(key) return … end,
        Save    = function(key, value) end,
        Release = function(key) end,   -- optional
    },
})
```

[Coffer](https://github.com/VALENCERBLX/Coffer) is one, ready made:

```lua
Store = Coffer.Backend()
```

Keys are `Session` for a global register and `Session/<UserId>` for an owned one. A
register hydrates on first open, and flushes when the player leaves and again on
`app:Stop`. Flushing happens before the tree is dropped and before modules are torn
down, since a module's `:Stop` may set the last value worth keeping.

Only values are saved, never the category shape. A stored blob therefore cannot
resurrect a category you have since removed from the map, and a category you have since
added simply appears empty. Values under a `Dynamic` category are restored with it.

Since a hydrated register may already hold data, seed defaults conditionally:

```lua
function SessionManager:PlayerAdded(player)
    local reg = self:Reg("Session", player)
    if reg:Access("Stats.Health") == nil then
        reg:New("Stats.Health", 100)
    end
end
```

---

# Capabilities

A module declares what it needs through `Req`. The deployment decides how much of it
through `BootOrder.Config`.

```lua
local CombatManager = {}
CombatManager.Req = { "Heart", "Fence", "Trove" }
```

```lua
-- BootOrder
Config = {
    CombatManager = { Hz = 30, Fences = { "Combat" } },
}
```

## What earns a Req

`Req` is for things that cost something at runtime, or that need per-deployment
configuration. A hook that is merely called once if you defined it costs nothing when
absent and must not need declaring. That rule is what keeps the list from growing.

Needing no `Req`:

| Hook | When |
| --- | --- |
| `:Start(Src)` | In `BootOrder` order. Each is wrapped, so one erroring cannot abort the boot. |
| `:Stop()` | On `app:Stop`, in reverse order. |
| `:Ready()` | Once every module on this side has started. |

`:Ready` is the half of an `Init` phase worth keeping. Trellis has no `:Init`, because
"everything is up now" is the timing question modules actually have, and one hook is
easier to reason about than two.

## The roster

| `Req` | Installs | Config | Side |
| --- | --- | --- | --- |
| `Heart` | `:Heartbeat(dt)` | `Hz` | both |
| `Player` | `:PlayerAdded(p)` / `:PlayerRemoving(p)` | - | server |
| `Tag` | `:TagAdded(inst, tag)` / `:TagRemoved(inst, tag)` | `Tags` | both |
| `Fence` | `:Fence(event, payload, from)` | `Fences` | both |
| `Timer` | `Src:Delay` `:Every` `:Cancel` | - | both |
| `Trove` | `Src.Trove` | - | both |
| `Profile` | every hook wrapped in `debug.profilebegin` | - | both |

Three things are checked at boot: a `Req` whose hook the module never defined, a hook
defined without its `Req` (a warning, since it would never be called), and a `Config`
key tuning a capability the module never asked for. That last one matters most, because
`Hz = 20` on a module without `Req = { "Heart" }` would otherwise do nothing at all,
quietly.

## Heart

```lua
StateManager.Req = { "Heart" }

function StateManager:Heartbeat(dt)
    self.Elapsed += dt
end
```

The module never says how often. `BootOrder` does:

| `Hz` | Driver |
| --- | --- |
| a number | `Heartbeat`, throttled to that rate |
| `"Render"` | `RenderStepped`. Client only; a Manager asking for it is a boot error. |
| `"Step"` | `Stepped` |
| omitted | `Heartbeat`, every frame |

The hook name is the same whatever drives it, so retargeting a module is one word in
one file and no change to the module.

Two things the scheduler does that a module cannot do for itself:

**One connection per driver, for the whole app.** Forty modules cost one `Connect`.

**Staggered phases.** Forty modules at `Hz = 10` would otherwise fire on the same
frame, giving a six-frame spike cycle. Each task's accumulator starts at a different
fraction of its period, using golden-ratio offsets so the spread works for any count
without knowing the count in advance. Measured: twelve modules at `Hz = 10`, busiest
frame carries three.

`dt` on a throttled heartbeat is the accumulated time since that module's last call,
not the frame delta, so integration stays correct at any rate. Internally that needs
two counters. One carries its remainder to keep the average rate exact; the other
measures wall time and zeroes on every call, so each `dt` is counted once. A lag spike
that banks several periods fires once and drops the backlog rather than rapid-firing to
catch up.

## Player

```lua
SessionManager.Req = { "Player" }

function SessionManager:PlayerAdded(player) end
function SessionManager:PlayerRemoving(player) end
```

Either hook alone is enough. At install, players already in the server are replayed
through `:PlayerAdded`. Without that, a module which boots after someone joined misses
them entirely, which is a bug that appears on a populated live server and never once in
Studio.

## Tag

```lua
PickupService.Req = { "Tag" }

function PickupService:TagAdded(instance, tag) end
function PickupService:TagRemoved(instance, tag) end

-- BootOrder.Config: PickupService = { Tags = { "Pickup", "Chest" } }
```

The module says it works on tagged instances; the config says which tags. Existing
tagged instances replay on install, so already-present and streamed-in take one code
path.

`Tag` is what `Body` would have been. CollectionService is universal; `Humanoid`-shaped
characters are not, and a framework should not assume your game has them.

## Fence

`:Fence` returns `(boolean, reason)`, runs on the receiving side, and every fencer on
an event must pass. See [Fences](#fences).

## Timer

```lua
RoundManager.Req = { "Timer" }

self:Delay(30, fn)
local handle = self:Every(1, fn)
self:Cancel(handle)
```

Timers ride the scheduler's clock rather than `task.delay`. They are deterministic
under test, cancel synchronously, and are cancelled for you on `:Stop`. The commonest
leak in Roblox code is a delayed call firing into a torn-down module; this makes it
impossible rather than a matter of discipline. A repeating timer carries its overshoot,
so it keeps its average period.

## Trove

```lua
VfxController.Req = { "Trove" }

function VfxController:Start()
    self.Trove:Add(Instance.new("Beam"))
    self.Trove:Add(workspace.ChildAdded:Connect(fn))
    self.Trove:Add(function() print("bye") end)
end
```

Handles instances, connections, functions, nested troves, and anything with `:Destroy`,
`:Disconnect` or `:Clean`. `:Disconnect` wins over `:Destroy` where both exist, since a
connection that also has `:Destroy` should be disconnected. Cleanup runs in reverse
order, and one erroring item does not stop the rest.

`:Track(item)` returns a remover for a single entry. `:Extend()` returns a nested trove
cleaned with its parent. Adding during teardown cleans immediately rather than leaking.

## Profile

Wraps every hook on the module in `debug.profilebegin("Module.Hook")`. Turn it on for a
suspect module, read the microprofiler, turn it off. The module itself never changes.
`Configure{ Profile = true }` profiles everything at once.

---

# Lifecycle

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

## Stopping and restarting

```lua
app:Stop()
app:Restart()
```

`:Stop` unwinds in reverse: every `:Stop`, then a register flush, then housekeeping
connections, then each `Src` teardown and the injected metatable, then the driver
connections. `:Restart` is that followed by a fresh `Configure`, without leaving Play
mode.

---

# Double-sided Services

A Service can have a client half, and **no part of the server module ever reaches a
client**. Not its `:Start`, not a constant, not a comment.

```
ServerStorage/Modules/Services/TService     the server half, never delivered
ServerStorage/Modules/Workers/TService      the client half, the only thing sent
Client/Modules/Services/TService            optional: receives it via __Recip
```

## How it works

```lua
-- Services/TService, stays on the server
local TService = {}

function TService:Start()
    warn("Is Server? =>", RunService:IsServer())
end

return TService
```

```lua
-- Workers/TService, delivered on join
local Worker = {}

function Worker:__Serve()               -- runs on the CLIENT, from the delivered copy
    local Client = {}
    function Client:Test()
        return "Is Client? " .. tostring(RunService:IsClient())
    end
    return Client
end

return Worker
```

```lua
-- Client/Modules/Services/TService, optional
function TService:__Recip(served) end   -- gets what __Serve built
```

```lua
-- any Controller
Src:GetService("TService"):Test()       --> Is Client? true
```

On join, Trellis clones the **Worker** into that player's `PlayerGui`, which replicates
to them and nobody else. The client requires it and calls `__Serve` there, so the table
it returns is built on that machine and its functions are real rather than something
that had to survive a remote. The client half receives it through `__Recip`, and
anything `__Recip` leaves untouched is copied across.

The result is an ordinary Service. `Src:GetService(name)` reaches it, `Req` and fences
apply, `:Stop` runs on teardown. With no client half at all, what `__Serve` returns is
the Service.

## Which file gets delivered

A Worker of the same name is preferred, and then **only that file is sent**: nothing in
the Service module can reach a client.

Without one, the Service module **itself** is delivered, whole. That is a fine choice
for shared protocol code and a bad one for anything you would mind a player reading, so
Trellis warns about it once at boot and names the Services concerned:

```
[Trellis] delivering these Service modules WHOLE to every player, because they
declare :__Serve and have no Worker: TService.
```

Allowed, never silent. Secrets belong in a **Manager** either way, since those never
replicate under any circumstances.

## Deploying by hand

The same machinery, for code that should reach only some clients:

```lua
Src:Deploy("Scout", player)     -- one player, via PlayerGui
Src:Deploy("Scout", "all")      -- everyone, via ReplicatedStorage
Src:Recall("Scout", player)     -- :Stop, then remove
```

A boss agent for the players in that arena, a tutorial agent for new accounts, a debug
agent for staff. Clients who never qualify never receive the module.

A client that **does** receive a Worker can read that Worker, as it can read any code it
runs. So a Worker holds client logic and nothing else.

---

# Working with it

## Diagnostics

```lua
app:Report()    -- routes with their real listeners, fences, registers, traffic
app:Inspect()   -- the same thing as data
app:Log():Dump()
app:Restart()
```

`Configure{ Panel = true }` builds a live panel on the client, toggled with **F4**.
`Configure{ Log = true }` keeps a ring buffer of the last events per path, summarized
by shape rather than by reference so it cannot pin payloads in memory. `:Dump()` is
what you paste into a bug report.

## Testing

`Trellis.__Tenv_` boots a whole app with no Roblox instances: plain-Lua channels, fake
players, and a clock you advance by hand. It runs under Lune, so your game's modules
are testable and not only the framework's.

```lua
local T = Trellis.__Tenv_({
    Side      = "Server",
    Junction  = require(Config.Junction),
    BootOrder = require(Config.BootOrder),
    Registers = require(Config.Registers),
    Store     = memoryStore,
    Modules   = {
        Managers = { CombatManager = require(…), SessionManager = require(…) },
        Services = { MemoryService = require(…) },
    },
})
```

`Modules` accepts the same folder names the registry uses: `Controllers`, `Managers`,
`Services`, `Packages`, `Utility`, `Config`. Pass `Bins` for anything else.

This is the same seam the framework's own suite runs on. `Bootstrap` already takes its
IO, its services and its clock as parameters, so the test environment is honest about
what it fakes rather than reimplementing the boot.

**The clock.** Nothing ticks on its own.

```lua
T:Step()          -- one frame at 1/60
T:Step(0.1)       -- one frame of 100ms
T:Wait(2)         -- two seconds of frames
T:Wait(1, 0.01)   -- ...at 100 frames per second
T:Now()
```

Pick a step size that divides your periods cleanly. `T:Wait(1)` at the default 1/60 is
about 0.99999 seconds of accumulated float, which can leave a 0.5s repeating timer one
fire short. `T:Wait(1, 0.01)` does not have that problem.

**The world.**

```lua
local ada = T:Join("Ada")     -- fires PlayerAdded, including backlog replay
T:Leave(ada)                  -- fires PlayerRemoving, flushes persisted registers
T:Tag(instance, "Pickup")     -- fires TagAdded
T:Untag(instance, "Pickup")
```

**The wire.**

```lua
T:Send("Network.Combat.Swing", { Combo = 2 }, ada)  -- as if a client sent it
T:Send("Network.Session.Sync", payload)             -- as if the server did

T:Sent()                          -- everything that left this side
T:Sent("Network.Combat.Hit")      -- filtered by path
T:Clear()

T:Answer("Network.Session.Get", function(payload) return … end)
```

Each packet records its direction (`ToServer`, `ToClient`, `ToAll`, `Invoke`) and its
target player where there is one. `T:Send` to a path that does not exist errors and
lists the real ones.

**Inspecting.**

```lua
T:Get("CombatManager")
T:Reg("Session", ada)
print(T:Report())
print(T:Dump())
T:Stop()
```

**A worked test.**

```lua
local T = Trellis.__Tenv_({ … })

local ada = T:Join("Ada")
assert(T:Reg("Session", ada):Access("Stats.Health") == 100)

T:Send("Network.Combat.Swing", { Combo = 2 }, ada)
assert(#T:Sent("Network.Combat.Hit") == 1)

T:Clear()
T:Send("Network.Combat.Swing", { Combo = 99 }, ada)   -- fails the Schema
assert(#T:Sent("Network.Combat.Hit") == 0)

T:Wait(1, 0.01)
print(T:Dump())
T:Stop()
```

Module tables are mutated by injection, so build fresh ones per environment. Booting
two environments over the same tables trips the "already has a metatable" guard, which
is the guard doing its job.

## The framework's own suite

```sh
./run-tests.sh
```

Twelve files under `tests/`, sharing `tests/harness.luau`, which loads every src module
into one sandboxed environment with a controllable clock and captured warnings.

```lua
local H = require("./harness")
local T = H.suite("Junction")
local Junction = H.src("Junction")

T.check("label", condition, detail)
T.equal("label", actual, expected)
T.near("label", actual, expected, tolerance)
T.throws("label", fn, "fragment of the message")
T.warned("label", "fragment")
T.done()
```

`H.folder` and `H.module` build fake Instances; `H.loader` resolves them. `H.clock`
controls what every module sees as `os.clock`. `H.warnings.take()` drains captured
warnings. Draining is the default, because a test that reads warnings without clearing
them will pass on the previous test's output.

`tests/test-regressions.luau` pins bugs that were shipped once and fixed, each with the
reasoning attached, so a refactor that reintroduces one fails loudly.

## What the suite cannot tell you

Every test stubs `Instance`, `RunService` and the remotes, because Lune cannot run
Roblox networking or physics. Real replication timing, real `WaitForChild` ordering,
real serialization limits and real client behaviour are all out of reach.

For that, run [`dist/Setup.luau`](dist/Setup.luau) in Studio and press Play.

---

# Reference

## Coming from Junky

Trellis is the successor to Junky, which implemented SSJA: Single Script Junction
Architecture.

**What survived.** One `Configure` per side. A declared routing map called the
Junction. A single injected context, with modules never requiring each other. Suffix
classification into Controllers, Managers and Services. Managers in a server-only
container.

**Configure stopped needing six arguments.** `ClassPriority` and `StandalonePriority`
merged into one `BootOrder`, split by concern rather than by role: `Order` is when,
`Config` is how. `Manifest` became a module in the `Config` bin. `Modules` is gone,
because the folders you scanned for modules and the folders your dependencies lived in
were always the same folders.

**The getters are derived.** Junky had three fixed ones. Trellis generates one per bin
from the folder name. This also removed a class of bug: Junky resolved by
`FindFirstChild`, so two modules with the same name in different roots silently picked
one, which is exactly what put a stale `Lume` into production. A duplicate is now a
boot error naming both paths.

**Local events are no longer Bindables**, because `BindableEvent:Fire` serializes and
would strip metatables from any payload carrying a class instance or a promise.

**Router and Network.lua are gone.** With one instance per entry, the channel name never
goes on the wire and every RemoteFunction has its own `OnServerInvoke`. That removed the
Substance dependency too.

**The player argument moved to second, for every transport**, and stopped being a field.

**Guards became Fences**, declared in the map, enforceable by several modules at once,
and carrying a rate budget the framework enforces.

**Capabilities and Registers are new.**

Rough migration order:

1. Move `ClassPriorityMap` and `StandalonePriorityMap` into one `BootOrder`.
2. Move `Junction`, `BootOrder` and `Manifest` into a `Config` folder; delete those
   arguments from both Bootstraps.
3. Add `Kind = "Resolve"` to every request-shaped entry.
4. Collapse repeated `Side` and `Destination` into domain-level `Defaults`.
5. Replace `context:Network(d)` / `context:Local(d)` with the `Src` equivalents.
6. Move the sending player to the second parameter, and collapse varargs into one
   payload table.
7. Convert guards to Fences, adding `Req = { "Fence" }` to whichever module owns each.
8. Add `Schema` to entries that were validating by hand, and delete the hand checks.
9. Run `lune run scripts/types` and annotate `:Start(Src: Generated.Src)`.

## Errors and warnings

| What you did | What you get |
| --- | --- |
| Asked for a missing entry | `no Package named "Nope". known: Lume, Trellis` |
| Mounted a name twice | `duplicate Service "CombatService", mounted from: …` |
| Named a bad destination | `Network.Combat.Swing routes to "CombatMangaer", which is not a module` |
| Posted on a Resolve entry | `Local.Session.Get is Kind "Resolve"; :Post is not one of its verbs` |
| Subscribed to a routed event | `X subscribed to Y, but the Junction routes it to Z, so it will never fire` |
| Defined a hook with no `Req` | `X defines :Heartbeat but never asked for Req "Heart"` |
| Tuned an unasked capability | `BootOrder.Config.X sets Hz, but X never asks for Req "Heart"` |
| Shadowed an injected key | `X defines "Network", which the framework injects. Rename it.` |
| Left a module out of BootOrder | `not in BootOrder, booting last: X` |

## Status

389 tests pass under Lune, and `rojo build` produces a clean model.

Trellis has run inside Roblox: a full game was migrated onto it from Junky and verified
end to end, with a client input crossing the wire through a schema, a fence, a Manager,
a state machine and a session write. The Lune suite still stubs `Instance`,
`RunService` and the remotes, so real replication timing and real serialization limits
remain out of its reach.

```sh
./run-tests.sh
```

---

<div align="center">

**Trellis** · [Valence](https://github.com/VALENCERBLX) · MIT

</div>
