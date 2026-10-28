--!strict
--[[
	The bunkers' steel hatch (the Bunker Hatch's `toggle` sounds, server Players/ToggleUse): low
	thuds opening and shutting, in the category block.bunker_hatch. Stand-ins; a Sound of an
	event's name in SoundService.IceVoxelSounds replaces it.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

type SoundSpec = Schema.SoundSpec

return function(define: Define.Context): { SoundSpec }
	local LAND = define.SHIPPED.LAND
	return {
		{
			name = "block.bunker_hatch.open",
			category = "block.bunker_hatch",
			id = LAND,
			volume = 0.8,
			pitch = 0.55,
			maxDistance = 16,
			source = "blocks",
			side = "server",
		},
		{
			name = "block.bunker_hatch.close",
			category = "block.bunker_hatch",
			id = LAND,
			volume = 0.9,
			pitch = 0.45,
			maxDistance = 16,
			source = "blocks",
			side = "server",
		},
	}
end
