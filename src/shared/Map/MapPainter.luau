--!strict
--!native
--[[
	Paints top-down map tiles straight from the terrain generator, so the map can show any part of
	the (infinite) world without anything being loaded. Runs inside the worker actors.

	A tile is `size` x `size` pixels, each pixel covering `scale` x `scale` blocks (sampled at its
	center). North (-Z) is up and east (+X) is right. Output is RGBA8, row by row, which is the
	format EditableImage:WritePixelsBuffer expects.

	Colouring: the surface block's colour, darkened where trees are dense, lit from the north-west
	using the slope towards the neighbouring pixel (hill shading) and a little brighter higher up;
	water is tinted by depth and frozen seas are drawn as ice. Oil wells' geysers are painted over
	it as black dots in the oil's colour: the pixel holding the spout, and every pixel whose centre
	lies within the lake's radius (Generation/OilWells; the wells are decided from the seed and the
	terrain alone, a few per tile at most). Water lakes (Generation/Lakes) are painted as shallow
	water (ice where frozen) at up to LAKE_SCALE blocks a pixel, and puddles at up to PUDDLE_SCALE:
	a pixel whose centre column holds the water. (Farther out they would be a pixel or less, and
	finding them for a whole tile would cost more than they show.)

	The sea is the generator's (`seaLevel`: a superflat world's water layers, none in a void), and
	a column with nothing in it (`column`'s surface is air: the void, a debug world's gaps) is
	painted VOID, a dark grey.

	The zombie apocalypse's ruins (Generation/Cities): a tile first warms the generator's caches
	for its rectangle (`prepare`, with the painter's yield), so the wrapped terrain `column` reads
	never builds a city or road plan at once. At up to CITY_SCALE (8) blocks a pixel the columns
	themselves show the streets and roads (their asphalt, concrete and grass); from it on each city
	is painted as a CITY grey square (its footprint), with its street grid darker at exactly
	CITY_SCALE (a street every four pixels; coarser, a grid would be noise), and the roads between
	them as one pixel lines in ROAD grey (`paintRoads`: every segment, walked half a pixel at a
	time), over everything else.
]]

local Config = require(script.Parent.Parent.Config)
local Blocks = require(script.Parent.Parent.Blocks)
local Biomes = require(script.Parent.Parent.Biomes)
local TerrainGenerator = require(script.Parent.Parent.Generation.TerrainGenerator)
local Lakes = require(script.Parent.Parent.Generation.Lakes)

local SEA = Config.SeaLevel
local ICE = Blocks.get(Blocks.id.Ice).color
local OIL = Blocks.get(Blocks.id.Oil).color
local AIR = Blocks.AIR
local VOID = { 18, 18, 22 }

-- Coarsest zoom (blocks per pixel) that paints water lakes / puddles.
local LAKE_SCALE, PUDDLE_SCALE = 8, 2
-- Pixels painted between two yields at most (and after every row).
local ROW_PART = 32
-- From this zoom (blocks per pixel) on, cities are squares and roads lines (see the header).
local CITY_SCALE = 8
local CITY, STREETS, ROAD = { 120, 120, 118 }, { 92, 92, 90 }, { 62, 62, 66 }

local writeu32 = buffer.writeu32
local floor = math.floor

export type Painter = (originX: number, originZ: number, scale: number, size: number, yield: (() -> ())?) -> buffer

local MapPainter = {}

local function pack(r: number, g: number, b: number): number
	r = if r < 0 then 0 elseif r > 255 then 255 else floor(r)
	g = if g < 0 then 0 elseif g > 255 then 255 else floor(g)
	b = if b < 0 then 0 elseif b > 255 then 255 else floor(b)
	-- Little endian: bytes R, G, B, A.
	return r + g * 256 + b * 65536 + 255 * 16777216
end

-- Hill shading per unit of slope (blocks per block) facing the light, and the brightening from sea
-- level to ALTITUDE_TOP.
local LIGHT = 0.3
local ALTITUDE_GAIN, ALTITUDE_TOP = 0.25, 700

-- Colour (packed RGBA) of one map pixel; `west` / `north` are the neighbouring pixels' heights,
-- `scale` blocks away; `sea` the world's sea level.
local function shade(
	height: number,
	west: number,
	north: number,
	scale: number,
	biome: number,
	vegetation: number,
	surface: number,
	sea: number
): number
	-- (The sea first: a superflat world of water only has no ground, height 0, under its sea.)
	if height < sea then
		if Biomes.list[biome].frozen then
			return pack(ICE[1], ICE[2], ICE[3])
		end
		local t = math.min(1, (sea - height) / 40)
		return pack(64 - 46 * t, 138 - 90 * t, 214 - 94 * t)
	elseif surface == AIR and height <= 0 then
		return pack(VOID[1], VOID[2], VOID[3])
	end
	local c = Blocks.get(surface).color
	-- Light from the north-west: slopes facing it are brighter.
	local light = 1 + ((height - west) + (height - north)) / scale * LIGHT
	light = if light < 0.6 then 0.6 elseif light > 1.35 then 1.35 else light
	local altitude = 0.92 + ALTITUDE_GAIN * math.min(1, (height - sea) / ALTITUDE_TOP)
	local forest = 1 - math.min(0.35, vegetation * 0.7)
	local k = light * altitude * forest
	return pack(c[1] * k, c[2] * k, c[3] * k)
end

-- Paints the geysers of the wells near the tile (see the header). With `yield`, the wells are
-- decided half a Spacing square at a time first, a yield after each (a coarse tile spans dozens
-- of cells, and each square decides the few cells around it it has not seen yet).
local function paintWells(
	generator: TerrainGenerator.Generator,
	pixels: buffer,
	originX: number,
	originZ: number,
	scale: number,
	size: number,
	yield: (() -> ())?
)
	local span = size * scale
	local oil = pack(OIL[1], OIL[2], OIL[3])
	if yield then
		local spacing = Config.Caves.OilWells.Spacing // 2
		for z = originZ, originZ + span - 1, spacing do
			for x = originX, originX + span - 1, spacing do
				generator.oilWells(
					x,
					z,
					math.min(x + spacing, originX + span) - 1,
					math.min(z + spacing, originZ + span) - 1
				)
				yield()
			end
		end
	end
	for _, well in generator.oilWells(originX, originZ, originX + span - 1, originZ + span - 1) do
		if not well.geyser then
			continue
		end
		-- The well's position in pixels (a block's centre), and the lake's radius.
		local cx, cz = (well.x + 0.5 - originX) / scale, (well.z + 0.5 - originZ) / scale
		local r = well.lakeRadius / scale
		local spoutX, spoutZ = floor(cx), floor(cz)
		for py = math.max(floor(cz - r), 0), math.min(floor(cz + r), size - 1) do
			for px = math.max(floor(cx - r), 0), math.min(floor(cx + r), size - 1) do
				local dx, dz = px + 0.5 - cx, py + 0.5 - cz
				if (px == spoutX and py == spoutZ) or dx * dx + dz * dz <= r * r then
					writeu32(pixels, (py * size + px) * 4, oil)
				end
			end
		end
	end
end

-- Paints the water lakes and puddles near the tile (see the header).
local function paintLakes(
	generator: TerrainGenerator.Generator,
	pixels: buffer,
	originX: number,
	originZ: number,
	scale: number,
	size: number
)
	if scale > LAKE_SCALE then
		return
	end
	local span = size * scale
	local half = scale // 2
	-- A lake's water, about 3 blocks deep, in the sea's colours.
	local t = 3 / 40
	local wet = pack(64 - 46 * t, 138 - 90 * t, 214 - 94 * t)
	local ice = pack(ICE[1], ICE[2], ICE[3])
	local shallow = pack(64, 138, 214)
	local x1, z1 = originX + span - 1, originZ + span - 1
	for _, lake in generator.waterLakes(originX, originZ, x1, z1) do
		local colour = if lake.frozen then ice else wet
		for py = math.max((lake.z - originZ) // scale, 0), math.min((lake.z + Lakes.BOX - 1 - originZ) // scale, size - 1) do
			for px = math.max((lake.x - originX) // scale, 0), math.min((lake.x + Lakes.BOX - 1 - originX) // scale, size - 1) do
				if Lakes.wet(lake, originX + px * scale + half, originZ + py * scale + half) then
					writeu32(pixels, (py * size + px) * 4, colour)
				end
			end
		end
	end
	if scale > PUDDLE_SCALE then
		return
	end
	for _, puddle in generator.puddles(originX, originZ, x1, z1) do
		for py = math.max((puddle.z0 - originZ) // scale, 0), math.min((puddle.z1 - originZ) // scale, size - 1) do
			for px = math.max((puddle.x0 - originX) // scale, 0), math.min((puddle.x1 - originX) // scale, size - 1) do
				if Lakes.inPuddle(puddle, originX + px * scale + half, originZ + py * scale + half) then
					writeu32(pixels, (py * size + px) * 4, shallow)
				end
			end
		end
	end
end

-- Paints the cities near the tile as squares (see the header).
local function paintCities(
	generator: TerrainGenerator.Generator,
	pixels: buffer,
	originX: number,
	originZ: number,
	scale: number,
	size: number,
	yield: (() -> ())?
)
	local cities = generator.cities
	if cities == nil or scale < CITY_SCALE then
		return
	end
	local span = size * scale
	local half = scale // 2
	local block = Config.Cities.Block
	local street = Config.Cities.Street
	local grey = pack(CITY[1], CITY[2], CITY[3])
	local streets = pack(STREETS[1], STREETS[2], STREETS[3])
	for _, site in cities(originX, originZ, originX + span - 1, originZ + span - 1, yield) do
		local x0, z0 = site.x - site.radius, site.z - site.radius
		local x1, z1 = site.x + site.radius, site.z + site.radius
		for py = math.max(0, (z0 - originZ) // scale), math.min(size - 1, (z1 - originZ) // scale) do
			local z = originZ + py * scale + half
			if z < z0 or z > z1 then
				continue
			end
			for px = math.max(0, (x0 - originX) // scale), math.min(size - 1, (x1 - originX) // scale) do
				local x = originX + px * scale + half
				if x >= x0 and x <= x1 then
					-- (A pixel holding a street's centre line, 3 blocks into it: one in four at 8.)
					local u0, v0 = originX + px * scale - x0, originZ + py * scale - z0
					local onStreet = (street // 2 - u0) % block < scale or (street // 2 - v0) % block < scale
					writeu32(pixels, (py * size + px) * 4, if scale == CITY_SCALE and onStreet then streets else grey)
				end
			end
		end
	end
end

-- Paints the roads near the tile as one pixel lines, at CITY_SCALE blocks a pixel and coarser.
function MapPainter.paintRoads(
	generator: TerrainGenerator.Generator,
	pixels: buffer,
	originX: number,
	originZ: number,
	scale: number,
	size: number,
	yield: (() -> ())?
)
	local roads = generator.roads
	if roads == nil or scale < CITY_SCALE then
		return
	end
	local span = size * scale
	local colour = pack(ROAD[1], ROAD[2], ROAD[3])
	for _, segment in roads(originX, originZ, originX + span - 1, originZ + span - 1, yield) do
		local ax, az = (segment.x0 - originX) / scale, (segment.z0 - originZ) / scale
		local bx, bz = (segment.x1 - originX) / scale, (segment.z1 - originZ) / scale
		local steps = math.max(1, math.ceil(math.max(math.abs(bx - ax), math.abs(bz - az)) * 2))
		for i = 0, steps do
			local t = i / steps
			local px, py = floor(ax + (bx - ax) * t), floor(az + (bz - az) * t)
			if px >= 0 and px < size and py >= 0 and py < size then
				writeu32(pixels, (py * size + px) * 4, colour)
			end
		end
	end
end

function MapPainter.new(generator: TerrainGenerator.Generator): Painter
	local column = generator.column
	local sea = generator.seaLevel or SEA
	local heights: { number } = {}

	return function(originX: number, originZ: number, scale: number, size: number, yield: (() -> ())?): buffer
		local pixels = buffer.create(size * size * 4)
		local half = scale // 2
		-- The ruins' caches for every column read below (see the header).
		local prepare = generator.prepare
		if prepare then
			prepare(originX - scale, originZ - scale, originX + size * scale, originZ + size * scale, yield)
		end
		-- Heights on a (size + 1)^2 grid: one extra row to the north and column to the west, used
		-- for shading. Grid cell (i, j) is at heights[j * stride + i + 1]; pixel (px, py) is (px + 1, py + 1).
		local stride = size + 1

		for i = 0, size do
			heights[i + 1] = column(originX + (i - 1) * scale + half, originZ - scale + half)
		end
		for py = 0, size - 1 do
			local z = originZ + py * scale + half
			local row = (py + 1) * stride
			heights[row + 1] = column(originX - scale + half, z)
			for px = 0, size - 1 do
				local h, biome, vegetation, surface = column(originX + px * scale + half, z)
				local i = px + 1
				heights[row + i + 1] = h
				local west = heights[row + i]
				local north = heights[row - stride + i + 1]
				writeu32(pixels, (py * size + px) * 4, shade(h, west, north, scale, biome, vegetation, surface, sea))
				-- (Every ROW_PART pixels too: a coarse tile's columns lie far apart, each its own.)
				if yield and px % ROW_PART == ROW_PART - 1 and px < size - 1 then
					yield()
				end
			end
			if yield then
				yield()
			end
		end
		paintLakes(generator, pixels, originX, originZ, scale, size)
		paintWells(generator, pixels, originX, originZ, scale, size, yield)
		paintCities(generator, pixels, originX, originZ, scale, size, yield)
		MapPainter.paintRoads(generator, pixels, originX, originZ, scale, size, yield)
		return pixels
	end
end

return MapPainter
