--!strict
--[[
	The Minecraft pack's workshop: the chest (server Players/Containers: right clicking opens its
	27 slots, breaking drops them), the crafting table (a 3 x 3 grid, Shared/Crafting) and the
	furnace (3 slots, Crafting/Smelting), each drawn with its decorated faces (BlockDecor). The
	chest and the crafting table burn 300 ticks in a furnace (Minecraft's). Zombies break none of
	them.
]]

local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

type BlockSpec = Schema.BlockSpec

return {
	{
		name = "Chest",
		color = { 162, 118, 58 },
		material = "WoodPlanks",
		hardness = 2.5,
		tool = "axe",
		container = 27,
		menu = "Chest",
		decor = "Chest",
		-- (Minecraft's chest is 14 pixels tall and a pixel in from the sides: nothing hangs on it.)
		sturdy = false,
		texture = { All = "chest" },
		lore = "Stores your things. Breaking it drops what's inside.",
		fuel = 300,
	},
	{
		name = "CraftingTable",
		color = { 128, 92, 54 },
		material = "WoodPlanks",
		hardness = 2.5,
		tool = "axe",
		menu = "Crafting",
		decor = "CraftingTable",
		-- (Minecraft's crafting table bottom is oak planks: Bottom = "planks" gives it them, in the
		-- crafting table's colour; a bottom shows near you only with Config.Textures.BottomFaces.)
		texture = { Top = "crafting table top", Sides = "crafting table side" },
		lore = "Opens a 3 x 3 crafting grid for bigger recipes.",
		fuel = 300,
	},
	{
		name = "Furnace",
		color = { 112, 112, 114 },
		material = "Cobblestone",
		hardness = 3.5,
		tool = "pickaxe",
		toolLevel = 0,
		container = 3,
		menu = "Furnace",
		decor = "Furnace",
		texture = { Top = "furnace top", Sides = "furnace side", Bottom = "furnace top" },
		lore = "Smelts ores, cooks food and purifies water with fuel.",
	},
} :: { BlockSpec }
