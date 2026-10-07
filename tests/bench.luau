--[[
	Generation / meshing benchmark and part count estimate.

	    lune run tests/bench [seed] [viewDistance] [splitDistance] [splitDistanceL1] [x z]

	Times generating and meshing chunks at every LOD level, then runs the real LOD selection around
	the spawn point and meshes every selected node to estimate how many parts the client creates,
	and how many remain when far meshes (Config.Render.FarMeshes) merge every eligible region.
	Then what the Caves setting costs over the full detail range (above ground, and with the
	underground split): parts, meshing time, the boxes' bytes and the sparse lights with caves
	hidden (no camera underground) and always shown (every section revealed, capped towards the
	coarser nodes around, a section with no cave cell near meshed hidden as the workers do).
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
	tonumber(process.args[4]) or tonumber(process.args[3]) or Config.Lod.SplitDistanceL1,
	-- (Full detail underground: the Caves setting's cost below.)
	Config.Lod.UndergroundSplitDistanceL1
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

-- The Caves setting over the full detail range: hidden (above ground, nothing revealed) against
-- always shown (ChunkWorker's way: revealed sections without a cave cell near mesh hidden).
local Blocks = require(shared.Blocks)
local function lightsOf(boxes: buffer, count: number): number
	local lights = 0
	for i = 0, count - 1 do
		local app, surface = GreedyMesher.decodeKey(buffer.readu16(boxes, i * GreedyMesher.BOX_BYTES + 12))
		if buffer.readu8(GreedyMesher.sparseLightLut, app) == 1 then
			local lit = if Blocks.appearances[app].shape
				then surface == 1
				else select(2, GreedyMesher.fluidSurface(surface))
			if lit then
				lights += 1
			end
		end
	end
	return lights
end
for _, underground in { false, true } do
	local selected = LodTree.select(sx + 0.5, sz + 0.5, nil, underground)
	local full: { [number]: boolean } = {}
	local chunks = {}
	for key, level in selected do
		if level == 0 then
			local _, nx, nz = Coords.decodeNodeKey(key)
			full[Coords.chunkKey(nx, nz)] = true
			table.insert(chunks, { nx, nz })
		end
	end
	local cost = {
		hidden = { parts = 0, ms = 0, sections = 0, lights = 0 },
		always = { parts = 0, ms = 0, sections = 0, lights = 0 },
	}
	for _, c in chunks do
		local r = gen.generate(0, c[1], c[2])
		local caps = 0
		for d, side in { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } } do
			if not full[Coords.chunkKey(c[1] + side[1], c[2] + side[2])] then
				caps += bit32.lshift(1, d - 1)
			end
		end
		for y0 = 0, r.height - 1, Config.SectionHeight do
			local y1 = math.min(y0 + Config.SectionHeight, r.height)
			for mode, entry in cost do
				local t0 = os.clock()
				local hide = mode == "hidden" or not GreedyMesher.touchesCaves(r.data, r.height, y0, y1)
				if not GreedyMesher.isTrivial(y0, y1, r.solidBelow, r.emptyAbove, hide) then
					local border = if not hide and caps ~= 0 then { hidden = caps } else nil
					local boxes, count = GreedyMesher.mesh(r.data, r.height, y0, y1, hide, border, true)
					entry.parts += count
					entry.sections += 1
					entry.lights += lightsOf(boxes, count)
				end
				entry.ms += (os.clock() - t0) * 1000
			end
		end
	end
	local hidden, always = cost.hidden, cost.always
	print(
		string.format(
			"\nFull detail caves%s, %d chunks (plants left out):\n  hidden until seen: %6d parts, %4d sections meshed in %5.0f ms, %5.0f KB of boxes, %d lights\n  always shown:      %6d parts (%.2fx), %4d sections meshed in %5.0f ms, %5.0f KB of boxes, %d lights",
			if underground then " (underground split)" else "",
			#chunks,
			hidden.parts,
			hidden.sections,
			hidden.ms,
			hidden.parts * GreedyMesher.BOX_BYTES / 1024,
			hidden.lights,
			always.parts,
			always.parts / math.max(hidden.parts, 1),
			always.sections,
			always.ms,
			always.parts * GreedyMesher.BOX_BYTES / 1024,
			always.lights
		)
	)
end
