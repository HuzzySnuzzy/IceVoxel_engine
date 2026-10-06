--[[
	Generated lava (Generation/Lava): Minecraft 1.20.1's lake shape (LakeFeature), lava below
	Config.Caves.LavaLevel (aquifers: CaveLava in the caves, Lava in surface caves dug that deep),
	underground lakes sunk into cave floors (CaveLava, decided from the chunk's own blocks, never in
	the neighbours' padding) and rare surface lakes (ordinary Lava, decided from the full detail
	terrain: not in snowy or wet biomes, never by water, a deep cave, a structure or the spawn;
	point-sampled at LOD). Every generated lava cell is held in; the padding equals the
	neighbouring cores; hidden caves draw nothing of the lava seas; the cost.
]]
return function(t, shared, require)
	local Config = require(shared.Config)
	local Blocks = require(shared.Blocks)
	local Biomes = require(shared.Biomes)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Hash = require(shared.Util.Hash)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)
	local Lava = require(shared.Generation.Lava)
	local Caves = require(shared.Generation.Caves)
	local Ores = require(shared.Generation.Ores)
	local GreedyMesher = require(shared.Meshing.GreedyMesher)
	local SectionGraph = require(shared.World.SectionGraph)

	local SIZE = ChunkLayout.SIZE
	local LAYER = ChunkLayout.LAYER
	local SEED = 12345
	local SECTION = Config.SectionHeight
	local LEVEL = Config.Caves.LavaLevel
	local B = Blocks.id
	local AIR, CAVE_AIR = Blocks.AIR, Blocks.CAVE_AIR
	local LAVA, CAVE_LAVA, STONE = B.Lava, B.CaveLava, B.Stone
	local gen = TerrainGenerator.new(SEED)

	local isLava: { [number]: boolean } = {}
	local isFluid: { [number]: boolean } = {}
	local isOpaque: { [number]: boolean } = {}
	local isLog: { [number]: boolean } = {}
	for id = 0, Blocks.count - 1 do
		local def = Blocks.get(id)
		isFluid[id] = def.fluid ~= nil
		isLava[id] = def.fluid ~= nil and def.fluid.group == "Lava"
		isOpaque[id] = Blocks.isOpaque(id)
		isLog[id] = string.find(def.name, "Log") ~= nil
	end
	-- Ores and stone varieties are only placed in each chunk's core (stone in the padding), and
	-- glow lichen in the padding may differ from the neighbour's core (tests/spec/CaveLichen).
	local rockLike: { [number]: boolean } = { [STONE] = true }
	for _, ore in Ores.FEATURES do
		rockLike[ore.block] = true
	end
	local function norm(id: number): number
		if rockLike[id] then
			return STONE
		elseif Blocks.isCaveTwin(id) and not isLava[id] and not isFluid[id] then
			return CAVE_AIR
		end
		return id
	end

	local cache: { [string]: any } = {}
	local function chunk(cx: number, cz: number): any
		local k = `{cx},{cz}`
		local r = cache[k]
		if r == nil then
			r = gen.generate(0, cx, cz)
			cache[k] = r
		end
		return r
	end
	local function blockAt(x: number, y: number, z: number): number
		local r = chunk(x // SIZE, z // SIZE)
		if y < 0 or y >= r.height then
			return if y < 0 then B.Bedrock else AIR
		end
		return ChunkLayout.get(r.data, x % SIZE, y, z % SIZE)
	end

	-- The cave visibility graph a worker builds (ChunkWorker: the lattice as a hint, sections dug
	-- below the sky line read cell by cell) against reading every cell; and every section holding
	-- cave cells or air below the sky line is listed. Returns the sections compared.
	local function graphsAgree(cx: number, cz: number): number
		local r = gen.generate(0, cx, cz, nil, true)
		local exact: { [number]: boolean } = {}
		if r.structureSpan then
			for s = r.structureSpan[1] // SECTION, r.structureSpan[2] // SECTION do
				exact[s] = true
			end
		end
		SectionGraph.dugSections(r.data, r.height, r.surface, r.solidBelow, exact)
		local extra = {}
		for s in exact do
			table.insert(extra, s)
		end
		local list = SectionGraph.carvedSections(r.carved, Caves.CELL_Y, extra)
		local hint: SectionGraph.Hint = {
			carved = r.carved,
			cellXZ = Caves.CELL_XZ,
			cellY = Caves.CELL_Y,
			originX = cx * SIZE,
			originZ = cz * SIZE,
			surface = r.surface,
			exact = exact,
		}
		local fast = SectionGraph.build(r.data, r.height, r.solidBelow, list, hint, nil, r.surface)
		local slow = SectionGraph.build(r.data, r.height, r.solidBelow, list, nil, nil, r.surface)
		local listed: { [number]: boolean } = {}
		for _, s in list do
			listed[s] = true
		end
		for s = 0, SectionGraph.SECTIONS - 1 do
			t.eq(SectionGraph.get(fast, s), SectionGraph.get(slow, s), `chunk {cx},{cz} section {s}`)
			if not listed[s] and s * SECTION < r.height then
				local cave, _, _, _, under = SectionGraph.masks(r.data, r.height, s, r.surface)
				t.eq(cave, 0, `chunk {cx},{cz}: cave cells in section {s} left out`)
				t.eq(under, 0, `chunk {cx},{cz}: air below the sky line in section {s} left out`)
			end
		end
		return #list
	end

	-- Lava cells of a chunk's core with an open side or bottom (neither opaque nor a fluid).
	local function leaks(r: any): (number, number, string?)
		local cells, open, where = 0, 0, nil
		for y = 1, r.height - 1 do
			for lz = 0, SIZE - 1 do
				for lx = 0, SIZE - 1 do
					if isLava[ChunkLayout.get(r.data, lx, y, lz)] then
						cells += 1
						for _, d in { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 }, { 0, -1, 0 } } do
							local n = ChunkLayout.getPadded(r.data, lx + d[1], y + d[2], lz + d[3])
							if not isOpaque[n] and not isFluid[n] then
								open += 1
								where = where or `{lx},{y},{lz} of chunk {r.nx},{r.nz} next to {Blocks.get(n).name}`
							end
						end
					end
				end
			end
		end
		return cells, open, where
	end

	-- Border cells of chunk (cx, cz) that disagree with its east and south neighbours.
	local function borderMismatches(cx: number, cz: number): (number, number)
		local a, east, south = chunk(cx, cz), chunk(cx + 1, cz), chunk(cx, cz + 1)
		local bad, compared = 0, 0
		local function get(r: any, px: number, y: number, pz: number): number
			if y >= r.height then
				return AIR
			end
			return norm(ChunkLayout.getPadded(r.data, px, y, pz))
		end
		for y = 1, math.max(a.height, east.height, south.height) - 1 do
			for i = 0, SIZE - 1 do
				compared += 4
				if get(a, SIZE, y, i) ~= get(east, 0, y, i) then
					bad += 1
				end
				if get(east, -1, y, i) ~= get(a, SIZE - 1, y, i) then
					bad += 1
				end
				if get(a, i, y, SIZE) ~= get(south, i, y, 0) then
					bad += 1
				end
				if get(south, i, y, -1) ~= get(a, i, y, SIZE - 1) then
					bad += 1
				end
			end
		end
		return bad, compared
	end

	-- Sample chunks with caves reaching below LavaLevel, spread over the world (generated once).
	local deep: { { number } } = {}
	do
		local rng = Hash.rng(4711)
		local tries = 0
		while #deep < 10 and tries < 300 do
			tries += 1
			local cx, cz = rng:int(-3000, 3000), rng:int(-3000, 3000)
			local r = chunk(cx, cz)
			local found = false
			for y = 1, LEVEL - 1 do
				for i = 0, LAYER - 1 do
					if buffer.readu16(r.data, (y * LAYER + i) * 2) == CAVE_LAVA then
						found = true
						break
					end
				end
				if found then
					break
				end
			end
			if found then
				table.insert(deep, { cx, cz })
			else
				cache[`{cx},{cz}`] = nil
			end
		end
	end

	--[[ The lake shape ]]

	t.test("lava: lakes have Minecraft's shape: blobs inside the box, a shell, a barrier", function()
		local halfBarrier, upperShell = 0, 0
		for k = 1, 200 do
			local shape, lava = Lava.shapeOf(Hash.rng(k))
			local again = Lava.shapeOf(Hash.rng(k))
			t.eq(buffer.tostring(again), buffer.tostring(shape), "the same draws give the same lake")
			local counted = 0
			for x = 0, Lava.BOX - 1 do
				for z = 0, Lava.BOX - 1 do
					for y = 0, Lava.LAYERS - 1 do
						local v = buffer.readu8(shape, Lava.cellIndex(x, y, z))
						local function at(dx: number, dy: number, dz: number): number
							local nx, ny, nz = x + dx, y + dy, z + dz
							if nx < 0 or nz < 0 or ny < 0 or nx >= Lava.BOX or nz >= Lava.BOX or ny >= Lava.LAYERS then
								return Lava.OUT
							end
							return buffer.readu8(shape, Lava.cellIndex(nx, ny, nz))
						end
						local touches = at(1, 0, 0) == Lava.LAKE
							or at(-1, 0, 0) == Lava.LAKE
							or at(0, 1, 0) == Lava.LAKE
							or at(0, -1, 0) == Lava.LAKE
							or at(0, 0, 1) == Lava.LAKE
							or at(0, 0, -1) == Lava.LAKE
						if v == Lava.LAKE then
							t.ok(
								x >= 1 and x <= 14 and z >= 1 and z <= 14 and y >= 1 and y <= 6,
								"a blob cell outside 1..14 / 1..6"
							)
							if y < Lava.SURFACE_LAYER then
								counted += 1
							end
						else
							t.eq(v ~= Lava.OUT, touches, `shell cell {x},{y},{z} of lake {k}`)
							if v ~= Lava.OUT and y < Lava.SURFACE_LAYER then
								t.eq(v, Lava.BARRIER, "every shell cell below layer 4 is barrier")
							elseif v ~= Lava.OUT then
								upperShell += 1
								if v == Lava.BARRIER then
									halfBarrier += 1
								end
							end
						end
					end
				end
			end
			t.eq(counted, lava, "lava cells counted")
		end
		local share = halfBarrier / upperShell
		print(string.format("    shell cells from layer 4 up turning into stone: %.1f%%", share * 100))
		t.ok(share > 0.45 and share < 0.55, "half of the upper shell (one nextInt(2) each)")
	end)

	--[[ Aquifers ]]

	t.test("lava: below LavaLevel every cave cell is CaveLava and surface caves hold Lava", function()
		t.ok(#deep >= 6, `sample chunks with caves below LavaLevel: {#deep}`)
		local sea = 0
		for _, s in deep do
			local r = chunk(s[1], s[2])
			for y = 1, LEVEL - 1 do
				for i = 0, LAYER - 1 do
					local id = buffer.readu16(r.data, (y * LAYER + i) * 2)
					t.ok(id ~= CAVE_AIR and id ~= AIR, `{Blocks.get(id).name} at y {y} of chunk {s[1]},{s[2]}`)
					if id == CAVE_LAVA then
						sea += 1
					end
				end
			end
			-- The surface of the sea is cave air (or rock) right above it.
			for i = 0, LAYER - 1 do
				local above = buffer.readu16(r.data, (LEVEL * LAYER + i) * 2)
				t.ok(not isLava[above] or above == CAVE_LAVA, "ordinary lava just over the sea")
			end
		end
		print(`    {sea} cells of lava sea in {#deep} chunks`)
		t.ok(sea > 1000, "lava seas")
	end)

	t.test("lava: every generated lava cell is held in by rock or fluid, beside and below", function()
		local cells, open = 0, 0
		local first: string? = nil
		for _, s in deep do
			local c, o, w = leaks(chunk(s[1], s[2]))
			cells += c
			open += o
			first = first or w
		end
		for _, lake in gen.lavaLakes(-1500, -1500, 1500, 1500) do
			for dz = 0, 1 do
				for dx = 0, 1 do
					local c, o, w = leaks(chunk((lake.x + dx * 15) // SIZE, (lake.z + dz * 15) // SIZE))
					cells += c
					open += o
					first = first or w
				end
			end
		end
		print(`    {cells} lava cells checked`)
		t.ok(cells > 2000, "lava cells")
		t.eq(open, 0, `lava cells with an open side: {first}`)
	end)

	t.test("lava: the Underlands' floor is a lava sea, which costs nothing while caves are hidden", function()
		-- Under the highest peaks near the origin the Underlands reach down to Caves.MinY.
		local bx, bz, best = 0, 0, 0
		for z = -3000, 3000, 128 do
			for x = 2000, 6000, 128 do
				local h = gen.column(x, z)
				if h > best then
					best, bx, bz = h, x, z
				end
			end
		end
		t.ok(best > 760, `highest column {best}`)
		local cx, cz = bx // SIZE, bz // SIZE
		local r = chunk(cx, cz)
		local sea = 0
		for y = 1, LEVEL - 1 do
			for i = 0, LAYER - 1 do
				if buffer.readu16(r.data, (y * LAYER + i) * 2) == CAVE_LAVA then
					sea += 1
				end
			end
		end
		print(`    Underlands chunk {cx},{cz} under {best}: {sea} cells of lava sea`)
		t.ok(sea > 1000, "a lava sea on the Underlands' floor")
		-- Hidden, the sea meshes exactly like the cave air it replaced.
		local air = buffer.create(buffer.len(r.data))
		buffer.copy(air, 0, r.data)
		for y = 1, LEVEL - 1 do
			for i = 0, LAYER - 1 do
				if buffer.readu16(air, (y * LAYER + i) * 2) == CAVE_LAVA then
					buffer.writeu16(air, (y * LAYER + i) * 2, CAVE_AIR)
				end
			end
		end
		local section = Config.SectionHeight
		local m1, n1 = GreedyMesher.mesh(r.data, r.height, 0, section, true)
		local m2, n2 = GreedyMesher.mesh(air, r.height, 0, section, true)
		t.eq(n1, n2, "boxes, hidden")
		t.eq(buffer.tostring(m1), buffer.tostring(m2), "the same boxes")
		local _, shown = GreedyMesher.mesh(r.data, r.height, 0, section, false)
		print(`    its lowest section: {n1} boxes hidden, {shown} revealed`)
		local bad = borderMismatches(cx, cz)
		t.eq(bad, 0, "the sea in the padding equals the neighbouring cores")
	end)

	--[[ Underground lakes ]]

	-- Chunks with an underground lake among random chunks (cached), and how many had caves.
	local underground: { { number } } = {}
	local caveRich = 0
	do
		local rng = Hash.rng(99)
		for _ = 1, 160 do
			local cx, cz = rng:int(-500, 500), rng:int(-500, 500)
			local r = chunk(cx, cz)
			local caves, lake = 0, false
			for y = 1, r.height - 1 do
				for i = 0, LAYER - 1 do
					local id = buffer.readu16(r.data, (y * LAYER + i) * 2)
					if id == CAVE_AIR or id == CAVE_LAVA then
						caves += 1
						lake = lake or (id == CAVE_LAVA and y >= LEVEL)
					end
				end
			end
			if caves >= 2000 then
				caveRich += 1
			end
			if lake then
				table.insert(underground, { cx, cz })
			else
				cache[`{cx},{cz}`] = nil
			end
		end
	end

	t.test("underground lakes: sunk into cave floors 30+ blocks down, in the chunk's core", function()
		t.ok(#underground >= caveRich / 8, "about one in a few chunks with caves")
		local shallowest = math.huge
		for _, s in underground do
			local r = chunk(s[1], s[2])
			local x0, y0, z0, x1, y1, z1 = math.huge, math.huge, math.huge, -1, -1, -1
			for y = LEVEL, r.height - 1 do
				for lz = 0, SIZE - 1 do
					for lx = 0, SIZE - 1 do
						if ChunkLayout.get(r.data, lx, y, lz) == CAVE_LAVA then
							x0, y0, z0 = math.min(x0, lx), math.min(y0, y), math.min(z0, lz)
							x1, y1, z1 = math.max(x1, lx), math.max(y1, y), math.max(z1, lz)
							-- (The floor is Depth below the surface where it was found; the rest of
							-- the box keeps the caves' margin under every column.)
							local h = gen.column(s[1] * SIZE + lx, s[2] * SIZE + lz)
							shallowest = math.min(shallowest, h - y)
							t.ok(h - y > Lava.LAYERS + Config.Caves.SurfaceMargin - Lava.SURFACE_LAYER, "too shallow")
						end
					end
				end
			end
			-- One lake: its lava within the core's cells 1..14 and three layers.
			t.ok(x0 >= 1 and z0 >= 1 and x1 <= SIZE - 2 and z1 <= SIZE - 2, "the lake keeps off the core's edge")
			t.ok(y1 - y0 <= 2, `lava over {y1 - y0 + 1} layers`)
			-- Lava's top layer: cave air (the bowl) or rock above, the cave over it.
			local bowl = 0
			for lz = 0, SIZE - 1 do
				for lx = 0, SIZE - 1 do
					if ChunkLayout.get(r.data, lx, y1, lz) == CAVE_LAVA then
						local above = ChunkLayout.get(r.data, lx, y1 + 1, lz)
						local cave = above == CAVE_AIR or (Blocks.isCaveTwin(above) and not isFluid[above])
						t.ok(cave or isOpaque[above], `{Blocks.get(above).name} on the lake`)
						if cave then
							bowl += 1
						end
					end
				end
			end
			t.ok(bowl > 0, "the lake opens into its bowl")
			local _, open, where = leaks(r)
			t.eq(open, 0, `held in: {where}`)
			-- The cave lattice knows the lake's cells (World/SectionGraph reads them).
			local carved = r.carved
			t.ok(carved ~= nil, "a lattice")
			if carved then
				for y = y0, y1 + 3 do
					for lz = 0, SIZE - 1 do
						for lx = 0, SIZE - 1 do
							local id = ChunkLayout.get(r.data, lx, y, lz)
							if id == CAVE_LAVA or id == CAVE_AIR then
								local wx, wz = s[1] * SIZE + lx, s[2] * SIZE + lz
								local gx = (wx - carved.x) // Caves.CELL_XZ
								local gy = (y - carved.y) // Caves.CELL_Y
								local gz = (wz - carved.z) // Caves.CELL_XZ
								t.ok(gy < carved.ny, "lattice tall enough")
								if gy < carved.ny then
									local flag = buffer.readu8(carved.flags, (gy * carved.nz + gz) * carved.nx + gx)
									t.ok(flag ~= 0, `lake cell {lx},{y},{lz} in an unmarked lattice cell`)
								end
							end
						end
					end
				end
			end
		end
		print(
			`    {#underground} underground lakes in {caveRich} chunks with 2000+ cave cells, lava {shallowest}+ blocks deep`
		)
	end)

	t.test("underground lakes: never in the neighbours' padding (only the barrier, rock either way)", function()
		local bad, compared = 0, 0
		for k = 1, math.min(#underground, 6) do
			local s = underground[k]
			for _, d in { { 0, 0 }, { -1, 0 }, { 0, -1 } } do
				local b, c = borderMismatches(s[1] + d[1], s[2] + d[2])
				bad += b
				compared += c
			end
		end
		t.ok(compared > 50000, `cells compared: {compared}`)
		t.eq(bad, 0, "border cells that disagree")
	end)

	--[[ Surface lakes ]]

	local surface = gen.lavaLakes(-4096, -4096, 4095, 4095)

	t.test("surface lakes: Minecraft's rarity, not in snowy or wet biomes, away from the spawn", function()
		local km2 = 8192 * 8192 / 1e6
		print(string.format("    %d surface lakes in %.0f km2 (%.2f per km2)", #surface, km2, #surface / km2))
		t.ok(#surface / km2 > 0.3 and #surface / km2 < 5, "rare")
		local sx, _, sz = gen.findSpawn()
		for _, lake in surface do
			local cx, cz = lake.x + Lava.BOX // 2, lake.z + Lava.BOX // 2
			local h, biome = gen.column(cx, cz)
			local def = Biomes.list[biome]
			t.ok(not def.frozen and def.top ~= B.Snow and def.humidity < Lava.WET, `a lake in {def.name}`)
			t.eq(lake.y, h - Lava.SURFACE_LAYER, "layer 4 at the surface height of the box's centre")
			t.ok(h > Config.SeaLevel + 1, "on dry land")
			local clearance = Config.Caves.LavaLakes.SpawnClearance
			t.ok((cx - sx) ^ 2 + (cz - sz) ^ 2 >= clearance ^ 2, "away from the spawn")
			for _, start in gen.structures(lake.x - 2, lake.z - 2, lake.x + 17, lake.z + 17) do
				for _, piece in start.pieces do
					local b = piece.box
					local near = b[1] <= lake.x + 17
						and b[4] >= lake.x - 2
						and b[3] <= lake.z + 17
						and b[6] >= lake.z - 2
					t.ok(not near, "no structure piece near")
				end
			end
		end
	end)

	t.test("surface lakes: lava, a bowl and a stone rim as generated; never by water", function()
		local checked = 0
		for k = 1, math.min(#surface, 8) do
			local lake = surface[k]
			local lava, stone, water = 0, 0, 0
			for x = lake.x - 1, lake.x + Lava.BOX do
				for z = lake.z - 1, lake.z + Lava.BOX do
					for y = lake.y - 1, lake.y + Lava.LAYERS do
						local id = blockAt(x, y, z)
						local lx, ly, lz = x - lake.x, y - lake.y, z - lake.z
						local v = Lava.OUT
						if lx >= 0 and lz >= 0 and ly >= 0 and lx < Lava.BOX and lz < Lava.BOX and ly < Lava.LAYERS then
							v = buffer.readu8(lake.shape, Lava.cellIndex(lx, ly, lz))
						end
						if v == Lava.LAKE and ly < Lava.SURFACE_LAYER then
							t.eq(id, LAVA, `lava at {x},{y},{z}`)
							lava += 1
						elseif v == Lava.LAKE then
							t.ok(not isOpaque[id], "the bowl is dug out")
						elseif id == STONE and v == Lava.BARRIER then
							stone += 1
						end
						if isFluid[id] and not isLava[id] then
							water += 1
						end
					end
				end
			end
			t.eq(lava, lake.cells, "every lava cell of the shape")
			t.ok(stone > 0, "a stone barrier")
			t.eq(water, 0, "no other fluid around the lake")
			checked += 1
		end
		t.ok(checked >= 4, `lakes checked: {checked}`)
	end)

	t.test("surface lakes: decided from the terrain alone; padding equals the neighbouring cores", function()
		-- A fresh generator asked about small areas in another order finds the same lakes.
		local fresh = TerrainGenerator.new(SEED)
		local seen: { [string]: boolean } = {}
		for k = #surface, 1, -1 do
			local lake = surface[k]
			for _, other in fresh.lavaLakes(lake.x + 3, lake.z + 3, lake.x + 4, lake.z + 4) do
				seen[`{other.x},{other.y},{other.z},{buffer.tostring(other.shape)}`] = true
			end
		end
		for _, lake in surface do
			t.ok(seen[`{lake.x},{lake.y},{lake.z},{buffer.tostring(lake.shape)}`], "the same lake")
		end
		local bad, compared = 0, 0
		for k = 1, math.min(#surface, 3) do
			local lake = surface[k]
			for cz = lake.z // SIZE - 1, (lake.z + 15) // SIZE do
				for cx = lake.x // SIZE - 1, (lake.x + 15) // SIZE do
					local b, c = borderMismatches(cx, cz)
					bad += b
					compared += c
				end
			end
		end
		t.ok(compared > 50000, `cells compared: {compared}`)
		t.eq(bad, 0, "border cells that disagree")
	end)

	t.test("surface lakes: no surface cave or tree in them; far nodes (levels 1-2) show the lava", function()
		for k = 1, math.min(#surface, 6) do
			local lake = surface[k]
			local m = Lava.PROTECT
			for x = lake.x - m, lake.x + Lava.BOX - 1 + m do
				for z = lake.z - m, lake.z + Lava.BOX - 1 + m do
					local h = gen.column(x, z)
					for y = lake.y - 2, h + 8 do
						local id = blockAt(x, y, z)
						t.ok(not isLog[id], "a tree in a lava lake")
						if id == AIR and y < h then
							-- Only the lake's bowl is dug below the ground.
							local lx, ly, lz = x - lake.x, y - lake.y, z - lake.z
							local inBox = lx >= 0
								and lz >= 0
								and lx < Lava.BOX
								and lz < Lava.BOX
								and ly >= 0
								and ly < Lava.LAYERS
							t.ok(
								inBox and buffer.readu8(lake.shape, Lava.cellIndex(lx, ly, lz)) == Lava.LAKE,
								`air dug at {x},{y},{z} under the ground ({h})`
							)
						end
					end
				end
			end
			for level = 1, Config.StructureMaxLevel do
				local span = SIZE * 2 ^ level
				local cx, cz = lake.x + 8, lake.z + 8
				local r = gen.generate(level, cx // span, cz // span)
				local found = 0
				for i = 0, buffer.len(r.data) // 2 - 1 do
					if buffer.readu16(r.data, i * 2) == LAVA then
						found += 1
					end
				end
				t.ok(found > 0, `level {level} shows lake {k}`)
				local cull = Blocks.cullLutHiddenCaves
				for y = 0, r.solidBelow - 1 do
					for i = 0, LAYER - 1 do
						t.ok(buffer.readu8(cull, buffer.readu16(r.data, (y * LAYER + i) * 2)) == 1, "solidBelow")
					end
				end
			end
		end
	end)

	t.test("lava: the cave lattice and the sky line describe the lava (cave visibility graphs)", function()
		local sections = 0
		for k = 1, 3 do
			sections += graphsAgree(deep[k][1], deep[k][2])
			if underground[k] then
				sections += graphsAgree(underground[k][1], underground[k][2])
			end
			local lake = surface[k]
			if lake then
				sections += graphsAgree((lake.x + 8) // SIZE, (lake.z + 8) // SIZE)
			end
		end
		t.ok(sections > 20, `sections compared: {sections}`)
	end)

	t.test("lava: solidBelow and emptyAbove hold over every kind of lava", function()
		local cull = Blocks.cullLutHiddenCaves
		local list: { { number } } = {}
		for k = 1, 3 do
			table.insert(list, deep[k])
			if underground[k] then
				table.insert(list, underground[k])
			end
			local lake = surface[k]
			if lake then
				table.insert(list, { (lake.x + 8) // SIZE, (lake.z + 8) // SIZE })
			end
		end
		for _, s in list do
			local r = chunk(s[1], s[2])
			t.ok(r.emptyAbove < r.height, "the crop leaves air on top")
			for y = 0, r.height - 1 do
				for i = 0, LAYER - 1 do
					local id = buffer.readu16(r.data, (y * LAYER + i) * 2)
					if y < r.solidBelow then
						t.ok(buffer.readu8(cull, id) == 1, `below solidBelow: {Blocks.get(id).name} at y {y}`)
					end
					if y >= r.emptyAbove then
						t.eq(id, AIR, "above emptyAbove")
					end
				end
			end
		end
	end)

	t.test("lava: costs little generation time", function()
		-- The passes alone on the sample chunks' data (with lava switched off while generating).
		local was = { Config.Caves.LavaLevel, Config.Caves.LavaLakes.Underground.Enabled }
		Config.Caves.LavaLevel, Config.Caves.LavaLakes.Underground.Enabled = 0, false
		local plain = TerrainGenerator.new(SEED)
		local samples: { { number } } = {}
		for _, s in deep do
			table.insert(samples, s)
		end
		for _, s in underground do
			table.insert(samples, s)
		end
		local chunks = {}
		local generation = 0
		for _, s in samples do
			local t0 = os.clock()
			local r = plain.generate(0, s[1], s[2])
			generation += os.clock() - t0
			table.insert(chunks, r)
		end
		Config.Caves.LavaLevel, Config.Caves.LavaLakes.Underground.Enabled = was[1], was[2]
		local lava = Lava.new(SEED, {
			height = function(): number
				return 0
			end,
			biome = function(): number
				return 1
			end,
			free = function(): boolean
				return true
			end,
			spawn = function(): (number, number)
				return 0, 0
			end,
		})
		local spent, lakes = 0, 0
		for k, r in chunks do
			local s = samples[k]
			local heights = {}
			for pz = 0, ChunkLayout.PADDED - 1 do
				for px = 0, ChunkLayout.PADDED - 1 do
					heights[pz * ChunkLayout.PADDED + px + 1] = (gen.column(s[1] * SIZE + px - 1, s[2] * SIZE + pz - 1))
				end
			end
			local data = buffer.create(buffer.len(r.data))
			buffer.copy(data, 0, r.data)
			local t0 = os.clock()
			Lava.aquifer(data, r.height, 0)
			local lake = lava.underground(data, r.height, s[1], s[2], heights, r.carved, nil)
			spent += os.clock() - t0
			if lake then
				lakes += 1
			end
		end
		print(
			string.format(
				"    %d chunks with deep caves or lakes: aquifer and underground lakes %.3f ms, the chunk %.2f ms",
				#chunks,
				spent / #chunks * 1000,
				generation / #chunks * 1000
			)
		)
		t.ok(lakes > 0, "lakes were tried")
		t.ok(spent < 0.1 * generation, "lava costs less than a tenth of generation")
	end)
end
