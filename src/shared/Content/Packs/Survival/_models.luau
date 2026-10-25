--!strict
--[[
	The Survival pack's own item models (its items/ modules use them; the Glass Bottle's is
	Content/Define's `bottle`): Tough As Nails' canteen and the wooden bowl, empty or full.
]]

local Define = require(script.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Schema)

type ModelBox = Schema.ModelBox

local shade = Define.shade

local Models = {}

-- The canteen (iron, and its round window).
Models.CANTEEN = { 172, 176, 184 }
local CANTEEN = Models.CANTEEN

-- The canteen with `window` (its water's colour, or its dark inside) in its round window.
function Models.canteen(window: { number }): { ModelBox }
	return {
		{ size = { 11, 11, 3 }, offset = { 0, -1.5, -0.5 }, color = shade(CANTEEN, 0.7), shape = "Cylinder" },
		{ size = { 10, 10, 4 }, offset = { 0, -1.5, 0 }, shape = "Cylinder" },
		{ size = { 5.5, 5.5, 0.5 }, offset = { 0, -1.5, 2.1 }, color = window, shape = "Cylinder" },
		{ size = { 3, 2, 3 }, offset = { 0, 4.5, 0 } },
		{ size = { 4, 1.5, 4 }, offset = { 0, 6.25, 0 }, color = { 70, 52, 36 }, material = "Wood" },
		{ size = { 1, 4, 1 }, offset = { -5.5, 3, 0 }, color = { 120, 84, 52 }, material = "Fabric" },
		{ size = { 1, 4, 1 }, offset = { 5.5, 3, 0 }, color = { 120, 84, 52 }, material = "Fabric" },
	}
end

-- The bowl's wood.
Models.BOWL = { 150, 104, 60 }
local BOWL = Models.BOWL

-- A brown bowl with a darker foot; filled (`drink`), the drink's top over its rim, else its dark
-- inside; `floating` boxes on it (a leaf or a slice of root on a tea).
function Models.bowl(drink: { number }?, floating: { ModelBox }?): { ModelBox }
	local boxes: { ModelBox } = {
		{ size = { 14, 2, 6 }, offset = { 0, 1, 0 }, color = shade(BOWL, 1.1) },
		{ size = { 12, 3, 5.6 }, offset = { 0, -1.5, 0 } },
		{ size = { 8.5, 2, 5 }, offset = { 0, -4, 0 }, color = shade(BOWL, 0.85) },
		{ size = { 5, 1, 4 }, offset = { 0, -5.5, 0 }, color = shade(BOWL, 0.65) },
	}
	if drink then
		-- (The drink filling it to the rim.)
		table.insert(
			boxes,
			{ size = { 12, 1.4, 5.4 }, offset = { 0, 2.6, 0 }, color = drink, material = "SmoothPlastic" }
		)
	else
		-- (Its dark inside, seen over the rim.)
		table.insert(boxes, { size = { 12, 0.6, 5 }, offset = { 0, 2.1, 0 }, color = shade(BOWL, 0.55) })
	end
	if floating then
		for _, box in floating do
			table.insert(boxes, box)
		end
	end
	return boxes
end

return Models
