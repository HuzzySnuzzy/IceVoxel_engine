--!strict
--[[
	The skill tree's nodes that came with TNT and the Nuke (blocks/fire, items/fire): on the
	knowledge branch's second row, after Core's Prospector (Progression/Skills, Content/Schema's
	SKILL_FIELDS). Neither has a perk: their point is the recipes of the entries naming them,
	`skill = "demolition"` (Gunpowder and TNT) and `skill = "fission"` (the Nuke), locked until
	the node is unlocked as well as their Age.
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

return {
	{
		id = "demolition",
		name = "Demolition",
		description = "Unlocks Gunpowder and TNT",
		row = 2,
		icon = "Tnt",
		age = "industrial",
		cost = 3,
		requires = { "prospector" },
		perk = { kind = "none" },
	},
	{
		id = "fission",
		name = "Fission",
		description = "Unlocks the Nuke",
		row = 2,
		icon = "Nuke",
		age = "atomic",
		cost = 5,
		requires = { "demolition" },
		perk = { kind = "none" },
	},
} :: { Schema.SkillRecord }
