--!strict
--[[
	Furnace fuel by item tag (Minecraft's AbstractFurnaceBlockEntity.getFuel burns logs and planks
	by their tags): every item in the tag burns this many ticks, so another pack's planks, put in
	#planks (Core's tags), burn as these do. An item's own `fuel` on its entry beats its tag's.
]]

return {
	logs = 300,
	planks = 300,
} :: { [string]: number }
