--!strict
--[[
	What there is to drink and how containers fill (Tough As Nails), pure (no Roblox APIs, so the
	tests run it). The items are ItemList's (Glass Bottle, Dirty / Purified Water Bottle, Canteen,
	Dirty / Purified Water Canteen, Bowl, Dirty / Purified Water Bowl, Mint / Ginger / Herbal Tea);
	dirty water is purified in a furnace or with a mint leaf in a crafting grid, and a purified
	water bowl brews a tea with a herb (Crafting/Recipes).

	  Drink                 thirst  hydration  Thirst effect  warmth / chill
	  a water source, hand    1       0.1      50%, 15 s        -            TAN's hand drinking
	                                                                         (Config.ToughAsNails
	                                                                         .HandDrinking)
	  dirty water             4       0.25     50%, 15 s        -            bottle, canteen sip
	  purified water          6       0.4        -              -            bottle, canteen sip
	  dirty water bowl        4       0.3      50%, 15 s        -            a bowl holds more
	  purified water bowl     7       0.45       -              -
	  mint tea                7       0.6        -          chill 2 min      a mint leaf brewed
	  ginger tea              7       0.6        -          warmth 2 min     a ginger root
	  herbal tea              8       0.65       -          both 1 min       both herbs
	(hydration is the modifier: Thirst.drink adds thirst x modifier x 2; the Thirst effect costs
	0.015 exhaustion a tick, so 15 s of it is 4.5 exhaustion, about a point of hydration or
	thirst; a longer one already running stays, so sips in a row cost one effect. TAN's own 75%
	and 30 s at 0.025 were too harsh for this game.) A drink may also give TAN's Internal Warmth
	or Internal Chill (`warmth` / `chill` ticks, Temperature.giveWarmth / giveChill): `apply`
	gives them when it is handed the temperature state. A bowl is cheap (three planks make four)
	and holds a little more than a bottle; a tea keeps its water's thirst, adds hydration and its
	effect, so brewing never wastes water: ginger tea keeps a cold biome's chill off (Internal
	Warmth: the target 5 steps warmer, though not past NEUTRAL's top by it), mint tea a hot one's
	heat (Internal Chill), herbal tea both, for half as long.

	The items are data, three tables below, and everything here reads them:
	  ITEMS        a full item -> { drink, empty?, sips? }: what drinking it gives, the empty
	               container drinking it leaves (nil: nothing, it is used up), and `sips`: true for
	               a canteen (the item's `durability` is its sips; each wears it, the last leaves
	               `empty`), else one item is one drink (a bottle: the stack shrinks by one and
	               `empty` comes back);
	  FILLS        an empty container -> the full item it becomes at a water source (its dirty
	               water). A `sips` item that is the dirty water of its own container (the Dirty
	               Water Canteen) is topped up at water while it has sips missing; a purified one
	               never is (it would be dirtied);
	  PURIFIED_OF  dirty water -> its purified twin (`purifiedOf`; `isDirty` is being a key here).
	               Purifying itself is a recipe's (Crafting/Recipes: smelting, or anything else
	               that turns one into the other).
	Both sides read this module, so entries go into the tables here (they are frozen), never at
	run time. A new container is four entries and its recipes, as the wooden bowls (ItemList Bowl,
	DirtyWaterBowl, PurifiedWaterBowl) are:
	    ITEMS        [I.DirtyWaterBowl] = { drink = Drinks.DIRTY_BOWL, empty = I.Bowl },
	                 [I.PurifiedWaterBowl] = { drink = Drinks.PURIFIED_BOWL, empty = I.Bowl },
	    FILLS        [I.Bowl] = I.DirtyWaterBowl,
	    PURIFIED_OF  [I.DirtyWaterBowl] = I.PurifiedWaterBowl,
	    Recipes      smelt("DirtyWaterBowl", "PurifiedWaterBowl") and the mint cure
	                 (mix({ "DirtyWaterBowl", "MintLeaves" }, "PurifiedWaterBowl"))
	and a bowl then fills at water, is drunk by holding the use button, gives its Bowl back, and
	purifies in a furnace or with mint, as a bottle does. A drink that is no water (the teas) is
	an ITEMS entry with a Drink of its own and the container it leaves: Mint Tea is { drink =
	Drinks.MINT_TEA, empty = I.Bowl }, MINT_TEA carrying `chill = 2400`. The load checks below
	assert that every named item is a drink where it must be one.

	Using an item (`action`, right click; Minecraft's Item.use after a block's own use):
	  an empty container (FILLS)   at a water source: fill (BottleItem: a ray that stops at
	                               sources)
	  a dirty canteen              at a water source with sips missing: fill again; else drink
	  a full item (ITEMS)          drink (a purified canteen is never dirtied by accident)
	  empty hand                   at a water source: a sip (instant, at most one per
	                               HAND_INTERVAL)
	Drinking an item takes USE_TICKS (32, PotionItem.getUseDuration) of holding the button, and
	(`drinkable`) only while thirsty with thirst on (creative: always, Thirst.canDrink), except a
	drink that tempers (`tempers`: Internal Warmth or Chill, the teas), which is drunk for that
	whenever temperature is on, thirsty or not, thirst on or off (as Minecraft's potions and
	honey, drunk whatever the hunger: ItemUtils.startUsingInstantly); with thirst off it gives
	only its warmth or chill (`apply` without a thirst state). Then (`afterDrinking`):
	  one drink   one is used up and its empty container comes back (PotionItem.finishUsingItem:
	              it replaces the stack when it was the last, else it goes into the inventory);
	  sips        a sip wears it (its `damage`); the last sip leaves the empty container.
	Creative players (instabuild) drink without using anything up, as Minecraft's.
	Filling (`fill`) is ItemUtils.createFilledResult: one empty container is used up and the full
	one replaces the stack when it was the last, else goes into the inventory; creative players
	keep the empty one and get a full one only when they have none.
]]

local Fluids = require(script.Parent.Parent.Fluids)
local Items = require(script.Parent.Parent.Items)
local Thirst = require(script.Parent.Thirst)
local Temperature = require(script.Parent.Temperature)

type Stack = Items.Stack

export type Drink = {
	-- Thirst points and hydration modifier (Thirst.drink).
	thirst: number,
	hydration: number,
	-- Chance (0..1) of TAN's Thirst effect, and its ticks.
	chance: number,
	effectTicks: number,
	-- Ticks of TAN's Internal Warmth / Internal Chill it gives (Temperature.giveWarmth /
	-- giveChill; nil: none).
	warmth: number?,
	chill: number?,
}

-- A full item (ITEMS, see the header).
export type DrinkItem = {
	drink: Drink,
	-- The empty container drinking it leaves (nil: nothing).
	empty: number?,
	-- Drunk in sips, the item's `durability` many (a canteen).
	sips: boolean?,
}

-- What a use does: "fill", "drink", "hand" (a sip from a water source) or nil (nothing).
export type Action = "fill" | "drink" | "hand"

local Drinks = {}

Drinks.HAND = table.freeze({ thirst = 1, hydration = 0.1, chance = 0.5, effectTicks = 300 }) :: Drink
Drinks.DIRTY = table.freeze({ thirst = 4, hydration = 0.25, chance = 0.5, effectTicks = 300 }) :: Drink
Drinks.PURIFIED = table.freeze({ thirst = 6, hydration = 0.4, chance = 0, effectTicks = 0 }) :: Drink
Drinks.DIRTY_BOWL = table.freeze({ thirst = 4, hydration = 0.3, chance = 0.5, effectTicks = 300 }) :: Drink
Drinks.PURIFIED_BOWL = table.freeze({ thirst = 7, hydration = 0.45, chance = 0, effectTicks = 0 }) :: Drink
-- The teas (a purified water bowl brewed with a herb): Internal Chill, Internal Warmth or both.
Drinks.MINT_TEA = table.freeze({ thirst = 7, hydration = 0.6, chance = 0, effectTicks = 0, chill = 2400 }) :: Drink
Drinks.GINGER_TEA = table.freeze({ thirst = 7, hydration = 0.6, chance = 0, effectTicks = 0, warmth = 2400 }) :: Drink
Drinks.HERBAL_TEA = table.freeze({
	thirst = 8,
	hydration = 0.65,
	chance = 0,
	effectTicks = 0,
	warmth = 1200,
	chill = 1200,
}) :: Drink

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

-- The full items (see the header).
Drinks.ITEMS = table.freeze({
	[I.DirtyWaterBottle] = table.freeze({ drink = Drinks.DIRTY, empty = I.GlassBottle }),
	[I.PurifiedWaterBottle] = table.freeze({ drink = Drinks.PURIFIED, empty = I.GlassBottle }),
	[I.DirtyWaterCanteen] = table.freeze({ drink = Drinks.DIRTY, empty = I.Canteen, sips = true }),
	[I.PurifiedWaterCanteen] = table.freeze({ drink = Drinks.PURIFIED, empty = I.Canteen, sips = true }),
	[I.DirtyWaterBowl] = table.freeze({ drink = Drinks.DIRTY_BOWL, empty = I.Bowl }),
	[I.PurifiedWaterBowl] = table.freeze({ drink = Drinks.PURIFIED_BOWL, empty = I.Bowl }),
	[I.MintTea] = table.freeze({ drink = Drinks.MINT_TEA, empty = I.Bowl }),
	[I.GingerTea] = table.freeze({ drink = Drinks.GINGER_TEA, empty = I.Bowl }),
	[I.HerbalTea] = table.freeze({ drink = Drinks.HERBAL_TEA, empty = I.Bowl }),
} :: { [number]: DrinkItem })

-- Empty containers and the full item each becomes at a water source.
Drinks.FILLS = table.freeze({
	[I.GlassBottle] = I.DirtyWaterBottle,
	[I.Canteen] = I.DirtyWaterCanteen,
	[I.Bowl] = I.DirtyWaterBowl,
} :: { [number]: number })

-- Dirty water and its purified twin.
Drinks.PURIFIED_OF = table.freeze({
	[I.DirtyWaterBottle] = I.PurifiedWaterBottle,
	[I.DirtyWaterCanteen] = I.PurifiedWaterCanteen,
	[I.DirtyWaterBowl] = I.PurifiedWaterBowl,
} :: { [number]: number })

-- (Mistakes in the tables would only show as items that do nothing: catch them at load.)
local function itemName(item: number): string
	local def = Items.get(item)
	return if def then def.name else tostring(item)
end
for item, entry in Drinks.ITEMS do
	assert(Items.get(item), `Drinks.ITEMS has an unknown item {item}`)
	assert(entry.empty == nil or Items.get(entry.empty), `{itemName(item)}'s empty container is no item`)
	local def = Items.get(item)
	assert(not entry.sips or (def and def.durability), `{itemName(item)} is drunk in sips but has no durability`)
end
for empty, full in Drinks.FILLS do
	assert(Items.get(empty), `Drinks.FILLS has an unknown item {empty}`)
	assert(Drinks.ITEMS[full], `{itemName(empty)} fills with {itemName(full)}, which is no drink`)
end
for dirty, purified in Drinks.PURIFIED_OF do
	assert(Drinks.ITEMS[dirty] and Drinks.ITEMS[purified], `{itemName(dirty)} or its purified twin is no drink`)
end

-- The full item entry of `item` (nil: it is no drink).
function Drinks.entry(item: number?): DrinkItem?
	return if item then Drinks.ITEMS[item] else nil
end

-- What drinking `item` gives (nil: it is no drink).
function Drinks.of(item: number?): Drink?
	local entry = Drinks.entry(item)
	return if entry then entry.drink else nil
end

-- Is `item` drunk by holding the use button (a filled bottle or canteen)?
function Drinks.isDrink(item: number?): boolean
	return Drinks.entry(item) ~= nil
end

-- The empty container drinking `item` leaves (nil: none, or no drink).
function Drinks.emptyOf(item: number?): number?
	local entry = Drinks.entry(item)
	return if entry then entry.empty else nil
end

-- Does `drink` temper the body (Internal Warmth or Chill: the teas)?
function Drinks.tempers(drink: Drink?): boolean
	return drink ~= nil and ((drink.warmth or 0) > 0 or (drink.chill or 0) > 0)
end

--[[
	May `drink` be drunk now (see the header)? `thirsty`: Thirst.canDrink (thirsty, or
	invulnerable); `thirstOn` / `temperatureOn`: Config.ToughAsNails' switches.
]]
function Drinks.drinkable(drink: Drink?, thirsty: boolean, thirstOn: boolean, temperatureOn: boolean): boolean
	if drink == nil then
		return false
	end
	return (thirstOn and thirsty) or (temperatureOn and Drinks.tempers(drink))
end

-- Is `item` an empty container that fills at water?
function Drinks.isContainer(item: number?): boolean
	return item ~= nil and Drinks.FILLS[item] ~= nil
end

-- Is `item` dirty water (it has a purified twin)?
function Drinks.isDirty(item: number?): boolean
	return item ~= nil and Drinks.PURIFIED_OF[item] ~= nil
end

-- The purified twin of dirty water `item` (nil: it is no dirty water).
function Drinks.purifiedOf(item: number?): number?
	return if item then Drinks.PURIFIED_OF[item] else nil
end

-- Does a right click with `item` do anything here (drink, or fill at water)?
function Drinks.isWaterItem(item: number?): boolean
	return Drinks.isContainer(item) or Drinks.isDrink(item)
end

-- Is `block` a water source a bottle or a hand drinks from (Minecraft's ClipContext SOURCE_ONLY
-- water)?
function Drinks.isWaterSource(block: number?): boolean
	return block ~= nil and Fluids.isSource(block) and Fluids.ofBlock(block) == Fluids.WATER
end

-- Is `item` drunk in sips and topped up at water (the dirty water of its own container)?
local function refills(item: number): boolean
	local entry = Drinks.ITEMS[item]
	return entry ~= nil and entry.sips == true and entry.empty ~= nil and Drinks.FILLS[entry.empty] == item
end

-- Would `stack` be filled at a water source (see the header)?
function Drinks.fills(stack: Stack?): boolean
	if stack == nil then
		return false
	end
	local item = stack.item
	return Drinks.isContainer(item) or (refills(item) and (stack.damage or 0) > 0)
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

-- The full item `stack` becomes at water (nil: it fills to nothing).
function Drinks.filledOf(stack: Stack): number?
	local item = stack.item
	local full = Drinks.FILLS[item]
	if full then
		return full
	end
	return if refills(item) then item else nil
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
	The held stack after drinking it (see the header), and a stack to give besides (the empty
	container of one drink that was not the last).
]]
function Drinks.afterDrinking(stack: Stack, creative: boolean): (Stack?, Stack?)
	local entry = Drinks.entry(stack.item)
	if creative or entry == nil then
		return stack, nil
	end
	local empty: Stack? = if entry.empty then { item = entry.empty, count = 1 } else nil
	if entry.sips then
		local def = Items.get(stack.item)
		local durability = if def then def.durability or 1 else 1
		local damage = (stack.damage or 0) + 1
		if damage >= durability then
			return empty, nil
		end
		return { item = stack.item, count = 1, damage = damage }, nil
	end
	if stack.count <= 1 then
		return empty, nil
	end
	return Items.withCount(stack, stack.count - 1), empty
end

-- Sips left in a stack drunk in sips (0 for anything else).
function Drinks.sips(stack: Stack?): number
	local entry = if stack then Drinks.entry(stack.item) else nil
	if stack == nil or entry == nil or not entry.sips then
		return 0
	end
	local def = Items.get(stack.item)
	return math.max(0, (if def then def.durability or 0 else 0) - (stack.damage or 0))
end

--[[
	Drinks `drink` into a thirst state (ToughAsNails/Thirst; nil while thirst is off: no water,
	no Thirst effect) with `random` (0..1, the effect's roll), and with the body's `temperature`
	state its Internal Warmth or Chill: returns whether the Thirst effect was given.
]]
function Drinks.apply(
	thirst: Thirst.State?,
	drink: Drink,
	random: () -> number,
	temperature: Temperature.State?
): boolean
	if thirst then
		Thirst.drink(thirst, drink.thirst, drink.hydration)
	end
	if temperature then
		if drink.warmth and drink.warmth > 0 then
			Temperature.giveWarmth(temperature, drink.warmth)
		end
		if drink.chill and drink.chill > 0 then
			Temperature.giveChill(temperature, drink.chill)
		end
	end
	if thirst and drink.chance > 0 and random() < drink.chance then
		Thirst.giveEffect(thirst, drink.effectTicks)
		return true
	end
	return false
end

return Drinks
