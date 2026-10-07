--!strict
--!native
--[[
	The cloud layer as levels of detail, pure (Weather/CloudView builds the parts; tests/spec/
	WeatherVisuals checks the rings, the merging and the part counts). Minecraft draws flat-box
	clouds, 12-block cells 4 blocks thick at one height, from a fixed image drifting east; here the
	cells come from the weather (Shared/Weather) and drift with its wind, out to the view distance.

	  Frame    clouds live in the air's frame, (u, w) = (x, z) - D(t) (WeatherModel's displacement):
	           a cell is fixed there, so the whole layer drifts with the wind (CloudView moves the
	           parts, not this plan) and a storm's clouds arrive with its rain.
	  Levels   like the terrain's levels of detail, a clipmap: level L has square cells of
	           `cell` x 2^L blocks, `cells` across (a multiple of 4), centred on the camera's
	           air-frame position snapped to two of its cells (`window`); the next level's window
	           is cut out of it (`hole`, on its cell edges), so the levels make rings, small cells
	           near the camera and coarse ones far off. Levels are added until one reaches the
	           view distance (`levels`); cells farther than the view distance are left out.
	  Cells    a cell is cloudy where a smooth pattern (Perlin noise in the air's frame, its
	           wavelength `wavelength` blocks or 3 cells, whichever is longer, so far rings keep
	           whole clouds; finer raggedness near the camera) is below the clouded fraction
	           coverBase + (1 - coverBase) x cover (the weather's cloud cover at the cell): fair
	           weather keeps scattered clouds, an overcast sky closes up (`cloudy`). The pattern is
	           made about uniform in 0..1 (a logistic of the noise over its spread, SPREAD), so the
	           fraction is the share of cells clouded (checked in the spec).
	  Look     the weather's precipitation p and thunder t at the cell, in RAIN_STEPS and
	           THUNDER_STEPS steps (`buckets`, so one storm's cells share looks): the grey of
	           Weather.cloudColour (white fair-weather clouds, dark grey rain clouds, nearly black
	           thunderstorms) in SHADES steps (`shadeOf`); the base lowered by `drop` x p, the
	           thickness `thickness` + `rainThickness` x p + `tower` x t (thunderstorms tower up
	           as anvils), on `step`-block steps (`heights`). Rain shafts (`shafts`): under rain
	           clouds of levels `shaftLevel` and up with p over `shaftMin`, a grey see-through
	           veil from the lowest rain cloud's base down to the ground (light or heavy, so a
	           storm's shafts merge), so distant rain shows as rain.
	  Merge    equal neighbouring cells (same look and heights) merge into rectangles, greedily:
	           runs along u, then down while the rows below match (`merge`), at most `maxPart`
	           blocks a side (a part's 2048 studs), so an overcast sky is a few boxes a level. Each box has a `key` of its rectangle and look: a new plan
	           keeps the parts of boxes it shares with the old one (CloudView's diff).

	Positions are blocks; boxes are air-frame rectangles [x0, x1) x [z0, z1) from `base` to `top`
	(a shaft's base is filled in by CloudView: the ground under it).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Hash = require(Shared.Util.Hash)
local Weather = require(Shared.Weather)

local noise = math.noise
local floor = math.floor
local exp = math.exp

export type Settings = {
	-- Base height of fair-weather clouds (blocks).
	altitude: number,
	-- Fair-weather thickness (blocks; Fast: 1, a flat layer).
	thickness: number,
	-- Level 0's cell (blocks) and cells across every level (a multiple of 4).
	cell: number,
	cells: number,
	-- How far clouds reach (blocks; the view distance).
	viewDistance: number,
	-- Share of the sky clouded with no cover at all, and the pattern's shortest wavelength.
	coverBase: number,
	wavelength: number,
	-- Rain lowers the base by `drop`, thickens by `rainThickness`; thunder adds `tower` on top.
	drop: number,
	rainThickness: number,
	tower: number,
	-- Heights snap to this many blocks (so neighbours merge).
	step: number,
	-- Rain shafts: on, from which level, over which precipitation.
	shafts: boolean,
	shaftLevel: number,
	shaftMin: number,
	maxLevels: number,
	-- Longest side of one box (blocks: Roblox's parts are at most 2048 studs).
	maxPart: number,
}

export type Box = {
	x0: number,
	z0: number,
	x1: number,
	z1: number,
	base: number,
	top: number,
	-- 1 (white) .. SHADES (darkest); a shaft's 1 (light) or 2 (heavy).
	shade: number,
	shaft: boolean,
	key: string,
}

export type Window = {
	level: number,
	size: number,
	u0: number,
	w0: number,
	cols: number,
	-- The inner level's window cut out of this one (nil on level 0).
	hole: { u0: number, w0: number, u1: number, w1: number }?,
}

-- The pattern's seeded offsets.
export type Pattern = { ox: number, oz: number, fx: number, fz: number }

-- Samples the weather at air-frame cell centres: `cols` x `rows` from (u0, w0), `step` apart,
-- 3 bytes a cell (Shared/Weather's grid: precipitation, thunder, cover x 255).
export type Sampler = (u0: number, w0: number, step: number, cols: number, rows: number) -> buffer

local CloudLod = {}

CloudLod.SHADES = 6
CloudLod.RAIN_STEPS = 4
CloudLod.THUNDER_STEPS = 3
-- Spread of math.noise's values (their standard deviation, measured: tests/spec/WeatherVisuals),
-- for the logistic that makes the pattern about uniform.
CloudLod.SPREAD = 0.28
-- The darkest grey a cloud gets (Weather.cloudColour's luminance at full thunder, rounded).
CloudLod.DARKEST = 0.15

-- The Clouds setting's values (Options > Weather...).
CloudLod.OFF = 0
CloudLod.FAST = 1
CloudLod.FANCY = 2

--[[
	The settings for Clouds `mode` (FAST or FANCY) and a view of `viewDistance` blocks, from
	Config.Weather.Clouds: Fast is one flat layer (a block thick, no drop, towers or shafts) of
	cells twice the size, FastCells across a ring.
]]
function CloudLod.settings(mode: number, viewDistance: number): Settings
	local clouds = Config.Weather.Clouds
	local fancy = mode >= CloudLod.FANCY
	return {
		altitude = clouds.Altitude,
		thickness = if fancy then clouds.Thickness else 1,
		cell = if fancy then clouds.Cell else clouds.Cell * 2,
		cells = if fancy then clouds.Cells else clouds.FastCells,
		viewDistance = viewDistance,
		coverBase = clouds.CoverBase,
		wavelength = clouds.Wavelength,
		drop = if fancy then clouds.Drop else 0,
		rainThickness = if fancy then clouds.RainThickness else 0,
		tower = if fancy then clouds.Tower else 0,
		step = if fancy then clouds.Step else 1,
		shafts = fancy,
		shaftLevel = clouds.ShaftLevel,
		shaftMin = clouds.ShaftMin,
		maxLevels = clouds.MaxLevels,
		maxPart = math.floor(2048 / Config.BlockSize),
	}
end

-- The pattern of world `seed`.
function CloudLod.pattern(seed: number): Pattern
	local salt = Hash.string("clouds")
	return {
		ox = Hash.hash3(seed, salt, 1, 0) % 65536 / 256 + 0.31,
		oz = Hash.hash3(seed, salt, 2, 0) % 65536 / 256 + 0.67,
		fx = Hash.hash3(seed, salt, 3, 0) % 65536 / 256 + 0.13,
		fz = Hash.hash3(seed, salt, 4, 0) % 65536 / 256 + 0.89,
	}
end

-- How many levels reach the view distance.
function CloudLod.levels(settings: Settings): number
	local reach = settings.cells / 2 * settings.cell
	local count = 1
	while reach < settings.viewDistance and count < settings.maxLevels do
		reach *= 2
		count += 1
	end
	return count
end

-- Level `level`'s window around the camera at air-frame (cu, cw).
function CloudLod.window(settings: Settings, level: number, cu: number, cw: number): Window
	local size = settings.cell * 2 ^ level
	local half = settings.cells / 2 * size
	local cx = floor(cu / (2 * size) + 0.5) * 2 * size
	local cz = floor(cw / (2 * size) + 0.5) * 2 * size
	local hole = nil
	if level > 0 then
		local inner = size / 2
		local ix = floor(cu / size + 0.5) * size
		local iz = floor(cw / size + 0.5) * size
		local innerHalf = settings.cells / 2 * inner
		hole = { u0 = ix - innerHalf, w0 = iz - innerHalf, u1 = ix + innerHalf, w1 = iz + innerHalf }
	end
	return { level = level, size = size, u0 = cx - half, w0 = cz - half, cols = settings.cells, hole = hole }
end

-- The pattern (about uniform, 0..1) at air-frame (u, w) for cells of `size` blocks.
function CloudLod.patternAt(pattern: Pattern, settings: Settings, u: number, w: number, size: number): number
	local wavelength = math.max(settings.wavelength, size * 3)
	local n = noise((u / wavelength + pattern.ox) % 256, (w / wavelength + pattern.oz) % 256, 0.5)
	if size * 3 <= settings.wavelength then
		-- (Ragged edges where the cells are small enough to show them.)
		local fine = settings.wavelength / 3
		n += 0.35 * noise((u / fine + pattern.fx) % 256, (w / fine + pattern.fz) % 256, 0.5)
		n /= 1.06
	end
	return 1 / (1 + exp(-1.702 * n / CloudLod.SPREAD))
end

-- The share of the sky clouded at cover `cover` (0..1).
function CloudLod.fraction(settings: Settings, cover: number): number
	return settings.coverBase + (1 - settings.coverBase) * math.clamp(cover, 0, 1)
end

-- Is the cell at air-frame (u, w) (its centre) cloudy at cover `cover`?
function CloudLod.cloudy(
	pattern: Pattern,
	settings: Settings,
	u: number,
	w: number,
	size: number,
	cover: number
): boolean
	if cover <= 0 and settings.coverBase <= 0 then
		return false
	end
	return CloudLod.patternAt(pattern, settings, u, w, size) < CloudLod.fraction(settings, cover)
end

-- Precipitation and thunder in the steps a cloud's look takes (RAIN_STEPS, THUNDER_STEPS), so
-- neighbouring cells of one storm share looks and merge.
function CloudLod.buckets(p: number, t: number): (number, number)
	return floor(math.clamp(p, 0, 1) * CloudLod.RAIN_STEPS + 0.5) / CloudLod.RAIN_STEPS,
		floor(math.clamp(t, 0, 1) * CloudLod.THUNDER_STEPS + 0.5) / CloudLod.THUNDER_STEPS
end

-- The shade step (1 white .. SHADES darkest) of a cloud with precipitation p and thunder t.
function CloudLod.shadeOf(p: number, t: number): number
	local rain, thunder = CloudLod.buckets(p, t)
	local grey = Weather.cloudColour({ 1, 1, 1 }, rain, thunder)
	local luminance = grey[1] * 0.3 + grey[2] * 0.59 + grey[3] * 0.11
	local darkness = (1 - luminance) / (1 - CloudLod.DARKEST)
	return math.clamp(floor(darkness * (CloudLod.SHADES - 1) + 0.5) + 1, 1, CloudLod.SHADES)
end

-- A cloud's base and top (blocks, on `step`s) with precipitation p and thunder t.
function CloudLod.heights(settings: Settings, p: number, t: number): (number, number)
	local rain, thunder = CloudLod.buckets(p, t)
	local step = settings.step
	local base = floor((settings.altitude - settings.drop * rain) / step + 0.5) * step
	local thickness = settings.thickness + settings.rainThickness * rain + settings.tower * thunder
	return base, base + math.max(1, floor(thickness / step + 0.5)) * step
end

-- The grey of shade `shade` (0..1: white to DARKEST).
function CloudLod.grey(shade: number): number
	return 1 - (shade - 1) / (CloudLod.SHADES - 1) * (1 - CloudLod.DARKEST)
end

local function keyOf(box: Box): string
	return string.format(
		"%d:%d:%d:%d:%d:%d:%d:%d",
		box.x0,
		box.z0,
		box.x1,
		box.z1,
		box.base,
		box.top,
		box.shade,
		if box.shaft then 1 else 0
	)
end

--[[
	Greedy rectangles of equal non-zero codes in a `cols` x `rows` grid (row by row, codes[row *
	cols + col + 1]), at most `maxSpan` cells a side. Calls `emit(col, row, width, height, code)`
	for each.
]]
function CloudLod.merge(
	codes: { number },
	cols: number,
	rows: number,
	emit: (col: number, row: number, width: number, height: number, code: number) -> (),
	maxSpan: number?
)
	local most = maxSpan or math.huge
	local used = table.create(cols * rows, false)
	for row = 0, rows - 1 do
		local base = row * cols
		local col = 0
		while col < cols do
			local code = codes[base + col + 1]
			if code == 0 or used[base + col + 1] then
				col += 1
				continue
			end
			local width = 1
			while
				width < most
				and col + width < cols
				and codes[base + col + width + 1] == code
				and not used[base + col + width + 1]
			do
				width += 1
			end
			local height = 1
			while height < most and row + height < rows do
				local below = (row + height) * cols
				local same = true
				for i = col, col + width - 1 do
					if codes[below + i + 1] ~= code or used[below + i + 1] then
						same = false
						break
					end
				end
				if not same then
					break
				end
				height += 1
			end
			for r = row, row + height - 1 do
				for i = col, col + width - 1 do
					used[r * cols + i + 1] = true
				end
			end
			emit(col, row, width, height, code)
			col += width
		end
	end
end

-- Codes: shade (4 bits), base step (10 bits), top step (10 bits).
local SHADE_BITS = 16
local HEIGHT_BITS = 1024

--[[
	Level `level`'s boxes for the camera at air-frame (cu, cw): clouds, then rain shafts, nearest
	first. `sample` gives the weather at the window's cell centres (see Sampler).
]]
function CloudLod.plan(
	settings: Settings,
	pattern: Pattern,
	level: number,
	cu: number,
	cw: number,
	sample: Sampler
): { Box }
	local window = CloudLod.window(settings, level, cu, cw)
	local size, cols = window.size, window.cols
	local u0, w0 = window.u0, window.w0
	local grid = sample(u0 + size / 2, w0 + size / 2, size, cols, cols)
	local hole = window.hole
	local reach = settings.viewDistance + size * 0.71
	local reach2 = reach * reach
	local step = settings.step
	local shafts = settings.shafts and level >= settings.shaftLevel
	local maxSpan = math.max(1, floor(settings.maxPart / size))
	local cloudCodes = table.create(cols * cols, 0)
	local shaftCodes = table.create(cols * cols, 0)
	local anyShaft = false
	for row = 0, cols - 1 do
		local w = w0 + (row + 0.5) * size
		local dw = w - cw
		for col = 0, cols - 1 do
			local u = u0 + (col + 0.5) * size
			local du = u - cu
			if du * du + dw * dw > reach2 then
				continue
			end
			if hole and u > hole.u0 and u < hole.u1 and w > hole.w0 and w < hole.w1 then
				continue
			end
			local index = (row * cols + col) * 3
			local cover = buffer.readu8(grid, index + 2) / 255
			if not CloudLod.cloudy(pattern, settings, u, w, size, cover) then
				continue
			end
			local p = buffer.readu8(grid, index) / 255
			local t = buffer.readu8(grid, index + 1) / 255
			local base, top = CloudLod.heights(settings, p, t)
			local shade = CloudLod.shadeOf(p, t)
			local baseStep = (base // step) % HEIGHT_BITS
			cloudCodes[row * cols + col + 1] = shade
				+ SHADE_BITS * (baseStep + HEIGHT_BITS * ((top // step) % HEIGHT_BITS))
			if shafts and p >= settings.shaftMin then
				local heavy = if p >= (1 + settings.shaftMin) / 2 then 2 else 1
				shaftCodes[row * cols + col + 1] = heavy
				anyShaft = true
			end
		end
	end
	local boxes: { Box } = {}
	CloudLod.merge(cloudCodes, cols, cols, function(col, row, width, height, code)
		local shade = code % SHADE_BITS
		local rest = code // SHADE_BITS
		local box: Box = {
			x0 = u0 + col * size,
			z0 = w0 + row * size,
			x1 = u0 + (col + width) * size,
			z1 = w0 + (row + height) * size,
			base = (rest % HEIGHT_BITS) * step,
			top = (rest // HEIGHT_BITS) * step,
			shade = shade,
			shaft = false,
			key = "",
		}
		box.key = keyOf(box)
		table.insert(boxes, box)
	end, maxSpan)
	if anyShaft then
		-- (Every shaft reaches up to the lowest rain cloud's base: they merge across a storm.)
		local shaftTop = CloudLod.heights(settings, 1, 0)
		CloudLod.merge(shaftCodes, cols, cols, function(col, row, width, height, code)
			local box: Box = {
				x0 = u0 + col * size,
				z0 = w0 + row * size,
				x1 = u0 + (col + width) * size,
				z1 = w0 + (row + height) * size,
				base = 0,
				top = shaftTop,
				shade = code % SHADE_BITS,
				shaft = true,
				key = "",
			}
			box.key = keyOf(box)
			table.insert(boxes, box)
		end, maxSpan)
	end
	table.sort(boxes, function(a: Box, b: Box): boolean
		local ax, az = (a.x0 + a.x1) / 2 - cu, (a.z0 + a.z1) / 2 - cw
		local bx, bz = (b.x0 + b.x1) / 2 - cu, (b.z0 + b.z1) / 2 - cw
		return ax * ax + az * az < bx * bx + bz * bz
	end)
	return boxes
end

--[[
	What changes from `live` (key -> anything) to `boxes`: the boxes to add (in `boxes`' order)
	and the keys to remove.
]]
function CloudLod.diff(live: { [string]: any }, boxes: { Box }): ({ Box }, { string })
	local wanted: { [string]: boolean } = {}
	local added: { Box } = {}
	for _, box in boxes do
		wanted[box.key] = true
		if live[box.key] == nil then
			table.insert(added, box)
		end
	end
	local removed: { string } = {}
	for key in live do
		if not wanted[key] then
			table.insert(removed, key)
		end
	end
	table.sort(removed)
	return added, removed
end

return CloudLod
