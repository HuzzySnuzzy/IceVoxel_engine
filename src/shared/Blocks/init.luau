--!strict
--[[
	Block registry.

	Turns `BlockList` into:
	  * `Blocks.id.Name -> id` (errors on unknown names, so typos fail loudly),
	  * `Blocks.get(id) -> BlockDef`,
	  * "appearances": groups of blocks that look identical when drawn (e.g. all water levels). The
	    mesher merges boxes per appearance, and the renderer keeps one part template per appearance,
	  * flat buffer lookup tables used by the hot generation / meshing loops.
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
	texture: string?,
	tint: { number },
	faces: { [string]: string }?,
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

local defs: { [number]: BlockDef } = {}
local ids: { [string]: number } = {}
local appearances: { Appearance } = {}
local appearanceByKey: { [string]: number } = {}
local fluidIds: { [string]: { [number]: number } } = {}
local placeable: { number } = {}

for index, spec in BlockList do
	local id = index - 1
	assert(ids[spec.name] == nil, `Duplicate block name {spec.name}`)

	local render = spec.render or "Opaque"
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
		texture = spec.texture,
		tint = spec.tint or { 255, 255, 255 },
		faces = spec.faces,
		appearance = 0,
	}

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
		local key = `{look}|{if solid then 1 else 0}|{texture}|{def.decor or ""}`
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

-- 1 per *appearance* id when its blocks are meshed one box per block (decorated faces).
Blocks.singleLut = buffer.create(#appearances + 1)
for _, appearance in appearances do
	buffer.writeu8(Blocks.singleLut, appearance.id, if appearance.decor then 1 else 0)
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

return Blocks
