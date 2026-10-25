--!strict
--[[
	The zombie apocalypse's status effects (Content/Schema's EFFECT_FIELDS; Shared/Effects): a
	zombie's hit may open a wound, a bite may infect.
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

return {
	-- The apocalypse's wounds (server Apocalypse/Survival): a zombie's hit may open one. Not
	-- lethal: it stops at 1 half heart (Shared/Effects' `lethal` rule, as Poison's).
	{
		name = "Bleeding",
		command = "bleeding",
		color = { 168, 20, 24 },
		category = "harmful",
		icon = "drop",
		interval = 80,
		damage = 1,
		lethal = false,
	},
	-- A zombie bite's infection, kept by server Apocalypse/Infection (its stages, the cure,
	-- rising as a zombie). Its adapter gives the stage as the amplifier (server Players/Effects).
	{
		name = "Infection",
		command = "infection",
		color = { 92, 128, 52 },
		category = "harmful",
		icon = "skull",
		external = true,
	},
} :: { Schema.EffectSpec }
