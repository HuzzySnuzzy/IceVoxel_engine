--!strict
--[[
	Terraria's things: its features, each in the pack's items and recipes (_models holds the rings'
	and stars' models):

	  accessories  Hermes Boots, Cloud in a Bottle, Shiny Red Balloon, Lucky Horseshoe, Aglet,
	               Anklet of the Wind, the bands of Regeneration and Starpower, Obsidian Skull,
	               Flipper, Cobalt Shield, Feral Claws (Items/Accessories)
	  mana         Fallen Stars (server Players/FallenStars), Mana Crystals, Lesser Mana and Mana
	               Potions (Shared/Mana)
	  magic        the Wand of Sparking, the Emerald Staff and Water Bolt (Shared/Magic)
	  vanity       the Top Hat, Tuxedo Shirt and Tuxedo Pants

	Calls made here: the accessories found in chests are rolled by the Minecraft pack's mineshaft
	loot table (its fourth pool) and the Apocalypse pack's (Feral Claws): a loot table is one
	pack's, so the tables stay whole there and name these items. Their lore, their icons (blank)
	and their Ages are fields on their entries.
]]
return {
	order = 400,
	description = "Terraria: accessories, mana, magic weapons and vanity clothes.",
	requires = { "Core", "Minecraft", "Survival" },
}
