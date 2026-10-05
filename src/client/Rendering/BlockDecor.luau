--!strict
--[[
	Decorated block faces: chests, crafting tables, furnaces, Mekanism's Creative Energy Cube,
	Heat Generator, Electric Furnace and Batteries (Energy Cubes), and Minecraft's structure blocks
	and jigsaw blocks, drawn like Minecraft's pixel art.

	No image assets are needed. Each face is a 16 x 16 "pixel" picture made of coloured rectangles,
	painted in order over the block's own part (its material and colour show wherever no rectangle
	covers it, e.g. the chest's planks inside its outline, or the furnace's cobblestone). The same data
	is drawn two ways:

	  world blocks  `applySurfaces`: one SurfaceGui per face with a Frame per rectangle (scale
	                positions, so any part size works). PartPool puts them on the near templates of
	                appearances with `decor`; the mesher keeps such blocks one part each.
	  item models   `buildParts`: ViewportFrames do not draw SurfaceGuis, so icons, dropped items and
	                the item in hand get thin raised slabs instead (ItemModels). Rectangles marked
	                `surfaceOnly` (fine detail, and the front details repeated on the sides of world
	                blocks, which have no facing) are left out there, so an icon stays under 40 parts
	                and shows the front on its left face, as Minecraft's icons do.

	Pixel coordinates are seen from outside the face: x to the right, y down, from the top left
	corner. Side faces are upright (+Y up). Faces are named like Enum.NormalId: Front is -Z (North),
	Back +Z (South), Left -X (West), Right +X (East). `faces`, `basis` and `layers` are pure data, so
	tests can check them.

	Jigsaw blocks face a way (one block per orientation, "Jigsaw<Front><Top>"), so their pictures
	are turned on each face towards the block's front or top with `basis`. Side faces are upright
	in SurfaceGuis whatever the block; on the top and bottom faces the pictures assume a SurfaceGui
	is drawn with `basis`'s right and up (item models are, by construction). The front, the face
	towards the top and the four sides all show the orientation, so it reads on upright faces
	alone.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Tiers = require(Shared.Transmitters.Tiers)

export type Rect = {
	x: number,
	y: number,
	w: number,
	h: number,
	colour: { number },
	-- Drawn on world blocks only (not on item models).
	surfaceOnly: boolean?,
}

-- Rectangles per face, keyed by Enum.NormalId name.
export type Faces = { [string]: { Rect } }

local BlockDecor = {}

-- Pixels across a face.
BlockDecor.GRID = 16
BlockDecor.FACES = table.freeze({ "Top", "Bottom", "Front", "Back", "Left", "Right" })

-- The SurfaceGui canvas: 4 canvas pixels per face pixel.
local CANVAS = 64
-- World faces stop drawing this far away (studs); a block is a few pixels wide there.
local MAX_DISTANCE = 96 * Config.BlockSize
-- Thickness of an item model's slab, as a share of the cube's size (each layer adds one).
local SLAB = 0.012

--[[ Face data ]]

local function rect(x: number, y: number, w: number, h: number, colour: { number }, surfaceOnly: boolean?): Rect
	return { x = x, y = y, w = w, h = h, colour = colour, surfaceOnly = surfaceOnly }
end

-- A one pixel frame around the face.
local function outline(colour: { number }, surfaceOnly: boolean?): { Rect }
	return {
		rect(0, 0, 16, 1, colour, surfaceOnly),
		rect(0, 15, 16, 1, colour, surfaceOnly),
		rect(0, 1, 1, 14, colour, surfaceOnly),
		rect(15, 1, 1, 14, colour, surfaceOnly),
	}
end

local function join(...: { Rect }): { Rect }
	local all = {}
	for _, list in { ... } do
		for _, r in list do
			table.insert(all, r)
		end
	end
	return all
end

--[[
	Chest (Minecraft's chest model, as a full block): planks with a dark outline, the lid's seam 5/16
	from the top and the light grey latch over it. Blocks have no facing, so world chests show the
	latch on all four sides; item models only on the front pair (the icon's left face).
]]
local CHEST_EDGE = { 58, 37, 17 }
local CHEST_RIM = { 120, 84, 38 }
local LATCH = { 200, 200, 204 }
local LATCH_SHADE = { 104, 104, 110 }

local function chestSide(latchSurfaceOnly: boolean): { Rect }
	return join(outline(CHEST_EDGE), {
		rect(1, 5, 14, 1, CHEST_EDGE),
		rect(1, 6, 14, 1, CHEST_RIM, true),
		rect(7, 3, 2, 4, LATCH, latchSurfaceOnly),
		rect(7, 6, 2, 1, LATCH_SHADE, true),
	})
end

local CHEST: Faces = {
	Top = join(outline(CHEST_EDGE), {
		rect(1, 5, 14, 1, CHEST_RIM, true),
		rect(1, 10, 14, 1, CHEST_RIM, true),
	}),
	Bottom = outline(CHEST_EDGE, true),
	Front = chestSide(false),
	Back = chestSide(false),
	Left = chestSide(true),
	Right = chestSide(true),
}

--[[
	Crafting table: a light top with a dark frame and a 3 x 3 grid; sides with the top's edge, corner
	posts and tools hanging on them (a saw on the front pair, a hammer and tongs on the others); oak
	planks underneath.
]]
local TABLE_FRAME = { 92, 62, 32 }
local TABLE_TOP = { 184, 146, 92 }
local TABLE_GRID = { 124, 88, 48 }
local TABLE_BAND = { 176, 138, 86 }
local TABLE_BAND_SHADE = { 72, 48, 24 }
local TABLE_POST = { 84, 56, 28 }
local TOOL_IRON = { 170, 170, 176 }
local TOOL_IRON_DARK = { 98, 98, 104 }
local TOOL_HANDLE = { 150, 104, 56 }
local PLANK_LINE = { 96, 66, 36 }

local function tableSide(tools: { Rect }): { Rect }
	return join({
		rect(0, 0, 16, 3, TABLE_BAND),
		rect(0, 3, 16, 1, TABLE_BAND_SHADE),
		rect(0, 4, 1, 12, TABLE_POST, true),
		rect(15, 4, 1, 12, TABLE_POST, true),
	}, tools)
end

local SAW: { Rect } = {
	rect(3, 6, 8, 4, TOOL_IRON),
	rect(3, 10, 8, 1, TOOL_IRON_DARK),
	rect(4, 11, 1, 1, TOOL_IRON_DARK, true),
	rect(6, 11, 1, 1, TOOL_IRON_DARK, true),
	rect(8, 11, 1, 1, TOOL_IRON_DARK, true),
	rect(10, 11, 1, 1, TOOL_IRON_DARK, true),
	rect(11, 5, 3, 6, TOOL_HANDLE),
	rect(12, 7, 1, 2, TABLE_BAND_SHADE, true),
}

local HAMMER: { Rect } = {
	rect(3, 6, 7, 3, TOOL_IRON),
	rect(3, 6, 1, 3, TOOL_IRON_DARK, true),
	rect(6, 9, 2, 6, TOOL_HANDLE),
	-- Tongs.
	rect(11, 6, 1, 9, TOOL_IRON_DARK, true),
	rect(13, 6, 1, 9, TOOL_IRON_DARK, true),
	rect(11, 6, 3, 1, TOOL_IRON_DARK, true),
}

-- Minecraft's oak planks: four boards with staggered joints.
local PLANKS: { Rect } = {
	rect(0, 3, 16, 1, PLANK_LINE, true),
	rect(0, 7, 16, 1, PLANK_LINE, true),
	rect(0, 11, 16, 1, PLANK_LINE, true),
	rect(0, 15, 16, 1, PLANK_LINE, true),
	rect(6, 0, 1, 3, PLANK_LINE, true),
	rect(11, 4, 1, 3, PLANK_LINE, true),
	rect(3, 8, 1, 3, PLANK_LINE, true),
	rect(9, 12, 1, 3, PLANK_LINE, true),
}

local CRAFTING_TABLE: Faces = {
	Top = {
		rect(0, 0, 16, 16, TABLE_FRAME),
		rect(1, 1, 14, 14, TABLE_TOP),
		rect(5, 1, 1, 14, TABLE_GRID),
		rect(10, 1, 1, 14, TABLE_GRID),
		rect(1, 5, 14, 1, TABLE_GRID),
		rect(1, 10, 14, 1, TABLE_GRID),
	},
	Bottom = PLANKS,
	Front = tableSide(SAW),
	Back = tableSide(SAW),
	Left = tableSide(HAMMER),
	Right = tableSide(HAMMER),
}

--[[
	Furnace: cobblestone sides (the part's own material) under a smoother top band, with the dark
	mouth and the grate above it; plain stone top and bottom. World furnaces show the mouth on all
	four sides; item models only on the front pair, like Minecraft's icon.
]]
local FURNACE_BAND = { 138, 138, 140 }
local FURNACE_BAND_SHADE = { 80, 80, 82 }
local MOUTH_FRAME = { 70, 70, 72 }
local GRATE = { 38, 38, 40 }
local GRATE_BAR = { 98, 98, 102 }
local MOUTH = { 20, 20, 22 }
local STONE_EDGE = { 104, 104, 106 }
local STONE = { 142, 142, 144 }

local function furnaceSide(mouthSurfaceOnly: boolean): { Rect }
	return {
		rect(0, 0, 16, 3, FURNACE_BAND),
		rect(0, 3, 16, 1, FURNACE_BAND_SHADE, true),
		rect(3, 6, 10, 8, MOUTH_FRAME, mouthSurfaceOnly),
		rect(4, 7, 8, 2, GRATE, mouthSurfaceOnly),
		rect(6, 7, 1, 2, GRATE_BAR, true),
		rect(9, 7, 1, 2, GRATE_BAR, true),
		rect(4, 10, 8, 3, MOUTH, mouthSurfaceOnly),
	}
end

local function stone(surfaceOnly: boolean?): { Rect }
	return { rect(0, 0, 16, 16, STONE_EDGE, surfaceOnly), rect(1, 1, 14, 14, STONE, surfaceOnly) }
end

local FURNACE: Faces = {
	Top = stone(),
	Bottom = stone(true),
	Front = furnaceSide(false),
	Back = furnaceSide(false),
	Left = furnaceSide(true),
	Right = furnaceSide(true),
}

--[[
	Creative Energy Cube (Mekanism's creative energy cube): the same on every face, a dark steel
	plate with magenta corners and a glowing magenta window in the middle, the colour Minecraft
	gives epic, creative-only things.
]]
local CUBE_EDGE = { 24, 22, 30 }
local CUBE_CORNER = { 176, 64, 196 }
local CUBE_WINDOW = { 30, 16, 40 }
local CUBE_CORE = { 236, 128, 252 }

local function cubeFace(): { Rect }
	local rects = outline(CUBE_EDGE, true)
	for _, corner in { { 1, 1 }, { 12, 1 }, { 1, 12 }, { 12, 12 } } do
		table.insert(rects, rect(corner[1], corner[2], 3, 3, CUBE_CORNER))
	end
	table.insert(rects, rect(4, 4, 8, 8, CUBE_WINDOW))
	table.insert(rects, rect(6, 6, 4, 4, CUBE_CORE))
	return rects
end

local CREATIVE_ENERGY_CUBE: Faces = {
	Top = cubeFace(),
	Bottom = cubeFace(),
	Front = cubeFace(),
	Back = cubeFace(),
	Left = cubeFace(),
	Right = cubeFace(),
}

--[[
	Heat Generator (Mekanism Generators'): a dark steel casing with osmium bolts, a grille across the
	top of each side and over the top, and the fuel window low on each side, dark while it is out.
	While it burns the client lights the window (Rendering/TransmitterModel.machineBoxes draws a
	glowing pane over GENERATOR_WINDOW from the machine's record). Item models show the window on
	the front pair only, like the furnace's mouth.
]]
local GENERATOR_EDGE = { 30, 31, 36 }
local GENERATOR_BOLT = { 150, 172, 200 }
local GRILLE_DARK = { 20, 20, 24 }
local GRILLE_LIGHT = { 96, 100, 110 }
local WINDOW_FRAME = { 36, 36, 40 }
local EMBER = { 74, 36, 22 }
-- The fuel window on every side (pixels from the face's top left; the glow covers exactly it).
BlockDecor.GENERATOR_WINDOW = table.freeze({ x = 5, y = 10, w = 6, h = 3 })
local WINDOW = BlockDecor.GENERATOR_WINDOW

local function bolts(): { Rect }
	return {
		rect(1, 1, 1, 1, GENERATOR_BOLT, true),
		rect(14, 1, 1, 1, GENERATOR_BOLT, true),
		rect(1, 14, 1, 1, GENERATOR_BOLT, true),
		rect(14, 14, 1, 1, GENERATOR_BOLT, true),
	}
end

local function generatorSide(windowSurfaceOnly: boolean): { Rect }
	return join(outline(GENERATOR_EDGE, true), bolts(), {
		rect(3, 2, 10, 5, GRILLE_DARK),
		rect(3, 3, 10, 1, GRILLE_LIGHT, true),
		rect(3, 5, 10, 1, GRILLE_LIGHT, true),
		rect(WINDOW.x - 1, WINDOW.y - 1, WINDOW.w + 2, WINDOW.h + 2, WINDOW_FRAME, windowSurfaceOnly),
		rect(WINDOW.x, WINDOW.y, WINDOW.w, WINDOW.h, EMBER, windowSurfaceOnly),
	})
end

local HEAT_GENERATOR: Faces = {
	Top = join(outline(GENERATOR_EDGE, true), bolts(), {
		rect(3, 3, 10, 10, GRILLE_DARK),
		rect(3, 5, 10, 1, GRILLE_LIGHT, true),
		rect(3, 7, 10, 1, GRILLE_LIGHT, true),
		rect(3, 9, 10, 1, GRILLE_LIGHT, true),
		rect(3, 11, 10, 1, GRILLE_LIGHT, true),
	}),
	Bottom = outline(GENERATOR_EDGE, true),
	Front = generatorSide(false),
	Back = generatorSide(false),
	Left = generatorSide(true),
	Right = generatorSide(true),
}

--[[
	Electric Furnace (Mekanism's Energized Smelter): a light steel casing with darker edges and
	osmium bolts, the heating chamber's window high on each side with its coils showing dark while
	it is off, a vent under it and a vent over the top. While it smelts the client lights the
	chamber (Rendering/TransmitterModel.machineBoxes draws a glowing pane over
	ELECTRIC_FURNACE_WINDOW from the machine's record). Item models show the window on the front
	pair only, like the furnace's mouth.
]]
local SMELTER_EDGE = { 96, 100, 108 }
local SMELTER_BOLT = { 104, 130, 168 }
local CHAMBER_FRAME = { 58, 60, 66 }
local CHAMBER = { 40, 30, 28 }
local COIL = { 120, 64, 40 }
local VENT = { 72, 74, 80 }
local VENT_SLAT = { 120, 124, 132 }
-- The heating chamber's window on every side (pixels from the face's top left; the glow covers
-- exactly it).
BlockDecor.ELECTRIC_FURNACE_WINDOW = table.freeze({ x = 4, y = 4, w = 8, h = 5 })
local CHAMBER_WINDOW = BlockDecor.ELECTRIC_FURNACE_WINDOW

local function smelterBolts(): { Rect }
	return {
		rect(1, 1, 1, 1, SMELTER_BOLT, true),
		rect(14, 1, 1, 1, SMELTER_BOLT, true),
		rect(1, 14, 1, 1, SMELTER_BOLT, true),
		rect(14, 14, 1, 1, SMELTER_BOLT, true),
	}
end

local function smelterSide(windowSurfaceOnly: boolean): { Rect }
	local w = CHAMBER_WINDOW
	return join(outline(SMELTER_EDGE, true), smelterBolts(), {
		rect(w.x - 1, w.y - 1, w.w + 2, w.h + 2, CHAMBER_FRAME, windowSurfaceOnly),
		rect(w.x, w.y, w.w, w.h, CHAMBER, windowSurfaceOnly),
		-- The heating coils across the chamber.
		rect(w.x, w.y + 1, w.w, 1, COIL, true),
		rect(w.x, w.y + 3, w.w, 1, COIL, true),
		-- A vent under the window.
		rect(4, 11, 8, 3, VENT, windowSurfaceOnly),
		rect(4, 12, 8, 1, VENT_SLAT, true),
	})
end

local ELECTRIC_FURNACE: Faces = {
	Top = join(outline(SMELTER_EDGE, true), smelterBolts(), {
		rect(4, 4, 8, 8, VENT),
		rect(4, 6, 8, 1, VENT_SLAT, true),
		rect(4, 9, 8, 1, VENT_SLAT, true),
	}),
	Bottom = outline(SMELTER_EDGE, true),
	Front = smelterSide(false),
	Back = smelterSide(false),
	Left = smelterSide(true),
	Right = smelterSide(true),
}

--[[
	Batteries (Mekanism's Energy Cubes, "<Tier>Battery"): a dark steel cube with 3 x 3 corners in
	the tier's colour on every face (Mekanism's energy cube frame; Transmitters/Tiers colours, as on
	cables and tanks), a charge gauge on each side, a terminal on top and a plate underneath. The
	gauge is dark while empty; the client fills it from the bottom with the battery's charge
	(Rendering/TransmitterModel.machineBoxes draws glowing panes over BATTERY_GAUGE from its
	record). Item models show the gauge on the front pair only, like the furnace's mouth.
]]
local BATTERY_EDGE = { 28, 29, 34 }
local GAUGE_FRAME = { 34, 35, 40 }
local GAUGE_EMPTY = { 14, 15, 18 }
local GAUGE_TICK = { 70, 72, 80 }
local TERMINAL = { 176, 178, 186 }
local BATTERY_PLATE = { 40, 42, 48 }
-- The charge gauge on every side (pixels from the face's top left; the charge fills it from the
-- bottom, exactly over it).
BlockDecor.BATTERY_GAUGE = table.freeze({ x = 6, y = 3, w = 4, h = 10 })
local GAUGE = BlockDecor.BATTERY_GAUGE

local function batteryCorners(tier: { number }): { Rect }
	local rects = outline(BATTERY_EDGE, true)
	for _, corner in { { 1, 1 }, { 12, 1 }, { 1, 12 }, { 12, 12 } } do
		table.insert(rects, rect(corner[1], corner[2], 3, 3, tier))
	end
	return rects
end

local function batterySide(tier: { number }, gaugeSurfaceOnly: boolean): { Rect }
	return join(batteryCorners(tier), {
		rect(GAUGE.x - 1, GAUGE.y - 1, GAUGE.w + 2, GAUGE.h + 2, GAUGE_FRAME, gaugeSurfaceOnly),
		rect(GAUGE.x, GAUGE.y, GAUGE.w, GAUGE.h, GAUGE_EMPTY, gaugeSurfaceOnly),
		-- Marks at a quarter, a half and three quarters, beside the gauge.
		rect(GAUGE.x + GAUGE.w + 1, GAUGE.y + 2, 1, 1, GAUGE_TICK, true),
		rect(GAUGE.x + GAUGE.w + 1, GAUGE.y + 5, 1, 1, GAUGE_TICK, true),
		rect(GAUGE.x + GAUGE.w + 1, GAUGE.y + 7, 1, 1, GAUGE_TICK, true),
	})
end

local function batteryFaces(tier: { number }): Faces
	return {
		-- A "+" terminal (the same turned by a quarter, as item models need).
		Top = join(batteryCorners(tier), {
			rect(7, 4, 2, 8, TERMINAL),
			rect(4, 7, 3, 2, TERMINAL),
			rect(9, 7, 3, 2, TERMINAL),
		}),
		Bottom = join(batteryCorners(tier), { rect(5, 5, 6, 6, BATTERY_PLATE) }),
		Front = batterySide(tier, false),
		Back = batterySide(tier, false),
		Left = batterySide(tier, true),
		Right = batterySide(tier, true),
	}
end

--[[
	Structure blocks (Minecraft 1.20.1's structure_block_<mode> textures, the same on every face):
	the block's dark purple black rim around a black field, light purple arcs in the corners and
	notches in the middle of each edge, and the mode's sigil in the middle: SAVE a filled rounded
	diamond, LOAD a hollow ring, CORNER a twisted square, DATA four petals. Item models keep the
	field and the sigil's main shapes.
]]
local SB_FIELD = { 16, 16, 16 }
local SB_DARK = { 38, 29, 42 }
local SB_MID = { 112, 94, 112 }
local SB_LIGHT = { 150, 120, 150 }
local SB_BRIGHT = { 190, 156, 190 }
local SB_WHITE = { 215, 186, 215 }

-- `r` mirrored left to right, and top to bottom.
local function flipX(r: Rect): Rect
	return rect(16 - r.x - r.w, r.y, r.w, r.h, r.colour, r.surfaceOnly)
end

local function flipY(r: Rect): Rect
	return rect(r.x, 16 - r.y - r.h, r.w, r.h, r.colour, r.surfaceOnly)
end

-- `rects` drawn in the top left quarter, and their mirror images in the other three.
local function fourWays(rects: { Rect }): { Rect }
	local all = {}
	for _, r in rects do
		table.insert(all, r)
		table.insert(all, flipX(r))
		table.insert(all, flipY(r))
		table.insert(all, flipX(flipY(r)))
	end
	return all
end

local function structureFrame(): { Rect }
	return join(
		{ rect(1, 1, 14, 14, SB_FIELD) },
		{
			rect(6, 1, 4, 1, SB_BRIGHT, true),
			rect(6, 14, 4, 1, SB_BRIGHT, true),
			rect(1, 6, 1, 4, SB_BRIGHT, true),
			rect(14, 6, 1, 4, SB_BRIGHT, true),
		},
		fourWays({
			rect(4, 2, 2, 1, SB_LIGHT, true),
			rect(3, 3, 1, 1, SB_LIGHT, true),
			rect(2, 4, 1, 2, SB_LIGHT, true),
		})
	)
end

-- The light dots around SAVE's and LOAD's sigils.
local function sigilDots(): { Rect }
	return {
		rect(7, 3, 2, 1, SB_LIGHT, true),
		rect(7, 12, 2, 1, SB_LIGHT, true),
		rect(3, 7, 1, 2, SB_LIGHT, true),
		rect(12, 7, 1, 2, SB_LIGHT, true),
	}
end

local SIGILS: { [string]: { Rect } } = {
	Save = join(sigilDots(), {
		rect(6, 4, 4, 8, SB_BRIGHT),
		rect(5, 5, 6, 6, SB_BRIGHT),
		rect(4, 6, 8, 4, SB_BRIGHT),
		rect(7, 6, 2, 4, SB_WHITE),
		rect(6, 7, 4, 2, SB_WHITE),
	}),
	Load = join(sigilDots(), {
		rect(7, 4, 2, 1, SB_WHITE),
		rect(7, 11, 2, 1, SB_WHITE),
		rect(4, 7, 1, 2, SB_BRIGHT),
		rect(11, 7, 1, 2, SB_BRIGHT),
	}, fourWays({ rect(6, 5, 1, 1, SB_WHITE, true), rect(5, 6, 1, 1, SB_WHITE, true) })),
	Corner = {
		rect(5, 4, 8, 1, SB_MID, true),
		rect(11, 3, 1, 1, SB_MID, true),
		rect(11, 5, 1, 6, SB_MID, true),
		rect(4, 5, 1, 7, SB_MID, true),
		rect(5, 11, 6, 1, SB_MID, true),
		rect(6, 5, 5, 1, SB_WHITE),
		rect(10, 6, 1, 4, SB_WHITE),
		rect(5, 10, 5, 1, SB_WHITE),
		rect(5, 6, 1, 4, SB_WHITE),
		rect(5, 5, 1, 1, SB_LIGHT, true),
		rect(10, 10, 1, 1, SB_LIGHT, true),
	},
	Data = fourWays({
		rect(3, 4, 4, 2, SB_BRIGHT),
		rect(4, 3, 2, 4, SB_BRIGHT, true),
		rect(4, 4, 2, 2, SB_WHITE, true),
	}),
}

local DECORS: { [string]: Faces } = {
	Chest = CHEST,
	CraftingTable = CRAFTING_TABLE,
	Furnace = FURNACE,
	CreativeEnergyCube = CREATIVE_ENERGY_CUBE,
	HeatGenerator = HEAT_GENERATOR,
	ElectricFurnace = ELECTRIC_FURNACE,
}
for _, tier in Tiers.TIERS do
	DECORS[`{tier.name}Battery`] = batteryFaces(tier.colour)
end
for mode, sigil in SIGILS do
	local face = join(structureFrame(), sigil)
	DECORS[`StructureBlock{mode}`] = { Top = face, Bottom = face, Front = face, Back = face, Left = face, Right = face }
end

-- The faces of `decor` (BlockList `decor`), or nil when it is unknown.
function BlockDecor.faces(decor: string): Faces?
	return DECORS[decor]
end

--[[
	A face's outward normal and its picture's right and up directions (unit axes of the block), seen
	from outside (right x up = normal). Side faces are upright, as SurfaceGuis draw them. Which way
	is up on the top and bottom only matters for plank lines that only world blocks draw (chest top,
	crafting table bottom): every top and bottom picture of an item model looks the same turned by a
	quarter, so it matches the world block whichever way SurfaceGuis turn those faces.
]]
local BASIS: { [string]: { { number } } } = {
	Front = { { 0, 0, -1 }, { -1, 0, 0 }, { 0, 1, 0 } },
	Back = { { 0, 0, 1 }, { 1, 0, 0 }, { 0, 1, 0 } },
	Left = { { -1, 0, 0 }, { 0, 0, 1 }, { 0, 1, 0 } },
	Right = { { 1, 0, 0 }, { 0, 0, -1 }, { 0, 1, 0 } },
	Top = { { 0, 1, 0 }, { -1, 0, 0 }, { 0, 0, 1 } },
	Bottom = { { 0, -1, 0 }, { 1, 0, 0 }, { 0, 0, 1 } },
}

function BlockDecor.basis(face: string): ({ number }, { number }, { number })
	local b = BASIS[face]
	return b[1], b[2], b[3]
end

--[[
	Jigsaw blocks (Minecraft 1.20.1's jigsaw model): drawn pointing up, then turned on each face.
	  front  the puzzle piece (jigsaw_top), its knob towards the block's top;
	  back   plain (jigsaw_bottom);
	  top    the face towards the block's top: the lock (jigsaw_lock), a bar from the edge next
	         to the front into the middle;
	  sides  the other three: an arrow pointing at the front (jigsaw_side).
	Item models show the front's piece, the lock's bar and the sides' arrows.
]]
local JIGSAW_FRONT: { Rect } = {
	rect(1, 1, 14, 14, SB_FIELD),
	rect(4, 1, 6, 1, SB_DARK, true),
	rect(14, 6, 1, 6, SB_DARK, true),
	rect(1, 8, 1, 5, SB_DARK, true),
	rect(3, 14, 5, 1, SB_DARK, true),
	rect(3, 5, 8, 8, SB_WHITE),
	rect(6, 3, 2, 2, SB_WHITE),
	rect(11, 8, 2, 2, SB_WHITE),
	rect(3, 8, 2, 2, SB_FIELD),
	rect(6, 11, 2, 2, SB_FIELD),
}
local JIGSAW_BACK: { Rect } = {
	rect(1, 1, 14, 1, SB_FIELD, true),
	rect(1, 14, 14, 1, SB_FIELD, true),
	rect(1, 2, 1, 12, SB_FIELD, true),
	rect(14, 2, 1, 12, SB_FIELD, true),
}
local JIGSAW_LOCK: { Rect } = join(JIGSAW_BACK, {
	rect(6, 1, 4, 8, SB_FIELD),
	rect(7, 0, 2, 8, SB_WHITE),
})
local JIGSAW_SIDE: { Rect } = {
	rect(1, 1, 14, 14, SB_FIELD),
	rect(7, 0, 2, 1, SB_MID, true),
	rect(2, 10, 2, 3, SB_DARK, true),
	rect(12, 10, 2, 3, SB_DARK, true),
	rect(7, 2, 2, 12, SB_LIGHT),
	rect(6, 3, 4, 1, SB_LIGHT, true),
	rect(5, 4, 6, 1, SB_LIGHT),
	rect(4, 5, 8, 1, SB_LIGHT),
	rect(3, 6, 10, 1, SB_LIGHT),
	rect(7, 3, 2, 10, SB_WHITE, true),
	rect(6, 4, 4, 1, SB_WHITE, true),
	rect(5, 5, 6, 1, SB_WHITE, true),
}

-- The four pictures as drawn pointing up (read only; for tests).
BlockDecor.JIGSAW_PICTURES =
	table.freeze({ front = JIGSAW_FRONT, back = JIGSAW_BACK, lock = JIGSAW_LOCK, side = JIGSAW_SIDE })

-- Unit offsets of the faces and of Minecraft's directions (North = -Z).
local FACE_VECTOR: { [string]: { number } } = {
	Front = { 0, 0, -1 },
	Back = { 0, 0, 1 },
	Left = { -1, 0, 0 },
	Right = { 1, 0, 0 },
	Top = { 0, 1, 0 },
	Bottom = { 0, -1, 0 },
}
local DIRECTION_VECTOR: { [string]: { number } } = {
	North = { 0, 0, -1 },
	South = { 0, 0, 1 },
	West = { -1, 0, 0 },
	East = { 1, 0, 0 },
	Up = { 0, 1, 0 },
	Down = { 0, -1, 0 },
}

local function dot(a: { number }, b: { number }): number
	return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
end

-- `rects` turned `turns` quarter turns clockwise (as seen) on the face.
local function turned(rects: { Rect }, turns: number): { Rect }
	local out = table.create(#rects)
	for i, r in rects do
		local x, y, w, h = r.x, r.y, r.w, r.h
		for _ = 1, turns % 4 do
			x, y, w, h = 16 - y - h, x, h, w
		end
		out[i] = rect(x, y, w, h, r.colour, r.surfaceOnly)
	end
	return out
end

-- Quarter turns clockwise taking a picture's up (towards y = 0) to world direction `towards`,
-- which lies in `face`.
local function turnsTowards(face: string, towards: { number }): number
	local _, right, up = BlockDecor.basis(face)
	local across, down = dot(towards, right), -dot(towards, up)
	if down < 0 then
		return 0
	elseif across > 0 then
		return 1
	elseif down > 0 then
		return 2
	end
	return 3
end

-- The faces of the jigsaw facing `front` with `top` up.
local function jigsawFaces(front: string, top: string): Faces
	local f, t = DIRECTION_VECTOR[front], DIRECTION_VECTOR[top]
	local faces: Faces = {}
	for _, face in BlockDecor.FACES do
		local normal = FACE_VECTOR[face]
		local along = dot(normal, f)
		if along > 0 then
			faces[face] = turned(JIGSAW_FRONT, turnsTowards(face, t))
		elseif along < 0 then
			faces[face] = JIGSAW_BACK
		elseif dot(normal, t) > 0 then
			faces[face] = turned(JIGSAW_LOCK, turnsTowards(face, f))
		else
			faces[face] = turned(JIGSAW_SIDE, turnsTowards(face, f))
		end
	end
	return faces
end

-- Minecraft's twelve FrontAndTop orientations (as BlockList's jigsaws).
for _, front in { "North", "South", "West", "East" } do
	DECORS[`Jigsaw{front}Up`] = jigsawFaces(front, "Up")
end
for _, front in { "Up", "Down" } do
	for _, top in { "North", "South", "West", "East" } do
		DECORS[`Jigsaw{front}{top}`] = jigsawFaces(front, top)
	end
end

local function overlaps(a: Rect, b: Rect): boolean
	return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end

--[[
	The stacking layer of each rectangle drawn (1 = right on the block, 0 = not drawn): one above the
	highest earlier rectangle it overlaps, so item model slabs that cover each other never share a
	plane. `items` = for item models (leaves out `surfaceOnly`).
]]
function BlockDecor.layers(rects: { Rect }, items: boolean): { number }
	local layers = table.create(#rects, 0)
	for i, r in rects do
		if not (items and r.surfaceOnly) then
			local layer = 1
			for j = 1, i - 1 do
				if layers[j] > 0 and overlaps(rects[j], r) then
					layer = math.max(layer, layers[j] + 1)
				end
			end
			layers[i] = layer
		end
	end
	return layers
end

-- How many slabs `buildParts` makes for `decor`.
function BlockDecor.partCount(decor: string): number
	local faces = DECORS[decor]
	local count = 0
	if faces then
		for _, rects in faces do
			for _, r in rects do
				if not r.surfaceOnly then
					count += 1
				end
			end
		end
	end
	return count
end

--[[ Instances ]]

local function colour3(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function vector(v: { number }): Vector3
	return Vector3.new(v[1], v[2], v[3])
end

-- Adds a SurfaceGui per face of `decor` to `part` (world blocks; clones keep them).
function BlockDecor.applySurfaces(part: BasePart, decor: string)
	local faces = DECORS[decor]
	if faces == nil then
		return
	end
	local grid = BlockDecor.GRID
	for _, face in BlockDecor.FACES do
		local rects = faces[face]
		if rects and #rects > 0 then
			local gui = Instance.new("SurfaceGui")
			gui.Name = `Decor{face}`
			gui.Face = (Enum.NormalId :: any)[face]
			-- Shaded by the world's light like the part under it, and hidden behind other things.
			gui.LightInfluence = 1
			gui.AlwaysOnTop = false
			gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
			gui.CanvasSize = Vector2.new(CANVAS, CANVAS)
			gui.ZOffset = 0
			gui.MaxDistance = MAX_DISTANCE
			gui.ClipsDescendants = true
			gui.Active = false
			for i, r in rects do
				local frame = Instance.new("Frame")
				frame.Name = tostring(i)
				frame.BorderSizePixel = 0
				frame.BackgroundColor3 = colour3(r.colour)
				frame.Position = UDim2.fromScale(r.x / grid, r.y / grid)
				frame.Size = UDim2.fromScale(r.w / grid, r.h / grid)
				-- Painted in list order.
				frame.ZIndex = i
				frame.Parent = gui
			end
			gui.Parent = part
		end
	end
end

--[[
	Thin raised slabs drawing `decor` on a cube of `size` studs placed at `base.CFrame` (item models:
	ViewportFrames do not draw SurfaceGuis). The parts are anchored and inert, and not parented.
]]
function BlockDecor.buildParts(decor: string, size: number, base: BasePart): { BasePart }
	local faces = DECORS[decor]
	local parts: { BasePart } = {}
	if faces == nil then
		return parts
	end
	local grid = BlockDecor.GRID
	local pixel = size / grid
	local thickness = size * SLAB
	local origin = base.CFrame
	for _, face in BlockDecor.FACES do
		local rects = faces[face]
		if rects then
			local n, r, u = BlockDecor.basis(face)
			local normal, right, up = vector(n), vector(r), vector(u)
			local layers = BlockDecor.layers(rects, true)
			for i, data in rects do
				local layer = layers[i]
				if layer > 0 then
					local across = (data.x + data.w / 2) * pixel - size / 2
					local down = (data.y + data.h / 2) * pixel - size / 2
					local out = size / 2 + (layer - 0.5) * thickness
					local centre = normal * out + right * across - up * down
					local part = Instance.new("Part")
					part.Name = `Decor{face}{i}`
					part.Anchored = true
					part.CanCollide = false
					part.CanQuery = false
					part.CanTouch = false
					part.CastShadow = false
					part.Locked = true
					part.TopSurface = Enum.SurfaceType.Smooth
					part.BottomSurface = Enum.SurfaceType.Smooth
					part.Material = Enum.Material.SmoothPlastic
					part.Color = colour3(data.colour)
					part.Size = Vector3.new(data.w * pixel, data.h * pixel, thickness)
					part.CFrame = origin * CFrame.fromMatrix(centre, right, up, normal)
					table.insert(parts, part)
				end
			end
		end
	end
	return parts
end

return BlockDecor
