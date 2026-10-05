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
	So osmium is about as common as iron below y 197 (1.0 times as many ore blocks over that band:
	about 1.3 to 1.4 times around y 50 .. 150, 0.6 near bedrock) and about half as common higher up
	(0.5 to 0.6 times), as Minecraft's iron outnumbers Mekanism's osmium in the mountains.

	Each ore draws from one random stream per chunk, in ORES order, so new ores go at the end of the
	list: an ore placed earlier never moves, and a later one only replaces the stone left over.
]]

local Blocks = require(script.Parent.Parent.Blocks)
local ChunkLayout = require(script.Parent.Parent.World.ChunkLayout)
local Hash = require(script.Parent.Parent.Util.Hash)

local SIZE = ChunkLayout.SIZE
local P = ChunkLayout.PADDED
local readu16 = buffer.readu16
local writeu16 = buffer.writeu16

--[[
	One ore feature. `veins` per 128 blocks of the height range [minY, maxY], `size` random-walk
	steps. Uniform ores (the default) start their veins anywhere in the part of the range the chunk
	has. `shape = "trapezoid"` starts them at Minecraft's TrapezoidHeight over the whole range
	(densest in the middle, flat for `plateau` blocks there), with the same number of veins in
	every chunk; veins above the chunk's top find no stone. Its maxY must be finite.
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
}

local ORES: { Ore } = {
	{ name = "diorite", block = Blocks.id.Diorite, veins = 1.5, size = 40, minY = 5, maxY = 200 },
	{ name = "andesite", block = Blocks.id.Andesite, veins = 1.5, size = 40, minY = 200, maxY = 370 },
	{ name = "granite", block = Blocks.id.Granite, veins = 1.5, size = 40, minY = 370, maxY = 540 },
	{ name = "coal", block = Blocks.id.CoalOre, veins = 12, size = 10, minY = 5, maxY = math.huge },
	{ name = "iron", block = Blocks.id.IronOre, veins = 7, size = 7, minY = 5, maxY = math.huge },
	{ name = "gold", block = Blocks.id.GoldOre, veins = 3, size = 6, minY = 48, maxY = math.huge },
	{ name = "diamond", block = Blocks.id.DiamondOre, veins = 4, size = 5, minY = 5, maxY = 30 },
	{ name = "emerald", block = Blocks.id.EmeraldOre, veins = 4, size = 3, minY = 600, maxY = math.huge },
	-- Mekanism's osmium (see the top). The middle feature's 4 per 128 blocks over its 192 are
	-- Mekanism's 6 veins per chunk.
	{ name = "osmium_small", block = Blocks.id.OsmiumOre, veins = 3, size = 4, minY = 5, maxY = math.huge },
	{
		name = "osmium_middle",
		block = Blocks.id.OsmiumOre,
		veins = 4,
		size = 9,
		minY = 5,
		maxY = 197,
		shape = "trapezoid",
	},
	{ name = "osmium_upper", block = Blocks.id.OsmiumOre, veins = 2, size = 7, minY = 197, maxY = math.huge },
}
for _, ore in ORES do
	assert(ore.minY < ore.maxY, `Ores: empty height range of {ore.name}`)
	assert(ore.shape == nil or (ore.shape == "trapezoid" and ore.maxY < math.huge), `Ores: bad shape of {ore.name}`)
	table.freeze(ore)
end

local Ores = {}

-- Every feature, in placement order (read-only): what tests and docs check the numbers against.
Ores.FEATURES = table.freeze(ORES)

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

--[[
	Places every feature's veins into the padded chunk `data` (`heightCells` cells tall) of chunk
	(cx, cz). Deterministic: the same seed and chunk always give the same ores.
]]
function Ores.place(data: buffer, seed: number, cx: number, cz: number, heightCells: number)
	local stone = Blocks.id.Stone
	local rng = Hash.rng(Hash.hash3(seed, cx, 0x0E5, cz))

	for _, ore in ORES do
		local trapezoid = ore.shape == "trapezoid"
		-- A trapezoid draws over its whole range; a uniform ore only over the part the chunk has.
		local maxY = if trapezoid then ore.maxY else math.min(ore.maxY, heightCells - 1)
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
			for _ = 1, ore.size do
				if x >= 0 and x < SIZE and z >= 0 and z < SIZE and y > 0 and y < heightCells then
					local offset = ((y * P + z + 1) * P + x + 1) * 2
					if readu16(data, offset) == stone then
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

return Ores
