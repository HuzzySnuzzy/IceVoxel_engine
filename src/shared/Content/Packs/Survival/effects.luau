--!strict
--[[
	Tough As Nails' status effects (its MobEffects in TAN 1.20; Content/Schema's EFFECT_FIELDS,
	Shared/Effects): each one `external`, its state kept by Shared/ToughAsNails' (thirst and
	temperature) and read through server Players/ToughAsNails' adapters (Players/Effects
	`addExternal`), so the HUD lists them with the rest. Dirty water and crackers bring Thirst,
	the teas Internal Warmth and Chill.
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

return {
	{
		name = "Thirst",
		command = "thirst",
		color = { 112, 160, 64 },
		category = "harmful",
		icon = "drop",
		external = true,
	},
	{
		name = "InternalWarmth",
		command = "internal_warmth",
		color = { 235, 120, 40 },
		category = "beneficial",
		icon = "flame",
		external = true,
	},
	{
		name = "InternalChill",
		command = "internal_chill",
		color = { 150, 210, 255 },
		category = "beneficial",
		icon = "snowflake",
		external = true,
	},
	{
		name = "ClimateClemency",
		command = "climate_clemency",
		color = { 236, 200, 92 },
		category = "beneficial",
		icon = "shield",
		external = true,
	},
} :: { Schema.EffectSpec }
