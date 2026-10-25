--!strict
--[[
	Content/Define's brewing (Content/Define lists it): what a potion (the `potions` kind, Content/
	Schema's POTION_FIELDS) makes. Content brews every potion with `brew` as packs load, its items
	after its pack's items and their recipes after its pack's recipes; Shared/Effects/PotionList
	gives its `variants` to the game (ToughAsNails/Drinks: what drinking one gives).

	Minecraft 1.20.1's brewing in a crafting grid (the game has no brewing stand), shapeless, the
	inventory's 2 x 2 too: a potion is BASE, a Purified Water Bottle (the Survival pack's), with
	its `ingredient`; its strong variant (level II) is the potion with STRONG, Glow Dust (the
	Minecraft pack's: the game's glowstone), and its long one the potion with LONG, a coal or
	charcoal (the game has no redstone). Drinking one leaves EMPTY, its Glass Bottle.

	  variants(potion)       its items in order: the base potion, the strong one, the long one (the
	                         ones it has), each a Variant: its item, name, effect, ticks and
	                         amplifier, what it is brewed from and with, and which variant it is
	  brew(potion, colour)   { items, recipes }: its items (Define/Items' `potion`, the bottle's
	                         liquid in `colour`, its effect's; each one's lore, icon and Age from
	                         the potion's `lore`, `icon` and `age`, a blank icon when it gives
	                         none; its `drink`: the variant's effect, ticks and level, no water,
	                         the EMPTY bottle back) and their recipes
]]

local Items = require(script.Parent.Items)
local Recipes = require(script.Parent.Recipes)
local Schema = require(script.Parent.Parent.Schema)

type ItemSpec = Schema.ItemSpec
type Recipe = Schema.Recipe
type PotionSpec = Schema.PotionSpec

-- One potion item: its item name, what it is shown as, and what drinking it gives.
export type Variant = {
	item: string,
	displayName: string,
	effect: string,
	-- Ticks (an instant effect: 1) and amplifier.
	ticks: number,
	amplifier: number,
	-- The item it is brewed from and with (the base: BASE and the potion's `ingredient`).
	from: string,
	with: string,
	-- Which variant it is: "base", "strong" or "long" (its key in the potion's lore, icon, age).
	form: string,
	potion: PotionSpec,
}

local Potions = {}

-- What every potion is brewed from, what makes the strong and long variants, and the bottle
-- drinking one leaves.
Potions.BASE = "PurifiedWaterBottle"
Potions.STRONG = "GlowDust"
Potions.LONG = "#coals"
Potions.EMPTY = "GlassBottle"

local TICKS_PER_SECOND = 20

function Potions.variants(potion: PotionSpec): { Variant }
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
			from = Potions.BASE,
			with = potion.ingredient,
			form = "base",
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
			with = Potions.STRONG,
			form = "strong",
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
			with = Potions.LONG,
			form = "long",
			potion = potion,
		})
	end
	return variants
end

function Potions.brew(potion: PotionSpec, colour: { number }): { items: { ItemSpec }, recipes: { Recipe } }
	local items: { ItemSpec } = {}
	local recipes: { Recipe } = {}
	for _, variant in Potions.variants(potion) do
		local form = variant.form
		local lore, icon, age = potion.lore, potion.icon, potion.age
		table.insert(
			items,
			Items.potion(variant, colour, {
				lore = lore and (lore :: any)[form],
				icon = icon and (icon :: any)[form] or "",
				age = age and (age :: any)[form],
				drink = {
					effects = { { effect = variant.effect, ticks = variant.ticks, amplifier = variant.amplifier } },
					empty = Potions.EMPTY,
				},
			})
		)
		table.insert(recipes, Recipes.shapeless({ variant.from, variant.with }, variant.item))
	end
	return { items = items, recipes = recipes }
end

return Potions
