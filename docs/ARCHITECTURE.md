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

A chunk is a full-height column (`Config.ChunkSize` = 16 wide, `Config.WorldHeight` = 1024 tall) stored
in a `buffer`, one u16 block id per cell (`World/ChunkLayout`). Each chunk also stores a one-cell
border copied from its neighbours ("padding", 18 × 18 cells per layer), so meshing never needs to
look at another chunk. Y is the outermost axis, so a vertical section is a contiguous slice.

**Cropping.** A full 1024-tall column would be 648 KB, almost all of it air. So the buffer ends a
little above the chunk's highest block (generated chunks keep 32 blocks of room for trees, rounded
up to whole sections, `ChunkLayout.croppedHeight`), and everything above it is air. The chunk's
`height` says where it ends; `getBlock` answers air above it. Placing a block above the crop grows
the buffer (`ChunkLayout.grow`) on the server, on the client (which also copies the neighbours'
border columns into the new rows' padding) and in workers applying edits; air above the crop needs
no room.

Parts and meshes are limited to 2048 studs per axis, and 1024 blocks are 3072 studs, so tall boxes
are split vertically (`ChunkRenderer`), and a far mesh region whose geometry is taller than that is
cut into height bands from its lowest point (`MeshGeometry`; most regions fit and stay whole).

Level-of-detail chunks use the same layout with bigger cells: a level `L` chunk covers
`16 × 2^L` blocks with 16 × 16 cells. Cells are `2^L` blocks wide but at most
`Lod.MaxVerticalStep` (16) blocks tall (`ChunkLayout.steps`), so the coarsest levels keep their
mountain shapes instead of collapsing into a couple of 64-block steps.

Keys are plain numbers (`World/Coords`): `nodeKey(level, x, z)`, `chunkKey(x, z)` (equal to the level 0
node key) and `posKey(x, y, z)` for block positions.

## Generation (`Generation/`)

`TerrainGenerator.generate(level, nx, nz)` builds one padded chunk:

1. **Columns.** For every padded column, `sample(x, z, level)` computes the height and surface:
   - the *relief* (`Relief.luau`, below) gives the height, the height without rivers, the
     terrain-type selector and the river strength;
   - the *biome* is picked by altitude first: the height without rivers (so a river bed belongs to
     its banks), dithered by a few blocks, falls into one of seven bands (lowland, forest, highland,
     meadow, alpine, snowy slopes, peaks; `BiomeList.bands`), and the biome is the one of that band
     nearest to the column's climate (temperature and humidity noise, also slightly jittered).
     Islands far out in some seas (very negative selector) are mushroom fields;
   - the surface: beach blocks just above sea level, gravel deep underwater, packed mud in river
     beds, biome patches (stone in windswept hills, calcite on stony peaks...) or the biome's top.
2. **Fill.** Bedrock, stone, filler and surface blocks; water up to sea level (ice in frozen biomes);
   bare rock (`Biome.steep`) on slopes steeper than the biome's limit. Below the lowest column top
   every column is stone, so that part is written a whole layer at a time (`buffer.copy`).
3. **Caves** (level 0 only, `Caves.luau`). See below. Caves are carved as **CaveAir** and stay
   `Caves.SurfaceMargin` blocks below the surface.
4. **Ores** (level 0 only). Random-walk veins inside the chunk's own core, in altitude bands
   (diorite, andesite and granite blobs low to high, emeralds only inside high mountains), with a
   vein count proportional to the height range the column has.
5. **Structures** (up to `Config.StructureMaxLevel`). See below.

The generator also returns two hints the mesher uses to skip work: `solidBelow` (everything below is
rock or cave air) and `emptyAbove` (everything above is air).

### Relief: JJThunder To The Max style (`Relief.luau`)

The terrain shape follows the "JJThunder To The Max" Minecraft datapack (version 0.6.0), whose
density functions were ported directly and calibrated against a simulation of the datapack. Its
surface is a pure heightfield, so IceVoxel keeps one height per column. Everything is computed in
the datapack's units (height `H`, 1 H = 1048 of its blocks; positions in its blocks) and mapped at
the end: `y = 64 + 450 (H - H_sea)` above sea level, `524 (H - H_sea)` below, and the same 0.43
scale horizontally, so slopes keep the datapack's steepness in a 1024 block world.

- **Selector.** One single-octave noise with a ~18 km wavelength, warped by a second noise near its
  zero contour. `a = |selector|` picks the terrain type: extreme mountains (0, the ranges follow the
  zero contour), mountains (0.075), extreme hills (0.15), hills (0.225), plains (0.3), ocean (0.4 and
  more: the selector's extremes are enclosed seas 9–17 km across). Neighbouring types are blended
  with a smoothstep, so at most two are evaluated per column.
- **Types.** `offset + offset noise + factor + jagged`: a wide offset noise, a kilometre-scale
  "factor" noise (ridges and valleys) and many-octave "jagged" detail whose amplitude grows on high
  ground. The factor is *eroded*: multiplied by `E = 1 / (1 + c)` where `c` grows with the factor's
  slope over one noise unit, so flanks flatten while crests and troughs keep their height. The hill
  types also squash positive factor values, which gives them plateau tops.
- **Rivers.** Valleys dug to 14 blocks below sea level along the zero contour of an independent
  ~9 km noise, through hills and plains and on into the sea. The distance to the contour is
  `|r| / |∇r|`, so valleys keep their width (about 200 blocks of water in a 600 block valley).
- **LOD.** Far levels leave out jagged octaves narrower than two of their cells (they would only
  alias).

Calibrated against the datapack: the terrain types cover the same share of the map, heights have
the same distribution (median ~120, 99th percentile ~680, highest ~930; a quarter of the map is
below sea level), and slopes and erosion match (mountain slopes ~0.7, plains ~0.16 blocks per
block over 14 blocks). `tests/spec/Generation` checks the main numbers.

`math.noise` computes in single precision, so noise offsets stay below 256 (its lattice repeats
every 256 units anyway): larger offsets turned kilometre-wide noise into steps several blocks long.

### Caves and the Underlands (`Caves.luau`)

Also after the datapack: caves are dry and grow with depth. A density F is computed from the depth
below the column's surface in H (`d = depth / 450`), and rock is carved where F < 0.

- No caves within ~9 blocks of the surface (`d` < 0.02); between ~9 and ~22 blocks (`d` = 0.05)
  they fade in, so the first ones appear ~11 blocks down.
- Three cave sets take over at ~45, ~158 and ~315 blocks deep (small, medium, large), blended with
  smoothsteps. Each mixes *blob* caves (one 3D noise) with *strata*, a smooth sawtooth over height
  tilted by a kilometre-scale noise plus 3D and jagged noise, by a very wide `barrier1` noise.
- `barrier2` (3D, ~190 blocks) gates the three sets: below 0 there are no caves, from 0.5 on the
  sets are at full strength. So caves come in regions, and ~14% of the rock between 22 and 316
  blocks deep is air (the datapack: 8–16%).
- **The Underlands.** From ~315 blocks deep (`d` = 0.7) the large set blends into the datapack's
  analytic `ygrad - 1.6 H` (no noise, not gated by `barrier2`), which takes over completely at
  `d` = 1. Under high ground that term is already strongly negative early in the blend, so the
  cavern opens ~330 blocks below the surface (~380 under lower ground), down to a floor that sinks
  as the surface rises. It appears under surfaces above ~540, reaches down to `Caves.MinY` under
  surfaces above ~700, and is up to ~600 blocks tall under the highest (~930) peaks. The datapack
  blends the same way.

Cave and strata sizes are 0.75 of the datapack's (the player is not scaled down with the terrain);
the depths scale with the terrain. 3D noise per block would be far too slow, so F is evaluated on
a world-aligned 4 × 8 × 4 lattice and interpolated. Lattice points where `barrier2` rules caves out
cost one noise call, cells positive at all eight corners are skipped, and the near-surface fade
uses each block's own depth (lattice depths are off on steep slopes); cells that are air at all
eight corners are carved without interpolating. In Lune, caves cost ~5–7 ms per chunk under most
terrain and ~16–20 ms (worst ~40) over the Underlands, where a chunk has 100k+ blocks of air; the
carver calls the generator's `yield` per lattice layer so workers keep to their time slice.

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
position. A spot grows something if a hash-derived roll is below the biome's vegetation chance
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

**Caves.** While the camera is below the terrain surface, sections within a reveal radius are
meshed with caves visible; everywhere else cave air counts as rock. Sections are remeshed as they
enter or leave that radius. The radius follows the open space around the camera
(`Streaming/CaveReach`): rays are cast sideways and upwards through the loaded blocks and their
median distance, plus a section, sets the radius between `Caves.RevealRadius` (tunnels) and
`Caves.RevealRadiusMax` (big caverns such as the Underlands). It grows at once and shrinks only
after two seconds, so the revealed sections do not churn. Caves only exist in full detail chunks,
so a cavern ends where they do. Where a revealed tunnel runs into hidden space (a hidden section above
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

### Far meshes (`Rendering/MeshOverlay`, `Rendering/MeshRegions`)

Thousands of far parts can be replaced by a few MeshParts built at runtime with EditableMesh. The
constraints that shape the design (creator-docs, API dump and live client flags, October 2026):

- An EditableMesh holds at most 60,000 vertices and 20,000 triangles.
- Clients have an editable memory budget (80 MiB on PC); every growable EditableMesh is charged a
  flat 10 MiB, which is where the "8 EditableMesh limit" comes from. Freed budget reportedly
  returns only after many seconds.
- `AssetService:CreateDataModelContentAsync` bakes an EditableMesh into static content that does
  not count against that budget; `CreateMeshPartAsync` then makes a MeshPart from it. Both yield,
  and a MeshPart reportedly costs ~20-30 ms to create, which cannot be split across frames.
- A MeshPart has one material, is centred on its mesh, and can be at most 2048 studs long.

So meshes are kept off the critical path: **parts first, meshes as an overlay.** Every node is still
built and shown as parts exactly as before; the streamer's protocol is unchanged. The overlay:

1. **Regions** (`MeshRegions`, pure and unit tested): shown far nodes of level >= `MinLevel` are
   grouped into aligned regions of 4 × 4 nodes of one level (at most 512 blocks wide). A region whose
   members have not changed for `StableSeconds` is a candidate (a meshed region that gained members,
   drawn as parts meanwhile, waits `RebuildSeconds`). Candidates are ranked by the parts a build
   saves times how long they have waited.
2. **Build** (builder thread, one region at a time, at most one every `BuildInterval` and never
   right after a hitch, i.e. a frame much longer than usual): the members' quads (snapshotted when
   the build starts) (`Meshing/QuadMesher`, made by the workers next to
   the boxes) become mesh arrays (`Meshing/MeshGeometry`: centred, split at `MaxTriangles`, a tiny
   anchor quad when a mesh would be flat), written into the session's single scratch EditableMesh
   with the batch APIs (vertex colours via the automatically created colour ids; with unshared
   vertices the automatic normals are the face normals), baked, cleared, and turned into a
   MeshPart (Box collision, no collision/queries/touch, Precise render fidelity so the engine does
   not decimate it into cracks). Its size is checked before it is trusted.
3. **Swap**: if the members are unchanged, the MeshParts are parented, and two frames later the
   members' part folders are unparented (kept). Parts of merged levels use a plain look
   (SmoothPlastic, block colour, opaque water), so both look the same.
4. **Demote**: when a member of a mesh is removed or rebuilt, the mesh is destroyed and the parts are
   parented again in the same frame. Members added to a meshed region stay parts until it is
   rebuilt. A failed build leaves the parts; failures back off per region, three in a row pause
   building for a minute, and StorageLimitExceeded / PermissionDenied switch meshes off.

Far nodes never change once built because their borders do not depend on their neighbours
(`generator.farSeamLimits`): the LOD tree is 2:1 balanced, so a node is meshed as if every side had
a one or a two levels coarser neighbour, which costs ~2% more boxes and ~1% more triangles. Full
detail chunks keep exact seams (and are never merged: they need exact collision, edits and caves).

A startup probe a few seconds after joining (an off-centre block, a flat sheet, and a full-size
mesh timed against the usual frame time, up to three tries) decides whether meshes are used at
all; when they are not, far parts keep their normal look. Meshes in the world are capped at
`MaxLiveTriangles`. Far meshes keep the sea floor: near water is transparent, so looking through
it across into a merged region must find the same ground the parts had. F3 shows the status and
counters.

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
with caves visible only while the camera is below the terrain surface and within the reveal radius
(see Streaming above). That is a cheap form of occlusion culling that needs no extra data structure.

**Octrees** are a storage / search structure: a cube split into 8 children until regions are
uniform. They compress big uniform volumes (air, solid rock) and speed up ray tracing and some LOD
schemes. They are not what hides caves. Our quadtree LOD (`World/LodTree`) is the 2D cousin. With
column chunks and greedy boxes, an octree would mostly help memory (a mostly-air column could be
stored as a few nodes instead of a cropped column buffer), and could be added later as a chunk
storage format.

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
