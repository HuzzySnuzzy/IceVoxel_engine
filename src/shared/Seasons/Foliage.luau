--!strict
--[[
	Foliage colours by season, pure (Config.Seasons.Foliage over Shared/Seasons/Calendar and
	SeasonClimate): the colour grass tops, leaves, tinted plants and vines take through the year.
	The client recolours what it draws from it (Rendering/SeasonTint drives Rendering/ChunkRenderer's
	budgeted sweep and the far meshes; Rendering/TextureLooks.seasonalTint turns a colour into the
	parts', images' and decals' colours). Items, icons and the map keep the authored colours.

	  Kinds      `kindOf(appearance)`: GRASS (Grass, DryGrass: their top texture follows the block's
	             colour), LEAVES (every *Leaves block), PLANT (tinted plants: grass and ferns, which
	             scale with the grass palette as their soil's tint does) and VINE, else NONE. Each
	             follows a foliage class's palette (`foliageOf`): "grass" (grass blocks and
	             plants), "deciduous" (oak and acacia leaves, vines), "birch", "evergreen" (spruce)
	             or "tropical" (jungle).
	  Palettes   Keyframes over the year's progress p (`progress`: (season - 1 + progress) / 4,
	             Autumn 0..0.25, Winter, Spring, Summer 0.75..1, whatever the seasons' lengths),
	             each { at, colour, keep }: a keyframe stands for lerp(colour, authored, keep) in
	             linear light (keep 1: the block's authored colour exactly), and between keyframes
	             (wrapping over the year's end) the colour moves evenly in CIELAB, so equal steps of
	             p differ by equal ΔE76 along a segment. A biome class may replace a foliage class's
	             keyframes (Overrides: dry biomes' grass yellows in summer, tropical biomes keep
	             every colour all year; a string names another class's keyframes).
	  Plants     A tinted plant's colour is its own times the grass palette's colour over the
	             Grass block's authored one (per channel), as Blocks.FOLIAGE_TINTS scale it by
	             soil: plants are authored in the Grass block's green.
	  Snow dust  `w = cover x Dust` (cover: SeasonClimate.snowCover of the biome class, the far
	             landscape's white; Dust per kind: grass and plants `grass`, leaves and vines
	             `leaves`, spruce `evergreen`, jungle `tropical`) moves the colour towards
	             SnowColour in CIELAB, so the far landscape reads white in winter beyond the real
	             snow layers.
	  Steps      `stepOf(time)`: calendar time in steps of BlendDays / 24 days (100 s of play at
	             the defaults), each drawn as at its `midpoint`; consecutive steps differ by at most
	             MAX_STEP_DELTA (ΔE76 2.5) all year, for every seasonal appearance and biome class
	             (tests/spec/Foliage), below a noticeable pop. The far meshes use coarser steps
	             (`farStepOf`: FarStepDays).
	  Targets    `targets(time)`: every seasonal appearance's colour per biome class (`classIndex`:
	             SeasonClimate.CLASSES' order) at that calendar time, as sRGB 0..255; nil while the
	             foliage does not follow the seasons (`active`: Config.Seasons.Enabled,
	             Config.Seasons.Foliage.Enabled and the calendar's state): the authored colours,
	             which callers leave untouched.

	Requires Config, Blocks, Calendar and SeasonClimate only (Rendering/ChunkRenderer and
	Rendering/SeasonTint require this, never the reverse).
]]

local Blocks = require(script.Parent.Parent.Blocks)
local Config = require(script.Parent.Parent.Config)
local Calendar = require(script.Parent.Calendar)
local SeasonClimate = require(script.Parent.SeasonClimate)

-- r, g, b in sRGB 0..255 (not rounded).
export type Rgb = { number }
export type Keyframe = { at: number, colour: { number }, keep: number }
export type FoliageClass = "grass" | "deciduous" | "birch" | "evergreen" | "tropical"

--[[
	Every seasonal appearance's colour at one calendar time: `colours[class][appearance]` (class:
	`classIndex`, SeasonClimate.CLASSES' order), with the time, the year's progress `p` and the
	snow cover per class it was worked out for.
]]
export type Targets = {
	time: number,
	p: number,
	covers: { number },
	colours: { { [number]: Rgb } },
}

local Foliage = {}

Foliage.NONE = 0
Foliage.GRASS = 1
Foliage.LEAVES = 2
Foliage.PLANT = 3
Foliage.VINE = 4
-- The most ΔE76 between the colours of two consecutive steps (tests/spec/Foliage).
Foliage.MAX_STEP_DELTA = 2.5
-- Biome classes, in index order (`classIndex`).
Foliage.CLASSES = SeasonClimate.CLASSES
Foliage.TEMPERATE = table.find(SeasonClimate.CLASSES, "temperate") :: number
local ALL_CLASSES: { number } = {}
for i in SeasonClimate.CLASSES do
	table.insert(ALL_CLASSES, i)
end

local Settings = Config.Seasons.Foliage

local classIndexOf: { [string]: number } = {}
for i, name in SeasonClimate.CLASSES do
	classIndexOf[name] = i
end

-- The index of biome class `class` (SeasonClimate.CLASSES' order; unknown ones: temperate's).
function Foliage.classIndex(class: string): number
	return classIndexOf[class] or Foliage.TEMPERATE
end

-- The biome class of index `index`.
function Foliage.className(index: number): SeasonClimate.Class
	return (SeasonClimate.CLASSES[index] or "temperate") :: SeasonClimate.Class
end

--[[ Seasonal appearances ]]

local LEAF_CLASS: { [string]: FoliageClass } = {
	OakLeaves = "deciduous",
	AcaciaLeaves = "deciduous",
	BirchLeaves = "birch",
	SpruceLeaves = "evergreen",
	JungleLeaves = "tropical",
}

-- Per appearance: its kind (u8) and its foliage class, authored colour and dust.
Foliage.kindLut = buffer.create(#Blocks.appearances + 1)
local foliageOf: { [number]: FoliageClass } = {}
local authored: { [number]: Rgb } = {}
local dustOf: { [number]: string } = {}
local seasonalList: { number } = {}

local GRASS_COLOUR = Blocks.get(Blocks.id.Grass).color

local function register(appearance: number, kind: number, class: FoliageClass, dust: string)
	if buffer.readu8(Foliage.kindLut, appearance) ~= Foliage.NONE then
		return
	end
	buffer.writeu8(Foliage.kindLut, appearance, kind)
	foliageOf[appearance] = class
	local c = Blocks.appearances[appearance].color
	authored[appearance] = { c[1], c[2], c[3] }
	dustOf[appearance] = dust
	table.insert(seasonalList, appearance)
end

for id = 0, Blocks.count - 1 do
	local def = Blocks.get(id)
	local appearance = def.appearance
	local info = Blocks.appearances[appearance]
	if info == nil then
		continue
	end
	local name = def.name
	if name == "Grass" or name == "DryGrass" then
		register(appearance, Foliage.GRASS, "grass", "grass")
	elseif LEAF_CLASS[name] then
		local class: FoliageClass = LEAF_CLASS[name] :: FoliageClass
		register(
			appearance,
			Foliage.LEAVES,
			class,
			if class == "evergreen" then "evergreen" elseif class == "tropical" then "tropical" else "leaves"
		)
	elseif info.tinted then
		register(appearance, Foliage.PLANT, "grass", "grass")
	elseif name == "Vine" or string.sub(name, 1, 4) == "Vine" then
		register(appearance, Foliage.VINE, "deciduous", "leaves")
	end
end
table.sort(seasonalList)

-- The kind of `appearance` (NONE: its colour never changes with the seasons).
function Foliage.kindOf(appearance: number): number
	if appearance < 0 or appearance > #Blocks.appearances then
		return Foliage.NONE
	end
	return buffer.readu8(Foliage.kindLut, appearance)
end

function Foliage.isSeasonal(appearance: number): boolean
	return Foliage.kindOf(appearance) ~= Foliage.NONE
end

-- The foliage class whose palette `appearance` follows (nil: not seasonal).
function Foliage.foliageOf(appearance: number): FoliageClass?
	return foliageOf[appearance]
end

-- The colour a keep of 1 gives (the appearance's BlockList colour), sRGB 0..255.
function Foliage.authored(appearance: number): Rgb?
	return authored[appearance]
end

-- Every seasonal appearance id, ascending (read only).
function Foliage.appearances(): { number }
	return seasonalList
end

--[[ Colour spaces ]]

local function toLinear(c: number): number
	return if c <= 0.04045 then c / 12.92 else ((c + 0.055) / 1.055) ^ 2.4
end
local function toSrgb(l: number): number
	return if l <= 0.0031308 then l * 12.92 else 1.055 * l ^ (1 / 2.4) - 0.055
end

-- D65 white and CIELAB's constants.
local XN, YN, ZN = 0.95047, 1.0, 1.08883
local EPSILON = 216 / 24389
local KAPPA = 24389 / 27

local function f(t: number): number
	return if t > EPSILON then t ^ (1 / 3) else (KAPPA * t + 16) / 116
end
local function fInverse(t: number): number
	local cube = t * t * t
	return if cube > EPSILON then cube else (116 * t - 16) / KAPPA
end

-- sRGB 0..255 -> CIELAB (D65): L, a, b.
function Foliage.toLab(c: { number }): (number, number, number)
	local r, g, b = toLinear(c[1] / 255), toLinear(c[2] / 255), toLinear(c[3] / 255)
	local x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / XN
	local y = (0.2126729 * r + 0.7151522 * g + 0.0721750 * b) / YN
	local z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / ZN
	local fx, fy, fz = f(x), f(y), f(z)
	return 116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)
end

-- CIELAB -> sRGB 0..255 (clamped to the gamut), written into `into` when given.
function Foliage.fromLab(l: number, a: number, b: number, into: Rgb?): Rgb
	local fy = (l + 16) / 116
	local x = XN * fInverse(fy + a / 500)
	local y = YN * fInverse(fy)
	local z = ZN * fInverse(fy - b / 200)
	local r = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
	local g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
	local bl = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z
	local out = into or table.create(3)
	out[1] = math.clamp(toSrgb(math.max(r, 0)), 0, 1) * 255
	out[2] = math.clamp(toSrgb(math.max(g, 0)), 0, 1) * 255
	out[3] = math.clamp(toSrgb(math.max(bl, 0)), 0, 1) * 255
	return out
end

-- ΔE76 between two sRGB 0..255 colours (the distance in CIELAB).
function Foliage.deltaE(c1: { number }, c2: { number }): number
	local l1, a1, b1 = Foliage.toLab(c1)
	local l2, a2, b2 = Foliage.toLab(c2)
	return math.sqrt((l1 - l2) ^ 2 + (a1 - a2) ^ 2 + (b1 - b2) ^ 2)
end

-- lerp(colour, base, keep) in linear light (sRGB 0..255 in and out).
local function keepMix(colour: { number }, base: { number }, keep: number): Rgb
	if keep >= 1 then
		return { base[1], base[2], base[3] }
	end
	local out = table.create(3)
	for k = 1, 3 do
		local from, to = toLinear(colour[k] / 255), toLinear(base[k] / 255)
		out[k] = toSrgb(from + (to - from) * keep) * 255
	end
	return out
end

--[[ Palettes ]]

-- A palette ready to evaluate: keyframe positions and their colours in CIELAB.
type Palette = { at: { number }, l: { number }, a: { number }, b: { number } }

local function keyframesOf(class: FoliageClass, biome: string): { Keyframe }
	local overrides = (Settings.Overrides :: any)[biome]
	local name: string = class
	local list: any = nil
	if overrides then
		local o = overrides[class]
		if type(o) == "string" then
			name = o
		elseif type(o) == "table" then
			list = o
		end
	end
	if list == nil then
		list = (Settings.Keyframes :: any)[name]
	end
	assert(type(list) == "table" and #list > 0, `Config.Seasons.Foliage: no keyframes for {name}`)
	return list
end

local function compile(keyframes: { Keyframe }, base: { number }): Palette
	local sorted = table.clone(keyframes)
	table.sort(sorted, function(x, y)
		return x.at < y.at
	end)
	local palette: Palette = { at = {}, l = {}, a = {}, b = {} }
	for i, key in sorted do
		local l, a, b = Foliage.toLab(keepMix(key.colour, base, math.clamp(key.keep, 0, 1)))
		palette.at[i] = key.at - math.floor(key.at)
		palette.l[i], palette.a[i], palette.b[i] = l, a, b
	end
	return palette
end

-- The palette's colour at year progress `p`, as CIELAB.
local function evaluate(palette: Palette, p: number): (number, number, number)
	local at = palette.at
	local n = #at
	if n == 1 then
		return palette.l[1], palette.a[1], palette.b[1]
	end
	local x = p - math.floor(p)
	-- The last keyframe at or before x (wrapping: before the first, the year's last).
	local i = n
	for k = 1, n do
		if at[k] <= x then
			i = k
		else
			break
		end
	end
	local j = if i == n then 1 else i + 1
	local from, to = at[i], at[j]
	local span = to - from
	if span <= 0 then
		span += 1
	end
	local into = x - from
	if into < 0 then
		into += 1
	end
	local t = if span > 0 then math.clamp(into / span, 0, 1) else 0
	return palette.l[i] + (palette.l[j] - palette.l[i]) * t,
		palette.a[i] + (palette.a[j] - palette.a[i]) * t,
		palette.b[i] + (palette.b[j] - palette.b[i]) * t
end

-- Compiled palettes per biome class index and appearance (the colour before snow dust), and each
-- appearance's dust; filled on first use (`reload` after a change of Config).
local palettes: { { [number]: Palette } } = {}
local snowLab = { 0, 0, 0 }
local dust: { [number]: number } = {}

local function build()
	table.clear(palettes)
	for index, biome in SeasonClimate.CLASSES do
		local byAppearance: { [number]: Palette } = {}
		for _, appearance in seasonalList do
			local kind = Foliage.kindOf(appearance)
			local class = foliageOf[appearance]
			-- (Plants follow the Grass block's palette, scaled to their own colour in `colour`.)
			local base = if kind == Foliage.PLANT then GRASS_COLOUR else authored[appearance]
			byAppearance[appearance] = compile(keyframesOf(class :: FoliageClass, biome), base)
		end
		palettes[index] = byAppearance
	end
	snowLab[1], snowLab[2], snowLab[3] = Foliage.toLab(Settings.SnowColour)
	for _, appearance in seasonalList do
		local value = (Settings.Dust :: any)[dustOf[appearance]]
		dust[appearance] = if type(value) == "number" then math.clamp(value, 0, 1) else 0
	end
end

-- Compiles the palettes again from Config.Seasons.Foliage (after a test or a tuning changed it).
function Foliage.reload()
	build()
end

--[[ Colours ]]

-- The year's progress p of a Calendar.Position: (season - 1 + progress) / 4.
function Foliage.progress(position: Calendar.Position): number
	return (position.season - 1 + position.progress) / Calendar.SEASONS
end

--[[
	The colour of `appearance` in a biome of class `class` (index or name) at year progress `p`
	with snow cover `cover` (0..1), sRGB 0..255 (written into `into` when given); nil for an
	appearance that is not seasonal.
]]
function Foliage.colour(appearance: number, class: number | string, p: number, cover: number, into: Rgb?): Rgb?
	local kind = Foliage.kindOf(appearance)
	if kind == Foliage.NONE then
		return nil
	end
	if #palettes == 0 then
		build()
	end
	local index = if type(class) == "number" then class else Foliage.classIndex(class)
	local palette = (palettes[index] or palettes[Foliage.TEMPERATE])[appearance]
	local l, a, b = evaluate(palette, p)
	local w = math.clamp(cover, 0, 1) * (dust[appearance] or 0)
	if w > 0 then
		l += (snowLab[1] - l) * w
		a += (snowLab[2] - a) * w
		b += (snowLab[3] - b) * w
	end
	local out = Foliage.fromLab(l, a, b, into)
	if kind == Foliage.PLANT then
		-- Their own colour times the grass colour over the Grass block's (see the header).
		local own = authored[appearance]
		for k = 1, 3 do
			out[k] = math.min(255, own[k] * out[k] / math.max(GRASS_COLOUR[k], 1))
		end
	end
	return out
end

--[[ Steps and targets ]]

-- Calendar days per near step (BlendDays / 24) and per far step (FarStepDays).
function Foliage.stepDays(): number
	local blend = Config.Seasons.BlendDays
	return if blend > 0 then blend / 24 else 1 / 24
end

function Foliage.farStepDays(): number
	return math.max(Settings.FarStepDays, Foliage.stepDays())
end

-- The near step holding calendar time `time`, and a step's midpoint (calendar time).
function Foliage.stepOf(time: number): number
	return math.floor(time / Foliage.stepDays())
end

function Foliage.midpoint(step: number): number
	return (step + 0.5) * Foliage.stepDays()
end

-- The far step holding calendar time `time`, and a far step's midpoint.
function Foliage.farStepOf(time: number): number
	return math.floor(time / Foliage.farStepDays())
end

function Foliage.farMidpoint(step: number): number
	return (step + 0.5) * Foliage.farStepDays()
end

-- Is foliage configured to follow the seasons (Config.Seasons.Enabled and Foliage.Enabled)?
function Foliage.configured(): boolean
	return Config.Seasons.Enabled == true and Settings.Enabled == true
end

-- Does foliage follow the seasons now (configured, and the calendar's state `s` enabled)?
function Foliage.active(s: Calendar.State?): boolean
	return Foliage.configured() and (s or Calendar.state()).enabled
end

--[[
	Every seasonal appearance's colour per biome class at calendar time `time` (see the header),
	reusing `into`'s tables when given; nil when the foliage does not follow the seasons (`active`).
]]
function Foliage.targets(time: number, s: Calendar.State?, into: Targets?): Targets?
	local state = s or Calendar.state()
	if not Foliage.active(state) then
		return nil
	end
	local position = Calendar.at(time, state)
	local p = Foliage.progress(position)
	local targets: Targets = into or { time = 0, p = 0, covers = {}, colours = {} }
	targets.time = time
	targets.p = p
	for index, class in SeasonClimate.CLASSES do
		local cover = SeasonClimate.snowCover(position, class :: SeasonClimate.Class)
		targets.covers[index] = cover
		local colours = targets.colours[index]
		if colours == nil then
			colours = {}
			targets.colours[index] = colours
		end
		for _, appearance in seasonalList do
			colours[appearance] = Foliage.colour(appearance, index, p, cover, colours[appearance]) :: Rgb
		end
	end
	return targets
end

--[[
	The largest ΔE76 between two targets' colours over the biome classes `classes` (indices; nil:
	all); nil targets stand for the authored colours.
]]
function Foliage.drift(from: Targets?, to: Targets?, classes: { number }?): number
	local worst = 0
	local list: { number } = classes or ALL_CLASSES
	for _, index in list do
		local a = if from then from.colours[index] else nil
		local b = if to then to.colours[index] else nil
		if a == nil and b == nil then
			continue
		end
		for _, appearance in seasonalList do
			local ca = if a then a[appearance] else authored[appearance]
			local cb = if b then b[appearance] else authored[appearance]
			worst = math.max(worst, Foliage.deltaE(ca, cb))
		end
	end
	return worst
end

return Foliage
