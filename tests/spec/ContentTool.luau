--[[
	The content tool (tests/content; its workings tests/lib/ContentTool, its view of the game
	tests/lib/ContentGame): every check on the fixture packs in tests/fixtures/content/tool (Lint,
	one of each finding, and LintPatch, a JSON pack patching it), grafted into a fresh game after
	its own packs; the game's packs, which load and whose faces rule agrees with the TexturePack
	spec's; a load error, named; what each entry came from (the loader's record, content.origin:
	the fixture packs of tests/spec/Content, Gamma's overrides; a kind folder's recipes by their
	file); the lists and the pages; and a new pack's modules, which load and pass the check as
	they are made.

	Nothing here pins an id or a total: the game's content may grow.
]]

local Loader = require("../lib/Loader")
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
			env.graft(`{TOOL}/Lint`, packs, "Lint")
			env.graft(`{TOOL}/LintPatch`, packs, "LintPatch")
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
		-- (LintSecond's recipe is the Lint pack's fifth: recipes are named by their place in it.)
		local place = 5
		t.eq(
			table.concat(of(findings, "Lint"), ", "),
			table.concat({
				"age item LintLate",
				"faces block LintBare",
				"icon item LintNoIcon",
				"lore block LintBare",
				`recipe recipe #{place} (LintSecond)`,
				"survival block LintBare",
				"survival item LintLost",
				'texture texture "lint unused"',
			}, ", "),
			"Lint's findings"
		)
		t.eq(#of(findings, "LintPatch"), 0, "nothing against the patch")
		-- Levels: the reach is an info, the rest warnings.
		t.eq((finding(findings, "survival", "item LintLost") :: any).level, "info")
		t.eq((finding(findings, "lore", "block LintBare") :: any).level, "warning")
		-- What each says.
		local age = (finding(findings, "age", "item LintLate") :: any).text
		t.ok(string.find(age, "LintPart", 1, true) and string.find(age, 'age = "iron"', 1, true), age)
		t.ok(string.find(age, "Stone Age", 1, true) and string.find(age, "Iron Age", 1, true), age)
		local shadow = (finding(findings, "recipe", `recipe #{place} (LintSecond)`) :: any).text
		t.ok(
			string.find(shadow, "LintFirst", 1, true) and string.find(shadow, "pack Lint's recipe #4", 1, true),
			shadow
		)
		t.ok(string.find((finding(findings, "faces", "block LintBare") :: any).text, "texture", 1, true))
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

	t.test("content tool: survival's reach follows drops, recipes and Ages", function()
		local view = withLint()
		local reach = ContentTool.reach(view)
		t.eq(reach.age.LintClean, 1, "found in the world: its drop")
		t.ok(string.find(reach.how.LintClean, "breaking LintClean", 1, true), reach.how.LintClean)
		t.eq(reach.age.LintNoIcon, 1, "smelted from it")
		t.eq(reach.age.LintPart, 2, "its own Age")
		t.eq(reach.age.LintLate, 2, "its part's Age")
		t.eq(reach.age.LintLost, nil, "never")
		t.eq(reach.age.LintBare, nil)
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
		t.ok(
			has(lines, { "Lint", "order 900", "blocks 2", "items 6", "recipes 5", "textures 2", "ores 1" }),
			"Lint's summary"
		)
		t.ok(has(lines, { "LintPatch", "order 910", "blocks 0 (1 override)" }), "the patch's")
		t.ok(has(lines, { "warning", "pack Lint, block LintBare: no lore line" }), "a warning names its pack and entry")
		t.ok(has(lines, { "info", "pack Lint, item LintLost:" }), "an info")
		local counts = lines[#lines]
		t.ok(string.find(counts, "warnings (", 1, true) and string.find(counts, "1 never crafted", 1, true), counts)
		-- (The fixture's own: the game's packs carry no warnings.)
		local lint: { any } = {}
		for _, finding in findings do
			if finding.pack == "Lint" or finding.pack == "LintPatch" then
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
		end
		local summary = ContentTool.summary(view)
		t.eq(#summary, #view.packs, "a summary line per pack")
		t.ok(has(summary, { "Core", "order 0", "ages", "fuel" }), "Core's")
		-- (The creative tier's machines are no finding: no recipe makes the Creative Energy Cube,
		-- by design, as Mekanism's.)
		t.ok(view.creativeMachines.CreativeEnergyCube, "a machine of a creative kind")
		t.eq(finding(ContentTool.check(view), "survival", "block CreativeEnergyCube"), nil, "not out of reach")
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
		t.ok(has(assert(ContentTool.show(view, "Torch")), { `pack Minecraft, {name}:` }), "and on its page")
	end)

	--[[ Lists and pages ]]

	t.test("content tool: list by kind and pack; show an entry, its patches and what it became", function()
		local view = withLint()
		local blocks = assert(ContentTool.list(view, "blocks", "Lint"))
		t.eq(blocks[1], "blocks: 2")
		t.ok(has(blocks, { tostring(view.content.blockId.LintBare), "LintBare", "Lint" }), "id, name, pack")
		t.ok(has(blocks, { "LintClean", "Lint (patched by LintPatch)" }))
		t.ok(has(assert(ContentTool.list(view, "blocks", "LintPatch")), { "LintClean" }), "what a pack patched")
		local all = assert(ContentTool.list(view, nil, "Lint"))
		for _, head in { "blocks: 2", "items: 6", "recipes: 5", "textures: 2", "ores: 1", "loot: 0" } do
			t.ok(table.find(all, head) ~= nil, head)
		end
		t.ok(has(all, { "lint unused", "Lint", "blank" }), "a blank texture")
		local none, why = ContentTool.list(view, "blcoks")
		t.eq(none, nil)
		t.ok(why and string.find(why, "no kind blcoks", 1, true), why)
		t.eq((ContentTool.list(view, nil, "Nowhere")), nil, "an unknown pack")

		local page = assert(ContentTool.show(view, "LintClean"))
		t.ok(has(page, { "block LintClean", `id {view.content.blockId.LintClean}`, "pack Lint" }), page[1])
		t.ok(has(page, { "patched by: LintPatch" }))
		t.ok(has(page, { "hardness = 2" }), "the merged fields")
		t.ok(has(page, { "lore:", "A fixture block with nothing against it." }))
		t.ok(has(page, { "texture:", 'All = "lint clean"', "its own entry" }))
		t.ok(has(page, { "Age: Stone Age" }), "the default")
		t.ok(has(page, { "survival: from the Stone Age" }))
		t.ok(has(page, { "pack Lint, recipe #1: smelting LintClean -> LintNoIcon" }), "a recipe using it")
		local item = assert(ContentTool.show(view, "LintPart"))
		t.ok(has(item, { "icon:", "blank" }))
		t.ok(
			has(item, { "food:", "heals 2 (hunger off)", "nutrition 4", "saturation 0.25 (+2)", "held 32 ticks" }),
			"what eating it does (Items/Foods)"
		)
		t.ok(has(item, { "50% Hunger (Thirst with hunger off) for 100 ticks" }), "its risk")
		local drink = assert(ContentTool.show(view, "LintLate"))
		t.ok(
			has(
				drink,
				{ "drink:", "a potion", "thirst 3", "hydration 0.5 (+3)", "Speed II for 40 ticks", "leaves LintPart" }
			),
			"what drinking it does (ToughAsNails/Drinks)"
		)
		t.ok(has(item, { "Age: Iron Age" }))
		t.ok(has(item, { "made by:" }) and has(item, { "shapeless LintPart" }))
		local texture = assert(ContentTool.show(view, "lint clean"))
		t.ok(has(texture, { 'texture "lint clean"', "pack Lint" }) and has(texture, { "faces of: LintClean" }))
		local ore = assert(ContentTool.show(view, "lint_clean"))
		t.ok(has(ore, { "ore feature lint_clean", "pack Lint" }))
		local age = assert(ContentTool.show(view, "iron"))
		t.ok(has(age, { "Age iron", "Iron Age" }) and has(age, { "opens:" }) and has(age, { "LintPart" }))
		local missing, near = ContentTool.show(view, "LintClaen")
		t.eq(missing, nil)
		t.eq((near :: any)[1], "LintClean", "the nearest name")
	end)

	--[[ A new pack ]]

	t.test("content tool: a new pack loads and passes the check as it is made", function()
		local view = assert(fresh())
		local order = ContentTool.nextOrder(view)
		for _, pack in view.packs do
			t.ok(order > pack.order, "after every pack")
		end
		t.eq(ContentTool.scaffoldProblem(view, "Scaffolded"), nil)
		local files = ContentTool.scaffold("Scaffolded", order)
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
