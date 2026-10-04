--!strict
--[[
	Voxel raycast (Amanatides & Woo grid traversal).

	Works on block data directly, so it gives exact block / face results on the client and lets the
	server raycast without any parts existing there.

	Positions and distances are in *block units* (studs / Config.BlockSize).
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

-- `getBlock(x, y, z)` returns a block id or nil (unloaded = passes through).
-- `isTarget(id)` decides which blocks stop the ray.
function VoxelRaycast.cast(
	ox: number,
	oy: number,
	oz: number,
	dx: number,
	dy: number,
	dz: number,
	maxDistance: number,
	getBlock: (x: number, y: number, z: number) -> number?,
	isTarget: (id: number) -> boolean
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
			return { x = x, y = y, z = z, nx = nx, ny = ny, nz = nz, block = block, distance = t }
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
