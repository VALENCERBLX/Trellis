# Registers

A register is a replicating tree with declared shape and declared authority.

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

### Edit and Swap are not interchangeable

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

### Only Cat creates a category

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

## Replication

The five mutation verbs are the wire protocol. Each is a path-shaped delta:

```lua
{ Op = "Edit", Reg = "Session", Owner = player, Path = "Stats.Health", Value = 92 }
```

Reads never replicate, which is why `Access` and `Bubble` sit outside that set. Clients
apply deltas and never receive a whole table after boot.

### Authority

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
