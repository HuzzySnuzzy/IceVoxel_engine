--!strict
--[[
	Players hitting mobs (pure; server Mobs/Mobs validates and applies a hit, client
	Interaction/BlockInteraction aims it): Minecraft 1.20.1's Player.attack without critical hits,
	sweeps or enchantments.

	  Damage    the held item's ItemList `attack` damage (half hearts, the hand's 1 included:
	            swords 4-7 by tier, axes 7-9, pickaxes 2-5, shovels 2.5-5.5, hoes 1), anything else
	            the hand's 1 (`attackOf`).
	  Strength  1.9's attack strength (Player.getAttackStrengthScale(0.5)): a weapon recovers over
	            20 / attack speed ticks (a sword 12.5, an axe 20-25, the hand 5) since the last swing
	            or the last change of held item, and a hit before that lands
	            damage x (0.2 + strength^2 x 0.8) (`damage`); a hit at 0.9 or more is a strong one
	            (entity.player.attack.strong, else .weak).
	  Reach     Minecraft's entity pick range: 3 blocks from the eyes to the mob's box in survival
	            and adventure, 6 in creative (GameRenderer.pick); spectators hit nothing (`reach`).
	            The server allows SERVER_LEEWAY more for the mob's movement and the latency.
	  Knockback LivingEntity.knockback(0.4) away from the attacker (`knockback`): the velocity
	            halves and the push is added sideways; on the ground the mob hops up to 0.4.
	  Wear      Minecraft's hurtEnemy: a sword wears 1 a hit, other tools 2 (`wear`).

	Units are blocks and ticks.
]]

local GameMode = require(script.Parent.Parent.GameMode)
local Items = require(script.Parent.Parent.Items)

local Combat = {}

-- The empty hand's (and any item without `attack`): Minecraft's base attack damage 1 and the
-- player's attack speed 4.
Combat.HAND_DAMAGE = 1
Combat.HAND_SPEED = 4
-- Entity reach (blocks from the eyes to the box): survival and adventure, creative.
Combat.REACH = 3
Combat.CREATIVE_REACH = 6
-- What the server allows beyond the reach.
Combat.SERVER_LEEWAY = 1
-- LivingEntity.knockback strength of a hit (and of a mob's hit on a player).
Combat.KNOCKBACK = 0.4
-- A hit at this strength or more is a strong one (Player.attack's flag).
Combat.STRONG = 0.9
-- Player eye height (standing).
Combat.EYE = 1.62

-- The damage (half hearts) and attack speed of hitting with `item` (nil: the empty hand).
function Combat.attackOf(item: number?): (number, number)
	local def = if item then Items.get(item) else nil
	local attack = def and def.attack
	if attack then
		return attack.damage, attack.speed
	end
	return Combat.HAND_DAMAGE, Combat.HAND_SPEED
end

--[[
	Player.getAttackStrengthScale(0.5): how far the weapon has recovered (0..1), `ticks` ticks
	after the last swing (or change of item) with attack speed `speed`.
]]
function Combat.strength(ticks: number, speed: number): number
	if not (speed > 0) then
		return 1
	end
	local delay = 20 / speed
	return math.clamp((ticks + 0.5) / delay, 0, 1)
end

-- A hit of `base` damage at strength `strength`: base x (0.2 + strength^2 x 0.8).
function Combat.damage(base: number, strength: number): number
	return base * (0.2 + strength * strength * 0.8)
end

-- How far (blocks from the eyes to the box) a player in game `mode` hits: 0 for spectators.
function Combat.reach(mode: string): number
	if GameMode.isSpectator(mode) then
		return 0
	end
	return if GameMode.instabuild(mode) then Combat.CREATIVE_REACH else Combat.REACH
end

-- How much hitting a mob wears `item` (Minecraft's hurtEnemy): swords 1, other tools 2, else 0.
function Combat.wear(item: number?): number
	local tool = Items.tool(item)
	local def = if item then Items.get(item) else nil
	if tool == nil or def == nil or def.durability == nil then
		return 0
	end
	return if tool.kind == "sword" then 1 else 2
end

-- Distance from (x, y, z) to the box (minX..maxX, minY..maxY, minZ..maxZ); 0 inside.
function Combat.boxDistance(
	x: number,
	y: number,
	z: number,
	minX: number,
	minY: number,
	minZ: number,
	maxX: number,
	maxY: number,
	maxZ: number
): number
	local dx = math.max(minX - x, 0, x - maxX)
	local dy = math.max(minY - y, 0, y - maxY)
	local dz = math.max(minZ - z, 0, z - maxZ)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--[[
	LivingEntity.knockback(strength, dx, dz) of a body moving at (vx, vy, vz), pushed away from
	(fromX, fromZ) towards (toX, toZ): the new velocity. Straight above or below the attacker it
	goes a random-free fixed way (+X), as Minecraft picks one at random.
]]
function Combat.knockback(
	strength: number,
	fromX: number,
	fromZ: number,
	toX: number,
	toZ: number,
	vx: number,
	vy: number,
	vz: number,
	onGround: boolean
): (number, number, number)
	if not (strength > 0) then
		return vx, vy, vz
	end
	local dx, dz = toX - fromX, toZ - fromZ
	local length = math.sqrt(dx * dx + dz * dz)
	if length < 1e-4 then
		dx, dz, length = 1, 0, 1
	end
	local px, pz = dx / length * strength, dz / length * strength
	local ny = if onGround then math.min(0.4, vy / 2 + strength) else vy
	return vx / 2 + px, ny, vz / 2 + pz
end

return Combat
