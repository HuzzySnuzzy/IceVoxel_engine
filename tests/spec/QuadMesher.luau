return function(t, shared, require)
	local Blocks = require(shared.Blocks)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local QuadMesher = require(shared.Meshing.QuadMesher)
	local GreedyMesher = require(shared.Meshing.GreedyMesher)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)

	local SIZE = ChunkLayout.SIZE
	local NORMALS = QuadMesher.NORMALS
	local STRIDE = QuadMesher.KEY_STRIDE

	-- Reference: key of the face of cell (x, y, z) in direction `dir`, 0 when not drawn.
	local function referenceKey(
		data: buffer,
		height: number,
		x: number,
		y: number,
		z: number,
		dir: number,
		hide: boolean
	)
		local cull = if hide then Blocks.cullLutHiddenCaves else Blocks.cullLut
		local id = ChunkLayout.get(data, x, y, z)
		local app = Blocks.get(id).appearance
		local caveCell = id == Blocks.CAVE_AIR or buffer.readu8(Blocks.caveTwinLut, id) == 1
		if app == 0 and not (hide and caveCell) then
			return 0
		end
		local d = NORMALS[dir + 1]
		local ny = y + d[2]
		local n
		if ny < 0 then
			return 0
		elseif ny >= height then
			n = Blocks.AIR
		else
			n = ChunkLayout.getPadded(data, x + d[1], ny, z + d[3])
		end
		local seeThrough = buffer.readu8(cull, n) == 0
		if hide and caveCell then
			-- Hidden caves: rock, with a stone cap towards open space that is not cave.
			return if seeThrough then Blocks.get(Blocks.id.Stone).appearance else 0
		end
		local kind = Blocks.appearances[app].kind
		if kind == Blocks.KIND_OPAQUE then
			return if seeThrough then app else 0
		elseif kind == Blocks.KIND_TRANSPARENT then
			return if seeThrough and n ~= id then app else 0
		elseif kind == Blocks.KIND_FLUID then
			if not seeThrough or Blocks.get(n).appearance == app then
				return 0
			end
			local surface = buffer.readu8(Blocks.fluidHeightLut, id)
			local above = if y + 1 < height then ChunkLayout.get(data, x, y + 1, z) else Blocks.AIR
			if surface < Blocks.FLUID_FULL and Blocks.get(above).appearance ~= app then
				return app + surface * STRIDE
			end
			return app
		end
		return 0
	end

	-- The cells a quad covers, as "x,y,z,dir" -> key.
	local function cellsOf(quads: buffer, i: number): { [string]: number }
		local o = i * QuadMesher.QUAD_BYTES
		local dir = buffer.readu16(quads, o)
		local x, y, z = buffer.readu16(quads, o + 2), buffer.readu16(quads, o + 4), buffer.readu16(quads, o + 6)
		local du, dv = buffer.readu16(quads, o + 8), buffer.readu16(quads, o + 10)
		local key = buffer.readu16(quads, o + 12)
		-- Extents along X, Y, Z from the face axes (see QuadMesher.corners).
		local ex, ey, ez = 1, 1, 1
		if dir == 0 then
			ey, ez = du, dv
		elseif dir == 1 then
			ez, ey = du, dv
		elseif dir == 2 then
			ez, ex = du, dv
		elseif dir == 3 then
			ex, ez = du, dv
		elseif dir == 4 then
			ex, ey = du, dv
		else
			ey, ex = du, dv
		end
		local out = {}
		for yy = y, y + ey - 1 do
			for zz = z, z + ez - 1 do
				for xx = x, x + ex - 1 do
					out[`{xx},{yy},{zz},{dir}`] = key
				end
			end
		end
		return out
	end

	local function verify(data: buffer, height: number, y0: number, y1: number, hide: boolean): number
		local quads, count = QuadMesher.mesh(data, height, y0, y1, hide)
		local covered: { [string]: number } = {}
		for i = 0, count - 1 do
			for cell, key in cellsOf(quads, i) do
				t.ok(covered[cell] == nil, `face {cell} covered twice`)
				covered[cell] = key
			end
		end
		local faces = 0
		for y = y0, y1 - 1 do
			for z = 0, SIZE - 1 do
				for x = 0, SIZE - 1 do
					for dir = 0, 5 do
						local cell = `{x},{y},{z},{dir}`
						local want = referenceKey(data, height, x, y, z, dir, hide)
						if want ~= 0 then
							faces += 1
						end
						t.eq(covered[cell] or 0, want, `face {cell}`)
						covered[cell] = nil
					end
				end
			end
		end
		t.ok(next(covered) == nil, "no quad outside the meshed range")
		return faces
	end

	t.test("quads cover every visible face exactly once (blocks, glass, lowered water)", function()
		local height = 8
		local data = ChunkLayout.create(height)
		local stone, glass = Blocks.id.Stone, Blocks.id.Glass
		for z = 0, SIZE - 1 do
			for x = 0, SIZE - 1 do
				ChunkLayout.set(data, x, 0, z, Blocks.id.Bedrock)
				ChunkLayout.set(data, x, 1, z, stone)
			end
		end
		ChunkLayout.set(data, 3, 2, 3, stone)
		ChunkLayout.set(data, 4, 2, 3, glass)
		ChunkLayout.set(data, 5, 2, 3, glass)
		ChunkLayout.set(data, 8, 2, 8, Blocks.fluidId("Water", 0))
		ChunkLayout.set(data, 9, 2, 8, Blocks.fluidId("Water", 3))
		ChunkLayout.set(data, 10, 2, 8, Blocks.fluidId("Water", 3))
		ChunkLayout.set(data, 12, 2, 12, Blocks.fluidId("Water", 0))
		ChunkLayout.set(data, 12, 3, 12, Blocks.fluidId("Water", 0))
		-- A neighbour in the padding hides the border face next to it.
		ChunkLayout.setPadded(data, -1, 2, 0, stone)
		ChunkLayout.set(data, 0, 2, 0, stone)
		local faces = verify(data, height, 0, height, true)
		t.ok(faces > 0)
		-- The flat floor merges: one quad on top of the stone layer around the extras.
		local quads, count = QuadMesher.mesh(data, height, 0, height, true)
		t.ok(count < 60, `few quads for a flat floor ({count})`)
		local _ = quads
	end)

	t.test("quads cover generated chunks exactly, at every LOD level and with caves", function()
		local gen = TerrainGenerator.new(4242)
		for level = 0, 4 do
			local r = gen.generate(level, 3, -2)
			local y0, y1 = GreedyMesher.activeRange(r.solidBelow, r.emptyAbove, r.height)
			verify(r.data, r.height, y0, y1, true)
		end
		local r = gen.generate(0, -12, -11)
		verify(r.data, r.height, 0, r.height, false)
	end)

	t.test("quads: with caves hidden, a surface cave meets the caves in stone caps", function()
		local gen = TerrainGenerator.new(12345)
		local stone = Blocks.get(Blocks.id.Stone).appearance
		-- The first chunk around (0, 6) where air carved below the surface touches cave air.
		for ring = 0, 4 do
			for dz = -ring, ring do
				for dx = -ring, ring do
					if math.abs(dx) ~= ring and math.abs(dz) ~= ring then
						continue
					end
					local r = gen.generate(0, dx, 6 + dz, nil, true)
					local caps = 0
					for z = 0, SIZE - 1 do
						for x = 0, SIZE - 1 do
							local top = buffer.readu16(r.surface, (z * SIZE + x) * 2)
							for y = math.max(r.solidBelow, 1), top - 1 do
								if ChunkLayout.get(r.data, x, y, z) == Blocks.CAVE_AIR then
									for dir = 0, 5 do
										if referenceKey(r.data, r.height, x, y, z, dir, true) == stone then
											caps += 1
										end
									end
								end
							end
						end
					end
					if caps > 0 then
						local y0, y1 = GreedyMesher.activeRange(r.solidBelow, r.emptyAbove, r.height)
						verify(r.data, r.height, y0, y1, true)
						return
					end
				end
			end
		end
		error("no surface cave meets a cave around chunk 0, 6")
	end)

	t.test("quad corners wind counter-clockwise around the outward normal", function()
		local height = 8
		local data = ChunkLayout.create(height)
		ChunkLayout.set(data, 5, 3, 7, Blocks.id.Stone)
		ChunkLayout.set(data, 9, 3, 7, Blocks.fluidId("Water", 4))
		local quads, count = QuadMesher.mesh(data, height, 0, height, true)
		t.eq(count, 12, "two single cells give 12 faces")
		local seen = {}
		for i = 0, count - 1 do
			local dir = buffer.readu16(quads, i * QuadMesher.QUAD_BYTES)
			local ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz = QuadMesher.corners(quads, i, 30, -60, 3, 6, 3, 0)
			-- Normal of (b - a) x (c - a) points outwards for a counter-clockwise front face.
			local ux, uy, uz = bx - ax, by - ay, bz - az
			local vx, vy, vz = cx - ax, cy - ay, cz - az
			local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
			local n = NORMALS[dir + 1]
			local length = math.sqrt(nx * nx + ny * ny + nz * nz)
			t.ok(length > 0, "non-degenerate")
			t.ok(
				math.abs(nx / length - n[1]) < 1e-9
					and math.abs(ny / length - n[2]) < 1e-9
					and math.abs(nz / length - n[3]) < 1e-9,
				`winding of direction {dir}`
			)
			-- The fourth corner closes the parallelogram.
			t.ok(math.abs(ax + (cx - bx) - dx) < 1e-9 and math.abs(ay + (cy - by) - dy) < 1e-9, "planar quad")
			t.ok(math.abs(az + (cz - bz) - dz) < 1e-9, "planar quad")
			seen[dir] = true
		end
		for dir = 0, 5 do
			t.ok(seen[dir], `direction {dir} present`)
		end
		-- Stone cell (5, 3, 7): x 30 + 15 .. 30 + 18, y 18 .. 24, z -60 + 21 .. -60 + 24.
		for i = 0, count - 1 do
			local o = i * QuadMesher.QUAD_BYTES
			if buffer.readu16(quads, o + 2) == 5 and buffer.readu16(quads, o) == 2 then
				local _, y = QuadMesher.corners(quads, i, 30, -60, 3, 6, 3, 0)
				t.eq(y, 24, "top face of the stone cell")
			elseif buffer.readu16(quads, o + 2) == 9 and buffer.readu16(quads, o) == 2 then
				local _, y = QuadMesher.corners(quads, i, 30, -60, 3, 6, 3, 0)
				-- Level 4 water: surface 4 / 9 of a block above the cell bottom.
				t.ok(math.abs(y - (18 + 6 - (9 - 4) / 9 * 3)) < 1e-9, `lowered water top ({y})`)
			end
		end
	end)

	t.test("quad growth overlaps neighbours without moving the face plane", function()
		local data = ChunkLayout.create(4)
		ChunkLayout.set(data, 2, 1, 2, Blocks.id.Stone)
		local quads, count = QuadMesher.mesh(data, 4, 0, 4, true)
		for i = 0, count - 1 do
			local dir = buffer.readu16(quads, i * QuadMesher.QUAD_BYTES)
			local plain = { QuadMesher.corners(quads, i, 0, 0, 3, 3, 3, 0) }
			local grown = { QuadMesher.corners(quads, i, 0, 0, 3, 3, 3, 0.05) }
			local axis = if dir <= 1 then 1 elseif dir <= 3 then 2 else 3
			for c = 0, 3 do
				t.eq(grown[c * 3 + axis], plain[c * 3 + axis], "plane unchanged")
			end
			-- Area grows from 3 x 3 to 3.1 x 3.1.
			local ux, uy, uz = grown[4] - grown[1], grown[5] - grown[2], grown[6] - grown[3]
			t.ok(math.abs(math.sqrt(ux * ux + uy * uy + uz * uz) - 3.1) < 1e-9, "grown edge")
		end
	end)
end
