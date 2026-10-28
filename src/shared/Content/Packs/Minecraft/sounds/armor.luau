--!strict
--[[
	Armor put on (LivingEntity.onEquipItem), by material: a rustle, higher for chainmail and gold,
	lower for iron and diamond. A piece's entry names its own (`equipSound`: Content/Define's
	`armorSet` gives every piece its material's); the generic one is for armor naming none, and for
	accessories and vanity clothes (Shared/Sounds.ARMOR_DEFAULT). Their category, item.armor.equip,
	lets one Sound of that name replace them all.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

type SoundSpec = Schema.SoundSpec

return function(define: Define.Context): { SoundSpec }
	local GET_UP = define.SHIPPED.GET_UP
	return {
		{
			name = "item.armor.equip_generic",
			category = "item.armor.equip",
			id = GET_UP,
			volume = 0.6,
			source = "players",
			side = "server",
		},
		{
			name = "item.armor.equip_leather",
			category = "item.armor.equip",
			id = GET_UP,
			volume = 0.6,
			pitch = 1.1,
			source = "players",
			side = "server",
		},
		{
			name = "item.armor.equip_chain",
			category = "item.armor.equip",
			id = GET_UP,
			volume = 0.5,
			pitch = 1.45,
			source = "players",
			side = "server",
		},
		{
			name = "item.armor.equip_iron",
			category = "item.armor.equip",
			id = GET_UP,
			volume = 0.6,
			pitch = 0.9,
			source = "players",
			side = "server",
		},
		{
			name = "item.armor.equip_gold",
			category = "item.armor.equip",
			id = GET_UP,
			volume = 0.55,
			pitch = 1.25,
			source = "players",
			side = "server",
		},
		{
			name = "item.armor.equip_diamond",
			category = "item.armor.equip",
			id = GET_UP,
			volume = 0.6,
			pitch = 0.8,
			source = "players",
			side = "server",
		},
	}
end
