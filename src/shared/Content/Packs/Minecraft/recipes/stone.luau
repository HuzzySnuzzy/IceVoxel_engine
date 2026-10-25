--!strict
--[[
	Minecraft's stone, ice and snow recipes (Java 1.20): the furnace from any stone crafting
	material (Core's tag: cobblestone), stone bricks, the polished stones, andesite from diorite and
	cobblestone, sandstone and cut sandstone, coarse dirt, packed and blue ice (nine of the one
	below each) and the snow block from snowballs.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return function(define: Define.Context): { Schema.Recipe }
	local shaped, shapeless = define.shaped, define.shapeless
	return {
		shaped({ "###", "# #", "###" }, { ["#"] = "#stone_crafting_materials" }, "Furnace"),
		shaped({ "##", "##" }, { ["#"] = "Stone" }, "StoneBricks", 4),
		shaped({ "##", "##" }, { ["#"] = "Andesite" }, "PolishedAndesite", 4),
		shaped({ "##", "##" }, { ["#"] = "Diorite" }, "PolishedDiorite", 4),
		shaped({ "##", "##" }, { ["#"] = "Granite" }, "PolishedGranite", 4),
		shapeless({ "Diorite", "Cobblestone" }, "Andesite", 2),
		shaped({ "##", "##" }, { ["#"] = "Sand" }, "Sandstone"),
		shaped({ "##", "##" }, { ["#"] = "Sandstone" }, "CutSandstone", 4),
		shaped({ "DG", "GD" }, { D = "Dirt", G = "Gravel" }, "CoarseDirt", 4),
		-- Ice and snow.
		shapeless({ "Ice", "Ice", "Ice", "Ice", "Ice", "Ice", "Ice", "Ice", "Ice" }, "PackedIce"),
		shapeless({
			"PackedIce",
			"PackedIce",
			"PackedIce",
			"PackedIce",
			"PackedIce",
			"PackedIce",
			"PackedIce",
			"PackedIce",
			"PackedIce",
		}, "BlueIce"),
		shaped({ "##", "##" }, { ["#"] = "Snowball" }, "Snow"),
	}
end
