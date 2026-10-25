--!strict
--[[
	The Apocalypse pack's own block shapes (its blocks module uses them): the barricades' boards.
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

type ShapeBox = Schema.ShapeBox

local PLATE = { 120, 84, 60 }

local Shapes = {}

--[[
	A barricade's boxes: three boards across the cell along `axis` "Z" (spanning East-West, the two
	battens in front of them to the south), turned for "X"; `plates` adds the reinforced one's two
	strips of scrap steel behind them.
]]
function Shapes.barricade(axis: string, plates: boolean): { ShapeBox }
	local boxes: { ShapeBox } = {}
	-- (Authored for "Z": x across, z through the boards; swapped for "X".)
	local function board(size: { number }, offset: { number }, color: { number }?, material: string?)
		if axis == "X" then
			size = { size[3], size[2], size[1] }
			offset = { offset[3], offset[2], offset[1] }
		end
		table.insert(boxes, { size = size, offset = offset, color = color, material = material })
	end
	for _, y in { -5.5, 0, 5.5 } do
		board({ 16, 3.5, 2 }, { 0, y, 0 })
	end
	for _, x in { -5, 5 } do
		board({ 2, 16, 1.5 }, { x, 0, 1.75 }, { 128, 98, 62 })
	end
	if plates then
		for _, y in { -2.75, 2.75 } do
			board({ 16, 2, 0.6 }, { 0, y, -1.3 }, PLATE, "CorrodedMetal")
		end
	end
	return boxes
end

return Shapes
