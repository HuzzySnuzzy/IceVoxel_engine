--!strict
--[[
	Turrets, the Metal Miner and the Ammo Press (Shared/Turrets; Shared/Machines kinds
	"turret_<type>_<tier>", "miner" and "press"): the twelve turrets, type by type (SMG, Rifle,
	Sniper) and tier by tier within each (Basic, Advanced, Elite, Ultimate: Shared/Turrets.SPECS'
	order), the Metal Miner and the Ammo Press. Mekanism style machine blocks (hardness 3.5, a
	pickaxe to drop anything, metal sounds) drawn with their BlockDecor faces (never textured),
	which zombies never break. The blocks are always there; each feature's recipes are left out
	when its Config switch (`Enabled`) is off (the pack's recipes).
	  Turrets       a steel base whose gun the client draws on top (Rendering/TurretView): no full
	                cube on top for anything to rest on (`sturdy = false`: no torches, no snow
	                layers), the energy store of its tier (Config.Turrets.Capacity), filled as fast
	                as the network gives.
	  Metal Miner   copies the ore block under it (Config.Miner), a 200 kJ store.
	  Ammo Press    presses brass, lead and gunpowder into rounds (Config.AmmoPress), a 20 kJ store.
]]

local Define = require(script.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Schema)

-- (Shared/Turrets' types: their key, their part of the block name, their part of the shown name.)
local TURRET_TYPES = {
	{ key = "smg", name = "Smg", label = "SMG" },
	{ key = "rifle", name = "Rifle", label = "Rifle" },
	{ key = "sniper", name = "Sniper", label = "Sniper" },
}
local TURRET_TIERS = { "Basic", "Advanced", "Elite", "Ultimate" }

return function(define: Define.Context): { Schema.BlockSpec }
	local Config = define.Config
	local list: { Schema.BlockSpec } = {}
	for _, turret in TURRET_TYPES do
		for tier, tierName in TURRET_TIERS do
			local capacity = Config.Turrets.Capacity[tier]
			local name = `{tierName}{turret.name}Turret`
			table.insert(list, {
				name = name,
				displayName = `{tierName} {turret.label} Turret`,
				color = { 70, 74, 80 },
				material = "Metal",
				sound = "metal",
				hardness = 3.5,
				tool = "pickaxe",
				toolLevel = 0,
				sturdy = false,
				decor = name,
				machine = { kind = `turret_{turret.key}_{tier}` },
				energy = { capacity = capacity, input = capacity },
			})
		end
	end
	define.append(list, {
		{
			name = "MetalMiner",
			color = { 128, 122, 110 },
			material = "Metal",
			sound = "metal",
			hardness = 3.5,
			tool = "pickaxe",
			toolLevel = 0,
			decor = "MetalMiner",
			machine = { kind = "miner" },
			energy = { capacity = Config.Miner.Capacity, input = Config.Miner.Capacity },
		},
		{
			name = "AmmoPress",
			color = { 104, 108, 116 },
			material = "Metal",
			sound = "metal",
			hardness = 3.5,
			tool = "pickaxe",
			toolLevel = 0,
			decor = "AmmoPress",
			machine = { kind = "press" },
			energy = { capacity = Config.AmmoPress.Capacity, input = Config.AmmoPress.Capacity },
		},
	})
	return list
end
