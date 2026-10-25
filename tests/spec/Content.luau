--[[
	Content packs (Shared/Content, Content/Schema, Content/Define): the game's packs (Core, the
	feature packs, Ores last) and the ids they give; discovery of Luau and JSON packs through
	Content.load (the fixture packs in tests/fixtures/content/packs: Beta, JSON, order 10; Alpha,
	Luau, order 20, a "_" helper and Define's metal; Gamma, order 20 after Alpha by name,
	overriding both), their order, ids, overrides and merged tags; kind folders
	(tests/fixtures/content/folders: Delta, Luau, a folder inside a kind folder; Epsilon, JSON),
	their modules' order and the files every message names; every per-entry field reaching its
	registry (the Fields fixture pack grafted into a fresh game); and every check: the schema's
	(unknown fields with their "did you mean", wrong types, missing fields), names and overrides,
	manifests and `requires`, every cross-reference, discovery's, and a value both on an entry and
	in a registry's side table.

	Nothing here pins an id or a total: the game's content may grow.
]]

local Loader = require("../lib/Loader")

local PACKS = "tests/fixtures/content/packs"
local FOLDERS = "tests/fixtures/content/folders"
local FIELDS = "tests/fixtures/content/fields/Fields"

return function(t, shared, require, _server, _client)
	local Content = require(shared.Content)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local Config = require(shared.Config)

	-- Does `text` contain every one of `parts` (plain)?
	local function has(text: string, parts: { string }): boolean
		for _, part in parts do
			if not string.find(text, part, 1, true) then
				return false
			end
		end
		return true
	end

	-- The names of `list`'s entries, joined.
	local function names(list: { any }, field: string?): string
		local out = {}
		for _, entry in list do
			table.insert(out, entry[field or "name"])
		end
		return table.concat(out, " ")
	end

	-- A fresh game (shared and server modules), after `edit` has had its chance to add packs to
	-- Content/Packs: the environment and the two roots.
	local function fresh(edit: ((env: Loader.Environment, packs: Loader.Node) -> ())?): (Loader.Environment, any, any)
		local env = Loader.new()
		local root = env.mount("src/shared", "ReplicatedStorage", "IceVoxel")
		local serverRoot = env.mount("src/server", "ServerScriptService", "IceVoxel")
		if edit then
			edit(env, (root :: any).Content.Packs)
		end
		return env, root, serverRoot
	end

	-- The fixture packs, through Content.load (a fresh environment: their modules are its own).
	local function fixtures(): Content.Content
		local env, root = fresh()
		local packs = env.mount(PACKS, "ReplicatedStorage", "ContentFixtures")
		return env.require(root.Content).load(packs)
	end

	--[[ The game's packs ]]

	t.test("content: the game's packs load in order, Air and Cave Air first, the ores last", function()
		local content = Content.default
		local order = names(content.packs)
		-- (The feature packs, by their order: each comes after the one before it.)
		local last = 0
		for _, name in { "Core", "Minecraft", "Mekanism", "Survival", "Terraria", "Apocalypse", "Turrets", "Ores" } do
			local at = string.find(order, name, 1, true)
			t.ok(at ~= nil and at > last, `{name} after the packs before it: {order}`)
			last = at or last
		end
		t.ok(not string.find(order, "Base", 1, true), "no Base pack left")
		for index = 2, #content.packs do
			local a, b = content.packs[index - 1], content.packs[index]
			t.ok(a.order < b.order or (a.order == b.order and a.name < b.name), "sorted by order, then name")
		end
		t.eq(content.blocks[1].name, "Air")
		t.eq(content.blocks[2].name, "CaveAir")
		t.eq(content.blockId.Air, Blocks.AIR)
		t.eq(content.blockId.CaveAir, Blocks.CAVE_AIR)
		-- Dense ids by place, the registries' the same.
		t.eq(Blocks.count, #content.blocks)
		for index, spec in content.blocks do
			t.eq(content.blockId[spec.name], index - 1, `{spec.name}'s id is its place`)
			t.eq(Blocks.id[spec.name], index - 1)
		end
		for index, spec in content.items do
			t.eq(content.itemId[spec.name], Content.ITEM_BASE + index - 1, `{spec.name}'s id is its place`)
			t.eq(Items.id[spec.name], Content.ITEM_BASE + index - 1)
		end
		t.ok(Blocks.count < Items.ITEM_BASE, "fewer blocks than ITEM_BASE")
		t.eq(Items.ITEM_BASE, Content.ITEM_BASE)
		-- The Ores pack's after the Turrets pack's, the lists the registries keep the merged ones.
		t.ok(Blocks.id.CopperOre > Blocks.id.AmmoPress and Items.id.RawCopper > Items.id.LaserSight, "the ores last")
		t.eq(content.where("block", "UraniumOre"), "pack Ores, block UraniumOre")
		t.eq(content.where("item", "Stick"), "pack Minecraft, items/materials, item Stick", "a kind folder's file")
		t.eq(content.where("item", "HermesBoots"), "pack Terraria, item HermesBoots")
		t.eq(require(shared.Blocks.BlockList), content.blocks, "Blocks.BlockList")
		t.eq(require(shared.Items.ItemList), content.items, "Items.ItemList")
		t.eq(content.entry("UraniumOre"), content.block("UraniumOre"))
		t.eq(content.entry("Stick"), content.item("Stick"))
		t.eq(content.entry("NoSuchThing"), nil)
	end)

	t.test("content: the Ores pack carries its own fields, and the side tables no longer name it", function()
		local content = Content.default
		local ore = content.block("UraniumOre") :: any
		t.eq(ore.texture.All, "uranium ore", "its texture")
		t.ok(type(ore.lore) == "string", "its lore")
		t.eq(ore.miner.ticks, 3600, "the miner's numbers")
		t.eq(ore.radiation, 1, "its radiation")
		t.eq((content.item("UraniumIngot") :: any).age, "industrial", "its Age")
		t.eq((content.item("HazmatHelmet") :: any).shielding, 0.25)
		t.eq((content.block("LeadBlock") :: any).radiationShield, 0.02)
		t.eq(content.textures["uranium ore"].Color, "", "its textures are the pack's")
		t.eq(content.ores[#content.ores].name, "uranium_buried", "its ore features last")
		t.eq(content.where("ores", "copper"), "pack Ores, ore feature copper", "where: by kind")
		t.eq(content.where("ore feature", "copper"), "pack Ores, ore feature copper", "or by its word")
		t.eq(content.where("texture", "copper ore"), "pack Ores, texture copper ore")
		-- (The side tables keep the rest only.)
		t.eq((Config.Miner.Ores :: any).UraniumOre, nil, "not in Config.Miner.Ores")
		t.eq((Config.Radiation.Sources :: any).UraniumOre, nil, "not in Config.Radiation.Sources")
		t.eq((Config.Radiation.Hazmat :: any).HazmatHelmet, nil)
		-- Define.metal made its set: storage both ways and smelting.
		local Recipes = require(shared.Crafting.Recipes)
		local packs, unpacks, smelts = 0, 0, 0
		for _, recipe in Recipes.shaped do
			if recipe.result == "CopperBlock" and recipe.key["#"] == "CopperIngot" then
				packs += 1
			end
		end
		for _, recipe in Recipes.shapeless do
			if recipe.result == "CopperIngot" and recipe.ingredients[1] == "CopperBlock" and recipe.count == 9 then
				unpacks += 1
			end
		end
		for _, recipe in Recipes.smelting do
			if recipe.result == "CopperIngot" then
				smelts += 1
			end
		end
		t.eq(packs, 1, "nine ingots into a block")
		t.eq(unpacks, 1, "a block into nine ingots")
		t.eq(smelts, 2, "the ore and the raw lump smelt")
	end)

	t.test(
		"content: the Minecraft pack's items carry their own fields, and the side tables no longer name them",
		function()
			local content = Content.default
			local LoreList = require(shared.Items.LoreList)
			local TexturePack = require(shared.TexturePack)
			local Ages = require(shared.Progression.Ages)
			local Skills = require(shared.Progression.Skills)
			local Knowledge = require(shared.Progression.Knowledge)
			local Recipes = require(shared.Crafting.Recipes)
			local Sounds = require(shared.Sounds)
			local SoundList = require(shared.Sounds.SoundList)
			local PotionList = require(shared.Effects.PotionList)
			local function item(name: string): any
				return content.item(name)
			end
			-- Every item of the pack: its lore line and its icon (blank until made) on its entry.
			local seen = 0
			for _, spec in content.items do
				if string.find(content.where("item", spec.name), "pack Minecraft", 1, true) then
					seen += 1
					t.ok(type(spec.lore) == "string" and LoreList[spec.name] == spec.lore, `{spec.name}'s lore`)
					t.eq(spec.icon, "", `{spec.name}'s icon on its entry`)
					t.eq(TexturePack.Icons[spec.name], "", `{spec.name}: TexturePack.Icons`)
				end
			end
			t.ok(seen > 0, "the pack has items")
			-- The armor sets: each material's equip sound, lore and Age on all four pieces.
			local iron = Ages.byId("iron") :: any
			local industrial = Ages.byId("industrial") :: any
			for name, sound in
				{ LeatherBoots = "leather", ChainmailHelmet = "chain", IronHelmet = "iron", GoldLeggings = "gold" }
			do
				t.eq(item(name).equipSound, `item.armor.equip_{sound}`, `{name}'s equipSound`)
				t.eq(Sounds.armorEquip(Items.id[name]), Sounds.id[`item.armor.equip_{sound}`], `{name} sounds its own`)
			end
			t.eq(item("DiamondChestplate").age, "industrial")
			t.eq(Ages.ofName("GoldBoots"), iron.index, "gold armor: the Iron Age")
			t.eq(item("LeatherHelmet").age, nil, "leather: the first Age")
			t.eq(item("IronBoots").lore, "Solid iron protection.")
			-- The tool sets: each tool's lore, the tier's Age and the wooden ones' fuel.
			t.eq(item("WoodenPickaxe").fuel, 200)
			t.eq(Recipes.fuel.WoodenSword, 200, "-> Recipes.fuel")
			t.eq(item("StonePickaxe").fuel, nil, "only wood burns")
			t.eq(Ages.ofName("GoldenHoe"), iron.index)
			t.eq(Ages.ofName("DiamondAxe"), industrial.index)
			t.eq(item("IronPickaxe").lore, "Mines gold, diamond, emerald and uranium ore.", "a tool's own line")
			-- Hand-written entries: fuel, knowledge, Age and skill.
			t.eq(item("Coal").fuel, 1600)
			t.eq(Recipes.fuel.Stick, 100)
			t.eq(Knowledge.SMELTED.IronIngot, 0.7, "knowledge.smelt -> Knowledge.SMELTED")
			t.eq(Knowledge.SMELTED.CookedChicken, 0.35)
			t.eq(item("Gunpowder").skill, "demolition")
			t.eq((Skills.ofName("Gunpowder") :: any).id, "demolition", "-> the skill's recipes")
			t.eq(Ages.ofName("Gunpowder"), industrial.index)
			t.eq(Ages.ofName("Shears"), iron.index)
			-- Potions: a base potion the Iron Age's, its strong and long variants the Industrial Age's.
			for _, variant in PotionList.all() do
				local age = if variant.from == PotionList.BASE then iron else industrial
				t.eq(Ages.ofName(variant.item), age.index, `{variant.item}'s Age`)
				t.ok(type(item(variant.item).lore) == "string", `{variant.item}'s lore`)
			end
			t.eq(item("LongPotionOfSwiftness").lore, "Brewed longer with coal. Run faster.")
			-- (SoundList.ARMOR keeps only other packs' prefixes.)
			for _, row in SoundList.ARMOR do
				for _, material in { "Leather", "Chainmail", "Iron", "Gold", "Diamond" } do
					t.ok(row.prefix ~= material, `SoundList.ARMOR no longer names {material}`)
				end
			end
		end
	)

	t.test("content: a potion PotionList makes needs its line in the Minecraft pack, and a line its potion", function()
		-- (A fresh game, PotionList edited before the packs load.)
		local function loading(edit: (list: { any }) -> ()): string
			local env, root = fresh()
			edit(env.require(root.Effects.PotionList).list)
			local ok, err = pcall(env.require, root.Content)
			return if ok then "(it loaded)" else tostring(err)
		end
		local added = loading(function(list)
			table.insert(list, { name = "Testing", ingredient = "Stick", effect = "Speed", seconds = 10 })
		end)
		t.ok(has(added, { "PotionOfTesting has no lore line and icon in the Minecraft pack's items/potions" }), added)
		local removed = loading(function(list)
			table.remove(list)
		end)
		-- (Resistance's two lines are left: either one may be named first.)
		t.ok(
			has(removed, { "items/potions has a line for", "PotionOfResistance, which PotionList makes no potion of" }),
			removed
		)
	end)

	--[[ Discovery, order, ids, overrides, tags (the fixture packs) ]]

	t.test("content: Luau and JSON packs are found, sorted by order then name; ids by place", function()
		local content = fixtures()
		t.eq(names(content.packs), "Beta Alpha Gamma", "order 10, then order 20 by name")
		t.eq(content.packs[1].description, "The JSON fixture pack (tests/spec/Content): every kind as a .json file.")
		t.eq(table.concat(content.packs[2].requires, ","), "Beta")
		t.eq(
			names(content.blocks),
			"BetaStone BetaOre AlphaStone FixiumOre FixiumBlock RawFixiumBlock GammaGlass",
			"blocks in load order, each pack's in its order"
		)
		for index, spec in content.blocks do
			t.eq(content.blockId[spec.name], index - 1)
		end
		t.eq(names(content.items), "BetaGem RawFixium FixiumIngot FixiumNugget AlphaWand")
		t.eq(content.itemId.BetaGem, Content.ITEM_BASE)
		t.eq(content.itemId.AlphaWand, Content.ITEM_BASE + 4)
		-- JSON decoded as Rojo does: lists, tables, numbers, false.
		local ore = content.block("BetaOre") :: any
		t.eq(ore.miner.ticks, 500)
		t.eq(ore.color[3], 200)
		t.eq(ore.texture.Top, "beta ore top")
		t.eq(content.loot.beta_chest[1].entries[2][1], false, "false in a loot entry")
		t.eq(content.ages[1].id, "beta_age")
		t.eq(content.lore.BetaGem, "A gem of the JSON pack.")
		t.eq(
			names(content.recipes, "type"),
			"smelting shapeless shaped shapeless shaped shapeless shaped shapeless smelting smelting shaped"
		)
		t.eq(content.recipes[1].result, "BetaGem", "Beta's recipes first")
		t.eq(content.recipes[#content.recipes].result, "AlphaWand", "Alpha's last")
		-- The function-form modules got Define and Config.
		t.eq(names(content.ores), "beta fixium")
		t.eq(content.ores[2].maxY, Config.SeaLevel, "Config through define")
		-- Define.metal's set.
		local fixium = content.block("FixiumOre") :: any
		t.eq(fixium.drops, "RawFixium")
		t.eq(fixium.toolLevel, 1)
		t.eq(fixium.texture.All, "fixium ore")
		t.eq(fixium.lore, "Gives Raw Fixium.", "the spec's own fields")
		t.eq((content.block("FixiumBlock") :: any).displayName, "Block of Fixium")
		t.eq((content.item("FixiumIngot") :: any).age, "beta_age")
		t.eq(content.textures["raw fixium block"].Material, "Rock")
		t.eq(content.textures["alpha stone"].Tint, "AlphaStone")
		t.eq(content.where("block", "BetaOre"), "pack Beta, block BetaOre")
		t.eq(content.where("texture", "alpha stone"), "pack Alpha, texture alpha stone")
	end)

	t.test("content: an override patches an earlier pack's entry, field by field", function()
		local content = fixtures()
		local stone = content.block("AlphaStone") :: any
		t.eq(stone.hardness, 4, "patched")
		t.eq(stone.lore, "Patched by Gamma.")
		t.eq(stone.material, "Rock", "the rest kept")
		t.eq(stone.texture.All, "alpha stone")
		t.eq(stone.override, nil, "no override field left")
		t.eq(content.blockId.AlphaStone, 2, "its place kept")
		t.eq(content.where("block", "AlphaStone"), "pack Alpha (patched by Gamma), block AlphaStone")
		local gem = content.item("BetaGem") :: any
		t.eq(gem.displayName, "Beta Jewel")
		t.eq(gem.model[1].size[1], 4, "its model kept")
		t.eq(content.itemId.BetaGem, Content.ITEM_BASE)
		local texture = content.textures["beta stone"]
		t.eq(texture.Color, "rbxassetid://7", "a texture patched")
		t.eq(texture.Material, "Slate")
		t.eq(texture.override, nil)
	end)

	t.test("content: tags are a union of every pack's lists and the entries' own, each name once", function()
		local content = fixtures()
		t.eq(table.concat(content.tags.fixture_stones, " "), "BetaStone AlphaStone GammaGlass")
		t.eq(table.concat(content.tags.fixture_metals, " "), "FixiumIngot BetaGem")
	end)

	--[[ Kind folders (the fixture packs in tests/fixtures/content/folders) ]]

	-- The kind folder fixture packs (Delta, Luau, order 10; Epsilon, JSON, order 20), through
	-- Content.load in a fresh environment.
	local function folderFixtures(): Content.Content
		local env, root = fresh()
		local packs = env.mount(FOLDERS, "ReplicatedStorage", "ContentFolders")
		return env.require(root.Content).load(packs)
	end

	t.test("content: kind folders merge their modules in name order, folders in place, Luau and JSON", function()
		local content = folderFixtures()
		t.eq(names(content.packs), "Delta Epsilon")
		t.eq(
			names(content.blocks),
			"DeltaFlower DeltaGrass DeltaStone DeltaBrick DeltaZebra EpsilonOne EpsilonTwo",
			"blocks/plants (flower, grass), blocks/stone, blocks/zebra, then Epsilon's one and two"
		)
		for index, spec in content.blocks do
			t.eq(content.blockId[spec.name], index - 1, "ids by place")
		end
		t.eq(names(content.items), "DeltaGem")
		t.eq(names(content.recipes, "type"), "smelting shaped shapeless shapeless", "a_smelting, b_gems, Epsilon's")
		t.eq(content.recipes[#content.recipes].count, 3, "the JSON pack's recipe last")
		t.eq(table.concat(content.tags.delta, " "), "DeltaStone DeltaBrick", "tags/a's and tags/b's, joined")
		t.eq(content.textures["delta stone"].Material, "Slate", "textures from two files")
		t.eq(content.textures["delta flower"].Tint, false)
		t.eq(content.loot.epsilon_chest[1].entries[2][1], false, "loot from two JSON files")
		t.eq(content.loot.epsilon_crate[1].entries[1][1], "EpsilonOne")
		t.eq((content.block("DeltaFlower") :: any).color[1], 200, "a function module got define")
		t.eq((content.block("DeltaStone") :: any).color[3], 120, "and the pack's helper at its top")
		t.eq(content.where("block", "DeltaFlower"), "pack Delta, blocks/plants/flower, block DeltaFlower")
		t.eq(content.where("block", "EpsilonTwo"), "pack Epsilon, blocks/two, block EpsilonTwo")
		t.eq(content.where("loot table", "epsilon_crate"), "pack Epsilon, loot/crate, loot table epsilon_crate")
		t.eq(content.where("texture", "delta stone"), "pack Delta, textures/ground, texture delta stone")
	end)

	--[[ Every per-entry field reaching its registry (the Fields pack in a fresh game) ]]

	t.test("content: every per-entry field reaches its registry", function()
		local env, root, serverRoot = fresh(function(env, packs)
			env.graft(FIELDS, packs, "Fields")
		end)
		local function need(path: { string }, from: any?): any
			local node = from or root
			for _, name in path do
				node = node[name]
			end
			return env.require(node)
		end
		local FreshBlocks = need({ "Blocks" })
		local FreshItems = need({ "Items" })
		local B, I = FreshBlocks.id, FreshItems.id
		local content = need({ "Content" }).default
		t.eq(content.packs[#content.packs].name, "Fields", "grafted last")
		t.eq(B.FixtureOre, FreshBlocks.count - 2, "its blocks after every other")
		-- Textures and icons.
		local TexturePack = need({ "TexturePack" })
		t.eq(TexturePack.Blocks.FixtureOre.All, "fixture ore", "texture -> TexturePack.Blocks")
		t.eq(FreshBlocks.get(B.FixtureOre).textures.north, "fixture ore", "and the block's faces")
		t.eq(FreshBlocks.get(B.FixtureFrost).textures.top, "fixture frost")
		t.eq(FreshBlocks.get(B.FixtureFrost).textures.west, "fixture ore")
		t.eq(TexturePack.Icons.FixtureGem, "rbxassetid://12345", "icon -> TexturePack.Icons")
		t.eq(FreshItems.icon(I.FixtureGem), "rbxassetid://12345")
		-- Lore: entries' and the pack's `lore`.
		local LoreList = need({ "Items", "LoreList" })
		t.eq(LoreList.FixtureOre, "Every block field there is.")
		t.eq(LoreList.FixtureGem, "Every item field there is.")
		t.eq(LoreList.FixtureHelmet, "Lore from a pack's lore module.")
		t.eq(need({ "Items", "Tooltip" }).lore(I.FixtureGem), "Every item field there is.")
		-- Ages and skills.
		local Ages = need({ "Progression", "Ages" })
		local Skills = need({ "Progression", "Skills" })
		t.eq(Ages.ofName("FixtureGem"), Ages.byId("iron").index, "age")
		t.eq(Ages.ofName("FixtureOre"), Ages.byId("industrial").index)
		t.ok(table.find(Ages.byId("iron").recipes, "FixtureGem") ~= nil, "in the Age's recipes")
		t.eq(Skills.ofName("FixtureGem").id, "demolition", "skill")
		t.eq(Skills.ofName("FixtureOre").id, "scholar")
		local Progression = need({ "Progression" })
		t.ok(not Progression.allows(Progression.new(), I.FixtureGem), "gated")
		-- Knowledge.
		local Knowledge = need({ "Progression", "Knowledge" })
		t.eq(Knowledge.ORES.FixtureOre, 4, "knowledge.mine")
		t.eq(Knowledge.SMELTED.FixtureOre, 0.3, "knowledge.smelt on a block")
		t.eq(Knowledge.SMELTED.FixtureGem, 2, "and an item")
		-- The Metal Miner, after every other ore.
		local MinerRules = need({ "Machines", "MinerRules" })
		local ore = MinerRules.ore(B.FixtureOre)
		t.ok(ore ~= nil, "miner")
		t.eq(ore.index, #MinerRules.ORES, "the last ore")
		t.eq(ore.ticks, 500)
		t.eq(ore.joules, 300)
		t.eq(ore.floor, 1000)
		t.eq(ore.drop, I.FixtureGem)
		-- Radiation.
		local Radiation = need({ "Radiation" })
		t.eq(Radiation.strength(B.FixtureOre), 0.5, "radiation, a block")
		t.eq(Radiation.strength(I.FixtureGem), 0.2, "and an item")
		t.eq(Radiation.TRANSMISSION[B.FixtureOre], 0.3, "radiationShield")
		t.eq(Radiation.SHIELDING[I.FixtureHelmet], 0.5, "shielding")
		t.eq(Radiation.shielding({ FreshItems.newStack(I.FixtureHelmet, 1) }), 0.5)
		-- Recipes, tags and fuel.
		local Recipes = need({ "Crafting", "Recipes" })
		t.eq(
			table.concat(Recipes.tags.fixture_tag, " "),
			"Stone FixtureOre FixtureGem",
			"the tag: its list, then entries'"
		)
		t.ok(table.find(Recipes.tags.coals, "FixtureGem") ~= nil, "an entry joins Core's tag")
		local Crafting = need({ "Crafting" })
		local gem = { item = I.FixtureGem, count = 1 }
		local made = Crafting.match({ gem, gem, nil, gem, gem }, 3)
		t.eq(made and made.item, B.FixtureOre, "a shaped recipe")
		local helmet = Crafting.match({ gem, { item = B.Stone, count = 1 } }, 3)
		t.eq(helmet and helmet.item, I.FixtureHelmet, "a shapeless one, through the tag")
		local Smelting = need({ "Crafting", "Smelting" })
		local smelted = Smelting.result(B.FixtureOre)
		t.ok(smelted and smelted.item == I.FixtureGem and smelted.count == 2, "smelting")
		t.eq(Smelting.fuel(I.FixtureGem), 120, "fuel, an item")
		t.eq(Smelting.fuel(B.FixtureOre), 50, "and a block")
		-- Ore features and loot tables.
		local Ores = need({ "Generation", "Ores" })
		local feature = Ores.FEATURES[#Ores.FEATURES]
		t.eq(feature.name, "fixture", "ores")
		t.eq(feature.block, B.FixtureOre)
		local ScavengeLoot = need({ "Generation", "ScavengeLoot" })
		local found = 0
		for i = 1, 40 do
			for _, item in ScavengeLoot.roll("fixture_loot", 99, i, 0, -i) do
				t.eq(item.item, "FixtureGem", "loot")
				t.ok(item.count >= 1 and item.count <= 3)
				found += 1
			end
		end
		t.ok(found > 0 and found < 40, `the gem one time in four ({found} of 40)`)
		-- A block's loot (Items.lootDrop): the table's or its own pools.
		local function rolls(values: { number }): () -> number
			local i = 0
			return function(): number
				i += 1
				return values[i] or 0.99
			end
		end
		t.ok(FreshItems.hasLoot(B.FixtureOre) and FreshItems.hasLoot(B.FixtureFrost), "loot")
		t.ok(not FreshItems.hasLoot(B.Stone))
		local drop = FreshItems.lootDrop(B.FixtureOre, rolls({ 0.1, 0.9 }))
		t.ok(drop and drop.item == I.FixtureGem and drop.count == 3, "its table: the gem, 1 + 2")
		t.eq(FreshItems.lootDrop(B.FixtureOre, rolls({ 0.5 })), nil, "nothing rolled: the usual drop")
		local snow = FreshItems.lootDrop(B.FixtureFrost, rolls({ 0.2 }))
		t.ok(snow and snow.item == I.Snowball and snow.count == 2, "inline pools")
		local fallen = FreshItems.leafDrop(B.FixtureFrost, rolls({ 0.2 }))
		t.ok(fallen and fallen.item == I.Snowball, "and when it drops by itself")
		local EditRules = need({ "Network", "EditRules" }, serverRoot)
		t.eq(EditRules.drops(B.FixtureOre, false, nil), nil, "no loot without a tool that harvests it")
		local snowballs, frost = 0, 0
		for _ = 1, 200 do
			local stack = EditRules.drops(B.FixtureFrost, false, nil)
			if stack and stack.item == I.Snowball then
				snowballs += 1
			elseif stack and stack.item == B.FixtureFrost then
				frost += 1
			end
		end
		t.ok(snowballs > 0 and frost > 0 and snowballs + frost == 200, "broken by hand: its loot or itself")
		for _ = 1, 20 do
			local stack = EditRules.drops(B.FixtureFrost, false, I.Shears)
			t.eq(stack and stack.item, B.FixtureFrost, "with Shears: never its loot")
		end
		-- Sounds.
		local Sounds = need({ "Sounds" })
		t.eq(Sounds.block(B.FixtureOre, "break"), Sounds.id["block.fire.extinguish"], "sounds")
		t.eq(Sounds.block(B.FixtureOre, "step"), Sounds.id["block.glass.step"])
		t.eq(Sounds.block(B.FixtureOre, "place"), Sounds.block(B.Stone, "place"), "the rest its sound type's")
		t.eq(Sounds.armorEquip(I.FixtureHelmet), Sounds.id["item.armor.equip_gold"], "equipSound")
		-- Tough As Nails.
		local Temperature = need({ "ToughAsNails", "Temperature" })
		t.ok(table.find(Temperature.HEATING_BLOCKS, "FixtureOre") ~= nil, "heats")
		t.ok(table.find(Temperature.COOLING_BLOCKS, "FixtureFrost") ~= nil, "cools")
		local Climate = need({ "Players", "Climate" }, serverRoot)
		t.ok(Climate.isHeating(B.FixtureOre) and Climate.isCooling(B.FixtureFrost), "the climate's sources")
	end)

	--[[ Checks: Content.build ]]

	local MODEL = { { size = { 1, 1, 1 }, offset = { 0, 0, 0 } } }
	-- A pack's data for Content.build (order 10 unless the manifest says).
	local function pack(name: string, kinds: { [string]: any }, manifest: any?): Content.PackData
		return { name = name, manifest = manifest or { order = 10 }, kinds = kinds }
	end
	-- What building `packs` fails with ("(it loaded)" when it does not).
	local function failure(packs: { Content.PackData }): string
		local ok, err = pcall(Content.build, packs)
		return if ok then "(it loaded)" else tostring(err)
	end
	local function fails(packs: { Content.PackData }, parts: { string }, what: string)
		local message = failure(packs)
		t.ok(has(message, parts), `{what}: {message}`)
	end

	t.test("content: the schema's checks: unknown fields, wrong types, missing fields", function()
		fails(
			{ pack("P", { blocks = { { name = "A", harndess = 2 } } }) },
			{ "pack P, block A: harndess is no field it may have (did you mean hardness?)" },
			"a typo"
		)
		fails(
			{ pack("P", { blocks = { { name = "A", hardness = "2" } } }) },
			{ 'pack P, block A: hardness must be a number, not the string "2"' },
			"a wrong type"
		)
		fails(
			{ pack("P", { blocks = { { name = "A", color = { 1, 2, 300 } } } }) },
			{ "pack P, block A: color[3] must be a number 0..255, not 300" },
			"inside a colour"
		)
		fails(
			{ pack("P", { blocks = { { name = "A", miner = { ticks = 1, joules = 1, flor = 2 } } } }) },
			{ "pack P, block A: miner.flor is no field it may have (did you mean floor?)" },
			"inside a field"
		)
		fails(
			{ pack("P", { blocks = { { name = "A", render = "Shiny" } } }) },
			{ "render must be one of Opaque, Transparent, Fluid, None" },
			"an enum"
		)
		fails({ pack("P", { blocks = { { hardness = 1 } } }) }, { "pack P, block #1: name is missing" }, "no name")
		fails({ pack("P", { items = { { name = "I" } } }) }, { "pack P, item I: model is missing" }, "no model")
		fails(
			{ pack("P", { items = { { name = "I", model = MODEL, icon = 7 } } }) },
			{ "pack P, item I: icon must be a string, not 7" },
			"an icon"
		)
		fails(
			{ pack("P", { items = { { name = "I", model = MODEL, miner = { ticks = 1, joules = 1 } } } }) },
			{ "pack P, item I: miner is no field it may have" },
			"a block's field on an item"
		)
		fails(
			{ pack("P", { loot = { chest = { { rolls = { 1, 1 }, entries = { { "A", 0, 1, 1 } } } } } }) },
			{ "pack P, loot table chest: it[1].entries[1][2] must be a weight above 0" },
			"a loot entry"
		)
		fails(
			{ pack("P", { recipes = { { type = "baked", result = "A" } } }) },
			{ "pack P, recipe #1 (A): type must be one of shaped, shapeless, smelting" },
			"a recipe type"
		)
		fails(
			{ pack("P", { recipes = { { type = "smelting", result = "A" } } }) },
			{ "pack P, recipe #1 (A): input is missing" },
			"a recipe's field"
		)
		fails(
			{ pack("P", { recipes = { { type = "shapeless", ingredients = { "A" }, input = "A", result = "A" } } }) },
			{ "input is no field a shapeless recipe has" },
			"a field of another type"
		)
		fails(
			{ pack("P", { textures = { t = { Color = "" } } }) },
			{ "pack P, texture t: Material is missing" },
			"a texture"
		)
		fails(
			{ pack("P", { ages = { { id = "a", name = "A", level = 0, milestones = {}, reward = 0 } } }) },
			{ "pack P, Age a: color is missing" },
			"an Age"
		)
	end)

	t.test("content: packs: manifests, names, order, requires, kinds", function()
		fails({ pack("P", {}, {}) }, { "pack P: its manifest.order is missing" }, "no order")
		fails({ pack("P", {}, { order = "1" }) }, { "pack P: its manifest.order must be a number" }, "a bad order")
		fails({ pack("P", {}, { order = 1, colour = 2 }) }, { "pack P: its manifest.colour is no field" }, "a typo")
		fails({ pack("P", {}), pack("P", {}) }, { "two packs are named P" }, "a name twice")
		fails(
			{ pack("P", {}, { order = 1, requires = { "Nope" } }) },
			{ "pack P requires pack Nope, which is not there" },
			"requires nothing"
		)
		fails(
			{ pack("P1", {}, { order = 10, requires = { "P2" } }), pack("P2", {}, { order = 20 }) },
			{ "pack P1 requires pack P2, which loads after it" },
			"requires a later pack"
		)
		fails(
			{ pack("P", { block = {} }) },
			{ "pack P has a module block, which is no kind (did you mean blocks?)" },
			"a kind's name"
		)
		fails(
			{ pack("P", { blocks = { A = { name = "A" } } }) },
			{ "pack P's blocks must be a list of entries" },
			"a list kind"
		)
		fails({ pack("P", { tags = { "x" } }) }, { "pack P's tags must be a table of names" }, "a named kind")
		-- (The same order: the names decide.)
		fails(
			{ pack("B", {}, { order = 5 }), pack("A", {}, { order = 5, requires = { "B" } }) },
			{ "pack A requires pack B, which loads after it (give it a lower order)" },
			"the same order, a later name"
		)
		t.ok(
			pcall(Content.build, { pack("A", {}, { order = 5 }), pack("B", {}, { order = 5, requires = { "A" } }) }),
			"the same order, an earlier name"
		)
	end)

	t.test("content: names: taken twice, by a block and an item, overrides of nothing", function()
		fails(
			{ pack("P1", { blocks = { { name = "A" } } }), pack("P2", { blocks = { { name = "A" } } }, { order = 20 }) },
			{ "pack P2, block A: the name is taken by pack P1, block A" },
			"a block twice"
		)
		fails({
			pack("P1", { blocks = { { name = "A" } } }),
			pack("P2", { items = { { name = "A", model = MODEL } } }, { order = 20 }),
		}, { "pack P2, item A: the name is taken by pack P1, block A" }, "a block's name for an item")
		fails(
			{ pack("P", { blocks = { { name = "A" }, { name = "A" } } }) },
			{ "pack P, block A: the name is taken by pack P, block A" },
			"twice in a pack"
		)
		fails(
			{ pack("P", { blocks = { { name = "Z", override = true } } }) },
			{ "pack P, block Z overrides a block no earlier pack makes" },
			"an override of nothing"
		)
		fails(
			{
				pack("P1", { items = { { name = "A", model = MODEL } } }),
				pack("P2", { blocks = { { name = "A", override = true } } }, { order = 20 }),
			},
			{ "pack P2, block A overrides a block no earlier pack makes (pack P1, item A has the name)" },
			"an override of the wrong kind"
		)
		fails(
			{ pack("P", { textures = { t = { override = true, Color = "" } } }) },
			{ "pack P, texture t overrides a texture no earlier pack makes" },
			"a texture override of nothing"
		)
		local texture = { Color = "", Material = "Rock" }
		fails(
			{ pack("P1", { textures = { t = texture } }), pack("P2", { textures = { t = texture } }, { order = 20 }) },
			{ "pack P2, texture t: pack P1 has one by that name already" },
			"a texture twice"
		)
		fails({
			pack("P1", { lore = { A = "x" }, blocks = { { name = "A" } } }),
			pack("P2", { lore = { A = "y" } }, { order = 20 }),
		}, { "pack P2, lore A: pack P1 has one by that name already" }, "lore twice")
		local feature = { name = "o", block = "A", veins = 1, size = 1, minY = 1, maxY = 2 }
		fails(
			{ pack("P", { blocks = { { name = "A" } }, ores = { feature, feature } }) },
			{ "pack P, ore feature o: pack P has one by that name" },
			"an ore feature twice"
		)
		local age = { id = "a", name = "A", level = 0, milestones = {}, reward = 0, color = { 1, 1, 1 } }
		fails(
			{ pack("P", { ages = { age, age } }) },
			{ "pack P, Age a: pack P has an Age with that id" },
			"an Age twice"
		)
		local many = {}
		for i = 1, Content.ITEM_BASE do
			many[i] = { name = `B{i}` }
		end
		fails({ pack("P", { blocks = many }) }, { "block ids must stay under ITEM_BASE" }, "too many blocks")
	end)

	t.test("content: every cross-reference is checked, naming the pack and the entry", function()
		local A = { name = "Stone" }
		local function with(kinds: { [string]: any }): { Content.PackData }
			local all = table.clone(kinds)
			all.blocks = all.blocks or { A }
			return { pack("P", all) }
		end
		fails(
			with({ blocks = { { name = "A", drops = "Ghost" } } }),
			{ "pack P, block A: drops names unknown item Ghost" },
			"drops"
		)
		fails(
			with({ blocks = { { name = "A", shearDrops = "Ghost" } } }),
			{ "shearDrops names unknown item Ghost" },
			"shearDrops"
		)
		fails(with({ blocks = { { name = "A", item = "Ghost" } } }), { "item names unknown item Ghost" }, "item")
		fails(
			with({ blocks = { { name = "A", caveTwin = "Ghost" } } }),
			{ "caveTwin names unknown block Ghost" },
			"caveTwin"
		)
		fails(
			with({ blocks = { { name = "A", plant = { top = "Ghost" } } } }),
			{ "plant top names unknown block Ghost" },
			"a plant"
		)
		fails(
			with({ blocks = { { name = "A", toggle = { to = "Ghost" } } } }),
			{ "toggle names unknown block Ghost" },
			"a toggle"
		)
		fails(
			with({ blocks = { { name = "A", texture = { All = "nope" } } } }),
			{ 'pack P, block A: texture All names unknown texture "nope"' },
			"a texture"
		)
		fails(
			with({ blocks = { { name = "A", loot = "nope" } } }),
			{ "pack P, block A: loot names unknown loot table nope" },
			"a loot table"
		)
		fails(
			with({ blocks = { { name = "A", loot = { { rolls = { 1, 1 }, entries = { { "Ghost", 1, 1, 1 } } } } } } }),
			{ "pack P, block A: pool 1, entry 1 names unknown item Ghost" },
			"inline loot"
		)
		fails(
			with({ blocks = { { name = "A", age = "bronze" } } }),
			{ "pack P, block A: age names unknown Age bronze" },
			"an Age"
		)
		fails(
			with({ items = { { name = "I", model = MODEL, places = "Ghost" } } }),
			{ "pack P, item I: places names unknown block Ghost" },
			"places"
		)
		fails(
			with({ recipes = { { type = "smelting", input = "Stone", result = "Ghost" } } }),
			{ "pack P, recipe #1 (Ghost): result names unknown item Ghost" },
			"a result"
		)
		fails(
			with({ recipes = { { type = "shapeless", ingredients = { "#nope" }, result = "Stone" } } }),
			{ "pack P, recipe #1 (Stone): ingredients names unknown tag #nope" },
			"a tag"
		)
		fails(
			with({ recipes = { { type = "shaped", pattern = { "X" }, key = { X = "Stnoe" }, result = "Stone" } } }),
			{ "key X names unknown item Stnoe (did you mean Stone?)" },
			"a key, with a hint"
		)
		fails(
			with({ recipes = { { type = "smelting", input = "Ghost", result = "Stone" } } }),
			{ "input names unknown item Ghost" },
			"an input"
		)
		fails(with({ tags = { t = { "Ghost" } } }), { "pack P: tag t names unknown item Ghost" }, "a tag's member")
		fails(
			with({
				blocks = { { name = "A", tags = { "t" } }, { name = "B", tags = { "t" } } },
				tags = { t = { "A", "Ghost" } },
			}),
			{ "pack P: tag t names unknown item Ghost" },
			"a tag's member, with entries' too"
		)
		fails(
			with({ loot = { chest = { { rolls = { 1, 1 }, entries = { { "Ghost", 1, 1, 1 } } } } } }),
			{ "pack P, loot table chest: pool 1, entry 1 names unknown item Ghost" },
			"a loot table"
		)
		fails(
			with({ ores = { { name = "o", block = "Ghost", veins = 1, size = 1, minY = 1, maxY = 2 } } }),
			{ "pack P, ore feature o: block names unknown block Ghost" },
			"an ore feature"
		)
		fails(
			with({
				ages = {
					{
						id = "a",
						name = "A",
						level = 0,
						reward = 0,
						color = { 1, 1, 1 },
						milestones = { { category = "craft", key = "Ghost", text = "x" } },
					},
				},
			}),
			{ "pack P, Age a: milestone craft names unknown item Ghost" },
			"a milestone"
		)
		fails(
			with({ textures = { t = { Color = "", Material = "Rock", Tint = "Ghost" } } }),
			{ "pack P, texture t: Tint names unknown block Ghost" },
			"a tint"
		)
		fails(with({ lore = { Ghost = "x" } }), { "pack P, lore Ghost: lore names unknown item Ghost" }, "lore")
		fails(
			with({ blocks = { { name = "A", lore = "x" } }, lore = { A = "y" } }),
			{ "pack P, block A: its lore is pack P's lore too" },
			"lore twice for one item"
		)
		t.ok(
			pcall(Content.build, with({ recipes = { { type = "smelting", input = "Stone", result = "Stone" } } })),
			"a good pack loads"
		)
	end)

	t.test("content: kind folders: every message names the file", function()
		-- A pack whose kinds are kind folders: `folders` is { [kind] = { { file, data } } }.
		local function filed(name: string, folders: { [string]: any }, kinds: { [string]: any }?): Content.PackData
			return { name = name, manifest = { order = 10 }, kinds = kinds or {}, folders = folders }
		end
		local function file(path: string, data: any): Content.PackFile
			return { file = path, data = data }
		end
		local stone = file("blocks/stone", { { name = "Stone" } })
		fails(
			{ filed("P", { blocks = { file("blocks/plants", { { name = "Poppy", harndess = 1 } }) } }) },
			{ "pack P, blocks/plants, block Poppy: harndess is no field it may have (did you mean hardness?)" },
			"an entry's field"
		)
		fails(
			{ filed("P", { blocks = { stone, file("blocks/plants", { Poppy = {} }) } }) },
			{ "pack P, blocks/plants must be a list of entries" },
			"a list kind's file"
		)
		fails(
			{ filed("P", { tags = { file("tags/a", { "Stone" }) } }) },
			{ "pack P, tags/a must be a table of names" },
			"a named kind's file"
		)
		fails(
			{ filed("P", { blocks = { stone, file("blocks/more", { { name = "Stone" } }) } }) },
			{ "pack P, blocks/more, block Stone: the name is taken by pack P, blocks/stone, block Stone" },
			"a name in two files"
		)
		local texture = { Color = "", Material = "Rock" }
		fails(
			{ filed("P", { textures = { file("textures/a", { t = texture }), file("textures/b", { t = texture }) } }) },
			{ "pack P, textures/b, texture t: pack P, textures/a has one by that name already" },
			"a texture in two files"
		)
		fails({
			filed("P", {
				blocks = { stone },
				recipes = {
					file("recipes/tools", {
						{ type = "smelting", input = "Stone", result = "Stone" },
						{ type = "shaped", pattern = { "X" }, key = { X = "Stnoe" }, result = "Stone" },
					}),
				},
			}),
		}, { "pack P, recipes/tools, recipe #2 (Stone): key X names unknown item Stnoe" }, "a recipe")
		fails(
			{ filed("P", { blocks = { stone, file("blocks/ore", { { name = "Ore", drops = "Ghost" } }) } }) },
			{ "pack P, blocks/ore, block Ore: drops names unknown item Ghost" },
			"a cross-reference"
		)
		fails(
			{ filed("P", { blocks = { stone }, tags = { file("tags/a", { t = { "Ghost" } }) } }) },
			{ "pack P, tags/a: tag t names unknown item Ghost" },
			"a tag's member"
		)
		fails(
			{ filed("P", { blocks = { stone } }, { blocks = {} }) },
			{ "pack P has its blocks both as a module and as a folder" },
			"a kind both ways"
		)
		fails(
			{ filed("P", { block = { stone } }) },
			{ "pack P has a folder block, which is no kind (did you mean blocks?)" },
			"a folder's name"
		)
		-- Discovery: what Content.load finds in a pack's folders.
		local env, root = fresh()
		local Fresh = env.require(root.Content)
		local made = 0
		local function load(build: (pack: Loader.Node) -> ()): string
			made += 1
			local packs = env.folder(root, `Folders{made}`)
			local p = env.folder(packs, "P")
			env.module(p, "pack", { order = 1 })
			build(p)
			local ok, err = pcall(Fresh.load, packs)
			return if ok then "(it loaded)" else tostring(err)
		end
		local message = load(function(p)
			env.module(env.folder(p, "blocks"), "_shapes", {})
		end)
		t.ok(has(message, { "pack P has blocks/_shapes: a helper goes at the pack's top" }), message)
		message = load(function(p)
			env.folder(p, "bloks")
		end)
		t.ok(has(message, { "pack P has a folder bloks, which is no kind (did you mean blocks?)" }), message)
		message = load(function(p)
			local blocks = env.folder(p, "blocks")
			env.module(env.folder(blocks, "deep"), "stone", { { name = "Stone", harndess = 1 } })
		end)
		t.ok(has(message, { "pack P, blocks/deep/stone, block Stone: harndess is no field" }), message)
		message = load(function(p)
			local blocks = env.folder(p, "blocks")
			env.module(blocks, "b", { { name = "B" } })
			env.module(blocks, "a", { { name = "A" } })
			env.folder(blocks, "empty")
		end)
		t.eq(message, "(it loaded)", "modules and an empty folder")
	end)

	--[[ Checks: discovery (Content.load) ]]

	t.test("content: discovery: a pack needs its manifest, modules are kinds or `_` helpers", function()
		local env, root = fresh()
		local Fresh = env.require(root.Content)
		local made = 0
		-- What loading the packs `build` makes in a new folder fails with.
		local function folder(build: (packs: Loader.Node) -> ()): string
			made += 1
			local packs = env.folder(root, `Packs{made}`)
			build(packs)
			local ok, err = pcall(Fresh.load, packs)
			return if ok then "(it loaded)" else tostring(err)
		end
		local message = folder(function(packs)
			env.module(env.folder(packs, "P"), "blocks", {})
		end)
		t.ok(has(message, { "pack P has no manifest (a module named pack)" }), message)
		message = folder(function(packs)
			local p = env.folder(packs, "P")
			env.module(p, "pack", { order = 1 })
			env.module(p, "block", {})
		end)
		t.ok(has(message, { "pack P has a module block, which is no kind (did you mean blocks?)" }), message)
		message = folder(function(packs)
			env.module(packs, "Stray", {})
		end)
		t.ok(has(message, { "/Stray is no pack folder" }), message)
		message = folder(function(packs)
			local p = env.folder(packs, "P")
			env.module(p, "pack", function(define)
				return { order = 1, description = `Config is {type(define.Config)}` }
			end)
			env.module(p, "_helper", "anything")
			env.module(p, "blocks", function(define)
				return { { name = "A", color = define.shade({ 100, 100, 100 }, 2) } }
			end)
		end)
		t.eq(message, "(it loaded)", "a function manifest, a helper and a function kind")
	end)

	--[[ Checks: a value both on an entry and in a registry's side table ]]

	-- Requiring `path` in a fresh game with a pack Clash (`kinds`) fails with `parts`.
	local function clash(kinds: { [string]: any }, path: { string }, parts: { string }, before: ((any, any) -> ())?)
		local env, root = fresh(function(env, packs)
			local folder = env.folder(packs, "Clash")
			env.module(folder, "pack", { order = 900, requires = { "Minecraft", "Terraria" } })
			for kind, value in kinds do
				env.module(folder, kind, value)
			end
		end)
		if before then
			before(env, root)
		end
		local node = root
		for _, name in path do
			node = node[name]
		end
		local ok, err = pcall(env.require, node)
		local message = if ok then "(it loaded)" else tostring(err)
		t.ok(has(message, parts), `{table.concat(path, ".")}: {message}`)
	end
	local STONE = "pack Minecraft (patched by Clash), blocks/terrain, block Stone"

	t.test("content: a value both on an entry and in a registry's side table is an error", function()
		-- (The Minecraft pack's blocks carry their own lore, faces, Ages, skills, knowledge, miner
		-- numbers and loot now, and those side tables are their modules' own, so no clash of a
		-- Minecraft block with them can be set up here: Stone's lore and texture, TNT's skill,
		-- Coal Ore's knowledge, Iron Ore's miner numbers and Gravel's loot were the examples. The
		-- side tables, and their checks, go once every pack's entries carry their values.)
		-- (An item LEGACY_ICONS still names: one with an icon its entry doesn't give. It was the
		-- Hermes Boots until the Terraria pack's items carried their own icons; the packs move
		-- theirs onto their entries, so the side table empties, and the check goes with it.)
		local TexturePack = require(shared.TexturePack)
		local legacy: string? = nil
		for _, spec in Content.default.items do
			if spec.icon == nil and TexturePack.Icons[spec.name] ~= nil then
				legacy = spec.name
				break
			end
		end
		if legacy then
			clash({ items = { { name = legacy, override = true, icon = "" } } }, { "TexturePack" }, {
				"TexturePack: pack ",
				"(patched by Clash)",
				`item {legacy} has its icon both on its entry and in LEGACY_ICONS`,
			})
		end
		clash(
			{ blocks = { { name = "Stone", override = true, skill = "juggling" } } },
			{ "Progression", "Skills" },
			{ `Skills: {STONE} names an unknown skill juggling` }
		)
		clash(
			{ blocks = { { name = "Stone", override = true, radiation = 2 } } },
			{ "Radiation" },
			{ `Radiation: {STONE} has its radiation, and Config.Radiation.Sources too` },
			function(env, root)
				env.require(root.Config).Radiation.Sources.Stone = 1
			end
		)
		-- (Fire's own sounds are on its entry: a side table naming it too, as a pack's old data.)
		clash({}, { "Sounds" }, {
			"Sounds: pack Minecraft, blocks/fire, block Fire has its sounds, and SoundList.BLOCK_SOUNDS too",
		}, function(env, root)
			env.require(root.Sounds.SoundList).BLOCK_SOUNDS.Fire = { ["break"] = "block.fire.extinguish" }
		end)
		clash(
			{ blocks = { { name = "Stone", override = true, sounds = { ["break"] = "block.stone.shatter" } } } },
			{ "Sounds" },
			{ `Sounds: {STONE}'s break plays unknown event block.stone.shatter` }
		)
		clash(
			{ blocks = { { name = "Stone", override = true, sounds = { smash = "block.stone.break" } } } },
			{ "Sounds" },
			{ `Sounds: {STONE} has unknown action smash` }
		)
		-- (SoundList.ARMOR names no prefix any more: every armor piece names its own `equipSound`.)
		-- (Ice cools on its entry: Config naming it too.)
		clash({}, { "ToughAsNails", "Temperature" }, {
			"Temperature: pack Minecraft, blocks/terrain, block Ice cools, and Config.ToughAsNails.CoolingBlocks too",
		}, function(env, root)
			table.insert(env.require(root.Config).ToughAsNails.CoolingBlocks, "Ice")
		end)
		clash({ blocks = { { name = "Planks", override = true, fuel = 300 } } }, { "Crafting", "Recipes" }, {
			"Recipes: pack Minecraft (patched by Clash), blocks/wood, block Planks has its fuel both on its entry and in LEGACY_FUEL (#planks)",
		})
	end)
end
