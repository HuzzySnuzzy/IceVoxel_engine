--!strict
--[[
	Sheep's wool's texture (white: Shared/Entities/MobList), not made yet (Shared/TexturePack's
	header says how to fill one in).
]]

local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return {
	["white wool"] = { Color = "", Material = "Fabric", Tint = false },
} :: { [string]: Schema.Texture }
