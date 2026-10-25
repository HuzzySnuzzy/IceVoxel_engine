--!strict
--[[
	The new ores' items, in this order: each metal's raw lump, ingot and nugget (copper, lead,
	zinc), brass's ingot and nugget, the two powders, Sulfur and Saltpetre (gunpowder's other
	halves: two Saltpetre, a Sulfur and a coal make four), uranium's lump, ingot and nugget
	(radioactive), and the Hazmat suit. Blank icons, so each look is one id to paste.

	The Hazmat suit (Mekanism's): four pieces of lead sheet under yellow cloth, Leather's armor
	points, Mekanism's names (Mask, Gown, Pants, Boots), each keeping out a share of radiation
	(`shielding`: Mekanism's 0.25, 0.4, 0.2 and 0.15; the whole suit all of it). The Iron Age's.
]]

local Define = require(script.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Schema)
local metals = require(script.Parent._metals)

type ModelBox = Schema.ModelBox

-- A heap of powder, as Glow Dust's, with specks of `fleck`.
local function powder(
	shade: (colour: { number }, factor: number) -> { number },
	colour: { number },
	fleck: { number }
): { ModelBox }
	return {
		{ size = { 11, 3, 4 }, offset = { 0, -3.5, 0 } },
		{ size = { 7, 3, 4 }, offset = { 0.5, -0.5, 0 }, color = shade(colour, 1.06) },
		{ size = { 3.5, 2.5, 3.5 }, offset = { -0.25, 2.25, 0 }, color = shade(colour, 1.12) },
		{ size = { 1.5, 1.5, 0.5 }, offset = { -3, -3, 2.1 }, color = fleck },
		{ size = { 1, 1, 0.5 }, offset = { 2, -0.5, 2.1 }, color = fleck },
		{ size = { 1, 1, 0.5 }, offset = { 3.5, -3.5, -2.1 }, color = fleck },
	}
end

local SULFUR = { 222, 206, 70 }
local SALTPETRE = { 232, 230, 220 }
local HAZMAT = { 226, 196, 54 }
-- (Mekanism's names for the pieces, Leather's armor points, and the share of radiation each keeps
-- out.)
local HAZMAT_NAMES = { "Hazmat Mask", "Hazmat Gown", "Hazmat Pants", "Hazmat Boots" }
local HAZMAT_POINTS = { 1, 3, 2, 1 }
local HAZMAT_SHIELDING = { 0.25, 0.4, 0.2, 0.15 }
local HAZMAT_LORE = {
	"Keeps out a quarter of radiation.",
	"Keeps out two fifths of radiation.",
	"Keeps out a fifth of radiation.",
	"Keeps out a little radiation. A full suit keeps out all.",
}

return function(define: Define.Context): { Schema.ItemSpec }
	local list: { Schema.ItemSpec } = {}
	for _, name in { "Copper", "Lead", "Zinc", "Brass" } do
		define.append(list, define.metal(metals[name]).items)
	end
	table.insert(list, {
		name = "Sulfur",
		color = SULFUR,
		material = "Sand",
		model = powder(define.shade, SULFUR, { 170, 150, 40 }),
		icon = "",
		lore = "Two saltpetre, a sulfur and a coal make four gunpowder.",
		knowledge = { smelt = 0.1 },
	})
	table.insert(list, {
		name = "Saltpetre",
		color = SALTPETRE,
		material = "Sand",
		model = powder(define.shade, SALTPETRE, { 190, 186, 172 }),
		icon = "",
		lore = "Gunpowder's main part, with sulfur and coal.",
		knowledge = { smelt = 0.1 },
	})
	define.append(list, define.metal(metals.Uranium).items)
	for i, piece in define.ARMOR_PIECES do
		table.insert(list, {
			name = `Hazmat{piece.name}`,
			displayName = HAZMAT_NAMES[i],
			maxStack = 1,
			armor = { slot = piece.slot, defense = HAZMAT_POINTS[i], toughness = 0 },
			color = HAZMAT,
			material = "Fabric",
			model = piece.model,
			icon = "",
			lore = HAZMAT_LORE[i],
			age = "iron",
			shielding = HAZMAT_SHIELDING[i],
		})
	end
	return list
end
