# Structure templates

ModuleScripts in this folder (any depth) each return one IVS1 string, or a list of them, as a
Structure Block's SAVE gives them (StringValues holding IVS1 data work here too):

```lua
return "IVS1:..."
```

```lua
return {
	"IVS1:...",
	"IVS1:...",
}
```

A template's name is inside its data (for example `outpost/houses/hut_1`), not the module's
name. Names with slashes make implicit template pools: the pool `outpost/houses` is every
template named `outpost/houses/...` (see `../Pools.luau`). `lune run tests/structure decode <data>`
prints a template. Rojo ignores this file, so the folder exists even when it holds no templates.
