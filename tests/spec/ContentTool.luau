--[[
	The content tool (tests/content; its workings tests/lib/ContentTool, its view of the game
	tests/lib/ContentGame): every check on the fixture packs in tests/fixtures/content/tool
	(FixtureLint, one of each finding, and FixtureLintPatch, a JSON pack patching it), grafted into
	a fresh game after every pack there (lib/GamePacks); what each finding says (an item out of
	reach named by its cause, a brewed potion item's fix on its potion, a pack naming another's
	entries without requiring it, or one loading after it, a recipe never used and how to replace
	the one winning over it); named recipes (tests/spec/Content's FixtureRecipes pack, overriding
	and removing the Minecraft pack's: no finding, listed and shown by name, the override's file
	named); the game's packs, which load, the
	shipped ones with no warning, and whose faces rule agrees with the TexturePack spec's; a load
	error, named; what each entry came from (the loader's record, content.origin: the fixture packs
	of tests/spec/Content, Gamma's overrides; a kind folder's recipes by their file); the lists
	(with the nearest kind or pack for a word that is neither, lore and fuel as the game has them)
	and the pages (biomes and biome tags too, every field whole, every way survival gets an item);
	and a new pack's modules, which load and pass the check as they are made, a second one too,
	their header saying where their order puts them.

	Nothing here pins an id or a total: the game's content may grow, and an author's packs move
	nothing here (the fixtures load after them and name what they make "Fixture...").
]]

local Loader = require("../lib/Loader")
local GamePacks = require("../lib/GamePacks")
local ContentGame = require("../lib/ContentGame")
local ContentTool = require("../lib/ContentTool")

local TOOL = "tests/fixtures/content/tool"
local PACKS = "tests/fixtures/content/packs"

return function(t, shared, require, _server, _client)
	local Schema = require(shared.Content.Schema)
	local Blocks = require(shared.Blocks)
	local world = ContentGame.scanWorld()

	-- A fresh game after `edit` had its chance to add packs to Content/Packs: its View, or nil and
	-- the error.
	local function fresh(edit: ((env: Loader.Environment, packs: Loader.Node) -> ())?): (any?, string?)
		local env = Loader.new()
		local root = env.mount("src/shared", "ReplicatedStorage", "IceVoxel")
		if edit then
			edit(env, (root :: any).Content.Packs)
		end
		return ContentGame.load(env, root, world)
	end

	local function withLint(): any
		local view, problem = fresh(function(env, packs)
			GamePacks.graftLast(env, `{TOOL}/FixtureLint`, packs, "FixtureLint")
			GamePacks.graftLast(env, `{TOOL}/FixtureLintPatch`, packs, "FixtureLintPatch")
		end)
		assert(view, problem)
		return view
	end

	-- `pack`'s findings as "check subject" strings, sorted.
	local function of(findings: { ContentTool.Finding }, pack: string): { string }
		local list = {}
		for _, finding in findings do
			if finding.pack == pack then
				table.insert(list, `{finding.check} {finding.subject}`)
			end
		end
		table.sort(list)
		return list
	end

	local function finding(findings: { ContentTool.Finding }, check: string, subject: string): ContentTool.Finding?
		for _, each in findings do
			if each.check == check and each.subject == subject then
				return each
			end
		end
		return nil
	end

	-- Does `lines` hold a line containing every one of `parts` (plain)?
	local function has(lines: { string }, parts: { string }): boolean
		for _, line in lines do
			local all = true
			for _, part in parts do
				all = all and string.find(line, part, 1, true) ~= nil
			end
			if all then
				return true
			end
		end
		return false
	end

	--[[ The checks ]]

	t.test("content tool: one of each finding, each on its entry and pack, nothing else", function()
		local view = withLint()
		local findings = ContentTool.check(view)
		-- (FixtureLintSecond's recipe is the FixtureLint pack's fifth: recipes are named by their
		-- place in it.)
		local place = 5
		t.eq(
			table.concat(of(findings, "FixtureLint"), ", "),
			table.concat({
				"age item FixtureLintLate",
				"faces block FixtureLintBare",
				"icon item FixtureLintNoIcon",
				"loot loot table fixture_lint_unused",
				"lore block FixtureLintBare",
				`recipe recipe #{place} (FixtureLintSecond)`,
				"requires requires",
				"survival block FixtureLintBare",
				"survival block FixtureLintOre",
				"survival item FixtureLintLost",
				"survival item FixtureLintNugget",
				"survival item FixtureLintRaw",
				'texture texture "fixture lint unused"',
			}, ", "),
			"FixtureLint's findings"
		)
		t.eq(#of(findings, "FixtureLintPatch"), 0, "nothing against the patch")
		-- Levels: the reach is an info, the rest warnings.
		t.eq((finding(findings, "survival", "item FixtureLintLost") :: any).level, "info")
		t.eq((finding(findings, "lore", "block FixtureLintBare") :: any).level, "warning")
		-- What each says.
		local age = (finding(findings, "age", "item FixtureLintLate") :: any).text
		t.ok(string.find(age, "FixtureLintPart", 1, true) and string.find(age, 'age = "iron"', 1, true), age)
		t.ok(string.find(age, "Stone Age", 1, true) and string.find(age, "Iron Age", 1, true), age)
		local shadow = (finding(findings, "recipe", `recipe #{place} (FixtureLintSecond)`) :: any).text
		t.ok(
			string.find(shadow, "FixtureLintFirst", 1, true)
				and string.find(shadow, "pack FixtureLint's recipe #4", 1, true),
			shadow
		)
		t.ok(string.find((finding(findings, "faces", "block FixtureLintBare") :: any).text, "texture", 1, true))
		t.ok(
			string.find(
				(finding(findings, "loot", "loot table fixture_lint_unused") :: any).text,
				"nothing rolls it",
				1,
				true
			)
		)
		local lintOnly: { ContentTool.Finding } = {}
		for _, each in findings do
			if each.pack == "FixtureLint" then
				table.insert(lintOnly, each)
			end
		end
		local requires = finding(lintOnly, "requires", "requires") :: any
		t.eq(requires.level, "warning", "a pack it could require: a warning")
		t.ok(
			string.find(requires.text, "pack Minecraft's Speed (item FixtureLintLate)", 1, true)
				and string.find(requires.text, 'requires = { "Core", "Minecraft" }?', 1, true),
			requires.text
		)
		-- Out of reach: named by the cause, not round the loop of the raw drop and its nuggets.
		local function says(subject: string): string
			return (finding(findings, "survival", subject) :: any).text
		end
		t.eq(
			says("item FixtureLintLost"),
			"survival never gives it: no recipe, loot table, drop, mob drop or structure gives it"
		)
		t.eq(
			says("block FixtureLintOre"),
			"survival never gives it: the world never makes it and no recipe, loot table, drop, mob drop or structure gives it"
		)
		t.ok(
			string.find(
				says("item FixtureLintRaw"),
				"only breaking FixtureLintOre gives it, and the world never makes it",
				1,
				true
			),
			says("item FixtureLintRaw")
		)
		local nugget = says("item FixtureLintNugget")
		t.ok(
			string.find(
				nugget,
				"its recipe needs FixtureLintRaw, which survival never gives: only breaking FixtureLintOre",
				1,
				true
			) and string.find(nugget, "no ore feature", 1, true),
			nugget
		)
		-- Findings come pack by pack in load order, warnings before infos.
		local packs = {}
		for _, each in view.packs do
			table.insert(packs, each.name)
		end
		local last, lastLevel = 0, "warning"
		for _, each in findings do
			local at = table.find(packs, each.pack) :: number
			t.ok(at >= last, "pack order")
			if at > last then
				lastLevel = "warning"
			end
			t.ok(not (lastLevel == "info" and each.level == "warning"), "warnings first")
			last, lastLevel = at, each.level
		end
	end)

	t.test("content tool: a smelting recipe for an input an earlier one takes never smelts", function()
		-- (A pack after every other smelting the Minecraft pack's Cobblestone, and Core's logs, into
		-- Glass: a furnace takes the first recipe for an input, Crafting/Smelting. Each named: a
		-- recipe's name is its result's, and the Minecraft pack's sand has Glass's. And a torch's
		-- grid making a Lantern: Torch's recipe fits it first.)
		local view, problem = fresh(function(env, packs)
			local order = GamePacks.orderAfter(env, packs, 900)
			local later = env.folder(packs, "Later")
			env.module(later, "pack", { order = order, requires = { "Core", "Minecraft" } })
			env.module(later, "recipes", {
				{ type = "smelting", input = "Cobblestone", result = "Glass", name = "GlassFromCobblestone" },
				{ type = "smelting", input = "#logs", result = "Glass", name = "GlassFromLogs" },
				{
					type = "shaped",
					pattern = { "X", "#" },
					key = { X = "Coal", ["#"] = "Stick" },
					result = "Lantern",
					name = "LanternFromCoal",
				},
			})
		end)
		assert(view, problem)
		local findings = ContentTool.check(view)
		local clash = finding(findings, "recipe", "recipe #1 (GlassFromCobblestone)")
		t.ok(clash and clash.pack == "Later" and clash.level == "warning", "a warning against the later pack")
		local text = if clash then clash.text else "(none)"
		t.ok(
			string.find(
				text,
				"never smelted: Cobblestone smelts into Stone, as pack Minecraft's recipes/smelting",
				1,
				true
			),
			text
		)
		-- (How to replace that one: an override of its name.)
		t.ok(
			string.find(text, "(Stone) comes first", 1, true)
				and string.find(text, 'to replace that recipe, override it (name = "Stone", override = true)', 1, true),
			text
		)
		local logs = finding(findings, "recipe", "recipe #2 (GlassFromLogs)")
		local logText = if logs then logs.text else "(none)"
		t.ok(
			string.find(logText, "never smelted: ", 1, true) and string.find(logText, "smelts into Charcoal", 1, true),
			logText
		)
		t.ok(string.find(logText, 'override it (name = "Charcoal", override = true)', 1, true), logText)
		local lantern = finding(findings, "recipe", "recipe #3 (LanternFromCoal)")
		local lanternText = if lantern then lantern.text else "(none)"
		t.ok(
			string.find(lanternText, "never crafted: its own grid makes Torch x4, as pack Minecraft's", 1, true)
				and string.find(lanternText, "(Torch) fits first", 1, true)
				and string.find(lanternText, 'override it (name = "Torch", override = true)', 1, true),
			lanternText
		)
		for _, each in of(findings, "Minecraft") do
			t.ok(string.sub(each, 1, 7) ~= "recipe ", `nothing against the earlier one: {each}`)
		end
	end)

	t.test("content tool: a pack's recipe overrides and removal: no finding, listed and shown by name", function()
		-- (The FixtureRecipes pack of tests/spec/Content: Torch's and IronIngotFromRawIron's
		-- replaced, Ladder's removed, FixtureStickFromFlint its own.)
		local view, problem = fresh(function(env, packs)
			GamePacks.graftLast(env, "tests/fixtures/content/recipes/FixtureRecipes", packs, "FixtureRecipes")
		end)
		assert(view, problem)
		local findings = ContentTool.check(view)
		t.eq(table.concat(of(findings, "FixtureRecipes"), ", "), "", "no finding: an override never hides")
		for _, each in of(findings, "Minecraft") do
			t.ok(string.sub(each, 1, 7) ~= "recipe ", `nothing against the recipes it replaced: {each}`)
		end
		-- Listed: its merged place, its name, what it is, its maker and the override's file.
		local list = assert(ContentTool.list(view, "recipes", "FixtureRecipes"))
		t.ok(
			has(list, {
				"Torch",
				"shaped Torch x8",
				"Minecraft (patched by FixtureRecipes's recipes/a_overrides), recipes/lights, recipe #1",
			}),
			"an override: listed under the pack patching it"
		)
		t.ok(has(list, { "IronIngotFromRawIron", "smelting RawIron -> IronIngot x2" }), "by the name it gives")
		t.ok(
			has(list, { "FixtureStickFromFlint", "shapeless Stick x2", "FixtureRecipes, recipes/b_new, recipe #1" }),
			"its own"
		)
		t.ok(not has(assert(ContentTool.list(view, "recipes")), { "Ladder", "shaped Ladder" }), "Ladder's gone")
		-- Shown by name: its place, its maker and the override's file, its fields.
		local torch = assert(ContentTool.show(view, "Torch"))
		t.ok(has(torch, { "recipe Torch: #", "pack Minecraft, recipes/lights, recipe #1" }), "the recipe's head")
		t.ok(has(torch, { "patched by: ", "FixtureRecipes's recipes/a_overrides" }), "the override's file")
		t.ok(has(torch, { "count = 8" }), "its merged fields")
		t.ok(has(torch, { "block Torch: id" }), "and the block of that name")
		local ingot = assert(ContentTool.show(view, "IronIngotFromRawIron"))
		t.ok(has(ingot, { "recipe IronIngotFromRawIron: #", "pack Minecraft, recipes/smelting" }), ingot[1])
		t.ok(not has(assert(ContentTool.show(view, "Ladder")), { "recipe Ladder" }), "no recipe Ladder")
		t.ok(
			has(assert(ContentTool.show(view, "Stick")), { "(FixtureStickFromFlint): shapeless Stick x2" }),
			"an item's recipes, each by its name"
		)
		local missing, near = ContentTool.show(view, "FixtureStickFromFlnit")
		t.eq(missing, nil)
		t.eq((near :: any)[1], "FixtureStickFromFlint", "a recipe's name is a name it knows")
		-- What it names for `requires`: the recipes it overrides or removes.
		local named = {}
		ContentTool.references(
			"recipes",
			{
				{ name = "Ladder", remove = true },
				{ type = "smelting", override = true, input = "Sand", result = "Glass" },
			},
			"recipes/a",
			function(space, name, where)
				table.insert(named, `{space} {name} ({where})`)
			end
		)
		t.ok(table.find(named, "recipe Ladder (recipes/a, recipe #1 (Ladder))") ~= nil, table.concat(named, "; "))
		t.ok(table.find(named, "recipe Glass (recipes/a, recipe #2 (Glass))") ~= nil, table.concat(named, "; "))
	end)

	t.test("content tool: survival's reach follows drops, recipes and Ages", function()
		local view = withLint()
		local reach = ContentTool.reach(view)
		t.eq(reach.age.FixtureLintClean, 1, "found in the world: its drop")
		t.ok(string.find(reach.how.FixtureLintClean, "breaking FixtureLintClean", 1, true), reach.how.FixtureLintClean)
		t.eq(reach.age.FixtureLintNoIcon, 1, "smelted from it")
		t.eq(reach.age.FixtureLintPart, 2, "its own Age")
		t.eq(reach.age.FixtureLintLate, 2, "its part's Age")
		t.eq(reach.age.FixtureLintLost, nil, "never")
		t.eq(reach.age.FixtureLintBare, nil)
		-- The game's: mined, smelted, crafted from them, looted, a mob's.
		t.eq(reach.age.Cobblestone, 1, "Stone breaks into it")
		t.eq(reach.age.IronIngot, 1, "smelted from Raw Iron, which Iron Ore drops")
		t.eq(reach.age.RottenFlesh, 1, "a zombie's drop")
		t.eq(reach.age.Stone, 1, "smelted from Cobblestone")
		t.eq(reach.age.Grass, nil, "Grass breaks into Dirt, and nothing makes it")
	end)

	t.test("content tool: the report, a line per finding, the counts last", function()
		local view = withLint()
		local findings = ContentTool.check(view)
		local lines = ContentTool.report(view, findings)
		-- (Their orders: after every pack's, an author's too.)
		local orders: { [string]: number } = {}
		for _, info in view.packs do
			orders[info.name] = info.order
		end
		t.ok(
			has(lines, {
				"FixtureLint",
				`order {orders.FixtureLint}`,
				"blocks 3",
				"items 8",
				"recipes 7",
				"textures 2",
				"loot 1",
				"ores 1",
			}),
			"FixtureLint's summary"
		)
		t.ok(
			has(lines, { "FixtureLintPatch", `order {orders.FixtureLintPatch}`, "blocks 0 (1 override)" }),
			"the patch's"
		)
		t.ok(
			has(lines, { "warning", "pack FixtureLint, block FixtureLintBare: no lore line" }),
			"a warning names its pack and entry"
		)
		t.ok(has(lines, { "info", "pack FixtureLint, item FixtureLintLost:" }), "an info")
		local counts = lines[#lines]
		-- ("never used": the recipe check counts a recipe never crafted or never smelted.)
		t.ok(string.find(counts, "warnings (", 1, true) and string.find(counts, "1 never used", 1, true), counts)
		t.ok(string.find(counts, "1 unused loot", 1, true) and string.find(counts, "requires", 1, true), counts)
		-- (The fixture's own: the game's packs carry no warnings.)
		local lint: { any } = {}
		for _, finding in findings do
			if finding.pack == "FixtureLint" or finding.pack == "FixtureLintPatch" then
				table.insert(lint, finding)
			end
		end
		t.ok(ContentTool.count(lint, "warning") >= 6, `--strict fails on these ({ContentTool.count(lint, "warning")})`)
		t.ok(ContentTool.count(lint, "info") >= 2)
	end)

	--[[ The game's packs ]]

	t.test("content tool: the game's packs load; every finding names a pack and a known check", function()
		local view, problem = fresh()
		t.ok(view, problem)
		local checks = {}
		for _, check in ContentTool.CHECKS do
			checks[check.id] = true
		end
		local packs = {}
		for _, pack in view.packs do
			packs[pack.name] = true
		end
		for _, each in ContentTool.check(view) do
			t.ok(checks[each.check], `known check {each.check}`)
			t.ok(packs[each.pack], `{each.subject}'s pack {each.pack}`)
			-- (The game's own packs carry no warning: their `requires` say what they need, the
			-- dependencies no `requires` can say are infos.)
			if table.find(GamePacks.SHIPPED, each.pack) then
				t.ok(each.level == "info", `pack {each.pack}, {each.subject}: {each.text}`)
			end
		end
		local summary = ContentTool.summary(view)
		t.eq(#summary, #view.packs, "a summary line per pack")
		t.ok(has(summary, { "Core", "order 0", "ages", "fuel" }), "Core's")
		-- (The creative tier's machines are no finding: no recipe makes the Creative Energy Cube,
		-- by design, as Mekanism's.)
		t.ok(view.creativeMachines.CreativeEnergyCube, "a machine of a creative kind")
		t.eq(finding(ContentTool.check(view), "survival", "block CreativeEnergyCube"), nil, "not out of reach")
		t.ok(has(summary, { "Minecraft", "biomes" }), "the Minecraft pack's biomes")
		t.ok(has(summary, { "Survival", "biomes", "overrides)" }), "the Survival pack's herbs, overrides")
	end)

	t.test("content tool: the faces rule is the TexturePack spec's", function()
		local view = assert(fresh())
		-- (tests/spec/TexturePack's blocks that never carry a texture.)
		local B = Blocks.id
		local never: { [number]: boolean } = {}
		for _, base in { B.Torch, B.Lantern, B.Fire, B.Campfire, B.CeilingLamp } do
			for _, id in Blocks.variants(base) do
				never[id] = true
				local twin = Blocks.caveTwinFor(id)
				if twin then
					never[twin] = true
				end
			end
		end
		for id, def in Blocks.defs do
			if
				def.kind == Blocks.KIND_NONE
				or def.kind == Blocks.KIND_FLUID
				or def.transmitter
				or def.tank
				or def.machine
				or def.structureMode
				or def.jigsaw
				or def.name == "StructureVoid"
				or def.name == "GlowBlock"
			then
				never[id] = true
			end
		end
		for _, spec in view.content.blocks do
			t.eq(ContentTool.texturable(spec), not never[B[spec.name]], `{spec.name}: texturable`)
		end
	end)

	t.test("content tool: a pack that fails to load is named with its kind and entry", function()
		local view, problem = fresh(function(env, packs)
			local pack = env.folder(packs, "Broken")
			env.module(pack, "pack", { order = 900 })
			env.module(pack, "blocks", { { name = "BrokenOre", drops = "NoSuchItem" } })
		end)
		t.eq(view, nil)
		local text = problem :: string
		t.ok(string.find(text, "pack Broken", 1, true) and string.find(text, "block BrokenOre", 1, true), text)
		t.ok(string.find(text, "NoSuchItem", 1, true), text)
		-- A registry's refusal too (Blocks: an unknown material... here a texture on a fluid).
		local _, other = fresh(function(env, packs)
			local pack = env.folder(packs, "Broken")
			env.module(pack, "pack", { order = 900 })
			env.module(pack, "blocks", { { name = "BrokenAir", render = "None", texture = { All = "stone" } } })
		end)
		t.ok(other and string.find(other, "BrokenAir", 1, true), other)
	end)

	--[[ Where things came from (content.origin) ]]

	t.test("content tool: where entries came from: the maker and the packs that patched them", function()
		-- (tests/spec/Content's fixture packs: Beta, Alpha, then Gamma patching both.)
		local env = Loader.new()
		local root = env.mount("src/shared", "ReplicatedStorage", "IceVoxel")
		local folder = env.mount(PACKS, "ReplicatedStorage", "ContentFixtures")
		local Content = env.require((root :: any).Content)
		local content = Content.load(folder)
		-- (The packs' own data is no longer read again: the content's own record says it.)
		local view = { content = content, packs = content.packs, kinds = Schema.KINDS }
		local lines = assert(ContentTool.list(view, "blocks"))
		t.ok(has(lines, { "AlphaStone", "Alpha (patched by Gamma)" }), "patched")
		t.ok(has(lines, { "BetaStone", "Beta" }), "made")
		-- Each agrees with the loader's own record.
		for _, spec in content.blocks do
			local where = content.where("block", spec.name)
			t.ok(string.find(where, `pack {ContentTool.packOf(view, "blocks", spec.name)}`, 1, true), where)
		end
		local recipes = assert(ContentTool.list(view, "recipes", "Alpha"))
		-- (As the loader names a recipe: "Alpha, recipe #1".)
		t.ok(has(recipes, { "AlphaWand", "Alpha, recipe #" }), "a pack's recipes, by their place in it")
		t.ok(not has(recipes, { "BetaGem" }), "only that pack's")
		local tags = assert(ContentTool.list(view, "tags"))
		t.ok(has(tags, { "#fixture_stones", "Beta, Alpha, Gamma" }), "a tag: every pack adding to it")
		t.ok(has(ContentTool.summary(view), { "Gamma", "blocks 1 (1 override)", "tags 1" }), "Gamma's summary")
		local biomes = assert(ContentTool.list(view, "biomes"))
		t.ok(has(biomes, { "1", "BetaDunes", "Lowland", "Beta (patched by Gamma)" }), "a biome: index, bands, packs")
		t.ok(has(biomes, { "GammaGlade", "Forest", "Gamma" }))
		t.ok(has(assert(ContentTool.list(view, "biomes", "Gamma")), { "BetaDunes" }), "what a pack patched")
		-- The structure kinds: Gamma patches Alpha's pool and structure.
		t.ok(has(assert(ContentTool.list(view, "pools")), { "alpha/huts", "Alpha (patched by Gamma)", "3 elements" }))
		t.ok(
			has(
				assert(ContentTool.list(view, "structures")),
				{ "alpha_village", "alpha/huts", "Alpha (patched by Gamma)" }
			)
		)
		local gamma = assert(ContentTool.list(view, "templates", "Gamma"))
		t.ok(has(gamma, { "gamma/hut", "Gamma" }), "a pack's template")
		t.ok(not has(gamma, { "alpha/huts/hut" }), "only that pack's")
	end)

	t.test("content tool: a kind folder's recipe is named by its file, as the loader names it", function()
		local view = assert(fresh())
		local content = view.content
		-- (The Minecraft pack's recipes are a kind folder: recipes/<file>.)
		local index: number? = nil
		for at, recipe in content.recipes do
			if recipe.result == "Torch" then
				index = at
				break
			end
		end
		local origin = content.origin("recipe", index :: number) :: any
		t.eq(origin.pack, "Minecraft")
		t.ok(origin.file and string.sub(origin.file, 1, 8) == "recipes/", `its file ({origin.file})`)
		local name = `{origin.file}, recipe #{origin.index}`
		t.ok(has(assert(ContentTool.list(view, "recipes", "Minecraft")), { "Torch", `Minecraft, {name}` }), name)
		-- (Its page: the item's "made by" line, its name after its place; and the recipe's own.)
		local page = assert(ContentTool.show(view, "Torch"))
		t.ok(has(page, { `pack Minecraft, {name} (Torch):` }), "and on its page")
		t.ok(has(page, { "recipe Torch: #", `pack Minecraft, {name}` }), "the recipe of that name")
	end)

	--[[ Lists and pages ]]

	t.test("content tool: list by kind and pack; show an entry, its patches and what it became", function()
		local view = withLint()
		local blocks = assert(ContentTool.list(view, "blocks", "FixtureLint"))
		t.eq(blocks[1], "blocks: 3")
		t.ok(
			has(blocks, { tostring(view.content.blockId.FixtureLintBare), "FixtureLintBare", "FixtureLint" }),
			"id, name, pack"
		)
		t.ok(has(blocks, { "FixtureLintClean", "FixtureLint (patched by FixtureLintPatch)" }))
		t.ok(
			has(assert(ContentTool.list(view, "blocks", "FixtureLintPatch")), { "FixtureLintClean" }),
			"what a pack patched"
		)
		local all = assert(ContentTool.list(view, nil, "FixtureLint"))
		for _, head in { "blocks: 3", "items: 8", "recipes: 7", "textures: 2", "ores: 1", "loot: 1" } do
			t.ok(table.find(all, head) ~= nil, head)
		end
		t.ok(has(all, { "fixture lint unused", "FixtureLint", "blank" }), "a blank texture")
		local none, why = ContentTool.list(view, "blcoks")
		t.eq(none, nil)
		t.ok(why and string.find(why, "no kind blcoks (did you mean blocks?)", 1, true), why)
		t.eq((ContentTool.list(view, nil, "Nowhere")), nil, "an unknown pack")
		-- (`list block`: one word, neither a kind nor a pack: the nearest of either.)
		local _, word = ContentTool.list(view, nil, "block")
		t.ok(word and string.find(word, "no kind or pack block (did you mean blocks?)", 1, true), word)
		local _, packWord = ContentTool.list(view, nil, "FixtureLnit")
		t.ok(packWord and string.find(packWord, "(did you mean FixtureLint?)", 1, true), packWord)
		-- Lore: every line the game has, an entry's own too; fuel: a tag's and an entry's own.
		local lore = assert(ContentTool.list(view, "lore", "FixtureLint"))
		t.ok(has(lore, { "FixtureLintClean", "FixtureLint" }) and lore[1] ~= "lore: 0", lore[1])
		t.ok(not has(lore, { "FixtureLintBare" }), "a line it has not")
		local fuel = assert(ContentTool.list(view, "fuel"))
		t.ok(has(fuel, { "#planks", "300 ticks", "Core" }), "a tag's")
		t.ok(has(fuel, { "Coal", "1600 ticks", "Minecraft" }), "an entry's own")

		local page = assert(ContentTool.show(view, "FixtureLintClean"))
		t.ok(
			has(page, { "block FixtureLintClean", `id {view.content.blockId.FixtureLintClean}`, "pack FixtureLint" }),
			page[1]
		)
		t.ok(has(page, { "patched by: FixtureLintPatch" }))
		t.ok(has(page, { "hardness = 2" }), "the merged fields")
		t.ok(has(page, { "lore:", "A fixture block with nothing against it." }))
		t.ok(has(page, { "texture:", 'All = "fixture lint clean"', "its own entry" }))
		t.ok(has(page, { "Age: Stone Age" }), "the default")
		t.ok(has(page, { "survival: from the Stone Age" }))
		t.ok(
			has(
				page,
				{ "pack FixtureLint, recipe #1 (FixtureLintNoIcon): smelting FixtureLintClean -> FixtureLintNoIcon" }
			),
			"a recipe using it"
		)
		local item = assert(ContentTool.show(view, "FixtureLintPart"))
		t.ok(has(item, { "icon:", "blank" }))
		t.ok(
			has(item, { "food:", "heals 2 (hunger off)", "nutrition 4", "saturation 0.25 (+2)", "held 32 ticks" }),
			"what eating it does (Items/Foods)"
		)
		t.ok(has(item, { "50% Hunger (Thirst with hunger off) for 100 ticks" }), "its risk")
		local drink = assert(ContentTool.show(view, "FixtureLintLate"))
		-- (Its pieces wrapped over two lines: the page's lines joined.)
		t.ok(
			has({ table.concat(drink, " ") }, {
				"drink:",
				"a potion",
				"thirst 3",
				"hydration 0.5 (+3)",
				"Speed II for 40 ticks",
				"leaves FixtureLintPart",
			}),
			"what drinking it does (ToughAsNails/Drinks)"
		)
		t.ok(has(item, { "Age: Iron Age" }))
		t.ok(has(item, { "made by:" }) and has(item, { "shapeless FixtureLintPart" }))
		local texture = assert(ContentTool.show(view, "fixture lint clean"))
		t.ok(
			has(texture, { 'texture "fixture lint clean"', "pack FixtureLint" })
				and has(texture, { "faces of: FixtureLintClean" })
		)
		local ore = assert(ContentTool.show(view, "fixture_lint_clean"))
		t.ok(has(ore, { "ore feature fixture_lint_clean", "pack FixtureLint" }))
		local age = assert(ContentTool.show(view, "iron"))
		t.ok(has(age, { "Age iron", "Iron Age" }) and has(age, { "opens:" }) and has(age, { "FixtureLintPart" }))
		local missing, near = ContentTool.show(view, "FixtureLintClaen")
		t.eq(missing, nil)
		t.eq((near :: any)[1], "FixtureLintClean", "the nearest name")
		-- Biomes: the game's, patched by the Survival pack's herbs.
		local biomes = assert(ContentTool.list(view, "biomes", "Survival"))
		t.ok(has(biomes, { "Taiga", "Minecraft (patched by Survival" }), "the biomes a pack patched")
		local taiga = assert(ContentTool.show(view, "Taiga"))
		t.ok(has(taiga, { "biome Taiga: index ", "pack Minecraft" }), taiga[1])
		t.ok(has(taiga, { "patched by: Survival" }))
		t.ok(has(taiga, { "foliage.herbs", "WildGinger" }), "its foliage a line each")
		t.ok(has(taiga, { 'tags = { "is_taiga" }' }))
		local tag = assert(ContentTool.show(view, "#is_forest"))
		t.ok(has(tag, { "biome tag #is_forest" }) and has(tag, { "BirchForest" }), "a biome tag")
		local _, nearBiome = ContentTool.show(view, "Taigaa")
		t.eq((nearBiome :: any)[1], "Taiga", "a biome's name is near too")

		-- The structure kinds: the game's example outpost, the Minecraft pack's.
		t.ok(has(assert(ContentTool.list(view, "templates", "Minecraft")), { "outpost/houses/hut", "Minecraft" }))
		t.ok(has(assert(ContentTool.list(view, "pools")), { "outpost/houses", "Minecraft", "5 elements" }))
		t.ok(has(assert(ContentTool.list(view, "structures")), { "outpost", "outpost/centres", "Minecraft" }))
		local hut = assert(ContentTool.show(view, "outpost/houses/hut"))
		t.ok(has(hut, { "template outpost/houses/hut", "pack Minecraft" }), hut[1])
		t.ok(has(hut, { "size 5 x 7 x 6" }) and has(hut, { "palette: ", "Cobblestone" }), "its size and palette")
		t.ok(has(hut, { "in pools: outpost/houses" }), "its pool")
		local houses = assert(ContentTool.show(view, "outpost/houses"))
		t.ok(has(houses, { "pool outpost/houses", "pack Minecraft" }), houses[1])
		t.ok(has(houses, { "outpost/houses/hut", "weight 3" }) and has(houses, { "(empty)", "weight 2" }), "elements")
		local centres = assert(ContentTool.show(view, "outpost/centres"))
		t.ok(has(centres, { "pool outpost/centres: the templates named outpost/centres/..." }), centres[1])
		t.ok(has(centres, { "templates: ", "outpost/centres/ruin" }) and has(centres, { "starts: outpost" }))
		local outpost = assert(ContentTool.show(view, "outpost"))
		t.ok(
			has(outpost, { "structure outpost", "pack Minecraft" }) and has(outpost, { "spacing = 56" }),
			"a structure"
		)
		local _, nearPool = ContentTool.show(view, "outpost/huoses")
		t.eq((nearPool :: any)[1], "outpost/houses", "the nearest pool")
	end)

	t.test(
		"content tool: effects and potions listed with their ids and packs; a potion shown with its items",
		function()
			local view = withLint()
			local effects = assert(ContentTool.list(view, "effects", "Minecraft"))
			t.ok(
				has(effects, { tostring(view.content.effectId.Speed), "Speed", "beneficial", "Minecraft" }),
				"id, name, category, pack"
			)
			t.ok(not has(effects, { "Thirst" }), "only that pack's")
			local potions = assert(ContentTool.list(view, "potions"))
			t.ok(has(potions, { "Swiftness", "Speed, 3 items", "Minecraft" }), "name, effect, items, pack")
			t.ok(has(potions, { "Healing", "InstantHealth, 2 items" }))
			-- (The potion and the effect named Strength: both shown.)
			local page = assert(ContentTool.show(view, "Strength"))
			t.ok(
				has(page, { "effect Strength", `id {view.content.effectId.Strength}`, "pack Minecraft" }),
				"the effect"
			)
			t.ok(has(page, { "melee = 3" }), "its fields")
			t.ok(has(page, { "potions: Strength" }), "the potions giving it")
			t.ok(has(page, { "potion Strength: pack Minecraft" }), "and the potion")
			t.ok(
				has(
					page,
					{ "StrongPotionOfStrength", "Potion of Strength II", "Strength 2 for 1800 ticks", "+ GlowDust" }
				),
				"an item it brews"
			)
			local item = assert(ContentTool.show(view, "PotionOfStrength"))
			t.ok(has(item, { "item PotionOfStrength", "pack Minecraft" }), "a potion's item, its pack's")
			t.ok(
				has(
					item,
					{ "pack Minecraft, potion Strength, recipe #1 (PotionOfStrength): shapeless PotionOfStrength" }
				),
				"made by its brewed recipe, named by its potion as the loader names it (and by its item)"
			)
			local recipes = assert(ContentTool.list(view, "recipes", "Minecraft"))
			t.ok(has(recipes, { "StrongPotionOfStrength", "Minecraft" }), "brewed recipes are their pack's")
			local _, near = ContentTool.show(view, "Strenght")
			t.eq((near :: any)[1], "Strength", "an effect's or potion's name is near")
		end
	)

	t.test("content tool: list the skills by pack; show a skill, its cell and the recipes it gates", function()
		local view = assert(fresh())
		local content = view.content
		local skills = assert(ContentTool.list(view, "skills"))
		t.eq(skills[1], `skills: {#content.skills}`)
		local demolition: number? = nil
		for index, skill in content.skills do
			if skill.id == "demolition" then
				demolition = index
			end
		end
		t.ok(
			has(skills, { tostring(demolition), "demolition", "Demolition", "industrial row 2", "Minecraft" }),
			"its place, id, name, cell and pack"
		)
		local survival = assert(ContentTool.list(view, "skills", "Survival"))
		t.ok(has(survival, { "hardy" }) and not has(survival, { "forager" }), "a pack's own")
		local page = assert(ContentTool.show(view, "demolition"))
		t.ok(has(page, { "skill demolition", "Demolition", `node {demolition} of`, "pack Minecraft" }), page[1])
		t.ok(has(page, { 'requires = { "prospector" }' }), "its fields")
		t.ok(has(page, { "cell: the Industrial Age's column, row 2" }))
		t.ok(has(page, { "needed by: fission" }))
		t.ok(has(page, { "gates:", "Tnt", "Gunpowder" }), "the entries naming it")
		t.ok(has(page, { "pack Minecraft, recipes/fire, recipe #", "shaped Tnt" }), "and their recipes")
		local _, near = ContentTool.show(view, "demolitoin")
		t.eq((near :: any)[1], "demolition", "a skill's id is a name it knows")
		-- (A pack patching a node shows on its page and in its list.)
		local patched = assert(fresh(function(env, packs)
			GamePacks.graftLast(env, "tests/fixtures/content/skills/FixtureSkilled", packs, "FixtureSkilled")
		end))
		t.ok(has(assert(ContentTool.show(patched, "forager")), { "patched by: ", "FixtureSkilled" }), "an override")
		t.ok(
			has(
				assert(ContentTool.list(patched, "skills", "FixtureSkilled")),
				{ "forager", "Core (patched by ", "FixtureSkilled)" }
			)
		)
		t.ok(
			has(assert(ContentTool.show(patched, "fixture_blasting")), { "gates: FixtureBlastCharge" }),
			"a pack's node"
		)
	end)

	t.test("content tool: sound events and tracks: lists by pack, pages with what names them", function()
		-- (The Content spec's sounds and music fixture pack, grafted in.)
		local view, problem = fresh(function(env, packs)
			GamePacks.graftLast(env, "tests/fixtures/content/sounds/FixtureChorus", packs, "FixtureChorus")
		end)
		assert(view, problem)
		local number = 0
		for index, spec in view.content.sounds do
			if spec.name == "entity.fixture_chorus.sing" then
				number = index
			end
		end
		local sounds = assert(ContentTool.list(view, "sounds", "FixtureChorus"))
		t.ok(has(sounds, { `#{number}`, "entity.fixture_chorus.sing", "FixtureChorus" }), "number, name, pack")
		t.ok(has(sounds, { "block.fixture_chime.step", "FixtureChorus", "block.step" }), "and category")
		t.ok(has(sounds, { "ui.button.click", "Minecraft (patched by ", "FixtureChorus)" }), "what a pack patched")
		local music = assert(ContentTool.list(view, "music", "FixtureChorus"))
		t.ok(has(music, { "fixture_chorus_mood", "mood", "FixtureChorus" }), "name, set, pack")
		t.ok(
			has(music, { "surface1", "surface", "Minecraft (patched by ", "FixtureChorus)", "First Light" }),
			"and title"
		)

		local page = assert(ContentTool.show(view, "item.armor.equip_fixture_chorus"))
		t.ok(has(page, { "sound item.armor.equip_fixture_chorus", "pack FixtureChorus" }), page[1])
		t.ok(has(page, { "pitch = 1.7" }), "the merged fields")
		t.ok(has(page, { "named by:", "IronHelmet (put on)" }), "the entries naming it")
		t.ok(has(assert(ContentTool.show(view, "block.fixture_chorus.hum")), { "ElectricFurnace (working)" }))
		t.ok(has(assert(ContentTool.show(view, "block.fire.extinguish")), { "Fire (break)" }))
		local click = assert(ContentTool.show(view, "ui.button.click"))
		t.ok(has(click, { "patched by: ", "FixtureChorus" }) and has(click, { "volume = 0.8" }), "an override")
		local mood = assert(ContentTool.show(view, "ambient.cave.fixture_chorus_mood"))
		t.ok(
			has(mood, { "track fixture_chorus_mood: mood, pack FixtureChorus" }),
			"a cave mood's event shows its track"
		)
		t.ok(has(mood, { "event: ambient.cave.fixture_chorus_mood" }))
		local missing, near = ContentTool.show(view, "entity.fixture_chorus.sign")
		t.eq(missing, nil)
		t.eq((near :: any)[1], "entity.fixture_chorus.sing", "the nearest name")
	end)

	t.test("content tool: show gives every field whole and every way survival gets an item", function()
		local view = assert(fresh())
		-- (The plains' flowers are a long list: wrapped, an element a line, never cut.)
		local plains = assert(ContentTool.show(view, "Plains"))
		local joined = table.concat(plains, "\n")
		t.ok(not string.find(joined, " ...", 1, true), "nothing cut")
		t.ok(has(plains, { "foliage.flowers = {" }) and has(plains, { '"Sunflower"' }), "the last flower too")
		for _, line in plains do
			t.ok(#line <= ContentTool.WIDTH, line)
		end
		-- A string longer than a line stays whole on its own.
		local long = ContentTool.valueLines("    lore = ", string.rep("x", 200), "    ", "")
		t.eq(#long, 1)
		t.eq(#long[1], 11 + 202)
		-- Stick: breaking leaves, its recipe and a chest, every way of the Stone Age.
		local stick = table.concat(assert(ContentTool.show(view, "Stick")), " ")
		t.ok(
			string.find(stick, "survival: from the Stone Age: breaking ", 1, true)
				and string.find(stick, "OakLeaves", 1, true)
				and string.find(stick, "(shaped Stick x4)", 1, true),
			"its recipe among its ways"
		)
		local reach = ContentTool.reach(view)
		t.ok(#reach.ways.Stick >= 3 and string.match(reach.how.Stick, "^breaking %a+ %(") ~= nil, reach.how.Stick)
	end)

	t.test("content tool: a brewed potion item's lore and Age are its potion's to give", function()
		-- (A potion of the Speed effect brewed from Shears, the Iron Age's, its strong variant
		-- without a line.)
		local view = assert(fresh(function(env, packs)
			local folder = env.folder(packs, "FixturePotion")
			env.module(
				folder,
				"pack",
				{ order = GamePacks.orderAfter(env, packs, 900), requires = { "Core", "Minecraft", "Survival" } }
			)
			env.module(folder, "potions", {
				{
					name = "FixtureHaste",
					ingredient = "Shears",
					effect = "Speed",
					seconds = 30,
					strong = 10,
					lore = { base = "Brewed from shears." },
				},
			})
		end))
		local findings = ContentTool.check(view)
		local lore = finding(findings, "lore", "item StrongPotionOfFixtureHaste") :: any
		t.ok(
			lore and string.find(lore.text, 'lore = { strong = "..." } on potion FixtureHaste', 1, true),
			lore and lore.text
		)
		local age = finding(findings, "age", "item PotionOfFixtureHaste") :: any
		t.ok(
			age and string.find(age.text, 'age = { base = "iron" } on potion FixtureHaste, which brews it?', 1, true),
			age and age.text
		)
		t.eq(#of(findings, "FixturePotion"), 3, "and the strong one's Age")
	end)

	t.test("content tool: requires: a pack named but not required, or loading after", function()
		-- (FixtureEarly names FixtureLate's item, which loads after it, and Minecraft's Stick,
		-- requiring Core alone.)
		local view = assert(fresh(function(env, packs)
			local early = env.folder(packs, "FixtureEarly")
			local order = GamePacks.orderAfter(env, packs, 900)
			env.module(early, "pack", { order = order, requires = { "Core" } })
			env.module(early, "recipes", {
				{ type = "shapeless", ingredients = { "FixtureLateGem", "Stick" }, result = "FixtureLateGem" },
			})
			local late = env.folder(packs, "FixtureLate")
			env.module(late, "pack", { order = order + 1, requires = { "Core" } })
			env.module(late, "items", {
				{ name = "FixtureLateGem", model = { { size = { 1, 1, 1 }, offset = { 0, 0, 0 } } } },
			})
		end))
		local found: { string } = {}
		for _, each in ContentTool.check(view) do
			if each.check == "requires" and each.pack == "FixtureEarly" then
				table.insert(found, `{each.level}: {each.text}`)
			end
		end
		t.eq(#found, 2, table.concat(found, "; "))
		t.ok(
			has(found, {
				"warning: it names pack Minecraft's Stick (recipe #1 (FixtureLateGem))",
				'requires = { "Core", "Minecraft" }?',
			}),
			"an earlier pack's: a warning"
		)
		t.ok(
			has(found, {
				"info: it names pack FixtureLate's FixtureLateGem (recipe #1 (FixtureLateGem))",
				"FixtureLate loads after it",
			}),
			"a later pack's: an info"
		)
		-- What a module names, as its pack wrote it: an override names what it patches.
		local named: { string } = {}
		ContentTool.references(
			"blocks",
			{
				{ name = "Stone", override = true, drops = "Cobblestone", texture = { All = "stone" }, age = "iron" },
			},
			nil,
			function(space, name, where)
				table.insert(named, `{space} {name} ({where})`)
			end
		)
		table.sort(named)
		t.eq(
			table.concat(named, ", "),
			"age iron (block Stone), block Stone (block Stone), entry Cobblestone (block Stone), texture stone (block Stone)"
		)
		-- (A recipe's tag, a container's fill, a drink's purified twin and an explosive's lit block.)
		named = {}
		local function into(space: string, name: string, where: string)
			table.insert(named, `{space} {name} ({where})`)
		end
		ContentTool.references("recipes", {
			{ type = "shapeless", ingredients = { "#coals", "Stick" }, result = "Torch" },
		}, "recipes/lights", into)
		ContentTool.references("items", {
			{ name = "Jug", fills = "DirtyJug", drink = { purified = "CleanJug", effects = { { effect = "Speed" } } } },
		}, nil, into)
		ContentTool.references("blocks", { { name = "Charge", lit = "LitCharge" } }, nil, into)
		-- (Joining a tag names no pack: the Ores pack's ores join the Minecraft pack's "ores".)
		ContentTool.references("blocks", { { name = "TinOre", tags = { "ores" } } }, nil, into)
		ContentTool.references("tags", { ores = { "TinOre" } }, nil, into)
		table.sort(named)
		t.eq(
			table.concat(named, ", "),
			table.concat({
				"block LitCharge (block Charge)",
				"effect Speed (item Jug)",
				"entry CleanJug (item Jug)",
				"entry DirtyJug (item Jug)",
				"entry Stick (recipes/lights, recipe #1 (Torch))",
				"entry TinOre (tag ores)",
				"entry Torch (recipes/lights, recipe #1 (Torch))",
				"tag coals (recipes/lights, recipe #1 (Torch))",
			}, ", ")
		)
	end)

	--[[ A new pack ]]

	t.test("content tool: a new pack loads and passes the check as it is made", function()
		local view = assert(fresh())
		local order = ContentTool.nextOrder(view)
		for _, pack in view.packs do
			t.ok(order > pack.order, "after every pack")
		end
		t.eq(ContentTool.scaffoldProblem(view, "Scaffolded"), nil)
		local files = ContentTool.scaffold(view, "Scaffolded", order)
		local paths = {}
		for _, file in files do
			table.insert(paths, file.path)
			t.ok(string.sub(file.text, 1, 9) == "--!strict", `{file.path} is strict`)
			t.ok(not string.find(file.text, "$", 1, true), `{file.path}: every name filled in`)
		end
		t.eq(table.concat(paths, " "), "pack.luau blocks.luau items.luau recipes.luau textures.luau loot.luau")
		local after, problem = fresh(function(env, packs)
			local folder = env.folder(packs, "Scaffolded")
			for _, file in files do
				env.source(folder, string.sub(file.path, 1, -6), file.text)
			end
		end)
		t.ok(after, problem)
		local findings = ContentTool.check(after)
		t.eq(table.concat(of(findings, "Scaffolded"), ", "), "", "nothing against it")
		local content = after.content
		t.eq(content.packs[#content.packs].name, "Scaffolded", "last")
		local block = content.block("ScaffoldedBlock") :: any
		t.ok(block and block.texture.All == "scaffolded block" and block.loot == "scaffolded_block", "the block")
		local item = content.item("ScaffoldedCrystal") :: any
		t.ok(item and item.icon == "" and item.age == "iron" and item.lore, "the item")
		t.ok(content.textures["scaffolded block"] and content.loot.scaffolded_block, "its texture and loot table")
		local shaped, smelting = 0, 0
		for _, recipe in content.recipes do
			if recipe.result == "ScaffoldedBlock" and recipe.type == "shaped" then
				shaped += 1
			elseif recipe.result == "ScaffoldedCrystal" and recipe.type == "smelting" then
				smelting += 1
			end
		end
		t.eq(shaped, 1, "a shaped recipe")
		t.eq(smelting, 1, "a smelting recipe")
		-- A second new pack, made in the game with the first: its recipe takes another grid, and
		-- neither has anything against it.
		local second = ContentTool.scaffold(after, "Rescaffolded", ContentTool.nextOrder(after))
		local both, bothProblem = fresh(function(env, packs)
			for name, made in { Scaffolded = files, Rescaffolded = second } do
				local folder = env.folder(packs, name)
				for _, file in made do
					env.source(folder, string.sub(file.path, 1, -6), file.text)
				end
			end
		end)
		t.ok(both, bothProblem)
		local again = ContentTool.check(both)
		t.eq(table.concat(of(again, "Scaffolded"), ", "), "", "the first: nothing against it")
		t.eq(table.concat(of(again, "Rescaffolded"), ", "), "", "the second: nothing against it")
		-- Its header says where its order puts it, and every header line fits 100 columns.
		local function header(made: { { path: string, text: string } }): string
			return made[1].text
		end
		t.ok(string.find(header(files), `at {order}, after every other pack`, 1, true), "the order it took")
		local early = ContentTool.scaffold(view, "Early", 50)
		local earlyHeader = string.gsub(header(early), "\n\t", " ")
		t.ok(
			string.find(earlyHeader, "at 50, before Minecraft, Mekanism", 1, true)
				and not string.find(earlyHeader, "after every other pack", 1, true),
			earlyHeader
		)
		-- (Comments 100 columns, as the game's modules wrap them; code 120, StyLua's.)
		for _, made in { files, second, early } do
			for _, file in made do
				local inComment = false
				for line in string.gmatch(file.text, "[^\n]+") do
					inComment = inComment or string.sub(line, 1, 4) == "--[["
					local tabs = #(string.match(line, "^\t*") :: string)
					local comment = inComment or string.match(line, "^\t*%-%-") ~= nil
					t.ok(#line + tabs * 3 <= if comment then 100 else 120, `{file.path}: {line}`)
					inComment = inComment and line ~= "]]"
				end
			end
		end
		-- What `new` prints of them.
		t.eq(ContentTool.verdict({}), "it loads and passes the check")
		local one =
			{ pack = "P", level = "warning", check = "lore", subject = "item I", text = "x" } :: ContentTool.Finding
		t.eq(ContentTool.verdict({ one }), "1 finding", "one, not 1 findings")
		t.eq(ContentTool.verdict({ one, one }), "2 findings")
		-- (Camel case names spaced: the texture's words.)
		t.eq(ContentTool.scaffoldNames("DeepOres").texture, "deep ores block")
		t.eq(ContentTool.scaffoldNames("DeepOres").loot, "deep_ores_block")
	end)

	t.test("content tool: a new pack's name must be free", function()
		local view = assert(fresh())
		t.ok(string.find(ContentTool.scaffoldProblem(view, "Ores") or "", "already", 1, true), "a pack's")
		t.ok(string.find(ContentTool.scaffoldProblem(view, "Copper") or "", "CopperBlock", 1, true), "an entry's")
		t.ok(ContentTool.scaffoldProblem(view, "marble") ~= nil, "a capital first")
		t.ok(ContentTool.scaffoldProblem(view, "Marble2") ~= nil, "letters only (texture names are words)")
	end)
end
