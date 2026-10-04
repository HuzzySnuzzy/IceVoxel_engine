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
	  tool         { kind = "pickaxe" | "axe" | "shovel" | "hoe" | "sword", speed, level }: Minecraft's
	               tool tiers (mining speed on blocks of its kind, harvest level; see Shared/Mining).
	  durability   Uses before it breaks (Minecraft's max damage); such items stack to 1.
	  color        { r, g, b } in 0-255, a representative colour.
	  model        Boxes the item is drawn with, in pixels (1/16 of a block) around the item's centre:
	               { size = { x, y, z }, offset = { x, y, z }, color = { r, g, b }?, material = "Metal"?,
	                 rotation = degrees about the view axis (Z)?, shape = "Ball" | "Cylinder"? }.
	  tilt         Degrees the whole model is turned about Z (tools and sticks lie diagonally, as in
	               Minecraft's inventory).
]]

export type ModelBox = {
	size: { number },
	offset: { number },
	color: { number }?,
	material: string?,
	rotation: number?,
	shape: string?,
}

export type ItemSpec = {
	name: string,
	displayName: string?,
	maxStack: number?,
	armor: { slot: string, defense: number, toughness: number }?,
	tool: { kind: string, speed: number, level: number }?,
	durability: number?,
	color: { number }?,
	material: string?,
	model: { ModelBox },
	tilt: number?,
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

--[[ Crafting materials ]]

local HANDLE = { 104, 76, 42 }

-- A lump (coal, raw ore).
local function lump(colour: { number }): { ModelBox }
	return {
		{ size = { 6, 5, 5 }, offset = { -1.5, 0, 0 }, color = colour },
		{ size = { 5, 5, 5 }, offset = { 2, 1, 0.5 }, color = colour },
		{ size = { 5, 4, 4 }, offset = { 0, -2.5, -0.5 }, color = colour },
	}
end
local INGOT: { ModelBox } = {
	{ size = { 12, 3, 6 }, offset = { 0, -1, 0 } },
	{ size = { 10, 1.5, 4 }, offset = { 0, 1.2, 0 } },
}
local NUGGET: { ModelBox } = {
	{ size = { 4, 3, 4 }, offset = { 0, -0.5, 0 } },
	{ size = { 3, 1.5, 3 }, offset = { 0, 1.5, 0 } },
}

table.insert(list, {
	name = "Stick",
	color = HANDLE,
	material = "Wood",
	model = { { size = { 1.5, 14, 1.5 }, offset = { 0, 0, 0 } } },
	tilt = -45,
})
table.insert(list, { name = "Coal", color = { 34, 34, 38 }, material = "Slate", model = lump({ 34, 34, 38 }) })
table.insert(list, { name = "Charcoal", color = { 58, 46, 36 }, material = "Slate", model = lump({ 58, 46, 36 }) })
table.insert(list, { name = "RawIron", color = { 196, 160, 128 }, material = "Rock", model = lump({ 196, 160, 128 }) })
table.insert(list, { name = "RawGold", color = { 232, 180, 50 }, material = "Rock", model = lump({ 232, 180, 50 }) })
table.insert(list, { name = "IronIngot", color = { 222, 222, 224 }, material = "Metal", model = INGOT })
table.insert(list, { name = "GoldIngot", color = { 250, 213, 58 }, material = "Metal", model = INGOT })
table.insert(list, { name = "IronNugget", color = { 222, 222, 224 }, material = "Metal", model = NUGGET })
table.insert(list, { name = "GoldNugget", color = { 250, 213, 58 }, material = "Metal", model = NUGGET })
table.insert(list, {
	name = "Diamond",
	color = { 90, 236, 227 },
	material = "Glass",
	model = {
		{ size = { 7, 7, 7 }, offset = { 0, 0, 0 }, rotation = 45 },
		{ size = { 9, 2, 4 }, offset = { 0, 2.5, 0 } },
	},
})
table.insert(list, {
	name = "Emerald",
	color = { 40, 210, 90 },
	material = "Glass",
	model = { { size = { 5, 9, 5 }, offset = { 0, 0, 0 }, rotation = 45 } },
})
table.insert(list, {
	name = "Snowball",
	maxStack = 16,
	color = { 240, 245, 250 },
	material = "Snow",
	model = { { size = { 8, 8, 8 }, offset = { 0, 0, 0 }, shape = "Ball" } },
})

--[[ Tools: Minecraft's tiers (speed, harvest level, durability) and shapes ]]

type Tier = { name: string, speed: number, level: number, durability: number, color: { number }, material: string }
local TIERS: { Tier } = {
	{ name = "Wooden", speed = 2, level = 0, durability = 59, color = { 156, 121, 72 }, material = "WoodPlanks" },
	{ name = "Stone", speed = 4, level = 1, durability = 131, color = { 128, 128, 130 }, material = "Slate" },
	{ name = "Iron", speed = 6, level = 2, durability = 250, color = { 222, 222, 224 }, material = "Metal" },
	{ name = "Golden", speed = 12, level = 0, durability = 32, color = { 250, 213, 58 }, material = "Metal" },
	{ name = "Diamond", speed = 8, level = 3, durability = 1561, color = { 90, 236, 227 }, material = "Metal" },
}
-- Upright shapes (the handle down); `tilt` lays them diagonally. Boxes without a colour take the
-- tier's.
local function handle(length: number, y: number): ModelBox
	return { size = { 1.5, length, 1.5 }, offset = { 0, y, 0 }, color = HANDLE, material = "Wood" }
end
type ToolShape = { name: string, kind: string, model: { ModelBox } }
local SHAPES: { ToolShape } = {
	{
		name = "Sword",
		kind = "sword",
		model = {
			{ size = { 2.5, 10, 1 }, offset = { 0, 3, 0 } },
			{ size = { 6, 1.5, 2 }, offset = { 0, -2.75, 0 }, color = { 70, 50, 30 }, material = "Wood" },
			handle(4, -5.5),
		},
	},
	{
		name = "Shovel",
		kind = "shovel",
		model = { { size = { 5, 5, 1.5 }, offset = { 0, 5, 0 } }, handle(12, -2) },
	},
	{
		name = "Pickaxe",
		kind = "pickaxe",
		model = {
			{ size = { 8, 2, 2 }, offset = { 0, 5.5, 0 } },
			{ size = { 3, 2, 2 }, offset = { -5, 4.5, 0 } },
			{ size = { 3, 2, 2 }, offset = { 5, 4.5, 0 } },
			handle(13, -1.5),
		},
	},
	{
		name = "Axe",
		kind = "axe",
		model = { { size = { 5, 6, 1.5 }, offset = { -2.75, 3.5, 0 } }, handle(13, -1.5) },
	},
	{
		name = "Hoe",
		kind = "hoe",
		model = { { size = { 5, 2, 2 }, offset = { -2, 5.5, 0 } }, handle(13, -1.5) },
	},
}
for _, tier in TIERS do
	for _, shape in SHAPES do
		table.insert(list, {
			name = tier.name .. shape.name,
			maxStack = 1,
			tool = { kind = shape.kind, speed = tier.speed, level = tier.level },
			durability = tier.durability,
			color = tier.color,
			material = tier.material,
			model = shape.model,
			tilt = -45,
		})
	end
end

return list
