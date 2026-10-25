--!strict
--[[
	Every item's lore: one short line under its name in the tooltip (Items/Tooltip, Minecraft's
	dark purple lore), saying what the item is for in this game first and its flavour second, as
	Terraria's tooltips do ("Allows the holder to double jump"). Data only, keyed by item name
	(Items.id: blocks' items by their block name, the other items by theirs), from the content
	packs (Shared/Content): each entry's `lore`, and the packs' `lore` (lines for items a registry
	makes, the potions; Content checks no name has both).

	  * Every item has one (tests/spec/Tooltips checks there are no gaps), and every key is an
	    item's (Items/Tooltip asserts it as it loads, so a renamed item can't keep stale lore).
	  * Keep a line short: the tooltip wraps it to a few rows. Numbers belong to the stat lines
	    (Items/Tooltip works them out from the item's data), so a line here says what no number
	    says: where the item comes from, what it is made into, what using it does.
	  * A new item gets its line on its entry (`lore = "..."`).
]]

local Content = require(script.Parent.Parent.Content)

-- The packs' lines: their `lore`, then each entry's.
local content = Content.default
local lore: { [string]: string } = table.clone(content.lore)
for _, entry in content.entries do
	if entry.lore then
		lore[entry.name] = entry.lore
	end
end

return table.freeze(lore)
