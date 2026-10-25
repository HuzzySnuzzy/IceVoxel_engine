--!strict
--[[
	Survival: Tough As Nails (thirst and body temperature) and the seasons, each feature in the
	pack's modules (blocks/ and items/ are kind folders, the rest single modules; _models holds the
	canteen's and bowl's models, Content/Define the herbs', snow layers', heaters' and doors'
	generators):

	  Tough As Nails
	    water        the Glass Bottle, dirty and purified water bottles, the canteen: items/drinks,
	                 recipes
	    herbs        Mint and Wild Ginger, Mint Leaves and Ginger Root: blocks/herbs, items/herbs,
	                 textures
	    bowls, teas  the Bowl, dirty and purified water bowls, Mint, Ginger and Herbal Tea:
	                 items/drinks, recipes
	    campfire     the Campfire: blocks/campfire, recipes
	    straw        Straw, Straw and Leaf armor: items/gear, recipes
	    thermometer  the Thermometer: items/gear, recipes
	  The seasons
	    snow layers  SnowLayer1 .. 8: blocks/seasons, recipes
	    heaters      the Wood Stove, Oil Heater, Electric Heater, Air Conditioner and Electric Fan:
	                 blocks/seasons, recipes
	    insulation   Insulated Planks, Insulated Glass and the Insulated Door: blocks/seasons,
	                 recipes, textures

	Each entry carries what the registries make of it: its lore, its texture or icon (blank: still
	to make), its Age and fuel, the campfire's warmth (`heats`), the armor's equip sound.

	Calls made here: the Glass Bottle is here (Tough As Nails' water brought it), though the
	Minecraft pack's potions are brewed from its Purified Water Bottle; the Bowl, Minecraft's, came
	with the teas. The Straw that grass drops is the grass's (the Minecraft pack's blocks).
]]
return {
	order = 300,
	description = "Tough As Nails (herbs, water, teas, campfire, straw, thermometer) and the seasons (snow layers, heaters, insulation).",
	requires = { "Core", "Minecraft" },
}
