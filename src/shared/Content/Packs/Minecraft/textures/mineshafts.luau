--!strict
--[[
	Ladders', rope's and the mineshafts' blocks' textures (Shared/TexturePack's header says how to
	fill one in). The ladder and rail pictures are drawn on the block's plate (Front: Minecraft's
	single quad, see-through around the rails and rungs), as the vine's is, the rope, cobweb and
	hanging roots pictures as sprites (two crossed planes, Minecraft's chain and cross models); the
	fence post takes "planks" and the moss carpet "moss block", as their Minecraft models do.
]]

local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return {
	-- (Its own picture, moss and all: its own colours, as Minecraft's.)
	["mossy cobblestone"] = {
		Color = "rbxassetid://136109631002116",
		Normal = "rbxassetid://97401111826072",
		Material = "Cobblestone",
		Tint = false,
	},
	-- ("All things moss": the moss block and the moss carpet, in the picture's own green, as
	-- Minecraft's moss is never tinted.)
	["moss block"] = {
		Color = "rbxassetid://133332486942553",
		Normal = "rbxassetid://80266253786825",
		Material = "Grass",
		Tint = false,
	},
	-- (On the vine's plate, tinted like the grass and leaves: the vine's own green, as Minecraft
	-- tints vines with the foliage colour. A plate's picture is a Decal, which takes no normal map;
	-- the sheet's is kept for the MaterialVariant all the same.)
	["vine"] = {
		Color = "rbxassetid://112502994131665",
		Normal = "rbxassetid://97312068579996",
		Material = "SmoothPlastic",
		Tint = true,
	},

	-- Not made yet.
	["ladder"] = { Color = "", Material = "WoodPlanks", Tint = false },
	["rope"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["rail"] = { Color = "", Material = "Metal", Tint = false },
	["cobweb"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["hanging roots"] = { Color = "", Material = "SmoothPlastic", Tint = false },
} :: { [string]: Schema.Texture }
