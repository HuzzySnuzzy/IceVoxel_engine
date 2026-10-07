--!strict
--[[
	Chunk worker, cloned into every Actor by WorkerPool. Runs generation, meshing and the culling
	work in parallel.

	Jobs ("Job" actor message). Every job has `id` (WorkerPool) and may carry
	  edit    true: the edit lane (below)
	  slice   the slice budget (ms) for this job; Config.Workers.SliceBudgetMs when missing (the
	          worker's own Config never sees the player's settings, so they travel in each job)

	  generate   { level, nx, nz, coarser, edits?, reveal?, caps?, quads?, foliage?, graph? }
	             -> { data (LOD 0 only), height, solidBelow, emptyAbove, sections, meshes,
	                  plants, quads?, quadCount, summary, graph?, bury?, caveSections? }
	             section meshes (+ the node's quads for Rendering/MeshOverlay when `quads`),
	             `plants` the sections holding plants, `summary` the node's Shared/World/Horizon
	             summary (every level; with the `edits` in it). Full detail chunks also get `graph`, their
	             Shared/World/SectionGraph (unless `graph` is false; with the generated surface
	             as its sky line), `bury` (the generated solidBelow, before edits: below it
	             sections are BURIED) and `caveSections` (the sections that may hold cave cells or
	             air carved below the surface), which a later `graph` job needs.
	  mesh       { nx, nz, coarser, data, height, solidBelow, emptyAbove, sections, reveal, caps?,
	             foliage?, graph?, graphSections? } -> { sections, meshes, plants, graph? }
	             section meshes + `plants`, those of `sections` holding plants (full detail
	             chunks only). With `graph` (the chunk's SectionGraph), the sections in
	             `graphSections` (default: `sections`) are recomputed in it (edits can open or
	             seal caves) and it comes back as `graph`.
	  graph      { data, height, bury, sections, sky? } -> { graph }   a chunk's SectionGraph, later
	             (`sky`: its sky line, TerrainGenerator's `surface`)
	  horizon    { records, count, x, y, z, raise?, spread?, keep?, bins? } -> { hidden }
	             the node keys of Horizon.evaluate (far nodes hidden behind terrain)
	  map        { x, z, scale, size } -> { pixels }   RGBA pixels of a map tile (Map/MapPainter)

	`coarser` is the level of the coarser node on each side (-X, +X, -Z, +Z; 0 = none) of a full
	detail chunk and `caps` the GreedyMesher.Border hidden mask of each revealed section
	({ section, mask, ... }); together they give the mesher's border (seams between LOD levels, cave
	caps). Far nodes use generator.farSeamLimits instead, which holds for any neighbours.
	`foliage` is whether the chunk draws its plants (LodTree.drawsFoliage: Config.Render.Foliage and
	the foliage distance, as the streamer saw them; this worker's own Config.Render.Foliage when it
	is missing): false meshes without plants (GreedyMesher's `hideFoliage`). Plants are counted
	either way, so the streamer knows which sections to remesh when that changes.

	Failures answer { id, failed = true, sections = {}, meshes = {} }.

	Slices: after the job's slice budget the worker waits for the next frame, so a busy worker
	never stalls rendering. Jobs run one at a time per worker because the generator and mesher
	reuse scratch memory.

	Edit lane: jobs with `edit` run before every other queued job, and a mesh job with `edit`
	doesn't even wait for the running job: that one lets it run at its next slice boundary (never
	while it holds the mesher's scratch memory across a slice), so an edit takes about a frame,
	never a whole generation job. (Other kinds only jump the queue: they share the generator's
	scratch memory with the running job.)

	Cancelling ("Cancel" actor message, a list of job ids): a queued job is dropped at once, a
	running one at its next slice boundary; each answers { id, cancelled = true, sections = {},
	meshes = {} }. Ids no longer queued or running are ignored.
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
local WorldTypes = require(Shared.Generation.WorldTypes)
local Caves = require(Shared.Generation.Caves)
local SectionGraph = require(Shared.World.SectionGraph)
local Horizon = require(Shared.World.Horizon)
local MapPainter = require(Shared.Map.MapPainter)

local resultEvent = actor:WaitForChild("Result") :: BindableEvent

local seed = Shared:GetAttribute("Seed")
while type(seed) ~= "number" do
	Shared:GetAttributeChangedSignal("Seed"):Wait()
	seed = Shared:GetAttribute("Seed")
end
local generator = WorldTypes.fromAttributes(Shared)
local paintMap = MapPainter.new(generator)

type Job = { [string]: any }

local SECTION = Config.SectionHeight
-- Odd boxes for textured blocks at full detail (GreedyMesher's `align`; never for LOD nodes).
local ALIGN = Config.Textures.OddBoxes
local SIZE = ChunkLayout.SIZE
local LAYER = ChunkLayout.LAYER
local AIR = Blocks.AIR
local cullHidden = Blocks.cullLutHiddenCaves

-- Thrown (as the error value) out of a job that was cancelled.
local CANCELLED = table.freeze({})

--[[ Scheduling state ]]

-- Queued jobs (false: cancelled while queued), with their read positions: the edit lane's mesh
-- jobs, its other jobs, everything else.
local edits: { Job | false } = {}
local editsHead = 1
local urgent: { Job | false } = {}
local urgentHead = 1
local queue: { Job | false } = {}
local queueHead = 1
local running = false
-- Jobs started and not finished (by id), and those asked to stop.
local active: { [number]: boolean } = {}
local stopping: { [number]: boolean } = {}
-- The innermost job running, its slice budget (seconds) and when its slice started.
local current: Job? = nil
local budget = Config.Workers.SliceBudgetMs / 1000
local sliceStart = os.clock()
-- False while the running job keeps scratch memory across a slice boundary (no edit may run
-- then); `nested` while an edit job runs inside another job's slice boundary.
local preemptible = true
local nested = false

local runJob: (job: Job) -> ()

local function pendingEdits(): boolean
	while editsHead <= #edits and edits[editsHead] == false do
		editsHead += 1
	end
	return editsHead <= #edits
end

-- Runs the edit lane's jobs now, inside the running job's slice boundary.
local function runEdits()
	nested = true
	while pendingEdits() do
		local job = edits[editsHead] :: Job
		edits[editsHead] = false
		editsHead += 1
		runJob(job)
	end
	nested = false
end

local function checkStop()
	local job = current
	if job and stopping[job.id] then
		error(CANCELLED, 0)
	end
end

local function yieldIfNeeded()
	if os.clock() - sliceStart > budget then
		task.synchronize()
		task.wait()
		task.desynchronize()
		sliceStart = os.clock()
		checkStop()
	end
	if preemptible and not nested and pendingEdits() then
		runEdits()
		checkStop()
	end
end

--[[ Jobs ]]

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
local function hidesFoliage(job: Job): boolean
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

local function generate(job: Job): Job
	local level = job.level :: number
	local r = generator.generate(level, job.nx, job.nz, yieldIfNeeded, true)
	local data, height = r.data, r.height
	local solidBelow, emptyAbove = r.solidBelow, r.emptyAbove
	-- (Sections below the generated surface are buried: open air there was dug.)
	local bury = solidBelow
	local open
	if level > 0 then
		open = generator.farSeamLimits(level, job.nx, job.nz)
	elseif job.coarser then
		open = generator.seamLimits(level, job.nx, job.nz, job.coarser)
	end
	yieldIfNeeded()
	local caps = capMap(job.caps)

	-- Sections whose cells the generator's cave lattice doesn't describe (edits, structures).
	local exact: { [number]: boolean } = {}
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
			exact[y // SECTION] = true
			if block ~= AIR and y + 1 > emptyAbove then
				emptyAbove = y + 1
			end
			if buffer.readu8(cullHidden, block) == 0 and y < solidBelow then
				solidBelow = y
			end
		end
		-- (The summary describes the generated terrain: dug ground and built blocks change it.)
		local summary = r.summary
		if summary then
			Horizon.applyEdits(summary, data, height, edits, Blocks.cullLut)
		end
	end

	-- The cave visibility graph (full detail only).
	local graph, caveSections = nil, nil
	if level == 0 then
		local span = r.structureSpan
		if span then
			for s = span[1] // SECTION, span[2] // SECTION do
				exact[s] = true
			end
		end
		-- Air carved below the generated surface (surface caves: entrances and ravines; cellars):
		-- the cave lattice knows nothing of it, so those sections are read cell by cell, and the
		-- surface heights become the graph's sky line (air below it is followed underground).
		local surface = r.surface
		if surface then
			SectionGraph.dugSections(data, height, surface, solidBelow, exact)
		end
		local extra = {}
		for s in exact do
			table.insert(extra, s)
		end
		local sections = SectionGraph.carvedSections(r.carved, Caves.CELL_Y, extra)
		caveSections = sections
		if job.graph ~= false then
			local hint: SectionGraph.Hint? = nil
			if r.surface then
				hint = {
					carved = r.carved,
					cellXZ = Caves.CELL_XZ,
					cellY = Caves.CELL_Y,
					originX = job.nx * SIZE,
					originZ = job.nz * SIZE,
					surface = r.surface,
					exact = exact,
				}
			end
			graph = SectionGraph.build(data, height, bury, sections, hint, yieldIfNeeded)
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
				local boxes, count, plantCells = GreedyMesher.mesh(
					data,
					height,
					y0,
					y1,
					hide,
					borderOf(open, caps, section),
					hideFoliage,
					nil,
					ALIGN
				)
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
			-- The border copy is the mesher's scratch memory and must survive the slice boundary
			-- before the quads: no edit job may run in between.
			preemptible = false
			local border = borderOf(open, nil, 0)
			local meshData = if border then GreedyMesher.applyBorder(data, height, y0, y1, true, border) else data
			-- (No sparse lights: far parts carry none, and marking them would only split boxes.)
			local boxes, count = GreedyMesher.mesh(meshData, height, y0, y1, true, nil, hideFoliage, true)
			if count > 0 then
				table.insert(indices, 0)
				table.insert(meshes, boxes)
			end
			if job.quads then
				yieldIfNeeded()
				quads, quadCount = QuadMesher.mesh(meshData, height, y0, y1, true)
			end
			preemptible = true
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
		summary = r.summary,
		graph = graph,
		bury = if level == 0 then bury else nil,
		caveSections = caveSections,
	}
end

local function remesh(job: Job): Job
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
				GreedyMesher.mesh(data, height, y0, y1, hide, borderOf(open, caps, section), hideFoliage, nil, ALIGN)
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
	-- The graph comes as this job's own copy: update it in place.
	local graph = job.graph
	if type(graph) == "buffer" then
		SectionGraph.refresh(graph, data, height, job.graphSections or job.sections, yieldIfNeeded)
	else
		graph = nil
	end
	return { id = job.id, sections = indices, meshes = meshes, plants = plants, graph = graph }
end

local function graphJob(job: Job): Job
	return {
		id = job.id,
		graph = SectionGraph.build(job.data, job.height, job.bury, job.sections, nil, yieldIfNeeded, job.sky),
	}
end

local function horizon(job: Job): Job
	local hidden = Horizon.evaluate(job.records, job.count, job.x, job.y, job.z, {
		raise = job.raise,
		spread = job.spread,
		keep = job.keep,
		bins = job.bins,
	}, yieldIfNeeded)
	return { id = job.id, hidden = hidden }
end

local function map(job: Job): Job
	return { id = job.id, pixels = paintMap(job.x, job.z, job.scale, job.size, yieldIfNeeded) }
end

local RUN: { [string]: (Job) -> Job } = {
	generate = generate,
	mesh = remesh,
	graph = graphJob,
	horizon = horizon,
	map = map,
}

function runJob(job: Job)
	local outer, outerBudget, outerPreemptible = current, budget, preemptible
	current = job
	active[job.id] = true
	local slice = job.slice
	budget = (if type(slice) == "number" and slice > 0 then slice else Config.Workers.SliceBudgetMs) / 1000
	preemptible = true
	if outer == nil then
		sliceStart = os.clock()
	end
	local ok, result = pcall(RUN[job.kind] or generate, job)
	active[job.id] = nil
	if not ok then
		if result == CANCELLED or stopping[job.id] then
			result = { id = job.id, cancelled = true, sections = {}, meshes = {} }
		else
			warn(`[IceVoxel] worker job failed: {result}`)
			result = { id = job.id, failed = true, sections = {}, meshes = {} }
		end
	end
	stopping[job.id] = nil
	current, budget, preemptible = outer, outerBudget, outerPreemptible
	task.synchronize()
	resultEvent:Fire(result)
	task.desynchronize()
	sliceStart = os.clock()
end

local function nextJob(): Job?
	if pendingEdits() then
		local job = edits[editsHead] :: Job
		edits[editsHead] = false
		editsHead += 1
		return job
	end
	while urgentHead <= #urgent do
		local job = urgent[urgentHead]
		urgent[urgentHead] = false
		urgentHead += 1
		if job ~= false then
			return job :: Job
		end
	end
	while queueHead <= #queue do
		local job = queue[queueHead]
		queue[queueHead] = false
		queueHead += 1
		if job ~= false then
			return job :: Job
		end
	end
	return nil
end

local function run()
	running = true
	while true do
		local job = nextJob()
		if job == nil then
			break
		end
		runJob(job)
	end
	-- Every queue is drained: start them over.
	table.clear(edits)
	table.clear(urgent)
	table.clear(queue)
	editsHead, urgentHead, queueHead = 1, 1, 1
	running = false
end

actor:BindToMessageParallel("Job", function(job: Job)
	-- Only mesh jobs may run inside another job's slice boundary: generation and the rest use the
	-- generator's scratch memory.
	if job.edit == true and job.kind == "mesh" then
		table.insert(edits, job)
	elseif job.edit == true then
		table.insert(urgent, job)
	else
		table.insert(queue, job)
	end
	if not running then
		run()
	end
end)

-- Serial: it only runs while the job loop waits, and answers from here need no synchronize.
actor:BindToMessage("Cancel", function(ids: { number })
	local wanted = toSet(ids)
	for _, list in { edits, urgent, queue } do
		for i, entry in list do
			if entry ~= false then
				local job = entry :: Job
				if wanted[job.id] then
					list[i] = false
					resultEvent:Fire({ id = job.id, cancelled = true, sections = {}, meshes = {} })
				end
			end
		end
	end
	for _, id in ids do
		if active[id] then
			stopping[id] = true
		end
	end
end)

resultEvent:Fire({ ready = true })
