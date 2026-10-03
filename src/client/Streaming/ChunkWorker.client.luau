--!strict
--[[
	Chunk worker, cloned into every Actor by WorkerPool. Runs generation and meshing in parallel.

	Jobs ("Job" actor message):
	  generate   { level, nx, nz, edits?, reveal? } -> chunk data (LOD 0 only) + section meshes
	  mesh       { data, height, solidBelow, emptyAbove, sections, reveal } -> section meshes
	  map        { x, z, scale, size } -> RGBA pixels of a map tile (Map/MapPainter)

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

local function generate(job: { [string]: any }): { [string]: any }
	local level = job.level :: number
	local r = generator.generate(level, job.nx, job.nz, yieldIfNeeded)
	local data, height = r.data, r.height
	local solidBelow, emptyAbove = r.solidBelow, r.emptyAbove

	local edits = job.edits :: { number }?
	if edits then
		for i = 1, #edits, 2 do
			local index, block = edits[i], edits[i + 1]
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

	local indices: { number }, meshes: { buffer } = {}, {}
	if level == 0 then
		local reveal = toSet(job.reveal)
		for section = 0, height // SECTION - 1 do
			local y0, y1 = section * SECTION, (section + 1) * SECTION
			local hide = not reveal[section]
			if not GreedyMesher.isTrivial(y0, y1, solidBelow, emptyAbove, hide) then
				local boxes, count = GreedyMesher.mesh(data, height, y0, y1, hide)
				if count > 0 then
					table.insert(indices, section)
					table.insert(meshes, boxes)
				end
				yieldIfNeeded()
			end
		end
	else
		local y0, y1 = GreedyMesher.activeRange(solidBelow, emptyAbove, height)
		if y1 > y0 then
			local boxes, count = GreedyMesher.mesh(data, height, y0, y1, true)
			if count > 0 then
				table.insert(indices, 0)
				table.insert(meshes, boxes)
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
	}
end

local function remesh(job: { [string]: any }): { [string]: any }
	local data = job.data :: buffer
	local height = job.height :: number
	local reveal = toSet(job.reveal)
	local indices: { number }, meshes: { buffer } = {}, {}
	for _, section in job.sections :: { number } do
		local y0, y1 = section * SECTION, math.min((section + 1) * SECTION, height)
		local hide = not reveal[section]
		local boxes = buffer.create(0)
		if not GreedyMesher.isTrivial(y0, y1, job.solidBelow, job.emptyAbove, hide) then
			boxes = GreedyMesher.mesh(data, height, y0, y1, hide)
		end
		-- Empty meshes are sent too: they clear the section's old parts.
		table.insert(indices, section)
		table.insert(meshes, boxes)
		yieldIfNeeded()
	end
	return { id = job.id, sections = indices, meshes = meshes }
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
