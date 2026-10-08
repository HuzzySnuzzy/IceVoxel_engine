--!strict
--!native
--[[
	The maps' weather mode, pure (Map/WeatherLayer draws it over the minimap and the world map;
	tests/spec/WeatherVisuals checks it). The weather is a deterministic field (Shared/Weather), so
	a forecast is the same field sampled at a later time: `Weather.momentAt(state, now + seconds)`
	with the override as it will be then.

	  Steps     the forecast: now, +2, +5, +10 and +20 minutes (STEPS, real time; the weather
	            clock runs at Config.Weather.Speed and stands still with doWeatherCycle off).
	  Grid      the weather is sampled on a coarse grid of square cells (`cellFor`: a power of two
	            of blocks, at least MIN_CELL, so the view and a margin fit `maxCells` cells
	            across), its corner on multiples of the margin (`grid`), so the map pans that far
	            before it is sampled again, drawn as a small image stretched over the map
	            (smoothed). `paint` can paint a band of rows of a picture at a time (Map/
	            WeatherLayer spreads a picture over frames: `bandRows` sizes a band to a frame's
	            time by what the last band cost, so a slow device paints thinner bands).
	  Colours   `colour`: clouds a light grey veil (CLOUD) by the cover; where it rains RAIN blue,
	            where it snows SNOW white (by the cell's biome and ground height, Weather.formAt),
	            stronger with the precipitation, nothing over dry biomes but the clouds;
	            thunderstorms THUNDER purple, with LIGHTNING yellow speckles (a fixed hash per
	            cell) where the thunder is over half. Alpha: 0 in clear weather, so the terrain
	            shows.
	  Cache     each forecast step's picture is kept with its grid and the time it was drawn
	            (`newCache`, `fresh`, `put`): switching steps back and forth costs nothing, and a
	            picture is drawn again only when the view moved off its grid or it is older than
	            Config.Weather.Map.RefreshSeconds.
	  Wind      `wind`: the wind's speed (blocks a second) and the angle the map's arrow is turned
	            by (0: blowing north, the top of the map; clockwise), `windText` its compass name.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Hash = require(Shared.Util.Hash)
local Weather = require(Shared.Weather)

export type Entry = {
	key: string,
	time: number,
	pixels: buffer,
	x0: number,
	z0: number,
	cell: number,
	cols: number,
	rows: number,
}

export type Cache = { entries: { [number]: Entry } }

local WeatherMap = {}

-- Forecast steps (seconds from now) and their labels.
WeatherMap.STEPS = table.freeze({ 0, 120, 300, 600, 1200 })
WeatherMap.LABELS = table.freeze({ "Now", "+2 min", "+5 min", "+10 min", "+20 min" })
WeatherMap.MIN_CELL = 4

-- RGB colours (0..255).
WeatherMap.CLOUD = table.freeze({ 214, 220, 230 })
WeatherMap.RAIN = table.freeze({ 48, 112, 255 })
WeatherMap.SNOW = table.freeze({ 246, 250, 255 })
WeatherMap.THUNDER = table.freeze({ 168, 64, 232 })
WeatherMap.LIGHTNING = table.freeze({ 255, 222, 64 })

-- The legend: name and colour.
WeatherMap.LEGEND = table.freeze({
	{ name = "Clouds", colour = WeatherMap.CLOUD },
	{ name = "Rain", colour = WeatherMap.RAIN },
	{ name = "Snow", colour = WeatherMap.SNOW },
	{ name = "Thunder", colour = WeatherMap.THUNDER },
}) :: { { name: string, colour: { number } } }

-- The smallest power-of-two cell (blocks, >= MIN_CELL) with `view` blocks and `margin` cells on
-- each side (default 1) at most `maxCells` cells across.
function WeatherMap.cellFor(view: number, maxCells: number, margin: number?): number
	local extra = 2 * (margin or 1)
	local cell = WeatherMap.MIN_CELL
	while math.ceil(view / cell) + extra > maxCells do
		cell *= 2
	end
	return cell
end

--[[
	The grid covering a `view`-block square centred on (x, z) with `margin` cells to spare on each
	side (default 1), its corner on multiples of `margin` cells (so panning less than that keeps
	the same grid, and its picture): the first cell's corner and how many cells across.
]]
function WeatherMap.grid(x: number, z: number, view: number, cell: number, margin: number?): (number, number, number)
	local spare = margin or 1
	local align = cell * spare
	local x0 = math.floor((x - view / 2) / align) * align
	local z0 = math.floor((z - view / 2) / align) * align
	local count = math.ceil(view / cell) + 2 * spare
	return x0, z0, count
end

-- How strongly something at `value` (0..1) shows, starting at `from`.
local function strength(value: number, from: number): number
	return math.clamp((value - from) / (1 - from), 0, 1)
end

local function mix(r: number, g: number, b: number, to: { number }, t: number): (number, number, number)
	return r + (to[1] - r) * t, g + (to[2] - g) * t, b + (to[3] - b) * t
end

--[[
	The colour (r, g, b, a: 0..255) of a cell with precipitation p, thunder t and cover c (0..1)
	where `form` falls (Weather.formAt: "rain", "snow" or "" for nothing); `speckle` (0..1, a
	fixed random of the cell) places the lightning.
]]
function WeatherMap.colour(
	p: number,
	t: number,
	c: number,
	form: string,
	speckle: number
): (number, number, number, number)
	local cloud = strength(c, 0.05)
	local r, g, b = WeatherMap.CLOUD[1], WeatherMap.CLOUD[2], WeatherMap.CLOUD[3]
	local alpha = 0.32 * cloud
	local falling = if form == Weather.NONE then 0 else strength(p, 0.04)
	if falling > 0 then
		local colour = if form == Weather.SNOW then WeatherMap.SNOW else WeatherMap.RAIN
		r, g, b = mix(r, g, b, colour, math.min(1, 0.35 + falling))
		alpha = math.max(alpha, 0.3 + 0.5 * falling)
	end
	local storm = strength(t, 0.05)
	if storm > 0 then
		r, g, b = mix(r, g, b, WeatherMap.THUNDER, 0.4 + 0.5 * storm)
		alpha = math.max(alpha, 0.45 + 0.4 * storm)
		if t > 0.5 and speckle < (t - 0.5) * 0.6 then
			r, g, b = WeatherMap.LIGHTNING[1], WeatherMap.LIGHTNING[2], WeatherMap.LIGHTNING[3]
			alpha = 0.95
		end
	end
	return math.floor(r + 0.5),
		math.floor(g + 0.5),
		math.floor(b + 0.5),
		math.floor(math.clamp(alpha, 0, 1) * 255 + 0.5)
end

-- The fixed speckle (0..1) of the cell at (x, z) (blocks, its corner) of size `cell`.
function WeatherMap.speckle(x: number, z: number, cell: number): number
	return Hash.float3(cell, x // cell, 7, z // cell)
end

--[[
	Paints `samples` (Shared/Weather's grid: 3 bytes a cell) of a `cols` x `rows` grid from
	(x0, z0), `cell` blocks a cell, into `into` (RGBA, 4 bytes a pixel, a pixel a cell, row by
	row, from pixel `at` on (default 0): a band of a bigger picture; reused when big enough).
	`formAt(x, z)` gives what falls at a cell's centre.
]]
function WeatherMap.paint(
	samples: buffer,
	x0: number,
	z0: number,
	cell: number,
	cols: number,
	rows: number,
	formAt: (x: number, z: number) -> string,
	into: buffer?,
	at: number?
): buffer
	local first = at or 0
	local size = (first + cols * rows) * 4
	local out = if into and buffer.len(into) >= size then into else buffer.create(size)
	for row = 0, rows - 1 do
		local z = z0 + row * cell
		for col = 0, cols - 1 do
			local x = x0 + col * cell
			local i = row * cols + col
			local p = buffer.readu8(samples, i * 3) / 255
			local t = buffer.readu8(samples, i * 3 + 1) / 255
			local c = buffer.readu8(samples, i * 3 + 2) / 255
			local form = if p > 0.04 then formAt(x + cell / 2, z + cell / 2) else Weather.NONE
			local r, g, b, a = WeatherMap.colour(p, t, c, form, WeatherMap.speckle(x, z, cell))
			local o = (first + i) * 4
			buffer.writeu8(out, o, r)
			buffer.writeu8(out, o + 1, g)
			buffer.writeu8(out, o + 2, b)
			buffer.writeu8(out, o + 3, a)
		end
	end
	return out
end

--[[
	Rows of `count` cells to paint in a frame: as many as `budget` seconds hold at `perCell`
	seconds a cell (what the last band cost; 0: unknown), at most `maxCells` cells (Map
	.CellsPerFrame) and the `left` rows, at least one.
]]
function WeatherMap.bandRows(count: number, left: number, maxCells: number, budget: number, perCell: number): number
	local rows = math.floor(maxCells / count)
	if perCell > 0 then
		rows = math.min(rows, math.floor(budget / (perCell * count)))
	end
	return math.clamp(rows, 1, math.max(1, left))
end

--[[ Cache ]]

function WeatherMap.newCache(): Cache
	return { entries = {} }
end

-- The grid's key (so a picture is reused only for the same cells).
function WeatherMap.key(x0: number, z0: number, cell: number, cols: number, rows: number): string
	return `{x0}:{z0}:{cell}:{cols}:{rows}`
end

-- Step `step`'s picture when it is for grid `key` and at most `maxAge` seconds old at `now`.
function WeatherMap.fresh(cache: Cache, step: number, key: string, now: number, maxAge: number): Entry?
	local entry = cache.entries[step]
	if entry and entry.key == key and now - entry.time <= maxAge and now >= entry.time then
		return entry
	end
	return nil
end

-- Keeps step `step`'s picture (one per step: the newest).
function WeatherMap.put(cache: Cache, step: number, entry: Entry)
	cache.entries[step] = entry
end

-- Drops every picture (the weather's state changed: an override, doWeatherCycle).
function WeatherMap.clear(cache: Cache)
	table.clear(cache.entries)
end

--[[ Wind ]]

--[[
	The wind (vx, vz in blocks a second) as the map shows it: its speed and the arrow's turn in
	degrees (0: towards the top of the map, -z; clockwise: +x is 90).
]]
function WeatherMap.wind(vx: number, vz: number): (number, number)
	local speed = math.sqrt(vx * vx + vz * vz)
	local angle = math.deg(math.atan2(vx, -vz)) % 360
	return speed, angle
end

local COMPASS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }

-- "1.3 b/s NE": the wind's speed and where it blows to (north is -z, the top of the map).
function WeatherMap.windText(vx: number, vz: number): string
	local speed, angle = WeatherMap.wind(vx, vz)
	local index = math.floor(angle / 45 + 0.5) % 8 + 1
	return string.format("%.1f b/s %s", speed, COMPASS[index])
end

return WeatherMap
