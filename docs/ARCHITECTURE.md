# IceVoxel architecture

## The big idea

Sending terrain over the network does not scale to high render distances, and replicating
thousands of parts from the server is slow. IceVoxel never does either:

```
            seed + edits                         seed
  Server  ───────────────►  Client  ─────────────────────►  Worker actors
  (authority over edits)    (state, scheduling, parts)       (generate + mesh in parallel)
```

- The **terrain generator is deterministic**: the same seed and coordinates give the same blocks on
  the server, every client and every worker actor.
- The **server** owns *changes* to the world: a list of edits per chunk. It validates edit
  requests, runs block updates and replicates every change.
- **Clients** generate, mesh and render terrain locally, then overlay the server's edits.

## Chunks

A chunk is a full-height column (`Config.ChunkSize` = 16 wide, `Config.WorldHeight` = 256 tall) stored
in a `buffer`, one u16 block id per cell (`World/ChunkLayout`). Each chunk also stores a one-cell
border copied from its neighbours ("padding", 18 × 18 cells per layer), so meshing never needs to
look at another chunk. Y is the outermost axis, so a vertical section is a contiguous slice.

Level-of-detail chunks use the same layout with bigger cells: a level `L` chunk covers
`16 × 2^L` blocks with 16 × 16 cells. Cells are `2^L` blocks wide but at most
`Lod.MaxVerticalStep` (16) blocks tall (`ChunkLayout.steps`), so the coarsest levels keep their
mountain shapes instead of collapsing into a couple of 64-block steps.

Keys are plain numbers (`World/Coords`): `nodeKey(level, x, z)`, `chunkKey(x, z)` (equal to the level 0
node key) and `posKey(x, y, z)` for block positions.

## Generation (`Generation/`)

`TerrainGenerator.generate(level, nx, nz)` builds one padded chunk:

1. **Columns.** For every padded column, `sample(x, z)` computes the height and surface:
   - *continentalness* (very low frequency) maps through a spline to a base height: deep ocean,
     ocean, coast, lowland, inland, highland;
   - *mountains* noise raises ridged mountain ranges where it is high and we are inland;
   - *biome blending*: temperature and humidity place the column in a 2D climate space. Every biome
     gets a gaussian weight from its distance in that space, and the biome terrain properties
     (`heightOffset`, `hilliness`, `vegetation`) are weighted averages. Because climate varies
     slowly, biome borders become smooth transitions instead of cliffs;
   - the *surface biome* (top / filler blocks) is the nearest biome to a slightly jittered climate,
     which makes borders look natural. Temperature drops with altitude, so peaks turn snowy.
   - beaches near sea level on coasts, gravel deep underwater, snow above the snow line.
2. **Fill.** Bedrock, stone, filler and surface blocks; water up to sea level (ice in frozen biomes);
   bare stone on steep slopes.
3. **Caves** (level 0 only, `Caves.luau`). "Spaghetti" tunnels where two 3D noise fields are both near
   zero, and caverns where a third is high. The noise is sampled on a 4-block grid and interpolated;
   segments where carving is impossible are skipped. Caves are carved as **CaveAir** and stay
   `Caves.SurfaceMargin` blocks below the surface.
4. **Ores** (level 0 only). Random-walk veins inside the chunk's own core.
5. **Structures** (up to `Config.StructureMaxLevel`). See below.

The generator also returns two hints the mesher uses to skip work: `solidBelow` (everything below is
rock or cave air) and `emptyAbove` (everything above is air).

**LOD sampling.** A level `L` chunk samples each cell at its center, so it costs about the same as a
full detail chunk while covering `4^L` times the area. LOD chunks also lower their padding columns
by one cell ("skirts"): where a coarse chunk meets a finer one, this keeps the coarse chunk from
hiding border cells the finer neighbour leaves exposed.

**Seams.** The finer side of a border has the opposite problem. Its padding holds its own, exact
terrain, but the coarser neighbour draws that column rounded down to its own cells (and sampled
elsewhere), often lower. A border cell the padding calls buried can therefore face open air, and
you could look into the terrain through it. So a node is meshed knowing the level of the coarser
node on each side: `generator.seamLimits` computes, per padding column, how high that node's terrain
really goes (with `generate`'s own rounding), and the mesher treats padding above it as air
(`GreedyMesher.Border.open`). This adds well under 1% parts and leaves no holes at any level pair
(`tests/spec/Meshing` checks the limits against the coarse node's generated data). The streamer
remeshes a node when a side gets a coarser neighbour.

### Structures

`Structures.populate` divides the world into 5 × 5 cells with one candidate spot per cell at a hashed
position. A spot grows something if a hash-derived roll is below the blended vegetation chance
there; the biome's `features` pick what grows, and the surface block must be a valid soil.

This is stateless: any chunk can find every structure that reaches into it (spots within
`Structures.RADIUS` of the chunk) and run its builder. Builders write through a `Writer` that clips
to the chunk, so a tree crossing a border is written partially by each chunk, and the parts line
up. Builders must draw random numbers the same way regardless of which chunk runs them.

On LOD chunks the writer point-samples (a cell is written if its center block is), so trees keep
their real size from far away.

## Meshing (`Meshing/GreedyMesher`)

Roblox parts are boxes, so the mesher covers blocks with as few boxes as possible:

- a drawn block is **visible** if a neighbour doesn't hide it; every visible block must be covered
  by exactly one box of its own appearance (blocks that look identical share an appearance);
- opaque blocks enclosed by opaque blocks are **wildcards**: an opaque box may extend through them,
  whatever their material, or leave them out. This lets a grass box run under a one-block step and
  keeps hillsides and underground cheap;
- glass is covered exactly; **fluids** only where they touch a non-opaque block other than
  themselves, so oceans become thin sheets instead of tall transparent boxes;
- a fluid cell without the same fluid above it is **lowered to its level** like Minecraft
  (`Blocks.fluidHeightLut`, in ninths of a block: sources 8, flowing levels 7..1, falling full).
  The height is packed next to the appearance id in the box key (`GreedyMesher.decodeKey`), so only
  cells of the same height merge and flowing water visibly steps down;
- with `hideCaves`, cave air counts as rock and every cave wall disappears.

Boxes grow along X, then Z, then Y. Output is a buffer of 7 × u16 per box (position, size, key). Tests check the
invariants (every visible block covered once, nothing visible covered by a wrong box) on generated
chunks of every LOD.

Full detail chunks are meshed in 16-block vertical sections, so an edit only rebuilds one section.
LOD chunks are meshed as one range between `solidBelow - 1` and `emptyAbove`.

## Client

### Streaming (`Streaming/ChunkStreamer`)

`LodTree.select` tiles the world with root nodes of the coarsest level and splits a node into four
children while the viewer is closer than `SplitDistance × nodeSize`. The leaves are the chunks to
show. They never overlap and leave no gaps. Hysteresis prevents flapping at split boundaries.
View and split distance come from `Config.Lod`; on phones and tablets `Rendering/ViewSettings`
switches to `Lod.Mobile`, because the engine draws parts only a few hundred studs far there anyway.
It also sets `Lighting.PrioritizeLightingQuality = false`, so that when the engine has to lower
quality it keeps draw distance and gives up lighting detail first. How far parts are actually drawn
is the engine's decision (graphics level and visible object count); scripts cannot raise it.

Each node goes through states:

```
waiting ──► queued ──► working ──► built ──► ready
(edit lists)  (priority)  (actor)   (parts)   (visible)
```

- **waiting**: full detail chunks need the server's edit lists for themselves and their four
  neighbours (neighbour edits on the shared border live in the padding).
- **queued**: sorted by distance, stretched for nodes behind the camera.
- **working**: a `ChunkWorker` actor generates, applies the edits and meshes. Long jobs yield every
  `Workers.SliceBudgetMs` so actors never stall a frame. Jobs on one actor run one at a time.
- **built**: the renderer creates parts within `Render.BuildBudgetMs` per frame, outside the
  workspace.
- **ready**: the node's folder is parented in one step.

**Seamless LOD changes.** A node that is no longer wanted stays visible until every wanted node
covering its area is ready (an ancestor, or all of its descendants). It is removed in the same frame
the last replacement appears. Replacements that finish earlier wait unshown, so two levels of
detail are never drawn over each other. `Streaming.ReplaceTimeout` is a safety net. Since a chunk
can wait unshown (without collision) for its whole old ancestor, `SpawnGuard` holds a character
until the chunk under it and the eight around it are shown.

**Edits.** Full detail chunks keep their block data on the main thread (`World/ClientWorld`). Edits
(local predictions and server messages) update the data and the neighbours' padding, and mark the
affected mesh sections dirty. Dirty sections are remeshed by workers before any new generation.
If an edit arrives while a chunk is being generated, the outdated result is discarded and the chunk
is regenerated.

**Caves.** While the camera is below the terrain surface, sections within `Caves.RevealRadius` are
meshed with caves visible; everywhere else cave air counts as rock. Sections are remeshed as they
enter or leave that radius. Where a revealed tunnel runs into hidden space (a hidden section above
or below, a neighbour chunk whose section is hidden, or a coarser node), nobody would draw its walls
there and you would look into the void. A revealed section is therefore meshed with a mask of those
sides (`GreedyMesher.Border.hidden`): hidden cave air beyond them counts as rock, and its own cave
air touching that rock becomes a stone cap. It is remeshed when the mask changes.

### Rendering (`Rendering/`)

Every node is a Folder of section Folders. A section is built outside the workspace and swapped in
whole. Parts come from `PartPool`: one template per appearance and near/far variant, so a recycled
part only needs a new size and position. Near parts collide and can be raycast; far parts do
neither and never cast shadows.

**Textures.** A block's `texture` names a MaterialVariant in MaterialService; templates set
`Material` to the block's material (it must be the variant's BaseMaterial) and `MaterialVariant` to
the name. Scripts cannot create textured variants at runtime (their maps are plugin-only), so they
are authored in Studio or synced by Rojo. With `StudsPerTile = BlockSize` and the Regular pattern
one tile covers one block face, and because box parts start and end on the block grid the tiles
line up across boxes. `faces` images become `Texture` children of near templates (e.g. a grass top
over a dirt texture), so pooled parts keep them without extra work.

### Map (`Map/`)

Map tiles are painted from the generator, not from loaded chunks, so the map shows the whole
(infinite) world. `Map/MapPainter` (shared, pure) runs inside the worker actors as a `map` job and
returns RGBA pixels: surface colour, hill shading from the neighbouring heights, tree density,
water depth and sea ice.

Roblox re-uploads only one displayed EditableImage per frame, so each map is a single
EditableImage used as a ring buffer (`Map/MapLayer`): tile `(tx, tz)` lives in slot
`(tx mod n, tz mod n)`; tiles entering the view take over the slots of tiles that left it and are
painted closest-first. `Map/MapView` shows a window of the ring with up to four ImageLabels (one per
wrapped piece) sharing the same image. The minimap uses a 256² image, the world map an 832² one
(~3 MB together). Creating an EditableImage throws when the experience has not enabled the API and
returns nil when the memory budget is used up; the maps then show markers only.

Waypoints live on the client (`Map/Waypoints`) and are saved by the server per player in a
DataStore (`Players/WaypointStore`, names text-filtered). Every client change bumps a revision
number sent with the list; the server ignores lists older than the newest one it has seen (text
filtering yields, so updates can finish out of order) and echoes the revision when filtering changed
a name, and the client applies an echo only if it made no change since. The client sends nothing
before the saved list arrives. If the saved list cannot be loaded, that session's waypoints are not
saved, so a DataStore outage never overwrites them. The server works through one list at a time
per player: filtered names are cached (so a replaced or failed list never filters a name twice), a
token bucket limits filtering per player, failed filter calls are retried with backoff, and when the
player leaves, names that could not be filtered become "Waypoint" so the positions are still saved. Teleport requests go to the server
(`Players/Teleport`), which checks `Map.Teleport` and a cooldown and lands the player on a safe spot;
`Player/SpawnGuard` holds the character until the terrain at the destination is built.

### Interaction

Targeting uses `World/VoxelRaycast` (grid traversal) on the client's block data. Edits are applied
immediately and sent to the server; a rejected edit comes back as the real block and undoes the
prediction. `Player/SpawnGuard` keeps a new character anchored until the chunk under it is ready.

### Water (`Player/WaterController`)

Water parts do not collide, and Roblox's swimming only knows Terrain water, so the character is
handled by one `VectorForce` on the root part, set every `PreSimulation` from the client's block
data (force = `AssemblyMass` × acceleration; velocity is never written):

- **Submersion** (0–1) comes from the real water surface in the character's column, including the
  lowered surfaces of flowing water.
- **Buoyancy and drag**: `g × Buoyancy × submersion − Drag × v.y × submersion` vertically. Below 1
  the character sinks slowly (terminal speed ≈ `g (1 − Buoyancy) / Drag`), and as buoyancy fades
  near the surface, holding Jump bobs there. Jump (read from `Humanoid.Jump`, which the default
  controls set for keyboard, gamepad and touch) adds `SwimUpAcceleration` while the waist is under.
- **Current**: `World/FluidFlow` gives the flow direction (Minecraft's rule: towards lower levels
  and drops, down in falling water). A one-sided servo pushes along it until the character moves at
  `CurrentSpeed`, so it never brakes the player and cannot build up speed. The Humanoid brakes hard
  on the ground, so the push limit is higher there.
- **Climbing out**: holding Jump while swimming towards a ledge at most one block above the water,
  with two free blocks above it and room over the character's head, lifts the character at
  `ClimbOutSpeed` until its feet clear the ledge (like jumping out of water in Minecraft); without
  it, a bank one block above the surface could not be climbed from deep water. A climb that does
  not get there within 1.5 s gives up until Jump is released.
- Walk speed is multiplied by `WalkSpeedFactor` in water; a WalkSpeed another script assigns
  meanwhile becomes the new normal speed and is kept when leaving the water (relative changes such
  as `+=` would apply to the slowed speed, so assign absolute values).
- The Humanoid keeps its normal states: forcing `Swimming` outside Terrain water makes it switch to
  GettingUp, steer with the camera's pitch and lie horizontal, which is wrong for shallow water.

## Networking (`Net/Protocol`)

One RemoteEvent carries `(messageType, buffer)` in both directions. A single remote keeps
server → client messages strictly ordered, which edit lists rely on: a chunk's edit list and the
live edits after it must arrive in the order they were sent.

| Direction       | Message         | Content                                       |
| --------------- | --------------- | --------------------------------------------- |
| client → server | `RequestChunks` | up to 256 chunk coordinates                   |
| client → server | `Edit`          | break / place, position, block                |
| client → server | `Teleport`      | target column (map)                           |
| client → server | `SaveWaypoints` | the player's waypoint list                    |
| server → client | `ChunkEdits`    | edit list of each requested chunk             |
| server → client | `Edits`         | every world change of the frame (or a reject) |
| server → client | `Waypoints`     | saved waypoints (on join, or after filtering) |

On the client, `Net/ClientNet` owns the only listener (Roblox delivers queued messages to the first
listener that connects) and routes messages by type, keeping early messages until a handler exists.
On the server, `ServerNet.on(kind, handler)` registers handlers.

## Server

- `World/WorldServer`: generated chunk cache (evicted when no player is near) plus the edit lists.
  `setBlock` records the edit, queues it for replication and notifies the block ticker.
- `World/BlockTicker`: scheduled block updates at `Server.TickRate`. A change notifies the block and
  its six neighbours; blocks with a behaviour schedule ticks. Overflow beyond
  `MaxUpdatesPerTick` moves to the next tick. Updates never generate chunks.
- `Behaviours/`: `Gravity` (sand, gravel), `Fluid` (Minecraft-style levels 0–7 plus falling, infinite
  sources; waits at unloaded chunks), `Grass` (turns to dirt when covered).
- `World/Simulation`: keeps chunks within `Server.SimulationRadius` of players generated.
- `Network/ServerNet`: rate limits, reach checks, breakable / placeable / replaceable checks, no
  placing inside players. Rejections never generate terrain.
- `Players/SafeSpot` + `Players/SpawnUnsafeBlocks`: a spot is safe when the floor is solid and not
  listed (`Floor`), the body's blocks are free and not listed (`Body`, e.g. water), nothing listed
  in `Hazards` (cactus) touches the body, and the feet are not below the natural surface (no cave
  spawns). The search checks the target column, then rings around it. In chunks nobody edited
  the terrain is exactly what the generator makes, so open water is skipped from the generator's
  height alone and columns are scanned from just above the tallest structure. Spawning re-checks the
  spawn spot on every respawn, since players may have built or poured water there; when no safe
  spot exists it waits 30 s before searching again.

## Hidden caves, octrees and regions

**How caves are hidden today.** Caves are carved as `CaveAir` and never reach the surface. The
mesher can treat cave air as rock (`hideCaves`), which removes every cave wall; sections are meshed
with caves visible only while the camera is below the terrain surface and within
`Caves.RevealRadius`. That is a cheap form of occlusion culling that needs no extra data structure.

**Octrees** are a storage / search structure: a cube split into 8 children until regions are
uniform. They compress big uniform volumes (air, solid rock) and speed up ray tracing and some LOD
schemes. They are not what hides caves. Our quadtree LOD (`World/LodTree`) is the 2D cousin. With
column chunks and greedy boxes, an octree would mostly help memory (a mostly-air column could be
stored as a few nodes instead of 166 KB), and could be added later as a chunk storage format.

**What Minecraft does for caves.** Minecraft splits chunks into 16³ sections and, for each section,
flood-fills its air to record which of the six faces connect to each other ("advanced cave
culling", 2014). At render time it walks from the camera's section through connected faces;
sections it never reaches are not drawn. The IceVoxel equivalent would compute that face
connectivity in the worker after meshing a section and parent / unparent section folders as the
camera moves. It would replace the "camera below the surface" rule with an exact answer (for
example, caves seen through a hole a player dug), at the cost of extra bookkeeping per section.

**Regions** in Minecraft are a *storage* format: the save file groups 32 × 32 chunks into one
`.mca` file so disks do not juggle millions of tiny files. They have nothing to do with rendering.
For IceVoxel the same idea fits persistence: saving edits per region (one DataStore key per
32 × 32 chunks) keeps the number of DataStore requests and keys low.

## Rules to keep in mind

- Generation must stay deterministic: use `Util/Hash` (never `math.random` or `Random`) and only
  the seed and coordinates as inputs. Clients and server must agree on every unedited block.
- Block ids are list positions in `BlockList`: append, never reorder.
- Anything crossing actor boundaries (jobs, results) may only contain numbers, strings, buffers,
  dense arrays and string-keyed tables.
