--!strict
--[[
	Content/Define's item helpers (Content/Define lists them): model pieces in pixels (ItemList's
	shapes: lumps, ingots, nuggets, the armor pieces, the tools, bottles and buckets) and the item
	sets that share them (an armor set, a tool set, a potion). Every entry made is an ItemSpec
	(Content/Schema); a pack's own items carry the rest of their fields themselves. A set takes
	what its pieces say of themselves (lore, icon, Age, fuel, equip sound) from its material or
	tier, so each piece's entry carries them as a hand-written one would; a potion takes them as
	`extra` fields.
]]

local Schema = require(script.Parent.Parent.Schema)

type ModelBox = Schema.ModelBox
type ItemSpec = Schema.ItemSpec

local Items = {}

--[[ Models ]]

-- `colour` scaled by `factor` (pixel art highlights and shadows).
function Items.shade(colour: { number }, factor: number): { number }
	return {
		math.min(255, math.round(colour[1] * factor)),
		math.min(255, math.round(colour[2] * factor)),
		math.min(255, math.round(colour[3] * factor)),
	}
end
local shade = Items.shade

-- A rounded lump (coal, raw ore) with light and dark specks on both faces.
function Items.lump(colour: { number }, light: { number }, dark: { number }): { ModelBox }
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
function Items.ingot(colour: { number }): { ModelBox }
	return {
		{ size = { 12, 3, 5 }, offset = { 0, -1, 0 } },
		{ size = { 10, 1.5, 4 }, offset = { 0, 1.25, 0 }, color = shade(colour, 1.12) },
		{ size = { 12.1, 0.75, 5.1 }, offset = { 0, -2.1, 0 }, color = shade(colour, 0.72) },
	}
end

-- A small cluster.
function Items.nugget(colour: { number }): { ModelBox }
	return {
		{ size = { 4, 3, 3 }, offset = { 0, -0.5, 0 } },
		{ size = { 2.5, 1.5, 2.5 }, offset = { -0.25, 1.5, 0 }, color = shade(colour, 1.12) },
		{ size = { 2, 2, 2.5 }, offset = { 2, -1.5, 0 }, color = shade(colour, 0.8) },
		{ size = { 2, 1.5, 2.5 }, offset = { -2, -1.25, 0 } },
	}
end

--[[ Armor ]]

-- Armor shapes (pixels), shared by every material.
Items.HELMET = {
	{ size = { 10, 2, 10 }, offset = { 0, 4, 0 } },
	{ size = { 1, 6, 10 }, offset = { -4.5, 0, 0 } },
	{ size = { 1, 6, 10 }, offset = { 4.5, 0, 0 } },
	{ size = { 8, 6, 1 }, offset = { 0, 0, -4.5 } },
	{ size = { 8, 2, 1 }, offset = { 0, 2, 4.5 } },
} :: { ModelBox }
Items.CHESTPLATE = {
	{ size = { 8, 11, 4 }, offset = { 0, -1, 0 } },
	{ size = { 4, 5, 5 }, offset = { -5.5, 2.5, 0 } },
	{ size = { 4, 5, 5 }, offset = { 5.5, 2.5, 0 } },
} :: { ModelBox }
Items.LEGGINGS = {
	{ size = { 9, 3, 5 }, offset = { 0, 5, 0 } },
	{ size = { 4, 10, 4.5 }, offset = { -2.5, -1.5, 0 } },
	{ size = { 4, 10, 4.5 }, offset = { 2.5, -1.5, 0 } },
} :: { ModelBox }
Items.BOOTS = {
	{ size = { 4, 4, 4 }, offset = { -3, 0, -1 } },
	{ size = { 4, 4, 4 }, offset = { 3, 0, -1 } },
	{ size = { 4, 2, 3 }, offset = { -3, -1, 2.5 } },
	{ size = { 4, 2, 3 }, offset = { 3, -1, 2.5 } },
} :: { ModelBox }

-- The armor pieces, head to feet: the name's suffix ("IronHelmet"), the slot and the model.
export type ArmorPiece = { name: string, slot: string, model: { ModelBox } }
Items.ARMOR_PIECES = {
	{ name = "Helmet", slot = "Head", model = Items.HELMET },
	{ name = "Chestplate", slot = "Chest", model = Items.CHESTPLATE },
	{ name = "Leggings", slot = "Legs", model = Items.LEGGINGS },
	{ name = "Boots", slot = "Feet", model = Items.BOOTS },
} :: { ArmorPiece }

-- Asserts every key of `map` names one of `pieces` (ARMOR_PIECES or TOOL_SHAPES: records with a
-- `name`), as a misspelt "Helmett" would be left out.
local function knownPieces(map: { [string]: any }, pieces: { any }, what: string)
	for key in map do
		local found = false
		for _, piece in pieces do
			found = found or piece.name == key
		end
		assert(found, `{what}: no piece is named {key}`)
	end
end

--[[
	An armor material (`armorSet`): Minecraft's armor points of the head / chest / legs / feet
	pieces and toughness, and each piece's Tough As Nails insulation (`tan`, Schema's: leather
	warms a step a piece and is freeze immune, Minecraft's freeze_immune_wearables). What every
	piece says of itself, each optional (Schema's fields of those names): `equipSound`, the event
	putting it on plays (SoundList's "item.armor.equip_<material>"; none: what Sounds.armorEquip
	gives armor naming none), so a set names its sound once; `lore`, its tooltip line; `age`, the
	Age opening its recipes; `icon`, every piece's icon ("" = not made yet); and `icons`, a piece's
	own icon by its name (ARMOR_PIECES': Helmet, Chestplate, Leggings, Boots), over `icon`.
]]
export type ArmorMaterial = {
	name: string,
	color: { number },
	material: string,
	points: { number },
	toughness: number,
	tan: { warmth: number?, cooling: number?, freezeImmune: boolean? }?,
	equipSound: string?,
	lore: string?,
	age: string?,
	icon: string?,
	icons: { [string]: string }?,
}

-- A material's four pieces, head to feet ("<Name>Helmet" ..), in the armor shapes; they stack to 1.
function Items.armorSet(armor: ArmorMaterial): { ItemSpec }
	local icons = armor.icons or {}
	knownPieces(icons, Items.ARMOR_PIECES, `armorSet {armor.name}'s icons`)
	local list: { ItemSpec } = {}
	for i, piece in Items.ARMOR_PIECES do
		table.insert(list, {
			name = armor.name .. piece.name,
			maxStack = 1,
			armor = { slot = piece.slot, defense = armor.points[i], toughness = armor.toughness },
			tan = armor.tan,
			color = armor.color,
			material = armor.material,
			model = piece.model,
			icon = icons[piece.name] or armor.icon,
			lore = armor.lore,
			age = armor.age,
			equipSound = armor.equipSound,
		})
	end
	return list
end

--[[ Tools: Minecraft's tiers (speed, harvest level, durability) and shapes ]]

-- The wooden handle of tools (and sticks, wands), and its darker grip.
Items.HANDLE = { 104, 76, 42 }
Items.HANDLE_DARK = { 70, 50, 30 }
local HANDLE, HANDLE_DARK = Items.HANDLE, Items.HANDLE_DARK

-- A tool's handle: `length` pixels, centred at `y`.
function Items.handle(length: number, y: number): ModelBox
	return { size = { 1.5, length, 1.25 }, offset = { 0, y, 0 }, color = HANDLE, material = "Wood" }
end
local handle = Items.handle

--[[
	Upright shapes: Minecraft's sprites turned so the handle is vertical, from y = -10 up, with the
	head on top (the axe's blade and the hoe's head on the left, where the sprites have them).
	`tilt` lays them back on the diagonal. Boxes without a colour take the tier's (`head`).
]]
export type ToolShape = { name: string, kind: string, model: (head: { number }) -> { ModelBox } }
Items.TOOL_SHAPES = {
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
} :: { ToolShape }

--[[
	A tool tier (`toolSet`): Minecraft's mining speed, harvest level and durability, the head's
	colour and material, and `attack`: per shape (TOOL_SHAPES' names) its { damage, speed }
	(Minecraft 1.20.1's attack damage, the hand's 1 included, and attack speed). What its tools say
	of themselves, each optional (Schema's fields): per shape, as `attack`, `lore` (its tooltip
	line) and `icons` (its icon, "" = not made yet); for every tool of the tier, `age` (the Age
	opening their recipes) and `fuel` (the ticks each one burns in a furnace: wooden tools).
]]
export type ToolTier = {
	name: string,
	speed: number,
	level: number,
	durability: number,
	color: { number },
	material: string,
	attack: { [string]: { number } },
	lore: { [string]: string }?,
	icons: { [string]: string }?,
	age: string?,
	fuel: number?,
}

-- A tier's five tools in TOOL_SHAPES' order ("<Tier>Sword" ..): one to a stack, tilted -45.
function Items.toolSet(tier: ToolTier): { ItemSpec }
	local lore, icons = tier.lore or {}, tier.icons or {}
	knownPieces(lore, Items.TOOL_SHAPES, `toolSet {tier.name}'s lore`)
	knownPieces(icons, Items.TOOL_SHAPES, `toolSet {tier.name}'s icons`)
	local list: { ItemSpec } = {}
	for _, shape in Items.TOOL_SHAPES do
		local attack = tier.attack[shape.name]
		table.insert(list, {
			name = tier.name .. shape.name,
			maxStack = 1,
			tool = { kind = shape.kind, speed = tier.speed, level = tier.level },
			attack = { damage = attack[1], speed = attack[2] },
			durability = tier.durability,
			color = tier.color,
			material = tier.material,
			model = shape.model(tier.color),
			tilt = -45,
			icon = icons[shape.name],
			lore = lore[shape.name],
			age = tier.age,
			fuel = tier.fuel,
		})
	end
	return list
end

--[[ Bottles and buckets ]]

-- The glass of bottles.
Items.GLASS = { 214, 230, 240 }
local GLASS = Items.GLASS

-- Minecraft's Glass Bottle, with a band of `water` (its liquid's colour) behind the front glass.
function Items.bottle(water: { number }?): { ModelBox }
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

-- Minecraft's iron bucket seen from the front: a rim, a body narrowing to its base, a handle, and
-- `top` over it (what it holds, or its dark inside).
local BUCKET_IRON = { 196, 198, 204 }
function Items.bucket(top: { ModelBox }): { ModelBox }
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
Items.BUCKET_IRON = BUCKET_IRON

-- A bucket full of a fluid of `colour` and `material` to the rim, a band of it over the rim's front.
function Items.filledBucket(colour: { number }, material: string): { ModelBox }
	return Items.bucket({
		{ size = { 10.5, 0.8, 3.8 }, offset = { 0, 5.2, 0 }, color = colour, material = material },
		{ size = { 10.5, 1.2, 0.4 }, offset = { 0, 4.4, 2.45 }, color = colour, material = material },
	})
end

--[[
	A potion item (a variant of Define/Potions: its item name and shown name): the Glass Bottle
	with the liquid in `colour` (its effect's: Minecraft's potion colour is its effect's), one to
	a stack as Minecraft's potions, with `extra`'s fields put over it (its lore, icon, Age...: what
	a hand-written entry would carry). Define/Potions' `brew` makes every potion's this way.
]]
function Items.potion(
	variant: { item: string, displayName: string },
	colour: { number },
	extra: { [string]: any }?
): ItemSpec
	local spec: ItemSpec = {
		name = variant.item,
		displayName = variant.displayName,
		maxStack = 1,
		color = colour,
		material = "Glass",
		model = Items.bottle(colour),
	}
	if extra then
		for field, value in extra do
			(spec :: any)[field] = value
		end
	end
	return spec
end

return Items
