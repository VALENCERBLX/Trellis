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
| `Player` | `:PlayerAdded(p)` / `:PlayerRemoving(p)` | — | server |
| `Tag` | `:TagAdded(inst, tag)` / `:TagRemoved(inst, tag)` | `Tags` | both |
| `Fence` | `:Fence(event, payload, from)` | `Fences` | both |
| `Timer` | `Src:Delay` `:Every` `:Cancel` | — | both |
| `Trove` | `Src.Trove` | — | both |
| `Profile` | every hook wrapped in `debug.profilebegin` | — | both |

Three things are checked at boot: a `Req` whose hook the module never defined, a hook
defined without its `Req` (a warning — it would never be called), and a `Config` key
tuning a capability the module never asked for. That last one matters most, because
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
two counters — one that carries its remainder to keep the average rate exact, and one
that measures wall time and zeroes on every call so each `dt` is counted once. A lag
spike that banks several periods fires once and drops the backlog rather than
rapid-firing to catch up.

## Player

```lua
SessionManager.Req = { "Player" }

function SessionManager:PlayerAdded(player) end
function SessionManager:PlayerRemoving(player) end
```

Either hook alone is enough. At install, players already in the server are replayed
through `:PlayerAdded`. Without that, a module which boots after someone joined misses
them entirely — a bug that appears on a populated live server and never once in Studio.

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

See [junction.md](junction.md#fences). The short version: `:Fence` returns
`(boolean, reason)`, runs on the receiving side, and every fencer on an event must
pass.

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
suspect module, read the microprofiler, turn it off — the module itself never changes.
`Configure{ Profile = true }` profiles everything at once.
