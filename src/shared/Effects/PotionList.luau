--!strict
--[[
	The potions (Minecraft 1.20.1's Potions, brewed here in a crafting grid: the game has no
	brewing stand). Pure data that requires nothing, read by ItemList (the potion items, in this
	order, so: ALWAYS ADD NEW POTIONS AT THE END, and new variants of a potion never, as the item
	ids are list positions), Crafting/Recipes (the brewing) and ToughAsNails/Drinks (drinking them:
	the 32 tick hold, the effects given when it finishes, the Glass Bottle back).

	A potion is a Purified Water Bottle brewed with its `ingredient` (shapeless, any grid; an item
	or block name, or a recipe "#tag"), giving `effect` (an EffectList name) for `seconds` (nil:
	an instant effect) at level I. Its variants, each an item of its own:
	  strong  Glow Dust (the game's glowstone) brewed into it: level II for `strong` seconds
	          (true for an instant effect's II): "Potion of Swiftness II"
	  long    a coal or charcoal (the game has no redstone) brewed into it: level I for `long`
	          seconds: "Long Potion of Swiftness"
	Minecraft's numbers: 3:00, II 1:30, long 8:00 for most; Poison and Regeneration 0:45, II 0:21.6
	and 0:22.5, long 1:30; Weakness 1:30, long 4:00. The ingredients are what the game has:
	Minecraft's own where it has them (Glow Dust for glowstone), else the flower that gives the
	effect in Minecraft's suspicious stew (Cornflower: Jump Boost, Oxeye Daisy: Regeneration, Lily
	of the Valley: Poison, tulips: Weakness), else something fitting (Mint Leaves quicken, Ginger
	Root warms against fire, a Gold Nugget heals as the glistering melon does, a Red Mushroom
	harms, Gunpowder for blaze powder). Haste and Resistance are this game's potions (Minecraft has
	none): a Gold Ingot (gold tools are the fastest) and an Iron Ingot.
]]

export type PotionSpec = {
	name: string,
	displayName: string?,
	ingredient: string,
	effect: string,
	seconds: number?,
	strong: (number | boolean)?,
	long: number?,
}

-- One potion item: its ItemList name, what it is shown as, and what drinking it gives.
export type Variant = {
	item: string,
	displayName: string,
	effect: string,
	-- Ticks (an instant effect: 1) and amplifier.
	ticks: number,
	amplifier: number,
	-- The item it is brewed from and with (the base: the Purified Water Bottle and `ingredient`).
	from: string,
	with: string,
	potion: PotionSpec,
}

local list: { PotionSpec } = {
	{ name = "Swiftness", ingredient = "MintLeaves", effect = "Speed", seconds = 180, strong = 90, long = 480 },
	{ name = "Leaping", ingredient = "Cornflower", effect = "JumpBoost", seconds = 180, strong = 90, long = 480 },
	{ name = "Strength", ingredient = "Gunpowder", effect = "Strength", seconds = 180, strong = 90, long = 480 },
	{ name = "Healing", ingredient = "GoldNugget", effect = "InstantHealth", strong = true },
	{ name = "Harming", ingredient = "RedMushroom", effect = "InstantDamage", strong = true },
	{ name = "Poison", ingredient = "LilyOfTheValley", effect = "Poison", seconds = 45, strong = 21.6, long = 90 },
	{
		name = "Regeneration",
		ingredient = "OxeyeDaisy",
		effect = "Regeneration",
		seconds = 45,
		strong = 22.5,
		long = 90,
	},
	{
		name = "FireResistance",
		displayName = "Fire Resistance",
		ingredient = "GingerRoot",
		effect = "FireResistance",
		seconds = 180,
		long = 480,
	},
	{
		name = "NightVision",
		displayName = "Night Vision",
		ingredient = "GlowDust",
		effect = "NightVision",
		seconds = 180,
		long = 480,
	},
	{ name = "Weakness", ingredient = "#tulips", effect = "Weakness", seconds = 90, long = 240 },
	{ name = "Haste", ingredient = "GoldIngot", effect = "Haste", seconds = 180, strong = 90 },
	{ name = "Resistance", ingredient = "IronIngot", effect = "Resistance", seconds = 90, strong = 45 },
}

-- Add new potions above this line, at the end (never reorder: the item ids follow this order).

local PotionList = {}

PotionList.list = list
-- What every potion is brewed from, and what makes the strong and long variants.
PotionList.BASE = "PurifiedWaterBottle"
PotionList.STRONG_INGREDIENT = "GlowDust"
PotionList.LONG_INGREDIENT = "#coals"
-- The bottle drinking a potion leaves.
PotionList.EMPTY = "GlassBottle"

local TICKS_PER_SECOND = 20

--[[
	The potion items of `potion`, in ItemList's order: the base, the strong one, the long one (those
	it has).
]]
function PotionList.variants(potion: PotionSpec): { Variant }
	local shown = potion.displayName or potion.name
	local base = `PotionOf{potion.name}`
	local instant = potion.seconds == nil
	local variants: { Variant } = {
		{
			item = base,
			displayName = `Potion of {shown}`,
			effect = potion.effect,
			ticks = if instant then 1 else math.round((potion.seconds :: number) * TICKS_PER_SECOND),
			amplifier = 0,
			from = PotionList.BASE,
			with = potion.ingredient,
			potion = potion,
		},
	}
	local strong = potion.strong
	if strong then
		table.insert(variants, {
			item = `StrongPotionOf{potion.name}`,
			displayName = `Potion of {shown} II`,
			effect = potion.effect,
			ticks = if type(strong) == "number" then math.round(strong * TICKS_PER_SECOND) else 1,
			amplifier = 1,
			from = base,
			with = PotionList.STRONG_INGREDIENT,
			potion = potion,
		})
	end
	if potion.long then
		table.insert(variants, {
			item = `LongPotionOf{potion.name}`,
			displayName = `Long Potion of {shown}`,
			effect = potion.effect,
			ticks = math.round(potion.long * TICKS_PER_SECOND),
			amplifier = 0,
			from = base,
			with = PotionList.LONG_INGREDIENT,
			potion = potion,
		})
	end
	return variants
end

-- Every potion item, in ItemList's order.
function PotionList.all(): { Variant }
	local all: { Variant } = {}
	for _, potion in list do
		for _, variant in PotionList.variants(potion) do
			table.insert(all, variant)
		end
	end
	return all
end

return PotionList
