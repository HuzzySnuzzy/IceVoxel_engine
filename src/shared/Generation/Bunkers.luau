--!strict
--!native
--[[
	Hidden bunkers (the zombie apocalypse's safe havens): concrete rooms of cave air under a steel
	hatch over a ladder shaft, in the wild (a candidate per Config.Bunkers.Grid cell, decided from
	the raw terrain: Generation/TerrainGenerator hands over the raw height, biome and river) and
	under the cities' sheds (Generation/Cities `bunkerSpots`). Their lamps and cobwebs are cave
	twins, so a hidden bunker costs nothing to draw until a player finds it; their loot is
	Generation/ScavengeLoot's. Full detail (LOD 0) chunks only, like the mineshafts, whose pattern
	this follows (plans from hashes and the terrain, an LRU of grid cells, yields, cell rules that
	keep hidden caves working and a chunk's padding equal to its neighbour's core).

	  plans       every bunker whose bounds touch a rectangle (`yield` while plans are built)
	  keepOut     x0, z0, x1, z1: the hatch collars, which trees and surface caves keep out of
	              (TerrainGenerator asks at the levels that grow trees or carve surface caves,
	              handing its yield: a cold plan search reads the terrain and the blocked areas)
	  boxes       x0, y0, z0, x1, y1, z1: what underground lava lakes keep clear of
	  write       the plans into a padded full detail chunk after the mineshafts: the lowest cell
	              written (huge: none), the first empty cell above, and the cave lattice
	  container   a bunker container's loot, nil: none there
	  poiBlocks   the containers and hatches in a rectangle whose blocks `lut` marks
	  locateKind  /locate structure bunker's kind (Generation/Locate)
	  built       plans built (not served from a cache) so far

	Wild sites (Config.Bunkers). One candidate per Grid x Grid cell (768: a cell is 0.59 km²),
	kept with Chance (0.35), from Hash.rng(hash3(salt, gx, 0, gz)); then up to Candidates (24)
	hatch columns, each a core column (2..13) of a chunk lying INSET (64) blocks or more inside
	the cell (no neighbour holds the shaft, its walls or the collar in its padding, and no LOD
	seam meets them). The first that passes, on the raw terrain, is the hatch:
	  * the 5 x 5 collar is dry land (above sea level + 2, no river) within a block of the
	    centre's height; no surface cave opens there (Terrain.carvesTop);
	  * its layout (below, drawn from the column's own hash: every chunk agrees whichever
	    candidate it reached first) keeps COVER (3) blocks of ground over every room's shell at
	    the points of a world-aligned SAMPLE (4) block lattice within SAMPLE / 2 of its
	    footprint, and stays above the caves' lava sea (Config.Caves.LavaLevel);
	  * nothing Terrain.blocked lists (library pieces, oil wells, lava and water lakes,
	    puddles, the cities' blocked area) comes within MARGIN (2) blocks of its bounds (asked
	    once, for the bounds grown by MARGIN + QUERY_PAD (2): a planner lists a box grown by its
	    own margin only when the query reaches the box itself);
	  * then no mineshaft piece or entrance shaft (Terrain.mineshafts, Mineshafts `boxes`) comes
	    within MARGIN of a room's shell or of the shaft's column, in three dimensions (a
	    mineshaft deep under a bunker leaves it be), asked last: a cold mineshaft plan is the
	    dearest lookup there is;
	  * its bounds keep SpawnClearance (64) blocks from the spawn.
	  A cell keeps a false when no candidate passes (a sea, a mountain range, a town). A
	  rectangle asks for the cells whose hatches' bounds may reach it (a chunk: one each way, two
	  within REACH - INSET of a cell's side). Measured in Lune: 0.42-0.61 per km² on three
	  seeds' 64 km² (0.38-0.61 on five; a dry world would get 0.59); a cold plan search's
	  longest stretch between yields under 1 ms; a cold search about a plain chunk and a quarter
	  (it decides the mineshafts and surface caves around its hatch, each about half a chunk).
	City sites: `cities.bunkerSpots` (1-2 per city in shed lots, Config.Cities.Bunkers): the hatch
	at the shed floor's (x, H, z), the rooms CITY_DEPTH (12) under it. A shed may stand only 10
	blocks inside its town's edge (Generation/CityLayout's outer lots), and rooms on alternating
	sides reach 13 or more across the corridor, so the drawn layout is tried in turn: the most
	rooms first (its extra rooms dropped, never the bunks or the storeroom), at each count the
	rooms on alternating sides, then all on one side (the side away from a near edge), the
	corridor heading north, east or west (from the drawn one), the first side swapped. The first
	whose bounds (`layoutBounds`: no rooms built) lie within REACH and inside the town's footprint
	(`cityAt` 1 at their corners grown by GUARD + 1: the footprint is levelled flat to H, so the
	cover holds without asking the relief), keep clear of the other sheds' airlocks and collars,
	of the whole bunkers of the sheds whose hatch comes first (in x, then z: they keep their
	layouts) and of the spawn, and leave every later shed near it a layout of its own (when it
	has any), is the bunker; else the first that fits; none fits: no bunker there. Each layout
	tried counts a lookup (a few microseconds) towards the yields. Measured with fakes of D's
	smallest town (radius 35): every lot's shed gets a bunker, and both sheds of every pair of
	lots in two parcels (D's two sheds); under D's own towns, every shed of 104 towns on five
	seeds (123 sheds). No corridor heads south, so a lone shed 10-14 blocks inside the north edge
	puts every room on the corridor's south side and keeps 3-5 of them (of D's three town sizes:
	93, 193 and 125 of 411 sheds); two sheds close together may leave one only its bunks and
	storeroom (21 of the 192 bunkers of the small town's pairs, 1 of D's 123).

	Layout (Hash.rng of the hatch column, every draw in a fixed order):
	  * the floor (the cell a player stands in) Depth (9..16) blocks under the hatch's height
	    (the first air), never below Config.Caves.LavaLevel + 1 (the shell's floor stays above
	    the lava sea, and 9 blocks over the bedrock);
	  * the airlock: 5 x 5 inside, 4 tall, under the shaft, which comes down by its south wall
	    (the ladder's: the open hatch stands up against its cell's north side, across the shaft
	    from the ladder, so a climber pressed against the ladder rises past it and out);
	  * the corridor, 3 wide and 3 tall inside, from the airlock's north, east or west wall,
	    START + STEP x ceil(rooms / 2) (10 + 6 x ...) long at least;
	  * Rooms (3..6) along it, alternating sides from a drawn first side (a city bunker's may all
	    go on one side, above), each against the last on its side with a one cell wall between:
	    exactly one bunk room (7 along x 9 deep) and one storeroom (7 x 7), then by weight a
	    medical room (5 x 7, weight 3), a generator room (7 x 7, 2, one at most), an armory
	    (5 x 7, 1, one at most) or a mess (7 x 9, 2), their order along the corridor shuffled.
	    Doorways are 1 x 2 openings in the corridor's wall (no doors: a door in cave air would be
	    drawn while caves are hidden);
	  * the shell: Concrete one block thick on every side (CrackedConcrete 10%; MossyConcrete
	    35% when overrun), the floor Concrete or SmoothStone; inside, cave air;
	  * furnishings, all opaque full blocks (nothing to twin): bunks (a Planks base under a
	    WhiteWool mattress, two cells long, three along each side wall), the storeroom's 3-5
	    Supply Crates and a Chest (bunker_storage), the medical room's two Medicine Cabinets on
	    the wall (bunker_medical) and a wool cot, the generator room's 2 x 2 x 2 IronBlock and
	    RustyMetal machine, Furnace, two CoalBlocks and a Supply Crate (bunker_generator), the
	    armory's two Chests (bunker_armory) and an iron rack, the mess's two Crafting Tables and
	    a Supply Crate (bunker_storage);
	  * lit (Lit, 0.8): a CaveCeilingLamp under the corridor's ceiling every LAMP_GAP (5) cells,
	    one in the airlock and in each room (two in the deep ones); an unlit bunker is dark,
	    and zombies may spawn in it: the lost ones;
	  * overrun (Overrun, 0.15): mossy shells, cave cobwebs under WEBS of the ceilings, half the
	    lamps gone, and Bone and RottenFlesh in the containers (their table rolled with another
	    salt).
	The shaft: the hatch (BunkerHatch, shut, lying on the ground) at the first air of its
	column; a plain Ladder (facing north, on the south wall) in every cell from the ground's top
	layer down to the airlock's floor; the shaft's walls Concrete from the airlock's ceiling up;
	the collar, the 8 columns around the hatch, Concrete or MossyConcrete flush with the ground
	(the ground above it cut level); grass and ferns (both halves of the tall ones) on 70% of
	the ring two blocks out where the soil takes them, to hide it; its 5 x 5 box keeps trees and
	surface caves away at every level they come in. Zombies never break the hatch (BlockList:
	no `zombieBreak`) and never dig down, so a shut bunker is a safe haven.

	Writing (TerrainGenerator, after the mineshafts; full detail only). Per plan: every room's
	shell, then every room's inside, the doorways, the furnishings, the lamps and cobwebs, then
	the shaft, hatch, collar and plants. Cell rules:
	  * a shell or inside cell is written only up to its column's limit (GUARD (2) blocks under
	    its own surface's top block and under its four neighbours' surfaces, Mineshafts'
	    `limitAt`): a room under a dip is cut off, never opened to the sky (the cover check
	    makes that rare); the shaft, its walls, the collar and the plants are not limited;
	  * a shell cell becomes concrete and an inside cell cave air whatever was there (rock,
	    cave air, a surface cave's air, ore, bedrock aside: nothing liquid lies there, since
	    lakes, wells and lava keep out of the blocked areas wild bunkers avoid and of the cities'
	    a city bunker lies in, the lava sea is below them and underground lava lakes keep off
	    `boxes`), so a bunker is sealed: no fluid ever borders its inside;
	  * furnishings go into the inside's cave air, lamps and cobwebs into it as cave twins
	    (cave air while caves are hidden: a hidden bunker draws nothing);
	  * every decision is the plan's and the column's own (its limit reads its neighbours'
	    heights: the chunk's padded heights, past them the generator's wrapped relief, as
	    TerrainGenerator samples its padding), so a chunk's padding equals its neighbour's core;
	    attached blocks (lamps, the ladder, plants) are checked at the end and taken away again
	    if what holds them went (a lamp under a ceiling cut off above a dip);
	  * every room's outer box and the shaft are marked in the cave lattice to be read cell by
	    cell (Caves.markRead), so World/SectionGraph follows the rooms; `write` returns the
	    lowest cell written with something neither opaque nor a cave cell (the ladder, the
	    hatch, plants and the collar's cut: TerrainGenerator lowers solidBelow to it) and one
	    above the highest cell written.

	Queries: `container` is ScavengeLoot.roll of the container's table at its position (salt
	Hash.hash2(seed, Hash.string("bunkers.loot"), 0xB0B5)); `poiBlocks` lists the containers
	and the hatches from the plans; `locateKind` "bunker" walks the 768 grid: a cell's probe is
	its hash (a wild candidate) or a city in a city cell overlapping it (the cities' own locate
	probe), answered at the cell's centre with `spread` its half diagonal; the verify builds the
	cell's plan and the city bunkers whose hatch lies in it (yielding) and answers the hatch
	nearest the player, standing on it.
]]

local Config = require(script.Parent.Parent.Config)
local Blocks = require(script.Parent.Parent.Blocks)
local ChunkLayout = require(script.Parent.Parent.World.ChunkLayout)
local Hash = require(script.Parent.Parent.Util.Hash)
local Caves = require(script.Parent.Caves)
local Cities = require(script.Parent.Cities)
local Locate = require(script.Parent.Locate)
local ScavengeLoot = require(script.Parent.ScavengeLoot)
local StructureGen = require(script.Parent.StructureGen)

local SIZE = ChunkLayout.SIZE
local P = ChunkLayout.PADDED
local SEA = Config.SeaLevel
-- TerrainGenerator's room kept above the terrain: its heights are clamped to WorldHeight - this.
local STRUCTURE_ROOM = 32

-- Tuning --------------------------------------------------------------------------------------------
local AIRLOCK = 5 -- the airlock's inside, square (blocks)
local AIRLOCK_TALL = 4 -- and tall
local TALL = 3 -- the corridor's and every room's inside height
local START, STEP = 10, 6 -- the corridor is START + STEP x ceil(rooms / 2) long at least
local CITY_DEPTH = 12 -- a city bunker's floor under its hatch
local GUARD = 2 -- blocks kept between a written cell and the open above or beside it
local COVER = 3 -- blocks of ground over every shell at the cover lattice's points
local SAMPLE = 4 -- the cover lattice's spacing
local MARGIN = 2 -- wild bunkers keep this far from what Terrain.blocked and the mineshafts list
-- Terrain.blocked is asked for this much more than the bounds grown by MARGIN: a planner lists
-- a box grown by its own margin (2 at most: Lakes.PROTECT, Lava.PROTECT, OilWells.MARGIN,
-- Mineshafts' MARGIN) only when the query reaches the box itself.
local QUERY_PAD = 2
local INSET = 64 -- candidate hatches lie this far inside their cell
local REACH = 40 -- a plan's bounds lie within this many blocks of its hatch, every way
local CACHE = 64 -- grid cells (and city spots) kept per generator
local PAUSE = 64 -- terrain lookups a plan build makes between two yields (`blocked` and `mineshafts`: all 64)
local CRACKED = 0.1 -- shell cells cracked
local MOSSY = 0.35 -- shell cells mossy in an overrun bunker
local COLLAR_MOSS = 0.4 -- collar cells mossy
local PLANTS = 0.7 -- the ring around the collar's cells with a plant
local WEBS = 0.12 -- an overrun bunker's ceiling cells with a cobweb under them
local LAMP_GAP = 5 -- a corridor lamp every this many cells
local MISSING = 0.5 -- an overrun bunker's lamps gone
local KEEP_OUT = 2 -- trees and surface caves keep this far from the hatch (the 5 x 5 collar box)

local min, max, abs = math.min, math.max, math.abs
local huge = math.huge
local readu8 = buffer.readu8
local readu16 = buffer.readu16
local writeu16 = buffer.writeu16
local bxor = bit32.bxor
local rshift = bit32.rshift

local id = Blocks.id
local AIR, CAVE_AIR, BEDROCK = Blocks.AIR, Blocks.CAVE_AIR, id.Bedrock
local CONCRETE, CRACKED_CONCRETE, MOSSY_CONCRETE = id.Concrete, id.CrackedConcrete, id.MossyConcrete
local SMOOTH_STONE, PLANKS, WOOL = id.SmoothStone, id.Planks, id.WhiteWool
local CHEST, CRATE, CABINET = id.Chest, id.SupplyCrate, id.MedicineCabinet
local IRON, RUSTY, FURNACE, COAL, TABLE = id.IronBlock, id.RustyMetal, id.Furnace, id.CoalBlock, id.CraftingTable
local LAMP = Blocks.caveTwinFor(id.CeilingLamp) :: number
local WEB = Blocks.caveTwinFor(id.Cobweb) :: number
local HATCH = id.BunkerHatch
-- The plain ladder on the shaft's south wall (it faces north, away from it): the open hatch
-- stands up against its cell's north side, so a climber pressed against the ladder rises clear
-- of it.
local LADDER = id.Ladder
-- Concealing plants and their upper halves (0: a single plant), by cumulative share.
local PLANT_KINDS = {
	{ id.ShortGrass, 0, 0.4 },
	{ id.Fern, 0, 0.6 },
	{ id.TallGrass, id.TallGrassTop, 0.85 },
	{ id.LargeFern, id.LargeFernTop, 1 },
}

local STURDY = Blocks.sturdyLut
local CULL_HIDDEN = Blocks.cullLutHiddenCaves
-- 1 for blocks that hang on a neighbour (BlockList `support`).
local ATTACHED = buffer.create(Blocks.count)
for blockId = 0, Blocks.count - 1 do
	if Blocks.get(blockId).support ~= nil then
		buffer.writeu8(ATTACHED, blockId, 1)
	end
end
assert(Blocks.supportOffset(LADDER) ~= nil, "Bunkers: the ladder hangs on a wall")
do
	local _, _, dz = Blocks.supportOffset(LADDER)
	assert(dz == 1, "Bunkers: the plain Ladder hangs on its south wall")
end

-- A cell's u32 hash (Mineshafts' and CaveDecor's: exact for |x|, |z| < 2^26), salted.
local function cellHash(salt: number, x: number, y: number, z: number): number
	local h = bxor(salt, (x * 0x3243F6B + z * 0x2B7E151 + y * 0x1B873) % 4294967296)
	h = bxor(h, rshift(h, 16))
	h = ((h % 65536) * 0x85EBCA6B + (h // 65536) * 0xCA6B % 65536 * 65536) % 4294967296
	h = bxor(h, rshift(h, 13))
	h = ((h % 65536) * 0xC2B2AE35 + (h // 65536) * 0xAE35 % 65536 * 65536) % 4294967296
	return bxor(h, rshift(h, 16))
end
-- [0, 1) from a cell's hash.
local function roll(salt: number, x: number, y: number, z: number): number
	return cellHash(salt, x, y, z) / 4294967296
end
-- Salts of the per cell decisions (xored into a plan's salt).
local S_SHELL, S_COLLAR, S_PLANT, S_WEB, S_LAMP, S_MACHINE = 0x5E11, 0xC011, 0x91A7, 0x7EB, 0x1A3F, 0x6E7
-- The overrun loot's salt (xored into the loot salt) and its rolls.
local S_OVERRUN = 0x0BE5

--[[ Rooms ]]

-- The loot tables of the containers (Room `containers` keep the index).
local TABLES = { "bunker_storage", "bunker_medical", "bunker_armory", "bunker_generator" }
local T_STORAGE, T_MEDICAL, T_ARMORY, T_GENERATOR = 1, 2, 3, 4

-- Room kinds: inside size along the corridor and deep from it; the extra rooms' weights and caps.
local KINDS: { [string]: { along: number, deep: number, weight: number, most: number } } = {
	bunks = { along = 7, deep = 9, weight = 0, most = 1 },
	storage = { along = 7, deep = 7, weight = 0, most = 1 },
	medical = { along = 5, deep = 7, weight = 3, most = 99 },
	generator = { along = 7, deep = 7, weight = 2, most = 1 },
	armory = { along = 5, deep = 7, weight = 1, most = 1 },
	mess = { along = 7, deep = 9, weight = 2, most = 99 },
}
local EXTRAS = { "medical", "generator", "armory", "mess" }

--[[
	A room of a bunker: its kind ("airlock", "corridor", "bunks", "storage", "medical",
	"generator", "armory", "mess"), its outer box (x0, y0, z0, x1, y1, z1, the shell included)
	and inside (`inner`), the lower cells of its doorways (x, y, z each, two tall: the opening
	into the corridor), its furnishings (`blocks`: x, y, z, block each), its containers (x, y, z,
	block, loot table index into TABLES each) and its lamps (x, y, z each: those the plan keeps).
]]
export type Room = {
	kind: string,
	box: { number },
	inner: { number },
	doors: { number },
	blocks: { number },
	containers: { number },
	lamps: { number },
}

--[[
	A bunker: its grid cell (the Grid cell its hatch lies in), the hatch (x, y, z: the column and
	its first air; `hatch` the same three), its salt (cell hashes), rooms (the airlock and the
	corridor first), the bounds of every cell it may write (x0, y0, z0, x1, y1, z1), whether it is
	lit and overrun, the floor (the cell a player stands in), the floor's block, the corridor's
	heading ("North", "East", "West") and whether a city's shed holds it. Read only.
]]
export type Plan = {
	cellX: number,
	cellZ: number,
	x: number,
	y: number,
	z: number,
	salt: number,
	rooms: { Room },
	bounds: { number },
	hatch: { number },
	lit: boolean,
	overrun: boolean,
	floor: number,
	floorBlock: number,
	dir: string,
	city: boolean,
}
export type Bunkers = {
	plans: (minX: number, minZ: number, maxX: number, maxZ: number, yield: (() -> ())?) -> { Plan },
	keepOut: (minX: number, minZ: number, maxX: number, maxZ: number, yield: (() -> ())?) -> { number },
	boxes: (minX: number, minZ: number, maxX: number, maxZ: number) -> { number },
	write: (
		plans: { Plan },
		data: buffer,
		originX: number,
		originZ: number,
		cells: number,
		heights: { number },
		carved: Caves.Carved?
	) -> (number, number, Caves.Carved?),
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
	built: () -> number,
}

-- The raw terrain (Generation/TerrainGenerator's: the raw relief's height, biome and river), what
-- wild bunkers keep out of (`blocked`: x0, z0, x1, z1 boxes: library pieces, wells, lakes,
-- puddles and the cities' blocked area; `yield` handed on), the spawn, where surface caves
-- open, and the cities (their sheds' spots, footprints and wrapped relief; nil: none).
-- `mineshafts`: the mineshafts' boxes (x0, y0, z0, x1, y1, z1: Mineshafts `boxes`, `yield`
-- handed on), checked in three dimensions and only once `blocked` is clear (nil: none, or
-- `blocked` lists them flat). `surface`: the height of a column as the generator's chunks have
-- it (nil: the cities' wrapped relief, clamped as TerrainGenerator clamps it), for the columns
-- just past a chunk's padding.
export type Terrain = {
	height: (x: number, z: number) -> number,
	biome: (x: number, z: number) -> number,
	river: (x: number, z: number) -> number,
	blocked: (minX: number, minZ: number, maxX: number, maxZ: number, yield: (() -> ())?) -> { number },
	spawn: () -> (number, number),
	carvesTop: (x: number, z: number, yield: (() -> ())?) -> boolean,
	cities: Cities.Cities?,
	mineshafts: ((minX: number, minZ: number, maxX: number, maxZ: number, yield: (() -> ())?) -> { number })?,
	surface: ((x: number, z: number) -> number)?,
}

-- A fixed list of plans in place of the grid and the cities (the debug structures world): those
-- whose bounds touch a block rectangle (inclusive).
export type Layout = (minX: number, minZ: number, maxX: number, maxZ: number) -> { Plan }

local Bunkers = {}

Bunkers.GUARD = GUARD
Bunkers.COVER = COVER
Bunkers.SAMPLE = SAMPLE
Bunkers.MARGIN = MARGIN
Bunkers.REACH = REACH
Bunkers.CACHE = CACHE
Bunkers.PAUSE = PAUSE
Bunkers.INSET = INSET
Bunkers.CITY_DEPTH = CITY_DEPTH
Bunkers.AIRLOCK_TALL = AIRLOCK_TALL
Bunkers.TALL = TALL
Bunkers.TABLES = TABLES
Bunkers.KINDS = KINDS

--[[ Layouts ]]

-- The corridor's headings: forward (fx, fz), across (rx, rz: a room's side +1 is this way) and
-- its first cell, the airlock's wall, from the hatch (ox, oz). The hatch is the airlock's south
-- row's middle cell: the airlock's inside runs hx - 2..hx + 2, hz - 4..hz.
type Dir = { name: string, fx: number, fz: number, rx: number, rz: number, ox: number, oz: number }
local DIRS: { Dir } = {
	{ name = "North", fx = 0, fz = -1, rx = 1, rz = 0, ox = 0, oz = -AIRLOCK },
	{ name = "East", fx = 1, fz = 0, rx = 0, rz = 1, ox = 3, oz = -2 },
	{ name = "West", fx = -1, fz = 0, rx = 0, rz = 1, ox = -3, oz = -2 },
}

-- What a layout is drawn from (before its geometry): the floor, the heading (index into DIRS),
-- the room kinds (the bunks, the storeroom, then the extras), their order along the corridor
-- (indices into `kinds`), the first room's side, whether the rooms alternate sides (false: every
-- room on `side`, a city bunker's way to keep off a nearby edge of its town), lit, overrun, the
-- floor's block, crates.
type Draw = {
	floor: number,
	dir: number,
	kinds: { string },
	order: { number },
	side: number,
	alternate: boolean,
	lit: boolean,
	overrun: boolean,
	floorBlock: number,
	crates: number,
}

-- The lowest floor (the cell a player stands in): the shell's floor stays above the lava sea.
local function lowestFloor(): number
	return max(Config.Caves.LavaLevel, 9) + 1
end

-- The draws of the layout of a hatch at (x, h, z), `depth` its floor under the hatch (nil: drawn
-- from Depth).
local function drawLayout(salt: number, x: number, h: number, z: number, depth: number?): Draw
	local cfg = Config.Bunkers
	local rng = Hash.rng(Hash.hash3(salt, x, 0x1A, z))
	local d = rng:int(cfg.Depth[1], cfg.Depth[2])
	local dir = rng:int(1, #DIRS)
	local count = rng:int(cfg.Rooms[1], cfg.Rooms[2])
	local kinds = { "bunks", "storage" }
	local taken: { [string]: number } = {}
	for _ = 3, count do
		local total = 0
		for _, kind in EXTRAS do
			local k = KINDS[kind]
			if (taken[kind] or 0) < k.most then
				total += k.weight
			end
		end
		local pick = rng:int(0, total - 1)
		for _, kind in EXTRAS do
			local k = KINDS[kind]
			if (taken[kind] or 0) < k.most then
				pick -= k.weight
				if pick < 0 then
					table.insert(kinds, kind)
					taken[kind] = (taken[kind] or 0) + 1
					break
				end
			end
		end
	end
	local order: { number } = {}
	for i = 1, #kinds do
		order[i] = i
	end
	for i = #order, 2, -1 do
		local j = rng:int(1, i)
		order[i], order[j] = order[j], order[i]
	end
	local side = if rng:int(0, 1) == 0 then 1 else -1
	local lit = rng:float() < cfg.Lit
	local overrun = rng:float() < cfg.Overrun
	local floorBlock = if rng:int(0, 1) == 0 then CONCRETE else SMOOTH_STONE
	local crates = rng:int(3, 5)
	return {
		floor = max(h - (depth or d), lowestFloor()),
		dir = dir,
		kinds = kinds,
		order = order,
		side = side,
		alternate = true,
		lit = lit,
		overrun = overrun,
		floorBlock = floorBlock,
		crates = crates,
	}
end

-- The draw with only its first `count` kinds (the bunks and the storeroom always stay), in the
-- same relative order.
local function shortened(draw: Draw, count: number): Draw
	local copy = table.clone(draw)
	copy.kinds = table.move(draw.kinds, 1, count, 1, {})
	local order: { number } = {}
	for _, i in draw.order do
		if i <= count then
			table.insert(order, i)
		end
	end
	copy.order = order
	return copy
end

-- A box (x0, y0, z0, x1, y1, z1) from two corners in any order.
local function boxOf(ax: number, ay: number, az: number, bx: number, by: number, bz: number): { number }
	return { min(ax, bx), min(ay, by), min(az, bz), max(ax, bx), max(ay, by), max(az, bz) }
end

local function grown(b: { number }, n: number): { number }
	return { b[1] - n, b[2] - n, b[3] - n, b[4] + n, b[5] + n, b[6] + n }
end

local function newRoom(kind: string, inner: { number }): Room
	return {
		kind = kind,
		box = grown(inner, 1),
		inner = inner,
		doors = {},
		blocks = {},
		containers = {},
		lamps = {},
	}
end

-- Bounds within REACH of the hatch's column (x, z), every way?
local function withinReach(bounds: { number }, x: number, z: number): boolean
	return bounds[1] >= x - REACH and bounds[4] <= x + REACH and bounds[3] >= z - REACH and bounds[6] <= z + REACH
end

-- Where a layout's rooms go along its corridor (their kinds, sides and first cells, in the
-- draw's order: each against the last on its side, a one cell wall between) and the corridor's
-- length.
type Place = { kind: string, side: number, a0: number }
local function placesOf(draw: Draw): ({ Place }, number)
	local nextA = { [1] = 1, [-1] = 1 }
	local placed: { Place } = {}
	for i, k in draw.order do
		local kind = draw.kinds[k]
		local s = if not draw.alternate or i % 2 == 1 then draw.side else -draw.side
		table.insert(placed, { kind = kind, side = s, a0 = nextA[s] })
		nextA[s] += KINDS[kind].along + 1
	end
	return placed, max(START + STEP * math.ceil(#draw.order / 2), nextA[1], nextA[-1])
end

--[[
	The bounds of the layout `draw` of a hatch at (hx, h, hz) (Plan `bounds`: every room's outer
	box, the shaft, the collar and the plants around it) without building its rooms, as cheap as
	a few table reads: what a city bunker's search tries its layouts by. `geometry`'s own.
]]
local function layoutBounds(hx: number, h: number, hz: number, draw: Draw): { number }
	local dir = DIRS[draw.dir]
	local fx, fz, rx, rz = dir.fx, dir.fz, dir.rx, dir.rz
	local cx0, cz0 = hx + dir.ox, hz + dir.oz
	local y0 = draw.floor
	-- The insides' footprint: the airlock's (the hatch is its south row's middle cell), then the
	-- corridor's and the rooms' (local corners: along a, across c).
	local x0, z0, x1, z1 = hx - 2, hz - AIRLOCK + 1, hx + 2, hz
	local function add(a0: number, c0: number, a1: number, c1: number)
		local ax, az = cx0 + a0 * fx + c0 * rx, cz0 + a0 * fz + c0 * rz
		local bx, bz = cx0 + a1 * fx + c1 * rx, cz0 + a1 * fz + c1 * rz
		x0, x1 = min(x0, ax, bx), max(x1, ax, bx)
		z0, z1 = min(z0, az, bz), max(z1, az, bz)
	end
	local placed, length = placesOf(draw)
	add(0, -1, length - 1, 1)
	for _, place in placed do
		local k = KINDS[place.kind]
		local s = place.side
		add(place.a0, s * 3, place.a0 + k.along - 1, s * (3 + k.deep - 1))
	end
	-- Their shells one block out; the collar and the plants KEEP_OUT around the hatch, up to two
	-- over its ground.
	return {
		min(x0 - 1, hx - KEEP_OUT),
		y0 - 1,
		min(z0 - 1, hz - KEEP_OUT),
		max(x1 + 1, hx + KEEP_OUT),
		max(h + 2, y0 + AIRLOCK_TALL, y0 + TALL),
		max(z1 + 1, hz + KEEP_OUT),
	}
end

--[[
	The plan of a hatch at (hx, h, hz) from `draw` (see the header): the airlock, the corridor
	and the rooms, their furnishings, lamps and containers. `salt`: the plan's cell hashes.
]]
local function geometry(salt: number, hx: number, h: number, hz: number, draw: Draw, city: boolean): Plan
	local dir = DIRS[draw.dir]
	local y0 = draw.floor
	local fx, fz, rx, rz = dir.fx, dir.fz, dir.rx, dir.rz
	local cx0, cz0 = hx + dir.ox, hz + dir.oz
	-- World column of a corridor cell (along a, across c).
	local function world(a: number, c: number): (number, number)
		return cx0 + a * fx + c * rx, cz0 + a * fz + c * rz
	end
	-- A box from local corners and heights.
	local function box(a0: number, c0: number, a1: number, c1: number, ya: number, yb: number): { number }
		local x0, z0 = world(a0, c0)
		local x1, z1 = world(a1, c1)
		return boxOf(x0, ya, z0, x1, yb, z1)
	end
	local lampSalt = bxor(salt, S_LAMP)
	-- A lamp under the ceiling at (x, y, z), unless the plan is dark or (overrun) it went.
	local function lamp(room: Room, x: number, y: number, z: number)
		if not draw.lit or (draw.overrun and roll(lampSalt, x, y, z) < MISSING) then
			return
		end
		table.insert(room.lamps, x)
		table.insert(room.lamps, y)
		table.insert(room.lamps, z)
	end

	local rooms: { Room } = {}
	-- The airlock: its inside under the shaft (the hatch is its south row's middle cell).
	local airlock = newRoom("airlock", { hx - 2, y0, hz - AIRLOCK + 1, hx + 2, y0 + AIRLOCK_TALL - 1, hz })
	lamp(airlock, hx, y0 + AIRLOCK_TALL - 1, hz - 2)
	table.insert(rooms, airlock)

	-- The rooms along each side: their first cells (a0) and the corridor's length.
	local placed, length = placesOf(draw)

	local corridor = newRoom("corridor", box(0, -1, length - 1, 1, y0, y0 + TALL - 1))
	for a = 2, length - 1, LAMP_GAP do
		local x, z = world(a, 0)
		lamp(corridor, x, y0 + TALL - 1, z)
	end
	table.insert(rooms, corridor)

	for _, entry in placed do
		local kind, s, a0 = entry.kind, entry.side, entry.a0
		local along, deep = KINDS[kind].along, KINDS[kind].deep
		local room = newRoom(kind, box(a0, s * 3, a0 + along - 1, s * (3 + deep - 1), y0, y0 + TALL - 1))
		-- The doorway in the corridor's wall, two tall, at the room's middle.
		local dx, dz = world(a0 + along // 2, s * 2)
		table.insert(room.doors, dx)
		table.insert(room.doors, y0)
		table.insert(room.doors, dz)
		-- Room cell (u along, v deep, layer up): world x, y, z.
		local function cell(u: number, v: number, layer: number): (number, number, number)
			local x, z = world(a0 + u, s * (3 + v))
			return x, y0 + layer, z
		end
		local function put(u: number, v: number, layer: number, block: number)
			local x, y, z = cell(u, v, layer)
			table.insert(room.blocks, x)
			table.insert(room.blocks, y)
			table.insert(room.blocks, z)
			table.insert(room.blocks, block)
		end
		local function keep(u: number, v: number, layer: number, block: number, loot: number)
			local x, y, z = cell(u, v, layer)
			table.insert(room.containers, x)
			table.insert(room.containers, y)
			table.insert(room.containers, z)
			table.insert(room.containers, block)
			table.insert(room.containers, loot)
		end
		local w, d = along, deep
		if kind == "bunks" then
			-- Three bunks along each side wall: a Planks base under a wool mattress, two long.
			for _, u in { 0, w - 1 } do
				for v = 1, d - 2, 3 do
					for dv = 0, 1 do
						put(u, v + dv, 0, PLANKS)
						put(u, v + dv, 1, WOOL)
					end
				end
			end
		elseif kind == "storage" then
			local spots = { { 0, d - 1 }, { w - 1, d - 1 }, { 1, d - 1 }, { w - 2, d - 1 }, { 0, d - 3 } }
			for k = 1, draw.crates do
				keep(spots[k][1], spots[k][2], 0, CRATE, T_STORAGE)
			end
			keep(w // 2, d - 1, 0, CHEST, T_STORAGE)
		elseif kind == "medical" then
			-- Two cabinets on the side wall, a cot along the other.
			keep(0, 2, 1, CABINET, T_MEDICAL)
			keep(0, 4, 1, CABINET, T_MEDICAL)
			put(w - 1, d - 2, 0, WOOL)
			put(w - 1, d - 1, 0, WOOL)
		elseif kind == "generator" then
			-- The machine in the back corner: iron and rust, by cell.
			for u = w - 2, w - 1 do
				for v = d - 2, d - 1 do
					for layer = 0, 1 do
						local x, y, z = cell(u, v, layer)
						put(u, v, layer, if roll(bxor(salt, S_MACHINE), x, y, z) < 0.5 then IRON else RUSTY)
					end
				end
			end
			put(0, d - 1, 0, FURNACE)
			put(1, d - 1, 0, COAL)
			put(0, d - 2, 0, COAL)
			keep(0, 1, 0, CRATE, T_GENERATOR)
		elseif kind == "armory" then
			keep(0, d - 1, 0, CHEST, T_ARMORY)
			keep(w - 1, d - 1, 0, CHEST, T_ARMORY)
			-- The rack along the side wall.
			for v = 2, 4 do
				put(0, v, 0, IRON)
			end
		elseif kind == "mess" then
			put(w // 2 - 1, d // 2, 0, TABLE)
			put(w // 2 + 1, d // 2, 0, TABLE)
			keep(w - 1, d - 1, 0, CRATE, T_STORAGE)
		end
		-- Lamps under the ceiling: one, or two in the deep rooms.
		if d >= 9 then
			local x, y, z = cell(w // 2, 2, TALL - 1)
			lamp(room, x, y, z)
			x, y, z = cell(w // 2, d - 3, TALL - 1)
			lamp(room, x, y, z)
		else
			local x, y, z = cell(w // 2, d // 2, TALL - 1)
			lamp(room, x, y, z)
		end
		table.insert(rooms, room)
	end

	-- Bounds: the rooms, the shaft, the collar and the plants around it.
	local bounds = layoutBounds(hx, h, hz, draw)
	-- (Alternating sides keep a layout within REACH; a one-sided one may run past it, and its
	-- caller turns it down.)
	assert(not draw.alternate or withinReach(bounds, hx, hz), "Bunkers: a plan reaches past REACH")
	local grid = Config.Bunkers.Grid
	return {
		cellX = hx // grid,
		cellZ = hz // grid,
		x = hx,
		y = h,
		z = hz,
		salt = salt,
		rooms = rooms,
		bounds = bounds,
		hatch = { hx, h, hz },
		lit = draw.lit,
		overrun = draw.overrun,
		floor = y0,
		floorBlock = draw.floorBlock,
		dir = dir.name,
		city = city,
	}
end

local function columnKey(x: number, z: number): number
	return (x + 1048576) * 2097152 + (z + 1048576)
end

local function overlaps(a: { number }, b: { number }): boolean
	return a[1] <= b[4] and a[4] >= b[1] and a[2] <= b[5] and a[5] >= b[2] and a[3] <= b[6] and a[6] >= b[3]
end

-- The squared distance from (x, z) to the bounds' footprint.
local function distance2(b: { number }, x: number, z: number): number
	local dx = max(b[1] - x, 0, x - b[4])
	local dz = max(b[3] - z, 0, z - b[6])
	return dx * dx + dz * dz
end

-- The boxes a plan builds in, each grown by MARGIN: every room's (its shell included) and the
-- shaft's, from under the airlock's floor to the plants over the collar.
local function solidBoxes(plan: Plan): { { number } }
	local list: { { number } } = {}
	for _, room in plan.rooms do
		table.insert(list, grown(room.box, MARGIN))
	end
	local m = KEEP_OUT + MARGIN
	table.insert(list, { plan.x - m, plan.floor - 1 - MARGIN, plan.z - m, plan.x + m, plan.y + 2 + MARGIN, plan.z + m })
	return list
end
Bunkers.solidBoxes = solidBoxes

--[[ Loot ]]

-- The items of a container of table `loot` (TABLES index) at (x, y, z): the table rolled; in
-- an overrun bunker rolled with another salt, then Bone and Rotten Flesh in free slots.
function Bunkers.loot(
	lootSalt: number,
	loot: number,
	overrun: boolean,
	x: number,
	y: number,
	z: number
): { StructureGen.ContainerItem }
	local name = TABLES[loot]
	if not overrun then
		return ScavengeLoot.roll(name, lootSalt, x, y, z)
	end
	local salt = bxor(lootSalt, S_OVERRUN)
	local items = ScavengeLoot.roll(name, salt, x, y, z)
	local used: { [number]: boolean } = {}
	for _, item in items do
		used[item.slot] = true
	end
	local rng = Hash.rng(Hash.hash3(salt, x, y + 1, z))
	for _, extra in { { item = "Bone", most = 3 }, { item = "RottenFlesh", most = 4 } } do
		local free: { number } = {}
		for slot = 1, ScavengeLoot.SLOTS do
			if not used[slot] then
				table.insert(free, slot)
			end
		end
		if #free == 0 then
			break
		end
		local slot = free[rng:int(1, #free)]
		used[slot] = true
		table.insert(items, {
			slot = slot,
			item = extra.item,
			count = rng:int(1, extra.most),
			damage = 0,
		})
	end
	return items
end

-- The loot of the container a plan puts at (x, y, z), nil when it puts none there.
local function containerOf(
	plans: { Plan },
	lootSalt: number,
	x: number,
	y: number,
	z: number
): { StructureGen.ContainerItem }?
	for _, plan in plans do
		for _, room in plan.rooms do
			local list = room.containers
			for i = 1, #list, 5 do
				if list[i] == x and list[i + 1] == y and list[i + 2] == z then
					return Bunkers.loot(lootSalt, list[i + 4], plan.overrun, x, y, z)
				end
			end
		end
	end
	return nil
end

--[[
	Appends x, y, z, block for every container and hatch `plans` put in the block rectangle
	(inclusive) when `lut` (u8 per block id) marks the block: /locate poi (World/PoiSearch) finds
	them from the plans, without generating their chunks.
]]
function Bunkers.poiOf(
	plans: { Plan },
	lut: buffer,
	minX: number,
	minZ: number,
	maxX: number,
	maxZ: number,
	out: { number }
)
	local function add(x: number, y: number, z: number, block: number)
		if x >= minX and x <= maxX and z >= minZ and z <= maxZ and readu8(lut, block) == 1 then
			table.insert(out, x)
			table.insert(out, y)
			table.insert(out, z)
			table.insert(out, block)
		end
	end
	for _, plan in plans do
		for _, room in plan.rooms do
			local list = room.containers
			for i = 1, #list, 5 do
				add(list[i], list[i + 1], list[i + 2], list[i + 3])
			end
		end
		add(plan.x, plan.y, plan.z, HATCH)
	end
end

--[[ Plans ]]

-- A wild cell's candidate hatches (x, z each), false: no candidate.
type Start = { candidates: { number } }
type Cell = { used: number, start: Start | false, plan: Plan | false | nil }
type Spot = { used: number, plan: Plan | false | nil }

-- A plan build's terrain lookups (cached per build) and the caller's yield (nil: none) with the
-- lookups made since it was last called.
type Build = {
	heights: { [number]: number },
	yield: (() -> ())?,
	work: number,
}

-- Writing state is below; Bunkers.write needs it (forward declaration).
local writePlans: (
	plans: { Plan },
	data: buffer,
	originX: number,
	originZ: number,
	cells: number,
	heights: { number },
	carved: Caves.Carved?,
	outside: (x: number, z: number) -> number
) -> (number, number, Caves.Carved?)

-- /locate structure bunker's kind with no bunker anywhere: every probe answers nothing.
local function noKind(): Locate.Kind
	local grid = Config.Bunkers.Grid
	return {
		id = "bunker",
		grid = grid,
		slack = 0,
		rings = math.ceil(Config.Locate.Radius.bunker / grid),
		showY = true,
		probe = function(_gx: number, _gz: number): (number?, number, number)
			return nil, 0, 0
		end,
	}
end

-- No bunkers (see the header).
function Bunkers.none(): Bunkers
	return {
		plans = function(_minX: number, _minZ: number, _maxX: number, _maxZ: number, _yield: (() -> ())?): { Plan }
			return {}
		end,
		keepOut = function(_minX: number, _minZ: number, _maxX: number, _maxZ: number, _yield: (() -> ())?): { number }
			return {}
		end,
		boxes = function(_minX: number, _minZ: number, _maxX: number, _maxZ: number): { number }
			return {}
		end,
		write = function(
			_plans: { Plan },
			_data: buffer,
			_originX: number,
			_originZ: number,
			_cells: number,
			_heights: { number },
			carved: Caves.Carved?
		): (number, number, Caves.Carved?)
			return math.huge, 0, carved
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
		built = function(): number
			return 0
		end,
	}
end

-- The bunkers of world `seed` over the raw `terrain` (see the header); `layout`: a fixed list
-- of plans instead (the debug structures world).
function Bunkers.new(seed: number, terrain: Terrain, layout: Layout?): Bunkers
	local cfg = Config.Bunkers
	local GRID, CHANCE, CANDIDATES = cfg.Grid, cfg.Chance, cfg.Candidates
	local salt = Hash.hash2(seed, Hash.string("bunkers"), 0xB0)
	local lootSalt = Hash.hash2(seed, Hash.string("bunkers.loot"), 0xB0B5)
	local height = terrain.height
	local cities = terrain.cities
	local builtCount = 0

	-- A column's height as the generator's chunks have it (see Terrain `surface`): the wrapped
	-- relief clamped as TerrainGenerator's clampHeight does.
	local surface: (x: number, z: number) -> number = height
	if terrain.surface then
		surface = terrain.surface
	elseif cities then
		local relief = cities.relief
		surface = function(x: number, z: number): number
			local y = relief.height(x, z, 0)
			return math.clamp(math.floor(y), 2, Config.WorldHeight - STRUCTURE_ROOM)
		end
	end

	--[[ Checks while building ]]

	-- Counts `n` terrain lookups, yielding every PAUSE (a worker's 3 ms slice, Config.Workers).
	local function spend(b: Build, n: number)
		local yield = b.yield
		if yield then
			b.work += n
			if b.work >= PAUSE then
				b.work = 0
				yield()
			end
		end
	end

	local function heightAt(b: Build, x: number, z: number): number
		local key = columnKey(x, z)
		local h = b.heights[key]
		if h == nil then
			spend(b, 1)
			h = height(x, z)
			b.heights[key] = h
		end
		return h
	end

	-- COVER blocks of ground over a room's shell at every point of the world-aligned SAMPLE
	-- lattice within SAMPLE / 2 of its footprint.
	local function covered(b: Build, box: { number }): boolean
		local top = box[5]
		local half = SAMPLE // 2
		for gz = (box[3] - half + SAMPLE - 1) // SAMPLE, (box[6] + half) // SAMPLE do
			for gx = (box[1] - half + SAMPLE - 1) // SAMPLE, (box[4] + half) // SAMPLE do
				if heightAt(b, gx * SAMPLE, gz * SAMPLE) - 1 - COVER < top then
					return false
				end
			end
		end
		return true
	end

	--[[
		Clear of everything Terrain.blocked lists within MARGIN blocks of the plan's bounds (asked
		once, for the bounds grown by MARGIN + QUERY_PAD), then of the mineshafts' pieces and
		entrance shafts within MARGIN blocks of its rooms and its shaft (Terrain.mineshafts: in
		three dimensions, so a mineshaft deep under a bunker leaves it be; asked only when the rest
		is clear: building a mineshaft's plan is the dearest lookup there is). A yield before and
		after each (they decide lakes, puddles and mineshafts cold, and yield inside too).
	]]
	local function clear(b: Build, plan: Plan): boolean
		local bounds = plan.bounds
		local x0, z0 = bounds[1] - MARGIN, bounds[3] - MARGIN
		local x1, z1 = bounds[4] + MARGIN, bounds[6] + MARGIN
		local q = QUERY_PAD
		spend(b, PAUSE)
		local list = terrain.blocked(x0 - q, z0 - q, x1 + q, z1 + q, b.yield)
		spend(b, PAUSE)
		for i = 1, #list, 4 do
			if list[i] <= x1 and list[i + 2] >= x0 and list[i + 1] <= z1 and list[i + 3] >= z0 then
				return false
			end
		end
		local mineshafts = terrain.mineshafts
		if mineshafts == nil then
			return true
		end
		local boxes = mineshafts(x0 - q, z0 - q, x1 + q, z1 + q, b.yield)
		spend(b, PAUSE)
		if #boxes == 0 then
			return true
		end
		for _, solid in solidBoxes(plan) do
			for i = 1, #boxes, 6 do
				if
					boxes[i] <= solid[4]
					and boxes[i + 3] >= solid[1]
					and boxes[i + 1] <= solid[5]
					and boxes[i + 4] >= solid[2]
					and boxes[i + 2] <= solid[6]
					and boxes[i + 5] >= solid[3]
				then
					return false
				end
			end
		end
		return true
	end

	-- Far enough from the spawn?
	local function awayFromSpawn(bounds: { number }): boolean
		local sx, sz = terrain.spawn()
		local d = cfg.SpawnClearance
		return distance2(bounds, sx, sz) >= d * d
	end

	--[[ Wild sites ]]

	-- The hatch's column lies in core columns 2..13 of its chunk.
	local function inCore(c: number): boolean
		local m = c % SIZE
		return m >= 2 and m <= SIZE - 3
	end

	-- The plan of a candidate hatch at (x, z), nil when it doesn't pass (see the header).
	local function tryWild(b: Build, x: number, z: number): Plan?
		if not (inCore(x) and inCore(z)) then
			return nil
		end
		local h0 = heightAt(b, x, z)
		if h0 <= SEA + 2 then
			return nil
		end
		for dz = -2, 2 do
			for dx = -2, 2 do
				local h = heightAt(b, x + dx, z + dz)
				if abs(h - h0) > 1 or h <= SEA + 2 then
					return nil
				end
				spend(b, 1)
				if terrain.river(x + dx, z + dz) > 0 then
					return nil
				end
			end
		end
		local plan = geometry(Hash.hash3(salt, x, h0, z), x, h0, z, drawLayout(salt, x, h0, z, nil), false)
		if not awayFromSpawn(plan.bounds) then
			return nil
		end
		for _, room in plan.rooms do
			if not covered(b, room.box) then
				return nil
			end
		end
		for dz = -2, 2 do
			for dx = -2, 2 do
				spend(b, 1)
				if terrain.carvesTop(x + dx, z + dz, b.yield) then
					return nil
				end
			end
		end
		if not clear(b, plan) then
			return nil
		end
		return plan
	end

	local function startOf(gx: number, gz: number): Start | false
		local rng = Hash.rng(Hash.hash3(salt, gx, 0, gz))
		if rng:float() >= CHANCE then
			return false
		end
		-- A core column (2..13) of a chunk lying INSET blocks or more inside the cell, each way.
		local candidates: { number } = table.create(CANDIDATES * 2)
		local function along(g: number): number
			local first, last = (g * GRID + INSET + SIZE - 1) // SIZE, (g * GRID + GRID - INSET + 1) // SIZE - 1
			return rng:int(first, last) * SIZE + rng:int(2, SIZE - 3)
		end
		for _ = 1, CANDIDATES do
			table.insert(candidates, along(gx))
			table.insert(candidates, along(gz))
		end
		return { candidates = candidates }
	end

	local function build(s: Start, yield: (() -> ())?): Plan | false
		builtCount += 1
		local b: Build = { heights = {}, yield = yield, work = 0 }
		local list = s.candidates
		for k = 1, #list, 2 do
			local plan = tryWild(b, list[k], list[k + 1])
			if plan then
				return plan
			end
		end
		return false
	end

	-- LRUs: grid cells, and city spots' plans.
	local cache: { [number]: Cell } = {}
	local spots: { [number]: Spot } = {}
	local cached, spotsCached, clock = 0, 0, 0

	local function evict(map: { [number]: any }): boolean
		local oldest, oldestKey = huge, nil
		for k, c in map do
			if c.used < oldest then
				oldest, oldestKey = c.used, k
			end
		end
		if oldestKey then
			map[oldestKey] = nil
			return true
		end
		return false
	end

	local function cellAt(gx: number, gz: number): Cell
		local key = columnKey(gx, gz)
		local cell = cache[key]
		clock += 1
		if cell == nil then
			if cached >= CACHE and evict(cache) then
				cached -= 1
			end
			cell = { used = clock, start = startOf(gx, gz), plan = nil }
			cache[key] = cell
			cached += 1
		end
		assert(cell, "Bunkers: a cell")
		cell.used = clock
		return cell
	end

	local function planAt(gx: number, gz: number, yield: (() -> ())?): Plan?
		local cell = cellAt(gx, gz)
		if cell.start == false then
			return nil
		end
		if cell.plan == nil then
			cell.plan = build(cell.start :: Start, yield)
			if yield then
				yield()
			end
		end
		local plan = cell.plan
		return if plan then plan :: Plan else nil
	end

	--[[ City sites ]]

	-- The layouts a city bunker tries, in order (see the header), each handed to `try` (the same
	-- table, changed between calls) until it answers true: that one, nil when none does.
	local function eachLayout(draw: Draw, try: (d: Draw) -> boolean): Draw?
		for count = #draw.kinds, 2, -1 do
			local d = shortened(draw, count)
			for sides = 2, 1, -1 do
				d.alternate = sides == 2
				for turn = 0, #DIRS - 1 do
					d.dir = (draw.dir - 1 + turn) % #DIRS + 1
					for flip = 0, 1 do
						d.side = if flip == 0 then draw.side else -draw.side
						if try(d) then
							return d
						end
					end
				end
			end
		end
		return nil
	end

	-- A shed whose hatch comes after the one being planned: its spot, its drawn layout and the
	-- airlocks it keeps clear of.
	type Later = { x: number, y: number, z: number, draw: Draw, airlocks: { { number } } }

	-- What every layout of the shed at (x, z) keeps: its airlock and collar, every level.
	local function airlockOf(x: number, z: number): { number }
		return { x - 3, -huge, z - AIRLOCK, x + 3, huge, z + KEEP_OUT }
	end

	-- The plan of the city spot (sx, sy, sz) (cached), nil when no layout fits (see the header);
	-- `depth` guards the recursion over the spots that come first.
	local cityPlan: (sx: number, sy: number, sz: number, yield: (() -> ())?, depth: number) -> Plan?
	local function buildCity(sx: number, sy: number, sz: number, yield: (() -> ())?, depth: number): Plan | false
		local c = cities
		if c == nil then
			return false
		end
		builtCount += 1
		-- (Each layout tried counts a lookup: a few microseconds.)
		local b: Build = { heights = {}, yield = yield, work = 0 }
		-- The other sheds near it: every one's airlock and collar to keep clear of, the whole
		-- bunkers of those whose hatch comes first (in x, then z: they keep their layouts), and
		-- those that come after it, to leave a layout each.
		local airlocks: { { number } } = {}
		local earlier: { { number } } = {}
		local later: { Later } = {}
		local near = c.bunkerSpots(sx - 2 * REACH, sz - 2 * REACH, sx + 2 * REACH, sz + 2 * REACH, yield)
		for i = 1, #near, 3 do
			local x, y, z = near[i], near[i + 1], near[i + 2]
			if x == sx and z == sz then
				continue
			end
			table.insert(airlocks, airlockOf(x, z))
			if x < sx or (x == sx and z < sz) then
				local other = if depth < 4 then cityPlan(x, y, z, yield, depth + 1) else nil
				if other then
					table.insert(earlier, other.bounds)
				end
			else
				table.insert(
					later,
					{ x = x, y = y, z = z, draw = drawLayout(salt, x, y, z, CITY_DEPTH), airlocks = {} }
				)
			end
		end
		local function inside(x: number, z: number): boolean
			return c.cityAt(x, z) >= 1
		end
		-- The bounds of layout `d` of the shed at (x, y, z) when they fit: within REACH, inside the
		-- town (cityAt 1 at their corners grown by GUARD + 1: the footprint is levelled flat, so
		-- the cover holds without asking the relief), clear of every box in the lists and of the
		-- spawn; nil when not.
		local function fits(x: number, y: number, z: number, d: Draw, lists: { { { number } } }): { number }?
			spend(b, 1)
			local bounds = layoutBounds(x, y, z, d)
			local m = GUARD + 1
			if
				not withinReach(bounds, x, z)
				or not inside(bounds[1] - m, bounds[3] - m)
				or not inside(bounds[4] + m, bounds[3] - m)
				or not inside(bounds[1] - m, bounds[6] + m)
				or not inside(bounds[4] + m, bounds[6] + m)
			then
				return nil
			end
			for _, list in lists do
				for _, other in list do
					if overlaps(other, bounds) then
						return nil
					end
				end
			end
			return if awayFromSpawn(bounds) then bounds else nil
		end
		-- The sheds after it that have a layout with this one's bunker out of the way (the
		-- others' airlocks and the earlier bunkers kept clear of): this one leaves each a layout
		-- when it can. (Exact for a town's two sheds; with more near, the third's own bunker is
		-- not counted.)
		local hopeful: { Later } = {}
		for _, other in later do
			local theirs = other.airlocks
			table.insert(theirs, airlockOf(sx, sz))
			for i = 1, #near, 3 do
				local x, z = near[i], near[i + 2]
				if not ((x == sx and z == sz) or (x == other.x and z == other.z)) then
					table.insert(theirs, airlockOf(x, z))
				end
			end
			local function free(d: Draw): boolean
				return fits(other.x, other.y, other.z, d, { theirs, earlier }) ~= nil
			end
			if other.draw.floor == other.y - CITY_DEPTH and eachLayout(other.draw, free) then
				table.insert(hopeful, other)
			end
		end
		local draw = drawLayout(salt, sx, sy, sz, CITY_DEPTH)
		if draw.floor ~= sy - CITY_DEPTH then
			return false
		end
		-- The first layout that fits and leaves every hopeful later shed one; else the first that
		-- fits.
		local first: Draw? = nil
		local chosen = eachLayout(draw, function(d: Draw): boolean
			local bounds = fits(sx, sy, sz, d, { airlocks, earlier })
			if bounds == nil then
				return false
			end
			if first == nil then
				first = table.clone(d)
			end
			local mine = { bounds }
			for _, other in hopeful do
				local function free(theirs: Draw): boolean
					return fits(other.x, other.y, other.z, theirs, { other.airlocks, earlier, mine }) ~= nil
				end
				if not eachLayout(other.draw, free) then
					return false
				end
			end
			return true
		end)
		local d = chosen or first
		if d == nil then
			return false
		end
		return geometry(Hash.hash3(salt, sx, sy, sz), sx, sy, sz, d, true)
	end

	function cityPlan(sx: number, sy: number, sz: number, yield: (() -> ())?, depth: number): Plan?
		local key = columnKey(sx, sz)
		local spot = spots[key]
		clock += 1
		if spot == nil then
			if spotsCached >= CACHE and evict(spots) then
				spotsCached -= 1
			end
			spot = { used = clock, plan = nil }
			spots[key] = spot
			spotsCached += 1
		end
		assert(spot, "Bunkers: a spot")
		spot.used = clock
		if spot.plan == nil then
			spot.plan = buildCity(sx, sy, sz, yield, depth) :: Plan | false
			if yield then
				yield()
			end
		end
		local plan = spot.plan
		return if plan then plan :: Plan else nil
	end

	--[[ Queries ]]

	local function touches(plan: Plan, minX: number, minZ: number, maxX: number, maxZ: number): boolean
		local b = plan.bounds
		return b[1] <= maxX and b[4] >= minX and b[3] <= maxZ and b[6] >= minZ
	end

	local function plans(minX: number, minZ: number, maxX: number, maxZ: number, yield: (() -> ())?): { Plan }
		if layout then
			return layout(minX, minZ, maxX, maxZ)
		end
		local list: { Plan } = {}
		-- Wild: the cells whose candidates may reach the rectangle (a cell's hatches lie INSET
		-- inside it, their bounds REACH around them: cells g with g x GRID + INSET - REACH <= max
		-- and g x GRID + GRID - INSET + REACH >= min, the first rounded up, so that a chunk asks
		-- for one cell each way, two only within REACH - INSET of a cell's side).
		local firstZ, lastZ = (minZ - (GRID - INSET) - REACH + GRID - 1) // GRID, (maxZ - INSET + REACH) // GRID
		local firstX, lastX = (minX - (GRID - INSET) - REACH + GRID - 1) // GRID, (maxX - INSET + REACH) // GRID
		for gz = firstZ, lastZ do
			for gx = firstX, lastX do
				if cellAt(gx, gz).start == false then
					continue
				end
				local plan = planAt(gx, gz, yield)
				if plan and touches(plan, minX, minZ, maxX, maxZ) then
					table.insert(list, plan)
				end
			end
		end
		-- The cities' sheds whose bunkers may reach it.
		local c = cities
		if c then
			local found = c.bunkerSpots(minX - REACH, minZ - REACH, maxX + REACH, maxZ + REACH, yield)
			for i = 1, #found, 3 do
				local plan = cityPlan(found[i], found[i + 1], found[i + 2], yield, 0)
				if plan and touches(plan, minX, minZ, maxX, maxZ) then
					table.insert(list, plan)
				end
			end
		end
		return list
	end

	local function keepOut(minX: number, minZ: number, maxX: number, maxZ: number, yield: (() -> ())?): { number }
		local list: { number } = {}
		for _, plan in plans(minX - KEEP_OUT, minZ - KEEP_OUT, maxX + KEEP_OUT, maxZ + KEEP_OUT, yield) do
			local x, z = plan.x, plan.z
			if x - KEEP_OUT <= maxX and x + KEEP_OUT >= minX and z - KEEP_OUT <= maxZ and z + KEEP_OUT >= minZ then
				table.insert(list, x - KEEP_OUT)
				table.insert(list, z - KEEP_OUT)
				table.insert(list, x + KEEP_OUT)
				table.insert(list, z + KEEP_OUT)
			end
		end
		return list
	end

	local function boxes(minX: number, minZ: number, maxX: number, maxZ: number): { number }
		local list: { number } = {}
		for _, plan in plans(minX, minZ, maxX, maxZ) do
			for _, room in plan.rooms do
				local b = grown(room.box, MARGIN)
				table.move(b, 1, 6, #list + 1, list)
			end
			table.move(
				{ plan.x - 1, plan.floor - 1, plan.z - 1, plan.x + 1, plan.y, plan.z + 1 },
				1,
				6,
				#list + 1,
				list
			)
		end
		return list
	end

	local function write(
		list: { Plan },
		data: buffer,
		originX: number,
		originZ: number,
		cells: number,
		heights: { number },
		carved: Caves.Carved?
	): (number, number, Caves.Carved?)
		return writePlans(list, data, originX, originZ, cells, heights, carved, surface)
	end

	local function container(x: number, y: number, z: number): { StructureGen.ContainerItem }?
		return containerOf(plans(x, z, x, z), lootSalt, x, y, z)
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
		Bunkers.poiOf(plans(minX, minZ, maxX, maxZ, yield), lut, minX, minZ, maxX, maxZ, out)
	end

	--[[ Locating ]]

	-- A city in one of the city cells overlapping grid cell (gx, gz) (the cities' own probe: a
	-- city and its margin never leave their cell)?
	local cityKind: Locate.Kind? = nil
	local function cityNear(gx: number, gz: number): boolean
		local c = cities
		if c == nil then
			return false
		end
		local kind = cityKind
		if kind == nil then
			kind = c.locateKind()
			cityKind = kind
		end
		assert(kind, "Bunkers: the cities' kind")
		local cityGrid, origin = kind.grid, kind.origin or 0
		local x0, z0 = gx * GRID, gz * GRID
		for cz = (z0 - origin) // cityGrid, (z0 + GRID - 1 - origin) // cityGrid do
			for cx = (x0 - origin) // cityGrid, (x0 + GRID - 1 - origin) // cityGrid do
				if kind.probe(cx, cz) ~= nil then
					return true
				end
			end
		end
		return false
	end

	local function locateKind(): Locate.Kind
		local half = GRID // 2
		return {
			id = "bunker",
			grid = GRID,
			-- (A hatch lies in its cell; the probe answers the cell's centre.)
			slack = 0,
			spread = half * math.sqrt(2) + 1,
			rings = math.ceil(Config.Locate.Radius.bunker / GRID),
			showY = true,
			probe = function(gx: number, gz: number): (number?, number, number)
				local wild = Hash.rng(Hash.hash3(salt, gx, 0, gz)):float() < CHANCE
				if wild or cityNear(gx, gz) then
					return gx * GRID + half, gz * GRID + half, 0
				end
				return nil, 0, 0
			end,
			-- The hatch nearest the player among the cell's wild bunker and its city bunkers.
			verify = function(
				gx: number,
				gz: number,
				px: number,
				pz: number,
				yield: () -> ()
			): (number?, number, number)
				local best: Plan? = nil
				local bestD = huge
				local function consider(plan: Plan)
					if plan.x // GRID ~= gx or plan.z // GRID ~= gz then
						return
					end
					local d = (plan.x - px) ^ 2 + (plan.z - pz) ^ 2
					if d < bestD then
						best, bestD = plan, d
					end
				end
				local wild = planAt(gx, gz, yield)
				if wild then
					consider(wild)
				end
				local c = cities
				if c and cityNear(gx, gz) then
					local found = c.bunkerSpots(gx * GRID, gz * GRID, gx * GRID + GRID - 1, gz * GRID + GRID - 1, yield)
					for i = 1, #found, 3 do
						local plan = cityPlan(found[i], found[i + 1], found[i + 2], yield, 0)
						if plan then
							consider(plan)
						end
					end
				end
				local plan = best
				if plan == nil then
					return nil, 0, 0
				end
				return plan.x, plan.y, plan.z
			end,
		}
	end

	return {
		plans = plans,
		keepOut = keepOut,
		boxes = boxes,
		write = write,
		container = container,
		poiBlocks = poiBlocks,
		locateKind = locateKind,
		built = function(): number
			return builtCount
		end,
	}
end

--[[ Writing ]]

-- The chunk being written (module level: one write at a time per actor).
local NOTHING = buffer.create(0)
local wData: buffer = NOTHING
local wCells = 0
local wX0, wZ0, wX1, wZ1 = 0, 0, 0, 0
local wLowest, wTop = huge, 0
local wHeights: { number } = {}
local wOutside: (x: number, z: number) -> number = function(_x: number, _z: number): number
	return 0
end
-- Per padded column: the highest cell a room may reach (UNKNOWN: not worked out yet).
local UNKNOWN = -huge
local wLimit: { number } = table.create(P * P, UNKNOWN)
-- Byte offsets of the attached blocks written.
local wAttached: { number } = {}

-- Byte offset of cell (x, y, z) in the chunk, -1 outside the padded box or the buffer (and
-- the bedrock layer).
local function at(x: number, y: number, z: number): number
	if x < wX0 or x > wX1 or z < wZ0 or z > wZ1 or y < 1 or y >= wCells then
		return -1
	end
	return ((y * P + (z - wZ0)) * P + (x - wX0)) * 2
end

-- The block at (x, y, z): -1 outside the padded box, Air above the buffer, bedrock below it.
local function read(x: number, y: number, z: number): number
	if x < wX0 or x > wX1 or z < wZ0 or z > wZ1 then
		return -1
	end
	if y >= wCells then
		return AIR
	elseif y < 0 then
		return BEDROCK
	end
	return readu16(wData, ((y * P + (z - wZ0)) * P + (x - wX0)) * 2)
end

local function put(o: number, y: number, block: number)
	writeu16(wData, o, block)
	if y < wLowest and readu8(CULL_HIDDEN, block) == 0 then
		wLowest = y
	end
	if y >= wTop then
		wTop = y + 1
	end
	if readu8(ATTACHED, block) == 1 then
		table.insert(wAttached, o)
	end
end

-- A column's height (padded columns from the chunk's heights, others asked).
local function columnHeight(x: number, z: number): number
	if x >= wX0 and x <= wX1 and z >= wZ0 and z <= wZ1 then
		return wHeights[(z - wZ0) * P + (x - wX0) + 1]
	end
	return wOutside(x, z)
end

-- The highest cell a room may reach in column (x, z): GUARD blocks under its own surface's top
-- block and under its four neighbours' surfaces (Mineshafts' limitAt).
local function limitAt(x: number, z: number): number
	local i = (z - wZ0) * P + (x - wX0) + 1
	local v = wLimit[i]
	if v == UNKNOWN then
		v = min(
			columnHeight(x, z) - 1,
			columnHeight(x - 1, z),
			columnHeight(x + 1, z),
			columnHeight(x, z - 1),
			columnHeight(x, z + 1)
		) - 1 - GUARD
		wLimit[i] = v
	end
	return v
end

-- Calls fn(x, y, z, o) for every cell of the box inside the padded box and under its column's
-- limit.
local function eachLimited(b: { number }, fn: (x: number, y: number, z: number, o: number) -> ())
	local x0, x1 = max(b[1], wX0), min(b[4], wX1)
	local z0, z1 = max(b[3], wZ0), min(b[6], wZ1)
	if x0 > x1 or z0 > z1 then
		return
	end
	for z = z0, z1 do
		for x = x0, x1 do
			local top = min(b[5], limitAt(x, z), wCells - 1)
			for y = max(b[2], 1), top do
				fn(x, y, z, ((y * P + (z - wZ0)) * P + (x - wX0)) * 2)
			end
		end
	end
end

-- A cell inside the padded box, under its column's limit, holding cave air: its offset, else -1.
local function insideAt(x: number, y: number, z: number): number
	local o = at(x, y, z)
	if o < 0 or y > limitAt(x, z) or readu16(wData, o) ~= CAVE_AIR then
		return -1
	end
	return o
end

-- A forced cell (the shaft, its walls, the collar): anything but bedrock becomes `block`.
local function force(x: number, y: number, z: number, block: number)
	local o = at(x, y, z)
	if o >= 0 and readu16(wData, o) ~= BEDROCK then
		put(o, y, block)
	end
end

local function writePlan(plan: Plan)
	local salt = plan.salt
	local y0 = plan.floor
	local shellSalt = bxor(salt, S_SHELL)
	local overrun = plan.overrun
	-- 1. Every room's shell (the whole outer box: the insides come next).
	for _, room in plan.rooms do
		eachLimited(room.box, function(x: number, y: number, z: number, o: number)
			if readu16(wData, o) == BEDROCK then
				return
			end
			local block = plan.floorBlock
			if y ~= y0 - 1 then
				local r = roll(shellSalt, x, y, z)
				block = if overrun and r < MOSSY
					then MOSSY_CONCRETE
					elseif r >= 1 - CRACKED then CRACKED_CONCRETE
					else CONCRETE
			end
			put(o, y, block)
		end)
	end
	-- 2. The insides and the doorways: cave air.
	local function hollow(_x: number, y: number, _z: number, o: number)
		if readu16(wData, o) ~= BEDROCK then
			put(o, y, CAVE_AIR)
		end
	end
	for _, room in plan.rooms do
		eachLimited(room.inner, hollow)
		local doors = room.doors
		for i = 1, #doors, 3 do
			local x, y, z = doors[i], doors[i + 1], doors[i + 2]
			eachLimited({ x, y, z, x, y + 1, z }, hollow)
		end
	end
	-- 3. Furnishings and containers, into the inside's cave air.
	for _, room in plan.rooms do
		local blocks = room.blocks
		for i = 1, #blocks, 4 do
			local o = insideAt(blocks[i], blocks[i + 1], blocks[i + 2])
			if o >= 0 then
				put(o, blocks[i + 1], blocks[i + 3])
			end
		end
		local list = room.containers
		for i = 1, #list, 5 do
			local o = insideAt(list[i], list[i + 1], list[i + 2])
			if o >= 0 then
				put(o, list[i + 1], list[i + 3])
			end
		end
	end
	-- 4. Lamps under the ceilings, and an overrun bunker's cobwebs: cave twins.
	for _, room in plan.rooms do
		local lamps = room.lamps
		for i = 1, #lamps, 3 do
			local o = insideAt(lamps[i], lamps[i + 1], lamps[i + 2])
			if o >= 0 then
				put(o, lamps[i + 1], LAMP)
			end
		end
	end
	if overrun then
		local webSalt = bxor(salt, S_WEB)
		for _, room in plan.rooms do
			local b = room.inner
			local y = b[5]
			for z = max(b[3], wZ0), min(b[6], wZ1) do
				for x = max(b[1], wX0), min(b[4], wX1) do
					if roll(webSalt, x, y, z) < WEBS then
						local o = insideAt(x, y, z)
						if o >= 0 then
							put(o, y, WEB)
						end
					end
				end
			end
		end
	end
	-- 5. The shaft: its walls from the airlock's ceiling up, the ladder down to the floor.
	local hx, h0, hz = plan.x, plan.y, plan.z
	local ceiling = y0 + AIRLOCK_TALL
	for dz = -1, 1 do
		for dx = -1, 1 do
			if dx ~= 0 or dz ~= 0 then
				for y = ceiling + 1, h0 - 2 do
					force(hx + dx, y, hz + dz, CONCRETE)
				end
			end
		end
	end
	for y = y0, h0 - 1 do
		force(hx, y, hz, LADDER)
	end
	-- The collar, flush with the ground (the ground above it cut level), and the hatch.
	local collarSalt = bxor(salt, S_COLLAR)
	for dz = -1, 1 do
		for dx = -1, 1 do
			local x, z = hx + dx, hz + dz
			if x < wX0 or x > wX1 or z < wZ0 or z > wZ1 then
				continue
			end
			if dx ~= 0 or dz ~= 0 then
				force(x, h0 - 1, z, if roll(collarSalt, x, h0 - 1, z) < COLLAR_MOSS then MOSSY_CONCRETE else CONCRETE)
			end
			for y = h0, columnHeight(x, z) - 1 do
				local o = at(x, y, z)
				if o >= 0 and readu16(wData, o) ~= AIR then
					put(o, y, AIR)
				end
			end
		end
	end
	force(hx, h0, hz, HATCH)
	-- Plants on the ring two blocks out, where the soil takes them.
	local plantSalt = bxor(salt, S_PLANT)
	for dz = -2, 2 do
		for dx = -2, 2 do
			if max(abs(dx), abs(dz)) ~= 2 then
				continue
			end
			local x, z = hx + dx, hz + dz
			if x < wX0 or x > wX1 or z < wZ0 or z > wZ1 then
				continue
			end
			local hc = columnHeight(x, z)
			local h = cellHash(plantSalt, x, hc, z)
			if (h % 1024) / 1024 >= PLANTS then
				continue
			end
			local r = ((h // 1024) % 1024) / 1024
			local plant, top = PLANT_KINDS[1][1], PLANT_KINDS[1][2]
			for _, kind in PLANT_KINDS do
				if r < kind[3] then
					plant, top = kind[1], kind[2]
					break
				end
			end
			local o = at(x, hc, z)
			if o < 0 or readu16(wData, o) ~= AIR or not Blocks.mayPlaceOn(plant, read(x, hc - 1, z)) then
				continue
			end
			if top ~= 0 then
				local above = at(x, hc + 1, z)
				if above < 0 or readu16(wData, above) ~= AIR then
					continue
				end
				put(o, hc, plant)
				put(above, hc + 1, top)
			else
				put(o, hc, plant)
			end
		end
	end
end

-- Takes away every attached block written whose support went (Mineshafts' settle): top down.
-- Supports past the padded box are unknown: kept.
local function settle()
	local count = #wAttached
	if count == 0 then
		return
	end
	table.sort(wAttached, function(a: number, b: number): boolean
		return a > b
	end)
	local LAYER2 = P * P * 2
	for k = 1, count do
		local o = wAttached[k]
		local block = readu16(wData, o)
		local dx, dy, dz = Blocks.supportOffset(block)
		if dx == nil or dy == nil or dz == nil then
			continue
		end
		local y = o // LAYER2
		local rest = (o % LAYER2) // 2
		local x, z = wX0 + rest % P, wZ0 + rest // P
		local support = read(x + dx, y + dy, z + dz)
		if support < 0 or readu8(STURDY, support) == 1 then
			continue
		end
		if Blocks.isPlant(block) and Blocks.mayPlaceOn(block, support) then
			continue
		end
		writeu16(wData, o, if Blocks.isCaveTwin(block) then CAVE_AIR else AIR)
	end
end

function writePlans(
	plans: { Plan },
	data: buffer,
	originX: number,
	originZ: number,
	cells: number,
	heights: { number },
	carved: Caves.Carved?,
	outside: (x: number, z: number) -> number
): (number, number, Caves.Carved?)
	wData, wCells = data, cells
	wX0, wZ0, wX1, wZ1 = originX - 1, originZ - 1, originX + SIZE, originZ + SIZE
	wLowest, wTop = huge, 0
	wHeights, wOutside = heights, outside
	for i = 1, P * P do
		wLimit[i] = UNKNOWN
	end
	table.clear(wAttached)
	local map = carved
	for _, plan in plans do
		local b = plan.bounds
		if b[1] > wX1 or b[4] < wX0 or b[3] > wZ1 or b[6] < wZ0 then
			continue
		end
		writePlan(plan)
		for _, room in plan.rooms do
			local r = room.box
			if r[1] <= wX1 and r[4] >= wX0 and r[3] <= wZ1 and r[6] >= wZ0 then
				map = Caves.markRead(map, originX, originZ, r[1], r[2], r[3], r[4], r[5], r[6])
			end
		end
		local x, z = plan.x, plan.z
		map = Caves.markRead(map, originX, originZ, x - 1, plan.floor - 1, z - 1, x + 1, plan.y, z + 1)
	end
	settle()
	local lowest, top = wLowest, wTop
	wData, wHeights = NOTHING, {}
	return lowest, top, map
end

--[[
	Writes `plans` into a padded full detail chunk (see Bunkers `write`); `outside(x, z)` gives
	the height of a column past the padded box.
]]
function Bunkers.write(
	plans: { Plan },
	data: buffer,
	originX: number,
	originZ: number,
	cells: number,
	heights: { number },
	carved: Caves.Carved?,
	outside: (x: number, z: number) -> number
): (number, number, Caves.Carved?)
	return writePlans(plans, data, originX, originZ, cells, heights, carved, outside)
end

--[[ Samples (the debug structures world) ]]

--[[
	A fixed bunker for the debug structures world: its hatch at (x, ground, z) (`ground`: the
	first air), CITY_DEPTH deep, the corridor heading east with every kind of room (bunks,
	storeroom, medical room, generator room, armory, mess, alternating sides from the north),
	lit, not overrun. Its bounds reach 3 blocks west of the hatch, 14 north, 31 east and 10
	south.
]]
function Bunkers.sample(x: number, ground: number, z: number): Plan
	local draw: Draw = {
		floor = ground - CITY_DEPTH,
		dir = 2,
		kinds = { "bunks", "storage", "medical", "generator", "armory", "mess" },
		order = { 1, 2, 3, 4, 5, 6 },
		side = -1,
		alternate = true,
		lit = true,
		overrun = false,
		floorBlock = CONCRETE,
		crates = 4,
	}
	return geometry(Hash.hash3(0xB0B5E, x, ground, z), x, ground, z, draw, false)
end

return Bunkers
