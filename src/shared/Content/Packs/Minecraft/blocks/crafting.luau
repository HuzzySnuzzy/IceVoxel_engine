--!strict
--[[
	The Minecraft pack's workshop: the chest (server Players/Containers: right clicking opens its
	27 slots, breaking drops them), the crafting table (a 3 x 3 grid, Shared/Crafting) and the
	furnace (3 slots, Crafting/Smelting), each drawn with its decorated faces (BlockDecor). Zombies
	break none of them.
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
	},
	{
		name = "CraftingTable",
		color = { 128, 92, 54 },
		material = "WoodPlanks",
		hardness = 2.5,
		tool = "axe",
		menu = "Crafting",
		decor = "CraftingTable",
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
	},
} :: { BlockSpec }
