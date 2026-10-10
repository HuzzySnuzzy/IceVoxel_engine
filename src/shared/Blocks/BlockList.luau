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
	  fluid         { group, level, tickDelay } for fluids (filled in by `fluid()` below; every
	                group is a fluid of Shared/Fluids).
	  displayName   Shown in the inventory (default: the name with spaces, "OakLog" -> "Oak Log").
	  hardness      Minecraft's destroy time (0 = breaks at once). Default 1. See Shared/Mining.
	  tool          The tool that mines it fast: "pickaxe", "axe", "shovel" or "hoe" (Minecraft's
	                mineable tags).
	  toolLevel     Set when the block only drops with that tool, of at least this tier (0 wood /
	                gold, 1 stone, 2 iron, 3 diamond): Minecraft's requiresCorrectToolForDrops. It
	                also mines 3.3 times slower without it. nil: drops by hand.
	  blastResistance  Minecraft's explosion resistance (Shared/World/Explosion: each step of an
	                explosion's ray through the block costs (resistance + 0.3) x 0.3). Default
	                its hardness (Minecraft's Properties.strength(f) sets both), 3 600 000 for
	                unbreakable and creative only blocks (bedrock, structure blocks), none at all
	                for air and cave air; fluids 100 (their hardness), so an explosion in water
	                breaks nothing, but fuel 0 (it is the explosive). Minecraft's values that
	                differ from the hardness are in BLAST_RESISTANCE at the end of the list.
	  drops         Name of the item a survival player gets for breaking it (default: the block
	                itself), or false for nothing (e.g. glass, leaves).
	  dropCount     How many of `drops` (default 1).
	  maxStack      Most of its item in one slot (1..64, default 64): Mekanism's Energy Cubes
	                (Batteries) stack to 1, as their charge is in each item.
	  container     Number of item slots the block keeps (a chest's 27, a furnace's 3); breaking it
	                drops what is inside.
	  menu          What right clicking opens: "Chest", "Crafting" (a crafting table's 3 x 3 grid),
	                "Furnace", "StructureBlock" or "Jigsaw" (their settings screens).
	  decor         Faces drawn on the block's parts ("Chest", "CraftingTable", "Furnace",
	                "CreativeEnergyCube", "HeatGenerator", "ElectricFurnace", "BasicBattery",
	                "AdvancedBattery", "EliteBattery", "UltimateBattery", "OilRefinery",
	                "CombustionGenerator", "Tnt", "Nuke", "StructureBlockSave", "StructureBlockLoad",
	                "StructureBlockCorner", "StructureBlockData" and
	                "Jigsaw<Front><Top>", e.g. "JigsawNorthUp"; client Rendering/BlockDecor). Such
	                blocks are drawn one part per block.
	  sound         What breaking, placing, hitting, walking and falling on it sounds like
	                (Minecraft's SoundType; the events are `block.<sound>.break` and so on, see
	                Shared/Sounds): "stone", "wood", "gravel", "grass", "sand", "glass", "snow",
	                "metal", "wool" or "water". Default: from the material (Wood / WoodPlanks wood;
	                Grass / LeafyGrass grass; Ground / Mud / Pebble gravel, as Minecraft's dirt
	                sounds; Sand sand; Snow snow; Glass / Ice / Glacier / Neon glass; Metal /
	                DiamondPlate / CorrodedMetal / Foil metal; Fabric wool; anything else stone),
	                "water" for fluids and none for blocks that are never drawn (air).

	Light and shapes (torches, lanterns, the glow block):
	  light         Light the block gives off, 0..15 (Minecraft's luminance: torches 14, glowstone
	                (here the Glow Block) and lanterns 15). The renderer gives each such block one PointLight (on its
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
	                stand on lanterns. Torches have no collision box in either game.
	  collides      The movement hull (Shared/Movement/Hull: players, mobs, items) bumps into its
	                `bounds`, though it is not `solid` (Minecraft's collision shape: a door's 3 pixel
	                panel, Blocks.collision). Implies `obstructs`. Lanterns keep none, so players
	                walk through them as before.
	  collision     { Bounds }: the boxes the movement hull bumps into instead (pixels; they may
	                reach up to 24, half a block over the cell: a fence's post and arms, Minecraft's
	                1.5 block fence collision), also for a `solid` block, whose cell then collides
	                only there; placing into a player and line of sight go by them too.
	  fence         0..15: the sides a fence post reaches an arm to (bits: 1 North, 2 South, 4 West,
	                8 East; Minecraft's FenceBlock connections). A fence and its variants (one per
	                set of sides) form a fence group: placing and neighbours changing pick the
	                variant joining the fences and sturdy blocks beside it (Blocks.fenceConnections,
	                server Behaviours/Fence); turning a structure turns its arms.
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
	  flammable     { ignite, burn }: Minecraft's FireBlock odds (FireBlock.setFlammable). `ignite`:
	                how readily fire spreads into air next to it (0..100; > 0 also means fire
	                clings to it and lava sets it alight); `burn`: how readily a fire next to it
	                destroys it (0..100). Set by the fire bootstrap at the end of this list
	                (Minecraft's FireBlock.bootStrap: planks 5 / 20, logs 5 / 5, leaves 30 / 60,
	                plants 60 / 100...) or on the block itself. See server Behaviours/Fire.

	Climbing, hanging and lying along (ladders, rope, vines, rails, cobwebs):
	  climbable     Players and mobs climb it from inside its cell (Minecraft's #climbable tag:
	                ladders, vines; the rope too, Supplementaries'). Blocks.isClimbable;
	                Shared/Movement/PlayerPhysics.
	  chain         It also holds on under a block of its own kind (or that block's cave twin)
	                right above it, not only on its `support`: a rope hangs from the rope above
	                (Supplementaries' RopeBlock.canSurvive), a vine from the same vine above
	                (VineBlock). Blocks.canSurvive. Needs a `support`.
	  axis          "X" or "Z": the horizontal axis it runs along (rails: "Z" North-South, "X"
	                East-West). A block and its variants with an `axis` form an axis group, one
	                per axis: placing picks the one along the player's facing
	                (BaseRailBlock.getStateForPlacement), turning a structure a quarter turn
	                swaps it (Blocks.placementFor, Blocks.rotate, Blocks.axisVariant).
	  stuck         { x, y, z }: moving inside it multiplies a move by these and stops the mover
	                (Minecraft's makeStuckInBlock: a cobweb's 0.25, 0.05, 0.25), and resets the
	                fall distance. Blocks.stuckIn.

	Plants (grass, ferns, flowers, mushrooms; Minecraft's BushBlock family, see "Plants" below):
	  plant         { soil = "dirt" | "deadbush" | "mushroom"?, top = "<Name>"?, bottom = "<Name>"? }.
	                A single plant or the lower half of a tall one stands on a block of its `soil`
	                set (Blocks.mayPlaceOn, Blocks.canSurvive):
	                  "dirt"      Minecraft's DIRT tag here: Grass, DryGrass, Dirt, CoarseDirt,
	                              Podzol and Mycelium;
	                  "deadbush"  Sand and the dirt set (DeadBushBlock: sand, terracotta, dirt);
	                  "mushroom"  Mycelium or Podzol, or any sturdy opaque full block (Minecraft
	                              also needs a raw light level below 13 on the other blocks; this
	                              game has no block light levels, so that part is left out).
	                `top` names a lower half's upper half, `bottom` an upper half's lower half
	                (DoublePlantBlock). An upper half stands on its own lower half, hangs on
	                nothing (no `support`), is no item of its own (`item` names the lower half,
	                `placeable` is false) and drops nothing; the server places and removes both
	                halves together.
	  tinted        true: the plant's boxes take the foliage colour of the soil it grows on
	                (Minecraft's biome grass tint, `tintindex`): their authored green times the
	                soil's Blocks.FOLIAGE_TINTS entry (Blocks.tintLut; the mesher finds the soil).
	                Short grass, ferns and their tall forms only, whose boxes are all green.
	  foliageColor  { r, g, b } on a soil block: what tinted plants on it look like instead of their
	                authored green (which is the Grass block's). Only DryGrass has one, so savanna
	                grass matches its ground.
	  scatter       true: drawn with a per-position offset (up to 3 pixels each way) and turn about
	                the vertical axis (Minecraft's OffsetType; client rendering). The outline does
	                not move.
	  shearDrops    What Shears harvest from it: true for the block itself, or an item's name
	                (Minecraft's loot tables' `match_tool shears`: leaves, grass, ferns, dead
	                bushes). Anything else held gets the usual drops (Items.drops).
	  shearCount    How many of `shearDrops` (default 1): tall grass gives 2 short grass.
	  shearSpeed    How fast Shears mine it (default the Shears' 15, Minecraft's on leaves): 2 on
	                glow lichen (ShearsItem.getDestroySpeed).
	A plant's `shape` has at most 4 boxes: each is a Part per plant in the world.

	Structures (structure blocks, jigsaw blocks, glow lichen in caves; Shared/Structures):
	  creativeOnly  Minecraft's operator blocks (structure blocks, structure voids, jigsaws): only
	                creative players place, use and break them (at once, like every block in
	                creative); survival players can't mine them (Mining.progressPerTick is 0,
	                Minecraft's hardness -1) and they never drop (Items.drops, Items.blockDrops).
	                They are in the creative inventory and JEI.
	  structureMode The structure block mode this block shows: "save", "load", "corner" or "data"
	                (one block per mode, so everyone sees the mode; Blocks.structureMode).
	  jigsaw        { front, top }: a jigsaw block's orientation (Minecraft's FrontAndTop: front
	                Up or Down with a horizontal top, or a horizontal front with top Up; one block
	                per orientation, Blocks.jigsawOrientation / Blocks.jigsawBlock).
	  caveTwin      Name of the block this one is the cave twin of (CaveGlowLichen* of GlowLichen*,
	                CaveLava of Lava, CaveOil of Oil, and the mineshafts' rails, fence posts,
	                cobwebs, wall torches, moss carpets, vines and hanging roots, at the end of the
	                list): it looks, drops and behaves exactly like it
	                (a fluid twin is a source of the same group), but generation places it in caves
	                and the mesher treats it like cave air while caves are hidden
	                (Blocks.cullLutHiddenCaves, Blocks.caveTwinLut), as CaveAir is to Air. Players
	                never place twins; their `item` is the twin's.

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

	Textures are not set here: every block's texture per face is in the texture pack
	(Shared/TexturePack; Blocks resolves it). `color` and `material` stay the block's plain look
	(drawn while its texture is blank or textures are off, and on the map) and the colour a tinted
	texture takes.
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
-- A plant (`plant`): its soil set, and the names of its other half.
export type PlantSpec = { soil: string?, top: string?, bottom: string? }
-- A door half (`door`): the way it faces, its hinge side ("Left" / "Right"), open or not, and
-- which half (Shared/Blocks/Doors).
export type DoorSpec = { facing: string, hinge: string, open: boolean, upper: boolean }
-- A jigsaw block's orientation (`jigsaw`): the direction its front faces and its top.
export type JigsawSpec = { front: string, top: string }
-- How a block burns (`flammable`): Minecraft's ignite and burn odds.
export type FlammableSpec = { ignite: number, burn: number }

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
	blastResistance: number?,
	drops: (string | false)?,
	dropCount: number?,
	maxStack: number?,
	container: number?,
	menu: string?,
	decor: string?,
	sound: string?,
	light: number?,
	lightColor: { number }?,
	shape: { ShapeBox }?,
	bounds: Bounds?,
	obstructs: boolean?,
	collides: boolean?,
	collision: { Bounds }?,
	fence: number?,
	support: string?,
	item: string?,
	brokenByFluid: boolean?,
	transmitter: TransmitterSpec?,
	tank: TankSpec?,
	icon: { ShapeBox }?,
	machine: MachineSpec?,
	energy: EnergySpec?,
	plant: PlantSpec?,
	door: DoorSpec?,
	tinted: boolean?,
	foliageColor: { number }?,
	scatter: boolean?,
	shearDrops: (string | boolean)?,
	shearCount: number?,
	shearSpeed: number?,
	creativeOnly: boolean?,
	structureMode: string?,
	jigsaw: JigsawSpec?,
	caveTwin: string?,
	flammable: FlammableSpec?,
	climbable: boolean?,
	chain: boolean?,
	axis: string?,
	stuck: { number }?,
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
		-- Grass and ferns on it: Minecraft's savanna #BFB755 in this game's palette, a little
		-- greener than the block itself so they read against it.
		foliageColor = { 156, 160, 76 },
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
	-- (Leaves hold up no torches or lanterns: Minecraft's LeavesBlock has no support shape. Shears
	-- harvest them, as in Minecraft; otherwise they drop a sapling or sticks now and then
	-- (Items.leafDrop), and they decay once their tree has no log left (server Behaviours/Leaves).)
	{
		name = "OakLeaves",
		behaviour = "Leaves",
		color = { 68, 128, 46 },
		material = "LeafyGrass",
		hardness = 0.2,
		drops = false,
		tool = "hoe",
		sturdy = false,
		shearDrops = true,
	},
	{ name = "BirchLog", color = { 216, 212, 198 }, material = "Wood", hardness = 2, tool = "axe" },
	{
		name = "BirchLeaves",
		behaviour = "Leaves",
		color = { 112, 150, 68 },
		material = "LeafyGrass",
		hardness = 0.2,
		drops = false,
		tool = "hoe",
		sturdy = false,
		shearDrops = true,
	},
	{ name = "SpruceLog", color = { 74, 54, 34 }, material = "Wood", hardness = 2, tool = "axe" },
	{
		name = "SpruceLeaves",
		behaviour = "Leaves",
		color = { 44, 88, 56 },
		material = "LeafyGrass",
		hardness = 0.2,
		drops = false,
		tool = "hoe",
		sturdy = false,
		shearDrops = true,
	},
	{ name = "AcaciaLog", color = { 118, 108, 98 }, material = "Wood", hardness = 2, tool = "axe" },
	{
		name = "AcaciaLeaves",
		behaviour = "Leaves",
		color = { 108, 138, 40 },
		material = "LeafyGrass",
		hardness = 0.2,
		drops = false,
		tool = "hoe",
		sturdy = false,
		shearDrops = true,
	},
	{ name = "JungleLog", color = { 96, 76, 44 }, material = "Wood", hardness = 2, tool = "axe" },
	{
		name = "JungleLeaves",
		behaviour = "Leaves",
		color = { 40, 120, 30 },
		material = "LeafyGrass",
		hardness = 0.2,
		drops = false,
		tool = "hoe",
		sturdy = false,
		shearDrops = true,
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
	Every group is a fluid of Shared/Fluids (FluidList: its id, bucket, colour and light; checked at
	load), and its flow rules are server Behaviours/Fluid's RULES.
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
			light = spec.light,
			lightColor = spec.lightColor,
			solid = false,
			replaceable = true,
			placeable = level == 0,
			hardness = 100,
			blastResistance = spec.blastResistance,
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
-- (Darker than Dirt: the texture pack draws it as "darker dirt", dirt's image in this colour.)
table.insert(list, { name = "PackedMud", color = { 97, 68, 46 }, material = "Mud", hardness = 1, tool = "pickaxe" })
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
	Light sources (Minecraft's torch, wall torch, lantern and glowstone, here the blue Glow Block).
	Torches and lanterns are
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

-- The Glow Block: a full glowing cube of glow dust (Neon, blue), in place of Minecraft's glowstone
-- (the game has no Nether; its dust comes from glow lichen in caves). Minecraft's glowstone drops
-- 2-4 dust (random); here always 4, which craft back into the block. It was named "Glowstone"
-- (Blocks.RENAMED keeps saved structures that name it working).
table.insert(list, {
	name = "GlowBlock",
	displayName = "Glow Block",
	color = { 104, 168, 255 },
	material = "Neon",
	sound = "glass",
	hardness = 0.3,
	light = 15,
	lightColor = { 150, 200, 255 },
	drops = "GlowDust" :: string,
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

--[[
	Mekanism's Energized Smelter, named the Electric Furnace (Shared/Machines/Kinds/Smelter, kind
	"smelter"): smelts what a furnace smelts on 50 J a tick of work, 200 ticks an item, from
	Mekanism's 20 000 J store, which cables and machines touching it may fill in a single tick.
	Mekanism's machine block: hardness 3.5, a pickaxe to drop anything. A light steel casing with
	osmium bolts and a heating chamber window (BlockDecor "ElectricFurnace"; the client lights the
	window while it smelts, Rendering/TransmitterModel.machineBoxes).
]]
table.insert(list, {
	name = "ElectricFurnace",
	color = { 150, 154, 162 },
	material = "Metal",
	sound = "metal",
	hardness = 3.5,
	tool = "pickaxe",
	toolLevel = 0,
	decor = "ElectricFurnace",
	machine = { kind = "smelter" },
	energy = { capacity = 20000, input = 20000 },
})

--[[
	Mekanism Generators' Solar Generator, named the Solar Panel (Shared/Machines/Kinds/Solar, kind
	"solar"): makes up to 50 J a tick while the sky straight above it is open and it is day (more
	with Speed Upgrades), into Mekanism's 96 000 J store (more with Energy Upgrades), given out at
	up to 100 J/t (twice what it makes) to cables and machines touching it. Mekanism's model is no
	full cube either: a thin panel of four dark blue cells in a steel frame on a short post over a
	foot, 9 pixels tall. Like a lantern it is not solid but obstructs (the movement hull only knows
	full cubes); it is no opaque block, so the panels of a stack all see the sky. Mekanism's
	machine block: hardness 3.5, a pickaxe to drop anything.
]]
local SOLAR_CELL = { 28, 46, 104 }
local SOLAR_SHAPE: { ShapeBox } = {
	metal({ 6, 1, 6 }, { 0, -7.5, 0 }, STEEL),
	metal({ 2, 6, 2 }, { 0, -4, 0 }, STEEL),
	metal({ 16, 1, 16 }, { 0, -0.5, 0 }, { 84, 88, 96 }),
}
for _, x in { -3.75, 3.75 } do
	for _, z in { -3.75, 3.75 } do
		table.insert(
			SOLAR_SHAPE,
			{ size = { 7, 1, 7 }, offset = { x, 0.5, z }, color = SOLAR_CELL, material = "Glass", transparency = 0 }
		)
	end
end
table.insert(list, {
	name = "SolarPanel",
	color = SOLAR_CELL,
	material = "Metal",
	sound = "metal",
	solid = false,
	placeable = true,
	obstructs = true,
	hardness = 3.5,
	tool = "pickaxe",
	toolLevel = 0,
	shape = SOLAR_SHAPE,
	machine = { kind = "solar" },
	energy = { capacity = 96000, output = 100 },
})

--[[
	Mekanism's Energy Cubes, named Batteries (Shared/Machines/Kinds/Battery, kind "battery"), Basic
	to Ultimate: Mekanism's EnergyCubeTier stores (4, 16, 64 and 256 MJ) and rates (4, 16, 64 and
	256 kJ/t), the same in and out (Transmitters/Tiers), so they are storage: the energy networks
	charge them with what generators have left over and draw on them when generators fall short,
	the backup. Mekanism's machine block: hardness 3.5, a pickaxe to drop anything; its item keeps
	its charge, so it stacks to 1 (Mekanism's energy cubes do). A dark steel cube with corners in
	the tier's colour (Mekanism's energy cube frame), a charge gauge on each side and a terminal on
	top (BlockDecor "<Tier>Battery"; the client fills the gauges from the machine's record,
	Rendering/TransmitterModel.machineBoxes).
]]
for tier, name in TIER_NAMES do
	local numbers = Tiers.TIERS[tier]
	table.insert(list, {
		name = `{name}Battery`,
		color = { 52, 54, 60 },
		material = "Metal",
		sound = "metal",
		hardness = 3.5,
		tool = "pickaxe",
		toolLevel = 0,
		maxStack = 1,
		decor = `{name}Battery`,
		machine = { kind = "battery" },
		energy = { capacity = numbers.batteryCapacity, input = numbers.batteryRate, output = numbers.batteryRate },
	})
end

--[[
	Plants: Minecraft 1.20.1's ground foliage (BushBlock and its family). Short grass ("Grass" is
	the grass block here; 1.20.3's name), ferns and their two block tall forms, the dead bush, the
	twelve flowers, the four tall flowers and both mushrooms.

	Every plant is shaped, not solid, breaks at once, sounds like grass, is washed away by flowing
	water (and drops), stands on its soil (`plant`, `support` "Down") and is kept up by the
	server's Plant behaviour. Tall plants are two blocks: the lower half is the item, the upper
	half names it (`item`) and drops nothing. Short grass, ferns, their tall forms and the dead bush
	are replaceable, as in Minecraft 1.20; flowers and mushrooms are not.

	Minecraft draws plants as crossed textured quads. Here they are a few thin boxes each (pixels
	from the cell's centre, the ground at y = -8) until their Sprite texture is filled in
	(Shared/TexturePack: the client then draws two crossed images instead, with textures on), and
	every box is one Part per plant in the world: at most 4, 3 on the common ones. Blades and
	fronds lean out in different directions in a few shades of green; flowers are a thin stem
	with a head in Minecraft's colours. Plants are drawn at a scattered offset and turn
	(`scatter`), so every box stays inside 2..14 (grass, ferns, dead bushes and tall plants) or
	5..11 (flowers and mushrooms) whichever way it is turned, and at most a pixel out of its cell
	after the offset of up to 3 pixels (like a wall torch's foot). Those are Minecraft's outlines
	too, aimed at and highlighted, except for tall plants: DoublePlantBlock keeps a block's default
	shape, so each half is aimed at and outlined as a full block.

	Tall grass gives 2 short grass with Shears and large ferns 2 ferns; short grass, ferns and dead
	bushes give themselves, and nothing (a dead bush a stick) without. Flowers and mushrooms always
	drop themselves.
]]
local SMOOTH = "SmoothPlastic"
local GROUND = -8
-- (Minecraft's outlines.)
local GRASS_BOUNDS: Bounds = { min = { 2, 0, 2 }, max = { 14, 13, 14 } }
-- (Both halves of a tall plant: a full block, DoublePlantBlock has no shape of its own.)
local TALL_BOUNDS: Bounds = FULL_BOUNDS
local FLOWER_BOUNDS: Bounds = { min = { 5, 0, 5 }, max = { 11, 10, 11 } }
local MUSHROOM_BOUNDS: Bounds = { min = { 5, 0, 5 }, max = { 11, 6, 11 } }

-- Greens of grass and ferns: the Grass block's and a shade darker and lighter (they are tinted by
-- the soil's foliage colour, so this is how they look on Grass).
local GRASS = { 92, 158, 62 }
local GRASS_DARK = { 72, 134, 48 }
local GRASS_LIGHT = { 118, 178, 76 }
local FERN = { 74, 140, 54 }
local FERN_DARK = { 58, 118, 44 }
local FERN_LIGHT = { 96, 160, 64 }
-- Flower stems and leaves (not tinted).
local STEM = { 70, 126, 42 }
local LEAF = { 60, 114, 38 }
local LEAF_LIGHT = { 88, 146, 54 }

-- The unit vector `lean` degrees from upright towards `facing` (degrees about the vertical axis
-- from east: 0 = east (+X), 90 = south (+Z)).
local function leaning(lean: number, facing: number): { number }
	local t, f = math.rad(lean), math.rad(facing)
	return { math.cos(f) * math.sin(t), math.cos(t), math.sin(f) * math.sin(t) }
end

-- The point `distance` pixels from `from` along a blade leaning `lean` towards `facing`.
local function along(from: { number }, lean: number, facing: number, distance: number): { number }
	local d = leaning(lean, facing)
	return { from[1] + d[1] * distance, from[2] + d[2] * distance, from[3] + d[3] * distance }
end

--[[
	A thin box from `foot` ({ x, y, z }) leaning `lean` degrees from upright towards `facing`:
	`size` = { width, length, thickness }. Its foot stays put whatever the lean:
	CFrame.Angles(0, 180 - facing, lean) leans it about its own Z axis, then turns it. `flat`: its
	broad face looks out and up (a leaf); otherwise the lean is in the plane of its broad face, so
	the splay of grass blades and fronds shows from the side.
]]
local function slat(
	foot: { number },
	size: { number },
	lean: number,
	facing: number,
	colour: { number },
	flat: boolean
): ShapeBox
	return {
		size = if flat then { size[3], size[2], size[1] } else { size[1], size[2], size[3] },
		offset = along(foot, lean, facing, size[2] / 2),
		rotation = { 0, 180 - facing, lean },
		color = colour,
		material = SMOOTH,
	}
end

-- A grass blade, frond, stem or twig: leaning in the plane of its broad face.
local function blade(foot: { number }, size: { number }, lean: number, facing: number, colour: { number }): ShapeBox
	return slat(foot, size, lean, facing, colour, false)
end

-- A leaf: its broad face looks out and up.
local function leaf(foot: { number }, size: { number }, lean: number, facing: number, colour: { number }): ShapeBox
	return slat(foot, size, lean, facing, colour, true)
end

-- The length of a blade `width` wide from `foot` whose highest corner is at `top` (a tall plant's
-- lower half reaching the top of its cell, where the upper half carries on).
local function reaching(foot: { number }, top: number, lean: number, width: number): number
	local t = math.rad(lean)
	return (top - foot[2] - width / 2 * math.sin(t)) / math.cos(t)
end

-- A box at `offset` (a flower head, a cap, a bush), turned by `rotation` (degrees, CFrame.Angles
-- order).
local function lump(size: { number }, offset: { number }, colour: { number }, rotation: { number }?): ShapeBox
	return { size = size, offset = offset, rotation = rotation, color = colour, material = SMOOTH }
end

-- Everything plants share (see above). Upper halves are no item, hang on nothing and drop nothing.
-- A plant with `placeable = false` is no item of its own either: an item of ItemList places it
-- (`places`: the herbs, planted by their leaves and roots).
local function plant(spec: BlockSpec)
	local info = spec.plant :: PlantSpec
	local upper = info.bottom ~= nil
	spec.material = spec.material or SMOOTH
	spec.solid = false
	spec.placeable = not upper and spec.placeable ~= false
	spec.hardness = 0
	spec.sound = "grass"
	spec.brokenByFluid = true
	spec.behaviour = spec.behaviour or "Plant"
	spec.scatter = true
	if upper then
		spec.item = info.bottom
		spec.drops = false
	else
		spec.support = "Down"
	end
	assert(spec.shape and #spec.shape <= 4, `Plant {spec.name} has more than 4 boxes`)
	table.insert(list, spec)
end

--[[ Grass and ferns ]]

-- The point on the ground `distance` pixels from the middle, away from `facing`: blades whose foot
-- is a pixel behind the middle cross at the root, like a tuft.
local function behind(facing: number, distance: number): { number }
	return along({ 0, GROUND, 0 }, 90, facing + 180, distance)
end

-- Short grass: three blades crossing at the root and splaying out, 9 to 12 pixels tall.
plant({
	name = "ShortGrass",
	displayName = "Short Grass",
	color = GRASS,
	replaceable = true,
	tinted = true,
	plant = { soil = "dirt" },
	shape = {
		blade(behind(15, 1), { 2.4, 12.5, 0.4 }, 28, 15, GRASS),
		blade(behind(140, 1), { 2, 13, 0.4 }, 20, 140, GRASS_LIGHT),
		blade(behind(255, 1), { 2.2, 10.5, 0.4 }, 34, 255, GRASS_DARK),
	},
	bounds = GRASS_BOUNDS,
	shearDrops = true,
	drops = false,
})

-- A fern: an upright frond and two broad ones arching out low, their faces up.
plant({
	name = "Fern",
	color = FERN,
	replaceable = true,
	tinted = true,
	plant = { soil = "dirt" },
	shape = {
		blade(behind(100, 0.8), { 3, 12, 0.4 }, 12, 100, FERN),
		leaf({ 0, GROUND, 0 }, { 3, 8.5, 0.4 }, 40, 330, FERN_LIGHT),
		leaf({ 0, GROUND, 0 }, { 2.8, 7.8, 0.4 }, 46, 210, FERN_DARK),
	},
	bounds = GRASS_BOUNDS,
	shearDrops = true,
	drops = false,
})

--[[
	A tall plant's blades fan out from the middle like a vase: the lower half's from the ground to
	the top of the cell, and the upper half's carry on from where they end (the same place one cell
	up: both halves are drawn at the lower half's offset), leaning further out.
]]
type TallBlade = {
	facing: number,
	lean: number,
	width: number,
	colour: { number },
	-- The upper half's part: its length, lean, width and colour, and whether it is a leaf (face
	-- up, a fern's arching frond).
	length: number,
	topLean: number,
	topWidth: number,
	topColour: { number },
	flat: boolean?,
}
local function tallBlades(blades: { TallBlade }): ({ ShapeBox }, { ShapeBox })
	local lower, upper = {}, {}
	for _, b in blades do
		-- (Half a pixel behind the middle, so the blades cross at the root.)
		local foot = behind(b.facing, 0.5)
		local length = reaching(foot, 8, b.lean, b.width)
		local top = along(foot, b.lean, b.facing, length)
		table.insert(lower, blade(foot, { b.width, length, 0.4 }, b.lean, b.facing, b.colour))
		local size = { b.topWidth, b.length, 0.4 }
		local start = { top[1], GROUND, top[3] }
		table.insert(upper, slat(start, size, b.topLean, b.facing, b.topColour, b.flat == true))
	end
	return lower, upper
end

local tallGrass, tallGrassTop = tallBlades({
	{
		facing = 30,
		lean = 10,
		width = 2.4,
		colour = GRASS,
		length = 13,
		topLean = 11,
		topWidth = 2,
		topColour = GRASS_LIGHT,
	},
	{
		facing = 150,
		lean = 8,
		width = 2.2,
		colour = GRASS_DARK,
		length = 12,
		topLean = 15,
		topWidth = 1.8,
		topColour = GRASS,
	},
	{
		facing = 270,
		lean = 9,
		width = 2.4,
		colour = GRASS_LIGHT,
		length = 14,
		topLean = 11,
		topWidth = 2,
		topColour = GRASS_DARK,
	},
})

local largeFern, largeFernTop = tallBlades({
	{
		facing = 10,
		lean = 8,
		width = 3,
		colour = FERN,
		length = 12.5,
		topLean = 11,
		topWidth = 2.6,
		topColour = FERN_LIGHT,
	},
	{
		facing = 130,
		lean = 8,
		width = 2.8,
		colour = FERN_DARK,
		length = 5.8,
		topLean = 36,
		topWidth = 2.6,
		topColour = FERN,
		flat = true,
	},
	{
		facing = 250,
		lean = 8,
		width = 3,
		colour = FERN_LIGHT,
		length = 5.8,
		topLean = 36,
		topWidth = 2.6,
		topColour = FERN_DARK,
		flat = true,
	},
})

-- Their items: the lower half with shorter blades fanning out of it, like the upper half's.
local function tallIcon(lower: { ShapeBox }, extra: { ShapeBox }): { ShapeBox }
	local icon = table.clone(lower)
	for _, box in extra do
		table.insert(icon, box)
	end
	return icon
end

plant({
	name = "TallGrass",
	displayName = "Tall Grass",
	color = GRASS,
	replaceable = true,
	tinted = true,
	plant = { soil = "dirt", top = "TallGrassTop" },
	shape = tallGrass,
	icon = tallIcon(tallGrass, {
		blade({ 0, -3, 0 }, { 2, 10, 0.4 }, 34, 90, GRASS_LIGHT),
		blade({ 0, -4, 0 }, { 2, 10, 0.4 }, 36, 200, GRASS),
		blade({ 0, -2, 0 }, { 1.8, 9, 0.4 }, 30, 320, GRASS_DARK),
	}),
	bounds = TALL_BOUNDS,
	shearDrops = "ShortGrass",
	shearCount = 2,
	drops = false,
})
plant({
	name = "TallGrassTop",
	displayName = "Tall Grass",
	color = GRASS,
	replaceable = true,
	tinted = true,
	plant = { bottom = "TallGrass" },
	shape = tallGrassTop,
	bounds = TALL_BOUNDS,
})
plant({
	name = "LargeFern",
	displayName = "Large Fern",
	color = FERN,
	replaceable = true,
	tinted = true,
	plant = { soil = "dirt", top = "LargeFernTop" },
	shape = largeFern,
	icon = tallIcon(largeFern, {
		leaf({ 0, -1, 0 }, { 3, 8, 0.4 }, 48, 90, FERN_LIGHT),
		leaf({ 0, -2, 0 }, { 3, 8, 0.4 }, 50, 200, FERN),
		blade({ 0, -3, 0 }, { 2.6, 10, 0.4 }, 32, 320, FERN_DARK),
	}),
	bounds = TALL_BOUNDS,
	shearDrops = "Fern",
	shearCount = 2,
	drops = false,
})
plant({
	name = "LargeFernTop",
	displayName = "Large Fern",
	color = FERN,
	replaceable = true,
	tinted = true,
	plant = { bottom = "LargeFern" },
	shape = largeFernTop,
	bounds = TALL_BOUNDS,
})

--[[ The dead bush: brown twigs, a main one and three splaying out (one a branch off it) ]]

local TWIG = { 124, 88, 44 }
local TWIG_DARK = { 100, 70, 36 }
local TWIG_LIGHT = { 146, 108, 60 }
plant({
	name = "DeadBush",
	displayName = "Dead Bush",
	color = TWIG,
	replaceable = true,
	plant = { soil = "deadbush" },
	shape = {
		blade({ 0, GROUND, 0 }, { 0.8, 11.5, 0.8 }, 8, 100, TWIG),
		blade({ 0.2, GROUND, 0.1 }, { 0.7, 8.5, 0.7 }, 40, 15, TWIG_DARK),
		blade({ -0.1, GROUND, 0.1 }, { 0.7, 8, 0.7 }, 42, 150, TWIG_LIGHT),
		blade(along({ 0, GROUND, 0 }, 8, 100, 4.5), { 0.6, 6.5, 0.6 }, 40, 255, TWIG),
	},
	bounds = GRASS_BOUNDS,
	shearDrops = true,
	drops = "Stick" :: string,
})

--[[
	Flowers: a stem with a leaf or two and a head in Minecraft's colours, up to 10 pixels tall
	(Minecraft's 5..11 outline). Heads are two crossed boxes or one turned 45 degrees, so they look
	round from every side.
]]

local function stem(height: number, lean: number?, facing: number?): ShapeBox
	return blade({ 0, GROUND, 0 }, { 0.8, height, 0.8 }, lean or 0, facing or 0, STEM)
end

local function flower(name: string, colour: { number }, shape: { ShapeBox }, displayName: string?)
	plant({
		name = name,
		displayName = displayName,
		color = colour,
		plant = { soil = "dirt" },
		shape = shape,
		bounds = FLOWER_BOUNDS,
	})
end

local DANDELION = { 255, 216, 36 }
flower("Dandelion", DANDELION, {
	stem(6),
	leaf({ 0, GROUND, 0 }, { 1.4, 3.2, 0.4 }, 58, 30, LEAF),
	lump({ 3.2, 2, 2.2 }, { 0, -1.2, 0 }, DANDELION, { 0, 20, 0 }),
	lump({ 2.2, 2.4, 3.2 }, { 0, -1.2, 0 }, { 246, 196, 30 }, { 0, 20, 0 }),
})

local POPPY = { 214, 34, 30 }
flower("Poppy", POPPY, {
	stem(7, 4, 0),
	leaf({ 0, -6.5, 0 }, { 1.4, 3.4, 0.4 }, 50, 220, LEAF),
	lump({ 3.6, 2.6, 3.6 }, { 0.3, 0.1, 0 }, POPPY, { 0, 30, 0 }),
	-- The dark middle, seen from above.
	lump({ 1.3, 0.3, 1.3 }, { 0.3, 1.5, 0 }, { 44, 36, 20 }, { 0, 30, 0 }),
})

-- The blue orchid: a star of bright blue petals, two crossed and tilted.
local ORCHID = { 40, 168, 228 }
local orchidTop = along({ 0, GROUND, 0 }, 6, 300, 6.5)
flower("BlueOrchid", ORCHID, {
	stem(6.5, 6, 300),
	leaf({ 0, GROUND, 0 }, { 1.2, 4, 0.4 }, 30, 120, LEAF),
	lump({ 3.8, 1, 1.4 }, { orchidTop[1], orchidTop[2] + 0.3, orchidTop[3] }, ORCHID, { 0, 20, 18 }),
	lump({ 1.4, 1.2, 3.8 }, { orchidTop[1], orchidTop[2] + 0.6, orchidTop[3] }, { 96, 200, 244 }, { -15, 20, 0 }),
}, "Blue Orchid")

local ALLIUM = { 166, 92, 212 }
flower("Allium", ALLIUM, {
	stem(7.5),
	leaf({ 0, GROUND, 0 }, { 1, 4.5, 0.35 }, 28, 160, LEAF),
	lump({ 3.6, 2.4, 3.6 }, { 0, 0.25, 0 }, ALLIUM),
	lump({ 2.6, 3.4, 2.6 }, { 0, 0.25, 0 }, { 192, 132, 230 }, { 0, 45, 0 }),
})

-- The azure bluet: a pale stem with a white flower and its yellow middle, and a bud lower down.
local BLUET_STEM = { 116, 146, 98 }
local WHITE = { 236, 240, 238 }
local bluetTop = along({ 0, GROUND, 0 }, 6, 30, 5.6)
flower("AzureBluet", WHITE, {
	blade({ 0, GROUND, 0 }, { 0.6, 5.6, 0.6 }, 6, 30, BLUET_STEM),
	lump({ 2.6, 0.8, 2.6 }, { bluetTop[1], bluetTop[2] + 0.2, bluetTop[3] }, WHITE, { 0, 45, 0 }),
	lump({ 1, 0.4, 1 }, { bluetTop[1], bluetTop[2] + 0.7, bluetTop[3] }, { 232, 204, 70 }, { 0, 45, 0 }),
	lump({ 1.8, 0.7, 1.8 }, { -1, -4.2, 0.6 }, { 226, 232, 236 }, { 0, 20, 0 }),
}, "Azure Bluet")

-- Tulips: a cup on a stem between two long leaves.
local function tulip(name: string, colour: { number })
	flower(name, colour, {
		stem(6),
		leaf({ 0, GROUND, 0 }, { 1.6, 5, 0.4 }, 22, 45, LEAF),
		leaf({ 0, GROUND, 0 }, { 1.6, 4.4, 0.4 }, 26, 225, LEAF_LIGHT),
		lump({ 2.6, 3.4, 2.6 }, { 0, -0.6, 0 }, colour, { 0, 45, 0 }),
	})
end
tulip("RedTulip", { 212, 42, 34 })
tulip("OrangeTulip", { 240, 128, 36 })
tulip("WhiteTulip", { 234, 238, 234 })
tulip("PinkTulip", { 238, 162, 198 })

flower("OxeyeDaisy", WHITE, {
	stem(6.5),
	leaf({ 0, GROUND, 0 }, { 1.4, 3.2, 0.4 }, 50, 300, LEAF),
	lump({ 4, 0.9, 4 }, { 0, -0.8, 0 }, { 242, 242, 238 }, { 12, 45, 0 }),
	lump({ 1.6, 0.5, 1.6 }, { 0, -0.25, 0.1 }, { 236, 196, 40 }, { 12, 45, 0 }),
}, "Oxeye Daisy")

local CORNFLOWER = { 70, 104, 228 }
flower("Cornflower", CORNFLOWER, {
	stem(6.5),
	leaf({ 0, GROUND, 0 }, { 1, 4.2, 0.35 }, 30, 70, LEAF),
	lump({ 3, 1.8, 3 }, { 0, -1, 0 }, CORNFLOWER, { 0, 45, 0 }),
	lump({ 1.8, 2.6, 1.8 }, { 0, -0.2, 0 }, { 50, 78, 200 }),
})

-- Lily of the valley: two broad upright leaves and an arching stem with white bells under its tip.
local LILY_LEAF = { 62, 130, 48 }
local lilyTop = along({ 0, GROUND, 0 }, 15, 100, 7)
flower("LilyOfTheValley", WHITE, {
	blade({ -0.4, GROUND, 0.2 }, { 2.2, 7.5, 0.4 }, 8, 200, LILY_LEAF),
	blade({ 0.4, GROUND, -0.2 }, { 2, 6.5, 0.4 }, 12, 20, LEAF_LIGHT),
	blade({ 0, GROUND, 0 }, { 0.5, 7, 0.5 }, 15, 100, STEM),
	-- (A row of bells along the arch, hanging under it.)
	lump({ 1.2, 1.4, 2.4 }, { lilyTop[1] * 0.8, lilyTop[2] - 1.1, lilyTop[3] * 0.75 }, { 244, 246, 240 }, { 0, 10, 0 }),
}, "Lily of the Valley")

--[[
	Tall flowers: two blocks like tall grass. The sunflower's yellow disc with its brown middle
	faces east and a little up, as in Minecraft; the lilac and the peony are leafy bushes with pale
	purple and pink blossoms on top, the rose bush a dark green bush dotted with red roses. Their
	items show the lower half with the top's blossoms (Minecraft's item uses the top half's
	texture), fitted in one cell; the sunflower's head faces the viewer there.
]]

local SUN_PETALS = { 252, 200, 32 }
local SUN_MIDDLE = { 96, 60, 28 }
local SUN_TILT = 22.5

-- The sunflower's head: a disc (two crossed rectangles, a pixel-art circle) and its middle, centred
-- at `centre`, facing east (+X) or towards -Z (the item), tilted up.
local function sunflowerHead(centre: { number }, east: boolean): { ShapeBox }
	local x, y, z = centre[1], centre[2], centre[3]
	local t = math.rad(SUN_TILT)
	if east then
		local rotation = { 0, 0, SUN_TILT }
		return {
			lump({ 0.8, 9, 6.4 }, centre, SUN_PETALS, rotation),
			lump({ 0.8, 6.4, 9 }, centre, SUN_PETALS, rotation),
			lump({ 0.8, 3.6, 3.6 }, { x + 0.6 * math.cos(t), y + 0.6 * math.sin(t), z }, SUN_MIDDLE, rotation),
		}
	end
	local rotation = { SUN_TILT, 0, 0 }
	return {
		lump({ 6.4, 9, 0.8 }, centre, SUN_PETALS, rotation),
		lump({ 9, 6.4, 0.8 }, centre, SUN_PETALS, rotation),
		lump({ 3.6, 3.6, 0.8 }, { x, y + 0.6 * math.sin(t), z - 0.6 * math.cos(t) }, SUN_MIDDLE, rotation),
	}
end

-- Adds a tall flower's halves from their boxes; its item shows the lower half and then `extra`.
local function tallFlower(
	name: string,
	colour: { number },
	lower: { ShapeBox },
	upper: { ShapeBox },
	extra: { ShapeBox },
	displayName: string?
)
	plant({
		name = name,
		displayName = displayName,
		color = colour,
		plant = { soil = "dirt", top = name .. "Top" },
		shape = lower,
		icon = tallIcon(lower, extra),
		bounds = TALL_BOUNDS,
	})
	plant({
		name = name .. "Top",
		displayName = displayName or name,
		color = colour,
		plant = { bottom = name },
		shape = upper,
		bounds = TALL_BOUNDS,
	})
end

-- (The stem leans a little east, under the head.)
local sunStemTop = along({ 0, GROUND, 0 }, 12, 0, 8.5)
local sunflowerTop = { blade({ 0, GROUND, 0 }, { 1.2, 8.5, 1.2 }, 12, 0, STEM) }
for _, box in sunflowerHead({ sunStemTop[1] + 0.5, sunStemTop[2] + 1, 0 }, true) do
	table.insert(sunflowerTop, box)
end
tallFlower("Sunflower", SUN_PETALS, {
	blade({ 0, GROUND, 0 }, { 1.2, 16, 1.2 }, 0, 0, STEM),
	leaf({ 0, -3, 0 }, { 2.4, 5.5, 0.4 }, 55, 160, LEAF),
	leaf({ 0, 2, 0 }, { 2.2, 5, 0.4 }, 50, 340, LEAF_LIGHT),
}, sunflowerTop, sunflowerHead({ 0, 3.4, -0.9 }, false))

-- Bushes: leafy masses of a few sizes, side by side and a little tilted, so their outline is
-- uneven; the upper half's lowest mass reaches down to the lower half's.
local BUSH_LEAVES = { 70, 124, 46 }
local BUSH_LEAVES_LIGHT = { 90, 146, 58 }
local ROSE_LEAVES = { 44, 100, 36 }
local ROSE_LEAVES_LIGHT = { 58, 120, 44 }

local function bushLower(leaves: { number }, light: { number }): { ShapeBox }
	return {
		lump({ 6, 9, 6 }, { -1, -3.5, 0.6 }, leaves, { 0, 25, 8 }),
		lump({ 5.4, 8, 5.4 }, { 1.3, 3.2, -0.8 }, light, { -8, 65, 0 }),
	}
end

local function bushUpper(leaves: { number }): ShapeBox
	return lump({ 6, 7.4, 6 }, { -0.5, -4.4, 0.4 }, leaves, { 8, 35, 0 })
end

local LILAC = { 196, 148, 212 }
local LILAC_LIGHT = { 220, 180, 232 }
local lilacLower = bushLower(BUSH_LEAVES, BUSH_LEAVES_LIGHT)
table.insert(lilacLower, leaf({ 0, -6, 0 }, { 2.6, 5, 0.5 }, 50, 120, BUSH_LEAVES_LIGHT))
tallFlower("Lilac", LILAC, lilacLower, {
	bushUpper(BUSH_LEAVES),
	lump({ 4.6, 6.5, 4.6 }, { 0.6, -0.4, -0.4 }, LILAC, { 0, 15, -8 }),
	lump({ 3.4, 5, 3.4 }, { -0.5, 3.4, 0.6 }, LILAC_LIGHT, { 10, 60, 0 }),
	leaf({ 0.5, -4, -0.5 }, { 2.4, 4.5, 0.5 }, 55, 300, BUSH_LEAVES_LIGHT),
}, {
	lump({ 5.8, 4.4, 5.8 }, { 1.2, 5.4, -0.6 }, LILAC, { 0, 40, 0 }),
	lump({ 3.6, 3, 3.6 }, { 0.8, 6.4, -0.4 }, LILAC_LIGHT, { 0, 70, 0 }),
})

local ROSE = { 206, 28, 34 }
local function rose(offset: { number }): ShapeBox
	return lump({ 1.6, 1.6, 1.6 }, offset, ROSE, { 0, 20, 0 })
end
local roseLower = bushLower(ROSE_LEAVES, ROSE_LEAVES_LIGHT)
table.insert(roseLower, rose({ 2.4, -4, 2.6 }))
table.insert(roseLower, rose({ -2.6, 4.4, -1.6 }))
tallFlower("RoseBush", ROSE, roseLower, {
	bushUpper(ROSE_LEAVES),
	lump({ 4.6, 5, 4.6 }, { 0.8, 0.4, -0.5 }, ROSE_LEAVES_LIGHT, { 0, 10, -10 }),
	rose({ -3, -3, 2 }),
	rose({ 1.6, 2.6, 1.4 }),
}, { rose({ 1, 7.4, -0.6 }) }, "Rose Bush")

local PEONY = { 236, 176, 220 }
local PEONY_LIGHT = { 248, 206, 236 }
local peonyLower = bushLower(BUSH_LEAVES_LIGHT, BUSH_LEAVES)
table.insert(peonyLower, leaf({ 0, -6, 0 }, { 2.6, 5, 0.5 }, 50, 300, BUSH_LEAVES))
tallFlower("Peony", PEONY, peonyLower, {
	bushUpper(BUSH_LEAVES_LIGHT),
	lump({ 5.4, 4, 5.4 }, { 0.6, -0.8, -0.4 }, PEONY, { 10, 15, -6 }),
	lump({ 4, 3.4, 4 }, { -0.6, 1.8, 0.5 }, PEONY_LIGHT, { -8, 55, 0 }),
	leaf({ 0.5, -4, -0.5 }, { 2.4, 4.5, 0.5 }, 55, 120, BUSH_LEAVES),
}, {
	lump({ 5.8, 3.6, 5.8 }, { 1.2, 5.8, -0.6 }, PEONY, { 0, 15, 0 }),
	lump({ 3.6, 2.4, 3.6 }, { 0.6, 6.6, -0.2 }, PEONY_LIGHT, { 0, 55, 0 }),
})

--[[
	Mushrooms: a short pale stem under a cap, the brown one flat and wide (two crossed slabs, a
	pixel-art circle), the red one domed with a white spot. Minecraft's brown mushroom gives off a
	little light (1); this one gives none.
]]
local function mushroom(name: string, colour: { number }, shape: { ShapeBox }, displayName: string)
	plant({
		name = name,
		displayName = displayName,
		color = colour,
		plant = { soil = "mushroom" },
		shape = shape,
		bounds = MUSHROOM_BOUNDS,
	})
end

local BROWN_CAP = { 152, 112, 84 }
mushroom("BrownMushroom", BROWN_CAP, {
	lump({ 1.6, 3.6, 1.6 }, { 0, -6.2, 0 }, { 212, 196, 164 }),
	lump({ 4.8, 1.4, 3.2 }, { 0, -3.8, 0 }, BROWN_CAP),
	lump({ 3.2, 1.4, 4.8 }, { 0, -3.8, 0 }, BROWN_CAP),
}, "Brown Mushroom")

local RED_CAP = { 200, 36, 32 }
mushroom("RedMushroom", RED_CAP, {
	lump({ 1.6, 3.4, 1.6 }, { 0, -6.3, 0 }, { 228, 220, 206 }),
	lump({ 4.2, 1.6, 4.2 }, { 0, -4.4, 0 }, RED_CAP, { 0, 45, 0 }),
	lump({ 2.8, 1.2, 2.8 }, { 0, -3.1, 0 }, RED_CAP),
	lump({ 0.9, 0.3, 0.9 }, { 0.5, -2.4, -0.4 }, { 246, 240, 232 }),
}, "Red Mushroom")

--[[
	Structures (Shared/Structures; server Structures, client screens): Minecraft 1.20.1's structure
	block, structure void and jigsaw block, creative only (`creativeOnly`).

	A structure block's mode is its block: StructureBlock (SAVE, the item), StructureBlockLoad,
	StructureBlockCorner and StructureBlockData, so the server swaps the block when the mode changes
	and everyone sees the mode's icon (BlockDecor "StructureBlock<Mode>": Minecraft's dark purple
	grey block with the mode's sigil on every face). Minecraft places a new one in DATA mode
	(StructureBlock.getStateForPlacement); here it is placed in SAVE mode, which is what a builder
	wants first. Right clicking opens its screen (`menu`).

	The structure void is Minecraft's: not solid, replaceable, saved as "keep" (whatever is in the
	world stays there when the structure is placed). Minecraft draws nothing; here it is a small
	translucent box (6 pixels, its outline too) so builders see where they put one.

	A jigsaw block's orientation is its block (Minecraft's FrontAndTop, 12 states): Jigsaw (front
	North, top Up; the item) and Jigsaw<Front><Top> for the other eleven. Its faces are Minecraft's
	(BlockDecor "Jigsaw<Front><Top>"): the front shows the puzzle piece with its knob towards the
	top, the face towards the top a bar from the front's edge (the "lock"), the back is plain and
	the other three faces have arrows pointing at the front. Placing one picks the orientation from
	the clicked face and the way the player looks (Blocks.placementFor).
]]
local STRUCTURE_COLOUR = { 38, 29, 42 }
for _, mode in { "Save", "Load", "Corner", "Data" } do
	local item = mode == "Save"
	table.insert(list, {
		name = if item then "StructureBlock" else `StructureBlock{mode}`,
		displayName = "Structure Block",
		color = STRUCTURE_COLOUR,
		material = "SmoothPlastic",
		sound = "stone",
		creativeOnly = true,
		placeable = item,
		item = if item then nil else "StructureBlock",
		drops = false,
		menu = "StructureBlock",
		decor = `StructureBlock{mode}`,
		structureMode = string.lower(mode),
	})
end

table.insert(list, {
	name = "StructureVoid",
	displayName = "Structure Void",
	color = { 52, 156, 168 },
	material = "SmoothPlastic",
	transparency = 0.45,
	sound = "stone",
	solid = false,
	replaceable = true,
	placeable = true,
	creativeOnly = true,
	drops = false,
	shape = { { size = { 6, 6, 6 }, offset = { 0, 0, 0 } } },
	bounds = { min = { 5, 5, 5 }, max = { 11, 11, 11 } },
})

-- Minecraft's FrontAndTop: the four horizontal fronts (top Up), then front Up and front Down with
-- each horizontal top. The first is the item.
local JIGSAW_ORIENTATIONS = {
	{ "North", "Up" },
	{ "South", "Up" },
	{ "West", "Up" },
	{ "East", "Up" },
	{ "Up", "North" },
	{ "Up", "South" },
	{ "Up", "West" },
	{ "Up", "East" },
	{ "Down", "North" },
	{ "Down", "South" },
	{ "Down", "West" },
	{ "Down", "East" },
}
for index, orientation in JIGSAW_ORIENTATIONS do
	local front, top = orientation[1], orientation[2]
	local item = index == 1
	table.insert(list, {
		name = if item then "Jigsaw" else `Jigsaw{front}{top}`,
		displayName = "Jigsaw Block",
		color = STRUCTURE_COLOUR,
		material = "SmoothPlastic",
		sound = "stone",
		creativeOnly = true,
		placeable = item,
		item = if item then nil else "Jigsaw",
		drops = false,
		menu = "Jigsaw",
		decor = `Jigsaw{front}{top}`,
		jigsaw = { front = front, top = top },
	})
end

--[[
	Glow lichen (Minecraft 1.20.1's GlowLichenBlock, a multiface block; here one face per block):
	GlowLichen lies on the block below (the item), GlowLichenUp hangs under the one above and
	GlowLichenNorth / South / West / East cover the wall on that side (`support`, kept up by the
	Attached behaviour like torches). Light 7 in a cool yellow green, hardness 0.2, mined fastest
	with an axe; it drops 2 Glow Dust (the game's glowing dust, which only lichen gives), or itself
	with Shears (Minecraft's only drop; 2 x slower with them than on leaves: `shearSpeed`), is
	replaceable and is washed away by flowing water.

	Each is a very thin plate a tenth of a pixel off its face, with a small Neon speck that carries
	the light (`glow`; the client gives only some lichen a PointLight, chosen by position, and lit
	and unlit lichen look alike). Two boxes, so two Parts a lichen: caves hold thousands of them
	(1,000-3,000 revealed around a player), and a third box cost as many Parts again as all their
	lights. The outline is Minecraft's: a pixel thick plate over the whole face.

	CaveGlowLichen and its Up / North / South / West / East forms are the cave twins generation
	places on cave walls (`caveTwin`): they look, drop and behave exactly like their twin, but count
	as cave air while caves are hidden, so a whole cave's lichen costs nothing until the player is
	in it, and the stone behind it stays hidden.
]]
local LICHEN = { 106, 128, 118 }
local LICHEN_GLOW = { 210, 220, 158 }
local LICHEN_LIGHT = { 190, 232, 168 }

-- The floor model: { size, offset } of each box with the face at y = -8 (support Down), as
-- { across, height above the face, along }.
local LICHEN_BOXES: { { size: { number }, at: { number }, colour: { number }, glow: boolean? } } = {
	{ size = { 13, 0.3, 13 }, at = { -0.5, 0.25, 0.5 }, colour = LICHEN },
	{ size = { 3, 0.6, 3 }, at = { -2.5, 0.4, -2 }, colour = LICHEN_GLOW, glow = true },
}

-- The lichen's boxes on the face towards `support`: the floor model turned onto that face.
local function lichenShape(support: string): { ShapeBox }
	local boxes: { ShapeBox } = {}
	for _, box in LICHEN_BOXES do
		local a, h, b = box.at[1], box.at[2], box.at[3]
		local sa, sh, sb = box.size[1], box.size[2], box.size[3]
		local size, offset
		if support == "Down" then
			size, offset = { sa, sh, sb }, { a, -8 + h, b }
		elseif support == "Up" then
			size, offset = { sa, sh, sb }, { a, 8 - h, -b }
		elseif support == "North" then
			size, offset = { sa, sb, sh }, { a, b, -8 + h }
		elseif support == "South" then
			size, offset = { sa, sb, sh }, { -a, b, 8 - h }
		elseif support == "West" then
			size, offset = { sh, sb, sa }, { -8 + h, b, -a }
		else
			size, offset = { sh, sb, sa }, { 8 - h, b, a }
		end
		table.insert(boxes, {
			size = size,
			offset = offset,
			color = box.colour,
			material = if box.glow then "Neon" else "SmoothPlastic",
			glow = box.glow,
		})
	end
	return boxes
end

-- Minecraft's outline: a pixel thick plate over the face it covers.
local function lichenBounds(support: string): Bounds
	local lo, hi = { 0, 0, 0 }, { 16, 16, 16 }
	local d = if support == "Down"
		then { 0, -1, 0 }
		elseif support == "Up" then { 0, 1, 0 }
		else table.clone(DIRECTIONS[support])
	for k = 1, 3 do
		if d[k] < 0 then
			hi[k] = 1
		elseif d[k] > 0 then
			lo[k] = 15
		end
	end
	return { min = lo, max = hi }
end

local LICHEN_SIDES = { "Down", "Up", "North", "South", "West", "East" }
for _, cave in { false, true } do
	for _, support in LICHEN_SIDES do
		local suffix = if support == "Down" then "" else support
		local twin = "GlowLichen" .. suffix
		local item = not cave and support == "Down"
		table.insert(list, {
			name = if cave then "CaveGlowLichen" .. suffix else twin,
			displayName = "Glow Lichen",
			color = LICHEN,
			material = "SmoothPlastic",
			sound = "grass",
			solid = false,
			replaceable = true,
			placeable = item,
			item = if item then nil else "GlowLichen",
			hardness = 0.2,
			tool = "axe",
			drops = "GlowDust" :: string,
			dropCount = 2,
			shearDrops = true,
			shearSpeed = 2,
			light = 7,
			lightColor = LICHEN_LIGHT,
			shape = lichenShape(support),
			bounds = lichenBounds(support),
			support = support,
			brokenByFluid = true,
			behaviour = "Attached",
			caveTwin = if cave then twin else nil,
		})
	end
end

--[[
	Lava (Minecraft 1.20.1's, in the overworld), and BuildCraft's oil and the fuel the Oil Refinery
	makes of it: fluid groups like water (Shared/Fluids ids 2, 3 and 4; their flow rules are server
	Behaviours/Fluid's RULES).
	  * Lava: light 15 in every level, a Neon orange surface (its light is sparse: the client
	    lights only some of its cells, as glow lichen's), tick delay 30.
	  * Oil: nearly black glass that barely shows through and shines, tick delay 20 (viscous).
	  * Fuel: translucent amber, tick delay 5 like water.
]]
local LAVA = { 212, 90, 20 }
local LAVA_LIGHT = { 255, 140, 60 }
fluid("Lava", {
	name = "Lava",
	color = LAVA,
	material = "Neon",
	light = 15,
	lightColor = LAVA_LIGHT,
}, 30)
fluid("Oil", {
	name = "Oil",
	color = { 24, 22, 26 },
	material = "Glass",
	transparency = 0.1,
	reflectance = 0.2,
}, 20)
fluid("Fuel", {
	name = "Fuel",
	color = { 232, 172, 44 },
	material = "Glass",
	transparency = 0.4,
	reflectance = 0.05,
	-- The explosive itself: explosions run through it (server World/Explosions sets it off).
	blastResistance = 0,
}, 5)

--[[
	Cave twins of the lava and oil sources (`caveTwin`): CaveLava fills the caves' lava seas and
	underground lava lakes, CaveOil the oil deposits buried in rock. They are their source in
	every way (same look, light, fluid group and level, behaviour; `Blocks.fluidId` never answers
	one, so a twin that flows makes ordinary flowing lava or oil, and a bucket pours an ordinary
	source), but count as cave air while caves are hidden, so a hidden cave's lava and a buried
	deposit cost nothing to draw. Players never place them.
]]
local function caveFluid(group: string)
	for _, spec in list do
		if spec.name == group then
			local twin = table.clone(spec)
			twin.name = "Cave" .. group
			twin.displayName = spec.displayName or group
			twin.placeable = false
			twin.item = group
			twin.caveTwin = group
			table.insert(list, twin)
			return
		end
	end
	error(`No fluid source {group} to twin`)
end
caveFluid("Lava")
caveFluid("Oil")

-- Obsidian (Minecraft's): what water makes of a lava source. Hardness 50, only a diamond pickaxe
-- gets it (9.4 s; by hand 250 s and nothing), drops itself.
table.insert(list, {
	name = "Obsidian",
	color = { 30, 22, 44 },
	material = "Basalt",
	hardness = 50,
	tool = "pickaxe",
	toolLevel = 3,
})

--[[
	The Oil Refinery (Shared/Machines/Kinds/Refinery, kind "refinery"): BuildCraft's refinery on
	electricity, turning oil into fuel 1:1 at 10 mB a tick for 200 J a tick (a bucket in 100 ticks
	for 20 kJ; Speed and Energy Upgrades with Mekanism's maths), from Mekanism-sized tanks of
	10 000 mB each and a 40 000 J store, which cables and machines touching it may fill in a single
	tick. Mekanism's machine block: hardness 3.5, a pickaxe to drop anything. A light steel casing
	with an oil and a fuel sight glass on each side and two tank caps on top (BlockDecor
	"OilRefinery"; the client may light its heater window while it works, REFINERY_WINDOW).
]]
table.insert(list, {
	name = "OilRefinery",
	color = { 140, 144, 152 },
	material = "Metal",
	sound = "metal",
	hardness = 3.5,
	tool = "pickaxe",
	toolLevel = 0,
	decor = "OilRefinery",
	machine = { kind = "refinery" },
	energy = { capacity = 40000, input = 40000 },
})

--[[
	The Combustion Generator (Shared/Machines/Kinds/Combustion, kind "combustion"): burns the
	refinery's fuel at 2 500 J a tick, a mB every 4 ticks (a bucket is 4 000 ticks, 10 MJ), from a
	10 000 mB fuel tank into a 1 MJ store, given out at up to 5 kJ/t (twice what it makes) to
	cables and machines touching it. Mekanism's machine block: hardness 3.5, a pickaxe to drop
	anything. A dark steel casing with amber fuel stripes, a combustion chamber window low on each
	side and an exhaust on top (BlockDecor "CombustionGenerator"; the client may light the window
	while it burns, COMBUSTION_WINDOW).
]]
table.insert(list, {
	name = "CombustionGenerator",
	color = { 56, 58, 64 },
	material = "Metal",
	sound = "metal",
	hardness = 3.5,
	tool = "pickaxe",
	toolLevel = 0,
	decor = "CombustionGenerator",
	machine = { kind = "combustion" },
	energy = { capacity = 1000000, output = 5000 },
})

--[[
	Saplings, one per wood (Minecraft's SaplingBlock): plants on dirt-type soil (`plant`, the Plant
	rules keep them up), dropped by their leaves now and then (Items.leafDrop). Under the open sky
	a random tick grows one into its tree (server Behaviours/Sapling, World/RandomTicker; about 16
	minutes on average) when the tree has room. Drawn as their texture pack sprite ("sapling": a
	black and white picture, tinted with each sapling's colour), else as a stem with leaf lumps.
	Minecraft's outline: 2..14 across, 12 high.
]]
local SAPLING_BOUNDS: Bounds = { min = { 2, 0, 2 }, max = { 14, 12, 14 } }
local function sapling(name: string, colour: { number }, displayName: string)
	plant({
		name = name,
		displayName = displayName,
		color = colour,
		behaviour = "Sapling",
		plant = { soil = "dirt" },
		shape = {
			stem(6),
			lump({ 4.5, 3, 4.5 }, { 0, -2.5, 0 }, colour),
			lump({ 3, 2.5, 3 }, { 0, -0.5, 0 }, colour, { 0, 45, 0 }),
		},
		bounds = SAPLING_BOUNDS,
	})
end
sapling("OakSapling", { 72, 124, 44 }, "Oak Sapling")
sapling("BirchSapling", { 116, 152, 72 }, "Birch Sapling")
sapling("SpruceSapling", { 50, 92, 58 }, "Spruce Sapling")
sapling("AcaciaSapling", { 112, 140, 44 }, "Acacia Sapling")
sapling("JungleSapling", { 46, 124, 36 }, "Jungle Sapling")

--[[
	Fire (Minecraft's FireBlock): burns on top of a block or clings to the sides of flammable
	ones, spreads, burns out and lights what it touches (server Behaviours/Fire, rules in
	Shared/Fire). No item: lit by flint and steel, lava and burning fuel. Light 15, no collision,
	replaceable (a block placed into it puts it out), broken at once with no drop (punching it out
	sounds like block.fire.extinguish: SoundList.BLOCK_SOUNDS), washed away by water.

	Its one shape box is only the carrier of its light: an invisible speck (Neon, see-through),
	sparse like glow lichen's (GreedyMesher: one PointLight per 8 x 8 x 8 blocks), so a forest
	fire is not hundreds of lights. The flames are drawn by client Rendering/FireRenderer: the
	user's animated sheet on Minecraft's fire_floor and fire_side planes, which depend on the
	neighbours (Fire.sides). Its outline is Minecraft's: a pixel thick slab on the floor
	(BaseFireBlock.DOWN_AABB); the client aims at a fire clinging to walls by the slabs on those
	walls instead (Fire.outlineAt).
]]
table.insert(list, {
	name = "Fire",
	color = { 232, 132, 36 },
	material = "Neon",
	sound = "wool",
	solid = false,
	placeable = false,
	replaceable = true,
	hardness = 0,
	drops = false,
	light = 15,
	lightColor = { 255, 170, 90 },
	shape = { { size = { 2, 2, 2 }, offset = { 0, -4, 0 }, glow = true, transparency = 1 } },
	bounds = { min = { 0, 0, 0 }, max = { 16, 1, 16 } },
	brokenByFluid = true,
	behaviour = "Fire",
})

--[[
	Blast resistance (`blastResistance`, Minecraft 1.20.1's explosion resistance) of the blocks
	whose value differs from their hardness: the stone family, bricks and smooth stone 6 (a TNT
	blast barely scratches them), planks 3, metal and gem blocks 6, packed mud 3, obsidian 1200.
	Everything else keeps its hardness (dirt 0.5, logs 2, glass 0.3...), as Minecraft's
	Properties.strength(f) gives both.
]]
local BLAST_RESISTANCE: { [string]: number } = {
	Stone = 6,
	Cobblestone = 6,
	Andesite = 6,
	Diorite = 6,
	Granite = 6,
	PolishedAndesite = 6,
	PolishedDiorite = 6,
	PolishedGranite = 6,
	StoneBricks = 6,
	CrackedStoneBricks = 6,
	SmoothStone = 6,
	SmoothSandstone = 6,
	Brick = 6,
	Planks = 3,
	BirchPlanks = 3,
	SprucePlanks = 3,
	AcaciaPlanks = 3,
	JunglePlanks = 3,
	CoalBlock = 6,
	IronBlock = 6,
	GoldBlock = 6,
	DiamondBlock = 6,
	EmeraldBlock = 6,
	RawIronBlock = 6,
	RawGoldBlock = 6,
	PackedMud = 3,
	Obsidian = 1200,
}
do
	local found = 0
	for _, spec in list do
		local resistance = BLAST_RESISTANCE[spec.name]
		if resistance then
			spec.blastResistance = resistance
			found += 1
		end
	end
	local named = 0
	for _ in BLAST_RESISTANCE do
		named += 1
	end
	assert(found == named, "BLAST_RESISTANCE names a block that does not exist")
end

--[[
	What burns: Minecraft 1.20.1's FireBlock.bootStrap for the blocks this game has, as `flammable`
	{ ignite, burn } (see the fields at the top). Minecraft lists every grass, fern, dead bush and
	flower (both halves of the tall ones), but no sapling and no mushroom; the game has no slabs,
	stairs, fences, wool, bookshelves or hay yet (give such blocks `flammable` where they are
	added, as TNT and the Nuke below have it). Glow lichen is Minecraft's 15 / 100, and its cave
	twins burn like it.
]]
local function fireOdds(spec: BlockSpec): FlammableSpec?
	local name = spec.name
	if string.sub(name, -6) == "Planks" then
		return { ignite = 5, burn = 20 }
	elseif string.sub(name, -3) == "Log" then
		return { ignite = 5, burn = 5 }
	elseif string.sub(name, -6) == "Leaves" then
		return { ignite = 30, burn = 60 }
	elseif string.find(name, "GlowLichen", 1, true) then
		return { ignite = 15, burn = 100 }
	elseif name == "CoalBlock" then
		return { ignite = 5, burn = 5 }
	elseif name == "FuelFalling" or string.sub(name, 1, 8) == "FuelFlow" then
		-- Flowing fuel (not its source, which explodes: server World/Explosions) burns like a
		-- fuse; fire spreads over it and eats it as readily as anything.
		return { ignite = 100, burn = 100 }
	elseif spec.plant and spec.behaviour ~= "Sapling" and spec.plant.soil ~= "mushroom" then
		return { ignite = 60, burn = 100 }
	end
	return nil
end
for _, spec in list do
	spec.flammable = spec.flammable or fireOdds(spec)
end

--[[
	TNT (Minecraft 1.20.1's TntBlock): breaks at once, no blast resistance, flammable 15 / 100
	(FireBlock.bootStrap), red with a white band (BlockDecor "Tnt"; texture pack "tnt side", "tnt
	top", "tnt bottom", blank until made). Flint and steel, fire burning it (lava lights the fire)
	and a blast reaching it light it: it turns into Lit TNT, Minecraft's PrimedTnt as a block
	(server Behaviours/Tnt): it falls while its 80 tick fuse burns, then explodes with power 4.
	Lit TNT glows and flashes (client Rendering/FuseView), can't be broken (an entity in
	Minecraft) and drops nothing; blasts leave it be. Its `item` is TNT (WAILA's icon, pick block).

	The Nuke (this game's, a mod's nuke): a dark steel casing with hazard stripes and the
	radiation sign (BlockDecor "Nuke"; "nuke side", "nuke top", blank), lit the same ways. Lit,
	it glows red, flashes and wails for 10 s, then digs a crater (server World/Nuke; Config.Nuke).
]]
local TNT = { 204, 52, 40 }
table.insert(list, {
	name = "Tnt",
	displayName = "TNT",
	color = TNT,
	material = "SmoothPlastic",
	sound = "grass",
	hardness = 0,
	decor = "Tnt",
	flammable = { ignite = 15, burn = 100 },
})
table.insert(list, {
	name = "LitTnt",
	displayName = "Lit TNT",
	color = { 236, 120, 100 },
	material = "SmoothPlastic",
	sound = "grass",
	hardness = 0,
	breakable = false,
	placeable = false,
	blastResistance = 0,
	drops = false,
	item = "Tnt",
	decor = "Tnt",
	light = 9,
	lightColor = { 255, 226, 190 },
	behaviour = "Tnt",
})
local NUKE = { 46, 50, 48 }
table.insert(list, {
	name = "Nuke",
	color = NUKE,
	material = "Metal",
	sound = "metal",
	hardness = 0,
	decor = "Nuke",
	flammable = { ignite = 15, burn = 100 },
})
table.insert(list, {
	name = "LitNuke",
	displayName = "Lit Nuke",
	color = { 96, 52, 48 },
	material = "Metal",
	sound = "metal",
	hardness = 0,
	breakable = false,
	placeable = false,
	blastResistance = 0,
	drops = false,
	item = "Nuke",
	decor = "Nuke",
	light = 12,
	lightColor = { 255, 70, 50 },
	behaviour = "Tnt",
})

--[[
	Herbs (Tough As Nails' water and teas, Shared/ToughAsNails/Drinks): Mint, the menthol herb
	whose leaves purify dirty water and brew a cooling tea, and Wild Ginger, whose root brews a
	warming one. Plants like the flowers (`plant`: the dirt soil set, broken at once, washed away,
	popping off with their soil), but no item of their own (`placeable` false): breaking one drops
	its herb item (Mint Leaves, Ginger Root), which plants it back (ItemList `places`, Minecraft's
	ItemNameBlockItem: sweet berries and their bush), one for one, so nothing is gained by
	replanting. They spread slowly instead, as Minecraft's mushrooms do (server Behaviours/Herb).
	Generation grows them in rare patches of their biomes (BiomeList `foliage.herbs`): mint on
	plains, meadows and in jungles, wild ginger in forests and taigas, so the cold biomes have
	their warming herb. Mint: a square stem with pairs of bright, crossed leaves and a pale tuft;
	wild ginger: two broad, dark heart-shaped leaves low over the ground and a maroon bud at their
	foot. They burn like flowers (60 / 100; the fire bootstrap above ran before them).
]]
local MINT_BOUNDS: Bounds = { min = { 4, 0, 4 }, max = { 12, 9, 12 } }
local GINGER_BOUNDS: Bounds = { min = { 3, 0, 3 }, max = { 13, 6, 13 } }
local MINT = { 92, 176, 84 }
local MINT_DARK = { 62, 140, 62 }
local MINT_LIGHT = { 150, 210, 128 }
local MINT_STEM = { 84, 124, 60 }
local GINGER_LEAF = { 50, 106, 44 }
local GINGER_LEAF_LIGHT = { 72, 128, 56 }
local GINGER_STALK = { 108, 96, 60 }
local HERB_FIRE: FlammableSpec = { ignite = 60, burn = 100 }
local function herb(name: string, displayName: string, colour: { number }, shape: { ShapeBox }, bounds: Bounds)
	plant({
		name = name,
		displayName = displayName,
		color = colour,
		placeable = false,
		behaviour = "Herb",
		plant = { soil = "dirt" },
		shape = shape,
		bounds = bounds,
		flammable = HERB_FIRE,
	})
end
herb("Mint", "Mint", MINT, {
	blade({ 0, GROUND, 0 }, { 0.8, 8, 0.8 }, 0, 0, MINT_STEM),
	lump({ 6.4, 0.6, 2.4 }, { 0, -5.2, 0 }, MINT_DARK, { 0, 20, 0 }),
	lump({ 2.4, 0.6, 5.6 }, { 0, -2.8, 0 }, MINT, { 0, 20, 0 }),
	lump({ 3, 1.8, 3 }, { 0, -0.4, 0 }, MINT_LIGHT, { 0, 65, 0 }),
}, MINT_BOUNDS)
herb("WildGinger", "Wild Ginger", GINGER_LEAF, {
	blade({ 0, GROUND, 0 }, { 0.6, 4, 0.6 }, 12, 120, GINGER_STALK),
	leaf({ 0, GROUND, 0 }, { 4, 5, 0.4 }, 62, 30, GINGER_LEAF),
	leaf({ 0, GROUND, 0 }, { 3.6, 4.4, 0.4 }, 56, 210, GINGER_LEAF_LIGHT),
	lump({ 1.4, 1.2, 1.4 }, { 0.6, -7.2, -0.5 }, { 112, 40, 46 }, { 0, 45, 0 }),
}, GINGER_BOUNDS)

--[[
	The Campfire (Minecraft 1.20.1's CampfireBlock, always lit here: nothing puts it out), Tough
	As Nails' warmth in the cold. Minecraft's recipe (three sticks around a coal or charcoal, over
	three logs: Crafting/Recipes) and model (campfire.json): two logs along Z on the floor (1..5
	and 11..15 across, 4 tall), two along X across them (3..7 up), and the glowing bed of embers
	between the lower pair (5..11, a pixel thick), which carries its light (15, warm); the flames
	over it are fire's animated sheet on Minecraft's two crossed planes (client
	Rendering/FireRenderer, Shared/Fire.planes). Its outline is Minecraft's 7 pixel tall slab.
	Not solid: Minecraft's campfire is a 7 pixel step to stand on, which the movement hull (full
	cubes only) cannot have, so players walk into it, and it hurts them as Minecraft's
	entityInside does (Players/Burning: half a heart through the hurt cooldown, armor softening
	it, without setting them alight); it `obstructs`, so it is never placed inside a player.
	Strength 2 (hardness and blast resistance), an axe mines it fast, wood sounds. Minecraft drops
	2 charcoal without Silk Touch, which this game has no enchantment for: here it drops itself,
	so a campfire can be moved. A heat source (Config.ToughAsNails.HeatingBlocks: 3 steps within
	5 blocks, 5 within 2) where dirty water boils clean (Shared/ToughAsNails/Boiling); it
	crackles like fire (Audio/Ambience through FireRenderer.firesNear). Spawns never land in or
	next to one (Players/SpawnUnsafeBlocks). Its item shows a few flames over the logs (`icon`).
]]
local CAMPFIRE_LOG = { 92, 70, 44 }
local CAMPFIRE_LOG_TOP = { 110, 84, 54 }
local EMBERS = { 255, 132, 40 }
local campfire: { ShapeBox } = {
	{ size = { 4, 4, 16 }, offset = { -5, -6, 0 }, color = CAMPFIRE_LOG },
	{ size = { 4, 4, 16 }, offset = { 5, -6, 0 }, color = CAMPFIRE_LOG },
	{ size = { 16, 4, 4 }, offset = { 0, -3, 5 }, color = CAMPFIRE_LOG_TOP },
	{ size = { 16, 4, 4 }, offset = { 0, -3, -5 }, color = CAMPFIRE_LOG_TOP },
	{ size = { 6, 1, 16 }, offset = { 0, -7.5, 0 }, color = EMBERS, material = "Neon", glow = true },
}
local campfireIcon = table.clone(campfire)
for _, flame in
	{
		{ size = { 3, 7, 3 }, offset = { 0, 2.5, 0 }, color = { 255, 170, 60 }, material = "Neon" },
		{ size = { 2, 4, 2 }, offset = { -2.5, 0.5, 1.5 }, color = { 255, 120, 30 }, material = "Neon" },
		{ size = { 2, 5, 2 }, offset = { 2.5, 1, -1.5 }, color = { 255, 214, 110 }, material = "Neon" },
	} :: { ShapeBox }
do
	table.insert(campfireIcon, flame)
end
table.insert(list, {
	name = "Campfire",
	color = CAMPFIRE_LOG,
	material = "Wood",
	sound = "wood",
	solid = false,
	placeable = true,
	hardness = 2,
	tool = "axe",
	light = 15,
	lightColor = { 255, 170, 90 },
	shape = campfire,
	icon = campfireIcon,
	bounds = { min = { 0, 0, 0 }, max = { 16, 7, 16 } },
	obstructs = true,
})

--[[
	White Wool (Minecraft 1.20.1's white_wool), what sheep drop (server Mobs/MobWorld, Shared/
	Entities/MobList) and four String make (Crafting/Recipes): a full block, strength 0.8 (hardness
	and blast resistance), no tool needed, wool sounds (Fabric), flammable 30 / 60 (FireBlock's
	wool odds; the fire bootstrap above ran before it) and 100 ticks of furnace fuel. Only white:
	a sheep's natural colour (black, grey, brown, pink) is drawn on the sheep, and every sheep
	drops white wool, as the game has no dyes. Texture pack "white wool", blank until made.
]]
table.insert(list, {
	name = "WhiteWool",
	color = { 234, 236, 237 },
	material = "Fabric",
	sound = "wool",
	hardness = 0.8,
	flammable = { ignite = 30, burn = 60 },
})

--[[
	Ladders, rope and the mineshafts' blocks (Minecraft 1.20.1's LadderBlock, RailBlock,
	FenceBlock, WebBlock, the lush caves' moss, vines and hanging roots, and Supplementaries'
	rope). Generation/Mineshafts builds the mineshafts of them. Each block's fire odds and blast
	resistance are its own (the bootstraps above ran before them). New block sounds: "ladder",
	"rope", "vine" and "moss" (Minecraft's SoundType.LADDER, VINE and MOSS, Supplementaries' rope).
	Every shape box is a Part per block: decorations generation writes by the hundred keep to one
	or two.
]]

-- A box given against the wall to the south (+Z: `support` "South"), turned onto the wall on
-- side `support`: x across the wall, y up, z towards the wall.
local function onWall(box: ShapeBox, support: string): ShapeBox
	local s, o = box.size, box.offset
	local turned = table.clone(box)
	if support == "South" then
		turned.size, turned.offset = { s[1], s[2], s[3] }, { o[1], o[2], o[3] }
	elseif support == "North" then
		turned.size, turned.offset = { s[1], s[2], s[3] }, { -o[1], o[2], -o[3] }
	elseif support == "East" then
		turned.size, turned.offset = { s[3], s[2], s[1] }, { o[3], o[2], -o[1] }
	else
		turned.size, turned.offset = { s[3], s[2], s[1] }, { -o[3], o[2], o[1] }
	end
	return turned
end

-- The outline of a panel `depth` pixels thick against the wall on side `support`.
local function wallBounds(support: string, depth: number): Bounds
	local lo, hi = { 0, 0, 0 }, { 16, 16, 16 }
	local d = DIRECTIONS[support]
	for k = 1, 3 do
		if d[k] < 0 then
			hi[k] = depth
		elseif d[k] > 0 then
			lo[k] = 16 - depth
		end
	end
	return { min = lo, max = hi }
end

--[[
	The Ladder (Minecraft's LadderBlock): a 3 pixel panel against a wall, facing away from it
	(Ladder faces North, on the wall to its south; LadderSouth, LadderWest and LadderEast the other
	ways: wall torches' naming). The wall must be sturdy (`support`, Attached); placing picks the
	clicked wall, else the first wall in the look order that holds one (Blocks.placementFor, as
	LadderBlock.getStateForPlacement). Climbable (Minecraft's #climbable: PlayerPhysics), strength
	0.4, mined fastest with an axe, drops itself, never burns (Minecraft's isn't flammable), 300
	ticks of furnace fuel, ladder sounds. Not `solid` and no collision box here (the movement hull
	only knows full cubes; Minecraft's 3 pixel box only keeps you off the wall), and water stops at
	it (Minecraft waterlogs it; there is no waterlogging here).

	Drawn as two rails 2 pixels wide and four rungs 4 pixels apart (so stacked ladders keep the
	spacing), 0 to 1.5 pixels off the wall, after a see-through plate a fifth of a pixel thick
	0.8 pixels off the wall: Minecraft's model is one textured quad there, and the texture pack's
	"ladder" picture goes on that plate (its Front) in place of the boxes (client rendering).
	Minecraft's outline: the 3 pixel panel.
]]
do
	local LADDER = { 150, 116, 70 }
	local ladder: { ShapeBox } = {
		{ size = { 16, 16, 0.2 }, offset = { 0, 0, 7.1 }, transparency = 1 },
		{ size = { 2, 16, 1.5 }, offset = { -5, 0, 7.25 } },
		{ size = { 2, 16, 1.5 }, offset = { 5, 0, 7.25 } },
	}
	for _, y in { -6, -2, 2, 6 } do
		table.insert(ladder, { size = { 8, 1.5, 1 }, offset = { 0, y, 6.9 } })
	end
	for _, facing in { "North", "South", "West", "East" } do
		local support = OPPOSITE[facing]
		local boxes: { ShapeBox } = {}
		for _, box in ladder do
			table.insert(boxes, onWall(box, support))
		end
		local base = facing == "North"
		table.insert(list, {
			name = if base then "Ladder" else "Ladder" .. facing,
			displayName = "Ladder",
			color = LADDER,
			material = "WoodPlanks",
			sound = "ladder",
			solid = false,
			placeable = base,
			item = if base then nil else "Ladder",
			hardness = 0.4,
			tool = "axe",
			shape = boxes,
			bounds = wallBounds(support, 3),
			support = support,
			behaviour = "Attached",
			climbable = true,
		})
	end
end

--[[
	Rope (Supplementaries' RopeBlock, Minecraft 1.20.1): a rope hanging straight down, a 3 pixel
	thick strand in the middle of its cell. It hangs under a sturdy block or under another rope
	(`support` Up and `chain`: RopeBlock.canSurvive's ceiling or rope above; its side attachments
	and knots are left out), so breaking a rope drops every rope below it, one a tick (Attached).
	Climbable: hold jump to climb a free hanging rope; sliding down is a free fall that never
	hurts (Supplementaries' fast-fall rope; PlayerPhysics). Strength 0.25, no tool, drops itself,
	burns fast (10 / 100), rope sounds, water stops at it (Supplementaries waterlogs it). Made of
	three Straw in a column (Supplementaries' flax) or three String on a diagonal (Crafting/
	Recipes). Using Rope on a rope adds one at its bottom (server Players/ItemUse). The overgrown
	mineshafts' entrances hang one all the way down. Its texture is a sprite (two crossed planes,
	Minecraft's chain model). Outline: Supplementaries' 4 pixel post.
]]
table.insert(list, {
	name = "Rope",
	color = { 156, 124, 84 },
	material = "Fabric",
	sound = "rope",
	solid = false,
	placeable = true,
	hardness = 0.25,
	shape = { { size = { 3, 16, 3 }, offset = { 0, 0, 0 } } },
	bounds = { min = { 6, 0, 6 }, max = { 10, 16, 10 } },
	support = "Up",
	chain = true,
	behaviour = "Attached",
	climbable = true,
	flammable = { ignite = 10, burn = 100 },
})

--[[
	Rails (Minecraft's RailBlock, straight pieces only: no curves, slopes or minecarts): Rail runs
	North-South (`axis` Z), RailEastWest East-West; placing picks the one along the player's facing
	(BaseRailBlock.getStateForPlacement), turning a structure swaps them. They lie on a sturdy
	block (`support` Down, Attached), have no collision, strength 0.7, a pickaxe mines them fast
	but anything drops them, metal sounds, never burn; water stops at them (Minecraft waterlogs
	them). Sixteen from six iron ingots and a stick. Drawn as a sleeper board (the plate the "rail"
	picture goes on, its Front) under two iron bars. Minecraft's outline: 2 pixels high.
]]
do
	local SLEEPERS = { 108, 84, 56 }
	local RAIL_IRON = { 150, 150, 158 }
	for _, axis in { "Z", "X" } do
		local northSouth = axis == "Z"
		local function box(across: number, height: number, y: number, x: number): ShapeBox
			return {
				size = if northSouth then { across, height, 16 } else { 16, height, across },
				offset = if northSouth then { x, y, 0 } else { 0, y, x },
			}
		end
		local sleepers = box(14, 1, -7.5, 0)
		sleepers.color, sleepers.material = SLEEPERS, "Wood"
		local shape: { ShapeBox } = { sleepers }
		for _, x in { -4.5, 4.5 } do
			local bar = box(1.5, 1, -6.5, x)
			bar.color = RAIL_IRON
			table.insert(shape, bar)
		end
		table.insert(list, {
			name = if northSouth then "Rail" else "RailEastWest",
			displayName = "Rail",
			color = RAIL_IRON,
			material = "Metal",
			sound = "metal",
			solid = false,
			placeable = northSouth,
			item = if northSouth then nil else "Rail",
			hardness = 0.7,
			tool = "pickaxe",
			shape = shape,
			bounds = { min = { 0, 0, 0 }, max = { 16, 2, 16 } },
			support = "Down",
			behaviour = "Attached",
			axis = axis,
		})
	end
end

--[[
	The Oak Fence (Minecraft's oak_fence): a 4 x 4 pixel post, and two rails (2 pixels wide, 3
	tall, at 6..9 and 12..15) out to every side it connects to: fences beside it and sturdy blocks
	(`fence`; FenceBlock.connectsTo). OakFence is the lone post and the item; its 15 variants with
	arms come at the end of the list (one per set of sides), and placing one, or a neighbour
	changing, picks the variant (Blocks.fenceConnections, server Behaviours/Fence). Solid, but it
	collides only with its post and arms (`collision`), 1.5 blocks high, as Minecraft's: players
	and mobs can't jump over a fence (a pen holds its animals), and walk past a lone post. Its
	outline: the post and arms 4 pixels wide. Not sturdy (nothing hangs on it). Strength 2, blast
	resistance 3, an axe mines it fast, wood sounds, burns like planks (5 / 20), 300 ticks of fuel.
	Three from four oak planks and two sticks. Drawn in the planks' texture (the pack's "planks").
]]
-- A fence post with arms to the sides of `mask` (`fence`): its shape, outline and collision.
local FENCE_SIDES: { { bit: number, side: string } } = {
	{ bit = 1, side = "North" },
	{ bit = 2, side = "South" },
	{ bit = 4, side = "West" },
	{ bit = 8, side = "East" },
}
local function fencePost(mask: number): ({ ShapeBox }, Bounds, { Bounds })
	local shape: { ShapeBox } = { { size = { 4, 16, 4 }, offset = { 0, 0, 0 } } }
	local lo, hi = { 6, 0, 6 }, { 10, 16, 10 }
	local collision: { Bounds } = { { min = { 6, 0, 6 }, max = { 10, 24, 10 } } }
	for _, entry in FENCE_SIDES do
		if bit32.band(mask, entry.bit) ~= 0 then
			-- (Rails authored against the wall to the south, `onWall` turns them.)
			table.insert(shape, onWall({ size = { 2, 3, 6 }, offset = { 0, -0.5, 5 } }, entry.side))
			table.insert(shape, onWall({ size = { 2, 3, 6 }, offset = { 0, 5.5, 5 } }, entry.side))
			local arm = wallBounds(entry.side, 6)
			for k = 1, 3, 2 do
				if arm.min[k] == 0 and arm.max[k] == 16 then
					arm.min[k], arm.max[k] = 6, 10
				end
			end
			for k = 1, 3 do
				lo[k] = math.min(lo[k], arm.min[k])
				hi[k] = math.max(hi[k], arm.max[k])
			end
			table.insert(collision, { min = { arm.min[1], 0, arm.min[3] }, max = { arm.max[1], 24, arm.max[3] } })
		end
	end
	return shape, { min = lo, max = hi }, collision
end
local function fenceSpec(mask: number): BlockSpec
	local shape, bounds, collision = fencePost(mask)
	local name = "OakFence"
	for _, entry in FENCE_SIDES do
		if bit32.band(mask, entry.bit) ~= 0 then
			name ..= entry.side
		end
	end
	return {
		name = name,
		displayName = "Oak Fence",
		color = { 170, 134, 84 },
		material = "WoodPlanks",
		sound = "wood",
		solid = true,
		placeable = mask == 0,
		item = if mask == 0 then nil else "OakFence",
		hardness = 2,
		blastResistance = 3,
		tool = "axe",
		shape = shape,
		bounds = bounds,
		collision = collision,
		fence = mask,
		behaviour = "Fence",
		flammable = { ignite = 5, burn = 20 },
	}
end
table.insert(list, fenceSpec(0))

--[[
	The Cobweb (Minecraft's WebBlock): moving through one is slowed to a quarter sideways and a
	twentieth up and down, with every move's speed lost, and stops a fall (`stuck`,
	makeStuckInBlock). Strength 4: a sword (speed 15, Shared/Mining) or Shears (15) are the tools
	that get anything: a sword gives a String, Shears the cobweb, a hand nothing. Water washes it
	away (a String). No recipe (Minecraft 1.20.1 has none), never burns. Wool sounds (1.20.1's
	cobweb has the default stone ones; later versions give it a soft sound). Drawn as two crossed
	see-through planes (Minecraft's cross model; the pack's "cobweb" sprite).
]]
table.insert(list, {
	name = "Cobweb",
	displayName = "Cobweb",
	color = { 232, 232, 236 },
	material = "SmoothPlastic",
	transparency = 0.45,
	sound = "wool",
	solid = false,
	placeable = true,
	hardness = 4,
	tool = "sword",
	toolLevel = 0,
	drops = "String" :: string,
	shearDrops = true,
	shape = {
		{ size = { 22.6, 16, 0.2 }, offset = { 0, 0, 0 }, rotation = { 0, 45, 0 } },
		{ size = { 22.6, 16, 0.2 }, offset = { 0, 0, 0 }, rotation = { 0, -45, 0 } },
	},
	bounds = { min = { 0, 0, 0 }, max = { 16, 16, 16 } },
	brokenByFluid = true,
	stuck = { 0.25, 0.05, 0.25 },
})

--[[
	Moss (Minecraft 1.20.1's lush caves): the Moss Block, a soft green block (strength 0.1, a hoe
	mines it fast, moss sounds, never burns) in Minecraft's dirt tag, so plants stand on it
	(Blocks' "dirt" soil set), and the Moss Carpet, a pixel of it on the floor (support Down: here
	the block below must be sturdy, where Minecraft's carpet lies on anything; washed away by
	water), three from two moss blocks. The overgrown mineshafts are full of both. The carpet takes
	the pack's "moss block" texture, as Minecraft's model does.
]]
do
	local MOSS = { 89, 110, 45 }
	table.insert(list, {
		name = "MossBlock",
		displayName = "Moss Block",
		color = MOSS,
		material = "Grass",
		sound = "moss",
		hardness = 0.1,
		tool = "hoe",
	})
	table.insert(list, {
		name = "MossCarpet",
		displayName = "Moss Carpet",
		color = MOSS,
		material = "Grass",
		sound = "moss",
		solid = false,
		placeable = true,
		hardness = 0.1,
		tool = "hoe",
		shape = { { size = { 16, 1, 16 }, offset = { 0, -7.5, 0 } } },
		bounds = { min = { 0, 0, 0 }, max = { 16, 1, 16 } },
		support = "Down",
		brokenByFluid = true,
		behaviour = "Attached",
	})
end

--[[
	Vines (Minecraft's VineBlock, one wall per block here, as glow lichen): Vine covers the wall
	to its south, VineNorth, VineWest and VineEast the others (`support`, the clicked wall first
	when placed). A vine holds on to its wall or hangs from the same vine above it (`chain`:
	VineBlock's hanging vines), so cutting one drops the hanging ones below. Climbable, replaceable,
	washed away by water, strength 0.2 (an axe), only Shears get it (at 2: ShearsItem), burns
	(15 / 100), vine sounds. No growth (Minecraft's random spreading is left out). A slightly
	see-through plate 0.8 pixels off the wall (Minecraft's model), the pack's "vine" picture on it
	(its Front, tinted with the vine's green). Outline: a pixel thick plate on the wall.
]]
do
	local VINE = { 58, 104, 34 }
	local plate: ShapeBox = { size = { 16, 16, 0.4 }, offset = { 0, 0, 7.2 } }
	for _, support in { "South", "North", "West", "East" } do
		local base = support == "South"
		table.insert(list, {
			name = if base then "Vine" else "Vine" .. support,
			displayName = "Vines",
			color = VINE,
			material = "LeafyGrass",
			transparency = 0.15,
			sound = "vine",
			solid = false,
			replaceable = true,
			placeable = base,
			item = if base then nil else "Vine",
			hardness = 0.2,
			tool = "axe",
			drops = false,
			shearDrops = true,
			shearSpeed = 2,
			shape = { onWall(plate, support) },
			bounds = wallBounds(support, 1),
			support = support,
			chain = true,
			brokenByFluid = true,
			behaviour = "Attached",
			climbable = true,
			flammable = { ignite = 15, burn = 100 },
		})
	end
end

--[[
	Hanging Roots (Minecraft's HangingRootsBlock): roots hanging under a sturdy ceiling (`support`
	Up), the top 6 pixels of the cell, two crossed planes (Minecraft's cross model; the pack's
	"hanging roots" sprite). Replaceable, broken at once, only Shears get them, washed away by
	water, burn (30 / 60), vine sounds (Minecraft's own hanging roots sounds stand closest).
]]
table.insert(list, {
	name = "HangingRoots",
	displayName = "Hanging Roots",
	color = { 160, 118, 92 },
	material = "SmoothPlastic",
	sound = "vine",
	solid = false,
	replaceable = true,
	placeable = true,
	hardness = 0,
	tool = "axe",
	drops = false,
	shearDrops = true,
	shape = {
		{ size = { 16.9, 6, 0.3 }, offset = { 0, 5, 0 }, rotation = { 0, 45, 0 } },
		{ size = { 16.9, 6, 0.3 }, offset = { 0, 5, 0 }, rotation = { 0, -45, 0 } },
	},
	bounds = { min = { 2, 10, 2 }, max = { 14, 16, 14 } },
	support = "Up",
	brokenByFluid = true,
	behaviour = "Attached",
	flammable = { ignite = 30, burn = 60 },
})

-- Mossy Cobblestone (Minecraft's): cobblestone with moss (cobblestone and a vine or a moss block
-- in any slots), strength 2, blast resistance 6, a pickaxe to drop it. The overgrown mineshafts'
-- entrances have a collar of it.
table.insert(list, {
	name = "MossyCobblestone",
	displayName = "Mossy Cobblestone",
	color = { 102, 112, 92 },
	material = "Cobblestone",
	sound = "stone",
	hardness = 2,
	blastResistance = 6,
	tool = "pickaxe",
	toolLevel = 0,
})

--[[
	Cave twins of what the mineshafts put in their tunnels (`caveTwin`): wall torches, rails,
	fence posts, cobwebs, moss carpets, vines and hanging roots, exactly their twins (a copy of the
	spec), but cave air while caves are hidden, so a mineshaft's decorations cost nothing until a
	player reaches it (Generation/Mineshafts: a twin in cave air, the block itself in the open).
]]
do
	local function caveTwin(name: string)
		for _, spec in list do
			if spec.name == name then
				local twin = table.clone(spec)
				twin.name = "Cave" .. name
				twin.placeable = false
				twin.item = spec.item or name
				twin.caveTwin = name
				table.insert(list, twin)
				return
			end
		end
		error(`No block {name} to twin`)
	end
	for _, name in
		{
			"WallTorchNorth",
			"WallTorchSouth",
			"WallTorchWest",
			"WallTorchEast",
			"Rail",
			"RailEastWest",
			"OakFence",
			"Cobweb",
			"MossCarpet",
			"Vine",
			"VineNorth",
			"VineWest",
			"VineEast",
			"HangingRoots",
		}
	do
		caveTwin(name)
	end
end

--[[
	Doors (Minecraft's DoorBlock: oak, spruce, birch, jungle and acacia, one per planks). A door
	is two blocks, a lower and an upper half (`door`), one block per facing (the way the player
	looked placing it), hinge side, open or closed and half: 32 per wood. The lower half is the
	item (OakDoor faces North, hinged on the left, closed); every other one names it as `item`,
	is no item of its own and the upper halves drop nothing. Placing picks the facing and hinge
	(Blocks.doorPlacement, DoorBlock.getStateForPlacement) and sets both halves; breaking either
	removes both with one drop (server Network/EditRules, as tall plants'); a half left alone, or
	a lower half without a sturdy block under it, pops (server Behaviours/Door). Right clicking
	either half opens or closes the door, and its double door partner with it (`menu` "Door":
	Shared/Blocks/Doors, server World/DoorUse), in every game mode but spectator.

	Its panel is 3 pixels thick (`bounds`), across the cell's side nearest the player who placed
	it while closed, against its hinge side while open, and players, mobs and items bump into it
	(`collides`: Minecraft's collision shape) though it is not solid. Strength 3, an axe mines it
	fast, wood sounds; Minecraft's wooden doors never catch fire from fire nearby (they are not in
	FireBlock.bootStrap). Three doors from six planks of a wood (Crafting/Recipes), 200 ticks of
	fuel each.

	Drawn from boxes: the lower half a panel with a raised middle and an iron handle on the side
	away from the hinge, the upper half a frame around each wood's windows (oak two, birch four,
	jungle two small ones, acacia one, spruce none: Minecraft's door pictures' windows, see-through
	here too). Its first box is a see-through plate the texture pack's door pictures go on, on both
	sides (TexturePack Blocks OakDoor / OakDoorTop `Front`: blank, so the boxes show), in place of
	the other boxes. The design is drawn for a left hinge and mirrored for a right one.
]]
do
	-- Pixels across the door (u: -8 at the hinge .. 8), up the half (v: -8 .. 8): a box filling
	-- that much of the panel, `thick` pixels thick (3: the panel; more stands proud on both sides),
	-- authored against the wall to the south as `onWall` takes it.
	local function piece(u0: number, u1: number, v0: number, v1: number, thick: number?, color: { number }?): ShapeBox
		local t = thick or 3
		return {
			size = { u1 - u0, v1 - v0, t },
			offset = { (u0 + u1) / 2, (v0 + v1) / 2, 6.5 },
			color = color,
		}
	end
	local function darker(c: { number }, by: number): { number }
		return { math.floor(c[1] * by), math.floor(c[2] * by), math.floor(c[3] * by) }
	end
	local HANDLE = { 72, 72, 76 }
	-- Each wood: its planks' colour and the frame around its upper half's windows (left and right
	-- stiles, rails and mullions; the windows are what they leave open).
	local WOODS: { { wood: string, color: { number }, upper: (c: { number }) -> { ShapeBox } } } = {
		{
			wood = "Oak",
			color = { 170, 134, 84 },
			upper = function(_c)
				return {
					piece(-8, -5, -8, 8),
					piece(5, 8, -8, 8),
					piece(-1, 1, -1, 5),
					piece(-5, 5, 5, 8),
					piece(-5, 5, -8, -1),
				}
			end,
		},
		{
			wood = "Spruce",
			color = { 114, 84, 48 },
			upper = function(c)
				return { piece(-8, 8, -8, 8), piece(-5, 5, -5, 5, 4, darker(c, 0.85)) }
			end,
		},
		{
			wood = "Birch",
			color = { 196, 178, 123 },
			upper = function(_c)
				return {
					piece(-8, -5, -8, 8),
					piece(5, 8, -8, 8),
					piece(-5, 5, 5, 8),
					piece(-5, 5, -8, -3),
					piece(-5, 5, 0.5, 2),
					piece(-1, 1, -3, 5),
				}
			end,
		},
		{
			wood = "Jungle",
			color = { 160, 115, 80 },
			upper = function(_c)
				return {
					piece(-8, -5, -8, 8),
					piece(5, 8, -8, 8),
					piece(-1, 1, 2, 5),
					piece(-5, 5, 5, 8),
					piece(-5, 5, -8, 2),
				}
			end,
		},
		{
			wood = "Acacia",
			color = { 168, 90, 50 },
			upper = function(_c)
				return {
					piece(-8, -4, -8, 8),
					piece(4, 8, -8, 8),
					piece(-4, 4, 5, 8),
					piece(-4, 4, -8, 0),
				}
			end,
		},
	}
	local FACINGS = { "North", "South", "West", "East" }
	local CLOCKWISE = { North = "East", East = "South", South = "West", West = "North" }
	local COUNTER = { North = "West", West = "South", South = "East", East = "North" }
	-- Which end of a panel against `side` the authored +u end turns to (`onWall`), per direction.
	local PLUS_END: { [string]: string } = { South = "East", North = "West", East = "North", West = "South" }
	-- A box of the design for a left hinge, mirrored (u flipped) for the other end.
	local function mirrored(box: ShapeBox): ShapeBox
		local copy = table.clone(box)
		copy.offset = { -box.offset[1], box.offset[2], box.offset[3] }
		return copy
	end
	for _, wood in WOODS do
		local base = wood.wood .. "Door"
		local plate: ShapeBox = { size = { 16, 16, 3 }, offset = { 0, 0, 6.5 }, transparency = 1 }
		local lower: { ShapeBox } = {
			plate,
			piece(-8, 8, -8, 8),
			piece(-5, 5, -5, 5, 4, darker(wood.color, 0.85)),
			{ size = { 1.5, 3, 5 }, offset = { 5.75, 4.5, 6.5 }, color = HANDLE, material = "Metal" },
		}
		local upper: { ShapeBox } = { plate }
		for _, box in wood.upper(wood.color) do
			table.insert(upper, box)
		end
		for _, facing in FACINGS do
			for _, hinge in { "Left", "Right" } do
				for _, open in { false, true } do
					-- The panel's side and the end its hinge is at (DoorBlock.getShape): closed,
					-- across the side facing the placer, hinged on their left or right; open,
					-- turned onto that hinge side, hinged at the old panel's side.
					local hingeSide = if hinge == "Left" then COUNTER[facing] else CLOCKWISE[facing]
					local back = OPPOSITE[facing]
					local side = if open then hingeSide else back
					local hingeEnd = if open then back else hingeSide
					local flip = PLUS_END[side] == hingeEnd
					for _, half in { "lower", "upper" } do
						local isUpper = half == "upper"
						local boxes: { ShapeBox } = {}
						local design: { ShapeBox } = if isUpper then upper else lower
						for _, box in design do
							table.insert(boxes, onWall(if flip then mirrored(box) else box, side))
						end
						local name = base
							.. (if facing == "North" then "" else facing)
							.. (if hinge == "Right" then "Right" else "")
							.. (if open then "Open" else "")
							.. (if isUpper then "Top" else "")
						local item = name == base
						local spec: BlockSpec = {
							name = name,
							displayName = wood.wood .. " Door",
							color = wood.color,
							material = "WoodPlanks",
							sound = "wood",
							solid = false,
							collides = true,
							placeable = item,
							item = if item then nil else base,
							hardness = 3,
							tool = "axe",
							shape = boxes,
							bounds = wallBounds(side, 3),
							support = if isUpper then nil else "Down",
							drops = if isUpper then false else nil,
							menu = "Door",
							behaviour = "Door",
							door = { facing = facing, hinge = hinge, open = open, upper = isUpper },
						}
						if item then
							-- (The item: the whole door at half size, upright, as Minecraft's
							-- door item is drawn; ItemModels centres it on the panel's bounds.)
							local icon: { ShapeBox } = {}
							for k, half in { lower, upper } do
								for _, box in half do
									local o, sz = box.offset, box.size
									local copy = table.clone(box)
									copy.size = { sz[1] / 2, sz[2] / 2, sz[3] }
									copy.offset = { o[1] / 2, o[2] / 2 + (if k == 1 then -4 else 4), o[3] }
									table.insert(icon, copy)
								end
							end
							spec.icon = icon
						end
						table.insert(list, spec)
					end
				end
			end
		end
	end
end

-- The Oak Fence's variants with arms (see the Oak Fence above): one per set of sides.
for mask = 1, 15 do
	table.insert(list, fenceSpec(mask))
end

return list
