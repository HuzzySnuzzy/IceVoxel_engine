--!strict
--[[
	Tough As Nails' water and teas (Shared/ToughAsNails/Drinks).

	  * Minecraft's Glass Bottle (Content/Define's `bottle`), filled at a water source into TAN's
	    Dirty Water Bottle, which a furnace purifies (the Purified Water Bottle); and the Canteen,
	    TAN's leather canteen made of iron here (the game has no leather), filled at water with three
	    sips of dirty water (its `durability`: each sip wears it, the last one leaves the empty
	    Canteen), purified the same way. The water shows through the front of the glass and in the
	    canteen's round window, murky green-brown when dirty, clear blue when purified. Filled
	    bottles stack to 16 (Minecraft's honey bottles), so a furnace purifies a stack in one go.
	    The Glass Bottle is here, with the water that came with it, though the Minecraft pack's
	    potions and the Terraria pack's mana potions are drunk from it too. The Canteen is the Iron
	    Age's.
	  * Bowls (Minecraft's wooden Bowl: three planks in a V make four) as water containers: filled
	    at a water source into a Dirty Water Bowl, purified in a furnace or with Mint Leaves into a
	    Purified Water Bowl, and brewed with a herb into a tea (Mint Tea, Ginger Tea, Herbal Tea
	    with both). Drinking one gives the Bowl back. Filled bowls stack to 16 like the filled
	    bottles; teas to 1, like Minecraft's stews. A brown bowl with a darker foot; filled, the
	    drink's top over its rim (murky, clear blue, the teas' pale green, amber and gold), with a
	    leaf or a slice of root floating on a tea (the pack's _models). An empty bowl burns 100
	    ticks as furnace fuel (Minecraft's).
	What each one gives when drunk is ToughAsNails/Drinks' (its tooltip's "When drunk:" lines);
	their icons are blank, so each look is one id to paste.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)
local models = require(script.Parent.Parent._models)

type ModelBox = Schema.ModelBox

local DIRTY_WATER = { 98, 116, 74 }
local PURIFIED_WATER = { 64, 140, 236 }
local MINT = { 92, 176, 84 }
local GINGER = { 206, 168, 112 }
local MINT_TEA = { 150, 198, 116 }
local GINGER_TEA = { 214, 158, 70 }
local HERBAL_TEA = { 186, 168, 82 }
local MINT_FLOAT: ModelBox = { size = { 3, 0.6, 1.6 }, offset = { -2.5, 3.4, 1.2 }, rotation = 10, color = MINT }
local GINGER_FLOAT: ModelBox = { size = { 2.2, 0.6, 2.2 }, offset = { 2.5, 3.4, 1.2 }, color = GINGER }

return function(define: Define.Context): { Schema.ItemSpec }
	local bottle, canteen, bowl = define.bottle, models.canteen, models.bowl
	return {
		{
			name = "GlassBottle",
			color = define.GLASS,
			material = "Glass",
			model = bottle(nil),
			icon = "",
			lore = "Fill it at water for a drink.",
		},
		{
			name = "DirtyWaterBottle",
			maxStack = 16,
			color = DIRTY_WATER,
			material = "Glass",
			model = bottle(DIRTY_WATER),
			icon = "",
			lore = "Unsafe to drink. Purify it in a furnace, on a campfire or with mint.",
		},
		{
			name = "PurifiedWaterBottle",
			maxStack = 16,
			color = PURIFIED_WATER,
			material = "Glass",
			model = bottle(PURIFIED_WATER),
			icon = "",
			lore = "Clean water. Also the base of every potion.",
		},
		{
			name = "Canteen",
			maxStack = 1,
			color = models.CANTEEN,
			material = "Metal",
			model = canteen({ 58, 58, 62 }),
			icon = "",
			lore = "Fill it at water. Holds several sips.",
			age = "iron",
		},
		{
			name = "DirtyWaterCanteen",
			durability = 3,
			color = DIRTY_WATER,
			material = "Metal",
			model = canteen(DIRTY_WATER),
			icon = "",
			lore = "Unsafe to drink. Purify it, or top it up at water.",
		},
		{
			name = "PurifiedWaterCanteen",
			durability = 3,
			color = PURIFIED_WATER,
			material = "Metal",
			model = canteen(PURIFIED_WATER),
			icon = "",
			lore = "Clean water, a few sips at a time.",
		},
		{
			name = "Bowl",
			color = models.BOWL,
			material = "Wood",
			model = bowl(nil),
			icon = "",
			lore = "Fill it at water. Holds a little more than a bottle.",
			fuel = 100,
		},
		{
			name = "DirtyWaterBowl",
			maxStack = 16,
			color = DIRTY_WATER,
			material = "Wood",
			model = bowl(DIRTY_WATER),
			icon = "",
			lore = "Unsafe to drink. Purify it in a furnace, on a campfire or with mint.",
		},
		{
			name = "PurifiedWaterBowl",
			maxStack = 16,
			color = PURIFIED_WATER,
			material = "Wood",
			model = bowl(PURIFIED_WATER),
			icon = "",
			lore = "Clean water. Brew a herb into it for tea.",
		},
		{
			name = "MintTea",
			maxStack = 1,
			color = MINT_TEA,
			material = "Wood",
			model = bowl(MINT_TEA, { MINT_FLOAT }),
			icon = "",
			lore = "A cooling brew for hot places.",
		},
		{
			name = "GingerTea",
			maxStack = 1,
			color = GINGER_TEA,
			material = "Wood",
			model = bowl(GINGER_TEA, { GINGER_FLOAT }),
			icon = "",
			lore = "A warming brew for cold places.",
		},
		{
			name = "HerbalTea",
			maxStack = 1,
			color = HERBAL_TEA,
			material = "Wood",
			model = bowl(HERBAL_TEA, { MINT_FLOAT, GINGER_FLOAT }),
			icon = "",
			lore = "Mint and ginger together: steadies you in heat and cold.",
		},
	}
end
