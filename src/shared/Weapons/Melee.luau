--!strict
--[[
	The melee rework in the manner of DayZ, pure (server Mobs/MobWorld and Mobs/Mobs, client
	Interaction/MeleeInput): light and heavy attacks, guarding, finishers. The inventory and melee
	builder owns the rules; this is FOUNDATION's stub, which keeps today's melee (every attack a
	light one, no guard, no finisher).

	  spec         the weapon's (Weapons.melee: Weapons/WeaponList `melee`), nil for anything else
	  heavyDamage  a heavy attack's base damage (half hearts, before the attack strength and the
	               status effects): the weapon's `heavy`, else `base` (the light attack's)
	  knockback    a hit's knockback: a heavy one's HeavyKnockback (Config.Weapons.Melee), else
	               Shared/Entities/Combat.KNOCKBACK
	  exhaustion   how many times a landed hit costs Minecraft's attack exhaustion: a heavy one
	               HeavyExhaustion, else 1
	  guardShare   the share (0..1) of a zombie's hit a guarding player blocks: the weapon's
	               `guard` when the zombie is within the front cone (horizontal look (lookX, lookZ)
	               against the direction to the zombie (dx, dz), dot at least GuardCone), else 0
	  finisher     does a hit kill outright: a weapon with `finisher` on a zombie that is not
	               aware (no target, no hunt) from behind (`behindDot`: the zombie's facing against
	               the direction to the attacker, at most -FinisherCone), whose kind's `health` is
	               at most FinisherMaxHealth? (Mobs/MobWorld asks only for zombie kinds.)
	With Config.Weapons.Melee.Enabled false, all of it is off (light attacks as today).
]]

local Combat = require(script.Parent.Parent.Entities.Combat)
local Config = require(script.Parent.Parent.Config)
local Weapons = require(script.Parent)

local Melee = {}

-- The weapon's melee numbers, nil for anything that is no listed melee weapon.
function Melee.spec(item: number?): Weapons.MeleeSpec?
	if not Config.Weapons.Melee.Enabled then
		return nil
	end
	return Weapons.melee(item)
end

-- A heavy attack's base damage with `item` whose light one is `base` (see the header).
function Melee.heavyDamage(_item: number?, base: number): number
	return base
end

-- A hit's knockback strength (see the header).
function Melee.knockback(_heavy: boolean): number
	return Combat.KNOCKBACK
end

-- How many times a landed hit costs attack exhaustion (see the header).
function Melee.exhaustion(_heavy: boolean): number
	return 1
end

-- The share of a zombie's hit blocked (see the header).
function Melee.guardShare(
	_item: number?,
	_guarding: boolean,
	_lookX: number,
	_lookZ: number,
	_dx: number,
	_dz: number
): number
	return 0
end

-- Does the hit kill outright (see the header)?
function Melee.finisher(_item: number?, _aware: boolean, _behindDot: number, _health: number): boolean
	return false
end

return Melee
