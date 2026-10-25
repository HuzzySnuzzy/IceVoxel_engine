--!strict
--[[
	The Ages, in the order they come in (Progression/Ages says what each opens and how): the Stone
	Age, then Iron, Industrial, Electric and Atomic. `id` is what saves keep and what entries name
	(`age = "iron"`), so an Age may be renamed or one inserted without breaking them. `level` is the
	knowledge level it needs, `milestones` the discoveries (Progression/Knowledge categories: one
	key, or `count` of a category), `reward` the points reaching it gives, `color` its banner's.
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

return {
	{
		id = "stone",
		name = "Stone Age",
		level = 0,
		milestones = {},
		reward = 0,
		color = { 150, 150, 150 },
	},
	{
		id = "iron",
		name = "Iron Age",
		level = 5,
		milestones = {
			{ category = "craft", key = "Furnace", text = "Craft a Furnace" },
			{ category = "smelt", key = "IronIngot", text = "Smelt an Iron Ingot" },
		},
		reward = 50,
		color = { 216, 216, 216 },
	},
	{
		id = "industrial",
		name = "Industrial Age",
		level = 15,
		milestones = {
			{ category = "smelt", key = "OsmiumIngot", text = "Smelt an Osmium Ingot" },
			{ category = "craft", key = "Bucket", text = "Craft a Bucket" },
		},
		reward = 100,
		color = { 196, 140, 80 },
	},
	{
		id = "electric",
		name = "Electric Age",
		level = 25,
		milestones = {
			{ category = "craft", key = "HeatGenerator", text = "Craft a Heat Generator" },
			-- (No biome count: biomes are too large for finding six to be fun.)
		},
		reward = 150,
		color = { 255, 214, 64 },
	},
	{
		id = "atomic",
		name = "Atomic Age",
		level = 40,
		milestones = {
			{ category = "craft", key = "OilRefinery", text = "Craft an Oil Refinery" },
			{ category = "craft", key = "BasicBattery", text = "Craft a Basic Battery" },
		},
		reward = 200,
		color = { 110, 255, 120 },
	},
} :: { Schema.AgeRecord }
