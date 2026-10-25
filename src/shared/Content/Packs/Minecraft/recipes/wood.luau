--!strict
--[[
	Minecraft's wood recipes (Java 1.20): a log of each wood into four of its planks, and from any
	planks ("#planks", Core's tag) sticks, the crafting table and the chest.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return function(define: Define.Context): { Schema.Recipe }
	local shaped, shapeless = define.shaped, define.shapeless
	return {
		shapeless({ "OakLog" }, "Planks", 4),
		shapeless({ "BirchLog" }, "BirchPlanks", 4),
		shapeless({ "SpruceLog" }, "SprucePlanks", 4),
		shapeless({ "AcaciaLog" }, "AcaciaPlanks", 4),
		shapeless({ "JungleLog" }, "JunglePlanks", 4),
		shaped({ "#", "#" }, { ["#"] = "#planks" }, "Stick", 4),
		shaped({ "##", "##" }, { ["#"] = "#planks" }, "CraftingTable"),
		shaped({ "###", "# #", "###" }, { ["#"] = "#planks" }, "Chest"),
	}
end
