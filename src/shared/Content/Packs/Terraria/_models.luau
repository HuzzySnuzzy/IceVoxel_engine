--!strict
--[[
	The Terraria pack's own item models (its items module uses them): a ring with a gem, and a five
	pointed star.
]]

local Define = require(script.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Schema)

type ModelBox = Schema.ModelBox

local shade = Define.shade
local DARK = { 28, 26, 32 }

local Models = {}

-- A ring seen from the front: a band of `colour` round a dark hole, with a gem on top.
function Models.ring(colour: { number }, gem: { ModelBox }): { ModelBox }
	local boxes: { ModelBox } = {
		{ size = { 10, 10, 2.5 }, offset = { 0, -1, 0 }, shape = "Cylinder" },
		{ size = { 6.5, 6.5, 2.7 }, offset = { 0, -1, 0 }, shape = "Cylinder", color = DARK },
		{ size = { 6, 1, 2.6 }, offset = { 0, -1, 1.2 }, color = shade(colour, 1.25) },
	}
	for _, box in gem do
		table.insert(boxes, box)
	end
	return boxes
end

-- A five pointed star in the view plane: a centre and a point every 72 degrees.
function Models.star(colour: { number }, radius: number, material: string?): { ModelBox }
	local boxes: { ModelBox } = {
		{
			size = { radius * 1.3, radius * 1.3, 2.5 },
			offset = { 0, 0, 0 },
			rotation = 36,
			color = colour,
			material = material,
		},
	}
	for k = 0, 4 do
		local angle = math.rad(90 + 72 * k)
		table.insert(boxes, {
			size = { radius * 0.6, radius * 1.1, 2 },
			offset = { math.cos(angle) * radius * 0.85, math.sin(angle) * radius * 0.85, 0 },
			rotation = 72 * k,
			color = colour,
			material = material,
		})
	end
	return boxes
end

return Models
