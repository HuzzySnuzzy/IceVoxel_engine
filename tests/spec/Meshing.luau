return function(t, shared, require)
	local Config = require(shared.Config)
	local Blocks = require(shared.Blocks)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local GreedyMesher = require(shared.Meshing.GreedyMesher)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)

	local SIZE = ChunkLayout.SIZE
	local OPAQUE, FLUID = Blocks.KIND_OPAQUE, Blocks.KIND_FLUID

	-- Straightforward reference for which cells must be drawn / may be skipped.
	local function classify(data: buffer, height: number, x: number, y: number, z: number, hideCaves: boolean)
		local cull = if hideCaves then Blocks.cullLutHiddenCaves else Blocks.cullLut
		local id = ChunkLayout.get(data, x, y, z)
		local app = Blocks.get(id).appearance
		if app == 0 then
			return 0, false
		end
		local kind = Blocks.appearances[app].kind
		local function neighbour(dx: number, dy: number, dz: number): number?
			local ny = y + dy
			if ny < 0 then
				return nil -- below the world: counts as solid
			elseif ny >= height then
				return Blocks.AIR
			end
			return ChunkLayout.getPadded(data, x + dx, ny, z + dz)
		end
		local dirs = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }
		if kind == OPAQUE then
			for _, d in dirs do
				local n = neighbour(d[1], d[2], d[3])
				if n ~= nil and buffer.readu8(cull, n) == 0 then
					return app, false
				end
			end
			return 0, true
		elseif kind == FLUID then
			for _, d in dirs do
				local n = neighbour(d[1], d[2], d[3])
				if n ~= nil and buffer.readu8(cull, n) == 0 and n ~= id then
					-- Visible; lowered to its level unless the same fluid continues above.
					local above = neighbour(0, 1, 0)
					local surface = buffer.readu8(Blocks.fluidHeightLut, id)
					if surface < Blocks.FLUID_FULL and Blocks.get(above :: number).appearance ~= app then
						return app + surface * GreedyMesher.KEY_STRIDE, false
					end
					return app, false
				end
			end
			return 0, false
		end
		return app, false
	end

	local function verify(data: buffer, height: number, y0: number, y1: number, hideCaves: boolean): number
		local boxes, count = GreedyMesher.mesh(data, height, y0, y1, hideCaves)
		local coverage: { [number]: number } = {}
		for b = 0, count - 1 do
			local o = b * GreedyMesher.BOX_BYTES
			local bx, by, bz = buffer.readu16(boxes, o), buffer.readu16(boxes, o + 2), buffer.readu16(boxes, o + 4)
			local sx, sy, sz = buffer.readu16(boxes, o + 6), buffer.readu16(boxes, o + 8), buffer.readu16(boxes, o + 10)
			local app = buffer.readu16(boxes, o + 12) -- appearance + fluid surface height (see GreedyMesher)
			local opaqueBox = Blocks.appearances[app % GreedyMesher.KEY_STRIDE].kind == OPAQUE
			assert(bx + sx <= SIZE and bz + sz <= SIZE and by >= y0 and by + sy <= y1, "box outside the section")
			for y = by, by + sy - 1 do
				for z = bz, bz + sz - 1 do
					for x = bx, bx + sx - 1 do
						local need, wild = classify(data, height, x, y, z, hideCaves)
						if need == app then
							local key = (y * SIZE + z) * SIZE + x
							coverage[key] = (coverage[key] or 0) + 1
						elseif not (wild and opaqueBox) then
							error(`box covers cell ({x},{y},{z}) it must not cover (need {need}, wild {wild})`)
						end
					end
				end
			end
		end
		for y = y0, y1 - 1 do
			for z = 0, SIZE - 1 do
				for x = 0, SIZE - 1 do
					local need = classify(data, height, x, y, z, hideCaves)
					if need ~= 0 then
						local n = coverage[(y * SIZE + z) * SIZE + x] or 0
						if n ~= 1 then
							error(`visible cell ({x},{y},{z}) covered {n} times`)
						end
					end
				end
			end
		end
		return count
	end

	t.test("single block becomes a single box", function()
		local data = ChunkLayout.create(4)
		ChunkLayout.set(data, 5, 1, 7, Blocks.id.Stone)
		t.eq(verify(data, 4, 0, 4, false), 1)
	end)

	t.test("a flat layer merges into one box and buried blocks are free", function()
		local data = ChunkLayout.create(8)
		for z = -1, SIZE do
			for x = -1, SIZE do
				for y = 0, 3 do
					ChunkLayout.setPadded(data, x, y, z, Blocks.id.Stone)
				end
				ChunkLayout.setPadded(data, x, 4, z, Blocks.id.Grass)
			end
		end
		t.eq(verify(data, 8, 0, 8, false), 1, "only the grass layer is visible")
		-- Dig a hole: the stone around it becomes visible and must be covered exactly.
		ChunkLayout.set(data, 8, 4, 8, Blocks.AIR)
		ChunkLayout.set(data, 8, 3, 8, Blocks.AIR)
		local count = verify(data, 8, 0, 8, false)
		t.ok(count > 1 and count < 12, `hole produced {count} boxes`)
	end)

	t.test("flowing water is lowered per level and only equal levels merge", function()
		local data = ChunkLayout.create(8)
		for z = -1, SIZE do
			for x = -1, SIZE do
				ChunkLayout.setPadded(data, x, 0, z, Blocks.id.Stone)
			end
		end
		-- A source with a row of weaker and weaker flowing water next to it, plus a falling column.
		ChunkLayout.set(data, 0, 1, 0, Blocks.fluidId("Water", 0))
		for level = 1, 7 do
			ChunkLayout.set(data, level, 1, 0, Blocks.fluidId("Water", level))
		end
		for y = 1, 4 do
			ChunkLayout.set(data, 10, y, 10, Blocks.fluidId("Water", 8))
		end
		local boxes, count = GreedyMesher.mesh(data, 8, 0, 8, false)
		local heights: { [number]: number } = {}
		for b = 0, count - 1 do
			local o = b * GreedyMesher.BOX_BYTES
			local appearance, surface = GreedyMesher.decodeKey(buffer.readu16(boxes, o + 12))
			if Blocks.appearances[appearance].kind == FLUID then
				heights[buffer.readu16(boxes, o) * 100 + buffer.readu16(boxes, o + 4)] = surface
			end
		end
		t.eq(heights[0], 8, "source surface is 8/9")
		t.eq(heights[300], 5, "level 3 is 5/9")
		t.eq(heights[700], 1, "level 7 is 1/9")
		t.eq(heights[1010], 0, "falling water is full height")
		verify(data, 8, 0, 8, false)
	end)

	t.test("glass and water are covered correctly", function()
		local data = ChunkLayout.create(8)
		local water = Blocks.fluidId("Water", 0)
		for z = -1, SIZE do
			for x = -1, SIZE do
				ChunkLayout.setPadded(data, x, 0, z, Blocks.id.Sand)
				for y = 1, 3 do
					ChunkLayout.setPadded(data, x, y, z, water)
				end
			end
		end
		ChunkLayout.set(data, 2, 2, 2, Blocks.id.Glass)
		ChunkLayout.set(data, 2, 3, 2, Blocks.id.Glass)
		verify(data, 8, 0, 8, false)
	end)

	t.test("generated chunks: every visible block covered once, nothing visible over-covered", function()
		local gen = TerrainGenerator.new(777)
		local sectionHeight = Config.SectionHeight
		local total = 0
		for _, p in { { 0, 0 }, { 3, -8 }, { -20, 11 } } do
			local r = gen.generate(0, p[1], p[2])
			for y0 = 0, r.height - 1, sectionHeight do
				local y1 = y0 + sectionHeight
				for _, hide in { true, false } do
					if GreedyMesher.isTrivial(y0, y1, r.solidBelow, r.emptyAbove, hide) then
						local _, count = GreedyMesher.mesh(r.data, r.height, y0, y1, hide)
						t.eq(count, 0, "trivial section produced boxes")
					else
						total += verify(r.data, r.height, y0, y1, hide)
					end
				end
			end
		end
		t.ok(total > 0)
	end)

	t.test("LOD chunks mesh correctly as a whole column", function()
		local gen = TerrainGenerator.new(4242)
		for level = 1, 4 do
			local r = gen.generate(level, 1, 2)
			verify(r.data, r.height, 0, r.height, true)
		end
	end)
end
