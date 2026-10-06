--!strict
--[[
	Random block ticks, Minecraft's ServerLevel.tickChunk: every tick, in every chunk near a player,
	each 16 x 16 x 16 section below the chunk's top picks Config.Server.RandomTickSpeed blocks at
	random (3, Minecraft's randomTickSpeed), and a block whose behaviour has `onRandomTick`
	(Behaviours/) gets one: grass spreads (Grass), leaves cut off from their logs decay (Leaves),
	saplings grow (Sapling). So any one block gets a random tick about every 68 seconds.

	Which chunks: World/Simulation's (those within SimulationRadius of a player, loaded). Air and
	cave air are skipped at once; everything above a chunk's top (`height`) is air.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local ChunkLayout = require(Shared.World.ChunkLayout)

local BlockTicker = require(script.Parent.BlockTicker)
local WorldServer = require(script.Parent.WorldServer)

local SIZE = ChunkLayout.SIZE
local P = ChunkLayout.PADDED
local SECTION = 16

export type Random = () -> number

local RandomTicker = {}

-- The behaviours with random ticks, by block id (built once from `behaviours`).
local function randomLut(behaviours: { [number]: BlockTicker.Behaviour }): { [number]: BlockTicker.Behaviour }
	local lut = {}
	for block, behaviour in behaviours do
		if behaviour.onRandomTick then
			lut[block] = behaviour
		end
	end
	return lut
end

export type RandomTicker = {
	ticker: BlockTicker.Ticker,
	world: WorldServer.World,
	ticking: { [number]: BlockTicker.Behaviour },
}

function RandomTicker.new(world: WorldServer.World, ticker: BlockTicker.Ticker): RandomTicker
	return { ticker = ticker, world = world, ticking = randomLut(ticker.behaviours) }
end

--[[
	One tick over `chunks` with `speed` picks per section (default Config.Server.RandomTickSpeed),
	`random` rolling in [0, 1). Returns the number of random ticks given.
]]
function RandomTicker.step(self: RandomTicker, chunks: { WorldServer.Chunk }, speed: number, random: Random): number
	if speed <= 0 then
		return 0
	end
	local ticking = self.ticking
	local world = self.world
	local given = 0
	for _, chunk in chunks do
		local data = chunk.data
		local height = chunk.height
		local baseX, baseZ = chunk.cx * SIZE, chunk.cz * SIZE
		for section = 0, (height - 1) // SECTION do
			for _ = 1, speed do
				local lx = math.floor(random() * SIZE)
				local lz = math.floor(random() * SIZE)
				local y = section * SECTION + math.floor(random() * SECTION)
				if y < height then
					-- (The chunk's buffer read straight: most picks are rock or air.)
					local block = buffer.readu16(data, ((y * P + lz + 1) * P + lx + 1) * 2)
					local behaviour = ticking[block]
					if behaviour and block ~= Blocks.AIR then
						local onRandomTick = behaviour.onRandomTick :: any
						onRandomTick(world, self.ticker, baseX + lx, y, baseZ + lz, block, random)
						given += 1
					end
				end
			end
		end
	end
	return given
end

return RandomTicker
