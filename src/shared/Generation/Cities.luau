--!strict
--!native
--[[
	Overgrown cities and the roads between them (the zombie apocalypse's ruins), decided from the
	raw terrain only: the raw Relief (`raw`), the raw biome (`rawBiome`), the seed and Util/Hash,
	never the generator's `column` or `sample` (which read the wrapped relief this module makes:
	that would recurse). What stands in a city is Generation/CityLayout's; the roads' geometry is
	Generation/Roads'.

	  relief       the wrapped Relief: cities level their footprint (cut and fill to the
	               plateau's height, blended over Margin) and roads grade their corridor; `u` and
	               `s` stay raw, so biomes never shift. Untouched ground is a raw pass-through.
	  prepare      warms every cache `relief`, `surface` and the rest may need in a rectangle,
	               calling `yield` as it goes (Generation/TerrainGenerator's `generate` prepares
	               its padded chunk; the map and the spawn search prepare first too).
	  surface      the top block override of a column (asphalt, road lines, sidewalks, grass and
	               moss patches, potholes) and its filler, or nil for natural ground; overridden
	               columns skip the generator's steep rule.
	  blocked      x0, z0, x1, z1 boxes whose union covers every city footprint + Margin and every
	               candidate road corridor in a rectangle: where the wrapper or the surface may
	               differ from the raw terrain. Cheap and conservative (existence tests only, never
	               a road plan: the candidate links of the cells around, whose ends' existence alone
	               is tested; a cold call tests some 7-17 cells, 1.5 ms at most). Every planner
	               (lakes, wells, lava, mineshafts, outposts, surface caves, bunkers) keeps out of
	               it, so whatever they accept stands on ground the wrapper leaves alone; one that
	               may yield passes its `yield` (optional).
	  protects     exactly: a footprint + Margin, or a built road + Blend (no surface cave there).
	  treeAllowed  trees grow here (not on asphalt, sidewalks or building lots).
	  top          the first air above the highest building block a chunk's level-`level` node
	               at (originX, originZ) holds (the generator's `needed`), nil: none.
	  write        the buildings, streets' decay, overgrowth, cars and loot containers into a
	               padded chunk (levels 0..Config.Cities.LodLevels): the lowest cell written (huge:
	               none) and the first empty cell above.
	  container    a generated container's loot (Generation/ScavengeLoot), nil: none there.
	  poiBlocks    the containers in a rectangle whose blocks `lut` marks (x, y, z, block each).
	  locateKind   /locate structure city's kind (Generation/Locate).
	  cityAt       1 inside a city, 0 outside, between in its margin.
	  sites, roads every city site and road segment in a rectangle (the map's overlay).
	  bunkerSpots  x, y (the ground: first air), z of each bunker shed's hatch (Generation/Bunkers).
	  spawnShift   findSpawn's last step: from the raw spawn (x, z), a spawn 150-400 blocks
	               outside the margin of the nearest site within 3 km whose column passes `ok`;
	               (x, z) itself when there is no site or no candidate passes.
	  built        cells, sites, links and tiles built so far (not served from a cache).

	Where cities stand (Config.Cities). One candidate per Grid x Grid cell (1024): the cell's hash
	keeps it with Chance, then draws up to Tries (4) spots in turn, the first that fits standing:
	half = MinRadius // 32 + floor((MaxRadius // 32 - MinRadius // 32 + 1) u²) (1..7: most sites
	are small towns), R = 32 half + 3 (the footprint starts and ends on a street); its centre at
	Grid g + M0 + int(0, Grid - 2 M0), M0 = MaxRadius + Margin + 64, so a city and its margin never
	leave their cell and a column's city is its own cell's. (One spot at Chance 0.5 gave 4.5-7.5
	cities per 100 km² on seeds 1, 99 and 12345: the lattice refuses many spots.) A 5 x 5 lattice
	over the footprint (R / 2 apart) decides: a sample passes with |selector| in [0.22, 0.40)
	(hills or plains), a river under 0.05, a height of at least SeaLevel + MinAboveSea and a raw
	biome neither frozen nor of the mountains (Meadow and up, or none: mushroom isles); the city
	stands when Accept of the 25 pass and the passing heights span at most 1.5 MaxSlope. The
	selectors (cheap) go first, then each sample's height and biome in turn, the corners and the
	middle first; the test stops at the fifth failure, or as soon as the samples passing so far
	span more than the limit (a hill shows after a few heights). Its plan (Sites cache):
	the plateau H, the median of a 9 x 9 lattice of heights (at least SeaLevel + MinAboveSea), and
	its overgrowth o = Overgrowth x clamp((humidity + 0.8) / 1.4, 0.15, 1) of the centre's biome
	(every city is somewhat overgrown, the jungle's most).

	Roads (Config.Cities.Roads). A city links to the nearest city in each quarter (east, north,
	west, south, by the signs of dx + dz and dx - dz) within LinkCells x Grid; link(A, B) when B is
	A's choice or A is B's, its id the hash of the two cells. Its gates: the point of each
	footprint's side facing the other city nearest it, on a street's centre line (cx + 32 j), so
	the road goes on as that street; Generation/Roads makes the plan from the lower cell's gate.
	The corridor (Roads.corridor(), 59.5 blocks either side of the gates' line) bounds the road and
	its blend whatever the plan, so `blocked` and the tile classes need existence tests only (see
	Candidates below).

	The wrapper. A 256 block tile's class (a plain integer-keyed table, cleared past 65536): 0 when
	no footprint + Margin and no candidate corridor touches it: the raw values, after one lookup.
	Else, per column (one shared memo of the last column for the wrapper, `surface`, `protects` and
	`treeAllowed`): the city weight w_c (1 in the footprint, smoothstep(1 - dist / Margin) in the
	margin, dist the Chebyshev distance past the square; target H) and, at levels up to CutLevels,
	the road weight w_r (1 within Width / 2 + Shoulder of the nearest segment of the tile's 32
	block bucket, smoothstep over Blend beyond; target the graded height at the projection, at
	least SeaLevel + 1: a causeway). w = max(w_c, w_r) and its target T: y + (T - y) w, river (1 -
	w). The surface: the city's (CityLayout.surface) in the footprint at every level; on a road at
	levels up to SurfaceLevels, Asphalt within Width / 2 (a dashed Yellow Road Line within 0.5 of
	the centre, decayed as the streets), a Gravel or Coarse Dirt shoulder out to Width / 2 +
	Shoulder; else nil. Wrecks on the roads: at vertices (Step apart) with a hash under Cars x Step,
	more than PIN blocks from a gate, square to the road's main axis in its right lane.

	Candidates and links. A cell's candidate links are the pairs of cities within LinkCells cells
	of it, and within LinkCells x Grid of each other, whose corridor touches it: a superset of its
	links that needs the existence of their ends alone (both ends of a link through a cell lie
	within LinkCells cells of it, as a footprint keeps 85 blocks inside its cell, more than the
	corridor's 59.5), never a city's choices. `blocked`, the tile classes, a tile's segments and
	/locate's planners read the candidates; with none cached for a cell, only the pairs whose
	gates' box, grown by the corridor, reaches their rectangle, and a far end's cell only when the
	hull of the near city's footprint (its gate's place) and that cell's gates' range, grown by
	the corridor, meets the rectangle (a cold `blocked` of a small rectangle tests some 7-17
	cells, 7 the median). Only a tile's segments, the map's roads and the containers ask whether
	a candidate is a link (whether one city is the other's choice: only the cells around it that
	could hold a nearer city in that quarter are tested) and build its plan. A tile's segments
	are built only for a column (the wrapper) or a rectangle (`prepare`) a candidate's corridor
	reaches: no road reaches one outside them all, so it is raw without any road's plan.

	Caches (Config.Cities.Caches, per generator): cells (existence and the candidate links near
	each cell), sites (plans), links (road plans), tiles (segment buckets), each an LRU (the
	oldest quarter dropped when full). `prepare` builds the cells around a rectangle (whatever its
	links' choices may test, LinkCells x 2 cells out), the tile classes, sites, links and tiles
	touching it, calling `yield` every PAUSE relief samples; every other wrapped query then finds
	them warm (a cold one builds only what it needs, at once: a road's or a city's first column
	some 0.3-5 ms, median 1.6-2.2, once per region and generator). No random stream lives across
	a yield: a plan keeps numbers, and nothing is cached before it is complete. `write` plans the chunk's lots first (LOT_WORK samples' worth each, yielding as
	they add up), then writes them through CityLayout's writer, which never yields (it is module
	state: another generate on the actor during a yield would take it over).

	`Cities.sample` is the debug structures world's town (Generation/DebugWorlds).
]]

local Config = require(script.Parent.Parent.Config)
local Blocks = require(script.Parent.Parent.Blocks)
local Biomes = require(script.Parent.Parent.Biomes)
local Hash = require(script.Parent.Parent.Util.Hash)
local ChunkLayout = require(script.Parent.Parent.World.ChunkLayout)
local Relief = require(script.Parent.Relief)
local Locate = require(script.Parent.Locate)
local StructureGen = require(script.Parent.StructureGen)
local ScavengeLoot = require(script.Parent.ScavengeLoot)
local Roads = require(script.Parent.Roads)
local CityLayout = require(script.Parent.CityLayout)

export type Site = { gx: number, gz: number, x: number, z: number, radius: number, y: number, salt: number }
export type Segment = { x0: number, z0: number, x1: number, z1: number, y0: number, y1: number, link: number }
export type WriteArgs = {
	data: buffer,
	cells: number,
	level: number,
	originX: number,
	originZ: number,
	heights: { number },
	topCells: { number },
	biomes: { number },
}
export type Cities = {
	-- The wrapped relief (cut and fill).
	relief: Relief.Relief,
	prepare: (minX: number, minZ: number, maxX: number, maxZ: number, yield: (() -> ())?) -> (),
	surface: (x: number, z: number, h: number, level: number) -> (number?, number?),
	blocked: (minX: number, minZ: number, maxX: number, maxZ: number, yield: (() -> ())?) -> { number },
	protects: (x: number, z: number) -> boolean,
	treeAllowed: (x: number, z: number) -> boolean,
	top: (level: number, originX: number, originZ: number) -> number?,
	write: (args: WriteArgs, yield: (() -> ())?) -> (number, number),
	container: (x: number, y: number, z: number) -> { StructureGen.ContainerItem }?,
	poiBlocks: (
		minX: number,
		minZ: number,
		maxX: number,
		maxZ: number,
		lut: buffer,
		out: { number },
		yield: (() -> ())?
	) -> (),
	locateKind: () -> Locate.Kind,
	cityAt: (x: number, z: number) -> number,
	sites: (minX: number, minZ: number, maxX: number, maxZ: number, yield: (() -> ())?) -> { Site },
	roads: (minX: number, minZ: number, maxX: number, maxZ: number, yield: (() -> ())?) -> { Segment },
	bunkerSpots: (minX: number, minZ: number, maxX: number, maxZ: number, yield: (() -> ())?) -> { number },
	spawnShift: (
		x: number,
		z: number,
		ok: (x: number, z: number) -> boolean,
		yield: (() -> ())?
	) -> (number, number),
	-- Cells, sites, links and tiles built so far (not served from a cache); nil: nothing to build.
	built: (() -> (number, number, number, number))?,
	-- The plan of the city whose footprint holds (x, z) (Generation/CityLayout), nil: none.
	planAt: ((x: number, z: number) -> CityLayout.Plan?)?,
}

-- What `new` needs besides the raw relief: the raw biome of a column and the sea's surface, and
-- optionally the biome of a column from its raw relief's height without rivers and selector
-- (the same answer as rawBiome's, without sampling the relief again: the existence test's).
export type Options = {
	rawBiome: (x: number, z: number) -> number,
	seaLevel: number,
	biomeOf: ((x: number, z: number, unrivered: number, selector: number) -> number)?,
}

-- An existing city's numbers (the existence test's): CityLayout.Site.
type Exist = CityLayout.Site

-- A candidate link: its id, the two cities (a: the lower cell) and their gates.
type Link = { id: number, a: Exist, b: Exist, ax: number, az: number, bx: number, bz: number }

-- A road plan with what its surface needs (overgrowth of its middle's biome).
type RoadPlan = Roads.Plan & { o: number }

-- A tile's segments: flat arrays (x0, z0, x1, z1, y0, y1, arc length at the start, plan index,
-- vertex) and per 32 block bucket the segments reaching it.
type Tile = {
	plans: { RoadPlan },
	seg: { number },
	buckets: { { number } },
}

-- A cell's record: whether a city stands in it (nil: none), and lazily the candidate links whose
-- corridor touches it.
type Cell = { exist: Exist?, candidates: { Link }? }

-- A plan build's yield and the relief samples since its last call.
type Work = { yield: (() -> ())?, work: number }

local Cities = {}

local TILE = 256
local BUCKET = 32
local BUCKETS = TILE // BUCKET
local SEG = 9 -- numbers per segment in a tile
local PAUSE = Roads.PAUSE
-- Planning a lot (and, far, its buildings' envelopes) costs about this many relief samples.
local LOT_WORK = 12
local SPAWN_RANGE = 3000
local SPAWN_NEAR, SPAWN_FAR, SPAWN_STEP = 150, 400, 50
local SPAWN_BEARING = math.rad(15)
local CLASS_LIMIT = 65536

local floor = math.floor
local min, max = math.min, math.max
local abs = math.abs
local sqrt = math.sqrt
local huge = math.huge
local smoothstep = Roads.smoothstep

local id = Blocks.id
local ASPHALT, LINE_YELLOW, GRAVEL, COARSE_DIRT = id.Asphalt, id.RoadLineYellow, id.Gravel, id.CoarseDirt
local CRATE = id.SupplyCrate
local WORLD_HEIGHT = Config.WorldHeight
local STRUCTURE_ROOM = 32

-- Biomes no city stands on: frozen ones and those of the mountains only (Meadow and up), or of
-- no band (mushroom isles).
local UNFIT: { boolean } = {}
do
	local meadow = 4
	for i, band in Biomes.bands do
		if band.name == "Meadow" then
			meadow = i
		end
	end
	for i, biome in Biomes.list do
		local low = false
		for _, band in biome.bands do
			if band < meadow then
				low = true
			end
		end
		UNFIT[i] = biome.frozen or not low
	end
end

local function cellKey(gx: number, gz: number): number
	return (gx + 1048576) * 2097152 + (gz + 1048576)
end

-- An LRU of `cap` entries (the oldest quarter dropped when full).
local function lru(cap: number): ((key: number) -> any, (key: number, value: any) -> ())
	local values: { [number]: any } = {}
	local used: { [number]: number } = {}
	local count, clock = 0, 0
	local function get(key: number): any
		local value = values[key]
		if value ~= nil then
			clock += 1
			used[key] = clock
		end
		return value
	end
	local function set(key: number, value: any)
		if values[key] == nil then
			if count >= cap then
				local stamps: { number } = {}
				for _, stamp in used do
					table.insert(stamps, stamp)
				end
				table.sort(stamps)
				local cut = stamps[max(1, #stamps // 4)]
				for k, stamp in used do
					if stamp <= cut then
						values[k] = nil
						used[k] = nil
						count -= 1
					end
				end
			end
			count += 1
		end
		clock += 1
		values[key] = value
		used[key] = clock
	end
	return get, set
end

local function spend(w: Work?, n: number)
	if w == nil then
		return
	end
	local yield = w.yield
	if yield then
		w.work += n
		if w.work >= PAUSE then
			w.work = 0
			yield()
		end
	end
end

-- The quarter (1 east, 2 north, 3 west, 4 south) of offset (dx, dz) (see the header).
local function quarter(dx: number, dz: number): number
	local a, b = dx + dz, dx - dz
	if a > 0 and b >= 0 then
		return 1
	elseif a <= 0 and b > 0 then
		return 2
	elseif a < 0 and b <= 0 then
		return 3
	end
	return 4
end

-- Gate of city a towards city b (see the header).
local function gate(a: Exist, b: Exist): (number, number)
	local dx, dz = b.x - a.x, b.z - a.z
	local R, h = a.radius, a.half
	if abs(dx) >= abs(dz) then
		local j = math.clamp(floor(math.clamp(dz, -R, R) / 32 + 0.5), -h, h)
		return a.x + (if dx >= 0 then R else -R), a.z + 32 * j
	end
	local j = math.clamp(floor(math.clamp(dx, -R, R) / 32 + 0.5), -h, h)
	return a.x + 32 * j, a.z + (if dz >= 0 then R else -R)
end

--[[
	Does the convex hull of the boxes (ax0..ax1, az0..az1) and (bx0..bx1, bz0..bz1) meet the
	rectangle x0..x1, z0..z1 (separating axes: the rectangle's two and the hull's edges')?
]]
local function hullMeets(
	ax0: number,
	az0: number,
	ax1: number,
	az1: number,
	bx0: number,
	bz0: number,
	bx1: number,
	bz1: number,
	x0: number,
	z0: number,
	x1: number,
	z1: number
): boolean
	if max(ax1, bx1) < x0 or min(ax0, bx0) > x1 or max(az1, bz1) < z0 or min(az0, bz0) > z1 then
		return false
	end
	local points = {
		{ ax0, az0 },
		{ ax1, az0 },
		{ ax0, az1 },
		{ ax1, az1 },
		{ bx0, bz0 },
		{ bx1, bz0 },
		{ bx0, bz1 },
		{ bx1, bz1 },
	}
	table.sort(points, function(p: { number }, q: { number }): boolean
		return p[1] < q[1] or (p[1] == q[1] and p[2] < q[2])
	end)
	local function cross(o: { number }, a: { number }, b: { number }): number
		return (a[1] - o[1]) * (b[2] - o[2]) - (a[2] - o[2]) * (b[1] - o[1])
	end
	-- (Andrew's monotone chain: the hull counter-clockwise.)
	local hull: { { number } } = {}
	for _, p in points do
		while #hull >= 2 and cross(hull[#hull - 1], hull[#hull], p) <= 0 do
			table.remove(hull)
		end
		table.insert(hull, p)
	end
	local lower = #hull + 1
	for i = #points - 1, 1, -1 do
		local p = points[i]
		while #hull >= lower and cross(hull[#hull - 1], hull[#hull], p) <= 0 do
			table.remove(hull)
		end
		table.insert(hull, p)
	end
	table.remove(hull)
	local corners = { { x0, z0 }, { x1, z0 }, { x0, z1 }, { x1, z1 } }
	for i = 1, #hull do
		local a, b = hull[i], hull[i % #hull + 1]
		local outside = true
		for _, c in corners do
			if cross(a, b, c) >= 0 then
				outside = false
				break
			end
		end
		if outside then
			return false
		end
	end
	return true
end

-- The existence test's 5 x 5 lattice (i, j in -2..2, R / 2 apart), the corners and the middle
-- first: a slope shows in the heights' span after a few samples (the order changes no answer).
local LATTICE: { number } = { -2, -2, 2, 2, 2, -2, -2, 2, 0, 0, 0, -2, 0, 2, -2, 0, 2, 0 }
do
	local seen: { [number]: boolean } = {}
	for k = 1, #LATTICE, 2 do
		seen[LATTICE[k] * 8 + LATTICE[k + 1]] = true
	end
	for j = -2, 2 do
		for i = -2, 2 do
			if not seen[i * 8 + j] then
				table.insert(LATTICE, i)
				table.insert(LATTICE, j)
			end
		end
	end
end

-- What a world without ruins uses for /locate structure city: every probe answers nothing.
local function noKind(): Locate.Kind
	local grid = Config.Cities.Grid
	return {
		id = "city",
		grid = grid,
		slack = 0,
		rings = math.ceil(Config.Locate.Radius.city / grid),
		showY = false,
		probe = function(_gx: number, _gz: number): (number?, number, number)
			return nil, 0, 0
		end,
	}
end

-- No cities: the raw relief, natural ground everywhere, nothing blocked (see the header).
function Cities.none(raw: Relief.Relief): Cities
	return {
		relief = raw,
		prepare = function(_minX: number, _minZ: number, _maxX: number, _maxZ: number, _yield: (() -> ())?) end,
		surface = function(_x: number, _z: number, _h: number, _level: number): (number?, number?)
			return nil, nil
		end,
		blocked = function(_minX: number, _minZ: number, _maxX: number, _maxZ: number, _yield: (() -> ())?): { number }
			return {}
		end,
		protects = function(_x: number, _z: number): boolean
			return false
		end,
		treeAllowed = function(_x: number, _z: number): boolean
			return true
		end,
		top = function(_level: number, _originX: number, _originZ: number): number?
			return nil
		end,
		write = function(_args: WriteArgs, _yield: (() -> ())?): (number, number)
			return math.huge, 0
		end,
		container = function(_x: number, _y: number, _z: number): { StructureGen.ContainerItem }?
			return nil
		end,
		poiBlocks = function(
			_minX: number,
			_minZ: number,
			_maxX: number,
			_maxZ: number,
			_lut: buffer,
			_out: { number },
			_yield: (() -> ())?
		)
		end,
		locateKind = noKind,
		cityAt = function(_x: number, _z: number): number
			return 0
		end,
		sites = function(_minX: number, _minZ: number, _maxX: number, _maxZ: number, _yield: (() -> ())?): { Site }
			return {}
		end,
		roads = function(_minX: number, _minZ: number, _maxX: number, _maxZ: number, _yield: (() -> ())?): { Segment }
			return {}
		end,
		bunkerSpots = function(
			_minX: number,
			_minZ: number,
			_maxX: number,
			_maxZ: number,
			_yield: (() -> ())?
		): { number }
			return {}
		end,
		spawnShift = function(
			x: number,
			z: number,
			_ok: (x: number, z: number) -> boolean,
			_yield: (() -> ())?
		): (number, number)
			return x, z
		end,
		built = nil,
		planAt = nil,
	}
end

-- The cities of world `seed` over the raw relief `raw` (see the header).
function Cities.new(seed: number, raw: Relief.Relief, options: Options): Cities
	local cfg = Config.Cities
	local roadCfg = cfg.Roads
	local SEA = options.seaLevel
	local rawBiome = options.rawBiome
	local biomeOf = options.biomeOf
	local GRID = cfg.Grid
	local MARGIN = cfg.Margin
	local MIN_HALF, MAX_HALF = cfg.MinRadius // 32, cfg.MaxRadius // 32
	local M0 = cfg.MaxRadius + MARGIN + 64
	local LINK = roadCfg.LinkCells
	local ROADS = roadCfg.Enabled
	local CORRIDOR = Roads.corridor()
	local BAND, REACH = Roads.band()
	local HALF_WIDTH = roadCfg.Width / 2
	local CUT_LEVELS, SURFACE_LEVELS = roadCfg.CutLevels, roadCfg.SurfaceLevels
	local LOD_LEVELS = cfg.LodLevels

	--[[
		The cell offset pairs (p, q) whose link's corridor may touch the middle cell (0, 0): p and
		q within LinkCells of it and of each other, and the hull of the ranges their gates may lie
		in (a footprint's side: the centre's range in its cell, +- the biggest R), grown by the
		corridor, meets it. Flat (pdx, pdz, qdx, qdz), the nearer end first and the pairs nearest
		the middle first: `walkCandidates` tests the existence of an end only when the other
		exists, so most cells around an empty one are never tested.
	]]
	-- Where in its cell a gate may lie on each axis (a centre's range, +- the biggest R).
	local GATE_LO, GATE_HI = M0 - (MAX_HALF * 32 + 3), GRID - M0 + (MAX_HALF * 32 + 3)
	local THROUGH: { number } = {}
	do
		local lo, hi = GATE_LO, GATE_HI
		local list: { { number } } = {}
		for pz = -LINK, LINK do
			for px = -LINK, LINK do
				for qz = -LINK, LINK do
					for qx = -LINK, LINK do
						local dp, dq = max(abs(px), abs(pz)), max(abs(qx), abs(qz))
						local first = dp < dq or (dp == dq and (pz < qz or (pz == qz and px < qx)))
						if not first or max(abs(px - qx), abs(pz - qz)) > LINK then
							continue
						end
						-- (Centres at least this far apart on each axis: farther than LinkCells x
						-- Grid in all, never a pair.)
						local gapX = max(0, abs(px - qx) * GRID - (GRID - 2 * M0))
						local gapZ = max(0, abs(pz - qz) * GRID - (GRID - 2 * M0))
						if gapX * gapX + gapZ * gapZ > (LINK * GRID) ^ 2 then
							continue
						end
						if
							hullMeets(
								px * GRID + lo,
								pz * GRID + lo,
								px * GRID + hi,
								pz * GRID + hi,
								qx * GRID + lo,
								qz * GRID + lo,
								qx * GRID + hi,
								qz * GRID + hi,
								-CORRIDOR - 1,
								-CORRIDOR - 1,
								GRID + CORRIDOR + 1,
								GRID + CORRIDOR + 1
							)
						then
							table.insert(list, { dp, dq, px, pz, qx, qz })
						end
					end
				end
			end
		end
		table.sort(list, function(a: { number }, b: { number }): boolean
			for i = 1, 6 do
				if a[i] ~= b[i] then
					return a[i] < b[i]
				end
			end
			return false
		end)
		for _, e in list do
			table.move(e, 3, 6, #THROUGH + 1, THROUGH)
		end
	end
	local citySalt = Hash.hash2(seed, Hash.string("cities"), 0xC17E)
	local linkSalt = Hash.hash2(seed, Hash.string("cities.roads"), 0x40AD)
	local lootSalt = Hash.hash2(seed, Hash.string("cities.loot"), 0x0C17)
	local carSalt = Hash.hash2(seed, Hash.string("cities.cars"), 0xCA45)
	local caches = cfg.Caches

	local builtCells, builtSites, builtLinks, builtTiles = 0, 0, 0, 0

	local function clampHeight(y: number): number
		local h = floor(y)
		if h < 2 then
			return 2
		elseif h > WORLD_HEIGHT - STRUCTURE_ROOM then
			return WORLD_HEIGHT - STRUCTURE_ROOM
		end
		return h
	end

	--[[ Existence ]]

	-- Does a footprint of half-width R centred on (cx, cz) pass the lattice test (see the header)?
	local function fits(cx: number, cz: number, R: number, w: Work?): boolean
		local allowed = 25 - cfg.Accept
		local fails = 0
		-- (The samples passing the selector as bits: nothing allocated per test.)
		local passing = 0
		for k = 1, 50, 2 do
			local x, z = cx + (LATTICE[k] * R) // 2, cz + (LATTICE[k + 1] * R) // 2
			local a = abs(raw.selector(x, z))
			if a < 0.22 or a >= 0.40 then
				fails += 1
				if fails > allowed then
					return false
				end
			else
				passing = bit32.bor(passing, bit32.lshift(1, k // 2))
			end
		end
		spend(w, 4)
		-- Then each sample left in turn: its height (under the sea's shore or on a river fails),
		-- then its biome (from the height's own numbers when the generator gives `biomeOf`: the
		-- same biome as rawBiome's, without a second relief sample). A sample passing both is in
		-- the final set for good, so the moment the heights of those passing so far span more
		-- than the limit the spot fails (the final span can only be wider), and a fifth failure
		-- of any kind ends it too: a hilly or mountainous spot is refused after a few samples.
		local limit = 1.5 * cfg.MaxSlope
		local lo, hi = huge, -huge
		for k = 1, 50, 2 do
			if bit32.band(passing, bit32.lshift(1, k // 2)) == 0 then
				continue
			end
			local x, z = cx + (LATTICE[k] * R) // 2, cz + (LATTICE[k + 1] * R) // 2
			local y, unrivered, selector, river = raw.height(x, z, 0)
			spend(w, 1)
			local fit = river < 0.05 and y >= SEA + cfg.MinAboveSea
			if fit then
				local biome
				if biomeOf then
					biome = biomeOf(x, z, unrivered, selector)
					spend(w, 1)
				else
					biome = rawBiome(x, z)
					spend(w, 2)
				end
				fit = not UNFIT[biome]
			end
			if not fit then
				fails += 1
				if fails > allowed then
					return false
				end
			else
				lo, hi = min(lo, y), max(hi, y)
				if hi - lo > limit then
					return false
				end
			end
		end
		return true
	end

	-- Cell (gx, gz)'s city (nil: none), from the raw terrain alone: the cell's hash keeps it with
	-- Chance, then up to Tries spots (size and centre) are tested in turn (see the header).
	local function existence(gx: number, gz: number, w: Work?): Exist?
		local rng = Hash.rng(Hash.hash3(citySalt, gx, 0, gz))
		if rng:float() >= cfg.Chance then
			return nil
		end
		for _ = 1, cfg.Tries do
			local u = rng:float()
			local half = min(MAX_HALF, MIN_HALF + floor((MAX_HALF - MIN_HALF + 1) * u * u))
			local R = half * 32 + 3
			local cx = gx * GRID + M0 + rng:int(0, GRID - 2 * M0)
			local cz = gz * GRID + M0 + rng:int(0, GRID - 2 * M0)
			if fits(cx, cz, R, w) then
				return {
					gx = gx,
					gz = gz,
					x = cx,
					z = cz,
					half = half,
					radius = R,
					salt = Hash.hash3(citySalt, gx, 1, gz),
				}
			end
		end
		return nil
	end

	local getCell, setCell = lru(caches.Cells)
	local function cellAt(gx: number, gz: number, w: Work?): Cell
		local key = cellKey(gx, gz)
		local cell: Cell? = getCell(key)
		if cell == nil then
			builtCells += 1
			local new: Cell = { exist = existence(gx, gz, w), candidates = nil }
			setCell(key, new)
			return new
		end
		return cell
	end

	local function makeLink(a: Exist, b: Exist): Link
		local ka, kb = cellKey(a.gx, a.gz), cellKey(b.gx, b.gz)
		if kb < ka then
			a, b, ka, kb = b, a, kb, ka
		end
		local ax, az = gate(a, b)
		local bx, bz = gate(b, a)
		return {
			id = Hash.hash3(linkSalt, ka % 4294967296, ka // 4294967296 + kb // 4294967296, kb % 4294967296),
			a = a,
			b = b,
			ax = ax,
			az = az,
			bx = bx,
			bz = bz,
		}
	end

	--[[
		Calls found(link) for every candidate link whose corridor touches the rectangle x0..x1,
		z0..z1 (inside cell (gx, gz)), in THROUGH's order, until it returns true: every pair of
		cities in the cells within LinkCells of the cell, within LinkCells cells and LinkCells x
		Grid of each other. A superset of the links (a link joins a city to one of its own
		choices, never farther), and both ends of any link whose corridor touches the cell lie
		within LinkCells cells of it (a footprint keeps 85 blocks inside its cell, more than the
		corridor's 59.5), so it needs the existence of some of those (2 LinkCells + 1)² cells
		alone (an end's only when the other end stands, only for the pairs whose gates' box,
		grown by the corridor, reaches the rectangle, and a far end's only when the hull of the
		near city's footprint and its gates' range does too), never a city's choices: `blocked`,
		the tile classes and a cold column stay conservative and cheap.
	]]
	local function walkCandidates(
		gx: number,
		gz: number,
		x0: number,
		z0: number,
		x1: number,
		z1: number,
		w: Work?,
		found: (link: Link) -> boolean
	)
		local limit = (LINK * GRID) ^ 2
		local span = GRID - 2 * M0
		local reach = CORRIDOR + 1
		for k = 1, #THROUGH, 4 do
			local pgx, pgz = gx + THROUGH[k], gz + THROUGH[k + 1]
			local bgx, bgz = gx + THROUGH[k + 2], gz + THROUGH[k + 3]
			-- (The box of both gates' ranges, grown by the corridor: the hull's, and so the
			-- corridor's, bounds.)
			if
				max(pgx, bgx) * GRID + GATE_HI + reach < x0
				or min(pgx, bgx) * GRID + GATE_LO - reach > x1
				or max(pgz, bgz) * GRID + GATE_HI + reach < z0
				or min(pgz, bgz) * GRID + GATE_LO - reach > z1
			then
				continue
			end
			local a = cellAt(pgx, pgz, w).exist
			if a == nil then
				continue
			end
			-- (The other end's cell only when its centres' range lies near enough to a.)
			local cx0, cz0 = bgx * GRID + M0, bgz * GRID + M0
			local gapX = max(0, cx0 - a.x, a.x - (cx0 + span))
			local gapZ = max(0, cz0 - a.z, a.z - (cz0 + span))
			if gapX * gapX + gapZ * gapZ > limit then
				continue
			end
			-- (And, when that cell is not known yet, only when the hull of a's footprint (where
			-- its gate lies) and the other's gates' range, grown by the corridor, meets the
			-- rectangle: no link between them could reach it otherwise.)
			if getCell(cellKey(bgx, bgz)) == nil then
				local R = a.radius
				if
					not hullMeets(
						a.x - R,
						a.z - R,
						a.x + R,
						a.z + R,
						bgx * GRID + GATE_LO,
						bgz * GRID + GATE_LO,
						bgx * GRID + GATE_HI,
						bgz * GRID + GATE_HI,
						x0 - reach,
						z0 - reach,
						x1 + reach,
						z1 + reach
					)
				then
					continue
				end
			end
			local b = cellAt(bgx, bgz, w).exist
			if b and (b.x - a.x) ^ 2 + (b.z - a.z) ^ 2 <= limit then
				local link = makeLink(a, b)
				if Roads.touches(link.ax, link.az, link.bx, link.bz, CORRIDOR, x0, z0, x1, z1) and found(link) then
					return
				end
			end
		end
	end

	-- The candidate links whose corridor touches cell (gx, gz) (walkCandidates), cached in the
	-- cell.
	local function candidatesNear(gx: number, gz: number, w: Work?): { Link }
		local cell = cellAt(gx, gz, w)
		local list = cell.candidates
		if list then
			return list
		end
		local out: { Link } = {}
		if ROADS then
			local x0, z0 = gx * GRID, gz * GRID
			walkCandidates(gx, gz, x0, z0, x0 + GRID - 1, z0 + GRID - 1, w, function(link: Link): boolean
				table.insert(out, link)
				return false
			end)
		end
		cell.candidates = out
		return out
	end

	-- Calls found(link) for every candidate link of cell (gx, gz) whose corridor touches the
	-- rectangle x0..x1, z0..z1 inside it, in THROUGH's order, until it returns true: the cell's
	-- cached candidates when known, else only the pairs that may reach the rectangle (fewer cells
	-- to test; the same links in the same order).
	local function linksTouching(
		gx: number,
		gz: number,
		x0: number,
		z0: number,
		x1: number,
		z1: number,
		w: Work?,
		found: (link: Link) -> boolean
	)
		if not ROADS then
			return
		end
		local known = cellAt(gx, gz, w).candidates
		if known == nil then
			walkCandidates(gx, gz, x0, z0, x1, z1, w, found)
			return
		end
		for _, link in known do
			if Roads.touches(link.ax, link.az, link.bx, link.bz, CORRIDOR, x0, z0, x1, z1) and found(link) then
				return
			end
		end
	end

	--[[
		Is city b city a's choice: the nearest city in its quarter of a within LinkCells x Grid
		(see the header), of the cells within LinkCells of a's, in rows of z then x, the first of
		equally near ones? Only the cells that could hold a city beating b are tested: those
		whose centres' range comes within b's distance of a and reaches b's quarter (a cold road
		column tests a few cells around each end, not all 24).
	]]
	local function chose(a: Exist, b: Exist, w: Work?): boolean
		local ox, oz = b.gx - a.gx, b.gz - a.gz
		if (ox == 0 and oz == 0) or abs(ox) > LINK or abs(oz) > LINK then
			return false
		end
		local bdx, bdz = b.x - a.x, b.z - a.z
		local d = bdx * bdx + bdz * bdz
		if d > (LINK * GRID) ^ 2 then
			return false
		end
		local q = quarter(bdx, bdz)
		local order = oz * (2 * LINK + 1) + ox
		local span = GRID - 2 * M0
		for dz = -LINK, LINK do
			for dx = -LINK, LINK do
				if (dx == 0 and dz == 0) or (dx == ox and dz == oz) then
					continue
				end
				-- (The offsets from a of the centres' range in that cell.)
				local x0 = (a.gx + dx) * GRID + M0 - a.x
				local z0 = (a.gz + dz) * GRID + M0 - a.z
				local x1, z1 = x0 + span, z0 + span
				local gapX, gapZ = max(0, x0, -x1), max(0, z0, -z1)
				if gapX * gapX + gapZ * gapZ > d then
					continue
				end
				-- (Whether some offset in it may lie in quarter q: the bounds of dx + dz and dx - dz.)
				local sumLo, sumHi, difLo, difHi = x0 + z0, x1 + z1, x0 - z1, x1 - z0
				if
					(q == 1 and (sumHi <= 0 or difHi < 0))
					or (q == 2 and (sumLo > 0 or difHi <= 0))
					or (q == 3 and (sumLo >= 0 or difLo > 0))
					or (q == 4 and (sumHi < 0 or difLo > 0))
				then
					continue
				end
				local c = cellAt(a.gx + dx, a.gz + dz, w).exist
				if c then
					local cdx, cdz = c.x - a.x, c.z - a.z
					local dc = cdx * cdx + cdz * cdz
					if quarter(cdx, cdz) == q and (dc < d or (dc == d and dz * (2 * LINK + 1) + dx < order)) then
						return false
					end
				end
			end
		end
		return true
	end

	-- Is candidate `link` a link: one of its cities' choice of the other (see the header)?
	local function isLink(link: Link, w: Work?): boolean
		return chose(link.a, link.b, w) or chose(link.b, link.a, w)
	end

	--[[ Sites ]]

	local getSite, setSite = lru(caches.Sites)
	local function sitePlan(e: Exist, w: Work?): CityLayout.Plan
		local key = cellKey(e.gx, e.gz)
		local plan: CityLayout.Plan? = getSite(key)
		if plan then
			return plan
		end
		builtSites += 1
		local heights: { number } = table.create(81)
		local R = e.radius
		for j = 0, 8 do
			for i = 0, 8 do
				local y = raw.height(e.x - R + (i * 2 * R) // 8, e.z - R + (j * 2 * R) // 8, 0)
				table.insert(heights, y)
				spend(w, 1)
			end
		end
		table.sort(heights)
		local H = max(clampHeight(heights[41]), SEA + cfg.MinAboveSea)
		local humidity = Biomes.list[rawBiome(e.x, e.z)].humidity
		spend(w, 2)
		local o = cfg.Overgrowth * math.clamp((humidity + 0.8) / 1.4, 0.15, 1)
		local new = CityLayout.plan(e, H, o)
		setSite(key, new)
		return new
	end

	--[[ Links ]]

	local getLink, setLink = lru(caches.Links)
	local function linkPlan(link: Link, w: Work?): RoadPlan
		local plan: RoadPlan? = getLink(link.id)
		if plan then
			return plan
		end
		builtLinks += 1
		local ya = sitePlan(link.a, w).y
		local yb = sitePlan(link.b, w).y
		local base = Roads.plan(link.id, link.ax, link.az, ya, link.bx, link.bz, yb, function(x: number, z: number)
			local y, _, s, river = raw.height(x, z, 0)
			spend(w, 1)
			return y, s, river
		end, nil)
		local mx, mz = (link.ax + link.bx) // 2, (link.az + link.bz) // 2
		local humidity = Biomes.list[rawBiome(mx, mz)].humidity
		spend(w, 2)
		local new = base :: RoadPlan
		new.o = cfg.Overgrowth * math.clamp((humidity + 0.8) / 1.4, 0.15, 1)
		setLink(link.id, new)
		return new
	end

	--[[ Tiles ]]

	local classes: { [number]: number } = {}
	local classCount = 0

	-- Tile (tx, tz)'s class (see the header).
	local function classOf(tx: number, tz: number, w: Work?): number
		local key = cellKey(tx, tz)
		local cached = classes[key]
		if cached then
			return cached
		end
		local x0, z0 = tx * TILE, tz * TILE
		local x1, z1 = x0 + TILE - 1, z0 + TILE - 1
		local gx, gz = x0 // GRID, z0 // GRID
		local c = 0
		local e = cellAt(gx, gz, w).exist
		if e then
			local m = e.radius + MARGIN
			if e.x - m <= x1 and e.x + m >= x0 and e.z - m <= z1 and e.z + m >= z0 then
				c = 1
			end
		end
		if c == 0 then
			linksTouching(gx, gz, x0, z0, x1, z1, w, function(_link: Link): boolean
				c = 1
				return true
			end)
		end
		if classCount >= CLASS_LIMIT then
			table.clear(classes)
			classCount = 0
		end
		classes[key] = c
		classCount += 1
		return c
	end

	-- The candidate links whose corridor touches tile (tx, tz) (linksTouching), kept per tile as
	-- the classes are (the wrapper's columns there test them before any tile is built).
	local tileLinks: { [number]: { Link } } = {}
	local tileLinkCount = 0
	local function linksOfTile(tx: number, tz: number, w: Work?): { Link }
		local key = cellKey(tx, tz)
		local list = tileLinks[key]
		if list then
			return list
		end
		local x0, z0 = tx * TILE, tz * TILE
		local out: { Link } = {}
		linksTouching(x0 // GRID, z0 // GRID, x0, z0, x0 + TILE - 1, z0 + TILE - 1, w, function(link: Link): boolean
			table.insert(out, link)
			return false
		end)
		if tileLinkCount >= CLASS_LIMIT then
			table.clear(tileLinks)
			tileLinkCount = 0
		end
		tileLinks[key] = out
		tileLinkCount += 1
		return out
	end

	local getTile, setTile = lru(caches.Tiles)
	local function tileOf(tx: number, tz: number, w: Work?): Tile
		local key = cellKey(tx, tz)
		local tile: Tile? = getTile(key)
		if tile then
			return tile
		end
		builtTiles += 1
		local x0, z0 = tx * TILE, tz * TILE
		local x1, z1 = x0 + TILE - 1, z0 + TILE - 1
		local plans: { RoadPlan } = {}
		local seg: { number } = {}
		local buckets: { { number } } = table.create(BUCKETS * BUCKETS)
		for i = 1, BUCKETS * BUCKETS do
			buckets[i] = {}
		end
		for _, link in linksOfTile(tx, tz, w) do
			if not isLink(link, w) then
				continue
			end
			local plan = linkPlan(link, w)
			if plan.rejected then
				continue
			end
			table.insert(plans, plan)
			local index = #plans
			local px, pz, py, ps = plan.x, plan.z, plan.y, plan.s
			for j = 1, plan.count - 1 do
				local sx0, sz0, sx1, sz1 = px[j], pz[j], px[j + 1], pz[j + 1]
				local bx0, bx1 = min(sx0, sx1) - REACH, max(sx0, sx1) + REACH
				local bz0, bz1 = min(sz0, sz1) - REACH, max(sz0, sz1) + REACH
				if bx1 < x0 or bx0 > x1 + 1 or bz1 < z0 or bz0 > z1 + 1 then
					continue
				end
				table.move({ sx0, sz0, sx1, sz1, py[j], py[j + 1], ps[j], index, j }, 1, SEG, #seg + 1, seg)
				local s = #seg - SEG + 1
				for bz = max(0, floor((bz0 - z0) / BUCKET)), min(BUCKETS - 1, floor((bz1 - z0) / BUCKET)) do
					for bx = max(0, floor((bx0 - x0) / BUCKET)), min(BUCKETS - 1, floor((bx1 - x0) / BUCKET)) do
						table.insert(buckets[bz * BUCKETS + bx + 1], s)
					end
				end
			end
		end
		local new: Tile = { plans = plans, seg = seg, buckets = buckets }
		setTile(key, new)
		return new
	end

	--[[ Columns ]]

	-- The shared memo of the last column looked up (see the header).
	local cityX, cityZ = huge, huge
	local mPlan: CityLayout.Plan? = nil
	local mWeight, mDist = 0, huge
	local roadX, roadZ = huge, huge
	local mRoad = false
	local mRoadD, mRoadY, mRoadAlong, mRoadO = huge, 0, 0, 0

	-- The city part of column (x, z): mPlan (nil: no city near), mWeight and mDist.
	local function lookupCity(x: number, z: number)
		if x == cityX and z == cityZ then
			return
		end
		cityX, cityZ = x, z
		mPlan, mWeight, mDist = nil, 0, huge
		local e = cellAt(x // GRID, z // GRID).exist
		if e then
			local dist = max(abs(x - e.x) - e.radius, abs(z - e.z) - e.radius)
			if dist <= MARGIN then
				mPlan = sitePlan(e)
				mDist = dist
				mWeight = if dist <= 0 then 1 else smoothstep(1 - dist / MARGIN)
			end
		end
	end

	-- The road part of column (x, z): mRoad, the nearest centre line's distance, graded height
	-- there, arc length, and the road's overgrowth.
	local function lookupRoad(x: number, z: number, tx: number, tz: number)
		if x == roadX and z == roadZ then
			return
		end
		roadX, roadZ = x, z
		mRoad = false
		if not ROADS then
			return
		end
		local tile: Tile? = getTile(cellKey(tx, tz))
		if tile == nil then
			-- (A cold tile is built only when a candidate's corridor reaches the column: no road
			-- reaches one outside them all, so it is the raw terrain without a road's plan.)
			local near = false
			for _, link in linksOfTile(tx, tz) do
				if Roads.touches(link.ax, link.az, link.bx, link.bz, CORRIDOR, x, z, x, z) then
					near = true
					break
				end
			end
			if not near then
				return
			end
			tile = tileOf(tx, tz)
		end
		local built = tile :: Tile
		local list = built.buckets[((z - tz * TILE) // BUCKET) * BUCKETS + (x - tx * TILE) // BUCKET + 1]
		if #list == 0 then
			return
		end
		local seg = built.seg
		local best, bestT, at = REACH * REACH, 0, 0
		for _, s in list do
			local d2, t = Roads.segmentDistance2(x, z, seg[s], seg[s + 1], seg[s + 2], seg[s + 3])
			if d2 < best then
				best, bestT, at = d2, t, s
			end
		end
		if at == 0 then
			return
		end
		mRoad = true
		mRoadD = sqrt(best)
		mRoadY = seg[at + 4] + (seg[at + 5] - seg[at + 4]) * bestT
		local dx, dz = seg[at + 2] - seg[at], seg[at + 3] - seg[at + 1]
		mRoadAlong = seg[at + 6] + sqrt(dx * dx + dz * dz) * bestT
		mRoadO = built.plans[seg[at + 7]].o
	end

	--[[ The wrapper ]]

	local function height(x: number, z: number, level: number): (number, number, number, number)
		local y, u, s, river = raw.height(x, z, level)
		local tx, tz = x // TILE, z // TILE
		local c = classes[cellKey(tx, tz)] or classOf(tx, tz)
		if c == 0 then
			return y, u, s, river
		end
		lookupCity(x, z)
		local w, target = mWeight, if mPlan then mPlan.y else 0
		if w < 1 and level <= CUT_LEVELS then
			lookupRoad(x, z, tx, tz)
			if mRoad then
				local d = mRoadD
				local wr = if d <= BAND then 1 else smoothstep(1 - (d - BAND) / roadCfg.Blend)
				if wr > w then
					w, target = wr, max(mRoadY, SEA + 1)
				end
			end
		end
		if w <= 0 then
			return y, u, s, river
		end
		return y + (target - y) * w, u, s, river * (1 - w)
	end

	local relief: Relief.Relief = { height = height, selector = raw.selector }

	local function surface(x: number, z: number, h: number, level: number): (number?, number?)
		local tx, tz = x // TILE, z // TILE
		local c = classes[cellKey(tx, tz)] or classOf(tx, tz)
		if c == 0 then
			return nil, nil
		end
		lookupCity(x, z)
		local plan = mPlan
		if plan and mDist <= 0 then
			return CityLayout.surface(plan, x, z)
		end
		if level > SURFACE_LEVELS or h <= SEA then
			return nil, nil
		end
		lookupRoad(x, z, tx, tz)
		if not mRoad or mRoadD > BAND then
			return nil, nil
		end
		if mRoadD <= HALF_WIDTH then
			local block = if mRoadD < 0.5 and mRoadAlong % 8 < 4 then LINE_YELLOW else ASPHALT
			return CityLayout.asphaltDecay(linkSalt, block, x, z, mRoadO)
		end
		return if CityLayout.roll(linkSalt, x, 3, z) < 0.5 then GRAVEL else COARSE_DIRT, GRAVEL
	end

	local function protects(x: number, z: number): boolean
		local tx, tz = x // TILE, z // TILE
		local c = classes[cellKey(tx, tz)] or classOf(tx, tz)
		if c == 0 then
			return false
		end
		lookupCity(x, z)
		if mPlan then
			return true
		end
		lookupRoad(x, z, tx, tz)
		return mRoad and mRoadD <= REACH
	end

	local function treeAllowed(x: number, z: number): boolean
		local tx, tz = x // TILE, z // TILE
		local c = classes[cellKey(tx, tz)] or classOf(tx, tz)
		if c == 0 then
			return true
		end
		lookupCity(x, z)
		local plan = mPlan
		if plan and mDist <= 0 then
			return CityLayout.treeAllowed(plan, x, z)
		end
		lookupRoad(x, z, tx, tz)
		return not (mRoad and mRoadD <= BAND + 2)
	end

	local function cityAt(x: number, z: number): number
		local e = cellAt(x // GRID, z // GRID).exist
		if not e then
			return 0
		end
		local dist = max(abs(x - e.x) - e.radius, abs(z - e.z) - e.radius)
		if dist <= 0 then
			return 1
		elseif dist >= MARGIN then
			return 0
		end
		return smoothstep(1 - dist / MARGIN)
	end

	--[[ Rectangle queries ]]

	local function blocked(minX: number, minZ: number, maxX: number, maxZ: number, yield: (() -> ())?): { number }
		-- (A planner that may yield passes its `yield`: a cold region's existence tests.)
		local w: Work? = if yield then { yield = yield, work = 0 } else nil
		local out: { number } = {}
		for gz = minZ // GRID, maxZ // GRID do
			for gx = minX // GRID, maxX // GRID do
				local x0, z0 = max(minX, gx * GRID), max(minZ, gz * GRID)
				local x1, z1 = min(maxX, gx * GRID + GRID - 1), min(maxZ, gz * GRID + GRID - 1)
				local e = cellAt(gx, gz, w).exist
				if e then
					local m = e.radius + MARGIN
					local bx0, bz0 = (e.x - m) // 32 * 32, (e.z - m) // 32 * 32
					local bx1, bz1 = (e.x + m) // 32 * 32 + 31, (e.z + m) // 32 * 32 + 31
					if bx0 <= x1 and bx1 >= x0 and bz0 <= z1 and bz1 >= z0 then
						table.insert(out, max(bx0, x0))
						table.insert(out, max(bz0, z0))
						table.insert(out, min(bx1, x1))
						table.insert(out, min(bz1, z1))
					end
				end
				-- (The cell's candidates when they are known, else only the pairs that may reach
				-- the rectangle: a planner's small one tests few cells.)
				local known = cellAt(gx, gz, w).candidates
				if known then
					for _, link in known do
						if Roads.touches(link.ax, link.az, link.bx, link.bz, CORRIDOR, x0, z0, x1, z1) then
							Roads.boxes(link.ax, link.az, link.bx, link.bz, CORRIDOR, x0, z0, x1, z1, out)
						end
					end
				elseif ROADS then
					walkCandidates(gx, gz, x0, z0, x1, z1, w, function(link: Link): boolean
						Roads.boxes(link.ax, link.az, link.bx, link.bz, CORRIDOR, x0, z0, x1, z1, out)
						return false
					end)
				end
			end
		end
		return out
	end

	-- The existing cities whose footprint grown by `grow` touches the rectangle.
	local function existsIn(minX: number, minZ: number, maxX: number, maxZ: number, grow: number, w: Work?): { Exist }
		local out: { Exist } = {}
		for gz = minZ // GRID, maxZ // GRID do
			for gx = minX // GRID, maxX // GRID do
				local e = cellAt(gx, gz, w).exist
				if e then
					local m = e.radius + grow
					if e.x - m <= maxX and e.x + m >= minX and e.z - m <= maxZ and e.z + m >= minZ then
						table.insert(out, e)
					end
				end
			end
		end
		return out
	end

	-- The built road plans touching the rectangle (each once).
	local function plansIn(minX: number, minZ: number, maxX: number, maxZ: number, w: Work?): { RoadPlan }
		local out: { RoadPlan } = {}
		local seen: { [number]: boolean } = {}
		for gz = minZ // GRID, maxZ // GRID do
			for gx = minX // GRID, maxX // GRID do
				for _, link in candidatesNear(gx, gz, w) do
					if
						not seen[link.id]
						and Roads.touches(link.ax, link.az, link.bx, link.bz, CORRIDOR, minX, minZ, maxX, maxZ)
					then
						seen[link.id] = true
						if not isLink(link, w) then
							continue
						end
						local plan = linkPlan(link, w)
						if not plan.rejected then
							table.insert(out, plan)
						end
					end
				end
			end
		end
		return out
	end

	local function sites(minX: number, minZ: number, maxX: number, maxZ: number, yield: (() -> ())?): { Site }
		local w: Work = { yield = yield, work = 0 }
		local out: { Site } = {}
		for _, e in existsIn(minX, minZ, maxX, maxZ, 0, w) do
			local plan = sitePlan(e, w)
			table.insert(out, { gx = e.gx, gz = e.gz, x = e.x, z = e.z, radius = e.radius, y = plan.y, salt = e.salt })
		end
		return out
	end

	local function roads(minX: number, minZ: number, maxX: number, maxZ: number, yield: (() -> ())?): { Segment }
		local w: Work = { yield = yield, work = 0 }
		local out: { Segment } = {}
		for _, plan in plansIn(minX, minZ, maxX, maxZ, w) do
			local px, pz, py = plan.x, plan.z, plan.y
			for j = 1, plan.count - 1 do
				local x0, z0, x1, z1 = px[j], pz[j], px[j + 1], pz[j + 1]
				if min(x0, x1) <= maxX and max(x0, x1) >= minX and min(z0, z1) <= maxZ and max(z0, z1) >= minZ then
					table.insert(
						out,
						{ x0 = x0, z0 = z0, x1 = x1, z1 = z1, y0 = py[j], y1 = py[j + 1], link = plan.id }
					)
				end
			end
		end
		return out
	end

	--[[ Road wrecks ]]

	--[[
		The wrecks on road `plan` reaching the rectangle: x0, z0, axis, salt per car (see the
		header and CityLayout.carCells).
	]]
	local function roadCars(plan: RoadPlan, minX: number, minZ: number, maxX: number, maxZ: number, out: { number })
		local chance = roadCfg.Cars * roadCfg.Step
		local px, pz, ps = plan.x, plan.z, plan.s
		local length = ps[plan.count]
		for j = 1, plan.count - 1 do
			local s = ps[j]
			if s < Roads.PIN or s > length - Roads.PIN then
				continue
			end
			local vx, vz = px[j], pz[j]
			if vx < minX - 8 or vx > maxX + 8 or vz < minZ - 8 or vz > maxZ + 8 then
				continue
			end
			local h = Hash.hash3(carSalt, plan.id % 4294967296, j, 0)
			if h / 4294967296 >= chance then
				continue
			end
			local dx, dz = px[j + 1] - vx, pz[j + 1] - vz
			local x0, z0, axis
			if abs(dx) >= abs(dz) then
				-- Along x, in the right lane (south of an eastward road).
				axis = 1
				x0 = floor(vx) - 2
				z0 = if dx >= 0 then floor(vz) + 1 else floor(vz) - 2
			else
				axis = 0
				z0 = floor(vz) - 2
				x0 = if dz >= 0 then floor(vx) - 2 else floor(vx) + 1
			end
			local x1 = x0 + (if axis == 1 then 3 else 1)
			local z1 = z0 + (if axis == 1 then 1 else 3)
			if x0 <= maxX and x1 >= minX and z0 <= maxZ and z1 >= minZ then
				table.insert(out, x0)
				table.insert(out, z0)
				table.insert(out, axis)
				table.insert(out, h)
			end
		end
	end

	--[[ Writing ]]

	local function write(args: WriteArgs, yield: (() -> ())?): (number, number)
		local level = args.level
		if level > LOD_LEVELS then
			return huge, 0
		end
		-- The plans and their lots first, yielding as they are planned (a far node over a city
		-- plans a hundred lots: some 4 ms), then the writing, which never yields
		-- (CityLayout.begin).
		local x0, z0, x1, z1 = CityLayout.span(level, args.originX, args.originZ)
		local w: Work = { yield = yield, work = 0 }
		local plans: { CityLayout.Plan } = {}
		local lots: { CityLayout.Plan | CityLayout.Lot } = {}
		for _, e in existsIn(x0, z0, x1, z1, 0, w) do
			local plan = sitePlan(e, w)
			table.insert(plans, plan)
			local n = plan.n
			for pv = max(0, (z0 - plan.z0) // 32), min(n - 1, (z1 - plan.z0) // 32) do
				for pu = max(0, (x0 - plan.x0) // 32), min(n - 1, (x1 - plan.x0) // 32) do
					local lot = CityLayout.lot(plan, pu, pv)
					if level >= 3 then
						for _, b in lot.buildings do
							CityLayout.envelope(b)
						end
					end
					table.insert(lots, plan)
					table.insert(lots, lot)
					spend(w, LOT_WORK)
				end
			end
		end
		local roadPlans = if level == 0 and ROADS then plansIn(x0, z0, x1, z1, w) else nil
		CityLayout.begin(args.data, args.cells, level, args.originX, args.originZ)
		for k = 1, #lots, 2 do
			CityLayout.writeLot(lots[k] :: CityLayout.Plan, lots[k + 1] :: CityLayout.Lot)
		end
		for _, plan in plans do
			CityLayout.writeStreetCars(plan)
		end
		if roadPlans then
			-- Road wrecks, on each column's own ground (`heights`: the padded columns' first air).
			local cars: { number } = {}
			for _, plan in roadPlans do
				roadCars(plan, x0, z0, x1, z1, cars)
			end
			local heights = args.heights
			local P = ChunkLayout.PADDED
			for k = 1, #cars, 4 do
				CityLayout.carCells(cars[k], cars[k + 1], cars[k + 2], cars[k + 3], function(x, dy, z, block)
					if x >= x0 and x <= x1 and z >= z0 and z <= z1 then
						CityLayout.putBlock(x, heights[(z - z0) * P + (x - x0) + 1] + dy, z, block)
					end
				end)
			end
		end
		return CityLayout.finish()
	end

	local function top(level: number, originX: number, originZ: number): number?
		if level > LOD_LEVELS then
			return nil
		end
		local step = ChunkLayout.steps(level)
		local span = ChunkLayout.SIZE * step
		local x0, z0 = originX - step, originZ - step
		local x1, z1 = originX + span + step - 1, originZ + span + step - 1
		local best: number? = nil
		for _, e in existsIn(x0, z0, x1, z1, 0) do
			best = max(best or 0, CityLayout.topIn(sitePlan(e), x0, z0, x1, z1))
		end
		return best
	end

	--[[ Containers ]]

	-- Calls visit(x, y, z, block, table) for every container of the cities and roads in the
	-- rectangle.
	local function containersIn(
		minX: number,
		minZ: number,
		maxX: number,
		maxZ: number,
		w: Work?,
		visit: (x: number, y: number, z: number, block: number, loot: string) -> ()
	)
		local function onLot()
			spend(w, LOT_WORK)
		end
		for _, e in existsIn(minX, minZ, maxX, maxZ, 0, w) do
			CityLayout.containersIn(sitePlan(e, w), minX, minZ, maxX, maxZ, visit, onLot)
		end
		if ROADS then
			local cars: { number } = {}
			for _, plan in plansIn(minX, minZ, maxX, maxZ, w) do
				roadCars(plan, minX, minZ, maxX, maxZ, cars)
			end
			for k = 1, #cars, 4 do
				local cx, cz = CityLayout.carCells(cars[k], cars[k + 1], cars[k + 2], cars[k + 3], nil)
				if cx and cz and cx >= minX and cx <= maxX and cz >= minZ and cz <= maxZ then
					-- (On the road's own ground: the wrapped height there.)
					visit(cx, clampHeight((height(cx, cz, 0))), cz, CRATE, "car")
				end
			end
		end
	end

	local function container(x: number, y: number, z: number): { StructureGen.ContainerItem }?
		local found: string? = nil
		containersIn(x, z, x, z, nil, function(cx: number, cy: number, cz: number, _block: number, loot: string)
			if cx == x and cy == y and cz == z then
				found = loot
			end
		end)
		if found == nil then
			return nil
		end
		return ScavengeLoot.roll(found, lootSalt, x, y, z)
	end

	local function poiBlocks(
		minX: number,
		minZ: number,
		maxX: number,
		maxZ: number,
		lut: buffer,
		out: { number },
		yield: (() -> ())?
	)
		local w: Work = { yield = yield, work = 0 }
		containersIn(minX, minZ, maxX, maxZ, w, function(x: number, y: number, z: number, block: number, _loot: string)
			if buffer.readu8(lut, block) ~= 0 then
				table.insert(out, x)
				table.insert(out, y)
				table.insert(out, z)
				table.insert(out, block)
			end
		end)
	end

	local function bunkerSpots(minX: number, minZ: number, maxX: number, maxZ: number, yield: (() -> ())?): { number }
		local w: Work = { yield = yield, work = 0 }
		local out: { number } = {}
		for _, e in existsIn(minX, minZ, maxX, maxZ, 0, w) do
			local plan = sitePlan(e, w)
			for i, _ in plan.sheds do
				local pu, pv = (i - 1) % plan.n, (i - 1) // plan.n
				for _, b in CityLayout.lot(plan, pu, pv).buildings do
					local hx, hz = b.hatchX, b.hatchZ
					if hx and hz and hx >= minX and hx <= maxX and hz >= minZ and hz <= maxZ then
						table.insert(out, hx)
						table.insert(out, plan.y)
						table.insert(out, hz)
					end
				end
			end
		end
		return out
	end

	--[[ Warming ]]

	--[[
		Warms the caches for the rectangle: what the wrapper and the other column queries need there
		(the tiles touching it whose candidates' corridors reach it, their links (whose cities'
		choices look LinkCells cells further), sites and road plans) and, with `planners`, what the
		planners' `blocked` asks for around it too (the candidate links of every cell one further
		out, and every cell within 2 LinkCells: whatever a query near the rectangle may test).
		Without `planners` (the spawn's candidates) only the cells those need are tested.
	]]
	local function warm(minX: number, minZ: number, maxX: number, maxZ: number, w: Work, planners: boolean)
		local around = if planners then 1 else 0
		local gx0, gz0, gx1, gz1 = minX // GRID, minZ // GRID, maxX // GRID, maxZ // GRID
		if planners then
			local reach = if ROADS then max(2 * LINK, LINK + around) else around
			for gz = gz0 - reach, gz1 + reach do
				for gx = gx0 - reach, gx1 + reach do
					cellAt(gx, gz, w)
				end
			end
		end
		for gz = gz0 - around, gz1 + around do
			for gx = gx0 - around, gx1 + around do
				candidatesNear(gx, gz, w)
			end
		end
		for tz = minZ // TILE, maxZ // TILE do
			for tx = minX // TILE, maxX // TILE do
				if classOf(tx, tz, w) == 0 then
					continue
				end
				local x0, z0 = tx * TILE, tz * TILE
				local e = cellAt(x0 // GRID, z0 // GRID, w).exist
				if e then
					local m = e.radius + MARGIN
					if e.x - m <= x0 + TILE - 1 and e.x + m >= x0 and e.z - m <= z0 + TILE - 1 and e.z + m >= z0 then
						sitePlan(e, w)
					end
				end
				-- (Its segments when a candidate's corridor reaches the rectangle there: elsewhere the
				-- wrapper needs none. The link plans' cities too: a road's ends are pinned to their
				-- plateaus.)
				local rx0, rz0 = max(minX, x0), max(minZ, z0)
				local rx1, rz1 = min(maxX, x0 + TILE - 1), min(maxZ, z0 + TILE - 1)
				for _, link in candidatesNear(x0 // GRID, z0 // GRID, w) do
					if Roads.touches(link.ax, link.az, link.bx, link.bz, CORRIDOR, rx0, rz0, rx1, rz1) then
						tileOf(tx, tz, w)
						break
					end
				end
			end
		end
	end

	local function prepare(minX: number, minZ: number, maxX: number, maxZ: number, yield: (() -> ())?)
		warm(minX, minZ, maxX, maxZ, { yield = yield, work = 0 }, true)
	end

	--[[ Spawn ]]

	local function spawnShift(
		x: number,
		z: number,
		ok: (x: number, z: number) -> boolean,
		yield: (() -> ())?
	): (number, number)
		local w: Work = { yield = yield, work = 0 }
		local best: Exist? = nil
		local bestD = SPAWN_RANGE
		for gz = (z - SPAWN_RANGE) // GRID, (z + SPAWN_RANGE) // GRID do
			for gx = (x - SPAWN_RANGE) // GRID, (x + SPAWN_RANGE) // GRID do
				local e = cellAt(gx, gz, w).exist
				if e then
					local d = sqrt((e.x - x) ^ 2 + (e.z - z) ^ 2)
					if d < bestD then
						best, bestD = e, d
					end
				end
			end
		end
		local e = best
		if e == nil then
			return x, z
		end
		local far = e.radius + MARGIN + SPAWN_FAR
		local bearing = math.atan2(z - e.z, x - e.x)
		for distance = e.radius + MARGIN + SPAWN_NEAR, far, SPAWN_STEP do
			for k = 0, 6 do
				local turn = if k == 0 then 0 elseif k % 2 == 1 then (k + 1) // 2 else -(k // 2)
				local angle = bearing + turn * SPAWN_BEARING
				local cx = floor(e.x + distance * math.cos(angle))
				local cz = floor(e.z + distance * math.sin(angle))
				-- (What `ok` reads of the wrapped terrain: the candidate's tile.)
				warm(cx - 2, cz - 2, cx + 2, cz + 2, w, false)
				if ok(cx, cz) then
					return cx, cz
				end
				if yield then
					yield()
				end
			end
		end
		return x, z
	end

	--[[ /locate ]]

	local function locateKind(): Locate.Kind
		return {
			id = "city",
			grid = GRID,
			-- (A city's centre lies in its cell.)
			slack = 0,
			rings = math.ceil(Config.Locate.Radius.city / GRID),
			showY = false,
			-- The existence test (a cached cell is read, never added: a search leaves the caches
			-- to the chunks).
			probe = function(gx: number, gz: number): (number?, number, number)
				local cell: Cell? = getCell(cellKey(gx, gz))
				local e = if cell then cell.exist else existence(gx, gz, nil)
				if e then
					return e.x, e.z, 0
				end
				return nil, 0, 0
			end,
		}
	end

	local function planAt(x: number, z: number): CityLayout.Plan?
		local e = cellAt(x // GRID, z // GRID).exist
		if e and abs(x - e.x) <= e.radius and abs(z - e.z) <= e.radius then
			return sitePlan(e)
		end
		return nil
	end

	return {
		relief = relief,
		prepare = prepare,
		surface = surface,
		blocked = blocked,
		protects = protects,
		treeAllowed = treeAllowed,
		top = top,
		write = write,
		container = container,
		poiBlocks = poiBlocks,
		locateKind = locateKind,
		cityAt = cityAt,
		sites = sites,
		roads = roads,
		bunkerSpots = bunkerSpots,
		spawnShift = spawnShift,
		built = function(): (number, number, number, number)
			return builtCells, builtSites, builtLinks, builtTiles
		end,
		planAt = planAt,
	}
end

--[[ Samples (the debug structures world) ]]

-- The sample town's parcels, north to south and west to east: a kind and its loot table each.
local SAMPLE: { { string } } = {
	{ "office", "" },
	{ "apartment", "" },
	{ "plaza", "" },
	{ "rubble", "" },
	{ "shop", "grocery" },
	{ "shop", "pharmacy" },
	{ "shop", "hardware" },
	{ "shop", "office" },
	{ "police", "police" },
	{ "fire", "fire_station" },
	{ "houses", "" },
	{ "houses", "" },
	{ "park", "" },
	{ "parking", "" },
	{ "houses", "" },
	{ "apartment", "" },
}
-- The sample's houses parcel (index into SAMPLE) whose first lot is a bunker shed.
local SAMPLE_SHED = 12

--[[
	A fixed town for the debug structures world (Generation/DebugWorlds): half 2 (4 x 4 parcels,
	R = 67) centred on (x, z), its plateau's first air at y, Config.Cities.Overgrowth's overgrowth,
	one parcel of every kind (a downtown office, apartments, a plaza, rubble, the four shops, the
	police and fire stations, houses, a park, a parking lot) and a bunker shed on the twelfth. Its
	ruin, doors, windows, decay and loot follow from its position as any city's do from its site.
]]
function Cities.sample(x: number, z: number, y: number): CityLayout.Plan
	local half = 2
	local site: CityLayout.Site = {
		gx = 0,
		gz = 0,
		x = x,
		z = z,
		half = half,
		radius = half * 32 + 3,
		salt = Hash.hash3(0x5A3E1E, x, y, z),
	}
	local plan = CityLayout.plan(site, y, Config.Cities.Overgrowth)
	for i, entry in SAMPLE do
		plan.kinds[i], plan.loots[i] = entry[1], entry[2]
	end
	-- (The office as downtown's: tall, its floors above FullFloors a ring of rooms round a core.)
	plan.dists[1] = 0.1
	plan.sheds = { [SAMPLE_SHED] = 1 }
	return plan
end

return Cities
