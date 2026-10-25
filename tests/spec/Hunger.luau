--[[
	Minecraft's hunger (Shared/Hunger: 1.20.1's FoodData, tick by tick): the starting bar,
	exhaustion taking saturation before food (one step a tick, the cap of 40), eating's caps
	(FoodData.eat), the fast regeneration of a full bar with saturation (every 10 ticks, f / 6 for
	f exhaustion), the slow one at 18 (every 80 ticks for 6), starvation every 80 ticks down to
	the floor (normal difficulty: 1; 0 and 10 too), Minecraft's Hunger effect (0.005 x level a
	tick, from /effect, rotten flesh and raw chicken), creative and spectator untouched, the
	regeneration held by the extremes and the infection (`stopped`) and by thirst under 18
	(Tough As Nails: both bars high), naturalRegeneration off, the sprint rule (food > 6 or
	mayfly) in the physics, the HUD's shanks and jitter, the exhaustion table against
	FoodConstants, the server's glue read from its source, and hunger off restoring the game
	before the food bar (foods heal, thirst regenerates, the HUD's rows where they were).
]]

local fs = require("@lune/fs")

return function(t, shared, require, server, client)
	local Blocks = require(shared.Blocks)
	local Config = require(shared.Config)
	local Effects = require(shared.Effects)
	local Foods = require(shared.Items.Foods)
	local GameMode = require(shared.GameMode)
	local Hunger = require(shared.Hunger)
	local Items = require(shared.Items)
	local PlayerPhysics = require(shared.Movement.PlayerPhysics)
	local Thirst = require(shared.ToughAsNails.Thirst)
	local EffectCommand = require(server.Players.EffectCommand)
	local EffectRules = require(server.Players.EffectRules)
	local HudLayout = require(client.Ui.HudLayout)

	local SURVIVAL, CREATIVE, ADVENTURE, SPECTATOR =
		GameMode.SURVIVAL, GameMode.CREATIVE, GameMode.ADVENTURE, GameMode.SPECTATOR
	local E, I = Effects.id, Items.id
	local settings = Config.Hunger

	-- Runs `f` with Config.Hunger fields changed, then puts them back.
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

	local function near(a: number, b: number): boolean
		return math.abs(a - b) < 1e-9
	end

	-- A bar of `food` and `saturation`.
	local function bar(food: number, saturation: number): Hunger.State
		local state = Hunger.new()
		state.food, state.saturation = food, saturation
		return state
	end

	-- `ticks` ticks at `health` (of 20; it follows the heals and hurts when `follow`): the ticks
	-- that healed and how much, the ticks that hurt.
	local function run(
		state: Hunger.State,
		ticks: number,
		health: number,
		follow: boolean?,
		extra: number?,
		stopped: boolean?,
		thirst: number?
	)
		local heals: { { tick: number, amount: number } } = {}
		local hurts: { number } = {}
		for tick = 1, ticks do
			local damage, heal = Hunger.tick(state, SURVIVAL, health, 20, extra, stopped, thirst)
			if heal > 0 then
				table.insert(heals, { tick = tick, amount = heal })
			end
			if damage > 0 then
				table.insert(hurts, tick)
			end
			if follow then
				health = math.clamp(health + heal - damage, 0, 20)
			end
		end
		return heals, hurts, health
	end

	t.test("hunger: a full bar to start, exhaustion takes saturation before food (FoodData.tick)", function()
		local state = Hunger.new()
		t.eq(state.food, 20, "foodLevel 20")
		t.eq(state.saturation, 5, "saturationLevel 5")
		t.eq(state.exhaustion, 0)
		t.eq(state.timer, 0)
		t.ok(Hunger.on(), "on by default (Config.Hunger.Enabled)")
		Hunger.addExhaustion(state, 4)
		Hunger.tick(state, SURVIVAL, 20, 20)
		t.eq(state.saturation, 5, "4: nothing yet (Minecraft's > 4)")
		Hunger.addExhaustion(state, 0.5)
		Hunger.tick(state, SURVIVAL, 20, 20)
		t.eq(state.saturation, 4, "above 4: a point of saturation")
		t.near(state.exhaustion, 0.5, 1e-9, "4 taken off")
		state.saturation = 0.4
		Hunger.addExhaustion(state, 4)
		Hunger.tick(state, SURVIVAL, 20, 20)
		t.eq(state.saturation, 0, "a part point of saturation goes whole")
		t.eq(state.food, 20)
		Hunger.addExhaustion(state, 4)
		Hunger.tick(state, SURVIVAL, 20, 20)
		t.eq(state.food, 19, "then food")
		Hunger.addExhaustion(state, 100)
		t.eq(state.exhaustion, 40, "exhaustion caps at 40")
		Hunger.tick(state, SURVIVAL, 20, 20)
		t.eq(state.food, 18, "one point a tick")
		t.near(state.exhaustion, 36, 1e-9)
		Hunger.addExhaustion(state, -5)
		Hunger.addExhaustion(state, 0 / 0)
		t.near(state.exhaustion, 36, 1e-9, "nonsense adds nothing")
		local empty = bar(0, 0)
		Hunger.addExhaustion(empty, 30)
		for _ = 1, 10 do
			Hunger.tick(empty, SURVIVAL, 20, 20)
		end
		t.eq(empty.food, 0, "never below 0")
	end)

	t.test("hunger: eating is FoodData.eat (food to 20, saturation to the new food)", function()
		local state = bar(10, 0)
		Hunger.eat(state, 8, 0.8)
		t.eq(state.food, 18, "a steak: 8")
		t.ok(near(state.saturation, 12.8), "8 x 0.8 x 2 = 12.8")
		Hunger.eat(state, 8, 0.8)
		t.eq(state.food, 20, "food caps at 20")
		t.eq(state.saturation, 20, "saturation caps at the food")
		local poor = bar(3, 0)
		Hunger.eat(poor, 4, 0.1)
		t.eq(poor.food, 7, "rotten flesh: 4")
		t.ok(near(poor.saturation, 0.8), "4 x 0.1 x 2")
		local low = bar(1, 0)
		Hunger.eat(low, 1, 5)
		t.eq(low.saturation, 2, "never above the new food")
		-- Who may eat (Player.canEat): not at 20, unless invulnerable.
		t.ok(not Hunger.canEat(20, SURVIVAL) and Hunger.canEat(19, ADVENTURE))
		t.ok(Hunger.canEat(20, CREATIVE) and Hunger.canEat(20, SPECTATOR), "invulnerable players may")
		t.ok(Hunger.needsFood(19) and not Hunger.needsFood(20))
	end)

	t.test("hunger: a full bar with saturation heals f / 6 every 10 ticks for f exhaustion", function()
		-- Food 20, saturation 5, health 10 (Minecraft 1.11's fast regeneration).
		local state = Hunger.new()
		local heals = run(state, 60, 10)
		t.eq(heals[1].tick, 10, "first at 10 ticks")
		t.ok(near(heals[1].amount, 5 / 6), "min(5, 6) / 6")
		t.eq(heals[2].tick, 20, "every 10")
		-- (Tick 10 added 5 exhaustion; tick 11 turned 4 of it into a point of saturation.)
		t.ok(near(heals[2].amount, 4 / 6), "a point of saturation less")
		t.eq(heals[3].tick, 30)
		t.ok(near(heals[3].amount, 3 / 6))
		t.eq(heals[4].tick, 40)
		t.ok(near(heals[4].amount, 3 / 6), "tick 30's 3 left exhaustion at 4: no point (> 4)")
		for _, heal in heals do
			t.eq(heal.tick % 10, 0, "on the tens")
		end
		-- Lots of saturation: at most 6 a heal (half a heart).
		local rich = bar(20, 20)
		local first = run(rich, 10, 4)
		t.eq(#first, 1)
		t.ok(near(first[1].amount, 1), "min(20, 6) / 6: half a heart")
		t.near(rich.exhaustion, 6, 1e-9, "for 6 exhaustion")
		-- Until the saturation is gone, then the slow branch at 18+ (the food has gone down).
		local long = Hunger.new()
		local healed, _, health = run(long, 2000, 2, true)
		t.ok(#healed > 0 and health > 2, "health comes back")
		t.ok(long.saturation == 0 or health >= 20, "the saturation burnt into health")
		-- Not hurt: nothing to heal, the timer stays at 0.
		local fine = Hunger.new()
		t.eq(#run(fine, 100, 20), 0, "full health: nothing")
		t.eq(fine.timer, 0)
		t.eq(fine.saturation, 5, "and nothing spent")
	end)

	t.test("hunger: at 18 or more, half a heart every 80 ticks for 6 exhaustion", function()
		local state = bar(18, 0)
		local heals = run(state, 400, 10)
		t.eq(#heals, 1, "one heal, then the food is under 18")
		t.eq(heals[1].tick, 80, "at 80 ticks")
		t.eq(heals[1].amount, 1, "half a heart")
		t.eq(state.food, 17, "its 6 exhaustion cost a point the next tick (no saturation)")
		t.near(state.exhaustion, 2, 1e-9)
		t.eq(state.timer, 0, "17: the timer stops")
		local more = bar(19, 0)
		local twice = run(more, 400, 10)
		t.eq(#twice, 2)
		t.eq(twice[2].tick, 160)
		t.eq(more.food, 17, "19 -> 18 -> 17")
		local short = bar(17, 0)
		t.eq(#run(short, 400, 10), 0, "17: none")
		-- Food 20 without saturation is the slow branch.
		local plain = bar(20, 0)
		local slow = run(plain, 100, 10)
		t.eq(#slow, 1)
		t.eq(slow[1].tick, 80)
	end)

	t.test("hunger: starvation hurts every 80 ticks down to the floor (normal difficulty: 1)", function()
		local state = bar(0, 0)
		local _, hurts = run(state, 400, 10)
		t.eq(#hurts, 5)
		t.eq(hurts[1], 80, "first at 80")
		t.eq(hurts[2], 160)
		local _, low = run(bar(0, 0), 400, 1)
		t.eq(#low, 0, "never at half a heart (health > 1)")
		local _, _, health = run(bar(0, 0), 2000, 20, true)
		t.eq(health, 1, "down to half a heart, no further")
		with({ StarvationFloor = 0 }, function()
			local _, hard, left = run(bar(0, 0), 2000, 20, true)
			t.eq(left, 0, "floor 0 (hard): to death")
			t.eq(#hard, 20)
		end)
		with({ StarvationFloor = 10 }, function()
			local _, _, easy = run(bar(0, 0), 2000, 20, true)
			t.eq(easy, 10, "floor 10 (easy): five hearts")
		end)
		-- The timer goes round even where it can't hurt (FoodData resets it either way).
		local floor = bar(0, 0)
		run(floor, 80, 1)
		t.eq(floor.timer, 0)
		-- Eating stops it.
		local fed = bar(0, 0)
		run(fed, 50, 10)
		Hunger.eat(fed, 2, 0.3)
		local _, after = run(fed, 200, 10)
		t.eq(#after, 0, "fed: no more")
		-- Regeneration's hold never spares starvation.
		local _, held = run(bar(0, 0), 160, 10, false, 0, true, 0)
		t.eq(#held, 2, "held and thirsty: still starving")
	end)

	t.test("hunger: Minecraft's Hunger effect adds 0.005 x level a tick (/effect, rotten flesh)", function()
		local effects = EffectRules.new()
		t.eq(Hunger.effectExhaustion(EffectRules.levels(effects)), 0, "none")
		EffectRules.give(effects, E.Hunger, 600, 0)
		t.ok(near(Hunger.effectExhaustion(EffectRules.levels(effects)), 0.005), "level I: 0.005")
		EffectRules.give(effects, E.Speed, 600, 0)
		t.ok(near(Hunger.effectExhaustion(EffectRules.levels(effects)), 0.005), "other effects add nothing")
		t.ok(near(Hunger.effectExhaustion({ [E.Hunger] = 2 }), 0.015), "level III: 0.015")
		-- Rotten flesh's 30 s at level I: 600 ticks, 3 exhaustion, under a point.
		local state = Hunger.new()
		local ticks = 0
		while EffectRules.has(effects, E.Hunger) and ticks < 10000 do
			Hunger.tick(state, SURVIVAL, 20, 20, Hunger.effectExhaustion(EffectRules.levels(effects)))
			EffectRules.tick(effects, SURVIVAL, 20, 20)
			ticks += 1
		end
		t.ok(ticks >= 599 and ticks <= 601, `30 s of it ({ticks} ticks)`)
		t.ok(math.abs(state.exhaustion - 3) < 0.01, `3 exhaustion ({state.exhaustion})`)
		t.eq(state.saturation, 5, "not a point yet")
		-- A long one: a point every 800 ticks at level I.
		local long = Hunger.new()
		run(long, 801, 20, false, 0.005)
		t.eq(long.saturation, 4, "801 ticks: past 4")
		with({ EffectExhaustion = 0.01 }, function()
			t.ok(near(Hunger.effectExhaustion({ [E.Hunger] = 0 }), 0.01), "Config's rate")
		end)
		-- /effect gives it by name, as any effect.
		local given: { any } = {}
		local steve = { key = "steve", name = "Steve", displayName = "Steve" }
		local result = EffectCommand.run("/effect give @s minecraft:hunger 30 1", {
			source = steve,
			players = { steve },
			mayUse = true,
			give = function(key: any, effect: number, seconds: number, amplifier: number): boolean
				table.insert(given, { key = key, effect = effect, ticks = seconds, amplifier = amplifier })
				return true
			end,
			clear = function(): number
				return 0
			end,
		})
		t.ok(result ~= nil and result.feedback[1] == "Applied effect Hunger to Steve", "Minecraft's wording")
		t.ok(given[1] and given[1].effect == E.Hunger and given[1].amplifier == 1 and given[1].ticks == 600)
	end)

	t.test("hunger: creative and spectator players stand still (and may always eat and sprint)", function()
		for _, mode in { CREATIVE, SPECTATOR } do
			local state = bar(0, 0)
			Hunger.addExhaustion(state, 3)
			local hurt, healed = 0, 0
			for _ = 1, 400 do
				local damage, heal = Hunger.tick(state, mode, 10, 20, 0.5)
				hurt += damage
				healed += heal
			end
			t.eq(hurt, 0, `{mode}: no starvation`)
			t.eq(healed, 0, `{mode}: no regeneration`)
			t.eq(state.exhaustion, 3, `{mode}: nothing drains, the effect's neither`)
			t.eq(state.timer, 0)
			t.ok(Hunger.canEat(20, mode), `{mode} eats whenever`)
			t.ok(Hunger.canSprint(0, mode), `{mode} sprints whenever (mayfly)`)
		end
	end)

	t.test("hunger: no regeneration while held (the extremes, the infection) or thirst is under 18", function()
		-- `stopped`: fully frozen or overheated (Temperature.stopsRegeneration) or the infection
		-- from stage III (Players/ToughAsNails' regeneration block): neither branch runs.
		for _, case in { { 20, 5 }, { 20, 0 }, { 18, 0 } } do
			local state = bar(case[1], case[2])
			local heals = run(state, 400, 10, false, 0, true)
			t.eq(#heals, 0, `food {case[1]}, saturation {case[2]}: held`)
			t.eq(state.timer, 0, "the timer waits at 0")
			t.eq(state.exhaustion, 0, "none of its exhaustion spent")
		end
		-- Tough As Nails' thirst rules regeneration too: both bars high.
		t.eq(#run(Hunger.new(), 200, 10, false, 0, false, 17), 0, "thirst 17: none")
		t.eq(#run(bar(18, 0), 200, 10, false, 0, false, 17), 0, "slow branch too")
		t.ok(#run(Hunger.new(), 200, 10, false, 0, false, 18) > 0, "thirst 18: heals")
		t.ok(#run(Hunger.new(), 200, 10, false, 0, false, nil) > 0, "thirst with no say: heals")
		-- Minecraft's naturalRegeneration rule off: never.
		with({ NaturalRegeneration = false }, function()
			t.eq(#run(Hunger.new(), 400, 10), 0, "naturalRegeneration false")
			local _, hurts = run(bar(0, 0), 80, 10)
			t.eq(#hurts, 1, "starvation still")
		end)
		-- Thirst's own regeneration is retired while hunger is on: the server always holds it
		-- (Thirst.tick's `stopped`), and dehydration stays.
		local function code(path: string): string
			local source = fs.readFile(path)
			source = string.gsub(source, "%-%-%[(=*)%[.-%]%1%]", "")
			return (string.gsub(source, "%-%-[^\n]*", ""))
		end
		local tan = code("src/server/Players/ToughAsNails.luau")
		t.ok(string.match(tan, "Thirst%.tick%(.-stopped or hungerOn%(%),") ~= nil, "thirst's held with hunger on")
		local thirst = Thirst.new()
		local back = 0
		for _ = 1, 200 do
			back += select(2, Thirst.tick(thirst, SURVIVAL, 10, 20, 0, false, true))
		end
		t.eq(back, 0, "held: thirst heals nothing")
		local dry = Thirst.new()
		dry.thirst, dry.hydration = 0, 0
		local hurt = 0
		for _ = 1, 120 do
			hurt += (Thirst.tick(dry, SURVIVAL, 10, 20, 0, false, true))
		end
		t.eq(hurt, 1, "dehydration still hurts")
		t.ok(string.find(tan, "if rules then thirst.thirst else nil", 1, true) ~= nil, "thirst's say goes to hunger")
		t.ok(
			string.find(tan, "hungerOn() or (thirstOn() and Config.ToughAsNails.ThirstRegeneration)", 1, true) ~= nil,
			"Roblox's own regeneration goes with hunger on"
		)
	end)

	t.test("hunger: no sprint at 6 or less (LocalPlayer.aiStep), flying modes exempt", function()
		t.ok(Hunger.canSprint(7, SURVIVAL), "7: sprints")
		t.ok(not Hunger.canSprint(6, SURVIVAL), "6: no")
		t.ok(not Hunger.canSprint(0, ADVENTURE))
		t.ok(Hunger.canSprint(6, CREATIVE), "mayfly")
		-- The physics: no start, and a running sprint stops.
		local world: PlayerPhysics.World = {
			getBlock = function(_x: number, y: number, _z: number): number?
				return if y <= 0 then Blocks.id.Stone else Blocks.AIR
			end,
		}
		local input: PlayerPhysics.Input = {
			moveX = 1,
			moveZ = 0,
			forward = 1,
			facingX = 1,
			facingZ = 0,
			lookY = 0,
			jump = false,
			sneak = false,
			sprint = true,
		}
		local hungry = PlayerPhysics.new(0.5, 1, 0.5)
		hungry.onGround = true
		hungry.tooHungry = true
		for _ = 1, 5 do
			PlayerPhysics.tick(hungry, input, world)
		end
		t.ok(not hungry.sprinting, "too hungry: the sprint key does nothing")
		local runner = PlayerPhysics.new(0.5, 1, 0.5)
		runner.onGround = true
		for _ = 1, 5 do
			PlayerPhysics.tick(runner, input, world)
		end
		t.ok(runner.sprinting, "fed: it sprints")
		runner.tooHungry = true
		PlayerPhysics.tick(runner, input, world)
		t.ok(not runner.sprinting, "the bar drops to 6: the sprint stops")
		local flyer = PlayerPhysics.new(0.5, 1, 0.5)
		flyer.onGround = true
		PlayerPhysics.setGameMode(flyer, CREATIVE)
		flyer.tooHungry = true
		for _ = 1, 5 do
			PlayerPhysics.tick(flyer, input, world)
		end
		t.ok(flyer.sprinting, "creative (mayfly) sprints at any food")
		-- The server doesn't believe the sprint flag either (Players/ToughAsNails' reports).
		local tan = fs.readFile("src/server/Players/ToughAsNails.luau")
		t.ok(string.find(tan, "Hunger.canSprint(record.hunger.food, mode)", 1, true) ~= nil, "the server's check")
		local controller = fs.readFile("src/client/Player/MovementController.luau")
		t.ok(string.find(controller, "state.tooHungry = SurvivalState.tooHungry(", 1, true) ~= nil, "the client's")
	end)

	t.test("hunger: foods fill the bar with Minecraft's nutrition; the eating rule is the bar's", function()
		local expected = {
			[I.CookedBeef] = { 8, 0.8 },
			[I.CookedPorkchop] = { 8, 0.8 },
			[I.CookedMutton] = { 6, 0.8 },
			[I.CookedChicken] = { 6, 0.6 },
			[I.RawBeef] = { 3, 0.3 },
			[I.RawPorkchop] = { 3, 0.3 },
			[I.RawMutton] = { 2, 0.3 },
			[I.RawChicken] = { 2, 0.3 },
			[I.RottenFlesh] = { 4, 0.1 },
			[I.CannedBeans] = { 6, 0.6 },
			[I.CannedPeaches] = { 4, 0.3 },
			[I.Crackers] = { 2, 0.1 },
			[I.ChocolateBar] = { 3, 0.3 },
			[I.MilitaryRation] = { 8, 0.8 },
		}
		-- (The listed foods by their numbers, every other food at least fills the bar: no count of
		-- foods, so new content's leave it alone.)
		for item, food in Foods.ITEMS do
			if Foods.isMedical(food) then
				t.eq(food.nutrition, nil, `{Items.displayName(item)}: medicine has no nutrition`)
			else
				t.ok((food.nutrition or 0) > 0, `{Items.displayName(item)} fills the bar`)
			end
		end
		for item, want in expected do
			local food = Foods.ITEMS[item]
			t.ok(food ~= nil and not Foods.isMedical(food), `{Items.displayName(item)} is a food`)
			if food then
				t.eq(food.nutrition, want[1], `{Items.displayName(item)}'s nutrition`)
				t.eq(food.saturation, want[2], `{Items.displayName(item)}'s saturation`)
			end
		end
		-- A steak on an empty stomach, through Foods.finish's food bar hook (server Players/Eating).
		local state = bar(4, 0)
		local healed = 0
		Foods.finish(Foods.of(I.CookedBeef) :: Foods.Food, {
			heal = function(halfHearts: number)
				healed += halfHearts
			end,
			feed = function(nutrition: number, modifier: number)
				Hunger.eat(state, nutrition, modifier)
			end,
			cure = function() end,
			setBack = function() end,
			infectionStage = function(): number
				return 0
			end,
			give = function() end,
			thirst = function() end,
			random = function(): number
				return 0.99
			end,
		})
		t.eq(state.food, 12)
		t.ok(near(state.saturation, 12), "12.8 held to the new food (12)")
		t.eq(healed, 0, "fed, not healed")
		-- The rule: the bar, not the health (Player.canEat).
		local steak = Foods.of(I.CookedBeef) :: Foods.Food
		local function none(): boolean
			return false
		end
		t.ok(Foods.canUse(steak, 20, 20, SURVIVAL, none, 12), "full health, hungry: eats")
		t.ok(not Foods.canUse(steak, 2, 20, SURVIVAL, none, 20), "hurt, full: doesn't")
		t.eq(Foods.riskEffect(Foods.of(I.RottenFlesh) :: Foods.Food, true), E.Hunger, "rotten flesh: Hunger")
		t.eq(Foods.riskEffect(Foods.of(I.RawChicken) :: Foods.Food, true), E.Hunger, "raw chicken: Hunger")
		t.eq(Foods.riskEffect(Foods.of(I.Crackers) :: Foods.Food, true), E.Thirst, "crackers: thirst")
		t.eq(Foods.riskEffect(steak, true), nil, "a steak: none")
	end)

	t.test("hunger: the HUD's shanks (from the right, half for an odd point) and their jitter", function()
		local function states(food: number): string
			local out = {}
			for i = 1, 10 do
				out[i] = tostring(Hunger.shank(food, i))
			end
			return table.concat(out)
		end
		t.eq(states(20), "2222222222", "full")
		t.eq(states(19), "2222222221", "an odd point: the last (leftmost) is half")
		t.eq(states(7), "2221000000", "filled from the right")
		t.eq(states(1), "1000000000")
		t.eq(states(0), "0000000000")
		-- Gui.renderPlayerHealth: without saturation, on ticks where tick % (food x 3 + 1) == 0.
		t.ok(not Hunger.jitters(0.1, 20, 61), "saturation left: still")
		t.ok(Hunger.jitters(0, 20, 61), "61 % 61")
		t.ok(not Hunger.jitters(0, 20, 60))
		t.ok(Hunger.jitters(0, 0, 7), "starving: every tick")
		-- Tough As Nails' droplets a row above the shanks (HudLayout.rows; tests/spec/HudLayout).
		local rows = HudLayout.rows(true)
		t.eq(rows.food, rows.hearts)
		t.eq(rows.thirst, (rows.food :: number) - HudLayout.ROW)
	end)

	t.test("hunger: exhaustion is Minecraft's FoodConstants, the same as thirst's (and attacks)", function()
		for key, value in Thirst.EXHAUSTION do
			t.eq(Hunger.EXHAUSTION[key], value, `{key}: the same for food and water`)
		end
		t.eq(Hunger.EXHAUSTION.attack, 0.1, "EXHAUSTION_ATTACK, the food bar's alone")
		t.eq(Thirst.EXHAUSTION.attack, nil, "thirst stays as it was")
		local tan = fs.readFile("src/server/Players/ToughAsNails.luau")
		for _, needle in
			{
				"Hunger.addExhaustion(hunger, Hunger.EXHAUSTION.hurt)",
				"Hunger.addExhaustion(record.hunger, exhaustion)",
				"Hunger.addExhaustion(record.hunger, Hunger.EXHAUSTION.mine)",
				"Hunger.addExhaustion(record.hunger, Hunger.EXHAUSTION.attack)",
				"Hunger.effectExhaustion(EffectsServer.levels(player))",
				"hunger = Hunger.new(),",
			}
		do
			t.ok(string.find(tan, needle, 1, true) ~= nil, needle)
		end
		local mobs = fs.readFile("src/server/Mobs/Mobs.luau")
		t.ok(string.find(mobs, "ToughAsNails.attacked(player)", 1, true) ~= nil, "an attack that landed")
		-- The sweating of the HOT zone stays thirst's.
		t.eq(string.find(tan, "Hunger.addExhaustion(record.hunger, Config.ToughAsNails.HotExhaustion", 1, true), nil)
		-- Eating fills the bar through server Players/Eating.
		local eating = fs.readFile("src/server/Players/Eating.luau")
		t.ok(string.find(eating, "Hunger.eat(hunger, nutrition, saturationModifier)", 1, true) ~= nil)
	end)

	t.test("hunger: off, the game before the food bar (foods heal, thirst rules, the rows as they were)", function()
		with({ Enabled = false }, function()
			t.ok(not Hunger.on())
			-- Foods: no food bar (nil), so they heal by health.
			local steak = Foods.of(I.CookedBeef) :: Foods.Food
			local function none(): boolean
				return false
			end
			t.ok(Foods.canUse(steak, 10, 20, SURVIVAL, none, nil), "hurt: eats")
			t.ok(not Foods.canUse(steak, 20, 20, SURVIVAL, none, nil), "full health: doesn't")
			local healed, thirst = 0, 0
			local function finish(item: number)
				Foods.finish(Foods.of(item) :: Foods.Food, {
					heal = function(halfHearts: number)
						healed += halfHearts
					end,
					cure = function() end,
					setBack = function() end,
					infectionStage = function(): number
						return 0
					end,
					give = function()
						error("no status effect with hunger off")
					end,
					thirst = function(ticks: number)
						thirst += ticks
					end,
					random = function(): number
						return 0.1
					end,
				})
			end
			finish(I.CookedBeef)
			t.eq(healed, 4, "a steak heals 2 hearts, as before")
			finish(I.RottenFlesh)
			t.eq(thirst, 600, "rotten flesh's risk is the Thirst effect, as before")
			-- Thirst regenerates by its own rule (the server passes `stopped` only when held).
			local water = Thirst.new()
			local back = 0
			for _ = 1, 80 do
				back += select(2, Thirst.tick(water, SURVIVAL, 10, 20, 0, false, false))
			end
			t.eq(back, 1, "thirst's regeneration, every 80 ticks")
		end)
		-- The HUD's rows without the shanks are exactly the old ones (tests/spec/HudLayout).
		local off = HudLayout.rows(false)
		t.ok(off.food == nil and off.height == 70 and off.thirst == off.hearts, "the old rows")
	end)
end
