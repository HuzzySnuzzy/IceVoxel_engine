return function(t, shared, require, _server, client)
	local Blocks = require(shared.Blocks)
	local Config = require(shared.Config)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local LodTree = require(shared.World.LodTree)
	local QuadMesher = require(shared.Meshing.QuadMesher)
	local GreedyMesher = require(shared.Meshing.GreedyMesher)
	local MeshGeometry = require(shared.Meshing.MeshGeometry)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)
	local MeshRegions = require(client.Rendering.MeshRegions)

	local SIZE = ChunkLayout.SIZE

	--[[ MeshGeometry ]]

	-- Quads of a little test terrain at LOD level `level`.
	local function nodeQuads(gen: any, level: number, nx: number, nz: number): (buffer, number)
		local r = gen.generate(level, nx, nz)
		local y0, y1 = GreedyMesher.activeRange(r.solidBelow, r.emptyAbove, r.height)
		return QuadMesher.mesh(r.data, r.height, y0, y1, true)
	end

	t.test("mesh geometry: centred positions, triangle cap, winding and colours", function()
		local gen = TerrainGenerator.new(777)
		local level = 2
		local step, stepY = ChunkLayout.steps(level)
		local scale, scaleY = step * Config.BlockSize, stepY * Config.BlockSize
		local builder = MeshGeometry.builder(Config.BlockSize, 0, 400)
		local all = {}
		for i = 0, 3 do
			local quads, count = nodeQuads(gen, level, 40 + i, -60)
			local ox, oz = (40 + i) * SIZE * scale, -60 * SIZE * scale
			builder:add(quads, count, ox, oz, scale, scaleY)
			table.insert(all, { quads = quads, count = count, ox = ox, oz = oz })
		end
		t.eq(builder.total, all[1].count + all[2].count + all[3].count + all[4].count)
		local meshes = builder:finish()
		t.ok(#meshes > 1, "split at the triangle cap")

		-- Every quad appears once, in order, with its corners at the right place.
		local expected = {}
		for _, node in all do
			for i = 0, node.count - 1 do
				table.insert(expected, {
					corners = {
						QuadMesher.corners(node.quads, i, node.ox, node.oz, scale, scaleY, Config.BlockSize, 0),
					},
					app = buffer.readu16(node.quads, i * QuadMesher.QUAD_BYTES + 12) % QuadMesher.KEY_STRIDE,
				})
			end
		end
		local index = 0
		for _, mesh in meshes do
			t.ok(mesh.quads * 2 <= 400, "cap respected")
			local c = mesh.center
			local min, max = { math.huge, math.huge, math.huge }, { -math.huge, -math.huge, -math.huge }
			for v = 1, #mesh.positions, 3 do
				for a = 1, 3 do
					local p = mesh.positions[v + a - 1] + c[a]
					min[a] = math.min(min[a], p)
					max[a] = math.max(max[a], p)
				end
			end
			for a = 1, 3 do
				t.ok(math.abs((min[a] + max[a]) / 2 - c[a]) < 1e-6, "centre is the box centre")
				t.ok(math.abs(max[a] - min[a] - mesh.size[a]) < 1e-6, "size is the box size")
				t.ok(mesh.size[a] <= 2048, "fits in a part")
			end
			for q = 0, mesh.quads - 1 do
				index += 1
				local want = expected[index]
				if want == nil then
					-- Only an anchor quad may be extra.
					t.eq(q, mesh.quads - 1, "extra quad is the last one")
					index -= 1
					break
				end
				for k = 1, 12 do
					local axis = (k - 1) % 3 + 1
					local got = mesh.positions[q * 12 + k] + c[axis]
					t.ok(math.abs(got - want.corners[k]) < 1e-6, "corner position")
				end
				t.eq(mesh.appearances[q + 1], want.app, "appearance")
			end
		end
		t.eq(index, #expected, "every quad placed once")
	end)

	t.test("mesh geometry: a flat sheet gets an anchor so its box is never flat", function()
		local sheet = buffer.create(QuadMesher.QUAD_BYTES)
		buffer.writeu16(sheet, 0, 2) -- +Y
		buffer.writeu16(sheet, 8, 16)
		buffer.writeu16(sheet, 10, 16)
		buffer.writeu16(sheet, 12, Blocks.get(Blocks.id.Stone).appearance)
		local builder = MeshGeometry.builder(Config.BlockSize, 0.05, 1000)
		builder:add(sheet, 1, 100, 200, 32, Config.BlockSize)
		local meshes = builder:finish()
		t.eq(#meshes, 1)
		local mesh = meshes[1]
		t.eq(mesh.quads, 2, "sheet plus anchor")
		for a = 1, 3 do
			t.ok(mesh.size[a] >= MeshGeometry.MIN_EXTENT - 1e-9, `axis {a} not flat`)
		end
		-- The anchor faces down (counter-clockwise seen from below).
		local p = mesh.positions
		local ax, ay, az = p[13], p[14], p[15]
		local ux, uy, uz = p[16] - ax, p[17] - ay, p[18] - az
		local vx, vy, vz = p[19] - ax, p[20] - ay, p[21] - az
		local ny = uz * vx - ux * vz
		t.ok(ny < 0 and uy == 0 and vy == 0, "anchor normal points down")
	end)

	t.test("mesh geometry: tall faces are cut into bands that fit in a part", function()
		local BAND = MeshGeometry.BAND
		local quads = buffer.create(2 * QuadMesher.QUAD_BYTES)
		local stone = Blocks.get(Blocks.id.Stone).appearance
		-- A +X wall 1000 cells (3000 studs) high, and a floor exactly on the first band boundary.
		buffer.writeu16(quads, 0, 0)
		buffer.writeu16(quads, 8, 1000)
		buffer.writeu16(quads, 10, 4)
		buffer.writeu16(quads, 12, stone)
		local floorY = BAND // Config.BlockSize - 1 -- its +Y face is at y = BAND studs
		local o = QuadMesher.QUAD_BYTES
		buffer.writeu16(quads, o, 2)
		buffer.writeu16(quads, o + 4, floorY)
		buffer.writeu16(quads, o + 8, 4)
		buffer.writeu16(quads, o + 10, 4)
		buffer.writeu16(quads, o + 12, stone)
		local builder = MeshGeometry.builder(Config.BlockSize, 0, 1000)
		builder:add(quads, 2, 0, 0, Config.BlockSize, Config.BlockSize)
		local meshes = builder:finish()
		t.eq(#meshes, 2, "one mesh per band")
		local wallArea = 0
		for band, mesh in meshes do
			t.ok(mesh.size[2] <= BAND + 2 * MeshGeometry.MIN_EXTENT, `band {band} is {mesh.size[2]} studs high`)
			local bottom = mesh.center[2] - mesh.size[2] / 2
			local top = mesh.center[2] + mesh.size[2] / 2
			t.ok(bottom >= (band - 1) * BAND - MeshGeometry.MIN_EXTENT - 1e-6, "below its band")
			t.ok(top <= band * BAND + 1e-6, "above its band")
			for q = 0, mesh.quads - 1 do
				local p = mesh.positions
				local ys = { p[q * 12 + 2], p[q * 12 + 5], p[q * 12 + 8], p[q * 12 + 11] }
				local height = math.max(table.unpack(ys)) - math.min(table.unpack(ys))
				if height > 0 then
					wallArea += height
				end
			end
		end
		t.ok(math.abs(wallArea - 1000 * Config.BlockSize) < 1e-6, `wall pieces add up ({wallArea})`)
		-- The floor on the boundary belongs to the upper band (whose box starts there).
		t.eq(meshes[2].quads, 2, "upper band: wall piece and floor")
	end)

	--[[ Far seam limits ]]

	t.test("far seam limits never leave more padding than a coarser neighbour draws", function()
		local gen = TerrainGenerator.new(777)
		for level = 1, Config.Lod.Levels - 2 do
			local far = gen.farSeamLimits(level, 3, -7) :: buffer
			t.ok(far ~= nil, "far limits exist below the coarsest level")
			for up = level + 1, math.min(level + 2, Config.Lod.Levels - 1) do
				for side = 1, 4 do
					local coarser = { 0, 0, 0, 0 }
					coarser[side] = up
					local exact = gen.seamLimits(level, 3, -7, coarser) :: buffer
					for i = 0, SIZE - 1 do
						local o = ((side - 1) * SIZE + i) * 2
						t.ok(
							buffer.readu16(far, o) <= buffer.readu16(exact, o),
							`level {level} side {side} column {i} vs level {up} neighbour`
						)
					end
				end
			end
		end
		t.eq(gen.farSeamLimits(Config.Lod.Levels - 1, 0, 0), nil, "nothing is coarser than the top level")
	end)

	--[[ MeshRegions ]]

	local function node(level: number, nx: number, nz: number)
		return { level = level, nx = nx, nz = nz, removed = false }
	end

	local function regions(stable: number?)
		return MeshRegions.new({
			minLevel = 2,
			regionNodes = 4,
			maxRegionBlocks = 512,
			stableSeconds = stable or 2,
			rebuildSeconds = 8,
			nodeSize = LodTree.nodeSize,
		})
	end

	local function always()
		return true
	end

	t.test("regions: eligibility and keys", function()
		local r = regions()
		t.eq(r:keyOf(1, 0, 0), nil, "below MinLevel")
		t.eq(r:keyOf(2, 0, 0), r:keyOf(2, 3, 3), "4x4 nodes per region")
		t.ok(r:keyOf(2, 4, 0) ~= r:keyOf(2, 3, 0), "next region")
		t.eq(r:keyOf(2, -1, 0), "2:-1,0", "negative coordinates floor")
		-- Level 4 nodes are 256 blocks: 2 x 2 per 512-block region; level 6 (1024) is too wide.
		t.eq(r:keyOf(4, 0, 0), r:keyOf(4, 1, 1))
		t.ok(r:keyOf(4, 2, 0) ~= r:keyOf(4, 1, 0))
		t.eq(r:keyOf(6, 0, 0), nil, "too wide for one part")
	end)

	t.test("regions: promotion after a stable period, larger first", function()
		local r = regions(2)
		local a, b, c = node(2, 0, 0), node(2, 1, 0), node(2, 8, 0)
		r:add(a, 0)
		r:add(b, 0)
		r:add(c, 0.5)
		t.eq(r:candidate(1.9, always), nil, "not stable yet")
		local first = r:candidate(2.1, always) :: any
		t.eq(first.count, 2, "the region with two nodes first")
		local others = r:candidate(2.6, function(n)
			return n ~= a
		end) :: any
		t.eq(others and others.count, 1, "regions with a member lacking quads wait")
		local job = r:begin(first)
		t.eq(#job.members, 2)
		t.ok(r:candidate(2.6, always) ~= first, "a building region is not offered again")
		t.ok(r:finish(job, true, 3), "unchanged members: apply")
		t.ok(first.meshed[a] ~= nil and first.meshed[b] ~= nil)
		t.ok(r:candidate(10, always) ~= first, "a meshed, unchanged region is done")
	end)

	t.test("regions: removing or changing a meshed member demotes, additions do not", function()
		local r = regions(0)
		local a, b = node(3, 0, 0), node(3, 1, 0)
		r:add(a, 0)
		r:add(b, 0)
		local region = r:candidate(0, always) :: any
		t.ok(r:finish(r:begin(region), true, 0))
		-- A new member stays parts; the mesh is still valid.
		local c = node(3, 2, 0)
		r:add(c, 1)
		t.eq(r:changed(c, 1), nil, "change of a member not in the mesh")
		t.ok(region.meshed ~= nil, "still meshed")
		t.eq(r:candidate(1, always), nil, "a meshed region waits longer before it is rebuilt")
		t.eq(r:candidate(9.5, always), region, "re-promoted to include the new member")
		-- Changing a member inside the mesh demotes.
		t.eq(r:changed(a, 2), region)
		r:demoted(region, 2)
		t.eq(region.meshed, nil)
		-- Mesh again, then remove a member inside it.
		t.ok(r:finish(r:begin(region), true, 3))
		t.eq(r:remove(b, 4), region, "removal of a meshed member demotes")
		r:demoted(region, 4)
		-- Removing everything drops the region.
		r:remove(a, 5)
		r:remove(c, 5)
		t.eq(r:stats().regions, 0, "empty region forgotten")
	end)

	t.test("regions: builds are discarded when members changed meanwhile, failures back off", function()
		local r = regions(0)
		local a, b = node(2, 0, 0), node(2, 1, 0)
		r:add(a, 0)
		r:add(b, 0)
		local region = r:candidate(0, always) :: any
		local job = r:begin(region)
		r:changed(a, 0.5)
		t.ok(not r:finish(job, true, 1), "member changed during the build")
		t.eq(region.meshed, nil)

		job = r:begin(r:candidate(1, always) :: any)
		r:remove(b, 1.5)
		t.ok(not r:finish(job, true, 2), "member removed during the build")

		job = r:begin(r:candidate(2, always) :: any)
		local d = node(2, 2, 0)
		r:add(d, 2.5)
		t.ok(r:finish(job, true, 3), "a member added during the build does not invalidate it")
		t.eq(region.meshed[d], nil, "the new member stays parts")

		-- Failures wait 2, 4, 8 ... seconds.
		r:changed(a, 3)
		r:demoted(region, 3)
		job = r:begin(r:candidate(3, always) :: any)
		t.ok(not r:finish(job, false, 3))
		t.eq(r:candidate(4.9, always), nil, "backing off")
		job = r:begin(r:candidate(5.1, always) :: any)
		t.ok(not r:finish(job, false, 5.1))
		t.eq(r:candidate(9, always), nil, "longer back off")
		t.ok(r:candidate(9.2, always) ~= nil)
	end)

	t.test("regions: a small region that waited long is not starved by larger ones", function()
		local r = regions(2)
		local lone = node(5, 0, 0) -- 512-block nodes: one per region
		r:add(lone, 0)
		local big = {}
		for i = 0, 15 do
			big[i + 1] = node(2, i % 4, i // 4)
			r:add(big[i + 1], 9)
		end
		local first = r:candidate(11, always) :: any
		t.eq(first.count, 16, "a big region that just became stable goes first")
		-- The big region keeps changing; the lone one has waited a minute.
		r:changed(big[1], 58)
		t.eq(r:candidate(60, always), r.regionOf[lone], "the long wait wins")
	end)

	t.test("regions: a region emptied while building is dropped", function()
		local r = regions(0)
		local a = node(2, 0, 0)
		r:add(a, 0)
		local job = r:begin(r:candidate(0, always) :: any)
		r:remove(a, 1)
		t.ok(not r:finish(job, true, 2))
		t.eq(r:stats().regions, 0)
	end)
end
