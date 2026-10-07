--!strict
--[[
	Lava and fire hurting and burning players and dropped items, pure (no Roblox APIs, so the tests
	run it): Minecraft 1.20.1's Entity.baseTick (burning: remainingFireTicks, lavaHurt), its
	updateFluidHeightAndDoFluidPushing (what touches a body), BaseFireBlock.entityInside (fire
	blocks), LivingEntity.hurt's cooldown and ItemEntity's health, with the numbers of each fluid's
	record (Shared/Fluids: lava hurts 4 every 10 ticks and sets burning for 15 s; water puts
	burning out).

	  Touching  `touching(getBlock, box)`: the fluids reaching into a box (a bit per Shared/Fluids
	            id, `has`), deflated by 0.001 as Minecraft does: a fluid cell overlapping it whose
	            surface (Blocks.fluidHeightLut; the whole cell when the same fluid is above: the
	            FluidState.getHeight Minecraft compares) is at or above the box's bottom; and the
	            FIRE bit when a fire block's cell overlaps it (Minecraft's checkInsideBlocks runs
	            entityInside for every cell the box is in, whatever the fire's outline), the
	            CAMPFIRE bit for a campfire's. Unknown (unloaded) cells touch nothing, so nothing
	            hurts at a chunk that is not loaded.

	  Players   one tick (20 a second, `tickPlayer`, Players/Characters runs it on the standing box
	            at the feet: the server can't tell a player's pose), in Entity.baseTick's order:
	              1. touching a fluid that `extinguishes` (water) puts burning out
	                 (updateInWaterStateAndDoFluidPushing's clearFire);
	              2. burning: every Fluids.BURN_INTERVAL (20) ticks of it left, Fluids.BURN_DAMAGE
	                 (1) half heart, but not while in a fluid that hurts (Minecraft: not in lava);
	                 one tick of it burns away;
	              3. in a fluid that hurts (lava, `damage` > 0): burning for at least its
	                 `burnSeconds` (setSecondsOnFire(15): 300 ticks) and its `damage` (4) half hearts
	                 (lavaHurt; a hurt that lands sizzles: entity.generic.burn);
	              4. in a fire block (BaseFireBlock.entityInside, after the move): burning goes on
	                 (a tick more, so it never runs down while in the fire), or, not burning yet,
	                 the player catches fire after PLAYER_FIRE_IMMUNE (20) ticks in it
	                 (remainingFireTicks counting up from -getFireImmuneTicks to 0) for
	                 IN_FIRE_SECONDS (8 s); and IN_FIRE_DAMAGE (1) half heart (inFire, softened by
	                 armor, under the cooldown; no sizzle). Out of fire and lava, not burning, the
	                 count starts over (Entity.move);
	              5. in a campfire (CampfireBlock.entityInside, always lit here): CAMPFIRE_DAMAGE
	                 (its fireDamage, 1) half heart, inFire, softened by armor, under the
	                 cooldown, and nothing more: a campfire sets nobody alight (nor is it in
	                 BlockTags.FIRE, so it doesn't keep the count above going either).
	            Hurts follow LivingEntity.hurt's cooldown: after a hurt lands, for its `damageInterval`
	            (lava: 10 ticks, half of Minecraft's 20 invulnerable ticks; burning: HURT_COOLDOWN, the
	            same 10) only a bigger hurt lands, and only by the difference. So lava takes 4 every
	            10 ticks, and a player who leaves it burns 1 every 20 ticks for 15 s (15 half
	            hearts, the first lost under the lava's cooldown) unless water puts it out. Armor
	            softens the fluid's hurt (Minecraft's lava damage type does not bypass armor:
	            Items.damageAfterArmor, CombatRules.getDamageAfterAbsorb; full diamond takes lava's 4
	            down to 0.96) but not burning's (on_fire bypasses armor).
	            Creative and spectator players (GameMode.invulnerable) never burn nor are hurt: their
	            burning is put out at once.
	            Status effects change it (`fire`, Shared/Effects.fireRules): Fire Resistance takes
	            every fire hurt away (lava, fire, campfires, burning: LivingEntity.hurt refuses
	            IS_FIRE damage; burning still counts down and shows, and no hurt means no sizzle
	            and no cooldown), Oil Coated and Fuel Soaked make the burning lava and fire set
	            last `factor` times longer (2, 3), Oil Coated makes each burning hurt `bonus` (1)
	            more, and Fuel Soaked catches fire in a fire block at once (`ignites`, no 20 tick
	            wait). `ignite` sets burning from elsewhere (a blast lighting a soaked player).
	            Explosions hurt through the same cooldown (`hurtPlayer`).

	  Items     one tick (`tickItem`, server Entities/EntityWorld): ItemEntity's 5 health with no
	            cooldown (items have no invulnerable time). Water puts burning out; burning takes
	            1 every 20 ticks of it left, not in lava; lava sets it burning and takes 4 a tick.
	            So an item touching lava for one tick is gone the next (5 - 4, then - 1 or - 4),
	            with Minecraft's entity.generic.burn on each lava hurt. A fire block sets it burning
	            at once (an item's getFireImmuneTicks is 1) and takes 1 a tick, silently: gone in a
	            few ticks. (Nothing is fire resistant: the game has no netherite.) A campfire leaves
	            items be (its entityInside hurts living entities only).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Effects = require(Shared.Effects)
local Fluids = require(Shared.Fluids)
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)

export type GetBlock = (x: number, y: number, z: number) -> number?

-- A player's burning (one per character).
export type PlayerState = {
	-- Ticks left burning (Minecraft's remainingFireTicks; 0: not burning).
	fire: number,
	-- Ticks spent in a fire block before catching fire (Minecraft's remainingFireTicks below 0,
	-- counting up from -PLAYER_FIRE_IMMUNE).
	heat: number,
	-- Ticks of the hurt cooldown left (while above 0 only a hurt bigger than `lastHurt` lands,
	-- by the difference) and that last hurt (half hearts).
	cooldown: number,
	lastHurt: number,
}

-- A dropped item's burning (ItemEntity's health and fire).
export type ItemState = { health: number, fire: number }

local Burning = {}

-- Ticks of LivingEntity.hurt's cooldown after a burning hurt (half its invulnerableTime of 20).
Burning.HURT_COOLDOWN = 10
-- ItemEntity's health.
Burning.ITEM_HEALTH = 5
-- How far boxes are deflated before looking (Entity.updateFluidHeightAndDoFluidPushing).
local DEFLATE = 0.001
local TICKS_PER_SECOND = 20
-- The bit `touching` sets for a fire block (above every fluid's).
Burning.FIRE = bit32.lshift(1, 30)
-- Fire blocks (BaseFireBlock.entityInside, FireBlock's fireDamage): the half hearts a tick in one
-- costs, the burning it sets and the ticks a player stands in it before catching fire
-- (Player.getFireImmuneTicks).
Burning.IN_FIRE_DAMAGE = 1
Burning.IN_FIRE_SECONDS = 8
Burning.PLAYER_FIRE_IMMUNE = 20
local FIRE_BLOCK = Blocks.id.Fire
-- The bit `touching` sets for a campfire (BlockList Campfire), and the half hearts a tick in one
-- costs (CampfireBlock's fireDamage).
Burning.CAMPFIRE = bit32.lshift(1, 29)
Burning.CAMPFIRE_DAMAGE = 1
local CAMPFIRE_BLOCK = Blocks.id.Campfire

local fluidHeightLut = Blocks.fluidHeightLut
local FULL = Blocks.FLUID_FULL
local blockLut = Fluids.blockLut
local floor = math.floor

assert(#Fluids.list < 29, "fluid bits must stay below Burning.CAMPFIRE and Burning.FIRE")

-- Per fluid id: does it put burning out, and does it hurt (its record)?
local EXTINGUISHES = 0
local HURTS: { Fluids.Fluid } = {}
for id, fluid in Fluids.list do
	if fluid.extinguishes then
		EXTINGUISHES = bit32.bor(EXTINGUISHES, bit32.lshift(1, id))
	end
	if fluid.damage > 0 then
		table.insert(HURTS, fluid)
	end
end
-- (The most harmful first: a body in two that hurt takes the worse.)
table.sort(HURTS, function(a, b)
	if a.damage ~= b.damage then
		return a.damage > b.damage
	end
	return a.id < b.id
end)

-- The fluid id of `block` (0: none, unknown blocks too).
local function fluidOf(block: number?): number
	if block == nil or block < 0 or block >= Blocks.count then
		return 0
	end
	return buffer.readu8(blockLut, block)
end

-- Is fluid `fluid` (a bit) in the mask `touching`?
function Burning.has(touching: number, fluid: number): boolean
	return bit32.btest(touching, bit32.lshift(1, fluid))
end

--[[
	The fluids reaching into the box (minX, minY, minZ)-(maxX, maxY, maxZ) (blocks), as a mask: bit
	`id` for each Shared/Fluids id. See the header.
]]
function Burning.touching(
	getBlock: GetBlock,
	minX: number,
	minY: number,
	minZ: number,
	maxX: number,
	maxY: number,
	maxZ: number
): number
	minX, minY, minZ = minX + DEFLATE, minY + DEFLATE, minZ + DEFLATE
	maxX, maxY, maxZ = maxX - DEFLATE, maxY - DEFLATE, maxZ - DEFLATE
	if not (minX <= maxX and minY <= maxY and minZ <= maxZ) or maxX - minX > 16 or maxY - minY > 16 then
		return 0
	end
	local mask = 0
	-- (Minecraft's cells: floor(min) .. ceil(max) - 1.)
	for x = floor(minX), math.ceil(maxX) - 1 do
		for z = floor(minZ), math.ceil(maxZ) - 1 do
			for y = floor(minY), math.ceil(maxY) - 1 do
				local block = getBlock(x, y, z)
				if block == FIRE_BLOCK then
					mask = bit32.bor(mask, Burning.FIRE)
				elseif block == CAMPFIRE_BLOCK then
					mask = bit32.bor(mask, Burning.CAMPFIRE)
				end
				local fluid = fluidOf(block)
				if fluid ~= 0 and not Burning.has(mask, fluid) then
					local height = if fluidOf(getBlock(x, y + 1, z)) == fluid
						then 1
						else buffer.readu8(fluidHeightLut, block :: number) / FULL
					if y + height >= minY then
						mask = bit32.bor(mask, bit32.lshift(1, fluid))
					end
				end
			end
		end
	end
	return mask
end

-- The fluids reaching into a box `width` wide and `height` tall standing at (x, y, z) (the bottom
-- centre: a player's feet, an item's position).
function Burning.touchingAt(getBlock: GetBlock, x: number, y: number, z: number, width: number, height: number): number
	local half = width / 2
	return Burning.touching(getBlock, x - half, y, z - half, x + half, y + height, z + half)
end

-- The most harmful fluid in `touching` (its record), nil when none hurts.
local function harmful(touching: number): Fluids.Fluid?
	if touching == 0 then
		return nil
	end
	for _, fluid in HURTS do
		if Burning.has(touching, fluid.id) then
			return fluid
		end
	end
	return nil
end

function Burning.newPlayer(): PlayerState
	return { fire = 0, heat = 0, cooldown = 0, lastHurt = 0 }
end

function Burning.newItem(): ItemState
	return { health = Burning.ITEM_HEALTH, fire = 0 }
end

-- Is the player (or item) burning?
function Burning.onFire(state: PlayerState | ItemState): boolean
	return state.fire > 0
end

-- LivingEntity.hurt's cooldown: the half hearts `amount` takes now (see the header).
local function hurt(state: PlayerState, amount: number, cooldown: number): number
	if amount <= 0 then
		return 0
	end
	if state.cooldown > 0 then
		if amount <= state.lastHurt then
			return 0
		end
		local extra = amount - state.lastHurt
		state.lastHurt = amount
		return extra
	end
	state.lastHurt = amount
	state.cooldown = cooldown
	return amount
end

--[[
	One tick of a player in game mode `mode` touching the fluids `touching` (`touching`'s mask),
	wearing `armor` points with `toughness` (Items.armorPoints; default none), with the status
	effects' `fire` rules (Shared/Effects.fireRules; nil: none). Returns the half hearts (of 20) it
	costs them this tick, whether burning was put out (by water: Minecraft's
	entity.generic.extinguish_fire) and whether the fluid's hurt landed (Entity.lavaHurt's hurt
	returned true, however much armor took: Minecraft's entity.generic.burn).
]]
function Burning.tickPlayer(
	state: PlayerState,
	mode: string,
	touching: number,
	armor: number?,
	toughness: number?,
	fire: Effects.FireRules?
): (number, boolean, boolean)
	if state.cooldown > 0 then
		state.cooldown -= 1
	end
	if GameMode.invulnerable(mode) then
		state.fire, state.heat = 0, 0
		return 0, false, false
	end
	-- (Fire Resistance: no fire hurt lands at all.)
	local immune = fire ~= nil and fire.immune
	local factor = if fire then fire.factor else 1
	local extinguished = false
	if bit32.band(touching, EXTINGUISHES) ~= 0 then
		state.heat = 0
		if state.fire > 0 then
			state.fire = 0
			extinguished = true
		end
	end
	local fluid = harmful(touching)
	local damage = 0
	if state.fire > 0 then
		if state.fire % Fluids.BURN_INTERVAL == 0 and fluid == nil and not immune then
			damage += hurt(state, Fluids.BURN_DAMAGE + (if fire then fire.bonus else 0), Burning.HURT_COOLDOWN)
		end
		state.fire -= 1
	end
	local hurtNow = false
	if fluid then
		state.fire = math.max(state.fire, math.floor(fluid.burnSeconds * TICKS_PER_SECOND * factor))
		if not immune then
			local landed = hurt(state, fluid.damage, fluid.damageInterval)
			hurtNow = landed > 0
			if landed > 0 and (armor or 0) > 0 then
				landed = Items.damageAfterArmor(landed, armor or 0, toughness or 0)
			end
			damage += landed
		end
	end
	if bit32.btest(touching, Burning.FIRE) then
		-- (BaseFireBlock.entityInside: remainingFireTicks + 1, 8 s once it reaches 0; at once
		-- when the effects say it ignites.)
		if state.fire > 0 then
			state.fire += 1
		else
			state.heat += 1
			if state.heat >= Burning.PLAYER_FIRE_IMMUNE or (fire ~= nil and fire.ignites) then
				state.heat = 0
				state.fire = math.floor(Burning.IN_FIRE_SECONDS * TICKS_PER_SECOND * factor)
			end
		end
		if not immune then
			local landed = hurt(state, Burning.IN_FIRE_DAMAGE, Burning.HURT_COOLDOWN)
			if landed > 0 and (armor or 0) > 0 then
				landed = Items.damageAfterArmor(landed, armor or 0, toughness or 0)
			end
			damage += landed
		end
	elseif fluid == nil and state.fire <= 0 then
		state.heat = 0
	end
	if bit32.btest(touching, Burning.CAMPFIRE) and not immune then
		-- (CampfireBlock.entityInside: hurt(inFire, fireDamage), no burning.)
		local landed = hurt(state, Burning.CAMPFIRE_DAMAGE, Burning.HURT_COOLDOWN)
		if landed > 0 and (armor or 0) > 0 then
			landed = Items.damageAfterArmor(landed, armor or 0, toughness or 0)
		end
		damage += landed
	end
	return damage, extinguished, hurtNow
end

--[[
	Sets a player in game mode `mode` burning for at least `seconds` (Entity.setSecondsOnFire),
	times the effects' `fire` factor (a blast lighting a Fuel Soaked player: Players/Characters).
	Creative and spectator players never burn.
]]
function Burning.ignite(state: PlayerState, mode: string, seconds: number, fire: Effects.FireRules?)
	if GameMode.invulnerable(mode) or not (seconds > 0) then
		return
	end
	local factor = if fire then fire.factor else 1
	state.fire = math.max(state.fire, math.floor(seconds * TICKS_PER_SECOND * factor))
end

--[[
	A hurt of `amount` half hearts from outside the fluids (an explosion: Shared/World/Explosion,
	server World/Explosions) on a player in game mode `mode` wearing `armor` points with
	`toughness`. It goes through the same LivingEntity.hurt cooldown as lava and burning, so
	blasts going off within 10 ticks of each other land only their biggest (a bigger one only by
	the difference), as a pile of TNT does in Minecraft, and armor softens it (explosions don't
	bypass armor). Creative and spectator players take nothing. Returns the half hearts it costs.
]]
function Burning.hurtPlayer(
	state: PlayerState,
	mode: string,
	amount: number,
	armor: number?,
	toughness: number?
): number
	if GameMode.invulnerable(mode) or not (amount > 0) then
		return 0
	end
	local landed = hurt(state, amount, Burning.HURT_COOLDOWN)
	if landed > 0 and (armor or 0) > 0 then
		landed = Items.damageAfterArmor(landed, armor or 0, toughness or 0)
	end
	return landed
end

--[[
	One tick of a dropped item touching the fluids `touching`. Returns whether it burnt away
	(health 0) and whether a fluid hurt it this tick (the burn sound).
]]
function Burning.tickItem(state: ItemState, touching: number): (boolean, boolean)
	if bit32.band(touching, EXTINGUISHES) ~= 0 then
		state.fire = 0
	end
	local fluid = harmful(touching)
	if state.fire > 0 then
		if state.fire % Fluids.BURN_INTERVAL == 0 and fluid == nil then
			state.health -= Fluids.BURN_DAMAGE
		end
		state.fire -= 1
	end
	local hurtNow = false
	if fluid then
		state.fire = math.max(state.fire, fluid.burnSeconds * TICKS_PER_SECOND)
		state.health -= fluid.damage
		hurtNow = true
	end
	if bit32.btest(touching, Burning.FIRE) then
		-- (An item's fire immunity is a single tick: it catches fire at once.)
		state.fire = if state.fire > 0 then state.fire + 1 else Burning.IN_FIRE_SECONDS * TICKS_PER_SECOND
		state.health -= Burning.IN_FIRE_DAMAGE
	end
	return state.health <= 0, hurtNow
end

return Burning
