--!strict
--[[
	Oil and fuel on the skin (Content/Schema's EFFECT_FIELDS; Shared/Effects): the effects this
	pack's fluids give (Shared/Fluids/FluidList `effects`). Crude oil coats the skin: slower and
	flammable; petrol soaks it: it catches at once and burns far longer. Water washes both off.
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

return {
	{
		name = "OilCoated",
		command = "oil_coated",
		color = { 66, 58, 76 },
		category = "harmful",
		icon = "drop",
		speed = -0.15,
		burnFactor = 2,
		burnBonus = 1,
		washOff = true,
	},
	{
		name = "FuelSoaked",
		command = "fuel_soaked",
		color = { 232, 172, 44 },
		category = "harmful",
		icon = "drop",
		burnFactor = 3,
		ignites = true,
		washOff = true,
	},
} :: { Schema.EffectSpec }
