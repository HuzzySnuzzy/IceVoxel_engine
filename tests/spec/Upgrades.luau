--[[
	Mekanism's upgrade cards (Shared/Machines/Upgrades, ItemList SpeedUpgrade / EnergyUpgrade): the
	items and their recipes, Mekanism's maths (ticks, energy per tick, capacity, production), the
	upgrade slots' rules (only the slot's own card, 8 at most, by hand and shift-click, never by
	transporters) and what the cards do in the Electric Furnace (fewer ticks, more or less energy a
	tick, a bigger store), its panel's upgrade slots with their outlines.
]]

return function(t, shared, require, server, client)
	local Blocks = require(shared.Blocks)
	local Crafting = require(shared.Crafting)
	local Items = require(shared.Items)
	local Machines = require(shared.Machines)
	local Upgrades = require(shared.Machines.Upgrades)
	local Menu = require(shared.Inventory.Menu)
	local Transmitters = require(shared.Transmitters)
	local Types = require(shared.Inventory.Types)
	local JeiData = require(client.Ui.Jei.JeiData)
	local MenuLayout = require(client.Ui.MenuLayout)

	local B = Blocks.id
	local I = Items.id
	local SPEED, ENERGY = I.SpeedUpgrade, I.EnergyUpgrade
	local FURNACE = B.ElectricFurnace
	local SOLAR = B.SolarPanel
	local ENERGY_INDEX = Machines.ENERGY
	-- The Electric Furnace's slots.
	local INPUT, OUTPUT, SPEED_SLOT, ENERGY_SLOT = 1, 2, 3, 4

	local function S(item: number, count: number)
		return { item = item, count = count }
	end

	local function ctx(block: number): any
		return {
			block = block,
			x = 0,
			y = 64,
			z = 0,
			energy = Machines.energyOf(block),
			tick = 1,
			dayTime = 6000,
			getBlock = function()
				return nil
			end,
		}
	end

	local function tick(container: any, n: number?)
		for _ = 1, n or 1 do
			Machines.tick(container, ctx(container.block))
		end
	end

	local function craft(rows: { { number? } }): any
		local stacks = {}
		for row = 1, 3 do
			for column = 1, 3 do
				local item = rows[row][column]
				if item then
					stacks[(row - 1) * 3 + column] = S(item, 1)
				end
			end
		end
		return Crafting.match(stacks, 3)
	end

	--[[ The cards ]]

	t.test("upgrades: the Speed and Energy Upgrade cards", function()
		t.eq(Items.displayName(SPEED), "Speed Upgrade")
		t.eq(Items.displayName(ENERGY), "Energy Upgrade")
		t.eq(Items.maxStack(SPEED), 8, "Mekanism's 8 a machine takes")
		t.eq(Items.maxStack(ENERGY), 8)
		t.ok(SPEED >= Items.ITEM_BASE and ENERGY >= Items.ITEM_BASE, "items, not blocks")
		t.ok(#Items.get(SPEED).model > 4 and #Items.get(ENERGY).model > 4, "a card with its symbol")
		t.eq(Upgrades.SPEED, SPEED)
		t.eq(Upgrades.ENERGY, ENERGY)
		t.ok(Upgrades.isSpeed(SPEED) and not Upgrades.isSpeed(ENERGY))
		t.ok(Upgrades.isEnergy(ENERGY) and not Upgrades.isEnergy(SPEED))
		t.ok(Upgrades.isUpgrade(SPEED) and Upgrades.isUpgrade(ENERGY) and not Upgrades.isUpgrade(I.GoldIngot))
		t.eq(Upgrades.MAX, 8)
		t.eq(Upgrades.MULTIPLIER, 10, "Mekanism's maxUpgradeMultiplier")
		-- Their outlines: 16 x 16 pixel art.
		for _, art in { Upgrades.SPEED_GHOST, Upgrades.ENERGY_GHOST } do
			t.eq(#art, 16)
			local pixels = 0
			for _, row in art do
				t.eq(#row, 16)
				t.ok(string.match(row, "^[%.G]+$") ~= nil, "dots and G only")
				pixels += select(2, string.gsub(row, "G", ""))
			end
			t.ok(pixels > 20, "something to see")
		end
	end)

	t.test("upgrades: Mekanism's recipes with glass, gold and osmium", function()
		local G, A, O = I.Glass, I.GoldIngot, I.OsmiumIngot
		local speed = craft({ { nil, G, nil }, { A, O, A }, { nil, G, nil } })
		t.eq(speed and speed.item, SPEED)
		t.eq(speed and speed.count, 1)
		t.eq(speed and speed.data, nil)
		local energy = craft({ { nil, G, nil }, { A, A, A }, { nil, G, nil } })
		t.eq(energy and energy.item, ENERGY, "gold for the gold dust")
		t.eq(energy and energy.count, 1)
		t.eq(craft({ { nil, G, nil }, { A, I.IronIngot, A }, { nil, G, nil } }), nil, "iron is no dust here")
		t.eq(craft({ { nil, I.Sand, nil }, { A, O, A }, { nil, G, nil } }), nil, "glass at the top and bottom")
		t.eq(craft({ { nil, G, nil }, { O, O, O }, { nil, G, nil } }), nil, "gold stands for the alloy")
		-- Survival can make every ingredient: glass smelts from sand, osmium from its ore.
		local Smelting = require(shared.Crafting.Smelting)
		t.eq(Smelting.result(I.Sand).item, G)
		t.eq(Smelting.result(I.RawOsmium).item, O)
		t.eq(Smelting.result(I.RawGold).item, A)
		-- JEI shows how to make them.
		local function makes(item: number): boolean
			for _, group in JeiData.recipes(item) do
				if group.category == "crafting" and #group.entries > 0 then
					return true
				end
			end
			return false
		end
		t.ok(makes(SPEED) and makes(ENERGY), "JEI lists their recipes")
	end)

	--[[ Mekanism's maths ]]

	t.test("upgrades: Mekanism's maths: ticks, energy per tick, capacity, production", function()
		-- MekanismUtils.getTicks: 200 x 10^(-speed/8), truncated.
		local ticks = { [0] = 200, 149, 112, 84, 63, 47, 35, 26, 20 }
		for speed = 0, 8 do
			t.eq(Upgrades.ticks(200, speed), ticks[speed], `{speed} Speed Upgrades`)
		end
		t.eq(Upgrades.ticks(1, 8), 1, "never below a tick")
		t.eq(Upgrades.ticks(200, 50), 20, "more than 8 count as 8")
		t.eq(Upgrades.ticks(200, -3), 200, "fewer than none count as none")
		-- getEnergyPerTick: 50 x 10^((2 speed - energy)/8).
		t.eq(Upgrades.energyPerTick(50, 0, 0), 50)
		t.near(Upgrades.energyPerTick(50, 1, 0), 88.914, 1e-3)
		t.near(Upgrades.energyPerTick(50, 4, 0), 500, 1e-9, "half the cards: ten times")
		t.near(Upgrades.energyPerTick(50, 8, 0), 5000, 1e-9, "all 8: a hundred times")
		t.near(Upgrades.energyPerTick(50, 0, 8), 5, 1e-9, "energy cards alone: a tenth")
		t.near(Upgrades.energyPerTick(50, 8, 8), 500, 1e-9, "both: ten times")
		t.near(Upgrades.energyPerTick(50, 4, 8), 50, 1e-9, "4 speed and 8 energy cancel out")
		-- getMaxEnergy: base x 10^(energy/8).
		t.eq(Upgrades.capacity(20000, 0), 20000)
		t.near(Upgrades.capacity(20000, 1), 26670.43, 0.01)
		t.near(Upgrades.capacity(20000, 8), 200000, 1e-6)
		t.near(Upgrades.capacity(96000, 8), 960000, 1e-6)
		-- The Solar Panel's production: base x 10^(speed/8).
		t.eq(Upgrades.production(50, 0), 50)
		t.near(Upgrades.production(50, 4), 158.11, 0.01)
		t.near(Upgrades.production(50, 8), 500, 1e-9)
		-- Counting the cards of a slot.
		t.eq(Upgrades.installed(nil, SPEED), 0)
		t.eq(Upgrades.installed(S(SPEED, 5), SPEED), 5)
		t.eq(Upgrades.installed(S(SPEED, 5), ENERGY), 0, "only the slot's own card")
		t.eq(Upgrades.installed(S(I.Dirt, 5), SPEED), 0)
		t.eq(Upgrades.installed(S(SPEED, 64), SPEED), 8, "at most 8, whatever a stack says")
		t.eq(Upgrades.installed(S(SPEED, 2.5), SPEED), 2)
		t.eq(Upgrades.installed(S(SPEED, 0 / 0), SPEED), 0)
		t.eq(Upgrades.installed(S(SPEED, -4), SPEED), 0)
		local container: any = Machines.newContainer(FURNACE)
		container.slots[SPEED_SLOT] = S(SPEED, 3)
		container.slots[ENERGY_SLOT] = S(ENERGY, 7)
		local speed, energy = Upgrades.counts(container, SPEED_SLOT, ENERGY_SLOT)
		t.eq(speed, 3)
		t.eq(energy, 7)
		-- The slots it gives a kind.
		local slots = Upgrades.slots(8, 53)
		t.eq(#slots, 2)
		t.eq(slots[1].x, 8)
		t.eq(slots[2].x, 26, "one slot to the right")
		t.eq(slots[1].limit, 8)
		t.eq(#(slots[1].insert :: any), 0, "transporters never put cards in")
		t.eq(slots[1].ghost, Upgrades.SPEED_GHOST)
		t.eq(slots[2].ghost, Upgrades.ENERGY_GHOST)
		-- `define` refuses an outline bigger than a slot (and defines nothing then).
		local tall = table.create(17, "G")
		t.ok(not pcall(Machines.define, "upgradesTestTall", { slots = { { x = 0, y = 0, ghost = tall } } }))
		t.ok(
			not pcall(Machines.define, "upgradesTestWide", { slots = { { x = 0, y = 0, ghost = { ("G"):rep(17) } } } })
		)
		t.eq(Machines.kind("upgradesTestTall"), nil)
		t.eq(Machines.kind("upgradesTestWide"), nil)
	end)

	--[[ Upgrade slots ]]

	t.test("upgrades: the slots take their own card only, 8 at most, by hand and shift-click", function()
		for _, block in { FURNACE, SOLAR } do
			local speedSlot = if block == FURNACE then SPEED_SLOT else 1
			local energySlot = speedSlot + 1
			local name = Blocks.get(block).name
			t.ok(Machines.mayPlace(block, speedSlot, SPEED), `{name}: speed slot`)
			t.ok(not Machines.mayPlace(block, speedSlot, ENERGY), `{name}: no energy card in it`)
			t.ok(not Machines.mayPlace(block, speedSlot, I.RawIron), `{name}: nothing else`)
			t.ok(Machines.mayPlace(block, energySlot, ENERGY), `{name}: energy slot`)
			t.ok(not Machines.mayPlace(block, energySlot, SPEED))
			t.eq(Machines.slotLimit(block, speedSlot, SPEED), 8)
			t.eq(Machines.slotLimit(block, energySlot, ENERGY), 8)
			t.eq(table.concat(Machines.quickMoveTargets(block, SPEED), ","), tostring(speedSlot))
			t.eq(table.concat(Machines.quickMoveTargets(block, ENERGY), ","), tostring(energySlot))
			-- Transporters never reach them.
			for face = 0, 5 do
				t.ok(not table.find(Machines.insertSlots(block, face), speedSlot), `{name}: face {face}`)
				t.ok(not table.find(Machines.insertSlots(block, face), energySlot))
				t.ok(not table.find(Machines.extractSlots(block, face), speedSlot))
				t.ok(not table.find(Machines.extractSlots(block, face), energySlot))
				local _, left = Transmitters.insert(block, face, {}, S(SPEED, 2))
				t.eq(left and left.count, 2, `{name}: a transporter's cards stay on the way`)
			end
		end
		t.eq(#Machines.quickMoveTargets(FURNACE, I.GoldIngot), 0)
		t.ok(Transmitters.isItemAcceptor(FURNACE), "the furnace's other slots still take items")

		-- Through Inventory/Menu, as the client predicts and the server runs it.
		local container = Machines.newContainer(FURNACE)
		local inventory = Types.newInventory()
		local window: any = { id = 1, inventory = inventory, container = container }
		local function slotOf(index: number): number
			return Menu.windowIndex(window, "inventory", index) :: number
		end
		inventory.slots[1] = S(SPEED, 8)
		inventory.slots[2] = S(SPEED, 3)
		inventory.slots[3] = S(ENERGY, 8)
		Menu.apply(window, { kind = "click", window = 1, slot = slotOf(1), clickType = 1, button = 0 }, false)
		t.eq(container.slots[SPEED_SLOT] and container.slots[SPEED_SLOT].count, 8, "shift-click: into the speed slot")
		t.eq(container.slots[INPUT], nil, "not into the input")
		t.eq(inventory.slots[1], nil)
		Menu.apply(window, { kind = "click", window = 1, slot = slotOf(2), clickType = 1, button = 0 }, false)
		t.eq(container.slots[SPEED_SLOT].count, 8, "full at 8")
		local spare = 0
		for _, stack in inventory.slots do
			if stack and stack.item == SPEED then
				spare += stack.count
			end
		end
		t.eq(spare, 3, "the rest stay in the inventory")
		Menu.apply(window, { kind = "click", window = 1, slot = slotOf(3), clickType = 1, button = 0 }, false)
		t.eq(container.slots[ENERGY_SLOT] and container.slots[ENERGY_SLOT].count, 8, "energy cards: their own slot")
		-- By hand: a click puts the cursor's cards in, up to 8; the wrong card isn't taken.
		local fresh = Machines.newContainer(FURNACE)
		local hand: any = { id = 2, inventory = Types.newInventory(), container = fresh }
		hand.inventory.cursor = S(ENERGY, 5)
		Menu.apply(hand, { kind = "click", window = 2, slot = SPEED_SLOT - 1, clickType = 0, button = 0 }, false)
		t.eq(fresh.slots[SPEED_SLOT], nil, "no energy card in the speed slot")
		t.eq(hand.inventory.cursor and hand.inventory.cursor.count, 5)
		hand.inventory.cursor = S(SPEED, 5)
		Menu.apply(hand, { kind = "click", window = 2, slot = SPEED_SLOT - 1, clickType = 0, button = 0 }, false)
		t.eq(fresh.slots[SPEED_SLOT] and fresh.slots[SPEED_SLOT].count, 5)
		t.eq(hand.inventory.cursor, nil)
		hand.inventory.cursor = S(SPEED, 5)
		Menu.apply(hand, { kind = "click", window = 2, slot = SPEED_SLOT - 1, clickType = 0, button = 0 }, false)
		t.eq(fresh.slots[SPEED_SLOT].count, 8, "topped up to 8")
		t.eq(hand.inventory.cursor and hand.inventory.cursor.count, 2)
		-- And taken out again by hand.
		hand.inventory.cursor = nil
		Menu.apply(hand, { kind = "click", window = 2, slot = SPEED_SLOT - 1, clickType = 0, button = 0 }, false)
		t.eq(fresh.slots[SPEED_SLOT], nil)
		t.eq(hand.inventory.cursor and hand.inventory.cursor.count, 8)
	end)

	--[[ The Electric Furnace with cards ]]

	t.test("upgrades: Speed Upgrades make the Electric Furnace faster and hungrier", function()
		local container: any = Machines.newContainer(FURNACE)
		container.slots[INPUT] = S(I.RawIron, 4)
		container.slots[SPEED_SLOT] = S(SPEED, 8)
		container.data[ENERGY_INDEX] = 20000
		tick(container)
		t.eq(Machines.get(container, "ticksRequired"), 20, "8 cards: 20 ticks an item")
		t.eq(Machines.get(container, "energyPerTick"), 5000, "at 5 kJ a tick")
		t.eq(Machines.capacity(container), 20000)
		t.eq(Machines.get(container, "rate"), -5000)
		t.eq(Machines.status(FURNACE, Machines.view(container)), "Using 5 kJ/t")
		tick(container, 3)
		t.eq(Machines.energy(container), 0, "four ticks empty its store")
		tick(container)
		t.eq(Machines.status(FURNACE, Machines.view(container)), "No power")
		-- With power the item is done in 20 ticks: 100 kJ.
		local fed: any = Machines.newContainer(FURNACE)
		fed.slots[INPUT] = S(I.RawIron, 4)
		fed.slots[SPEED_SLOT] = S(SPEED, 8)
		for i = 1, 20 do
			fed.data[ENERGY_INDEX] = 20000
			tick(fed)
			if i < 20 then
				t.eq(fed.slots[OUTPUT], nil, `tick {i}`)
			end
		end
		t.eq(fed.slots[OUTPUT] and fed.slots[OUTPUT].count, 1, "the 20th tick smelts it")
		-- One card: 149 ticks at 88.9 J a tick (each a whole tick's energy, quantised up).
		local one: any = Machines.newContainer(FURNACE)
		one.slots[INPUT] = S(I.Sand, 2)
		one.slots[SPEED_SLOT] = S(SPEED, 1)
		one.data[ENERGY_INDEX] = 20000
		tick(one, 148)
		t.eq(one.slots[OUTPUT], nil)
		tick(one)
		t.eq(one.slots[OUTPUT] and one.slots[OUTPUT].item, I.Glass, "149 ticks")
		local per = Machines.quantiseUp(Upgrades.energyPerTick(50, 1, 0))
		t.eq(Machines.energy(one), 20000 - 149 * per, "energy is exact")
		t.eq(-Machines.get(one, "rate"), per)
		t.eq(Machines.status(FURNACE, Machines.view(one)), `Using {Items.formatEnergy(per)}/t`)
	end)

	t.test("upgrades: Energy Upgrades make it thriftier and its store bigger", function()
		local container: any = Machines.newContainer(FURNACE)
		container.slots[INPUT] = S(I.RawIron, 2)
		container.slots[ENERGY_SLOT] = S(ENERGY, 8)
		-- (More than its base store: the cards make room for it in the same tick.)
		container.data[ENERGY_INDEX] = 150000
		tick(container)
		t.eq(Machines.capacity(container), 200000, "8 cards: ten times the store")
		t.eq(Machines.get(container, "energyPerTick"), 5, "and a tenth of the energy")
		t.eq(Machines.get(container, "ticksRequired"), 200, "at the same speed")
		local input = Machines.rates(container)
		t.eq(input, 200000, "a network may fill the bigger store in a tick")
		tick(container, 199)
		t.eq(container.slots[OUTPUT] and container.slots[OUTPUT].count, 1, "an item for 1 kJ")
		t.eq(Machines.energy(container), 150000 - 200 * 5)
		-- Both: 8 and 8 make it 10 times faster at 10 times the energy a tick (the same per item).
		local both: any = Machines.newContainer(FURNACE)
		both.slots[INPUT] = S(I.RawIron, 2)
		both.slots[SPEED_SLOT] = S(SPEED, 8)
		both.slots[ENERGY_SLOT] = S(ENERGY, 8)
		both.data[ENERGY_INDEX] = 200000
		tick(both)
		t.eq(Machines.capacity(both), 200000)
		t.eq(Machines.get(both, "energyPerTick"), 500)
		tick(both, 19)
		t.eq(both.slots[OUTPUT] and both.slots[OUTPUT].count, 1)
		t.eq(Machines.energy(both), 200000 - 20 * 500, "10 kJ an item, as without cards")
		-- Taking the cards out: the store shrinks back and what is over it is lost (Mekanism's
		-- setMaxEnergy); a progress past the new ticks finishes on the next tick.
		both.slots[ENERGY_SLOT] = nil
		both.slots[SPEED_SLOT] = nil
		tick(both)
		t.eq(Machines.capacity(both), 20000)
		t.eq(Machines.energy(both), 20000 - 50, "cut to its base store, then a tick's work")
		t.eq(Machines.get(both, "progress"), 1)
		local fast: any = Machines.newContainer(FURNACE)
		fast.slots[INPUT] = S(I.RawIron, 2)
		fast.data[ENERGY_INDEX] = 20000
		tick(fast, 150)
		t.eq(Machines.get(fast, "progress"), 150)
		fast.slots[SPEED_SLOT] = S(SPEED, 8)
		tick(fast)
		t.eq(fast.slots[OUTPUT] and fast.slots[OUTPUT].count, 1, "past 20 ticks already: done at once")
		t.eq(Machines.get(fast, "progress"), 0)
		-- Cards from elsewhere count up to 8 only.
		local forged: any = Machines.newContainer(FURNACE)
		forged.slots[SPEED_SLOT] = S(SPEED, 64)
		forged.slots[ENERGY_SLOT] = S(SPEED, 8)
		tick(forged)
		t.eq(Machines.get(forged, "ticksRequired"), 20)
		t.eq(Machines.capacity(forged), 20000, "speed cards in the energy slot do nothing")
	end)

	--[[ What players see ]]

	t.test("upgrades: the furnace's panel shows its upgrade slots with their outlines", function()
		local container: any = Machines.newContainer(FURNACE)
		local panel = MenuLayout.panel(container)
		t.eq(#panel.slots, 4)
		local speed, energy = panel.slots[3], panel.slots[4]
		t.eq(speed.slot, SPEED_SLOT)
		t.eq(speed.x, 8)
		t.eq(speed.y, 53)
		t.eq(speed.ghost, Upgrades.SPEED_GHOST, "the chevrons while empty")
		t.eq(energy.slot, ENERGY_SLOT)
		t.eq(energy.x, 26)
		t.eq(energy.y, 53)
		t.eq(energy.ghost, Upgrades.ENERGY_GHOST, "the bolt")
		t.eq(panel.slots[1].ghost, nil, "the input has none")
		-- Clear of the status line, the row, the energy bar and the panel's edge (78 high).
		local bar = panel.energy :: any
		for _, slot in { speed, energy } do
			t.ok(slot.y + 17 <= panel.height - 7, "inside the panel")
			t.ok(slot.x + 17 < 55, "left of the input's frame")
			t.ok(slot.x + 17 < bar.x)
		end
		t.ok((panel.status :: any).y + 8 < speed.y - 1, "below the status line")
	end)
end
