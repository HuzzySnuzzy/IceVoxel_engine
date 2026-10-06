--!strict
--[[
	Thirst, pure (no Roblox APIs, so the tests run it): Tough As Nails 1.20's ThirstData, which is
	Minecraft 1.20.1's FoodData with water in food's place.

	  thirst      0..MAX (20): the ten droplets over the hotbar. Starts full.
	  hydration   0..thirst (a float): food's saturation, used up before thirst. Starts at 5.
	  exhaustion  0..MAX_EXHAUSTION (40, FoodData.addExhaustion's cap): above STEP (4), 4 is
	              taken off and a point of hydration goes, or a point of thirst when there is no
	              hydration left (FoodData.tick).
	  effect      ticks left of TAN's Thirst effect (dirty water): EFFECT_EXHAUSTION (0.015, gentler
	              than TAN's 0.025) more exhaustion every tick (ThirstEffect.applyEffectTick,
	              amplifier 0). A new one replaces a shorter one (Minecraft's
	              MobEffectInstance.update: the longer wins).
	  timer       FoodData's tickTimer: ticks towards the next regeneration or dehydration hurt.

	Exhaustion comes from Minecraft's FoodConstants, which TAN's thirst counts as well
	(Player.causeFoodExhaustion): EXHAUSTION below. Movement is the client's to measure
	(ToughAsNails/Exertion: Minecraft's server takes the client's sprint flag and positions too);
	breaking blocks and hurts the server sees itself. Being in the HOT zone adds
	Config.ToughAsNails.HotExhaustion (0.005) every tick (sweating; `tick`'s `extra`).

	One tick (`tick`, 20 a second, server Players/ToughAsNails), in Minecraft's order: the Thirst
	effect counts down and adds its exhaustion (LivingEntity.tickEffects), plus `extra`; then
	FoodData.tick: the exhaustion turns into lost hydration or thirst; then
	  regeneration  (Config.ToughAsNails.ThirstRegeneration) hurt, with thirst REGEN_THIRST (18) or
	                more: half a heart every INTERVAL (80) ticks, for REGEN_COST (6) exhaustion
	                (FoodData's slow branch; its fast branch spends food's saturation, and
	                hydration is no food, so it is left out); never while `stopped` (fully frozen
	                or overheated, Temperature.stopsRegeneration: the extremes hurt every 100
	                ticks, which this would outlast for anyone with water);
	  dehydration   at thirst 0: half a heart every DEHYDRATION_INTERVAL (120, gentler than
	                starvation's 80) ticks while health is above Config.ToughAsNails
	                .DehydrationFloor half hearts (FoodData's starvation on normal difficulty:
	                health > 1; TAN's thirst damage, which goes through armor like starvation);
	  otherwise the timer stops at 0.
	Under TAN's Climate Clemency (`tick`'s `clement`, ToughAsNails/Temperature.clement) thirst
	drains at CLEMENCY_RATE (half) the rate (a point goes for every STEP / CLEMENCY_RATE
	exhaustion) and dehydration doesn't hurt.
	Creative and spectator players (GameMode.invulnerable, TAN's canHurtPlayer) are untouched:
	nothing counts down, drains or hurts, and they may always drink (Player.canEat: invulnerable).

	Drinking (`drink`) is FoodData.eat's rule (TAN's ThirstData.drink): thirst + n (at most MAX),
	hydration + n x hydrationModifier x 2 (at most the new thirst). Drinks/Drink sources say how
	much (ToughAsNails/Drinks) and roll their Thirst effect with the caller's random.
]]

local Config = require(script.Parent.Parent.Config)
local GameMode = require(script.Parent.Parent.GameMode)

export type State = {
	thirst: number,
	hydration: number,
	exhaustion: number,
	effect: number,
	timer: number,
}

local Thirst = {}

Thirst.MAX = 20
Thirst.START_HYDRATION = 5
Thirst.STEP = 4
Thirst.MAX_EXHAUSTION = 40
-- FoodData's tickTimer period (regeneration) and the thirst regeneration needs.
Thirst.INTERVAL = 80
Thirst.REGEN_THIRST = 18
Thirst.REGEN_COST = 6
-- Ticks between two dehydration hurts.
Thirst.DEHYDRATION_INTERVAL = 120
-- TAN's Thirst effect, per tick at amplifier 0.
Thirst.EFFECT_EXHAUSTION = 0.015
-- How fast thirst drains under Climate Clemency.
Thirst.CLEMENCY_RATE = 0.5

-- Minecraft's FoodConstants (exhaustion per cause).
Thirst.EXHAUSTION = table.freeze({
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
})

function Thirst.new(): State
	return {
		thirst = Thirst.MAX,
		hydration = Thirst.START_HYDRATION,
		exhaustion = 0,
		effect = 0,
		timer = 0,
	}
end

-- FoodData.addExhaustion: more exhaustion, up to MAX_EXHAUSTION (nonsense adds nothing).
function Thirst.addExhaustion(state: State, amount: number)
	if amount > 0 and amount == amount then
		state.exhaustion = math.min(state.exhaustion + amount, Thirst.MAX_EXHAUSTION)
	end
end

-- Is there room to drink (FoodData.needsFood)?
function Thirst.isThirsty(state: State): boolean
	return state.thirst < Thirst.MAX
end

-- May a player in game `mode` drink now (Player.canEat: invulnerable players always may)?
function Thirst.canDrink(state: State, mode: string): boolean
	return GameMode.invulnerable(mode) or Thirst.isThirsty(state)
end

-- FoodData.eat with water: `thirst` points and hydration by `hydrationModifier` (see the header).
function Thirst.drink(state: State, thirst: number, hydrationModifier: number)
	state.thirst = math.clamp(state.thirst + thirst, 0, Thirst.MAX)
	state.hydration = math.min(state.hydration + thirst * hydrationModifier * 2, state.thirst)
end

-- Gives TAN's Thirst effect for `ticks` (a longer one already running stays).
function Thirst.giveEffect(state: State, ticks: number)
	state.effect = math.max(state.effect, ticks)
end

--[[
	One tick of a player in game `mode` with `health` half hearts (of `maxHealth`, Minecraft's 20)
	and `extra` exhaustion besides the Thirst effect's (HOT's sweating), `clement` under Climate
	Clemency, `stopped` while regeneration waits (Temperature.stopsRegeneration). Returns the half
	hearts it costs them (dehydration) and the half hearts they get back (regeneration). See the
	header.
]]
function Thirst.tick(
	state: State,
	mode: string,
	health: number,
	maxHealth: number,
	extra: number?,
	clement: boolean?,
	stopped: boolean?
): (number, number)
	if GameMode.invulnerable(mode) then
		state.timer = 0
		return 0, 0
	end
	local settings = Config.ToughAsNails
	if state.effect > 0 then
		state.effect -= 1
		Thirst.addExhaustion(state, Thirst.EFFECT_EXHAUSTION)
	end
	Thirst.addExhaustion(state, extra or 0)

	local step = if clement then Thirst.STEP / Thirst.CLEMENCY_RATE else Thirst.STEP
	if state.exhaustion > step then
		state.exhaustion -= step
		if state.hydration > 0 then
			state.hydration = math.max(state.hydration - 1, 0)
		else
			state.thirst = math.max(state.thirst - 1, 0)
		end
	end

	local hurt = health > 0 and health < maxHealth
	if settings.ThirstRegeneration and hurt and not stopped and state.thirst >= Thirst.REGEN_THIRST then
		state.timer += 1
		if state.timer >= Thirst.INTERVAL then
			state.timer = 0
			Thirst.addExhaustion(state, Thirst.REGEN_COST)
			return 0, 1
		end
	elseif state.thirst <= 0 and not clement then
		state.timer += 1
		if state.timer >= Thirst.DEHYDRATION_INTERVAL then
			state.timer = 0
			if health > settings.DehydrationFloor then
				return 1, 0
			end
		end
	else
		state.timer = 0
	end
	return 0, 0
end

return Thirst
