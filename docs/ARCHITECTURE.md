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
`16 × 2^L` blocks with 16 × 16 cells, and `256 / 2^L` cells vertically.

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
full detail chunk while covering `4^L` times the area. LOD chunks also lower their border columns by
one cell ("skirts"): where a coarse chunk meets a finer one, this keeps the coarse chunk from hiding
border cells the finer neighbour leaves exposed, which would otherwise show up as thin cracks.

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
- glass is covered exactly; **fluids** only where they touch a different non-opaque block, so oceans
  become thin sheets instead of tall transparent boxes;
- with `hideCaves`, cave air counts as rock and every cave wall disappears.

Boxes grow along X, then Z, then Y. Output is a buffer of 7 × u16 per box. Tests check the
invariants (every visible block covered once, nothing visible covered by a wrong box) on generated
chunks of every LOD.

Full detail chunks are meshed in 16-block vertical sections, so an edit only rebuilds one section.
LOD chunks are meshed as one range between `solidBelow - 1` and `emptyAbove`.

## Client

### Streaming (`Streaming/ChunkStreamer`)

`LodTree.select` tiles the world with root nodes of the coarsest level and splits a node into four
children while the viewer is closer than `SplitDistance × nodeSize`. The leaves are the chunks to
show. They never overlap and leave no gaps. Hysteresis prevents flapping at split boundaries.

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
the last replacement appears. `Streaming.ReplaceTimeout` is a safety net.

**Edits.** Full detail chunks keep their block data on the main thread (`World/ClientWorld`). Edits
(local predictions and server messages) update the data and the neighbours' padding, and mark the
affected mesh sections dirty. Dirty sections are remeshed by workers before any new generation.
If an edit arrives while a chunk is being generated, the outdated result is discarded and the chunk
is regenerated.

**Caves.** While the camera is below the terrain surface, sections within `Caves.RevealRadius` are
meshed with caves visible; everywhere else cave air counts as rock. Sections are remeshed as they
enter or leave that radius.

### Rendering (`Rendering/`)

Every node is a Folder of section Folders. A section is built outside the workspace and swapped in
whole. Parts come from `PartPool`: one template per appearance and near/far variant, so a recycled
part only needs a new size and position. Near parts collide and can be raycast; far parts do
neither and never cast shadows.

### Interaction

Targeting uses `World/VoxelRaycast` (grid traversal) on the client's block data. Edits are applied
immediately and sent to the server; a rejected edit comes back as the real block and undoes the
prediction. `Player/SpawnGuard` keeps a new character anchored until the chunk under it is ready.

## Networking (`Net/Protocol`)

One RemoteEvent carries `(messageType, buffer)` in both directions. A single remote keeps
server → client messages strictly ordered, which edit lists rely on: a chunk's edit list and the
live edits after it must arrive in the order they were sent.

| Direction       | Message         | Content                                       |
| --------------- | --------------- | --------------------------------------------- |
| client → server | `RequestChunks` | up to 256 chunk coordinates                   |
| client → server | `Edit`          | break / place, position, block                |
| server → client | `ChunkEdits`    | edit list of each requested chunk             |
| server → client | `Edits`         | every world change of the frame (or a reject) |

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

## Rules to keep in mind

- Generation must stay deterministic: use `Util/Hash` (never `math.random` or `Random`) and only
  the seed and coordinates as inputs. Clients and server must agree on every unedited block.
- Block ids are list positions in `BlockList`: append, never reorder.
- Anything crossing actor boundaries (jobs, results) may only contain numbers, strings, buffers,
  dense arrays and string-keyed tables.
