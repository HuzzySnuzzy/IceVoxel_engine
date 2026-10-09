--!strict
--[[
	Terraria's accessories (ItemList `accessory`; Inventory/Types' accessory slots): what the worn
	ones add up to, pure, so the client's movement prediction (Movement/PlayerPhysics through
	Player/MovementController) and the server's rules (fall damage, regeneration, armor, knockback,
	the move check, max mana) read the same numbers from the same inventory, and nothing is sent.

	  stats        the accessories in the open slots (1..`accessorySlots`), each item once (Terraria
	               lets no accessory be worn twice: Inventory/Menu refuses a second, and a stray
	               one still counts once), summed into one Stats table:
	                 speed, jump, airJumps, mana, defense, attackSpeed   added
	                 runBoost, swim, knockback                           the largest (two pairs of
	                                                                     running boots are as fast
	                                                                     as the faster: Terraria's
	                                                                     accRunSpeed)
	                 regen                                               the shortest interval (0:
	                                                                     none)
	                 noFallDamage, fireWalk                              any
	               A hidden look (`hidden`) still works: hiding only stops it being drawn. Slots
	               past `accessorySlots` (an Age lost to /age) do nothing until they open again.
	               `out` is filled in place, so a caller recomputing it on every inventory change
	               allocates nothing.
	  slotsForAge  accessory slots open at Age `age` (an Ages index): Config.Accessories.Slots, one
	               more for each of ExtraSlotAges reached (Industrial, Atomic: Terraria's Demon Heart
	               and Master mode), at most Types.ACCESSORY_SIZE.
	  armorPoints  Items.armorPoints of the armor worn plus the accessories' defense (Obsidian Skull,
	               Cobalt Shield: Terraria's +1 defense each), for every reader of armor points.
	  isHidden     whether an accessory slot's or an armor slot's look is hidden.
]]

local Config = require(script.Parent.Parent.Config)
local Ages = require(script.Parent.Parent.Progression.Ages)
local Items = require(script.Parent)
local Types = require(script.Parent.Parent.Inventory.Types)

export type Stats = {
	-- Share of movement speed added (1 + speed times it).
	speed: number,
	-- Sprinting on the ground builds up to 1 + runBoost times the speed (Hermes Boots).
	runBoost: number,
	-- Jumps in the air (Cloud in a Bottle).
	airJumps: number,
	-- Jump velocity added, blocks a tick (Shiny Red Balloon).
	jump: number,
	noFallDamage: boolean,
	-- Ticks per half heart healed while hurt (0: none; Band of Regeneration).
	regen: number,
	-- Max mana added (Band of Starpower).
	mana: number,
	-- Armor points added.
	defense: number,
	-- No hurt from hot blocks (Obsidian Skull).
	fireWalk: boolean,
	-- Knockback resistance, 0..1 (Cobalt Shield).
	knockback: number,
	-- Share of swimming acceleration added (Flipper).
	swim: number,
	-- Share of melee attack speed added (Feral Claws).
	attackSpeed: number,
}

local Accessories = {}

-- Nothing worn.
function Accessories.new(): Stats
	return {
		speed = 0,
		runBoost = 0,
		airJumps = 0,
		jump = 0,
		noFallDamage = false,
		regen = 0,
		mana = 0,
		defense = 0,
		fireWalk = false,
		knockback = 0,
		swim = 0,
		attackSpeed = 0,
	}
end

-- Items counted in the current `stats` call (cleared each time: no allocation).
local seen: { [number]: boolean } = {}

-- What the accessories worn in `inventory`'s open slots add up to (into `out` when given).
function Accessories.stats(inventory: Types.Inventory, out: Stats?): Stats
	local stats = out or Accessories.new()
	stats.speed, stats.runBoost, stats.airJumps, stats.jump = 0, 0, 0, 0
	stats.noFallDamage, stats.regen, stats.mana, stats.defense = false, 0, 0, 0
	stats.fireWalk, stats.knockback, stats.swim, stats.attackSpeed = false, 0, 0, 0
	table.clear(seen)
	local open = math.clamp(inventory.accessorySlots, 0, Types.ACCESSORY_SIZE)
	for slot = 1, open do
		local stack = inventory.accessories[slot]
		local item = stack and stack.item
		local accessory = if item and not seen[item] then Items.accessory(item) else nil
		if item and accessory then
			seen[item] = true
			stats.speed += accessory.speed or 0
			stats.airJumps += accessory.airJumps or 0
			stats.jump += accessory.jump or 0
			stats.mana += accessory.mana or 0
			stats.defense += accessory.defense or 0
			stats.attackSpeed += accessory.attackSpeed or 0
			stats.runBoost = math.max(stats.runBoost, accessory.runBoost or 0)
			stats.swim = math.max(stats.swim, accessory.swim or 0)
			stats.knockback = math.max(stats.knockback, accessory.knockback or 0)
			local regen = accessory.regen
			if regen and regen > 0 and (stats.regen == 0 or regen < stats.regen) then
				stats.regen = regen
			end
			stats.noFallDamage = stats.noFallDamage or accessory.noFallDamage == true
			stats.fireWalk = stats.fireWalk or accessory.fireWalk == true
		end
	end
	return stats
end

-- Accessory slots open at Age index `age` (see the header).
function Accessories.slotsForAge(age: number): number
	local slots = Types.BASE_ACCESSORY_SLOTS
	for _, id in Config.Accessories.ExtraSlotAges do
		local reached = Ages.byId(id)
		if reached and age >= reached.index then
			slots += 1
		end
	end
	return math.min(slots, Types.ACCESSORY_SIZE)
end

-- Armor points and toughness worn, the accessories' defense included.
function Accessories.armorPoints(inventory: Types.Inventory): (number, number)
	local points, toughness = Items.armorPoints(inventory.armor)
	local open = math.clamp(inventory.accessorySlots, 0, Types.ACCESSORY_SIZE)
	table.clear(seen)
	for slot = 1, open do
		local stack = inventory.accessories[slot]
		local item = stack and stack.item
		local accessory = if item and not seen[item] then Items.accessory(item) else nil
		if item and accessory then
			seen[item] = true
			points += accessory.defense or 0
		end
	end
	return points, toughness
end

-- Is the look of accessory slot `slot` ("accessory") or armor slot `slot` ("armor") hidden?
function Accessories.isHidden(inventory: Types.Inventory, kind: "accessory" | "armor", slot: number): boolean
	local bit = if kind == "armor" then Types.HIDE_ARMOR + slot - 1 else slot - 1
	return bit32.btest(inventory.hidden, bit32.lshift(1, bit))
end

return Accessories
