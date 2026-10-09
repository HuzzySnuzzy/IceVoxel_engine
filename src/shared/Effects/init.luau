--!strict
--[[
	Status effects (Minecraft 1.20.1's MobEffect and MobEffectInstance), shared and pure: the
	registry of EffectList (ids are u8 list positions, append only: 1 Speed .. 18 Glowing,
	19 Oil Coated, 20 Fuel Soaked, 21..24 Tough As Nails' Thirst, Internal Warmth, Internal Chill,
	Climate Clemency, 25 Terraria's Mana Sickness) and the rules both sides need, so the client's
	prediction and the server's checks agree:

	  Registry   `id.Name`, `get`, `list`, `find` (a name or an /effect id, "minecraft:" or not, any
	             case), `levelName` ("Speed II": the amplifier + 1 in roman numerals up to X, as
	             Minecraft's enchantment.level names; higher in figures), `formatTicks`
	             (StringUtil.formatTickDuration: "m:ss", "h:mm:ss", "**:**" for infinite).
	  Levels     the effects in force as `{ [effect id] = amplifier }`, which the modifiers read:
	               speedFactor   the ground speed's multiplier: every `speed` effect multiplies it
	                             by 1 + speed x level (Minecraft's MULTIPLY_TOTAL modifiers:
	                             Speed I 1.2, Slowness II 0.7, Speed I with Slowness I 1.02),
	                             never below 0 (Shared/Movement/PlayerPhysics, client
	                             Player/MovementController);
	               miningFactor  Player.getDestroySpeed: Haste x (1 + 0.2 x level), Mining
	                             Fatigue x 0.3, 0.09, 0.0027, 0.00081 by level (Shared/Mining, both
	                             the client's progress and the server's check);
	               jumpBoost     Jump Boost: +0.1 jump velocity a level and as many blocks less
	                             fall damage (LivingEntity.getJumpBoostPower,
	                             calculateFallDamage);
	               meleeDamage   a melee hit's half hearts with Strength (+3 a level) and Weakness
	                             (-4 a level), never below 0 (for the combat to come);
	               incomingDamage  Resistance: (25 - 5 x level) / 25 of a hurt gets through
	                             (LivingEntity.getDamageAfterMagicAbsorb: nothing from level 5);
	               fireRules     Fire Resistance (no fire hurts), the burn factor and bonus (Oil
	                             Coated, Fuel Soaked) and catching at once (server Players/Burning);
	               noSprint      Blindness: no sprint starts (LocalPlayer.canStartSprinting).
	  Ticking    `isDurationTick` (MobEffect.isDurationEffectTick: Regeneration every 50 >> amp
	             ticks, Poison 25 >> amp, Wither 40 >> amp; the instant effects on their one tick),
	             `instantAmount` (4 << amp healed, 6 << amp hurt).
	  The view   `nightVisionScale` (GameRenderer.getNightVisionScale: full, flickering in the last
	             10 s), `blindnessFog` (FogRenderer's BlindnessFogFunction: 5 blocks, opening up in
	             the last second), `iconAlpha` (Gui.renderEffects: icons flash out over the last
	             10 s), `hudOrder` (the beneficial row and the rest, longest first).

	The server keeps each player's effects (Players/EffectRules, pure; Players/Effects, the glue
	and the API) and sends them to their client when they change (Protocol Effects), which counts
	them down itself (`remaining`).
]]

local EffectList = require(script.EffectList)

export type EffectSpec = EffectList.EffectSpec

export type Effect = {
	id: number,
	name: string,
	displayName: string,
	-- The /effect id ("jump_boost").
	command: string,
	color: { number },
	-- Its colour as Minecraft's int (0xRRGGBB): the HUD order's last tie break.
	colorValue: number,
	category: string,
	beneficial: boolean,
	icon: string,
	-- Per level (see EffectList); 0 / false / nil where it has none.
	speed: number,
	mining: number,
	fatigue: boolean,
	jump: number,
	melee: number,
	resistance: number,
	interval: number,
	heal: number,
	damage: number,
	lethal: boolean,
	instant: string?,
	fireImmune: boolean,
	burnFactor: number,
	burnBonus: number,
	ignites: boolean,
	washOff: boolean,
	view: string?,
	noSprint: boolean,
	external: boolean,
}

-- The effects in force: effect id -> amplifier (0 = level I).
export type Levels = { [number]: number }

-- One effect as the protocol carries it and the HUD shows it: ticks left (INFINITE: never ends)
-- and whether it is ambient (Minecraft's beacon effects; none here yet, but /effect and the
-- protocol keep the flag).
-- (`paused`: the time stands still for now: an external effect its owner holds, Tough As Nails'
-- Thirst and Climate Clemency for a creative player; the client then doesn't count it down.)
export type Entry = { effect: number, amplifier: number, ticks: number, ambient: boolean, paused: boolean? }

-- How fire treats a player (server Players/Burning): no fire hurts (`immune`), burning set lasts
-- `factor` times longer, each burning hurt takes `bonus` more, and fire catches at once.
export type FireRules = { immune: boolean, factor: number, bonus: number, ignites: boolean }

local Effects = {}

-- A duration that never runs out (MobEffectInstance.INFINITE_DURATION).
Effects.INFINITE = -1
-- The highest amplifier (a byte in Minecraft's packets and /effect: 0..255).
Effects.MAX_AMPLIFIER = 255
Effects.COUNT = #EffectList
-- Ticks a second.
Effects.TICKS_PER_SECOND = 20
-- Mining Fatigue's speed by amplifier (Player.getDestroySpeed), the last for every higher one.
Effects.FATIGUE = table.freeze({ 0.3, 0.09, 0.0027, 8.1E-4 })
-- Instant Health heals 4 << amplifier, Instant Damage hurts 6 << amplifier (HealOrHarmMobEffect).
Effects.INSTANT_HEAL = 4
Effects.INSTANT_HARM = 6
-- Effects with this many ticks left or fewer flash on the HUD (MobEffectInstance.endsWithin(200)).
Effects.FLASH_TICKS = 200
-- Blindness closes the fog in to this many blocks (FogRenderer).
Effects.BLIND_DISTANCE = 5

assert(Effects.COUNT < 256, "Effect ids must fit a u8")

local CATEGORIES: { [string]: boolean } = { beneficial = true, harmful = true, neutral = true }
local VIEWS: { [string]: boolean } = { nightVision = true, blindness = true, nausea = true, glowing = true }
local INSTANTS: { [string]: boolean } = { heal = true, harm = true }

local list: { Effect } = {}
local byName: { [string]: number } = {}
local ids: { [string]: number } = {}

-- "JumpBoost" -> "Jump Boost".
local function spaced(name: string): string
	return (string.gsub(name, "(%l)(%u)", "%1 %2"))
end

for id, spec in EffectList do
	assert(ids[spec.name] == nil, `Two effects are named {spec.name}`)
	assert(CATEGORIES[spec.category], `Effect {spec.name} has an unknown category {spec.category}`)
	assert(spec.view == nil or VIEWS[spec.view], `Effect {spec.name} has an unknown view {spec.view}`)
	assert(spec.instant == nil or INSTANTS[spec.instant], `Effect {spec.name} has an unknown instant`)
	assert(string.match(spec.command, "^[a-z_]+$"), `Effect {spec.name}'s command id must be lower_snake`)
	assert(#spec.color == 3, `Effect {spec.name} needs a colour of three channels`)
	assert((spec.interval or 1) >= 1, `Effect {spec.name}'s interval must be at least 1`)
	local c = spec.color
	local record: Effect = {
		id = id,
		name = spec.name,
		displayName = spec.displayName or spaced(spec.name),
		command = spec.command,
		color = table.freeze(table.clone(spec.color)),
		colorValue = c[1] * 65536 + c[2] * 256 + c[3],
		category = spec.category,
		beneficial = spec.category == "beneficial",
		icon = spec.icon,
		speed = spec.speed or 0,
		mining = spec.mining or 0,
		fatigue = spec.fatigue == true,
		jump = spec.jump or 0,
		melee = spec.melee or 0,
		resistance = spec.resistance or 0,
		interval = spec.interval or 0,
		heal = spec.heal or 0,
		damage = spec.damage or 0,
		lethal = spec.lethal == true,
		instant = spec.instant,
		fireImmune = spec.fireImmune == true,
		burnFactor = spec.burnFactor or 1,
		burnBonus = spec.burnBonus or 0,
		ignites = spec.ignites == true,
		washOff = spec.washOff == true,
		view = spec.view,
		noSprint = spec.noSprint == true,
		external = spec.external == true,
	}
	list[id] = table.freeze(record)
	ids[spec.name] = id
	for _, key in { spec.name, spec.command, record.displayName, (string.gsub(spec.command, "_", "")) } do
		local lower = string.lower(key)
		assert(byName[lower] == nil or byName[lower] == id, `Effect name {key} is taken`)
		byName[lower] = id
	end
end

-- Effect ids by name: Effects.id.Speed.
Effects.id = table.freeze(ids)
Effects.list = table.freeze(list)

-- Is `id` an effect (1..COUNT, whole)?
function Effects.isValid(id: unknown): boolean
	return type(id) == "number" and id >= 1 and id <= Effects.COUNT and id == math.floor(id)
end

-- The effect with id `id` (nil: none).
function Effects.get(id: number): Effect?
	return if Effects.isValid(id) then list[id] else nil
end

--[[
	The effect `text` names (nil: none): its name ("JumpBoost"), display name ("Jump Boost") or
	/effect id ("jump_boost", "minecraft:jump_boost", "toughasnails:thirst"), in any case.
]]
function Effects.find(text: string): number?
	local lower = string.lower(text)
	local path = string.match(lower, "^[%w_]+:(.+)$")
	return byName[path or lower]
end

local ROMAN = { "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X" }

-- Level `level` (1 = I) as written after a name: roman numerals up to X, figures above.
function Effects.roman(level: number): string
	return ROMAN[level] or tostring(level)
end

--[[
	An effect's name with its level: "Speed", "Speed II" (Minecraft writes level I bare and the
	others with their numeral).
]]
function Effects.levelName(id: number, amplifier: number): string
	local effect = Effects.get(id)
	local name = if effect then effect.displayName else "Unknown"
	if amplifier >= 1 then
		return `{name} {Effects.roman(amplifier + 1)}`
	end
	return name
end

-- A duration as Minecraft writes it (StringUtil.formatTickDuration): "0:05", "3:00", "1:02:03";
-- "**:**" never ends.
function Effects.formatTicks(ticks: number): string
	if ticks == Effects.INFINITE or ticks == math.huge then
		return "**:**"
	end
	local seconds = math.max(0, math.floor(ticks / Effects.TICKS_PER_SECOND))
	local hours = seconds // 3600
	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, (seconds // 60) % 60, seconds % 60)
	end
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

--[[ Modifiers ]]

--[[
	The ground speed's multiplier with `levels` in force (see the header): 1 with none.
]]
function Effects.speedFactor(levels: Levels): number
	local factor = 1
	for id, amplifier in levels do
		local effect = list[id]
		if effect and effect.speed ~= 0 then
			factor *= 1 + effect.speed * (amplifier + 1)
		end
	end
	return math.max(0, factor)
end

-- The mining speed's multiplier with `levels` in force (Haste, Mining Fatigue): 1 with none.
function Effects.miningFactor(levels: Levels): number
	local factor = 1
	for id, amplifier in levels do
		local effect = list[id]
		if effect then
			if effect.mining ~= 0 then
				factor *= 1 + effect.mining * (amplifier + 1)
			end
			if effect.fatigue then
				factor *= Effects.FATIGUE[math.min(amplifier + 1, #Effects.FATIGUE)]
			end
		end
	end
	return factor
end

--[[
	Jump Boost with `levels` in force: the jump velocity added (blocks a tick) and the blocks of
	fall taken off before fall damage counts. 0, 0 with none.
]]
function Effects.jumpBoost(levels: Levels): (number, number)
	local velocity, fall = 0, 0
	for id, amplifier in levels do
		local effect = list[id]
		if effect and effect.jump ~= 0 then
			velocity += effect.jump * (amplifier + 1)
			fall += amplifier + 1
		end
	end
	return velocity, fall
end

-- A melee hit of `base` half hearts with `levels` in force (Strength, Weakness), never below 0.
function Effects.meleeDamage(base: number, levels: Levels): number
	local damage = base
	for id, amplifier in levels do
		local effect = list[id]
		if effect and effect.melee ~= 0 then
			damage += effect.melee * (amplifier + 1)
		end
	end
	return math.max(0, damage)
end

-- What gets through of a hurt of `amount` half hearts with `levels` in force (Resistance).
function Effects.incomingDamage(amount: number, levels: Levels): number
	local share = 1
	for id, amplifier in levels do
		local effect = list[id]
		if effect and effect.resistance ~= 0 then
			share -= effect.resistance * (amplifier + 1)
		end
	end
	return amount * math.max(0, share)
end

--[[
	How fire treats a player with `levels` in force (see FireRules), nil when no effect changes
	anything (the common case allocates nothing).
]]
function Effects.fireRules(levels: Levels): FireRules?
	local rules: FireRules? = nil
	for id in levels do
		local effect = list[id]
		if effect and (effect.fireImmune or effect.burnFactor ~= 1 or effect.burnBonus ~= 0 or effect.ignites) then
			local current: FireRules = rules or { immune = false, factor = 1, bonus = 0, ignites = false }
			current.immune = current.immune or effect.fireImmune
			current.factor = math.max(current.factor, effect.burnFactor)
			current.bonus += effect.burnBonus
			current.ignites = current.ignites or effect.ignites
			rules = current
		end
	end
	return rules
end

-- May the player start sprinting with `levels` in force (not while blind)?
function Effects.noSprint(levels: Levels): boolean
	for id in levels do
		local effect = list[id]
		if effect and effect.noSprint then
			return true
		end
	end
	return false
end

--[[ Ticking ]]

--[[
	Does effect `id` at `amplifier` act on a tick with `ticks` left (MobEffect.isDurationEffectTick;
	an infinite effect asks with the entity's age instead)? Interval effects every interval >>
	amplifier ticks (every tick once that is 0), instant ones on any tick they have.
]]
function Effects.isDurationTick(id: number, ticks: number, amplifier: number): boolean
	local effect = Effects.get(id)
	if effect == nil then
		return false
	end
	if effect.instant then
		return ticks >= 1
	end
	if effect.interval <= 0 then
		return false
	end
	local every = bit32.rshift(effect.interval, math.clamp(amplifier, 0, 31))
	return every <= 0 or ticks % every == 0
end

-- Half hearts an instant effect heals or hurts at `amplifier` (4 << amp, 6 << amp; 0 for others).
function Effects.instantAmount(id: number, amplifier: number): number
	local effect = Effects.get(id)
	if effect == nil or effect.instant == nil then
		return 0
	end
	local base = if effect.instant == "heal" then Effects.INSTANT_HEAL else Effects.INSTANT_HARM
	-- (Java's int shift: wraps past 31 bits; amplifiers are bytes, so cap it sensibly.)
	return bit32.lshift(base, math.clamp(amplifier, 0, 24))
end

--[[ The client ]]

--[[
	A potion's tooltip lines (PotionUtils.addPotionTooltip): each effect's name and level, with its
	time in brackets unless it is instant ("Speed II (1:30)", "Instant Health"), and whether it is
	harmful (Minecraft writes those red, the rest blue).
]]
function Effects.tooltip(
	given: { { effect: number, ticks: number, amplifier: number } }
): { { text: string, harmful: boolean } }
	local lines = {}
	for _, entry in given do
		local effect = Effects.get(entry.effect)
		if effect then
			local text = Effects.levelName(entry.effect, entry.amplifier)
			if effect.instant == nil then
				text ..= ` ({Effects.formatTicks(entry.ticks)})`
			end
			table.insert(lines, { text = text, harmful = effect.category == "harmful" })
		end
	end
	return lines
end

-- Ticks left of an entry the server sent with `ticks` left, `elapsed` ticks ago (INFINITE stays,
-- and a `paused` one).
function Effects.remaining(ticks: number, elapsed: number, paused: boolean?): number
	if ticks == Effects.INFINITE or paused then
		return ticks
	end
	return math.max(0, ticks - math.max(0, elapsed))
end

-- The levels in force among `entries` (into `into`, cleared first, or a new table).
function Effects.levelsOf(entries: { Entry }, into: Levels?): Levels
	local levels = into or {}
	table.clear(levels)
	for _, entry in entries do
		if entry.ticks ~= 0 then
			levels[entry.effect] = entry.amplifier
		end
	end
	return levels
end

-- Night Vision's brightness (0..1) with `ticks` left: full, then flickering over the last 10 s.
function Effects.nightVisionScale(ticks: number): number
	if ticks == Effects.INFINITE or ticks > Effects.FLASH_TICKS then
		return 1
	end
	return 0.7 + math.sin(ticks * math.pi * 0.2) * 0.3
end

-- Nausea's intensity rises 0.006 a tick while it has more than 3 s left and falls 0.01 a tick
-- otherwise (LocalPlayer.handleConfusionTransitionEffect).
Effects.NAUSEA_RISE = 0.006
Effects.NAUSEA_FALL = 0.01
Effects.NAUSEA_HOLD = 60

--[[
	Nausea's intensity (0..1) after `ticks` (may be fractional: a frame) from `intensity`, with
	`left` ticks of Nausea left (0: none) (see NAUSEA_RISE).
]]
function Effects.nauseaIntensity(intensity: number, left: number, ticks: number): number
	if left == Effects.INFINITE or left > Effects.NAUSEA_HOLD then
		return math.min(1, intensity + Effects.NAUSEA_RISE * ticks)
	end
	return math.max(0, intensity - Effects.NAUSEA_FALL * ticks)
end

--[[
	Nausea's wobble at `intensity` and time `seconds` (Minecraft stretches and turns the whole view;
	a Roblox camera can only roll and zoom): the camera's roll as a share of the full roll (-1..1)
	and the field of view's sway as a share of the full sway (-1..1), two slow waves out of step.
]]
function Effects.nauseaSway(intensity: number, seconds: number): (number, number)
	if intensity <= 0 then
		return 0, 0
	end
	return math.sin(seconds * math.pi * 0.9) * intensity, math.sin(seconds * math.pi * 0.62 + 1.3) * intensity
end

--[[
	Blindness' fog (blocks from the eye: start, end) with `ticks` left and the view distance `far`
	(blocks): 5 blocks, opening back out to `far` over the last second.
]]
function Effects.blindnessFog(ticks: number, far: number): (number, number)
	local finish = if ticks == Effects.INFINITE
		then Effects.BLIND_DISTANCE
		else far + (Effects.BLIND_DISTANCE - far) * math.min(1, ticks / 20)
	return finish * 0.25, finish
end

--[[
	The HUD icon's opacity (0..1) of an effect with `ticks` left (Gui.renderEffects): 1, but in the
	last 10 s it fades and blinks out, faster at the end. Ambient effects never flash.
]]
function Effects.iconAlpha(ticks: number, ambient: boolean?): number
	if ambient or ticks == Effects.INFINITE or ticks > Effects.FLASH_TICKS then
		return 1
	end
	local seconds = 10 - ticks // 20
	return math.clamp(ticks / 10 / 5 * 0.5, 0, 0.5)
		+ math.cos(ticks * math.pi / 5) * math.clamp(seconds / 10 * 0.25, 0, 0.25)
end

--[[
	The order the HUD draws `entries` in (Gui.renderEffects: Minecraft's MobEffectInstance order
	reversed: ambient first, then infinite, then the longest, then the higher colour), split into
	the beneficial row (top) and the rest (harmful and neutral, the row below). Effects with no
	ticks left or unknown are left out.
]]
function Effects.hudOrder(entries: { Entry }): ({ Entry }, { Entry })
	local sorted = table.clone(entries)
	local function key(entry: Entry): (number, number, number)
		local infinite = if entry.ticks == Effects.INFINITE then 1 else 0
		local ticks = if entry.ticks == Effects.INFINITE then math.huge else entry.ticks
		return (if entry.ambient then 1 else 0), infinite, ticks
	end
	table.sort(sorted, function(a: Entry, b: Entry): boolean
		local aAmbient, aInfinite, aTicks = key(a)
		local bAmbient, bInfinite, bTicks = key(b)
		if aAmbient ~= bAmbient then
			return aAmbient > bAmbient
		elseif aInfinite ~= bInfinite then
			return aInfinite > bInfinite
		elseif aTicks ~= bTicks then
			return aTicks > bTicks
		end
		local ca = if list[a.effect] then list[a.effect].colorValue else 0
		local cb = if list[b.effect] then list[b.effect].colorValue else 0
		if ca ~= cb then
			return ca > cb
		end
		return a.effect < b.effect
	end)
	local good, rest = {}, {}
	for _, entry in sorted do
		local effect = list[entry.effect]
		if effect and entry.ticks ~= 0 and effect.instant == nil then
			table.insert(if effect.beneficial then good else rest, entry)
		end
	end
	return good, rest
end

return Effects
