--!strict
--[[
	Weapons in tooltips (Shared/Items/Tooltip requires this): the stat lines of firearms,
	ammunition, magazines, attachments and melee weapons, and the describers (Items.addDescriber)
	of the item data keys Weapons/WeaponState keeps (rounds, chamber, magazine, attachments,
	mode, light). The inventory and melee builder owns them; this is FOUNDATION's stub: it adds no
	describer and no line, so tooltips stay as they were.
]]

local Items = require(script.Parent.Parent.Items)

local Describe = {}

-- The weapon stat lines of `stack` for its tooltip, in order ({} for none).
function Describe.lines(_stack: Items.Stack?): { string }
	return {}
end

return Describe
