--[[
	Progression: knowledge (Minecraft's experience curve, the sources, discoveries once ever,
	repeats with their fatigue, the per-minute budget and the carried fractions, nothing for placed
	blocks: EditRules.placed), the Ages (their data against the game's items and recipes, the
	requirements and advancing, rewards opening the next), the recipe gate (Inventory/Menu: a
	locked crafting result never offered and never taken, furnaces and machines taking no input
	that smelts into a locked result, merges too, windows without a gate and creative players
	making everything, the server's onTake for crafts and outputs, the client prediction's gate,
	JEI's lock data), the skill tree (data, unlocking: Age, prerequisites, points), every perk's
	effect where it applies (knowledge, Shared/Mining's factor on the client's progress and the
	server's check, wear, thirst's rate, insulation on the temperature target, the campfire's
	boiling), death's loss, the saved record (round trip, migration-safe reading), the protocol
	(Progress and UnlockSkill round trips, malformed messages) and the /knowledge and /age
	commands.
]]

return function(t, shared, require, server, client)
	local Blocks = require(shared.Blocks)
	local Crafting = require(shared.Crafting)
	local GameMode = require(shared.GameMode)
	local Items = require(shared.Items)
	local Menu = require(shared.Inventory.Menu)
	local Mining = require(shared.Mining)
	local Progression = require(shared.Progression)
	local Protocol = require(shared.Net.Protocol)
	local Smelting = require(shared.Crafting.Smelting)
	local Sounds = require(shared.Sounds)
	local Types = require(shared.Inventory.Types)
	local Boiling = require(shared.ToughAsNails.Boiling)
	local Temperature = require(shared.ToughAsNails.Temperature)
	local Thirst = require(shared.ToughAsNails.Thirst)
	local Biomes = require(shared.Biomes)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local EditRules = require(server.Network.EditRules)
	local ProgressionCommand = require(server.Players.ProgressionCommand)
	local Prediction = require(client.Inventory.Prediction)
	local JeiData = require(client.Ui.Jei.JeiData)

	local Knowledge = Progression.Knowledge
	local Ages = Progression.Ages
	local Skills = Progression.Skills
	local I = Items.id
	local SURVIVAL = GameMode.SURVIVAL
	local Click = Menu.ClickType
	local LEFT = 0
	local BUDGET = 20

	local function S(item: number, count: number)
		return { item = item, count = count }
	end

	local function fresh()
		return Progression.new(), Knowledge.newSession()
	end

	-- A state in the Age with id `id` (reached the way /age set does).
	local function inAge(id: string)
		local state, session = fresh()
		Progression.setAge(state, (Ages.byId(id) :: any).index)
		return state, session
	end

	local function gateOf(state)
		return function(item: number): boolean
			return Progression.allows(state, item)
		end
	end

	--[[ Knowledge ]]

	t.test("knowledge: Minecraft's experience curve (2L+7, 5L-38, 9L-158)", function()
		t.eq(Knowledge.needed(0), 7)
		t.eq(Knowledge.needed(14), 35)
		t.eq(Knowledge.needed(15), 37, "5L - 38 from 15")
		t.eq(Knowledge.needed(29), 107)
		t.eq(Knowledge.needed(30), 112, "9L - 158 from 30")
		t.eq(Knowledge.needed(31), 121)
		-- Minecraft's totals: L^2 + 6L to 16, 2.5L^2 - 40.5L + 360 to 31, 4.5L^2 - 162.5L + 2220.
		for level = 0, 60 do
			local expected = if level <= 16
				then level * level + 6 * level
				elseif level <= 31 then 2.5 * level * level - 40.5 * level + 360
				else 4.5 * level * level - 162.5 * level + 2220
			t.eq(Knowledge.total(level), expected, `total at level {level}`)
		end
		t.eq(Knowledge.total(5), 55)
		t.eq(Knowledge.total(15), 315)
		t.eq(Knowledge.total(25), 910)
		t.eq(Knowledge.total(40), 2920)
		t.eq(Knowledge.levelOf(0), 0)
		t.eq(Knowledge.levelOf(6), 0)
		t.eq(Knowledge.levelOf(7), 1)
		t.eq(Knowledge.levelOf(2919), 39)
		t.eq(Knowledge.levelOf(2920), 40)
		t.eq(Knowledge.levelOf(-5), 0)
		t.eq(Knowledge.levelOf(0 / 0), 0)
		t.eq(Knowledge.levelOf(math.huge), Knowledge.MAX_LEVEL)
		local level, into, needed = Knowledge.progress(60)
		t.eq(level, 5)
		t.eq(into, 5)
		t.eq(needed, 17)
	end)

	t.test("knowledge: discoveries once ever, by category", function()
		local state, session = fresh()
		t.eq(Progression.discover(state, session, "mine", "Stone"), 5, "a block kind: 5")
		t.eq(Progression.discover(state, session, "mine", "Stone"), 0, "only once")
		t.eq(Progression.discover(state, session, "craft", "Planks"), 8)
		t.eq(Progression.discover(state, session, "smelt", "Glass"), 10)
		t.eq(Progression.discover(state, session, "biome", "Plains"), 20)
		t.eq(Progression.discover(state, session, "mob", "Zombie"), 10)
		t.eq(Progression.discover(state, session, "newThing", "x"), Knowledge.DEFAULT_DISCOVERY, "any category")
		t.eq(Progression.discover(state, session, "age", "iron"), 50, "an Age: its reward")
		t.eq(state.points, 5 + 8 + 10 + 20 + 10 + 5 + 50)
		t.eq(Progression.count(state, "mine"), 1)
		t.ok(Progression.found(state, "craft", "Planks"))
		t.eq(Progression.discover(state, session, "mine", ""), 0, "no empty keys")
		t.eq(Progression.discover(state, session, "mine", string.rep("x", 65)), 0, "no long keys")
	end)

	t.test("knowledge: repeats wear off with fatigue and recover with time", function()
		local session = Knowledge.newSession()
		t.near(Knowledge.repeatPoints(session, "ore:IronOre", 2, 0, BUDGET), 2, 1e-9, "the first")
		t.near(Knowledge.repeatPoints(session, "ore:IronOre", 2, 0, BUDGET), 1.5, 1e-9, "x 0.75")
		t.near(Knowledge.repeatPoints(session, "ore:IronOre", 2, 0, BUDGET), 1.125, 1e-9, "x 0.75 again")
		t.near(Knowledge.repeatPoints(session, "ore:CoalOre", 1, 0, BUDGET), 1, 1e-9, "another thing: fresh")
		-- 3 repeats of fatigue; 120 s later 2 have worn off.
		t.near(Knowledge.repeatPoints(session, "ore:IronOre", 2, 120, BUDGET), 2 * 0.75, 1e-9, "recovering")
		t.near(Knowledge.repeatPoints(session, "ore:IronOre", 2, 10000, BUDGET), 2, 1e-9, "fully rested")
		t.eq(Knowledge.repeatPoints(session, "ore:IronOre", 0, 10000, BUDGET), 0, "nothing for nothing")
	end)

	t.test("knowledge: the per-minute budget caps all repeats together, refilling smoothly", function()
		local session = Knowledge.newSession()
		local total = 0
		for i = 1, 100 do
			total += Knowledge.repeatPoints(session, `key{i}`, 5, 0, 20)
		end
		t.near(total, 20, 1e-9, "a minute's budget at once at most")
		t.eq(Knowledge.repeatPoints(session, "more", 5, 0, 20), 0, "then nothing")
		t.near(Knowledge.repeatPoints(session, "more2", 5, 30, 20), 5, 1e-9, "half a minute later: 10 back, 5 taken")
		t.near(Knowledge.repeatPoints(session, "more3", 50, 30, 20), 5, 1e-9, "the rest of it")
		-- Perks multiply before the bucket: the cap holds with every knowledge perk. An ore every
		-- 10 s, the six kinds in turn, for 10 minutes.
		local ORES = { "CoalOre", "IronOre", "OsmiumOre", "GoldOre", "DiamondOre", "EmeraldOre" }
		local function minute(perks: boolean): number
			local state, mining = fresh()
			if perks then
				for _, id in { "prospector", "scholar", "polymath", "enlightenment" } do
					state.skills[id] = true
				end
			end
			-- (The steady rate: from the third minute on, the discoveries and the first full
			-- bucket behind.)
			local before = 0
			for i = 1, 60 do
				if i == 13 then
					before = state.points
				end
				Progression.mined(state, mining, ORES[(i - 1) % 6 + 1], false, i * 10, 20)
			end
			return (state.points - before) / 8
		end
		local plain, perked = minute(false), minute(true)
		t.ok(plain <= 20 + 1e-9, `{plain} points a minute without perks`)
		t.ok(perked <= 20 + 0.5, `{perked} points a minute with every knowledge perk: still the 20`)
		t.ok(perked > plain, "the perks still help under the cap")
	end)

	t.test("knowledge: fractions carry over, perks multiply their source", function()
		local state, session = fresh()
		for _ = 1, 3 do
			t.eq(Progression.award(state, session, 0.25, "mine"), 0, "a quarter waits")
		end
		t.eq(Progression.award(state, session, 0.25, "mine"), 1, "four make one")
		t.eq(state.points, 1)
		t.eq(Progression.award(state, session, -3, "mine"), 0, "nothing negative")
		t.eq(Progression.award(state, session, 0 / 0, "mine"), 0, "nothing NaN")
		state.skills.forager = true
		t.near(Progression.knowledgeFactor(state, "discovery"), 1.1, 1e-9, "Forager: discoveries")
		t.near(Progression.knowledgeFactor(state, "ore"), 1, 1e-9, "not ores")
		state.skills.prospector = true
		t.near(Progression.knowledgeFactor(state, "ore"), 2, 1e-9, "Prospector: ores twice")
		state.skills.scholar = true
		t.near(Progression.knowledgeFactor(state, "ore"), 2.1, 1e-9, "Scholar adds to everything")
		t.near(Progression.knowledgeFactor(state, "discovery"), 1.2, 1e-9)
		state.skills.polymath, state.skills.enlightenment = true, true
		t.near(Progression.knowledgeFactor(state, "craft"), 1.5, 1e-9, "Scholar, Polymath, Enlightenment")
		t.eq(Progression.knowledgeFactor(nil, "craft"), 1)
		-- Forager on a discovery: 5 x 1.1 = 5.5, the half carried.
		local foraging, carry = fresh()
		foraging.skills.forager = true
		t.eq(Progression.discover(foraging, carry, "mine", "Dirt"), 5)
		t.eq(Progression.discover(foraging, carry, "mine", "Sand"), 6, "the halves add up")
	end)

	t.test("knowledge: mining, crafting, smelting, visiting and killing", function()
		local state, session = fresh()
		t.eq(Progression.mined(state, session, "IronOre", false, 0, BUDGET), 5 + 2, "discovery and the ore")
		t.eq(Progression.mined(state, session, "IronOre", false, 0, BUDGET), 1, "1.5: one now")
		t.eq(Progression.mined(state, session, "Stone", false, 0, BUDGET), 5, "stone: the discovery only")
		t.eq(Progression.mined(state, session, "Stone", false, 0, BUDGET), 0, "then nothing")
		t.eq(Progression.mined(state, session, "DiamondOre", true, 0, BUDGET), 0, "placed: nothing at all")
		t.ok(not Progression.found(state, "mine", "DiamondOre"), "no discovery either")
		-- Logs: a quarter each.
		local logs, logSession = fresh()
		Progression.mined(logs, logSession, "OakLog", false, 0, BUDGET)
		t.eq(logs.points, 5, "the discovery, a quarter waiting")
		t.eq(Knowledge.minePoints("BirchLog"), 0.25)
		t.eq(Knowledge.minePoints("DiamondOre"), 5)
		-- Crafting and smelting.
		local maker, makerSession = fresh()
		t.eq(Progression.crafted(maker, makerSession, "Furnace", 0, BUDGET), 8)
		t.eq(Progression.smelted(maker, makerSession, "IronIngot", 10, 0, BUDGET), 10 + 7, "0.7 an ingot")
		t.eq(Progression.smelted(maker, makerSession, "Glass", 10, 0, BUDGET), 10 + 1, "0.1 a glass")
		t.eq(Progression.visited(maker, makerSession, "Plains"), 20)
		t.eq(Progression.visited(maker, makerSession, "Plains"), 0)
		t.eq(Progression.killed(maker, makerSession, "Zombie", 0, BUDGET), 10 + 5, "a monster: 5")
		t.eq(Progression.killed(maker, makerSession, "Sheep", 0, BUDGET), 10 + 2, "an animal: 2")
		t.eq(Knowledge.mobPoints("Dragon"), Knowledge.MOB_DEFAULT)
	end)

	t.test("knowledge: no points for blocks placed after generation (the edit list)", function()
		local size = ChunkLayout.SIZE
		local edits: { [string]: { [number]: number } } = {
			["0,0"] = { [ChunkLayout.localIndex(3, 20, 4)] = Blocks.id.IronOre },
			["-1,0"] = { [ChunkLayout.localIndex(size - 1, 5, 2)] = Blocks.id.Cobblestone },
		}
		local world = {
			chunkEdits = function(_, cx, cz)
				return edits[`{cx},{cz}`]
			end,
		}
		t.ok(EditRules.placed(world :: any, 3, 20, 4, Blocks.id.IronOre), "in the edit list")
		t.ok(not EditRules.placed(world :: any, 3, 20, 4, Blocks.id.Stone), "another block there now")
		t.ok(not EditRules.placed(world :: any, 3, 21, 4, Blocks.id.IronOre), "generated")
		t.ok(not EditRules.placed(world :: any, 100, 20, 4, Blocks.id.IronOre), "a chunk without edits")
		t.ok(EditRules.placed(world :: any, -1, 5, 2, Blocks.id.Cobblestone), "negative coordinates")
	end)

	--[[ Ages ]]

	t.test("ages: data (names are items with recipes; Stone Age essentials open)", function()
		t.eq(Ages.count, 5)
		t.eq(Ages.list[1].id, "stone")
		local results: { [number]: boolean } = {}
		for _, recipe in Crafting.recipes do
			results[recipe.result] = true
		end
		for _, recipe in Smelting.recipes() do
			results[recipe.result.item] = true
		end
		for name, index in Ages.names() do
			local ok, id = pcall(function()
				return I[name]
			end)
			t.ok(ok and id, `{name} is an item`)
			t.ok(results[id], `{name} is made by a recipe`)
			t.ok(index > 1, `{name} is past the Stone Age`)
		end
		local previous = -1
		for index, age in Ages.list do
			t.eq(age.index, index)
			t.ok(age.level > previous, `{age.id}: levels rise`)
			previous = age.level
			for _, milestone in age.milestones do
				if milestone.key then
					t.ok(results[I[milestone.key]] or Blocks.id[milestone.key], `{milestone.key} can be done`)
				end
			end
		end
		local stone = Progression.new()
		for _, name in
			{
				"Planks",
				"Stick",
				"CraftingTable",
				"Chest",
				"Furnace",
				"WoodenPickaxe",
				"StonePickaxe",
				"StoneSword",
				"Torch",
				"Campfire",
				"Bowl",
				"GlassBottle",
				"MintTea",
				"StrawChestplate",
				"Glass",
				"IronIngot",
				"Charcoal",
				"PurifiedWaterBottle",
			}
		do
			t.ok(Progression.allows(stone, I[name]), `{name} in the Stone Age`)
		end
		for _, name in { "IronPickaxe", "Bucket", "GoldIngot", "Shears", "OsmiumIngot" } do
			t.ok(not Progression.allows(stone, I[name]), `{name} needs the Iron Age`)
		end
	end)

	t.test("ages: entered when the level and every milestone are met, rewards included", function()
		local state, session = fresh()
		t.eq(#Progression.advance(state, session), 0, "nothing yet")
		Progression.setPoints(state, Knowledge.total(5))
		t.eq(#Progression.advance(state, session), 0, "the level alone is not enough")
		Progression.discover(state, session, "craft", "Furnace")
		t.eq(#Progression.advance(state, session), 0, "one milestone")
		Progression.discover(state, session, "smelt", "IronIngot")
		local reached = Progression.advance(state, session)
		t.eq(#reached, 1)
		t.eq(reached[1].id, "iron")
		t.eq(state.age, 2)
		t.ok(Progression.found(state, "age", "iron"), "a discovery")
		t.eq(state.points, Knowledge.total(5) + 8 + 10 + 50, "the Iron Age's 50")
		-- Milestones met early wait for the level; several Ages at once when everything is there.
		local fast, fastSession = fresh()
		for _, pair in
			{
				{ "craft", "Furnace" },
				{ "smelt", "IronIngot" },
				{ "smelt", "OsmiumIngot" },
				{ "craft", "Bucket" },
			}
		do
			Progression.discover(fast, fastSession, pair[1], pair[2])
		end
		Progression.setPoints(fast, Knowledge.total(15))
		local both = Progression.advance(fast, fastSession)
		t.eq(#both, 2, "Iron and Industrial together")
		t.eq(fast.age, 3)
		-- The Electric Age: level 25 and a Heat Generator (no biomes to find).
		Progression.setPoints(fast, Knowledge.total(25))
		t.eq(#Progression.advance(fast, fastSession), 0, "no Heat Generator yet")
		Progression.discover(fast, fastSession, "craft", "HeatGenerator")
		t.eq(Progression.advance(fast, fastSession)[1].id, "electric", "a Heat Generator crafted")
		t.eq(#Progression.advance(fast, fastSession), 0, "the Atomic Age waits")
		-- /age set: up, with the Ages passed counted as reached.
		local set = Progression.new()
		Progression.setAge(set, 4)
		t.eq(set.age, 4)
		t.ok(Progression.found(set, "age", "industrial"))
		Progression.setAge(set, 99)
		t.eq(set.age, Ages.count, "clamped")
	end)

	--[[ Recipes ]]

	t.test("recipes: a locked crafting result is never offered, so never taken", function()
		local state = Progression.new()
		local window = Types.newWindow(Types.newInventory())
		window.container = Types.newCrafting("crafting", Blocks.id.CraftingTable)
		window.recipes = gateOf(state)
		local taken = {}
		window.onTake = function(kind, stack)
			table.insert(taken, { kind = kind, item = stack.item, count = stack.count })
		end
		local slots = window.container.slots
		slots[2], slots[3], slots[4] = S(I.IronIngot, 1), S(I.IronIngot, 1), S(I.IronIngot, 1)
		slots[6], slots[9] = S(I.Stick, 1), S(I.Stick, 1)
		Menu.updateCraft(window)
		t.eq(slots[1], nil, "the iron pickaxe is not offered in the Stone Age")
		local match = Crafting.match(
			{ S(I.IronIngot, 1), S(I.IronIngot, 1), S(I.IronIngot, 1), nil, S(I.Stick, 1), nil, nil, S(I.Stick, 1) },
			3
		)
		t.eq(match and match.item, I.IronPickaxe, "though the grid matches it")
		for _, clickType in { Click.Pickup, Click.QuickMove, Click.Throw } do
			Menu.apply(
				window,
				{ kind = "click", window = window.id, slot = 0, clickType = clickType, button = LEFT },
				false
			)
		end
		Menu.apply(window, { kind = "click", window = window.id, slot = 0, clickType = Click.Swap, button = 0 }, false)
		t.eq(window.inventory.cursor, nil, "nothing taken")
		t.eq(window.inventory.slots[1], nil, "nothing swapped out")
		t.eq(#taken, 0)
		t.eq(slots[2] and slots[2].count, 1, "the grid untouched")
		-- In the Iron Age it is.
		Progression.setAge(state, 2)
		Menu.updateCraft(window)
		t.eq(slots[1] and slots[1].item, I.IronPickaxe, "offered in the Iron Age")
		Menu.apply(
			window,
			{ kind = "click", window = window.id, slot = 0, clickType = Click.Pickup, button = LEFT },
			false
		)
		t.eq(window.inventory.cursor and window.inventory.cursor.item, I.IronPickaxe, "taken")
		t.eq(#taken, 1, "onTake heard it")
		t.eq(taken[1].kind, "craft")
		t.eq(taken[1].item, I.IronPickaxe)
		-- A copy keeps the gate (the client's prediction), not the server's onTake.
		local copy = Menu.copyWindow(window)
		t.eq(copy.recipes, window.recipes)
		t.eq(copy.onTake, nil)
	end)

	t.test("recipes: shift-click crafts tell onTake every round; no gate makes everything", function()
		local window = Types.newWindow(Types.newInventory())
		local taken = 0
		window.onTake = function(kind)
			if kind == "craft" then
				taken += 1
			end
		end
		window.container.slots[2] = S(I.OakLog, 3)
		Menu.updateCraft(window)
		t.eq(window.container.slots[1] and window.container.slots[1].item, I.Planks)
		Menu.apply(window, { kind = "click", window = 0, slot = 0, clickType = Click.QuickMove, button = LEFT }, false)
		t.eq(taken, 3, "three crafts")
		-- Without a gate (no player, creative) even the Nuke comes out.
		local free = Types.newWindow(Types.newInventory())
		free.container = Types.newCrafting("crafting", Blocks.id.CraftingTable)
		for i = 2, 10 do
			free.container.slots[i] = S(I.Tnt, 1)
		end
		free.container.slots[6] = S(I.DiamondBlock, 1)
		Menu.updateCraft(free)
		t.eq(free.container.slots[1] and free.container.slots[1].item, I.Nuke, "ungated")
		t.ok(Progression.allows(nil, I.Nuke), "a nil state allows everything")
	end)

	t.test("recipes: furnaces and machines take no input that smelts into a locked result", function()
		local state = Progression.new()
		local window = Types.newWindow(Types.newInventory())
		window.container =
			{ kind = "furnace", block = Blocks.id.Furnace, size = 3, slots = {}, data = Smelting.newData() }
		window.id = 1
		window.recipes = gateOf(state)
		local inventory = window.inventory
		t.ok(not Menu.mayPlace(window, 0, I.RawGold), "raw gold: gold ingots are the Iron Age's")
		t.ok(Menu.mayPlace(window, 0, I.RawIron), "raw iron: iron ingots are the Stone Age's")
		t.ok(Menu.mayPlace(window, 1, I.Coal), "fuel as ever")
		inventory.cursor = S(I.RawGold, 5)
		Menu.apply(window, { kind = "click", window = 1, slot = 0, clickType = Click.Pickup, button = LEFT }, false)
		t.eq(window.container.slots[1], nil, "not placed")
		t.eq(inventory.cursor and inventory.cursor.count, 5, "still carried")
		-- Shift-click from the inventory, and merging onto gold already in it (another player's).
		inventory.cursor = nil
		local first = Menu.windowIndex(window, "inventory", 1) :: number
		inventory.slots[1] = S(I.RawGold, 4)
		Menu.apply(
			window,
			{ kind = "click", window = 1, slot = first, clickType = Click.QuickMove, button = LEFT },
			false
		)
		t.eq(window.container.slots[1], nil, "shift-click: not into the input")
		window.container.slots[1] = S(I.RawGold, 2)
		Menu.apply(
			window,
			{ kind = "click", window = 1, slot = first, clickType = Click.QuickMove, button = LEFT },
			false
		)
		t.eq(window.container.slots[1].count, 2, "no merging either")
		inventory.slots[2] = S(I.RawIron, 3)
		local second = Menu.windowIndex(window, "inventory", 2) :: number
		window.container.slots[1] = nil
		Menu.apply(
			window,
			{ kind = "click", window = 1, slot = second, clickType = Click.QuickMove, button = LEFT },
			false
		)
		t.eq(window.container.slots[1] and window.container.slots[1].item, I.RawIron, "raw iron goes in")
		-- The Iron Age opens it.
		Progression.setAge(state, 2)
		t.ok(Menu.mayPlace(window, 0, I.RawGold))
		-- Machines: the Electric Furnace's input the same way.
		local machine = Types.newWindow(Types.newInventory())
		machine.container = { kind = "machine", block = Blocks.id.ElectricFurnace, size = 4, slots = {}, data = { 0 } }
		machine.recipes = gateOf(Progression.new())
		t.ok(not Menu.mayPlace(machine, 0, I.RawGold), "not into a smelting machine")
		t.ok(Menu.mayPlace(machine, 0, I.Sand), "sand smelts into glass, open")
		machine.recipes = nil
		t.ok(Menu.mayPlace(machine, 0, I.RawGold), "ungated")
	end)

	t.test("recipes: what is taken out of an output tells onTake (FurnaceResultSlot)", function()
		local window = Types.newWindow(Types.newInventory())
		window.container =
			{ kind = "furnace", block = Blocks.id.Furnace, size = 3, slots = {}, data = Smelting.newData() }
		window.id = 1
		local taken = {}
		window.onTake = function(kind, stack)
			table.insert(taken, { kind = kind, item = stack.item, count = stack.count })
		end
		window.container.slots[3] = S(I.IronIngot, 6)
		Menu.apply(window, { kind = "click", window = 1, slot = 2, clickType = Click.Pickup, button = 1 }, false)
		t.eq(#taken, 1)
		t.eq(taken[1].kind, "smelt")
		t.eq(taken[1].count, 3, "right click: half")
		Menu.apply(window, { kind = "click", window = 1, slot = 2, clickType = Click.QuickMove, button = LEFT }, false)
		t.eq(#taken, 2)
		t.eq(taken[2].count, 3, "the rest, shift-clicked")
		Menu.apply(window, { kind = "click", window = 1, slot = 0, clickType = Click.Pickup, button = LEFT }, false)
		t.eq(#taken, 2, "other slots: nothing")
	end)

	t.test("recipes: the client's prediction keeps the gate on every window", function()
		local prediction = Prediction.new()
		local state = Progression.new()
		prediction:setRecipes(gateOf(state), SURVIVAL)
		local inventory = Types.newInventory()
		inventory.slots[1] = S(I.IronIngot, 2)
		prediction:receive({
			ack = 0,
			inventory = inventory,
			window = 0,
			container = Types.newCrafting("inventory"),
		}, SURVIVAL)
		t.eq(prediction:window().recipes ~= nil, true, "a snapshot's window gets it")
		-- Shears (two iron ingots on a diagonal) in the 2 x 2 grid: predicted locked.
		local first = Menu.windowIndex(prediction:window(), "inventory", 1) :: number
		prediction:push({ kind = "click", window = 0, slot = first, clickType = Click.Pickup, button = LEFT }, SURVIVAL)
		prediction:push({ kind = "click", window = 0, slot = 2, clickType = Click.Pickup, button = 1 }, SURVIVAL)
		prediction:push({ kind = "click", window = 0, slot = 3, clickType = Click.Pickup, button = 1 }, SURVIVAL)
		local window = prediction:window()
		t.eq(window.container and window.container.slots[3] and window.container.slots[3].item, I.IronIngot)
		t.eq(window.container and window.container.slots[1], nil, "no shears predicted")
		Progression.setAge(state, 2)
		prediction:setRecipes(gateOf(state), SURVIVAL)
		local after = prediction:window()
		t.eq(
			after.container and after.container.slots[1] and after.container.slots[1].item,
			I.Shears,
			"after the Iron Age"
		)
	end)

	t.test("recipes: JEI's lock data and the lock texts", function()
		local state = Progression.new()
		local function entryOf(item: number, category: string)
			for _, group in JeiData.recipes(item) do
				if group.category == category then
					return group.entries[1]
				end
			end
			return nil
		end
		local pickaxe = assert(entryOf(I.IronPickaxe, "crafting"))
		t.eq(JeiData.lockText(pickaxe, state), "Requires the Iron Age")
		t.eq(JeiData.lockText(pickaxe, nil), nil, "no gate: no lock (creative)")
		t.eq(JeiData.lockText(assert(entryOf(I.StonePickaxe, "crafting")), state), nil)
		t.eq(JeiData.lockText(assert(entryOf(I.GoldIngot, "smelting")), state), "Requires the Iron Age")
		t.eq(JeiData.lockText(assert(entryOf(I.IronIngot, "smelting")), state), nil, "iron smelts in the Stone Age")
		t.eq(JeiData.lockText(assert(entryOf(I.Tnt, "crafting")), state), "Requires the Industrial Age and Demolition")
		Progression.setAge(state, 3)
		t.eq(JeiData.lockText(assert(entryOf(I.Tnt, "crafting")), state), "Requires Demolition")
		state.skills.demolition = true
		t.eq(JeiData.lockText(assert(entryOf(I.Tnt, "crafting")), state), nil)
		local age, skill = Progression.requirement(I.Nuke)
		t.eq(age and age.id, "atomic")
		t.eq(skill and skill.id, "fission")
		local none, noSkill = Progression.requirement(I.Torch)
		t.eq(none, nil)
		t.eq(noSkill, nil)
	end)

	--[[ Skills ]]

	t.test("skills: data (ids, rows, icons, prerequisites, costs)", function()
		t.ok(Skills.count >= 15, "a tree")
		t.eq(Skills.totalCost(), 51)
		for index = 1, Ages.count do
			local nodes = Skills.ofAge(index)
			t.ok(#nodes >= 3 and #nodes <= 6, `{Ages.list[index].id}: 3-6 nodes`)
		end
		for index, skill in Skills.list do
			t.eq(skill.index, index)
			t.eq(skill.cost, skill.age, `{skill.id} costs its Age's number`)
			local ok, id = pcall(function()
				return I[skill.icon]
			end)
			t.ok(ok and id, `{skill.id}'s icon {skill.icon} is an item`)
			t.ok(skill.perk.kind ~= "none" or #skill.recipes > 0, `{skill.id} does something`)
			for _, required in skill.requires do
				local before = Skills.byId(required)
				t.ok(before and before.index < index, `{skill.id} needs an earlier node`)
			end
			for _, name in skill.recipes do
				t.eq(select(2, Progression.requirement(I[name])), skill, `{name} needs {skill.id}`)
			end
		end
	end)

	t.test("skills: unlocking needs the Age, the prerequisites and the points", function()
		local state = Progression.new()
		local ok, reason = Progression.canUnlock(state, "forager")
		t.ok(not ok)
		t.eq(reason, "points", "level 0: no points")
		Progression.setPoints(state, Knowledge.total(3))
		t.eq(Progression.skillPoints(state), 3)
		t.ok((Progression.unlock(state, "forager")), "Forager")
		t.eq(Progression.skillPoints(state), 2)
		t.eq(select(2, Progression.unlock(state, "forager")), "unlocked", "only once")
		t.eq(select(2, Progression.canUnlock(state, "firekeeper")), "requires", "needs Hardy")
		t.eq(select(2, Progression.canUnlock(state, "prospector")), "age", "an Iron Age node")
		t.eq(select(2, Progression.canUnlock(state, "nope")), "unknown")
		t.ok((Progression.unlock(state, "hardy")))
		t.ok((Progression.unlock(state, "firekeeper")), "after Hardy")
		t.eq(Progression.skillPoints(state), 0)
		Progression.setAge(state, 2)
		local _, why, text = Progression.canUnlock(state, "prospector")
		t.eq(why, "points")
		t.eq(text, "Prospector costs 2 skill points")
		Progression.setPoints(state, Knowledge.total(5))
		t.ok((Progression.unlock(state, "prospector")), "an Iron Age node for 2")
		t.eq(Progression.spent(state), 5)
		-- Points below what was spent (a command): none to spend, nothing lost.
		Progression.setPoints(state, 0)
		t.eq(Progression.skillPoints(state), 0)
		t.ok(Progression.perk(state, "prospector"))
	end)

	--[[ Perks ]]

	t.test("perks: Quarrying, Ironworking, Diamond Cutting, Mastery (Mining's factor, both sides)", function()
		local state = Progression.new()
		t.eq(Progression.miningFactor(state, I.StonePickaxe), 1)
		state.skills.quarrying = true
		t.near(Progression.miningFactor(state, I.StonePickaxe), 1.1, 1e-9, "stone tools")
		t.near(Progression.miningFactor(state, I.StoneShovel), 1.1, 1e-9)
		t.eq(Progression.miningFactor(state, I.IronPickaxe), 1, "not iron")
		t.eq(Progression.miningFactor(state, nil), 1, "not bare hands")
		t.eq(Progression.miningFactor(state, I.Stick), 1, "not a stick")
		state.skills.ironworking = true
		t.near(Progression.miningFactor(state, I.GoldenPickaxe), 1.1, 1e-9, "golden tools")
		state.skills.mastery = true
		t.near(Progression.miningFactor(state, I.StonePickaxe), 1.21, 1e-9, "Mastery on top")
		t.near(Progression.miningFactor(state, I.DiamondPickaxe), 1.1, 1e-9)
		-- Stone with a stone pickaxe: 1.5 hardness, speed 4: 12 ticks; 4.4: 11.
		local stone, pickaxe = Blocks.id.Stone, I.StonePickaxe
		t.eq(Mining.ticks(stone, true, false, pickaxe), 12)
		local quick = Progression.new()
		quick.skills.quarrying = true
		local factor = Progression.miningFactor(quick, pickaxe)
		t.eq(Mining.ticks(stone, true, false, pickaxe, factor), 11, "a tick faster")
		t.near(
			Mining.progressPerTick(stone, true, false, pickaxe, factor),
			Mining.progressPerTick(stone, true, false, pickaxe) * 1.1,
			1e-12,
			"the client's progress"
		)
		-- The server's check (a full break, `needed` 1) accepts the faster break, not without the perk.
		t.ok(Mining.mayBreak(stone, 10 / 20, 1, pickaxe, factor), "after 11 ticks with the perk")
		t.ok(not Mining.mayBreak(stone, 10 / 20, 1, pickaxe), "not without")
		t.ok(Mining.mayBreak(stone, 11 / 20, 1, pickaxe), "after 12 without")
	end)

	t.test("perks: Smithing and Tempering skip wear points", function()
		local state = Progression.new()
		t.eq(Progression.wearChance(state), 0)
		t.eq(
			Progression.wear(state, 2, function()
				return 0
			end),
			2,
			"no perk: all of it"
		)
		state.skills.smithing = true
		t.near(Progression.wearChance(state), 0.15, 1e-9)
		t.eq(
			Progression.wear(state, 1, function()
				return 0.1
			end),
			0,
			"a roll under 0.15 skips it"
		)
		t.eq(
			Progression.wear(state, 1, function()
				return 0.2
			end),
			1,
			"over it lands"
		)
		state.skills.tempering = true
		t.near(Progression.wearChance(state), 1 - 0.85 * 0.85, 1e-9, "Tempering combines")
		local rolls, i = { 0.1, 0.5 }, 0
		t.eq(
			Progression.wear(state, 2, function()
				i += 1
				return rolls[i]
			end),
			1,
			"each point rolls"
		)
		-- On average 15% less (a fixed sequence of rolls: a linear congruential generator).
		local seed = 12345
		local function roll(): number
			seed = (seed * 1103515245 + 12345) % 2147483648
			return seed / 2147483648
		end
		local landed = 0
		local smith = Progression.new()
		smith.skills.smithing = true
		for _ = 1, 20000 do
			landed += Progression.wear(smith, 1, roll)
		end
		t.near(landed / 20000, 0.85, 0.01, "85% land")
	end)

	t.test("perks: Hardy and Endurance slow thirst (Thirst.tick's rate)", function()
		local state = Progression.new()
		t.eq(Progression.thirstRate(state), 1)
		state.skills.hardy = true
		t.near(Progression.thirstRate(state), 0.9, 1e-9)
		-- 4 exhaustion is a point without the perk; with it 4 / 0.9.
		local plain, hardy = Thirst.new(), Thirst.new()
		Thirst.addExhaustion(plain, 4.2)
		Thirst.addExhaustion(hardy, 4.2)
		Thirst.tick(plain, SURVIVAL, 20, 20)
		Thirst.tick(hardy, SURVIVAL, 20, 20, 0, false, false, Progression.thirstRate(state))
		t.eq(plain.hydration, 4, "a point")
		t.eq(hardy.hydration, 5, "not yet with Hardy")
		Thirst.addExhaustion(hardy, 0.3)
		Thirst.tick(hardy, SURVIVAL, 20, 20, 0, false, false, Progression.thirstRate(state))
		t.eq(hardy.hydration, 4, "past 4.44")
		-- Over a long drain: about 10% slower.
		local a, b = Thirst.new(), Thirst.new()
		for _ = 1, 100 do
			Thirst.addExhaustion(a, 0.5)
			Thirst.addExhaustion(b, 0.5)
			Thirst.tick(a, SURVIVAL, 20, 20)
			Thirst.tick(b, SURVIVAL, 20, 20, 0, false, false, 0.9)
		end
		local lostA = (20 + 5) - (a.thirst + a.hydration)
		local lostB = (20 + 5) - (b.thirst + b.hydration)
		t.near(lostB / lostA, 0.9, 0.05, "10% slower")
		state.skills.endurance = true
		t.near(Progression.thirstRate(state), 0.81, 1e-9, "Endurance multiplies")
	end)

	t.test("perks: Insulation and Thermoregulation pull the temperature towards neutral", function()
		local state = Progression.new()
		t.eq(Progression.insulation(state), 0)
		state.skills.insulation = true
		t.eq(Progression.insulation(state), 1)
		local function target(climate: number, steps: number): number
			return Temperature.target(
				{
					climate = climate,
					y = 80,
					surface = 80,
					skyOpen = true,
					night = false,
					wet = false,
					sprinting = false,
					heated = false,
					nearHeat = false,
					cooled = false,
					burning = false,
					armorWarmth = steps,
					armorCooling = steps,
				} :: any,
				nil
			)
		end
		local tundra = (Biomes.byName("Tundra") :: any).temperature
		local desert = (Biomes.byName("Desert") :: any).temperature
		t.eq(target(tundra, 0), -10)
		t.eq(target(tundra, Progression.insulation(state)), -9, "a step warmer in the cold")
		t.eq(target(desert, Progression.insulation(state)), target(desert, 0) - 1, "a step cooler in the heat")
		state.skills.thermoregulation = true
		t.eq(Progression.insulation(state), 2)
		t.eq(target(tundra, Progression.insulation(state)), -8)
	end)

	t.test("perks: Firekeeper boils water on a campfire twice as fast (Boiling.ready)", function()
		local state = Progression.new()
		t.eq(Progression.boilSpeed(state), 1)
		t.ok(not Boiling.ready(1.6, Boiling.LEEWAY, Progression.boilSpeed(state)), "3 s without")
		state.skills.firekeeper = true
		t.eq(Progression.boilSpeed(state), 2)
		t.ok(Boiling.ready(1.5, nil, Progression.boilSpeed(state)), "1.5 s with it")
		t.ok(not Boiling.ready(1.4, nil, Progression.boilSpeed(state)))
		t.ok(Boiling.ready(1.3, Boiling.LEEWAY, Progression.boilSpeed(state)), "the server's leeway")
		t.ok(Boiling.ready(3, nil, nil), "unchanged without a speed")
	end)

	t.test("perks: Demolition and Fission unlock their recipes besides the Age", function()
		local state = Progression.new()
		Progression.setAge(state, Ages.count)
		t.ok(not Progression.allows(state, I.Gunpowder), "the Age is not enough")
		t.ok(not Progression.allows(state, I.Tnt))
		state.skills.demolition = true
		t.ok(Progression.allows(state, I.Gunpowder))
		t.ok(Progression.allows(state, I.Tnt))
		t.ok(not Progression.allows(state, I.Nuke))
		state.skills.fission = true
		t.ok(Progression.allows(state, I.Nuke))
		local early = Progression.new()
		early.skills.demolition = true
		t.ok(not Progression.allows(early, I.Tnt), "the skill alone is not enough either")
	end)

	--[[ Death, saving, the protocol ]]

	t.test("death: Config.Progression.DeathLoss of the progress into the level, never levels", function()
		local state = Progression.new()
		Progression.setPoints(state, Knowledge.total(10) + 20)
		Progression.die(state, 0)
		t.eq(state.points, Knowledge.total(10) + 20, "0: kept")
		Progression.die(state, 0.5)
		t.eq(state.points, Knowledge.total(10) + 10, "half the progress")
		Progression.die(state, 1)
		t.eq(state.points, Knowledge.total(10), "never below the level")
		Progression.die(state, 0 / 0)
		t.eq(state.points, Knowledge.total(10))
	end)

	t.test("saving: the record round trip, and odd records read safely", function()
		local state, session = inAge("industrial")
		Progression.setPoints(state, 1234)
		state.skills.forager, state.skills.hardy = true, true
		Progression.discover(state, session, "mine", "Stone")
		Progression.discover(state, session, "biome", "Plains")
		local record = Progression.toRecord(state)
		t.eq(record.v, 1)
		t.eq(record.age, "industrial", "by id")
		t.eq(record.skills[1], "forager", "sorted ids")
		local back = Progression.fromRecord(record)
		t.eq(back.points, state.points)
		t.eq(back.age, 3)
		t.ok(back.skills.forager and back.skills.hardy)
		t.ok(Progression.found(back, "mine", "Stone"))
		t.ok(Progression.found(back, "age", "iron"))
		for _, junk in { 5, "x", {}, { v = 2, points = 99 }, { v = 1, points = "lots" } } do
			local read = Progression.fromRecord(junk)
			t.eq(read.points, 0, "a fresh start")
			t.eq(read.age, 1)
		end
		-- Saved over: nothing saved, or a record of this version; never another version's (a newer
		-- server's, during an update) nor anything unreadable.
		t.eq(select(2, Progression.fromRecord(nil)), true, "nothing saved yet")
		t.eq(select(2, Progression.fromRecord(record)), true, "this version")
		t.eq(select(2, Progression.fromRecord({ v = 1, points = "lots" })), true, "this version, odd fields")
		for _, other in { { v = 2, points = 99 }, { v = 0 }, {}, 5, "x" } do
			t.eq(select(2, Progression.fromRecord(other)), false, "kept for the build that reads it")
		end
		t.eq(Progression.fromRecord(nil).points, 0, "nil: a fresh start")
		local odd = Progression.fromRecord({
			v = 1,
			points = 1e12,
			age = "steam",
			skills = { "forager", "teleportation", 5 },
			found = { mine = { "Stone", 7, string.rep("x", 100) }, [5] = { "a" }, craft = "Planks" },
		})
		t.eq(odd.points, Knowledge.MAX_POINTS, "clamped")
		t.eq(odd.age, 1, "an unknown Age: the Stone Age (reached again by advance)")
		t.ok(odd.skills.forager and odd.skills.teleportation == nil, "unknown skills dropped")
		t.eq(Progression.count(odd, "mine"), 1, "bad keys dropped")
		t.eq(odd.found.craft, nil)
		t.eq(Progression.fromRecord({ v = 1, points = -5 }).points, 0)
		t.eq(Progression.fromRecord({ v = 1, points = 0 / 0 }).points, 0)
		t.eq(Progression.fromRecord({ v = 1, points = 10.7 }).points, 10, "whole points")
	end)

	t.test("protocol: Progress and UnlockSkill round trips, malformed messages", function()
		t.eq(Protocol.ClientMessage.UnlockSkill, 20, "appended after Eat")
		t.eq(Protocol.ServerMessage.Progress, 20, "appended after Effects")
		local state, session = inAge("iron")
		Progression.setPoints(state, 777)
		state.skills.forager, state.skills.smithing = true, true
		Progression.discover(state, session, "craft", "Furnace")
		Progression.discover(state, session, "smelt", "OsmiumIngot")
		Progression.discover(state, session, "biome", "Plains")
		local status = Progression.status(state)
		local b = Protocol.encodeProgress(status)
		local back = assert(Protocol.decodeProgress(b))
		t.eq(back.points, status.points)
		t.eq(back.age, 2)
		t.ok(back.skills.forager and back.skills.smithing and not back.skills.hardy)
		t.eq(back.counts.craft, 1)
		t.eq(back.counts.biome, 1)
		t.eq(back.counts.age, 1, "the Iron Age")
		for i, met in status.milestones do
			t.eq(back.milestones[i], met, `milestone {i}`)
		end
		t.ok(back.milestones[1], "a Furnace crafted")
		t.ok(not back.milestones[2], "no Iron Ingot smelted")
		t.ok(back.milestones[3], "an Osmium Ingot smelted")
		-- Malformed: short, a bad Age, a bad skill, the wrong lengths.
		t.eq(Protocol.decodeProgress(buffer.create(3)), nil)
		local badAge = buffer.create(buffer.len(b))
		buffer.copy(badAge, 0, b)
		buffer.writeu8(badAge, 4, Ages.count + 1)
		t.eq(Protocol.decodeProgress(badAge), nil, "no such Age")
		local badSkill = buffer.create(buffer.len(b))
		buffer.copy(badSkill, 0, b)
		buffer.writeu8(badSkill, 6, 250)
		t.eq(Protocol.decodeProgress(badSkill), nil, "no such skill")
		local long = buffer.create(buffer.len(b) + 1)
		buffer.copy(long, 0, b)
		t.eq(Protocol.decodeProgress(long), nil, "too long")
		local tooMany = buffer.create(buffer.len(b))
		buffer.copy(tooMany, 0, b)
		buffer.writeu32(tooMany, 0, Knowledge.MAX_POINTS + 1)
		t.eq(Protocol.decodeProgress(tooMany), nil, "too many points")
		-- UnlockSkill.
		local skill = assert(Skills.byId("firekeeper"))
		t.eq(Protocol.decodeUnlockSkill(Protocol.encodeUnlockSkill(skill.index)), skill.index)
		t.eq(Protocol.decodeUnlockSkill(Protocol.encodeUnlockSkill(0)), nil)
		t.eq(Protocol.decodeUnlockSkill(Protocol.encodeUnlockSkill(Skills.count + 1)), nil)
		t.eq(Protocol.decodeUnlockSkill(buffer.create(2)), nil)
		-- The client's state from a status allows and perks alike.
		local client = Progression.fromStatus(back)
		t.ok(Progression.allows(client, I.IronPickaxe))
		t.near(Progression.wearChance(client), 0.15, 1e-9)
	end)

	t.test("sounds: knowledge, levels and Ages have their events", function()
		for _, name in { "entity.experience_orb.pickup", "entity.player.levelup", "ui.toast.challenge_complete" } do
			local event = Sounds.get(name)
			t.ok(event, name)
			t.eq(event and event.side, "client", `{name}: the player's own client`)
		end
	end)

	--[[ Commands ]]

	t.test("commands: /knowledge and /age (admins change, anyone asks)", function()
		local steve, alex =
			{ key = "steve", name = "Steve", displayName = "Steve" }, {
				key = "alex",
				name = "Alex",
				displayName = "Alex",
			}
		local states = { steve = Progression.new(), alex = Progression.new() }
		local function run(text: string, mayUse: boolean?, source: any?)
			return ProgressionCommand.run(text, {
				source = source or steve,
				players = { steve, alex },
				mayUse = mayUse ~= false,
				stateOf = function(key)
					return states[key]
				end,
			})
		end
		t.eq(run("hello"), nil, "not a command")
		t.ok(ProgressionCommand.matches("/xp add @s 5"))
		t.ok(ProgressionCommand.matches("/AGE query alex"))
		t.eq(run("/knowledge add @s 100", false).feedback[1], ProgressionCommand.DENIED, "not an admin")
		t.eq(states.steve.points, 0)
		-- Where progress is saved for every server, an operator who is not one of the game's own
		-- is told why (Players/Progression passes `denied`).
		local saved = ProgressionCommand.run("/age set @s iron", {
			source = steve,
			players = { steve, alex },
			mayUse = false,
			denied = ProgressionCommand.SAVED_DENIED,
			stateOf = function(key)
				return states[key]
			end,
		}) :: any
		t.eq(saved.feedback[1], ProgressionCommand.SAVED_DENIED)
		t.eq(states.steve.age, 1, "unchanged")
		t.eq(run("/knowledge query alex", false).feedback[1], "Alex has 0 knowledge points", "anyone asks")
		local result = run("/knowledge add @s 100")
		t.eq(states.steve.points, 100)
		t.eq(result.changed[1], "steve")
		t.eq(result.feedback[1], "Steve now has 7 levels (100 points), the Stone Age")
		run("/xp add Steve 2 levels")
		t.eq(Progression.level(states.steve), 9, "levels added")
		t.eq(states.steve.points - Knowledge.total(9), 100 - Knowledge.total(7), "the progress stays")
		run("/knowledge set @a 30 levels")
		t.eq(states.steve.points, Knowledge.total(30))
		t.eq(states.alex.points, Knowledge.total(30), "@a")
		run("/knowledge set alex 5")
		t.eq(states.alex.points, 5)
		run("/knowledge add alex -50")
		t.eq(states.alex.points, 0, "never below 0")
		t.eq(run("/knowledge query steve levels").feedback[1], "Steve has 30 knowledge levels")
		t.eq(run("/knowledge add @s 1.5").feedback[1], "'1.5' is no whole number")
		t.eq(run("/knowledge add @s").feedback[1], ProgressionCommand.KNOWLEDGE_USAGE)
		t.eq(run("/knowledge add @s 5 bananas").feedback[1], ProgressionCommand.KNOWLEDGE_USAGE)
		t.eq(run("/knowledge add nobody 5").feedback[1], "No player was found")
		-- /age.
		t.eq(run("/age set alex iron", false).feedback[1], ProgressionCommand.DENIED)
		run("/age set alex Iron Age")
		t.eq(states.alex.age, 2, "by name")
		run("/age set alex industrial")
		t.eq(states.alex.age, 3, "by id")
		run("/age set alex 5")
		t.eq(states.alex.age, 5, "by number")
		t.eq(#run("/age set alex 5").lowered, 0, "not lower")
		local down = run("/age set alex stone")
		t.eq(states.alex.age, 1, "down too")
		t.eq(down.lowered[1], "alex", "lowered: the glue checks no Ages now (they would undo it)")
		-- When the Ages are checked again (the next knowledge), they come back, none for the
		-- first time (nothing to announce, no reward again).
		Progression.setPoints(states.alex, Knowledge.total(40))
		local before = states.alex.points
		local back, first = Progression.advance(states.alex, Knowledge.newSession())
		t.eq(#back, 0, "the milestones were never met (set by command): it holds")
		t.eq(#first, 0)
		local held = Progression.new()
		Progression.setPoints(held, Knowledge.total(5))
		for _, pair in { { "craft", "Furnace" }, { "smelt", "IronIngot" } } do
			Progression.discover(held, Knowledge.newSession(), pair[1], pair[2])
		end
		local session = Knowledge.newSession()
		local _, news = Progression.advance(held, session)
		t.eq(#news, 1, "the Iron Age the first time: news")
		Progression.setAge(held, 1)
		local again, again1 = Progression.advance(held, session)
		t.eq(#again, 1, "entered again")
		t.eq(#again1, 0, "but not news, nor a reward again")
		t.eq(states.alex.points, before)
		t.eq(run("/age query alex", false).feedback[1], "Alex is in the Stone Age")
		t.ok(string.find(run("/age set alex steam").feedback[1], "Unknown Age", 1, true) ~= nil)
		t.eq(run("/age").feedback[1], ProgressionCommand.AGE_USAGE)
		-- Not loaded yet.
		states.alex = nil :: any
		t.eq(run("/knowledge add alex 5").feedback[1], ProgressionCommand.NOT_LOADED)
	end)
end
