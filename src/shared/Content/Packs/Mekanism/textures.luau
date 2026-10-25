--!strict
--[[
	The Mekanism pack's textures, not made yet (Shared/TexturePack's header says how to fill one
	in): osmium's ore and blocks. Transmitters, fluid tanks, machines and the solar panel are never
	textured.
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

return {
	["osmium ore"] = { Color = "", Material = "Granite", Tint = false },
	["osmium block"] = { Color = "", Material = "Metal" },
	["raw osmium block"] = { Color = "", Material = "Rock" },
} :: { [string]: Schema.Texture }
