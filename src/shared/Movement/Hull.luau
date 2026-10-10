--!strict
--[[
	Axis-aligned box ("hull") collision against the block grid, the way Minecraft Java Edition moves
	entities (Entity.collide / collideWithShapes / Shapes.collide, Player.maybeBackOffFromEdge).

	Units are blocks: block (x, y, z) fills [x, x + 1] on every axis. `solidAt(x, y, z)` tells
	whether a block blocks movement: true for a full cube, false (or nil) for none, or the boxes it
	collides with (Shape: in the cell's own units, 0..1 on every axis, Minecraft's collision
	VoxelShape: a door's 3 pixel panel), whose boxes may reach up to TALL above the cell (a
	fence's 1.5 blocks: Minecraft's tall collision shapes; never below it or out sideways). Callers
	treat unloaded blocks as solid so nothing falls out of the loaded world. A Shape is truthy, so a
	caller asking only "anything there?" sees one as a block.

	A move is resolved one axis at a time: Y first, then the larger of the horizontal components,
	then the other. Along an axis the box moves until it touches the first solid block or box whose
	cross section it overlaps (by more than EPSILON); those it already overlaps are ignored, so a box
	stuck inside a block can still get out. Pure Luau, no Roblox APIs.
]]

local EPSILON = 1.0e-7

export type Box = {
	minX: number,
	minY: number,
	minZ: number,
	maxX: number,
	maxY: number,
	maxZ: number,
}

-- A block's collision boxes in its own cell (0..1 on every axis; Hull's header).
export type Shape = { Box }

export type SolidAt = (x: number, y: number, z: number) -> boolean | Shape

local floor = math.floor
local ceil = math.ceil
local abs = math.abs

local Hull = {}

-- How far above its cell a shape's boxes may reach (blocks): a fence's 24 pixels.
local TALL = 0.5
Hull.TALL = TALL

--[[
	The row under the box whose tall shapes may reach into it (its bottom is within TALL of that
	row's top), else nil: only shapes count there, not full cells (they end below the box).
]]
local function tallRow(box: Box): number?
	local row = floor(box.minY + EPSILON) - 1
	return if box.minY < row + 1 + TALL - EPSILON then row else nil
end

Hull.EPSILON = EPSILON

-- Box of an entity standing with its feet centred at (x, y, z).
function Hull.box(x: number, y: number, z: number, width: number, height: number): Box
	local half = width / 2
	return { minX = x - half, minY = y, minZ = z - half, maxX = x + half, maxY = y + height, maxZ = z + half }
end

function Hull.offset(box: Box, dx: number, dy: number, dz: number): Box
	return {
		minX = box.minX + dx,
		minY = box.minY + dy,
		minZ = box.minZ + dz,
		maxX = box.maxX + dx,
		maxY = box.maxY + dy,
		maxZ = box.maxZ + dz,
	}
end

-- The box grown towards a movement (AABB.expandTowards).
function Hull.expandTowards(box: Box, dx: number, dy: number, dz: number): Box
	return {
		minX = if dx < 0 then box.minX + dx else box.minX,
		minY = if dy < 0 then box.minY + dy else box.minY,
		minZ = if dz < 0 then box.minZ + dz else box.minZ,
		maxX = if dx > 0 then box.maxX + dx else box.maxX,
		maxY = if dy > 0 then box.maxY + dy else box.maxY,
		maxZ = if dz > 0 then box.maxZ + dz else box.maxZ,
	}
end

-- Does a box of `shape` in cell (x, y, z) overlap `box` (touching faces do not count)?
local function shapeOverlaps(shape: Shape, x: number, y: number, z: number, box: Box): boolean
	for _, part in shape do
		if
			x + part.minX < box.maxX - EPSILON
			and x + part.maxX > box.minX + EPSILON
			and y + part.minY < box.maxY - EPSILON
			and y + part.maxY > box.minY + EPSILON
			and z + part.minZ < box.maxZ - EPSILON
			and z + part.maxZ > box.minZ + EPSILON
		then
			return true
		end
	end
	return false
end

-- Does any solid block (or box of a shaped one) overlap the box (touching faces do not count)?
function Hull.noCollision(solidAt: SolidAt, box: Box): boolean
	local below = tallRow(box)
	for x = floor(box.minX + EPSILON), floor(box.maxX - EPSILON) do
		for y = below or floor(box.minY + EPSILON), floor(box.maxY - EPSILON) do
			for z = floor(box.minZ + EPSILON), floor(box.maxZ - EPSILON) do
				local solid = solidAt(x, y, z)
				if
					(solid == true and y ~= below)
					or (type(solid) == "table" and shapeOverlaps(solid, x, y, z, box))
				then
					return false
				end
			end
		end
	end
	return true
end

--[[
	The nearest face of an obstacle in the cross section at layer `k` along `axis` (1 = X, 2 = Y,
	3 = Z; `a0..a1`, `b0..b1` the cells of the other two axes, inclusive) that the box moving along
	the axis (`positive` or not) would hit, nil when none: for a positive move the lowest start of
	a full block or shape box starting at or beyond `face` (the box's leading side), else the
	highest end of one ending at or before it. Those starting behind the face are overlapped
	already and ignored. A shape box must overlap the box's cross section itself.
]]
local function layerHit(
	solidAt: SolidAt,
	axis: number,
	k: number,
	a0: number,
	a1: number,
	b0: number,
	b1: number,
	box: Box,
	positive: boolean,
	face: number,
	below: number?
): number?
	local hit: number? = nil
	for a = a0, a1 do
		for b = b0, b1 do
			local x, y, z
			if axis == 1 then
				x, y, z = k, a, b -- a = y, b = z
			elseif axis == 2 then
				x, y, z = a, k, b -- a = x, b = z
			else
				x, y, z = a, b, k -- a = x, b = y
			end
			local solid = solidAt(x, y, z)
			if solid == true and y ~= below then
				local at = if positive then k else k + 1
				if if positive then at >= face - EPSILON else at <= face + EPSILON then
					if hit == nil or (if positive then at < hit else at > hit) then
						hit = at
					end
				end
			elseif type(solid) == "table" then
				for _, part in solid do
					local lo, hi, across
					if axis == 1 then
						lo, hi = x + part.minX, x + part.maxX
						across = y + part.minY < box.maxY - EPSILON
							and y + part.maxY > box.minY + EPSILON
							and z + part.minZ < box.maxZ - EPSILON
							and z + part.maxZ > box.minZ + EPSILON
					elseif axis == 2 then
						lo, hi = y + part.minY, y + part.maxY
						across = x + part.minX < box.maxX - EPSILON
							and x + part.maxX > box.minX + EPSILON
							and z + part.minZ < box.maxZ - EPSILON
							and z + part.maxZ > box.minZ + EPSILON
					else
						lo, hi = z + part.minZ, z + part.maxZ
						across = x + part.minX < box.maxX - EPSILON
							and x + part.maxX > box.minX + EPSILON
							and y + part.minY < box.maxY - EPSILON
							and y + part.maxY > box.minY + EPSILON
					end
					if across then
						local at = if positive then lo else hi
						if if positive then at >= face - EPSILON else at <= face + EPSILON then
							if hit == nil or (if positive then at < hit else at > hit) then
								hit = at
							end
						end
					end
				end
			end
		end
	end
	return hit
end

--[[
	How far the box can move along `axis` (1 = X, 2 = Y, 3 = Z), up to `delta` (Shapes.collide):
	`delta` shortened to the first solid block (or shape box) in the way. The scan starts at the
	layer the box's leading side is in (a shape box there may still be ahead of it) and stops at
	the first layer with a hit: anything in a later layer starts further on, but for the tops of
	tall shapes (TALL) one layer further down, which a downward move looks at too. Sideways, the
	row under the box counts for its tall shapes (`tallRow`).
]]
function Hull.collideAxis(solidAt: SolidAt, axis: number, box: Box, delta: number): number
	if delta == 0 then
		return 0
	end
	local min, max, a0, a1, b0, b1
	local below: number? = nil
	if axis == 1 then
		min, max = box.minX, box.maxX
		below = tallRow(box)
		a0, a1 = below or floor(box.minY + EPSILON), floor(box.maxY - EPSILON)
		b0, b1 = floor(box.minZ + EPSILON), floor(box.maxZ - EPSILON)
	elseif axis == 2 then
		min, max = box.minY, box.maxY
		a0, a1 = floor(box.minX + EPSILON), floor(box.maxX - EPSILON)
		b0, b1 = floor(box.minZ + EPSILON), floor(box.maxZ - EPSILON)
	else
		min, max = box.minZ, box.maxZ
		below = tallRow(box)
		a0, a1 = floor(box.minX + EPSILON), floor(box.maxX - EPSILON)
		b0, b1 = below or floor(box.minY + EPSILON), floor(box.maxY - EPSILON)
	end
	if delta > 0 then
		local k = floor(max - EPSILON)
		while k < max + delta do
			local hit = layerHit(solidAt, axis, k, a0, a1, b0, b1, box, true, max, below)
			if hit then
				delta = math.min(delta, hit - max)
				break
			end
			k += 1
		end
	else
		local tall = if axis == 2 then TALL else 0
		local k = ceil(min + EPSILON) - 1
		while k + 1 + tall > min + delta do
			local hit = layerHit(solidAt, axis, k, a0, a1, b0, b1, box, false, min, below)
			if hit then
				if axis == 2 then
					-- (A tall shape's top in the layer under may be higher.)
					local under = layerHit(solidAt, axis, k - 1, a0, a1, b0, b1, box, false, min, nil)
					if under and under > hit then
						hit = under
					end
				end
				delta = math.max(delta, hit - min)
				break
			end
			k -= 1
		end
	end
	return if abs(delta) < EPSILON then 0 else delta
end

--[[
	A movement resolved against the blocks one axis at a time (Entity.collideWithShapes): Y first,
	then the larger horizontal component, then the other.
]]
function Hull.collideBox(solidAt: SolidAt, box: Box, dx: number, dy: number, dz: number): (number, number, number)
	if dy ~= 0 then
		dy = Hull.collideAxis(solidAt, 2, box, dy)
		if dy ~= 0 then
			box = Hull.offset(box, 0, dy, 0)
		end
	end
	local zFirst = abs(dx) < abs(dz)
	if zFirst and dz ~= 0 then
		dz = Hull.collideAxis(solidAt, 3, box, dz)
		if dz ~= 0 then
			box = Hull.offset(box, 0, 0, dz)
		end
	end
	if dx ~= 0 then
		dx = Hull.collideAxis(solidAt, 1, box, dx)
		if not zFirst and dx ~= 0 then
			box = Hull.offset(box, dx, 0, 0)
		end
	end
	if not zFirst and dz ~= 0 then
		dz = Hull.collideAxis(solidAt, 3, box, dz)
	end
	return dx, dy, dz
end

--[[
	The movement an entity actually makes (Entity.collide): collideBox, and if that stopped it
	horizontally while it is on the ground (or just landed), also try stepping up to `stepHeight`
	over the obstacle; the step wins when it gets further horizontally, and then steps back down.
	The fourth result tells whether the step was taken.
]]
function Hull.collide(
	solidAt: SolidAt,
	box: Box,
	dx: number,
	dy: number,
	dz: number,
	stepHeight: number,
	onGround: boolean
): (number, number, number, boolean)
	if dx == 0 and dy == 0 and dz == 0 then
		return 0, 0, 0, false
	end
	local rx, ry, rz = Hull.collideBox(solidAt, box, dx, dy, dz)
	local hitX, hitY, hitZ = rx ~= dx, ry ~= dy, rz ~= dz
	if stepHeight > 0 and (onGround or (hitY and dy < 0)) and (hitX or hitZ) then
		-- Straight up the step and along...
		local ax, ay, az = Hull.collideBox(solidAt, box, dx, stepHeight, dz)
		-- ...or first up as far as the swept area allows, then along.
		local _, uy, _ = Hull.collideBox(solidAt, Hull.expandTowards(box, dx, 0, dz), 0, stepHeight, 0)
		if uy < stepHeight then
			local bx, by, bz = Hull.collideBox(solidAt, Hull.offset(box, 0, uy, 0), dx, 0, dz)
			by += uy
			if bx * bx + bz * bz > ax * ax + az * az then
				ax, ay, az = bx, by, bz
			end
		end
		if ax * ax + az * az > rx * rx + rz * rz then
			local _, down, _ = Hull.collideBox(solidAt, Hull.offset(box, ax, ay, az), 0, -ay + dy, 0)
			return ax, ay + down, az, true
		end
	end
	return rx, ry, rz, false
end

--[[
	Sneaking at an edge (Player.maybeBackOffFromEdge): shorten the horizontal movement in steps of
	0.05 until the box, moved and lowered by `stepHeight`, still stands on something. The caller
	checks when this applies (sneaking, not moving up, on or just above the ground).
]]
function Hull.backOffFromEdge(solidAt: SolidAt, box: Box, dx: number, dz: number, stepHeight: number): (number, number)
	local function shorten(d: number): number
		if d < 0.05 and d >= -0.05 then
			return 0
		elseif d > 0 then
			return d - 0.05
		end
		return d + 0.05
	end
	while dx ~= 0 and Hull.noCollision(solidAt, Hull.offset(box, dx, -stepHeight, 0)) do
		dx = shorten(dx)
	end
	while dz ~= 0 and Hull.noCollision(solidAt, Hull.offset(box, 0, -stepHeight, dz)) do
		dz = shorten(dz)
	end
	while dx ~= 0 and dz ~= 0 and Hull.noCollision(solidAt, Hull.offset(box, dx, -stepHeight, dz)) do
		dx = shorten(dx)
		dz = shorten(dz)
	end
	return dx, dz
end

return Hull
