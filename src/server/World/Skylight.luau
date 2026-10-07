--!strict
--[[
	Is a cell under the open sky? The server keeps no light levels, so the random ticks that need
	daylight (grass spreading, saplings growing: Minecraft's light 9 or more) ask whether nothing
	opaque stands above the cell up to the top of its chunk (everything higher is air). Fluids,
	leaves, glass and plants let it through. nil when the chunk isn't loaded.

	`clear` is stricter: Minecraft's Level.canSeeSky, the full sky light of 15, which leaves and
	fluids also take away (their light block of 1: 14 under them). Mobs burning in daylight
	(Mobs/MobWorld) ask it, so a zombie in a tree's shade is safe, as in Minecraft; glass and
	plants still let the sun through.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local ChunkLayout = require(Shared.World.ChunkLayout)

local SIZE = ChunkLayout.SIZE

local Skylight = {}

-- Does `block` (not opaque) dim the sky light below it: leaves and fluids?
local function dims(block: number): boolean
	local def = Blocks.get(block)
	return def.behaviour == "Leaves" or def.fluid ~= nil
end
Skylight.dims = dims

local function scan(world: any, x: number, y: number, z: number, strict: boolean): boolean?
	local chunk = world:peekChunk(x // SIZE, z // SIZE)
	if chunk == nil then
		return nil
	end
	for cell = y, chunk.height - 1 do
		local block = world:peekBlock(x, cell, z)
		if block == nil then
			return nil
		elseif Blocks.isOpaque(block) or (strict and dims(block)) then
			return false
		end
	end
	return true
end

function Skylight.open(world: any, x: number, y: number, z: number): boolean?
	return scan(world, x, y, z, false)
end

function Skylight.clear(world: any, x: number, y: number, z: number): boolean?
	return scan(world, x, y, z, true)
end

return Skylight
