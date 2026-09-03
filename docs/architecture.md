# Architecture

Trellis is a subset of Single Script Architecture. It keeps SSA's three guarantees
(one Bootstrap per side, one declared routing map, one shared context) and drops the
parts that were bookkeeping.

## The five pieces

| Module | Owns |
| --- | --- |
| `Registry` | The hierarchy. Mounts bins, generates getters, resolves lazily. |
| `Junction` | The routing map. Parses, validates, materializes instances. |
| `Src` | The injected context. The only surface a module talks through. |
| `Reg` | The register tree, its deltas, its policies, its persistence. |
| `Bootstrap` | `Configure`. Owns the order everything happens in. |

Supporting them: `Scheduler` (one connection per driver, timers), `Schema` (payload
shapes), `Trove` (cleanup), `Log` (event ring buffer), `Inspect` (topology),
`Reaction` (promises), `Tenv` (the test environment).

`Reaction` is deliberately self-contained so the framework has no hard dependency. Its
verb set matches Accede's, PascalCased, so swapping it is a one-line require change.

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
of a silent nothing. A destination whose suffix is none of the three is rejected outright,
which catches the common case where the typo lands *in* the suffix (`CombatMangaer`).

## Boot order

`Configure` runs twelve steps, and the order carries real weight.

1. **Side.** From `RunService`.
2. **Registry.** Walk `Hierarchy`, mount bins, apply `Inject`. A name mounted twice is
   recorded rather than thrown, so step 4 gets one chance to reconcile a
   double-sided Service; anything unreconciled throws when something asks for it.
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

`app:Stop()` unwinds in reverse: every `:Stop`, then a register flush, then
housekeeping connections, then each `Src` teardown and the injected metatable, then the
driver connections. `app:Restart()` is that followed by a fresh `Configure`.

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
- `BootOrder` naming a module that is not here, or naming one twice
- `BootOrder.Config` tuning a capability the module never asked for
- two modules with the same name, unless they are a `__Serve` / `__Recip` pair

And two warnings, for things that are legal but almost certainly wrong: a hook defined
without its `Req` (it will never be called), and a module subscribing to an event the
Junction routes elsewhere (it will never fire).
