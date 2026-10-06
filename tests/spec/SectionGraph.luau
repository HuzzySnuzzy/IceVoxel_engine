--[[
	The cave visibility graph (World/SectionGraph): per-section face connectivity against a plain
	per-cell flood fill (random sections and generated chunks), the section value, the search from
	the camera (tunnels, the never-step-back rule, reach, budget, pending chunks, no leaks into the
	sky, dug tunnels), cap masks and the hysteresis tracker.
]]

return function(t, shared, require)
	local Config = require(shared.Config)
	local Blocks = require(shared.Blocks)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Coords = require(shared.World.Coords)
	local SectionGraph = require(shared.World.SectionGraph)
	local Caves = require(shared.Generation.Caves)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)

	local SIZE = Config.ChunkSize
	local SECTION = Config.SectionHeight
	local SECTIONS = SectionGraph.SECTIONS
	local STONE = Blocks.id.Stone
	local AIR = Blocks.AIR
	local CAVE_AIR = Blocks.CAVE_AIR
	local GLASS = Blocks.id.Glass
	local TWIN = -1
	for id = 0, Blocks.count - 1 do
		if buffer.readu8(Blocks.caveTwinLut, id) == 1 then
			TWIN = id
			break
		end
	end
	assert(TWIN >= 0, "no cave twin block")

	--[[ Reference: a per-cell flood fill (6-connected) of one section ]]

	local DIRS = { { -1, 0, 0 }, { 1, 0, 0 }, { 0, 0, -1 }, { 0, 0, 1 }, { 0, -1, 0 }, { 0, 1, 0 } }

	local function pairMask(faces: number): number
		local m, k = 0, 0
		for a = 0, 5 do
			for b = a + 1, 5 do
				if bit32.btest(faces, bit32.lshift(1, a)) and bit32.btest(faces, bit32.lshift(1, b)) then
					m = bit32.bor(m, bit32.lshift(1, k))
				end
				k += 1
			end
		end
		return bit32.bor(m, bit32.lshift(faces, 15))
	end

	local function reference(data: buffer, height: number, s: number): (number, number, number, boolean)
		local function cell(x: number, y: number, z: number): number
			local yy = s * SECTION + y
			if yy >= height then
				return AIR
			end
			return ChunkLayout.get(data, x, yy, z)
		end
		local seen = {}
		local cave, open, sealed, anyCave = 0, 0, 0, false
		for y = 0, 15 do
			for z = 0, 15 do
				for x = 0, 15 do
					local i = (y * 16 + z) * 16 + x
					local id = cell(x, y, z)
					if seen[i] or Blocks.isOpaque(id) then
						continue
					end
					seen[i] = true
					local stack = { { x, y, z } }
					local faces, hasCave = 0, false
					while #stack > 0 do
						local c = table.remove(stack) :: { number }
						local cx, cy, cz = c[1], c[2], c[3]
						local b = cell(cx, cy, cz)
						if b == CAVE_AIR or buffer.readu8(Blocks.caveTwinLut, b) == 1 then
							hasCave = true
						end
						if cx == 0 then
							faces = bit32.bor(faces, 1)
						end
						if cx == 15 then
							faces = bit32.bor(faces, 2)
						end
						if cz == 0 then
							faces = bit32.bor(faces, 4)
						end
						if cz == 15 then
							faces = bit32.bor(faces, 8)
						end
						if cy == 0 then
							faces = bit32.bor(faces, 16)
						end
						if cy == 15 then
							faces = bit32.bor(faces, 32)
						end
						for _, d in DIRS do
							local nx, ny, nz = cx + d[1], cy + d[2], cz + d[3]
							if nx >= 0 and nx < 16 and ny >= 0 and ny < 16 and nz >= 0 and nz < 16 then
								local j = (ny * 16 + nz) * 16 + nx
								if not seen[j] and not Blocks.isOpaque(cell(nx, ny, nz)) then
									seen[j] = true
									table.insert(stack, { nx, ny, nz })
								end
							end
						end
					end
					local m = pairMask(faces)
					if hasCave then
						anyCave = true
						cave = bit32.bor(cave, m)
					else
						open = bit32.bor(open, m)
						if not bit32.btest(faces, 32) then
							sealed = bit32.bor(sealed, m)
						end
					end
				end
			end
		end
		return cave, open, sealed, anyCave
	end

	local function same(data: buffer, height: number, s: number, label: string)
		local c1, o1, s1, h1 = SectionGraph.masks(data, height, s)
		local c2, o2, s2, h2 = reference(data, height, s)
		t.eq(c1, c2, `{label}: cave mask`)
		t.eq(o1, o2, `{label}: open mask`)
		t.eq(s1, s2, `{label}: sealed mask`)
		t.eq(h1, h2, `{label}: holds caves`)
	end

	-- A deterministic pseudo-random sequence (no math.random state shared with other specs).
	local function rng(seed: number): () -> number
		local state = seed
		return function(): number
			state = (state * 1103515245 + 12345) % 2147483648
			return state / 2147483648
		end
	end

	t.test("section graph: masks match a per-cell flood fill on random sections", function()
		local random = rng(7)
		local height = 40 -- section 2 is partly above the crop (air)
		for round = 1, 24 do
			local data = ChunkLayout.create(height)
			-- Mostly rock with air of every kind, or mostly air with rock: many small pockets.
			local rock = if round % 3 == 0 then 0.35 elseif round % 3 == 1 then 0.55 else 0.7
			for i = 0, ChunkLayout.cellCount(height) - 1 do
				local r = random()
				local id
				if r < rock then
					id = STONE
				else
					local k = random()
					id = if k < 0.4 then CAVE_AIR elseif k < 0.75 then AIR elseif k < 0.85 then GLASS else TWIN
				end
				buffer.writeu16(data, i * 2, id)
			end
			for s = 0, 2 do
				same(data, height, s, `random {round} section {s}`)
			end
		end
	end)

	t.test("section graph: masks match a per-cell flood fill on generated chunks", function()
		local gen = TerrainGenerator.new(12345)
		local checked, withCaves = 0, 0
		for _, c in { { 30, -10 }, { 31, -10 }, { 200, -913 }, { -4, 6 } } do
			local r = gen.generate(0, c[1], c[2])
			for s = 0, (r.height - 1) // SECTION do
				local _, _, _, hasCave = SectionGraph.masks(r.data, r.height, s)
				same(r.data, r.height, s, `chunk {c[1]},{c[2]} section {s}`)
				checked += 1
				if hasCave then
					withCaves += 1
				end
			end
		end
		t.ok(withCaves >= 5, `only {withCaves} sections with caves checked`)
		t.ok(checked >= 50, `only {checked} sections checked`)
	end)

	t.test("section graph: values follow cave and sealed pockets, everything when buried", function()
		local cave = bit32.bor(1, bit32.lshift(3, 15)) -- -X / +X connected
		local open = bit32.lshift(0x20 + 0x10, 15) -- touches -Y / +Y (no pairs, for the test)
		local sealed = bit32.lshift(4, 15) -- touches -Z
		local v = SectionGraph.value(cave, bit32.bor(open, sealed), sealed, true, false)
		t.eq(bit32.band(v, SectionGraph.MASK), bit32.bor(cave, sealed), "followed: cave and sealed")
		t.eq(bit32.band(bit32.rshift(v, SectionGraph.PASSABLE_SHIFT), 63), 63 - 8, "passable faces")
		t.ok(bit32.btest(v, SectionGraph.CAVES), "holds caves")
		t.ok(not bit32.btest(v, SectionGraph.BURIED), "not buried")
		local b = SectionGraph.value(0, open, 0, false, true)
		t.eq(bit32.band(b, SectionGraph.MASK), open, "buried: open air is followed too")
		t.ok(bit32.btest(b, SectionGraph.BURIED) and not bit32.btest(b, SectionGraph.CAVES), "flags")
		-- Above the crop: one pocket of air touching every face, the sky: not followed.
		local c, o, sl, h = SectionGraph.masks(ChunkLayout.create(16), 16, 3)
		t.eq(c, 0, "no cave above the crop")
		t.eq(o, SectionGraph.FULL, "open everywhere above the crop")
		t.eq(sl, 0, "the sky is not sealed")
		t.ok(not h, "no cave cells")
		t.ok(SectionGraph.connected(SectionGraph.FULL, 0, 5), "connected")
		t.ok(SectionGraph.connected(cave, 0, 1) and not SectionGraph.connected(cave, 0, 2), "pairs")
		t.ok(SectionGraph.connected(cave, 1, 1) and not SectionGraph.connected(cave, 2, 2), "faces")
	end)

	t.test("section graph: build marks buried sections, refresh keeps them", function()
		local height = 64
		local data = ChunkLayout.create(height)
		for i = 0, ChunkLayout.cellCount(height) - 1 do
			buffer.writeu16(data, i * 2, STONE)
		end
		-- A cave tunnel along X in section 1, and the bury line at 40 (sections 0 and 1 buried).
		for x = 0, 15 do
			ChunkLayout.set(data, x, 20, 8, CAVE_AIR)
		end
		local graph = SectionGraph.build(data, height, 40, { 1 })
		t.eq(buffer.len(graph), SectionGraph.BYTES, "one u32 per section")
		t.eq(SectionGraph.get(graph, 0), SectionGraph.BURIED, "section 0: buried rock")
		local v1 = SectionGraph.get(graph, 1)
		t.ok(bit32.btest(v1, SectionGraph.BURIED) and bit32.btest(v1, SectionGraph.CAVES), "section 1 flags")
		t.ok(SectionGraph.connected(v1, 0, 1), "the tunnel connects -X and +X")
		t.eq(SectionGraph.get(graph, 2), 0, "section 2 not buried, not computed")
		-- A player digs a tunnel (air) along Z through buried section 0: followed after a refresh.
		for z = 0, 15 do
			ChunkLayout.set(data, 3, 5, z, AIR)
		end
		SectionGraph.refresh(graph, data, height, { 0 })
		local v0 = SectionGraph.get(graph, 0)
		t.ok(bit32.btest(v0, SectionGraph.BURIED), "still buried")
		t.ok(SectionGraph.connected(v0, 2, 3), "dug tunnel followed in a buried section")
		-- The same tunnel in section 2 (not buried, sealed from above): followed too.
		for z = 0, 15 do
			ChunkLayout.set(data, 3, 37, z, AIR)
		end
		SectionGraph.refresh(graph, data, height, { 2 })
		t.ok(SectionGraph.connected(SectionGraph.get(graph, 2), 2, 3), "sealed tunnel followed")
		-- Open it to the sky (a shaft up to the crop): no longer followed.
		for y = 38, 47 do
			ChunkLayout.set(data, 3, y, 4, AIR)
		end
		for y = 48, height - 1 do
			for z = 0, 15 do
				for x = 0, 15 do
					ChunkLayout.set(data, x, y, z, AIR)
				end
			end
		end
		SectionGraph.refresh(graph, data, height, { 2 })
		local v2 = SectionGraph.get(graph, 2)
		t.ok(not SectionGraph.connected(v2, 2, 3), "a tunnel open to the sky is not followed")
		t.ok(bit32.btest(bit32.rshift(v2, SectionGraph.PASSABLE_SHIFT), 4), "but it is passable")
	end)

	t.test("section graph: carved sections hold every cave cell", function()
		local gen = TerrainGenerator.new(12345)
		for _, c in { { 30, -10 }, { 200, -913 } } do
			local r = gen.generate(0, c[1], c[2])
			local list = SectionGraph.carvedSections(r.carved, Caves.CELL_Y, { 63 })
			local set = {}
			for i, s in list do
				set[s] = true
				t.ok(i == 1 or list[i - 1] < s, "ascending")
			end
			t.ok(set[63], "extra sections included")
			local any = false
			for s = 0, (r.height - 1) // SECTION do
				local _, _, _, hasCave = SectionGraph.masks(r.data, r.height, s)
				if hasCave then
					any = true
					t.ok(set[s], `chunk {c[1]},{c[2]}: section {s} has caves but was not listed`)
				end
			end
			t.ok(any, "a chunk with caves")
		end
		t.eq(#SectionGraph.carvedSections(nil, Caves.CELL_Y), 0, "no lattice, no sections")
	end)

	-- The graph a worker builds for a fresh chunk: the generator's lattice as a hint.
	local function workerGraph(r: any, cx: number, cz: number, hinted: boolean): buffer
		local exact: { [number]: boolean } = {}
		local extra = {}
		if r.structureSpan then
			for s = r.structureSpan[1] // SECTION, r.structureSpan[2] // SECTION do
				exact[s] = true
				table.insert(extra, s)
			end
		end
		local list = SectionGraph.carvedSections(r.carved, Caves.CELL_Y, extra)
		local hint: SectionGraph.Hint? = if hinted
			then {
				carved = r.carved,
				cellXZ = Caves.CELL_XZ,
				cellY = Caves.CELL_Y,
				originX = cx * SIZE,
				originZ = cz * SIZE,
				surface = r.surface,
				exact = exact,
			}
			else nil
		return SectionGraph.build(r.data, r.height, r.solidBelow, list, hint)
	end

	t.test("section graph: the generator's lattice gives the same graph as reading every cell", function()
		local checked = 0
		for _, seed in { 12345, 777 } do
			local gen = TerrainGenerator.new(seed)
			-- Hills, mountains (caves under steep ground), the Underlands, and chunks with structures.
			local chunks = { { 30, -10 }, { 31, -9 }, { 200, -913 }, { 199, -913 }, { 1004, 704 }, { -4, 6 } }
			for i = 1, 40 do
				table.insert(chunks, { (i * 37) % 97 - 48, (i * 53) % 89 - 44 })
			end
			for _, c in chunks do
				local r = gen.generate(0, c[1], c[2], nil, true)
				t.ok(r.surface ~= nil, "surface heights")
				local fast = workerGraph(r, c[1], c[2], true)
				local slow = workerGraph(r, c[1], c[2], false)
				for s = 0, SECTIONS - 1 do
					t.eq(
						SectionGraph.get(fast, s),
						SectionGraph.get(slow, s),
						`seed {seed} chunk {c[1]},{c[2]} section {s}`
					)
				end
				checked += 1
			end
		end
		t.ok(checked >= 80, "chunks checked")
	end)

	t.test("section graph: section keys", function()
		for _, c in { { 0, 0, 0 }, { -5, 7, 63 }, { 100000, -100000, 12 } } do
			local key = SectionGraph.key(c[1], c[2], c[3])
			t.eq(key, Coords.chunkKey(c[1], c[2]) * SECTIONS + c[3], "key")
			local cx, cz, s = SectionGraph.decode(key)
			t.eq(cx, c[1], "cx")
			t.eq(cz, c[2], "cz")
			t.eq(s, c[3], "s")
		end
	end)

	--[[ A small synthetic world for the search ]]

	type World = {
		chunks: { [number]: { data: buffer, height: number, bury: number } },
		set: (x: number, y: number, z: number, id: number) -> (),
		box: (x0: number, y0: number, z0: number, x1: number, y1: number, z1: number, id: number) -> (),
		lookup: SectionGraph.Lookup,
		graphs: { [number]: buffer },
		pending: { [number]: boolean },
	}

	-- Chunks -r..r around the origin, rock up to `ground` (cells), air above; buried below `bury`.
	local function world(r: number, height: number, ground: number, bury: number): World
		local chunks = {}
		for cz = -r, r do
			for cx = -r, r do
				local data = ChunkLayout.create(height)
				for y = 0, ground - 1 do
					buffer.fill(data, y * ChunkLayout.LAYER * 2, 0, ChunkLayout.LAYER * 2)
					for i = 0, ChunkLayout.LAYER - 1 do
						buffer.writeu16(data, (y * ChunkLayout.LAYER + i) * 2, STONE)
					end
				end
				chunks[Coords.chunkKey(cx, cz)] = { data = data, height = height, bury = bury }
			end
		end
		local w = {} :: World
		w.chunks = chunks
		w.graphs = {}
		w.pending = {}
		function w.set(x: number, y: number, z: number, id: number)
			local c = chunks[Coords.chunkKey(x // SIZE, z // SIZE)]
			if c then
				ChunkLayout.set(c.data, x % SIZE, y, z % SIZE, id)
			end
		end
		function w.box(x0: number, y0: number, z0: number, x1: number, y1: number, z1: number, id: number)
			for y = y0, y1 do
				for z = z0, z1 do
					for x = x0, x1 do
						w.set(x, y, z, id)
					end
				end
			end
		end
		function w.lookup(cx: number, cz: number): (buffer | false)?
			local key = Coords.chunkKey(cx, cz)
			if w.pending[key] then
				return false
			end
			local c = chunks[key]
			if c == nil then
				return nil
			end
			local g = w.graphs[key]
			if g == nil then
				local all = {}
				for s = 0, c.height // SECTION - 1 do
					table.insert(all, s)
				end
				g = SectionGraph.build(c.data, c.height, c.bury, all)
				w.graphs[key] = g
			end
			return g
		end
		return w
	end

	local function reached(result: SectionGraph.Result, cx: number, cz: number, s: number): boolean
		return result.reached[SectionGraph.key(cx, cz, s)] ~= nil
	end

	t.test("section graph search: follows a tunnel, stops at rock, reach and budget", function()
		local w = world(4, 64, 60, 60)
		-- A cave tunnel along +X at y 20, z 8, from x 8 to the far end; a side cave in chunk (0, 2).
		w.box(8, 20, 8, 4 * SIZE + 15, 21, 8, CAVE_AIR)
		w.box(4, 20, 2 * SIZE + 4, 10, 25, 2 * SIZE + 10, CAVE_AIR)
		local r = SectionGraph.search(w.lookup, 8.5, 20.6, 8.5)
		for cx = 0, 4 do
			t.ok(reached(r, cx, 0, 1), `tunnel chunk {cx} reached`)
		end
		t.ok(not reached(r, 0, 2, 1), "a cave behind rock is not reached")
		t.ok(not reached(r, 1, 1, 1), "rock beside the tunnel is not reached")
		t.ok(not reached(r, 0, 0, 3), "nor above it")
		t.eq(r.count, 5, "five sections")
		t.ok(not r.truncated, "not truncated")
		-- Reach: section centres closer than 40 blocks.
		local near = SectionGraph.search(w.lookup, 8.5, 20.6, 8.5, { reach = 40 })
		t.ok(reached(near, 2, 0, 1) and not reached(near, 3, 0, 1), "reach")
		-- Budget: the nearest three.
		local few = SectionGraph.search(w.lookup, 8.5, 20.6, 8.5, { budget = 3 })
		t.eq(few.count, 3, "budget")
		t.ok(few.truncated, "truncated")
		t.ok(reached(few, 2, 0, 1) and not reached(few, 3, 0, 1), "nearest first")
	end)

	t.test("section graph search: walls next door are revealed, pending and missing chunks", function()
		local w = world(3, 64, 60, 60)
		-- A cave ending exactly at the chunk border x = 16: chunk 1's section is entered (its
		-- rock faces the cave) but the search goes no further.
		w.box(4, 20, 8, 15, 21, 8, CAVE_AIR)
		local r = SectionGraph.search(w.lookup, 8.5, 20.6, 8.5)
		t.ok(reached(r, 1, 0, 1), "the wall's section is revealed")
		t.ok(not reached(r, 2, 0, 1), "nothing behind it")
		-- The tunnel continues into a chunk not generated yet: pending, not reached.
		w.box(16, 20, 8, 40, 21, 8, CAVE_AIR)
		w.graphs = {}
		w.pending[Coords.chunkKey(2, 0)] = true
		local p = SectionGraph.search(w.lookup, 8.5, 20.6, 8.5)
		t.ok(reached(p, 1, 0, 1), "chunk 1 reached")
		t.ok(p.pending[SectionGraph.key(2, 0, 1)], "chunk 2 pending")
		t.ok(not reached(p, 2, 0, 1), "pending is not reached")
		-- A chunk that is not full detail stops the search silently.
		w.pending = {}
		w.chunks[Coords.chunkKey(2, 0)] = nil :: any
		local n = SectionGraph.search(w.lookup, 8.5, 20.6, 8.5)
		t.ok(not reached(n, 2, 0, 1) and not n.pending[SectionGraph.key(2, 0, 1)], "no full detail chunk")
		-- Nothing at all when the camera's chunk is missing.
		local none = SectionGraph.search(w.lookup, 40.5, 20.6, 8.5)
		t.eq(none.count, 0, "camera chunk missing")
	end)

	t.test("section graph search: never steps back against its directions", function()
		local w = world(3, 64, 60, 60)
		-- U-turn: +X from the camera to chunk 2, +Z into chunk (2, 1), then back -X to chunk (0, 1).
		w.box(8, 20, 8, 2 * SIZE + 8, 21, 8, CAVE_AIR)
		w.box(2 * SIZE + 8, 20, 8, 2 * SIZE + 8, 21, SIZE + 8, CAVE_AIR)
		w.box(8, 20, SIZE + 8, 2 * SIZE + 8, 21, SIZE + 8, CAVE_AIR)
		local r = SectionGraph.search(w.lookup, 8.5, 20.6, 8.5)
		t.ok(reached(r, 2, 0, 1) and reached(r, 2, 1, 1), "out and across")
		t.ok(not reached(r, 1, 1, 1), "not back: behind the rock between the legs")
	end)

	t.test("section graph search: a cave mouth does not leak into the sky; dug tunnels lead on", function()
		local w = world(3, 96, 56, 48)
		-- A cave under ground level 56 (sections 0-3; 0-2 buried), opened to the sky by a dug
		-- shaft at x 8.
		w.box(4, 20, 4, 12, 23, 12, CAVE_AIR)
		w.box(8, 24, 8, 8, 55, 8, AIR)
		local r = SectionGraph.search(w.lookup, 8.5, 20.6, 8.5)
		t.ok(reached(r, 0, 0, 2), "up the shaft through buried section 2")
		t.ok(reached(r, 0, 0, 3), "the section where it meets the sky is revealed")
		t.ok(not reached(r, 0, 0, 4) and not reached(r, 1, 0, 3) and not reached(r, -1, 0, 3), "no further")
		t.eq(r.count, 3, "three sections")
		-- Not buried, the shaft (open to the sky) is not followed at all.
		local high = world(3, 96, 56, 32)
		high.box(4, 20, 4, 12, 23, 12, CAVE_AIR)
		high.box(8, 24, 8, 8, 55, 8, AIR)
		local h = SectionGraph.search(high.lookup, 8.5, 20.6, 8.5)
		t.ok(reached(h, 0, 0, 2) and not reached(h, 0, 0, 3), "an open shaft is entered, not followed")
		-- A tunnel dug from the cave to another cave three chunks away (air, buried section 1).
		w.box(12, 21, 8, 3 * SIZE + 4, 21, 8, AIR)
		w.box(3 * SIZE + 4, 18, 4, 3 * SIZE + 10, 25, 12, CAVE_AIR)
		w.graphs = {}
		local d = SectionGraph.search(w.lookup, 8.5, 20.6, 8.5)
		t.ok(reached(d, 3, 0, 1), "the far cave through the dug tunnel")
	end)

	t.test("section graph search: a camera by a section corner sees into its neighbours", function()
		local w = world(3, 64, 60, 60)
		-- The camera is in a pocket at the +X / +Z corner of its section; caves start just across
		-- each face and run on away from it.
		w.box(13, 20, 13, 15, 21, 15, CAVE_AIR)
		w.box(16, 20, 13, 40, 21, 13, CAVE_AIR)
		w.box(13, 20, 16, 13, 21, 40, CAVE_AIR)
		local r = SectionGraph.search(w.lookup, 14.5, 20.6, 14.5)
		t.ok(reached(r, 2, 0, 1), "along +X")
		t.ok(reached(r, 0, 2, 1), "along +Z")
	end)

	t.test("section graph: cap masks, neighbourhoods, sections of a chunk", function()
		local revealed = {
			[SectionGraph.key(0, 0, 5)] = true,
			[SectionGraph.key(1, 0, 5)] = true,
			[SectionGraph.key(0, 0, 6)] = true,
		}
		local function full(cx: number, _cz: number): boolean
			return cx >= 0
		end
		-- -X: not full detail; +X revealed; -Z / +Z hidden; below hidden; above revealed.
		t.eq(SectionGraph.capMask(revealed, 0, 0, 5, full), 1 + 4 + 8 + 16, "cap mask")
		t.eq(SectionGraph.capMask(revealed, 0, 0, 6, full), 1 + 2 + 4 + 8 + 32, "cap mask above")
		t.eq(SectionGraph.capMask({}, 0, 0, 0, full), 1 + 2 + 4 + 8 + 32, "nothing below the world")
		local n = SectionGraph.neighbourhood({ SectionGraph.key(0, 0, 5) })
		local count = 0
		for _ in n do
			count += 1
		end
		t.eq(count, 7, "a section and its six neighbours")
		local top = SectionGraph.neighbourhood({ SectionGraph.key(0, 0, SECTIONS - 1) })
		count = 0
		for _ in top do
			count += 1
		end
		t.eq(count, 6, "none above the top")
		local list = SectionGraph.sectionsOf(revealed, 0, 0)
		t.eq(#list, 2, "two sections")
		t.eq(list[1], 5, "ascending")
		t.eq(list[2], 6, "ascending")
	end)

	t.test("section graph tracker: hides a section after it stayed unreachable", function()
		local tracker = SectionGraph.tracker(2, true)
		local a, b, c = SectionGraph.key(0, 0, 1), SectionGraph.key(1, 0, 1), SectionGraph.key(2, 0, 1)
		local function result(keys: { number }, pending: { number }?): SectionGraph.Result
			local reached, p = {}, {}
			for _, k in keys do
				reached[k] = 1
			end
			for _, k in pending or {} do
				p[k] = true
			end
			return { reached = reached, pending = p, count = #keys, truncated = false }
		end
		local added, removed = tracker:update(result({ a, b }, { c }), 0)
		t.eq(#added, 3, "revealed with the pending one")
		t.eq(#removed, 0, "nothing hidden")
		added, removed = tracker:update(result({ a }), 1.5)
		t.eq(#added + #removed, 0, "kept while unreachable for less than 2 s")
		t.ok(tracker.revealed[b] and tracker.revealed[c], "still revealed")
		added, removed = tracker:update(result({ a }), 2.5)
		t.eq(#removed, 2, "hidden after 2 s")
		t.ok(tracker.revealed[a] and not tracker.revealed[b], "a stays")
		added, removed = tracker:update(result({ a, b }), 2.6)
		t.eq(#added, 1, "b back at once")
		removed = tracker:reset()
		t.eq(#removed, 2, "reset hides everything")
		t.eq(next(tracker.revealed), nil, "empty")
		local plain = SectionGraph.tracker(2)
		added = plain:update(result({ a }, { c }), 0)
		t.eq(#added, 1, "pending left out by default")
	end)
end
