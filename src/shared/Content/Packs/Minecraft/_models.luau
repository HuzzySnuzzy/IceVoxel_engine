--!strict
--[[
	The Minecraft pack's own item models (its items/ modules use them; Content/Define has the ones
	other packs share): the Shears, and the mobs' meat, a slab with its fat (and bone) and a
	drumstick.
]]

local Define = require(script.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Schema)

type ModelBox = Schema.ModelBox

local shade = Define.shade

local Models = {}

--[[ The Shears ]]

local SHEARS_HANDLE = { 112, 114, 120 }
local SHEARS_HOLE = { 40, 40, 44 }
-- (Each blade runs on through the rivet into the opposite handle, 12 degrees off upright.)
local SHEARS_ANGLE = 12

local function shearsArm(side: number): { ModelBox }
	local a = math.rad(SHEARS_ANGLE)
	-- Along the arm, from the rivet at (0, -1): +d up the blade, -d down the handle.
	local dx, dy = side * math.sin(a), math.cos(a)
	return {
		{ size = { 1.8, 8, 0.6 }, offset = { dx * 4, -1 + dy * 4, side * 0.3 }, rotation = -side * SHEARS_ANGLE },
		{
			size = { 2.8, 5, 0.8 },
			offset = { -dx * 3.6, -1 - dy * 3.6, side * 0.3 },
			rotation = -side * SHEARS_ANGLE,
			color = SHEARS_HANDLE,
		},
		{
			size = { 1, 2.6, 0.9 },
			offset = { -dx * 4, -1 - dy * 4, side * 0.3 },
			rotation = -side * SHEARS_ANGLE,
			color = SHEARS_HOLE,
		},
	}
end

-- Two grey blades crossing at a rivet over two darker handle loops, upright (blades up).
function Models.shears(): { ModelBox }
	local model: { ModelBox } = {}
	for _, side in { 1, -1 } do
		for _, box in shearsArm(side) do
			table.insert(model, box)
		end
	end
	table.insert(model, { size = { 1.4, 1.4, 1.4 }, offset = { 0, -1, 0 }, color = SHEARS_HANDLE })
	return model
end

--[[ Meat ]]

local BONE = { 232, 228, 210 }
Models.BONE = BONE

-- A slab of meat with a stripe of fat along one edge (beef, mutton: with a bone end), in `meat`.
function Models.slab(meat: { number }, fat: { number }, bone: boolean): { ModelBox }
	local boxes: { ModelBox } = {
		{ size = { 11, 8, 3 }, offset = { 0, -0.5, 0 }, color = meat },
		{ size = { 9, 2, 3.1 }, offset = { 0, 4, 0 }, color = fat },
		{ size = { 3, 5, 3 }, offset = { -6, -1, 0 }, rotation = 15, color = meat },
		{ size = { 5, 1, 0.4 }, offset = { 0.5, -1, 1.6 }, color = shade(meat, 0.75) },
		{ size = { 3, 1, 0.4 }, offset = { -1, -3, 1.6 }, color = shade(meat, 1.2) },
	}
	if bone then
		table.insert(boxes, { size = { 4, 2, 2 }, offset = { 7, -3, 0 }, color = BONE })
		table.insert(boxes, { size = { 2, 3, 2 }, offset = { 9, -3, 0 }, color = BONE })
	end
	return boxes
end

-- A drumstick: the meat in a ball, the bone sticking out of it with its knob.
function Models.drumstick(meat: { number }): { ModelBox }
	return {
		{ size = { 8, 8, 6 }, offset = { -2, 2, 0 }, color = meat, shape = "Ball" },
		{ size = { 6, 6, 5 }, offset = { 0.5, -0.5, 0 }, color = shade(meat, 0.9), shape = "Ball" },
		{ size = { 6, 1.6, 1.6 }, offset = { 4, -4, 0 }, rotation = -45, color = BONE },
		{ size = { 2.4, 2.4, 2 }, offset = { 6.5, -6.5, 0 }, color = BONE },
	}
end

return Models
