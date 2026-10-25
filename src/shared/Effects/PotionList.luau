--!strict
--[[
	The potions (Minecraft 1.20.1's Potions, brewed here in a crafting grid: the game has no
	brewing stand): the registry of the content packs' `potions` (Shared/Content; Content/Schema's
	POTION_FIELDS say what each field does). The Minecraft pack holds Minecraft's (its `potions`);
	a pack adds one by adding an entry to its own. Content brews every potion into its items, each
	with its `drink` (ToughAsNails/Drinks: the 32 tick hold, the effect given when it finishes, the
	Glass Bottle back), and their recipes as the packs load (Content/Define's `brew`), so a potion
	added in any pack has its items, its recipes, its drink and its tooltip with nothing else to
	write.

	A potion is a Purified Water Bottle (BASE) brewed with its `ingredient` (shapeless, any grid; an
	item or block name, or a recipe "#tag"), giving `effect` (an effect's name) for `seconds` (nil:
	an instant effect) at level I. Its variants, each an item of its own:
	  strong  Glow Dust (the game's glowstone: STRONG_INGREDIENT) brewed into it: level II for
	          `strong` seconds (true for an instant effect's II): "Potion of Swiftness II"
	  long    a coal or charcoal (the game has no redstone: LONG_INGREDIENT) brewed into it: level I
	          for `long` seconds: "Long Potion of Swiftness"

	  list                the potions, in load order (Content's merged entries)
	  variants(potion)    its items: the base, the strong one, the long one (those it has), each
	                      a Variant (its item, shown name, effect, ticks, amplifier, what it is
	                      brewed from and with)
	  all()               every potion's variants, in load order
	  BASE, STRONG_INGREDIENT, LONG_INGREDIENT, EMPTY   the brewing's items (Content/Define/
	                      Potions'), EMPTY the bottle drinking one leaves
]]

local Content = require(script.Parent.Parent.Content)
local Potions = require(script.Parent.Parent.Content.Define.Potions)
local Schema = require(script.Parent.Parent.Content.Schema)

export type PotionSpec = Schema.PotionSpec
-- One potion item: its item name, what it is shown as, and what drinking it gives.
export type Variant = Potions.Variant

local PotionList = {}

PotionList.list = Content.default.potions
-- What every potion is brewed from, and what makes the strong and long variants.
PotionList.BASE = Potions.BASE
PotionList.STRONG_INGREDIENT = Potions.STRONG
PotionList.LONG_INGREDIENT = Potions.LONG
-- The bottle drinking a potion leaves.
PotionList.EMPTY = Potions.EMPTY

--[[
	The potion items of `potion`, in its order: the base, the strong one, the long one (those it
	has).
]]
function PotionList.variants(potion: PotionSpec): { Variant }
	return Potions.variants(potion)
end

-- Every potion item, in the potions' order.
function PotionList.all(): { Variant }
	local all: { Variant } = {}
	for _, potion in PotionList.list do
		for _, variant in Potions.variants(potion) do
			table.insert(all, variant)
		end
	end
	return all
end

return PotionList
