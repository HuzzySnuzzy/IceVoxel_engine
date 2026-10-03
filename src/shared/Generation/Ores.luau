--!strict
--!native
--[[
	Ore veins for full detail (LOD 0) chunks.

	Each chunk places a fixed number of small random-walk veins inside its own core. Ores only
	replace stone, and since ore and stone are both opaque, the neighbouring chunks' copies of our
	border cells don't need to know about them.
]]

local Blocks = require(script.Parent.Parent.Blocks)
local ChunkLayout = require(script.Parent.Parent.World.ChunkLayout)
local Hash = require(script.Parent.Parent.Util.Hash)

local SIZE = ChunkLayout.SIZE
local P = ChunkLayout.PADDED
local readu16 = buffer.readu16
local writeu16 = buffer.writeu16

type Ore = { block: number, veins: number, size: number, minY: number, maxY: number }

local ORES: { Ore } = {
	{ block = Blocks.id.CoalOre, veins = 16, size = 10, minY = 5, maxY = 128 },
	{ block = Blocks.id.IronOre, veins = 10, size = 7, minY = 5, maxY = 64 },
	{ block = Blocks.id.GoldOre, veins = 3, size = 6, minY = 5, maxY = 32 },
	{ block = Blocks.id.DiamondOre, veins = 1, size = 5, minY = 5, maxY = 16 },
}

local Ores = {}

function Ores.place(data: buffer, seed: number, cx: number, cz: number, heightCells: number)
	local stone = Blocks.id.Stone
	local rng = Hash.rng(Hash.hash3(seed, cx, 0x0E5, cz))

	for _, ore in ORES do
		local maxY = math.min(ore.maxY, heightCells - 1)
		for _ = 1, ore.veins do
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
