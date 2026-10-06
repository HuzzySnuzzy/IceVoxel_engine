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
	  tool         { kind = "pickaxe" | "axe" | "shovel" | "hoe" | "sword" | "shears", speed, level }:
	               Minecraft's tool tiers (mining speed on blocks of its kind, harvest level; see
	               Shared/Mining). Shears are no tier (level 0): fast on blocks with `shearDrops`
	               (BlockList), which they harvest (Items.drops), and worn by every block.
	  durability   Uses before it breaks (Minecraft's max damage); such items stack to 1.
	  color        { r, g, b } in 0-255, a representative colour.
	  model        Boxes the item is drawn with, in pixels (1/16 of a block) around the item's centre:
	               { size = { x, y, z }, offset = { x, y, z }, color = { r, g, b }?, material = "Metal"?,
	                 rotation = degrees about the view axis (Z)?, shape = "Ball" | "Cylinder"? }.
	               Coordinates are as the inventory icon shows the item: x to the right, y up, z towards
	               the viewer (the front of armor is +z); angles are anticlockwise. A ball takes the
	               smallest of its sizes; a cylinder's axis is z (its round face looks at the viewer).
	               Boxes without a colour / material take the item's.
	  tilt         Degrees the whole model is turned (anticlockwise) about the view axis. Tools and
	               sticks are modelled upright (handle down, head up) and tilted -45 so they lie
	               diagonally, head at the top right, as in Minecraft's inventory; held in a hand they
	               are drawn upright again (client Rendering/ItemModels).
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
	{ size = { 8, 6, 1 }, offset = { 0, 0, -4.5 } },
	{ size = { 8, 2, 1 }, offset = { 0, 2, 4.5 } },
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
	{ size = { 4, 4, 4 }, offset = { -3, 0, -1 } },
	{ size = { 4, 4, 4 }, offset = { 3, 0, -1 } },
	{ size = { 4, 2, 3 }, offset = { -3, -1, 2.5 } },
	{ size = { 4, 2, 3 }, offset = { 3, -1, 2.5 } },
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
local HANDLE_DARK = { 70, 50, 30 }

-- `colour` scaled by `factor` (pixel art highlights and shadows).
local function shade(colour: { number }, factor: number): { number }
	return {
		math.min(255, math.round(colour[1] * factor)),
		math.min(255, math.round(colour[2] * factor)),
		math.min(255, math.round(colour[3] * factor)),
	}
end

-- A rounded lump (coal, raw ore) with light and dark specks on both faces.
local function lump(colour: { number }, light: { number }, dark: { number }): { ModelBox }
	return {
		{ size = { 7, 6, 4 }, offset = { 0, 0, 0 }, color = colour },
		{ size = { 5, 2, 3.5 }, offset = { -0.5, 3.5, 0 }, color = colour },
		{ size = { 5, 2, 3.5 }, offset = { 0.5, -3.5, 0 }, color = colour },
		{ size = { 2, 4, 3.5 }, offset = { -4, 0.5, 0 }, color = colour },
		{ size = { 2, 4, 3.5 }, offset = { 4, -0.5, 0 }, color = colour },
		{ size = { 1.5, 1.5, 0.5 }, offset = { -1.5, 1.5, 2.1 }, color = light },
		{ size = { 1, 1, 0.5 }, offset = { 2, 1, 2.1 }, color = light },
		{ size = { 1.5, 1, 0.5 }, offset = { 0.5, -1.75, 2.1 }, color = dark },
		{ size = { 1.5, 1.5, 0.5 }, offset = { 1.5, 0.5, -2.1 }, color = light },
		{ size = { 1.5, 1, 0.5 }, offset = { -1.5, -1.5, -2.1 }, color = dark },
	}
end

-- A bar with a narrower, lighter top and a shaded foot (tilted up to the right, like Minecraft's).
local function ingot(colour: { number }): { ModelBox }
	return {
		{ size = { 12, 3, 5 }, offset = { 0, -1, 0 } },
		{ size = { 10, 1.5, 4 }, offset = { 0, 1.25, 0 }, color = shade(colour, 1.12) },
		{ size = { 12.1, 0.75, 5.1 }, offset = { 0, -2.1, 0 }, color = shade(colour, 0.72) },
	}
end

-- A small cluster.
local function nugget(colour: { number }): { ModelBox }
	return {
		{ size = { 4, 3, 3 }, offset = { 0, -0.5, 0 } },
		{ size = { 2.5, 1.5, 2.5 }, offset = { -0.25, 1.5, 0 }, color = shade(colour, 1.12) },
		{ size = { 2, 2, 2.5 }, offset = { 2, -1.5, 0 }, color = shade(colour, 0.8) },
		{ size = { 2, 1.5, 2.5 }, offset = { -2, -1.25, 0 } },
	}
end

local COAL = { 34, 34, 38 }
local CHARCOAL = { 58, 46, 36 }
local RAW_IRON = { 196, 160, 128 }
local RAW_GOLD = { 232, 180, 50 }
local IRON = { 222, 222, 224 }
local GOLD = { 250, 213, 58 }
local DIAMOND = { 90, 236, 227 }
local EMERALD = { 40, 210, 90 }

table.insert(list, {
	name = "Stick",
	color = HANDLE,
	material = "Wood",
	model = {
		{ size = { 1.5, 16, 1.5 }, offset = { 0, 0, 0 } },
		{ size = { 0.5, 15, 1.6 }, offset = { -0.45, 0.25, 0 }, color = shade(HANDLE, 1.3) },
	},
	tilt = -45,
})
table.insert(list, {
	name = "Coal",
	color = COAL,
	material = "Slate",
	model = lump(COAL, { 82, 82, 88 }, { 14, 14, 16 }),
})
table.insert(list, {
	name = "Charcoal",
	color = CHARCOAL,
	material = "Slate",
	model = lump(CHARCOAL, { 102, 84, 66 }, { 30, 24, 18 }),
})
table.insert(list, {
	name = "RawIron",
	color = RAW_IRON,
	material = "Rock",
	model = lump(RAW_IRON, { 228, 200, 174 }, { 146, 112, 86 }),
})
table.insert(list, {
	name = "RawGold",
	color = RAW_GOLD,
	material = "Rock",
	model = lump(RAW_GOLD, { 252, 228, 122 }, { 180, 126, 28 }),
})
table.insert(list, { name = "IronIngot", color = IRON, material = "Metal", model = ingot(IRON), tilt = 25 })
table.insert(list, { name = "GoldIngot", color = GOLD, material = "Metal", model = ingot(GOLD), tilt = 25 })
table.insert(list, { name = "IronNugget", color = IRON, material = "Metal", model = nugget(IRON) })
table.insert(list, { name = "GoldNugget", color = GOLD, material = "Metal", model = nugget(GOLD) })
-- A cut gem: a wide crown with its table, a pointed pavilion and a glint.
table.insert(list, {
	name = "Diamond",
	color = DIAMOND,
	material = "Glass",
	model = {
		{ size = { 10, 3, 3 }, offset = { 0, 2.5, 0 } },
		{ size = { 6, 1, 2.5 }, offset = { 0, 4.5, 0 }, color = shade(DIAMOND, 1.15) },
		{ size = { 7.07, 7.07, 3 }, offset = { 0, -0.5, 0 }, rotation = 45, color = shade(DIAMOND, 0.75) },
		{ size = { 2, 2, 0.5 }, offset = { -2.5, 2.5, 1.6 }, color = { 225, 255, 252 } },
	},
})
-- An upright octagonal gem with darker bevels and a light centre.
table.insert(list, {
	name = "Emerald",
	color = EMERALD,
	material = "Glass",
	model = {
		{ size = { 6, 9, 3 }, offset = { 0, 0, 0 } },
		{ size = { 4, 1, 3 }, offset = { 0, 5, 0 } },
		{ size = { 4, 1, 3 }, offset = { 0, -5, 0 } },
		{ size = { 1, 7, 3 }, offset = { -3.5, 0, 0 }, color = shade(EMERALD, 0.7) },
		{ size = { 1, 7, 3 }, offset = { 3.5, 0, 0 }, color = shade(EMERALD, 0.7) },
		{ size = { 2, 6, 0.5 }, offset = { -0.5, 0.5, 1.6 }, color = { 150, 250, 172 } },
	},
})
table.insert(list, {
	name = "Snowball",
	maxStack = 16,
	color = { 240, 245, 250 },
	material = "Snow",
	model = {
		{ size = { 8, 8, 8 }, offset = { 0, 0, 0 }, shape = "Ball" },
		{ size = { 4, 4, 4 }, offset = { 1.75, 1.75, 1.5 }, shape = "Ball", color = { 255, 255, 255 } },
	},
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

--[[
	Upright shapes: Minecraft's sprites turned so the handle is vertical, from y = -10 up, with the
	head on top (the axe's blade and the hoe's head on the left, where the sprites have them).
	`tilt` lays them back on the diagonal. Boxes without a colour take the tier's (`head`).
]]
local function handle(length: number, y: number): ModelBox
	return { size = { 1.5, length, 1.25 }, offset = { 0, y, 0 }, color = HANDLE, material = "Wood" }
end
type ToolShape = { name: string, kind: string, model: (head: { number }) -> { ModelBox } }
local SHAPES: { ToolShape } = {
	{
		name = "Sword",
		kind = "sword",
		model = function(head)
			-- Blade (shaded on one side) with a pointed tip, crossguard, grip and pommel.
			return {
				{ size = { 3, 10, 1 }, offset = { 0, 2.5, 0 } },
				{ size = { 1, 10, 1.1 }, offset = { 1, 2.5, 0 }, color = shade(head, 0.72) },
				{ size = { 2.12, 2.12, 1 }, offset = { 0, 7.5, 0 }, rotation = 45 },
				{ size = { 7, 1.5, 1.5 }, offset = { 0, -3.25, 0 }, color = HANDLE_DARK, material = "Wood" },
				{ size = { 1.5, 4.5, 1.25 }, offset = { 0, -6.25, 0 }, color = HANDLE, material = "Wood" },
				{ size = { 2, 1.5, 1.5 }, offset = { 0, -9.25, 0 }, color = HANDLE_DARK, material = "Wood" },
			}
		end,
	},
	{
		name = "Shovel",
		kind = "shovel",
		model = function(head)
			-- A spade with a rounded point, shaded on one side, on a collar.
			return {
				handle(13, -3.5),
				{ size = { 5, 5.5, 1.25 }, offset = { 0, 5.75, 0 } },
				{ size = { 2.83, 2.83, 1.25 }, offset = { 0, 8.5, 0 }, rotation = 45 },
				{ size = { 1, 5.5, 1.35 }, offset = { 2, 5.75, 0 }, color = shade(head, 0.72) },
				{ size = { 2.25, 1.5, 1.5 }, offset = { 0, 2.75, 0 }, color = shade(head, 0.6) },
			}
		end,
	},
	{
		name = "Pickaxe",
		kind = "pickaxe",
		model = function(head)
			-- An arc across the top: a middle bar, then wings and tips drooping on both sides.
			return {
				handle(16, -2),
				{ size = { 6, 2.5, 1.5 }, offset = { 0, 6, 0 } },
				{ size = { 6, 0.75, 1.6 }, offset = { 0, 5.1, 0 }, color = shade(head, 0.72) },
				{ size = { 5, 2, 1.5 }, offset = { -4.85, 5.15, 0 }, rotation = 20 },
				{ size = { 5, 2, 1.5 }, offset = { 4.85, 5.15, 0 }, rotation = -20 },
				{ size = { 3, 1.75, 1.5 }, offset = { -7.76, 3.45, 0 }, rotation = 50 },
				{ size = { 3, 1.75, 1.5 }, offset = { 7.76, 3.45, 0 }, rotation = -50 },
			}
		end,
	},
	{
		name = "Axe",
		kind = "axe",
		model = function(head)
			-- The head left of the handle's top, flaring out to a long, brighter edge; a poll behind.
			return {
				handle(17, -1.5),
				{ size = { 3, 3.5, 1.5 }, offset = { -0.75, 6.5, 0 }, color = shade(head, 0.8) },
				{ size = { 2.25, 4.75, 1.5 }, offset = { -3.375, 5.875, 0 } },
				{ size = { 1.25, 6.5, 1.5 }, offset = { -5.125, 5, 0 }, color = shade(head, 1.15) },
				{ size = { 1.5, 2.5, 1.5 }, offset = { 1.5, 7, 0 }, color = shade(head, 0.8) },
			}
		end,
	},
	{
		name = "Hoe",
		kind = "hoe",
		model = function(head)
			-- The head runs down to the left from the handle's top and hooks back at its end.
			return {
				handle(17, -1.5),
				{ size = { 5.5, 2, 1.5 }, offset = { -1.44, 6.31, 0 }, rotation = 45 },
				{ size = { 2.5, 2, 1.5 }, offset = { -2.51, 3.48, 0 }, rotation = -45, color = shade(head, 1.15) },
				{ size = { 2, 1.5, 1.6 }, offset = { 0, 7.5, 0 }, color = shade(head, 0.72) },
			}
		end,
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
			model = shape.model(tier.color),
			tilt = -45,
		})
	end
end

--[[ Light ]]

-- Glow Dust: what glow lichen (2) and the Glow Block (4, which make a block again) drop, the
-- game's blue glowing dust in place of Minecraft's glowstone dust (and of redstone in Mekanism's
-- recipes): a small heap with bright specks. It was named "GlowstoneDust" (Items.RENAMED).
local GLOW_DUST = { 92, 150, 238 }
local SPARK = { 196, 228, 255 }
table.insert(list, {
	name = "GlowDust",
	displayName = "Glow Dust",
	color = GLOW_DUST,
	material = "Sand",
	model = {
		{ size = { 11, 3, 4 }, offset = { 0, -3.5, 0 } },
		{ size = { 7, 3, 4 }, offset = { 0.5, -0.5, 0 }, color = shade(GLOW_DUST, 1.08) },
		{ size = { 3.5, 2.5, 3.5 }, offset = { -0.25, 2.25, 0 }, color = shade(GLOW_DUST, 1.15) },
		{ size = { 1.5, 1.5, 0.5 }, offset = { -3, -3, 2.1 }, color = SPARK, material = "Neon" },
		{ size = { 1, 1, 0.5 }, offset = { 2, -0.5, 2.1 }, color = SPARK, material = "Neon" },
		{ size = { 1, 1, 0.5 }, offset = { -0.5, 2.5, 1.85 }, color = SPARK, material = "Neon" },
		{ size = { 1, 1, 0.5 }, offset = { 3.5, -3.5, -2.1 }, color = SPARK, material = "Neon" },
	},
})

--[[
	Mekanism pipes (Shared/Transmitters) and Minecraft's buckets.

	The Configurator (Mekanism's tool) sets how each side of a transmitter connects and colours
	transporters: a wrench with a blue head and a small screen on its grip, modelled upright and
	tilted like the tools. Buckets carry fluids (Shared/Fluids) to and from fluid tanks and the world
	(1000 mB, a source block); an empty one stacks to 16 as in Minecraft, a full one does not stack.
	(The Lava, Oil and Fuel Buckets are further down.)
]]
local CONFIGURATOR_BLUE = { 44, 116, 214 }
local CONFIGURATOR_GRIP = { 62, 64, 72 }
table.insert(list, {
	name = "Configurator",
	maxStack = 1,
	color = CONFIGURATOR_BLUE,
	material = "Metal",
	model = {
		{ size = { 2, 11, 1.5 }, offset = { 0, -3.5, 0 }, color = CONFIGURATOR_GRIP },
		{ size = { 2.4, 1, 1.8 }, offset = { 0, -8.25, 0 }, color = { 30, 30, 34 } },
		{ size = { 1.2, 2, 0.4 }, offset = { 0, -1, 0.9 }, color = { 120, 230, 255 }, material = "Neon" },
		{ size = { 6, 2, 1.5 }, offset = { 0, 3, 0 }, color = shade(CONFIGURATOR_BLUE, 0.8) },
		{ size = { 2, 4, 1.5 }, offset = { -2, 6, 0 } },
		{ size = { 2, 4, 1.5 }, offset = { 2, 6, 0 } },
		{ size = { 1, 3, 1.6 }, offset = { -2.5, 6.5, 0 }, color = shade(CONFIGURATOR_BLUE, 1.2) },
	},
	tilt = -45,
})

-- Minecraft's iron bucket seen from the front: a rim, a body narrowing to its base, and a handle.
local BUCKET_IRON = { 196, 198, 204 }
local function bucket(top: { ModelBox }): { ModelBox }
	local boxes: { ModelBox } = {
		{ size = { 12, 1.5, 4.5 }, offset = { 0, 4.25, 0 }, color = shade(BUCKET_IRON, 1.1) },
		{ size = { 11, 3, 4 }, offset = { 0, 2, 0 } },
		{ size = { 9.5, 3, 4 }, offset = { 0, -1, 0 } },
		{ size = { 8, 2, 4 }, offset = { 0, -3.5, 0 }, color = shade(BUCKET_IRON, 0.75) },
		{ size = { 1, 3.5, 1 }, offset = { -5.25, 6.75, 0 }, color = shade(BUCKET_IRON, 0.5) },
		{ size = { 1, 3.5, 1 }, offset = { 5.25, 6.75, 0 }, color = shade(BUCKET_IRON, 0.5) },
		{ size = { 9.5, 1, 1 }, offset = { 0, 8, 0 }, color = shade(BUCKET_IRON, 0.5) },
	}
	for _, box in top do
		table.insert(boxes, box)
	end
	return boxes
end
local WATER = { 52, 96, 220 }
table.insert(list, {
	name = "Bucket",
	maxStack = 16,
	color = BUCKET_IRON,
	material = "Metal",
	-- (Its dark inside, seen over the rim.)
	model = bucket({ { size = { 10, 0.6, 3.5 }, offset = { 0, 5.1, 0 }, color = { 58, 58, 62 } } }),
})
table.insert(list, {
	name = "WaterBucket",
	maxStack = 1,
	color = WATER,
	material = "Metal",
	-- (Water filling it to the rim, and a band of it showing over the rim's front.)
	model = bucket({
		{ size = { 10.5, 0.8, 3.8 }, offset = { 0, 5.2, 0 }, color = WATER, material = "SmoothPlastic" },
		{ size = { 10.5, 1.2, 0.4 }, offset = { 0, 4.4, 2.45 }, color = WATER, material = "SmoothPlastic" },
	}),
})

--[[
	Mekanism's osmium: what Osmium Ore drops (Raw Osmium), the ingot it smelts into and the nugget,
	drawn like their iron and gold counterparts in a bluish silver. Mekanism's later machines and
	cables are made from the ingot. (The ore and the storage blocks are in BlockList.)
]]
local RAW_OSMIUM = { 132, 158, 190 }
local OSMIUM = { 172, 192, 216 }
table.insert(list, {
	name = "RawOsmium",
	color = RAW_OSMIUM,
	material = "Rock",
	model = lump(RAW_OSMIUM, { 200, 218, 238 }, { 84, 106, 136 }),
})
table.insert(list, { name = "OsmiumIngot", color = OSMIUM, material = "Metal", model = ingot(OSMIUM), tilt = 25 })
table.insert(list, { name = "OsmiumNugget", color = OSMIUM, material = "Metal", model = nugget(OSMIUM) })

--[[
	Mekanism's upgrade cards (Shared/Machines/Upgrades): the Speed Upgrade and the Energy Upgrade,
	which the Electric Furnace and the Solar Panel take in their upgrade slots, 8 of each at most
	(Mekanism's Upgrade.getMax); they stack to that 8 too (Mekanism's own stack to 64). A small
	circuit card with gold contacts and the upgrade's symbol in its colour (Mekanism's EnumColor:
	red for speed, bright green for energy): two chevrons, a bolt.
]]
local CARD = { 58, 62, 70 }
local CONTACT = shade(GOLD, 0.9)
local SPEED_RED = { 226, 64, 60 }
local ENERGY_GREEN = { 96, 226, 92 }

-- The card: a dark board, a lighter face, four gold contacts along its foot, then `symbol`.
local function upgradeCard(symbol: { ModelBox }): { ModelBox }
	local boxes: { ModelBox } = {
		{ size = { 12, 13, 1 }, offset = { 0, 0.5, 0 }, color = CARD },
		{ size = { 10, 9, 0.4 }, offset = { 0, 1.5, 0.6 }, color = shade(CARD, 1.35) },
	}
	for i = 0, 3 do
		table.insert(boxes, { size = { 1.5, 2, 1.2 }, offset = { -3.75 + i * 2.5, -5.5, 0 }, color = CONTACT })
	end
	for _, box in symbol do
		table.insert(boxes, box)
	end
	return boxes
end

-- A ">" chevron with its tip at (x, y): two bars meeting at a right angle (on the card's face).
local function chevron(x: number, y: number): { ModelBox }
	return {
		{ size = { 4, 1.3, 0.4 }, offset = { x - 1.4, y + 1.4, 1 }, rotation = -45, material = "Neon" },
		{ size = { 4, 1.3, 0.4 }, offset = { x - 1.4, y - 1.4, 1 }, rotation = 45, material = "Neon" },
	}
end

local speedSymbol = chevron(0, 1.5)
for _, box in chevron(3.5, 1.5) do
	table.insert(speedSymbol, box)
end
table.insert(list, {
	name = "SpeedUpgrade",
	maxStack = 8,
	color = SPEED_RED,
	material = "Metal",
	model = upgradeCard(speedSymbol),
})
table.insert(list, {
	name = "EnergyUpgrade",
	maxStack = 8,
	color = ENERGY_GREEN,
	material = "Metal",
	-- (A bolt: a stroke down to the left end of a bar, the bar, a stroke down from its right end.)
	model = upgradeCard({
		{ size = { 1.4, 4.5, 0.4 }, offset = { -0.55, 3.55, 1 }, rotation = -25, material = "Neon" },
		{ size = { 4, 1.3, 0.4 }, offset = { 0, 1.5, 1 }, material = "Neon" },
		{ size = { 1.4, 4.5, 0.4 }, offset = { 0.55, -0.55, 1 }, rotation = -25, material = "Neon" },
	}),
})

--[[
	Minecraft's Shears: 238 uses, a tool of their own kind (Shared/Mining: 15 on leaves, worn by
	every block broken, instant ones too) that harvests grass, ferns, dead bushes and leaves
	(BlockList `shearDrops`; Items.drops). Two grey blades crossing at a rivet over two darker
	handle loops, modelled upright like the tools (blades up) and tilted the same way.
]]
local SHEARS = { 204, 206, 210 }
local SHEARS_HANDLE = { 112, 114, 120 }
local SHEARS_HOLE = { 40, 40, 44 }
-- (Each blade runs on through the rivet into the opposite handle, 12 degrees off upright.)
local SHEARS_ANGLE = 12
local function shearsArm(side: number): { ModelBox }
	local a = math.rad(SHEARS_ANGLE)
	-- Along the arm, from the rivet at (0, -1): +d up the blade, -d down the handle.
	local dx, dy = side * math.sin(a), math.cos(a)
	return {
		{ size = { 1.8, 8, 0.6 }, offset = { dx * 4, -1 + dy * 4, side * 0.3 }, rotation = -side * SHEARS_ANGLE },
		{
			size = { 2.8, 5, 0.8 },
			offset = { -dx * 3.6, -1 - dy * 3.6, side * 0.3 },
			rotation = -side * SHEARS_ANGLE,
			color = SHEARS_HANDLE,
		},
		{
			size = { 1, 2.6, 0.9 },
			offset = { -dx * 4, -1 - dy * 4, side * 0.3 },
			rotation = -side * SHEARS_ANGLE,
			color = SHEARS_HOLE,
		},
	}
end
local shearsModel: { ModelBox } = {}
for _, side in { 1, -1 } do
	for _, box in shearsArm(side) do
		table.insert(shearsModel, box)
	end
end
table.insert(shearsModel, { size = { 1.4, 1.4, 1.4 }, offset = { 0, -1, 0 }, color = SHEARS_HANDLE })
table.insert(list, {
	name = "Shears",
	durability = 238,
	tool = { kind = "shears", speed = 15, level = 0 },
	color = SHEARS,
	material = "Metal",
	model = shearsModel,
	tilt = -45,
})

--[[
	Buckets of lava (Minecraft's), oil and fuel (BuildCraft's): the Water Bucket's model with the
	fluid's colour to the rim (Shared/Fluids' colours; lava glowing Neon, oil glossy). Full ones don't
	stack, and each leaves the empty Bucket when used up (Items.craftingRemainder); a Lava Bucket
	burns 20 000 ticks in a furnace (Crafting/Smelting).
]]
local function filledBucket(colour: { number }, material: string): { ModelBox }
	return bucket({
		{ size = { 10.5, 0.8, 3.8 }, offset = { 0, 5.2, 0 }, color = colour, material = material },
		{ size = { 10.5, 1.2, 0.4 }, offset = { 0, 4.4, 2.45 }, color = colour, material = material },
	})
end
local LAVA = { 212, 90, 20 }
local OIL = { 24, 22, 26 }
local FUEL = { 232, 172, 44 }
table.insert(list, {
	name = "LavaBucket",
	maxStack = 1,
	color = LAVA,
	material = "Metal",
	model = filledBucket(LAVA, "Neon"),
})
table.insert(list, {
	name = "OilBucket",
	maxStack = 1,
	color = OIL,
	material = "Metal",
	model = filledBucket(OIL, "Glass"),
})
table.insert(list, {
	name = "FuelBucket",
	maxStack = 1,
	color = FUEL,
	material = "Metal",
	model = filledBucket(FUEL, "SmoothPlastic"),
})

--[[
	Tough As Nails' water (Shared/ToughAsNails/Drinks): Minecraft's Glass Bottle, filled at a water
	source into TAN's Dirty Water Bottle, which a furnace purifies (the Purified Water Bottle);
	and the Canteen, TAN's leather canteen made of iron here (the game has no leather), filled at
	water with three sips of dirty water (its `durability`: each sip wears it, the last one leaves
	the empty Canteen), purified the same way. The water shows through the front of the glass and
	in the canteen's round window, murky green-brown when dirty, clear blue when purified. Filled
	bottles stack to 16 (Minecraft's honey bottles), so a furnace purifies a stack in one go.
]]
local GLASS = { 214, 230, 240 }
local DIRTY_WATER = { 98, 116, 74 }
local PURIFIED_WATER = { 64, 140, 236 }
local function bottle(water: { number }?): { ModelBox }
	local boxes: { ModelBox } = {
		{ size = { 8, 7, 6 }, offset = { 0, -3.5, 0 } },
		{ size = { 6, 1.5, 5 }, offset = { 0, 0.75, 0 } },
		{ size = { 3, 3, 3 }, offset = { 0, 3, 0 } },
		{ size = { 4, 1, 4 }, offset = { 0, 5, 0 }, color = shade(GLASS, 0.85) },
		{ size = { 1.2, 4, 0.4 }, offset = { -2.6, -3, 3.1 }, color = { 255, 255, 255 } },
	}
	if water then
		table.insert(boxes, { size = { 6.8, 5, 0.4 }, offset = { 0.4, -4.2, 3.1 }, color = water })
	end
	return boxes
end
table.insert(list, {
	name = "GlassBottle",
	color = GLASS,
	material = "Glass",
	model = bottle(nil),
})
table.insert(list, {
	name = "DirtyWaterBottle",
	maxStack = 16,
	color = DIRTY_WATER,
	material = "Glass",
	model = bottle(DIRTY_WATER),
})
table.insert(list, {
	name = "PurifiedWaterBottle",
	maxStack = 16,
	color = PURIFIED_WATER,
	material = "Glass",
	model = bottle(PURIFIED_WATER),
})
local CANTEEN = { 172, 176, 184 }
local function canteen(window: { number }): { ModelBox }
	return {
		{ size = { 11, 11, 3 }, offset = { 0, -1.5, -0.5 }, color = shade(CANTEEN, 0.7), shape = "Cylinder" },
		{ size = { 10, 10, 4 }, offset = { 0, -1.5, 0 }, shape = "Cylinder" },
		{ size = { 5.5, 5.5, 0.5 }, offset = { 0, -1.5, 2.1 }, color = window, shape = "Cylinder" },
		{ size = { 3, 2, 3 }, offset = { 0, 4.5, 0 } },
		{ size = { 4, 1.5, 4 }, offset = { 0, 6.25, 0 }, color = { 70, 52, 36 }, material = "Wood" },
		{ size = { 1, 4, 1 }, offset = { -5.5, 3, 0 }, color = { 120, 84, 52 }, material = "Fabric" },
		{ size = { 1, 4, 1 }, offset = { 5.5, 3, 0 }, color = { 120, 84, 52 }, material = "Fabric" },
	}
end
table.insert(list, {
	name = "Canteen",
	maxStack = 1,
	color = CANTEEN,
	material = "Metal",
	model = canteen({ 58, 58, 62 }),
})
table.insert(list, {
	name = "DirtyWaterCanteen",
	durability = 3,
	color = DIRTY_WATER,
	material = "Metal",
	model = canteen(DIRTY_WATER),
})
table.insert(list, {
	name = "PurifiedWaterCanteen",
	durability = 3,
	color = PURIFIED_WATER,
	material = "Metal",
	model = canteen(PURIFIED_WATER),
})

--[[
	Fire (Shared/Fire, server Behaviours/Fire). Flint: Minecraft's, which gravel drops one time in
	10 (Items.randomDrop): a dark chipped shard with a pale glint. Flint and Steel: Minecraft's
	(shapeless: an iron ingot and flint), 64 uses, each lighting a fire in front of the clicked
	face where fire can burn (Players/ItemUse); a steel striker's ring at the bottom left, the
	flint at the top right, as its inventory icon.
]]
local FLINT = { 62, 62, 68 }
local STEEL = { 168, 170, 176 }
table.insert(list, {
	name = "Flint",
	color = FLINT,
	material = "Slate",
	model = {
		{ size = { 6, 8, 3 }, offset = { 0, -0.5, 0 } },
		{ size = { 4, 3, 2.6 }, offset = { -1, 4.5, 0 }, rotation = 20 },
		{ size = { 3.5, 3, 2.6 }, offset = { 1.2, -5.2, 0 }, rotation = -15 },
		{ size = { 2, 2.5, 0.4 }, offset = { -1, 1.5, 1.6 }, color = shade(FLINT, 1.9) },
		{ size = { 1.5, 3, 0.4 }, offset = { 1.5, -2, 1.6 }, color = shade(FLINT, 0.7) },
	},
})
table.insert(list, {
	name = "FlintAndSteel",
	displayName = "Flint and Steel",
	durability = 64,
	color = STEEL,
	material = "Metal",
	model = {
		-- (The ring opens to the right: its bottom, back and shorter top bar.)
		{ size = { 7, 1.6, 1.5 }, offset = { -2.5, -6.2, 0 } },
		{ size = { 1.6, 6, 1.5 }, offset = { -6, -4, 0 } },
		{ size = { 5, 1.6, 1.5 }, offset = { -3.5, -1.8, 0 }, color = shade(STEEL, 1.15) },
		{ size = { 5, 6, 2.5 }, offset = { 3, 3.5, 0 }, rotation = 25, color = FLINT, material = "Slate" },
		{ size = { 1.8, 2.2, 0.4 }, offset = { 2.4, 4.4, 1.4 }, rotation = 25, color = shade(FLINT, 1.9) },
	},
})

--[[
	Gunpowder (Minecraft's, which creepers drop: this game has no creepers). Black powder is
	charcoal and saltpetre; here a coal or charcoal and a flint make two (Shared/Crafting/Recipes),
	and five of them with four sand make TNT (BlockList Tnt, server Behaviours/Tnt). A dark grey
	heap of grains with a few lighter specks, as Minecraft's icon.
]]
local GUNPOWDER = { 78, 78, 80 }
table.insert(list, {
	name = "Gunpowder",
	color = GUNPOWDER,
	material = "Sand",
	model = {
		{ size = { 12, 3, 4 }, offset = { 0, -4.5, 0 } },
		{ size = { 9, 3, 4 }, offset = { -0.5, -1.5, 0 } },
		{ size = { 5, 3, 4 }, offset = { 0.5, 1.5, 0 } },
		{ size = { 2, 2, 4 }, offset = { 0, 4, 0 } },
		{ size = { 1.5, 1.5, 0.4 }, offset = { -3, -3.5, 2.1 }, color = shade(GUNPOWDER, 1.8) },
		{ size = { 1.5, 1.5, 0.4 }, offset = { 2.5, -1, 2.1 }, color = shade(GUNPOWDER, 1.6) },
		{ size = { 1.5, 1.5, 0.4 }, offset = { 3.5, -4.5, 2.1 }, color = shade(GUNPOWDER, 0.6) },
		{ size = { 1.5, 1.5, 0.4 }, offset = { -0.5, 2, 2.1 }, color = shade(GUNPOWDER, 0.6) },
	},
})

return list
