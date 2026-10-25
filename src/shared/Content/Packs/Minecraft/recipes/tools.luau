--!strict
--[[
	Minecraft's tool and armor recipes (Java 1.20): the five tools of wood (any planks), stone (any
	stone tool material: cobblestone), iron, gold and diamond over sticks; iron, gold and diamond
	armor in the armor shapes (leather's are with the mobs' drops; chainmail is not craftable, but
	smelts); and the Shears, two iron ingots on a diagonal (Minecraft's " #", "# "; mirrored works
	too).
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

local TOOL_MATERIALS = {
	{ "Wooden", "#planks" },
	{ "Stone", "#stone_tool_materials" },
	{ "Iron", "IronIngot" },
	{ "Golden", "GoldIngot" },
	{ "Diamond", "Diamond" },
}

return function(define: Define.Context): { Schema.Recipe }
	local shaped = define.shaped
	local list: { Schema.Recipe } = {}
	for _, material in TOOL_MATERIALS do
		local tier, x = material[1], material[2]
		local key = { X = x, ["#"] = "Stick" }
		table.insert(list, shaped({ "XXX", " # ", " # " }, key, tier .. "Pickaxe"))
		table.insert(list, shaped({ "XX", "X#", " #" }, key, tier .. "Axe"))
		table.insert(list, shaped({ "X", "#", "#" }, key, tier .. "Shovel"))
		table.insert(list, shaped({ "XX", " #", " #" }, key, tier .. "Hoe"))
		table.insert(list, shaped({ "X", "X", "#" }, key, tier .. "Sword"))
	end
	for _, material in { { "Iron", "IronIngot" }, { "Gold", "GoldIngot" }, { "Diamond", "Diamond" } } do
		local key = { X = material[2] }
		table.insert(list, shaped({ "XXX", "X X" }, key, material[1] .. "Helmet"))
		table.insert(list, shaped({ "X X", "XXX", "XXX" }, key, material[1] .. "Chestplate"))
		table.insert(list, shaped({ "XXX", "X X", "X X" }, key, material[1] .. "Leggings"))
		table.insert(list, shaped({ "X X", "X X" }, key, material[1] .. "Boots"))
	end
	table.insert(list, shaped({ " #", "# " }, { ["#"] = "IronIngot" }, "Shears"))
	return list
end
