--!strict
--[[
	Hunger, pure (no Roblox APIs, so the tests run it): Minecraft 1.20.1's FoodData, the food bar
	Tough As Nails' thirst (Shared/ToughAsNails/Thirst) was modelled on, and the rules around it
	(Player.canEat, LocalPlayer's sprint rule, HungerMobEffect). Config.Hunger turns it on and off
	(`on`) and tunes it; server Players/ToughAsNails plays it out beside thirst, every player's
	state sent to them in the Survival message (client Ui/StatusCluster draws it as the FOOD
	status icon).

	  food        foodLevel 0..MAX (20): Minecraft's ten shanks, the FOOD icon's fill. Starts full.
	  saturation  saturationLevel 0..food (a float), used up before food. Starts at
	              START_SATURATION (5).
	  exhaustion  exhaustionLevel 0..MAX_EXHAUSTION (40, FoodData.addExhaustion's cap): above STEP
	              (4), 4 is taken off and a point of saturation goes, or a point of food when there is
	              no saturation left (FoodData.tick).
	  timer       FoodData's tickTimer: ticks towards the next heal or starvation hurt.

	Exhaustion is Minecraft's FoodConstants (EXHAUSTION): what the client measures of its movement
	(ToughAsNails/Exertion: 0.1 a sprinted metre, 0.01 a metre in water, 0.05 a jump, 0.2 a
	sprint jump), and what the server sees: a block broken (0.005), a hurt that landed (0.1), an
	attack that landed (0.1, Player.attack). The same amounts go to thirst (TAN counts
	Player.causeFoodExhaustion as well; attacks are hunger's alone, so thirst stays as it was), but
	the HOT zone's sweating (Config.ToughAsNails.HotExhaustion) is thirst's alone. Minecraft's
	Hunger effect adds Config.Hunger.EffectExhaustion (0.005) x (amplifier + 1) every tick
	(`effectExhaustion`: the effects whose entry `drainsFood`, Content/Schema's EFFECT_FIELDS).

	One tick (`tick`, 20 a second), FoodData.tick after the status effects (Player.tick: super.tick
	first, LivingEntity.tickEffects): `extra` exhaustion is added (the Hunger effect's), the
	exhaustion turns into lost saturation or food, then, while the player is hurt (0 < health <
	max) and natural regeneration may run (Config.Hunger.NaturalRegeneration, Minecraft's
	naturalRegeneration rule; not `stopped`; with `thirst` given, thirst THIRST_REGEN (18) or more):
	  saturated   food 20 with saturation left: every FAST_INTERVAL (10) ticks heal f / 6 half
	              hearts, f = min(saturation, FAST_SATURATION (6)), for f exhaustion (Minecraft
	              1.11's fast regeneration: a full bar burns its saturation into health);
	  fed         else food REGEN_FOOD (18) or more: half a heart every INTERVAL (80) ticks, for
	              REGEN_COST (6) exhaustion;
	  starving    else (whether or not regeneration may run) at food 0: half a heart every
	              STARVE_INTERVAL (80) ticks while health is above Config.Hunger.StarvationFloor
	              half hearts (normal difficulty: health > 1; the timer goes round either way);
	  otherwise the timer stops at 0.
	`stopped` is the server's regeneration hold: the body fully frozen or overheated
	(Temperature.stopsRegeneration) or the zombie apocalypse's infection from stage III
	(Players/ToughAsNails.setRegenBlock). `thirst` is given while Tough As Nails' thirst rules
	regeneration (Config.ToughAsNails.ThirstRegeneration): TAN wants both bars high, and thirst's
	own regeneration (Thirst.tick's) is retired while hunger is on, so health has one source.
	Tough As Nails' Climate Clemency halves thirst's drain and spares dehydration only (TAN's
	clemency is about the climate and water): hunger drains and starves as ever under it.
	Creative and spectator players (GameMode.invulnerable, Minecraft's abilities.invulnerable,
	which causeFoodExhaustion skips) are untouched: nothing drains, heals or hurts.

	Eating (`eat`) is FoodData.eat: food + nutrition (at most MAX), saturation + nutrition x
	saturationModifier x 2 (at most the new food). Who may eat (`canEat`): Player.canEat, food
	below 20 or an invulnerable player (a food that may always be eaten is Items/Foods' to say).
	Sprinting (`canSprint`): LocalPlayer.aiStep's `foodLevel > 6 || mayfly`: at SPRINT_FOOD (6) or
	less a sprint neither starts nor goes on, unless the mode may fly (creative, spectator).

	Minecraft's food bar rules, kept specced though the HUD now shows a status icon instead (its
	falling arrows stand for the shake): `shank` (each of the ten from the right, 2 points a shank,
	a half shank for an odd point) and `jitters` (Gui.renderPlayerHealth: without saturation the
	shanks shake on ticks where tick % (food x 3 + 1) == 0).
]]

local Config = require(script.Parent.Config)
local Effects = require(script.Parent.Effects)
local GameMode = require(script.Parent.GameMode)

export type State = {
	food: number,
	saturation: number,
	exhaustion: number,
	timer: number,
}

local Hunger = {}

Hunger.MAX = 20
Hunger.START_SATURATION = 5
Hunger.STEP = 4
Hunger.MAX_EXHAUSTION = 40
-- The saturated branch: ticks between heals and the most saturation one heal spends.
Hunger.FAST_INTERVAL = 10
Hunger.FAST_SATURATION = 6
-- The fed branch: ticks between heals, the food it needs and its exhaustion.
Hunger.INTERVAL = 80
Hunger.REGEN_FOOD = 18
Hunger.REGEN_COST = 6
-- Ticks between two starvation hurts.
Hunger.STARVE_INTERVAL = 80
-- The thirst regeneration needs too (Tough As Nails' rule, Thirst.REGEN_THIRST's 18).
Hunger.THIRST_REGEN = 18
-- At this much food or less no sprint (LocalPlayer.aiStep).
Hunger.SPRINT_FOOD = 6

-- Minecraft's FoodConstants (exhaustion per cause; Thirst.EXHAUSTION has the same for water).
Hunger.EXHAUSTION = table.freeze({
	-- A metre sprinted on the ground (EXHAUSTION_SPRINT 0.1 per metre).
	sprintMetre = 0.1,
	-- A metre swum, walked under water or waded (EXHAUSTION_SWIM 0.01 per metre).
	waterMetre = 0.01,
	-- A jump (EXHAUSTION_JUMP), a sprinting one (EXHAUSTION_SPRINT_JUMP).
	jump = 0.05,
	sprintJump = 0.2,
	-- A block broken (EXHAUSTION_MINE).
	mine = 0.005,
	-- A hurt that landed (DamageSource's exhaustion, 0.1 for nearly everything).
	hurt = 0.1,
	-- An attack that landed (EXHAUSTION_ATTACK).
	attack = 0.1,
})

-- Is hunger on (Config.Hunger.Enabled)?
function Hunger.on(): boolean
	return Config.Hunger.Enabled == true
end

-- A full bar: Minecraft's new FoodData (and a respawned player's).
function Hunger.new(): State
	return {
		food = Hunger.MAX,
		saturation = Hunger.START_SATURATION,
		exhaustion = 0,
		timer = 0,
	}
end

-- FoodData.addExhaustion: more exhaustion, up to MAX_EXHAUSTION (nonsense adds nothing).
function Hunger.addExhaustion(state: State, amount: number)
	if amount > 0 and amount == amount then
		state.exhaustion = math.min(state.exhaustion + amount, Hunger.MAX_EXHAUSTION)
	end
end

-- Is there room to eat (FoodData.needsFood)?
function Hunger.needsFood(food: number): boolean
	return food < Hunger.MAX
end

-- May a player in game `mode` with `food` eat a plain food now (Player.canEat: invulnerable
-- players always may)?
function Hunger.canEat(food: number, mode: string): boolean
	return GameMode.invulnerable(mode) or Hunger.needsFood(food)
end

-- FoodData.eat: `nutrition` points and saturation by `saturationModifier` (see the header).
function Hunger.eat(state: State, nutrition: number, saturationModifier: number)
	state.food = math.clamp(state.food + nutrition, 0, Hunger.MAX)
	state.saturation = math.clamp(state.saturation + nutrition * saturationModifier * 2, 0, state.food)
end

-- The food exhaustion a tick of the effects in `levels` adds (Minecraft's Hunger, see the header).
function Hunger.effectExhaustion(levels: Effects.Levels): number
	local total = 0
	for id, amplifier in levels do
		local effect = Effects.get(id)
		if effect and effect.drainsFood then
			total += Config.Hunger.EffectExhaustion * (math.max(amplifier, 0) + 1)
		end
	end
	return total
end

-- May a player in game `mode` with `food` sprint (start or go on: see the header)?
function Hunger.canSprint(food: number, mode: string): boolean
	return food > Hunger.SPRINT_FOOD or GameMode.mayFly(mode)
end

--[[
	One tick of a player in game `mode` with `health` half hearts (of `maxHealth`, Minecraft's 20)
	and `extra` exhaustion (the Hunger effect's), `stopped` while the server holds regeneration,
	`thirst` the player's thirst while it rules regeneration too (nil: it has no say). Returns the
	half hearts starvation costs them and the half hearts regeneration gives back (a share of one
	in the saturated branch). See the header.
]]
function Hunger.tick(
	state: State,
	mode: string,
	health: number,
	maxHealth: number,
	extra: number?,
	stopped: boolean?,
	thirst: number?
): (number, number)
	if GameMode.invulnerable(mode) then
		state.timer = 0
		return 0, 0
	end
	local settings = Config.Hunger
	Hunger.addExhaustion(state, extra or 0)
	if state.exhaustion > Hunger.STEP then
		state.exhaustion -= Hunger.STEP
		if state.saturation > 0 then
			state.saturation = math.max(state.saturation - 1, 0)
		else
			state.food = math.max(state.food - 1, 0)
		end
	end

	local regenerates = settings.NaturalRegeneration == true
		and not stopped
		and (thirst == nil or thirst >= Hunger.THIRST_REGEN)
		and health > 0
		and health < maxHealth
	if regenerates and state.saturation > 0 and state.food >= Hunger.MAX then
		state.timer += 1
		if state.timer >= Hunger.FAST_INTERVAL then
			state.timer = 0
			local spent = math.min(state.saturation, Hunger.FAST_SATURATION)
			Hunger.addExhaustion(state, spent)
			return 0, spent / Hunger.FAST_SATURATION
		end
	elseif regenerates and state.food >= Hunger.REGEN_FOOD then
		state.timer += 1
		if state.timer >= Hunger.INTERVAL then
			state.timer = 0
			Hunger.addExhaustion(state, Hunger.REGEN_COST)
			return 0, 1
		end
	elseif state.food <= 0 then
		state.timer += 1
		if state.timer >= Hunger.STARVE_INTERVAL then
			state.timer = 0
			if health > settings.StarvationFloor then
				return 1, 0
			end
		end
	else
		state.timer = 0
	end
	return 0, 0
end

--[[ Minecraft's food bar (specced; the HUD's FOOD icon is client Ui/StatusCluster's) ]]

-- The state of shank `i` (1 = rightmost) at `food` points: 0 empty, 1 half, 2 full.
function Hunger.shank(food: number, i: number): number
	return math.clamp(food - (i - 1) * 2, 0, 2)
end

-- Do the shanks shake on HUD tick `tick` (Gui.renderPlayerHealth's rule, see the header)?
function Hunger.jitters(saturation: number, food: number, tick: number): boolean
	return saturation <= 0 and tick % (food * 3 + 1) == 0
end

return Hunger
