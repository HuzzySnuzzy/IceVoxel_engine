--!strict
--[[
	The medical supplies' sounds (their items' `food.sound`, items/supplies; client
	Interaction/Eating plays the user's own as the use starts, the server everyone else's), in place
	of the bites and the burp. Stand-ins:
	  item.bandage.apply   a bandage or poultice wrapped on: a rustle
	  item.medkit.use      a medkit used: a longer rustle
	  item.pills.swallow   pills swallowed: the swim gulp pitched up
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

type SoundSpec = Schema.SoundSpec

return function(define: Define.Context): { SoundSpec }
	local SHIPPED = define.SHIPPED
	return {
		{
			name = "item.bandage.apply",
			id = SHIPPED.GET_UP,
			volume = 0.5,
			pitch = 1.4,
			pitchVariance = 0.1,
			duration = 0.5,
			maxDistance = 16,
			source = "players",
			side = "predicted",
		},
		{
			name = "item.medkit.use",
			id = SHIPPED.GET_UP,
			volume = 0.6,
			pitch = 1.0,
			duration = 0.6,
			maxDistance = 16,
			source = "players",
			side = "predicted",
		},
		{
			name = "item.pills.swallow",
			id = SHIPPED.SWIM,
			volume = 0.4,
			pitch = 1.6,
			duration = 0.3,
			maxDistance = 16,
			source = "players",
			side = "predicted",
		},
	}
end
