--[[
	Renders a top-down map of the terrain to tests/out/preview.ppm using the same painter as the
	in-game map (Map/MapPainter). Handy when tuning biomes or terrain noise.

	    lune run tests/preview [seed] [blocksPerPixel] [pixels]
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local Loader = require("./lib/Loader")

local shared, require = Loader.mount("src/shared", "IceVoxel")
local TerrainGenerator = require(shared.Generation.TerrainGenerator)
local MapPainter = require(shared.Map.MapPainter)

local seed = tonumber(process.args[1]) or 12345
local scale = tonumber(process.args[2]) or 8
local pixels = tonumber(process.args[3]) or 512

local gen = TerrainGenerator.new(seed)
local sx, _, sz = gen.findSpawn()
local paint = MapPainter.new(gen)
local rgba = paint(sx - (pixels // 2) * scale, sz - (pixels // 2) * scale, scale, pixels)

local header = `P6\n{pixels} {pixels}\n255\n`
local image = buffer.create(#header + pixels * pixels * 3)
buffer.writestring(image, 0, header)
for i = 0, pixels * pixels - 1 do
	local px, py = i % pixels, i // pixels
	local o = #header + i * 3
	if math.abs(px - pixels // 2) <= 2 and math.abs(py - pixels // 2) <= 2 then
		-- Spawn marker.
		buffer.writeu8(image, o, 255)
		buffer.writeu8(image, o + 1, 0)
		buffer.writeu8(image, o + 2, 0)
	else
		buffer.writeu8(image, o, buffer.readu8(rgba, i * 4))
		buffer.writeu8(image, o + 1, buffer.readu8(rgba, i * 4 + 1))
		buffer.writeu8(image, o + 2, buffer.readu8(rgba, i * 4 + 2))
	end
end

if not fs.isDir("tests/out") then
	fs.writeDir("tests/out")
end
fs.writeFile("tests/out/preview.ppm", image)
print(`Wrote tests/out/preview.ppm ({pixels}x{pixels}, {scale} blocks per pixel, seed {seed})`)
