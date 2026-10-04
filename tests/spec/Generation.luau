return function(t, shared, require)
	local Config = require(shared.Config)
	local Blocks = require(shared.Blocks)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)
	local Relief = require(shared.Generation.Relief)
	local Biomes = require(shared.Biomes)
	local Hash = require(shared.Util.Hash)

	local SIZE = ChunkLayout.SIZE
	local gen = TerrainGenerator.new(12345)

	-- Ores only exist in a chunk's own core, so treat them as stone when comparing borders.
	local ORE = {
		[Blocks.id.CoalOre] = true,
		[Blocks.id.IronOre] = true,
		[Blocks.id.GoldOre] = true,
		[Blocks.id.DiamondOre] = true,
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

		local caveCells = 0
		for cx = 0, 3 do
			local r = gen.generate(0, cx, 0)
			for i = 0, buffer.len(r.data) // 2 - 1 do
				if buffer.readu16(r.data, i * 2) == Blocks.CAVE_AIR then
					caveCells += 1
				end
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

		-- Far LOD heights only lose jagged detail narrower than two of their cells, which moves them
		-- by less than a cell.
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
