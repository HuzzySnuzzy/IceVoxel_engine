--!strict
--[[
	The Minecraft pack's ore features (Generation/Ores' header says what each field does and where
	the numbers come from; `block` is the block's name): the stone varieties by altitude and
	Minecraft's ores. Each feature's veins come from its own random stream (the seed and its name),
	so features may be added, removed or reordered without moving another's veins.
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

return {
	{ name = "diorite", block = "Diorite", veins = 1.5, size = 40, minY = 5, maxY = 200 },
	{ name = "andesite", block = "Andesite", veins = 1.5, size = 40, minY = 200, maxY = 370 },
	{ name = "granite", block = "Granite", veins = 1.5, size = 40, minY = 370, maxY = 540 },
	{ name = "coal", block = "CoalOre", veins = 12, size = 10, minY = 5, maxY = math.huge },
	{ name = "iron", block = "IronOre", veins = 7, size = 7, minY = 5, maxY = math.huge },
	{ name = "gold", block = "GoldOre", veins = 3, size = 6, minY = 48, maxY = math.huge },
	{ name = "diamond", block = "DiamondOre", veins = 4, size = 5, minY = 5, maxY = 30 },
	{ name = "emerald", block = "EmeraldOre", veins = 4, size = 3, minY = 600, maxY = math.huge },
} :: { Schema.OreFeature }
