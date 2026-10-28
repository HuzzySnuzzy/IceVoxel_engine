--!strict
--[[
	Radiation's sound: one click of a Geiger counter (ambient.radiation.click, the fifth data
	sheet's "geiger counter click": heard without an item, a sign of radiation exposure), flat for
	the player exposed alone. Client Audio/Geiger clicks it at random, faster the higher the rate
	(Shared/Radiation: this pack's uranium is the source). The volume tick its fallback should the
	recording fail to load.
]]

local Define = require(script.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Schema)

type SoundSpec = Schema.SoundSpec

return function(define: Define.Context): { SoundSpec }
	return {
		{
			name = "ambient.radiation.click",
			id = "rbxassetid://123303121160543",
			volume = 0.5,
			pitchVariance = 0.05,
			fallback = { id = define.SHIPPED.TICK, pitch = 1.6 },
			source = "ambient",
			ui = true,
			side = "client",
		},
	}
end
