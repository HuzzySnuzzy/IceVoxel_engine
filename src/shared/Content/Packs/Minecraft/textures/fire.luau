--!strict
--[[
	TNT's and the Nuke's textures, not made yet (Shared/TexturePack's header says how to fill one
	in): they keep their decorated faces too; lit, they share their unlit textures.
]]

local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return {
	["tnt side"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["tnt top"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["tnt bottom"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["nuke side"] = { Color = "", Material = "Metal", Tint = false },
	["nuke top"] = { Color = "", Material = "Metal", Tint = false },
} :: { [string]: Schema.Texture }
