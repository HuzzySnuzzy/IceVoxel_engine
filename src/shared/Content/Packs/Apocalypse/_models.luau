--!strict
--[[
	The Apocalypse pack's own item models (its items/ modules use them): a tin can and a baseball
	bat, and the weapons' pieces: a box, cartridges, shotgun shells, a bolt-action rifle and a
	firearm's boxes at its WeaponList `scale`, with the guns' colours.
]]

local Define = require(script.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Schema)
-- (Pure data: the firearms' scales.)
local WeaponList = require(script.Parent.Parent.Parent.Parent.Weapons.WeaponList)

type ModelBox = Schema.ModelBox

local shade = Define.shade

local Models = {}

--[[ Supplies ]]

Models.CAN = { 170, 170, 166 }
Models.BAT = { 176, 134, 84 }
local CAN, BAT = Models.CAN, Models.BAT

-- A tin can with a label of `label` round its middle.
function Models.can(label: { number }): { ModelBox }
	return {
		{ size = { 8, 10, 6 }, offset = { 0, -1, 0 } },
		{ size = { 8.2, 5, 6.2 }, offset = { 0, -1, 0 }, color = label, material = "SmoothPlastic" },
		{ size = { 7, 0.8, 5 }, offset = { 0, 4.4, 0 }, color = shade(CAN, 1.15) },
		{ size = { 1.2, 4, 0.4 }, offset = { -2.6, -1, 3.2 }, color = shade(label, 1.3) },
	}
end

-- An upright bat from y = -10 (knob) to the barrel's end at the top.
function Models.bat(): { ModelBox }
	return {
		{ size = { 2.5, 1, 2.5 }, offset = { 0, -9.5, 0 }, color = shade(BAT, 0.7) },
		{ size = { 1.5, 7, 1.5 }, offset = { 0, -5.5, 0 }, color = shade(BAT, 0.85) },
		{ size = { 2.2, 3, 2.2 }, offset = { 0, -0.5, 0 } },
		{ size = { 3, 9, 3 }, offset = { 0, 5.5, 0 } },
		{ size = { 0.6, 8, 3.1 }, offset = { 1, 5.5, 0 }, color = shade(BAT, 1.15) },
	}
end

--[[ Weapons ]]

Models.GUNMETAL = { 58, 60, 64 }
Models.POLY = { 34, 34, 36 }
Models.STOCK = { 120, 78, 44 }
Models.DARK = { 92, 60, 34 }
Models.GUN_STEEL = { 150, 152, 156 }
Models.BRASS = { 196, 160, 70 }
Models.OLIVE = { 86, 92, 60 }
Models.TIP_COPPER = { 190, 120, 60 }
local GUNMETAL, GUN_STEEL, BRASS = Models.GUNMETAL, Models.GUN_STEEL, Models.BRASS

-- A box of `size` at `offset` (pixels) in `colour`, of `material` (default the item's), turned
-- `rotation` degrees about the view axis.
function Models.box(
	size: { number },
	offset: { number },
	colour: { number },
	material: string?,
	rotation: number?
): ModelBox
	return { size = size, offset = offset, color = colour, material = material, rotation = rotation }
end
local box = Models.box

-- Cartridges standing side by side at `xs`: a case of `case` (w x h, `caseColour`) and a tip
-- (`tip` size, `tipColour`) on top, `tipShape` "Ball" for a round nose.
function Models.cartridges(
	xs: { number },
	case: { number },
	caseColour: { number },
	tip: { number },
	tipColour: { number },
	tipY: number?,
	tipShape: string?
): { ModelBox }
	local boxes: { ModelBox } = {}
	local y = tipY or case[2] / 2 + tip[2] / 2
	for _, x in xs do
		table.insert(boxes, box({ case[1], case[2], case[1] }, { x, 0, 0 }, caseColour, "Metal"))
		table.insert(boxes, {
			size = { tip[1], tip[2], tip[1] },
			offset = { x, y, 0 },
			color = tipColour,
			material = "Metal",
			shape = tipShape,
		})
	end
	return boxes
end

-- Two shotgun shells: a coloured hull on a brass base.
function Models.shells(hull: { number }): { ModelBox }
	local boxes: { ModelBox } = {}
	for _, x in { -2, 2 } do
		table.insert(boxes, box({ 3, 7, 3 }, { x, 0, 0 }, hull, "SmoothPlastic"))
		table.insert(boxes, box({ 3.2, 2, 3.2 }, { x, -3.5, 0 }, BRASS, "Metal"))
	end
	return boxes
end

-- A bolt-action rifle's boxes in `wood`.
function Models.boltRifle(wood: { number }): { ModelBox }
	return {
		box({ 26, 3, 2.4 }, { -2, 0, 0 }, wood, "Wood"),
		box({ 12, 1.2, 1.2 }, { 13, 1.6, 0 }, GUN_STEEL),
		box({ 6, 2.2, 2 }, { -2, 2, 0 }, GUNMETAL),
		box({ 1, 2.5, 1 }, { -4, 1, 1.6 }, GUN_STEEL, nil, -30),
		box({ 5, 5, 2.4 }, { -15, -1, 0 }, wood, "Wood", 10),
	}
end

-- Firearm `name`'s boxes at its WeaponList `scale` (long guns at 0.58, so they fit the icon's
-- cube, keeping their proportions to each other).
function Models.drawn(name: string, boxes: { ModelBox }): { ModelBox }
	local scale = WeaponList.firearms[name].scale or 1
	if scale == 1 then
		return boxes
	end
	local out: { ModelBox } = {}
	for _, b in boxes do
		table.insert(out, {
			size = { b.size[1] * scale, b.size[2] * scale, b.size[3] * scale },
			offset = { b.offset[1] * scale, b.offset[2] * scale, b.offset[3] * scale },
			color = b.color,
			material = b.material,
			rotation = b.rotation,
			shape = b.shape,
		})
	end
	return out
end

return Models
