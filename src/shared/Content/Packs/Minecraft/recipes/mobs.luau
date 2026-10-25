--!strict
--[[
	What mobs drop (Shared/Entities/MobList), Minecraft's: raw meat cooks in a furnace, Leather
	makes the leather armor pieces in the armor shapes (24 for a set) and four String in a square
	make White Wool.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return function(define: Define.Context): { Schema.Recipe }
	local shaped, smelting = define.shaped, define.smelting
	local key = { X = "Leather" }
	return {
		smelting("RawBeef", "CookedBeef"),
		smelting("RawMutton", "CookedMutton"),
		smelting("RawPorkchop", "CookedPorkchop"),
		smelting("RawChicken", "CookedChicken"),
		shaped({ "XXX", "X X" }, key, "LeatherHelmet"),
		shaped({ "X X", "XXX", "XXX" }, key, "LeatherChestplate"),
		shaped({ "XXX", "X X", "X X" }, key, "LeatherLeggings"),
		shaped({ "X X", "X X" }, key, "LeatherBoots"),
		shaped({ "##", "##" }, { ["#"] = "String" }, "WhiteWool"),
	}
end
