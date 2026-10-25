--!strict
--[[
	Turrets and their machines: its features, each in the pack's modules (single modules; _models
	holds the parts' box helper):

	  turrets      the twelve turrets (SMG, rifle and sniper, Basic to Ultimate), their parts
	               (barrels, the belt feeder, receiver, servo motor and targeting module) and the
	               Laser Sight: blocks, items, recipes (Shared/Turrets, Config.Turrets)
	  Metal Miner  blocks, recipes (Machines/MinerRules, Config.Miner)
	  Ammo Press   blocks, recipes (Config.AmmoPress; the servo motor is the turrets' and its)

	Each feature stays behind its Config switch (`Enabled`): its recipes are left out when it is
	off, its blocks and items are always there. Calls made here: the turrets' guns and rounds are
	the Apocalypse pack's weapons (Shared/Turrets names them through Config.Turrets); the parts'
	recipes take its Nails and Scrap Metal and Mekanism's cables and osmium.
]]
return {
	order = 600,
	description = "Turrets and their parts, the Metal Miner and the Ammo Press, each behind its Config switch.",
	requires = { "Core", "Minecraft", "Mekanism", "Apocalypse" },
}
