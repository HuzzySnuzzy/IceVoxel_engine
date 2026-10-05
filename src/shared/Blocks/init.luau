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
	    broken, placed, hit, walked and fallen on (Shared/Sounds plays `block.<type>.<action>`).
]]

local BlockList = require(script.BlockList)

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
	-- The tool that mines it fast ("pickaxe", "axe", "shovel", "hoe"), and the tier it needs to
	-- drop anything (nil: drops by hand).
	tool: string?,
	toolLevel: number?,
	-- Item name dropped when broken in survival (nil = the block itself, false = nothing) and how
	-- many; see Items.drops.
	drops: (string | false)?,
	dropCount: number,
	-- Item slots the block keeps (chest 27, furnace 3), 0 for other blocks.
	container: number,
	-- What right clicking opens ("Chest", "Crafting", "Furnace"), nil for nothing.
	menu: string?,
	-- Faces drawn on its parts (client Rendering/BlockDecor), one part per block.
	decor: string?,
	-- Sound type (one of Blocks.SOUND_TYPES; Shared/Sounds), nil for silent blocks (air).
	sound: string?,
	texture: string?,
	tint: { number },
	faces: { [string]: string }?,
	-- Light given off (0..15) and its colour; see BlockList.
	light: number,
	lightColor: { number },
	-- Boxes drawn instead of a cube (pixels from the cell's centre), and the outline aimed at
	-- (pixels 0..16); see BlockList.
	shape: { ShapeBox }?,
	bounds: Bounds,
	-- Not solid, but has a collision box in Minecraft (lanterns; see Blocks.obstruction).
	obstructs: boolean,
	-- The direction of the block it hangs on (nil: needs nothing) and the item placing / dropping
	-- it when that is not the block itself.
	support: string?,
	item: string?,
	brokenByFluid: boolean,
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
	-- MaterialVariant name, tint applied with it and per-face images (see BlockList).
	texture: string?,
	tint: { number },
	faces: { [string]: string }?,
	-- Faces drawn on its parts (Rendering/BlockDecor); such blocks are meshed one box per block.
	decor: string?,
	-- Light given off (0..15; > 0 puts a PointLight on its parts) and its colour.
	light: number,
	lightColor: { number },
	-- Boxes drawn instead of a cube (see BlockList); such blocks are meshed one box per block.
	shape: { ShapeBox }?,
}

export type ShapeBox = BlockList.ShapeBox
export type Bounds = BlockList.Bounds

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
-- Boxes a shaped block may have (the renderer keys part templates by box index).
Blocks.MAX_SHAPE_BOXES = 15

--[[
	Sound types, Minecraft's SoundType: how a block sounds when broken, placed, hit while mining,
	walked on and fallen on. Shared/Sounds has the events `block.<type>.<action>` for each. A
	block's type is its `sound`, else its material's (SOUND_BY_MATERIAL), else stone; fluids sound
	like water and blocks that are never drawn (air) like nothing.
]]
Blocks.SOUND_TYPES =
	table.freeze({ "stone", "wood", "gravel", "grass", "sand", "glass", "snow", "metal", "wool", "water" })
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
		sturdy = solid and drawn and spec.shape == nil and spec.sturdy ~= false,
		replaceable = spec.replaceable or false,
		breakable = breakable,
		placeable = if spec.placeable ~= nil then spec.placeable else (drawn and solid),
		behaviour = spec.behaviour,
		friction = spec.friction or 0.6,
		fluid = spec.fluid,
		displayName = spec.displayName,
		hardness = if breakable then spec.hardness or 1 else -1,
		tool = spec.tool,
		toolLevel = spec.toolLevel,
		drops = spec.drops,
		dropCount = spec.dropCount or 1,
		container = spec.container or 0,
		menu = spec.menu,
		decor = spec.decor,
		sound = if spec.sound
			then spec.sound
			elseif kind == Blocks.KIND_NONE then nil
			elseif kind == Blocks.KIND_FLUID then "water"
			else SOUND_BY_MATERIAL[spec.material or "SmoothPlastic"] or "stone",
		texture = spec.texture,
		tint = spec.tint or { 255, 255, 255 },
		faces = spec.faces,
		light = math.clamp(spec.light or 0, 0, 15),
		lightColor = spec.lightColor or DEFAULT_LIGHT_COLOR,
		shape = spec.shape,
		bounds = spec.bounds or (if spec.shape then shapeBounds(spec.shape) else FULL_CELL),
		obstructs = spec.obstructs == true,
		support = spec.support,
		item = spec.item,
		brokenByFluid = spec.brokenByFluid == true,
		appearance = 0,
	}
	assert(spec.shape == nil or #spec.shape <= Blocks.MAX_SHAPE_BOXES, `Block {spec.name} has too many shape boxes`)
	assert(def.sound == nil or soundIndex[def.sound], `Block {spec.name} has unknown sound {def.sound}`)

	if drawn then
		local c, t = def.color, def.tint
		local faces = {}
		local faceImages: { [string]: string } = def.faces or {}
		for face, image in faceImages do
			table.insert(faces, `{face}={image}`)
		end
		table.sort(faces)
		local look = `{kind}|{def.material}|{c[1]},{c[2]},{c[3]}|{def.transparency}|{def.reflectance}`
		local texture = `{def.texture or ""}|{t[1]},{t[2]},{t[3]}|{table.concat(faces, ";")}`
		local lc = def.lightColor
		-- (Shaped blocks get an appearance each: their boxes are their look.)
		local glow = `{def.light}|{lc[1]},{lc[2]},{lc[3]}|{if def.shape then def.name else ""}`
		local key = `{look}|{if solid then 1 else 0}|{texture}|{def.decor or ""}|{glow}`
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
				texture = def.texture,
				tint = def.tint,
				faces = def.faces,
				decor = def.decor,
				light = def.light,
				lightColor = def.lightColor,
				shape = def.shape,
			})
		end
		def.appearance = appearance
	end

	if def.fluid then
		local group = def.fluid.group
		fluidIds[group] = fluidIds[group] or {}
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
-- (drawn box by box in every cell) and light sources (one light per block).
Blocks.singleLut = buffer.create(#appearances + 1)
for _, appearance in appearances do
	local single = appearance.decor ~= nil or appearance.shape ~= nil or appearance.light > 0
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

-- Same, but cave air also counts as solid rock (used for sections far away from the camera).
Blocks.cullLutHiddenCaves = u8Lut(function(def)
	return def.kind == Blocks.KIND_OPAQUE or def.id == Blocks.CAVE_AIR
end)

Blocks.solidLut = u8Lut(function(def)
	return def.solid
end)

Blocks.replaceableLut = u8Lut(function(def)
	return def.replaceable
end)

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

-- Block id of `group` (e.g. "Water") at `level` (0 = source, 1-7 = flowing, 8 = falling).
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
	Variants: a block and the blocks whose `item` names it (Torch and the four wall torches,
	Lantern and HangingLantern). Placing the item picks one of them; they all drop it.
]]
local variants: { [number]: { number } } = {}
-- Per variant group (keyed by its first block): the variant that hangs on each direction.
local bySupport: { [number]: { [string]: number } } = {}
for id = 0, Blocks.count - 1 do
	local def = defs[id]
	local base = if def.item then rawget(ids :: any, def.item) else nil
	-- (A typo would otherwise leave the variant silently unplaceable.)
	assert(def.item == nil or base ~= nil, `Block {def.name} names unknown block {def.item} as its item`)
	if base ~= nil then
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
for _, group in variants do
	local base = group[1]
	if bySupport[base] == nil then
		local map = {}
		for _, id in group do
			local support = defs[id].support
			if support then
				assert(map[support] == nil, `Two variants of {defs[base].name} hang on {support}`)
				map[support] = id
			end
		end
		bySupport[base] = map
	end
end
for id, def in defs do
	if def.support and variants[id] == nil then
		-- An attached block without variants (a lone support) is its own group.
		variants[id] = { id }
		bySupport[id] = { [def.support] = id }
	end
end

-- The blocks one item places (the block's own first), e.g. Torch and the wall torches.
function Blocks.variants(block: number): { number }
	return variants[block] or { block }
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

--[[
	Can `block` stay at (x, y, z)? Blocks with a `support` need a sturdy block on that side
	(Minecraft's canSurvive: TorchBlock, WallTorchBlock, LanternBlock). `getBlock` answers nil for
	unknown (unloaded) blocks, which hold nothing up.
]]
function Blocks.canSurvive(
	block: number,
	getBlock: (x: number, y: number, z: number) -> number?,
	x: number,
	y: number,
	z: number
): boolean
	local dx, dy, dz = Blocks.supportOffset(block)
	if dx == nil or dy == nil or dz == nil then
		return true
	end
	local support = getBlock(x + dx, y + dy, z + dz)
	return support ~= nil and Blocks.isSturdy(support)
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

--[[
	The variant of `block`'s item hanging on the face that was clicked, whose normal is
	(nx, ny, nz): the block the face belongs to is the support. nil when no variant hangs that way
	(a torch under a ceiling). Blocks without supports are their own answer.
]]
function Blocks.variantFor(block: number, nx: number, ny: number, nz: number): number?
	local group = variants[block]
	if group == nil then
		return block
	end
	local direction = Blocks.direction(-nx, -ny, -nz)
	return if direction then bySupport[group[1]][direction] else nil
end

-- The torch for a clicked face: a standing torch on top, a wall torch facing away from a side,
-- nothing under a block.
function Blocks.torchFor(nx: number, ny: number, nz: number): number?
	return Blocks.variantFor(rawget(ids :: any, "Torch") :: number, nx, ny, nz)
end

local HORIZONTAL: { [string]: boolean } = { North = true, South = true, West = true, East = true }

--[[
	The block placing `block`'s item at (x, y, z) makes: Minecraft's BlockPlaceContext order (the
	clicked face's support first, then the directions the player looks along, `lookOrder`).
	  * Up or down: the variant hanging that way, if it can survive there (TorchBlock,
	    LanternBlock.getStateForPlacement).
	  * A side: the wall variant, which is the first side in the whole order whose variant
	    survives (WallTorchBlock.getStateForPlacement), even one listed after a floor that would
	    hold a standing torch (StandingAndWallBlockItem asks the wall block at the first side).
	The first answer wins. A torch clicked under a ceiling still goes on a wall or the floor next
	to it when there is one. nil: nothing can hold it. (nx, ny, nz) = (0, 0, 0) uses the look order
	alone. Blocks without supports place as they are.
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
	z: number
): number?
	local group = variants[block]
	if group == nil then
		return block
	end
	local hanging = bySupport[group[1]]
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
		if HORIZONTAL[direction] and variant and Blocks.canSurvive(variant, getBlock, x, y, z) then
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
			if variant and Blocks.canSurvive(variant, getBlock, x, y, z) then
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
for id, def in defs do
	local b = def.bounds
	if b ~= FULL_CELL then
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

return Blocks
