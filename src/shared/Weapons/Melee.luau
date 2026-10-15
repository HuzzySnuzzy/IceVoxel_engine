--!strict
--[[
	The melee rework in the manner of DayZ, pure (server Mobs/MobWorld and Mobs/Mobs, client
	Interaction/MeleeInput): light and heavy attacks, guarding, finishers. The weapons are
	Weapons/WeaponList's `melee` (the knives, the machete, the bats, the crowbar, the axe, the pipe
	wrench, the sledgehammer); every other item (swords, tools, the hand) attacks as before: no
	heavy attack, no guard.

	  spec         the weapon's numbers (Weapons.melee), nil for anything else and while the rework
	               is off
	  mayAttack    may a player attack at all (an Attack message, server Mobs/Mobs) holding their
	               weapon as the aim attribute says (Inventory/Types.AIM_ATTRIBUTE): never while
	               guarding (no attacks from behind the guard) nor with a gun raised (its attack
	               button fires it; only a lowered gun bashes). The client sends none then.
	  heavy        does an Attack's heavy flag count: only with a listed weapon (a client that sends
	               the flag with a sword gets a light hit)
	  heavyHold    is a press held this long a heavy attack (the client's call on release): a
	               listed weapon held HeavyHold (0.45 s) or more; shorter, a light one
	  heavyDamage  a heavy attack's base damage (half hearts, before the attack strength and the
	               status effects): the weapon's `heavy` (a bat 10 where its light hit is 5), else
	               `base` (the light attack's)
	  knockback    a hit's knockback strength: a heavy one's HeavyKnockback (0.8, twice
	               Minecraft's), else Shared/Entities/Combat.KNOCKBACK (0.4)
	  exhaustion   how many times a landed hit costs Minecraft's attack exhaustion (Tough As
	               Nails' food): a heavy one HeavyExhaustion (3; DayZ's heavy swing costs much more
	               stamina, and this game's stamina is food), else 1
	  guardShare   the share (0..1) of a zombie's hit a guarding player blocks: the weapon's
	               `guard` (a knife 0.3, a bat 0.6, the sledgehammer 0.7) when the zombie is within
	               the front cone (the horizontal look (lookX, lookZ) against the horizontal
	               direction to the zombie (dx, dz), both normalised: dot at least GuardCone, 0.5,
	               a 120 degree cone), else 0; 0 when not guarding, without a listed weapon, and
	               when either direction has no horizontal length (looking straight down, the
	               zombie on top of the player)
	  finisher     does a hit kill outright: a weapon with `finisher` (both knives) on a zombie
	               that is not aware of anyone (no target, no hunt) from behind (`behindDot`: the
	               zombie's facing against the direction to the attacker, at most
	               -FinisherCone, -0.5) whose kind's `health` is at most FinisherMaxHealth (30: the
	               ordinary infected, never a brute)? Mobs/MobWorld asks only for zombie kinds.

	Every number is Config.Weapons.Melee's, read at each call (the specs change them). With
	Melee.Enabled false all of it is off: no heavy attacks, no guard, no finishers, light attacks
	as before.
]]

local Combat = require(script.Parent.Parent.Entities.Combat)
local Config = require(script.Parent.Parent.Config)
local Types = require(script.Parent.Parent.Inventory.Types)
local Weapons = require(script.Parent)

local Melee = {}

local function settings()
	return Config.Weapons.Melee
end

-- The weapon's melee numbers, nil for anything that is no listed melee weapon (and while off).
function Melee.spec(item: number?): Weapons.MeleeSpec?
	if not settings().Enabled then
		return nil
	end
	return Weapons.melee(item)
end

-- May a player whose aim attribute is `aim` attack (see the header)?
function Melee.mayAttack(aim: unknown): boolean
	return aim ~= Types.AIM_GUARD and aim ~= Types.AIM_RAISED
end

-- Does an Attack's heavy flag count with `item` in hand (see the header)?
function Melee.heavy(item: number?, flag: boolean?): boolean
	return flag == true and Melee.spec(item) ~= nil
end

--[[
	Is a press of the attack button held `seconds` with `item` a heavy attack (client
	Interaction/MeleeInput, on release)? Only with a listed weapon, held HeavyHold (0.45 s) or more.
]]
function Melee.heavyHold(item: number?, seconds: number): boolean
	return Melee.spec(item) ~= nil and seconds >= settings().HeavyHold
end

-- A heavy attack's base damage with `item` whose light one is `base` (see the header).
function Melee.heavyDamage(item: number?, base: number): number
	local spec = Melee.spec(item)
	return if spec then spec.heavy else base
end

-- A hit's knockback strength (see the header).
function Melee.knockback(heavy: boolean): number
	local melee = settings()
	return if heavy and melee.Enabled then melee.HeavyKnockback else Combat.KNOCKBACK
end

-- How many times a landed hit costs attack exhaustion (see the header): a whole number, 1 or more.
function Melee.exhaustion(heavy: boolean): number
	local melee = settings()
	if heavy and melee.Enabled then
		return math.max(1, math.floor(melee.HeavyExhaustion))
	end
	return 1
end

-- The share of a zombie's hit blocked (see the header).
function Melee.guardShare(
	item: number?,
	guarding: boolean,
	lookX: number,
	lookZ: number,
	dx: number,
	dz: number
): number
	local spec = if guarding then Melee.spec(item) else nil
	if spec == nil then
		return 0
	end
	local look = math.sqrt(lookX * lookX + lookZ * lookZ)
	local away = math.sqrt(dx * dx + dz * dz)
	if not (look > 1e-6 and away > 1e-6) then
		return 0
	end
	local dot = (lookX * dx + lookZ * dz) / (look * away)
	return if dot >= settings().GuardCone then spec.guard else 0
end

-- Does the hit kill outright (see the header)?
function Melee.finisher(item: number?, aware: boolean, behindDot: number, health: number): boolean
	local spec = Melee.spec(item)
	local melee = settings()
	return spec ~= nil
		and spec.finisher
		and not aware
		and behindDot <= -melee.FinisherCone
		and health <= melee.FinisherMaxHealth
end

return Melee
