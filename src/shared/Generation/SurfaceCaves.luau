--!strict
--!native
--[[
	Surface caves: cave entrances and ravines, carved as Air right after the deep caves
	(TerrainGenerator). They are Minecraft 1.20.1's two overworld carvers, adapted to a world whose
	deep caves (Caves.luau) never come near the surface.

	Entrances (CaveWorldCarver, Config.Caves.Entrances)
	  One candidate per Spacing x Spacing block cell, taken with Chance, at a hashed column of the
	  cell. A tunnel of ellipsoids, one per step of a block, starts on the column's surface:
	    * flat ground: sloping down at a hashed 0.45..0.8 radians, so the opening is a pit; on
	      slopes of MOUTH_SLOPE or more it heads uphill nearly level, so mountain flanks get mouths;
	    * Minecraft's wander: yaw += f * 0.1 with f = 0.75 f + noise, pitch relaxing by 0.7 a step
	      plus 0.1 of its own noise, here towards a target pitch (the start's slope down while the
	      tunnel is less than its hashed Depth below the surface, levelling off over LEVEL_OFF
	      blocks) instead of 0;
	    * it heads for the deep caves: a pit picks, of four right angles to its hashed heading, the
	      one whose point at its depth lies deepest in the cave regions (Caves.regions, the
	      carver's barrier2 gate), and every STEER_EVERY steps a tunnel outside a full strength
	      region turns towards the better side. Without that ~35% of the entrances met cave air,
	      with it ~60%;
	    * the horizontal radius varies smoothly within Radius (hashed knots every KNOT steps), the
	      vertical one is a hashed 0.85..1.15 of it, and each ellipsoid is cut at a hashed floor
	      level of -0.85..-0.5 (Minecraft's -1..-0.4: flat floors); like Minecraft, a quarter of the
	      steps is skipped (rougher walls), but never two in a row (a thin, steep tunnel would be
	      walled off);
	    * past its first OPENING steps it goes into the ground: while its centre is less than its
	      vertical radius + COVER below the lowest surface around it (the downhill side of a slope),
	      it dives at DIVE radians or more and its pitch noise only pushes it down. One that never
	      got under the ground by MAX_OPENING steps, or came out of it again for more than REOPEN
	      steps (the ground falls away faster than it dives), ends there, without a chamber. So
	      entrances open at their start (and maybe where they leave a slope), never as long open
	      ditches along the surface;
	    * some (Branch) fork once, 30..60% along, sideways (Minecraft's right angle and a third of
	      the pitch), thinner, shorter and a little deeper;
	    * after Length steps it ends in a small chamber; one that runs into cave air on the way is
	      joined to the cave network there.
	Ravines (CanyonWorldCarver, Config.Caves.Ravines)
	  One candidate per (larger) Spacing cell. A long cut, Length steps of a block, gently curving
	  (yaw += f * 0.05, f = 0.5 f + noise). Its half width is Minecraft's width curve,
	  r0 + sin(pi i / n) * thickness times 0.75..1 per step, and its depth below the surface (a
	  moving average of the surface along it, so the floor is smooth) follows the same curve from
	  END_DEPTH at the ends to a hashed Depth in the middle. Its floor is rounded over its lowest
	  ROUND blocks and its walls are jagged by Minecraft's width factor per block of height,
	  (1 + r1 r2)^2 redrawn on a third of the levels (cells carve where d^2 * factor < 1); each
	  column is cut from its lowest such cell up to its top, so the cut is open to the sky and has
	  no overhangs (no rim block is left floating on a slope).

	Determinism. Every worm depends only on the seed, its grid cell and the full detail surface
	(`surfaceAt`: the generator's column heights and river strength; the cave regions are seed
	only). A chunk visits every cell whose start lies within the kind's reach (its longest worm) of
	its padded box, so every chunk sees every worm that reaches it, and clips its writes to that
	box: padding equals the neighbouring core. Cells (their candidate and built worm) are kept in
	an LRU per generator. Each block is decided alone (carvable rock inside a carved ellipsoid or
	cut), so the order of the worms does not matter.

	Cell rules
	  * Carved cells become Air: surface caves are part of the surface, drawn from above and lit by
	    the sky. Only opaque rock and soil is carved: never bedrock, water, ice or cave air, so cave
	    air a worm runs into stays cave air (the junction with the deep caves). Nothing below
	    Config.Caves.MinY.
	  * Columns whose surface is at or below sea level + 2 are never carved, and a step that may
	    reach below sea level + 1 (or lies in a river valley) is only carved when every column
	    within its radius + DRY_MARGIN blocks (+ RIVER_MARGIN in river valleys), sampled on a
	    LATTICE block grid, is above that: the worm stops there (no chamber), and one stopped
	    (by water, or an entrance out of the ground) within MIN_*_STEPS carved steps is dropped.
	    So no surface cave touches water, as Minecraft's carvers skip water (only water narrower
	    than the LATTICE could slip between the samples; none was found in real terrain). Worms
	    only start on dry land (above START_ABOVE) outside river beds (RIVER_START).
	  * `protected` columns (around library structure pieces, see TerrainGenerator) are left alone.
	  * An entrance step that reaches a column's top block, or leaves it a roof of THIN_ROOF
	    blocks (on a slope, left floating), carves the column up to its top. A single block of rock
	    left between carved air and cave air (where an entrance meets a cave) is cleared, in full
	    detail chunks and off the core's edge columns (the neighbours' padding stays their core).
	  * Where a worm carves a column's top block and that was grass, dry grass, podzol, mycelium
	    or snow, the dirt it uncovers below becomes that block again (Minecraft's carver does the
	    same for grass; snow stands in for its freezing pass).

	Levels. `carve` takes the chunk's level: LOD chunks point-sample like Structures/Writer (a cell
	is carved when its sample block is), so far ravines show as cuts, but of an entrance only the
	steps that open a column (the pits and mouths): its tunnels under an intact roof can't be seen
	from far away and would only cost parts. TerrainGenerator carves up to MAX_LEVEL;
	`lowestCarved` tells its seam limits where a coarser or a finer node's cut begins, from the
	worms alone (`mayCarve` first, without the column's height).

	`carvesTop(x, z)` answers, from the worms alone (never from chunk data), whether a surface cave
	may carve the top block of column (x, z) or one within ~1.5 blocks of it: trees are refused
	there, so every chunk and level agrees on every tree (and TerrainGenerator's findSpawn skips
	such columns). It keeps the worms near its last TILES tiles of TILE x TILE blocks, so a tree
	spot costs some 10-30 microseconds once the worms around are built.
]]

local Config = require(script.Parent.Parent.Config)
local Blocks = require(script.Parent.Parent.Blocks)
local ChunkLayout = require(script.Parent.Parent.World.ChunkLayout)
local Hash = require(script.Parent.Parent.Util.Hash)

local SIZE = ChunkLayout.SIZE
local P = ChunkLayout.PADDED
local LAYER = ChunkLayout.LAYER
local STRIDE = LAYER * 2
local SEA = Config.SeaLevel
local MIN_Y = Config.Caves.MinY

-- Tuning --------------------------------------------------------------------------------------------
local WET = SEA + 2 -- columns at or below this surface height are never carved
local START_ABOVE = SEA + 4 -- a worm starts only on a column above this
local RIVER_START = 0.3 -- ... and with a river strength below this (Relief: the valley's inner part)
local DRY_MARGIN = 3 -- blocks around a low step that must be dry land
local RIVER_MARGIN = 3 -- extra margin inside river valleys
local LATTICE = 4 -- spacing of the surface samples of that check (blocks)
local MOUTH_SLOPE = 0.6 -- surface slope (blocks per block) from which an entrance starts as a mouth
local KNOT = 12 -- steps between the radius knots of an entrance
local LEVEL_OFF = 8 -- an entrance levels off over this many blocks above its target depth
-- Past its first OPENING steps, an entrance whose centre is less than its vertical radius + COVER
-- below the surface dives at DIVE radians or more.
local OPENING = 6
local COVER = 2
local DIVE = 0.7
-- An entrance ends where its top has been open for more than REOPEN steps after it had been under
-- the ground (it came out of a slope), or when it is not under the ground by step MAX_OPENING.
local REOPEN = 4
local MAX_OPENING = 16
local END_DEPTH = 8 -- depth of a ravine at its ends (blocks)
local ROUND = 5 -- a ravine's floor is rounded over at most this many blocks
local TREE_MARGIN = 1.5 -- carvesTop also answers for columns this far from a carved top
local THIN_ROOF = 1 -- an entrance step leaving a column a roof this thin (blocks) carves it too
-- A worm that water stops within this many carved steps is dropped (no stubs by the shore).
local MIN_ENTRANCE_STEPS = 16
local MIN_RAVINE_STEPS = 30
-- Steering towards the cave regions (Caves.regions): every STEER_EVERY steps a tunnel not yet in
-- a full strength region (STEER_FULL) compares the regions STEER_AHEAD blocks ahead to either
-- side (STEER_ANGLE) and turns towards the better one (yaw impulse STEER_TURN).
local STEER_EVERY = 4
local STEER_FULL = 0.5
local STEER_AHEAD = 16
local STEER_ANGLE = 0.7
local STEER_TURN = 1.5

-- Highest LOD level carved (point-sampled).
local MAX_LEVEL = 2

local ENTRANCE, RAVINE = 1, 2
local TAU = 2 * math.pi
local PI = math.pi

local floor, ceil, sqrt, sin, cos, atan2 = math.floor, math.ceil, math.sqrt, math.sin, math.cos, math.atan2
local min, max, huge = math.min, math.max, math.huge
local readu16, writeu16, readu8 = buffer.readu16, buffer.writeu16, buffer.readu8

local AIR, CAVE_AIR = Blocks.AIR, Blocks.CAVE_AIR
local DIRT = Blocks.id.Dirt
-- What a worm may carve: opaque rock and soil, never bedrock (nor water, ice or cave air).
local CARVABLE = buffer.create(Blocks.count)
for id = 0, Blocks.count - 1 do
	if Blocks.isOpaque(id) and id ~= Blocks.id.Bedrock then
		buffer.writeu8(CARVABLE, id, 1)
	end
end
-- Tops that grow back on the dirt a carved top uncovers.
local GRASSY: { [number]: boolean } = {
	[Blocks.id.Grass] = true,
	[Blocks.id.DryGrass] = true,
	[Blocks.id.Podzol] = true,
	[Blocks.id.Mycelium] = true,
	[Blocks.id.Snow] = true,
}

local function smoothstep01(t: number): number
	if t <= 0 then
		return 0
	elseif t >= 1 then
		return 1
	end
	return t * t * (3 - 2 * t)
end

-- (x, z) -> full detail surface height (first air block, whole blocks) and river strength (Relief).
export type SurfaceSampler = (x: number, z: number) -> (number, number)
-- (x, y, z) -> the cave regions' gate (Caves.regions): no caves below 0, full strength from 0.5.
export type RegionSampler = (x: number, y: number, z: number) -> number

--[[
	A worm: the steps it carves, as flat arrays. Entrance steps are ellipsoids centred at (x, y, z)
	with horizontal radius `h`, vertical radius `v`, cut below `floor` (in units of `v`). Ravine
	steps are columns of cells within `h` of (x, z), from the floor `y` up to each column's top,
	rounded over the lowest `v` blocks, with the width factor `widths[y - widthY + 1]` per block of
	height (clamped to the array). Bounds cover every block a step may carve (ravines: up to
	`maxY`, the highest surface along them plus the slope allowance).
]]
export type Worm = {
	kind: string, -- "entrance" / "ravine"
	cellX: number,
	cellZ: number,
	startX: number,
	startY: number,
	startZ: number,
	mouth: boolean, -- an entrance that starts heading into a slope
	branched: boolean,
	count: number,
	x: { number },
	y: { number },
	z: { number },
	h: { number },
	v: { number },
	floor: { number },
	widths: { number },
	widthY: number,
	minX: number,
	maxX: number,
	minY: number,
	maxY: number,
	minZ: number,
	maxZ: number,
}

export type SurfaceCaves = {
	--[[
		Carves every worm reaching the padded chunk (`level`, core origin `originX`, `originZ`)
		into `data`. `heights` / `topCells`: per padded column (index pz * PADDED + px + 1), its
		surface height and top cell, as `generate` filled them; `cells`: the buffer's height;
		`protected`: columns to leave alone (nil: none); `yield` is called after each worm built
		(a few in the first chunks of an area). Returns the lowest cell carved (math.huge: none),
		for the chunk's solidBelow.
	]]
	carve: (
		data: buffer,
		level: number,
		originX: number,
		originZ: number,
		heights: { number },
		topCells: { number },
		cells: number,
		protected: { boolean }?,
		yield: (() -> ())?
	) -> number,
	-- May a surface cave carve the top block of column (x, z), or of a column ~1.5 blocks away?
	-- From the worms alone (trees, spawns).
	carvesTop: (x: number, z: number) -> boolean,
	--[[
		The lowest cell `carve` carves in a column of a `level` chunk whose sample block is (x, z),
		whose surface height (at that level) is `height` and top cell `topCell` (a core column's,
		not lowered), when the column is not protected; nil when none (`ravinesOnly`: of the
		ravines). Where a coarser or a finer node's terrain ends (TerrainGenerator's seam limits),
		from the worms alone. Leaves out the remnant pass (single blocks, full detail only).
	]]
	lowestCarved: (
		level: number,
		x: number,
		z: number,
		height: number,
		topCell: number,
		ravinesOnly: boolean?
	) -> number?,
	-- May any worm (`ravinesOnly`: any ravine) carve column (x, z) at all? From the worms' steps
	-- alone, without the column's height: false means `lowestCarved` is nil there at every level.
	mayCarve: (x: number, z: number, ravinesOnly: boolean?) -> boolean,
	-- Every worm with a step in the block rectangle (inclusive): tests and measurements.
	worms: (minX: number, minZ: number, maxX: number, maxZ: number) -> { Worm },
	-- Worms built (not served from the cache) so far.
	built: () -> number,
	--[[
		/locate (Generation/Locate): the start column of grid cell (gx, gz)'s candidate of `kind`
		("entrance" or "ravine"; x nil: none, or the kind is off), a hash only, never cached; and
		the cell's worm (built and cached as the chunks would; nil: the candidate made none),
		`yield` called after a build.
	]]
	start: (kind: string, gx: number, gz: number) -> (number?, number),
	wormOf: (kind: string, gx: number, gz: number, yield: (() -> ())?) -> Worm?,
}

local SurfaceCaves = {}

SurfaceCaves.MAX_LEVEL = MAX_LEVEL
-- Grid cells kept per generator (per kind): whether each has a candidate, and its worm once built.
SurfaceCaves.CACHE_ENTRANCES = 384
SurfaceCaves.CACHE_RAVINES = 48
-- carvesTop keeps the worms near its last TILES tiles of TILE x TILE blocks.
local TILE = 32
local TILES = 16

-- Furthest any block of a worm can be from its start (blocks), its tree margin included: the
-- steps are a block long, then the radius (an entrance's end chamber: up to 1.3 x the largest).
local function entranceReach(): number
	local e = Config.Caves.Entrances
	return e.Length[2] + 2 + e.Radius[2] * 1.3 + TREE_MARGIN + 1
end
local function ravineReach(): number
	local r = Config.Caves.Ravines
	return r.Length[2] + r.Radius[2] + TREE_MARGIN + 1
end
SurfaceCaves.entranceReach = entranceReach
SurfaceCaves.ravineReach = ravineReach

--[[
	A grid cell of one kind as far as it was looked at: whether it has a candidate (`start`) and
	where, and once a chunk within reach needed it, its worm (`built`; nil: the candidate made
	none). Kept in a small LRU, so most lookups are a table index.
]]
type Cell = {
	used: number,
	start: boolean,
	x: number,
	z: number,
	built: boolean,
	worm: Worm?,
}

type Cache = {
	cells: { [number]: Cell },
	count: number,
	clock: number,
	capacity: number,
}

local function newCache(capacity: number): Cache
	return { cells = {}, count = 0, clock = 0, capacity = capacity }
end

local function cacheInsert(cache: Cache, key: number, cell: Cell)
	if cache.count >= cache.capacity then
		local oldest, oldestKey = huge, nil
		for k, c in cache.cells do
			if c.used < oldest then
				oldest, oldestKey = c.used, k
			end
		end
		if oldestKey then
			cache.cells[oldestKey] = nil
			cache.count -= 1
		end
	end
	cache.cells[key] = cell
	cache.count += 1
end

local function cellKey(gx: number, gz: number): number
	return gx * 2097152 + gz
end

-- Steps under construction.
type Builder = {
	x: { number },
	y: { number },
	z: { number },
	h: { number },
	v: { number },
	floor: { number },
	count: number,
}

local function newBuilder(): Builder
	return { x = {}, y = {}, z = {}, h = {}, v = {}, floor = {}, count = 0 }
end

local function push(b: Builder, x: number, y: number, z: number, h: number, v: number, f: number)
	local n = b.count + 1
	b.count = n
	b.x[n], b.y[n], b.z[n], b.h[n], b.v[n], b.floor[n] = x, y, z, h, v, f
end

-- `regions`: the deep caves' regions, which entrances steer towards (nil: no steering).
function SurfaceCaves.new(seed: number, surfaceAt: SurfaceSampler, regions: RegionSampler?): SurfaceCaves
	local entranceCfg = Config.Caves.Entrances
	local ravineCfg = Config.Caves.Ravines
	local entranceSalt = Hash.hash2(seed, Hash.string("surfacecaves.entrance"), 0x5C1)
	local ravineSalt = Hash.hash2(seed, Hash.string("surfacecaves.ravine"), 0x5C2)
	local entranceCache = newCache(SurfaceCaves.CACHE_ENTRANCES)
	local ravineCache = newCache(SurfaceCaves.CACHE_RAVINES)
	local builtCount = 0
	local ENTRANCE_REACH = entranceReach()
	local RAVINE_REACH = ravineReach()

	-- Surface heights and river strengths on a LATTICE grid, per worm being built: the dry land
	-- check, and (interpolated) the surface along the worm, at a fraction of the samples.
	local lattice: { [number]: number } = {}
	local latticeRiver: { [number]: number } = {}

	local function latticeHeight(lx: number, lz: number): number
		local key = lx * 2097152 + lz
		local h = lattice[key]
		if h == nil then
			local river
			h, river = surfaceAt(lx * LATTICE, lz * LATTICE)
			lattice[key], latticeRiver[key] = h, river
		end
		return h
	end

	local function clearLattice()
		table.clear(lattice)
		table.clear(latticeRiver)
	end

	-- The surface height and river strength at (x, z), bilinear between lattice points.
	local function surfaceNear(x: number, z: number): (number, number)
		local u, v = x / LATTICE, z / LATTICE
		local lx, lz = floor(u), floor(v)
		local fx, fz = u - lx, v - lz
		local h00, h10 = latticeHeight(lx, lz), latticeHeight(lx + 1, lz)
		local h01, h11 = latticeHeight(lx, lz + 1), latticeHeight(lx + 1, lz + 1)
		local k = lx * 2097152 + lz
		local r00, r10 = latticeRiver[k], latticeRiver[k + 2097152]
		local r01, r11 = latticeRiver[k + 1], latticeRiver[k + 2097153]
		local h0, h1 = h00 + (h10 - h00) * fx, h01 + (h11 - h01) * fx
		local r0, r1 = r00 + (r10 - r00) * fx, r01 + (r11 - r01) * fx
		return h0 + (h1 - h0) * fz, r0 + (r1 - r0) * fz
	end

	--[[
		May a step whose lowest block is `bottom`, centred over (x, z) with radius `r`, be carved?
		Only steps that may reach below sea level + 1, or lie in a river valley, can come near
		water: those need dry land (above WET) all around.
	]]
	local function dry(x: number, z: number, r: number, bottom: number, river: number): boolean
		if bottom > SEA + 1 and river <= 0 then
			return true
		end
		local m = r + DRY_MARGIN + (if river > 0 then RIVER_MARGIN else 0) + LATTICE / 2
		for lz = floor((z - m) / LATTICE), ceil((z + m) / LATTICE) do
			for lx = floor((x - m) / LATTICE), ceil((x + m) / LATTICE) do
				if latticeHeight(lx, lz) <= WET then
					return false
				end
			end
		end
		return true
	end

	local function finish(kind: string, gx: number, gz: number, b: Builder, sx: number, sy: number, sz: number): Worm?
		if b.count == 0 then
			return nil
		end
		local worm: Worm = {
			kind = kind,
			cellX = gx,
			cellZ = gz,
			startX = sx,
			startY = sy,
			startZ = sz,
			mouth = false,
			branched = false,
			count = b.count,
			x = b.x,
			y = b.y,
			z = b.z,
			h = b.h,
			v = b.v,
			floor = b.floor,
			widths = {},
			widthY = 0,
			minX = huge,
			maxX = -huge,
			minY = huge,
			maxY = -huge,
			minZ = huge,
			maxZ = -huge,
		}
		for s = 1, b.count do
			local r = b.h[s] + TREE_MARGIN
			worm.minX = min(worm.minX, b.x[s] - r)
			worm.maxX = max(worm.maxX, b.x[s] + r)
			worm.minZ = min(worm.minZ, b.z[s] - r)
			worm.maxZ = max(worm.maxZ, b.z[s] + r)
			if kind == "entrance" then
				worm.minY = min(worm.minY, b.y[s] - b.v[s])
				worm.maxY = max(worm.maxY, b.y[s] + b.v[s])
			else
				worm.minY = min(worm.minY, b.y[s])
			end
		end
		return worm
	end

	--[[ Entrances ]]

	--[[
		One tunnel of an entrance (the main one or its branch), appended to `b`. Walks `steps`
		steps from (x, y, z); returns whether it went the whole way (false: stopped short of water,
		or ended out of the ground), its last position and heading, and its state at step `forkAt`
		(nil when it didn't get there).
	]]
	local function tunnel(
		b: Builder,
		rng: Hash.Rng,
		x: number,
		y: number,
		z: number,
		yaw: number,
		pitch: number,
		descend: number,
		steps: number,
		depth: number,
		rLow: number,
		rHigh: number,
		vScale: number,
		floorLevel: number,
		forkAt: number
	): (boolean, number, number, number, number, number, { number }?)
		local knots: { number } = {}
		for k = 1, steps // KNOT + 2 do
			knots[k] = rng:float()
		end
		local fork: { number }? = nil
		local dYaw, dPitch = 0, 0
		-- Whether the tunnel has been under the ground yet, for how many steps its top has been
		-- open again since, and whether it skipped its last step.
		local covered, reopened, skipped = false, 0, false
		for j = 0, steps - 1 do
			if j > 0 then
				local cp = cos(pitch)
				x += cos(yaw) * cp
				y += sin(pitch)
				z += sin(yaw) * cp
			end
			local surface, river = surfaceNear(x, z)
			local k = j / KNOT
			local k0 = floor(k)
			local a = knots[k0 + 1]
			local radius = rLow + (rHigh - rLow) * (a + (knots[k0 + 2] - a) * smoothstep01(k - k0))
			local vr = radius * vScale
			-- Down at `descend` until LEVEL_OFF blocks above the target depth, then level.
			local cover = surface - y
			local target = descend * smoothstep01((depth - cover) / LEVEL_OFF)
			local lift = dPitch
			if cover >= vr then
				covered, reopened = true, 0
			elseif covered then
				reopened += 1
			end
			if j >= OPENING then
				-- Past its opening a tunnel goes into the ground. One that never got under it, or
				-- came out of it again for REOPEN steps (the ground falls away as fast as it can
				-- dive), ends there; one still close to the surface dives, its wander only ever
				-- pushing it down. So no long ditches.
				if reopened > REOPEN or (not covered and j >= MAX_OPENING) then
					return false, x, y, z, yaw, pitch, fork
				end
				-- (Under the lowest of the surface around it: along a slope, the downhill side.)
				local low = min(
					surface,
					(surfaceNear(x - radius, z)),
					(surfaceNear(x + radius, z)),
					(surfaceNear(x, z - radius)),
					(surfaceNear(x, z + radius))
				)
				if low - y < vr + COVER then
					target = min(target, -DIVE)
					lift = min(lift, 0)
				end
			end
			pitch = target + (pitch - target) * 0.7 + lift * 0.1
			yaw += dYaw * 0.1
			dPitch = dPitch * 0.9 + (rng:float() - rng:float()) * rng:float() * 2
			dYaw = dYaw * 0.75 + (rng:float() - rng:float()) * rng:float() * 4
			-- Towards the cave regions, until in one.
			if regions and j % STEER_EVERY == 0 and regions(x, y, z) < STEER_FULL then
				local plus =
					regions(x + cos(yaw + STEER_ANGLE) * STEER_AHEAD, y, z + sin(yaw + STEER_ANGLE) * STEER_AHEAD)
				local minus =
					regions(x + cos(yaw - STEER_ANGLE) * STEER_AHEAD, y, z + sin(yaw - STEER_ANGLE) * STEER_AHEAD)
				dYaw += if plus > minus then STEER_TURN else -STEER_TURN
			end
			-- Minecraft skips a quarter of the steps; never two in a row here, or a thin, steep
			-- tunnel is pinched shut.
			local skip = rng:int(0, 3) == 0 and not skipped

			if y - vr < MIN_Y + 1 then
				y = MIN_Y + 1 + vr
				if pitch < 0 then
					pitch = 0
				end
			end
			if not dry(x, z, radius, y - vr, river) then
				return false, x, y, z, yaw, pitch, fork
			end
			if j == forkAt then
				fork = { x, y, z, yaw, pitch }
			end
			skipped = j > 0 and skip
			if not skipped then
				push(b, x, y, z, radius, vr, floorLevel)
			end
		end
		return true, x, y, z, yaw, pitch, fork
	end

	-- The end chamber of a tunnel just past (x, y, z) (heading yaw / pitch), if it is dry.
	local function chamber(b: Builder, x: number, y: number, z: number, yaw: number, pitch: number, radius: number)
		local cp = cos(pitch)
		x += cos(yaw) * cp
		y += sin(pitch) * 0.5
		z += sin(yaw) * cp
		local vr = radius * 0.75
		if y - vr < MIN_Y + 1 then
			y = MIN_Y + 1 + vr
		end
		local _, river = surfaceNear(x, z)
		if dry(x, z, radius, y - vr, river) then
			push(b, x, y, z, radius, vr, -0.6)
		end
	end

	local function buildEntrance(gx: number, gz: number, rng: Hash.Rng, sx: number, sz: number): Worm?
		local e = entranceCfg
		-- Every draw that shapes the worm first, so none of them depends on the terrain.
		local length = rng:int(e.Length[1], e.Length[2])
		local depth = rng:int(e.Depth[1], e.Depth[2])
		local rLow, rHigh = e.Radius[1], e.Radius[2]
		local vScale = 0.85 + rng:float() * 0.3
		local floorLevel = -0.85 + rng:float() * 0.35
		local yaw = rng:float() * TAU
		local slopeDown = 0.45 + rng:float() * 0.35
		local mouthJitter = (rng:float() - 0.5) * 1.0
		local mouthPitch = 0.05 + rng:float() * 0.15
		local branch = rng:float() < e.Branch
		local forkAt = floor(length * (0.3 + rng:float() * 0.3))
		local side = if rng:float() < 0.5 then -1 else 1
		local branchLength = min(rng:int(16, 40), length - forkAt)
		local chamberRadius = rHigh * (0.8 + rng:float() * 0.5)
		local walkSeed = rng:next()
		local branchSeed = rng:next()

		local x, z = sx + 0.5, sz + 0.5
		local h, river = surfaceAt(x, z)
		if h <= START_ABOVE or river >= RIVER_START then
			return nil
		end
		-- The surface's slope at the start (over 8 blocks).
		local gradX = ((surfaceAt(x + 4, z)) - (surfaceAt(x - 4, z))) / 8
		local gradZ = ((surfaceAt(x, z + 4)) - (surfaceAt(x, z - 4))) / 8
		local mouth = gradX * gradX + gradZ * gradZ >= MOUTH_SLOPE * MOUTH_SLOPE
		local y, pitch, descend
		if mouth then
			-- Into the slope, nearly level, the floor at the start column's surface.
			yaw = atan2(gradZ, gradX) + mouthJitter
			pitch = -mouthPitch
			descend = -0.25
			y = h - 0.5 - floorLevel * rLow * vScale
		else
			-- Down from the surface: a pit, heading (of four right angles) for the cave region
			-- around where it reaches its depth.
			pitch = -slopeDown
			descend = -slopeDown
			y = h
			if regions then
				local reach = depth / math.tan(slopeDown) + 8
				local best, heading = -huge, yaw
				for k = 0, 3 do
					local a = heading + k * PI / 2
					local value = regions(x + cos(a) * reach, h - depth, z + sin(a) * reach)
					if value > best then
						best, yaw = value, a
					end
				end
			end
		end

		clearLattice()
		local b = newBuilder()
		local whole, ex, ey, ez, eyaw, epitch, fork = tunnel(
			b,
			Hash.rng(walkSeed),
			x,
			y,
			z,
			yaw,
			pitch,
			descend,
			length,
			depth,
			rLow,
			rHigh,
			vScale,
			floorLevel,
			if branch then forkAt else -1
		)
		if whole then
			chamber(b, ex, ey, ez, eyaw, epitch, chamberRadius)
		elseif b.count < MIN_ENTRANCE_STEPS then
			clearLattice()
			return nil
		end
		local branched = false
		if fork and branchLength > 0 then
			-- Sideways, thinner and a little deeper (Minecraft's branches turn by a right angle and
			-- take a third of the pitch).
			local brng = Hash.rng(branchSeed)
			local turn = side * (PI / 2 + (brng:float() - 0.5) * 0.6)
			local before = b.count
			local bWhole, bx, by, bz, byaw, bpitch = tunnel(
				b,
				brng,
				fork[1],
				fork[2],
				fork[3],
				fork[4] + turn,
				fork[5] / 3,
				descend,
				branchLength,
				depth + brng:int(0, 10),
				rLow,
				rLow + (rHigh - rLow) * 0.6,
				vScale,
				floorLevel,
				-1
			)
			if bWhole then
				chamber(b, bx, by, bz, byaw, bpitch, chamberRadius * 0.75)
			end
			branched = b.count > before
		end
		clearLattice()
		local worm = finish("entrance", gx, gz, b, x, y, z)
		if worm then
			worm.mouth = mouth
			worm.branched = branched
		end
		return worm
	end

	--[[ Ravines ]]

	local function buildRavine(gx: number, gz: number, rng: Hash.Rng, sx: number, sz: number): Worm?
		local r = ravineCfg
		local length = rng:int(r.Length[1], r.Length[2])
		local rEnd, rMiddle = r.Radius[1], r.Radius[2]
		local thickness = (rMiddle - rEnd) * (0.5 + 0.5 * rng:float())
		local depthMax = rng:int(r.Depth[1], r.Depth[2])
		local yaw = rng:float() * TAU
		local walkSeed = rng:next()
		local widthSeed = rng:next()

		local x, z = sx + 0.5, sz + 0.5
		local h, river = surfaceAt(x, z)
		if h <= START_ABOVE or river >= RIVER_START then
			return nil
		end

		clearLattice()
		local b = newBuilder()
		local walk = Hash.rng(walkSeed)
		local ref = h
		local dYaw = 0
		local highest = h
		for i = 0, length - 1 do
			if i > 0 then
				x += cos(yaw)
				z += sin(yaw)
			end
			yaw += dYaw * 0.05
			dYaw = dYaw * 0.5 + (walk:float() - walk:float()) * walk:float() * 4
			local skip = walk:int(0, 3) == 0
			local factor = 0.75 + 0.25 * walk:float()
			local surface, rv = surfaceNear(x, z)
			-- A moving average of the surface along the cut: a smooth floor.
			ref += (surface - ref) * 0.25
			local s = sin(PI * i / length)
			local half = (rEnd + s * thickness) * factor
			local depth = END_DEPTH + (depthMax - END_DEPTH) * s
			local floorY = max(min(ref, surface) - depth, MIN_Y + 1)
			if not dry(x, z, half, floorY, rv) then
				if b.count < MIN_RAVINE_STEPS then
					clearLattice()
					return nil
				end
				break
			end
			if i == 0 or not skip then
				push(b, x, floorY, z, half, min(half * 1.5, depth * 0.4, ROUND), 0)
				-- Columns across the cut may stand higher than its centre line (slopes).
				highest = max(highest, surface + half * 3)
			end
		end
		clearLattice()
		local worm = finish("ravine", gx, gz, b, sx + 0.5, h, sz + 0.5)
		if worm == nil then
			return nil
		end
		-- Minecraft's width factor per block of height: (1 + r1 r2)^2, redrawn on a third of the
		-- levels, from the floor to above the highest column top it may reach.
		local wrng = Hash.rng(widthSeed)
		local y0 = floor(worm.minY) - 1
		local y1 = ceil(highest) + 1
		local f = 1
		for y = y0, y1 do
			if y == y0 or wrng:int(0, 2) == 0 then
				f = 1 + wrng:float() * wrng:float()
			end
			worm.widths[y - y0 + 1] = f * f
		end
		worm.widthY = y0
		worm.maxY = y1
		return worm
	end

	--[[ Lookup ]]

	-- The candidate of grid cell (gx, gz) of `kind`: its random stream after the start's draws,
	-- whether it has one, and its start column.
	local function candidate(kind: number, gx: number, gz: number): (Hash.Rng, boolean, number, number)
		local cfg = if kind == ENTRANCE then entranceCfg else ravineCfg
		local spacing = cfg.Spacing
		local rng = Hash.rng(Hash.hash3(if kind == ENTRANCE then entranceSalt else ravineSalt, gx, 0, gz))
		if rng:float() >= cfg.Chance then
			return rng, false, 0, 0
		end
		local sx = gx * spacing + rng:int(0, spacing - 1)
		local sz = gz * spacing + rng:int(0, spacing - 1)
		return rng, true, sx, sz
	end

	-- The worm of grid cell (gx, gz) of `kind` if its start is within reach of the rectangle.
	local function wormAt(
		kind: number,
		gx: number,
		gz: number,
		minX: number,
		minZ: number,
		maxX: number,
		maxZ: number
	): Worm?
		local cache = if kind == ENTRANCE then entranceCache else ravineCache
		local key = cellKey(gx, gz)
		local cell = cache.cells[key]
		if cell == nil then
			local _, start, sx, sz = candidate(kind, gx, gz)
			cell = { used = 0, start = start, x = sx, z = sz, built = false, worm = nil }
			cacheInsert(cache, key, cell)
		end
		assert(cell)
		cache.clock += 1
		cell.used = cache.clock
		if not cell.start then
			return nil
		elseif cell.built then
			return cell.worm
		end
		local sx, sz = cell.x, cell.z
		local reach = if kind == ENTRANCE then ENTRANCE_REACH else RAVINE_REACH
		if sx + reach < minX or sx - reach > maxX or sz + reach < minZ or sz - reach > maxZ then
			return nil
		end
		local rng = candidate(kind, gx, gz)
		builtCount += 1
		local worm = if kind == ENTRANCE then buildEntrance(gx, gz, rng, sx, sz) else buildRavine(gx, gz, rng, sx, sz)
		cell.built, cell.worm = true, worm
		return worm
	end

	-- Appends to `list` every worm of an enabled kind (from `firstKind` on: RAVINE for ravines
	-- only) whose bounds touch the block rectangle. `yield` is called after each worm built.
	local function collect(
		minX: number,
		minZ: number,
		maxX: number,
		maxZ: number,
		list: { Worm },
		yield: (() -> ())?,
		firstKind: number?
	)
		for kind = firstKind or ENTRANCE, RAVINE do
			local cfg = if kind == ENTRANCE then entranceCfg else ravineCfg
			if cfg.Enabled then
				local spacing = cfg.Spacing
				local reach = if kind == ENTRANCE then ENTRANCE_REACH else RAVINE_REACH
				for gz = floor((minZ - reach) / spacing), floor((maxZ + reach) / spacing) do
					for gx = floor((minX - reach) / spacing), floor((maxX + reach) / spacing) do
						local before = builtCount
						local worm = wormAt(kind, gx, gz, minX, minZ, maxX, maxZ)
						if yield and builtCount > before then
							yield()
						end
						if
							worm
							and worm.maxX >= minX
							and worm.minX <= maxX + 1
							and worm.maxZ >= minZ
							and worm.minZ <= maxZ + 1
						then
							table.insert(list, worm)
						end
					end
				end
			end
		end
	end

	--[[ Carving ]]

	-- Per padded column: its top block before a worm carved it (0: untouched), and the touched list.
	local topWas: { number } = table.create(P * P, 0)
	local touched: { number } = {}
	local chunkWorms: { Worm } = {}
	-- Byte offsets of the core cells carved in a full detail chunk (for the remnant pass).
	local carvedCells: { number } = {}
	local NEIGHBOURS = { 2, -2, P * 2, -P * 2, STRIDE, -STRIDE }

	-- Is the cell at byte offset `o` surrounded by air and cave air on all six sides?
	local function isolated(data: buffer, o: number): boolean
		for _, d in NEIGHBOURS do
			local id = readu16(data, o + d)
			if id ~= AIR and id ~= CAVE_AIR then
				return false
			end
		end
		return true
	end

	local function carve(
		data: buffer,
		level: number,
		originX: number,
		originZ: number,
		heights: { number },
		topCells: { number },
		cells: number,
		protected: { boolean }?,
		yield: (() -> ())?
	): number
		local step, stepY = ChunkLayout.steps(level)
		local half, halfY = step // 2, stepY // 2
		local span = SIZE * step
		-- The padded box (blocks) and the sample block of padded column 0.
		local x0, z0 = originX - step, originZ - step
		local x1, z1 = originX + span + step - 1, originZ + span + step - 1
		local baseX, baseZ = x0 + half, z0 + half
		local minCell = max(ceil((MIN_Y - halfY) / stepY), 1)
		local lowest = huge
		local touchedCount, carvedCount = 0, 0

		table.clear(chunkWorms)
		collect(x0, z0, x1, z1, chunkWorms, yield)
		for _, worm in chunkWorms do
			local xs, ys, zs, hs, vs, fs = worm.x, worm.y, worm.z, worm.h, worm.v, worm.floor
			local ravine = worm.kind == "ravine"
			local widths, widthY, widthCount = worm.widths, worm.widthY, #worm.widths
			for s = 1, worm.count do
				local cx, cy, cz, hr = xs[s], ys[s], zs[s], hs[s]
				if cx + hr < x0 or cx - hr > x1 + 1 or cz + hr < z0 or cz - hr > z1 + 1 then
					continue
				end
				-- Padded columns whose sample block's centre is within hr of the centre.
				local px0 = max(floor((cx - hr - 0.5 - baseX) / step) + 1, 0)
				local px1 = min(ceil((cx + hr - 0.5 - baseX) / step) - 1, P - 1)
				local pz0 = max(floor((cz - hr - 0.5 - baseZ) / step) + 1, 0)
				local pz1 = min(ceil((cz + hr - 0.5 - baseZ) / step) - 1, P - 1)
				local inv = 1 / hr
				local vr, fl = vs[s], fs[s]
				-- Ravines: cells from the floor up (cy is the floor).
				local floorCell = if ravine then max(ceil((floor(cy - 0.5) + 1 - halfY) / stepY), minCell) else 0
				for pz = pz0, pz1 do
					local dz = (baseZ + pz * step + 0.5 - cz) * inv
					local dz2 = dz * dz
					for px = px0, px1 do
						local dx = (baseX + px * step + 0.5 - cx) * inv
						local d2 = dx * dx + dz2
						if d2 >= 1 then
							continue
						end
						local i = pz * P + px + 1
						if heights[i] <= WET or (protected and protected[i]) then
							continue
						end
						local topCell = topCells[i]
						local base = (pz * P + px) * 2
						local c0, c1
						if ravine then
							c0, c1 = floorCell, min(topCell, cells - 1)
						else
							-- Blocks whose centre is inside the ellipsoid and above its floor.
							local sq = sqrt(1 - d2)
							local lo = if -sq > fl then -sq else fl
							c0 = max(ceil((floor(cy + lo * vr - 0.5) + 1 - halfY) / stepY), minCell)
							-- A step that reaches the column's top block, or leaves it a roof of
							-- THIN_ROOF blocks (on a slope, left floating), opens the column up to its
							-- top. Far chunks only show such openings: the rest is buried.
							local topBlock = ceil(cy + sq * vr - 0.5) - 1
							if topBlock >= heights[i] - 1 - THIN_ROOF then
								c1 = min(topCell, cells - 1)
							elseif level > 0 then
								continue
							else
								c1 = min(floor((topBlock - halfY) / stepY), topCell, cells - 1)
							end
						end
						-- A ravine's column is cut from its lowest carved cell up (no overhangs, so
						-- no rim block is left floating on a slope).
						local through = false
						for c = c0, c1 do
							if ravine and not through then
								-- Rounded at the bottom over vr blocks, jagged by the width factor of
								-- each block of height.
								local by = c * stepY + halfY
								local u = by + 0.5 - cy
								local wi = by - widthY + 1
								local need = d2
									* widths[if wi < 1 then 1 elseif wi > widthCount then widthCount else wi]
								if u < vr then
									local t = u / vr
									need /= t * (2 - t)
								end
								if need >= 1 then
									continue
								end
								through = true
							end
							local o = base + c * STRIDE
							local id = readu16(data, o)
							if readu8(CARVABLE, id) == 1 then
								if c == topCell and topWas[i] == 0 then
									topWas[i] = id
									touchedCount += 1
									touched[touchedCount] = i
								end
								writeu16(data, o, AIR)
								if c < lowest then
									lowest = c
								end
								if level == 0 and px >= 1 and px <= SIZE and pz >= 1 and pz <= SIZE then
									carvedCount += 1
									carvedCells[carvedCount] = o
								end
							end
						end
					end
				end
			end
		end
		table.clear(chunkWorms)

		-- A single block of rock left between carved air and cave air (where an entrance meets a
		-- cave, or between two steps) would float: clear it. Only in core columns off the core's
		-- edge, whose six neighbours this chunk holds and which no neighbour has in its padding.
		for k = 1, carvedCount do
			local o = carvedCells[k]
			for _, d in NEIGHBOURS do
				local n = o + d
				local index = n // 2
				local y, column = index // LAYER, index % LAYER
				local px, pz = column % P, column // P
				if
					px >= 2
					and px < SIZE
					and pz >= 2
					and pz < SIZE
					and y >= 1
					and y < cells - 1
					and heights[column + 1] > WET
					and not (protected and protected[column + 1])
					and readu8(CARVABLE, readu16(data, n)) == 1
					and isolated(data, n)
				then
					writeu16(data, n, AIR)
					if y < lowest then
						lowest = y
					end
				end
			end
		end

		-- Grass grows back on the dirt a carved top uncovers.
		for k = 1, touchedCount do
			local i = touched[k]
			local top = topWas[i]
			topWas[i] = 0
			if GRASSY[top] then
				local base = (i - 1) * 2
				local y = topCells[i] - 1
				while y >= 1 and readu16(data, base + y * STRIDE) == AIR do
					y -= 1
				end
				if y >= 1 and readu16(data, base + y * STRIDE) == DIRT then
					writeu16(data, base + y * STRIDE, top)
				end
			end
		end
		return lowest
	end

	--[[ Trees and spawns ]]

	-- (x, z) -> the worms (of the kinds from `firstKind` on) whose bounds touch the TILE x TILE
	-- block tile of column (x, z), kept for the last TILES tiles asked for.
	local function tileCache(firstKind: number): (x: number, z: number) -> { Worm }
		local tileKeys: { number } = table.create(TILES, huge)
		local tileLists: { { Worm } } = {}
		for t = 1, TILES do
			tileLists[t] = {}
		end
		local tileNext = 1
		return function(x: number, z: number): { Worm }
			local tx, tz = x // TILE, z // TILE
			local key = cellKey(tx, tz)
			for t = 1, TILES do
				if tileKeys[t] == key then
					return tileLists[t]
				end
			end
			local list: { Worm } = {}
			collect(tx * TILE, tz * TILE, tx * TILE + TILE - 1, tz * TILE + TILE - 1, list, nil, firstKind)
			tileKeys[tileNext], tileLists[tileNext] = key, list
			tileNext = tileNext % TILES + 1
			return list
		end
	end
	local wormsNear = tileCache(ENTRANCE)
	-- (Far seams only look for ravines: no entrance worm is built for them.)
	local ravinesNear = tileCache(RAVINE)

	local function carvesTop(x: number, z: number): boolean
		local list = wormsNear(x, z)
		if #list == 0 then
			return false
		end
		local h: number? = nil
		local px, pz = x + 0.5, z + 0.5
		for _, worm in list do
			if px < worm.minX or px > worm.maxX or pz < worm.minZ or pz > worm.maxZ then
				continue
			end
			local surface = h
			if surface == nil then
				surface = (surfaceAt(x, z))
				h = surface
			end
			assert(surface)
			-- The top block (and a block either way, for neighbours of a similar height).
			local y = surface - 1
			if surface + 1 < worm.minY or y - 1 > worm.maxY then
				continue
			end
			local xs, ys, zs, hs, vs, fs = worm.x, worm.y, worm.z, worm.h, worm.v, worm.floor
			local ravine = worm.kind == "ravine"
			for s = 1, worm.count do
				local r = hs[s] + TREE_MARGIN
				local dx, dz = px - xs[s], pz - zs[s]
				local d2 = (dx * dx + dz * dz) / (r * r)
				if d2 >= 1 then
					continue
				end
				if ravine then
					-- A column is cut up from its lowest carved level, which may be the widest
					-- (width factors are at least 1): the full radius.
					if y + 1.5 > ys[s] then
						return true
					end
				else
					local sq = sqrt(1 - d2)
					local vr = vs[s]
					if (y - 0.5 - ys[s]) / vr < sq and (y + 1.5 - ys[s]) / vr > max(-sq, fs[s]) then
						return true
					end
				end
			end
		end
		return false
	end

	local function mayCarve(x: number, z: number, ravinesOnly: boolean?): boolean
		local px, pz = x + 0.5, z + 0.5
		for _, worm in (if ravinesOnly then ravinesNear else wormsNear)(x, z) do
			if px < worm.minX or px > worm.maxX or pz < worm.minZ or pz > worm.maxZ then
				continue
			end
			local xs, zs, hs = worm.x, worm.z, worm.h
			for s = 1, worm.count do
				local dx, dz, hr = px - xs[s], pz - zs[s], hs[s]
				if dx * dx + dz * dz < hr * hr then
					return true
				end
			end
		end
		return false
	end

	local function lowestCarved(
		level: number,
		x: number,
		z: number,
		height: number,
		topCell: number,
		ravinesOnly: boolean?
	): number?
		if height <= WET then
			return nil
		end
		local _, stepY = ChunkLayout.steps(level)
		local halfY = stepY // 2
		local minCell = max(ceil((MIN_Y - halfY) / stepY), 1)
		local best = huge
		local px, pz = x + 0.5, z + 0.5
		for _, worm in (if ravinesOnly then ravinesNear else wormsNear)(x, z) do
			if px < worm.minX or px > worm.maxX or pz < worm.minZ or pz > worm.maxZ then
				continue
			end
			local xs, ys, zs, hs, vs, fs = worm.x, worm.y, worm.z, worm.h, worm.v, worm.floor
			local ravine = worm.kind == "ravine"
			local widths, widthY, widthCount = worm.widths, worm.widthY, #worm.widths
			for s = 1, worm.count do
				local hr = hs[s]
				local dx, dz = (px - xs[s]) / hr, (pz - zs[s]) / hr
				local d2 = dx * dx + dz * dz
				if d2 >= 1 then
					continue
				end
				local cy, vr = ys[s], vs[s]
				if ravine then
					-- The first cell from the floor up that `carve` carves.
					for c = max(ceil((floor(cy - 0.5) + 1 - halfY) / stepY), minCell), min(topCell, best - 1) do
						local by = c * stepY + halfY
						local u = by + 0.5 - cy
						local wi = by - widthY + 1
						local need = d2 * widths[if wi < 1 then 1 elseif wi > widthCount then widthCount else wi]
						if u < vr then
							local t = u / vr
							need /= t * (2 - t)
						end
						if need < 1 then
							best = c
							break
						end
					end
				else
					local sq = sqrt(1 - d2)
					local lo = if -sq > fs[s] then -sq else fs[s]
					local c0 = max(ceil((floor(cy + lo * vr - 0.5) + 1 - halfY) / stepY), minCell)
					local topBlock = ceil(cy + sq * vr - 0.5) - 1
					local c1
					if topBlock >= height - 1 - THIN_ROOF then
						c1 = topCell
					elseif level > 0 then
						continue
					else
						c1 = min(floor((topBlock - halfY) / stepY), topCell)
					end
					if c0 <= c1 and c0 < best then
						best = c0
					end
				end
			end
		end
		return if best < huge then best else nil
	end

	local function worms(minX: number, minZ: number, maxX: number, maxZ: number): { Worm }
		local near: { Worm } = {}
		collect(minX, minZ, maxX, maxZ, near)
		local list: { Worm } = {}
		for _, worm in near do
			for s = 1, worm.count do
				local x, z = worm.x[s], worm.z[s]
				if x >= minX and x < maxX + 1 and z >= minZ and z < maxZ + 1 then
					table.insert(list, worm)
					break
				end
			end
		end
		return list
	end

	--[[ Locating ]]

	local function start(kind: string, gx: number, gz: number): (number?, number)
		local k = if kind == "entrance" then ENTRANCE else RAVINE
		if not (if k == ENTRANCE then entranceCfg else ravineCfg).Enabled then
			return nil, 0
		end
		local _, has, sx, sz = candidate(k, gx, gz)
		if not has then
			return nil, 0
		end
		return sx, sz
	end

	local function wormOf(kind: string, gx: number, gz: number, yield: (() -> ())?): Worm?
		local sx, sz = start(kind, gx, gz)
		if sx == nil then
			return nil
		end
		local before = builtCount
		local worm = wormAt(if kind == "entrance" then ENTRANCE else RAVINE, gx, gz, sx, sz, sx, sz)
		if yield and builtCount > before then
			yield()
		end
		return worm
	end

	return {
		carve = carve,
		carvesTop = carvesTop,
		lowestCarved = lowestCarved,
		mayCarve = mayCarve,
		worms = worms,
		built = function(): number
			return builtCount
		end,
		start = start,
		wormOf = wormOf,
	}
end

return SurfaceCaves
