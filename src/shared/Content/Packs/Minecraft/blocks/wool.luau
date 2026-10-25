--!strict
--[[
	White Wool (Minecraft 1.20.1's white_wool), what sheep drop (server Mobs/MobWorld, Shared/
	Entities/MobList) and four String make: a full block, strength 0.8 (hardness and blast
	resistance), no tool needed, wool sounds (Fabric), flammable 30 / 60 (FireBlock's wool odds)
	and 100 ticks of furnace fuel (Crafting/Recipes). Only white: a sheep's natural colour (black,
	grey, brown, pink) is drawn on the sheep, and every sheep drops white wool, as the game has no
	dyes. A zombie breaks it soon (120 ticks). Texture pack "white wool", blank until made.
]]

local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return {
	{
		name = "WhiteWool",
		color = { 234, 236, 237 },
		material = "Fabric",
		sound = "wool",
		hardness = 0.8,
		flammable = { ignite = 30, burn = 60 },
		zombieBreak = 120,
		texture = { All = "white wool" },
		lore = "Soft wool, from sheep or four String.",
		fuel = 100,
	},
} :: { Schema.BlockSpec }
