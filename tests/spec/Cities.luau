--[[
	Overgrown cities and the roads between them (Generation/Cities, CityLayout, Roads): where they
	stand (density on three seeds, small towns, each in its cell), the roads linking them (graded,
	pinned to the plateaus, inside their corridor); determinism (any chunk order, yields, a second
	generator, with or without `prepare`, levels 0-4) and padding equal to the neighbour's core;
	solidBelow, emptyAbove and structureSpan; the raw invariant (outside `blocked` the relief and the
	surface are the raw terrain's; `protects` inside it); the cost against plain chunks, every
	downtown's meshing against tests/bench's plain chunks, the cache counter after `prepare`, a cold
	`prepare`, and the yield stretches of a map tile, the spawn search and a city's chunks at levels
	0-4; the map's squares and lines; nothing of the planners (lakes, wells, lava lakes, puddles,
	mineshaft entrances, outposts) on a city or road, no surface cave cutting a street or a lot, no
	tree on a lot or asphalt; loot (Antibiotics in a big city, a Medicine Cabinet in every town);
	the ruins' overgrowth holding (vines, carpets, plants); the bunker sheds; the switches; far
	levels (and lots' tops worked out without planning them).
]]

return function(t, shared, require, server)
	local Config = require(shared.Config)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Relief = require(shared.Generation.Relief)
	local Roads = require(shared.Generation.Roads)
	local CityLayout = require(shared.Generation.CityLayout)
	local Cities = require(shared.Generation.Cities)
	local ScavengeLoot = require(shared.Generation.ScavengeLoot)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)
	local MapPainter = require(shared.Map.MapPainter)
	local Locate = require(shared.Generation.Locate)
	local Ores = require(shared.Generation.Ores)
	local Lava = require(shared.Generation.Lava)
	local Lakes = require(shared.Generation.Lakes)
	local Biomes = require(shared.Biomes)

	local SIZE = ChunkLayout.SIZE
	local P = ChunkLayout.PADDED
	local LAYER = ChunkLayout.LAYER
	local SEA = Config.SeaLevel
	local B = Blocks.id
	local AIR, CAVE_AIR, STONE = Blocks.AIR, Blocks.CAVE_AIR, B.Stone
	local readu16, readu8 = buffer.readu16, buffer.readu8
	local cfg = Config.Cities
	local MARGIN = cfg.Margin
	local SEED = 99

	-- Every TerrainGenerator.new makes its cities through Cities.new: keep the last one made.
	local made: any = nil
	local originalNew = Cities.new
	Cities.new = function(...)
		local c = originalNew(...)
		made = c
		return c
	end
	local function generator(seed: number, options: any?): (any, any)
		local gen = TerrainGenerator.new(seed, options)
		return gen, made
	end

	local gen, cities = generator(SEED)
	local plain = TerrainGenerator.new(SEED, { ruins = false })
	local raw = Relief.new(SEED)

	-- Ores and stone varieties only in each chunk's own core; twins in the padding may differ.
	local rockLike: { [number]: boolean } = { [STONE] = true }
	for _, ore in Ores.FEATURES do
		rockLike[ore.block] = true
	end
	local isFluid: { [number]: boolean } = {}
	local isLog: { [number]: boolean } = {}
	for id = 0, Blocks.count - 1 do
		local def = Blocks.get(id)
		isFluid[id] = def.fluid ~= nil
		isLog[id] = string.find(def.name, "Log") ~= nil
	end
	local function norm(id: number): number
		if rockLike[id] then
			return STONE
		elseif Blocks.isCaveTwin(id) and not isFluid[id] then
			return CAVE_AIR
		end
		return id
	end
	local function at(r: any, px: number, y: number, pz: number): number
		if y >= r.height or y < 0 then
			return AIR
		end
		return readu16(r.data, ((y * P + pz) * P + px) * 2)
	end

	local caches: { [any]: { [string]: any } } = {}
	local function chunk(g: any, cx: number, cz: number): any
		local cache = caches[g]
		if cache == nil then
			cache = {}
			caches[g] = cache
		end
		local key = `{cx},{cz}`
		local r = cache[key]
		if r == nil then
			r = g.generate(0, cx, cz, nil, true)
			cache[key] = r
		end
		return r
	end
	local function blockAt(g: any, x: number, y: number, z: number): number
		local r = chunk(g, x // SIZE, z // SIZE)
		if y < 0 then
			return B.Bedrock
		elseif y >= r.height then
			return AIR
		end
		return ChunkLayout.get(r.data, x % SIZE, y, z % SIZE)
	end

	-- The sites near the origin: a big city (with a downtown), a small town; a road between cities.
	local AREA = 8000
	local all = gen.cities(-AREA, -AREA, AREA, AREA)
	local function nearest(want: (any) -> boolean): any
		local best, bestD = nil, math.huge
		for _, site in all do
			local d = site.x * site.x + site.z * site.z
			if want(site) and d < bestD then
				best, bestD = site, d
			end
		end
		return best
	end
	local BIG = nearest(function(site)
		return site.radius >= 160
	end)
	local TOWN = nearest(function(site)
		return site.radius < 64
	end)
	assert(BIG and TOWN, "a big city and a town near the origin")
	local planBig = cities.planAt(BIG.x, BIG.z)
	-- A road segment far from every city (its middle), for the road chunks.
	local ROAD: any = nil
	for _, segment in gen.roads(BIG.x - 3000, BIG.z - 3000, BIG.x + 3000, BIG.z + 3000) do
		local mx, mz = (segment.x0 + segment.x1) / 2, (segment.z0 + segment.z1) / 2
		local clear = true
		for _, site in all do
			if math.max(math.abs(mx - site.x), math.abs(mz - site.z)) < site.radius + MARGIN + 200 then
				clear = false
				break
			end
		end
		if clear then
			ROAD = { x = math.floor(mx), z = math.floor(mz), segment = segment }
			break
		end
	end
	assert(ROAD, "a road between the cities")
	print(
		`    big city at {BIG.x}, {BIG.z} (R {BIG.radius}, plateau {BIG.y}), town at {TOWN.x}, {TOWN.z} (R {TOWN.radius}), a road at {ROAD.x}, {ROAD.z}`
	)

	-- The chunks over a site's middle (n x n) and over the road.
	local function chunksAround(x: number, z: number, n: number): { { number } }
		local out = {}
		for dz = -(n // 2), (n + 1) // 2 - 1 do
			for dx = -(n // 2), (n + 1) // 2 - 1 do
				table.insert(out, { x // SIZE + dx, z // SIZE + dz })
			end
		end
		return out
	end
	local downtown = chunksAround(BIG.x, BIG.z, 4)
	local roadChunks = chunksAround(ROAD.x, ROAD.z, 2)

	--[[ Where cities stand ]]

	t.test(
		"cities: 6-12 sites per 100 km² over 20 km squares on three seeds, mostly towns, each in its cell",
		function()
			for _, seed in { 12345, 1, 99 } do
				local g = TerrainGenerator.new(seed)
				local R = 10000
				local count, small = 0, 0
				for _, site in g.cities(-R, -R, R - 1, R - 1) do
					if site.x >= -R and site.x < R and site.z >= -R and site.z < R then
						count += 1
						if site.radius < 128 then
							small += 1
						end
					end
					-- The footprint and its margin stay in the site's cell (a column's city is its cell's).
					local m = site.radius + MARGIN
					t.ok(site.x - m >= site.gx * cfg.Grid and site.x + m < (site.gx + 1) * cfg.Grid, "in its cell (x)")
					t.ok(site.z - m >= site.gz * cfg.Grid and site.z + m < (site.gz + 1) * cfg.Grid, "in its cell (z)")
					t.ok(site.y >= SEA + cfg.MinAboveSea, "above the sea")
					t.eq((site.radius - 3) % 32, 0, "starts and ends on a street")
				end
				local per = count / 4
				print(`    seed {seed}: {count} sites in 400 km² ({per} per 100 km²), {small} under 128 blocks`)
				t.ok(per >= 6 and per <= 12, `seed {seed}: {per} per 100 km²`)
				t.ok(small > count / 2, "most are towns")
			end
		end
	)

	t.test("roads: they link most cities with a neighbour within LinkCells cells, graded and pinned", function()
		local roads = cfg.Roads
		for _, seed in { 12345, 99 } do
			local g = TerrainGenerator.new(seed)
			local R = 6000
			local sites = g.cities(-R, -R, R, R)
			local segments = g.roads(-R - 3000, -R - 3000, R + 3000, R + 3000)
			local withNeighbour, linked = 0, 0
			for _, site in sites do
				local has = false
				for _, other in sites do
					if
						other ~= site
						and math.max(math.abs(other.gx - site.gx), math.abs(other.gz - site.gz)) <= roads.LinkCells
						and math.sqrt((other.x - site.x) ^ 2 + (other.z - site.z) ^ 2) <= roads.LinkCells * cfg.Grid
					then
						has = true
					end
				end
				if has then
					withNeighbour += 1
					-- A road starts at a gate on the footprint's side.
					for _, s in segments do
						local d0 = math.max(math.abs(s.x0 - site.x), math.abs(s.z0 - site.z))
						local d1 = math.max(math.abs(s.x1 - site.x), math.abs(s.z1 - site.z))
						if math.abs(d0 - site.radius) < 1e-6 or math.abs(d1 - site.radius) < 1e-6 then
							linked += 1
							break
						end
					end
				end
			end
			print(`    seed {seed}: {linked} of {withNeighbour} cities with a neighbour have a road`)
			t.ok(withNeighbour > 5 and linked >= 0.6 * withNeighbour, `seed {seed}: roads link most cities`)
			-- (Vertices are Step apart along the curve, the last up to 1.25 Step: no chord longer.)
			for _, s in segments do
				t.ok(math.abs(s.y1 - s.y0) <= 1.25 * roads.Step * roads.MaxGrade + 1e-6, "graded")
				t.ok(s.y0 >= SEA + 1 - 1e-6, "dry")
			end
		end
	end)

	t.test("roads: a plan keeps to its corridor and grade, pinned to both plateaus, the same twice", function()
		local roads = cfg.Roads
		local function sample(x: number, z: number): (number, number, number)
			return 90 + 12 * math.sin(x / 140) + 8 * math.cos(z / 90), 0.3, 0
		end
		local a = Roads.plan(1234567, 100, 200, 85, 1700, 900, 96, sample)
		local b = Roads.plan(1234567, 100, 200, 85, 1700, 900, 96, sample)
		t.eq(a.count, b.count, "deterministic")
		t.ok(not a.rejected, `kept ({a.reason})`)
		t.eq(a.x[1], 100)
		t.eq(a.z[1], 200)
		t.eq(a.x[a.count], 1700)
		t.eq(a.z[a.count], 900)
		local dx, dz = 1600, 700
		local length = math.sqrt(dx * dx + dz * dz)
		for i = 1, a.count do
			t.eq(a.y[i], b.y[i], "deterministic")
			-- Inside the hull of the control points: within Wobble of the gates' line.
			local off = math.abs((a.x[i] - 100) * dz - (a.z[i] - 200) * dx) / length
			t.ok(off <= roads.Wobble + 1e-6, `vertex {i} off the line by {off}`)
			if i > 1 then
				local step = a.s[i] - a.s[i - 1]
				t.ok(step <= roads.Step + 1e-6 and step > 0, "resampled every Step")
				t.ok(math.abs(a.y[i] - a.y[i - 1]) <= step * roads.MaxGrade + 1e-9, "the slope clamp")
			end
		end
		t.near(a.y[1], 85, 1e-9, "pinned to gate a's plateau")
		t.near(a.y[a.count], 96, 1e-9, "pinned to gate b's plateau")
		-- Over the sea for longer than MaxWater: dropped.
		local wet = Roads.plan(7, 0, 0, 80, 1000, 0, 80, function(x: number): (number, number, number)
			return if x > 300 and x < 500 then 40 else 80, if x > 300 and x < 500 then 0.5 else 0.3, 0
		end)
		t.ok(wet.rejected and wet.reason == "water", "a long crossing is dropped")
		-- The corridor geometry.
		t.ok(Roads.touches(0, 0, 100, 0, 10, 50, 5, 60, 20), "touches a rectangle near its side")
		t.ok(not Roads.touches(0, 0, 100, 0, 10, 50, 30, 60, 40), "misses one further off")
		local boxes = {}
		Roads.boxes(0, 0, 100, 37, 12, -1000, -1000, 1000, 1000, boxes)
		for x = -20, 120, 3 do
			for z = -20, 60, 3 do
				local d2 = Roads.segmentDistance2(x, z, 0, 0, 100, 37)
				if d2 <= 144 then
					local inside = false
					for i = 1, #boxes, 4 do
						if x >= boxes[i] and x <= boxes[i + 2] and z >= boxes[i + 1] and z <= boxes[i + 3] then
							inside = true
						end
					end
					t.ok(inside, `{x}, {z} covered by the corridor's boxes`)
				end
			end
		end
	end)

	--[[ Determinism, padding, contracts ]]

	local function sameChunk(a: any, b: any, what: string)
		t.eq(a.height, b.height, `{what} height`)
		t.eq(a.solidBelow, b.solidBelow, `{what} solidBelow`)
		t.eq(a.emptyAbove, b.emptyAbove, `{what} emptyAbove`)
		t.ok(buffer.tostring(a.data) == buffer.tostring(b.data), `{what} data`)
	end

	t.test("cities: the same chunks in any order, a yield at a time, on a second generator, prepared or not", function()
		local nodes: { { number } } = {}
		for level = 0, cfg.LodLevels do
			local span = SIZE * 2 ^ level
			for _, p in { { BIG.x, BIG.z }, { BIG.x + BIG.radius, BIG.z + BIG.radius // 2 }, { ROAD.x, ROAD.z } } do
				table.insert(nodes, { level, p[1] // span, p[2] // span })
			end
		end
		local first = {}
		for i, n in nodes do
			first[i] = gen.generate(n[1], n[2], n[3])
		end
		-- A fresh generator, the nodes the other way round, a yield between every step.
		local second = TerrainGenerator.new(SEED)
		local yields = 0
		for i = #nodes, 1, -1 do
			local n = nodes[i]
			sameChunk(
				second.generate(n[1], n[2], n[3], function()
					yields += 1
				end),
				first[i],
				`L{n[1]} {n[2]},{n[3]} reversed with yields`
			)
		end
		t.ok(yields > #nodes, "yielded")
		-- Another, every node prepared first (as the map and the spawn search do).
		local third = TerrainGenerator.new(SEED)
		for i, n in nodes do
			local span = SIZE * 2 ^ n[1]
			third.prepare(n[2] * span - 600, n[3] * span - 600, n[2] * span + span + 600, n[3] * span + span + 600)
			sameChunk(third.generate(n[1], n[2], n[3]), first[i], `L{n[1]} {n[2]},{n[3]} prepared`)
		end
	end)

	t.test("cities: a chunk's padding equals its neighbour's core at levels 0-4", function()
		-- Far levels lower their padding's top terrain cell (TerrainGenerator's skirt, which moves
		-- a street's top block down a cell too): there only the buildings' cells above the
		-- plateau's ground are compared (full detail: every cell).
		local building: { [number]: boolean } = {}
		for _, name in
			{
				"Concrete",
				"CrackedConcrete",
				"MossyConcrete",
				"Brick",
				"CrackedBricks",
				"MossyBricks",
				"StoneBricks",
				"SmoothStone",
				"Planks",
				"Glass",
			}
		do
			building[B[name]] = true
		end
		local bad, compared = 0, 0
		for level = 0, cfg.LodLevels do
			local span = SIZE * 2 ^ level
			local _, stepY = ChunkLayout.steps(level)
			-- (The first cell whose sample block is at or above the plateau's first air.)
			local fromY = if level == 0 then 0 else (BIG.y - stepY // 2 + stepY - 1) // stepY
			local places = { { BIG.x, BIG.z }, { BIG.x - BIG.radius // 2, BIG.z + BIG.radius // 3 } }
			if level == 0 then
				table.insert(places, { ROAD.x, ROAD.z })
			end
			for _, p in places do
				local nx, nz = p[1] // span, p[2] // span
				local a = gen.generate(level, nx, nz)
				local bx = gen.generate(level, nx + 1, nz)
				local bz = gen.generate(level, nx, nz + 1)
				local top = math.max(a.height, bx.height, bz.height)
				for y = fromY, top - 1 do
					for k = 1, SIZE do
						local pairs = {
							{ at(a, P - 1, y, k), at(bx, 1, y, k) },
							{ at(bx, 0, y, k), at(a, SIZE, y, k) },
							{ at(a, k, y, P - 1), at(bz, k, y, 1) },
							{ at(bz, k, y, 0), at(a, k, y, SIZE) },
						}
						for _, pair in pairs do
							if level == 0 or building[pair[1]] or building[pair[2]] then
								compared += 1
								if norm(pair[1]) ~= norm(pair[2]) then
									bad += 1
								end
							end
						end
					end
				end
			end
		end
		print(`    {compared} border cells compared`)
		t.ok(compared > 20000, "compared")
		t.eq(bad, 0, "padding cells that differ from the neighbour's core")
	end)

	t.test("cities: solidBelow and emptyAbove hold; structureSpan covers every building block", function()
		local cull = Blocks.cullLutHiddenCaves
		local cityBlock: { [number]: boolean } = {}
		for _, name in
			{
				"Concrete",
				"CrackedConcrete",
				"MossyConcrete",
				"Brick",
				"CrackedBricks",
				"MossyBricks",
				"StoneBricks",
				"SmoothStone",
				"Glass",
				"Planks",
				"Ladder",
				"LadderSouth",
				"Chest",
				"SupplyCrate",
				"MedicineCabinet",
				"MossCarpet",
				"Cobweb",
			}
		do
			cityBlock[B[name]] = true
		end
		local covered = 0
		for _, c in downtown do
			local r = chunk(gen, c[1], c[2])
			for y = 0, r.solidBelow - 1 do
				for i = 0, LAYER - 1 do
					t.ok(readu8(cull, readu16(r.data, (y * LAYER + i) * 2)) == 1, "solidBelow")
				end
			end
			for y = r.emptyAbove, r.height - 1 do
				for i = 0, LAYER - 1 do
					t.eq(readu16(r.data, (y * LAYER + i) * 2), AIR, "emptyAbove")
				end
			end
			local span = r.structureSpan
			t.ok(span ~= nil, "a span")
			for y = BIG.y, r.height - 1 do
				for i = 0, LAYER - 1 do
					if cityBlock[readu16(r.data, (y * LAYER + i) * 2)] then
						covered += 1
						t.ok(y >= span[1] and y <= span[2], `building block at {y} inside the span`)
					end
				end
			end
		end
		t.ok(covered > 1000, "buildings downtown")
	end)

	--[[ The raw invariant ]]

	t.test("cities: outside `blocked` the relief and the surface are the raw terrain's; protects inside it", function()
		local half = 2048
		local x0, z0 = BIG.x - half, BIG.z - half
		local boxes = cities.blocked(x0, z0, x0 + 2 * half - 1, z0 + 2 * half - 1)
		-- Which 32 block squares the boxes cover (they are 32-aligned).
		local inside: { [number]: boolean } = {}
		for i = 1, #boxes, 4 do
			for gz = boxes[i + 1] // 32, boxes[i + 3] // 32 do
				for gx = boxes[i] // 32, boxes[i + 2] // 32 do
					inside[gx * 65536 + gz] = true
				end
			end
		end
		local outside, differ, protected = 0, 0, 0
		for z = z0, z0 + 2 * half - 1, 13 do
			for x = x0, x0 + 2 * half - 1, 13 do
				local inBox = inside[(x // 32) * 65536 + z // 32] == true
				local y0 = raw.height(x, z, 0)
				local y2, u2, s2, r2 = raw.height(x, z, 2)
				local w0 = cities.relief.height(x, z, 0)
				if inBox then
					if w0 ~= y0 then
						differ += 1
					end
				else
					outside += 1
					local w2, wu, ws, wr = cities.relief.height(x, z, 2)
					t.eq(w0, y0, `relief at {x}, {z}`)
					t.ok(w2 == y2 and wu == u2 and ws == s2 and wr == r2, "relief at level 2")
					t.eq((cities.surface(x, z, math.floor(y0), 0)), nil, `surface at {x}, {z}`)
					t.ok(not cities.protects(x, z), `protects at {x}, {z} outside blocked`)
				end
				if cities.protects(x, z) then
					protected += 1
				end
			end
		end
		print(
			`    {outside} columns outside the blocked boxes, {differ} inside them cut or filled, {protected} protected`
		)
		t.ok(outside > 10000 and differ > 100 and protected > 100, "both kinds sampled")
		-- The generator's columns agree with a world without ruins out there too.
		for k = 0, 199 do
			local x, z = x0 + (k * 7919) % (2 * half), z0 + (k * 104729) % (2 * half)
			if not inside[(x // 32) * 65536 + z // 32] then
				local h1, b1, v1, s1 = gen.column(x, z)
				local h2, b2, v2, s2 = plain.column(x, z)
				t.ok(h1 == h2 and b1 == b2 and v1 == v2 and s1 == s2, `column {x}, {z}`)
			end
		end
	end)

	--[[ Cost ]]

	-- Generation time of `list` (level, x, z) on generator g, per node.
	local function timed(g: any, list: { { number } }): number
		local s = os.clock()
		for _, n in list do
			g.generate(n[1], n[2], n[3])
		end
		return (os.clock() - s) / #list
	end
	-- Best of `rounds` for two generators taking turns (a busy machine slows both alike).
	local function compare(a: any, b: any, list: { { number } }, rounds: number): (number, number)
		local ta, tb = math.huge, math.huge
		for round = 1, rounds do
			if round % 2 == 1 then
				ta = math.min(ta, timed(a, list))
				tb = math.min(tb, timed(b, list))
			else
				tb = math.min(tb, timed(b, list))
				ta = math.min(ta, timed(a, list))
			end
		end
		return ta, tb
	end

	t.test("cities: cost against plain chunks (full detail, far levels, chunks away from cities)", function()
		local with = TerrainGenerator.new(SEED)
		local without = TerrainGenerator.new(SEED, { ruins = false })
		with.findSpawn()
		without.findSpawn()
		local function nodes(level: number, x: number, z: number, n: number): { { number } }
			local span = SIZE * 2 ^ level
			local out = {}
			for dz = 0, n - 1 do
				for dx = 0, n - 1 do
					table.insert(out, { level, x // span + dx - n // 2, z // span + dz - n // 2 })
				end
			end
			return out
		end
		local full = nodes(0, BIG.x, BIG.z, 4)
		local a, b = compare(with, without, full, 6)
		print(string.format("    downtown full detail: %.2f ms with, %.2f ms without", a * 1000, b * 1000))
		t.ok(a < b * 1.6 + 0.003, "full detail city chunks: x 1.6 + 3 ms")
		local near = {}
		for _, n in nodes(1, BIG.x, BIG.z, 3) do
			table.insert(near, n)
		end
		for _, n in nodes(2, BIG.x, BIG.z, 2) do
			table.insert(near, n)
		end
		a, b = compare(with, without, near, 6)
		print(string.format("    levels 1-2 over it: %.2f ms with, %.2f ms without", a * 1000, b * 1000))
		t.ok(a < b * 1.3 + 0.003, "levels 1-2: x 1.3 + 3 ms")
		local far = {}
		for _, n in nodes(3, BIG.x, BIG.z, 2) do
			table.insert(far, n)
		end
		for _, n in nodes(4, BIG.x, BIG.z, 1) do
			table.insert(far, n)
		end
		a, b = compare(with, without, far, 6)
		print(string.format("    levels 3-4 over it: %.2f ms with, %.2f ms without", a * 1000, b * 1000))
		t.ok(a < b * 1.2 + 0.002, "levels 3-4: x 1.2 + 2 ms")
		-- Plain chunks in a world with cities: away from every city and road (nothing blocked).
		local cx, cz = nil, nil
		for k = 0, 40 do
			local x, z = BIG.x + 900 + k * 97, BIG.z - 2000 + k * 131
			if #cities.blocked(x - 200, z - 200, x + 200, z + 200) == 0 then
				cx, cz = x, z
				break
			end
		end
		t.ok(cx ~= nil, "plain ground near the city")
		local plainNodes = nodes(0, cx :: number, cz :: number, 4)
		for level = 1, 4 do
			for _, n in nodes(level, cx :: number, cz :: number, 1) do
				table.insert(plainNodes, n)
			end
		end
		a, b = compare(with, without, plainNodes, 8)
		print(string.format("    plain chunks with cities on: %.2f ms, off: %.2f ms", a * 1000, b * 1000))
		t.ok(a < b * 1.05 + 0.0005, "plain chunks: x 1.05 + 0.5 ms")
	end)

	t.test("cities: every downtown meshes into at most 2.5 times the bench's plain chunks", function()
		local GreedyMesher = require(shared.Meshing.GreedyMesher)
		local QuadMesher = require(shared.Meshing.QuadMesher)
		-- Parts, quads and meshing time a chunk (tests/bench's way: plants left out; generated
		-- first, so only the meshing is timed).
		local function meshed(g: any, list: { { number } }): (number, number, number)
			local parts, quads, time = 0, 0, 0
			for _, c in list do
				local r = g.generate(0, c[1], c[2])
				local s = os.clock()
				for y0 = 0, r.height - 1, Config.SectionHeight do
					local y1 = y0 + Config.SectionHeight
					if not GreedyMesher.isTrivial(y0, y1, r.solidBelow, r.emptyAbove, true) then
						local _, count = GreedyMesher.mesh(r.data, r.height, y0, y1, true, nil, true)
						parts += count
					end
				end
				time += os.clock() - s
				local q0, q1 = GreedyMesher.activeRange(r.solidBelow, r.emptyAbove, r.height)
				local _, n = QuadMesher.mesh(r.data, r.height, q0, q1, true)
				quads += n
			end
			return parts / #list, quads / #list, time / #list
		end
		-- The budget's plain chunks: tests/bench's, the 16 around the spawn of its world (seed
		-- 12345). The downtowns: the 16 chunks in the middle of every city with one (R >= 131,
		-- `half` 4 and up) here, against them.
		local bench = TerrainGenerator.new(12345)
		local sx, _, sz = bench.findSpawn()
		local reference = chunksAround(sx, sz, 4)
		meshed(bench, reference)
		local pp, pq, pm = meshed(bench, reference)
		print(string.format("    plain (the bench's): %.0f parts, %.0f quads, %.2f ms a chunk", pp, pq, pm * 1000))
		local count, sumTime = 0, 0
		for _, site in all do
			if site.radius >= 131 then
				local list = chunksAround(site.x, site.z, 4)
				meshed(gen, list)
				local dp, dq, dm = meshed(gen, list)
				count += 1
				sumTime += dm
				print(
					string.format(
						"    downtown at %d, %d (R %d): %.0f parts (%.2fx), %.0f quads (%.2fx), %.2f ms",
						site.x,
						site.z,
						site.radius,
						dp,
						dp / pp,
						dq,
						dq / pq,
						dm * 1000
					)
				)
				t.ok(dp <= 2.5 * pp, `parts at {site.x}, {site.z}`)
				t.ok(dq <= 2.5 * pq, `quads at {site.x}, {site.z}`)
			end
		end
		t.ok(count >= 3, "downtowns measured")
		-- (Meshing time over them all: one chunk's is a fraction of a millisecond, its noise large.)
		t.ok(sumTime / count <= 2.5 * pm, "meshing time")
	end)

	t.test("cities: a generate after `prepare` builds no cell, site, link or tile", function()
		local g, c = generator(SEED)
		g.findSpawn()
		for _, n in
			{
				{ 0, BIG.x, BIG.z },
				{ 0, ROAD.x, ROAD.z },
				{ 0, BIG.x + BIG.radius, BIG.z },
				{ 2, BIG.x, BIG.z },
				{ 4, BIG.x, BIG.z },
				{ 6, BIG.x, BIG.z },
			}
		do
			local level = n[1]
			local step = 2 ^ level
			local span = SIZE * step
			local nx, nz = n[2] // span, n[3] // span
			local guard = 2 * (step + 2) + 16
			local ox, oz = nx * span, nz * span
			g.prepare(ox - step - guard, oz - step - guard, ox + span + step + guard, oz + span + step + guard)
			local a1, b1, c1, d1 = c.built()
			g.generate(level, nx, nz)
			local a2, b2, c2, d2 = c.built()
			t.eq(`{a2 - a1} {b2 - b1} {c2 - c1} {d2 - d1}`, "0 0 0 0", `L{level} {nx},{nz}: builds after prepare`)
		end
		-- Many road and margin chunks of the cities of two seeds, the library on (the outposts'
		-- placer reads the raw terrain and keeps its starts' bounds out of `blocked`), each on a
		-- fresh generator that knows its spawn (as a worker's), and the chunk where an outpost's
		-- placer once built a road's plan.
		local chunks, hits = 0, 0
		for _, seed in { 12345, 99 } do
			local fresh, fc = generator(seed)
			fresh.findSpawn()
			local list: { { number } } = if seed == 12345 then { { -100 * SIZE, -307 * SIZE } } else {}
			local segments = fresh.roads(-6000, -6000, 6000, 6000)
			for i = 1, #segments, math.max(1, #segments // 60) do
				table.insert(list, { segments[i].x0, segments[i].z0 })
			end
			local sites = fresh.cities(-6000, -6000, 6000, 6000)
			for i = 1, math.min(8, #sites) do
				local site = sites[i]
				table.insert(list, { site.x + site.radius + MARGIN // 2, site.z })
				table.insert(list, { site.x - 5, site.z - site.radius - MARGIN + 3 })
			end
			for _, p in list do
				local nx, nz = math.floor(p[1]) // SIZE, math.floor(p[2]) // SIZE
				local guard = 2 * (1 + 2) + 16
				local ox, oz = nx * SIZE, nz * SIZE
				fresh.prepare(ox - 1 - guard, oz - 1 - guard, ox + SIZE + 1 + guard, oz + SIZE + 1 + guard)
				local a1, b1, c1, d1 = fc.built()
				fresh.generate(0, nx, nz)
				local a2, b2, c2, d2 = fc.built()
				chunks += 1
				if a2 + b2 + c2 + d2 ~= a1 + b1 + c1 + d1 then
					hits += 1
					t.eq(
						`{a2 - a1} {b2 - b1} {c2 - c1} {d2 - d1}`,
						"0 0 0 0",
						`seed {seed} L0 {nx},{nz}: builds after prepare`
					)
				end
			end
		end
		print(`    {chunks} road and margin chunks of two seeds generated after prepare, {hits} built anything`)
		-- /locate's probes, of every kind, build no site, link or tile (existence tests only), on
		-- a fresh generator that knows its spawn; the bunkers' (Generation/Bunkers) alone may plan
		-- sites, as their hatches stand in the cities' sheds (`bunkerSpots` reads a site's plan),
		-- but no road.
		local kind = c.locateKind()
		local beforeCells = c.built()
		for gx = -30, 30 do
			kind.probe(gx, 7)
		end
		t.eq((c.built()), beforeCells, "the city probes add no cell to the caches")
		for _, seed in { 99, 12345 } do
			local fresh, fc = generator(seed)
			fresh.findSpawn()
			for _, k in (fresh.locateKinds :: any)() do
				local _, s0, l0, t0 = fc.built()
				for _, from in { { 0, 0 }, { 9000, -7000 } } do
					Locate.nearest({ k }, from[1], from[2])
				end
				local _, s1, l1, t1 = fc.built()
				local sites = if k.id == "bunker" then 0 else s1 - s0
				t.eq(`{sites} {l1 - l0} {t1 - t0}`, "0 0 0", `seed {seed} /locate {k.id}: no site, link or tile built`)
			end
		end
	end)

	-- Runs f with a yield that records the longest stretch between two yields; total, longest (s).
	local function stretches(f: (yield: () -> ()) -> ()): (number, number, number)
		local last = os.clock()
		local start = last
		local longest, count = 0, 0
		f(function()
			local now = os.clock()
			longest = math.max(longest, now - last)
			last = now
			count += 1
		end)
		local now = os.clock()
		return now - start, math.max(longest, now - last), count
	end

	t.test("cities: a cold prepare of one 1024 block cell and its links: 40 ms at most, 3 ms between yields", function()
		local gx, gz = BIG.x // cfg.Grid, BIG.z // cfg.Grid
		-- (The total: the median of three fresh generators; the longest stretch: the best of them,
		-- as a busy machine only lengthens stretches.)
		local totals, worst = {}, math.huge
		for _ = 1, 3 do
			local g, c = generator(SEED)
			local total, longest = stretches(function(yield)
				g.prepare(
					gx * cfg.Grid,
					gz * cfg.Grid,
					gx * cfg.Grid + cfg.Grid - 1,
					gz * cfg.Grid + cfg.Grid - 1,
					yield
				)
			end)
			table.insert(totals, total)
			worst = math.min(worst, longest)
			local cells, sites, links, tiles = c.built()
			t.ok(sites > 0 and tiles > 0, "it built the city")
			local _ = cells + links
		end
		table.sort(totals)
		print(
			string.format(
				"    cold prepare: %.1f ms (median of 3), longest stretch %.2f ms (best of 3)",
				totals[2] * 1000,
				worst * 1000
			)
		)
		t.ok(totals[2] < 0.040, "40 ms in total")
		t.ok(worst < 0.003, "3 ms between yields")
	end)

	t.test(
		"cities: a map tile at 64 blocks a pixel, the spawn search and city chunks keep to 3 ms between yields",
		function()
			-- Each stretch is the best of three fresh generators: a busy machine (other work on its
			-- cores, a collection) only lengthens them. (A fresh generator that has made one chunk,
			-- so it knows its spawn: the planners' first query works it out at once, as it always
			-- has; the spawn search's own stretches are measured below.)
			local total, longest, count = math.huge, math.huge, 0
			for _ = 1, 3 do
				local g = TerrainGenerator.new(SEED)
				g.generate(0, 0, 0)
				local spent, longestHere, yields = stretches(function(yield)
					MapPainter.new(g)(BIG.x - 2048, BIG.z - 2048, 64, Config.Map.TileSize, yield)
				end)
				total, longest, count = math.min(total, spent), math.min(longest, longestHere), yields
			end
			print(
				string.format(
					"    map tile at 64 blocks a pixel: %.1f ms, %d yields, longest %.2f ms (best of 3)",
					total * 1000,
					count,
					longest * 1000
				)
			)
			t.ok(longest < 0.003, "the map tile")
			local worst = 0
			for _, seed in { 2, 14, 99 } do
				local times, stretch = {}, math.huge
				local x, z
				for _ = 1, 3 do
					local fresh, c = generator(seed)
					local sx, sz
					local spent, longestHere = stretches(function(yield)
						sx, _, sz = fresh.findSpawn(yield)
					end)
					x, z = sx, sz
					table.insert(times, spent)
					stretch = math.min(stretch, longestHere)
					local _ = c
				end
				table.sort(times)
				worst = math.max(worst, times[1])
				-- Shifted next to a city: 150-400 blocks outside its margin, on ground that passes.
				local rawX, _, rawZ = TerrainGenerator.new(seed, { ruins = false }).findSpawn()
				t.ok(x ~= rawX or z ~= rawZ, `seed {seed}: the spawn moved`)
				local best, bestD = nil, math.huge
				for _, site in TerrainGenerator.new(seed).cities(rawX - 3000, rawZ - 3000, rawX + 3000, rawZ + 3000) do
					local d = math.sqrt((site.x - rawX) ^ 2 + (site.z - rawZ) ^ 2)
					if d < bestD then
						best, bestD = site, d
					end
				end
				t.ok(best ~= nil, "a city near")
				local d = math.sqrt((x - best.x) ^ 2 + (z - best.z) ^ 2)
				local edge = best.radius + MARGIN
				t.ok(d >= edge + 150 - 2 and d <= edge + 400 + 2, `seed {seed}: {d - edge} blocks past the margin`)
				print(
					string.format(
						"    seed %d: spawn %d, %d (raw %d, %d), %.1f ms cold, longest stretch %.2f ms (best of 3)",
						seed,
						x,
						z,
						rawX,
						rawZ,
						times[1] * 1000,
						stretch * 1000
					)
				)
				t.ok(stretch < 0.003, `seed {seed}: 3 ms between yields`)
			end
			t.ok(worst < 0.030, "findSpawn: 30 ms cold")
			-- Downtown's chunks on a fresh generator (cold caches, unplanned lots), a yield at a time:
			-- each level's longest stretch, the best of three generators (a busy machine only
			-- lengthens stretches; L2's trees alone take some 1.6 ms here, cities or not).
			for level = 0, cfg.LodLevels do
				local span = SIZE * 2 ^ level
				local runs = {}
				for _ = 1, 3 do
					local fresh = TerrainGenerator.new(SEED)
					fresh.generate(0, 0, 0)
					local _, longestHere = stretches(function(yield)
						fresh.generate(level, BIG.x // span, BIG.z // span, yield)
					end)
					table.insert(runs, longestHere)
				end
				table.sort(runs)
				print(
					string.format("    downtown L%d cold: longest stretch %.2f ms (best of 3)", level, runs[1] * 1000)
				)
				t.ok(runs[1] < 0.003, `L{level}: 3 ms between yields`)
			end
		end
	)

	t.test("cities: cold /locate of the planners' kinds and cold `blocked` keep to 3 ms between yields", function()
		-- The planners (lakes, lava lakes, wells, outposts, mineshafts) keep out of `blocked`,
		-- which needs existence tests alone (the candidate links, never a city's choices or a
		-- road's plan): from far out on a fresh generator, each search's longest stretch (the best
		-- of three generators: a busy machine only lengthens them).
		local worst, worstWhat = 0, ""
		for _, seed in { 1, 99, 12345 } do
			for _, id in { "lake", "lava_lake", "oil_geyser", "outpost", "mineshaft_entrance" } do
				local best = math.huge
				for _ = 1, 3 do
					local fresh = TerrainGenerator.new(seed)
					fresh.generate(0, 0, 0)
					local kind: any = nil
					for _, k in (fresh.locateKinds :: any)() do
						if k.id == id then
							kind = k
						end
					end
					assert(kind, id)
					local _, longest = stretches(function(yield)
						Locate.nearest({ kind }, 20000, -15000, yield)
					end)
					best = math.min(best, longest)
				end
				if best > worst then
					worst, worstWhat = best, `seed {seed} {id}`
				end
				t.ok(best < 0.003, `seed {seed} /locate {id}: {best * 1000} ms between yields`)
			end
		end
		print(string.format("    cold /locate: longest stretch %.2f ms (%s, best of 3)", worst * 1000, worstWhat))
		-- A cold `blocked` of a small rectangle (a planner's query) on its own, in 16 spots 12 km
		-- apart on three seeds: the existence tests of a few cells. Each spot's best of three
		-- fresh generators; the slowest spot is then timed on seven more and its median kept (a
		-- busy machine or a collection only lengthens a single call).
		local function coldBlocked(seed: number, x: number, z: number): (number, number)
			local _, c = generator(seed)
			local before = c.built()
			local start = os.clock()
			c.blocked(x, z, x + 31, z + 31)
			return os.clock() - start, c.built() - before
		end
		local slowest, cells, at = 0, 0, { 0, 0, 0 }
		for _, seed in { 1, 99, 12345 } do
			for k = 0, 15 do
				local x, z = (k % 4) * 12000 - 18000, (k // 4) * 12000 - 18000
				local best, built = math.huge, 0
				for _ = 1, 3 do
					local spent, tested = coldBlocked(seed, x, z)
					best, built = math.min(best, spent), tested
				end
				if best > slowest then
					slowest, cells, at = best, built, { seed, x, z }
				end
			end
		end
		local again: { number } = {}
		for i = 1, 7 do
			again[i] = coldBlocked(at[1], at[2], at[3])
		end
		table.sort(again)
		print(
			string.format(
				"    cold blocked(): slowest spot %.2f ms (best of 3; %d cells tested), %.2f ms (median of 7 more)",
				slowest * 1000,
				cells,
				again[4] * 1000
			)
		)
		t.ok(again[4] < 0.003, "a cold blocked()")
		-- A planner that may yield passes its yield (a bunker's or a mineshaft's region: a city's
		-- 2 km square and its roads): the same boxes, no stretch over 3 ms.
		local site = generator(SEED).cities(4000, 4000, 12000, 12000)[1]
		assert(site, "a city with roads")
		local x0, z0, x1, z1 = site.x - 1024, site.z - 1024, site.x + 1023, site.z + 1023
		local longestBig, boxes = math.huge, 0
		for _ = 1, 3 do
			local _, c = generator(SEED)
			local yielded: { number } = {}
			local _, longest = stretches(function(yield)
				yielded = c.blocked(x0, z0, x1, z1, yield)
			end)
			longestBig = math.min(longestBig, longest)
			local _, again = generator(SEED)
			t.eq(table.concat(yielded, ","), table.concat(again.blocked(x0, z0, x1, z1), ","), "the same boxes")
			boxes = #yielded // 4
		end
		t.ok(boxes > 10, "a city's and its roads' boxes")
		print(
			string.format(
				"    a 2 km square's blocked() with a yield: %d boxes, longest stretch %.2f ms",
				boxes,
				longestBig * 1000
			)
		)
		t.ok(longestBig < 0.003, "a yielding blocked()")
	end)

	t.test("cities: a road's or a city's first wrapped column tests at most 20 cells and builds one tile", function()
		-- A caller that does not prepare (the client's camera column, WAILA, SafeSpot) builds what
		-- its column needs at once: the tile's candidate links (only the pairs that may reach it),
		-- whether each is a link (only the cells that could hold a nearer city in that quarter),
		-- and the plans of those that are. Points on roads (their segments' ends and middles) and
		-- in cities, on fresh generators; the column is the prepared generator's.
		local times: { number } = {}
		local worstCells, points = 0, 0
		for _, seed in { 99, 12345 } do
			local finder, fc = generator(seed)
			local list: { { number } } = {}
			local segments = finder.roads(-5000, -5000, 5000, 5000)
			for i = 1, #segments, math.max(1, #segments // 8) do
				local segment = segments[i]
				table.insert(list, { math.floor(segment.x0), math.floor(segment.z0) })
				table.insert(list, {
					math.floor((segment.x0 + segment.x1) / 2),
					math.floor((segment.z0 + segment.z1) / 2),
				})
			end
			for i, site in finder.cities(-5000, -5000, 5000, 5000) do
				if i <= 4 then
					table.insert(list, { site.x, site.z })
				end
			end
			for _, p in list do
				local fresh, c = generator(seed)
				local start = os.clock()
				local y = fresh.column(p[1], p[2])
				table.insert(times, os.clock() - start)
				local cells, _, _, tiles = c.built()
				points += 1
				worstCells = math.max(worstCells, cells)
				t.ok(cells <= 20, `seed {seed} {p[1]}, {p[2]}: {cells} cells tested`)
				t.ok(tiles <= 1, `seed {seed} {p[1]}, {p[2]}: {tiles} tiles built`)
				fc.prepare(p[1] - 1, p[2] - 1, p[1] + 1, p[2] + 1)
				t.eq(y, (finder.column(p[1], p[2])), "the prepared generator's column")
			end
		end
		table.sort(times)
		print(
			string.format(
				"    %d first columns: at most %d cells, median %.2f ms, slowest %.2f ms",
				points,
				worstCells,
				times[#times // 2 + 1] * 1000,
				times[#times] * 1000
			)
		)
	end)

	--[[ The map ]]

	t.test("map: cities are grey squares and roads lines from 8 blocks a pixel; streets darker at 8", function()
		local function rgb(tile: buffer, size: number, px: number, py: number): (number, number, number)
			local o = (py * size + px) * 4
			return readu8(tile, o), readu8(tile, o + 1), readu8(tile, o + 2)
		end
		local size = 64
		local scale = 16
		local ox, oz = BIG.x - size * scale // 2, BIG.z - size * scale // 2
		local tile = MapPainter.new(gen)(ox, oz, scale, size)
		local inCity, squares = 0, 0
		for py = 0, size - 1 do
			for px = 0, size - 1 do
				local x, z = ox + px * scale + scale // 2, oz + py * scale + scale // 2
				if math.abs(x - BIG.x) <= BIG.radius and math.abs(z - BIG.z) <= BIG.radius then
					inCity += 1
					local r, g, b = rgb(tile, size, px, py)
					if r == 120 and g == 120 and b == 118 then
						squares += 1
					end
				end
			end
		end
		t.ok(inCity > 100 and squares == inCity, `the city's pixels grey ({squares} of {inCity})`)
		-- At 8 blocks a pixel: the street grid darker.
		local fine = MapPainter.new(gen)(BIG.x - 256, BIG.z - 256, 8, size)
		local streets = 0
		for py = 0, size - 1 do
			for px = 0, size - 1 do
				local r = rgb(fine, size, px, py)
				if r == 92 then
					streets += 1
				end
			end
		end
		t.ok(streets > 100, `streets drawn ({streets})`)
		-- A road: its segments' pixels in the road's grey.
		local rx, rz = ROAD.x - size * scale // 2, ROAD.z - size * scale // 2
		local roadTile = MapPainter.new(gen)(rx, rz, scale, size)
		local s = ROAD.segment
		local px, py = math.floor((s.x0 - rx) / scale), math.floor((s.z0 - rz) / scale)
		local r, g, b = rgb(roadTile, size, px, py)
		t.ok(r == 62 and g == 62 and b == 66, `the road's pixel ({r}, {g}, {b})`)
	end)

	--[[ What keeps clear ]]

	t.test(
		"cities: no lake, well, lava lake, puddle, entrance or outpost on them; no cave or tree on a lot or asphalt",
		function()
			local R = BIG.radius + MARGIN
			local x0, z0, x1, z1 = BIG.x - R - 300, BIG.z - R - 300, BIG.x + R + 300, BIG.z + R + 300
			local boxes = cities.blocked(x0, z0, x1, z1)
			local function clear(bx0: number, bz0: number, bx1: number, bz1: number, what: string)
				for i = 1, #boxes, 4 do
					t.ok(
						not (bx0 <= boxes[i + 2] and bx1 >= boxes[i] and bz0 <= boxes[i + 3] and bz1 >= boxes[i + 1]),
						`{what} at {bx0}, {bz0} on the ruins`
					)
				end
			end
			for _, lake in gen.waterLakes(x0, z0, x1, z1) do
				clear(lake.x, lake.z, lake.x + Lakes.BOX - 1, lake.z + Lakes.BOX - 1, "a lake")
			end
			for _, puddle in gen.puddles(x0, z0, x1, z1) do
				clear(puddle.x0, puddle.z0, puddle.x1, puddle.z1, "a puddle")
			end
			for _, lake in gen.lavaLakes(x0, z0, x1, z1) do
				clear(lake.x, lake.z, lake.x + Lava.BOX - 1, lake.z + Lava.BOX - 1, "a lava lake")
			end
			for _, well in gen.oilWells(x0, z0, x1, z1) do
				clear(
					well.x - well.lakeRadius,
					well.z - well.lakeRadius,
					well.x + well.lakeRadius,
					well.z + well.lakeRadius,
					"a well"
				)
			end
			for _, start in gen.structures(x0, z0, x1, z1) do
				for _, piece in start.pieces do
					clear(piece.box[1], piece.box[3], piece.box[4], piece.box[6], "an outpost's piece")
				end
			end
			for _, plan in gen.mineshafts(x0, z0, x1, z1) do
				local e = plan.entrance
				if e then
					clear(e.box[1], e.box[2], e.box[3], e.box[4], "a mineshaft entrance")
				end
			end
			-- The chunks: a street's or road's override is its top block (no surface cave carved it), and
			-- no trunk stands on a lot or on asphalt.
			local checked, trees, footprint = 0, 0, 0
			local list = table.clone(downtown)
			for _, c in chunksAround(BIG.x + BIG.radius - 20, BIG.z, 2) do
				table.insert(list, c)
			end
			for _, c in roadChunks do
				table.insert(list, c)
			end
			for _, c in list do
				for lz = 0, SIZE - 1 do
					for lx = 0, SIZE - 1 do
						local x, z = c[1] * SIZE + lx, c[2] * SIZE + lz
						local h = gen.column(x, z)
						local override = cities.surface(x, z, h, 0)
						if override then
							checked += 1
							t.eq(blockAt(gen, x, h - 1, z), override, `the street's block at {x}, {z}`)
						end
						-- (Every footprint column's ground stands: no pit opened in a lot or a park.)
						if cities.cityAt(x, z) == 1 then
							footprint += 1
							local ground = blockAt(gen, x, h - 1, z)
							t.ok(ground ~= AIR and ground ~= CAVE_AIR, `the ground at {x}, {z}`)
						end
						local base = blockAt(gen, x, h, z)
						if isLog[base] then
							trees += 1
							t.ok(cities.treeAllowed(x, z), `a tree at {x}, {z}`)
						end
					end
				end
			end
			print(
				`    {checked} street and road columns whole, {footprint} footprint columns on ground, {trees} trees where trees may grow`
			)
			t.ok(checked > 1000 and footprint > 4000, "streets and lots checked")
		end
	)

	t.test("outposts: no piece of any in `blocked` (footprints, margins, road corridors) on three seeds", function()
		-- (A start whose bounds reach the blocked area is dropped as it is assembled: StructureGen's
		-- `clear`; its `land` reads the raw terrain, out of `blocked`.)
		local R = 10000
		local starts, pieces = 0, 0
		for _, seed in { 99, 12345, 42 } do
			local g, c = generator(seed)
			for _, start in g.structures(-R, -R, R, R) do
				starts += 1
				local b = start.bounds
				t.eq(#c.blocked(b[1], b[3], b[4], b[6]), 0, `seed {seed}: {start.name} at {start.x}, {start.z}`)
				for _, piece in start.pieces do
					pieces += 1
					local box = piece.box
					t.eq(#c.blocked(box[1], box[3], box[4], box[6]), 0, `seed {seed}: a piece at {box[1]}, {box[3]}`)
				end
			end
		end
		print(`    {starts} outposts ({pieces} pieces) in 20 km squares on three seeds, none on the ruins`)
		t.ok(starts > 100, "outposts checked")
	end)

	--[[ Loot ]]

	-- Antibiotics expected in a container of table `name` (the pools' mean rolls times the odds).
	local function antibiotics(name: string): number
		local sum = 0
		for _, pool in ScavengeLoot.TABLES[name] do
			local total, odds = 0, 0
			for _, entry in pool.entries do
				total += entry[2]
				if entry[1] == "Antibiotics" then
					odds += entry[2]
				end
			end
			sum += (pool.rolls[1] + pool.rolls[2]) / 2 * odds / total
		end
		return sum
	end

	-- Every building container of a plan: x, y, z, block, table.
	local function containersOf(plan: any): { { any } }
		local out = {}
		for pv = 0, plan.n - 1 do
			for pu = 0, plan.n - 1 do
				for _, b in CityLayout.lot(plan, pu, pv).buildings do
					for k = 1, #b.containers, 4 do
						table.insert(out, {
							b.containers[k],
							b.containers[k + 1],
							b.containers[k + 2],
							b.containers[k + 3],
							b.tables[(k + 3) // 4],
						})
					end
				end
			end
		end
		return out
	end

	t.test("loot: a big city holds 3+ Antibiotics in expectation; every town a Medicine Cabinet", function()
		t.ok(Items.id.Antibiotics ~= nil, "antibiotics")
		local expected = 0
		local list = containersOf(planBig)
		for _, c in list do
			expected += antibiotics(c[5])
		end
		print(string.format("    the big city: %d containers, %.2f Antibiotics expected", #list, expected))
		t.ok(expected >= 3, "3 or more Antibiotics")
		-- Every container stands where the plan says, and holds its table's loot.
		local salt = require(shared.Util.Hash).hash2(SEED, require(shared.Util.Hash).string("cities.loot"), 0x0C17)
		for k = 1, #list, math.max(1, #list // 25) do
			local c = list[k]
			t.eq(blockAt(gen, c[1], c[2], c[3]), c[4], `container at {c[1]}, {c[2]}, {c[3]}`)
			local items = gen.structureContainer(c[1], c[2], c[3])
			local want = ScavengeLoot.roll(c[5], salt, c[1], c[2], c[3])
			t.ok(items ~= nil and #items == #want, "its loot")
			for i, item in items :: any do
				t.eq(item.item, want[i].item)
				t.eq(item.count, want[i].count)
			end
		end
		t.eq(gen.structureContainer(BIG.x, BIG.y + 200, BIG.z), nil, "nothing in the air")
		-- Every city around has a Medicine Cabinet that stands.
		local cabinet = B.MedicineCabinet
		for _, site in all do
			local plan = cities.planAt(site.x, site.z)
			local found = false
			for _, c in containersOf(plan) do
				if c[4] == cabinet and c[2] == site.y then
					found = true
				end
			end
			t.ok(found, `a ground floor Medicine Cabinet in the city at {site.x}, {site.z}`)
		end
		-- /locate poi finds them from the plans.
		local lut = buffer.create(Blocks.count)
		buffer.writeu8(lut, cabinet, 1)
		local out =
			gen.poiBlocks(TOWN.x - TOWN.radius, TOWN.z - TOWN.radius, TOWN.x + TOWN.radius, TOWN.z + TOWN.radius, lut)
		t.ok(#out >= 4, "the town's cabinets as points of interest")
	end)

	--[[ Overgrowth ]]

	t.test(
		"ruins: vines hold, carpets lie on sturdy blocks, no plant on asphalt or concrete; webs, moss, cracks",
		function()
			local counts: { [string]: number } = {}
			local function count(name: string)
				counts[name] = (counts[name] or 0) + 1
			end
			local hard: { [number]: boolean } = {}
			for _, name in { "Asphalt", "CrackedAsphalt", "RoadLine", "RoadLineYellow", "Concrete", "CrackedConcrete" } do
				hard[B[name]] = true
			end
			for _, c in downtown do
				for lz = 0, SIZE - 1 do
					for lx = 0, SIZE - 1 do
						local x, z = c[1] * SIZE + lx, c[2] * SIZE + lz
						for y = BIG.y - 1, BIG.y + 60 do
							local id = blockAt(gen, x, y, z)
							local def = Blocks.get(id)
							if string.sub(def.name, 1, 4) == "Vine" then
								count("vines")
								local dx, dy, dz = Blocks.supportOffset(id)
								local wall = blockAt(gen, x + (dx :: number), y + (dy :: number), z + (dz :: number))
								t.ok(Blocks.isSturdy(wall) or blockAt(gen, x, y + 1, z) == id, `vine at {x}, {y}, {z}`)
							elseif id == B.MossCarpet then
								count("carpets")
								t.ok(Blocks.isSturdy(blockAt(gen, x, y - 1, z)), `carpet at {x}, {y}, {z}`)
							elseif id == B.Cobweb then
								count("cobwebs")
							elseif string.find(def.name, "Mossy") then
								count("mossy")
							elseif string.find(def.name, "Cracked") then
								count("cracked")
							elseif id == B.Grass or id == B.MossBlock then
								count("green")
							elseif string.find(def.name, "Ladder") then
								count("ladders")
							elseif Blocks.isPlant(id) then
								count("plants")
								t.ok(
									not hard[blockAt(gen, x, y - 1, z)],
									`a plant on asphalt or concrete at {x}, {y}, {z}`
								)
							end
						end
					end
				end
			end
			local parts = {}
			for name, n in counts do
				table.insert(parts, `{n} {name}`)
			end
			table.sort(parts)
			print(`    downtown: {table.concat(parts, ", ")}`)
			for _, name in { "vines", "carpets", "mossy", "cracked", "green", "ladders" } do
				t.ok((counts[name] or 0) > 0, `some {name}`)
			end
		end
	)

	t.test("ruins: overgrown: a desert downtown's streets a fifth green and planted, its road too, trees", function()
		-- (Overgrowth 0.6 with a humidity floor of 0.15 left a desert town at o 0.09: 0.7% of its
		-- streets green, none planted, and the roads 3% green; trees grew only in parks.)
		-- (At least 0.8 x 0.5: a desert or plains town's.)
		local least = 0.4
		for _, site in all do
			local plan = cities.planAt(site.x, site.z)
			t.ok(plan.o >= least - 1e-9, `o {plan.o} at {site.x}, {site.z}: at least {least}`)
		end
		t.near(planBig.o, least, 1e-9, "the desert downtown: the floor")
		local greenTop: { [number]: boolean } = { [B.Grass] = true, [B.MossBlock] = true }
		-- The big city's streets in its downtown's chunks: the top block and what stands on it.
		local streets, greens, planted = 0, 0, 0
		for _, c in downtown do
			for lz = 0, SIZE - 1 do
				for lx = 0, SIZE - 1 do
					local x, z = c[1] * SIZE + lx, c[2] * SIZE + lz
					local u, v = x - planBig.x0, z - planBig.z0
					if u % cfg.Block < cfg.Street or v % cfg.Block < cfg.Street then
						streets += 1
						local top = blockAt(gen, x, BIG.y - 1, z)
						if greenTop[top] then
							greens += 1
						end
						if Blocks.isPlant(blockAt(gen, x, BIG.y, z)) then
							planted += 1
							t.ok(top == B.Grass, `a street plant on grass at {x}, {z}`)
						end
					end
				end
			end
		end
		-- The road's asphalt in its chunks (its own surface: not the shoulders' gravel and dirt).
		local road, roadGreen, roadPlanted = 0, 0, 0
		local paved: { [number]: boolean } = {
			[B.Asphalt] = true,
			[B.CrackedAsphalt] = true,
			[B.RoadLineYellow] = true,
			[B.Grass] = true,
			[B.MossBlock] = true,
		}
		for _, c in roadChunks do
			for lz = 0, SIZE - 1 do
				for lx = 0, SIZE - 1 do
					local x, z = c[1] * SIZE + lx, c[2] * SIZE + lz
					local h = gen.column(x, z)
					local override = cities.surface(x, z, h, 0)
					if override and paved[override] then
						road += 1
						if greenTop[override] then
							roadGreen += 1
						end
						if Blocks.isPlant(blockAt(gen, x, h, z)) then
							roadPlanted += 1
						end
					end
				end
			end
		end
		-- Trees: in a plains town's parks and on its streets' grass (the plains' own chance, 0.012,
		-- grew next to none in a town: Cities.Trees x o sets the least).
		local green: any = nil
		local bestD = math.huge
		for _, site in all do
			local _, biome = gen.column(site.x, site.z)
			local d = site.x * site.x + site.z * site.z
			if site.radius >= 60 and site.radius < 131 and Biomes.list[biome].name == "Plains" and d < bestD then
				green, bestD = site, d
			end
		end
		assert(green, "a plains town")
		local planTown = cities.planAt(green.x, green.z)
		local parkTrees, streetTrees = 0, 0
		for z = green.z - green.radius, green.z + green.radius do
			for x = green.x - green.radius, green.x + green.radius do
				if isLog[blockAt(gen, x, green.y, z)] then
					local u, v = x - planTown.x0, z - planTown.z0
					if u % cfg.Block < cfg.Street or v % cfg.Block < cfg.Street then
						streetTrees += 1
					else
						parkTrees += 1
					end
					t.ok(cities.treeAllowed(x, z), `a trunk where trees may grow at {x}, {z}`)
				end
			end
		end
		print(
			string.format(
				"    desert downtown (o %.2f): %d street columns, %.1f%% green, %.1f%% planted; road: %d columns, %.1f%% green, %.1f%% planted; plains town at %d, %d (o %.2f): %d park and %d street trunks",
				planBig.o,
				streets,
				100 * greens / streets,
				100 * planted / streets,
				road,
				100 * roadGreen / road,
				100 * roadPlanted / road,
				green.x,
				green.z,
				planTown.o,
				parkTrees,
				streetTrees
			)
		)
		t.ok(streets > 1000 and road > 100, "streets and road measured")
		t.ok(greens / streets >= 0.2, "a fifth of the streets green or more")
		t.ok(planted / streets >= 0.07, "plants on them")
		t.ok(roadGreen / road >= 0.15, "the road's asphalt a sixth green or more")
		t.ok(roadPlanted / road >= 0.05, "plants on it")
		t.ok(parkTrees >= 5, "trees in its parks")
		t.ok(streetTrees >= 1, "and on its streets")
	end)

	t.test(
		"ruins: every ladder rung hangs on its wall, no Gravel over a hole, carpets on sturdy blocks (3 seeds)",
		function()
			-- Every chunk holding a building's ladder in the three biggest cities near the origin of
			-- three seeds (and the chunks of the cases found before: a ladder whose wall's jagged
			-- top lay lower than its own, rubble under two holed slabs), written by CityLayout's
			-- writer alone (the lots reaching it, the street wrecks) into a scratch chunk: the
			-- ruins' own blocks, whatever the terrain under them.
			local cells = Config.WorldHeight
			local data = buffer.create(LAYER * cells * 2)
			local cases: { [number]: { { number } } } = {
				[12345] = { { 550, 5503 }, { -592, -4468 } },
				[99] = { { 1452, 5561 } },
			}
			local ladders, gravel, carpets, chunksWritten = 0, 0, 0, 0
			local function fail(what: string)
				t.ok(false, what)
			end
			for _, seed in { 99, 12345, 1 } do
				local g, c = generator(seed)
				local sites = g.cities(-6000, -6000, 6000, 6000)
				table.sort(sites, function(a: any, b: any): boolean
					return a.radius > b.radius or (a.radius == b.radius and a.x < b.x)
				end)
				local wanted: { [string]: { number } } = {}
				local function want(x: number, z: number)
					local cx, cz = x // SIZE, z // SIZE
					wanted[`{cx},{cz}`] = { cx, cz }
				end
				for i = 1, math.min(3, #sites) do
					local plan = c.planAt(sites[i].x, sites[i].z)
					for pv = 0, plan.n - 1 do
						for pu = 0, plan.n - 1 do
							for _, b in CityLayout.lot(plan, pu, pv).buildings do
								if b.ladderSide ~= 0 then
									want(b.ladderX, b.ladderZ)
								end
							end
						end
					end
				end
				for _, p in cases[seed] or {} do
					want(p[1], p[2])
				end
				for _, key in wanted do
					local ox, oz = key[1] * SIZE, key[2] * SIZE
					local x0, z0, x1, z1 = CityLayout.span(0, ox, oz)
					local plans = {}
					for _, site in g.cities(x0, z0, x1, z1) do
						table.insert(plans, c.planAt(site.x, site.z))
					end
					if #plans == 0 then
						continue
					end
					chunksWritten += 1
					buffer.fill(data, 0, 0)
					CityLayout.begin(data, cells, 0, ox, oz)
					for _, plan in plans do
						local n = plan.n
						for pv = math.max(0, (z0 - plan.z0) // 32), math.min(n - 1, (z1 - plan.z0) // 32) do
							for pu = math.max(0, (x0 - plan.x0) // 32), math.min(n - 1, (x1 - plan.x0) // 32) do
								CityLayout.writeLot(plan, CityLayout.lot(plan, pu, pv))
							end
						end
						CityLayout.writeStreetCars(plan)
					end
					local _, top = CityLayout.finish()
					local function get(px: number, y: number, pz: number): number
						if px < 0 or px >= P or pz < 0 or pz >= P or y < 0 or y >= cells then
							return AIR
						end
						return readu16(data, ((y * P + pz) * P + px) * 2)
					end
					-- (The padded chunk's own columns; the ground under a building's slab is the
					-- terrain's, not written here: from the plateau's first air up.)
					local y0 = plans[1].y
					for _, plan in plans do
						y0 = math.min(y0, plan.y)
					end
					for pz = 1, P - 2 do
						for px = 1, P - 2 do
							for y = y0, top - 1 do
								local id = get(px, y, pz)
								if id == AIR then
									continue
								end
								local x, z = x0 + px, z0 + pz
								if string.find(Blocks.get(id).name, "Ladder") then
									ladders += 1
									local dx, dy, dz = Blocks.supportOffset(id)
									local support = get(px + (dx :: number), y + (dy :: number), pz + (dz :: number))
									if not Blocks.isSturdy(support) then
										fail(`seed {seed}: a ladder at {x}, {y}, {z} on {Blocks.get(support).name}`)
									end
								elseif id == B.Gravel then
									gravel += 1
									if y > y0 and not Blocks.isSolid(get(px, y - 1, pz)) then
										fail(
											`seed {seed}: Gravel at {x}, {y}, {z} over {Blocks.get(get(px, y - 1, pz)).name}`
										)
									end
								elseif id == B.MossCarpet then
									carpets += 1
									if y > y0 and not Blocks.isSturdy(get(px, y - 1, pz)) then
										fail(
											`seed {seed}: a carpet at {x}, {y}, {z} on {Blocks.get(get(px, y - 1, pz)).name}`
										)
									end
								end
							end
						end
					end
				end
			end
			print(`    {chunksWritten} chunks: {ladders} ladder cells, {gravel} Gravel, {carpets} carpets, all held up`)
			t.ok(ladders > 500 and gravel > 100, "enough of them")
		end
	)

	--[[ Sheds ]]

	t.test("sheds: 1-2 a city, a Concrete floor under Air in a chunk's core columns 2..13", function()
		-- (What the cities write, so with the bunkers off: Generation/Bunkers puts its hatch and
		-- ladder shaft through that floor.)
		local bunkersOn = Config.Bunkers.Enabled
		Config.Bunkers.Enabled = false
		local cityOnly = TerrainGenerator.new(SEED)
		Config.Bunkers.Enabled = bunkersOn
		for _, site in { BIG, TOWN } do
			local spots = cities.bunkerSpots(
				site.x - site.radius,
				site.z - site.radius,
				site.x + site.radius,
				site.z + site.radius
			)
			local n = #spots // 3
			t.ok(n >= cfg.Bunkers[1] and n <= cfg.Bunkers[2], `{n} sheds`)
			for k = 1, #spots, 3 do
				local x, y, z = spots[k], spots[k + 1], spots[k + 2]
				t.eq(y, site.y, "on the plateau")
				t.ok(x % SIZE >= 2 and x % SIZE <= 13 and z % SIZE >= 2 and z % SIZE <= 13, "core columns 2..13")
				t.eq(blockAt(cityOnly, x, y - 1, z), B.Concrete, "a concrete floor")
				t.eq(blockAt(cityOnly, x, y, z), AIR, "air above it")
			end
		end
		-- Every shed has its Oak Door (the lower half in the door's cell, facing out).
		local sheds = 0
		for _, site in all do
			local plan = cities.planAt(site.x, site.z)
			for i in plan.sheds do
				local pu, pv = (i - 1) % plan.n, (i - 1) // plan.n
				for _, b in CityLayout.lot(plan, pu, pv).buildings do
					if b.kind == "shed" then
						sheds += 1
						t.ok(b.door, `the shed at {b.x0}, {b.z0} has a door`)
						if sheds <= 6 then
							local side, along = b.doorSide, b.doorAlong
							local x = if side == 1 or side == 3 then b.x0 + along elseif side == 2 then b.x1 else b.x0
							local z = if side == 2 or side == 4 then b.z0 + along elseif side == 3 then b.z1 else b.z0
							local id = blockAt(gen, x, plan.y, z)
							local _, _, _, upper = Blocks.doorState(id)
							t.ok(
								Blocks.isDoor(id) and string.find(Blocks.get(id).name, "OakDoor") ~= nil,
								`the shed's door at {x}, {plan.y}, {z}: {Blocks.get(id).name}`
							)
							t.eq(upper, false, "its lower half")
						end
					end
				end
			end
		end
		t.ok(sheds >= #all, `{sheds} sheds`)
	end)

	--[[ Safety ]]

	t.test("SafeSpot: in a tall building, the ground or a full floor, never the sealed rooms above", function()
		-- Above FullFloors a tall building is a ring of rooms behind glass round a solid core, with
		-- no ladder up, and its broken top is open sky far above the street: a spot there would
		-- shut a player in or strand them. /tp, the map's teleport and respawns
		-- (Players/SafeSpot.column) stop at the last full floor in a city's footprint, also in a
		-- chunk a player has edited (there SafeSpot starts from the column's top block): `edited`
		-- holds one edit in each tested column's chunk (a block changed and put back, so its
		-- blocks are the generator's and its spots must be the same).
		local WorldServer = require(server.World.WorldServer)
		local SafeSpot = require(server.Players.SafeSpot)
		local world = WorldServer.new(gen)
		local edited = WorldServer.new(gen)
		local FH = cfg.FloorHeight
		local tall, spots, editedSpots = 0, 0, 0
		local function editChunkOf(x: number, z: number, y: number)
			local ex, ez = (x // SIZE) * SIZE, (z // SIZE) * SIZE
			local old = edited:getBlock(ex, y, ez)
			t.ok(edited:setBlock(ex, y, ez, if old == AIR then Blocks.id.Stone else AIR), "an edit")
			edited:setBlock(ex, y, ez, old)
			t.ok(edited:chunkEdits(x // SIZE, z // SIZE) ~= nil, "the column's chunk holds an edit")
		end
		for pv = 0, planBig.n - 1 do
			for pu = 0, planBig.n - 1 do
				for _, b in CityLayout.lot(planBig, pu, pv).buildings do
					if b.floors <= b.full or tall >= 4 then
						continue
					end
					tall += 1
					local mx, mz = (b.x0 + b.x1) // 2, (b.z0 + b.z1) // 2
					-- The ring (depth 1 and 2, inside each wall) and the core.
					for _, c in
						{
							{ mx + 1, b.z0 + 1 },
							{ b.x1 - 2, mz + 1 },
							{ mx - 1, b.z1 - 1 },
							{ b.x0 + 2, mz - 1 },
							{ mx, mz },
						}
					do
						local y = SafeSpot.column(world, c[1], c[2])
						if y then
							spots += 1
							t.ok(
								y <= b.y0 + 1 + (b.full - 1) * FH,
								`{b.kind} of {b.floors} floors: a spot at {c[1]}, {y}, {c[2]} above its last full floor`
							)
						end
						editChunkOf(c[1], c[2], b.y0 + 1)
						local ye = SafeSpot.column(edited, c[1], c[2])
						if ye then
							editedSpots += 1
							t.ok(
								ye <= b.y0 + 1 + (b.full - 1) * FH,
								`{b.kind} of {b.floors} floors, edited chunk: a spot at {c[1]}, {ye}, {c[2]} above its last full floor`
							)
						end
						t.eq(ye, y, `the spot at {c[1]}, {c[2]} with and without an edit in its chunk`)
					end
				end
			end
		end
		print(
			`    {tall} tall buildings, {spots} spots ({editedSpots} in edited chunks), each at most on the last full floor`
		)
		t.ok(tall > 0 and spots > 0 and editedSpots > 0, "tall buildings and spots in them")
	end)

	--[[ Far levels, switches, /locate ]]

	t.test("cities: massing at levels 1-4, nothing standing beyond; the surface at every level", function()
		for level = 1, Config.Lod.Levels - 1 do
			local span = SIZE * 2 ^ level
			local _, stepY = ChunkLayout.steps(level)
			local r = gen.generate(level, BIG.x // span, BIG.z // span)
			local above = 0
			local from = (BIG.y + stepY) // stepY + 1
			for y = from, r.height - 1 do
				for i = 0, LAYER - 1 do
					if readu16(r.data, (y * LAYER + i) * 2) ~= AIR then
						above += 1
					end
				end
			end
			if level <= cfg.LodLevels then
				t.ok(above > 0, `L{level}: buildings stand`)
			else
				t.eq(above, 0, `L{level}: nothing stands`)
			end
		end
		local streetX, streetZ = BIG.x - BIG.radius + 3, BIG.z
		for _, level in { 0, 2, 5 } do
			local h = gen.column(streetX, streetZ)
			t.ok(cities.surface(streetX, streetZ, h, level) ~= nil, `L{level}: a street's surface`)
		end
		t.eq((cities.surface(ROAD.x, ROAD.z, gen.column(ROAD.x, ROAD.z), 3)), nil, "no road beyond SurfaceLevels")
		-- (`top` asks for lots' tops without planning them: the planned lots' own.)
		local fresh = CityLayout.plan(planBig, planBig.y, planBig.o)
		for pv = 0, planBig.n - 1 do
			for pu = 0, planBig.n - 1 do
				t.eq(CityLayout.lotTop(fresh, pu, pv), CityLayout.lot(planBig, pu, pv).top, `lot {pu}, {pv}'s top`)
			end
		end
	end)

	t.test("cities: none without Ruins, structures, Generate Structures or Cities.Enabled", function()
		for _, options in { { ruins = false }, { structures = false } } do
			local g = TerrainGenerator.new(SEED, options)
			t.eq(#g.cities(-8000, -8000, 8000, 8000), 0, "no sites")
			t.eq(g.prepare, nil, "nothing to prepare")
		end
		Config.Cities.Enabled = false
		local off = TerrainGenerator.new(SEED)
		Config.Cities.Enabled = true
		t.eq(#off.cities(-8000, -8000, 8000, 8000), 0, "Cities.Enabled off")
		Config.Cities.Roads.Enabled = false
		local noRoads = TerrainGenerator.new(SEED)
		Config.Cities.Roads.Enabled = true
		t.ok(#noRoads.cities(-8000, -8000, 8000, 8000) > 0, "cities without roads")
		t.eq(#noRoads.roads(-8000, -8000, 8000, 8000), 0, "no roads")
	end)

	t.test("cities: /locate structure city answers the nearest site", function()
		local kinds = {}
		for _, kind in (gen.locateKinds :: any)() do
			if kind.id == "city" then
				table.insert(kinds, kind)
			end
		end
		t.eq(#kinds, 1, "the kind")
		for _, p in { { 0, 0 }, { BIG.x + 1500, BIG.z - 700 } } do
			local found = Locate.nearest(kinds, p[1], p[2]) :: any
			local best = math.huge
			for _, site in gen.cities(p[1] - 6000, p[2] - 6000, p[1] + 6000, p[2] + 6000) do
				best = math.min(best, math.sqrt((site.x - p[1]) ^ 2 + (site.z - p[2]) ^ 2))
			end
			t.near(found.distance, best, 1e-6, "the nearest")
		end
	end)

	Cities.new = originalNew
end
