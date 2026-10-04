--!strict
--[[
	Items that are not blocks. (Every placeable block is an item too, with the block's own id: see
	Items. Those need no entry here.)

	An item's id is ITEM_BASE (4096) + its position in this list - 1, so:

	  * ALWAYS ADD NEW ITEMS AT THE END. Reordering changes ids, which breaks saved inventories.

	Fields (everything except `name` and `model` is optional):
	  name         Unique name, used as `Items.id.Name` (must not be a block name).
	  displayName  Shown in the inventory. Default: the name with spaces ("IronHelmet" -> "Iron Helmet").
	  maxStack     Most items of this kind in one slot. Default 64.
	  armor        { slot = "Head" | "Chest" | "Legs" | "Feet", defense, toughness }: worn in that armor
	               slot; Minecraft's armor points and toughness.
	  color        { r, g, b } in 0-255, a representative colour.
	  model        Boxes the item is drawn with, in pixels (1/16 of a block) around the item's centre:
	               { size = { x, y, z }, offset = { x, y, z }, color = { r, g, b }?, material = "Metal"? }.
]]

export type ModelBox = {
	size: { number },
	offset: { number },
	color: { number }?,
	material: string?,
}

export type ItemSpec = {
	name: string,
	displayName: string?,
	maxStack: number?,
	armor: { slot: string, defense: number, toughness: number }?,
	color: { number }?,
	material: string?,
	model: { ModelBox },
}

-- Armor shapes (pixels), shared by every material.
local HELMET: { ModelBox } = {
	{ size = { 10, 2, 10 }, offset = { 0, 4, 0 } },
	{ size = { 1, 6, 10 }, offset = { -4.5, 0, 0 } },
	{ size = { 1, 6, 10 }, offset = { 4.5, 0, 0 } },
	{ size = { 8, 6, 1 }, offset = { 0, 0, 4.5 } },
	{ size = { 8, 2, 1 }, offset = { 0, 2, -4.5 } },
}
local CHESTPLATE: { ModelBox } = {
	{ size = { 8, 11, 4 }, offset = { 0, -1, 0 } },
	{ size = { 4, 5, 5 }, offset = { -5.5, 2.5, 0 } },
	{ size = { 4, 5, 5 }, offset = { 5.5, 2.5, 0 } },
}
local LEGGINGS: { ModelBox } = {
	{ size = { 9, 3, 5 }, offset = { 0, 5, 0 } },
	{ size = { 4, 10, 4.5 }, offset = { -2.5, -1.5, 0 } },
	{ size = { 4, 10, 4.5 }, offset = { 2.5, -1.5, 0 } },
}
local BOOTS: { ModelBox } = {
	{ size = { 4, 4, 4 }, offset = { -3, 0, 1 } },
	{ size = { 4, 4, 4 }, offset = { 3, 0, 1 } },
	{ size = { 4, 2, 3 }, offset = { -3, -1, -2.5 } },
	{ size = { 4, 2, 3 }, offset = { 3, -1, -2.5 } },
}

local list: { ItemSpec } = {}

-- Minecraft armor materials: armor points of the head / chest / legs / feet pieces and toughness.
type ArmorMaterial = { name: string, color: { number }, material: string, points: { number }, toughness: number }
local ARMOR: { ArmorMaterial } = {
	{ name = "Leather", color = { 160, 101, 64 }, material = "Fabric", points = { 1, 3, 2, 1 }, toughness = 0 },
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
type ArmorPiece = { name: string, slot: string, model: { ModelBox } }
local PIECES: { ArmorPiece } = {
	{ name = "Helmet", slot = "Head", model = HELMET },
	{ name = "Chestplate", slot = "Chest", model = CHESTPLATE },
	{ name = "Leggings", slot = "Legs", model = LEGGINGS },
	{ name = "Boots", slot = "Feet", model = BOOTS },
}
for _, armor in ARMOR do
	for i, piece in PIECES do
		table.insert(list, {
			name = armor.name .. piece.name,
			maxStack = 1,
			armor = { slot = piece.slot, defense = armor.points[i], toughness = armor.toughness },
			color = armor.color,
			material = armor.material,
			model = piece.model,
		})
	end
end

-- Add new items below this line (and never above, see the note at the top).

return list
