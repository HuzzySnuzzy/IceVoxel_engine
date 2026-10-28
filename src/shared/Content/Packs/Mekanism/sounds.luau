--!strict
--[[
	Mekanism's sounds:

	  * the Configurator changing a transmitter's side or colour (server Players/ItemUse): a click,
	    the volume tick pitched down;
	  * the working machines' hums (client Audio/Ambience, from the machines' records: the blocks'
	    `workSound`), the fifth data sheet's recordings (Content/Define's RECORDINGS): a working
	    Electric Furnace "Electric Hum" (category machine.hum, with the seasons' heaters and the
	    Ammo Press), the Oil Refinery "Heavy Electric Hum" (category machine.heavy_hum, with the
	    Metal Miner: the two using the most energy, 200 J a tick and more); the old wind their
	    fallback. A Sound of a category's name in SoundService.IceVoxelSounds replaces its group.
]]

local Define = require(script.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Schema)

type SoundSpec = Schema.SoundSpec

return function(define: Define.Context): { SoundSpec }
	local FALLING = define.SHIPPED.FALLING
	return {
		{
			name = "item.configurator.click",
			id = define.SHIPPED.TICK,
			volume = 0.5,
			pitch = 0.8,
			pitchVariance = 0.05,
			duration = 0.25,
			source = "players",
			side = "server",
		},
		{
			name = "block.electric_furnace.hum",
			category = "machine.hum",
			id = define.RECORDINGS.ELECTRIC_HUM,
			volume = 0.25,
			pitch = 1.05,
			fallback = { id = FALLING, pitch = 0.5 },
			maxDistance = 12,
			source = "blocks",
			side = "client",
		},
		{
			name = "block.oil_refinery.hum",
			category = "machine.heavy_hum",
			id = define.RECORDINGS.HEAVY_HUM,
			volume = 0.35,
			pitch = 0.95,
			fallback = { id = FALLING, pitch = 0.35 },
			maxDistance = 12,
			source = "blocks",
			side = "client",
		},
	}
end
