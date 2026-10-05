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
little above the chunk's highest block (generated chunks keep 32 blocks of room for trees, or room
for the tallest library structure reaching into them, rounded up to whole sections,
`ChunkLayout.croppedHeight`), and everything above it is air. The chunk's
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
   bare rock (`Biome.steep`) on slopes steeper than the biome's limit. A full detail chunk's
   outermost padding columns also measure the slope to their missing neighbour just outside the
   padding (only when that could still change the answer), so their surface is exactly the
   neighbouring chunk's core's and plants grow by it (LOD padding is a lowered skirt anyway).
   Below the lowest column top every column is stone, so that part is written a whole layer at a
   time (`buffer.copy`).
3. **Caves** (level 0 only, `Caves.luau`). See below. Caves are carved as **CaveAir** and stay
   `Caves.SurfaceMargin` blocks below the surface.
4. **Ores** (level 0 only, `Ores.luau`). Random-walk veins inside the chunk's own core, in altitude
   bands (diorite, andesite and granite blobs low to high, emeralds only inside high mountains).
   Each feature in `Ores.FEATURES` has `veins` per 128 blocks of height and `size` walk steps.
   Uniform features start veins anywhere in the part of their range the chunk's buffer has (up to
   its highest column plus the structure room), so ores are as common in a mountain as on a plain.
   `shape = "trapezoid"` features start them at Minecraft's TrapezoidHeight over their whole range
   (`Ores.trapezoid`: two uniform draws, densest in the middle), the same number in every chunk.
   Mekanism's three osmium features (Minecraft 1.20.1: upper 65 x 7 at y 72..343 trapezoid with a
   plateau of 8, middle 6 x 9 at y -32..56 trapezoid, small 8 x 4 uniform at y -64..64) are mapped
   onto this world's bands: small veins of 4 in all rock from y 5 (3 per 128 blocks), 6 veins of 9
   per chunk on a trapezoid over y 5..197 ("more in the middle", densest near y 100), and veins of
   7 above y 197 (2 per 128 blocks). Osmium is about as common as iron below y 197 and about half
   as common above. Every feature draws from one random stream per chunk, in list order: new
   features go at the end, so earlier ores never move (a Generation test pins them).
5. **Structures** (up to `Config.StructureMaxLevel`): trees and cacti (`Structures.populate`), then
   the structure library's jigsaw structures (`StructureGen.luau`), whose air clears trees and
   whose structure voids keep them. See below.
6. **Glow lichen** (level 0 only, `CaveDecor.luau`), after structures, so it only clings to rock
   that is still there. See below.
7. **Ground plants** (level 0 only, `Foliage.luau`), after structures, so nothing grows under a
   trunk, leaves or a building. See Foliage below.

The generator also returns two hints the mesher uses to skip work: `solidBelow` (everything below is
rock or cave air; lowered under a structure's cells that are neither) and `emptyAbove` (everything
above is air; raised over trees, structures and plants). `TerrainGenerator.new(seed, options?)`
takes the structure library to generate (`options.library`, default `Library.load()` while
`Config.Structures.Generate` is on; `structures = false` for none);
`generator.structures(minX, minZ, maxX, maxZ)` lists the generated structures with a piece in a
rectangle and `generator.structureContainer(x, y, z)` the items a generated chest starts with.

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
eight corners are carved without interpolating. The carver returns the lattice cells it carved
(`Caves.Carved`: per 4 × 8 × 4 cell, not carved, carved in, or cave air throughout), so glow lichen
only looks where caves are. In Lune, caves cost ~5–7 ms per chunk under most
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
their real size from far away. A spot is refused near a library structure's piece (`accept`, see
below), so no canopy is cut by a hut and no trunk stands in a path.

### Library structures (`StructureGen.luau`)

The structure library's jigsaw structures (Structures/Library and Structures/Jigsaw, see
Structure blocks and jigsaw structures), Minecraft 1.20.1's JigsawStructure with its
RandomSpreadStructurePlacement, written right after the trees at levels up to
`Config.StructureMaxLevel`.

- **Starts.** Each structure cuts the world into regions of `spacing` × `spacing` chunks; region
  (rx, rz) has one start chunk at `region * spacing + rand(spacing - separation)` per axis, from a
  Hash rng of (seed, region, salt) (`StructureGen.startChunk`), and the start position is that
  chunk's minimum corner. The start piece alone is assembled first (`Jigsaw.assemble` at depth 0,
  the same draws the full assembly begins with): its box centre's column must be in one of the
  structure's biomes and, with `onLand`, dry and not bare rock (the generator's steep rule). Only
  then is the whole structure assembled, `size` levels deep. Every check reads full detail terrain
  through the generator's `firstFreeHeight` (Minecraft's WORLD_SURFACE_WG: the ground, or the
  sea's surface over water), `biome` and `land`, so every chunk and level agrees. Assembled starts,
  and rejected ones, stay in an LRU per generator of `CACHE_PER_STRUCTURE` (8) per structure, at
  least `CACHE_SIZE` (48), so the dozens of chunks a structure covers assemble it once per worker
  and a library of many structures doesn't thrash it.
- **Which starts.** Stateless, like trees: a chunk asks `starts` for every structure whose start
  position is within its `reach` (Library: every block within that many blocks of the start) of
  the padded box grown by twice the tree radius, and keeps those whose pieces' bounds touch it.
  Their highest block raises the chunk's crop (`top`); `treeAllowed` refuses vegetation spots
  within `TREE_CLEARANCE` (5) blocks of a rigid piece or `PATH_CLEARANCE` (1) of a terrain
  matching one.
- **Writing** (`write`), clipped to the padded box, in a fixed order (structure, region, assembly
  order), so where pieces overlap every chunk agrees on the result. `Jigsaw.writeTables` gives a
  piece's palette turned by its rotation (Blocks.rotate) and its jigsaws' final states; "keep"
  cells (structure voids, a final state of StructureVoid) are skipped, air clears terrain and
  trees, DATA markers are air in the template already. Rigid pieces sit at their box's y; a
  terrain matching piece puts each column's layer 0 on that column's top cell (the chunk's own
  heights, which are the full detail heights at level 0; at LOD its coarse, skirted top cell; over
  water the water's top). With `foundation`, air and water under a rigid piece's solid bottom
  cells down to the ground (at most `FOUNDATION_DEPTH`, 12 blocks) become the column's biome
  filler, a simple stand-in for Minecraft's beard terrain adaptation. LOD chunks point-sample like
  the tree writer: a cell takes the block the structure puts at its sample point, so buildings keep
  their size from afar. `write` returns one above the highest non-air cell it wrote (`emptyAbove`)
  and the lowest cell it wrote with a block that is not opaque, cave air or a cave twin
  (`solidBelow`).
- **Chests.** `container(x, y, z)` (the generator's `structureContainer`) looks up the template's
  container record at a world cell, a fresh copy of its items; the last piece writing there
  decides, and nil means no generated container. The server fills a generated chest from it the
  first time its contents are needed (see Server).

In a normal Luau VM a chunk under the example outpost costs within a few percent of plain terrain,
an outpost's assembly (~30 pieces) about 0.5 ms, and chunks with no start near them the same as
before.

### Glow lichen (`CaveDecor.luau`)

Minecraft 1.20.1's `glow_lichen` feature (104-157 tries a chunk on stone-type faces 13+ blocks
below the surface, ceilings and walls, spreading half the time) as patches decided per cell, in
full detail chunks after the structures:
1. Patches: one per 8³ block grid cell with chance 0.33, at a hashed centre with a hashed radius
   of 2..4. A chunk visits the patches whose sphere reaches its padded box, and in them only the
   cave lattice cells the carver carved (`Caves.Carved`), skipping those that are cave air
   throughout with cave air all round (no cell there touches rock): the work follows cave walls
   near patches, not the rock or the cave volume (an Underlands chunk has 100k+ cave air cells).
2. A cell must be CaveAir at least 13 blocks below its column's surface.
3. A face is a candidate when the block above, or north, south, west or east, is rock: Stone,
   Andesite, Diorite, Granite, Calcite and every block Ores places (ores are only in each chunk's
   own core, so counting them keeps a cell next to one deciding alike in every chunk). No floors,
   as Minecraft's feature.
4. A per-cell hash is rolled against 0.9 fading linearly to 0 at the sphere's edge (overlapping
   patches test the same roll against their own fade, so the order doesn't matter), and the cell
   becomes the cave twin (CaveGlowLichenUp, ...North...) on the first candidate face of a hashed
   rotation of Up, North, East, South, West: one face per cell.

Every cell is decided by the seed, its position and its in-buffer neighbourhood, so the padding
grows what the neighbouring core grows, except where the face is past the buffer (unknown, never
rock): harmless, as cave air and cave twins cull alike in both modes (tests/spec/CaveLichen meshes
both). About 3% of cave walls and ceilings get lichen (~20 a chunk, ~2 per 1000 cave cells, about
Minecraft's), 95% of it in patches, for ~0.2 ms a chunk (~5% of generation).

### Foliage (`Foliage.luau`)

Minecraft 1.20.1's vegetal decoration from each biome's `foliage` (BiomeList): grass, ferns and
their tall forms, dead bushes, flowers, tall flowers and mushrooms. It runs after structures, in
full detail chunks only: LOD cells are 2+ blocks wide, and every box of a plant is a part.

Every padded column is decided alone, from the seed, its world (x, z) and its own blocks, so a
chunk's padding grows exactly what its neighbour's core grows:
- the surface (the column's top cell from the fill) must be ground (Grass, DryGrass, Dirt,
  CoarseDirt, Podzol, Mycelium, Sand: `Foliage.GROUND`) in the plant's soil set
  (`Blocks.mayPlaceOn`), with air above it: a trunk, leaves, a cactus, water or ice there means no
  plant. Mushrooms, which may stand on any sturdy opaque block, also grow on that ground only (no
  beach gravel or bare rock);
- a per-column hash (`columnHash`, MurmurHash3's finaliser) is rolled against the biome's
  chances. Flowers take the bottom of its range and other plants the part above, so a column grows
  one or the other. Each chance is the biome's average (`density`, `flowers.chance`) over the mean
  of a patch ramp, times that ramp: 0 where a low-frequency noise (`Noise.fbm2`, ~24 blocks) is
  below a threshold (clearings), 1 above it (patches), fading in between. The threshold leaves
  `cover` of the ground in patches (0.5 by default, 0.3 for flowers), so `density` stays the
  average share of soil columns with a plant. Flowers have their own patch noise (~20 blocks);
- other plants are picked by weight from the same hash; a flower's species follows a wider noise
  (~128 blocks) made uniform, with a little per-column jitter, so neighbouring flowers are mostly
  the same species (Minecraft's noise-based flower providers);
- a tall plant also needs air above its lower half, inside the buffer, or it grows as its single
  form (tall grass as short grass, a large fern as a fern), or not at all (tall flowers).

The placer returns one above the highest cell it wrote, and `generate` raises `emptyAbove` to it.
Generated plants always satisfy `Blocks.canSurvive`, tall ones whole, so the server's Plant
behaviour finds nothing to pop.

Budget: averaged over a biome's soil columns, its plants cost at most 0.6 parts in jungles and
meadows, 0.45 on plains and savannas and 0.35 elsewhere (measured on generated terrain: about 0.5,
0.36-0.42 and 0.06-0.31). That is still 10,000-20,000 parts over every full detail chunk, so the
client draws them only near the viewer (see Streaming). Patches are noise thresholds (blobs and
winding bands) rather than Minecraft's clusters of tries, and the density is lower than
Minecraft's. tests/spec/FoliageGeneration checks the budget, determinism across borders (every
side and corner, next to trees), the placement rules and the cost (plants about 0.2-0.35 ms per
chunk in Lune; the edge columns' extra heights about 0.4 ms more).

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
- with `hideCaves`, cave air counts as rock and every cave wall disappears. **Cave twins**
  (`Blocks.caveTwinLut`: the CaveGlowLichen* generation puts on cave walls) count as cave air
  then: they have no appearance (`appearanceHiddenCaves`), are rock to their neighbours
  (`Blocks.cullLutHiddenCaves`) and are cave air to the stone caps at a revealed section's hidden
  sides (see Streaming), so a hidden cave's lichen costs nothing and hides nothing;
- **sparse lights** (`sparseLightLut`, per appearance: glow lichen) are drawn in every cell, but
  only one cell per `LIGHT_BOX`³ (8³) block box carries the light: the one nearest the box's
  centre (`lightScore`; on a tie the lowest, then northmost, then westmost). Boxes are world
  aligned and divide sections and chunks, and the choice depends only on the cells in the box, so
  the same blocks always light the same cell and lights never jump on a remesh. The chosen cell's
  key has surface field 1 (`decodeKey`), the others 0;
- **plants** (`Blocks.foliageLut`) are shaped single cells like torches. With `hideFoliage`
  (`Config.Render.Foliage` off, or a chunk beyond `LodTree.drawsFoliage`; see Streaming) they are
  not meshed; they hide nothing, so every other box stays the same. `mesh` also returns how many
  plant cells the range holds, drawn or not. A **tinted** plant's key (`Blocks.tintedLut`: grass
  and ferns) carries its soil's foliage tint, `Blocks.tintLut` of the block below (below its lower
  half for a tall plant's top), in the surface field fluids use for their height; `decodeKey`
  returns it and the appearance tells the uses apart (a shaped block is never a fluid, and no
  tinted plant gives light, so the sparse light flag never clashes with a tint). Border copies
  (`applyBorder`) keep two layers below the range for it.

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
median distance, plus a section, sets the radius between `Caves.RevealRadius` (64 blocks,
tunnels) and `Caves.RevealRadiusMax` (128, big caverns such as the Underlands); phones use
`Caves.Mobile` (48 and 96: `ViewSettings.revealRadii`). It grows at once and shrinks only
after two seconds, so the revealed sections do not churn. Caves only exist in full detail chunks,
so a cavern ends where they do. Where a revealed tunnel runs into hidden space (a hidden section above
or below, a neighbour chunk whose section is hidden, or a coarser node), nobody would draw its walls
there and you would look into the void. A revealed section is therefore meshed with a mask of those
sides (`GreedyMesher.Border.hidden`): hidden cave air beyond them counts as rock, and its own cave
air touching that rock becomes a stone cap. It is remeshed when the mask changes. Which sections
are revealed and their masks are pure (`CaveReach.reveals`, `CaveReach.capMask`;
tests/spec/CaveView).

**The underground split.** Full detail chunks are the only ones with caves, so above ground's
full detail range (~96 blocks) would end every cave there. While the cave view is active (the
camera below its column's surface) and for `Lod.UndergroundSeconds` (5) after it ends
(`CaveReach.hold`, so walking in and out of a cave mouth does not rebuild the chunks around it
back and forth), `LodTree.select` runs with `underground`: level 1 nodes split at
`Lod.UndergroundSplitDistanceL1` (4, phones 3) instead of `SplitDistanceL1`, so full detail and
caves reach ~128 blocks; coarser levels are unchanged. Level 1's hysteresis holds within one mode
only (`previousUnderground`): the first selection after going underground splits every level 1
node within the new distance, as a fresh selection would, instead of keeping the leaves of the
selection above ground. Walking keeps full detail up to ~15% short ahead of the camera, as the
hysteresis does above ground. Measured in a cave near the spawn (seed 12345): 268 full detail
chunks instead of 164 and ~57,000 parts instead of ~47,000 (~139,000 instead of ~110,000 in the
Underlands, before far meshes). F3 shows how far caves are revealed and the split in use.

**Plants.** Every box of a plant is a part, and all ~180 full detail chunks would hold
10,000-20,000 of them. So only full detail chunks within `Lod.FoliageDistance` of the viewer (40
blocks to the chunk's square, 24 on phones through `ViewSettings`; one already drawing them keeps
them up to half a chunk further) draw their plants, while `Render.Foliage` is on
(`LodTree.drawsFoliage`): about 1,000-3,000 parts on grassland, at most 6,000. Jobs carry the
node's `foliage` and workers report which sections hold plants (drawn or not); when a chunk
starts or stops drawing them (the viewer moved, `Render.Foliage` changed), each refresh remeshes
only those sections, like edited ones. A node with a generation job queued or running is left to
that job, which takes the current answer.

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

**Plants.** A `scatter` appearance's boxes are drawn off the cell's centre and turned about its
vertical axis: `Meshing/Scatter.at` hashes the world block position (the node's origin plus the
cell; not the seed, like Minecraft's OffsetType) into an offset of up to ±3 pixels along X and Z
(16 steps) and a turn (64 steps). Each box goes to the centre plus the offset, turned by the yaw,
then by its own rotation. A tall plant's top uses its lower half's position, so both halves line
up; the sunflower is never turned (its head faces east, as in Minecraft, which turns no plant).
Every plant's boxes stay inside its outline whichever way they turn, and within a pixel of the
cell after the offset (BlockList, tests/spec/Plants). The outline does not move (Minecraft's
does). Tinted boxes (grass and ferns) are coloured authored colour × `Blocks.FOLIAGE_TINTS[tint]`,
each channel clamped, with the tint from the box key; their parts' colour is set every time, since
a pooled part may come from a cell with another tint. An edit that changes a soil's tint two cells
below a section's bottom also remeshes that section (`ClientWorld`): a tall plant's top there
reads its tint from it.

**Glow lichen's lights.** A revealed cave can hold 1,000-3,000 lichen, and a PointLight each
would be far too many. The mesher marks one lit cell per 8³ box (sparse lights, see Meshing); for
the others PartPool's `acquire(..., dark)` gives the light's box from a "dark" template, the same
part without its PointLight, so lit and unlit lichen look alike (a Neon speck). Even so a revealed
cavern holds hundreds, so ChunkRenderer keeps every lichen light's part and position and switches
on only those within `Caves.LichenLightDistance` of the camera (32 blocks, 24 on phones:
`ViewSettings.lichenLightDistance`), every 0.25 s, turning them off again 8 blocks further: a few
dozen in a cave (in the CaveView test scene 1,272 lichen, 343 lit cells, ~56 on). Lichen lights
cast no shadows: they are dim, short and many, and lichen grows only deep underground, so a glow
reaching through a thin cave wall shows nowhere it shouldn't. Each lichen is two parts, its plate
and the Neon speck that carries the light. The renderer counts parts with a light (`lightCount`)
and lichen lights (`sparseCount`, `sparseOn`) for F3.

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
  12 on blocks of its kind; swords 1.5 on leaves; shears 15 on what they harvest, `shearDrops`, so
  leaves break at once) / hardness / 30, or / 100 if the block needs a tool it can't harvest with
  (stone by hand, iron ore with a wooden pickaxe), five times slower in the air or under water.
  Switching to another item restarts the block. The client sends `Mine` when it starts on a block
  and when it stops early. The first tick on a block only starts it (Minecraft's
  `startDestroyBlock`), and `CrackOverlay` draws the ten crack stages as the progress grows
  (procedural lines on SurfaceGuis, no assets) on the block's outline like the highlight, so they
  fit a lantern instead of its cell. At 100% the block breaks, then mining pauses for 5 ticks.
- **The server** only counts a `Mine` start for a minable block in reach. It accepts the break if
  the player started mining that very block long enough ago (`Mining.mayBreak`: 70% of the time,
  Minecraft's tolerance) with the tool held when the break arrives, drops `Items.drops(block,
  tool)` (nothing when that tool can't harvest it; with Shears, the block's `shearDrops`) and
  wears the tool (`Mining.wear`: 1 per block, 2 for swords, none on instant blocks, but Shears 1
  on every block, instant ones too; it breaks at its durability). A break that arrives earlier
  still (network jitter) is kept and finished once the full time has passed, or undone after a
  second, like Minecraft's delayed destroy. Only one timer runs at a time: a block started
  meanwhile counts from when the waiting break is done.
- **Creative** breaks at once, again every `Interaction.BreakInterval` (6 ticks) while held (not
  with a sword in hand, as in Minecraft), and drops nothing. Creative players make items from nothing, so the stacks they throw or spill by
  breaking a chest come out of a budget (10 a second, 64 at once); a chest that would overdraw it
  stays.
- **Using and placing.** Right click on a block with a `menu` (chest, crafting table, furnace)
  opens it, unless sneaking with an item in hand.
  Otherwise the selected item is placed if it is a block. Survival placing uses the item up: the
  Edit message carries the inventory action number of that use (see below), so the prediction
  and the server's answer line up. The own hull is checked standing, like the server checks every
  player. A block goes into the clicked block if that is replaceable and the held item is not its
  own (`Items.isReplacedBy`, Minecraft's canBeReplaced: Short Grass clicked on short grass goes
  beside it), else against the clicked face.
- **Plants** place through `placementFor` (their soil, and room for a tall plant's top:
  `Blocks.canPlace`). The client predicts only the half of a tall plant it places or breaks; the
  server sets or removes the other and replicates it as an ordinary edit (block edits carry no
  action number, so nothing needs reconciling; a placement's `seq` still settles the item). Until
  it arrives the other half stands alone, and breaking it meanwhile is answered with air. Debris
  of grass and ferns takes the soil's tint.
- **Operator blocks** (`Blocks.isCreativeOnly`: structure blocks, structure voids, jigsaws). In
  creative a right click on a structure block or jigsaw sends a Use, which the server answers with
  its screen (Structure blocks and jigsaw structures, below) or a refusal; in survival they are
  plain blocks to build against, and their items are not placed. A jigsaw's orientation comes from
  `Blocks.placementFor` (Minecraft's JigsawBlock.getStateForPlacement, `Blocks.jigsawPlacement`):
  the front faces out of the clicked face; a horizontal front has its top Up, a vertical one the
  opposite of the player's horizontal facing (`Blocks.horizontalFacing`, Direction.fromYRot). The
  structure block's item places SAVE mode (Minecraft places DATA), and glow lichen, like a torch,
  the variant on the clicked face's side.
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
    "✔ Requires Stone Pickaxe", "✘ ...", "✔ Tool: Axe" or "Unbreakable"; operator blocks say
    "Creative only" instead (F3: "Breaks in creative only (at once)");
  - a structure block's mode and name ("Mode: Save", "Name: hut"; a DATA block its marker) and a
    jigsaw's name, target and pool, from the records Net/StructureNet keeps (F3 adds a structure
    block's region and, in LOAD mode, its rotation, mirror, integrity and seed);
  - while the F3 overlay is open (`DebugOverlay.isOpen()`), gray lines: `Stone #3`, position,
    chunk (floored, with the local column), biome (`generator.column`), hardness, tool kind and
    level, drops with the held item and by hand (`Items.drops`; a tall plant's top shows its lower
    half's, which breaking either half harvests), break time (`Mining.ticks / 20`,
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
the camera (`LightingController.dayTime`, `skyExposure`); the PointLights in the world (lichen
lights: on of all); and the cave view (how far caves are revealed, the level 1 split in use).

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

**Solar panels** (server). `DayCycle.isDay` is Minecraft's Level.isDay in clear weather, the sky
darkening by less than 4 (`skyDarken`): from tick 23 460 (the sun about 4 degrees up) to 12 540.
`DayCycle.sunBrightness` is Mekanism's getSunBrightness, a copy of ClientLevel.getSkyDarken:
`skyBrightness x 0.8 + 0.2`. The Solar Panel reads both on the server's clock (`TimeOfDay.get`,
MachineWorld's `dayTime`).

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
the 20 Minecraft armor pieces, sticks, coal, raw ores, ingots, nuggets (Minecraft's and Mekanism's osmium), gems, snowballs, the 25
tools and Shears) have ids from 4096 up. A stack is `{ item, count, damage }`, at most `maxStack`
(64; armor and tools 1, snowballs 16); `damage` is a tool's wear (`durability`: wood 59, stone
131, iron 250, diamond 1561, gold 32, shears 238). Blocks say how long they take to mine
(`hardness`), which tool harvests them (`tool`, and `toolLevel` when only that tool of that tier
or better drops anything: iron and osmium ore need stone, diamond, gold and emerald ore iron),
what they drop (`drops`, `dropCount`: snow gives 4 snowballs; `shearDrops`, `shearCount`: what
Shears get instead), what right click opens (`menu`) and how many slots they hold (`container`).

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
| `machine`   | its kind's slots (0 or more), plus `data` (energy first) | shared |

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
A shaped recipe with `keep` (a key character it uses once) gives its result that ingredient's item
data as it is (`Recipe.keep`, the cell; Mekanism's MekDataShapedRecipe): a Battery crafted into the
next tier keeps its charge. Other results carry none.

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
  slots change, and every other tick while only the gauges move. Every 10 ticks the furnaces whose
  output holds something (`Containers.ejectingFurnaces`) push it into the chests next to them
  (`Transmitters/Eject`, below).

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
  from the furnace's `data`. Worn tools show Minecraft's durability bar, and machines' items that hold energy an energy bar in its place.
- `CreativeScreen` (`E` in creative): the "Item selection" picker, a search box that filters
  `Items.search` as you type, an 8-column scrolling grid, and the hotbar under it. Clicking an item
  gives a full stack; dropping a stack on the grid deletes it.
- `SlotClicks` turns mouse, keys, touch and gamepad into Minecraft's click actions (pure, tested).
- `Screens` opens and closes them, frees the mouse (in first person too) and stops the character
  while one is open. Other modules' screens (the structure block and jigsaw screens) are shown as
  panels (`showPanel`, `closePanel`) with the same darkened world and free mouse but none of the
  inventory's input.

**Item icons and models** (`Rendering/ItemModels`, `Ui/ItemIcon`). An item's model is a cube with the
block's look (the terrain's part template: material, colour, texture, face images), or the item's
boxes. Icons show it in a ViewportFrame, lit so the top is brightest, then the left face, then the
right. They are built once per slot and only rebuilt when the item changes. The same models are
dropped items and, in `Player/HeldItems`, the item in each character's hand (from the
`IceVoxelHeldItem` attribute the server sets) and in the first person corner. Tools and sticks lie
diagonally in icons (`tilt`) and are held by the handle, pointing forward. Plants are shaped-block
items: icons from the front, held upright like blocks, dropped like items, drawn untinted (the
Grass block's green); a tall plant shows its `icon`, the lower half plus the top's look in one
cell. Shears are a tool: diagonal in icons, held by the handles.

**Decorated blocks** (`Rendering/BlockDecor`). Chests, crafting tables, furnaces, the Creative
Energy Cube, the Heat Generator, the Electric Furnace, the Batteries, structure blocks (Minecraft's
dark purple block with the mode's sigil on every face) and jigsaws (the puzzle piece on the front,
the lock towards the top, arrows on the other sides, turned per orientation) are drawn without image
assets from pure face data (rectangles on a 16 × 16 grid per face): in the world as SurfaceGuis on
their parts' templates (recycled parts keep them; they stop drawing beyond 96 blocks), and on item
models as thin raised slabs, since ViewportFrames don't draw SurfaceGuis.

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

There is no light field in the block data; Roblox's lighting engine does the rest. Glow lichen
(light 7) is the exception to one light per block: only some of its cells carry one (see Meshing
and Rendering).

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

**Plants** (`Blocks`, BlockList `plant`; Minecraft's BushBlock family). The 29 plant blocks
(short grass, ferns, dead bushes, flowers, mushrooms and both halves of tall grass, large ferns
and tall flowers) are shaped blocks: one part per box, at most 4, every box inside the outline
whichever way the client's scatter turns it. They are not solid and do not `obstruct` (players
walk through them, and a plant may be placed where a player stands), break at once, sound like
grass, are `brokenByFluid` and stand through the attached-block machinery:
- Standing: a single plant or lower half has `support = "Down"`, but needs a block of its soil set
  below instead of a sturdy one (`Blocks.mayPlaceOn`: "dirt" = Grass, DryGrass, Dirt, CoarseDirt,
  Podzol, Mycelium; "deadbush" adds Sand; "mushroom" = Mycelium, Podzol or any sturdy opaque cube,
  without Minecraft's light check, as there are no block light levels). An upper half
  (`plant.bottom`) needs its own lower half below. That is `Blocks.canSurvive`; `Blocks.canPlace`
  adds room for a tall plant's top (y + 1 below `Config.WorldHeight` and replaceable), and
  `placementFor` and `EditRules.supported` use it. Upper halves have no `support`, so
  `placementFor` never returns one.
- Halves: `plantTop`, `plantBottom`, `otherHalf` (the partner's dy). Upper halves name the lower
  half as their `item`, so `Items.ofBlock` gives the plant's item (WAILA, pick block, placing) and
  they are its variants; they are no item of their own and drop nothing. Each half of a tall plant
  is aimed at and outlined as a full block (DoublePlantBlock keeps a block's default shape); the
  others have Minecraft's outlines (grass, ferns and dead bushes 2..14 x 0..13 pixels, flowers
  5..11 x 0..10, mushrooms 5..11 x 0..6).
- Replacing: short grass, ferns, both halves of tall grass and large ferns, and dead bushes are
  `replaceable` (Minecraft 1.20), so anything placed there replaces them without a drop; flowers
  and mushrooms are not.
- Look: per appearance `foliage` (every plant, `Blocks.foliageLut`), `tinted` (grass and ferns,
  `Blocks.tintedLut`), `scatter` and `upperHalf`; plants never share an appearance with other
  blocks. A soil's `foliageColor` (only DryGrass, a savanna yellow-green) becomes a multiplier of
  the authored green (foliage colour / Grass colour) in `Blocks.FOLIAGE_TINTS`, indexed by
  `Blocks.tintLut[soil]` (u8 per block, 0 = none, at most 63 so it fits the mesher's key). See
  Meshing and Rendering.
- Drops: `Items.drops(block, tool)` gives Shears a block's `shearDrops`, `shearCount` of it
  (Minecraft's `match_tool shears`: tall grass 2 short grass, large ferns 2 ferns; short grass,
  ferns, dead bushes and leaves themselves), and the usual drops to anything else: nothing for
  grass and ferns, a stick for a dead bush (Minecraft: 0-2), the flower or mushroom itself.
  Shears (ItemList: tool kind "shears", speed 15, 238 uses; Minecraft's recipe, two iron ingots on
  a diagonal) mine `shearDrops` blocks at 15 (`Mining.toolSpeed`) and wear 1 on every block they
  break, instant ones included (`Mining.wear`, Minecraft's ShearsItem.mineBlock); creative
  players' tools never wear.
- Server: `Behaviours/Plant` re-checks a plant when a neighbour changes (`Plant.stays`: soil or own
  lower half below, own top above a lower half; unloaded blocks are waited for) and breaks it with
  its no-tool drop and a sound; players' tall plant edits are EditRules' (see Server).

**Operator blocks** (BlockList `creativeOnly`; Minecraft's GameMasterBlock): the four structure
block modes, the structure void and the twelve jigsaws. Survival players can't mine them
(`Mining.progressPerTick` is 0, Minecraft's hardness -1); creative players break them at once like
any block, and they never drop (`Items.drops`, `Items.blockDrops`); placing, breaking and using them
needs the server's `operator` rule (see Server). They are in the creative picker and JEI
(`Items.isCreativeOnly` tells their items).
- A structure block's mode is its block (`structureMode`: StructureBlock is SAVE and the item,
  then StructureBlockLoad, ...Corner, ...Data; `Blocks.structureMode`, `structureBlock`), so the
  server swaps the block when the mode changes and everyone sees the mode's sigil (BlockDecor
  "StructureBlock<Mode>"). A variant group without supports places the item's own block.
- A jigsaw's orientation is its block (`jigsaw = { front, top }`, Minecraft's FrontAndTop: a
  horizontal front with top Up, or front Up / Down with a horizontal top; Jigsaw is North / Up and
  the item, then `Jigsaw<Front><Top>`; `Blocks.jigsawOrientation`, `jigsawBlock`,
  `jigsawPlacement`). BlockDecor turns its pictures towards the front and top on each face.
- The structure void is not solid and replaceable but holds no fluid (Behaviours/Fluid), drawn as
  a 6 pixel translucent cube with that outline (Minecraft draws nothing).
- `Blocks.rotate(id, rotation, mirror)` (and `rotateLut` for hot loops) is the block after its
  structure is turned: mirror first ("leftRight" flips Z, "frontBack" X), then quarter turns
  clockwise from above (`turnDirection`); wall torches and glow lichen become the variant hanging
  on the turned side, jigsaws the turned orientation, everything else stays. `Blocks.find(name)`
  gives an id or nil, for names that come from data.

**Glow lichen** (Minecraft's GlowLichenBlock, one face per block): GlowLichen on the floor (the
item), GlowLichenUp on a ceiling and GlowLichenNorth / South / West / East on walls, through the
torch machinery (`support`, `Attached`, `placementFor`). Light 7 in a cool yellow green, hardness
0.2, mined fastest with an axe, drops only with Shears (`shearDrops`; Shears mine it at 2,
`shearSpeed`, Minecraft's ShearsItem.getDestroySpeed), replaceable and `brokenByFluid`. Its shape is
a 13 × 13 pixel plate a tenth of a pixel off its face and a 3 × 3 pixel Neon speck, the `glow` box
that carries the light: two boxes, two parts. Its outline is a pixel thick plate over the face.

**Cave twins** (BlockList `caveTwin`): CaveGlowLichen and its five sides, the lichen generation
puts in caves. A twin looks, drops and behaves exactly like its twin (same appearance, item,
support, light, hardness, drops and behaviour; checked at load), but counts as cave air while
caves are hidden (`cullLutHiddenCaves`, `caveTwinLut`; see Meshing), as CaveAir is to Air. Players
never place one: twins are no variants of their item (`placementFor` never returns one, EditRules
refuses them), `Blocks.rotate` keeps a twin a twin, and `Blocks.surfaceForm` turns a twin into
its twin and CaveAir into Air when a structure is saved (`caveTwinOf`, `caveTwinFor`, `isCaveTwin`).

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
  is an Advanced Fluid Tank made from a tank holding water), except a recipe's kept ingredient's
  (Recipes `keep`: a Battery crafted into the next tier keeps its charge); what stays in the grid
  keeps its own.
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
(`CATALYSTS`: the crafting table for crafting, the furnace and the Electric Furnace for smelting, the furnace and the Heat Generator for fuel), also uses every
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
Minecraft's buckets. Universal Cables are described in Electricity and machines; Pressurized Tubes
and Thermodynamic Conductors are out of scope: there is no gas or heat.

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
(+Z), 4 West (-X), 5 East (+X); side s of a block at p faces p + offset(s), and opposite(s) is s
xor 1. Each side of a transmitter has Mekanism's ConnectionType, which the Configurator cycles
NORMAL -> PUSH -> PULL -> NONE: NORMAL and PUSH may hand items or water to an acceptor (`outputs`),
PULL takes from it (`pulls`) and never gives, NONE cuts the side; NORMAL and PULL transporter sides
take what a furnace or machine pushes out (`receives`, Mekanism's canReceiveFrom). The six modes
pack into 16 bits, 2 a side, side 0 lowest (0 = all NORMAL, at most 4095), which is how they are
stored and sent. Transporters may be coloured with Minecraft's 16 dyes (1..16, 0 none; sneaking
with the Configurator steps through them and back to none).

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
facing the transmitter (a transporter on a furnace reaches its face Up). Furnaces and machines
follow Mekanism's machine rules, the same on every face. (Furnaces used to be Minecraft's
WorldlyContainer, fuel through the sides, so a transporter pulling from a furnace's side took the
fuel players put in straight back out; Mekanism's logic was chosen instead.) A furnace takes in
through any face {input, fuel}: the input only what smelts (Mekanism's input slots take only valid
recipe inputs), the fuel only fuel, so ore goes into the input, coal into the fuel and logs into
the input first, then the fuel when the input can't take them (a furnace is filled slot by slot, as
Mekanism fills a machine's slots); the output takes nothing. Through any face it gives {output,
fuel}: the results, and from the fuel slot only what no longer burns (an empty bucket: Mekanism's
FuelInventorySlot); never the input or the fuel. A chest gives every slot to every face. `insert`
and `room` top up stacks of the same item and wear first, then fill empty slots, up to the item's
max stack (Forge's insertItemStacked, as Mekanism inserts); `available` lists the item types a face
gives with their totals (Mekanism's TransitRequest) and `extract` takes up to n of one type, a
stack at most. They are pure (new slot tables out, inputs untouched), so the server simulates a
delivery with the same calls it applies. A pipe's fill travels as a byte (`fillLevel`: 0 empty, at
least 1 with anything in it, 255 full).
A machine reaches the slots its kind gives each face (`Machines.insertSlots` / `extractSlots`):
the Heat Generator takes fuel through every face and gives nothing; the Electric Furnace takes
what smelts and gives its results through every face (Core's defaults).
Upgrade slots (`Machines/Upgrades`) are reached through no face, so a machine with nothing else (the
Solar Panel) is no inventory and transporters don't connect to it.

**Pushing results out** (Mekanism's ejector: `Transmitters.ejects`, `ejectSlots`, `results`,
`takeResults`, `isPlain`). A furnace (its output) and a machine with output slots
(`Machines.outputSlots`: the Electric Furnace's; the Heat Generator and Solar Panel have none)
push what those hold out on their own, a stack at most every 10 ticks:
- into the transporters next to them whose side receives (`Transmitters.receives`: NORMAL or
  PULL, Mekanism's canReceiveFrom; never PUSH or NONE), in the transporter's pull pass (below);
- into the plain inventories next to them (chests and any other `container` block that is no
  furnace and no machine), through their face towards it (`server/Transmitters/Eject`);
- never straight into another furnace or machine (no surprise chains such as cobblestone to stone
  to smooth stone); transporters still lead results into one when a line goes there.

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
  - Pulling: a transporter with PULL sides on inventories, or NORMAL sides on furnaces and
    machines that push their results out (`pullers`, worked out with its links), pulls through
    each such side, one pass a side, then waits 10 ticks (3 when nothing was there,
    min(40, e^failures) when items found nowhere to go). The item types the side may take are
    tried in order: a PULL side what the inventory's facing side gives (`Transmitters.available`:
    a furnace's or machine's results only), a NORMAL side what a furnace or machine pushes out
    (`Transmitters.results`). The first with a destination sends up to the tier's pull amount (a
    whole stack from a furnace or machine: the ejector's), never more than fits there or a stack.
    Destinations are found before anything is taken, and the item takes the puller's colour.
  - Routes: Dijkstra from the item's transporter, adding `pathCost` for each transporter entered
    and only entering ones that `carries` its colour. The cheapest inventory (then fewest steps)
    on a NORMAL or PUSH side that takes at least one item wins. Room counts the items already on
    their way there (Mekanism's TransporterManager). The source inventory is excluded except as
    "home" (reachable through any joined side; a furnace's or machine's results have no home, so
    they never go back in); with neither, the item waits in the middle of its transporter and
    looks again every 20 ticks. A search visits at most 4096 transporters, and
    once a tick's searches have visited 4096, waiting items and pulls carry on the next tick
    (moving items always re-route), so big networks full of waiting items cannot stall the server.
  - Moving: progress grows by the transporter's speed each tick (100 = a block). Halfway, the way
    ahead is checked (and re-routed if closed); at 100 the item enters the next transporter, or the
    inventory: what fits goes in (viewers get a snapshot, a furnace wakes) and the rest re-routes.
    A broken transporter drops its items (Entities.dropBlock).
  - Chests next to a furnace or machine (`Eject`, pure): every 10 ticks the results go into them
    in side order (Down .. East), the first item type that fits anywhere, up to a stack, as much
    as fits; what goes in decides what comes out, so nothing is lost or made. Players/Inventories'
    furnace loop runs it for the furnaces with results (Containers' `ejectingFurnaces`), and
    MachineWorld's step for machines with output slots, after their tick. Both containers'
    viewers get a snapshot (`containerChanged`) and the furnace is ticked again. Blocks are read as
    the pipes read them (peekBlock, else the edit list), never generating terrain.
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
    replaceable or the block beyond its side; what the water replaces drops what it drops by
    itself (`UseRules.pour`: short grass nothing, a dead bush a stick); survival gets the empty
    bucket back.
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
face; turns at centres). The way into the first block is not sent: an Add for a known item takes it
from its previous route (`entryOf`), a newly pulled one from the transporter's one PULL side on an
inventory, else (no PULL side) its one NORMAL side on a furnace or machine that pushed it out
(`pullEntry` with the acceptor sides whose block `ejects`), else it comes in straight. Models
(ItemModels, 0.35 blocks, turning slowly on the client's clock) are pooled per item, at most 256,
and moved with one BulkMoveTo per frame. Remove(arrived) lets an item finish its way (at most 1 s),
dropped / gone remove it at once, an item whose way ended goes after 0.5 s, and one out of range
for 60 s is forgotten.

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

## Electricity and machines (`Machines/`, server `Machines/`)

Mekanism's energy, in joules (`Items.formatEnergy`: J, kJ, MJ, GJ), and the framework every
machine is built on.

**Universal Cables** are transmitters of kind "energy", Basic to Ultimate, with Mekanism's
CableTier capacities (8 000, 128 000, 1 024 000, 8 192 000 J/t; `Transmitters.cableCapacity`).
They are Mekanism's small transmitters: a 6 pixel core, a red-ish conductor in a frame of the
tier's colour; the client draws thinner opaque arms (4 px, 5 px collars, 8 px plates:
`TransmitterModel.sizes`) and the Configurator aims at the smaller core. They connect to cables
of any tier and to energy blocks (any machine, `Transmitters.isEnergyAcceptor`) on every side
that is not NONE; PUSH and PULL act as NORMAL. They are TransmitterWorld nodes like pipes (modes,
the Configurator, Transmitters records) without a network there: a cable that comes, goes or
changes links is flagged in `energyDirty` for the energy networks.

**Machines** (`Shared/Machines`: init loads Core and every kind in `Kinds/`, then binds BlockList
blocks with `machine`). A machine block has `machine = { kind }` and `energy = { capacity, input?,
output? }`; output only makes it a producer, input only a consumer, both storage (`Machines.role`).
A kind (`Core.define`) gives its slots (panel position, what each takes, outputs, limits,
transporter faces and an outline shown while empty, `ghost`), data fields, fields kept in the item,
its panel, its server tick, a status line, optional rate overrides and an optional state field: a
code (0..255, `Machines.state`) saying why it is not working, which Machines records carry and
`status` gets as `view.state`. Its tick gets a context (`TickContext`): the block, its energy spec
and position, the server's day time (`dayTime`, World/TimeOfDay) and whether a cell sees the sky
(`sky(x, y, z)`, below). Its contents are a container of kind "machine" (Types.KINDS) with the
kind's slots and f64 `data` (at most 16): a header every machine shares, 1 energy, 2 capacity, 3
input and 4 output (what the network moved last tick), 5 rate (made +, used -), 6 active, then the
kind's fields. Inventory/Menu asks Machines for a machine's slot rules, limits and outputs, and
shift-clicks from the inventory into the slots that take the item in one pass (Mekanism's
MekanismContainer; only when none takes anything does it move between the inventory and the hotbar).
A machine with slots transporters reach is an inventory for them (Transmitters/Inventories), through
the faces its kind gives each slot (by default inputs take items through every face and outputs give
them out through every face); one whose slots no face reaches (the Solar Panel: upgrade slots only)
is none. A machine with output slots pushes what they hold out on its own (Mekanism's ejector,
every 10 ticks, into the transporters and chests next to it: Pushing results out, above). Energy
is kept in multiples of 1/1024 J (`QUANTUM`), so sums and differences are exact;
`produce` and `use` keep it so, and `share` is Mekanism's even split in whole quanta: every
recipient gets the same share, those that take less get all they take and the rest is shared again,
smallest limits first.
A kind's `lines(view)` gives up to `MAX_LINES` (4) more panel lines under its status line, where
its panel's `lines = { x, y }` puts the first (`Machines.lines`; one every 12 pixels,
`MenuLayout.LINE_HEIGHT`, as many as fit the panel).

**On the server** (`server/Machines/`). `MachineWorld` (pure) keeps a machine per machine block
(`blockChanged`, chained onto WorldServer.onChanged after Inventories and Transmitters) and
creates its container in Players/Containers at once, so a machine works before anyone opens it;
machine containers are never forgotten while their block stands, and a broken machine's slots
drop through Inventories like a chest's. Each `step` (20 a second, Machines.update right after the pipes): queued network work, every
machine's kind tick (`Machines.tick`: afterwards, even when the kind's tick errors, which is reported
once per kind, the data holds no NaN and energy is within 0..capacity in whole quanta), then
`EnergyNet.solve` (a kind whose `rates` override errors moves nothing). `EnergyNet` (pure) joins
cables (`links`), cables and machines (`acceptors`) and directly adjacent machines into networks;
positions whose links changed dissolve their network and their neighbours' and are flood filled
again, at most 4096 a tick (the rest carries over and waiting positions move nothing meanwhile). A
change at or next to a position the fill in progress has visited starts it over; one elsewhere
leaves it going, so players building elsewhere never starve a big network's fill. Per network and tick: producers' supply
(their energy, at most their output rate) goes to consumers' demand (their room, at most their
input rate), at most the throughput (the cables' capacities summed, unlimited without cables),
split evenly both ways; what producers still have charges storage up to its input rates, and
what consumers still need is covered by storage discharging up to its output rates, within the
throughput left. Storage never charges storage. What is taken is exactly what is given.

Viewers of a machine's window get a snapshot at once when its slots change and every 2 ticks
while only its data moves (as furnaces). `Machines` records (energy, capacity, input, output, rate, active, the kind's state code) go to players within 192 blocks sideways when they change, at most 4 a second per
machine, and with a chunk's edit list when not in the default state (empty, idle, the block's capacity, state 0). Mekanism's sustained data (`MachineWorld.blockDataHooks`): a survival break keeps the
energy and the kind's `keep` fields in the item's data (`Machines.save`; the creative cube keeps
nothing), and placing that item puts them back (`Machines.restore`, at most the capacity).

**The sky** (`MachineWorld.seesSky`, `Machines/SkyCheck`). A kind asks whether a cell sees the sky
straight up with its context's `sky(x, y, z)`: nothing opaque (`Blocks.isOpaque`: full cubes,
leaves, ice; glass, water and shaped blocks let the light through) in any cell above it, Mekanism's
solar generators' check (Minecraft's canSeeSky, which wants the full sky light, so water blocks it
there). `SkyCheck.open` (pure, tested) never generates a chunk: a chunk the server holds is read as
it is (terrain, trees, edits; everything from its crop height up is air), and any other column is
its edit list over the generator's ground height for that one column (`TerrainGenerator.column`):
unedited cells below the ground count as ground (a natural cave a dug shaft passes through too) and
unedited cells above it as air, so trees and sea ice are only seen in loaded chunks. MachineWorld
caches the answers per cell (at most 65 536, then they start over) and keeps them true from
`blockChanged`, which every block change reaches: an opaque block covers the cells below it at
once, and a covered cell whose roof may have gone (an opaque block replaced by anything else) is
looked at again when next asked, a tick later, with its chunk just loaded by that change. A
machine's own cell is forgotten when it goes. Without a game look (tests) the cells above are read
with `getBlock`.

**On the client.** TransmitterRenderer keeps Machines records like Tanks records
(`machine(x, y, z)`); WAILA shows "Energy: 1.2 kJ / 20 kJ" and the status (`Machines.status`:
the kind's, else "Producing x/t", "Using x/t", "Charging" / "Discharging"), and for cables
"Capacity: 8 kJ/t" (a side set to push or pull reads "Push (as Normal)"), with F3 details (a
cable's network line counts the cables linked to it as the client sees them; the server's network
may also join cables through machines). A machine's panel (MenuLayout) is its kind's: slots where it puts them (a slot with a `ghost` shows that outline while empty, as empty armor slots do: the upgrade cards'), the title centred, Mekanism's GuiVerticalPowerBar (6 x 52 at (164, 15), filling
from the bottom in whole rows rounded down, at least one while it holds any, red when empty
through yellow to green when full, "stored / capacity" on hover), and the arrow, flame, status line and lines it asks for, read from the data fields it names. The panel reads the window's data without
changing it and redraws only when a snapshot replaces it.
Machines whose decor has a window (`TransmitterModel.hasMachineBoxes`: the Heat Generator and the Electric Furnace) are
TransmitterRenderer cells like tanks, redrawn on each record: `machineBoxes` gives a working one
a Neon pane over its window on each of its four sides (BlockDecor.GENERATOR_WINDOW and ELECTRIC_FURNACE_WINDOW, 0.2 px out of the face). `activeMachines(x, y, z, radius, filter)` lists the working machines near a point from
their records (Audio/Ambience).
Batteries (`hasMachineBoxes`) are cells too: `machineBoxes` fills each side's gauge
(BlockDecor.BATTERY_GAUGE) from the bottom with `chargeRows` of its 10 rows (the record's energy
over capacity, rounded down, at least one while it holds any, as the panels' bar), a Neon pane
in `Machines.energyColour` of that fill (red when nearly empty, yellow, green when full; the
panels' energy bar and items' energy bars use the same function); the signature names the rows,
so a battery is redrawn only when a whole row changes. A machine's item whose data holds energy
shows an energy bar where the durability bar goes (`MenuLayout.energyItemBar`: 13 pixels x energy
over the block's capacity, rounded down, at least 1; Mekanism rounds to the nearest pixel, uses
0x3CFE9A and draws it on Energy Cubes only, empty ones too; `ItemIcon:set(item, count, damage,
data)`, which Hud, InventoryScreen and the carried stack pass the stack's data to).

**The Creative Energy Cube** (kind "creative"): infinite capacity and output, always full,
gives whatever its network takes; creative only (no recipe).

**The Heat Generator** (kind "generator", `Machines/Kinds/Generator`; Mekanism Generators').
BlockList `HeatGenerator` has `energy = { capacity = 160 000, output = 400 }`: a producer whose
output is twice what it makes, so a network takes all of it. One fuel slot takes what
`Smelting.fuel` burns, from every face, and gives nothing to transporters; data 7 is `burnTime`
(ticks left of the item burning, a fraction after a part tick) and 8 `burnTotal` (its burn time,
0 while out), both clamped to the longest fuel's burn time. Each tick it makes up to 200 J
(Mekanism's heatGeneration; `produce`, so at most its room) and burns that share of a tick: what
is left of the item is counted in whole energy quanta (`TICK_QUANTA` = 200 J / QUANTUM a tick),
so a nearly full generator burns part ticks and no energy is made or lost. An item lights only
when there is room (it is used up, both fields its furnace burn time); one that runs out partway
through a tick lights the next, which makes the rest of the tick, and one out at the end of a
tick lights the next at once, so neither the flame nor the output dips between items. Full, it
keeps its item and lights nothing new. RATE is what it made, ACTIVE whether it made anything; its
status line is "Producing 200 J/t" or "Idle". Its item keeps its energy and both burn fields
(tooltip "Fuel: 60 s", a describer the kind adds). Mekanism's lava tank (which burns a whole
tick's lava whenever there is any room), lava around it and the nether bonus are left out: fuel
burns directly. JEI lists it as a fuel catalyst.

**The Electric Furnace** (kind "smelter", `Machines/Kinds/Smelter`; Mekanism's Energized Smelter).
BlockList `ElectricFurnace` has `energy = { capacity = 20 000, input = 20 000 }`, a consumer; its
`rates` override gives its capacity as its input rate (Mekanism's machine energy containers take any
amount), so a network may fill it in one tick. Slot 1, the input, takes what `Smelting.result`
smelts, through every face; slot 2, the output (the furnace's result frame), gives through every
face and pushes its results into the transporters and chests next to it (blocks have no facing, so
Mekanism's side configuration becomes the same on every face: Core's defaults, the rules furnaces
follow too); slots 3 and 4 hold its Speed and Energy Upgrades (`Upgrades.slots(8, 53)`, reached
through no face). Data 7 `progress`, 8 `ticksRequired` (200), 9 `energyPerTick` (50), 10
`smelting` (the item in the input; another one starts over), 11 `state`, its state code (0 idle, 1
no power, 2 output full), and 12 `activeDelay`; 4 values are spare. Each tick `settings` works out
the ticks, the energy per tick and the capacity from the cards installed (Mekanism's maths, below;
`Upgrades.setCapacity` cuts the energy to a smaller capacity at once, as Mekanism's setMaxEnergy
does); with something to smelt and room for the result it `use`s a tick's energy, all or nothing,
and moves the progress on, and at `ticksRequired` one input item becomes the result (a progress
already past fewer ticks finishes on the next tick). Without the energy or the room the progress
waits (Mekanism pauses on both); no input resets it. RATE is minus what it used this tick, and its
status reads it with the state code ("Using 50 J/t", "No power", "Output full" or "Idle"), so WAILA
has it without the window. ACTIVE is what the block shows, Mekanism's client active state
(TileEntityMekanism.setActive): on at once, off at once unless it last stopped within 60 ticks
(blockDeactivationDelay, counted down in `activeDelay`), so a furnace on too little power glows
steadily. Its item keeps only its energy (its slots drop, upgrade cards included). JEI lists it as a
smelting catalyst; the client lights its heating chamber from ACTIVE.

**Upgrade cards** (`Machines/Upgrades`; Mekanism's Upgrade and MekanismUtils). ItemList
`SpeedUpgrade` and `EnergyUpgrade` stack to 8, the most a machine takes of each (Upgrade.getMax;
Mekanism's own cards stack to 64). `Upgrades.slots(x, y)` gives a kind a slot for each, at (x, y)
and (x + 18, y): only its own card, at most 8, by hand or shift-click, through no transporter face
(`insert = {}`: Mekanism's upgrades are out of its side configuration), with the card's outline
while empty (`SPEED_GHOST`, `ENERGY_GHOST`; `define` refuses one over 16 x 16). `counts` reads the
cards installed (the slot's own card only, whole, 0..8, whatever a stack says), and the maths is
Mekanism's with its maxUpgradeMultiplier 10, for n speed and e energy cards: `ticks` = base x
10^(-n/8), truncated (getTicks: 200 becomes 149 with one card and 20 with 8; at least 1),
`energyPerTick` = base x 10^((2n - e)/8), `capacity` = base x 10^(e/8), and `production` = base x
10^(n/8), the Solar Panel's (Mekanism's solar generators take no upgrades). The cards are slot
contents like any other: they drop when the machine is broken (Mekanism keeps them in its item).

**The Solar Panel** (kind "solar", `Machines/Kinds/Solar`; Mekanism Generators' Solar Generator).
BlockList `SolarPanel` has `energy = { capacity = 96 000, output = 100 }`, a producer, and
Mekanism's shape: no full cube but a thin panel of four cells on a post, 9 pixels tall (not solid
but obstructing, as a lantern; not opaque, so the panels of a stack all see the sky). Slots 1 and 2
hold its Speed and Energy Upgrades (`Upgrades.slots(8, 53)`), which no transporter reaches, so it is
no item inventory. Data 7 is `state`, its state code: 0 producing (also a panel not ticked yet), 1
night, 2 no sky, 3 full. Each tick it sets its capacity (96 000 x 10^(e/8)); a cell without the sky
(`ctx.sky` on its own cell) makes it "No sky", a time outside Minecraft's day (`DayCycle.isDay`,
ticks 23 460 to 12 540) "Night", and otherwise it `produce`s 50 x 10^(n/8) J x the sun's brightness
(`DayCycle.sunBrightness`: 1 from about tick 730 to 11 270, 0.47 at the ends of the day), at most
its room ("Full" when there is none). Its `rates` override gives out twice its noon production (100
x 10^(n/8) J/t). RATE is what it made and ACTIVE whether it made anything (Mekanism's active: it
sees the sun and has room); its status is "Producing x/t", "Full", "Night", "No sky" or "Idle", and
the state code carries it to WAILA. A day without cards makes about 621 kJ (13 081 ticks of
daylight). Its item keeps its energy, at most 96 kJ when placed again (the cards drop). Mekanism's
biome factor (SolarCheck's peak multiplier from temperature and rainfall: about 0.65 in a desert
to 1.2 on frozen peaks) and rain don't apply.

**Batteries** (kind "battery", `Machines/Kinds/Battery`; Mekanism's Energy Cubes). BlockList
`BasicBattery`, `AdvancedBattery`, `EliteBattery` and `UltimateBattery` have `energy = { capacity,
input, output }` from Mekanism's EnergyCubeTier (`Transmitters/Tiers` `batteryCapacity` and
`batteryRate`: 4, 16, 64, 256 MJ at 4, 16, 64, 256 kJ/t, the same in and out), so they are storage
(`Machines.role`) and EnergyNet gives them the backup's part: the producers' surplus after the
consumers charges them up to their rate, within the throughput left, and the consumers' shortfall
is covered by them discharging up to their rate; storage never charges storage. The kind has no
slots, no fields and no tick: the header's INPUT and OUTPUT (what the network moved last tick)
are all it reads. Its status is "Charging x/t" / "Discharging x/t" (input minus output), else
"Full", "Empty" or "Idle"; its panel puts the status line at (8, 20) and its `lines` under it
("Input: 150 J/t", "Output: 0 J/t", "Max rate: 4 kJ/t"). Its item keeps its energy (sustained
data, at most its capacity when placed again), so BlockList gives it `maxStack = 1` (Mekanism's
cubes stack to 1). A tier upgrade recipe keeps the energy of the battery in its middle (Recipes
`keep`). The look: BlockDecor "<Tier>Battery" (dark steel, 3 x 3 corners in the tier's colour, a
dark gauge on each side, BATTERY_GAUGE, a "+" terminal on top); TransmitterModel fills the gauges
from its record (below). Left out: Mekanism's charge and discharge slots, side configuration (a
battery, like any machine, joins the networks on its sides into one, so it cannot buffer between
two networks) and its unlimited insert rate from cables (the cube only limits its own output).

**A new machine:** a BlockList block with `machine` and `energy`, a module in
`Machines/Kinds/` returning `Core.define(name, spec)`, and a line requiring it in
`Machines/init`. Tests bind test-only kinds to spare blocks (`Machines.bind`).

## Structure blocks and jigsaw structures (`Structures/`, `StructureLibrary/`, server `Structures/`)

Minecraft 1.20.1's structure blocks, structure voids and jigsaw blocks, and the jigsaw structures
the terrain generator places from the structure library (see Library structures under
Generation). The shared modules are pure; the server and client parts are below.

### Structure data (`Structures/Template`, `Structures/Settings`)

**In memory** a template is `{ name, size, palette, cells, jigsaws, markers, containers }`: a
Minecraft-style name (1..128 letters, digits and `_ . / : -`, slashes for pools:
"outpost/houses/hut"), a size of 1..48 per axis (`Config.Structures.MaxSize`), a palette of block
ids, a buffer of u16 palette indices per cell (x fastest, then z, then y:
`(y * sizeZ + z) * sizeX + x`; 0 is "keep", a structure void, never in the palette), jigsaw records
(position, front, top, name, target, pool, final state, joint; their cells hold the Jigsaw* block
too), data markers (position and string; their cells are air) and container records (position,
1-based slots with item name, count and wear; item data is not kept). Positions are local from the
minimum corner.

**As text** ("IVS1"): `"IVS1:"` and the payload in base64url (A-Z a-z 0-9 - _, no padding), so it
pastes into chat and into a Luau string literal as it is. The payload is LEB128 varints and
length-prefixed UTF-8 strings: version (1), the body's length (so a cut paste says how much is
missing), the name, the size, the palette as block names (names survive id changes; an unknown name
decodes to air with a warning), the cells as runs of (index, length) or bit-packed at 1..16 bits a
cell, whichever is smaller, the jigsaws (orientation as front × 6 + top, joint as a byte), the
markers and the containers, and a CRC-32 of everything before it. Records are sorted, so equal
templates give equal text. `Template.decode` never errors: it ignores whitespace anywhere (wrapped
pastes) and quotes around the text (trailing ones cut with a backward scan, so decoding stays linear
in the length however the text is spaced), caps every count and string (the text at 3 million
characters, the payload at 2 MiB, 1024 palette entries, jigsaws, markers and containers, 4096 items)
and returns nil and a message for the player for anything malformed: not IVS1, a character outside
the alphabet, cut off, damaged (checksum), from a newer version, a position outside the box,
duplicates. A 7 × 5 × 7 hut is ~250 characters, a 16 × 10 × 16 house ~1,150, a 48 × 48 × 48 build of
100 kinds of block in noise ~130,000 (encoded in ~160 ms, decoded in ~120 ms in Lune); any 48³
structure stays under ~150,000, inside `Config.Structures.MaxDataChars` (200,000, what a StringValue
holds).

`Template.capture` builds a template from the world with Minecraft's SAVE rules: air is air (it
clears the world where the structure is placed), a structure void is "keep", a DATA structure
block becomes a marker with its string and air, other structure blocks air, jigsaws keep their
block and get a record with their settings, blocks with slots a container record, and cave air
and cave twins are saved as their surface forms (`Blocks.surfaceForm`), so a structure saved in a
cave has nothing the mesher hides with caves. `toTable` / `fromTable` convert to and from an
editable table of ASCII layers (one character per palette entry, "." air, " " keep), which
`tests/structure.luau` uses: `decode` prints every IVS1 text in a file, a pasted chat message, a
library module or standard input (`tests/lib/StructureText` finds them and decodes data with
chat words after it), `--lua` writes the table, `encode` turns one back into text or a module.

`Structures/Settings` holds the screens' fields, their defaults and ranges, and their wire format. A
structure block has a mode, a name, an offset (-48..48, default 0, 1, 0), a size (0..48, default 5
on every side), a rotation (0..3 quarter turns clockwise from above), a mirror ("none", "leftRight":
Z flips, "frontBack": X flips), an integrity (0..1), a seed (0: random), showBoundingBox,
showInvisible and metadata (DATA's string, 128 bytes); a jigsaw a name, a target, a pool (default
"empty"), a finalState (a block name, default "Air") and a joint (aligned for horizontal fronts,
rollable for vertical ones). `clampStructure` / `clampJigsaw` bring any table into range as
Minecraft's block entities do when they load; `checkStructure` / `checkJigsaw` say in words what is
still wrong (a bad name, a final state that is no block).

### Turning (`Structures/Transform`)

Minecraft's StructureTemplate.transform in a box whose minimum corner stays 0: the mirror first,
then `rotation` quarter turns clockwise from above, one turn mapping (x, z) to (sz - 1 - z, x) in
a box sz wide and sx deep; directions turn the same way, Up and Down stay. Minecraft turns around
a pivot instead, so its box can reach to negative x or z; `anchor` gives the offset between the
two, for LOAD to place a template exactly where Minecraft's would. `inverse` maps back, for writers
that go cell by cell through the world.

### Jigsaw assembly (`Structures/Jigsaw`)

Minecraft 1.20.1's JigsawPlacement, pure and deterministic (Util/Hash rngs from the options' seed),
so every client and the server assemble the same structure:
- **Start** (addPieces): a random rotation and a weighted random element of the start pool (an
  empty element gives no structure); with `startJigsawName` that jigsaw sits on the start
  position. The piece then moves so its layer 0 is the ground's top layer: minY + 1 =
  startHeight + firstFreeHeight at its box's centre with `projectToHeightmap` (Java's
  round-towards-zero midpoint), else its unprojected y.
- **Free space:** the box centre ± maxDistance (80, at most 128) in every axis, minus the start
  piece's box, shared by the structure. A jigsaw whose target cell (one step in front of it) lies
  inside its own piece uses that piece's box minus the children already in it. A child fits when
  every cell of its box is free (Minecraft: the box shrunk by 0.25 inside the free shape); the
  placed box is then taken out. Holes are filed in a 16 block grid.
- **Children** (Placer.tryPlacingChildren), breadth first up to `maxDepth` (0..7): every jigsaw of
  a piece in shuffled order; candidates are its pool's elements in weighted random order (only
  below maxDepth), then its fallback pool's, so pieces at the last level still get end caps; an
  empty element stops the jigsaw. For each candidate, each rotation (shuffled) and each of its
  jigsaws that `canAttach` (facing each other, the source's target is the candidate jigsaw's name,
  and the same top unless the source is rollable; shuffled), the child's y lines its jigsaw up with
  the source when both pieces are rigid, else puts it at firstFreeHeight of the source's column
  (read once per source jigsaw). The first child that fits is kept. Missing pools are skipped with
  a warning; "empty", "minecraft:empty" and "" are the silent empty pool.
- **Draws:** Minecraft shuffles a list holding each element `weight` times. An element that failed
  can only fail again for the same jigsaw, so drawing distinct elements with probability
  proportional to weight, without replacement (O(log n) a draw), has the same outcomes and costs far
  less with large weights. Jigsaws whose target cell is taken are skipped untried.
- **Caps:** an assembly stops with "Assembly stopped at N pieces: the structure is too big" after
  `MAX_PIECES` (4096) pieces or `MAX_WORK` (400,000) units of work, charged for every step whether
  it leads anywhere or not: each source jigsaw, candidate drawn, rotation, candidate jigsaw tested,
  placed box a fit test compares, and `HEIGHT_WORK` (64) per ground read. Data made to waste time
  stops within ~25-35 ms in Lune; a dense 7 deep village of up to 280 pieces needs under 100,000
  and takes a few milliseconds.
- **Not ported:** the expansion hack (legacy villages) and junctions (beard terrain adaptation;
  the generator's foundation stands in).
- **Generate** (`generateFrom`, the jigsaw block's button): the first piece comes from the source
  jigsaw's pool (then its fallback) and attaches to the source like a child (facing it, its jigsaw
  named the source's target); then `levels` levels grow from it inside its centre ± 128, with the
  source's own cell taken, so nothing grows back over the build it stands in.
- **Writing:** `writeTables` (a piece's palette turned by its rotation through Blocks.rotate, and
  its jigsaw cells' final states, -1 for keep), `localColumn`, `baseY` (a terrain matching piece's
  layer 0 at firstFreeHeight - 1, Minecraft's GravityProcessor), `cellBlock`, `blockAt` and
  `eachBlock`. Final state names match loosely (`nameKey`: case, underscores, spaces and
  "minecraft:" ignored, so "minecraft:oak_planks" finds nothing here but "planks" finds Planks);
  StructureVoid means keep, unknown names air.

Templates are cached by table identity: never change one after it was assembled.

### The library (`Structures/Library`, `StructureLibrary/`)

`Library.load()` reads, once per Luau VM (the server, each client, each worker actor):
1. the repo's `StructureLibrary/`: `Templates/` (ModuleScripts at any depth returning an IVS1
   string or a list, or StringValues; `Outpost.luau` is the example, written by
   `tests/build_structures.luau`), `Pools.luau` (explicit pools: a fallback, a projection and
   elements, each a template or empty with a weight of 1..150 and maybe its own projection) and
   `Structures.luau` (the generated structures);
2. the place's optional `ReplicatedStorage.IceVoxelStructures` folder: StringValues at any depth
   holding one or more IVS1 strings. Attributes make a StringValue's first template a generated
   structure with no code (`Generate`, `Biomes`, `Spacing`, `Separation`, `Size`, `Foundation`,
   `OnLand`, `StartHeight`, `MaxDistance`), and `TerrainMatching` makes its templates terrain
   matching in implicit pools. The folder's templates and structures replace the repo's of the
   same name.

Both are read in path order (then class, data and attributes), so every machine resolves a
template defined twice alike, whatever order the children replicated in. Every machine must load
the same library, so the server never writes into the folder at runtime (saves go to
ServerStorage). `Library.new` (pure, what tests use) validates everything and never errors: bad
entries are warned (`[Structures] ...`, and `library.warnings`) and skipped.

A pool name resolves (`library.pool`, cached) to an explicit pool, else the template with exactly
that name alone, else the implicit pool: every template named "<pool>/..." (sorted, weight 1, rigid
unless marked terrain matching). A structure has a name, a startPool, maybe a startJigsawName, a
size (jigsaw depth, default 7), a maxDistance (80), biomes (default all; matched with
Jigsaw.nameKey, an unknown one warned with the list of valid ones), a spacing and separation (34 and
8, Minecraft's villages), a salt (default a hash of the name), a startHeight (0) and the flags
projectToHeightmap, onLand and foundation (true), plus the computed `reach`: every block of it lies
within ± reach blocks of its start (the start piece's widest side, plus maxDistance when it has
levels).

### On the server (`server/Structures/`)

- **`Permission`** (pure): Minecraft's canUseGameMasterBlocks. Creative players only, and of them
  the game's owner, `Config.Gameplay.Admins` and Studio sessions always, else
  `Config.Structures.Permission` (a list of user ids, by default none; true for every creative
  player, false for nobody). `StructureBlocks.operator(player)` asks it (the owner looked up once
  per player); it is ServerNet's `operator` rule for placing and breaking operator blocks
  (`EditRules.mayUseCreativeOnly`) and gates every request and upload.
- **`StructureStore`** (pure): every structure block's and jigsaw's settings by position, for the
  session, like chests. `blockChanged` (chained onto WorldServer.onChanged) gives a new block its
  mode's or front's defaults, keeps the settings when one structure block or jigsaw becomes
  another (a mode change swaps the block), and forgets them for anything else. These blocks only
  come from edits (generation writes jigsaws as their final state and markers as air). Records go
  with a chunk's edit list and, when changed, to players within 192 blocks sideways; a removed
  block's record has no settings.
- **`StructureServer`** (pure; Minecraft's handleSetStructureBlock / handleSetJigsawBlock /
  handleJigsawGenerate): a request must name a loaded structure block or jigsaw within reach + 2
  (open) or 32 blocks (the rest; a screen stays open where its block was clicked). Every action
  first stores the screen's fields (names checked; a new mode swaps the block). SAVE captures the
  region (terrain generated where needed, as edits do; the store's jigsaw and DATA settings,
  Containers' items), encodes it, refuses one over `MaxDataChars`, keeps it by name for the
  session (at most `MAX_SAVED` 256 saves and `MAX_SAVED_BYTES` 32 MB, the oldest dropped first),
  sends the text to the player and answers "Saved structure '<name>' (N blocks, M characters)".
  LOAD takes this session's save, else the library's template, else the player's upload: a
  template of another size first only sets the size ("position prepared"), the next LOAD places
  it (`Placement.loadPlan`; seed 0 draws one). DETECT is StructureBlockEntity.detectSize over the
  CORNER blocks with the name within `Config.Structures.DetectRange` (the inside of their box, at
  most 48 a side). Generate runs `Jigsaw.generateFrom` from the jigsaw with a random seed over
  `lookups` (the session's saves over the library, so a piece saved a minute ago joins its pool),
  terrain matching pieces on `surfaceHeight` (the live world's highest sturdy block or fluid where
  loaded, else the generator's height, never generating), then `Placement.piecesPlan`. Plans wait
  in one queue: a LOAD or Generate that would take it beyond `MAX_QUEUED` (3 million) cells is
  refused until it drains, a Generate of more than `MAX_GENERATE` (2 million) cells outright.
  Uploads are put together per player (`Protocol.joinStructureData`); the last two finished ones
  are kept by transfer number, so LOAD can name one twice.
- **`Placement`** (pure): a plan is the cells to set in order, with what each gets once its block
  is there (a jigsaw's settings, a DATA block's, a container's items, replacing what it held, as
  Minecraft clears a container it places over). A LOAD (at most 48³ cells) is planned at once:
  turned around Minecraft's pivot (`Transform.anchor`), blocks turned (`Blocks.rotateLut`),
  integrity drawn per cell from the seed (BlockRotProcessor), keep cells skipped, markers back as
  DATA structure blocks. A Generate's plan is streamed (`refill`, batches of `Placement.BATCH`, 256
  cells, about 4,096 template cells of work each), so building it costs nothing up front and its
  memory doesn't grow with its size: the terrain matching pieces' ground heights, then the solid
  blocks layer by layer over every piece, then the late blocks piece by piece; where pieces
  overlap the later piece's cell wins and the earlier one is never set (a 16 block grid finds the
  overlaps). Solid blocks go first, bottom up, then what hangs on, stands on or flows from them
  (torches, lanterns, lichen, plants, fluids), so what holds them is there first. The queue sets at
  most `Config.Structures.LoadBlocksPerFrame` (2000) cells, 2 chunk generations and 6 ms a frame
  (it looks at the clock every 64 cells and after every batch) and never stops between a tall
  plant's halves; a 1-million-cell Generate costs its request ~1 ms.
- **`StructureBlocks`**, the glue: decodes the StructureBlock, Jigsaw and StructureData messages,
  rate limits them per player (20 a second; save, load, detect and generate 1 a second with a
  burst of 3; uploaded pieces 1.5 × `DataPiecesPerSecond`), answers a Use on these blocks like an
  open request (`Inventories.onMenu`), places the queue's share each frame before ServerNet's
  flush (so its edits go out that frame, before the records they make) and sends changed records
  after it. Each save is
  also a StringValue named after it in `ServerStorage.IceVoxelSavedStructures` while the session
  keeps it (`Env.stored`, `Env.forget`), and its text goes to the player in StructureData pieces
  at `DataPiecesPerSecond`.
- **Generated chests** (`Players/Containers`): a store may have `generated` (the generator's
  `structureContainer`, and the block without generating terrain). A container there gets its
  contents the first time it is needed: opened, read (`get`, `peek`: windows, pipes, a SAVE), or
  just before its block changes (`materialize`, first in the server's onChanged, so one broken
  unopened drops what it held). Each position is asked once per session (`sourced`), so an emptied
  chest never refills and a chest placed there later starts empty. Machines are never sourced.
- **Rules elsewhere:** EditRules refuses cave twins and needs `operator` for operator blocks
  (survival players can't mine them anyway: Mining); Fluid never flows into a structure void
  (Minecraft's canHoldFluid), though it is replaceable.

### On the client (`Net/StructureNet`, `World/StructureRecords`, `Ui/`, `Rendering/StructureBoxes`)

- **`World/StructureRecords`** (pure): the server's StructureBlocks and Jigsaws records (a record
  replaces what was known, one without settings forgets it; `prune` drops records whose loaded
  block is no longer one, every few seconds); `region`, the box a structure block outlines as
  Minecraft's StructureBlockRenderer does (SAVE always, LOAD with "Show Bounding Box" as the
  template's turned box at `Transform.anchor`, nothing for CORNER, DATA or a side of 0); an
  `Outbox` that paces pasted text out as StructureData pieces at `DataPiecesPerSecond`, then the
  LOAD naming its transfer; and `Downloads`, which keeps the texts SAVEs bring back. Pieces don't
  name their block, so each SAVE is expected with its name and size (at most 8, for 30 s) and a
  finished text goes to the oldest SAVE expected with the name and size its first bytes give (the
  server answers SAVEs in order, so expected ones before it were refused and are dropped).
- **`Net/StructureNet`** routes the messages: an `open` record opens the block's screen (the
  answer to a Use, as for chests), StructureData pieces fill Downloads, and the screens' buttons
  become StructureBlock and Jigsaw requests; pasted text goes first in pieces of a new transfer
  number, and the same text loaded again (the LOAD after "position prepared") reuses a transfer the
  server still keeps.
- **`Ui/StructureForm`** (pure) is both screens' model, Minecraft's StructureBlockEditScreen and
  JigsawBlockEditScreen as data: the fields as typed, filtered as Minecraft's fields are and read
  as Minecraft reads them (a number that doesn't parse is 0, or 1 for the integrity), the layout
  per mode at Minecraft's GUI positions plus two rows for the data (SAVE's text in parts of 16,000
  characters to copy, LOAD's Paste Data box, checked with `pasteSummary`), and `merge`, which takes
  a server update into a field only where it changed on the server and differs from what this
  screen last sent, so typing is kept but a prepared size shows. After DETECT and LOAD the actions
  wait for the block's next record (`await`, at most 1 s), so a SAVE pressed right after a DETECT
  can't resend the old region. A jigsaw form starts with Keep Jigsaws on, as Minecraft's.
- **`Ui/StructureScreen`** draws them in this game's style with `Ui/FormWidgets` (Minecraft's
  EditBox, buttons, labels and slider; a read only box can still be focused and selected, which
  is how its text is copied: Roblox scripts can't write the clipboard, but a TextBox with
  TextEditable off keeps Ctrl+C). It is a `Screens` panel (`showPanel`, `closePanel`): the
  darkened world, the free mouse and the controls off like any screen, but none of the inventory's
  input; E, Escape, gamepad B and death close it as Cancel, and `E` still closes it while the read
  only box has the focus. Unlike Minecraft it stays open after DETECT, SAVE and LOAD, repeating
  the answer on its status line (`Notices.listen`); Done and Generate close it. Each opening
  starts with an empty Paste Data box. While it is open the block's outline follows the fields
  (`preview`).
- **`Rendering/StructureBoxes`** outlines the regions of the nearest 24 structure blocks within
  128 blocks (a SelectionBox on an invisible, non-colliding, non-queried part), labels their
  blocks with the name within 48 blocks, and for "Show Invisible Blocks" marks the region's air
  (at most 2,048 markers, in regions of at most 16,384 cells). Like Minecraft's, none of it shows
  outside creative.

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
Minecraft), Behaviours/Plant (plants popping off), Containers' `onOpeners` (first viewer in, last
out; a broken chest closes silently), Inventories (armor put on by any action, a tool breaking),
Entities (pickups, at the item), Characters (health lost, at most every 0.5 s; death; a hurting
landing's fall and the fall sound of the block below the feet).

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
  - every Heat Generator whose record says it burns, within 16 blocks of the listener
    (`SoundRules.crackles`, `TransmitterRenderer.activeMachines`): the same crackle, at the
    generator;
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
| client → server | `StructureBlock` | position, op (open, update, save, load, detect), the screen's settings; load: an upload's transfer number (0: by name) |
| client → server | `Jigsaw`        | position, op (open, update, generate), the jigsaw's settings; generate: levels (0..7), keep jigsaws |
| client → server | `StructureData` | a piece of pasted structure text: transfer, index, count, text (16,000 characters) |
| server → client | `ChunkEdits`    | edit list of each requested chunk             |
| server → client | `Edits`         | every world change of the frame (or a reject) |
| server → client | `Waypoints`     | saved waypoints (on join, or after filtering) |
| server → client | `Inventory`     | inventory + window container after action `ack` |
| server → client | `Entities`      | dropped items: spawn / sync / count / remove  |
| server → client | `Notice`        | a message for the chat                        |
| server → client | `Transmitters`  | transmitter states: packed side modes, colour, pipe fill |
| server → client | `Tanks`         | fluid tank contents (fluid, mB)               |
| server → client | `Transport`     | items entering, re-routed in or leaving transporters (path, speed, start time) |
| server → client | `Machines`      | machines' energy, capacity, network input / output, rate, active, state code |
| server → client | `Sound`         | sound events near the player (event, position, volume, pitch) |
| server → client | `StructureBlocks` | structure blocks' settings per position (none: gone); open flag (show the screen) |
| server → client | `Jigsaws`       | jigsaws' settings per position (none: gone); open flag            |
| server → client | `StructureData` | a piece of the text a SAVE made, for the player who saved: transfer, index, count, text |

Structure settings travel in `Structures/Settings`' format (Net/Protocol uses its `write*` /
`read*`): unknown codes, NaN and strings over 128 bytes are malformed, numbers out of range are
clamped. Structure text goes in pieces of `Config.Structures.DataPieceChars` (16,000) characters,
at most `MaxDataChars` (200,000, 13 pieces) a text and `DataPiecesPerSecond` a second each way:
reliable RemoteEvents name no size limit but share about 500 requests a second per client, so
pieces keep each message small. `Protocol.joinStructureData` puts pieces back together in any
order, refuses ones that don't fit (another count, an index twice, too long) and drops older
half-received texts beyond 2 per sender.

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
  break and drop when what they hang on stops being sturdy), `Plant` (a plant whose soil or other
  half is gone breaks and drops what it drops by itself, in every game mode: a tall plant's lower
  half drops, its top never does, so a tall plant drops once). They drop items through `Drops`,
  which ServerNet wires to `Entities.dropBlock` (Transmitters/UseRules uses it too).
  - In `Gravity`, as in Minecraft, a falling block passes through blocks without a collision box
    (torches) and lands on those with one (`Blocks.obstruction`). Coming to rest in a torch's cell
    (a solid block under the torch) or on a lantern, it breaks into an item and the torch or
    lantern stays: the torch trick for clearing sand and gravel. Past wall torches with air under
    them it keeps falling, and a block placed on a torch stays where it is.
  - Plants in `Gravity` and `Fluid`: falling sand replaces the replaceable plants (no drop) and
    breaks into an item on flowers, tall flowers and mushrooms, which are not replaceable and have
    no collision box, as on a torch; flowing water washes every plant away with its drop. Plants are
    not opaque, so the grass under them stays grass and the sun reaches through them (`SkyCheck`),
    and a spawn may stand in one (`SafeSpot`).
- `World/Simulation`: keeps chunks within `Server.SimulationRadius` of players generated.
- `Network/ServerNet`: rate limits, reach checks, breakable / placeable / replaceable checks, no
  placing inside players (`EditRules.obstructs`: solid blocks and lanterns, not torches or plants),
  survival mining time and drops (`EditRules`), and the rules injected by the boot script
  (`setRules`: using up placed items, dropping items and chest contents). Rejections never generate
  terrain.
  Tall plants follow Minecraft's DoublePlantBlock through pure `EditRules` rules: `mayPlace`
  refuses upper halves and `supported` (`Blocks.canPlace`) wants room for the top; `setPlaced`
  sets the lower half and its top together (looking at the room again first: without it nothing
  is set and the edit is rejected); a player breaking either half removes both (`removeBroken`)
  with one drop, the lower half's with the breaker's tool and game mode (`harvested`: 2 short
  grass from tall grass with Shears, the flower from either half of a tall flower), one break
  sound and one wear. The client predicts the half it touched; the other comes as an ordinary
  edit. Placing over a replaceable plant drops nothing; the other half of a tall one then pops by
  itself with its no-tool drop (nothing for tall grass and large ferns).
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
- `Structures/`: structure blocks, jigsaws and their Generate, and who may use them (see
  Structure blocks and jigsaw structures). `Players/Containers` fills a generated structure's chest
  from the generator the first time its contents are needed; ServerNet's `operator` rule
  (`EditRules.mayUseCreativeOnly`) keeps operator blocks to players allowed to use them, and
  EditRules refuses cave twins; `Fluid` never flows into a structure void.
- `Transmitters/`: Mekanism pipes (see Mekanism pipes); `Players/ItemUse`: the Configurator and
  buckets (UseItem). A water bucket that replaces a plant (`UseRules.pour`) drops it, as
  Minecraft's BucketItem.emptyContents destroys the block with drops.
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
mesher can treat cave air (and the glow lichen generated on cave walls, its cave twins) as rock
(`hideCaves`), which removes every cave wall; sections are meshed
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
- Transmitters, fluid tanks, chests and furnaces come from edits: the pipes (and furnaces pushing
  their results into chests) read unloaded chunks' edit lists to find them. The one exception is a
  library structure's chests and furnaces, which Players/Containers fills from the generator
  (`structureContainer`) when first needed and the pipes only see in loaded chunks. Keep
  transmitters, tanks and machines out of library templates: nothing on the server knows a
  generated one (a LOAD or Generate places them as edits, which is fine).
- Furnaces and machines follow Mekanism's machine rules for automation on every face: inputs only
  take what they can use, transporters only ever take results (never the input or fuel), and
  results are pushed out on their own into transporters (NORMAL / PULL sides) and plain
  inventories, never straight into another furnace or machine. A new machine gets this from its
  slots (`output = true` slots are pushed out); `Transmitters/Inventories` is the one place the
  faces are decided.
- Ore features (`Generation/Ores`) are placed in list order from one random stream per chunk:
  append new ones, never reorder or change earlier ones, or every unedited world's ores move.
- Ground plants (`Generation/Foliage`) decide each column from the seed, its (x, z) and its own
  blocks only, so a chunk's padding grows what its neighbour's core grows; keep it so. A plant's
  shape has at most 4 boxes (each is a part per plant in the world), and a tall plant is placed
  through `EditRules.setPlaced` (both halves), never one half alone (it would pop).
- Machine data starts with the shared header (energy always at 1); kinds append fields, at most
  16 values in all. Kind ticks replace slot stacks (never change a stack table) and add or use
  energy through `Machines.produce` / `use`, so energy stays exact.
- Machines and cables only come from edits, like pipes.
- Kind modules require Machines/Core, Machines/Upgrades and plain shared modules (Items, Crafting/Smelting, DayCycle), never
  Shared/Machines, Inventory/Menu or Shared/Transmitters (those require Machines: a cycle). A
  kind keeps per-machine state in its data fields, not in module tables.
- Anything crossing actor boundaries (jobs, results) may only contain numbers, strings, buffers,
  dense arrays and string-keyed tables.
- The structure library is part of world generation: the server, every client and every worker
  must load the same one (StructureLibrary modules plus ReplicatedStorage.IceVoxelStructures as
  published, read once, in path order). Never write into that folder at runtime; saves go to
  ServerStorage. Templates are immutable once loaded (Jigsaw caches by table identity), and
  structure placement (StructureGen) must stay stateless and written in its fixed order.
- IVS1 text is what users keep: palettes name blocks, so renaming a block turns it into air in
  every saved structure (add, don't rename), and a format change needs a new version number
  (`Template.VERSION`; decode refuses newer ones) and must keep reading version 1.
- Cave twins must look, drop and behave exactly like their twin (Blocks checks it at load), and
  glow lichen generation (`Generation/CaveDecor`) decides each cell from the seed, its position and
  its in-buffer neighbourhood only, like foliage. A lichen is 2 parts: caves hold thousands.
- Operator blocks (`creativeOnly`) break and drop nothing for survival players, and only players
  `Structures/Permission` allows place, break or use them; a new one needs `drops = false`
  (checked at load).
