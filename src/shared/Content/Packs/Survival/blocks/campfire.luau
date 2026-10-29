--!strict
--[[
	The Campfire (Minecraft 1.20.1's CampfireBlock, always lit here: nothing puts it out), Tough As
	Nails' warmth in the cold. Minecraft's recipe (three sticks around a coal or charcoal, over three
	logs: the pack's recipes) and model (campfire.json): two logs along Z on the floor (1..5 and
	11..15 across, 4 tall), two along X across them (3..7 up), and the glowing bed of embers between
	the lower pair (5..11, a pixel thick), which carries its light (15, warm); the flames over it are
	fire's animated sheet on Minecraft's two crossed planes (client Rendering/FireRenderer,
	Shared/Fire.planes). Its outline is Minecraft's 7 pixel tall slab. Not solid: Minecraft's
	campfire is a 7 pixel step to stand on, which the movement hull (full cubes only) cannot have,
	so players walk into it, and it hurts them as Minecraft's entityInside does (Players/Burning:
	half a heart through the hurt cooldown, armor softening it, without setting them alight); it
	`obstructs`, so it is never placed inside a player. Strength 2 (hardness and blast resistance),
	an axe mines it fast, wood sounds. Minecraft drops 2 charcoal without Silk Touch, which this
	game has no enchantment for: here it drops itself, so a campfire can be moved. A heat source
	(`heats`, Shared/ToughAsNails/Temperature: 3 steps within 5 blocks, 5 within 2) where dirty water
	boils clean (Shared/ToughAsNails/Boiling); it crackles like fire (Audio/Ambience through
	FireRenderer.firesNear). Spawns never land in or next to one (`spawnUnsafe`, Players/SafeSpot). Its
	item shows a few flames over the logs (`icon`).
]]

local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

type ShapeBox = Schema.ShapeBox

local CAMPFIRE_LOG = { 92, 70, 44 }
local CAMPFIRE_LOG_TOP = { 110, 84, 54 }
local EMBERS = { 255, 132, 40 }

local campfire: { ShapeBox } = {
	{ size = { 4, 4, 16 }, offset = { -5, -6, 0 }, color = CAMPFIRE_LOG },
	{ size = { 4, 4, 16 }, offset = { 5, -6, 0 }, color = CAMPFIRE_LOG },
	{ size = { 16, 4, 4 }, offset = { 0, -3, 5 }, color = CAMPFIRE_LOG_TOP },
	{ size = { 16, 4, 4 }, offset = { 0, -3, -5 }, color = CAMPFIRE_LOG_TOP },
	{ size = { 6, 1, 16 }, offset = { 0, -7.5, 0 }, color = EMBERS, material = "Neon", glow = true },
}
local campfireIcon = table.clone(campfire)
for _, flame in
	{
		{ size = { 3, 7, 3 }, offset = { 0, 2.5, 0 }, color = { 255, 170, 60 }, material = "Neon" },
		{ size = { 2, 4, 2 }, offset = { -2.5, 0.5, 1.5 }, color = { 255, 120, 30 }, material = "Neon" },
		{ size = { 2, 5, 2 }, offset = { 2.5, 1, -1.5 }, color = { 255, 214, 110 }, material = "Neon" },
	} :: { ShapeBox }
do
	table.insert(campfireIcon, flame)
end

return {
	{
		name = "Campfire",
		color = CAMPFIRE_LOG,
		material = "Wood",
		sound = "wood",
		solid = false,
		placeable = true,
		hardness = 2,
		tool = "axe",
		light = 15,
		lightColor = { 255, 170, 90 },
		shape = campfire,
		icon = campfireIcon,
		bounds = { min = { 0, 0, 0 }, max = { 16, 7, 16 } },
		obstructs = true,
		heats = true,
		lore = "Warms you when close and boils dirty water clean. Hot to touch.",
		spawnUnsafe = "near",
	},
} :: { Schema.BlockSpec }
