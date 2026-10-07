--[[
	Status effects (Shared/Effects, server Players/EffectRules, Players/EffectCommand): the
	registry, Minecraft 1.20.1's MobEffectInstance.update and tick (hidden effects, Regeneration,
	Poison, Wither and the instant effects on their ticks, invulnerable modes), the modifiers the
	movement, mining, combat and burning read (on both the client's and the server's paths), the
	effects oil and fuel give and water washes off, burning with Fire Resistance, Oil Coated and
	Fuel Soaked, the potions (items, brewing, drinking), the Effects message, the server's sync
	rule, /effect's parsing and permission, and the HUD's order, flashing and glyphs.
]]

return function(t, shared, require, server, client)
	local Blocks = require(shared.Blocks)
	local Crafting = require(shared.Crafting)
	local Effects = require(shared.Effects)
	local PotionList = require(shared.Effects.PotionList)
	local Fluids = require(shared.Fluids)
	local GameMode = require(shared.GameMode)
	local Items = require(shared.Items)
	local Mining = require(shared.Mining)
	local PlayerPhysics = require(shared.Movement.PlayerPhysics)
	local Protocol = require(shared.Net.Protocol)
	local Drinks = require(shared.ToughAsNails.Drinks)
	local Thirst = require(shared.ToughAsNails.Thirst)
	local Burning = require(server.Players.Burning)
	local EditRules = require(server.Network.EditRules)
	local EffectCommand = require(server.Players.EffectCommand)
	local EffectRules = require(server.Players.EffectRules)
	local EffectIcons = require(client.Ui.EffectIcons)

	local E = Effects.id
	local B, I = Blocks.id, Items.id
	local SURVIVAL, CREATIVE, SPECTATOR = GameMode.SURVIVAL, GameMode.CREATIVE, GameMode.SPECTATOR
	local INFINITE = Effects.INFINITE
	local AIR, STONE = Blocks.AIR, B.Stone
	local function mask(fluid: number): number
		return bit32.lshift(1, fluid)
	end
	local OIL, FUEL, WATER = mask(Fluids.OIL), mask(Fluids.FUEL), mask(Fluids.WATER)
	local function near(a: number, b: number, tolerance: number?): boolean
		return math.abs(a - b) <= (tolerance or 1e-9)
	end
	-- Ticks `state` `n` times in `mode` at `health` of 20: the hurt and healing summed.
	local function run(state, n: number, mode: string?, health: number?): (number, number)
		local hurt, healed = 0, 0
		for _ = 1, n do
			local d, h = EffectRules.tick(state, mode or SURVIVAL, health or 10, 20)
			hurt += d
			healed += h
		end
		return hurt, healed
	end

	--[[ Registry ]]

	t.test("effects: the registry (ids append only, names, Minecraft's colours)", function()
		t.eq(E.Speed, 1)
		t.eq(E.Glowing, 18)
		t.eq(E.OilCoated, 19)
		t.eq(E.FuelSoaked, 20)
		t.eq(E.ClimateClemency, 24)
		t.eq(Effects.COUNT, 24, "the last effect added (Tough As Nails' Climate Clemency)")
		t.eq(Effects.get(E.Speed).colorValue, 8171462, "Minecraft's MOVEMENT_SPEED colour")
		t.eq(Effects.get(E.Poison).colorValue, 5149489)
		t.eq(Effects.get(E.NightVision).colorValue, 2039713)
		t.eq(Effects.get(E.JumpBoost).displayName, "Jump Boost")
		t.eq(Effects.find("speed"), E.Speed)
		t.eq(Effects.find("minecraft:jump_boost"), E.JumpBoost)
		t.eq(Effects.find("JUMP_BOOST"), E.JumpBoost, "any case")
		t.eq(Effects.find("Jump Boost"), E.JumpBoost, "the display name")
		t.eq(Effects.find("JumpBoost"), E.JumpBoost, "the name")
		t.eq(Effects.find("toughasnails:thirst"), E.Thirst)
		t.eq(Effects.find("oil_coated"), E.OilCoated)
		t.eq(Effects.find("levitation"), nil, "not in this game")
		t.ok(Effects.get(0) == nil and Effects.get(25) == nil and Effects.get(1.5) == nil, "unknown ids")
		t.ok(Effects.get(E.Speed).beneficial and not Effects.get(E.Poison).beneficial)
		t.eq(Effects.get(E.Glowing).category, "neutral")
		for _, name in { "Thirst", "InternalWarmth", "InternalChill", "ClimateClemency" } do
			t.ok(Effects.get(E[name]).external, `{name} is Tough As Nails'`)
		end
	end)

	t.test("effects: names with levels and Minecraft's durations", function()
		t.eq(Effects.levelName(E.Speed, 0), "Speed", "level I is written bare")
		t.eq(Effects.levelName(E.Speed, 1), "Speed II")
		t.eq(Effects.levelName(E.Haste, 3), "Haste IV")
		t.eq(Effects.levelName(E.Strength, 9), "Strength X")
		t.eq(Effects.levelName(E.Strength, 10), "Strength 11", "figures past X")
		t.eq(Effects.formatTicks(0), "0:00")
		t.eq(Effects.formatTicks(19), "0:00")
		t.eq(Effects.formatTicks(600), "0:30")
		t.eq(Effects.formatTicks(3600), "3:00")
		t.eq(Effects.formatTicks(9600), "8:00")
		t.eq(Effects.formatTicks(20 * 3723), "1:02:03")
		t.eq(Effects.formatTicks(INFINITE), "**:**")
	end)

	--[[ Modifiers ]]

	t.test("effects: speed, mining and jump modifiers (Minecraft's attribute numbers)", function()
		t.eq(Effects.speedFactor({}), 1)
		t.ok(near(Effects.speedFactor({ [E.Speed] = 0 }), 1.2), "Speed I")
		t.ok(near(Effects.speedFactor({ [E.Speed] = 1 }), 1.4), "Speed II")
		t.ok(near(Effects.speedFactor({ [E.Slowness] = 0 }), 0.85), "Slowness I")
		t.ok(near(Effects.speedFactor({ [E.Slowness] = 1 }), 0.7), "Slowness II")
		t.ok(near(Effects.speedFactor({ [E.Speed] = 0, [E.Slowness] = 0 }), 1.02), "multiplied, not added")
		t.ok(near(Effects.speedFactor({ [E.Slowness] = 1, [E.OilCoated] = 0 }), 0.595), "oil's two")
		t.eq(Effects.speedFactor({ [E.Slowness] = 6 }), 0, "never below 0")
		t.ok(near(Effects.miningFactor({ [E.Haste] = 0 }), 1.2), "Haste I")
		t.ok(near(Effects.miningFactor({ [E.Haste] = 1 }), 1.4), "Haste II")
		t.ok(near(Effects.miningFactor({ [E.MiningFatigue] = 0 }), 0.3), "Mining Fatigue I")
		t.ok(near(Effects.miningFactor({ [E.MiningFatigue] = 1 }), 0.09))
		t.ok(near(Effects.miningFactor({ [E.MiningFatigue] = 2 }), 0.0027))
		t.ok(near(Effects.miningFactor({ [E.MiningFatigue] = 3 }), 8.1e-4))
		t.ok(near(Effects.miningFactor({ [E.MiningFatigue] = 9 }), 8.1e-4), "and every level after")
		local velocity, fall = Effects.jumpBoost({ [E.JumpBoost] = 1 })
		t.ok(near(velocity, 0.2) and fall == 2, "Jump Boost II: +0.2 and 2 blocks")
		t.eq(select(2, Effects.jumpBoost({})), 0)
		t.ok(Effects.noSprint({ [E.Blindness] = 0 }) and not Effects.noSprint({ [E.Speed] = 0 }))
	end)

	t.test("effects: melee and incoming damage (Strength, Weakness, Resistance)", function()
		t.eq(Effects.meleeDamage(7, {}), 7)
		t.eq(Effects.meleeDamage(7, { [E.Strength] = 0 }), 10, "Strength I: +3")
		t.eq(Effects.meleeDamage(7, { [E.Strength] = 1 }), 13, "Strength II: +6")
		t.eq(Effects.meleeDamage(7, { [E.Weakness] = 0 }), 3, "Weakness: -4")
		t.eq(Effects.meleeDamage(2, { [E.Weakness] = 0 }), 0, "never below 0")
		t.eq(Effects.meleeDamage(7, { [E.Strength] = 0, [E.Weakness] = 0 }), 6)
		t.ok(near(Effects.incomingDamage(10, { [E.Resistance] = 0 }), 8), "Resistance I: 20% off")
		t.ok(near(Effects.incomingDamage(10, { [E.Resistance] = 3 }), 2), "IV: 80%")
		t.eq(Effects.incomingDamage(10, { [E.Resistance] = 4 }), 0, "V: nothing gets through")
		t.eq(Effects.incomingDamage(10, { [E.Speed] = 0 }), 10)
	end)

	t.test("effects: fire rules (Fire Resistance, Oil Coated, Fuel Soaked)", function()
		t.eq(Effects.fireRules({}), nil, "none: nothing to allocate")
		t.eq(Effects.fireRules({ [E.Speed] = 0 }), nil)
		local resistant = Effects.fireRules({ [E.FireResistance] = 0 })
		t.ok(resistant and resistant.immune and resistant.factor == 1, "Fire Resistance")
		local coated = Effects.fireRules({ [E.OilCoated] = 0 })
		t.ok(coated and coated.factor == 2 and coated.bonus == 1 and not coated.ignites, "Oil Coated")
		local soaked = Effects.fireRules({ [E.FuelSoaked] = 0 })
		t.ok(soaked and soaked.factor == 3 and soaked.ignites and not soaked.immune, "Fuel Soaked")
		local both = Effects.fireRules({ [E.FuelSoaked] = 0, [E.OilCoated] = 0 })
		t.ok(both and both.factor == 3 and both.bonus == 1 and both.ignites, "the worst of both")
	end)

	--[[ Giving and ticking ]]

	t.test("effects: give and refresh follow MobEffectInstance.update", function()
		local state = EffectRules.new()
		t.ok(EffectRules.give(state, E.Speed, 600, 0), "new")
		t.eq(EffectRules.amplifier(state, E.Speed), 0)
		t.ok(not EffectRules.give(state, E.Speed, 300, 0), "the same level for less: nothing")
		t.eq(EffectRules.get(state, E.Speed).ticks, 600)
		t.ok(EffectRules.give(state, E.Speed, 900, 0), "the same level for longer refreshes")
		t.eq(EffectRules.get(state, E.Speed).ticks, 900)
		-- A stronger, shorter one wins and the old one waits underneath.
		t.ok(EffectRules.give(state, E.Speed, 100, 1), "a higher amplifier wins")
		local speed = EffectRules.get(state, E.Speed)
		t.ok(speed.amplifier == 1 and speed.ticks == 100, "with its duration")
		t.ok(speed.hidden and speed.hidden.amplifier == 0 and speed.hidden.ticks == 900, "the old one hidden")
		run(state, 100)
		speed = EffectRules.get(state, E.Speed)
		t.ok(speed and speed.amplifier == 0, "Speed I comes back when Speed II ends")
		t.eq(speed.ticks, 800, "having counted down underneath")
		t.eq(EffectRules.amplifier(state, E.Speed), 0, "and the levels follow")
		-- A weaker, longer one goes under.
		local other = EffectRules.new()
		EffectRules.give(other, E.Haste, 100, 2)
		t.ok(not EffectRules.give(other, E.Haste, 400, 0), "a lower amplifier changes nothing shown")
		t.ok(EffectRules.get(other, E.Haste).hidden ~= nil, "but waits underneath")
		run(other, 100)
		t.eq(EffectRules.amplifier(other, E.Haste), 0)
		t.eq(EffectRules.get(other, E.Haste).ticks, 300)
		-- Infinite effects never run out.
		EffectRules.give(other, E.NightVision, INFINITE)
		run(other, 1000)
		t.ok(EffectRules.has(other, E.NightVision), "infinite")
		t.ok(not EffectRules.give(other, E.NightVision, 999999), "nothing outlasts infinite")
		-- Ambient: a non-ambient one makes it non-ambient.
		local ambient = EffectRules.new()
		EffectRules.give(ambient, E.Resistance, 100, 0, true)
		t.ok(EffectRules.give(ambient, E.Resistance, 50, 0, false), "no longer ambient")
		t.eq(EffectRules.get(ambient, E.Resistance).ambient, false)
		-- Nonsense changes nothing.
		local bad = EffectRules.new()
		t.ok(not EffectRules.give(bad, 0, 100), "unknown")
		t.ok(not EffectRules.give(bad, E.Speed, 0), "no time")
		t.ok(not EffectRules.give(bad, E.Speed, 1.5), "half a tick")
		t.ok(not EffectRules.give(bad, E.Speed, 100, 256), "amplifier over 255")
		t.ok(not EffectRules.give(bad, E.Speed, 100, -1), "negative amplifier")
		t.ok(not EffectRules.give(bad, E.Thirst, 100), "external effects belong to their owners")
		t.eq(next(bad.active), nil)
		-- Removing and clearing.
		t.ok(EffectRules.remove(state, E.Speed) and not EffectRules.remove(state, E.Speed))
		EffectRules.give(state, E.Speed, 10)
		EffectRules.give(state, E.Poison, 10)
		t.eq(EffectRules.clear(state), 2)
		t.eq(next(state.levels), nil)
	end)

	t.test("effects: Regeneration, Poison and Wither act on Minecraft's ticks", function()
		local regen = EffectRules.new()
		EffectRules.give(regen, E.Regeneration, 200, 0)
		local _, healed = run(regen, 200)
		t.eq(healed, 4, "Regeneration I: every 50 ticks")
		t.ok(not EffectRules.has(regen, E.Regeneration), "and it ends")
		local regen2 = EffectRules.new()
		EffectRules.give(regen2, E.Regeneration, 200, 1)
		t.eq(select(2, run(regen2, 200)), 8, "II: every 25")
		local full = EffectRules.new()
		EffectRules.give(full, E.Regeneration, 200, 1)
		t.eq(select(2, run(full, 200, SURVIVAL, 20)), 0, "nothing at full health")
		local fast = EffectRules.new()
		EffectRules.give(fast, E.Regeneration, 10, 5)
		t.eq(select(2, run(fast, 10)), 10, "50 >> 5 = 1: every tick")

		local poison = EffectRules.new()
		EffectRules.give(poison, E.Poison, 100, 0)
		t.eq(run(poison, 100), 4, "Poison I: every 25 ticks")
		local poison2 = EffectRules.new()
		EffectRules.give(poison2, E.Poison, 120, 1)
		t.eq(run(poison2, 120), 10, "II: every 12")
		local weak = EffectRules.new()
		EffectRules.give(weak, E.Poison, 100, 0)
		t.eq(run(weak, 100, SURVIVAL, 1), 0, "poison never takes the last half heart")
		local wither = EffectRules.new()
		EffectRules.give(wither, E.Wither, 80, 0)
		t.eq(run(wither, 80, SURVIVAL, 1), 2, "Wither: every 40, and it kills")
		local god = EffectRules.new()
		EffectRules.give(god, E.Poison, 100, 0)
		EffectRules.give(god, E.Regeneration, 100, 0)
		local hurt, healed2 = run(god, 100, CREATIVE)
		t.ok(hurt == 0 and healed2 == 2, "creative: never hurt, still healed")
		t.ok(not EffectRules.has(god, E.Poison), "and the time still runs")
		-- Infinite effects act by the player's age.
		local forever = EffectRules.new()
		EffectRules.give(forever, E.Regeneration, INFINITE, 0)
		t.eq(select(2, run(forever, 100)), 2, "every 50 ticks of age")
	end)

	t.test("effects: Instant Health and Instant Damage act once (4 << amp, 6 << amp)", function()
		local state = EffectRules.new()
		EffectRules.give(state, E.InstantHealth, 1, 0)
		local _, healed = EffectRules.tick(state, SURVIVAL, 10, 20)
		t.eq(healed, 4)
		t.ok(not EffectRules.has(state, E.InstantHealth), "gone")
		EffectRules.give(state, E.InstantHealth, 1, 1)
		t.eq(select(2, EffectRules.tick(state, SURVIVAL, 10, 20)), 8, "II")
		EffectRules.give(state, E.InstantDamage, 1, 0)
		t.eq(EffectRules.tick(state, SURVIVAL, 10, 20), 6)
		EffectRules.give(state, E.InstantDamage, 1, 1)
		t.eq(EffectRules.tick(state, SURVIVAL, 10, 20), 12, "II")
		EffectRules.give(state, E.InstantDamage, 1, 1)
		t.eq(EffectRules.tick(state, SPECTATOR, 10, 20), 0, "spectators are not hurt")
		EffectRules.give(state, E.InstantHealth, 3, 0)
		t.eq(select(2, run(state, 3)), 12, "/effect's seconds are ticks for instant effects: every tick")
		t.eq(#EffectRules.entries(state), 0, "instant effects are never shown")
	end)

	--[[ Fluids ]]

	t.test("effects: oil (Slowness II, then Oil Coated) and water washing it off", function()
		local state = EffectRules.new()
		EffectRules.touchFluids(state, OIL, 0, SURVIVAL)
		t.eq(EffectRules.amplifier(state, E.Slowness), 1, "Slowness II in oil")
		t.ok(not EffectRules.has(state, E.OilCoated), "not coated yet")
		for _ = 1, 50 do
			EffectRules.touchFluids(state, OIL, 0, SURVIVAL)
			EffectRules.tick(state, SURVIVAL, 20, 20)
		end
		t.eq(EffectRules.get(state, E.Slowness).ticks, 19, "refreshed every tick (1 s, then a tick)")
		EffectRules.touchFluids(state, 0, 0, SURVIVAL)
		t.ok(EffectRules.has(state, E.OilCoated), "coated on leaving")
		t.eq(EffectRules.get(state, E.OilCoated).ticks, 600, "for 30 s")
		run(state, 25)
		t.ok(not EffectRules.has(state, E.Slowness), "the oil's Slowness wears off in a second")
		t.ok(near(Effects.speedFactor(EffectRules.levels(state)), 0.85), "the coat still slows (Slowness I)")
		EffectRules.touchFluids(state, 0, 0, SURVIVAL)
		t.eq(EffectRules.get(state, E.OilCoated).ticks, 575, "leaving once coats once")
		EffectRules.touchFluids(state, WATER, 0, SURVIVAL)
		t.ok(not EffectRules.has(state, E.OilCoated), "water washes it off")
	end)

	t.test("effects: fuel's fumes (Nausea, Poison after 3 s) and Fuel Soaked", function()
		local state = EffectRules.new()
		EffectRules.touchFluids(state, FUEL, 0, SURVIVAL)
		t.eq(EffectRules.get(state, E.Nausea).ticks, 160, "Nausea for 8 s")
		t.eq(EffectRules.get(state, E.FuelSoaked).ticks, 400, "soaked: 20 s")
		t.ok(not EffectRules.has(state, E.Poison), "no poison yet")
		for _ = 2, 59 do
			EffectRules.touchFluids(state, FUEL, 0, SURVIVAL)
		end
		t.ok(not EffectRules.has(state, E.Poison), "59 ticks in it: still none")
		EffectRules.touchFluids(state, FUEL, 0, SURVIVAL)
		t.eq(EffectRules.get(state, E.Poison).ticks, 100, "after 3 s: Poison I, refreshed")
		-- A break in the contact starts the count over.
		local again = EffectRules.new()
		for _ = 1, 50 do
			EffectRules.touchFluids(again, FUEL, 0, SURVIVAL)
		end
		EffectRules.touchFluids(again, 0, 0, SURVIVAL)
		for _ = 1, 50 do
			EffectRules.touchFluids(again, FUEL, 0, SURVIVAL)
		end
		t.ok(not EffectRules.has(again, E.Poison), "a breath of air resets the fumes")
		-- Water and fuel together: washed at once; water alone washes the soak off.
		local both = EffectRules.new()
		EffectRules.touchFluids(both, bit32.bor(FUEL, WATER), 0, SURVIVAL)
		t.ok(
			not EffectRules.has(both, E.FuelSoaked) and EffectRules.has(both, E.Nausea),
			"the soak washes off, not the fumes"
		)
		EffectRules.touchFluids(state, WATER, 0, SURVIVAL)
		t.ok(not EffectRules.has(state, E.FuelSoaked), "a swim washes it off")
		local ghost = EffectRules.new()
		EffectRules.touchFluids(ghost, FUEL, 0, SPECTATOR)
		t.eq(next(ghost.active), nil, "spectators touch nothing")
		EffectRules.touchFluids(ghost, FUEL, 0, CREATIVE)
		t.ok(EffectRules.has(ghost, E.Nausea), "creative players feel it (it can't hurt them)")
	end)

	t.test("effects: fluid effects are data (`head`, `after`)", function()
		local fake = {
			{
				id = Fluids.WATER,
				effects = {
					{ effect = E.NightVision, ticks = 40, amplifier = 0, when = "head", after = 0 },
					{ effect = E.Speed, ticks = 20, amplifier = 2, when = "in", after = 2 },
				},
			},
		}
		local state = EffectRules.new()
		EffectRules.touchFluids(state, WATER, 0, SURVIVAL, fake :: any)
		t.ok(not EffectRules.has(state, E.NightVision), "the body in it, not the eyes")
		t.ok(not EffectRules.has(state, E.Speed), "one tick is not two")
		EffectRules.touchFluids(state, WATER, WATER, SURVIVAL, fake :: any)
		t.ok(EffectRules.has(state, E.NightVision), "the eyes in it")
		t.eq(EffectRules.amplifier(state, E.Speed), 2, "after two ticks")
		t.ok(not EffectRules.HEAD_EFFECTS, "no real fluid gives effects at the eyes (they aren't looked for)")
		-- Every real fluid effect names a real effect with sensible numbers.
		for _, fluid in Fluids.list do
			for _, given in fluid.effects do
				t.ok(Effects.get(given.effect) ~= nil and given.ticks > 0, `{fluid.name}'s effects`)
			end
		end
		t.eq(#Fluids.get(Fluids.OIL).effects, 2)
		t.eq(#Fluids.get(Fluids.FUEL).effects, 3)
		t.eq(#Fluids.get(Fluids.WATER).effects, 0)
	end)

	--[[ Burning ]]

	t.test("effects: burning with Fire Resistance, Oil Coated and Fuel Soaked", function()
		local LAVA = Blocks.fluidId("Lava", 0)
		local function cells(list: { [string]: number }): (number, number, number) -> number?
			return function(x: number, y: number, z: number): number?
				return list[`{x},{y},{z}`] or AIR
			end
		end
		local lava = Burning.touchingAt(cells({ ["0,64,0"] = LAVA }), 0.5, 64, 0.5, 0.6, 1.8)
		local fire = Burning.touchingAt(cells({ ["0,64,0"] = B.Fire }), 0.5, 64, 0.5, 0.6, 1.8)

		-- Fire Resistance: lava sets burning, but nothing hurts and nothing sizzles.
		local immune = Effects.fireRules({ [E.FireResistance] = 0 })
		local state = Burning.newPlayer()
		local hurt, total = false, 0
		for _ = 1, 40 do
			local damage, _, sizzled = Burning.tickPlayer(state, SURVIVAL, lava, 0, 0, immune)
			total += damage
			hurt = hurt or sizzled
		end
		t.ok(total == 0 and not hurt, "no lava hurt")
		t.eq(state.fire, 300, "still burning (it shows)")
		for _ = 1, 100 do
			total += Burning.tickPlayer(state, SURVIVAL, 0, 0, 0, immune)
		end
		t.eq(total, 0, "and burning doesn't hurt either")
		t.eq(state.cooldown, 0, "no hurt, no cooldown")

		-- Oil Coated: lava's burning lasts twice as long and each second of it hurts 2.
		local coated = Effects.fireRules({ [E.OilCoated] = 0 })
		local oily = Burning.newPlayer()
		Burning.tickPlayer(oily, SURVIVAL, lava, 0, 0, coated)
		t.eq(oily.fire, 600, "30 s of burning")
		local burnt = 0
		for _ = 1, 100 do
			burnt += Burning.tickPlayer(oily, SURVIVAL, 0, 0, 0, coated)
		end
		local plain = Burning.newPlayer()
		Burning.tickPlayer(plain, SURVIVAL, lava, 0, 0, nil)
		local plainBurnt = 0
		for _ = 1, 100 do
			plainBurnt += Burning.tickPlayer(plain, SURVIVAL, 0, 0, 0, nil)
		end
		t.eq(burnt, 2 * plainBurnt, `burns twice as hard ({burnt} against {plainBurnt})`)

		-- Fuel Soaked: catches at once in a fire block, for 3 x 8 s.
		local soaked = Effects.fireRules({ [E.FuelSoaked] = 0 })
		local wet = Burning.newPlayer()
		Burning.tickPlayer(wet, SURVIVAL, fire, 0, 0, soaked)
		t.eq(wet.fire, 480, "alight at once, for 24 s")
		local dry = Burning.newPlayer()
		Burning.tickPlayer(dry, SURVIVAL, fire, 0, 0, nil)
		t.eq(dry.fire, 0, "a dry player waits 20 ticks")
		-- A blast lights a soaked player; water puts it out all the same.
		local blasted = Burning.newPlayer()
		Burning.ignite(blasted, SURVIVAL, Burning.IN_FIRE_SECONDS, soaked)
		t.eq(blasted.fire, 480)
		local _, out = Burning.tickPlayer(blasted, SURVIVAL, mask(Fluids.WATER), 0, 0, soaked)
		t.ok(out and blasted.fire == 0, "water puts it out")
		local god = Burning.newPlayer()
		Burning.ignite(god, CREATIVE, 8, soaked)
		t.eq(god.fire, 0, "creative players never burn")
	end)

	--[[ Movement and mining: the client's prediction and the server's check ]]

	t.test("effects: movement (speed factor, Jump Boost, fall damage, Blindness)", function()
		local world: PlayerPhysics.World = {
			getBlock = function(_x: number, y: number, _z: number): number?
				return if y <= 0 then STONE else AIR
			end,
		}
		local function input(sprint: boolean?, jump: boolean?): PlayerPhysics.Input
			return {
				moveX = 1,
				moveZ = 0,
				forward = 1,
				facingX = 1,
				facingZ = 0,
				lookY = 0,
				jump = jump == true,
				sneak = false,
				sprint = sprint == true,
			}
		end
		local function speed(factor: number): number
			local state = PlayerPhysics.new(0.5, 1, 0.5)
			state.onGround = true
			state.speedFactor = factor
			local x0 = 0
			for tick = 1, 100 do
				PlayerPhysics.tick(state, input(), world)
				if tick == 40 then
					x0 = state.x
				end
			end
			return (state.x - x0) / 60 * 20
		end
		local walk = speed(1)
		t.ok(near(speed(1.2) / walk, 1.2, 1e-3), "Speed I: 20% faster")
		t.ok(near(speed(0.7) / walk, 0.7, 1e-3), "Slowness II: 30% slower")

		local jumper = PlayerPhysics.new(0.5, 1, 0.5)
		jumper.onGround = true
		jumper.jumpBoost = 0.1
		PlayerPhysics.tick(jumper, input(false, true), world)
		-- (0.42 + 0.1, then gravity and drag for the tick: (0.52 - 0.08) x 0.98.)
		t.ok(near(jumper.vy, (0.52 - 0.08) * 0.98, 1e-6), `Jump Boost I: ${jumper.vy}`)

		local function drop(height: number, reduction: number): number
			local s = PlayerPhysics.new(0.5, 1 + height, 0.5)
			s.fallReduction = reduction
			for _ = 1, 100 do
				local events = PlayerPhysics.tick(s, input(), world)
				if events.landed then
					return events.damage
				end
			end
			return -1
		end
		local plain = drop(8, 0)
		t.ok(plain > 0, `an 8 block fall hurts ({plain})`)
		t.eq(drop(8, 2), plain - 2, "Jump Boost II: 2 blocks less")
		t.eq(drop(8, 10), 0)

		local blind = PlayerPhysics.new(0.5, 1, 0.5)
		blind.onGround = true
		blind.noSprint = true
		for _ = 1, 5 do
			PlayerPhysics.tick(blind, input(true), world)
		end
		t.ok(not blind.sprinting, "Blindness: no sprint")
		local sighted = PlayerPhysics.new(0.5, 1, 0.5)
		sighted.onGround = true
		for _ = 1, 5 do
			PlayerPhysics.tick(sighted, input(true), world)
		end
		t.ok(sighted.sprinting, "without it the sprint key sprints")
	end)

	t.test("effects: mining speed agrees on the client and the server", function()
		local pick = I.WoodenPickaxe
		t.eq(Mining.ticks(STONE, true, false, pick), 23, "stone with a wooden pickaxe")
		local haste = Effects.miningFactor({ [E.Haste] = 1 })
		local fatigue = Effects.miningFactor({ [E.MiningFatigue] = 0 })
		t.eq(Mining.ticks(STONE, true, false, pick, haste), 17, "Haste II: x 1.4")
		t.eq(Mining.ticks(STONE, true, false, pick, fatigue), 75, "Mining Fatigue I: x 0.3")
		t.eq(Mining.ticks(B.Dirt, true, false, nil, Effects.miningFactor({ [E.Haste] = 255 })), 1, "at most at once")
		-- The server's check takes the same factor: the client's break time with Haste is
		-- accepted, and too early without it.
		local ticks = Mining.ticks(STONE, true, false, pick, haste)
		local seconds = (ticks - 1) / 20
		t.ok(Mining.mayBreak(STONE, seconds, 1, pick, haste), "Haste II's time, with Haste II")
		t.ok(not Mining.mayBreak(STONE, seconds, 1, pick), "but not without it")
		local mine = { x = 0, y = 64, z = 0, startedAt = 0 }
		t.ok(EditRules.mayBreak(STONE, false, mine, 0, 64, 0, seconds, pick, haste), "EditRules passes it on")
		t.ok(not EditRules.mayBreak(STONE, false, mine, 0, 64, 0, 0.6, pick, fatigue), "fatigue holds it back")
		t.ok(EditRules.mayBreak(STONE, false, mine, 0, 64, 0, 0.9, pick), "the plain time without effects")
	end)

	--[[ Potions ]]

	t.test("potions: items, brewing and drinking", function()
		local all = PotionList.all()
		t.eq(#all, 29, "12 potions, 9 strong, 8 long")
		for _, variant in all do
			local item = Items.id[variant.item]
			local def = Items.get(item)
			local effect = Effects.get(Effects.id[variant.effect])
			t.ok(def and def.maxStack == 1, `{variant.item} is an item that doesn't stack`)
			t.eq(def.displayName, variant.displayName)
			t.ok(def.color[1] == effect.color[1] and def.color[3] == effect.color[3], "the effect's colour")
			local entry = Drinks.entry(item)
			t.ok(entry and entry.empty == I.GlassBottle, `{variant.item}: drunk, the bottle back`)
			local given = entry.drink.effects[1]
			t.ok(given.effect == effect.id and given.ticks == variant.ticks and given.amplifier == variant.amplifier)
			t.ok(Drinks.drinkable(entry.drink, false, false, false), "drunk with Tough As Nails off")
			t.ok(Drinks.drinkable(entry.drink, false, true, true), "and not thirsty")
			-- Brewed in the grid from what it says.
			local with = variant.with
			local ingredient = if string.sub(with, 1, 1) == "#"
				then Items.id[require(shared.Crafting.Recipes).tags[string.sub(with, 2)][1]]
				else Items.id[with]
			local made = Crafting.match({
				[1] = { item = Items.id[variant.from], count = 1 },
				[2] = { item = ingredient, count = 1 },
			}, 2)
			t.ok(made and made.item == item, `{variant.item} is brewed`)
		end
		local swift = PotionList.variants(PotionList.list[1])
		t.eq(swift[1].ticks, 3600, "Swiftness: 3:00")
		t.eq(swift[2].ticks, 1800, "II: 1:30")
		t.eq(swift[2].amplifier, 1)
		t.eq(swift[3].ticks, 9600, "long: 8:00")
		t.eq(Items.get(I.StrongPotionOfSwiftness).displayName, "Potion of Swiftness II")
		t.eq(Items.get(I.LongPotionOfFireResistance).displayName, "Long Potion of Fire Resistance")
		t.eq(Drinks.of(I.StrongPotionOfPoison).effects[1].ticks, 432, "Minecraft's 21.6 s")
		t.eq(Drinks.of(I.PotionOfHealing).effects[1].ticks, 1, "instant: one tick")
		-- Any tulip brews Weakness; a coal or charcoal lengthens.
		for _, tulip in { B.RedTulip, B.PinkTulip } do
			local made = Crafting.match({
				[1] = { item = I.PurifiedWaterBottle, count = 1 },
				[3] = { item = tulip, count = 1 },
			}, 2)
			t.ok(made and made.item == I.PotionOfWeakness, "a tulip")
		end
		local long = Crafting.match(
			{ [1] = { item = I.PotionOfWeakness, count = 1 }, [2] = { item = I.Charcoal, count = 1 } },
			2
		)
		t.ok(long and long.item == I.LongPotionOfWeakness, "charcoal lengthens")
		t.eq(
			Crafting.match(
				{ [1] = { item = I.DirtyWaterBottle, count = 1 }, [2] = { item = I.GlowDust, count = 1 } },
				2
			),
			nil,
			"dirty water brews nothing"
		)
		-- Drinking: the bottle comes back, no water is drunk.
		local held, give = Drinks.afterDrinking({ item = I.PotionOfSwiftness, count = 1 }, false)
		t.ok(held and held.item == I.GlassBottle and give == nil, "the Glass Bottle replaces it")
		local thirst = Thirst.new()
		thirst.thirst = 10
		Drinks.apply(thirst, Drinks.of(I.PotionOfSwiftness), function()
			return 0
		end)
		t.eq(thirst.thirst, 10, "a potion is no water")
		t.eq(Drinks.action({ item = I.PotionOfSwiftness, count = 1 }, true, true, true), "drink", "drunk, not filled")
		t.ok(Drinks.isPotion(Drinks.of(I.PotionOfHarming)) and not Drinks.isPotion(Drinks.of(I.PurifiedWaterBottle)))
		local lines = Effects.tooltip(Drinks.of(I.StrongPotionOfSwiftness).effects)
		t.ok(lines[1].text == "Speed II (1:30)" and not lines[1].harmful, "tooltip")
		lines = Effects.tooltip(Drinks.of(I.PotionOfHarming).effects)
		t.ok(lines[1].text == "Instant Damage" and lines[1].harmful, "instant: no time, red")
	end)

	--[[ Sending ]]

	t.test("effects: the Effects message round trip and malformed payloads", function()
		local entries = {
			{ effect = E.Speed, amplifier = 1, ticks = 1800, ambient = false },
			{ effect = E.NightVision, amplifier = 0, ticks = INFINITE, ambient = true },
			{ effect = E.ClimateClemency, amplifier = 0, ticks = 6000, ambient = false },
		}
		local payload = Protocol.encodeEffects(entries)
		t.eq(buffer.len(payload), 1 + 3 * Protocol.EFFECT_BYTES)
		local back = Protocol.decodeEffects(payload)
		assert(back, "decodes")
		t.eq(#back, 3)
		for i, entry in entries do
			local got = back[i]
			t.ok(
				got.effect == entry.effect
					and got.amplifier == entry.amplifier
					and got.ticks == entry.ticks
					and got.ambient == entry.ambient,
				`entry {i}`
			)
		end
		t.eq(#Protocol.decodeEffects(Protocol.encodeEffects({})), 0, "none")
		local function with(offset: number, value: number, writer: string?): buffer
			local b = Protocol.encodeEffects(entries)
			if writer == "i32" then
				buffer.writei32(b, offset, value)
			else
				buffer.writeu8(b, offset, value)
			end
			return b
		end
		t.eq(Protocol.decodeEffects(with(1, 0)), nil, "effect 0")
		t.eq(Protocol.decodeEffects(with(1, 99)), nil, "unknown effect")
		t.eq(Protocol.decodeEffects(with(1 + Protocol.EFFECT_BYTES, E.Speed)), nil, "the same effect twice")
		t.eq(Protocol.decodeEffects(with(3, -2, "i32")), nil, "ticks below -1")
		t.eq(Protocol.decodeEffects(with(7, 2)), nil, "unknown flags")
		t.eq(Protocol.decodeEffects(with(0, 4)), nil, "a count that doesn't fit the length")
		t.eq(Protocol.decodeEffects(buffer.create(0)), nil, "empty")
		local many = buffer.create(1 + 25 * Protocol.EFFECT_BYTES)
		buffer.writeu8(many, 0, 25)
		t.eq(Protocol.decodeEffects(many), nil, "more than there are effects")
		t.eq(Protocol.ServerMessage.Effects, 18, "appended after Survival")
	end)

	t.test("effects: the server sends when the client's view is off", function()
		local state = EffectRules.new()
		t.ok(not EffectRules.needsSync(state), "nothing to say")
		EffectRules.give(state, E.Haste, 600, 0)
		t.ok(EffectRules.needsSync(state), "a new effect")
		EffectRules.markSent(state, EffectRules.entries(state))
		t.ok(not EffectRules.needsSync(state), "sent")
		run(state, 100)
		t.ok(not EffectRules.needsSync(state), "the client counts down the same")
		-- Refreshed every tick (a fluid): told again about once a second.
		local fluid = EffectRules.new()
		local sends = 0
		for _ = 1, 100 do
			EffectRules.touchFluids(fluid, OIL, 0, SURVIVAL)
			EffectRules.tick(fluid, SURVIVAL, 20, 20)
			if EffectRules.needsSync(fluid) then
				sends += 1
				EffectRules.markSent(fluid, EffectRules.entries(fluid))
			end
		end
		t.ok(sends >= 4 and sends <= 6, `{sends} messages in 5 s in oil`)
		-- A stronger one, a removal and an expiry are told.
		EffectRules.give(state, E.Haste, 600, 1)
		t.ok(EffectRules.needsSync(state), "a new amplifier")
		EffectRules.markSent(state, EffectRules.entries(state))
		EffectRules.remove(state, E.Haste)
		t.ok(EffectRules.needsSync(state), "removed")
		EffectRules.markSent(state, EffectRules.entries(state))
		EffectRules.give(state, E.Speed, 5, 0)
		EffectRules.markSent(state, EffectRules.entries(state))
		run(state, 5)
		t.ok(EffectRules.needsSync(state), "ended (the client keeps it at 0 until told)")
		EffectRules.markSent(state, EffectRules.entries(state))
		-- External effects (Tough As Nails') are shown and followed the same way.
		EffectRules.setExternal(state, E.Thirst, 300)
		t.ok(EffectRules.needsSync(state), "an external effect")
		local entries = EffectRules.entries(state)
		t.ok(#entries == 1 and entries[1].effect == E.Thirst and entries[1].ticks == 300)
		EffectRules.markSent(state, entries)
		run(state, 10)
		EffectRules.setExternal(state, E.Thirst, 290)
		t.ok(not EffectRules.needsSync(state), "counting down as its owner does")
		EffectRules.setExternal(state, E.Thirst, 600)
		t.ok(EffectRules.needsSync(state), "a drink refreshed it")
		EffectRules.setExternal(state, E.Thirst, 0)
		EffectRules.markSent(state, EffectRules.entries(state))
		t.eq(#EffectRules.entries(state), 0)
	end)

	--[[ /effect ]]

	t.test("effects: /effect give and clear (Minecraft's wording, permission)", function()
		local steve = { key = "steve", name = "Steve", displayName = "Steve" }
		local alex = { key = "alex", name = "Alex", displayName = "Alex" }
		local given: { any } = {}
		local cleared: { any } = {}
		local function context(mayUse: boolean, takes: boolean?, has: number?)
			return {
				source = steve,
				players = { steve, alex },
				mayUse = mayUse,
				give = function(key: any, effect: number, ticks: number, amplifier: number): boolean
					table.insert(given, { key = key, effect = effect, ticks = ticks, amplifier = amplifier })
					return takes ~= false
				end,
				clear = function(key: any, effect: number?): number
					table.insert(cleared, { key = key, effect = effect })
					return has or 1
				end,
			}
		end
		local function say(text: string, ctx: any?): string
			table.clear(given)
			table.clear(cleared)
			local result = EffectCommand.run(text, ctx or context(true))
			return if result then table.concat(result.feedback, " | ") else "(not a command)"
		end
		t.eq(say("/effect give @s speed 60 1"), "Applied effect Speed to Steve")
		t.ok(
			given[1].effect == E.Speed
				and given[1].ticks == 1200
				and given[1].amplifier == 1
				and given[1].key == "steve"
		)
		t.eq(say("/effect give Alex minecraft:jump_boost"), "Applied effect Jump Boost to Alex")
		t.ok(given[1].key == "alex" and given[1].ticks == 600 and given[1].amplifier == 0, "30 s by default")
		t.eq(say("/effect give @a night_vision infinite"), "Applied effect Night Vision to 2 targets")
		t.eq(given[2].ticks, INFINITE)
		t.eq(say("/effect give @p instant_health"), "Applied effect Instant Health to Steve")
		t.eq(given[1].ticks, 1, "an instant effect's default: a tick")
		say("/effect give @s instant_damage 3")
		t.eq(given[1].ticks, 3, "its seconds are ticks")
		say("/effect give @s thirst 10")
		t.eq(given[1].effect, E.Thirst, "Tough As Nails' too")
		t.eq(say("/effect give @s levitation"), "Unknown effect: levitation")
		t.eq(say("/effect give @s speed 0"), "Integer must not be less than 1, found 0")
		t.eq(say("/effect give @s speed 1000001"), "Integer must not be more than 1000000, found 1000001")
		t.eq(say("/effect give @s speed 10 256"), "Integer must not be more than 255, found 256")
		t.eq(say("/effect give @s speed ten"), "Expected integer, found 'ten'")
		t.eq(say("/effect give @s speed 10 1 maybe"), "Invalid boolean, expected 'true' or 'false' but found 'maybe'")
		t.eq(say("/effect give @s speed 10 1 true"), "Applied effect Speed to Steve")
		t.eq(say("/effect give Herobrine speed"), "No player was found")
		t.eq(say("/effect give @s"), EffectCommand.GIVE_USAGE)
		t.eq(say("/effect give @s speed", context(true, false)), EffectCommand.GIVE_FAILED)
		t.eq(say("/effect give @s speed", context(false)), EffectCommand.DENIED)
		t.eq(#given, 0, "denied: nothing given")
		t.eq(say("/effect clear"), "Removed every effect from Steve")
		t.ok(cleared[1].key == "steve" and cleared[1].effect == nil, "yourself by default")
		t.eq(say("/effect clear @a"), "Removed every effect from 2 targets")
		t.eq(say("/effect clear @s poison"), "Removed effect Poison from Steve")
		t.eq(cleared[1].effect, E.Poison)
		t.eq(say("/effect clear @s", context(true, true, 0)), EffectCommand.CLEAR_FAILED)
		t.eq(say("/effect clear @s poison", context(true, true, 0)), EffectCommand.CLEAR_SPECIFIC_FAILED)
		t.eq(say("/effect clear", context(false)), EffectCommand.DENIED)
		t.eq(say("/effect"), EffectCommand.USAGE)
		t.eq(say("/effect remove"), EffectCommand.USAGE)
		t.eq(say("/effects give @s speed"), "(not a command)")
		t.eq(say("hello"), "(not a command)")
		t.ok(EffectCommand.matches("  /EFFECT give"), "any case, leading spaces")
	end)

	--[[ The HUD ]]

	t.test("effects: the HUD's order, flashing and the view's numbers", function()
		local entries = {
			{ effect = E.Poison, amplifier = 0, ticks = 300, ambient = false },
			{ effect = E.Speed, amplifier = 0, ticks = 600, ambient = false },
			{ effect = E.Haste, amplifier = 0, ticks = 1200, ambient = false },
			{ effect = E.NightVision, amplifier = 0, ticks = INFINITE, ambient = false },
			{ effect = E.Glowing, amplifier = 0, ticks = 100, ambient = false },
			{ effect = E.InstantHealth, amplifier = 0, ticks = 1, ambient = false },
		}
		local good, rest = Effects.hudOrder(entries)
		t.eq(#good, 3, "the beneficial row")
		t.ok(
			good[1].effect == E.NightVision and good[2].effect == E.Haste and good[3].effect == E.Speed,
			"infinite, then longest"
		)
		t.ok(#rest == 2 and rest[1].effect == E.Poison and rest[2].effect == E.Glowing, "harmful and neutral below")
		t.eq(Effects.iconAlpha(1000, false), 1)
		t.eq(Effects.iconAlpha(INFINITE, false), 1)
		t.eq(Effects.iconAlpha(50, true), 1, "ambient effects never flash")
		local low = Effects.iconAlpha(10, false)
		t.ok(low < 1, `fading at the end ({low})`)
		t.eq(Effects.nightVisionScale(1000), 1)
		t.ok(Effects.nightVisionScale(150) <= 1 and Effects.nightVisionScale(150) >= 0.4, "flickering")
		local start, finish = Effects.blindnessFog(100, 256)
		t.ok(finish == 5 and start == 1.25, "blind: 5 blocks")
		local _, opening = Effects.blindnessFog(10, 256)
		t.ok(near(opening, 130.5), "opening up in the last second")
		t.eq(select(2, Effects.blindnessFog(0, 256)), 256)
		local intensity = 0
		for _ = 1, 100 do
			intensity = Effects.nauseaIntensity(intensity, 160, 1)
		end
		t.ok(near(intensity, 0.6), "Nausea builds up 0.006 a tick")
		intensity = Effects.nauseaIntensity(intensity, 40, 10)
		t.ok(near(intensity, 0.5), "and fades 0.01 a tick in its last 3 s")
		t.eq(select(1, Effects.nauseaSway(0, 3)), 0)
		local glyphs = EffectIcons.GLYPHS
		for _, effect in Effects.list do
			local glyph = glyphs[effect.icon]
			t.ok(glyph ~= nil and #glyph == EffectIcons.SIZE, `{effect.name}'s icon`)
			for _, row in glyph do
				t.ok(#row == EffectIcons.SIZE and not string.find(row, "[^%.KCLDW]"), `{effect.icon}: {row}`)
			end
		end
	end)
end
