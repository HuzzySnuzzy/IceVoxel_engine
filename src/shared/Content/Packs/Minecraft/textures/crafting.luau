--!strict
--[[
	The workshop's textures, not made yet (Shared/TexturePack's header says how to fill one in):
	the chest, crafting table and furnace keep their decorated faces drawn over these.
]]

local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return {
	["chest"] = { Color = "", Material = "WoodPlanks" },
	["crafting table top"] = { Color = "", Material = "WoodPlanks" },
	["crafting table side"] = { Color = "", Material = "WoodPlanks" },
	["furnace top"] = { Color = "", Material = "Cobblestone" },
	["furnace side"] = { Color = "", Material = "Cobblestone" },
} :: { [string]: Schema.Texture }
