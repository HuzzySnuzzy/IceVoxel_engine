--!strict
--[[
	The Minecraft pack's own block shapes (its blocks/ modules use them; Content/Define has the
	ones other packs share): glow lichen's plate on each face and its outline, and the plants'
	special boxes, the tuft of grass blades, the tall grass and large fern halves, the sunflower's
	head, the bushes of the lilac, rose bush and peony, and a rose.
]]

local Define = require(script.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Schema)

type ShapeBox = Schema.ShapeBox
type Bounds = Schema.Bounds

local along, blade, slat, plantBox = Define.along, Define.blade, Define.slat, Define.plantBox
local GROUND = Define.GROUND

local Shapes = {}

--[[ Glow lichen ]]

local LICHEN = { 106, 128, 118 }
local LICHEN_GLOW = { 210, 220, 158 }

-- The floor model: { size, offset } of each box with the face at y = -8 (support Down), as
-- { across, height above the face, along }.
local LICHEN_BOXES: { { size: { number }, at: { number }, colour: { number }, glow: boolean? } } = {
	{ size = { 13, 0.3, 13 }, at = { -0.5, 0.25, 0.5 }, colour = LICHEN },
	{ size = { 3, 0.6, 3 }, at = { -2.5, 0.4, -2 }, colour = LICHEN_GLOW, glow = true },
}

-- The lichen's boxes on the face towards `support`: the floor model turned onto that face.
function Shapes.lichenShape(support: string): { ShapeBox }
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
function Shapes.lichenBounds(support: string): Bounds
	local lo, hi = { 0, 0, 0 }, { 16, 16, 16 }
	local d = if support == "Down"
		then { 0, -1, 0 }
		elseif support == "Up" then { 0, 1, 0 }
		else table.clone(Define.DIRECTIONS[support])
	for k = 1, 3 do
		if d[k] < 0 then
			hi[k] = 1
		elseif d[k] > 0 then
			lo[k] = 15
		end
	end
	return { min = lo, max = hi }
end

--[[ Grass and ferns ]]

-- The point on the ground `distance` pixels from the middle, away from `facing`: blades whose foot
-- is a pixel behind the middle cross at the root, like a tuft.
function Shapes.behind(facing: number, distance: number): { number }
	return along({ 0, GROUND, 0 }, 90, facing + 180, distance)
end
local behind = Shapes.behind

-- The length of a blade `width` wide from `foot` whose highest corner is at `top` (a tall plant's
-- lower half reaching the top of its cell, where the upper half carries on).
local function reaching(foot: { number }, top: number, lean: number, width: number): number
	local t = math.rad(lean)
	return (top - foot[2] - width / 2 * math.sin(t)) / math.cos(t)
end

--[[
	A tall plant's blades fan out from the middle like a vase: the lower half's from the ground to
	the top of the cell, and the upper half's carry on from where they end (the same place one cell
	up: both halves are drawn at the lower half's offset), leaning further out.
]]
export type TallBlade = {
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
function Shapes.tallBlades(blades: { TallBlade }): ({ ShapeBox }, { ShapeBox })
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

--[[ Tall flowers ]]

local SUN_PETALS = { 252, 200, 32 }
local SUN_MIDDLE = { 96, 60, 28 }
local SUN_TILT = 22.5

-- The sunflower's head: a disc (two crossed rectangles, a pixel-art circle) and its middle, centred
-- at `centre`, facing east (+X) or towards -Z (the item), tilted up.
function Shapes.sunflowerHead(centre: { number }, east: boolean): { ShapeBox }
	local x, y, z = centre[1], centre[2], centre[3]
	local t = math.rad(SUN_TILT)
	if east then
		local rotation = { 0, 0, SUN_TILT }
		return {
			plantBox({ 0.8, 9, 6.4 }, centre, SUN_PETALS, rotation),
			plantBox({ 0.8, 6.4, 9 }, centre, SUN_PETALS, rotation),
			plantBox({ 0.8, 3.6, 3.6 }, { x + 0.6 * math.cos(t), y + 0.6 * math.sin(t), z }, SUN_MIDDLE, rotation),
		}
	end
	local rotation = { SUN_TILT, 0, 0 }
	return {
		plantBox({ 6.4, 9, 0.8 }, centre, SUN_PETALS, rotation),
		plantBox({ 9, 6.4, 0.8 }, centre, SUN_PETALS, rotation),
		plantBox({ 3.6, 3.6, 0.8 }, { x, y + 0.6 * math.sin(t), z - 0.6 * math.cos(t) }, SUN_MIDDLE, rotation),
	}
end

-- Bushes: leafy masses of a few sizes, side by side and a little tilted, so their outline is
-- uneven; the upper half's lowest mass reaches down to the lower half's.
function Shapes.bushLower(leaves: { number }, light: { number }): { ShapeBox }
	return {
		plantBox({ 6, 9, 6 }, { -1, -3.5, 0.6 }, leaves, { 0, 25, 8 }),
		plantBox({ 5.4, 8, 5.4 }, { 1.3, 3.2, -0.8 }, light, { -8, 65, 0 }),
	}
end

function Shapes.bushUpper(leaves: { number }): ShapeBox
	return plantBox({ 6, 7.4, 6 }, { -0.5, -4.4, 0.4 }, leaves, { 8, 35, 0 })
end

-- A rose of the rose bush at `offset`.
local ROSE = { 206, 28, 34 }
function Shapes.rose(offset: { number }): ShapeBox
	return plantBox({ 1.6, 1.6, 1.6 }, offset, ROSE, { 0, 20, 0 })
end

return Shapes
