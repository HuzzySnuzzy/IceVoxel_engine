--!strict
--[[
	Tough As Nails' herbs in the Minecraft pack's biomes: overrides adding each biome's
	`foliage.herbs` (an override patches a biome's foliage field by field, so the grass and flowers
	stay the Minecraft pack's; Content/Schema's BIOME_FIELDS).

	Herbs (Tough As Nails' water and teas): mint, the cooling herb that also purifies water, on the
	plains, in meadows and jungles (the warm and temperate grass; the game has no swamps or river
	biomes for it); wild ginger, the warming one, under the trees of forests and taigas, so the
	colder biomes have theirs. Rare small patches: 0.4% of the open ground, in patches of 4 or so
	herbs about 30 blocks apart on open ground (fewer under trees; tests/spec/Herbs counts them).
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

local MINT: Schema.PlantPatches = { chance = 0.004, cover = 0.04, species = { { "Mint", 1 } } }
local GINGER: Schema.PlantPatches = { chance = 0.004, cover = 0.04, species = { { "WildGinger", 1 } } }

return {
	{ name = "Taiga", override = true, foliage = { herbs = GINGER } },
	{ name = "Plains", override = true, foliage = { herbs = MINT } },
	{ name = "Forest", override = true, foliage = { herbs = GINGER } },
	{ name = "BirchForest", override = true, foliage = { herbs = GINGER } },
	{ name = "Jungle", override = true, foliage = { herbs = MINT } },
	{ name = "OldGrowthTaiga", override = true, foliage = { herbs = GINGER } },
	{ name = "Meadow", override = true, foliage = { herbs = MINT } },
} :: { any }
