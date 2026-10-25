--!strict
--[[
	Potions (Shared/Effects/PotionList: Minecraft's, brewed in a crafting grid from a Purified Water
	Bottle, the pack's recipes): every potion's variants (Content/Define's `potion`: the Glass
	Bottle with the liquid in its effect's colour, Minecraft's potion colour being its effect's),
	stacking to 1 as Minecraft's potions do, the strong and long variants after each base potion,
	in PotionList's order. Drinking one (held 32 ticks: ToughAsNails/Drinks) gives its effect, and
	the Glass Bottle comes back.

	PotionList makes the items; what each says of itself is here, by its item name (POTIONS: its
	lore line and icon, blank), and its Age by its variant: brewing a base potion is the Iron Age's
	(Minecraft's brewing waits for the Nether), its strong (II) and long variants the Industrial
	Age's. A potion added to PotionList gets its line here too (a variant without one, or a line
	for no variant, fails the load).
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local EffectList = require(script.Parent.Parent.Parent.Parent.Parent.Effects.EffectList)
local PotionList = require(script.Parent.Parent.Parent.Parent.Parent.Effects.PotionList)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

-- Each potion item's lore line and icon, in PotionList's order.
local POTIONS: { [string]: { lore: string, icon: string } } = {
	PotionOfSwiftness = { lore = "Brewed from mint. Run faster.", icon = "" },
	StrongPotionOfSwiftness = { lore = "Brewed stronger with Glow Dust. Run much faster.", icon = "" },
	LongPotionOfSwiftness = { lore = "Brewed longer with coal. Run faster.", icon = "" },
	PotionOfLeaping = { lore = "Brewed from a cornflower. Jump higher.", icon = "" },
	StrongPotionOfLeaping = { lore = "Brewed stronger with Glow Dust. Jump much higher.", icon = "" },
	LongPotionOfLeaping = { lore = "Brewed longer with coal. Jump higher.", icon = "" },
	PotionOfStrength = { lore = "Brewed from gunpowder. Hit harder.", icon = "" },
	StrongPotionOfStrength = { lore = "Brewed stronger with Glow Dust. Hit much harder.", icon = "" },
	LongPotionOfStrength = { lore = "Brewed longer with coal. Hit harder.", icon = "" },
	PotionOfHealing = { lore = "Brewed from a gold nugget. Heals at once.", icon = "" },
	StrongPotionOfHealing = { lore = "Brewed stronger with Glow Dust. Heals more at once.", icon = "" },
	PotionOfHarming = { lore = "Brewed from a red mushroom. Don't drink it.", icon = "" },
	StrongPotionOfHarming = { lore = "Brewed stronger with Glow Dust. Really, don't drink it.", icon = "" },
	PotionOfPoison = { lore = "Brewed from a lily of the valley. Poisonous.", icon = "" },
	StrongPotionOfPoison = { lore = "Brewed stronger with Glow Dust. Very poisonous.", icon = "" },
	LongPotionOfPoison = { lore = "Brewed longer with coal. Poisonous.", icon = "" },
	PotionOfRegeneration = { lore = "Brewed from an oxeye daisy. Heals over time.", icon = "" },
	StrongPotionOfRegeneration = { lore = "Brewed stronger with Glow Dust. Heals faster.", icon = "" },
	LongPotionOfRegeneration = { lore = "Brewed longer with coal. Heals over time.", icon = "" },
	PotionOfFireResistance = { lore = "Brewed from ginger. Fire and lava can't hurt you.", icon = "" },
	LongPotionOfFireResistance = { lore = "Brewed longer with coal. Fire and lava can't hurt you.", icon = "" },
	PotionOfNightVision = { lore = "Brewed from Glow Dust. See in the dark.", icon = "" },
	LongPotionOfNightVision = { lore = "Brewed longer with coal. See in the dark.", icon = "" },
	PotionOfWeakness = { lore = "Brewed from a tulip. Your blows go soft.", icon = "" },
	LongPotionOfWeakness = { lore = "Brewed longer with coal. Your blows go soft.", icon = "" },
	PotionOfHaste = { lore = "Brewed from a gold ingot. Mine faster.", icon = "" },
	StrongPotionOfHaste = { lore = "Brewed stronger with Glow Dust. Mine much faster.", icon = "" },
	PotionOfResistance = { lore = "Brewed from an iron ingot. Take less damage.", icon = "" },
	StrongPotionOfResistance = { lore = "Brewed stronger with Glow Dust. Take much less damage.", icon = "" },
}

return function(define: Define.Context): { Schema.ItemSpec }
	local colours: { [string]: { number } } = {}
	for _, effect in EffectList do
		colours[effect.name] = effect.color
	end
	local list: { Schema.ItemSpec } = {}
	local made: { [string]: boolean } = {}
	for _, variant in PotionList.all() do
		local colour = colours[variant.effect]
		assert(colour, `Potion {variant.item} gives an unknown effect {variant.effect}`)
		local own = POTIONS[variant.item]
		assert(own, `Potion {variant.item} has no lore line and icon in the Minecraft pack's items/potions`)
		table.insert(
			list,
			define.potion(variant, colour, {
				lore = own.lore,
				icon = own.icon,
				age = if variant.from == PotionList.BASE then "iron" else "industrial",
			})
		)
		made[variant.item] = true
	end
	for name in POTIONS do
		assert(
			made[name],
			`The Minecraft pack's items/potions has a line for {name}, which PotionList makes no potion of`
		)
	end
	return list
end
