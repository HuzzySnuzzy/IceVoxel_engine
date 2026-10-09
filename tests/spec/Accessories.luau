--[[
	Terraria's equipment (Config.Accessories): the accessory, vanity and weapon items (ItemList
	`accessory`, `vanity`, `magic`, their checks), their blank icons (TexturePack.Icons), the
	inventory's new stores (Inventory/Types: slots, window numbers, save places; copies; the
	server's restoreEquipment), what worn accessories add up to (Items/Accessories: sums, the
	largest, each once, open slots only, hidden ones still working, slots by Age, armor points),
	and where they come from (Crafting/Recipes, Progression/Ages' gate, Generation/Mineshafts'
	fourth loot pool, spiders' Feral Claws). Then what they do and show: the looks text drawn
	(vanity over armor, hidden slots, closed rows, each once) and its parser, the tooltips, the
	speed factor, knockback share, attack speed and regeneration, the server's InventoryState
	(open slots, `has`, death drops), the Obsidian Skull on campfires (Players/Burning), and other
	players' air jumps told from their poses (Player/AirJumps: every frame rate, never a ground
	jump, the flag a frame late, ledges, flying, cooldown, nonsense).
]]

return function(t, shared, require, server, client)
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
		t.eq(Types.ACCESSORY_START, 40, "after the hotbar: every slot before keeps its number")
		t.eq(Types.PLAYER_SLOTS, Types.EQUIPMENT_END, "every window has the equipment slots")
		t.eq(Types.HIDDEN_MASK, 0x0F7F, "7 accessory bits, 4 armor bits from HIDE_ARMOR")
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

	--[[ What the equipment does (the builders' rules on top of the stats) ]]

	t.test("accessories: the looks drawn: vanity over armor, hidden slots, worn places, once each", function()
		local inventory = Types.newInventory()
		t.eq(Accessories.looks(inventory), "0,0,0,0", "nothing worn")
		inventory.armor[1] = stack("IronHelmet")
		inventory.armor[2] = stack("IronChestplate")
		inventory.armor[4] = stack("IronBoots")
		inventory.vanityArmor[1] = stack("TopHat")
		inventory.vanityArmor[3] = stack("TuxedoPants")
		local head, chest, legs, feet = id.TopHat, id.IronChestplate, id.TuxedoPants, id.IronBoots
		t.eq(Accessories.looks(inventory), `{head},{chest},{legs},{feet}`, "vanity over armor, vanity alone too")
		-- A hidden armor slot shows nothing, its vanity piece neither (Terraria's eye on the row).
		inventory.hidden = bit32.lshift(1, Types.HIDE_ARMOR + 1)
		t.eq(Accessories.looks(inventory), `{head},0,{legs},{feet}`, "the chest hidden")
		inventory.hidden = 0
		-- Accessories: only those with a `worn` place (all of today's), open slots, unhidden.
		inventory.accessories[1] = stack("HermesBoots")
		inventory.accessories[2] = stack("ShinyRedBalloon")
		inventory.accessories[6] = stack("CloudInABottle")
		local armor = `{head},{chest},{legs},{feet}`
		t.eq(Accessories.looks(inventory), `{armor},{id.HermesBoots},{id.ShinyRedBalloon}`, "slot 6 is closed")
		inventory.hidden = 1
		t.eq(Accessories.looks(inventory), `{armor},{id.ShinyRedBalloon}`, "slot 1 hidden: not drawn")
		-- A vanity accessory shows over its row, even when the row's accessory is hidden.
		inventory.vanityAccessories[1] = stack("Flipper")
		t.eq(Accessories.looks(inventory), `{armor},{id.Flipper},{id.ShinyRedBalloon}`, "vanity over hidden")
		-- The same item twice is drawn once; vanity rows are never closed.
		inventory.vanityAccessories[2] = stack("Flipper")
		inventory.vanityAccessories[7] = stack("CobaltShield")
		t.eq(Accessories.looks(inventory), `{armor},{id.Flipper},{id.CobaltShield}`, "once each")
		-- Back to ids.
		local ids = Accessories.parseLooks(Accessories.looks(inventory))
		t.eq(#ids, 6)
		t.eq(ids[1], head)
		t.eq(ids[2], chest)
		t.eq(ids[5], id.Flipper)
		t.eq(ids[6], id.CobaltShield)
		-- Nonsense reads as nothing worn (a client never trusts an attribute's text).
		for _, bad in { nil :: any, 5, "", "a,b", "99999,1.5,-3", string.rep("1,", 200) } do
			local parsed = Accessories.parseLooks(bad)
			t.ok(#parsed == 4 and parsed[1] == 0 and parsed[4] == 0, `{bad} reads as nothing`)
		end
		local mixed = Accessories.parseLooks(`{head},x,{chest},0,{id.Dirt},{id.HermesBoots},{id.IronHelmet}`)
		t.eq(mixed[1], head)
		t.eq(mixed[2], 0, "x is nothing")
		t.eq(#mixed, 5, "dirt and a helmet are no accessories to draw")
		t.eq(mixed[5], id.HermesBoots)
	end)

	t.test("accessories: tooltips say what each does", function()
		local function says(name: string, text: string)
			local lines = Accessories.tooltip(id[name])
			t.eq(lines[1], "When worn:", `{name}'s first line`)
			t.ok(table.find(lines, text) ~= nil, `{name} says "{text}": {table.concat(lines, " / ")}`)
		end
		says("HermesBoots", "Sprinting builds up to 40% faster")
		says("CloudInABottle", "Jump once more in the air")
		says("ShinyRedBalloon", "Jump higher (as Jump Boost I)")
		says("LuckyHorseshoe", "No fall damage")
		says("Aglet", "+5% movement speed")
		says("AnkletOfTheWind", "+10% movement speed")
		says("BandOfRegeneration", "Heals half a heart every 10 seconds")
		says("BandOfStarpower", "+20 max mana")
		says("ObsidianSkull", "+1 Armor")
		says("ObsidianSkull", "Campfires don't hurt")
		says("Flipper", "Swims 100% faster")
		says("CobaltShield", "No knockback")
		says("FeralClaws", "+12% attack speed")
		t.eq(Accessories.tooltip(id.TopHat)[1], "Vanity: worn for its look only")
		t.eq(#Accessories.tooltip(id.Dirt), 0)
		t.eq(#Accessories.tooltip(id.IronHelmet), 0, "armor's lines are the armor tooltip's")
	end)

	t.test("accessories: speed factor, knockback share, attack speed and regeneration", function()
		local inventory = Types.newInventory()
		local stats = Accessories.stats(inventory)
		t.eq(Accessories.speedFactor(stats), 1, "nothing worn")
		t.eq(Accessories.knockbackShare(stats), 1)
		inventory.accessories[1] = stack("HermesBoots")
		inventory.accessories[2] = stack("Aglet")
		inventory.accessories[3] = stack("AnkletOfTheWind")
		inventory.accessories[4] = stack("CobaltShield")
		Accessories.stats(inventory, stats)
		t.near(Accessories.speedFactor(stats), 1.15 * 1.4, 1e-9, "1.61: MoveCheck's factor")
		t.eq(Accessories.knockbackShare(stats), 0, "the shield holds all of it")
		-- Feral Claws: a sword (1.6 attacks a second) recovers in 12.5 ticks, with the claws in
		-- 12.5 / 1.12; ticks seen faster give the same strength as a faster weapon.
		local Combat = require(shared.Entities.Combat)
		for _, ticks in { 0, 3, 7, 11 } do
			t.near(
				Combat.strength(Accessories.hasteTicks(ticks, 0.12), 1.6),
				Combat.strength(ticks, 1.6 * 1.12),
				1e-9,
				`{ticks} ticks`
			)
		end
		t.eq(Accessories.hasteTicks(5, 0), 5, "no claws: as before")
		t.ok(Combat.strength(Accessories.hasteTicks(11, 0.12), 1.6) >= 1, "full strength after 11 ticks, not 12.5")
		-- A Band of Regeneration: a half heart every 200 ticks while hurt; stopping starts over.
		inventory.accessories[5] = stack("BandOfRegeneration")
		Accessories.stats(inventory, stats)
		local ticks, healed = 0, 0
		for _ = 1, 1000 do
			local h
			ticks, h = Accessories.regenerate(stats, ticks, true)
			healed += h
		end
		t.eq(healed, 5, "1000 ticks: five half hearts")
		ticks = 150
		ticks, healed = Accessories.regenerate(stats, ticks, false)
		t.eq(ticks, 0, "full health (or creative): the count starts over")
		t.eq(healed, 0)
		inventory.accessories[5] = nil
		Accessories.stats(inventory, stats)
		t.eq(select(2, Accessories.regenerate(stats, 199, true)), 0, "no band, no healing")
	end)

	t.test("accessories: the server's inventory: open slots by Age, has, death drops", function()
		local state = InventoryState.new()
		state:join("p")
		local window = state:window("p") :: any
		t.eq(window.inventory.accessorySlots, 5)
		state:takeDirty()
		t.ok(state:setAccessorySlots("p", 6), "the Industrial Age")
		t.eq(window.inventory.accessorySlots, 6)
		t.eq(#state:takeDirty(), 1, "a snapshot is due")
		t.ok(not state:setAccessorySlots("p", 6), "the same: nothing")
		t.eq(#state:takeDirty(), 0)
		state:setAccessorySlots("p", 99)
		t.eq(window.inventory.accessorySlots, Types.ACCESSORY_SIZE, "at most 7")
		state:setAccessorySlots("p", -3)
		t.eq(window.inventory.accessorySlots, 0)
		t.ok(not state:setAccessorySlots("p", 0 / 0), "NaN: nothing")
		t.ok(not state:setAccessorySlots("nobody", 6))
		-- Inventory.contains looks into every compartment.
		window.inventory.vanityAccessories[3] = stack("FeralClaws")
		t.ok(state:has("p", id.FeralClaws), "in a vanity slot")
		window.inventory.accessories[1] = stack("Aglet")
		t.ok(state:has("p", id.Aglet), "in an accessory slot")
		t.ok(not state:has("p", id.HermesBoots))
		-- Dying without keepInventory drops the equipment; keeping it keeps it.
		local kept = state:die("p", true)
		t.eq(#kept, 0)
		t.ok(window.inventory.accessories[1] ~= nil, "kept")
		local dropped = state:die("p", false)
		t.eq(#dropped, 2, "the accessory and the vanity accessory")
		t.eq(window.inventory.accessories[1], nil)
	end)

	t.test("accessories: an Obsidian Skull walks on campfires; lava and fire still hurt", function()
		local Burning = require(server.Players.Burning)
		local GameMode = require(shared.GameMode)
		local SURVIVAL = GameMode.SURVIVAL
		local function hurtBy(touching: number, fireWalk: boolean): number
			local state = Burning.newPlayer()
			local total = 0
			for _ = 1, 40 do
				total += Burning.tickPlayer(state, SURVIVAL, touching, 0, 0, nil, fireWalk)
			end
			return total
		end
		t.ok(hurtBy(Burning.CAMPFIRE, false) > 0, "a campfire hurts")
		t.eq(hurtBy(Burning.CAMPFIRE, true), 0, "not with fireWalk")
		t.ok(hurtBy(Burning.FIRE, true) > 0, "a fire block still does")
		local Fluids = require(shared.Fluids)
		local lava = bit32.lshift(1, Fluids.LAVA)
		t.eq(hurtBy(lava, true), hurtBy(lava, false), "lava as ever")
	end)

	-- Other players' air jumps (Player/AirJumps), from poses as Player/RemoteMotion draws them.
	do
		local AirJumps = require(client.Player.AirJumps)
		local PlayerSync = require(shared.Net.PlayerSync)
		local Flag = PlayerSync.Flag
		local TICK = 1 / 20

		type Pose = { y: number, flags: number }

		-- A remote player's poses, one a tick, with Minecraft's jump numbers: `jumps[k]` presses
		-- jump on tick k (from the ground: 0.42; in the air: 0.36, while `airJumps` last); the floor
		-- is at 0, or at `ledge` until tick `ledgeEnd` (walking off it). Jumped stays on 0.31 s.
		local function poses(
			jumps: { [number]: boolean },
			ticks: number,
			airJumps: number,
			flying: boolean?,
			ledge: number?,
			ledgeEnd: number?
		): { Pose }
			local list = {}
			local y, vy = ledge or 0, 0
			local onGround, left, jumpedAt = true, airJumps, -math.huge
			for k = 1, ticks do
				local floor = if ledge and ledgeEnd and k < ledgeEnd then ledge else 0
				if jumps[k] and onGround then
					vy, jumpedAt = 0.42, k
				elseif jumps[k] and left > 0 then
					vy, jumpedAt, left = 0.36, k, left - 1
				end
				y += vy
				if y <= floor then
					y, vy, onGround, left = floor, 0, true, airJumps
				else
					onGround = false
				end
				vy = (vy - 0.08) * 0.98
				local flags = 0
				if onGround then
					flags = bit32.bor(flags, Flag.OnGround)
				end
				if (k - jumpedAt) * TICK < 0.31 then
					flags = bit32.bor(flags, Flag.Jumped)
				end
				if flying then
					flags = bit32.bor(flags, Flag.Flying)
				end
				list[k] = { y = y, flags = flags }
			end
			return list
		end

		-- Draws them at `fps` frames a second, from `phase` (seconds) on: feet lerped between the
		-- two poses around each frame, the nearer one's flags; the times of the air jumps seen.
		local function watch(list: { Pose }, fps: number, phase: number): { number }
			local seen = {}
			local w = AirJumps.new()
			local frame = 0
			while true do
				local now = phase + frame / fps
				local p = now / TICK + 1
				local k = math.floor(p)
				if k + 1 > #list then
					break
				end
				local alpha = p - k
				local a, b = list[k], list[k + 1]
				local y = a.y + (b.y - a.y) * alpha
				local flags = if alpha < 0.5 then a.flags else b.flags
				if AirJumps.step(w, flags, y, now) then
					table.insert(seen, now)
				end
				frame += 1
			end
			return seen
		end

		-- Every frame rate and phase sees the air jumps at ticks `at`, each within 0.1 s of its rise
		-- (tick k's pose is drawn at (k - 1) TICK, so its rise starts a tick before).
		local function sees(list: { Pose }, at: { number }, what: string)
			for _, fps in { 30, 60, 144 } do
				for _, phase in { 0, 0.004, 0.013, 0.021, 0.037 } do
					local seen = watch(list, fps, phase)
					t.eq(#seen, #at, `{what}: {fps} fps, phase {phase}: {#seen} air jumps`)
					for i, k in at do
						local when = (k - 2) * TICK
						if seen[i] then
							t.ok(
								seen[i] > when and seen[i] <= when + 0.1,
								`{what}: {fps} fps: air jump {i} at {seen[i]} for {when}`
							)
						end
					end
				end
			end
		end

		t.test("air jumps: others' air jumps are told from their poses, never their ground jumps", function()
			sees(poses({ [3] = true }, 60, 1), {}, "a ground jump")
			sees(poses({ [3] = true, [30] = true }, 80, 1), {}, "two ground jumps")
			sees(poses({ [3] = true, [9] = true }, 60, 1), { 9 }, "at the top (Jumped still on)")
			sees(poses({ [3] = true, [14] = true }, 60, 1), { 14 }, "falling (a new Jumped)")
			sees(poses({ [3] = true, [9] = true, [20] = true }, 80, 2), { 9, 20 }, "two in one flight")
			sees(poses({ [3] = true, [9] = true, [40] = true, [46] = true }, 100, 1), { 9, 46 }, "again after landing")
			sees(poses({ [12] = true }, 60, 1, false, 10, 5), { 12 }, "walking off a ledge")
			sees(poses({ [3] = true, [9] = true }, 60, 1, true), {}, "flying")
			-- Too soon after the ground: the ground jump's own rise, never an air jump.
			sees(poses({ [3] = true, [5] = true }, 60, 1), {}, "0.1 s after leaving the ground")
		end)

		t.test("air jumps: a first frame, a repeated time or NaN show nothing", function()
			local w = AirJumps.new()
			t.ok(not AirJumps.step(w, Flag.Jumped, 0, 1), "the first frame")
			t.ok(not AirJumps.step(w, Flag.Jumped, 5, 1), "the same time")
			t.ok(not AirJumps.step(w, Flag.Jumped, 0 / 0, 2), "NaN")
			t.ok(not AirJumps.step(w, Flag.Jumped, 1, 3), "after NaN: no speed yet")
			-- Off the ground long enough, a rise flagged Jumped counts once, then the cooldown.
			t.ok(not AirJumps.step(w, 0, 1, 3.5))
			t.ok(AirJumps.step(w, Flag.Jumped, 1.5, 3.55), "a rise of 10 blocks a second")
			t.ok(not AirJumps.step(w, Flag.Jumped, 1.5, 3.6))
			t.ok(not AirJumps.step(w, Flag.Jumped, 2, 3.65), "within the cooldown")
			-- In water a rise is swimming.
			AirJumps.step(w, 0, 2, 4.5)
			t.ok(not AirJumps.step(w, bit32.bor(Flag.Jumped, Flag.InWater), 2.5, 4.55), "in water")
		end)
	end
end
