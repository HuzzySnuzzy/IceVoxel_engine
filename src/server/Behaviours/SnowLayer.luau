--!strict
--[[
	Snow layers (BlockList SnowLayer1 .. SnowLayer8, Shared/Seasons/SnowLayers; Minecraft's
	SnowLayerBlock.updateShape): a layer whose support goes (Shared/Seasons/SnowLayers.supports:
	the block below no longer holds snow: dug out, burnt, a full layer under it melted to fewer)
	vanishes a tick later, without drops or a sound, in every game mode. A neighbour change looks
	at the block below at once and schedules nothing while it holds (snowfall's writes cost no
	block ticks); a block below in a chunk that is not loaded is waited for, not guessed (as in
	Behaviours/Plant), though it is always in the layer's own chunk.

	It goes with an ordinary WorldServer.setBlock: a layer the weather made on the seed's air goes
	back to that air without an edit (the natural map; cave air where the seed made cave air), a
	player's leaves an edit.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local SnowLayers = require(Shared.Seasons.SnowLayers)

local WorldServer = require(script.Parent.Parent.World.WorldServer)

local RETRY_TICKS = 40

local SnowLayer = {}

SnowLayer.tickDelay = 1

--[[
	Does the snow layer at (x, y, z) still lie on something (`getBlock` nil: not loaded)? nil when
	the block below is not loaded.
]]
function SnowLayer.stays(
	getBlock: (x: number, y: number, z: number) -> number?,
	x: number,
	y: number,
	z: number
): boolean?
	local below = getBlock(x, y - 1, z)
	if below == nil then
		return nil
	end
	return SnowLayers.supports(below)
end

-- A neighbour (or the layer itself) changed: a tick to vanish when the support is gone.
function SnowLayer.onNeighborChanged(world: any, ticker: any, x: number, y: number, z: number, _block: number)
	local below = world:peekBlock(x, y - 1, z)
	if below == nil or not SnowLayers.supports(below) then
		ticker:schedule(x, y, z, SnowLayer.tickDelay)
	end
end

function SnowLayer.onTick(world: any, ticker: any, x: number, y: number, z: number, _block: number)
	local stays = SnowLayer.stays(function(bx: number, by: number, bz: number): number?
		return world:peekBlock(bx, by, bz)
	end, x, y, z)
	if stays == nil then
		ticker:schedule(x, y, z, RETRY_TICKS)
	elseif not stays then
		-- (Back to the seed's own air: cave air in a cave mouth.)
		local natural = if world.natural then WorldServer.naturalAt(world, x, y, z) else nil
		world:setBlock(x, y, z, if natural == Blocks.CAVE_AIR then natural else Blocks.AIR)
	end
end

return SnowLayer
