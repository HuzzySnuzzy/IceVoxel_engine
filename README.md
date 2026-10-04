# IceVoxel

A fast, Minecraft-style voxel engine for Roblox.

- **Client-side generation in parallel.** Terrain is generated from the world seed on every
  client, inside a pool of Actors (Parallel Luau). The server never sends terrain, only edits.
- **Level of detail.** A quadtree of chunk sizes gives a default view distance of 2048 blocks
  (128 chunks). Far chunks use cells up to 64 blocks wide (but at most 16 tall, so mountains keep
  their shape). LOD changes swap in place without holes or flicker.
- **Greedy box meshing.** Blocks become as few Parts as possible; blocks you can never see are
  merged into neighbouring boxes for free, and caves are only meshed when the camera is underground.
- **Terrain like JJThunder To The Max.** A 1024 block tall world in the style of the Minecraft
  datapack: mountain ranges up to ~900 blocks high with snowy peaks, eroded flanks and plateau
  hills, plains, wide river valleys and enclosed seas with islands. Its height functions are ported
  directly and scaled to fit. 18 biomes are picked by altitude band (lowland, forest, highland,
  meadow, alpine, snowy slopes, peaks), then by climate.
- **Caves, ores and structures.** Dry caves that grow with depth, from tunnels to huge stratified
  caverns, and the Underlands: a cavern hundreds of blocks tall under the highest mountains. Ores and
  stone varieties by altitude, and a deterministic structure system (trees and cacti today) that
  lets anything cross chunk borders.
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
- **Far meshes.** Regions of distant chunks that stopped changing are merged into a few MeshParts
  built with EditableMesh ("superchunks"), replacing thousands of parts: at the default view,
  83k parts become 36k parts + 90 meshes in the mountains. Parts stay the fallback, so nothing breaks
  where the Mesh APIs are unavailable.

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
| Select block  | `1`–`9`, `Q` / `E` to cycle, or click a slot | L1 / R1 | Tap a slot, ‹ › pages |
| Swim up       | Hold `Space` in water       | A       | Jump button |
| Climb out     | Hold `Space` and walk at a ledge | A + stick | Jump + move |
| World map     | `M`, or click the minimap   |         | Tap minimap |
| Map menu      | Right click the map         | R3      | Long press |
| Minimap zoom  | `-` / `=`                   |         |            |
| Debug overlay | `F3`                        |         |            |

## Project layout

```
src/shared   -> ReplicatedStorage.IceVoxel          (used by server, client and worker actors)
  Config                    every tunable setting
  Blocks/  BlockList        block definitions -> ids, appearances, lookup tables
  Biomes/  BiomeList        biome definitions and altitude bands
  Generation/
    TerrainGenerator        biomes, surfaces, filling chunks at any LOD
    Relief                  terrain heights (JJThunder To The Max style)
    Noise                   seeded noise on top of math.noise
    Caves, Ores             full detail only
    Structures/             placement + Trees (builders) + Writer (clipping, LOD)
  Meshing/GreedyMesher      blocks -> boxes (parts)
  Meshing/QuadMesher        blocks -> faces (meshes); MeshGeometry: faces -> mesh arrays
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
  Rendering/                ChunkRenderer (boxes -> parts), PartPool, ViewSettings,
                            MeshOverlay + MeshRegions (far meshes)
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
| `Lod.SplitDistanceL1`     | 3       | Same for full detail only; 2 = ~12% fewer parts in mountains.       |
| `Lod.Levels`              | 7       | Coarsest level covers `16 × 2^(Levels-1)` blocks per chunk.         |
| `Lod.MaxVerticalStep`     | 16      | Tallest LOD cell in blocks (keeps far mountains shaped).            |
| `Workers.Count`           | 6       | Actors generating / meshing in parallel.                            |
| `Render.BuildBudgetMs`    | 4       | Main thread time per frame spent creating parts.                    |
| `Render.Shadows`          | true    | Shadows on full detail chunks (far chunks never cast shadows).      |
| `Caves.RevealRadius`      | 48      | How far around an underground camera caves are meshed.              |
| `Caves.RevealRadiusMax`   | 96      | Same in big caverns (the radius follows the open space around you). |
| `StructureMaxLevel`       | 2       | Highest LOD level that still shows trees.                           |
| `Render.Textures`         | true    | Use block textures (MaterialVariants / face images) when defined.   |
| `Render.FarMeshes`        | on (PC) | Merge stable far regions into meshes (see Far meshes below).        |
| `Map.Teleport`            | true    | Who may teleport from the map: everyone, nobody, or a user id list. |
| `Map.SaveWaypoints`       | true    | Keep waypoints between sessions (DataStore).                        |

Part count depends on the terrain: flat land costs ~35 parts per full detail chunk, steep
mountains ~110. Most parts are near the player; doubling the view distance adds comparatively
few. Measured views (`lune run tests/bench <seed> <viewDistance> [splitDistance] [splitL1] [x z]`,
seed 12345; "mountains" is inside a range at 3200, -14600):

| View from         | 512 (mobile) | 1024 | 2048 (default) | 4096 |
| ----------------- | ------------ | ---- | -------------- | ---- |
| spawn (hills)     | 14k          | 28k  | 34k            | 46k  |
| mountains         | 29k          | 68k  | 83k            | 99k  |

With far meshes, once every region near the player has settled (the bench prints this too):

| View from         | 2048 (default)          | 4096                     |
| ----------------- | ----------------------- | ------------------------ |
| spawn (hills)     | 16.7k parts + 88 meshes | 20.6k parts + 187 meshes |
| mountains         | 35.5k parts + 90 meshes | 40.1k parts + 191 meshes |

What remains are the near levels (full detail and level 1), which stay parts. In the mountains,
`Lod.SplitDistanceL1 = 2` or a shorter view on weaker devices brings that down.

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

**Far meshes (EditableMesh superchunks).** Distant terrain (LOD level 2 and up, about 200 blocks
and further) is merged per region of 4 × 4 chunks into MeshParts once the region has not changed
for 2 seconds. About the "8 EditableMesh limit": it is not a count but a memory budget. A PC
client gets 80 MiB for editable objects and every growable EditableMesh is charged a flat 10 MiB,
whatever it holds. IceVoxel therefore keeps one EditableMesh for the whole session as a scratch
buffer: each region is written into it, *baked* into static content with
`AssetService:CreateDataModelContentAsync` (which does not count against that budget), cleared,
and shown with `CreateMeshPartAsync`. So any number of regions can be merged.

- Like EditableImage, it needs the Mesh / Image APIs enabled for published games (see The map).
- A few seconds after joining, a probe builds a few test meshes and times them against the usual
  frame time; press **F3** to see the status, how many regions and chunks are merged, and how long
  builds take. Meshes stay off (parts only, with their normal look) when the Mesh APIs are
  unavailable, the probe fails, or building makes frames more than `MaxBlockingMs` longer.
- Merged levels use a plain look for their parts too (SmoothPlastic in the block colour, opaque
  water), so swapping between parts and a mesh is invisible.
- Phones keep parts by default (`FarMeshes.Mobile`).
- Not yet measured on live servers: how long builds take on real clients, whether baked content
  is reclaimed over long sessions (a bake that hits the engine's storage limit switches meshes
  off; meshes in the world are capped at `MaxLiveTriangles`), and how far the engine then
  actually draws. Check F3 and the MicroProfiler in a published test place before relying on it.

**A biome.** Add an entry to `src/shared/Biomes/BiomeList.luau` with the altitude bands it appears
in, a climate position (temperature, humidity), surface blocks (optionally patches of another
block and a block for steep slopes) and vegetation. The terrain shape comes from `Relief`, so a
biome only decides what grows and what the ground is made of.

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
- **The Underlands at a distance.** Caves only exist in full detail chunks, so a big cavern ends
  where they do (~96 blocks). Carving the Underlands (an analytic interval per column, cheap at any
  level) into far chunks and meshing those with caves visible while the camera is inside would
  show them whole.
- **Bigger structures.** Villages / dungeons using the same stateless placement with a larger grid.
- **Parallel server generation.** The server generates chunks on its main thread (one per frame).
- **Mesher.** Try both X-first and Z-first growth and keep the smaller result.
- **Floating origin** for play far beyond ±16k studs, where float precision starts to show.
