--[[
	Structures/Library and the StructureLibrary folder: implicit pools by name prefix (and a
	template's own name), explicit pools (weights, empty elements, fallbacks, projections),
	structures and their defaults, validation warnings (never an error on bad data), assembling
	through a library, `Library.load` from the repo's modules (which must load without warnings)
	and from a place's ReplicatedStorage.IceVoxelStructures folder with its attributes.
]]
return function(t, shared, require)
	local Blocks = require(shared.Blocks)
	local Biomes = require(shared.Biomes)
	local Hash = require(shared.Util.Hash)
	local Jigsaw = require(shared.Structures.Jigsaw)
	local Library = require(shared.Structures.Library)

	local id = Blocks.id
	local STONE = id.Stone
	local COBBLE = id.Cobblestone

	-- A template of sx × sy × sz filled with `block`; jigsaws: { x, y, z, front, top, name,
	-- target, pool, finalState?, joint? }, their cells holding the jigsaw block of that orientation.
	local function template(name: string, sx: number, sy: number, sz: number, block: number, jigsaws: { any }?): any
		local cells = buffer.create(sx * sy * sz * 2)
		for i = 0, sx * sy * sz - 1 do
			buffer.writeu16(cells, i * 2, 1)
		end
		local palette = { block }
		local list = {}
		for _, j in jigsaws or {} do
			local jigsawBlock = Blocks.jigsawBlock(j[4], j[5])
			local inside = j[1] >= 0 and j[1] < sx and j[2] >= 0 and j[2] < sy and j[3] >= 0 and j[3] < sz
			if jigsawBlock and inside then
				local p = table.find(palette, jigsawBlock)
				if p == nil then
					table.insert(palette, jigsawBlock)
					p = #palette
				end
				buffer.writeu16(cells, ((j[2] * sz + j[3]) * sx + j[1]) * 2, p)
			end
			table.insert(list, {
				x = j[1],
				y = j[2],
				z = j[3],
				front = j[4],
				top = j[5],
				name = j[6],
				target = j[7],
				pool = j[8],
				finalState = j[9] or "Air",
				joint = j[10] or (if j[4] == "Up" or j[4] == "Down" then "rollable" else "aligned"),
			})
		end
		return {
			name = name,
			size = { sx, sy, sz },
			palette = palette,
			cells = cells,
			jigsaws = list,
			markers = {},
			containers = {},
		}
	end

	local function has(list: { string }, pattern: string): boolean
		for _, s in list do
			if string.find(s, pattern, 1, true) then
				return true
			end
		end
		return false
	end

	local function poolNames(pool: any): string
		local names = {}
		for _, e in pool.elements do
			table.insert(names, `{e.template or "<empty>"}:{e.weight}:{e.projection}`)
		end
		return table.concat(names, " ")
	end

	--[[ Pools ]]

	t.test("implicit pools: every template under '<pool>/', sorted, weight 1, rigid", function()
		local lib = Library.new({
			templates = {
				template("town/houses/b", 3, 3, 3, STONE),
				template("town/houses/a", 3, 3, 3, STONE),
				template("town/houses/big/c", 5, 4, 5, STONE),
				template("town/streets/x", 3, 1, 5, COBBLE),
				template("townhall", 3, 3, 3, STONE),
			},
			projections = { ["town/streets/x"] = "terrain_matching" },
		})
		t.eq(#lib.warnings, 0, "no warnings")
		t.eq(table.concat(lib.names, ","), "town/houses/a,town/houses/b,town/houses/big/c,town/streets/x,townhall")
		local houses = lib.pool("town/houses") :: any
		t.eq(poolNames(houses), "town/houses/a:1:rigid town/houses/b:1:rigid town/houses/big/c:1:rigid")
		t.eq(houses.fallback, nil, "no fallback")
		t.eq(poolNames(lib.pool("town/houses/big")), "town/houses/big/c:1:rigid", "nested pool")
		t.eq(poolNames(lib.pool("town/streets")), "town/streets/x:1:terrain_matching", "projection hint")
		-- "town" holds everything under "town/" but not "townhall".
		t.eq(#(lib.pool("town") :: any).elements, 4, "prefix needs the slash")
		t.eq(lib.pool("nothing"), nil, "unknown pool")
		t.eq(lib.pool("town/houses"), houses, "cached")
		t.eq(lib.template("town/houses/a"), lib.templates["town/houses/a"])
		t.eq(lib.template("nope"), nil)
	end)

	t.test("a template's own name is a pool of that template alone", function()
		local lib = Library.new({
			templates = {
				template("tower", 3, 9, 3, STONE),
				template("tower/top", 3, 3, 3, STONE),
				template("tower/top/flag", 1, 3, 1, STONE),
			},
		})
		t.eq(poolNames(lib.pool("tower")), "tower:1:rigid", "exact name")
		t.eq(poolNames(lib.pool("tower/top")), "tower/top:1:rigid")
		-- Both shadowed pools are pointed out.
		t.ok(has(lib.warnings, "pool 'tower' is that template alone"), "warned")
		t.ok(has(lib.warnings, "pool 'tower/top' is that template alone"), "warned")
	end)

	t.test("explicit pools: weights, empty elements, fallback, projections; they shadow implicit ones", function()
		local lib = Library.new({
			templates = {
				template("v/streets/a", 3, 1, 9, COBBLE),
				template("v/streets/b", 3, 1, 9, COBBLE),
				template("v/ends/a", 3, 1, 1, COBBLE),
			},
			pools = {
				["v/streets"] = {
					fallback = "v/ends",
					projection = "terrain_matching",
					elements = {
						{ template = "v/streets/a", weight = 4 },
						{ template = "v/streets/b", projection = "rigid" },
						{ empty = true, weight = 2 },
					},
				},
			},
		})
		t.eq(#lib.warnings, 0, table.concat(lib.warnings, "; "))
		local pool = lib.pool("v/streets") :: any
		t.eq(poolNames(pool), "v/streets/a:4:terrain_matching v/streets/b:1:rigid <empty>:2:terrain_matching")
		t.eq(pool.fallback, "v/ends")
		t.eq(lib.pools["v/streets"], pool, "listed")
		t.eq(poolNames(lib.pool("v/ends")), "v/ends/a:1:rigid", "the fallback is an implicit pool")
	end)

	t.test("bad pools and elements are reported and skipped, never an error", function()
		local lib = Library.new({
			templates = { template("p/a", 3, 3, 3, STONE) },
			pools = {
				broken = 5,
				nolist = { elements = "x" },
				mixed = {
					fallback = "p/missing",
					elements = {
						{ template = "p/a", weight = 0 },
						{ template = "p/a", weight = 1000 },
						{ template = "p/a", weight = 2.5, projection = "sideways" },
						{ template = "p/nope" },
						{ template = 42 },
						"string",
					},
				},
				hollow = { elements = { { template = "p/nope" } } },
			} :: any,
		})
		local w = lib.warnings
		t.ok(has(w, "Pool 'broken' has no elements list"), "not a table")
		t.ok(has(w, "Pool 'nolist' has no elements list"), "no list")
		t.ok(has(w, "element #1: weight must be 1..150 (1 used)"), "weight 0")
		t.ok(has(w, "element #2: weight must be 1..150 (150 used)"), "weight 1000")
		t.ok(has(w, "element #3: weight must be 1..150 (2 used)"), "weight 2.5")
		t.ok(has(w, "unknown projection 'sideways'"), "projection")
		t.ok(has(w, "Pool 'mixed': no template 'p/nope'"), "missing template")
		t.ok(has(w, "element #5: template must be a name"), "bad name")
		t.ok(has(w, "element #6 is not a table"), "bad element")
		t.ok(has(w, "fallback pool 'p/missing' has no templates"), "fallback")
		t.ok(has(w, "Pool 'hollow' has no usable elements"), "hollow")
		t.eq(poolNames(lib.pool("mixed")), "p/a:1:rigid p/a:150:rigid p/a:2:rigid")
		-- A hollow explicit pool stays (and assembling warns), it does not fall back to implicit.
		t.eq(#(lib.pool("hollow") :: any).elements, 0)
	end)

	t.test("template validation: jigsaws pointing at nothing, bad orientations, final states", function()
		local broken = template("q/broken", 3, 3, 3, STONE)
		table.insert(broken.jigsaws, 5)
		table.insert(broken.jigsaws, { x = 1, y = 1, z = 1, front = "North", top = "Up" })
		local lib = Library.new({
			templates = {
				broken,
				template("q/start", 5, 3, 5, STONE, {
					{ 0, 1, 2, "West", "Up", "a", "b", "q/nowhere" },
					{ 4, 1, 2, "East", "Up", "a", "b", "q/nowhere" },
					{ 2, 2, 2, "Up", "Up", "c", "d", "empty" },
					{ 2, 0, 2, "Down", "North", "c", "d", "empty", "minecraft:not_a_block" },
					{ 1, 1, 0, "North", "Up", "c", "d", "empty", "minecraft:oak_log", "sideways" },
					{ 9, 1, 0, "North", "Up", "c", "d", "empty" },
				}),
				template("q/other", 3, 3, 3, STONE, { { 1, 1, 0, "North", "Up", "a", "b", "q/nowhere" } }),
			},
		})
		local w = lib.warnings
		t.ok(has(w, "Pool 'q/nowhere' (used by q/other, q/start) has no templates"), "one warning per pool")
		t.ok(has(w, "jigsaw at 2 2 2 has a bad orientation (Up / Up)"), "orientation")
		t.ok(has(w, "unknown final state 'minecraft:not_a_block'"), "final state")
		t.ok(not has(w, "oak_log"), "minecraft names resolve (oak_log -> OakLog)")
		t.ok(has(w, "unknown joint 'sideways'"), "joint")
		t.ok(has(w, "jigsaw at 9 1 0 is outside the template"), "outside")
		t.ok(has(w, "Template 'q/broken': a jigsaw has no position"), "not a table")
		t.ok(has(w, "Template 'q/broken': jigsaw at 1 1 1 has no name, target or pool"), "no names")
		-- Assembling with such a template does not error either.
		local pieces = Jigsaw.assemble({
			seed = 1,
			startPool = "q/broken",
			x = 0,
			z = 0,
			projectToHeightmap = true,
			firstFreeHeight = function()
				return 5
			end,
			maxDepth = 3,
			pool = lib.pool,
			template = lib.template,
		})
		t.eq(#pieces, 1, "the broken template alone")
		t.eq(lib.pool(5 :: any), nil, "non-string pool names")
		t.eq(lib.template(nil :: any), nil, "non-string template names")
	end)

	t.test("bad templates are skipped; later templates replace earlier ones", function()
		local good = template("r/a", 2, 2, 2, STONE)
		local newer = template("r/a", 4, 2, 2, STONE)
		local lib = Library.new({
			templates = {
				good,
				{ name = "", size = { 1, 1, 1 } },
				{ name = "r/b", size = { 0, 1, 1 }, cells = buffer.create(0), palette = {}, jigsaws = {} },
				{ name = "r/c", size = { 2, 2, 2 }, cells = buffer.create(2), palette = {}, jigsaws = {} },
				"nonsense",
				newer,
			} :: any,
		})
		t.ok(has(lib.warnings, "Template #2 has no name"), "no name")
		t.ok(has(lib.warnings, "Template #3 is empty"), "empty")
		t.ok(has(lib.warnings, "Template #4 has no cells"), "short buffer")
		t.ok(has(lib.warnings, "Template #5 is not a template"), "not a table")
		t.ok(has(lib.warnings, "Template 'r/a' is defined twice"), "duplicate")
		t.eq(lib.template("r/a"), newer, "the later one wins")
		t.eq(#lib.names, 1)
	end)

	--[[ Structures ]]

	t.test("structures: defaults filled in, biomes resolved, reach", function()
		local lib = Library.new({
			templates = {
				template("s/centre", 9, 5, 7, STONE, { { 4, 0, 0, "North", "Up", "x", "y", "s/parts" } }),
				template("s/parts/a", 3, 3, 3, STONE),
			},
			structures = {
				{ name = "plain", startPool = "s/centre" },
				{
					name = "custom",
					startPool = "s/centre",
					startJigsawName = "x",
					size = 0,
					maxDistance = 40,
					biomes = { "Plains", "Savanna", "Atlantis" },
					spacing = 20,
					separation = 4,
					salt = 99,
					startHeight = -3,
					projectToHeightmap = false,
					onLand = false,
					foundation = false,
				},
				{ name = "listed", startPool = "s/centre", biomes = "Meadow, Forest" },
				-- Minecraft-style names match as final states do.
				{ name = "loose", startPool = "s/centre", biomes = "plains, minecraft:birch_forest, SAVANNA" },
			},
		})
		t.eq(#lib.structures, 4)
		local plain = lib.structure("plain") :: any
		t.eq(plain.size, 7, "size")
		t.eq(plain.maxDistance, 80, "maxDistance")
		t.eq(plain.spacing, 34, "spacing")
		t.eq(plain.separation, 8, "separation")
		t.eq(plain.salt, Hash.string("plain"), "salt from the name")
		t.eq(plain.startHeight, 0)
		t.eq(plain.projectToHeightmap, true)
		t.eq(plain.onLand, true)
		t.eq(plain.foundation, true)
		t.eq(plain.startJigsawName, nil)
		t.eq(#plain.biomes, Biomes.count, "every biome by default")
		-- The start piece is 9 wide: its centre is within 8 of the start, pieces within 80 of it.
		t.eq(plain.reach, 8 + 80, "reach")

		local custom = lib.structure("custom") :: any
		t.eq(custom.size, 0)
		t.eq(custom.maxDistance, 40)
		t.eq(table.concat(custom.biomes, ","), "Plains,Savanna")
		t.ok(custom.biomeSet[(Biomes.byName("Plains") :: any).index], "biome set")
		t.ok(not custom.biomeSet[(Biomes.byName("Desert") :: any).index], "biome set")
		t.ok(has(lib.warnings, "unknown biome 'Atlantis'"), "unknown biome")
		t.eq(custom.spacing, 20)
		t.eq(custom.separation, 4)
		t.eq(custom.salt, 99)
		t.eq(custom.startHeight, -3)
		t.eq(custom.projectToHeightmap, false)
		t.eq(custom.onLand, false)
		t.eq(custom.foundation, false)
		t.eq(custom.startJigsawName, "x")
		t.eq(custom.reach, 8, "size 0: the start piece only")
		t.eq(table.concat((lib.structure("listed") :: any).biomes, ","), "Meadow,Forest", "comma list")
		t.eq(table.concat((lib.structure("loose") :: any).biomes, ","), "Plains,BirchForest,Savanna", "loose names")
		t.ok(not has(lib.warnings, "Structure 'loose'"), "no warning for loose names")
		t.ok(has(lib.warnings, "unknown biome 'Atlantis' (biomes: Tundra,"), "the warning lists the biomes")
	end)

	t.test("structures: bad entries are reported and skipped or fixed", function()
		local lib = Library.new({
			templates = {
				template("s/centre", 5, 5, 5, STONE, { { 2, 0, 0, "North", "Up", "x", "y", "empty" } }),
			},
			structures = {
				"nonsense",
				{ startPool = "s/centre" },
				{ name = "nostart" },
				{ name = "missing", startPool = "s/none" },
				{ name = "nojigsaw", startPool = "s/centre", startJigsawName = "zzz" },
				{ name = "nobiome", startPool = "s/centre", biomes = { "Atlantis" } },
				{
					name = "fixed",
					startPool = "s/centre",
					spacing = 10,
					separation = 10,
					size = 12,
					maxDistance = 500,
					onLand = "yes",
					salt = 1.5,
				},
				{ name = "twice", startPool = "s/centre", spacing = 5 },
				{ name = "twice", startPool = "s/centre", spacing = 6 },
			} :: any,
		})
		local w = lib.warnings
		t.ok(has(w, "Structure #1 has no name"), "not a table")
		t.ok(has(w, "Structure #2 has no name"), "no name")
		t.ok(has(w, "Structure 'nostart' has no startPool"), "no start pool")
		t.ok(has(w, "start pool 's/none' has no templates"), "missing pool")
		t.ok(has(w, "no template in 's/centre' has a jigsaw named 'zzz'"), "start jigsaw")
		t.ok(has(w, "Structure 'nobiome' can grow in no biome"), "no biome")
		t.ok(has(w, "separation must be 0..9 (9 used)"), "separation")
		t.ok(has(w, "size must be 0..7 (7 used)"), "size")
		t.ok(has(w, "maxDistance must be 1..128 (128 used)"), "distance")
		t.ok(has(w, "onLand must be true or false"), "flag")
		t.ok(has(w, "salt must be a whole number"), "salt")
		t.ok(has(w, "Structure 'twice' is defined twice"), "duplicate")
		local names = {}
		for _, s in lib.structures do
			table.insert(names, s.name)
		end
		t.eq(table.concat(names, ","), "fixed,twice", "only valid ones, in order")
		t.eq((lib.structure("twice") :: any).spacing, 6, "the later one")
		local fixed = lib.structure("fixed") :: any
		t.eq(fixed.separation, 9)
		t.eq(fixed.size, 7)
		t.eq(fixed.maxDistance, 128)
		t.eq(fixed.onLand, true)
	end)

	t.test("no code needed: pieces named under a pool assemble through the library", function()
		local lib = Library.new({
			templates = {
				template("mything/start", 7, 4, 7, STONE, {
					{ 3, 1, 0, "North", "Up", "door", "door", "mything/houses" },
					{ 3, 1, 6, "South", "Up", "door", "door", "mything/houses" },
				}),
				template("mything/houses/a", 5, 4, 5, STONE, { { 2, 1, 0, "North", "Up", "door", "door", "empty" } }),
				template("mything/houses/b", 3, 5, 3, STONE, { { 1, 1, 0, "North", "Up", "door", "door", "empty" } }),
			},
			structures = { { name = "mything", startPool = "mything/start" } },
		})
		t.eq(#lib.warnings, 0, table.concat(lib.warnings, "; "))
		local s = lib.structures[1]
		local pieces = Jigsaw.assemble({
			seed = 5,
			startPool = s.startPool,
			startJigsawName = s.startJigsawName,
			x = 0,
			z = 0,
			startHeight = s.startHeight,
			projectToHeightmap = s.projectToHeightmap,
			firstFreeHeight = function()
				return 70
			end,
			maxDepth = s.size,
			maxDistance = s.maxDistance,
			pool = lib.pool,
			template = lib.template,
		})
		t.eq(#pieces, 3, "the start and a house on each side")
		t.eq(pieces[1].template, "mything/start")
		for i = 2, 3 do
			t.ok(string.sub(pieces[i].template, 1, 15) == "mything/houses/", "a house")
			t.eq(pieces[i].y, pieces[1].y, "doors line up")
		end
		for _, p in pieces do
			t.ok(math.abs(p.box[1]) <= s.reach and math.abs(p.box[4]) <= s.reach, "within reach")
			t.ok(math.abs(p.box[3]) <= s.reach and math.abs(p.box[6]) <= s.reach, "within reach")
		end
	end)

	--[[ Loading ]]

	t.test("splitData and splitList", function()
		local parts = Library.splitData('  "IVS1:abc",\nIVS1:de f  junk IVS1:g-_')
		t.eq(#parts, 3)
		t.eq(parts[1], "IVS1:abc", "quote and comma trimmed")
		t.eq(parts[2], "IVS1:de f  junk", "inner spaces kept (decode ignores them)")
		t.eq(parts[3], "IVS1:g-_", "base64url's - and _ kept")
		t.eq(#Library.splitData("no data"), 0)
		t.eq(table.concat(Library.splitList(" Plains, Savanna ;Forest,, "), "|"), "Plains|Savanna|Forest")
		t.eq(#Library.splitList("   ,  ;"), 0, "blank names dropped")
	end)

	t.test("splitData and splitList take linear time on long runs of junk", function()
		local run = string.rep(" ", 64000)
		local started = os.clock()
		local parts = Library.splitData("IVS1:ab" .. run .. "cd" .. run .. '",')
		local names = Library.splitList("a" .. run .. "b" .. run .. ",c")
		t.ok(os.clock() - started < 0.5, `took {os.clock() - started} s`)
		t.eq(#parts, 1)
		t.eq(#parts[1], 5 + 2 + 64000 + 2, "inner run kept, trailing junk trimmed")
		t.eq(#names, 2)
		t.eq(#names[1], 1 + 64000 + 1)
		t.eq(names[2], "c")
	end)

	t.test("Library.load: the repo's StructureLibrary loads without warnings (cached)", function()
		local lib = Library.load()
		t.eq(#lib.warnings, 0, table.concat(lib.warnings, "; "))
		t.eq(Library.load(), lib, "cached")
		print(`    repo library: {#lib.names} templates, {#lib.structures} structures`)
		for _, s in lib.structures do
			-- Every shipped structure must assemble.
			local pieces = Jigsaw.assemble({
				seed = 1,
				startPool = s.startPool,
				startJigsawName = s.startJigsawName,
				x = 0,
				z = 0,
				startHeight = s.startHeight,
				projectToHeightmap = s.projectToHeightmap,
				firstFreeHeight = function()
					return 100
				end,
				maxDepth = s.size,
				maxDistance = s.maxDistance,
				pool = lib.pool,
				template = lib.template,
				warn = function(message)
					error(`{s.name}: {message}`)
				end,
			})
			t.ok(#pieces >= 1, `{s.name} assembles`)
		end
	end)

	-- Stand-ins for Roblox instances: Folders and StringValues with attributes.
	local function folder(name: string, children: { any }): any
		local self = { Name = name, ClassName = "Folder" }
		function self.GetChildren(_)
			return table.clone(children)
		end
		function self.IsA(_, class)
			return class == "Folder" or class == "Instance"
		end
		function self.FindFirstChild(_, n)
			for _, c in children do
				if c.Name == n then
					return c
				end
			end
			return nil
		end
		function self.GetAttribute(_, _n)
			return nil
		end
		return self
	end
	local function stringValue(name: string, value: string, attributes: { [string]: any }?): any
		local self = { Name = name, ClassName = "StringValue", Value = value }
		function self.GetChildren(_)
			return {}
		end
		function self.IsA(_, class)
			return class == "StringValue" or class == "ValueBase" or class == "Instance"
		end
		function self.FindFirstChild(_, _n)
			return nil
		end
		function self.GetAttribute(_, n)
			return (attributes or {})[n]
		end
		return self
	end

	t.test("Library.load: the place's IceVoxelStructures folder and its attributes", function()
		local Template = require(shared.Structures.Template)
		local function encoded(tp: any): string
			return Template.encode(tp)
		end
		local start = template("user/keep/start", 7, 4, 7, STONE, {
			{ 3, 1, 0, "North", "Up", "door", "door", "user/keep/rooms" },
		})
		local room =
			template("user/keep/rooms/a", 5, 4, 5, STONE, { { 2, 1, 0, "North", "Up", "door", "door", "empty" } })
		local path = template("user/paths/a", 3, 1, 7, COBBLE)
		local hut = template("user/hut", 5, 5, 5, STONE)
		local warnings = {}
		local place = folder("IceVoxelStructures", {
			folder("Keep", {
				stringValue("Start", encoded(start), {
					Generate = true,
					Biomes = "Plains, Forest",
					Spacing = 12,
					Separation = 3,
					Size = 2,
					Foundation = false,
				}),
				-- Two templates in one value (whitespace between them is fine).
				stringValue("Rooms", encoded(room) .. "\n\n" .. encoded(path), { TerrainMatching = false }),
			}),
			stringValue("Paths", encoded(path), { TerrainMatching = true }),
			stringValue("Hut", encoded(hut), { Generate = true, Spacing = "lots" }),
			stringValue("Broken", "IVS1:AAAA"),
			stringValue("Empty", "hello"),
		})
		local lib = Library.load({
			modules = folder("StructureLibrary", {}),
			folder = place,
			warn = function(message)
				table.insert(warnings, message)
			end,
		})
		t.ok(lib ~= Library.load(), "not the cached default")
		t.eq(table.concat(lib.names, ","), "user/hut,user/keep/rooms/a,user/keep/start,user/paths/a")
		t.ok(has(warnings, "IceVoxelStructures/Broken"), "bad data reported")
		t.ok(has(warnings, "IceVoxelStructures/Empty: no IVS1 data"), "no data reported")
		t.ok(has(warnings, "attribute Spacing must be a number"), "wrong attribute type")
		t.ok(has(warnings, "Template 'user/paths/a' is defined twice"), "same template twice")
		t.eq(poolNames(lib.pool("user/paths")), "user/paths/a:1:terrain_matching", "TerrainMatching")
		t.eq(#lib.structures, 2, "two Generate templates")
		local keep = lib.structure("user/keep/start") :: any
		t.eq(keep.startPool, "user/keep/start")
		t.eq(table.concat(keep.biomes, ","), "Plains,Forest")
		t.eq(keep.spacing, 12)
		t.eq(keep.separation, 3)
		t.eq(keep.size, 2)
		t.eq(keep.foundation, false)
		local hutStructure = lib.structure("user/hut") :: any
		t.eq(hutStructure.spacing, Library.DEFAULT_SPACING, "bad attribute ignored")
		-- It assembles: the start and a room.
		local pieces = Jigsaw.assemble({
			seed = 2,
			startPool = keep.startPool,
			x = 0,
			z = 0,
			projectToHeightmap = true,
			firstFreeHeight = function()
				return 80
			end,
			maxDepth = keep.size,
			pool = lib.pool,
			template = lib.template,
		})
		t.eq(#pieces, 2, "start and room")
		-- The folder's order does not matter (clients may get children in another order), even
		-- for two values at the same path defining the same template.
		local small = template("user/twin", 2, 2, 2, STONE)
		local big = template("user/twin", 4, 2, 2, STONE)
		local function twins(reversed: boolean)
			local children = {
				stringValue("Twin", encoded(small), { Generate = true, Spacing = 9 }),
				stringValue("Twin", encoded(big), { Generate = true, Spacing = 7 }),
			}
			if reversed then
				children = { children[2], children[1] }
			end
			return Library.load({
				modules = folder("StructureLibrary", {}),
				folder = folder("F", children),
				warn = function() end,
			})
		end
		local a, b = twins(false), twins(true)
		t.eq((a.template("user/twin") :: any).size[1], (b.template("user/twin") :: any).size[1], "same template")
		t.eq((a.structure("user/twin") :: any).spacing, (b.structure("user/twin") :: any).spacing, "same structure")
		-- The same for StructureLibrary/Templates: values sharing a name (Studio's default
		-- "Value", or two copies of a save) holding versions of one template.
		local function versions(order: { number }): number
			local children = {}
			for _, width in order do
				table.insert(children, stringValue("Value", encoded(template("user/shed", width, 2, 2, STONE))))
			end
			local loaded = Library.load({
				modules = folder("StructureLibrary", { folder("Templates", children) }),
				folder = folder("F", {}),
				warn = function() end,
			})
			return (loaded.template("user/shed") :: any).size[1]
		end
		local forward = versions({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 })
		t.eq(versions({ 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1 }), forward, "Templates: order does not matter")
		t.eq(versions({ 5, 12, 1, 9, 3, 11, 2, 8, 4, 10, 6, 7 }), forward, "Templates: any order")
		-- Loose biome names in the Biomes attribute.
		local shed = template("user/shed", 3, 2, 3, STONE)
		local loose = Library.load({
			modules = folder("StructureLibrary", {}),
			folder = folder(
				"F",
				{ stringValue("Shed", encoded(shed), { Generate = true, Biomes = "plains, forest" }) }
			),
			warn = function() end,
		})
		t.eq(table.concat((loose.structure("user/shed") :: any).biomes, ","), "Plains,Forest", "plains, forest")
		-- A decoded template holds the same cells.
		local decoded = lib.template("user/hut") :: any
		t.eq(decoded.size[1] * decoded.size[2] * decoded.size[3], 125)
		local p = buffer.readu16(decoded.cells, 0)
		t.eq(decoded.palette[p], STONE, "cells survive the round trip")
	end)
end
