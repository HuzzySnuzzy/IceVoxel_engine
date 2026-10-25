--!strict
--[[
	The ores' and storage blocks' textures: the ores in their own colours (no tint), the storage
	blocks not made yet (Shared/TexturePack's header says how to fill one in).
]]

local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return {
	["coal ore"] = {
		Color = "rbxassetid://123190628695822",
		Normal = "rbxassetid://126178156614120",
		Material = "Rock",
		Tint = false,
	},
	["iron ore"] = {
		Color = "rbxassetid://105117991053609",
		Normal = "rbxassetid://78336303508336",
		Material = "Rock",
		Tint = false,
	},
	["gold ore"] = {
		Color = "rbxassetid://120488738320366",
		Normal = "rbxassetid://84056217279698",
		Material = "Rock",
		Tint = false,
	},
	["diamond ore"] = {
		Color = "rbxassetid://118816817484302",
		Normal = "rbxassetid://112898008799573",
		Material = "Rock",
		Tint = false,
	},

	-- Not made yet.
	["emerald ore"] = { Color = "", Material = "Rock", Tint = false },
	["coal block"] = { Color = "", Material = "Slate" },
	["iron block"] = { Color = "", Material = "Metal" },
	["gold block"] = { Color = "", Material = "Metal" },
	["diamond block"] = { Color = "", Material = "Metal" },
	["emerald block"] = { Color = "", Material = "Metal" },
	["raw iron block"] = { Color = "", Material = "Rock" },
	["raw gold block"] = { Color = "", Material = "Rock" },
} :: { [string]: Schema.Texture }
