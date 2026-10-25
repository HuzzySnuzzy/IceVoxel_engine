--!strict
--[[
	Terraria's status effect (Content/Schema's EFFECT_FIELDS; Shared/Effects): Mana Sickness.
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

return {
	-- Terraria's Mana Sickness, given by every mana restoring item (5 s each, up to 10 s:
	-- Config.Mana.Sickness*); magic damage is cut by 5% for each second left (Shared/Mana reads
	-- the ticks left, so it has no attribute here).
	{
		name = "ManaSickness",
		displayName = "Mana Sickness",
		command = "mana_sickness",
		color = { 128, 72, 196 },
		category = "harmful",
		icon = "star",
	},
} :: { Schema.EffectSpec }
