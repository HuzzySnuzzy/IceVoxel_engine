--[[
	The world types' generators (Generation/WorldTypes, LayeredGenerator, Superflat, DebugWorlds,
	TerrainGenerator's `biome` and `climateScale`): every type generates every LOD level within the
	chunk contract (solidBelow, emptyAbove, extras, seams), Superflat presets (parsing, bad presets
	falling back with a message, layers, the sea, far levels, decoration), the Void's platform,
	Single Biome and Large Biomes against the Default (which stays byte for byte what it was:
	pinned digests), the debug worlds' grids (every block once at y 70 with gaps, every structure
	once without overlap and alike across chunk borders, name tags, biome strips), the declared
	settings and hints, and the consumers: the map, the culling (SectionGraph, Horizon), safe
	spawning and structure block records.
]]

return function(t, shared, require, server)
	local Config = require(shared.Config)
	local Blocks = require(shared.Blocks)
	local Biomes = require(shared.Biomes)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Hash = require(shared.Util.Hash)
	local Horizon = require(shared.World.Horizon)
	local SectionGraph = require(shared.World.SectionGraph)
	local Caves = require(shared.Generation.Caves)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)
	local WorldTypes = require(shared.Generation.WorldTypes)
	local LayeredGenerator = require(shared.Generation.LayeredGenerator)
	local Superflat = require(shared.Generation.Superflat)
	local DebugWorlds = require(shared.Generation.DebugWorlds)
	local MapPainter = require(shared.Map.MapPainter)
	local Library = require(shared.Structures.Library)
	local Jigsaw = require(shared.Structures.Jigsaw)
	local Settings = require(shared.Structures.Settings)
	local GameMode = require(shared.GameMode)
	local WorldServer = require(server.World.WorldServer)
	local SafeSpot = require(server.Players.SafeSpot)
	local StructureStore = require(server.Structures.StructureStore)

	local SIZE = ChunkLayout.SIZE
	local P = ChunkLayout.PADDED
	local LAYER = ChunkLayout.LAYER
	local AIR = Blocks.AIR
	local B = Blocks.id
	local readu16, readu8 = buffer.readu16, buffer.readu8
	local cullHidden = Blocks.cullLutHiddenCaves
	local SEED = 12345
	local PLAINS = (Biomes.byName("Plains") :: any).index

	local function digest(b: buffer?): number
		return if b then Hash.string(buffer.tostring(b)) else 0
	end

	local function at(r: any, px: number, y: number, pz: number): number
		if y >= r.height then
			return AIR
		end
		return readu16(r.data, ((y * P + pz) * P + px) * 2)
	end

	-- The chunk contract (TerrainGenerator.ChunkResult): sizes, solidBelow, emptyAbove, extras.
	local function checkChunk(r: any, what: string)
		t.eq(buffer.len(r.data), LAYER * r.height * 2, `{what}: buffer size`)
		t.ok(r.height >= 1 and r.height <= ChunkLayout.cellsTall(r.level), `{what}: height in range`)
		t.ok(r.emptyAbove <= r.height, `{what}: emptyAbove inside`)
		for pz = 0, P - 1 do
			for px = 0, P - 1 do
				for y = 0, r.height - 1 do
					local block = at(r, px, y, pz)
					if y < r.solidBelow and readu8(cullHidden, block) == 0 then
						error(`{what}: open cell {block} at {px},{y},{pz} below solidBelow {r.solidBelow}`)
					end
					if y >= r.emptyAbove and block ~= AIR then
						error(`{what}: block {block} at {px},{y},{pz} above emptyAbove {r.emptyAbove}`)
					end
				end
			end
		end
		t.ok(r.summary ~= nil and buffer.len(r.summary) == Horizon.SUMMARY_BYTES, `{what}: summary`)
		if r.level == 0 then
			t.ok(r.surface ~= nil and buffer.len(r.surface) == SIZE * SIZE * 2, `{what}: surface`)
		end
		for tile = 0, 15 do
			t.ok(Horizon.ground(r.summary, tile) <= Horizon.top(r.summary, tile) + 16, `{what}: ground under top`)
		end
	end

	-- What a chunk worker does with a full detail chunk (ChunkWorker `generate`): the culling.
	local function cull(r: any): buffer
		local exact: { [number]: boolean } = {}
		if r.structureSpan then
			for s = r.structureSpan[1] // 16, r.structureSpan[2] // 16 do
				exact[s] = true
			end
		end
		SectionGraph.dugSections(r.data, r.height, r.surface, r.solidBelow, exact)
		local extra = {}
		for s in exact do
			table.insert(extra, s)
		end
		local sections = SectionGraph.carvedSections(r.carved, Caves.CELL_Y, extra)
		return SectionGraph.build(r.data, r.height, r.solidBelow, sections, {
			carved = r.carved,
			cellXZ = Caves.CELL_XZ,
			cellY = Caves.CELL_Y,
			originX = r.nx * SIZE,
			originZ = r.nz * SIZE,
			surface = r.surface,
			exact = exact,
		})
	end

	--[[ Every type ]]

	t.test("world types: the list, unique ids, names, descriptions, hints and settings well formed", function()
		local seen: { [string]: boolean } = {}
		local expected = {
			"default",
			"superflat",
			"void",
			"singleBiome",
			"largeBiomes",
			"debugBlocks",
			"debugStructures",
			"debugBiomes",
		}
		for i, id in expected do
			t.eq(WorldTypes.list[i].id, id, "menu order")
		end
		for _, worldType in WorldTypes.list do
			t.ok(not seen[worldType.id], `unique id {worldType.id}`)
			seen[worldType.id] = true
			t.ok(worldType.name ~= "" and worldType.description ~= "", `{worldType.id}: name and description`)
			t.ok(worldType.gameMode == nil or GameMode.isValid(worldType.gameMode), `{worldType.id}: game mode`)
			local keys: { [string]: boolean } = {}
			for _, setting in worldType.settings or {} do
				t.ok(not keys[setting.key], `{worldType.id}: unique setting {setting.key}`)
				keys[setting.key] = true
				t.ok(setting.name ~= "", "setting name")
				if setting.kind == "toggle" then
					t.eq(type(setting.default), "boolean", `{setting.key}: toggle default`)
				elseif setting.kind == "choice" then
					local choices = setting.choices :: { string }
					t.ok(table.find(choices, setting.default :: string) ~= nil, `{setting.key}: default is a choice`)
					t.eq(#(setting.labels :: { string }), #choices, `{setting.key}: a label per choice`)
				elseif setting.kind == "text" then
					t.eq(type(setting.default), "string", `{setting.key}: text default`)
				else
					error(`{worldType.id}: unknown setting kind {setting.kind}`)
				end
			end
		end
		for _, id in { "debugBlocks", "debugStructures", "debugBiomes", "void" } do
			t.eq((WorldTypes.get(id) :: any).mobs, false, `{id}: no natural mobs`)
		end
		for _, id in { "debugBlocks", "debugStructures" } do
			t.eq((WorldTypes.get(id) :: any).ticks, false, `{id}: nothing ticks`)
			t.ok((WorldTypes.get(id) :: any).debug, `{id}: a debug world`)
		end
		t.eq((WorldTypes.get("debugBlocks") :: any).gameMode, GameMode.SPECTATOR, "Minecraft's debug world")
		t.eq((WorldTypes.get(WorldTypes.DEFAULT) :: any).ticks, nil, "the Default ticks")
	end)

	-- A stand-in for ReplicatedStorage.IceVoxel's attributes.
	local function newFolder(): any
		local attributes: { [string]: any } = {}
		return {
			GetAttribute = function(_, name: string): any
				return attributes[name]
			end,
			SetAttribute = function(_, name: string, value: any)
				attributes[name] = value
			end,
		}
	end

	t.test("world types: published reads the attributes (the Default when unknown)", function()
		local folder = newFolder()
		WorldTypes.publish(folder, "superflat", 99, { preset = "Bedrock;Plains", decoration = true })
		local worldType, options = WorldTypes.published(folder)
		t.eq(worldType.id, "superflat")
		t.eq(options.preset, "Bedrock;Plains")
		t.eq(options.decoration, true)
		local gen, id = WorldTypes.fromAttributes(folder)
		t.eq(id, "superflat")
		t.eq((gen.column(5, 5)), 1, "a one layer world")
		folder:SetAttribute("WorldType", "nonsense")
		t.eq(WorldTypes.published(folder).id, WorldTypes.DEFAULT)
		t.eq(WorldTypes.published(newFolder()).id, WorldTypes.DEFAULT, "nothing published")
	end)

	t.test("world types: every type generates every level within the chunk contract", function()
		for _, worldType in WorldTypes.list do
			local gen = WorldTypes.create(worldType.id, SEED, {})
			t.eq(gen.seed, SEED, worldType.id)
			for level = 0, Config.Lod.Levels - 1 do
				for _, node in { { 0, 0 }, { -1, 1 } } do
					local r = gen.generate(level, node[1], node[2], nil, true)
					t.eq(r.level, level)
					checkChunk(r, `{worldType.id} L{level} {node[1]},{node[2]}`)
					local far = gen.farSeamLimits(level, node[1], node[2])
					if level < Config.Lod.Levels - 1 then
						t.ok(far ~= nil and buffer.len(far) == 4 * SIZE * 2, `{worldType.id}: far seam limits`)
					else
						t.eq(far, nil, "none at the coarsest level")
					end
				end
			end
			local seams = gen.seamLimits(0, 0, 0, { 1, 0, 2, 0 })
			t.ok(seams ~= nil and buffer.len(seams) == 4 * SIZE * 2, `{worldType.id}: seam limits`)
			t.eq(gen.seamLimits(0, 0, 0, { 0, 0, 0, 0 }), nil, `{worldType.id}: no coarser side, no limits`)
			local x, y, z = gen.findSpawn()
			t.eq((gen.column(x, z)), y, `{worldType.id}: spawn on its column`)
			local h, biome, vegetation, surface = gen.column(x, z)
			t.ok(h >= 0 and Biomes.list[biome] ~= nil and vegetation >= 0 and Blocks.isValid(surface), "column")
			t.ok(type(gen.structures(-64, -64, 64, 64)) == "table", "structures")
			t.ok(type(gen.oilWells(-64, -64, 64, 64)) == "table", "oil wells")
			t.ok(type(gen.lavaLakes(-64, -64, 64, 64)) == "table", "lava lakes")
			t.ok(type(gen.waterLakes(-64, -64, 64, 64)) == "table", "water lakes")
			t.ok(type(gen.puddles(-64, -64, 64, 64)) == "table", "puddles")
			t.ok(type(gen.surfaceCaves.carvesTop(x, z)) == "boolean", "surface caves")
			t.ok(type(gen.seaLevel) == "number", `{worldType.id}: a sea level`)
		end
	end)

	t.test("world types: full detail chunks agree across their borders (padding = neighbour's core)", function()
		for _, id in { "superflat", "void", "debugBlocks", "debugStructures", "debugBiomes" } do
			local gen = WorldTypes.create(id, SEED, {})
			local a, b = gen.generate(0, 0, 0), gen.generate(0, 1, 0)
			local c = gen.generate(0, 0, 1)
			for y = 0, math.max(a.height, b.height, c.height) - 1 do
				for k = 1, SIZE do
					-- a's +X padding is b's first core column, and the other way round.
					t.eq(at(a, P - 1, y, k), at(b, 1, y, k), `{id}: +X padding at {y},{k}`)
					t.eq(at(b, 0, y, k), at(a, SIZE, y, k), `{id}: -X padding at {y},{k}`)
					t.eq(at(a, k, y, P - 1), at(c, k, y, 1), `{id}: +Z padding at {y},{k}`)
				end
			end
		end
	end)

	t.test("world types: the map, the culling and the horizon accept every type", function()
		for _, worldType in WorldTypes.list do
			local gen = WorldTypes.create(worldType.id, SEED, {})
			local tile = MapPainter.new(gen)(-64, -64, 4, 32)
			t.eq(buffer.len(tile), 32 * 32 * 4, worldType.id)
			local r = gen.generate(0, 0, 0, nil, true)
			local graph = cull(r)
			t.eq(buffer.len(graph), SectionGraph.BYTES, `{worldType.id}: a section graph`)
		end
	end)

	--[[ The Default stays what it was ]]

	-- Digests of the Default world (seed 12345) made before world types existed: chunk data, its
	-- Horizon summary and surface, height, solidBelow, emptyAbove (outposts in the last three).
	local PINNED = {
		{ 0, 0, 0, 3763431356, 2385823076, 637642054, 112, 73, 75 },
		{ 0, 3, -2, 3308524465, 2787425146, 1146561170, 112, 71, 74 },
		{ 0, -7, 11, 1407525034, 2203614583, 1426292326, 96, 60, 64 },
		{ 0, 20, 5, 1128386215, 684176278, 885456967, 112, 40, 84 },
		{ 1, 1, 1, 2419421421, 670723311, 0, 56, 35, 41 },
		{ 2, -2, 3, 3908353193, 1244948833, 0, 24, 13, 16 },
		{ 4, 0, 0, 784031936, 522254533, 0, 7, 3, 5 },
		{ 0, 100, -40, 2062877020, 2634376917, 4083301882, 272, 229, 246 },
		{ 0, -150, 60, 3358180211, 3657096357, 3972328917, 144, 98, 107 },
		{ 3, 10, -10, 1875142174, 3052199922, 0, 40, 25, 35 },
		{ 6, 0, 0, 3250628276, 4267492549, 0, 12, 1, 9 },
		{ 0, 21, 118, 103057674, 1369674844, 1140634773, 112, 64, 71 },
		{ 0, 22, 119, 4100114075, 2112851314, 3314049870, 112, 65, 71 },
		{ 2, 5, 29, 3341450558, 1389781405, 0, 28, 14, 17 },
	}

	t.test("default world: byte for byte what it was before world types (chunks, columns, spawn, map)", function()
		for _, gen in { TerrainGenerator.new(SEED), WorldTypes.create(WorldTypes.DEFAULT, SEED, {}) } do
			for _, p in PINNED do
				local r = gen.generate(p[1], p[2], p[3], nil, true)
				local what = `L{p[1]} {p[2]},{p[3]}`
				t.eq(digest(r.data), p[4], `{what} data`)
				t.eq(digest(r.summary), p[5], `{what} summary`)
				t.eq(digest(r.surface), p[6], `{what} surface`)
				t.eq(r.height, p[7], `{what} height`)
				t.eq(r.solidBelow, p[8], `{what} solidBelow`)
				t.eq(r.emptyAbove, p[9], `{what} emptyAbove`)
			end
			local acc = 0
			for i = 0, 199 do
				local x, z = (i * 7919) % 6000 - 3000, (i * 104729) % 6000 - 3000
				local h, b, v, s = gen.column(x, z)
				acc = Hash.hash3(acc, h, b * 1000 + s, math.floor(v * 1e6))
			end
			t.eq(acc, 882441969, "columns")
			local x, y, z = gen.findSpawn()
			t.eq(`{x} {y} {z}`, "512 87 -128", "spawn")
			t.eq(digest(MapPainter.new(gen)(-512, 300, 8, 32)), 1346689466, "map tile")
			t.eq(#gen.structures(-2500, -2500, 2500, 2500), 9, "outposts")
			t.eq(gen.seaLevel, Config.SeaLevel)
		end
	end)

	--[[ Superflat ]]

	t.test("superflat: presets parse into layers and a biome; Minecraft's names paste as they are", function()
		local preset = Superflat.parse(Superflat.CLASSIC) :: any
		t.eq(#preset.layers, 3)
		t.eq(preset.layers[1].block, B.Bedrock)
		t.eq(preset.layers[2].block, B.Dirt)
		t.eq(preset.layers[2].count, 2)
		t.eq(preset.layers[3].block, B.Grass)
		t.eq(preset.biome, PLAINS)
		t.eq(preset.stack.height, 4)
		t.eq(preset.stack.ground, 4)
		t.eq(preset.stack.surface, B.Grass)
		local minecraft =
			Superflat.parse("minecraft:bedrock, 2*minecraft:dirt ,minecraft:grass_block;minecraft:plains") :: any
		t.eq(Superflat.format(minecraft.layers, minecraft.biome), Superflat.CLASSIC, "same as classic")
		t.eq((Superflat.parse("2 * dirt") :: any).biome, PLAINS, "the biome defaults to plains")
		t.eq((Superflat.parse("Snow;snowy_plains") :: any).biome, (Biomes.byName("Tundra") :: any).index)
		for _, p in Superflat.PRESETS do
			local parsed, err = Superflat.parse(p.value)
			t.ok(parsed ~= nil, `{p.name}: {err}`)
			t.eq(Superflat.format((parsed :: any).layers, (parsed :: any).biome), p.value, `{p.name}: round trip`)
		end
		t.eq((Superflat.parse(Superflat.PRESETS[2].value) :: any).stack.height, 237, "Tunnelers' Dream")
	end)

	t.test("superflat: bad presets explain themselves, and build Classic Flat", function()
		local bad = {
			{ "", "no layers" },
			{ "Bedrock,Nonsense", "Unknown block" },
			{ "Bedrock;Atlantis", "Unknown biome" },
			{ "0*Dirt", "count" },
			{ "Bedrock,,Dirt", "empty layer" },
			{ `{Superflat.MAX_HEIGHT + 1}*Stone`, "count" },
			{ `{Superflat.MAX_HEIGHT}*Stone,Dirt`, "tall" },
			{ "Dirt;Plains;Extra", "layers, then" },
		}
		for _, case in bad do
			local preset, err = Superflat.parse(case[1])
			t.eq(preset, nil, case[1])
			t.ok(err and string.find(string.lower(err), string.lower(case[2]), 1, true), `{case[1]}: {err}`)
		end
		local fallback, err = Superflat.resolve({ preset = "Bedrock,Nonsense" })
		t.ok(err ~= nil, "the reason")
		t.eq(Superflat.format(fallback.layers, fallback.biome), Superflat.CLASSIC)
		local classic = WorldTypes.create("superflat", SEED, {})
		local broken = WorldTypes.create("superflat", SEED, { preset = "Bedrock,Nonsense" })
		t.eq(digest(broken.generate(0, 2, 3).data), digest(classic.generate(0, 2, 3).data), "classic flat")
	end)

	t.test("superflat: layers from y 0, the spawn on top, every column alike, no sea", function()
		local gen = WorldTypes.create("superflat", SEED, {})
		for _, node in { { 0, 0 }, { -40, 77 } } do
			local r = gen.generate(0, node[1], node[2])
			for pz = 0, P - 1 do
				for px = 0, P - 1 do
					t.eq(at(r, px, 0, pz), B.Bedrock)
					t.eq(at(r, px, 1, pz), B.Dirt)
					t.eq(at(r, px, 2, pz), B.Dirt)
					t.eq(at(r, px, 3, pz), B.Grass)
					t.eq(at(r, px, 4, pz), AIR)
				end
			end
			t.eq(r.solidBelow, 4)
			t.eq(r.emptyAbove, 4)
		end
		local h, biome, vegetation, surface = gen.column(1234, -987)
		t.eq(h, 4)
		t.eq(biome, PLAINS)
		t.eq(vegetation, 0)
		t.eq(surface, B.Grass)
		local x, y, z = gen.findSpawn()
		t.eq(`{x} {y} {z}`, "0 4 0")
		t.eq(gen.seaLevel, 0, "no sea: the ground is low, not under water")
		t.eq(gen.labels and #(gen.labels :: any)(), 0, "no name tags")
	end)

	t.test("superflat: a thin world stays visible at every far level, skirted at its borders", function()
		local gen = WorldTypes.create("superflat", SEED, {})
		for level = 1, Config.Lod.Levels - 1 do
			local r = gen.generate(level, 3, -2)
			-- (The ground's top cell shows the surface, cell 0 at least; border columns are a
			-- cell lower.)
			local _, stepY = ChunkLayout.steps(level)
			local top = LayeredGenerator.topCellOf(4, stepY, stepY // 2)
			t.ok(top >= 0, "something to draw")
			t.eq(at(r, 5, top, 7), B.Grass, `L{level}: grass on top`)
			t.eq(at(r, 5, top + 1, 7), AIR, `L{level}: air above`)
			t.eq(at(r, 0, top, 7), AIR, `L{level}: skirted border`)
			local limits = gen.seamLimits(level, 3, -2, { level + 1, 0, 0, 0 }) :: buffer
			local _, coarseY = ChunkLayout.steps(level + 1)
			local solidTop = (LayeredGenerator.topCellOf(4, coarseY, coarseY // 2) + 1) * coarseY
			t.eq(readu16(limits, 0), math.max(solidTop // stepY, 1), `L{level}: the coarser node's top`)
		end
	end)

	t.test("superflat: water on top is the sea (ground under it, spawn over open water)", function()
		local gen = WorldTypes.create("superflat", SEED, { preset = "Bedrock,5*Stone,5*Dirt,5*Sand,90*Water;Plains" })
		t.eq(gen.seaLevel, 106)
		local h, _, vegetation, surface = gen.column(10, 10)
		t.eq(h, 16, "the ground")
		t.eq(surface, B.Sand)
		t.eq(vegetation, 0)
		local r = gen.generate(0, 0, 0)
		t.eq(at(r, 3, 15, 3), B.Sand)
		t.eq(at(r, 3, 16, 3), Blocks.fluidId("Water", 0))
		t.eq(at(r, 3, 105, 3), Blocks.fluidId("Water", 0))
		t.eq(at(r, 3, 106, 3), AIR)
		t.eq(r.solidBelow, 16, "water is not opaque")
		local far = gen.generate(4, 0, 0)
		t.eq(at(far, 5, 0, 5), B.Sand, "far: the ground's top cell")
		t.eq(at(far, 5, 6, 5), Blocks.fluidId("Water", 0), "far: the sea above it")
		-- The map draws it as water.
		local tile = MapPainter.new(gen)(0, 0, 4, 4)
		t.ok(readu8(tile, 2) > readu8(tile, 0), "blue")
		-- Spawning finds no dry spot (open water): SafeSpot.column skips it.
		local world = WorldServer.new(gen)
		t.eq(SafeSpot.column(world, 0, 0), nil, "open water")
	end)

	t.test("superflat: decoration grows the biome's trees and plants, never without it", function()
		local overworld = "Bedrock,59*Stone,3*Dirt,Grass;Forest"
		local bare = WorldTypes.create("superflat", SEED, { preset = overworld })
		local decorated = WorldTypes.create("superflat", SEED, { preset = overworld, decoration = true })
		local logs, plants, none = 0, 0, 0
		for cx = 0, 3 do
			for cz = 0, 3 do
				local a, b = bare.generate(0, cx, cz), decorated.generate(0, cx, cz)
				for pz = 1, SIZE do
					for px = 1, SIZE do
						for y = 64, b.height - 1 do
							local block = at(b, px, y, pz)
							if block == B.OakLog or block == B.BirchLog then
								logs += 1
							elseif Blocks.isPlant(block) then
								plants += 1
							end
							if at(a, px, y, pz) ~= AIR then
								none += 1
							end
						end
					end
				end
			end
		end
		t.ok(logs > 0, "trees")
		t.ok(plants > 0, "plants")
		t.eq(none, 0, "nothing on the bare world")
		t.ok(select(3, decorated.column(5, 5)) > 0, "vegetation reported for the map")
	end)

	t.test("layered: one stack everywhere (whole layers at a time) is the same stack per column", function()
		local values = { "Bedrock,10*Air,Stone,Glass;Plains" }
		for _, p in Superflat.PRESETS do
			table.insert(values, p.value)
		end
		for _, value in values do
			local preset = Superflat.parse(value) :: any
			local uniform = LayeredGenerator.new({ seed = 1, stack = preset.stack, biome = preset.biome })
			local perColumn = LayeredGenerator.new({
				seed = 1,
				columnAt = function(): (any, number)
					return preset.stack, preset.biome
				end,
			})
			for level = 0, Config.Lod.Levels - 1 do
				local a, b = uniform.generate(level, 2, -3, nil, true), perColumn.generate(level, 2, -3, nil, true)
				local what = `{value} L{level}`
				t.eq(buffer.tostring(a.data), buffer.tostring(b.data), `{what}: blocks`)
				t.eq(a.solidBelow, b.solidBelow, `{what}: solidBelow`)
				t.eq(a.emptyAbove, b.emptyAbove, `{what}: emptyAbove`)
				t.eq(digest(a.summary), digest(b.summary), `{what}: summary`)
				checkChunk(a, what)
			end
		end
		-- Air layers inside a stack stay air, and open cells lower solidBelow.
		local gen = Superflat.create(1, { preset = "Bedrock,10*Air,Stone,Glass;Plains" })
		local r = gen.generate(0, 0, 0)
		t.eq(at(r, 4, 0, 4), B.Bedrock)
		t.eq(at(r, 4, 5, 4), AIR)
		t.eq(at(r, 4, 11, 4), B.Stone)
		t.eq(at(r, 4, 12, 4), B.Glass)
		t.eq(r.solidBelow, 1)
		t.eq((gen.column(0, 0)), 13)
	end)

	--[[ The Void ]]

	t.test("void: a stone platform with cobblestone in the middle, nothing else", function()
		local gen = WorldTypes.create("void", SEED, {})
		local r = gen.generate(0, 0, 0)
		local y = WorldTypes.VOID_Y
		t.eq(at(r, 1, y, 1), B.Cobblestone, "the centre (0, 0)")
		t.eq(at(r, 2, y, 1), B.Stone)
		t.eq(at(r, P - 1, y, P - 1), B.Stone, "padding (16, 16)")
		t.eq(at(r, 1, y - 1, 1), AIR, "nothing under it")
		t.eq(at(r, 1, y + 1, 1), AIR)
		local edge = gen.generate(0, 1, 0)
		t.eq(at(edge, 1, y, 1), B.Stone, "x = 16: the platform's edge")
		t.eq(at(edge, 2, y, 1), AIR, "x = 17: past it")
		local far = gen.generate(0, 5, 5)
		t.eq(far.emptyAbove, 0, "empty")
		t.eq(buffer.tostring(far.data), string.rep("\0", buffer.len(far.data)), "all air")
		local x, sy, z = gen.findSpawn()
		t.eq(`{x} {sy} {z}`, `0 {y + 1} 0`)
		t.eq((gen.column(40, 40)), 0, "no ground off the platform")
		t.eq(select(4, gen.column(40, 40)), AIR)
		t.eq(gen.seaLevel, 0)
		local world = WorldServer.new(gen)
		t.eq(SafeSpot.column(world, 3, -5), y + 1, "a safe spot on the platform")
		t.eq(SafeSpot.column(world, 40, 40), nil, "none in the void")
		-- The map: the platform's stone, the void dark.
		local tile = MapPainter.new(gen)(-64, -64, 4, 32)
		local function pixel(px: number, py: number): number
			return readu8(tile, (py * 32 + px) * 4)
		end
		t.ok(pixel(16, 16) > pixel(0, 0), "stone brighter than the void")
	end)

	--[[ Single Biome, Large Biomes ]]

	t.test("single biome: one biome everywhere on the Default's terrain", function()
		local desert = (Biomes.byName("Desert") :: any).index
		local default = WorldTypes.create(WorldTypes.DEFAULT, SEED, { structures = false })
		local single = WorldTypes.create("singleBiome", SEED, { biome = "Desert", structures = false })
		local sand = 0
		for i = 0, 299 do
			local x, z = (i * 7919) % 8000 - 4000, (i * 104729) % 8000 - 4000
			local hd = default.column(x, z)
			local hs, b, _, surface = single.column(x, z)
			t.eq(b, desert, "desert everywhere")
			t.eq(hs, hd, "the same terrain")
			if surface == B.Sand then
				sand += 1
			end
		end
		t.ok(sand > 100, "sand on top")
		-- An unknown biome is plains.
		local unknown = WorldTypes.create("singleBiome", SEED, { biome = "Atlantis" })
		t.eq(select(2, unknown.column(10, 10)), PLAINS)
		local r = single.generate(0, 3, -2, nil, true)
		checkChunk(r, "single biome chunk")
	end)

	t.test("large biomes: the climate four times as wide, the terrain unchanged", function()
		local changesDefault, changesLarge, differ = 0, 0, 0
		for _, seed in { SEED, 777 } do
			local d = WorldTypes.create(WorldTypes.DEFAULT, seed, { structures = false })
			local l = WorldTypes.create("largeBiomes", seed, { structures = false })
			for row = 0, 20 do
				local pd, pl, last = nil, nil, false
				for i = 0, 400 do
					local x, z = i * 32 - 6400, row * 600 - 6000
					local hd, bd = d.column(x, z)
					local hl, bl = l.column(x, z)
					t.eq(hl, hd, "same terrain")
					if bd ~= bl then
						differ += 1
					end
					-- Changes between neighbouring lowland samples: the climate's doing.
					local lowland = hd > 66 and hd < 150
					if lowland and last then
						if pd ~= bd then
							changesDefault += 1
						end
						if pl ~= bl then
							changesLarge += 1
						end
					end
					pd, pl, last = bd, bl, lowland
				end
			end
		end
		t.ok(differ > 0, "other biomes")
		t.ok(changesLarge < changesDefault * 0.9, `fewer biome borders ({changesLarge} vs {changesDefault})`)
	end)

	--[[ Debug: All Blocks ]]

	t.test("debug blocks: every block but air once, at y 70 on odd x and z, ordered by id", function()
		local gen = WorldTypes.create("debugBlocks", SEED, {})
		local list = DebugWorlds.gridBlocks()
		t.eq(#list, Blocks.count - 2, "every id but air and cave air")
		local width = DebugWorlds.gridWidth(#list)
		t.eq(width, math.ceil(math.sqrt(#list)))
		local found: { [number]: { number } } = {}
		local count = 0
		local span = (2 * width + 1) // SIZE
		for cx = -1, span + 1 do
			for cz = -1, span + 1 do
				local r = gen.generate(0, cx, cz)
				for y = 0, r.height - 1 do
					for lz = 0, SIZE - 1 do
						for lx = 0, SIZE - 1 do
							local block = ChunkLayout.get(r.data, lx, y, lz)
							if block ~= AIR then
								local x, z = cx * SIZE + lx, cz * SIZE + lz
								t.eq(y, DebugWorlds.BLOCK_Y, "at y 70")
								t.ok(x % 2 == 1 and z % 2 == 1 and x > 0 and z > 0, "odd x and z: a gap between")
								t.eq(found[block], nil, `block {block} once`)
								found[block] = { x, z }
								count += 1
							end
						end
					end
				end
			end
		end
		t.eq(count, #list, "all of them")
		for k, block in list do
			local x, z = DebugWorlds.gridPosition(k - 1, width)
			local where = found[block]
			t.ok(where and where[1] == x and where[2] == z, `{Blocks.get(block).name} at its place`)
		end
		-- The fluid rule: every level of every fluid (sources and flowing), standing still since
		-- the world has no ticks; plants and supported blocks alone, as in Minecraft.
		t.ok(found[Blocks.fluidId("Water", 0)] and found[Blocks.fluidId("Water", 5)], "water levels")
		t.ok(found[Blocks.fluidId("Lava", 8)] and found[B.CaveLava], "lava levels and its twin")
		t.ok(found[B.TallGrassTop] and found[B.WallTorchNorth], "upper halves and wall torches")
		t.eq((WorldTypes.get("debugBlocks") :: any).ticks, false, "no ticks: nothing flows or drops")
		-- Spawn standing on block 0 (bedrock), which column() reports.
		local x, y, z = gen.findSpawn()
		t.eq(`{x} {y} {z}`, "1 71 1")
		local h, _, _, surface = gen.column(1, 1)
		t.eq(h, 71)
		t.eq(surface, B.Bedrock)
		t.eq((gen.column(2, 2)), 0, "the gaps are empty")
		local world = WorldServer.new(gen)
		local sx, sy, sz = SafeSpot.find(world, x, z)
		t.eq(`{sx} {sy} {sz}`, "1 71 1", "a safe spot on the bedrock")
	end)

	t.test("debug blocks: far levels keep the grid (the cell holding each block)", function()
		local gen = WorldTypes.create("debugBlocks", SEED, {})
		for level = 1, Config.Lod.Levels - 1 do
			local r = gen.generate(level, 0, 0)
			local _, stepY = ChunkLayout.steps(level)
			local cy = DebugWorlds.BLOCK_Y // stepY
			local any = 0
			for pz = 1, SIZE do
				for px = 1, SIZE do
					if at(r, px, cy, pz) ~= AIR then
						any += 1
					end
				end
			end
			t.ok(any > 0, `L{level}: blocks`)
		end
	end)

	--[[ Debug: All Structures ]]

	local library = Library.load()

	t.test("debug structures: every template and generated structure once, no overlaps, tags outside", function()
		local entries = DebugWorlds.structureLayout(SEED, library)
		t.eq(#entries, #library.names + #library.structures, "every template and structure")
		local seen: { [string]: number } = {}
		for _, e in entries do
			seen[e.name] = (seen[e.name] or 0) + 1
		end
		for _, name in library.names do
			t.eq(seen[name], 1, `template {name} once`)
		end
		for _, s in library.structures do
			t.eq(seen[s.name], 1, `structure {s.name} once`)
		end
		for i, a in entries do
			local ba = a.start.bounds
			t.eq(ba[1], a.x)
			t.eq(ba[3], a.z)
			for j, b in entries do
				local bb = b.start.bounds
				if i ~= j then
					local overlap = ba[1] <= bb[4] and ba[4] >= bb[1] and ba[3] <= bb[6] and ba[6] >= bb[3]
					t.ok(not overlap, `{a.name} and {b.name} apart`)
				end
				local l = a.label
				t.ok(not (l.x >= bb[1] and l.x <= bb[4] and l.z >= bb[3] and l.z <= bb[6]), `{a.name}'s tag outside`)
			end
			for _, piece in a.start.pieces do
				t.eq(piece.rotation, if #a.start.pieces == 1 then 0 else piece.rotation, "templates unturned")
			end
		end
		-- Deterministic.
		local again = DebugWorlds.structureLayout(SEED, library)
		for i, e in entries do
			t.eq(again[i].x, e.x)
			t.eq(again[i].z, e.z)
			t.eq(#again[i].start.pieces, #e.start.pieces)
		end
	end)

	t.test("debug structures: the chunks hold every template block, alike across chunk borders", function()
		local gen = DebugWorlds.allStructures(SEED, library)
		local entries = DebugWorlds.structureLayout(SEED, library)
		local cache: { [string]: any } = {}
		local function chunk(cx: number, cz: number): any
			local key = `{cx},{cz}`
			local r = cache[key]
			if r == nil then
				r = gen.generate(0, cx, cz)
				cache[key] = r
			end
			return r
		end
		local function blockAt(x: number, y: number, z: number): number
			local cx, cz = x // SIZE, z // SIZE
			local r = chunk(cx, cz)
			return if y < r.height then ChunkLayout.get(r.data, x - cx * SIZE, y, z - cz * SIZE) else AIR
		end
		local checked = 0
		for _, e in entries do
			if #e.start.pieces ~= 1 then
				continue
			end
			local piece = e.start.pieces[1]
			local template = e.start.templates[1]
			local palette, finals = Jigsaw.writeTables(piece, template)
			local sx, sy, sz = template.size[1], template.size[2], template.size[3]
			for ly = 0, sy - 1 do
				for lz = 0, sz - 1 do
					for lx = 0, sx - 1 do
						local index = (ly * sz + lz) * sx + lx
						local v = readu16(template.cells, index * 2)
						local expected = finals[index] or palette[v]
						if v ~= 0 and expected >= 0 then
							local got = blockAt(piece.x + lx, piece.y + ly, piece.z + lz)
							t.eq(got, expected, `{e.name} at {lx},{ly},{lz}`)
							checked += 1
						end
					end
				end
			end
			-- Its name tag: a SAVE structure block on the floor, LABEL blocks north.
			t.eq(blockAt(e.label.x, e.label.y, e.label.z), Blocks.structureBlock("save"), `{e.name}: tag`)
		end
		t.ok(checked > 1000, `template blocks checked ({checked})`)
		-- Chunks agree across borders where pieces cross them.
		for key, r in cache do
			local cx, cz = string.match(key, "(-?%d+),(-?%d+)")
			local east = chunk(tonumber(cx) :: number + 1, tonumber(cz) :: number)
			for y = 0, math.min(r.height, east.height) - 1 do
				for k = 1, SIZE do
					t.eq(at(r, P - 1, y, k), at(east, 1, y, k), `{key}: +X padding`)
				end
			end
		end
		-- Far levels point sample them.
		local far = gen.generate(1, 0, 0)
		local nonFloor = 0
		for pz = 1, SIZE do
			for px = 1, SIZE do
				for y = DebugWorlds.FLOOR // 2, far.height - 1 do
					if at(far, px, y, pz) ~= AIR then
						nonFloor += 1
					end
				end
			end
		end
		t.ok(nonFloor > 0, "far: structures drawn")
	end)

	t.test("debug structures: name tags as structure block records, containers, spawn on the floor", function()
		local gen = DebugWorlds.allStructures(SEED, library)
		local labels = (gen.labels :: any)()
		t.eq(#labels, #DebugWorlds.structureLayout(SEED, library))
		-- As Structures/StructureBlocks seeds them: valid settings, kept as given.
		local store = StructureStore.new()
		local save = Blocks.structureBlock("save") :: number
		for _, label in labels do
			store:blockChanged(label.x, label.y, label.z, AIR, save)
			local settings = Settings.defaultStructure("save")
			settings.name = label.name
			settings.offset = table.clone(label.offset)
			settings.size = table.clone(label.size)
			t.eq(Settings.checkStructure(settings), nil, `{label.name}: valid settings`)
			t.ok(store:setStructure(label.x, label.y, label.z, settings), "stored")
			local kept = store:structure(label.x, label.y, label.z) :: any
			t.eq(kept.name, label.name)
			t.ok(Settings.sameStructure(kept, Settings.clampStructure(settings)), "unclamped")
			-- The region starts at the structure's corner.
			t.eq(label.x + label.offset[1], label.x)
			t.eq(label.z + label.offset[3], label.z + DebugWorlds.LABEL)
		end
		-- A generated chest holds the template's items.
		local found = 0
		for _, e in DebugWorlds.structureLayout(SEED, library) do
			if #e.start.pieces == 1 then
				local piece = e.start.pieces[1]
				for _, c in e.start.templates[1].containers do
					local items = gen.structureContainer(piece.x + c.x, piece.y + c.y, piece.z + c.z)
					t.ok(items ~= nil and #items == #c.items, `{e.name}: chest contents`)
					found += 1
				end
			end
		end
		t.ok(found > 0, "the library has a chest")
		local x, y, z = gen.findSpawn()
		t.eq(y, DebugWorlds.FLOOR)
		local world = WorldServer.new(gen)
		t.eq(SafeSpot.column(world, x, z), DebugWorlds.FLOOR, "standing on the floor")
		t.eq(#gen.structures(-10, -10, 10000, 10000), #labels, "every start")
	end)

	--[[ Debug: All Biomes ]]

	t.test("debug biomes: a 16 block strip per biome, its ground, trees and plants", function()
		local gen = WorldTypes.create("debugBiomes", SEED, {})
		for i, biome in Biomes.list do
			local x = (i - 1) * DebugWorlds.STRIP + 3
			local h, b, _, surface = gen.column(x, 40)
			t.eq(b, i, `{biome.name} strip`)
			t.eq(h, DebugWorlds.FLOOR)
			t.eq(surface, biome.top)
			t.eq(select(2, gen.column(x + Biomes.count * DebugWorlds.STRIP, -500)), i, "repeats")
		end
		local forest = (Biomes.byName("Forest") :: any).index
		local logs = 0
		for cz = 0, 5 do
			local r = gen.generate(0, forest - 1, cz)
			for pz = 1, SIZE do
				for px = 1, SIZE do
					for y = DebugWorlds.FLOOR, r.height - 1 do
						local block = at(r, px, y, pz)
						if block == B.OakLog or block == B.BirchLog then
							logs += 1
						end
					end
				end
			end
		end
		t.ok(logs > 0, "forest trees")
		local x, _, z = gen.findSpawn()
		t.eq(select(2, gen.column(x, z)), PLAINS, "spawn in the plains")
	end)
end
