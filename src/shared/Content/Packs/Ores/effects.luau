--!strict
--[[
	Uranium's status effect (Content/Schema's EFFECT_FIELDS; Shared/Effects): Radiation Sickness.
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

return {
	-- Radiation (Mekanism's, simplified: Shared/Radiation), given from a dose's band by server
	-- Players/Radiation (I at 0.1 Sv, II at 1, III at 10: Config.Radiation.Sickness) and renewed
	-- while the dose holds: a half heart every 300 >> amp ticks (15 s, 7.5 s, 3.75 s), magic
	-- (through armor), and it kills, as Mekanism's radiation does; Minecraft's Hunger and Nausea
	-- come with the higher levels.
	{
		name = "RadiationSickness",
		command = "radiation_sickness",
		color = { 150, 196, 40 },
		category = "harmful",
		icon = "radiation",
		interval = 300,
		damage = 1,
		lethal = true,
	},
} :: { Schema.EffectSpec }
