--!strict
--[[
	Potions (Shared/Effects/PotionList), brewed in a crafting grid as the game has no brewing stand
	(shapeless, the inventory's 2 x 2 too): a Purified Water Bottle (the Survival pack's) with the
	potion's ingredient makes the potion (Mint Leaves Swiftness, Glow Dust Night Vision...), the
	potion with Glow Dust its level II and with a coal or charcoal its long variant, where it has
	them (Minecraft's glowstone and redstone).
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local PotionList = require(script.Parent.Parent.Parent.Parent.Parent.Effects.PotionList)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return function(define: Define.Context): { Schema.Recipe }
	local list: { Schema.Recipe } = {}
	for _, variant in PotionList.all() do
		table.insert(list, define.shapeless({ variant.from, variant.with }, variant.item))
	end
	return list
end
