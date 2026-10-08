--[[
	/locate's searches (Generation/Locate, the generators' locate hooks): ids and tags (loose
	matching, snake case, tags expanding, unknown ids and tags), the ring search's answer against
	a brute force nearest over the generators' own rectangle queries for every kind on two seeds
	from two points each, the probes leaving the caches alone (StructureGen, Mineshafts, surface
	caves) and chunks byte for byte the same after a search, the world types that rule kinds
	out (Single Biome, no structures, Superflat: not found with no probe at all), the fixed
	layouts (Debug: All Structures, All Biomes), and the biome rings (the nearest sample of the
	grid, never more than about sqrt(2) times the first hit's ring).
]]

return function(t, shared, require, _server)
	local Biomes = require(shared.Biomes)
	local Locate = require(shared.Generation.Locate)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)
	local WorldTypes = require(shared.Generation.WorldTypes)
	local StructureGen = require(shared.Generation.StructureGen)
	local Mineshafts = require(shared.Generation.Mineshafts)
	local Library = require(shared.Structures.Library)

	local function biomeIndex(name: string): number
		return (Biomes.byName(name) :: any).index
	end

	-- Java's (a + b) / 2, as StructureGen centres a start piece.
	local function midpoint(a: number, b: number): number
		local s = a + b
		return if s >= 0 then s // 2 else -(-s // 2)
	end

	local function kindsOf(gen, ids: { string })
		local set = Locate.set(ids)
		local list = {}
		for _, kind in (gen.locateKinds :: any)() do
			if set[kind.id] then
				table.insert(list, kind)
			end
		end
		return list
	end

	local function hasKind(gen, id: string): boolean
		if gen.locateKinds == nil then
			return false
		end
		return #kindsOf(gen, { id }) > 0
	end

	--[[ Ids ]]

	t.test("locate: ids match loosely and show in snake case", function()
		t.eq(Locate.snake("BirchForest"), "birch_forest")
		t.eq(Locate.snake("OldGrowthTaiga"), "old_growth_taiga")
		t.eq(Locate.snake("outpost"), "outpost")
		t.eq(Locate.snake("Old Growth"), "old_growth")
		t.eq(Locate.key("minecraft:Birch_Forest"), "birchforest")
		t.eq(Locate.key("icevoxel:birch forest"), "birchforest")
		local biomes = Locate.biomeRegistry()
		t.eq(#biomes.ids, Biomes.count, "every biome")
		for _, typed in { "minecraft:birch_forest", "BirchForest", "birch forest", "BIRCH_FOREST" } do
			local resolved = Locate.resolve(biomes, typed)
			t.ok(resolved ~= nil, typed)
			t.eq((resolved :: any).members[1], "birch_forest", typed)
			t.eq((resolved :: any).label, "birch_forest")
		end
		local missing, problem = Locate.resolve(biomes, "ocean")
		t.eq(missing, nil)
		t.eq(problem, "id")
	end)

	t.test("locate: tags expand, answer with their member, unknown tags", function()
		local structures = Locate.structureRegistry({ "outpost" })
		local resolved = Locate.resolve(structures, "#mineshaft") :: any
		t.ok(resolved and resolved.tag, "a tag")
		t.eq(resolved.label, "#mineshaft")
		t.eq(table.concat(resolved.members, ","), "mineshaft,mineshaft_overgrown")
		t.eq(Locate.label(resolved, "mineshaft_overgrown"), "#mineshaft (mineshaft_overgrown)")
		local library = Locate.resolve(structures, "#minecraft:library") :: any
		t.eq(table.concat(library.members, ","), "outpost", "the library tag")
		local id = Locate.resolve(structures, "minecraft:outpost") :: any
		t.eq(Locate.label(id, "outpost"), "outpost", "an id's answer is the id")
		local none, problem = Locate.resolve(structures, "#village")
		t.eq(none, nil)
		t.eq(problem, "tag")
		-- Biome tags answer with or without "is_".
		local biomes = Locate.biomeRegistry()
		local forest = Locate.resolve(biomes, "#forest") :: any
		t.eq(forest.label, "#is_forest")
		t.ok(table.find(forest.members, "birch_forest") ~= nil)
		local snowy = Locate.resolve(biomes, "#is_snowy") :: any
		t.ok(table.find(snowy.members, "tundra") ~= nil and table.find(snowy.members, "frozen_peaks") ~= nil)
		t.ok(table.find(snowy.members, "desert") == nil)
		local peaks = Locate.resolve(biomes, "#band_peaks") :: any
		t.ok(table.find(peaks.members, "jagged_peaks") ~= nil, "a band's tag")
		-- A library structure named like a built-in kind is left out (the built-in wins).
		local clash = Locate.structureRegistry({ "Mineshaft", "outpost" })
		local count = 0
		for _, entry in clash.ids do
			if entry == "mineshaft" then
				count += 1
			end
		end
		t.eq(count, 1, "one mineshaft id")
	end)

	--[[ Exactness ]]

	-- The nearest (x, z) of `points` (flat x, z pairs) to (px, pz): its distance.
	local function nearestOf(points: { number }, px: number, pz: number): number
		local best = math.huge
		for i = 1, #points, 2 do
			best = math.min(best, math.sqrt((points[i] - px) ^ 2 + (points[i + 1] - pz) ^ 2))
		end
		return best
	end

	-- Every candidate position of kind `id` within `r` (per axis) of (px, pz), by brute force over
	-- the generator's rectangle queries.
	local function brute(gen, id: string, px: number, pz: number, r: number): { number }
		local x0, z0, x1, z1 = math.floor(px - r), math.floor(pz - r), math.ceil(px + r), math.ceil(pz + r)
		local out = {}
		local function add(x: number, z: number)
			table.insert(out, x)
			table.insert(out, z)
		end
		if id == "outpost" then
			for _, start in gen.structures(x0, z0, x1, z1) do
				if start.name == "outpost" then
					local box = start.pieces[1].box
					add(midpoint(box[1], box[4]), midpoint(box[3], box[6]))
				end
			end
		elseif id == "mineshaft" or id == "mineshaft_overgrown" or id == "mineshaft_entrance" then
			for _, plan in gen.mineshafts(x0, z0, x1, z1) do
				if id == "mineshaft_entrance" then
					local e = plan.entrance
					if e then
						add(e.x, e.z)
					end
				elseif plan.overgrown == (id == "mineshaft_overgrown") then
					local box = plan.pieces[1].box
					add((box[1] + box[4]) // 2, (box[3] + box[6]) // 2)
				end
			end
		elseif id == "oil_geyser" or id == "oil_deposit" then
			for _, well in gen.oilWells(x0, z0, x1, z1) do
				if id == "oil_deposit" or well.geyser then
					add(well.x, well.z)
				end
			end
		elseif id == "lava_lake" then
			for _, lake in gen.lavaLakes(x0, z0, x1, z1) do
				add(lake.x + 8, lake.z + 8)
			end
		elseif id == "lake" then
			for _, lake in gen.waterLakes(x0, z0, x1, z1) do
				add(lake.x + 8, lake.z + 8)
			end
		elseif id == "cave_entrance" then
			for _, worm in gen.surfaceCaves.worms(x0, z0, x1, z1) do
				if worm.kind == "entrance" then
					add(math.floor(worm.startX), math.floor(worm.startZ))
				end
			end
		elseif id == "ravine" then
			for _, worm in gen.surfaceCaves.worms(x0, z0, x1, z1) do
				if worm.kind == "ravine" then
					-- (Its step nearest the player, as the search answers.)
					local best, at = math.huge, 1
					for i = 1, worm.count do
						local d = (worm.x[i] - px) ^ 2 + (worm.z[i] - pz) ^ 2
						if d < best then
							best, at = d, i
						end
					end
					add(math.floor(worm.x[at]), math.floor(worm.z[at]))
				end
			end
		end
		return out
	end

	local KINDS = {
		"outpost",
		"mineshaft",
		"mineshaft_overgrown",
		"mineshaft_entrance",
		"oil_geyser",
		"oil_deposit",
		"lava_lake",
		"lake",
		"cave_entrance",
		"ravine",
	}

	for _, seed in { 12345, 7 } do
		t.test(`locate: every kind's answer is the brute force nearest (seed {seed})`, function()
			local gen = TerrainGenerator.new(seed)
			for _, point in { { 0, 0 }, { 3000, -2000 } } do
				local px, pz = point[1], point[2]
				for _, id in KINDS do
					local stats = { probes = 0, verified = 0 }
					local found = Locate.nearest(kindsOf(gen, { id }), px, pz, nil, stats)
					t.ok(found ~= nil, `{id} from {px}, {pz}: found`)
					local f = found :: any
					t.eq(f.id, id)
					-- (Ravines and entrances answer a part up to their reach away from the probe.)
					local d = nearestOf(brute(gen, id, px, pz, f.distance + 2), px, pz)
					t.near(f.distance, d, 1e-6, `{id} from {px}, {pz}: the nearest`)
					t.near(math.sqrt((f.x - px) ^ 2 + (f.z - pz) ^ 2), f.distance, 1e-6, "its distance")
					t.ok(stats.probes > 0, "probed")
				end
			end
		end)
	end

	t.test("locate: a tag's search shares the best distance and answers the nearest member", function()
		local gen = TerrainGenerator.new(12345)
		local alone = Locate.nearest(kindsOf(gen, { "mineshaft" }), 3000, -2000) :: any
		local overgrown = Locate.nearest(kindsOf(gen, { "mineshaft_overgrown" }), 3000, -2000) :: any
		local stats = { probes = 0, verified = 0 }
		local both =
			Locate.nearest(kindsOf(gen, { "mineshaft", "mineshaft_overgrown" }), 3000, -2000, nil, stats) :: any
		local nearest = if alone.distance <= overgrown.distance then alone else overgrown
		t.eq(both.id, nearest.id)
		t.near(both.distance, nearest.distance, 1e-9)
	end)

	--[[ Purity ]]

	t.test("locate: probes leave the caches alone; chunks stay byte for byte the same", function()
		local seed = 4242
		local library = Library.load()
		local plains = biomeIndex("Plains")
		local placer = StructureGen.new(seed, library, {
			firstFreeHeight = function(): number
				return 70
			end,
			biome = function(): number
				return plains
			end,
			land = function(): boolean
				return true
			end,
		})
		local passed = nil
		for rx = -10, 10 do
			for rz = -10, 10 do
				local x = placer.probe(1, rx, rz)
				if x and passed == nil then
					passed = { rx, rz }
				end
			end
		end
		t.eq(placer.assembled(), 0, "441 probes assembled nothing")
		t.ok(passed ~= nil, "a start passes on flat plains")
		local start = placer.assembleAt(1, (passed :: any)[1], (passed :: any)[2])
		t.ok(start ~= nil, "it assembles")
		t.eq(placer.assembled(), 1, "the verify is the one assembly")

		local jungle = biomeIndex("Jungle")
		local mines = Mineshafts.new(seed, {
			height = function(): number
				return 120
			end,
			biome = function(): number
				return jungle
			end,
		})
		local cell = nil
		for gx = -10, 10 do
			for gz = -10, 10 do
				local x = mines.candidate(gx, gz)
				if x and cell == nil then
					cell = { gx, gz }
				end
			end
		end
		t.eq(mines.built(), 0, "441 candidates built no plan")
		t.ok(mines.planAt((cell :: any)[1], (cell :: any)[2]) ~= nil, "a plan")
		t.eq(mines.built(), 1, "the verify built one")

		local gen = TerrainGenerator.new(12345)
		local before = gen.generate(0, 3, -2).data
		local worms = gen.surfaceCaves.built()
		for gx = -20, 20 do
			gen.surfaceCaves.start("entrance", gx, 0)
			gen.surfaceCaves.start("ravine", gx, 0)
		end
		t.eq(gen.surfaceCaves.built(), worms, "surface caves' probes build no worm")
		for _, id in KINDS do
			Locate.nearest(kindsOf(gen, { id }), 9000, 9000)
		end
		t.eq(buffer.tostring(gen.generate(0, 3, -2).data), buffer.tostring(before), "the same chunk after searches")
		t.eq(
			buffer.tostring(TerrainGenerator.new(12345).generate(0, 3, -2).data),
			buffer.tostring(before),
			"and as a fresh generator makes it"
		)
	end)

	--[[ World types ]]

	t.test("locate: world types that can't have a kind leave it out (no probe at all)", function()
		local desert = TerrainGenerator.new(12345, { biome = biomeIndex("Desert") })
		t.ok(not hasKind(desert, "outpost"), "no outposts in a desert")
		t.ok(not hasKind(desert, "mineshaft_overgrown"), "no overgrown mineshafts in a dry biome")
		t.ok(not hasKind(desert, "mineshaft_entrance"), "nor their entrances")
		t.ok(hasKind(desert, "mineshaft") and hasKind(desert, "lava_lake"), "the rest")
		t.eq(table.concat(desert.biomes :: any, ","), tostring(biomeIndex("Desert")), "one biome")
		local tundra = TerrainGenerator.new(12345, { biome = biomeIndex("Tundra") })
		t.ok(not hasKind(tundra, "lava_lake"), "no lava lakes in a frozen biome")

		local bare = TerrainGenerator.new(12345, { structures = false })
		for _, id in { "outpost", "mineshaft", "mineshaft_overgrown", "mineshaft_entrance" } do
			t.ok(not hasKind(bare, id), `{id}: none without structures`)
		end
		t.ok(hasKind(bare, "oil_geyser") and hasKind(bare, "ravine"), "terrain features stay")

		local flat = WorldTypes.create("superflat", 1, {})
		t.eq(flat.locateKinds, nil, "a flat world has no kinds")
		local stats = { probes = 0, verified = 0 }
		local plains =
			Locate.biome(flat.column, Locate.biomeSet({ "plains" }), flat.biomes, 10, -20, 6400, 32, nil, stats)
		t.ok(plains ~= nil, "its biome")
		t.eq((plains :: any).distance, 0, "where the player stands")
		t.eq((plains :: any).id, "plains")
		stats = { probes = 0, verified = 0 }
		t.eq(Locate.biome(flat.column, Locate.biomeSet({ "desert" }), flat.biomes, 0, 0, 6400, 32, nil, stats), nil)
		t.eq(stats.probes, 0, "another biome: no sample")
	end)

	t.test("locate: Debug All Structures lists its structures; All Biomes has every biome near", function()
		local gen = WorldTypes.create("debugStructures", 1, {})
		local list = (gen.locateList :: any)()
		local ids = {}
		for _, thing in list do
			ids[thing.id] = true
		end
		for _, id in { "outpost", "mineshaft", "mineshaft_overgrown", "mineshaft_entrance" } do
			t.ok(ids[id], `{id} listed`)
		end
		local found = Locate.nearestListed(list, Locate.set({ "mineshaft", "mineshaft_overgrown" }), 0, 0) :: any
		t.ok(found and found.showY, "a mineshaft, with its y")

		local biomes = WorldTypes.create("debugBiomes", 1, {})
		-- (Strips 16 wide: the search samples them at a quarter of the step: its climate scale.)
		t.ok((biomes.climateScale or 1) < 1, "narrow biomes")
		local scale = math.clamp(biomes.climateScale or 1, 0.25, 2)
		for _, biome in Biomes.list do
			local id = Locate.snake(biome.name)
			local at =
				Locate.biome(biomes.column, Locate.biomeSet({ id }), biomes.biomes, 5, 5, 6400 * scale, 32 * scale)
			t.ok(at ~= nil and (at :: any).distance <= 16 * Biomes.count, `{id} near`)
		end
	end)

	--[[ Biome rings ]]

	t.test("locate: the biome search answers the grid's nearest sample within sqrt(2) rings", function()
		local gen = TerrainGenerator.new(12345)
		for _, name in { "Jungle", "Desert", "Plains" } do
			local set = Locate.biomeSet({ Locate.snake(name) })
			local stats = { probes = 0, verified = 0 }
			local found = Locate.biome(gen.column, set, gen.biomes, 100, -50, 6400, 32, nil, stats) :: any
			t.ok(found ~= nil, name)
			-- Brute force over every sample out to the found distance.
			local reach = math.ceil(found.distance / 32) + 1
			local best, firstRing = math.huge, math.huge
			for j = -reach, reach do
				for i = -reach, reach do
					local _, biome = gen.column(100 + i * 32, -50 + j * 32)
					if set[biome] then
						best = math.min(best, 32 * math.sqrt(i * i + j * j))
						firstRing = math.min(firstRing, math.max(math.abs(i), math.abs(j)))
					end
				end
			end
			t.near(found.distance, best, 1e-9, `{name}: the nearest sample`)
			t.ok((found.x - 100) % 32 == 0 and (found.z + 50) % 32 == 0, "on the grid")
			local rings = math.ceil(math.sqrt(2) * firstRing) + 1
			t.ok(stats.probes <= (2 * rings + 1) ^ 2, `{name}: {stats.probes} samples for first ring {firstRing}`)
			local _, at = gen.column(found.x, found.z)
			t.eq(Locate.snake(Biomes.list[at].name), found.id)
			t.eq(found.y, (gen.column(found.x, found.z)), "the surface's height")
		end
		-- A biome the generator can't have fails at once.
		local single = TerrainGenerator.new(12345, { biome = biomeIndex("Plains") })
		local stats = { probes = 0, verified = 0 }
		t.eq(Locate.biome(single.column, Locate.biomeSet({ "jungle" }), single.biomes, 0, 0, 6400, 32, nil, stats), nil)
		t.eq(stats.probes, 0)
	end)

	t.test("locate: yield follows every probe and verify", function()
		local gen = TerrainGenerator.new(12345)
		local yields = 0
		local stats = { probes = 0, verified = 0 }
		Locate.nearest(kindsOf(gen, { "mineshaft_entrance" }), 3000, -2000, function()
			yields += 1
		end, stats)
		t.ok(
			yields >= stats.probes + stats.verified,
			`{yields} yields for {stats.probes} probes, {stats.verified} verifies`
		)
	end)
end
