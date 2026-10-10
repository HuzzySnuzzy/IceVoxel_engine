--!strict
--[[
	Block registry.

	Turns `BlockList` into:
	  * `Blocks.id.Name -> id` (errors on unknown names, so typos fail loudly),
	  * `Blocks.get(id) -> BlockDef`,
	  * "appearances": groups of blocks that look identical when drawn (e.g. all water levels). The
	    mesher merges boxes per appearance, and the renderer keeps one part template per appearance,
	  * flat buffer lookup tables used by the hot generation / meshing loops,
	  * light sources and attached blocks (torches, lanterns): `lightLut`, the `shape` boxes and
	    `bounds` they are drawn and aimed at with, what they hang on (`canSurvive`, `isSturdy`),
	    which variant a placement makes (`placementFor`, `torchFor`) and what keeps them out of
	    players (`obstruction`), following Minecraft's TorchBlock, WallTorchBlock, LanternBlock
	    and StandingAndWallBlockItem,
	  * sound types (`sound`, `soundLut`, `soundType`): what the block sounds like when it is
	    broken, placed, hit, walked and fallen on (Shared/Sounds plays `block.<type>.<action>`),
	  * Mekanism's transmitters and fluid tanks (`transmitter`, `tank`, `icon`), which
	    Shared/Transmitters reads, and machines (`machine`, `energy`), which Shared/Machines
	    reads (a machine opens a "Machine" menu unless BlockList names another),
	  * plants (BlockList `plant`: grass, ferns, flowers, mushrooms and the two halves of tall
	    ones), Minecraft's BushBlock, DeadBushBlock, MushroomBlock and DoublePlantBlock:
	      - what they stand on: `mayPlaceOn` (the soil sets), `canSurvive` (a single plant or
	        lower half needs its soil below, an upper half its own lower half) and `canPlace`
	        (`canSurvive`, plus room for the upper half of a tall plant: inside the world and
	        replaceable), which `placementFor` uses;
	      - their halves: `isPlant`, `plantTop`, `plantBottom`, `otherHalf` (the partner's dy).
	        Upper halves name the lower half as their `item`, so `Items.ofBlock` answers the
	        plant's item and they are the lower half's variants; having no `support`, they are
	        never placed by `placementFor`;
	      - their look: the soil's foliage colour (`foliageColorOf`; the mesher's `tintLut` into
	        `FOLIAGE_TINTS`, multipliers of the authored green) for `tinted` plants, and per
	        appearance `tinted`, `scatter`, `upperHalf` and `foliage` (also as `tintedLut` and
	        `foliageLut`). Plants never share an appearance with anything else;
	      - what Shears harvest (`shearDrops`, `shearCount`; Items.drops, Shared/Mining).
  * fire (BlockList `flammable`, Minecraft's FireBlock odds): `igniteOdds`, `burnOdds` and
    `isFlammable` (FireBlock.canBurn), also as `igniteLut` and `burnLut`, which Shared/Fire and
    server Behaviours/Fire read;
	  * climbing and hanging (ladders, rope, vines, rails, cobwebs): what players and mobs climb
	    (`climbable`: `isClimbable`, `climbableLut`, Minecraft's #climbable), what slows them down
	    (`stuck`: `stuckIn`, `stuckLut`, makeStuckInBlock), what also hangs from its own kind above
	    (`chain`, in `canSurvive`: a rope under a rope, a vine under a vine) and the axis groups
	    of blocks lying along X or Z (`axis`: rails; `axisOf`, `axisVariant`, picked by the
	    player's facing in `placementFor`, swapped by a quarter turn in `rotate`);
	  * textures (Shared/TexturePack, the texture pack): each block's texture per face
	    (`textures` on defs and appearances, resolved from the pack's All / Sides / Top / Bottom /
	    Front / Sprite; a cave twin takes its twin's, a variant its group's), whether an
	    appearance draws any (`textured`), the texture its parts take as a MaterialVariant
	    (`variantTexture`), which appearances want odd box sizes (`alignLut`, for
	    Config.Textures.OddBoxes) and the pack lookups the client and the generator
	    (tests/build_textures) use: `textureFaces`, `textureOf`, `textureFilled`, `variantName`,
	    `texturesUsed`, `textureUsers`. The pack is checked when this module loads (unknown blocks,
	    textures or face names, materials that cannot take a MaterialVariant), so a typo fails
	    loudly everywhere;
	  * structures (Shared/Structures):
	      - creative only blocks (`creativeOnly`, `isCreativeOnly`): structure blocks, structure
	        voids and jigsaws, which only creative players break (survival players can't mine
	        them) and which never drop;
	      - structure block modes (`structureMode`, `structureBlock`): one block per mode;
	      - jigsaw orientations (`jigsawOrientation`, `jigsawBlock`; Minecraft's FrontAndTop),
	        placed from the clicked face and the look (`jigsawPlacement`, through `placementFor`);
	      - turning blocks with a structure (`rotate`, `rotateLut`, `turnDirection`): wall
	        torches, glow lichen and jigsaws face the turned way;
	      - cave twins (`caveTwin`: CaveGlowLichen*, CaveLava, CaveOil): the same look and behaviour
	        as their twin (a fluid twin is a source of its group, but never `fluidId`'s answer), but
	        cave air while caves are hidden (`cullLutHiddenCaves`, `caveTwinLut`), never part of
	        their item's variants (`placementFor` never picks one), and turned back into their twin
	        by `surfaceForm` (with CaveAir into Air) when a structure is saved;
	      - `find(name)`: a block's id by name, nil when there is none (names from data).
]]

local BlockList = require(script.BlockList)
local Config = require(script.Parent.Config)
local TexturePack = require(script.Parent.TexturePack)

export type BlockDef = {
	id: number,
	name: string,
	render: string,
	kind: number,
	color: { number },
	material: string,
	transparency: number,
	reflectance: number,
	solid: boolean,
	-- Torches and lanterns can hang on it (see Blocks.isSturdy).
	sturdy: boolean,
	replaceable: boolean,
	breakable: boolean,
	placeable: boolean,
	behaviour: string?,
	-- Minecraft block friction (slipperiness) when walking on it.
	friction: number,
	fluid: { group: string, level: number, tickDelay: number }?,
	displayName: string?,
	-- Minecraft destroy time (see Shared/Mining); < 0 = unbreakable.
	hardness: number,
	-- Minecraft's explosion resistance (Shared/World/Explosion; BlockList `blastResistance`): 0 for
	-- air, which explosions pass at no cost.
	blastResistance: number,
	-- The tool that mines it fast ("pickaxe", "axe", "shovel", "hoe"), and the tier it needs to
	-- drop anything (nil: drops by hand).
	tool: string?,
	toolLevel: number?,
	-- Item name dropped when broken in survival (nil = the block itself, false = nothing) and how
	-- many; see Items.drops.
	drops: (string | false)?,
	dropCount: number,
	-- Most of its item in one slot (1..64; Items.maxStack): a Battery's 1.
	maxStack: number,
	-- Item slots the block keeps (chest 27, furnace 3), 0 for other blocks.
	container: number,
	-- What right clicking opens ("Chest", "Crafting", "Furnace"), nil for nothing.
	menu: string?,
	-- Faces drawn on its parts (client Rendering/BlockDecor), one part per block.
	decor: string?,
	-- Sound type (one of Blocks.SOUND_TYPES; Shared/Sounds), nil for silent blocks (air).
	sound: string?,
	-- The texture pack's texture names per face (blank ones too); nil for blocks that are never
	-- textured. See Shared/TexturePack.
	textures: TextureFaces?,
	-- Light given off (0..15) and its colour; see BlockList.
	light: number,
	lightColor: { number },
	-- Boxes drawn instead of a cube (pixels from the cell's centre), and the outline aimed at
	-- (pixels 0..16); see BlockList.
	shape: { ShapeBox }?,
	bounds: Bounds,
	-- Not solid, but has a collision box in Minecraft (lanterns; see Blocks.obstruction).
	obstructs: boolean,
	-- Not solid, but the movement hull bumps into its bounds (doors; see Blocks.collision).
	collides: boolean,
	-- The direction of the block it hangs on (nil: needs nothing) and the item placing / dropping
	-- it when that is not the block itself.
	support: string?,
	item: string?,
	brokenByFluid: boolean,
	-- Mekanism transmitters and fluid tanks (Shared/Transmitters), and the boxes of the item's
	-- model when they differ from `shape` (a transmitter's core with two arms).
	transmitter: TransmitterSpec?,
	tank: TankSpec?,
	icon: { ShapeBox }?,
	-- Mekanism machines (Shared/Machines): the kind, and the energy it holds and moves.
	machine: MachineSpec?,
	energy: EnergySpec?,
	-- Plants: the soil set and the other half's name (see Blocks.canSurvive); `tinted` plants
	-- take their soil's foliage colour, which soil blocks may have (`foliageColor`); `scatter`
	-- plants are drawn at a per-position offset and turn.
	plant: PlantSpec?,
	-- A door half's facing, hinge, open state and half (BlockList `door`; Blocks/Doors).
	door: DoorSpec?,
	tinted: boolean,
	foliageColor: { number }?,
	scatter: boolean,
	-- What Shears harvest from it (true: itself, else an item's name) and how many; see
	-- Items.drops. `shearSpeed`: how fast Shears mine it (nil: the Shears' own speed).
	shearDrops: (string | boolean)?,
	shearCount: number,
	shearSpeed: number?,
	-- Only creative players place, use and break it (structure blocks, structure voids, jigsaws).
	creativeOnly: boolean,
	-- A structure block's mode ("save", "load", "corner", "data"), a jigsaw's orientation and a
	-- cave twin's twin (its name); see BlockList.
	structureMode: string?,
	jigsaw: JigsawSpec?,
	caveTwin: string?,
	-- Minecraft's fire odds (BlockList `flammable`): how readily fire spreads next to it and how
	-- readily it burns away, 0 for blocks that never burn. See Shared/Fire.
	ignite: number,
	burn: number,
	-- Climbed from inside its cell (BlockList `climbable`), also held up by its own kind right
	-- above (`chain`), the horizontal axis it lies along ("X", "Z"; `axis`) and the move
	-- multiplier inside it (`stuck`, { x, y, z }); see BlockList.
	climbable: boolean,
	chain: boolean,
	axis: string?,
	stuck: { number }?,
	appearance: number,
}

export type Appearance = {
	id: number,
	kind: number,
	color: { number },
	material: string,
	transparency: number,
	reflectance: number,
	solid: boolean,
	-- Its blocks' texture names per face (the same table as theirs; nil: never textured), whether
	-- any of them is filled in (or the pack shows missing textures: TexturePack.ShowMissing), and
	-- the plant sprite's.
	textures: TextureFaces?,
	textured: boolean,
	sprite: string?,
	-- Faces drawn on its parts (Rendering/BlockDecor); such blocks are meshed one box per block.
	decor: string?,
	-- Light given off (0..15; > 0 puts a PointLight on its parts) and its colour.
	light: number,
	lightColor: { number },
	-- Boxes drawn instead of a cube (see BlockList); such blocks are meshed one box per block.
	shape: { ShapeBox }?,
	-- Plants (`foliage`, every plant): `tinted` ones take the foliage colour of the soil below
	-- (the mesher packs Blocks.tintLut of it into the box key), `scatter` ones are drawn at a
	-- per-position offset and turn, and an `upperHalf` (a tall plant's top) is offset like the
	-- lower half below it.
	tinted: boolean,
	scatter: boolean,
	upperHalf: boolean,
	foliage: boolean,
}

export type ShapeBox = BlockList.ShapeBox
export type Bounds = BlockList.Bounds
export type TransmitterSpec = BlockList.TransmitterSpec
export type TankSpec = BlockList.TankSpec
export type MachineSpec = BlockList.MachineSpec
export type EnergySpec = BlockList.EnergySpec
export type PlantSpec = BlockList.PlantSpec
export type DoorSpec = BlockList.DoorSpec
export type JigsawSpec = BlockList.JigsawSpec
export type FlammableSpec = BlockList.FlammableSpec
export type Texture = TexturePack.Texture

-- A block's texture per face, resolved from its texture pack entry (texture names; see
-- Shared/TexturePack): the six faces of its cube, glow lichen's `front` and a plant's `sprite`.
export type TextureFaces = {
	top: string?,
	bottom: string?,
	north: string?,
	south: string?,
	east: string?,
	west: string?,
	front: string?,
	sprite: string?,
}

local Blocks = {}

-- Render kinds.
Blocks.KIND_NONE = 0
Blocks.KIND_OPAQUE = 1 -- hides neighbours; hidden cells may be merged into any opaque box
Blocks.KIND_TRANSPARENT = 2 -- drawn cell by cell, does not hide neighbours (glass)
Blocks.KIND_FLUID = 3 -- only cells touching a different non-opaque block are drawn

local KIND_BY_RENDER: { [string]: number } = {
	None = Blocks.KIND_NONE,
	Opaque = Blocks.KIND_OPAQUE,
	Transparent = Blocks.KIND_TRANSPARENT,
	Fluid = Blocks.KIND_FLUID,
}

Blocks.AIR = 0
Blocks.CAVE_AIR = 1

-- Lit blocks without a colour of their own: a warm white.
local DEFAULT_LIGHT_COLOR = { 255, 220, 170 }
local FULL_CELL: Bounds = table.freeze({ min = table.freeze({ 0, 0, 0 }), max = table.freeze({ 16, 16, 16 }) })
-- Minecraft's explosion resistance of unbreakable blocks (bedrock, structure blocks).
local UNBREAKABLE_RESISTANCE = 3600000
-- Boxes a shaped block may have (the renderer keys part templates by box index).
Blocks.MAX_SHAPE_BOXES = 15

--[[
	Sound types, Minecraft's SoundType: how a block sounds when broken, placed, hit while mining,
	walked on and fallen on. Shared/Sounds has the events `block.<type>.<action>` for each. A
	block's type is its `sound`, else its material's (SOUND_BY_MATERIAL), else stone; fluids sound
	like water and blocks that are never drawn (air) like nothing. Ladders, rope, vines (and
	hanging roots) and moss have types of their own (Minecraft's SoundType.LADDER, VINE and MOSS,
	Supplementaries' rope), named on their blocks.
]]
Blocks.SOUND_TYPES = table.freeze({
	"stone",
	"wood",
	"gravel",
	"grass",
	"sand",
	"glass",
	"snow",
	"metal",
	"wool",
	"water",
	"ladder",
	"rope",
	"vine",
	"moss",
})
local SOUND_BY_MATERIAL: { [string]: string } = {
	Wood = "wood",
	WoodPlanks = "wood",
	Grass = "grass",
	LeafyGrass = "grass",
	-- (Minecraft's dirt, coarse dirt and podzol sound like gravel.)
	Ground = "gravel",
	Mud = "gravel",
	Pebble = "gravel",
	Sand = "sand",
	Snow = "snow",
	Glass = "glass",
	Ice = "glass",
	Glacier = "glass",
	Neon = "glass",
	Metal = "metal",
	DiamondPlate = "metal",
	CorrodedMetal = "metal",
	Foil = "metal",
	Fabric = "wool",
}
local soundIndex: { [string]: number } = {}
for index, name in Blocks.SOUND_TYPES do
	soundIndex[name] = index
end

-- The box around a shape's boxes (turned ones included), in pixels 0..16.
local function shapeBounds(shape: { ShapeBox }): Bounds
	local lo, hi = { math.huge, math.huge, math.huge }, { -math.huge, -math.huge, -math.huge }
	for _, box in shape do
		local r = box.rotation or { 0, 0, 0 }
		local ax, ay, az = math.rad(r[1]), math.rad(r[2]), math.rad(r[3])
		for _, sx in { -1, 1 } do
			for _, sy in { -1, 1 } do
				for _, sz in { -1, 1 } do
					-- CFrame.Angles(ax, ay, az) = Rx * Ry * Rz, applied to the corner.
					local x, y, z = box.size[1] / 2 * sx, box.size[2] / 2 * sy, box.size[3] / 2 * sz
					x, y = x * math.cos(az) - y * math.sin(az), x * math.sin(az) + y * math.cos(az)
					x, z = x * math.cos(ay) + z * math.sin(ay), -x * math.sin(ay) + z * math.cos(ay)
					y, z = y * math.cos(ax) - z * math.sin(ax), y * math.sin(ax) + z * math.cos(ax)
					local p = { x + box.offset[1] + 8, y + box.offset[2] + 8, z + box.offset[3] + 8 }
					for k = 1, 3 do
						lo[k] = math.clamp(math.min(lo[k], p[k]), 0, 16)
						hi[k] = math.clamp(math.max(hi[k], p[k]), 0, 16)
					end
				end
			end
		end
	end
	return { min = lo, max = hi }
end

-- Transmitter and tank tiers: 1 Basic .. 4 Ultimate (Transmitters/Tiers).
local function isTier(tier: number): boolean
	return tier == 1 or tier == 2 or tier == 3 or tier == 4
end

-- Structure block modes (BlockList `structureMode`).
local STRUCTURE_MODES = { "save", "load", "corner", "data" }
Blocks.STRUCTURE_MODES = table.freeze(table.clone(STRUCTURE_MODES))

local HORIZONTAL: { [string]: boolean } = { North = true, South = true, West = true, East = true }

-- Minecraft's FrontAndTop: a horizontal front with top Up, or front Up / Down with a horizontal top.
local function validOrientation(front: string, top: string): boolean
	if HORIZONTAL[front] then
		return top == "Up"
	end
	return (front == "Up" or front == "Down") and HORIZONTAL[top] == true
end

--[[
	The texture pack (Shared/TexturePack), checked here so a mistake fails loudly wherever Blocks
	loads (server, client, workers, Lune), naming what is wrong: every entry's block exists, is
	drawn, is no fluid and no cave twin (twins take their twin's textures), every face name is
	known and names a texture, every texture's Material can take a MaterialVariant and every Tint
	naming a block names one. (Ids are checked by tests/build_textures, which turns the pack into
	the MaterialVariants.)
]]

-- Enum.Material names a MaterialVariant can be based on (every one but Neon, Glass, ForceField,
-- Air and the terrain-only Water). A list, since Lune has no Enum.
Blocks.VARIANT_MATERIALS = table.freeze({
	"Plastic",
	"SmoothPlastic",
	"Wood",
	"WoodPlanks",
	"Marble",
	"Basalt",
	"Slate",
	"CrackedLava",
	"Concrete",
	"Limestone",
	"Granite",
	"Pavement",
	"Brick",
	"Pebble",
	"Cobblestone",
	"Rock",
	"Sandstone",
	"CorrodedMetal",
	"DiamondPlate",
	"Foil",
	"Metal",
	"Grass",
	"LeafyGrass",
	"Sand",
	"Fabric",
	"Snow",
	"Mud",
	"Ground",
	"Asphalt",
	"Salt",
	"Ice",
	"Glacier",
	"Cardboard",
	"Carpet",
	"CeramicTiles",
	"ClayRoofTiles",
	"RoofShingles",
	"Leather",
	"Plaster",
	"Rubber",
})
local variantMaterials: { [string]: boolean } = {}
for _, name in Blocks.VARIANT_MATERIALS do
	variantMaterials[name] = true
end

-- The resolved faces (TextureFaces), in the order the appearance key lists them.
Blocks.TEXTURE_FACES = table.freeze({ "top", "bottom", "north", "south", "east", "west", "front", "sprite" })
local PACK_FACES: { [string]: boolean } =
	{ All = true, Sides = true, Top = true, Bottom = true, Front = true, Sprite = true }

local packTextures = TexturePack.Textures
local packBlocks = TexturePack.Blocks
do
	local specs: { [string]: BlockList.BlockSpec } = {}
	for _, spec in BlockList do
		specs[spec.name] = spec
	end
	for name, texture in packTextures do
		assert(
			variantMaterials[texture.Material],
			`TexturePack: texture "{name}" has Material {texture.Material}, which cannot take a MaterialVariant`
		)
		local tint = texture.Tint
		assert(
			type(tint) ~= "string" or specs[tint] ~= nil,
			`TexturePack: texture "{name}" is tinted like unknown block {tint}`
		)
	end
	assert(
		packTextures[TexturePack.Missing],
		`TexturePack: the Missing texture "{TexturePack.Missing}" is not in Textures`
	)
	for name, faces in packBlocks do
		local spec = specs[name]
		assert(spec, `TexturePack: there is no block named {name}`)
		assert(spec.caveTwin == nil, `TexturePack: {name} is a cave twin, which takes {spec.caveTwin}'s textures`)
		assert(
			spec.render ~= "None" and spec.render ~= "Fluid",
			`TexturePack: {name} is never textured ({if spec.render == "None" then "not drawn" else "a fluid"})`
		)
		assert(next(faces) ~= nil, `TexturePack: {name} has an empty entry`)
		for face, texture in faces :: { [string]: string } do
			assert(
				PACK_FACES[face],
				`TexturePack: {name} has unknown face {face} (All, Sides, Top, Bottom, Front or Sprite)`
			)
			assert(packTextures[texture], `TexturePack: {name}'s {face} uses unknown texture "{texture}"`)
		end
	end
end

-- Is the texture filled in (a colour map, not "")? false for unknown names and nil.
local function filled(name: string?): boolean
	local texture = if name then packTextures[name] else nil
	return texture ~= nil and texture.Color ~= ""
end

-- An entry's texture per face: All sets every face of the cube, Sides the four sides, Top and
-- Bottom their own; a face given nothing falls back to All, then to Sides.
local function resolveFaces(entry: TexturePack.Faces): TextureFaces
	local all, sides = entry.All, entry.Sides
	local side = sides or all
	return table.freeze({
		top = entry.Top or all or sides,
		bottom = entry.Bottom or all or sides,
		north = side,
		south = side,
		east = side,
		west = side,
		front = entry.Front,
		sprite = entry.Sprite,
	})
end

-- Per variant group (keyed by the name its blocks' `item` gives, the group's first block): the
-- entry covering the group's blocks without one of their own: the first block's, else the first
-- one listed. (Cave twins are no variants: they take their twin's textures.)
local groupEntries: { [string]: TexturePack.Faces } = {}
for _, spec in BlockList do
	local entry = packBlocks[spec.name]
	if entry and spec.caveTwin == nil then
		local base = spec.item or spec.name
		if groupEntries[base] == nil or spec.item == nil then
			groupEntries[base] = entry
		end
	end
end

-- The appearance key's part for textures: the texture name on each face.
local function texturesKey(faces: TextureFaces?): string
	if faces == nil then
		return ""
	end
	local names = {}
	for index, face in Blocks.TEXTURE_FACES do
		names[index] = (faces :: any)[face] or ""
	end
	return table.concat(names, ";")
end

-- Does an appearance with these faces draw a texture: a filled one, or blank ones shown as
-- missing (TexturePack.ShowMissing)?
local function texturedOf(faces: TextureFaces?): boolean
	if faces == nil then
		return false
	end
	if TexturePack.ShowMissing and filled(TexturePack.Missing) then
		return true
	end
	for _, face in Blocks.TEXTURE_FACES do
		if filled((faces :: any)[face]) then
			return true
		end
	end
	return false
end

local defs: { [number]: BlockDef } = {}
local ids: { [string]: number } = {}
local appearances: { Appearance } = {}
local appearanceByKey: { [string]: number } = {}
local fluidIds: { [string]: { [number]: number } } = {}
local placeable: { number } = {}

for index, spec in BlockList do
	local id = index - 1
	assert(ids[spec.name] == nil, `Duplicate block name {spec.name}`)

	local render = spec.render or (if spec.shape then "Transparent" else "Opaque")
	local kind = KIND_BY_RENDER[render]
	assert(kind ~= nil, `Block {spec.name} has unknown render mode {render}`)

	local drawn = kind ~= Blocks.KIND_NONE
	local solid = if spec.solid ~= nil then spec.solid else drawn
	local breakable = if spec.breakable ~= nil then spec.breakable else drawn
	local def: BlockDef = {
		id = id,
		name = spec.name,
		render = render,
		kind = kind,
		color = spec.color or { 255, 0, 255 },
		material = spec.material or "SmoothPlastic",
		transparency = spec.transparency or 0,
		reflectance = spec.reflectance or 0,
		solid = solid,
		-- (Shaped blocks only when they say so: a fluid tank's glass and frame fill its cell.)
		sturdy = solid and drawn and (if spec.sturdy ~= nil then spec.sturdy else spec.shape == nil),
		replaceable = spec.replaceable or false,
		breakable = breakable,
		placeable = if spec.placeable ~= nil then spec.placeable else (drawn and solid),
		behaviour = spec.behaviour,
		friction = spec.friction or 0.6,
		fluid = spec.fluid,
		displayName = spec.displayName,
		hardness = if breakable then spec.hardness or 1 else -1,
		blastResistance = if spec.blastResistance
			then spec.blastResistance
			elseif kind == Blocks.KIND_NONE then 0
			elseif not breakable or spec.creativeOnly then UNBREAKABLE_RESISTANCE
			else spec.hardness or 1,
		tool = spec.tool,
		toolLevel = spec.toolLevel,
		drops = spec.drops,
		dropCount = spec.dropCount or 1,
		maxStack = spec.maxStack or 64,
		container = spec.container or 0,
		menu = spec.menu or (if spec.machine then "Machine" else nil),
		decor = spec.decor,
		sound = if spec.sound
			then spec.sound
			elseif kind == Blocks.KIND_NONE then nil
			elseif kind == Blocks.KIND_FLUID then "water"
			else SOUND_BY_MATERIAL[spec.material or "SmoothPlastic"] or "stone",
		textures = nil,
		light = math.clamp(spec.light or 0, 0, 15),
		lightColor = spec.lightColor or DEFAULT_LIGHT_COLOR,
		shape = spec.shape,
		bounds = spec.bounds or (if spec.shape then shapeBounds(spec.shape) else FULL_CELL),
		obstructs = spec.obstructs == true or spec.collides == true,
		collides = spec.collides == true,
		support = spec.support,
		item = spec.item,
		brokenByFluid = spec.brokenByFluid == true,
		transmitter = spec.transmitter,
		tank = spec.tank,
		icon = spec.icon,
		machine = spec.machine,
		energy = spec.energy,
		plant = spec.plant,
		door = spec.door,
		tinted = spec.tinted == true,
		foliageColor = spec.foliageColor,
		scatter = spec.scatter == true,
		shearDrops = spec.shearDrops,
		shearCount = spec.shearCount or 1,
		shearSpeed = spec.shearSpeed,
		creativeOnly = spec.creativeOnly == true,
		structureMode = spec.structureMode,
		jigsaw = spec.jigsaw,
		caveTwin = spec.caveTwin,
		ignite = if spec.flammable then spec.flammable.ignite else 0,
		burn = if spec.flammable then spec.flammable.burn else 0,
		climbable = spec.climbable == true,
		chain = spec.chain == true,
		axis = spec.axis,
		stuck = if spec.stuck then table.freeze(table.clone(spec.stuck)) else nil,
		appearance = 0,
	}
	assert(spec.axis == nil or spec.axis == "X" or spec.axis == "Z", `Block {spec.name} has a bad axis {spec.axis}`)
	assert(not def.chain or def.support ~= nil, `Block {spec.name} hangs in a chain on nothing (no support)`)
	assert(not (def.collides and solid), `Block {spec.name} collides by its bounds but is solid (a full cube)`)
	local stuck = spec.stuck
	assert(
		stuck == nil
			or (
				#stuck == 3
				and stuck[1] >= 0
				and stuck[1] <= 1
				and stuck[2] >= 0
				and stuck[2] <= 1
				and stuck[3] >= 0
				and stuck[3] <= 1
			),
		`Block {spec.name} has a bad stuck multiplier`
	)
	assert(spec.shape == nil or #spec.shape <= Blocks.MAX_SHAPE_BOXES, `Block {spec.name} has too many shape boxes`)
	assert(
		def.maxStack >= 1 and def.maxStack <= 64 and def.maxStack == math.floor(def.maxStack),
		`Block {spec.name} has a bad maxStack`
	)
	assert(def.sound == nil or soundIndex[def.sound], `Block {spec.name} has unknown sound {def.sound}`)
	local transmitter = spec.transmitter
	assert(
		transmitter == nil
			or (
				(transmitter.kind == "item" or transmitter.kind == "fluid" or transmitter.kind == "energy")
				and isTier(transmitter.tier)
			),
		`Block {spec.name} has a bad transmitter`
	)
	local energy = spec.energy
	assert(
		energy == nil
			or (
				type(energy.capacity) == "number"
				and energy.capacity > 0
				and (energy.input == nil or energy.input >= 0)
				and (energy.output == nil or energy.output >= 0)
			),
		`Block {spec.name} has bad energy`
	)
	assert(spec.machine == nil or type(spec.machine.kind) == "string", `Block {spec.name} has a bad machine`)
	assert(
		spec.machine == nil or (spec.container == nil and transmitter == nil and spec.tank == nil),
		`Machine {spec.name} must not be a container, transmitter or tank (its slots are its kind's)`
	)
	assert(spec.tank == nil or (isTier(spec.tank.tier) and spec.tank.capacity > 0), `Block {spec.name} has a bad tank`)
	assert(transmitter == nil or spec.tank == nil, `Block {spec.name} is a transmitter and a tank`)
	assert(
		spec.shearDrops == nil or spec.shearDrops == true or type(spec.shearDrops) == "string",
		`Block {spec.name} has bad shearDrops`
	)
	assert(
		def.shearCount >= 1 and def.shearCount <= 64 and def.shearCount == math.floor(def.shearCount),
		`Block {spec.name} has a bad shearCount`
	)
	assert(spec.shearSpeed == nil or spec.shearSpeed > 0, `Block {spec.name} has a bad shearSpeed`)
	assert(
		def.ignite >= 0
			and def.ignite <= 255
			and def.ignite == math.floor(def.ignite)
			and def.burn >= 0
			and def.burn <= 255
			and def.burn == math.floor(def.burn),
		`Block {spec.name} has bad fire odds`
	)
	assert(
		spec.structureMode == nil or table.find(STRUCTURE_MODES, spec.structureMode) ~= nil,
		`Block {spec.name} has unknown structure mode {spec.structureMode}`
	)
	assert(
		spec.jigsaw == nil or validOrientation(spec.jigsaw.front, spec.jigsaw.top),
		`Block {spec.name} has a bad jigsaw orientation`
	)
	assert(
		not def.creativeOnly or (breakable and def.drops == false),
		`Creative only {spec.name} must break and drop nothing`
	)
	-- (A twin comes after the block it twins, and looks exactly like it: see below.)
	local twin = if spec.caveTwin then defs[ids[spec.caveTwin] or -1] else nil
	assert(spec.caveTwin == nil or twin ~= nil, `Block {spec.name} twins unknown or later block {spec.caveTwin}`)
	-- Its texture pack entry, else its variant group's; a twin shares its twin's textures.
	if twin then
		def.textures = twin.textures
	else
		-- (A door's upper halves take its `<door>Top` entry, the upper half facing North.)
		local upperDoor = if spec.door and spec.door.upper then packBlocks[(spec.item or spec.name) .. "Top"] else nil
		local entry = packBlocks[spec.name] or upperDoor or groupEntries[spec.item or spec.name]
		def.textures = if entry then resolveFaces(entry) else nil
	end

	if drawn then
		local c = def.color
		local look = `{kind}|{def.material}|{c[1]},{c[2]},{c[3]}|{def.transparency}|{def.reflectance}`
		local texture = texturesKey(def.textures)
		local lc = def.lightColor
		-- (Shaped blocks get an appearance each: their boxes are their look.)
		local glow = `{def.light}|{lc[1]},{lc[2]},{lc[3]}|{if def.shape then spec.caveTwin or def.name else ""}`
		-- (Plants never share one with anything else: the mesher and renderer treat them apart.)
		local upperHalf = spec.plant ~= nil and spec.plant.bottom ~= nil
		local foliage = `{spec.plant ~= nil},{def.tinted},{def.scatter},{upperHalf}`
		local key = `{look}|{if solid then 1 else 0}|{texture}|{def.decor or ""}|{glow}|{foliage}`
		local appearance = appearanceByKey[key]
		if appearance == nil then
			appearance = #appearances + 1
			appearanceByKey[key] = appearance
			table.insert(appearances, {
				id = appearance,
				kind = kind,
				color = def.color,
				material = def.material,
				transparency = def.transparency,
				reflectance = def.reflectance,
				solid = solid,
				textures = def.textures,
				textured = texturedOf(def.textures),
				sprite = if def.textures then def.textures.sprite else nil,
				decor = def.decor,
				light = def.light,
				lightColor = def.lightColor,
				shape = def.shape,
				tinted = def.tinted,
				scatter = def.scatter,
				upperHalf = upperHalf,
				foliage = spec.plant ~= nil,
			})
		end
		def.appearance = appearance
	end

	-- (A cave twin of a source is no level of its group: `fluidId` answers the ordinary source.)
	if def.fluid and spec.caveTwin == nil then
		local group = def.fluid.group
		fluidIds[group] = fluidIds[group] or {}
		assert(fluidIds[group][def.fluid.level] == nil, `Two blocks are {group} level {def.fluid.level}`)
		fluidIds[group][def.fluid.level] = id
	end

	if def.placeable then
		table.insert(placeable, id)
	end

	defs[id] = def
	ids[spec.name] = id
end

assert(ids.Air == Blocks.AIR and ids.CaveAir == Blocks.CAVE_AIR, "Air and CaveAir must be the first two blocks")
-- The mesher packs a fluid height next to the appearance id in 16 bits (see GreedyMesher).
assert(#appearances < 1024, "At most 1023 distinct block appearances are supported")

-- Cave twins look and behave exactly like their twin (BlockList `caveTwin`): a fluid's twin is a
-- source of the same group too.
local function sameFluid(a: BlockDef, b: BlockDef): boolean
	local x, y = a.fluid, b.fluid
	if x == nil or y == nil then
		return x == y
	end
	return x.group == y.group and x.level == y.level and x.tickDelay == y.tickDelay
end
local function sameStuck(a: { number }?, b: { number }?): boolean
	if a == nil or b == nil then
		return a == b
	end
	return a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end
for _, def in defs do
	local name = def.caveTwin
	if name then
		local twin = defs[ids[name]]
		assert(twin.caveTwin == nil, `Block {def.name} twins another twin`)
		assert(
			def.appearance == twin.appearance
				and sameFluid(def, twin)
				and def.item == (twin.item or twin.name)
				and def.support == twin.support
				and def.light == twin.light
				and def.solid == twin.solid
				and def.replaceable == twin.replaceable
				and def.hardness == twin.hardness
				and def.tool == twin.tool
				and def.drops == twin.drops
				and def.shearDrops == twin.shearDrops
				and def.behaviour == twin.behaviour
				and def.ignite == twin.ignite
				and def.burn == twin.burn
				and def.climbable == twin.climbable
				and def.chain == twin.chain
				and def.axis == twin.axis
				and sameStuck(def.stuck, twin.stuck)
				and not def.placeable,
			`Cave twin {def.name} differs from {name}`
		)
	end
end

Blocks.count = #BlockList
Blocks.defs = defs
Blocks.appearances = appearances
Blocks.placeable = placeable

-- `Blocks.id.Stone` -> 3. Unknown names error instead of silently returning nil.
Blocks.id = (
	setmetatable(ids, {
		__index = function(_, name)
			error(`Unknown block name '{name}'`, 2)
		end,
	}) :: any
) :: { [string]: number }

--[[ Lookup tables (one entry per block id unless noted) ]]

local function u8Lut(predicate: (BlockDef) -> boolean): buffer
	local lut = buffer.create(Blocks.count)
	for id, def in defs do
		buffer.writeu8(lut, id, if predicate(def) then 1 else 0)
	end
	return lut
end

-- Appearance id (u16), 0 = not drawn.
Blocks.appearanceLut = buffer.create(Blocks.count * 2)
for id, def in defs do
	buffer.writeu16(Blocks.appearanceLut, id * 2, def.appearance)
end

-- 1 per *appearance* id when its blocks are meshed one box per block: decorated faces, shapes
-- (drawn box by box in every cell) and light sources (one light per block). Never a fluid: a
-- lava sea is a surface of merged boxes, and only some of its cells carry a light (sparse lights,
-- like glow lichen's; see GreedyMesher).
Blocks.singleLut = buffer.create(#appearances + 1)
for _, appearance in appearances do
	local single = appearance.decor ~= nil
		or appearance.shape ~= nil
		or (appearance.light > 0 and appearance.kind ~= Blocks.KIND_FLUID)
	buffer.writeu8(Blocks.singleLut, appearance.id, if single then 1 else 0)
end

-- Render kind per *appearance* id (u8).
Blocks.kindLut = buffer.create(#appearances + 1)
for _, appearance in appearances do
	buffer.writeu8(Blocks.kindLut, appearance.id, appearance.kind)
end

-- 1 if the block hides the faces of its neighbours.
Blocks.cullLut = u8Lut(function(def)
	return def.kind == Blocks.KIND_OPAQUE
end)

-- 1 for cave twins (BlockList `caveTwin`: the glow lichen generation puts on cave walls).
Blocks.caveTwinLut = u8Lut(function(def)
	return def.caveTwin ~= nil
end)

-- Same as cullLut, but cave air and cave twins also count as solid rock (used for sections far
-- away from the camera): the mesher doesn't draw twins there either, so a cave's lichen costs
-- nothing and hides nothing until its cave is revealed.
Blocks.cullLutHiddenCaves = u8Lut(function(def)
	return def.kind == Blocks.KIND_OPAQUE or def.id == Blocks.CAVE_AIR or def.caveTwin ~= nil
end)

-- 1 for creative only blocks (BlockList `creativeOnly`).
Blocks.creativeOnlyLut = u8Lut(function(def)
	return def.creativeOnly
end)

-- 1 for blocks players and mobs climb from inside their cell (BlockList `climbable`: ladders,
-- vines, rope; Minecraft's #climbable tag).
Blocks.climbableLut = u8Lut(function(def)
	return def.climbable
end)

-- 1 for blocks that slow down what moves inside them (BlockList `stuck`: cobwebs).
Blocks.stuckLut = u8Lut(function(def)
	return def.stuck ~= nil
end)

Blocks.solidLut = u8Lut(function(def)
	return def.solid
end)

Blocks.replaceableLut = u8Lut(function(def)
	return def.replaceable
end)

-- Explosion resistance per block (f32; Shared/World/Explosion reads it for every step of a ray).
Blocks.blastResistanceLut = buffer.create(Blocks.count * 4)
for id, def in defs do
	buffer.writef32(Blocks.blastResistanceLut, id * 4, def.blastResistance)
end

--[[
	Foliage tints: every block with a `foliageColor` (DryGrass), numbered from 1 in id order.
	`tintLut` gives a block's number (u8, 0 = none) and `FOLIAGE_TINTS[number]` the { r, g, b }
	multipliers tinted plants on it are drawn with: its foliage colour / the Grass block's colour,
	per channel, since plants are authored in the Grass block's green. The mesher packs the number
	of the soil under a tinted plant into its box key (GreedyMesher), which has room for 63.
]]
local grassColour = defs[ids.Grass].color
local foliageTints: { { number } } = {}
Blocks.tintLut = buffer.create(Blocks.count)
for id = 0, Blocks.count - 1 do
	local colour = defs[id].foliageColor
	if colour then
		table.insert(
			foliageTints,
			table.freeze({ colour[1] / grassColour[1], colour[2] / grassColour[2], colour[3] / grassColour[3] })
		)
		buffer.writeu8(Blocks.tintLut, id, #foliageTints)
	end
end
assert(#foliageTints < 64, "At most 63 foliage colours fit the mesher's box keys")
Blocks.FOLIAGE_TINTS = table.freeze(foliageTints)

-- 1 per *appearance* id when it is tinted by its soil (`tinted`), and when it is a plant
-- (`foliage`; drawn only with Config.Render.Foliage on).
Blocks.tintedLut = buffer.create(#appearances + 1)
Blocks.foliageLut = buffer.create(#appearances + 1)
for _, appearance in appearances do
	buffer.writeu8(Blocks.tintedLut, appearance.id, if appearance.tinted then 1 else 0)
	buffer.writeu8(Blocks.foliageLut, appearance.id, if appearance.foliage then 1 else 0)
end

--[[
	Surface height of fluid blocks in ninths of a block (like Minecraft): sources 8, flowing levels
	1..7 get lower (7..1), falling fluid is full (9). 0 for everything else.
]]
Blocks.FLUID_FULL = 9
Blocks.fluidHeightLut = buffer.create(Blocks.count)
for id, def in defs do
	local fluid = def.fluid
	if fluid then
		local height = if fluid.level == 0 then 8 elseif fluid.level >= 8 then Blocks.FLUID_FULL else 8 - fluid.level
		buffer.writeu8(Blocks.fluidHeightLut, id, height)
	end
end

-- Light given off by each block (u8, 0..15; Minecraft's luminance).
Blocks.lightLut = buffer.create(Blocks.count)
for id, def in defs do
	buffer.writeu8(Blocks.lightLut, id, def.light)
end

-- Sound type of each block (u8): its index in SOUND_TYPES, 0 = silent.
Blocks.soundLut = buffer.create(Blocks.count)
for id, def in defs do
	buffer.writeu8(Blocks.soundLut, id, if def.sound then soundIndex[def.sound] else 0)
end

-- Blocks a player can point at (everything drawn except fluids).
Blocks.targetLut = u8Lut(function(def)
	return def.kind == Blocks.KIND_OPAQUE or def.kind == Blocks.KIND_TRANSPARENT
end)

--[[ Textures (Shared/TexturePack) ]]

-- An appearance's texture per face (the table its blocks' defs share), nil when its blocks are
-- never textured. Takes the appearance or its id. Read only.
function Blocks.textureFaces(appearance: number | Appearance): TextureFaces?
	local info = if type(appearance) == "number" then appearances[appearance] else appearance
	return if info then info.textures else nil
end

-- The pack's texture of that name, nil for unknown names. Read only.
function Blocks.textureOf(name: string): Texture?
	return packTextures[name]
end

-- Is the texture filled in (it has a colour map, not "")? false for unknown names and nil.
Blocks.textureFilled = filled

-- The name of a texture's MaterialVariant and Texture prototype (tests/build_textures makes
-- them): "IV_" and the name with its spaces as "_" ("grass top" -> "IV_grass_top").
function Blocks.variantName(name: string): string
	return "IV_" .. (string.gsub(name, " ", "_"))
end

--[[
	The texture whose MaterialVariant a cube's parts take at full detail (the client's near look,
	Rendering/TextureLooks), nil for none (the parts keep their plain material):
	  * the sides' texture when it is filled;
	  * else the top's, when no other face has a different filled texture;
	  * else the missing texture when the pack shows missing ones (TexturePack.ShowMissing).
	With Config.Textures.SideImages the sides are drawn as images, so a filled top that differs
	from the sides comes first. Plants and glow lichen (Sprite, Front) draw images, never a variant.
]]
local function variantOf(faces: TextureFaces?): string?
	if faces == nil or (faces.north == nil and faces.top == nil) then
		return nil
	end
	local side, top = faces.north, faces.top
	if Config.Textures.SideImages and filled(top) and top ~= side then
		return top
	elseif filled(side) then
		return side
	elseif filled(top) and (faces.bottom == top or not filled(faces.bottom)) then
		return top
	elseif TexturePack.ShowMissing and filled(TexturePack.Missing) then
		return TexturePack.Missing
	end
	return nil
end

function Blocks.variantTexture(appearance: number | Appearance): string?
	return variantOf(Blocks.textureFaces(appearance))
end

--[[
	1 per *appearance* id whose boxes Config.Textures.OddBoxes makes odd sized (GreedyMesher, full
	detail only): an opaque cube meshed in merged boxes (not `single`, no shape) whose parts take
	a texture's MaterialVariant (`variantTexture`) that lines up with the block grid (its Align is
	not false). Images tile from a face's corner, so they need nothing.
]]
Blocks.alignLut = buffer.create(#appearances + 1)
for _, appearance in appearances do
	local texture = variantOf(appearance.textures)
	local align = appearance.kind == Blocks.KIND_OPAQUE
		and appearance.shape == nil
		and buffer.readu8(Blocks.singleLut, appearance.id) == 0
		and texture ~= nil
		and packTextures[texture].Align ~= false
	buffer.writeu8(Blocks.alignLut, appearance.id, if align then 1 else 0)
end

-- Per texture name, the blocks whose faces use it (names, in id order; twins and variants too).
local textureUsers: { [string]: { string } } = {}
for id = 0, Blocks.count - 1 do
	local def = defs[id]
	local faces = def.textures
	if faces then
		local seen: { [string]: boolean } = {}
		for _, face in Blocks.TEXTURE_FACES do
			local name = (faces :: any)[face]
			if name and not seen[name] then
				seen[name] = true
				local list = textureUsers[name] or {}
				textureUsers[name] = list
				table.insert(list, def.name)
			end
		end
	end
end
local texturesUsed: { string } = {}
for name, list in textureUsers do
	table.freeze(list)
	table.insert(texturesUsed, name)
end
table.sort(texturesUsed)

-- Every texture name a block uses (blank ones too), sorted. Read only.
Blocks.texturesUsed = table.freeze(texturesUsed)

local NO_USERS: { string } = table.freeze({})

-- The blocks using a texture (names, in id order; cave twins and variants too), for the
-- generator's list of what waits on each blank texture. Read only.
function Blocks.textureUsers(name: string): { string }
	return textureUsers[name] or NO_USERS
end

--[[ Helpers ]]

function Blocks.get(id: number): BlockDef
	return defs[id]
end

function Blocks.isValid(id: number): boolean
	return defs[id] ~= nil
end

function Blocks.isSolid(id: number): boolean
	return buffer.readu8(Blocks.solidLut, id) == 1
end

function Blocks.isReplaceable(id: number): boolean
	return buffer.readu8(Blocks.replaceableLut, id) == 1
end

function Blocks.isTargetable(id: number): boolean
	return buffer.readu8(Blocks.targetLut, id) == 1
end

function Blocks.isOpaque(id: number): boolean
	return buffer.readu8(Blocks.cullLut, id) == 1
end

-- Block id of `group` (e.g. "Water") at `level` (0 = source, 1-7 = flowing, 8 = falling). Never a
-- cave twin (CaveLava): flowing out of one makes ordinary fluid. Shared/Fluids has the fluid of
-- any block (`Fluids.ofBlock`, twins included).
function Blocks.fluidId(group: string, level: number): number
	local levels = fluidIds[group]
	assert(levels and levels[level], `Unknown fluid {group} level {level}`)
	return levels[level]
end

--[[ Light sources and attached blocks (torches, lanterns) ]]

-- Offsets of the six directions (Minecraft's: North = -Z, East = +X).
local DIRECTIONS: { [string]: { number } } = {
	Down = { 0, -1, 0 },
	Up = { 0, 1, 0 },
	North = { 0, 0, -1 },
	South = { 0, 0, 1 },
	West = { -1, 0, 0 },
	East = { 1, 0, 0 },
}
Blocks.DIRECTIONS = table.freeze(DIRECTIONS)

-- The direction of offset (dx, dy, dz) (one of the six unit offsets), else nil.
function Blocks.direction(dx: number, dy: number, dz: number): string?
	for name, d in DIRECTIONS do
		if d[1] == dx and d[2] == dy and d[3] == dz then
			return name
		end
	end
	return nil
end

local OPPOSITE: { [string]: string } =
	{ Down = "Up", Up = "Down", North = "South", South = "North", West = "East", East = "West" }

for _, def in defs do
	assert(def.support == nil or DIRECTIONS[def.support], `Block {def.name} has unknown support {def.support}`)
end

-- 1 if attached blocks can hang on the block: solid full cubes (Minecraft's isFaceSturdy), but
-- not those whose support shape is smaller (BlockList `sturdy = false`: leaves, chests, cactus).
Blocks.sturdyLut = u8Lut(function(def)
	return def.sturdy
end)

function Blocks.isSturdy(id: number): boolean
	return id >= 0 and id < Blocks.count and buffer.readu8(Blocks.sturdyLut, id) == 1
end

-- Do players and mobs climb the block from inside its cell (ladders, vines, rope: Minecraft's
-- #climbable tag; BlockList `climbable`)? false for unknown ids.
function Blocks.isClimbable(id: number): boolean
	return id >= 0 and id < Blocks.count and buffer.readu8(Blocks.climbableLut, id) == 1
end

-- The multiplier { x, y, z } a move inside the block is slowed by (BlockList `stuck`: a cobweb's
-- 0.25, 0.05, 0.25, Minecraft's makeStuckInBlock), nil when it slows nothing. Read only.
function Blocks.stuckIn(id: number): { number }?
	local def = defs[id]
	return if def then def.stuck else nil
end

-- Sound type of a block (one of SOUND_TYPES), nil for silent blocks (air) and unknown ids.
function Blocks.soundType(id: number): string?
	if id < 0 or id >= Blocks.count or id ~= id // 1 then
		return nil
	end
	local index = buffer.readu8(Blocks.soundLut, id)
	return if index > 0 then Blocks.SOUND_TYPES[index] else nil
end

-- Light given off by a block (0..15).
function Blocks.light(id: number): number
	return if id >= 0 and id < Blocks.count then buffer.readu8(Blocks.lightLut, id) else 0
end

--[[
	Fire (Shared/Fire, server Behaviours/Fire): Minecraft's FireBlock odds per block (BlockList
	`flammable`, u8; 0: never burns). `igniteLut` is how readily fire spreads into the air next to
	a block (FireBlock.getIgniteOdds), `burnLut` how readily a fire next to it burns it away
	(getBurnOdds).
]]
Blocks.igniteLut = buffer.create(Blocks.count)
Blocks.burnLut = buffer.create(Blocks.count)
for id, def in defs do
	buffer.writeu8(Blocks.igniteLut, id, def.ignite)
	buffer.writeu8(Blocks.burnLut, id, def.burn)
end

-- Minecraft's ignite odds of a block (0 for blocks that never burn and unknown ids).
function Blocks.igniteOdds(id: number): number
	return if id >= 0 and id < Blocks.count then buffer.readu8(Blocks.igniteLut, id) else 0
end

-- Minecraft's burn odds of a block (0 for blocks that never burn and unknown ids).
function Blocks.burnOdds(id: number): number
	return if id >= 0 and id < Blocks.count then buffer.readu8(Blocks.burnLut, id) else 0
end

-- Does fire catch on the block (FireBlock.canBurn: ignite odds above 0)? Fire clings to its
-- sides and lava sets the air next to it alight.
function Blocks.isFlammable(id: number): boolean
	return id >= 0 and id < Blocks.count and buffer.readu8(Blocks.igniteLut, id) > 0
end

--[[
	Variants: a block and the blocks whose `item` names it (Torch and the four wall torches,
	Lantern and HangingLantern, the glow lichen's six sides, the structure block's four modes, the
	jigsaw's twelve orientations). Placing the item picks one of them; they all drop it. Cave twins
	name their twin's item too, but are no variant: nothing places them.
]]
local variants: { [number]: { number } } = {}
-- Per variant group (keyed by its first block): the variant that hangs on each direction.
local bySupport: { [number]: { [string]: number } } = {}
for id = 0, Blocks.count - 1 do
	local def = defs[id]
	local base = if def.item then rawget(ids :: any, def.item) else nil
	-- (A typo would otherwise leave the variant silently unplaceable.)
	assert(def.item == nil or base ~= nil, `Block {def.name} names unknown block {def.item} as its item`)
	if base ~= nil and def.caveTwin == nil then
		assert(base ~= id, `Block {def.name} names itself as its item`)
		local group = variants[base]
		if group == nil then
			group = { base }
			variants[base] = group
		end
		table.insert(group, id)
		variants[id] = group
	end
end
-- Per axis group (keyed by its first block): the variant lying along each axis ("X", "Z").
local byAxis: { [number]: { [string]: number } } = {}
for _, group in variants do
	local base = group[1]
	if bySupport[base] == nil then
		local map = {}
		if defs[base].door then
			-- (A door's variants are its facings, hinges, open states and halves: `doorPlacement`
			-- picks the one placed, so none is keyed by the floor it stands on.)
			for _, id in group do
				assert(defs[id].door, `Block {defs[id].name} is no door in door {defs[base].name}'s group`)
			end
		elseif defs[base].axis then
			-- (An axis group's variants all lie on the floor: the facing picks them, not a side.)
			local axes = {}
			for _, id in group do
				local axis = defs[id].axis
				assert(axis and axes[axis] == nil, `Axis group {defs[base].name} needs one variant per axis`)
				axes[axis] = id
			end
			byAxis[base] = axes
		else
			for _, id in group do
				local support = defs[id].support
				assert(defs[id].axis == nil, `Block {defs[id].name} lies along an axis in a group that does not`)
				if support then
					assert(map[support] == nil, `Two variants of {defs[base].name} hang on {support}`)
					map[support] = id
				end
			end
		end
		bySupport[base] = map
	end
end
for id, def in defs do
	if def.support and variants[id] == nil and def.caveTwin == nil then
		-- An attached block without variants (a lone support) is its own group.
		variants[id] = { id }
		bySupport[id] = { [def.support] = id }
	end
end

-- The blocks one item places (the block's own first), e.g. Torch and the wall torches.
function Blocks.variants(block: number): { number }
	return variants[block] or { block }
end

-- The horizontal axis a block lies along ("X" or "Z": BlockList `axis`, rails), nil for others.
function Blocks.axisOf(block: number): string?
	local def = defs[block]
	return if def then def.axis else nil
end

--[[
	The variant of `block`'s axis group (a rail, or any rail of the group) lying along `axis`
	("X" East-West, "Z" North-South), nil when the block is in no axis group or the axis is
	unknown. Generation picks rails by a corridor's axis with it (and their cave twins with
	`caveTwinFor`).
]]
function Blocks.axisVariant(block: number, axis: string): number?
	local group = variants[block]
	local axes = if group then byAxis[group[1]] else nil
	return if axes then axes[axis] else nil
end

-- The direction from a block to the block it hangs on, as an offset (nil: needs nothing).
function Blocks.supportOffset(block: number): (number?, number?, number?)
	local def = defs[block]
	local support = def and def.support
	if support == nil then
		return nil, nil, nil
	end
	local d = DIRECTIONS[support]
	return d[1], d[2], d[3]
end

--[[ Plants (BlockList `plant`) ]]

--[[
	Soil sets (BlockList `plant.soil`): "dirt" is Minecraft's DIRT tag as far as this game has it
	(the Moss Block is in it too), "deadbush" adds sand (DeadBushBlock; there is no terracotta),
	"mushroom" is Minecraft's MUSHROOM_GROW_BLOCK tag, plus any sturdy opaque full block
	(`mayPlaceOn`).
]]
local DIRT_SOIL = { "Grass", "DryGrass", "Dirt", "CoarseDirt", "Podzol", "Mycelium", "MossBlock" }
local soils: { [string]: { [number]: boolean } } = { dirt = {}, deadbush = {}, mushroom = {} }
for _, name in DIRT_SOIL do
	soils.dirt[ids[name]] = true
	soils.deadbush[ids[name]] = true
end
soils.deadbush[ids.Sand] = true
soils.mushroom[ids.Mycelium] = true
soils.mushroom[ids.Podzol] = true

-- Single plants and lower halves: their soil set; tall plants: each half's other half.
local plantSoil: { [number]: string } = {}
local plantTops: { [number]: number } = {}
local plantBottoms: { [number]: number } = {}
for id, def in defs do
	local info = def.plant
	if info and info.bottom then
		local bottom = rawget(ids :: any, info.bottom) :: number?
		local lower = if bottom then defs[bottom].plant else nil
		assert(bottom and lower and lower.top == def.name, `Plant {def.name} names a bad bottom {info.bottom}`)
		assert(info.soil == nil and info.top == nil, `Upper half {def.name} has a soil or a top`)
		assert(
			def.support == nil and def.item == info.bottom,
			`Upper half {def.name} must hang on nothing and be its bottom's`
		)
		plantBottoms[id] = bottom
	elseif info then
		assert(info.soil and soils[info.soil], `Plant {def.name} has unknown soil {info.soil}`)
		assert(def.support == "Down", `Plant {def.name} must stand on its soil (support "Down")`)
		plantSoil[id] = info.soil
		if info.top then
			local top = rawget(ids :: any, info.top) :: number?
			local upper = if top then defs[top].plant else nil
			assert(top and upper and upper.bottom == def.name, `Plant {def.name} names a bad top {info.top}`)
			plantTops[id] = top
		end
	end
	assert(info or not def.tinted, `Block {def.name} is tinted but no plant`)
end

-- Is the block a plant (either half of a tall one included)?
function Blocks.isPlant(id: number): boolean
	local def = defs[id]
	return def ~= nil and def.plant ~= nil
end

-- The upper half of a tall plant's lower half (nil for anything else).
function Blocks.plantTop(id: number): number?
	return plantTops[id]
end

-- The lower half of a tall plant's upper half (nil for anything else).
function Blocks.plantBottom(id: number): number?
	return plantBottoms[id]
end

-- Where a tall plant's other half is, as dy: +1 from a lower half, -1 from an upper half; nil for
-- anything else.
function Blocks.otherHalf(id: number): number?
	if plantTops[id] then
		return 1
	elseif plantBottoms[id] then
		return -1
	end
	return nil
end

--[[ Doors (BlockList `door`; Shared/Blocks/Doors) ]]

--[[
	Every door half by its door (its group's first block, the item), facing, hinge, open state and
	half; and each half's other half, the same door's, kept with the tall plants' (`plantTop`,
	`plantBottom`, `otherHalf`): breaking, placing, surviving and structures treat a door's halves
	as a tall plant's. A door has all 32 halves (4 facings x 2 hinges x open or not x 2 halves).
]]
local doorStates: { [number]: DoorSpec } = {}
local doorIds: { [string]: number } = {}
local function doorKey(base: number, facing: string, hinge: string, open: boolean, upper: boolean): string
	return `{base}|{facing}|{hinge}|{open}|{upper}`
end
for id, def in defs do
	local door = def.door
	if door then
		assert(
			HORIZONTAL[door.facing] and (door.hinge == "Left" or door.hinge == "Right"),
			`Door {def.name} has a bad facing or hinge`
		)
		local group = variants[id]
		assert(group ~= nil, `Door {def.name} is in no variant group (name its item)`)
		local key = doorKey(group[1], door.facing, door.hinge, door.open, door.upper)
		assert(doorIds[key] == nil, `Two door halves are {key}`)
		doorStates[id] = door
		doorIds[key] = id
	end
end
for id, door in doorStates do
	local base = variants[id][1]
	for _, facing in { "North", "South", "West", "East" } do
		for _, hinge in { "Left", "Right" } do
			for _, open in { false, true } do
				for _, upper in { false, true } do
					assert(
						doorIds[doorKey(base, facing, hinge, open, upper)],
						`Door {defs[base].name} lacks a {facing} {hinge} {open} {upper} half`
					)
				end
			end
		end
	end
	local other = doorIds[doorKey(base, door.facing, door.hinge, door.open, not door.upper)]
	if door.upper then
		assert(defs[id].support == nil, `Door upper half {defs[id].name} must hang on nothing`)
		plantBottoms[id] = other
	else
		assert(defs[id].support == "Down", `Door lower half {defs[id].name} must stand on a block`)
		plantTops[id] = other
	end
end

-- Is the block a door half?
function Blocks.isDoor(id: number): boolean
	return doorStates[id] ~= nil
end

-- A door half's facing, hinge ("Left" / "Right"), whether it is open and whether it is the upper
-- half; nils for anything else.
function Blocks.doorState(id: number): (string?, string?, boolean?, boolean?)
	local door = doorStates[id]
	if door == nil then
		return nil, nil, nil, nil
	end
	return door.facing, door.hinge, door.open, door.upper
end

-- The half of `id`'s door (any of its halves) facing `facing` with `hinge`, `open` or not, the
-- upper one or not; nil when `id` is no door.
function Blocks.doorVariant(id: number, facing: string, hinge: string, open: boolean, upper: boolean): number?
	local group = if doorStates[id] then variants[id] else nil
	return if group then doorIds[doorKey(group[1], facing, hinge, open, upper)] else nil
end

-- The same door half opened (closed when open); nil for anything else.
function Blocks.doorToggled(id: number): number?
	local door = doorStates[id]
	if door == nil then
		return nil
	end
	return doorIds[doorKey(variants[id][1], door.facing, door.hinge, not door.open, door.upper)]
end

local DOOR_LEFT: { [string]: string } = { North = "West", West = "South", South = "East", East = "North" }
local DOOR_RIGHT: { [string]: string } = { North = "East", East = "South", South = "West", West = "North" }

--[[
	The closed lower half of door `block` (any half) a player places at (x, y, z) looking along
	(lx, lz), having clicked at (hx, hz) within that cell (0..1; nil: its middle), or nil when it
	can't stand there (Blocks.canPlace: a sturdy block below, room above). Minecraft's
	DoorBlock.getStateForPlacement: it faces the way the player looks; its hinge goes against the
	side with more full blocks (solid unshaped cells) beside the door's two cells, else away from a
	door already beside it (its double door partner: a door to the left gets a right hinge), else
	on the half of the cell clicked (DoorBlock.getHinge).
]]
function Blocks.doorPlacement(
	block: number,
	lx: number,
	lz: number,
	getBlock: (x: number, y: number, z: number) -> number?,
	x: number,
	y: number,
	z: number,
	hx: number?,
	hz: number?
): number?
	local facing = Blocks.horizontalFacing(lx, lz)
	local left, right = DIRECTIONS[DOOR_LEFT[facing]], DIRECTIONS[DOOR_RIGHT[facing]]
	local function full(bx: number, by: number, bz: number): boolean
		local id = getBlock(bx, by, bz)
		local def = if id then defs[id] else nil
		return def ~= nil and def.solid and def.shape == nil
	end
	local function lowerDoor(bx: number, by: number, bz: number): boolean
		local id = getBlock(bx, by, bz)
		local door = if id then doorStates[id] else nil
		return door ~= nil and not door.upper
	end
	local walls = 0
	walls -= if full(x + left[1], y, z + left[3]) then 1 else 0
	walls -= if full(x + left[1], y + 1, z + left[3]) then 1 else 0
	walls += if full(x + right[1], y, z + right[3]) then 1 else 0
	walls += if full(x + right[1], y + 1, z + right[3]) then 1 else 0
	local leftDoor = lowerDoor(x + left[1], y, z + left[3])
	local rightDoor = lowerDoor(x + right[1], y, z + right[3])
	local hinge
	if (leftDoor and not rightDoor) or walls > 0 then
		hinge = "Right"
	elseif (rightDoor and not leftDoor) or walls < 0 then
		hinge = "Left"
	else
		local step = DIRECTIONS[facing]
		local sx, sz = step[1], step[3]
		local dx, dz = hx or 0.5, hz or 0.5
		local onLeft = (sx >= 0 or dz >= 0.5)
			and (sx <= 0 or dz <= 0.5)
			and (sz >= 0 or dx <= 0.5)
			and (sz <= 0 or dx >= 0.5)
		hinge = if onLeft then "Left" else "Right"
	end
	local variant = Blocks.doorVariant(block, facing, hinge, false, false)
	return if variant and Blocks.canPlace(variant, getBlock, x, y, z) then variant else nil
end

--[[
	May `plant` (a single plant or a lower half) stand on `soil`? Its soil set (Minecraft's
	BushBlock.mayPlaceOn and its overrides): mushrooms also stand on any sturdy opaque full block
	(MushroomBlock, without its light check: there are no block light levels). Upper halves stand
	on their lower half only (`canSurvive`), so they and non-plants answer false.
]]
function Blocks.mayPlaceOn(plant: number, soil: number): boolean
	local set = plantSoil[plant]
	if set == nil or defs[soil] == nil then
		return false
	end
	return soils[set][soil] == true or (set == "mushroom" and Blocks.isSturdy(soil) and Blocks.isOpaque(soil))
end

-- The foliage colour ({ r, g, b }) tinted plants take on `soil` (BlockList `foliageColor`), nil
-- when they keep their own. Read only.
function Blocks.foliageColorOf(soil: number): { number }?
	local def = defs[soil]
	return if def then def.foliageColor else nil
end

--[[
	Can `block` stay at (x, y, z)? Minecraft's canSurvive:
	  * a plant (a single one or a lower half) needs a block of its soil set below (`mayPlaceOn`;
	    BushBlock), an upper half its own lower half (DoublePlantBlock; whether a lower half has
	    its top is the server's Plant behaviour's business);
	  * other blocks with a `support` need a sturdy block on that side (TorchBlock,
	    WallTorchBlock, LanternBlock, LadderBlock, BaseRailBlock), or, for `chain` blocks, a
	    block of their own kind right above them, a cave twin counting as its twin (a rope under
	    a rope: Supplementaries' RopeBlock; a vine under the same vine: VineBlock).
	`getBlock` answers nil for unknown (unloaded) blocks, which hold nothing up.
]]
-- A block's kind for `chain`: its twin's id for a cave twin, else its own.
local function chainKind(id: number): number
	local def = defs[id]
	local twin = def and def.caveTwin
	return if twin then rawget(ids :: any, twin) :: number else id
end

function Blocks.canSurvive(
	block: number,
	getBlock: (x: number, y: number, z: number) -> number?,
	x: number,
	y: number,
	z: number
): boolean
	local bottom = plantBottoms[block]
	if bottom ~= nil then
		return getBlock(x, y - 1, z) == bottom
	end
	if plantSoil[block] ~= nil then
		local soil = getBlock(x, y - 1, z)
		return soil ~= nil and Blocks.mayPlaceOn(block, soil)
	end
	local dx, dy, dz = Blocks.supportOffset(block)
	if dx == nil or dy == nil or dz == nil then
		return true
	end
	local support = getBlock(x + dx, y + dy, z + dz)
	if support ~= nil and Blocks.isSturdy(support) then
		return true
	end
	local def = defs[block]
	if def and def.chain then
		local above = getBlock(x, y + 1, z)
		return above ~= nil and defs[above] ~= nil and chainKind(above) == chainKind(block)
	end
	return false
end

--[[
	May `block` be placed at (x, y, z)? It must survive there (`canSurvive`), and a tall plant's
	lower half needs room for its upper half: y + 1 inside the world (below Config.WorldHeight)
	and replaceable there (Minecraft's DoublePlantBlock.getStateForPlacement). `getBlock` answers
	nil for unknown blocks, which leave no room.
]]
function Blocks.canPlace(
	block: number,
	getBlock: (x: number, y: number, z: number) -> number?,
	x: number,
	y: number,
	z: number
): boolean
	if not Blocks.canSurvive(block, getBlock, x, y, z) then
		return false
	end
	if plantTops[block] == nil then
		return true
	end
	if y + 1 >= Config.WorldHeight then
		return false
	end
	local above = getBlock(x, y + 1, z)
	return above ~= nil and defs[above] ~= nil and Blocks.isReplaceable(above)
end

--[[
	The six directions ordered by how directly a look vector points along them, then their
	opposites in reverse: Minecraft's Direction.orderedByNearest (makeDirectionArray), which decides
	where a torch goes when the clicked face can't hold it.
]]
function Blocks.lookOrder(lx: number, ly: number, lz: number): { string }
	local x = if lx > 0 then "East" else "West"
	local y = if ly > 0 then "Up" else "Down"
	local z = if lz > 0 then "South" else "North"
	local ax, ay, az = math.abs(lx), math.abs(ly), math.abs(lz)
	local a, b, c
	if ax > az then
		if ay > ax then
			a, b, c = y, x, z
		elseif az > ay then
			a, b, c = x, z, y
		else
			a, b, c = x, y, z
		end
	elseif ay > az then
		a, b, c = y, z, x
	elseif ax > ay then
		a, b, c = z, x, y
	else
		a, b, c = z, y, x
	end
	return { a, b, c, OPPOSITE[c], OPPOSITE[b], OPPOSITE[a] }
end

-- Is the variant group starting with `base` one of jigsaws (orientations, no supports)?
local function jigsawGroup(base: number): boolean
	return defs[base].jigsaw ~= nil
end

--[[
	The variant of `block`'s item hanging on the face that was clicked, whose normal is
	(nx, ny, nz): the block the face belongs to is the support. nil when no variant hangs that way
	(a torch under a ceiling). Blocks without supports are their own answer; a group whose
	variants hang on nothing (the structure block's modes) gives the item's own block, and a
	jigsaw the orientation `jigsawPlacement` picks for a player looking into the face.
]]
function Blocks.variantFor(block: number, nx: number, ny: number, nz: number): number?
	local group = variants[block]
	if group == nil then
		return block
	end
	local base = group[1]
	if jigsawGroup(base) then
		return Blocks.jigsawPlacement(nx, ny, nz, -nx, -ny, -nz)
	elseif next(bySupport[base]) == nil then
		return base
	end
	local direction = Blocks.direction(-nx, -ny, -nz)
	return if direction then bySupport[base][direction] else nil
end

-- The torch for a clicked face: a standing torch on top, a wall torch facing away from a side,
-- nothing under a block.
function Blocks.torchFor(nx: number, ny: number, nz: number): number?
	return Blocks.variantFor(rawget(ids :: any, "Torch") :: number, nx, ny, nz)
end

--[[
	The block placing `block`'s item at (x, y, z) makes: Minecraft's BlockPlaceContext order (the
	clicked face's support first, then the directions the player looks along, `lookOrder`).
	  * Up or down: the variant hanging that way, if it can be placed there (`canPlace`: it
	    survives, and a tall plant has room for its top; TorchBlock,
	    LanternBlock.getStateForPlacement, DoublePlantBlock).
	  * A side: the wall variant, which is the first side in the whole order whose variant
	    survives (WallTorchBlock.getStateForPlacement), even one listed after a floor that would
	    hold a standing torch (StandingAndWallBlockItem asks the wall block at the first side).
	The first answer wins. A torch clicked under a ceiling still goes on a wall or the floor next
	to it when there is one. nil: nothing can hold it. (nx, ny, nz) = (0, 0, 0) uses the look order
	alone. Blocks without supports place as they are. A plant gives itself or nil, never the upper
	half of a tall one (it hangs on nothing, so no direction picks it). A group whose variants
	hang on nothing places the item's own block (a structure block in SAVE mode), and a jigsaw
	takes its orientation from the clicked face and the look (`jigsawPlacement`). An axis group
	(rails) places the variant along the player's horizontal facing (East / West: "X", else "Z")
	when it can lie there. Ladders and vines are wall variants like the wall torch, so a click
	on a floor puts one on a wall beside the cell. A door places its closed lower half facing the
	way the player looks, its hinge by `doorPlacement` (`hx`, `hz`: where in the cell the click
	landed, 0..1). Cave twins are never placed.
]]
function Blocks.placementFor(
	block: number,
	nx: number,
	ny: number,
	nz: number,
	lx: number,
	ly: number,
	lz: number,
	getBlock: (x: number, y: number, z: number) -> number?,
	x: number,
	y: number,
	z: number,
	hx: number?,
	hz: number?
): number?
	local group = variants[block]
	if group == nil then
		return if defs[block] and defs[block].caveTwin then nil else block
	end
	local base = group[1]
	if doorStates[base] then
		return Blocks.doorPlacement(base, lx, lz, getBlock, x, y, z, hx, hz)
	end
	if jigsawGroup(base) then
		return Blocks.jigsawPlacement(nx, ny, nz, lx, ly, lz)
	end
	local axes = byAxis[base]
	if axes then
		-- Along the way the player faces (BaseRailBlock.getStateForPlacement), if it can lie there.
		local facing = Blocks.horizontalFacing(lx, lz)
		local variant = axes[if facing == "East" or facing == "West" then "X" else "Z"]
		return if variant and Blocks.canPlace(variant, getBlock, x, y, z) then variant else nil
	end
	local hanging = bySupport[base]
	if next(hanging) == nil then
		return base
	end
	local order = Blocks.lookOrder(lx, ly, lz)
	local first = Blocks.direction(-nx, -ny, -nz)
	if first then
		local index = table.find(order, first) :: number
		table.remove(order, index)
		table.insert(order, 1, first)
	end
	-- The wall variant: the first side, in that order, that holds one.
	local wall: number? = nil
	for _, direction in order do
		local variant = hanging[direction]
		if HORIZONTAL[direction] and variant and Blocks.canPlace(variant, getBlock, x, y, z) then
			wall = variant
			break
		end
	end
	for _, direction in order do
		if HORIZONTAL[direction] then
			if wall then
				return wall
			end
		else
			local variant = hanging[direction]
			if variant and Blocks.canPlace(variant, getBlock, x, y, z) then
				return variant
			end
		end
	end
	return nil
end

--[[
	The outline of a block players aim at, in block units within its cell (minX, minY, minZ, maxX,
	maxY, maxZ), or nil for a whole cell. Shaped blocks are aimed at and highlighted by it, so a ray
	passes beside a torch to the wall behind it.
]]
local outlines: { [number]: { number } } = {}
-- (Bounds covering the whole cell are no outline: transmitters and fluid tanks.)
local function wholeCell(b: Bounds): boolean
	for k = 1, 3 do
		if b.min[k] > 0 or b.max[k] < 16 then
			return false
		end
	end
	return true
end
for id, def in defs do
	local b = def.bounds
	if b ~= FULL_CELL and not wholeCell(b) then
		outlines[id] = {
			b.min[1] / 16,
			b.min[2] / 16,
			b.min[3] / 16,
			b.max[1] / 16,
			b.max[2] / 16,
			b.max[3] / 16,
		}
	end
end

function Blocks.outline(id: number): { number }?
	return outlines[id]
end

--[[
	The box a block fills for Minecraft's collision checks that move nothing, in block units within
	its cell like `outline` (minX, minY, minZ, maxX, maxY, maxZ): a solid block's whole cell, an
	`obstructs` block's outline (a lantern), else nil (torches, air, water). A block isn't placed
	where that box overlaps a player (Minecraft's BlockItem.canPlace; server Network/ServerNet and
	the client's BlockInteraction), and falling blocks land on it (server Behaviours/Gravity).
]]
local WHOLE_CELL = table.freeze({ 0, 0, 0, 1, 1, 1 })
local obstructions: { [number]: { number } } = {}
for id, def in defs do
	if def.solid then
		obstructions[id] = WHOLE_CELL
	elseif def.obstructs then
		obstructions[id] = outlines[id] or WHOLE_CELL
	end
end

function Blocks.obstruction(id: number): { number }?
	return obstructions[id]
end

--[[
	What the movement hull bumps into in a block's cell (Shared/Movement/Hull's SolidAt): true for
	a solid block (its whole cell), the boxes of a `collides` block (its outline, block units within
	the cell: a door's panel), else false.
]]
export type CollisionBox = { minX: number, minY: number, minZ: number, maxX: number, maxY: number, maxZ: number }
local collisions: { [number]: { CollisionBox } } = {}
for id, def in defs do
	if def.collides then
		local o = outlines[id] or WHOLE_CELL
		collisions[id] = table.freeze({
			table.freeze({ minX = o[1], minY = o[2], minZ = o[3], maxX = o[4], maxY = o[5], maxZ = o[6] }),
		})
	end
end

function Blocks.collision(id: number): boolean | { CollisionBox }
	if buffer.readu8(Blocks.solidLut, id) == 1 then
		return true
	end
	return collisions[id] or false
end

--[[ Structures: creative only blocks, structure block modes, jigsaws, turning, cave twins ]]

-- Blocks that were renamed: old name -> new name. Names in data (structure palettes, jigsaw
-- final states) saved before the rename still find their block through `find`.
Blocks.RENAMED = table.freeze({
	Glowstone = "GlowBlock",
} :: { [string]: string })

-- The id of the block named `name` (or formerly named, Blocks.RENAMED), or nil when there is
-- none: for names that come from data (structure palettes, jigsaw final states), where
-- `Blocks.id` would error.
function Blocks.find(name: string): number?
	if type(name) ~= "string" then
		return nil
	end
	return rawget(ids :: any, name) or rawget(ids :: any, Blocks.RENAMED[name] or "")
end

-- Is the block creative only (structure blocks, structure voids, jigsaws; BlockList
-- `creativeOnly`)? Survival players can't mine them, and they never drop.
function Blocks.isCreativeOnly(id: number): boolean
	local def = defs[id]
	return def ~= nil and def.creativeOnly
end

-- The structure block of each mode.
local structureBlocks: { [string]: number } = {}
for id, def in defs do
	local mode = def.structureMode
	if mode then
		assert(structureBlocks[mode] == nil, `Two structure blocks in mode {mode}`)
		structureBlocks[mode] = id
	end
end
for _, mode in STRUCTURE_MODES do
	assert(structureBlocks[mode], `No structure block in mode {mode}`)
end

-- The mode a structure block shows ("save", "load", "corner", "data"), nil for other blocks.
function Blocks.structureMode(id: number): string?
	local def = defs[id]
	return if def then def.structureMode else nil
end

-- The structure block showing `mode`, nil for an unknown mode.
function Blocks.structureBlock(mode: string): number?
	return structureBlocks[mode]
end

function Blocks.isStructureBlock(id: number): boolean
	return Blocks.structureMode(id) ~= nil
end

-- The jigsaw of each orientation, keyed "<front>|<top>".
local jigsaws: { [string]: number } = {}
for id, def in defs do
	local orientation = def.jigsaw
	if orientation then
		local key = `{orientation.front}|{orientation.top}`
		assert(jigsaws[key] == nil, `Two jigsaws face {key}`)
		jigsaws[key] = id
	end
end

-- A jigsaw's front and top directions (Minecraft's FrontAndTop), nil for other blocks.
function Blocks.jigsawOrientation(id: number): (string?, string?)
	local def = defs[id]
	local orientation = def and def.jigsaw
	if orientation == nil then
		return nil, nil
	end
	return orientation.front, orientation.top
end

-- The jigsaw facing `front` with `top` up, nil when that is not one of the twelve orientations
-- (a horizontal front needs top Up, a vertical one a horizontal top).
function Blocks.jigsawBlock(front: string, top: string): number?
	return jigsaws[`{front}|{top}`]
end

function Blocks.isJigsaw(id: number): boolean
	local def = defs[id]
	return def ~= nil and def.jigsaw ~= nil
end

local OPPOSITE_DIRECTION = table.freeze(table.clone(OPPOSITE))

-- The opposite of a direction ("North" -> "South").
function Blocks.opposite(direction: string): string
	return OPPOSITE_DIRECTION[direction]
end

-- Minecraft's Direction.fromYRot: the horizontal direction a player looking along (lx, ly, lz)
-- faces, from the yaw rounded to a quarter turn (straight up or down faces South).
local FACINGS = { "South", "West", "North", "East" }
function Blocks.horizontalFacing(lx: number, lz: number): string
	-- (atan2 tells -0 from 0: straight down along -0 would face North.)
	if lx == 0 and lz == 0 then
		return "South"
	end
	local yaw = math.deg(math.atan2(-lx, lz))
	if yaw ~= yaw then
		yaw = 0
	end
	return FACINGS[math.floor(yaw / 90 + 0.5) % 4 + 1]
end

--[[
	The jigsaw a player places by clicking a face whose normal (pointing out of the clicked block)
	is (nx, ny, nz) while looking along (lx, ly, lz): Minecraft's JigsawBlock.getStateForPlacement.
	The front faces out of the clicked face (towards the player); a horizontal front has its top
	Up, a vertical one the opposite of the way the player faces. Without a face ((0, 0, 0)) the
	front faces back along the look (the nearest look direction's opposite).
]]
function Blocks.jigsawPlacement(nx: number, ny: number, nz: number, lx: number, ly: number, lz: number): number
	local front = Blocks.direction(nx, ny, nz) or OPPOSITE[Blocks.lookOrder(lx, ly, lz)[1]]
	local top = if HORIZONTAL[front] then "Up" else OPPOSITE[Blocks.horizontalFacing(lx, lz)]
	return jigsaws[`{front}|{top}`]
end

--[[
	Turning a structure (Minecraft's Rotation and Mirror, as structure blocks and jigsaw assembly
	use them): `rotation` is 0..3 quarter turns clockwise seen from above (North -> East -> South
	-> West), `mirror` "none", "leftRight" (Z flips: North <-> South) or "frontBack" (X flips:
	East <-> West), applied before the rotation. Up and Down never change.
]]
Blocks.MIRRORS = table.freeze({ "none", "leftRight", "frontBack" })
local CLOCKWISE: { [string]: string } =
	{ North = "East", East = "South", South = "West", West = "North", Up = "Up", Down = "Down" }
local MIRRORED: { [string]: { [string]: string } } = {
	none = {},
	leftRight = { North = "South", South = "North" },
	frontBack = { West = "East", East = "West" },
}

-- `direction` (one of the six) after mirroring by `mirror` and turning `rotation` quarter turns
-- clockwise. An unknown mirror counts as "none"; any whole rotation works (it is taken mod 4).
function Blocks.turnDirection(direction: string, rotation: number, mirror: string?): string
	local mirrored = MIRRORED[mirror or "none"] or MIRRORED.none
	local d = mirrored[direction] or direction
	for _ = 1, (math.floor(rotation) % 4) do
		d = CLOCKWISE[d] or d
	end
	return d
end

-- Cave twins and their twins, both ways, and per variant group the twins hanging on each side
-- (or, for an axis group, lying along each axis).
local twinOf: { [number]: number } = {}
local twinFor: { [number]: number } = {}
local twinsBySupport: { [number]: { [string]: number } } = {}
local twinsByAxis: { [number]: { [string]: number } } = {}
for id, def in defs do
	if def.caveTwin then
		local twin = ids[def.caveTwin]
		twinOf[id] = twin
		twinFor[twin] = id
		local base = (variants[twin] or { twin })[1]
		if def.axis then
			local map = twinsByAxis[base] or {}
			twinsByAxis[base] = map
			assert(map[def.axis] == nil, `Two cave twins of {defs[base].name} lie along {def.axis}`)
			map[def.axis] = id
		else
			local map = twinsBySupport[base] or {}
			twinsBySupport[base] = map
			if def.support then
				assert(map[def.support] == nil, `Two cave twins of {defs[base].name} hang on {def.support}`)
				map[def.support] = id
			end
		end
	end
end

-- The block `id` becomes when its structure is turned: its variant (or twin) hanging on the turned
-- side, its variant (or twin) along the other axis after an odd number of quarter turns (mirrors
-- keep an axis), a jigsaw's turned orientation, else itself.
local function turned(id: number, rotation: number, mirror: string): number
	local def = defs[id]
	local door = def.door
	if door then
		-- (A mirror swaps the hinge too: DoorBlock.mirror.)
		local facing = Blocks.turnDirection(door.facing, rotation, mirror)
		local flips = mirror ~= "none" and MIRRORED[mirror] ~= nil
		local hinge = if flips then (if door.hinge == "Left" then "Right" else "Left") else door.hinge
		return Blocks.doorVariant(id, facing, hinge, door.open, door.upper) or id
	end
	local orientation = def.jigsaw
	if orientation then
		local front = Blocks.turnDirection(orientation.front, rotation, mirror)
		local top = Blocks.turnDirection(orientation.top, rotation, mirror)
		return jigsaws[`{front}|{top}`] or id
	end
	local axis = def.axis
	if axis then
		if math.floor(rotation) % 2 == 0 then
			return id
		end
		local other = if axis == "X" then "Z" else "X"
		local family
		if def.caveTwin then
			local twin = twinOf[id]
			family = twinsByAxis[(variants[twin] or { twin })[1]]
		else
			family = byAxis[(variants[id] or { id })[1]]
		end
		return (family and family[other]) or id
	end
	local support = def.support
	if support == nil or support == "Up" or support == "Down" then
		return id
	end
	local side = Blocks.turnDirection(support, rotation, mirror)
	local family
	if def.caveTwin then
		local twin = twinOf[id]
		family = twinsBySupport[(variants[twin] or { twin })[1]]
	else
		family = bySupport[(variants[id] or { id })[1]]
	end
	return (family and family[side]) or id
end

-- Per mirror, per rotation (index rotation + 1): the turned block of each block (u16 per id).
local rotateLuts: { [string]: { buffer } } = {}
for _, mirror in Blocks.MIRRORS do
	local luts = {}
	for rotation = 0, 3 do
		local lut = buffer.create(Blocks.count * 2)
		for id = 0, Blocks.count - 1 do
			buffer.writeu16(lut, id * 2, turned(id, rotation, mirror))
		end
		luts[rotation + 1] = lut
	end
	rotateLuts[mirror] = luts
end

--[[
	The lookup table turning blocks by `rotation` and `mirror` (see above): u16 per block id, read
	with buffer.readu16(lut, id * 2). For hot loops writing a structure's cells. Read only.
]]
function Blocks.rotateLut(rotation: number, mirror: string?): buffer
	local luts = rotateLuts[mirror or "none"] or rotateLuts.none
	return luts[math.floor(rotation) % 4 + 1]
end

-- The block `id` becomes when its structure is turned by `rotation` and `mirror`: wall torches,
-- ladders, vines, glow lichen (cave twins stay twins) and jigsaws face the turned way, rails lie
-- along the turned axis; everything else is unchanged. Unknown ids come back as they are.
function Blocks.rotate(id: number, rotation: number, mirror: string?): number
	if defs[id] == nil then
		return id
	end
	return buffer.readu16(Blocks.rotateLut(rotation, mirror), id * 2)
end

-- Is the block a cave twin (BlockList `caveTwin`)?
function Blocks.isCaveTwin(id: number): boolean
	return twinOf[id] ~= nil
end

-- The block a cave twin twins (CaveGlowLichenNorth -> GlowLichenNorth), nil for other blocks.
function Blocks.caveTwinOf(id: number): number?
	return twinOf[id]
end

-- The cave twin of a block (GlowLichenNorth -> CaveGlowLichenNorth), nil when it has none.
function Blocks.caveTwinFor(id: number): number?
	return twinFor[id]
end

--[[
	The block as a saved structure keeps it: cave air becomes air and a cave twin its twin, so a
	structure saved in a cave and placed in the open has nothing the mesher hides with caves.
	Everything else is itself.
]]
function Blocks.surfaceForm(id: number): number
	if id == Blocks.CAVE_AIR then
		return Blocks.AIR
	end
	return twinOf[id] or id
end

return Blocks
