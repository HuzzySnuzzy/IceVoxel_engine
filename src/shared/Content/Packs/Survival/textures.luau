--!strict
--[[
	The Survival pack's textures, not made yet (Shared/TexturePack's header says how to fill one
	in): the herbs' sprites (mint and wild ginger), and the seasons' insulation: wool-lined planks,
	double glass in iron, and the padded door's two halves (on its plate, as the other doors').
	Snow layers take the Minecraft pack's "snow"; the stoves, heaters and coolers are never
	textured, nor the campfire.
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

return {
	["mint"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["wild ginger"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["insulated planks"] = { Color = "", Material = "WoodPlanks", Tint = false },
	["insulated glass"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["insulated door bottom"] = { Color = "", Material = "WoodPlanks", Tint = false },
	["insulated door top"] = { Color = "", Material = "WoodPlanks", Tint = false },
} :: { [string]: Schema.Texture }
