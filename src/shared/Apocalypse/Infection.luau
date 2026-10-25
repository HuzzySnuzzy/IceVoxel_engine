--!strict
--[[
	A zombie bite's infection, pure (numbers in, numbers out, so the tests play it out): server
	Apocalypse/Infection keeps each player's progress and plays these rules out, and the status
	effect list shows it (Shared/Effects' Infection: an external effect whose amplifier is the
	stage). `s` is Config.Apocalypse.Infection.

	  Progress  `p` counts the infection's ticks from 1 at the bite (0: healthy; this is what a
	            save keeps). It grows a tick at a time while the player's game mode can be hurt
	            (creative and spectator hold it: the effect's `paused`). Lethal is StageTicks x
	            Stages (48000: two in-game days, 40 real minutes): the tick that takes p past it
	            is the player's death, so an untreated bite kills exactly LETHAL ticks after it,
	            never before (`ticksLeft` is the effect's countdown: LETHAL + 1 - p).
	  Stages    StageTicks (12000) each, shown as the effect's amplifier (`amplifier`: stage - 1,
	            "Infection III" at stage III). The symptoms are status effects given or refreshed
	            every SYMPTOM_EVERY (20) ticks for SYMPTOM_TICKS (60), so they end soon after a
	            cure (and are taken off at once by it):
	              I    nothing but the icon;
	              II   Weakness; Tough As Nails' thirst drains THIRST_EXHAUSTION (0.005) more a
	                   tick while thirst is on;
	              III  Weakness, Slowness, and Nausea for NAUSEA_TICKS (200) every NAUSEA_EVERY
	                   (1200) ticks; no natural regeneration (`blocksRegeneration`: neither
	                   thirst's nor Roblox's Health script; effects, foods and medicine still
	                   heal);
	              IV   Weakness, Slowness II, and a half heart of magic damage every
	                   DamageInterval (100) ticks that never takes the last half heart (not lethal).
	  Bites     a bite's chance is the zombie kind's `infect` less the armor's shield
	            (`chance`: each armor point shields ArmorShield, 3.75%, of it, at most
	            ArmorShieldMax, 75%: a full diamond set's 20 points). At most one roll every
	            RollInterval ticks a player (`mayRoll`: a horde's hits don't stack rolls). An
	            infecting bite starts a healthy player at p = 1, and takes an infected one
	            BiteAdvance (2400) ticks on, never past LETHAL (`bite`). `rollBite` is the whole
	            rule for one landed bite.
	  Immune    creative and spectator players (GameMode.invulnerable) never catch it, and an
	            infection they carry stands still (`affects`).
	  Cures     Antibiotics cure it at any stage, with Weakness for AFTERMATH_TICKS (1200) after
	            a cure from AFTERMATH_STAGE (III) on (Items/Foods' `aftermath`, given as the
	            Antibiotics finish); a Herbal Poultice takes it back a stage (`setBack`: p -
	            StageTicks, at least 1: never a cure, a stage I infection restarts its stage).
	            Death clears it.
	  Dormant   with `Enabled` false (the server passes a copy with it false while
	            Config.Apocalypse.Enabled is off) nothing is ever caught, and an infection a save
	            brought back stands still and does nothing (`dormant`): no countdown or level on
	            the effect list, no symptoms, no thirst drain, no hold on regeneration, no
	            damage, no death. It is kept as it is, so turning the switch back on loses
	            nothing.
]]

local GameMode = require(script.Parent.Parent.GameMode)

local Infection = {}

-- What the rules read of Config.Apocalypse.Infection.
export type Settings = {
	Enabled: boolean?,
	StageTicks: number,
	Stages: number,
	BiteAdvance: number,
	RollInterval: number,
	ArmorShield: number,
	ArmorShieldMax: number,
	DamageInterval: number,
}

-- What one tick of an infection does (`tick`'s `out`).
export type Step = {
	-- The symptoms are due again (refresh `symptoms(stage)`; never at stage I, which has none).
	refresh: boolean,
	-- Nausea is due (stage III's spell).
	nausea: boolean,
	-- A half heart of magic damage is due (stage IV; never the last one).
	hurt: boolean,
	-- The infection kills now.
	dies: boolean,
	-- The stage after the tick (0: healthy).
	stage: number,
}

-- A symptom: a Shared/Effects name and its amplifier.
export type Symptom = { name: string, amplifier: number }

-- Symptoms are given every SYMPTOM_EVERY ticks for SYMPTOM_TICKS.
Infection.SYMPTOM_EVERY = 20
Infection.SYMPTOM_TICKS = 60
-- Stage III's Nausea: NAUSEA_TICKS long, every NAUSEA_EVERY ticks.
Infection.NAUSEA_TICKS = 200
Infection.NAUSEA_EVERY = 1200
-- Stage II on: extra exhaustion of Tough As Nails' thirst a tick.
Infection.THIRST_EXHAUSTION = 0.005
-- Weakness after a cure from this stage on, for this many ticks (the Antibiotics' `aftermath`,
-- their entry's in the Apocalypse pack's items/supplies; Items/Foods).
Infection.AFTERMATH_STAGE = 3
Infection.AFTERMATH_TICKS = 1200
-- From this stage natural regeneration stops.
Infection.NO_REGENERATION = 3
-- The stage whose magic damage hurts (the last).
Infection.HURTING = 4

-- The symptoms of each stage (see the header).
Infection.SYMPTOMS = table.freeze({
	table.freeze({}),
	table.freeze({ table.freeze({ name = "Weakness", amplifier = 0 }) }),
	table.freeze({
		table.freeze({ name = "Weakness", amplifier = 0 }),
		table.freeze({ name = "Slowness", amplifier = 0 }),
	}),
	table.freeze({
		table.freeze({ name = "Weakness", amplifier = 0 }),
		table.freeze({ name = "Slowness", amplifier = 1 }),
	}),
} :: { { Symptom } })

local NONE: { Symptom } = table.freeze({})

-- Is the infection switched off (`Enabled` false: see the header)?
function Infection.dormant(s: Settings): boolean
	return s.Enabled == false
end

-- Ticks from the bite to death (StageTicks x Stages).
function Infection.lethal(s: Settings): number
	return s.StageTicks * s.Stages
end

-- The stage of progress `p` (0: healthy, else 1..Stages).
function Infection.stage(p: number, s: Settings): number
	if not (p > 0) then
		return 0
	end
	return math.min(s.Stages, (p - 1) // s.StageTicks + 1)
end

-- The amplifier the effect shows (stage - 1; 0 when healthy or dormant).
function Infection.amplifier(p: number, s: Settings): number
	if Infection.dormant(s) then
		return 0
	end
	return math.max(0, Infection.stage(p, s) - 1)
end

-- The effect's ticks left: the countdown to death (0: healthy or dormant; at least 1 while
-- infected).
function Infection.ticksLeft(p: number, s: Settings): number
	if not (p > 0) or Infection.dormant(s) then
		return 0
	end
	return math.max(1, Infection.lethal(s) + 1 - p)
end

-- The symptoms of `stage` (none for 0).
function Infection.symptoms(stage: number): { Symptom }
	return Infection.SYMPTOMS[stage] or NONE
end

-- Does an infection at `p` stop natural regeneration (stage III on; never dormant)?
function Infection.blocksRegeneration(p: number, s: Settings): boolean
	return not Infection.dormant(s) and Infection.stage(p, s) >= Infection.NO_REGENERATION
end

-- Does an infection at `p` drain thirst (stage II on; never dormant)?
function Infection.drainsThirst(p: number, s: Settings): boolean
	return not Infection.dormant(s) and Infection.stage(p, s) >= 2
end

--[[
	The chance (0..1) that a landed hit of a kind with `infect` infects a player wearing
	`armorPoints` (see the header).
]]
function Infection.chance(infect: number, armorPoints: number, s: Settings): number
	local shield = math.min(s.ArmorShieldMax, math.max(0, armorPoints) * s.ArmorShield)
	return math.clamp(infect, 0, 1) * (1 - shield)
end

-- May a player whose last roll was at tick `last` (nil: never) roll again at tick `now`?
function Infection.mayRoll(last: number?, now: number, s: Settings): boolean
	return last == nil or now - last >= s.RollInterval
end

-- Does the infection touch a player in game `mode` (catch, grow, hurt)? Not creative or spectator.
function Infection.affects(mode: string): boolean
	return not GameMode.invulnerable(mode)
end

-- Progress after an infecting bite (see the header).
function Infection.bite(p: number, s: Settings): number
	if Infection.dormant(s) then
		return p
	end
	if not (p > 0) then
		return 1
	end
	return math.min(Infection.lethal(s), p + s.BiteAdvance)
end

--[[
	One landed bite of a kind with `infect` on a player in game `mode` wearing `armorPoints`, at
	progress `p`, whose last roll was at tick `last` (nil: never), now at tick `now`, rolled with
	`random()` (0..1): the progress after it, and the tick of this roll (nil: no roll was made, the
	last one stands).
]]
function Infection.rollBite(
	p: number,
	last: number?,
	now: number,
	mode: string,
	infect: number,
	armorPoints: number,
	random: () -> number,
	s: Settings
): (number, number?)
	if
		Infection.dormant(s)
		or not Infection.affects(mode)
		or not (infect > 0)
		or not Infection.mayRoll(last, now, s)
	then
		return p, nil
	end
	if random() >= Infection.chance(infect, armorPoints, s) then
		return p, now
	end
	return Infection.bite(p, s), now
end

-- A saved progress `p` checked (0: healthy, else 1..LETHAL; damage reads healthy).
function Infection.fromSaved(p: unknown, s: Settings): number
	if type(p) ~= "number" or p ~= p or p <= 0 then
		return 0
	end
	return math.clamp(math.floor(p), 1, Infection.lethal(s))
end

-- Progress after a Herbal Poultice (back a stage, never a cure; healthy stays healthy).
function Infection.setBack(p: number, s: Settings): number
	if not (p > 0) then
		return 0
	end
	return math.max(1, p - s.StageTicks)
end

-- A fresh Step for `tick`.
function Infection.newStep(): Step
	return { refresh = false, nausea = false, hurt = false, dies = false, stage = 0 }
end

--[[
	One tick of an infection at progress `p` (see the header): the new progress, with what the
	tick does in `out`. A healthy player (p 0) stays healthy; one past LETHAL dies; a dormant one
	stands still and nothing happens.
]]
function Infection.tick(p: number, s: Settings, out: Step): number
	out.refresh, out.nausea, out.hurt, out.dies = false, false, false, false
	if not (p > 0) then
		out.stage = 0
		return 0
	end
	if Infection.dormant(s) then
		out.stage = Infection.stage(p, s)
		return p
	end
	local nextP = p + 1
	local lethal = Infection.lethal(s)
	if nextP > lethal then
		out.stage = s.Stages
		out.dies = true
		return nextP
	end
	local stage = Infection.stage(nextP, s)
	out.stage = stage
	out.refresh = #Infection.symptoms(stage) > 0 and nextP % Infection.SYMPTOM_EVERY == 0
	out.nausea = stage == 3 and nextP % Infection.NAUSEA_EVERY == 0
	out.hurt = stage >= Infection.HURTING and nextP % s.DamageInterval == 0
	return nextP
end

return Infection
