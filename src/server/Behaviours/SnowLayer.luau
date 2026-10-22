--!strict
--[[
	Snow layers (BlockList SnowLayer1 .. SnowLayer8, Shared/Seasons/SnowLayers; Minecraft's
	SnowLayerBlock.updateShape): a layer whose support goes (Shared/Seasons/SnowLayers.supports:
	the block below no longer holds snow) vanishes without drops. Stub until the snow lands: it
	reacts to nothing (no ticks are scheduled).
]]

local SnowLayer = {}

-- (A neighbour change schedules nothing yet; see the header.)
function SnowLayer.onNeighborChanged(_world: any, _ticker: any, _x: number, _y: number, _z: number, _block: number) end

return SnowLayer
