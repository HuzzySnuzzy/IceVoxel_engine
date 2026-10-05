return function(t, shared, require)
	local Config = require(shared.Config)
	local Blocks = require(shared.Blocks)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)
	local Relief = require(shared.Generation.Relief)
	local Biomes = require(shared.Biomes)
	local Hash = require(shared.Util.Hash)
	local Ores = require(shared.Generation.Ores)

	local SIZE = ChunkLayout.SIZE
	local gen = TerrainGenerator.new(12345)

	-- Ores (and stone varieties) only exist in a chunk's own core, so treat them as stone when
	-- comparing borders.
	local ORE = {
		[Blocks.id.CoalOre] = true,
		[Blocks.id.IronOre] = true,
		[Blocks.id.GoldOre] = true,
		[Blocks.id.DiamondOre] = true,
		[Blocks.id.EmeraldOre] = true,
		[Blocks.id.OsmiumOre] = true,
		[Blocks.id.Diorite] = true,
		[Blocks.id.Andesite] = true,
		[Blocks.id.Granite] = true,
	}
	local function norm(id: number): number
		return if ORE[id] then Blocks.id.Stone else id
	end

	t.test("generation is deterministic per seed", function()
		local a = gen.generate(0, 3, -2).data
		local b = TerrainGenerator.new(12345).generate(0, 3, -2).data
		t.eq(buffer.tostring(a), buffer.tostring(b), "same seed")
		local c = TerrainGenerator.new(54321).generate(0, 3, -2).data
		t.ok(buffer.tostring(a) ~= buffer.tostring(c), "different seed")
	end)

	t.test("chunk borders agree with their neighbours (terrain, caves, trees)", function()
		local mismatches = 0
		local pairs = { { 0, 0 }, { -7, 3 }, { 12, -9 }, { 40, 40 }, { -25, -60 } }
		for _, p in pairs do
			local cx, cz = p[1], p[2]
			local a = gen.generate(0, cx, cz)
			local east = gen.generate(0, cx + 1, cz)
			local south = gen.generate(0, cx, cz + 1)
			for y = 0, a.height - 1 do
				for i = 0, SIZE - 1 do
					-- A's +X border == east core column 0, and east's -X border == A core column 15.
					if norm(ChunkLayout.getPadded(a.data, SIZE, y, i)) ~= norm(ChunkLayout.get(east.data, 0, y, i)) then
						mismatches += 1
					end
					if
						norm(ChunkLayout.getPadded(east.data, -1, y, i))
						~= norm(ChunkLayout.get(a.data, SIZE - 1, y, i))
					then
						mismatches += 1
					end
					if
						norm(ChunkLayout.getPadded(a.data, i, y, SIZE)) ~= norm(ChunkLayout.get(south.data, i, y, 0))
					then
						mismatches += 1
					end
					if
						norm(ChunkLayout.getPadded(south.data, i, y, -1))
						~= norm(ChunkLayout.get(a.data, i, y, SIZE - 1))
					then
						mismatches += 1
					end
				end
			end
		end
		t.eq(mismatches, 0, "border cells that disagree")
	end)

	t.test("solidBelow / emptyAbove hints are correct", function()
		local cull = Blocks.cullLutHiddenCaves
		for level = 0, 3 do
			for _, p in { { 0, 0 }, { 5, -3 }, { -2, 9 } } do
				local r = gen.generate(level, p[1], p[2])
				-- Cropped a little above the terrain: the top row is still air.
				t.ok(r.emptyAbove < r.height, `L{level} crop leaves no air on top`)
				for y = 0, r.height - 1 do
					for i = 0, ChunkLayout.LAYER - 1 do
						local id = buffer.readu16(r.data, (y * ChunkLayout.LAYER + i) * 2)
						if y < r.solidBelow then
							t.ok(buffer.readu8(cull, id) == 1, `L{level} cell below solidBelow is not solid (y={y})`)
						end
						if y >= r.emptyAbove then
							t.eq(id, Blocks.AIR, `L{level} cell above emptyAbove is not air (y={y})`)
						end
					end
				end
			end
		end
	end)

	t.test("LOD chunks follow the full detail terrain", function()
		for level = 1, Config.Lod.Levels - 1 do
			local step, stepY = ChunkLayout.steps(level)
			local r = gen.generate(level, 1, -1)
			local worst = 0
			for lz = 0, SIZE - 1, 5 do
				for lx = 0, SIZE - 1, 5 do
					local wx = SIZE * step + lx * step + step // 2
					local wz = -SIZE * step + lz * step + step // 2
					local h = gen.column(wx, wz)
					-- Highest terrain cell (ignore trees by only looking at non-leaf/log blocks below h + step).
					local topCell = -1
					for y = r.height - 1, 0, -1 do
						local id = ChunkLayout.get(r.data, lx, y, lz)
						if Blocks.isOpaque(id) and y * stepY <= h then
							topCell = y
							break
						end
					end
					worst = math.max(worst, math.abs((topCell + 1) * stepY - h))
				end
			end
			t.ok(worst <= stepY, `level {level}: LOD surface off by {worst} blocks`)
			t.ok(r.height <= Config.WorldHeight // stepY, "cells per column")
			t.eq(buffer.len(r.data), ChunkLayout.LAYER * r.height * 2, "buffer matches the height")
		end
	end)

	t.test("world has oceans, land, mountains, several biomes and caves", function()
		local land, ocean, high = 0, 0, 0
		local biomes: { [number]: boolean } = {}
		local biomeCount = 0
		for z = -6000, 6000, 150 do
			for x = -6000, 6000, 150 do
				local h, biome = gen.column(x, z)
				if h >= Config.SeaLevel then
					land += 1
				else
					ocean += 1
				end
				if h > Config.SeaLevel + 60 then
					high += 1
				end
				if not biomes[biome] then
					biomes[biome] = true
					biomeCount += 1
				end
			end
		end
		t.ok(land > 0 and ocean > 0 and high > 0, `land {land}, ocean {ocean}, mountains {high}`)
		t.ok(biomeCount >= 6, `only {biomeCount} biomes in a 12k block square`)

		-- Caves come in regions (a few hundred blocks wide): look along a line of chunks.
		local caveCells = 0
		for cx = 0, 120, 4 do
			local r = gen.generate(0, cx, 0)
			for i = 0, buffer.len(r.data) // 2 - 1 do
				if buffer.readu16(r.data, i * 2) == Blocks.CAVE_AIR then
					caveCells += 1
				end
			end
			if caveCells > 0 then
				break
			end
		end
		t.ok(caveCells > 0, "no caves generated")
	end)

	t.test("spawn is on dry land", function()
		local x, h, z = gen.findSpawn()
		t.ok(h > Config.SeaLevel, `spawn height {h}`)
		t.eq(gen.column(x, z), h)
	end)

	t.test("relief: terrain types, heights and rivers like JJThunder To The Max", function()
		local relief = Relief.new(777)
		local rng = Hash.rng(5)
		local function between(a: number, b: number): number
			return a + (b - a) * rng:float()
		end
		local n, ranges, ocean, belowSea, rivers = 4000, 0, 0, 0, 0
		local heights = {}
		for _ = 1, n do
			local x, z = between(-200000, 200000), between(-200000, 200000)
			local y, unrivered, selector, river = relief.height(x, z, 0)
			local a = math.abs(selector)
			if a < 0.0375 then
				ranges += 1
			elseif a >= 0.4 then
				ocean += 1
			end
			if y < Config.SeaLevel then
				belowSea += 1
				if river > 0.9 then
					rivers += 1
				end
			end
			t.ok(y <= unrivered + 1e-9, "rivers only dig")
			table.insert(heights, y)
		end
		table.sort(heights)
		-- The datapack: 7.4% extreme mountain cores, 27% ocean, 27% below sea level (scaled heights:
		-- median ~130, p99 ~680, highest ~900).
		t.ok(ranges / n > 0.04 and ranges / n < 0.11, `mountain cores {ranges / n}`)
		t.ok(ocean / n > 0.2 and ocean / n < 0.34, `ocean {ocean / n}`)
		t.ok(belowSea / n > 0.18 and belowSea / n < 0.36, `below sea level {belowSea / n}`)
		local median, p99 = heights[n // 2], heights[math.floor(n * 0.99)]
		t.ok(median > 80 and median < 200, `median height {median}`)
		t.ok(p99 > 550 and p99 < 820, `99th percentile height {p99}`)
		t.ok(heights[n] < Config.WorldHeight - 32, `highest {heights[n]}`)
		t.ok(rivers > 0, "no river below sea level")

		-- Far LOD heights only lose jagged detail narrower than two of their cells: less than a cell
		-- up to level 4, up to two cells at levels 5-6 (where cells stop growing taller).
		for _ = 1, 300 do
			local x, z = between(-50000, 50000), between(-50000, 50000)
			local y0 = relief.height(x, z, 0)
			for level = 1, Config.Lod.Levels - 1 do
				local _, stepY = ChunkLayout.steps(level)
				local y = relief.height(x, z, level)
				t.ok(math.abs(y - y0) < math.max(3, 2 * stepY), `level {level} height {y} vs {y0}`)
			end
		end
	end)

	t.test("ores and stone varieties keep to their altitudes", function()
		local bands = {
			[Blocks.id.Diorite] = { 5, 200 },
			[Blocks.id.Andesite] = { 200, 370 },
			[Blocks.id.Granite] = { 370, 540 },
			[Blocks.id.DiamondOre] = { 5, 30 },
			[Blocks.id.EmeraldOre] = { 600, math.huge },
		}
		local seen: { [number]: number } = {}
		local relief = Relief.new(12345)
		-- Mountain chunks (every band, unless the Underlands hollowed it out) and a lowland one.
		local rng = Hash.rng(11)
		local spots = {}
		while #spots < 6 do
			local x, z = rng:int(-40000, 40000), rng:int(-40000, 40000)
			local y = relief.height(x, z, 0)
			if (#spots < 3 and y > 640 and y < 720) or (#spots >= 3 and y > 90 and y < 140) then
				table.insert(spots, { x // SIZE, z // SIZE })
			end
		end
		for _, spot in spots do
			local r = gen.generate(0, spot[1], spot[2])
			for y = 0, r.height - 1 do
				for z = 0, SIZE - 1 do
					for x = 0, SIZE - 1 do
						local id = ChunkLayout.get(r.data, x, y, z)
						local band = bands[id]
						if band then
							seen[id] = (seen[id] or 0) + 1
							-- Veins wander up to their size from where they start.
							t.ok(y >= band[1] - 40 and y <= band[2] + 40, `{Blocks.get(id).name} at y {y}`)
						end
					end
				end
			end
		end
		for id in bands do
			t.ok((seen[id] or 0) > 0, `no {Blocks.get(id).name}`)
		end
	end)

	--[[ Mekanism's osmium (Ores.FEATURES osmium_small / osmium_middle / osmium_upper) ]]

	t.test("ores: trapezoid heights follow Minecraft's TrapezoidHeight", function()
		local rng = Hash.rng(77)
		local thirds = { 0, 0, 0 }
		local sum, n = 0, 30000
		for _ = 1, n do
			local y = Ores.trapezoid(rng, 5, 197)
			t.ok(y >= 5 and y <= 197 and y == math.floor(y), `trapezoid height {y}`)
			sum += y
			local third = math.min(3, (y - 5) * 3 // 192 + 1)
			thirds[third] += 1
		end
		-- A triangle: 2/9 of the heights in each outer third, 5/9 in the middle one.
		t.near(sum / n, 101, 1.5, "centred")
		t.near(thirds[2] / n, 5 / 9, 0.02, "middle third")
		t.near(thirds[1] / n, 2 / 9, 0.02, "lower third")
		t.near(thirds[3] / n, 2 / 9, 0.02, "upper third")
		-- A plateau flattens the top; one as wide as the range is uniform.
		local plateau = 0
		for _ = 1, 10000 do
			local y = Ores.trapezoid(rng, 72, 343, 8)
			t.ok(y >= 72 and y <= 343, "plateau range")
			if y >= 203 and y <= 211 then
				plateau += 1
			end
		end
		t.ok(plateau / 10000 > 0.06, `plateau share {plateau / 10000}`)
		for _ = 1, 100 do
			local y = Ores.trapezoid(rng, 10, 12, 5)
			t.ok(y >= 10 and y <= 12, "uniform when the plateau covers the range")
		end
		-- An empty range gives its bottom and draws nothing (Minecraft's warning case).
		local state = rng.state
		t.eq(Ores.trapezoid(rng, 50, 40), 50, "empty range")
		t.eq(rng.state, state, "no draws for an empty range")
		t.eq(Ores.trapezoid(rng, 30, 30), 30, "a single height")
		-- Mekanism's middle feature is the trapezoid one, and it draws 6 veins per chunk.
		local middle
		for _, ore in Ores.FEATURES do
			if ore.name == "osmium_middle" then
				middle = ore
			end
		end
		assert(middle, "osmium_middle")
		t.eq(middle.shape, "trapezoid")
		t.eq(middle.veins * (middle.maxY - middle.minY) / 128, 6, "veins per chunk")
		t.eq(middle.size, 9, "Mekanism's vein size")
	end)

	-- A chunk `height` cells tall: bedrock at 0, stone up to `top` with layers of dirt, water and
	-- cave air in it, air above; the padding is stone too (where ores must never go).
	local function testChunk(height: number, top: number): buffer
		local data = ChunkLayout.create(height)
		for y = 0, top do
			local block = if y == 0
				then Blocks.id.Bedrock
				elseif y % 40 == 7 then Blocks.id.Dirt
				elseif y % 40 == 19 then Blocks.fluidId("Water", 0)
				elseif y % 40 == 31 then Blocks.CAVE_AIR
				else Blocks.id.Stone
			for i = 0, ChunkLayout.LAYER - 1 do
				buffer.writeu16(data, (y * ChunkLayout.LAYER + i) * 2, block)
			end
		end
		return data
	end

	t.test("ores: veins only turn stone in the chunk's core into ore, deterministically", function()
		local isOre: { [number]: boolean } = {}
		for _, ore in Ores.FEATURES do
			isOre[ore.block] = true
		end
		local height, top = 448, 430
		local before = testChunk(height, top)
		local osmium = 0
		for _, chunk in { { 0, 0 }, { 5, -9 }, { -300, 41 } } do
			local data = testChunk(height, top)
			Ores.place(data, 4242, chunk[1], chunk[2], height)
			local again = testChunk(height, top)
			Ores.place(again, 4242, chunk[1], chunk[2], height)
			t.eq(buffer.tostring(data), buffer.tostring(again), "same seed and chunk, same ores")
			local other = testChunk(height, top)
			Ores.place(other, 4243, chunk[1], chunk[2], height)
			t.ok(buffer.tostring(data) ~= buffer.tostring(other), "another seed, other ores")
			for i = 0, buffer.len(data) // 2 - 1 do
				local was, now = buffer.readu16(before, i * 2), buffer.readu16(data, i * 2)
				if was ~= now then
					t.ok(was == Blocks.id.Stone, "only stone is replaced")
					t.ok(isOre[now] == true, "by an ore")
					local index = i % ChunkLayout.LAYER
					local px, pz = index % ChunkLayout.PADDED, index // ChunkLayout.PADDED
					t.ok(px >= 1 and px <= SIZE and pz >= 1 and pz <= SIZE, "inside the core")
					if now == Blocks.id.OsmiumOre then
						osmium += 1
					end
				end
			end
		end
		t.ok(osmium > 50, `osmium placed: {osmium}`)
	end)

	t.test("ores: adding osmium moved no earlier ore (saved worlds keep theirs)", function()
		-- Checksums of every non-osmium ore cell in all-stone chunks, taken before osmium existed:
		-- the features before it in Ores.FEATURES must keep drawing the same numbers.
		local height = 700
		local expected = { "922:1760838665", "921:2061121151", "914:384238489" }
		for i, chunk in { { 0, 0 }, { 3, -2 }, { -57, 1201 } } do
			local data = ChunkLayout.create(height)
			for cell = ChunkLayout.LAYER, ChunkLayout.LAYER * height - 1 do
				buffer.writeu16(data, cell * 2, Blocks.id.Stone)
			end
			Ores.place(data, 4242, chunk[1], chunk[2], height)
			local sum, n = 0, 0
			for cell = 0, buffer.len(data) // 2 - 1 do
				local id = buffer.readu16(data, cell * 2)
				if id ~= Blocks.id.Stone and id ~= Blocks.id.Air and id ~= Blocks.id.OsmiumOre then
					sum = (sum * 31 + cell * 7 + id) % 2147483647
					n += 1
				end
			end
			t.eq(`{n}:{sum}`, expected[i], `chunk {chunk[1]}, {chunk[2]}`)
		end
	end)

	t.test("ores: osmium is as common as iron low down, rarer higher up, densest around y 100", function()
		-- All-stone chunks 448 tall (no caves or terrain in the way): ore cells per band.
		local height = 448
		local template = buffer.create(ChunkLayout.LAYER * height * 2)
		for i = ChunkLayout.LAYER, ChunkLayout.LAYER * height - 1 do
			buffer.writeu16(template, i * 2, Blocks.id.Stone)
		end
		local IRON, OSMIUM = Blocks.id.IronOre, Blocks.id.OsmiumOre
		-- [band] = { iron, osmium }: low 5..196, high 197..447, deep 5..40, middle 70..130.
		local counts = { low = { 0, 0 }, high = { 0, 0 }, deep = { 0, 0 }, middle = { 0, 0 } }
		local data = buffer.create(buffer.len(template))
		for chunk = 1, 48 do
			buffer.copy(data, 0, template)
			Ores.place(data, 12345, chunk * 7 - 100, chunk * 13 - 300, height)
			for y = 5, height - 1 do
				local iron, osmium = 0, 0
				for z = 0, SIZE - 1 do
					for x = 0, SIZE - 1 do
						local id = ChunkLayout.get(data, x, y, z)
						if id == IRON then
							iron += 1
						elseif id == OSMIUM then
							osmium += 1
						end
					end
				end
				local band = if y < 197 then counts.low else counts.high
				band[1] += iron
				band[2] += osmium
				if y <= 40 then
					counts.deep[1] += iron
					counts.deep[2] += osmium
				elseif y >= 70 and y <= 130 then
					counts.middle[1] += iron
					counts.middle[2] += osmium
				end
			end
		end
		local low = counts.low[2] / counts.low[1]
		local high = counts.high[2] / counts.high[1]
		t.ok(low > 0.7 and low < 1.35, `osmium / iron below y 197: {low}`)
		t.ok(high > 0.3 and high < 0.8, `osmium / iron above: {high}`)
		-- Per layer: the middle band (61 layers) against near bedrock (36 layers).
		local middle, deep = counts.middle[2] / 61, counts.deep[2] / 36
		t.ok(middle > 1.8 * deep, `osmium per layer around y 100 {middle}, near bedrock {deep}`)
	end)

	t.test("ores: generated chunks have osmium in their rock, lowlands and mountains alike", function()
		local relief = Relief.new(12345)
		local rng = Hash.rng(23)
		local found = { low = 0, high = 0 }
		local spots = {}
		while #spots < 4 do
			local x, z = rng:int(-40000, 40000), rng:int(-40000, 40000)
			local y = relief.height(x, z, 0)
			if (#spots < 2 and y > 90 and y < 160) or (#spots >= 2 and y > 500 and y < 700) then
				table.insert(spots, { x // SIZE, z // SIZE })
			end
		end
		for _, spot in spots do
			local r = gen.generate(0, spot[1], spot[2])
			for y = 0, r.height - 1 do
				for z = 0, SIZE - 1 do
					for x = 0, SIZE - 1 do
						if ChunkLayout.get(r.data, x, y, z) == Blocks.id.OsmiumOre then
							local surface = gen.column(spot[1] * SIZE + x, spot[2] * SIZE + z)
							t.ok(y < surface, `osmium below the surface ({y} < {surface})`)
							if y < 197 then
								found.low += 1
							else
								found.high += 1
							end
						end
					end
				end
			end
		end
		t.ok(found.low > 0, "osmium below y 197")
		t.ok(found.high > 0, "osmium in the mountains")
	end)

	t.test("biomes follow altitude bands", function()
		local relief = Relief.new(12345)
		local rng = Hash.rng(9)
		local mushroom = (Biomes.byName("MushroomFields") :: any).index
		local seen: { [number]: boolean } = {}
		for _ = 1, 3000 do
			local x, z = rng:int(-100000, 100000), rng:int(-100000, 100000)
			local _, biome = gen.column(x, z)
			local _, unrivered, selector = relief.height(x, z, 0)
			seen[biome] = true
			if biome == mushroom then
				t.ok(selector < -0.4, "mushroom fields only in the middle of seas")
			else
				-- Band borders are dithered by a few blocks.
				local band = Biomes.bandAt(unrivered)
				local near = false
				for _, b in Biomes.list[biome].bands do
					near = near or math.abs(b - band) <= 1
				end
				t.ok(near, `{Biomes.list[biome].name} at height {unrivered}`)
			end
		end
		for _, name in { "Plains", "Forest", "SnowySlopes", "Grove", "Meadow" } do
			t.ok(seen[(Biomes.byName(name) :: any).index], `no {name} found`)
		end
	end)
end
