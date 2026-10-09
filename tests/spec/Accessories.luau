--[[
	Terraria's equipment (Config.Accessories): the accessory, vanity and weapon items (ItemList
	`accessory`, `vanity`, `magic`, their checks), their blank icons (TexturePack.Icons), the
	inventory's new stores (Inventory/Types: slots, window numbers, save places; copies; the
	server's restoreEquipment), what worn accessories add up to (Items/Accessories: sums, the
	largest, each once, open slots only, hidden ones still working, slots by Age, armor points),
	and where they come from (Crafting/Recipes, Progression/Ages' gate, Generation/Mineshafts'
	fourth loot pool, spiders' Feral Claws).
]]

return function(t, shared, require, server)
	local Accessories = require(shared.Items.Accessories)
	local Ages = require(shared.Progression.Ages)
	local Config = require(shared.Config)
	local Crafting = require(shared.Crafting)
	local Items = require(shared.Items)
	local Menu = require(shared.Inventory.Menu)
	local Mineshafts = require(shared.Generation.Mineshafts)
	local MobList = require(shared.Entities.MobList)
	local TexturePack = require(shared.TexturePack)
	local Types = require(shared.Inventory.Types)
	local InventoryState = require(server.Players.InventoryState)

	local id = Items.id

	local ACCESSORIES = {
		"HermesBoots",
		"CloudInABottle",
		"ShinyRedBalloon",
		"LuckyHorseshoe",
		"Aglet",
		"AnkletOfTheWind",
		"BandOfRegeneration",
		"BandOfStarpower",
		"ObsidianSkull",
		"Flipper",
		"CobaltShield",
		"FeralClaws",
	}
	local NEW_ITEMS = table.clone(ACCESSORIES)
	for _, name in
		{
			"FallenStar",
			"ManaCrystal",
			"LesserManaPotion",
			"ManaPotion",
			"WandOfSparking",
			"EmeraldStaff",
			"WaterBolt",
			"TopHat",
			"TuxedoShirt",
			"TuxedoPants",
		}
	do
		table.insert(NEW_ITEMS, name)
	end

	local function stack(name: string): Items.Stack
		return { item = id[name], count = 1 }
	end

	t.test("accessories: the items, appended after the potions, one a slot, no armor", function()
		for i, name in NEW_ITEMS do
			t.eq(id[name], id.HermesBoots + i - 1, `{name} in its place`)
		end
		for _, name in ACCESSORIES do
			local def = Items.get(id[name]) :: Items.ItemDef
			t.ok(def.accessory ~= nil, `{name} is an accessory`)
			t.eq(def.maxStack, 1, `{name} stacks to 1`)
			t.eq(def.armor, nil, `{name} is no armor`)
			t.eq(Items.armorSlot(id[name]), nil)
			t.ok(def.model ~= nil and #(def.model :: any) > 0, `{name} has a model`)
		end
		t.eq((Items.accessory(id.HermesBoots) :: any).runBoost, 0.4)
		t.eq((Items.accessory(id.CloudInABottle) :: any).airJumps, 1)
		t.eq((Items.accessory(id.ShinyRedBalloon) :: any).jump, 0.1)
		t.eq((Items.accessory(id.LuckyHorseshoe) :: any).noFallDamage, true)
		t.eq((Items.accessory(id.BandOfRegeneration) :: any).regen, 200)
		t.eq((Items.accessory(id.BandOfStarpower) :: any).mana, 20)
		t.eq((Items.accessory(id.CobaltShield) :: any).knockback, 1)
		t.eq(Items.accessory(id.IronHelmet), nil, "armor is no accessory")
		t.eq(Items.accessory(nil), nil)
		t.eq(Items.vanitySlot(id.TopHat), 1)
		t.eq(Items.vanitySlot(id.TuxedoShirt), 2)
		t.eq(Items.vanitySlot(id.TuxedoPants), 3)
		t.eq(Items.vanitySlot(id.IronHelmet), nil, "armor is no vanity item (it fits vanity slots by its armor slot)")
		t.eq(Items.armorSlot(id.TopHat), nil, "a vanity item is never worn as armor")
		local wand = Items.magic(id.WandOfSparking) :: any
		t.eq(wand.mana, 2)
		t.eq(wand.projectile, "spark")
		t.eq(Items.maxStack(id.FallenStar), 64)
		t.eq(Items.maxStack(id.LesserManaPotion), 16)
	end)

	t.test("accessories: every new item has a blank icon; Items.icon is nil until one is filled in", function()
		for _, name in NEW_ITEMS do
			t.eq(TexturePack.Icons[name], "", `{name}'s icon is blank`)
			t.eq(Items.icon(id[name]), nil)
		end
		for name in TexturePack.Icons do
			t.ok(Items.find(name) ~= nil, `the icon {name} is an item's`)
		end
		t.eq(Items.icon(nil), nil)
	end)

	t.test("accessories: the inventory's equipment stores and their numbers", function()
		local inventory = Types.newInventory()
		t.eq(inventory.hidden, 0)
		t.eq(inventory.accessorySlots, Config.Accessories.Slots)
		t.eq(Types.ACCESSORY_SIZE, 7)
		t.eq(Types.EQUIPMENT_SIZE, 18)
		t.eq(Types.ACCESSORY_START, Types.PLAYER_SLOTS, "after the hotbar: every slot before keeps its number")
		t.eq(Types.VANITY_ARMOR_START, 47)
		t.eq(Types.VANITY_ACCESSORY_START, 51)
		t.eq(Types.EQUIPMENT_END, 58)
		t.eq(Types.PLACE_CURSOR, 41, "PlayerCodec's cursor place")
		t.eq(Types.PLACE_ACCESSORY, 42)
		t.eq(Types.PLACE_VANITY_ARMOR, 49)
		t.eq(Types.PLACE_VANITY_ACCESSORY, 53)
		t.eq(Types.PLACE_END, 59)
		-- Copies are deep (the client's prediction must never share a table with the snapshot).
		inventory.accessories[1] = stack("HermesBoots")
		inventory.vanityArmor[1] = stack("TopHat")
		inventory.vanityAccessories[7] = stack("ShinyRedBalloon")
		inventory.hidden = 5
		inventory.accessorySlots = 6
		local copy = Menu.copyInventory(inventory)
		t.ok(copy.accessories ~= inventory.accessories and copy.accessories[1] ~= inventory.accessories[1])
		t.eq((copy.accessories[1] :: any).item, id.HermesBoots)
		t.eq((copy.vanityArmor[1] :: any).item, id.TopHat)
		t.eq((copy.vanityAccessories[7] :: any).item, id.ShinyRedBalloon)
		t.eq(copy.hidden, 5)
		t.eq(copy.accessorySlots, 6)
		-- The server puts a saved character's equipment back (copies, the hidden bits), nothing else.
		local state = InventoryState.new()
		state:join("p")
		local equipment = Types.newEquipment()
		equipment.accessories[2] = stack("Aglet")
		equipment.vanityArmor[4] = stack("IronBoots")
		equipment.hidden = 2
		state:restoreEquipment("p", equipment)
		local worn = (state:window("p") :: any).inventory
		t.eq(worn.accessories[2].item, id.Aglet)
		t.ok(worn.accessories[2] ~= equipment.accessories[2], "a copy")
		t.eq(worn.vanityArmor[4].item, id.IronBoots)
		t.eq(worn.hidden, 2)
		equipment.accessories[2] = nil
		state:restoreEquipment("p", equipment)
		t.eq(worn.accessories[2], nil, "replaced, not merged")
		state:restoreEquipment("nobody", equipment)
	end)

	t.test("accessories: stats add, take the largest or the shortest, each item once, open slots only", function()
		local inventory = Types.newInventory()
		local stats = Accessories.stats(inventory)
		t.eq(stats.speed, 0)
		t.eq(stats.noFallDamage, false)
		inventory.accessories[1] = stack("Aglet")
		inventory.accessories[2] = stack("AnkletOfTheWind")
		inventory.accessories[3] = stack("HermesBoots")
		inventory.accessories[4] = stack("CloudInABottle")
		inventory.accessories[5] = stack("ObsidianSkull")
		inventory.accessories[6] = stack("CobaltShield")
		local out = Accessories.stats(inventory, stats)
		t.ok(out == stats, "filled in place")
		t.near(stats.speed, 0.15, 1e-9, "Aglet + Anklet add")
		t.eq(stats.runBoost, 0.4)
		t.eq(stats.airJumps, 1)
		t.eq(stats.defense, 1, "the shield is in slot 6, closed at the start")
		t.eq(stats.fireWalk, true)
		t.eq(stats.knockback, 0)
		inventory.accessorySlots = 6
		Accessories.stats(inventory, stats)
		t.eq(stats.defense, 2, "open: Obsidian Skull + Cobalt Shield")
		t.eq(stats.knockback, 1)
		-- The same item twice counts once (Inventory/Menu refuses it; a stray one is harmless).
		inventory.accessories[6] = stack("Aglet")
		Accessories.stats(inventory, stats)
		t.near(stats.speed, 0.15, 1e-9)
		-- Hiding a look keeps its effect.
		inventory.hidden = 0x7F
		t.ok(Accessories.isHidden(inventory, "accessory", 3))
		t.ok(not Accessories.isHidden(inventory, "armor", 1))
		Accessories.stats(inventory, stats)
		t.eq(stats.runBoost, 0.4)
		inventory.hidden = bit32.lshift(1, Types.HIDE_ARMOR + 1)
		t.ok(Accessories.isHidden(inventory, "armor", 2))
		t.ok(not Accessories.isHidden(inventory, "accessory", 1))
		-- Regeneration takes the shortest interval; flags are any.
		inventory.accessories[1] = stack("BandOfRegeneration")
		inventory.accessories[2] = stack("LuckyHorseshoe")
		Accessories.stats(inventory, stats)
		t.eq(stats.regen, 200)
		t.eq(stats.noFallDamage, true)
		-- Armor points: the armor's plus the accessories' defense.
		inventory.armor[1] = stack("IronHelmet")
		local points = Accessories.armorPoints(inventory)
		t.eq(points, Items.armorPoints(inventory.armor) + 1, "the Obsidian Skull's +1")
	end)

	t.test("accessories: slots open by Age (5, the Industrial Age's 6th, the Atomic Age's 7th)", function()
		t.eq(Accessories.slotsForAge(1), 5)
		t.eq(Accessories.slotsForAge((Ages.byId("iron") :: any).index), 5)
		t.eq(Accessories.slotsForAge((Ages.byId("industrial") :: any).index), 6)
		t.eq(Accessories.slotsForAge((Ages.byId("electric") :: any).index), 6)
		t.eq(Accessories.slotsForAge((Ages.byId("atomic") :: any).index), 7)
	end)

	t.test("accessories: recipes, the Age gate, mineshaft loot and the spider's claws", function()
		local function grid(cells: { [number]: string }): { [number]: Items.Stack? }
			local out = {}
			for slot, name in cells do
				out[slot] = { item = id[name], count = 1 }
			end
			return out
		end
		local function made(cells: { [number]: string }): string?
			local result = Crafting.match(grid(cells), 3)
			return if result then (Items.get(result.item) :: any).name else nil
		end
		t.eq(made({ [1] = "Leather", [2] = "IronNugget", [3] = "IronNugget" }), "Aglet")
		t.eq(made({ "Feather", "Feather", "Feather", "String", "Emerald" }), "AnkletOfTheWind")
		t.eq(
			made({ [2] = "GoldIngot", [4] = "GoldIngot", [5] = "FallenStar", [6] = "GoldIngot", [8] = "GoldIngot" }),
			"BandOfStarpower"
		)
		t.eq(
			made({
				[1] = "Obsidian",
				[2] = "Obsidian",
				[3] = "Obsidian",
				[4] = "Obsidian",
				[6] = "Obsidian",
				[8] = "Obsidian",
			}),
			"ObsidianSkull"
		)
		t.eq(made({ "FallenStar", "FallenStar", "FallenStar", "FallenStar", "FallenStar" }), "ManaCrystal")
		local potions = Crafting.match(
			grid({ "PurifiedWaterBottle", "PurifiedWaterBottle", "FallenStar", "GlowDust" }),
			3
		) :: Items.Stack
		t.eq(potions.item, id.LesserManaPotion)
		t.eq(potions.count, 2)
		t.eq(made({ "LesserManaPotion", "LesserManaPotion", "GlowLichen" }), "ManaPotion")
		t.eq(made({ [2] = "Emerald", [3] = "Emerald", [5] = "Stick", [6] = "Emerald", [7] = "Stick" }), "EmeraldStaff")
		t.eq(made({ [2] = "Leather", [5] = "Leather", [7] = "Leather", [8] = "Leather", [9] = "Leather" }), "TopHat")
		t.eq(made({ "WhiteWool", "WhiteWool", "Leather", "Leather", "String" }), "TuxedoShirt")
		t.eq(made({ "Leather", "Leather", "Leather", "String" }), "TuxedoPants")
		-- Iron, gold and emerald things wait for the Iron Age; stars, crystals and the hat don't.
		local iron = (Ages.byId("iron") :: any).index
		for _, name in { "Aglet", "AnkletOfTheWind", "BandOfStarpower", "ObsidianSkull", "EmeraldStaff", "ManaPotion" } do
			t.eq(Ages.ofName(name), iron, `{name} is the Iron Age's`)
		end
		for _, name in { "ManaCrystal", "LesserManaPotion", "TopHat" } do
			t.eq(Ages.ofName(name), 1, `{name} is the Stone Age's`)
		end
		-- Mineshafts: a fourth pool after Minecraft's three, its items real.
		t.eq(#Mineshafts.LOOT, 4)
		local pool = Mineshafts.LOOT[4]
		t.eq(pool.rolls[1], 1)
		t.eq(pool.rolls[2], 1)
		local rewarding: { [string]: boolean } = {}
		for _, entry in pool.entries do
			if entry[1] then
				t.ok(Items.find(entry[1]) ~= nil, `{entry[1]} is an item`)
				rewarding[entry[1]] = true
			end
		end
		for _, name in { "HermesBoots", "CloudInABottle", "BandOfRegeneration", "WandOfSparking" } do
			t.ok(rewarding[name], `mineshafts hide {name}`)
		end
		-- About 3 chests in 10 hold an accessory (weights 31 of 105).
		local found = 0
		local isAccessory: { [string]: boolean } = {}
		for _, name in ACCESSORIES do
			isAccessory[name] = true
		end
		for i = 1, 400 do
			for _, item in Mineshafts.loot(12345, i * 7, 30, -i * 3) do
				if isAccessory[item.item] then
					found += 1
				end
			end
		end
		t.ok(found > 80 and found < 160, `about 30% of 400 chests: {found}`)
		-- The spider's Feral Claws: 2.5%, killed by a player.
		local claws = nil
		local spider = MobList.get(MobList.find("Spider") :: number) :: any
		for _, drop in spider.drops do
			if drop.item == "FeralClaws" then
				claws = drop
			end
		end
		t.ok(claws ~= nil, "spiders drop Feral Claws")
		t.eq((claws :: any).chance, 0.025)
		t.eq((claws :: any).byPlayer, true)
	end)
end
