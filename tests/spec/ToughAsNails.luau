--[[
	Tough As Nails: thirst (Minecraft's FoodData with water: exhaustion -> hydration -> thirst,
	the Thirst effect, regeneration that needs thirst, dehydration down to the floor), drinks
	(hand, dirty, purified; their chances with an injected random; bottles and canteens filling and
	emptying, creative's rules), movement exhaustion (Exertion: what the client measures, what the
	server allows), body temperature (the target from the climate, altitude, night, shelter,
	underground and the modifiers; the drift a level per ChangeTicks; hypothermia and
	hyperthermia timing; leather), the surroundings (Players/Climate over a fake world: heat and
	cold sources, checks), the recipes (bottles, the canteen, purification by smelting) and the
	Protocol messages.
]]

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

	t.test("thirst: the Thirst effect adds 0.025 exhaustion a tick and counts down", function()
		local state = Thirst.new()
		Thirst.giveEffect(state, 600)
		Thirst.giveEffect(state, 100)
		t.eq(state.effect, 600, "a longer one stays")
		for _ = 1, 200 do
			Thirst.tick(state, SURVIVAL, 20, 20)
		end
		t.eq(state.effect, 400)
		t.eq(state.hydration, 4, "200 x 0.025 = 5 exhaustion: a point")
		for _ = 1, 400 do
			Thirst.tick(state, SURVIVAL, 20, 20)
		end
		t.eq(state.effect, 0)
		t.eq(state.hydration, 2, "600 ticks: 15 exhaustion, 3 points and 3 left over")
		t.near(state.exhaustion, 3, 1e-6)
		-- HOT's sweating is `extra`.
		local hot = Thirst.new()
		for _ = 1, 420 do
			Thirst.tick(hot, SURVIVAL, 20, 20, settings.HotExhaustion)
		end
		t.eq(hot.hydration, 4, "0.01 a tick: a point every 400 ticks")
	end)

	t.test("thirst: dehydration hurts every 80 ticks down to the floor (normal difficulty)", function()
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
		t.eq(#hurts, 5)
		t.eq(hurts[1], 80, "first at 80 ticks")
		t.eq(hurts[2], 160)
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
			for _ = 1, 80 do
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

	--[[ Drinks ]]

	t.test("drinks: hand, dirty and purified water with their chances (injected random)", function()
		local state = Thirst.new()
		state.thirst, state.hydration = 10, 0
		t.ok(Drinks.apply(state, Drinks.HAND, rolls({ 0.74 })), "0.74 < 0.75: Thirst effect")
		t.eq(state.thirst, 11)
		t.near(state.hydration, 0.2, 1e-9)
		t.eq(state.effect, 600, "30 s")
		state.effect = 0
		t.ok(not Drinks.apply(state, Drinks.DIRTY, rolls({ 0.75 })), "0.75: none")
		t.eq(state.thirst, 15)
		t.eq(state.effect, 0)
		t.ok(not Drinks.apply(state, Drinks.PURIFIED, rolls({})), "purified never rolls")
		t.eq(state.thirst, 20)
		t.eq(Drinks.of(I.DirtyWaterBottle), Drinks.DIRTY)
		t.eq(Drinks.of(I.PurifiedWaterCanteen), Drinks.PURIFIED)
		t.eq(Drinks.of(I.GlassBottle), nil)
		t.eq(Drinks.of(nil), nil)
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
			cooled = false,
			leather = 0,
		}
		for key, value in overrides or {} do
			base[key] = value
		end
		return base
	end
	local function climate(name)
		return assert(Biomes.byName(name)).temperature
	end

	t.test("temperature: the target from the biome, altitude, night, shelter and underground", function()
		local ICY, COLD, NEUTRAL, WARM, HOT = -2, -1, 0, 1, 2
		t.eq(Temperature.target(env({ climate = climate("Tundra") })), ICY, "tundra")
		t.eq(Temperature.target(env({ climate = climate("Taiga") })), COLD, "taiga")
		t.eq(Temperature.target(env({ climate = climate("Taiga"), night = true })), ICY, "taiga at night")
		t.eq(Temperature.target(env({ climate = climate("Plains") })), NEUTRAL, "plains")
		t.eq(Temperature.target(env({ climate = climate("Plains"), night = true })), NEUTRAL, "plains at night")
		t.eq(Temperature.target(env({ climate = climate("Jungle") })), WARM, "jungle")
		t.eq(Temperature.target(env({ climate = climate("Desert") })), HOT, "desert by day")
		t.eq(Temperature.target(env({ climate = climate("Desert"), night = true })), WARM, "desert at night")
		t.eq(Temperature.target(env({ climate = climate("Desert"), skyOpen = false })), WARM, "a desert house")
		t.eq(
			Temperature.target(env({ climate = climate("Tundra"), skyOpen = false, y = 40, surface = 80 })),
			NEUTRAL,
			"underground: neutral"
		)
		t.eq(
			Temperature.target(env({ climate = climate("Tundra"), skyOpen = false, y = 70, surface = 80 })),
			ICY,
			"a shallow hole is still the tundra"
		)
		t.eq(Temperature.target(env({ climate = climate("JaggedPeaks"), y = 760, surface = 760 })), COLD, "peaks")
		t.eq(Temperature.target(env({ climate = climate("FrozenPeaks"), y = 760, surface = 760 })), ICY)
		t.eq(Temperature.target(env({ climate = climate("Plains"), y = 1000, surface = 80 })), ICY, "flying high")
		t.near(Temperature.climateValue(env({ climate = 0.5, y = 356 })), 0.4, 1e-9, "0.001 a block above 256")
		t.eq(Temperature.levelOf(-0.55), COLD, "borders belong to the warmer side")
		t.eq(Temperature.levelOf(0.7), HOT)
		t.eq(Temperature.name(5), "Hot")
	end)

	t.test("temperature: modifiers a level each (wet, sprinting, heat, cold, leather)", function()
		t.eq(Temperature.target(env({ wet = true })), -1, "wet cools")
		t.eq(Temperature.target(env({ sprinting = true })), 1, "sprinting warms")
		t.eq(Temperature.target(env({ heated = true })), 1, "a heat source")
		t.eq(Temperature.target(env({ cooled = true })), -1, "a cold source")
		t.eq(Temperature.target(env({ heated = true, cooled = true })), 0, "both cancel")
		t.eq(
			Temperature.target(env({ climate = climate("Desert"), heated = true, sprinting = true })),
			2,
			"HOT at most"
		)
		t.eq(Temperature.target(env({ climate = climate("Tundra"), wet = true })), -2, "ICY at least")
		t.eq(Temperature.target(env({ climate = climate("Taiga"), leather = 2 })), 0, "leather insulates")
		t.eq(Temperature.target(env({ climate = climate("Taiga"), leather = 1 })), -1, "one piece doesn't")
		t.eq(Temperature.target(env({ climate = climate("Jungle"), leather = 4 })), 1, "nor warms in the heat")
	end)

	t.test("temperature: one level per ChangeTicks towards the target", function()
		local state = Temperature.new()
		state.target = 2
		local steps = {}
		for tick = 1, 500 do
			local before = state.level
			Temperature.tick(state, SURVIVAL)
			if state.level ~= before then
				table.insert(steps, tick)
			end
			if tick == 1 then
				t.eq(Temperature.trend(state), 1, "rising")
			end
		end
		t.eq(#steps, 2)
		t.eq(steps[1], settings.ChangeTicks, "a level after 200 ticks")
		t.eq(steps[2], settings.ChangeTicks * 2)
		t.eq(state.level, 2)
		t.eq(Temperature.trend(state), 0)
		state.target = 0
		for _ = 1, settings.ChangeTicks - 1 do
			Temperature.tick(state, SURVIVAL)
		end
		t.eq(state.level, 2)
		state.target = 2
		Temperature.tick(state, SURVIVAL)
		state.target = 0
		Temperature.tick(state, SURVIVAL)
		t.eq(state.level, 2, "back on target restarts the count")
		-- Wet for WetTicks after the water.
		Temperature.soak(state)
		t.ok(Temperature.isWet(state))
		for _ = 1, settings.WetTicks do
			Temperature.tick(state, SURVIVAL)
		end
		t.ok(not Temperature.isWet(state), "dry again")
	end)

	t.test("temperature: hypothermia and hyperthermia (Minecraft's freezing timing)", function()
		local cold = Temperature.new()
		cold.level, cold.target = -2, -2
		local hurts = {}
		for tick = 1, 300 do
			local damage = Temperature.tick(cold, SURVIVAL)
			if damage > 0 then
				table.insert(hurts, tick)
			end
			if tick == 140 then
				t.eq(cold.frozen, 140, "fully frozen after 140 ticks")
			end
		end
		t.eq(hurts[1], 179, "the first hurt 40 ticks after freezing through")
		t.eq(hurts[2], 219, "then every 40")
		t.eq(#hurts, 4)
		cold.target = 0
		cold.delay = settings.ChangeTicks
		for _ = 1, settings.ChangeTicks do
			Temperature.tick(cold, SURVIVAL)
		end
		t.eq(cold.level, -1, "warming up")
		t.eq(cold.frozen, 138, "thaws 2 a tick once above ICY")
		for _ = 1, 69 do
			Temperature.tick(cold, SURVIVAL)
		end
		t.eq(cold.frozen, 0)

		local dressed = Temperature.new()
		dressed.level, dressed.target = -2, -2
		local damage = 0
		for _ = 1, 400 do
			damage += Temperature.tick(dressed, SURVIVAL, true)
		end
		t.eq(damage, 0, "leather: never frozen (freeze_immune_wearables)")
		t.eq(dressed.frozen, 0)

		local hot = Temperature.new()
		hot.level, hot.target = 2, 2
		damage = 0
		for _ = 1, 180 do
			damage += Temperature.tick(hot, ADVENTURE, true)
		end
		t.eq(hot.heat, 140)
		t.eq(damage, 1, "hyperthermia hurts the same way, leather or not")
		local frost, heat = Temperature.extremes(hot)
		t.eq(frost, 0)
		t.eq(heat, 1)

		Temperature.tick(hot, CREATIVE)
		t.eq(hot.heat, 0, "creative: cleared at once")
		damage = 0
		for _ = 1, 400 do
			damage += Temperature.tick(hot, CREATIVE)
		end
		t.eq(damage, 0)
		t.eq(hot.level, 2, "and the level stands still")
	end)

	--[[ Surroundings ]]

	t.test("climate: heat and cold sources around the player, and checks", function()
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
		local heated, cooled = Climate.sources(view, 0, 64, 0, r)
		t.ok(not heated and not cooled, "nothing around")
		put(r, 64, 0, Blocks.fluidId("Lava", 3))
		heated = Climate.sources(view, 0, 64, 0, r)
		t.ok(heated, "flowing lava at the edge")
		put(r, 64, 0, Blocks.AIR)
		put(r + 1, 64, 0, B.CaveLava)
		t.ok(not (Climate.sources(view, 0, 64, 0, r)), "one block too far")
		t.ok(Climate.isHeating(B.CaveLava), "the cave twin heats")
		t.ok(Climate.isHeating(B.Fire), "fire")
		put(0, 60, 2, B.PackedIce)
		heated, cooled = Climate.sources(view, 0, 64, 0, r)
		t.ok(cooled and not heated, "packed ice")
		-- A check decides for a block that heats only sometimes.
		local lit = false
		Climate.addHeatSource(B.CraftingTable, function()
			return lit
		end)
		put(1, 64, 1, B.CraftingTable)
		t.ok(not (Climate.sources(view, 0, 64, 0, r)), "unlit")
		lit = true
		t.ok((Climate.sources(view, 0, 64, 0, r)), "lit")

		local e = Climate.environment(view, 0.5, 64, 0.5, 18000, {
			wet = false,
			sprinting = true,
			burning = false,
			leather = 2,
		})
		t.eq(e.climate, climate("Plains"))
		t.ok(e.night, "18000 is midnight")
		t.ok(e.heated and e.cooled and e.sprinting)
		t.eq(e.leather, 2)
		t.eq(Temperature.target(e), 1, "plains at night, sprinting, both sources")
		t.eq(
			Climate.leatherPieces({ { item = I.LeatherHelmet, count = 1 }, nil, nil, { item = I.IronBoots, count = 1 } }),
			1
		)
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
			thirst = 13,
			hydration = 2.4,
			exhaustion = 1.5,
			level = -2,
			target = 1,
			frozen = 99,
			heat = 0,
			effect = 345,
		}
		local decoded = assert(Protocol.decodeSurvival(Protocol.encodeSurvival(status)))
		for key, value in status do
			if type(value) == "number" then
				t.near(decoded[key], value, 1e-9, key)
			else
				t.eq(decoded[key], value, key)
			end
		end
		local broken = Protocol.encodeSurvival(status)
		buffer.writeu8(broken, 1, 21)
		t.eq(Protocol.decodeSurvival(broken), nil, "thirst over 20")
		t.ok(Protocol.ServerMessage.Survival ~= nil and Protocol.ClientMessage.Drink ~= Protocol.ClientMessage.Exertion)
	end)
end
