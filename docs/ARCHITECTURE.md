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
4. **Cave entrances and ravines** (levels 0-2, `SurfaceCaves.luau`). See below. Carved as **Air**
   (part of the surface: drawn from above, lit by the sky) after the caves, which they open up:
   the cave air they run into stays cave air. `solidBelow` drops to the lowest carved cell, and
   ores only replace stone, so they never fill it.
5. **Lava and oil** (`Lava.luau`, `OilWells.luau`; see below). Right after the surface caves
   (levels 0-2), cave air below `Caves.LavaLevel` becomes CaveLava and surface caves' air there
   Lava (`Lava.aquifer`). Then surface lava lakes and oil wells (deposits and geysers;
   point-sampled up to `Config.StructureMaxLevel`) are written, before the ores, so a deposit takes
   the same rock in a chunk's padding as in its neighbour's core; then water lakes (point-sampled
   up to `Config.StructureMaxLevel`) and puddles (full detail only; `Lakes.luau`, see Lakes and
   puddles). After the ores (step 6) a full detail chunk with caves may sink an underground lava
   lake into a cave floor (not within 2 blocks of a library piece or a mineshaft's piece).
6. **Ores** (level 0 only, `Ores.luau`). Random-walk veins inside the chunk's own core, in altitude
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
7. **Structures** (up to `Config.StructureMaxLevel`): trees and cacti (`Structures.populate`), then
   the structure library's jigsaw structures (`StructureGen.luau`), whose air clears trees and
   whose structure voids keep them. See below.
8. **Mineshafts** (level 0 only, `Mineshafts.luau`): their pieces carved and furnished as cave air
   and cave twins, overgrowth, then their entrance shafts open to the sky. See Mineshafts below.
9. **Glow lichen** (level 0 only, `CaveDecor.luau`), after structures and mineshafts, so it only
   clings to rock that is still there; it grows only in cave air, so surface caves get none. See
   below.
10. **Ground plants** (level 0 only, `Foliage.luau`), after structures, so nothing grows under a
   trunk, leaves or a building, nor in or over a pit or an entrance shaft (the column's generated
   top must be ground with air above). See Foliage below.

The generator also returns two hints the mesher uses to skip work: `solidBelow` (everything below is
rock or cave air; lowered under a structure's cells that are neither, under surface caves' air
and under ordinary Lava and Oil) and `emptyAbove` (everything above is air; raised over trees,
structures, plants and geysers' spouts). A dug lake (a geyser's oil lake, a water lake or a
puddle) lowers its columns' `topCells`, so the sky line and the Horizon summary keep describing the ground, and whatever puts
cave cells into rock (deposits, the spout below a lake, underground lava lakes) marks the cave
lattice (`Caves.mark`; a chunk without caves gets one), so World/SectionGraph reads those cells
instead of assuming rock; mineshafts, which also put planks, logs and moss into caves, mark every
lattice cell their pieces and shafts touch as read (`Caves.markRead`: a cell flagged "cave air
throughout" becomes "read" too).
`TerrainGenerator.new(seed, options?)` takes the structure library to generate (`options.library`,
default `Library.load()` while `Config.Structures.Generate` is on; `structures = false` for none);
`generator.structures(minX, minZ, maxX, maxZ)` lists the generated structures with a piece in a
rectangle, `generator.structureContainer(x, y, z)` the items a generated chest starts with and
`generator.surfaceCaves` the cave entrances and ravines (`worms(minX, minZ, maxX, maxZ)` finds
them, `carvesTop(x, z)` says whether one opens at a column). `findSpawn` skips columns where one
opens. `generator.oilWells(minX, minZ, maxX, maxZ)` lists the oil wells near a rectangle (the
map paints their geysers), `oilLake(well)` a geyser's lake columns, `lavaLakes(...)` the
surface lava lakes and `waterLakes(...)` / `puddles(...)` the water lakes and puddles.
`options.biome` (a biome index) puts one biome on every column and `options.climateScale` widens
the climate noise (World types below); without them a world is byte for byte what it was
(tests/spec/WorldTypeGenerators pins digests of chunks, columns, the spawn and a map tile).
`generator.mineshafts(minX, minZ, maxX, maxZ)` (optional: the Default and the debug structures
world have it) lists the mineshafts whose bounds touch a rectangle, and `structureContainer`
answers for their chests too (after the library's).
`generator.seaLevel` is the sea's surface (`Config.SeaLevel` here; the map, safe spawning and
structures' ground read it) and `generator.labels` (optional) lists generated structure blocks
with settings of their own (the debug structures world's name tags).

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

- No caves within ~9 blocks of the surface (`d` < 0.02, and never within `Caves.SurfaceMargin`,
  5); between ~9 and ~22 blocks (`d` = 0.05) they fade in, so the first ones appear ~11 blocks
  down. That holds for these deep caves only: what opens them to the surface are the cave
  entrances and ravines (below), a separate carver.
- Three cave sets take over at ~45, ~158 and ~315 blocks deep (small, medium, large), blended with
  smoothsteps. Each mixes *blob* caves (one 3D noise) with *strata*, a smooth sawtooth over height
  tilted by a kilometre-scale noise plus 3D and jagged noise, by a very wide `barrier1` noise.
- `barrier2` (3D, ~190 blocks) gates the three sets: below 0 there are no caves, from 0.5 on the
  sets are at full strength. So caves come in regions, and ~14% of the rock between 22 and 316
  blocks deep is air (the datapack: 8–16%). `Caves.regions(seed)` gives the same noise to the
  cave entrances, which head for these regions.
- **The Underlands.** From ~315 blocks deep (`d` = 0.7) the large set blends into the datapack's
  analytic `ygrad - 1.6 H` (no noise, not gated by `barrier2`), which takes over completely at
  `d` = 1. Under high ground that term is already strongly negative early in the blend, so the
  cavern opens ~330 blocks below the surface (~380 under lower ground), down to a floor that sinks
  as the surface rises. It appears under surfaces above ~540, reaches down to `Caves.MinY` under
  surfaces above ~700, and is up to ~600 blocks tall under the highest (~930) peaks. The datapack
  blends the same way.
- **Lava.** Cave air below `Caves.LavaLevel` (y 11) becomes lava after the carving (see Lava
  below), so the deepest caves and the Underlands' floor where it reaches `Caves.MinY` (4) are lava
  seas.

Cave and strata sizes are 0.75 of the datapack's (the player is not scaled down with the terrain);
the depths scale with the terrain. 3D noise per block would be far too slow, so F is evaluated on
a world-aligned 4 × 8 × 4 lattice and interpolated. Lattice points where `barrier2` rules caves out
cost one noise call, cells positive at all eight corners are skipped, and the near-surface fade
uses each block's own depth (lattice depths are off on steep slopes); cells that are air at all
eight corners are carved without interpolating. The carver returns the lattice cells it carved
(`Caves.Carved`: per 4 × 8 × 4 cell, not carved, carved in, or cave air throughout), so glow lichen
only looks where caves are. In Lune, interpreted (`NOCODEGEN=1`, as on a Roblox client without
native code), caves cost ~1–5 ms per chunk under most terrain and ~14–21 ms (worst ~27) over the
Underlands, where a chunk has 100k+ blocks of air; with native code about a quarter of that. The
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
remeshes a node when a side gets a coarser neighbour. Where the coarser node carved a cave entrance
or a ravine (levels 1-2), the limit drops to the lowest carved cell of that column
(`SurfaceCaves.lowestCarved`, from the worms; columns next to a structure's piece are left out, as
`generate` leaves them alone), so the finer side draws the walls that face the cut. The other way
round, a far node's limits (`farSeamLimits`, which hold for any neighbours) are also opened down
to where a finer neighbour's surface caves cut its border columns (`openToFinerCuts`), since the
far node's padding there is its own coarser, uncarved terrain and neither side would draw the
rock facing the cut: a see-through slit at a ravine's end. From level 3 on (nodes that carve
nothing and build no entrance worms) and towards a node two levels finer, only ravines count.

### Cave entrances and ravines (`SurfaceCaves.luau`)

Minecraft 1.20.1's two overworld carvers, CaveWorldCarver and CanyonWorldCarver, adapted to a world
whose deep caves never come near the surface: worms of steps a block long, carved as **Air** right
after the caves.

- **Entrances** (`Caves.Entrances`). One candidate per `Spacing` (96) square cell, taken with
  `Chance` (0.6), at a hashed column; it needs land more than 4 blocks above sea level and a river
  strength below 0.3. Where the ground slopes 0.6 or more (over 8 blocks) the tunnel heads uphill
  nearly level into the slope (a mouth); otherwise it slopes down 0.45-0.8 rad (a pit), along the
  one of four right angles to its hashed heading whose point at its depth lies deepest in the deep
  caves' regions (`Caves.regions`). Yaw and pitch wander like Minecraft's (`f = 0.75 f + noise`,
  pitch relaxing by 0.7 a step), pitch towards a target: down until the hashed `Depth` (15-60)
  below the surface, levelling off over its last 8 blocks; every 4 steps a tunnel outside a full
  strength region turns towards the side where the regions are stronger. The radius varies
  smoothly within `Radius` (1.5-3.5, knots every 12 steps), the vertical one is 0.85-1.15 of it,
  and each ellipsoid has a flat floor (cut at a hashed -0.85..-0.5 of its height; Minecraft's
  -1..-0.4). A quarter of the steps is skipped as in Minecraft, but never two in a row (a thin,
  steep tunnel would be pinched shut). Past its first 6 steps a tunnel goes into the ground: while
  its centre is less than its vertical radius + 2 below the lowest surface around it (the downhill
  side of a slope), it dives at 0.7 rad or more and its pitch noise only pushes it down; one not
  under the ground by step 16, or out of it again for more than 4 steps, ends there without a
  chamber, so there are no long open ditches. `Branch` (0.35) of them fork once, 30-60% along,
  sideways (a right angle and a third of the pitch), thinner, 16-40 steps long and a little
  deeper. After `Length` (48-140) steps a tunnel ends in a small chamber (0.8-1.3 × the largest
  radius). One that runs into cave air on the way is joined to the cave network there.
- **Ravines** (`Caves.Ravines`). One candidate per `Spacing` (384) square cell, with `Chance`
  (0.5). A gently curving cut (`yaw += f × 0.05`, `f = 0.5 f + noise`) of `Length` (60-160)
  steps. Its half width is Minecraft's width curve, `r0 + sin(π i / n) × thickness` times 0.75-1
  per step (`Radius`: 1.5 at the ends, up to 6 in the middle), and its floor follows the same
  curve, from 8 blocks at the ends to a hashed `Depth` (20-45) in the middle, below a moving
  average of the surface along it (so the floor is smooth). The floor is rounded over at most 5
  blocks and the walls are jagged by Minecraft's width factor per block of height, `(1 + r1 r2)²`,
  redrawn on a third of the levels. Each column is cut from its lowest carved cell up to its top:
  always open to the sky, with no overhangs.
- **Rules.** Only opaque rock and soil is carved: never bedrock, water, ice or cave air (the cave
  air a worm runs into stays cave air, the junction), and nothing below `Caves.MinY`. Columns at
  or below sea level + 2 are never carved. A step that may reach below sea level + 1, or lies in a
  river valley, needs dry land (above that) within its radius + 3 blocks (+ 3 more in a river
  valley), sampled on a 4-block grid, or the worm stops there; one stopped (by water, or an
  entrance out of the ground) within 16 entrance / 30 ravine carved steps is dropped, so there are
  no stubs by the shore. Columns within 2 blocks of a library structure's piece are left alone
  (`protectedColumns`): no foundation fills a pit and no path floats over a ravine. So are surface
  lava lakes' boxes and 2 blocks around them, geysers' lake squares and 2 blocks around them, water
  lakes' boxes and 2 blocks around them and puddles' bounds and a block around them
  (`protectedColumns`' `boxes`): a cut there would open the lake's side. An entrance
  step that reaches a column's top, or leaves it a roof of one block, opens the column to its top,
  and a single block left with air or cave air on all six sides is cleared (full detail chunks,
  off the core's edge columns, so the padding stays the neighbour's core). Where a worm carves a
  top of grass, dry grass, podzol, mycelium or snow, the dirt it uncovers becomes that block again.
- **Determinism.** A worm depends only on the seed, its grid cell, the full detail surface
  (heights and river strength) and the seed-only cave regions. A chunk visits every cell whose
  start lies within the kind's reach (its longest worm) of its padded box and clips its writes to
  that box, so its padding equals the neighbouring core (a test checks every side). Each block is
  decided alone, so the worms' order doesn't matter. Cells and their built worms sit in an LRU per
  generator (384 entrance and 48 ravine cells); the first chunk in a new area builds ~25 worms
  (~0.7 ms each, interpreted), and `generate`'s `yield` is called after each one built and
  every 16 steps while one is (`WORM_PAUSE`: a cold worm samples the surface along its whole walk,
  up to ~7 ms; `carvesTop(x, z, yield)` passes a caller's yield on to the worms it builds).
- **Trees and spawns.** `carvesTop(x, z)` says, from the worms alone (never the chunk's data),
  whether a surface cave may carve the top of column (x, z) or of one within 1.5 blocks: trees are
  refused there (see Structures) and `findSpawn` skips it. It keeps the worms of its last 16 tiles
  of 32 × 32 blocks, so a tree spot costs some 10-30 µs.
- **Levels.** LOD levels 1-2 (`SurfaceCaves.MAX_LEVEL`) point-sample the worms like the
  structure writer (a cell is carved when its sample block is), but only the ravines and the
  entrance steps that open a column (pits and mouths): tunnels under an intact roof can't be seen
  from afar and would only cost parts. Far ravines show as cuts out to ~400 blocks instead of
  appearing at the full detail edge; see Seams for both sides of a border.
- **Numbers** (Lune, seeds 12345 and 777, four areas of 32 × 32 chunks per terrain type): 50-72
  entrances per km² of land (no mouths on plains, half to three quarters of them mouths in
  mountains), 55-66% of them meeting cave air in most areas (53-80% in all), and 1-6 ravines;
  65-120 openings per km² (8-connected groups of columns whose top was carved), median 17-37
  columns. Interpreted, carving costs 0.26 ms per full detail chunk (1-4% of generation),
  0.32 / 0.84 ms at levels 1 / 2; level 1 nodes get ~6-7% more boxes, level 2 ~1-2%.
  tests/spec/SurfaceCaves checks determinism and seams, the cell rules, ores, trees, plants,
  spawns and structures, the LOD sampling and seams, that tunnels are continuous and walkable,
  that there are no long open ditches or floating blocks, the regrown tops and the cost (the dry
  land rule has no test of its own yet).
- **Not Minecraft.** Entrances always start on the surface and steer towards the caves
  (Minecraft's tunnels start anywhere from y 8 to 180, so its openings are incidental); one
  sideways branch while the tunnel goes on (Minecraft forks both ways and ends the parent); a
  chamber at the end instead of rooms at the start. Ravines follow the surface, so they are always
  open (Minecraft's sit at y 10-67 and are often buried), and are rarer (~3 per km² against
  Minecraft's 0.01 per chunk, ~39 per km² buried ones included). No water aquifers (lava below
  `Caves.LavaLevel` fills what they cut that deep: see Lava), and a dry margin instead of only
  skipping fluid blocks; nothing carved next to structures (Minecraft carves under villages).
  Surface caves don't show on the map (it paints the generator's column data). Single blocks between
  a tunnel and a cave can still float in a chunk's edge columns.

### Lava (`Lava.luau`)

Minecraft 1.20.1's overworld lava in three parts, all of it sources (level 0) at rest: nothing
flows until something next to it changes (server Behaviours/Fluid).

- **Below `Caves.LavaLevel`** (11; levels 0-2, `Lava.aquifer`, right after the surface caves).
  Minecraft fills every cave below y -54 (its surface 10 blocks above the world's floor:
  NoiseBasedChunkGenerator's fluid picker) and its carvers carve lava at aboveBottom(8) and below.
  Here every cave air cell below y 11 becomes CaveLava (cave air while caves are hidden: see
  Meshing) and every Air cell there (a surface cave cut that deep) ordinary Lava: the deepest caves
  and the Underlands' floor under the highest mountains are lava seas (420-460 cells per chunk with
  caves, ~2,300 in a chunk of Underlands floor), meshed hidden to exactly the boxes of cave air.
  LOD levels 1-2 have no caves, so there only a ravine cut that deep fills.
- **Lakes**: LakeFeature with lake_lava's configuration (`shapeOf`, Minecraft's draws): a 16 × 8 ×
  16 box of 4-7 overlapping ellipsoid blobs (3-9 wide, 2-6 tall) inside its cells 1..14 / 1..6 /
  1..14, lava in the lower four layers and air (the bowl) above. A lake is refused where a shell
  cell (next to the blobs) is liquid from layer 4 up or not solid below it, so lava never spills;
  then solid shell cells become stone below layer 4, and half of them (a draw each) from layer 4
  up.
  - **Underground** (`underground`; level 0, after the ores; lake_lava_underground adapted to cave
    floors). One chunk in `Underground.Rarity` (1) of those with caves tries `Tries` (8) random
    core columns at random heights for a cave floor (cave air over rock, within 32 blocks down) at
    least `Depth` (30) blocks below the surface, and sinks a box on the chunk's core into it with
    the floor block in layer 4. CaveLava and a cave air bowl: nothing to draw while caves are
    hidden. Decided from the chunk's own blocks (rock below the lava, no liquid by the bowl, no
    surface cave air or fluid in it, the caves' margin under every column, no structure piece);
    the blobs never reach the core's outer columns, so no neighbour's padding holds them (only the
    stone barrier may sit in a core edge column, where it replaces rock: it culls alike). One in
    3-6 chunks with 2,000 or more cave cells gets one (seeds 12345 / 777: 1 in 3.3 / 5.5).
  - **Surface** (`surfaceLakes`, `writeSurface`; levels up to `StructureMaxLevel`;
    lake_lava_surface). One candidate per 16 × 16 cell with chance 1 / `Surface.Rarity` (200), its
    layer 4 at the full detail height of the box's centre (Minecraft: its corner). Decided from the
    full detail heights alone (ground below a column's height, air above it, water below the sea),
    so every chunk and level agrees: refused in snowy or wet biomes (frozen, snow-topped, humidity
    0.45 or more), next to water, where a cell could meet a deep cave (any cell less than the
    caves' 9 cave-free blocks below its column's surface), within 2 blocks (PROTECT) of a structure
    piece or a geyser's lake, and within `SpawnClearance` (128) blocks of the spawn. Ordinary Lava,
    0.7-1.6 lakes per km². Surface caves leave the box and 2 blocks around it alone and trees keep
    out; LOD chunks put lava in the top cell of a column whose sample block lies over the lake's
    lava.

### Oil wells (`OilWells.luau`)

BuildCraft 7.1's OilPopulate on this world's terms, decided from the seed, its grid cell and the
full detail terrain only (`find`, cached per generator), so every chunk and level agrees.

- **Placement.** One candidate per `Spacing` (512) square cell, at a hashed column INSET (32)
  blocks from the cell's sides (a well never reaches past its cell). It is a well with its biome's
  chance in `Biomes` (Desert 0.6, Savanna and Windswept Savanna 0.5, Plains 0.45: BuildCraft's oil
  biomes), `Chance` (0.12) on other land and `Sea` (0.15) under the sea; never within
  `SpawnClearance` (256) blocks of the spawn, nor where a library structure's piece comes within
  MARGIN (2) of it. Sizes by share (`Sizes`): large 25% (deposit radius 8-12, lake radius 7-10,
  spout 16), medium 50% (5-7, 4-7, 6), small 25% (3-4, no geyser); undersea pockets are all of
  `SeaSize` (small), which leaves the draws of land wells as they were.
- **Deposit.** A sphere (distance² ≤ r²) centred `Depth` (20-40) blocks down, kept COVER (6)
  blocks under the lowest ground above it and off the bedrock (a deposit under a shallow sea floor
  shrinks to fit, or there is none), and moved up or down in steps of 4 within its depth range
  out of the deep caves' regions (`Caves.regions` at most 0.05 at its centre and 14 points of its
  surface), else no well: deposits are buried in rock, not hollowed out by a cave. Its rock
  (opaque, not bedrock) becomes CaveOil, so a buried deposit meshes hidden like plain rock. Cave
  entrances and ravines are carved before it: where one cuts near the sphere, the deposit keeps
  CLEAR (2) below the lowest carved cell of that column and its 4 neighbours (`Terrain.carved`,
  asked of the worms, `SurfaceCaves.mayCarve` and `lowestCarved`, so padding agrees; the well's
  own lake square is skipped, as TerrainGenerator protects it), so no CaveOil faces open-sky air.
  About 190, 900 and 4,800 cells (buckets) for small, medium and large wells.
- **Geyser** (large and medium wells on land more than 2 above the sea). The lake (`lakeOf`,
  BuildCraft's generateSurfaceDeposit: tendrils from the centre with its falling chance
  `(radius - w + 4) / (radius + 4)`, holes filled; `LakeDepth` 1-3 deep, its top one below the
  ground, the block over it dug away) covers columns no higher than the centre's and at most one
  lower, so rough ground gives a smaller, ragged lake, as BuildCraft's setOilColumnForLake does
  (median 36 columns; about 12% have fewer than 10); a column whose neighbour outside the lake is
  lower than the oil's top is left out (no open side), but never the centre, which is the spout's.
  Its radius shrinks until the ground on two rings around it is dry (above sea level + 1); only a
  spout within 2 blocks of water or a beach loses its geyser (none did over 1,568 km²). The spout, a
  1-wide column of sources, rises from the deposit through the lake to `Spout` (16 large, 6 medium)
  blocks over the ground: CaveOil below the lake (replacing rock, cave air and lava alike, so it
  runs on through a cave as a pillar), ordinary Oil in and above the lake. Surface caves leave the
  lake's square and MARGIN around it alone, and trees keep out. LOD chunks up to `StructureMaxLevel`
  put oil in the top cell of columns whose sample block lies in the lake and draw the spout in the
  cell holding its column, so geysers show from afar; the map paints them as black dots.
- **Undersea pockets.** Wells under the sea are small deposits without a geyser.

Generated oil is sources at rest: a broken block beside the spout makes it pour out
(Behaviours/Fluid), as BuildCraft's does. Seeds 12345 / 777 over 784 km² each: 379 / 302 wells
(0.48 / 0.39 per km²): 1.1 / 0.9 per km² of oil biomes, 0.26 / 0.27 of other land and 0.30 / 0.33
of sea; 254 / 151 geysers (0.32 / 0.19 per km²), nearly every large and medium well on land.
Undersea pockets hold 1-4% of the oil, oil biomes 55-59%.

Cost per chunk (native / interpreted): lookups 0.005 / 0.013 ms, lava below LavaLevel 0.02 /
0.14 ms, underground lakes 0.05 / 0.36 ms, writing a surface lake or a geyser 0.05 / 0.23 ms (a
whole chunk: 9.3 / 21.8 ms); deciding a lake or a geyser's lake costs 0.5-2 ms once per
generator, and `findSpawn` (for the spawn clearances) 3-7 ms once.

### Lakes and puddles (`Lakes.luau`)

Surface water, decided like the surface lava lakes from the seed and the full detail heights
alone (`Lakes.Terrain`: a cell below a column's height is ground, at or above it air, or water
below the sea), cached per generator, so every chunk and level agrees. All of it is water sources
(level 0) held in on every side and below: nothing flows until something next to it changes.

- **Lakes** (`lakes`, `write`; Minecraft's lake_water, the overworld's LakeFeature for water
  before 1.18 replaced it with aquifers). The lava lakes' shape (`Lava.shapeOf`, the same draws:
  4-7 ellipsoid blobs in a 16 × 8 × 16 box), water in its lower four layers, the bowl above dug
  out as air; the shell's barrier draws are made and unused (lake_water has no barrier). One
  candidate per 16 × 16 cell with chance 1 / `Lakes.Water.Rarity` (600; lava's is 200), times the
  biome's weight in `Lakes.Water.Biomes` (deserts 0.3, savannas 0.5-0.6), its layer 4 at the
  full detail height of the box's centre, more than `SHORE` (2) blocks above the sea. Minecraft's
  shell rule keeps the water in: refused where a shell cell is liquid from layer 4 up or not
  ground below it. Also refused where a cell could meet a deep cave (the caves' 9 cave-free
  blocks), within `PROTECT` (2) blocks of a library structure's piece, an oil well (deposits too)
  or a surface lava lake, within `SpawnClearance` (24) blocks of the spawn, and when a candidate
  in a neighbouring cell also passed its roll (two overlapping lakes, each decided alone, could
  spill into each other's bowl; about 1 in 60 lakes is lost). Written at full detail as:
  - water, and Ice in the top layer where water freezes (a frozen or snow-topped biome);
  - air in the bowl (bedrock stays);
  - the lake's floor (`floor`) in soil (dirt, grass, podzol, mycelium, coarse dirt, snow) under
    or beside the water: the biome's underwater block (sand, gravel), or for biomes with a dirt
    floor patches per column (`floorAt`: the mean of two hashes of the lake's `patch` seed on 3-
    and 2-block grids; below 0.45 sand, below 0.62 gravel, else dirt: about 40 / 31 / 29 %, like
    Minecraft's disk features; there is no clay block), dirt where water lies under the cell too
    (no sand that could fall);
  - the shore: a grassy top beside the water with the sky above it becomes sand or gravel in 2 x 2
    patches (`shoreAt`: a hash below 0.4 sand, below 0.55 gravel; a sand- or gravel-floored
    biome's own block below 0.55), only on an opaque block (never over air or water); else it
    stays (grass at the water's edge). Frozen lakes keep their shores;
  - the dirt the bowl uncovers above the water grows the column's top back (Minecraft turns it
    into grass or mycelium; here also dry grass, podzol and snow).
  `topCells` drop below the lowest written cell, so plants never grow in the water (Foliage needs
  air above the ground) and the sky line describes the ground. LOD chunks up to
  `StructureMaxLevel` put water (or ice) into the top cell of a column whose sample block lies
  over the lake's water, as the lava lakes do. Surface caves leave the box and 2 blocks around it
  alone and no tree grows there (`keepOut`). The map paints the lakes' water at up to 8 blocks a
  pixel (`MapPainter.paintLakes`). Seeds 12345 / 777: 0.30 / 0.58 lakes per km² over 67 km² (lava
  lakes 1.55 / 0.69), one in 10-20 frozen.
- **Puddles** (`puddles`, `write`; not a Minecraft feature). One candidate per
  `Lakes.Puddles.Spacing` (32) square cell at a hashed spot, kept with its biome's chance
  (`Lakes.Puddles.Biomes`, else `Chance`: jungles 0.14, mushroom fields 0.12, forests 0.08-0.1,
  plains and meadows 0.05-0.06, windswept hills 0.03, savannas, stony peaks and deserts
  0.005-0.012; frozen and snowy biomes none). From the spot it runs downhill, steepest first, up
  to `DRAIN` (12) steps to a column no 4-neighbour is lower than, the bottom of a dip at height
  L (still going after 12 steps: a long slope, no puddle). From there it floods outwards over
  columns of height L, within a wobbly radius (`Radius` 1.5-3.5 blocks, two harmonics of up to
  30% each) and up to `Size[2]` (20) columns, but only onto columns with no lower 4-neighbour,
  so every water cell (y L - 1, in place of the top block) has ground or water beside it and
  ground below. Fewer than `Size[1]` (3) columns, L within 2 blocks of the sea, a column a cave
  entrance or ravine may open (`SurfaceCaves.carvesTop`), a frozen or snowy biome on or next to
  it, a structure's piece, an oil well or a lava or water lake within `PUDDLE_MARGIN` (1), or the
  spawn within 24 blocks: no puddle. Two candidates draining into the same dip overlap at the
  same water level, which holds as well. Full detail chunks only: a puddle is a few blocks
  across, under a far node's cell, and puddles cost nothing at LOD but the decisions (far nodes
  still keep trees and surface caves out of them, so trees agree at every level); the map paints
  them at 1-2 blocks a pixel. Seeds 12345 / 777 over 16.8 km²: 22 / 14 per km² (37 / 92 per km²
  of land), 3-20 columns (median 12-15); per km² of each biome: jungles 111-123, mushroom fields
  114, forests 74-106, birch forests 61-71, taiga 58-65, old growth taiga 51-68, plains 47-53,
  meadows 44, windswept hills 16, savannas 4-24, deserts 2-4, frozen biomes 0. (Puddles are
  counted by the biome at the dip's bottom, which a spot in a wetter neighbour can drain into:
  savannas next to plains get more than their own chance.)

A puddle decision calls the generator's `yield` (handed down through `puddles`) every 64 new
height lookups, around its checks of wells, lava lakes, structures and lakes, and while
`carvesTop` builds worms: a cold decision ran up to 11 ms in one go, more than a slice of the
server's background generation or a worker's (see Server chunk generation). The answer never
depends on where it yields, and a decision is cached only once complete.

Cost: deciding a km² of puddles takes ~35 ms (native code, once per generator), more than half of
it building the surface caves' worms (`carvesTop`, last), which the chunks there build anyway, and
lakes ~6 ms; chunks around lakes and puddles generate within a few percent of the time without them
(tests/spec/LakeGeneration, which also checks the shapes, that no water cell has an open side or
bottom, determinism and the seams, trees and plants, far nodes, solidBelow / emptyAbove, the
cave visibility graphs and the map).

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
below), so no canopy is cut by a hut and no trunk stands in a path, inside a surface lava or
water lake's box, a puddle's bounds, a geyser's lake square or a mineshaft entrance's square
(5 blocks around its opening's centre) (with their margins: TerrainGenerator's `keepOut`; far
nodes keep trees out of puddles and entrances too, though they don't draw them, so every level
agrees on every tree), and where a cave
entrance or ravine may carve the column's top (`SurfaceCaves.carvesTop`, decided from the worms,
never the chunk's data, so every chunk and level agrees on every tree).

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
  (`solidBelow`). Cave entrances and ravines leave every column within 2 blocks of a piece alone
  (TerrainGenerator's `protectedColumns`, from the pieces' world boxes), so foundations never fill
  a pit and paths never float over a ravine.
- **Chests.** `container(x, y, z)` (the generator's `structureContainer`) looks up the template's
  container record at a world cell, a fresh copy of its items; the last piece writing there
  decides, and nil means no generated container. The server fills a generated chest from it the
  first time its contents are needed (see Server).

In a normal Luau VM a chunk under the example outpost costs within a few percent of plain terrain,
an outpost's assembly (~30 pieces) about 0.5 ms, and chunks with no start near them the same as
before.

### Mineshafts (`Mineshafts.luau`)

Minecraft 1.20.1's abandoned mineshafts (MineshaftStructure, MineshaftPieces), procedural rather
than templates: a jigsaw structure underground would write plain Air (always meshed, never
hidden); these write cave air and cave twins, which hidden caves draw as rock. Written in full
detail chunks only (caves exist only there), in step 8 after the library structures.

- **Placement** (`Config.Mineshafts`). One candidate per `Grid` × `Grid` (128) block cell, kept with
  `Chance` (0.25: ~15 per km², Minecraft's 0.4% of chunks), from `Hash.rng(Hash.hash3(salt, gx, 0,
  gz))`: the start room's corner at a hashed spot of the cell, its size (8..13 × 5..10 × 8..13),
  and its floor `Depth` (28..64) blocks under the full detail surface of its centre, never below
  `MinY + 4` (a start that can't keep 28 blocks over it, a deep sea floor, is dropped). Depth is
  measured from the surface because the world is 1024 tall: Minecraft's absolute y -10..52 would
  bury them hundreds of blocks deep or put them in the Underlands. Overgrown with
  `clamp((humidity - 0.1) / 0.5, 0, 1) × OvergrownChance` by the start column's biome; an
  overgrown one wants an entrance with `EntranceChance`.
- **Pieces.** Minecraft's grammar with its draws, depth first from one random stream (rooms with
  exits along their sides; crossings at rand(100) ≥ 80, stairs ≥ 70, else corridors 5 n long,
  shortened while refused; straight on, left or right a block down, level or up; side branches
  every 5 blocks two steps deeper; nothing past `MaxDepth` 8 or `Extent` 80 blocks from the room's
  corner). A piece is refused below `MinY`, with less than `Cover` blocks of ground over it (on a
  world-aligned 8 block lattice of columns within 4 of its footprint), overlapping an earlier
  piece, or within `MARGIN` (2) of a library piece, an oil well or its lake, a surface lava lake, a
  water lake or a puddle (TerrainGenerator's `blocked` lists them per 64 × 64 tile, with their own
  margins). Plans depend on the seed, their cell and the full detail terrain only, and are kept in
  an LRU of 64 cells per generator (each worker its own); a lookup only builds the cells whose
  start may reach it (`Extent + 30` blocks every way). Measured in Lune: 9-16 per km² on eight
  seeds (13 on seed 12345; starts under deep sea floors are dropped), typically 60-150 pieces; a
  plan builds in ~1-3 ms (a lookup at a room 2.3 ms median with cold lakes and puddles, 13 ms at
  most for two big ones). A build calls the generator's `yield` every `PAUSE` (64) terrain
  lookups, a `blocked` tile counting 64 (yielding before and after it, and handing it the yield:
  TerrainGenerator yields between its lists and Lakes after each puddle candidate and inside
  each decision; the entrance check hands `carvesTop` the build's yield too), and
  `entrances` takes the yield too: on seed 42 the longest level 0 stretch between yields went
  from 11-12.5 ms to ~6 ms (one cold puddle decision), against ~3-5 without mineshafts.
- **Writing** (`write(plans, data, originX, originZ, cells, heights, carved)`): every plan
  touching the padded chunk, its pieces in plan order clipped to it, a plan's overgrowth after all
  its pieces, then every entrance. Rock (opaque, not bedrock, not the structure's planks, logs or
  chests) becomes cave air; Air (a surface cave) stays Air; fluids are never touched; and no cell is
  carved within `GUARD` (2) blocks of the open above or beside it (its own and its four
  neighbours' full detail heights), so a cliff between Cover samples never opens a tunnel to the
  sky or the sea. Decorations go into cave air as their cave twin and into Air as themselves;
  those hanging on a side (torches, vines, lichen) only into cave air. An opaque or ordinary block
  is decided by the plan, per cell hashes and its own column only, so a padding column gets what
  the neighbour's core column gets (ores count as rock, twins as the cave air they may be); twins
  may read their sides, so a padding ring twin can differ, as glow lichen's can. Every attached
  block written is checked last and taken away if what held it went. Each piece's box grown by
  one, each log pillar and each shaft is marked read in the cave lattice. `write` returns the
  lowest cell it wrote with something neither opaque nor a cave cell (ordinary decorations in a
  surface cave, the shaft's air and rope: `solidBelow`) and one above its highest (`emptyAbove`).
- **Furnishing** (MineShaftCorridor.postProcess per column): rough ceilings (80% of the top layer),
  a support every 5 blocks (a plank beam where the cell above isn't open, a quarter of them only
  their end planks; oak fence posts under the end planks), wall torches 5% each side of a whole
  beam (twins hanging on the beam), cobwebs 10% / 5% at the top corners under opaque rock (60% of
  a spider corridor's lower two layers), planks over floor cells that aren't sturdy and oak log
  pillars down to sturdy ground within 20 blocks under a bridge's ends, rails 70% along a rail
  corridor on a sturdy floor (along its axis: `Blocks.axisVariant`), a Chest 1% per section side on
  a sturdy floor (decided with the plan, so `container` needs no chunk); crossings get plank
  pillars and floors; rooms and stairs are carved only. Overgrown: moss blocks on the rock around
  the open space (floors 60%, ceilings 25%, walls 30%; from the pieces' open cells, not the
  chunk's), moss carpets 35% over moss or planks, hanging roots 8% under sturdy ceilings, vines
  15% from wall cells under the ceiling hanging 1..3 cells, glow lichen 6%; cobwebs × 0.3, no
  spider corridors.
- **Entrances** (overgrown, when a spot passes): the room's centre (moved up to 2 blocks), then each
  corridor section's middle between supports, at most 32 tried; the 3 × 3 opening must lie in
  core columns 2..13 of one chunk (so the whole entrance, collar and headframe, is in columns no
  neighbour holds in its padding and no LOD seam meets), its 5 × 5 collar on dry level land (within
  a block of the centre's height, above sea level + 2, no river), no surface cave opening there
  (`carvesTop`), nothing of the `blocked` list within 2 blocks, 32 blocks from the spawn
  (`spawnColumn`; findSpawn is unchanged, so there is no cycle) and no other piece of the
  mineshaft in the shaft's way. About `EntranceChance` (half) of the overgrown mineshafts under
  dry land get one (0.38-0.57 on eight seeds; 45 of 85 on seed 12345); one under the sea or a beach
  never does (every candidate fails the dry land rule, and more than 32 candidates find almost
  none more), so of all the overgrown ones 0.18-0.45 by the seed (46 of 103 on 12345, 36 of 195
  on 777). It is Air from the piece's floor layer up through the ground (an underground pocket for
  the cave view, open to the sky like a cave entrance's pit; `topCells` stay), planks under the
  opening where its floor is not sturdy (a room keeps its natural floor, which a cave may cross: 9
  of 86 entrances on four seeds hung their rope over a drop, some over a lava sea) with log
  pillars under the planked corners, a mossy cobblestone collar
  two deep, two oak fence posts three tall and a 5 block oak log beam on them `FRAME` (3) over the
  collar, an ordinary Rope from under the beam's middle to the floor (each held by the one above,
  the top one by the beam), vines down its walls from the collar's top layer and from the beam.
  The beam's height is the climber's (PlayerPhysics): holding jump up the rope, the head meets the
  beam with the feet 1.2 over the collar, enough to drift across the beam onto the collar before
  dropping below its top; under a beam 2 over the collar the feet stop 0.2 over it and a climber
  stepping off falls back down the shaft (tests/spec/MineshaftClimbing). A wall vine run starting
  in the collar's top layer climbs out the same way as a ladder's top. Its square (5 blocks around) joins `keepOut` at every level up to
  `StructureMaxLevel`, so trees and surface caves keep away.
- **Loot.** `container(x, y, z)`: Minecraft's chests/abandoned_mineshaft on this game's items
  (`Mineshafts.LOOT`), rolled from `Hash.rng(Hash.hash3(lootSalt, x, y, z))` into random slots,
  a fresh table each call.
- **Cost.** Level 0 chunks over an overgrown mineshaft: ~3.9 ms against ~3.5 without (best of 5,
  90 chunks); far nodes only ask for entrance squares (no measurable difference).
- The debug structures world (`DebugWorlds`) writes two fixed samples (`Mineshafts.sample`)
  through the same module into its floor's stone.

### Glow lichen (`CaveDecor.luau`)

Minecraft 1.20.1's `glow_lichen` feature (104-157 tries a chunk on stone-type faces 13+ blocks
below the surface, ceilings and walls, spreading half the time) as patches decided per cell, in
full detail chunks after the structures:
1. Patches: one per 8³ block grid cell with chance 0.08 (rare finds, not every corner), at a hashed centre with a hashed radius
   of 2..4. A chunk visits the patches whose sphere reaches its padded box, and in them only the
   cave lattice cells the carver carved (`Caves.Carved`), skipping those that are cave air
   throughout with cave air all round (no cell there touches rock): the work follows cave walls
   near patches, not the rock or the cave volume (an Underlands chunk has 100k+ cave air cells).
2. A cell must be CaveAir at least 13 blocks below its column's surface.
3. A face is a candidate when the block above, or north, south, west or east, is rock: Stone,
   Andesite, Diorite, Granite, Calcite and every block Ores places (ores are only in each chunk's
   own core, so counting them keeps a cell next to one deciding alike in every chunk). No floors,
   as Minecraft's feature.
4. A per-cell hash is rolled against 0.6 fading linearly to 0 at the sphere's edge (overlapping
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
their tall forms, dead bushes, flowers, tall flowers and mushrooms, and Tough As Nails' herbs
(`foliage.herbs`: mint, wild ginger). It runs after structures, in
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
- herbs take the part of the roll's range above the other plants (`herbs.chance`, 0.004 a soil
  column), so they only grow where nothing grew before (adding them moved no grass or flower),
  with a patch noise of their own (~16 blocks) and a small `cover` (0.04): rare patches of about
  4 herbs some 30 blocks apart on open ground (tests/spec/Herbs measures them on the seed); mint
  on plains, meadows and in jungles, wild ginger in forests, birch forests and both taigas;
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
side and corner, next to trees), the placement rules and the cost (plants about 0.1-0.2 ms per
chunk in Lune, interpreted; the edge columns' extra heights about 0.4 ms more).

### World types (`WorldTypes.luau`, `LayeredGenerator.luau`, `Superflat.luau`, `DebugWorlds.luau`)

Minecraft's world presets. `WorldTypes` is the registry: each type has an id, a name, a
description, `create(seed, options) -> Generator`, the options it understands (`settings`, for
the Create World screen: toggles, choices with labels, texts with ready-made presets) and hints
for the rest of the game (`mobs = false`: no natural spawning, `World/WorldInfo.apply` turns
`Config.Mobs.Spawning` off before the world starts; `ticks = false`: the server's `startWorld`
builds its BlockTicker without behaviours, so there are no block updates and no random ticks, as
in Minecraft's debug world; `gameMode`: the mode the Create World screen preselects, and the one
players get with the menu off; `debug`: the screen lists these last). The server publishes
`WorldType`, `WorldOptions` (one string, `encodeOptions`) and then `Seed` on
`ReplicatedStorage.IceVoxel`; the server, the client boot and every chunk worker build the same
generator from them (`fromAttributes`); `published` reads the type back once the world exists.
`Config.World.Type` / `Config.World.Options` choose the world a server starts without the menu.

| Type | Generator | Notes |
| --- | --- | --- |
| Default | TerrainGenerator | `structures` toggle |
| Superflat | Superflat on LayeredGenerator | `preset` text (layers bottom up, then the biome), `decoration` toggle |
| The Void | LayeredGenerator | 33 x 33 stone platform at y 64, cobblestone centre; no mobs |
| Single Biome | TerrainGenerator `biome` | `biome` choice (BiomeList), `structures` |
| Large Biomes | TerrainGenerator `climateScale = 4` | `structures` |
| Debug: All Blocks | DebugWorlds on LayeredGenerator | every block id once; no ticks, no mobs, spectator |
| Debug: All Structures | DebugWorlds, StructureGen fixed layout | every library template and structure, two sample mineshafts, name tags; no ticks, no mobs |
| Debug: All Biomes | DebugWorlds on LayeredGenerator | a 16 block strip per biome; no mobs |

**LayeredGenerator** builds a whole Generator from a stack of layers per column (one stack
everywhere or `columnAt(x, z)`), blocks laid over the stacks (`blocks`: x, y, z, block) and an
optional StructureGen placer. Everything a consumer asks works at every level: a cell holds the
stack's block at its sample height, the ground's top cell shows the surface block (grass stays
green from afar), a stack thinner than a far level's cells still fills cell 0 (a 4 block classic
flat world is drawn one 16 block cell tall at level 4 rather than vanishing), LOD border columns
lower their ground a cell (the Default's skirt; water fills the freed cell) and the seam limits
round the coarser node's ground the same way, so seams have no cracks. Placed blocks go into the
cell that holds each, at every level (a lone debug block never falls between far sample points).
Water layers on top of the stack are the world's sea: `column` reports the ground under them and
`seaLevel` their top, as the Default reports its sea floor and sea level (spawning skips open
water, the map draws depth). `column` also reports a column's highest placed block above its
stack (map colour, spawn, sky checks). No caves (`carved` nil), surface caves that carve nothing,
no wells or lakes: the culling gets an exact sky line (`surface`, the ground) and every query is
cheap. Trees and plants (`decoration`) are the Default's Structures.populate and Foliage on the
ground, never under water. Each stack's cells are worked out once per level; one stack everywhere
is written a whole layer at a time (a layer like the one below is a `buffer.copy`) and then the
border columns' differing cells, a stack per column cell by cell. In Lune a full detail chunk
costs 0.02-0.06 ms (Classic Flat, Tunnelers' Dream, the void, all blocks, all structures) and
0.2-0.4 ms with trees and plants (decorated superflat, all biomes), against the Default's ~1.3 ms.

**Superflat** parses Minecraft's preset string in this game's names (`Bedrock,2*Dirt,Grass;Plains`;
names match loosely, as structure final states do, and a few Minecraft names map onto this game's,
so `minecraft:grass_block` works); `parse` explains what is wrong (unknown block or biome, a count
out of 1..`MAX_HEIGHT`, the stack taller than the world less the trees' room) and a bad preset
builds Classic Flat (`resolve`), so every machine agrees. The presets are Minecraft 1.20.1's whose
blocks exist: Classic Flat, Tunnelers' Dream, Water World, Overworld, Snowy Kingdom, Bottomless
Pit, Desert, Redstone Ready.

**DebugWorlds.** All Blocks is Minecraft's DebugLevelSource: every block id but air, cave air and
the cave twins (variants, both halves of tall plants, every fluid level; a twin looks exactly like
its twin, and hidden caves would draw it as a stone cap in the open air) at y 70, block k at
x = 2 (k // W) + 1, z = 2 (k % W) + 1 with W = ceil(sqrt(n)) (220 blocks: a 30 x 30 square),
nothing under them. Blocks that need support and fluids are shown alone, as they are: the type has
no ticks, so nothing flows, falls or pops even next to an edit. All Structures lays out every
template of the library (sorted, rotation 0) and every generated structure (assembled whole from
a seed of its own on flat ground) by shelf packing (ceil(sqrt(n)) per row, 5 blocks apart, rows 8
apart) on a grass floor whose first air is 65 (StructureGen's terrain matching pieces stay at sea
level or above); StructureGen takes the layout instead of its random spread (`layout`), so pieces
are written per chunk like any structure, far levels point sample them and chests hold their
loot. Each has a SAVE structure block 3 blocks north of its corner, named after it with its box
as the region; server `Structures/StructureBlocks` seeds those records from `generator.labels` at
the start, so WAILA names them and F3 draws the outline. Then two sample mineshafts,
"mineshaft" and "mineshaft/overgrown" (`Mineshafts.sample`), in a row of chunks of their own: the
generator is the LayeredGenerator's with its full detail `generate` wrapped to write them into the
floor's stone through Generation/Mineshafts (24 blocks under the floor; the overgrown one's
entrance opens on the floor with its rope), `structureContainer` answering for their chests and
`mineshafts` listing them. All Biomes repeats 16 block strips of
every biome's ground (stone, filler, top) with its trees and plants.
Single Biome changes only the biome pick (the terrain's height is the Default's everywhere: a
desert's sand climbs the mountains, a tundra freezes the seas); Large Biomes only the climate's
wavelengths (the altitude bands and their dither stay, so mountains change as before and the
lowlands' climate patches grow).

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
  themselves, so oceans become thin sheets instead of tall transparent boxes. Fluids compare by
  their surface form (`fluidFormLut`: a cave twin is its source), so where CaveLava meets Lava (a
  twin flowed, or a bucket was poured into a lava sea) no wall is drawn between them;
- a fluid cell without the same fluid above it is **lowered to its level** like Minecraft
  (`Blocks.fluidHeightLut`, in ninths of a block: sources 8, flowing levels 7..1, falling full).
  The height is packed next to the appearance id in the box key (`GreedyMesher.decodeKey`), so only
  cells of the same height merge and flowing water visibly steps down;
- with `hideCaves`, cave air counts as rock and every cave wall disappears. **Cave twins**
  (`Blocks.caveTwinLut`: the CaveGlowLichen* generation puts on cave walls, the CaveLava of lava
  seas and underground lakes, the CaveOil of oil deposits) count as cave air then: they have no
  appearance (`appearanceHiddenCaves`), are rock to their neighbours (`Blocks.cullLutHiddenCaves`)
  and are cave air to the stone caps at a revealed section's hidden sides (see Streaming), so a
  hidden cave's lichen and lava and a buried deposit cost nothing and hide nothing (64 chunks with
  every cave cell below y 15 turned to lava mesh hidden to exactly the boxes of empty caves, 2,672,
  against 3,728 (+39.5%) with ordinary lava; revealed, both mesh alike). A hidden cave
  cell (`caveCellLut`: cave air or a twin) that touches a cell that is neither opaque nor a cave
  cell (air, water, glass, a torch: where a cave entrance, a ravine or a shaft dug from the
  surface runs into a hidden cave) is drawn as a **stone cap** (`STONE_APPEARANCE`), so that air
  looks at rock, never the void (above the buffer counts as air, below the world as solid). Every
  other hidden cave cell is enclosed by rock and hidden cave, and is a wildcard like enclosed rock:
  not drawn, but a box may run through it, so the caps merge into the rock around them.
  QuadMesher draws the same caps face by face. Over six areas of 12 × 12 chunks: +0.7%
  hidden-mode parts (+2.7% where entrances are densest, -0.3% with no surface caves; +1.5% without
  the new wildcards), meshing +5-10% interpreted. A range with no cave cell in it or around it
  (`touchesCaves`: the cells its mesh reads, padding and the layers above and below) meshes the
  same with caves hidden or shown, so ChunkWorker meshes such a revealed section hidden, and
  buried rock is trivial again (with caves always shown, 2,161 of 5,689 mountain sections are
  meshed, in half the time; tests/spec/Meshing compares both on real chunks);
- **sparse lights** (`sparseLightLut`, per appearance: glow lichen and every fluid giving light,
  lava) are drawn in every cell, but only one cell per light box carries the light
  (`sparseBoxLut`: `LIGHT_BOX`³, 8³ blocks, for lichen; `FLUID_LIGHT_BOX`³, 16³, for lava, whose
  light reaches twice as far): among the box's drawn cells, the one nearest its centre
  (`lightScore`; on a tie the lowest, then northmost, then westmost). Boxes are world aligned and
  divide sections and chunks, and the choice depends only on the cells in the box, so the same
  blocks always light the same cell and lights never jump on a remesh. A lichen's chosen cell has
  surface field 1 (`decodeKey`), the others 0; a lava cell's key adds `FLUID_LIT` (16) to its
  height (`fluidSurface` splits them), so the lit cell is a box of its own and a lava sea's sheet
  splits into about five boxes per 16 × 16 surface. Lichen and lava choose apart (a box may light
  one of each). `noLights` (far nodes, whose parts carry no light: ChunkWorker passes it) marks
  nothing, so a far lava lake stays one box. An Underlands lava sea revealed (seed 12345, 197
  chunks, 51,235 lava cells drawn) gets 209 lights for +0.58% boxes (8³ boxes would be 824,
  +1.58%); hidden, it has neither;
- **plants** (`Blocks.foliageLut`) are shaped single cells like torches. With `hideFoliage`
  (`Config.Render.Foliage` off, or a chunk beyond `LodTree.drawsFoliage`; see Streaming) they are
  not meshed; they hide nothing, so every other box stays the same. `mesh` also returns how many
  plant cells the range holds, drawn or not. A **tinted** plant's key (`Blocks.tintedLut`: grass
  and ferns) carries its soil's foliage tint, `Blocks.tintLut` of the block below (below its lower
  half for a tall plant's top), in the surface field fluids use for their height; `decodeKey`
  returns it and the appearance tells the uses apart (a shaped block is never a fluid, and no
  tinted plant gives light, so the sparse light flag never clashes with a tint). Border copies
  (`applyBorder`) keep two layers below the range for it;
- **odd boxes** (`align`: `Config.Textures.OddBoxes`, off by default; ChunkWorker passes it for
  full detail sections only): every box of a `Blocks.alignLut` appearance (an opaque merged cube
  whose parts take a texture's MaterialVariant, `Align` not false; see Texture pack) is an odd
  number of blocks along each axis, for variants that tile from a face's centre. After each axis
  grows (X, then Z, then Y), an even run first starts one cell earlier when that whole slab is
  wildcards (hidden rock any opaque box may cover), else it stops one short. A box grows only over
  its own cells and wildcards, so no other appearance's boxes change, and with the flag off the
  boxes are byte for byte what they were (20,530 sample meshes, LOD nodes included). Cost: +14-18%
  boxes at full detail (+49% on flat plains; leaving the leaves out saves 7 points), no measurable
  mesh time. LOD nodes never use it: their cells are 2^level blocks, so every size is even anyway.

Boxes grow along X, then Z, then Y. Output is a buffer of 7 × u16 per box (position, size, key). Tests check the
invariants (every visible block covered once, nothing visible covered by a wrong box) on generated
chunks of every LOD.

Full detail chunks are meshed in 16-block vertical sections, so an edit only remeshes one section
(and the renderer only swaps the boxes that changed: see Rendering).
LOD chunks are meshed as one range between `solidBelow - 1` and `emptyAbove`.

## Client

### Streaming (`Streaming/ChunkStreamer`)

`LodTree.select` tiles the world with root nodes of the coarsest level and splits a node into four
children while the viewer is closer than `SplitDistance × nodeSize`. The leaves are the chunks to
show. They never overlap and leave no gaps. Hysteresis prevents flapping at split boundaries.
View and split distances come from the player's settings (`Rendering/ViewSettings`, see Player
settings): Config's `Lod` is the High preset, and phones and tablets start on the Low preset
(`Lod.Mobile`), because the engine draws parts only a few hundred studs far there anyway. With
"Prefer: Distance" (the default) ViewSettings sets `Lighting.PrioritizeLightingQuality = false`, so
that when the engine has to lower quality it keeps draw distance and gives up lighting detail
first. How far parts are actually drawn is the engine's decision (graphics level and visible
object count); scripts cannot raise it.

Each node goes through states:

```
waiting ──► queued ──► working ──► built ──► ready
(edit lists)  (score)    (actor)   (parts)   (shown in the next swap)
```

- **waiting**: full detail chunks need the server's edit lists for themselves and their four
  neighbours (neighbour edits on the shared border live in the padding; `ClientWorld` keeps each
  list's border columns ready, so a job never reads a neighbour's whole list).
- **queued**: sorted by score (below), most urgent last; nodes leaving `waiting` are inserted by
  binary search.
- **working**: a `ChunkWorker` actor generates, applies the edits and meshes (see Workers).
- **built**: the renderer builds its sections in its normal lane, by the node's score.
- **ready**: shown by the next swap pass, once nothing covers its area.
- **failed**: whatever covers the area stays; generated again after `Streaming.RetryDelay`
  (0.5 s), doubling up to `RetryMax` (8 s).
- **meshing**: a generation result that came back after an edit touched the chunk (or a coarser
  neighbour changed) is kept: the chunk's current edits are written into it on the main thread
  (`ClientWorld.applyJobEdits`) and only a mesh job is sent, so continuous edits never starve it.

**Load order** (`LoadPriority`, pure). Every refresh scores the nodes not ready yet, lower first:
the ring under the player (closer than 32 blocks) by distance; nodes in the view wedge (the
camera's horizontal field of view plus 15 degrees each side) and not hidden behind terrain by
distance; nodes behind closer than 128 blocks by twice their distance; then the rest out of view,
then what is hidden (`streamer.hidden`, see Hidden terrain). All the wanted nodes under one shown
node being replaced share their best score, because it only goes when all of them are ready, so a
visible sibling never waits for a hidden one. The renderer re-reads the scores (`reprioritise`).
After a teleport, 90% of the view is shown 15-40% sooner.

**Seamless LOD changes** (`SwapUnits`, pure). A node that is no longer wanted stays visible until
every wanted node covering its area is ready (`covered` only visits areas that hold wanted nodes).
Once a frame, when a node became ready or the selection changed, the swap pass groups the nodes
that may go and the ready nodes waiting to be shown into swap units, connected through the LOD
tree. A unit is done whole: its old nodes are cleared and its new ones shown in the same frame,
so two levels never overlap and never leave a gap (and `ChunkRenderer.clear` keeps the old model
`Render.SwapFrames` frames under the new one). Units go nearest first until
`Render.SwapPartsPerFrame` parts went out and in (at least one a frame; in teleport mode units that
only show nodes don't count; the far meshes get what is left of the allowance); the rest wait a
frame. A full detail chunk that a revealed tunnel next
door is open towards waits until that tunnel is closed (see Caves). `Streaming.ReplaceTimeout` is
a safety net. The movement controller keeps the hull frozen until the chunk under it and the eight
around it are shown (`isReady`); meanwhile the renderer may build up to 12 ms a frame
(`setFrozen`).

**Edits** (`RemeshQueue`, pure). Full detail chunks keep their block data on the main thread
(`World/ClientWorld`). Edits (local predictions and server messages) update the data and the
neighbours' padding and mark sections dirty, with a reason: edit, cave reveal, seam or plants (a
section keeps its most urgent one). Every section one batch of edits dirtied (the edited chunk and
the neighbours whose padding changed) is one renderer commit group: each chunk gets an edit job
(the worker runs it at the running job's next slice boundary; the renderer builds it in its edit
lane), and the group goes live in one frame. Each job holds the group until its builds are queued,
or it failed (its sections are marked again and the chunk waits 0.5 s, doubling up to 8 s). Other
remeshes go by reason, then distance, one job per chunk at a time, at most `Streaming.RemeshJobs`
(4) in flight while generation has work; once one member of a batch was sent, the others go next
and past that cap, so a batch is never left waiting on the cap. A chunk may have several jobs in
flight; a result only counts for the sections no newer job took. While loading, edits go live in
2 frames instead of a median of 6.

**Teleports** (`TeleportMode`, pure). `MovementController`'s teleport handler tells the streamer
the destination (`teleported`); a jump of more than `Streaming.TeleportDistance` (128 blocks)
between refreshes counts too. The streamer selects there in that frame, without hysteresis, and
drops every node no longer wanted in one pass: no `covered()` work, builds and worker jobs
cancelled (`WorkerPool.cancel`), models trashed (`ChunkRenderer.trashNode`: within 1.5 × the full
detail radius of the destination they leave at once, the rest nearest first within
`Render.UnparentPartsPerFrame`). Shown models that overlap nothing wanted are handed over 64 a
frame. The camera follows the character a frame late, so the cave view is judged from the eye
above the destination's feet (the standing eye height), and a teleport ends the underground hold,
so the destination is selected with the right full detail range at once. Until the 3 × 3 chunks
under the player are shown and at most `Streaming.TeleportSettle` nodes and builds are left, or
`TeleportTimeout` (10 s), far meshes, horizon jobs and map tiles wait. The first load works the
same way. The player unfreezes after 16-31 frames instead of 33-274, and no frame puts more than
~700 parts into the workspace (before: up to 22,600).

Far meshes also wait while more than `Streaming.BusyJobs` nodes or `BusyBuilds` builds are pending
(`MeshOverlay.setStreamerBusy`).

**Per refresh**: `LodTree.select` is skipped while the viewer moved less than a block and
`underground` and `LodTree.version()` are unchanged; seams are recomputed only next to coarse nodes
that changed (`LodTree.seamsAffected`); the cave view is checked again only where it may have
changed (below). In Lune (interpreted) a refresh costs 0.04 ms standing above ground (it was 2.2),
0.09 ms standing in a cave (12), and ~0.9 ms walking above ground (2.5) or ~1.7 ms in a cave (14).

**Caves** (`CaveReach.view`, `World/SectionGraph`: see Cave visibility below). While the camera is
more than a block below its column's terrain surface (the generator's uncarved height: in a cave, a
dug shaft, a cave entrance or a ravine), the sections it can see into through connected cave air,
and air carved or dug below the surface such as an entrance leading down to the caves, are revealed
(meshed with their cave walls); everywhere else cave air counts as rock (and is capped in stone
where open air meets it: see Meshing). Workers return each full detail chunk's graph (one u32 per
section) with its generation and recompute it for the sections an edit job remeshes (an edit can
open or seal a cave); results merge per section, so an older job's answer never overwrites a newer
one's. The search runs from the camera when it changes section, the reach changes, or a graph or a
full detail chunk near it changed (median 0.6 ms, at most ~3.6 ms where the Underlands hit
`Caves.RevealBudget` sections). It reaches `Caves.RevealReach` (88 blocks, scaled by the Cave View
setting: `PlayerSettings.revealReach`) along tunnels, and in big caverns the open space around the
camera plus a section, so caverns are seen as far as before: `CaveReach.probe` casts rays sideways
and upwards through the loaded blocks and their median distance sets a radius between
`Caves.RevealRadius` (64) and `RevealRadiusMax` (128; the cave view sets both: `revealRadii`),
growing at once and shrinking only after two seconds. A section stays revealed `Caves.RevealHold`
(2) seconds after the search stopped reaching it; sections of chunks not generated yet that the
search would enter count as revealed, so they are generated revealed. Over 29 caves on three seeds
this costs 0.96 × the parts of the 80-block sphere it replaced (median; at most 1.12 ×), sees
tunnels 88 blocks away, and walking remeshes about half as many sections.

*Caps.* Where a revealed tunnel runs into hidden space nobody would draw its walls, and you would
look into the void. A revealed section is therefore meshed with a mask of the sides where its
tunnels end in stone (`GreedyMesher.Border.hidden`): hidden cave air beyond them counts as rock,
and its own cave air touching that rock becomes a stone cap. A side is open only towards a section
that draws its caves on screen whenever this mesh does (`drawsCaves`): one in a full detail chunk
on screen whose revealed mesh is live, or goes live in the same commit group. A hidden section
draws no wall there and a coarser node nothing underground; a section the search misses shows a
cap, never the void. So what is on screen is tracked per section as each mesh goes live (`live`,
`liveCaps`, `wentLive`): a section that is only dirty or in flight never counts, and a cap closed
meanwhile opens once the section beyond is live (`liveCheck`). It holds the other way round too: a
section goes hidden only together with the caps closing towards it (`canHideNow`, checked again
when the job is sent: `mayHide`), and a full detail chunk leaves the screen only once no tunnel
next door is open towards it (`swap`). A change of caps only remeshes a section where cave air
reaches that side on either side of it (`capFaces`).

*Passes.* After a refresh only the sections whose reveal flag or caps may differ are checked
(`updateReveal`): the sections revealed or hidden and their neighbours, those of chunks next to
full detail chunks that came, went or were shown, nodes that became ready and meshes that went
live. One pass (`checkPass`) checks reveal flags first, then caps, so a cap opening and the section
behind it are marked together, and goes live in commit groups of at most
`Streaming.RevealGroupSections` (96) sections, nearest first; the sections being hidden and the
caps closing towards them are one group of their own whatever its size. Thin cracks can still show
at a tunnel's rim for a few frames while a side switches between open and capped across two
groups; the void across a whole tunnel cannot.

**The underground split.** Full detail chunks are the only ones with caves, so above ground's full
detail range (~96 blocks) would end every cave there. While the cave view is active with the camera
shut in (`CaveReach.enclosed`: its cell is cave air or a cave twin, a cavern under a ravine's cut
too, or an opaque block lies between it and its column's generated surface; cells not loaded count
as shut in) and for `Lod.UndergroundSeconds` (5) after that ends (`CaveReach.hold`, so walking in
and out of a cave mouth does not rebuild the chunks around it back and forth; a teleport ends it),
`LodTree.select` runs with `underground`: level 1 nodes split at the underground split distance
(`Lod.UndergroundSplitDistanceL1`, 4, phones 3; with settings: from the cave view,
`PlayerSettings.lod`) instead of `SplitDistanceL1`, so full detail and caves reach ~128 blocks;
coarser levels are unchanged. Level 1's hysteresis holds within one mode only
(`previousUnderground`): the first selection after going underground splits every level 1 node
within the new distance, as a fresh selection would, instead of keeping the leaves of the selection
above ground. Walking keeps full detail up to ~15% short ahead of the camera, as the hysteresis does
above ground. Measured in a cave near the spawn (seed 12345, with the reveal sphere the search
replaced): 268 full detail chunks instead of 164 and ~57,000 parts instead of ~47,000 (~139,000
instead of ~110,000 in the Underlands, before far meshes). F3 shows how far caves are revealed and
the split in use. At the open bottom of a pit, a ravine or a shaft dug from the surface the camera
is not shut in: what it sees is the sky and the surface, and the split would load 70-100% more full
detail chunks for nothing (in the streamer simulation 88 full detail chunks stay in a pit instead of
168, 80 in a ravine instead of 160). Walking down entrances, the camera is shut in about 3 steps
after the eye goes under; where an entrance passes under open sky again on the way down, the hold
covers it.

**Hidden terrain** (`HiddenTerrain`, `World/Horizon`: see Far nodes behind terrain below). Every
generated node carries a summary (lowest ground and highest top of 4 × 4 tiles); edits update
those of full detail chunks (`Horizon.applyEdits`: in the worker, for late results and for every
block change). About once a second while the camera moves or new summaries came in, or after 8
blocks of movement (never in teleport mode, when nothing new has a summary yet), a worker sweeps
the wanted nodes front to back from the camera (90-160 ms in the worker; the job may use the
pool's overflow slot) and returns the far nodes hidden behind nearer terrain: they load last
(LoadPriority's hidden tier; a node not generated yet is judged from the nodes it replaces). Nodes
within 64 blocks are never hidden. With "Skip hidden terrain" (the Hidden Terrain setting, read
every refresh; on in the Low preset) a hidden far node shows no parts (`held`): one generated
hidden is never built, and a built one hidden in 2 verdicts in a row gives its parts back (only
while the camera moves at most 6 blocks a second, and not the levels far meshes merge while they
are on). Both
count as ready, so swaps go on. They build again as soon as a verdict sees them or the camera
leaves the eyes the verdict was made from. Every far node keeps its meshes (`kept`: the buffers its
sections show, so they cost no memory of their own), so switching the setting on later applies to
what was built while it was off too. In the mountains 45% of the parts on screen are hidden; with
far meshes off at the default view, skipping keeps 41% fewer parts after loading and 34% fewer
while walking (valleys 30%, the spawn hills 1%). With far meshes on only level 1 qualifies (4%).

**Plants.** Every box (or sprite plane) of a plant is a part, and all ~180 full detail chunks
would hold 10,000-20,000 of them. So only full detail chunks within the plant distance of the viewer
(`Lod.FoliageDistance`, 40 blocks to the chunk's square, 24 on phones; the Plant Distance
setting; one already drawing them keeps them up to half a chunk further) draw their plants, while
`Render.Foliage` is on (`LodTree.drawsFoliage`): about 1,000-3,000 parts on grassland, at most
6,000. Jobs carry the node's `foliage` and workers report which sections hold plants (drawn or
not); when a chunk starts or stops drawing them (the viewer moved, the setting changed), only those
sections are remeshed, like edited ones. A node with a generation job queued or running is left to
that job, which takes the current answer.

**Settings**: `streamer:applyView()` (effects "lod", "caves", "foliage") sets LodTree's four
distances and plants from `ViewSettings`, a new cave reach tracker from its radii and the tunnel
reach, whether caves are always shown (below), and selects again in that frame. "Skip hidden
terrain" needs no call: it is read every refresh.

**Caves always shown** (the Caves setting, `ViewSettings.alwaysCaves`, default
`Caves.AlwaysShow` false). The streamer's `alwaysCaves` makes every section of every full detail
chunk revealed (`wantsReveal`), wherever the camera is; the search does not run, nor the probe
(only `enclosed`, which the underground split still needs). Nothing else changes: jobs carry every
section in `reveal`, caps close towards chunks that are not full detail on screen and towards
sections whose revealed mesh is not live yet, a chunk leaves the screen once the tunnels next door
closed, so the void rules above (*Caps*) hold as they are (tests/spec/Streaming runs the void check
through both switches, in the cave world and on real terrain). Far nodes have no caves at either
setting: levels 1-2 cut entrances and ravines as open air, the same both ways, so "revealed"
means nothing for them and they stay as they are; full detail chunks are where every cave shows.
Switching (`applyView` sees the setting change) starts a fresh cave view and sets `caveFlip`: the
next refresh checks every section of every ready full detail chunk once (`allSections`). The air
above a chunk's terrain (from `emptyAbove` up, about 60 of its 64 sections) just takes its flag
there, and only taller neighbours' sections facing it are checked; the sections holding terrain
go through the usual pass: REVEAL remeshes in commit groups of `RevealGroupSections`, nearest
first, or all hides in one group. Back to hidden the fresh search runs from the camera in the same
refresh, so what it reaches stays revealed. Nothing is generated again. Measured (real terrain at
a cave entrance's mouth, 88 full detail chunks, 446 sections of terrain): to always shown 648
sections remeshed (1.45 each: a cap closed where two commit groups met reopens once the other is
live) in 152 jobs; back to hidden 446 in 88 jobs; the switching frame 10-14 ms in Lune (passing
the air through `checkPass` too took 3-4 times that). Cost of the setting itself: about 4 × the
parts of full detail terrain (README, `lune run tests/bench`), plus a few hundred sparse lights.

### Workers (`Streaming/ChunkWorker`, `Streaming/WorkerPool`)

Every Actor runs ChunkWorker. Jobs: `generate` (a node's blocks and section meshes, its quads for
far meshes, its Horizon summary and, for full detail chunks, its cave graph with the generated
surface as its sky line), `mesh` (sections of a full detail chunk again, recomputing their graph),
`graph` (`sky`: the sky line), `horizon` (the hidden node sweep)
and `map` (tiles). Long jobs yield every `Workers.SliceBudgetMs` so actors never stall a frame,
and run one at a time per worker (the generator and mesher reuse scratch memory). Worker actors
keep their own Config, so what the player's settings change travels in each job (`foliage`,
`slice`, the reveal flags and caps).
- **Edit lane.** Jobs flagged `edit` run before every other queued job, and an edit mesh job does
  not even wait for the running job: that one lets it run at its next slice boundary (never while
  it holds the mesher's scratch memory across a slice), so an edit takes about a frame, never a
  whole generation job. `WorkerPool` sends edit jobs to the worker with the fewest edit jobs and
  gives them 2 slots beyond `Workers.JobsPerWorker`, so loading never fills them up; map tiles and
  horizon jobs may use one extra slot (`overflow`).
- **Cancelling.** `WorkerPool:cancel(ids)` (teleports, removed nodes) drops the callbacks at once;
  the worker drops a queued job and stops a running one at its next slice boundary, and answers
  `cancelled` (the slot frees then).
- **Failures** answer `failed`: a failed generation keeps the old terrain and retries, a failed
  remesh marks its sections dirty again.

### Cave visibility (`World/SectionGraph`)

Minecraft's advanced cave culling, adapted to hidden caves. Workers record, per 16³ section of a
full detail chunk, which faces its air pockets connect: a flood fill over the passable cells, done
on 16-bit rows (row y × 16 + z, bit x) instead of cells, finds the pockets, and every pair of faces
one pocket touches is connected. Only some pockets are followed: cave pockets (cave air, cave
twins); underground pockets, with no cave cell and no cell at or above its column's generated
surface (the chunk's *sky line*): air carved or dug into the ground, such as a cave entrance or a
ravine below their mouths, a dug shaft or tunnel, a cellar; sealed pockets that don't reach the
section's top (dug rooms); and in buried sections (entirely below the chunk's lowest generated
surface) all air. Sky air is at or above the sky line and always reaches the top of its section
(the terrain is a height field), so no rule follows it: the search climbs from a cave up an
entrance to the section where it meets the sky (revealed, not left), and runs from a camera in an
entrance down into the caves, but never leaks out into the sky. A section is one u32: the 15
pairs of faces connected by a followed pocket, the 6 faces a followed pocket touches, the 6 faces
any air touches (where a camera there can look out), and the CAVES and BURIED flags. Faces are
numbered like `GreedyMesher.Border`'s hidden bits (0 −X, 1 +X, 2 −Z, 3 +Z, 4 −Y, 5 +Y), so a cap
mask is a set of face bits. Graphs are only computed for the sections that may hold cave cells,
from the carver's lattice where it is conclusive: 1.5-2.3 ms a chunk in Lune (interpreted) under
hills and mountains, ~7 ms in deep caves and the Underlands.
A graph ends with its sky line (the generator's `surface`, u16 per core column: 768 bytes a chunk
in all), so `refresh` classifies dug air as the generation did. The lattice knows nothing of
surface caves, so the worker also scans each core column from `solidBelow` up to its sky line
(`dugSections`, ~0.1 ms a chunk) and reads the sections holding such air cell by cell (+0.1-0.3 ms
a chunk in all). A mineshaft's tunnels are cave pockets like any cave (cave air and cave twins,
in lattice cells marked read, `Caves.markRead`), its planks, logs and moss rock; an overgrown
one's entrance shaft is an underground pocket (Air below the sky line, found by `dugSections`
from the lowered `solidBelow`), so the search climbs it to the sky and walks down its rope into
the tunnels, as from a cave entrance's pit. From an entrance's mouth the search reaches 23-34 sections (9-10 with pockets
below the sky line not followed: it never left the mouth), at most ~200 walking down to the cave
(0.03-0.26 ms a search), 16-163 from ravine floors; following all air would reach 180-560 from the
same cameras.

The search (main thread, `search`): from the camera's section and the neighbours its air touches
(left through any face, for a camera next to a section corner), each section is visited once and
left only through a face connected to the one it was entered by, never stepping back against a
direction already taken on the path, so it doesn't wrap around behind rock. It works outwards in
8-block distance bands, nearest first, up to `reach` blocks (to section centres); past the section
`budget` the whole band where that happened is dropped, so the cut behaves like a distance and
moves little with the camera. Every section reached is revealed: one entered only through rock
still has to draw its walls facing the cave next door. Sections of full detail chunks not generated
yet come back as `pending`. Searches take a median 0.6 ms (p90 1.2 ms), at most ~3.6 ms in the
Underlands, where the 1,500-section budget cuts them (13-18 ms uncapped). `CaveReach.view` keeps
the revealed set with its hold and answers `reveals` / `capMask`; tests/spec/SectionGraph checks
the fill against a per-cell flood fill, tests/spec/CaveView the reveal and caps.

The bury line is per chunk, the sky line per column: above the bury line, dug air is followed
where it lies below the sky line or doesn't reach its section's top, so a shaft dug down from the
surface is followed up to the section where it meets the sky, and no further.

With caves always shown (the Caves setting, see Streaming) none of this runs: every full detail
section counts as revealed, and only the caps (`capsOf`, towards what is not full detail on
screen or not live yet) still close tunnels in stone.

### Far nodes behind terrain (`World/Horizon`)

Every generated node carries 64 bytes (`summarise`, made by the generator): per 4 × 4 tile of its 16
× 16 cells, the lowest terrain top (the tile is solid up to there: an occluder; terrain only) and
the highest top with trees, water and structures (an occludee). Edits update full detail chunks'
(`applyEdits`): dug ground lowers a tile's ground where nothing solid is left above it (a quarry, a
levelled hill; a tunnel under the ground leaves it, like the generated caves), and a placed block
raises its top; ground never rises again, so an occluder is never overstated (with one exception:
the summary is made from the heights before surface caves, so a pit or a ravine does not lower its
tile's ground; only sight lines along a cut's floor could be blocked wrongly, judged negligible). A
node not generated yet gets an occludee-only estimate from a generated ancestor or descendants
(`estimate`); one with neither is left out and never counts as hidden.

`evaluate` (in a worker, yielding): a front-to-back sweep from the eye over 512 compass bins, each
holding the steepest slope known to be blocked in every direction of the bin. Tiles are taken in
8-block rings: those whose nearest point lies in a ring are tested first, then those whose
farthest point lies in it raise the horizon, so an occluder always lies entirely in front of what
it hides. A tile is hidden when every bin it touches is steeper than its own steepest point, a node
when all its tiles are. The camera moves between evaluations, so a node only counts as hidden when
it is hidden from all five eyes: the camera raised 16 blocks, and four more 16 blocks to its sides;
nodes within 64 blocks never are. A test casts rays from every eye over random terrain and checks
that every hidden node really is blocked. An evaluation takes 85-180 ms in a worker; the main
thread only packs the records (0.3-0.75 ms, about once a second). Hidden shares with the default
margins: 2-7% of the parts at the spawn, 17-47% on mountain slopes, 27-35% in valleys.

### Rendering (`Rendering/`)

Every node is a Folder of section Folders. Parts come from `PartPool`: one template per
appearance, shape box (or sprite plane) and near / far / plain variant, in the look
`Rendering/TextureLooks` gives (see Texture pack), so a recycled part only needs a new size and
position. Near parts collide and can be raycast; far parts do neither and never cast shadows.
No terrain part takes part in audio collisions (`AudioCanCollide`, set under pcall).

**Builds** (`ChunkRenderer`, `RenderSchedule`). Every section build is a task in one of four
lanes: `edit` (player and server edits, first in first out, with its own `Render.EditBudgetMs`
each frame, so an edit never waits behind loading), `near` (cave reveal, plants and seams, by
priority), `normal` (generation, by node priority: the streamer's score, lower first, re-read by
`reprioritise` after each refresh) and `background` (texture restyles, skip hidden terrain giving
parts back). Parts are built out of the workspace and the budget is checked before every part.
With `Render.AutoBudget` the budget adapts (`FrameBudget`): `usual` is the shortest of the last 90
frames; a frame longer than 1.1 × that cuts the budget, which then recovers only to 90% of the
budget that overran for 120 frames; while builds wait and frames have room it grows, between 2 and
8 ms (12 ms while the player is frozen waiting for terrain); with nothing to build it drifts back
to `Render.BuildBudgetMs`. On a frame model (600 ms of building after a teleport, vsync at 60 Hz)
a fast device loads in 1.4 s instead of 2.5 s, a device with ~4 ms to spare misses 5 frames
instead of 28, and one already at 30 fps loads twice as fast at the same frame rate. The Build
Budget setting fixes it instead (`setBuildBudget`).

**In-place remesh** (`SectionDiff`). A section keeps its boxes and the parts of each box. A new
mesh is matched against the live one by the boxes' 14 bytes (position, size, look, fluid level,
tint, sparse light): identical boxes keep their parts untouched, only new boxes are built and only
removed ones go. An edit builds a median of 1 part (p90 5-8) instead of rebuilding ~300, with 2
property writes instead of ~1,000. A section with nothing on screen yet, or built in an older
look (another look generation, or plain where it no longer is), is built whole into a new folder.

**One build in waiting per section.** A section has at most one build that is not live yet, so
every build diffs against what is on screen; a newer one waits ("parked") and joins its lane when
that one goes live. A newer mesh makes an older one that has not started out of date, so when
neither has a commit group the newer one replaces it (a parked one, or the queued one while the
renderer has not started it), in the more urgent of the two lanes. A build in the same commit group
as an older one of its section drops that one (waiting behind it would deadlock the group);
meshes still go live oldest first. Restyle builds never replace a build and give way to any newer
one.

**Going live without gaps.** New parts are parented; removed parts and replaced folders, see-through
ones included, stay `Render.SwapFrames` (2) frames longer, so a part the engine draws a frame late
never shows the sky behind it. (The mesher draws a lake surface as one box, so an edit in a lake
replaces the whole surface: for those frames the old and new surfaces overlap and the water looks
darker where boxes changed.) Their PointLights go off at once, so lights never double. `clear` (a
node replaced by other levels of detail) keeps the old model the same way, and MeshOverlay keeps a
demoted mesh until the parts under it are back. Released parts are quarantined: PartPool hands
them out from the next frame on, so a part on screen at the start of a frame is never moved
elsewhere in it.

**Commit groups.** The streamer opens a group for one batch of edits (or cave sections whose caps
change together), holds it for every job that will add sections to it and releases each hold when
the job's sections were queued or the job failed. The sections are built and held ("staged") until
all are, then go live in the same frame, so an edit on a section or chunk border never shows the
old neighbour next to the new section. A group open longer than 2 s stops waiting: its staged
builds go live at once and later ones as they are staged, so a lost job can never freeze a section.

**Taking things away is budgeted.** Models and parts leave the workspace at most
`Render.UnparentPartsPerFrame` parts a frame; their parts go back to the pool or, once it is full,
a whole folder is destroyed in one call, within `Render.ReleaseBudgetMs` a frame. The pool trims
parts beyond `Render.PoolLimit` and kinds unused for 30 s the same way. `trashNode` (teleports)
drops a node without the swap delay, nearest to the destination first, and `show` never puts a
node on screen while a trashed model above or below it is still there. A far teleport that
removed 33,000-139,000 parts in one frame now takes 36-158 frames of at most 3,000 parts.
`Render.SwapPartsPerFrame` is one allowance a frame for the streamer's level of detail swaps and
the far meshes together: `show` counts the parts it puts into the workspace, and the overlay gets
what is left at the next step (it still moves its first node every frame).

**Restyle** (the settings menu). Shadow changes update PartPool's templates at once, live parts
within the build budget and pooled ones when handed out. Looks come from TextureLooks, whose
`changed` signal fires whenever they change (the Textures or Far Materials setting, averages
measured, ids that failed; see Texture pack). Each section's record keeps the look generation
its parts were made with (`PartPool:generationOf`: the plain one in plain far levels, the part
one elsewhere) and whether it was drawn plain (`Record.plain`). `looksChanged` rebuilds only the
sections where either differs from now, off-screen in the background lane, swapped like any other
build (a change of near looks alone keeps the plain levels' parts; Far Materials flips the merged
levels between plain and their far look), and also first builds that started with the old look;
only where no build waits to start (it uses the new look anyway). Any newer build replaces a
restyle, so an edit never waits behind one.

`tests/spec/RenderPipeline` runs ChunkRenderer, PartPool and MeshOverlay against fake instances
whose clock advances with every operation, with an engine drawing new parts up to `SwapFrames`
late, and checks every frame for gaps (opaque and see-through boxes, lowered water surfaces
included), doubled lights and parts reused in the frame they were released, and that any sequence
of edits ends with exactly the parts of a fresh build. Nothing of this ran in Roblox: whether the
engine really draws new parts a frame late, and what instances cost, are its assumptions.

**Textures** (the texture pack, see Texture pack below). Templates take TextureLooks' look of
their appearance: near templates its near look (the MaterialVariant in its texture's Material, the
clamped tint as Color, and Texture images such as a grass top over the grass side variant), far
templates its far look (one variant, no images), plain templates SmoothPlastic in its plain colour.
Images are children of the templates, so pooled parts keep them without extra work. With
`StudsPerTile` 3 (a block) and the Regular pattern one tile covers one block face, and since box
parts start and end on the block grid the tiles line up across boxes (if they tile from a face's
corner; `Config.Textures.OddBoxes` otherwise, see Meshing). Glow lichen's plate (its first box that
does not glow) goes see-through and carries its Front image as a Decal; the speck keeps the light,
so lit and dark templates work as before.

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
reads its tint from it. A plant with a sprite (`TextureLooks.spriteOf`: a filled Sprite texture,
Textures and `Config.Textures.Sprites` on) is drawn in full detail as two crossed planes along its
cell's diagonals instead of its boxes: `PartPool.SPRITE_BOX` templates (thin see-through parts,
`SPRITE_THICKNESS` 0.05 studs, no collision, queries, touch or shadow, the sprite as a Decal on
Front and Back), BlockSize × √2 wide and a cell tall, at the same offset and turn. Tinted ones
get their soil's tint on the Decals (`PartPool:images`), written only when the part's tint differs
(`spriteTints`). The mesher, the shapes and the Bounds that aim and outline plants are unchanged,
so a sprite is purely a drawing: 2 parts a plant instead of up to 4 boxes.

**Glow lichen's lights.** A revealed cave can hold 1,000-3,000 lichen, and a PointLight each
would be far too many. The mesher marks one lit cell per 8³ box (sparse lights, see Meshing); for
the others PartPool's `acquire(..., dark)` gives the light's box from a "dark" template, the same
part without its PointLight, so lit and unlit lichen look alike (a Neon speck). A revealed
cavern holds a few hundred lit cells (in the CaveView test scene 1,272 lichen, 343 lit), all on:
lichen should light a cave at any distance. ChunkRenderer keeps every lichen light's part and
position, so a finite `Caves.LichenLightDistance` or Lichen Lights setting
(`ViewSettings.lichenLightDistance`; default math.huge, "All") switches off those farther from the
camera on slow devices, every 0.25 s, turning them off again 8 blocks further. Lichen lights cast
no shadows: they are dim, short and many, and lichen grows only deep underground, so a glow
reaching through a thin cave wall shows nowhere it shouldn't. Each lichen is two parts, its plate
(see-through with the pack's image, see Textures) and the Neon speck that carries the light. The
renderer counts parts with a light (`lightCount`) and sparse lights (`sparseCount`, `sparseOn`; of
them lava's, `lavaCount`, `lavaOn`) for F3 ("lichen a of b, lava c of d").

**Lava's lights.** Lava (light 15: 13.5 blocks, 40.5 studs of PointLight range, no shadows) is a
sparse light too: a lava box the mesher did not mark (`GreedyMesher.fluidSurface`) comes from
PartPool's dark template, the same Neon part without its PointLight, so lit and unlit lava look
alike. ChunkRenderer keeps lava's lights apart from lichen's and switches off those beyond
`Caves.LavaLightDistance` (96 blocks, phones 48; `ViewSettings.lavaLightDistance`, no player
setting yet) the same way: in the revealed Underlands sea above, ~110 of its 209 lights are on
(~30 at 48 blocks). Far nodes carry none (`noLights`): a far lava lake is unlit Neon.

**The view from inside a fluid** (`Rendering/FluidFog`; pure but for `start`, tested in
tests/spec/LavaOilClient). Every frame after the camera, `cameraFluid` finds the fluid at the
camera (the block's fluid, any level or cave twin, when the camera is below its surface:
FluidState.getHeight, Camera.getFluidInCamera; third person counts where the camera is) and sets
Minecraft's FogRenderer fog in blocks from each fluid's record: lava 0.25..1 (spectators -8..half
the view distance), oil 0..2, fuel -8..32, water -8..96 times the water vision (`vision`: at least
0.25, building up over 600 ticks under water and dropping 10 a tick out of it, `stepVision`;
LocalPlayer.getWaterVision), never past the view distance (Roblox fog starts at 0 at the
nearest). It goes through `ViewSettings.setFluidFog` and `LightingController.setFogColour` in the
same frame: Lighting's old FogStart / FogEnd / FogColor, which Roblox only draws with no Atmosphere
in Lighting, so ViewSettings takes the Atmosphere out meanwhile and puts it back once the camera
leaves the fluid (see Lighting, Haze). The colour
is the fluid's `fogColor` (water's brightened towards its brightest hue with the vision); fluids
giving no light darken with the light around the camera (the sun's brightness times the sky light
reaching it, `light`), lava glows anyway. A ColorCorrectionEffect ("IceVoxelFluidView" in
Lighting) tints the view towards the fluid's colour (`TINT`: water 0.12, lava 0.55, oil 0.5, fuel
0.3), the sky seen through the surface too (Lighting's fog never covers the sky). Each fluid's tint and
Color3 are made once; a frame compares the fluid, the fog to a tenth of a block and the colour with
what it last wrote, in locals, and writes only changes, so a frame in an unchanging fluid makes no
garbage.

**Burning players** (`Player/BurningView`; `onFire` pure). The server marks a burning character
with the attribute `IceVoxelOnFire` (Players/Characters); polled ten times a second, every
burning character gets flames (a Fire on its root part), and the local player in first person a
fire overlay at the bottom of the screen (Minecraft's renderFlame and ScreenEffectRenderer's fire,
which in third person the body's flames replace).

**Fire** (`Rendering/FireRenderer`; the shapes and frames pure in Shared/Fire, tested in
tests/spec/Fire). The terrain draws a fire block as one invisible speck (its only shape box: Neon,
Transparency 1), which carries its light 15 as a sparse light: Fire is in GreedyMesher's
SPARSE_LIGHT_ITEMS, sharing glow lichen's 8 × 8 × 8 light boxes (one PointLight per box for both;
F3 counts them with the lichen's), so a forest fire of 300 blocks is a handful of lights. The
flames depend on the neighbours, so FireRenderer draws them apart from the mesher, the way
TransmitterRenderer draws pipe arms:
- Which fires: they only come from edits, so a chunk's are found in its edit list when its data is
  attached (ClientWorld `onChunkLoaded`, `knownEdits`) and followed through `onBlockChanged`
  (predicted breaks included), which also marks the fires next to any changed block for a new look.
  Every 0.25 s the nearest 192 within 48 blocks of the camera whose chunk is shown (the streamer's
  `shown`, as for pipes) are drawn, at most 24 (re)built a frame.
- Shapes: Minecraft's blockstates/fire.json, from `Fire.sides` (FireBlock.getStateForPlacement
  worked out on the client: 0 on the floor, else the flags of the flammable neighbours), as
  `Fire.planes`: on the floor, template_fire_floor's four planes (16 × 22.4 pixels rescaled by
  1 / cos 22.5, two pairs 0.8 pixels off the middle leaning ±22.5° across it) seen from both sides,
  plus template_fire_side's four sides as one box of the cell's size, 22.4 pixels tall, with the
  flames on its outer faces only (Minecraft's planes are seen from both sides; the far ones seen
  from inside are left out, a part and four images fewer); clinging, one plane per flammable wall
  0.01 pixels off it facing into the cell, and one under a flammable ceiling facing down. 5 parts
  and 12 images a fire on the floor, 1 and 1 per side clinging.
- Images: each face is a SurfaceGui (LightInfluence 0, Brightness 1.4: fire glows by night as
  Minecraft draws it at full brightness, which a Texture on the part, lit by the scene, would not;
  MaxDistance 48 blocks; 16 pixels a stud) holding one ImageLabel of the user's sheet
  (rbxassetid://124923986221566: 8 square frames stacked down one image, uploaded 256 × 2048),
  as wide as the face and 8 faces tall, clipped by the SurfaceGui so one frame shows, Pixelated.
  Frames are picked by position, not ImageRectOffset: Roblox shrinks images over 1024 pixels (this
  sheet is 128 × 1024 in game), so pixel rectangles from the upload's size show four frames. Parts are thin (0.05 studs), see-through, never collide or
  take queries, touches or audio collisions, cast no shadow; aiming goes by the voxel ray.
- Animation: one shared step. Every frame `Fire.frameAt(os.clock())` (2 game ticks a frame: an
  0.8 s loop; every fire in step, as Minecraft animates the one fire texture); when it changes, a
  single loop writes the new Position (`Fire.sheetPosition`: up one face height a frame) into
  every live label, a dense list kept as parts are taken and given back. 100 fires on the floor are
  1,200 writes about 10 times a second; nothing runs per fire.
- Pooling: one template per kind of plane ("double", "front", "box"), SurfaceGuis inside, cloned
  once; a fire that goes out returns its parts (600 spare at most), a new one resizes and moves
  them.
- Aim: a fire's outline is Minecraft's shape: the floor slab (BaseFireBlock.DOWN_AABB, BlockList
  `bounds`), else one box around the slabs on the walls it clings to (`Fire.outline`), which
  BlockInteraction and WAILA pass to VoxelRaycast as `Fire.outlineAt(getBlock)` (the raycast's
  `outline` gets the cell's position now); the highlight and the cracks use it too.
- Campfires (BlockList Campfire, always lit): the terrain draws the logs and the embers (a `glow`
  box carrying its own light 15, one PointLight a campfire like a lantern's), and FireRenderer
  their flames, a record like a fire's (`Fire.isFlame`): `Fire.lookAt` gives a campfire
  `CAMPFIRE_LOOK` (32, past the side flags), whose `Fire.planes` are campfire.json's two planes
  crossing diagonally (14.4 pixels rescaled by 1 / cos 45, 16 tall from a pixel up, both sides
  seen): 2 parts and 4 images on the same animated sheet. A fire turning into a campfire (one
  placed into it) keeps its record and is rebuilt with the new look. `firesNear` lists campfires
  too, so they crackle like fire (Audio/Ambience).

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
2. **Build** (builder thread, one region at a time, when the gate below allows): the members'
   quads (snapshotted when the build starts) (`Meshing/QuadMesher`, made by the workers next to
   the boxes) become mesh arrays (`Meshing/MeshGeometry`: centred, split at `MaxTriangles`, a tiny
   anchor quad when a mesh would be flat), written into the session's single scratch EditableMesh
   with the batch APIs (vertex colours via the automatically created colour ids; with unshared
   vertices the automatic normals are the face normals), baked, cleared, and turned into a
   MeshPart (Box collision, no collision/queries/touch, Precise render fidelity so the engine does
   not decimate it into cracks). Its size is checked before it is trusted.
3. **Swap**: if the members are unchanged, the MeshParts are parented, and `Render.SwapFrames`
   frames later (at least one) the members' part folders are unparented (kept). Parts of merged
   levels take the meshes' look, so both look the same: the plain look (SmoothPlastic in the
   colour each block averages to on screen, opaque water) unless Far Materials is on (below).
4. **Demote**: when a member of a mesh is removed or rebuilt, the members' parts are parented
   again and the mesh is destroyed `Render.SwapFrames` frames after the last of them, so the two
   never leave a gap. Members added to a meshed region stay parts until it is rebuilt. A failed
   build leaves the parts; failures back off per region, three in a row pause building for a
   minute, and StorageLimitExceeded / PermissionDenied switch meshes off.

**The gate.** At most one build every `BuildInterval`, never right after a hitch (a frame much
longer than usual), never while the camera's average speed over the last `SpeedWindow` (2 s) is
above `MaxBuildSpeed` (2 blocks/s: regions keep changing while it moves, and every MeshPart costs
a long frame), never while the streamer is busy and never while paused (teleport mode: a running
build stops between MeshParts, which is not a failure). Parts keep drawing meanwhile. Walking,
builds drop from ~70 to ~3 a minute (flying: 125 to 3); at the end of a 10 s stop 2% of the
regions still wait for a mesh, which is why `MinLevel` stays 2 (level 1: 20%).

Hiding and showing members count their parts against `Render.SwapPartsPerFrame`, the allowance
the streamer's swaps share (`step(allowance, used)`): a node that would go over it waits a frame,
except the first one the overlay moves in a frame, so meshes never wait forever behind the swaps.
The Far Meshes setting (`setUserEnabled`) demotes everything but keeps the quads, so switching
back on rebuilds the meshes without generating anything; it cannot switch on meshes that were off
from the start (configuration, phones, a failed probe), and the status then still gives the real
reason ("off (settings)" only while the player switched them off).

Far nodes never change once built because their borders do not depend on their neighbours
(`generator.farSeamLimits`): the LOD tree is 2:1 balanced, so a node is meshed as if every side had
a one or a two levels coarser neighbour, which costs ~2% more boxes and ~1% more triangles. Full
detail chunks keep exact seams (and are never merged: they need exact collision, edits and caves).

A startup probe a few seconds after joining (an off-centre block, a flat sheet, and a full-size
mesh timed against the usual frame time, up to three tries) decides whether meshes are used at
all; when they are not, far parts keep their normal look. The block is timed the same way
(`usualFrame`, the mean of 30 frames, and `timedMesh`, the slowest Heartbeat during the build
over it: `tinyFrameMs`, what a region's small looks cost), then built again in a look (Slate,
UVs, Material and MaterialVariant written, as Far Materials builds); when that fails, meshes
stay on but plain (`dropLooks`, below). Meshes in the world are capped at `MaxLiveTriangles`. Far
meshes keep the sea floor: near water is transparent, so looking through it across into a merged
region must find the same ground the parts had. F3 shows the status and counters (with Far
Materials, "N parts (M with materials)": MeshParts in a look other than plain).

**Looks (Far Materials).** A MeshPart has one Material and one MaterialVariant, so materials need
one MeshPart per look. ChunkRenderer gives the overlay TextureLooks' callbacks with
`setLooks(enabled, lookOf, lookInfo, plainOf)`, at start and whenever `changed.meshes`:
- `lookOf(appearance, face)`: a quad's look id (`MeshGeometry.PLAIN` = 0) and vertex colour;
- `lookInfo(id)`: the look's material, variant, transparency, reflectance and its texture's
  average (sRGB 0..1, when known);
- `plainOf` (`TextureLooks.plainRgb`): what a face averages to on screen.

Off (the default): `plainLevel` is true for merged levels and every mesh is one plain look in the
plain colours, the meshes of before with calibrated colours. On (`looks`: the setting, unless the
probe dropped them): `plainLevel` is false, the merged levels' parts take their far look, and
MeshGeometry groups each region's quads by look (`Options`):
- looks are ranked by the area they cover; those covering at least `LookMinShare` (5%) keep
  meshes of their own, at most `MaxLooks` (4), the largest;
- every other quad is recoloured to its plain colour: `LookRemainder = "plain"` draws it in the
  plain look; `"largest"` adds it to the largest kept look that is opaque (plain when none is),
  tinted so that look's texture averages to the plain colour (`MeshGeometry.tint`: plain colour /
  look average per channel in linear light, at most 1; the plain colour itself when the average is
  unknown). Its own vertex colour would be a tint meant for its own texture: a Tint false ore's
  white, shown on stone's texture;
- meshes go by look (ascending ids), then band, under the same triangle cap; with one look the
  meshes are exactly those without looks, plus colours;
- textured looks get box-mapped UVs from world studs, `UvStuds` per tile from a corner snapped to
  a whole tile (u to the right and v down seen from outside the face; tops and bottoms on X and Z),
  so tile edges fall on block edges at every level and across meshes;
- each MeshPart takes its look's Material, MaterialVariant, Transparency and Reflectance, a white
  Color (the vertex colours tint it) and no shadow when see-through.

A change of looks bumps `lookGen`: the running build stops, a build that finishes in old looks is
dropped (not a failure), every mesh is demoted, ChunkRenderer restyles the sections whose
generation or plain flag is out of date, and a region is merged again only once every member's
parts carry the current look (`isCurrent`, set by ChunkRenderer), so a mesh is never built from
parts about to be restyled. `dropLooks` (the probe's mesh in a look failed) sets `lookable` false,
warns once ("[IceVoxel] Far Materials off: ... (far meshes stay plain)"), applies `setLooks` again
with Far Materials off whatever the setting, and when that changed `plainLevel`'s answer calls
`onLooks`, which ChunkRenderer answers by restyling the merged levels. Cost: 2-5 meshes per region
instead of 1-2; a 1,616-quad region builds in 4.0 ms instead of 2.9 (native; 6.7 instead of 5.9
interpreted). Unchecked in Studio: whether a MeshPart's material follows the written UVs (and their
scale and signs), and whether vertex colours tint it.

### Map (`Map/`)

Map tiles are painted from the generator, not from loaded chunks, so the map shows the whole
(infinite) world. `Map/MapPainter` (shared, pure) runs inside the worker actors as a `map` job and
returns RGBA pixels: surface colour, hill shading from the neighbouring heights, tree density,
water depth and sea ice. It paints from column data, so cave entrances and ravines don't show.
Oil wells' geysers are painted over it as black dots in the oil's colour (`paintWells`, from
`generator.oilWells`: the pixel holding the spout and every pixel whose centre lies within the
lake's radius, not the lake's exact shape); a tile has a few wells at most, and the dots add
nothing measurable. Water lakes (at up to 8 blocks a pixel) and puddles (up to 2) are painted as
water where a pixel's centre column holds theirs (`paintLakes`, from `generator.waterLakes` and
`generator.puddles`); further out they would be a pixel or less.

Roblox re-uploads only one displayed EditableImage per frame, so each map is a single
EditableImage used as a ring buffer (`Map/MapLayer`): tile `(tx, tz)` lives in slot
`(tx mod n, tz mod n)`; tiles entering the view take over the slots of tiles that left it and are
painted closest-first. `Map/MapView` shows a window of the ring with up to four ImageLabels (one per
wrapped piece) sharing the same image. The minimap uses a 256² image, the world map an 832² one
(~3 MB together). Creating an EditableImage throws when the experience has not enabled the API and
returns nil when the memory budget is used up; the maps then show markers only.

The weather mode (see Weather) lays a small EditableImage of its own over each map (48² and 96²,
~45 KB together), painted rarely and a band a frame.

Tile jobs share the workers with terrain: they may use the pool's overflow slot, and wait while
teleport mode lasts (the first load too: `Map.setPaused`). While the Minimap setting hides the
minimap (`Map.setMinimapVisible`) it neither draws nor asks for tiles; on touch screens a small
"Map" button then takes its corner, as tapping the minimap is the only way to the world map there.

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
  opens it, in every game mode, unless sneaking with an item in hand. Adventure and spectator
  players do nothing else with blocks (see Game modes: On the client).
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
  its screen (Structure blocks and jigsaw structures, below) or a refusal; in the other modes they
  are plain blocks, and their items are not placed. A jigsaw's orientation comes from
  `Blocks.placementFor` (Minecraft's JigsawBlock.getStateForPlacement, `Blocks.jigsawPlacement`):
  the front faces out of the clicked face; a horizontal front has its top Up, a vertical one the
  opposite of the player's horizontal facing (`Blocks.horizontalFacing`, Direction.fromYRot). The
  structure block's item places SAVE mode (Minecraft places DATA), and glow lichen, like a torch,
  the variant on the clicked face's side.
- Middle click picks the block (Minecraft's pick block), `Q` drops the held item (`Ctrl`: the
  stack). On touch screens a tap uses or places and holding breaks.
- The mouse buttons and keys here are the key bindings Attack/Destroy, Use Item/Place Block,
  Pick Block and Drop Selected Item (`Keybinds.matches`, each on its own, so an input bound to
  two actions does both, as Minecraft's). A use bound to the right button with a free mouse keeps
  the short-click rule (Roblox's camera turns on a right drag); bound to anything else it repeats
  while held. The debug key held (the Debug Screen binding) keeps the drop key from dropping (its
  `+ Q` is the debug list). Each attack sent starts the attack indicator's recovery
  (`Ui/AttackIndicator.attacked`).

### WAILA (`Ui/Waila`, `Ui/WailaInfo`)

A panel at the top centre names what the crosshair points at, like the Jade mod.

- **Light level.** Blocks and fluids carry a "Light level N" line (`WailaInfo.lightLine`, context
  `light`): the light of the cell a mob would stand in (above an opaque block, else the block's
  own cell), the larger of its block light (`Shared/World/LightEstimate.blockLight`: sources less
  one per open cell they travel, budgeted; the server's mob spawning uses the same) and sky light
  (`LightingController.skyLight`, SkyExposure's estimate), since the engine keeps no light map.
  It is worked out at every pick (0.05 s) and is part of the panel's key, so a torch placed nearby
  updates it. Coloured for Minecraft 1.18+'s monster spawning (block light 0): red with sky light
  at most 7, yellow above (night only), green lit; F3 adds "(block b, sky s)".

- **Target.** `BlockInteraction.target()`: the highlighted block, with the same reach and rules
  (outlines included; a fire's from the walls it clings to, `Fire.outlineAt`; it is named "Fire"
  with a colour box for an icon, as it is no item). A dropped item (`EntityRenderer.itemsNear`, a 0.5 × 0.8 block box around
  its bobbing model) or another player (their standing hull) nearer on the same aim and in reach
  wins, except while mining (`BlockInteraction.miningProgress()`), so the progress stays on
  screen; an entity behind a block is never named, even when that block is too far to target
  (WAILA casts BlockInteraction's ray without its reach check). A fluid (water, lava, oil, fuel)
  shows only when no block is in reach: BlockInteraction aims and mines through fluids, so WAILA
  must not hide the highlighted block. The fluid ray skips the fluid the camera starts in. The rule
  is `WailaInfo.choose` (tested). Items, players, fluids and the hiding block are looked for every
  0.05 s; touch screens aim with a finger only while breaking, so they show blocks only. Spectators
  are never named, nor the player being spectated; a spectator sees blocks with a menu and players
  only (see Game modes: On the client).
- **Content.** `WailaInfo` (pure, tested) turns (block, held item, x, y, z, extended) into an icon
  (the item's 3D icon; a colour box for blocks that are no item; a player's head shot) and lines
  of coloured segments:
  - the name (a chest adds "(27 slots)"; contents are only known while it is open; a fluid is
    named by its fluid, "Lava" for every level and for CaveLava);
  - "Light 15" for a fluid that gives light (`fluidLight`: lava lights its surroundings, though
    only some of its cells carry a light);
  - the harvest line from `Items.canHarvest` and the block's `tool` / `toolLevel`:
    "✔ Requires Stone Pickaxe", "✘ ...", "✔ Tool: Axe" or "Unbreakable"; operator blocks say
    "Creative only" instead (F3: "Breaks in creative only (at once)"); lit TNT and Nukes (which
    can't be broken) "Lit: stand back!" in red instead;
  - explosives: "Explosive: power 4" (TNT), "Explosive: 24 block crater" (the Nuke), in gold
    (`explosiveLine`);
  - a structure block's mode and name ("Mode: Save", "Name: hut"; a DATA block its marker) and a
    jigsaw's name, target and pool, from the records Net/StructureNet keeps (F3 adds a structure
    block's region and, in LOAD mode, its rotation, mirror, integrity and seed);
  - while the F3 overlay is open (`DebugOverlay.isOpen()`), gray lines: `Stone #3`, position, chunk
    (floored, with the local column), biome (`generator.column`), hardness, tool kind and level,
    drops with the held item and by hand (`Items.drops`; a tall plant's top shows its lower half's,
    which breaking either half harvests), break time (`Mining.ticks / 20`, standing and dry, at the
    player's own speed: the context's `miningFactor`, Mining.playerFactor of the effects' levels,
    the perks and the held item, as BlockInteraction mines), light (`Blocks.light`), fluid level,
    render kind, solidity, friction, menu;
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
  it, it goes over the minimap's corner, as far left as it can. It keeps clear of that corner only
  while the minimap shows (`setMinimapShown`, the Minimap setting).
- **Setting.** With the WAILA setting off (`setEnabled`) the panel is hidden and nothing is picked.
- **Updates.** Every frame builds a short key (target, held item, F3) and rebuilds the text only
  when it changes, at most once a tick (0.05 s); hiding keeps the text, so a target flickering on
  and off is shown again without a rebuild. Progress only resizes its line. The panel hides while
  a screen is open, while the HUD is hidden (the world map) and with nothing aimed at.

The F3 overlay also shows the time: clock, day number, tick, sky light and how much of it reaches
the camera (`LightingController.dayTime`, `skyExposure`); the fog showing (`describeFog`: the
Atmosphere's density, how far it hazes things 90%, haze, glare and offset, or a fluid's or
Blindness' fog in blocks); the PointLights in the world (lichen
and lava lights: on of all); the cave view (how far caves are revealed, the level 1 split in
use); and the hull's flags, `lava` among them.

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
  - Reads input: on a keyboard and mouse (`Keybinds.usingKeys`: a keyboard, and Roblox's last
    input no gamepad or touch) the key bindings Walk Forwards / Backwards, Strafe Left / Right
    and Jump held (`Keybinds.isDown`, nothing while typing), so the control scripts' own W A S D,
    arrows and Space move nothing once rebound; otherwise the default control scripts' move
    vector (`PlayerModule` `GetMoveVector`: gamepad sticks, the touch thumbstick) and
    `Humanoid.Jump`. It turns that by the camera the way the `ControlModule` does, and leaves
    keyboard diagonals longer than 1 so diagonal sprinting works as in Minecraft.
    `Humanoid.MoveDirection` is the fallback. Jump is latched between ticks so short taps count.
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
    top of the FOV setting (`setFieldOfView`; without one, whatever the field of view is set to),
    the modifier scaled towards 1 by the FOV Effects setting (`setFovEffects`).

  Other duties:
  - Sprint and sneak are `ContextActionService` actions at High priority that sink their keys, so
    Left Shift no longer toggles shift lock (Right Shift still does). Their keys are the Sprint
    and Sneak key bindings plus `Config.Movement`'s gamepad buttons; a changed binding binds the
    action again (`Keybinds.changed`). With `ToggleSprint` (the Sprint setting), the sprint key
    turns sprinting on and off; turning it off also stops a sprint started by double tapping.
    `ToggleSneak` (the Sneak setting, Hold by default as Minecraft's) does the same for sneaking
    (never from a shift click in a screen). Switching either setting lets go of whatever the old
    mode latched (`followSprintMode`, `followSneakMode`), so a sprint can always be stopped.
    While a screen (inventory) or the game mode switcher is open, the input is neutral.
  - View bobbing and the hurt tilt (`Player/ViewBob`, pure, tested in tests/spec/Keybinds):
    Minecraft's `GameRenderer.bobView` (walk distance 0.6 a block, the bob easing 0.4 a tick to
    the speed a tick, at most 0.1, on the ground only: 0.05 blocks sideways, 0.1 down, 0.3° of
    roll, 0.5° of pitch while walking) and `bobHurt` (−sin(t⁴π) × 14° over the 10 ticks after
    health drops, times Damage Tilt). The camera moves by the view's inverse at
    `Camera + 4` (after ExplosionView, FluidFog and EffectView) and the move comes off again
    (`unbob`, only if nothing else moved the camera) at the start of the next frame's movement
    step, before Roblox's camera reads its own look vector, so the pitch never accumulates.
  - The hull stays frozen until the chunk under it and the eight around it are shown, and after
    teleports (meanwhile the renderer may build longer per frame: `ChunkStreamer.setFrozen`).
    Server teleports arrive as attributes and are passed on to the streamer at once
    (`ChunkStreamer.teleported`, teleport mode); other scripts moving the character far are
    detected and followed.
  - The `Physics` state never dies by itself, so health ≤ 0 puts the Humanoid into `Dead`. On death
    the rig is released: its parts go back to Default, the forces and the camera offset are removed.
  - Explosions push the hull: `knockback(kx, ky, kz)` (the server's Explosion message, through
    `Rendering/ExplosionView`) adds the push to the hull's velocity with
    `PlayerPhysics.knockback`, as Minecraft's client adds the explosion packet's knockback; not
    while frozen or following someone, nor for spectators (`noClip`) or a player in flight who may
    fly (Minecraft's server leaves creative flight out of the packet's knockback).
- **`Player/CharacterAnimator`** replaces the `Animate` script, which needs Humanoid states the
  character never enters. It loads the avatar's own animation ids from `Animate`, falling back to
  Roblox's defaults. It uses the script's rules:
  - R15 walk / run blend by `speed / 16 × 1.25 / heightScale`;
  - idle below 0.75 × height scale;
  - jump for 0.31 s, then fall;
  - swim at `speed / 10`;
  - climb (on a ladder, vine or rope off the ground: the hull's `climbing`) at the vertical speed
    / 5 (R15, over the height scale) or / 12 (R6) in studs a second, from the controller's
    `climbSpeed`; backwards sliding down, still when holding on, at most 3;
  - fades of 0.2 / 0.1 / 0.4 s;
  - Core priority for movement tracks, Idle for `toolnone`.

**Creative flight** (`PlayerPhysics`, Minecraft 1.20.1 tick for tick). Creative players `mayFly`.
A second jump press within 7 ticks toggles flying. While flying (and unaffected by water, like
Minecraft's flying player):
- jump / sneak add ±3 × the flying speed (0.15) to the vertical speed;
- horizontal acceleration is the flying speed, `State.flyingSpeed` (Abilities.flyingSpeed, a
  float: 0.05; × 2 sprinting);
- afterwards the vertical speed is the one from before the move × 0.6, so it settles at 0.375 blocks
  per tick (7.5 m/s); horizontally 10.9 m/s, 21.8 sprinting;
- no crouching, no edge back-off; landing stops it;
- players who may fly take no fall damage. The field of view widens by 1.1 in flight (× 1.15 when
  also sprinting).

**Spectators** (`State.noClip`, Minecraft's `noPhysics`) always fly and move straight where their
velocity takes them: no collision, never on the ground, no fall distance or landings, no water,
swimming or currents, no pushing out of blocks, always standing. Double tapping jump does nothing,
and sprinting (× 2) starts only with the sprint key: Minecraft starts a sprint by double tapping
only on the ground or under water. The mouse wheel changes the flying speed by 0.005 between 0 and
0.2 while the spectator menu is closed (`scrollFlyingSpeed`, MouseHandler.onScroll), and every game
mode change sets it back to 0.05, as Minecraft's abilities packet does. Only the height is limited:
from the bottom of the world (`NO_CLIP_MIN_Y`, 0: below it everything is bedrock, there is no void)
to 64 blocks above its top (`NO_CLIP_MAX_Y`). `setGameMode(state, mode)` applies a mode's abilities
(MovementController calls it when the hull is made and whenever the mode attribute changes):
spectator flies at once, creative keeps flying as it was (from spectator too), survival and
adventure stop flying and fall. `PlayerPhysics.isInWall` is Minecraft's in-wall test, which the
server uses for suffocation (see Game modes: On the server).

**Ladders, vines and rope** (`PlayerPhysics`, LivingEntity 1.20.1 tick for tick; the numbers are
pinned by tests/spec/Climbing). The player climbs while the feet cell (`floor` of the position,
`blockPosition`) holds a block `Blocks.isClimbable` names (ladders, vines and their cave twins,
rope; Minecraft's `#climbable`); spectators never climb. In the normal travel branch,
`handleOnClimbable` runs after the acceleration and before the move: the fall distance is cleared,
the sideways speed held to ±0.15F a tick and the descent to −0.15F, and sneaking (`state.sneaking`,
`isSuppressingSlidingDownLadder`) turns a descent into 0. After the move, a horizontal collision
or a held jump on a climbable sets the vertical speed to 0.2, which the gravity and drag line turns
into (0.2 − 0.08) × 0.98 = 0.1176 blocks a tick, 2.35 m/s up; letting go settles at 0.15 a tick
down (3 m/s). Jump is what climbs a free-hanging rope or vine: there is no wall to push against.
Rope follows Supplementaries' `LivingEntityMixin` (`slide_on_fall`): its descent is not limited,
a free fall, but the fall distance is still cleared before every move, so a slide of any length
lands without damage (fall damage is the client's `events.damage`, sent as a Fall message: the
server needs nothing). In water the water branch adds Minecraft's climb out: a horizontal
collision on a climbable sets 0.2 before the water's drag (0.155 a tick). Lava has no climbing;
creative flight runs the clamps and then restores its own vertical speed as before. The ledge at
the top is stepped onto because the feet leave the ladder's top cell above the wall's top while
still rising. `climbing` (after the tick) feeds the sounds, the animator and F3.

**Cobwebs** (`Entity.makeStuckInBlock`). After every move the cells the hull overlaps, deflated by
1e-7 (`checkInsideBlocks`), are looked up in `Blocks.stuckLut`; a hit stores the block's
`stuck` multiplier (cobwebs and their twin: 0.25, 0.05, 0.25) in `state.stuck` and clears the fall
distance. The next local `move` multiplies its movement by it before the edge back-off and the
collision, clears it and zeroes the velocity, so nothing builds up: 0.49 m/s walking (a quarter
of one tick's push), 0.004 blocks a tick falling. It works in every branch (water, lava, flight)
but never for spectators (`moveNoClip`). Teleports (`place`) and game mode changes forget it.

**Mobs** (`Entities/MobPhysics`) use the same rules: a mob whose feet cell is climbable gets the
clamps before its move (rope: no descent limit) and 0.2 after it when it walked into something or
its AI jumped, so a zombie that walks into a ladder climbs it at 0.1176 a tick; they never seek one
out. Spiders keep their own wall climbing (`climbs`: Spider.onClimbable is its wall flag) and are
not slowed by webs (Spider.makeStuckInBlock does nothing); every other mob is.

**Using rope** (`Shared/Rope`, pure; server `Players/ItemUse`; client
`Interaction/BlockInteraction`). Supplementaries' `RopeHelper`: Rope used (not sneaking) on any rope of a column walks down the
column (`bottom`) and places one Rope under it (`extendTarget`: a loaded, replaceable cell without
fluid, y ≥ 1), using one item (none in creative), with the rope's place sound at × 0.8 pitch; an
empty hand on a rope with a rope above or below removes the column's bottom rope (`pullTarget`) and
gives it back (nothing in creative), with its break sound at × 0.6. `Rope.use` returns the hand's
new stack, the stack given and the sound; ItemUse runs it after its usual checks (reach on the
clicked rope, `GameModeRules.mayUseItemOn`, the use budget, the held stack) through
`world:setBlock`, so the edits are recorded and replicated like any other. The client sends a
UseItem for exactly the clicks `Rope.wantsUse` names (Rope or an empty hand on a rope, not
sneaking, in survival or creative), unpredicted and repeated while the button is held. A rope cut
anywhere comes down a block a tick through `Behaviours/Attached` (`Blocks.canSurvive`'s chain
rule), each rope dropping itself. `SpawnUnsafeBlocks` keeps spawns out of cobwebs.

**Sounds of climbing** (`Audio/SoundRules.move`, `Audio/MovementSounds`; Entity.move). While the
hull climbs off the ground (`Motion.climbing`), the vertical movement counts toward the step
distance (the 3D distance × 0.6) and the step plays in the air: the block under the feet
(`floor(y − 0.2)`) when it is climbable, its own sound type (ladder, vine, rope), about every
1.67 blocks climbed, sneaking or not (only flying, and sneaking on the ground, are silent). Over
the floor below a ladder's bottom rung the step passes without a sound, as Minecraft's second
`vibrationAndSoundEffectsFromBlock` call does. `observe` reports other characters climbing when
their feet are in a climbable cell and they do not stand.

**Fluids and the player.**
- `World/FluidFlow` is Minecraft's `getFlow`. It takes the height differences to the neighbours,
  treats an open side with the same fluid below it as a drop, and makes falling fluid next to a
  solid face push almost straight down. `PlayerPhysics` pushes the hull along it at the fluid's
  `push` per tick (Shared/Fluids: water and fuel 0.014, lava and oil 0.0023333).
- Each fluid moves the player by its record (`physics`, `drag`, `push`, `swim`), in Minecraft's
  two tags: "water" (water, fuel: the water branch of LivingEntity.travel, `inWater`, swimming)
  and "lava" (lava, oil: `inLava`, `lavaHeight`). The lava branch: acceleration 0.02, then drag 0.5
  every way while the fluid is deeper than 0.4 (the jump threshold), else 0.5 sideways and 0.8 up
  and down with water's slow sinking; gravity / 4 on top; jumping rises 0.04 a tick
  (jumpInLiquid), the same hop out onto a ledge, no swimming and no sinking by sneaking, and the
  fall distance halves every tick in it (Entity.baseTick). That is 0.78 blocks a second walking,
  40% of water's; a 25-block fall into 2-deep lava costs 9 half hearts against 21 on stone. The
  water tag is looked at first, as in Minecraft, when the player touches both. `eyeFluid` is the
  fluid at the eyes (Entity.updateFluidOnEyes). CharacterAnimator walks (it doesn't swim) while
  the hull wades through lava or oil.
- Water spreads like Minecraft's `FlowingFluid.getSpread` (`Behaviours/Fluid`): sideways only
  towards the side(s) with the shortest way to a hole. The search follows open blocks for up to 4
  blocks past the neighbour, so holes up to 5 blocks away count; it is a breadth-first search with
  each block read once. A search that reaches an unloaded chunk waits for it. A pool of sources
  pouring into a hole keeps spreading at its edge. So water runs down slopes the way it does in
  Minecraft instead of flooding the ground around it. Lava, oil and fuel spread the same way with
  their own slope distance (see Fluids: lava and oil look for holes up to 3 blocks away).

## Texture pack (`TexturePack`, `Blocks`, `tests/build_textures`, client `Rendering/TextureLooks`)

The user's textures go from one hand-edited module to every part, image and mesh:

```
Shared/TexturePack ─► Blocks (faces per block, appearances, variantTexture, alignLut)
   │                  ├─► GreedyMesher (odd boxes)
   │                  └─► Rendering/TextureLooks ─► PartPool, ChunkRenderer (parts, sprites)
   │                                             ─► MeshOverlay (far mesh looks)
   │                                             ─► ItemModels, ItemIcon (items)
   ▼
tests/build_textures ─► src/textures/*.model.json ─► Rojo 7.7.1 ─► MaterialService.IceVoxel,
                                                                   ReplicatedStorage.IceVoxelTextures
                                     (the variants and prototypes TextureLooks draws with)
```

**The pack** (`Shared/TexturePack`): pure data that requires nothing, so the server, clients,
worker Actors and Lune all load it, and it is the only place textures are set (BlockList's old
`texture`, `tint` and `faces` fields are gone). `Textures` maps a name (lower case with spaces, as
Minecraft names them) to a colour map (`""` until made), optional normal, roughness and metalness
maps, the `Material` its MaterialVariant is based on, `Tint` (true, the default: the drawn block's
voxel colour; false: the image's own; a block name: that block's colour), `Average` and `Align`.
`Blocks` maps a block name to its faces (`All`, `Sides`, `Top`, `Bottom`, `Front`, `Sprite`).
`StudsPerTile` is 3 (a block face), `ShowMissing` swaps blank textures for `Missing`.

**Resolution** (`Blocks`, when it loads). Every def gets `textures` (`TextureFaces`: `top`,
`bottom`, `north`, `south`, `east`, `west`, `front`, `sprite`, texture names, blank ones too; nil
for blocks never textured): a face given nothing falls back to All, then Sides. A cave twin shares
its twin's table (twins must look alike, so they never have entries); a block without an entry
takes its variant group's (the base's, else the first member listed with one: the six glow lichen
sides, tall plants' tops). The eight names are part of the appearance key, so blocks with
different textures never share an appearance (still 157 appearances, numbered as before). Each
appearance gets `textures`, `textured` (a face is filled, or ShowMissing with a filled missing
texture) and `sprite`. The pack is checked as Blocks loads, failing with a message that names the
mistake (`TexturePack: ...`): unknown blocks, faces, textures or tint blocks; entries for twins,
fluids or undrawn blocks; empty entries; materials that cannot take a variant
(`VARIANT_MATERIALS`, a list because Lune has no Enum: all but Neon, Glass, ForceField, Air and
Water). Lookups: `textureFaces`, `textureOf`, `textureFilled`, `variantName` (`"IV_"` and the name
with spaces as `_`), `texturesUsed`, `textureUsers`, and two rules everything else follows:
- `variantTexture(appearance)`: the texture whose MaterialVariant a cube's parts take at full
  detail (a part has one variant on all six faces): the sides' when filled; else the top's when
  the bottom has no other filled texture; else the missing texture with ShowMissing; none for
  plants and lichen. With `Config.Textures.SideImages` a filled top that differs from the sides
  comes first (the sides are images then).
- `alignLut`: 1 per appearance that is an opaque, merged (not `single`), unshaped cube whose
  `variantTexture` is filled and not `Align = false` (34 today: every textured opaque cube but the
  leaves), the odd-box rule's input (see Meshing). Images tile from a face's corner, so they need
  nothing.

All of this adds about 1.5 ms to Blocks' load time (interpreted).

**The generator** (`tests/build_textures`, its logic in `tests/lib/TextureBuild` so a spec can
run it). Game scripts cannot set a MaterialVariant's maps or BaseMaterial, nor a Texture's normal,
roughness and metalness maps (PluginSecurity), so they are made at edit time, as two committed Rojo
model files:
- `src/textures/Materials.model.json`, mapped to `MaterialService.IceVoxel`: a MaterialVariant
  `IV_<name>` per filled texture with BaseMaterial, its maps (`ColorMapContent`...), StudsPerTile 3
  and MaterialPattern Regular, never AlphaMode (MaterialVariant cut-outs are not live on clients,
  so block textures are opaque);
- `src/textures/Images.model.json`, mapped to `ReplicatedStorage.IceVoxelTextures`: a Texture
  prototype of the same name with TextureContent, its maps and StudsPerTileU / V, which the client
  clones for images, sprites and item cubes because a clone keeps the maps scripts cannot set.

Content properties are plain strings and never `""` (Rojo would store an empty Uri), which needs
Rojo 7.7 (7.4 knows none of them; `rokit.toml` pins 7.7.1). Rojo owns only the IceVoxel folder, so
variants made by hand elsewhere in MaterialService stay. The output is deterministic (sorted names
and keys, tabs, one property per line), so `--check` and the TexturePack spec compare text (CRLF
read as LF). It refuses bad ids, unknown fields and bad averages; warns about a normal map equal
to its colour map and filled textures no block uses; notes the filled textures without an Average
(`unmeasured`, `--list`).

**Looks** (`Rendering/TextureLooks`, the one place that decides them, so near, far, plain, meshed
and item looks agree; its maths is pure, and Instances appear only in `newImage`, `newDecal`,
`start` and the MaterialService lookup). A part shows `ColorMap × Color`, and `BasePart.Color` is
8 bits a channel, so a part's tint can only darken; `Texture` and `Decal.Color3` are not clamped.
In linear light:
- `tintOf`: target / average per channel (the target is the Tint's colour; none for Tint false:
  white), clamped to 1 on parts, not on images; with an unknown average the target itself (a
  plain multiply);
- `averageOf`: what a face shows on screen, average × tint where the average is known, else the
  target (the voxel colour for Tint false or a face without a texture);
- `shortfall`: how far below its target a part's clamped texture shows. Above `CLAMP_VISIBLE`
  (4 of 255) an opaque block keeps the variant but adds the texture as images (unclamped tint) on
  every face still showing it, and its far look becomes plain; a see-through block draws it darker
  (images would hide what is behind). One sorted warning lists them whenever the list changes.

Per appearance, cached until the next change:
- near (full detail): `variantTexture`'s variant in its texture's Material, Color = its clamped
  tint, plus a Texture image (3 studs a tile, unclamped tint) on the top when it draws another
  texture, on the bottom with `BottomFaces`, on the sides with `SideImages`; nothing drawable: nil,
  the BlockList look;
- far (levels >= 1 not plain): one variant, no images: the top's texture, else the sides' (tops
  dominate from afar); the plain look when too dark;
- plain: SmoothPlastic in what the top averages to (`plainColour`);
- sprite (`Config.Textures.Sprites`): the texture and its Decal colours per foliage tint (target
  × `FOLIAGE_TINTS[t]`, clamped like the boxes' colours, / average);
- front (glow lichen, ladders, rails, vines): one Decal on the plate's face away from the support
  (Down: Top, Up: Bottom, North: Back, South: Front, West: Right, East: Left);
- shapes (`drawnBoxes`, `shapeLook`): see textured shapes below;
- item cube faces: an image per face that draws a texture;
- far mesh look (`lookOf`, `lookInfo`, `plainRgb`): with Far Materials the far look (material +
  variant + transparency + reflectance; one per appearance, as a far part has one variant) and the
  far part's Color as vertex colour, or the BlockList material in the voxel colour; without it the
  plain look in the plain colour.

**Textured shapes.** A shaped block can carry a texture three ways: a Sprite (two crossed planes
instead of its boxes: plants, rope, cobwebs, hanging roots), a Front image on its plate (the first
box that does not glow), or its entry's cube faces. Two rules make filled textures look right:
- *A Front replaces the boxes* (`drawnBoxes`, from the pure `drawnBoxesOf(shape, transparency,
  front)`): when the plate draws a Front image, ChunkRenderer builds only the plate (see-through,
  with its Decal) and the glowing boxes, so a ladder's rails and rungs and a rail's iron bars give
  way to the picture, like Minecraft's single textured quad. Without one, every box is built but a
  plate that is fully see-through (transparency 1: the ladder's image carrier, which would show
  nothing). Plain parts carry no images, so they keep the boxes. Glow lichen has only its plate
  and its glowing box, so it looks as before. ItemModels follows the same list for item icons.
- *Shaped boxes take the near look* (`shapeLook`): a shaped block whose entry has cube faces (All,
  Sides, Top) draws its boxes at full detail in that texture's MaterialVariant, material and tint
  (`Blocks.variantTexture`, as a cube's near look, without images); glowing boxes stay Neon, far
  boxes keep their colours. That dresses the oak fence post in planks and the moss carpet in moss
  block. PartPool applies it per template; both rules are part of the looks' signatures, so a
  filled texture or the Textures setting restyles them like any look.

`drawable` turns a blank texture (with ShowMissing), a failed id or a variant missing from
MaterialService (`GetMaterialVariant`, warned once with the fix) into the missing texture, and that
into nothing (the block's own look) when the missing texture cannot be drawn either. Images clone
the prototypes, else are new Textures from the colour map.

**Startup** (`start`, called before `ChunkRenderer.new`; in the background, never in the first
frame). With `Config.Textures.ValidateIds` every filled id of every map is preloaded once through
temporary Decals (`ContentProvider:PreloadAsync`; a MaterialVariant cannot be preloaded): a failed
colour map marks its texture failed (`applyFailed`: drawn as the missing texture), and every
failure is warned with the texture, the map and the likely cause (a Decal id), for a colour map
also its blocks and the fallback drawn instead. With `MeasureAverages` every texture without an
Average (the missing texture only when something draws it) is measured one image at a time:
`CreateEditableImageAsync`, `ReadPixelsBuffer`, every 8th texel each way, the alpha-weighted mean
in linear light (`averagePixels`), `Destroy`; up to 3 tries a second apart while the editable
memory budget (shared with far meshes) is full, stopping after 3 failures in a row. The averages are printed ready to paste (`formatAverages`)
and applied (`applyAverages`); failures are warned by cause (refused: the Mesh / Image APIs or
ownership; the budget; a transparent image; not tried). Until then looks are provisional.

**Generations and restyles.** `change` snapshots every appearance's look signatures around an
edit of the state (`setStyle`: the Textures and Far Materials settings; `applyAverages`;
`applyFailed`) and bumps only what differs: `partGeneration` (near and far looks, sprites,
lichen), `plainGeneration` (plain colours) and `generation`. `changed` fires with `Changes`
(`parts`, `plain`, `meshes`: plain colours changed, Far Materials toggled, or part looks changed
with it on; `items`), and `itemsChanged` only when item looks changed, so Far Materials alone
rebuilds no item.
- PartPool keys templates by generation (plain templates by the plain one, the rest by the part
  one), so parts of an old look are never handed out again; `syncLooks` takes the new generations
  and destroys the old templates (castRule, litKeys and sparseKeys stay: parts of old keys may
  still be on screen, and refresh and release read them), and `trim` the old pooled parts.
- ChunkRenderer rebuilds what changed (see Rendering, Restyle), calls `MeshOverlay:setLooks` when
  `meshes`, and answers `overlay.isCurrent` and `overlay.onLooks` (see Far meshes).
- ItemModels drops its cached prototypes on `itemsChanged` and counts `generation()`; ItemIcon
  drops its spare models and marks every live icon stale (hidden screens' too), building them
  again within 1 ms a frame (`REBUILD_BUDGET`). Held, dropped and transported items keep their
  model until their item changes.

**Items** (`Rendering/ItemModels`). A cube with textures is a bare template (`PartPool.makeTemplate`
with `bare`: the BlockList material and colour) with one Texture per face that draws one, its
StudsPerTile the cube's size so one tile spans the face (a variant would tile every 3 studs
whatever the size), in its unclamped tint; with all six textured the cube under them is white
SmoothPlastic. A plant with a sprite (a tall plant's top half's, else its own) is the sprite on an
upright plane filling the cube, both sides; glow lichen's plate shows its image only.

**Specs.**
- `tests/spec/TexturePack`: the pack's shape, an entry for every block that can carry a texture
  and none for the rest, the sheet's ids with its two typo fixes, the blanks, face resolution
  (twins, variant groups), appearances keyed by textures, `variantTexture` and `alignLut`, Blocks'
  refusals, and the generator: its output, its refusals and the committed files up to date. Tests
  that make up packs run on three bases (the pack as shipped, every blank filled, ShowMissing on),
  so filling the pack never breaks them; replacing a sheet id means updating `SHEET`.
- `tests/spec/TextureLooks`: TextureLooks under fake services: the tint maths, pixel averages and
  the paste block, near, far and plain looks of grass, logs, sandstone, cactus, ores and blanks,
  items, sprites and lichen, prototypes, the missing texture, ShowMissing, textures too dark,
  far mesh looks, generations and signals, and `start`'s checks with every failure by cause. Each
  test starts from a neutral pack (ShowMissing off, no Average) and blanks what it needs itself.
- `tests/spec/FarLooks`: MeshGeometry's look grouping, share rule, remainder tint, UVs and bands;
  MeshOverlay's `setLooks`, stale builds, `isCurrent`, a MeshPart per look, the probe and
  `dropLooks`; and generated terrain meshed with TextureLooks' real looks, Far Materials on and off.
- `tests/spec/Meshing`: odd boxes (off: unchanged; a flat layer; generated chunks: every textured
  box odd, coverage exact, other appearances unchanged).
- `tests/spec/RenderPipeline`: near, far and plain templates, sprites and lichen, restyles of only
  what changed, old templates destroyed, item cubes and icons, textures too dark, and generated
  terrain drawn through ChunkRenderer with MaterialService and the prototypes loaded from the
  generated `src/textures` files (grass is `IV_grass_side` with a green `IV_grass_top` image, logs
  `IV_log` each in its own colour, every look of all 157 appearances names something the files
  hold, ShowMissing swaps in `IV_missing_texture`).
- `tests/spec/PlayerSettings`, `SettingsClient`: the Far Materials setting (id 34) and when
  Textures and Far Materials are offered.

## Player settings (`PlayerSettings`, client `Settings/`, `Ui/SettingsScreen`, server `Players/SettingsStore`)

Players tune the view, performance, sounds, controls, HUD and chat for themselves in Minecraft's
Options screen; Config gives every default and the presets.

- **The schema** (`Shared/PlayerSettings`, pure, tested in tests/spec/PlayerSettings). Every
  setting is one number (toggles 0 / 1, choices an index, key bindings a key's code) with an
  append-only u8 id, a key, kind (slider, toggle, choice, key), range and step, desktop and phone
  defaults (and a phone maximum: the view stops at 1024 there), its page, the effect that applies
  it, and whether presets set it. Plain settings have ids 1, 2, 3... (their place in the list);
  the key bindings are generated from Shared/KeyBindings' actions from id 128 on (`KEY_BASE`), so
  both append without meeting. It
  also holds the presets (High is Config's own view, Low its `Mobile` values with shadows off and
  hidden terrain skipped), the default preset per device (phones Low; others by Roblox's saved
  graphics quality: 1-3 Low, 4-6 Medium, 7-10 or Automatic High), the LOD balance rule (split
  distance at least 2, full detail at most split + 1, the underground split from the cave view
  between the two; checked against real `LodTree` selections for every slider combination), what
  values mean (`lod`, `revealReach`, `revealRadii`, `alwaysCaves`, `lichenLightDistance`,
  `buildBudget`, `caveAmbient`, `fovModifier`, `volume`, `mouseSensitivity`, `scrollSensitivity`,
  `scroll`, `distortion`), an optional `tooltip`, the wire format and the DataStore record.
- **State** (`Settings/State`, pure). One values table for the session, changed in place
  (`Rendering/ViewSettings` reads the same table), and which settings the player chose. Only
  chosen settings are saved, so everything else keeps following the preset and Roblox's quality
  level. Picking a preset chooses `preset` and lets the settings it sets follow it again; Reset
  does the same for the current preset; Defaults forgets every choice (the key bindings too);
  `unset` forgets some (the Key Binds screen's Reset and Reset Keys). A saved profile arriving
  after the player made choices is merged under them (`receive`: what Defaults or a preset dropped
  since stays dropped).
- **When effects run** (`Settings/Schedule`, pure). Cheap effects run at the next frame, once
  however many changes asked for them; costly ones (`EXPENSIVE`: lod, caves, foliage, shadows,
  farShadows, textures, overlay) `Config.Settings.ApplyDelay` (0.4 s) after the last change, so a
  dragged slider rebuilds the world once; all in `EFFECT_ORDER` (the view before the fog that
  follows it). `flush` (the menu closing) runs everything waiting at once. An 8-step drag of the
  render distance applies the view once instead of 8 times while the fog follows every step.
- **Effects** (the client script, `Settings.register`; each runs once when registered, and a
  function registered under several keys runs once a frame):

  | Effect                       | What it calls                                                       |
  | ---------------------------- | ------------------------------------------------------------------- |
  | lod, caves, foliage          | `ChunkStreamer:applyView()` (see Streaming; the Caves setting switches its `alwaysCaves`) |
  | fog, lighting                | `ViewSettings.applyFog` and `LightingController.refresh` (the Atmosphere's density follows the view and the Fog setting at the next frame) / `applyLighting` (Prefer, Brightness) |
  | shadows, farShadows, textures | `ChunkRenderer:restyle` (see Rendering; farMaterials uses textures) |
  | overlay                      | `MeshOverlay:setUserEnabled` (see Far meshes)                       |
  | budget                       | `ChunkRenderer:setBuildBudget(ms?)`, nil for Auto                   |
  | swapFrames                   | writes `Config.Render.SwapFrames`, which the renderer reads every frame |
  | lichen, skipHidden           | nothing: read live (the lichen light sweep; the streamer's refresh) |
  | audio                        | `SoundPlayer.setPlayerSettings` (see Sounds)                        |
  | camera                       | `MovementController.setFieldOfView` / `setFovEffects` / `setViewBobbing` / `setDamageTilt`, `EffectView.setDistortion` |
  | controls                     | `Config.Movement.ToggleSprint` / `ToggleSneak` and `TouchButtons` (bound once: after rejoining), `Hud.setWheelSelects` / `setScrolling` |
  | mouse                        | `MouseLook.setSensitivity` (`UserInputService.MouseDeltaSensitivity`) / `setInverted` |
  | keys                         | `Keybinds.refresh`: fires `Keybinds.changed` (the sprint and sneak actions bind their new keys); the bindings themselves are read live |
  | hud                          | `Map.setMinimapVisible`, `Waila.setEnabled` / `setMinimapShown`, `Style.setScaleOverride`, `AttackIndicator.setMode` |
  | clouds, weather              | `WeatherClient.setClouds` / `setWeather` (Off, Fast, Fancy: the cloud rings and the rain and snow strips; see Weather) |
| chat                         | `Chat.applySettings` (see Chat)                                     |

  Worker actors keep their own Config, so what a worker needs travels in its jobs (see Workers).
- **Start-up.** The client listens for its saved profile first and waits up to
  `Config.Settings.LoadWait` (1 s) for it before it creates the streamer, so the first terrain is
  already the player's view. One arriving later applies then.
- **The menu** (`Ui/SettingsScreen`, a `Screens` panel built with `FormWidgets`; the layout comes
  from `Settings/Pages`: Minecraft's 150 × 20 buttons in two columns, settings a device doesn't
  offer left out and the rest closing up). The Options key binding (`Config.Settings.Key`, P) or
  `GamepadButton` (D-pad right) open it while no screen is open (`Screens.onSettings`), as do the
  HUD's touch gear and the inventory's gear; P, E, Escape, gamepad B and Done close it and flush
  (a sub-page's Done goes back to its `parent`: Mouse Settings and Key Binds to Controls).
  Gamepad: D-pad left / right step a slider (`FormWidgets`' `stepSelected` keeps the selection on
  it), down / up move through the widgets in reading order. Status lines come from providers the
  client script sets (`Settings.setStatus`: "terrain", "farMeshes", "controls", "mouse"). Key
  Binds needs a keyboard and Mouse Settings a mouse (`Settings.pageShown`). A setting with a
  `tooltip` (PlayerSettings; Caves warns "May lower performance") shows it in Minecraft's tooltip
  box while hovered or selected: wrapped to `Pages.TOOLTIP_W` (200) pixels (Ui/TextWrap), below
  the widget or above it near the panel's bottom (`Pages.tooltipAt`, Minecraft's
  BelowOrAboveWidgetTooltipPositioner).
- **Key bindings** (`Shared/KeyBindings`, pure; client `Settings/Keybinds`; tested in
  tests/spec/Keybinds). Minecraft's KeyMapping: 32 actions in Minecraft's categories (Movement,
  Gameplay, Inventory, Multiplayer, Miscellaneous) and this game's (Map, Just Enough Items), each a
  setting "key.<action>" holding a code: Roblox's `Enum.KeyCode` value for a key, the mouse
  KeyCodes' values (1018-1020) for the three mouse buttons, 0 for "Not Bound". The defaults are
  the keys the game always had (Config's sprint, sneak, Options and skill tree keys among them).
  Every input site asks `Keybinds.matches(action, input)` (InputBegan / Ended),
  `Keybinds.isDown(action)` (held: the walk, jump, the debug key) or `Keybinds.hotbarSlot(input)`,
  and `Keybinds.input(action)` gives ContextActionService its key (sprint, sneak); names for hints
  come from `Keybinds.name(action)`. Conflicts follow Forge's KeyConflictContext: game keys only
  meet game keys, screen keys (JEI's) only screen keys, universal ones (inventory, drop, hotbar,
  Options, skill tree) both. Escape, Shift / Ctrl as click modifiers, the mouse on slots, the
  debug combinations' second keys, gamepads and touch stay fixed, as in Minecraft.
- **The Key Binds screen** (`SettingsScreen`'s list page: rows from `Pages.keyList`, scrolling
  from `Pages.clampScroll` / `thumb` / `scrollAtThumb` / `scrollToShow`). Waiting for a key, a
  cover takes the panel's clicks and Screens leaves every key to the panel (`Panel.capturing`;
  Escape and the Roblox menu opening go to `Panel.escaped`: Not Bound); `CAPTURE_GRACE` (0.3 s)
  after a key is taken the same press is still the panel's. The wheel reaches the list through
  `Panel.wheel` (Hud sinks the wheel for screens). A binding set back to its default is forgotten
  (`Settings.unset`), not saved.
- **Persistence** (`Players/SettingsStore`, like WaypointStore). One profile per kind of device
  (desktop, touch: `ViewSettings.isMobile`, console: `GuiService:IsTenFootInterface`), so a phone
  never loads a computer's view. DataStore "IceVoxelSettings_v1", key `player_<UserId>`, a record
  `{ v = 1, desktop = {...}, touch = {...}, console = {...} }` of `{ [id] = value }`. Loaded on
  join with retries; if loading fails nothing is saved that session, so an outage never overwrites
  saved settings. Once loaded the server sends one `Settings` message per profile (count 0 when
  nothing is saved) and the client takes its own. The client sends its profile (`SaveSettings`)
  `Config.Settings.SaveDelay` (1.5 s) after the last change, when the menu closes, and at once
  when the saved profile arrived after it had made choices (the merged result). The server decodes
  it with PlayerSettings (unknown ids and NaN dropped, values clamped, a touch profile to the
  phone limits) and keeps the newest per profile, whole. One that arrives before loading finished
  replaces the loaded one too, but the client is still sent the loaded one, merges it under its
  choices and sends the result back (a key-by-key merge on the server would bring back saved
  choices the player had undone; only a player leaving within that round trip keeps just the
  early profile). Saved on leave and in `BindToClose` (which waits for saves in flight, up to
  25 s), only when something changed. tests/spec/SettingsStore runs the real store against a fake
  DataStore with delays and failures, wired to the real client controller.

## Chat (client `Ui/Chat/`, `Net/Notices`)

Minecraft 1.20.1's chat (ChatComponent, ChatScreen, CommandSuggestions, ChatListener) replaces
Roblox's chat window and input bar, which the client turns off before the title screen shows
(`Chat.hideRoblox`: `ChatWindowConfiguration`, `ChatInputBarConfiguration`,
`ChannelTabsConfiguration` `.Enabled = false`; the title screen has no chat, as Minecraft's). Box
and lines are drawn over the HUD (DisplayOrder 12, as Minecraft draws the chat over the hotbar),
under a screen's backdrop while one is open (8). On touch, the tap on the HUD's chat button that
takes the box's focus closes the chat, and the button's own Activated right after (`TAP_CLOSE`)
does not open it again. Roblox still carries
every message: players' text is only ever sent with `TextChannel:SendAsync` and shown from
`TextChatService.MessageReceived`, so Roblox filters it for each reader; the game never sends
player text through its own remotes. No server code and no Protocol message were added.

- **Lines** (`ChatLog`, pure, tested in tests/spec/Chat). The newest 100 messages are kept, each
  wrapped (at spaces; long words by characters; never through a UTF-8 character) to the chat's
  width in chat units (the Width setting divided by the Text Size), and the newest 100 lines,
  newest first. A line shows for 10 s, fully for 9 and fading out over the last second with
  Minecraft's squared curve; while the box is open every line shows. Rows: floor(height / line
  height) with the focused or unfocused height; line height is floor(9 × (1 + spacing)) and the
  text sits Minecraft's round(-8 × (1 + spacing) + 4 × spacing) above a row's bottom. Scrolling (7
  lines a notch, 1 with Shift, Page Up / Down a page less one) only while open; a message arriving
  while scrolled up moves the position with it and turns the scroll bar red; closing scrolls
  back. Chat Delay queues other players' messages (`ChatFormat.isPlayerKind`) and lets one out
  per delay ("[+N pending lines]"); everything else shows at once. Each line's rich text and its
  shadow's are made once, when it is wrapped, and the labels change only when `version` does,
  so drawing is a loop over at most 20 rows setting what changed, and nothing at all once every
  line has faded.
- **Looks** (`ChatFormat`, pure). Messages are coloured spans (hex colours, bold, italic,
  underline): players' "<Name> message" white, Roblox's whisper channels as Minecraft's gray
  italic private messages, team channels "[Team] <Name> ...", joins and leaves yellow, notices
  white, the debug prefix bold yellow, the chat's own errors red, Roblox's system messages gray
  (tags stripped). TextChatService delivers players' text escaped for rich text; it is unescaped
  for the plain text (wrapping, searching) and escaped again for the labels. The Chat setting
  decides what is kept at all: Commands Only drops players' messages, Hidden everything.
- **The box** (`ChatInput`, pure). Sent text is trimmed, its runs of spaces collapsed and cut to
  200 bytes (Roblox's limit; Minecraft's is 256). A command's first word is looked up in the
  aliases of the `TextChatCommand`s under TextChatService (the server's commands replicate there,
  and Roblox's own): found, the text goes to SendAsync with the word written as the alias is
  (TextChatService runs the command, and shows it to no one); not found, nothing is sent and
  Minecraft's two red lines answer ("Unknown or incomplete command, see below for error", then the
  input underlined and "<--[HERE]"). History: 100 sent texts, a repeat of the last only once, Up /
  Down with the draft kept. Tab: the word before the cursor, command aliases while in a command's
  first word, else players' names and display names (any case, all for an empty word); the first
  Tab uses the highlighted suggestion, further ones move on (SuggestionsList.tabCycles); while a
  command's name is typed its suggestions show by themselves (Command Suggestions), 10 rows at a
  time, and Up / Down move the highlight instead of the history. Tab and the suggestions offer only
  the commands the player may use, as Minecraft's client knows only those of its permission
  level: the server marks each of its commands with `WorldSettings.COMMAND_ATTRIBUTE` ("operator":
  /op, /deop; "commands": /effect, /summon, /kill, the operators' permission; "gamemode":
  /gamemode, the player's own mode permission; none: /time, /gamerule and /knowledge, whose
  queries anyone may make) and `WorldSettings.mayRun` reads it with the player's attributes
  (`IceVoxelOperator`, the world's `AllowCommands`, `IceVoxelGameModePermission`). Sending still
  knows every command: the server answers one the player may not use.
- **Glue** (`Ui/Chat/init`). The key bindings "chat" and "command" (`Settings/Keybinds`, T and "/"
  by default; a mouse button bound to them counts off the GUI) open the box when no screen
  (the Key Binds screen waiting for a key among them), switcher, menu or other text box is open;
  the focus is captured a frame later so the key is not typed (and taken back if it was: the
  character `GetStringForKeyCode` gives for the key). While open: `Hud.setInputTaken` (no hotbar keys or wheel, the wheel scrolls the
  chat), the mouse is freed after the camera every frame (computers), a full-screen button catches
  clicks beside the box (they never reach the world) and the box takes the focus back, as
  Minecraft's chat screen is modal; on touch a tap elsewhere closes it, and box and lines rise
  above the on-screen keyboard. Escape, Roblox's menu, or a screen opening (a block's window the
  server opens) close it. Every key handler in the game already ignores input a text box took
  (`gameProcessedEvent`, or `UserInputService:GetFocusedTextBox()` where processed input matters),
  and `Player/MovementController` stands the player still while a text box has the keys, so typing
  never moves, mines, drops or opens anything. Plain text is refused with Commands Only and when
  the local TextSource may not send (Roblox's privacy settings); SendAsync's refusals are put in
  words. Roblox's /whisper and /team may point `ChatInputBarConfiguration.TargetTextChannel`
  elsewhere: the box then sends there, says so, and Backspace in an empty box goes back to
  RBXGeneral. Joins and leaves come from `Players.PlayerAdded` / `PlayerRemoving` on each client
  (the player's own join too). Roblox's /clear (`RBXClearCommand.Triggered`) clears the lines.
  With the legacy chat nothing here starts.
- **Notices.** The server's `Notice` messages (command feedback, Age announcements, structure
  saves, F3 + Q) still arrive through `Net/Notices`; once the chat runs it sets `Notices.setSink`
  and they become white lines (the debug ones with their bold yellow prefix) shown at once,
  instead of RBXSystem system messages. `Notices.listen` (the structure screen's status line)
  is unchanged.
- **Arguments and links** (/locate). A command may list its arguments
  (`WorldSettings.COMMAND_ARGUMENTS_ATTRIBUTE`: one line per position, "<words before>|<candidate>,
  ..."; `ChatInput.parseArguments`): Tab and the suggestions that show by themselves complete
  them by the start of the word ("minecraft:" skipped, tags only once "#" is typed), for the
  commands the player may use. A notice's link (`Protocol.NoticeLink`) becomes a green span with
  `suggest` and `hover` (`ChatFormat.notice(text, link)`); while the chat is open a click or tap
  on it (`ChatLog.spanAt`: the span under the pointer, measuring the line's text up to each span)
  puts its command in the box and keeps the focus (Minecraft's SUGGEST_COMMAND), and hovering it
  shows Minecraft's tooltip ("Click to teleport"). Roblox's chat (before the game's chat starts)
  shows the link's part green; the legacy chat plain text.
- **Settings** (`PlayerSettings` ids 46-55, page "chat", effect "chat"): chatVisibility,
  chatOpacity (10-100), chatBackground, chatScale, chatLineSpacing, chatDelay (half seconds:
  tenths are not exact in f32), chatWidth (40-320), chatHeightFocused / chatHeightUnfocused
  (20-180), commandSuggestions; `ChatLog.metrics` turns them into what the chat draws with.

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
- Changing the time or the rule needs the operators' permission (`Players/Operators.permitted`,
  see the title screen's section); queries are open to everyone.
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
  sky, so caves are equally dark at noon and at midnight, as in Minecraft. The Brightness setting
  raises it towards Minecraft's Bright (`ViewSettings.applyLighting` writes `CaveAmbient`; 0% is
  Config's own).

With `Lighting.Enabled = false` it writes only `ClockTime`, but still works out the sky exposure
below: the music (`Audio/Music`: surface or cave), the cave mood's sky light (`skyLight`) and F3
read it.

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

A cave entrance darkens like a dug tunnel (half light ~17 blocks in, dark from ~30), a ravine's
floor is under the open sky (nothing opaque above it: full light), and the deep caves beyond stay
dark (tests/spec/SkyExposure checks real ones).

**Haze** (`Rendering/AtmosphereModel`, pure, tested in tests/spec/Atmosphere). The view's
distance fades into the sky through a Lighting Atmosphere, Roblox's newer fog: while one is in
Lighting (with a Sky: without one Roblox ignores it) the old `FogStart` / `FogEnd` / `FogColor`
are ignored, even at Density 0.
- *Whose.* `default.project.json` puts an `Atmosphere` (its daytime values, so Studio's edit view
  looks right; the spec checks they match what the client writes at noon) and a `Sky` in
  Lighting, under the names a new place's template uses, so `rojo serve` updates those.
  `ViewSettings.atmosphere()` adopts the first Atmosphere in Lighting; `LightingController.start`
  makes "IceVoxelAtmosphere" when there is none, "IceVoxelSky" when there is no Sky, and takes a
  second Atmosphere out (which one Roblox would use is undefined). With `Lighting.Enabled = false`
  nothing is made or written: the place's Atmosphere is its own (the Fog button reads "Place's
  Own"), but the short fogs below still take it out while they show. The project's Atmosphere is
  marked (attribute `IceVoxel` = true, `ViewSettings.PROJECT_ATTRIBUTE`) and is not the place's:
  with `Enabled` false `ViewSettings.atmosphere()` takes it out of Lighting, so the old view fog
  follows the view, the weather and the Fog setting as before the project had one (its fixed
  daytime haze would follow none of them).
- *Distance.* An Atmosphere has no start or end. Roblox publishes no formula; the best model (a
  re-implementation of its renderer, matching developers' reports such as Density 1 hiding things
  some 30 studs away and the docs' examples) is transmittance T(d) = exp(-Scale x Density^4 x d),
  d in studs from the camera. `extinction` gives the k = -ln(Edge) / R that leaves `Edge` (0.1) of
  a thing's light at R = view x BlockSize (the old FogEnd), `density` the Density
  (k / Scale)^(1/4): 0.247 at 2048 blocks, 0.294 at 1024, 0.350 at 512, 0.208 at 4096. The loaded terrain's edge is 90% hazed, LodTree's far nodes drawn whole up to a third past
  it over 95%; near things stay clear (haze(d) = 1 - Edge^(d / R), whatever Scale is: 6% at R /
  40, 13% at R / 16, 44% at R / 4). The old fog was clear to 55% of R and opaque at R, so the
  middle distance is hazier than before. `Offset` 0.05 fades the haze into the sky right behind a
  thing, so the edge melts into it (a high Offset gives silhouettes and shows LOD changes).
- *Weather.* `WeatherSky.fog`'s factor f (0.6 rain, 0.4 snow, 0.45 thunder) shortens R to
  R x f^`WeatherPower` (1/3: Density x f^(-1/12); the loaded terrain's edge 93-96% hazed). Not
  the old fog's whole nearer FogEnd: this haze starts at the camera, and the storm's cloud deck
  overhead (224 blocks up from y 64) would come out 57-72% hazed into the clear sky behind it at
  1024 blocks of view, where the old fog (from 55% of FogEnd) never reached it; with 1/3 it stays
  at most half hazed from 1024 blocks up (Low's 512: 70-75%). `WeatherSky.apply` darkens the fog
  colour (Minecraft's), adds `Sky.Haze` x rain and `ThunderHaze` x thunder to Haze (the horizon
  greys over in the storm's colour: that is the storm's look) and takes the sun's glare away.
- *Caves.* The haze fades things into the sky behind them, a daylit sky even in a cave, so below
  `ThinBelow` (0.4) of sky exposure k is scaled by (exposure / ThinBelow)^2 (deep down: Density
  0), and `DayCycle.environment` fades Haze and Glare out with the rest of the sky's light. Both
  follow the exposure's smoothing. Above ThinBelow the haze is the outdoor one: inside a tunnel
  dug into a hillside (exposure 1 - distance / 16) the view out of its mouth keeps it for the
  first 9 blocks (87% at the view's edge 10 blocks in, 59% at 12), so the edge of the loaded
  terrain doesn't show and stepping out doesn't pump the haze; the tunnel's own walls, within 16
  blocks, are under 3% hazed anyway.
- *Colour.* Color is `DayCycle.environment`'s fog colour (Minecraft's day, dusk, night fog: the
  colour of Minecraft's horizon), then darkened by the weather (`WeatherSky.apply`). In the
  re-implementation the haze scatters the sky box's light by Color^2, not darkened at night, so
  Minecraft's dark night fog gives a dark night haze, and a brighter night Color would glow over
  the dark sky. `ColorFloor` (0: off) raises the time of day's colour at its brightest channel
  (`AtmosphereModel.floor`, before `WeatherSky.apply`, so rain and thunder still darken it):
  a knob for the Roblox player if the night's horizon shows black there. Haze, Glare and Decay
  are blended like the light (`Day`, `Night`, `Dusk`: a warm haze and a glow around the sun at
  sunset, no glare at night). The Dusk glare only shows with the sun above the horizon (full by
  `DayCycle.GLARE_RISE`, 0.05): with an Atmosphere Roblox is reported to light from the moon from
  ClockTime 18 to 6, and the glare would sit round the moon; the haze keeps the dusk's glow.
- *Off.* The Fog setting off (or `Render.Fog` false): Density, Haze and Glare 0. The Atmosphere
  stays in Lighting.
- *Writing.* `LightingController` works it out every update into one table (`state`) and writes
  only what changed (Density to a thousandth, Haze and Glare to a hundredth, colours in whole
  steps), into the Atmosphere even while it is out of Lighting, so it comes back up to date.
- *Which fog shows* (`AtmosphereModel.fog`, `ViewSettings.applyFog`): a status effect's fog
  (Blindness) when nearer than the fluid's, the fluid's, else the Atmosphere. The short fogs keep
  Minecraft's exact distances and colours with the old fog: `applyFog` writes FogStart / FogEnd
  and takes the Atmosphere out (Parent nil, the reference kept) in one call, and the colour comes
  from LightingController in the same frame (FluidFog and EffectView call both), so no frame
  shows both or neither; when they end the Atmosphere goes back with the place's own FogStart /
  FogEnd. Without any Atmosphere (`Lighting.Enabled` false in a place without one of its own)
  the old view fog stays: FogEnd at the view x the weather's factor, FogStart 55% of it.
- *F3*: the `fog` line, the Atmosphere's Density and how far it hazes things 90% (in blocks),
  Haze, Glare, Offset; or the short fog's start and end.

Uncertain: the Scale constant (and so the Densities) comes from a re-implementation, not Roblox;
calibrate it in Studio with a part d studs away whose haze looks half: Scale = 0.693 /
(Density^4 x d). Roblox steps quick changes of Color and Haze (Density changes are smooth), so
everything here changes over seconds. Also uncertain: that the haze's light is not darkened at
night (the re-implementation; why `ColorFloor` is 0), and when Roblox swaps the sun's light for
the moon's (forum reports; why the dusk glare stops at the horizon).

## Weather (`Weather/`, server `World/WeatherServer`, `World/WeatherRules`, `World/Lightning`, client `Weather/`, `Map/WeatherLayer`)

Minecraft's weather is one switch for the whole world. Here it is a field over the world and
time, so storms can be seen coming, walked out of, and forecast. It is pure and deterministic:
the server, every client and the tests compute the same storms from the world seed and the
weather clock.

**The field** (`Weather/WeatherModel`, `WeatherModel.new(seed)` or `Weather.setSeed(seed)` for
the world's):
- *Wind.* The air's displacement D(t) has a closed form: a prevailing wind (1.2 blocks a second,
  its direction from the seed) plus three sinusoidal swings in time (periods of 7 to 31 minutes,
  phases from the seed). The wind's speed (0 to about 3 blocks a second) and direction wander
  slowly. `wind(t)` is its derivative.
- *Moisture.* Three layers of Perlin noise are drawn in the air's frame, (x, z) − D(t), so
  everything drifts with the wind. Weather systems are ~5 km across, storm cells ~1.6 km and
  showers ~450 blocks. Each layer also moves slowly through its own time axis (one noise unit in
  200000, 60000 and 20000 ticks), so storms grow and die out about half as fast as the mean
  wind carries them.
- *Outputs.* Precipitation is the moisture over a threshold, smoothed from drizzle at the edge to
  1 in the core; it counts as falling over 0.2 (Minecraft's isRaining). Cloud cover starts lower,
  so clouds spread around the rain. Thunder needs the highest moisture and a slower
  "instability" noise, and never exceeds the precipitation.
- *Precision.* Every noise coordinate is reduced modulo 256 (math.noise's lattice period) in
  double precision first, so far places and late clocks stay smooth.
- *Cost.* A sample costs ~0.5 µs. `grid` fills a buffer for a whole rectangle at once (the
  per-time terms are worked out once).
- *Calibration* (seeds 12345, 777 and 4242, 192 places over 40 in-game days, sampled every
  10 s): it rains 23-24% of the time (Minecraft ~16%). Spells of rain last 16-18 minutes on
  average (median 11-13, p10 2, p90 42, longest 2-3 hours). Clear stretches last 50-56
  minutes. A storm's median chord is ~1.1 km (p10 225 blocks, p90 3.5 km). It thunders 3% of
  the time, 13-14% of the rainy time. `tests/spec/Weather` checks the ranges on one seed.

**The clock** (`Weather` State): the weather clock counts 20 ticks a real second times
`Weather.Speed`, and nothing while doWeatherCycle is off. It is published like the day's clock,
as three workspace attributes: `IceVoxelWeatherTime`, `IceVoxelWeatherSync` and
`IceVoxelWeatherRate`. `/time` never touches it, so setting the time doesn't move a storm. A new
world's clock starts where its spawn stays dry for `Weather.ClearStartSeconds`
(`Weather.clearStart`). `IceVoxelWeatherEnabled` false (`Weather.Enabled` off, or the debug
worlds) means always clear.

**Overrides** (`/weather`): an override blends the whole world towards its kind:
- rain: at least 0.8 precipitation, no thunder, overcast;
- thunder: full rain and thunder;
- clear: no rain and thin clouds at most.

It blends in over `Weather.BlendSeconds` (5 s, Minecraft's 0.01 rain level a tick) from
whatever was there before: the overrides it replaced (`previous`, oldest first: the old one at the
weight it had, after what that one was still blending from, up to 8) fade out as it comes in, so
changing your mind, even three times in three seconds, never jumps. It blends back out over the
last 5 s before it ends; one shorter than the blend is dropped only once what it replaced has
faded out too (`expire`). With doWeatherCycle off an override's time stands still (Minecraft's
counters wait too), so it never ends, and one fading out stays where it was. It is published as
one string attribute, `IceVoxelWeatherOverride` ("kind;start;finish;left;previous;weight..."), so
a client never sees half a change. `Weather.momentAt(state, serverTime)` gives a Moment: the clock with the
override's weights, which `at`, `grid` and `forecastAt` take.

**What falls where** (Minecraft's Biome.getPrecipitationAt):
- Each biome has Minecraft's temperature and precipitation flag (`BiomeList` `weather`; Biomes
  `weatherTemperature`, `precipitation`). Deserts and savannas get none.
- It snows below 0.15, else it rains.
- It gets colder with height: 0.05 every 40 blocks above y 80 in Minecraft, which is 0.0029 a
  block above y 71 on this world's terrain (the datapack's heights × 0.43). A small noise makes
  the snow line ragged.
- So a plains valley rains while the slopes above ~295 snow, and a taiga snows from ~105 up.
- `Weather.kindAt(x, y, z, time, biomeTemperature)` is "clear", "rain" or "snow".

**Sky hooks** (pure, for the client):
- Minecraft's darkening: (1 − rain × 5/16) × (1 − thunder × 5/16) of the sky's brightness:
  `dimming`, `skyDarken`, `skyLight`, `sunBrightness`, and `isDay`, which is false in a full
  thunderstorm even at noon.
- The sky, cloud and fog colours greyed as in ClientLevel and FogRenderer.
- `fogFactor`: the fog distance at full rain 0.6, snow 0.4, thunder 0.45 (the client's
  Atmosphere: as dense as for a view that factor to `Lighting.Atmosphere.WeatherPower` shorter).
- The rain's sound volume and pitch (`rainSound`, LevelRenderer's weather.rain and
  weather.rain.above).
- `thunderDelay(distance)`: thunder at 343 blocks a second.

**On the server** (`World/WeatherServer`):
- *Rain on a cell* (`rainingAt`, `World/WeatherRules`: Minecraft's Level.isRainingAt):
  precipitation over 0.2 there, rain (not snow, not a dry biome), and nothing that stops rain at
  or above the cell (Minecraft's MOTION_BLOCKING: anything with a collision box, i.e.
  Blocks.obstruction, and fluids; torches and plants let it through). The column's biome comes
  from the generator and is cached per column. The moment is worked out once a frame.
- *Fire* (`Behaviours/Fire`, FireBlock.tick): rain on a fire or beside it puts it out with a
  chance of 0.2 + age × 0.03 a fire tick, and a cell near rain never catches.
- *Wetness* (`Players/ToughAsNails`): rain at a player's feet or the top of their box, checked
  once a second, makes them wet, as water does (TAN: 3 steps colder).
- *The undead* (`Mobs/MobWorld`): zombies and skeletons don't burn in the rain
  (isInWaterRainOrBubble) or where the weather makes it not day (`isDayAt`: a thunderstorm).
- *Burning* (`Players/Burning`'s RAIN bit, Entity.move's isInWaterRainOrBubble): rain at the feet
  or the top of the box puts out a burning player (`Characters.setRain`) or mob, whatever set it
  (a bolt, daylight, lava they left), after the tick's fire and lava; the weather is asked only
  while something burns.
- *Lightning* (`World/Lightning`, pure, with injected randomness):
  - Rate: every player not in spectator rolls once a second, thunder at their feet ÷
    `Lightning.MeanSeconds` (20). Minecraft's 1 in 100000 per chunk a tick would be rare near a
    player here. Like Minecraft's, the rate is the area's (`Lightning.roll`): a column a player
    drew is kept with the share 1 / (players whose discs hold it), so players standing together
    don't multiply the strikes (eight at one spot: 1053 strikes in 20000 s against one player's
    987; two far apart: 1985).
  - Target: a column picked evenly within `Lightning.Radius` (64). It strikes the column's top
    (the MOTION_BLOCKING heightmap), or a living thing within 3 blocks of the column, from 3 below
    its top up to the build height, that sees the sky (findLightningTargetAround's box: one on a
    pillar draws it). It only strikes where it rains.
  - Fire: with doFireTick, the struck cell, plus 4 random cells around it on normal and hard
    (LightningBolt.spawnFire). Fire goes only into air where it can stay.
  - Hurt: the living within x ± 3, y − 3 .. y + 9 of the bolt catch fire for 8 s and take 5 half
    hearts through armor (Entity.thunderHit); the rain the bolt struck in puts the fire out on
    the next tick (above), so a strike costs 5 half hearts. Players via `Characters.lightning`, mobs via
    `Mobs.lightning` and `MobWorld.lightning`; the boot script connects them
    (`WeatherServer.setHandler`).
  - An unloaded column is struck at the generator's height, as a sight only.
  - Every player within `Lightning.Distance` (4096 blocks, Ultra's view) gets a `Lightning`
    message, so a strike where players stand is seen as far as any view reaches (17 bytes a
    strike; a client draws it within its view and hears it within `Distant.Hearing`).
- *Commands* (`Players/WeatherCommand`, pure; `Players/WeatherCommands`):
  - `/weather clear|rain|thunder [duration]`: Minecraft's TimeArgument, at least 1 tick. The
    default is Minecraft's random duration: clear 12000-180000 ticks, rain 12000-24000,
    thunder 3600-15600. It answers with Minecraft's "Set the weather to rain & thunder" and
    needs the operators' permission.
  - `/weather query` (Bedrock's, for anyone) says what it is doing where you stand.
  - `/gamerule doWeatherCycle` lives in `Players/TimeCommand` with doDaylightCycle.
- *Saving*: `WeatherServer.encode()` gives a short string (`Weather.encodeState`: the clock's
  value, doWeatherCycle, the override and its time left). `WeatherServer.decode(text)` restores
  it before or after the weather starts, with the override already blended in, so a world loads
  as it was. `World/WorldSave` keeps it as the world's "weather" section (in its record, beside
  "time"): startWorld starts the weather (a new world's clear start at spawn) before
  `WorldSave.restore` decodes a saved world's over it, so the clock goes on from the value it was
  saved at (the time the server was down doesn't count, as Minecraft's level.dat), and a world
  saved without one, or with text that can't be read, keeps the clear start. Before `start`,
  `encode` gives back a decoded state still waiting for it.

**On the client** (`Weather/`, started by the client boot after `Rendering/LightingController`;
the Clouds and Weather settings reach it through `WeatherClient.setClouds` / `setWeather`):
- *State* (`Weather/WeatherState`): reads the attributes with `Weather.readState` (again only
  when one changes, then fires `changed`), works the frame's Moment out once into one table
  (`Weather.momentAt(state, now, into)`, in a RenderStep before the other weather work), and
  samples the weather over the camera's column: as it is (F3, the rain's form) and smoothed in
  time (`DayCycle.approach`: the light over Sky.Smoothing, the rain drawn over
  Precipitation.Smoothing), so a teleport out of a storm brightens the sky over a few seconds.
  Column biomes and ground heights come from the generator, cached per column (16384).
- *Rain and snow* (`Weather/Precipitation`, pure; `PrecipitationView`): Minecraft's
  renderSnowAndRain. Every block column within the radius (Fast 5: 69 columns, Fancy 10: 305)
  is one camera-facing Beam between two Attachments of one invisible part at the camera's cell.
  A column draws from max(cameraY − r, floor) to max(cameraY + r, floor), where the floor is
  the cell above the highest block that stops rain (`Weather.blocksRain`), so nothing falls under
  a roof, in a cave, or in a column whose roof is above the camera. Its form is the column's
  (rain or snow by biome and landing height; nothing in dry biomes), its alpha the intensity at
  the camera × Minecraft's edge fade ((1 − d²/r²) × 0.5 + 0.5), in 16 steps with one
  NumberSequence per form and step made once. Floors are scanned from the loaded chunk buffers
  (`floorOf`, against a lookup table of the blocks that stop rain), at most ScansPerFrame columns
  a frame, cached per column and kept right by `ClientWorld:onBlockChanged` (a new blocking block
  above the floor raises it; the floor's block going away rescans) and `onChunkLoaded`. The
  strips are laid out again only when the camera changes cell, a floor is learned or the alpha
  step changes, writing only what differs; in clear weather nothing is looked up. The pure work
  of a layout is 0.06 ms for 305 columns (Lune).
- *The rain's sound*: Minecraft's tickRain, 20 times a second: 100 × level² random columns
  within 10 blocks (level halved on Fast; the columns it tries are queued for a roof scan as the
  strips' are, so it plays with the Weather setting Off and reaches 10 blocks on Fast), the last
  whose rain lands within 10 blocks of the
  camera's height is where `weather.rain` (or `weather.rain.above`, quieter and lower, when it
  lands more than a block above the camera and the camera's column is roofed) plays, when
  nextInt(3) < the ticks since the last one. Volume and pitch from `Weather.rainSound`.
- *Light and fog* (`Weather/WeatherSky`, pure): `Rendering/LightingController` passes
  `DayCycle.environment`'s values through `WeatherSky.apply` every update: what the sky gives
  (OutdoorAmbient, the sun's Brightness and ColorShift_Top, the sky box's diffuse and specular
  light) times Minecraft's dimming, the sun also by `Sky.CoverSun` of the cloud cover, the fog's
  colour by `Weather.fogColour` (the Atmosphere's Color), the Atmosphere's Haze up by `Sky.Haze`
  and `ThunderHaze` and its Glare gone, all scaled by the sky exposure, so caves never change. At
  10 Hz a ColorCorrectionEffect (`IceVoxelWeatherView`) greys, flattens and cools the picture
  (`WeatherSky.grading`), and the haze thickens by `Weather.fogFactor` to the power
  `Lighting.Atmosphere.WeatherPower` (`ViewSettings.setWeatherFog`, read by LightingController's
  next update: see Lighting, Haze; a fluid's or Blindness's fog still wins). The clouds are parts,
  hazed by distance like the terrain: their rings' ragged edge just past the view distance over
  90%, a cloud halfway out under 70%, the storm's deck overhead at most half from 1024 blocks of
  view up.
- *Clouds* (`Weather/CloudLod`, pure; `CloudView`): flat boxes at `Clouds.Altitude` (320: above
  9 in 10 of the land on seed 12345, under the great ranges' peaks) in the air's frame
  ((x, z) − D(t)), so they drift with the storms. Rings of detail as a clipmap: ring L has cells
  of 16 × 2^L blocks, 24 across, centred on the camera snapped to two of its cells, the next
  ring's window cut out on its cell edges; rings are added until one reaches the view distance (5
  at 2048, 6 at 4096). A cell is cloudy where a smooth, about uniform pattern (Perlin noise
  through a logistic, wavelength at least 3 cells, so far rings keep whole clouds) is below
  CoverBase + (1 − CoverBase) × cover. Its look comes from the precipitation and thunder there in
  a few steps: the grey of `Weather.cloudColour` in 6 shades, the base lowered and the box
  thickened by rain, a tower of up to 160 blocks over thunder; from ring 1 out, heavy rain gets a
  see-through grey shaft from the ground to the cloud deck (the lowest ground under it where the
  clouds are at each plan, in 8-block steps that are part of its key: `CloudLod.groundShafts`, so
  a shaft that drifted off a plateau is placed again lower). Equal neighbours merge greedily into
  rectangles (at most a part's 2048 studs a side). A ring is planned again when its window or its
  hole (the finer ring's window, which moves twice as often) moved (`CloudLod.sameWindow`), every
  RefreshSeconds × 2^ring, or when the mode or view changed: one ring a frame at most
  (0.2-0.7 ms in Lune), keyed boxes diffed against the live ones so unchanged parts stay; at most
  PartsPerFrame (48) parts are placed or removed a frame, new ones first (no holes), released ones
  pooled. Each ring is one Model moved with PivotTo to the displacement now (every 0.1 s near,
  less often far). Parts on seed 12345 (two in-game days, at the spawn and 3 km out): Fancy 2048
  202 on average, 387 at most (122 shafts); Fancy 4096 325 / 496; Fancy 1024 140 / 238; Fast
  2048 88 / 122; Fast 512 (Low, phones) 38 / 48. A world without weather (the debug worlds,
  `Weather.Enabled` off) has no clouds.
- *Lightning* (`Weather/LightningBolt`, pure; `LightningView`): the `Lightning` message's seed
  gives Minecraft's bolt (8 sections of 16 blocks zigzagging by up to 5 blocks, two branches
  zigzagging by up to 15, widening upwards) and its life (LightningBolt.tick: 2 ticks, then up to
  `flashes` more shapes after random pauses); the sky flashes while its life is at least 0 (a
  ColorCorrectionEffect's brightness, less with distance (`DistantStorms.skyFlash`: half at 512
  blocks, and by day the farther the less, to the distant flashes' `DayFlash` at Near), indoors
  and blind: `EffectView.blindness`) and a PointLight lights the
  struck point. Each segment is a Neon core and a see-through glow (pooled parts; three bolts at
  once at most). The crack plays where it struck; the thunder after `Weather.thunderDelay`, 8
  blocks (`DistantStorms.THUNDER_OFFSET`) from the listener towards the strike, fainter with
  distance (`DistantStorms.thunderCue`). A strike farther than `Distant.Near` (256) is drawn and heard as a distant
  one (below). Every strike also lights the clouds over it (`CloudView.glow`).
- *Distant storms* (`Weather/DistantStorms`, pure; `StormView`; drawn and heard by
  `LightningView.distant`): Minecraft has lightning only near players and no weather far off, so
  each client makes the lightning of the thunderstorms in reach itself, the same on every client
  with nothing sent (as Minecraft 1.21.9's End flashes come from the game time alone):
  - Schedule: `Distant.Cell` (128) block cells, `Distant.Period` (2 s) periods of the server's
    clock (`GetServerTimeNow`: the weather clock stands still with doWeatherCycle off, while the
    server goes on striking). During a period the next one's flashes are worked out, a band of
    rows a frame (`prepare`, then `advance` by `budget`'s cells: the rows left shared out over the
    frames until it is due, half a second before it starts, or half a second after its work
    began when that began late; at least `CellsPerFrame`): its thunder sampled at every cell
    centre within reach (`Field:grid` at that period's start: `fill`), each cell's chance
    `1 − exp(−rate × cell² × period × weight)` with the most thunder of it and its 8 neighbours
    (`weight`: 0 at `MinThunder` 0.15, the clouds' first tower step, to 1) worked out as the rows
    come in, then each cell rolled by a hash of (seed, cell, period) (`roll`); a cell that fires
    draws its point, time, kind, shape seed and flashes from more of the hash and keeps the point
    with the share of the weight the thunder there has. A grid not ready when its period starts
    is finished and shown late (flashes up to 1 s late), never thrown away. Rate: `Distant.Rate` (12)
    a minute per km² of full thunder (Minecraft's near a player: 47; the server's: 233; real
    storms 0.04-1). 55% of 2048-block views hold thunder (seeds 12345, 777, 4242); the median
    holds 0.38 km² of its weight: a flash every 13 s (one in ten over 22 a minute, the biggest
    83); with a storm thundering 600 blocks off, 13 a minute. At most `PerMinute` (24, one every
    2.5 s; `FastPerMinute` 12 on Fast clouds; Off none) in reach, thinned by one scale for all
    cells, keeping the lowest rolls (Fast's flashes are Fancy's). Under the cap every client sees
    the same flashes; over it, clients with another reach or Fast thin by another scale and
    share most of them.
  - Kinds: `GroundShare` (0.3) bolts, where rain falls; the rest flash in the cloud. No bolt
    within `MinDistance` (64) of the camera or anyone or `Lightning.Radius` + `Margin` (96) of a
    player in thunder, not a spectator (the server's strikes are there; now sent out to 4096):
    an in-cloud flash instead (`strikes`, asked as the flash shows).
  - Reach: max(view, `Hearing` 2048, `MobileHearing` 1024 on phones), at most `MaxReach` 4096:
    seen within the view, heard within the hearing (Ultra's outer 2 km flicker silently).
  - Seen: a far bolt from the ground (`groundAt`: the generator's height, its own sea level's
    surface over water, so on a flat world's ground too) to the cloud's base (`CloudView.base`),
    one FaceCamera Beam a segment (LightEmission 1, LightInfluence 0, pooled with its two
    Attachments) `boltWidth` wide (`PixelWidth` 0.0026 × the distance: 2 px at the vertical FOV
    70, 1080p, where a pixel is 2 tan 35° / 1080 = 1.3e-3 of the distance) and `brightness` bright (Beam.Brightness =
    1 / the Atmosphere's transmittance there, `AtmosphereModel.haze`, at most `MaxBrightness`
    20); at most `Bolts` (3; `FastBolts` 2) bolts and `Glows` (4) distant flashes at once. The
    clouds over a flash are lit while it flashes (`CloudView.glow` / `light` / `unglow`: up to
    `GlowParts` 6 cloud parts of the finest ring with any within `GlowRadius` 96 blocks, turned
    `Glow` of the way to the bolt's colour and Neon, written only on change and only while a
    part still shows its box; a lit part released by a plan gets its material back). The sky's
    flash: `skyFlash` (half at 512 blocks, by day down to `DayFlash` 0.3 of that from Near on,
    so no jump where strikes turn distant; `InCloudFlash` 0.5 in the cloud).
  - Heard: after `Weather.thunderDelay` (6 s from 2 km), `entity.lightning_bolt.thunder.far`
    (the thunder's stand-in lower still; its category is the thunder) on
    `SoundPlayer.playDistant`'s own voices (3, `MobileVoices` 2 on phones: an Attachment each with
    an EqualizerSoundEffect of its own, kept 8 blocks from the listener towards the flash every
    frame, the quietest as heard now giving way: `SoundRules.acquireQuietest`, fading out over
    `DISTANT_FADE` 0.2 s before the louder one starts, `fadeOut`), at `thunderCue`
    (`thunderVolume`, 1 / (1 + (d / 700)²), fading out over the hearing's last quarter, times what
    the near thunder's voice keeps 8 blocks off, `rolloff` 0.85, so it is never louder just past
    Near; `InCloudVolume` 0.7 for a cloud flash), `thunderPitch` (up to 25% lower and longer), `muffle`
    (highs −10 dB and mids −2.5 dB every 256 blocks past Near, floors −40 / −15, lows +2 dB by
    1024: the air takes the highs, 33 dB a km at 4 kHz, under 1 below 250 Hz), an echo from 768
    blocks (0.8-1.8 s later, 0.55 as loud).
  - Rain: every 0.25 s the rain level (`rainLevel`: the rain sound's) at 4 rings (24-168 blocks)
    × 8 directions around the camera, snapped to 8 blocks for the column cache, where rain falls
    by the biome (`hiss`: the loudest, weighted 1 / (1 + (r / 64)²), and its side, shorter when
    it falls all around), `hissVolume` fading as the rain at the camera takes over, underground
    (sky exposure) and under a roof (`PrecipitationView.roofed`: the camera column's rain floor
    above it; `Roofed` 0.5 of it), smoothed over 1.2 s, played on `SoundPlayer.newBed`'s looped
    `weather.rain.far`, muffled (`hissMuffle`: mids −4, highs −14 dB; under a roof −8, −24).
  - Cost (Lune, interpreted / native): a 2048 reach's 35 × 35 grid 1.5 / 0.5 ms a period to
    sample and 0.9 / 0.4 ms to roll under /weather thunder (0.1 in random weather, none clear);
    Ultra's 67 × 67 5.1 / 1.9 and 3.5 / 1.5 ms. All spread over the period before: at 60 fps 3
    rows a frame at 2048, 2 at 4096 (99% of frames under 0.2-0.5 ms interpreted), at 15 fps 4
    and 6; ready before its period from 5 fps up.
- *F3*: the weather at the camera (kind, precipitation, thunder, cover), the wind and where it
  blows, the weather clock and an override's share; the cloud parts and rings (and parts still to
  place), the strips drawn and the near bolts showing; the distant flashes a minute expected in
  reach and shown in the last minute, distant flashes showing, distant sounds playing and the
  distant rain's volume.

**The maps' weather mode** (`Map/WeatherMap`, pure; `Map/WeatherLayer`): one switch for both maps
(the Weather Map key binding, B, or their cloud buttons) and one forecast step (Now, +2, +5, +10,
+20 minutes, the world map's buttons; the minimap shows the step chosen). The field is
deterministic, so a forecast is just `Weather.momentAt(state, now + seconds)`, the override as it
will be then included. Each map has a small EditableImage (48 or 96 cells square) stretched over
the grid it was painted for, between the terrain and the markers. Cells are powers of two of
blocks, so the view and 4 cells of margin fit; the grid's corner sits on multiples of the margin,
so the map pans that far before it is painted again. A cell's colour: clouds a grey veil, rain
blue, snow white (by the cell's biome and ground height, up to 96 new columns looked up a frame,
rain until known), thunder purple with yellow speckles where it is over half; clear cells are
see-through. A picture is painted a band of rows a frame (at most `Map.CellsPerFrame`, 1536
cells, ~1.1 ms with native code; and as many rows as `Map.FrameMs`, 0.75 ms, holds at what the
last band cost a cell, `WeatherMap.bandRows`, the columns' lookups stopping at that time too: run
interpreted, about 3 times slower, a picture takes more frames, never more of a frame; the world
map's 96 × 96 picture is 7.8 ms in all with native code) at the moment it started,
into a buffer of its own, and kept per step, so switching steps back costs nothing; it is painted
again after `Map.RefreshSeconds`, when the map panned past its margin or zoomed, and when the
server's weather changed. Until a new picture is done the last one stays, placed on its own grid.
The wind (speed and compass point) and its arrow show with the step.

Not done: snow layers piling up and cauldrons filling (the game has no snow layer or cauldron
blocks), charged creepers and skeleton horse traps; rain splashes (Minecraft's rain particles on
the ground) and the sky box's own greying (Roblox's sky can't be tinted by a property, so the
picture is graded instead); real rain, snow and thunder textures and sounds (stand-ins, set in
Config and SoundList).

## Game modes (`GameMode`, server `Players/GameModes` and `Players/GameModeRules`)

Minecraft 1.20.1's survival, creative, adventure and spectator (GameType). A player's mode is the
Player attribute `IceVoxelGameMode` (`GameMode.ATTRIBUTE`), set by the server
(`Gameplay.DefaultGameMode` on joining) and replicated to every client.

### Abilities (`Shared/GameMode`)

Code never compares modes: it asks what one allows, `GameMode.<ability>(mode)` or
`GameMode.<ability>Of(player)`, as GameType.updatePlayerAbilities gives them:

| Ability                                 | Survival | Creative | Adventure | Spectator |
| --------------------------------------- | -------- | -------- | --------- | --------- |
| `mayFly`                                |          | yes      |           | yes       |
| `alwaysFlying`, `noClip`, `isSpectator` |          |          |           | yes       |
| `instabuild`                            |          | yes      |           |           |
| `invulnerable`                          |          | yes      |           | yes       |
| `mayBuild`                              | yes      | yes      |           |           |
| `isSurvivalLike`                        | yes      |          | yes       |           |
| `canPickUp`, `canInteract`, `showsHud`  | yes      | yes      | yes       |           |

- `instabuild` is what "creative" means everywhere else: instant breaking, nothing used up, worn
  or dropped, the item selection, creative slots and middle-click clones, operator blocks. Every
  `creative` parameter (`Menu.apply`, `EditRules`, `UseRules`, `InventoryState.apply`) is this
  ability. `GameMode.isCreative(player)` is kept for older callers.
- `mayBuild`: breaking, placing and using items on blocks. `isSurvivalLike`: hearts and armour.
  `canInteract`: slot clicks, drags and drops (spectators open menus read only). `showsHud`: the
  hotbar and the held item's name.
- `ALL` lists the modes by Minecraft's GameType id (0 survival, 1 creative, 2 adventure,
  3 spectator; `id`, `fromId`), `ORDER` the switcher's (Creative, Survival, Adventure, Spectator).
  `parse` reads `survival` / `s` / `0`, `creative` / `c` / `1`, `adventure` / `a` / `2` and
  `spectator` / `sp` / `3` in any case; `displayName` gives "Spectator Mode".
- `Inventory/Menu.allows(action, mode)` says what a mode may do in a window: spectators only select
  a hotbar slot and close windows (Minecraft's handleContainerClick sends a spectator the menu
  again instead of clicking), and creative actions need instabuild. The server and the client's
  prediction both check it before `Menu.apply`.

### Switching (`Players/GameModes`; the pure rules in `Players/GameModeCommand`, tested)

- `/gamemode <survival|creative|adventure|spectator> [player]`, alias `/gm`, with the modes as
  `parse` reads them: `TextChatCommand`s created by the server, whose `Triggered` fires on the
  server; the legacy chat falls back to `Player.Chatted`. `player` is a name, display name or
  unique prefix, `@s` or `@a`.
- Permissions: `Gameplay.GameModeCommand` (true / false / user ids) for one's own mode; the
  operators' permission (`Players/Operators.permitted`: operators, among them `Gameplay.Admins`,
  the game's owner and Studio; everyone in a world with Allow Commands) for other players' and for
  their own even where the command is off (`mayChangeOwn`, Minecraft's permission level 2). A
  group game's owner is looked up once per server (GroupService); a failed lookup is tried again
  after 5 s, doubling up to 300 s (Players/Operators makes the owner an operator once it works),
  and every change of a player's operator status updates their permission (`Operators.changed`).
- The server tells each client whether it may change its own mode: the attribute
  `IceVoxelGameModePermission` (`GameMode.mayChangeOwn`), set on joining and refreshed on every
  command, switch and change of operator status. Clients refuse `F3` + `N` and `F3` + `F4`
  themselves with it.
- The previous mode, `IceVoxelPreviousGameMode` (`GameMode.previousOf`), changes only when the
  mode does (`previousAfter`; none until the first change), as Minecraft's client keeps it
  (MultiPlayerGameMode.setLocalMode; the server's copy is bug MC-259571, which Paper fixes the
  same way). `F3` + `N` and the switcher read it.
- The switcher and `F3` + `N` send `SetGameMode` (a GameType id). The server answers it like the
  command (`switchOwn`: the same permission and answer) and does nothing at all when the player is
  in that mode already; at most 4 a second per player (a token bucket).
- Answers ("Set own game mode to Spectator Mode"; the other player reads "Your game mode has been
  updated to ...") are `Notice` messages, shown in the chat by `Net/Notices`. `GameModes.changed`
  fires `(player, mode, previous?)`. Inventories stay as they are when the mode changes, as in
  Minecraft.

### On the server (`Network/EditRules`, `Players/GameModeRules`, pure, tested in `GameModesServer`)

- **Edits** (`Network/ServerNet`). Survival and creative players break and place
  (`EditRules.mayEdit`, mayBuild); an adventure or spectator player's edit is answered with the
  real block, and a placement is still acknowledged, so the client's prediction is undone. Only
  survival players' `Mine` messages count (`minesOverTime`), and a delayed survival break is
  dropped (the block sent back) once the player's mode no longer mines over time. Spectators never
  keep a block from being placed (`blocksPlacing`, Minecraft's Level.isUnobstructed).
- **Items on blocks** (`Players/ItemUse`): the Configurator and buckets need mayBuild
  (`mayUseItemOn`), so adventure and spectator players use nothing; their UseItem gets no answer.
- **Menus** (`Players/Inventories`). A Use on a block with a menu opens it in every mode, as
  ServerPlayerGameMode.useItemOn opens a spectator's MenuProvider. Every inventory action goes
  through `InventoryState.applyAs` (`Menu.allows`): what the mode does not allow changes nothing
  but is acknowledged, so the snapshot rolls the prediction back. Spectators are quiet viewers
  (`opensContainers`; `Containers`' `addViewer(..., quiet)`, ChestBlockEntity.startOpen skips
  them): they get the container's snapshots, but no lid opens or sounds for them, and `onOpeners`
  counts openers, not viewers. A mode change does not close an open window.
- **Pickups**: never by spectators (`picksUp`): Entities leaves them out of the pickers, and the
  pickup handler takes nothing.
- **Damage** (`Players/Characters`). While a player is in creative or spectator (`invulnerable`)
  their character holds an invisible ForceField named `IceVoxelInvulnerable`, updated on spawning
  and whenever the mode attribute changes; `Humanoid:TakeDamage` respects it (setting `Health`
  directly still hurts, like Minecraft's /kill). Falls hurt survival and adventure players
  (`fallDamage`: `ceil(distance − 3)` half hearts, none for players who may fly). Players in a
  wall suffocate (`inWall`, LivingEntity.baseTick): every `IN_WALL_INTERVAL` (0.5 s) a living
  player whose eyes are in a solid, opaque block (`PlayerPhysics.isInWall`, Entity.isInWall: a box
  0.48 wide at the eyes; unloaded blocks never count) loses `IN_WALL_DAMAGE` (half a heart),
  scaled to `MaxHealth`, so 20 health lasts 10 s. The server can't see the client's pose, so the
  eyes of all three poses (standing, crouching, crawling) must be in a wall: crouching or crawling
  under blocks never hurts. The feet come from the character (`Rig.feet`), the blocks from the
  server's generated chunks only; not creative or spectator players. So a player who leaves
  spectator inside rock (or is buried in sand) isn't walled in for good. Lava hurts and burns
  survival and adventure players only (`Players/Burning`: creative and spectator players' burning
  is put out at once; see Fluids).
- **Death**: spectators drop nothing and keep their inventory (`keepsInventory`,
  ServerPlayer.die); everyone does with `Gameplay.KeepInventory`.
- **Sounds**: spectators make no hurt, death, burn or extinguish sound and open no chest lid
  (`makesSounds`).
- **Spectator teleport** (`Players/Teleport`). `SpectatorTeleport` (the spectator menu's
  "Teleport to Player", Minecraft's handleTeleportToEntityPacket) moves a living spectator's feet
  to another player's exactly (`spectatorTeleport`: only a spectator, not to themselves, the
  target in the game with a character, at a finite spot within `Protocol.MAX_COORDINATE`
  sideways, the height kept between `PlayerPhysics.NO_CLIP_MIN_Y` (0) and `NO_CLIP_MAX_Y`
  (`WorldHeight` + 64)), without a safe spot search (`Characters.teleportFeet`), at most one
  every 0.25 s. Other spectators are valid targets, as on Minecraft's server. The spectator keeps
  their own view direction, and refusals send nothing back.
- **Operator blocks** (`Structures/Permission`): instabuild players only (canUseGameMasterBlocks),
  so never adventure or spectator players.

Spectators' movement is `PlayerPhysics`' (see Movement: Spectators).

### On the client

Client modules ask Shared/GameMode's abilities of the local player's mode
(`ClientInventory.mode()`); none compares modes.

- **Debug keys** (`Debug/DebugKeys`, pure, tested; `Debug/DebugOverlay` feeds it the keyboard).
  Minecraft's KeyboardHandler: `F3` toggles the overlay when it is let go, unless a combination
  ran while it was held (handledDebugKey) or a screen is open. `F3` + `N` asks for spectator, or
  from spectator for the previous mode (Creative when there is none); `F3` + `F4` opens the
  switcher; `F3` + `Q` lists the three in the chat. Combinations run only while no screen and no
  switcher is open and the player isn't typing (a focused TextBox or chat bar), and `N` and `F4`
  only with `GameMode.mayChangeOwn` (else "[Debug]: Unable to switch game mode; no permission" or
  "... open game mode switcher; no permission"). The "[Debug]:" prefix is bold yellow
  (`Notices.debug`; white in the legacy chat). A key that ran a combination does nothing else:
  `F3` + `Q` throws nothing (BlockInteraction ignores `Q` while `F3` is down). Losing the window's
  focus forgets that `F3` was held. `F3` is the Debug Screen key binding: DebugOverlay hands
  DebugKeys whatever key it is bound to as "F3" (and F3 itself, rebound away, as nothing), so the
  combinations become that key + `N` / `Q` / `F4`; the switcher closes when that key is let go.
- **The switcher** (`Ui/GameModeSwitcher`; its model `Ui/ModeSwitch`, pure, tested): Minecraft's
  GameModeSwitcherScreen at its offsets from the screen's centre, scaled like the HUD. Four slots
  in `GameMode.ORDER` (a grass block and an iron sword from ItemIcon, a map and an ender eye in
  pixel art) on a dark translucent box, the highlighted mode's name above them and "[ F4 ] Next"
  under them. It opens on the previous mode (else Survival from Creative, Creative otherwise).
  `F4` steps on, wrapping round (DebugOverlay passes it on while the switcher is open); the mouse
  highlights the slot it moves onto, but not one it rested on when the screen opened or `F4` was
  last pressed, and clicking does nothing more, as in Minecraft. Every frame it checks that `F3`
  is still down: once not, it sends `SetGameMode` for the highlighted mode unless that is the
  current one, and closes. Escape (Roblox's menu), an inventory screen opening or respawning
  close it without switching. While it is shown, a Modal button frees the mouse and takes the
  clicks, and it has the keys like a Minecraft Screen: the player stands still
  (MovementController), the hotbar's and spectator menu's keys and the wheel do nothing
  (`Hud.setInputTaken`), and neither do BlockInteraction's buttons.
- **HUD** (`Ui/Hud`). Hearts, armour and the knowledge bar show in `isSurvivalLike` modes (survival, adventure), the
  held item's name higher above them; without `showsHud` (spectators) there is no hotbar, item
  name, hearts or armour, and the spectator menu takes the hotbar's place.
- **The spectator menu** (`Ui/SpectatorGui`; its model `Ui/SpectatorMenu`, pure, tested):
  Minecraft's SpectatorMenu and SpectatorGui, drawn with the hotbar's bar and selection frame. A
  spectator's number key, middle click, gamepad L1 / R1 or the touch "…" button opens its root
  page; then a number selects a slot and the same number again (or the middle click, gamepad
  D-pad up, the "…" button) uses it; a click or tap on a slot is its number. Slot 1 "Teleport to
  Player" (enabled while there is someone to teleport to) lists the other players who are not
  spectating, by user id, as they were when the menu opened, with their head shots: slots 1-7,
  then 6 a page after "Previous Page"; 8 "Next Page" (dimmed on the last page) and 9 "Close Menu"
  on every page. Using a player sends `SpectatorTeleport`; the menu stays open, as in Minecraft.
  Enabled items show their number, the selected item's name (or the page's prompt) shows above
  the bar, and the menu fades 3 s after the last key (a CanvasGroup) and closes after 5.
  "Teleport to Team Member" is left out: the game has no teams. While the menu is open the wheel
  (and L1 / R1) moves the selection, skipping empty and dimmed slots; while it is closed the wheel
  changes the flying speed (`SpectatorGui.onFlyingSpeed`, which MovementController turns into
  `PlayerPhysics.scrollFlyingSpeed`).
- **Interaction** (`Interaction/BlockInteraction`). Breaking, placing and using items on blocks
  need `mayBuild`, instant breaking `instabuild`, and only survival mines over time. Menus open
  in every mode (operator blocks' screens with instabuild only). Adventure players' left click
  only swings the arm, and no block is outlined (Minecraft outlines blocks in adventure only for
  items with CanDestroy / CanPlaceOn tags, which the game has none of); WAILA still names them.
  Spectators aim at and outline blocks with a menu only (the aim passes through the rest), open
  them with a right click, never swing, throw nothing, and their middle click is the spectator
  menu's. A spectator's left click on a player (another player's standing hull on the aim, in
  reach, not behind a block, not a spectator, not the one already spectated) spectates them.
  Spectators never keep a block from being placed, on the client either.
- **Spectating a player** (`Player/MovementController.spectate`, `spectating`). The camera's
  subject becomes the target's Humanoid, in first person, with its CameraOffset set locally every
  frame to their eyes (standing, or lying as far as the body is pitched: their own client's
  offset and pose never replicate); the hull is put at their feet every frame, so chunks stream
  around them. Sneaking, a teleport, a game mode change or the target dying or leaving ends it
  where the target was, and the camera comes back. Clicking another player switches to them
  (ServerPlayer.attack's setCamera). The view stays free (Minecraft locks it to the target's),
  and the server only sees the spectator's invisible character move with the target.
- **Inventory** (`Inventory/ClientInventory`, `Prediction`). Actions go through `Menu.allows`
  before they are predicted or sent, so a spectator's clicks, drags, drops and creative actions
  never leave the client, and spectators pick no blocks. `Prediction` takes the game mode and does
  what the server does (`Menu.allows`, then `Menu.apply` with instabuild); pending actions replay
  by the new mode's rules after a change. `E` opens nothing for spectators, and the item
  selection needs instabuild, so adventure gets the survival inventory. Switching to spectator
  closes one's own inventory (and the item selection), while a block's window stays open, read
  only, without JEI's recipe transfer.
- **Seeing spectators** (`Player/SpectatorView`; the rules in `Player/SpectatorRules`, pure,
  tested). Every frame after the camera, a spectator's parts, the decals on them (the face) and
  their effects (`SpectatorRules.HIDDEN_CLASSES`) get LocalTransparencyModifier 1 for players who
  don't spectate, and their name and health display is hidden (DisplayDistanceType None, locally);
  spectators see the head and what is worn on it at 0.85 (Minecraft's alpha 0.15). Values are
  only ever raised above what the camera's first person fade set, and put back once the player
  stops spectating. Spectators hold nothing (`Player/HeldItems`, which also hides any player's
  held item while the camera fades their head: one's own in first person, and the spectated
  player's), have no minimap dot where they are hidden (`Map/Minimap`) and make no movement
  sounds (`Audio/MovementSounds`: none from any spectator, this player included). WAILA and a
  spectator's click never aim at a spectator or at the player being spectated
  (`SpectatorRules.aimable`).
- **WAILA** for a spectator: blocks with a menu (all BlockInteraction aims at) and players; no
  dropped items or fluids.
- **Structure outlines** (`Rendering/StructureBoxes`) show with instabuild and to spectators, as
  in Minecraft.

## Items and inventories

What each game mode may do with items and inventories is in Game modes, above.

**Items** (`Items`). Every placeable block is an item with the block's id. Other items (`ItemList`:
the 20 Minecraft armor pieces, sticks, coal, raw ores, ingots, nuggets (Minecraft's and Mekanism's
osmium), gems, snowballs, the 25 tools and Shears, buckets) have ids from 4096 up. What an item
leaves behind when a recipe or a furnace uses it up is `Items.craftingRemainder` (Minecraft's
getCraftingRemainingItem): the empty Bucket for each full bucket (Water, Lava, Oil, Fuel; one per
fluid of Shared/Fluids, checked at load). A stack is `{ item, count, damage }`, at most `maxStack`
(64; armor and tools 1, snowballs 16); `damage` is a tool's wear (`durability`: wood 59, stone
131, iron 250, diamond 1561, gold 32, shears 238). Blocks say how long they take to mine
(`hardness`), which tool harvests them (`tool`, and `toolLevel` when only that tool of that tier
or better drops anything: iron and osmium ore need stone, diamond, gold and emerald ore iron),
what they drop (`drops`, `dropCount`: snow gives 4 snowballs; `shearDrops`, `shearCount`: what
Shears get instead), what right click opens (`menu`) and how many slots they hold (`container`).
An item of ItemList may place a block that is no item of its own (`places`, Minecraft's
ItemNameBlockItem: Mint Leaves plant Mint, Ginger Root Wild Ginger): its `block` is that block,
so the client places it as a block item (with the item's own model in hand and in slots), and
`Items.ofBlock` answers the item for the block, so the block drops it, pick block takes it and
the server's placement uses it up (`EditRules.mayPlace` takes any block `ofBlock` answers).
Asserted at load: the block exists, is not `placeable`, has no `item` and only one item places
it.

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

`Menu.apply(window, action, creative)` performs one action (`creative`: the instabuild ability;
whether a game mode may do it at all is `Menu.allows`, checked first on both sides), ported from
Minecraft 1.20.1's `AbstractContainerMenu.doClick` and `Inventory.add`:
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
next tier keeps its charge. A shapeless recipe's `keep` names an ingredient it lists once (the
matching tells which stack took it). A result that wears (Items `durability`) takes the kept
stack's wear too: a part-drunk Dirty Water Canteen cured with Mint Leaves keeps its sips. Other
results carry none.

**Chests, crafting tables and furnaces** (`Players/Containers`, `InventoryState`):
- `Use` on a block with a `menu` (reach-checked) opens it as window 1–255, in every game mode
  (spectators read only and as quiet viewers: see Game modes). Chests and furnaces are
  contents per block position, created on first use and shared by everyone who opens them (each
  viewer's snapshot includes the shared container). A crafting table gives each player a grid of
  their own, which goes back into their inventory when they close it.
- A window closes when the player walks away, dies or leaves, or when the block changes.
- Breaking or replacing the block drops what it holds (`world.onChanged`).
- Furnaces (`Crafting/Smelting`, Minecraft's AbstractFurnaceBlockEntity tick) run at 20 Hz on the
  server, whether or not anyone is watching: a fuel item lights the furnace for its burn time
  (coal 1600 ticks, planks and logs 300, sticks 100, a Lava Bucket 20 000, the fluids' records'
  `furnaceFuel`, which leaves the empty Bucket in the fuel slot; oil and fuel are no furnace fuel,
  as furnaces burn solid fuels only) when there is something to smelt that fits the output, an item
  takes 200 ticks, progress falls back when the fire goes out. Only furnaces that are doing
  something are ticked (`Containers.tickFurnaces`). Viewers get a snapshot when the slots change,
  and every other tick while only the gauges move. Every 10 ticks the furnaces whose output holds
  something (`Containers.ejectingFurnaces`) push it into the chests next to them
  (`Transmitters/Eject`, below).

Death drops the whole inventory (unless `Gameplay.KeepInventory`, or the player was spectating).
Inventories and chests live for the session.

**Screens** (`Ui/`), old-school Minecraft styled from Frames only (gray beveled panels, inset slots,
the Arcade pixel font):
- `Hud`: the hotbar (1–9, the wheel unless the Scroll Wheel setting makes it zoom, L1 / R1, taps;
  on touch screens the "…" inventory button at its end and the Options gear at its start), the
  held item's name, and hearts and armor in survival and adventure; spectators get the spectator
  menu in the hotbar's place (see Game modes). Roblox's health bar and backpack are turned off.
  The GUI Scale setting caps Minecraft's automatic scale (`Style.setScaleOverride`; scaled GUIs lay
  out again on `Style.scaleChanged`).
- `InventoryScreen` (`E`; spectators have none): the armor column on the left with a character
  preview, the 2 × 2 crafting grid and its result at the top right, the 27 slots and the hotbar. An
  open block's panel sits above it (`Ui/MenuLayout`, Minecraft's coordinates): a chest's rows, a
  crafting table's 3 × 3 grid and result, or a furnace's input, fuel and output with the flame and
  arrow gauges from the furnace's `data`. Worn tools show Minecraft's durability bar, and machines'
  items that hold energy an energy bar in its place. A gear where Minecraft's recipe book button
  is opens the Options menu.
- `CreativeScreen` (`E` with instabuild, in creative): the "Item selection" picker, a search box
  that filters `Items.search` as you type, an 8-column scrolling grid, and the hotbar under it.
  Clicking an item gives a full stack; dropping a stack on the grid deletes it.
- `SlotClicks` turns mouse, keys, touch and gamepad into Minecraft's click actions (pure, tested).
- `Screens` opens and closes them, frees the mouse (in first person too) and stops the character
  while one is open. Other modules' screens (the structure block and jigsaw screens, the Options
  menu) are shown as panels (`showPanel`, `closePanel`) with the same darkened world and free mouse
  but none of the inventory's input.

**Item icons and models** (`Rendering/ItemModels`, `Ui/ItemIcon`). An item's model is a cube with the
block's look (the terrain's part template: material and colour, or with textures one image per
textured face, see Texture pack), or the item's boxes. Icons show it in a ViewportFrame, lit so
the top is brightest, then the left face, then the right. They are built once per slot and only
rebuilt when the item changes, or a few a frame after item looks change. The same models are
dropped items and, in `Player/HeldItems`, the item in each character's hand (from the
`IceVoxelHeldItem` attribute the server sets) and in the first person corner. Tools and sticks lie
diagonally in icons (`tilt`) and are held by the handle, pointing forward. Plants are shaped-block
items: icons from the front, held upright like blocks, dropped like items, drawn untinted (the
Grass block's green); a tall plant shows its `icon`, the lower half plus the top's look in one
cell, and a plant with a sprite shows the sprite on an upright plane instead. Shears are a tool:
diagonal in icons, held by the handles.

**Decorated blocks** (`Rendering/BlockDecor`). Chests, crafting tables, furnaces, the Creative
Energy Cube, the Heat Generator, the Electric Furnace, the Batteries, the Oil Refinery (a light
steel casing with an oil and a fuel sight glass on each side and two tank caps on top), the
Combustion Generator (dark steel, amber fuel stripes, a chamber window low on each side and an
exhaust on top), structure blocks (Minecraft's dark purple block with the mode's sigil on every
face) and jigsaws (the puzzle piece on the front, the lock towards the top, arrows on the other
sides, turned per orientation) are drawn without image assets from pure face data (rectangles on a
16 × 16 grid per face): in the world as SurfaceGuis on their parts' templates (recycled parts keep
them; they stop drawing beyond 96 blocks), and on item models as thin raised slabs, since
ViewportFrames don't draw SurfaceGuis.

**Light sources and shaped blocks** (`Blocks`, `Rendering/PartPool`, `Behaviours/Attached`).
Blocks may give off light (`light`, Minecraft's 0..15: torches 14, lanterns and the Glow Block 15;
`Blocks.lightLut`) and may be drawn from boxes instead of a cube (`shape`: pixels from the cell's
centre, turned with CFrame.Angles). Shaped blocks render like glass (they hide no neighbour and no
opaque box runs through them). Shaped and lit blocks are meshed one box per block
(`Blocks.singleLut`), lit fluids excepted: a lava sea is a sheet of merged boxes with sparse
lights. The renderer draws one part per shape box, each from its own template. The glowing box's
near template (the Glow Block's cube) carries one PointLight: range light × 0.9 blocks, warm colour.
A light inside a part that casts a shadow is hidden by that part, so one of the two gives way:
- torches' and lanterns' boxes cast no shadow (they are small, so it hardly shows), and their
  light has shadows when `Render.Shadows` is on, so it stops at walls;
- the Glow Block's cube casts one like any opaque cube, so a roof of them keeps the sun out; its
  light has no shadows instead and also reaches the far side of a wall within its range (lights
  just outside each face would need up to six per block, placed by its neighbours, which shared
  templates can't do).

There is no light field in the block data; Roblox's lighting engine does the rest. Glow lichen
(light 7), fire (light 15) and lava (light 15, in every level) are the exceptions to one light per
block: only some of their cells carry one (see Meshing and Rendering).

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
- Herbs (Tough As Nails' Mint and Wild Ginger, appended after the TNT and the Nuke) are plants
  on the dirt set like the flowers, but `placeable = false`: no item of their own. The herb item
  places them (ItemList `places`, Minecraft's ItemNameBlockItem, below) and is their drop, and
  they spread (`Behaviours/Herb`).
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
block modes, the structure void and the twelve jigsaws. Survival players can't mine them (adventure
and spectator players break nothing at all)
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
0.2, mined fastest with an axe. It drops 2 Glow Dust (the game's blue glowing dust, which stands
in for glowstone and Mekanism's redstone in recipes; also when its wall goes or water washes it
away), or itself with Shears (`shearDrops`, Minecraft's only drop; Shears mine it at 2,
`shearSpeed`, Minecraft's ShearsItem.getDestroySpeed); replaceable and `brokenByFluid`. The block
of 4 Glow Dust is the Glow Block (formerly Glowstone: `Blocks.RENAMED` / `Items.RENAMED` keep
structure data that names Glowstone or GlowstoneDust working). Its shape is
a 13 × 13 pixel plate a tenth of a pixel off its face and a 3 × 3 pixel Neon speck, the `glow` box
that carries the light: two boxes, two parts. Its outline is a pixel thick plate over the face.

**Cave twins** (BlockList `caveTwin`): CaveGlowLichen and its five sides, the lichen generation
puts in caves, and CaveLava and CaveOil, the lava of the caves' lava seas and underground lakes
and the oil of buried deposits (see Fluids). A twin looks, drops and behaves exactly like its twin
(same appearance, item, support, light, hardness, drops and behaviour; a fluid twin is a source of
the same group, level and tick delay; checked at load), but counts as cave air while caves are
hidden (`cullLutHiddenCaves`, `caveTwinLut`; see Meshing), as CaveAir is to Air. Players never
place one: twins are no variants of their item (`placementFor` never returns one, EditRules
refuses them, `Blocks.fluidId` never answers one, so a bucket pours an ordinary source),
`Blocks.rotate` keeps a twin a twin, and `Blocks.surfaceForm` turns a twin into its twin and
CaveAir into Air when a structure is saved (`caveTwinOf`, `caveTwinFor`, `isCaveTwin`).

**Obsidian** (Minecraft's): what water makes of a lava source (see Fluids). Hardness 50, a diamond
pickaxe or nothing (`toolLevel` 3: 9.4 s; 250 s by hand, for no drop); it drops itself.

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
  is an Advanced Fluid Tank made from a tank holding a fluid), except a recipe's kept ingredient's
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
they were added; other keys show nothing (Minecraft hides NBT). "fluid" ("Lava: 12,000 mB", with
`amount`; names from Shared/Fluids) and "energy" ("Energy: 1.2 MJ") are built in, and each
machine tank's name gets one (Shared/Machines: "Oil: 3,000 mB"); `Items.addDescriber(key, fn)` adds
or replaces one (a failing one is skipped). `formatEnergy` is Mekanism's short form (J, kJ, MJ, GJ,
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
`restoreTank` fills the placed tank (whole mB, at most its capacity, fluids tanks carry only:
`Fluids.carriable`) and marks it dirty, so its Tanks record follows the edit to clients. Machines
keep their energy, their kind's `keep` fields and every fluid tank the same way
(`MachineWorld.blockDataHooks`, `Machines.save` / `restore`).

## Fluids (`Fluids/`, server `Behaviours/Fluid`, `Players/Burning`)

Water, lava, oil and fuel. Everything that holds or tells fluids apart asks Shared/Fluids instead
of naming water: blocks, buckets, Fluid Tanks and pipes, machines' tanks, the protocol, movement,
item physics, burning, the view from inside a fluid, sounds, WAILA and JEI.

**The registry** (`Fluids`, its data in `Fluids/FluidList`). Fluid ids are u8 list positions and
append only (they are sent and saved in items): 0 none, 1 water, 2 lava, 3 oil, 4 fuel (`COUNT`).
A record holds its BlockList group (`name`: the blocks <name>, <name>Flow1..7 and <name>Falling),
its blocks (`source`, `caveSource`), full bucket (`bucket`), `color`, `light`, movement (`physics`
"water" or "lava": the branch of Minecraft's LivingEntity.travel and the fluid tag it belongs to;
`drag`, `push`, `swim`), harm (`damage` every `damageInterval` ticks, `burnSeconds`,
`extinguishes`), `furnaceFuel`, `carriable` (all four), fog (`fogColor`, `fogStart`, `fogEnd`) and
bucket sounds (`fillSound`, `emptySound`). Lookups: `get`, `name` ("Empty" for 0), `find`,
`isValid`, `ofBlock` and `blockLut` (u8 per block, every level and the cave twins: ~7 ns read
directly, ~90 ns through `ofBlock`, interpreted), `isSource` (what an empty bucket takes, twins
included), `sourceOf` (what a bucket pours: never a twin), `caveSourceOf`, `bucketOf`, `ofBucket`
(0 for the empty Bucket) and `carriable`. FluidList is plain data that Items and
Crafting/Smelting read; the registry requires Blocks and Items and checks at load that every
fluid group of BlockList is a fluid here, with this colour and light, and that every fluid has a
bucket item of its own.

| Fluid | Slope, drop off, infinite, tick | Light | Moves like (drag, push)   | Harm                         | Fog (blocks)    | Furnace       |
| ----- | ------------------------------- | ----- | ------------------------- | ---------------------------- | --------------- | ------------- |
| Water | 4, 1, yes, 5                    | 0     | water (0.8, 0.014), swims | puts burning out             | -8..96 x vision | -             |
| Lava  | 2, 2, no, 30 (flows 3)          | 15    | lava (0.5, 0.0023)        | 4 every 10 ticks, burns 15 s | 0.25..1         | bucket 20 000 |
| Oil   | 2, 1, no, 20 (flows 7)          | 0     | lava (0.5, 0.0023)        | -                            | 0..2            | -             |
| Fuel  | 4, 1, no, 5 (flows 7)           | 0     | water (0.8, 0.014), swims | -                            | -8..32          | -             |

**Blocks.** BlockList's `fluid(group, spec, tickDelay)` makes a group's nine blocks with one
appearance: lava Neon orange, light 15 in every level; oil nearly black glass that barely shows
through and shines; fuel translucent amber. Then `caveFluid` adds the cave twins CaveLava and
CaveOil (see Items and inventories: Cave twins), and Obsidian follows. The fluid blocks are 167 to
195 and Obsidian 196 (ids are list positions: append only).

**Flow** (`Behaviours/Fluid`; `RULES` per group: slope distance, drop off, infinite sources and
whether what it washes away burns; the tick delay is BlockList's). Every group runs water's
machinery (FlowingFluid.getSpread with its own slope distance, see Movement: Fluids and the
player) and must have rules (a group without them fails at load). Different fluids never flow into
each other; only lava and water meet, as in Minecraft 1.20.1 (LiquidBlock.shouldSpreadLiquid,
LavaFluid.spreadTo):
- lava with water above it or beside it (not below) hardens: a source (its cave twin too) into
  obsidian, flowing or falling lava into cobblestone. Minecraft does it the moment the water
  arrives; here the neighbour change schedules the lava's tick 1 tick later instead of 30;
- lava pouring down into water (any level) turns that water into stone;
- each hisses (LiquidBlock.fizz: `block.lava.extinguish`, played by the server).

Lava burns what it washes away (torches and plants: no drop, a hiss;
LavaFluid.beforeDestroyingBlock); water, oil and fuel drop it. A cave twin is a source of its group
in every way, and what flows out of one is ordinary fluid. Generated lava and oil are sources at
rest until something next to them changes. From one source on flat ground (interpreted): water
covers 113 cells and settles in 2 s, lava 25 in 6 s, oil 113 in 8 s. Left out: lava's random
slower spread, lava looking through water for its way down, fire and basalt.

**Burning** (`Players/Burning`, pure, tested in LavaOilServer): Minecraft 1.20.1's Entity.baseTick
(burning, lavaHurt), LivingEntity.hurt's cooldown and ItemEntity's health, with each fluid's
record.
- `touching(getBlock, box)`: a bit per fluid id reaching into a box (deflated by 0.001, as
  Minecraft does): a fluid cell overlapping it whose surface (the whole cell when the same fluid is
  above, else its level's height) is at or above the box's bottom. Unloaded cells touch nothing.
- Players (`tickPlayer`; Players/Characters runs it at 20 Hz on the standing box at the feet, as the
  server can't see the pose, against loaded blocks): a fluid that `extinguishes` (water) puts
  burning out (entity.generic.extinguish_fire); burning costs Fluids.BURN_DAMAGE (1) every
  BURN_INTERVAL (20) ticks, not while in lava, through armor; a fluid that hurts (lava) sets
  burning for its `burnSeconds` (15 s, 300 ticks) and takes its `damage` (4), softened by armor
  (Items.damageAfterArmor: lava's damage type doesn't bypass armor, so full diamond takes the 4
  down to 0.96). Hurts follow LivingEntity.hurt's cooldown (10 ticks: only a bigger hurt lands,
  and only by the difference), so lava takes 4 every 10 ticks, and a player who leaves it burns 1
  every 20 ticks for 15 s (the first under lava's cooldown) unless water puts it out. It also
  says whether a lava hurt landed (before armor: not under the cooldown, not in creative or
  spectator), when Characters plays the sizzle (entity.generic.burn, Entity.lavaHurt), each sound
  with its own volume and pitch. Creative and spectator players (GameMode.invulnerable) never
  burn: their burning is put out at once. Characters sets the character attribute
  `IceVoxelOnFire` while a player burns (client Player/BurningView), and a new character starts
  out of the fire.
- Items (`tickItem`; server Entities/EntityWorld): ItemEntity's 5 health with no cooldown. Lava
  takes 4 a tick and sets burning, so an item touching lava for a tick is gone the next, with
  entity.generic.burn at each lava hurt (EntityWorld's `burnt`, played by Entities). Nothing is
  fire resistant (there is no netherite).
- Fire blocks (BaseFireBlock.entityInside): `touching` also sets `Burning.FIRE` (bit 30, above
  every fluid's) when a Fire cell overlaps the box, whatever the fire's outline (Minecraft's
  checkInsideBlocks), so Characters and EntityWorld need nothing new. A player in one takes
  `IN_FIRE_DAMAGE` (1) under the hurt cooldown (every 10 ticks; the in_fire damage type doesn't
  bypass armor) with no sizzle; burning goes on a tick more each tick (it never runs down in the
  fire), and a player not burning yet counts up (`heat`, Minecraft's remainingFireTicks below 0
  from -getFireImmuneTicks: 20) and catches fire for 8 s after 20 ticks in it; out of fire and
  lava, not burning, the count starts over (Entity.move), as water does. Items catch at once (their
  immunity is a tick) and lose 1 a tick: gone in a few ticks.
- Status effects (`fire`, Shared/Effects.fireRules, from Players/Effects): Fire Resistance makes
  every fire hurt land as nothing (lava, fire, campfires, burning: no damage, no sizzle, no
  cooldown; burning still counts down and shows), a burn `factor` stretches every burning lava and
  fire set (Oil Coated 2, Fuel Soaked 3), a `bonus` adds to each burning hurt (Oil Coated 1) and
  `ignites` catches fire in a fire block at once; `Burning.ignite(state, mode, seconds, fire)` sets
  burning from outside (a blast reaching a Fuel Soaked player). A burning player does not light
  fuel (only fire and lava blocks do: World/FuelBlast), so a soaked player in burning fuel is in
  its blast, which lights them.
- Campfires (CampfireBlock.entityInside, lit): `touching` sets `Burning.CAMPFIRE` (bit 29; fluids
  must stay below it) for a Campfire cell in the box. A player in one takes `CAMPFIRE_DAMAGE` (1,
  its fireDamage) under the same hurt cooldown, softened by armor, and nothing else: a campfire
  sets nobody alight and doesn't count towards catching fire (it is not in BlockTags.FIRE).
  Items lie in it unharmed (it hurts living entities only).

**Buckets.** The Lava, Oil and Fuel Buckets (ItemList; full buckets stack to 1, the Water Bucket's
model in the fluid's colour) carry their fluids as the Water Bucket does: an empty Bucket takes any
carriable source, twins included (`Fluids.isSource`), a full one pours the ordinary source
(`Fluids.sourceOf`), and both work on Fluid Tanks and machines' tanks (see Mekanism pipes: On the
server). Each fluid's bucket sounds are its record's (lava and oil the thicker
item.bucket.fill_lava and empty_lava, water and fuel the plain ones). A Lava Bucket burns 20 000
ticks in a furnace and leaves the Bucket in the fuel slot (`Items.craftingRemainder`); oil and
fuel are no furnace fuel.

Nobody spawns in lava, oil or fuel or next to lava (`SpawnUnsafeBlocks`: `Body` names the four
fluids, which covers their levels and twins; `Hazards` lava).

## Explosions (`World/Explosion`, server `World/FuelBlast`, `World/Explosions`)

Minecraft 1.20.1's explosions, set off by burning fuel (and `Api.explode`). Tested in
`tests/spec/Explosions`.

**The maths** (`Shared/World/Explosion`, pure; Minecraft's Explosion.explode, finalizeExplosion and
getSeenPercent):
- Blocks (`affected(getBlock, x, y, z, power, random)`): the 1352 points on the surface of a
  16 × 16 × 16 cube give the rays' directions (`RAYS`, in Minecraft's loop order). Each ray starts
  with power × (0.7 + random × 0.6) and steps 0.3 blocks; every step costs 0.22500001, plus
  (resistance + 0.3) × 0.3 in any cell but air. A cell reached with intensity left is affected,
  air included (fire lands there). Rays stop at the world's floor and ceiling and at unloaded
  blocks. Each cell is read once per ray however many steps it holds (the cost is still per step):
  TNT in open air reads about 9,000 blocks (1.7 ms interpreted), power 12 about 26,000 (7 ms).
- Blast resistance is BlockList's `blastResistance` (Blocks `blastResistance`, f32
  `blastResistanceLut`): the hardness unless given (Minecraft's `strength(f)` sets both),
  3,600,000 for unbreakable and creative only blocks, 0 for air, Minecraft's values where they
  differ (`BLAST_RESISTANCE` at the end of BlockList: the stone family and bricks 6, planks 3,
  metal and gem blocks 6, packed mud 3, obsidian 1200). Fluids resist 100 (their hardness), so TNT
  in water breaks nothing (the first step costs 30); fuel 0: it is the explosive.
- Entities (`hit`): within 2 × power of the centre (measured to the feet), impact =
  (1 − distance / (2 × power)) × seen, damage = ⌊(impact² + impact) / 2 × 7 × 2 × power + 1⌋ half
  hearts (TNT point blank 57, half its reach away 22, behind a wall 1), and a push of `impact`
  blocks per tick away from the centre towards the eyes (Blast Protection would soften it;
  nothing is enchanted). `seenPercent` samples the body box every 1 / (2 × size + 1) of it on
  each axis (a player 3 × 5 × 3 points, an item 2 × 2 × 2), shifted to centre them across, and
  counts the points with no solid block on the line to the centre (`VoxelRaycast`).
- `dropChance(power)`: 1 / power (the survives_explosion loot condition). `fireSpots`: one in
  three affected cells (a roll per cell, nextInt(3) == 0) that are air after the blast with an
  opaque block below.

**Fuel catching** (`World/FuelBlast`, pure): fuel (any level, falling too) catches when one of its
six sides is Fire or lava of any level (the cave twin too: `isHot`). `Behaviours/Fluid` asks in
its `onNeighborChanged`, which runs for the fuel itself and for every neighbour's change: so fuel
catches when fire or lava arrives next to it and when it flows next to them. Crude oil does not.
- `measure`: a breadth-first fill through the six sides over the connected fuel, at most
  `Explosions.MaxCells` (4096) cells, never into claimed cells or unloaded chunks. A source counts
  a bucket, a flowing cell its fill ((8 − level) / 8; falling 1) × `FlowingShare` (1/16): flowing
  fluid is a thin sheet Minecraft makes out of nothing, so a bucket's puddle (a source and 112
  flowing cells) counts 3.6 buckets, not 43.
- `power(v)` = `BucketPower` (4) × ∛v within `MinPower`..`MaxPower` (1..12): blast reach scales with
  the cube root of the charge (Hopkinson–Cranz), and Minecraft's power is a reach (entities within
  2 × power, rays through 1.73 × power blocks of air). A bucket is TNT, 4 buckets 6.3 (a charged
  creeper), 8 buckets 8, 27 buckets 12.
- `plan`: the body is cut into `ClusterSize` (4) wide cubes centred on the cell that caught; each
  cube is one blast, at its fuel's weighted centre, with the power of its buckets, `delay` ticks
  after catching: the flood fill distance of its nearest cell / `ChainBlocksPerTick` (1.5). Cubes
  under `MinBlastVolume` (half a bucket) are flashes (power 0). A bucket on the ground: one TNT
  blast, its puddle's thin edge flashing; a 12 × 12 × 2 pool: 16 blasts of power 8 to 12 over 14
  ticks; a 16 × 16 × 4 pool of 1024 buckets: 50 blasts of power 6.3 to 12 over 20 ticks (more
  under the cost bounds).

**Fuses**: only a source that catches explodes (`ignite`). Flowing fuel (any level but 0, falling
too) touching fire or lava is handed to `Explosions.fuse` instead, which turns it into Fire
`FuseTicks` (4) ticks later if it is still flowing fuel no plan claims; that fire touches the
next flowing cells, and so on: the flame runs up a trail of spilt fuel at 5 blocks a second to its
source, which goes off with the whole connected body as above. Flowing fuel is also flammable
(BlockList 100 / 100), so ordinary fire spreads over and eats it; a trail with no source left just
burns away.

**In the world** (`World/Explosions`, on WorldServer; state per world, weakly kept):
- `ignite(world, x, y, z)` queues a cell. `step(world)` (the boot script, every server tick after
  the block ticker) plans at most `MaxIgnitionsPerTick` (4) queued cells, claiming every cell of a
  plan for its blast; claimed cells are skipped by later fills and ignitions, and blasts reaching
  them leave them, so each part of a body goes off once, on its own schedule.
- Then it sets off the blasts that are due, in order: at most `MaxBlastsPerTick` (8), and no new
  one once this tick's rays read `RayBudget` (60,000) blocks; the first always goes, the rest
  wait. A fuel blast first consumes its cube's cells that are still fuel (air; released). Then,
  as Minecraft: the affected cells; the handler (`setHandler`: the boot script's
  `Entities.explode` and `Characters.explosion`) before any block goes, so the blast's own drops
  are spared; the sound (`entity.generic.explode`, Audio/Sounds); every affected non-air block
  becomes air, dropping its items (`Items.leafDrop` or `Items.blockDrops`) with `dropChance`
  through `Behaviours/Drops` (containers spill as for any change); unclaimed fuel among them is
  ignited instead, and explosive blocks go to the primer (`setPrimer`: Behaviours/Tnt lights TNT
  and Nukes with a short fuse, leaves lit ones be); and a fiery blast (every fuel blast) sets Fire on
  its `fireSpots`. Fire next to fuel the plan did not reach (beyond MaxCells, or flowing in later)
  lights it in turn, so huge bodies burn on in chains. A flash consumes its cells and sets fire on
  the same rule. Unloaded chunks stop everything and are never generated.
- `explode(world, x, y, z, power, fiery)` queues a single blast for the next step (`Api.explode`).

**Entities**:
- Items (`EntityWorld.explode`, through `Entities.explode`): an item takes the damage off its 5
  health (gone at 0: any impact over 0.126, so within 7 blocks of TNT in the open); the rest are
  pushed (aimed at 0.85 of their height, Minecraft's eye height) and resynced at once.
- Players (`Characters.explosion`): a living player in reach takes the damage through
  `Burning.hurtPlayer`: the same LivingEntity.hurt cooldown as lava and burning (10 ticks: blasts
  together land only the biggest, a bigger one by the difference, as a pile of TNT does), softened
  by armor (explosions don't bypass it), none in creative or spectator (also their ForceField).
  The box is the standing one at the feet (`Rig.feet`), eyes at 1.62. Every player within
  `EffectDistance` (64) gets an `Explosion` message with the centre, the power and their own
  knockback (zero if out of reach or a spectator).
- The client (`Rendering/ExplosionView`): a Roblox `Explosion` at the centre (radius 0.75 × power
  blocks, at most 8; BlastPressure 0, DestroyJointRadiusPercent 0, no craters: it only draws), the
  knockback to `MovementController.knockback`, and a camera shake (this game's): strength
  (1 − distance / (`ShakeDistance` × power)) × min(1, power / 4), fading over 0.45 s, turning the
  camera by up to 1.6° after Roblox's camera updates.

## TNT and the Nuke (server `Behaviours/Tnt`, `World/Nuke`, client `Rendering/FuseView`)

Minecraft 1.20.1's TntBlock and PrimedTnt, and a mod-style Nuke lit the same way. Tested in
`tests/spec/Tnt`.

**Blocks** (BlockList, at the end): `Tnt` (hardness 0, blast resistance 0, flammable 15 / 100,
BlockDecor "Tnt": red with the sticks' seams, a white band with TNT; texture pack "tnt side / top /
bottom", blank) and `Nuke` (the same numbers, BlockDecor "Nuke": dark steel, hazard stripes, the
radiation sign; "nuke side / top", blank), and their lit blocks `LitTnt` and `LitNuke`: not
placeable, unbreakable (Minecraft's primed TNT is an entity no player breaks), blast resistance 0
(rays pass, as they pass entities), no drops, `item` the unlit block (WAILA's icon, pick block),
glowing (`light` 9 white, 12 red: drawn one part per block with its PointLight), behaviour "Tnt".
Gunpowder (ItemList, last) is two per coal or charcoal and flint; TNT is Minecraft's recipe (5
gunpowder in an X, 4 sand); the Nuke is eight TNT around a diamond block.

**Lit blocks, not entities.** PrimedTnt falls, flashes and explodes where it is. The engine's
entities are items only (EntityWorld, its own protocol and renderer), so a lit explosive is a
block: the world's edits replicate it, the client meshes it like any block, and the server keeps
its state by position (`Behaviours/Tnt`, per world, never sent): the tick its fuse runs out, its
fall speed and part cell, and what it fell into. Every lit block has its next block tick waiting;
each tick is PrimedTnt.tick:
- the fuse (`Config.Tnt.FuseTicks` 80, `Config.Nuke.FuseTicks` 200): when it runs out the cell
  goes back to what it fell into and TNT explodes there (`Explosions.explode`, power
  `Config.Tnt.Power` 4, no fire, at y + 0.0625: PrimedTnt's getY(0.0625)), a Nuke calls
  `Nuke.detonate`;
- a Nuke beeps every `AlarmTicks` (entity.nuke.alarm);
- gravity while the cell below is loaded and replaceable (air, fire, plants, fluids): speed += 0.04
  then × 0.98 (Minecraft's), the block moving a whole cell when the fall passes one, giving back
  what it passed through (a water source stays: TNT that sinks into water explodes in it and
  breaks nothing, as in Minecraft). Minecraft's hop on lighting (0.2 up) is left out.
A lit block is registered when it is placed (`onNeighborChanged` with nothing on record, or what
`prime` or the fall hands over); a record not run for 20 ticks belongs to a lit block replaced
by other means and is replaced. A random tick restarts a lit block whose tick was lost.

**Lighting** (`Tnt.prime(world, x, y, z, fuse?, quiet?)`, entity.tnt.primed): flint and steel
(`Players/ItemUse`, TntBlock.use: any side, wears 1, not in creative; the client sends it for TNT
and Nukes whatever is in front), fire (`Behaviours/Fire`'s checkBurnOut lights it where it would
burn it away; lava lights fire next to flammable blocks, so lava lights it too) and blasts:
`World/Explosions` hands every non-air block a blast reaches to the primer (`setPrimer`; this
module sets `Tnt.blasted` when it loads) before breaking it: TNT and Nukes are lit quietly with
TntBlock.wasExploded's fuse rand(fuse / 4) + fuse / 8 (TNT 10..29 ticks, a Nuke 25..74), lit ones
stay. A pile of TNT goes off in a ripple, each lit by the last.

**The Nuke's crater** (`World/Nuke`, pure on WorldServer; `Config.Nuke`). Minecraft's 1352 rays
thin out at huge powers (gaps between rays far out) and still read tens of thousands of blocks in
a tick, so the crater is dug cell by cell instead:
- `detonate(world, x, y, z)`: at once the handler (`Explosions.effects`: items and players with
  Minecraft's damage and push at `Power` 28, reach 56, deadly in the open within about 50 blocks,
  shielded by what is between; the Explosion message to players within `EffectDistance` 256), the
  boom (entity.nuke.explode, heard 256 blocks away); then a job.
- The crater (`crater`, `radiusAt`, `fate`): seeded by the Nuke's cell (Hash), so the same place
  digs the same crater. A cell's radius is `Radius` × (1 + `Ragged` × w) + c, w smooth 3D noise
  (wavelength `RaggedScale`, scaled ×2 and clamped to ±1), c a hashed crumble of ±0.5: 18.7..29.3
  blocks. Inside, a block becomes air (no drops) when its blast resistance is under `Strength` ×
  (1 − d / r): dirt (0.5) to the rim, stone (6) to 0.9 r, obsidian (1200), bedrock and fluids (100)
  never: water pours in afterwards, a bunker of obsidian stands. Fuel inside is vaporised.
- Scorching, in the ellipsoid of `ScorchRadius` (40) sideways and the largest crater radius up and
  down: grass, dry grass, podzol and mycelium become dirt (coarse dirt one time in three, hashed),
  blocks resisting less than `ScorchResistance` (leaves, plants, glass, snow, torches) are blown
  away, logs stand, fuel there catches (`Explosions.ignite`). One air cell in `FireOdds` (hashed)
  over an opaque block that stays catches fire, inside the crater and around it.
- Explosives it reaches go to the primer (`Explosions.reached`): chain reactions, Nukes too.
- Costs: the cells (about 200,000: the ellipsoid) are visited nearest first from a list of i8
  offsets built once (`offsets`, a bucket sort by half blocks, 30 ms in Lune), so the crater grows
  outwards. `step` (the boot script, after `Explosions.step`) works the jobs oldest first within
  `EditsPerTick` (500; lighting an explosive counts) and `ReadsPerTick` (16,000) together; a cell
  is at most one edit. Each edit is 12 bytes to every client (`Edits`), so 6 KB a tick at most.
  Measured in Lune on the spawn of seed 12345: 32,700 edits and 224,000 reads over 66 ticks
  (3.3 s), 3 ms a tick on average and 8-12 ms at worst (the read-only ticks of open sky at the
  end), the block ticker's reaction to it 6-10 ms in all. Unloaded chunks are skipped, never
  generated.

**The client.** `Rendering/FuseView` flashes lit blocks: a Neon box a little over the block
(white over TNT, red over a Nuke) shown 5 ticks, hidden 5 (TntRenderer's (fuse / 5) % 2, from the
clock so all flash in step), for the nearest 48 within 64 blocks, found from chunk edits and block
changes as FireRenderer finds fires. `Rendering/ExplosionView` draws a blast of
`Config.Nuke.LookPower` or more (`isNuke`) as the Nuke's: a white flash over the screen
(`flash`: full within 64 blocks, nothing at 256), a Roblox Explosion up to 24 blocks, a fireball
swelling to the crater's size, a shock ring along the ground and a mushroom cloud (a stem and
three caps) rising 60 blocks over 9 s from fire to smoke, six anchored inert parts gone after
14 s, and a 2.5 s shake of up to 4°. WAILA says "Explosive: power 4", "Explosive: 24 block
crater" and, on lit ones, "Lit: stand back!".

## Thirst and temperature (`ToughAsNails/`, server `Players/ToughAsNails`, `Players/Climate`, client `Ui/SurvivalHud`)

The Tough As Nails mod's survival mechanics, after its 1.20 version: thirst and body temperature,
tuned gentler than the mod (a fine temperature scale that moves slowly, slow extremes, a grace
period). The rules are pure shared modules (tested in `tests/spec/ToughAsNails`); the server plays
them out at 20 ticks a second and sends each player their own state; the client draws it and
reports its movement. `Config.ToughAsNails` turns thirst and temperature on and off (with both off
the server module does nothing and no message is sent). Survival and adventure players only
(`ToughAsNails.affects`: not GameMode.invulnerable): creative and spectator players' stats stand
still, the extremes clear and nothing hurts; the HUD shows with the hearts.

**Thirst** (`ToughAsNails/Thirst`, TAN's ThirstData = Minecraft 1.20.1's FoodData with water):
- thirst 0..20 (starts 20), hydration 0..thirst (starts 5, food's saturation), exhaustion 0..40;
  above 4, 4 is taken off and a point of hydration goes, or of thirst when none is left (one step
  a tick, Minecraft's `> 4`);
- exhaustion, Minecraft's FoodConstants: sprinting 0.1 a metre on the ground, swimming, walking
  under water or wading 0.01 a metre, a jump 0.05, a sprint jump 0.2 (the client's `Exertion`
  reports, below), a block broken 0.005 (ServerNet's `broke` rule), a hurt that landed 0.1 (the
  server sees health drop outside its own damage), 6 a regenerated half heart, TAN's Thirst
  effect 0.015 a tick (TAN's 0.025 was too harsh), `HotExhaustion` (0.005) a tick in the HOT zone;
- a tick in Minecraft's order: the effect counts down and adds its exhaustion, the exhaustion
  turns into lost points, then with `ThirstRegeneration` and thirst 18+ a hurt player gets half a
  heart back every 80 ticks for 6 exhaustion (FoodData's slow branch; the fast saturation branch
  is food's and left out; never while fully frozen or overheated, `tick`'s `stopped`: see
  Temperature), or at 0 thirst half a heart is lost every 120 ticks
  (`DEHYDRATION_INTERVAL`, starvation's 80 made gentler) while health is above
  `DehydrationFloor` (1: normal difficulty), through armor;
- under Climate Clemency (below) a point goes for every 8 exhaustion instead of 4 (half the
  drain, `CLEMENCY_RATE`) and dehydration doesn't hurt;
- with `ThirstRegeneration` the character's Roblox `Health` script is removed, so health only
  comes back by thirst's rule; otherwise it stays, disabled while the body is fully frozen or
  overheated (`Temperature.stopsRegeneration`).

**Drinks** (`ToughAsNails/Drinks`): drinking is FoodData.eat (thirst + n up to 20, hydration +
n × modifier × 2 up to the new thirst), and a dirty drink rolls TAN's Thirst effect (a longer one
running stays):

| Drink                        | Thirst | Hydration | Thirst effect | Warmth / chill |
| ---------------------------- | ------ | --------- | ------------- | -------------- |
| a water source, empty hand   | 1      | 0.1       | 50%, 300 ticks | -             |
| Dirty Water Bottle / Canteen | 4      | 0.25      | 50%, 300 ticks | -             |
| Purified Water Bottle / Canteen | 6   | 0.4       | -             | -              |
| Dirty Water Bowl             | 4      | 0.3       | 50%, 300 ticks | -             |
| Purified Water Bowl          | 7      | 0.45      | -             | -              |
| Mint Tea                     | 7      | 0.6       | -             | chill 2400 ticks |
| Ginger Tea                   | 7      | 0.6       | -             | warmth 2400 ticks |
| Herbal Tea                   | 8      | 0.65      | -             | both 1200 ticks |

A `Drink` may also carry `warmth` / `chill` ticks: `Drinks.apply(thirst, drink, random,
temperature?)` gives TAN's Internal Warmth / Internal Chill to the temperature state it is handed
(the server hands it while temperature is on). Containers are data, three frozen tables in the
module that both sides read: `ITEMS` (full item -> `{ drink, empty?, sips? }`: what it gives, the
empty container drinking it leaves, `sips` for a canteen whose `durability` is its sips), `FILLS`
(empty container -> the dirty water it becomes at a water source; a dirty `sips` item of its own
container is topped up there while it has sips missing) and `PURIFIED_OF` (dirty -> purified;
`purifiedOf`, `isDirty`). A new container is two `ITEMS` entries, a `FILLS` entry, a
`PURIFIED_OF` entry and its recipes, as the wooden bowls are; a drink that is no water (the teas)
is an `ITEMS` entry with a `Drink` of its own and the container it leaves; load-time asserts catch
entries that name no item or no drink.

Items (appended to ItemList): Glass Bottle (Minecraft's; three glass in a V make three), Dirty and
Purified Water Bottle (stack 16), Canteen (TAN's leather canteen in iron: a nugget over three
ingots in a cup), Dirty and Purified Water Canteen (durability 3: a sip wears it, the last leaves
the empty Canteen; the tool repair recipe skips them). An empty container used at a water source
(Minecraft's source-only ray; a Dirty canteen with sips missing too) fills with dirty water
(ItemUtils.createFilledResult: one used, the full one replaces the stack or goes into the
inventory; creative keeps the empty one); smelting purifies (TAN's original way), in a furnace or
an Electric Furnace. Drinking an item is Minecraft's 32 tick use: the client sends `Drink` start,
counts 32 ticks while the button stays down (gulps every 4 ticks from the 7th), then finish; the
server drinks it only if the same item is still in the same slot 28+ ticks after start and the
player may drink it (`Drinks.drinkable`: thirsty or creative with thirst on; a drink that tempers,
a tea, whenever temperature is on, thirsty or not, its water only with thirst on), then uses it up (one drink gives its empty container
back) and plays the last gulp to everyone else. A sip from a water source with an empty hand is
instant, at most every 10 ticks (`HandDrinking`). Nothing is predicted: the inventory snapshot and
the Survival message bring the results.

**Herbs, bowls and teas** (BlockList Mint and WildGinger, ItemList MintLeaves, GingerRoot, Bowl,
DirtyWaterBowl, PurifiedWaterBowl, MintTea, GingerTea, HerbalTea; Crafting/Recipes). Mint and Wild
Ginger are plants (see Plants) that generation grows in rare patches (see Foliage: mint on plains,
meadows and in jungles, wild ginger in forests and taigas); breaking one drops one Mint Leaves /
Ginger Root (Shears too: no shear drop), which plants it back on the dirt set (ItemList `places`,
see Items), one for one, so replanting gains nothing; they spread instead (`Behaviours/Herb`,
Minecraft's mushrooms: `Server.HerbSpread` 1/8 a random tick, a try every 9 minutes or so, up to 5
in 9 x 3 x 9). The Bowl is Minecraft's (three planks of any wood in a V make four; 100 ticks of
fuel). It is a third container through the tables alone: it fills at water into a Dirty Water Bowl
(stack 16), which a furnace purifies (a campfire boils it, as any dirty water: Gear, below), and
drinking a bowl gives the Bowl back. Mint purifies without a fire: a dirty bottle, bowl or canteen
with Mint Leaves (shapeless, the inventory's 2 x 2 grid too) makes its purified twin, a canteen
keeping its sips (the shapeless `keep`, see Crafting: a cure never makes water). A Purified
Water Bowl with a herb brews a tea (stack 1, like stews): Mint Tea gives Internal Chill for 2
minutes, Ginger Tea Internal Warmth for 2 minutes, Herbal Tea (both herbs) both for 1; a tea keeps
its water's thirst and adds hydration, and is drunk for its effect whenever temperature is on,
thirsty or not, thirst on or off (`Drinks.tempers`, `drinkable`). So under ginger tea the tundra's -10 is held at -5 (COLD:
no freezing), under mint tea the desert's 9 at 4 (WARM). Drinking a bowl uses the drink and fill
sounds of the bottles. tests/spec/Herbs covers it all.

**Movement** (`ToughAsNails/Exertion`): Minecraft's server takes the client's sprint flag and
positions, so the client measures (MovementController hands each tick to `Player/Exertion`):
centimetres sprinted on the ground, swum or moved in water (Player.checkMovementStatistics's
branches; flying and walking cost nothing), jumps and sprint jumps, and sends them about once a
second, and at once when sprinting starts or stops. The server allows at most 10 m and 3 jumps per
second since the last report (`clamp`; 4 reports a second) and holds the sprint flag for 2 s.

**Temperature** (`ToughAsNails/Temperature`): an integer body temperature -10..10 (TAN 1.12's fine
scale) in TAN 1.18+'s five zones, whose ids (`zone`, ICY -2 .. HOT 2) are the levels of before:
ICY -10..-8, COLD -7..-3, NEUTRAL -2..2, WARM 3..7, HOT 8..10. The target, worked out once a
second per player from `Players/Climate`:
1. the climate: the column's surface biome temperature (BiomeList, -0.75 tundra .. 0.8 desert),
   0.001 colder per block above 256, then outdoors at night 0.3 colder, under a roof (day and
   night) 0.15 towards NEUTRAL's middle but never past it (out of the sun in the heat, out of the
   wind in the cold: a roof never chills, so a taiga house is -2 and a desert one 7), and
   underground (under a roof, 16+ blocks below the column's terrain) NEUTRAL's middle; put on
   the scale piecewise linearly (`scaleOf`) through the old cuts -0.55, -0.25, 0.4 and 0.7, which
   land on the zone borders -7.5, -2.5, 2.5 and 7.5 (beyond them the nearest segment's slope goes
   on), rounded half up, within -10..10. So tundra -10, taiga -4 (-9 at night), plains 0 (-2 at
   night), savanna 4, jungle 7, desert 9 (4 at night, 7 in a house), the frozen peaks -10;
2. steps, each kept within -10..10: wet (in water or out of it for less than `WetTicks`) -3,
   sprinting +2, a heating block within `ProximityRadius` (5, a cube around the feet) +3 or within
   2 blocks +5, burning +5 (not on top of a heat source's: the larger), a cooling block -3 but not
   within 2 blocks of a heat source (a tundra's snow is a cooling block all around: by a campfire
   the fire wins, so the coldest place is -5 there, not -8);
3. armor insulation (ItemList `tan` summed by `Climate.insulation`): `warmth` steps pull a target
   below 0 up towards 0 and `cooling` steps pull one above 0 down, never past 0 (leather: warmth 1
   a piece);
4. the player's own effects (`target(env, state)`): Internal Warmth +5 but never past +2 by it,
   Internal Chill -5 but never past -2 (protection without the opposite extreme); then Climate
   Clemency holds the target within -2..2.
The temperature steps once towards the target every `ChangeTicks` (140: from neutral the icy edge
takes 56 s in the coldest place) moving away from 0, or every `RecoverTicks` (70) moving back
towards it (the count restarts on target and after each step). In the ICY zone `frozen` rises a
tick at a time to `EXTREME_TICKS` (400: 20 s; Minecraft's freezing takes 7) unless a worn piece is
freeze immune (`tan.freezeImmune`, Minecraft's freeze_immune_wearables: leather) or Climate
Clemency is on; otherwise it thaws 4 a tick (5 s from full). In the HOT zone `heat` does the same
(hyperthermia). Full: half a heart every 100 ticks (5 s), through armor (Minecraft's freeze
hurt). The hurts don't go through Burning's shared hurt cooldown. From neutral and full health,
nothing worn, in the coldest place, death takes 176 s, whatever is drunk: while fully frozen or
overheated no health comes back (`stopsRegeneration`: thirst's regeneration, a half heart every
80 ticks, waits, and the server disables Roblox's Health script where it is kept), as either
would outlast hurts every 100 ticks (simulated tick by tick in the spec, drinking a bowl
whenever thirst drops below 18 too; before: 67 s).

**Climate Clemency** (TAN's grace effect): the first character since joining gets `ClemencyTicks`
(6000: 5 minutes) of it, a respawn `RespawnClemencyTicks` (1200: a minute); nothing is saved
between visits, so every visit starts afresh. It counts down only in survival and adventure
(`Temperature.tickEffects`, which the server runs alone while temperature is off). While it lasts
the target stays within NEUTRAL, no extreme builds, thirst drains at half the rate and
dehydration doesn't hurt.

**Surroundings** (`Players/Climate`, pure over a view: loaded blocks, the generator's column, and
SkyCheck for the roof above the eyes). Heat and cold sources are block ids: `HeatingBlocks` and
`CoolingBlocks` names (a fluid name is every level and the cave twin: "Lava"; a name no block has
is skipped with a warning, so a block can be listed before it exists), plus sources registered with
`Climate.addHeatSource(block, check?)` / `addColdSource(block)` (they return how many ids they
cover): the server module registers the Furnace (while its container's litTime > 0) and the Heat
and Combustion Generators (while their machine is active). `Climate.sources` gives the distance of
the nearest heat and cold source (along the farthest axis); a check only runs for a block of its
kind within range that would be nearer than the nearest found so far. The Campfire, always lit, is
a plain `HeatingBlocks` name; anything new that warms only sometimes (burning blocks) registers
with a check.

**Gear** (the climate's tools; tested in `tests/spec/SurvivalGear`):
- the **Campfire** (BlockList, appended; Minecraft's CampfireBlock, always lit): Minecraft's recipe
  (" S ", "SCS", "LLL": sticks, a coal or charcoal, any logs) and model (four logs, the glowing bed
  of embers that carries its light 15, the 7 pixel outline), not solid (the hull has no 7 pixel
  step) but `obstructs`, strength 2 with an axe, dropping itself (Minecraft drops 2 charcoal
  without Silk Touch, which the game has no way to get, so it could never be moved). A
  `HeatingBlocks` heat source; standing in it hurts (Players/Burning, above in Fluids); spawns
  avoid it (SpawnUnsafeBlocks Body and Hazards); its flames and crackle are fire's (Rendering);
- **boiling** (`ToughAsNails/Boiling`, pure): a right click on a campfire with dirty water
  (`Drinks.isDirty`: anything in PURIFIED_OF, so later containers boil with no code) turns one
  into its purified twin, createFilledResult-style (the last one is replaced, else the purified
  one goes into the inventory; a canteen keeps its wear, so its sips; creative keeps the dirty one
  and gets a purified one only without one). It is the campfire's own use (CampfireBlock.use):
  survival, adventure and creative, not spectators, not while sneaking (`Boiling.applies`). The
  water takes its time: one container every `Boiling.INTERVAL` (60 ticks, 3 s) per player
  (`Boiling.ready`), as the campfire burns no fuel and moves with its owner (Minecraft's campfire
  cooks free but slowly too), so mint stays the quick cure and the furnace the unattended one.
  The client (Interaction/BlockInteraction) sends it as a UseItem after a block's menu and before
  Drinking (so a dirty bottle aimed at a campfire boils, elsewhere it is drunk), not predicted, and
  not sooner than the interval (a click too soon sends nothing and stays unspent, so a held
  button boils the next one when ready); Players/ItemUse checks it before the game mode's
  mayUseItemOn (adventure players fail that) and the interval again (`Boiling.LEEWAY`, 4 ticks
  short allowed), plays `block.campfire.boil` and hands the stacks over. JEI shows it as a seventh category,
  "Campfire" (Ui/Jei/JeiData `boiling`: one entry per PURIFIED_OF pair, drawn as smelting with
  "Right click" under it; the Campfire is its catalyst);
- **Straw** (ItemList): `Items.strawDrop`, which EditRules.drops asks after `leafDrop` when no
  Shears are held: Short Grass gives one half the time, Tall Grass (its lower half answers for a
  break of either) always, where Minecraft's grass gives wheat seeds one time in 8; Shears still
  harvest the grass itself; grass gone by itself (water, fire, a blast) gives nothing;
- **Straw and Leaf armor** (ItemList `INSULATING_ARMOR`, appended after everything: the `ARMOR`
  table at the top must not grow, its ids would shift): leather's points (1 / 3 / 2 / 1, no
  toughness; armor doesn't wear in this game, so no durability), `tan = { warmth = 1 }` from
  Straw and `tan = { cooling = 1 }` from any leaves (Recipes' `#leaves` tag), the armor shapes.
  The coldest target is -10 day and night (the scale's clamp at each step), so a full straw set
  holds -6 (COLD) anywhere, three pieces -7, two -8 (ICY); a taiga's night (-9) is -5. A full leaf
  set turns a desert's 9 into 5 (WARM) and the hottest 10 into 6; one piece leaves 8 (HOT);
- the **Thermometer** (ItemList; an iron nugget over glass over glow dust): while it is the held
  item, Ui/SurvivalHud reads the temperature and the target out as numbers ("-3", "+5" in their
  zones' colours, the trend's arrow between) a row above the status row (Ui/Hud passes the held
  item to `SurvivalHud.render`).

**Sync and HUD.** The server sends `Survival` (14 bytes: flags with wet, Internal Warmth and Chill,
thirst, hydration, exhaustion, the temperature and its target as -10..10, frozen and heat, the
Thirst effect's ticks, Climate Clemency's seconds) to the player alone when its bytes change, at
most every 4 ticks and at once for a new character (a respawn starts over: full thirst, neutral,
dry). `Player/SurvivalState` keeps it; `Ui/SurvivalHud` draws inside the hotbar's canvas (so the
GUI scale is the hotbar's): 10 droplets right-aligned level with the hearts (hunger's place,
filled from the right, half droplets their right half; green under the Thirst effect; jittering
with no hydration, Minecraft's hunger rule); above them, level with the armor, a 75 × 9
thermometer (a bulb in the zone's colour: pale blue, blue, green, orange, red; a tube of 21 cells
tinted by zone with ticks at the zone borders; a pin on the temperature and an arrow beside it for
the trend); a row higher, above the held item name's row (the centred name, long for most of the
Tough As Nails items, reaches the right side), right-aligned, Climate Clemency's shield and time
left (m:ss) and the Internal Warmth (flame) and Chill (snowflake) icons, only with
`Config.Effects.Hud` off (the status effect icons list the same three, with their time); and the
frost or heat closing in from the screen's edges as `frozen` / `heat` rise (a ScreenGui of its
own behind the HUD). F3 prints a `survival` line with all the numbers. Knowledge's bar (Ui/Hud)
fits between the hearts' and droplets' row and the hotbar, its level in the gap between them, so
none of these rows moved for it; all of them are in the one canvas and its UIScale, so they keep
apart at every GUI scale and on touch screens.

## Status effects (`Effects/`, server `Players/Effects`, client `Player/EffectState`, `Ui/EffectHud`, `Rendering/EffectView`)

Minecraft 1.20.1's MobEffect and MobEffectInstance, this game's two from the fluids and Tough As
Nails' four, in one list. Tested in `tests/spec/Effects`.

**The registry** (`Shared/Effects`, its data in `Effects/EffectList`; ids are u8 list positions,
append only, sent in the Effects message): 1 Speed, 2 Slowness, 3 Haste, 4 Mining Fatigue,
5 Strength, 6 Instant Health, 7 Instant Damage, 8 Jump Boost, 9 Nausea, 10 Regeneration,
11 Resistance, 12 Fire Resistance, 13 Blindness, 14 Night Vision, 15 Weakness, 16 Poison,
17 Wither, 18 Glowing, 19 Oil Coated, 20 Fuel Soaked, 21 Thirst, 22 Internal Warmth, 23 Internal
Chill, 24 Climate Clemency. A record holds its name, `/effect` id (Minecraft's), colour (MobEffect's
int), category (beneficial, harmful, neutral), HUD glyph and what it does as data. `find` takes a
name, a display name or an `/effect` id with or without a namespace; `levelName` writes "Speed II"
(roman to X), `formatTicks` "m:ss" / "h:mm:ss" / "**:**".

| Effect | Per level (amplifier + 1) | Minecraft's code |
| ------ | ------------------------- | ---------------- |
| Speed / Slowness / Oil Coated | ground speed × (1 + 0.2 / −0.15 / −0.15 × level), multiplied together, ≥ 0 | MULTIPLY_TOTAL on movement_speed |
| Haste / Mining Fatigue | mining × (1 + 0.2 × level) / × 0.3, 0.09, 0.0027, 0.00081 | Player.getDestroySpeed |
| Jump Boost | jump + 0.1 × level, fall damage − level blocks | getJumpBoostPower, calculateFallDamage |
| Strength / Weakness | melee + 3 / − 4 half hearts × level, ≥ 0 | attack_damage ADDITION |
| Resistance | hurts × (25 − 5 × level) / 25, ≥ 0 | getDamageAfterMagicAbsorb |
| Regeneration | heals 1 every 50 >> amp ticks below full health | RegenerationMobEffect |
| Poison | hurts 1 every 25 >> amp ticks while health > 1 (magic: no armor) | PoisonMobEffect |
| Wither | hurts 1 every 40 >> amp ticks, may kill | WitherMobEffect |
| Instant Health / Damage | heals 4 << amp / hurts 6 << amp once (magic) | HealOrHarmMobEffect |
| Fire Resistance | no fire hurt | LivingEntity.hurt (IS_FIRE) |
| Oil Coated / Fuel Soaked | burning × 2 and + 1 a hurt / × 3, catches at once, lit by blasts; water washes off | this game's |
| Night Vision, Blindness, Nausea, Glowing | the view (client), the outline (server Highlight) | GameRenderer, FogRenderer |
| Thirst, Internal Warmth / Chill, Climate Clemency | kept by Tough As Nails (`external`) | TAN 1.20's effects |

The modifiers read `Levels` (effect id → amplifier): `speedFactor`, `miningFactor`, `jumpBoost`,
`meleeDamage`, `incomingDamage`, `fireRules` (nil when nothing changes: no allocation),
`noSprint`; `isDurationTick` and `instantAmount` are the ticking; `nightVisionScale`,
`blindnessFog`, `nauseaIntensity` / `nauseaSway`, `iconAlpha`, `hudOrder` and `tooltip` the
client's.

**Giving and ticking** (`Players/EffectRules`, pure): a State per character holds the running
instances (effect, amplifier, ticks or INFINITE, ambient, the hidden one), their levels (kept in
step, so the modifiers read a table and allocate nothing), the external effects, the fluids'
contact counts and the player's age. `give` is MobEffectInstance.update: a higher amplifier wins
(the old one hidden underneath when it would last longer, coming back when the stronger ends,
having counted down meanwhile), the same amplifier only lengthens, a lower longer one goes under;
external effects and nonsense change nothing. `tick` (20 a second) acts on isDurationEffectTick
(an infinite effect by the age), sums the hurt (never for creative or spectator) and healing,
counts down every instance and its hidden chain, and drops what ran out. Instant effects are
instances of a tick (a potion's) or of `/effect`'s seconds as ticks, never shown.

**The fluids' effects** (`touchFluids`, FluidList `effects`, resolved by Shared/Fluids to ids and
ticks): each fluid's list of `{ effect, seconds, amplifier, when, after }`: "in" refreshes the
effect every tick the body touches the fluid (once `after` seconds unbroken; an effect that acts on
an interval, fuel's Poison, only once it ran down that interval: isDurationEffectTick asks the ticks
left, so put back to its full 100 every tick it acted every tick, 141 hurts in 10 s of fuel and a
hurt cooldown that never ended; now Poison I's half heart every 25 ticks), "head" while the eyes are
in it (Players/Characters looks at the eyes only when a fluid has such an effect), "left" gives it
the tick the body stops touching it. Then a fluid that `extinguishes` washes off every `washOff`
effect (after the giving: water and fuel together leave nothing to wash). Spectators touch nothing.
Oil: Slowness II for 1 s while in it, Oil Coated for 30 s on leaving. Fuel: Nausea 8 s while in it,
Poison I (up to 5 s left) after 3 s in it, Fuel Soaked 20 s while in it.
`Config.Effects.FluidEffects` turns it off.

**In the world** (`Players/Effects`, the API): Players/Characters runs it in its 20 Hz body tick:
the fluids' effects (`touchFluids`, with the masks Burning already made), the fire rules for
Burning.tickPlayer, then `tick`, whose hurt goes through the same hurt cooldown as lava (no
armor: magic) and whose healing raises the Humanoid's health; every hurt there (lava, fire,
burning, the effects, blasts, falls, walls; Players/ToughAsNails' hypothermia and hyperthermia
too, which are Minecraft's freeze damage, not dehydration, which is starvation's and bypasses
effects) is cut by Resistance after armor, a fall loses Jump
Boost's levels first, and a blast that hurts a player whose effects `ignite` sets them burning.
`tick` also reads the external effects from their adapters (`addExternal`: Tough As Nails
registers Thirst, Internal Warmth and Chill with their switches, and Climate Clemency, each with
`give` and `clear` for `/effect`, Thirst and the clemency with `paused`: they stand still for
creative and spectator players), keeps the Glowing Highlight on the character and sends the
Effects message when `needsSync` says the client's view is off. ServerNet's `miningFactor` rule
(Mining.playerFactor: Effects.miningFactor times Progression's mining perks) times survival
mining (Mining's `factor`: the start check, the break check, a delayed break's time), so a Haste
player's breaks are accepted when the client finishes them.
Potions are given by Players/ToughAsNails when a drink with `effects` finishes (`giveAll`). A new
character starts with none (the client is told at once); nothing is saved.

**Sending** (`needsSync`, `markSent`): the client counts every effect down itself and keeps one at
0 until told it went (as Minecraft's client keeps an effect until the remove packet), so the
server sends the whole list (7 bytes an effect) when an effect comes or goes, its amplifier or
ambience changes, or its ticks left differ from the client's countdown by more than 20: an effect
refreshed every tick in a fluid costs a message about once a second, an untouched one nothing
until it ends. An external effect its owner holds goes out `paused` (flags bit 1): the client keeps
its time as sent and the server compares against that, so a creative player's Climate Clemency is
told once, not every 21 ticks as its frozen time drifted from the client's countdown.

**/effect** (`Players/EffectCommand`, pure; the glue in Players/Effects): `give <player> <effect>
[seconds | infinite] [amplifier] [hideParticles]` (Minecraft's bounds 1..1000000 and 0..255,
default 30 s, an instant effect's a tick and its seconds as ticks) and `clear [player] [effect]`,
players as `/gamemode` finds them plus `@p`, the permission of `/time` (the operators',
Players/Operators) and Minecraft's answers ("Applied effect Speed to Steve", "Removed every effect from
2 targets", "Unable to apply this effect (...)", "Unknown effect: x", "Integer must not be more than
255, found 256"). Dead players take nothing.

**Potions** (`Effects/PotionList`, pure data): twelve potions, each a Purified Water Bottle brewed
with an ingredient in a crafting grid, with a strong (Glow Dust: level II) and a long (a coal or
charcoal) variant where Minecraft has them; 29 items (ItemList, stack 1, the effect's colour in a
bottle), 29 shapeless recipes (Crafting/Recipes; the `tulips` tag) and 29 `Drinks.ITEMS` entries
whose `Drink` carries `effects` (no water; `Drinks.isPotion`: drinkable any time, Tough As Nails on
or off, so Players/ToughAsNails keeps its Drink listener and records with both switches off,
without ticking, and bottles fill at water then too). The inventory tooltip lists the effect, its
level and time (blue, harmful red).

**The client.** `Player/EffectState` keeps the last Effects message and when it came, counts down
(`list`, `get`) and keeps the modifiers worked out once per message: MovementController puts the
speed factor, Jump Boost and Blindness onto the hull before every tick (PlayerPhysics' ground
speed and, unlike Minecraft, a slowing factor in fluids too so oil's Slowness slows wading; jump
velocity; the safe fall; no sprint start) and widens the field of view by (factor + 1) / 2;
BlockInteraction times mining with its levels (Mining.playerFactor, with the perks).
`Rendering/EffectView` (after the camera) raises Lighting's ambients for Night Vision
(LightingController.setNightVision), closes the fog in black for Blindness (ViewSettings.setEffectFog, which wins over a fluid's when nearer;
LightingController.setEffectFogColour, in the same frame: Lighting's fog with the Atmosphere out of Lighting) and rolls the camera and sways the field of view for
Nausea (MovementController.setFovSway; the wobble times the Distortion Effects setting squared,
Minecraft's screenEffectScale: `EffectView.setDistortion`), with a ColorCorrectionEffect for the brightness, darkness
and tint, writing only what changed. `Ui/EffectHud` draws Minecraft's icons (24 × 24 frames,
9 × 9 glyphs from `Ui/EffectIcons` at 2 pixels, beneficial row over the rest, longest first,
GroupTransparency for the last 10 s' blinking) below `MusicToast.bottom()`, the hovered or tapped
one's name and time under them, and Minecraft's 120 × 32 list on the left while an inventory
screen is open: over the screens' darkened backdrop (DisplayOrder 10, above Screens' 9, under the
cursor's 20), never taking clicks, Minecraft's 32 wide compact list (glyphs alone) when the full one
would reach the screen's panels (`Screens.screenLeft`), none when even that wouldn't fit, and
nothing behind panel screens (skill tree, Options: `Screens.panelOpen`). Its ScreenGui orders
children over parents (ZIndexBehavior Sibling, as Style's builders expect: under Instance.new's
Global ordering each list panel's outline covered its own face and text). It is rebuilt only when
a message comes. F3 lists every effect.

## Knowledge, Ages and skills (`Progression/`, server `Players/Progression`, client `Player/ProgressionState`)

Progression is three things, pure and shared (`Shared/Progression`, tested in
`tests/spec/Progression`), played out by the server and drawn by the client:

- **Knowledge** (`Progression/Knowledge`): this game's experience. Points and levels are
  Minecraft's exactly (`needed(L)`: 2L + 7 below 15, 5L - 38 below 30, 9L - 158 above; `total`
  is a table of level starts, `levelOf` a binary search over it, `progress` the bar's fill), so
  level 5 is 55 points, 15 is 315, 25 is 910, 40 is 2920. It is never spent.
- **Ages** (`Progression/Ages`): Stone, Iron, Industrial, Electric, Atomic. Each names the result
  items it opens (`recipes`), the knowledge level it needs and two milestones (discoveries: a key
  of a category, or a count of one), and its reward. Every result no Age names is the Stone Age's,
  so what other parts add later starts open.
- **Skills** (`Progression/Skills`): 18 nodes, 3-4 per Age, costing the Age's number in skill
  points (one per level; 51 for the whole tree), each needing its Age, its prerequisites and the
  points, each with one perk kind (or recipes it unlocks besides their Age).

A player's `State` is `{ points, age, skills, found }` (`found`: category -> key -> true, the
discoveries). A `Session` (per server visit, never saved) holds the repeats' fatigue, the
budget's bucket and the fraction of a point not yet given.

**Earning** (`Progression.award / discover / mined / crafted / smelted / visited / killed`):

| Source | First time (once ever) | Again |
| ------ | ---------------------- | ----- |
| a block broken | 5 (`mine`) | ores: coal 1, iron and osmium 2, gold 3, diamond and emerald 5 (`ORES`, source "ore"); logs 0.25 (`LOG`) |
| a crafting result taken | 8 (`craft`) | 0.1 a craft (`CRAFT`) |
| a smelted result taken out (or pushed out, or pulled by a pipe: for the furnace's last user) | 10 (`smelt`) | Minecraft's furnace experience per item: iron and osmium ingots 0.7, gold, diamond, emerald 1, charcoal 0.15, others 0.1 (`SMELTED`) |
| a biome stood in | 20 (`biome`) | - |
| a mob killed (Mobs/Mobs' `died`, wired to `killed` by the boot script) | 10 (`mob`) | animals 2 (Minecraft's 1-3), monsters 5, creepers 6, others 3 (`MOBS`) |
| an Age reached | its reward: 50, 100, 150, 200 (`age`) | - |

Repeats go through `Knowledge.repeatPoints(session, key, base, now, budget)`: each repeat of the
same key gives `FATIGUE_FACTOR` (0.75) of the one before, one repeat of fatigue wearing off every
`FATIGUE_SECONDS` (60), so mining one ore vein pays less and less while variety keeps paying; then
all repeats together draw on a bucket of `Config.Progression.RepeatBudget` (20) points a minute that
refills smoothly. Discoveries are finite, so not budgeted. The knowledge perks for its source
(`knowledgeFactor`: 1 + the bonuses, added) multiply a repeat's base before the bucket
(`repeatAction`), so the 20 a minute holds with every perk (they were applied after it: ores cycled
every 10 s gave 45 a minute with Prospector, Scholar, Polymath and Enlightenment, 18 without);
`award` (discoveries, the API's direct points) multiplies what it is given. The fraction carries
(`Knowledge.carry`), so quarter points add up; a stack taken out at once is one repeat worth every
item, items taken one at a time are repeats of their own and wear off (ten glass: 1 point in one
stack, about 0.38 one by one). A block placed after generation gives nothing at all, neither the
discovery nor a repeat: ServerNet reads `EditRules.placed` (the chunk's edit list holds that block
there, as Behaviours/Leaves tells placed leaves; a cobblestone generator's stone too) just before
the break removes it and hands it to the `mined` rule. Creative and spectator players earn nothing
(survival and adventure: Minecraft's hasExperience).

**Ages** (`requirementsMet`, `advance`): after every change the server enters each next Age whose
level and milestones are met, one after another (a reward can open the next), each a discovery
of category "age" (its reward through `award`). `setAge` (the command) sets it either way;
lowering it holds until the next knowledge the player gets, which checks again (the command's
`lowered` targets skip the check it would otherwise get at once, and `advance`'s second result,
the Ages reached for the first time, is what the chat announces, so Ages entered again are not
announced again nor rewarded). With the
milestones: Iron (5, a Furnace crafted, an Iron Ingot smelted), Industrial (15, an Osmium Ingot
smelted, a Bucket crafted), Electric (25, a Heat Generator crafted, 6 biomes), Atomic (40, an
Oil Refinery and a Basic Battery crafted). Iron smelting is the Stone Age's on purpose: smelting
the first ingot is the way in; what is made of iron is the Iron Age's. What the mobs brought
(cooked meat, leather armor, White Wool) is the Stone Age's; the potions (Effects/PotionList)
are brewed from the Iron Age (each potion's base variant), their level II and long variants from
the Industrial Age (`tests/spec/Crossover` checks every one).

**The recipe gate.** `Progression.allows(state, item)`: the item's Age reached and the node that
names it (Demolition's gunpowder and TNT, Fission's Nuke) unlocked; a nil state allows
everything. It plugs into the inventory logic as the window's `recipes` (Types.Window):

- crafting: `Menu.updateCraft` leaves the result slot empty when the gate refuses the match
  (Minecraft's doLimitedCrafting). Every way of taking a result (click, shift-click, number
  key, Q) takes the result slot's stack, so a locked result can't be taken whatever the client
  sends: the server's window simply never holds it. The match itself is unchanged, so a grid
  filled by hand shows the locked result greyed; JEI greys a locked recipe's "+" with what it
  needs (its transfer fills no grid);
- furnaces and machines: they smelt for nobody in particular (a furnace is shared and keeps
  cooking unwatched), so the gate is at the input: `Menu.mayPlace` refuses an item whose
  smelting result is locked in a furnace's input or a machine's slot (`gated`), and so do the
  merging passes of shift-clicks (which Minecraft runs without mayPlace). What comes out of a
  furnace was put in by someone allowed; a pipe can't be had before the Industrial Age;
- windows without a gate make everything: the tests' grids, `Config.Progression.Enabled` or
  `GateRecipes` off, and creative players (the server's gate asks `GameMode.instabuildOf`; a
  game mode switch works the open grid out again).

The server sets the gate and `onTake` on each player's window once (InventoryState keeps one
window table per player; the hook re-checks every frame for a new one). The client's
Inventory/Prediction puts the same gate (`ProgressionState.allows`) on every window it makes,
so a locked result is never predicted; `setRecipes` rebuilds the prediction when the status
changes. `Menu.copyWindow` keeps the gate and drops `onTake`.

**What is taken** (Types.Window `onTake`, server only): `Menu`'s `craft` (ResultSlot.onTake)
tells it each craft's result, every round of a shift-click too; `Menu.apply` compares a
furnace's or machine's output slots before and after the action and tells it what left them
(FurnaceResultSlot.checkTakeAchievements). Results that leave on their own (Transmitters/Eject
pushing them into a chest beside, a pipe pulling them: the envs' `resultsTaken`) count for the
player who last acted in that furnace's or machine's window (Players/Inventories keeps it,
weakly), as if taken by hand: Minecraft's furnace keeps what it smelted for a player even when a
hopper empties it. Without it a furnace next to a chest, which pushes each ingot out within half
a second, never counted as smelting, and the Iron Age's "Smelt an Iron Ingot" (and the Industrial
Age's osmium) could not be met. A furnace fed only by pipes (no window user) credits nobody.

**Perks** (`Progression.perk(state, id)` is one node; the aggregates are what the game asks):

| Perk | Nodes | Where it plugs in |
| ---- | ----- | ----------------- |
| knowledge | Forager (+10% discoveries), Prospector (ores x2), Scholar (+10% all), Polymath (+15%), Enlightenment (+25%) | `knowledgeFactor(state, source)` inside `award` |
| mining | Quarrying (stone tools x1.1), Ironworking (iron, golden), Diamond Cutting (diamond), Mastery (any tool) | `miningFactor(state, tool)`, times the status effects' in `Mining.playerFactor` -> Shared/Mining's `factor` (`progressPerTick`, `ticks`, `mayBreak`): the client's mining (BlockInteraction, from ProgressionState.perks and EffectState) and the server's checks (ServerNet's `miningFactor` rule into EditRules.mayBreak, the delayed break's timing) |
| wear | Smithing (15%), Tempering (15% more: 1 - 0.85²) | `wear(state, amount, random)`: each point skipped with `wearChance` (Unbreaking's way), from `Inventories.wearTool` (`setWearFilter`): mining, flint and steel, all tool wear |
| thirst | Hardy (x0.9), Endurance (x0.9 more) | `thirstRate` -> `Thirst.tick`'s `rate` (a point costs 4 / rate exhaustion), server ToughAsNails (`setPerks`) |
| insulation | Insulation, Thermoregulation (a step each) | `insulation` steps added to the armor's warmth and cooling before Climate's target (towards neutral either way), server ToughAsNails |
| boiling | Firekeeper (x2) | `boilSpeed` -> `Boiling.ready`'s `speed` (INTERVAL / speed): the client's wait (BlockInteraction) and the server's check (ItemUse, `setBoilSpeed`) |

**Death**: `Config.Progression.DeathLoss` (0) of the progress into the current level is lost
(`die`); levels, the Age, skills and discoveries never are. Knowledge is learning; Minecraft's
experience drops because it is a currency (enchanting), which knowledge isn't.

**On the server** (`Players/Progression`): a fresh state at join, then the saved one
(`Players/ProgressStore`: DataStore "IceVoxelProgress_v1", key player_<UserId>, the record `{ v = 1,
points, age = id, skills = { ids }, found = { [category] = { keys } } }`, names and ids rather than
numbers; loaded with three tries, and a player whose record could not be read, or is of another
version (`fromRecord`'s second result: a newer server's during an update, kept for it), is never
saved that session; saved on leave, on shutdown and every `SaveInterval` seconds while changed, one
write a call: what changes during a write waits for the next interval (written again at once it kept
the key in DataStore's queue, a write every 6 s for as long as the player earned); a player who left
is written again at once while something changed during the write or it failed (`LEAVE_RETRIES` 2),
a periodic write in flight as they left included, and BindToClose waits for those writes). Until it
is read the player has the Stone Age's gate and earns nothing (a first time missed meanwhile counts
the next time). `fromRecord` reads anything safely: another version or garbage is a fresh start (not
saved over), unknown skills are dropped, an unknown Age reads as the Stone Age (and `advance`
reaches it again), points are clamped and whole, keys checked (at most 64 bytes, 4096 a category).
Biomes are looked at every `BiomeInterval` seconds (the generator's surface biome of the column; no
chunk is generated). UnlockSkill messages (5 a second) go through `unlock` once loaded; a refusal is
a Notice with the reason and the status sent again. A player whose state changed gets one Progress
message a frame at most. An Age reached is told to everyone in the chat. Commands
(`Players/ProgressionCommand`, pure): `/knowledge add|set|query` (also `/xp`, `/experience`: with
TextChatService one TextChatCommand per two aliases; points or levels, Minecraft's /xp) and `/age
set|query`, changing with the operators' permission (as /time), and only the game's own operators
(`Operators.isPermanent`: `Gameplay.Admins`, the owner, Studio) where progress is saved.

**Saved for every server or not** (`WorldSettings.savesProgress`, the boot's `Progression.start(net,
world, saved)`): a world type with `savesProgress = false` (superflat, whose preset may be layers
of ore, and the debug worlds, which lay out every block and biome) or Allow Commands keeps what is
earned on that server: the saved progress is read and played with, never written, and each player
is told once in the world.

The API for other parts: `award(player, points, reason)` (direct: no fatigue or budget, the
caller's own reasons), `discover(player, category, key)` (true when new), `killed(player,
mobName)` (the mobs' death signal: a discovery and a repeat of `Knowledge.MOBS`), `state(player)`,
`allows(player, item)`, `smelted(player, stack)` (results a furnace the player last used gave
up on its own: Inventories' results handler), and the perks' `miningFactor`, `wear`,
`thirstRate`, `insulation`, `boilSpeed`.

**On the client**: `Player/ProgressionState` keeps the last status (`Progression.status`: points,
Age, skills, discovery counts by category, the milestones' bits) as a state for the shared rules
(`fromStatus`: no discoveries), sets the prediction's gate, answers the perks the client predicts
with, and plays the orb sound for points (at most every 0.08 s), the level-up for a level and the
challenge fanfare for an Age (none for the first message). `Ui/Hud` draws Minecraft's experience
bar where Minecraft's layout already leaves it room (182 x 5, 7 GUI pixels above the hotbar's
top, under the hearts' and droplets' row, which stay where they were) and the level in green
with a black outline over its middle (13 above the hotbar, between the hearts and the
droplets), in survival and adventure. `Ui/AgeToast` fades a new Age's name in big (its colour,
"A new Age begins", how many recipes it opens). `Ui/SkillTreeScreen` is a panel (K, D-pad left,
the touch button over the gear): a column per Age, a row per node (Skills `row`: the knowledge,
tools and survival branches), lines from prerequisites (along a row, else through the gap after
the prerequisite's column), nodes in slot-grey wells with frames gold unlocked / white available /
dark locked (a locked skill's item mildly dimmed, still recognisable), an info area on the grid's
dark backdrop for the hovered or selected node or Age title (an Age's level and milestones, green
when met; wrapped at word breaks by `Ui/TextWrap`, the status line always kept), and Unlock.
Columns are 80 wide so "Industrial" and the header stay at the font's own size, the panel short
enough (416 × 291) for GUI scale 3 on 900 pixel tall screens; the title and header are dark text
without a shadow, as on the inventory, and gamepad selection is an outline. The inventory screen draws a locked crafting result greyed in the empty result slot
with its requirement on hover (Crafting.match again only when a grid stack or the status
changed); JEI's recipe view puts a padlock on a locked output, adds "Requires the Iron Age" to
its tooltip and greys its "+" with that reason (`JeiData.lockText`).

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
- fuel: `Smelting.fuels()`, the burn time shown as "Burns N items" (ticks / 200; a Lava Bucket
  100);
- boiling (Tough As Nails): dirty water boiled clean on a Campfire, one entry per
  `Drinks.PURIFIED_OF` pair (input, output), drawn with smelting's layout and "Right click" for a
  time; the Campfire is its catalyst and its tab;
- refining, heating and combustion, from the machines' numbers (`Machines.info`): the Oil
  Refinery's bucket of oil into a bucket of fuel (100 ticks, 20 kJ at 200 J/t: "5 s, 20 kJ",
  "200 J/t"), and a bucket burnt in the Heat Generator (a mB of lava 20 ticks: 20 000 ticks at
  200 J/t, "Makes 4 MJ", "200 J/t for 1000 s") and in the Combustion Generator (a mB of fuel 4
  ticks: 4 000 ticks at 2.5 kJ/t, "Makes 10 MJ", "2.5 kJ/t for 200 s"). Their entries carry
  `fluidInputs`, `fluidOutput` (fluid stacks: a Shared/Fluids id and mB), `energy` and `power`
  (`fluidTexts`). A fluid stack is drawn as a slot of the fluid's colour, its name and "1,000 mB"
  on hover (`RecipeView.fluidAt`); JeiLayout draws refining as the oil, an arrow filling over the
  bucket's time, the fuel and two lines of text, and the generators like a fuel, the fluid stack
  under the flame (150 x 36 each). The item list shows items only; in lookups a fluid stands for
  its bucket and its block (`fluidItems`), so "Show uses" of an Oil Bucket or of Oil lists
  refining, and "Show recipes" of a Fuel Bucket too.

`recipes(item)` are the entries that make the item (crafting, smelting, refining), `uses(item)`
those that take it (in any cell, as a smelting input, as a fuel, as a fluid). A catalyst, the
block a category's recipes are made in (`CATALYSTS`: the crafting table for crafting, the furnace
and the Electric Furnace for smelting, the furnace and the Heat Generator for fuel, the Oil
Refinery for refining, the Heat Generator for heating, the Combustion Generator for combustion,
the Campfire for boiling), also uses every entry of its categories, after its own uses, as JEI's
"Show uses" on a crafting table or furnace lists them. Both come grouped by category in that order
(crafting, smelting, fuel, refining, heating, combustion, boiling), without the empty ones.

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
the Restrictive Transporter (items), Mechanical Pipes (every fluid of Shared/Fluids: water, lava,
oil and fuel), Fluid Tanks, the Configurator and Minecraft's buckets. Universal Cables are described
in Electricity and machines; Pressurized Tubes and Thermodynamic Conductors are out of scope: there
is no gas or heat.

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
  sturdy (`sturdy = true` makes a solid shaped block hold torches). Breaking one in creative loses
  its fluid; a survival break keeps it in the item (see Item data).
- Items: the Configurator (1 per slot), Bucket (16) and the Water, Lava, Oil and Fuel Buckets (1).

**Sides and modes.** Sides are Minecraft's Direction ordinal: 0 Down, 1 Up, 2 North (-Z), 3 South
(+Z), 4 West (-X), 5 East (+X); side s of a block at p faces p + offset(s), and opposite(s) is s
xor 1. Each side of a transmitter has Mekanism's ConnectionType, which the Configurator cycles
NORMAL -> PUSH -> PULL -> NONE: NORMAL and PUSH may hand items or fluid to an acceptor (`outputs`),
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
  Fluid Tank or a machine with fluid tanks (`Machines.hasTanks`) for pipes, an energy block for
  cables) unless its side is NONE. The rule knows no fluids: two pipes holding different fluids
  still connect (and draw a joint), but their networks stay apart (On the server, below);
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
A machine reaches the slots its kind gives each face (`Machines.insertSlots` / `extractSlots`),
and a slot may give only some items (its `takes`, `Machines.mayTake`: Mekanism's canExtract, which
only automation obeys; the hand takes anything): the Heat Generator takes fuel through every face
and gives only what its fuel slot would not take in, the empty Bucket a poured Lava Bucket leaves
(Mekanism's FluidFuelInventorySlot.forFuel), so a line feeding it Lava Buckets, or coal after one,
never jams on the bucket and never pulls fuel back out; the Electric Furnace takes what smelts and
gives its results through every face (Core's defaults).
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
  splitting shares them; a broken pipe loses its share, a broken tank its fluid. A buffer holds one
  fluid: a fill never takes in pipes whose network holds another fluid than the pipes it has
  taken in (Mekanism's MechanicalPipe.isValidTransmitter), so fluids never mix, and such networks
  stay apart until one is empty and a later fill joins them (a fill carried over between ticks
  that meets two anyway keeps the largest share's fluid; the rest is lost).
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
- **Fluids** (`Fluids`; water, lava, oil and fuel). Each tick every PULL side takes up to the pipe's
  pull amount (only the buffer's fluid while it holds any, up to the pipes' capacity) from a Fluid
  Tank, or from a machine's output tanks (`Machines.extractFluid`; input tanks never give to pipes);
  then the buffer is split evenly over the acceptors on NORMAL / PUSH sides with room for its fluid
  (Fluid Tanks empty or holding it, machines whose input tanks take it: `fluidRoom` / `insertFluid`,
  the first input tank taking it first), each once, smallest room first; the whole mB left over by
  rounding go to the last ones, and what nobody takes stays. Machines with output tanks push them
  out every tick after their tick (`TransmitterWorld.ejectFluid`, run by MachineWorld; Mekanism's
  ejector at `Machines.FLUID_EJECT_RATE`, 1 024 mB/t), split evenly the same way over the Fluid
  Tanks next to them that take it and the pipes next to them whose side receives (NORMAL, PULL),
  whose buffer is empty or holds that fluid and whose network leads it somewhere (`leadsSomewhere`:
  an acceptor on a NORMAL or PUSH side that takes it; cached per network and tick). Without that the
  pipe feeding a machine would fill with what the machine makes and stop feeding it (the refinery's
  fuel in its oil line): Mekanism avoids it with per-side configuration, which blocks here lack,
  having no facing. For the same reason the ejector skips a Fluid Tank next to it that a pipe PULLs
  from into a network leading that fluid nowhere, or into one not built yet (`suppliesElsewhere`:
  the oil tank right next to the refinery, which, once empty, would take fuel that its oil line then
  pulls and never delivers, and the oil would never move again). Never straight into another
  machine. The pull phase is Mekanism's MechanicalPipe.pullFromAcceptors as it is: it pulls whatever
  a tank holds into an empty buffer, which then waits in the pipe.
- **Replication.**
  - Transmitters / Tanks records (a pipe's fill byte and the fluid id its network holds; a tank's
    fluid id and mB): a chunk's non-default ones go to a player right after its edit list
    (ServerNet's `chunksSent` rule). Changes go each frame to players within 192 blocks
    sideways (to every player not yet seen in the world), compared with what was last sent; pipe
    fills and tank contents go at most every 5 ticks.
  - Transport: items are tracked per player within 64 blocks (gone beyond 72, checked every
    10 ticks). An `add` is sent when an item enters, is re-routed or waits, changes speed, or has
    gone 128 blocks along a route longer than 255 sides; a `remove` when it arrives, drops or
    leaves the player's range. `startTime` is the server time of the tick that produced it.
- **Use** (`Players/ItemUse`, rules in `Transmitters/UseRules`). UseItem from a living player in
  survival or creative (`GameModeRules.mayUseItemOn`: mayBuild), in reach, at most 10 a second,
  with the item in hand:
  - Configurator: cycles the clicked side (a same-kind transmitter beyond it matches, so a cut
    joint is joined again from either end; Mekanism changes only the clicked side), or sneaking on
    a transporter its colour; Mekanism's message in the chat and a click sound.
  - Bucket: a carriable fluid's source, its cave twin too (`Fluids.isSource`), becomes air and the
    bucket that fluid's (Minecraft's createFilledResult: a stack keeps the rest and the full bucket
    goes into the inventory, else is thrown; creative keeps its bucket and gets one of that fluid at
    most). Not sneaking: a Fluid Tank holding 1000 mB, or a machine with an output tank, else an
    input tank, holding that much (`Machines.fillBucket`), loses it (creative gets nothing, as in
    Mekanism). The fluid's own fill sound (item.bucket.fill_lava for lava and oil), else the plain
    one.
  - Full buckets (Water, Lava, Oil, Fuel): not sneaking, a Fluid Tank with room for 1000 mB of that
    fluid, or a machine's first input tank taking it with room for all of it
    (`Machines.pourBucket`); all or nothing. Else the fluid's source (never a twin) in the clicked
    block if replaceable or the block beyond its side; what it replaces drops what it drops by
    itself, lava too (`UseRules.pour`: short grass nothing, a dead bush a stick;
    BucketItem.emptyContents); survival gets the empty bucket back. Block updates take it from
    there (lava meeting water hardens).
  - Sneaking skips tanks and machines. `UseRules.fillBucket` / `emptyBucket` work a use out
    against a BucketEnv (the world, the pipes' tanks, the machines' containers; pure, tested) and
    ItemUse applies it. Nothing is predicted: the snapshot, edits and records bring the results;
    what a machine's tank gained or lost reaches its viewers with the next machine step.

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
- fluid: a pipe's fill byte (its network's) as a level in the core and sideways arms, the arm
  down full whenever there is any, the arm up only from 95 %; a tank's amount / capacity from
  its bottom plate. Each fluid in its colour (`fluidColour`: the record's `color`, from the
  Transmitters record's `fluidId` or the Tanks record's fluid; water's for a record without one),
  water, oil and fuel as translucent "water" boxes, lava as glowing "molten" (Neon) ones
  (`fluidKind`: a fluid that gives light).
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
the same look, so a pipe's changing fluid level only resizes them), at most 4000 parts.

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
the sources of every carriable fluid, cave twins too (`Fluids.isSource`, Minecraft's
Fluid.SOURCE_ONLY), and sends that cell, or a Fluid Tank or a machine with tanks (not when
sneaking); a full bucket (`Fluids.ofBucket`) sends a tank or machine (not when sneaking) or the
clicked block when the cell the server would fill is replaceable. A block with a menu still opens
first unless sneaking, but for a machine with fluid tanks clicked with a bucket that would act on
them (`Interaction/TankUse.acts`, pure, tested): it asks the server's question of the machine's
kind and of the tanks in its last Machines record (`TransmitterRenderer.machine`; without a
record, the server's default: every tank empty). A full bucket acts when an input tank takes its
fluid (`Machines.bucketTank`) and has room for all 1000 mB (empty or holding that fluid); an
empty Bucket when some tank holds 1000 mB of a carriable fluid. Otherwise the screen opens, as
Mekanism's BlockFluidTank opens its GUI when handleTankInteraction moves nothing, so a Fuel
Bucket on a full Combustion Generator, or an empty Bucket on a fresh machine, opens it.

WAILA asks TransmitterRenderer (`state`, `tank`, `connections`, `itemsIn`, `network`: a cached
walk of the connected transmitters) and BlockInteraction.targetSide: "Side: Pull", a
transporter's colour and items, "Lava: ~n / m mB" for a pipe (the fluid its network holds; its
fill byte times the capacity of the pipes the client sees connected; "Empty: 0 / m mB"),
"Lava: n / m mB" for a tank; with F3 the
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
transporter faces, what transporters may take out, `takes`, and an outline shown while empty,
`ghost`), data fields, fields kept in the item, fluid tanks (`tanks`, below), its panel, its server
tick, a status line, optional rate overrides, numbers for JEI (`info`, `Machines.info`) and an
optional state field: a code (0..255, `Machines.state`) saying why it is not working, which Machines
records carry and `status` gets as `view.state`. Its tick gets a context (`TickContext`): the block,
its energy spec and position, the server's day time (`dayTime`, World/TimeOfDay) and whether a cell
sees the sky (`sky(x, y, z)`, below). Its contents are a container of kind "machine" (Types.KINDS)
with the kind's slots and f64 `data` (at most 16): a header every machine shares, 1 energy, 2
capacity, 3 input and 4 output (what the network moved last tick), 5 rate (made +, used -), 6
active, then the kind's fields, then its tanks. Inventory/Menu asks Machines for a machine's slot
rules, limits and outputs, and shift-clicks from the inventory into the slots that take the item in
one pass (Mekanism's MekanismContainer; only when none takes anything does it move between the
inventory and the hotbar). A machine with slots transporters reach is an inventory for them
(Transmitters/Inventories), through the faces its kind gives each slot (by default inputs take items
through every face and outputs give them out through every face); one whose slots no face reaches
(the Solar Panel: upgrade slots only) is none. A machine with output slots pushes what they hold out
on its own (Mekanism's ejector, every 10 ticks, into the transporters and chests next to it: Pushing
results out, above). Energy is kept in multiples of 1/1024 J (`QUANTUM`), so sums and differences
are exact; `produce` and `use` keep it so, and `share` is Mekanism's even split in whole quanta:
every recipient gets the same share, those that take less get all they take and the rest is shared
again, smallest limits first. A kind's `lines(view)` gives up to `MAX_LINES` (4) more panel lines
under its status line, where its panel's `lines = { x, y }` puts the first (`Machines.lines`; one
every 12 pixels, `MenuLayout.LINE_HEIGHT`, as many as fit the panel).

**Fluid tanks** (`Machines/Core`; Mekanism's BasicFluidTank.input / output). A kind's `tanks` each
have a `name` (a data key), a whole `capacity` (mB), the `fluids` they take (Shared/Fluids ids,
carriable ones) and a `role`, "input" (pipes and full buckets fill it, the kind's tick drains it)
or "output" (the tick fills it, pipes and empty buckets drain it); `define` refuses a bad name or
one taken, a capacity that is not whole, a bad role, a fluid that is not carriable or listed
twice, and data past 16 values. Their amounts follow the kind's fields in the data, under each
tank's name (whole mB); a tank taking several fluids also keeps its fluid id under "<name>Fluid"
(0 while empty). `tick` keeps them whole, in range and of a fluid they take, and `save` /
`restore` keep them in the item like energy (the tooltip reads "Lava: 5,000 mB"). The rules are
Mekanism's, the same through every side (blocks have no facing): pipes fill input tanks that take
their fluid (`insertFluid`, in tank order) and drain output tanks (`extractFluid`; inputs never
give to pipes), and a machine pushes its outputs into the pipes and Fluid Tanks around it (the
server's ejector, up to `FLUID_EJECT_RATE`, 1 024 mB/t, Mekanism's fluidAutoEjectRate); a full
bucket pours its 1000 mB into the first input tank with room for all of it (`pourBucket`;
`bucketTank` names it), and an empty one takes 1000 mB from the first output tank holding that
much, else from the first input tank that does (`fillBucket`, Mekanism's MANUAL access). A kind's
tick uses `tankAmount`, `tankRoom`, `tankInsert` and `tankExtract`; `takesFluid`, `givesFluid`,
`fluidRoom`, `hasTanks`, `inputTanks` and `outputTanks` answer for the pipes, and `tankContents`
lists what each holds (Machines records, WAILA). Panels draw a gauge per tank with a `gauge`
(`gauges`: an 18 x 60 frame by default, Mekanism's GaugeType.STANDARD, the fluid filling the
inside's 58 rows to round(amount / capacity x rows), `gaugeLevel`; `tankLine` the text).
`showActive` is Mekanism's setActive with its 60 tick blockDeactivationDelay
(`DEACTIVATION_DELAY`), for kinds with an `activeDelay` field (the Electric Furnace, the Oil
Refinery): on at once, off only after 60 ticks stopped, so a machine on too little power glows
steadily.

**On the server** (`server/Machines/`). `MachineWorld` (pure) keeps a machine per machine block
(`blockChanged`, chained onto WorldServer.onChanged after Inventories and Transmitters) and
creates its container in Players/Containers at once, so a machine works before anyone opens it;
machine containers are never forgotten while their block stands, and a broken machine's slots
drop through Inventories like a chest's. Each `step` (20 a second, Machines.update right after the
pipes): queued network work, every machine's kind tick (`Machines.tick`: afterwards, even when the
kind's tick errors, which is reported once per kind, the data holds no NaN and energy is within
0..capacity in whole quanta), a machine with output tanks pushing them out after its tick
(`TransmitterWorld.ejectFluid`, see Mekanism pipes: Fluids), then `EnergyNet.solve` (a kind whose
`rates` override errors moves nothing). `EnergyNet` (pure) joins cables (`links`), cables and
machines (`acceptors`) and directly adjacent machines into networks; positions whose links changed
dissolve their network and their neighbours' and are flood filled again, at most 4096 a tick (the
rest carries over and waiting positions move nothing meanwhile). A change at or next to a position
the fill in progress has visited starts it over; one elsewhere leaves it going, so players building
elsewhere never starve a big network's fill. Per network and tick: producers' supply (their energy,
at most their output rate) goes to consumers' demand (their room, at most their input rate), at most
the throughput (the cables' capacities summed, unlimited without cables), split evenly both ways;
what producers still have charges storage up to its input rates, and what consumers still need is
covered by storage discharging up to its output rates, within the throughput left. Storage never
charges storage. What is taken is exactly what is given.

Viewers of a machine's window get a snapshot at once when its slots change and every 2 ticks
while only its data moves (as furnaces); the data is compared with what it was after the last
step, so fluid that pipes or buckets put into a machine's tanks between two steps counts too.
`Machines` records (energy, capacity, input, output, rate, active, the kind's state code and its
tanks' contents, `Machines.tankContents`) go to players within 192 blocks sideways when they
change (a tank alone changing too), at most 4 a second per machine, and with a chunk's edit list
when not in the default state (empty, idle, the block's capacity, state 0, every tank empty), so
a machine holding only fluid is sent. Mekanism's sustained data (`MachineWorld.blockDataHooks`): a
survival break keeps the energy and the kind's `keep` fields in the item's data (`Machines.save`;
the creative cube keeps nothing), and placing that item puts them back (`Machines.restore`, at most
the capacity).

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
may also join cables through machines), and then each of a machine's tanks from its record
("Oil: 3,000 / 10,000 mB", "Empty: 0 / 10,000 mB"; without a record, every tank empty). A
machine's panel (MenuLayout) is its kind's: slots where it puts them (a slot with a `ghost` shows
that outline while empty, as empty armor slots do: the upgrade cards'), the title centred,
Mekanism's GuiVerticalPowerBar (6 x 52 at (164, 15), filling from the bottom in whole rows rounded
down, at least one while it holds any, red when empty through yellow to green when full, "stored /
capacity" on hover), a fluid gauge per tank with a `gauge` (Mekanism's 18 x 60 GuiFluidGauge,
`MenuLayout.tanks`: a sunken frame, the fluid's colour filling `tankRows` of its 58 rows from the
bottom, `Machines.gaugeLevel`, under scale marks, a long one every quarter and short ones between;
water and fuel show a little of the frame's back through them; "Lava: 5,000 mB" and "Capacity:
24,000 mB" on hover, `tankTooltip`), and the arrow, flame, status line and lines it asks for, read
from the data fields it names. The panel reads the window's data without changing it and redraws
only when a snapshot replaces it. Machines whose decor has a window
(`TransmitterModel.hasMachineBoxes`: the Heat Generator, the Electric Furnace, the Oil Refinery and
the Combustion Generator) are TransmitterRenderer cells like tanks, redrawn on each record:
`machineBoxes` gives a working one a Neon pane over its window on each of its four sides
(BlockDecor.GENERATOR_WINDOW, ELECTRIC_FURNACE_WINDOW, REFINERY_WINDOW and COMBUSTION_WINDOW, 0.2 px
out of the face). `activeMachines(x, y, z, radius, filter)` lists the working machines near a point
from their records (Audio/Ambience). Batteries (`hasMachineBoxes`) are cells too: `machineBoxes`
fills each side's gauge (BlockDecor.BATTERY_GAUGE) from the bottom with `chargeRows` of its 10 rows
(the record's energy over capacity, rounded down, at least one while it holds any, as the panels'
bar), a Neon pane in `Machines.energyColour` of that fill (red when nearly empty, yellow, green when
full; the panels' energy bar and items' energy bars use the same function); the signature names the
rows, so a battery is redrawn only when a whole row changes. A machine's item whose data holds
energy shows an energy bar where the durability bar goes (`MenuLayout.energyItemBar`: 13 pixels x
energy over the block's capacity, rounded down, at least 1; Mekanism rounds to the nearest pixel,
uses 0x3CFE9A and draws it on Energy Cubes only, empty ones too; `ItemIcon:set(item, count, damage,
data)`, which Hud, InventoryScreen and the carried stack pass the stack's data to).

**The Creative Energy Cube** (kind "creative"): infinite capacity and output, always full,
gives whatever its network takes; creative only (no recipe).

**The Heat Generator** (kind "generator", `Machines/Kinds/Generator`; Mekanism Generators').
BlockList `HeatGenerator` has `energy = { capacity = 160 000, output = 400 }`: a producer whose
output is above the most it makes, so a network takes all of it. One burner makes 200 J a tick
(Mekanism's heatGeneration) while it burns, fed two ways:
- solid fuel in its fuel slot: what `Smelting.fuel` burns and leaves nothing behind, from every
  face, burning for its furnace burn time (a coal 320 kJ);
- lava in its lava tank (Mekanism's TileEntityHeatGenerator lavaTank: input, 24 000 mB, its gauge
  at (7, 13); MekanismGenerators 10.4's tankCapacity), filled by pipes and buckets (Fluid tanks,
  above), and by Lava Buckets put in the fuel slot, poured in once all 1000 mB fit, leaving the
  empty Bucket in the slot (Mekanism's FluidFuelInventorySlot.fillOrBurn, which gives up on a
  stack of more than one). A mB of lava burns for LAVA_TICKS_PER_MB (20) ticks, so a bucket is
  20 000 ticks, 4 MJ: the Lava Bucket's furnace burn time, 12.5 coal, Mekanism's own ratio (it
  turns a solid fuel into burn time / 20 mB of lava). Its heatGenerationFluidRate (10 mB a tick, a
  bucket in 100 ticks for 20 kJ, a sixteenth of a coal) is left out, because solid fuels here burn
  their whole furnace time.
What lights next: an item already burning burns out first, then a mB from the tank, then the next
solid item (Mekanism turns items into lava only while its tank has room, so piped lava keeps it
busy too). Transporters take out of the fuel slot, through every face, only what it would not
take in (`takes`: the empty Bucket; never coal or a Lava Bucket), so a line feeding it never jams
on the bucket; the hand takes anything. Every side touching lava (any level, CaveLava too:
`Fluids.ofBlock`) adds LAVA_PER_SIDE (30) J/t (Mekanism's getBoost, heatGenerationLava), burning
or not and with no fuel at all, and that free heat counts first: up to 180 J/t, 380 J/t in all,
within its output. Data 7 is `burnTime` (ticks left of what is burning, a fraction after a part
tick), 8 `burnTotal` (its burn time, 20 for a mB of lava, 0 while out), both clamped to the
longest solid fuel's burn time (`MAX_BURN`), and 9 the tank's `lava`. It burns only what it has
room for (`produce`, so at most its room): what is left burning is counted in whole energy quanta
(`TICK_QUANTA` = 200 J / QUANTUM a tick), so a nearly full generator burns part ticks and no
energy is made or lost. Fuel lights only when there is room (an item, or a mB, is used up then,
both fields its burn time); one that runs out partway through a tick lights the next, which makes
the rest of the tick, and one out at the end of a tick lights the next at once, so neither the
flame nor the output dips between items. Full, it keeps what is burning and lights nothing new.
RATE is what it made (the burner and the lava around it), ACTIVE whether the burner made anything
(Mekanism's active: burning); its status line ((30, 20), right of the lava gauge) is
"Producing 200 J/t" or "Idle". Its item keeps its energy, both burn fields and its lava (tooltips
"Fuel: 60 s", a describer the kind adds, and "Lava: 5,000 mB"). Left out: Mekanism's heat model
(heat capacitor, losses to the air and below, Carnot efficiency), the nether bonus, the
lava-logged seventh side and turning solid fuels into lava (they burn as they are, for the same
energy). JEI lists it as a fuel catalyst and the heating category's (`info`: heatGeneration,
lavaPerTick 1/20, lavaPerSide, maxBurn).

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

**The Oil Refinery** (kind "refinery", `Machines/Kinds/Refinery`; BuildCraft's refinery on
Mekanism's electricity). BlockList `OilRefinery`, `energy = { capacity = 40 000, input = 40 000 }`
(its `rates` take up to its capacity a tick, as Mekanism's machine energy containers take any
amount). Tanks: oil (input, 10 000 mB, gauge (7, 13)) and fuel (output, 10 000 mB, gauge (57, 13));
slots: its Speed and Energy Upgrades only (`Upgrades.slots(82, 53)`, no transporter reaches them,
so it is no item inventory). It turns oil into fuel 1:1 (BuildCraft's recipe, without its heat
and gas by-product): a bucket is its operation (as Mekanism's Electric Pump's), taking
`Upgrades.ticks(100, speed)` ticks (74 with one Speed Upgrade, 10 with 8), so 10 mB a tick, moved
in whole mB with the fraction carried in `progress` (mB of the bucket refined, the arrow's fill),
at `Upgrades.energyPerTick(200, speed, energy)` J a tick, all or nothing, from a store of
`Upgrades.capacity(40 000, energy)`: 200 J/t and 20 kJ a bucket, 100 mB/t at 20 kJ/t with 8 Speed
Upgrades. Short of oil or fuel room it refines what it can for that share of the tick's energy, so
no oil is ever stuck; no oil is idle (the bucket starts over), no fuel room "Output full", too
little energy "No power" (state codes 0, 1, 2; Mekanism pauses on all three). Data: 7 progress, 8
ticksRequired, 9 energyPerTick, 10 state, 11 activeDelay, 12 oil, 13 fuel. RATE is minus what it
used, which its status reads ("Using 200 J/t"); ACTIVE is `showActive`'s. Its panel: the oil gauge,
Minecraft's arrow at (29, 35) and the fuel gauge in a row, the status at (82, 20) and the upgrade
slots at (82, 53) and (100, 53). Its fuel goes out on its own through the ejector (Mekanism pipes:
Fluids). Its item keeps its energy and both tanks; the cards drop. Recipe: "IGI", "OFO", "IBI"
(iron, glass; osmium, a furnace; a bucket): Mekanism's machine shape around BuildCraft's
refinery, osmium standing for Mekanism's steel and circuits.

**The Combustion Generator** (kind "combustion", `Machines/Kinds/Combustion`; BuildCraft's
combustion engine as a Mekanism generator). BlockList `CombustionGenerator`, `energy = { capacity
= 1 000 000, output = 5 000 }`: a producer whose output is twice what it makes. One input tank,
fuel (10 000 mB: 100 MJ, gauge (7, 13)), no slots. It makes PRODUCTION (2 500) J a tick and a mB
burns for TICKS_PER_MB (4) ticks (ENERGY_PER_MB, 10 kJ), so a bucket burns 4 000 ticks (200 s) and
makes 10 MJ, the strongest fuel: 2.5 Lava Buckets or about 31 coal in a Heat Generator, 500 times
the 20 kJ refining it costs, and one refinery's 10 mB/t keeps 40 of them burning. Like the Heat
Generator it makes only what it has room for: a mB is taken from the tank when it lights (only
with room) and burns over the next ticks, and with less room than a tick's 2 500 J it makes what
fits and keeps the rest of its mB burning (`burning`, data 7, 0..1 mB counted in energy quanta,
kept in the item), so no fuel is wasted and no energy made or lost by rounding; data 8 is the
tank's `fuel`. RATE is what it made, ACTIVE whether it made anything; status "Producing 2.5 kJ/t"
or "Idle" at (30, 20), right of the gauge. Its item keeps its energy, fuel and `burning`. `info`:
fuelPerTick 1/4, energyPerMb 10 000. Recipe: "OBO", "IFI", "ODO" (osmium, a bucket; iron, a
furnace; glow dust): Mekanism's generator shape around BuildCraft's engine, glow dust standing
for redstone as in the cables. Left out: BuildCraft's coolant and heat.

**A new machine:** a BlockList block with `machine` and `energy`, a module in
`Machines/Kinds/` returning `Core.define(name, spec)`, and a line requiring it in
`Machines/init`. A kind with fluid tanks gives `tanks`; pipes, buckets, the ejector, gauges,
records and the item follow from their roles. Tests bind test-only kinds to spare blocks
(`Machines.bind`).

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
100 kinds of block in noise ~130,000 (encoded in ~15 ms, decoded in ~10 ms in Lune; ~50 and ~30 ms
interpreted); any 48³ structure stays under ~150,000, inside `Config.Structures.MaxDataChars`
(200,000, what a StringValue holds).

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
  operators always (Players/Operators.permitted: the game's owner, `Config.Gameplay.Admins` and
  Studio sessions among them), else `Config.Structures.Permission` (a list of user ids, by
  default none; true for every creative player, false for nobody).
  `StructureBlocks.operator(player)` asks it; it is ServerNet's `operator` rule for placing and breaking operator blocks
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
  (at most 2,048 markers, in regions of at most 16,384 cells). Like Minecraft's, it shows only in
  creative (instabuild) and to spectators.

## Item entities (`Entities/`)

Dropped items are Minecraft's ItemEntity:
- `Entities/ItemPhysics` (shared) is its movement, one 20 Hz tick on a 0.25 block box:
  - gravity 0.04 and drag 0.98, ground friction (ice slides);
  - fluids in Minecraft's two tags by their record's `physics` (Shared/Fluids `blockLut`, twins
    included): "water" (water, fuel) and "lava" (lava, oil), water's first. Touching one pushes the
    item along its flow, normalised, times the deepest fluid's `push` (water and fuel 0.014, lava
    and oil 0.0023333), at least 0.0045 while it is nearly still sideways
    (Entity.updateFluidHeightAndDoFluidPushing); deeper than 0.1014 above the box's bottom, the item
    floats (+0.0005 while slower than 0.06 up) with its horizontal speed x 0.99 in water's tag
    (setUnderwaterMovement) or x 0.95 in lava's (setUnderLavaMovement), water winning where both
    are deep enough. The check runs again at the end of the tick, as ItemEntity.tick does. Water
    behaves as before; a floating item costs about 3 µs a tick in Lune;
  - pushed out of blocks placed on it;
  - collision through `Hull`.
- `EntityWorld` (server, pure, tested) holds the rules:
  - pickup delay 10 ticks (40 when thrown);
  - pickup by a player box grown by (1, 0.5, 1), living players only, never spectators;
  - merging of equal items (the smaller into the larger, every 2 ticks while moving, 40 at rest);
  - despawn after `Entities.ItemLifetime`; at most `Entities.MaxItems`;
  - explosions (`explode`): see Explosions;
  - burning (`Players/Burning.tickItem`, after the move): lava takes 4 of an item's 5 health a tick
    and sets it burning (water puts it out), so an item touching lava is gone the tick after
    (Minecraft's Entity.lavaHurt); each lava hurt is in `takeChanges().burnt`, where Entities plays
    entity.generic.burn. Over 1000 resting items the check is ~6% of the tick (9% interpreted).
- `Entities` replicates the items within `Entities.TrackingDistance` of each player: spawns, a
  sync every 20 ticks while moving, count changes, and removals naming who picked them up.
- Clients run the same `ItemPhysics` between syncs, ease corrections in, and draw items bobbing and
  spinning (more copies for bigger stacks). A picked-up item flies to the player.

## Mobs (`Entities/MobList`, server `Mobs/`, client `Entities/MobRenderer`)

Minecraft 1.20.1's farm animals and classic monsters as plain hitboxes. Tested in
`tests/spec/Mobs` (server and shared) and `tests/spec/MobsClient`.

**Kinds** (`Shared/Entities/MobList`, append only: a kind's id is a u8 on the wire). Each record
holds Minecraft's numbers (box, eyes, health, MOVEMENT_SPEED, armor, attack damage, the goals'
speed modifiers), its abilities (`burnsInDaylight`, `slowFall`, `fallDamage`, `climbs`,
`darkOnly`, `leap`, a creeper's `fuse`, a skeleton's `bow`), its loot, spawn weight and group,
hurt and death sounds, and how the client draws it (at most 2 boxes, `variants` recolouring the
first: sheep's natural colours by Minecraft's odds). The registry resolves the loot to item ids
at load (a typo fails loudly).

| Kind     | Box          | Health | Speed | Does                                                              |
| -------- | ------------ | ------ | ----- | ----------------------------------------------------------------- |
| Cow      | 0.9 × 1.4    | 10     | 0.2   | wanders, panics (x2); leather 0-2, beef 1-3                       |
| Sheep    | 0.9 × 1.3    | 8      | 0.23  | wanders, panics (x1.25); white wool, mutton 1-2                    |
| Pig      | 0.9 × 0.9    | 10     | 0.25  | wanders, panics (x1.25); porkchop 1-3                              |
| Chicken  | 0.4 × 0.7    | 4      | 0.25  | falls x 0.6 a tick, no fall damage; feathers 0-2, chicken          |
| Zombie   | 0.6 × 1.95   | 20     | 0.23  | armor 2, hits 3, burns by day; rotten flesh 0-2 (+2.5% iron)       |
| Skeleton | 0.6 × 1.99   | 20     | 0.25  | shoots within 15 (3-5, every 60 ticks), burns by day; bones 0-2    |
| Creeper  | 0.6 × 1.7    | 20     | 0.25  | 30 tick fuse within 3, cancelled at 7, power 3; gunpowder 0-2      |
| Spider   | 1.4 × 0.9    | 16     | 0.3   | hits 2, climbs, leaps, hunts only in the dark; string 0-2          |

**Movement** (`Shared/Entities/MobPhysics`, pure): LivingEntity.aiStep and travel for a mob
steered by its AI: `forward` (Minecraft's zza: speed x modifier x 0.98) along its yaw (facing
(sin, cos)), the jump. Ground acceleration speed x 0.216 / f³ (so a zombie walks 0.114 blocks a
tick, 2.3 a second: tested), air 0.02, gravity 0.08, x 0.98 vertically and f x 0.91 sideways;
water's tag (water, fuel) 0.02 / x 0.8 / sinking 0.005, lava's tag (lava, oil) x 0.5 and
gravity / 4; jumping 0.42 off the ground 10 ticks apart or 0.04 in a fluid deeper than 0.4 (how
FloatGoal keeps mobs up); a ledge at the surface is hopped out of (0.3). Collision is `Hull` with
Minecraft's mob step of 0.6, so a full block takes a jump; a spider pushing into a wall climbs
at 0.2 a tick. The fall distance (cleared in water, halved in lava) comes back on landing.
`dropAt` answers how far the floor is below a step (nil beyond the depth: a cliff).

**AI** (`server/Mobs/MobAI`, pure): direct steering, no path finding.
- Wander (RandomStrollGoal: one tick in 120, a spot 3-10 blocks away, at most 100 ticks), stand
  idle between; panic (creatures hurt by anything: 3-5 s at `panic` speed away from the hurt's
  source); float (jump 4 ticks in 5 when deeper than 0.4 or in lava).
- Steering faces the goal and walks; a wall is jumped (a spider climbs it). `safeAhead` refuses a
  step into an unloaded cell, a hazard (fire, campfire, lava, oil, fuel: `hazard`) or over a drop
  of more than 3 blocks (the path finder's max fall): the mob stops (a stroll ends, a panic picks
  another spot).
- Targets: every 10 ticks (staggered by id) a monster without one looks for the nearest living
  survival or adventure player (never creative or spectator: `attackable`) within `follow` (16)
  it can see (`canSee`: a voxel ray from its eyes to theirs, solid blocks stop it); it keeps the
  target while in range and attackable, and drops it after 60 ticks out of sight. Hurt by a
  player, it hunts them (HurtByTargetGoal). Spiders notice players only under raw brightness 8
  (the open sky by the time of day, else `LightEstimate.blockLight` with a 64 cell budget) and
  give up 1 tick in 100 in the light.
- Melee (zombie, spider): Minecraft's reach (distance² ≤ (2w)² + 0.6) with the target in sight,
  every 20 ticks: a `hits` record with the damage and a 0.4 knockback away from the mob
  (`Combat.knockback`). A spider leaps at a target 2-4 blocks away one tick in 5.
- Creeper: SwellGoal and Creeper.tick: the goal runs while the fuse burns or a target is within
  3 blocks (standing still), the fuse lights (+1 a tick; the hiss on the first) while the target
  is seen within 7, else cools (-1); at 30 an `explosions` record (power 3) and the creeper is
  gone (no loot, no death record).
- Skeleton: RangedBowAttackGoal on normal: `seeTime` counts the target in sight; with it seen 20
  ticks within 15 blocks it stands; a 20 tick draw, then a hitscan shot and a 40 tick reload. A
  shot hits with 1.15 - distance / 15 (0.25..0.95) for 3-5 with a 0.4 knockback, else flies 1.5
  blocks off; either way an `arrows` record (the clients draw it) and the bow's sound.

**The world** (`server/Mobs/MobWorld`, pure, `MobWorld.new(getBlock, options)`): mobs by id in id
order, ticked at 20 Hz (`tick(context)`: the players as PlayerViews (feet, eye height, game
mode, alive), the day time, `skyOpen`, `skyClear` and `active(cx, cz)`). Frozen (`frozen`) when
its chunk doesn't tick or its cell isn't loaded. Each live mob: AI, physics, fall damage (ceil(d
- 3), bypassing armor; not chickens), daylight burning (by day, out of water, the sky over the
eyes at full light: `skyClear`, World/Skylight.clear, Level.canSeeSky's sky light 15, so leaves
and fluids shade and glass doesn't; 1 tick in 25 → 8 s),
`Players/Burning.tickPlayer` as for a player (lava, fire, campfires, burning, water; a mob
catches fire after 20 ticks in a fire block like a player, Minecraft's mobs at once) and
suffocation (eyes in an opaque block, 1 under the cooldown).
- `hurt(id, amount, source)`: Burning.hurtPlayer's LivingEntity cooldown (10 ticks: only a bigger
  hurt lands, by the difference) and the kind's armor unless `bypassArmor`; a fresh hurt flashes
  10 ticks (`hurtTime`), sounds, knocks back (`source.knockback` from (x, z)), and makes creatures
  panic or monsters hunt the player. A player's hurt counts for the kill 100 ticks.
- Death: the death sound, a `deaths` record (kind, position, killer or nil), 20 ticks lying (the
  dying flag), then the loot (`kindDrops`: min..max, `chance`, `byPlayer` only with a killer; raw
  meat cooked when it died burning: `Foods.COOKED`) and gone; the 20 ticks count in a frozen
  chunk too (the body still), so /kill's far mobs go. `kill(id)` is /kill's death.
- `overlaps(box)`: is any mob's box (dying ones too) in it? ServerNet refuses a block placed
  inside a mob (its `occupied` rule, `Mobs.occupied` with the block's Blocks.obstruction: Level.
  isUnobstructed), as inside a player; the client checks the mobs where it draws them first.
  Otherwise a block in a monster's head cell would blind it (no melee, fuse or shot) until the
  wall smothered it.
- `explode(x, y, z, power)`: Explosion.seenPercent / hit on each live mob in reach: the damage
  through `hurt` and the push added to its velocity.
- `attack(id, attacker)`: refused for the dead, spectators (`Combat.reach` 0), dying or gone mobs,
  a box beyond the mode's reach from the eyes (+ `SERVER_LEEWAY` 1), or out of sight (the mob's
  centre, eyes and feet); else the held item's damage, with the attacker's Strength and Weakness
  (`levels`: Effects.meleeDamage, as Minecraft's attack_damage modifiers) x 1.9's strength
  (`Combat.strength(ticks since the swing or the change of item, speed)`) with a 0.4 knockback;
  returns the landed hurt and whether it was strong.
- Despawn every 20 ticks over every mob (Mob.checkDespawn): nothing with no players; monsters
  beyond 128 blocks of every player go, beyond 32 after 600 idle ticks one check in 40 (a frozen
  monster's idle time counts on in this check: the chunks that tick reach about 56 blocks,
  Minecraft's simulation distance past 128, where its monsters would tick and idle away);
  creatures with no player within 128 for `ForgetTicks` go; below y -64 anything.
- `takeChanges()`: spawned, removed, deaths, drops, hits, arrows, explosions, sounds.
Measured in Lune on a flat world with a player (mixed kinds, at night): 50 / 150 / 300 mobs
cost 0.14 / 0.45 / 0.85 ms a tick native, 0.44 / 1.35 / 2.76 ms interpreted (~9 µs a mob).

**Spawning** (`server/Mobs/MobSpawning`, pure): monsters every `HostileInterval` (20) ticks,
creatures every `PassiveInterval` (400), for each living non-spectator player whose 128 block
census is under `HostileCap` (15) / `PassiveCap` (10) and the world under `MaxHostile` /
`MaxPassive` / `MaxMobs`: `Attempts` (3) packs, each a kind by spawn weight, a column 24-44
blocks out (`SpawnDistance`) in a chunk that ticks (the census counts a player's monsters only
in those chunks: frozen ones farther out would fill the cap with none about the player, and they
idle away), its centre the first standing spot down the
column (creatures from 20 above the player's feet over 48, monsters from ±16 over 24), 2-4 /
1-4 members spread ±4, each on its own spot within 3 up or down. `validSpot`: the chunk ticks, a
solid opaque sturdy floor (grass or dry grass for creatures), the box free (no solid, unloaded,
fluid, fire or campfire cell: Hull and Burning.touching), no rail in the feet's cell or the
one above (Minecraft's `#prevent_mob_spawning_inside`; a cobweb does not stop a spawn, as
NaturalSpawner.isValidEmptySpawnBlock allows), 24 blocks from every player, and the
light: creatures raw brightness above 8, monsters Minecraft's two rolls
(`LightEstimate.darkForMonsters`) and then no block light (searched with `SPAWN_BUDGET`, only
for the spots the rolls let through). Measured on generated terrain (seed 12345, a player
switching between two spots 80 blocks apart every 2 minutes at night): before, 15 monsters
within 128 blocks of which 10-12 frozen at the old spot, none spawning about the player; now
14-15 ticking about the player within a minute of arriving and 4-11 frozen ones idling away.

**Light** (`Shared/World/LightEstimate`, pure, shared): `blockLight` (the search the cave mood
used, moved here: sources less one per open cell, 256 cells, no allocations; a monster's spawn
check `SPAWN_BUDGET` 2048, every cell a torch lights (13 steps) in a room of any height or on the
open ground, stopping at the first light found: a torch 12 blocks off in a 2, 3 or 6 high hall
gives 2, where 256 cells reached 8 blocks; ~0.7 ms a dark open-ground search interpreted, 0.1
with 256), `skyLight` (15
where `open`, else 15 less the steps to the nearest open cell through open cells within 48:
an overhang's edge 14, a cave 0; the server's `open` is World/Skylight.open), `darkForMonsters`
(Monster.isDarkEnoughToSpawn: block light 0, sky ≤ rand(32), max(sky - skyDarken, block) ≤
rand(0..7)) and `brightForAnimals` (> 8). WAILA's block light and Audio/CaveMood use the same.

**On the server** (`server/Mobs/Mobs`): 20 Hz on Heartbeat (4 ticks a frame at most). Every 10
ticks the ticking chunks from `Simulation.activeChunks` (a key set); players from their
characters (Rig.feet, eyes 1.62). After each tick: sounds (Audio/Sounds), deaths (the `died`
BindableEvent: killer Player or nil, kind, x, y, z, id), loot (Entities.spawnItem), hits
(`Characters.hurt`: Burning.hurtPlayer's cooldown and the armor worn, then Resistance; a fresh one
queues a `push` for the player), creepers' blasts (`Explosions.explode`, power 3 at the feet: a blast like any,
which reaches the boot script's handler and so `Mobs.explode` for the other mobs), arrows
(queued for players within tracking range). Every `SyncTicks` (2) each player gets one Mobs
message: spawns for mobs coming within `TrackingDistance` (64; 128 spawns a message at most),
states of known mobs whose quantized state changed (a per-player copy of what was sent), removes
for those that left or are gone, and the queued arrows and push. Attacks: a token bucket of
`AttacksPerSecond`, the held item (Inventories.heldTool, watched every tick for the attack
strength's reset), `MobWorld.attack` with the player's effect levels (Players/Effects.levels),
the strong or weak attack sound, the weapon's wear
(Combat.wear: swords 1, tools 2; not with instabuild). Placing: `Mobs.occupied(block, x, y,
z)` (ServerNet's `occupied` rule). /summon and /kill: TextChatCommands (or
Chatted), SummonCommand's parse and the operators' permission (Players/Operators.permitted). The boot script connects `died` to
Players/Progression.killed for a player's kills (the kind's first a discovery, then
Knowledge.MOBS: animals 2, monsters 5, creepers 6).

**Combat and food** (`Shared/Entities/Combat`, `Shared/Items/Foods`, pure): ItemList's `attack`
(swords 4-7 at 1.6 a second, axes 7-9 at 0.8-1, pickaxes 2-5, shovels 2.5-5.5, hoes 1, the hand 1
at 4), `strength` (Player.getAttackStrengthScale(0.5)), `damage` (x (0.2 + s² x 0.8)), `reach`
(3, creative 6, spectators 0), `knockback` (LivingEntity.knockback), `wear`. Foods: heal (cooked
beef and porkchop 4, mutton and chicken 3, raw 1-2, rotten flesh 2) and an optional effect
(raw chicken 30%, rotten flesh 80%: TAN's Thirst effect 600 ticks, Minecraft's Hunger), `canEat`
(hurt or invulnerable, never a spectator), `COOKED`. The 32 tick hold is Drinking's: client
`Interaction/Eating`, server `Players/Eating` (start / finish / cancel, the time, slot and item
checked, health += heal scaled to MaxHealth, one item used up outside creative, the burp).

**On the client** (`Entities/MobRenderer`, `Entities/MobModel`): MobModel (pure) glides each mob
from where it is drawn to the new state over the sync interval (yaw the short way; > 8 blocks
snaps), colours parts (the variant, hurt → 0.7 of the way to red, a lit creeper flashing white
faster as it burns), tips a dying mob over 1 s (sqrt(progress x 1.6) x 90°) and picks the nearest
live box on a ray. MobRenderer takes the Mobs messages from the moment it loads (the boot script
requires it before anything waits), its parts in a folder kept out of the workspace until `start`:
the server sends a spawn once and then only changes, so a message dropped by ClientNet's backlog (64
a kind, ~6 s of the stream) while a slow client booted left mobs invisible or ghosted for good.
MobRenderer: anchored, non-colliding, non-queried Parts from a pool (128 spare), one BulkMoveTo a
frame after the camera, colours written only on change, a Fire (BurningView's colours) on a burning
mob's body, arrows as thin shafts flying at 32 blocks a second (at most 32), `push` ops to
`MovementController.knockback`. BlockInteraction aims at mobs first (`mobOn`: MobRenderer.pick on
the aim ray, then the box within Combat.reach of the hull's eyes): a mob nearer than the block hides
it (no outline, no mining, no placing) and a press (a tap on touch) sends Attack. WAILA
(`pickEntity`) names mobs as items and players (`WailaInfo.mob`: name, "Health h / max", F3: kind,
id, position; a colour box icon).

## Sounds (`Sounds/`, server `Audio/Sounds`, client `Audio/SoundPlayer`)

Sounds are Minecraft's sound events, played with files that ship with every Roblox client.

**The catalogue** (`Sounds`, from `Sounds/SoundList`). Events are numbered by position: the block
events first (`Blocks.SOUND_TYPES` x the five actions), then SoundList's list, in a fixed order,
so the server and clients agree on the numbers without sending names. Each event has a file, a
volume and pitch (final: Sound.Volume and PlaybackSpeed), a random pitch variance, the distance it
carries (16 blocks), the volume setting it follows (`source`), and who plays it (`side`). The list
ends with the cave moods, built from `Sounds/MusicList.Moods` (`ambient.cave.mood1`..., category
`ambient.cave`, client side, volume 0.5, falling back on the stand-in wind; `Sounds.MOODS`); the
music is not in the catalogue (Audio/Music plays it, following the `music` source volume).
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
- Lava (appended at the end of the list): `block.lava.pop` and `block.lava.ambient` (lava open to
  the air, each client by itself), `block.lava.extinguish` (LiquidBlock.fizz: lava hardening and
  lava turning water into stone; volume 0.5, pitch 2.6), `item.bucket.fill_lava` and
  `item.bucket.empty_lava` (lava's and oil's buckets: Fluids `fillSound`, `emptySound`; their
  categories are the plain bucket sounds), `entity.generic.burn` (a lava hurt, a player's or an
  item's: volume 0.4, pitch 2..2.4) and `entity.generic.extinguish_fire` (water putting a burning
  player out: volume 0.7, pitch 1.6 ± 0.25, Minecraft's ± 0.4 triangle flattened). They carry
  Minecraft's numbers themselves, so the server plays them with no cue volume or pitch on top
  (`SoundRules.playback` multiplies the two). Stand-ins: the splash pitched down for the pop and
  the buckets, the falling wind pitched up into a hiss or down into a bubbling rumble.
- Fire (appended at the end, after Tough As Nails' drinking): `block.fire.ambient`
  (BaseFireBlock.animateTick, each client by itself: every fire within 32 blocks the client knows, `FireRenderer.firesNear`, rolls
  each tick the odds Minecraft's display ticks give a block at its distance, 667 × the product of
  (16 - |d|) / 256 over the axes plus the same for 32, times 1 / 24, `SoundRules.fireCrackle`; cue
  volume 1..2, pitch 0.3..1; at most 4 at once), `block.fire.extinguish` (level event 1009,
  punching a fire out: volume 0.5, pitch 2.6; category block.break, side predicted) and
  `item.flintandsteel.use` (the server, at the new fire). A block may have its own action sounds
  (`SoundList.BLOCK_SOUNDS`, read by `Sounds.block`): Fire's break is the extinguish hiss, so the
  client's playBlock and ServerNet's break sound need nothing new. Stand-ins: the falling wind
  pitched down into a roar and up into a hiss, the volume slider's tick for the strike.
- The campfire (appended after the cave moods, at the very end of the events): campfires crackle
  with `block.fire.ambient` (they are FireRenderer's records too), and dirty water boiled on one
  bubbles with `block.campfire.boil` (this game's; the server, at the campfire: Players/ItemUse;
  the splash pitched up). Straw and leaf armor go on with `item.armor.equip_leather`
  (`SoundList.ARMOR` prefixes "Straw" and "Leaf").

**Who plays what** (Minecraft's split between server and client):

| Side        | Events                                                     | How                              |
| ----------- | ---------------------------------------------------------- | -------------------------------- |
| `predicted` | block break / place / fall (fire's break: its hiss), player small / big fall | the acting client at once; the server sends everyone else |
| `server`    | chest open / close, item pickup, tool break, hurt, death, armor equip, buckets, lava's fizz, burn, extinguish, explosions | the server sends everyone near, the player included |
| `client`    | mining hits, footsteps, splash, swim, clicks, furnace crackle, cave moods, lava pop and ambient, fire crackle | clients only, never sent |

**The server** (`Audio/Sounds`) queues sounds and, once a frame, sends each player whose feet are
within the event's distance (times a volume above 1, at most 2.55) plus `Sounds.BroadcastSlack`
blocks one `Sound` message with all of theirs, at most `Sounds.MaxPerFrame`, leaving out the player
whose client predicted it. Sounds a player's own messages cause (chest lids, armor put on) use up
that player's budget (`Sounds.PlayerRate` a second, bursts of twice that), so a client spamming
inventory or Use messages can't stream sounds to everyone near. Hooks: ServerNet (players' breaks
and placements), Behaviours/Attached (torches popping off; water washing one away is silent, as in
Minecraft), Behaviours/Plant (plants popping off), Containers' `onOpeners` (first opener in, last
out; spectators look in without opening the lid; a broken chest closes silently), Inventories
(armor put on by any action, a tool breaking), Entities (pickups, at the item; an item burning in
lava), Characters (health lost, at most every 0.5 s; death; a hurting landing's fall and the fall
sound of the block below the feet; a lava hurt that lands, water putting burning out; none for
spectators), Behaviours/Fluid (lava's fizz), Players/ItemUse (each fluid's bucket sounds, flint
and steel striking) and
World/Explosions (`entity.generic.explode`: appended after the lava's events, Minecraft's volume
4 as a 64 block reach, pitch 0.7 ± 0.1, the built-in boom whole at volume 1), Behaviours/Tnt
(`entity.tnt.primed` when TNT or a Nuke is lit, the wind pitched up into a fizz; a lit Nuke's
`entity.nuke.alarm` every second, the volume tick pitched up, heard 64 blocks away) and World/Nuke
(`entity.nuke.explode`, the boom pitched down to 0.35, heard 256 blocks away).

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
  - Volume: the event's (or the override's) x the cue's x `Sounds.Volume` x the source's, the last
    two each times the player's Music & Sounds volume (`setPlayerSettings`). The player's
    Footsteps, Interface Clicks and Cave Moods switches only turn off what `Config.Sounds` has on
    (`SoundPlayer.allows`). `sourceVolume(source)` gives that product for a source alone (the
    music's).
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
    for the landing; spectators (`state.noClip`) make no sound at all;
  - in water or fuel off the ground (a fluid one swims in, Fluids `swim`): swim sounds; entering
    it: a splash; both scaled by speed. Lava and oil are silent to move through, as Minecraft's
    lava;
  - a landing that hurts: `Sounds.fall` and the block's fall sound.
- Other players' characters within 24 blocks of the listener, followed per player (a new
  character starts over; spectators are not followed): the same rules every frame, from their
  feet (`SoundRules.observe` guesses the ground, edges included, and the water; lying down in
  water is swimming).
- Screens and JEI: clicks on buttons, tabs, page arrows, Back and "+" (not on slots or items).
- `Ambience`:
  - the open furnace window, while burning: crackles with Minecraft's odds for a furnace a block
    or two away (about every 4 s);
  - every Heat or Combustion Generator whose record says it burns, within 16 blocks of the
    listener (`SoundRules.crackles`, `TransmitterRenderer.activeMachines`): the same crackle, at
    the generator;
  - lava with air (or cave air) above it pops and bubbles (`SoundRules.lavaTick`, LavaFluid
    .animateTick): Minecraft's client picks 667 random blocks a tick within 16 blocks of the player
    and 667 within 32, and lava pops one time in 100 and bubbles one in 200; here LAVA_SAMPLES (24)
    of each a tick stand for those 667, with the odds scaled to match: the same sounds on average
    for 48 block reads a tick instead of 1,334 (volume x 0.2-0.4, pitch x 0.9-1.05);
  - Minecraft's cave mood (`Audio/CaveMood`, pure; `BiomeAmbientSoundsHandler` with the
    overworld's `AmbientMoodSettings.LEGACY_CAVE_SETTINGS`: ambient.cave, tick delay 6000, search
    extent 8, sound offset 2), every game tick:
    - one block is picked at `floor(eyes + nextInt(17) - 8)` on each axis;
    - its sky light s > 0: mood −= s / 15 × 0.001; else mood −= (block light − 1) / 6000, except
      a dark open block (not opaque, block light 0), which adds OPEN_WEIGHT (4) / 6000: this
      game's change, so a bigger cave brings the mood sooner (5 min / (1 + 3 × open share));
    - at mood ≥ 1: a random `Sounds.MOODS` event (`ambient.cave.mood<N>`, from MusicList.Moods;
      the stand-in `ambient.cave` while there are none) plays at the eyes + the direction to the
      block's centre × (its distance + 2), and the mood is 0 again; else it stays ≥ 0.
    - The light is estimated, as the engine keeps no light map. Sky light
      (`SkyExposure.skyLight`, through `LightingController.skyLight` with its cached natural
      ground): 0 in an opaque block, 15 where nothing opaque is above, else 15 less the steps
      (a block face each, a diagonal two) to the nearest cell open to the sky along the 16 rays,
      within a 512-cell budget. Block light (`CaveMood.blockLight`, Shared/World/LightEstimate's,
      which WAILA and the server's mob spawning share): breadth first through open
      cells from the block, a source's light less one a face, an opaque block its own light only,
      at most 256 open cells (a whole tunnel, a few blocks around in a big cavern), with no
      allocations (flat frontier lists and a stamped visit buffer). About 0.2 ms a tick
      interpreted on generated caves.
    - It counts whatever the switches say (F3's `mood N%`); Config.Sounds.Ambient and the Cave
      Moods setting only keep it quiet.

**Music** (`Audio/Music`, rules in `Audio/MusicRules`, tracks in `Sounds/MusicList`):
- Minecraft's MusicManager with the surface and caves as its situations. `MusicRules.step`
  (every frame) and `ended` (reported back) make a pure state machine:
  - **place**: "cave" once `LightingController.skyExposure()` has been under `CaveExposure` (0.2)
    for `SwitchSeconds` (5), "surface" once over `SurfaceExposure` (0.5) as long; between the two
    it stays.
  - **waits**: `FirstDelay` (5 s, Minecraft's 100 ticks) after joining, then `MinDelay` to
    `MaxDelay` (600 to 1200 s, music.game's 12000 to 24000 ticks) after a track finishes, and at
    most `SwitchDelay` (3 s) after one fades out or fails to load.
  - **a place change**: a track of the other kind gets a `fade` action (Minecraft's
    replaceCurrentMusic), and the wait drops to at most `SwitchDelay`.
  - **starts**: a track of the place's kind, at random, never the last one of that kind (unless
    it is the only one left) nor a failed one, and never while the exposure already says the
    other place.
- One Sound (SoundService.IceVoxelMusic), flat and not looped, plays it:
  - its file is preloaded first; one that fails, or hasn't loaded after `LoadTimeout` (20 s), is
    reported failed and skipped from then on;
  - a fade takes `FadeSeconds` (4);
  - its volume is `Music.Volume` (0.5) × `SoundPlayer.sourceVolume("music")` × the fade;
  - nothing new starts while that volume is 0, so nothing downloads.
- When a track starts, `Ui/MusicToast` shows its title: the MusicList `Title`, else the asset's
  name from `MarketplaceService:GetProductInfo` (asked once a track), else "Unknown Track". The
  toast is Minecraft's 160 × 32 panel (a music disc, "Now Playing" in yellow, the title cut with
  "..." to fit), tweened in from the right edge and back out after `ToastSeconds` (5). It sits
  under the minimap and its coordinates line while the minimap shows (`setMinimapShown`), and is
  scaled by `Style.guiScale`. A newer toast replaces it.
- Settings: Music (id 35, a source volume) and Music Toasts (id 36), both "audio" effects.

## Locating (`Generation/Locate`, `Poi`, server `World/PoiSearch`, `Players/LocateCommands`, `Players/TeleportCommands`)

Minecraft 1.20.1's `/locate structure | biome | poi` (LocateCommand,
ChunkGenerator.findNearestMapStructure, ServerLevel.findClosestBiome3d,
PoiManager.findClosestWithType) and a small `/tp`, for operators (Minecraft's permission level
2: `Operators.permitted`). Nothing keeps a list of what was generated, and a search must never
generate the chunks it looks through: everything a locate needs is decided per grid cell from the
seed and the full detail terrain, and the generators answer for one cell at a time.

- **Ids and tags** (`Generation/Locate`, pure). A `Registry` per kind of thing: structures (the
  built-in kinds `mineshaft`, `mineshaft_overgrown`, `mineshaft_entrance`, `oil_geyser`,
  `oil_deposit`, `lava_lake`, `lake`, `cave_entrance`, `ravine`, then the library's structures;
  a library name clashing with a built-in one is left out), biomes (BiomeList's 18) and points of
  interest (`Shared/Poi`). Ids show in snake case without a namespace ("birch_forest") and match
  loosely (`Locate.key`: any case, "minecraft:" or "icevoxel:" dropped, no `_`, spaces or dashes).
  Tags (`#mineshaft`, `#oil_well`, `#lake`, `#cave`, `#library`; `#is_forest`, `#is_taiga`,
  `#is_mountain`, `#is_hill`, `#is_savanna`, `#is_jungle`, `#is_snowy`, `#band_lowland` ..
  `#band_peaks`, also without "is_"; `#workstation`, `#machine`, `#generator`, `#container`,
  `#structure`, `#explosive`) search their members together and answer "#tag (member)". An id
  in the registry that this world can't have answers not found at once (no probe); an unknown one
  Minecraft's parse errors.
- **Kinds** (the generator's `locateKinds`, TerrainGenerator). One kind per locatable structure,
  on a cell grid (`grid`, `origin`): a `probe` that never touches a cache (a library structure's
  start check: the start piece alone, its centre column's biome and ground, 21 µs; a mineshaft's
  start: a hash and two columns, 10 µs; an oil well's or a lake's decision, read from the cache
  when there, else decided and not stored; a surface cave's hash) and an exact `verify` for the
  few candidates that might be nearest (`StructureGen.assembleAt`, `Mineshafts.planAt`,
  `SurfaceCaves.wormOf`: cached as the chunks cache them, 0.5-5 ms, yielding). `slack` bounds how
  far a verified position lies outside its cell, `spread` how far from its probe (an entrance from
  its room, a ravine's nearest step from its start). Left out when the world can't have them: no
  structures, a Single Biome outside a structure's biomes, too dry for moss (overgrown mineshafts
  and entrances), frozen, snowy or wet (lava lakes). Flat worlds have none; the debug structures
  world lists its laid out things instead (`locateList`).
- **Rings** (`Locate.nearest`). Square rings of cells around the player's (k = 0..rings): every
  cell probed, the candidates sorted by distance and verified in order while one could still be
  nearer than the best; a kind stops at the first ring whose cells all lie (k - 1) x grid - slack
  beyond the best. The answer is the true nearest (horizontal distance) at the probe's resolution,
  not Minecraft's first hit of the first ring. A tag's kinds share the best distance. Rings:
  `Config.Locate.StructureRings` (Minecraft's 100) for library structures, `Radius` per built-in
  kind.
- **Biomes** (`Locate.biome`). Samples `BiomeStep` (32) apart in square rings out to
  `BiomeRadius` (6400), both times the generator's `climateScale` clamped to 0.25..2 (Large
  Biomes: 12800 in steps of 64; Debug: All Biomes' 16 block strips: steps of 8); the nearest
  sample of the set wins and the search stops at the first ring farther than it (at most about
  sqrt(2) times the first hit's ring). A set the generator's `biomes` can't produce fails with no
  sample. The answer's y is the column's surface, the distance horizontal (biomes are 2D here).
- **Points of interest** (`World/PoiSearch`, `Poi`). The wanted blocks within `PoiRadius` (256,
  3D) of the player: the world's edits in the 33 x 33 chunks around (what is there now), and what
  the plans put there (`generator.poiBlocks`: library templates' cells, worked out once per
  template and rotation, mineshafts' chests, laid out blocks) where no edit changed it; nearest
  first, a generated one checked against the block really there (the world's loaded chunk, else
  the chunk generated by the search's own generator a slice at a time). `PoiGeneratedNear` keeps
  only those in loaded chunks (Minecraft's generated-only rule).
- **Answers** (`Players/LocateCommand`, pure). Minecraft's texts exactly; the coordinates are
  "[x, y, z]" with y "~" for surface structures, the y for underground ones, the surface for
  biomes, the block's for points of interest; distances floored. The coordinates are a link
  (`Protocol.NoticeLink` after the Notice's text: its bytes and "/tp @s x y z"), green in the
  chat, which puts the command in the box when clicked (see Chat). Coordinates are true world
  coordinates (F3's), with or without the floating origin: positions come from
  `PlayerPositions.feet`.
- **Scheduling** (`LocateCommand.Queue`, glue `Players/LocateCommands`). One search at a time,
  resumed each Heartbeat for at most `BudgetMs` (3); the searches call the queue's yield after
  every probe and verify, which suspends them once the slice is spent, so no frame takes more than
  the budget plus one probe or verify (tested with a fake clock). At most `Queue` (8) waiting, one
  per player (a new /locate replaces theirs; leaving cancels), `TimeoutSeconds` (20) of running
  answers not found. Searches run on a generator of their own (`WorldTypes.create` with the
  world's type and seed, made at the first search): they stop in the middle of plans and chunks,
  which the world's generator, generating the chunks around players in the same frames, must
  never do, and their caches never evict what the chunks need. A full miss costs about 0.9 s of
  work (40,000 outpost probes, or 160,801 biome samples): some 300 frames; a typical answer 1-20.
- **/tp** (`Players/TeleportCommand`, pure; glue `TeleportCommands`). `/tp x y z`,
  `/tp targets x y z`, `/tp player`, `/tp targets player`; "~" and "~n" relative to whoever typed
  it, whole x and z the block's centre (Vec3Argument), limits `Protocol.MAX_COORDINATE` and
  PlayerSync's y range, Minecraft's answers (its "%f" numbers). Moves go through
  `PlayerPositions.teleport` (characters today; the private Teleport message and a new epoch
  with server positions). Survival and adventure players who would land unsafe
  (`SafeSpot.isSafe`) stand on the block asked for, else on the column's safe top (a /locate
  link's "~"); creative and spectator players land exactly.

## Title screen, operators and creating the world (`WorldSettings`, server `Players/Operators`, `Players/WorldMenu`, `World/WorldInfo`, client `Ui/MainMenu`)

Minecraft's title screen and Create World screen, and its server operators.

**Boot.** The server starts what doesn't need a world first, on `Network/LobbyNet`:
Players/Operators, Players/SettingsStore (so the title screen's Options menu saves) and, with
`Config.MainMenu.Enabled`, Players/WorldMenu (the boot script turns `Players.CharacterAutoLoads`
off first of all). Everything else is the boot script's `startWorld(settings)`, which
`World/WorldInfo.create` runs exactly once: from WorldMenu when the operator creates the world, or
at once with the menu off (`WorldSettings.fromConfig`: `Config.World` and `Config.Seed`). Before it
runs, `WorldInfo.apply` puts the settings into the server's Config (new players' game mode
`Gameplay.DefaultGameMode`, the difficulty `Server.Fire.Difficulty`, and Peaceful's
`Mobs.HostileCap` / `MaxHostile` 0: no monsters spawn; /summon still makes them; a world type with
`mobs = false`: `Mobs.Spawning` off), and `startWorld` hands Allow Commands to Operators and builds
the block ticker without behaviours for a type with `ticks = false` (the debug worlds). `startWorld` publishes last (`WorldSettings.publish`:
"WorldName", "Difficulty", "AllowCommands", then WorldTypes' "WorldType", "WorldOptions" and
"Seed"), so every part is up before a client starts loading. A `startWorld` that throws leaves the
state "failed" for good (half the parts may have started: the server needs a restart).

**Operators** (`Players/OperatorList`, pure and tested; the glue `Players/Operators`). Players are
known by user id. Automatic operators (`autoOperator`) only with the menu and
`Config.MainMenu.AutoOperator`, and only until the world exists (`WorldInfo.onReady` turns them
off for good): meanwhile the first player to join while no operator is here becomes one, and
everyone is told ("Steve is the server operator"), and while players are here one of them always
is an operator: the last one leaving makes the player here longest one ("Alex is now the server
operator"), and `/deop` refuses to take the last one away, so the world can be created. After that
(and with the menu off) nobody becomes an operator by being here: the permanent ones, and whoever
they `/op`; the first operator stays one. The op list lasts the server's lifetime (rejoining keeps
it, as Minecraft's ops.json). Permanent operators: `Gameplay.Admins` and everyone in Studio from
the join, the game's owner once `GameModes.isOwner` says so (a group game's: retried, 5 s doubling
to 300 s, while `GameModes.ownerKnown()` is false). `/op <player>` and `/deop <player>` (operators
only; names as `/gamemode` finds them) answer as Minecraft ("Made Steve a server operator",
"Nothing changed. The player already is an operator", ...), tell the player, and show the other
operators Minecraft's admin line ("[Alex: Made Steve a server operator]"). `Operators.permitted
(player)` is the check every operators' command asks (`/time`, `/gamerule`, `/gamemode` for others
and the switcher's permission, `/effect`, `/summon`, `/kill`, `/knowledge`, `/age`, structure
blocks): an operator, or anyone once the world allows commands. `isOperator` is the real thing
(`/op`, `/deop`, Create World); `isPermanent` the game's own (changing progress that is saved for
every server). Each command's `TextChatCommand` carries who may use it
(`WorldSettings.COMMAND_ATTRIBUTE`), so the chat offers a player only theirs (see Chat). The Player attribute `IceVoxelOperator`
(`WorldSettings.OPERATOR_ATTRIBUTE`) tells clients; `Operators.changed` fires for each player whose
status or permission changed.

**The title screen** (client `Ui/MainMenu`; its rules in `Ui/TitleRules` and `Ui/CreateWorldForm`,
pure and tested). The client boot calls `MainMenu.run()` right after `SoundPlayer.start` and
`Settings.start`, and nothing else starts until it returns: no streaming, no HUD, no input
handlers, so the menu needs no input blocking and the world costs nothing while it shows. (Loading
the world behind the menu would make Join instant, but every module's keys would then need a
guard, and a player waiting for the operator has no world to load anyway; entering is a normal
join, the movement waiting for the ground.) The Options menu is `SettingsScreen.showIn(host,
onDone)`: the same panel, hosted by the title screen before Ui/Screens exists, every page with it
(Controls with Mouse Settings and Key Binds, Chat Settings, Video's Caves, Accessibility). Hosted
there it takes the mouse wheel itself (the Key Binds list), and Escape / B go back a page
(`SettingsScreen.back`; Escape makes a key Key Binds waits for "Not Bound", B leaves it) before
leaving to the title; the title screen takes Escape as Ui/Screens does (InputBegan or Roblox's
`MenuOpened`, whichever comes first, the other ignored), and a gamepad's selection moves to each
page's first widget (`showIn` too). Before the menu the boot turns Roblox's chat window and input
bar off (`Chat.hideRoblox`: nothing typed on the title screen goes out as chat) and applies the
GUI Scale setting (`Style.setScaleOverride`, again on every settings change until the world's
"hud" effect takes over). The server's
`MenuState` (waiting, creating, ready, failed; the operator's and the world's names) and the
operator attribute decide what is enabled: Join World once ready, Create World for an operator
while waiting, Load World for an operator while waiting where saving works (its Select World
page: "Saving worlds" below), Options always. The background is a
moving sky (a gradient, a square sun, clouds and two hill layers, each two screens wide holding
its pattern twice and slid by a scale offset: three property writes a frame); the other screens
use Minecraft's options background (the texture pack's dirt, 32 GUI pixels a tile, at 64 / 255).
Messages the server sends meanwhile wait in Net/ClientNet's backlog (edits for chunks the client
has no edit list for are ignored anyway: it asks for the lists once it streams).

**Creating** (`WorldSettings`, shared and tested). The screen sends `CreateWorld` (its options
encoded by `WorldTypes.encodeOptions`); WorldMenu answers malformed ones, non-operators and
anything after the first (`WorldInfo.refusal`) with `CreateWorldResult` false and a reason, else
checks the request (`WorldSettings.validate`: a type the menu offers, one of the screen's three
game modes, difficulty 0..3, a seed of at most 32 characters, the name cleaned: control characters
out, trimmed, 32 characters, blank "New World"), puts the name through TextService's broadcast
filter (everyone reads it; an unreachable filter gives "New World"), and calls
`WorldInfo.create`. The seed: blank is random (1..2^31 - 2), a whole number (an optional sign and
digits) is itself while |n| < 2^53, any other text is Java's `String.hashCode` over UTF-16 units
(Minecraft's `WorldOptions.parseSeed`). A world type's options are only those it declares in its
optional `settings` (WorldTypes.Setting: toggle, choice or text; text is a code alphabet, never
free text, so it needs no filter), each of its kind or its default, plus `structures` (Generate
Structures). The form (`Ui/CreateWorldForm`) offers every registered type the menu may show (the
debug worlds last, in the registry's order); Customize draws the type's settings but
`structures`, which is the World tab's toggle (greyed for a type that doesn't declare it), a
text setting with its `presets` on a button and its `check` (superflat: `Superflat.parse`) in red
under the box, and Create New World refuses a text that fails it. A type's `gameMode` hint is
preselected when the type is picked (and is a mode the screen and `validate` accept for it:
Spectator for All Blocks), and the mode before the hint comes back on a type without one unless
the player chose a mode meanwhile. With the menu off, `fromConfig` takes `Config.World.Options`
(kept as a request's) and the type's game mode hint over `Gameplay.DefaultGameMode`.

**Characters.** With the menu nobody has a character before entering the world (Roblox's
auto-loading is off; one that slipped in before the boot turned it off is removed). `EnterWorld`
(Join World, or the creator's client after a success) loads it with `Player:LoadCharacterAsync`
(LoadCharacter on an engine without it), and the server respawns the dead itself after
`Players.RespawnTime`, as Roblox would. Players who join later see the title screen and Join
World.

## Saving worlds (server `Save/`, `World/WorldSave`, client `Ui/SaveIndicator`, `Ui/MainMenu`)

Minecraft's level saving, its autosave, `/save-all`, `/save-off`, `/save-on` and its world list,
on Roblox's DataStores. The rules are pure and tested (tests/spec/WorldSave: a fake DataStore with
budgets, the 6 s a key, latency and failures); `World/WorldSave` is the Roblox side.

**What a saved world holds.** The only terrain state is the edit lists (WorldServer `edits`: what
differs from what the seed generates; player-placed leaves are leaves in them and never decay),
so a world is: its record (settings, the clock, its operators, the sections other parts register),
its regions and its players.
- Regions (`Save/RegionCodec`), 32 × 32 chunks each (`Config.Save.RegionChunks`, Minecraft's region
  files): every chunk's edits as runs (gap, length, block; a dug tunnel row or a 16 × 16 layer of
  one block is one run), containers (chests; furnaces with their fuel and cook progress; machines,
  whose energy, gauges and tanks are their container's data, Shared/Machines), generated chests
  already asked about (Containers `sourced`: looted ones never fill again), structure blocks' and
  jigsaws' settings, transmitters (side modes, colour, a pipe's share of its network's fluid by
  capacity, `TransmitterWorld.saveState`), Fluid Tanks, stacks in transporters, dropped items
  (with their age), farm animals (`Config.Save.Mobs`; monsters despawn anyway) and block updates
  still due (`BlockTicker.scheduled`, in ticks from the save). Records are tagged and
  length-prefixed and read back exactly to their length; ids this version doesn't know (a newer
  version's blocks, items, mobs, items in a chest) are dropped one by one and counted (`dropped`),
  anything else damaged refuses the region. A world with any dropped is played but never saved
  (`canSave` false, "saved by a newer version" on the title screens): writing it back would lose
  them for good. Block updates still waiting for their chunk to generate are saved again as they
  were (`WorldSnapshot.collect`'s `pending`), not lost at the next save.
- Players (`Save/PlayerCodec`, Minecraft's playerdata): feet and facing (or none: back at the
  spawn), health in half hearts, game mode and the previous one, the selected slot, inventory,
  armor and cursor, Tough As Nails' thirst and temperature (Climate Clemency left included) and
  the running status effects. Knowledge, Ages and skills stay in Players/ProgressStore, for every
  world. 60-400 bytes. A record holding items this version doesn't know is applied (what it can
  read) but never written that session.
- Not saved: fire's ages (fire comes back at age 0), a lit TNT's or Nuke's fuse (a lit block
  with no record starts its full fuse, Behaviours/Tnt), explosions under way, items' and mobs'
  velocities, monsters, the session's SAVE texts of structure blocks (copy the IVS1 text) and
  open windows (a window's cursor goes back into the inventory).

**Format and keys** (`Save/SaveCodec`, `Save/WorldMeta`). DataStore "IceVoxelWorlds_v1"
(`Config.Save.StoreName`): "index" (the game's world list, the worlds made with the title screen
off: id, name, type, seed, game mode, owner, created, last played, bytes), "index/<userId>" (a
player's: the worlds they created on the title screen), "<id>/meta" (the world's record: version,
settings, the seed as its digits, its owner, `gen` the saves made, every region and player with
its bytes, the op list, the sections),
"<id>/lock", "<id>/r/<rx>_<rz>" (a region's head), "<id>/r/<rx>_<rz>/<slot>_<i>" (its further parts)
and "<id>/p/<userId>" (written with the player's user id, as Roblox asks). Binary is kept as base85
text (4 bytes in 5 characters over 85 printable characters JSON never escapes: 1.25 per byte, and
exactly what Roblox counts against a key's 4,194,304 characters; text rather than buffers, whose
stored size the code could not measure). A region longer than `Config.Save.MaxKeyBytes` (4,000,000) goes in
parts: parts 2.. are written first, into the slot the committed head does not name, then the head
(part 1, the part count, the slot, `gen`, the writing server's tag `w`: an FNV hash of its JobId),
so the head is the region's commit: a save cut short leaves the old head naming the old slot's
intact parts, and parts whose `gen` or `w` differ from their head's (two servers that both
believed they held the world, numbering their saves alike) refuse the load instead of joining
into a region neither wrote. Every record carries a version; a newer
one is refused, never half read or overwritten. A world's bytes are its record, regions and
players (each value's text plus 96 for the JSON around it); a save that would take a world past
`Config.Save.MaxWorldBytes` (64 MB) is refused as a whole, and operators are warned past
`WarnShare` (80%) and every 5% more. Measured (tests/spec/WorldSave): a 9 × 9 × 5 house, a 3 × 3 ×
64 tunnel, a chest, a furnace, a battery, pipes, an item and a cow are 797 edits, 881 bytes, 1,102
characters; 6 fully edited chunks with no two neighbouring cells alike (no run compresses: the
worst case) are 3.66 MB and two parts; a typical player record is 192 characters.

**Owners.** A world is its creator's (`WorldMeta` `owner`: the operator who pressed Create New
World, `WorldSave.claim`; 0, the game's, with the title screen off). Load World lists a player's
own list, and for the game's own people (`Operators.isPermanent`: `Gameplay.Admins`, the game's
owner, Studio) the game's too; loading, renaming and deleting check the record's owner on the
server (`WorldMeta.mayManage`: "it is not yours"), whatever id a client sends. So the first
stranger into an empty public server, its operator until a world exists, sees and touches only
the worlds they made. A world whose record is gone is deleted only from a list of one's own. A
list holds `WorldMeta.MAX_WORLDS` (200): Create World is refused past it ("delete one to save
another"), and a world that would be the 201st (another server filled the list meanwhile) is
refused whole at its first save, never written unlisted; no world is ever dropped from a list.

**Safety.** A session lock per world (`Save/SaveLock`, inside UpdateAsync transforms: one atomic
step): `{ job, at }`, renewed every third of `Config.Save.LockTimeout` (180 s) while the world is
open, while it loads (a load of 250 regions at an empty server's 60 reads a minute takes about
190 s: the lock is never more than 60 s old meanwhile), once more as it starts, and before every
save writes (`ensureLock`: renewed when its last renewal is 30 s old, before the writes and again
before the commit and the record); a live lock of another server refuses loading and deleting
("it is open on another server"); a stale one (a crashed or stalled server) is taken over, and
the old server's next heartbeat or save finds it lost and stops saving. A world is loaded whole
or not at all: any key that can't be read (after the scheduler's retries) or decoded gives the
lock back and the world is never started, so nothing is ever written over it; a world whose start
failed half way (`WorldSave.abandon`) is never saved either. A player whose record can't be read
starts afresh and is never written that session (and is told), so an outage never replaces a
saved inventory with an empty one; one who leaves before their first character (still on the
title screen) is written with their saved place, health, Tough As Nails and effects
(`PlayerCodec.withWaiting`), not as a fresh player. Each player record a save or a leaving player
writes carries its capture's order: a record older than one already written (or being written)
for that player is skipped (an autosave's retry can't put back what a leaving player had
before), and a player back before their leaving record went out takes it over. Studio without
API access (or `Save.Enabled` off): one read of the index at boot fails, every title screen says
why in red and Load World stays greyed; the world plays session-only and operators are told in
the chat (`/save-off` and `/save-on` say why and change nothing).

**Writing** (`Save/SaveScheduler`, `Save/WorldStore`). Requests go in order (players and further
parts, then heads, then the record, then the index: an UpdateAsync that merges the world's line),
at most 8 in flight, each waiting for its kind's budget (DataStoreService
:GetRequestBudgetForRequestType; SetAsync and RemoveAsync share one) and for the key's 6 s since
its last write (kept across saves), failures tried again after 1, 2, 4, 8 s (5 tries), and a
deadline at shutdown. What failed is reported and kept for the next save; a region whose parts
failed is not committed (its head stays as it was). Saves write only what changed: every block
change marks its region dirty (`WorldSave.blockChanged`), and `WorldSnapshot.collect` builds the
dirty regions, the regions holding state now and those that held some at the last save (what
moved or went away is written out of them, even when they are empty now), all in one frame (a
chest broken mid-save can't be saved both as a chest and as its items; 0.2 ms for the area
above in Lune); WorldStore then compares each region's text with what the store holds and writes
only those that differ (the meta and index are written every save: 2 writes when nothing else
changed). Autosave every `Config.Save.Interval` (300 s) while saving is on; `/save-all` waits
for a save in flight and saves; `/save-off` stops autosaves; shutdown (BindToClose) saves within
25 of its 30 s even after `/save-off` (as Minecraft's stop), then gives the lock back. A new world
is saved at once (so the list has it). A leaving player's record is written at once
(`WorldStore.savePlayers`, their key alone), and a player who comes back before it was written
gets that record.

**Loading.** The title screen's Load World (operators, while no world exists; Players/WorldMenu's
WorldAction) or, with the menu off and `Config.Save.LoadLatest`, the world played last that no
other server has open: `WorldSave.prepare` takes the lock, reads the record and every region the
record lists (heads, then the parts of long ones, as many at once as the budget allows; each key
read is a "Loading world: 12 / 40" on every title screen), joins and decodes them; then
`WorldInfo.create` runs startWorld with the world's settings: `attach` makes the loaded edits the
world's (before any chunk is generated: WorldServer overlays them on every chunk it makes, which
is all terrain needs), `restore` (after every part started, before the world is published) puts
back the containers (each block's fresh container with the saved slots and data copied in;
furnaces cook on), runs the edits' transmitters, tanks, chests, machines and structure blocks
through their parts' `blockChanged` from air (machines find their restored containers, pipes
relink, networks join again over the next ticks adding the pipes' shares up), then the pipes' saved
modes, colours and fluids, the structure settings, items, animals, the operators (`Operators.grant`)
and the sections; block updates due are scheduled when their chunk generates (WorldServer
`onGenerated`). Players: each one's record is read as they join; WorldMenu's `beforeEnter`
holds their character until it is (at most 10 s); their inventory (`Inventories.restore`) and game
mode come back at once, their place and facing with their first character (Players/Spawning's
placement), health (`Characters.restoreHealth`, no hurt sound), Tough As Nails
(`ToughAsNails.restore`) and effects (`Effects.restore`) with it too. With the menu off (characters
load before the record arrives) the standing character is moved and set.

**Sections** (`WorldSave.registerSection(name, encode, decode)`): state other parts keep with the
world, in its record: `encode()` returns a small JSON-able value at every save (in the save's
frame), `decode(value)` runs once when a saved world starts (after every part started, before
the world is published), or at once when registered later. "time" is the day clock's (day time
and doDaylightCycle); "weather" the weather's (`WeatherServer.encode`'s text: its clock,
doWeatherCycle and a `/weather` override with its time left; see Weather).

**Feedback.** WorldSave messages (Protocol): "saving" and "saved" to everyone (Ui/SaveIndicator:
Bedrock's saving icon, a grass block bobbing in the bottom right corner with "Saving...", while a
save is in flight and at least 1.2 s; higher up on touch screens, clear of the buttons), the sizes
to operators only (the toast, as Ui/MusicToast's and under it while that one shows, or dropping
under one that comes in over it: "World saved" over "1.4 MB of 64 MB (largest region 0.3 / 4 MB)",
red when it failed or nears the most; while it sits under Now Playing, `MusicToast.setBelow`
moves the status effect icons down under it too), the
state (on, off, unavailable and why, session only) to every title screen and the loading progress.
Operators read failures, refusals and the size warnings in the chat. The icon and the toast hide
with the HUD (the world map hides it: on 4:3 and squarer screens the icon would sit on the map's
weather bar and legend, and without the minimap the toast on its buttons).

**Title screen** (client `Ui/MainMenu`, rules in `Ui/WorldListRules`, `Ui/TitleRules`). Load World
is enabled for an operator while no world exists where saving works (`TitleRules.buttons`'
`saves`); its page is Minecraft's Select World: the list (WorldList, last played first; rows of
name, "Type, last played 2026-10-07 14:03", "Survival Mode, 1.4 MB"; click selects, double click
plays), Play Selected World ("Loading the world..." with the count; a failure comes back in red),
Rename (an edit box; the server filters the name), Delete (Minecraft's confirmation) and Cancel.
Every answer is the list again with how it went. One list and one change a second per player (a
list asked faster gets the last one again: the screen waits for an answer).

## Floating origin and player sync (`World/Origin`, `Net/PlayerSync`, server `Players/PlayerPositions`, client `Player/RemotePlayers`, `Rendering/Rebase`)

Two switches, both **off** for now (the foundation is in; the server, world and player sides land
on it): `Config.Origin.Enabled` (the client's floating origin) and `Config.Players.ServerPositions`
(positions from checked client moves, characters parked on the server, poses relayed by interest:
"fake coords"). Off, everything behaves as before: the origin stays at 0, every conversion is the
identity, and both position APIs read the characters.

**Frames.** All logic stays in world coordinates: blocks as Luau doubles (the hull, the streamer,
raycasts, entities, mobs, weather, sounds, the protocol, the server). Each client has a render
origin O = (Ox, 0, Oz) studs, a multiple of `Origin.Snap` (768 = 2^8 × 3: blocks, chunks, the
4-stud lighting grid and texture tiles up to 256 studs line up the same after a move); every
client-made instance is written at world studs − O and read back with + O. Y is never shifted.
`Shared/World/Origin` (pure: specs and the streamer's fake `game` load it) does every conversion
from doubles: `blocksToRender`, `blockCentreToRender`, `studsToRender`, `renderX`/`renderZ` (hot
paths), `toRender`/`cframeToRender` (near values only), `renderToBlocks`/`renderToStuds` (doubles
back), `toWorld`, `offset`, `snap`, `plan`, `planTo`, `set` (returns (dx, dz), epoch + 1, listeners
in order), `onRebase`, `reset`. Its Vector3 / CFrame functions read Roblox's globals when called
(under Lune a spec lends them: tests/spec/Origin). The server has no origin.

Rules for code that places or reads instances:
- R1: never write a world Vector3 into an instance; convert from doubles (a float32 world value
  at 1e6 blocks is 1/16 block off).
- R2: never compare a render position with a world one; convert one side. Differences of two render
  positions need nothing.
- R3: Y is never shifted. R4: directions are frame-free.
- R5: a module that caches render studs subscribes to `Origin.onRebase`; one that places instances
  once registers a `Rebase` mover; per-frame writers only convert.

**Re-basing** (client `Rendering/Rebase`, the render step `IceVoxelOrigin` at Camera − 3, before
remote players (198), the local character (199) and the camera). The origin moves under the camera
when it is farther than `Origin.RebaseDistance` (8192 studs: 1/1024 stud there) along X or Z, at
`SoftDistance` (3072) while `Rebase.setHidden(reason, true)` holds (the map, screens, menus, the
death screen, the streamer's teleport mode), and to a teleport's destination after
`Rebase.request(x, z)` (world studs). A move: `Origin.set` (listeners shift caches), every mover
(`Rebase.register(name, fn(dx, dz, parts, cframes))`) appends its parented parts with their new
CFrames to two reused arrays, one `workspace:BulkMoveTo(..., FireCFrameChanged)`, the camera's
CFrame and Focus − d, stats (`Rebase.stats()`: epoch, x, z, count, lastMs, lastParts) and one
line. A failing mover is warned about and left out. `Rebase.now()` forces a move (debug). The boot
puts the origin over `SpawnPosition` before the streamer builds (`Origin.planTo`). Unparented
containers are fixed when they are shown (their owners record the origin they were placed for).

**The world in the render frame** (client rendering, audio, weather, entities). Everything the
client simulates stays in world blocks; only the writes into instances subtract the origin (from
doubles: `x * BlockSize - Origin.x`) and only camera reads add it back (`Origin.renderToBlocks`:
FireRenderer, FuseView, TransmitterRenderer, StructureBoxes, LightingController, FluidFog,
WeatherState, CloudView, the streamer's eye, SoundPlayer's listener). What is placed once moves
with the origin; what is placed every frame (after the origin's render step) only converts:

| Owner | At a move | Placed every frame |
| --- | --- | --- |
| `ChunkRenderer` ("terrain" mover) | parts of nodes whose model is in the workspace; retiring models, folders and removed parts still there; trashed models still there; the far meshes in the workspace (`MeshOverlay.gather`); the sparse lights' cached positions | |
| `TransmitterRenderer`, `FireRenderer`, `FuseView`, `StructureBoxes` | their parts in the workspace (pipes, flames, flashing boxes, outlines, labels, air markers) | items in transporters |
| `PrecipitationView` | the one anchor part (every strip's attachments are on it) | |
| `LightningView` | near bolts and strike anchors; the far bolts' Attachments (their anchor stays at the identity) − d | |
| `CloudView` | each ring's Model `PivotTo(GetPivot() − d)` (never its parts one by one: its WorldPivot stays right) | |
| `SoundPlayer` (`Origin.onRebase`) | the emitter's Attachments, the distant voices' sources and the listener − d (the emitter stays at the identity) | the listener |
| `EntityRenderer`, `MobRenderer`, `ExplosionView` | | items and pickup flights, mobs and arrows, the Nuke's six parts (a per-frame updater replaced its CFrame tweens) |

Containers out of the workspace are never moved at a move (the lazy rule: a part goes into the
workspace only placed for the current origin):
- every ChunkRenderer node records the origin its parts are placed for (`NodeState.ox/oz`); the
  mover moves the parented ones and sets theirs to the new origin. A node shown again (`show`, or
  the far meshes putting a member back: `overlay.settle`) whose origin differs is moved by
  (its origin − the current one) in one BulkMoveTo right after it is parented, everything in its
  model (`GetChildren` of its section folders: retiring folders and removed parts too);
  `Rebase.settled(n)` counts them (`stats().lazyParts`);
- a build takes the origin when it starts (`Build.ox/oz`; `originX/originZ` are the node's corner
  in that frame) and its new parts, out of the workspace until the commit, are moved to their
  node's origin by plain CFrame writes just before the commit parents them; a sparse light built
  across a move caches where it will show (its position + (build origin − origin));
- a far mesh keeps its centre in world studs and is placed for the origin of the moment `apply`
  parents it; the camera's speed (the far meshes' motion gate) is measured in world studs.

The streamer selects around `streamer.viewerFeet()` (the boot: the local hull's world blocks; the
streamer may not require MovementController), else `SpawnPosition` (world studs), else the camera
read back; its eye is the camera read back. Pickup flights go to `RemotePlayers.feet(collector)` or
the local hull; StormView's lightning guards and MovementSounds' other players' footsteps come
from `RemotePlayers.each()` (world blocks, so a move is no jump and no teleport). The streamer's
teleport mode is a hidden moment (`Rebase.setHidden("teleport", active)` in the boot). Stats:
`stats()` also gives the last move's Luau side (Origin's listeners and the movers gathering:
`lastGatherMs`) and its BulkMoveTo (`lastMoveMs`), and the log line both.

Measured (Lune, interpreted as Roblox clients run it; ChunkRenderer's real mover through
`Rebase.perform`, 200 parts a node, no BulkMoveTo): the walk costs 1.8 ms for 17k parts on screen,
2.8 for 35k, 6.5 for 80k and 11.5 for 140k (0.08 µs a part). The `part.CFrame` read and the
`CFrame − Vector3` per part are engine calls in Roblox and come on top (Lune's userdata versions
take about 0.75 µs a part, which says nothing of Roblox's); BulkMoveTo's own cost and the next
frame's broadphase and lighting work are only measurable in Studio (scratchpad
`origin-design/RebaseProbe.client.luau`, the design's §2.4 decision rule).

**Players' positions.** One API on each side, world blocks as doubles, each with a compat backend
that reads the characters exactly as before:
- server `Players/PlayerPositions`: `feet(player) -> (x?, y, z)` (nil: not standing in the world;
  also for a position that is not finite or beyond `MAX_COORDINATE` + 64), `feetVector` (Rig.feet's
  drop-in), `center` (the body's middle: today the root), `eye`, `hull` (standing, Rig.hull's
  drop-in), `yaw`, `look`, `alive`, `inReach(player, x, y, z, reach?)` (block centre within
  `Interaction.Reach` + 2 of the centre, every reach check's rule), `each()` (`for player, x, y, z
  in ...`), `chunkOf`, `teleport(player, x, y, z, yaw?)` (feet; compat: PivotTo plus the
  IceVoxelFeet / IceVoxelTeleports attributes, as `Characters.teleportFeet`), `teleported` (a
  signal: player, x, y, z), `grant(player, blocks)` (knockback allowance), `spectating(player)`,
  `start(net)` (before `Characters.start`). The getters work before `start`.
- client `Player/RemotePlayers`: `get(player) -> Remote?` (one table per player refreshed in
  place: feet, yaw, pitch, tilt, PlayerSync flags, speed, climb, alive, character), `feet`, `hull`,
  `each()` (`for player, remote in ...`), `isTracked`, `onTracked(fn(player, tracked))`, `start()`
  (before MovementController). Compat: every other player with a character is tracked.
- `Movement/Rig`: `rootCFrame(character, renderFeet, yaw, tilt, bodyPitch)` (MovementController's
  placement), `yaw(rootCFrame)` (at any body pitch), `deathCFrame(base, progress, height?)`
  (Minecraft's death roll about the feet).

**Wire** (`Net/PlayerSync`, ids in Protocol: `ClientMessage.Spectate` 24, `ServerMessage.Teleport`
26, `ServerMessage.Players` 27; the unreliable remote `Net/Remotes.moves()`, "Moves"). Every
position is world blocks; the receiver converts with its own O.

| Message | Channel | Layout |
| --- | --- | --- |
| Move (client → server, 20 Hz) | unreliable Moves | u16 seq, u16 epoch, f64 x, y, z, tail: 36 bytes |
| Poses (server → client, 20 Hz) | unreliable Moves | u16 tick, u8 n (≤ 40), n × (u16 slot, i32 x, y, z in 1/256 block, tail): 3 + 22 n ≤ 883 bytes (Roblox drops unreliable messages over 1000) |
| Players (server → client) | Net, `Players` | u8 n, n × (u8 op: 2 untrack u16 slot; 1 track u16 slot, f64 user id, u8 game mode, i32 x, y, z, tail) |
| Teleport (server → its player) | Net, `Teleport` | u16 epoch, u16 life, f64 x, y, z, f32 yaw (NaN: keep), u8 reason (spawn, teleport, correction): 33 bytes |
| Spectate (client → server) | Net, `Spectate` | f64 user id (0: stopped) |

The pose tail (8 bytes): u16 yaw, i16 pitch (× 20860), u8 tilt, u8 flags (sneaking, sprinting,
flying, on ground, in water, climbing, jumped, dead), u8 speed (× 8), i8 climb (× 8). Decoders
refuse wrong lengths, non-finite numbers, positions beyond `MAX_COORDINATE` or heights outside
−256..4096, unknown ops, modes and reasons, too many records and user ids that aren't whole;
`decodePoses` fills a reused list.

**The server's own positions** (`Config.Players.ServerPositions`; server `Players/PositionStore`,
`MoveCheck`, `Interest` (pure, specs of the same names), `PlayerPositions`' networked backend,
`PlayerRelay`). With the switch off every part below is as before; on:
- *Characters.* `Players/Spawning` parks every new character first (`Characters.park`: its life +1
  in the `IceVoxelLife` attribute, `Rig.LIFE`; the root anchored, so server-owned; no joints broken
  at death; `PivotTo(Players.ParkPosition)` once and for good), then places the player through
  `PlayerPositions.teleport` like any teleport. What replicates of any character is the park: the
  fake coordinates. Each client places every character locally (its own from the hull, others from
  relayed poses); those writes never replicate. A dead body stays where it is (the clients play the
  death tilt); `Died` is made sure of on the server (`ChangeState(Dead)` if health reached 0 without
  it). `Characters.teleport` / `teleportFeet` (signatures kept) and `teleportTo(player, x, y, z,
  yaw?)` (doubles) all go through `PlayerPositions.teleport`.
- *Records* (PositionStore, keyed by Player): feet doubles and whether there is a position at all
  (none before a character's first teleport nor after it is removed: only the parked character's
  removal counts), the last move's pose (the Dead flag is the server's, from the Humanoid), a slot
  (u16, increasing, never one in use), life and teleport epoch (u16), the last move's seq,
  whom the player spectates, MoveCheck's buckets, a version bumped by every change, `gone` while
  leaving (unseen at once; the record stays 5 s so the save still reads it).
- *Moves* (Moves remote, about 20 a second): taken when they decode, the player has a position, the
  epoch is the record's (a teleport's new epoch drops what is on its way until the client snapped
  and confirms), the seq is newer (wrap-aware), the player spectates nobody and MoveCheck allows
  them. MoveCheck: horizontal, up and down buckets refilled in server time at the game mode's
  `Players.MoveLimits` up to `MoveSlack` seconds of it; a move costs its displacement, one that
  would overdraw any is refused; the larger of the old and new limits for 2 s after a mode change;
  `grant` (12 × an explosion's or a mob hit's knockback) over the cap for 2 s; a teleport fills
  them. Refused under `MoveCheck = "correct"`: a Teleport (reason correction, a new epoch) back to
  the last accepted place, at most every 0.5 s; `"log"` takes it and warns (every 10 s at most);
  `"off"` takes anything in bounds. The spec replays 30 s of real PlayerPhysics in every mode
  (sprint-jumping on ice with Speed II, sprint-flying, the fastest spectator flight, a 2000-block
  fall) with jittery latency and no refusal.
- *Teleports* (`PlayerPositions.teleport`): position and yaw set, epoch + 1, buckets full,
  spectating ended, the Teleport message to that player alone (reason spawn for a new character's
  first, carrying its life), `teleported` fired (not for corrections).
- *Spectating*: `Spectate(userId)` from a spectator (0 stops; leaving spectator mode, a teleport or
  the target leaving end it too); their place follows the target's every relay tick, through
  chains, never in a loop, so their chunk lists, edits and streaming follow the target.
- *Who sees whom* (`Interest.sees`, Minecraft's tracked-entity rule): never oneself, both with a
  position, a spectator only by spectators (SpectatorRules.sees, copied), always the spectated
  player, else within `Interest.PlayerDistance` (256) blocks horizontally to start and 272 to stay;
  the dead stay seen. `PlayerRelay`, 20 times a second: alive flags, spectators follow, then per
  player `Interest.update` (changes as one reliable Players message: untracks by slot, tracks with
  the whole pose and game mode) and `Interest.due` (poses changed since sent, or every
  `KeepAliveSeconds`) in unreliable Poses messages of at most 40.
- *Leaks closed*: edits go only to players within `EditSendRadius` (26) chunks of them
  (`Interest.routeEdits`: one shared message for those near all of a frame's edits; none without a
  position); a chunk's edit list (and the records sent after it) is answered only within
  `EditChunkRadius` (24) chunks of the player, farther requests wait in a per-player queue (at
  most `DeferredChunkRequests`, oldest dropped) answered by a scan twice a second once they come
  near (the client asks for a list once and waits); records of machines, pipes and structure blocks
  go to nobody without a position (before: everyone); server lightning is sent within
  `LightningDistance` (512) blocks (before: 4096; the clients draw far storms themselves).
- *Every server read of a position* is `PlayerPositions`' (reach, hulls in the way, suffocation,
  lava and burning, blasts, lightning, landings, items, sounds, mobs, weather, records, biome
  discovery, thirst and temperature, /weather, /summon, saves, map and spectator teleports); only
  `World/Simulation` still reads the root (the server generation work replaces it).
  `PlayerPositions.networked()` says whether the rules above apply; `spawned(player, character)`
  (Characters.park) and `store()` (PlayerRelay, ServerNet) reach the records.

Config: `Origin` (Enabled, RebaseDistance, SoftDistance, Snap), `Interest` (PlayerDistance 256 and
its hysteresis 16, RelayRate 20, KeepAliveSeconds, MaxPosesPerMessage 40, InterpolationDelay 0.1,
EditChunkRadius 24, EditSendRadius 26, DeferredChunkRequests, LightningDistance 512), `Players`
(ServerPositions, MoveRate 20, MoveCheck "correct" / "log" / "off", MoveSlack, MoveLimits by game
mode, ParkPosition).

**The player's side** (client `Player/MovementController`, `Player/LocalPosition`,
`Player/RemotePlayers` + `Player/RemoteMotion`, `Player/SpectatorView`; specs `LocalPosition` and
`RemoteMotion`). With `Players.ServerPositions` off everything below reads and writes the
characters as before (the old unanchored path is kept as the switch's other side); conversions go
through `Origin` either way (the identity while it stays at 0).
- *The local character.* The hull and the drawn feet are doubles (`View.feetX/feetY/feetZ`;
  `feet` stays as their float32 Vector3 for readers near the camera) and the root goes at
  `Rig.rootCFrame(character, Origin.blocksToRender(feet), yaw, tilt, bodyPitch)`. On: the root is
  anchored by the server, so no VectorForce, no velocity and no "moved by another script" check;
  a new character is placed at once at the newest Teleport (else `SpawnPosition`), frozen, and
  waits for the Teleport whose `life` equals its `IceVoxelLife` attribute (`LocalPosition.placing`:
  either may arrive first; `SPAWN_SETTLE` falls back to the newest). Every Teleport of that life
  (teleports, corrections) snaps the hull, sets the yaw, tells the streamer (teleport mode) and
  `Rebase.request`s the destination, then the move epoch is adopted. Death on: Minecraft's tilt
  (`Rig.deathCFrame`, 20 ticks) in a render step of its own, in the render frame of each moment;
  after a second `SpectatorView` hides the body (`MovementController.deathTime`). Off: the body
  falls as before. `Origin.onRebase` shifts `lastPlaced` and the view bob's camera CFrames (so
  `unbob` still finds its own CFrame). Screens and the Options menu (`Screens.changed`), Roblox's
  menu and the death set `Rebase.setHidden` ("screen", "menu", "dead"); the world map sets "map".
  `Config.Origin.Enabled` without `ServerPositions` is warned about: a character the client owns
  would replicate render studs.
- *Moves* (`LocalPosition.step`, pure): after the movement's ticks, the newest tick's hull (f64
  feet), yaw, look pitch, tilt, flags (`LocalPosition.flags`), speed and climb, with the adopted
  epoch and a u16 seq, on `Remotes.moves()`; at most `MoveRate` a second in a steady rhythm (a new
  rhythm after a pause or a long frame, never a burst), an unchanged pose only every `KEEPALIVE`
  (1 s), nothing before a Teleport was adopted, while frozen or while spectating.
  `MovementController.spectate` sends `Spectate` (0 when it stops).
- *Other players* (`RemotePlayers` networked): `Players` messages track (slot, user, whole pose)
  and untrack by slot (a track for a user not in this client's game yet waits for `PlayerAdded`);
  `Poses` on `Moves` go into each slot's `RemoteMotion` ring with their tick's server time; poses
  of untracked slots are dropped. `RemoteMotion`: the server clock from the ticks (u16 unwrapped
  the nearer way, the smallest `arrival − tick time` over the last 1–2 s), playback at that minus
  `InterpolationDelay`; feet lerped in doubles, yaw the short way, flags of the nearer snapshot; a
  jump over 8 blocks snaps; past the newest, extrapolation along the last velocity for 0.1 s, then
  hold; late or repeated snapshots ignored. The render step `IceVoxelRemotePlayers` (Camera − 2,
  after the origin's, before the local character and the camera) samples every tracked record and
  writes its root (`Rig.rootCFrame` at `Origin.blocksToRender`; the death tilt when the pose is
  dead). `RemotePlayers.shown(player)`: tracked and not a body gone after its tilt (compat: always).
- *Visibility* (`SpectatorView`, the one writer of other characters' `LocalTransparencyModifier`
  and `DisplayDistanceType`): characters not `shown` are hidden whole, nameless, their Highlights
  (the Glowing outline) off; spectators as before. What can be hidden of a character is listed once
  and again only when its descendants change. `HeldItems` and `BurningView` skip characters not
  shown.
- *Consumers*: `BlockInteraction` casts from `Origin.renderToBlocks(ray.Origin)` (the aim `Ray`
  carries the origin as doubles), compares reach in render studs, places the outline and the debris
  at `Origin.blocksToRender` (live debris has a `Rebase` mover), and checks placement obstruction
  and the spectator's pick against `RemotePlayers`; `CrackOverlay` likewise (a mover while shown);
  `Eating` and `Drinking` sound at the drawn hull; `Waila` picks from doubles and names other
  players' true coordinates through `RemotePlayers`; the minimap and the world map centre on the
  character read back through `Origin` and dot only `RemotePlayers.each()`; `Waypoints` beacons
  stand at `Origin.blocksToRender` with a mover; F3 adds the `origin` line (`Rebase.stats`, the
  move epoch and the players tracked).

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
| client → server | `SetGameMode`   | a GameType id (u8: 0 survival … 3 spectator): switch one's own game mode (the switcher, `F3` + `N`) |
| client → server | `SpectatorTeleport` | a player's user id (f64, whole and finite): a spectator teleports to them |
| client → server | `SaveSettings`  | the chosen settings of the client's device profile (below), after changes and when the menu closes |
| client → server | `Exertion`      | movement that costs thirst since the last report: cm sprinted and in water, jumps, sprint jumps, sprinting now (7 bytes, about once a second) |
| client → server | `Drink`         | u8 action: start / finish / cancel holding a drink; hand (a sip) / fill (a bottle or canteen) at a water source's cell |
| client → server | `Attack`        | u32 mob id: a left click on a mob (4 bytes) |
| client → server | `Eat`           | u8 action: start / finish / cancel holding a food |
| client → server | `UnlockSkill`   | u8: a skill tree node's place in Progression/Skills (the server checks the Age, prerequisites and points) |
| client → server | `CreateWorld`   | the Create World screen: u8 game mode (0..2), u8 difficulty (0..3), u8 flags (allow commands, structures), then name, world type, encoded options and seed text (u16 length + UTF-8 each, at most 128 / 64 / 1024 / 128 bytes) |
| client → server | `EnterWorld`    | nothing: Join World (or a created world): the server loads the character once the world exists |
| client → server | `WorldAction`   | the Load World page (operators): u8 action (list, load, delete, rename), u16 length + world id (at most 16 bytes), u16 length + new name (rename) |
| server → client | `ChunkEdits`    | edit list of each requested chunk             |
| server → client | `Edits`         | every world change of the frame (or a reject) |
| server → client | `Waypoints`     | saved waypoints (on join, or after filtering) |
| server → client | `Inventory`     | inventory + window container after action `ack` |
| server → client | `Entities`      | dropped items: spawn / sync / count / remove  |
| server → client | `Notice`        | a message for the chat (and a link: /locate's coordinates and the command they suggest) |
| server → client | `Transmitters`  | transmitter states: packed side modes, colour, pipe fill, the fluid id its network holds |
| server → client | `Tanks`         | fluid tank contents (fluid id, mB)            |
| server → client | `Transport`     | items entering, re-routed in or leaving transporters (path, speed, start time) |
| server → client | `Machines`      | machines' energy, capacity, network input / output, rate, active, state code, tanks (fluid id, mB, capacity) |
| server → client | `Sound`         | sound events near the player (event, position, volume, pitch) |
| server → client | `StructureBlocks` | structure blocks' settings per position (none: gone); open flag (show the screen) |
| server → client | `Jigsaws`       | jigsaws' settings per position (none: gone); open flag            |
| server → client | `StructureData` | a piece of the text a SAVE made, for the player who saved: transfer, index, count, text |
| server → client | `Settings`      | one device profile's saved settings, one message per profile once loaded on join (count 0: none) |
| server → client | `Explosion`     | an explosion within 64 blocks: centre, power, this player's knockback (7 × f32; Minecraft's explode packet without its block list) |
| server → client | `Survival`      | the player's own thirst (thirst, hydration, exhaustion, Thirst effect ticks) and temperature (level, target, frozen, heat, wet), and which are on (10 bytes, when it changes, at most every 4 ticks) |
| server → client | `Mobs`          | mobs in tracking range: spawn (kind, variant, state) / state (position in 1/32 block, yaw in 1/256 turn, health, flags, fuse: 21 bytes) / remove / arrow (from, to) / push (this player's knockback) |
| server → client | `Effects`       | the player's status effects: u8 count, count × (u8 effect, u8 amplifier, i32 ticks (-1 infinite), u8 flags (bit 0 ambient, bit 1 paused: an external effect its owner holds, not counted down)), 7 bytes each, when the client's countdown would be off (EffectRules.needsSync) and empty for a new character |
| server → client | `Progress`      | the player's own knowledge points (u32), Age, unlocked skills, discovery counts by category and the Ages' milestones as bits (21 bytes and one a skill, after every change, one a frame at most) |
| server → client | `MenuState`     | the title screen's state (u8: waiting, creating, ready, failed), the operator's name and the world's (u16 length + text each), on joining and to everyone on a change |
| server → client | `CreateWorldResult` | u8 ok, u16 length + text: the answer to this player's CreateWorld |
| server → client | `WorldList`     | u8 saving works, u16 length + text (how the last WorldAction went), u16 count (at most 200), then each saved world: id, name, type and seed text (u16 length + text each), u8 game mode, f64 last played, f64 bytes |
| server → client | `WorldSave`     | u8 op: saving; saved (u8 flags ok / sizes / warn, then the sizes for operators only: f64 bytes, max, largest key, key limit; text); loading (u16 keys read, u16 of, text); state (u8 on / off / unavailable / session only, text why) |
| server → client | `Lightning`     | a strike within `Weather.Lightning.Distance` (4096 blocks): f32 x, y, z (the struck cell's bottom centre), u32 seed (the bolt's shape), u8 flashes (1-3): 17 bytes |

Fluids travel as Shared/Fluids ids, a u8 (0 none, 1 water, 2 lava, 3 oil, 4 fuel; encoders write
an unknown id as 0, decoders refuse one above `Fluids.COUNT` as malformed). A Transmitters record
is 15 bytes (`TRANSMITTER_BYTES`: i32 x, u16 y, i32 z, u16 modes, u8 colour, u8 fill, u8 fluid
id). A Machines record is its 40-byte fixed part (`MACHINE_BYTES`, up to the state code), then a u8
tank count (0 for a kind without tanks) and per tank a u8 fluid id, u32 amount and u32 capacity
(`MACHINE_TANK_BYTES` 9, at most `MAX_MACHINE_TANKS` 255), in the kind's tank order
(`Machines.tankContents`); `decodeMachines` refuses an unknown fluid id, a tank count longer than
the bytes left, leftover bytes and a record count that cannot fit (checked before anything is
made for it), and a record with no tanks decodes with `tanks` nil.

Structure settings travel in `Structures/Settings`' format (Net/Protocol uses its `write*` /
`read*`): unknown codes, NaN and strings over 128 bytes are malformed, numbers out of range are
clamped. Structure text goes in pieces of `Config.Structures.DataPieceChars` (16,000) characters,
at most `MaxDataChars` (200,000, 13 pieces) a text and `DataPiecesPerSecond` a second each way:
reliable RemoteEvents name no size limit but share about 500 requests a second per client, so
pieces keep each message small. `Protocol.joinStructureData` puts pieces back together in any
order, refuses ones that don't fit (another count, an index twice, too long) and drops older
half-received texts beyond 2 per sender.

Player settings travel in PlayerSettings' format: u8 version, u8 profile (1 desktop, 2 touch,
3 console), u8 count, count × (u8 id, f32 value), only the settings the player chose, by their
append-only ids. Another version, profile or length is malformed; unknown ids and NaN are dropped
and values clamped (a touch profile's to the phone limits). A full profile is 168 bytes, a typical
one 23.

On the client, `Net/ClientNet` owns the only listener (Roblox delivers queued messages to the first
listener that connects) and routes messages by type, keeping early messages until a handler exists.
On the server, `ServerNet.on(kind, handler)` registers handlers. What starts before the world
exists (Players/Operators, Players/SettingsStore, Players/WorldMenu) uses `Network/LobbyNet`: the
same `on` / `send` on the same remote with handlers of its own; ServerNet starts with the world
and listens too, each ignoring the other's message types, so every message is handled once and
sends stay in one ordered stream.

## Server

- `World/WorldServer`: generated chunk cache (evicted when no player is near) plus the edit lists.
  Chunks come in through `install` (their edits laid over, `onGenerated` once): `getChunk`
  generates inline, World/Simulation in the background (see Server chunk generation).
  `setBlock` records the edit, queues it for replication and notifies the block ticker.
- `World/BlockTicker`: scheduled block updates at `Server.TickRate`. A change notifies the block and
  its six neighbours; blocks with a behaviour schedule ticks. Overflow beyond
  `MaxUpdatesPerTick` moves to the next tick. Updates never generate chunks.
- `World/RandomTicker`: Minecraft's random ticks. After each BlockTicker step, every 16-block
  section of the chunks within `SimulationRadius` of a player (`Simulation.activeChunks`) gets
  `Server.RandomTickSpeed` (3) random picks read straight from the chunk buffer; a block whose
  behaviour has `onRandomTick(world, ticker, x, y, z, block, random)` runs it.
  `World/Skylight.open` stands in for Minecraft's light levels on the server (it has no light
  map): nothing opaque between a cell and the top of its chunk.
- `Behaviours/`: `Gravity` (sand, gravel), `Fluid` (Minecraft-style levels 0–7 plus falling,
  infinite water sources, spreading only towards the nearest way down; waits at unloaded chunks;
  washes away `brokenByFluid` blocks, which lava burns; water, lava, oil and fuel with their own
  rules, and lava hardening against water: see Fluids), `Grass` (turns to dirt when covered; on a
  random tick grass, dry grass and mycelium under the sky try 4 times to spread onto dirt within
  1 sideways, 3 down, 1 up whose top is open to the sky and free of opaque blocks and fluids;
  podzol never spreads), `Leaves` (decay: a neighbour change schedules a check after
  `Server.LeafDecay` 4-12 ticks, a random tick checks too; leaves with no log within 6 steps
  through leaves, unloaded blocks counting as a log, break with `Items.leafDrop`; leaves in the
  chunk's edit list as leaves were placed by a player and never decay), `Sapling` (stays up like
  a plant; on a random tick under the sky, chance `Server.SaplingGrowth` 1/14, runs its wood's
  Trees builder through a recording writer and places it only if every forced cell but its own is
  air, a plant or leaves; leaves only go into air), `Herb` (Mint and Wild Ginger: stay up like a
  plant; on a random tick, chance `Server.HerbSpread` 1/8, Minecraft's MushroomBlock.randomTick:
  unless 5 of the same herb are in the 9 x 3 x 9 blocks around, a walk of up to four random steps
  (-1..1 on each axis) onto air the herb survives in, and a new one where it ends if it may stand
  there; unloaded blocks are no room),
  `Attached` (torches and lanterns break and drop when what they hang on stops being sturdy),
  `Plant` (a plant whose soil or other half is gone breaks and drops what it drops by itself, in
  every game mode: a tall plant's lower half drops, its top never does, so a tall plant drops once),
  `Fire` (Minecraft's FireBlock, below).
  They drop items through `Drops`, which ServerNet wires to `Entities.dropBlock`
  (Transmitters/UseRules uses it too).
  - In `Gravity`, as in Minecraft, a falling block passes through blocks without a collision box
    (torches) and lands on those with one (`Blocks.obstruction`). Coming to rest in a torch's cell
    (a solid block under the torch) or on a lantern, it breaks into an item and the torch or
    lantern stays: the torch trick for clearing sand and gravel. Past wall torches with air under
    them it keeps falling, and a block placed on a torch stays where it is.
  - Plants in `Gravity` and `Fluid`: falling sand replaces the replaceable plants (no drop) and
    breaks into an item on flowers, tall flowers and mushrooms, which are not replaceable and have
    no collision box, as on a torch; flowing water washes every plant away with its drop (flowing
    lava burns it, with no drop). Plants are not opaque, so the grass under them stays grass and the
    sun reaches through them (`SkyCheck`), and a spawn may stand in one (`SafeSpot`).
  - `Fire` (Minecraft 1.20.1's FireBlock; the shared rules in Shared/Fire, each block's odds in
    BlockList `flammable`, Blocks `igniteOdds` / `burnOdds` / `isFlammable`, set by the bootstrap
    pass at the end of BlockList: planks 5 / 20, logs 5 / 5, leaves 30 / 60, grass, ferns, dead
    bushes and flowers (both halves of tall ones) 60 / 100, glow lichen 15 / 100, coal blocks
    5 / 5; no saplings or mushrooms, as in Minecraft). Tested in tests/spec/Fire.
    - Age 0..15 lives in a table by position per world, never in the block: the block stays the
      one Fire id (which other modules compare with: FuelBlast.isHot, ToughAsNails' heating
      blocks), and an age change costs no edit, no replication and no remesh (Minecraft sets it
      with flag 4 for the same reason). Variant blocks were not used: 16 ages (times the 32 shapes
      Minecraft keeps in the state) would be hundreds of ids for something only the server reads.
      Ages of fires that went out some other way are swept once the table passes 4,096.
    - A new fire is told apart from a neighbour change by its scheduled tick (a burning fire
      always has one): `ignite(world, x, y, z, age)` hands it its spreader's age, anything else
      (world:setBlock by flint and steel, lava or a blast) starts at 0. It schedules its first
      tick in 30 + rand(10) ticks, or goes out on the next tick where it can't survive (Minecraft:
      at once; a tick later the fuel under a fiery blast's fire has seen it). A neighbour change
      that leaves it unable to survive puts it out at once (updateShape); an unloaded neighbour
      leaves it be. A random tick restarts a fire whose tick was lost with its chunk.
    - `tick` is FireBlock.tick (with `Config.Server.Fire.Tick`, doFireTick): reschedule, out if it
      can't survive, age by rand(3) / 2, off a flammable neighbour out unless on a sturdy block
      and at most 3 old, at 15 out one time in 4 unless the block below burns, then checkBurnOut
      on the six neighbours (rand(300) sideways, rand(250) up and down, < burn odds: into fire one
      time in (age + 10) / 5, else air, no drop; a tall plant's other half goes with it; TNT and
      Nukes are lit instead, `Behaviours/Tnt.prime`, Minecraft's TntBlock.explode), then
      spreading into the empty cells 1 sideways, 1 below and up to 4 above with a flammable
      neighbour: rand(100 + 100 (dy - 1)) <= (ignite + 40 + 7 x `Config.Server.Fire.Difficulty`)
      / (age + 30). No rain, humid biomes or infiniburn blocks here.
    - `lavaTick` (Behaviours/Fluid's `onRandomTick` for lava, cave lava too; LavaFluid.randomTick):
      two times in three 1-2 steps up (each up to 1 sideways), lighting the first empty cell
      next to a flammable block and stopping at a solid one; else 3 cells at its level, lighting
      the empty cell above each flammable one. Minecraft's ignitedByLava is `flammable` here.
    - `light` (Players/ItemUse, flint and steel: FlintAndSteelItem.useOn): fire in front of the
      clicked side where `Fire.canPlaceAt` (empty, and it survives), item.flintandsteel.use, one
      wear (64 uses), none in creative; on TNT or a Nuke (any side) it lights it instead
      (TntBlock.use). The client sends the use only where the same checks pass. Players put fires out by breaking them (hardness 0: at once, no drop, the
      extinguish hiss), water washes them away (`brokenByFluid`, no drop; lava fizzes), and a
      block placed into one replaces it (`replaceable`).
- `World/Explosions` + `World/FuelBlast`: blasts and fuel going off, stepped after the block
  ticker every tick (see Explosions). `Behaviours/Fluid` hands fuel touching fire or lava to it.
- `Behaviours/Tnt` + `World/Nuke`: lit TNT and Nukes (block ticks) and the Nuke's crater, stepped
  after the explosions every tick (see TNT and the Nuke).
- `World/Simulation`: keeps chunks within `Server.SimulationRadius` of players generated, a
  slice of each frame on a generator of its own (see Server chunk generation).
- `Network/ServerNet`: rate limits, reach checks, the game mode (`EditRules.mayEdit`: survival and
  creative edit, adventure and spectator edits are answered with the real block;
  `EditRules.minesOverTime`: only survival's Mine messages count), breakable / placeable /
  replaceable checks, no placing inside players (`EditRules.obstructs`: solid blocks and lanterns,
  not torches or plants; spectators are never in the way, `EditRules.blocksPlacing`), survival
  mining time and drops (`EditRules`; its `creative` is the instabuild ability), and the rules
  injected by the boot script (`setRules`: using up placed items, dropping items and chest
  contents). Rejections never generate terrain.
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
- `Mobs/`: mobs, their spawning, players' attacks and /summon (see Mobs); `Players/Eating`: food.
  `Characters.hurt` is how a mob's hit reaches a player (the hurt cooldown and armor).
- `Players/GameModes`, `Players/GameModeCommand`, `Players/GameModeRules`: see Game modes.
  `Players/Inventories`, `Players/Containers`: see Items and inventories. `World/TimeOfDay` and
  `Players/TimeCommands`: see Day and night. `Audio/Sounds`: see Sounds.
- `Players/Characters`: puts every character part in the `IceVoxelCharacters` collision group
  (it collides with none of the groups registered when the server starts; parts go back to Default
  on death, so the body falls, and when they leave the character), teleports characters by setting
  the feet position as attributes the client's hull follows (`teleport` to a block, `teleportFeet`
  to an exact spot), and turns reported landings into fall damage in survival and adventure
  (`GameModeRules.fallDamage`: `ceil(distance − 3)` of 20 half hearts, none for players who may
  fly, scaled to `MaxHealth`, through `TakeDamage`; landings that do no damage are ignored, the
  others at most 4 a second). Creative and spectator characters hold an invisible ForceField
  (`IceVoxelInvulnerable`), so `TakeDamage` can't hurt them. Players in a wall suffocate
  (`GameModeRules.inWall`): half a heart every 0.5 s. Lava hurts and burns (`Players/Burning`, at
  20 ticks a second, catching up at most 4 a frame, on the standing box at the feet against the
  server's loaded blocks, with the armor worn from `Inventories`; see Fluids), and a burning
  character carries `IceVoxelOnFire`. It also plays the hurt, death, hurting-landing, burn and
  extinguish sounds to everyone near (see Sounds), never a spectator's. Explosions hurt and push
  players through `Characters.explosion` (see Explosions).
- `Players/Teleport`: map teleports (see Map), and spectators' `SpectatorTeleport` (see Game
  modes: On the server).
- `Players/SettingsStore`: players' settings, one profile per kind of device, in a DataStore (see
  Player settings).
- `Players/Operators`, `Players/WorldMenu`, `World/WorldInfo`, `Network/LobbyNet`: operators, the
  title screen's server side, the world's settings and its one creation, the net before the world
  (see Title screen, operators and creating the world).
- `World/WorldSave`, `Save/`: saved worlds in DataStores: the world list, loading one, autosave,
  `/save-all`, `/save-off`, `/save-on`, players' records and the sections other parts register
  (see Saving worlds).
- `Structures/`: structure blocks, jigsaws and their Generate, and who may use them (see
  Structure blocks and jigsaw structures). `Players/Containers` fills a generated structure's chest
  from the generator the first time its contents are needed; ServerNet's `operator` rule
  (`EditRules.mayUseCreativeOnly`) keeps operator blocks to players allowed to use them, and
  EditRules refuses cave twins; `Fluid` never flows into a structure void.
- `Transmitters/`: Mekanism pipes (see Mekanism pipes); `Players/ItemUse`: the Configurator and
  buckets (UseItem). A full bucket that replaces a plant (`UseRules.pour`) drops it, lava's too, as
  Minecraft's BucketItem.emptyContents destroys the block with drops.
- `Players/SafeSpot` + `Players/SpawnUnsafeBlocks`: a spot is safe when the floor is solid and not
  listed (`Floor`), the body's blocks are free and not listed (`Body`: water, lava, oil and fuel,
  each name covering its levels and cave twin), nothing listed in `Hazards` (cactus, lava) touches
  the body, and the feet are not below the natural surface (no cave spawns; in a pit's or a ravine's
  column the floor at the natural surface is air, so none there either, and the generator's
  `findSpawn` already skips them). The search checks the target column, then rings around it. In
  chunks nobody edited the terrain is exactly what the generator makes, so open water is skipped
  from the generator's height alone and columns are scanned from just above the tallest structure.
  Spawning re-checks the spawn spot on every respawn, since players may have built or poured water
  there; when no safe spot exists it waits 30 s before searching again.

## Server chunk generation (server `World/Simulation`, `World/GenQueue`, `World/WorldServer`)

The server generates the chunks around players itself, from the seed, at full detail: block
updates, random ticks, mobs and edit validation read them. Minecraft keeps the chunks within a
ticket distance of each player loaded and generates new ones off the main thread; here they are
generated on the main thread, but a slice of each frame at a time.

- **Two ways in.** `WorldServer.getChunk` generates inline on the world's generator for anything
  that needs a block now (edit validation, `setBlock`, SafeSpot for spawns and map teleports,
  structures, the Api; counted in `inlineChunks` / `inlineMs`). The chunks around players come
  from Simulation's background job instead. Both end in `WorldServer.install(cx, cz, data,
  height)`: the chunk's edits are laid over the terrain (the buffer grows when one lies above the
  crop), it is stored and `onGenerated` runs once. A chunk already there (getChunk made it while
  the job ran) is kept and returned with false; the late terrain is dropped. Edits made while a
  job runs either generated the chunk inline (`setBlock`) or wait in `world.edits` (a loaded
  world's), so the install lays them over either way.
- **Windows and order** (`GenQueue`, pure). Every 0.5 s, and at the next frame after a teleport
  (`PlayerPositions.teleported`), Simulation gives GenQueue the chunk of every player's feet
  (`PlayerPositions.each()`: true world positions, whatever the characters replicate; a spectator's
  is its target's). The chunks within `SimulationRadius` (3: 7 × 7) of a player are *near*: they
  are generated, and block updates, random ticks and mobs run there (`Simulation.activeChunks`).
  One ring wider (9 × 9) is *kept*: eviction (`WorldServer.evict`) never drops those and keeps at
  most `CacheSize` (192) others, least recently used dropped first. The queue holds every near
  chunk neither generated nor in flight, closest to its nearest player first (dx² + dz²: a
  player's own chunk and the 8 around it lead), ties by age, then by coordinates. Chunks that
  left every window leave the queue, and the job in flight is abandoned when its chunk did.
- **The job.** One at a time: a coroutine running `generate(0, cx, cz, yield)` on a second
  generator instance, built once from the world's type, seed and options. It can't be the world's:
  a generator keeps per-instance column scratch, so two calls in flight on one instance corrupt
  each other (14 chunks in 15 came out wrong when tried). Two instances are safe, since no
  generation module keeps module-level scratch across a yield: the spec runs the world's generator
  at every yield of the background one and compares both with chunks made in one go. A generator
  never resumed leaves nothing half done (its caches take an entry only once complete), which the
  client's cancelled worker jobs relied on already; an abandoned job is simply dropped.
- **Slices.** `yield` suspends the job once the step's deadline has passed; `step(budget)`
  resumes it, installs it when it finishes and starts the next while time is left. A step lasts
  its budget plus the stretch to the generator's next yield. Over 600 cold random chunks (seed
  12345, Lune, native) the longest stretch per chunk is p50 0.7, p99 3.6 and at most ~5 ms, since
  Lakes' puddle decisions, SurfaceCaves' worm builds and the tail of TerrainGenerator.generate
  (after the ores, the trees and library structures, the mineshafts) now yield inside; before
  that it was p99 9.2 ms and 10.7 ms at most, in one puddle decision.
- **Budget** (`GenQueue.budget`, Config.Server): `GenerationBudgetMs` (4) a frame;
  `UrgentGenerationBudgetMs` (8) while a player's own chunk or one around it is missing (a join or
  a teleport) or more than `UrgentBacklog` (49, a window) chunks wait; never past `FrameBudgetMs`
  (12) of the frame's work so far, measured from `RunService.PreSimulation`, the frame's first
  script step; but always `MinGenerationBudgetMs` (1), so the backlog keeps moving. Budgets that
  run later in the frame (/locate's search, the pose relay) come on top.
- **Why not Actors.** A chunk costs 3.4-3.75 ms along a walk (the region caches stay warm) and
  ~11 ms alone; 8 sprinting players need ~1.3 ms of generation a frame. Roblox gives a server
  Parallel Luau threads by its maximum player count (one for a small server), every Actor is its
  own VM with its own copy of the native generation code and caches (+8-23 % CPU), and chunk
  buffers would be copied across. On one thread an Actor pool only slices the work, as this
  does. What hurt was one whole chunk a frame: 16-45 ms frames whenever one generated (40-50 ms
  interpreted) and at most 60 chunks a second. Actors become worth it with 20-30+ player servers
  of flyers, an interpreted generator, or a bigger SimulationRadius: GenQueue's job would then go
  to K workers (a Folder of Actors running the generator, chosen by 8 × 8-chunk region so their
  caches stay warm, results installed on the main thread through `install`).
- **/genstats** (operators): the last 10 s of background generation (chunks/s, ms/s, the worst
  frame), the backlog and the chunk in flight, the totals (generated, dropped because made
  meanwhile, abandoned, failed) and the chunks generated inline since the start.

Measured (`lune run tests/servergen <scenario>`: players spread 6-18k blocks apart moving
diagonally, 60 Hz frames, the real Default generator on seed 12345, Lune, native code; before =
the old Simulation, one whole chunk a frame; after = GenQueue with the budget above):

| Scenario | Frame while generating, p99 / max (ms) | Frames over 16.7 ms | Chunks/s | A player's own 3 × 3 waited (max) | Every window complete / backlog at the end |
|---|---|---|---|---|---|
| 1 walking, 30 s | 14.8 / 17.1 → 9.8 / 15.0 (a rerun: 8.2 / 9.1) | 0.1 % → 0 | 4.0 → 4.0 | 0.13 → 0.12 s | 0.80 → 0.77 s |
| 1 joining | 12.1 / 12.1 → 9.0 / 9.0 | 0 → 0 | | 0.13 → 0.12 s | 0.80 → 0.78 s |
| 8 joining at once | 10.6 / 17.9 → 9.0 / 10.5 | 0.2 % → 0 | | 1.18 → 0.60 s | 6.52 → 3.20 s |
| 8 sprinting, 20 s | 10.6 / 18.5 → 8.6 / 11.8 | 0.1 % → 0 | 38.4 → 41.7 | 1.57 → 0.60 s | 7.45 → 3.70 s; 21 → 21 waiting |
| 8 flying, 15 s | 10.0 / 21.1 → 8.6 / 11.9 | 0.2 % → 0 | 56.3 → 66.9 | 1.35 → 0.67 s | 36 → 33 waiting |
| 8 sprint-flying, 12 s | 11.7 / 19.9 → 8.9 / 12.0 | 0.1 % → 0 | 60.0 (the cap) → 99.4 | 2.20 → 0.68 s | 178 → 70 waiting |

The frames over 16.7 ms were single chunks (the report measured up to 45 ms natively, 40-50 ms
interpreted, on other chunks); a frame now lasts its budget plus at most one stretch. With 4 cores
shared by other jobs a run shows the odd outlier either way (a rerun of the walk: 9.1 ms at most).

## Hidden caves, octrees and regions

**How caves are hidden.** Caves are carved as `CaveAir` and never reach the surface on their own;
cave entrances and ravines (`SurfaceCaves`) are carved as Air and run into them. The mesher can
treat cave air (and the cave twins: the glow lichen generated on cave walls, the lava of the
caves' lava seas and lakes, the oil of buried deposits, the mineshafts' rails, fence posts,
cobwebs, wall torches, moss carpets, vines and hanging roots) as rock (`hideCaves`), which removes every
cave wall, and draws the hidden side of a junction with open air as stone caps; sections are meshed
with caves visible only while the camera is below the terrain surface, and only those its section
visibility search reaches (see Meshing, Streaming and Cave visibility above); the Caves setting's
Always Shown meshes every full detail section with its caves instead (about 4 × the parts).

**Octrees** are a storage / search structure: a cube split into 8 children until regions are
uniform. They compress big uniform volumes (air, solid rock) and speed up ray tracing and some LOD
schemes. They are not what hides caves. Our quadtree LOD (`World/LodTree`) is the 2D cousin. With
column chunks and greedy boxes, an octree would mostly help memory (a mostly-air column could be
stored as a few nodes instead of a cropped column buffer), and could be added later as a chunk
storage format.

**What Minecraft does for caves.** Minecraft splits chunks into 16³ sections and, for each section,
flood-fills its air to record which of the six faces connect to each other ("advanced cave
culling", 2014). At render time it walks from the camera's section through connected faces;
sections it never reaches are not drawn. IceVoxel does the same for its hidden caves
(`World/SectionGraph`, see Cave visibility): workers record the face connectivity of every section
that may hold caves with its generation and its edits, and the main thread's search decides which
sections are meshed with their cave walls, instead of a sphere around the camera. Unlike
Minecraft, a section the search misses is not left out but drawn as rock with stone caps, so a
miss never shows the void. The "camera below the surface" switch stays: above ground no cave is
revealed. Far terrain gets a coarser kind of occlusion culling, by horizon (see Far nodes behind
terrain).

**Regions** in Minecraft are a *storage* format: the save file groups 32 × 32 chunks into one
`.mca` file so disks do not juggle millions of tiny files. They have nothing to do with rendering.
IceVoxel saves the same way: each region's edits and state are one DataStore key (split in parts
past 4 MB), so a world of a few hundred regions needs as many requests, not one per chunk (see
Saving worlds).

## Rules to keep in mind

- Saved worlds outlive versions: `Save/RegionCodec`, `PlayerCodec` and `WorldMeta` carry a format
  version and are read by tags and lengths; add record tags and fields, never change what an
  existing one means (bump the version and keep reading the old one), and keep block, item, mob
  and fluid ids append-only (a saved world stores them). State another part keeps with a world
  goes through `WorldSave.registerSection`, not new keys.
- Generation must stay deterministic: use `Util/Hash` (never `math.random` or `Random`) and only
  the seed and coordinates as inputs. Clients and server must agree on every unedited block.
- Block ids are list positions in `BlockList`: append, never reorder. The same holds for items in
  `ItemList` (ids from 4096).
- Status effect ids are list positions in `Effects/EffectList` (sent as a u8), and potion items
  follow `Effects/PotionList`'s order (and each potion's base, strong, long): append, never
  reorder. Every hurt a player takes on the server goes through `Players/Effects.incomingDamage`
  (Resistance), and the mining factor reaches both the client's progress and ServerNet's check
  (`Mining`'s `factor`), or their timings drift apart.
- `Inventory/Menu` and `Crafting` must stay pure and deterministic: the client predicts every
  inventory action with them and must reach exactly the server's result. Both sides check
  `Menu.allows(action, mode)` before `Menu.apply`, and pass the instabuild ability as `creative`.
- Game modes are asked for what they allow (`GameMode.mayBuild(mode)`, `instabuildOf(player)`...),
  never compared (`mode == GameMode.CREATIVE`), the way Minecraft reads a player's Abilities.
- Sides are Minecraft's Direction ordinal everywhere in the pipes (0 Down .. 5 East,
  `Transmitters.SIDES`); transmitter modes, colours, network buffers and tank contents live in
  memory, like chests.
- Transmitters, fluid tanks, chests and furnaces come from edits: the pipes (and furnaces pushing
  their results into chests) read unloaded chunks' edit lists to find them. The one exception is a
  library structure's chests and furnaces, and a second the mineshafts' chests, which
  Players/Containers fills from the generator (`structureContainer`) when first needed and the
  pipes only see in loaded chunks. Keep
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
- Machine data starts with the shared header (energy always at 1); kinds append fields, then their
  tanks, at most 16 values in all. Kind ticks replace slot stacks (never change a stack table) and
  add or use energy through `Machines.produce` / `use`, so energy stays exact.
- Machines and cables only come from edits, like pipes.
- Kind modules require Machines/Core, Machines/Upgrades and plain shared modules (Items,
  Crafting/Smelting, DayCycle, Fluids), never Shared/Machines, Inventory/Menu or Shared/Transmitters
  (those require Machines: a cycle). A kind keeps per-machine state in its data fields, not in
  module tables.
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
- Cave twins must look, drop and behave exactly like their twin (Blocks checks it at load; a fluid
  twin is a source of its group, and `Blocks.fluidId` never answers one), and glow lichen
  generation (`Generation/CaveDecor`) decides each cell from the seed, its position and its
  in-buffer neighbourhood only, like foliage. A lichen is 2 parts: caves hold thousands.
- Fluid ids (`Fluids/FluidList` positions) are sent and saved in items: append a fluid, never
  reorder (at most 255). Code that holds or tells fluids apart asks Shared/Fluids (`blockLut`,
  `ofBucket`, the record), never names water; every fluid group needs its flow `RULES`
  (Behaviours/Fluid) and its own bucket item, and the registry checks BlockList and ItemList
  against it at load.
- Mineshafts are planned from the seed and the full detail terrain only (never a chunk's blocks),
  and write an opaque or ordinary block from the plan, cell hashes and its own column only; only
  cave twins may read their four sides. Everything they put into cave air is cave air or a cave
  twin (a new decoration needs a twin), everything in the open (a surface cave, the entrance
  shaft) the ordinary block, and their pieces and shafts are marked read in the cave lattice
  (`Caves.markRead`). Nothing they plan asks the mineshafts back (trees and lava lakes only read
  their boxes).
- Surface lava lakes and oil wells are decided from the seed and the full detail terrain only
  (heights, biome, structure pieces, the spawn, the surface caves' worms), never from a chunk's
  blocks; underground lava lakes from the chunk's own blocks, but their lava and bowl stay in the
  core's cells 1..14, so no padding holds them. What puts cave cells into rock marks the cave
  lattice (`Caves.mark`), and what digs below the ground lowers `topCells`. Generated lava and oil
  open to the sky (surface lava lakes, surface caves' lava, a geyser's lake and its spout from the
  lake up) are ordinary blocks; inside rock and caves they are cave twins, so hidden caves and
  buried deposits stay free.
- A pipe network's buffer holds one fluid: fills keep pipes of other fluids out. A kind's tick
  changes its tanks only through `tankInsert` / `tankExtract`. The fluid ejector pushes only into
  pipes that lead the fluid somewhere and never into another line's supply tank
  (Transmitters/Fluids); keep it so, or a machine's output clogs the pipe feeding it.
- Operator blocks (`creativeOnly`) break and drop nothing for survival players, and only players
  `Structures/Permission` allows place, break or use them; a new one needs `drops = false`
  (checked at load).
- Terrain geometry goes in and out of the workspace only through ChunkRenderer and MeshOverlay:
  the new before the old leaves, the old `Render.SwapFrames` frames later with its lights off at
  once, and every removal within the frame budgets (`UnparentPartsPerFrame`, `SwapPartsPerFrame`,
  `ReleaseBudgetMs`). A section has at most one build that is not live yet; sections that must
  change together share a commit group.
- A revealed section's side may only open towards a section that draws its caves on screen
  whenever this mesh does (its revealed mesh live, or going live in the same commit group), and a
  section goes hidden only together with the caps closing towards it; anything looser shows the
  void through a tunnel. `World/SectionGraph`'s faces are `GreedyMesher.Border`'s hidden bits
  (0 −X, 1 +X, 2 −Z, 3 +Z, 4 −Y, 5 +Y; the opposite face is f xor 1): keep them the same.
- A Horizon summary must never overstate an occluder: ground only ever drops (edits), estimates
  never occlude, and a node is hidden only when hidden from every eye. A wrong "hidden" skips
  parts the player can see. (Surface caves are the one known, small exception: see Far nodes
  behind terrain.)
- Surface caves (`Generation/SurfaceCaves`) decide every block from the worms, and a worm from the
  seed, its grid cell, the full detail surface and the seed-only cave regions; whether one opens
  under a tree (`carvesTop`) or where it cuts a seam (`lowestCarved`, `mayCarve`) is answered from
  the worms too, never from a chunk's data, so every chunk and level agrees. Keep it so.
- Player setting ids (`PlayerSettings` entries) are saved and sent: append, never reorder or
  reuse one. A setting's effect key needs a function registered in the client script
  (`Settings.missing()` lists those without), and anything a worker needs travels in its jobs:
  worker actors keep their own Config.
- Textures are set only in `Shared/TexturePack`, which stays pure data (every VM requires it).
  After editing it run `lune run tests/build_textures`; `src/textures` is generated and never
  edited by hand (`--check` and the TexturePack spec fail when it is stale). Cave twins never get
  entries. `Blocks.variantTexture` is the one rule for a cube's MaterialVariant: TextureLooks and
  `alignLut` both follow it.
- Looks come only from `Rendering/TextureLooks`: PartPool, ChunkRenderer, MeshOverlay (through
  `setLooks`) and ItemModels ask it, so near, far, plain, meshed and item looks agree. A change of
  looks goes through its generations and `changed` / `itemsChanged`, and what it touches is
  rebuilt in the background lane, never all at once.
- Mob kinds (`Entities/MobList` positions) go on the wire as a u8: append, never reorder. Mobs
  only tick in the chunks World/Simulation keeps (loaded, near a player) and read blocks with
  `peekBlock`; spawning never generates terrain and never places a mob in a chunk that doesn't
  tick. Mob AI and physics stay pure (MobWorld, MobAI, MobSpawning, MobPhysics take their blocks,
  players, time and randomness as arguments), so the specs run them; Roblox calls stay in
  `Mobs/Mobs`. Light for gameplay comes from `World/LightEstimate`, the one estimate WAILA shows.
