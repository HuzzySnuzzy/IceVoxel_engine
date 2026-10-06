--!strict
--[[
	Grass blocks (Grass, DryGrass, Mycelium, Podzol), Minecraft's SpreadingSnowyDirtBlock:

	  Dying    something opaque placed on top turns it into dirt (a tick after it lands, and on a
	           random tick).
	  Spread   on a random tick (World/RandomTicker), grass, dry grass and mycelium under the open
	           sky (the server's stand-in for Minecraft's light 9: World/Skylight) try four times to
	           spread: a random block within one block sideways, three below and one above that is
	           Dirt, with nothing opaque on it and the open sky above it (light 4 in Minecraft),
	           becomes the same kind of grass. Podzol never spreads, as in Minecraft.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)

local Skylight = require(script.Parent.Parent.World.Skylight)

local DIRT = Blocks.id.Dirt
-- The kinds that spread onto dirt (Podzol doesn't).
local SPREADS: { [number]: boolean } = {
	[Blocks.id.Grass] = true,
	[Blocks.id.DryGrass] = true,
	[Blocks.id.Mycelium] = true,
}
-- Tries per random tick (Minecraft's 4).
local TRIES = 4

local Grass = {}

Grass.tickDelay = 20

-- Is something opaque on top of (x, y, z)?
local function covered(world: any, x: number, y: number, z: number): boolean
	local above = world:peekBlock(x, y + 1, z)
	return above ~= nil and Blocks.isOpaque(above)
end

function Grass.onTick(world: any, _ticker: any, x: number, y: number, z: number, _block: number)
	if covered(world, x, y, z) then
		world:setBlock(x, y, z, DIRT)
	end
end

-- Can grass spread onto (x, y, z)? Dirt, nothing opaque or fluid on it, and the open sky above.
function Grass.takes(world: any, x: number, y: number, z: number): boolean
	if world:peekBlock(x, y, z) ~= DIRT then
		return false
	end
	local above = world:peekBlock(x, y + 1, z)
	if above == nil or Blocks.isOpaque(above) or Blocks.get(above).fluid ~= nil then
		return false
	end
	return Skylight.open(world, x, y + 1, z) == true
end

function Grass.onRandomTick(
	world: any,
	_ticker: any,
	x: number,
	y: number,
	z: number,
	block: number,
	random: () -> number
)
	if covered(world, x, y, z) then
		world:setBlock(x, y, z, DIRT)
		return
	end
	if not SPREADS[block] or Skylight.open(world, x, y + 1, z) ~= true then
		return
	end
	for _ = 1, TRIES do
		local tx = x + math.floor(random() * 3) - 1
		local ty = y + math.floor(random() * 5) - 3
		local tz = z + math.floor(random() * 3) - 1
		if Grass.takes(world, tx, ty, tz) then
			world:setBlock(tx, ty, tz, block)
		end
	end
end

return Grass
