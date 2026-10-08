--!strict
--!native
--[[
	Mineshafts: Minecraft 1.20.1's abandoned mineshafts (MineshaftStructure, MineshaftPieces), at
	a depth under the local surface, and overgrown ones in humid biomes, some of them with a shaft
	open to the sky and a rope all the way down. Full detail (LOD 0) chunks only, like the caves.

	Placement (Config.Mineshafts). One candidate start room per Grid x Grid block cell, kept with
	Chance (128 and 0.25: one in 65536 blocks², Minecraft's 0.4% of chunks, ~15 per km²); its
	corner at a hashed spot of the cell, its floor a hashed Depth (28..64) blocks under the
	surface of its centre column, never below MinY + 4 (a start whose floor can't keep Depth[1]
	under the surface, a deep sea floor, is dropped). Minecraft puts the whole complex's top at
	y -10..52 under a 64 block sea; this world is 1024 tall with mountains, so depth is measured
	from the surface instead (absolute heights would bury them hundreds of blocks deep or in the
	Underlands). Overgrown with clamp((humidity - 0.1) / 0.5, 0, 1) x OvergrownChance by the
	start column's biome (jungles 0.72, birch forests and mushroom fields 0.8, old growth taigas
	0.56, forests and taigas 0.32, groves 0.16, dry biomes never); an overgrown one has an entrance
	with EntranceChance.

	Pieces: Minecraft's grammar, numbers and draws kept, depth first with one random stream per
	mineshaft (Minecraft's rand(n) is rng:int(0, n - 1)):
	  * the room (the start): 8..13 x 5..10 x 8..13 blocks; exits walked along each side
	    (i += rand(span), then 4 on) at 1..ySpan - 4 above the floor; carved: the 3 tall space over
	    the floor, each exit 3 tall, and the upper half ellipsoid dome (x² + y² + z² <= 1.05) above
	    it; the floor stays natural;
	  * a next piece is a crossing (rand(100) >= 80), stairs (>= 70) or a corridor; none past
	    MaxDepth (8) steps, nor starting more than Extent (80) blocks from the room's corner;
	  * corridors: 3 x 3, 5 n long (n = rand(3) + 2, shortened when refused), rails in 1 in 3,
	    a spider corridor in 1 in 23 of the others; then straight on (2 in 4), left or right, at
	    the floor -1, 0 or +1, and side branches every 5 blocks (2 in 5) two steps deeper;
	  * crossings: 5 x 5, 3 tall or two floored (7 tall, 1 in 4), three exits (and four more
	    upstairs, half each); stairs: 3 x 9, five steps of one down.
	  A piece is refused (Minecraft refuses only overlaps) when it reaches below MinY (its floor
	  too), leaves less than Cover blocks of ground over it (at the points of a world-aligned
	  SAMPLE (8) block lattice within 4 blocks of its footprint: a plan reads some 200 columns
	  instead of every one of its pieces'; the write's GUARD keeps a tunnel shut where the ground
	  dips between them), overlaps an earlier piece of this mineshaft, or, grown by MARGIN,
	  overlaps a library structure's piece, an oil well (deposit or lake), a surface lava lake, a
	  water lake or a puddle (Terrain.blocked, with their own margins, asked once per TILE x TILE
	  tile a plan reaches). Minecraft keeps pieces off liquids chunk by chunk
	  (isInInvalidLocation); here every generated liquid is known from plans, the sea and rivers
	  stay above Cover, the lava seas below MinY, and underground lava lakes are kept off
	  mineshafts (`boxes`).
	A plan depends on the seed, its cell and the full detail terrain only (never a chunk's
	blocks), so every chunk, worker and level agrees; plans are kept in an LRU of CACHE cells
	(rejected cells too) per generator, a lookup builds only the cells whose start may reach it
	(`reach`: Extent + 30 blocks every way), and `built` counts the plans built. Measured on seed
	12345 (Lune): 13-14 per km², 60-150 pieces each (some 250), about 130 x 130 blocks; a plan
	builds in 1-3 ms (lakes and puddles worked out too); level 0 chunks over an overgrown one cost
	~12% more than without it, far nodes nothing measurable.

	Writing (`write`, in TerrainGenerator's step 4 after the library structures, before glow
	lichen and plants): every plan reaching the padded chunk, its pieces in plan order clipped to the
	padded box, overgrowth after all of a plan's pieces, every entrance last. Cell rules, which
	keep hidden caves working and a chunk's padding equal to its neighbour's core:
	  * carving: rock (opaque, not bedrock nor this structure's woodwork: planks, logs, chests;
	    Minecraft's canBeReplaced) becomes CaveAir; Air (a surface cave) stays Air, cave air stays,
	    fluids are never touched; and nothing is carved within GUARD blocks of the open above or
	    beside it (each column's and its four neighbours' full detail heights), which a cliff
	    between Cover samples would otherwise open to the sky or the sea;
	  * decorations (fence posts, rails, cobwebs, wall torches, moss carpets, vines, hanging
	    roots, glow lichen) only go into cave air, as their cave twin (cave air while caves are
	    hidden: a hidden mineshaft draws nothing), or into Air, as the block itself; those that
	    hang on a side (torches, vines, lichen) only into cave air. Planks, logs, chests, moss:
	    the same block anywhere;
	  * an opaque or ordinary block is decided by the plan, per cell hashes and the cells of its
	    own column only (every earlier step is the same in a padding column and in the
	    neighbour's core column; ores count as rock, and cave twins as the cave air they could
	    be); only twins read their four sides (a wall to hang on), so a padding ring twin may
	    differ from the neighbour's core (harmless, as CaveDecor's lichen there);
	  * every attached block written is checked at the end and taken away again if what holds it
	    went (a later piece carved its wall or floor);
	  * each written piece's box grown by one (and each log pillar, and the entrance shaft) is
	    marked in the cave lattice to be read cell by cell (Caves.markRead: flags 0 and 2 become
	    1), so World/SectionGraph follows the tunnels. `write` returns the lowest cell written
	    with something that is neither opaque nor a cave cell (Air, ordinary decorations, the
	    rope: TerrainGenerator lowers solidBelow to it) and one above the highest cell written.
	Normal decoration (MineshaftCorridor.postProcess, decided per column): the top layer of a
	corridor 80% carved (a rough ceiling); every 5 blocks a support: a plank beam (a beam plank
	only where the cell above is not open: no beam under a cave; 1 in 4 beams only their two end
	planks) on oak fence posts under its end planks; wall torches 5% each side of a whole beam;
	cobwebs at the top corners next to it, 10% one block away and 5% two away, where the cell above
	is opaque (60% of the lower two layers in a spider corridor); planks over floor cells that are
	not sturdy (bridges over caves) and OakLog pillars down to sturdy ground within PILLAR blocks
	under a bridge's ends (Minecraft's chains up are left out); rails 70% along a rail corridor's
	middle on a sturdy floor; a chest 1% per section side on a sturdy floor (Minecraft's chest
	minecart; no spawners). Crossings: plank pillars at their inner corners under a ceiling,
	plank floors; rooms and stairs: carved only.
	Overgrown (lush caves over a mineshaft, after Minecraft's moss and vine features): rock around
	the open space (CaveDecor's rock, dirt, gravel) becomes Moss Block, floors 60%, ceilings 25%,
	walls 30% (woodwork stays wood); moss carpet on 35% of the floor cells over moss or planks,
	hanging roots under 8% of the sturdy ceilings, vines starting at 15% of the wall cells under a
	ceiling and hanging 1..3 cells, glow lichen on 6% of the other wall cells; cobwebs x 0.3 and
	no spider corridors.

	The entrance (overgrown only): candidates are the room's centre (moved up to 2 blocks) and
	the middle of each corridor section between two supports, in plan order, at most CANDIDATES
	(32: with 12, a third of the mineshafts that want one found none; with 32 about 80% do, so
	about EntranceChance of the overgrown ones have one). The first that passes is taken: its
	3 x 3 opening lies in core columns 2..13 of one chunk
	(so the whole entrance, collar and headframe, is in columns no neighbour holds in its
	padding, and no LOD seam meets it); the 5 x 5 collar's columns are dry land (above sea level
	+ 2, no river) within a block of the centre's height; no surface cave opens there
	(Terrain.carvesTop); no lake, puddle, lava lake, oil well or library piece within MARGIN of
	the collar; SpawnClearance blocks from the spawn; no other piece of the mineshaft in the
	shaft's way. It is written last: the opening Air from the piece's lowest open layer up
	through the ground, a mossy cobblestone collar two deep around it, oak fence posts three
	tall and an oak log beam across them FRAME (3) blocks over the collar, ordinary Rope from
	under the beam's middle down to the floor (every rope hanging from the beam or the rope
	above), and vines on the beam and down the shaft's walls from the collar's top layer. The
	beam is that high so a climber can get out (Shared/Movement/PlayerPhysics): at the top of
	the rope their head (1.8 tall) meets the beam with their feet 1.2 over the collar, enough to
	drift off the rope onto the collar before they drop below its top (under a beam 2 over the
	collar the feet stop at 0.2, and a climber stepping off falls back down the shaft); a wall
	vine reaching the collar's top climbs out as a ladder does. Its box (5 blocks around the centre)
	keeps trees and surface caves away at every level (TerrainGenerator's keepOut).

	Loot (`container`, Minecraft's chests/abandoned_mineshaft on this game's items): a fresh table
	for a chest a plan puts at (x, y, z), rolled from the position alone (LOOT).
]]

local Config = require(script.Parent.Parent.Config)
local Blocks = require(script.Parent.Parent.Blocks)
local Biomes = require(script.Parent.Parent.Biomes)
local ChunkLayout = require(script.Parent.Parent.World.ChunkLayout)
local Hash = require(script.Parent.Parent.Util.Hash)
local Caves = require(script.Parent.Caves)
local CaveDecor = require(script.Parent.CaveDecor)

local SIZE = ChunkLayout.SIZE
local P = ChunkLayout.PADDED
local SEA = Config.SeaLevel

-- Tuning --------------------------------------------------------------------------------------------
local SECTION = 5 -- a corridor section (a support every 5 blocks)
local ROUGH = 0.8 -- share of a corridor's top layer carved
local BROKEN = 4 -- 1 in this many beams keep only their end planks
local TORCH = 0.05 -- a wall torch each side of a whole beam
local WEB_NEAR, WEB_FAR = 0.1, 0.05 -- cobwebs at the top corners one and two blocks from a beam
local SPIDER_WEBS = 0.6 -- share of a spider corridor's lower two layers in cobwebs
local CHEST = 0.01 -- a chest per section side
local RAIL = 0.7 -- share of a rail corridor's middle cells with a rail
local PILLAR = 20 -- a bridge's log pillar reaches this far down (Minecraft's MAX_PILLAR_HEIGHT)
local MOSS_FLOOR, MOSS_CEILING, MOSS_WALL = 0.6, 0.25, 0.3
local CARPET = 0.35
local ROOTS = 0.08
local VINES = 0.15
local VINE_RUN = 3
local LICHEN = 0.06
local OVERGROWN_WEBS = 0.3 -- cobwebs in an overgrown mineshaft, times
local SAMPLE = 8 -- Cover is checked on a world-aligned lattice of columns this far apart
local MARGIN = 2 -- pieces keep this far from lakes, wells, lava lakes, puddles and library pieces
local GUARD = 2 -- blocks kept between a carved cell and the open above or beside it
local CANDIDATES = 32 -- entrance spots tried at most
local SHAFT_VINES = 0.2 -- a vine run from each wall face of the shaft's opening
local BEAM_VINES = 0.25 -- a vine on each side cell of the beam over the opening
local KEEP_OUT = 5 -- trees and surface caves keep this far from an entrance's centre
local FRAME = 3 -- the entrance's beam this far over the collar's top (a climber steps off: header)
local CACHE = 64 -- cells (plans and rejected candidates) kept per generator
local SLOTS = 27 -- a chest's slots

local abs = math.abs
local min, max = math.min, math.max
local huge = math.huge
local readu8 = buffer.readu8
local writeu8 = buffer.writeu8
local readu16 = buffer.readu16
local writeu16 = buffer.writeu16
local bxor = bit32.bxor
local rshift = bit32.rshift

local id = Blocks.id
local AIR, CAVE_AIR, BEDROCK = Blocks.AIR, Blocks.CAVE_AIR, id.Bedrock
local PLANKS, LOG, FENCE, CHEST_BLOCK = id.Planks, id.OakLog, id.OakFence, id.Chest
local COBWEB, MOSS, CARPET_BLOCK, ROOTS_BLOCK = id.Cobweb, id.MossBlock, id.MossCarpet, id.HangingRoots
local MOSSY, ROPE = id.MossyCobblestone, id.Rope
local RAIL_X = Blocks.axisVariant(id.Rail, "X") :: number
local RAIL_Z = Blocks.axisVariant(id.Rail, "Z") :: number

-- Block classes (u8 per id): what carving and the decisions see.
local K_OTHER = 0 -- shaped and see-through blocks (rails, fences, plants...): left alone
local K_AIR = 1 -- Air
local K_CAVE = 2 -- cave air and cave twins (not fluids): open
local K_FLUID = 3 -- every fluid (cave twins too): never touched
local K_ROCK = 4 -- opaque, not bedrock nor woodwork: carved
local K_WOOD = 5 -- planks, logs, chests: kept (Minecraft's canBeReplaced)
local K_HARD = 6 -- bedrock
local KIND = buffer.create(Blocks.count)
-- Twin of each block (u16, 0: none), moss takes (u8), sturdy (Blocks), opaque (Blocks).
local TWIN = buffer.create(Blocks.count * 2)
local MOSSABLE = buffer.create(Blocks.count)
-- 1 for blocks that hang on a neighbour (BlockList `support`).
local ATTACHED = buffer.create(Blocks.count)
local STURDY = Blocks.sturdyLut
local OPAQUE = Blocks.cullLut
local CULL_HIDDEN = Blocks.cullLutHiddenCaves
for blockId = 0, Blocks.count - 1 do
	local def = Blocks.get(blockId)
	local kind = K_OTHER
	if blockId == AIR then
		kind = K_AIR
	elseif def.fluid then
		kind = K_FLUID
	elseif blockId == CAVE_AIR or Blocks.isCaveTwin(blockId) then
		kind = K_CAVE
	elseif blockId == BEDROCK then
		kind = K_HARD
	elseif blockId == PLANKS or blockId == LOG or blockId == CHEST_BLOCK then
		kind = K_WOOD
	elseif readu8(OPAQUE, blockId) == 1 then
		kind = K_ROCK
	end
	writeu8(KIND, blockId, kind)
	writeu16(TWIN, blockId * 2, Blocks.caveTwinFor(blockId) or 0)
	if CaveDecor.isRock(blockId) or blockId == id.Dirt or blockId == id.Gravel then
		writeu8(MOSSABLE, blockId, 1)
	end
	if def.support ~= nil then
		writeu8(ATTACHED, blockId, 1)
	end
end

-- Wall torches, vines and glow lichen by the side they hang on.
local TORCH_ON: { [string]: number } = {}
for _, facing in { "North", "South", "West", "East" } do
	local torch = id["WallTorch" .. facing]
	TORCH_ON[Blocks.get(torch).support :: string] = torch
end
local VINE_ON: { [string]: number } = {}
for _, name in { "Vine", "VineNorth", "VineWest", "VineEast" } do
	VINE_ON[Blocks.get(id[name]).support :: string] = id[name]
end
local LICHEN_ON: { [string]: number } = {}
for _, face in { "North", "South", "West", "East" } do
	local lichen = id["CaveGlowLichen" .. face]
	LICHEN_ON[Blocks.get(lichen).support :: string] = lichen
end
-- The four sides: name and offset.
local SIDES = { "North", "East", "South", "West" }
local SIDE_DX = { 0, 1, 0, -1 }
local SIDE_DZ = { -1, 0, 1, 0 }

-- A cell's u32 hash (CaveDecor's: exact for |x|, |z| < 2^26), salted.
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
-- Salts of the per cell decisions (xored into a piece's salt).
local S_ROUGH, S_WEB, S_RAIL, S_MOSS, S_DECOR, S_SHAFT = 0x51, 0x7EB, 0x2A11, 0x3055, 0xDEC0, 0x5A4F

export type ContainerItem = { slot: number, item: string, count: number, damage: number }

--[[
	A piece. `box`: its cells (x0, y0, z0, x1, y1, z1, inclusive; a room's y0 is its natural
	floor, every other piece's its lowest open layer); `dir`: the way it was entered (North,
	South, West, East; nil for the room), as Minecraft orients it; `salt`: its cell hashes.
	Corridors: `sections` of 5, `rails`, `spider`, and per section `beams` (1 whole, 2 only the
	end planks) and `torches` (bit 1 on the side towards the corridor's start, 2 the other);
	`chests`: x, y, z of each chest the piece places (any piece; corridors). Crossings:
	`twoFloors`. The room: its exits' boxes (`exits`, six numbers each). `outer`: every cell the
	piece may write (its box grown by one: floors, moss; a room's exits too).
]]
export type Piece = {
	kind: string,
	box: { number },
	dir: string?,
	depth: number,
	salt: number,
	sections: number,
	rails: boolean,
	spider: boolean,
	twoFloors: boolean,
	beams: { number },
	torches: { number },
	chests: { number },
	exits: { number },
	outer: { number },
}

--[[
	The surface entrance: the opening's centre column (x, z), `top` that column's height (the
	first air: the collar's top is top - 1, the beam at top + FRAME), `bottom` the lowest open layer
	of the piece it opens into (the rope's last cell), the beam's `axis` ("X" or "Z"), `box` the
	square trees and surface caves keep out of (x0, z0, x1, z1) and `shaft` every cell it writes
	(x0, y0, z0, x1, y1, z1).
]]
export type Entrance = {
	x: number,
	z: number,
	top: number,
	bottom: number,
	axis: string,
	box: { number },
	shaft: { number },
}

--[[
	A mineshaft: its grid cell, the start room's corner and floor (x, y, z), whether it is
	overgrown, its cobwebs' chance factor (`webs`), its pieces in write order, the bounds of
	every cell it may write (x0, y0, z0, x1, y1, z1; the pieces grown by one, the entrance) and
	its entrance (nil: none). Read only.
]]
export type Plan = {
	cellX: number,
	cellZ: number,
	x: number,
	y: number,
	z: number,
	overgrown: boolean,
	webs: number,
	salt: number,
	pieces: { Piece },
	bounds: { number },
	entrance: Entrance?,
}

--[[
	What mineshafts need of the terrain, all at full detail (TerrainGenerator): a column's height
	(first air), river strength (Relief; nil: none) and biome index; the rectangles pieces keep
	MARGIN blocks from (library pieces, oil wells and their lakes, surface lava lakes, water lakes
	and puddles, each with its own margin: x0, z0, x1, z1 per rectangle) touching a block
	rectangle; the spawn column; whether a surface cave may open a column.
]]
export type Terrain = {
	height: (x: number, z: number) -> number,
	biome: (x: number, z: number) -> number,
	river: ((x: number, z: number) -> number)?,
	blocked: ((minX: number, minZ: number, maxX: number, maxZ: number) -> { number })?,
	spawn: (() -> (number, number))?,
	carvesTop: ((x: number, z: number) -> boolean)?,
}

-- A fixed list of plans in place of the grid (the debug structures world): those touching a
-- block rectangle (inclusive).
export type Layout = (minX: number, minZ: number, maxX: number, maxZ: number) -> { Plan }

export type Mineshafts = {
	-- Every plan whose bounds touch the block rectangle (inclusive), in write order. `yield` is
	-- called after each plan built.
	plans: (minX: number, minZ: number, maxX: number, maxZ: number, yield: (() -> ())?) -> { Plan },
	-- Every entrance whose keep-out box touches the block rectangle (only builds the plans that
	-- may have one: cheap for far chunks).
	entrances: (minX: number, minZ: number, maxX: number, maxZ: number) -> { Entrance },
	-- The boxes an underground lava lake must not overlap (every piece grown by MARGIN and every
	-- entrance shaft of the plans touching the rectangle; six numbers each).
	boxes: (minX: number, minZ: number, maxX: number, maxZ: number) -> { number },
	--[[
		Writes `plans` into the padded full detail chunk `data` (first core column originX,
		originZ; `cells` tall; `heights` per padded column at pz * PADDED + px + 1: its full
		detail height) and marks `carved` (the chunk's cave lattice, nil: none yet). Returns the
		lowest cell written with something neither opaque nor a cave cell (math.huge: none), one
		above the highest cell written (0: none) and the lattice.
	]]
	write: (
		plans: { Plan },
		data: buffer,
		originX: number,
		originZ: number,
		cells: number,
		heights: { number },
		carved: Caves.Carved?
	) -> (number, number, Caves.Carved?),
	-- The items of the chest a mineshaft puts at (x, y, z), nil when it puts none there (a fresh
	-- table each call).
	container: (x: number, y: number, z: number) -> { ContainerItem }?,
	-- Plans built (not served from the cache) so far.
	built: () -> number,
}

local Mineshafts = {}

Mineshafts.SECTION = SECTION
Mineshafts.MARGIN = MARGIN
Mineshafts.GUARD = GUARD
Mineshafts.KEEP_OUT = KEEP_OUT
Mineshafts.FRAME = FRAME
Mineshafts.CACHE = CACHE
Mineshafts.PILLAR = PILLAR
Mineshafts.SLOTS = SLOTS

-- How far a plan's bounds (and its entrance's keep-out box) reach from its start room's corner,
-- every way (blocks): pieces start within Extent of the corner and run 19 further, 3 wide, grown
-- by one; an entrance's keep-out box reaches KEEP_OUT past a piece's middle.
local function reach(): number
	return Config.Mineshafts.Extent + 30
end
Mineshafts.reach = reach

--[[ Loot ]]

--[[
	Minecraft's chests/abandoned_mineshaft on this game's items: { item (false: nothing), weight,
	fewest, most } per entry. Pool 1: the golden apples, name tag and enchanted book are left out
	(nothing). Pool 2: redstone -> raw iron, lapis -> raw gold, bread -> cooked porkchop, glow
	berries -> glow dust, the three seeds -> mint leaves, ginger root and straw. Pool 3: the
	powered, detector and activator rails -> nothing, and Supplementaries' rope.
]]
local LOOT: { { rolls: { number }, entries: { { any } } } } = {
	{ rolls = { 1, 1 }, entries = { { "IronPickaxe", 5, 1, 1 }, { false, 66, 0, 0 } } },
	{
		rolls = { 2, 4 },
		entries = {
			{ "IronIngot", 10, 1, 5 },
			{ "GoldIngot", 5, 1, 3 },
			{ "RawIron", 5, 2, 5 },
			{ "RawGold", 5, 1, 3 },
			{ "Diamond", 3, 1, 2 },
			{ "Coal", 10, 3, 8 },
			{ "CookedPorkchop", 15, 1, 3 },
			{ "GlowDust", 15, 2, 4 },
			{ "MintLeaves", 10, 2, 4 },
			{ "GingerRoot", 10, 2, 4 },
			{ "Straw", 10, 2, 4 },
		},
	},
	{
		rolls = { 3, 3 },
		entries = { { "Rail", 20, 4, 8 }, { "Torch", 15, 1, 16 }, { "Rope", 10, 4, 8 }, { false, 15, 0, 0 } },
	},
}
Mineshafts.LOOT = LOOT

-- The items of a chest at (x, y, z) (`salt`: the seed's loot salt): a fresh table.
function Mineshafts.loot(salt: number, x: number, y: number, z: number): { ContainerItem }
	local rng = Hash.rng(Hash.hash3(salt, x, y, z))
	local free: { number } = table.create(SLOTS)
	for slot = 1, SLOTS do
		free[slot] = slot
	end
	local items: { ContainerItem } = {}
	for _, pool in LOOT do
		local total = 0
		for _, entry in pool.entries do
			total += entry[2]
		end
		for _ = 1, rng:int(pool.rolls[1], pool.rolls[2]) do
			local pick = rng:int(0, total - 1)
			for _, entry in pool.entries do
				pick -= entry[2]
				if pick < 0 then
					if entry[1] and #free > 0 then
						local k = rng:int(1, #free)
						local slot = table.remove(free, k) :: number
						table.insert(
							items,
							{ slot = slot, item = entry[1], count = rng:int(entry[3], entry[4]), damage = 0 }
						)
					end
					break
				end
			end
		end
	end
	return items
end

--[[ Geometry ]]

local function intersects(a: { number }, b: { number }): boolean
	return a[1] <= b[4] and a[4] >= b[1] and a[2] <= b[5] and a[5] >= b[2] and a[3] <= b[6] and a[6] >= b[3]
end

local function newPiece(kind: string, box: { number }, dir: string?, depth: number, salt: number): Piece
	return {
		kind = kind,
		box = box,
		dir = dir,
		depth = depth,
		salt = salt,
		sections = 0,
		rails = false,
		spider = false,
		twoFloors = false,
		beams = {},
		torches = {},
		chests = {},
		exits = {},
		outer = { box[1] - 1, box[2] - 1, box[3] - 1, box[4] + 1, box[5] + 1, box[6] + 1 },
	}
end

-- A room's outer box takes in its exits (a two floored crossing's reaches above the room).
local function finishRoom(room: Piece)
	local outer, exits = room.outer, room.exits
	for i = 1, #exits, 6 do
		for k = 0, 2 do
			outer[1 + k] = min(outer[1 + k], exits[i + k] - 1)
			outer[4 + k] = max(outer[4 + k], exits[i + 3 + k] + 1)
		end
	end
end

-- The bounds of a plan's pieces and entrance (x0, y0, z0, x1, y1, z1).
local function boundsOf(pieces: { Piece }, entrance: Entrance?): { number }
	local bounds = { huge, huge, huge, -huge, -huge, -huge }
	for _, piece in pieces do
		local outer = piece.outer
		for k = 1, 3 do
			bounds[k] = min(bounds[k], outer[k])
			bounds[k + 3] = max(bounds[k + 3], outer[k + 3])
		end
	end
	if entrance then
		local shaft = entrance.shaft
		for k = 1, 3 do
			bounds[k] = min(bounds[k], shaft[k])
			bounds[k + 3] = max(bounds[k + 3], shaft[k + 3])
		end
	end
	return bounds
end

-- World column of a corridor's or stairs' local (lx across, lz along) cell (StructurePiece's
-- getWorldX / getWorldZ for its orientation).
local function toWorld(piece: Piece, lx: number, lz: number): (number, number)
	local b, dir = piece.box, piece.dir
	if dir == "North" then
		return b[1] + lx, b[6] - lz
	elseif dir == "South" then
		return b[1] + lx, b[3] + lz
	elseif dir == "West" then
		return b[4] - lz, b[3] + lx
	end
	return b[1] + lz, b[3] + lx
end

-- The other way: local (lx, lz) of world column (x, z).
local function toLocal(piece: Piece, x: number, z: number): (number, number)
	local b, dir = piece.box, piece.dir
	if dir == "North" then
		return x - b[1], b[6] - z
	elseif dir == "South" then
		return x - b[1], z - b[3]
	elseif dir == "West" then
		return z - b[3], b[4] - x
	end
	return z - b[3], x - b[1]
end

-- Does the piece open cell (x, y, z) (its plan alone: what carving makes cave air)?
local function opens(piece: Piece, x: number, y: number, z: number): boolean
	local b = piece.box
	local kind = piece.kind
	if kind == "corridor" then
		local lx, lz = toLocal(piece, x, z)
		local ly = y - b[2]
		if lx < 0 or lx > 2 or lz < 0 or lz > piece.sections * SECTION - 1 or ly < 0 or ly > 2 then
			return false
		end
		return ly < 2 or roll(bxor(piece.salt, S_ROUGH), x, y, z) < ROUGH
	elseif kind == "room" then
		-- Each exit, 3 tall (it may reach a block past the room's side).
		local exits = piece.exits
		for i = 1, #exits, 6 do
			if
				x >= exits[i]
				and x <= exits[i + 3]
				and z >= exits[i + 2]
				and z <= exits[i + 5]
				and y >= exits[i + 4] - 2
				and y <= exits[i + 4]
			then
				return true
			end
		end
		if x < b[1] or x > b[4] or z < b[3] or z > b[6] or y <= b[2] or y > b[5] then
			return false
		end
		if y <= b[2] + 3 then
			return true
		end
		-- The upper half ellipsoid (StructurePiece.generateUpperHalfSphere) from y0 + 4 up.
		local fx, fy, fz = b[4] - b[1] + 1, b[5] - (b[2] + 4) + 1, b[6] - b[3] + 1
		local nx = (x - (b[1] + fx / 2)) / (fx * 0.5)
		local ny = (y - (b[2] + 4)) / fy
		local nz = (z - (b[3] + fz / 2)) / (fz * 0.5)
		return nx * nx + ny * ny + nz * nz <= 1.05
	elseif kind == "crossing" then
		if x < b[1] or x > b[4] or z < b[3] or z > b[6] or y < b[2] or y > b[5] then
			return false
		end
		local cross = (x > b[1] and x < b[4]) or (z > b[3] and z < b[6])
		if not piece.twoFloors then
			return cross
		end
		if y <= b[2] + 2 or y >= b[5] - 2 then
			return cross
		end
		return y == b[2] + 3 and x > b[1] and x < b[4] and z > b[3] and z < b[6]
	end
	-- Stairs: the top landing, five steps of one down, the bottom landing.
	local lx, lz = toLocal(piece, x, z)
	local ly = y - b[2]
	if lx < 0 or lx > 2 or lz < 0 or lz > 8 or ly < 0 or ly > 7 then
		return false
	end
	if lz <= 1 then
		return ly >= 5
	elseif lz >= 7 then
		return ly <= 2
	end
	local i = lz - 2
	return ly >= 5 - i - (if i < 4 then 1 else 0) and ly <= 7 - i
end
Mineshafts.opens = opens

-- The lowest open layer of a piece (where a rope from an entrance ends).
local function bottomOf(piece: Piece): number
	return if piece.kind == "room" then piece.box[2] + 1 else piece.box[2]
end

--[[ Plans ]]

--[[
	A plan's place before its pieces (the cheap part of a grid cell: whether it has a candidate,
	where, overgrown or not), with its random stream ready for the pieces.
]]
type Start = {
	rng: Hash.Rng,
	salt: number,
	x: number,
	z: number,
	sx: number,
	sy: number,
	sz: number,
	y: number,
	overgrown: boolean,
	entrance: boolean,
}

type Cell = {
	used: number,
	start: Start | false,
	plan: Plan | false | nil,
}

-- Everything a plan's pieces are checked against while it is built.
type Build = {
	pieces: { Piece },
	salt: number,
	overgrown: boolean,
	heights: { [number]: number },
	tiles: { [number]: { number } },
}

local function columnKey(x: number, z: number): number
	return (x + 1048576) * 2097152 + (z + 1048576)
end

local TILE = 64

function Mineshafts.new(seed: number, terrain: Terrain, layout: Layout?): Mineshafts
	local cfg = Config.Mineshafts
	local GRID, CHANCE = cfg.Grid, cfg.Chance
	local DEPTH_MIN, DEPTH_MAX = cfg.Depth[1], cfg.Depth[2]
	local MIN_Y, COVER = cfg.MinY, cfg.Cover
	local MAX_DEPTH, EXTENT = cfg.MaxDepth, cfg.Extent
	local REACH = reach()
	local salt = Hash.hash2(seed, Hash.string("mineshafts"), 0x4D53)
	local lootSalt = Hash.hash2(seed, Hash.string("mineshafts.loot"), 0x100E)
	local height = terrain.height
	local builtCount = 0

	--[[ Checks while building ]]

	local function heightAt(b: Build, x: number, z: number): number
		local key = columnKey(x, z)
		local h = b.heights[key]
		if h == nil then
			h = height(x, z)
			b.heights[key] = h
		end
		return h
	end

	-- Cover blocks of ground over the box at every point of the world-aligned SAMPLE lattice
	-- within SAMPLE / 2 of its footprint (so every column of it has one that near; the points are
	-- shared by the pieces around). What lies between is the write's GUARD's.
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

	-- Clear of everything Terrain.blocked lists, MARGIN blocks around the rectangle (asked per
	-- TILE x TILE tile, once per plan).
	local function clear(b: Build, x0: number, z0: number, x1: number, z1: number): boolean
		local blocked = terrain.blocked
		if blocked == nil then
			return true
		end
		x0, z0, x1, z1 = x0 - MARGIN, z0 - MARGIN, x1 + MARGIN, z1 + MARGIN
		for tz = z0 // TILE, z1 // TILE do
			for tx = x0 // TILE, x1 // TILE do
				local key = columnKey(tx, tz)
				local list = b.tiles[key]
				if list == nil then
					list = blocked(tx * TILE, tz * TILE, tx * TILE + TILE - 1, tz * TILE + TILE - 1)
					b.tiles[key] = list
				end
				for i = 1, #list, 4 do
					if list[i] <= x1 and list[i + 2] >= x0 and list[i + 1] <= z1 and list[i + 3] >= z0 then
						return false
					end
				end
			end
		end
		return true
	end

	-- May a piece take `box` (MinY, no overlap, Cover, clear)?
	local function accept(b: Build, box: { number }): boolean
		if box[2] - 1 < MIN_Y then
			return false
		end
		for _, piece in b.pieces do
			if intersects(piece.box, box) then
				return false
			end
		end
		return covered(b, box) and clear(b, box[1], box[3], box[4], box[6])
	end

	--[[ The grammar (MineshaftPieces) ]]

	local addChildren: (b: Build, rng: Hash.Rng, piece: Piece) -> ()

	local function pieceSalt(b: Build): number
		return Hash.hash3(b.salt, #b.pieces + 1, 0x9E, 0)
	end

	-- createRandomShaftPiece: a crossing, stairs or a corridor at (x, y, z) heading `dir`.
	local function createPiece(
		b: Build,
		rng: Hash.Rng,
		x: number,
		y: number,
		z: number,
		dir: string,
		depth: number
	): Piece?
		local r = rng:int(0, 99)
		if r >= 80 then
			local h = if rng:int(0, 3) == 0 then 6 else 2
			local box
			if dir == "North" then
				box = { x - 1, y, z - 4, x + 3, y + h, z }
			elseif dir == "South" then
				box = { x - 1, y, z, x + 3, y + h, z + 4 }
			elseif dir == "West" then
				box = { x - 4, y, z - 1, x, y + h, z + 3 }
			else
				box = { x, y, z - 1, x + 4, y + h, z + 3 }
			end
			if not accept(b, box) then
				return nil
			end
			local piece = newPiece("crossing", box, dir, depth, pieceSalt(b))
			piece.twoFloors = h == 6
			return piece
		elseif r >= 70 then
			local box
			if dir == "North" then
				box = { x, y - 5, z - 8, x + 2, y + 2, z }
			elseif dir == "South" then
				box = { x, y - 5, z, x + 2, y + 2, z + 8 }
			elseif dir == "West" then
				box = { x - 8, y - 5, z, x, y + 2, z + 2 }
			else
				box = { x, y - 5, z, x + 8, y + 2, z + 2 }
			end
			if not accept(b, box) then
				return nil
			end
			return newPiece("stairs", box, dir, depth, pieceSalt(b))
		end
		-- A corridor, shortened while refused.
		for n = rng:int(0, 2) + 2, 1, -1 do
			local len = n * SECTION
			local box
			if dir == "North" then
				box = { x, y, z - len + 1, x + 2, y + 2, z }
			elseif dir == "South" then
				box = { x, y, z, x + 2, y + 2, z + len - 1 }
			elseif dir == "West" then
				box = { x - len + 1, y, z, x, y + 2, z + 2 }
			else
				box = { x, y, z, x + len - 1, y + 2, z + 2 }
			end
			if accept(b, box) then
				local piece = newPiece("corridor", box, dir, depth, pieceSalt(b))
				piece.sections = n
				piece.rails = rng:int(0, 2) == 0
				local spider = not piece.rails and rng:int(0, 22) == 0
				piece.spider = spider and not b.overgrown
				-- What Minecraft decides in postProcess, decided here from the piece's salt: each
				-- support's beam and torches, each section side's chest.
				local own = Hash.rng(piece.salt)
				for i = 0, n - 1 do
					local broken = own:int(0, BROKEN - 1) == 0
					piece.beams[i + 1] = if broken then 2 else 1
					local torches = 0
					if own:float() < TORCH then
						torches += 1
					end
					if own:float() < TORCH then
						torches += 2
					end
					piece.torches[i + 1] = torches
					local lz = 2 + i * SECTION
					for side = 0, 1 do
						if own:float() < CHEST then
							local cx, cz =
								toWorld(piece, if side == 0 then 2 else 0, if side == 0 then lz - 1 else lz + 1)
							table.insert(piece.chests, cx)
							table.insert(piece.chests, y)
							table.insert(piece.chests, cz)
						end
					end
				end
				return piece
			end
		end
		return nil
	end

	-- generateAndAddPiece.
	local function generate(
		b: Build,
		rng: Hash.Rng,
		x: number,
		y: number,
		z: number,
		dir: string,
		depth: number
	): Piece?
		if depth > MAX_DEPTH then
			return nil
		end
		local room = b.pieces[1].box
		if abs(x - room[1]) <= EXTENT and abs(z - room[3]) <= EXTENT then
			local piece = createPiece(b, rng, x, y, z, dir, depth + 1)
			if piece then
				table.insert(b.pieces, piece)
				addChildren(b, rng, piece)
			end
			return piece
		end
		return nil
	end

	function addChildren(b: Build, rng: Hash.Rng, piece: Piece)
		local box, depth, dir = piece.box, piece.depth, piece.dir
		local x0, y0, z0, x1, y1, z1 = box[1], box[2], box[3], box[4], box[5], box[6]
		if piece.kind == "room" then
			local v = max(y1 - y0 + 1 - 4, 1)
			for side = 1, 4 do
				local northSouth = side <= 2
				local span = if northSouth then x1 - x0 + 1 else z1 - z0 + 1
				local i = 0
				while i < span do
					i += rng:int(0, span - 1)
					if i + 3 > span then
						break
					end
					local cy = y0 + rng:int(0, v - 1) + 1
					local child
					if side == 1 then
						child = generate(b, rng, x0 + i, cy, z0 - 1, "North", depth)
					elseif side == 2 then
						child = generate(b, rng, x0 + i, cy, z1 + 1, "South", depth)
					elseif side == 3 then
						child = generate(b, rng, x0 - 1, cy, z0 + i, "West", depth)
					else
						child = generate(b, rng, x1 + 1, cy, z0 + i, "East", depth)
					end
					if child then
						local c = child.box
						local exit
						if side == 1 then
							exit = { c[1], c[2], z0, c[4], c[5], z0 + 1 }
						elseif side == 2 then
							exit = { c[1], c[2], z1 - 1, c[4], c[5], z1 }
						elseif side == 3 then
							exit = { x0, c[2], c[3], x0 + 1, c[5], c[6] }
						else
							exit = { x1 - 1, c[2], c[3], x1, c[5], c[6] }
						end
						table.move(exit, 1, 6, #piece.exits + 1, piece.exits)
					end
					i += 4
				end
			end
		elseif piece.kind == "corridor" then
			local r = rng:int(0, 3)
			local cy = y0 - 1 + rng:int(0, 2)
			if dir == "North" then
				if r <= 1 then
					generate(b, rng, x0, cy, z0 - 1, "North", depth)
				elseif r == 2 then
					generate(b, rng, x0 - 1, cy, z0, "West", depth)
				else
					generate(b, rng, x1 + 1, cy, z0, "East", depth)
				end
			elseif dir == "South" then
				if r <= 1 then
					generate(b, rng, x0, cy, z1 + 1, "South", depth)
				elseif r == 2 then
					generate(b, rng, x0 - 1, cy, z1 - 3, "West", depth)
				else
					generate(b, rng, x1 + 1, cy, z1 - 3, "East", depth)
				end
			elseif dir == "West" then
				if r <= 1 then
					generate(b, rng, x0 - 1, cy, z0, "West", depth)
				elseif r == 2 then
					generate(b, rng, x0, cy, z0 - 1, "North", depth)
				else
					generate(b, rng, x0, cy, z1 + 1, "South", depth)
				end
			else
				if r <= 1 then
					generate(b, rng, x1 + 1, cy, z0, "East", depth)
				elseif r == 2 then
					generate(b, rng, x1 - 3, cy, z0 - 1, "North", depth)
				else
					generate(b, rng, x1 - 3, cy, z1 + 1, "South", depth)
				end
			end
			if depth < MAX_DEPTH then
				if dir == "West" or dir == "East" then
					local x = x0 + 3
					while x + 3 <= x1 do
						local s = rng:int(0, 4)
						if s == 0 then
							generate(b, rng, x, y0, z0 - 1, "North", depth + 1)
						elseif s == 1 then
							generate(b, rng, x, y0, z1 + 1, "South", depth + 1)
						end
						x += SECTION
					end
				else
					local z = z0 + 3
					while z + 3 <= z1 do
						local s = rng:int(0, 4)
						if s == 0 then
							generate(b, rng, x0 - 1, y0, z, "West", depth + 1)
						elseif s == 1 then
							generate(b, rng, x1 + 1, y0, z, "East", depth + 1)
						end
						z += SECTION
					end
				end
			end
		elseif piece.kind == "crossing" then
			if dir == "North" then
				generate(b, rng, x0 + 1, y0, z0 - 1, "North", depth)
				generate(b, rng, x0 - 1, y0, z0 + 1, "West", depth)
				generate(b, rng, x1 + 1, y0, z0 + 1, "East", depth)
			elseif dir == "South" then
				generate(b, rng, x0 + 1, y0, z1 + 1, "South", depth)
				generate(b, rng, x0 - 1, y0, z0 + 1, "West", depth)
				generate(b, rng, x1 + 1, y0, z0 + 1, "East", depth)
			elseif dir == "West" then
				generate(b, rng, x0 + 1, y0, z0 - 1, "North", depth)
				generate(b, rng, x0 + 1, y0, z1 + 1, "South", depth)
				generate(b, rng, x0 - 1, y0, z0 + 1, "West", depth)
			else
				generate(b, rng, x0 + 1, y0, z0 - 1, "North", depth)
				generate(b, rng, x0 + 1, y0, z1 + 1, "South", depth)
				generate(b, rng, x1 + 1, y0, z0 + 1, "East", depth)
			end
			if piece.twoFloors then
				if rng:int(0, 1) == 1 then
					generate(b, rng, x0 + 1, y0 + 4, z0 - 1, "North", depth)
				end
				if rng:int(0, 1) == 1 then
					generate(b, rng, x0 - 1, y0 + 4, z0 + 1, "West", depth)
				end
				if rng:int(0, 1) == 1 then
					generate(b, rng, x1 + 1, y0 + 4, z0 + 1, "East", depth)
				end
				if rng:int(0, 1) == 1 then
					generate(b, rng, x0 + 1, y0 + 4, z1 + 1, "South", depth)
				end
			end
		else
			if dir == "North" then
				generate(b, rng, x0, y0, z0 - 1, "North", depth)
			elseif dir == "South" then
				generate(b, rng, x0, y0, z1 + 1, "South", depth)
			elseif dir == "West" then
				generate(b, rng, x0 - 1, y0, z0, "West", depth)
			else
				generate(b, rng, x1 + 1, y0, z0, "East", depth)
			end
		end
	end

	--[[ The entrance ]]

	-- The opening's three columns along each axis lie in core columns 2..13 of one chunk.
	local function inCore(c: number): boolean
		local m = c % SIZE
		return m >= 3 and m <= SIZE - 4
	end

	-- Does an entrance at (cx, cz) over `piece` pass (see the header)? Returns it.
	local function tryEntrance(b: Build, piece: Piece, cx: number, cz: number, axis: string): Entrance?
		local h0 = heightAt(b, cx, cz)
		if h0 <= SEA + 2 then
			return nil
		end
		local bottom = bottomOf(piece)
		local river = terrain.river
		for dz = -2, 2 do
			for dx = -2, 2 do
				local x, z = cx + dx, cz + dz
				local h = heightAt(b, x, z)
				if abs(h - h0) > 1 or h <= SEA + 2 or (river and river(x, z) > 0) then
					return nil
				end
			end
		end
		-- No other piece in the shaft's way, from the piece up through the ground.
		local shaftBox = { cx - 2, bottom, cz - 2, cx + 2, h0 + FRAME + 1, cz + 2 }
		for _, other in b.pieces do
			if other ~= piece then
				local o = other.box
				local grown = { o[1] - 1, o[2] - 1, o[3] - 1, o[4] + 1, o[5] + 1, o[6] + 1 }
				if intersects(grown, shaftBox) then
					return nil
				end
			end
		end
		if not clear(b, cx - 2, cz - 2, cx + 2, cz + 2) then
			return nil
		end
		local spawn = terrain.spawn
		if spawn then
			local sx, sz = spawn()
			local d = cfg.SpawnClearance
			if (cx - sx) * (cx - sx) + (cz - sz) * (cz - sz) < d * d then
				return nil
			end
		end
		local carvesTop = terrain.carvesTop
		if carvesTop then
			for dz = -2, 2 do
				for dx = -2, 2 do
					if carvesTop(cx + dx, cz + dz) then
						return nil
					end
				end
			end
		end
		return {
			x = cx,
			z = cz,
			top = h0,
			bottom = bottom,
			axis = axis,
			box = { cx - KEEP_OUT, cz - KEEP_OUT, cx + KEEP_OUT, cz + KEEP_OUT },
			shaft = { cx - 2, bottom - 1, cz - 2, cx + 2, h0 + FRAME + 1, cz + 2 },
		}
	end

	-- The first candidate that passes, in plan order (the room's centre, then the middle of each
	-- corridor section between two supports), at most CANDIDATES tried.
	local function findEntrance(b: Build): Entrance?
		local tried = 0
		local room = b.pieces[1]
		local rb = room.box
		local mx, mz = (rb[1] + rb[4]) // 2, (rb[3] + rb[6]) // 2
		-- The room's centre, moved up to 2 blocks (nearest first) to lie in a chunk's core.
		local best: { number }? = nil
		for dz = -2, 2 do
			for dx = -2, 2 do
				local cx, cz = mx + dx, mz + dz
				if
					inCore(cx)
					and inCore(cz)
					and cx - 1 >= rb[1]
					and cx + 1 <= rb[4]
					and cz - 1 >= rb[3]
					and cz + 1 <= rb[6]
				then
					local d = abs(dx) + abs(dz)
					if best == nil or d < best[3] then
						best = { cx, cz, d }
					end
				end
			end
		end
		if best then
			tried += 1
			local axis = if Hash.hash3(b.salt, 0x5A, 0, 0) % 2 == 0 then "X" else "Z"
			local found = tryEntrance(b, room, best[1], best[2], axis)
			if found then
				return found
			end
		end
		for _, piece in b.pieces do
			if piece.kind ~= "corridor" then
				continue
			end
			local axis = if piece.dir == "West" or piece.dir == "East" then "Z" else "X"
			for i = 0, piece.sections - 2 do
				local cx, cz = toWorld(piece, 1, SECTION * i + 4)
				if inCore(cx) and inCore(cz) then
					if tried >= CANDIDATES then
						return nil
					end
					tried += 1
					local found = tryEntrance(b, piece, cx, cz, axis)
					if found then
						return found
					end
				end
			end
		end
		return nil
	end

	--[[ Grid cells ]]

	local cache: { [number]: Cell } = {}
	local cached, clock = 0, 0

	-- The cheap part of cell (gx, gz): false when it has no start.
	local function startOf(gx: number, gz: number): Start | false
		local rng = Hash.rng(Hash.hash3(salt, gx, 0, gz))
		if rng:float() >= CHANCE then
			return false
		end
		local x = gx * GRID + rng:int(0, GRID - 14)
		local z = gz * GRID + rng:int(0, GRID - 14)
		-- MineShaftRoom's box: 7 + rand(6), 4 + rand(6), 7 + rand(6) past the corner.
		local sx, sy, sz = 7 + rng:int(0, 5), 4 + rng:int(0, 5), 7 + rng:int(0, 5)
		local depth = rng:int(DEPTH_MIN, DEPTH_MAX)
		local overgrownRoll, entranceRoll = rng:float(), rng:float()
		local cx, cz = x + sx // 2, z + sz // 2
		local h = height(cx, cz)
		local y = max(h - depth, MIN_Y + 4)
		if y > h - DEPTH_MIN then
			return false
		end
		local humidity = Biomes.list[terrain.biome(cx, cz)].humidity
		local lo, hi = cfg.OvergrownHumidity[1], cfg.OvergrownHumidity[2]
		local chance = math.clamp((humidity - lo) / (hi - lo), 0, 1) * cfg.OvergrownChance
		local overgrown = overgrownRoll < chance
		return {
			rng = rng,
			salt = Hash.hash3(salt, gx, 1, gz),
			x = x,
			z = z,
			sx = sx,
			sy = sy,
			sz = sz,
			y = y,
			overgrown = overgrown,
			entrance = overgrown and entranceRoll < cfg.EntranceChance,
		}
	end

	-- The plan of a start (false: its room is refused).
	local function build(gx: number, gz: number, s: Start): Plan | false
		builtCount += 1
		local b: Build = { pieces = {}, salt = s.salt, overgrown = s.overgrown, heights = {}, tiles = {} }
		local roomBox = { s.x, s.y, s.z, s.x + s.sx, s.y + s.sy, s.z + s.sz }
		if not accept(b, roomBox) then
			return false
		end
		local room = newPiece("room", roomBox, nil, 0, Hash.hash3(s.salt, 1, 0x9E, 0))
		table.insert(b.pieces, room)
		addChildren(b, s.rng, room)
		finishRoom(room)
		local entrance = if s.entrance then findEntrance(b) else nil
		return {
			cellX = gx,
			cellZ = gz,
			x = s.x,
			y = s.y,
			z = s.z,
			overgrown = s.overgrown,
			webs = if s.overgrown then OVERGROWN_WEBS else 1,
			salt = s.salt,
			pieces = b.pieces,
			bounds = boundsOf(b.pieces, entrance),
			entrance = entrance,
		}
	end

	local function cellAt(gx: number, gz: number): Cell
		local key = columnKey(gx, gz)
		local cell = cache[key]
		clock += 1
		if cell == nil then
			if cached >= CACHE then
				local oldest, oldestKey = huge, nil
				for k, c in cache do
					if c.used < oldest then
						oldest, oldestKey = c.used, k
					end
				end
				if oldestKey then
					cache[oldestKey] = nil
					cached -= 1
				end
			end
			cell = { used = clock, start = startOf(gx, gz), plan = nil }
			cache[key] = cell
			cached += 1
		end
		assert(cell)
		cell.used = clock
		return cell
	end

	local function planAt(gx: number, gz: number, yield: (() -> ())?): Plan?
		local cell = cellAt(gx, gz)
		if cell.start == false then
			return nil
		end
		if cell.plan == nil then
			cell.plan = build(gx, gz, cell.start :: Start)
			if yield then
				yield()
			end
		end
		local plan = cell.plan
		return if plan then plan :: Plan else nil
	end

	local function plans(minX: number, minZ: number, maxX: number, maxZ: number, yield: (() -> ())?): { Plan }
		if layout then
			return layout(minX, minZ, maxX, maxZ)
		end
		local list: { Plan } = {}
		for gz = (minZ - REACH - GRID + 14) // GRID, (maxZ + REACH) // GRID do
			for gx = (minX - REACH - GRID + 14) // GRID, (maxX + REACH) // GRID do
				-- Only starts that may reach the rectangle are built.
				local start = cellAt(gx, gz).start
				if start == false then
					continue
				end
				local s = start :: Start
				if s.x - REACH > maxX or s.x + REACH < minX or s.z - REACH > maxZ or s.z + REACH < minZ then
					continue
				end
				local plan = planAt(gx, gz, yield)
				if plan then
					local b = plan.bounds
					if b[1] <= maxX and b[4] >= minX and b[3] <= maxZ and b[6] >= minZ then
						table.insert(list, plan)
					end
				end
			end
		end
		return list
	end

	local function entrances(minX: number, minZ: number, maxX: number, maxZ: number): { Entrance }
		local list: { Entrance } = {}
		local function add(plan: Plan)
			local e = plan.entrance
			if e and e.box[1] <= maxX and e.box[3] >= minX and e.box[2] <= maxZ and e.box[4] >= minZ then
				table.insert(list, e)
			end
		end
		if layout then
			for _, plan in layout(minX, minZ, maxX, maxZ) do
				add(plan)
			end
			return list
		end
		for gz = (minZ - REACH - GRID + 14) // GRID, (maxZ + REACH) // GRID do
			for gx = (minX - REACH - GRID + 14) // GRID, (maxX + REACH) // GRID do
				-- Only starts that may have one reaching the rectangle are built.
				local start = cellAt(gx, gz).start
				if start == false then
					continue
				end
				local s = start :: Start
				if s.x - REACH > maxX or s.x + REACH < minX or s.z - REACH > maxZ or s.z + REACH < minZ then
					continue
				end
				if s.entrance then
					local plan = planAt(gx, gz)
					if plan then
						add(plan)
					end
				end
			end
		end
		return list
	end

	local function boxes(minX: number, minZ: number, maxX: number, maxZ: number): { number }
		local list: { number } = {}
		for _, plan in plans(minX, minZ, maxX, maxZ) do
			for _, piece in plan.pieces do
				local b = piece.outer
				table.insert(list, b[1] - MARGIN + 1)
				table.insert(list, b[2] - MARGIN + 1)
				table.insert(list, b[3] - MARGIN + 1)
				table.insert(list, b[4] + MARGIN - 1)
				table.insert(list, b[5] + MARGIN - 1)
				table.insert(list, b[6] + MARGIN - 1)
			end
			local e = plan.entrance
			if e then
				table.move(e.shaft, 1, 6, #list + 1, list)
			end
		end
		return list
	end

	local function container(x: number, y: number, z: number): { ContainerItem }?
		for _, plan in plans(x, z, x, z) do
			for _, piece in plan.pieces do
				local chests = piece.chests
				for i = 1, #chests, 3 do
					if chests[i] == x and chests[i + 1] == y and chests[i + 2] == z then
						return Mineshafts.loot(lootSalt, x, y, z)
					end
				end
			end
		end
		return nil
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
		return Mineshafts.write(list, data, originX, originZ, cells, heights, carved, height)
	end

	return {
		plans = plans,
		entrances = entrances,
		boxes = boxes,
		write = write,
		container = container,
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
local wOutside: (x: number, z: number) -> number = function(): number
	return 0
end
-- Per padded column: the highest cell carving may reach (UNKNOWN: not worked out yet).
local UNKNOWN = -huge
local wLimit: { number } = table.create(P * P, UNKNOWN)
-- Byte offsets of the attached blocks written.
local wAttached: { number } = {}
-- Pillar columns written (x, y0, z, y1 each), to mark in the lattice.
local wPillars: { number } = {}
-- A piece's open cells over a box: u8 per cell.
local mask = buffer.create(4096)
local mX0, mY0, mZ0, mNX, mNY, mNZ = 0, 0, 0, 0, 0, 0

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

local function kindOf(block: number): number
	return if block < 0 then K_HARD else readu8(KIND, block)
end

local function isOpen(block: number): boolean
	local k = kindOf(block)
	return k == K_AIR or k == K_CAVE
end

local function isSturdy(block: number): boolean
	return block >= 0 and readu8(STURDY, block) == 1
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

-- The highest cell carving may reach in column (x, z): GUARD blocks under its own surface's top
-- block and under its four neighbours' surfaces.
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

-- Rock at (x, y, z) becomes cave air.
local function carve(x: number, y: number, z: number)
	local o = at(x, y, z)
	if o >= 0 and readu8(KIND, readu16(wData, o)) == K_ROCK and y <= limitAt(x, z) then
		put(o, y, CAVE_AIR)
	end
end

-- A decoration: its cave twin into cave air, the block itself into Air.
local function decorate(x: number, y: number, z: number, block: number)
	local o = at(x, y, z)
	if o < 0 then
		return
	end
	local here = readu16(wData, o)
	if here == CAVE_AIR then
		local twin = readu16(TWIN, block * 2)
		if twin ~= 0 then
			put(o, y, twin)
		end
	elseif here == AIR then
		put(o, y, block)
	end
end

-- A decoration that hangs on a side: only its cave twin, only into cave air.
local function decorateCave(x: number, y: number, z: number, block: number)
	local o = at(x, y, z)
	if o >= 0 and readu16(wData, o) == CAVE_AIR then
		local twin = readu16(TWIN, block * 2)
		if twin ~= 0 then
			put(o, y, twin)
		end
	end
end

-- An opaque block (planks) into a cell that is not sturdy (bridges, floors): never over fluids,
-- bedrock or woodwork.
local function floorAt(x: number, y: number, z: number, block: number)
	local o = at(x, y, z)
	if o < 0 then
		return
	end
	local here = readu16(wData, o)
	local k = readu8(KIND, here)
	if readu8(STURDY, here) == 0 and k ~= K_FLUID and k ~= K_WOOD and k ~= K_HARD then
		put(o, y, block)
	end
end

-- An opaque block over anything but fluids and bedrock.
local function solid(x: number, y: number, z: number, block: number)
	local o = at(x, y, z)
	if o < 0 then
		return
	end
	local k = readu8(KIND, readu16(wData, o))
	if k ~= K_FLUID and k ~= K_HARD then
		put(o, y, block)
	end
end

-- Fills the mask with the piece's open cells over its box grown by one, clipped to the padded
-- box grown by one (so the padded cells' neighbours are known). false: nothing there.
local function fillMask(piece: Piece): boolean
	local b = piece.outer
	local x0, x1 = max(b[1], wX0 - 1), min(b[4], wX1 + 1)
	local z0, z1 = max(b[3], wZ0 - 1), min(b[6], wZ1 + 1)
	local y0, y1 = max(b[2], 0), min(b[5], wCells - 1)
	if x0 > x1 or z0 > z1 or y0 > y1 then
		return false
	end
	mX0, mY0, mZ0 = x0, y0, z0
	mNX, mNY, mNZ = x1 - x0 + 1, y1 - y0 + 1, z1 - z0 + 1
	local n = mNX * mNY * mNZ
	if buffer.len(mask) < n then
		mask = buffer.create(n)
	end
	local i = 0
	for y = y0, y1 do
		for z = z0, z1 do
			for x = x0, x1 do
				writeu8(mask, i, if opens(piece, x, y, z) then 1 else 0)
				i += 1
			end
		end
	end
	return true
end

-- Is cell (x, y, z) open in the mask (0 outside it)?
local function masked(x: number, y: number, z: number): boolean
	local lx, ly, lz = x - mX0, y - mY0, z - mZ0
	if lx < 0 or lx >= mNX or ly < 0 or ly >= mNY or lz < 0 or lz >= mNZ then
		return false
	end
	return readu8(mask, (ly * mNZ + lz) * mNX + lx) == 1
end

-- Carves the piece's open cells (the mask) inside the padded box.
local function carveMask(piece: Piece)
	local b = piece.outer
	for y = max(b[2], 1), min(b[5], wCells - 1) do
		for z = max(b[3], wZ0), min(b[6], wZ1) do
			for x = max(b[1], wX0), min(b[4], wX1) do
				if masked(x, y, z) then
					carve(x, y, z)
				end
			end
		end
	end
end

-- A log pillar from the first sturdy block within PILLAR blocks under a bridge's plank up to it.
local function pillar(x: number, y: number, z: number)
	if read(x, y, z) ~= PLANKS then
		return
	end
	for j = 1, PILLAR + 1 do
		local below = read(x, y - j, z)
		local k = kindOf(below)
		if y - j < 1 or (k ~= K_AIR and k ~= K_CAVE) then
			if y - j >= 1 and isSturdy(below) and k ~= K_FLUID then
				for yy = y - j + 1, y - 1 do
					solid(x, yy, z, LOG)
				end
				table.insert(wPillars, x)
				table.insert(wPillars, y - j + 1)
				table.insert(wPillars, z)
				table.insert(wPillars, y - 1)
			end
			return
		end
	end
end

-- A corridor's supports, floors, pillars, chests, cobwebs and rails (MineShaftCorridor).
local function decorateCorridor(piece: Piece, plan: Plan)
	local b = piece.box
	local y0 = b[2]
	local last = piece.sections * SECTION - 1
	local webSalt = bxor(piece.salt, S_WEB)
	local function web(lx: number, lz: number, chance: number)
		local x, z = toWorld(piece, lx, lz)
		local y = y0 + 2
		local here = read(x, y, z)
		if (here == CAVE_AIR or here == AIR) and roll(webSalt, x, y, z) < chance * plan.webs then
			local above = read(x, y + 1, z)
			if above >= 0 and readu8(OPAQUE, above) == 1 then
				decorate(x, y, z, COBWEB)
			end
		end
	end
	for i = 0, piece.sections - 1 do
		local lz = 2 + i * SECTION
		local whole = piece.beams[i + 1] == 1
		-- The beam, plank by plank where the cell above holds it, posts under its end planks.
		for lx = 0, 2 do
			if lx == 1 and not whole then
				continue
			end
			local x, z = toWorld(piece, lx, lz)
			if at(x, y0 + 2, z) < 0 or isOpen(read(x, y0 + 3, z)) then
				continue
			end
			solid(x, y0 + 2, z, PLANKS)
			if lx ~= 1 and read(x, y0 + 2, z) == PLANKS then
				decorate(x, y0, z, FENCE)
				decorate(x, y0 + 1, z, FENCE)
			end
		end
		-- Wall torches on the beam's middle plank, facing away from it.
		local torches = piece.torches[i + 1]
		if whole and torches > 0 then
			local bx, bz = toWorld(piece, 1, lz)
			if read(bx, y0 + 2, bz) == PLANKS then
				for side = 1, 2 do
					if bit32.btest(torches, side) then
						local tx, tz = toWorld(piece, 1, if side == 1 then lz - 1 else lz + 1)
						local support = Blocks.direction(bx - tx, 0, bz - tz)
						if support then
							decorateCave(tx, y0 + 2, tz, TORCH_ON[support])
						end
					end
				end
			end
		end
		for _, lx in { 0, 2 } do
			web(lx, lz - 1, WEB_NEAR)
			web(lx, lz + 1, WEB_NEAR)
			web(lx, lz - 2, WEB_FAR)
			web(lx, lz + 2, WEB_FAR)
		end
	end
	-- Planks over floor cells that aren't sturdy, and log pillars under a bridge's ends.
	for lz = 0, last do
		for lx = 0, 2 do
			local x, z = toWorld(piece, lx, lz)
			floorAt(x, y0 - 1, z, PLANKS)
		end
	end
	for _, lz in (if piece.sections > 1 then { 2, last - 2 } else { 2 }) :: { number } do
		for _, lx in { 0, 2 } do
			local x, z = toWorld(piece, lx, lz)
			if at(x, y0 - 1, z) >= 0 then
				pillar(x, y0 - 1, z)
			end
		end
	end
	-- Chests on a sturdy floor.
	local chests = piece.chests
	for k = 1, #chests, 3 do
		local x, y, z = chests[k], chests[k + 1], chests[k + 2]
		local o = at(x, y, z)
		if o >= 0 and isOpen(readu16(wData, o)) and isSturdy(read(x, y - 1, z)) then
			put(o, y, CHEST_BLOCK)
		end
	end
	-- A spider corridor's cobwebs in its lower two layers.
	if piece.spider then
		for lz = 0, last do
			for lx = 0, 2 do
				local x, z = toWorld(piece, lx, lz)
				for y = y0, y0 + 1 do
					if roll(webSalt, x, y, z) < SPIDER_WEBS then
						decorate(x, y, z, COBWEB)
					end
				end
			end
		end
	end
	-- Rails along the middle, on a sturdy opaque floor.
	if piece.rails then
		local rail = if piece.dir == "West" or piece.dir == "East" then RAIL_X else RAIL_Z
		local railSalt = bxor(piece.salt, S_RAIL)
		for lz = 0, last do
			local x, z = toWorld(piece, 1, lz)
			local below = read(x, y0 - 1, z)
			if isSturdy(below) and readu8(OPAQUE, below) == 1 and roll(railSalt, x, y0, z) < RAIL then
				decorate(x, y0, z, rail)
			end
		end
	end
end

-- A crossing's plank pillars at its inner corners (under a ceiling) and plank floor.
local function decorateCrossing(piece: Piece)
	local b = piece.box
	for _, corner in { { b[1] + 1, b[3] + 1 }, { b[1] + 1, b[6] - 1 }, { b[4] - 1, b[3] + 1 }, { b[4] - 1, b[6] - 1 } } do
		local x, z = corner[1], corner[2]
		if at(x, b[2], z) >= 0 and not isOpen(read(x, b[5] + 1, z)) then
			for y = b[2], b[5] do
				solid(x, y, z, PLANKS)
			end
		end
	end
	for z = b[3], b[6] do
		for x = b[1], b[4] do
			floorAt(x, b[2] - 1, z, PLANKS)
		end
	end
end

-- Overgrowth around a piece (its mask filled): moss on the rock around the open space, then
-- carpets, hanging roots, vines and glow lichen in it.
local function overgrow(piece: Piece)
	local b = piece.outer
	local mossSalt = bxor(piece.salt, S_MOSS)
	local decorSalt = bxor(piece.salt, S_DECOR)
	local ya, yb = max(b[2], 1), min(b[5], wCells - 1)
	local za, zb = max(b[3], wZ0), min(b[6], wZ1)
	local xa, xb = max(b[1], wX0), min(b[4], wX1)
	for y = ya, yb do
		for z = za, zb do
			for x = xa, xb do
				if masked(x, y, z) then
					continue
				end
				local o = at(x, y, z)
				if o < 0 or readu8(MOSSABLE, readu16(wData, o)) == 0 then
					continue
				end
				local chance = 0
				if masked(x, y + 1, z) then
					chance = MOSS_FLOOR
				elseif masked(x, y - 1, z) then
					chance = MOSS_CEILING
				elseif masked(x - 1, y, z) or masked(x + 1, y, z) or masked(x, y, z - 1) or masked(x, y, z + 1) then
					chance = MOSS_WALL
				end
				if chance > 0 and roll(mossSalt, x, y, z) < chance then
					put(o, y, MOSS)
				end
			end
		end
	end
	for y = yb, ya, -1 do
		for z = za, zb do
			for x = xa, xb do
				if not masked(x, y, z) then
					continue
				end
				local here = read(x, y, z)
				if here ~= CAVE_AIR and here ~= AIR then
					continue
				end
				local h = cellHash(decorSalt, x, y, z)
				local r1 = (h % 1024) / 1024
				local below, above = read(x, y - 1, z), read(x, y + 1, z)
				if below == MOSS or below == PLANKS then
					if r1 < CARPET then
						decorate(x, y, z, CARPET_BLOCK)
					end
					continue
				end
				if isSturdy(above) then
					if r1 < ROOTS then
						decorate(x, y, z, ROOTS_BLOCK)
						continue
					end
				end
				if here ~= CAVE_AIR then
					continue
				end
				-- A wall to hang on: the first sturdy side from a hashed one.
				local first = (h // 1073741824) % 4
				for k = 0, 3 do
					local s = (first + k) % 4 + 1
					if isSturdy(read(x + SIDE_DX[s], y, z + SIDE_DZ[s])) then
						local side = SIDES[s]
						local r2 = ((h // 1024) % 1024) / 1024
						local r3 = ((h // 1048576) % 1024) / 1024
						if not isOpen(above) and r2 < VINES then
							-- A vine down from under the ceiling, 1..VINE_RUN cells.
							local vine = VINE_ON[side]
							for d = 0, h % VINE_RUN do
								if read(x, y - d, z) ~= CAVE_AIR then
									break
								end
								decorateCave(x, y - d, z, vine)
							end
						elseif r3 < LICHEN then
							local o = at(x, y, z)
							if o >= 0 then
								put(o, y, LICHEN_ON[side])
							end
						end
						break
					end
				end
			end
		end
	end
end

-- The entrance shaft (in core columns of one chunk only: see the header).
local function writeEntrance(plan: Plan, e: Entrance)
	local cx, cz, h0, bottom = e.x, e.z, e.top, e.bottom
	local shaftSalt = bxor(plan.salt, S_SHAFT)
	-- The opening: Air from the piece up through the ground.
	for dz = -1, 1 do
		for dx = -1, 1 do
			local x, z = cx + dx, cz + dz
			for y = bottom, columnHeight(x, z) - 1 do
				local o = at(x, y, z)
				if o >= 0 then
					local here = readu16(wData, o)
					local k = readu8(KIND, here)
					if here ~= AIR and k ~= K_FLUID and k ~= K_HARD then
						put(o, y, AIR)
					end
				end
			end
		end
	end
	-- The collar: mossy cobblestone two deep, the ground above it cut level.
	for dz = -2, 2 do
		for dx = -2, 2 do
			if max(abs(dx), abs(dz)) == 2 then
				local x, z = cx + dx, cz + dz
				solid(x, h0 - 2, z, MOSSY)
				solid(x, h0 - 1, z, MOSSY)
				for y = h0, columnHeight(x, z) - 1 do
					local o = at(x, y, z)
					if o >= 0 and readu16(wData, o) ~= AIR then
						put(o, y, AIR)
					end
				end
			end
		end
	end
	-- The headframe: two fence posts and an oak log beam across the opening, FRAME over the collar.
	local ax, az = if e.axis == "X" then 1 else 0, if e.axis == "X" then 0 else 1
	for _, d in { -2, 2 } do
		local x, z = cx + d * ax, cz + d * az
		for y = h0, h0 + FRAME - 1 do
			local o = at(x, y, z)
			if o >= 0 then
				put(o, y, FENCE)
			end
		end
	end
	for d = -2, 2 do
		solid(cx + d * ax, h0 + FRAME, cz + d * az, LOG)
	end
	-- The rope, from under the beam to the floor.
	for y = bottom, h0 + FRAME - 1 do
		local o = at(cx, y, cz)
		if o >= 0 then
			put(o, y, ROPE)
		end
	end
	-- Vines down the opening's walls (from the collar's top layer, so a climber on one reaches the
	-- ground: Shared/Movement/PlayerPhysics) and on the beam's sides.
	for s = 1, 4 do
		local dx, dz = SIDE_DX[s], SIDE_DZ[s]
		local vine = VINE_ON[SIDES[s]]
		for along = -1, 1 do
			local x, z = cx + dx + along * dz, cz + dz + along * dx
			local h = cellHash(shaftSalt, x, s, z)
			if (h % 1024) / 1024 >= SHAFT_VINES then
				continue
			end
			for y = h0 - 1, h0 - 2 - (h // 1024) % 5, -1 do
				local o = at(x, y, z)
				if o < 0 or readu16(wData, o) ~= AIR then
					break
				end
				if not isSturdy(read(x + dx, y, z + dz)) and read(x, y + 1, z) ~= vine then
					break
				end
				put(o, y, vine)
			end
		end
	end
	for _, side in { -1, 1 } do
		-- The cells beside the beam over the opening hang on it.
		local support = Blocks.direction(-side * az, 0, -side * ax)
		if support == nil then
			continue
		end
		local vine = VINE_ON[support]
		for along = -1, 1 do
			local x, z = cx + along * ax + side * az, cz + along * az + side * ax
			local h = cellHash(shaftSalt, x, h0 + FRAME, z)
			if (h % 1024) / 1024 < BEAM_VINES then
				for y = h0 + FRAME, h0 + FRAME - 1 - (h // 1024) % 2, -1 do
					local o = at(x, y, z)
					if o >= 0 and readu16(wData, o) == AIR then
						put(o, y, vine)
					end
				end
			end
		end
	end
end

-- Takes away every attached block written whose support went (a later piece carved it):
-- top down, so a vine hanging from one taken away goes too. Supports past the padded box are
-- unknown: kept.
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
		if support < 0 or isSturdy(support) then
			continue
		end
		local def = Blocks.get(block)
		if def.chain then
			local above = read(x, y + 1, z)
			local family = Blocks.caveTwinOf(block) or block
			if above >= 0 and (Blocks.caveTwinOf(above) or above) == family then
				continue
			end
		end
		writeu16(wData, o, if Blocks.isCaveTwin(block) then CAVE_AIR else AIR)
	end
end

--[[
	Writes `plans` into a padded full detail chunk (see Mineshafts.write in the type);
	`outside(x, z)` gives the height of a column past the padded box.
]]
function Mineshafts.write(
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
	table.clear(wPillars)
	local map = carved
	for _, plan in plans do
		local touched: { Piece } = {}
		for _, piece in plan.pieces do
			local b = piece.outer
			if b[1] > wX1 or b[4] < wX0 or b[3] > wZ1 or b[6] < wZ0 then
				continue
			end
			table.insert(touched, piece)
			if not fillMask(piece) then
				continue
			end
			carveMask(piece)
			if piece.kind == "corridor" then
				decorateCorridor(piece, plan)
			elseif piece.kind == "crossing" then
				decorateCrossing(piece)
			end
		end
		if plan.overgrown then
			for _, piece in touched do
				if fillMask(piece) then
					overgrow(piece)
				end
			end
		end
		for _, piece in touched do
			local b = piece.outer
			map = Caves.markRead(map, originX, originZ, b[1], b[2], b[3], b[4], b[5], b[6])
		end
	end
	for _, plan in plans do
		local e = plan.entrance
		if e and e.x >= originX and e.x < originX + SIZE and e.z >= originZ and e.z < originZ + SIZE then
			writeEntrance(plan, e)
			local s = e.shaft
			map = Caves.markRead(map, originX, originZ, s[1], s[2], s[3], s[4], s[5], s[6])
		end
	end
	for i = 1, #wPillars, 4 do
		local x, y0, z, y1 = wPillars[i], wPillars[i + 1], wPillars[i + 2], wPillars[i + 3]
		map = Caves.markRead(map, originX, originZ, x, y0, z, x, y1, z)
	end
	settle()
	local lowest, top = wLowest, wTop
	wData, wHeights = NOTHING, {}
	return lowest, top, map
end

--[[ Samples (the debug structures world) ]]

--[[
	A fixed mineshaft for the debug structures world, its room's corner at (x, y, z) (the floor
	at y): the room, a rail corridor east with whole beams, torches and a chest, a crossing, a
	spider corridor north and stairs down; overgrown, with its entrance at the room's centre from
	a surface at `ground` (the centre must lie in a chunk's core columns 3..12). Its bounds reach
	1 block west of x, 18 north of z, 30 east and 10 south.
]]
function Mineshafts.sample(x: number, y: number, z: number, overgrown: boolean, ground: number): Plan
	local salt = Hash.hash3(0x5A3B1E, x, y, z)
	local pieces: { Piece } = {}
	local function add(kind: string, box: { number }, dir: string?): Piece
		local piece = newPiece(kind, box, dir, #pieces, Hash.hash3(salt, #pieces + 1, 0x9E, 0))
		table.insert(pieces, piece)
		return piece
	end
	local room = add("room", { x, y, z, x + 9, y + 6, z + 9 }, nil)
	local east = add("corridor", { x + 10, y + 1, z + 3, x + 24, y + 3, z + 5 }, "East")
	east.sections, east.rails = 3, true
	east.beams, east.torches = { 1, 1, 1 }, { 3, 0, 0 }
	local cx, cz = toWorld(east, 2, 2 + SECTION - 1)
	east.chests = { cx, y + 1, cz }
	table.move({ x + 8, y + 1, z + 3, x + 9, y + 3, z + 5 }, 1, 6, 1, room.exits)
	finishRoom(room)
	add("crossing", { x + 25, y + 1, z + 2, x + 29, y + 3, z + 6 }, "East")
	local north = add("corridor", { x + 26, y + 1, z - 8, x + 28, y + 3, z + 1 }, "North")
	north.sections, north.spider = 2, true
	north.beams, north.torches = { 1, 2 }, { 0, 0 }
	add("stairs", { x + 26, y - 4, z - 17, x + 28, y + 3, z - 9 }, "North")
	local entrance: Entrance? = nil
	if overgrown then
		local ex, ez = x + 5, z + 5
		entrance = {
			x = ex,
			z = ez,
			top = ground,
			bottom = y + 1,
			axis = "X",
			box = { ex - KEEP_OUT, ez - KEEP_OUT, ex + KEEP_OUT, ez + KEEP_OUT },
			shaft = { ex - 2, y, ez - 2, ex + 2, ground + FRAME + 1, ez + 2 },
		}
	end
	return {
		cellX = 0,
		cellZ = 0,
		x = x,
		y = y,
		z = z,
		overgrown = overgrown,
		webs = if overgrown then OVERGROWN_WEBS else 1,
		salt = salt,
		pieces = pieces,
		bounds = boundsOf(pieces, entrance),
		entrance = entrance,
	}
end

return Mineshafts
