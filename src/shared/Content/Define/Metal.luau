--!strict
--[[
	Content/Define's `metal` (Content/Define lists it): a metal's whole set, its ore, storage block
	and raw block, its raw lump, ingot and nugget, the recipes between them and their textures.

	A metal (MetalSpec): `name` ("Copper"; the entries are "<Name>Ore", "<Name>Block",
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

	What a metal is given is checked first (Define/Fields): its own fields and colours, and each
	piece's fields against Content/Schema's block or item fields (an unknown one gets a "did you
	mean").
]]

local Fields = require(script.Parent.Fields)
local Items = require(script.Parent.Items)
local Recipes = require(script.Parent.Recipes)
local Schema = require(script.Parent.Parent.Schema)

type BlockSpec = Schema.BlockSpec
type ItemSpec = Schema.ItemSpec
type Recipe = Schema.Recipe
type Texture = Schema.Texture

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

local function append<T>(list: { T }, more: { T })
	for _, entry in more do
		table.insert(list, entry)
	end
end

-- A metal's own fields (MetalSpec), each piece's checked against its kind's fields.
local RGB = Schema.BLOCK_FIELDS.color
local function FALSE(value: any): string?
	return if value == false then nil else ` must be false (an alloy: no ore), not {tostring(value)}`
end
local METAL_OWN = table.freeze({
	name = Schema.STRING,
	level = Schema.NUMBER,
	ore = FALSE,
	colors = Schema.record({
		ore = RGB,
		block = RGB,
		rawBlock = RGB,
		raw = RGB,
		ingot = RGB,
		light = RGB,
		dark = RGB,
	}, { "block", "ingot" }),
	oreBlock = Schema.record(Schema.BLOCK_FIELDS),
	storageBlock = Schema.record(Schema.BLOCK_FIELDS),
	rawBlock = Schema.record(Schema.BLOCK_FIELDS),
	rawItem = Schema.record(Schema.ITEM_FIELDS),
	ingotItem = Schema.record(Schema.ITEM_FIELDS),
	nuggetItem = Schema.record(Schema.ITEM_FIELDS),
}) :: { [string]: Schema.Check }

local function metal(spec: MetalSpec): Metal
	Fields.check(`metal {spec.name}`, spec, { own = METAL_OWN, needs = { "name", "level", "colors" } })
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
				model = Items.lump(raw, colors.light :: { number }, colors.dark :: { number }),
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
			model = Items.ingot(colors.ingot),
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
			model = Items.nugget(colors.ingot),
			icon = "",
		}, spec.nuggetItem)
	)
	append(recipes, Recipes.storage(`{name}Nugget`, `{name}Ingot`))
	append(recipes, Recipes.storage(`{name}Ingot`, `{name}Block`))
	if hasOre then
		append(recipes, Recipes.storage(`Raw{name}`, `Raw{name}Block`))
		table.insert(recipes, Recipes.smelting(`Raw{name}`, `{name}Ingot`))
		table.insert(recipes, Recipes.smelting(`{name}Ore`, `{name}Ingot`))
	end
	return { blocks = blocks, items = items, recipes = recipes, textures = textures }
end

return { metal = metal, with = with }
