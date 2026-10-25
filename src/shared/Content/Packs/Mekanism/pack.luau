--!strict
--[[
	Mekanism (and Mekanism Generators, and BuildCraft's oil made Mekanism's): its features, each in
	the pack's modules (blocks/ is a kind folder, the rest single modules; _models holds the upgrade
	cards' models, Content/Define the transmitters', tanks' and cables' shapes):

	  osmium        Osmium Ore and its blocks, Raw Osmium, the ingot and nugget, their storage and
	                smelting, the ore features: blocks/osmium, items, recipes, textures, ores
	  transmitters  Logistical Transporters, the Restrictive Transporter, Mechanical Pipes, Fluid
	                Tanks and Universal Cables, Basic to Ultimate: blocks/transmitters, recipes
	  the Configurator: items, recipes
	  machines      the Creative Energy Cube, the Heat Generator, the Electric Furnace, the Solar
	                Panel and the Batteries (energy cubes): blocks/machines, recipes
	  upgrade cards the Speed and Energy Upgrades: items, recipes
	  oil and fuel  the Oil and Fuel fluids, CaveOil, the oil and fuel buckets, the Oil Refinery and
	                the Combustion Generator: blocks/oil, items, recipes

	Every entry carries what it says of itself: its lore, its texture or (blank) icon, the Age that
	opens it, osmium's knowledge and the Metal Miner's numbers for Osmium Ore.

	Calls made here: the oil and fuel buckets are BuildCraft's fluids', so they are here with them
	(the Bucket, water's and lava's are Minecraft's); the oil and fuel came with the refinery, so
	they are this pack's though BuildCraft's.
]]
return {
	order = 200,
	description = "Mekanism: osmium, transmitters, tanks, machines, generators, batteries, upgrades, oil and fuel.",
	requires = { "Core", "Minecraft" },
}
