--!strict
--!native
--[[
	Ground plants: Minecraft 1.20.1's vegetal decoration (short and tall grass, ferns, dead bushes,
	flowers, tall flowers, mushrooms), grown by each biome's `foliage` (Biomes/BiomeList).

	TerrainGenerator runs it after structures, in full detail chunks only: LOD cells are 2+ blocks
	wide and small plants would vanish in them (and every box of a plant is a Part).

	Every padded column is decided on its own, from the seed, its world (x, z) and its own blocks,
	so a column in a chunk's padding gets exactly the plant its neighbour's core gets:
	  1. the surface is the column's top cell from the fill step; it must be ground (the dead
	     bush's soil set: Minecraft's dirt tag and sand) and in the plant's soil set
	     (Blocks.mayPlaceOn), and the cell above must be air: a trunk, leaves, a cactus, water or
	     ice there means no plant. (Mushrooms, which may stand on any sturdy block, therefore only
	     grow on that ground too: none on beach gravel or bare rock.)
	  2. a per-column hash (`columnHash`) is rolled against the biome's chances. Flowers take the
	     bottom of the roll's range, other plants the part above it and herbs (Tough As Nails'
	     mint and wild ginger) the part above that, so a column grows one of them at most (and a
	     biome given herbs keeps its grass and flowers where they were). Each chance is the
	     biome's average divided by the share of the ground in patches, times a patch noise ramp:
	     low-frequency noise (Noise.fbm2) above a threshold makes patches, below it clearings,
	     and the ramp between fades their edges, like Minecraft's random patch features. Flowers
	     and herbs have their own patch noises (the herbs' smaller and rarer).
	  3. other plants are picked by weight from the same hash; a flower's species follows a third,
	     lower-frequency noise (made uniform, with a little per-column jitter), so a flower patch
	     is one or two species, like Minecraft's noise-based flower providers.
	  4. a tall plant also needs air in the cell above that, inside the buffer, for its top half;
	     otherwise tall grass becomes short grass, a large fern a fern, and a tall flower nothing.
	The place function returns one above the highest cell it wrote (0: none), which `generate`
	raises `emptyAbove` to.
]]

local Blocks = require(script.Parent.Parent.Blocks)
local Biomes = require(script.Parent.Parent.Biomes)
local ChunkLayout = require(script.Parent.Parent.World.ChunkLayout)
local Hash = require(script.Parent.Parent.Util.Hash)
local Noise = require(script.Parent.Noise)

local P = ChunkLayout.PADDED
local STRIDE = ChunkLayout.LAYER * 2
local AIR = Blocks.AIR

-- Tuning --------------------------------------------------------------------------------------------
local PATCH_FREQUENCY = 1 / 24 -- grass and fern patches and the clearings between them
local FLOWER_FREQUENCY = 1 / 20 -- flower patches
local HERB_FREQUENCY = 1 / 16 -- herb patches (small)
local SPECIES_FREQUENCY = 1 / 128 -- which flower grows where (wider than a patch)
local EDGE = 0.25 -- noise width over which a patch fades into a clearing
local SPECIES_JITTER = 0.02 -- per-column noise in the species pick (ragged borders between species)
-- Standard deviation of Noise.fbm2's output.
local NOISE_STD = 1 / 3

local readu16 = buffer.readu16
local writeu16 = buffer.writeu16
local exp = math.exp
local bxor = bit32.bxor
local rshift = bit32.rshift
local id = Blocks.id
local mayPlaceOn = Blocks.mayPlaceOn
local plantTop = Blocks.plantTop

-- Plants grow on this ground only (and each on its own soil set within it).
local GROUND: { [number]: boolean } = {}
for _, name in { "Grass", "DryGrass", "Dirt", "CoarseDirt", "Podzol", "Mycelium", "Sand" } do
	GROUND[id[name]] = true
end

-- A tall plant without room for its top grows as this instead (others: nothing).
local SINGLE_FORM: { [number]: number } = {
	[id.TallGrass] = id.ShortGrass,
	[id.LargeFern] = id.Fern,
}

local Foliage = {}

Foliage.GROUND = GROUND
Foliage.SINGLE_FORM = SINGLE_FORM

--[[
	The patch noise ramp: 0 in clearings, 1 in patches, rising over EDGE around `threshold`. The
	threshold leaves `cover` of the ground in patches (normal quantile of the noise, logistic
	approximation); cover 1 means no clearings at all (nil threshold).
]]
local function thresholdFor(cover: number): number?
	if cover >= 0.999 then
		return nil
	end
	local c = math.max(cover, 1e-3)
	return math.log((1 - c) / c) / 1.702 * NOISE_STD
end

local function ramp(n: number, threshold: number): number
	local m = (n - threshold) / EDGE + 0.5
	return if m <= 0 then 0 elseif m >= 1 then 1 else m
end

-- Average of the ramp over the noise (normally distributed), so chances can be scaled to keep the
-- biome's average.
local function meanRamp(threshold: number?): number
	if threshold == nil then
		return 1
	end
	local sum, weight = 0, 0
	local steps = 600
	for i = 0, steps do
		local n = (i / steps * 2 - 1) * 6 * NOISE_STD
		local w = exp(-0.5 * (n / NOISE_STD) ^ 2)
		sum += ramp(n, threshold) * w
		weight += w
	end
	return sum / weight
end

-- Is `soil` ground that some plant of the biome could grow on? (The soil columns of its budget.)
local soilOf: { { [number]: boolean } } = {}
-- Per biome: peak chances (in patches) and patch thresholds of plants, flowers and herbs.
local plantPeak: { number }, plantThreshold: { number? } = {}, {}
local flowerPeak: { number }, flowerThreshold: { number? } = {}, {}
local herbPeak: { number }, herbThreshold: { number? } = {}, {}
for index, biome in Biomes.list do
	local foliage = biome.foliage
	local soil: { [number]: boolean } = {}
	soilOf[index] = soil
	plantPeak[index], flowerPeak[index], herbPeak[index] = 0, 0, 0
	if foliage then
		for ground in GROUND do
			for _, plant in foliage.plants.blocks do
				soil[ground] = soil[ground] or mayPlaceOn(plant, ground)
			end
			if foliage.flowers then
				for _, flower in foliage.flowers.blocks do
					soil[ground] = soil[ground] or mayPlaceOn(flower, ground)
				end
			end
			if foliage.herbs then
				for _, herb in foliage.herbs.blocks do
					soil[ground] = soil[ground] or mayPlaceOn(herb, ground)
				end
			end
		end
		local t = thresholdFor(foliage.cover)
		plantThreshold[index] = t
		plantPeak[index] = math.min(1, foliage.density / meanRamp(t))
		local tf = thresholdFor(foliage.flowerCover)
		flowerThreshold[index] = tf
		flowerPeak[index] = if foliage.flowers then math.min(1, foliage.flowerChance / meanRamp(tf)) else 0
		local th = thresholdFor(foliage.herbCover)
		herbThreshold[index] = th
		herbPeak[index] = if foliage.herbs then math.min(1, foliage.herbChance / meanRamp(th)) else 0
		assert(
			plantPeak[index] + flowerPeak[index] + herbPeak[index] <= 1,
			`Biome {biome.name}'s foliage is too dense for its patches`
		)
	end
end

-- May a plant of biome `biome` grow on `block` (ground in one of its plants' soil sets)?
function Foliage.isSoil(biome: number, block: number): boolean
	return soilOf[biome][block] == true
end

--[[
	A column's u32 hash: its position folded into 32 bits by two odd multipliers below 2^26
	(exact for |x|, |z| < 2^26), then MurmurHash3's finaliser with the salt, its products split in
	16-bit halves so they stay exact. Inlined: on open ground, hashing is most of foliage's cost.
]]
local function columnHash(salt: number, x: number, z: number): number
	local h = bxor(salt, (x * 0x3243F6B + z * 0x2B7E151) % 4294967296)
	h = bxor(h, rshift(h, 16))
	h = ((h % 65536) * 0x85EBCA6B + (h // 65536) * 0xCA6B % 65536 * 65536) % 4294967296
	h = bxor(h, rshift(h, 13))
	h = ((h % 65536) * 0xC2B2AE35 + (h // 65536) * 0xAE35 % 65536 * 65536) % 4294967296
	return bxor(h, rshift(h, 16))
end

local function pick(list: Biomes.PlantList, u: number): number
	local roll = u * list.total
	local weights = list.weights
	for i, block in list.blocks do
		roll -= weights[i]
		if roll < 0 then
			return block
		end
	end
	return list.blocks[#list.blocks]
end

--[[
	Grows the plants of every padded column of a full detail chunk. `data` / `cells`: the chunk's
	buffer and cells per column; (originX, originZ): world position of its first core column;
	`biomes` / `topCells`: per padded column (index pz * PADDED + px + 1), its biome index and
	surface cell. Returns one above the highest cell written (0 when none).
]]
export type Placer = (
	data: buffer,
	cells: number,
	originX: number,
	originZ: number,
	biomes: { number },
	topCells: { number }
) -> number

function Foliage.new(seed: number): Placer
	local patches = Noise.fbm2(seed, "foliage.patches", PATCH_FREQUENCY, 2)
	local flowerPatches = Noise.fbm2(seed, "foliage.flowerPatches", FLOWER_FREQUENCY, 2)
	local species = Noise.fbm2(seed, "foliage.species", SPECIES_FREQUENCY, 2)
	local herbPatches = Noise.fbm2(seed, "foliage.herbPatches", HERB_FREQUENCY, 2)
	local salt = Hash.hash2(seed, Hash.string("foliage.columns"), 0xF01A)
	local list = Biomes.list

	return function(
		data: buffer,
		cells: number,
		originX: number,
		originZ: number,
		biomes: { number },
		topCells: { number }
	): number
		local highest = -1
		for pz = 0, P - 1 do
			local wz = originZ + pz - 1
			for px = 0, P - 1 do
				local i = pz * P + px + 1
				local b = biomes[i]
				local foliage = list[b].foliage
				local y = topCells[i] + 1 -- the plant's cell
				if foliage == nil or y < 1 or y >= cells then
					continue
				end
				local base = (pz * P + px) * 2
				local surface = readu16(data, base + (y - 1) * STRIDE)
				if not soilOf[b][surface] or readu16(data, base + y * STRIDE) ~= AIR then
					continue
				end

				local wx = originX + px - 1
				local h = columnHash(salt, wx, wz)
				local roll = (h % 65536) / 65536
				local fPeak = flowerPeak[b]
				local block
				if roll < fPeak then
					local t = flowerThreshold[b]
					local flowers = foliage.flowers
					if flowers and roll < fPeak * (if t then ramp(flowerPatches(wx, wz), t) else 1) then
						-- The species noise made uniform (logistic approximation of its normal CDF).
						local u = 1 / (1 + exp(-1.702 / NOISE_STD * species(wx, wz)))
						u += ((h // 65536) / 65536 - 0.5) * SPECIES_JITTER
						block = pick(flowers, math.clamp(u, 0, 0.99999))
					end
				elseif roll < fPeak + plantPeak[b] then
					local t = plantThreshold[b]
					if roll - fPeak < plantPeak[b] * (if t then ramp(patches(wx, wz), t) else 1) then
						block = pick(foliage.plants, (h // 65536) / 65536)
					end
				elseif roll < fPeak + plantPeak[b] + herbPeak[b] then
					local t = herbThreshold[b]
					local herbs = foliage.herbs
					local above = roll - fPeak - plantPeak[b]
					if herbs and above < herbPeak[b] * (if t then ramp(herbPatches(wx, wz), t) else 1) then
						block = pick(herbs, (h // 65536) / 65536)
					end
				end
				if block == nil or not mayPlaceOn(block, surface) then
					continue
				end

				local top = plantTop(block)
				if top and (y + 1 >= cells or readu16(data, base + (y + 1) * STRIDE) ~= AIR) then
					-- No room for the top half.
					block, top = SINGLE_FORM[block], nil
					if block == nil then
						continue
					end
				end
				writeu16(data, base + y * STRIDE, block)
				local written = y
				if top then
					writeu16(data, base + (y + 1) * STRIDE, top)
					written = y + 1
				end
				if written > highest then
					highest = written
				end
			end
		end
		return highest + 1
	end
end

return Foliage
