--!strict
--[[
	The new ores, a feature in one pack (the worked example of a content pack): copper, lead, zinc
	(brass's other metal) and brass, sulfur and saltpetre (gunpowder's other halves), uranium (the
	Nuke's core, radioactive) and the Hazmat suit. Their blocks, items, recipes, textures and ore
	features are this pack's modules; their lore, textures, icons, Ages, knowledge, the Metal Miner's
	numbers and their radiation are fields on their entries. After the Base pack (order 200), so
	their ids come after every other block's and item's.
]]
return {
	order = 200,
	description = "Copper, lead, zinc, brass, sulfur, saltpetre, uranium and the Hazmat suit.",
	requires = { "Core", "Base" },
}
