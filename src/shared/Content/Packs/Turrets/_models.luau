--!strict
--[[
	The Turrets pack's own item model helper (its items module uses it): a box of the parts' models.
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

type ModelBox = Schema.ModelBox

local Models = {}

-- A box of `size` at `offset` in `colour`, of `material` (default the item's), a `shape` maybe.
function Models.box(
	size: { number },
	offset: { number },
	colour: { number },
	material: string?,
	shape: string?
): ModelBox
	return { size = size, offset = offset, color = colour, material = material, shape = shape }
end

return Models
