--!strict
--[[
	Every item that is no block: the content packs' item entries (Shared/Content), merged, in id
	order (an item's id is ITEM_BASE + its place minus one; every placeable block is an item too,
	with its block's id: see Items). The list itself moved into the packs (the Minecraft pack's
	items, Mekanism's, Survival's, Terraria's...); this module keeps `Items.ItemList` and its types
	for the code and specs that read them. The fields are Content/Schema's.
]]

local Content = require(script.Parent.Parent.Content)
local Schema = require(script.Parent.Parent.Content.Schema)

export type ModelBox = Schema.ModelBox
export type AccessorySpec = Schema.AccessorySpec
export type MagicSpec = Schema.MagicSpec
export type ItemSpec = Schema.ItemSpec

return Content.default.items
