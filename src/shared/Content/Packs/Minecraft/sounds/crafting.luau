--!strict
--[[
	The workshop's sounds: the chest's lid, which opens for the first viewer and closes after the
	last (ChestBlockEntity; every block whose menu is a chest's, Shared/Sounds.MENUS), and a lit
	furnace crackling (AbstractFurnaceBlock.animateTick) while its window shows it burning (client
	Audio/Ambience; the Heat and Combustion Generators crackle with it).
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

type SoundSpec = Schema.SoundSpec

return function(define: Define.Context): { SoundSpec }
	local SHIPPED = define.SHIPPED
	return {
		{
			name = "block.chest.open",
			id = SHIPPED.GET_UP,
			volume = 0.5,
			pitch = 0.7,
			pitchVariance = 0.03,
			source = "blocks",
			side = "server",
		},
		{
			name = "block.chest.close",
			id = SHIPPED.LAND,
			volume = 0.6,
			pitch = 0.95,
			pitchVariance = 0.03,
			source = "blocks",
			side = "server",
		},
		{
			name = "block.furnace.fire_crackle",
			id = SHIPPED.STEPS,
			volume = 0.3,
			pitch = 2.4,
			pitchVariance = 0.3,
			duration = 0.1,
			source = "blocks",
			side = "client",
			-- (A crackle is short and comes now and then.)
			limit = 2,
		},
	}
end
