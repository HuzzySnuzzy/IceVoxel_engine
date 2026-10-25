--!strict
--!native
--[[
	Ore veins and stone varieties for full detail (LOD 0) chunks.

	Each chunk places small random-walk veins inside its own core: per ore, a number of veins
	proportional to the height range it can appear in (columns are up to ~900 blocks tall), so ores
	are as common in a mountain as on a plain. Ores only replace stone, and since ore and stone are
	both opaque, the neighbouring chunks' copies of our border cells don't need to know about them.

	Heights follow JJThunder To The Max, scaled like the terrain: diorite low down, andesite in the
	middle and granite high up in big blobs, coal and iron at any height, gold above the sea floor,
	diamonds near bedrock and emeralds only inside the highest mountains.

	Mekanism's osmium (10.4) has three features in Minecraft 1.20.1, whose world runs from y -64 to
	320 with the sea at 63:

	  feature  per chunk  vein size  heights                  shape
	  upper    65         7          72 .. 343 (24 over top)  trapezoid, plateau 8 (mountains)
	  middle   6          9          -32 .. 56                trapezoid (densest at y 12)
	  small    8          4          -64 (bottom) .. 64       uniform

	This world is 1024 tall with the sea at 64 and keeps Minecraft's ores at any height of rock (iron
	has no mountain bonus), so the features are mapped onto its bands instead of its numbers:
	  * small: small veins (4) in all stone from y 5 up, 3 per 128 blocks of height;
	  * middle: Mekanism's 6 veins of 9 per chunk on a trapezoid over the low band (y 5 .. 197,
	    where diorite is), densest around y 100: "more in the middle";
	  * upper: veins of 7 above it, 2 per 128 blocks: Mekanism's mountain feature, scaled down.
	So osmium is about as common as iron below y 197 (1.1 times as many ore blocks over that band:
	about 1.5 times around y 50 .. 150, 0.5 near bedrock) and about half as common higher up (0.5
	times), as Minecraft's iron outnumbers Mekanism's osmium in the mountains.

	The newer ores are mapped the same way: the low band is Minecraft's ground under the sea (its
	y -64 .. 64 is y 5 .. 197 here, one and a half blocks a block: Minecraft's y becomes
	5 + 1.5 (y + 64)), what lies over its sea goes into the taller hills above, and the per-chunk
	counts and
	vein sizes are kept where they fit (ranges rounded so the counts come out whole). Measured
	over 48 all-stone chunks 448 tall (tests/spec/OreGeneration), in ore blocks against iron's in
	the same band:

	  ore        source (Minecraft 1.20.1)                    here
	  copper     16 a chunk of 10, trapezoid -16 .. 112       the same on a trapezoid over y 48 .. 304
	                                                          (densest around y 176, where the low
	                                                          band meets the andesite): 1.6 times
	                                                          iron over that band, 2.4 times around
	                                                          y 130 .. 230, 0.2 below y 90
	  lead       Mekanism's 8 of 9, trapezoid from 24 below   the same on a trapezoid over y -31 ..
	             the bottom to 64 (densest 52 over it)        197 (densest around y 83): 0.94 times
	                                                          iron below y 197 (0.9 times osmium),
	                                                          1.24 times around y 50 .. 120, none
	                                                          in the mountains
	  zinc       Create's 8 of 12, uniform -63 .. 70          gold's rate instead (brass takes one
	             (0.7 times Minecraft's iron there)           zinc to three copper): veins of 12,
	                                                          uniform over the low band (y 5 ..
	                                                          197): 0.9 times gold over y 48 .. 197,
	                                                          0.31 times iron
	  uranium    Mekanism's small 4 of 4, trapezoid from      a quarter of Mekanism's veins: small
	             the bottom to 8; buried 7 of 9 from 24       over y 5 .. 133, buried over -35 .. 93
	             below the bottom to 56 over it, plateau      (plateau 24: densest at y 17 .. 41),
	             16, 0.75 of its cells next to air dropped    the same 0.75 of the buried cells next
	                                                          to air left as stone: rare (0.6 times
	                                                          iron below y 50, 0.45 below 100; 4
	                                                          times the diamonds), never in the
	                                                          mountains; its cells touch air half
	                                                          as often as lead's

	Two more are not plain veins:
	  * sulfur is volcanic: 3 veins of 8 a chunk in the cave lava's band (y 1 .. 33: caves are lava
	    below Config.Caves.LavaLevel, y 11; 1.9 times iron there), and `Ores.vents` on the stone
	    barrier of every lava lake (on the surface and sunk into cave floors; some 20 blocks a
	    surface lake, 35 an underground one) and in the rock around oil deposits (20 to 30 blocks
	    a small well, 35 to 70 a medium one, 85 to 210 a large one);
	  * saltpetre lies under dry land: 4 veins of 8 a chunk start 4 to 36 blocks under the top
	    block of columns whose biome never rains (BiomeList's precipitation = false: Desert,
	    Savanna, Windswept Savanna) above the sea, some 24 blocks a dry chunk: as many as coal in
	    those layers. It replaces stone only, as every ore: a desert's sandstone is just the 5
	    blocks under its sand (fillerDepth), and keeping "ores only replace stone" keeps
	    CaveDecor's rock rule and every border check that reads an ore as stone true.
	Saltpetre needs each column's surface height and biome (`Ores.place`'s `surface` and
	`biomes`, from TerrainGenerator); without them it draws its numbers and places nothing.

	The features are the content packs' `ores` (Shared/Content: the Minecraft pack's stones and
	ores, the Mekanism pack's osmium, the Ores pack's copper .. uranium), placed in load order.
	Each feature draws from a random stream of its own per chunk, from the seed, its name and the
	chunk, so adding, removing or reordering features (or whole packs) moves no other feature's
	veins. Ores only replace stone, so where two features' veins cross the earlier one keeps the
	cell: a new pack's ores (a pack of a later order) only take the stone left over, and taking a
	feature out only gives its stone to the later ones. The vents draw from a stream per lake and
	per well.
]]

local Config = require(script.Parent.Parent.Config)
local Blocks = require(script.Parent.Parent.Blocks)
local Biomes = require(script.Parent.Parent.Biomes)
local Content = require(script.Parent.Parent.Content)
local ChunkLayout = require(script.Parent.Parent.World.ChunkLayout)
local Hash = require(script.Parent.Parent.Util.Hash)
local Lava = require(script.Parent.Lava)
local OilWells = require(script.Parent.OilWells)

local SIZE = ChunkLayout.SIZE
local P = ChunkLayout.PADDED
local STRIDE = ChunkLayout.LAYER * 2
local SEA = Config.SeaLevel
local readu8 = buffer.readu8
local readu16 = buffer.readu16
local writeu16 = buffer.writeu16

local AIR, CAVE_AIR = Blocks.AIR, Blocks.CAVE_AIR
local STONE, SULFUR = Blocks.id.Stone, Blocks.id.SulfurOre

-- Tuning --------------------------------------------------------------------------------------------
-- Sulfur vents (`Ores.vents`): a vein of LAKE_VEIN steps per LAKE_CELLS cells of a lava lake's
-- stone barrier (at least one), and one of WELL_VEIN steps per WELL_AREA square blocks of an oil
-- deposit's surface (at least one), started one block outside it.
local LAKE_VEIN = 6
local LAKE_CELLS = 16
local WELL_VEIN = 8
local WELL_AREA = 64

-- Salts of the buried rule's per-cell hash and the vents' streams (each feature's stream has its
-- own: FEATURE_SALT, from its name).
local BURIED_SALT = Hash.string("ores.buried")
local LAKE_SALT = Hash.string("ores.vents.lake")
local WELL_SALT = Hash.string("ores.vents.well")

-- Biome indices of dry land: Minecraft's has_precipitation false (deserts and savannas).
local DRY: { boolean } = {}
for i, biome in Biomes.list do
	DRY[i] = not biome.precipitation
end

--[[
	One ore feature. `veins` per 128 blocks of the height range [minY, maxY], `size` random-walk
	steps. Uniform ores (the default) start their veins anywhere in the part of the range the chunk
	has. `shape = "trapezoid"` starts them at Minecraft's TrapezoidHeight over the whole range
	(densest in the middle, flat for `plateau` blocks there), with the same number in every chunk;
	veins above the chunk's top find no stone. Its maxY must be finite.
	`depth`: minY .. maxY count blocks down from each column's top block instead (uniform, the same
	number in every chunk; maxY finite), and a vein only goes where `Ores.place` was told the
	column's surface; `dry`: only under dry land above the sea (DRY). `buried`: the share of the
	vein's cells next to air or cave air left as stone (Minecraft's discardChanceOnAirExposure).
]]
export type Ore = {
	name: string,
	block: number,
	veins: number,
	size: number,
	minY: number,
	maxY: number,
	shape: string?,
	plateau: number?,
	depth: boolean?,
	dry: boolean?,
	buried: number?,
}

-- Every feature: the content packs' `ores` (Shared/Content: the Minecraft pack's stones and ores,
-- the Mekanism pack's osmium, then the Ores pack's), in load order, each block by id.
local ORES: { Ore } = {}
do
	local content = Content.default
	for _, feature in content.ores do
		local block = Blocks.find(feature.block)
		assert(block, `Ores: {content.where("ores", feature.name)} places unknown block {feature.block}`)
		table.insert(ORES, {
			name = feature.name,
			block = block,
			veins = feature.veins,
			size = feature.size,
			minY = feature.minY,
			maxY = feature.maxY,
			shape = feature.shape,
			plateau = feature.plateau,
			depth = feature.depth,
			dry = feature.dry,
			buried = feature.buried,
		})
	end
end
-- Each feature's stream salt, by its name (the packs' ore names are unique).
local FEATURE_SALT: { [string]: number } = {}
for _, ore in ORES do
	assert(FEATURE_SALT[ore.name] == nil, `Ores: two features named {ore.name}`)
	FEATURE_SALT[ore.name] = Hash.string("ores.feature." .. ore.name)
	assert(ore.minY < ore.maxY, `Ores: empty height range of {ore.name}`)
	assert(ore.shape == nil or (ore.shape == "trapezoid" and ore.maxY < math.huge), `Ores: bad shape of {ore.name}`)
	assert(ore.depth == nil or (ore.shape == nil and ore.maxY < math.huge), `Ores: bad depth range of {ore.name}`)
	assert(ore.dry == nil or ore.depth, `Ores: {ore.name} is dry but not under the surface`)
	table.freeze(ore)
end

local Ores = {}

-- Every feature, in placement order (read-only): what tests and docs check the numbers against.
Ores.FEATURES = table.freeze(ORES)
-- Is biome index `biome` dry land (saltpetre's)?
function Ores.isDry(biome: number): boolean
	return DRY[biome] == true
end

--[[
	Minecraft's TrapezoidHeight.sample: a height in [minY, maxY], the sum of two uniform draws, so
	heights near the middle are the most likely (a triangle; `plateau` > 0 flattens its top).
	Draws two numbers from `rng` (one when the plateau covers the range, none when the range is
	empty: then it is `minY`, as Minecraft answers with a warning).
]]
function Ores.trapezoid(rng: Hash.Rng, minY: number, maxY: number, plateau: number?): number
	local range = maxY - minY
	if range < 0 then
		return minY
	end
	local flat = plateau or 0
	if flat >= range then
		return rng:int(minY, maxY)
	end
	local low = (range - flat) // 2
	local high = range - low
	return minY + rng:int(0, high) + rng:int(0, low)
end

-- Is the block at byte `offset` of a padded chunk air or cave air?
local function airAt(data: buffer, offset: number): boolean
	local block = readu16(data, offset)
	return block == AIR or block == CAVE_AIR
end

-- Is core cell `offset` (at height y > 0 of a chunk `cells` tall) next to air or cave air? (The
-- core's neighbours are all in the padded buffer; above the buffer is air.)
local function exposed(data: buffer, offset: number, y: number, cells: number): boolean
	return y + 1 >= cells
		or airAt(data, offset + STRIDE)
		or airAt(data, offset - STRIDE)
		or airAt(data, offset + 2)
		or airAt(data, offset - 2)
		or airAt(data, offset + P * 2)
		or airAt(data, offset - P * 2)
end

--[[
	Places every feature's veins into the padded chunk `data` (`heightCells` cells tall) of chunk
	(cx, cz). Deterministic: the same seed and chunk always give the same ores. `surface` and
	`biomes` (per padded column, at pz * P + px + 1: the height of its first air block and its
	biome index; nil: unknown) are what `depth` and `dry` features need. `features`: only these
	(of FEATURES), in this order (tests; nil: every feature).
]]
function Ores.place(
	data: buffer,
	seed: number,
	cx: number,
	cz: number,
	heightCells: number,
	surface: { number }?,
	biomes: { number }?,
	features: { Ore }?
)
	local stone = STONE
	local buriedSeed = Hash.hash2(seed, BURIED_SALT, 0)
	local originX, originZ = cx * SIZE, cz * SIZE

	for _, ore in features or ORES do
		-- Its own stream: the seed, its name and the chunk (see the header).
		local rng = Hash.rng(Hash.hash3(Hash.hash2(seed, FEATURE_SALT[ore.name], 0), cx, 0x0E5, cz))
		local trapezoid = ore.shape == "trapezoid"
		local depth = ore.depth == true
		local buried = ore.buried
		-- A trapezoid draws over its whole range; a uniform ore only over the part the chunk has.
		local maxY = if trapezoid or depth then ore.maxY else math.min(ore.maxY, heightCells - 1)
		-- Expected vein count for that range; the fraction is a last vein's chance.
		local expected = if maxY > ore.minY then ore.veins * (maxY - ore.minY) / 128 else 0
		local count = math.floor(expected)
		if rng:float() < expected - count then
			count += 1
		end
		for _ = 1, count do
			local x = rng:int(0, SIZE - 1)
			local y = if trapezoid then Ores.trapezoid(rng, ore.minY, maxY, ore.plateau) else rng:int(ore.minY, maxY)
			local z = rng:int(0, SIZE - 1)
			-- A depth feature's vein starts that many blocks under its column's top block, where
			-- the column lets it; elsewhere it only draws its steps.
			local live = true
			if depth then
				local column = (z + 1) * P + x + 2
				local h = if surface then surface[column] else nil
				if h and (not ore.dry or (biomes ~= nil and h > SEA and DRY[biomes[column]])) then
					y = h - 1 - y
				else
					live = false
				end
			end
			for _ = 1, ore.size do
				if live and x >= 0 and x < SIZE and z >= 0 and z < SIZE and y > 0 and y < heightCells then
					local offset = ((y * P + z + 1) * P + x + 1) * 2
					-- (A dry ore's every step stays under dry land above the sea: a vein starting
					-- at a desert's edge ends there instead of running under the tundra beside it.)
					local column = (z + 1) * P + x + 2
					local h = if ore.dry and surface then surface[column] else nil
					if
						readu16(data, offset) == stone
						and (not ore.dry or (h ~= nil and h > SEA and biomes ~= nil and DRY[biomes[column]]))
						and (
							buried == nil
							or not exposed(data, offset, y, heightCells)
							or Hash.float3(buriedSeed, originX + x, y, originZ + z) >= buried
						)
					then
						writeu16(data, offset, ore.block)
					end
				end
				local axis = rng:int(0, 5)
				if axis == 0 then
					x += 1
				elseif axis == 1 then
					x -= 1
				elseif axis == 2 then
					y += 1
				elseif axis == 3 then
					y -= 1
				elseif axis == 4 then
					z += 1
				else
					z -= 1
				end
			end
		end
	end
end

-- A vent's vein: `size` random-walk steps of sulfur from world cell (x, y, z), turning the stone
-- it meets in the core of chunk (originX, originZ) of `data` (`cells` tall) into sulfur. Every
-- chunk walks the same steps (the stream is the lake's or the well's) and writes its own core.
local function vent(
	data: buffer,
	rng: Hash.Rng,
	size: number,
	x: number,
	y: number,
	z: number,
	originX: number,
	originZ: number,
	cells: number
)
	x -= originX
	z -= originZ
	for _ = 1, size do
		if x >= 0 and x < SIZE and z >= 0 and z < SIZE and y > 0 and y < cells then
			local offset = ((y * P + z + 1) * P + x + 1) * 2
			if readu16(data, offset) == STONE then
				writeu16(data, offset, SULFUR)
			end
		end
		local axis = rng:int(0, 5)
		if axis == 0 then
			x += 1
		elseif axis == 1 then
			x -= 1
		elseif axis == 2 then
			y += 1
		elseif axis == 3 then
			y -= 1
		elseif axis == 4 then
			z += 1
		else
			z -= 1
		end
	end
end

-- Box cell indices of a lake's stone barrier (reused).
local barrier: { number } = {}

--[[
	Sulfur vents in the full detail chunk (cx, cz) of `data` (`heightCells` tall), after its ores
	and lava lakes: veins started on the stone barrier of every lava lake in `lakes` (the surface
	lakes near the chunk) and `sunk` (the underground lake just sunk into it), one per LAKE_CELLS
	of its barrier cells, and around every oil deposit of `wells`, one per WELL_AREA square blocks
	of its surface, started one block outside the sphere. Each lake's and well's veins come from
	its own stream, so every chunk walks the same ones and writes its core's part (a vein crosses
	chunk borders unbroken, but for the sunk lake's: only its own chunk knows of it, so its veins
	stop at that chunk's border, as every Ores.place vein does). Only stone becomes sulfur.
]]
function Ores.vents(
	data: buffer,
	seed: number,
	cx: number,
	cz: number,
	heightCells: number,
	lakes: { Lava.Lake }?,
	wells: { OilWells.Well }?,
	sunk: Lava.Lake?
)
	local originX, originZ = cx * SIZE, cz * SIZE
	local x0, z0, x1, z1 = originX, originZ, originX + SIZE - 1, originZ + SIZE - 1

	local function lake(l: Lava.Lake)
		-- No vein reaches the core from a box more than LAKE_VEIN blocks off it.
		local m = LAKE_VEIN
		if l.x > x1 + m or l.x + Lava.BOX - 1 < x0 - m or l.z > z1 + m or l.z + Lava.BOX - 1 < z0 - m then
			return
		end
		table.clear(barrier)
		local shape = l.shape
		for i = 0, buffer.len(shape) - 1 do
			if readu8(shape, i) == Lava.BARRIER then
				table.insert(barrier, i)
			end
		end
		local n = #barrier
		if n == 0 then
			return
		end
		local rng = Hash.rng(Hash.hash3(Hash.hash2(seed, LAKE_SALT, 0), l.x, l.y, l.z))
		for _ = 1, math.max(1, n // LAKE_CELLS) do
			-- (Box cells are at (x * BOX + z) * LAYERS + y.)
			local i = barrier[rng:int(1, n)]
			local ly, column = i % Lava.LAYERS, i // Lava.LAYERS
			local lx, lz = column // Lava.BOX, column % Lava.BOX
			vent(data, rng, LAKE_VEIN, l.x + lx, l.y + ly, l.z + lz, originX, originZ, heightCells)
		end
	end

	if lakes then
		for _, l in lakes do
			lake(l)
		end
	end
	if sunk then
		lake(sunk)
	end
	if wells then
		local wellSeed = Hash.hash2(seed, WELL_SALT, 0)
		for _, well in wells do
			local r = well.radius + 1
			-- A vein's cells lie within r + WELL_VEIN - 1 of the centre.
			local reach = r + WELL_VEIN - 1
			if well.x - reach > x1 or well.x + reach < x0 or well.z - reach > z1 or well.z + reach < z0 then
				continue
			end
			local rng = Hash.rng(Hash.hash3(wellSeed, well.x, well.y, well.z))
			local count = math.max(1, math.floor(4 * math.pi * r * r / WELL_AREA + 0.5))
			for _ = 1, count do
				-- A direction uniform on the sphere (a point of the unit ball, pushed out to it).
				local dx, dy, dz, length = 0, 1, 0, 1
				for _ = 1, 8 do
					local a, b, c = rng:float() * 2 - 1, rng:float() * 2 - 1, rng:float() * 2 - 1
					local l2 = a * a + b * b + c * c
					if l2 > 0.01 and l2 <= 1 then
						dx, dy, dz, length = a, b, c, math.sqrt(l2)
						break
					end
				end
				local s = r / length
				vent(
					data,
					rng,
					WELL_VEIN,
					math.floor(well.x + dx * s + 0.5),
					math.floor(well.y + dy * s + 0.5),
					math.floor(well.z + dz * s + 0.5),
					originX,
					originZ,
					heightCells
				)
			end
		end
	end
end

return Ores
