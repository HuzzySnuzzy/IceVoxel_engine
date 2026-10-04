--!strict
--[[
	Decorated block faces: chests, crafting tables and furnaces drawn like Minecraft's pixel art.

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
	corner. Side faces are upright (+Y up). Faces are named like Enum.NormalId: Front is -Z, Back +Z,
	Left -X, Right +X. `faces`, `basis` and `layers` are pure data, so tests can check them.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)

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

local DECORS: { [string]: Faces } = {
	Chest = CHEST,
	CraftingTable = CRAFTING_TABLE,
	Furnace = FURNACE,
}

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
