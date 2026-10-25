--!strict
--[[
	Potions (Shared/Effects/PotionList: Minecraft's, brewed in a crafting grid from a Purified Water
	Bottle, the pack's recipes): every potion's variants (Content/Define's `potion`: the Glass
	Bottle with the liquid in its effect's colour, Minecraft's potion colour being its effect's),
	stacking to 1 as Minecraft's potions do, the strong and long variants after each base potion,
	in PotionList's order. Drinking one (held 32 ticks: ToughAsNails/Drinks) gives its effect, and
	the Glass Bottle comes back.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local EffectList = require(script.Parent.Parent.Parent.Parent.Parent.Effects.EffectList)
local PotionList = require(script.Parent.Parent.Parent.Parent.Parent.Effects.PotionList)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return function(define: Define.Context): { Schema.ItemSpec }
	local colours: { [string]: { number } } = {}
	for _, effect in EffectList do
		colours[effect.name] = effect.color
	end
	local list: { Schema.ItemSpec } = {}
	for _, variant in PotionList.all() do
		local colour = colours[variant.effect]
		assert(colour, `Potion {variant.item} gives an unknown effect {variant.effect}`)
		table.insert(list, define.potion(variant, colour))
	end
	return list
end
