--!strict
--[[
	The inventory family's own silhouettes, as vector drawings for Ui/Masks: the faint ghosts in
	empty worn slots, the pictures at the left of section headers, the glyphs of the top headers'
	buttons, the sections' minus and plus, the closed accessory slot's padlock and the crafting
	arrow. Pure: no Roblox APIs, so the specs check every drawing (tests/spec/Silhouettes). All of
	them are drawn fresh here from circles, rectangles, rings and polygons; none is traced from
	another game's art.

	  worn slots      head (a helmet), chest (a jacket), legs (trousers), feet (a boot),
	                  accessory (a ring with a stone)
	  section heads   backpack, crafting (a hammer), vanity (a top hat)
	  header buttons  gear (the options), close, items (a two by two grid: the creative items)
	  toggles         minus (a shown section collapses), plus (a collapsed one opens)
	  others          padlock (a closed accessory slot), chevron (the crafting arrow, pointing right)

	Rules every drawing keeps:

	  * Unit coordinates (0..1 across and down a square mask), every shape inside the square, so a
	    drawing renders at any size (Masks.render; Ui/Theme's Size.MASK, 48 px, is the size shown
	    on screen through an image, smaller ones are the blocky fallback).
	  * Solid and simple: each reads as itself at 8 x 8 blocky pixels (the header glyphs' size)
	    and is filled, so a white silhouette at 20 % (a slot's ghost) still shows its shape. Lines
	    thinner than a twentieth of the square stay out (they vanish when shown small).
	  * Symmetric about the vertical axis unless the thing is not (a boot, an arrow): the specs
	    hold the mirror of each symmetric drawing to its mask.
	  * `ops` of a name it does not know is empty: an empty mask, never an error (a consumer
	    naming a silhouette that is not drawn yet shows nothing).

	`render` draws one at `size` (default 48) with SAMPLES x SAMPLES samples a pixel: fewer than
	Masks' default 4 x 4, since a 48 px mask is shown at about its own size (3 x 3 gives ten
	levels of edge, plenty) and drawing a mask costs its samples; Style.Dayz draws each name once
	and keeps it.
]]

local Masks = require(script.Parent.Masks)

local Silhouettes = {}

-- Samples per axis per pixel when `render` draws a silhouette.
Silhouettes.SAMPLES = 3
-- The size `render` draws at unless told otherwise (Ui/Theme's Size.MASK).
Silhouettes.SIZE = 48

type Op = Masks.Op

local function rect(x: number, y: number, w: number, h: number, r: number?, cut: boolean?): Op
	return { shape = { kind = "rect", x = x, y = y, w = w, h = h, r = r }, cut = cut }
end

local function circle(x: number, y: number, r: number, cut: boolean?): Op
	return { shape = { kind = "circle", x = x, y = y, r = r }, cut = cut }
end

local function ring(x: number, y: number, r: number, width: number): Op
	return { shape = { kind = "ring", x = x, y = y, r = r, width = width } }
end

local function poly(points: { number }, cut: boolean?): Op
	return { shape = { kind = "poly", points = points }, cut = cut }
end

-- A bar from (x1, y1) to (x2, y2), `half` thick on each side of the line, as a polygon.
local function bar(x1: number, y1: number, x2: number, y2: number, half: number): Op
	local dx, dy = x2 - x1, y2 - y1
	local length = math.sqrt(dx * dx + dy * dy)
	local nx, ny = -dy / length * half, dx / length * half
	return poly({ x1 + nx, y1 + ny, x2 + nx, y2 + ny, x2 - nx, y2 - ny, x1 - nx, y1 - ny })
end

local DRAWINGS: { [string]: { Op } } = {
	-- A helmet from the front: the dome, its brim and the two ear guards.
	head = {
		circle(0.5, 0.58, 0.38),
		rect(0, 0.62, 1, 0.38, nil, true),
		rect(0.08, 0.56, 0.84, 0.1, 0.04),
		rect(0.16, 0.62, 0.15, 0.22, 0.04),
		rect(0.69, 0.62, 0.15, 0.22, 0.04),
	},
	-- A jacket: collar, shoulders, sleeves and body, with its zip cut down the middle.
	chest = {
		poly({
			0.36,
			0.1,
			0.5,
			0.2,
			0.64,
			0.1,
			0.82,
			0.16,
			0.96,
			0.5,
			0.82,
			0.54,
			0.76,
			0.36,
			0.76,
			0.9,
			0.24,
			0.9,
			0.24,
			0.36,
			0.18,
			0.54,
			0.04,
			0.5,
			0.18,
			0.16,
		}),
		rect(0.475, 0.22, 0.05, 0.68, nil, true),
	},
	-- Trousers: the waist and two legs.
	legs = {
		poly({ 0.22, 0.08, 0.78, 0.08, 0.82, 0.92, 0.57, 0.92, 0.5, 0.36, 0.43, 0.92, 0.18, 0.92 }),
		rect(0.22, 0.17, 0.56, 0.05, nil, true),
	},
	-- A boot from the side, toe to the right, on its sole.
	feet = {
		poly({ 0.22, 0.08, 0.54, 0.08, 0.54, 0.5, 0.8, 0.6, 0.92, 0.7, 0.92, 0.84, 0.22, 0.84 }),
		rect(0.18, 0.82, 0.78, 0.1, 0.02),
	},
	-- A ring with its stone on top.
	accessory = {
		ring(0.5, 0.6, 0.3, 0.11),
		poly({ 0.5, 0.08, 0.68, 0.24, 0.5, 0.42, 0.32, 0.24 }),
	},
	-- A backpack: its loop on top, the pack, a seam across it.
	backpack = {
		ring(0.5, 0.22, 0.15, 0.07),
		rect(0.2, 0.22, 0.6, 0.7, 0.12),
		rect(0.2, 0.52, 0.6, 0.05, nil, true),
	},
	-- A hammer: the head across the top, the handle down.
	crafting = {
		rect(0.12, 0.12, 0.76, 0.24, 0.04),
		rect(0.41, 0.36, 0.18, 0.54, 0.03),
	},
	-- A top hat: the crown with a band cut round it, and the brim.
	vanity = {
		rect(0.26, 0.12, 0.48, 0.58, 0.04),
		rect(0.26, 0.54, 0.48, 0.05, nil, true),
		rect(0.06, 0.7, 0.88, 0.12, 0.05),
	},
	-- An X.
	close = {
		bar(0.18, 0.18, 0.82, 0.82, 0.1),
		bar(0.82, 0.18, 0.18, 0.82, 0.1),
	},
	-- Four squares: a grid of items.
	items = {
		rect(0.1, 0.1, 0.36, 0.36, 0.04),
		rect(0.54, 0.1, 0.36, 0.36, 0.04),
		rect(0.1, 0.54, 0.36, 0.36, 0.04),
		rect(0.54, 0.54, 0.36, 0.36, 0.04),
	},
	minus = {
		rect(0.1, 0.39, 0.8, 0.22),
	},
	plus = {
		rect(0.1, 0.39, 0.8, 0.22),
		rect(0.39, 0.1, 0.22, 0.8),
	},
	-- A padlock: the shackle over the body, a keyhole cut into it.
	padlock = {
		ring(0.5, 0.4, 0.26, 0.1),
		rect(0.16, 0.42, 0.68, 0.48, 0.06),
		circle(0.5, 0.6, 0.08, true),
		rect(0.46, 0.62, 0.08, 0.16, nil, true),
	},
	-- A flat chevron pointing right.
	chevron = {
		poly({ 0.16, 0.12, 0.5, 0.12, 0.86, 0.5, 0.5, 0.88, 0.16, 0.88, 0.52, 0.5 }),
	},
}

-- The gear: eight teeth (two crossed bars and two crossed diagonals, their middles under the
-- wheel), the wheel and its hole. (Bars, not eight turned blocks: a rect is cheap to sample.)
do
	local half = 0.085
	local reach = 0.47 / math.sqrt(2)
	DRAWINGS.gear = {
		rect(0.5 - half, 0.03, 2 * half, 0.94),
		rect(0.03, 0.5 - half, 0.94, 2 * half),
		bar(0.5 - reach, 0.5 - reach, 0.5 + reach, 0.5 + reach, half),
		bar(0.5 + reach, 0.5 - reach, 0.5 - reach, 0.5 + reach, half),
		circle(0.5, 0.5, 0.31),
		circle(0.5, 0.5, 0.13, true),
	}
end

-- Every name drawn here, in the order of the header.
Silhouettes.NAMES = table.freeze({
	"head",
	"chest",
	"legs",
	"feet",
	"accessory",
	"backpack",
	"crafting",
	"vanity",
	"gear",
	"close",
	"items",
	"minus",
	"plus",
	"padlock",
	"chevron",
})

-- The names whose drawing is its own mirror image left to right.
Silhouettes.SYMMETRIC = table.freeze({
	head = true,
	chest = true,
	legs = true,
	accessory = true,
	backpack = true,
	crafting = true,
	vanity = true,
	gear = true,
	close = true,
	items = true,
	minus = true,
	plus = true,
	padlock = true,
} :: { [string]: boolean })

local EMPTY: { Op } = table.freeze({})

-- The drawing of `name` (Masks operations; empty for a name not drawn here).
function Silhouettes.ops(name: string): { Op }
	return DRAWINGS[name] or EMPTY
end

-- Is `name` drawn here?
function Silhouettes.has(name: string): boolean
	return DRAWINGS[name] ~= nil
end

-- The mask of `name` at `size` x `size` (default SIZE), with SAMPLES x SAMPLES samples a pixel.
function Silhouettes.render(name: string, size: number?): Masks.Mask
	local side = size or Silhouettes.SIZE
	return Masks.render(Silhouettes.ops(name), side, side, Silhouettes.SAMPLES)
end

-- The same mask, not drawn yet (Masks.step draws it a few rows at a time: Style.Dayz).
function Silhouettes.job(name: string, size: number?): Masks.Job
	local side = size or Silhouettes.SIZE
	return Masks.begin(Silhouettes.ops(name), side, side, Silhouettes.SAMPLES)
end

return Silhouettes
