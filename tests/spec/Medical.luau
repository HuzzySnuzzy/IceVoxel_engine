--[[
	The zombie apocalypse's food, water and medical supplies (Shared/Items/Foods,
	Shared/ToughAsNails/Drinks, Shared/Items/Tooltip): who may use each one (Foods.canUse: hurt,
	bleeding for a bandage, infected for antibiotics and a poultice, a treat any time, creative
	whenever, a spectator never), how long each is held, what finishing one does through the
	server's hooks (Foods.finish, as server Players/Eating plays it: healing, cures, effects, the
	old Thirst risk), a bandage stopping a bleeding player's Bleeding (server Players/EffectRules),
	the ruins' bottled water and soda as drinks, and the tooltips ("When used:", "Cures Bleeding").
]]

return function(t, shared, require, server)
	local Effects = require(shared.Effects)
	local Foods = require(shared.Items.Foods)
	local GameMode = require(shared.GameMode)
	local Items = require(shared.Items)
	local Tooltip = require(shared.Items.Tooltip)
	local Drinks = require(shared.ToughAsNails.Drinks)
	local Thirst = require(shared.ToughAsNails.Thirst)
	local EffectRules = require(server.Players.EffectRules)

	local I, E = Items.id, Effects.id
	local SURVIVAL, ADVENTURE, CREATIVE, SPECTATOR =
		GameMode.SURVIVAL, GameMode.ADVENTURE, GameMode.CREATIVE, GameMode.SPECTATOR

	local function food(item: number): Foods.Food
		local found = Foods.of(item)
		assert(found, `{Items.displayName(item)} is food`)
		return found
	end
	local function having(...: string): (name: string) -> boolean
		local set = {}
		for _, name in { ... } do
			set[name] = true
		end
		return function(name: string): boolean
			return set[name] == true
		end
	end
	local none = having()

	t.test("medical: who may use what (hurt, bleeding, infected, any time, creative)", function()
		local bandage, medkit = food(I.Bandage), food(I.Medkit)
		local painkillers, chocolate = food(I.Painkillers), food(I.ChocolateBar)
		local beans, steak = food(I.CannedBeans), food(I.CookedBeef)
		-- Hurt: everything that heals.
		for _, item in { I.Bandage, I.Medkit, I.Painkillers, I.CannedBeans, I.CookedBeef, I.MilitaryRation } do
			t.ok(Foods.canUse(food(item), 10, 20, SURVIVAL, none), `{Items.displayName(item)} when hurt`)
			t.ok(not Foods.canUse(food(item), 20, 20, SURVIVAL, none), `{Items.displayName(item)} not at full health`)
		end
		-- Bleeding at full health: bandage and medkit, not painkillers or food.
		local bleeding = having("Bleeding")
		t.ok(Foods.canUse(bandage, 20, 20, SURVIVAL, bleeding), "a bandage on a bleeding player")
		t.ok(Foods.canUse(medkit, 20, 20, ADVENTURE, bleeding), "a medkit too, in adventure")
		t.ok(not Foods.canUse(painkillers, 20, 20, SURVIVAL, bleeding), "painkillers don't stop bleeding")
		t.ok(not Foods.canUse(beans, 20, 20, SURVIVAL, bleeding))
		-- A treat with effects any time; medicine with effects only for what it treats.
		t.ok(Foods.canUse(chocolate, 20, 20, SURVIVAL, none), "chocolate at full health")
		t.ok(not Foods.isMedical(chocolate) and Foods.isMedical(painkillers))
		-- Creative whenever; a spectator never.
		t.ok(Foods.canUse(steak, 20, 20, CREATIVE, none))
		t.ok(Foods.canUse(food(I.Antibiotics), 20, 20, CREATIVE, none))
		for _, item in { I.Bandage, I.ChocolateBar, I.Antibiotics } do
			t.ok(not Foods.canUse(food(item), 4, 20, SPECTATOR, having("Bleeding", "Infection")), "a spectator never")
		end
		-- canEat is the plain food's rule.
		t.ok(Foods.canEat(10, 20, SURVIVAL) and not Foods.canEat(20, 20, SURVIVAL))
		t.ok(Foods.canEat(20, 20, CREATIVE) and not Foods.canEat(4, 20, SPECTATOR))
	end)

	t.test("medical: with hunger on, food goes by the food bar (Player.canEat), medicine by health", function()
		local beans, steak, chocolate = food(I.CannedBeans), food(I.CookedBeef), food(I.ChocolateBar)
		local bandage, painkillers = food(I.Bandage), food(I.Painkillers)
		-- (The last argument is the food bar; nil is hunger off, the tests above.)
		t.ok(Foods.canUse(steak, 20, 20, SURVIVAL, none, 19), "full health, a bar below 20: eaten")
		t.ok(not Foods.canUse(steak, 4, 20, SURVIVAL, none, 20), "hurt, a full bar: not eaten")
		t.ok(not Foods.canUse(beans, 4, 20, ADVENTURE, none, 20))
		t.ok(Foods.canUse(beans, 4, 20, ADVENTURE, none, 0), "starving")
		t.ok(Foods.canUse(chocolate, 20, 20, SURVIVAL, none, 20), "a treat any time (canAlwaysEat)")
		t.ok(Foods.canUse(steak, 20, 20, CREATIVE, none, 20), "creative whenever")
		t.ok(not Foods.canUse(steak, 4, 20, SPECTATOR, none, 0), "a spectator never")
		-- Medicine heals as ever, the food bar has no say.
		t.ok(Foods.canUse(painkillers, 10, 20, SURVIVAL, none, 20), "hurt: painkillers, a full bar or not")
		t.ok(not Foods.canUse(painkillers, 20, 20, SURVIVAL, none, 2), "not at full health")
		t.ok(Foods.canUse(bandage, 20, 20, SURVIVAL, having("Bleeding"), 20))
		t.ok(Foods.canEat(20, 20, SURVIVAL, 19) and not Foods.canEat(4, 20, SURVIVAL, 20))
		for item, entry in Foods.ITEMS do
			t.eq(
				Foods.nourishes(entry),
				not Foods.isMedical(entry),
				`{Items.displayName(item)}: food feeds, medicine heals`
			)
		end
	end)

	t.test("medical: how long each is held, its sound, no burp for medicine", function()
		local expected = {
			[I.Bandage] = 40,
			[I.Medkit] = 80,
			[I.Antibiotics] = 32,
			[I.HerbalPoultice] = 40,
			[I.Painkillers] = 24,
			[I.CannedBeans] = 32,
			[I.CannedPeaches] = 32,
			[I.Crackers] = 24,
			[I.ChocolateBar] = 24,
			[I.MilitaryRation] = 48,
			[I.CookedBeef] = 32,
		}
		for item, ticks in expected do
			t.eq(Foods.useTicks(food(item)), ticks, Items.displayName(item))
		end
		t.eq(food(I.Bandage).sound, "item.bandage.apply")
		t.eq(food(I.HerbalPoultice).sound, "item.bandage.apply", "the poultice is wrapped on like a bandage")
		t.eq(food(I.Medkit).sound, "item.medkit.use")
		t.eq(food(I.Antibiotics).sound, "item.pills.swallow")
		t.eq(food(I.Painkillers).sound, "item.pills.swallow")
		for _, item in { I.Bandage, I.Medkit, I.Antibiotics, I.HerbalPoultice, I.Painkillers } do
			t.ok(Foods.isMedical(food(item)), `{Items.displayName(item)} is medicine (no burp)`)
		end
		for _, item in { I.CannedBeans, I.ChocolateBar, I.MilitaryRation, I.RottenFlesh } do
			t.ok(not Foods.isMedical(food(item)) and food(item).sound == nil, `{Items.displayName(item)} is eaten`)
		end
		t.eq(food(I.CannedBeans).heal, 6)
		t.eq(food(I.MilitaryRation).heal, 8)
		t.eq(food(I.Medkit).heal, 8)
	end)

	-- Finishes `item` through fake hooks (an infection at `stage`, 0 by default; `hunger` true: the
	-- food bar's hook is there, Minecraft's hunger on): what was healed, fed, cured, given and
	-- whether the infection went back and thirst was given.
	local function finish(item: number, roll: number?, stage: number?, hunger: boolean?)
		local log = {
			healed = 0,
			fed = 0,
			saturation = 0,
			cured = {} :: { string },
			given = {} :: { number },
			setBack = false,
			thirst = 0,
		}
		Foods.finish(food(item), {
			feed = if hunger
				then function(nutrition: number, modifier: number)
					log.fed += nutrition
					log.saturation += nutrition * modifier * 2
				end
				else nil,
			heal = function(halfHearts: number)
				log.healed += halfHearts
			end,
			cure = function(name: string)
				table.insert(log.cured, name)
			end,
			setBack = function()
				log.setBack = true
			end,
			infectionStage = function(): number
				return stage or 0
			end,
			give = function(effect: number, ticks: number, amplifier: number)
				table.insert(log.given, effect)
				t.ok(ticks > 0 and amplifier >= 0, "a real effect")
			end,
			thirst = function(ticks: number)
				log.thirst += ticks
			end,
			random = function(): number
				return roll or 0.99
			end,
		})
		return log
	end

	t.test("medical: finishing one heals, cures and gives its effects (the server's hooks)", function()
		local bandage = finish(I.Bandage)
		t.eq(bandage.healed, 2)
		t.eq(bandage.cured[1], "Bleeding")
		t.eq(#bandage.given, 0)
		local medkit = finish(I.Medkit)
		t.eq(medkit.healed, 8)
		t.eq(medkit.cured[1], "Bleeding")
		t.eq(medkit.given[1], E.Regeneration, "and keeps healing for a while")
		local painkillers = finish(I.Painkillers)
		t.eq(painkillers.healed, 2)
		t.eq(painkillers.given[1], E.Regeneration)
		t.eq(#painkillers.cured, 0)
		local antibiotics = finish(I.Antibiotics, nil, 2)
		t.eq(antibiotics.healed, 0)
		t.eq(antibiotics.cured[1], "Infection")
		t.eq(#antibiotics.given, 0, "stage II: no aftermath")
		local late = finish(I.Antibiotics, nil, 3)
		t.eq(late.given[1], E.Weakness, "stage III: Weakness after the cure")
		local poultice = finish(I.HerbalPoultice)
		t.ok(poultice.setBack and #poultice.cured == 0, "a poultice sets back, cures nothing")
		local chocolate = finish(I.ChocolateBar)
		t.eq(chocolate.given[1], E.Speed)
		-- Crackers' thirst: 30%, as raw chicken.
		t.eq(finish(I.Crackers, 0.29).thirst, 600, "dry: the Thirst effect at 30%")
		t.eq(finish(I.Crackers, 0.31).thirst, 0)
		t.eq(finish(I.CannedBeans, 0).thirst, 0, "beans carry no risk")
		-- (No food bar: hunger off, so food heals and rotten flesh brings the Thirst effect.)
		t.eq(finish(I.CannedBeans).healed, 6)
		t.eq(finish(I.RottenFlesh, 0.5).thirst, 600, "hunger off: rotten flesh's risk is thirst")
	end)

	t.test("medical: with hunger on, food fills the bar; medicine still heals; Hunger for flesh", function()
		local beans = finish(I.CannedBeans, 0.99, nil, true)
		t.eq(beans.fed, 6, "Canned Beans: 6 food")
		t.ok(math.abs(beans.saturation - 7.2) < 1e-9, "and 6 x 0.6 x 2 saturation")
		t.eq(beans.healed, 0, "no healing")
		local ration = finish(I.MilitaryRation, 0.99, nil, true)
		t.eq(ration.fed, 8)
		local medkit = finish(I.Medkit, 0.99, nil, true)
		t.eq(medkit.healed, 8, "medicine heals with hunger on")
		t.eq(medkit.fed, 0)
		local flesh = finish(I.RottenFlesh, 0.5, nil, true)
		t.eq(flesh.fed, 4)
		t.eq(flesh.given[1], E.Hunger, "80%: Minecraft's Hunger")
		t.eq(flesh.thirst, 0, "not thirst")
		t.eq(#finish(I.RottenFlesh, 0.85, nil, true).given, 0, "20%: nothing")
		t.eq(finish(I.RawChicken, 0.29, nil, true).given[1], E.Hunger, "raw chicken 30%")
		t.eq(#finish(I.RawChicken, 0.31, nil, true).given, 0)
		local crackers = finish(I.Crackers, 0.29, nil, true)
		t.eq(crackers.thirst, 600, "crackers stay thirsty")
		t.eq(#crackers.given, 0)
		local chocolate = finish(I.ChocolateBar, 0.99, nil, true)
		t.eq(chocolate.fed, 3)
		t.eq(chocolate.given[1], E.Speed, "and its Speed")
	end)

	t.test("medical: a bandage stops the bleeding (Players/EffectRules)", function()
		local state = EffectRules.new()
		EffectRules.give(state, E.Bleeding, 400, 0)
		local hurt = 0
		for _ = 1, 100 do
			hurt += (EffectRules.tick(state, SURVIVAL, 18, 20))
		end
		t.ok(hurt >= 1, "bleeding hurts")
		-- The bandage, as Players/Eating applies it: cure = Effects.remove.
		Foods.finish(food(I.Bandage), {
			heal = function() end,
			cure = function(name: string)
				EffectRules.remove(state, Effects.id[name])
			end,
			setBack = function() end,
			infectionStage = function(): number
				return 0
			end,
			give = function() end,
			thirst = function() end,
			random = function(): number
				return 0.5
			end,
		})
		t.ok(not EffectRules.has(state, E.Bleeding), "no more Bleeding")
		local after = 0
		for _ = 1, 400 do
			after += (EffectRules.tick(state, SURVIVAL, 18, 20))
		end
		t.eq(after, 0, "nothing hurts after the bandage")
	end)

	t.test("medical: bottled water and soda (Shared/ToughAsNails/Drinks)", function()
		local water, soda = Drinks.of(I.BottledWater), Drinks.of(I.SodaCan)
		-- (Purified water: the Purified Water Bottle's drink, its entry's, in place of the old
		-- Drinks.PURIFIED; alike drinks are one.)
		t.eq(water, Drinks.of(I.PurifiedWaterBottle), "bottled water is purified water")
		t.eq(Drinks.emptyOf(I.BottledWater), I.GlassBottle, "the bottle is kept")
		t.ok(not Drinks.isPotion(water), "drunk while thirsty")
		t.ok(Drinks.drinkable(water, true, true, true) and not Drinks.drinkable(water, false, true, true))
		local held, give = Drinks.afterDrinking({ item = I.BottledWater, count = 3 }, false)
		t.eq(held and held.count, 2)
		t.eq(give and give.item, I.GlassBottle)
		t.ok(soda ~= nil, "soda is a drink")
		if soda then
			t.eq(soda.thirst, 4)
			t.eq(soda.hydration, 0.2)
			t.eq(Drinks.emptyOf(I.SodaCan), nil, "the can is not kept")
			t.ok(Drinks.isPotion(soda), "its Speed makes it drunk any time")
			t.ok(Drinks.drinkable(soda, false, false, false), "thirst off: still drunk for its Speed")
			local effects = soda.effects :: { Drinks.PotionEffect }
			t.eq(effects[1].effect, E.Speed)
			t.eq(effects[1].ticks, 400)
			local thirst = Thirst.new()
			thirst.thirst, thirst.hydration = 10, 0
			Drinks.apply(thirst, soda, function(): number
				return 0
			end)
			t.eq(thirst.thirst, 14)
			t.ok(math.abs(thirst.hydration - 1.6) < 1e-9, "4 x 0.2 x 2 hydration")
			local last, nothing = Drinks.afterDrinking({ item = I.SodaCan, count = 1 }, false)
			t.eq(last, nil, "the last can leaves nothing")
			t.eq(nothing, nil)
		end
	end)

	t.test("medical: tooltips say what each does", function()
		local function has(item: number, text: string): boolean
			for _, line in Tooltip.texts(item) do
				if line == text then
					return true
				end
			end
			return false
		end
		t.ok(has(I.Bandage, "When used:"), "medicine is used")
		t.ok(has(I.Bandage, "Cures Bleeding"))
		t.ok(has(I.Bandage, "Heals 1 heart"))
		t.ok(has(I.Antibiotics, "Cures Infection"))
		t.ok(not has(I.Antibiotics, "Heals 0 hearts"), "no healing line for 0")
		t.ok(has(I.HerbalPoultice, "Sets an infection back a stage"))
		t.ok(has(I.Medkit, "Regeneration (0:10)"))
		-- (Minecraft's hunger on, Config's default: a tin fills the food bar instead of healing.)
		t.ok(has(I.CannedBeans, "When eaten:") and has(I.CannedBeans, "Restores 6 hunger"))
		t.ok(has(I.CannedBeans, "+7.2 Saturation"))
		t.ok(has(I.ChocolateBar, "Speed (0:10)"))
		t.ok(has(I.SodaCan, "When drunk:") and has(I.SodaCan, "Speed (0:20)"))
		t.ok(has(I.BottledWater, "Restores 6 thirst"))
	end)
end
