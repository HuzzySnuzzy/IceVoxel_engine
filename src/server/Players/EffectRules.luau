--!strict
--[[
	A player's status effects on the server, pure (no Roblox APIs, so the tests run it): Minecraft
	1.20.1's MobEffectInstance (update, tick, the hidden effect), LivingEntity.tickEffects and the
	status effects the fluids give (Shared/Fluids `effects`). Players/Effects keeps one State per
	character and plays these out; Players/Characters ticks them with lava and burning.

	  Giving    `give(state, effect, ticks, amplifier, ambient)`: a new effect is added; one already
	            running is updated as MobEffectInstance.update does:
	              * a higher amplifier wins, with its duration; the old one, when it would have
	                lasted longer, is kept hidden underneath (and comes back when the stronger
	                one ends: Speed II for 10 s over Speed I for 3 minutes leaves Speed I for the
	                rest);
	              * the same amplifier for longer refreshes the duration (never shortens it);
	              * a lower amplifier for longer goes under it as the hidden effect (or updates
	                the hidden one);
	              * ambient becomes non-ambient when a non-ambient one comes.
	            Returns whether anything changed. Ticks are whole and at least 1, or
	            Effects.INFINITE; amplifiers 0..255. Instant effects (Instant Health, Instant
	            Damage) are given like any other and act on the next tick's isDurationEffectTick:
	            a potion gives them 1 tick (once), /effect seconds as ticks (every tick, as
	            Minecraft's EffectCommands do).
	  Ticking   `tick(state, mode, health, maxHealth)`, 20 a second: each effect with time left
	            acts on its isDurationEffectTick (an infinite one asks with the player's age):
	              Regeneration  heals `heal` (1) while below full health, every 50 >> amp ticks;
	              Poison        hurts `damage` (1) while the health is above 1, every 25 >> amp;
	              Wither        hurts 1 every 40 >> amp, and may kill;
	              Instant Health / Damage  heal 4 << amp / hurt 6 << amp;
	            then counts down a tick (its hidden effects too); one at 0 gives way to its hidden
	            effect, or is removed (LivingEntity.tickEffects). Returns the half hearts it hurts
	            (magic: through armor, under the hurt cooldown, Resistance applies: Players/
	            Characters) and heals. Creative and spectator players (GameMode.invulnerable) are
	            never hurt, but their effects run and count down, as Minecraft's.
	  Fluids    `touchFluids(state, touching, eyes, mode)`, every tick with Players/Burning's masks
	            (the fluids the standing box touches and those over the eyes): every fluid's
	            `effects` (FluidList): "in" while touching it (once touching `after` ticks
	            unbroken), refreshed every tick, "head" while the eyes are in it, "left" the tick
	            it stops touching it. An effect that acts on an interval (fuel's Poison: every 25
	            ticks) is refreshed only once it ran down that interval, which keeps it acting on
	            its interval (refreshed every tick, its time left would always be the full duration,
	            an acting tick: Poison every tick). A fluid that `extinguishes` (water) then washes
	            off every effect that `washOff` (Oil Coated, Fuel Soaked), after the giving, so
	            water and fuel together leave nothing to wash. Spectators touch nothing.
	  External  effects kept elsewhere (Tough As Nails': Effects `external`) are set every tick
	            from their owners (`setExternal`), only to be shown; one its owner holds for now
	            (Thirst and Climate Clemency stand still for a creative player) goes out
	            `paused`, and the client keeps its time as sent.
	  Sending   `needsSync` says whether the client's view (the entries last sent, `markSent`,
	            counted down since) is off: an effect came, went before its time, changed its
	            amplifier or ambience, or its time left differs from the countdown by more than
	            SYNC_TOLERANCE ticks (a refreshed effect: in a fluid that is about once a second).
	            The client counts down itself and keeps an effect at 0 until it is told it went,
	            as Minecraft's client does, so an effect refreshed every tick never flickers.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Effects = require(Shared.Effects)
local Fluids = require(Shared.Fluids)
local GameMode = require(Shared.GameMode)

-- One running effect (MobEffectInstance): ticks left (Effects.INFINITE: never ends) and the
-- weaker but longer effect hidden under it.
export type Instance = {
	effect: number,
	amplifier: number,
	ticks: number,
	ambient: boolean,
	hidden: Instance?,
}

-- What the client was last told of an effect, and the player's age then.
type Sent = { amplifier: number, ticks: number, ambient: boolean, paused: boolean, at: number }

export type State = {
	-- The running effects by id, and their levels (Effects.Levels: what the modifiers read), kept
	-- in step.
	active: { [number]: Instance },
	levels: Effects.Levels,
	-- External effects (Effects `external`) and their ticks left (0 or absent: none), and those
	-- whose owner holds them for now (not counting down).
	external: { [number]: number },
	paused: { [number]: boolean },
	-- Per fluid id: ticks of unbroken contact; the fluids touched last tick (a mask).
	contact: { [number]: number },
	touched: number,
	-- Ticks lived (Minecraft's tickCount: infinite effects act by it).
	age: number,
	-- What the client was last told (effect id -> Sent).
	sent: { [number]: Sent },
}

local EffectRules = {}

-- Ticks the client's countdown may be off before it is told again.
EffectRules.SYNC_TOLERANCE = 20

local INFINITE = Effects.INFINITE
local COUNT = Effects.COUNT

-- Fluids that give effects, and the mask of those that wash effects off (water).
local GIVING: { Fluids.Fluid } = {}
local WASHING = 0
for id, fluid in Fluids.list do
	if #fluid.effects > 0 then
		table.insert(GIVING, fluid)
	end
	if fluid.extinguishes then
		WASHING = bit32.bor(WASHING, bit32.lshift(1, id))
	end
end
-- Effects that wash off.
local WASH_OFF: { number } = {}
for id, effect in Effects.list do
	if effect.washOff then
		table.insert(WASH_OFF, id)
	end
end
-- Is there a fluid with "head" effects (Players/Characters then looks at the eyes)?
EffectRules.HEAD_EFFECTS = false
for _, fluid in GIVING do
	for _, given in fluid.effects do
		if given.when == "head" then
			EffectRules.HEAD_EFFECTS = true
		end
	end
end

local function touches(mask: number, fluid: number): boolean
	return bit32.btest(mask, bit32.lshift(1, fluid))
end

function EffectRules.new(): State
	return { active = {}, levels = {}, external = {}, paused = {}, contact = {}, touched = 0, age = 0, sent = {} }
end

-- (The levels follow the running effects: the instant ones never count.)
local function relevel(state: State)
	local levels = state.levels
	table.clear(levels)
	for id, instance in state.active do
		levels[id] = instance.amplifier
	end
end

local function infinite(instance: Instance): boolean
	return instance.ticks == INFINITE
end

-- MobEffectInstance.isShorterDurationThan.
local function shorter(a: Instance, b: Instance): boolean
	return not infinite(a) and (a.ticks < b.ticks or infinite(b))
end

local function copy(instance: Instance): Instance
	return {
		effect = instance.effect,
		amplifier = instance.amplifier,
		ticks = instance.ticks,
		ambient = instance.ambient,
		hidden = instance.hidden,
	}
end

-- MobEffectInstance.update: `current` takes what `other` brings (see the header).
local function update(current: Instance, other: Instance): boolean
	local changed = false
	if other.amplifier > current.amplifier then
		if shorter(other, current) then
			-- (The weaker, longer one goes under, keeping what was under it.)
			local old = current.hidden
			local hidden = copy(current)
			hidden.hidden = old
			current.hidden = hidden
		end
		current.amplifier = other.amplifier
		current.ticks = other.ticks
		changed = true
	elseif shorter(current, other) then
		if other.amplifier == current.amplifier then
			current.ticks = other.ticks
			changed = true
		elseif current.hidden == nil then
			current.hidden = copy(other)
		else
			update(current.hidden :: Instance, other)
		end
	end
	if (not other.ambient and current.ambient) or changed then
		changed = changed or current.ambient ~= other.ambient
		current.ambient = other.ambient
	end
	return changed
end

-- Are `ticks` a duration an effect may be given (whole and at least 1, or INFINITE)?
local function validTicks(ticks: number): boolean
	return ticks == INFINITE or (ticks >= 1 and ticks == math.floor(ticks) and ticks < 2 ^ 31)
end

--[[
	Gives effect `effect` (an Effects id) for `ticks` at `amplifier` (default 0) to the state (see
	the header). Returns whether anything changed; nonsense (unknown effects, bad numbers, an
	external effect) changes nothing.
]]
function EffectRules.give(state: State, effect: number, ticks: number, amplifier: number?, ambient: boolean?): boolean
	local def = Effects.get(effect)
	local level = amplifier or 0
	if
		def == nil
		or def.external
		or not validTicks(ticks)
		or not (level >= 0 and level <= Effects.MAX_AMPLIFIER and level == math.floor(level))
	then
		return false
	end
	local other: Instance =
		{ effect = effect, amplifier = level, ticks = ticks, ambient = ambient == true, hidden = nil }
	local current = state.active[effect]
	if current == nil then
		state.active[effect] = other
		state.levels[effect] = level
		return true
	end
	local changed = update(current, other)
	if changed then
		state.levels[effect] = current.amplifier
	end
	return changed
end

-- Removes effect `effect` (and what was hidden under it). Returns whether it was there.
function EffectRules.remove(state: State, effect: number): boolean
	if state.active[effect] == nil then
		return false
	end
	state.active[effect] = nil
	state.levels[effect] = nil
	return true
end

-- Removes every effect (not the external ones). Returns how many there were.
function EffectRules.clear(state: State): number
	local count = 0
	for _ in state.active do
		count += 1
	end
	table.clear(state.active)
	table.clear(state.levels)
	return count
end

-- The running effect `effect` (nil: none).
function EffectRules.get(state: State, effect: number): Instance?
	return state.active[effect]
end

-- The amplifier of effect `effect` (nil: not running).
function EffectRules.amplifier(state: State, effect: number): number?
	return state.levels[effect]
end

-- Is effect `effect` running?
function EffectRules.has(state: State, effect: number): boolean
	return state.levels[effect] ~= nil
end

-- The levels in force (read only: Effects' modifiers read it).
function EffectRules.levels(state: State): Effects.Levels
	return state.levels
end

-- Sets external effect `effect` to `ticks` left (0: none), as its owner keeps it; `paused` while
-- the owner holds it (doesn't count it down: Tough As Nails' Thirst and Climate Clemency for a
-- creative player), so the client stops its countdown too.
function EffectRules.setExternal(state: State, effect: number, ticks: number, paused: boolean?)
	if ticks > 0 or ticks == INFINITE then
		state.external[effect] = ticks
		if paused then
			state.paused[effect] = true
		else
			state.paused[effect] = nil
		end
	else
		state.external[effect] = nil
		state.paused[effect] = nil
	end
end

-- Counts an effect and the ones hidden under it down a tick (MobEffectInstance.tickDownDuration).
local function tickDown(instance: Instance)
	local hidden = instance.hidden
	if hidden then
		tickDown(hidden)
	end
	if not infinite(instance) and instance.ticks > 0 then
		instance.ticks -= 1
	end
end

--[[
	One tick of a player in game `mode` with `health` half hearts of `maxHealth` (see the header).
	Returns the half hearts the effects hurt and heal this tick.
]]
function EffectRules.tick(state: State, mode: string, health: number, maxHealth: number): (number, number)
	state.age += 1
	local active = state.active
	local damage, heal = 0, 0
	local hurts = not GameMode.invulnerable(mode)
	local current = health
	local changed = false
	-- (In id order, so the same effects always act in the same order.)
	for id = 1, COUNT do
		local instance = active[id]
		if instance == nil then
			continue
		end
		local amplifier = instance.amplifier
		if infinite(instance) or instance.ticks > 0 then
			local at = if infinite(instance) then state.age else instance.ticks
			if Effects.isDurationTick(id, at, amplifier) then
				local effect = Effects.list[id]
				if effect.instant == "heal" then
					local amount = Effects.instantAmount(id, amplifier)
					heal += amount
					current += amount
				elseif effect.instant == "harm" then
					if hurts then
						local amount = Effects.instantAmount(id, amplifier)
						damage += amount
						current -= amount
					end
				else
					if effect.heal > 0 and current < maxHealth then
						heal += effect.heal
						current += effect.heal
					end
					if effect.damage > 0 and hurts and (effect.lethal or current > 1) then
						damage += effect.damage
						current -= effect.damage
					end
				end
			end
			tickDown(instance)
			if instance.ticks == 0 and instance.hidden then
				-- (MobEffectInstance.tick: the hidden effect takes over.)
				local hidden = instance.hidden :: Instance
				instance.amplifier = hidden.amplifier
				instance.ticks = hidden.ticks
				instance.ambient = hidden.ambient
				instance.hidden = hidden.hidden
				changed = true
			end
		end
		if not infinite(instance) and instance.ticks <= 0 then
			active[id] = nil
			changed = true
		end
	end
	if changed then
		relevel(state)
	end
	return damage, heal
end

--[[
	Is a fluid's effect due to be given again while it is still running? Every tick, except an
	effect that acts on an interval (Poison: every 25 ticks at amplifier 0) running at the given
	amplifier: only once it has run down a whole interval. Its isDurationEffectTick asks its ticks
	left, so put back to its full duration every tick it would act every tick (fuel's Poison I
	every tick, not every 25); this way it acts on its own interval, given back each time it acts.
]]
local function giveDue(state: State, given: Fluids.FluidEffect): boolean
	local current = state.active[given.effect]
	if current == nil or current.amplifier ~= given.amplifier or infinite(current) then
		return true
	end
	local effect = Effects.list[given.effect]
	local every = if effect.instant == nil and effect.interval > 0
		then bit32.rshift(effect.interval, math.clamp(given.amplifier, 0, 31))
		else 0
	return every <= 1 or current.ticks <= given.ticks - every
end

--[[
	One tick of the fluids' effects (see the header): `touching` the fluids the body touches and
	`eyes` those over the eyes (Players/Burning masks, a bit per Shared/Fluids id), in game `mode`.
	`fluids` (default: every fluid that gives effects) is for the tests.
]]
function EffectRules.touchFluids(state: State, touching: number, eyes: number, mode: string, fluids: { Fluids.Fluid }?)
	if GameMode.isSpectator(mode) then
		table.clear(state.contact)
		state.touched = 0
		return
	end
	local contact = state.contact
	local before = state.touched
	for _, fluid in fluids or GIVING do
		local id = fluid.id
		local inside = touches(touching, id)
		local ticks = if inside then (contact[id] or 0) + 1 else 0
		if ticks > 0 then
			contact[id] = ticks
		else
			contact[id] = nil
		end
		for _, given in fluid.effects do
			local when = given.when
			local due = if when == "in"
				then inside and ticks >= given.after
				elseif when == "head" then touches(eyes, id) and ticks >= given.after
				else not inside and touches(before, id)
			if due and giveDue(state, given) then
				EffectRules.give(state, given.effect, given.ticks, given.amplifier)
			end
		end
	end
	if bit32.band(touching, WASHING) ~= 0 then
		for _, effect in WASH_OFF do
			EffectRules.remove(state, effect)
		end
	end
	state.touched = touching
end

--[[ Sending ]]

-- The effects the client shows: the running ones (not instant ones) and the external ones.
function EffectRules.entries(state: State): { Effects.Entry }
	local entries: { Effects.Entry } = {}
	for id = 1, COUNT do
		local instance = state.active[id]
		if instance and Effects.list[id].instant == nil then
			table.insert(entries, {
				effect = id,
				amplifier = instance.amplifier,
				ticks = instance.ticks,
				ambient = instance.ambient,
			})
		end
		local external = state.external[id]
		if external then
			table.insert(
				entries,
				{ effect = id, amplifier = 0, ticks = external, ambient = false, paused = state.paused[id] == true }
			)
		end
	end
	return entries
end

-- What the client counts `sent` down to by now (below 0: it has sat at 0 that long; a paused
-- one stays).
local function predicted(state: State, sent: Sent): number
	if sent.ticks == INFINITE or sent.paused then
		return sent.ticks
	end
	return sent.ticks - (state.age - sent.at)
end

-- Is the client's countdown of one shown effect off (see the header)?
local function off(
	state: State,
	sent: Sent?,
	amplifier: number,
	ticks: number,
	ambient: boolean,
	paused: boolean
): boolean
	if sent == nil or sent.amplifier ~= amplifier or sent.ambient ~= ambient or sent.paused ~= paused then
		return true
	end
	local guess = predicted(state, sent)
	if (guess == INFINITE) ~= (ticks == INFINITE) then
		return true
	end
	return ticks ~= INFINITE and math.abs(ticks - guess) > EffectRules.SYNC_TOLERANCE
end

-- Does the client need the effects again (see the header)?
function EffectRules.needsSync(state: State): boolean
	local sent = state.sent
	for id = 1, COUNT do
		local instance = state.active[id]
		local shown = instance ~= nil and Effects.list[id].instant == nil
		local external = state.external[id]
		local entry = sent[id]
		if shown then
			local i = instance :: Instance
			if off(state, entry, i.amplifier, i.ticks, i.ambient, false) then
				return true
			end
		elseif external then
			if off(state, entry, 0, external, false, state.paused[id] == true) then
				return true
			end
		elseif entry then
			-- (Gone: always say so, the client keeps it at 0 until told.)
			return true
		end
	end
	return false
end

-- Remembers `entries` (EffectRules.entries) as what the client was just told.
function EffectRules.markSent(state: State, entries: { Effects.Entry })
	local sent = state.sent
	table.clear(sent)
	for _, entry in entries do
		sent[entry.effect] = {
			amplifier = entry.amplifier,
			ticks = entry.ticks,
			ambient = entry.ambient,
			paused = entry.paused == true,
			at = state.age,
		}
	end
end

return EffectRules
