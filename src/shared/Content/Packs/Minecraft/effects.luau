--!strict
--[[
	Minecraft 1.20.1's status effects (MobEffects), with their colours (Content/Schema's
	EFFECT_FIELDS say what each field does; Shared/Effects is their registry). The game has these
	eighteen of them, then Hunger, which came with the food bar. Potions give most of them (this
	pack's potions), the fluids some (Shared/Fluids/FluidList `effects`), /effect any.
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

return {
	{
		name = "Speed",
		command = "speed",
		color = { 124, 175, 198 },
		category = "beneficial",
		icon = "speed",
		speed = 0.2,
	},
	{
		name = "Slowness",
		command = "slowness",
		color = { 90, 108, 129 },
		category = "harmful",
		icon = "slowness",
		speed = -0.15,
	},
	{
		name = "Haste",
		command = "haste",
		color = { 217, 192, 67 },
		category = "beneficial",
		icon = "pickaxe",
		mining = 0.2,
	},
	{
		name = "MiningFatigue",
		command = "mining_fatigue",
		color = { 74, 66, 23 },
		category = "harmful",
		icon = "pickaxe",
		fatigue = true,
	},
	{
		name = "Strength",
		command = "strength",
		color = { 147, 36, 35 },
		category = "beneficial",
		icon = "sword",
		melee = 3,
	},
	{
		name = "InstantHealth",
		command = "instant_health",
		color = { 248, 36, 35 },
		category = "beneficial",
		icon = "heart",
		instant = "heal",
	},
	{
		name = "InstantDamage",
		command = "instant_damage",
		color = { 67, 10, 9 },
		category = "harmful",
		icon = "broken",
		instant = "harm",
	},
	{
		name = "JumpBoost",
		command = "jump_boost",
		color = { 34, 255, 76 },
		category = "beneficial",
		icon = "jump",
		jump = 0.1,
	},
	{
		name = "Nausea",
		command = "nausea",
		color = { 85, 29, 74 },
		category = "harmful",
		icon = "spiral",
		view = "nausea",
	},
	{
		name = "Regeneration",
		command = "regeneration",
		color = { 205, 92, 171 },
		category = "beneficial",
		icon = "heart",
		interval = 50,
		heal = 1,
	},
	{
		name = "Resistance",
		command = "resistance",
		color = { 153, 69, 58 },
		category = "beneficial",
		icon = "shield",
		resistance = 0.2,
	},
	{
		name = "FireResistance",
		command = "fire_resistance",
		color = { 228, 154, 58 },
		category = "beneficial",
		icon = "flame",
		fireImmune = true,
	},
	{
		name = "Blindness",
		command = "blindness",
		color = { 31, 31, 35 },
		category = "harmful",
		icon = "eye",
		view = "blindness",
		noSprint = true,
	},
	{
		name = "NightVision",
		command = "night_vision",
		color = { 31, 31, 161 },
		category = "beneficial",
		icon = "eye",
		view = "nightVision",
	},
	{
		name = "Weakness",
		command = "weakness",
		color = { 72, 77, 72 },
		category = "harmful",
		icon = "sword",
		melee = -4,
	},
	{
		name = "Poison",
		command = "poison",
		color = { 78, 147, 49 },
		category = "harmful",
		icon = "drop",
		interval = 25,
		damage = 1,
	},
	{
		name = "Wither",
		command = "wither",
		color = { 53, 42, 39 },
		category = "harmful",
		icon = "skull",
		interval = 40,
		damage = 1,
		lethal = true,
	},
	{
		name = "Glowing",
		command = "glowing",
		color = { 148, 160, 97 },
		category = "neutral",
		icon = "star",
		view = "glowing",
	},
	-- Minecraft's Hunger (MobEffects.HUNGER, its colour), from rotten flesh and raw chicken
	-- (Items/Foods): the food bar drains faster (the HUD's FOOD icon falls, with a Hunger badge:
	-- client Ui/StatusCluster).
	-- Kept by Players/Effects like any other; Shared/Hunger reads its level.
	{
		name = "Hunger",
		command = "hunger",
		color = { 88, 118, 83 },
		category = "harmful",
		icon = "drumstick",
		drainsFood = true,
	},
} :: { Schema.EffectSpec }
