--!strict
--[[
	Everything the game had before content packs, as it was: the blocks, items, recipes, textures,
	loot tables and ore features BlockList, ItemList, Recipes, TexturePack, ScavengeLoot, the
	mineshafts and Generation/Ores held, in their old order (so no id moved). Its features move out
	into packs of their own (Minecraft's, Mekanism's, the seasons'...), entries carrying their own
	lore, textures and numbers instead of the registries' side tables.
]]
return {
	order = 100,
	description = "The game's content from before packs: vanilla, Mekanism, the seasons, the apocalypse, turrets.",
	requires = { "Core" },
}
