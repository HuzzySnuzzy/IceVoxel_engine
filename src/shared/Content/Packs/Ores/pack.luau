--!strict
--[[
	The new ores, a feature in one pack (the worked example of a content pack): copper, lead, zinc
	(brass's other metal) and brass, sulfur and saltpetre (gunpowder's other halves), uranium (the
	Nuke's core, radioactive) and the Hazmat suit. Their blocks, items, recipes, textures and ore
	features are this pack's modules (_metals holds the metals, for Content/Define's `metal`);
	their lore, textures, icons, Ages, knowledge, the Metal Miner's numbers and their radiation are
	fields on their entries. Last of the game's packs (order 700). Its recipes name the Minecraft
	pack's TNT, glass, wool and coals (the Nuke is its block, with TNT).
]]
return {
	order = 700,
	description = "Copper, lead, zinc, brass, sulfur, saltpetre, uranium and the Hazmat suit.",
	requires = { "Core", "Minecraft" },
}
