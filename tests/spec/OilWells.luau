--[[
	Oil wells (Generation/OilWells, BuildCraft's OilPopulate): one candidate per Spacing cell,
	biome weights (deserts, savannas and plains first, small undersea pockets), sizes, never near
	the spawn or a library structure; deposits of CaveOil buried in rock, out of the caves and
	under the surface caves (nothing to draw while caves are hidden, marked in the cave lattice);
	geysers on every large and medium well on land: a spout from the deposit to 6 or 16 blocks
	over the ground and BuildCraft's lake around it, held in on uneven ground too, kept clear of
	surface caves and trees, shown at LOD and on the map; determinism and padding; the cost.
]]
return function(t, shared, require)
	local Config = require(shared.Config)
	local Blocks = require(shared.Blocks)
	local Biomes = require(shared.Biomes)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)
	local OilWells = require(shared.Generation.OilWells)
	local Caves = require(shared.Generation.Caves)
	local Ores = require(shared.Generation.Ores)
	local GreedyMesher = require(shared.Meshing.GreedyMesher)
	local SectionGraph = require(shared.World.SectionGraph)
	local MapPainter = require(shared.Map.MapPainter)

	local SIZE = ChunkLayout.SIZE
	local LAYER = ChunkLayout.LAYER
	local SEED = 12345
	local SECTION = Config.SectionHeight
	local SEA = Config.SeaLevel
	local cfg = Config.Caves.OilWells
	local B = Blocks.id
	local AIR, CAVE_AIR, STONE = Blocks.AIR, Blocks.CAVE_AIR, B.Stone
	local OIL, CAVE_OIL = B.Oil, B.CaveOil
	local gen = TerrainGenerator.new(SEED)

	local isFluid: { [number]: boolean } = {}
	local isOpaque: { [number]: boolean } = {}
	local isLog: { [number]: boolean } = {}
	for id = 0, Blocks.count - 1 do
		local def = Blocks.get(id)
		isFluid[id] = def.fluid ~= nil
		isOpaque[id] = Blocks.isOpaque(id)
		isLog[id] = string.find(def.name, "Log") ~= nil
	end
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

	local function sizeOf(name: string)
		for _, s in cfg.Sizes do
			if s.Name == name then
				return s
			end
		end
		error(`{name}: not a configured size`)
	end

	local R = 8192
	local wells = gen.oilWells(-R, -R, R - 1, R - 1)
	local geysers, undersea = {}, {}
	for _, w in wells do
		if w.geyser then
			table.insert(geysers, w)
		elseif w.undersea then
			table.insert(undersea, w)
		end
	end
	-- The wells nearest the origin first (fixtures).
	local function byDistance(list: { OilWells.Well })
		table.sort(list, function(a, b)
			return a.x * a.x + a.z * a.z < b.x * b.x + b.z * b.z
		end)
	end
	byDistance(geysers)
	byDistance(undersea)

	t.test("wells: one candidate per cell, inside it; sizes, radii and depths as configured", function()
		t.ok(#wells > 50, `wells: {#wells}`)
		local sizes: { [string]: number } = {}
		for _, w in wells do
			local inX, inZ = w.x - w.cellX * cfg.Spacing, w.z - w.cellZ * cfg.Spacing
			t.ok(inX >= OilWells.INSET and inX < cfg.Spacing - OilWells.INSET, "inside its cell")
			t.ok(inZ >= OilWells.INSET and inZ < cfg.Spacing - OilWells.INSET, "inside its cell")
			sizes[w.size] = (sizes[w.size] or 0) + 1
			local spec = sizeOf(w.size)
			t.ok(w.radius >= 2 and w.radius <= spec.Radius[2], `radius {w.radius} of a {w.size} well`)
			if not w.undersea and w.surface > SEA + 20 then
				t.ok(w.radius >= spec.Radius[1], "land deposits keep their size")
			end
			-- Buried: COVER under its column, off the bedrock.
			t.ok(w.y + w.radius <= w.surface - OilWells.COVER, "buried")
			t.ok(w.y - w.radius > Config.Caves.MinY, "off the bedrock")
			t.ok(
				w.surface - w.y <= cfg.Depth[2] or w.y == w.surface - OilWells.COVER - w.radius,
				"no deeper than Depth"
			)
			t.eq(w.undersea, w.surface < SEA, "undersea under the sea")
			if w.geyser then
				t.ok(not w.undersea and spec.Spout > 0, "geysers on land, large and medium wells")
				-- (Smaller by the shore.)
				t.ok(w.lakeRadius >= 1 and w.lakeRadius <= spec.Lake[2], "lake radius")
				t.ok(w.lakeDepth >= cfg.LakeDepth[1] and w.lakeDepth <= cfg.LakeDepth[2], "lake depth")
				t.eq(w.lakeLevel, w.surface - 2, "the lake's top one below the ground")
				t.eq(w.spoutTop, w.surface - 1 + spec.Spout, "the spout's height")
			end
		end
		print(
			`    {#wells} wells in {math.floor((2 * R) ^ 2 / 1e6)} km2: {sizes.Large or 0} large, {sizes.Medium or 0} medium, {sizes.Small or 0} small; {#geysers} geysers, {#undersea} undersea`
		)
		t.ok(
			(sizes.Medium or 0) > (sizes.Large or 0) and (sizes.Medium or 0) > (sizes.Small or 0),
			"half of them medium"
		)
		t.ok(#geysers > 10 and #undersea > 5, "geysers and undersea pockets")
	end)

	t.test("wells: deserts, savannas and plains far more likely than other land; undersea pockets", function()
		local area: { [string]: number } = {}
		local GRID = 128
		for z = -R, R - 1, GRID do
			for x = -R, R - 1, GRID do
				local h, biome = gen.column(x + GRID // 2, z + GRID // 2)
				local name = if h < SEA then "(sea)" else Biomes.list[biome].name
				area[name] = (area[name] or 0) + GRID * GRID / 1e6
			end
		end
		local count: { [string]: number } = {}
		for _, w in wells do
			local name = if w.undersea then "(sea)" else Biomes.list[w.biome].name
			count[name] = (count[name] or 0) + 1
		end
		local oilBiomes, oilArea, other, otherArea = 0, 0, 0, 0
		local lines = {}
		for name, km2 in area do
			local n = count[name] or 0
			if cfg.Biomes[name] then
				oilBiomes += n
				oilArea += km2
			elseif name ~= "(sea)" then
				other += n
				otherArea += km2
			end
			if km2 >= 5 then
				table.insert(lines, string.format("%s %.2f", name, n / km2))
			end
		end
		table.sort(lines)
		print(`    wells per km2: {table.concat(lines, ", ")}`)
		local rich, poor = oilBiomes / oilArea, other / otherArea
		print(
			string.format(
				"    oil biomes %.2f per km2, other land %.2f, under the sea %.2f",
				rich,
				poor,
				(count["(sea)"] or 0) / area["(sea)"]
			)
		)
		t.ok(rich > 2.5 * poor, "oil biomes are much more likely")
		t.ok((count["(sea)"] or 0) > 0, "undersea pockets")
	end)

	t.test("wells: undersea pockets are small (SeaSize), a minor share of the oil", function()
		local sea = sizeOf(cfg.SeaSize)
		local seaOil, allOil, n = 0, 0, 0
		for _, w in wells do
			local volume = w.radius ^ 3
			allOil += volume
			if w.undersea then
				n += 1
				seaOil += volume
				t.eq(w.size, cfg.SeaSize, "an undersea pocket's size")
				t.ok(w.radius <= sea.Radius[2], `undersea radius {w.radius}`)
			end
		end
		print(string.format("    %d undersea pockets: %.1f%% of the oil", n, seaOil / allOil * 100))
		t.ok(n > 0, "undersea pockets")
		t.ok(seaOil < 0.1 * allOil, "undersea pockets hold a minor share of the oil")
	end)

	t.test("wells: never near the spawn or a library structure", function()
		local sx, _, sz = gen.findSpawn()
		local near = 0
		for _, w in wells do
			t.ok((w.x - sx) ^ 2 + (w.z - sz) ^ 2 >= cfg.SpawnClearance ^ 2, "away from the spawn")
			local r = math.max(w.radius, w.lakeRadius) + OilWells.MARGIN
			for _, start in gen.structures(w.x - r, w.z - r, w.x + r, w.z + r) do
				for _, piece in start.pieces do
					local b = piece.box
					if b[1] <= w.x + r and b[4] >= w.x - r and b[3] <= w.z + r and b[6] >= w.z - r then
						near += 1
					end
				end
			end
		end
		t.eq(near, 0, "structure pieces at a well")
		-- Wells checked against structures: some candidate cells lost one (outposts are ~3 per
		-- 1000 x 1000 blocks), so the check runs.
		t.ok(#gen.structures(-R, -R, R - 1, R - 1) > 0, "structures exist")
	end)

	-- Counts a well's oil: deposit twins in its sphere, twins outside it (the spout), hollow cells
	-- (cave air or air) in the sphere, deposit twins within COVER of the ground.
	local function deposit(w: OilWells.Well): (number, number, number, number, number)
		local inside, outside, hollow, shallow, sphere = 0, 0, 0, 0, 0
		local r = math.max(w.radius, w.lakeRadius) + 1
		for x = w.x - r, w.x + r do
			for z = w.z - r, w.z + r do
				local h = gen.column(x, z)
				for y = math.max(w.y - w.radius - 1, 1), math.max(w.spoutTop, w.y + w.radius) + 2 do
					local id = blockAt(x, y, z)
					local dx, dy, dz = x - w.x, y - w.y, z - w.z
					local inSphere = dx * dx + dy * dy + dz * dz <= w.radius * w.radius
					if inSphere then
						sphere += 1
					end
					if id == CAVE_OIL then
						if inSphere then
							inside += 1
							if y > h - OilWells.COVER then
								shallow += 1
							end
						elseif x == w.x and z == w.z and w.geyser then
							-- (The spout below the lake.)
						else
							outside += 1
						end
					elseif inSphere and (id == AIR or id == CAVE_AIR) then
						hollow += 1
					end
				end
			end
		end
		return inside, outside, hollow, shallow, sphere
	end

	t.test("wells: deposits are CaveOil spheres in rock, buried and out of the caves", function()
		local list: { OilWells.Well } = {}
		for k = 1, 4 do
			table.insert(list, geysers[k])
			table.insert(list, undersea[k])
		end
		local total, holes = 0, 0
		for _, w in list do
			local inside, outside, hollow, shallow, sphere = deposit(w)
			t.eq(outside, 0, "CaveOil only in the sphere and the spout")
			t.eq(shallow, 0, "buried COVER deep")
			t.ok(inside >= 0.97 * sphere, `the sphere is oil: {inside} of {sphere}`)
			total += inside
			holes += hollow
		end
		print(`    {#list} deposits: {total} cells of CaveOil, {holes} cells of air in them`)
		t.eq(holes, 0, "no cave runs through a deposit")
	end)

	-- Deposits cut back under a surface cave (for the padding test).
	local cutDeposits: { OilWells.Well } = {}
	t.test("wells: deposits keep under cave entrances and ravines (no CaveOil faces their air)", function()
		-- Every deposit a surface cave may cut: a worm carves a column of it or one next to it,
		-- outside a geyser's lake square (which surface caves leave alone).
		local checked, cut, faces, kept = 0, 0, 0, 0
		for _, w in wells do
			local r = w.radius
			local lake = if w.geyser then w.lakeRadius + OilWells.MARGIN else -1
			local near = false
			for dz = -r - 1, r + 1 do
				for dx = -r - 1, r + 1 do
					if
						not near
						and (math.abs(dx) > lake or math.abs(dz) > lake)
						and gen.surfaceCaves.mayCarve(w.x + dx, w.z + dz)
					then
						near = true
					end
				end
			end
			if not near then
				continue
			end
			checked += 1
			local rock = 0
			for y = w.y - r, w.y + r do
				for z = w.z - r, w.z + r do
					for x = w.x - r, w.x + r do
						if (x - w.x) ^ 2 + (y - w.y) ^ 2 + (z - w.z) ^ 2 <= r * r then
							local id = blockAt(x, y, z)
							if id == CAVE_OIL then
								for _, d in
									{ { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }
								do
									if blockAt(x + d[1], y + d[2], z + d[3]) == AIR then
										faces += 1
									end
								end
							elseif isOpaque[id] then
								-- (Rock left between the deposit and a surface cave.)
								rock += 1
							end
						end
					end
				end
			end
			if rock > 0 then
				cut += 1
				kept += rock
				table.insert(cutDeposits, w)
			end
		end
		print(
			`    {checked} deposits under surface caves, {cut} cut back under one ({kept} cells of rock kept), {faces} CaveOil faces on their air`
		)
		t.eq(faces, 0, "CaveOil faces on a surface cave's air")
		t.ok(checked >= 3, "deposits under surface caves")
		t.ok(cut >= 1, "a deposit cut back under a surface cave")
	end)

	t.test("wells: hidden caves draw nothing of a buried deposit; the lattice marks it", function()
		local sections, boxes = 0, 0
		for k = 1, 3 do
			local w = undersea[k]
			local r = chunk(w.x // SIZE, w.z // SIZE)
			local rock = buffer.create(buffer.len(r.data))
			buffer.copy(rock, 0, r.data)
			for i = 0, buffer.len(rock) // 2 - 1 do
				if buffer.readu16(rock, i * 2) == CAVE_OIL then
					buffer.writeu16(rock, i * 2, STONE)
				end
			end
			local section = Config.SectionHeight
			for y0 = ((w.y - w.radius) // section) * section, w.y + w.radius, section do
				local m1, n1 = GreedyMesher.mesh(r.data, r.height, y0, y0 + section, true)
				local m2, n2 = GreedyMesher.mesh(rock, r.height, y0, y0 + section, true)
				t.eq(n1, n2, "boxes")
				t.eq(buffer.tostring(m1), buffer.tostring(m2), "the same boxes as rock")
				sections += 1
				boxes += n1
			end
			-- Every twin in the core lies in a lattice cell marked carved (World/SectionGraph reads it).
			local carved = r.carved
			t.ok(carved ~= nil, "a lattice")
			if carved then
				for y = 1, r.height - 1 do
					for lz = 0, SIZE - 1 do
						for lx = 0, SIZE - 1 do
							if ChunkLayout.get(r.data, lx, y, lz) == CAVE_OIL then
								local gx = ((w.x // SIZE) * SIZE + lx - carved.x) // Caves.CELL_XZ
								local gz = ((w.z // SIZE) * SIZE + lz - carved.z) // Caves.CELL_XZ
								local gy = (y - carved.y) // Caves.CELL_Y
								local ok = gy < carved.ny
									and buffer.readu8(carved.flags, (gy * carved.nz + gz) * carved.nx + gx) ~= 0
								t.ok(ok, "a deposit cell in an unmarked lattice cell")
							end
						end
					end
				end
			end
		end
		print(`    {sections} sections through undersea deposits: {boxes} boxes hidden, as plain rock`)
	end)

	t.test("wells: the cave lattice and the sky line describe them (cave visibility graphs)", function()
		local sections = 0
		for k = 1, 3 do
			for _, w in { geysers[k], undersea[k] } do
				sections += graphsAgree(w.x // SIZE, w.z // SIZE)
				sections += graphsAgree(w.x // SIZE + 1, w.z // SIZE)
			end
		end
		t.ok(sections > 10, `sections compared: {sections}`)
	end)

	t.test("geysers: a spout from the deposit to Spout blocks over the ground", function()
		for k = 1, 4 do
			local w = geysers[k]
			local bottom = w.lakeLevel - w.lakeDepth + 1
			for y = w.y + w.radius + 1, bottom - 1 do
				t.eq(blockAt(w.x, y, w.z), CAVE_OIL, `the spout below the lake at y {y}`)
			end
			for y = bottom, w.spoutTop do
				t.eq(blockAt(w.x, y, w.z), OIL, `oil at y {y}`)
			end
			t.eq(blockAt(w.x, w.spoutTop + 1, w.z), AIR, "air over the spout")
			t.ok(w.spoutTop - (w.surface - 1) == 6 or w.spoutTop - (w.surface - 1) == 16, "6 or 16 into the air")
		end
	end)

	t.test("geysers: every large and medium well on land has one, but on the shore", function()
		local land, rough = 0, 0
		for _, w in wells do
			if w.undersea or w.surface <= SEA + 2 or sizeOf(w.size).Spout == 0 then
				t.ok(not w.geyser, "no geyser under the sea, on a beach or on a small well")
				continue
			end
			-- (OilWells drops the geyser only where its smallest lake's rings, 1 and 2 blocks out,
			-- reach the shore.)
			local shore = false
			for dz = -2, 2 do
				for dx = -2, 2 do
					shore = shore or gen.column(w.x + dx, w.z + dz) <= SEA + 1
				end
			end
			if shore then
				continue
			end
			land += 1
			t.ok(w.geyser, `a {w.size} well on land at {w.x},{w.z} without a geyser`)
			-- Uneven ground (more than 2 blocks off the centre on the ring around the lake) only
			-- shapes the lake.
			for i = 0, 15 do
				local a = 2 * math.pi * i / 16
				local r = w.lakeRadius + 1
				if
					math.abs(
						gen.column(w.x + math.round(r * math.cos(a)), w.z + math.round(r * math.sin(a))) - w.surface
					) > 2
				then
					rough += 1
					break
				end
			end
		end
		print(`    {land} large and medium wells on land, {rough} of them on uneven ground`)
		t.ok(land > 50 and rough > 10, "wells on land, some on uneven ground")
	end)

	t.test("geysers on uneven ground: the spout's column runs unbroken, the lake is held in", function()
		-- Geysers whose spout column has a neighbour below the oil's top (an open side the lake's
		-- rules would drop for any other column), and the first few ragged lakes (less than 30%
		-- of their square).
		local list, open, ragged = {}, 0, 0
		for _, w in geysers do
			local low = false
			for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
				low = low or gen.column(w.x + d[1], w.z + d[2]) <= w.lakeLevel
			end
			local mask = gen.oilLake(w)
			local cells = 0
			for i = 0, buffer.len(mask) - 1 do
				cells += buffer.readu8(mask, i)
			end
			if low then
				open += 1
				table.insert(list, w)
			elseif ragged < 6 and cells < 0.3 * buffer.len(mask) then
				ragged += 1
				table.insert(list, w)
			end
		end
		t.ok(open >= 1 and ragged >= 1, "geysers with a low neighbour by the spout, ragged lakes")
		local sides = 0
		for _, w in list do
			local mask = gen.oilLake(w)
			local r = w.lakeRadius
			local width = 2 * r + 1
			t.eq(buffer.readu8(mask, r * width + r), 1, "the spout's column is in the lake")
			local bottom = w.lakeLevel - w.lakeDepth + 1
			for y = w.y + w.radius + 1, w.spoutTop do
				t.eq(blockAt(w.x, y, w.z), if y < bottom then CAVE_OIL else OIL, `the spout at y {y}`)
			end
			for dz = -r, r do
				for dx = -r, r do
					if (dx ~= 0 or dz ~= 0) and buffer.readu8(mask, (dz + r) * width + dx + r) == 1 then
						for y = bottom, w.lakeLevel do
							for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
								local n = blockAt(w.x + dx + d[1], y, w.z + dz + d[2])
								if not isOpaque[n] and not isFluid[n] then
									sides += 1
								end
							end
						end
					end
				end
			end
		end
		print(`    {open} geysers with a low neighbour by the spout, {ragged} ragged lakes`)
		t.eq(sides, 0, "lake cells with an open side")
	end)

	t.test("geysers: BuildCraft's lake: grown from the centre, the same depth, held in", function()
		local columns, open = 0, 0
		for k = 1, 6 do
			local w = geysers[k]
			local mask = gen.oilLake(w)
			local r = w.lakeRadius
			local width = 2 * r + 1
			t.eq(buffer.len(mask), width * width, "the lake's square")
			t.eq(buffer.readu8(mask, r * width + r), 1, "the centre is oil")
			-- Connected to the centre (tendrils grow next to oil; a few are dropped at open sides).
			local seen, stack, reached, cells = {}, { { 0, 0 } }, 0, 0
			for i = 0, width * width - 1 do
				cells += buffer.readu8(mask, i)
			end
			while #stack > 0 do
				local p = table.remove(stack) :: { number }
				local key = (p[2] + r) * width + p[1] + r
				if p[1] < -r or p[1] > r or p[2] < -r or p[2] > r or seen[key] or buffer.readu8(mask, key) == 0 then
					continue
				end
				seen[key] = true
				reached += 1
				for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
					table.insert(stack, { p[1] + d[1], p[2] + d[2] })
				end
			end
			t.ok(reached >= 0.8 * cells, `connected: {reached} of {cells}`)
			for dz = -r, r do
				for dx = -r, r do
					local x, z = w.x + dx, w.z + dz
					local lake = buffer.readu8(mask, (dz + r) * width + dx + r) == 1
					local top = blockAt(x, w.lakeLevel, z)
					if lake then
						columns += 1
						for y = w.lakeLevel - w.lakeDepth + 1, w.lakeLevel do
							t.eq(blockAt(x, y, z), OIL, "the lake's depth")
							for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
								local n = blockAt(x + d[1], y, z + d[2])
								if not isOpaque[n] and not isFluid[n] then
									open += 1
								end
							end
						end
						local under = blockAt(x, w.lakeLevel - w.lakeDepth, z)
						if dx == 0 and dz == 0 then
							t.eq(under, CAVE_OIL, "the spout under the lake")
						else
							t.ok(isOpaque[under], "rock under the lake")
						end
						if dx ~= 0 or dz ~= 0 then
							t.eq(blockAt(x, w.lakeLevel + 1, z), AIR, "the top block over the lake dug away")
						end
					else
						t.ok(top ~= OIL, "oil outside the lake")
					end
				end
			end
		end
		print(`    {columns} lake columns of 6 geysers`)
		t.eq(open, 0, "lake cells with an open side")
	end)

	t.test("geysers: no surface cave or tree in the lake's square; solidBelow, emptyAbove", function()
		for k = 1, 4 do
			local w = geysers[k]
			local r = w.lakeRadius + OilWells.MARGIN
			local x0, z0, x1, z1 = w.x - r, w.z - r, w.x + r, w.z + r
			local mask = gen.oilLake(w)
			local width = 2 * w.lakeRadius + 1
			for x = x0, x1 do
				for z = z0, z1 do
					local h = gen.column(x, z)
					local dx, dz = x - w.x, z - w.z
					local lake = math.abs(dx) <= w.lakeRadius
						and math.abs(dz) <= w.lakeRadius
						and buffer.readu8(mask, (dz + w.lakeRadius) * width + dx + w.lakeRadius) == 1
					for y = w.lakeLevel - 4, h + 12 do
						local id = blockAt(x, y, z)
						t.ok(not isLog[id], "a tree at a geyser")
						if id == AIR and y < h then
							t.ok(lake and y == w.lakeLevel + 1, `air dug at {x},{y},{z} under the ground ({h})`)
						end
					end
				end
			end
			local cull = Blocks.cullLutHiddenCaves
			for level = 0, Config.StructureMaxLevel do
				local span = SIZE * 2 ^ level
				local c = if level == 0
					then chunk(w.x // span, w.z // span)
					else gen.generate(level, w.x // span, w.z // span)
				t.ok(c.emptyAbove < c.height, "the crop leaves air on top")
				for y = 0, c.height - 1 do
					for i = 0, LAYER - 1 do
						local id = buffer.readu16(c.data, (y * LAYER + i) * 2)
						if y < c.solidBelow then
							t.ok(buffer.readu8(cull, id) == 1, `level {level}: {Blocks.get(id).name} below solidBelow`)
						end
						if y >= c.emptyAbove then
							t.eq(id, AIR, `level {level}: above emptyAbove`)
						end
					end
				end
			end
		end
	end)

	t.test("geysers: far nodes (levels 1-2) show the lake and the spout", function()
		for k = 1, 4 do
			local w = geysers[k]
			for level = 1, Config.StructureMaxLevel do
				local step, stepY = ChunkLayout.steps(level)
				local span = SIZE * step
				local nx, nz = w.x // span, w.z // span
				local r = gen.generate(level, nx, nz)
				local lx, lz = (w.x - nx * span) // step, (w.z - nz * span) // step
				local spout = 0
				for cy = 0, r.height - 1 do
					if ChunkLayout.get(r.data, lx, cy, lz) == OIL then
						spout += 1
					end
				end
				t.ok(spout * stepY >= 6, `level {level}: the spout's cell holds {spout} cells of oil`)
				local top = 0
				for cy = 0, r.height - 1 do
					if ChunkLayout.get(r.data, lx, cy, lz) == OIL then
						top = cy
					end
				end
				t.eq(top, w.spoutTop // stepY, `level {level}: the spout's top`)
			end
		end
	end)

	t.test("wells: decided from the terrain alone; padding equals the neighbouring cores", function()
		local fresh = TerrainGenerator.new(SEED)
		for k = #wells, 1, -7 do
			local w = wells[k]
			local again = fresh.oilWells(w.x, w.z, w.x, w.z)
			t.eq(#again, 1, "found again")
			if again[1] then
				t.eq(again[1].y, w.y)
				t.eq(again[1].radius, w.radius)
				t.eq(again[1].geyser, w.geyser)
				t.eq(buffer.tostring(fresh.oilLake(again[1])), buffer.tostring(gen.oilLake(w)), "the same lake")
			end
		end
		local bad, compared = 0, 0
		local list = { geysers[1], geysers[2], undersea[1] }
		for k = 1, math.min(#cutDeposits, 2) do
			table.insert(list, cutDeposits[k])
		end
		for _, w in list do
			local r = math.max(w.radius, w.lakeRadius)
			for cz = (w.z - r) // SIZE - 1, (w.z + r) // SIZE do
				for cx = (w.x - r) // SIZE - 1, (w.x + r) // SIZE do
					local a, east, south = chunk(cx, cz), chunk(cx + 1, cz), chunk(cx, cz + 1)
					local function get(c: any, px: number, y: number, pz: number): number
						if y >= c.height then
							return AIR
						end
						return norm(ChunkLayout.getPadded(c.data, px, y, pz))
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
				end
			end
		end
		t.ok(compared > 100000, `cells compared: {compared}`)
		t.eq(bad, 0, "border cells that disagree")
	end)

	t.test("map: geysers are black dots", function()
		local paint = MapPainter.new(gen)
		local oil = Blocks.get(OIL).color
		local function oilPixels(tile: buffer): number
			local n = 0
			for i = 0, buffer.len(tile) // 4 - 1 do
				local o = i * 4
				if
					buffer.readu8(tile, o) == oil[1]
					and buffer.readu8(tile, o + 1) == oil[2]
					and buffer.readu8(tile, o + 2) == oil[3]
				then
					n += 1
				end
			end
			return n
		end
		for _, scale in { 1, 4, 64 } do
			local w = geysers[1]
			local size = 32
			local ox, oz = w.x - (size // 2) * scale, w.z - (size // 2) * scale
			local tile = paint(ox, oz, scale, size)
			local px, pz = (w.x - ox) // scale, (w.z - oz) // scale
			local o = (pz * size + px) * 4
			t.eq(buffer.readu8(tile, o), oil[1], `scale {scale}: the spout's pixel is oil`)
			local n = oilPixels(tile)
			if scale == 1 then
				local mask = gen.oilLake(w)
				local cells = 0
				for i = 0, buffer.len(mask) - 1 do
					cells += buffer.readu8(mask, i)
				end
				t.ok(n >= cells * 0.6, `scale 1: {n} oil pixels for a lake of {cells} columns`)
			end
		end
		-- Far from every geyser: no oil.
		local w = geysers[1]
		local tile = paint(w.x + 1000, w.z + 1000, 1, 32)
		local near = gen.oilWells(w.x + 1000, w.z + 1000, w.x + 1031, w.z + 1031)
		local any = false
		for _, other in near do
			any = any or other.geyser
		end
		if not any then
			t.eq(oilPixels(tile), 0, "no dots without a geyser")
		end
	end)

	t.test("wells: cost", function()
		-- Deciding the cells of a 16 x 16 km area with a fresh generator, and writing wells into
		-- the chunks around geysers.
		local fresh = TerrainGenerator.new(SEED)
		fresh.findSpawn()
		local t0 = os.clock()
		local list = fresh.oilWells(-R, -R, R - 1, R - 1)
		local decide = os.clock() - t0
		local cells = (2 * R / cfg.Spacing) ^ 2
		local was = cfg.Enabled
		local chunks: { { number } } = {}
		for k = 1, 3 do
			local w = geysers[k]
			for dz = -1, 1 do
				for dx = -1, 1 do
					table.insert(chunks, { w.x // SIZE + dx, w.z // SIZE + dz })
				end
			end
		end
		local times = {}
		for _, on in { false, true } do
			cfg.Enabled = on
			local g = TerrainGenerator.new(SEED)
			g.findSpawn()
			local best = math.huge
			for _ = 1, 2 do
				local t1 = os.clock()
				for _, c in chunks do
					g.generate(0, c[1], c[2])
				end
				best = math.min(best, os.clock() - t1)
			end
			table.insert(times, best / #chunks * 1000)
		end
		cfg.Enabled = was
		print(
			string.format(
				"    %d cells decided in %.1f ms (%.3f ms each, %d wells); chunks around geysers %.2f ms with, %.2f ms without",
				cells,
				decide * 1000,
				decide / cells * 1000,
				#list,
				times[2],
				times[1]
			)
		)
		t.ok(decide / cells < 0.01, "deciding a cell costs little")
	end)
end
