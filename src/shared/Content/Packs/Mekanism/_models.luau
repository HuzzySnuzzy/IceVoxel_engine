--!strict
--[[
	The Mekanism pack's own item models (its items module uses them): the upgrade cards' card and
	the speed upgrade's chevrons.
]]

local Define = require(script.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Schema)

type ModelBox = Schema.ModelBox

local shade = Define.shade

local CARD = { 58, 62, 70 }
-- (Gold contacts: the gold ingot's colour, a little darker.)
local CONTACT = shade({ 250, 213, 58 }, 0.9)

local Models = {}

-- The card: a dark board, a lighter face, four gold contacts along its foot, then `symbol`.
function Models.upgradeCard(symbol: { ModelBox }): { ModelBox }
	local boxes: { ModelBox } = {
		{ size = { 12, 13, 1 }, offset = { 0, 0.5, 0 }, color = CARD },
		{ size = { 10, 9, 0.4 }, offset = { 0, 1.5, 0.6 }, color = shade(CARD, 1.35) },
	}
	for i = 0, 3 do
		table.insert(boxes, { size = { 1.5, 2, 1.2 }, offset = { -3.75 + i * 2.5, -5.5, 0 }, color = CONTACT })
	end
	for _, box in symbol do
		table.insert(boxes, box)
	end
	return boxes
end

-- A ">" chevron with its tip at (x, y): two bars meeting at a right angle (on the card's face).
function Models.chevron(x: number, y: number): { ModelBox }
	return {
		{ size = { 4, 1.3, 0.4 }, offset = { x - 1.4, y + 1.4, 1 }, rotation = -45, material = "Neon" },
		{ size = { 4, 1.3, 0.4 }, offset = { x - 1.4, y - 1.4, 1 }, rotation = 45, material = "Neon" },
	}
end

return Models
