--[[
	Content packs (Shared/Content, Content/Schema, Content/Define): the game's packs (Core, the
	feature packs, Ores last) and the ids they give; discovery of Luau and JSON packs through
	Content.load (the fixture packs in tests/fixtures/content/packs: Beta, JSON, order 10; Alpha,
	Luau, order 20, a "_" helper and Define's metal; Gamma, order 20 after Alpha by name,
	overriding both), their order, ids, overrides, merged tags and structures (templates, pools
	and structures: a pool's and a structure's overrides); kind folders
	(tests/fixtures/content/folders: Delta, Luau, a folder inside a kind folder; Epsilon, JSON),
	their modules' order and the files every message names; every per-entry field reaching its
	registry (the Fields fixture pack grafted into a fresh game); where each thing came from
	(`origin`); biomes: the game's (the Minecraft pack's, the Survival pack's herbs patched in), the
	fixture packs' (Beta's in JSON, Gamma's override patching it field by field) and a pack's biome
	and override reaching Biomes, Locate and the generator (tests/fixtures/content/biomes/Wilds
	grafted into a fresh game); effects and potions: the game's, by pack, and a pack's own status
	effect and potion (the Brewing fixture pack, grafted the same way: the potion's items, recipes,
	lore, drink and tooltip from its entry alone, and a patched effect and potion of the Minecraft
	pack's); the skill tree's nodes (the `skills` kind: the game's in their features' packs, Beta's
	in JSON, and the Skilled fixture pack's node, which needs Demolition and gates a recipe, and
	override, grafted the same way); and every check: the schema's (unknown fields with their "did
	you mean", wrong types, missing fields, an effect's icon and view the client has, a skill's perk
	and its numbers), names and overrides, manifests and `requires`, every cross-reference (a
	potion's effect, ingredient and variants, a skill's Age, icon, prerequisites and cell),
	discovery's, the registries' own checks on the entries' values (Effects' names among them, the
	skill tree's rows, icons and perks), and the biome registries' (bands, tree builders, a band
	without biomes, a biome code needs).

	Nothing here pins an id or a total: the game's content may grow.
]]

local Loader = require("../lib/Loader")

local PACKS = "tests/fixtures/content/packs"
local FOLDERS = "tests/fixtures/content/folders"
local FIELDS = "tests/fixtures/content/fields/Fields"
local BIOMES = "tests/fixtures/content/biomes/Wilds"
local BREWING = "tests/fixtures/content/brewing/Brewing"
local SKILLS = "tests/fixtures/content/skills/Skilled"

return function(t, shared, require, _server, _client)
	local Content = require(shared.Content)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local Config = require(shared.Config)
	local TemplateText = require(shared.Structures.TemplateText)

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

	t.test("content: the Ores pack carries its own fields", function()
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

	t.test("content: the Minecraft pack's items carry their own fields", function()
		local content = Content.default
		local LoreList = require(shared.Items.LoreList)
		local TexturePack = require(shared.TexturePack)
		local Ages = require(shared.Progression.Ages)
		local Skills = require(shared.Progression.Skills)
		local Knowledge = require(shared.Progression.Knowledge)
		local Recipes = require(shared.Crafting.Recipes)
		local Sounds = require(shared.Sounds)
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
	end)

	-- (The potions were PotionList's, their lines the Minecraft pack's items/potions table, which
	-- the old test here kept in step; a potion is the `potions` kind now and carries its own lines,
	-- and a line for a variant it has not fails the load: the cross-reference checks below.)
	t.test("content: the Minecraft pack's effects and potions are its own; the others' in their packs", function()
		local content = Content.default
		local Effects = require(shared.Effects)
		local PotionList = require(shared.Effects.PotionList)
		for name, pack in
			{
				Speed = "Minecraft",
				Glowing = "Minecraft",
				Hunger = "Minecraft",
				OilCoated = "Mekanism",
				FuelSoaked = "Mekanism",
				Thirst = "Survival",
				ClimateClemency = "Survival",
				ManaSickness = "Terraria",
				Bleeding = "Apocalypse",
				Infection = "Apocalypse",
				RadiationSickness = "Ores",
			}
		do
			t.eq(content.where("effect", name), `pack {pack}, effect {name}`, `{name} is the {pack} pack's`)
		end
		-- Ids by place, the registry's the same.
		t.eq(Effects.COUNT, #content.effects)
		for index, spec in content.effects do
			t.eq(content.effectId[spec.name], index, `{spec.name}'s id is its place`)
			t.eq(Effects.id[spec.name], index)
		end
		t.ok(#content.effects <= Content.MAX_EFFECTS, "ids fit a u8")
		t.eq(PotionList.list, content.potions, "PotionList.list")
		t.eq(content.where("potion", "Swiftness"), "pack Minecraft, potion Swiftness")
		-- Each potion's items are brewed after the pack's own items, their recipes after its recipes.
		t.ok(Items.id.PotionOfSwiftness > Items.id.Stick, "after the pack's own items")
		t.eq(
			content.where("item", "LongPotionOfSwiftness"),
			"pack Minecraft, potion Swiftness, item LongPotionOfSwiftness",
			"an item names its potion"
		)
		local Recipes = require(shared.Crafting.Recipes)
		local brewed = 0
		for _, recipe in Recipes.shapeless do
			if recipe.result == "StrongPotionOfSwiftness" then
				brewed += 1
				t.eq(table.concat(recipe.ingredients, " "), "PotionOfSwiftness GlowDust")
			end
		end
		t.eq(brewed, 1, "a recipe a variant")
	end)

	t.test("content: a pack's own effect and potion: items, recipes, lore and tooltip from its entry alone", function()
		local env, root = fresh(function(env, packs)
			env.graft(BREWING, packs, "Brewing")
		end)
		local function need(path: { string }): any
			local node = root
			for _, name in path do
				node = node[name]
			end
			return env.require(node)
		end
		local FreshEffects = need({ "Effects" })
		local FreshItems = need({ "Items" })
		local PotionList = need({ "Effects", "PotionList" })
		local LoreList = need({ "Items", "LoreList" })
		local TexturePack = need({ "TexturePack" })
		local Ages = need({ "Progression", "Ages" })
		local Crafting = need({ "Crafting" })
		local Drinks = need({ "ToughAsNails", "Drinks" })
		local Tooltip = need({ "Items", "Tooltip" })
		local content = need({ "Content" }).default
		local E, I = FreshEffects.id, FreshItems.id
		-- The effect: the last id, its own fields, /effect finds it.
		t.eq(E.Luck, FreshEffects.COUNT, "after every other pack's effects")
		local luck = FreshEffects.get(E.Luck)
		t.eq(luck.colorValue, 51 * 65536 + 153 * 256, "Minecraft's LUCK colour")
		t.ok(luck.beneficial and luck.icon == "star")
		t.eq(FreshEffects.find("minecraft:luck"), E.Luck, "/effect give @s luck")
		t.eq(content.where("effect", "Luck"), "pack Brewing, effect Luck")
		-- Speed patched: its place kept, the colour its potions' liquid takes.
		t.eq(E.Speed, require(shared.Effects).id.Speed, "its id kept")
		t.eq(FreshEffects.get(E.Speed).color[1], 10, "patched")
		t.eq(FreshEffects.get(E.Speed).command, "speed", "the rest kept")
		t.eq(FreshItems.get(I.PotionOfSwiftness).color[1], 10, "a potion takes its effect's colour, patched")
		t.eq(content.where("effect", "Speed"), "pack Minecraft (patched by Brewing), effect Speed")
		-- The potion's items, after the pack's own: the base potion and the long one (no strong).
		t.ok(I.PotionOfLuck == I.FourLeafClover + 1 and I.LongPotionOfLuck == I.PotionOfLuck + 1, "after its own")
		t.eq(FreshItems.find("StrongPotionOfLuck"), nil, "no strong variant")
		t.eq(FreshItems.get(I.LongPotionOfLuck).displayName, "Long Potion of Luck")
		t.eq(FreshItems.get(I.PotionOfLuck).maxStack, 1)
		t.eq(FreshItems.get(I.PotionOfLuck).color[2], 153, "its effect's colour")
		t.eq(content.where("item", "PotionOfLuck"), "pack Brewing, potion Luck, item PotionOfLuck")
		-- Each item's lore line, icon and Age, from the potion's.
		t.eq(LoreList.PotionOfLuck, "Brewed from an emerald. Feel lucky.")
		t.eq(LoreList.LongPotionOfLuck, "Brewed longer with coal. Feel lucky for longer.")
		t.eq(TexturePack.Icons.PotionOfLuck, "rbxassetid://777", "its icon")
		t.eq(TexturePack.Icons.LongPotionOfLuck, "", "blank where it gives none")
		t.eq(Ages.ofName("PotionOfLuck"), Ages.byId("iron").index)
		t.eq(Ages.ofName("LongPotionOfLuck"), Ages.byId("industrial").index)
		-- Its recipes: a Purified Water Bottle with the ingredient, the potion with a coal.
		local made = Crafting.match({
			[1] = { item = I.PurifiedWaterBottle, count = 1 },
			[2] = { item = I.Emerald, count = 1 },
		}, 2)
		t.eq(made and made.item, I.PotionOfLuck, "brewed")
		local long =
			Crafting.match({ [1] = { item = I.PotionOfLuck, count = 1 }, [2] = { item = I.Charcoal, count = 1 } }, 2)
		t.eq(long and long.item, I.LongPotionOfLuck, "lengthened")
		-- Drinking it, and its tooltip.
		local given = Drinks.of(I.PotionOfLuck).effects[1]
		t.ok(given.effect == E.Luck and given.ticks == 6000 and given.amplifier == 0, "5:00 of Luck I")
		t.eq(Drinks.entry(I.PotionOfLuck).empty, I.GlassBottle, "the bottle back")
		local tip = Tooltip.texts(I.PotionOfLuck)
		t.ok(table.find(tip, "Luck (5:00)") ~= nil, "the tooltip's effect line")
		t.ok(table.find(tip, "Brewed from an emerald. Feel lucky.") ~= nil, "and its lore")
		-- Swiftness patched: 4:00, its new line; the Minecraft pack's own data untouched.
		t.eq(Drinks.of(I.PotionOfSwiftness).effects[1].ticks, 4800, "patched: 4:00")
		t.eq(Drinks.of(I.StrongPotionOfSwiftness).effects[1].ticks, 1800, "its II kept")
		t.eq(LoreList.PotionOfSwiftness, "Patched by Brewing. Run faster for longer.")
		t.eq(content.where("potion", "Swiftness"), "pack Minecraft (patched by Brewing), potion Swiftness")
		t.eq(PotionList.list[#PotionList.list].name, "Luck", "the potions in load order")
		t.eq(require(shared.Content).default.potions[1].seconds, 180, "the game's own Swiftness unpatched")
		-- Where each came from, as data (`origin`): the effects and potions, their overrides, and a
		-- brewed item's and recipe's potion.
		local function origin(kind: string, name: any): string
			local from = content.origin(kind, name)
			if from == nil then
				return "nil"
			end
			local index = if from.index then ` #{from.index}` else ""
			return `{from.pack} {from.file or "-"}{index} [{table.concat(from.patched, ",")}]`
		end
		t.eq(origin("effect", "Luck"), "Brewing - []", "an effect's")
		t.eq(origin("effects", "Speed"), "Minecraft - [Brewing]", "an effect patched")
		t.eq(origin("potion", "Luck"), "Brewing - []", "a potion's")
		t.eq(origin("potion", "Swiftness"), "Minecraft - [Brewing]", "a potion patched")
		t.eq(origin("item", "LongPotionOfLuck"), "Brewing potion Luck []", "a brewed item: its potion's")
		t.eq(origin("item", "PotionOfSwiftness"), "Minecraft potion Swiftness []")
		local brewedAt: number? = nil
		for index, recipe in content.recipes do
			if recipe.result == "LongPotionOfLuck" then
				brewedAt = index
			end
		end
		t.eq(origin("recipe", brewedAt), "Brewing potion Luck #2 []", "a brewed recipe: its potion's, its place")
		t.eq(origin("effect", "Nothing"), "nil")
	end)

	t.test("content: the game's biomes are the Minecraft pack's, in order; the Survival pack adds herbs", function()
		local content = Content.default
		local Biomes = require(shared.Biomes)
		t.ok(#content.biomes > 0, "biomes")
		t.eq(Biomes.count, #content.biomes, "the registry has every one")
		for index, spec in content.biomes do
			t.eq(Biomes.get(index).name, spec.name, `{spec.name}: its index is its place`)
			t.eq(Biomes.byName(spec.name), Biomes.get(index))
			t.eq(content.biome(spec.name), spec)
			t.ok(string.find(content.where("biome", spec.name), "pack Minecraft", 1, true) ~= nil, spec.name)
		end
		t.eq(content.biome("Atlantis"), nil)
		-- (The order the generator's arrays and climate picks follow: the Minecraft pack's list.
		-- tests/spec/Generation and WorldTypeGenerators pin what it generates.)
		local function before(a: string, b: string)
			local x, y = Biomes.byName(a), Biomes.byName(b)
			t.ok(x and y and x.index < y.index, `{a} before {b}`)
		end
		before("Tundra", "Taiga")
		before("Plains", "Forest")
		before("FrozenPeaks", "MushroomFields")
		-- Herbs: the Survival pack's overrides, the rest of the foliage the Minecraft pack's.
		t.eq(content.where("biome", "Taiga"), "pack Minecraft (patched by Survival), biome Taiga")
		local taiga = content.biome("Taiga") :: any
		t.eq(taiga.foliage.herbs.species[1][1], "WildGinger")
		t.eq(taiga.foliage.plants[1][1], "Fern", "the taiga's own plants kept")
		t.eq((content.biome("Plains") :: any).foliage.herbs.species[1][1], "Mint")
		t.eq((content.biome("Desert") :: any).foliage.herbs, nil, "no herbs in the desert")
		local plains = Biomes.byName("Plains") :: any
		t.eq(plains.foliage.herbs.blocks[1], Blocks.id.Mint, "-> Biomes")
		t.eq(plains.foliage.herbChance, 0.004)
		-- Tags: the entries' own.
		t.ok(table.find(taiga.tags, "is_taiga") ~= nil, "Minecraft's biome tags on the entries")
		t.eq(#(Biomes.byName("MushroomFields") :: any).bands, 0, "the islands are no band's")
		-- (The structure library names biomes too, and Structures/Library warns of one no pack makes.)
		local unknown = {}
		require(shared.Structures.Library).load({
			warn = function(text: string)
				if string.find(text, "unknown biome", 1, true) then
					table.insert(unknown, text)
				end
			end,
		})
		t.eq(table.concat(unknown, "; "), "", "the library's structures name the packs' biomes")
	end)

	--[[ Discovery, order, ids, overrides, tags (the fixture packs) ]]

	t.test("content: Luau and JSON packs are found, sorted by order then name; ids by place", function()
		local content = fixtures()
		t.eq(names(content.packs), "Beta Alpha Gamma", "order 10, then order 20 by name")
		t.eq(
			content.packs[1].description,
			"The JSON fixture pack (tests/spec/Content): every kind as a .json file but potions (brewed from the game's bottles: the Brewing pack)."
		)
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
		local scouting = content.skills[1]
		t.eq(scouting.id, "beta_scouting", "a skill")
		t.eq(scouting.perk.sources[1], "discovery", "its perk's list")
		t.eq(content.where("skill", "beta_scouting"), "pack Beta, skill beta_scouting")
		t.eq(content.lore.BetaGem, "A gem of the JSON pack.")
		t.eq(names(content.effects), "BetaGlow AlphaHaste", "effects in load order")
		t.eq(content.effectId.BetaGlow, 1, "effect ids from 1, by place")
		t.eq(content.effectId.AlphaHaste, 2)
		t.eq(content.effects[1].color[2], 220, "an effect from JSON")
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
		local glow = content.effects[content.effectId.BetaGlow] :: any
		t.eq(glow.displayName, "Beta Shine", "an effect patched")
		t.eq(glow.view, "glowing", "the rest kept")
		t.eq(glow.override, nil)
		t.eq(content.effectId.BetaGlow, 1, "its place kept")
		t.eq(content.where("effect", "BetaGlow"), "pack Beta (patched by Gamma), effect BetaGlow")
	end)

	t.test("content: tags are a union of every pack's lists and the entries' own, each name once", function()
		local content = fixtures()
		t.eq(table.concat(content.tags.fixture_stones, " "), "BetaStone AlphaStone GammaGlass")
		t.eq(table.concat(content.tags.fixture_metals, " "), "FixiumIngot BetaGem")
	end)

	t.test("content: biomes by name: a JSON pack's, patched field by field, its lists replaced", function()
		local content = fixtures()
		t.eq(names(content.biomes), "BetaDunes GammaGlade", "in load order")
		local dunes = content.biome("BetaDunes") :: any
		t.eq(dunes.weather.temperature, 1.5, "patched")
		t.eq(dunes.weather.precipitation, false, "the rest of its weather kept")
		t.eq(dunes.top, "BetaStone", "and the rest of it")
		t.eq(#dunes.features, 1)
		t.eq(dunes.features[1][1], "OakTree", "a list replaced whole")
		t.eq(table.concat(dunes.tags, " "), "is_fixture is_patched")
		t.eq(dunes.override, nil, "no override field left")
		t.eq(content.where("biome", "BetaDunes"), "pack Beta (patched by Gamma), biome BetaDunes")
		local origin = content.origin("biome", "BetaDunes") :: any
		t.ok(
			origin.pack == "Beta" and origin.file == nil and table.concat(origin.patched, ",") == "Gamma",
			"its origin: the maker and the override"
		)
		t.eq((content.origin("biomes", "GammaGlade") :: any).pack, "Gamma")
		t.eq(content.origin("biome", "Atlantis"), nil)
		t.eq((content.biome("GammaGlade") :: any).patches.block, "GammaGlass")
		t.eq(content.where("biomes", "GammaGlade"), "pack Gamma, biome GammaGlade")
		-- (Not in the item tags.)
		t.eq(content.tags.is_fixture, nil)
	end)

	t.test("content: templates by name; pools and structures too, an override patching fields", function()
		local content = fixtures()
		local templates = {}
		for name in content.templates do
			table.insert(templates, name)
		end
		table.sort(templates)
		t.eq(table.concat(templates, " "), "alpha/huts/hut alpha/huts/shed beta/well gamma/hut")
		t.eq(string.sub(content.templates["beta/well"], 1, 5), "IVS1:", "a JSON pack's text")
		t.eq(content.where("template", "beta/well"), "pack Beta, template beta/well")
		-- Gamma's override: its elements replace Alpha's whole, the rest of the pool is kept.
		local huts = content.pools["alpha/huts"] :: any
		t.eq(#huts.elements, 3, "the elements replaced whole")
		t.eq(huts.elements[3].template, "gamma/hut")
		t.eq(huts.elements[3].weight, 2)
		t.eq(huts.projection, "terrain_matching", "the projection kept")
		t.eq(huts.override, nil, "no override field left")
		t.eq(content.where("pool", "alpha/huts"), "pack Alpha (patched by Gamma), pool alpha/huts")
		local wells = content.pools["beta/wells"] :: any
		t.eq(wells.elements[2].empty, true, "JSON: the empty element")
		t.eq(wells.fallback, "minecraft:empty")
		-- Structures in load order, Gamma's override patching Alpha's.
		t.eq(names(content.structures), "beta_well alpha_village")
		local village = content.structures[2] :: any
		t.eq(village.spacing, 50, "patched")
		t.eq(table.concat(village.biomes, ","), "GammaGlade", "a list replaced whole")
		t.eq(village.size, 2, "the rest kept")
		t.eq(village.startPool, "alpha/huts")
		t.eq(village.override, nil)
		t.eq(content.where("structure", "alpha_village"), "pack Alpha (patched by Gamma), structure alpha_village")
		t.eq((content.structures[1] :: any).onLand, false, "JSON: false")
		-- Their origins: the maker, its file and the packs that patched it, overrides too.
		local function origin(kind: string, name: string): string
			local found = content.origin(kind, name) :: any
			if found == nil then
				return "none"
			end
			return `{found.pack} {found.file or "-"} {table.concat(found.patched, ",")}`
		end
		t.eq(origin("template", "beta/well"), "Beta - ", "a JSON pack's template")
		t.eq(origin("templates", "gamma/hut"), "Gamma - ")
		t.eq(origin("pool", "alpha/huts"), "Alpha - Gamma", "a pool and its override")
		t.eq(origin("pools", "beta/wells"), "Beta - ")
		t.eq(origin("structure", "alpha_village"), "Alpha - Gamma", "a structure and its override")
		t.eq(origin("structure", "beta_well"), "Beta - ")
		t.eq(origin("structure", "nowhere"), "none")
		t.eq(origin("pool", "alpha"), "none", "an implicit pool is no entry")
		-- A kind folder's file: the game's outpost.
		local outpost = Content.default.origin("template", "outpost/houses/hut") :: any
		t.eq(outpost.pack, "Minecraft")
		t.eq(outpost.file, "templates/outpost", "a kind folder's file")
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

	t.test("content: origin: the pack that made each thing, the packs that patched it, a recipe's place", function()
		local content = fixtures()
		local function says(origin: Content.Origin?): string
			if origin == nil then
				return "nil"
			end
			local text = `{origin.pack} [{table.concat(origin.patched, " ")}]`
			text ..= if origin.file then ` {origin.file}` else ""
			return text .. if origin.index then ` #{origin.index}` else ""
		end
		t.eq(says(content.origin("block", "AlphaStone")), "Alpha [Gamma]", "made, then patched")
		t.eq(says(content.origin("blocks", "GammaGlass")), "Gamma []", "by kind or by its word")
		t.eq(says(content.origin("item", "BetaGem")), "Beta [Gamma]")
		t.eq(says(content.origin("texture", "beta stone")), "Beta [Gamma]", "a texture's override")
		-- (Beta, order 10, first; then Alpha's.)
		t.eq(says(content.origin("recipe", 1)), "Beta [] #1", "a recipe: its place in its pack")
		t.eq(says(content.origin("recipe", 3)), "Alpha [] #1")
		t.eq(
			says(content.origin("tag", "fixture_stones")),
			"Beta [Alpha Gamma]",
			"a tag: its first pack, the packs adding to it (a module's or an entry's tags) in load order"
		)
		t.eq(content.origin("block", "Nothing"), nil)
		t.eq(content.origin("recipe", #content.recipes + 1), nil)
		t.eq(content.origin("spell", "AlphaStone"), nil, "no such kind")
		local origin = content.origin("block", "AlphaStone") :: Content.Origin
		table.insert(origin.patched, "Mine")
		t.eq(says(content.origin("block", "AlphaStone")), "Alpha [Gamma]", "a copy each time")
		-- A kind folder's file.
		local folders = folderFixtures()
		t.eq(says(folders.origin("block", "DeltaFlower")), "Delta [] blocks/plants/flower")
		t.eq(says(folders.origin("recipe", 3)), "Delta [] recipes/b_gems #2", "its place in its file")
		t.eq(says(folders.origin("tag", "delta")), "Delta [] tags/a", "the file its first names came from")
		t.eq(says(folders.origin("loot table", "epsilon_crate")), "Epsilon [] loot/crate")
		-- The game's: Core's fuel tags.
		t.eq(says(Content.default.origin("fuel tag", "planks")), "Core []")
		t.eq(Content.default.fuel.planks, 300)
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
		-- (FixtureOre, FixtureFrost, FixturePlanks, FixtureCharge and FixtureLitCharge; its override
		-- of Planks moves no id.)
		t.eq(B.FixtureOre, FreshBlocks.count - 5, "its blocks after every other")
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
		-- Fuel by tag (the packs' `fuel`: Core's planks), and an entry's own beating its tag's.
		t.eq(Recipes.fuel["#planks"], 300, "a fuel tag -> Recipes.fuel")
		t.eq(Smelting.fuel(B.BirchPlanks), 300, "every item in the tag burns")
		t.eq(Smelting.fuel(B.FixturePlanks), 300, "another pack's planks in #planks too")
		t.eq(Smelting.fuel(B.Planks), 100, "an entry's own fuel beats its tag's")
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
		-- (With Shears too: it keeps nothing for them, `shearDrops`, as gravel keeps its flint.)
		local sheared = 0
		for _ = 1, 200 do
			local stack = EditRules.drops(B.FixtureFrost, false, I.Shears)
			if stack and stack.item == I.Snowball then
				sheared += 1
			end
		end
		t.ok(sheared > 0 and sheared < 200, `with Shears: its loot or itself ({sheared} of 200)`)
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
		-- Food and drink, effects by name.
		local Effects = need({ "Effects" })
		local Foods = need({ "Items", "Foods" })
		local snack = Foods.of(I.FixtureSnack)
		t.ok(snack ~= nil and Foods.ITEMS[I.FixtureSnack] == snack, "food -> Foods.ITEMS, by id")
		t.eq(snack.heal, 2)
		t.eq(snack.nutrition, 3)
		t.eq(snack.saturation, 0.5)
		t.eq(Foods.useTicks(snack), 20)
		t.eq(snack.effect.chance, 0.25, "its risk")
		t.eq(Foods.riskEffect(snack, true), Effects.id.Thirst, "a thirst risk")
		t.eq(snack.effects[1].effect, Effects.id.Speed, "an effect by name")
		t.eq(snack.effects[1].ticks, 60)
		t.eq(snack.effects[1].amplifier, 1)
		local salve = Foods.of(I.FixtureSalve)
		t.ok(Foods.isMedical(salve) and not Foods.nourishes(salve), "medicine")
		t.ok(Foods.cures(salve, "Bleeding") and Foods.cures(salve, "Infection"), "cures")
		t.eq(salve.aftermath.effect, Effects.id.Weakness, "aftermath")
		t.eq(salve.aftermath.amplifier, 0, "amplifier 0 when left out")
		t.eq(salve.aftermath.stage, 2)
		t.ok(salve.setback and salve.sound == "item.bandage.apply", "setback, sound")
		t.ok(table.isfrozen(snack) and table.isfrozen(snack.effects) and table.isfrozen(salve.cures), "frozen")
		local Drinks = need({ "ToughAsNails", "Drinks" })
		local tonic = Drinks.of(I.FixtureTonic)
		t.ok(tonic ~= nil and Drinks.ITEMS[I.FixtureTonic].drink == tonic, "drink -> Drinks.ITEMS, by id")
		t.eq(tonic.thirst, 3)
		t.eq(tonic.hydration, 0.5)
		t.eq(tonic.chance, 0.25)
		t.eq(tonic.effectTicks, 100)
		t.ok(tonic.warmth == 60 and tonic.chill == 30, "warmth and chill")
		t.eq(tonic.effects[1].effect, Effects.id.Speed, "an effect by name")
		t.eq(tonic.effects[1].amplifier, 0)
		t.eq(Drinks.manaOf(tonic), 5)
		t.eq(Drinks.emptyOf(I.FixtureTonic), I.GlassBottle, "the container it leaves, by name")
		local flask = Drinks.entry(I.FixtureFlask)
		t.ok(flask and flask.sips == true, "sips")
		t.eq(Drinks.emptyOf(I.FixtureFlask), I.FixtureGem)
		t.eq(Drinks.sips({ item = I.FixtureFlask, count = 1 }), 2, "its durability")
		t.eq(flask and flask.drink.chance, 0, "numbers left out are 0")
		t.eq(flask and flask.drink, Drinks.of(I.PurifiedWaterBottle), "an alike drink is the same Drink")
		-- An empty container's `fills`, dirty water's `purified` (its drink's).
		t.eq(Drinks.FILLS[I.FixtureGem], I.FixtureFlask, "fills -> Drinks.FILLS")
		t.ok(Drinks.isContainer(I.FixtureGem) and Drinks.fills({ item = I.FixtureGem, count = 1 }), "it fills")
		t.ok(Drinks.fills({ item = I.FixtureFlask, count = 1, damage = 1 }), "its flask tops up at water")
		t.eq(Drinks.purifiedOf(I.FixtureTonic), I.FixtureFlask, "drink.purified -> Drinks.PURIFIED_OF")
		t.ok(Drinks.isDirty(I.FixtureTonic) and not Drinks.isDirty(I.FixtureFlask), "dirty")
		local Boiling = need({ "ToughAsNails", "Boiling" })
		t.ok(Boiling.boils({ item = I.FixtureTonic, count = 1 }), "a campfire boils it")
		-- Cooked meat: a food a furnace makes into a food (its smelting recipe).
		t.eq(Foods.COOKED[I.FixtureSnack], I.FixtureSalve, "smelting -> Foods.COOKED")
		-- Silk Touch: only its tool gets its drop, never a blast.
		t.eq(FreshItems.blockDrops(B.FixtureCharge), nil, "silkTouch: nothing by itself")
		local mined = FreshItems.drops(B.FixtureCharge, I.WoodenPickaxe)
		t.eq(mined and mined.item, B.FixtureCharge, "its pickaxe gets it")
		t.eq(FreshItems.drops(B.FixtureCharge, nil), nil, "a hand does not")
		-- An explosive: `lit` and the lit block's `fuse` (server Behaviours/Tnt).
		local Tnt = need({ "Behaviours", "Tnt" }, serverRoot)
		t.ok(Tnt.isExplosive(B.FixtureCharge) and not Tnt.isLit(B.FixtureCharge), "lit -> an explosive")
		t.ok(Tnt.isLit(B.FixtureLitCharge), "fuse -> a lit block")
		t.eq(Tnt.fuseOf(B.FixtureCharge), 30, "its fuse")
		t.eq(Tnt.fuseOf(B.Tnt), Config.Tnt.FuseTicks, "TNT's, Config's")
		-- Spawns (server Players/SafeSpot): "near" keeps them off it, out of it and from beside it.
		local SafeSpot = need({ "Players", "SafeSpot" }, serverRoot)
		local function spot(cells: { [string]: number }): boolean
			local world = {
				getBlock = function(_self: any, x: number, y: number, z: number): number
					return cells[`{x},{y},{z}`] or FreshBlocks.AIR
				end,
			}
			return SafeSpot.isSafe(world :: any, 0, 10, 0)
		end
		t.ok(spot({ ["0,9,0"] = B.Stone }), "on stone")
		t.ok(not spot({ ["0,9,0"] = B.Stone, ["1,10,0"] = B.FixtureCharge }), "spawnUnsafe near: not beside")
		t.ok(not spot({ ["0,9,0"] = B.FixtureCharge }), "nor on it")
		t.ok(not spot({ ["0,9,0"] = B.OakLeaves }), "the game's leaves: on")
		t.ok(not spot({ ["0,9,0"] = B.Stone, ["0,10,0"] = B.WaterFlow3 }), "water: in, every level")
	end)

	t.test("content: a pack's biome reaches Biomes, Locate and the generator; its override of Plains", function()
		local env, root = fresh(function(env, packs)
			env.graft(BIOMES, packs, "Wilds")
		end)
		local FreshBlocks = env.require(root.Blocks)
		local FreshBiomes = env.require(root.Biomes)
		local B = FreshBlocks.id
		local GameBiomes = require(shared.Biomes)
		-- After every other biome, which keep their places.
		local marsh = FreshBiomes.byName("Marsh") :: any
		t.ok(marsh ~= nil, "the Marsh")
		t.eq(marsh.index, FreshBiomes.count, "last")
		t.eq(FreshBiomes.count, GameBiomes.count + 1)
		for index, biome in GameBiomes.list do
			t.eq(FreshBiomes.get(index).name, biome.name, `{biome.name} where it was`)
		end
		-- Its fields, as the registry makes them.
		t.eq(marsh.top, B.Grass)
		t.eq(marsh.patch, B.CoarseDirt)
		t.eq(marsh.patchCover, 0.2)
		t.eq(marsh.steep, B.Stone, "the default steep block")
		t.eq(marsh.weatherTemperature, 0.8)
		t.ok(marsh.precipitation, "it rains")
		t.eq(table.concat(marsh.bands, ","), tostring(1), "the Lowland band")
		t.ok(table.find(FreshBiomes.inBand[1], marsh.index) ~= nil, "in the band's list")
		t.eq(marsh.features[1].structure, "OakTree")
		t.eq(marsh.featureWeight, 1)
		t.eq(marsh.foliage.plants.blocks[1], B.ShortGrass)
		t.eq(marsh.foliage.plants.total, 4)
		t.eq(marsh.foliage.cover, 0.5, "foliage cover's default")
		t.eq(marsh.foliage.flowers.blocks[1], B.BlueOrchid)
		t.eq(marsh.foliage.herbs, nil)
		-- The override: a list replaced, the rest of the foliage kept (the Survival pack's mint too).
		local plains = FreshBiomes.byName("Plains") :: any
		local before = GameBiomes.byName("Plains") :: any
		t.eq(#plains.foliage.flowers.blocks, 2)
		t.eq(plains.foliage.flowers.blocks[2], B.Allium, "the new species list")
		t.eq(plains.foliage.flowerChance, before.foliage.flowerChance, "its chance kept")
		t.eq(plains.foliage.density, before.foliage.density)
		t.eq(plains.foliage.herbs.blocks[1], B.Mint, "the Survival pack's herbs kept")
		t.eq(FreshBiomes.where("Plains"), "pack Minecraft (patched by Survival, Wilds), biome Plains")
		-- Its tags: /locate's, joining the Minecraft pack's.
		local Locate = env.require(root.Generation.Locate)
		t.ok(table.find(Locate.BIOME_TAGS.is_forest, "marsh") ~= nil, "#is_forest")
		t.ok(table.find(Locate.BIOME_TAGS.is_forest, "birch_forest") ~= nil, "with the others")
		local wet = Locate.resolve(Locate.biomeRegistry(), "#wet") :: any
		t.eq(table.concat(wet.members, ","), "marsh", "a tag of its own")
		t.eq(Locate.biomeIndex.marsh, marsh.index)
		-- The generator takes it: its features are known builders, its arrays cover it.
		local Generation = env.require(root.Generation.TerrainGenerator)
		local single = Generation.new(7, { biome = marsh.index })
		t.eq(select(2, single.column(10, 10)), marsh.index, "Single Biome of it")
	end)

	--[[ The skill tree (the skills kind) ]]

	t.test("content: the skill tree's nodes are their features' packs', placed in load order", function()
		local content = Content.default
		local Skills = require(shared.Progression.Skills)
		for id, pack in
			{
				forager = "Core",
				quarrying = "Core",
				enlightenment = "Core",
				demolition = "Minecraft",
				fission = "Minecraft",
				hardy = "Survival",
				endurance = "Survival",
			}
		do
			local origin = content.origin("skill", id)
			t.eq(origin and origin.pack, pack, `{id}'s pack`)
		end
		t.eq(content.where("skill", "demolition"), "pack Minecraft, skill demolition")
		-- Each node's place (the protocol's u8) is its place among every pack's, dense.
		t.ok(Skills.count == #content.skills and Skills.count <= Skills.MAX, "every node, a u8 each")
		for index, record in content.skills do
			local skill = Skills.get(index) :: any
			t.eq(skill.id, record.id, `{record.id} at its place`)
			t.eq(Skills.byId(record.id), skill)
			t.eq(skill.cost, record.cost, "its cost its own")
		end
		-- (Core's, then the Minecraft pack's, then the Survival pack's.)
		local function at(id: string): number
			return (Skills.byId(id) :: any).index
		end
		t.ok(at("enlightenment") < at("demolition") and at("fission") < at("hardy"), "in pack order")
		t.eq(table.concat((Skills.byId("demolition") :: any).recipes, " "), "Tnt Gunpowder", "the entries naming it")
	end)

	t.test("content: a pack's skill: a node needing another, gating a recipe; an override", function()
		local env, root = fresh(function(env, packs)
			env.graft(SKILLS, packs, "Skilled")
		end)
		local Progression = env.require(root.Progression)
		local Skills, Ages, Knowledge = Progression.Skills, Progression.Ages, Progression.Knowledge
		local FreshItems = env.require(root.Items)
		local content = env.require(root.Content).default
		local blasting = assert(Skills.byId("blasting"), "the pack's node")
		t.eq(blasting.index, Skills.count, "the last pack's: the last place")
		t.eq(Ages.get(blasting.age).id, "electric")
		t.eq(blasting.row, 2)
		t.eq(table.concat(blasting.requires, " "), "demolition", "it needs the Minecraft pack's")
		t.eq(table.concat(blasting.recipes, " "), "BlastCharge", "the entry naming it")
		t.eq(Skills.ofName("BlastCharge"), blasting)
		-- Its cell on the skill tree screen: its Age's column, a row of its own.
		for _, other in Skills.ofAge(blasting.age) do
			t.ok(other == blasting or other.row ~= blasting.row, `{other.id}'s row is another`)
		end
		-- The gate: the Age, then the node, which needs Demolition first.
		local charge = FreshItems.id.BlastCharge
		local state = Progression.new()
		Progression.setAge(state, Ages.byId("electric").index)
		Progression.setPoints(state, Knowledge.total(40))
		t.ok(not Progression.allows(state, charge), "locked")
		t.eq(Progression.lockText(state, charge), "Requires Blasting")
		t.eq(select(2, Progression.canUnlock(state, "blasting")), "requires", "Demolition first")
		state.skills.demolition = true
		t.ok((Progression.unlock(state, "blasting")), "then it unlocks")
		t.ok(Progression.allows(state, charge), "and its recipe with it")
		local Crafting = env.require(root.Crafting)
		local I = FreshItems.id
		local made = Crafting.match({
			{ item = I.Tnt, count = 1 },
			{ item = I.Gunpowder, count = 1 },
			{
				item = I.Gunpowder,
				count = 1,
			},
		}, 3)
		t.eq(made and made.item, charge, "the recipe it gates")
		local Protocol = env.require(root.Net.Protocol)
		t.eq(Protocol.decodeUnlockSkill(Protocol.encodeUnlockSkill(blasting.index)), blasting.index, "on the wire")
		-- The override: Forager's cost and line, the rest and its place Core's.
		local forager = Skills.byId("forager")
		t.eq(forager.cost, 2, "patched")
		t.eq(forager.description, "+10% knowledge from discoveries, dearer")
		t.eq(forager.name, "Forager", "the rest kept")
		t.eq(forager.perk.bonus, 0.1)
		t.eq(forager.index, (require(shared.Progression.Skills).byId("forager") :: any).index, "its place kept")
		t.eq(content.where("skill", "forager"), "pack Core (patched by Skilled), skill forager")
		t.eq(table.concat((content.origin("skill", "forager") :: any).patched, " "), "Skilled")
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
	-- The IVS1 text of a template named `name` whose palette is `blocks`: a row of cells along x,
	-- one of each, and nothing else (Template.encode names the game's blocks only).
	local function ivs1(name: string, blocks: { string }): string
		local body: { number } = {}
		local function varint(v: number)
			while v >= 128 do
				table.insert(body, v % 128 + 128)
				v = v // 128
			end
			table.insert(body, v)
		end
		local function str(text: string)
			varint(#text)
			for i = 1, #text do
				table.insert(body, string.byte(text, i))
			end
		end
		str(name)
		for _, n in { #blocks, 1, 1, #blocks } do
			varint(n)
		end
		for _, block in blocks do
			str(block)
		end
		varint(0)
		for p = 1, #blocks do
			varint(p)
			varint(1)
		end
		for _ = 1, 3 do
			varint(0)
		end
		local inner = body
		body = {}
		varint(TemplateText.VERSION)
		varint(#inner)
		local b = buffer.create(#body + #inner + 4)
		for i, byte in body do
			buffer.writeu8(b, i - 1, byte)
		end
		for i, byte in inner do
			buffer.writeu8(b, #body + i - 1, byte)
		end
		local n = #body + #inner
		buffer.writeu32(b, n, TemplateText.crc32(b, 0, n))
		return TemplateText.PREFIX .. TemplateText.base64(b)
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
		-- Effects: the client's closed sets of icons and views (Effects/Looks), and their own rules.
		local function effect(extra: { [string]: any }): any
			local spec: { [string]: any } =
				{ name = "E", command = "e", color = { 1, 2, 3 }, category = "harmful", icon = "drop" }
			for field, value in extra do
				spec[field] = value
			end
			return spec
		end
		fails(
			{ pack("P", { effects = { effect({ intervall = 5 }) } }) },
			{ "pack P, effect E: intervall is no field it may have (did you mean interval?)" },
			"an effect's typo"
		)
		fails(
			{ pack("P", { effects = { effect({ icon = "spiralz" }) } }) },
			{ "pack P, effect E: icon must be one of speed, slowness, pickaxe", 'not the string "spiralz"' },
			"an icon the client has no glyph for"
		)
		fails(
			{ pack("P", { effects = { effect({ view = "xray" }) } }) },
			{ "view must be one of nightVision, blindness, nausea, glowing" },
			"a view the client has not"
		)
		fails(
			{ pack("P", { effects = { effect({ command = "Oil-Coated" }) } }) },
			{ "command must be lower_snake" },
			"a command"
		)
		fails(
			{ pack("P", { effects = { effect({ interval = 0 }) } }) },
			{ "interval must be a number of at least 1, not 0" },
			"an interval"
		)
		fails(
			{ pack("P", { effects = { effect({ category = "good" }) } }) },
			{ "category must be one of beneficial, harmful, neutral" },
			"a category"
		)
		fails(
			{ pack("P", { effects = { { name = "E", command = "e", color = { 1, 2, 3 }, category = "harmful" } } }) },
			{ "pack P, effect E: icon is missing" },
			"an effect's icon"
		)
		-- Potions.
		fails(
			{ pack("P", { potions = { { name = "X", ingredient = "A", effect = "E", secnds = 5 } } }) },
			{ "pack P, potion X: secnds is no field it may have (did you mean seconds?)" },
			"a potion's typo"
		)
		fails(
			{ pack("P", { potions = { { name = "X", ingredient = "A", effect = "E", strong = "2" } } }) },
			{ 'strong must be a number above 0 or true, not the string "2"' },
			"a strong variant"
		)
		fails(
			{ pack("P", { potions = { { name = "X", ingredient = "A", effect = "E", lore = { bse = "x" } } } }) },
			{ "pack P, potion X: lore.bse is no field it may have (did you mean base?)" },
			"a variant's line"
		)
		fails(
			{ pack("P", { potions = { { name = "X", ingredient = "A" } } }) },
			{ "pack P, potion X: effect is missing" },
			"an effect"
		)
		fails(
			{ pack("P", { templates = { ["t/a"] = "hello" } }) },
			{ 'pack P, template t/a: it must be a structure\'s text ("IVS1:..."), not text starting "hello"' },
			"a template's text"
		)
		fails(
			{ pack("P", { pools = { p = { elements = { { weight = 2 } } } } }) },
			{ "pack P, pool p: elements[1] needs a template or empty = true" },
			"a pool's element"
		)
		fails(
			{ pack("P", { pools = { p = { projection = "sideways", elements = {} } } }) },
			{ "pack P, pool p: projection must be one of rigid, terrain_matching" },
			"a projection"
		)
		fails({ pack("P", { pools = { p = {} } }) }, { "pack P, pool p: elements is missing" }, "a pool's elements")
		fails(
			{ pack("P", { structures = { { name = "s", startPool = "t", spacng = 3 } } }) },
			{ "pack P, structure s: spacng is no field it may have (did you mean spacing?)" },
			"a structure's field"
		)
		fails(
			{ pack("P", { structures = { { name = "s" } } }) },
			{ "pack P, structure s: startPool is missing" },
			"a structure's start"
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
		fails({
			pack("P1", { templates = { ["t/a"] = "IVS1:x" } }),
			pack("P2", { templates = { ["t/a"] = "IVS1:y" } }, { order = 20 }),
		}, { "pack P2, template t/a: pack P1 has one by that name already" }, "a template twice")
		local pool = { elements = { { empty = true } } }
		fails(
			{ pack("P1", { pools = { p = pool } }), pack("P2", { pools = { p = pool } }, { order = 20 }) },
			{ "pack P2, pool p: pack P1 has one by that name already" },
			"a pool twice"
		)
		fails(
			{ pack("P", { pools = { p = { override = true, fallback = "q" } } }) },
			{ "pack P, pool p overrides a pool no earlier pack makes" },
			"a pool override of nothing"
		)
		local structure = { name = "s", startPool = "t" }
		fails({
			pack("P1", { structures = { structure } }),
			pack("P2", { structures = { structure } }, { order = 20 }),
		}, { "pack P2, structure s: the name is taken by pack P1, structure s" }, "a structure twice")
		fails(
			{ pack("P", { structures = { { name = "s", override = true, spacing = 9 } } }) },
			{ "pack P, structure s overrides a structure no earlier pack makes" },
			"a structure override of nothing"
		)
		local many = {}
		for i = 1, Content.ITEM_BASE do
			many[i] = { name = `B{i}` }
		end
		fails({ pack("P", { blocks = many }) }, { "block ids must stay under ITEM_BASE" }, "too many blocks")
		local E = { name = "E", command = "e", color = { 1, 2, 3 }, category = "harmful", icon = "drop" }
		fails(
			{ pack("P1", { effects = { E } }), pack("P2", { effects = { E } }, { order = 20 }) },
			{ "pack P2, effect E: the name is taken by pack P1, effect E" },
			"an effect twice"
		)
		fails(
			{ pack("P", { effects = { { name = "Z", override = true } } }) },
			{ "pack P, effect Z overrides an effect no earlier pack makes" },
			"an effect override of nothing"
		)
		local X = { name = "X", ingredient = "A", effect = "E" }
		fails(
			{ pack("P1", { potions = { X } }), pack("P2", { potions = { X } }, { order = 20 }) },
			{ "pack P2, potion X: the name is taken by pack P1, potion X" },
			"a potion twice"
		)
		fails(
			{ pack("P", { potions = { { name = "Z", override = true } } }) },
			{ "pack P, potion Z overrides a potion no earlier pack makes" },
			"a potion override of nothing"
		)
		local effects = {}
		for i = 1, Content.MAX_EFFECTS + 1 do
			effects[i] = { name = `E{i}`, command = "e", color = { 1, 2, 3 }, category = "harmful", icon = "drop" }
		end
		fails({ pack("P", { effects = effects }) }, { "effect ids must fit a u8" }, "too many effects")
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
		-- (Content's check now the skills are a kind; Progression/Skills used to make it.)
		fails(
			with({ blocks = { { name = "A", skill = "juggling" } } }),
			{ "pack P, block A: skill names unknown skill juggling" },
			"a skill"
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
		-- A potion: its effect, its ingredient, its variants (an instant effect's and a lasting
		-- one's), its lines, its items' names; then the bottles it brews from (the game's).
		local EFFECTS = {
			{ name = "Quick", command = "quick", color = { 1, 2, 3 }, category = "beneficial", icon = "speed" },
			{
				name = "Hurt",
				command = "hurt",
				color = { 1, 2, 3 },
				category = "harmful",
				icon = "broken",
				instant = "harm",
			},
		}
		local function brewing(potion: any, more: { [string]: any }?): { Content.PackData }
			local kinds: { [string]: any } = { effects = EFFECTS, potions = { potion } }
			for kind, value in more or {} do
				kinds[kind] = value
			end
			return with(kinds)
		end
		fails(
			brewing({ name = "X", ingredient = "Stone", effect = "Quik", seconds = 5 }),
			{ "pack P, potion X: effect names unknown effect Quik (did you mean Quick?)" },
			"a potion's effect"
		)
		fails(
			brewing({ name = "X", ingredient = "Stnoe", effect = "Quick", seconds = 5 }),
			{ "pack P, potion X: ingredient names unknown item Stnoe (did you mean Stone?)" },
			"a potion's ingredient"
		)
		fails(
			brewing({ name = "X", ingredient = "Stone", effect = "Hurt", seconds = 5 }),
			{ "pack P, potion X: seconds is for a lasting effect: Hurt is instant" },
			"seconds for an instant effect"
		)
		fails(
			brewing({ name = "X", ingredient = "Stone", effect = "Quick" }),
			{ "pack P, potion X: seconds is missing (Quick lasts" },
			"none for a lasting one"
		)
		fails(
			brewing({ name = "X", ingredient = "Stone", effect = "Quick", seconds = 5, strong = true }),
			{ "pack P, potion X: strong must be its seconds (Quick lasts), not true" },
			"a lasting effect's strong variant"
		)
		fails(
			brewing({ name = "X", ingredient = "Stone", effect = "Hurt", strong = 5 }),
			{ "pack P, potion X: strong must be true for an instant effect (Hurt), not 5" },
			"an instant one's"
		)
		fails(
			brewing({ name = "X", ingredient = "Stone", effect = "Hurt", long = 5 }),
			{ "pack P, potion X: long is for a lasting effect: Hurt is instant" },
			"an instant effect's long variant"
		)
		fails(
			brewing({
				name = "X",
				ingredient = "Stone",
				effect = "Quick",
				seconds = 5,
				lore = { base = "x", long = "y" },
			}),
			{ "pack P, potion X: lore.long is for a long variant, and it has no long" },
			"a line for no item"
		)
		fails(
			brewing(
				{ name = "X", ingredient = "Stone", effect = "Quick", seconds = 5 },
				{ items = { { name = "PotionOfX", model = MODEL } } }
			),
			{ "pack P, potion X, item PotionOfX: the name is taken by pack P, item PotionOfX" },
			"a potion's item's name"
		)
		fails(
			brewing({ name = "X", ingredient = "Stone", effect = "Quick", seconds = 5 }),
			{ "pack P, potion X, recipe #1 (PotionOfX): ingredients names unknown item PurifiedWaterBottle" },
			"what it brews from (the game's bottle, missing here)"
		)
		fails(
			with({ blocks = { { name = "A", lore = "x" } }, lore = { A = "y" } }),
			{ "pack P, block A: its lore is pack P's lore too" },
			"lore twice for one item"
		)
		fails(
			with({ tags = { t = { "Stone" } }, fuel = { u = 300 } }),
			{ "pack P, fuel tag u: names unknown tag #u (did you mean t?)" },
			"a fuel tag"
		)
		fails(
			with({ tags = { t = { "Stone" } }, fuel = { t = 0 } }),
			{ "pack P, fuel tag t: burns for 0 ticks" },
			"a fuel tag's ticks"
		)
		fails(with({ fuel = { t = "long" } }), { "pack P, fuel tag t: it must be a number" }, "a fuel tag's type")
		-- Structures: a template's text and palette, the templates and pools named.
		local hut = ivs1("t/hut", { "Stone" })
		fails(
			with({ templates = { ["t/hut"] = ivs1("t/hut", { "Stone", "Stnoe" }) } }),
			{ "pack P, template t/hut: palette names unknown block Stnoe (did you mean Stone?)" },
			"a palette's block"
		)
		fails(
			with({ templates = { ["t/shed"] = hut } }),
			{ "pack P, template t/shed: its text is the template t/hut" },
			"a template under another name"
		)
		fails(
			with({ templates = { ["t/hut"] = string.sub(hut, 1, 20) } }),
			{ "pack P, template t/hut: The structure data is cut off" },
			"a cut text"
		)
		fails(
			with({ templates = { ["t/hut"] = hut }, pools = { p = { elements = { { template = "t/hot" } } } } }),
			{ "pack P, pool p: element 1 names unknown template t/hot (did you mean t/hut?)" },
			"a pool's template"
		)
		fails(
			with({
				templates = { ["t/hut"] = hut },
				pools = { p = { fallback = "q", elements = { { template = "t/hut" } } } },
			}),
			{ "pack P, pool p: fallback names unknown pool q" },
			"a fallback"
		)
		fails(
			with({ templates = { ["t/hut"] = hut }, structures = { { name = "s", startPool = "u" } } }),
			{ "pack P, structure s: startPool names unknown pool u" },
			"a start pool"
		)
		-- A structure's biomes: by their exact names (as every other name), at least one.
		local plains = {
			name = "Plains",
			bands = { "Lowland" },
			temperature = 0,
			humidity = 0,
			vegetation = 0.1,
			top = "Stone",
			filler = "Stone",
			fillerDepth = 3,
			underwater = "Stone",
			beach = "Stone",
			features = {},
		}
		local function grows(list: { any }): { Content.PackData }
			return with({ templates = { ["t/hut"] = hut }, biomes = { plains }, structures = list })
		end
		fails(
			grows({ { name = "s", startPool = "t/hut", biomes = { "plains" } } }),
			{ "pack P, structure s: biomes names unknown biome plains (did you mean Plains?)" },
			"a biome, by its exact name"
		)
		fails(
			grows({ { name = "s", startPool = "t/hut", biomes = {} } }),
			{ "pack P, structure s: biomes is empty, so it would grow nowhere" },
			"no biome at all"
		)
		fails(
			grows({ { name = "s", startPool = "t/hut" }, { name = "s", override = true, biomes = {} } }),
			{ "pack P (patched by P), structure s: biomes is empty" },
			"an override leaving it none"
		)
		t.ok(pcall(Content.build, grows({ { name = "s", startPool = "t/hut", biomes = { "Plains" } } })), "a biome")
		t.ok(pcall(Content.build, grows({ { name = "s", startPool = "t/hut" } })), "every biome")
		-- A pool is an explicit one, a template's name or the templates named under it.
		for _, start in { "t/hut", "t", "p" } do
			t.ok(
				pcall(
					Content.build,
					with({
						templates = { ["t/hut"] = hut },
						pools = { p = { fallback = "empty", elements = { { template = "t/hut" }, { empty = true } } } },
						structures = { { name = "s", startPool = start } },
					})
				),
				`start pool {start}`
			)
		end
		t.ok(
			pcall(Content.build, with({ recipes = { { type = "smelting", input = "Stone", result = "Stone" } } })),
			"a good pack loads"
		)
	end)

	t.test("content: biomes' checks: fields, names, overrides, the blocks and plants they name", function()
		local GROUND = {
			{ name = "Stone" },
			{ name = "Flower", plant = { soil = "dirt" } },
			{ name = "TallBottom", plant = { soil = "dirt", top = "TallTop" } },
			{ name = "TallTop", plant = { bottom = "TallBottom" } },
		}
		local BASE = {
			name = "B",
			bands = { "Lowland" },
			temperature = 0,
			humidity = 0,
			vegetation = 0.1,
			top = "Stone",
			filler = "Stone",
			fillerDepth = 3,
			underwater = "Stone",
			beach = "Stone",
			features = {},
		}
		-- A biome: BASE with `fields` over it.
		local function biome(fields: { [string]: any }): any
			local out = table.clone(BASE)
			for key, value in fields do
				out[key] = value
			end
			return out
		end
		local function with(list: { any }, more: { Content.PackData }?): { Content.PackData }
			local packs = { pack("P", { blocks = GROUND, biomes = list }) }
			for _, other in more or {} do
				table.insert(packs, other)
			end
			return packs
		end
		t.ok(pcall(Content.build, with({ biome({}) })), "a good biome loads")
		-- The schema's.
		fails(
			with({ biome({ vegetaton = 0.1 }) }),
			{ "pack P, biome B: vegetaton is no field it may have (did you mean vegetation?)" },
			"a typo"
		)
		fails(
			with({ biome({ temperature = "warm" }) }),
			{ 'pack P, biome B: temperature must be a number, not the string "warm"' },
			"a wrong type"
		)
		local topless = biome({})
		topless.top = nil
		fails(with({ topless }), { "pack P, biome B: top is missing" }, "a missing field")
		fails(with({ biome({ vegetation = 2 }) }), { "vegetation must be a share 0..1, not 2" }, "a share")
		fails(
			with({ biome({ features = { { "OakTree", 0 } } }) }),
			{ "features[1][2] must be a weight above 0, not 0" },
			"a weight"
		)
		fails(
			with({ biome({ foliage = { density = 0.1, plants = {} } }) }),
			{ "foliage.plants must name a plant at least" },
			"an empty plant list"
		)
		fails(
			with({ biome({ foliage = { density = 0.1, plants = { { "Flower", 1 } }, flowers = { chance = 0.1 } } }) }),
			{ "foliage.flowers.species is missing" },
			"a nested field"
		)
		fails(
			with({ biome({ tags = { "Is Forest" } }) }),
			{ 'tags[1] must be a tag id (lower case, digits and _: "is_forest")' },
			"a tag id"
		)
		-- (Its season class, oil wells, lakes and puddles.)
		t.ok(
			pcall(Content.build, with({ biome({ seasonClass = "dry", oilWells = 1, lakes = 3, puddles = 0 }) })),
			"a season class and its water and oil"
		)
		fails(
			with({ biome({ seasonClass = "warm" }) }),
			{ 'pack P, biome B: seasonClass must be one of cold, temperate, dry, tropical, not the string "warm"' },
			"a season class"
		)
		fails(with({ biome({ oilWells = 1.5 }) }), { "oilWells must be a share 0..1, not 1.5" }, "an oil chance")
		fails(with({ biome({ lakes = -1 }) }), { "lakes must be a number of at least 0, not -1" }, "a lake weight")
		fails(with({ biome({ puddles = "few" }) }), { 'puddles must be a share 0..1, not the string "few"' }, "puddles")
		-- Names and overrides.
		fails(
			with({ biome({}) }, { pack("Q", { biomes = { biome({}) } }, { order = 20 }) }),
			{ "pack Q, biome B: the name is taken by pack P, biome B" },
			"a name twice"
		)
		fails(
			with({ biome({}), { name = "C", override = true, vegetation = 0.2 } }),
			{ "pack P, biome C overrides a biome no earlier pack makes" },
			"an override of nothing"
		)
		-- (An override's tables of fields need none of theirs; the patched biome needs them all.)
		local herbs = { chance = 0.01, species = { { "Flower", 1 } } }
		fails(
			with({ biome({}) }, {
				pack(
					"Q",
					{ biomes = { { name = "B", override = true, foliage = { herbs = herbs } } } },
					{ order = 20 }
				),
			}),
			{ "pack P (patched by Q), biome B: foliage.density is missing" },
			"an override leaving out what the biome needs"
		)
		local base = biome({
			weather = { temperature = 0.5 },
			foliage = {
				density = 0.1,
				plants = { { "Flower", 1 } },
				flowers = { chance = 0.1, species = { { "Flower", 1 } } },
			},
		})
		local patched = Content.build(with({ base }, {
			pack("Q", {
				biomes = {
					{
						name = "B",
						override = true,
						weather = { precipitation = false },
						foliage = { herbs = herbs, flowers = { species = { { "TallBottom", 2 } } } },
						bands = { "Forest" },
					},
				},
			}, { order = 20 }),
		})).biome("B") :: any
		t.eq(patched.weather.temperature, 0.5, "a table of fields patched")
		t.eq(patched.weather.precipitation, false)
		t.eq(patched.foliage.flowers.chance, 0.1, "two deep")
		t.eq(patched.foliage.flowers.species[1][1], "TallBottom", "a list replaced")
		t.eq(#patched.foliage.flowers.species, 1)
		t.eq(patched.foliage.herbs, herbs, "a new table of fields")
		t.eq(patched.foliage.plants[1][1], "Flower", "the rest kept")
		t.eq(table.concat(patched.bands, ","), "Forest")
		t.eq(base.foliage.flowers.species[1][1], "Flower", "the earlier pack's data untouched")
		t.eq(base.weather.precipitation, nil)
		-- The blocks it names.
		fails(
			with({ biome({ top = "Stnoe" }) }),
			{ "pack P, biome B: top names unknown block Stnoe (did you mean Stone?)" },
			"its top"
		)
		fails(with({ biome({ steep = "Ghost" }) }), { "steep names unknown block Ghost" }, "steep")
		fails(
			with({ biome({ patches = { block = "Ghost", cover = 0.2 } }) }),
			{ "pack P, biome B: patches names unknown block Ghost" },
			"patches"
		)
		fails(
			with({ biome({ foliage = { density = 0.1, plants = { { "Ghost", 1 } } } }) }),
			{ "pack P, biome B: foliage.plants names unknown block Ghost" },
			"a plant"
		)
		fails(
			with({ biome({ foliage = { density = 0.1, plants = { { "Stone", 1 } } } }) }),
			{ "pack P, biome B: foliage.plants grows Stone, which is no plant (or the upper half of one)" },
			"no plant"
		)
		fails(
			with({
				biome({
					foliage = {
						density = 0.1,
						plants = { { "Flower", 1 } },
						flowers = { chance = 0.1, species = { { "TallTop", 1 } } },
					},
				}),
			}),
			{ "foliage.flowers grows TallTop, which is no plant (or the upper half of one)" },
			"an upper half"
		)
		fails(
			with({
				biome({
					foliage = {
						density = 0.1,
						plants = { { "Flower", 1 } },
						herbs = { chance = 0.1, species = { { "Ghost", 1 } } },
					},
				}),
			}),
			{ "foliage.herbs names unknown block Ghost" },
			"an herb"
		)
		-- A kind folder's file.
		fails({
			{
				name = "P",
				manifest = { order = 10 },
				kinds = { blocks = GROUND },
				folders = { biomes = { { file = "biomes/hills", data = { biome({ beach = "Ghost" }) } } } },
			},
		}, { "pack P, biomes/hills, biome B: beach names unknown block Ghost" }, "the file named")
	end)

	t.test("content: skills: their schema and perks, ids and overrides, Ages, icons, prerequisites, cells", function()
		local AGES = {
			{ id = "a", name = "First Age", level = 0, milestones = {}, reward = 0, color = { 1, 1, 1 } },
			{ id = "b", name = "Second Age", level = 1, milestones = {}, reward = 0, color = { 1, 1, 1 } },
		}
		-- A node `id` of the first Age, row 1 (`fields` on top).
		local function node(id: string, fields: { [string]: any }?): { [string]: any }
			local entry: { [string]: any } = {
				id = id,
				name = id,
				description = "x",
				row = 1,
				icon = "Stone",
				age = "a",
				cost = 1,
				perk = { kind = "none" },
			}
			for key, value in fields or {} do
				entry[key] = value
			end
			return entry
		end
		local function tree(skills: { any }): { Content.PackData }
			return { pack("P", { blocks = { { name = "Stone" } }, ages = AGES, skills = skills }) }
		end
		-- The schema's.
		fails(
			tree({ node("s", { rwo = 2 }) }),
			{ "pack P, skill s: rwo is no field it may have (did you mean row?)" },
			"a typo"
		)
		fails(tree({ node("s", { cost = "1" }) }), { "pack P, skill s: cost must be a whole number" }, "a wrong type")
		fails(tree({ node("s", { icon = false }) }), { "pack P, skill s: icon must be a string" }, "not a name")
		local noIcon = node("s")
		noIcon.icon = nil
		fails(tree({ noIcon }), { "pack P, skill s: icon is missing" }, "a missing field")
		fails(
			tree({ node("s", { perk = { kind = "flying" } }) }),
			{ "pack P, skill s: perk.kind must be one of knowledge, mining, wear, thirst, insulation, boiling, none" },
			"a perk kind of none of the code's"
		)
		fails(
			tree({ node("s", { perk = { kind = "wear", factor = 1.1 } }) }),
			{ "pack P, skill s: perk.factor is no number a wear perk has (it has chance)" },
			"another kind's number"
		)
		fails(
			tree({ node("s", { perk = { kind = "knowledge", bonus = 0.1 } }) }),
			{ "pack P, skill s: perk.sources is missing (a knowledge perk's)" },
			"a number the kind needs"
		)
		fails(
			tree({ node("s", { perk = { kind = "wear", chance = 15 } }) }),
			{ "pack P, skill s: perk.chance must be a share 0..1, not 15" },
			"a number out of its range"
		)
		-- Ids and overrides.
		fails({
			pack("P1", { blocks = { { name = "Stone" } }, ages = AGES, skills = { node("s") } }),
			pack("P2", { skills = { node("s", { row = 2 }) } }, { order = 20 }),
		}, { "pack P2, skill s: the id is taken by pack P1, skill s" }, "an id twice")
		fails(
			tree({ { id = "ghost", override = true, cost = 2 } }),
			{ "pack P, skill ghost overrides a skill no earlier pack makes" },
			"an override of nothing"
		)
		local patched = Content.build({
			pack(
				"P1",
				{ blocks = { { name = "Stone" } }, ages = AGES, skills = { node("s"), node("t", { row = 2 }) } }
			),
			pack("P2", { skills = { { id = "s", override = true, cost = 3 } } }, { order = 20 }),
		})
		t.eq(patched.skills[1].cost, 3, "an override patches")
		t.eq(patched.skills[1].name, "s", "the rest kept")
		t.eq(patched.skills[2].id, "t", "and its place")
		t.eq(patched.where("skill", "s"), "pack P1 (patched by P2), skill s")
		-- Cross-references.
		fails(tree({ node("s", { age = "c" }) }), { "pack P, skill s: age names unknown Age c" }, "an Age")
		fails(
			tree({ node("s", { icon = "Stnoe" }) }),
			{ "pack P, skill s: icon names unknown item Stnoe (did you mean Stone?)" },
			"an icon"
		)
		fails(
			tree({ node("s", { requires = { "ghost" } }) }),
			{ "pack P, skill s: requires names unknown skill ghost" },
			"a prerequisite"
		)
		fails(
			tree({ node("s", { requires = { "t" } }), node("t", { row = 2, requires = { "s" } }) }),
			{ "pack P, skill s: its requires go round in a loop (s, t, s)" },
			"a loop"
		)
		fails(
			tree({ node("s", { requires = { "t" } }), node("t", { age = "b" }) }),
			{ "pack P, skill s: requires t, a node of a later Age (Second Age)" },
			"a prerequisite of a later Age"
		)
		fails(
			tree({ node("s"), node("t", { age = "b" }), node("u") }),
			{ "pack P, skill u: row 1 of the First Age is pack P, skill s's" },
			"two nodes in one cell of the screen"
		)
		t.ok(
			pcall(
				Content.build,
				tree({ node("s"), node("t", { age = "b", requires = { "s" } }), node("u", { row = 6 }) })
			),
			"a good tree loads"
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
		fails({
			filed("P", {
				blocks = { stone },
				templates = { file("templates/huts", { ["t/a"] = ivs1("t/a", { "Ghost" }) }) },
			}),
		}, { "pack P, templates/huts, template t/a: palette names unknown block Ghost" }, "a template's palette")
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

	--[[ Checks: the registries' own, on the entries' values ]]

	-- Requiring `path` in a fresh game with a pack Patch (`kinds`) fails with `parts`.
	local function refused(kinds: { [string]: any }, path: { string }, parts: { string })
		local env, root = fresh(function(env, packs)
			local folder = env.folder(packs, "Patch")
			env.module(folder, "pack", { order = 900, requires = { "Minecraft", "Terraria" } })
			for kind, value in kinds do
				env.module(folder, kind, value)
			end
		end)
		local node = root
		for _, name in path do
			node = node[name]
		end
		local ok, err = pcall(env.require, node)
		local message = if ok then "(it loaded)" else tostring(err)
		t.ok(has(message, parts), `{table.concat(path, ".")}: {message}`)
	end
	local STONE = "pack Minecraft (patched by Patch), blocks/terrain, block Stone"
	local HELMET = "pack Minecraft (patched by Patch), items/armor, item IronHelmet"

	t.test("content: food and drink: their schema, unknown effects and containers, ones that do nothing", function()
		fails(
			{ pack("P", { items = { { name = "I", model = MODEL, food = { nutrition = 2, saturation = 0.1 } } } }) },
			{ "pack P, item I: food.heal is missing" },
			"a food's heal"
		)
		fails(
			{ pack("P", { items = { { name = "I", model = MODEL, food = { heal = 1, effect = { kind = "rot" } } } } }) },
			{ "pack P, item I: food.effect.kind must be one of hunger, thirst" },
			"a risk's kind"
		)
		fails(
			{ pack("P", { items = { { name = "I", model = MODEL, drink = { thirst = 1, emtpy = "Bowl" } } } }) },
			{ "pack P, item I: drink.emtpy is no field it may have (did you mean empty?)" },
			"a drink's field"
		)
		local SNACK = "pack Patch, item ClashSnack"
		local function item(fields: { [string]: any }): { [string]: any }
			local entry: { [string]: any } = { name = "ClashSnack", model = MODEL }
			for key, value in fields do
				entry[key] = value
			end
			return { items = { entry } }
		end
		refused(
			item({ food = { heal = 1, effects = { { effect = "Sped", ticks = 20 } } } }),
			{ "Items", "Foods" },
			{ `Foods: {SNACK} gives an unknown effect Sped` }
		)
		refused(
			item({ food = { heal = 1, cures = { "Bleding" } } }),
			{ "Items", "Foods" },
			{ `Foods: {SNACK} cures an unknown effect Bleding` }
		)
		refused(
			item({ food = { heal = 0, aftermath = { effect = "Weakness", ticks = 20, stage = 1 } } }),
			{ "Items", "Foods" },
			{ `Foods: {SNACK}'s aftermath needs an infection cure` }
		)
		refused(item({ food = { heal = 0 } }), { "Items", "Foods" }, { `Foods: {SNACK} does nothing` })
		refused(
			item({ food = { heal = 1, nutrition = 30, saturation = 0.1 } }),
			{ "Items", "Foods" },
			{ `Foods: {SNACK} has bad nutrition` }
		)
		refused(
			item({ drink = { effects = { { effect = "Sped", ticks = 20 } } } }),
			{ "ToughAsNails", "Drinks" },
			{ `Drinks: {SNACK} gives an unknown effect Sped` }
		)
		refused(
			item({ drink = { thirst = 2, empty = "GlassBotle" } }),
			{ "ToughAsNails", "Drinks" },
			{ `Drinks: {SNACK}'s empty container GlassBotle is no item` }
		)
		refused(
			item({ drink = { thirst = 2, sips = true } }),
			{ "ToughAsNails", "Drinks" },
			{ `Drinks: {SNACK} is drunk in sips but has no durability` }
		)
		refused(item({ drink = { hydration = 0.5 } }), { "ToughAsNails", "Drinks" }, { `Drinks: {SNACK} does nothing` })
		-- An empty container's `fills` and dirty water's `purified`: items (Content), drinks (Drinks).
		fails(
			{ pack("P", { items = { { name = "Jar", model = MODEL, fills = "Watr" } } }) },
			{ "pack P, item Jar: fills names unknown item Watr" },
			"fills"
		)
		fails(
			{ pack("P", { items = { { name = "Jar", model = MODEL, drink = { thirst = 1, purified = "Clean" } } } }) },
			{ "pack P, item Jar: drink purified names unknown item Clean" },
			"purified"
		)
		refused(
			item({ fills = "Stick" }),
			{ "ToughAsNails", "Drinks" },
			{ `Drinks: {SNACK} fills with Stick, which is no drink` }
		)
		refused(
			item({ drink = { thirst = 2, purified = "Stick" } }),
			{ "ToughAsNails", "Drinks" },
			{ `Drinks: {SNACK}'s purified twin Stick is no drink` }
		)
	end)

	t.test("content: an explosive's lit block and fuse, Silk Touch and spawn safety are checked", function()
		fails(
			{ pack("P", { blocks = { { name = "Bomb", lit = "LitBom" } } }) },
			{ "pack P, block Bomb: lit names unknown block LitBom" },
			"lit"
		)
		fails(
			{ pack("P", { blocks = { { name = "Bomb", lit = "Lit" }, { name = "Lit" } } }) },
			{ "pack P, block Bomb: lit names Lit, which has no fuse" },
			"a lit block without a fuse"
		)
		fails(
			{ pack("P", { blocks = { { name = "Lit", fuse = 2.5 } } }) },
			{ "pack P, block Lit: fuse must be whole ticks, 1 at least, not 2.5" },
			"fuse"
		)
		fails(
			{ pack("P", { blocks = { { name = "Spikes", spawnUnsafe = "beside" } } }) },
			{ "pack P, block Spikes: spawnUnsafe must be one of on, in, near" },
			"spawnUnsafe"
		)
		fails(
			{ pack("P", { blocks = { { name = "Rock", silkTuch = true } } }) },
			{ "pack P, block Rock: silkTuch is no field it may have (did you mean silkTouch?)" },
			"silkTouch"
		)
		refused(
			{ blocks = { { name = "ClashRock", silkTouch = true } } },
			{ "Items" },
			{ "Items: pack Patch, block ClashRock has silkTouch, which needs its tool and toolLevel" }
		)
	end)

	t.test("content: a registry refuses a value only it can check, naming the entry", function()
		-- (Content checks the names entries give; what a value means is the registry's to check.)
		-- (An unknown event a block's sounds or an armor piece's equipSound names is Content's to
		-- refuse now, the events being the packs': "content: sounds and music: ...".)
		refused(
			{ blocks = { { name = "Stone", override = true, sounds = { smash = "block.stone.break" } } } },
			{ "Sounds" },
			{ `Sounds: {STONE} has unknown action smash` }
		)
		refused(
			{ blocks = { { name = "Stone", override = true, radiation = 0 } } },
			{ "Radiation" },
			{ `Radiation: {STONE}'s radiation must be a positive number` }
		)
		refused(
			{ items = { { name = "IronHelmet", override = true, shielding = 2 } } },
			{ "Radiation" },
			{ `Radiation: {HELMET}'s shielding must be 0..1` }
		)
		refused(
			{ blocks = { { name = "Stone", override = true, miner = { ticks = 1.5, joules = 10 } } } },
			{ "Machines", "MinerRules" },
			{ `MinerRules: {STONE} needs whole ticks and J a tick` }
		)
		refused(
			{ blocks = { { name = "Stone", override = true, fuel = 0 } } },
			{ "Crafting", "Recipes" },
			{ `Recipes: {STONE} burns for 0 ticks` }
		)
	end)

	t.test("content: the biome registries' checks: bands, tree builders, an empty band, a biome code needs", function()
		local bad = {
			name = "Bad",
			bands = { "Lowlnd" },
			temperature = 0,
			humidity = 0,
			vegetation = 0,
			top = "Stone",
			filler = "Stone",
			fillerDepth = 1,
			underwater = "Stone",
			beach = "Stone",
			features = {},
		}
		refused({ biomes = { bad } }, { "Biomes" }, {
			"Biomes: pack Patch, biome Bad: bands names unknown band Lowlnd (did you mean Lowland?)",
		})
		local treeless = table.clone(bad)
		treeless.bands = { "Lowland" }
		treeless.features = { { "OakTre", 1 } }
		refused({ biomes = { treeless } }, { "Generation", "Structures" }, {
			"Structures: pack Patch, biome Bad: features names unknown tree builder OakTre (did you mean OakTree?)",
		})
		-- (Overrides moving every biome of the peaks to the slopes leave the Peaks band without one.)
		local Biomes = require(shared.Biomes)
		local peaks: number? = nil
		for index, band in Biomes.bands do
			if band.name == "Peaks" then
				peaks = index
			end
		end
		local moved = {}
		for _, index in Biomes.inBand[peaks :: number] do
			table.insert(moved, { name = Biomes.get(index).name, override = true, bands = { "Slopes" } })
		end
		t.ok(#moved > 0, "the peaks have biomes")
		refused({ biomes = moved }, { "Biomes" }, { "Biomes: no biome is in band Peaks" })
		-- A biome code looks up by name: there, or an error naming both as the game loads.
		t.eq(Biomes.need("Plains", "a spec"), Biomes.byName("Plains"))
		local ok, err = pcall(Biomes.need, "Plain", "a spec (its check)")
		t.ok(not ok and has(tostring(err), {
			"Biomes: a spec (its check) needs a biome named Plain, which no pack makes (did you mean Plains?)",
		}), tostring(err))
		-- (No pack takes a biome away: the merged list without it, before the registry loads.)
		local env, root = fresh()
		local list = env.require(root.Content).default.biomes
		for index, biome in list do
			if biome.name == "MushroomFields" then
				table.remove(list, index)
				break
			end
		end
		local loaded, problem = pcall(env.require, root.Generation.TerrainGenerator)
		t.ok(not loaded and has(tostring(problem), {
			"Biomes: TerrainGenerator (its islands far out at sea) needs a biome named MushroomFields, which no pack makes",
		}), tostring(problem))
	end)

	t.test("content: a biome's season class, oil wells, lakes and puddles reach the seasons and generation", function()
		-- (A pack patching the plains: cold, no oil, twice the lakes, more puddles; the tundra's
		-- puddles stay none, as it is frozen.)
		local env, root = fresh(function(env, packs)
			local folder = env.folder(packs, "Patch")
			env.module(folder, "pack", { order = 900, requires = { "Minecraft" } })
			env.module(folder, "biomes", {
				{ name = "Plains", override = true, seasonClass = "cold", oilWells = 0, lakes = 2, puddles = 0.2 },
				{ name = "Tundra", override = true, puddles = 0.5 },
			})
		end)
		local Biomes = env.require(root.Biomes)
		local plains = assert(Biomes.byName("Plains")).index
		local forest = assert(Biomes.byName("Forest")).index
		local desert = assert(Biomes.byName("Desert")).index
		local tundra = assert(Biomes.byName("Tundra")).index
		local SeasonClimate = env.require(root.Seasons.SeasonClimate)
		t.eq(SeasonClimate.classOf(plains), "cold", "the patch's class")
		t.eq(SeasonClimate.classOf(desert), "dry", "the Minecraft pack's")
		t.eq(SeasonClimate.classOf(forest), "temperate", "the default")
		local OilWells = env.require(root.Generation.OilWells)
		local Settings = env.require(root.Config)
		t.eq(OilWells.chanceOf(plains), 0, "no oil on the patched plains")
		t.eq(OilWells.chanceOf(desert), 0.6, "the desert's")
		t.eq(OilWells.chanceOf(forest), Settings.Caves.OilWells.Chance, "the default")
		local Lakes = env.require(root.Generation.Lakes)
		t.eq(Lakes.lakeWeight[plains], 2)
		t.eq(Lakes.lakeWeight[desert], 0.3)
		t.eq(Lakes.lakeWeight[forest], 1, "the default")
		t.eq(Lakes.puddleChance[plains], 0.2)
		t.eq(Lakes.puddleChance[tundra], 0, "frozen: none whatever it says")
		t.eq(Lakes.puddleChance[assert(Biomes.byName("Grove")).index], 0, "snowy: none")
		t.eq(Lakes.puddleChance[forest], 0.1, "the forest's")
	end)

	t.test("content: a registry's own check names the pack: two effects /effect finds by one word", function()
		refused({
			effects = {
				{ name = "Quick", command = "speed", color = { 1, 2, 3 }, category = "beneficial", icon = "speed" },
			},
		}, { "Effects" }, { 'Effects: pack Patch, effect Quick is found by "speed", and so is Speed' })
	end)

	t.test("content: the skill tree refuses a row off the screen, an icon no item, a perk's source or tier", function()
		-- A Patch pack's node `id`, in the Stone Age's free row 2 (`fields` on top).
		local function node(fields: { [string]: any }): { [string]: any }
			local entry: { [string]: any } = {
				id = "clash",
				name = "Clash",
				description = "x",
				row = 2,
				icon = "Stick",
				age = "stone",
				cost = 1,
				perk = { kind = "none" },
			}
			for key, value in fields do
				entry[key] = value
			end
			return { skills = { entry } }
		end
		local CLASH = "pack Patch, skill clash"
		refused(
			node({ row = 7 }),
			{ "Progression", "Skills" },
			{ `Skills: {CLASH}: row 7 is off the skill tree (rows 1..6` }
		)
		refused(
			node({ icon = "Air" }),
			{ "Progression", "Skills" },
			{ `Skills: {CLASH}: icon Air is a block that is no item` }
		)
		refused(
			node({ perk = { kind = "knowledge", sources = { "discovry" }, bonus = 0.1 } }),
			{ "Progression", "Skills" },
			{ `Skills: {CLASH}'s perk names unknown knowledge source discovry (did you mean discovery?)` }
		)
		refused(
			node({ perk = { kind = "mining", tiers = { "Bronze" }, factor = 1.1 } }),
			{ "Progression", "Skills" },
			{ `Skills: {CLASH}'s perk's tier Bronze begins no tool's name` }
		)
		-- More nodes than the protocol's u8 numbers: Ages enough for their cells.
		local ages, skills = {}, {}
		for a = 1, 43 do
			table.insert(
				ages,
				{ id = `age{a}`, name = `Age {a}`, level = a, milestones = {}, reward = 0, color = { 1, 1, 1 } }
			)
			for row = 1, 6 do
				local id = `node{a}_{row}`
				table.insert(skills, node({ id = id, age = `age{a}`, row = row }).skills[1])
			end
		end
		refused(
			{ ages = ages, skills = skills },
			{ "Progression", "Skills" },
			{ "Skills: ", "nodes, more than the 255 the protocol numbers (a u8 each)" }
		)
	end)

	--[[ Sounds and music (the `sounds` and `music` kinds) ]]

	-- The fixture pack of sounds and music, grafted into a fresh game.
	local CHORUS = "tests/fixtures/content/sounds/Chorus"

	-- A sound event's entry and a track's, with `fields` over them.
	local function soundEntry(name: string, fields: { [string]: any }?): { [string]: any }
		local entry: { [string]: any } =
			{ name = name, id = "rbxasset://sounds/oof.ogg", source = "players", side = "server" }
		for key, value in fields or {} do
			entry[key] = value
		end
		return entry
	end
	local function trackEntry(name: string, fields: { [string]: any }?): { [string]: any }
		local entry: { [string]: any } = { name = name, id = "rbxassetid://1", set = "surface" }
		for key, value in fields or {} do
			entry[key] = value
		end
		return entry
	end

	t.test("content: sounds and music merge by name, each kind's names its own, JSON too", function()
		local content = fixtures()
		t.eq(names(content.sounds), "block.beta.chime", "Beta's event (JSON)")
		local chime = content.sounds[1] :: any
		t.eq(chime.volume, 0.9, "patched by Gamma")
		t.eq(chime.pitch, 1.5, "the rest kept")
		t.eq(chime.limit, 2)
		t.eq(chime.fallback.id, "rbxasset://sounds/action_jump_land.mp3", "a JSON table")
		t.eq(chime.override, nil, "no override field left")
		t.eq(content.where("sound", "block.beta.chime"), "pack Beta (patched by Gamma), sound block.beta.chime")
		local origin = content.origin("sound", "block.beta.chime") :: Content.Origin
		t.eq(origin.pack, "Beta", "origin: the pack that made it")
		t.eq(table.concat(origin.patched, " "), "Gamma", "and the one that patched it")
		t.eq(names(content.music), "beta_theme")
		t.eq((content.music[1] :: any).title, "Beta Theme")
		t.eq((content.music[1] :: any).set, "night")
		t.eq(content.where("track", "beta_theme"), "pack Beta, track beta_theme")
		t.eq((content.origin("music", "beta_theme") :: Content.Origin).pack, "Beta", "by kind or by its word")
		-- The game's, each from its file.
		local game = Content.default
		t.eq(game.where("sound", "block.stone.break"), "pack Minecraft, sounds/blocks, sound block.stone.break")
		t.eq(
			game.where("sound", "item.firearm.9mm.fire"),
			"pack Apocalypse, sounds/weapons, sound item.firearm.9mm.fire",
			"a gun's shot is the Apocalypse pack's"
		)
		t.eq(game.where("sound", "ambient.radiation.click"), "pack Ores, sound ambient.radiation.click")
		t.eq(game.where("track", "mood1"), "pack Minecraft, track mood1")
		t.eq((game.origin("sound", "entity.zombie.hurt") :: Content.Origin).file, "sounds/zombies")
		-- A block, a sound and a track may share a name: each kind's names are its own.
		t.ok(
			pcall(Content.build, {
				pack(
					"P",
					{ blocks = { { name = "Hum" } }, sounds = { soundEntry("Hum") }, music = { trackEntry("Hum") } }
				),
			}),
			"a block, a sound and a track of one name"
		)
	end)

	t.test("content: a pack's sounds and music reach the catalogue, the blocks and the music", function()
		local env, root = fresh(function(env, packs)
			env.graft(CHORUS, packs, "Chorus")
		end)
		local FreshSounds = env.require(root.Sounds)
		local FreshBlocks = env.require(root.Blocks)
		local FreshItems = env.require(root.Items)
		local FreshMusic = env.require(root.Sounds.MusicList)
		local FreshDefine = env.require(root.Content.Define)
		local content = env.require(root.Content).default
		local GameSounds = require(shared.Sounds)
		local B = FreshBlocks.id
		-- A block sound type of its own: its five events make it one, after the Minecraft pack's.
		t.eq(FreshBlocks.SOUND_TYPES[#FreshBlocks.SOUND_TYPES], "chime", "a type, after every other pack's")
		local step = FreshSounds.get(FreshSounds.block(B.ChorusBlock, "step") :: number) :: any
		t.eq(step.name, "block.chime.step", "its block steps with it")
		t.near(step.pitch, 1.8, 1e-9, "the type's pitch, Minecraft's scaling for a step")
		t.eq(step.limit, 6, "and a step's limit")
		t.eq((FreshSounds.get("block.chime.break") :: any).id, FreshDefine.RECORDINGS.BREAK, "the recordings")
		-- Its events after every other pack's, the cave moods last.
		local sing = FreshSounds.get("entity.chorus.sing") :: any
		t.ok(sing.index > FreshSounds.id["ambient.radiation.click"], "after the Ores pack's")
		t.ok(sing.index < FreshSounds.id[FreshSounds.MOODS[1]], "before the cave moods")
		t.eq(FreshSounds.count, #content.sounds + #FreshSounds.MOODS)
		t.eq(sing.limit, 2, "its limit")
		t.eq(FreshSounds.LIMITS["entity.chorus.sing"], 2, "its kind's")
		t.eq(sing.fallback.pitch, 2, "its fallback")
		t.eq(sing.fallback.volume, 0.5, "what the fallback leaves out is the event's")
		-- An override retunes an event in its place.
		local click = FreshSounds.get("ui.button.click") :: any
		t.eq(click.volume, 0.8, "retuned")
		t.eq(click.id, "rbxasset://sounds/volume_slider.ogg", "its file kept")
		t.eq(click.index, GameSounds.id["ui.button.click"], "its number kept")
		t.eq(
			content.where("sound", "ui.button.click"),
			"pack Minecraft (patched by Chorus), sounds/interface, sound ui.button.click"
		)
		-- A machine's work sound and an armor piece's equip sound, by name.
		t.eq(FreshSounds.workSound(B.ElectricFurnace), "block.chorus.hum", "workSound")
		t.eq(FreshSounds.workSound(B.Stone), nil)
		t.eq(FreshSounds.armorEquip(FreshItems.id.IronHelmet), FreshSounds.id["item.armor.equip_chorus"], "equipSound")
		-- Music: a track added to a set, an override's title, a cave mood.
		local surface = FreshMusic.Surface
		t.eq(surface[#surface].Id, "rbxassetid://1234", "a surface track, after the Minecraft pack's")
		t.eq(surface[#surface].Title, "Chorus")
		t.eq(surface[1].Title, "First Light", "an override's title")
		t.eq(surface[1].Id, "rbxassetid://113907623876478", "its id kept")
		local mood = FreshSounds.MOODS[#FreshSounds.MOODS]
		t.eq(mood, "ambient.cave.chorus_mood", "a cave mood, its track's name")
		local event = FreshSounds.get(mood) :: any
		t.eq(event.id, "rbxassetid://5678")
		t.eq(event.category, "ambient.cave")
		t.eq(event.limit, 1, "one at a time, as every mood")
		t.eq(FreshMusic.Moods[#FreshMusic.Moods], "rbxassetid://5678")
	end)

	t.test("content: sounds and music: the schema's checks, names, overrides and the events entries name", function()
		fails(
			{ pack("P", { sounds = { soundEntry("a", { volme = 1 }) } }) },
			{ "pack P, sound a: volme is no field it may have (did you mean volume?)" },
			"a typo"
		)
		fails({ pack("P", { sounds = { soundEntry("a", { id = "sounds/oof.ogg" }) } }) }, {
			'pack P, sound a: id must be a sound file (rbxasset://sounds/... or rbxassetid://<n>), not the string "sounds/oof.ogg"',
		}, "a file")
		fails(
			{ pack("P", { sounds = { soundEntry("a", { side = "both" }) } }) },
			{ "pack P, sound a: side must be one of server, predicted, client" },
			"a side"
		)
		fails(
			{ pack("P", { sounds = { soundEntry("a", { source = "music" }) } }) },
			{ "pack P, sound a: source must be one of blocks, players, ambient, ui" },
			"a source"
		)
		fails(
			{ pack("P", { sounds = { { name = "a", id = "rbxasset://sounds/oof.ogg", side = "client" } } }) },
			{ "pack P, sound a: source is missing" },
			"a missing field"
		)
		fails(
			{ pack("P", { sounds = { soundEntry("a", { fallback = { pitch = 2 } }) } }) },
			{ "pack P, sound a: fallback.id is missing" },
			"a fallback's file"
		)
		fails(
			{ pack("P", { sounds = { soundEntry("a", { limit = "two" }) } }) },
			{ 'pack P, sound a: limit must be a number, not the string "two"' },
			"a limit"
		)
		fails(
			{ pack("P", { music = { trackEntry("t", { set = "boss" }) } }) },
			{ "pack P, track t: set must be one of surface, night, cave, mood" },
			"a set"
		)
		fails(
			{ pack("P", { music = { { name = "t", set = "cave" } } }) },
			{ "pack P, track t: id is missing" },
			"a track's id"
		)
		fails(
			{ pack("P", { music = { trackEntry("t", { titel = "x" }) } }) },
			{ "pack P, track t: titel is no field it may have (did you mean title?)" },
			"a track's typo"
		)
		-- Names and overrides.
		fails({
			pack("P1", { sounds = { soundEntry("a") } }),
			pack("P2", { sounds = { soundEntry("a") } }, { order = 20 }),
		}, { "pack P2, sound a: the name is taken by pack P1, sound a" }, "an event twice")
		fails(
			{ pack("P1", { music = { trackEntry("t") } }), pack("P2", { music = { trackEntry("t") } }, { order = 20 }) },
			{ "pack P2, track t: the name is taken by pack P1, track t" },
			"a track twice"
		)
		fails(
			{ pack("P", { sounds = { { name = "a", override = true, volume = 1 } } }) },
			{ "pack P, sound a overrides a sound no earlier pack makes" },
			"an override of nothing"
		)
		fails(
			{ pack("P", { music = { { name = "t", override = true, title = "x" } } }) },
			{ "pack P, track t overrides a track no earlier pack makes" },
			"a track's override of nothing"
		)
		t.ok(
			pcall(Content.build, {
				pack("P1", { sounds = { soundEntry("a") } }),
				pack("P2", { sounds = { { name = "a", override = true, volume = 0.1 } } }, { order = 20 }),
			}),
			"an override needs only its name"
		)
		-- The events entries name (blocks' and items' sound fields): one of the packs' sounds.
		local function with(kinds: { [string]: any }): { Content.PackData }
			local all = table.clone(kinds)
			all.sounds = { soundEntry("block.a.break") }
			return { pack("P", all) }
		end
		fails(
			with({ blocks = { { name = "A", sounds = { ["break"] = "block.a.brake" } } } }),
			{ "pack P, block A: sounds.break names unknown sound block.a.brake (did you mean block.a.break?)" },
			"a block's own sounds"
		)
		fails(
			with({ blocks = { { name = "A", workSound = "block.a.hum" } } }),
			{ "pack P, block A: workSound names unknown sound block.a.hum" },
			"a machine's work sound"
		)
		fails(
			with({ blocks = { { name = "A", toggle = { to = "A", sound = "block.a.open" } } } }),
			{ "pack P, block A: toggle sound names unknown sound block.a.open" },
			"a toggle's sound"
		)
		fails(
			with({
				items = {
					{
						name = "I",
						model = MODEL,
						armor = { slot = "Head", defense = 1, toughness = 0 },
						equipSound = "nope",
					},
				},
			}),
			{ "pack P, item I: equipSound names unknown sound nope" },
			"an armor piece's equip sound"
		)
		fails(
			with({ items = { { name = "I", model = MODEL, food = { heal = 1, sound = "nope" } } } }),
			{ "pack P, item I: food sound names unknown sound nope" },
			"a food's sound"
		)
		t.ok(
			pcall(Content.build, with({ blocks = { { name = "A", sounds = { ["break"] = "block.a.break" } } } })),
			"a good name loads"
		)
	end)

	t.test("content: the catalogue refuses what only it can check, naming the entry", function()
		local PATCH = "pack Patch, sound block.patch.hit"
		-- (A mining hit of its own, in the category every block type's hits share, wanting more.)
		local hit =
			soundEntry("block.patch.hit", { category = "block.hit", source = "blocks", side = "client", limit = 5 })
		refused({ sounds = { hit } }, { "Sounds" }, {
			`Sounds: {PATCH}'s limit 5 is not 3, the limit pack Minecraft, sounds/blocks, sound block.stone.hit gives its kind block.hit`,
		})
		refused(
			{ sounds = { soundEntry("entity.patch.hum", { limit = 1.5 }) } },
			{ "Sounds" },
			{ "Sounds: pack Patch, sound entity.patch.hum's limit must be a whole 1 or more" }
		)
		refused(
			{ sounds = { soundEntry("entity.patch.hum", { pitch = 0 }) } },
			{ "Sounds" },
			{ "Sounds: pack Patch, sound entity.patch.hum has a bad volume or pitch" }
		)
		refused(
			{ blocks = { { name = "Stone", override = true, workSound = "block.fan.loop" } } },
			{ "Sounds" },
			{ `Sounds: {STONE} has a workSound but is no machine` }
		)
		refused(
			{ blocks = { { name = "Stone", override = true, sound = "chime" } } },
			{ "Blocks" },
			{ "Block Stone has unknown sound chime (a type is one once the packs' sounds give block.chime.break" }
		)
		-- What the game's code plays by name, a menu's lids, the firearm classes' shots and the
		-- fluids' buckets must be some pack's events: a game whose packs lack one fails to load.
		local function loading(path: { string }, edit: (env: Loader.Environment, root: any) -> ()): string
			local env = Loader.new()
			local root = env.mount("src/shared", "ReplicatedStorage", "IceVoxel")
			edit(env, root)
			local node = root
			for _, name in path do
				node = node[name]
			end
			local ok, err = pcall(env.require, node)
			return if ok then "(it loaded)" else tostring(err)
		end
		local message = loading({ "Sounds" }, function(_env, root)
			-- (The Minecraft pack without its interface's sounds.)
			rawget(root.Content.Packs.Minecraft.sounds, "__children").interface = nil
		end)
		t.ok(
			has(message, { "Sounds: the game (Sounds.PLAYED) plays ui.button.click, which no pack's sounds give" }),
			message
		)
		message = loading({ "Weapons" }, function(env, root)
			-- (The Apocalypse pack's weapons' sounds without the pistol's shot.)
			local folder = root.Content.Packs.Apocalypse.sounds
			local list = env.require(folder.weapons)(env.require(root.Content.Define))
			local kept = {}
			for _, entry in list do
				if entry.name ~= "item.firearm.pistol.fire" then
					table.insert(kept, entry)
				end
			end
			env.module(folder, "weapons", kept)
		end)
		t.ok(
			has(message, { "Weapons: class pistol's shot item.firearm.pistol.fire is no pack's sound event" }),
			message
		)
		message = loading({ "Fluids" }, function(env, root)
			local water = env.require(root.Fluids.FluidList)[1]
			water.fillSound = "item.bucket.fil"
		end)
		t.ok(has(message, { "'s bucket sound item.bucket.fil is no pack's sound event" }), message)
	end)
end
