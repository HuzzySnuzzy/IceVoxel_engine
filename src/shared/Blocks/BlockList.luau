--!strict
--[[
	Every block type in the game. A block's numeric id is its position in this list minus one, so:

	  * ALWAYS ADD NEW BLOCKS AT THE END. Reordering changes ids, which breaks saved edits.
	  * Air must stay first (id 0): freshly created chunk buffers are zero-filled, i.e. all air.

	Fields (everything except `name` is optional):
	  name          Unique name, used as `Blocks.id.Name`.
	  render        "Opaque" (default), "Transparent" (glass-like), "Fluid" (only the surface is drawn)
	                or "None" (never drawn).
	  color         { r, g, b } in 0-255.
	  material      Name of an Enum.Material, e.g. "Slate".
	  transparency  Part transparency for Transparent / Fluid blocks.
	  reflectance   Part reflectance.
	  solid         Collides with characters. Default true for drawn blocks.
	  sturdy        false: torches and lanterns can't hang on it, though it is a solid cube
	                (Minecraft's support shape: leaves have none, and a chest's and a cactus's
	                faces stop short of the cell's). Default true for solid, drawn blocks without a
	                `shape` (Blocks.isSturdy); `true` makes a solid shaped block sturdy (a fluid
	                tank).
	  replaceable   Placing a block may overwrite it (air, fluids). Default false.
	  breakable     Players can break it. Default true.
	  placeable     Is an item players can hold and place (creative inventory, drops). Default true
	                for drawn, solid blocks.
	  behaviour     Name of a server block behaviour (see ServerScriptService.IceVoxel.Behaviours).
	  friction      How slippery the block is to walk on (Minecraft's block friction): 0.6 by
	                default, 0.98 for ice. Higher keeps more of the speed from tick to tick.
	  fluid         { group, level, tickDelay } for fluids (filled in by `fluid()` below).
	  displayName   Shown in the inventory (default: the name with spaces, "OakLog" -> "Oak Log").
	  hardness      Minecraft's destroy time (0 = breaks at once). Default 1. See Shared/Mining.
	  tool          The tool that mines it fast: "pickaxe", "axe", "shovel" or "hoe" (Minecraft's
	                mineable tags).
	  toolLevel     Set when the block only drops with that tool, of at least this tier (0 wood /
	                gold, 1 stone, 2 iron, 3 diamond): Minecraft's requiresCorrectToolForDrops. It
	                also mines 3.3 times slower without it. nil: drops by hand.
	  drops         Name of the item a survival player gets for breaking it (default: the block
	                itself), or false for nothing (e.g. glass, leaves).
	  dropCount     How many of `drops` (default 1).
	  container     Number of item slots the block keeps (a chest's 27, a furnace's 3); breaking it
	                drops what is inside.
	  menu          What right clicking opens: "Chest", "Crafting" (a crafting table's 3 x 3 grid)
	                or "Furnace".
	  decor         Faces drawn on the block's parts ("Chest", "CraftingTable", "Furnace",
	                "CreativeEnergyCube", "HeatGenerator"; client Rendering/BlockDecor). Such blocks
	                are drawn one part per block.
	  sound         What breaking, placing, hitting, walking and falling on it sounds like
	                (Minecraft's SoundType; the events are `block.<sound>.break` and so on, see
	                Shared/Sounds): "stone", "wood", "gravel", "grass", "sand", "glass", "snow",
	                "metal", "wool" or "water". Default: from the material (Wood / WoodPlanks wood;
	                Grass / LeafyGrass grass; Ground / Mud / Pebble gravel, as Minecraft's dirt
	                sounds; Sand sand; Snow snow; Glass / Ice / Glacier / Neon glass; Metal /
	                DiamondPlate / CorrodedMetal / Foil metal; Fabric wool; anything else stone),
	                "water" for fluids and none for blocks that are never drawn (air).

	Light and shapes (torches, lanterns, glowstone):
	  light         Light the block gives off, 0..15 (Minecraft's luminance: torches 14, glowstone
	                and lanterns 15). The renderer gives each such block one PointLight (on its
	                `glow` box), and lit blocks are drawn one part per block, so lights never merge or
	                pile up.
	  lightColor    { r, g, b } of that light. Default a warm white.
	  shape         Boxes the block is drawn with instead of a full cube, in pixels (1/16 block):
	                { size = { x, y, z }, offset = { x, y, z }, rotation = { rx, ry, rz }?,
	                  color = { r, g, b }?, material = "Metal"?, glow = true? }. `offset` is the
	                box's centre from the cell's centre (the cell spans -8..8 on every axis) and
	                `rotation` turns the box about its own centre (degrees, CFrame.Angles order).
	                Boxes without a colour / material take the block's; `glow` boxes are Neon and
	                carry the block's light. A shaped block is drawn one part per box, never hides
	                its neighbours and renders like glass ("Transparent") unless `render` says
	                otherwise. At most 15 boxes.
	  bounds        { min = { x, y, z }, max = { x, y, z } } in pixels 0..16: the outline players
	                aim at and see highlighted (Minecraft's VoxelShape). Default: the box around
	                the shape, or the whole cell. Bounds that cover the whole cell are aimed at as
	                a full block (no outline: transmitters, fluid tanks).
	  obstructs     Has a collision box in Minecraft though it is not `solid` (lanterns): its
	                `bounds` keep it from being placed inside a player (Minecraft's
	                BlockItem.canPlace) and falling sand lands on it (Blocks.obstruction). Players
	                and items still pass through it, unlike Minecraft's, where they bump into and
	                stand on lanterns: the movement hull only knows full cubes, and a solid lantern
	                would be an invisible wall. Torches have no collision box in either game.
	  support       The side the block hangs on: "Down" stands on the block below, "Up" hangs from
	                the one above, "North" / "South" / "West" / "East" are fixed to that side. That
	                block must be sturdy (`sturdy` above); when it goes, this one breaks and drops
	                if it also has `behaviour = "Attached"` (server Behaviours/Attached).
	  item          Name of the item that places and drops this block, for variants that are no
	                item of their own (wall torches are placed by, and drop, a Torch); Items.ofBlock
	                answers it. A block and every block naming it as `item` are its variants:
	                placing picks the one whose support holds (Blocks.placementFor).
	  brokenByFluid Flowing water washes it away and it drops (torches: Minecraft's canHoldFluid).
	                Players still can't place blocks into it.

	Mekanism pipes (Shared/Transmitters):
	  transmitter   { kind = "item" | "fluid" | "energy", tier = 1..4, restrictive = true? }: a
	                Logistical Transporter ("item"), the Restrictive Transporter (`restrictive`), a
	                Mechanical Pipe ("fluid") or a Universal Cable ("energy") of that tier (1 Basic
	                .. 4 Ultimate; the numbers are in Transmitters/Tiers). Its `shape` is the core;
	                the client draws the arms towards what it connects to.
	  tank          { tier = 1..4, capacity = mB }: a Fluid Tank (Transmitters.isTank).
	  icon          Boxes the item's model shows instead of `shape` (same format), starting with
	                the shape's own boxes in the same order: a transmitter's core plus two arms.
	  Shape boxes may also have `transparency` (0..1, default the block's): a transmitter's glass
	  is see-through, its frame is not.

	Mekanism machines (Shared/Machines; the server runs them in server/Machines):
	  machine       { kind = "<kind>" }: a machine of a kind Shared/Machines defines (its slots,
	                data, panel and tick). Its contents live in a container of kind "machine"
	                (server Players/Containers); right clicking opens its panel (`menu` defaults
	                to "Machine"). Don't set `container`: the slots are the kind's.
	  energy        { capacity = J, input = J/t?, output = J/t? }: the energy it holds and the
	                most it takes from / gives to an energy network per tick (Universal Cables
	                and directly adjacent energy blocks). Output only: a producer (generators);
	                input only: a consumer (machines); both: storage (batteries, the backup).
	                `math.huge` is Mekanism's creative infinity.

	Directions are Minecraft's: North = -Z, South = +Z, West = -X, East = +X.

	Textures (optional, see "Block textures" in the README):
	  texture       Name of a MaterialVariant in MaterialService whose BaseMaterial is `material`
	                (e.g. "IV_Stone" with BaseMaterial Slate, StudsPerTile = BlockSize, Pattern Regular).
	                `color` stays the block's colour on the map; the part is tinted with `tint`.
	  tint          { r, g, b } multiplied with the texture. Default white (the texture's own colours).
	  faces         { Top = "rbxassetid://...", ... }: extra images drawn on single faces of full
	                detail parts, e.g. a grass top over a dirt texture. Costs one instance per face.
]]

-- (Pure data that requires nothing, so Blocks never depends on the Transmitters logic.)
local Tiers = require(script.Parent.Parent.Transmitters.Tiers)

-- One box of a shaped block (see `shape` above).
export type ShapeBox = {
	size: { number },
	offset: { number },
	rotation: { number }?,
	color: { number }?,
	material: string?,
	glow: boolean?,
	transparency: number?,
}

export type Bounds = { min: { number }, max: { number } }

-- A transmitter (`transmitter`) and a fluid tank (`tank`); see Shared/Transmitters.
export type TransmitterSpec = { kind: string, tier: number, restrictive: boolean? }
export type TankSpec = { tier: number, capacity: number }
-- A machine (`machine`) and the energy it holds and moves (`energy`); see Shared/Machines.
export type MachineSpec = { kind: string }
export type EnergySpec = { capacity: number, input: number?, output: number? }

export type BlockSpec = {
	name: string,
	render: string?,
	color: { number }?,
	material: string?,
	transparency: number?,
	reflectance: number?,
	solid: boolean?,
	sturdy: boolean?,
	replaceable: boolean?,
	breakable: boolean?,
	placeable: boolean?,
	behaviour: string?,
	friction: number?,
	fluid: { group: string, level: number, tickDelay: number }?,
	displayName: string?,
	hardness: number?,
	tool: string?,
	toolLevel: number?,
	drops: (string | false)?,
	dropCount: number?,
	container: number?,
	menu: string?,
	decor: string?,
	sound: string?,
	texture: string?,
	tint: { number }?,
	faces: { [string]: string }?,
	light: number?,
	lightColor: { number }?,
	shape: { ShapeBox }?,
	bounds: Bounds?,
	obstructs: boolean?,
	support: string?,
	item: string?,
	brokenByFluid: boolean?,
	transmitter: TransmitterSpec?,
	tank: TankSpec?,
	icon: { ShapeBox }?,
	machine: MachineSpec?,
	energy: EnergySpec?,
}

local list: { BlockSpec } = {
	{ name = "Air", render = "None", solid = false, replaceable = true, breakable = false },
	-- Air produced by cave carving. Behaves exactly like air, but the mesher can treat it as solid
	-- rock so cave walls far from the camera are not drawn.
	{ name = "CaveAir", render = "None", solid = false, replaceable = true, breakable = false },
	{ name = "Bedrock", color = { 45, 45, 50 }, material = "Basalt", breakable = false, placeable = false },
	{
		name = "Stone",
		color = { 125, 125, 128 },
		material = "Slate",
		hardness = 1.5,
		drops = "Cobblestone",
		tool = "pickaxe",
		toolLevel = 0,
	},
	{
		name = "Cobblestone",
		color = { 110, 110, 112 },
		material = "Cobblestone",
		hardness = 2,
		tool = "pickaxe",
		toolLevel = 0,
	},
	{ name = "Dirt", color = { 121, 85, 58 }, material = "Ground", hardness = 0.5, tool = "shovel" },
	{
		name = "Grass",
		tool = "shovel",
		color = { 92, 158, 62 },
		material = "Grass",
		behaviour = "Grass",
		hardness = 0.6,
		drops = "Dirt",
	},
	{
		name = "DryGrass",
		tool = "shovel",
		color = { 168, 162, 84 },
		material = "Grass",
		behaviour = "Grass",
		hardness = 0.6,
		drops = "Dirt",
	},
	{
		name = "Snow",
		color = { 238, 242, 248 },
		material = "Snow",
		hardness = 0.2,
		tool = "shovel",
		toolLevel = 0,
		drops = "Snowball" :: string,
		dropCount = 4,
	},
	{
		name = "Sand",
		color = { 220, 206, 160 },
		material = "Sand",
		behaviour = "Gravity",
		hardness = 0.5,
		tool = "shovel",
	},
	{
		name = "Sandstone",
		color = { 206, 188, 138 },
		material = "Sandstone",
		hardness = 0.8,
		tool = "pickaxe",
		toolLevel = 0,
	},
	{
		name = "Gravel",
		color = { 132, 126, 122 },
		material = "Pebble",
		behaviour = "Gravity",
		hardness = 0.6,
		tool = "shovel",
	},
	{
		name = "Ice",
		color = { 165, 205, 240 },
		material = "Glacier",
		friction = 0.98,
		hardness = 0.5,
		drops = false,
		tool = "pickaxe",
	},
	{ name = "OakLog", color = { 106, 82, 52 }, material = "Wood", hardness = 2, tool = "axe" },
	-- (Leaves hold up no torches or lanterns: Minecraft's LeavesBlock has no support shape.)
	{
		name = "OakLeaves",
		color = { 68, 128, 46 },
		material = "LeafyGrass",
		hardness = 0.2,
		drops = false,
		tool = "hoe",
		sturdy = false,
	},
	{ name = "BirchLog", color = { 216, 212, 198 }, material = "Wood", hardness = 2, tool = "axe" },
	{
		name = "BirchLeaves",
		color = { 112, 150, 68 },
		material = "LeafyGrass",
		hardness = 0.2,
		drops = false,
		tool = "hoe",
		sturdy = false,
	},
	{ name = "SpruceLog", color = { 74, 54, 34 }, material = "Wood", hardness = 2, tool = "axe" },
	{
		name = "SpruceLeaves",
		color = { 44, 88, 56 },
		material = "LeafyGrass",
		hardness = 0.2,
		drops = false,
		tool = "hoe",
		sturdy = false,
	},
	{ name = "AcaciaLog", color = { 118, 108, 98 }, material = "Wood", hardness = 2, tool = "axe" },
	{
		name = "AcaciaLeaves",
		color = { 108, 138, 40 },
		material = "LeafyGrass",
		hardness = 0.2,
		drops = false,
		tool = "hoe",
		sturdy = false,
	},
	{ name = "JungleLog", color = { 96, 76, 44 }, material = "Wood", hardness = 2, tool = "axe" },
	{
		name = "JungleLeaves",
		color = { 40, 120, 30 },
		material = "LeafyGrass",
		hardness = 0.2,
		drops = false,
		tool = "hoe",
		sturdy = false,
	},
	-- (Minecraft's cactus sounds like wool, and is a pixel short of its cell on every side but the
	-- bottom: nothing hangs on it.)
	{
		name = "Cactus",
		color = { 64, 122, 52 },
		material = "Grass",
		hardness = 0.4,
		sound = "wool",
		sturdy = false,
	},
	{
		name = "CoalOre",
		color = { 58, 58, 62 },
		material = "Rock",
		hardness = 3,
		tool = "pickaxe",
		toolLevel = 0,
		drops = "Coal" :: string,
	},
	{
		name = "IronOre",
		color = { 176, 142, 118 },
		material = "Rock",
		hardness = 3,
		tool = "pickaxe",
		toolLevel = 1,
		drops = "RawIron" :: string,
	},
	{
		name = "GoldOre",
		color = { 222, 190, 72 },
		material = "Rock",
		hardness = 3,
		tool = "pickaxe",
		toolLevel = 2,
		drops = "RawGold" :: string,
	},
	{
		name = "DiamondOre",
		color = { 92, 202, 212 },
		material = "Rock",
		hardness = 3,
		tool = "pickaxe",
		toolLevel = 2,
		drops = "Diamond" :: string,
	},
	{
		name = "Planks",
		color = { 170, 134, 84 },
		material = "WoodPlanks",
		hardness = 2,
		tool = "axe",
		displayName = "Oak Planks",
	},
	{
		name = "Brick",
		color = { 160, 82, 62 },
		material = "Brick",
		hardness = 2,
		tool = "pickaxe",
		toolLevel = 0,
		displayName = "Bricks",
	},
	{
		name = "Glass",
		render = "Transparent",
		color = { 210, 235, 245 },
		material = "Glass",
		transparency = 0.6,
		hardness = 0.3,
		drops = false,
	},
}

--[[
	Fluids get one block per level: level 0 is a source block, 1-7 are flowing blocks getting weaker,
	and 8 is "falling" fluid fed from above. They share one appearance so the mesher merges them.
]]
local function fluid(group: string, spec: BlockSpec, tickDelay: number)
	for level = 0, 8 do
		local name = if level == 0 then group elseif level == 8 then group .. "Falling" else group .. "Flow" .. level
		table.insert(list, {
			name = name,
			render = "Fluid",
			color = spec.color,
			material = spec.material,
			transparency = spec.transparency,
			reflectance = spec.reflectance,
			solid = false,
			replaceable = true,
			placeable = level == 0,
			hardness = 100,
			drops = false,
			behaviour = "Fluid",
			fluid = { group = group, level = level, tickDelay = tickDelay },
		})
	end
end

fluid("Water", {
	name = "Water",
	color = { 44, 106, 196 },
	material = "Glass",
	transparency = 0.45,
	reflectance = 0.05,
}, 5)

-- Add new blocks below this line (and never above, see the note at the top).

-- Mountains, rivers and islands (terrain generator).
table.insert(list, {
	name = "PackedIce",
	color = { 141, 180, 236 },
	material = "Ice",
	friction = 0.98,
	hardness = 0.5,
	drops = false,
	tool = "pickaxe",
})
table.insert(list, {
	name = "Calcite",
	color = { 222, 223, 218 },
	material = "Marble",
	hardness = 0.75,
	tool = "pickaxe",
	toolLevel = 0,
})
table.insert(list, { name = "PackedMud", color = { 142, 106, 79 }, material = "Mud", hardness = 1, tool = "pickaxe" })
table.insert(list, {
	name = "Mycelium",
	tool = "shovel",
	color = { 122, 104, 116 },
	material = "Grass",
	behaviour = "Grass",
	hardness = 0.6,
	drops = "Dirt" :: string,
})
table.insert(list, {
	name = "Podzol",
	tool = "shovel",
	color = { 106, 74, 38 },
	material = "Ground",
	behaviour = "Grass",
	hardness = 0.5,
	drops = "Dirt" :: string,
})
table.insert(
	list,
	{ name = "CoarseDirt", color = { 112, 80, 56 }, material = "Ground", hardness = 0.5, tool = "shovel" }
)
-- Stone varieties and ores by altitude (Ores.luau).
table.insert(
	list,
	{ name = "Andesite", color = { 134, 134, 136 }, material = "Rock", hardness = 1.5, tool = "pickaxe", toolLevel = 0 }
)
table.insert(list, {
	name = "Diorite",
	color = { 190, 190, 190 },
	material = "Limestone",
	hardness = 1.5,
	tool = "pickaxe",
	toolLevel = 0,
})
table.insert(list, {
	name = "Granite",
	color = { 150, 103, 85 },
	material = "Granite",
	hardness = 1.5,
	tool = "pickaxe",
	toolLevel = 0,
})
table.insert(list, {
	name = "EmeraldOre",
	color = { 62, 168, 94 },
	material = "Rock",
	hardness = 3,
	tool = "pickaxe",
	toolLevel = 2,
	drops = "Emerald" :: string,
})
-- Containers (server Players/Containers): right clicking opens the slots, breaking drops them.
table.insert(list, {
	name = "Chest",
	color = { 162, 118, 58 },
	material = "WoodPlanks",
	hardness = 2.5,
	tool = "axe",
	container = 27,
	menu = "Chest",
	decor = "Chest",
	-- (Minecraft's chest is 14 pixels tall and a pixel in from the sides: nothing hangs on it.)
	sturdy = false,
})

-- Crafting (Shared/Crafting): the other planks, the crafting table and furnace, and the blocks
-- recipes and smelting make.
local function add(spec: BlockSpec)
	table.insert(list, spec)
end
add({ name = "BirchPlanks", color = { 196, 178, 123 }, material = "WoodPlanks", hardness = 2, tool = "axe" })
add({ name = "SprucePlanks", color = { 114, 84, 48 }, material = "WoodPlanks", hardness = 2, tool = "axe" })
add({ name = "AcaciaPlanks", color = { 168, 90, 50 }, material = "WoodPlanks", hardness = 2, tool = "axe" })
add({ name = "JunglePlanks", color = { 160, 115, 80 }, material = "WoodPlanks", hardness = 2, tool = "axe" })
add({
	name = "CraftingTable",
	color = { 128, 92, 54 },
	material = "WoodPlanks",
	hardness = 2.5,
	tool = "axe",
	menu = "Crafting",
	decor = "CraftingTable",
})
add({
	name = "Furnace",
	color = { 112, 112, 114 },
	material = "Cobblestone",
	hardness = 3.5,
	tool = "pickaxe",
	toolLevel = 0,
	container = 3,
	menu = "Furnace",
	decor = "Furnace",
})
add({
	name = "CoalBlock",
	displayName = "Block of Coal",
	color = { 22, 22, 26 },
	material = "Slate",
	hardness = 5,
	tool = "pickaxe",
	toolLevel = 0,
})
add({
	name = "IronBlock",
	displayName = "Block of Iron",
	color = { 220, 220, 222 },
	material = "Metal",
	hardness = 5,
	tool = "pickaxe",
	toolLevel = 1,
})
add({
	name = "GoldBlock",
	displayName = "Block of Gold",
	color = { 246, 208, 61 },
	material = "Metal",
	hardness = 3,
	tool = "pickaxe",
	toolLevel = 2,
})
add({
	name = "DiamondBlock",
	displayName = "Block of Diamond",
	color = { 98, 237, 228 },
	material = "Metal",
	hardness = 5,
	tool = "pickaxe",
	toolLevel = 2,
})
add({
	name = "EmeraldBlock",
	displayName = "Block of Emerald",
	color = { 42, 203, 88 },
	material = "Metal",
	hardness = 5,
	tool = "pickaxe",
	toolLevel = 2,
})
add({
	name = "RawIronBlock",
	displayName = "Block of Raw Iron",
	color = { 166, 135, 107 },
	material = "Rock",
	hardness = 5,
	tool = "pickaxe",
	toolLevel = 1,
})
add({
	name = "RawGoldBlock",
	displayName = "Block of Raw Gold",
	color = { 221, 169, 46 },
	material = "Rock",
	hardness = 5,
	tool = "pickaxe",
	toolLevel = 2,
})
add({
	name = "StoneBricks",
	color = { 122, 121, 122 },
	material = "Brick",
	hardness = 1.5,
	tool = "pickaxe",
	toolLevel = 0,
})
add({
	name = "CrackedStoneBricks",
	color = { 118, 117, 118 },
	material = "Brick",
	hardness = 1.5,
	tool = "pickaxe",
	toolLevel = 0,
})
add({
	name = "SmoothStone",
	color = { 158, 158, 158 },
	material = "Concrete",
	hardness = 2,
	tool = "pickaxe",
	toolLevel = 0,
})
add({
	name = "PolishedAndesite",
	color = { 132, 135, 134 },
	material = "Concrete",
	hardness = 1.5,
	tool = "pickaxe",
	toolLevel = 0,
})
add({
	name = "PolishedDiorite",
	color = { 192, 193, 194 },
	material = "Marble",
	hardness = 1.5,
	tool = "pickaxe",
	toolLevel = 0,
})
add({
	name = "PolishedGranite",
	color = { 154, 106, 89 },
	material = "Concrete",
	hardness = 1.5,
	tool = "pickaxe",
	toolLevel = 0,
})
add({
	name = "CutSandstone",
	color = { 217, 206, 159 },
	material = "Sandstone",
	hardness = 0.8,
	tool = "pickaxe",
	toolLevel = 0,
})
add({
	name = "SmoothSandstone",
	color = { 223, 214, 170 },
	material = "Sandstone",
	hardness = 2,
	tool = "pickaxe",
	toolLevel = 0,
})
add({
	name = "BlueIce",
	color = { 116, 167, 253 },
	material = "Ice",
	friction = 0.989,
	hardness = 2.8,
	tool = "pickaxe",
	drops = false,
})

--[[
	Light sources (Minecraft's torch, wall torch, lantern and glowstone). Torches and lanterns are
	shaped (pixels from the cell's centre) and need a block to hang on; the light is a PointLight on
	the `glow` box (client Rendering/PartPool).
]]
local WOOD = { 104, 76, 42 }
local FLAME = { 255, 206, 110 }
local TORCH_LIGHT = { 255, 196, 128 }
local IRON = { 62, 64, 72 }
local LANTERN_GLOW = { 255, 188, 92 }

-- A standing torch whose stick's bottom centre is at `bottom`: a 2 x 8 x 2 stick under a 2 x 2 x 2
-- flame (10 pixels, Minecraft's torch model).
local function torch(bottom: { number }): { ShapeBox }
	local x, y, z = bottom[1], bottom[2], bottom[3]
	return {
		{ size = { 2, 8, 2 }, offset = { x, y + 4, z }, color = WOOD, material = "Wood" },
		{ size = { 2, 2, 2 }, offset = { x, y + 9, z }, color = FLAME, material = "Neon", glow = true },
	}
end

--[[
	`boxes` leaned `angle` degrees about the X (axis "x") or Z axis through `pivot` (Minecraft's
	element rotation): the offsets turn about the pivot and each box turns by the same angle. The
	rotation matrices are Roblox's (CFrame.Angles), so the renderer draws exactly this.
]]
local function lean(boxes: { ShapeBox }, pivot: { number }, axis: string, angle: number): { ShapeBox }
	local r = math.rad(angle)
	local c, s = math.cos(r), math.sin(r)
	local out = {}
	for _, box in boxes do
		local dx, dy, dz = box.offset[1] - pivot[1], box.offset[2] - pivot[2], box.offset[3] - pivot[3]
		local offset, rotation
		if axis == "x" then
			offset = { pivot[1] + dx, pivot[2] + dy * c - dz * s, pivot[3] + dy * s + dz * c }
			rotation = { angle, 0, 0 }
		else
			offset = { pivot[1] + dx * c - dy * s, pivot[2] + dx * s + dy * c, pivot[3] + dz }
			rotation = { 0, 0, angle }
		end
		table.insert(out, {
			size = box.size,
			offset = offset,
			rotation = rotation,
			color = box.color,
			material = box.material,
			glow = box.glow,
		})
	end
	return out
end

-- Directions as offsets (Minecraft's: north = -Z).
local DIRECTIONS: { [string]: { number } } = {
	North = { 0, 0, -1 },
	South = { 0, 0, 1 },
	West = { -1, 0, 0 },
	East = { 1, 0, 0 },
}
local OPPOSITE: { [string]: string } = { North = "South", South = "North", West = "East", East = "West" }

table.insert(list, {
	name = "Torch",
	color = WOOD,
	material = "Wood",
	sound = "wood",
	solid = false,
	placeable = true,
	hardness = 0,
	light = 14,
	lightColor = TORCH_LIGHT,
	shape = torch({ 0, -8, 0 }),
	bounds = { min = { 6, 0, 6 }, max = { 10, 10, 10 } },
	support = "Down",
	brokenByFluid = true,
	behaviour = "Attached",
})

--[[
	Wall torches, facing away from the wall they hang on (Minecraft's wall_torch `facing`): the
	torch's foot touches the middle of that wall 3.5 pixels up, and it leans 22.5 degrees out
	(template_torch_wall). Placed by the Torch item, they drop a Torch.
]]
for _, facing in { "North", "South", "West", "East" } do
	local d = DIRECTIONS[facing]
	-- The foot, on the wall behind the torch.
	local pivot = { -d[1] * 8, -4.5, -d[3] * 8 }
	local boxes = if d[1] ~= 0
		-- Turning about +Z by -a moves the top towards +X: lean out, away from the wall.
		then lean(torch(pivot), pivot, "z", -d[1] * 22.5)
		else lean(torch(pivot), pivot, "x", d[3] * 22.5)
	-- Minecraft's outline: 5 x 10 x 5 pixels against the wall, 3 to 13 up.
	local lo = { 5.5, 3, 5.5 }
	local hi = { 10.5, 13, 10.5 }
	local axis = if d[1] ~= 0 then 1 else 3
	-- Against the wall: 0..5 when it is on the low side (facing +), 11..16 otherwise.
	if d[axis] > 0 then
		lo[axis], hi[axis] = 0, 5
	else
		lo[axis], hi[axis] = 11, 16
	end
	table.insert(list, {
		name = "WallTorch" .. facing,
		displayName = "Wall Torch",
		color = WOOD,
		material = "Wood",
		sound = "wood",
		solid = false,
		placeable = false,
		hardness = 0,
		light = 14,
		lightColor = TORCH_LIGHT,
		shape = boxes,
		bounds = { min = lo, max = hi },
		support = OPPOSITE[facing],
		item = "Torch",
		brokenByFluid = true,
		behaviour = "Attached",
	})
end

-- Glowstone: a full glowing cube (Neon). Minecraft drops 2-4 dust (random); here always 4, which
-- craft back into the block.
table.insert(list, {
	name = "Glowstone",
	color = { 222, 178, 98 },
	material = "Neon",
	sound = "glass",
	hardness = 0.3,
	light = 15,
	lightColor = { 255, 214, 150 },
	drops = "GlowstoneDust" :: string,
	dropCount = 4,
})

--[[
	A lantern: an iron frame (bottom and top plates, four corner posts), a glowing core seen
	between the posts, a cap and a handle (Minecraft's 6 x 7 x 6 body under a 4 x 2 x 4 top).
	Hanging, it sits a pixel higher with a chain up to the block above.
]]
local function lantern(y: number, hanging: boolean): { ShapeBox }
	local boxes: { ShapeBox } = {
		{ size = { 5, 5, 5 }, offset = { 0, y + 3.5, 0 }, color = LANTERN_GLOW, material = "Neon", glow = true },
		{ size = { 6, 1, 6 }, offset = { 0, y + 0.5, 0 } },
		{ size = { 6, 1, 6 }, offset = { 0, y + 6.5, 0 } },
		{ size = { 4, 2, 4 }, offset = { 0, y + 8, 0 } },
	}
	for _, corner in { { -2.5, -2.5 }, { 2.5, -2.5 }, { -2.5, 2.5 }, { 2.5, 2.5 } } do
		table.insert(boxes, { size = { 1, 5, 1 }, offset = { corner[1], y + 3.5, corner[2] } })
	end
	if hanging then
		-- The chain, from the cap to the ceiling.
		table.insert(boxes, { size = { 1, 6, 1 }, offset = { 0, y + 12, 0 } })
	else
		table.insert(boxes, { size = { 3, 2, 0.5 }, offset = { 0, y + 10, 0 } })
	end
	return boxes
end

table.insert(list, {
	name = "Lantern",
	color = IRON,
	material = "Metal",
	sound = "metal",
	solid = false,
	placeable = true,
	hardness = 3.5,
	tool = "pickaxe",
	toolLevel = 0,
	light = 15,
	lightColor = TORCH_LIGHT,
	shape = lantern(-8, false),
	bounds = { min = { 5, 0, 5 }, max = { 11, 9, 11 } },
	obstructs = true,
	support = "Down",
	behaviour = "Attached",
})
table.insert(list, {
	name = "HangingLantern",
	displayName = "Lantern",
	color = IRON,
	material = "Metal",
	sound = "metal",
	solid = false,
	placeable = false,
	hardness = 3.5,
	tool = "pickaxe",
	toolLevel = 0,
	light = 15,
	lightColor = TORCH_LIGHT,
	shape = lantern(-7, true),
	bounds = { min = { 5, 1, 5 }, max = { 11, 10, 11 } },
	obstructs = true,
	support = "Up",
	item = "Lantern",
	behaviour = "Attached",
})

--[[
	Mekanism's transmitters and fluid tanks (Shared/Transmitters; the tier numbers are in
	Transmitters/Tiers): Logistical Transporters (items), the Restrictive Transporter and
	Mechanical Pipes (water), Basic to Ultimate, and Basic to Ultimate Fluid Tanks.

	A transmitter's `shape` is Mekanism's 8 x 8 x 8 pixel core: a glass cube in a frame of twelve
	edges in its tier's colour (Basic dark grey, Advanced red, Elite dark aqua, Ultimate purple;
	the Restrictive Transporter orange; Mechanical Pipes have bluish grey glass). The arms towards
	what it connects to depend on the neighbours and the configured sides, so the client draws
	them over the block (Rendering/TransmitterRenderer), as it draws the items and water inside.
	Transmitters are aimed at over their whole cell (`bounds`), which makes choosing a side with
	the Configurator easy. They are not `solid`, as lanterns: the movement hull only knows full
	cubes, so players walk through them (Mekanism's have a collision box), but they `obstruct`, so
	none is placed inside a player and falling sand lands on them. They break fast (hardness 1,
	Mekanism's) and drop themselves.

	Fluid tanks are solid cubes: steel plates at the top and bottom, posts in the tier's colour at
	the corners and glass sides, through which the client's water shows. What a tank holds is lost
	when it is broken (items carry no data).
]]
local TIER_NAMES = { "Basic", "Advanced", "Elite", "Ultimate" }
local FULL_BOUNDS: Bounds = { min = { 0, 0, 0 }, max = { 16, 16, 16 } }
-- Glass of transmitters and tanks: its see-through look (the frames are opaque).
local GLASS_TRANSPARENCY = 0.5
local TRANSPORTER_GLASS = { 206, 222, 230 }
local PIPE_GLASS = { 124, 148, 172 }
local TANK_GLASS = { 190, 214, 226 }
local RESTRICTIVE = { 226, 128, 40 }
local STEEL = { 112, 116, 124 }

-- An opaque metal box in `colour` (frames).
local function metal(size: { number }, offset: { number }, colour: { number }): ShapeBox
	return { size = size, offset = offset, color = colour, material = "Metal", transparency = 0 }
end

local function glass(size: { number }, offset: { number }, colour: { number }): ShapeBox
	return { size = size, offset = offset, color = colour, material = "Glass", transparency = GLASS_TRANSPARENCY }
end

--[[
	A transmitter's core, 8 pixels wide: the glass cube first, then the twelve frame edges, a pixel
	thick. The X edges run the whole length; the Y and Z edges fit between them, so no two boxes
	share a face.
]]
local function transmitterCore(frame: { number }, glassColour: { number }): { ShapeBox }
	local boxes: { ShapeBox } = { glass({ 7, 7, 7 }, { 0, 0, 0 }, glassColour) }
	for _, a in { -3.5, 3.5 } do
		for _, b in { -3.5, 3.5 } do
			table.insert(boxes, metal({ 8, 1, 1 }, { 0, a, b }, frame))
			table.insert(boxes, metal({ 1, 6, 1 }, { a, 0, b }, frame))
			table.insert(boxes, metal({ 1, 1, 6 }, { a, b, 0 }, frame))
		end
	end
	return boxes
end

-- The item's model: the core with an arm to the west and east, each ending in a collar.
local function transmitterIcon(core: { ShapeBox }, frame: { number }, glassColour: { number }): { ShapeBox }
	local boxes = table.clone(core)
	for _, side in { -1, 1 } do
		table.insert(boxes, glass({ 3.5, 6, 6 }, { side * 5.75, 0, 0 }, glassColour))
		table.insert(boxes, metal({ 1, 7, 7 }, { side * 7.5, 0, 0 }, frame))
	end
	return boxes
end

local function transmitter(spec: BlockSpec, frame: { number }, glassColour: { number })
	local core = transmitterCore(frame, glassColour)
	spec.color = frame
	spec.material = "Metal"
	spec.transparency = GLASS_TRANSPARENCY
	spec.sound = "metal"
	spec.solid = false
	spec.placeable = true
	spec.obstructs = true
	spec.hardness = 1
	spec.tool = "pickaxe"
	spec.shape = core
	spec.icon = transmitterIcon(core, frame, glassColour)
	spec.bounds = FULL_BOUNDS
	table.insert(list, spec)
end

for tier, name in TIER_NAMES do
	transmitter({
		name = `{name}LogisticalTransporter`,
		transmitter = { kind = "item", tier = tier },
	}, Tiers.TIERS[tier].colour, TRANSPORTER_GLASS)
end
-- (Mekanism's Restrictive Transporter is a basic one that paths avoid.)
transmitter({
	name = "RestrictiveTransporter",
	transmitter = { kind = "item", tier = 1, restrictive = true },
}, RESTRICTIVE, TRANSPORTER_GLASS)
for tier, name in TIER_NAMES do
	transmitter({
		name = `{name}MechanicalPipe`,
		transmitter = { kind = "fluid", tier = tier },
	}, Tiers.TIERS[tier].colour, PIPE_GLASS)
end

-- A fluid tank: glass sides inside steel plates and four posts in the tier's colour.
local function tankShape(posts: { number }): { ShapeBox }
	local boxes: { ShapeBox } = {
		glass({ 14, 14, 14 }, { 0, 0, 0 }, TANK_GLASS),
		metal({ 16, 2, 16 }, { 0, -7, 0 }, STEEL),
		metal({ 16, 2, 16 }, { 0, 7, 0 }, STEEL),
	}
	for _, x in { -7, 7 } do
		for _, z in { -7, 7 } do
			table.insert(boxes, metal({ 2, 12, 2 }, { x, 0, z }, posts))
		end
	end
	return boxes
end

for tier, name in TIER_NAMES do
	table.insert(list, {
		name = `{name}FluidTank`,
		color = STEEL,
		material = "Metal",
		transparency = GLASS_TRANSPARENCY,
		sound = "metal",
		hardness = 2,
		tool = "pickaxe",
		-- (A solid cube, so torches may hang on it.)
		sturdy = true,
		shape = tankShape(Tiers.TIERS[tier].colour),
		bounds = FULL_BOUNDS,
		tank = { tier = tier, capacity = Tiers.TIERS[tier].tankCapacity },
	})
end

--[[
	Mekanism's osmium (Mekanism 10.4): Osmium Ore, the Block of Osmium and the Block of Raw Osmium.
	Generation/Ores places the ore, Crafting/Recipes smelts it and packs the storage blocks, and
	ItemList has Raw Osmium, the Osmium Ingot and the Osmium Nugget.

	  * Osmium Ore is stone with bluish-white specks: Granite's speckled material in a blue-grey.
	    Mekanism's numbers: hardness 3 (Minecraft's ores), a stone pickaxe or better to drop
	    anything (its needs_stone_tool tag), and it drops one Raw Osmium.
	  * Both storage blocks have Mekanism's hardness 7.5 and need a stone pickaxe too. The Block of
	    Osmium is bluish silver metal and sounds like the game's other metal blocks (Mekanism
	    leaves its resource blocks on the default stone sound); the raw block is rock.
]]
table.insert(list, {
	name = "OsmiumOre",
	color = { 138, 156, 184 },
	material = "Granite",
	hardness = 3,
	tool = "pickaxe",
	toolLevel = 1,
	drops = "RawOsmium" :: string,
})
table.insert(list, {
	name = "OsmiumBlock",
	displayName = "Block of Osmium",
	color = { 166, 188, 212 },
	material = "Metal",
	hardness = 7.5,
	tool = "pickaxe",
	toolLevel = 1,
})
table.insert(list, {
	name = "RawOsmiumBlock",
	displayName = "Block of Raw Osmium",
	color = { 118, 144, 176 },
	material = "Rock",
	hardness = 7.5,
	tool = "pickaxe",
	toolLevel = 1,
})

--[[
	Mekanism's Universal Cables (energy transmitters, Basic to Ultimate; Shared/Transmitters, the
	throughput per tier is in Transmitters/Tiers) and the Creative Energy Cube (Shared/Machines).

	A Universal Cable is Mekanism's small transmitter: a 6 pixel core (Mekanism's 5..11 box), a
	red-ish conductor in a frame of twelve edges in the tier's colour. Like every transmitter it is
	aimed at over its whole cell, not solid but obstructing, breaks fast and drops itself; the
	client draws its arms (thinner than a pipe's) towards the cables and energy blocks it joins.

	The Creative Energy Cube is Mekanism's: infinite energy, given out without limit, creative only
	(no recipe). A cube of dark steel with a magenta frame (BlockDecor "CreativeEnergyCube").
]]
local CABLE_CORE = { 176, 58, 44 }

-- A Universal Cable's core, 6 pixels wide: the conductor, then the twelve frame edges.
local function cableCore(frame: { number }): { ShapeBox }
	local boxes: { ShapeBox } = { metal({ 5, 5, 5 }, { 0, 0, 0 }, CABLE_CORE) }
	for _, a in { -2.5, 2.5 } do
		for _, b in { -2.5, 2.5 } do
			table.insert(boxes, metal({ 6, 1, 1 }, { 0, a, b }, frame))
			table.insert(boxes, metal({ 1, 4, 1 }, { a, 0, b }, frame))
			table.insert(boxes, metal({ 1, 1, 4 }, { a, b, 0 }, frame))
		end
	end
	-- (The conductor is SmoothPlastic, so it reads as a coloured core inside a metal frame.)
	boxes[1].material = "SmoothPlastic"
	return boxes
end

-- The item's model: the core with an arm to the west and east, each ending in a collar.
local function cableIcon(core: { ShapeBox }, frame: { number }): { ShapeBox }
	local boxes = table.clone(core)
	for _, side in { -1, 1 } do
		local arm = metal({ 4.5, 4, 4 }, { side * 5.25, 0, 0 }, CABLE_CORE)
		arm.material = "SmoothPlastic"
		table.insert(boxes, arm)
		table.insert(boxes, metal({ 1, 5, 5 }, { side * 7.5, 0, 0 }, frame))
	end
	return boxes
end

for tier, name in TIER_NAMES do
	local frame = Tiers.TIERS[tier].colour
	local core = cableCore(frame)
	table.insert(list, {
		name = `{name}UniversalCable`,
		color = frame,
		material = "Metal",
		sound = "metal",
		solid = false,
		placeable = true,
		obstructs = true,
		hardness = 1,
		tool = "pickaxe",
		shape = core,
		icon = cableIcon(core, frame),
		bounds = FULL_BOUNDS,
		transmitter = { kind = "energy", tier = tier },
	})
end

table.insert(list, {
	name = "CreativeEnergyCube",
	color = { 40, 38, 46 },
	material = "Metal",
	sound = "metal",
	hardness = 2,
	tool = "pickaxe",
	decor = "CreativeEnergyCube",
	machine = { kind = "creative" },
	energy = { capacity = math.huge, output = math.huge },
})

--[[
	Mekanism Generators' Heat Generator (Shared/Machines/Kinds/Generator, kind "generator"): burns
	furnace fuel, 200 J a tick of burning, into Mekanism's 160 000 J store, given out at up to
	400 J/t (twice what it makes) to cables and machines touching it. Mekanism's machine block:
	hardness 3.5 like a furnace, mined fast with a pickaxe, which it needs to drop anything. A dark
	steel casing with grilles and a fuel window (BlockDecor "HeatGenerator"; the client lights the
	window while it burns, Rendering/TransmitterModel.machineBoxes).
]]
table.insert(list, {
	name = "HeatGenerator",
	color = { 62, 64, 70 },
	material = "Metal",
	sound = "metal",
	hardness = 3.5,
	tool = "pickaxe",
	toolLevel = 0,
	decor = "HeatGenerator",
	machine = { kind = "generator" },
	energy = { capacity = 160000, output = 400 },
})

return list
