--!strict
--[[
	What there is to drink and how containers fill (Tough As Nails), pure (no Roblox APIs, so the
	tests run it). The items are ItemList's (Glass Bottle, Dirty / Purified Water Bottle, Canteen,
	Dirty / Purified Water Canteen); dirty water is purified in a furnace (Crafting/Recipes).

	  Drink                 thirst  hydration  Thirst effect
	  a water source, hand    1       0.1      75%, 30 s    TAN's hand drinking (Config
	                                                        .ToughAsNails.HandDrinking)
	  dirty water             4       0.25     75%, 30 s    bottle or canteen sip
	  purified water          6       0.4        -          bottle or canteen sip
	(hydration is the modifier: Thirst.drink adds thirst x modifier x 2; the Thirst effect costs
	0.025 exhaustion a tick, so 30 s of it is 3.75 points of hydration or thirst; a longer one
	already running stays, so sips in a row cost one effect.)

	Using an item (`action`, right click; Minecraft's Item.use after a block's own use):
	  Glass Bottle            at a water source: fill (BottleItem: a ray that stops at sources)
	  Canteen                 at a water source: fill to 3 sips of dirty water
	  Dirty Water Canteen     at a water source with sips missing: fill again; else drink
	  bottles, other canteens drink (a purified canteen is never dirtied by accident)
	  empty hand              at a water source: a sip (instant, at most one per HAND_INTERVAL)
	Drinking an item takes USE_TICKS (32, PotionItem.getUseDuration) of holding the button, and
	only while thirsty (creative: always, Thirst.canDrink). Then (`afterDrinking`):
	  a bottle    one is used up and a Glass Bottle comes back (PotionItem.finishUsingItem: the
	              bottle replaces the stack when it was the last, else it goes into the inventory);
	  a canteen   wears a sip (its `damage`; durability 3); the last sip leaves the empty Canteen.
	Creative players (instabuild) drink without using anything up, as Minecraft's.
	Filling (`fill`) is ItemUtils.createFilledResult: one empty container is used up and the full
	one replaces the stack when it was the last, else goes into the inventory; creative players
	keep the empty one and get a full one only when they have none.
]]

local Fluids = require(script.Parent.Parent.Fluids)
local Items = require(script.Parent.Parent.Items)
local Thirst = require(script.Parent.Thirst)

type Stack = Items.Stack

export type Drink = {
	-- Thirst points and hydration modifier (Thirst.drink).
	thirst: number,
	hydration: number,
	-- Chance (0..1) of TAN's Thirst effect, and its ticks.
	chance: number,
	effectTicks: number,
}

-- What a use does: "fill", "drink", "hand" (a sip from a water source) or nil (nothing).
export type Action = "fill" | "drink" | "hand"

local Drinks = {}

Drinks.HAND = table.freeze({ thirst = 1, hydration = 0.1, chance = 0.75, effectTicks = 600 }) :: Drink
Drinks.DIRTY = table.freeze({ thirst = 4, hydration = 0.25, chance = 0.75, effectTicks = 600 }) :: Drink
Drinks.PURIFIED = table.freeze({ thirst = 6, hydration = 0.4, chance = 0, effectTicks = 0 }) :: Drink

-- Ticks of holding the use button to drink an item (Minecraft's potions and TAN's drinks).
Drinks.USE_TICKS = 32
-- Ticks between two sips from a water source with an empty hand.
Drinks.HAND_INTERVAL = 10

local I = Items.id
Drinks.GLASS_BOTTLE = I.GlassBottle
Drinks.DIRTY_BOTTLE = I.DirtyWaterBottle
Drinks.PURIFIED_BOTTLE = I.PurifiedWaterBottle
Drinks.CANTEEN = I.Canteen
Drinks.DIRTY_CANTEEN = I.DirtyWaterCanteen
Drinks.PURIFIED_CANTEEN = I.PurifiedWaterCanteen

local DRINKS: { [number]: Drink } = {
	[Drinks.DIRTY_BOTTLE] = Drinks.DIRTY,
	[Drinks.PURIFIED_BOTTLE] = Drinks.PURIFIED,
	[Drinks.DIRTY_CANTEEN] = Drinks.DIRTY,
	[Drinks.PURIFIED_CANTEEN] = Drinks.PURIFIED,
}
-- Canteens: the empty one their last sip leaves.
local CANTEENS: { [number]: boolean } = {
	[Drinks.DIRTY_CANTEEN] = true,
	[Drinks.PURIFIED_CANTEEN] = true,
}

-- What drinking `item` gives (nil: it is no drink).
function Drinks.of(item: number?): Drink?
	return if item then DRINKS[item] else nil
end

-- Is `item` drunk by holding the use button (a filled bottle or canteen)?
function Drinks.isDrink(item: number?): boolean
	return Drinks.of(item) ~= nil
end

-- Does a right click with `item` do anything here (drink, or fill at water)?
function Drinks.isWaterItem(item: number?): boolean
	return item == Drinks.GLASS_BOTTLE or item == Drinks.CANTEEN or Drinks.isDrink(item)
end

-- Is `block` a water source a bottle or a hand drinks from (Minecraft's ClipContext SOURCE_ONLY
-- water)?
function Drinks.isWaterSource(block: number?): boolean
	return block ~= nil and Fluids.isSource(block) and Fluids.ofBlock(block) == Fluids.WATER
end

-- Would `stack` be filled at a water source (see the header)?
function Drinks.fills(stack: Stack?): boolean
	if stack == nil then
		return false
	end
	local item = stack.item
	return item == Drinks.GLASS_BOTTLE
		or item == Drinks.CANTEEN
		or (item == Drinks.DIRTY_CANTEEN and (stack.damage or 0) > 0)
end

--[[
	What a right click does with `stack` in hand (nil: empty), aiming at a water source or not,
	for a player who may drink now (`canDrink`, Thirst.canDrink) and with hand drinking on or off.
]]
function Drinks.action(stack: Stack?, atWater: boolean, canDrink: boolean, handDrinking: boolean): Action?
	if stack == nil then
		return if atWater and canDrink and handDrinking then "hand" else nil
	end
	if atWater and Drinks.fills(stack) then
		return "fill"
	end
	if Drinks.isDrink(stack.item) and canDrink then
		return "drink"
	end
	return nil
end

-- The full container `stack` becomes at water (nil: it fills to nothing).
function Drinks.filledOf(stack: Stack): number?
	local item = stack.item
	if item == Drinks.GLASS_BOTTLE then
		return Drinks.DIRTY_BOTTLE
	elseif item == Drinks.CANTEEN or item == Drinks.DIRTY_CANTEEN then
		return Drinks.DIRTY_CANTEEN
	end
	return nil
end

--[[
	Fills the held `stack` at water (ItemUtils.createFilledResult, see the header): the new held
	stack (nil: the slot empties) and a stack to give besides (nil: none). `hasItem` says whether
	the player holds an item anywhere (creative's rule). A stack that doesn't fill comes back as it
	was.
]]
function Drinks.fill(stack: Stack, creative: boolean, hasItem: (item: number) -> boolean): (Stack?, Stack?)
	local filled = if Drinks.fills(stack) then Drinks.filledOf(stack) else nil
	if filled == nil then
		return stack, nil
	end
	local full = { item = filled, count = 1 }
	if creative then
		return stack, if hasItem(filled) then nil else full
	end
	if stack.count <= 1 then
		return full, nil
	end
	return Items.withCount(stack, stack.count - 1), full
end

--[[
	The held stack after drinking it (see the header), and a stack to give besides (the Glass
	Bottle of a bottle that was not the last).
]]
function Drinks.afterDrinking(stack: Stack, creative: boolean): (Stack?, Stack?)
	if creative or not Drinks.isDrink(stack.item) then
		return stack, nil
	end
	if CANTEENS[stack.item] then
		local def = Items.get(stack.item)
		local durability = if def then def.durability or 1 else 1
		local damage = (stack.damage or 0) + 1
		if damage >= durability then
			return { item = Drinks.CANTEEN, count = 1 }, nil
		end
		return { item = stack.item, count = 1, damage = damage }, nil
	end
	local glass = { item = Drinks.GLASS_BOTTLE, count = 1 }
	if stack.count <= 1 then
		return glass, nil
	end
	return Items.withCount(stack, stack.count - 1), glass
end

-- Sips left in a canteen stack (0 for anything else).
function Drinks.sips(stack: Stack?): number
	if stack == nil or not CANTEENS[stack.item] then
		return 0
	end
	local def = Items.get(stack.item)
	return math.max(0, (if def then def.durability or 0 else 0) - (stack.damage or 0))
end

--[[
	Drinks `drink` into a thirst state (ToughAsNails/Thirst) with `random` (0..1, the effect's
	roll): returns whether the Thirst effect was given.
]]
function Drinks.apply(thirst: Thirst.State, drink: Drink, random: () -> number): boolean
	Thirst.drink(thirst, drink.thirst, drink.hydration)
	if drink.chance > 0 and random() < drink.chance then
		Thirst.giveEffect(thirst, drink.effectTicks)
		return true
	end
	return false
end

return Drinks
