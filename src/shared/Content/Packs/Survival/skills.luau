--!strict
--[[
	The skill tree's survival branch, rows 5 and 6 (Progression/Skills, Content/Schema's
	SKILL_FIELDS): Tough As Nails' perks, thirst draining slower (ToughAsNails/Thirst's rate),
	steps of warmth and cooling as armor gives (server Players/ToughAsNails) and the campfire
	boiling faster (ToughAsNails/Boiling), each drawn with this pack's things. A node costs its
	Age's number of points.
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

return {
	{
		id = "hardy",
		name = "Hardy",
		description = "Thirst drains 10% slower",
		row = 5,
		icon = "PurifiedWaterBottle",
		age = "stone",
		cost = 1,
		perk = { kind = "thirst", factor = 0.9 },
	},
	{
		id = "firekeeper",
		name = "Firekeeper",
		description = "A campfire boils water twice as fast",
		row = 6,
		icon = "Campfire",
		age = "stone",
		cost = 1,
		requires = { "hardy" },
		perk = { kind = "boiling", speed = 2 },
	},
	{
		id = "insulation",
		name = "Insulation",
		description = "A step of warmth and of cooling, as armor",
		row = 5,
		icon = "StrawChestplate",
		age = "iron",
		cost = 2,
		requires = { "hardy" },
		perk = { kind = "insulation", steps = 1 },
	},
	{
		id = "thermoregulation",
		name = "Thermoregulation",
		description = "One more step of warmth and of cooling",
		row = 5,
		icon = "Thermometer",
		age = "electric",
		cost = 4,
		requires = { "insulation" },
		perk = { kind = "insulation", steps = 1 },
	},
	{
		id = "endurance",
		name = "Endurance",
		description = "Thirst drains another 10% slower",
		row = 6,
		icon = "Canteen",
		age = "electric",
		cost = 4,
		requires = { "hardy" },
		perk = { kind = "thirst", factor = 0.9 },
	},
} :: { Schema.SkillRecord }
