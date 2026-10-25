--!strict
--[[
	The new ores' features (Generation/Ores' header says how each was mapped from Minecraft's,
	Mekanism's and Create's), after the Base pack's so every older ore keeps its veins: copper,
	lead, zinc, sulfur in the cave lava's band (and its vents, which Generation/Ores places), saltpetre
	under dry land, uranium small and buried.
]]

local Define = require(script.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Schema)

return function(define: Define.Context): { Schema.OreFeature }
	local lavaLevel = define.Config.Caves.LavaLevel
	return {
		-- Minecraft's copper: 8 per 128 blocks over 256 are its 16 veins per chunk.
		{
			name = "copper",
			block = "CopperOre",
			veins = 8,
			size = 10,
			minY = 48,
			maxY = 304,
			shape = "trapezoid",
		},
		-- Mekanism's lead: 4.5 per 128 blocks over 228 are its 8 veins per chunk (8.02).
		{
			name = "lead",
			block = "LeadOre",
			veins = 4.5,
			size = 9,
			minY = -31,
			maxY = 197,
			shape = "trapezoid",
		},
		-- Gold's 3 veins of 6 per 128 blocks in Create's veins of 12.
		{ name = "zinc", block = "ZincOre", veins = 1.5, size = 12, minY = 5, maxY = 197 },
		-- 12 per 128 blocks over 32 are 3 veins per chunk.
		{ name = "sulfur", block = "SulfurOre", veins = 12, size = 8, minY = 1, maxY = lavaLevel + 22 },
		-- 16 per 128 blocks of depth over 32 are 4 veins per chunk.
		{
			name = "saltpetre",
			block = "SaltpetreOre",
			veins = 16,
			size = 8,
			minY = 4,
			maxY = 36,
			depth = true,
			dry = true,
		},
		-- Mekanism's uranium at a quarter of its veins: 1 and 1.75 per chunk (ranges of 128).
		{
			name = "uranium_small",
			block = "UraniumOre",
			veins = 1,
			size = 4,
			minY = 5,
			maxY = 133,
			shape = "trapezoid",
		},
		{
			name = "uranium_buried",
			block = "UraniumOre",
			veins = 1.75,
			size = 9,
			minY = -35,
			maxY = 93,
			shape = "trapezoid",
			plateau = 24,
			buried = 0.75,
		},
	}
end
