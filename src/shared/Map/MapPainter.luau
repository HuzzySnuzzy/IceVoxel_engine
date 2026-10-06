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
]]

local Config = require(script.Parent.Parent.Config)
local Blocks = require(script.Parent.Parent.Blocks)
local Biomes = require(script.Parent.Parent.Biomes)
local TerrainGenerator = require(script.Parent.Parent.Generation.TerrainGenerator)
local Lakes = require(script.Parent.Parent.Generation.Lakes)

local SEA = Config.SeaLevel
local ICE = Blocks.get(Blocks.id.Ice).color
local OIL = Blocks.get(Blocks.id.Oil).color

-- Coarsest zoom (blocks per pixel) that paints water lakes / puddles.
local LAKE_SCALE, PUDDLE_SCALE = 8, 2

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
-- `scale` blocks away.
local function shade(
	height: number,
	west: number,
	north: number,
	scale: number,
	biome: number,
	vegetation: number,
	surface: number
): number
	if height < SEA then
		if Biomes.list[biome].frozen then
			return pack(ICE[1], ICE[2], ICE[3])
		end
		local t = math.min(1, (SEA - height) / 40)
		return pack(64 - 46 * t, 138 - 90 * t, 214 - 94 * t)
	end
	local c = Blocks.get(surface).color
	-- Light from the north-west: slopes facing it are brighter.
	local light = 1 + ((height - west) + (height - north)) / scale * LIGHT
	light = if light < 0.6 then 0.6 elseif light > 1.35 then 1.35 else light
	local altitude = 0.92 + ALTITUDE_GAIN * math.min(1, (height - SEA) / ALTITUDE_TOP)
	local forest = 1 - math.min(0.35, vegetation * 0.7)
	local k = light * altitude * forest
	return pack(c[1] * k, c[2] * k, c[3] * k)
end

-- Paints the geysers of the wells near the tile (see the header).
local function paintWells(
	generator: TerrainGenerator.Generator,
	pixels: buffer,
	originX: number,
	originZ: number,
	scale: number,
	size: number
)
	local span = size * scale
	local oil = pack(OIL[1], OIL[2], OIL[3])
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

function MapPainter.new(generator: TerrainGenerator.Generator): Painter
	local column = generator.column
	local heights: { number } = {}

	return function(originX: number, originZ: number, scale: number, size: number, yield: (() -> ())?): buffer
		local pixels = buffer.create(size * size * 4)
		local half = scale // 2
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
				writeu32(pixels, (py * size + px) * 4, shade(h, west, north, scale, biome, vegetation, surface))
			end
			if yield then
				yield()
			end
		end
		paintLakes(generator, pixels, originX, originZ, scale, size)
		paintWells(generator, pixels, originX, originZ, scale, size)
		return pixels
	end
end

return MapPainter
