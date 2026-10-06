--[[
	Water lakes and puddles (Generation/Lakes): Minecraft's lake_water (the lava lakes' shape, water
	below layer 4, the bowl dug out above, ice on frozen lakes, the soil under the water turned into
	the lake's floor, grass grown back around the rim) and shallow puddles in natural dips, both
	decided from the full detail terrain alone. Every water cell is a source held in beside and
	below; the padding equals the neighbouring cores; no tree or plant stands in or on the water;
	far nodes show the lakes and not the puddles; the map paints both; the densities per km² and
	by biome; solidBelow / emptyAbove and the cave visibility graphs; the cost.
]]
return function(t, shared, require)
	local Config = require(shared.Config)
	local Blocks = require(shared.Blocks)
	local Biomes = require(shared.Biomes)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)
	local Lakes = require(shared.Generation.Lakes)
	local Lava = require(shared.Generation.Lava)
	local Caves = require(shared.Generation.Caves)
	local Ores = require(shared.Generation.Ores)
	local SectionGraph = require(shared.World.SectionGraph)
	local MapPainter = require(shared.Map.MapPainter)

	local SIZE = ChunkLayout.SIZE
	local LAYER = ChunkLayout.LAYER
	local SEA = Config.SeaLevel
	local SECTION = Config.SectionHeight
	local SEED = 12345
	local B = Blocks.id
	local AIR, CAVE_AIR = Blocks.AIR, Blocks.CAVE_AIR
	local WATER = Blocks.fluidId("Water", 0)
	local ICE, STONE = B.Ice, B.Stone
	local gen = TerrainGenerator.new(SEED)

	local isWater: { [number]: boolean } = {}
	local isFluid: { [number]: boolean } = {}
	local isOpaque: { [number]: boolean } = {}
	local isWoody: { [number]: boolean } = {}
	for id = 0, Blocks.count - 1 do
		local def = Blocks.get(id)
		isFluid[id] = def.fluid ~= nil
		isWater[id] = def.fluid ~= nil and def.fluid.group == "Water"
		isOpaque[id] = Blocks.isOpaque(id)
		isWoody[id] = string.find(def.name, "Log") ~= nil
			or string.find(def.name, "Leaves") ~= nil
			or def.name == "Cactus"
			or Blocks.isPlant(id)
	end
	local GRASSY: { [number]: boolean } = {
		[B.Grass] = true,
		[B.DryGrass] = true,
		[B.Podzol] = true,
		[B.Mycelium] = true,
		[B.Snow] = true,
	}
	-- Ores and stone varieties are only placed in each chunk's core (stone in the padding), and
	-- glow lichen in the padding may differ from the neighbour's core (tests/spec/CaveLichen).
	local rockLike: { [number]: boolean } = { [STONE] = true }
	for _, ore in Ores.FEATURES do
		rockLike[ore.block] = true
	end
	local function norm(id: number): number
		if rockLike[id] then
			return STONE
		elseif Blocks.isCaveTwin(id) and not isFluid[id] then
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
	local function shapeAt(lake: Lakes.Lake, x: number, y: number, z: number): number
		local lx, ly, lz = x - lake.x, y - lake.y, z - lake.z
		if lx < 0 or lz < 0 or ly < 0 or lx >= Lakes.BOX or lz >= Lakes.BOX or ly >= Lava.LAYERS then
			return Lava.OUT
		end
		return buffer.readu8(lake.shape, Lava.cellIndex(lx, ly, lz))
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

	-- The cave visibility graph a worker builds (the lattice as a hint, sections dug below the sky
	-- line read cell by cell) against reading every cell (as tests/spec/LavaGeneration).
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
		for s = 0, SectionGraph.SECTIONS - 1 do
			t.eq(SectionGraph.get(fast, s), SectionGraph.get(slow, s), `chunk {cx},{cz} section {s}`)
		end
		return #list
	end

	local R = 4096
	local KM2 = (2 * R) ^ 2 / 1e6
	local lakes = gen.waterLakes(-R, -R, R - 1, R - 1)
	local PR = 2048
	local PKM2 = (2 * PR) ^ 2 / 1e6
	local puddles = gen.puddles(-PR, -PR, PR - 1, PR - 1)
	-- A few lakes (a frozen one first, if any) and puddles spread over the area, for the block checks.
	local sampleLakes: { Lakes.Lake } = {}
	for _, lake in lakes do
		if lake.frozen then
			table.insert(sampleLakes, lake)
			break
		end
	end
	for k = 1, #lakes, math.max(#lakes // 6, 1) do
		if #sampleLakes < 7 and not table.find(sampleLakes, lakes[k]) then
			table.insert(sampleLakes, lakes[k])
		end
	end
	local samplePuddles: { Lakes.Puddle } = {}
	for k = 1, #puddles, math.max(#puddles // 40, 1) do
		table.insert(samplePuddles, puddles[k])
	end
	-- Chunks (cx, cz) under the sample lakes and puddles.
	local sampleChunks: { { number } } = {}
	do
		local seen: { [string]: boolean } = {}
		local function add(x0: number, z0: number, x1: number, z1: number)
			for cz = z0 // SIZE, z1 // SIZE do
				for cx = x0 // SIZE, x1 // SIZE do
					if not seen[`{cx},{cz}`] then
						seen[`{cx},{cz}`] = true
						table.insert(sampleChunks, { cx, cz })
					end
				end
			end
		end
		for _, lake in sampleLakes do
			add(lake.x, lake.z, lake.x + Lakes.BOX - 1, lake.z + Lakes.BOX - 1)
		end
		for _, p in samplePuddles do
			add(p.x0, p.z0, p.x1, p.z1)
		end
	end

	--[[ Lakes ]]

	t.test("lakes: rarer than lava lakes, on dry land, away from the spawn and structures", function()
		local lava = gen.lavaLakes(-R, -R, R - 1, R - 1)
		local frozen = 0
		for _, lake in lakes do
			if lake.frozen then
				frozen += 1
			end
		end
		print(
			string.format(
				"    seed %d: %d water lakes in %.0f km2 (%.2f per km2, %d frozen); %d lava lakes (%.2f)",
				SEED,
				#lakes,
				KM2,
				#lakes / KM2,
				frozen,
				#lava,
				#lava / KM2
			)
		)
		local other = TerrainGenerator.new(777)
		local otherLakes = other.waterLakes(-R, -R, R - 1, R - 1)
		local otherLava = other.lavaLakes(-R, -R, R - 1, R - 1)
		print(
			string.format(
				"    seed 777: %d water lakes (%.2f per km2); %d lava lakes (%.2f)",
				#otherLakes,
				#otherLakes / KM2,
				#otherLava,
				#otherLava / KM2
			)
		)
		t.ok(#lakes / KM2 > 0.15 and #lakes / KM2 < 1.2, "rare")
		t.ok(#otherLakes / KM2 > 0.15 and #otherLakes / KM2 < 1.2, "rare (seed 777)")
		t.ok(#lakes + #otherLakes < #lava + #otherLava, "rarer than lava lakes")
		local sx, _, sz = gen.findSpawn()
		for _, lake in lakes do
			local cx, cz = lake.x + Lakes.BOX // 2, lake.z + Lakes.BOX // 2
			local h, biome = gen.column(cx, cz)
			local def = Biomes.list[biome]
			t.eq(lake.y, h - Lava.SURFACE_LAYER, "layer 4 at the surface height of the box's centre")
			t.ok(h > SEA + Lakes.SHORE, "on dry land")
			t.eq(lake.frozen, def.frozen == true or def.top == B.Snow, `frozen in {def.name}`)
			local clearance = Config.Lakes.SpawnClearance
			t.ok((cx - sx) ^ 2 + (cz - sz) ^ 2 >= clearance ^ 2, "away from the spawn")
			local m = Lakes.PROTECT
			local x0, z0, x1, z1 = lake.x - m, lake.z - m, lake.x + Lakes.BOX - 1 + m, lake.z + Lakes.BOX - 1 + m
			for _, start in gen.structures(x0, z0, x1, z1) do
				for _, piece in start.pieces do
					local b = piece.box
					t.ok(not (b[1] <= x1 and b[4] >= x0 and b[3] <= z1 and b[6] >= z0), "no structure piece near")
				end
			end
			t.eq(#gen.lavaLakes(x0, z0, x1, z1), 0, "no lava lake near")
			t.eq(#gen.oilWells(x0, z0, x1, z1), 0, "no oil well near")
			t.eq(#gen.waterLakes(x0, z0, x1, z1), 1, "no other water lake near")
		end
	end)

	t.test("lakes: water below layer 4, ice on frozen ones, the bowl dug, the floor, grass on the rim", function()
		t.ok(#sampleLakes >= 5, `sample lakes: {#sampleLakes}`)
		local frozenChecked, regrown, floors = 0, 0, 0
		for _, lake in sampleLakes do
			local water, ice = 0, 0
			for x = lake.x - 1, lake.x + Lakes.BOX do
				for z = lake.z - 1, lake.z + Lakes.BOX do
					local h, _, _, surface = gen.column(x, z)
					local topSoil = false
					for y = lake.y - 1, lake.y + Lava.LAYERS do
						local id = blockAt(x, y, z)
						local v = shapeAt(lake, x, y, z)
						local ly = y - lake.y
						if v == Lava.LAKE and ly < Lava.SURFACE_LAYER then
							if lake.frozen and ly == Lava.SURFACE_LAYER - 1 then
								t.eq(id, ICE, `ice on top of a frozen lake at {x},{y},{z}`)
								ice += 1
							else
								t.eq(id, WATER, `a water source at {x},{y},{z}`)
								water += 1
							end
						elseif v == Lava.LAKE then
							t.ok(not isOpaque[id] and not isFluid[id], "the bowl is dug out")
						end
						-- No grass, podzol, mycelium or snow under the water, nor beside it but as
						-- a top open to the sky (grass by the water's edge).
						if (isWater[id] or id == ICE) and y > 0 then
							for _, d in { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 }, { 0, -1, 0 } } do
								local n = blockAt(x + d[1], y + d[2], z + d[3])
								local over = blockAt(x + d[1], y + d[2] + 1, z + d[3])
								t.ok(
									not GRASSY[n] or (d[2] == 0 and not isWater[over] and over ~= ICE),
									`{Blocks.get(n).name} under or beside the water at {x},{y},{z}`
								)
								if n == lake.floor and lake.floor ~= B.Dirt then
									floors += 1
								end
							end
						end
						-- Dirt the bowl uncovered (air right above it, below the natural surface)
						-- grew the column's top back.
						if y < h - 1 and id ~= AIR and blockAt(x, y + 1, z) == AIR and GRASSY[surface] then
							t.ok(id ~= B.Dirt, `bare dirt in the bowl at {x},{y},{z}`)
							if id == surface then
								topSoil = true
							end
						end
					end
					if topSoil then
						regrown += 1
					end
				end
			end
			t.eq(water + ice, lake.cells, "every water cell of the shape")
			if lake.frozen then
				frozenChecked += 1
				t.ok(ice > 0, "a frozen lake has ice")
			end
		end
		print(
			`    {#sampleLakes} lakes checked ({frozenChecked} frozen): {regrown} bowl columns grew their top back, {floors} faces of floor block by the water`
		)
		t.ok(regrown > 0, "the rim's grass grows back")
		t.ok(floors > 0, "sand or gravel floors")
	end)

	--[[ Puddles ]]

	t.test("puddles: one block deep in a dip, a few to 20 columns, held in by the ground", function()
		local sizes = {}
		for _, p in puddles do
			t.ok(p.cells >= Config.Lakes.Puddles.Size[1] and p.cells <= Config.Lakes.Puddles.Size[2], "size")
			table.insert(sizes, p.cells)
			t.ok(p.y + 1 > SEA + Lakes.SHORE, "above the shore")
			for z = p.z0, p.z1 do
				for x = p.x0, p.x1 do
					if Lakes.inPuddle(p, x, z) then
						t.eq((gen.column(x, z)), p.y + 1, "the dip's floor is level")
						for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
							t.ok(gen.column(x + d[1], z + d[2]) >= p.y + 1, "no lower column beside a puddle")
						end
					end
				end
			end
		end
		table.sort(sizes)
		print(
			string.format(
				"    %d puddles, columns: median %d, 10%% %d, 90%% %d",
				#puddles,
				sizes[#sizes // 2 + 1],
				sizes[#sizes // 10 + 1],
				sizes[#sizes * 9 // 10 + 1]
			)
		)
		-- As generated: water in place of the top block, ground below.
		local cells = 0
		for _, p in samplePuddles do
			for z = p.z0, p.z1 do
				for x = p.x0, p.x1 do
					if Lakes.inPuddle(p, x, z) then
						t.eq(blockAt(x, p.y, z), WATER, `puddle water at {x},{p.y},{z}`)
						t.ok(isOpaque[blockAt(x, p.y - 1, z)], "ground under a puddle")
						t.ok(not isOpaque[blockAt(x, p.y + 1, z)], "open above")
						cells += 1
					end
				end
			end
		end
		t.ok(cells > 200, `puddle cells checked: {cells}`)
	end)

	t.test("puddles: noticeable in wet biomes, rare in dry ones, none in frozen ones (per km²)", function()
		local wetNames = { "Jungle", "Forest", "BirchForest", "OldGrowthTaiga", "Taiga", "MushroomFields" }
		local dryNames = { "Desert", "Savanna", "WindsweptSavanna" }
		local wetTotal, wetArea, dryTotal, dryArea = 0, 0, 0, 0
		for _, seed in { SEED, 777 } do
			local g = if seed == SEED then gen else TerrainGenerator.new(seed)
			local list = if seed == SEED then puddles else g.puddles(-PR, -PR, PR - 1, PR - 1)
			local count: { [string]: number } = {}
			for _, p in list do
				local def = Biomes.list[p.biome]
				t.ok(not def.frozen and def.top ~= B.Snow, `a puddle in {def.name}`)
				count[def.name] = (count[def.name] or 0) + 1
			end
			-- Land area per biome, on a 16 block grid.
			local area: { [string]: number } = {}
			local land = 0
			for z = -PR, PR - 1, 16 do
				for x = -PR, PR - 1, 16 do
					local h, biome = g.column(x + 8, z + 8)
					if h > SEA + Lakes.SHORE then
						local name = Biomes.list[biome].name
						area[name] = (area[name] or 0) + 256 / 1e6
						land += 256 / 1e6
					end
				end
			end
			print(
				string.format(
					"    seed %d: %d puddles in %.1f km2 (%.1f per km2, %.1f per km2 of land)",
					seed,
					#list,
					PKM2,
					#list / PKM2,
					#list / land
				)
			)
			local names = {}
			for name in area do
				table.insert(names, name)
			end
			table.sort(names, function(a, b)
				return area[a] > area[b]
			end)
			for _, name in names do
				if area[name] >= 0.2 then
					print(
						string.format(
							"      %-17s %5.2f km2 %5d puddles %6.1f per km2",
							name,
							area[name],
							count[name] or 0,
							(count[name] or 0) / area[name]
						)
					)
				end
				if table.find(wetNames, name) then
					wetTotal += count[name] or 0
					wetArea += area[name]
				elseif table.find(dryNames, name) then
					dryTotal += count[name] or 0
					dryArea += area[name]
				end
			end
			t.ok(#list / land > 10 and #list / land < 120, "noticeable, not everywhere")
		end
		local wet, dry = wetTotal / wetArea, dryTotal / dryArea
		print(string.format("    wet biomes %.1f per km2, dry biomes %.1f per km2", wet, dry))
		t.ok(wet > 40 and wet < 150, "wet biomes have many")
		t.ok(dry < wet / 4, "dry biomes have few")
	end)

	--[[ Every lake and puddle ]]

	t.test("water: every generated water cell is a still source held in beside and below", function()
		local cells, open = 0, 0
		local first: string? = nil
		for _, s in sampleChunks do
			local r = chunk(s[1], s[2])
			for y = SEA, r.height - 1 do
				for lz = 0, SIZE - 1 do
					for lx = 0, SIZE - 1 do
						local id = ChunkLayout.get(r.data, lx, y, lz)
						if isWater[id] or id == ICE then
							-- Above the sea, only lakes and puddles hold water.
							t.ok(id == WATER or id == ICE, "a source")
							local x, z = s[1] * SIZE + lx, s[2] * SIZE + lz
							local inside = false
							for _, lake in gen.waterLakes(x, z, x, z) do
								inside = inside or shapeAt(lake, x, y, z) == Lava.LAKE
							end
							for _, p in gen.puddles(x, z, x, z) do
								inside = inside or (Lakes.inPuddle(p, x, z) and y == p.y)
							end
							t.ok(inside, `water at {x},{y},{z} in no lake or puddle`)
							if id == ICE then
								continue
							end
							cells += 1
							for _, d in { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 }, { 0, -1, 0 } } do
								local n = ChunkLayout.getPadded(r.data, lx + d[1], y + d[2], lz + d[3])
								if not isOpaque[n] and not isWater[n] and n ~= ICE then
									open += 1
									first = first or `{x},{y},{z} next to {Blocks.get(n).name}`
								end
							end
						end
					end
				end
			end
		end
		print(`    {cells} water cells checked in {#sampleChunks} chunks`)
		t.ok(cells > 1000, "water cells")
		t.eq(open, 0, `water cells with an open side or bottom: {first}`)
	end)

	t.test("water: decided from the terrain alone; padding equals the neighbouring cores", function()
		-- A fresh generator asked about small areas in another order finds the same lakes and puddles.
		local fresh = TerrainGenerator.new(SEED)
		for k = #sampleLakes, 1, -1 do
			local lake = sampleLakes[k]
			local found = false
			for _, other in fresh.waterLakes(lake.x + 5, lake.z + 5, lake.x + 6, lake.z + 6) do
				found = found
					or (
						other.x == lake.x
						and other.y == lake.y
						and other.z == lake.z
						and buffer.tostring(other.shape) == buffer.tostring(lake.shape)
						and other.floor == lake.floor
					)
			end
			t.ok(found, "the same lake")
		end
		for k = #samplePuddles, 1, -1 do
			local p = samplePuddles[k]
			local found = false
			for _, other in fresh.puddles(p.x0, p.z0, p.x0, p.z0) do
				found = found
					or (
						other.x0 == p.x0
						and other.z1 == p.z1
						and other.y == p.y
						and buffer.tostring(other.mask) == buffer.tostring(p.mask)
					)
			end
			t.ok(found, "the same puddle")
		end
		-- The same chunks from both generators.
		for k = 1, math.min(#sampleChunks, 6) do
			local s = sampleChunks[k]
			t.eq(
				buffer.tostring(fresh.generate(0, s[1], s[2]).data),
				buffer.tostring(chunk(s[1], s[2]).data),
				"same chunk"
			)
		end
		local bad, compared = 0, 0
		local function around(x0: number, z0: number, x1: number, z1: number)
			for cz = z0 // SIZE - 1, z1 // SIZE do
				for cx = x0 // SIZE - 1, x1 // SIZE do
					local b, c = borderMismatches(cx, cz)
					bad += b
					compared += c
				end
			end
		end
		for k = 1, math.min(#sampleLakes, 3) do
			local lake = sampleLakes[k]
			around(lake.x, lake.z, lake.x + Lakes.BOX - 1, lake.z + Lakes.BOX - 1)
		end
		-- Puddles across a chunk border.
		local crossing = 0
		for _, p in puddles do
			if crossing < 6 and (p.x0 // SIZE ~= p.x1 // SIZE or p.z0 // SIZE ~= p.z1 // SIZE) then
				crossing += 1
				around(p.x0, p.z0, p.x1, p.z1)
			end
		end
		t.ok(crossing >= 4, `puddles across a border: {crossing}`)
		t.ok(compared > 100000, `cells compared: {compared}`)
		t.eq(bad, 0, "border cells that disagree")
	end)

	t.test("water: no tree or plant stands in or on it; no surface cave opens it", function()
		local checked = 0
		for _, s in sampleChunks do
			local r = chunk(s[1], s[2])
			for y = SEA, r.height - 2 do
				for lz = 0, SIZE - 1 do
					for lx = 0, SIZE - 1 do
						local id = ChunkLayout.get(r.data, lx, y, lz)
						if isWater[id] or id == ICE then
							checked += 1
							local above = ChunkLayout.get(r.data, lx, y + 1, lz)
							t.ok(not isWoody[above], `{Blocks.get(above).name} on the water`)
						end
					end
				end
			end
		end
		t.ok(checked > 1000, `water cells: {checked}`)
		-- Surface caves never carve a puddle's columns or a lake's box.
		for _, p in samplePuddles do
			for z = p.z0, p.z1 do
				for x = p.x0, p.x1 do
					if Lakes.inPuddle(p, x, z) then
						t.ok(not gen.surfaceCaves.carvesTop(x, z), "a surface cave under a puddle")
					end
				end
			end
		end
	end)

	t.test("water: far nodes (levels 1-2) show the lakes, not the puddles", function()
		for k = 1, math.min(#sampleLakes, 4) do
			local lake = sampleLakes[k]
			for level = 1, Config.StructureMaxLevel do
				local span = SIZE * 2 ^ level
				local _, stepY = ChunkLayout.steps(level)
				local r = gen.generate(level, (lake.x + 8) // span, (lake.z + 8) // span)
				local found = 0
				for i = 0, buffer.len(r.data) // 2 - 1 do
					local id = buffer.readu16(r.data, i * 2)
					if (id == WATER or id == ICE) and (i // LAYER) * stepY >= SEA then
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
		-- A far node over puddles (and no lake) holds no water above the sea.
		local shown = 0
		for k = 1, math.min(#samplePuddles, 10) do
			local p = samplePuddles[k]
			local span = SIZE * 2
			local nx, nz = p.x0 // span, p.z0 // span
			if #gen.waterLakes(nx * span - 4, nz * span - 4, nx * span + span + 3, nz * span + span + 3) == 0 then
				local r = gen.generate(1, nx, nz)
				for i = 0, buffer.len(r.data) // 2 - 1 do
					if buffer.readu16(r.data, i * 2) == WATER and (i // LAYER) * 2 >= SEA then
						shown += 1
					end
				end
			end
		end
		t.eq(shown, 0, "far nodes draw no puddles")
	end)

	t.test("water: solidBelow, emptyAbove and the cave visibility graphs hold", function()
		local cull = Blocks.cullLutHiddenCaves
		for k = 1, math.min(#sampleChunks, 12) do
			local s = sampleChunks[k]
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
		local sections = 0
		for k = 1, math.min(#sampleChunks, 6) do
			sections += graphsAgree(sampleChunks[k][1], sampleChunks[k][2])
		end
		t.ok(sections >= 0, "graphs compared")
	end)

	t.test("water: the map paints lakes and puddles as water", function()
		local paint = MapPainter.new(gen)
		local function isBlue(tile: buffer, size: number, px: number, py: number): boolean
			local o = (py * size + px) * 4
			local r, g, b = buffer.readu8(tile, o), buffer.readu8(tile, o + 1), buffer.readu8(tile, o + 2)
			return b > r and b >= g
		end
		local lakePixels, puddlePixels = 0, 0
		for k = 1, math.min(#sampleLakes, 4) do
			local lake = sampleLakes[k]
			if lake.frozen then
				continue
			end
			local scale, size = 2, 16
			local ox, oz = lake.x, lake.z
			local tile = paint(ox, oz, scale, size)
			for py = 0, size - 1 do
				for px = 0, size - 1 do
					if Lakes.wet(lake, ox + px * scale + 1, oz + py * scale + 1) then
						t.ok(isBlue(tile, size, px, py), "a lake pixel is water")
						lakePixels += 1
					end
				end
			end
		end
		for k = 1, math.min(#samplePuddles, 6) do
			local p = samplePuddles[k]
			local size = 16
			local tile = paint(p.x0 - 4, p.z0 - 4, 1, size)
			for py = 0, size - 1 do
				for px = 0, size - 1 do
					if Lakes.inPuddle(p, p.x0 - 4 + px, p.z0 - 4 + py) then
						t.ok(isBlue(tile, size, px, py), "a puddle pixel is water")
						puddlePixels += 1
					end
				end
			end
		end
		t.ok(lakePixels > 20 and puddlePixels > 20, `pixels: {lakePixels} of lakes, {puddlePixels} of puddles`)
	end)

	t.test("water: costs little generation time", function()
		-- The same chunks with lakes and puddles switched off, each from a fresh generator (so the
		-- decisions are part of the cost, as for a worker's first chunks in a new area).
		local function run(): number
			local g = TerrainGenerator.new(SEED)
			local t0 = os.clock()
			for _, s in sampleChunks do
				for dz = 0, 1 do
					for dx = 0, 1 do
						g.generate(0, s[1] + dx, s[2] + dz)
					end
				end
			end
			return os.clock() - t0
		end
		-- The best of three runs each, alternating, so a busy machine skews both alike.
		local was = { Config.Lakes.Water.Enabled, Config.Lakes.Puddles.Enabled }
		local with, without = math.huge, math.huge
		for _ = 1, 3 do
			with = math.min(with, run())
			Config.Lakes.Water.Enabled, Config.Lakes.Puddles.Enabled = false, false
			without = math.min(without, run())
			Config.Lakes.Water.Enabled, Config.Lakes.Puddles.Enabled = was[1], was[2]
		end
		local n = #sampleChunks * 4
		print(
			string.format(
				"    %d chunks around lakes and puddles: %.2f ms a chunk with them, %.2f ms without (%+.1f%%)",
				n,
				with / n * 1000,
				without / n * 1000,
				(with / without - 1) * 100
			)
		)
		t.ok(with < without * 1.2, "lakes and puddles cost little")
	end)
end
