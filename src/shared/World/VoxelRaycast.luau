--!strict
--[[
	Voxel raycast (Amanatides & Woo grid traversal).

	Works on block data directly, so it gives exact block / face results on the client and lets the
	server raycast without any parts existing there.

	Positions and distances are in *block units* (studs / Config.BlockSize).

	Blocks smaller than their cell (torches, lanterns) can pass an `outline` (Blocks.outline): the
	ray must hit that box inside the cell, else it goes on past it (to the wall behind a torch), and
	the face reported is the outline's. An outline may be several boxes (six numbers each, one
	after the other: a pipe's core and arms, Blocks/Shapes); the nearest one hit counts.
]]

local VoxelRaycast = {}

export type Hit = {
	x: number,
	y: number,
	z: number,
	-- Normal of the face that was hit; (x + nx, y + ny, z + nz) is where a placed block goes.
	nx: number,
	ny: number,
	nz: number,
	block: number,
	distance: number,
}

-- Where the ray (o + t d) crosses one axis' slab lo..hi: entry and exit distances (nil: parallel to
-- the slab and outside it).
local function slab(o: number, d: number, lo: number, hi: number): (number?, number)
	if math.abs(d) < 1e-12 then
		if o < lo or o > hi then
			return nil, 0
		end
		return -math.huge, math.huge
	end
	local t1, t2 = (lo - o) / d, (hi - o) / d
	if t1 > t2 then
		return t2, t1
	end
	return t1, t2
end

--[[
	Where the ray from (ox, oy, oz) along (dx, dy, dz) enters the box (x0, y0, z0)..(x1, y1, z1):
	the distance and the entry face's axis (1..3), or nil when it misses. Starting inside counts as
	entering at 0 (axis 0). Scalars only: this runs every frame while aiming at a torch.
]]
local function enterBox(
	ox: number,
	oy: number,
	oz: number,
	dx: number,
	dy: number,
	dz: number,
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number
): (number?, number)
	local nearX, farX = slab(ox, dx, x0, x1)
	local nearY, farY = slab(oy, dy, y0, y1)
	local nearZ, farZ = slab(oz, dz, z0, z1)
	if nearX == nil or nearY == nil or nearZ == nil then
		return nil, 0
	end
	local near, axis = -math.huge, 0
	if nearX > near then
		near, axis = nearX, 1
	end
	if nearY > near then
		near, axis = nearY, 2
	end
	if nearZ > near then
		near, axis = nearZ, 3
	end
	local far = math.min(farX, farY, farZ)
	if near > far or far < 0 then
		return nil, 0
	end
	if near < 0 then
		return 0, 0
	end
	return near, axis
end

--[[
	`getBlock(x, y, z)` returns a block id or nil (unloaded = passes through).
	`isTarget(id)` decides which blocks stop the ray.
	`outline(id, x, y, z)` (optional): the part of the cell a block fills, { minX, minY, minZ,
	maxX, maxY, maxZ } in 0..1 (or several such boxes in a row), or nil for the whole cell
	(Blocks.outline, or Fire.outlineAt for a fire's, which depends on its neighbours).
]]
function VoxelRaycast.cast(
	ox: number,
	oy: number,
	oz: number,
	dx: number,
	dy: number,
	dz: number,
	maxDistance: number,
	getBlock: (x: number, y: number, z: number) -> number?,
	isTarget: (id: number) -> boolean,
	outline: ((id: number, x: number, y: number, z: number) -> { number }?)?
): Hit?
	local length = math.sqrt(dx * dx + dy * dy + dz * dz)
	if length < 1e-9 then
		return nil
	end
	dx, dy, dz = dx / length, dy / length, dz / length

	local x, y, z = math.floor(ox), math.floor(oy), math.floor(oz)
	local stepX = if dx > 0 then 1 elseif dx < 0 then -1 else 0
	local stepY = if dy > 0 then 1 elseif dy < 0 then -1 else 0
	local stepZ = if dz > 0 then 1 elseif dz < 0 then -1 else 0

	local function boundary(origin: number, cell: number, dir: number): (number, number)
		if dir == 0 then
			return math.huge, math.huge
		end
		local delta = math.abs(1 / dir)
		local next = if dir > 0 then (cell + 1 - origin) / dir else (origin - cell) / -dir
		return next, delta
	end

	local tMaxX, tDeltaX = boundary(ox, x, dx)
	local tMaxY, tDeltaY = boundary(oy, y, dy)
	local tMaxZ, tDeltaZ = boundary(oz, z, dz)

	local nx, ny, nz = 0, 0, 0
	local t = 0
	while t <= maxDistance do
		local block = getBlock(x, y, z)
		if block ~= nil and isTarget(block) then
			local box = if outline then outline(block, x, y, z) else nil
			if box == nil then
				return { x = x, y = y, z = z, nx = nx, ny = ny, nz = nz, block = block, distance = t }
			end
			local enter, axis = nil, 0
			for i = 1, #box - 5, 6 do
				local e, a = enterBox(
					ox,
					oy,
					oz,
					dx,
					dy,
					dz,
					x + box[i],
					y + box[i + 1],
					z + box[i + 2],
					x + box[i + 3],
					y + box[i + 4],
					z + box[i + 5]
				)
				if e and (enter == nil or e < enter) then
					enter, axis = e, a
				end
			end
			if enter and enter <= maxDistance then
				local hit = { x = x, y = y, z = z, nx = nx, ny = ny, nz = nz, block = block, distance = enter }
				if axis ~= 0 then
					local d = if axis == 1 then dx elseif axis == 2 then dy else dz
					local n = if d > 0 then -1 else 1
					hit.nx = if axis == 1 then n else 0
					hit.ny = if axis == 2 then n else 0
					hit.nz = if axis == 3 then n else 0
				end
				return hit
			end
		end
		if tMaxX < tMaxY and tMaxX < tMaxZ then
			x += stepX
			t = tMaxX
			tMaxX += tDeltaX
			nx, ny, nz = -stepX, 0, 0
		elseif tMaxY < tMaxZ then
			y += stepY
			t = tMaxY
			tMaxY += tDeltaY
			nx, ny, nz = 0, -stepY, 0
		else
			z += stepZ
			t = tMaxZ
			tMaxZ += tDeltaZ
			nx, ny, nz = 0, 0, -stepZ
		end
	end
	return nil
end

return VoxelRaycast
