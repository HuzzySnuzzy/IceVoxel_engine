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
]]

local Blocks = require(script.Parent.Parent.Blocks)
local ChunkLayout = require(script.Parent.Parent.World.ChunkLayout)
local Hash = require(script.Parent.Parent.Util.Hash)

local SIZE = ChunkLayout.SIZE
local P = ChunkLayout.PADDED
local readu16 = buffer.readu16
local writeu16 = buffer.writeu16

-- `veins` per 128 blocks of the height range [minY, maxY] that the chunk has; `size` random-walk steps.
type Ore = { block: number, veins: number, size: number, minY: number, maxY: number }

local ORES: { Ore } = {
	{ block = Blocks.id.Diorite, veins = 1.5, size = 40, minY = 5, maxY = 200 },
	{ block = Blocks.id.Andesite, veins = 1.5, size = 40, minY = 200, maxY = 370 },
	{ block = Blocks.id.Granite, veins = 1.5, size = 40, minY = 370, maxY = 540 },
	{ block = Blocks.id.CoalOre, veins = 12, size = 10, minY = 5, maxY = math.huge },
	{ block = Blocks.id.IronOre, veins = 7, size = 7, minY = 5, maxY = math.huge },
	{ block = Blocks.id.GoldOre, veins = 3, size = 6, minY = 48, maxY = math.huge },
	{ block = Blocks.id.DiamondOre, veins = 4, size = 5, minY = 5, maxY = 30 },
	{ block = Blocks.id.EmeraldOre, veins = 4, size = 3, minY = 600, maxY = math.huge },
}

local Ores = {}

function Ores.place(data: buffer, seed: number, cx: number, cz: number, heightCells: number)
	local stone = Blocks.id.Stone
	local rng = Hash.rng(Hash.hash3(seed, cx, 0x0E5, cz))

	for _, ore in ORES do
		local maxY = math.min(ore.maxY, heightCells - 1)
		-- Expected vein count for the range this chunk has; the fraction is a last vein's chance.
		local expected = if maxY > ore.minY then ore.veins * (maxY - ore.minY) / 128 else 0
		local count = math.floor(expected)
		if rng:float() < expected - count then
			count += 1
		end
		for _ = 1, count do
			local x = rng:int(0, SIZE - 1)
			local y = rng:int(ore.minY, maxY)
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
