--[[
	A zombie bite's infection (Shared/Apocalypse/Infection, played out by server
	Apocalypse/Infection): the stages and their timings, the effect's amplifier and countdown, the
	armour's shield, one roll a RollInterval, a bite while infected taking it on, creative and
	spectator immune; untreated it kills exactly 48000 ticks after the bite and never before (stage
	IV's hurts leave the last half heart); Antibiotics cure it at every stage (with Weakness after
	a late one, given by the Antibiotics themselves from the stage read before the cure), a Herbal
	Poultice takes it back a stage and never cures it (through Items/Foods.finish's hooks, as server
	Players/Eating plays them); the regeneration it stops from stage III; dormant with the switch
	off (a saved infection kept but doing nothing); a saved progress checked; and rising on death
	(server Apocalypse/SurvivalRules: the trigger, and the look and skin of the zombie the player
	rises as).
]]

return function(t, shared, require, server)
	local Config = require(shared.Config)
	local Effects = require(shared.Effects)
	local Foods = require(shared.Items.Foods)
	local GameMode = require(shared.GameMode)
	local Items = require(shared.Items)
	local MobList = require(shared.Entities.MobList)
	local Infection = require(shared.Apocalypse.Infection)
	local SurvivalRules = require(server.Apocalypse.SurvivalRules)

	local s = Config.Apocalypse.Infection
	local I = Items.id
	local SURVIVAL, ADVENTURE, CREATIVE, SPECTATOR =
		GameMode.SURVIVAL, GameMode.ADVENTURE, GameMode.CREATIVE, GameMode.SPECTATOR
	local LETHAL = 48000

	t.test("infection: four stages of 12000 ticks, the stage as the amplifier, a countdown to death", function()
		t.eq(s.StageTicks, 12000)
		t.eq(s.Stages, 4)
		t.eq(Infection.lethal(s), LETHAL, "two in-game days")
		t.eq(Infection.stage(0, s), 0, "healthy")
		t.eq(Infection.stage(1, s), 1, "the bite")
		t.eq(Infection.stage(12000, s), 1)
		t.eq(Infection.stage(12001, s), 2)
		t.eq(Infection.stage(24000, s), 2)
		t.eq(Infection.stage(24001, s), 3)
		t.eq(Infection.stage(36001, s), 4)
		t.eq(Infection.stage(LETHAL, s), 4)
		for stage = 1, 4 do
			t.eq(Infection.amplifier((stage - 1) * 12000 + 1, s), stage - 1, `stage {stage}: "Infection {stage}"`)
		end
		t.eq(Infection.amplifier(0, s), 0)
		t.eq(Infection.ticksLeft(0, s), 0, "no effect when healthy")
		t.eq(Infection.ticksLeft(1, s), LETHAL, "the whole countdown at the bite")
		t.eq(Infection.ticksLeft(LETHAL, s), 1, "one tick left at the end")
		-- The symptoms (Shared/Effects names).
		t.eq(#Infection.symptoms(1), 0, "stage I: just the icon")
		t.eq(Infection.symptoms(2)[1].name, "Weakness")
		t.eq(#Infection.symptoms(3), 2)
		t.eq(Infection.symptoms(4)[2].name, "Slowness")
		t.eq(Infection.symptoms(4)[2].amplifier, 1, "Slowness II at stage IV")
		for stage = 1, 4 do
			for _, symptom in Infection.symptoms(stage) do
				t.ok(Effects.id[symptom.name] ~= nil, `{symptom.name} is an effect`)
			end
		end
		-- The external effect is the registry's Infection.
		local def = Effects.get(Effects.id.Infection)
		t.ok(def ~= nil and def.external, "Infection is an external effect")
	end)

	-- Plays an untreated infection out from the bite: `health` half hearts of 20, stage IV's hurt
	-- as Characters.magicHurt(player, 1, false) lands it (never the last half heart), death when
	-- `dies`. Returns the tick it killed on (nil: never within `limit`), the lowest health before
	-- it, what each stage gave and when stage IV first hurt.
	local function untreated(limit: number)
		local step = Infection.newStep()
		local p = Infection.bite(0, s)
		local health = 20
		local lowest = health
		local refreshes: { [number]: number } = {}
		local nauseas, hurts = 0, 0
		local firstHurt: number? = nil
		for tick = 1, limit do
			p = Infection.tick(p, s, step)
			if step.dies then
				return tick, lowest, refreshes, nauseas, hurts, firstHurt
			end
			if step.refresh then
				refreshes[step.stage] = (refreshes[step.stage] or 0) + 1
			end
			if step.nausea then
				nauseas += 1
			end
			if step.hurt then
				hurts += 1
				firstHurt = firstHurt or tick
				health -= math.min(1, math.max(0, health - 1))
			end
			lowest = math.min(lowest, health)
		end
		return nil, lowest, refreshes, nauseas, hurts, firstHurt
	end

	t.test("infection: untreated, it kills exactly 48000 ticks after the bite, never before", function()
		local died, lowest, refreshes, nauseas, hurts, firstHurt = untreated(60000)
		t.eq(died, LETHAL, "the tick that kills")
		t.eq(lowest, 1, "stage IV took the player down to the last half heart, never below")
		t.ok(hurts >= 100, `stage IV hurt every DamageInterval ({hurts} times)`)
		t.ok(firstHurt ~= nil and (firstHurt :: number) >= 36000, "nothing hurts before stage IV")
		-- Symptoms every 20 ticks from stage II; nausea spells only at stage III.
		t.eq(refreshes[1], nil, "stage I gives nothing")
		t.eq(refreshes[2], 12000 / Infection.SYMPTOM_EVERY)
		t.eq(nauseas, 12000 / Infection.NAUSEA_EVERY, "a nausea spell every minute of stage III")
		-- Stage IV's hurts alone never kill, whatever the health they start from.
		local step = Infection.newStep()
		local p = 36001
		local health = 1
		for _ = 1, LETHAL - 36001 do
			p = Infection.tick(p, s, step)
			t.ok(not step.dies, "not before the end")
			if step.hurt then
				health -= math.min(1, math.max(0, health - 1))
			end
		end
		t.eq(health, 1, "the last half heart stays")
		Infection.tick(p, s, step)
		t.ok(step.dies, "the next tick kills")
		-- A healthy player stays healthy.
		t.eq(Infection.tick(0, s, step), 0)
		t.ok(not step.dies and not step.refresh)
	end)

	t.test("infection: the armour's shield, one roll a RollInterval, a bite taking it on", function()
		local function near(a: number, b: number): boolean
			return math.abs(a - b) < 1e-12
		end
		t.ok(near(Infection.chance(0.04, 0, s), 0.04), "no armour")
		t.ok(near(Infection.chance(0.04, 10, s), 0.04 * (1 - 0.375)), "10 points: 37.5%")
		t.ok(near(Infection.chance(0.04, 20, s), 0.01), "20 points: 75%")
		t.ok(near(Infection.chance(0.08, 30, s), 0.02), "never past 75%")
		t.ok(Infection.mayRoll(nil, 0, s))
		t.ok(not Infection.mayRoll(0, 99, s), "within RollInterval: no roll")
		t.ok(Infection.mayRoll(0, 100, s))
		t.eq(Infection.bite(0, s), 1, "a healthy player starts at 1")
		t.eq(Infection.bite(5000, s), 7400, "an infected one goes BiteAdvance on")
		t.eq(Infection.bite(47000, s), LETHAL, "never past the end")
		-- The whole rule: a horde's hits roll once a RollInterval.
		local always = function(): number
			return 0
		end
		local never = function(): number
			return 0.999
		end
		local p, rolled = Infection.rollBite(0, nil, 10, SURVIVAL, 0.04, 0, always, s)
		t.eq(p, 1, "a bite that rolls under the chance infects")
		t.eq(rolled, 10)
		local again, rolledAgain = Infection.rollBite(p, 10, 50, SURVIVAL, 0.04, 0, always, s)
		t.eq(again, 1, "40 ticks later: no roll")
		t.eq(rolledAgain, nil)
		local later = Infection.rollBite(p, 10, 110, ADVENTURE, 0.04, 0, always, s)
		t.eq(later, 1 + s.BiteAdvance, "a RollInterval later: another bite, in adventure too")
		local missed, rolledMiss = Infection.rollBite(0, nil, 10, SURVIVAL, 0.04, 0, never, s)
		t.eq(missed, 0, "a missed roll")
		t.eq(rolledMiss, 10, "still counts as the roll")
		t.eq((Infection.rollBite(0, nil, 10, SURVIVAL, 0, 0, always, s)), 0, "a kind that never infects")
		-- Off: nothing.
		local off = table.clone(s)
		off.Enabled = false
		t.eq((Infection.rollBite(0, nil, 10, SURVIVAL, 0.04, 0, always, off)), 0, "Infection.Enabled false")
		t.eq(Infection.bite(0, off), 0)
	end)

	t.test("infection: creative and spectator players never catch it, nor get worse", function()
		local always = function(): number
			return 0
		end
		t.ok(Infection.affects(SURVIVAL) and Infection.affects(ADVENTURE))
		t.ok(not Infection.affects(CREATIVE) and not Infection.affects(SPECTATOR))
		for _, mode in { CREATIVE, SPECTATOR } do
			local p, rolled = Infection.rollBite(0, nil, 10, mode, 1, 0, always, s)
			t.eq(p, 0, `{mode}: never infected`)
			t.eq(rolled, nil, `{mode}: no roll`)
			local held, heldRoll = Infection.rollBite(5000, nil, 10, mode, 1, 0, always, s)
			t.eq(held, 5000, `{mode}: an infection they carry isn't taken on`)
			t.eq(heldRoll, nil)
		end
	end)

	-- Uses `item` at infection progress `p` through Foods.finish's hooks as server Players/Eating
	-- plays them: a cure is Players/Effects.remove (the Infection's owner: healthy at once), the
	-- stage is server Apocalypse/Infection.stage's, a setback Infection.setBack, and whatever is
	-- given (Antibiotics' Weakness after a late cure among it) goes to Players/Effects.give.
	local function use(item: number, p: number): (number, { string }, { number }, { number })
		local food = Foods.of(item) :: Foods.Food
		local cured: { string } = {}
		local given: { number } = {}
		local ticks: { number } = {}
		local now = p
		Foods.finish(food, {
			heal = function() end,
			cure = function(name: string)
				table.insert(cured, name)
				if name == "Infection" then
					now = 0
				end
			end,
			setBack = function()
				now = Infection.setBack(now, s)
			end,
			infectionStage = function(): number
				return Infection.stage(now, s)
			end,
			give = function(effect: number, length: number)
				table.insert(given, effect)
				table.insert(ticks, length)
			end,
			thirst = function() end,
			random = function(): number
				return 0.5
			end,
		})
		return now, cured, given, ticks
	end

	t.test("infection: antibiotics cure it at every stage, with Weakness after a late one", function()
		for stage = 1, 4 do
			local p = (stage - 1) * 12000 + 5000
			local after, cured, given, ticks = use(I.Antibiotics, p)
			t.eq(after, 0, `stage {stage}: cured`)
			t.eq(cured[1], "Infection")
			t.eq(#given, if stage >= 3 then 1 else 0, `stage {stage}: Weakness only after a late one`)
			if stage >= 3 then
				t.eq(given[1], Effects.id.Weakness, `stage {stage}: Weakness`)
				t.eq(ticks[1], 1200, "for a minute")
			end
		end
		t.eq(Infection.AFTERMATH_TICKS, 1200, "a minute of Weakness")
		t.eq(Infection.AFTERMATH_STAGE, 3)
		-- The stage is read before the cure: one that read it after would never give it.
		local readAfter = 0
		local late = Foods.of(I.Antibiotics) :: Foods.Food
		local cleared = false
		Foods.finish(late, {
			heal = function() end,
			cure = function()
				cleared = true
			end,
			setBack = function() end,
			infectionStage = function(): number
				return if cleared then 0 else 3
			end,
			give = function()
				readAfter += 1
			end,
			thirst = function() end,
			random = function(): number
				return 0.5
			end,
		})
		t.eq(readAfter, 1, "Weakness for the stage the cure ended")
		-- Only for the infected (and creative).
		local antibiotics = Foods.of(I.Antibiotics) :: Foods.Food
		local function infected(name: string): boolean
			return name == "Infection"
		end
		local function healthy(_name: string): boolean
			return false
		end
		t.ok(Foods.canUse(antibiotics, 4, 20, SURVIVAL, infected), "infected")
		t.ok(not Foods.canUse(antibiotics, 4, 20, SURVIVAL, healthy), "hurt but healthy: no")
		t.ok(Foods.canUse(antibiotics, 20, 20, CREATIVE, healthy), "creative uses anything")
	end)

	t.test("infection: a poultice takes it back a stage and never cures it", function()
		local stageThree = 30000
		t.eq(Infection.stage(stageThree, s), 3)
		local after, cured = use(I.HerbalPoultice, stageThree)
		t.eq(after, 18000)
		t.eq(Infection.stage(after, s), 2, "stage III back to stage II")
		t.eq(#cured, 0, "it cures nothing")
		-- Stage I restarts its stage; poultices one after another never cure.
		t.eq(Infection.setBack(5000, s), 1)
		local p = LETHAL
		for _ = 1, 10 do
			p = Infection.setBack(p, s)
			t.ok(p >= 1, "still infected")
		end
		t.eq(p, 1)
		t.eq(Infection.setBack(0, s), 0, "a healthy player stays healthy")
		-- Usable only while infected.
		local poultice = Foods.of(I.HerbalPoultice) :: Foods.Food
		t.ok(Foods.canUse(poultice, 4, 20, SURVIVAL, function(name: string): boolean
			return name == "Infection"
		end))
		t.ok(not Foods.canUse(poultice, 4, 20, SURVIVAL, function(): boolean
			return false
		end))
	end)

	t.test("infection: no natural regeneration from stage III, thirst drains from stage II", function()
		t.ok(not Infection.blocksRegeneration(0, s))
		t.ok(not Infection.blocksRegeneration(12000, s), "stage I")
		t.ok(not Infection.blocksRegeneration(24000, s), "stage II")
		t.ok(Infection.blocksRegeneration(24001, s), "stage III")
		t.ok(Infection.blocksRegeneration(LETHAL, s), "stage IV")
		t.ok(not Infection.drainsThirst(12000, s) and Infection.drainsThirst(12001, s))
	end)

	t.test("infection: dormant with the switch off: kept, but nothing shows, grows, hurts or holds", function()
		local off = table.clone(s)
		off.Enabled = false
		t.ok(Infection.dormant(off) and not Infection.dormant(s))
		local p = 30000
		t.eq(Infection.ticksLeft(p, off), 0, "no countdown on the effect list")
		t.eq(Infection.amplifier(p, off), 0)
		t.ok(not Infection.blocksRegeneration(p, off), "regeneration runs")
		t.ok(not Infection.drainsThirst(p, off), "thirst as usual")
		local step = Infection.newStep()
		local q = p
		local anything = false
		for _ = 1, LETHAL do
			q = Infection.tick(q, off, step)
			anything = anything or step.dies or step.hurt or step.refresh or step.nausea
		end
		t.eq(q, p, "it stands still")
		t.ok(not anything, "no symptoms, hurts or death")
		t.eq(Infection.fromSaved(p, off), p, "kept as saved")
		-- Back on: it goes on from where it stood.
		t.eq(Infection.ticksLeft(p, s), LETHAL + 1 - p)
		t.ok(Infection.blocksRegeneration(p, s))
	end)

	t.test("infection: a saved progress is checked (damage reads healthy)", function()
		t.eq(Infection.fromSaved(0, s), 0)
		t.eq(Infection.fromSaved(-5, s), 0)
		t.eq(Infection.fromSaved(0 / 0, s), 0)
		t.eq(Infection.fromSaved("x", s), 0)
		t.eq(Infection.fromSaved(nil, s), 0)
		t.eq(Infection.fromSaved(3.7, s), 3)
		t.eq(Infection.fromSaved(0.5, s), 1, "a sliver of one is the bite")
		t.eq(Infection.fromSaved(1e9, s), LETHAL, "never past the end")
		t.eq(Infection.fromSaved(math.huge, s), LETHAL)
	end)

	t.test("infection: an infected player's death raises a zombie in the nearest civilian look", function()
		t.ok(SurvivalRules.rises(1, true, true), "infected, on")
		t.ok(not SurvivalRules.rises(0, true, true), "healthy: no")
		t.ok(not SurvivalRules.rises(5000, false, true), "the apocalypse off")
		t.ok(not SurvivalRules.rises(5000, true, false), "RiseOnDeath off")
		t.eq(Config.Apocalypse.Zombies.RiseOnDeath, true)
		local zombie = MobList.get(MobList.find("Zombie") :: number) :: MobList.Kind
		local looks = MobList.looksOf(zombie) :: { MobList.Look }
		-- Red tee (look 1) for a red torso; blue tee (2) for a blue one; skins wrap.
		local red = SurvivalRules.riseVariant(looks, { 200, 60, 50 }, 3)
		local look, skin = MobList.look(zombie, red)
		t.eq(look, looks[1], "a red torso rises in the red tee")
		t.eq(skin, MobList.SKIN_TONES[3])
		local blue = SurvivalRules.riseVariant(looks, { 60, 110, 170 }, 1)
		t.eq((MobList.look(zombie, blue)), looks[2], "a blue torso in the blue tee")
		local wrapped = SurvivalRules.riseVariant(looks, { 200, 60, 50 }, #MobList.SKIN_TONES + 2)
		t.eq(select(2, MobList.look(zombie, wrapped)), MobList.SKIN_TONES[2], "skins wrap")
	end)
end
