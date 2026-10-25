--!strict
--[[
	Minecraft's armor: leather, chainmail, iron, gold and diamond, four pieces each (Content/Define's
	`armorSet`: helmet, chestplate, leggings and boots in the armor shapes), with Minecraft's armor
	points of the head / chest / legs / feet pieces and toughness. Leather warms a step a piece in
	Tough As Nails' climate and is freeze immune (Minecraft's freeze_immune_wearables; Shared/
	ToughAsNails/Temperature). Leather's pieces are made from cows' Leather, iron's, gold's and
	diamond's from their ingots and gems (the pack's recipes); chainmail is not craftable, but
	smelts into iron nuggets.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

local MATERIALS: { Define.ArmorMaterial } = {
	{
		name = "Leather",
		color = { 160, 101, 64 },
		material = "Fabric",
		points = { 1, 3, 2, 1 },
		toughness = 0,
		tan = { warmth = 1, freezeImmune = true },
	},
	{
		name = "Chainmail",
		color = { 150, 152, 156 },
		material = "DiamondPlate",
		points = { 2, 5, 4, 1 },
		toughness = 0,
	},
	{ name = "Iron", color = { 216, 216, 216 }, material = "Metal", points = { 2, 6, 5, 2 }, toughness = 0 },
	{ name = "Gold", color = { 250, 213, 58 }, material = "Metal", points = { 2, 5, 3, 1 }, toughness = 0 },
	{ name = "Diamond", color = { 51, 235, 203 }, material = "Metal", points = { 3, 8, 6, 3 }, toughness = 2 },
}

return function(define: Define.Context): { Schema.ItemSpec }
	local list: { Schema.ItemSpec } = {}
	for _, armor in MATERIALS do
		define.append(list, define.armorSet(armor))
	end
	return list
end
