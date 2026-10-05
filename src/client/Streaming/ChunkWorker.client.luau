--!strict
--[[
	Chunk worker, cloned into every Actor by WorkerPool. Runs generation and meshing in parallel.

	Jobs ("Job" actor message):
	  generate   { level, nx, nz, coarser, edits?, reveal?, caps?, quads?, foliage? } -> chunk data
	             (LOD 0 only) + section meshes (+ the node's quads for Rendering/MeshOverlay when
	             `quads`) + `plants`, the sections holding plants
	  mesh       { nx, nz, coarser, data, height, solidBelow, emptyAbove, sections, reveal, caps?,
	             foliage? } -> section meshes + `plants`, those of `sections` holding plants (full
	             detail chunks only)

	  map        { x, z, scale, size } -> RGBA pixels of a map tile (Map/MapPainter)

	`coarser` is the level of the coarser node on each side (-X, +X, -Z, +Z; 0 = none) of a full
	detail chunk and `caps` the GreedyMesher.Border hidden mask of each revealed section
	({ section, mask, ... }); together they give the mesher's border (seams between LOD levels, cave
	caps). Far nodes use generator.farSeamLimits instead, which holds for any neighbours.
	`foliage` is whether the chunk draws its plants (LodTree.drawsFoliage: Config.Render.Foliage and
	the foliage distance, as the streamer saw them; this worker's own Config.Render.Foliage when it
	is missing): false meshes without plants (GreedyMesher's `hideFoliage`). Plants are counted
	either way, so the streamer knows which sections to remesh when that changes.

	Long jobs are split across frames: after Config.Workers.SliceBudgetMs the worker waits for the
	next frame, so a busy worker never stalls rendering. Jobs run one at a time per worker because
	the generator and mesher reuse scratch memory.
]]

local actor = script:GetActor()
if actor == nil then
	-- This is the template sitting in PlayerScripts; only the clones inside Actors do work.
	return
end

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Blocks = require(Shared.Blocks)
local ChunkLayout = require(Shared.World.ChunkLayout)
local GreedyMesher = require(Shared.Meshing.GreedyMesher)
local QuadMesher = require(Shared.Meshing.QuadMesher)
local TerrainGenerator = require(Shared.Generation.TerrainGenerator)
local MapPainter = require(Shared.Map.MapPainter)

local resultEvent = actor:WaitForChild("Result") :: BindableEvent

local seed = Shared:GetAttribute("Seed")
while type(seed) ~= "number" do
	Shared:GetAttributeChangedSignal("Seed"):Wait()
	seed = Shared:GetAttribute("Seed")
end
local generator = TerrainGenerator.new(seed :: number)
local paintMap = MapPainter.new(generator)

local SECTION = Config.SectionHeight
local LAYER = ChunkLayout.LAYER
local AIR = Blocks.AIR
local cullHidden = Blocks.cullLutHiddenCaves
local budget = Config.Workers.SliceBudgetMs / 1000

local sliceStart = os.clock()
local function yieldIfNeeded()
	if os.clock() - sliceStart > budget then
		task.synchronize()
		task.wait()
		task.desynchronize()
		sliceStart = os.clock()
	end
end

local function toSet(list: { number }?): { [number]: boolean }
	local set = {}
	if list then
		for _, v in list do
			set[v] = true
		end
	end
	return set
end

-- { section, mask, ... } -> { [section] = mask }
local function capMap(list: { number }?): { [number]: number }
	local map = {}
	if list then
		for i = 1, #list, 2 do
			map[list[i]] = list[i + 1]
		end
	end
	return map
end

-- Should a job's meshes leave plants out (Config.Render.Foliage off)?
local function hidesFoliage(job: { [string]: any }): boolean
	local foliage = job.foliage
	if type(foliage) ~= "boolean" then
		foliage = Config.Render.Foliage
	end
	return not foliage
end

-- Border for one mesh call; nil when there is nothing special around it.
local function borderOf(open: buffer?, caps: { [number]: number }?, section: number): GreedyMesher.Border?
	local hidden = if caps then caps[section] or 0 else 0
	if open == nil and hidden == 0 then
		return nil
	end
	return { open = open, hidden = hidden }
end

local function generate(job: { [string]: any }): { [string]: any }
	local level = job.level :: number
	local r = generator.generate(level, job.nx, job.nz, yieldIfNeeded)
	local data, height = r.data, r.height
	local solidBelow, emptyAbove = r.solidBelow, r.emptyAbove
	local open
	if level > 0 then
		open = generator.farSeamLimits(level, job.nx, job.nz)
	elseif job.coarser then
		open = generator.seamLimits(level, job.nx, job.nz, job.coarser)
	end
	yieldIfNeeded()
	local caps = capMap(job.caps)

	local edits = job.edits :: { number }?
	if edits then
		-- Edits may lie above the generated terrain's crop: make room first.
		local top = 0
		for i = 1, #edits, 2 do
			if edits[i + 1] ~= AIR then
				top = math.max(top, edits[i] // LAYER + 1)
			end
		end
		if top > height then
			height = ChunkLayout.croppedHeight(top, 1)
			data = ChunkLayout.grow(data, height)
		end
		for i = 1, #edits, 2 do
			local index, block = edits[i], edits[i + 1]
			if index // LAYER >= height then
				continue -- air above the crop
			end
			buffer.writeu16(data, index * 2, block)
			local y = index // LAYER
			if block ~= AIR and y + 1 > emptyAbove then
				emptyAbove = y + 1
			end
			if buffer.readu8(cullHidden, block) == 0 and y < solidBelow then
				solidBelow = y
			end
		end
	end

	-- Cells a seam opens up may lie below the otherwise buried range.
	local meshBelow = math.min(solidBelow, GreedyMesher.lowestOpen(open))
	local hideFoliage = hidesFoliage(job)
	local indices: { number }, meshes: { buffer } = {}, {}
	local plants: { number } = {}
	local quads, quadCount = nil, 0
	if level == 0 then
		local reveal = toSet(job.reveal)
		for section = 0, height // SECTION - 1 do
			local y0, y1 = section * SECTION, (section + 1) * SECTION
			local hide = not reveal[section]
			if not GreedyMesher.isTrivial(y0, y1, meshBelow, emptyAbove, hide) then
				local boxes, count, plantCells =
					GreedyMesher.mesh(data, height, y0, y1, hide, borderOf(open, caps, section), hideFoliage)
				if count > 0 then
					table.insert(indices, section)
					table.insert(meshes, boxes)
				end
				if plantCells > 0 then
					table.insert(plants, section)
				end
				yieldIfNeeded()
			end
		end
	else
		local y0, y1 = GreedyMesher.activeRange(meshBelow, emptyAbove, height)
		if y1 > y0 then
			-- The worker runs one job at a time, so the border scratch survives these yields.
			local border = borderOf(open, nil, 0)
			local meshData = if border then GreedyMesher.applyBorder(data, height, y0, y1, true, border) else data
			local boxes, count = GreedyMesher.mesh(meshData, height, y0, y1, true, nil, hideFoliage)
			if count > 0 then
				table.insert(indices, 0)
				table.insert(meshes, boxes)
			end
			if job.quads then
				yieldIfNeeded()
				quads, quadCount = QuadMesher.mesh(meshData, height, y0, y1, true)
			end
		end
	end

	return {
		id = job.id,
		-- Only full detail chunks keep their block data on the main thread (edits, raycasts).
		data = if level == 0 then data else nil,
		height = height,
		solidBelow = solidBelow,
		emptyAbove = emptyAbove,
		sections = indices,
		meshes = meshes,
		plants = plants,
		quads = quads,
		quadCount = quadCount,
	}
end

local function remesh(job: { [string]: any }): { [string]: any }
	local data = job.data :: buffer
	local height = job.height :: number
	local reveal = toSet(job.reveal)
	local open = if job.coarser then generator.seamLimits(0, job.nx, job.nz, job.coarser) else nil
	local caps = capMap(job.caps)
	local meshBelow = math.min(job.solidBelow, GreedyMesher.lowestOpen(open))
	local hideFoliage = hidesFoliage(job)
	local indices: { number }, meshes: { buffer } = {}, {}
	local plants: { number } = {}
	for _, section in job.sections :: { number } do
		local y0, y1 = section * SECTION, math.min((section + 1) * SECTION, height)
		local hide = not reveal[section]
		local boxes = buffer.create(0)
		if not GreedyMesher.isTrivial(y0, y1, meshBelow, job.emptyAbove, hide) then
			local meshed, _, plantCells =
				GreedyMesher.mesh(data, height, y0, y1, hide, borderOf(open, caps, section), hideFoliage)
			boxes = meshed
			if plantCells > 0 then
				table.insert(plants, section)
			end
		end
		-- Empty meshes are sent too: they clear the section's old parts.
		table.insert(indices, section)
		table.insert(meshes, boxes)
		yieldIfNeeded()
	end
	return { id = job.id, sections = indices, meshes = meshes, plants = plants }
end

local function map(job: { [string]: any }): { [string]: any }
	return { id = job.id, pixels = paintMap(job.x, job.z, job.scale, job.size, yieldIfNeeded) }
end

local RUN = { generate = generate, mesh = remesh, map = map }

local queue: { { [string]: any } } = {}
local running = false

local function run()
	running = true
	while #queue > 0 do
		local job = table.remove(queue, 1) :: { [string]: any }
		sliceStart = os.clock()
		local ok, result = pcall(RUN[job.kind] or generate, job)
		if not ok then
			warn(`[IceVoxel] worker job failed: {result}`)
			result = { id = job.id, failed = true, sections = {}, meshes = {} }
		end
		task.synchronize()
		resultEvent:Fire(result)
		task.desynchronize()
	end
	running = false
end

actor:BindToMessageParallel("Job", function(job: { [string]: any })
	table.insert(queue, job)
	if not running then
		run()
	end
end)

resultEvent:Fire({ ready = true })
