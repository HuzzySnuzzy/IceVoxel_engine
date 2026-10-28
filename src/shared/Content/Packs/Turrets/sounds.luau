--!strict
--[[
	Turrets and the Metal Miner (Shared/Turrets, Shared/Machines kinds "miner" and "press"): loops,
	each replaced by a Sound of its name in SoundService.IceVoxelSounds (or the override folder):
	  block.turret.servo         a turret turning its gun: the falling wind pitched up, faint (at
	                             most Config.Turrets.Client.ServoLoops of them, the nearest)
	  block.metal_miner.hum      a working Metal Miner: the fifth sheet's "Heavy Electric Hum"
	                             (category machine.heavy_hum; the old clatter its fallback)
	  block.ammo_press.hum       a working Ammo Press: its "Electric Hum" (category machine.hum;
	                             the old thud its fallback)
	The client plays them (the servo at a turning turret: Rendering/TurretView; the hums while the
	machine works, from its record and its block's `workSound`: Audio/Ambience). A turret's shots
	are its stand-in gun's own fire sounds (the Apocalypse pack's, Rendering/ShotView), its dry
	click item.firearm.dry.
]]

local Define = require(script.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Schema)

type SoundSpec = Schema.SoundSpec

return function(define: Define.Context): { SoundSpec }
	local SHIPPED = define.SHIPPED
	return {
		{
			name = "block.turret.servo",
			id = SHIPPED.FALLING,
			volume = 0.15,
			pitch = 1.8,
			maxDistance = 12,
			source = "blocks",
			side = "client",
		},
		{
			name = "block.metal_miner.hum",
			category = "machine.heavy_hum",
			id = define.RECORDINGS.HEAVY_HUM,
			volume = 0.35,
			fallback = { id = SHIPPED.STEPS, pitch = 0.6, volume = 0.3 },
			maxDistance = 12,
			source = "blocks",
			side = "client",
		},
		{
			name = "block.ammo_press.hum",
			category = "machine.hum",
			id = define.RECORDINGS.ELECTRIC_HUM,
			volume = 0.3,
			pitch = 0.95,
			fallback = { id = SHIPPED.TICK, pitch = 0.5, volume = 0.4 },
			maxDistance = 12,
			source = "blocks",
			side = "client",
		},
	}
end
