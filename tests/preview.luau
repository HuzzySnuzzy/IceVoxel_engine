--[[
	Renders a top-down map of the terrain to tests/out/preview.ppm (surface colour, shaded by height,
	water tinted by depth). Handy when tuning biomes or terrain noise.

	    lune run tests/preview [seed] [blocksPerPixel] [pixels]
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local Loader = require("./lib/Loader")

local shared, require = Loader.mount("src/shared", "IceVoxel")
local Config = require(shared.Config)
local Blocks = require(shared.Blocks)
local TerrainGenerator = require(shared.Generation.TerrainGenerator)

local seed = tonumber(process.args[1]) or 12345
local scale = tonumber(process.args[2]) or 8
local pixels = tonumber(process.args[3]) or 512

local gen = TerrainGenerator.new(seed)
local sx, _, sz = gen.findSpawn()

local header = `P6\n{pixels} {pixels}\n255\n`
local image = buffer.create(#header + pixels * pixels * 3)
buffer.writestring(image, 0, header)

local offset = #header
for py = 0, pixels - 1 do
	for px = 0, pixels - 1 do
		local x = sx + (px - pixels // 2) * scale
		local z = sz + (py - pixels // 2) * scale
		local h, _, vegetation, surface = gen.column(x, z)
		local c = Blocks.get(surface).color
		local r, g, b = c[1], c[2], c[3]
		if h < Config.SeaLevel then
			local depth = math.min(1, (Config.SeaLevel - h) / 40)
			r, g, b = 40 * (1 - depth) + 10 * depth, 110 * (1 - depth) + 40 * depth, 200 * (1 - depth) + 120 * depth
		else
			-- Height shading plus a darker tint where trees are dense.
			local shade = 0.7 + (h - Config.SeaLevel) / 200
			local forest = 1 - math.min(0.35, vegetation * 0.7)
			r, g, b = r * shade * forest, g * shade * forest, b * shade * forest
		end
		-- Mark the spawn point.
		if math.abs(px - pixels // 2) <= 2 and math.abs(py - pixels // 2) <= 2 then
			r, g, b = 255, 0, 0
		end
		buffer.writeu8(image, offset, math.clamp(math.floor(r), 0, 255))
		buffer.writeu8(image, offset + 1, math.clamp(math.floor(g), 0, 255))
		buffer.writeu8(image, offset + 2, math.clamp(math.floor(b), 0, 255))
		offset += 3
	end
end

if not fs.isDir("tests/out") then
	fs.writeDir("tests/out")
end
fs.writeFile("tests/out/preview.ppm", image)
print(`Wrote tests/out/preview.ppm ({pixels}x{pixels}, {scale} blocks per pixel, seed {seed})`)
