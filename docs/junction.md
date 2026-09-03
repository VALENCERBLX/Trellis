# The Junction

One map declares every event in the game.

```lua
Junction.<Namespace>.<Domain>.<Event> = { entry }
```

`Namespace` is `Network`, `Local` or `Fence`. Domains group events; the domain is what
`Src:Local(domain)` and `Src:Network(domain)` bind to.

## Entry fields

| Field | Default | Meaning |
| --- | --- | --- |
| `Kind` | `"Static"` | `"Static"` is an Event, `"Resolve"` is a Function. |
| `Destination` | none | Delivery filter. Only that module's subscribers receive it. |
| `Side` | both | `"Server"` or `"Client"`. Local entries only. |
| `Schema` | none | The payload shape, checked at the edge. |
| `Instanced` | `false` | Local entries only: use a real Bindable. |

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

`Defaults` is the only reserved key, so no event may be named `Defaults`.

## Transports

```lua
class = (namespace == "Local" and "Bindable" or "Remote") .. (Static and "Event" or "Function")
```

| | `Kind = "Static"` | `Kind = "Resolve"` |
| --- | --- | --- |
| `Junction.Local` | BindableEvent | BindableFunction |
| `Junction.Network` | RemoteEvent | RemoteFunction |

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

One instance per entry rather than one multiplexed remote, for three reasons. The
channel name leaves the wire. A RemoteFunction has exactly one `OnServerInvoke`, so
multiplexing forces a hand-rolled responder table. Per-entry instances also make "two
modules answered the same event" a boot error instead of last-writer-wins. And the
Explorer shows the topology while the game runs.

### Local entries are not Bindables

`BindableEvent:Fire` serializes its arguments. Tables are deep-copied, metatables
stripped, table identity lost, mixed keys mangled. A Local event carrying a state
machine, a class instance or a promise breaks silently. Local entries are therefore
plain-Lua signals: same surface, no copy, faster. Set `Instanced = true` on an entry
when you want the Explorer node or a third-party script hooking in.

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
