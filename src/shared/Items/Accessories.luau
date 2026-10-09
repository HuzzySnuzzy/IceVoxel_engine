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
	  speedFactor  how much faster the stats move a player sideways at most, (1 + speed) x (1 +
	               runBoost): the server's move check (Players/MoveCheck.setFactor; 1.61 with
	               today's accessories).
	  knockbackShare  the share of a push that reaches the player (1 - knockback): the server
	               scales the explosion and mob pushes it sends, and their speed allowance.
	  fallReduction  blocks of fall the jump added takes off before fall damage, as Jump Boost's
	               (Minecraft's LivingEntity.calculateFallDamage: a block for each 0.1 of jump
	               velocity; a Shiny Red Balloon's 0.1: 1): the client's prediction
	               (PlayerPhysics' `fallReduction`) and the server's Fall (Players/Characters).
	  regenerate   one 20 Hz tick of a Band of Regeneration's count: a half heart every `regen`
	               ticks while hurt, alive and in survival or adventure (Players/Characters).
	  hasteTicks   ticks since the last swing as a weapon `attackSpeed` faster than its own sees
	               them (Feral Claws: Combat.strength's recharge x (1 + attackSpeed), done on the
	               ticks so Combat's speeds stay Minecraft's): the server's hits (Mobs/Mobs) and
	               the client's attack indicator agree.
	  looks        what the character shows, as the text of the Types.LOOKS_ATTRIBUTE player
	               attribute (server Players/Inventories sets it, every client's
	               Player/EquipmentLooks draws it): the four armor pieces, head to feet, each its
	               vanity item over the armor worn and "0" when the armor slot is hidden or empty;
	               then the accessories drawn (only items with a `worn` place), at most
	               ACCESSORY_SIZE, each a vanity accessory over the accessory in its row (shown
	               even when that one is hidden, Terraria; vanity rows are never closed: looks
	               only), else the accessory unless hidden or its slot closed, each item once.
	               "4100,0,0,4235,4237".
	  parseLooks   the item ids of such a text ([1..4] armor, 0 none; [5..] accessories); nonsense
	               reads as nothing.
	  tooltip      the lines an accessory's or vanity item's tooltip adds ("When worn:", "Sprinting
	               builds up to 40% faster", ...).
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

-- How much faster `stats` move a player sideways at most (see the header).
function Accessories.speedFactor(stats: Stats): number
	return (1 + stats.speed) * (1 + stats.runBoost)
end

-- The share of a push that reaches a player wearing `stats` (a Cobalt Shield's 1 resistance: 0).
function Accessories.knockbackShare(stats: Stats): number
	return 1 - math.clamp(stats.knockback, 0, 1)
end

-- Blocks of fall `stats`' added jump takes off (see the header).
function Accessories.fallReduction(stats: Stats): number
	return math.floor(stats.jump * 10 + 1e-6)
end

--[[
	One tick of a Band of Regeneration (`stats.regen` ticks a half heart; 0: none): `ticks` counted
	so far, whether the player may heal now (hurt, alive, survival or adventure). Returns the new
	count and the half hearts healed this tick (Players/Characters' 20 a second): one every
	`regen` ticks while it may, the count starting over whenever it may not.
]]
function Accessories.regenerate(stats: Stats, ticks: number, mayHeal: boolean): (number, number)
	local regen = stats.regen
	if regen <= 0 or not mayHeal then
		return 0, 0
	end
	ticks += 1
	if ticks >= regen then
		return 0, 1
	end
	return ticks, 0
end

-- `ticks` since the last swing as a weapon `haste` (Stats.attackSpeed) faster sees them.
function Accessories.hasteTicks(ticks: number, haste: number): number
	if not (haste > 0) then
		return ticks
	end
	return (ticks + 0.5) * (1 + haste) - 0.5
end

-- The item drawn for a stack, if it may be (an accessory with a `worn` place).
local function drawn(stack: Types.Stack?): number?
	local item = if stack and stack.count >= 1 then stack.item else nil
	local accessory = if item then Items.accessory(item) else nil
	return if accessory and accessory.worn then item else nil
end

-- What the character shows (Types.LOOKS_ATTRIBUTE's text, see the header).
function Accessories.looks(inventory: Types.Inventory): string
	local parts: { string } = {}
	for slot = 1, Types.ARMOR_SIZE do
		local stack: Types.Stack? = nil
		if not Accessories.isHidden(inventory, "armor", slot) then
			local vanity = inventory.vanityArmor[slot]
			stack = if vanity and vanity.count >= 1 then vanity else inventory.armor[slot]
		end
		parts[slot] = if stack and stack.count >= 1 then tostring(stack.item) else "0"
	end
	local open = math.clamp(inventory.accessorySlots, 0, Types.ACCESSORY_SIZE)
	local shown: { [number]: boolean } = {}
	for slot = 1, Types.ACCESSORY_SIZE do
		local vanity = inventory.vanityAccessories[slot]
		local item = if vanity and vanity.count >= 1 then drawn(vanity) else nil
		if
			(vanity == nil or vanity.count < 1)
			and slot <= open
			and not Accessories.isHidden(inventory, "accessory", slot)
		then
			item = drawn(inventory.accessories[slot])
		end
		if item and not shown[item] then
			shown[item] = true
			table.insert(parts, tostring(item))
		end
	end
	return table.concat(parts, ",")
end

-- The ids of a looks text ([1..4] armor, 0 none; [5..] accessories drawn): see the header.
function Accessories.parseLooks(text: any): { number }
	local ids = { 0, 0, 0, 0 }
	if type(text) ~= "string" or #text > 200 then
		return ids
	end
	local index = 0
	for word in string.gmatch(text, "[^,]+") do
		index += 1
		local id = tonumber(word)
		local valid = id ~= nil and id == math.floor(id) and Items.isValid(id)
		if index <= Types.ARMOR_SIZE then
			ids[index] = if valid then id :: number else 0
		elseif index <= Types.ARMOR_SIZE + Types.ACCESSORY_SIZE then
			if valid and drawn({ item = id :: number, count = 1 }) then
				table.insert(ids, id :: number)
			end
		end
	end
	return ids
end

local ROMAN = { "I", "II", "III", "IV", "V" }

-- A share as a whole percentage ("40%").
local function percent(share: number): string
	return `{math.floor(share * 100 + 0.5)}%`
end

-- The lines an accessory's or vanity item's tooltip adds (see the header); {} for other items.
function Accessories.tooltip(item: number): { string }
	local lines: { string } = {}
	local accessory = Items.accessory(item)
	if accessory == nil then
		if Items.vanitySlot(item) then
			table.insert(lines, "Vanity: worn for its look only")
		end
		return lines
	end
	table.insert(lines, "When worn:")
	local runBoost = accessory.runBoost or 0
	if runBoost > 0 then
		table.insert(lines, `Sprinting builds up to {percent(runBoost)} faster`)
	end
	local airJumps = accessory.airJumps or 0
	if airJumps == 1 then
		table.insert(lines, "Jump once more in the air")
	elseif airJumps > 1 then
		table.insert(lines, `Jump {airJumps} more times in the air`)
	end
	local jump = accessory.jump or 0
	if jump > 0 then
		local level = math.floor(jump / 0.1 + 0.5)
		local roman = ROMAN[level]
		table.insert(
			lines,
			if roman and math.abs(level * 0.1 - jump) < 1e-9
				then `Jump higher (as Jump Boost {roman})`
				else "Jump higher"
		)
	end
	if accessory.noFallDamage then
		table.insert(lines, "No fall damage")
	end
	local speed = accessory.speed or 0
	if speed > 0 then
		table.insert(lines, `+{percent(speed)} movement speed`)
	end
	local regen = accessory.regen or 0
	if regen > 0 then
		local seconds = regen / 20
		table.insert(
			lines,
			if seconds == math.floor(seconds)
				then `Heals half a heart every {seconds} seconds`
				else `Heals half a heart every {string.format("%.1f", seconds)} seconds`
		)
	end
	local mana = accessory.mana or 0
	if mana > 0 then
		table.insert(lines, `+{mana} max mana`)
	end
	local defense = accessory.defense or 0
	if defense > 0 then
		table.insert(lines, `+{defense} Armor`)
	end
	if accessory.fireWalk then
		table.insert(lines, "Campfires don't hurt")
	end
	local knockback = accessory.knockback or 0
	if knockback >= 1 then
		table.insert(lines, "No knockback")
	elseif knockback > 0 then
		table.insert(lines, `{percent(knockback)} less knockback`)
	end
	local swim = accessory.swim or 0
	if swim > 0 then
		table.insert(lines, `Swims {percent(swim)} faster`)
	end
	local attackSpeed = accessory.attackSpeed or 0
	if attackSpeed > 0 then
		table.insert(lines, `+{percent(attackSpeed)} attack speed`)
	end
	return lines
end

return Accessories
