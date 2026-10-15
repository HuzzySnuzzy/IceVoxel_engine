--!strict
--[[
	The status icons' silhouettes (Ui/StatusCluster draws them), as vector drawings for Ui/Masks:
	pure, so the specs render every one (tests/spec/StatusLayout). Our own simple shapes in unit
	coordinates (0..1 across and down a square mask), drawn for this game, not traced from
	anything:

	  notifiers  health a cross (two rounded bars), food a stomach (a rounded sack with its tube in
	             at the top left and out at the bottom left), thirst a drop (a circle under a
	             triangle meeting it at its tangents), temperature a thermometer (a rounded tube
	             over a round bulb), mana a four-point star, armor a vest (a V neck and arm holes)
	  badges     Bleeding two drops, Infection a round cell with knobs, Poison a flask, Wither a
	             skull, Hunger a drumstick, Thirst (dirty water) a drop with a hole, Nausea a broken
	             spiral, Climate Clemency a shield, Internal Warmth a flame, Internal Chill a
	             snowflake
	  chevrons   a rising and a falling chevron (a wide flat "^" and "v"), CHEVRON_W x CHEVRON_H

	`render(name)` draws one into a mask (SIZE x SIZE pixels; the chevrons CHEVRON_W x CHEVRON_H;
	SAMPLES x SAMPLES samples a pixel), which Style.Dayz.maskImage shows smaller and keeps, once, by
	name. Names: the notifiers' ("health"), the badges' (Effects names: "Bleeding"), "chevronUp"
	and "chevronDown".
]]

local Masks = require(script.Parent.Masks)

local StatusGlyphs = {}

-- Pixels of a rendered glyph or badge (Theme.Size.MASK), and of a rendered chevron.
StatusGlyphs.SIZE = 48
StatusGlyphs.CHEVRON_W = 48
StatusGlyphs.CHEVRON_H = 20
-- Samples per axis in each pixel: 3 x 3 (nine levels of edge) like Ui/Silhouettes. Drawing a
-- mask costs its samples and Style.Dayz draws at least one a frame; 4 x 4 cost the slowest
-- glyph about 1.6 times as long (65 against 41 ms under Lune).
StatusGlyphs.SAMPLES = 3

local function circle(x: number, y: number, r: number, cut: boolean?): Masks.Op
	return { shape = { kind = "circle", x = x, y = y, r = r }, cut = cut }
end

local function box(x: number, y: number, w: number, h: number, r: number?, cut: boolean?): Masks.Op
	return { shape = { kind = "rect", x = x, y = y, w = w, h = h, r = r }, cut = cut }
end

local function poly(points: { number }, cut: boolean?): Masks.Op
	return { shape = { kind = "poly", points = points }, cut = cut }
end

local function ring(x: number, y: number, r: number, width: number, cut: boolean?): Masks.Op
	return { shape = { kind = "ring", x = x, y = y, r = r, width = width }, cut = cut }
end

-- A drop centred on `x` whose round part has radius `r` at height `y`, its tip `tip` above that
-- centre: the triangle meets the circle where its sides are tangent to it.
local function drop(x: number, y: number, r: number, tip: number): { Masks.Op }
	local d = tip
	-- (The tangent points: at distance sqrt(d^2 - r^2) from the tip along its sides.)
	local along = math.sqrt(d * d - r * r)
	local sinA, cosA = r / d, along / d
	local tx, ty = along * sinA, along * cosA
	return {
		circle(x, y, r),
		poly({ x, y - d, x + tx, y - d + ty, x - tx, y - d + ty }),
	}
end

local function join(...: { Masks.Op }): { Masks.Op }
	local out: { Masks.Op } = {}
	for _, list in { ... } do
		for _, op in list do
			table.insert(out, op)
		end
	end
	return out
end

-- The six notifiers.
StatusGlyphs.NOTIFIERS = table.freeze({
	health = {
		box(0.36, 0.06, 0.28, 0.88, 0.05),
		box(0.06, 0.36, 0.88, 0.28, 0.05),
	},
	food = {
		circle(0.58, 0.54, 0.34),
		box(0.2, 0.02, 0.18, 0.42, 0.09),
		box(0.06, 0.72, 0.38, 0.16, 0.08),
		circle(0.36, 0.62, 0.1, true),
	},
	thirst = drop(0.5, 0.64, 0.31, 0.6),
	temperature = {
		box(0.39, 0.04, 0.22, 0.64, 0.11),
		circle(0.5, 0.75, 0.21),
	},
	mana = {
		poly({ 0.5, 0.02, 0.61, 0.39, 0.98, 0.5, 0.61, 0.61, 0.5, 0.98, 0.39, 0.61, 0.02, 0.5, 0.39, 0.39 }),
	},
	armor = {
		poly({
			0.2,
			0.06,
			0.38,
			0.06,
			0.5,
			0.28,
			0.62,
			0.06,
			0.8,
			0.06,
			0.8,
			0.22,
			0.94,
			0.38,
			0.94,
			0.94,
			0.06,
			0.94,
			0.06,
			0.38,
			0.2,
			0.22,
		}),
	},
} :: { [string]: { Masks.Op } })

-- The badges, by Effects name.
StatusGlyphs.BADGES = table.freeze({
	Bleeding = join(drop(0.38, 0.66, 0.27, 0.54), drop(0.78, 0.4, 0.14, 0.3)),
	Infection = {
		circle(0.5, 0.5, 0.27),
		circle(0.5, 0.12, 0.09),
		circle(0.5, 0.88, 0.09),
		circle(0.12, 0.5, 0.09),
		circle(0.88, 0.5, 0.09),
		circle(0.23, 0.23, 0.09),
		circle(0.77, 0.23, 0.09),
		circle(0.23, 0.77, 0.09),
		circle(0.77, 0.77, 0.09),
	},
	Poison = {
		box(0.4, 0.04, 0.2, 0.34),
		box(0.32, 0.02, 0.36, 0.1, 0.04),
		circle(0.5, 0.64, 0.33),
	},
	Wither = {
		circle(0.5, 0.42, 0.38),
		box(0.28, 0.56, 0.44, 0.38, 0.06),
		circle(0.34, 0.44, 0.11, true),
		circle(0.66, 0.44, 0.11, true),
		poly({ 0.5, 0.58, 0.57, 0.7, 0.43, 0.7 }, true),
		box(0.41, 0.8, 0.05, 0.14, nil, true),
		box(0.54, 0.8, 0.05, 0.14, nil, true),
	},
	Hunger = {
		circle(0.36, 0.64, 0.3),
		poly({ 0.5, 0.44, 0.76, 0.18, 0.84, 0.26, 0.58, 0.52 }),
		circle(0.76, 0.1, 0.09),
		circle(0.92, 0.26, 0.09),
	},
	Thirst = join(drop(0.5, 0.64, 0.31, 0.6), { circle(0.5, 0.66, 0.12, true) }),
	Nausea = {
		ring(0.5, 0.5, 0.47, 0.13),
		ring(0.5, 0.5, 0.25, 0.13),
		box(0.5, 0.38, 0.5, 0.13, nil, true),
		box(0.62, 0.38, 0.24, 0.13),
	},
	ClimateClemency = {
		poly({ 0.12, 0.06, 0.88, 0.06, 0.88, 0.5, 0.5, 0.95, 0.12, 0.5 }),
	},
	InternalWarmth = {
		poly({
			0.5,
			0.02,
			0.63,
			0.25,
			0.79,
			0.42,
			0.84,
			0.66,
			0.72,
			0.88,
			0.5,
			0.97,
			0.28,
			0.88,
			0.16,
			0.66,
			0.22,
			0.44,
			0.34,
			0.56,
			0.37,
			0.32,
		}),
	},
	InternalChill = {
		box(0.44, 0.04, 0.12, 0.92),
		poly({ 0.13, 0.2, 0.93, 0.66, 0.87, 0.8, 0.07, 0.34 }),
		poly({ 0.87, 0.2, 0.93, 0.34, 0.13, 0.8, 0.07, 0.66 }),
	},
} :: { [string]: { Masks.Op } })

-- The trend chevrons (in their CHEVRON_W x CHEVRON_H masks).
StatusGlyphs.CHEVRON_UP = table.freeze({
	poly({ 0, 1, 0.5, 0, 1, 1, 0.72, 1, 0.5, 0.55, 0.28, 1 }),
} :: { Masks.Op })
StatusGlyphs.CHEVRON_DOWN = table.freeze({
	poly({ 0, 0, 0.5, 1, 1, 0, 0.72, 0, 0.5, 0.45, 0.28, 0 }),
} :: { Masks.Op })

-- The drawing named `name` (see the header), nil for an unknown name.
function StatusGlyphs.ops(name: string): { Masks.Op }?
	if name == "chevronUp" then
		return StatusGlyphs.CHEVRON_UP
	elseif name == "chevronDown" then
		return StatusGlyphs.CHEVRON_DOWN
	end
	return StatusGlyphs.NOTIFIERS[name] or StatusGlyphs.BADGES[name]
end

-- The mask of drawing `name` at its size (an unknown name draws an empty glyph).
function StatusGlyphs.render(name: string): Masks.Mask
	local ops = StatusGlyphs.ops(name) or {}
	if name == "chevronUp" or name == "chevronDown" then
		return Masks.render(ops, StatusGlyphs.CHEVRON_W, StatusGlyphs.CHEVRON_H, StatusGlyphs.SAMPLES)
	end
	return Masks.render(ops, StatusGlyphs.SIZE, StatusGlyphs.SIZE, StatusGlyphs.SAMPLES)
end

return StatusGlyphs
