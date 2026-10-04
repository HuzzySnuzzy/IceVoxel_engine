--[[
	Generation / meshing benchmark and part count estimate.

	    lune run tests/bench [seed] [viewDistance] [splitDistance]

	Times generating and meshing chunks at every LOD level, then runs the real LOD selection around
	the spawn point and meshes every selected node to estimate how many parts the client creates.
]]

local process = require("@lune/process")
local Loader = require("./lib/Loader")

local shared, require = Loader.mount("src/shared", "IceVoxel")
local Config = require(shared.Config)
local Coords = require(shared.World.Coords)
local LodTree = require(shared.World.LodTree)
local GreedyMesher = require(shared.Meshing.GreedyMesher)
local TerrainGenerator = require(shared.Generation.TerrainGenerator)

local seed = tonumber(process.args[1]) or 12345
LodTree.configure(
	tonumber(process.args[2]) or Config.Lod.ViewDistance,
	tonumber(process.args[3]) or Config.Lod.SplitDistance
)
local gen = TerrainGenerator.new(seed)
local sx, sh, sz = gen.findSpawn()
print(`seed {seed}, spawn at {sx}, {sh}, {sz}`)

local function meshNode(level: number, nx: number, nz: number, revealAll: boolean): (number, number, number)
	local t0 = os.clock()
	local r = gen.generate(level, nx, nz)
	local t1 = os.clock()
	local boxes = 0
	if level == 0 then
		for y0 = 0, r.height - 1, Config.SectionHeight do
			local y1 = y0 + Config.SectionHeight
			local hide = not revealAll
			if not GreedyMesher.isTrivial(y0, y1, r.solidBelow, r.emptyAbove, hide) then
				local _, count = GreedyMesher.mesh(r.data, r.height, y0, y1, hide)
				boxes += count
			end
		end
	else
		local y0, y1 = GreedyMesher.activeRange(r.solidBelow, r.emptyAbove, r.height)
		if y1 > y0 then
			local _, count = GreedyMesher.mesh(r.data, r.height, y0, y1, true)
			boxes += count
		end
	end
	return t1 - t0, os.clock() - t1, boxes
end

print("\nPer chunk (average of 16 chunks around spawn):")
print("level  generate   mesh     boxes")
for level = 0, Config.Lod.Levels - 1 do
	local size = LodTree.nodeSize(level)
	local gx, gz = sx // size, sz // size
	local tg, tm, tb, n = 0, 0, 0, 0
	for dz = -2, 1 do
		for dx = -2, 1 do
			local g, m, b = meshNode(level, gx + dx, gz + dz, false)
			tg += g
			tm += m
			tb += b
			n += 1
		end
	end
	print(string.format("  %d    %6.2f ms  %6.2f ms  %6.0f", level, tg / n * 1000, tm / n * 1000, tb / n))
end

local _, _, caveBoxes = meshNode(0, sx // 16, sz // 16, true)
local _, _, hiddenBoxes = meshNode(0, sx // 16, sz // 16, false)
print(`\nSpawn chunk boxes with caves revealed: {caveBoxes}, hidden: {hiddenBoxes}`)

print(`\nFull view from spawn (caves hidden, view distance {LodTree.viewDistance()}):`)
local nodes = LodTree.select(sx + 0.5, sz + 0.5)
local perLevel: { [number]: { count: number, boxes: number } } = {}
local total, totalTime = 0, 0
local t0 = os.clock()
for key, level in nodes do
	local _, nx, nz = Coords.decodeNodeKey(key)
	local _, _, boxes = meshNode(level, nx, nz, false)
	local entry = perLevel[level] or { count = 0, boxes = 0 }
	entry.count += 1
	entry.boxes += boxes
	perLevel[level] = entry
	total += boxes
end
totalTime = os.clock() - t0
for level = 0, Config.Lod.Levels - 1 do
	local e = perLevel[level]
	if e then
		print(string.format("  level %d: %4d nodes, %7d parts", level, e.count, e.boxes))
	end
end
print(string.format("  total: %d parts, generated + meshed in %.2f s on one thread", total, totalTime))
