--[[
	Tough As Nails: thirst (Minecraft's FoodData with water: exhaustion -> hydration -> thirst,
	the Thirst effect, regeneration that needs thirst, dehydration down to the floor, half the
	drain under Climate Clemency, the regeneration block that holds both thirst's and Roblox's
	regeneration for the zombie apocalypse's infection), drinks (hand, dirty, purified; their chances with an injected
	random; Internal Warmth and Chill; bottles and canteens filling and emptying, creative's
	rules; the container tables), movement exhaustion (Exertion: what the client measures, what
	the server allows), body temperature (the climate on the -10..10 scale and its zones, the
	modifiers in steps, armor insulation, the effects and the clemency's hold; the drift and the
	faster recovery; hypothermia and hyperthermia timing; the clemency's countdown), how long the
	harshest cold takes to kill (simulated tick by tick), the surroundings (Players/Climate over a
	fake world: heat and cold sources and their distance, a source's own radius, checks,
	insulation; the machines' heat, cold and room sources registered by the server, room sources
	whatever thirst and temperature say), the recipes (bottles, the canteen, purification by
	smelting) and the Protocol messages.
]]

local fs = require("@lune/fs")

return function(t, shared, require, server)
	local Biomes = require(shared.Biomes)
	local Blocks = require(shared.Blocks)
	local Config = require(shared.Config)
	local Crafting = require(shared.Crafting)
	local Fluids = require(shared.Fluids)
	local GameMode = require(shared.GameMode)
	local Items = require(shared.Items)
	local Protocol = require(shared.Net.Protocol)
	local Smelting = require(shared.Crafting.Smelting)
	local Sounds = require(shared.Sounds)
	local ToughAsNails = require(shared.ToughAsNails)
	local Climate = require(server.Players.Climate)

	local Thirst = ToughAsNails.Thirst
	local Temperature = ToughAsNails.Temperature
	local Drinks = ToughAsNails.Drinks
	local Exertion = ToughAsNails.Exertion
	local I, B = Items.id, Blocks.id
	local SURVIVAL, CREATIVE, ADVENTURE, SPECTATOR =
		GameMode.SURVIVAL, GameMode.CREATIVE, GameMode.ADVENTURE, GameMode.SPECTATOR
	local settings = Config.ToughAsNails

	-- Runs `f` with Config.ToughAsNails fields changed, then puts them back.
	local function with(changes: { [string]: any }, f: () -> ())
		local old = {}
		for key, value in changes do
			old[key] = settings[key]
			settings[key] = value
		end
		local ok, err = pcall(f)
		for key, value in old do
			settings[key] = value
		end
		if not ok then
			error(err, 0)
		end
	end

	-- A random that answers `values` in turn.
	local function rolls(values: { number }): () -> number
		local i = 0
		return function(): number
			i += 1
			return values[i]
		end
	end

	--[[ Thirst ]]

	t.test("thirst: exhaustion drains hydration first, then thirst (FoodData.tick)", function()
		local state = Thirst.new()
		t.eq(state.thirst, 20, "starts full")
		t.eq(state.hydration, 5, "with 5 hydration")
		Thirst.addExhaustion(state, 4)
		t.eq(select(1, Thirst.tick(state, SURVIVAL, 20, 20)), 0)
		t.eq(state.hydration, 5, "4: nothing yet (Minecraft's > 4)")
		Thirst.addExhaustion(state, 0.01)
		Thirst.tick(state, SURVIVAL, 20, 20)
		t.eq(state.hydration, 4, "above 4: a point of hydration")
		t.near(state.exhaustion, 0.01, 1e-9, "4 taken off")
		for _ = 1, 4 do
			Thirst.addExhaustion(state, 4)
			Thirst.tick(state, SURVIVAL, 20, 20)
		end
		t.eq(state.hydration, 0)
		t.eq(state.thirst, 20, "hydration goes first")
		Thirst.addExhaustion(state, 4)
		Thirst.tick(state, SURVIVAL, 20, 20)
		t.eq(state.thirst, 19, "then thirst")
		-- One step per tick, and the cap of 40.
		Thirst.addExhaustion(state, 100)
		t.eq(state.exhaustion, 40, "exhaustion caps at 40")
		Thirst.tick(state, SURVIVAL, 20, 20)
		t.eq(state.thirst, 18, "one point a tick")
		t.eq(state.exhaustion, 36)
		Thirst.addExhaustion(state, -5)
		Thirst.addExhaustion(state, 0 / 0)
		t.eq(state.exhaustion, 36, "nonsense adds nothing")
	end)

	t.test("thirst: drinking is FoodData.eat (hydration up to the new thirst)", function()
		local state = Thirst.new()
		state.thirst, state.hydration = 10, 0
		Thirst.drink(state, 4, 0.25)
		t.eq(state.thirst, 14)
		t.near(state.hydration, 2, 1e-9, "4 x 0.25 x 2")
		state.thirst, state.hydration = 18, 0
		Thirst.drink(state, 6, 0.4)
		t.eq(state.thirst, 20, "thirst caps at 20")
		t.near(state.hydration, 4.8, 1e-9)
		state.thirst, state.hydration = 2, 0
		Thirst.drink(state, 1, 5)
		t.eq(state.hydration, 3, "never above thirst")
		t.ok(not Thirst.canDrink(Thirst.new(), SURVIVAL), "full: no drinking")
		t.ok(Thirst.canDrink(Thirst.new(), CREATIVE), "creative always may (Player.canEat)")
		state.thirst = 19
		t.ok(Thirst.canDrink(state, ADVENTURE), "thirsty")
	end)

	t.test("thirst: the Thirst effect adds 0.015 exhaustion a tick and counts down", function()
		local state = Thirst.new()
		Thirst.giveEffect(state, 300)
		Thirst.giveEffect(state, 100)
		t.eq(state.effect, 300, "a longer one stays")
		for _ = 1, 280 do
			Thirst.tick(state, SURVIVAL, 20, 20)
		end
		t.eq(state.effect, 20)
		t.eq(state.hydration, 4, "280 x 0.015 = 4.2 exhaustion: a point")
		for _ = 1, 100 do
			Thirst.tick(state, SURVIVAL, 20, 20)
		end
		t.eq(state.effect, 0)
		t.eq(state.hydration, 4, "300 ticks: 4.5 exhaustion, a point and 0.5 left over")
		t.near(state.exhaustion, 0.5, 1e-6)
		-- The HOT zone's sweating is `extra`.
		local hot = Thirst.new()
		for _ = 1, 820 do
			Thirst.tick(hot, SURVIVAL, 20, 20, settings.HotExhaustion)
		end
		t.eq(hot.hydration, 4, "0.005 a tick: a point every 800 ticks")
	end)

	t.test("thirst: dehydration hurts every 120 ticks down to the floor (normal difficulty)", function()
		local state = Thirst.new()
		state.thirst, state.hydration = 0, 0
		local hurts = {}
		for tick = 1, 400 do
			local damage = Thirst.tick(state, SURVIVAL, 10, 20)
			if damage > 0 then
				table.insert(hurts, tick)
				t.eq(damage, 1, "half a heart")
			end
		end
		t.eq(#hurts, 3)
		t.eq(hurts[1], 120, "first at 120 ticks")
		t.eq(hurts[2], 240)
		local low = Thirst.new()
		low.thirst, low.hydration = 0, 0
		local total = 0
		for _ = 1, 400 do
			total += Thirst.tick(low, SURVIVAL, 1, 20)
		end
		t.eq(total, 0, "never below half a heart (health > 1)")
		with({ DehydrationFloor = 0 }, function()
			local hard = Thirst.new()
			hard.thirst, hard.hydration = 0, 0
			local hurt = 0
			for _ = 1, 120 do
				hurt += Thirst.tick(hard, SURVIVAL, 1, 20)
			end
			t.eq(hurt, 1, "floor 0: to death")
		end)
		-- Drinking stops it.
		Thirst.drink(state, 1, 0)
		local after = 0
		for _ = 1, 200 do
			after += Thirst.tick(state, SURVIVAL, 10, 20)
		end
		t.eq(after, 0)
	end)

	t.test("thirst: health comes back only with thirst 18+, for 6 exhaustion", function()
		local state = Thirst.new()
		local healed, at = 0, nil
		for tick = 1, 160 do
			local _, heal = Thirst.tick(state, SURVIVAL, 15, 20)
			healed += heal
			if heal > 0 and at == nil then
				at = tick
			end
		end
		t.eq(at, 80, "half a heart every 80 ticks")
		t.eq(healed, 2)
		t.eq(state.hydration, 4, "the first 6 cost a point the next tick")
		t.near(state.exhaustion, 8, 1e-9, "the second 6 waits for the next tick")
		local full = Thirst.new()
		local none = 0
		for _ = 1, 200 do
			none += select(2, Thirst.tick(full, SURVIVAL, 20, 20))
		end
		t.eq(none, 0, "not hurt: nothing to heal")
		local dry = Thirst.new()
		dry.thirst = 17
		for _ = 1, 200 do
			none += select(2, Thirst.tick(dry, SURVIVAL, 10, 20))
		end
		t.eq(none, 0, "thirst 17: no regeneration")
		with({ ThirstRegeneration = false }, function()
			local off = Thirst.new()
			local got = 0
			for _ = 1, 200 do
				got += select(2, Thirst.tick(off, SURVIVAL, 10, 20))
			end
			t.eq(got, 0, "turned off")
		end)
		-- Fully frozen or overheated (Temperature.stopsRegeneration): none, and the timer waits
		-- at 0.
		local frozen = Thirst.new()
		local held = 0
		for _ = 1, 200 do
			held += select(2, Thirst.tick(frozen, SURVIVAL, 10, 20, 0, false, true))
		end
		t.eq(held, 0, "stopped: no regeneration")
		t.eq(frozen.timer, 0)
		t.eq(frozen.exhaustion, 0, "and none of its exhaustion")
	end)

	t.test("thirst: the regeneration block (an infection from stage III) stops both kinds", function()
		-- (Server Players/ToughAsNails can't run outside Roblox; its rule is checked in its source:
		-- the block joins the frozen or overheated rule in `stopped`, which both pauses the Roblox
		-- Health script and holds thirst's regeneration, and server Apocalypse/Infection sets the
		-- block from Shared/Apocalypse/Infection.blocksRegeneration.)
		local function code(path: string): string
			local source = fs.readFile(path)
			source = string.gsub(source, "%-%-%[(=*)%[.-%]%1%]", "")
			return (string.gsub(source, "%-%-[^\n]*", ""))
		end
		local tan = code("src/server/Players/ToughAsNails.luau")
		local stopped = string.match(tan, "local stopped = (.-)\n%s*pauseRobloxRegeneration")
		t.ok(stopped ~= nil, "`stopped` is worked out right before the Health script's pause")
		t.ok(stopped and string.find(stopped, "Temperature.stopsRegeneration", 1, true), "the extremes")
		t.ok(stopped and string.find(stopped, "block(player)", 1, true), "and the regeneration block")
		t.ok(string.find(tan, "pauseRobloxRegeneration(record, character, stopped)", 1, true), "Roblox's kind")
		-- (Thirst's own kind is always held with Minecraft's hunger on, whose kind takes its place
		-- and is held by the same `stopped`.)
		t.ok(string.match(tan, "Thirst%.tick%(%s*thirst,.-stopped or hungerOn%(%),") ~= nil, "thirst's kind")
		t.ok(string.match(tan, "Hunger%.tick%(%s*hunger,[^)]-%)%),%s*stopped,") ~= nil, "hunger's kind")
		t.ok(string.find(tan, "function ToughAsNailsServer.setRegenBlock", 1, true), "the block's setter")
		t.ok(string.find(tan, "function ToughAsNailsServer.pauseRegeneration", 1, true), "the pause without a tick")
		t.ok(string.find(tan, "function ToughAsNailsServer.sprinting", 1, true), "the sprint flag")
		local infection = code("src/server/Apocalypse/Infection.luau")
		t.ok(string.find(infection, "ToughAsNails.setRegenBlock(", 1, true), "the infection sets the block")
		t.ok(string.find(infection, "Rules.blocksRegeneration", 1, true), "from the pure rule")
		-- (With Tough As Nails off the infection asks for the pause every tick, kept nowhere, so a
		-- character that came without dying, its Health script new, is paused too.)
		local tick = string.match(infection, "function Infection%.tick%(.-\nend")
		t.ok(tick and string.find(tick, "ToughAsNails.pauseRegeneration(player,", 1, true), "asked every tick")
		t.ok(tick and not string.find(tick, "paused[", 1, true), "no remembered pause to go stale")
		-- Thirst's kind, held: no health back, none of its exhaustion spent.
		local held = Thirst.new()
		local healed = 0
		for _ = 1, 400 do
			healed += select(2, Thirst.tick(held, SURVIVAL, 10, 20, 0, false, true))
		end
		t.eq(healed, 0, "held: nothing comes back")
		local free = Thirst.new()
		local back = 0
		for _ = 1, 400 do
			back += select(2, Thirst.tick(free, SURVIVAL, 10, 20, 0, false, false))
		end
		t.ok(back > 0, "free: it comes back")
	end)

	t.test("thirst: creative and spectator players stand still", function()
		for _, mode in { CREATIVE, SPECTATOR } do
			local state = Thirst.new()
			state.thirst, state.hydration = 0, 0
			Thirst.giveEffect(state, 100)
			Thirst.addExhaustion(state, 4)
			local damage = 0
			for _ = 1, 200 do
				damage += Thirst.tick(state, mode, 10, 20)
			end
			t.eq(damage, 0, `{mode}: no dehydration`)
			t.eq(state.effect, 100, `{mode}: the effect waits`)
			t.eq(state.exhaustion, 4, `{mode}: nothing drains`)
			t.ok(not ToughAsNails.affects(mode), mode)
		end
		t.ok(ToughAsNails.affects(SURVIVAL) and ToughAsNails.affects(ADVENTURE))
	end)

	t.test("thirst: Climate Clemency halves the drain and spares dehydration", function()
		local state = Thirst.new()
		Thirst.addExhaustion(state, 7.9)
		Thirst.tick(state, SURVIVAL, 20, 20, 0, true)
		t.eq(state.hydration, 5, "7.9: nothing yet (8 a point)")
		Thirst.addExhaustion(state, 0.2)
		Thirst.tick(state, SURVIVAL, 20, 20, 0, true)
		t.eq(state.hydration, 4, "above 8: a point")
		t.near(state.exhaustion, 0.1, 1e-9, "8 taken off")
		-- Over a long run: half the points of the same exhaustion.
		local clement, plain = Thirst.new(), Thirst.new()
		for _ = 1, 2000 do
			Thirst.tick(clement, SURVIVAL, 20, 20, 1 / 32, true)
			Thirst.tick(plain, SURVIVAL, 20, 20, 1 / 32)
		end
		local lost = function(s)
			return (Thirst.MAX - s.thirst) + (Thirst.START_HYDRATION - s.hydration)
		end
		t.eq(lost(plain), 15, "62.5 exhaustion: a point at 129 ticks, then every 128")
		t.eq(lost(clement), 7, "under the clemency at 257, then every 256")
		local dry = Thirst.new()
		dry.thirst, dry.hydration = 0, 0
		local hurt = 0
		for _ = 1, 600 do
			hurt += Thirst.tick(dry, SURVIVAL, 10, 20, 0, true)
		end
		t.eq(hurt, 0, "no dehydration under the clemency")
		local regen = 0
		local healthy = Thirst.new()
		for _ = 1, 80 do
			regen += select(2, Thirst.tick(healthy, SURVIVAL, 10, 20, 0, true))
		end
		t.eq(regen, 1, "regeneration as ever")
	end)

	--[[ Drinks ]]

	t.test("drinks: hand, dirty and purified water with their chances (injected random)", function()
		local state = Thirst.new()
		state.thirst, state.hydration = 10, 0
		t.ok(Drinks.apply(state, Drinks.HAND, rolls({ 0.49 })), "0.49 < 0.5: Thirst effect")
		t.eq(state.thirst, 11)
		t.near(state.hydration, 0.2, 1e-9)
		t.eq(state.effect, 300, "15 s")
		state.effect = 0
		t.ok(not Drinks.apply(state, Drinks.DIRTY, rolls({ 0.5 })), "0.5: none")
		t.eq(state.thirst, 15)
		t.eq(state.effect, 0)
		t.ok(not Drinks.apply(state, Drinks.PURIFIED, rolls({})), "purified never rolls")
		t.eq(state.thirst, 20)
		t.eq(Drinks.of(I.DirtyWaterBottle), Drinks.DIRTY)
		t.eq(Drinks.of(I.PurifiedWaterCanteen), Drinks.PURIFIED)
		t.eq(Drinks.of(I.GlassBottle), nil)
		t.eq(Drinks.of(nil), nil)
	end)

	t.test("drinks: Internal Warmth and Chill through Drinks.apply (the temperature state)", function()
		local tea = { thirst = 2, hydration = 0.5, chance = 0, effectTicks = 0, warmth = 1200 }
		local juice = { thirst = 2, hydration = 0.5, chance = 0, effectTicks = 0, chill = 600 }
		local thirst, body = Thirst.new(), Temperature.new()
		thirst.thirst = 10
		Drinks.apply(thirst, tea, rolls({}), body)
		t.eq(body.warmth, 1200, "warmth given")
		t.eq(body.chill, 0)
		t.eq(thirst.thirst, 12, "and drunk")
		Drinks.apply(thirst, juice, rolls({}), body)
		t.eq(body.chill, 600, "chill given")
		Drinks.apply(thirst, { thirst = 1, hydration = 0, chance = 0, effectTicks = 0, warmth = 100 }, rolls({}), body)
		t.eq(body.warmth, 1200, "a longer one stays")
		local alone = Thirst.new()
		alone.thirst = 10
		Drinks.apply(alone, tea, rolls({}))
		t.eq(alone.thirst, 12, "without a temperature state: just a drink")
		local plain = Temperature.new()
		Drinks.apply(Thirst.new(), Drinks.PURIFIED, rolls({}), plain)
		t.eq(plain.warmth + plain.chill, 0, "water gives neither")
	end)

	t.test("drinks: the container tables (dirty and purified, empties, a third kind by data)", function()
		t.eq(Drinks.purifiedOf(I.DirtyWaterBottle), I.PurifiedWaterBottle)
		t.eq(Drinks.purifiedOf(I.DirtyWaterCanteen), I.PurifiedWaterCanteen)
		t.eq(Drinks.purifiedOf(I.PurifiedWaterBottle), nil)
		t.eq(Drinks.purifiedOf(nil), nil)
		t.ok(Drinks.isDirty(I.DirtyWaterBottle) and Drinks.isDirty(I.DirtyWaterCanteen))
		t.ok(not Drinks.isDirty(I.PurifiedWaterCanteen) and not Drinks.isDirty(I.GlassBottle))
		t.eq(Drinks.emptyOf(I.PurifiedWaterBottle), I.GlassBottle)
		t.eq(Drinks.emptyOf(I.DirtyWaterCanteen), I.Canteen)
		t.ok(Drinks.isContainer(I.GlassBottle) and Drinks.isContainer(I.Canteen))
		t.ok(not Drinks.isContainer(I.DirtyWaterCanteen), "a canteen with water is no empty container")
		-- Every dirty water purifies by a recipe into its twin.
		for dirty, purified in Drinks.PURIFIED_OF do
			local result = Smelting.result(dirty)
			t.eq(result and result.item, purified, `{Items.get(dirty).name} smelts into its purified twin`)
			t.ok(Drinks.isDrink(purified), "the twin is a drink")
		end
		-- What fills is a drink, and drinking it gives the container back.
		for empty, full in Drinks.FILLS do
			t.eq(Drinks.emptyOf(full), empty, `{Items.get(full).name} leaves {Items.get(empty).name}`)
		end
		t.ok(table.isfrozen(Drinks.ITEMS) and table.isfrozen(Drinks.FILLS), "entries go into the module")
	end)

	t.test("drinks: what a right click does (Drinks.action)", function()
		local function S(item, count, damage)
			return { item = item, count = count or 1, damage = damage }
		end
		t.eq(Drinks.action(S(I.GlassBottle, 5), true, true, true), "fill")
		t.eq(Drinks.action(S(I.GlassBottle, 5), false, true, true), nil, "a bottle away from water")
		t.eq(Drinks.action(S(I.Canteen), true, false, true), "fill", "filling needs no thirst")
		t.eq(Drinks.action(S(I.DirtyWaterCanteen, 1, 2), true, true, true), "fill", "refilled")
		t.eq(Drinks.action(S(I.DirtyWaterCanteen), true, true, true), "drink", "full: drunk")
		t.eq(Drinks.action(S(I.PurifiedWaterCanteen, 1, 2), true, true, true), "drink", "never dirtied")
		t.eq(Drinks.action(S(I.DirtyWaterBottle), true, true, true), "drink")
		t.eq(Drinks.action(S(I.PurifiedWaterBottle), false, false, true), nil, "not thirsty")
		t.eq(Drinks.action(nil, true, true, true), "hand")
		t.eq(Drinks.action(nil, true, true, false), nil, "hand drinking off")
		t.eq(Drinks.action(nil, false, true, true), nil)
		t.eq(Drinks.action(S(B.Stone), true, true, true), nil)
		local water = Blocks.fluidId("Water", 0)
		t.ok(Drinks.isWaterSource(water), "a water source")
		t.ok(not Drinks.isWaterSource(Blocks.fluidId("Water", 1)), "flowing water is no source")
		t.ok(not Drinks.isWaterSource(Blocks.fluidId("Lava", 0)), "lava")
		t.ok(not Drinks.isWaterSource(nil))
		t.eq(Fluids.ofBlock(water), Fluids.WATER)
	end)

	t.test("drinks: filling (ItemUtils.createFilledResult) and drinking up bottles and canteens", function()
		local function has(_item)
			return false
		end
		local held, give = Drinks.fill({ item = I.GlassBottle, count = 3 }, false, has)
		t.eq(held and held.item, I.GlassBottle)
		t.eq(held and held.count, 2, "one bottle used")
		t.eq(give and give.item, I.DirtyWaterBottle, "the full one goes into the inventory")
		held, give = Drinks.fill({ item = I.GlassBottle, count = 1 }, false, has)
		t.eq(held and held.item, I.DirtyWaterBottle, "the last one: replaced")
		t.eq(give, nil)
		held, give = Drinks.fill({ item = I.GlassBottle, count = 4 }, true, has)
		t.eq(held and held.count, 4, "creative keeps the empty ones")
		t.eq(give and give.item, I.DirtyWaterBottle, "and gets a full one")
		held, give = Drinks.fill({ item = I.GlassBottle, count = 4 }, true, function(item)
			return item == I.DirtyWaterBottle
		end)
		t.eq(give, nil, "creative: not when it has one")
		held = Drinks.fill({ item = I.Canteen, count = 1 }, false, has)
		t.eq(held and held.item, I.DirtyWaterCanteen)
		t.eq(held and held.damage, nil, "three sips")
		held = Drinks.fill({ item = I.DirtyWaterCanteen, count = 1, damage = 2 }, false, has)
		t.eq(held and held.damage, nil, "topped up")
		held, give = Drinks.fill({ item = I.Stone, count = 1 }, false, has)
		t.eq(held and held.item, I.Stone, "no filling")

		-- Bottles give their Glass Bottle back.
		held, give = Drinks.afterDrinking({ item = I.PurifiedWaterBottle, count = 3 }, false)
		t.eq(held and held.count, 2)
		t.eq(give and give.item, I.GlassBottle)
		held, give = Drinks.afterDrinking({ item = I.DirtyWaterBottle, count = 1 }, false)
		t.eq(held and held.item, I.GlassBottle, "the last becomes the bottle")
		t.eq(give, nil)
		held, give = Drinks.afterDrinking({ item = I.DirtyWaterBottle, count = 1 }, true)
		t.eq(held and held.item, I.DirtyWaterBottle, "creative uses nothing up")

		-- Canteens: three sips, then the empty Canteen.
		local canteen = { item = I.PurifiedWaterCanteen, count = 1 }
		t.eq(Drinks.sips(canteen), 3)
		local sips = 0
		while canteen.item == I.PurifiedWaterCanteen do
			canteen = assert(Drinks.afterDrinking(canteen, false))
			sips += 1
			t.ok(sips <= 3, "at most three")
		end
		t.eq(sips, 3)
		t.eq(canteen.item, I.Canteen)
		t.eq(Drinks.sips(canteen), 0)
		t.eq(Items.get(I.Canteen).maxStack, 1)
		t.eq(Items.get(I.DirtyWaterBottle).maxStack, 16)
		t.eq(Items.get(I.GlassBottle).maxStack, 64)
	end)

	t.test("drinks: Terraria's mana potions are drunk any time, for mana and a bottle", function()
		for item, mana in { [I.LesserManaPotion] = 50, [I.ManaPotion] = 100 } do
			local drink = Drinks.of(item)
			t.eq(Drinks.manaOf(drink), mana)
			t.ok(Drinks.isPotion(drink), "a potion")
			-- Not thirsty, thirst on or off: still drunk.
			for _, thirstOn in { true, false } do
				local canDrink = Drinks.drinkable(drink, false, thirstOn, thirstOn)
				t.eq(Drinks.action({ item = item, count = 2 }, false, canDrink, true), "drink")
			end
			t.eq(Drinks.emptyOf(item), I.GlassBottle)
			t.ok(not Drinks.fills({ item = item, count = 1 }), "never filled at water")
			-- No water in it: drinking changes no thirst.
			local thirst = Thirst.new()
			thirst.thirst = 10
			Drinks.apply(thirst, drink :: any, rolls({ 0 }), nil)
			t.eq(thirst.thirst, 10)
		end
	end)

	t.test("drinks: recipes (the Glass Bottle, the Canteen) and purification by smelting", function()
		local function grid(cells)
			local stacks = {}
			for slot = 1, 9 do
				local item = cells[slot]
				if item then
					stacks[slot] = { item = item, count = 1 }
				end
			end
			return Crafting.match(stacks, 3)
		end
		local G, N, IN = I.Glass, I.IronNugget, I.IronIngot
		local bottles = grid({ G, nil, G, nil, G })
		t.eq(bottles and bottles.item, I.GlassBottle, "three glass in a V")
		t.eq(bottles and bottles.count, 3)
		local canteen = grid({ nil, N, nil, IN, nil, IN, nil, IN })
		t.eq(canteen and canteen.item, I.Canteen, "a nugget over an iron cup")
		local bucket = grid({ IN, nil, IN, nil, IN })
		t.eq(bucket and bucket.item, I.Bucket, "the Bucket is still the Bucket")
		t.eq(Smelting.result(I.DirtyWaterBottle).item, I.PurifiedWaterBottle)
		t.eq(Smelting.result(I.DirtyWaterCanteen).item, I.PurifiedWaterCanteen)
		t.eq(Smelting.result(I.PurifiedWaterBottle), nil)
		-- Canteens don't "repair" together (tools only).
		local worn = { item = I.DirtyWaterCanteen, count = 1, damage = 2 }
		t.eq(Crafting.match({ worn, worn }, 2), nil, "no pouring two canteens together")
		local pick = { item = I.IronPickaxe, count = 1, damage = 200 }
		t.ok(Crafting.match({ pick, pick }, 2) ~= nil, "tools still repair")
		t.ok(Sounds.find("entity.generic.drink") ~= nil and Sounds.find("item.bottle.fill") ~= nil, "sounds")
	end)

	--[[ Movement ]]

	t.test("exertion: what the client counts, what the server allows, what it costs", function()
		local report = Exertion.new()
		local hull = {
			swimming = false,
			eyeInWater = false,
			inWater = false,
			onGround = true,
			sprinting = true,
			flying = false,
			noClip = false,
		}
		Exertion.record(report, hull, 0.3, 0, 0.4, false)
		t.eq(report.sprintCm, 50, "a sprinted half metre")
		Exertion.record(report, hull, 0.3, 0.4, 0, true)
		t.eq(report.sprintJumps, 1)
		t.eq(report.sprintCm, 80, "horizontal only")
		hull.sprinting = false
		Exertion.record(report, hull, 1, 0, 0, true)
		t.eq(report.sprintCm, 80, "walking costs nothing")
		t.eq(report.jumps, 1)
		hull.swimming = true
		Exertion.record(report, hull, 0, 0.3, 0.4, false)
		t.eq(report.waterCm, 50, "swimming: the whole move")
		hull.swimming, hull.inWater = false, true
		Exertion.record(report, hull, 0, 1, 0.1, false)
		t.eq(report.waterCm, 60, "wading: horizontal")
		hull.inWater, hull.flying = false, true
		Exertion.record(report, hull, 5, 0, 0, true)
		t.eq(report.jumps, 1, "flying: nothing")
		t.near(Exertion.exhaustion(report), 0.8 * 0.1 + 0.6 * 0.01 + 0.2 + 0.05, 1e-9, "FoodConstants")
		local greedy = { sprintCm = 60000, waterCm = 60000, jumps = 200, sprintJumps = 200, sprinting = true }
		local bounded = Exertion.clamp(greedy, 1)
		t.eq(bounded.sprintCm, 1000, "10 m in a second at most")
		t.eq(bounded.waterCm, 0)
		t.eq(bounded.sprintJumps + bounded.jumps, 3)
		t.ok(bounded.sprinting)
		Exertion.reset(report)
		t.ok(Exertion.isEmpty(report))
	end)

	--[[ Temperature ]]

	local ICY, COLD, NEUTRAL, WARM, HOT =
		Temperature.ICY, Temperature.COLD, Temperature.NEUTRAL, Temperature.WARM, Temperature.HOT

	local function env(overrides)
		local base = {
			climate = 0.1,
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
			armorWarmth = 0,
			armorCooling = 0,
		}
		for key, value in overrides or {} do
			base[key] = value
		end
		return base
	end
	local function climate(name)
		return assert(Biomes.byName(name)).temperature
	end
	local function target(overrides, state)
		return Temperature.target(env(overrides), state)
	end

	t.test("temperature: the climate on the -10..10 scale, and its zones", function()
		for i, border in Temperature.CLIMATE do
			t.near(Temperature.scaleOf(border), Temperature.SCALE[i], 1e-9, `border {border} on a zone border`)
		end
		t.eq(Temperature.levelOf(-0.55), -7, "borders belong to the warmer side: cold")
		t.eq(Temperature.levelOf(-0.56), -8, "just below: icy")
		t.eq(Temperature.levelOf(-0.25), -2, "neutral")
		t.eq(Temperature.levelOf(0.4), 3, "warm")
		t.eq(Temperature.levelOf(0.7), 8, "hot")
		t.near(Temperature.scaleOf(0.075), 0, 1e-9, "neutral's middle")
		t.near(Temperature.scaleOf(-0.85), -12.5, 1e-9, "beyond the borders the slope goes on")
		t.eq(Temperature.levelOf(-3), Temperature.MIN, "and the scale's ends cut it")
		t.eq(Temperature.levelOf(3), Temperature.MAX)
		local expected = { [-10] = ICY, [-8] = ICY, [-7] = COLD, [-3] = COLD, [-2] = NEUTRAL }
		expected[2], expected[3], expected[7], expected[8], expected[10] = NEUTRAL, WARM, WARM, HOT, HOT
		for value, zone in expected do
			t.eq(Temperature.zone(value), zone, `zone of {value}`)
		end
		for zone, range in Temperature.ZONES do
			t.ok(Temperature.zone(range[1]) == zone and Temperature.zone(range[2]) == zone, `zone {zone}'s range`)
		end
		t.eq(Temperature.name(-9), "Icy")
		t.eq(Temperature.name(0), "Neutral")
		t.eq(Temperature.name(9), "Hot")
	end)

	t.test("temperature: the target from the biome, altitude, night, shelter and underground", function()
		t.eq(target({ climate = climate("Tundra") }), -10, "tundra: icy")
		t.eq(target({ climate = climate("Taiga") }), -4, "taiga: cold")
		t.eq(target({ climate = climate("Taiga"), night = true }), -9, "taiga at night: icy")
		t.eq(target({ climate = climate("Plains") }), 0, "plains")
		t.eq(target({ climate = climate("Plains"), night = true }), -2, "plains at night: still neutral")
		t.eq(target({ climate = climate("Savanna") }), 4, "savanna: warm")
		t.eq(target({ climate = climate("Jungle") }), 7, "jungle: warm")
		t.eq(target({ climate = climate("Desert") }), 9, "desert by day: hot")
		t.eq(target({ climate = climate("Desert"), night = true }), 4, "desert at night: warm")
		t.eq(target({ climate = climate("Desert"), skyOpen = false }), 7, "a desert house: warm")
		t.eq(target({ climate = climate("Taiga"), skyOpen = false }), -2, "a taiga house: neutral")
		t.eq(target({ climate = climate("Taiga"), skyOpen = false, night = true }), -2, "by night too")
		t.eq(target({ climate = climate("OldGrowthTaiga"), skyOpen = false }), -3, "an old growth taiga house: cold")
		t.eq(target({ climate = climate("Tundra"), skyOpen = false }), -8, "a tundra house: the edge of icy")
		t.eq(target({ climate = climate("Plains"), skyOpen = false }), 0, "never past NEUTRAL's middle")
		-- A roof moves the climate towards neutral, never past it nor away: never colder in the
		-- cold, nor warmer in the heat, than outdoors by day (it used to chill every house).
		for _, biome in Biomes.list do
			local day = target({ climate = biome.temperature })
			local house = target({ climate = biome.temperature, skyOpen = false })
			t.ok(math.abs(house) <= math.abs(day), `{biome.name}: a house {house}, outdoors {day}`)
			t.ok(house * day >= 0, `{biome.name}: never past neutral`)
		end
		t.eq(target({ climate = climate("Tundra"), skyOpen = false, y = 40, surface = 80 }), 0, "underground: neutral")
		t.eq(
			Temperature.zone(target({ climate = climate("Tundra"), skyOpen = false, y = 70, surface = 80 })),
			ICY,
			"a shallow hole is still the tundra"
		)
		t.eq(Temperature.zone(target({ climate = climate("JaggedPeaks"), y = 760, surface = 760 })), COLD, "peaks")
		t.eq(Temperature.zone(target({ climate = climate("FrozenPeaks"), y = 760, surface = 760 })), ICY)
		t.eq(Temperature.zone(target({ climate = climate("Plains"), y = 1000, surface = 80 })), ICY, "flying high")
		t.near(Temperature.climateValue(env({ climate = 0.5, y = 356 })), 0.4, 1e-9, "0.001 a block above 256")
	end)

	t.test("temperature: modifiers in steps (wet, sprinting, heat near and far, burning, cold)", function()
		t.eq(target({ wet = true }), -3, "wet")
		t.eq(target({ sprinting = true }), 2, "sprinting")
		t.eq(target({ heated = true }), 3, "a heat source in range")
		t.eq(target({ heated = true, nearHeat = true }), 5, "within 2 blocks")
		t.eq(target({ burning = true }), 5, "burning")
		t.eq(target({ burning = true, heated = true, nearHeat = true }), 5, "burning by a fire: the larger, not both")
		t.eq(target({ cooled = true }), -3, "a cold source")
		t.eq(target({ heated = true, cooled = true }), 0, "both cancel")
		t.eq(target({ climate = climate("Desert"), heated = true, sprinting = true }), 10, "10 at most")
		t.eq(target({ climate = climate("Tundra"), wet = true }), -10, "-10 at least")
		t.eq(
			target({ climate = climate("Tundra"), wet = true, heated = true, nearHeat = true }),
			-5,
			"kept within the scale step by step: a fire still helps the soaked"
		)
		t.eq(Temperature.zone(target({ climate = climate("Tundra"), heated = true })), COLD, "a fire keeps the ice off")
	end)

	t.test("temperature: armor insulation pulls towards 0, never past it (ItemList tan)", function()
		t.eq(target({ climate = climate("Tundra"), armorWarmth = 4 }), -6)
		t.eq(target({ climate = climate("Tundra"), armorWarmth = 8 }), -2, "a full set at 2 a piece: neutral")
		t.eq(target({ climate = climate("Taiga"), armorWarmth = 8 }), 0, "never past 0")
		t.eq(target({ climate = climate("Jungle"), armorWarmth = 8 }), 7, "warmth doesn't warm in the heat")
		t.eq(target({ climate = climate("Desert"), armorCooling = 4 }), 5, "cooling")
		t.eq(target({ climate = climate("Desert"), armorCooling = 20 }), 0)
		t.eq(target({ climate = climate("Tundra"), armorCooling = 4 }), -10, "cooling doesn't chill in the cold")
		local leather = Items.get(I.LeatherHelmet).tan
		t.ok(leather ~= nil and leather.warmth == 1 and leather.cooling == 0 and leather.freezeImmune, "leather")
		t.eq(Items.get(I.IronHelmet).tan, nil, "iron: none")
		local warmth, cooling, immune = Climate.insulation({
			{ item = I.LeatherHelmet, count = 1 },
			{ item = I.LeatherChestplate, count = 1 },
			nil,
			{ item = I.IronBoots, count = 1 },
		})
		t.eq(warmth, 2, "two leather pieces")
		t.eq(cooling, 0)
		t.ok(immune, "freeze immune")
		local w, c, i = Climate.insulation({ nil, { item = I.IronChestplate, count = 1 } })
		t.ok(w == 0 and c == 0 and not i, "iron insulates nothing")
	end)

	t.test("temperature: Internal Warmth and Chill stop at NEUTRAL; Climate Clemency holds it", function()
		local warm = Temperature.new()
		Temperature.giveWarmth(warm, 600)
		t.eq(target({ climate = climate("Tundra") }, warm), -5, "warmth: 5 steps")
		t.eq(target({ climate = climate("Taiga") }, warm), 1)
		t.eq(target({ climate = climate("Plains") }, warm), 2, "never past NEUTRAL's top by it")
		t.eq(target({ climate = climate("Desert") }, warm), 9, "nor anything in the heat")
		local cool = Temperature.new()
		Temperature.giveChill(cool, 600)
		t.eq(target({ climate = climate("Desert") }, cool), 4, "chill: 5 steps")
		t.eq(target({ climate = climate("Jungle") }, cool), 2)
		t.eq(target({ climate = climate("Plains") }, cool), -2, "never past NEUTRAL's bottom by it")
		t.eq(target({ climate = climate("Tundra") }, cool), -10, "nor anything in the cold")
		-- They count down; a longer one stays.
		Temperature.giveWarmth(warm, 100)
		t.eq(warm.warmth, 600)
		for _ = 1, 600 do
			Temperature.tick(warm, SURVIVAL)
		end
		t.eq(warm.warmth, 0)
		t.eq(target({ climate = climate("Tundra") }, warm), -10, "worn off")

		local grace = Temperature.new(100)
		t.ok(Temperature.clement(grace))
		t.eq(target({ climate = climate("Tundra") }, grace), -2, "the clemency holds the target in NEUTRAL")
		t.eq(target({ climate = climate("Desert"), sprinting = true }, grace), 2)
		t.eq(target({ climate = climate("Plains") }, grace), 0)
		for _ = 1, 50 do
			Temperature.tick(grace, CREATIVE)
		end
		t.eq(grace.clemency, 100, "it waits in creative")
		for _ = 1, 60 do
			Temperature.tick(grace, SURVIVAL)
		end
		t.eq(grace.clemency, 40, "counts down in survival")
		for _ = 1, 40 do
			Temperature.tickEffects(grace, ADVENTURE)
		end
		t.eq(grace.clemency, 0, "and adventure (tickEffects alone too)")
		t.ok(not Temperature.clement(grace))
		t.eq(target({ climate = climate("Tundra") }, grace), -10, "over")
		Temperature.grantClemency(grace, 20)
		Temperature.grantClemency(grace, 10)
		t.eq(grace.clemency, 20, "a longer one stays")
		t.eq(Temperature.new().clemency, 0, "none by default")
	end)

	t.test("temperature: a step per ChangeTicks away from 0, per RecoverTicks back", function()
		local change, recover = settings.ChangeTicks, settings.RecoverTicks
		t.ok(recover < change, "recovering is faster")
		local body = Temperature.new()
		body.target = -10
		local steps, icyAt = {}, nil
		for tick = 1, 12 * change do
			local before = body.value
			Temperature.tick(body, SURVIVAL)
			if body.value ~= before then
				table.insert(steps, tick)
			end
			if icyAt == nil and Temperature.zone(body.value) == ICY then
				icyAt = tick
			end
			if tick == 1 then
				t.eq(Temperature.trend(body), -1, "falling")
			end
		end
		t.eq(steps[1], change, "a step after ChangeTicks")
		t.eq(steps[2], 2 * change)
		t.eq(#steps, 10)
		t.eq(icyAt, 8 * change, "the icy edge after 8 steps")
		t.ok(icyAt and icyAt >= 45 * 20 and icyAt <= 60 * 20, "neutral to icy takes 45..60 s")
		print(`         (neutral to icy in the coldest place: {(icyAt or 0) / 20} s)`)
		t.eq(Temperature.trend(body), 0, "on target")

		body.target = 0
		local edge = nil
		for tick = 1, 12 * recover do
			Temperature.tick(body, SURVIVAL)
			if edge == nil and body.value == -2 then
				edge = tick
			end
		end
		t.eq(edge, 8 * recover, "-10 to NEUTRAL's edge at RecoverTicks a step")
		t.eq(body.value, 0)

		local cross = Temperature.new()
		cross.value, cross.target = -1, 1
		local at = {}
		for tick = 1, recover + change do
			local before = cross.value
			Temperature.tick(cross, SURVIVAL)
			if cross.value ~= before then
				table.insert(at, tick)
			end
		end
		t.eq(at[1], recover, "-1 -> 0: back towards 0")
		t.eq(at[2], recover + change, "0 -> 1: away from it")
		t.eq(Temperature.stepTicks(5, 0), recover)
		t.eq(Temperature.stepTicks(5, 9), change)

		local wobble = Temperature.new()
		wobble.target = 2
		for _ = 1, change - 1 do
			Temperature.tick(wobble, SURVIVAL)
		end
		wobble.target = 0
		Temperature.tick(wobble, SURVIVAL)
		wobble.target = 2
		Temperature.tick(wobble, SURVIVAL)
		t.eq(wobble.value, 0, "back on target restarts the count")
		-- Wet for WetTicks after the water.
		Temperature.soak(wobble)
		t.ok(Temperature.isWet(wobble))
		for _ = 1, settings.WetTicks do
			Temperature.tick(wobble, SURVIVAL)
		end
		t.ok(not Temperature.isWet(wobble), "dry again")
		-- Creative: the temperature stands still.
		local still = Temperature.new()
		still.target = -10
		for _ = 1, 3 * change do
			Temperature.tick(still, CREATIVE)
		end
		t.eq(still.value, 0, "creative stands still")
	end)

	t.test("temperature: hypothermia and hyperthermia (20 s to build, 5 s to thaw, a hurt every 5 s)", function()
		local full, interval = Temperature.EXTREME_TICKS, Temperature.HURT_INTERVAL
		t.eq(full, 400)
		t.eq(interval, 100)
		local cold = Temperature.new()
		cold.value, cold.target = -8, -8
		local hurts = {}
		for tick = 1, full + 3 * interval do
			local damage = Temperature.tick(cold, SURVIVAL)
			if damage > 0 then
				t.eq(damage, 1, "half a heart")
				table.insert(hurts, tick)
			end
			if tick == full - 1 then
				t.eq(cold.frozen, full - 1, "a tick at a time")
			end
		end
		t.ok(Temperature.stopsRegeneration(cold), "frozen through: no health comes back")
		t.eq(hurts[1], full + interval - 1, "the first hurt 5 s after freezing through")
		t.eq(hurts[2], full + 2 * interval - 1, "then every 5 s")
		t.eq(#hurts, 3)
		cold.value, cold.target = -7, -7
		Temperature.tick(cold, SURVIVAL)
		t.eq(cold.frozen, full - Temperature.THAW, "thaws 4 a tick out of ICY")
		t.ok(not Temperature.stopsRegeneration(cold), "thawing: health comes back again")
		for _ = 1, full // Temperature.THAW - 1 do
			Temperature.tick(cold, SURVIVAL)
		end
		t.eq(cold.frozen, 0, "5 s from full")

		local dressed = Temperature.new()
		dressed.value, dressed.target = -10, -10
		local damage = 0
		for _ = 1, 3 * full do
			damage += Temperature.tick(dressed, SURVIVAL, true)
		end
		t.eq(damage, 0, "freeze immune (leather): never frozen")
		t.eq(dressed.frozen, 0)

		local graced = Temperature.new(10 * full)
		graced.value, graced.target = -10, -10
		for _ = 1, 3 * full do
			damage += Temperature.tick(graced, SURVIVAL)
		end
		t.eq(damage, 0, "Climate Clemency: no extremes")
		t.eq(graced.frozen, 0)

		local hot = Temperature.new()
		hot.value, hot.target = 9, 9
		for _ = 1, full + interval do
			damage += Temperature.tick(hot, ADVENTURE, true)
		end
		t.eq(hot.heat, full)
		t.eq(damage, 1, "hyperthermia hurts the same way, freeze immune or not")
		t.ok(Temperature.stopsRegeneration(hot), "and stops regeneration the same way")
		t.ok(not Temperature.stopsRegeneration(Temperature.new()))
		local frost, heat = Temperature.extremes(hot)
		t.eq(frost, 0)
		t.eq(heat, 1)
		Temperature.tick(hot, CREATIVE)
		t.eq(hot.heat, 0, "creative: cleared at once")
	end)

	--[[
		The harshest place, played out as the server does: from neutral and full health, nothing
		worn, the clemency over (or not), the surroundings sampled once a second, a tick at a time
		until health runs out; with thirst (full, its regeneration fighting back, the HOT zone's
		sweating, no regeneration while fully frozen or overheated) or the temperature alone, and
		`drinking`: a Purified Water Bowl whenever thirst drops below 18 (so its regeneration never
		runs dry). Returns the ticks it took.
	]]
	local function timeToDeath(where, withThirst: boolean, clemency: number?, drinking: boolean?): number
		local body, thirst = Temperature.new(clemency), Thirst.new()
		local health = 20
		for tick = 1, 20 * 60 * 30 do
			if tick % 20 == 1 then
				body.target = Temperature.target(where, body)
			end
			local damage = Temperature.tick(body, SURVIVAL)
			if withThirst then
				local hot = Temperature.zone(body.value) == HOT
				local lost, gained = Thirst.tick(
					thirst,
					SURVIVAL,
					health,
					20,
					if hot then settings.HotExhaustion else 0,
					Temperature.clement(body),
					Temperature.stopsRegeneration(body)
				)
				damage += lost
				health = math.min(20, health + gained)
				if drinking and thirst.thirst < Thirst.REGEN_THIRST then
					Drinks.apply(thirst, Drinks.PURIFIED_BOWL, rolls({}))
				end
			end
			health -= damage
			if health <= 0 then
				return tick
			end
		end
		return math.huge
	end
	local function clock(ticks: number): string
		local seconds = math.floor(ticks / 20)
		return string.format("%d:%02d", seconds // 60, seconds % 60)
	end

	t.test("temperature: the harshest cold or heat takes about 3 minutes to kill, whatever is drunk", function()
		local tundra = env({ climate = climate("Tundra"), night = true })
		local desert = env({ climate = climate("Desert"), sprinting = true })
		t.eq(Temperature.target(tundra), Temperature.MIN, "the coldest")
		t.eq(Temperature.target(desert), Temperature.MAX, "the hottest")
		local alone = timeToDeath(tundra, false)
		local cold = timeToDeath(tundra, true)
		local hot = timeToDeath(desert, true)
		local watered = timeToDeath(tundra, true, nil, true)
		local wateredHot = timeToDeath(desert, true, nil, true)
		local joined = timeToDeath(tundra, true, settings.ClemencyTicks)
		print(
			`         (to death from neutral: cold {clock(cold)} ({cold / 20} s), hot {clock(hot)} ({hot / 20} s),`
				.. ` cold by temperature alone {clock(alone)} ({alone / 20} s), cold on joining {clock(joined)})`
		)
		local full, interval = Temperature.EXTREME_TICKS, Temperature.HURT_INTERVAL
		t.eq(alone, 8 * settings.ChangeTicks + full + 20 * interval - 2, "icy, frozen through, 20 hurts")
		t.ok(alone >= 170 * 20, `temperature alone: nearly 3 minutes ({clock(alone)})`)
		-- (Regeneration, a half heart every 80 ticks, would outlast hurts every 100: it waits.)
		t.ok(interval > Thirst.INTERVAL, "the extremes hurt slower than thirst's regeneration heals")
		t.eq(cold, alone, "thirst's regeneration waits while frozen through")
		t.eq(hot, alone, "the heat the same")
		t.eq(watered, alone, "drinking whenever thirsty doesn't hold the cold off")
		t.eq(wateredHot, alone, "nor the heat")
		-- (Held at NEUTRAL's edge, -2, through the clemency: 6 steps to icy after it, not 8.)
		t.ok(joined >= settings.ClemencyTicks + 160 * 20, "the clemency's 5 minutes come first")
		-- Before: two levels at 200 ticks each, frozen in 140, then a hurt every 40: 67 s.
		local before = 2 * 200 + 140 + 20 * 40
		t.ok(alone >= 2.5 * before, "two and a half times as long as before at least")
	end)

	--[[ Seasons (Shared/Seasons/SeasonClimate's sample in the environment; see Temperature's header) ]]

	local SeasonClimate = require(shared.Seasons.SeasonClimate)
	local Calendar = require(shared.Seasons.Calendar)
	local seasons = Calendar.newState()
	seasons.enabled = true
	-- The season's sample for a biome `name` at `dayTime` (seasons on).
	local function season(name: string, dayTime: number): any
		local biome = assert(Biomes.byName(name))
		return SeasonClimate.sample(dayTime, SeasonClimate.classOf(biome.index), 1, seasons)
	end
	local WINTER_NIGHT = 12 * 24000 + 18000

	t.test("temperature (seasons): without the seasons' fields every rule is as before", function()
		for _, biome in Biomes.list do
			for _, night in { false, true } do
				for _, skyOpen in { false, true } do
					for _, overrides in
						{ {}, { wet = true }, { heated = true }, { nearHeat = true, heated = true }, { cooled = true } }
					do
						local plain = table.clone(overrides) :: any
						plain.climate, plain.night, plain.skyOpen = biome.temperature, night, skyOpen
						local seasonless = table.clone(plain)
						seasonless.seasonShift, seasonless.snowedOn, seasonless.radiant = 0, false, false
						t.eq(target(seasonless), target(plain), `{biome.name} night {night} sky {skyOpen}`)
					end
				end
			end
		end
	end)

	t.test("temperature (seasons): a room's air is step 1; its sources count there, radiant +2", function()
		t.eq(target({ room = -5.6 }), -6, "rounded half up")
		t.eq(target({ room = 1.2 }), 1)
		t.eq(target({ room = 1.5 }), 2, "a half belongs to the warmer side")
		t.eq(target({ room = -30 }), Temperature.MIN, "kept on the scale")
		t.eq(target({ room = 30 }), Temperature.MAX)
		t.eq(target({ room = 0, climate = climate("Tundra"), night = true }), 0, "the room, not the tundra")
		-- In a room the proximity modifiers are dropped (the air counts those sources)...
		t.eq(target({ room = 0, heated = true }), 0, "no +3")
		t.eq(target({ room = 0, heated = true, nearHeat = true }), 0, "no +5")
		t.eq(target({ room = 0, cooled = true }), 0, "no -3")
		-- ...but a radiant source close by warms (+2), and burning is burning.
		t.eq(target({ room = 0, radiant = true }), Temperature.RADIANT_IN_ROOM)
		t.eq(Temperature.RADIANT_IN_ROOM, 2)
		t.eq(target({ room = 0, radiant = true, burning = true }), 5, "the larger, not both")
		t.eq(target({ radiant = true }), 0, "radiant counts only in a room")
		t.eq(target({ room = -2, wet = true, sprinting = true }), -3, "wet and sprinting as ever")
		t.eq(target({ room = -6, armorWarmth = 2 }), -4, "and the armor")
		-- The outside value beside it (the thermometer's "Out"), with no room in it.
		t.near(Temperature.outside(env({ climate = climate("Plains") })), Temperature.scaleOf(0.1), 1e-9)
	end)

	t.test("temperature (seasons): snow falling on you chills by one; the night reaches under roofs", function()
		t.eq(Temperature.MODIFIERS.snowedOn, -1)
		t.eq(target({ snowedOn = true }), -1)
		t.eq(target({ snowedOn = true, wet = true }), -4, "on top of being wet")
		-- With the seasons' night drop a roof no longer keeps the night out (the shelter still pulls).
		local winter = season("Plains", WINTER_NIGHT)
		local base = { climate = climate("Plains"), night = true, skyOpen = false }
		t.eq(target(base), 0, "without seasons a plains house is neutral at night")
		local seasonal = table.clone(base) :: any
		seasonal.seasonShift, seasonal.nightDrop = winter.shift, winter.nightDrop
		t.eq(target(seasonal), -7, "a bare roof on a winter night: cold")
		seasonal.skyOpen = true
		t.eq(target(seasonal), -9, "outdoors: icy")
		-- Underground the season never reaches.
		seasonal.skyOpen, seasonal.y, seasonal.surface = false, 30, 80
		t.eq(target(seasonal), 0, "underground: neutral")
	end)

	t.test("temperature (seasons): leather slows freezing but no longer stops it; shivering costs food", function()
		t.eq(Temperature.freezeImmune(true, false), true, "without seasons a leather piece is immune")
		t.eq(Temperature.freezeImmune(false, false), false)
		t.eq(settings.LeatherFreezeImmunity, false, "Config: no immunity with seasons on")
		t.eq(Temperature.freezeImmune(true, true), false, "with seasons, freezing goes on")
		with({ LeatherFreezeImmunity = true }, function()
			t.eq(Temperature.freezeImmune(true, true), true, "unless the knob says so")
		end)
		t.eq(settings.ColdExhaustion, 0.005)
		t.eq(Temperature.coldExhaustion(-3, true), 0.005, "COLD shivers")
		t.eq(Temperature.coldExhaustion(-10, true), 0.005, "ICY too")
		t.eq(Temperature.coldExhaustion(-2, true), 0, "NEUTRAL doesn't")
		t.eq(Temperature.coldExhaustion(-9, false), 0, "nothing without seasons")
		-- A full set of leather (1 a piece) turns a plains winter night (-9) into -5: cold, not icy.
		local winter = season("Plains", WINTER_NIGHT)
		local night: any = { climate = climate("Plains"), night = true, seasonShift = winter.shift }
		night.nightDrop = winter.nightDrop
		t.eq(target(night), -9)
		local dressed = table.clone(night) :: any
		dressed.armorWarmth = 4
		t.eq(target(dressed), -5)
	end)

	t.test("temperature (seasons): a winter night outdoors without gear kills in about 3 minutes", function()
		local winter = season("Plains", WINTER_NIGHT)
		local where = env({ climate = climate("Plains"), night = true })
		where.seasonShift, where.nightDrop = winter.shift, winter.nightDrop
		t.eq(Temperature.zone(Temperature.target(where)), ICY, "plains: icy")
		local ticks = timeToDeath(where, false)
		print(`         (a plains winter night, from neutral: {clock(ticks)} ({ticks / 20} s))`)
		t.ok(ticks >= 170 * 20 and ticks <= 190 * 20, `about 3 minutes ({clock(ticks)})`)
		-- Every temperate biome is icy then; a full leather set keeps one alive.
		for _, name in { "Plains", "Forest", "BirchForest", "Meadow", "WindsweptHills" } do
			local sample = season(name, WINTER_NIGHT)
			local outdoors = env({ climate = climate(name), night = true })
			outdoors.seasonShift, outdoors.nightDrop = sample.shift, sample.nightDrop
			t.eq(Temperature.zone(Temperature.target(outdoors)), ICY, `{name} on a winter night`)
		end
		where.armorWarmth = 4
		t.eq(timeToDeath(where, false), math.huge, "leather: cold, survivable")
	end)

	--[[ Surroundings ]]

	t.test("climate: heat and cold sources around the player, their distance, and checks", function()
		local blocks: { [string]: number } = {}
		local function put(x, y, z, block)
			blocks[`{x},{y},{z}`] = block
		end
		local view = {
			getBlock = function(x, y, z)
				return blocks[`{x},{y},{z}`] or Blocks.AIR
			end,
			column = function(_x, _z)
				return 64, assert(Biomes.byName("Plains")).index
			end,
			skyOpen = function(_x, _y, _z)
				return true
			end,
		}
		local r = settings.ProximityRadius
		local heat, cold = Climate.sources(view, 0, 64, 0, r)
		t.eq(heat, nil, "nothing around")
		t.eq(cold, nil)
		put(r, 64, 0, Blocks.fluidId("Lava", 3))
		t.eq((Climate.sources(view, 0, 64, 0, r)), r, "flowing lava at the edge")
		put(r, 64, 0, Blocks.AIR)
		put(r + 1, 64, 0, B.CaveLava)
		t.eq((Climate.sources(view, 0, 64, 0, r)), nil, "one block too far")
		t.ok(Climate.isHeating(B.CaveLava), "the cave twin heats")
		t.ok(Climate.isHeating(B.Fire), "fire")
		put(0, 60, 2, B.PackedIce)
		heat, cold = Climate.sources(view, 0, 64, 0, r)
		t.eq(cold, 4, "packed ice 4 below")
		t.eq(heat, nil)
		put(-3, 64, 0, B.Fire)
		put(1, 65, -2, B.Fire)
		t.eq((Climate.sources(view, 0, 64, 0, r)), 2, "the nearer of two fires")
		put(-3, 64, 0, Blocks.AIR)
		put(1, 65, -2, Blocks.AIR)
		-- A check decides for a block that heats only sometimes.
		local lit = false
		Climate.addHeatSource(B.CraftingTable, function()
			return lit
		end)
		put(1, 64, 1, B.CraftingTable)
		t.eq((Climate.sources(view, 0, 64, 0, r)), nil, "unlit")
		lit = true
		t.eq((Climate.sources(view, 0, 64, 0, r)), 1, "lit")
		-- A name no block has yet is skipped, so a block can be named before it exists.
		t.eq(Climate.addHeatSource("NoSuchHeaterYet"), 0, "unknown: skipped, no error")
		t.ok(Climate.addHeatSource("Lava") > 1, "a fluid name: all its blocks")

		local e = Climate.environment(view, 0.5, 64, 0.5, 18000, {
			wet = false,
			sprinting = true,
			burning = false,
			armorWarmth = 2,
			armorCooling = 0,
		})
		t.eq(e.climate, climate("Plains"))
		t.ok(e.night, "18000 is midnight")
		t.ok(e.heated and e.nearHeat and e.cooled and e.sprinting)
		t.eq(e.armorWarmth, 2)
		-- (The ice would cool 3, but not within NEAR of a heat source: a fire beats the cold around.)
		t.eq(Temperature.target(e), 5, "plains at night (-2), sprinting, a lit table at 1, ice at 4")
	end)

	t.test("climate (seasons): the season, the room at the feet, snow, radiant and room sources", function()
		local blocks: { [string]: number } = {}
		local room: any = nil
		local snowing = false
		local view = {
			getBlock = function(x, y, z)
				return blocks[`{x},{y},{z}`] or Blocks.AIR
			end,
			column = function(_x, _z)
				return 64, assert(Biomes.byName("Plains")).index
			end,
			skyOpen = function(_x, _y, _z)
				return true
			end,
			room = function(_x, _y, _z)
				return room
			end,
			snowing = function(_x, _y, _z)
				return snowing
			end,
		}
		local body = { wet = false, sprinting = false, burning = false, armorWarmth = 0, armorCooling = 0 }
		local winter = season("Plains", WINTER_NIGHT)
		-- Without a season none of it is looked at: as before.
		room, snowing = { temperature = 3, id = 1 }, true
		local plain = Climate.environment(view, 0.5, 64, 0.5, 18000, body)
		t.eq(plain.room, nil)
		t.eq(plain.snowedOn, nil)
		t.eq(plain.seasonShift, nil)
		-- With one: the shift and night drop, the room's air, the snow on the player.
		local e = Climate.environment(view, 0.5, 64, 0.5, 18000, body, winter)
		t.eq(e.seasonShift, winter.shift)
		t.eq(e.nightDrop, winter.nightDrop)
		t.eq(e.room, 3, "the room's air")
		t.eq(e.snowedOn, true)
		t.eq(Temperature.target(e), 2, "the room (3), snowed on (-1)")
		room, snowing = nil, false
		e = Climate.environment(view, 0.5, 64, 0.5, 18000, body, winter)
		t.eq(e.room, nil, "outdoors")
		t.eq(Temperature.target(e), -9, "a plains winter night")
		-- Radiant sources (fire, lava, campfires, the stoves) warm in a room; a convective one doesn't.
		room = { temperature = 0, id = 1 }
		blocks["1,64,0"] = B.Campfire
		e = Climate.environment(view, 0.5, 64, 0.5, 18000, body, winter)
		t.eq(e.radiant, true)
		t.eq(Temperature.target(e), 2, "a campfire beside you in a room: +2")
		t.ok(Climate.isRadiant(B.Fire) and Climate.isRadiant(B.Campfire), "fire and campfires")
		t.ok(Climate.isRadiant(Blocks.fluidId("Lava", 0)), "lava")
		blocks["1,64,0"] = nil
		-- Room sources: what a block gives a room's air, and how many count.
		local campfire, campfires = Climate.roomSource(B.Campfire)
		t.eq(assert(campfire)(0, 0, 0, B.Campfire), Config.Seasons.Heat.Campfire)
		t.eq(campfires, nil, "every campfire counts")
		local fire, fires = Climate.roomSource(B.Fire)
		t.eq(assert(fire)(0, 0, 0, B.Fire), 15)
		t.eq(fires, 3, "three fires at most")
		local lava, lavas = Climate.roomSource(Blocks.fluidId("Lava", 0))
		t.eq(assert(lava)(0, 0, 0, 0), 10)
		t.eq(lavas, 6)
		t.eq(Climate.roomSource(B.Stone), nil)
		t.eq(Climate.PLAYER_HU, 1)
		local made = Climate.addRoomSource(B.Chest, function()
			return -4
		end, 2)
		t.eq(made, 1)
		t.eq(assert(Climate.roomSource(B.Chest))(0, 0, 0, 0), -4)
		-- A cold source may have a check too (a cooler while it cools).
		local cooling = false
		Climate.addColdSource(B.GlowBlock, function()
			return cooling
		end)
		blocks["0,64,2"] = B.GlowBlock
		local _, cold = Climate.sources(view, 0, 64, 0, settings.ProximityRadius)
		t.eq(cold, nil, "not cooling")
		cooling = true
		_, cold = Climate.sources(view, 0, 64, 0, settings.ProximityRadius)
		t.eq(cold, 2, "cooling")
		-- (Registries are module state: leave the stand-ins idle for the specs after.)
		cooling = false
	end)

	t.test("climate: a source warms or cools only within its own radius (a space heater's, a fan's)", function()
		local blocks: { [string]: number } = {}
		local view = {
			getBlock = function(x, y, z)
				return blocks[`{x},{y},{z}`] or Blocks.AIR
			end,
			column = function(_x, _z)
				return 64, assert(Biomes.byName("Plains")).index
			end,
			skyOpen = function(_x, _y, _z)
				return true
			end,
		}
		local heat = Config.Seasons.Heat
		local r = settings.ProximityRadius
		local working = true
		local function check(): boolean
			return working
		end
		-- Stand-ins registered as Players/ToughAsNails registers the Electric Heater and the fan.
		Climate.addHeatSource(B.GoldBlock, check, nil, heat.SpaceHeaterRadius)
		Climate.addColdSource(B.EmeraldBlock, check, heat.FanRadius)
		t.ok(heat.FanRadius < r and heat.SpaceHeaterRadius <= r, "within what Tough As Nails looks at")
		blocks[`{heat.SpaceHeaterRadius},64,0`] = B.GoldBlock
		t.eq((Climate.sources(view, 0, 64, 0, r)), heat.SpaceHeaterRadius, "the space heater at its edge")
		blocks[`0,64,{heat.FanRadius + 1}`] = B.EmeraldBlock
		t.eq(select(2, Climate.sources(view, 0, 64, 0, r)), nil, "a fan one block past its radius")
		blocks[`0,64,{heat.FanRadius + 1}`] = nil
		blocks[`0,64,{-heat.FanRadius}`] = B.EmeraldBlock
		t.eq(select(2, Climate.sources(view, 0, 64, 0, r)), heat.FanRadius, "at its radius")
		-- A shorter reach for a heat source; registered again without one, the whole radius.
		Climate.addHeatSource(B.GoldBlock, check, nil, 2)
		t.eq((Climate.sources(view, 0, 64, 0, r)), nil, "3 blocks away, reaching 2")
		blocks["0,66,0"] = B.GoldBlock
		t.eq((Climate.sources(view, 0, 64, 0, r)), 2)
		blocks["0,66,0"] = nil
		Climate.addHeatSource(B.GoldBlock, check)
		t.eq((Climate.sources(view, 0, 64, 0, r)), heat.SpaceHeaterRadius)
		-- (Leave the stand-ins idle for the specs after.)
		working = false
	end)

	t.test("climate: the server registers the machines' room sources whatever thirst and temperature say", function()
		-- (Server Players/ToughAsNails can't run outside Roblox; its registrations are checked in its
		-- source: the room sources before the switches, the heat and cold sources, with the space
		-- heater's and the fan's radii, behind them.)
		local function code(path: string): string
			local source = fs.readFile(path)
			source = string.gsub(source, "%-%-%[(=*)%[.-%]%1%]", "")
			return (string.gsub(source, "%-%-[^\n]*", ""))
		end
		local tan = code("src/server/Players/ToughAsNails.luau")
		local start = assert(string.match(tan, "function ToughAsNailsServer%.start%(.-\nend\n"), "start")
		local rooms = string.find(start, "\n\tregisterRoomSources()\n", 1, true)
		local switch =
			string.find(start, "\n\tif thirstOn() or temperatureOn() then\n\t\tregisterHeatSources()", 1, true)
		t.ok(rooms ~= nil and switch ~= nil and rooms < switch, "room sources first, unconditionally")
		local roomSources = assert(string.match(tan, "local function registerRoomSources%(%)(.-)\nend\n"))
		for _, needle in
			{
				"Climate.addRoomSource(Blocks.id.Furnace,",
				"Climate.addRoomSource(Blocks.id.HeatGenerator, generator)",
				"Climate.addRoomSource(Blocks.id.CombustionGenerator, generator)",
				'{ "WoodStove", "OilHeater", "ElectricHeater", "AirConditioner", "ElectricFan" }',
			}
		do
			t.ok(string.find(roomSources, needle, 1, true) ~= nil, needle)
		end
		local heatSources = assert(string.match(tan, "local function registerHeatSources%(%)(.-)\nend\n"))
		t.eq(string.find(heatSources, "addRoomSource", 1, true), nil, "no room source behind the switches")
		for _, needle in
			{
				"Climate.addHeatSource(Blocks.id.ElectricHeater, heating, nil, heat.SpaceHeaterRadius)",
				"Climate.addColdSource(Blocks.id.ElectricFan, cooling, heat.FanRadius)",
			}
		do
			t.ok(string.find(heatSources, needle, 1, true) ~= nil, needle)
		end
	end)

	--[[ Protocol ]]

	t.test("protocol: Exertion, Drink and Survival round trips; malformed payloads", function()
		local report = { sprintCm = 1234, waterCm = 56, jumps = 3, sprintJumps = 2, sprinting = true }
		local back = assert(Protocol.decodeExertion(Protocol.encodeExertion(report)))
		for key, value in report do
			t.eq(back[key], value, key)
		end
		local bad = Protocol.encodeExertion(report)
		buffer.writeu8(bad, 6, 7)
		t.eq(Protocol.decodeExertion(bad), nil, "unknown flags")
		t.eq(Protocol.decodeExertion(buffer.create(3)), nil)

		local A = Protocol.DrinkAction
		local action, x, y, z = Protocol.decodeDrink(Protocol.encodeDrink(A.Fill, -12, 70, 99))
		t.eq(action, A.Fill)
		t.eq(x, -12)
		t.eq(y, 70)
		t.eq(z, 99)
		t.eq((Protocol.decodeDrink(Protocol.encodeDrink(A.Finish))), A.Finish)
		t.eq((Protocol.decodeDrink(Protocol.encodeDrink(9))), nil, "unknown action")
		t.eq((Protocol.decodeDrink(Protocol.encodeDrink(A.Hand, 2000000, 1, 0))), nil, "too far out")
		t.eq((Protocol.decodeDrink(buffer.create(0))), nil)

		local status = {
			thirstOn = true,
			temperatureOn = false,
			wet = true,
			warmth = true,
			chill = false,
			thirst = 13,
			hydration = 2.4,
			exhaustion = 1.5,
			temperature = -9,
			target = 4,
			frozen = 399,
			heat = 0,
			effect = 345,
			clemency = 299,
			-- (Minecraft's food bar: Shared/Hunger.)
			hungerOn = true,
			food = 7,
			saturation = 3.6,
			foodExhaustion = 2.5,
		}
		local payload = Protocol.encodeSurvival(status)
		-- (14 before the food bar's three bytes, 17 before the seasons' room and outside.)
		t.eq(buffer.len(payload), 19, "19 bytes")
		local decoded = assert(Protocol.decodeSurvival(payload))
		for key, value in status do
			if type(value) == "number" then
				t.near(decoded[key], value, 1e-9, key)
			else
				t.eq(decoded[key], value, key)
			end
		end
		status.temperature, status.target, status.warmth, status.chill = 10, -10, false, true
		decoded = assert(Protocol.decodeSurvival(Protocol.encodeSurvival(status)))
		t.ok(decoded.temperature == 10 and decoded.target == -10, "the scale's ends")
		t.ok(not decoded.warmth and decoded.chill, "the effect flags")
		status.clemency = 1e6
		t.eq(assert(Protocol.decodeSurvival(Protocol.encodeSurvival(status))).clemency, 65535, "clamped")
		local function broken(offset, write, value, why)
			local copy = Protocol.encodeSurvival(status)
			write(copy, offset, value)
			t.eq(Protocol.decodeSurvival(copy), nil, why)
		end
		broken(1, buffer.writeu8, 21, "thirst over 20")
		broken(0, buffer.writeu8, 64, "unknown flags (bit 5 is hunger's now)")
		broken(14, buffer.writeu8, 21, "food over 20")
		broken(15, buffer.writeu8, 201, "saturation over 20")
		status.hungerOn, status.food, status.saturation, status.foodExhaustion = false, 0, 0, 99
		decoded = assert(Protocol.decodeSurvival(Protocol.encodeSurvival(status)))
		t.ok(not decoded.hungerOn and decoded.food == 0 and decoded.saturation == 0, "hunger off, an empty bar")
		t.eq(decoded.foodExhaustion, 255 / 50, "exhaustion clamped to its byte")
		broken(4, buffer.writeu8, 21, "temperature over 10")
		broken(5, buffer.writeu8, 255, "target over 10")
		broken(6, buffer.writeu16, Temperature.EXTREME_TICKS + 1, "frozen over full")
		broken(8, buffer.writeu16, Temperature.EXTREME_TICKS + 1, "heat over full")
		t.eq(Protocol.decodeSurvival(buffer.create(10)), nil, "an old size")
		t.eq(Protocol.decodeSurvival(buffer.create(14)), nil, "the size before hunger")
		t.eq(Protocol.decodeSurvival(buffer.create(17)), nil, "the size before the seasons")
		-- The seasons' room (nil: none) and outside, in half steps.
		t.eq(decoded.room, nil, "no room")
		t.eq(decoded.outside, 0)
		local seasonal: any = status
		seasonal.room, seasonal.outside = -5.6, -9.2
		decoded = assert(Protocol.decodeSurvival(Protocol.encodeSurvival(status)))
		t.eq(decoded.room, -5.5, "half steps")
		t.eq(decoded.outside, -9)
		seasonal.room, seasonal.outside = 100, -100
		decoded = assert(Protocol.decodeSurvival(Protocol.encodeSurvival(status)))
		t.eq(decoded.room, 63.5, "clamped to the byte")
		t.eq(decoded.outside, -63.5)
		broken(18, buffer.writei8, Protocol.NO_ROOM, "an outside of -128")
		t.ok(Protocol.ServerMessage.Survival ~= nil and Protocol.ClientMessage.Drink ~= Protocol.ClientMessage.Exertion)
	end)
end
