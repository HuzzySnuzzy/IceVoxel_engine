--!strict
--!native
--[[
	Water lakes and puddles on the surface.

	Lakes: Minecraft's LakeFeature with lake_water's configuration (the overworld's water lakes
	before 1.18, when aquifers replaced them): the lava lakes' shape (Lava.shapeOf, the same draws:
	4..7 ellipsoid blobs, 3..9 wide and 2..6 tall, in a 16 x 8 x 16 box), water in its lower four
	layers and air above (the bowl). lake_water had no barrier: its shell's draws are made and
	unused. Minecraft refuses a lake whose shell (the cells next to the blobs) is liquid from
	layer 4 up or not solid below it, so the water never spills: the same rule here, on the full
	detail heights (a cell below a column's height is ground, at or above it air, or water below
	the sea). Like lake_water:
	  * in a biome where water freezes (frozen, or snow covered) the top layer of water is Ice;
	  * dirt the bowl uncovers (above the water) grows back the column's top: grass stays grass
	    around the rim (Minecraft turns exposed dirt in the bowl into grass, mycelium in mushroom
	    fields; here also podzol, dry grass and snow);
	  * the soil under and beside the water (dirt, grass and the other tops) becomes the lake's
	    floor: the biome's underwater block (sand, gravel), or for biomes with a dirt floor patches
	    of sand, gravel and dirt (`floorAt`: about 40 / 30 / 30 %, in blotches 2-3 blocks across,
	    like Minecraft's disk_sand, disk_clay and disk_gravel features; there is no clay block),
	    and dirt where water lies below it too (no sand that would fall);
	  * a top beside the water with the sky above it (the shore at the water's edge) becomes sand
	    or gravel in patches (`shoreAt`: about 40 % sand, 15 % gravel, 2 x 2 blotches; on ground,
	    never over air or water), else stays grass; frozen lakes keep their snowy shores.
	One candidate per 16 x 16 block cell with chance 1 / Water.Rarity (rarer than lava lakes, which
	are 1 / 200), times the biome's weight in Water.Biomes (deserts and savannas fewer); its layer
	4 at the full detail height of the box's centre, on dry land more than 2 blocks above the sea
	(no beaches, rivers or seas). Two candidates in neighbouring cells could overlap, and each,
	decided alone, could spill into the other's bowl: neither is a lake (about 1 in 60). Decided
	from the full detail terrain alone, as Lava's surface lakes, so every chunk and level agrees:
	refused where a cell could meet a deep cave (the caves' 9 cave-free blocks), within PROTECT
	blocks of a library structure's piece, an oil well or a surface lava lake, and within
	SpawnClearance blocks of the spawn. Surface caves leave the
	box and PROTECT around it alone and trees keep out (TerrainGenerator); LOD chunks up to
	Config.StructureMaxLevel point-sample the lake as Lava does (water, or ice, in the top cell of a
	column whose sample block lies over the lake's water), so lakes show from afar, and the map
	paints them (Map/MapPainter).

	Puddles: shallow pools one block deep in natural hollows, not a Minecraft feature (its swamps
	and rain have none; IceVoxel's terrain is a heightfield of whole blocks, so a puddle is water
	in place of the top block of a few columns at the bottom of a dip). One candidate per
	Puddles.Spacing square cell, at a hashed spot, kept with its biome's chance (Puddles.Biomes:
	most in jungles and forests, fewer on plains, rare in deserts, savannas and on bare peaks, none
	in frozen or snowy biomes). From the spot it runs downhill, steepest first, up to DRAIN steps,
	to a column no 4-neighbour is lower than (still going after DRAIN steps: a long slope, no
	puddle), the bottom of the dip at height L. Then it floods outwards from there over columns of
	that same height L, within a wobbly radius (Puddles.Radius, two harmonics of up to WOBBLE
	each) and up to Size[2] columns, but only onto columns with no lower 4-neighbour: every water
	cell (y L - 1) has ground or water beside it and ground below, so nothing spills. Fewer than
	Size[1] columns, a dip at L <= sea level + 2, a column a surface cave may open
	(SurfaceCaves.carvesTop), a column of a biome where water freezes on or next to it (no water
	beside snow), a library structure's piece, an oil well, a lava or water lake within
	PUDDLE_MARGIN blocks, or the spawn within SpawnClearance blocks: no puddle. Two puddles
	draining into the same dip overlap at one water level, which holds as well. Decided
	from the full detail heights alone, like the lakes. Full detail chunks only: a puddle is a
	few blocks across, less than a cell of a far node (2+ blocks), so far nodes don't draw them
	(they only keep trees and surface caves out of them, as full detail does, so trees agree at
	every level); the map shows them at 1-2 blocks a pixel.

	All of it is water sources (level 0) at rest: every water cell is held in beside and below, so
	nothing flows until something next to it changes (the server's Behaviours/Fluid).
]]

local Config = require(script.Parent.Parent.Config)
local Blocks = require(script.Parent.Parent.Blocks)
local Biomes = require(script.Parent.Parent.Biomes)
local ChunkLayout = require(script.Parent.Parent.World.ChunkLayout)
local Hash = require(script.Parent.Parent.Util.Hash)
local Lava = require(script.Parent.Lava)

local P = ChunkLayout.PADDED
local LAYER = ChunkLayout.LAYER
local SEA = Config.SeaLevel
local MIN_Y = Config.Caves.MinY

local BOX, LAYERS, SURFACE_LAYER = Lava.BOX, Lava.LAYERS, Lava.SURFACE_LAYER
local OUT, LAKE, BARRIER, SHELL = Lava.OUT, Lava.LAKE, Lava.BARRIER, Lava.SHELL
local cellIndex = Lava.cellIndex

-- Tuning --------------------------------------------------------------------------------------------
local CAVE_FREE = 9 -- no cave air within this many blocks of a column's surface (Caves: d < 0.02)
local SHORE = 2 -- lakes and puddles lie on land more than this many blocks above the sea (no beaches)
local PROTECT = 2 -- surface caves and trees keep this many blocks from a lake's box
local PUDDLE_MARGIN = 1 -- ... and this many from a puddle's columns' bounds
local DRAIN = 12 -- a puddle's spot runs at most this many steps downhill to the bottom of its dip
local WOBBLE = 0.3 -- amplitude of each of the two harmonics of a puddle's radius (share of it)
-- A dirt-floored biome's lake floor: the mean of two coarse hashes (2- and 3-block grids) below
-- FLOOR_SAND is sand, below FLOOR_GRAVEL gravel, else dirt (a triangular spread: 40 / 31 / 29 %).
local FLOOR_SAND, FLOOR_GRAVEL = 0.45, 0.62
-- Its shore (tops at the water's edge): a 2-block grid hash below SHORE_SAND is sand, below
-- SHORE_GRAVEL gravel, else the top stays.
local SHORE_SAND, SHORE_GRAVEL = 0.4, 0.55

local readu8 = buffer.readu8
local writeu8 = buffer.writeu8
local readu16 = buffer.readu16
local writeu16 = buffer.writeu16
local huge = math.huge

local AIR = Blocks.AIR
local id = Blocks.id
local WATER = Blocks.fluidId("Water", 0)
local ICE, DIRT, SAND, GRAVEL, SNOW, BEDROCK = id.Ice, id.Dirt, id.Sand, id.Gravel, id.Snow, id.Bedrock

-- Soil under water becomes the lake's floor block.
local SOIL: { [number]: boolean } = {}
for _, name in { "Dirt", "Grass", "DryGrass", "Podzol", "Mycelium", "CoarseDirt", "Snow" } do
	SOIL[id[name]] = true
end
-- Tops that grow back on the dirt a lake's bowl uncovers (as SurfaceCaves).
local GRASSY: { [number]: boolean } = {
	[id.Grass] = true,
	[id.DryGrass] = true,
	[id.Podzol] = true,
	[id.Mycelium] = true,
	[id.Snow] = true,
}

local water = Config.Lakes.Water
local puddleCfg = Config.Lakes.Puddles

-- Per biome index: a water lake candidate's weight and a puddle cell's chance (frozen and snowy
-- biomes: none), and whether water freezes there.
local lakeWeight: { number } = {}
local puddleChance: { number } = {}
local freezes: { boolean } = {}
local MAX_PUDDLE_CHANCE = 0
for i, biome in Biomes.list do
	local cold = biome.frozen or biome.top == SNOW
	freezes[i] = cold
	lakeWeight[i] = water.Biomes[biome.name] or 1
	local chance = puddleCfg.Biomes[biome.name] or puddleCfg.Chance
	puddleChance[i] = if cold then 0 else chance
	MAX_PUDDLE_CHANCE = math.max(MAX_PUDDLE_CHANCE, puddleChance[i])
end
for name in water.Biomes do
	assert(Biomes.byName(name), `Config.Lakes.Water.Biomes names unknown biome {name}`)
end
for name in puddleCfg.Biomes do
	assert(Biomes.byName(name), `Config.Lakes.Puddles.Biomes names unknown biome {name}`)
end

--[[
	A water lake: its box's corner cell (world x, the y of layer 0, z) and its shape (Lava.Lake's
	layout: water below SURFACE_LAYER, the bowl's air from it up, shell cells left as they are but
	for soil under water). `cells`: water cells; `frozen`: the top layer of water is Ice; `floor`:
	the block soil under the water becomes.
]]
export type Lake = {
	x: number,
	y: number,
	z: number,
	shape: buffer,
	cells: number,
	frozen: boolean,
	floor: number,
	biome: number,
	-- Seed of its floor and shore patches.
	patch: number,
}

--[[
	A puddle: the bounds of its columns (inclusive), the y of its water (one below the ground's
	height there), a u8 per column of the bounds at (z - z0) * (x1 - x0 + 1) + (x - x0) (1: water)
	and its number of columns; `biome`: of the dip's bottom.
]]
export type Puddle = {
	x0: number,
	z0: number,
	x1: number,
	z1: number,
	y: number,
	mask: buffer,
	cells: number,
	biome: number,
}

--[[
	What lakes and puddles need of the terrain, all at full detail (TerrainGenerator): a column's
	height (first air) and biome index, whether a block rectangle (inclusive) is free of library
	structure pieces, oil wells and surface lava lakes, the spawn column and whether a surface cave
	may open column (x, z) (SurfaceCaves.carvesTop; nil: no surface caves).
]]
export type Terrain = {
	height: (x: number, z: number) -> number,
	biome: (x: number, z: number) -> number,
	free: (minX: number, minZ: number, maxX: number, maxZ: number) -> boolean,
	spawn: () -> (number, number),
	carvesTop: ((x: number, z: number) -> boolean)?,
}

export type LakeGen = {
	-- Every water lake whose box (grown by PROTECT) reaches the block rectangle (inclusive).
	lakes: (minX: number, minZ: number, maxX: number, maxZ: number) -> { Lake },
	-- Every puddle whose bounds (grown by PUDDLE_MARGIN) reach the block rectangle (inclusive);
	-- `yield` is called after each candidate cell.
	puddles: (minX: number, minZ: number, maxX: number, maxZ: number, yield: (() -> ())?) -> { Puddle },
	--[[
		Writes `lakes` and `puddles` into the padded `level` chunk (first core column originX,
		originZ; `cells` tall). Level 0 writes the lakes' cells (water or ice, the bowl's air, the
		floor and the regrown rim) and the puddles' water; levels up to Config.StructureMaxLevel put
		water (ice) into the top cell of each column whose sample block lies over a lake's water,
		and no puddles. `topCells` (per padded column) drop below what was dug or flooded, so they
		keep describing the ground. Returns the lowest cell written with water, ice or air
		(math.huge: none) and one above the highest water or ice (0: none).
	]]
	write: (
		lakes: { Lake },
		puddles: { Puddle },
		data: buffer,
		level: number,
		originX: number,
		originZ: number,
		cells: number,
		topCells: { number }
	) -> (number, number),
}

local Lakes = {}

Lakes.BOX = BOX
Lakes.PROTECT = PROTECT
Lakes.PUDDLE_MARGIN = PUDDLE_MARGIN
Lakes.DRAIN = DRAIN
Lakes.SHORE = SHORE

-- Is column (x, z) one of the puddle's?
function Lakes.inPuddle(puddle: Puddle, x: number, z: number): boolean
	if x < puddle.x0 or x > puddle.x1 or z < puddle.z0 or z > puddle.z1 then
		return false
	end
	return readu8(puddle.mask, (z - puddle.z0) * (puddle.x1 - puddle.x0 + 1) + x - puddle.x0) == 1
end

-- Does the lake hold water (or ice) in column (x, z)?
--[[
	The floor block under `lake`'s water at world column (wx, wz): the biome's underwater block, or
	for a dirt-floored biome patches of sand, gravel and dirt (see the header).
]]
function Lakes.floorAt(lake: Lake, wx: number, wz: number): number
	if lake.floor ~= DIRT then
		return lake.floor
	end
	local v = (Hash.float3(lake.patch, wx // 3, 0, wz // 3) + Hash.float3(lake.patch, (wx + 1) // 2, 1, (wz + 1) // 2))
		/ 2
	return if v < FLOOR_SAND then SAND elseif v < FLOOR_GRAVEL then GRAVEL else DIRT
end

-- The shore block at the water's edge of `lake` at world column (wx, wz): sand, gravel, or nil
-- (the top stays). A biome with a sand or gravel floor has a shore of it.
function Lakes.shoreAt(lake: Lake, wx: number, wz: number): number?
	local v = Hash.float3(lake.patch, wx // 2, 2, wz // 2)
	if lake.floor ~= DIRT then
		return if v < SHORE_GRAVEL then lake.floor else nil
	end
	return if v < SHORE_SAND then SAND elseif v < SHORE_GRAVEL then GRAVEL else nil
end

function Lakes.wet(lake: Lake, x: number, z: number): boolean
	local lx, lz = x - lake.x, z - lake.z
	if lx < 0 or lz < 0 or lx >= BOX or lz >= BOX then
		return false
	end
	for y = 1, SURFACE_LAYER - 1 do
		if readu8(lake.shape, cellIndex(lx, y, lz)) == LAKE then
			return true
		end
	end
	return false
end

-- Cell keys of a candidate grid.
local function cellKey(cx: number, cz: number): number
	return (cx + 2097152) * 4194304 + (cz + 2097152)
end

-- A cache of decided candidate cells (`value` nil: none) in two generations, so it stays small.
local function cache<T>(decide: (cx: number, cz: number) -> T?): (cx: number, cz: number) -> T?
	local recent: { [number]: { value: T? } } = {}
	local older: { [number]: { value: T? } } = {}
	local count = 0
	return function(cx: number, cz: number): T?
		local key = cellKey(cx, cz)
		local entry = recent[key]
		if entry == nil then
			entry = older[key] or { value = decide(cx, cz) }
			if count >= 4096 then
				older, recent, count = recent, {}, 0
			end
			recent[key] = entry
			count += 1
		end
		return entry.value
	end
end

function Lakes.new(seed: number, terrain: Terrain): LakeGen
	local lakeSalt = Hash.hash2(seed, Hash.string("lakes.water"), 0x3C9C)
	local puddleSalt = Hash.hash2(seed, Hash.string("lakes.puddles"), 0x4DAD)
	local spawnClearance = Config.Lakes.SpawnClearance
	local spacing = puddleCfg.Spacing
	local minRadius, maxRadius = puddleCfg.Radius[1], puddleCfg.Radius[2]
	local minCells, maxCells = puddleCfg.Size[1], puddleCfg.Size[2]
	-- How far a puddle's columns can lie from its cell: the walk downhill, then the radius.
	local puddleReach = DRAIN + math.ceil(maxRadius * (1 + 2 * WOBBLE)) + PUDDLE_MARGIN

	local function nearSpawn(x: number, z: number): boolean
		if spawnClearance <= 0 then
			return false
		end
		local sx, sz = terrain.spawn()
		return (x - sx) ^ 2 + (z - sz) ^ 2 < spawnClearance ^ 2
	end

	-- The water lake of candidate cell (cx, cz), nil when it has none.
	local function decideLake(cx: number, cz: number): Lake?
		local rng = Hash.rng(Hash.hash2(lakeSalt, cx, cz))
		if not water.Enabled or rng:float() * water.Rarity >= 1 then
			return nil
		end
		-- Two candidates in neighbouring cells could overlap, and each decided alone would spill
		-- into the other's bowl: neither is a lake (some 2% of them).
		for dz = -1, 1 do
			for dx = -1, 1 do
				if
					(dx ~= 0 or dz ~= 0)
					and Hash.rng(Hash.hash2(lakeSalt, cx + dx, cz + dz)):float() * water.Rarity < 1
				then
					return nil
				end
			end
		end
		local x0 = cx * BOX + rng:int(0, BOX - 1)
		local z0 = cz * BOX + rng:int(0, BOX - 1)
		local shape, cells, ax, az, bx, bz = Lava.shapeOf(rng)
		local keep = rng:float()
		-- (A draw no longer used, kept so the draws after it are unchanged.)
		rng:float()
		if cells == 0 then
			return nil
		end
		local mx, mz = x0 + BOX // 2, z0 + BOX // 2
		local o = terrain.height(mx, mz)
		local base = o - SURFACE_LAYER
		if base <= MIN_Y or o <= SEA + SHORE then
			return nil
		end
		local biomeIndex = terrain.biome(mx, mz)
		if keep >= lakeWeight[biomeIndex] then
			return nil
		end
		if nearSpawn(mx, mz) then
			return nil
		end
		-- The shell rule and the cave-free rule, column by column, on the full detail heights.
		for x = ax, bx do
			for z = az, bz do
				local first = -1
				for y = 0, LAYERS - 1 do
					if readu8(shape, cellIndex(x, y, z)) ~= OUT then
						first = y
						break
					end
				end
				if first < 0 then
					continue
				end
				local h = terrain.height(x0 + x, z0 + z)
				if h - (base + first) >= CAVE_FREE then
					return nil
				end
				for y = first, LAYERS - 1 do
					local v = readu8(shape, cellIndex(x, y, z))
					if v == BARRIER or v == SHELL then
						local wy = base + y
						if y >= SURFACE_LAYER then
							if wy >= h and wy < SEA then
								return nil -- water beside the bowl
							end
						elseif wy >= h then
							return nil -- air or water beside the lake's water
						end
					end
				end
			end
		end
		if not terrain.free(x0 - PROTECT, z0 - PROTECT, x0 + BOX - 1 + PROTECT, z0 + BOX - 1 + PROTECT) then
			return nil
		end
		local biome = Biomes.list[biomeIndex]
		local floor = biome.underwater
		return table.freeze({
			x = x0,
			y = base,
			z = z0,
			shape = shape,
			cells = cells,
			frozen = freezes[biomeIndex],
			floor = floor,
			biome = biomeIndex,
			patch = rng:int(0, 2 ^ 30),
		})
	end
	local lakeAt: (cx: number, cz: number) -> Lake? = cache(decideLake)

	local function lakes(minX: number, minZ: number, maxX: number, maxZ: number): { Lake }
		local list: { Lake } = {}
		-- A box's corner lies in its cell, so it reaches up to 2 BOX - 2 blocks past the cell's start.
		local reach = 2 * BOX - 2 + PROTECT
		for cz = (minZ - reach) // BOX, (maxZ + PROTECT) // BOX do
			for cx = (minX - reach) // BOX, (maxX + PROTECT) // BOX do
				local lake: Lake? = lakeAt(cx, cz)
				if
					lake
					and lake.x - PROTECT <= maxX
					and lake.x + BOX - 1 + PROTECT >= minX
					and lake.z - PROTECT <= maxZ
					and lake.z + BOX - 1 + PROTECT >= minZ
				then
					table.insert(list, lake)
				end
			end
		end
		return list
	end

	-- The puddle of candidate cell (cx, cz), nil when it has none.
	local function decidePuddle(cx: number, cz: number): Puddle?
		local rng = Hash.rng(Hash.hash2(puddleSalt, cx, cz))
		local roll = rng:float()
		if not puddleCfg.Enabled or roll >= MAX_PUDDLE_CHANCE then
			return nil
		end
		local sx = cx * spacing + rng:int(0, spacing - 1)
		local sz = cz * spacing + rng:int(0, spacing - 1)
		if roll >= puddleChance[terrain.biome(sx, sz)] then
			return nil
		end
		-- Heights around the spot, each sampled once (DRAIN + the radius stays within 64).
		local known: { [number]: number } = {}
		local function height(x: number, z: number): number
			local k = (x - sx + 64) * 256 + (z - sz + 64)
			local h = known[k]
			if h == nil then
				h = terrain.height(x, z)
				known[k] = h
			end
			return h
		end
		-- Downhill to the bottom of the dip, steepest first (ties: the first in E, W, S, N order).
		local x, z = sx, sz
		local h = height(x, z)
		local settled = false
		for _ = 0, DRAIN do
			local bx, bz, bh = x, z, h
			for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
				local nh = height(x + d[1], z + d[2])
				if nh < bh then
					bx, bz, bh = x + d[1], z + d[2], nh
				end
			end
			if bh == h then
				settled = true
				break
			end
			x, z, h = bx, bz, bh
		end
		if not settled or h <= SEA + SHORE then
			return nil
		end
		local biome = terrain.biome(x, z)
		if puddleChance[biome] <= 0 or nearSpawn(x, z) then
			return nil
		end
		-- Flood the dip's floor from its bottom: columns of the same height within the wobbly
		-- radius whose 4-neighbours are none lower (so the water is held in).
		local radius = minRadius + rng:float() * (maxRadius - minRadius)
		local a1, p1 = rng:float() * WOBBLE, rng:float() * 2 * math.pi
		local a2, p2 = rng:float() * WOBBLE, rng:float() * 2 * math.pi
		local list = { x, z }
		local seen: { [number]: boolean } = { [(x - sx + 64) * 256 + (z - sz + 64)] = true }
		local accepted: { number } = {}
		local head = 1
		while head < #list and #accepted < maxCells * 2 do
			local qx, qz = list[head], list[head + 1]
			head += 2
			local dx, dz = qx - x, qz - z
			local ok = height(qx, qz) == h
			if ok and (dx ~= 0 or dz ~= 0) then
				local angle = math.atan2(dz, dx)
				local r = radius * (1 + a1 * math.sin(2 * angle + p1) + a2 * math.sin(3 * angle + p2))
				ok = dx * dx + dz * dz <= r * r
			end
			if ok then
				for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
					if height(qx + d[1], qz + d[2]) < h then
						ok = false
						break
					end
				end
			end
			if not ok then
				continue
			end
			table.insert(accepted, qx)
			table.insert(accepted, qz)
			for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
				local nx, nz = qx + d[1], qz + d[2]
				local k = (nx - sx + 64) * 256 + (nz - sz + 64)
				if not seen[k] then
					seen[k] = true
					table.insert(list, nx)
					table.insert(list, nz)
				end
			end
		end
		local count = #accepted // 2
		if count < minCells then
			return nil
		end
		-- (A big flat floor stops the flood at Size[2] columns, the nearest in flooding order.)
		count = math.min(count, maxCells)
		local x0, z0, x1, z1 = huge, huge, -huge, -huge
		for i = 1, count * 2, 2 do
			local px, pz = accepted[i], accepted[i + 1]
			x0, z0 = math.min(x0, px), math.min(z0, pz)
			x1, z1 = math.max(x1, px), math.max(z1, pz)
		end
		-- No water by snow or ice: every column around it is of a biome where water doesn't freeze.
		for qz = z0 - 1, z1 + 1 do
			for qx = x0 - 1, x1 + 1 do
				if freezes[terrain.biome(qx, qz)] then
					return nil
				end
			end
		end
		local m = PUDDLE_MARGIN
		if not terrain.free(x0 - m, z0 - m, x1 + m, z1 + m) or #lakes(x0 - m, z0 - m, x1 + m, z1 + m) > 0 then
			return nil
		end
		-- (Last: it builds the surface caves' worms around.)
		if terrain.carvesTop then
			for i = 1, count * 2, 2 do
				if terrain.carvesTop(accepted[i], accepted[i + 1]) then
					return nil
				end
			end
		end
		local w = x1 - x0 + 1
		local mask = buffer.create(w * (z1 - z0 + 1))
		for i = 1, count * 2, 2 do
			writeu8(mask, (accepted[i + 1] - z0) * w + accepted[i] - x0, 1)
		end
		return table.freeze({
			x0 = x0,
			z0 = z0,
			x1 = x1,
			z1 = z1,
			y = h - 1,
			mask = mask,
			cells = count,
			biome = biome,
		})
	end
	local puddleAt: (cx: number, cz: number) -> Puddle? = cache(decidePuddle)

	local function puddles(minX: number, minZ: number, maxX: number, maxZ: number, yield: (() -> ())?): { Puddle }
		local list: { Puddle } = {}
		for cz = (minZ - puddleReach) // spacing, (maxZ + puddleReach) // spacing do
			for cx = (minX - puddleReach) // spacing, (maxX + puddleReach) // spacing do
				local puddle: Puddle? = puddleAt(cx, cz)
				if yield then
					yield()
				end
				if
					puddle
					and puddle.x0 - PUDDLE_MARGIN <= maxX
					and puddle.x1 + PUDDLE_MARGIN >= minX
					and puddle.z0 - PUDDLE_MARGIN <= maxZ
					and puddle.z1 + PUDDLE_MARGIN >= minZ
				then
					table.insert(list, puddle)
				end
			end
		end
		return list
	end

	-- Is the lake's cell (x, y, z) of the box water (a lake cell below SURFACE_LAYER)?
	local function wetCell(shape: buffer, x: number, y: number, z: number): boolean
		return x >= 0
			and z >= 0
			and x < BOX
			and z < BOX
			and y >= 0
			and y < SURFACE_LAYER
			and readu8(shape, cellIndex(x, y, z)) == LAKE
	end

	-- Is the lake's cell (x, y, z) of the box a shell cell beside or under its water?
	local function wetShell(shape: buffer, x: number, y: number, z: number): boolean
		return y >= 0
			and y < SURFACE_LAYER
			and readu8(shape, cellIndex(x, y, z)) ~= LAKE
			and (
				wetCell(shape, x + 1, y, z)
				or wetCell(shape, x - 1, y, z)
				or wetCell(shape, x, y, z + 1)
				or wetCell(shape, x, y, z - 1)
				or wetCell(shape, x, y + 1, z)
			)
	end

	local function write(
		lakeList: { Lake },
		puddleList: { Puddle },
		data: buffer,
		level: number,
		originX: number,
		originZ: number,
		cells: number,
		topCells: { number }
	): (number, number)
		local lowest, highest = huge, -1
		local step = ChunkLayout.steps(level)
		local half = step // 2
		local minX, minZ = originX - step, originZ - step
		for _, lake in lakeList do
			local shape, base = lake.shape, lake.y
			local top = if lake.frozen then ICE else WATER
			if level == 0 then
				local xa, xb = math.max(lake.x, minX), math.min(lake.x + BOX - 1, minX + P - 1)
				local za, zb = math.max(lake.z, minZ), math.min(lake.z + BOX - 1, minZ + P - 1)
				for wz = za, zb do
					local pz = wz - minZ
					local lz = wz - lake.z
					for wx = xa, xb do
						local px = wx - minX
						local lx = wx - lake.x
						local col = pz * P + px
						local was = if topCells[col + 1] >= 1 and topCells[col + 1] < cells
							then readu16(data, (topCells[col + 1] * LAYER + col) * 2)
							else AIR
						local dug, air = huge, huge
						for y = 0, LAYERS - 1 do
							local v = readu8(shape, cellIndex(lx, y, lz))
							local wy = base + y
							if v == OUT or wy < 1 or wy >= cells then
								continue
							end
							local o = (wy * LAYER + col) * 2
							local block = readu16(data, o)
							if v == LAKE then
								if block == BEDROCK then
									continue
								end
								local new = if y >= SURFACE_LAYER
									then AIR
									elseif y == SURFACE_LAYER - 1 then top
									else WATER
								if block ~= new then
									writeu16(data, o, new)
									dug = math.min(dug, wy)
									if new == AIR then
										air = math.min(air, wy)
									elseif wy > highest then
										highest = wy
									end
								end
							elseif
								SOIL[block]
								and wetShell(shape, lx, y, lz)
								and not (GRASSY[block] and not wetCell(shape, lx, y + 1, lz))
							then
								-- Soil under or beside the water: the lake's floor (dirt where water
								-- lies under it too, so no sand or gravel would fall). A top beside
								-- the water with the sky above it stays: grass by the water's edge.
								local floor = Lakes.floorAt(lake, wx, wz)
								if y > 0 and readu8(shape, cellIndex(lx, y - 1, lz)) == LAKE then
									floor = DIRT
								end
								if block ~= floor then
									writeu16(data, o, floor)
								end
							elseif
								GRASSY[block]
								and not lake.frozen
								and wy > 1
								and wetShell(shape, lx, y, lz)
								and not wetCell(shape, lx, y + 1, lz)
							then
								-- The shore: a top at the water's edge, in sand or gravel patches,
								-- on ground only (sand never hangs over air or water).
								local shore = Lakes.shoreAt(lake, wx, wz)
								local below = readu16(data, o - LAYER * 2)
								if shore and below ~= AIR and Blocks.isOpaque(below) then
									writeu16(data, o, shore)
								end
							end
						end
						-- The dirt the bowl uncovers above the water grows the column's top back.
						-- (Beside the water too, when the lake's floor is dirt.)
						if air < huge and GRASSY[was] and air - 1 >= 1 then
							local o = ((air - 1) * LAYER + col) * 2
							if readu16(data, o) == DIRT then
								writeu16(data, o, was)
							end
						end
						if dug <= topCells[col + 1] then
							topCells[col + 1] = dug - 1
						end
						if dug < lowest then
							lowest = dug
						end
					end
				end
			else
				-- Point-sampled: water (ice) in the top cell of a column whose sample block lies over
				-- the lake's water.
				for pz = 0, P - 1 do
					local lz = minZ + pz * step + half - lake.z
					if lz < 0 or lz >= BOX then
						continue
					end
					for px = 0, P - 1 do
						local lx = minX + px * step + half - lake.x
						if lx < 0 or lx >= BOX or not Lakes.wet(lake, lake.x + lx, lake.z + lz) then
							continue
						end
						local col = pz * P + px
						local cell = topCells[col + 1]
						if cell >= 1 and cell < cells then
							writeu16(data, (cell * LAYER + col) * 2, top)
							topCells[col + 1] = cell - 1
							lowest = math.min(lowest, cell)
							highest = math.max(highest, cell)
						end
					end
				end
			end
		end
		if level == 0 then
			for _, puddle in puddleList do
				local wy = puddle.y
				if wy < 1 or wy >= cells then
					continue
				end
				local w = puddle.x1 - puddle.x0 + 1
				for wz = math.max(puddle.z0, minZ), math.min(puddle.z1, minZ + P - 1) do
					for wx = math.max(puddle.x0, minX), math.min(puddle.x1, minX + P - 1) do
						if readu8(puddle.mask, (wz - puddle.z0) * w + wx - puddle.x0) == 0 then
							continue
						end
						local col = (wz - minZ) * P + wx - minX
						local o = (wy * LAYER + col) * 2
						if readu8(Blocks.cullLut, readu16(data, o)) ~= 1 then
							continue -- (only ever in place of the ground's top block)
						end
						writeu16(data, o, WATER)
						if wy <= topCells[col + 1] then
							topCells[col + 1] = wy - 1
						end
						lowest = math.min(lowest, wy)
						highest = math.max(highest, wy)
					end
				end
			end
		end
		return lowest, highest + 1
	end

	return {
		lakes = lakes,
		puddles = puddles,
		write = write,
	}
end

return Lakes
