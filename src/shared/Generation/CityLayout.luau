--!strict
--!native
--[[
	The zombie apocalypse's cities, parcel by parcel (Generation/Cities decides where they stand;
	this module is what stands there). Pure: a site's plan, its parcels, their buildings and every
	block of them follow from the site's numbers (the existence test's cell, centre, size and salt,
	its plateau height H and its overgrowth o) and position hashes alone, never from a chunk's
	blocks, so a chunk's padding gets exactly its neighbour's core and every machine agrees.

	The footprint is a square 2R + 1 blocks wide, R = 32 half + 3 (half 1..7), local u = x - (cx -
	R) and v = z - (cz - R) in 0..2R, so it starts and ends on a street.
	  Streets   every Block (32) blocks, Street (7) wide: u % 32 < 7 or v % 32 < 7. Across a
	            street running along z: a Concrete sidewalk at 0 and 6, Asphalt 1..5, the dashed
	            Yellow Road Line at 3 (v % 8 < 4) outside the crossings; crossings are plain
	            asphalt, and the street's rows either side of one (v % 32 = 7 and 31) are a
	            crosswalk, the white Road Line on lanes 1, 3 and 5 (the only place it lies). Decay
	            (`surface`): Gravel potholes (Roads.Potholes per block), Grass and Moss Block
	            patches where a 4 block value noise falls in the lowest Roads.Overgrown x o of its
	            range (`share`: the noise's quantiles), Cracked Asphalt (Cracked Concrete on
	            sidewalks) in CRACK_PATCH (4) square patches (Roads.Cracks): a crosswalk fades the
	            same way. Asphalt, lines and sidewalks lie on Gravel, the grass on Dirt (the
	            override's filler).
	  Parcels   the 25 x 25 blocks between streets (pu = u // 32, pv = v // 32), each from its own
	            hash. d: the parcel's ring around the centre ((ring + 0.5) / half), pulled outwards
	            in small towns (d = 1 - (1 - d) x (0.5 + 0.5 (half - 1) / 6): only a city of half 4
	            or more, R >= 131, has a downtown). Downtown (d <= 0.35): office 50, apartment 30, plaza 10,
	            rubble 10; mid (<= 0.7): apartment 30, shop 30 (grocery 40, pharmacy 15, hardware
	            20, office 25), four houses 25, park 10, parking 5; outer: houses 60, park 15,
	            parking 10, shop 10, rubble 5. Once per city, on the mid parcels with the lowest
	            hashes (any parcels in a town without a mid ring): a police station (a shop's shell,
	            police loot), a fire station (two floors, fire station loot) and, unless a pharmacy
	            stands already, a pharmacy (so every town has Medicine Cabinets). Cities.Bunkers
	            (1-2) outer house lots (else mid, else parcels turned into houses) hold a shed: 5 x 5
	            Planks, an Oak Door, its middle floor cell (x, H - 1, z) Concrete with Air above, in
	            core columns 2..13 of its chunk, where Generation/Bunkers puts a hatch (`sheds`).
	  Buildings inset one block from their lot (23 x 23, a house 10 x 10 in a 12 x 12 lot); floors
	            FloorHeight (4) apart from the ground slab at H - 1 (a slab, three of air): houses,
	            shops and police 1-2, fire stations 2, apartments 3-6, offices 6 + (1 - d) x
	            (MaxFloors - 6) +- 2 (at most MaxFloors). Walls one block thick, of Brick, Concrete,
	            Stone Bricks or Smooth Stone (houses Planks, Brick or Stone Bricks; offices Concrete);
	            slabs Concrete (houses' Planks). Windows: rows 1-2 of each floor, at every fourth
	            block along a wall (offices: bands all along; shops, police and fire stations: a
	            band on the ground floor), Glass with chance 0.7 x (1 - ruin) per window (per eight
	            blocks of a band), else open. The door: the middle of the side facing a street, an
	            Oak Door pair (60%) or a gap. Floors up to FullFloors (4) are open rooms with a
	            1 x 1 ladder shaft in a corner (the slab cell above each floor open, a Ladder against
	            the wall from the ground floor to the last full floor's slab); above them each
	            floor is its facade and a ring of rooms two blocks deep behind it (a slab every
	            floor, so the windows show depth) around a solid core of the wall material. The
	            roof: a slab.
	  Ruin      r = clamp(Ruin + (hash - 0.5) x 0.6 + 0.2 d, 0, 1) per building (downtown offices
	            0.1 less): the top is jagged, top - r x 2.5 floors x value noise(x / 4, z / 4), per
	            2 x 2 columns in steps of 2 blocks, never below the ground floor's three lower rows
	            (the door and the ground floor's containers always stand). Walls decay in panels a
	            floor tall (few big boxes for the mesher): blown out by PANEL (4 blocks along a
	            wall; rows 1-3 open, 0.15 r), else cracked (0.25 r) or mossy (0.2 o) by AGE_PANEL
	            (8), never a corner, the door's frame or the ladder's wall, and the floor line (row
	            0) stays whole. The slabs between the full floors hole in 4 x 4 patches (0.1 r), a
	            layer of rubble (Gravel or Cracked Concrete) under each on the floor below; the
	            ground slab, the roof and the ring of rooms above never do.
	  Overgrowth  vines hang from the jagged top of 0.3 o of the walls' columns down 3-12 blocks,
	            outside the wall, the first on its wall (a sturdy block), the rest on the vine above;
	            Moss Carpet on 0.15 o of the roofs and 0.04 o of the floors (patches of a value
	            noise, on a sturdy block); Grass and Moss Block in 4 x 4 patches of 0.15 o r of the
	            ground floors (Generation/Foliage plants them); Cobwebs in 0.05 r of the upper
	            corners of the full floors (ruins give String). Parks are Grass (trees grow there:
	            `treeAllowed`); nothing grows on asphalt or concrete. Rubble lots: a mound max(0, 3
	            - dist / 3 + noise) of Gravel, Cracked Concrete and Brick and one or two wall stubs;
	            plazas Concrete; parking lots Asphalt with wrecks.
	  Cars      on each street stretch between two crossings, per lane, Cars of a chance: 2 x 4,
	            Coal Block wheels at the corners and Rusty Metal between them (30%: one is a Supply
	            Crate of car loot), Rusty Metal hood and trunk over them and a Glass cabin (50% open).
	  Loot      containers against the inside walls (never the ladder's corner or the door), on
	            the full floors, where their cell stands and their slab does: houses 1-2 per floor
	            (Chest or Supply Crate, house) and 30% a Medicine Cabinet; apartments a Chest per
	            floor (house); groceries 2-4 Supply Crates; pharmacies 2 Medicine Cabinets and a
	            Supply Crate; hardware 2-3 Supply Crates; police 2 Chests; fire stations 2 Supply
	            Crates; offices a Chest per floor (office). Generation/ScavengeLoot rolls them.
	Far nodes (`writeLod`): levels 1-2 point-sample the decayed envelope filled solid with the
	wall material (and the rubble); levels 3-4 fill each building's box to its highest decayed top
	(`envelope`), so no skyline flickers between levels and streets stay ground.

	Writing (`begin`, `writeLot`, `writeStreetCars`, `finish`) is one chunk at a time per actor
	(module state, as Generation/Mineshafts' writer): cells are clipped to the padded chunk, and
	`finish` returns the lowest cell written (TerrainGenerator lowers solidBelow to it and spans
	structureSpan from it) and one above the highest cell written.
]]

local Config = require(script.Parent.Parent.Config)
local Blocks = require(script.Parent.Parent.Blocks)
local Hash = require(script.Parent.Parent.Util.Hash)
local ChunkLayout = require(script.Parent.Parent.World.ChunkLayout)

local P = ChunkLayout.PADDED

local cfg = Config.Cities
local BLOCK = cfg.Block
local STREET = cfg.Street
local FH = cfg.FloorHeight
local FULL = cfg.FullFloors
local MAX_FLOORS = cfg.MaxFloors
local MAX_HALF = cfg.MaxRadius // BLOCK
local LOT = BLOCK - STREET -- 25: a parcel's side

-- Tuning --------------------------------------------------------------------------------------------
local COLLAPSE_FLOORS = 2.5 -- the jagged top loses up to r x this many floors
local WALL_HOLES, SLAB_HOLES = 0.15, 0.1 -- holes in walls and slabs, times r
local CRACKS, MOSS = 0.25, 0.2 -- aged walls: cracked (times r), mossy (times o)
local VINES = 0.3 -- wall columns with a vine, times o
local VINE_MIN, VINE_MAX = 3, 12 -- a vine's length
local ROOF_CARPET, FLOOR_CARPET = 0.15, 0.04 -- moss carpet on roofs and floors, times o
local PANEL = 4 -- walls blow out in panels this many blocks along a wall, one floor tall
local AGE_PANEL = 8 -- and crack or grow moss in panels this wide (few big boxes for the mesher)
local CRACK_PATCH = 4 -- streets and sidewalks crack in patches this wide
local BAND_SEGMENT = 8 -- a window band's glass is whole or broken this many blocks at a time
local SLAB_PATCH = 4 -- slab holes, ground floor greens: patches this wide
local GROUND_GREEN = 0.15 -- grass and moss in the ground floors, times o x r
local COBWEBS = 0.05 -- the full floors' upper corners, times r
local GLASS_CHANCE = 0.7 -- a window's glass, times 1 - r
local DOOR_CHANCE = 0.6 -- an Oak Door (else a gap)
local CAR_CRATE, CAR_GLASS = 0.3, 0.5
local HOUSE_CABINET = 0.3
local SHED = 5

local floor = math.floor
local min, max = math.min, math.max
local abs = math.abs
local readu8 = buffer.readu8
local writeu16 = buffer.writeu16
local bxor = bit32.bxor
local rshift = bit32.rshift

local id = Blocks.id
local AIR = Blocks.AIR
local ASPHALT, CRACKED_ASPHALT, LINE_YELLOW, LINE_WHITE = id.Asphalt, id.CrackedAsphalt, id.RoadLineYellow, id.RoadLine
local CONCRETE, CRACKED_CONCRETE, MOSSY_CONCRETE = id.Concrete, id.CrackedConcrete, id.MossyConcrete
local BRICK, CRACKED_BRICKS, MOSSY_BRICKS = id.Brick, id.CrackedBricks, id.MossyBricks
local STONE_BRICKS, CRACKED_STONE_BRICKS = id.StoneBricks, id.CrackedStoneBricks
local SMOOTH_STONE, COBBLESTONE, MOSSY_COBBLESTONE = id.SmoothStone, id.Cobblestone, id.MossyCobblestone
local PLANKS, GLASS = id.Planks, id.Glass
local GRAVEL, DIRT, GRASS, MOSS_BLOCK, CARPET = id.Gravel, id.Dirt, id.Grass, id.MossBlock, id.MossCarpet
local COBWEB, RUSTY, CRATE, CABINET, CHEST = id.Cobweb, id.RustyMetal, id.SupplyCrate, id.MedicineCabinet, id.Chest
local COAL_BLOCK = id.CoalBlock

local STURDY = Blocks.sturdyLut

-- The four sides: 1 north (-Z), 2 east (+X), 3 south (+Z), 4 west (-X).
local SIDE_DX = { 0, 1, 0, -1 }
local SIDE_DZ = { -1, 0, 1, 0 }
local SIDE_NAME = { "North", "East", "South", "West" }
local OPPOSITE = { 3, 4, 1, 2 }

-- A ladder against the wall on side s of its cell, a vine outside the wall on side s (its wall on
-- the opposite side), the door in a wall on side s (facing in: the way a player walks through it).
local LADDER_ON: { number } = {}
local VINE_OUTSIDE: { number } = {}
local DOOR_LOWER: { number } = {}
local DOOR_UPPER: { number } = {}
do
	local ladders: { [string]: number } = {}
	for _, name in { "Ladder", "LadderSouth", "LadderWest", "LadderEast" } do
		ladders[Blocks.get(id[name]).support :: string] = id[name]
	end
	local vines: { [string]: number } = {}
	for _, name in { "Vine", "VineNorth", "VineWest", "VineEast" } do
		vines[Blocks.get(id[name]).support :: string] = id[name]
	end
	for s = 1, 4 do
		LADDER_ON[s] = ladders[SIDE_NAME[s]]
		VINE_OUTSIDE[s] = vines[SIDE_NAME[OPPOSITE[s]]]
		local facing = SIDE_NAME[OPPOSITE[s]]
		DOOR_LOWER[s] = Blocks.doorVariant(id.OakDoor, facing, "Left", false, false) :: number
		DOOR_UPPER[s] = Blocks.doorVariant(id.OakDoor, facing, "Left", false, true) :: number
		assert(LADDER_ON[s] and VINE_OUTSIDE[s] and DOOR_LOWER[s] and DOOR_UPPER[s], "CityLayout: blocks")
	end
end

-- Aged kinds of each wall material: cracked, mossy (0: none).
local CRACKED: { [number]: number } = {
	[BRICK] = CRACKED_BRICKS,
	[CONCRETE] = CRACKED_CONCRETE,
	[STONE_BRICKS] = CRACKED_STONE_BRICKS,
	[SMOOTH_STONE] = COBBLESTONE,
}
local MOSSY: { [number]: number } = {
	[BRICK] = MOSSY_BRICKS,
	[CONCRETE] = MOSSY_CONCRETE,
	[STONE_BRICKS] = MOSSY_COBBLESTONE,
	[SMOOTH_STONE] = MOSSY_COBBLESTONE,
}
local MATERIALS = { BRICK, CONCRETE, STONE_BRICKS, SMOOTH_STONE }
local HOUSE_MATERIALS = { PLANKS, BRICK, STONE_BRICKS }

--[[ Hashes and noise ]]

-- A cell's u32 hash (exact for |x|, |z| < 2^26), salted (Generation/Mineshafts' and CaveDecor's).
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
-- 2D value noise in [0, 1]: smoothstep-blended hashes of a lattice `scale` blocks apart.
local function vnoise(salt: number, x: number, z: number, scale: number): number
	local fx, fz = x / scale, z / scale
	local ix, iz = floor(fx), floor(fz)
	local tx, tz = fx - ix, fz - iz
	tx = tx * tx * (3 - 2 * tx)
	tz = tz * tz * (3 - 2 * tz)
	local a, b = roll(salt, ix, 0, iz), roll(salt, ix + 1, 0, iz)
	local c, d = roll(salt, ix, 0, iz + 1), roll(salt, ix + 1, 0, iz + 1)
	local top = a + (b - a) * tx
	local bottom = c + (d - c) * tx
	return top + (bottom - top) * tz
end

-- The value noise's quantiles at p = 0, 0.025 .. 1 (measured over 2 million samples), so a patch
-- rule "noise < share(p)" covers a share p of the ground.
local QUANTILES = {
	0,
	0.0971,
	0.1428,
	0.1776,
	0.2022,
	0.2257,
	0.2460,
	0.2683,
	0.2883,
	0.3089,
	0.3256,
	0.3442,
	0.3617,
	0.3787,
	0.3939,
	0.4131,
	0.4279,
	0.4445,
	0.4630,
	0.4800,
	0.4958,
	0.5097,
	0.5260,
	0.5410,
	0.5572,
	0.5740,
	0.5889,
	0.6038,
	0.6211,
	0.6385,
	0.6557,
	0.6753,
	0.6956,
	0.7161,
	0.7391,
	0.7620,
	0.7884,
	0.8145,
	0.8537,
	0.8957,
	1,
}
local function share(p: number): number
	if p <= 0 then
		return -1
	elseif p >= 1 then
		return 2
	end
	local f = p * 40
	local i = floor(f)
	return QUANTILES[i + 1] + (QUANTILES[i + 2] - QUANTILES[i + 1]) * (f - i)
end

-- Salts of the per cell decisions (xored into a building's or a city's salt).
local S_COLLAPSE, S_HOLE, S_SLAB, S_CRACK, S_MOSS = 0x0C01, 0x0E1E, 0x51AB, 0xC4AC, 0x3055
local S_GLASS, S_VINE, S_WEB, S_CARPET, S_GROUND = 0x6A55, 0x7111, 0x3EB, 0xCA9E, 0x6200
local S_POT, S_GREEN, S_STREET_CRACK, S_CAR, S_MOUND, S_RUBBLE = 0x9077, 0x64EE, 0x5C4A, 0xCA4, 0x3D, 0x4B
local S_WALK = 0xA1C

--[[ Types ]]

--[[
	A building (Lot `buildings`): its box (walls inclusive), floors and how many are full rooms,
	the ground slab's y (H - 1) and `top` (one above the roof), materials (`wall`, its aged kinds,
	`slab` for floors and the roof, `ground` for the ground slab), ruin `r` and how many blocks its
	top may lose (`collapse`), its windows (`bands`: all along every floor; `front`: the ground
	floor's), the door (side, the position along that wall, an Oak Door or a gap), the ladder
	(`ladderX`, `ladderZ`, its wall side; 0: none) and the cell behind it, its containers (x, y, z,
	block per container, `tables` their loot) and, for a shed, the hatch's column.
]]
export type Building = {
	kind: string,
	x0: number,
	z0: number,
	x1: number,
	z1: number,
	floors: number,
	full: number,
	y0: number,
	top: number,
	wall: number,
	cracked: number,
	mossy: number,
	slab: number,
	ground: number,
	r: number,
	o: number,
	collapse: number,
	glass: number,
	bands: boolean,
	front: boolean,
	doorSide: number,
	doorAlong: number,
	door: boolean,
	ladderSide: number,
	ladderX: number,
	ladderZ: number,
	salt: number,
	containers: { number },
	tables: { string },
	special: { [number]: number },
	hatchX: number?,
	hatchZ: number?,
	envelope: number?,
}

--[[
	A parcel: its kind, its 25 x 25 blocks (x0..x1, z0..z1), its buildings, a rubble lot's mound
	and wall stubs (x0, z0, x1, z1, top, block each), and one above the highest block anything in
	it may reach (`top`).
]]
export type Lot = {
	kind: string,
	x0: number,
	z0: number,
	x1: number,
	z1: number,
	buildings: { Building },
	mound: boolean,
	stubs: { number },
	cars: { number },
	salt: number,
	top: number,
}

--[[
	A city's plan: its existence numbers (cell, centre x / z, half, radius R, salt), its plateau y
	(H, first air), its overgrowth o, the footprint's corner (x0, z0 = centre - R), parcels per side
	(n = 2 half), each parcel's kind, its shop's loot table and d, the shed lots (parcel index ->
	lot 1..4), the lots planned so far (filled lazily, each complete before it is kept) and the
	tops worked out without planning their lot (`lotTop`).
]]
export type Plan = {
	gx: number,
	gz: number,
	x: number,
	z: number,
	half: number,
	radius: number,
	y: number,
	salt: number,
	o: number,
	x0: number,
	z0: number,
	n: number,
	kinds: { string },
	loots: { string },
	dists: { number },
	hashes: { number },
	sheds: { [number]: number },
	lots: { [number]: Lot },
	tops: { [number]: number },
}

-- What a plan is made from: the existence test's numbers.
export type Site = { gx: number, gz: number, x: number, z: number, half: number, radius: number, salt: number }

local CityLayout = {}

CityLayout.share = share
CityLayout.vnoise = vnoise
CityLayout.roll = roll
CityLayout.SHED = SHED

local function sub(h: number, k: number): number
	return Hash.hash3(h, k, 0x51, 0)
end
local function subf(h: number, k: number): number
	return sub(h, k) / 4294967296
end

-- The pick of a weighted list { name, weight, ... } by u in [0, 1).
local function pick(list: { any }, u: number): string
	local total = 0
	for i = 2, #list, 2 do
		total += list[i]
	end
	local at = u * total
	for i = 1, #list, 2 do
		at -= list[i + 1]
		if at < 0 then
			return list[i]
		end
	end
	return list[#list - 1]
end

local DOWNTOWN: { any } = { "office", 50, "apartment", 30, "plaza", 10, "rubble", 10 }
local MID: { any } = { "apartment", 30, "shop", 30, "houses", 25, "park", 10, "parking", 5 }
local OUTER: { any } = { "houses", 60, "park", 15, "parking", 10, "shop", 10, "rubble", 5 }
local SHOPS: { any } = { "grocery", 40, "pharmacy", 15, "hardware", 20, "office", 25 }

-- Where d puts a parcel: 1 downtown, 2 mid, 3 outer.
local function zoneOf(d: number): number
	return if d <= 0.35 then 1 elseif d <= 0.7 then 2 else 3
end
CityLayout.zoneOf = zoneOf

--[[ Plans ]]

-- The plan of site `s` with plateau y `H` and overgrowth `o` (see the header).
function CityLayout.plan(s: Site, H: number, o: number): Plan
	local half = s.half
	local n = 2 * half
	local parcelSalt = Hash.hash3(s.salt, 0x9A, 0, 0x7C)
	local kinds, loots, dists, hashes =
		table.create(n * n), table.create(n * n), table.create(n * n), table.create(n * n)
	local size = 0.5 + 0.5 * (half - 1) / math.max(MAX_HALF - 1, 1)
	for pv = 0, n - 1 do
		for pu = 0, n - 1 do
			local i = pv * n + pu + 1
			local h = Hash.hash3(parcelSalt, pu, 0, pv)
			local ring = max(abs(2 * pu - (n - 1)), abs(2 * pv - (n - 1))) // 2
			local d = 1 - (1 - (ring + 0.5) / half) * size
			local zone = zoneOf(d)
			local kind = pick(if zone == 1 then DOWNTOWN elseif zone == 2 then MID else OUTER, subf(h, 1))
			hashes[i], dists[i], kinds[i] = h, d, kind
			loots[i] = if kind == "shop" then pick(SHOPS, subf(h, 2)) else ""
		end
	end
	-- Once per city: police, fire station, a pharmacy (see the header).
	local candidates: { number } = {}
	for i = 1, n * n do
		if zoneOf(dists[i]) == 2 then
			table.insert(candidates, i)
		end
	end
	if #candidates < 3 then
		candidates = {}
		for i = 1, n * n do
			table.insert(candidates, i)
		end
	end
	table.sort(candidates, function(a: number, b: number): boolean
		return hashes[a] < hashes[b]
	end)
	kinds[candidates[1]], loots[candidates[1]] = "police", "police"
	kinds[candidates[2]], loots[candidates[2]] = "fire", "fire_station"
	local pharmacy = false
	for i = 1, n * n do
		if kinds[i] == "shop" and loots[i] == "pharmacy" then
			pharmacy = true
		end
	end
	if not pharmacy then
		kinds[candidates[3]], loots[candidates[3]] = "shop", "pharmacy"
	end
	-- Sheds over the bunkers: outer house parcels first, then mid ones, then any other parcel
	-- turned into houses (lowest hashes first).
	local bunkers = cfg.Bunkers
	local count = bunkers[1] + sub(s.salt, 0x5ED) % (bunkers[2] - bunkers[1] + 1)
	local order: { number } = {}
	for i = 1, n * n do
		table.insert(order, i)
	end
	local function rank(i: number): number
		if kinds[i] == "houses" then
			return if zoneOf(dists[i]) == 3 then 0 else 1
		elseif kinds[i] == "police" or kinds[i] == "fire" or (kinds[i] == "shop" and loots[i] == "pharmacy") then
			return 3
		end
		return 2
	end
	table.sort(order, function(a: number, b: number): boolean
		local ra, rb = rank(a), rank(b)
		if ra ~= rb then
			return ra < rb
		end
		return hashes[a] < hashes[b]
	end)
	local sheds: { [number]: number } = {}
	for k = 1, math.min(count, #order) do
		local i = order[k]
		if rank(i) == 3 then
			break
		end
		kinds[i], loots[i] = "houses", ""
		sheds[i] = sub(hashes[i], 7) % 4 + 1
	end
	return {
		gx = s.gx,
		gz = s.gz,
		x = s.x,
		z = s.z,
		half = half,
		radius = s.radius,
		y = H,
		salt = s.salt,
		o = o,
		x0 = s.x - s.radius,
		z0 = s.z - s.radius,
		n = n,
		kinds = kinds,
		loots = loots,
		dists = dists,
		hashes = hashes,
		sheds = sheds,
		lots = {},
		tops = {},
	}
end

--[[ Buildings ]]

-- The block of the jagged top of building b at column (x, z): its first air (see the header).
local function effTop(b: Building, x: number, z: number): number
	if b.collapse <= 0 then
		return b.top
	end
	-- (Per 2 x 2 columns and in steps of 2 blocks: a ragged top of few boxes.)
	local loss = floor(b.collapse * vnoise(bxor(b.salt, S_COLLAPSE), x // 2 * 2, z // 2 * 2, 4) / 2) * 2
	return max(b.y0 + 3, b.top - loss)
end
CityLayout.effTop = effTop

-- Is the slab of floor index k (0: the ground floor) holed at (x, z)? Only between the full
-- floors (never the ground slab, the roof or the ring of rooms above them, mostly hidden: every
-- hole costs boxes).
local function slabHole(b: Building, x: number, k: number, z: number): boolean
	if k <= 0 or k >= b.full or b.r <= 0 then
		return false
	end
	return roll(bxor(b.salt, S_SLAB), x // SLAB_PATCH, k, z // SLAB_PATCH) < SLAB_HOLES * b.r
end
CityLayout.slabHole = slabHole

-- The side and the position along it of wall column (x, z) (corners: the north or south side).
local function sideOf(b: Building, x: number, z: number): (number, number)
	if z == b.z0 then
		return 1, x - b.x0
	elseif z == b.z1 then
		return 3, x - b.x0
	elseif x == b.x1 then
		return 2, z - b.z0
	end
	return 4, z - b.z0
end

-- Is wall column (x, z) one no hole or window may touch (the door's frame, the ladder's wall)?
local function essential(b: Building, x: number, z: number): boolean
	local side, along = sideOf(b, x, z)
	if side == b.doorSide and abs(along - b.doorAlong) <= 1 then
		return true
	end
	if b.ladderSide ~= 0 then
		local wx, wz = b.ladderX + SIDE_DX[b.ladderSide], b.ladderZ + SIDE_DZ[b.ladderSide]
		if x == wx and z == wz then
			return true
		end
	end
	return false
end

-- A wall cell's block: its material, cracked or mossy by panels (side, along // AGE_PANEL, floor
-- index k: a floor tall), so the wall stays a few big boxes.
local function aged(b: Building, side: number, along: number, k: number): number
	local panel = along // AGE_PANEL
	if b.cracked ~= 0 and roll(bxor(b.salt, S_CRACK), side, panel, k) < CRACKS * b.r then
		return b.cracked
	end
	if b.mossy ~= 0 and roll(bxor(b.salt, S_MOSS), side, panel, k) < MOSS * b.o then
		return b.mossy
	end
	return b.wall
end

-- Is the wall panel at (side, along) of floor index k blown out (rows 1-3 open)?
local function holed(b: Building, side: number, along: number, k: number): boolean
	return b.r > 0 and roll(bxor(b.salt, S_HOLE), side, along // PANEL, k) < WALL_HOLES * b.r
end

-- The window at (side, along) of floor index k, row `row`: its block (Glass or Air), or nil.
local function windowAt(b: Building, side: number, along: number, k: number, row: number): number?
	if row ~= 1 and row ~= 2 then
		return nil
	end
	local width = if side == 1 or side == 3 then b.x1 - b.x0 else b.z1 - b.z0
	if along <= 0 or along >= width then
		return nil
	end
	local glass
	if b.bands or (b.front and k == 0) then
		glass = roll(bxor(b.salt, S_GLASS), side, k, along // BAND_SEGMENT) < b.glass
	else
		if along % 4 ~= 1 or along > width - 1 then
			return nil
		end
		glass = roll(bxor(b.salt, S_GLASS), side, k, along) < b.glass
	end
	return if glass then GLASS else AIR
end

-- The interior cells against the walls (depth 1, not the corners), as x, z pairs around.
local function innerRing(b: Building): { number }
	local out: { number } = {}
	for x = b.x0 + 2, b.x1 - 2 do
		table.insert(out, x)
		table.insert(out, b.z0 + 1)
	end
	for z = b.z0 + 2, b.z1 - 2 do
		table.insert(out, b.x1 - 1)
		table.insert(out, z)
	end
	for x = b.x1 - 2, b.x0 + 2, -1 do
		table.insert(out, x)
		table.insert(out, b.z1 - 1)
	end
	for z = b.z1 - 2, b.z0 + 2, -1 do
		table.insert(out, b.x0 + 1)
		table.insert(out, z)
	end
	return out
end

-- Key of a cell of building b (its `special` table).
local function cellKey(b: Building, x: number, y: number, z: number): number
	return ((y - b.y0) * 64 + (z - b.z0)) * 64 + (x - b.x0)
end

-- Adds `count` containers of `block` and loot `table` on floor index k of building b.
local function addContainers(b: Building, ring: { number }, k: number, count: number, block: number, loot: string)
	local cells = #ring // 2
	if cells == 0 then
		return
	end
	local dx, dz = SIDE_DX[b.doorSide], SIDE_DZ[b.doorSide]
	-- The door's inside cell.
	local doorX, doorZ
	if b.doorSide == 1 or b.doorSide == 3 then
		doorX, doorZ = b.x0 + b.doorAlong, (if b.doorSide == 1 then b.z0 else b.z1) - dz
	else
		doorX, doorZ = (if b.doorSide == 2 then b.x1 else b.x0) - dx, b.z0 + b.doorAlong
	end
	local y = b.y0 + k * FH + 1
	for j = 1, count do
		local start = sub(b.salt, k * 16 + j) % cells
		for step = 0, cells - 1 do
			local c = (start + step) % cells
			local x, z = ring[c * 2 + 1], ring[c * 2 + 2]
			local key = cellKey(b, x, y, z)
			local near = abs(x - doorX) + abs(z - doorZ) <= 1
			local ladder = abs(x - b.ladderX) + abs(z - b.ladderZ) <= 1
			if b.special[key] == nil and not near and not ladder then
				-- Only where it stands: under the jagged top, on a slab that is there.
				if y < effTop(b, x, z) and not slabHole(b, x, k, z) then
					b.special[key] = block
					table.insert(b.containers, x)
					table.insert(b.containers, y)
					table.insert(b.containers, z)
					table.insert(b.containers, block)
					table.insert(b.tables, loot)
				end
				break
			end
		end
	end
end

--[[
	A building of `kind` in box x0..x1, z0..z1 of plan `p`'s parcel i (d its distance), its door on
	one of `sides` (a list of sides facing a street).
]]
-- How many floors building `slot` (0: the parcel's only one, 1..4: a houses parcel's lots) of
-- `kind` on plan p's parcel i has.
local function floorsOf(p: Plan, i: number, slot: number, kind: string): number
	local h = sub(p.hashes[i], 100 + slot)
	if kind == "office" then
		local d = p.dists[i]
		return math.clamp(6 + floor((1 - d) * (MAX_FLOORS - 6)) + sub(h, 1) % 5 - 2, 3, MAX_FLOORS)
	elseif kind == "apartment" then
		return 3 + sub(h, 1) % 4
	elseif kind == "fire" then
		return 2
	elseif kind == "shed" then
		return 1
	end
	return 1 + sub(h, 1) % 2
end

local function newBuilding(
	p: Plan,
	i: number,
	slot: number,
	kind: string,
	loot: string,
	x0: number,
	z0: number,
	x1: number,
	z1: number,
	sides: { number }
): Building
	local h = sub(p.hashes[i], 100 + slot)
	local d = p.dists[i]
	local floors = floorsOf(p, i, slot, kind)
	local house = kind == "house" or kind == "shed"
	local wall
	if kind == "office" then
		wall = CONCRETE
	elseif kind == "fire" then
		wall = BRICK
	elseif kind == "shed" then
		wall = PLANKS
	elseif house then
		wall = HOUSE_MATERIALS[sub(h, 2) % #HOUSE_MATERIALS + 1]
	else
		wall = MATERIALS[sub(h, 2) % #MATERIALS + 1]
	end
	local r = if kind == "shed" then 0 else math.clamp(cfg.Ruin + (subf(h, 3) - 0.5) * 0.6 + 0.2 * d, 0, 1)
	if kind == "office" and zoneOf(d) == 1 then
		r = math.max(r - 0.1, 0)
	end
	local o = p.o
	local full = math.min(floors, FULL)
	local y0 = p.y - 1
	local doorSide = sides[sub(h, 4) % #sides + 1]
	local width = if doorSide == 1 or doorSide == 3 then x1 - x0 else z1 - z0
	local b: Building = {
		kind = kind,
		x0 = x0,
		z0 = z0,
		x1 = x1,
		z1 = z1,
		floors = floors,
		full = full,
		y0 = y0,
		top = y0 + floors * FH + 1,
		wall = wall,
		cracked = CRACKED[wall] or 0,
		mossy = MOSSY[wall] or 0,
		slab = if house then PLANKS else CONCRETE,
		ground = if house then PLANKS else CONCRETE,
		r = r,
		o = o,
		collapse = floor(r * COLLAPSE_FLOORS * FH),
		glass = GLASS_CHANCE * (1 - r),
		bands = kind == "office",
		front = kind == "shop" or kind == "police" or kind == "fire",
		doorSide = doorSide,
		doorAlong = width // 2,
		-- (A bunker shed always has its Oak Door.)
		door = kind == "shed" or subf(h, 5) < DOOR_CHANCE,
		ladderSide = 0,
		ladderX = x0 + 1,
		ladderZ = z0 + 1,
		salt = h,
		containers = {},
		tables = {},
		special = {},
		hatchX = nil,
		hatchZ = nil,
		envelope = nil,
	}
	-- The ladder: an inner corner away from the door, against the north or south wall.
	if full >= 2 then
		local corner = sub(h, 6) % 4
		local east, south = corner % 2 == 1, corner >= 2
		b.ladderX = if east then x1 - 1 else x0 + 1
		b.ladderZ = if south then z1 - 1 else z0 + 1
		b.ladderSide = if south then 3 else 1
	end
	if kind == "shed" then
		-- The hatch's cell: the middle of the shed (see the header).
		b.hatchX, b.hatchZ = (x0 + x1) // 2, (z0 + z1) // 2
		b.r = 0
		return b
	end
	-- Containers (see the header).
	local ring = innerRing(b)
	if kind == "house" then
		for k = 0, full - 1 do
			local block = if sub(h, 20 + k) % 2 == 0 then CHEST else CRATE
			addContainers(b, ring, k, 1 + sub(h, 30 + k) % 2, block, "house")
		end
		if subf(h, 8) < HOUSE_CABINET then
			addContainers(b, ring, 0, 1, CABINET, "medicine_cabinet")
		end
	elseif kind == "apartment" then
		for k = 0, full - 1 do
			addContainers(b, ring, k, 1, CHEST, "house")
		end
	elseif kind == "office" or (kind == "shop" and loot == "office") then
		for k = 0, full - 1 do
			addContainers(b, ring, k, 1, CHEST, "office")
		end
	elseif kind == "police" then
		addContainers(b, ring, 0, 2, CHEST, "police")
	elseif kind == "fire" then
		addContainers(b, ring, 0, 2, CRATE, "fire_station")
	elseif loot == "grocery" then
		addContainers(b, ring, 0, 2 + sub(h, 9) % 3, CRATE, "grocery")
	elseif loot == "pharmacy" then
		addContainers(b, ring, 0, 2, CABINET, "pharmacy")
		addContainers(b, ring, 0, 1, CRATE, "pharmacy")
	elseif loot == "hardware" then
		addContainers(b, ring, 0, 2 + sub(h, 9) % 2, CRATE, "hardware")
	end
	return b
end

-- The highest decayed top over building b's box (levels 3-4: see the header), cached.
function CityLayout.envelope(b: Building): number
	local e = b.envelope
	if e then
		return e
	end
	local best = b.y0 + 3
	-- (effTop is decided per 2 x 2 columns, at their even corner: each of those once.)
	for z = b.z0 // 2 * 2, b.z1, 2 do
		for x = b.x0 // 2 * 2, b.x1, 2 do
			best = max(best, effTop(b, x, z))
		end
	end
	b.envelope = best
	return best
end

--[[
	Lot of parcel (pu, pv) of plan p (cached in the plan; see the header).
]]
function CityLayout.lot(p: Plan, pu: number, pv: number): Lot
	local i = pv * p.n + pu + 1
	local lot = p.lots[i]
	if lot then
		return lot
	end
	local x0 = p.x0 + pu * BLOCK + STREET
	local z0 = p.z0 + pv * BLOCK + STREET
	local x1, z1 = x0 + LOT - 1, z0 + LOT - 1
	local kind = p.kinds[i]
	local h = p.hashes[i]
	local new: Lot = {
		kind = kind,
		x0 = x0,
		z0 = z0,
		x1 = x1,
		z1 = z1,
		buildings = {},
		mound = false,
		stubs = {},
		cars = {},
		salt = sub(h, 50),
		top = p.y,
	}
	local top = p.y
	if kind == "houses" then
		local shed = p.sheds[i]
		for li = 1, 4 do
			local ix, iz = (li - 1) % 2, (li - 1) // 2
			local lx0, lz0 = x0 + ix * 13, z0 + iz * 13
			local sides = { if iz == 0 then 1 else 3, if ix == 0 then 4 else 2 }
			local b
			if shed == li then
				-- A shed whose middle lies in core columns 2..13 of its chunk (see the header).
				local sx0, sz0 = lx0 + 3, lz0 + 3
				for offset = 0, 5 do
					local cx = lx0 + 1 + (sub(h, 60) + offset) % 6 + 2
					if cx % 16 >= 2 and cx % 16 <= 13 then
						sx0 = cx - 2
						break
					end
				end
				for offset = 0, 5 do
					local cz = lz0 + 1 + (sub(h, 61) + offset) % 6 + 2
					if cz % 16 >= 2 and cz % 16 <= 13 then
						sz0 = cz - 2
						break
					end
				end
				b = newBuilding(p, i, li, "shed", "", sx0, sz0, sx0 + SHED - 1, sz0 + SHED - 1, sides)
			else
				b = newBuilding(p, i, li, "house", "", lx0 + 1, lz0 + 1, lx0 + 10, lz0 + 10, sides)
			end
			table.insert(new.buildings, b)
			top = max(top, b.top + 1)
		end
	elseif kind == "office" or kind == "apartment" or kind == "shop" or kind == "police" or kind == "fire" then
		local b = newBuilding(p, i, 0, kind, p.loots[i], x0 + 1, z0 + 1, x1 - 1, z1 - 1, { 1, 2, 3, 4 })
		table.insert(new.buildings, b)
		top = max(top, b.top + 1)
	elseif kind == "rubble" then
		new.mound = true
		top = max(top, p.y + 5)
		for k = 1, 1 + sub(h, 70) % 2 do
			local alongX = sub(h, 71 + k) % 2 == 0
			local length = 5 + sub(h, 73 + k) % 5
			local height = 2 + sub(h, 75 + k) % 5
			local sx = x0 + 2 + sub(h, 77 + k) % (LOT - 4 - (if alongX then length else 1))
			local sz = z0 + 2 + sub(h, 79 + k) % (LOT - 4 - (if alongX then 1 else length))
			local block = if sub(h, 81 + k) % 2 == 0 then CRACKED_BRICKS else CRACKED_CONCRETE
			table.insert(new.stubs, sx)
			table.insert(new.stubs, sz)
			table.insert(new.stubs, if alongX then sx + length - 1 else sx)
			table.insert(new.stubs, if alongX then sz else sz + length - 1)
			table.insert(new.stubs, p.y + height)
			table.insert(new.stubs, block)
			top = max(top, p.y + height)
		end
	elseif kind == "parking" then
		-- Wrecks parked in two rows of bays.
		for k = 0, 5 do
			if subf(h, 90 + k) < 0.35 then
				local row, bay = k // 3, k % 3
				table.insert(new.cars, x0 + 3 + bay * 8)
				table.insert(new.cars, z0 + 3 + row * 12)
				table.insert(new.cars, 0) -- along z
				table.insert(new.cars, sub(h, 100 + k))
			end
		end
		top = max(top, p.y + 2)
	end
	new.top = top
	p.lots[i] = new
	return new
end

--[[
	One above the highest block plan p puts in the block rectangle (inclusive): its lots' tops, and
	the street wrecks' two blocks over the ground.
]]
function CityLayout.topIn(p: Plan, minX: number, minZ: number, maxX: number, maxZ: number): number
	local best = p.y + 2
	local n = p.n
	for pv = max(0, (minZ - p.z0) // BLOCK), min(n - 1, (maxZ - p.z0) // BLOCK) do
		for pu = max(0, (minX - p.x0) // BLOCK), min(n - 1, (maxX - p.x0) // BLOCK) do
			local x0, z0 = p.x0 + pu * BLOCK + STREET, p.z0 + pv * BLOCK + STREET
			if x0 <= maxX and x0 + LOT - 1 >= minX and z0 <= maxZ and z0 + LOT - 1 >= minZ then
				best = max(best, CityLayout.lotTop(p, pu, pv))
			end
		end
	end
	return best
end

--[[
	Lot (pu, pv)'s `top` without planning the lot (its buildings' floors and its rubble's heights
	alone, from the same hashes: a few of them instead of a lot's planning), cached in the plan.
]]
function CityLayout.lotTop(p: Plan, pu: number, pv: number): number
	local i = pv * p.n + pu + 1
	local lot = p.lots[i]
	if lot then
		return lot.top
	end
	local cached = p.tops[i]
	if cached then
		return cached
	end
	local kind = p.kinds[i]
	local h = p.hashes[i]
	local top = p.y
	-- (A building's `top` is one above its roof, y0 + floors FH + 1, its lot's one more.)
	if kind == "houses" then
		local shed = p.sheds[i]
		for li = 1, 4 do
			top = max(top, p.y + floorsOf(p, i, li, if shed == li then "shed" else "house") * FH + 1)
		end
	elseif kind == "office" or kind == "apartment" or kind == "shop" or kind == "police" or kind == "fire" then
		top = max(top, p.y + floorsOf(p, i, 0, kind) * FH + 1)
	elseif kind == "rubble" then
		top = max(top, p.y + 5)
		for k = 1, 1 + sub(h, 70) % 2 do
			top = max(top, p.y + 2 + sub(h, 75 + k) % 5)
		end
	elseif kind == "parking" then
		top = max(top, p.y + 2)
	end
	p.tops[i] = top
	return top
end

--[[ Ground ]]

-- Street decay over an asphalt (or road line) block at (x, z): block, filler.
local function asphaltDecay(salt: number, block: number, x: number, z: number, o: number): (number, number)
	local roads = cfg.Roads
	if roll(bxor(salt, S_POT), x, 0, z) < roads.Potholes then
		return GRAVEL, GRAVEL
	end
	if vnoise(bxor(salt, S_GREEN), x, z, 4) < share(roads.Overgrown * o) then
		return if roll(bxor(salt, S_GREEN), x, 1, z) < 0.5 then GRASS else MOSS_BLOCK, DIRT
	end
	if roll(bxor(salt, S_STREET_CRACK), x // CRACK_PATCH, 0, z // CRACK_PATCH) < roads.Cracks then
		return CRACKED_ASPHALT, GRAVEL
	end
	return block, GRAVEL
end
CityLayout.asphaltDecay = asphaltDecay

-- A sidewalk or plaza block at (x, z): block, filler.
local function concreteDecay(salt: number, x: number, z: number, o: number): (number, number)
	local roads = cfg.Roads
	if vnoise(bxor(salt, S_WALK), x, z, 4) < share(roads.Overgrown * o * 1.5) then
		return GRASS, DIRT
	end
	if roll(bxor(salt, S_STREET_CRACK), x // CRACK_PATCH, 1, z // CRACK_PATCH) < roads.Cracks then
		return CRACKED_CONCRETE, GRAVEL
	end
	return CONCRETE, GRAVEL
end

--[[
	The top block override at column (x, z) of plan p's footprint and its filler (nil: natural
	ground: a building's or house's lot, a rubble lot), see the header.
]]
function CityLayout.surface(p: Plan, x: number, z: number): (number?, number?)
	local u, v = x - p.x0, z - p.z0
	local su, sv = u % BLOCK, v % BLOCK
	local streetU, streetV = su < STREET, sv < STREET
	local salt, o = p.salt, p.o
	if streetU or streetV then
		local block = ASPHALT
		if streetU and not streetV then
			if su == 0 or su == STREET - 1 then
				return concreteDecay(salt, x, z, o)
			elseif (sv == STREET or sv == BLOCK - 1) and su % 2 == 1 then
				block = LINE_WHITE
			elseif su == STREET // 2 and v % 8 < 4 then
				block = LINE_YELLOW
			end
		elseif streetV and not streetU then
			if sv == 0 or sv == STREET - 1 then
				return concreteDecay(salt, x, z, o)
			elseif (su == STREET or su == BLOCK - 1) and sv % 2 == 1 then
				block = LINE_WHITE
			elseif sv == STREET // 2 and u % 8 < 4 then
				block = LINE_YELLOW
			end
		end
		return asphaltDecay(salt, block, x, z, o)
	end
	local i = (v // BLOCK) * p.n + u // BLOCK + 1
	local kind = p.kinds[i]
	if kind == "park" then
		return GRASS, DIRT
	elseif kind == "plaza" then
		return concreteDecay(salt, x, z, o)
	elseif kind == "parking" then
		return asphaltDecay(salt, ASPHALT, x, z, o)
	end
	return nil, nil
end

-- May a tree grow at (x, z) of plan p's footprint? Only in parks.
function CityLayout.treeAllowed(p: Plan, x: number, z: number): boolean
	local u, v = x - p.x0, z - p.z0
	if u % BLOCK < STREET or v % BLOCK < STREET then
		return false
	end
	return p.kinds[(v // BLOCK) * p.n + u // BLOCK + 1] == "park"
end

-- The parcel (pu, pv) holding (x, z) of plan p's footprint, nil on a street.
function CityLayout.parcelAt(p: Plan, x: number, z: number): (number?, number)
	local u, v = x - p.x0, z - p.z0
	if u < 0 or v < 0 or u > 2 * p.radius or v > 2 * p.radius then
		return nil, 0
	end
	if u % BLOCK < STREET or v % BLOCK < STREET then
		return nil, 0
	end
	return u // BLOCK, v // BLOCK
end

--[[ Cars ]]

--[[
	The street cars of plan p reaching the block rectangle (inclusive): x0, z0 (the car's first
	corner), axis (0: along z, 1: along x) and salt per car, appended to `out`.
]]
function CityLayout.streetCars(p: Plan, minX: number, minZ: number, maxX: number, maxZ: number, out: { number })
	local chance = cfg.Cars
	local n = p.n
	for axis = 0, 1 do
		-- Streets across (index i: u = 32 i .. 32 i + 6 for axis 0) and stretches along them.
		local across0 = if axis == 0 then minX else minZ
		local across1 = if axis == 0 then maxX else maxZ
		local origin = if axis == 0 then p.x0 else p.z0
		local alongOrigin = if axis == 0 then p.z0 else p.x0
		for i = max(0, (across0 - origin - STREET) // BLOCK), min(n, (across1 - origin) // BLOCK) do
			for j = 0, n - 1 do
				for lane = 0, 1 do
					local h = cellHash(bxor(p.salt, S_CAR), i, axis * 2 + lane, j)
					if h / 4294967296 < chance then
						local a = origin + i * BLOCK + (if lane == 0 then 1 else 4)
						local b = alongOrigin + j * BLOCK + STREET + (h // 7) % (LOT - 3)
						local cx0, cz0 = if axis == 0 then a else b, if axis == 0 then b else a
						local cx1 = cx0 + (if axis == 0 then 1 else 3)
						local cz1 = cz0 + (if axis == 0 then 3 else 1)
						if cx0 <= maxX and cx1 >= minX and cz0 <= maxZ and cz1 >= minZ then
							table.insert(out, cx0)
							table.insert(out, cz0)
							table.insert(out, axis)
							table.insert(out, h)
						end
					end
				end
			end
		end
	end
end

--[[
	The cells of a car whose first corner is (x0, z0), along z (axis 0) or x (1), from salt h:
	calls emit(x, dy, z, block) for each (dy 0 on the ground's first air, 1 above), and returns
	the supply crate's cell (x, z; nil: none).
]]
function CityLayout.carCells(
	x0: number,
	z0: number,
	axis: number,
	h: number,
	emit: ((x: number, dy: number, z: number, block: number) -> ())?
): (number?, number?)
	local crate = (h // 65536) % 1000 / 1000 < CAR_CRATE
	local glass = (h // 4096) % 256 / 256 < CAR_GLASS
	local crateAt = (h // 32) % 4
	local cx, cz: number? = nil, nil
	for along = 0, 3 do
		for side = 0, 1 do
			local x = if axis == 0 then x0 + side else x0 + along
			local z = if axis == 0 then z0 + along else z0 + side
			local middle = along == 1 or along == 2
			local block = if middle then RUSTY else COAL_BLOCK
			if middle and crate and (along - 1) * 2 + side == crateAt then
				block = CRATE
				cx, cz = x, z
			end
			if emit then
				emit(x, 0, z, block)
				if not middle then
					emit(x, 1, z, RUSTY)
				elseif glass then
					emit(x, 1, z, GLASS)
				end
			end
		end
	end
	return cx, cz
end

--[[ Containers ]]

--[[
	Calls visit(x, y, z, block, loot) for every loot container of plan p in the block rectangle
	(inclusive), with its ScavengeLoot table: its buildings' (Chests, Supply Crates, Medicine
	Cabinets) and the Supply Crates of the wrecks on its parking lots and streets ("car", on the
	plateau's first air). `onLot`, when given, is called after each lot planned (a caller's work
	count: Generation/Cities yields as they add up).
]]
function CityLayout.containersIn(
	p: Plan,
	minX: number,
	minZ: number,
	maxX: number,
	maxZ: number,
	visit: (x: number, y: number, z: number, block: number, loot: string) -> (),
	onLot: (() -> ())?
)
	local n = p.n
	for pv = max(0, (minZ - p.z0) // BLOCK), min(n - 1, (maxZ - p.z0) // BLOCK) do
		for pu = max(0, (minX - p.x0) // BLOCK), min(n - 1, (maxX - p.x0) // BLOCK) do
			local lot = CityLayout.lot(p, pu, pv)
			if onLot then
				onLot()
			end
			for _, b in lot.buildings do
				local list = b.containers
				for k = 1, #list, 4 do
					local x, z = list[k], list[k + 2]
					if x >= minX and x <= maxX and z >= minZ and z <= maxZ then
						visit(x, list[k + 1], z, list[k + 3], b.tables[(k + 3) // 4])
					end
				end
			end
			local cars = lot.cars
			for k = 1, #cars, 4 do
				local cx, cz = CityLayout.carCells(cars[k], cars[k + 1], cars[k + 2], cars[k + 3], nil)
				if cx and cz and cx >= minX and cx <= maxX and cz >= minZ and cz <= maxZ then
					visit(cx, p.y, cz, CRATE, "car")
				end
			end
		end
	end
	local cars: { number } = {}
	CityLayout.streetCars(p, minX, minZ, maxX, maxZ, cars)
	for k = 1, #cars, 4 do
		local cx, cz = CityLayout.carCells(cars[k], cars[k + 1], cars[k + 2], cars[k + 3], nil)
		if cx and cz and cx >= minX and cx <= maxX and cz >= minZ and cz <= maxZ then
			visit(cx, p.y, cz, CRATE, "car")
		end
	end
end

--[[ Writing ]]

-- The chunk being written (module state: one chunk at a time per actor).
local NOTHING = buffer.create(0)
local wData: buffer = NOTHING
local wCells = 0
local wLevel = 0
local wStep, wStepY, wHalfY = 1, 1, 0
local wX0, wZ0, wX1, wZ1 = 0, 0, 0, 0
local wLowest, wTop = math.huge, 0

--[[
	The sample blocks of the first and last padded columns of the level-`level` chunk whose first
	core column is (originX, originZ): x0, z0, x1, z1 (what `begin` writes clips to).
]]
function CityLayout.span(level: number, originX: number, originZ: number): (number, number, number, number)
	local step = ChunkLayout.steps(level)
	local x0, z0 = originX - step + step // 2, originZ - step + step // 2
	return x0, z0, x0 + (P - 1) * step, z0 + (P - 1) * step
end

--[[
	Starts writing into padded chunk `data` (`cells` tall) of level `level` whose first core column
	is (originX, originZ). Nothing may yield until `finish`: the writer is module state, one chunk
	at a time per actor, and another generate on the actor during a yield would take it over.
]]
function CityLayout.begin(data: buffer, cells: number, level: number, originX: number, originZ: number)
	local step, stepY = ChunkLayout.steps(level)
	wData, wCells, wLevel = data, cells, level
	wStep, wStepY, wHalfY = step, stepY, stepY // 2
	wX0, wZ0, wX1, wZ1 = CityLayout.span(level, originX, originZ)
	wLowest, wTop = math.huge, 0
end

-- The lowest cell written (math.huge: none), one above the highest cell written (0: none).
function CityLayout.finish(): (number, number)
	wData = NOTHING
	return wLowest, wTop
end

-- Full detail: block (x, y, z), when it lies in the padded chunk.
local function put(x: number, y: number, z: number, block: number)
	if x < wX0 or x > wX1 or z < wZ0 or z > wZ1 or y < 1 or y >= wCells then
		return
	end
	writeu16(wData, ((y * P + (z - wZ0)) * P + (x - wX0)) * 2, block)
	if y >= wTop then
		wTop = y + 1
	end
	if y < wLowest then
		wLowest = y
	end
end

CityLayout.putBlock = put

-- Far nodes: cell (px, cy, pz).
local function putCell(px: number, cy: number, pz: number, block: number)
	if cy < 1 or cy >= wCells then
		return
	end
	writeu16(wData, ((cy * P + pz) * P + px) * 2, block)
	if cy >= wTop then
		wTop = cy + 1
	end
	if cy < wLowest then
		wLowest = cy
	end
end

-- The rubble lying under slab hole patch (x, k, z): one block per patch.
local function rubble(b: Building, x: number, k: number, z: number): number
	return if roll(bxor(b.salt, S_SLAB), x // SLAB_PATCH, k + 101, z // SLAB_PATCH) < 0.5
		then GRAVEL
		else CRACKED_CONCRETE
end

-- Full detail: building b's column (x, z) (see the header).
local function writeColumn(b: Building, x: number, z: number)
	local et = effTop(b, x, z)
	local y0 = b.y0
	local yEnd = min(et, wCells) - 1
	local onX = x == b.x0 or x == b.x1
	local onZ = z == b.z0 or z == b.z1
	local floors = b.floors
	if onX or onZ then
		local corner = onX and onZ
		local side, along = sideOf(b, x, z)
		local keep = essential(b, x, z)
		for y = y0, yEnd do
			local dy = y - y0
			local k = dy // FH
			local row = dy - k * FH
			local block: number
			if k >= floors then
				block = aged(b, side, along, k)
			elseif k == 0 and side == b.doorSide and along == b.doorAlong and (row == 1 or row == 2) then
				block = if not b.door then AIR elseif row == 1 then DOOR_LOWER[side] else DOOR_UPPER[side]
			else
				local window = if corner or keep then nil else windowAt(b, side, along, k, row)
				if window then
					block = window
				elseif row > 0 and not corner and not keep and holed(b, side, along, k) then
					block = AIR
				elseif row == 0 then
					-- (The floor line stays whole: it merges with the slab behind it.)
					block = b.wall
				else
					block = aged(b, side, along, k)
				end
			end
			put(x, y, z, block)
		end
		return
	end
	local depth = min(x - b.x0, b.x1 - x, z - b.z0, b.z1 - z)
	local ladder = b.ladderSide ~= 0 and x == b.ladderX and z == b.ladderZ
	-- The last full floor's slab, or below the jagged top of the wall the ladder hangs on (its
	-- 2 x 2 group may lie lower than the ladder's own: no rung on air).
	local ladderTop = y0 + (b.full - 1) * FH
	if ladder then
		local side = b.ladderSide
		ladderTop = min(ladderTop, effTop(b, x + SIDE_DX[side], z + SIDE_DZ[side]) - 1)
	end
	local hatch = b.hatchX == x and b.hatchZ == z
	local cornerCell = (x == b.x0 + 1 or x == b.x1 - 1) and (z == b.z0 + 1 or z == b.z1 - 1)
	local o = b.o
	for y = y0, yEnd do
		local dy = y - y0
		local k = dy // FH
		local row = dy - k * FH
		local block: number
		if k >= floors then
			block = b.slab
		elseif k < b.full then
			if row == 0 then
				if k == 0 then
					if hatch then
						block = CONCRETE
					elseif
						b.r > 0
						and roll(bxor(b.salt, S_GROUND), x // SLAB_PATCH, 0, z // SLAB_PATCH)
							< GROUND_GREEN * o * b.r
					then
						block = if roll(bxor(b.salt, S_GROUND), x // SLAB_PATCH, 2, z // SLAB_PATCH) < 0.5
							then GRASS
							else MOSS_BLOCK
					else
						block = b.ground
					end
				elseif ladder and y <= ladderTop then
					block = LADDER_ON[b.ladderSide]
				elseif slabHole(b, x, k, z) then
					block = AIR
				else
					block = b.slab
				end
			elseif ladder and y <= ladderTop then
				block = LADDER_ON[b.ladderSide]
			else
				block = AIR
				if row == 1 then
					local special = b.special[cellKey(b, x, y, z)]
					if special then
						block = special
					elseif
						k + 1 < floors
						and slabHole(b, x, k + 1, z)
						and (k == 0 or not slabHole(b, x, k, z))
						and not (ladder and y - 1 <= ladderTop)
					then
						-- Rubble from the hole above, on a floor that stands (Gravel falls).
						block = rubble(b, x, k + 1, z)
					elseif
						not hatch
						and (k == 0 or not slabHole(b, x, k, z))
						and not (ladder and y - 1 <= ladderTop)
						and vnoise(bxor(b.salt, S_CARPET), x, z + k * 97, 5) < share(FLOOR_CARPET * o)
					then
						block = CARPET
					end
				elseif row == 3 and cornerCell and not ladder and b.r > 0 then
					if roll(bxor(b.salt, S_WEB), x, y, z) < COBWEBS * b.r then
						block = COBWEB
					end
				end
			end
		elseif depth >= 3 then
			block = b.wall
		elseif row == 0 then
			block = if slabHole(b, x, k, z) then AIR else b.slab
		elseif row == 1 and k + 1 < floors and slabHole(b, x, k + 1, z) then
			block = rubble(b, x, k + 1, z)
		else
			block = AIR
		end
		put(x, y, z, block)
	end
	-- Moss carpet on the roof, where the top stands whole.
	if et == b.top and vnoise(bxor(b.salt, S_CARPET), x, z, 5) < share(ROOF_CARPET * o) then
		put(x, b.top, z, CARPET)
	end
end

-- Full detail: the vines down the outer walls of building b (see the header).
local function writeVines(b: Building)
	if b.o <= 0 then
		return
	end
	local salt = bxor(b.salt, S_VINE)
	local chance = VINES * b.o
	for side = 1, 4 do
		local dx, dz = SIDE_DX[side], SIDE_DZ[side]
		local width = if side == 1 or side == 3 then b.x1 - b.x0 else b.z1 - b.z0
		for along = 1, width - 1 do
			local x = if side == 1 or side == 3 then b.x0 + along elseif side == 2 then b.x1 else b.x0
			local z = if side == 2 or side == 4 then b.z0 + along elseif side == 1 then b.z0 else b.z1
			local ox, oz = x + dx, z + dz
			if ox < wX0 or ox > wX1 or oz < wZ0 or oz > wZ1 then
				continue
			end
			local h = cellHash(salt, x, side, z)
			if h / 4294967296 >= chance then
				continue
			end
			if side == b.doorSide and abs(along - b.doorAlong) <= 1 then
				continue
			end
			-- From the jagged top's highest wall cell down a hashed length: the first hangs on its
			-- wall (a sturdy block), the rest on the vine above.
			local topY = effTop(b, x, z) - 1
			local length = VINE_MIN + (h // 4096) % (VINE_MAX - VINE_MIN + 1)
			local wall = CityLayout.wallBlock(b, x, topY, z)
			if wall == nil or readu8(STURDY, wall) == 0 then
				continue
			end
			local vine = VINE_OUTSIDE[side]
			for y = topY, max(topY - length + 1, b.y0 + 1), -1 do
				put(ox, y, oz, vine)
			end
		end
	end
end

--[[
	The block building b puts at wall cell (x, y, z) (the full detail rules), nil when the jagged top
	leaves it out.
]]
function CityLayout.wallBlock(b: Building, x: number, y: number, z: number): number?
	if y < b.y0 or y >= effTop(b, x, z) then
		return nil
	end
	local side, along = sideOf(b, x, z)
	local dy = y - b.y0
	local k = dy // FH
	local row = dy - k * FH
	if k >= b.floors then
		return aged(b, side, along, k)
	end
	if k == 0 and side == b.doorSide and along == b.doorAlong and (row == 1 or row == 2) then
		return if not b.door then AIR elseif row == 1 then DOOR_LOWER[side] else DOOR_UPPER[side]
	end
	local corner = (x == b.x0 or x == b.x1) and (z == b.z0 or z == b.z1)
	local keep = essential(b, x, z)
	local window = if corner or keep then nil else windowAt(b, side, along, k, row)
	if window then
		return window
	end
	if row > 0 and not corner and not keep and holed(b, side, along, k) then
		return AIR
	elseif row == 0 then
		return b.wall
	end
	return aged(b, side, along, k)
end

-- Full detail: a rubble lot's mound and wall stubs.
local function writeRubble(p: Plan, lot: Lot)
	local cx, cz = (lot.x0 + lot.x1) / 2, (lot.z0 + lot.z1) / 2
	local H = p.y
	for z = max(lot.z0, wZ0), min(lot.z1, wZ1) do
		for x = max(lot.x0, wX0), min(lot.x1, wX1) do
			local height = CityLayout.moundHeight(lot, cx, cz, x, z)
			for y = H, H + height - 1 do
				local u = roll(bxor(lot.salt, S_RUBBLE), x // 2, y, z // 2)
				put(x, y, z, if u < 0.5 then GRAVEL elseif u < 0.8 then CRACKED_CONCRETE else BRICK)
			end
		end
	end
	local stubs = lot.stubs
	for k = 1, #stubs, 6 do
		for z = max(stubs[k + 1], wZ0), min(stubs[k + 3], wZ1) do
			for x = max(stubs[k], wX0), min(stubs[k + 2], wX1) do
				for y = H, stubs[k + 4] - 1 do
					put(x, y, z, stubs[k + 5])
				end
			end
		end
	end
end

-- The rubble mound's height (blocks) at (x, z) of a rubble lot centred on (cx, cz).
function CityLayout.moundHeight(lot: Lot, cx: number, cz: number, x: number, z: number): number
	local dist = math.sqrt((x - cx) ^ 2 + (z - cz) ^ 2)
	return max(0, floor(3 - dist / 3 + 2 * vnoise(bxor(lot.salt, S_MOUND), x, z, 4) - 1))
end

-- Full detail: a car whose first corner is (x0, z0), standing on ground whose first air is y.
local function writeCar(x0: number, z0: number, axis: number, h: number, y: number)
	CityLayout.carCells(x0, z0, axis, h, function(x: number, dy: number, z: number, block: number)
		put(x, y + dy, z, block)
	end)
end
CityLayout.writeCar = function(x0: number, z0: number, axis: number, h: number, y: number)
	writeCar(x0, z0, axis, h, y)
end

--[[
	Writes lot `lot` of plan p into the chunk being written: full detail (level 0) every block of
	its buildings, rubble and parked wrecks; far nodes the massing (see the header).
]]
function CityLayout.writeLot(p: Plan, lot: Lot)
	if wLevel == 0 then
		for _, b in lot.buildings do
			if b.x1 + 1 < wX0 or b.x0 - 1 > wX1 or b.z1 + 1 < wZ0 or b.z0 - 1 > wZ1 then
				continue
			end
			for z = max(b.z0, wZ0), min(b.z1, wZ1) do
				for x = max(b.x0, wX0), min(b.x1, wX1) do
					writeColumn(b, x, z)
				end
			end
			writeVines(b)
		end
		if lot.mound then
			writeRubble(p, lot)
		end
		local cars = lot.cars
		for k = 1, #cars, 4 do
			writeCar(cars[k], cars[k + 1], cars[k + 2], cars[k + 3], p.y)
		end
		return
	end
	-- Far nodes: the padded columns' sample blocks inside each building.
	local step = wStep
	local x0 = wX0
	local z0 = wZ0
	for _, b in lot.buildings do
		local px0 = max(0, -((x0 - b.x0) // step))
		local px1 = min(P - 1, (b.x1 - x0) // step)
		local pz0 = max(0, -((z0 - b.z0) // step))
		local pz1 = min(P - 1, (b.z1 - z0) // step)
		if px0 > px1 or pz0 > pz1 then
			continue
		end
		local block = b.wall
		local envelope = if wLevel >= 3 then CityLayout.envelope(b) else 0
		for pz = pz0, pz1 do
			local z = z0 + pz * step
			for px = px0, px1 do
				local x = x0 + px * step
				local top = if wLevel >= 3 then envelope else effTop(b, x, z)
				-- Cells whose sample block lies in y0 .. top - 1.
				local cy0 = (b.y0 - wHalfY + wStepY - 1) // wStepY
				local cy1 = (top - 1 - wHalfY) // wStepY
				for cy = cy0, cy1 do
					putCell(px, cy, pz, block)
				end
			end
		end
	end
	if lot.mound and wLevel <= 2 then
		local cx, cz = (lot.x0 + lot.x1) / 2, (lot.z0 + lot.z1) / 2
		local H = p.y
		local px0 = max(0, -((x0 - lot.x0) // step))
		local px1 = min(P - 1, (lot.x1 - x0) // step)
		local pz0 = max(0, -((z0 - lot.z0) // step))
		local pz1 = min(P - 1, (lot.z1 - z0) // step)
		for pz = pz0, pz1 do
			local z = z0 + pz * step
			for px = px0, px1 do
				local x = x0 + px * step
				local top = H + CityLayout.moundHeight(lot, cx, cz, x, z)
				local stubs = lot.stubs
				for k = 1, #stubs, 6 do
					if x >= stubs[k] and x <= stubs[k + 2] and z >= stubs[k + 1] and z <= stubs[k + 3] then
						top = max(top, stubs[k + 4])
					end
				end
				for cy = (H - wHalfY + wStepY - 1) // wStepY, (top - 1 - wHalfY) // wStepY do
					putCell(px, cy, pz, GRAVEL)
				end
			end
		end
	end
end

-- Full detail: the street cars of plan p reaching the chunk being written.
function CityLayout.writeStreetCars(p: Plan)
	if wLevel ~= 0 then
		return
	end
	local cars: { number } = {}
	CityLayout.streetCars(p, wX0, wZ0, wX1, wZ1, cars)
	for k = 1, #cars, 4 do
		writeCar(cars[k], cars[k + 1], cars[k + 2], cars[k + 3], p.y)
	end
end

return CityLayout
