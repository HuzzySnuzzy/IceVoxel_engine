--!strict
--[[
	Body temperature, pure (no Roblox APIs, so the tests run it): Tough As Nails 1.18+'s model
	(TemperatureHelper, TemperatureHandler), five levels the body drifts between one at a time
	towards the level its surroundings give (the target):

	  ICY (-2)  COLD (-1)  NEUTRAL (0)  WARM (1)  HOT (2)

	The target (`target`, from an Environment the server's Players/Climate gathers once a second):
	  1. the climate: the surface biome's temperature (BiomeList, about -1 tundra .. 0.8 desert),
	     ALTITUDE_LAPSE (0.001) colder per block above ALTITUDE_START (256: TAN takes Minecraft's
	     biome temperature at the player's height, which falls with altitude), then
	       outdoors (nothing opaque above the head) at night: NIGHT (0.3) colder;
	       under a roof: SHELTER (0.15) colder (out of the sun by day, out of the wind by night);
	       underground (under a roof and UNDERGROUND_DEPTH (16) blocks or more below the column's
	       terrain): neutral whatever the biome, as TAN's deep underground;
	     cut into a level at CLIMATE's borders (-0.55, -0.25, 0.4, 0.7): a tundra is icy, a taiga
	     cold (icy at night), plains and forests neutral, savannas and jungles warm, a desert hot
	     by day and warm at night, the highest peaks cold or icy;
	  2. then a level at a time (never past ICY or HOT), TAN's modifiers:
	       wet (in water, or out of it for less than Config.ToughAsNails.WetTicks)   one colder
	       sprinting (the client's sprint flag)                                        one warmer
	       a heating block within Config.ToughAsNails.ProximityRadius (lava, fire, a lit furnace:
	       Players/Climate), or burning                                                one warmer
	       a cooling block in that range (ice, snow)                                   one colder
	       two or more leather armor pieces while colder than NEUTRAL (insulation)     one warmer

	Each tick (`tick`): the level steps once towards the target every Config.ToughAsNails
	.ChangeTicks (200: 10 s a level; the count restarts whenever the level is on target), then
	the extremes, Minecraft's freezing (Entity.ticksFrozen, which TAN's hypothermia uses) and
	TAN's hyperthermia the same way:
	  hypothermia  at ICY `frozen` rises 1 a tick up to FREEZE_TICKS (140, getTicksRequiredToFreeze),
	               else falls 2 a tick (Entity.baseTick's thaw). Wearing any leather (Minecraft's
	               freeze_immune_wearables) keeps it from rising;
	  hyperthermia at HOT `heat` the same way;
	  fully frozen or overheated: EXTREME_DAMAGE (1) half heart every HURT_INTERVAL (40) ticks
	  (LivingEntity.aiStep's freeze hurt), through armor (Minecraft's freeze damage bypasses it).
	Creative and spectator players (GameMode.invulnerable): the level stands still and both
	extremes clear at once.
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
	-- A heating / cooling block within reach (Players/Climate), or burning.
	heated: boolean,
	cooled: boolean,
	-- Leather armor pieces worn (0..4).
	leather: number,
}

export type State = {
	level: number,
	target: number,
	-- Ticks until the next step towards the target.
	delay: number,
	-- Hypothermia and hyperthermia, 0..FREEZE_TICKS.
	frozen: number,
	heat: number,
	-- Ticks towards the next extreme hurt.
	timer: number,
	-- Ticks left wet.
	wet: number,
}

local Temperature = {}

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

-- The climate's borders between the levels (ICY | COLD | NEUTRAL | WARM | HOT).
Temperature.CLIMATE = table.freeze({ -0.55, -0.25, 0.4, 0.7 })
Temperature.ALTITUDE_START = 256
Temperature.ALTITUDE_LAPSE = 0.001
Temperature.NIGHT = 0.3
Temperature.SHELTER = 0.15
Temperature.UNDERGROUND_DEPTH = 16
-- Leather pieces that insulate against the cold.
Temperature.INSULATION_PIECES = 2
-- Minecraft's getTicksRequiredToFreeze, its thaw per tick and its freeze hurt.
Temperature.FREEZE_TICKS = 140
Temperature.THAW = 2
Temperature.HURT_INTERVAL = 40
Temperature.EXTREME_DAMAGE = 1

-- `level` kept within ICY..HOT.
local function clampLevel(level: number): number
	return math.clamp(level, Temperature.ICY, Temperature.HOT)
end

-- The level's name ("Neutral").
function Temperature.name(level: number): string
	return Temperature.NAMES[clampLevel(level)]
end

-- Is the environment underground (see the header)?
function Temperature.underground(env: Environment): boolean
	return not env.skyOpen and env.y <= env.surface - Temperature.UNDERGROUND_DEPTH
end

-- The climate's value where the player stands (step 1 of the header), before the cut.
function Temperature.climateValue(env: Environment): number
	if Temperature.underground(env) then
		return 0
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

-- The level a climate value is cut into.
function Temperature.levelOf(value: number): number
	local borders = Temperature.CLIMATE
	if value < borders[1] then
		return Temperature.ICY
	elseif value < borders[2] then
		return Temperature.COLD
	elseif value < borders[3] then
		return Temperature.NEUTRAL
	elseif value < borders[4] then
		return Temperature.WARM
	end
	return Temperature.HOT
end

-- The level the surroundings give (see the header).
function Temperature.target(env: Environment): number
	local level = Temperature.levelOf(Temperature.climateValue(env))
	if env.wet then
		level = clampLevel(level - 1)
	end
	if env.sprinting then
		level = clampLevel(level + 1)
	end
	if env.heated then
		level = clampLevel(level + 1)
	end
	if env.cooled then
		level = clampLevel(level - 1)
	end
	if level < Temperature.NEUTRAL and env.leather >= Temperature.INSULATION_PIECES then
		level += 1
	end
	return level
end

function Temperature.new(): State
	return {
		level = Temperature.NEUTRAL,
		target = Temperature.NEUTRAL,
		delay = Config.ToughAsNails.ChangeTicks,
		frozen = 0,
		heat = 0,
		timer = 0,
		wet = 0,
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

-- Where the level goes next: 1 rising, -1 falling, 0 on target.
function Temperature.trend(state: State): number
	return if state.target > state.level then 1 elseif state.target < state.level then -1 else 0
end

-- How far the extremes have got (0..1): hypothermia, hyperthermia.
function Temperature.extremes(state: State): (number, number)
	return state.frozen / Temperature.FREEZE_TICKS, state.heat / Temperature.FREEZE_TICKS
end

--[[
	One tick of a player in game `mode`; `freezeImmune` when they wear leather (Minecraft's
	freeze_immune_wearables). Returns the half hearts the extremes cost them (see the header).
]]
function Temperature.tick(state: State, mode: string, freezeImmune: boolean?): number
	if state.wet > 0 then
		state.wet -= 1
	end
	if GameMode.invulnerable(mode) then
		state.frozen, state.heat, state.timer = 0, 0, 0
		state.delay = Config.ToughAsNails.ChangeTicks
		return 0
	end
	local target = clampLevel(state.target)
	if state.level == target then
		state.delay = Config.ToughAsNails.ChangeTicks
	else
		state.delay -= 1
		if state.delay <= 0 then
			state.level += if target > state.level then 1 else -1
			state.delay = Config.ToughAsNails.ChangeTicks
		end
	end

	local full = Temperature.FREEZE_TICKS
	if state.level == Temperature.ICY and not freezeImmune then
		state.frozen = math.min(full, state.frozen + 1)
	else
		state.frozen = math.max(0, state.frozen - Temperature.THAW)
	end
	if state.level == Temperature.HOT then
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
