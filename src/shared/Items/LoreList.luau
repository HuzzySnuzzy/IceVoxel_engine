--!strict
--[[
	Every item's lore: one short line under its name in the tooltip (Items/Tooltip, Minecraft's
	dark purple lore), saying what the item is for in this game first and its flavour second, as
	Terraria's tooltips do ("Allows the holder to double jump"). Data only, keyed by item name
	(Items.id: blocks' items by their block name, the other items by theirs), from the content
	packs (Shared/Content): each entry's `lore`, the packs' `lore` (lines for items a registry
	makes), and the side table below, for the items whose entries carry none yet. A name with a
	line both on its entry (or in a pack's `lore`) and in the side table is an error.

	  * Every item has one (tests/spec/Tooltips checks there are no gaps), and every key is an
	    item's (Items/Tooltip asserts it as it loads, so a renamed item can't keep stale lore).
	  * Keep a line short: the tooltip wraps it to a few rows. Numbers belong to the stat lines
	    (Items/Tooltip works them out from the item's data), so a line here says what no number
	    says: where the item comes from, what it is made into, what using it does.
	  * A new item gets its line on its entry (`lore = "..."`).
]]

local Content = require(script.Parent.Parent.Content)

-- The side table, by name (the old lists' order).
local lore: { [string]: string } = {
	-- Blocks (BlockList order) --------------------------------------------------------------------

	-- Mekanism and more -------------------------------------------------------------------------

	-- Terraria ----------------------------------------------------------------------------------
}

-- The packs' lines: their `lore`, then each entry's.
local content = Content.default
local function add(name: string, line: string, where: string)
	assert(lore[name] == nil, `LoreList: {where} has a lore line, and so has LoreList's side table`)
	lore[name] = line
end
for name, line in content.lore do
	add(name, line, content.where("lore", name))
end
for _, entry in content.entries do
	local line = entry.lore
	if line then
		add(entry.name, line, content.where(if content.block(entry.name) then "block" else "item", entry.name))
	end
end

return table.freeze(lore)
