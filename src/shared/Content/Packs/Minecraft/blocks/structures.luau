--!strict
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

local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

type BlockSpec = Schema.BlockSpec

local STRUCTURE_COLOUR = { 38, 29, 42 }

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

local list: { BlockSpec } = {}
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
		lore = if item then "Saves and loads structures. Creative only." else nil,
		-- (/locate poi finds every mode: the others are the item's, Shared/Poi.)
		poi = if item then "structure_block" else nil,
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
	lore = "Marks cells a structure leaves as they are. Creative only.",
})

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
		lore = if item then "Joins structure pieces together. Creative only." else nil,
		poi = if item then "jigsaw" else nil,
	})
end

return list
