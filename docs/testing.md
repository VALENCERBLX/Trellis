# Testing

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

This is the same seam the framework's own suite runs on — `Bootstrap` already takes its
IO, its services and its clock as parameters — so the test environment is honest about
what it fakes rather than reimplementing the boot.

## The clock

Nothing ticks on its own. Heartbeats and timers advance only when you say so.

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

## The world

```lua
local ada = T:Join("Ada")     -- fires PlayerAdded, including backlog replay
T:Leave(ada)                  -- fires PlayerRemoving, flushes persisted registers
T:Tag(instance, "Pickup")     -- fires TagAdded
T:Untag(instance, "Pickup")
```

## The wire

```lua
T:Send("Network.Combat.Swing", { Combo = 2 }, ada)  -- as if a client sent it
T:Send("Network.Session.Sync", payload)             -- as if the server did

T:Sent()                          -- everything that left this side
T:Sent("Network.Combat.Hit")      -- filtered by path
T:Clear()

T:Answer("Network.Session.Get", function(payload) return … end)
```

Each packet records its direction — `ToServer`, `ToClient`, `ToAll`, `Invoke` — and its
target player where there is one. `T:Send` to a path that does not exist errors and
lists the real ones.

## Inspecting

```lua
T:Get("CombatManager")
T:Reg("Session", ada)
print(T:Report())    -- routes, listeners, fences, registers, traffic
print(T:Dump())      -- the event transcript
T:Stop()
```

## A worked test

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

Ten files under `tests/`, sharing `tests/harness.luau`, which loads every src module
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
warnings — draining is the default, because a test that reads warnings without clearing
them will pass on the previous test's output.

`tests/test-regressions.luau` pins bugs that were shipped once and fixed, each with the
reasoning attached, so a refactor that reintroduces one fails loudly.

## What the suite cannot tell you

Every test stubs `Instance`, `RunService` and the remotes, because Lune cannot run
Roblox networking or physics. Real replication timing, real `WaitForChild` ordering,
real serialization limits and real client behaviour are all out of reach.

For that, paste `scripts/Scaffold.lua` into the Studio command bar and press Play. It
lays down a working game and prints a pass/fail line per subsystem from both sides.
