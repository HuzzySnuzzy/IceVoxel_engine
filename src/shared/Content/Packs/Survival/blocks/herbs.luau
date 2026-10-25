--!strict
--[[
	Herbs (Tough As Nails' water and teas, Shared/ToughAsNails/Drinks): Mint, the menthol herb whose
	leaves purify dirty water and brew a cooling tea, and Wild Ginger, whose root brews a warming
	one. Plants like the flowers (Content/Define's `herb`: the dirt soil set, broken at once, washed
	away, popping off with their soil), but no item of their own: breaking one drops its herb item
	(Mint Leaves, Ginger Root), which plants it back (its `places`, Minecraft's
	ItemNameBlockItem: sweet berries and their bush), one for one, so nothing is gained by
	replanting. They spread slowly instead, as Minecraft's mushrooms do (server Behaviours/Herb).
	Generation grows them in rare patches of their biomes (BiomeList `foliage.herbs`): mint on
	plains, meadows and in jungles, wild ginger in forests and taigas, so the cold biomes have their
	warming herb. Mint: a square stem with pairs of bright, crossed leaves and a pale tuft; wild
	ginger: two broad, dark heart-shaped leaves low over the ground and a maroon bud at their foot.
	They burn like flowers (60 / 100).
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

type Bounds = Schema.Bounds

local MINT_BOUNDS: Bounds = { min = { 4, 0, 4 }, max = { 12, 9, 12 } }
local GINGER_BOUNDS: Bounds = { min = { 3, 0, 3 }, max = { 13, 6, 13 } }
local MINT = { 92, 176, 84 }
local MINT_DARK = { 62, 140, 62 }
local MINT_LIGHT = { 150, 210, 128 }
local MINT_STEM = { 84, 124, 60 }
local GINGER_LEAF = { 50, 106, 44 }
local GINGER_LEAF_LIGHT = { 72, 128, 56 }
local GINGER_STALK = { 108, 96, 60 }

return function(define: Define.Context): { Schema.BlockSpec }
	local blade, leaf, lump, GROUND = define.blade, define.leaf, define.plantBox, define.GROUND
	return {
		define.herb("Mint", "Mint", MINT, {
			blade({ 0, GROUND, 0 }, { 0.8, 8, 0.8 }, 0, 0, MINT_STEM),
			lump({ 6.4, 0.6, 2.4 }, { 0, -5.2, 0 }, MINT_DARK, { 0, 20, 0 }),
			lump({ 2.4, 0.6, 5.6 }, { 0, -2.8, 0 }, MINT, { 0, 20, 0 }),
			lump({ 3, 1.8, 3 }, { 0, -0.4, 0 }, MINT_LIGHT, { 0, 65, 0 }),
		}, MINT_BOUNDS),
		define.herb("WildGinger", "Wild Ginger", GINGER_LEAF, {
			blade({ 0, GROUND, 0 }, { 0.6, 4, 0.6 }, 12, 120, GINGER_STALK),
			leaf({ 0, GROUND, 0 }, { 4, 5, 0.4 }, 62, 30, GINGER_LEAF),
			leaf({ 0, GROUND, 0 }, { 3.6, 4.4, 0.4 }, 56, 210, GINGER_LEAF_LIGHT),
			lump({ 1.4, 1.2, 1.4 }, { 0.6, -7.2, -0.5 }, { 112, 40, 46 }, { 0, 45, 0 }),
		}, GINGER_BOUNDS),
	}
end
