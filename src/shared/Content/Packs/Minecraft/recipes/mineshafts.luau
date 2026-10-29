--!strict
--[[
	Climbing and the mineshafts' blocks. Minecraft's: the Ladder (seven sticks, three ladders),
	Rails (six iron ingots around a stick, sixteen), the Oak Fence (oak planks and sticks, three),
	the Moss Carpet (two moss blocks, three) and Mossy Cobblestone (cobblestone with a vine or a
	moss block). Rope is Supplementaries': three flax in a column make three, or three String on a
	diagonal; Straw (grass broken by hand, the Survival pack's) is this game's plant fibre, so three
	Straw in a column. Cobwebs have no recipe (Minecraft 1.20.1 has none). The second recipe of
	Rope and of Mossy Cobblestone each has a name of its own (a recipe's is its result's unless it
	gives one): RopeFromString, MossyCobblestoneFromMossBlock.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return function(define: Define.Context): { Schema.Recipe }
	local shaped, shapeless, named = define.shaped, define.shapeless, define.named
	return {
		shaped({ "S S", "SSS", "S S" }, { S = "Stick" }, "Ladder", 3),
		shaped({ "#", "#", "#" }, { ["#"] = "Straw" }, "Rope", 3),
		named("RopeFromString", shaped({ "#  ", " # ", "  #" }, { ["#"] = "String" }, "Rope", 3)),
		shaped({ "I I", "ISI", "I I" }, { I = "IronIngot", S = "Stick" }, "Rail", 16),
		shaped({ "PSP", "PSP" }, { P = "Planks", S = "Stick" }, "OakFence", 3),
		shaped({ "##" }, { ["#"] = "MossBlock" }, "MossCarpet", 3),
		shapeless({ "Cobblestone", "Vine" }, "MossyCobblestone"),
		named("MossyCobblestoneFromMossBlock", shapeless({ "Cobblestone", "MossBlock" }, "MossyCobblestone")),
	}
end
