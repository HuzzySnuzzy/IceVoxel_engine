--[[
	Ground plants in generated terrain (Generation/Foliage, BiomeList `foliage`): determinism across
	chunk borders, Minecraft's placement rules, full detail only, coverage per biome, same-species
	flower patches, the part budget (per soil column, and all plants drawn around a player) and the
	cost.
]]
return function(t, shared, require)
	local Config = require(shared.Config)
	local Blocks = require(shared.Blocks)
	local Biomes = require(shared.Biomes)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)
	local Foliage = require(shared.Generation.Foliage)
	local Hash = require(shared.Util.Hash)

	local SIZE = ChunkLayout.SIZE
	local P = ChunkLayout.PADDED
	local AIR = Blocks.AIR
	local SEED = 12345
	local gen = TerrainGenerator.new(SEED)
	local id = Blocks.id

	-- Parts a plant costs in the world: its boxes, plus its top's for a tall plant.
	local function parts(block: number): number
		local shape = Blocks.appearances[Blocks.get(block).appearance].shape
		local n = if shape then #shape else 0
		local top = Blocks.plantTop(block)
		return if top then n + parts(top) else n
	end

	-- Parts per soil column allowed, by biome.
	local BUDGET = { Jungle = 0.6, Meadow = 0.6, Plains = 0.45, Savanna = 0.45 }
	local DEFAULT_BUDGET = 0.35

	local isPlant: { [number]: boolean } = {}
	for block = 0, Blocks.count - 1 do
		isPlant[block] = Blocks.isPlant(block)
	end
	local function isTree(block: number): boolean
		local name = Blocks.get(block).name
		return string.find(name, "Log") ~= nil or string.find(name, "Leaves") ~= nil
	end

	-- Ores and stone varieties only exist in a chunk's own core.
	local ORE: { [number]: boolean } = {}
	for _, name in
		{ "CoalOre", "IronOre", "GoldOre", "DiamondOre", "EmeraldOre", "OsmiumOre", "Diorite", "Andesite", "Granite" }
	do
		ORE[id[name]] = true
	end
	local function norm(block: number): number
		return if ORE[block] then id.Stone else block
	end

	-- Block at padded (px, y, pz) of a generated chunk, air above its buffer.
	local function padded(r: any, px: number, y: number, pz: number): number
		if y >= r.height then
			return AIR
		end
		return buffer.readu16(r.data, ChunkLayout.index(px, y, pz) * 2)
	end

	--[[
		Sample chunks: per biome, chunks whose centre and corners are that biome on dry land, spread
		over 128k blocks (2 per biome), plus 4 neighbours (east,
		south, both corners on the east) of each with foliage. Generated once, shared by the tests.
	]]
	local chunks: { { cx: number, cz: number, r: any } } = {}
	local byKey: { [string]: any } = {}
	local function chunk(cx: number, cz: number): any
		local key = `{cx},{cz}`
		local r = byKey[key]
		if r == nil then
			r = gen.generate(0, cx, cz)
			byKey[key] = r
			table.insert(chunks, { cx = cx, cz = cz, r = r })
		end
		return r
	end
	local samples: { [number]: { { number } } } = {}
	local NEIGHBOURS = { { 1, 0 }, { 0, 1 }, { 1, 1 }, { 1, -1 } }
	do
		local rng = Hash.rng(2024)
		for _ = 1, 8000 do
			local cx, cz = rng:int(-4000, 4000), rng:int(-4000, 4000)
			local x0, z0 = cx * SIZE, cz * SIZE
			local h, biome = gen.column(x0 + 8, z0 + 8)
			local list = samples[biome] or {}
			samples[biome] = list
			local foliage = Biomes.list[biome].foliage ~= nil
			if #list < 2 and h > Config.SeaLevel + 2 then
				local same = true
				for _, c in { { 0, 0 }, { 15, 0 }, { 0, 15 }, { 15, 15 } } do
					local _, b = gen.column(x0 + c[1], z0 + c[2])
					same = same and b == biome
				end
				if same then
					table.insert(list, { cx, cz })
					chunk(cx, cz)
					if foliage then
						for _, d in NEIGHBOURS do
							chunk(cx + d[1], cz + d[2])
						end
					end
				end
			end
		end
	end

	t.test("foliage: padding grows exactly the neighbour's plants, next to trees too", function()
		local mismatches, plantCells, treeColumns, compared = 0, 0, 0, 0
		for index, biome in Biomes.list do
			for _, sample in (if biome.foliage then samples[index] else nil) or {} do
				local cx, cz = sample[1], sample[2]
				local a = chunk(cx, cz)
				-- A's padding against each neighbour's core and theirs against A's: every side and
				-- corner of the padding.
				for _, d in NEIGHBOURS do
					compared += 1
					local b = chunk(cx + d[1], cz + d[2])
					for _, side in { { a, b, d[1], d[2], cx, cz }, { b, a, -d[1], -d[2], cx + d[1], cz + d[2] } } do
						local from, to, ox, oz = side[1], side[2], side[3], side[4]
						for pz = 0, P - 1 do
							for px = 0, P - 1 do
								-- The padded column of `from` that is a core column of `to`.
								local lx, lz = px - 1 - ox * SIZE, pz - 1 - oz * SIZE
								if lx >= 0 and lx < SIZE and lz >= 0 and lz < SIZE then
									-- From under the surface to above any tall plant (the rest of the
									-- column is tests/spec/Generation's).
									local h = gen.column(side[5] * SIZE + px - 1, side[6] * SIZE + pz - 1)
									for y = h - 3, h + 3 do
										local mine = norm(padded(from, px, y, pz))
										if mine ~= norm(padded(to, lx + 1, y, lz + 1)) then
											mismatches += 1
										end
										if isPlant[mine] then
											plantCells += 1
										end
									end
									if isTree(padded(from, px, h, pz)) or isTree(padded(from, px, h + 1, pz)) then
										treeColumns += 1
									end
								end
							end
						end
					end
				end
			end
		end
		t.eq(mismatches, 0, "padding cells that differ from the neighbour's core")
		t.ok(compared >= 24, `chunk pairs compared: {compared}`)
		t.ok(plantCells > 100, `plant cells compared: {plantCells}`)
		t.ok(treeColumns > 20, `columns with a tree right above the ground compared: {treeColumns}`)
	end)

	t.test("foliage: plants stand on their soil, tall ones are whole and emptyAbove covers them", function()
		local count, tall = 0, 0
		for _, c in chunks do
			local r = c.r
			local function get(x: number, y: number, z: number): number?
				if x < 0 or x >= P or z < 0 or z >= P or y < 0 then
					return nil
				end
				return padded(r, x, y, z)
			end
			-- (Below solidBelow everything is rock or cave air.)
			for y = math.max(r.solidBelow, 1), r.height - 1 do
				for pz = 0, P - 1 do
					for px = 0, P - 1 do
						local block = padded(r, px, y, pz)
						if isPlant[block] then
							count += 1
							local name = Blocks.get(block).name
							local where = `{name} at {px},{y},{pz} of chunk {c.cx},{c.cz}`
							t.ok(Blocks.canSurvive(block, get, px, y, pz), `{where} cannot stand there`)
							t.ok(y < r.emptyAbove, `{where} is above emptyAbove {r.emptyAbove}`)
							-- Right on its column's ground, and nothing on top of it but its own top.
							local bottom = Blocks.plantBottom(block)
							local ground = if bottom then y - 2 else y - 1
							local h = gen.column(c.cx * SIZE + px - 1, c.cz * SIZE + pz - 1)
							t.eq(ground, h - 1, `{where}: not on the surface`)
							t.ok(Foliage.GROUND[padded(r, px, ground, pz)], `{where}: not on the ground`)
							local top = Blocks.plantTop(block)
							if top then
								tall += 1
								t.ok(y + 1 < r.height, `{where}: its top is outside the buffer`)
								t.eq(padded(r, px, y + 1, pz), top, `{where}: no top`)
							else
								if bottom then
									t.eq(padded(r, px, y - 1, pz), bottom, `{where}: no bottom`)
								end
								t.ok(not isPlant[padded(r, px, y + 1, pz)], `{where}: a plant on it`)
							end
						end
					end
				end
			end
		end
		t.ok(count > 1000, `plants checked: {count}`)
		t.ok(tall > 50, `tall plants checked: {tall}`)
	end)

	t.test("foliage: none in LOD chunks", function()
		local found, checked = 0, 0
		for index, biome in Biomes.list do
			local list = samples[index]
			if biome.foliage and list and #list > 0 then
				-- (Levels 1 to 3 in turn.)
				local level = checked % 3 + 1
				local span = SIZE * 2 ^ level
				local r = gen.generate(level, (list[1][1] * SIZE) // span, (list[1][2] * SIZE) // span)
				for i = 0, buffer.len(r.data) // 2 - 1 do
					if isPlant[buffer.readu16(r.data, i * 2)] then
						found += 1
					end
				end
				checked += 1
			end
		end
		t.ok(checked >= 10, `LOD chunks checked: {checked}`)
		t.eq(found, 0, "plant cells in LOD chunks")
	end)

	-- Per biome, over the core columns of the sample chunks: what grew, and the flowers (x, z, block).
	type Tally = { plants: number, grown: { [number]: number }, flowers: { { number } } }
	local tallies: { [number]: Tally }? = nil
	local function tally(): { [number]: Tally }
		if tallies then
			return tallies
		end
		local out: { [number]: Tally } = {}
		for index in Biomes.list do
			out[index] = { plants = 0, grown = {}, flowers = {} }
		end
		for _, c in chunks do
			for lz = 0, SIZE - 1 do
				for lx = 0, SIZE - 1 do
					local x, z = c.cx * SIZE + lx, c.cz * SIZE + lz
					local h, biome = gen.column(x, z)
					local block = if h < c.r.height then ChunkLayout.get(c.r.data, lx, h, lz) else AIR
					if isPlant[block] then
						local entry = out[biome]
						entry.plants += 1
						entry.grown[block] = (entry.grown[block] or 0) + 1
						local flowers = (Biomes.list[biome].foliage :: Biomes.Foliage).flowers
						if flowers and table.find(flowers.blocks, block) then
							table.insert(entry.flowers, { x, z, block })
						end
					end
				end
			end
		end
		tallies = out
		return out
	end

	t.test("foliage: every biome with foliage grows some, the others none", function()
		local counts = tally()
		for index, biome in Biomes.list do
			if #(samples[index] or {}) > 0 then
				t.eq(biome.foliage ~= nil, counts[index].plants > 0, `{biome.name} grows plants`)
			end
		end
		for _, name in { "Plains", "Forest", "Taiga", "Jungle", "Desert", "Meadow", "Savanna", "MushroomFields" } do
			local biome = Biomes.byName(name) :: Biomes.Biome
			t.ok(biome.foliage ~= nil, `{name} has foliage`)
			t.eq(#(samples[biome.index] or {}), 2, `sample chunks found in {name}`)
		end
		-- What grows where (Minecraft's vegetal decoration).
		local function grows(biome: string, block: string): number
			return counts[(Biomes.byName(biome) :: Biomes.Biome).index].grown[id[block]] or 0
		end
		t.ok(grows("Taiga", "Fern") > grows("Taiga", "ShortGrass"), "taiga: ferns over grass")
		t.ok(grows("Plains", "ShortGrass") > 2 * grows("Plains", "TallGrass"), "plains: mostly short grass")
		t.ok(grows("Plains", "TallGrass") > 0, "plains: some tall grass")
		t.ok(grows("Savanna", "TallGrass") > 0, "savanna: tall grass")
		t.ok(grows("Desert", "DeadBush") > 0, "desert: dead bushes")
		t.ok(grows("MushroomFields", "BrownMushroom") > 0 and grows("MushroomFields", "RedMushroom") > 0, "mushrooms")
		t.ok(grows("OldGrowthTaiga", "LargeFern") > 0, "old growth taiga: large ferns")
		t.ok(grows("Jungle", "Fern") > 0 and grows("Jungle", "ShortGrass") > 0, "jungle: grass and ferns")
		t.ok(#counts[(Biomes.byName("Meadow") :: Biomes.Biome).index].flowers > 20, "meadow: many flowers")
	end)

	t.test("foliage: flowers grow in same-species patches", function()
		local counts = tally()
		local same, total, random = 0, 0, 0
		for _, name in { "Plains", "Meadow", "Forest", "BirchForest" } do
			local biome = Biomes.byName(name) :: Biomes.Biome
			local flowers = (biome.foliage :: Biomes.Foliage).flowers :: Biomes.PlantList
			local list = counts[biome.index].flowers
			for i, a in list do
				for j = i + 1, #list do
					local b = list[j]
					if math.abs(a[1] - b[1]) <= 3 and math.abs(a[2] - b[2]) <= 3 then
						total += 1
						if a[3] == b[3] then
							same += 1
						end
					end
				end
			end
			-- Neighbours of the same species if species were random: the sum of p^2.
			local p2 = 0
			for _, w in flowers.weights do
				p2 += (w / flowers.total) ^ 2
			end
			random = math.max(random, p2)
		end
		t.ok(total > 50, `neighbouring flower pairs: {total}`)
		t.ok(same / total > 0.6, `same-species neighbours: {same / total}`)
		t.ok(
			same / total > 2.5 * random,
			`{same / total} same-species neighbours is not much more than random ({random})`
		)
	end)

	-- A flat test chunk: bedrock, `surface` at y 1, and `blocker` (or air) at y `blockY`.
	local function flat(surface: number, blocker: number?, blockY: number?): (buffer, number)
		local cells = 8
		local data = ChunkLayout.create(cells)
		for pz = -1, SIZE do
			for px = -1, SIZE do
				ChunkLayout.setPadded(data, px, 0, pz, id.Bedrock)
				ChunkLayout.setPadded(data, px, 1, pz, surface)
				if blocker and blockY then
					ChunkLayout.setPadded(data, px, blockY, pz, blocker)
				end
			end
		end
		return data, cells
	end

	--[[
		Grows a biome's plants on `count` flat chunks of `surface` spread over the world (origins
		far apart, so they sample many patches). Returns the plant cells by block and the highest
		top returned.
	]]
	local place = Foliage.new(SEED)
	local function grow(
		surface: number,
		biome: number,
		count: number,
		blocker: number?,
		blockY: number?
	): ({ [number]: number }, number)
		local grown: { [number]: number } = {}
		local highest = 0
		local biomes, tops = table.create(P * P, biome), table.create(P * P, 1)
		local template, cells = flat(surface, blocker, blockY)
		local data = buffer.create(buffer.len(template))
		local layer = ChunkLayout.LAYER
		for c = 0, count - 1 do
			buffer.copy(data, 0, template)
			local top = place(data, cells, c * 977 - 50000, c * 1361 - 80000, biomes, tops)
			highest = math.max(highest, top)
			-- (Plants can only be in cells 2 and 3.)
			for i = 2 * layer, 4 * layer - 1 do
				local block = buffer.readu16(data, i * 2)
				if isPlant[block] then
					grown[block] = (grown[block] or 0) + 1
					assert(i // layer < top, "the returned top covers the plants")
				end
			end
		end
		return grown, highest
	end

	-- Parts per soil column a biome's foliage is expected to cost: the chances times the average
	-- parts of what grows (tall plants whole).
	local function expectedParts(foliage: Biomes.Foliage): number
		local function average(list: Biomes.PlantList): number
			local sum = 0
			for i, block in list.blocks do
				sum += list.weights[i] * parts(block)
			end
			return sum / list.total
		end
		local expected = foliage.density * average(foliage.plants)
		local flowers = foliage.flowers
		if flowers then
			expected += foliage.flowerChance * average(flowers)
		end
		return expected
	end

	t.test("foliage: Parts per soil column stay within the budget in every biome", function()
		for index, biome in Biomes.list do
			local foliage = biome.foliage
			if foliage then
				local budget = BUDGET[biome.name] or DEFAULT_BUDGET
				local expected = expectedParts(foliage)
				t.ok(expected <= budget, `{biome.name}: {expected} Parts per soil column expected (budget {budget})`)
				-- Measured on open ground of the biome's top block (all columns are soil; trees,
				-- water and steep rock in real terrain only take plants away).
				t.ok(Foliage.isSoil(index, biome.top), `{biome.name}'s top block is soil`)
				local count = 60
				local grown = grow(biome.top, index, count)
				local sum = 0
				for block, n in grown do
					if not Blocks.plantBottom(block) then
						sum += n * parts(block)
					end
				end
				local measured = sum / (count * P * P)
				t.ok(measured <= budget, `{biome.name}: {measured} Parts per soil column (budget {budget})`)
				t.near(measured / expected, 1, 0.2, `{biome.name}: measured / expected Parts`)
			end
		end
	end)

	--[[
		The Parts of every plant drawn around a player: only full detail chunks within
		Config.Lod.FoliageDistance draw theirs (LodTree.drawsFoliage; all ~180 full detail chunks
		would cost 10,000-20,000 Parts). Even with every chunk of the hysteresis band still drawing
		them, at the worst viewer position, and every column soil of the densest biome, that stays
		within a few thousand, on computers and phones alike.
	]]
	local DRAWN_PARTS = 6000
	t.test("foliage: the plants drawn around a player stay within a few thousand Parts", function()
		local LodTree = require(shared.World.LodTree)
		local Coords = require(shared.World.Coords)
		-- A chunk's worst average: the densest biome's expected Parts per column, every column soil.
		local densest = 0
		for _, biome in Biomes.list do
			local foliage = biome.foliage
			if foliage then
				densest = math.max(densest, expectedParts(foliage))
			end
		end
		local perChunk = densest * SIZE * SIZE
		local lod = Config.Lod
		local presets = {
			{ "computers", lod.ViewDistance, lod.SplitDistance, lod.SplitDistanceL1, lod.FoliageDistance },
			{ "phones", lod.Mobile.ViewDistance, lod.Mobile.SplitDistance, nil, lod.Mobile.FoliageDistance },
		}
		for _, preset in presets do
			LodTree.configure(preset[2], preset[3], preset[4])
			LodTree.setFoliageDistance(preset[5])
			-- The most chunks that may be drawing plants, over viewer positions across a chunk.
			local most = 0
			for ix = 0, SIZE, 2 do
				for iz = 0, SIZE, 2 do
					local n = 0
					for key, level in LodTree.select(ix, iz) do
						local _, nx, nz = Coords.decodeNodeKey(key)
						if LodTree.drawsFoliage(level, nx, nz, ix, iz, true) then
							n += 1
						end
					end
					most = math.max(most, n)
				end
			end
			local worst = most * perChunk
			t.ok(worst <= DRAWN_PARTS, `{preset[1]}: {most} chunks, up to {math.floor(worst)} plant Parts`)
		end
		LodTree.configure(lod.ViewDistance, lod.SplitDistance, lod.SplitDistanceL1)
		LodTree.setFoliageDistance(lod.FoliageDistance)
		-- Measured on generated terrain around the densest biomes' samples: what is drawn there.
		for _, name in { "Meadow", "Plains" } do
			local index = (Biomes.byName(name) :: Biomes.Biome).index
			local sample = (samples[index] or {})[1]
			t.ok(sample ~= nil, `a {name} sample`)
			if sample then
				local x, z = sample[1] * SIZE + 8, sample[2] * SIZE + 8
				local drawn = 0
				for key, level in LodTree.select(x, z) do
					local _, nx, nz = Coords.decodeNodeKey(key)
					if LodTree.drawsFoliage(level, nx, nz, x, z) then
						local r = gen.generate(0, nx, nz)
						for y = r.solidBelow, r.emptyAbove - 1 do
							for lz = 0, SIZE - 1 do
								for lx = 0, SIZE - 1 do
									local block = ChunkLayout.get(r.data, lx, y, lz)
									if isPlant[block] and not Blocks.plantBottom(block) then
										drawn += parts(block)
									end
								end
							end
						end
					end
				end
				t.ok(drawn > 0 and drawn <= DRAWN_PARTS, `{name}: {drawn} plant Parts drawn`)
			end
		end
	end)

	t.test("foliage: the placement rules on flat test chunks", function()
		local jungle = (Biomes.byName("Jungle") :: Biomes.Biome).index
		local desert = (Biomes.byName("Desert") :: Biomes.Biome).index
		local tundra = (Biomes.byName("Tundra") :: Biomes.Biome).index
		-- Open grass: grass, ferns and their tall forms, whole, tops in cell 3.
		local open, top = grow(id.Grass, jungle, 16)
		t.ok((open[id.TallGrass] or 0) > 0 and open[id.TallGrass] == open[id.TallGrassTop], "tall grass, whole")
		t.ok((open[id.LargeFern] or 0) > 0 and open[id.LargeFern] == open[id.LargeFernTop], "large ferns, whole")
		t.eq(top, 4, "returned top")
		-- Leaves two above the ground: the tall plants become their single forms.
		local grown, low = grow(id.Grass, jungle, 16, id.JungleLeaves, 3)
		t.eq(grown[id.TallGrass], nil, "tall grass under low leaves")
		t.eq(grown[id.LargeFern], nil, "large ferns under low leaves")
		t.eq(grown[id.ShortGrass], (open[id.ShortGrass] or 0) + open[id.TallGrass], "tall grass became short grass")
		t.eq(grown[id.Fern], (open[id.Fern] or 0) + open[id.LargeFern], "large ferns became ferns")
		t.eq(low, 3, "returned top without tall plants")
		-- Anything right above the ground (a trunk, leaves, water, ice): nothing.
		for _, blocker in { id.JungleLog, id.JungleLeaves, Blocks.fluidId("Water", 0), id.Ice } do
			local none, nothing = grow(id.Grass, jungle, 4, blocker, 2)
			t.eq(next(none), nil, `plants under {Blocks.get(blocker).name}`)
			t.eq(nothing, 0, "returned top without plants")
		end
		-- Wrong ground: nothing (grass on sand, anything on stone).
		t.eq(next((grow(id.Sand, jungle, 4))), nil, "jungle plants on sand")
		t.eq(next((grow(id.Stone, jungle, 4))), nil, "plants on stone")
		-- Dead bushes do grow on sand; biomes without foliage grow nothing.
		t.ok(((grow(id.Sand, desert, 8))[id.DeadBush] or 0) > 0, "dead bushes on sand")
		t.eq(next((grow(id.Grass, tundra, 4))), nil, "plants in a biome without foliage")
		-- A buffer ending right above the plants: no room for tops, so single forms only.
		local data = flat(id.Grass)
		t.eq(place(data, 3, 0, 0, table.create(P * P, jungle), table.create(P * P, 1)), 3, "returned top")
		local singles = 0
		for i = 0, buffer.len(data) // 2 - 1 do
			local block = buffer.readu16(data, i * 2)
			t.ok(Blocks.otherHalf(block) == nil, "a tall plant at the buffer's top")
			if isPlant[block] then
				singles += 1
			end
		end
		t.ok(singles > 0, "single plants at the buffer's top")
	end)

	t.test("foliage: costs little generation time", function()
		local generateTime, placeTime = 0, 0
		for k = 1, 4 do
			local c = chunks[k]
			local best = math.huge
			for _ = 1, 2 do
				local t0 = os.clock()
				gen.generate(0, c.cx, c.cz)
				best = math.min(best, os.clock() - t0)
			end
			generateTime += best
			-- The same chunk without its plants, grown again from its columns.
			local bare = buffer.create(buffer.len(c.r.data))
			buffer.copy(bare, 0, c.r.data)
			for i = 0, buffer.len(bare) // 2 - 1 do
				if isPlant[buffer.readu16(bare, i * 2)] then
					buffer.writeu16(bare, i * 2, AIR)
				end
			end
			local biomes, tops = {}, {}
			for pz = 0, P - 1 do
				for px = 0, P - 1 do
					local h, biome = gen.column(c.cx * SIZE + px - 1, c.cz * SIZE + pz - 1)
					biomes[pz * P + px + 1], tops[pz * P + px + 1] = biome, h - 1
				end
			end
			local copy = buffer.create(buffer.len(bare))
			best = math.huge
			for _ = 1, 3 do
				buffer.copy(copy, 0, bare)
				local t0 = os.clock()
				place(copy, c.r.height, c.cx * SIZE, c.cz * SIZE, biomes, tops)
				best = math.min(best, os.clock() - t0)
			end
			placeTime += best
			t.eq(buffer.tostring(copy), buffer.tostring(c.r.data), "regrown plants match the generated ones")
		end
		t.ok(placeTime < 0.1 * generateTime, `plants cost {placeTime * 1000} ms of {generateTime * 1000} ms`)
	end)
end
