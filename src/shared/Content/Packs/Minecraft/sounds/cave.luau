--!strict
--[[
	Minecraft's cave mood (client Audio/CaveMood, Audio/Ambience): this stand-in rumble plays only
	while no pack's music has a cave mood; the moods are the pack's music (`set = "mood"`), each the
	event ambient.cave.<name> in this one's category, falling back on its rumble (Shared/Sounds).
	One plays at a time (`limit`).
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

type SoundSpec = Schema.SoundSpec

return function(define: Define.Context): { SoundSpec }
	return {
		{
			name = "ambient.cave",
			id = define.SHIPPED.FALLING,
			volume = 0.25,
			pitch = 0.35,
			pitchVariance = 0.05,
			duration = 6,
			source = "ambient",
			side = "client",
			limit = 1,
		},
	}
end
