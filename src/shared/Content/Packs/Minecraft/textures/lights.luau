--!strict
--[[
	Glow lichen's texture, on the face it covers (its Front), in the picture's own colours. Torches,
	lanterns and the Glow Block are never textured (Neon cannot take a MaterialVariant).
]]

local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return {
	["glow lichen"] = {
		Color = "rbxassetid://81026875222604",
		Material = "SmoothPlastic",
		Tint = false,
	},
} :: { [string]: Schema.Texture }
