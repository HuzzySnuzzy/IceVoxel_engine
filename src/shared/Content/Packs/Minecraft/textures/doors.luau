--!strict
--[[
	The doors' textures, not made yet: Minecraft's door pictures, the lower and upper half's, drawn
	on both sides of the door's plate in place of its boxes (see-through where the picture is: the
	windows). The same picture serves both hinges. Fill an item's icon with the whole door too
	(Shared/TexturePack's header says how to fill one in).
]]

local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return {
	["oak door bottom"] = { Color = "", Material = "WoodPlanks", Tint = false },
	["oak door top"] = { Color = "", Material = "WoodPlanks", Tint = false },
	["spruce door bottom"] = { Color = "", Material = "WoodPlanks", Tint = false },
	["spruce door top"] = { Color = "", Material = "WoodPlanks", Tint = false },
	["birch door bottom"] = { Color = "", Material = "WoodPlanks", Tint = false },
	["birch door top"] = { Color = "", Material = "WoodPlanks", Tint = false },
	["jungle door bottom"] = { Color = "", Material = "WoodPlanks", Tint = false },
	["jungle door top"] = { Color = "", Material = "WoodPlanks", Tint = false },
	["acacia door bottom"] = { Color = "", Material = "WoodPlanks", Tint = false },
	["acacia door top"] = { Color = "", Material = "WoodPlanks", Tint = false },
} :: { [string]: Schema.Texture }
