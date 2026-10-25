--!strict
--[[
	What content packs build entries with (Shared/Content): a kind module written as
	`function(define) -> data` is called with this module, and any pack module may require it.
	Pure: it makes tables and requires only Config and the content types.

	  Config        the game's tunables, for packs that read switches and numbers (the turrets',
	                the miner's and the press's `Enabled`, the cave lava's level)
	  shade, lump, ingot, nugget
	                item model helpers: a colour scaled for highlights and shadows, a raw ore's
	                lump, an ingot's bar and a nugget's cluster, in pixels (ItemList's)
	  HELMET, CHESTPLATE, LEGGINGS, BOOTS, ARMOR_PIECES
	                the armor pieces' shapes, and each piece's name suffix, slot and model
	  shaped, shapeless, smelting, storage
	                recipe records: `storage(item, block)` packs nine of `item` into `block`
	                and unpacks it into nine again (two recipes)
	  metal(spec)   a metal's whole set (MetalSpec below): its ore, storage block and raw block,
	                its raw lump, ingot and nugget, the recipes between them (storage both ways,
	                smelting the ore and the lump), and their textures, as { blocks, items,
	                recipes, textures } for a pack's kind modules to take their part of
	  append(list, more)  adds `more`'s entries to the end of `list` (returns `list`)

	The rest of BlockList's and ItemList's generators (fluids, plants, doors, fences, transmitters,
	flowers, saplings, armor and tool sets, machines) move here as their features become packs.
]]

local Config = require(script.Parent.Parent.Config)
local Schema = require(script.Parent.Schema)

type ModelBox = Schema.ModelBox
type BlockSpec = Schema.BlockSpec
type ItemSpec = Schema.ItemSpec
type Recipe = Schema.Recipe
type Texture = Schema.Texture

local Define = {}

Define.Config = Config

--[[ Models ]]

-- `colour` scaled by `factor` (pixel art highlights and shadows).
function Define.shade(colour: { number }, factor: number): { number }
	return {
		math.min(255, math.round(colour[1] * factor)),
		math.min(255, math.round(colour[2] * factor)),
		math.min(255, math.round(colour[3] * factor)),
	}
end
local shade = Define.shade

-- A rounded lump (coal, raw ore) with light and dark specks on both faces.
function Define.lump(colour: { number }, light: { number }, dark: { number }): { ModelBox }
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
function Define.ingot(colour: { number }): { ModelBox }
	return {
		{ size = { 12, 3, 5 }, offset = { 0, -1, 0 } },
		{ size = { 10, 1.5, 4 }, offset = { 0, 1.25, 0 }, color = shade(colour, 1.12) },
		{ size = { 12.1, 0.75, 5.1 }, offset = { 0, -2.1, 0 }, color = shade(colour, 0.72) },
	}
end

-- A small cluster.
function Define.nugget(colour: { number }): { ModelBox }
	return {
		{ size = { 4, 3, 3 }, offset = { 0, -0.5, 0 } },
		{ size = { 2.5, 1.5, 2.5 }, offset = { -0.25, 1.5, 0 }, color = shade(colour, 1.12) },
		{ size = { 2, 2, 2.5 }, offset = { 2, -1.5, 0 }, color = shade(colour, 0.8) },
		{ size = { 2, 1.5, 2.5 }, offset = { -2, -1.25, 0 } },
	}
end

-- Armor shapes (pixels), shared by every material.
Define.HELMET = {
	{ size = { 10, 2, 10 }, offset = { 0, 4, 0 } },
	{ size = { 1, 6, 10 }, offset = { -4.5, 0, 0 } },
	{ size = { 1, 6, 10 }, offset = { 4.5, 0, 0 } },
	{ size = { 8, 6, 1 }, offset = { 0, 0, -4.5 } },
	{ size = { 8, 2, 1 }, offset = { 0, 2, 4.5 } },
} :: { ModelBox }
Define.CHESTPLATE = {
	{ size = { 8, 11, 4 }, offset = { 0, -1, 0 } },
	{ size = { 4, 5, 5 }, offset = { -5.5, 2.5, 0 } },
	{ size = { 4, 5, 5 }, offset = { 5.5, 2.5, 0 } },
} :: { ModelBox }
Define.LEGGINGS = {
	{ size = { 9, 3, 5 }, offset = { 0, 5, 0 } },
	{ size = { 4, 10, 4.5 }, offset = { -2.5, -1.5, 0 } },
	{ size = { 4, 10, 4.5 }, offset = { 2.5, -1.5, 0 } },
} :: { ModelBox }
Define.BOOTS = {
	{ size = { 4, 4, 4 }, offset = { -3, 0, -1 } },
	{ size = { 4, 4, 4 }, offset = { 3, 0, -1 } },
	{ size = { 4, 2, 3 }, offset = { -3, -1, 2.5 } },
	{ size = { 4, 2, 3 }, offset = { 3, -1, 2.5 } },
} :: { ModelBox }

-- The armor pieces, head to feet: the name's suffix ("IronHelmet"), the slot and the model.
export type ArmorPiece = { name: string, slot: string, model: { ModelBox } }
Define.ARMOR_PIECES = {
	{ name = "Helmet", slot = "Head", model = Define.HELMET },
	{ name = "Chestplate", slot = "Chest", model = Define.CHESTPLATE },
	{ name = "Leggings", slot = "Legs", model = Define.LEGGINGS },
	{ name = "Boots", slot = "Feet", model = Define.BOOTS },
} :: { ArmorPiece }

--[[ Recipes ]]

function Define.shaped(
	pattern: { string },
	key: { [string]: string },
	result: string,
	count: number?,
	keep: string?
): Recipe
	return { type = "shaped", pattern = pattern, key = key, result = result, count = count, keep = keep }
end

function Define.shapeless(ingredients: { string }, result: string, count: number?, keep: string?): Recipe
	return { type = "shapeless", ingredients = ingredients, result = result, count = count, keep = keep }
end

function Define.smelting(input: string, result: string, count: number?): Recipe
	return { type = "smelting", input = input, result = result, count = count }
end

-- A 3 x 3 of `item` packs into `block`, which unpacks into 9 again.
function Define.storage(item: string, block: string): { Recipe }
	return {
		Define.shaped({ "###", "###", "###" }, { ["#"] = item }, block),
		Define.shapeless({ block }, item, 9),
	}
end

-- Adds `more`'s entries to the end of `list`; returns `list`.
function Define.append<T>(list: { T }, more: { T }): { T }
	for _, entry in more do
		table.insert(list, entry)
	end
	return list
end

--[[ Metals ]]

--[[
	A metal (`metal`): `name` ("Copper"; the entries are "<Name>Ore", "<Name>Block",
	"Raw<Name>Block", "Raw<Name>", "<Name>Ingot", "<Name>Nugget"), `level` the least pickaxe tier
	its ore and blocks need (Schema's `toolLevel`), and its colours: `ore` (the ore's specks), `block`,
	`rawBlock`, `raw` (the lump), `ingot` (the ingot and nugget), `light` and `dark` (the lump's
	specks). Each piece may be given fields of its own, put over (or added to) what is made:
	`oreBlock`, `storageBlock`, `rawBlock`, `rawItem`, `ingotItem`, `nuggetItem` (lore, age,
	knowledge, miner, radiation...). `ore = false` (an alloy: brass) makes no ore, raw lump or raw
	block and no smelting.

	The ore: Minecraft's ores' hardness 3, a pickaxe of `level` to drop its raw lump, a Granite
	(speckled stone) look. The storage blocks: hardness 5, Minecraft's metal blocks' blast resistance
	6, a pickaxe of `level`; the block of Metal, the raw block of Rock. The lump, ingot (tilted 25
	degrees) and nugget: Define's models in the metal's colours, blank icons. Their textures are
	"<name> ore", "<name> block" and "raw <name> block" (lower case), blank and untinted, each on
	its block's material.
]]
export type MetalSpec = {
	name: string,
	level: number,
	ore: false?,
	colors: {
		ore: { number }?,
		block: { number },
		rawBlock: { number }?,
		raw: { number }?,
		ingot: { number },
		light: { number }?,
		dark: { number }?,
	},
	oreBlock: { [string]: any }?,
	storageBlock: { [string]: any }?,
	rawBlock: { [string]: any }?,
	rawItem: { [string]: any }?,
	ingotItem: { [string]: any }?,
	nuggetItem: { [string]: any }?,
}
export type Metal = {
	blocks: { BlockSpec },
	items: { ItemSpec },
	recipes: { Recipe },
	textures: { [string]: Texture },
}

-- `entry` with `extra`'s fields put over it.
local function with<T>(entry: T, extra: { [string]: any }?): T
	if extra then
		for field, value in extra do
			(entry :: any)[field] = value
		end
	end
	return entry
end

function Define.metal(spec: MetalSpec): Metal
	local name, level, colors = spec.name, spec.level, spec.colors
	local lower = string.lower(name)
	local hasOre = spec.ore ~= false
	local blocks: { BlockSpec } = {}
	local items: { ItemSpec } = {}
	local recipes: { Recipe } = {}
	local textures: { [string]: Texture } = {}
	local function block(entry: BlockSpec, texture: string, extra: { [string]: any }?)
		entry.texture = { All = texture }
		textures[texture] = { Color = "", Material = entry.material :: string, Tint = false }
		table.insert(blocks, with(entry, extra))
	end
	if hasOre then
		block({
			name = `{name}Ore`,
			color = colors.ore,
			material = "Granite",
			hardness = 3,
			tool = "pickaxe",
			toolLevel = level,
			drops = `Raw{name}`,
		}, `{lower} ore`, spec.oreBlock)
	end
	block({
		name = `{name}Block`,
		displayName = `Block of {name}`,
		color = colors.block,
		material = "Metal",
		hardness = 5,
		blastResistance = 6,
		tool = "pickaxe",
		toolLevel = level,
	}, `{lower} block`, spec.storageBlock)
	if hasOre then
		block({
			name = `Raw{name}Block`,
			displayName = `Block of Raw {name}`,
			color = colors.rawBlock,
			material = "Rock",
			hardness = 5,
			blastResistance = 6,
			tool = "pickaxe",
			toolLevel = level,
		}, `raw {lower} block`, spec.rawBlock)
		local raw = colors.raw :: { number }
		table.insert(
			items,
			with({
				name = `Raw{name}`,
				color = raw,
				material = "Rock",
				model = Define.lump(raw, colors.light :: { number }, colors.dark :: { number }),
				icon = "",
			}, spec.rawItem)
		)
	end
	table.insert(
		items,
		with({
			name = `{name}Ingot`,
			color = colors.ingot,
			material = "Metal",
			model = Define.ingot(colors.ingot),
			tilt = 25,
			icon = "",
		}, spec.ingotItem)
	)
	table.insert(
		items,
		with({
			name = `{name}Nugget`,
			color = colors.ingot,
			material = "Metal",
			model = Define.nugget(colors.ingot),
			icon = "",
		}, spec.nuggetItem)
	)
	Define.append(recipes, Define.storage(`{name}Nugget`, `{name}Ingot`))
	Define.append(recipes, Define.storage(`{name}Ingot`, `{name}Block`))
	if hasOre then
		Define.append(recipes, Define.storage(`Raw{name}`, `Raw{name}Block`))
		table.insert(recipes, Define.smelting(`Raw{name}`, `{name}Ingot`))
		table.insert(recipes, Define.smelting(`{name}Ore`, `{name}Ingot`))
	end
	return { blocks = blocks, items = items, recipes = recipes, textures = textures }
end

-- What a function-form pack module receives (this module).
export type Context = typeof(Define)

return Define
