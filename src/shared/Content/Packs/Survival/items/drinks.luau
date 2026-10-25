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
	    potions and the Terraria pack's mana potions are drunk from it too.
	  * Bowls (Minecraft's wooden Bowl: three planks in a V make four) as water containers: filled
	    at a water source into a Dirty Water Bowl, purified in a furnace or with Mint Leaves into a
	    Purified Water Bowl, and brewed with a herb into a tea (Mint Tea, Ginger Tea, Herbal Tea
	    with both). Drinking one gives the Bowl back. Filled bowls stack to 16 like the filled
	    bottles; teas to 1, like Minecraft's stews. A brown bowl with a darker foot; filled, the
	    drink's top over its rim (murky, clear blue, the teas' pale green, amber and gold), with a
	    leaf or a slice of root floating on a tea (the pack's _models).
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
		},
		{
			name = "DirtyWaterBottle",
			maxStack = 16,
			color = DIRTY_WATER,
			material = "Glass",
			model = bottle(DIRTY_WATER),
		},
		{
			name = "PurifiedWaterBottle",
			maxStack = 16,
			color = PURIFIED_WATER,
			material = "Glass",
			model = bottle(PURIFIED_WATER),
		},
		{
			name = "Canteen",
			maxStack = 1,
			color = models.CANTEEN,
			material = "Metal",
			model = canteen({ 58, 58, 62 }),
		},
		{
			name = "DirtyWaterCanteen",
			durability = 3,
			color = DIRTY_WATER,
			material = "Metal",
			model = canteen(DIRTY_WATER),
		},
		{
			name = "PurifiedWaterCanteen",
			durability = 3,
			color = PURIFIED_WATER,
			material = "Metal",
			model = canteen(PURIFIED_WATER),
		},
		{ name = "Bowl", color = models.BOWL, material = "Wood", model = bowl(nil) },
		{
			name = "DirtyWaterBowl",
			maxStack = 16,
			color = DIRTY_WATER,
			material = "Wood",
			model = bowl(DIRTY_WATER),
		},
		{
			name = "PurifiedWaterBowl",
			maxStack = 16,
			color = PURIFIED_WATER,
			material = "Wood",
			model = bowl(PURIFIED_WATER),
		},
		{
			name = "MintTea",
			maxStack = 1,
			color = MINT_TEA,
			material = "Wood",
			model = bowl(MINT_TEA, { MINT_FLOAT }),
		},
		{
			name = "GingerTea",
			maxStack = 1,
			color = GINGER_TEA,
			material = "Wood",
			model = bowl(GINGER_TEA, { GINGER_FLOAT }),
		},
		{
			name = "HerbalTea",
			maxStack = 1,
			color = HERBAL_TEA,
			material = "Wood",
			model = bowl(HERBAL_TEA, { MINT_FLOAT, GINGER_FLOAT }),
		},
	}
end
