--!strict
--[[
	Wooden doors opening and closing (DoorBlock.playSound: BlockSetType's door sounds, volume 1,
	pitch 0.9 to 1). The player using one hears it at once (Blocks/Doors predicts the door); a
	double door plays once. Swap them for real recordings in SoundService.IceVoxelSounds.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

type SoundSpec = Schema.SoundSpec

return function(define: Define.Context): { SoundSpec }
	local SHIPPED = define.SHIPPED
	return {
		{
			name = "block.wooden_door.open",
			id = SHIPPED.GET_UP,
			volume = 0.7,
			pitch = 0.8,
			pitchVariance = 0.05,
			source = "blocks",
			side = "predicted",
		},
		{
			name = "block.wooden_door.close",
			id = SHIPPED.LAND,
			volume = 0.8,
			pitch = 0.85,
			pitchVariance = 0.05,
			source = "blocks",
			side = "predicted",
		},
	}
end
