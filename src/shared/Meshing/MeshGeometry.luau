--!strict
--[[
	Turns the quads of several chunk nodes (QuadMesher output) into the arrays of one or more meshes,
	each small enough for one EditableMesh / MeshPart. Pure Luau: the client converts the numbers into
	Vector3 / Color3 values and feeds them to the batch APIs (see Rendering/MeshOverlay).

	A mesh holds whole quads, at most `maxTriangles / 2` of them, in the order the nodes and their
	quads are added, so the result is deterministic. Each quad becomes four vertices of its own
	(corners wound counter-clockwise, see QuadMesher.corners) and two triangles (0, 1, 2) and
	(0, 2, 3); with unshared vertices the engine's automatic normals are exactly the face normals.

	Positions are relative to the centre of the mesh's bounding box (a MeshPart is centred on its
	mesh; place it at `center`). A mesh whose box is flat on some axis (e.g. a sheet of sea water)
	gets one extra tiny quad below it, so no axis of its part is (almost) zero.
]]

local QuadMesher = require(script.Parent.QuadMesher)

local KEY_STRIDE = QuadMesher.KEY_STRIDE
-- Thinnest a mesh's box may be on any axis (studs); also the size of the quad that ensures it.
local MIN_EXTENT = 0.1

export type Mesh = {
	-- x, y, z per vertex, relative to `center` (four vertices per quad).
	positions: { number },
	-- Appearance id of each quad (its four vertices share it).
	appearances: { number },
	quads: number,
	-- Centre and size of the bounding box in studs.
	center: { number },
	size: { number },
}

export type Builder = {
	add: (
		self: Builder,
		quads: buffer,
		count: number,
		originX: number,
		originZ: number,
		scale: number,
		scaleY: number
	) -> (),
	finish: (self: Builder) -> { Mesh },
	-- Quads added so far.
	total: number,
}

type Raw = {
	-- Absolute positions while collecting.
	positions: { number },
	appearances: { number },
	quads: number,
	min: { number },
	max: { number },
}

local MeshGeometry = {}

MeshGeometry.MIN_EXTENT = MIN_EXTENT

local function newRaw(): Raw
	return {
		positions = {},
		appearances = {},
		quads = 0,
		min = { math.huge, math.huge, math.huge },
		max = { -math.huge, -math.huge, -math.huge },
	}
end

local function push(raw: Raw, x: number, y: number, z: number)
	local positions = raw.positions
	local n = #positions
	positions[n + 1], positions[n + 2], positions[n + 3] = x, y, z
	local min, max = raw.min, raw.max
	if x < min[1] then
		min[1] = x
	end
	if x > max[1] then
		max[1] = x
	end
	if y < min[2] then
		min[2] = y
	end
	if y > max[2] then
		max[2] = y
	end
	if z < min[3] then
		min[3] = z
	end
	if z > max[3] then
		max[3] = z
	end
end

--[[
	`blockSize` is Config.BlockSize (for lowered fluid surfaces), `grow` the in-plane overlap of every
	quad (studs), `maxTriangles` the triangle cap per mesh (even, at least 4).
]]
function MeshGeometry.builder(blockSize: number, grow: number, maxTriangles: number): Builder
	assert(maxTriangles >= 4, "maxTriangles too small")
	-- Leave room for the anchor quad.
	local perMesh = maxTriangles // 2 - 1
	local done: { Raw } = {}
	local current = newRaw()

	local builder = { total = 0 }

	function builder.add(
		self: Builder,
		quads: buffer,
		count: number,
		originX: number,
		originZ: number,
		scale: number,
		scaleY: number
	)
		for i = 0, count - 1 do
			if current.quads >= perMesh then
				table.insert(done, current)
				current = newRaw()
			end
			local ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz =
				QuadMesher.corners(quads, i, originX, originZ, scale, scaleY, blockSize, grow)
			push(current, ax, ay, az)
			push(current, bx, by, bz)
			push(current, cx, cy, cz)
			push(current, dx, dy, dz)
			current.quads += 1
			current.appearances[current.quads] = buffer.readu16(quads, i * QuadMesher.QUAD_BYTES + 12) % KEY_STRIDE
		end
		self.total += count
	end

	function builder.finish(_self: Builder): { Mesh }
		if current.quads > 0 then
			table.insert(done, current)
			current = newRaw()
		end
		local meshes: { Mesh } = {}
		for _, raw in done do
			-- Keep every axis of the box at least MIN_EXTENT thick with a tiny quad facing down,
			-- just below the mesh (out of sight under the surfaces it extends).
			local min, max = raw.min, raw.max
			if max[1] - min[1] < MIN_EXTENT or max[2] - min[2] < MIN_EXTENT or max[3] - min[3] < MIN_EXTENT then
				local x, y, z = min[1], min[2] - MIN_EXTENT, min[3]
				local s = MIN_EXTENT
				-- A -Y face: these corners wind counter-clockwise seen from below.
				push(raw, x, y, z)
				push(raw, x + s, y, z)
				push(raw, x + s, y, z + s)
				push(raw, x, y, z + s)
				raw.quads += 1
				raw.appearances[raw.quads] = raw.appearances[1]
			end
			local cx, cy, cz = (min[1] + max[1]) / 2, (min[2] + max[2]) / 2, (min[3] + max[3]) / 2
			local positions = raw.positions
			for j = 1, #positions, 3 do
				positions[j] -= cx
				positions[j + 1] -= cy
				positions[j + 2] -= cz
			end
			table.insert(meshes, {
				positions = positions,
				appearances = raw.appearances,
				quads = raw.quads,
				center = { cx, cy, cz },
				size = { max[1] - min[1], max[2] - min[2], max[3] - min[3] },
			})
		end
		done = {}
		return meshes
	end

	return (builder :: any) :: Builder
end

return MeshGeometry
