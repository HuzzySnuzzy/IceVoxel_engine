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
- **decorated** blocks (`decor`: chests, crafting tables, furnaces; `Blocks.singleLut`) always get a
  box of their own, one block in size, so their faces can be drawn per block. Other opaque boxes may
  still run through them where they are hidden;
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
can wait unshown for its whole old ancestor, the movement controller keeps the hull frozen until
the chunk under it and the eight around it are shown (`isReady`).

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
whole. Parts come from `PartPool`: one template per appearance, shape box and near / far / plain
variant, so a recycled part only needs a new size and position. Near parts collide and can be
raycast; far parts do neither and never cast shadows.

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
the movement hull stays frozen until the terrain at the destination is built.

### Interaction (`Interaction/BlockInteraction`)

Targeting uses `World/VoxelRaycast` (grid traversal) on the client's block data. Edits are applied
immediately and sent to the server; a rejected edit comes back as the real block and undoes the
prediction.

- **Survival mining.** Holding the break button adds `Mining.progressPerTick` every 20 Hz tick,
  Minecraft's formula: the held tool's speed (1 by hand; wood 2, stone 4, iron 6, diamond 8, gold
  12 on blocks of its kind; swords 1.5 on leaves) / hardness / 30, or / 100 if the block needs a
  tool it can't harvest with (stone by hand, iron ore with a wooden pickaxe), five times slower in
  the air or under water. Switching to another item restarts the block. The client sends `Mine` when it starts on
  a block and when it stops early. The first tick on a block only starts it (Minecraft's
  `startDestroyBlock`), and `CrackOverlay` draws the ten crack stages as the progress grows
  (procedural lines on SurfaceGuis, no assets) on the block's outline like the highlight, so they
  fit a lantern instead of its cell. At 100% the block breaks, then mining pauses for 5 ticks.
- **The server** only counts a `Mine` start for a minable block in reach. It accepts the break if
  the player started mining that very block long enough ago (`Mining.mayBreak`: 70% of the time,
  Minecraft's tolerance) with the tool held when the break arrives, drops `Items.drops(block,
  tool)` (nothing when that tool can't harvest it) and wears the tool (`Mining.wear`: 1 per block, 2
  for swords, none on instant blocks; it breaks at its durability). A break that arrives earlier still (network
  jitter) is kept and finished once the full time has passed, or undone after a second, like
  Minecraft's delayed destroy. Only one timer runs at a time: a block started meanwhile counts from
  when the waiting break is done.
- **Creative** breaks at once, again every `Interaction.BreakInterval` (6 ticks) while held (not
  with a sword in hand, as in Minecraft), and drops nothing. Creative players make items from nothing, so the stacks they throw or spill by
  breaking a chest come out of a budget (10 a second, 64 at once); a chest that would overdraw it
  stays.
- **Using and placing.** Right click on a block with a `menu` (chest, crafting table, furnace)
  opens it, unless sneaking with an item in hand.
  Otherwise the selected item is placed if it is a block. Survival placing uses the item up: the
  Edit message carries the inventory action number of that use (see below), so the prediction
  and the server's answer line up. The own hull is checked standing, like the server checks every
  player.
- Middle click picks the block (Minecraft's pick block), `Q` drops the held item (`Ctrl`: the
  stack). On touch screens a tap uses or places and holding breaks.

### WAILA (`Ui/Waila`, `Ui/WailaInfo`)

A panel at the top centre names what the crosshair points at, like the Jade mod.

- **Target.** `BlockInteraction.target()`: the highlighted block, with the same reach and rules
  (outlines included). A dropped item (`EntityRenderer.itemsNear`, a 0.5 × 0.8 block box around
  its bobbing model) or another player (their standing hull) nearer on the same aim and in reach
  wins, except while mining (`BlockInteraction.miningProgress()`), so the progress stays on
  screen; an entity behind a block is never named, even when that block is too far to target
  (WAILA casts BlockInteraction's ray without its reach check). Water shows only when no block is
  in reach: BlockInteraction aims and mines through water, so WAILA must not hide the highlighted
  block. The water ray skips the water the camera starts in. The rule is `WailaInfo.choose`
  (tested). Items, players, water and the hiding block are looked for every 0.05 s; touch
  screens aim with a finger only while breaking, so they show blocks only.
- **Content.** `WailaInfo` (pure, tested) turns (block, held item, x, y, z, extended) into an icon
  (the item's 3D icon; a colour box for blocks that are no item; a player's head shot) and lines
  of coloured segments:
  - the name (a chest adds "(27 slots)"; contents are only known while it is open);
  - the harvest line from `Items.canHarvest` and the block's `tool` / `toolLevel`:
    "✔ Requires Stone Pickaxe", "✘ ...", "✔ Tool: Axe" or "Unbreakable";
  - while the F3 overlay is open (`DebugOverlay.isOpen()`), gray lines: `Stone #3`, position,
    chunk (floored, with the local column), biome (`generator.column`), hardness, tool kind and
    level, drops with the held item and by hand (`Items.drops`), break time (`Mining.ticks / 20`,
    standing and dry), light (`Blocks.light`), fluid level, render kind, solidity, friction, menu;
  - "IceVoxel" in blue italics, always last.
- **Drawing.** Minecraft's tooltip shape, Jade's default theme: a translucent dark background
  with cut corners and a 1 pixel purple border fading downwards, the Arcade font with its shadow,
  in GUI pixels at the HUD's scale. Checks and crosses are pixel art; the italic mod name is the
  label cut into 2 pixel strips, each shifted a whole pixel or none like Minecraft's italic shear
  (`WailaInfo.italicShifts`; UDim offsets are integers). Mining progress is a white line over the
  bottom border.
- **Placement.** `WailaInfo.placement` (tested): the top centre, clear of the minimap's corner
  and, with F3 open, right of the debug text when the screen allows (screen edges first, then the
  minimap, then the F3 text); drawn smaller when it doesn't fit (whole scales on desktops,
  eighths on touch, at least half size). Where the room left of the minimap is too narrow to read
  it, it goes over the minimap's corner, as far left as it can.
- **Updates.** Every frame builds a short key (target, held item, F3) and rebuilds the text only
  when it changes, at most once a tick (0.05 s); hiding keeps the text, so a target flickering on
  and off is shown again without a rebuild. Progress only resizes its line. The panel hides while
  a screen is open, while the HUD is hidden (the world map) and with nothing aimed at.

The F3 overlay also shows the time: clock, day number, tick, sky light and how much of it reaches
the camera (`LightingController.dayTime`, `skyExposure`).

### Movement (`Shared/Movement`, `Player/MovementController`, `Player/CharacterAnimator`)

Players move like in Minecraft Java Edition (1.20): a hull, an axis-aligned box, is simulated
against the client's block data at 20 ticks per second. The Roblox character only shows where the
hull is.

- **`Movement/Hull`**: box vs block grid collision, ported from `Entity.collide`. One axis at a
  time: Y first, then the larger horizontal component. Each axis is clipped against the first
  solid block whose cross section the box overlaps. Step-up tries Minecraft's two candidates and
  keeps the longer horizontal move. The sneaking edge back-off (`maybeBackOffFromEdge`) works in
  0.05-block steps. Unloaded blocks count as solid.
- **`Movement/PlayerPhysics`**: the player tick, in Minecraft's order:
  1. fluid push and the eyes-in-water test;
  2. `LocalPlayer.aiStep` (crouching, the ×0.3 slow-down, sprint start / stop rules, the double tap);
  3. `LivingEntity.aiStep` (jump delay, tiny velocities zeroed, jumping);
  4. `travel` (ground / air / water acceleration, gravity and drag);
  5. the pose (standing 1.8, crouching 1.5, swimming / crawling 0.6 tall).

  The numbers are Minecraft's floats. The tests check speeds tick by tick against Minecraft:
  walk 4.317 m/s, sprint 5.612 m/s, sneak 1.295 m/s, sprint jumping 7.13 m/s, a 1.2522-block jump.
  The one deliberate difference is `State.stepHeight`, set from `Config.Movement.StepHeight`
  (1.0625 blocks, so the steep terrain is walkable). Sneaking still looks only Minecraft's
  0.6 blocks down at an edge, so it stops at every block edge. Pure Luau, deterministic.
- **`Movement/Rig`**: where the hull is relative to a character (root part height above the feet,
  R15 / R6), the character collision group and the teleport attributes.
- **`Player/MovementController`** runs at `RenderPriority.Camera − 1`, so the camera follows this
  frame's position. Each frame it:
  - Reads input from the default control scripts' move vector (`PlayerModule` `GetMoveVector`). It
    turns that by the camera the way the `ControlModule` does, and leaves keyboard diagonals longer
    than 1 so diagonal sprinting works as in Minecraft. `Humanoid.MoveDirection` is the fallback.
    Jump comes from `Humanoid.Jump`, latched between ticks so short taps count.
  - Runs whole ticks, at most 5 per frame.
  - Draws the character interpolated between the last two ticks:
    - `root.CFrame` and `AssemblyLinearVelocity` are set; the client owns the character, so this
      replicates.
    - A step up, a whole block in one tick, is drawn as a quick climb: an offset that decays at
      14/s, applied to the body through its root joint and to the camera. The root part stays on
      the hull, so the server always sees the real position.
    - In the swimming / crawling pose the body lies down at Minecraft's `swimAmount` rate. It faces
      down when crawling and follows the view pitch when swimming. Roblox's Swimming state tilts
      the root the same way, and the swim animation is made for that.
  - Keeps the cosmetic rig inert:
    - parts in a collision group that collides with nothing;
    - the Humanoid held in the `Physics` state, which applies no forces;
    - a `VectorForce` cancelling gravity.
  - Puts the camera at the hull's eye height. Roblox's camera adds `CameraOffset` in the root
    part's space, so the offset is computed through the root's CFrame. The eye height eases like
    Minecraft's, half the remaining way per tick.
  - Scales the camera's field of view by `SprintFov` (1.15) while sprinting, eased the same way, on
    top of whatever the field of view is set to.

  Other duties:
  - Sprint and sneak are `ContextActionService` actions at High priority that sink their keys, so
    Left Shift no longer toggles shift lock (Right Shift still does). With `ToggleSprint`, the
    sprint key turns sprinting on and off; turning it off also stops a sprint started by double
    tapping. While a screen (inventory) is open, the input is neutral.
  - The hull stays frozen until the chunk under it and the eight around it are shown, and after
    teleports. Server teleports arrive as attributes; other scripts moving the character far are
    detected and followed.
  - The `Physics` state never dies by itself, so health ≤ 0 puts the Humanoid into `Dead`. On death
    the rig is released: its parts go back to Default, the forces and the camera offset are removed.
- **`Player/CharacterAnimator`** replaces the `Animate` script, which needs Humanoid states the
  character never enters. It loads the avatar's own animation ids from `Animate`, falling back to
  Roblox's defaults. It uses the script's rules:
  - R15 walk / run blend by `speed / 16 × 1.25 / heightScale`;
  - idle below 0.75 × height scale;
  - jump for 0.31 s, then fall;
  - swim at `speed / 10`;
  - fades of 0.2 / 0.1 / 0.4 s;
  - Core priority for movement tracks, Idle for `toolnone`.

**Creative flight** (`PlayerPhysics`, Minecraft 1.20.1 tick for tick). Creative players `mayFly`.
A second jump press within 7 ticks toggles flying. While flying (and unaffected by water, like
Minecraft's flying player):
- jump / sneak add ±0.15 to the vertical speed;
- horizontal acceleration is the flying speed, 0.05 (0.1 sprinting);
- afterwards the vertical speed is the one from before the move × 0.6, so it settles at 0.375 blocks
  per tick (7.5 m/s); horizontally 10.9 m/s, 21.8 sprinting;
- no crouching, no edge back-off; landing stops it;
- creative players take no fall damage. The field of view widens by 1.1 in flight (× 1.15 when also
  sprinting).

**Fluids and the player.**
- `World/FluidFlow` is Minecraft's `getFlow`. It takes the height differences to the neighbours,
  treats an open side with the same fluid below it as a drop, and makes falling fluid next to a solid
  face push almost straight down. `PlayerPhysics` pushes the hull along it at 0.014 per tick.
- Water spreads like Minecraft's `FlowingFluid.getSpread` (`Behaviours/Fluid`): sideways only
  towards the side(s) with the shortest way to a hole. The search follows open blocks for up to 4
  blocks past the neighbour, so holes up to 5 blocks away count; it is a breadth-first search with
  each block read once. A search that reaches an unloaded chunk waits for it. A pool of sources
  pouring into a hole keeps spreading at its edge. So water runs down slopes the way it does in
  Minecraft instead of flooding the ground around it.

## Day and night (`DayCycle`, server `World/TimeOfDay`, client `Rendering/LightingController`)

**Time.** Minecraft's day: 24000 ticks, with 0 sunrise, 6000 noon, 12000 sunset and 18000
midnight. The count keeps going past 24000, which gives the day number. The server is the
authority. It publishes three workspace attributes:
- `IceVoxelDayTime`: the day time at one moment;
- `IceVoxelDaySync`: that moment as `workspace:GetServerTimeNow()`;
- `IceVoxelDayRate`: ticks per second (24000 / `Time.DayLength`, 0 while doDaylightCycle is off).

Clients compute the time from these at every update, so a running clock costs no traffic.
- The attributes change only when `/time` or `/gamerule` changes the clock. Every 60 s the same
  values are written again, which only restores them if something else changed them.
- The clock is never re-based on a timer. Server and clients compute the same closed form from the
  same numbers, so nothing drifts. A re-base would change all three attributes at once, and a
  client could apply that change halfway.
- `Lighting.ClockTime` is set by each client, never the server, so the two never fight.

**Sun position.** `DayCycle.timeOfDay` is Minecraft's celestial angle (DimensionType.timeOfDay):
it lingers around noon and passes midnight fastest, so Minecraft's sun is up for about 13600 of
the 24000 ticks, and at tick 0 it is already 12° up. `clockTime = (12 + angle × 24) % 24` puts
Roblox's sun at that angle. Roblox then tilts the sun's path by `GeographicLatitude` and its Earth
tilt.

**Commands.** `/time set|add|query` and `/gamerule doDaylightCycle` are TextChatCommands, with
`Player.Chatted` for the legacy chat. Parsing and permissions are in `Players/TimeCommand`, pure
and tested:
- Time arguments follow Minecraft's TimeArgument: `d` = 24000 ticks, `s` = 20, `t` = 1, rounded,
  never negative.
- Changing the time or the rule needs `Gameplay.Admins`, the owner or Studio; queries are open to
  everyone.
- Answers use Minecraft's wording and come back as Notices.

**Lighting.** Roblox's engine does the lighting. `default.project.json` sets Future technology and
global shadows (Technology cannot be set from scripts). Near opaque parts cast shadows
(`Render.Shadows`); far ones do not.

`LightingController` writes the Lighting properties at 10 Hz, only when they change, from
`DayCycle.environment`:
- Minecraft's sky brightness and sunrise glow depend only on how high the sun stands
  (`DayCycle.sunHeight`). The controller feeds them the height of the sun Roblox really draws
  (`Lighting:GetSunDirection().Y`), so the light matches the sky at any latitude.
- `Config.Lighting.Night` is blended to `Day` by `daylight(h) = clamp(2h + 0.2, 0, 1)`.
- `Dusk` colours are mixed in by `glow(h)`, the alpha of Minecraft's sunrise colour, times
  `Dusk.Strength`.
- `Ambient` is always `CaveAmbient`. It is the only light the engine gives places closed to the
  sky, so caves are equally dark at noon and at midnight, as in Minecraft.

With `Lighting.Enabled = false` it writes only `ClockTime`, but still works out the sky exposure
below: the cave rumble (`Audio/Ambience`) and F3 read it.

**Underground.** Roblox's sky occlusion probably does not reach far enough for caves hundreds of
blocks deep. So the sky's light (outdoor ambient, sun, sky box) also fades with the camera's depth
under the generator's ground height: from `Underground.Start` to `End` blocks. The fade is smoothed
with a time constant of `Seconds` (`DayCycle.approach`, which lands exactly so the writes stop).
Depth alone would also darken places open to the sky, so `Rendering/SkyExposure` (pure, tested)
looks at the loaded blocks around the camera:
- With nothing opaque above the camera (a pit open to the sky) it keeps full sky light, as
  Minecraft's sky light runs straight down a shaft.
- Otherwise rays step out from the camera's cell through cells that are not opaque, up to `End`
  blocks: the 8 horizontal directions and the 8 rising at 45° (stairs dug up to the surface). A
  cell at most `Start` blocks under its own column's ground, or open to the sky, raises the
  exposure to `1 - distance / End`. So a tunnel into a hillside, or a quarry under an overhang,
  darkens with the distance from the open air rather than the depth of the rock above.
- The rays stop at a wall, at an unloaded cell and once they cannot beat the best so far; their
  looks up for the sky share a budget of 2048 blocks, and the controller caches ground heights
  per column, so this fits the 10 Hz update.

Generated caves never open to the surface, so they still go dark.

Fog colour follows the time while `ViewSettings.usesFog()` is true. An Atmosphere or Sky in
Lighting is left alone, because Roblox lights both by the sun and moon itself.

## Items, inventories and game modes

**Game modes** (`GameMode`, server `Players/GameModes`). A player's mode is the Player attribute
`IceVoxelGameMode`, set by the server (`Gameplay.DefaultGameMode` on joining).
- `/gamemode <survival|creative|s|c|0|1> [player]`, alias `/gm`: `TextChatCommand`s created by the
  server, whose `Triggered` fires on the server. The legacy chat falls back to `Player.Chatted`.
- Permissions are in `Players/GameModeCommand`, pure and tested:
  - `Gameplay.GameModeCommand` (true / false / user ids) for one's own mode;
  - `Gameplay.Admins` for other players (by name, display name, unique prefix, `@s`, `@a`); the
    same ids may change the time (see Day and night);
  - the game's owner and Studio always may.
- Answers ("Set own game mode to Creative Mode") are `Notice` messages, shown in the chat by
  `Net/Notices`. Inventories stay as they are when the mode changes, as in Minecraft.

**Items** (`Items`). Every placeable block is an item with the block's id. Other items (`ItemList`:
the 20 Minecraft armor pieces, sticks, coal, raw ores, ingots, nuggets, gems, snowballs and the 25
tools) have ids from 4096 up. A stack is `{ item, count, damage }`, at most `maxStack` (64; armor
and tools 1, snowballs 16); `damage` is a tool's wear (`durability`: wood 59, stone 131, iron 250,
diamond 1561, gold 32). Blocks say how long they take to mine (`hardness`), which tool harvests them
(`tool`, and `toolLevel` when only that tool of that tier or better drops anything: iron ore needs
stone, diamond, gold and emerald ore iron), what they drop (`drops`, `dropCount`: snow gives 4
snowballs), what right click opens (`menu`) and how many slots they hold (`container`).

**The inventory** (`Inventory/Types`, `Inventory/Menu`). It is Minecraft's: 36 slots (1–9 the
hotbar), 4 armor slots, the stack carried by the mouse, and the selected hotbar slot. A *window*
is what a screen shows: the inventory plus a container, its top part. Its slots are numbered:

| Window slots      | What                                    |
| ----------------- | --------------------------------------- |
| `0 .. n-1`        | the container's n slots                 |
| `n .. n+3`        | armor: head, chest, legs, feet          |
| `n+4 .. n+30`     | inventory slots 10–36                   |
| `n+31 .. n+39`    | the hotbar                              |

Containers come in four kinds:

| Kind        | Slots                                          | Whose                               |
| ----------- | ---------------------------------------------- | ----------------------------------- |
| `inventory` | 1 result, 2–5 the 2 × 2 grid                   | window 0: the inventory screen's own |
| `crafting`  | 1 result, 2–10 the 3 × 3 grid                  | a crafting table; personal          |
| `chest`     | 27                                             | shared by everyone who opens it     |
| `furnace`   | 1 input, 2 fuel, 3 output, plus `data`         | shared                              |

So window 0 is numbered exactly like Minecraft's InventoryMenu (0 result, 1–4 grid, 5–8 armor,
9–35 inventory, 36–44 hotbar).

`Menu.apply(window, action, creative)` performs one action, ported from Minecraft 1.20.1's
`AbstractContainerMenu.doClick` and `Inventory.add`:
- clicks: left / right pickup, shift-click (`quickMoveStack`: a chest to the inventory from the
  hotbar's right end, the inventory to the chest, armor to its slot, inventory ↔ hotbar), number key
  swap, middle-click clone (creative), throw, double click collect;
- drags that split a stack evenly or one per slot;
- select, drop, the use of a placed block;
- creative slots;
- crafting (Minecraft's ResultSlot): the result is `Crafting.match` of the grid, recomputed after
  every action; taking it (click, shift-click repeatedly, number key, `Q`) takes the whole result
  and uses one item from every grid slot. Shift-click routing follows InventoryMenu,
  CraftingMenu (inventory items go into the 3 × 3 grid first) and AbstractFurnaceMenu (smeltable
  items to the input, fuel to the fuel slot). Nothing can be put into a result or the furnace
  output, and the fuel slot takes only fuel;
- close (the cursor, then a crafting grid's items, go back into the inventory; what doesn't fit
  is thrown).
Stacks stack only with the same item and wear (Minecraft's isSameItemSameTags).

It is pure and deterministic, and returns the stacks thrown out of the window. Tests fuzz it for item
conservation.

**Prediction.** Every inventory action gets a number (`seq`) on the client
(`Inventory/ClientInventory`, `Prediction`):
- The client applies it at once to its predicted state and sends it (`Inventory` message; a
  placement's number travels in its `Edit`).
- The server (`Players/Inventories` + `InventoryState`) applies actions in arrival order with the
  same `Menu`. Once per frame it sends each changed player a snapshot: the inventory, an open
  container, and `ack`, the last action it processed.
- The client takes the snapshot as the new base and replays its actions numbered above `ack`. So
  pickups, chest changes by other players, refused actions and the server's own changes all end up
  exactly as on the server, without flicker.

**Crafting** (`Crafting/`). `Recipes` lists Minecraft 1.20's recipes for the game's items by
name (shaped patterns, shapeless ingredient lists, `#planks` / `#logs` tags, smelting and fuel);
`Crafting` compiles them into ids and matches a grid: shaped recipes anywhere inside it, as written
or mirrored, with nothing else around; shapeless ones by assigning stacks to ingredients; and two
worn tools of a kind repair into one with 5% extra (RepairItemRecipe). It is pure, so the server
crafts and the client predicts with the same code.

**Chests, crafting tables and furnaces** (`Players/Containers`, `InventoryState`):
- `Use` on a block with a `menu` (reach-checked) opens it as window 1–255. Chests and furnaces are
  contents per block position, created on first use and shared by everyone who opens them (each
  viewer's snapshot includes the shared container). A crafting table gives each player a grid of
  their own, which goes back into their inventory when they close it.
- A window closes when the player walks away, dies or leaves, or when the block changes.
- Breaking or replacing the block drops what it holds (`world.onChanged`).
- Furnaces (`Crafting/Smelting`, Minecraft's AbstractFurnaceBlockEntity tick) run at 20 Hz on the
  server, whether or not anyone is watching: a fuel item lights the furnace for its burn time
  (coal 1600 ticks, planks and logs 300, sticks 100...) when there is something to smelt that fits
  the output, an item takes 200 ticks, progress falls back when the fire goes out. Only furnaces
  that are doing something are ticked (`Containers.tickFurnaces`). Viewers get a snapshot when the
  slots change, and every other tick while only the gauges move.

Death drops the whole inventory (unless `Gameplay.KeepInventory`). Inventories and chests live for
the session.

**Screens** (`Ui/`), old-school Minecraft styled from Frames only (gray beveled panels, inset slots,
the Arcade pixel font):
- `Hud`: the hotbar (1–9, the wheel, L1 / R1, taps), the held item's name, and hearts and armor in
  survival. Roblox's health bar and backpack are turned off.
- `InventoryScreen` (`E`): the armor column on the left with a character preview, the 2 × 2
  crafting grid and its result at the top right, the 27 slots and the hotbar. An open block's panel
  sits above it (`Ui/MenuLayout`, Minecraft's coordinates): a chest's rows, a crafting table's
  3 × 3 grid and result, or a furnace's input, fuel and output with the flame and arrow gauges
  from the furnace's `data`. Worn tools show Minecraft's durability bar.
- `CreativeScreen` (`E` in creative): the "Item selection" picker, a search box that filters
  `Items.search` as you type, an 8-column scrolling grid, and the hotbar under it. Clicking an item
  gives a full stack; dropping a stack on the grid deletes it.
- `SlotClicks` turns mouse, keys, touch and gamepad into Minecraft's click actions (pure, tested).
- `Screens` opens and closes them, frees the mouse (in first person too) and stops the character
  while one is open.

**Item icons and models** (`Rendering/ItemModels`, `Ui/ItemIcon`). An item's model is a cube with the
block's look (the terrain's part template: material, colour, texture, face images), or the item's
boxes. Icons show it in a ViewportFrame, lit so the top is brightest, then the left face, then the
right. They are built once per slot and only rebuilt when the item changes. The same models are
dropped items and, in `Player/HeldItems`, the item in each character's hand (from the
`IceVoxelHeldItem` attribute the server sets) and in the first person corner. Tools and sticks lie
diagonally in icons (`tilt`) and are held by the handle, pointing forward.

**Decorated blocks** (`Rendering/BlockDecor`). Chests, crafting tables and furnaces are drawn
without image assets from pure face data (rectangles on a 16 × 16 grid per face): in the world as
SurfaceGuis on their parts' templates (recycled parts keep them; they stop drawing beyond 96
blocks), and on item models as thin raised slabs, since ViewportFrames don't draw SurfaceGuis.

**Light sources and shaped blocks** (`Blocks`, `Rendering/PartPool`, `Behaviours/Attached`).
Blocks may give off light (`light`, Minecraft's 0..15: torches 14, lanterns and glowstone 15;
`Blocks.lightLut`) and may be drawn from boxes instead of a cube (`shape`: pixels from the cell's
centre, turned with CFrame.Angles). Shaped blocks render like glass (they hide no neighbour and no
opaque box runs through them). Shaped and lit blocks are meshed one box per block
(`Blocks.singleLut`). The renderer draws one part per shape box, each from its own template. The
glowing box's near template (glowstone's cube) carries one PointLight: range light × 0.9 blocks,
warm colour. A light inside a part that casts a shadow is hidden by that part, so one of the two
gives way:
- torches' and lanterns' boxes cast no shadow (they are small, so it hardly shows), and their
  light has shadows when `Render.Shadows` is on, so it stops at walls;
- glowstone's cube casts one like any opaque cube, so a glowstone roof keeps the sun out; its
  light has no shadows instead and also reaches the far side of a wall within its range (lights
  just outside each face would need up to six per block, placed by its neighbours, which shared
  templates can't do).

There is no light field in the block data; Roblox's lighting engine does the rest.

Blocks that hang on another (`support`: "Down", "Up" or a side) need a sturdy one there
(`Blocks.canSurvive`, `Blocks.isSturdy`): solid, drawn and unshaped, unless BlockList says
`sturdy = false`. Leaves, chests and cactus say so: in Minecraft leaves have no support shape and a
chest's and a cactus's sides stop short of the cell, so no torch or lantern hangs on them. An item
can place several variants (BlockList `item`: the Torch places the four wall torches; the Lantern a
hanging lantern). Placing follows Minecraft's BlockPlaceContext (`Blocks.placementFor`): the clicked
face's side first, then the directions the player looks along (`Blocks.lookOrder`,
Direction.orderedByNearest). Up or down gives the variant hanging that way if it survives; a side
gives the wall variant, which is the first side in the whole order that holds one
(StandingAndWallBlockItem, WallTorchBlock). The client sends the variant; the server re-checks
support (`EditRules.supported`, never generating terrain) and uses up the item through
`Items.ofBlock`. The `Attached` behaviour breaks a block whose support stopped being sturdy and
drops it (`Items.blockDrops`: no tool needed, like Minecraft's updateShape); `Fluid` washes away
`brokenByFluid` blocks (torches) the same way. Behaviours drop items through `Behaviours/Drops`,
which ServerNet wires to `Entities.dropBlock`. Aiming uses each block's outline (`Blocks.outline`,
Minecraft's VoxelShapes), so a ray passes beside a torch to the wall behind it, and the highlight
and the mining cracks fit the block.

Lanterns are not `solid`: the movement hull only knows full cubes, so a solid lantern would be an
invisible wall. Players and dropped items pass through them (in Minecraft they bump into them and
stand on them). They are marked `obstructs` instead, and `Blocks.obstruction` gives the box
Minecraft's collision checks that move nothing see: a solid block's whole cell, an `obstructs`
block's outline, nothing for a torch, air or water. The server refuses a placement whose box
overlaps a player's standing hull (`EditRules.obstructs`, Minecraft's BlockItem.canPlace; a torch
may overlap one), and falling sand and gravel land on that box (see Server).

## Item data (`Items`, Mekanism's sustained data)

A stack may carry `data`, Minecraft's item NBT kept small and flat: `Stack = { item, count,
damage?, data? }`, where `data` maps up to 16 keys (1-32 letters, digits and `_`) to finite numbers,
strings of at most 64 bytes or booleans. No data is nil, never an empty table.
- **Values.** A data table is shared by every copy of its stack and frozen (`Items.cleanData`,
  `withData`): never change one, make a new one. `Items.newStack`, `copyStack` and `withCount` keep
  data and wear on every copy, so data travels through clicks, drags, shift-clicks, number keys,
  throws, chests, furnaces (what is left of the input and fuel), transporters, item entities,
  death drops, close leftovers and the client's prediction.
- **Matching.** Stacks only stack with the same item, wear and data (`Items.stacksMatch`, also
  `Menu.stacksMatch`: Minecraft's isSameItemSameTags; `sameData` compares data alone, `dataKey`
  gives equal data an equal string): in the menu, `Menu.add`, transporters' insert and room, item
  entity merging and JEI's transfer, which uses plain stacks before ones with data. Pick block
  takes plain stacks only (the picked stack has no tags).
- **Where data comes from.** Crafting results have none (a repaired tool is a fresh stack, and so
  is an Advanced Fluid Tank made from a tank holding water); what stays in the grid keeps its own.
  Creative middle-click clone copies the whole stack, and the `creative` action carries wear and
  data (Minecraft's creative slot packet), checked by `Items.validData` and the item's durability.
- **Trust.** Everything from the network passes `Items.validData`; Net/Protocol decodes nothing
  else and hands out frozen tables. `Items.dataNumber(data, key)` reads a number back.

**On the wire.** Snapshots and creative actions send a stack's data after its wear: u8 n (0 none,
at most 16), then n entries sorted by key (equal data encodes alike): u8 key length + key, u8 type
and value (0 f64, finite; 1 u8 length + string; 2 u8 0 / 1). Duplicate keys, unknown types, NaN or
infinities make the message malformed: the client drops such a snapshot, the server such an
action. Item entities and items in transporters send no data (clients only draw them). A
container's `data` (Minecraft's ContainerData) is u8 n + n x f64 (at most
`Types.MAX_CONTAINER_DATA` = 16, NaN refused), so machines can show energy far beyond 16 bits; the
furnace keeps indices 1..5. A container whose kind is not in `Types.KINDS` travels as none.

**Tooltips.** `Items.describe(stack)` gives a line for each data key with a describer, in the order
they were added; other keys show nothing (Minecraft hides NBT). "fluid" ("Water: 12,000 mB", with
`amount`) and "energy" ("Energy: 1.2 MJ") are built in; `Items.addDescriber(key, fn)` adds or
replaces one (a failing one is skipped). `formatEnergy` is Mekanism's short form (J, kJ, MJ, GJ,
two decimals cut, so nothing short of full reads full; "Infinite"); `formatFluid` and `thousands`
write "12,000". `Ui/Screens` shows the lines in grey under a hovered slot's item name.

**Sustained data** (`Network/EditRules`, `Network/ServerNet`). Mekanism keeps a block's contents in
its item when it is broken. Parts of the server that keep block state register hooks with
`ServerNet.addBlockData({ save, placed })` (a registry from `EditRules.newBlockData`):
- a survival break computes its drop with `EditRules.breakDrop` while the block is still there:
  every part's `save(x, y, z, block)`, merged (an earlier part wins a shared key, at most 16 keys),
  goes on the drop when it is the block's own item (`dropWithData`; an ore dropping raw ore drops
  it plain). Then setBlock removes the block and its state. Creative breaks drop nothing;
- a placement asks `place` (Players/Inventories) first, which hands back the stack the block came
  from as it was before one was used up (data intact; in creative the held stack if it is the
  block's item). Right after setBlock every part's `placed(player, x, y, z, block, stack)` puts
  its contents back into the fresh block;
- a hook that errors is reported and skipped; it never stops a break or a placement.
The first user is the Fluid Tank (`TransmitterWorld.blockDataHooks`): `tankData` is `{ fluid,
amount }` while it holds anything (an empty tank drops a plain item that stacks with new ones);
`restoreTank` fills the placed tank (whole mB, at most its capacity, known fluids only) and marks
it dirty, so its Tanks record follows the edit to clients.

## Just Enough Items (`Ui/Jei/`)

JEI's three parts, simplified: an item list beside every inventory screen, a recipe view with an
item's recipes or uses, and the recipe transfer ("+"). The logic is pure and tested (`JeiData`,
`JeiLayout`, `JeiTransfer`); `JeiPanel` and `RecipeView` draw, and the controller (`Ui/Jei`) acts
on the input `Ui/Screens` hands it before anything else.

**The index** (`JeiData`). Built once, on first use, from the data the game plays with:
- crafting: `Crafting.recipes`, the compiled recipes the grids match. Each is drawn on a 3 × 3
  grid laid out like JEI's CraftingGridHelper: one wide in the middle column, one high in the
  middle row, shapeless ones in a 1 × 1, 2 × 2 or 3 × 3 square. A cell lists every item it
  accepts, in creative order; a tag (`#planks`) shows one a second, and the looked-up item stays
  put;
- smelting: `Smelting.recipes()`, one per line of `Recipes.smelting` (a tag stays one recipe),
  200 ticks each;
- fuel: `Smelting.fuels()`, the burn time shown as "Burns N items" (ticks / 200).

`recipes(item)` are the entries that make the item, `uses(item)` those that take it (in any cell,
as a smelting input, as a fuel). A catalyst, the block a category's recipes are made in
(`CATALYSTS`: the crafting table for crafting, the furnace for smelting and fuel), also uses every
entry of its categories, after its own uses, as JEI's "Show uses" on a crafting table or furnace
lists them. Both come grouped by category in that order, without the empty ones.

**Screens.** While an inventory screen is open:
- The list sits right of the 176 px panels at their GUI scale (`JeiLayout.list`): up to 9 columns
  and 16 rows of 18 px cells (every cell is a ViewportFrame), fewer on narrow screens, hidden when
  not even 3 columns fit, and in creative above the hotbar row (also while the recipe view hides
  it, so the cells are not rebuilt). Its arrows or the wheel turn the pages; the page text drops
  to "n" where "n / m" does not fit. The search field filters with `Items.search` as you type; it
  is a TextBox, Screens ignores keys while one has focus, and the list gives up the focus when it
  hides.
- Left click or R: recipes; right click or U: uses. R and U work over any item: the list, the
  view, slots, the creative grid and the hotbar. Lookups that find nothing do nothing.
- The recipe view takes the inventory panel's place: Screens hides the panel and makes no slot
  clicks while it is shown. It has category tabs, pages, and as many recipes as fit (two crafting
  or smelting recipes, three fuels). Clicking its items navigates, Back or Backspace returns
  through the history, and E, Escape or gamepad B go back to the inventory. Escape also opens
  Roblox's menu (MenuOpened): with the view open that only closes the view, so the menu shows
  over the inventory; the key and the menu are debounced so one press acts once. A gamepad
  selection the rebuilt view destroys or hides moves to its first slot.
- Creative (JEI's cheat mode): shift-left or middle click puts a full stack on the cursor, and
  clicking the list with a carried stack deletes it, both through the existing `creative` action.

**Recipe transfer** (`JeiTransfer`). The "+" shows on crafting recipes while the inventory screen
shows a crafting grid: window 0's 2 × 2 or a crafting table's 3 × 3. A recipe goes where the view
draws it: cell for cell on a table, and on the inventory's grid the view's top left 2 × 2, which
holds every recipe that fits there (bigger ones: "Recipe too large for this grid"). `check` shares
the inventory, the grid and the carried stack out among the cells (a tag cell takes the kind there
is most of; the cells of every recipe accept the same items or none in common, which keeps that
greedy choice right) and names the cells it cannot fill. `status`, which the button uses, also
makes the one set plan, so the button is greyed out as well when the carried stack or the grid's
contents have no room to go back ("No room in the inventory"). A greyed button's tooltip says
why, and hovering it shows the missing cells red.

`plan(window, recipe, all)` is a list of ordinary inventory actions:
1. the carried stack is put down in the inventory;
2. the grid is shift-clicked empty;
3. for each kind of ingredient, the biggest stack is picked up and spread with drags (Split when an
   even share fits every cell, One for an item each). An excess goes back by right clicks or by
   halving the stack. One set takes about 3 actions per kind of ingredient; random tests average
   8 actions a plan (shift: as many sets as the inventory holds, up to a stack; snowballs 16).

The plan is applied to a copy with `Menu.apply` before it is returned. It must leave exactly the
recipe in the grid, its result in the result slot, nothing carried and every item still there.
The client sends it through `ClientInventory.apply`, so the server checks it like any click, then
closes the view. A fuzz test plans and applies hundreds of random transfers.

## Mekanism pipes (`Transmitters/`)

Mekanism 10's transmitters (Minecraft 1.20.1) for what the game has: Logistical Transporters and
the Restrictive Transporter (items), Mechanical Pipes (water), Fluid Tanks, the Configurator and
Minecraft's buckets. Universal Cables, Pressurized Tubes and Thermodynamic Conductors are out of
scope: there is no energy, gas or heat.

**Blocks and items.** BlockList gives transmitters `transmitter = { kind = "item" | "fluid", tier,
restrictive? }` and tanks `tank = { tier, capacity }`; the numbers per tier are Mekanism's
TransporterTier, PipeTier and FluidTankTier (`Transmitters/Tiers`):

| Tier     | Transporter pull | Speed (progress / tick) | Route cost | Pipe capacity (mB) | Pipe pull (mB / tick) | Tank (mB) | Tank output (mB / tick) |
| -------- | ---------------- | ----------------------- | ---------- | ------------------ | --------------------- | --------- | ----------------------- |
| Basic    | 1                | 5                       | 10         | 2 000              | 250                   | 32 000    | 1 000                   |
| Advanced | 16               | 10                      | 5          | 8 000              | 1 000                 | 64 000    | 4 000                   |
| Elite    | 32               | 20                      | 2.5        | 32 000             | 8 000                 | 128 000   | 16 000                  |
| Ultimate | 64               | 50                      | 1          | 128 000            | 32 000                | 256 000   | 64 000                  |

100 progress is one block, transporters pull every 10 ticks, and a bucket is 1 000 mB. A route
costs the sum of the transporters it enters (Mekanism's getCost: the Ultimate speed over the
tier's, `Transmitters.pathCost`), and 1 000 for a Restrictive Transporter, so routes take faster
transporters and avoid restrictive ones unless there is no other way.
- Transmitters are shaped blocks. Their `shape` is Mekanism's 8-pixel core: a glass cube, then
  twelve frame edges in the tier's colour (Basic dark grey, Advanced red, Elite dark aqua,
  Ultimate purple; the Restrictive Transporter orange, pipes with bluish glass). Shape boxes may
  have their own `transparency` (glass 0.5, frames 0). The arms depend on the neighbours and the
  side modes, so the client draws them; `icon` (the core's boxes, then two arms) is the item model.
- They are aimed at over the whole cell (bounds covering the cell give no outline), which makes
  choosing a side easy. They are not `solid` (the hull only knows full cubes: players walk through
  them, as through lanterns) but `obstruct`, so none is placed inside a player and falling sand
  lands on them. Hardness 1, pickaxe, metal sounds; they drop themselves.
- Fluid tanks are solid shaped cubes (steel plates, posts in the tier's colour, glass sides) and
  sturdy (`sturdy = true` makes a solid shaped block hold torches). Breaking one loses its water.
- Items: the Configurator (1 per slot), Bucket (16) and Water Bucket (1).

**Sides and modes.** Sides are Minecraft's Direction ordinal: 0 Down, 1 Up, 2 North (-Z), 3 South
(+Z), 4 West (-X), 5 East (+X); side s of a block at p faces p + offset(s), and opposite(s) is
s xor 1. Each side of a transmitter has Mekanism's ConnectionType, which the Configurator cycles
NORMAL -> PUSH -> PULL -> NONE: NORMAL and PUSH may hand items or water to an acceptor
(`outputs`), PULL takes from it (`pulls`) and never gives, NONE cuts the side. The six modes pack
into 16 bits, 2 a side, side 0 lowest (0 = all NORMAL, at most 4095), which is how they are stored
and sent. Transporters may be coloured with Minecraft's 16 dyes (1..16, 0 none; sneaking with the
Configurator steps through them and back to none).

**Connections** (`Transmitters.connects`, `Transmitters.connections`: Mekanism's
canConnectMutual), shared by the client's arms and the server's networks:
- two transmitters connect when they are the same kind (any tiers), neither facing side is NONE
  and, for transporters, their colours are compatible (either is uncoloured, or both are the
  same; pipes have no colour);
- a transmitter connects to an acceptor of its kind (a block with `container` slots for items, a
  fluid tank for water) unless its side is NONE;
- nothing else connects. `connections` answers all six sides of a position as two bit masks
  (transmitters, acceptors) from block and state lookups, so both sides get the same answer.
An item pulled into a transporter takes its colour and only enters transporters that are
uncoloured or of that colour (`Transmitters.carries`, Mekanism's
TransporterStack.canInsertToTransporter): an uncoloured item stays off coloured transporters even
where they connect to uncoloured ones.

**Sided inventories** (`Transmitters/Inventories`). An inventory is reached through its own side
facing the transmitter (a transporter on a furnace reaches its face Up). A furnace is Minecraft's
AbstractFurnaceBlockEntity: Up reaches the input, the sides the fuel, Down the output and then the
fuel; the input takes anything, the fuel only fuel and the output nothing; anything may be taken
out except the fuel through Down (only buckets). A chest gives every slot to every face. `insert`
and `room` top up stacks of the same item and wear first, then fill empty slots, up to the item's
max stack (Forge's insertItemStacked, as Mekanism inserts); `available` lists the item types a
face gives with their totals (Mekanism's TransitRequest) and `extract` takes up to n of one type,
a stack at most. They are pure (new slot tables out, inputs untouched), so the server simulates a
delivery with the same calls it applies. A pipe's fill travels as a byte (`fillLevel`: 0 empty,
at least 1 with anything in it, 255 full).

### On the server (`server/Transmitters/`, `Players/ItemUse`)

`Transmitters/TransmitterWorld` holds the pipes' state and is pure (the tests run it on a table of
blocks); `Transmitters/Transmitters` runs it from the server script's Heartbeat, after ServerNet's
flush, at 20 ticks a second (a fixed step catching up at most 4 ticks a frame).
- **State.** A node per transmitter (packed side modes, colour, a transporter's pull timer), a tank
  record per fluid tank, and the items in transit; all in memory. The server script chains
  `blockChanged` onto WorldServer.onChanged, so placements, breaks and Api changes all come
  through. Each node keeps two masks, `links` (sides joined to transmitters) and `acceptors`
  (sides joined to inventories or tanks), from `Transmitters.connections`, recomputed when it, its
  modes or colour, or a neighbouring block change. Blocks are read with peekBlock, falling back to
  the chunk's edit list: transmitters, tanks, chests and furnaces only come from edits, so pipes
  work where no player is and never generate terrain.
- **Networks** (pipes only). A pipe whose links change queues itself and the pipes it joined or
  left; queued pipes are flood filled, at most 4096 visited per tick, the rest carried over while
  the old networks keep working. A finished fill becomes one network that takes from each old
  network the share of its buffer its pipes held (by capacity), so merging adds buffers and
  splitting shares them; a broken pipe loses its share, a broken tank its water.
- **Items** (`Transport`, Mekanism's LogisticalTransporterBase / TransporterPathfinder):
  - Pulling: a transporter with PULL sides on inventories pulls through each, then waits 10 ticks
    (3 when nothing was there, min(40, e^failures) when items found nowhere to go). The item types
    the inventory's facing side gives (`Transmitters.available`) are tried in order; the first
    with a destination sends up to the tier's pull amount, never more than fits there or a stack.
    Destinations are found before anything is taken, and the item takes the puller's colour.
  - Routes: Dijkstra from the item's transporter, adding `pathCost` for each transporter entered
    and only entering ones that `carries` its colour. The cheapest inventory (then fewest steps)
    on a NORMAL or PUSH side that takes at least one item wins. Room counts the items already on
    their way there (Mekanism's TransporterManager). The source inventory is excluded except as
    "home" (reachable through any joined side); with neither, the item waits in the middle of its
    transporter and looks again every 20 ticks. A search visits at most 4096 transporters, and
    once a tick's searches have visited 4096, waiting items and pulls carry on the next tick
    (moving items always re-route), so big networks full of waiting items cannot stall the server.
  - Moving: progress grows by the transporter's speed each tick (100 = a block). Halfway, the way
    ahead is checked (and re-routed if closed); at 100 the item enters the next transporter, or the
    inventory: what fits goes in (viewers get a snapshot, a furnace wakes) and the rest re-routes.
    A broken transporter drops its items (Entities.dropBlock).
- **Water** (`Fluids`): each tick, every PULL side on a tank takes up to the pipe's pull amount
  into the buffer (one fluid, up to the pipes' capacity); then the buffer is split evenly over the
  tanks on NORMAL / PUSH sides with room, each tank once, smallest room first.
- **Replication.**
  - Transmitters / Tanks records: a chunk's non-default ones go to a player right after its edit
    list (ServerNet's `chunksSent` rule). Changes go each frame to players within 192 blocks
    sideways (to every player not yet seen in the world), compared with what was last sent; pipe
    fills and tank contents go at most every 5 ticks.
  - Transport: items are tracked per player within 64 blocks (gone beyond 72, checked every
    10 ticks). An `add` is sent when an item enters, is re-routed or waits, changes speed, or has
    gone 128 blocks along a route longer than 255 sides; a `remove` when it arrives, drops or
    leaves the player's range. `startTime` is the server time of the tick that produced it.
- **Use** (`Players/ItemUse`, rules in `Transmitters/UseRules`). UseItem from a living player, in
  reach, at most 10 a second, with the item in hand:
  - Configurator: cycles the clicked side (a same-kind transmitter beyond it matches, so a cut
    joint is joined again from either end; Mekanism changes only the clicked side), or sneaking on
    a transporter its colour; Mekanism's message in the chat and a click sound.
  - Bucket: a water source becomes air (Minecraft's createFilledResult: a stack keeps the rest and
    the water bucket goes into the inventory, else is thrown; creative keeps its bucket and gets
    one water bucket at most). A tank with 1000 mB loses it (creative gets nothing, as in
    Mekanism).
  - Water Bucket: a tank with room for 1000 mB, else a water source in the clicked block if
    replaceable or the block beyond its side; survival gets the empty bucket back.
  - Sneaking skips tanks. Nothing is predicted: the snapshot, edits and records bring the results.

### Mekanism pipes on the client (`Rendering/TransmitterRenderer`, `Rendering/TransmitterModel`)

The terrain draws each transmitter's core and each tank's frame (their `shape`; PartPool gives
every shape box its own transparency). Everything that depends on neighbours or on the server is
drawn by TransmitterRenderer within 64 blocks of the camera, from boxes TransmitterModel computes
(pure, tested; pixels from the cell's centre):
- arms on every side `Transmitters.connections` connects: glass from the core's frame (4 px)
  out, ending in a 7 x 7 collar between transmitters (two collars make a joint) or a 10 x 10
  plate on an acceptor; a Neon band on an acceptor's arm whose side is PUSH (orange) or PULL
  (blue) (between transmitters those modes act as NORMAL and Mekanism draws them so); a coloured
  transporter's tint cube and dyed arm glass;
- water: a pipe's fill byte (its network's) as a level in the core and sideways arms, the arm
  down full whenever there is water, the arm up only from 95 %; a tank's amount / capacity from
  its bottom plate.
Positions come from edits only: a chunk's transmitters and tanks are read from its edit list when
its data is attached and followed through block changes (ClientWorld `onChunkLoaded`,
`knownEdits`, `onBlockChanged`). Records are kept while a chunk's edit list is known or
requested, or its data is loaded (the server sends changes to every player near, and the edit
list's records again with it), and dropped when neither is; an all-zero record is the default
state. Any change of a position's block resets its state (the server starts a new transmitter in
the default state and sends no record); when this player's own predicted break took it
(`onBlockChanged`'s `predicted`), it is kept 5 s and comes back if the server refuses the break.
Cells are decorated only while their chunk is shown (the streamer's node), redrawn only when
they, a neighbour or their state change (at most 64 a frame, and only when the boxes' signature
changed), from pooled parts (a template per kind and colour; a redraw keeps the cell's parts of
the same look, so a pipe's changing water level only resizes them), at most 4000 parts.

Items in transit: `route` turns an Add (block, progress, speed, server start time, path) into
per-block exit times, each block crossed at its transporter's speed; `position` follows it every
frame from workspace:GetServerTimeNow() (progress 0 the entry face, 50 the centre, 100 the exit
face; turns at centres). The way into the first block is not sent: an Add for a known item takes
it from its previous route (`entryOf`), a newly pulled one from the transporter's one PULL side on
an inventory (`pullEntry`), else it comes in straight. Models (ItemModels, 0.35 blocks, turning
slowly on the client's clock) are pooled per item, at most 256, and moved with one BulkMoveTo per
frame. Remove(arrived) lets an item finish its way (at most 1 s), dropped / gone remove it at
once, an item whose way ended goes after 0.5 s, and one out of range for 60 s is forgotten.

Interaction: items that are no block send `UseItem`, unpredicted, once per press, and only where
the server would act. The Configurator (on transmitters; sneaking only on transporters) sends the
side `TransmitterModel.pickSide` finds: the arm the ray hits, else the core face it enters, else
the cell face it hit; sneaking is a flag. The empty Bucket casts its own ray that also stops at
water sources (Minecraft's Fluid.SOURCE_ONLY) and sends that water cell or a tank (not when
sneaking); the Water Bucket sends a tank (not when sneaking) or the clicked block when the cell
the server would fill is replaceable. A block with a menu still opens first unless sneaking.

WAILA asks TransmitterRenderer (`state`, `tank`, `connections`, `itemsIn`, `network`: a cached
walk of the connected transmitters) and BlockInteraction.targetSide: "Side: Pull", a
transporter's colour and items, "Water: ~n / m mB" for a pipe (its network's fill byte times the
capacity of the pipes the client sees connected), "Water: n / m mB" for a tank; with F3 the
tier's numbers, packed modes and each side's, colour and fill byte, connected sides and the
network size. Item icons draw a block's `icon` (a transmitter's core and two arms) box by box.

## Item entities (`Entities/`)

Dropped items are Minecraft's ItemEntity:
- `Entities/ItemPhysics` (shared) is its movement, one 20 Hz tick on a 0.25 block box:
  - gravity 0.04 and drag 0.98, ground friction (ice slides);
  - floating up in water; pushed out of blocks placed on it;
  - collision through `Hull`.
- `EntityWorld` (server, pure, tested) holds the rules:
  - pickup delay 10 ticks (40 when thrown);
  - pickup by a player box grown by (1, 0.5, 1);
  - merging of equal items (the smaller into the larger, every 2 ticks while moving, 40 at rest);
  - despawn after `Entities.ItemLifetime`; at most `Entities.MaxItems`.
- `Entities` replicates the items within `Entities.TrackingDistance` of each player: spawns, a
  sync every 20 ticks while moving, count changes, and removals naming who picked them up.
- Clients run the same `ItemPhysics` between syncs, ease corrections in, and draw items bobbing and
  spinning (more copies for bigger stacks). A picked-up item flies to the player.

## Sounds (`Sounds/`, server `Audio/Sounds`, client `Audio/SoundPlayer`)

Sounds are Minecraft's sound events, played with files that ship with every Roblox client.

**The catalogue** (`Sounds`, from `Sounds/SoundList`). Events are numbered by position: the block
events first (`Blocks.SOUND_TYPES` x the five actions), then SoundList's list, in a fixed order,
so the server and clients agree on the numbers without sending names. Each event has a file, a
volume and pitch (final: Sound.Volume and PlaybackSpeed), a random pitch variance, the distance it
carries (16 blocks), the volume setting it follows (`source`), and who plays it (`side`).
- Blocks have a sound type (`sound`, else by material: Wood wood, Ground gravel as Minecraft's
  dirt, Ice glass, Metal metal...; fluids water; `Blocks.soundLut`). A type has a dig clip
  (break, place) and a step clip (step, hit, fall), scaled per action like Minecraft (break and
  place (v + 1) / 2 and pitch 0.8, hit (v + 1) / 8 and 0.5, step v x 0.15, fall v x 0.5 and 0.75).
  With one thud and one footstep for everything, pitch tells the materials apart (placed: wool
  0.6, gravel 0.72, stone 0.8, sand 0.88, wood 0.96, grass 1.08, metal 1.2, snow 1.32; glass is
  placed like stone and shatters when broken).
- Files: a client ships eleven sounds (content/sounds in Roblox's file manifest, checked against
  version 0.741): action_falling.ogg, action_footsteps_plastic.mp3, action_get_up.mp3,
  action_jump.mp3, action_jump_land.mp3, action_swim.mp3, impact_explosion_03.mp3,
  impact_water.mp3, oof.ogg, ouch.ogg and volume_slider.ogg. The catalogue uses only those, all
  but action_jump.mp3 (the classic gear sounds such as glassbreak.wav or unsheath.wav, and
  uuhhh.mp3, are gone). An event may still name a `fallback`, which clients play when its file
  fails to load.
- Lookups: `block(block, action)`, `container(block, opened)` (chest lids), `equip(old, new)`
  (armor put on), `fall(halfHearts)` (small up to 4, else big), `lookupNames` (override names).

**Who plays what** (Minecraft's split between server and client):

| Side        | Events                                                     | How                              |
| ----------- | ---------------------------------------------------------- | -------------------------------- |
| `predicted` | block break / place / fall, player small / big fall        | the acting client at once; the server sends everyone else |
| `server`    | chest open / close, item pickup, tool break, hurt, death, armor equip | the server sends everyone near, the player included |
| `client`    | mining hits, footsteps, splash, swim, clicks, furnace crackle, cave ambience | clients only, never sent |

**The server** (`Audio/Sounds`) queues sounds and, once a frame, sends each player whose feet are
within the event's distance (times a volume above 1, at most 2.55) plus `Sounds.BroadcastSlack`
blocks one `Sound` message with all of theirs, at most `Sounds.MaxPerFrame`, leaving out the player
whose client predicted it. Sounds a player's own messages cause (chest lids, armor put on) use up
that player's budget (`Sounds.PlayerRate` a second, bursts of twice that), so a client spamming
inventory or Use messages can't stream sounds to everyone near. Hooks: ServerNet (players' breaks
and placements), Behaviours/Attached (torches popping off; water washing one away is silent, as in
Minecraft), Containers' `onOpeners` (first viewer in, last out; a broken chest closes silently),
Inventories (armor put on by any action, a tool breaking), Entities (pickups, at the item),
Characters (health lost, at most every 0.5 s; death; a hurting landing's fall and the fall sound of
the block below the feet).

**Overrides.** Sounds in `SoundService.IceVoxelSounds` (or ReplicatedStorage) named like an event,
else like its category (`block.break`, `item.armor.equip`), replace it; several with one name are
picked at random.

**The client** (`Audio/`). `SoundPlayer` plays everything: the server's `Sound` messages and the
client's own sounds, which play at once as Minecraft's client does.
- Voices: 32 Sounds in Attachments of one invisible anchored Part
  (`workspace.IceVoxelAudio.Emitter`) for 3D, and 4 in `SoundService.IceVoxelAudio` for the
  interface. Nothing is created per sound.
  - A voice is free again when its sound ends, or when it is cut at `duration / PlaybackSpeed`.
  - When all voices are busy, the oldest is taken. A kind of sound (an event's category) has at
    most a few at once (`SoundRules.CAPS`: three mining hits, six footsteps).
  - At most 32 sounds start per frame. Sounds beyond hearing of the listener are never started.
- Listener: the camera, as in Minecraft, but never more than 4 blocks (`SoundRules.LISTENER_REACH`,
  Minecraft's third person distance) from the eyes it looks at (`Camera.Focus`), turned like the
  camera (`SoundService:SetListener`, every frame after the camera). Roblox's camera zooms out to
  128 studs, where everything near the player would fade out, and the server only sends sounds
  near the character. A Scriptable camera keeps Roblox's camera listener.
- Playback (`SoundRules.playback`):
  - Volume: the event's (or the override's) x the cue's x `Sounds.Volume` x the source's.
  - Pitch: the event's pitch (or the override's PlaybackSpeed), varied by the event's variance,
    x the cue's.
  - Linear rolloff from `MinDistance` to `maxDistance x max(1, cue volume)` blocks.
- Files are preloaded. One whose Sound has not loaded after 15 s (2 s once the preload reports it
  failed; a Sound that loads always counts) plays its fallback from then on, with a warning.
- Overrides: the override folder (SoundService, else ReplicatedStorage) is indexed by Sound name
  and watched. The event's name wins over its category; several Sounds with one name are picked
  at random.
- Roblox's `RbxCharacterSounds` is disabled (its running, landing and death sounds would double
  ours) and the sounds it made are removed.

What the client plays itself:
- `BlockInteraction`: break and place, and the survival hit every 4 ticks from the tick after the
  start (`destroyTicks`; unbreakable blocks too).
- `MovementSounds.tick`, after every hull tick (Minecraft's `Entity.move`):
  - `moveDist` grows by 0.6 per block walked; a step plays each time it passes the next whole
    number (every 1.67 blocks), on the block the hull stands on (else `floor(y - 0.2)`);
  - fluids make no step; flying and sneaking on the ground are silent; in the air the step waits
    for the landing;
  - in water off the ground: swim sounds; entering water: a splash; both scaled by speed;
  - a landing that hurts: `Sounds.fall` and the block's fall sound.
- Other players' characters within 24 blocks of the listener, followed per player (a new
  character starts over): the same rules every frame, from their feet (`SoundRules.observe`
  guesses the ground, edges included, and the water; lying down in water is swimming).
- Screens and JEI: clicks on buttons, tabs, page arrows, Back and "+" (not on slots or items).
- `Ambience`:
  - the open furnace window, while burning: crackles with Minecraft's odds for a furnace a block
    or two away (about every 4 s);
  - under `skyExposure` 0.2: `ambient.cave` every 90 to 300 seconds spent there, from up to 8
    blocks each way around the listener.

## Networking (`Net/Protocol`)

One RemoteEvent carries `(messageType, buffer)` in both directions. A single remote keeps
server → client messages strictly ordered, which edit lists rely on: a chunk's edit list and the
live edits after it must arrive in the order they were sent.

| Direction       | Message         | Content                                       |
| --------------- | --------------- | --------------------------------------------- |
| client → server | `RequestChunks` | up to 256 chunk coordinates                   |
| client → server | `Edit`          | break / place, position, block, action number |
| client → server | `Teleport`      | target column (map)                           |
| client → server | `SaveWaypoints` | the player's waypoint list                    |
| client → server | `Fall`          | fall distance of a landing (fall damage)      |
| client → server | `Mine`          | started / stopped mining a block              |
| client → server | `Inventory`     | a numbered inventory action                   |
| client → server | `Use`           | right click on a block with a menu            |
| client → server | `UseItem`       | right click on a block with the Configurator or a bucket: position, side, sneaking |
| server → client | `ChunkEdits`    | edit list of each requested chunk             |
| server → client | `Edits`         | every world change of the frame (or a reject) |
| server → client | `Waypoints`     | saved waypoints (on join, or after filtering) |
| server → client | `Inventory`     | inventory + window container after action `ack` |
| server → client | `Entities`      | dropped items: spawn / sync / count / remove  |
| server → client | `Notice`        | a message for the chat                        |
| server → client | `Transmitters`  | transmitter states: packed side modes, colour, pipe fill |
| server → client | `Tanks`         | fluid tank contents (fluid, mB)               |
| server → client | `Transport`     | items entering, re-routed in or leaving transporters (path, speed, start time) |
| server → client | `Sound`         | sound events near the player (event, position, volume, pitch) |

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
  sources, spreading only towards the nearest way down; waits at unloaded chunks; washes away
  `brokenByFluid` blocks), `Grass` (turns to dirt when covered), `Attached` (torches and lanterns
  break and drop when what they hang on stops being sturdy). They drop items through `Drops`, which
  ServerNet wires to `Entities.dropBlock`.
  - In `Gravity`, as in Minecraft, a falling block passes through blocks without a collision box
    (torches) and lands on those with one (`Blocks.obstruction`). Coming to rest in a torch's cell
    (a solid block under the torch) or on a lantern, it breaks into an item and the torch or
    lantern stays: the torch trick for clearing sand and gravel. Past wall torches with air under
    them it keeps falling, and a block placed on a torch stays where it is.
- `World/Simulation`: keeps chunks within `Server.SimulationRadius` of players generated.
- `Network/ServerNet`: rate limits, reach checks, breakable / placeable / replaceable checks, no
  placing inside players (`EditRules.obstructs`: solid blocks and lanterns, not torches), survival
  mining time and drops (`EditRules`), and the rules injected by the boot script (`setRules`: using
  up placed items, dropping items and chest contents). Rejections never generate terrain.
- `Entities/`: dropped items (see Item entities).
- `Players/GameModes`, `Players/Inventories`, `Players/Containers`: see Items, inventories and game
  modes. `World/TimeOfDay` and `Players/TimeCommands`: see Day and night. `Audio/Sounds`: see
  Sounds.
- `Players/Characters`: puts every character part in the `IceVoxelCharacters` collision group
  (it collides with none of the groups registered when the server starts; parts go back to Default
  on death, so the body falls, and when they leave the character), teleports characters by setting the
  feet position as attributes the client's hull follows, and turns reported landings into fall
  damage in survival (`ceil(distance − 3)` of 20 half hearts, scaled to `MaxHealth`, through
  `TakeDamage`; at most 4 reports a second). It also plays the hurt, death and hurting-landing
  sounds to everyone near (see Sounds).
- `Transmitters/`: Mekanism pipes (see Mekanism pipes); `Players/ItemUse`: the Configurator and
  buckets (UseItem).
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
- Block ids are list positions in `BlockList`: append, never reorder. The same holds for items in
  `ItemList` (ids from 4096).
- `Inventory/Menu` and `Crafting` must stay pure and deterministic: the client predicts every
  inventory action with them and must reach exactly the server's result.
- Sides are Minecraft's Direction ordinal everywhere in the pipes (0 Down .. 5 East,
  `Transmitters.SIDES`); transmitter modes, colours, network buffers and tank contents live in
  memory, like chests.
- Transmitters, fluid tanks, chests and furnaces only come from edits: the pipes read unloaded
  chunks' edit lists to find them. Generating any of them would need Transmitters/Transmitters to
  learn about it.
- Anything crossing actor boundaries (jobs, results) may only contain numbers, strings, buffers,
  dense arrays and string-keyed tables.
