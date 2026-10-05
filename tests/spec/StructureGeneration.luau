--[[
	Library structures in generated terrain (Generation/StructureGen through TerrainGenerator):
	random_spread placement, biomes and dry land, every piece written whole across chunk seams
	(rotations, final states, keep cells, terrain matching paths, foundations), padding equal to the
	neighbouring cores, LOD point sampling, emptyAbove / solidBelow, trees keeping clear, generated
	chest contents, determinism (cold and warm caches, any chunk order) and the cost. The repo's
	example outpost (StructureLibrary, tests/build_structures.luau) is what generates.
]]
return function(t, shared, require)
	local Config = require(shared.Config)
	local Blocks = require(shared.Blocks)
	local Biomes = require(shared.Biomes)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)
	local StructureGen = require(shared.Generation.StructureGen)
	local Jigsaw = require(shared.Structures.Jigsaw)
	local Library = require(shared.Structures.Library)
	local Template = require(shared.Structures.Template)
	local Transform = require(shared.Structures.Transform)

	local SIZE = ChunkLayout.SIZE
	local P = ChunkLayout.PADDED
	local SEA = Config.SeaLevel
	local AIR = Blocks.AIR
	local SEED = 12345
	local gen = TerrainGenerator.new(SEED)
	local plain = TerrainGenerator.new(SEED, { structures = false })
	local library = Library.load()
	local outpost = library.structure("outpost")

	local isPlant: { [number]: boolean } = {}
	local isLeaves: { [number]: boolean } = {}
	local isOre: { [number]: boolean } = {}
	for id = 0, Blocks.count - 1 do
		isPlant[id] = Blocks.isPlant(id)
		isLeaves[id] = string.find(Blocks.get(id).name, "Leaves") ~= nil
	end
	for _, name in
		{ "CoalOre", "IronOre", "GoldOre", "DiamondOre", "EmeraldOre", "OsmiumOre", "Diorite", "Andesite", "Granite" }
	do
		isOre[Blocks.id[name]] = true
	end
	-- Ores only exist in each chunk's core and lichen at the padding's edge may differ (see
	-- tests/spec/Generation and CaveLichen).
	local function norm(id: number): number
		if Blocks.isCaveTwin(id) then
			return Blocks.CAVE_AIR
		end
		return if isOre[id] then Blocks.id.Stone else id
	end

	-- Generated chunks by generator and level, kept for the whole spec.
	local caches: { [any]: { [string]: any } } = {}
	local function chunk(g: any, level: number, cx: number, cz: number): any
		local cache = caches[g]
		if cache == nil then
			cache = {}
			caches[g] = cache
		end
		local key = `{level}:{cx}:{cz}`
		local r = cache[key]
		if r == nil then
			r = g.generate(level, cx, cz)
			cache[key] = r
		end
		return r
	end
	-- Block at world (x, y, z) of a level's chunks (the cell containing it).
	local function blockAt(g: any, level: number, x: number, y: number, z: number): number
		local step, stepY = ChunkLayout.steps(level)
		local span = SIZE * step
		local cx, cz = x // span, z // span
		local r = chunk(g, level, cx, cz)
		local cy = y // stepY
		if cy < 0 or cy >= r.height then
			return AIR
		end
		return ChunkLayout.get(r.data, (x - cx * span) // step, cy, (z - cz * span) // step)
	end

	local function firstFree(x: number, z: number): number
		return math.max((gen.column(x, z)), SEA)
	end
	local function key(x: number, y: number, z: number): string
		return `{x},{y},{z}`
	end

	--[[
		What a start writes at level 0, cell by cell: every piece in order (later ones over earlier
		ones), each rigid piece's foundation after it (air and water down to the ground become the
		biome's filler). `kind` says what wrote each cell last: 1 a rigid piece, 2 a foundation, 0 a
		terrain matching piece.
	]]
	type Expected = { blocks: { [string]: number }, kind: { [string]: number }, list: { { number } } }
	local expectedCache: { [any]: Expected } = {}
	local function expected(start: any): Expected
		local cachedExpected = expectedCache[start]
		if cachedExpected then
			return cachedExpected
		end
		local blocks: { [string]: number } = {}
		local kind: { [string]: number } = {}
		local list: { { number } } = {}
		local function put(x: number, y: number, z: number, block: number, writer: number)
			local k = key(x, y, z)
			if blocks[k] == nil then
				table.insert(list, { x, y, z })
			end
			blocks[k] = block
			kind[k] = writer
		end
		for i, piece in start.pieces do
			local template = start.templates[i]
			local isRigid = piece.projection ~= Jigsaw.TERRAIN_MATCHING
			Jigsaw.eachBlock(piece, template, firstFree, function(x, y, z, block)
				put(x, y, z, block, if isRigid then 1 else 0)
			end)
			if isRigid and start.foundation then
				local box = piece.box
				for x = box[1], box[4] do
					for z = box[3], box[6] do
						local bottom = Jigsaw.blockAt(piece, template, x, piece.y, z, firstFree)
						if bottom and Blocks.isSolid(bottom) then
							local h, biome = gen.column(x, z)
							local filler = Biomes.list[biome].filler
							for y = piece.y - 1, piece.y - StructureGen.FOUNDATION_DEPTH, -1 do
								local was = blocks[key(x, y, z)]
								local fillable = if was ~= nil
									then was == AIR or Blocks.get(was).fluid ~= nil
									else y >= h
								if not fillable then
									break
								end
								put(x, y, z, filler, 2)
							end
						end
					end
				end
			end
		end
		local result = { blocks = blocks, kind = kind, list = list }
		expectedCache[start] = result
		return result
	end

	-- The outposts near the origin (assembled once; every test below looks at them).
	local found = gen.structures(-2500, -2500, 2500, 2500)
	local sample: { any } = {}
	for i = 1, math.min(3, #found) do
		table.insert(sample, found[i])
	end

	-- Chunk range covering a start's pieces at a level, plus a chunk around.
	local function chunkRange(start: any, level: number): (number, number, number, number)
		local span = SIZE * 2 ^ level
		local b = start.bounds
		return b[1] // span - 1, b[3] // span - 1, b[4] // span + 1, b[6] // span + 1
	end

	t.test("structures: the example outpost is in the library and generates", function()
		t.ok(outpost ~= nil, "the outpost structure")
		if outpost == nil then
			return
		end
		t.eq(#library.warnings, 0, table.concat(library.warnings, "; "))
		t.eq(outpost.startPool, "outpost/centres")
		for _, name in { "Plains", "Savanna", "Meadow", "Forest" } do
			t.ok(outpost.biomeSet[(Biomes.byName(name) :: any).index], `outpost grows in {name}`)
		end
		local kinds: { [string]: boolean } = {}
		for _, name in library.names do
			local parts = string.split(name, "/")
			if parts[1] == "outpost" then
				kinds[parts[2]] = true
			end
		end
		for _, kind in { "centres", "paths", "path_ends", "houses" } do
			t.ok(kinds[kind], `outpost/{kind} templates`)
		end
		t.ok(library.pool("outpost/paths").fallback == "outpost/path_ends", "paths end in path ends")
		t.ok(#found >= 3, `outposts within 2500 blocks of the origin: {#found}`)
		print(`    {#found} outposts in 5000 x 5000 blocks`)
		local pieces, houses, chests = 0, 0, 0
		for _, start in found do
			pieces += #start.pieces
			for _, piece in start.pieces do
				if string.find(piece.template, "/houses/") then
					houses += 1
				end
				if piece.template == "outpost/houses/storehouse" or piece.template == "outpost/centres/ruin" then
					chests += 1
				end
			end
		end
		print(`    {pieces / #found} pieces, {houses / #found} houses and {chests / #found} chests per outpost`)
		t.ok(houses > #found, "houses along the paths")
		t.ok(chests > 0, "storehouses and ruins with their chest")
	end)

	t.test("structures: starts follow random_spread, in their biomes, on dry land", function()
		local regions: { [string]: boolean } = {}
		for _, start in found do
			t.eq(start.name, "outpost")
			local s = outpost :: Library.Structure
			-- One start per region, inside the region's spread.
			local rx, rz = start.chunkX // s.spacing, start.chunkZ // s.spacing
			local cx, cz = StructureGen.startChunk(SEED, s, rx, rz)
			t.eq(cx, start.chunkX, "start chunk x")
			t.eq(cz, start.chunkZ, "start chunk z")
			t.ok(cx - rx * s.spacing < s.spacing - s.separation, "spread x")
			t.ok(cz - rz * s.spacing < s.spacing - s.separation, "spread z")
			t.ok(not regions[`{rx},{rz}`], "one start per region")
			regions[`{rx},{rz}`] = true
			t.eq(start.x, cx * SIZE, "start position: the chunk's minimum corner")
			-- The start piece's centre column decides (Minecraft's biome check).
			local box = start.pieces[1].box
			local mx, mz = (box[1] + box[4]) // 2, (box[3] + box[6]) // 2
			local h, biome = gen.column(mx, mz)
			t.ok(s.biomeSet[biome], `start in {Biomes.list[biome].name}`)
			t.ok(h > SEA, `start on dry land ({h})`)
			-- Layer 0 of the start piece is the ground's top block there.
			t.eq(start.pieces[1].y, firstFree(mx, mz) - 1, "start piece on the ground")
			t.ok(string.find(start.pieces[1].template, "outpost/centres/", 1, true) == 1, "a centre piece first")
		end
		-- Deterministic and salted: a fresh placer finds the same starts.
		local again = TerrainGenerator.new(SEED).structures(-2500, -2500, 2500, 2500)
		t.eq(#again, #found, "the same starts")
		for i, start in again do
			t.eq(start.x, found[i].x)
			t.eq(start.z, found[i].z)
			t.eq(#start.pieces, #found[i].pieces)
		end
		t.ok(#TerrainGenerator.new(SEED + 1).structures(-2500, -2500, 2500, 2500) > 0, "other seeds have outposts too")
	end)

	t.test("structures: every piece is written whole across chunk seams (rotations, final states, paths)", function()
		local checked, wrong, plants, rotations = 0, 0, 0, {}
		local firstWrong = nil
		for _, start in sample do
			local e = expected(start)
			for _, piece in start.pieces do
				rotations[piece.rotation] = true
			end
			for _, p in e.list do
				local x, y, z = p[1], p[2], p[3]
				local want = e.blocks[key(x, y, z)]
				local got = blockAt(gen, 0, x, y, z)
				checked += 1
				if got ~= want then
					-- (Plants grow on the ground after structures, also in a piece's air.)
					if want == AIR and isPlant[got] then
						plants += 1
					else
						wrong += 1
						firstWrong = firstWrong
							or `{Blocks.get(got).name} instead of {Blocks.get(want).name} at {x} {y} {z}`
					end
				end
			end
		end
		t.ok(checked > 3000, `cells checked: {checked}`)
		t.eq(wrong, 0, `cells that differ from the pieces ({firstWrong})`)
		t.ok(rotations[0] and rotations[1] and rotations[2] and rotations[3], "pieces in all four rotations")
		print(`    {checked} cells of {#sample} outposts, {plants} with a plant in a piece's air`)
	end)

	t.test("structures: keep cells and the ground under pieces are left alone", function()
		local checked, wrong = 0, 0
		for _, start in sample do
			local e = expected(start)
			for _, piece in start.pieces do
				local box = piece.box
				for x = box[1], box[4] do
					for z = box[3], box[6] do
						local h = gen.column(x, z)
						-- The terrain below a piece's cells that nothing wrote (structure void,
						-- the ground under a rigid floor) is what the plain generator has.
						for y = math.max(box[2] - 3, h - 6), h - 1 do
							if e.blocks[key(x, y, z)] == nil then
								checked += 1
								if norm(blockAt(gen, 0, x, y, z)) ~= norm(blockAt(plain, 0, x, y, z)) then
									wrong += 1
								end
							end
						end
					end
				end
			end
		end
		t.ok(checked > 1000, `cells checked: {checked}`)
		t.eq(wrong, 0, "untouched cells that changed")
	end)

	t.test("structures: chunk padding equals the neighbouring cores around outposts", function()
		local mismatches, compared = 0, 0
		for _, start in sample do
			local x0, z0, x1, z1 = chunkRange(start, 0)
			for cx = x0, x1 - 1 do
				for cz = z0, z1 - 1 do
					local a = chunk(gen, 0, cx, cz)
					local east = chunk(gen, 0, cx + 1, cz)
					local south = chunk(gen, 0, cx, cz + 1)
					local height = math.max(a.height, east.height, south.height)
					local function at(r: any, x: number, y: number, z: number): number
						return if y < r.height then ChunkLayout.getPadded(r.data, x, y, z) else AIR
					end
					local b = start.bounds
					for y = math.max(0, b[2] - StructureGen.FOUNDATION_DEPTH - 2), math.min(height - 1, b[5] + 2) do
						for i = 0, SIZE - 1 do
							compared += 4
							if norm(at(a, SIZE, y, i)) ~= norm(at(east, 0, y, i)) then
								mismatches += 1
							end
							if norm(at(east, -1, y, i)) ~= norm(at(a, SIZE - 1, y, i)) then
								mismatches += 1
							end
							if norm(at(a, i, y, SIZE)) ~= norm(at(south, i, y, 0)) then
								mismatches += 1
							end
							if norm(at(south, i, y, -1)) ~= norm(at(a, i, y, SIZE - 1)) then
								mismatches += 1
							end
						end
					end
				end
			end
		end
		t.ok(compared > 20000, `cells compared: {compared}`)
		t.eq(mismatches, 0, "padding cells that differ from the neighbour's core")
	end)

	t.test("structures: LOD chunks point-sample the pieces (levels 1 and 2)", function()
		for level = 1, Config.StructureMaxLevel do
			local step, stepY = ChunkLayout.steps(level)
			local half, halfY = step // 2, stepY // 2
			local checked, wrong, built = 0, 0, 0
			for _, start in sample do
				local e = expected(start)
				-- Columns a terrain matching piece covers follow the coarse ground at LOD: skip them.
				local paths: { [string]: boolean } = {}
				for _, piece in start.pieces do
					if piece.projection == Jigsaw.TERRAIN_MATCHING then
						local box = piece.box
						for x = box[1], box[4] do
							for z = box[3], box[6] do
								paths[`{x},{z}`] = true
							end
						end
					end
				end
				for _, p in e.list do
					local x, y, z = p[1], p[2], p[3]
					-- Sample points of their cells only.
					if x % step == half and z % step == half and y % stepY == halfY and not paths[`{x},{z}`] then
						local k = key(x, y, z)
						-- (Rigid pieces' own cells: foundations reach the coarse ground at LOD.)
						if e.kind[k] == 1 then
							checked += 1
							local want = e.blocks[k]
							local got = blockAt(gen, level, x, y, z)
							if got ~= want then
								wrong += 1
							elseif want ~= AIR then
								built += 1
							end
						end
					end
				end
			end
			-- (A level L cell is one sample point of 2^L x 2^L x 2^L blocks.)
			local cells = step * step * stepY
			t.ok(checked > 4000 // cells, `level {level}: sample points checked: {checked}`)
			t.ok(built > 1000 // cells, `level {level}: built cells seen: {built}`)
			t.eq(wrong, 0, `level {level}: sample points that differ from full detail`)
		end
		-- Above StructureMaxLevel: no structures.
		local level = Config.StructureMaxLevel + 1
		local start = sample[1]
		local step = 2 ^ level
		local box = start.pieces[1].box
		local mx, mz = (box[1] + box[4]) // 2, (box[3] + box[6]) // 2
		local span = SIZE * step
		local r = chunk(gen, level, mx // span, mz // span)
		local p = chunk(plain, level, mx // span, mz // span)
		t.eq(buffer.tostring(r.data), buffer.tostring(p.data), `level {level}: like the plain terrain`)
	end)

	t.test("structures: emptyAbove / solidBelow cover the pieces, the crop leaves air on top", function()
		local cull = Blocks.cullLutHiddenCaves
		for _, start in { sample[1] } do
			for level = 0, Config.StructureMaxLevel do
				local x0, z0, x1, z1 = chunkRange(start, level)
				for cx = x0 + 1, x1 - 1 do
					for cz = z0 + 1, z1 - 1 do
						local r = chunk(gen, level, cx, cz)
						t.ok(r.emptyAbove < r.height, `L{level} crop leaves no air on top`)
						for y = 0, r.height - 1 do
							for i = 0, ChunkLayout.LAYER - 1 do
								local id = buffer.readu16(r.data, (y * ChunkLayout.LAYER + i) * 2)
								if y < r.solidBelow and buffer.readu8(cull, id) ~= 1 then
									error(`L{level} chunk {cx},{cz}: {Blocks.get(id).name} below solidBelow (y {y})`)
								end
								if y >= r.emptyAbove and id ~= AIR then
									error(`L{level} chunk {cx},{cz}: {Blocks.get(id).name} above emptyAbove (y {y})`)
								end
							end
						end
					end
				end
			end
		end
	end)

	t.test("structures: attached blocks keep their support, trees keep clear", function()
		local attached, unsupported, leaves = 0, 0, 0
		for _, start in sample do
			local e = expected(start)
			for _, p in e.list do
				local x, y, z = p[1], p[2], p[3]
				local block = blockAt(gen, 0, x, y, z)
				local dx, dy, dz = Blocks.supportOffset(block)
				if dx and dy and dz and not Blocks.isCaveTwin(block) then
					attached += 1
					if not Blocks.isSturdy(blockAt(gen, 0, x + dx, y + dy, z + dz)) then
						unsupported += 1
					end
				end
			end
			for _, piece in start.pieces do
				if piece.projection ~= Jigsaw.TERRAIN_MATCHING then
					local box = piece.box
					for x = box[1], box[4] do
						for z = box[3], box[6] do
							for y = box[2], box[5] do
								if isLeaves[blockAt(gen, 0, x, y, z)] then
									leaves += 1
								end
							end
						end
					end
				end
			end
		end
		t.ok(attached > 20, `torches and lanterns checked: {attached}`)
		t.eq(unsupported, 0, "torches and lanterns without their support")
		t.eq(leaves, 0, "leaves inside rigid pieces")
	end)

	t.test("structures: generated chests hold the template's items", function()
		local chests = 0
		local fresh = TerrainGenerator.new(SEED)
		for _, start in found do
			for i, piece in start.pieces do
				local template = start.templates[i]
				for _, c in template.containers do
					local size = template.size
					local lx, ly, lz = Transform.position(c.x, c.y, c.z, size[1], size[3], piece.rotation)
					local x, y, z = piece.x + lx, piece.y + ly, piece.z + lz
					local items = gen.structureContainer(x, y, z)
					t.ok(items ~= nil, `chest of {piece.template} at {x} {y} {z}`)
					if items then
						t.eq(#items, #c.items, "stacks")
						for k, item in c.items do
							t.eq(items[k].item, item.item)
							t.eq(items[k].count, item.count)
							t.eq(items[k].slot, item.slot)
							t.eq(items[k].damage, item.damage)
						end
						-- A fresh copy each time, and a cold cache answers alike.
						t.ok(gen.structureContainer(x, y, z) ~= items, "a fresh copy")
						t.eq(#(fresh.structureContainer(x, y, z) or {}), #items, "cold cache")
						t.eq(blockAt(gen, 0, x, y, z), Blocks.id.Chest, "a chest is there")
					end
					t.eq(gen.structureContainer(x, y + 1, z), nil, "nothing above it")
					t.eq(gen.structureContainer(x, y - 1, z), nil, "nothing below it")
					chests += 1
					if chests >= 4 then
						break
					end
				end
			end
		end
		t.ok(chests > 0, "generated chests checked")
		t.eq(gen.structureContainer(1000000, 70, 1000000), nil, "nothing far away")
		t.eq(plain.structureContainer(0, 70, 0), nil, "nothing without structures")
	end)

	t.test("structures: deterministic whatever the cache and chunk order; off switch", function()
		local start = sample[1]
		local box = start.pieces[1].box
		local cx, cz = ((box[1] + box[4]) // 2) // SIZE, ((box[3] + box[6]) // 2) // SIZE
		-- Neighbours first with one generator, the chunk alone (cold cache) with another.
		local warm = TerrainGenerator.new(SEED)
		warm.generate(0, cx + 1, cz)
		warm.generate(1, (cx + 1) // 2, cz // 2)
		local a = warm.generate(0, cx, cz)
		local b = TerrainGenerator.new(SEED).generate(0, cx, cz)
		t.eq(buffer.tostring(a.data), buffer.tostring(b.data), "same chunk")
		t.eq(a.emptyAbove, b.emptyAbove)
		t.eq(a.solidBelow, b.solidBelow)
		local p = chunk(plain, 0, cx, cz)
		t.ok(buffer.tostring(a.data) ~= buffer.tostring(p.data), "the outpost is there")
		-- Config.Structures.Generate = false: none (read when a generator is made).
		local before = Config.Structures.Generate
		Config.Structures.Generate = false
		local off = TerrainGenerator.new(SEED)
		Config.Structures.Generate = before
		t.eq(#off.structures(-2500, -2500, 2500, 2500), 0, "Generate off: no structures")
		t.eq(buffer.tostring(off.generate(0, cx, cz).data), buffer.tostring(p.data), "Generate off: plain terrain")
	end)

	t.test("structures: assembled once per placer, a small cache", function()
		local placer = StructureGen.new(SEED, library, {
			firstFreeHeight = firstFree,
			biome = function(x: number, z: number): number
				local _, biome = gen.column(x, z)
				return biome
			end,
			land = function(x: number, z: number): boolean
				return gen.column(x, z) > SEA
			end,
		})
		local start = sample[1]
		local b = start.bounds
		local first = placer.starts(b[1], b[3], b[4], b[6])
		local same = nil
		for _, s in first do
			if s.x == start.x and s.z == start.z then
				same = s
			end
		end
		local assembled = placer.assembled()
		t.ok(assembled >= 1, "assembled")
		for _ = 1, 5 do
			placer.starts(b[1], b[3], b[4], b[6])
		end
		t.eq(placer.assembled(), assembled, "served from the cache")
		t.ok(same ~= nil, "the generator's start")
		t.eq(#(same or { pieces = {} }).pieces, #start.pieces, "same pieces as the generator's")
		-- More starts than the cache holds: old ones are assembled again when needed.
		placer.starts(-3600, -3600, 3600, 3600)
		local after = placer.assembled()
		placer.starts(b[1], b[3], b[4], b[6])
		t.eq(placer.assembled(), after + 1, "evicted and assembled again")
	end)

	t.test("structures: the cache grows with the library, so a walk assembles each start once", function()
		-- 30 structures with the defaults a Generate value gets (spacing 34, separation 8): chunks
		-- in rings around the origin, as streaming asks for them. A fixed 48 start cache thrashed
		-- here (about 9 assemblies per start with 40 structures).
		local templates = {}
		for _, name in library.names do
			table.insert(templates, library.templates[name])
		end
		local Pools = require(shared.StructureLibrary.Pools)
		local specs = {}
		for i = 1, 30 do
			table.insert(specs, { name = `copy{i}`, startPool = "outpost/centres", size = 1, onLand = false })
		end
		local many = Library.new({ templates = templates, pools = Pools, structures = specs })
		t.eq(#many.structures, 30)
		local terrain = {
			firstFreeHeight = function(_x: number, _z: number): number
				return SEA + 6
			end,
			biome = function(_x: number, _z: number): number
				return 1
			end,
			land = function(_x: number, _z: number): boolean
				return true
			end,
		}
		local function walk(placer: StructureGen.Placer): number
			for r = 0, 12 do
				for cx = -r, r do
					for cz = -r, r do
						if math.max(math.abs(cx), math.abs(cz)) == r then
							local x0, z0 = cx * SIZE - 1, cz * SIZE - 1
							placer.starts(x0 - 10, z0 - 10, x0 + SIZE + 11, z0 + SIZE + 11)
						end
					end
				end
			end
			return placer.assembled()
		end
		local assembled = walk(StructureGen.new(SEED, many, terrain))
		-- The same walk with a cache that never forgets: every start assembled exactly once.
		local saved = StructureGen.CACHE_SIZE
		StructureGen.CACHE_SIZE = math.huge
		local once = walk(StructureGen.new(SEED, many, terrain))
		StructureGen.CACHE_SIZE = saved
		print(`    30 structures, rings of chunks: {assembled} assemblies, {once} distinct starts`)
		t.ok(once >= 30, "starts to cache")
		t.eq(assembled, once, "no start assembled twice")
	end)

	t.test("structures: generation cost", function()
		-- Chunks covering an outpost: with structures and without (same terrain), and assembly.
		local start = sample[1]
		local b = start.bounds
		local chunks = {}
		for cx = b[1] // SIZE, b[4] // SIZE do
			for cz = b[3] // SIZE, b[6] // SIZE do
				table.insert(chunks, { cx, cz })
			end
		end
		local function time(g: any): number
			local best = math.huge
			for _ = 1, 3 do
				local t0 = os.clock()
				for _, c in chunks do
					g.generate(0, c[1], c[2])
				end
				best = math.min(best, os.clock() - t0)
			end
			return best / #chunks
		end
		local with = time(gen)
		local without = time(plain)
		-- Assembly of a start (cold), averaged over the outposts found.
		local t0 = os.clock()
		local fresh = TerrainGenerator.new(SEED)
		local n = #fresh.structures(-2500, -2500, 2500, 2500)
		local assembly = (os.clock() - t0) / math.max(n, 1)
		print(
			string.format(
				"    full detail chunks under an outpost: %.2f ms with structures, %.2f ms without; assembly %.2f ms per start",
				with * 1000,
				without * 1000,
				assembly * 1000
			)
		)
		t.ok(with < 1.5 * without + 0.005, "structures cost less than half of a chunk's generation")
		t.ok(assembly < 0.05, "assembly takes less than 50 ms")
	end)

	-- (Silence the unused helper warning for Template: the outpost's data decodes through it.)
	t.test("structures: the outpost's templates decode and re-encode alike", function()
		local Outpost = require(shared.StructureLibrary.Templates.Outpost)
		t.ok(#Outpost >= 8, "outpost templates")
		for _, text in Outpost do
			local template, err = Template.decode(text)
			t.ok(template ~= nil, err)
			if template then
				t.eq(Template.encode(template), text, `{template.name} re-encodes alike`)
			end
		end
	end)
end
