# IceVoxel

A fast, Minecraft-style voxel engine for Roblox.

- **Client-side generation in parallel.** Terrain is generated from the world seed on every
  client, inside a pool of Actors (Parallel Luau). The server never sends terrain, only edits.
- **Level of detail.** A quadtree of chunk sizes gives a default view distance of 1024 blocks
  (64 chunks) at roughly 20–45k parts. LOD changes swap in place without holes or flicker.
- **Greedy box meshing.** Blocks become as few Parts as possible; blocks you can never see are
  merged into neighbouring boxes for free, and caves are only meshed when the camera is underground.
- **Blended biomes.** Continents, oceans, beaches, mountain ranges and 8 biomes (tundra, taiga,
  plains, forest, birch forest, savanna, desert, jungle) whose terrain blends smoothly.
- **Caves, ores and structures.** Tunnels and caverns, ore veins, and a deterministic structure
  system (trees and cacti today) that lets anything cross chunk borders.
- **Server-authoritative interaction.** Break and place blocks with client prediction and server
  validation. Block updates power falling sand and gravel, flowing water (Minecraft rules, including
  infinite sources) and grass turning into dirt.

## Getting started

1. Install the toolchain with [Rokit](https://github.com/rojo-rbx/rokit):
   ```sh
   rokit install
   ```
2. Either live-sync into Studio:
   ```sh
   rojo serve
   ```
   and connect with the Rojo Studio plugin, or build a place file and open it:
   ```sh
   rojo build -o IceVoxel.rbxlx
   ```
3. Press Play.

Studio tips:
- Delete the template's `Baseplate`; the world starts at y = 0 and the baseplate only sits under it.
- New places come with an `Atmosphere` in Lighting, which adds haze to the far LOD chunks. Without
  one, IceVoxel uses distance fog at the edge of the view distance instead.
- Studio's graphics quality limits how far parts are drawn. Raise it to see the full view distance.

## Controls

| Action        | Mouse / keyboard            | Gamepad | Touch      |
| ------------- | --------------------------- | ------- | ---------- |
| Break block   | Left click (hold to repeat) | R2      | Tap        |
| Place block   | Right click                 | L2      | Long press |
| Select block  | `1`–`9`, `Q` / `E` to cycle |         |            |
| Debug overlay | `F3`                        |         |            |

## Project layout

```
src/shared   -> ReplicatedStorage.IceVoxel          (used by server, client and worker actors)
  Config                    every tunable setting
  Blocks/  BlockList        block definitions -> ids, appearances, lookup tables
  Biomes/  BiomeList        biome definitions
  Generation/
    TerrainGenerator        heights, biome blending, filling chunks at any LOD
    Noise                   seeded noise on top of math.noise
    Caves, Ores             full detail only
    Structures/             placement + Trees (builders) + Writer (clipping, LOD)
  Meshing/GreedyMesher      blocks -> boxes
  World/                    ChunkLayout, Coords, LodTree, VoxelRaycast
  Net/                      Protocol (buffer encoding), Remotes
  Util/Hash                 deterministic hashing and RNG

src/server   -> ServerScriptService.IceVoxel
  IceVoxel_Server           boot: seed, world, ticker, network, players
  Api                       require this from your own server scripts
  World/                    WorldServer (chunks + edits), BlockTicker, Simulation
  Behaviours/               Gravity, Fluid, Grass (block update logic)
  Network/ServerNet         edit lists, edit validation, replication
  Players/Spawning          spawn point on dry land

src/client   -> StarterPlayerScripts.IceVoxel
  IceVoxel_Client           boot
  World/ClientWorld         nearby block data, edit lists, prediction
  Streaming/                ChunkStreamer (LOD + scheduling), WorkerPool, ChunkWorker (actor)
  Rendering/                ChunkRenderer (boxes -> parts), PartPool
  Interaction/              BlockInteraction, Hotbar
  Player/SpawnGuard         holds the character until the ground exists
  Debug/DebugOverlay        F3 stats

tests/       Lune scripts: unit tests, benchmark, terrain preview
docs/        ARCHITECTURE.md (how everything fits together)
```

How the pieces work together is described in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Configuration

Everything lives in `src/shared/Config.luau`. The settings that matter most for performance:

| Setting                   | Default | Effect                                                              |
| ------------------------- | ------- | ------------------------------------------------------------------- |
| `Lod.ViewDistance`        | 1024    | How far terrain is drawn (blocks).                                  |
| `Lod.SplitDistance`       | 3       | Detail falloff. LOD 0 radius is roughly `2 × SplitDistance` chunks. |
| `Lod.Levels`              | 5       | Coarsest level covers `16 × 2^(Levels-1)` blocks per chunk.         |
| `Workers.Count`           | 6       | Actors generating / meshing in parallel.                            |
| `Render.BuildBudgetMs`    | 4       | Main thread time per frame spent creating parts.                    |
| `Render.Shadows`          | true    | Shadows on full detail chunks (far chunks never cast shadows).      |
| `Caves.RevealRadius`      | 48      | How far around an underground camera caves are meshed.              |
| `StructureMaxLevel`       | 2       | Highest LOD level that still shows trees.                           |

Part count depends on the terrain: flat land costs ~35 parts per full detail chunk, steep
mountains ~120. Measured view from spawn with the default settings: 19k parts on seed 12345
(plains), 45k on seed 777 (mountain taiga). For phones, try `ViewDistance = 512` and
`SplitDistance = 2`, which roughly halves that (10k and 25k on the same seeds).

`Seed = nil` gives every server a random world; set a number for a fixed one.

## Extending

**A block.** Append an entry to `src/shared/Blocks/BlockList.luau` (at the end: ids are list
positions and saved edits depend on them):

```lua
table.insert(list, { name = "Marble", color = { 235, 235, 230 }, material = "Marble" })
```

It is immediately placeable from the hotbar. Blocks that look identical share one part template.

**A biome.** Add an entry to `src/shared/Biomes/BiomeList.luau` with a climate position
(temperature, humidity), terrain shape (`heightOffset`, `hilliness`), surface blocks and
vegetation. Terrain shape blends with neighbouring biomes automatically.

**A structure.** Write a builder in `Generation/Structures/` (see `Trees.luau`), register it in
`Structures.registry` with the blocks it may grow on, and list it in a biome's `features`. Builders
write in world coordinates; chunk clipping, cross-chunk consistency and LOD are handled for you.

**A block behaviour.** Create a module in `src/server/Behaviours/` (see `Gravity.luau`) with
`onTick(world, ticker, x, y, z, block)` and set `behaviour = "YourModule"` on the block.

**Server-side world access** from your own scripts:

```lua
local IceVoxel = require(game.ServerScriptService.IceVoxel.Api)
local Blocks = require(game.ReplicatedStorage.IceVoxel.Blocks)

local world = IceVoxel.waitForWorld()
world:setBlock(10, 80, 10, Blocks.id.Stone) -- replicated to every client, triggers block updates
print(world:getBlock(10, 80, 10))
```

## Development

The engine's core is pure Luau, so most of it runs and is tested outside Roblox with
[Lune](https://github.com/lune-org/lune):

```sh
lune run tests/run                    # unit tests (generation, meshing, LOD, protocol, block updates)
lune run tests/bench [seed]           # generation / meshing speed and part count estimate
lune run tests/preview [seed] [blocksPerPixel] [pixels]   # top-down map in tests/out/preview.ppm
```

Formatting, linting and type checking:

```sh
stylua src tests
selene src
rojo sourcemap default.project.json -o sourcemap.json
luau-lsp analyze --platform=roblox --sourcemap=sourcemap.json \
    --definitions=@roblox=path/to/globalTypes.d.luau src
```

(`globalTypes.d.luau` comes from the [luau-lsp repository](https://github.com/JohnnyMorganz/luau-lsp/tree/main/scripts).)

## Roadmap

Natural next steps, roughly in order:

- **Persistence.** Edits live in memory (`WorldServer.edits`); save them per chunk to a DataStore.
- **Edits in LOD chunks.** Far chunks show generated terrain only; player builds appear once in
  full detail range.
- **Swimming.** Water is drawn and flows, but characters fall through it.
- **Bigger structures.** Villages / dungeons using the same stateless placement with a larger grid.
- **Parallel server generation.** The server generates chunks on its main thread (one per frame).
- **Mesher.** Try both X-first and Z-first growth and keep the smaller result.
- **Floating origin** for worlds far beyond ±100k studs.
