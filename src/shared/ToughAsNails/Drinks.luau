--!strict
--[[
	What there is to drink and how containers fill (Tough As Nails), pure (no Roblox APIs, so the
	tests run it). The drinks are content pack items, each saying what drinking it gives on its
	entry, its `drink` (Content/Schema): the Survival pack's water and teas (items/drinks: the
	Glass Bottle, Dirty / Purified Water Bottle, Canteen, Dirty / Purified Water Canteen, Bowl,
	Dirty / Purified Water Bowl, Mint / Ginger / Herbal Tea, with a table of their numbers), the
	Apocalypse pack's Bottled Water and Soda (items/supplies), the Terraria pack's mana potions
	and every pack's potions (its `potions`, brewed into items with their drinks as the packs load:
	Content/Define's `brew`). Dirty water is purified in a furnace or with a mint leaf in a
	crafting grid, and a purified water bowl brews a tea with a herb (the Survival pack's recipes).

	A drink (Drink) gives `thirst` points and the `hydration` modifier (Thirst.drink adds thirst x
	modifier x 2), and rolls TAN's Thirst effect at `chance` for `effectTicks` (dirty water: 50%,
	15 s). The Thirst effect costs 0.015 exhaustion a tick, so 15 s of it is 4.5 exhaustion, about
	a point of hydration or thirst; a longer one already running stays, so sips in a row cost one
	effect. (TAN's own 75% and 30 s at 0.025 were too harsh for this game.) A sip from a water
	source with an empty hand is HAND: thirst 1, hydration 0.1, 50%, 15 s (TAN's hand drinking,
	Config.ToughAsNails.HandDrinking). A drink may also give TAN's Internal Warmth or Internal
	Chill (`warmth` / `chill` ticks, Temperature.giveWarmth / giveChill: the target 5 steps
	warmer or cooler, though not past NEUTRAL by it): `apply` gives them when it is handed the
	temperature state. Status effects (`effects`) or mana (`mana`) make it a potion (below). An
	entry leaves out the numbers it hasn't: they are 0.

	The items are data, their entries', made into three tables as this loads, which everything
	here reads:
	  ITEMS        a full item -> { drink, empty?, sips? }, each entry's `drink`:
	               what drinking it gives, the empty container drinking it leaves (`empty`, an item
	               name on the entry; nil: nothing, it is used up), and `sips`: true for a canteen
	               (the item's `durability` is its sips; each wears it, the last leaves `empty`),
	               else one item is one drink (a bottle: the stack shrinks by one and `empty` comes
	               back). Entries whose drinks are alike share one Drink: a bottle's and a
	               canteen's dirty water, purified water and the ruins' bottled water (client
	               Ui/Theme's "Water" pill goes by that);
	  FILLS        an empty container -> the full item it becomes at a water source (its dirty
	               water): each container entry's `fills`. A `sips` item that is the dirty water of
	               its own container (the Dirty Water Canteen) is topped up at water while it has
	               sips missing; a purified one never is (it would be dirtied);
	  PURIFIED_OF  dirty water -> its purified twin: each drink's `purified` (`purifiedOf`;
	               `isDirty` is being a key here; what a campfire boils it into,
	               ToughAsNails/Boiling). Purifying itself is a recipe's (Crafting/Recipes:
	               smelting, or anything else that turns one into the other).
	Both sides read this module, so drinks go on the entries (the tables are frozen), never at
	run time. A new container is three entries and its recipes, as the wooden bowls (the Survival
	pack's Bowl, DirtyWaterBowl, PurifiedWaterBowl) are:
	    Bowl               fills = "DirtyWaterBowl"
	    DirtyWaterBowl     drink = { thirst = 4, hydration = 0.3, chance = 0.5, effectTicks = 300,
	                                 empty = "Bowl", purified = "PurifiedWaterBowl" }
	    PurifiedWaterBowl  drink = { thirst = 7, hydration = 0.45, empty = "Bowl" }
	    recipes            smelting("DirtyWaterBowl", "PurifiedWaterBowl") and the mint cure
	                       (shapeless({ "DirtyWaterBowl", "MintLeaves" }, "PurifiedWaterBowl"))
	and a bowl then fills at water, is drunk by holding the use button, gives its Bowl back, and
	purifies in a furnace or with mint, as a bottle does. A drink that is no water (the teas) is
	an entry's `drink` of its own with the container it leaves: Mint Tea's is { thirst = 7,
	hydration = 0.6, chill = 2400, empty = "Bowl" }. The load checks below name the pack and the
	entry of an unknown effect or container, sips without a durability, a drink that does nothing,
	and a container filling with, or dirty water purified into, an item that is no drink
	(Shared/Content checks that the names are items).

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
	only its warmth or chill (`apply` without a thirst state). A potion (Shared/Effects/PotionList:
	a Drink with `effects`, no water) is drunk any time, Tough As Nails on or off, and its status
	effects are given when it finishes (server Players/ToughAsNails through Players/Effects:
	Minecraft's PotionItem.finishUsingItem; an instant effect acts on the next tick). Terraria's
	mana potions (Lesser Mana Potion 50, Mana Potion 100: a Drink with `mana`, no water) count as
	potions: drunk any time, their mana and Mana Sickness given when they finish (server
	Players/Mana.potion), a Glass Bottle back. Then (`afterDrinking`):
	  one drink   one is used up and its empty container comes back (PotionItem.finishUsingItem:
	              it replaces the stack when it was the last, else it goes into the inventory);
	  sips        a sip wears it (its `damage`); the last sip leaves the empty container.
	Creative players (instabuild) drink without using anything up, as Minecraft's.
	Filling (`fill`) is ItemUtils.createFilledResult: one empty container is used up and the full
	one replaces the stack when it was the last, else goes into the inventory; creative players
	keep the empty one and get a full one only when they have none.
]]

local Content = require(script.Parent.Parent.Content)
local Effects = require(script.Parent.Parent.Effects)
local Fluids = require(script.Parent.Parent.Fluids)
local Items = require(script.Parent.Parent.Items)
local Schema = require(script.Parent.Parent.Content.Schema)
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
	-- Status effects it gives (Shared/Effects ids; nil: none).
	effects: { PotionEffect }?,
	-- Mana it restores (Terraria's mana potions, Shared/Mana; nil: none). The server gives it with
	-- Mana Sickness when the drink finishes (Players/ToughAsNails through Players/Mana.potion).
	mana: number?,
}

-- A status effect a drink gives: an Effects id, its ticks and amplifier.
export type PotionEffect = { effect: number, ticks: number, amplifier: number }

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

-- A sip from a water source with an empty hand (see the header; no item gives it).
Drinks.HAND = table.freeze({ thirst = 1, hydration = 0.1, chance = 0.5, effectTicks = 300 }) :: Drink

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

-- (For drinks without effects.)
local NO_EFFECTS: { PotionEffect } = table.freeze({})

-- (A Drink's effects as one string, to tell alike drinks.)
local function effectsKey(effects: { PotionEffect }?): string
	local parts = {}
	for _, effect in effects or NO_EFFECTS do
		table.insert(parts, `{effect.effect}:{effect.ticks}:{effect.amplifier}`)
	end
	return table.concat(parts, ",")
end

-- Alike drinks share one Drink (see the header): a drink's numbers -> its Drink.
local alike: { [string]: Drink } = {}

-- `where`'s `drink` (an entry's, Content/Schema) as a Drink: numbers left out are 0, effect names
-- become ids; an alike one made before is that one.
local function fromEntry(spec: Schema.DrinkSpec, where: string): Drink
	local effects: { PotionEffect }? = nil
	if spec.effects then
		local list: { PotionEffect } = {}
		for _, given in spec.effects do
			local id = Effects.id[given.effect]
			assert(id, `Drinks: {where} gives an unknown effect {given.effect}`)
			table.insert(list, table.freeze({ effect = id, ticks = given.ticks, amplifier = given.amplifier or 0 }))
		end
		effects = table.freeze(list)
	end
	local drink: Drink = {
		thirst = spec.thirst or 0,
		hydration = spec.hydration or 0,
		chance = spec.chance or 0,
		effectTicks = spec.effectTicks or 0,
		warmth = spec.warmth,
		chill = spec.chill,
		effects = effects,
		mana = spec.mana,
	}
	local key = string.format(
		"%.17g %.17g %.17g %.17g %s %s %s %s",
		drink.thirst,
		drink.hydration,
		drink.chance,
		drink.effectTicks,
		tostring(drink.warmth),
		tostring(drink.chill),
		tostring(drink.mana),
		effectsKey(effects)
	)
	local made = alike[key]
	if made == nil then
		made = table.freeze(drink)
		alike[key] = made
	end
	return made
end

-- The full items (see the header): every content pack item's `drink`. (Mistakes would only show
-- as items that do nothing: catch them at load.)
local content = Content.default
local ITEMS: { [number]: DrinkItem } = {}
for _, spec in content.items do
	local own = spec.drink
	if own then
		local where = content.where("item", spec.name)
		local empty: number? = nil
		if own.empty then
			empty = Items.find(own.empty)
			assert(empty, `Drinks: {where}'s empty container {own.empty} is no item`)
		end
		assert(not own.sips or spec.durability, `Drinks: {where} is drunk in sips but has no durability`)
		local drink = fromEntry(own, where)
		assert(
			drink.thirst > 0
				or (drink.warmth or 0) > 0
				or (drink.chill or 0) > 0
				or #(drink.effects or NO_EFFECTS) > 0
				or (drink.mana or 0) > 0,
			`Drinks: {where} does nothing (no thirst, warmth, chill, effects or mana)`
		)
		ITEMS[Items.id[spec.name]] = table.freeze({ drink = drink, empty = empty, sips = own.sips })
	end
end
Drinks.ITEMS = table.freeze(ITEMS)

-- Empty containers and the full item each becomes at a water source (their entries' `fills`), and
-- dirty water and its purified twin (the drinks' `purified`). (Mistakes would only show as items
-- that do nothing: catch them at load.)
local FILLS: { [number]: number } = {}
local PURIFIED_OF: { [number]: number } = {}
for _, spec in content.items do
	local where = content.where("item", spec.name)
	if spec.fills then
		local full = Items.find(spec.fills)
		assert(full and Drinks.ITEMS[full], `Drinks: {where} fills with {spec.fills}, which is no drink`)
		FILLS[Items.id[spec.name]] = full
	end
	local purified = spec.drink and spec.drink.purified
	if purified then
		local twin = Items.find(purified)
		assert(twin and Drinks.ITEMS[twin], `Drinks: {where}'s purified twin {purified} is no drink`)
		PURIFIED_OF[Items.id[spec.name]] = twin
	end
end
Drinks.FILLS = table.freeze(FILLS)
Drinks.PURIFIED_OF = table.freeze(PURIFIED_OF)

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

-- Is `drink` a potion (it gives status effects, or mana: drunk any time, see the header)?
function Drinks.isPotion(drink: Drink?): boolean
	local effects = if drink then drink.effects else nil
	return (effects ~= nil and #effects > 0) or Drinks.manaOf(drink) > 0
end

-- Mana `drink` restores (0: none; Terraria's mana potions).
function Drinks.manaOf(drink: Drink?): number
	return if drink then drink.mana or 0 else 0
end

--[[
	May `drink` be drunk now (see the header)? `thirsty`: Thirst.canDrink (thirsty, or
	invulnerable); `thirstOn` / `temperatureOn`: Config.ToughAsNails' switches.
]]
function Drinks.drinkable(drink: Drink?, thirsty: boolean, thirstOn: boolean, temperatureOn: boolean): boolean
	if drink == nil then
		return false
	end
	return Drinks.isPotion(drink) or (thirstOn and thirsty) or (temperatureOn and Drinks.tempers(drink))
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
	if thirst and drink.thirst > 0 then
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
