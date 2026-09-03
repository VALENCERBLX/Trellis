# Src

`Src` is what a Controller, Manager or Service receives. It arrives twice: as the
`:Start` argument, and mirrored onto the module itself through `__index`. That second
delivery is why `self:Local("Input")` works from any method, and why no module needs
the `self._ctx = ctx` line that every SSA framework otherwise collects.

Injection is a privilege of the three roles. Packages, Utilities and Config modules
receive nothing. They are plain modules pulled through the getters, which is what
keeps them reusable across projects.

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

## Dependencies

Two views of one lazy cache:

```lua
Src.Main.Packages.Lume  ==  Src:GetPackage("Lume")
Src.Main.Utility.Maid   ==  Src:GetUtility("Maid")
```

`Main` is keyed by the container name as it appears in your tree; the getter is keyed
by the singular bin name. `Main` is frozen, so containers cannot be replaced and entries
cannot be written. Iterating a container walks its modules.

Each bin generates `Get<Bin>`, `Has<Bin>` and `List<Bin>`. `Has` is a soft miss
returning `false`; `Get` on a missing entry errors and lists the known names.

## The bus

```lua
local Combat = Src:Network("Combat")
local Input  = Src:Local("Input")
```

A scope is bound to one namespace and one domain, and validates event names against
the Junction when you bind. Scopes are cached per `Src`, so calling `Src:Network("Combat")`
repeatedly is free.

### Static entries

```lua
Combat:Post("Hit", payload)
Combat:Subscribe("Hit", function(payload, from) end)   --> unsubscribe
Combat:Once("Hit", handler)

Combat:PostTo(player, "Hit", payload)      -- server only
Combat:PostAll("Hit", payload)             -- server only
Combat:PostExcept(player, "Hit", payload)  -- server only
```

Direction is implicit in the side. On the client, `:Post` goes up to the server. On the
server it goes down to every client; `:PostTo` targets one.

### Resolve entries

```lua
Combat:Resolve("Query", payload):Next(print):Toss(warn)
Combat:Respond("Query", function(payload, from) return answer end)

Combat:ResolveFrom(player, "Query", payload, { Timeout = 5 })   -- server only
```

`:Resolve` on the server is an error telling you to use `:ResolveFrom`, since there is
no single peer. `:ResolveFrom` carries a mandatory ten second default timeout, because
`RemoteFunction:InvokeClient` blocks until that client answers and a hung or hostile
client would otherwise strand a server thread indefinitely.

### The handler contract

```lua
function(payload, from)
```

`from` is the sending Player, or `nil` when the event originated on this side. It is a
parameter and never a field: `Src` is a per-module singleton, so a shared slot would be
overwritten by the next event whenever a handler yields, and this is the value
authority is gated on. The shape is identical across all four transports.

```lua
Combat:Subscribe("Swing", function(payload, from)
    if from then
        -- a client sent this. untrusted.
    else
        -- internal. trusted.
    end
end)
```

### Destination filtering

`Destination` filters delivery; it does not set direction. Only subscribers owned by
the named module receive the event. Subscribing to an event routed elsewhere is always
a mistake, so it warns at bind time naming both modules rather than silently never
firing.

## Registers

```lua
Src:Reg("Round")            -- a global register
Src:Reg("Session", player)  -- server: whose
Src:Reg("Session")          -- client: implicitly yours
```

See [registers.md](registers.md).

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
Name  Role  Side  Player  Main  Local  Network  Reg  Await  OnCleanup
Inspect  Trove  Delay  Every  Cancel  Get*  Has*  List*
```

`Req` is read before injection, so it stays yours. `Hz`, `Tags` and `Fences` live in
`BootOrder` and are never injected.
