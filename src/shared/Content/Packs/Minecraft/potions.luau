--!strict
--[[
	Minecraft's potions (Content/Schema's POTION_FIELDS; Shared/Effects/PotionList), brewed in a
	crafting grid as the game has no brewing stand. Content brews each into its items, stacking to
	1 (the Glass Bottle with the liquid in its effect's colour, Minecraft's potion colour being its
	effect's), and their shapeless recipes, after this pack's own (Content/Define's `brew`): a
	Purified Water Bottle (the Survival pack's) with the ingredient makes the potion, the potion
	with Glow Dust its level II and with a coal or charcoal its long variant, where it has them
	(Minecraft's glowstone and redstone). Drinking one (held 32 ticks: ToughAsNails/Drinks) gives
	its effect, and the Glass Bottle comes back.

	Minecraft's numbers: 3:00, II 1:30, long 8:00 for most; Poison and Regeneration 0:45, II 0:21.6
	and 0:22.5, long 1:30; Weakness 1:30, long 4:00. The ingredients are what the game has:
	Minecraft's own where it has them (Glow Dust for glowstone), else the flower that gives the
	effect in Minecraft's suspicious stew (Cornflower: Jump Boost, Oxeye Daisy: Regeneration, Lily
	of the Valley: Poison, tulips: Weakness), else something fitting (Mint Leaves quicken, Ginger
	Root warms against fire, a Gold Nugget heals as the glistering melon does, a Red Mushroom
	harms, Gunpowder for blaze powder). Haste and Resistance are this game's potions (Minecraft has
	none): a Gold Ingot (gold tools are the fastest) and an Iron Ingot.

	Each potion's items carry its lore lines, and their Ages (BREWING): brewing a base potion is
	the Iron Age's (Minecraft's brewing waits for the Nether), its strong (II) and long variants
	the Industrial Age's. Their icons are blank (none given: still to make).
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

local BREWING: Schema.PotionText = { base = "iron", strong = "industrial", long = "industrial" }

return {
	{
		name = "Swiftness",
		ingredient = "MintLeaves",
		effect = "Speed",
		seconds = 180,
		strong = 90,
		long = 480,
		lore = {
			base = "Brewed from mint. Run faster.",
			strong = "Brewed stronger with Glow Dust. Run much faster.",
			long = "Brewed longer with coal. Run faster.",
		},
		age = BREWING,
	},
	{
		name = "Leaping",
		ingredient = "Cornflower",
		effect = "JumpBoost",
		seconds = 180,
		strong = 90,
		long = 480,
		lore = {
			base = "Brewed from a cornflower. Jump higher.",
			strong = "Brewed stronger with Glow Dust. Jump much higher.",
			long = "Brewed longer with coal. Jump higher.",
		},
		age = BREWING,
	},
	{
		name = "Strength",
		ingredient = "Gunpowder",
		effect = "Strength",
		seconds = 180,
		strong = 90,
		long = 480,
		lore = {
			base = "Brewed from gunpowder. Hit harder.",
			strong = "Brewed stronger with Glow Dust. Hit much harder.",
			long = "Brewed longer with coal. Hit harder.",
		},
		age = BREWING,
	},
	{
		name = "Healing",
		ingredient = "GoldNugget",
		effect = "InstantHealth",
		strong = true,
		lore = {
			base = "Brewed from a gold nugget. Heals at once.",
			strong = "Brewed stronger with Glow Dust. Heals more at once.",
		},
		age = BREWING,
	},
	{
		name = "Harming",
		ingredient = "RedMushroom",
		effect = "InstantDamage",
		strong = true,
		lore = {
			base = "Brewed from a red mushroom. Don't drink it.",
			strong = "Brewed stronger with Glow Dust. Really, don't drink it.",
		},
		age = BREWING,
	},
	{
		name = "Poison",
		ingredient = "LilyOfTheValley",
		effect = "Poison",
		seconds = 45,
		strong = 21.6,
		long = 90,
		lore = {
			base = "Brewed from a lily of the valley. Poisonous.",
			strong = "Brewed stronger with Glow Dust. Very poisonous.",
			long = "Brewed longer with coal. Poisonous.",
		},
		age = BREWING,
	},
	{
		name = "Regeneration",
		ingredient = "OxeyeDaisy",
		effect = "Regeneration",
		seconds = 45,
		strong = 22.5,
		long = 90,
		lore = {
			base = "Brewed from an oxeye daisy. Heals over time.",
			strong = "Brewed stronger with Glow Dust. Heals faster.",
			long = "Brewed longer with coal. Heals over time.",
		},
		age = BREWING,
	},
	{
		name = "FireResistance",
		displayName = "Fire Resistance",
		ingredient = "GingerRoot",
		effect = "FireResistance",
		seconds = 180,
		long = 480,
		lore = {
			base = "Brewed from ginger. Fire and lava can't hurt you.",
			long = "Brewed longer with coal. Fire and lava can't hurt you.",
		},
		age = BREWING,
	},
	{
		name = "NightVision",
		displayName = "Night Vision",
		ingredient = "GlowDust",
		effect = "NightVision",
		seconds = 180,
		long = 480,
		lore = {
			base = "Brewed from Glow Dust. See in the dark.",
			long = "Brewed longer with coal. See in the dark.",
		},
		age = BREWING,
	},
	{
		name = "Weakness",
		ingredient = "#tulips",
		effect = "Weakness",
		seconds = 90,
		long = 240,
		lore = {
			base = "Brewed from a tulip. Your blows go soft.",
			long = "Brewed longer with coal. Your blows go soft.",
		},
		age = BREWING,
	},
	{
		name = "Haste",
		ingredient = "GoldIngot",
		effect = "Haste",
		seconds = 180,
		strong = 90,
		lore = {
			base = "Brewed from a gold ingot. Mine faster.",
			strong = "Brewed stronger with Glow Dust. Mine much faster.",
		},
		age = BREWING,
	},
	{
		name = "Resistance",
		ingredient = "IronIngot",
		effect = "Resistance",
		seconds = 90,
		strong = 45,
		lore = {
			base = "Brewed from an iron ingot. Take less damage.",
			strong = "Brewed stronger with Glow Dust. Take much less damage.",
		},
		age = BREWING,
	},
} :: { Schema.PotionSpec }
