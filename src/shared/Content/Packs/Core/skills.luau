--!strict
--[[
	The skill tree's knowledge and tools branches (Progression/Skills says how the tree plays and
	what each perk kind does; Content/Schema's SKILL_FIELDS what each field is): knowledge on rows
	1 and 2, tools on 3 and 4, a column per Age on the skill tree screen. The survival branch (rows
	5 and 6) is the Survival pack's, as its perks are Tough As Nails'; Demolition and Fission (row 2)
	are the Minecraft pack's, as TNT and the Nuke are. A node costs its Age's number of points.

	`id` is what saves keep and what entries name (`skill = "demolition"`); a node's place among
	every pack's nodes, in load order, is what the protocol sends, so nodes may be added anywhere.
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

return {
	{
		id = "forager",
		name = "Forager",
		description = "+10% knowledge from discoveries",
		row = 1,
		icon = "OakSapling",
		age = "stone",
		cost = 1,
		perk = { kind = "knowledge", sources = { "discovery" }, bonus = 0.1 },
	},
	{
		id = "quarrying",
		name = "Quarrying",
		description = "Mine 10% faster with stone tools",
		row = 3,
		icon = "StonePickaxe",
		age = "stone",
		cost = 1,
		perk = { kind = "mining", tiers = { "Stone" }, factor = 1.1 },
	},
	{
		id = "smithing",
		name = "Smithing",
		description = "Tools wear 15% slower",
		row = 3,
		icon = "IronIngot",
		age = "iron",
		cost = 2,
		requires = { "quarrying" },
		perk = { kind = "wear", chance = 0.15 },
	},
	{
		id = "prospector",
		name = "Prospector",
		description = "Ores give twice the knowledge",
		row = 1,
		icon = "RawIron",
		age = "iron",
		cost = 2,
		requires = { "forager" },
		perk = { kind = "knowledge", sources = { "ore" }, bonus = 1 },
	},
	{
		id = "ironworking",
		name = "Ironworking",
		description = "Mine 10% faster with iron and golden tools",
		row = 4,
		icon = "IronPickaxe",
		age = "iron",
		cost = 2,
		requires = { "quarrying" },
		perk = { kind = "mining", tiers = { "Iron", "Golden" }, factor = 1.1 },
	},
	{
		id = "scholar",
		name = "Scholar",
		description = "+10% knowledge from everything",
		row = 1,
		icon = "Torch",
		age = "industrial",
		cost = 3,
		requires = { "prospector" },
		perk = { kind = "knowledge", sources = { "all" }, bonus = 0.1 },
	},
	{
		id = "tempering",
		name = "Tempering",
		description = "Tools wear another 15% slower",
		row = 3,
		icon = "IronSword",
		age = "industrial",
		cost = 3,
		requires = { "smithing" },
		perk = { kind = "wear", chance = 0.15 },
	},
	{
		id = "diamondCutting",
		name = "Diamond Cutting",
		description = "Mine 10% faster with diamond tools",
		row = 4,
		icon = "DiamondPickaxe",
		age = "industrial",
		cost = 3,
		requires = { "ironworking" },
		perk = { kind = "mining", tiers = { "Diamond" }, factor = 1.1 },
	},
	{
		id = "polymath",
		name = "Polymath",
		description = "+15% knowledge from everything",
		row = 1,
		icon = "Lantern",
		age = "electric",
		cost = 4,
		requires = { "scholar" },
		perk = { kind = "knowledge", sources = { "all" }, bonus = 0.15 },
	},
	{
		id = "mastery",
		name = "Mastery",
		description = "Mine 10% faster with any tool",
		row = 4,
		icon = "DiamondAxe",
		age = "atomic",
		cost = 5,
		requires = { "diamondCutting" },
		perk = { kind = "mining", factor = 1.1 },
	},
	{
		id = "enlightenment",
		name = "Enlightenment",
		description = "+25% knowledge from everything",
		row = 1,
		icon = "GlowBlock",
		age = "atomic",
		cost = 5,
		requires = { "polymath" },
		perk = { kind = "knowledge", sources = { "all" }, bonus = 0.25 },
	},
} :: { Schema.SkillRecord }
