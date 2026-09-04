# dist

Two paste-in scripts. Neither needs Wally, rojo or a toolchain.

## Install the framework

`Adeal.luau` carries every module inline and rebuilds `ReplicatedStorage.Trellis`.
Nothing else in the place is touched, so re-running it upgrades the framework and
leaves your game alone.

Paste the file into the Studio command bar, or fetch it (Game Settings > Security >
Allow HTTP Requests):

```lua
local h = game:GetService("HttpService")
loadstring(h:GetAsync("https://raw.githubusercontent.com/VALENCERBLX/Trellis/master/dist/Adeal.luau"))()
```

`Adeal.luau` is generated from `src/`. Regenerate it with:

```sh
lune run scripts/build-dist
```

`tests/test-dist.luau` reruns the generated installer against fake Instances and
compares every module byte for byte, so a stale dist fails the suite rather than
shipping.

## Lay out a project

`Setup.luau` creates the module folders, the `Config` module with its children, the
shared `Bootstrap`, and the two entry points (`ServerInit` and `Init`).

```lua
local h = game:GetService("HttpService")
loadstring(h:GetAsync("https://raw.githubusercontent.com/VALENCERBLX/Trellis/master/dist/Setup.luau"))()
```

It never overwrites. Folders already present are reused, and any script or module
that already exists is left alone, so re-running only fills in what is missing. It
prints what it created and what it skipped.

What you end up with:

```
ReplicatedStorage/
  Trellis
  Shared/
    Assets/     Interface  Audio  Models  Builds
    Classes/    __NameOfClassFolder__/__NameOfClass__
    Modules/
      Packages/
      Services/
      Utilities/
        Bootstrap      the layout, read by both entry points
        Config/        Junction  BootOrder  Registers  Manifests
  Client/
    Modules/    Controllers  Services  Packages  Utilities

ServerStorage/
  Modules/      Managers  Services  Packages  Utilities

ServerScriptService/ServerInit      Script
StarterPlayerScripts/Init           LocalScript
```

`Assets` and `Classes` hold content rather than modules, so they stay out of the
Hierarchy and are reached through resolver bins that `Bootstrap` declares:

```lua
Src:GetClass("Characters.Superman")
Src:GetAsset("HealthBar")
```

## Then

Press Play. The boot is silent, because nothing is declared yet. Write a Manager in
`ServerStorage/Modules/Managers`, a Controller in
`ReplicatedStorage/Client/Modules/Controllers`, and declare the events they use in
`Config/Junction`.

For a place that already runs and proves each subsystem, use
[`scripts/Scaffold.lua`](../scripts/Scaffold.lua) instead. It lays down a working
demo game and prints a pass/fail line per subsystem on Play.
