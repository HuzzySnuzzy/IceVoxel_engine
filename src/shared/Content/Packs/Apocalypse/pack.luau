--!strict
--[[
	The zombie apocalypse, in the manner of DayZ: its features, each in the pack's modules (items/
	and loot/ are kind folders, the rest single modules; _shapes holds the barricades' boards,
	_models the cans', bats' and guns' models):

	  cities and roads   asphalt, the road lines, concrete, cracked and mossy bricks, rusty metal:
	                     blocks, recipes, textures
	  scavenging         the Supply Crate and the Medicine Cabinet, and the ruins' loot tables:
	                     blocks, loot/ruins
	  bunkers            barricades, the Bunker Hatch, the Ceiling Lamp (and its cave twin), the
	                     bunkers' loot tables: blocks, recipes, textures, loot/bunkers
	  wounds             Bleeding and a bite's Infection: effects
	  medical            bandages, the medkit, antibiotics, painkillers, the herbal poultice:
	                     items/supplies, recipes (Shared/Items/Foods)
	  DayZ items         rags, duct tape, nails, scrap metal, the ruins' food and drink, bats, the
	                     machete, crowbar and fire axe: items/supplies, recipes
	  weapons            firearms, magazines, ammunition, attachments and melee weapons
	                     (Shared/Weapons' WeaponList holds their numbers): items/weapons, recipes,
	                     sounds/weapons (each class's and recorded calibre's shots: _sounds)
	  zombies            their voices, groans, door bashing, the screamer's shriek and the blood
	                     moon (the mobs are Shared/Entities/MobList's): sounds/zombies; the bunkers'
	                     hatch and the medical supplies' sounds: sounds/bunkers, sounds/medical

	Calls made here: the ruins' and bunkers' loot hold the Terraria pack's Feral Claws (a loot table
	is one pack's); the medical supplies' effects are Shared/Items/Foods' (keyed by name), and the
	zombies are the mobs' (Shared/Entities/MobList).
]]
return {
	order = 500,
	description = "The zombie apocalypse: cities, roads, bunkers, medical supplies, scavenging loot and DayZ weapons.",
	requires = { "Core", "Minecraft", "Survival" },
}
