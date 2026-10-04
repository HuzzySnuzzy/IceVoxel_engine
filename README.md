# IceVoxel

A fast, Minecraft-style voxel engine for Roblox.

- **Client-side generation in parallel.** Terrain is generated from the world seed on every
  client, inside a pool of Actors (Parallel Luau). The server never sends terrain, only edits.
- **Level of detail.** A quadtree of chunk sizes gives a default view distance of 2048 blocks
  (128 chunks) at roughly 25–50k parts. Far chunks use cells up to 64 blocks wide (but at most 16
  tall, so mountains keep their shape). LOD changes swap in place without holes or flicker.
- **Greedy box meshing.** Blocks become as few Parts as possible; blocks you can never see are
  merged into neighbouring boxes for free, and caves are only meshed when the camera is underground.
- **Blended biomes.** Continents, oceans, beaches, mountain ranges and 8 biomes (tundra, taiga,
  plains, forest, birch forest, savanna, desert, jungle) whose terrain blends smoothly.
- **Caves, ores and structures.** Tunnels and caverns, ore veins, and a deterministic structure
  system (trees and cacti today) that lets anything cross chunk borders.
- **Server-authoritative interaction.** Break and place blocks with client prediction and server
  validation. Block updates power falling sand and gravel, flowing water (Minecraft rules, including
  infinite sources) and grass turning into dirt.
- **Water you can see flow and swim in.** Flowing water steps down level by level like Minecraft,
  currents push the player downstream, and you can swim (float, sink slowly, hold Jump to rise).
- **Minimap and world map.** Painted straight from the generator, so the map shows the whole world.
  Right click the map to add waypoints (saved between sessions), teleport, or center the view.
- **Safe spawns.** Spawns and teleports never land in water, on leaves or next to cacti; the rules
  live in `SpawnUnsafeBlocks`.
- **Textures.** Optional per-block textures through MaterialVariants, tiled once per block.

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
- How far parts are drawn is up to the engine, not the script: it depends on the graphics quality
  level and how many objects are on screen. Studio ignores that limit, so judge long views in the
  Roblox player with a high graphics level. Phones draw far less (a few hundred studs), which is why
  they get a shorter view distance (`Lod.Mobile`).

## Controls

| Action        | Mouse / keyboard            | Gamepad | Touch      |
| ------------- | --------------------------- | ------- | ---------- |
| Break block   | Left click (hold to repeat) | R2      | Tap        |
| Place block   | Right click                 | L2      | Long press |
| Select block  | `1`–`9`, `Q` / `E` to cycle |         |            |
| Swim up       | Hold `Space` in water       | A       | Jump button |
| World map     | `M`, or click the minimap   |         | Tap minimap |
| Map menu      | Right click the map         | R3      | Long press |
| Minimap zoom  | `-` / `=`                   |         |            |
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
  Map/MapPainter            map tile colours from the generator (runs in the workers)
  World/                    ChunkLayout, Coords, LodTree, VoxelRaycast, FluidFlow
  Net/                      Protocol (buffer encoding), Remotes
  Util/Hash                 deterministic hashing and RNG

src/server   -> ServerScriptService.IceVoxel
  IceVoxel_Server           boot: seed, world, ticker, network, players
  Api                       require this from your own server scripts
  World/                    WorldServer (chunks + edits), BlockTicker, Simulation
  Behaviours/               Gravity, Fluid, Grass (block update logic)
  Network/ServerNet         edit lists, edit validation, replication
  Players/                  Spawning, SafeSpot + SpawnUnsafeBlocks (safety rules),
                            Teleport (map), WaypointStore (DataStore)

src/client   -> StarterPlayerScripts.IceVoxel
  IceVoxel_Client           boot
  World/ClientWorld         nearby block data, edit lists, prediction
  Streaming/                ChunkStreamer (LOD + scheduling), WorkerPool, ChunkWorker (actor)
  Rendering/                ChunkRenderer (boxes -> parts), PartPool
  Interaction/              BlockInteraction, Hotbar
  Map/                      MapLayer (EditableImage ring), MapView, Minimap, WorldMap,
                            Waypoints, ContextMenu
  Net/ClientNet             routes server messages
  Player/                   SpawnGuard (holds the character until the ground exists),
                            WaterController (swimming, currents)
  Debug/DebugOverlay        F3 stats

tests/       Lune scripts: unit tests, benchmark, terrain preview
docs/        ARCHITECTURE.md (how everything fits together)
```

How the pieces work together is described in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Configuration

Everything lives in `src/shared/Config.luau`. The settings that matter most for performance:

| Setting                   | Default | Effect                                                              |
| ------------------------- | ------- | ------------------------------------------------------------------- |
| `Lod.ViewDistance`        | 2048    | How far terrain is drawn (blocks).                                  |
| `Lod.Mobile`              | 512 / 2 | View / split distance on phones and tablets.                        |
| `Lod.SplitDistance`       | 3       | Detail falloff. LOD 0 radius is roughly `2 × SplitDistance` chunks. |
| `Lod.Levels`              | 7       | Coarsest level covers `16 × 2^(Levels-1)` blocks per chunk.         |
| `Lod.MaxVerticalStep`     | 16      | Tallest LOD cell in blocks (keeps far mountains shaped).            |
| `Workers.Count`           | 6       | Actors generating / meshing in parallel.                            |
| `Render.BuildBudgetMs`    | 4       | Main thread time per frame spent creating parts.                    |
| `Render.Shadows`          | true    | Shadows on full detail chunks (far chunks never cast shadows).      |
| `Caves.RevealRadius`      | 48      | How far around an underground camera caves are meshed.              |
| `StructureMaxLevel`       | 2       | Highest LOD level that still shows trees.                           |
| `Render.Textures`         | true    | Use block textures (MaterialVariants / face images) when defined.   |
| `Map.Teleport`            | true    | Who may teleport from the map: everyone, nobody, or a user id list. |
| `Map.SaveWaypoints`       | true    | Keep waypoints between sessions (DataStore).                        |

Part count depends on the terrain: flat land costs ~35 parts per full detail chunk, steep
mountains ~120. Most parts are near the player; doubling the view distance adds comparatively
few. Measured view from spawn (`lune run tests/bench <seed> <viewDistance> [splitDistance]`):

| Seed              | 512 (mobile) | 1024 | 2048 (default) | 4096 |
| ----------------- | ------------ | ---- | -------------- | ---- |
| 12345 (plains)    | 9k           | 19k  | 25k            | 34k  |
| 777 (mountains)   | 24k          | 45k  | 49k            | 59k  |

Keep the playable area within about ±16,000 studs (±5,000 blocks) of the origin: further out,
float precision makes parts and characters jitter.

`Seed = nil` gives every server a random world; set a number for a fixed one.

## Extending

**A block.** Append an entry to `src/shared/Blocks/BlockList.luau` (at the end: ids are list
positions and saved edits depend on them):

```lua
table.insert(list, { name = "Marble", color = { 235, 235, 230 }, material = "Marble" })
```

It is immediately placeable from the hotbar. Blocks that look identical share one part template.

**Block textures.** Blocks already use Roblox materials (Slate, Grass, Sand...), which have
built-in textures. For your own, per-block textures use a MaterialVariant per block:

1. In Studio open the Material Manager (Model tab) and create a variant, e.g. `IV_Stone`, with the
   block's material as Base Material (Stone uses `Slate`), your uploaded images as Color (and
   optionally Normal / Roughness) maps, **Studs Per Tile = 3** (the block size, so one tile covers
   one block face) and **Pattern = Regular**. Scripts cannot create textured variants at runtime;
   they have to be authored in Studio (or synced by Rojo, below).
2. Point the block at it in `BlockList.luau`:
   ```lua
   { name = "Stone", color = { 125, 125, 128 }, material = "Slate", texture = "IV_Stone" },
   ```
   `color` still colours the map; the part is tinted with `tint` (default white, i.e. the
   texture's own colours). A missing variant just prints a warning and keeps the plain material.
3. Different faces, e.g. a grass top on a dirt-textured block: `faces = { Top = "rbxassetid://..." }`.
   Each face image is one extra instance per part, so it is only drawn on full detail chunks.

With Rojo the variants can live in the project instead:

```json
"MaterialService": {
  "IV_Stone": {
    "$className": "MaterialVariant",
    "$properties": {
      "BaseMaterial": "Slate",
      "ColorMap": "rbxassetid://YOUR_IMAGE_ID",
      "StudsPerTile": 3,
      "MaterialPattern": "Regular"
    }
  }
}
```

(add it inside `"tree"` in `default.project.json`; Rojo 7.5+ also accepts `ColorMapContent`). Check
the tile alignment once in Studio: a 9-stud and three 3-stud parts next to each other should show
identical tiles.

**Spawn safety.** `src/server/Players/SpawnUnsafeBlocks.luau` lists what a player must not stand on
(`Floor`), stand in (`Body`, fluids by name) or touch (`Hazards`), plus the headroom and search
radius. Spawns and map teleports search outward for the closest spot that passes, and never put
players below the natural surface (caves).

**The map.** The minimap and world map draw terrain with EditableImage. That API works in Studio
right away, but **published games** need the experience owner to be 13+ and ID verified and to turn
on *Enable Mesh / Image APIs* (Creator Dashboard, experience settings). Without it the maps still
show players and waypoints, and the right click menu still works. Teleporting is controlled by
`Config.Map.Teleport` and checked by the server.

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

- **Persistence.** Edits live in memory (`WorldServer.edits`); save them to a DataStore per region
  of 32 × 32 chunks (see "regions" in docs/ARCHITECTURE.md).
- **Edits in LOD chunks and on the map.** Far chunks and the map show generated terrain only; player
  builds appear once in full detail range.
- **Exact cave culling.** Replace the "camera below the surface" rule with Minecraft-style section
  connectivity (docs/ARCHITECTURE.md, "Hidden caves, octrees and regions").
- **Bigger structures.** Villages / dungeons using the same stateless placement with a larger grid.
- **Parallel server generation.** The server generates chunks on its main thread (one per frame).
- **Mesher.** Try both X-first and Z-first growth and keep the smaller result.
- **Floating origin** for play far beyond ±16k studs, where float precision starts to show.
