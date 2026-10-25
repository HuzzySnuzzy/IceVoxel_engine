--!strict
--[[
	Minecraft's storage recipes (Content/Define's `storage`: nine of an item into its block and the
	block back into nine): coal, iron, gold, diamond, emerald, raw iron and raw gold, and nine
	nuggets into an ingot of iron or gold (and back).
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return function(define: Define.Context): { Schema.Recipe }
	local list: { Schema.Recipe } = {}
	for _, pair in
		{
			{ "Coal", "CoalBlock" },
			{ "IronIngot", "IronBlock" },
			{ "GoldIngot", "GoldBlock" },
			{ "Diamond", "DiamondBlock" },
			{ "Emerald", "EmeraldBlock" },
			{ "RawIron", "RawIronBlock" },
			{ "RawGold", "RawGoldBlock" },
			{ "IronNugget", "IronIngot" },
			{ "GoldNugget", "GoldIngot" },
		}
	do
		define.append(list, define.storage(pair[1], pair[2]))
	end
	return list
end
