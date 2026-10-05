--[[
	Generation / meshing benchmark and part count estimate.

	    lune run tests/bench [seed] [viewDistance] [splitDistance] [splitDistanceL1] [x z]

	Times generating and meshing chunks at every LOD level, then runs the real LOD selection around
	the spawn point and meshes every selected node to estimate how many parts the client creates,
	and how many remain when far meshes (Config.Render.FarMeshes) merge every eligible region.
]]

local process = require("@lune/process")
local Loader = require("./lib/Loader")

local shared, require = Loader.mount("src/shared", "IceVoxel")
local Config = require(shared.Config)
local Coords = require(shared.World.Coords)
local LodTree = require(shared.World.LodTree)
local GreedyMesher = require(shared.Meshing.GreedyMesher)
local QuadMesher = require(shared.Meshing.QuadMesher)
local MeshGeometry = require(shared.Meshing.MeshGeometry)
local ChunkLayout = require(shared.World.ChunkLayout)
local TerrainGenerator = require(shared.Generation.TerrainGenerator)

local seed = tonumber(process.args[1]) or 12345
LodTree.configure(
	tonumber(process.args[2]) or Config.Lod.ViewDistance,
	tonumber(process.args[3]) or Config.Lod.SplitDistance,
	tonumber(process.args[4]) or tonumber(process.args[3]) or Config.Lod.SplitDistanceL1
)
local gen = TerrainGenerator.new(seed)
local sx, sh, sz = gen.findSpawn()
if process.args[6] then
	-- Somewhere else than the spawn (e.g. inside a mountain range).
	sx, sz = tonumber(process.args[5]) :: number, tonumber(process.args[6]) :: number
	sh = gen.column(sx, sz)
end
print(`seed {seed}, viewpoint {sx}, {sh}, {sz}`)

-- Generates and meshes a node like ChunkWorker (far nodes with their far seam borders). Returns
-- generation time, meshing time, boxes and (far nodes) the quads for far meshes and their count.
local function meshNode(
	level: number,
	nx: number,
	nz: number,
	revealAll: boolean
): (number, number, number, buffer?, number)
	local t0 = os.clock()
	local r = gen.generate(level, nx, nz)
	local t1 = os.clock()
	local boxes, quads, quadCount = 0, nil, 0
	if level == 0 then
		for y0 = 0, r.height - 1, Config.SectionHeight do
			local y1 = y0 + Config.SectionHeight
			local hide = not revealAll
			if not GreedyMesher.isTrivial(y0, y1, r.solidBelow, r.emptyAbove, hide) then
				-- (Plants are left out: the README counts their parts separately, see
				-- Lod.FoliageDistance.)
				local _, count = GreedyMesher.mesh(r.data, r.height, y0, y1, hide, nil, true)
				boxes += count
			end
		end
	else
		local open = gen.farSeamLimits(level, nx, nz)
		local below = math.min(r.solidBelow, GreedyMesher.lowestOpen(open))
		local y0, y1 = GreedyMesher.activeRange(below, r.emptyAbove, r.height)
		if y1 > y0 then
			local data = if open
				then GreedyMesher.applyBorder(r.data, r.height, y0, y1, true, { open = open, hidden = 0 })
				else r.data
			local _, count = GreedyMesher.mesh(data, r.height, y0, y1, true)
			boxes += count
			local tMesh = os.clock()
			quads, quadCount = QuadMesher.mesh(data, r.height, y0, y1, true)
			t1 += os.clock() - tMesh -- quads are not part of the box meshing time
		end
	end
	return t1 - t0, os.clock() - t1, boxes, quads, quadCount
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
local FarMeshes = Config.Render.FarMeshes
local merged = 0
-- One MeshGeometry builder per region, fed like Rendering/MeshOverlay builds them (meshes are
-- split by triangle count and by height band).
local regionBuilders: { [string]: MeshGeometry.Builder } = {}
local t0 = os.clock()
for key, level in nodes do
	local _, nx, nz = Coords.decodeNodeKey(key)
	local _, _, boxes, quads, quadCount = meshNode(level, nx, nz, false)
	local entry = perLevel[level] or { count = 0, boxes = 0 }
	entry.count += 1
	entry.boxes += boxes
	perLevel[level] = entry
	total += boxes
	-- Regions as Rendering/MeshRegions forms them.
	local size = LodTree.nodeSize(level)
	if level >= FarMeshes.MinLevel and size <= FarMeshes.MaxRegionBlocks then
		local perSide = math.max(1, math.min(FarMeshes.RegionNodes, FarMeshes.MaxRegionBlocks // size))
		local region = `{level}:{nx // perSide},{nz // perSide}`
		local builder = regionBuilders[region]
		if builder == nil then
			builder = MeshGeometry.builder(Config.BlockSize, FarMeshes.Overlap, FarMeshes.MaxTriangles)
			regionBuilders[region] = builder
		end
		if quads and quadCount > 0 then
			local step, stepY = ChunkLayout.steps(level)
			local scale = step * Config.BlockSize
			builder:add(
				quads,
				quadCount,
				nx * Config.ChunkSize * scale,
				nz * Config.ChunkSize * scale,
				scale,
				stepY * Config.BlockSize
			)
		end
		merged += boxes
	end
end
totalTime = os.clock() - t0
for level = 0, Config.Lod.Levels - 1 do
	local e = perLevel[level]
	if e then
		print(string.format("  level %d: %4d nodes, %7d parts", level, e.count, e.boxes))
	end
end
print(string.format("  total: %d parts, generated + meshed in %.2f s on one thread", total, totalTime))
local meshParts, triangles, regions = 0, 0, 0
for _, builder in regionBuilders do
	regions += 1
	for _, mesh in builder:finish() do
		meshParts += 1
		triangles += mesh.quads * 2
	end
end
print(
	string.format(
		"  with far meshes (level %d+): %d parts + %d MeshParts in %d regions (%dk triangles)",
		FarMeshes.MinLevel,
		total - merged,
		meshParts,
		regions,
		triangles // 1000
	)
)
