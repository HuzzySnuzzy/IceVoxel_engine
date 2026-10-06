--[[
	Surface caves (Generation/SurfaceCaves): cave entrances and ravines carved as Air after the
	caves. Checked on real worms of seed 12345 near the origin: determinism and chunk seams, the
	cell rules (Air, below the surface, never at water, bedrock or cave air), the water rule (on
	real coasts and river banks of seeds 12345, 777 and 2024 at levels 0-2, and on a synthetic
	world through a fake sampler), ores and grass, trees, plants and spawns, library structures,
	LOD point sampling (far chunks carve only what is open to the sky) and the seams both ways,
	frequency and shapes, continuous walkable tunnels, no long open ditches, no floating blocks,
	regrown tops (snow too), and the cost.
]]

return function(t, shared, require, server)
	local Config = require(shared.Config)
	local Blocks = require(shared.Blocks)
	local Biomes = require(shared.Biomes)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)
	local SurfaceCaves = require(shared.Generation.SurfaceCaves)
	local Relief = require(shared.Generation.Relief)
	local Ores = require(shared.Generation.Ores)
	local GreedyMesher = require(shared.Meshing.GreedyMesher)
	local Hash = require(shared.Util.Hash)

	local SIZE = ChunkLayout.SIZE
	local SEA = Config.SeaLevel
	local AIR, CAVE = Blocks.AIR, Blocks.CAVE_AIR
	local SEED = 12345
	local entranceCfg, ravineCfg = Config.Caves.Entrances, Config.Caves.Ravines

	local gen = TerrainGenerator.new(SEED, { structures = false })
	local sc = gen.surfaceCaves

	-- The same terrain without surface caves (Config is read when chunks are carved).
	local function withoutSurfaceCaves<T>(fn: () -> T): T
		local e, r = entranceCfg.Enabled, ravineCfg.Enabled
		entranceCfg.Enabled, ravineCfg.Enabled = false, false
		local ok, result = pcall(fn)
		entranceCfg.Enabled, ravineCfg.Enabled = e, r
		assert(ok, result)
		return result
	end

	-- Fixtures: a long entrance and a long ravine near the origin.
	local entrance, ravine
	for _, worm in sc.worms(-1600, -1600, 1600, 1600) do
		if worm.kind == "entrance" and entrance == nil and worm.count >= 50 and not worm.mouth then
			entrance = worm
		elseif worm.kind == "ravine" and ravine == nil and worm.count >= 60 then
			ravine = worm
		end
	end
	assert(entrance and ravine, "no entrance or ravine near the origin")

	-- Chunks whose padded box a worm's steps reach.
	local function chunksOf(worm: SurfaceCaves.Worm): { { number } }
		local seen, list = {}, {}
		for s = 1, worm.count do
			local r = worm.h[s] + 1
			for cz = (worm.z[s] - r - 1) // SIZE, (worm.z[s] + r + 1) // SIZE do
				for cx = (worm.x[s] - r - 1) // SIZE, (worm.x[s] + r + 1) // SIZE do
					local key = cx * 100000 + cz
					if not seen[key] then
						seen[key] = true
						table.insert(list, { cx, cz })
					end
				end
			end
		end
		return list
	end

	local results: { [number]: any } = {}
	local function chunk(cx: number, cz: number)
		local key = cx * 100000 + cz
		local r = results[key]
		if r == nil then
			r = gen.generate(0, cx, cz)
			results[key] = r
		end
		return r
	end

	local isOre: { [number]: boolean } = {}
	for _, ore in Ores.FEATURES do
		isOre[ore.block] = true
	end
	local function norm(id: number): number
		if Blocks.isCaveTwin(id) then
			return CAVE
		end
		return if isOre[id] then Blocks.id.Stone else id
	end

	t.test("surface caves: worms are deterministic, whatever the cache and chunk order", function()
		local again = TerrainGenerator.new(SEED, { structures = false })
		-- Fill the other generator's caches elsewhere first.
		for cx = 40, 44 do
			again.generate(0, cx, -30)
		end
		for _, c in { chunksOf(entrance)[3], chunksOf(ravine)[5] } do
			local a = chunk(c[1], c[2])
			local b = again.generate(0, c[1], c[2])
			t.eq(buffer.tostring(a.data), buffer.tostring(b.data), `chunk {c[1]}, {c[2]}`)
		end
		local list = again.surfaceCaves.worms(-1600, -1600, 1600, 1600)
		local same = 0
		for _, worm in list do
			if worm.cellX == entrance.cellX and worm.cellZ == entrance.cellZ and worm.kind == "entrance" then
				t.eq(worm.count, entrance.count)
				for s = 1, worm.count do
					t.eq(worm.x[s], entrance.x[s])
					t.eq(worm.y[s], entrance.y[s])
					t.eq(worm.h[s], entrance.h[s])
				end
				same += 1
			end
		end
		t.eq(same, 1, "the entrance again")
		local other = TerrainGenerator.new(SEED + 1, { structures = false }).surfaceCaves
		local first = other.worms(-1600, -1600, 1600, 1600)[1]
		t.ok(first == nil or first.x[1] ~= entrance.x[1] or first.z[1] ~= entrance.z[1], "another seed")
	end)

	t.test("surface caves: chunk padding equals the neighbouring cores", function()
		local mismatches, compared = 0, 0
		for _, worm in { entrance, ravine } do
			local list = chunksOf(worm)
			for k = 1, #list, 2 do
				local cx, cz = list[k][1], list[k][2]
				local a = chunk(cx, cz)
				local east, south = chunk(cx + 1, cz), chunk(cx, cz + 1)
				for y = 1, math.min(a.height, east.height, south.height) - 1 do
					for i = 0, SIZE - 1 do
						compared += 4
						if
							norm(ChunkLayout.getPadded(a.data, SIZE, y, i)) ~= norm(ChunkLayout.get(east.data, 0, y, i))
						then
							mismatches += 1
						end
						if
							norm(ChunkLayout.getPadded(east.data, -1, y, i))
							~= norm(ChunkLayout.get(a.data, SIZE - 1, y, i))
						then
							mismatches += 1
						end
						if
							norm(ChunkLayout.getPadded(a.data, i, y, SIZE))
							~= norm(ChunkLayout.get(south.data, i, y, 0))
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
		end
		t.ok(compared > 100000, "cells compared")
		t.eq(mismatches, 0, "border cells that disagree")
	end)

	t.test("surface caves: Air below the surface, never at water, bedrock or cave air", function()
		local carved, junctions, regrown = 0, 0, 0
		-- (Water and ice: below Config.Caves.LavaLevel a surface cave's air becomes lava,
		-- Generation/Lava, as Minecraft's carvers carve lava there.)
		local WATER_SET: { [number]: boolean } = {}
		for id = 0, Blocks.count - 1 do
			local fluid = Blocks.get(id).fluid
			if (fluid and fluid.group == "Water") or id == Blocks.id.Ice then
				WATER_SET[id] = true
			end
		end
		for _, worm in { entrance, ravine } do
			for _, c in chunksOf(worm) do
				local cx, cz = c[1], c[2]
				local on = chunk(cx, cz)
				local off = withoutSurfaceCaves(function()
					return TerrainGenerator.new(SEED, { structures = false }).generate(0, cx, cz)
				end)
				for lz = -1, SIZE do
					for lx = -1, SIZE do
						local h = gen.column(cx * SIZE + lx, cz * SIZE + lz)
						for y = 0, math.min(h - 1, on.height - 1) do
							local a, b =
								ChunkLayout.getPadded(on.data, lx, y, lz), ChunkLayout.getPadded(off.data, lx, y, lz)
							if norm(b) == CAVE then
								t.eq(norm(a), CAVE, "cave air stays cave air")
							end
							-- (Lichen may grow on other walls once some rock is gone.)
							if norm(a) == norm(b) then
								continue
							end
							if a == AIR then
								carved += 1
								t.ok(y >= Config.Caves.MinY, `carved at y {y}`)
								t.ok(h > SEA + 2, `carved in a column at {h}`)
								t.ok(Blocks.isOpaque(norm(b)) and b ~= Blocks.id.Bedrock, `carved {b}`)
								if lx >= 0 and lx < SIZE and lz >= 0 and lz < SIZE then
									for _, d in
										{
											{ 1, 0, 0 },
											{ -1, 0, 0 },
											{ 0, 0, 1 },
											{ 0, 0, -1 },
											{ 0, -1, 0 },
											{ 0, 1, 0 },
										}
									do
										local n = ChunkLayout.getPadded(on.data, lx + d[1], y + d[2], lz + d[3])
										t.ok(not WATER_SET[n], "carved air next to water")
										if n == CAVE then
											junctions += 1
										end
									end
								end
							else
								-- Grass (or another top) regrown on uncovered dirt.
								t.eq(b, Blocks.id.Dirt, `changed {b} into {a} at {h - y} below the surface`)
								regrown += 1
							end
						end
					end
				end
			end
		end
		t.ok(carved > 1000, `carved cells: {carved}`)
		t.ok(junctions > 0, "the fixtures meet cave air")
		t.ok(regrown > 0, "grass grows back on pit floors")
	end)

	--[[
		The water rule: no surface cave touches water. SurfaceCaves carves only columns above WET,
		and dry() lets a step that may reach below sea level + 1 (or lies in a river valley) carve
		only when the surface around it, sampled on a 4 block grid, is above WET within its radius
		+ DRY_MARGIN (+ RIVER_MARGIN in valleys); a worm starts only on land above START_ABOVE with
		a river strength below RIVER_START, and one the water stops within MIN_STEPS is dropped.
		Checked on real coasts and river banks of three seeds at every carved level, and on a
		synthetic world built so that every part of the rule matters.
	]]
	local WET = SEA + 2 -- columns at or below this surface height count as water
	local DRY_MARGIN, RIVER_MARGIN = 3, 3 -- blocks a low step keeps from water; more in valleys
	local START_ABOVE, RIVER_START = SEA + 4, 0.3 -- where a worm may start
	local MIN_STEPS = { entrance = 16, ravine = 30 } -- a worm the water stops sooner is dropped
	local WATCH = 20 -- steps this close to water (blocks beyond their radius) are looked at
	local SEARCH = DRY_MARGIN + RIVER_MARGIN + 4 -- how far `nearestWet` looks (blocks)
	local WATER = Blocks.fluidId("Water", 0)
	-- Water and ice (lava fills a surface cave's air below LavaLevel: Generation/Lava).
	local WATERY: { [number]: boolean } = {}
	for id = 0, Blocks.count - 1 do
		local fluid = Blocks.get(id).fluid
		if (fluid and fluid.group == "Water") or id == Blocks.id.Ice then
			WATERY[id] = true
		end
	end
	local SIX = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }

	local function blocks(d: number): string
		return if d == math.huge then "-" else string.format("%.1f", d)
	end

	-- A sampler of whole columns that remembers what it was asked.
	local function cached(surfaceAt: SurfaceCaves.SurfaceSampler): SurfaceCaves.SurfaceSampler
		local heights: { [number]: number }, rivers: { [number]: number } = {}, {}
		return function(x: number, z: number): (number, number)
			local k = x * 1048576 + z
			local h = heights[k]
			if h == nil then
				local river
				h, river = surfaceAt(x, z)
				heights[k], rivers[k] = h, river
			end
			return h, rivers[k]
		end
	end

	type Tally = {
		cells: number, -- carved cells checked
		low: number, -- of them at or below sea level
		valley: number, -- in a river valley
		justAbove: number, -- in a column just above WET (sea level + 3)
		closest: number, -- closest a low or valley cell came to a column at or below WET
		lowStep: number, -- closest a step dry() checks came to water, beyond its radius
		valleyStep: number, -- ... of the steps in a river valley
		breaches: number,
		first: string?, -- the first breach of the rule
	}

	local function newTally(): Tally
		return {
			cells = 0,
			low = 0,
			valley = 0,
			justAbove = 0,
			closest = math.huge,
			lowStep = math.huge,
			valleyStep = math.huge,
			breaches = 0,
			first = nil,
		}
	end

	local function breach(tally: Tally, what: string)
		tally.breaches += 1
		if tally.first == nil then
			tally.first = what
		end
	end

	--[[
		The water rule over the cells surface caves carved into a chunk, on terrain `surfaceAt`
		(full detail heights and river strengths, whole columns). The checker takes the chunk's
		level and node, its data with (`on`) and without (`off`) surface caves and the surface
		height of a column at its level, and looks at every carved cell of its core (Air in `on`
		where `off` has something else, below the surface). None may
		  * touch water, ice or another fluid on its six sides;
		  * be in a column at or below WET at that level;
		  * at or below sea level, be closer than DRY_MARGIN blocks to a column at or below WET;
		  * in a river valley (river strength above 0), be closer than DRY_MARGIN + RIVER_MARGIN.
	]]
	local function waterRule(
		surfaceAt: SurfaceCaves.SurfaceSampler
	): (number, number, number, buffer, buffer, (number, number) -> number, Tally) -> ()
		local surface = cached(surfaceAt)
		local nearest: { [number]: number } = {}
		-- Distance from column (x, z) to the nearest column at or below WET (math.huge: none
		-- within SEARCH blocks).
		local function nearestWet(x: number, z: number): number
			local k = x * 1048576 + z
			local d = nearest[k]
			if d == nil then
				local best = math.huge
				for dz = -SEARCH, SEARCH do
					for dx = -SEARCH, SEARCH do
						local d2 = dx * dx + dz * dz
						if d2 < best and d2 <= SEARCH * SEARCH and (surface(x + dx, z + dz)) <= WET then
							best = d2
						end
					end
				end
				d = math.sqrt(best)
				nearest[k] = d
			end
			return d
		end
		return function(level, nx, nz, on, off, levelHeight, tally)
			local step, stepY = ChunkLayout.steps(level)
			local half, halfY = step // 2, stepY // 2
			local span = SIZE * step
			local cells = ChunkLayout.height(on)
			for lz = 0, SIZE - 1 do
				for lx = 0, SIZE - 1 do
					local x, z = nx * span + lx * step + half, nz * span + lz * step + half
					local h = levelHeight(x, z)
					local _, river = surface(x, z)
					for cy = 1, math.min((h - halfY + stepY - 1) // stepY - 1, cells - 2) do
						if ChunkLayout.get(on, lx, cy, lz) ~= AIR or ChunkLayout.get(off, lx, cy, lz) == AIR then
							continue
						end
						local y = cy * stepY + halfY
						local at = `at {x}, {y}, {z} (level {level})`
						tally.cells += 1
						for _, d in SIX do
							local n = ChunkLayout.get(on, lx + d[1], cy + d[2], lz + d[3])
							if WATERY[n] then
								breach(tally, `carved air next to {Blocks.get(n).name} {at}`)
							end
						end
						if h <= WET then
							breach(tally, `carved in a column at {h} {at}`)
						elseif h == WET + 1 then
							tally.justAbove += 1
						end
						if y <= SEA or river > 0 then
							local d = nearestWet(x, z)
							tally.closest = math.min(tally.closest, d)
							if y <= SEA then
								tally.low += 1
								if d < DRY_MARGIN then
									breach(tally, `carved below sea level {blocks(d)} blocks from water {at}`)
								end
							end
							if river > 0 then
								tally.valley += 1
								if d < DRY_MARGIN + RIVER_MARGIN then
									breach(tally, `carved in a river valley {blocks(d)} blocks from water {at}`)
								end
							end
						end
					end
				end
			end
		end
	end

	--[[
		dry() on its own 4 block grid: no step of `list` that may reach below sea level + 1, or
		lies in a river valley, may have a sample of `surface` at or below WET within its radius +
		DRY_MARGIN (+ RIVER_MARGIN in a valley). Into `tally`, with how close they come to one.
	]]
	local function stepCheck(list: { SurfaceCaves.Worm }, surface: SurfaceCaves.SurfaceSampler, tally: Tally)
		for _, worm in list do
			for s = 1, worm.count do
				local x, z, r = worm.x[s], worm.z[s], worm.h[s]
				local bottom = if worm.kind == "ravine" then worm.y[s] else worm.y[s] - worm.v[s]
				local _, river = surface(math.floor(x), math.floor(z))
				if bottom > SEA + 1 and river <= 0 then
					continue
				end
				local margin = DRY_MARGIN + (if river > 0 then RIVER_MARGIN else 0)
				local m = r + WATCH
				for gz = math.floor((z - m) / 4), math.ceil((z + m) / 4) do
					for gx = math.floor((x - m) / 4), math.ceil((x + m) / 4) do
						if (surface(gx * 4, gz * 4)) <= WET then
							local d = math.sqrt((gx * 4 - x) ^ 2 + (gz * 4 - z) ^ 2) - r
							if river > 0 then
								tally.valleyStep = math.min(tally.valleyStep, d)
							else
								tally.lowStep = math.min(tally.lowStep, d)
							end
							if d < margin then
								breach(
									tally,
									`a {worm.kind} step at {math.floor(x)}, {math.floor(z)} has water {blocks(d)} blocks beyond its radius`
								)
							end
						end
					end
				end
			end
		end
	end

	--[[
		The full detail chunks (cx, cz) whose padded box a step of `list` reaches that comes within
		WATCH blocks (beyond its radius) of a column of `surface` at or below `limit` (probed on a 4
		block grid), and how many of the worms have such a step.
	]]
	local function chunksNear(
		list: { SurfaceCaves.Worm },
		surface: SurfaceCaves.SurfaceSampler,
		limit: number
	): ({ { number } }, number)
		local seen, chunks, near = {}, {}, 0
		for _, worm in list do
			local any = false
			for s = 1, worm.count do
				local x, z, r = worm.x[s], worm.z[s], worm.h[s]
				local m = r + WATCH
				local hit = false
				for gz = math.floor((z - m) / 4), math.ceil((z + m) / 4) do
					for gx = math.floor((x - m) / 4), math.ceil((x + m) / 4) do
						if (surface(gx * 4, gz * 4)) <= limit then
							hit = true
							break
						end
					end
					if hit then
						break
					end
				end
				if hit then
					any = true
					for cz = (math.floor(z - r) - 1) // SIZE, (math.ceil(z + r) + 1) // SIZE do
						for cx = (math.floor(x - r) - 1) // SIZE, (math.ceil(x + r) + 1) // SIZE do
							local key = cx * 100000 + cz
							if not seen[key] then
								seen[key] = true
								table.insert(chunks, { cx, cz })
							end
						end
					end
				end
			end
			if any then
				near += 1
			end
		end
		return chunks, near
	end

	-- The nodes of `level` holding the full detail chunks `chunks`.
	local function nodesOf(chunks: { { number } }, level: number): { { number } }
		local span = SIZE * bit32.lshift(1, level)
		local seen, nodes = {}, {}
		for _, c in chunks do
			local nx, nz = (c[1] * SIZE) // span, (c[2] * SIZE) // span
			if not seen[nx * 100000 + nz] then
				seen[nx * 100000 + nz] = true
				table.insert(nodes, { nx, nz })
			end
		end
		return nodes
	end

	--[[
		Coasts (`river` false) or river banks of `surface`: points of a 64 block grid within 4 km of
		the origin at or below WET, out of river valleys or in one, with land well above the sea
		(sea level + 8) next to them; the nearest six at least 448 blocks apart.
	]]
	local function shores(surface: SurfaceCaves.SurfaceSampler, river: boolean): { { number } }
		local GRID, SPAN = 64, 4096
		local points = {}
		for gz = -SPAN // GRID + 1, SPAN // GRID - 1 do
			for gx = -SPAN // GRID + 1, SPAN // GRID - 1 do
				local h, r = surface(gx * GRID, gz * GRID)
				if h <= WET and (r > 0) == river then
					for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
						if (surface((gx + d[1]) * GRID, (gz + d[2]) * GRID)) > SEA + 8 then
							table.insert(points, { gx * GRID, gz * GRID })
							break
						end
					end
				end
			end
		end
		table.sort(points, function(a, b)
			local da, db = a[1] * a[1] + a[2] * a[2], b[1] * b[1] + b[2] * b[2]
			if da ~= db then
				return da < db
			end
			return if a[1] ~= b[1] then a[1] < b[1] else a[2] < b[2]
		end)
		local picked = {}
		for _, p in points do
			local apart = true
			for _, q in picked do
				if math.abs(p[1] - q[1]) < 448 and math.abs(p[2] - q[2]) < 448 then
					apart = false
					break
				end
			end
			if apart then
				table.insert(picked, p)
				if #picked == 6 then
					break
				end
			end
		end
		return picked
	end

	--[[
		On the coasts or river banks of `seed`: the worms within 160 blocks of each shore point,
		dry() on their steps, and the chunks where they come near the water, generated at levels 0
		to MAX_LEVEL with and without surface caves, with the water rule on their cells (all into
		`tally`). Every worm must be long enough. Prints what it looked at.
	]]
	local function shoreCheck(seed: number, river: boolean, tally: Tally)
		local g = if seed == SEED then gen else TerrainGenerator.new(seed, { structures = false })
		local plain = TerrainGenerator.new(seed, { structures = false }) -- (only without surface caves)
		local relief = Relief.new(seed)
		local surface = cached(function(x: number, z: number): (number, number)
			local _, _, _, strength = relief.height(x, z, 0)
			return (g.column(x, z)), strength
		end)
		local list, seen = {}, {}
		for _, p in shores(surface, river) do
			for _, worm in g.surfaceCaves.worms(p[1] - 160, p[2] - 160, p[1] + 160, p[2] + 160) do
				if not seen[worm] then
					seen[worm] = true
					table.insert(list, worm)
					if worm.count < MIN_STEPS[worm.kind] then
						breach(tally, `a {worm.kind} of {worm.count} steps`)
					end
				end
			end
		end
		stepCheck(list, surface, tally)
		local chunks, near = chunksNear(list, surface, WET)
		local check = waterRule(surface)
		local cells, generated = tally.cells, 0
		for level = 0, SurfaceCaves.MAX_LEVEL do
			local levelHeight = if level == 0
				then function(x: number, z: number): number
					return (surface(x, z))
				end
				else function(x: number, z: number): number
					return math.max(math.floor((relief.height(x, z, level))), 2)
				end
			for _, n in nodesOf(chunks, level) do
				local on = g.generate(level, n[1], n[2])
				local off = withoutSurfaceCaves(function()
					return plain.generate(level, n[1], n[2])
				end)
				check(level, n[1], n[2], on.data, off.data, levelHeight, tally)
				generated += 1
			end
		end
		print(
			`    seed {seed}: {#list} worms, {near} near {if river then "a river" else "the sea"}, {generated} nodes (levels 0-{SurfaceCaves.MAX_LEVEL}), {tally.cells - cells} carved cells`
		)
	end

	t.test("surface caves: never at water on real coasts (seeds 12345, 777, 2024, levels 0-2)", function()
		local tally = newTally()
		for _, seed in { SEED, 777, 2024 } do
			shoreCheck(seed, false, tally)
		end
		local closest, step = blocks(tally.closest), blocks(tally.lowStep)
		print(
			`    {tally.low} carved cells below sea level, {tally.valley} in river valleys: closest to water {closest}; low steps come {step} blocks beyond their radius from water`
		)
		t.eq(tally.breaches, 0, tally.first or "breaches of the water rule")
		t.ok(tally.low > 1000, "carved cells below sea level by the sea")
		t.ok(tally.lowStep < DRY_MARGIN + 8, "worms run up to the margin")
	end)

	t.test("surface caves: river valleys keep their margin (seeds 12345, 777, 2024, levels 0-2)", function()
		local tally = newTally()
		for _, seed in { SEED, 777, 2024 } do
			shoreCheck(seed, true, tally)
		end
		local closest, step = blocks(tally.closest), blocks(tally.valleyStep)
		print(
			`    {tally.valley} carved cells in river valleys, {tally.low} below sea level: closest to water {closest}; valley steps come {step} blocks beyond their radius from water`
		)
		t.eq(tally.breaches, 0, tally.first or "breaches of the water rule")
		t.ok(tally.valley > 1000, "carved cells in river valleys")
		t.ok(tally.valleyStep < DRY_MARGIN + RIVER_MARGIN + 8, "worms run up to the margin")
	end)

	t.test("surface caves: the water rule on a synthetic coast, beach, lowland and river valley", function()
		--[[
			Bands across x, the same along z, every PERIOD blocks: two stretches of coastal land at
			sea level + 12 with a sea 20 deep between them (behind cliffs, frozen over), lowland at
			sea level + 3 and + 4 (carved, but too low for a worm to start on), a beach at WET (never
			carved, and as wet as the sea for the margins) and a river valley (river strength 1 in
			its middle, 0 at its rims) holding some 130 blocks of water; its banks above START_ABOVE
			reach a river strength of 0.53. Every band starts on the 4 block grid and is wider than
			it, so dry() sees all of the water.
		]]
		local PERIOD = 640
		local function fakeSurface(x: number, _z: number): (number, number)
			local u = x % PERIOD
			if u < 96 then
				return SEA + 12, 0
			elseif u < 160 then
				return SEA - 20, 0
			elseif u < 256 then
				return SEA + 12, 0
			elseif u < 288 then
				return SEA + 3, 0
			elseif u < 320 then
				return SEA + 4, 0
			elseif u < 352 then
				return WET, 0
			end
			local a = 1 - math.abs(u - 496) / 144
			local river = a * a * (3 - 2 * a)
			return math.floor(SEA + 24 - 38 * river), river
		end
		local fake = SurfaceCaves.new(SEED, fakeSurface)
		-- The same world without water (the sea, the beach and the river filled up to sea level
		-- + 12): which worms the water stops or drops.
		local dryTwin = SurfaceCaves.new(SEED, function(x: number, z: number): (number, number)
			local h, river = fakeSurface(x, z)
			return if h <= WET then SEA + 12 else h, river
		end)
		local X0, X1, Z0, Z1 = 0, 2 * PERIOD - 1, -1024, 1023
		local list = fake.worms(X0, Z0, X1, Z1)

		-- Each worm: where it starts, its length, and every step that may reach below sea level
		-- + 1 or lies in the river valley clear of every column at or below WET (not only dry()'s
		-- samples) by its radius + the margin.
		local worms = newTally()
		for _, worm in list do
			local h, river = fakeSurface(worm.startX, worm.startZ)
			if h <= START_ABOVE or river >= RIVER_START then
				breach(worms, `a {worm.kind} starts at {h} with river strength {river}`)
			end
			if worm.count < MIN_STEPS[worm.kind] then
				breach(worms, `a {worm.kind} of {worm.count} steps`)
			end
			for s = 1, worm.count do
				local cx, r = worm.x[s], worm.h[s]
				local bottom = if worm.kind == "ravine" then worm.y[s] else worm.y[s] - worm.v[s]
				local _, strength = fakeSurface(cx, worm.z[s])
				if bottom > SEA + 1 and strength <= 0 then
					continue
				end
				local margin = DRY_MARGIN + (if strength > 0 then RIVER_MARGIN else 0)
				for x = math.floor(cx - r - SEARCH), math.ceil(cx + r + SEARCH) do
					if (fakeSurface(x, 0)) <= WET then
						local d = math.abs(x + 0.5 - cx) - r
						if strength > 0 then
							worms.valleyStep = math.min(worms.valleyStep, d)
						else
							worms.lowStep = math.min(worms.lowStep, d)
						end
						if d < margin then
							local at = math.floor(cx)
							breach(worms, `a {worm.kind} step at {at} has water {blocks(d)} blocks beyond its radius`)
						end
					end
				end
			end
		end

		-- The worms of the same cells in the dry twin, from the same start: the water drops some and
		-- stops others short.
		local wet: { [string]: SurfaceCaves.Worm } = {}
		for _, worm in fake.worms(X0 - 200, Z0 - 200, X1 + 200, Z1 + 200) do
			wet[`{worm.kind} {worm.cellX} {worm.cellZ}`] = worm
		end
		local dropped, shortened = 0, 0
		for _, worm in dryTwin.worms(X0, Z0, X1, Z1) do
			if (fakeSurface(worm.startX, worm.startZ)) > WET then
				local twin = wet[`{worm.kind} {worm.cellX} {worm.cellZ}`]
				if twin == nil then
					dropped += 1
				elseif twin.count < worm.count then
					shortened += 1
				end
			end
		end

		-- The chunks where the worms come near the water or the lowland, filled like TerrainGenerator
		-- does (bedrock, stone, a grass top, water up to sea level with ice on the sea) at levels 0
		-- to MAX_LEVEL, then carved (and before). `claimWet(px, pz)`: carve is told that padded
		-- column's surface is at WET (its blocks stay as they are).
		local P = ChunkLayout.PADDED
		local function carved(
			level: number,
			nx: number,
			nz: number,
			claimWet: ((number, number) -> boolean)?
		): (buffer, buffer)
			local step, stepY = ChunkLayout.steps(level)
			local half, halfY = step // 2, stepY // 2
			local originX, originZ = nx * SIZE * step, nz * SIZE * step
			local cells = ChunkLayout.croppedHeight((SEA + 40) // stepY, stepY)
			local data = ChunkLayout.create(cells)
			local heights, topCells = {}, {}
			local waterTop = (SEA - halfY + stepY - 1) // stepY - 1
			for pz = 0, P - 1 do
				for px = 0, P - 1 do
					local h, river = fakeSurface(originX + (px - 1) * step + half, originZ + (pz - 1) * step + half)
					local top = (h - halfY + stepY - 1) // stepY - 1
					heights[pz * P + px + 1], topCells[pz * P + px + 1] = h, top
					if claimWet and claimWet(px, pz) then
						heights[pz * P + px + 1] = WET
					end
					ChunkLayout.setPadded(data, px - 1, 0, pz - 1, Blocks.id.Bedrock)
					for y = 1, top do
						local id = if y == top then Blocks.id.Grass else Blocks.id.Stone
						ChunkLayout.setPadded(data, px - 1, y, pz - 1, id)
					end
					for y = top + 1, waterTop do
						local id = if y == waterTop and river == 0 then Blocks.id.Ice else WATER
						ChunkLayout.setPadded(data, px - 1, y, pz - 1, id)
					end
				end
			end
			local before = buffer.create(buffer.len(data))
			buffer.copy(before, 0, data)
			fake.carve(data, level, originX, originZ, heights, topCells, cells)
			return data, before
		end
		local check = waterRule(fakeSurface)
		local tally = newTally()
		local chunks, near = chunksNear(list, fakeSurface, WET + 2)
		local function height(x: number, z: number): number
			return (fakeSurface(x, z))
		end
		for level = 0, SurfaceCaves.MAX_LEVEL do
			for _, n in nodesOf(chunks, level) do
				local on, off = carved(level, n[1], n[2])
				check(level, n[1], n[2], on, off, height, tally)
			end
		end
		-- carve() itself never touches a column it is told is at or below WET, whatever the worms:
		-- the full detail chunks again, every other column said to be at WET.
		local function claimed(px: number, pz: number): boolean
			return (px + pz) % 2 == 0
		end
		local kept, cut = 0, 0
		for _, c in chunks do
			local on, off = carved(0, c[1], c[2], claimed)
			for pz = 0, P - 1 do
				for px = 0, P - 1 do
					for y = 1, ChunkLayout.height(on) - 1 do
						if
							ChunkLayout.getPadded(on, px - 1, y, pz - 1)
							~= ChunkLayout.getPadded(off, px - 1, y, pz - 1)
						then
							if claimed(px, pz) then
								kept += 1
							else
								cut += 1
							end
						end
					end
				end
			end
		end

		local lowStep, valleyStep, closest = blocks(worms.lowStep), blocks(worms.valleyStep), blocks(tally.closest)
		print(
			`    {#list} worms, {near} near water or lowland: {dropped} dropped, {shortened} stopped short; low steps come {lowStep} blocks beyond their radius from water, valley steps {valleyStep}`
		)
		print(
			`    {#chunks} chunks (levels 0-{SurfaceCaves.MAX_LEVEL}): {tally.cells} carved cells, {tally.low} below sea level, {tally.valley} in the valley, {tally.justAbove} at sea level + 3; closest to water {closest}`
		)
		print(`    told every other column is at WET, carve() changes {kept} cells in them and {cut} in the others`)
		t.eq(worms.breaches, 0, worms.first or "worms breaking the water rule")
		t.eq(tally.breaches, 0, tally.first or "carved cells breaking the water rule")
		t.ok(dropped > 0 and shortened > 0, "the water drops some worms and stops others short")
		t.ok(
			worms.lowStep < DRY_MARGIN + 4 and worms.valleyStep < DRY_MARGIN + RIVER_MARGIN + 4,
			"worms run up to the margins"
		)
		t.ok(tally.low > 1000 and tally.valley > 1000, "carved cells below sea level and in the valley")
		t.ok(tally.justAbove > 0, "lowland just above WET is carved")
		t.eq(kept, 0, "cells carve() changed in columns at WET")
		t.ok(cut > 1000, "carved cells in the other columns")
	end)

	t.test("surface caves: ores never fill carved air", function()
		for _, c in chunksOf(ravine) do
			local r = chunk(c[1], c[2])
			local off = withoutSurfaceCaves(function()
				return TerrainGenerator.new(SEED, { structures = false }).generate(0, c[1], c[2])
			end)
			for i = 0, buffer.len(r.data) // 2 - 1 do
				local id = buffer.readu16(r.data, i * 2)
				if isOre[id] then
					t.eq(buffer.readu16(off.data, i * 2), id, "an ore the carving did not have")
				end
			end
		end
	end)

	t.test("surface caves: no tree or plant over a hole; carvesTop covers every carved top", function()
		local LOG: { [number]: boolean } = {}
		for _, name in { "OakLog", "BirchLog", "SpruceLog", "AcaciaLog", "JungleLog", "Cactus" } do
			LOG[Blocks.id[name]] = true
		end
		local openTops, trees, plants = 0, 0, 0
		for _, worm in { entrance, ravine } do
			for _, c in chunksOf(worm) do
				local r = chunk(c[1], c[2])
				for lz = 0, SIZE - 1 do
					for lx = 0, SIZE - 1 do
						local x, z = c[1] * SIZE + lx, c[2] * SIZE + lz
						local h = gen.column(x, z)
						if h >= r.height then
							continue
						end
						local top = ChunkLayout.get(r.data, lx, h - 1, lz)
						if top == AIR then
							openTops += 1
							t.ok(sc.carvesTop(x, z), `carvesTop misses the open column {x}, {z}`)
						end
						local above = ChunkLayout.get(r.data, lx, h, lz)
						if LOG[above] then
							trees += 1
							t.ok(top ~= AIR, "a trunk over a hole")
						end
						for y = 1, r.height - 1 do
							local id = ChunkLayout.get(r.data, lx, y, lz)
							if Blocks.isPlant(id) and Blocks.plantBottom(id) == nil then
								plants += 1
								t.ok(ChunkLayout.get(r.data, lx, y - 1, lz) ~= AIR, "a plant over a hole")
							end
						end
					end
				end
			end
		end
		t.ok(openTops > 50, `open columns: {openTops}`)
		print(`    {openTops} open columns, {trees} trunks and {plants} plants next to them`)
	end)

	t.test("surface caves: spawns never land in a pit", function()
		local x, h, z = gen.findSpawn()
		t.ok(not sc.carvesTop(x, z), "the spawn column")
		t.ok(h > SEA)
		local WorldServer = require(server.World.WorldServer)
		local SafeSpot = require(server.Players.SafeSpot)
		local world = WorldServer.new(gen)
		-- An open column of the entrance: no spot in it, and the nearest one stands on ground.
		local px, pz
		for s = 1, entrance.count do
			local cx, cz = math.floor(entrance.x[s]), math.floor(entrance.z[s])
			local surface = gen.column(cx, cz)
			if world:getBlock(cx, surface - 1, cz) == AIR then
				px, pz = cx, cz
				break
			end
		end
		assert(px and pz, "no open column")
		t.eq(SafeSpot.column(world, px, pz), nil, "a spot in the pit")
		local fx, fy, fz = SafeSpot.find(world, px, pz)
		assert(fx)
		t.ok(fy >= gen.column(fx, fz), "not below the natural surface")
		t.ok(Blocks.isSolid(world:getBlock(fx, fy - 1, fz)), "on solid ground")
	end)

	t.test("surface caves: solidBelow covers the carved air", function()
		local cull = Blocks.cullLutHiddenCaves
		for _, worm in { entrance, ravine } do
			local list = chunksOf(worm)
			for k = 1, #list, 3 do
				local r = chunk(list[k][1], list[k][2])
				for y = 0, r.solidBelow - 1 do
					for i = 0, ChunkLayout.LAYER - 1 do
						local id = buffer.readu16(r.data, (y * ChunkLayout.LAYER + i) * 2)
						t.ok(buffer.readu8(cull, id) == 1, `cell below solidBelow is not solid (y={y})`)
					end
				end
			end
		end
	end)

	t.test("surface caves: LOD chunks 1 and 2 point-sample the ravine", function()
		for level = 1, SurfaceCaves.MAX_LEVEL do
			local step, stepY = ChunkLayout.steps(level)
			local half, halfY = step // 2, stepY // 2
			local s = ravine.count // 2
			local nx, nz = math.floor(ravine.x[s]) // (SIZE * step), math.floor(ravine.z[s]) // (SIZE * step)
			local r = gen.generate(level, nx, nz)
			local carved, matching = 0, 0
			for lz = 0, SIZE - 1 do
				for lx = 0, SIZE - 1 do
					local x = nx * SIZE * step + lx * step + half
					local z = nz * SIZE * step + lz * step + half
					local h = gen.column(x, z)
					local fine = chunk(x // SIZE, z // SIZE)
					-- (A few blocks below the surface: LOD heights differ a little.)
					for cy = 1, math.min(r.height - 1, (h - 4 - halfY) // stepY) do
						if ChunkLayout.get(r.data, lx, cy, lz) == AIR then
							carved += 1
							local y = cy * stepY + halfY
							local id = if y < fine.height
								then ChunkLayout.get(fine.data, x % SIZE, y, z % SIZE)
								else AIR
							-- (Where the ravine meets a cave, the cave air stays.)
							if id == AIR or norm(id) == CAVE then
								matching += 1
							end
						end
					end
				end
			end
			print(`    level {level}: {carved} carved cells, {matching} carved at full detail too`)
			t.ok(carved > 10, `level {level}: the ravine shows`)
			t.ok(matching >= carved * 0.9, `level {level}: cells carved at their sample block`)
		end
	end)

	t.test("surface caves: entrances and ravines on ordinary land, their shapes", function()
		local list = sc.worms(-2000, -2000, 2000, 2000)
		local entrances, ravines, branched = 0, 0, 0
		for _, worm in list do
			if worm.kind == "entrance" then
				entrances += 1
				if worm.branched then
					branched += 1
				end
				for s = 1, worm.count do
					-- (The end chambers are up to 1.3 times the widest tunnel.)
					t.ok(
						worm.h[s] >= entranceCfg.Radius[1] and worm.h[s] <= entranceCfg.Radius[2] * 1.3 + 1e-9,
						"radius"
					)
					t.ok(worm.y[s] - worm.v[s] >= Config.Caves.MinY, "above MinY")
				end
				t.ok(worm.count <= entranceCfg.Length[2] + 41 + 2, "length")
			else
				ravines += 1
				local s = worm.count // 2
				local depth = gen.column(math.floor(worm.x[s]), math.floor(worm.z[s])) - worm.y[s]
				t.ok(depth >= 0 and depth <= ravineCfg.Depth[2] + 30, `ravine depth {depth}`)
			end
		end
		local km2 = 16
		print(
			`    within 2 km of the origin: {entrances / km2} entrances per km2 ({branched} branched), {ravines / km2} ravines`
		)
		t.ok(entrances / km2 > 15 and entrances / km2 < 120, "entrances every few hundred blocks")
		t.ok(ravines >= 4, "ravines")
		t.ok(branched > 0, "some entrances branch")
		-- The entrance fixture runs down from the surface to its depth.
		local h0 = gen.column(math.floor(entrance.x[1]), math.floor(entrance.z[1]))
		local deepest = math.huge
		for s = 1, entrance.count do
			deepest = math.min(deepest, entrance.y[s])
		end
		t.ok(h0 - deepest >= entranceCfg.Depth[1] - 5, `the entrance goes {h0 - deepest} blocks down`)
	end)

	t.test("surface caves: mountain slopes get mouths", function()
		-- High, steep ground: the selector of the extreme mountains.
		local rng = Hash.rng(77)
		local mouths, worms = 0, 0
		for _ = 1, 400 do
			local x, z = rng:int(-30000, 30000), rng:int(-30000, 30000)
			if gen.column(x, z) > 300 then
				for _, worm in sc.worms(x - 200, z - 200, x + 200, z + 200) do
					if worm.kind == "entrance" then
						worms += 1
						if worm.mouth then
							mouths += 1
						end
					end
				end
				if worms > 20 then
					break
				end
			end
		end
		t.ok(worms > 0, "entrances in the mountains")
		t.ok(mouths >= worms * 0.25, `{mouths} of {worms} mountain entrances are mouths`)
	end)

	t.test("surface caves: protected columns and switched off kinds are left alone", function()
		local c = chunksOf(ravine)[4]
		local off = withoutSurfaceCaves(function()
			return TerrainGenerator.new(SEED, { structures = false }).generate(0, c[1], c[2])
		end)
		local on = chunk(c[1], c[2])
		t.ok(buffer.tostring(on.data) ~= buffer.tostring(off.data), "the ravine carves this chunk")
		-- Carving the uncarved chunk again with every column protected changes nothing.
		local data = buffer.create(buffer.len(off.data))
		buffer.copy(data, 0, off.data)
		local P = ChunkLayout.PADDED
		local heights, topCells, protected = {}, {}, {}
		for pz = 0, P - 1 do
			for px = 0, P - 1 do
				local h = gen.column(c[1] * SIZE + px - 1, c[2] * SIZE + pz - 1)
				heights[pz * P + px + 1], topCells[pz * P + px + 1] = h, h - 1
				protected[pz * P + px + 1] = true
			end
		end
		local lowest = sc.carve(data, 0, c[1] * SIZE, c[2] * SIZE, heights, topCells, off.height, protected)
		t.eq(lowest, math.huge, "nothing carved")
		t.eq(buffer.tostring(data), buffer.tostring(off.data), "protected columns")
		-- Unprotected, the carver alone gives the generated chunk's air.
		local lowest2 = sc.carve(data, 0, c[1] * SIZE, c[2] * SIZE, heights, topCells, off.height, nil)
		t.ok(lowest2 < math.huge, "carved")
		local differ = 0
		for pz = 0, P - 1 do
			for px = 0, P - 1 do
				for y = 0, heights[pz * P + px + 1] - 1 do
					local a = ChunkLayout.getPadded(data, px - 1, y, pz - 1)
					local b = ChunkLayout.getPadded(on.data, px - 1, y, pz - 1)
					if (a == AIR) ~= (b == AIR) then
						differ += 1
					end
				end
			end
		end
		t.eq(differ, 0, "the same air as the generator's (before ores, trees and plants)")
	end)

	t.test("surface caves: none next to a library structure's pieces", function()
		local withLibrary = TerrainGenerator.new(SEED)
		local start
		for _, st in withLibrary.structures(-1600, -1600, 1600, 1600) do
			local b = st.bounds
			if #withLibrary.surfaceCaves.worms(b[1] - 8, b[3] - 8, b[4] + 8, b[6] + 8) > 0 then
				start = st
				break
			end
		end
		assert(start, "a structure next to a worm")
		local b = start.bounds
		local near, elsewhere = 0, 0
		for cz = (b[3] - 8) // SIZE, (b[6] + 8) // SIZE do
			for cx = (b[1] - 8) // SIZE, (b[4] + 8) // SIZE do
				local on = withLibrary.generate(0, cx, cz)
				local off = withoutSurfaceCaves(function()
					return TerrainGenerator.new(SEED).generate(0, cx, cz)
				end)
				for lz = 0, SIZE - 1 do
					for lx = 0, SIZE - 1 do
						local x, z = cx * SIZE + lx, cz * SIZE + lz
						local nearPiece = false
						for _, piece in start.pieces do
							local box = piece.box
							if x >= box[1] - 2 and x <= box[4] + 2 and z >= box[3] - 2 and z <= box[6] + 2 then
								nearPiece = true
							end
						end
						local h = gen.column(x, z)
						for y = 1, math.min(h, on.height) - 1 do
							local a = ChunkLayout.get(on.data, lx, y, lz)
							if a == AIR and ChunkLayout.get(off.data, lx, y, lz) ~= AIR then
								if nearPiece then
									near += 1
								else
									elsewhere += 1
								end
							end
						end
					end
				end
			end
		end
		print(`    {start.name} at {b[1]}, {b[3]}: {elsewhere} carved cells around it, {near} next to its pieces`)
		t.ok(elsewhere > 0, "a worm carves around the structure")
		t.eq(near, 0, "carved cells next to the structure's pieces")
	end)

	-- The cells an entrance worm carves on its own, from its steps alone (the rule `carve` uses at
	-- full detail, ignoring the terrain): key (x, y, z) -> { x, y, z }.
	local function wormCells(worm: SurfaceCaves.Worm, last: number?): { [number]: { number } }
		local cells = {}
		for s = 1, last or worm.count do
			local cx, cy, cz, hr, vr, fl = worm.x[s], worm.y[s], worm.z[s], worm.h[s], worm.v[s], worm.floor[s]
			for x = math.floor(cx - hr), math.ceil(cx + hr) do
				for z = math.floor(cz - hr), math.ceil(cz + hr) do
					local dx, dz = (x + 0.5 - cx) / hr, (z + 0.5 - cz) / hr
					local d2 = dx * dx + dz * dz
					if d2 < 1 then
						local sq = math.sqrt(1 - d2)
						local lo = math.max(-sq, fl)
						for y = math.floor(cy + lo * vr - 0.5) + 1, math.ceil(cy + sq * vr - 0.5) - 1 do
							cells[(x * 8192 + z) * 2048 + y] = { x, y, z }
						end
					end
				end
			end
		end
		return cells
	end

	t.test("surface caves: entrance tunnels are continuous and can be walked down", function()
		local list = sc.worms(-1000, -1000, 1000, 1000)
		local entrances, pieces, walkable, widest = 0, 0, 0, 0
		local DIRS = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }
		local function key(x: number, y: number, z: number): number
			return (x * 8192 + z) * 2048 + y
		end
		for _, worm in list do
			if worm.kind ~= "entrance" then
				continue
			end
			entrances += 1
			-- The main tunnel: up to where the branch starts (a jump back to the fork).
			local last = worm.count
			for s = 2, worm.count do
				local dx, dy, dz = worm.x[s] - worm.x[s - 1], worm.y[s] - worm.y[s - 1], worm.z[s] - worm.z[s - 1]
				local gap = math.sqrt(dx * dx + dy * dy + dz * dz)
				if gap > 6 then
					last = math.min(last, s - 1)
				else
					-- (Never two steps skipped in a row; the end chamber is a step past the last.)
					widest = math.max(widest, gap)
				end
			end
			-- Face-connected pieces of all of its cells (a wall across the tunnel splits it).
			local cells = wormCells(worm)
			local seen, count = {}, 0
			for k, c in cells do
				if seen[k] then
					continue
				end
				count += 1
				seen[k] = true
				local queue, qi = { c }, 1
				while qi <= #queue do
					local p = queue[qi]
					qi += 1
					for _, d in DIRS do
						local n = key(p[1] + d[1], p[2] + d[2], p[3] + d[3])
						if cells[n] and not seen[n] then
							seen[n] = true
							table.insert(queue, cells[n])
						end
					end
				end
			end
			if count > 1 then
				pieces += 1
			end
			-- Walk the main tunnel down: two cells of head room, up a block or down at most 3.
			local main = wormCells(worm, last)
			local function air(x: number, y: number, z: number): boolean
				return main[key(x, y, z)] ~= nil
			end
			local function stand(x: number, y: number, z: number): boolean
				return air(x, y, z) and air(x, y + 1, z) and not air(x, y - 1, z)
			end
			local sx, sy, sz = math.floor(worm.x[1]), math.floor(worm.y[1]), math.floor(worm.z[1])
			local queue, visited = {}, {}
			for x = sx - 3, sx + 3 do
				for z = sz - 3, sz + 3 do
					for y = sy - 4, sy + 2 do
						if stand(x, y, z) then
							visited[key(x, y, z)] = true
							table.insert(queue, { x, y, z })
						end
					end
				end
			end
			local ex, ey, ez = worm.x[last], worm.y[last], worm.z[last]
			local qi, reached = 1, false
			while qi <= #queue and not reached do
				local p = queue[qi]
				qi += 1
				local x, y, z = p[1], p[2], p[3]
				if (x + 0.5 - ex) ^ 2 + (z + 0.5 - ez) ^ 2 <= 4 and math.abs(y - ey) <= 4 then
					reached = true
				end
				for _, d in DIRS do
					if d[2] ~= 0 then
						continue
					end
					local nx, nz = x + d[1], z + d[3]
					local ny = nil
					if stand(nx, y + 1, nz) and air(x, y + 2, z) then
						ny = y + 1
					elseif air(nx, y, nz) and air(nx, y + 1, nz) then
						ny = y
						while air(nx, ny - 1, nz) and y - ny < 4 do
							ny -= 1
						end
						if y - ny > 3 then
							ny = nil
						end
					end
					if ny and not visited[key(nx, ny, nz)] then
						visited[key(nx, ny, nz)] = true
						table.insert(queue, { nx, ny, nz })
					end
				end
			end
			if reached then
				walkable += 1
			end
		end
		local gap = math.floor(widest * 100) / 100
		print(
			`    {entrances} entrances within 1 km: {pieces} in more than one piece, {walkable} walkable to their end; widest gap between steps {gap}`
		)
		t.ok(entrances > 50, "entrances")
		t.eq(pieces, 0, "entrances split by a wall across the tunnel")
		t.ok(widest <= 2 + 1e-9, "never two steps skipped in a row")
		t.ok(walkable >= entrances * 0.85, "most entrances can be walked down to their end")
	end)

	t.test("surface caves: entrances go into the ground (no long open ditches)", function()
		local heights: { [number]: number } = {}
		local function column(x: number, z: number): number
			local k = x * 100000 + z
			local h = heights[k]
			if h == nil then
				h = gen.column(x, z)
				heights[k] = h
			end
			return h
		end
		local entrances, long, longest = 0, 0, 0
		for _, worm in sc.worms(-1500, -1500, 1500, 1500) do
			if worm.kind ~= "entrance" then
				continue
			end
			entrances += 1
			-- Steps that open some column's top (`carve`'s rule: they reach its top block, or leave
			-- it a roof of a single block), and the longest run of them.
			local run, best = 0, 0
			for s = 1, worm.count do
				local cx, cy, cz, hr, vr, fl = worm.x[s], worm.y[s], worm.z[s], worm.h[s], worm.v[s], worm.floor[s]
				local opens = false
				for x = math.floor(cx - hr), math.ceil(cx + hr) do
					for z = math.floor(cz - hr), math.ceil(cz + hr) do
						local dx, dz = (x + 0.5 - cx) / hr, (z + 0.5 - cz) / hr
						local d2 = dx * dx + dz * dz
						if not opens and d2 < 1 then
							local h = column(x, z)
							local sq = math.sqrt(1 - d2)
							local top = math.ceil(cy + sq * vr - 0.5) - 1
							local bottom = math.floor(cy + math.max(-sq, fl) * vr - 0.5) + 1
							opens = h > SEA + 2 and top >= h - 2 and bottom <= h - 1
						end
					end
				end
				run = if opens then run + 1 else 0
				best = math.max(best, run)
			end
			if best >= 15 then
				long += 1
			end
			longest = math.max(longest, best)
		end
		print(`    {entrances} entrances within 1.5 km: {long} open for 15+ steps in a row, at most {longest}`)
		t.ok(entrances > 100, "entrances")
		t.ok(longest < 30, "no entrance runs along the surface for 30 steps")
		t.ok(long <= entrances * 0.03, "few run open for 15 steps")
	end)

	t.test("surface caves: no floating blocks (ravine walls without overhangs, no remnants)", function()
		-- Ravines alone: every column is cut from its lowest carved cell up to its top.
		local saved = entranceCfg.Enabled
		entranceCfg.Enabled = false
		local ok, err = pcall(function()
			local ravines = TerrainGenerator.new(SEED, { structures = false })
			local overhangs, cut = 0, 0
			for _, c in chunksOf(ravine) do
				local r = ravines.generate(0, c[1], c[2])
				for lz = 0, SIZE - 1 do
					for lx = 0, SIZE - 1 do
						local h = gen.column(c[1] * SIZE + lx, c[2] * SIZE + lz)
						local carved = false
						for y = 1, math.min(h, r.height) - 1 do
							local id = ChunkLayout.get(r.data, lx, y, lz)
							if id == AIR then
								carved = true
								cut += 1
							elseif carved and Blocks.isOpaque(id) then
								overhangs += 1
							end
						end
					end
				end
			end
			t.ok(cut > 1000, "the ravine cuts")
			t.eq(overhangs, 0, "rock over a ravine's cut")
		end)
		entranceCfg.Enabled = saved
		assert(ok, err)
		-- Both kinds: no block of rock is left alone between air and cave air by the carving
		-- (off the core's edge columns, see `carve`).
		local isolated = 0
		local function alone(data: buffer, lx: number, y: number, lz: number): boolean
			for _, d in { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } } do
				local n = ChunkLayout.getPadded(data, lx + d[1], y + d[2], lz + d[3])
				if n ~= AIR and norm(n) ~= CAVE then
					return false
				end
			end
			return true
		end
		local checked = 0
		for _, worm in { entrance, ravine } do
			for _, c in chunksOf(worm) do
				local on = chunk(c[1], c[2])
				local off = withoutSurfaceCaves(function()
					return TerrainGenerator.new(SEED, { structures = false }).generate(0, c[1], c[2])
				end)
				for lz = 1, SIZE - 2 do
					for lx = 1, SIZE - 2 do
						for y = 1, math.min(on.height, off.height) - 2 do
							local id = ChunkLayout.get(on.data, lx, y, lz)
							if Blocks.isOpaque(id) and alone(on.data, lx, y, lz) then
								checked += 1
								if not alone(off.data, lx, y, lz) then
									isolated += 1
								end
							end
						end
					end
				end
			end
		end
		t.eq(isolated, 0, `blocks the carving left floating ({checked} floating ones in all)`)
	end)

	t.test("surface caves: pit floors grow the top they lost (snow in snowy biomes)", function()
		local GRASSY = {
			[Blocks.id.Grass] = true,
			[Blocks.id.DryGrass] = true,
			[Blocks.id.Podzol] = true,
			[Blocks.id.Mycelium] = true,
			[Blocks.id.Snow] = true,
		}
		-- An entrance starting in snow on dirt (Tundra), and the fixtures.
		local snowy
		for _, worm in sc.worms(-2000, -2000, 2000, 2000) do
			local x, z = math.floor(worm.startX), math.floor(worm.startZ)
			local _, biome, _, surface = gen.column(x, z)
			if
				worm.kind == "entrance"
				and surface == Blocks.id.Snow
				and Biomes.list[biome].filler == Blocks.id.Dirt
			then
				snowy = worm
				break
			end
		end
		assert(snowy, "an entrance in snow on dirt")
		local floors, dirt, snow = 0, 0, 0
		for _, worm in { snowy, entrance } do
			for _, c in chunksOf(worm) do
				local r = chunk(c[1], c[2])
				for lz = 0, SIZE - 1 do
					for lx = 0, SIZE - 1 do
						local h, _, _, surface = gen.column(c[1] * SIZE + lx, c[2] * SIZE + lz)
						if h >= r.height or not GRASSY[surface] or ChunkLayout.get(r.data, lx, h - 1, lz) ~= AIR then
							continue
						end
						local y = h - 2
						while y > 0 and ChunkLayout.get(r.data, lx, y, lz) == AIR do
							y -= 1
						end
						local floor = ChunkLayout.get(r.data, lx, y, lz)
						if h - 1 - y <= 6 then
							floors += 1
							if floor == Blocks.id.Dirt then
								dirt += 1
							elseif floor == Blocks.id.Snow then
								snow += 1
							end
						end
					end
				end
			end
		end
		print(`    {floors} shallow pit floors under grass or snow: {snow} snow, {dirt} bare dirt`)
		t.ok(snow > 0, "snow grows back on pit floors in snow")
		t.eq(dirt, 0, "bare dirt under a carved grassy or snowy top")
	end)

	-- Meshes a far node the way ChunkWorker does (farSeamLimits, caves hidden): the node's result,
	-- its drawn opaque cells (ChunkLayout.localIndex) and box count.
	local function meshFar(g: any, level: number, nx: number, nz: number): (any, { [number]: boolean }, number)
		local r = g.generate(level, nx, nz, nil, true)
		local open = g.farSeamLimits(level, nx, nz)
		local below = math.min(r.solidBelow, GreedyMesher.lowestOpen(open))
		local y0, y1 = GreedyMesher.activeRange(below, r.emptyAbove, r.height)
		local covered: { [number]: boolean } = {}
		if y1 <= y0 then
			return r, covered, 0
		end
		local border = if open then { open = open, hidden = 0 } else nil
		local boxes, count = GreedyMesher.mesh(r.data, r.height, y0, y1, true, border, true)
		for b = 0, count - 1 do
			local o = b * GreedyMesher.BOX_BYTES
			local app = GreedyMesher.decodeKey(buffer.readu16(boxes, o + 12))
			if Blocks.appearances[app].kind == Blocks.KIND_OPAQUE then
				local x, y, z = buffer.readu16(boxes, o), buffer.readu16(boxes, o + 2), buffer.readu16(boxes, o + 4)
				for yy = y, y + buffer.readu16(boxes, o + 8) - 1 do
					for zz = z, z + buffer.readu16(boxes, o + 10) - 1 do
						for xx = x, x + buffer.readu16(boxes, o + 6) - 1 do
							covered[ChunkLayout.localIndex(xx, yy, zz)] = true
						end
					end
				end
			end
		end
		return r, covered, count
	end

	t.test("surface caves: far chunks (levels 1-2) carve only what is open to the sky, for few parts", function()
		local off = withoutSurfaceCaves(function()
			return TerrainGenerator.new(SEED)
		end)
		local cull = Blocks.cullLutHiddenCaves
		for level = 1, SurfaceCaves.MAX_LEVEL do
			local span = SIZE * bit32.lshift(1, level)
			local carved, roofed, boxesOn, boxesOff = 0, 0, 0, 0
			for _, centre in { { 0, 0 }, { entrance.x[1], entrance.z[1] } } do
				for dz = -2, 2 do
					for dx = -2, 2 do
						local nx, nz = math.floor(centre[1]) // span + dx, math.floor(centre[2]) // span + dz
						local a, _, n = meshFar(gen, level, nx, nz)
						boxesOn += n
						local without = withoutSurfaceCaves(function()
							return { meshFar(off, level, nx, nz) }
						end)
						local b = without[1]
						boxesOff += without[3]
						for lz = 0, SIZE - 1 do
							for lx = 0, SIZE - 1 do
								local roof = false
								for y = math.min(a.height, b.height) - 1, 1, -1 do
									local id = ChunkLayout.get(a.data, lx, y, lz)
									if buffer.readu8(cull, id) == 1 then
										roof = true
									elseif
										id == AIR and buffer.readu8(cull, ChunkLayout.get(b.data, lx, y, lz)) == 1
									then
										carved += 1
										if roof then
											roofed += 1
										end
									end
								end
							end
						end
					end
				end
			end
			print(
				`    level {level}: {carved} carved cells ({roofed} under a roof), {boxesOn} boxes against {boxesOff} without surface caves`
			)
			t.ok(carved > 20, `level {level}: openings show`)
			t.ok(roofed <= carved * 0.01, `level {level}: carved cells under a roof`)
			t.ok(boxesOn <= boxesOff * 1.12, `level {level}: parts surface caves add`)
		end
	end)

	t.test("surface caves: a coarser node draws the rock facing a finer node's ravine", function()
		-- For level pairs 1/2 and 2/3, each far node a ravine runs through and each of its sides on
		-- the coarser level's grid: at every block of the shared face, open air on the finer side
		-- must face a drawn cell (or open air) on the coarser side, never undrawn rock.
		local nodes: { [string]: any } = {}
		local function node(level: number, nx: number, nz: number): any
			local k = `{level},{nx},{nz}`
			local m = nodes[k]
			if m == nil then
				local r, covered = meshFar(gen, level, nx, nz)
				m = { r = r, covered = covered }
				nodes[k] = m
			end
			return m
		end
		local cull = Blocks.cullLutHiddenCaves
		local SIDES = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }
		local ravines = {}
		for _, worm in sc.worms(-1600, -1600, 1600, 1600) do
			if worm.kind == "ravine" then
				table.insert(ravines, worm)
			end
		end
		for a = 1, 2 do
			local step, stepY = ChunkLayout.steps(a)
			local cs, csY = ChunkLayout.steps(a + 1)
			local span, cspan = SIZE * step, SIZE * cs
			local facing, holes = 0, 0
			for _, worm in ravines do
				if facing > 200 then
					break
				end
				local seen = {}
				for s = 1, worm.count, 4 do
					local nx, nz = math.floor(worm.x[s]) // span, math.floor(worm.z[s]) // span
					if seen[nx * 100000 + nz] then
						continue
					end
					seen[nx * 100000 + nz] = true
					for side, d in SIDES do
						-- The block just across this side; skip sides inside the parent node.
						local ax = if d[1] < 0 then nx * span - 1 elseif d[1] > 0 then (nx + 1) * span else nil
						local az = if d[2] < 0 then nz * span - 1 elseif d[2] > 0 then (nz + 1) * span else nil
						if
							(ax and ax // cspan == (nx * span) // cspan) or (az and az // cspan == (nz * span) // cspan)
						then
							continue
						end
						local F = node(a, nx, nz)
						for i = 0, SIZE - 1 do
							local lx = if side == 1 then 0 elseif side == 2 then SIZE - 1 else i
							local lz = if side == 3 then 0 elseif side == 4 then SIZE - 1 else i
							for sub = 0, step - 1 do
								local bx = ax or nx * span + lx * step + sub
								local bz = az or nz * span + lz * step + sub
								local cnx, cnz = bx // cspan, bz // cspan
								local C = node(a + 1, cnx, cnz)
								local clx, clz = (bx - cnx * cspan) // cs, (bz - cnz * cspan) // cs
								for y = 1, math.min(F.r.height * stepY, C.r.height * csY) - 1 do
									local fy, cy = y // stepY, y // csY
									if buffer.readu8(cull, ChunkLayout.get(F.r.data, lx, fy, lz)) == 0 then
										local id = ChunkLayout.get(C.r.data, clx, cy, clz)
										if buffer.readu8(cull, id) == 1 then
											facing += 1
											if not C.covered[ChunkLayout.localIndex(clx, cy, clz)] then
												holes += 1
											end
										end
									end
								end
							end
						end
					end
				end
			end
			print(`    levels {a} / {a + 1}: {facing} faces of open air against coarser rock, {holes} not drawn`)
			t.ok(facing > 0, `levels {a} / {a + 1}: a ravine at a seam`)
			t.eq(holes, 0, `levels {a} / {a + 1}: see-through holes`)
		end
	end)

	t.test("surface caves: cost per chunk", function()
		local fresh = TerrainGenerator.new(SEED, { structures = false })
		local inside = 0
		local carve, carvesTop = fresh.surfaceCaves.carve, fresh.surfaceCaves.carvesTop
		fresh.surfaceCaves.carve = function(...)
			local t0 = os.clock()
			local lowest = carve(...)
			inside += os.clock() - t0
			return lowest
		end
		fresh.surfaceCaves.carvesTop = function(x: number, z: number): boolean
			local t0 = os.clock()
			local open = carvesTop(x, z)
			inside += os.clock() - t0
			return open
		end
		local start = os.clock()
		local n = 0
		local cx0, cz0 = math.floor(entrance.x[1]) // SIZE - 4, math.floor(entrance.z[1]) // SIZE - 4
		for cz = cz0, cz0 + 7 do
			for cx = cx0, cx0 + 7 do
				fresh.generate(0, cx, cz)
				n += 1
			end
		end
		local total = os.clock() - start
		print(
			string.format(
				"    %d chunks around an entrance: %.2f ms per chunk, surface caves %.3f ms (worms built: %d)",
				n,
				total / n * 1000,
				inside / n * 1000,
				fresh.surfaceCaves.built()
			)
		)
		t.ok(inside / n < 0.003, "surface caves cost a few percent of a chunk")
	end)
end
