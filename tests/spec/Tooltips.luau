--[[
	Item tooltips (Shared/Items/Tooltip, its lore in Items/LoreList): what a sword, a pickaxe, armor
	with Tough As Nails insulation, food, a drink, fuel, a block, an accessory and a potion say, in
	Minecraft's order and colours; a stack's wear and data; the recipe gate's lock line; every item
	giving lines without error; and every item having lore (no gaps, no stale keys).
]]

return function(t, shared, require)
	local Items = require(shared.Items)
	local LoreList = require(shared.Items.LoreList)
	local Tooltip = require(shared.Items.Tooltip)
	local Progression = require(shared.Progression)

	local id = Items.id

	-- The index of the line reading `text` (nil: none).
	local function find(lines, text: string): number?
		for index, line in lines do
			if line.text == text then
				return index
			end
		end
		return nil
	end

	-- The line reading `text`, which must be there.
	local function line(lines, text: string)
		local index = find(lines, text)
		t.ok(index ~= nil, `tooltip has "{text}"`)
		return if index then lines[index] else { text = "", colour = "none" }
	end

	t.test("tooltips: a sword says Minecraft's main hand block and its durability", function()
		local lines = Tooltip.lines(id.IronSword)
		t.eq(lines[1].text, "Iron Sword")
		t.eq(lines[1].colour, "white")
		t.eq(lines[2].colour, "lore", "the lore comes right under the name")
		t.eq(lines[2].text, LoreList.IronSword)
		local heading = find(lines, "When in Main Hand:") :: number
		t.ok(heading ~= nil and lines[heading - 1].text == "", "an empty line before the block")
		t.eq(lines[heading].colour, "gray")
		t.eq(lines[heading + 1].text, " 6 Attack Damage")
		t.eq(lines[heading + 1].colour, "darkGreen")
		t.eq(lines[heading + 2].text, " 1.6 Attack Speed")
		t.eq(line(lines, "Durability: 250 / 250").colour, "gray")
		t.eq(find(lines, "Mining speed: 6x"), nil, "a sword says nothing of mining")
		-- A worn one says what is left.
		local worn = Tooltip.texts(id.IronSword, { item = id.IronSword, count = 1, damage = 50 })
		t.ok(table.find(worn, "Durability: 200 / 250") ~= nil, "wear shown")
	end)

	t.test("tooltips: a pickaxe says its harvest level, best blocks and mining speed", function()
		local texts = Tooltip.texts(id.IronPickaxe)
		local level = table.find(texts, "Harvest level: Iron") :: number
		t.ok(level ~= nil and level > 2, "after the lore")
		t.eq(texts[level + 1], "Harvests up to: Gold Ore, Diamond Ore, Emerald Ore")
		t.eq(texts[level + 2], "Mining speed: 6x")
		t.ok(table.find(texts, " 4 Attack Damage") ~= nil and table.find(texts, " 1.2 Attack Speed") ~= nil)
		t.ok(table.find(Tooltip.texts(id.GoldenPickaxe), "Harvest level: Wood") ~= nil, "gold harvests as wood")
		t.ok(table.find(Tooltip.texts(id.DiamondPickaxe), "Harvests up to: Obsidian") ~= nil)
		local shovel = Tooltip.texts(id.StoneShovel)
		t.ok(table.find(shovel, "Mining speed: 4x") ~= nil, "a shovel's speed")
		t.eq(table.find(shovel, "Harvest level: Stone"), nil, "no harvest level where every tier harvests alike")
		t.ok(table.find(Tooltip.texts(id.Shears), "Durability: 238 / 238") ~= nil, "shears wear")
	end)

	t.test("tooltips: armor says its slot, points and Tough As Nails insulation", function()
		local lines = Tooltip.lines(id.LeatherChestplate)
		local heading = find(lines, "When on Chest:") :: number
		t.ok(heading ~= nil, "slot heading")
		t.eq(lines[heading + 1].text, "+3 Armor")
		t.eq(lines[heading + 1].colour, "blue")
		t.eq(line(lines, "+1 Warmth").colour, "blue")
		t.eq(line(lines, "Keeps you from freezing").colour, "blue")
		t.ok(table.find(Tooltip.texts(id.LeafBoots), "+1 Cooling") ~= nil, "leaf armor cools")
		local diamond = Tooltip.texts(id.DiamondHelmet)
		t.ok(table.find(diamond, "+2 Armor Toughness") ~= nil, "toughness")
		t.eq(table.find(diamond, "Keeps you from freezing"), nil, "only leather is freeze immune")
	end)

	t.test("tooltips: food heals, and a risky one says its chance in red", function()
		t.ok(table.find(Tooltip.texts(id.CookedBeef), "Heals 2 hearts") ~= nil)
		t.ok(table.find(Tooltip.texts(id.RawMutton), "Heals half a heart") ~= nil)
		local flesh = Tooltip.lines(id.RottenFlesh)
		t.ok(find(flesh, "When eaten:") ~= nil)
		t.eq(line(flesh, "80% chance: Thirst (0:30)").colour, "red")
	end)

	t.test("tooltips: drinks say thirst, hydration, dirt and a tea's warmth", function()
		local dirty = Tooltip.lines(id.DirtyWaterBottle)
		t.ok(find(dirty, "When drunk:") ~= nil)
		t.eq(line(dirty, "Restores 4 thirst").colour, "blue")
		t.ok(find(dirty, "+2 Hydration") ~= nil, "4 x 0.25 x 2")
		t.eq(line(dirty, "50% chance: Thirst (0:15)").colour, "red")
		local clean = Tooltip.texts(id.PurifiedWaterBottle)
		t.ok(table.find(clean, "Restores 6 thirst") ~= nil and table.find(clean, "+4.8 Hydration") ~= nil)
		t.eq(table.find(clean, "50% chance: Thirst (0:15)"), nil, "purified water is safe")
		t.ok(table.find(Tooltip.texts(id.GingerTea), "Internal Warmth (2:00)") ~= nil)
		local herbal = Tooltip.texts(id.HerbalTea)
		t.ok(table.find(herbal, "Internal Warmth (1:00)") ~= nil and table.find(herbal, "Internal Chill (1:00)") ~= nil)
		-- A canteen's sips come after its drink, its wear from the stack.
		local canteen =
			Tooltip.texts(id.PurifiedWaterCanteen, { item = id.PurifiedWaterCanteen, count = 1, damage = 1 })
		t.ok((table.find(canteen, "Sips: 2 / 3") or 0) > (table.find(canteen, "When drunk:") or math.huge))
		t.eq(table.find(canteen, "Durability: 2 / 3"), nil)
	end)

	t.test("tooltips: fuel says its burn time and what generators make of it", function()
		local coal = Tooltip.texts(id.Coal)
		t.ok(table.find(coal, "As fuel:") ~= nil)
		t.ok(table.find(coal, "Burns for 80 s, smelts 8 items") ~= nil)
		t.ok(table.find(coal, "Heat Generator: 320 kJ") ~= nil)
		local lava = Tooltip.texts(id.LavaBucket)
		t.ok(table.find(lava, "Burns for 1,000 s, smelts 100 items") ~= nil)
		t.ok(table.find(lava, "Heat Generator: 4 MJ") ~= nil, "a lava bucket's lava")
		local fuel = Tooltip.texts(id.FuelBucket)
		t.ok(table.find(fuel, "Combustion Generator: 10 MJ") ~= nil)
		t.eq(table.find(Tooltip.texts(id.Stone), "As fuel:"), nil, "stone doesn't burn")
	end)

	t.test("tooltips: blocks say their tool, light, falling, climbing and more", function()
		local ore = Tooltip.lines(id.IronOre)
		t.eq(line(ore, "Needs a Stone Pickaxe or better").colour, "gray")
		t.ok(table.find(Tooltip.texts(id.DiamondOre), "Needs an Iron Pickaxe or better") ~= nil)
		t.ok(table.find(Tooltip.texts(id.Stone), "Needs a Pickaxe") ~= nil)
		t.ok(table.find(Tooltip.texts(id.Cobweb), "Needs a Sword or Shears") ~= nil)
		local log = Tooltip.texts(id.OakLog)
		t.ok(table.find(log, "Best tool: Axe") ~= nil and table.find(log, "Flammable") ~= nil)
		t.ok(table.find(Tooltip.texts(id.Torch), "Light: 14") ~= nil)
		t.ok(table.find(Tooltip.texts(id.Sand), "Falls when nothing holds it up") ~= nil)
		t.ok(table.find(Tooltip.texts(id.Ladder), "Climbable") ~= nil)
		t.ok(table.find(Tooltip.texts(id.Ice), "Slippery") ~= nil)
		t.ok(table.find(Tooltip.texts(id.Chest), "Storage: 27 slots") ~= nil)
		t.ok(table.find(Tooltip.texts(id.Campfire), "Warms you when you are close") ~= nil)
		t.ok(table.find(Tooltip.texts(id.StructureBlock), "Creative only") ~= nil)
		t.ok(table.find(Tooltip.texts(id.BasicBattery), "Stores 4 MJ") ~= nil)
		t.ok(table.find(Tooltip.texts(id.BasicFluidTank), "Capacity: 32,000 mB") ~= nil)
		t.ok(table.find(Tooltip.texts(id.BasicUniversalCable), "Capacity: 8 kJ/t") ~= nil)
		t.ok(table.find(Tooltip.texts(id.BasicLogisticalTransporter), "Speed: 1 block/s") ~= nil)
		-- A tank's contents come before the lore (the item data).
		local tank = Tooltip.texts(id.BasicFluidTank, {
			item = id.BasicFluidTank,
			count = 1,
			data = table.freeze({ fluid = 2, amount = 5000 }),
		})
		t.eq(tank[2], "Lava: 5,000 mB")
		t.eq(tank[3], LoreList.BasicFluidTank)
	end)

	t.test("tooltips: accessories, potions and mana items", function()
		local claws = Tooltip.lines(id.FeralClaws)
		local worn = find(claws, "When worn:") :: number
		t.ok(worn ~= nil and claws[worn].colour == "gray")
		t.eq(claws[worn + 1].text, "+12% attack speed")
		t.eq(claws[worn + 1].colour, "blue")
		local swiftness = Tooltip.lines(id.StrongPotionOfSwiftness)
		t.eq(line(swiftness, "Speed II (1:30)").colour, "blue")
		t.eq(line(Tooltip.lines(id.PotionOfPoison), "Poison (0:45)").colour, "red")
		local potion = Tooltip.texts(id.ManaPotion)
		t.ok(table.find(potion, "Restores 100 mana") ~= nil)
		local headings = 0
		for _, text in potion do
			headings += if text == "When drunk:" then 1 else 0
		end
		t.eq(headings, 1, "Shared/Mana's block only: no empty drink block")
		t.ok(table.find(Tooltip.texts(id.WandOfSparking), "3 Magic Damage") ~= nil)
	end)

	t.test("tooltips: the recipe gate's lock line", function()
		local stone = Progression.new()
		local lines = Tooltip.lines(id.IronPickaxe, nil, { gate = stone })
		t.eq(lines[#lines].text, "Crafting requires the Iron Age")
		t.eq(lines[#lines].colour, "red")
		t.eq(find(Tooltip.lines(id.IronPickaxe), "Crafting requires the Iron Age"), nil, "no gate, no lock")
		t.eq(find(Tooltip.lines(id.WoodenPickaxe, nil, { gate = stone }), "Crafting requires the Iron Age"), nil)
	end)

	t.test("tooltips: every item gives lines without error, every one with lore", function()
		local missing = {}
		for _, def in Items.list do
			local ok, lines = pcall(Tooltip.lines, def.id, nil, { gate = Progression.new() })
			t.ok(ok and #lines >= 2, `{def.name} has a tooltip`)
			if ok then
				t.eq(lines[1].text, def.displayName)
				for _, entry in lines do
					t.ok(type(entry.text) == "string" and type(entry.colour) == "string", `{def.name}'s lines`)
				end
			end
			local lore = LoreList[def.name]
			if type(lore) ~= "string" or lore == "" then
				table.insert(missing, def.name)
			end
		end
		t.eq(table.concat(missing, ", "), "", "every item has lore")
		for name, lore in LoreList do
			t.ok(rawget(Items.id :: any, name) ~= nil, `lore names unknown item {name}`)
			t.ok(#lore <= 90, `{name}'s lore is short`)
		end
		-- Unknown items give their name only.
		t.eq(#Tooltip.lines(-5), 1)
	end)

	t.test("tooltips: numbers as Minecraft writes them", function()
		t.eq(Tooltip.number(4), "4")
		t.eq(Tooltip.number(1.6), "1.6")
		t.eq(Tooltip.number(2.5), "2.5")
		t.eq(Tooltip.number(1 / 3), "0.33")
		t.eq(Tooltip.number(0), "0")
		t.eq(Tooltip.hearts(4), "2 hearts")
		t.eq(Tooltip.hearts(2), "1 heart")
		t.eq(Tooltip.hearts(3), "1.5 hearts")
	end)
end
