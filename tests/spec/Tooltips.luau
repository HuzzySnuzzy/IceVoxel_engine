--[[
	Item tooltips (Shared/Items/Tooltip, its lore in Items/LoreList): what a sword, a pickaxe, armor
	with Tough As Nails insulation, food, a drink, fuel, a block, an accessory and a potion say, in
	Minecraft's order and colours; a stack's wear and data; the recipe gate's lock line; the twelve
	turrets' stat line (range, rate, rounds held, calibre: Shared/Turrets' Specs); every item
	giving lines without error; and every item having lore (no gaps, no stale keys). The weapons
	(Shared/Weapons/Describe): a firearm's state under its name (magazine, rounds, chamber, fire
	mode, what is mounted and its condition, a jam, ruin) and its block when fired (damage of each
	round, rates, calibre, feed, mounts), ammunition, magazines, attachments, the melee weapons'
	heavy attack, guard and finisher, and the condition words agreeing with the survival look's.
]]

return function(t, shared, require, _server, client)
	local Config = require(shared.Config)
	local Items = require(shared.Items)
	local LoreList = require(shared.Items.LoreList)
	local Tooltip = require(shared.Items.Tooltip)
	local Progression = require(shared.Progression)
	local Describe = require(shared.Weapons.Describe)
	local Theme = require(client.Ui.Theme)

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

	t.test("tooltips: food fills hunger (or heals, hunger off), a risky one says its chance in red", function()
		-- (Minecraft's hunger on, Config's default: the nutrition and the saturation it adds.)
		t.ok(table.find(Tooltip.texts(id.CookedBeef), "Restores 8 hunger") ~= nil)
		t.ok(table.find(Tooltip.texts(id.CookedBeef), "+12.8 Saturation") ~= nil, "8 x 0.8 x 2")
		t.ok(table.find(Tooltip.texts(id.RawMutton), "+1.2 Saturation") ~= nil)
		t.eq(table.find(Tooltip.texts(id.CookedBeef), "Heals 2 hearts"), nil, "no healing with hunger")
		local flesh = Tooltip.lines(id.RottenFlesh)
		t.ok(find(flesh, "When eaten:") ~= nil)
		t.eq(line(flesh, "80% chance: Hunger (0:30)").colour, "red", "Minecraft's Hunger")
		t.ok(table.find(Tooltip.texts(id.Crackers), "30% chance: Thirst (0:30)") ~= nil, "dry crackers")
		t.ok(table.find(Tooltip.texts(id.Bandage), "Heals 1 heart") ~= nil, "medicine heals either way")
		-- Hunger off: the game before the food bar.
		Config.Hunger.Enabled = false
		local ok, err = pcall(function()
			t.ok(table.find(Tooltip.texts(id.CookedBeef), "Heals 2 hearts") ~= nil)
			t.ok(table.find(Tooltip.texts(id.RawMutton), "Heals half a heart") ~= nil)
			t.eq(table.find(Tooltip.texts(id.CookedBeef), "Restores 8 hunger"), nil)
			t.eq(line(Tooltip.lines(id.RottenFlesh), "80% chance: Thirst (0:30)").colour, "red")
		end)
		Config.Hunger.Enabled = true
		if not ok then
			error(err, 0)
		end
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

	t.test("tooltips: the twelve turrets say their range, rate, rounds held and calibre", function()
		local Turrets = require(shared.Turrets)
		-- Config.Turrets' numbers by type, Basic to Ultimate, and how players read each calibre.
		local expected = {
			smg = { range = { 16, 20, 24, 32 }, rpm = { 90, 150, 240, 360 }, buffer = { 2, 3, 4, 6 }, calibre = "9mm" },
			rifle = {
				range = { 24, 32, 40, 48 },
				rpm = { 45, 75, 120, 180 },
				buffer = { 1, 2, 3, 4 },
				calibre = "5.56",
			},
			sniper = { range = { 40, 48, 56, 64 }, rpm = { 15, 20, 30, 40 }, buffer = { 1, 1, 2, 2 }, calibre = ".308" },
		}
		t.eq(#Turrets.SPECS, 12)
		for _, spec in Turrets.SPECS do
			local numbers = expected[spec.type]
			local want =
				`Range {numbers.range[spec.tier]} · {numbers.rpm[spec.tier]} rpm · holds {numbers.buffer[spec.tier]} · {numbers.calibre}`
			t.eq(Tooltip.turretLine(spec), want, spec.name)
			local lines = Tooltip.lines(spec.block)
			local index = find(lines, want)
			t.ok(index ~= nil, `{spec.name}'s tooltip has "{want}"`)
			if index then
				t.eq(lines[index].colour, "gray")
				t.eq(lines[index - 1].text, `Stores {Items.formatEnergy(spec.capacity)}`, "after its store")
			end
			t.eq(lines[2].text, LoreList[spec.name], "the lore first")
		end
		-- The design's line, last after its tool and store.
		t.eq(
			table.concat(Tooltip.texts(Turrets.of("smg", 3).block), " | "),
			`Elite SMG Turret | {LoreList.EliteSmgTurret} | Needs a Pickaxe | Stores 80 kJ | Range 24 · 240 rpm · holds 4 · 9mm`
		)
		-- Nothing else says it.
		for _, item in { id.MetalMiner, id.AmmoPress, id.Rounds556, id.Smg, id.ElectricFurnace } do
			for _, text in Tooltip.texts(item) do
				t.ok(string.find(text, " rpm · holds ", 1, true) == nil, `{Items.displayName(item)}: no turret line`)
			end
		end
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

	--[[ Weapons ]]

	-- A stack of `item` with weapon data and wear.
	local function weapon(item: number, data: { [string]: any }?, damage: number?): Items.Stack
		return { item = item, count = 1, damage = damage, data = if data then table.freeze(data) else nil }
	end

	-- The lines between the heading `heading` and the next empty line (the block's body).
	local function block(lines, heading: string): { string }
		local start = find(lines, heading)
		t.ok(start ~= nil, `the "{heading}" block`)
		local body = {}
		if start then
			t.eq(lines[start - 1].text, "", "an empty line before it")
			for index = start + 1, #lines do
				if lines[index].text == "" then
					break
				end
				table.insert(body, lines[index].text)
			end
		end
		return body
	end

	t.test("tooltips: a firearm's state under its name, its block when fired", function()
		local pistol = weapon(id.Pistol, {
			ch = id.Rounds9mm,
			mag = id.PistolMagazine,
			n = 12,
			ammo = id.Rounds9mm,
			optic = id.RedDotSight,
			muzzle = id.Suppressor,
			muzzleD = 100,
			light = id.WeaponFlashlight,
			lit = true,
		})
		local lines = Tooltip.lines(id.Pistol, pistol)
		local texts = Tooltip.texts(id.Pistol, pistol)
		t.eq(texts[1], "9mm Pistol")
		t.eq(texts[2], "Magazine: 9mm Pistol Magazine (Pristine)", "the state right under the name")
		t.eq(texts[3], "Rounds: 12 / 15 (9mm Rounds)")
		t.eq(texts[4], "Chambered: 9mm Rounds")
		t.eq(texts[5], "Optic: Red Dot Sight")
		t.eq(texts[6], "Muzzle: Suppressor (Worn)", "its wear: 300 of 400 left")
		t.eq(texts[7], "Light: Weapon Flashlight (on)")
		t.eq(texts[8], LoreList.Pistol, "then the lore")
		t.eq(lines[2].colour, "gray")
		local fired = block(lines, "When fired:")
		t.eq(
			table.concat(fired, " | "),
			" 7 Damage |  300 Rounds a Minute | Calibre: 9mm | Feeds from: 9mm Pistol Magazine | Mounts: Optic, Muzzle, Light"
		)
		t.eq(line(lines, " 7 Damage").colour, "darkGreen")
		t.eq(line(lines, "Calibre: 9mm").colour, "gray")
		-- (The bash, Minecraft's block, and the gun's wear stay.)
		t.ok(find(lines, "When in Main Hand:") ~= nil and find(lines, "Durability: 1500 / 1500") ~= nil)
		-- Nothing in it; jammed; ruined.
		local empty = Tooltip.texts(id.Pistol, weapon(id.Pistol))
		t.eq(empty[2], "No magazine")
		t.eq(empty[3], "Chamber empty")
		local jammed = Tooltip.lines(id.Pistol, weapon(id.Pistol, { ch = id.Rounds9mm, jam = true }))
		t.eq(line(jammed, "Jammed: reload to clear it").colour, "red")
		local ruined = Tooltip.lines(id.Pistol, weapon(id.Pistol, nil, 1500))
		t.eq(line(ruined, "Ruined: it will not fire").colour, "red")
		t.eq(find(Tooltip.lines(id.Pistol, weapon(id.Pistol, nil, 1100)), "Ruined: it will not fire"), nil, "Damaged")
		-- Without a stack (JEI, the creative list): no state, the block all the same.
		local plain = Tooltip.texts(id.Pistol)
		t.eq(plain[2], LoreList.Pistol)
		t.ok(table.find(plain, "When fired:") ~= nil)
	end)

	t.test("tooltips: every gun's rounds, rates, feed and mounts", function()
		local smg = Tooltip.lines(id.Smg, weapon(id.Smg, { mode = 2 }))
		t.ok(find(smg, "Fire mode: Auto") ~= nil, "its mode")
		t.eq(
			table.concat(block(smg, "When fired:"), " | "),
			" 5.95 Damage |  400 Rounds a Minute (Semi) |  700 Rounds a Minute (Auto) | Calibre: 9mm | Feeds from: SMG Magazine | Mounts: Optic, Muzzle, Light"
		)
		t.ok(find(Tooltip.lines(id.Smg, weapon(id.Smg)), "Fire mode: Semi") ~= nil)
		local pump = Tooltip.lines(id.PumpShotgun, weapon(id.PumpShotgun, { ch = id.Slugs, n = 3, ammo = id.Buckshot }))
		t.ok(find(pump, "Rounds: 3 / 5 (12 Gauge Buckshot)") ~= nil, "the tube")
		t.ok(find(pump, "Chambered: 12 Gauge Slugs") ~= nil, "the chamber apart")
		t.eq(
			table.concat(block(pump, "When fired:"), " | "),
			" 2.5 Damage x 8 pellets (12 Gauge Buckshot) |  16 Damage (12 Gauge Slugs) |  60 Rounds a Minute | Calibre: 12 gauge | Holds 5 rounds and 1 chambered | Mounts: Optic, Light"
		)
		local bolt = Tooltip.texts(id.BoltActionRifle)
		t.ok(table.find(bolt, " 22 Damage") ~= nil, "20 x 1.1")
		local hunting = Tooltip.texts(id.HuntingRifle)
		t.ok(table.find(hunting, "Built-in scope: 4x") ~= nil)
		t.eq(table.find(hunting, "Mounts: Optic"), nil, "no mount for a second optic")
		local crossbow = Tooltip.texts(id.Crossbow)
		t.ok(table.find(crossbow, "Holds 1 crossbow bolt") ~= nil)
		t.ok(table.find(crossbow, "Never jams") ~= nil)
		t.ok(table.find(crossbow, "Calibre: Crossbow bolt") ~= nil)
		local revolver = Tooltip.texts(id.Revolver, weapon(id.Revolver))
		t.eq(revolver[2], "Rounds: 0 / 5")
		t.ok(table.find(revolver, "Calibre: .357") ~= nil and table.find(revolver, "Never jams") ~= nil)
		t.eq(table.find(Tooltip.texts(id.Revolver), "Mounts: Optic"), nil, "no mounts")
	end)

	t.test("tooltips: ammunition, magazines and attachments", function()
		local nine = Tooltip.lines(id.Rounds9mm)
		t.eq(
			table.concat(block(nine, "As ammunition:"), " | "),
			" 7 Damage | Calibre: 9mm | Full damage to 40 blocks | Fits: 9mm Pistol, SMG"
		)
		t.ok(table.find(Tooltip.texts(id.Buckshot), " 2.5 Damage x 8 pellets") ~= nil)
		t.ok(table.find(Tooltip.texts(id.CrossbowBolt), "Often found again after a shot (70%)") ~= nil)
		-- (The chance is Config.Weapons.BoltRecover's alone: WeaponList's `recover` only switches it
		-- on.)
		local recover = Config.Weapons.BoltRecover
		Config.Weapons.BoltRecover = 0.5
		local half = table.find(Tooltip.texts(id.CrossbowBolt), "Often found again after a shot (50%)")
		Config.Weapons.BoltRecover = recover
		t.ok(half ~= nil, "BoltRecover's chance")
		t.eq(table.find(Tooltip.texts(id.Rounds9mm), "Often found again after a shot (70%)"), nil, "bullets: never")
		t.ok(table.find(Tooltip.texts(id.Rounds762), "Fits: Bolt-Action Rifle, Semi-Auto Rifle") ~= nil)
		local mag = Tooltip.texts(id.PistolMagazine, weapon(id.PistolMagazine, { n = 12, ammo = id.Rounds9mm }))
		t.eq(mag[2], "Rounds: 12 / 15 (9mm Rounds)")
		t.eq(
			table.concat(block(Tooltip.lines(id.PistolMagazine), "As a magazine:"), " | "),
			"Calibre: 9mm | Holds 15 rounds | Fits: 9mm Pistol"
		)
		t.eq(Tooltip.texts(id.SmgMagazine, weapon(id.SmgMagazine))[2], "Rounds: 0 / 30")
		local suppressor = Tooltip.lines(id.Suppressor)
		t.eq(
			table.concat(block(suppressor, "When mounted:"), " | "),
			"Noise: 25% | Spread: 90% | Suppressed | Fits: 9mm Pistol, SMG, Semi-Auto Rifle, Assault Rifle, Small-Bore Rifle"
		)
		t.eq(line(suppressor, "Noise: 25%").colour, "blue")
		t.ok(table.find(Tooltip.texts(id.RifleScope), "4x Zoom") ~= nil)
		t.ok(table.find(Tooltip.texts(id.RedDotSight), "1.4x Zoom") ~= nil)
		t.ok(table.find(Tooltip.texts(id.WeaponFlashlight), "Lights 24 blocks ahead") ~= nil)
		t.ok(table.find(Tooltip.texts(id.ImprovisedSuppressor), "Noise: 45%") ~= nil)
	end)

	t.test("tooltips: melee weapons say their heavy attack, guard and finisher", function()
		local knife = Tooltip.lines(id.KitchenKnife)
		t.eq(
			table.concat(block(knife, "Melee:"), " | "),
			" 7 Heavy Attack Damage | Hold the attack button for a heavy blow | Guard: blocks 30% of a zombie's hit | Kills an unaware zombie from behind"
		)
		t.eq(line(knife, " 7 Heavy Attack Damage").colour, "darkGreen")
		t.eq(line(knife, "Kills an unaware zombie from behind").colour, "blue")
		local bat = Tooltip.texts(id.BaseballBat)
		t.ok(table.find(bat, "Guard: blocks 60% of a zombie's hit") ~= nil)
		t.eq(table.find(bat, "Kills an unaware zombie from behind"), nil, "no finisher")
		t.eq(table.find(Tooltip.texts(id.IronSword), "Melee:"), nil, "a sword: as before")
		Config.Weapons.Melee.Enabled = false
		local ok, err = pcall(function()
			t.eq(table.find(Tooltip.texts(id.KitchenKnife), "Melee:"), nil, "the rework off")
		end)
		Config.Weapons.Melee.Enabled = true
		if not ok then
			error(err, 0)
		end
	end)

	t.test("tooltips: the weapon lines in order, and the condition words of the survival look", function()
		local texts = Describe.lines(weapon(id.PistolMagazine, { n = 3, ammo = id.Rounds9mm }))
		t.eq(
			table.concat(texts, " | "),
			"Rounds: 3 / 15 (9mm Rounds) | As a magazine: | Calibre: 9mm | Holds 15 rounds | Fits: 9mm Pistol"
		)
		t.eq(#Describe.lines(nil), 0)
		t.eq(#Describe.lines({ item = id.Stone, count = 1 }), 0, "nothing for stone")
		t.eq(#Describe.CONDITIONS, #Theme.CONDITIONS)
		for index, condition in Theme.CONDITIONS do
			t.eq(Describe.CONDITIONS[index], condition.name, "the same words")
		end
		t.eq(Describe.condition(id.Suppressor, 0), "Pristine")
		t.eq(Describe.condition(id.Suppressor, 399), "Ruined")
		t.eq(Describe.calibre("12g"), "12 gauge")
		t.eq(Describe.calibre("odd"), "odd")
	end)
end
