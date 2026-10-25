--!strict
--[[
	The wood's textures, each shared by every wood in its own colour (Tint): logs' bark and end
	rings, planks (fences and the Apocalypse pack's barricades take it too) and leaves.
]]

local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return {
	-- (Every log's bark, in the log's own colour.)
	["log"] = {
		Color = "rbxassetid://120423551204729",
		Normal = "rbxassetid://109169967309613",
		Material = "Wood",
		Tint = true,
	},
	["planks"] = {
		Color = "rbxassetid://118497034160890",
		Normal = "rbxassetid://129159801834926",
		Material = "WoodPlanks",
		Tint = true,
	},
	-- (The sheet's normal map repeated the colour map's id, a typo, so leaves have none. Opaque, as
	-- Minecraft's "fast" leaves: nothing behind a leaf block is drawn.)
	["leaves"] = {
		Color = "rbxassetid://17327831454",
		Material = "LeafyGrass",
		Tint = true,
		Align = false,
	},
	-- (Every log's end rings, in the log's own colour; not made yet.)
	["log top"] = { Color = "", Material = "Wood", Tint = true },
} :: { [string]: Schema.Texture }
