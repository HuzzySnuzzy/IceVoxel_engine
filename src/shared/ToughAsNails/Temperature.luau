--!strict
--[[
	Body temperature, pure (no Roblox APIs, so the tests run it): Tough As Nails' model with the
	fine scale of TAN 1.12 (an integer body temperature, here -10..10: 21 steps) cut into the five
	zones of TAN 1.18+ (TemperatureLevel), which the HUD's colours and the extremes go by:

	  ICY (-2)      -10 .. -8    hypothermia builds
	  COLD (-1)      -7 .. -3
	  NEUTRAL (0)    -2 ..  2
	  WARM (1)        3 ..  7
	  HOT (2)         8 .. 10    hyperthermia builds, sweating costs thirst

	The zone ids (`zone`, Temperature.ICY .. HOT) are the five levels this module had before, so
	whatever thinks in zones keeps working. The body drifts a step at a time towards the
	temperature its surroundings give (the target):

	  1. the climate (`climateValue`): the surface biome's temperature (BiomeList, -0.75 tundra ..
	     0.8 desert), ALTITUDE_LAPSE (0.001) colder per block above ALTITUDE_START (256: TAN takes
	     Minecraft's biome temperature at the player's height, which falls with altitude), then
	       outdoors (nothing opaque above the head) at night: NIGHT (0.3) colder;
	       under a roof: SHELTER (0.15) colder (out of the sun by day, out of the wind by night);
	       underground (under a roof and UNDERGROUND_DEPTH (16) blocks or more below the column's
	       terrain): NEUTRAL's middle whatever the biome (UNDERGROUND_CLIMATE, 0.075: 0 on the
	       scale), as TAN's deep underground;
	     put on the scale (`scaleOf`) piecewise linearly through CLIMATE's borders (-0.55, -0.25,
	     0.4, 0.7), which land on SCALE (-7.5, -2.5, 2.5, 7.5), the zones' borders, so the zones
	     fall where the five levels were cut; beyond the outer borders the nearest segment's slope
	     goes on. Rounded half up (a border belongs to the warmer side) and kept within -10..10:
	     a tundra -10 (icy), a taiga -4 (cold; -9 at night), plains 0, a savanna 4, a jungle 7, a
	     desert 9 (hot; 4 at night, 7 in a house), the highest peaks cold or icy;
	  2. TAN's modifiers, in steps (MODIFIERS, each kept within -10..10):
	       wet (in water, or out of it for less than Config.ToughAsNails.WetTicks)           -3
	       sprinting (the client's sprint flag)                                             +2
	       a heating block within Config.ToughAsNails.ProximityRadius (lava, fire, a lit
	       furnace: Players/Climate)                              +3, or +5 within NEAR (2) blocks
	       burning                             +5 (with a heat source too: the larger, not both)
	       a cooling block in that range (ice, snow)                                         -3
	  3. armor insulation (ItemList `tan`, summed over the pieces worn by Players/Climate
	     .insulation): `warmth` steps pull a target below 0 up towards 0, `cooling` steps pull one
	     above 0 down towards 0, never past it (insulation keeps the weather out; it neither heats
	     nor chills by itself);
	  4. given the player's own state (`target(env, state)`): TAN's effects, Internal Warmth
	     (`giveWarmth`) EFFECT_STEPS (5) warmer but never past NEUTRAL's top (2) by it, Internal
	     Chill (`giveChill`) 5 colder but never past NEUTRAL's bottom (-2): they protect without
	     causing the opposite extreme (Drinks give them); then TAN's Climate Clemency
	     (`grantClemency`) holds the target within NEUTRAL (-2..2).

	Each tick (`tick`):
	  * wet and the effects count down, and Climate Clemency in survival and adventure only
	    (`tickEffects`, which also runs alone while temperature is off, for thirst's sake);
	  * the drift: a step towards the target once Config.ToughAsNails.ChangeTicks (140) ticks
	    have gone by moving away from 0, or RecoverTicks (70) moving back towards it (the count
	    restarts on target and after each step): from neutral the icy edge (-8) is 56 s away in
	    the coldest place, and from there back to NEUTRAL's edge 21 s;
	  * the extremes, Minecraft's freezing (Entity.ticksFrozen, which TAN's hypothermia uses)
	    slowed down, and TAN's hyperthermia the same way:
	      hypothermia   in the ICY zone `frozen` rises 1 a tick up to EXTREME_TICKS (400: 20 s
	                    where Minecraft takes 7), else falls THAW (4) a tick (5 s from full).
	                    Never during Climate Clemency, nor wearing a piece that is freeze immune
	                    (Minecraft's freeze_immune_wearables: leather; ItemList `tan.freezeImmune`);
	      hyperthermia  in the HOT zone `heat` the same way (Climate Clemency stops it too);
	      fully frozen or overheated: EXTREME_DAMAGE (1) half heart every HURT_INTERVAL (100:
	      5 s, Minecraft's 2) ticks, through armor (Minecraft's freeze damage bypasses it).
	So from neutral, full health and nothing worn, in the coldest place once the clemency is over:
	icy after 56 s, frozen through 20 s later, then half a heart every 5 s; death comes after
	176 s of temperature alone, and after about 3 1/2 minutes with thirst's regeneration
	fighting back while thirst lasts (205 s; the hottest place 200 s, sweating; on joining the 5
	minutes of clemency come first). tests/spec/ToughAsNails simulates it tick by tick. (Before:
	two levels of 10 s, frozen in 7 s, a hurt every 2 s: 67 s.)
	Creative and spectator players (GameMode.invulnerable): the temperature stands still, both
	extremes clear at once and the clemency waits.
]]

local Config = require(script.Parent.Parent.Config)
local GameMode = require(script.Parent.Parent.GameMode)

export type Environment = {
	-- The surface biome's temperature (BiomeList, roughly -1..1).
	climate: number,
	-- Feet height and the terrain height of the column (first air block), blocks.
	y: number,
	surface: number,
	-- Nothing opaque above the head (Machines/SkyCheck's rule).
	skyOpen: boolean,
	night: boolean,
	wet: boolean,
	sprinting: boolean,
	-- A heating block within Config.ToughAsNails.ProximityRadius, one within NEAR blocks
	-- (Players/Climate), a cooling block within the radius.
	heated: boolean,
	nearHeat: boolean,
	cooled: boolean,
	-- On fire.
	burning: boolean,
	-- Steps of insulation the armor worn gives (ItemList `tan`, Players/Climate.insulation).
	armorWarmth: number,
	armorCooling: number,
}

export type State = {
	-- The body temperature (-10..10) and where it is going (-10..10).
	value: number,
	target: number,
	-- Ticks spent moving towards the target since the last step.
	drift: number,
	-- Hypothermia and hyperthermia, 0..EXTREME_TICKS.
	frozen: number,
	heat: number,
	-- Ticks towards the next extreme hurt.
	timer: number,
	-- Ticks left wet.
	wet: number,
	-- Ticks left of TAN's Internal Warmth and Internal Chill.
	warmth: number,
	chill: number,
	-- Ticks left of TAN's Climate Clemency.
	clemency: number,
}

local Temperature = {}

-- The scale's ends.
Temperature.MIN = -10
Temperature.MAX = 10

-- Zone ids (TAN's TemperatureLevel, the five levels of before).
Temperature.ICY = -2
Temperature.COLD = -1
Temperature.NEUTRAL = 0
Temperature.WARM = 1
Temperature.HOT = 2
Temperature.NAMES = table.freeze({
	[-2] = "Icy",
	[-1] = "Cold",
	[0] = "Neutral",
	[1] = "Warm",
	[2] = "Hot",
} :: { [number]: string })
-- Each zone's coldest and warmest temperature.
Temperature.ZONES = table.freeze({
	[-2] = table.freeze({ -10, -8 }),
	[-1] = table.freeze({ -7, -3 }),
	[0] = table.freeze({ -2, 2 }),
	[1] = table.freeze({ 3, 7 }),
	[2] = table.freeze({ 8, 10 }),
} :: { [number]: { number } })

-- The climate's borders between the zones and where they land on the scale (see the header).
Temperature.CLIMATE = table.freeze({ -0.55, -0.25, 0.4, 0.7 })
Temperature.SCALE = table.freeze({ -7.5, -2.5, 2.5, 7.5 })
Temperature.ALTITUDE_START = 256
Temperature.ALTITUDE_LAPSE = 0.001
Temperature.NIGHT = 0.3
Temperature.SHELTER = 0.15
Temperature.UNDERGROUND_DEPTH = 16
-- Halfway between NEUTRAL's climate borders: 0 on the scale.
Temperature.UNDERGROUND_CLIMATE = (Temperature.CLIMATE[2] + Temperature.CLIMATE[3]) / 2
-- The modifiers, in steps (see the header), and how near a heat source warms the most.
Temperature.MODIFIERS = table.freeze({
	wet = -3,
	sprinting = 2,
	heated = 3,
	nearHeat = 5,
	burning = 5,
	cooled = -3,
})
Temperature.NEAR = 2
-- Internal Warmth and Internal Chill: steps, and the bound they never push past.
Temperature.EFFECT_STEPS = 5
-- Hypothermia and hyperthermia: ticks to full, thaw per tick, ticks between hurts, half hearts.
Temperature.EXTREME_TICKS = 400
Temperature.THAW = 4
Temperature.HURT_INTERVAL = 100
Temperature.EXTREME_DAMAGE = 1

-- `value` kept within the scale.
local function clampValue(value: number): number
	return math.clamp(value, Temperature.MIN, Temperature.MAX)
end

-- The zone (Temperature.ICY .. HOT) of a body temperature.
function Temperature.zone(value: number): number
	if value <= Temperature.ZONES[Temperature.ICY][2] then
		return Temperature.ICY
	elseif value <= Temperature.ZONES[Temperature.COLD][2] then
		return Temperature.COLD
	elseif value <= Temperature.ZONES[Temperature.NEUTRAL][2] then
		return Temperature.NEUTRAL
	elseif value <= Temperature.ZONES[Temperature.WARM][2] then
		return Temperature.WARM
	end
	return Temperature.HOT
end

-- The name of a body temperature's zone ("Neutral").
function Temperature.name(value: number): string
	return Temperature.NAMES[Temperature.zone(value)]
end

-- Is the environment underground (see the header)?
function Temperature.underground(env: Environment): boolean
	return not env.skyOpen and env.y <= env.surface - Temperature.UNDERGROUND_DEPTH
end

-- The climate's value where the player stands (step 1 of the header), before the scale.
function Temperature.climateValue(env: Environment): number
	if Temperature.underground(env) then
		return Temperature.UNDERGROUND_CLIMATE
	end
	local value = env.climate - math.max(0, env.y - Temperature.ALTITUDE_START) * Temperature.ALTITUDE_LAPSE
	if env.skyOpen then
		if env.night then
			value -= Temperature.NIGHT
		end
	else
		value -= Temperature.SHELTER
	end
	return value
end

-- A climate value on the scale, unrounded and unbounded (see the header).
function Temperature.scaleOf(value: number): number
	local borders, scale = Temperature.CLIMATE, Temperature.SCALE
	local count = #borders
	-- The border at or below the value (the first below them all), and the segment's slope.
	local anchor = 1
	for i = count, 1, -1 do
		if value >= borders[i] then
			anchor = i
			break
		end
	end
	local segment = math.min(anchor, count - 1)
	local slope = (scale[segment + 1] - scale[segment]) / (borders[segment + 1] - borders[segment])
	return scale[anchor] + (value - borders[anchor]) * slope
end

-- The temperature a climate value gives: on the scale, rounded half up, within -10..10.
function Temperature.levelOf(value: number): number
	return clampValue(math.floor(Temperature.scaleOf(value) + 0.5))
end

--[[
	The temperature the surroundings give (steps 1 to 3 of the header), and with the player's
	`state` their effects and Climate Clemency too (step 4).
]]
function Temperature.target(env: Environment, state: State?): number
	local modifiers = Temperature.MODIFIERS
	local value = Temperature.levelOf(Temperature.climateValue(env))
	if env.wet then
		value = clampValue(value + modifiers.wet)
	end
	if env.sprinting then
		value = clampValue(value + modifiers.sprinting)
	end
	local source = if env.nearHeat then modifiers.nearHeat elseif env.heated then modifiers.heated else 0
	local heat = math.max(source, if env.burning then modifiers.burning else 0)
	if heat > 0 then
		value = clampValue(value + heat)
	end
	if env.cooled then
		value = clampValue(value + modifiers.cooled)
	end
	if value < 0 and env.armorWarmth > 0 then
		value = math.min(0, value + env.armorWarmth)
	elseif value > 0 and env.armorCooling > 0 then
		value = math.max(0, value - env.armorCooling)
	end
	if state then
		value = Temperature.adjusted(state, value)
	end
	return value
end

--[[
	A target with the player's effects and Climate Clemency (step 4 of the header): Internal
	Warmth and Chill move it EFFECT_STEPS but never past NEUTRAL by that; the clemency holds it
	within NEUTRAL.
]]
function Temperature.adjusted(state: State, target: number): number
	local low, high = Temperature.ZONES[Temperature.NEUTRAL][1], Temperature.ZONES[Temperature.NEUTRAL][2]
	local value = clampValue(target)
	if state.warmth > 0 and value < high then
		value = math.min(value + Temperature.EFFECT_STEPS, high)
	end
	if state.chill > 0 and value > low then
		value = math.max(value - Temperature.EFFECT_STEPS, low)
	end
	if state.clemency > 0 then
		value = math.clamp(value, low, high)
	end
	return value
end

-- A new body: neutral, dry, with `clemency` ticks of Climate Clemency (none by default).
function Temperature.new(clemency: number?): State
	return {
		value = 0,
		target = 0,
		drift = 0,
		frozen = 0,
		heat = 0,
		timer = 0,
		wet = 0,
		warmth = 0,
		chill = 0,
		clemency = math.max(0, clemency or 0),
	}
end

-- The player touches water: wet for Config.ToughAsNails.WetTicks.
function Temperature.soak(state: State)
	state.wet = Config.ToughAsNails.WetTicks
end

-- Is the player wet?
function Temperature.isWet(state: State): boolean
	return state.wet > 0
end

-- TAN's Internal Warmth / Internal Chill for `ticks` (a longer one already running stays,
-- Minecraft's MobEffectInstance.update).
function Temperature.giveWarmth(state: State, ticks: number)
	state.warmth = math.max(state.warmth, ticks)
end

function Temperature.giveChill(state: State, ticks: number)
	state.chill = math.max(state.chill, ticks)
end

-- TAN's Climate Clemency for `ticks` (a longer one already running stays).
function Temperature.grantClemency(state: State, ticks: number)
	state.clemency = math.max(state.clemency, ticks)
end

-- Is Climate Clemency on (no extremes; thirst drains at half the rate, Thirst.tick's `clement`)?
function Temperature.clement(state: State): boolean
	return state.clemency > 0
end

-- Where the temperature goes next: 1 rising, -1 falling, 0 on target.
function Temperature.trend(state: State): number
	return if state.target > state.value then 1 elseif state.target < state.value then -1 else 0
end

-- Ticks a step from `value` towards `target` takes: RecoverTicks back towards 0, else ChangeTicks.
function Temperature.stepTicks(value: number, target: number): number
	local settings = Config.ToughAsNails
	local recovering = (target > value and value < 0) or (target < value and value > 0)
	return if recovering then settings.RecoverTicks else settings.ChangeTicks
end

-- How far the extremes have got (0..1): hypothermia, hyperthermia.
function Temperature.extremes(state: State): (number, number)
	return state.frozen / Temperature.EXTREME_TICKS, state.heat / Temperature.EXTREME_TICKS
end

-- The countdowns of a tick in game `mode` (see the header): wet, the effects, the clemency.
function Temperature.tickEffects(state: State, mode: string)
	if state.wet > 0 then
		state.wet -= 1
	end
	if state.warmth > 0 then
		state.warmth -= 1
	end
	if state.chill > 0 then
		state.chill -= 1
	end
	if state.clemency > 0 and not GameMode.invulnerable(mode) then
		state.clemency -= 1
	end
end

--[[
	One tick of a player in game `mode`; `freezeImmune` when they wear a freeze immune piece
	(Minecraft's freeze_immune_wearables). Returns the half hearts the extremes cost them (see the
	header).
]]
function Temperature.tick(state: State, mode: string, freezeImmune: boolean?): number
	Temperature.tickEffects(state, mode)
	if GameMode.invulnerable(mode) then
		state.frozen, state.heat, state.timer, state.drift = 0, 0, 0, 0
		return 0
	end
	local target = clampValue(state.target)
	if state.value == target then
		state.drift = 0
	else
		state.drift += 1
		if state.drift >= Temperature.stepTicks(state.value, target) then
			state.value += if target > state.value then 1 else -1
			state.drift = 0
		end
	end

	local full = Temperature.EXTREME_TICKS
	local zone = Temperature.zone(state.value)
	local clement = state.clemency > 0
	if zone == Temperature.ICY and not freezeImmune and not clement then
		state.frozen = math.min(full, state.frozen + 1)
	else
		state.frozen = math.max(0, state.frozen - Temperature.THAW)
	end
	if zone == Temperature.HOT and not clement then
		state.heat = math.min(full, state.heat + 1)
	else
		state.heat = math.max(0, state.heat - Temperature.THAW)
	end
	if state.frozen >= full or state.heat >= full then
		state.timer += 1
		if state.timer >= Temperature.HURT_INTERVAL then
			state.timer = 0
			return Temperature.EXTREME_DAMAGE
		end
	else
		state.timer = 0
	end
	return 0
end

return Temperature
