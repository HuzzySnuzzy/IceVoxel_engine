--!strict
--!native
--[[
	Rotation and mirror maths for structure templates (Minecraft's StructureTemplate.transform).

	A template is a box of `sx × sy × sz` cells with local coordinates from 0. Turning it gives
	another box, again with its minimum corner at 0:
	  1. the mirror first: "leftRight" flips Z (north ↔ south), "frontBack" flips X (east ↔ west);
	  2. then `rotation` quarter turns clockwise seen from above (North → East → South → West):
	     one turn maps (x, z) to (sz - 1 - z, x), so the turned box is sz wide and sx deep.
	Y never changes. Directions turn the same way (Up and Down stay).

	Minecraft turns around a pivot (the piece's position, 0 here) instead, so its turned box can
	reach to negative x or z; `anchor` gives the offset between the two, for code that must place
	a template exactly where Minecraft's structure block LOAD would.

	Everything here is pure and allocation free except `box`.
]]

export type Mirror = "none" | "leftRight" | "frontBack"

local Transform = {}

-- The three mirrors and the four rotations, in the order the structure block cycles them.
Transform.MIRRORS = table.freeze({ "none", "leftRight", "frontBack" } :: { Mirror })
Transform.ROTATIONS = table.freeze({ 0, 1, 2, 3 })

-- Minecraft's Direction ordinals: 0 Down, 1 Up, 2 North, 3 South, 4 West, 5 East.
Transform.DIRECTIONS = table.freeze({ "Down", "Up", "North", "South", "West", "East" })

-- Unit offset of each direction (North = -Z, East = +X, as Blocks.DIRECTIONS).
Transform.OFFSETS = table.freeze({
	Down = table.freeze({ 0, -1, 0 }),
	Up = table.freeze({ 0, 1, 0 }),
	North = table.freeze({ 0, 0, -1 }),
	South = table.freeze({ 0, 0, 1 }),
	West = table.freeze({ -1, 0, 0 }),
	East = table.freeze({ 1, 0, 0 }),
})

Transform.OPPOSITE = table.freeze({
	Down = "Up",
	Up = "Down",
	North = "South",
	South = "North",
	West = "East",
	East = "West",
})

-- One clockwise quarter turn seen from above.
local CLOCKWISE: { [string]: string } =
	{ North = "East", East = "South", South = "West", West = "North", Up = "Up", Down = "Down" }
local MIRROR_Z: { [string]: string } = { North = "South", South = "North" }
local MIRROR_X: { [string]: string } = { East = "West", West = "East" }

-- Rotation folded into 0..3 (any integer, negative ones too).
function Transform.normalize(rotation: number): number
	return rotation % 4
end

-- Whether `mirror` is one of the three mirrors (nil counts as "none").
function Transform.isMirror(mirror: any): boolean
	return mirror == nil or mirror == "none" or mirror == "leftRight" or mirror == "frontBack"
end

-- Size of the turned box (a mirror never changes it).
function Transform.size(sx: number, sy: number, sz: number, rotation: number): (number, number, number)
	if rotation % 2 == 1 then
		return sz, sy, sx
	end
	return sx, sy, sz
end

-- Local position (x, y, z) in a template of `sx × ? × sz` → its position in the turned box.
function Transform.position(
	x: number,
	y: number,
	z: number,
	sx: number,
	sz: number,
	rotation: number,
	mirror: Mirror?
): (number, number, number)
	if mirror == "leftRight" then
		z = sz - 1 - z
	elseif mirror == "frontBack" then
		x = sx - 1 - x
	end
	local r = rotation % 4
	if r == 0 then
		return x, y, z
	elseif r == 1 then
		return sz - 1 - z, y, x
	elseif r == 2 then
		return sx - 1 - x, y, sz - 1 - z
	end
	return z, y, sx - 1 - x
end

-- The inverse: position (x, y, z) in the turned box → local position in the template. `sx` and
-- `sz` are the template's own (unturned) size.
function Transform.inverse(
	x: number,
	y: number,
	z: number,
	sx: number,
	sz: number,
	rotation: number,
	mirror: Mirror?
): (number, number, number)
	local r = rotation % 4
	local lx, lz
	if r == 0 then
		lx, lz = x, z
	elseif r == 1 then
		lx, lz = z, sz - 1 - x
	elseif r == 2 then
		lx, lz = sx - 1 - x, sz - 1 - z
	else
		lx, lz = sx - 1 - z, x
	end
	if mirror == "leftRight" then
		lz = sz - 1 - lz
	elseif mirror == "frontBack" then
		lx = sx - 1 - lx
	end
	return lx, y, lz
end

-- A direction ("North", "Up"...) after the mirror and the rotation. Unknown names come back as
-- they are.
function Transform.direction(direction: string, rotation: number, mirror: Mirror?): string
	local d = direction
	if mirror == "leftRight" then
		d = MIRROR_Z[d] or d
	elseif mirror == "frontBack" then
		d = MIRROR_X[d] or d
	end
	if CLOCKWISE[d] == nil then
		return d
	end
	for _ = 1, rotation % 4 do
		d = CLOCKWISE[d]
	end
	return d
end

-- World box { minX, minY, minZ, maxX, maxY, maxZ } (inclusive) of a template of `sx × sy × sz`
-- turned by `rotation` whose turned box has its minimum corner at (x, y, z).
function Transform.box(
	x: number,
	y: number,
	z: number,
	sx: number,
	sy: number,
	sz: number,
	rotation: number
): { number }
	local tx, ty, tz = Transform.size(sx, sy, sz, rotation)
	return { x, y, z, x + tx - 1, y + ty - 1, z + tz - 1 }
end

--[[
	Offset (dx, dz) from Minecraft's anchor to the turned box's minimum corner. Minecraft turns a
	template around the position it is placed at (StructureTemplate.transform with pivot 0), so a
	template loaded by a structure block with a rotation extends to the west or north of the
	block's offset position; place the turned box at `anchor + (dx, 0, dz)` to match it.
]]
local function minecraftTransform(x: number, z: number, rotation: number, mirror: Mirror?): (number, number)
	if mirror == "leftRight" then
		z = -z
	elseif mirror == "frontBack" then
		x = -x
	end
	local r = rotation % 4
	if r == 1 then
		return -z, x
	elseif r == 2 then
		return -x, -z
	elseif r == 3 then
		return z, -x
	end
	return x, z
end

function Transform.anchor(sx: number, sz: number, rotation: number, mirror: Mirror?): (number, number)
	-- Minecraft's transform (pivot 0) of two opposite corners; the box's minimum is theirs.
	local ax, az = minecraftTransform(0, 0, rotation, mirror)
	local bx, bz = minecraftTransform(sx - 1, sz - 1, rotation, mirror)
	return math.min(ax, bx), math.min(az, bz)
end

return Transform
