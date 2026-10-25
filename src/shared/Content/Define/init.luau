--!strict
--[[
	What content packs build entries with (Shared/Content): a kind module written as
	`function(define) -> data` is called with this module, and any pack module may require it.
	Pure: it makes tables and requires only Config and the content types. The helpers live in its
	submodules (Items, Blocks, Plants, Recipes, Metal) and are all here as `define.<name>`; a pack's
	own helpers are its "_" modules.

	  Config          the game's tunables, for packs that read switches and numbers (the turrets',
	                  the miner's and the press's `Enabled`, the cave lava's level)
	  append(list, more)  adds `more`'s entries to the end of `list` (returns `list`)

	Item models and sets (Define/Items: pixels, ItemList's)
	  shade(colour, factor)   a colour scaled for highlights and shadows
	  lump(colour, light, dark)   a raw ore's or coal's lump with specks on both faces
	  ingot(colour), nugget(colour)   an ingot's bar and a nugget's cluster
	  HELMET, CHESTPLATE, LEGGINGS, BOOTS   the armor pieces' shapes
	  ARMOR_PIECES    each piece's name suffix, slot and model, head to feet
	  armorSet(material)   a material's four pieces (ArmorMaterial: points, toughness, `tan`)
	  HANDLE, HANDLE_DARK   the tools' wooden handle and its darker grip
	  handle(length, y)   a tool's handle box
	  TOOL_SHAPES     the sword, shovel, pickaxe, axe and hoe, each a model of its head's colour
	  toolSet(tier)   a tier's five tools (ToolTier: speed, level, durability, each shape's attack)
	  GLASS, bottle(water?)   the Glass Bottle, with a band of its liquid
	  BUCKET_IRON, bucket(top), filledBucket(colour, material)   Minecraft's bucket, empty or full
	  potion(variant, colour)   a potion item (PotionList's variant) in its effect's colour

	Blocks (Define/Blocks: BlockList's generators)
	  DIRECTIONS, OPPOSITE   the horizontal directions as offsets, and each one's opposite
	  FULL_BOUNDS     the whole cell, aimed at as a full block
	  onWall(box, support), wallBounds(support, depth)   a box turned onto a wall, a panel's outline
	  fluid(group, spec, tickDelay, flowing?)   a fluid's nine blocks: source, seven flows, falling
	  caveTwin(spec, extra?)   a block's cave twin ("Cave<Name>"), cave air while caves are hidden
	  caveFluid(source)   a fluid source's cave twin
	  torch(bottom), wallTorch(facing), lean(boxes, pivot, axis, angle)   torches' boxes, leaned
	  lantern(y, hanging)   a lantern's boxes, standing or hanging
	  GLASS_TRANSPARENCY, metalBox(...), glassBox(...)   Mekanism's frames and glass
	  transmitter(spec, frame, glass)   a Logistical Transporter or Mechanical Pipe, filled in
	  cable(spec, frame)   a Universal Cable, filled in
	  tank(spec, posts)   a Fluid Tank, filled in
	  DoorWood, door(wood), doorPiece(u0, u1, v0, v1, thick?, color?), darker(c, by)
	                  a door's 32 halves from its wood's design, the design's boxes
	  fence(base)     a fence's 16 variants (lone post and arms) from its own fields
	  layers(base, speeds)   a layered block's eight heights (snow layers)
	  machine(name, kind, colour, energy)   a Mekanism style machine block (heaters, coolers)

	Plants (Define/Plants: Minecraft's ground foliage)
	  GROUND, STEM, LEAF, LEAF_LIGHT   the ground's height, flower stems' and leaves' greens
	  FLOWER_BOUNDS, MUSHROOM_BOUNDS, SAPLING_BOUNDS, TALL_BOUNDS   Minecraft's outlines
	  leaning, along, slat, blade, leaf, plantBox, stem   a plant's boxes: blades, leaves, heads
	  plant(spec)     a plant's shared fields (not solid, broken at once, on its soil...)
	  tallIcon(lower, extra), tallPlant(lower, upper)   a tall plant's item, its two halves joined
	  tallFlower(name, colour, lower, upper, extra, displayName?)   a two block flower
	  flower(name, colour, shape, displayName?), tulip(name, colour)   flowers on dirt
	  mushroom(name, colour, shape, displayName), sapling(name, colour, displayName)
	  herb(name, displayName, colour, shape, bounds)   a Tough As Nails herb, planted by its item

	Recipes (Define/Recipes) and metals (Define/Metal)
	  shaped, shapeless, smelting   recipe records
	  storage(item, block)   nine of `item` into `block` and back (two recipes)
	  metal(spec)     a metal's whole set (Define/Metal's MetalSpec): its ore, storage block and
	                  raw block, its raw lump, ingot and nugget, the recipes between them and their
	                  textures, as { blocks, items, recipes, textures } for a pack's kind modules
	                  to take their part of
]]

local BlocksDefine = require(script.Blocks)
local Config = require(script.Parent.Parent.Config)
local ItemsDefine = require(script.Items)
local MetalDefine = require(script.Metal)
local PlantsDefine = require(script.Plants)
local RecipesDefine = require(script.Recipes)

export type ArmorPiece = ItemsDefine.ArmorPiece
export type ArmorMaterial = ItemsDefine.ArmorMaterial
export type ToolShape = ItemsDefine.ToolShape
export type ToolTier = ItemsDefine.ToolTier
export type DoorWood = BlocksDefine.DoorWood
export type MetalSpec = MetalDefine.MetalSpec
export type Metal = MetalDefine.Metal

local Define = {}

Define.Config = Config

-- Adds `more`'s entries to the end of `list`; returns `list`.
function Define.append<T>(list: { T }, more: { T }): { T }
	for _, entry in more do
		table.insert(list, entry)
	end
	return list
end

-- Item models and sets.
Define.shade = ItemsDefine.shade
Define.lump = ItemsDefine.lump
Define.ingot = ItemsDefine.ingot
Define.nugget = ItemsDefine.nugget
Define.HELMET = ItemsDefine.HELMET
Define.CHESTPLATE = ItemsDefine.CHESTPLATE
Define.LEGGINGS = ItemsDefine.LEGGINGS
Define.BOOTS = ItemsDefine.BOOTS
Define.ARMOR_PIECES = ItemsDefine.ARMOR_PIECES
Define.armorSet = ItemsDefine.armorSet
Define.HANDLE = ItemsDefine.HANDLE
Define.HANDLE_DARK = ItemsDefine.HANDLE_DARK
Define.handle = ItemsDefine.handle
Define.TOOL_SHAPES = ItemsDefine.TOOL_SHAPES
Define.toolSet = ItemsDefine.toolSet
Define.GLASS = ItemsDefine.GLASS
Define.bottle = ItemsDefine.bottle
Define.BUCKET_IRON = ItemsDefine.BUCKET_IRON
Define.bucket = ItemsDefine.bucket
Define.filledBucket = ItemsDefine.filledBucket
Define.potion = ItemsDefine.potion

-- Blocks.
Define.DIRECTIONS = BlocksDefine.DIRECTIONS
Define.OPPOSITE = BlocksDefine.OPPOSITE
Define.FULL_BOUNDS = BlocksDefine.FULL_BOUNDS
Define.onWall = BlocksDefine.onWall
Define.wallBounds = BlocksDefine.wallBounds
Define.fluid = BlocksDefine.fluid
Define.caveTwin = BlocksDefine.caveTwin
Define.caveFluid = BlocksDefine.caveFluid
Define.torch = BlocksDefine.torch
Define.wallTorch = BlocksDefine.wallTorch
Define.lean = BlocksDefine.lean
Define.lantern = BlocksDefine.lantern
Define.GLASS_TRANSPARENCY = BlocksDefine.GLASS_TRANSPARENCY
Define.metalBox = BlocksDefine.metalBox
Define.glassBox = BlocksDefine.glassBox
Define.transmitter = BlocksDefine.transmitter
Define.cable = BlocksDefine.cable
Define.tank = BlocksDefine.tank
Define.door = BlocksDefine.door
Define.doorPiece = BlocksDefine.doorPiece
Define.darker = BlocksDefine.darker
Define.fence = BlocksDefine.fence
Define.layers = BlocksDefine.layers
Define.machine = BlocksDefine.machine

-- Plants.
Define.GROUND = PlantsDefine.GROUND
Define.STEM = PlantsDefine.STEM
Define.LEAF = PlantsDefine.LEAF
Define.LEAF_LIGHT = PlantsDefine.LEAF_LIGHT
Define.FLOWER_BOUNDS = PlantsDefine.FLOWER_BOUNDS
Define.MUSHROOM_BOUNDS = PlantsDefine.MUSHROOM_BOUNDS
Define.SAPLING_BOUNDS = PlantsDefine.SAPLING_BOUNDS
Define.TALL_BOUNDS = PlantsDefine.TALL_BOUNDS
Define.leaning = PlantsDefine.leaning
Define.along = PlantsDefine.along
Define.slat = PlantsDefine.slat
Define.blade = PlantsDefine.blade
Define.leaf = PlantsDefine.leaf
Define.plantBox = PlantsDefine.plantBox
Define.stem = PlantsDefine.stem
Define.plant = PlantsDefine.plant
Define.tallIcon = PlantsDefine.tallIcon
Define.tallPlant = PlantsDefine.tallPlant
Define.tallFlower = PlantsDefine.tallFlower
Define.flower = PlantsDefine.flower
Define.tulip = PlantsDefine.tulip
Define.mushroom = PlantsDefine.mushroom
Define.sapling = PlantsDefine.sapling
Define.herb = PlantsDefine.herb

-- Recipes and metals.
Define.shaped = RecipesDefine.shaped
Define.shapeless = RecipesDefine.shapeless
Define.smelting = RecipesDefine.smelting
Define.storage = RecipesDefine.storage
Define.metal = MetalDefine.metal

-- What a function-form pack module receives (this module).
export type Context = typeof(Define)

return Define
