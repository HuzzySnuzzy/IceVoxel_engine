--!strict
--[[
	A pool of Actors running ChunkWorker, so terrain generation, meshing and the culling work run
	in parallel on several cores (Parallel Luau) instead of on the main thread.

	Jobs and results only contain numbers, strings, buffers, dense arrays and string-keyed tables,
	which is what survives being copied across actor boundaries (so a buffer sent in a job is the
	worker's own copy).

	`submit` gives the job an id (`job.id`, set on the table passed in). With it, `cancel` stops
	jobs that are no longer wanted (a teleport, a node removed): their callbacks are dropped at
	once, and each worker drops them from its queue, or stops the running one at its next slice
	boundary. The slot stays taken until the worker confirms, which takes about a frame.

	Edit lane: a job with `edit = true` (the player's edits: see ChunkWorker) goes to the worker
	with the fewest edit jobs, and may use EDIT_SLOTS slots beyond `perWorker`, so it is never
	refused because generation filled every slot (`hasCapacity(true)` says whether one fits).
	Small, low priority jobs (map tiles, horizon verdicts) may use one extra slot per worker
	(`overflow`), so they still make progress while streaming keeps every regular slot busy.
]]

local Players = game:GetService("Players")

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("IceVoxel").Config)

export type Result = { [string]: any }
export type Callback = (result: Result) -> ()

-- Slots beyond `perWorker` only edit jobs may take.
local EDIT_SLOTS = 2

type Worker = {
	actor: Actor,
	ready: boolean,
	inFlight: number,
	-- Edit jobs in flight.
	edits: number,
}

export type WorkerPool = {
	workers: { Worker },
	callbacks: { [number]: Callback },
	owners: { [number]: Worker },
	-- Ids of edit jobs in flight.
	editJobs: { [number]: boolean },
	nextId: number,
	perWorker: number,

	hasCapacity: (self: WorkerPool, edit: boolean?, overflow: boolean?) -> boolean,
	submit: (self: WorkerPool, job: { [string]: any }, callback: Callback, overflow: boolean?) -> boolean,
	cancel: (self: WorkerPool, ids: { number }) -> number,
	busy: (self: WorkerPool) -> number,
}

local WorkerPool = {}
WorkerPool.__index = WorkerPool
WorkerPool.EDIT_SLOTS = EDIT_SLOTS

function WorkerPool.new(template: LocalScript, count: number?): WorkerPool
	local self = (
		setmetatable({
			workers = {},
			callbacks = {},
			owners = {},
			editJobs = {},
			nextId = 0,
			perWorker = Config.Workers.JobsPerWorker,
		}, WorkerPool) :: any
	) :: WorkerPool

	-- LocalScripts only run below PlayerScripts (among a few other places).
	local container = Players.LocalPlayer:WaitForChild("PlayerScripts")

	for i = 1, count or Config.Workers.Count do
		local actor = Instance.new("Actor")
		actor.Name = `IceVoxelWorker{i}`

		local resultEvent = Instance.new("BindableEvent")
		resultEvent.Name = "Result"
		resultEvent.Parent = actor

		local worker: Worker = { actor = actor, ready = false, inFlight = 0, edits = 0 }
		table.insert(self.workers, worker)

		resultEvent.Event:Connect(function(result: Result)
			if result.ready then
				worker.ready = true
				return
			end
			local id = result.id :: number
			-- A late answer for a job already accounted for (should not happen) is ignored.
			if self.owners[id] ~= worker then
				return
			end
			local callback = self.callbacks[id]
			self.callbacks[id] = nil
			self.owners[id] = nil
			worker.inFlight -= 1
			if self.editJobs[id] then
				self.editJobs[id] = nil
				worker.edits -= 1
			end
			-- (Cancelled jobs have no callback any more.)
			if callback and not result.cancelled then
				callback(result)
			end
		end)

		local script = template:Clone()
		script.Parent = actor
		actor.Parent = container
	end

	return self
end

-- Can a job be submitted now (an edit job: with the edit lane's extra slots; `overflow`: with
-- submit's extra slot)?
function WorkerPool.hasCapacity(self: WorkerPool, edit: boolean?, overflow: boolean?): boolean
	local limit = if edit then self.perWorker + EDIT_SLOTS elseif overflow then self.perWorker + 1 else self.perWorker
	for _, worker in self.workers do
		if worker.ready and worker.inFlight < limit then
			return true
		end
	end
	return false
end

--[[
	Sends a job to the least busy ready worker (an edit job: the one with the fewest edit jobs).
	Returns false if every worker is full; otherwise `job.id` is the job's id.
	`overflow` lets a small, low priority job (map tiles, horizon jobs) use one extra slot per worker,
	so it still makes progress while chunk streaming keeps every regular slot busy.
]]
function WorkerPool.submit(self: WorkerPool, job: { [string]: any }, callback: Callback, overflow: boolean?): boolean
	local edit = job.edit == true
	local limit = if edit then self.perWorker + EDIT_SLOTS elseif overflow then self.perWorker + 1 else self.perWorker
	local best: Worker? = nil
	for _, worker in self.workers do
		if worker.ready and worker.inFlight < limit then
			if
				best == nil
				or (edit and worker.edits < best.edits)
				or ((not edit or worker.edits == best.edits) and worker.inFlight < best.inFlight)
			then
				best = worker
			end
		end
	end
	if best == nil then
		return false
	end

	self.nextId += 1
	local id = self.nextId
	job.id = id
	self.callbacks[id] = callback
	self.owners[id] = best
	best.inFlight += 1
	if edit then
		self.editJobs[id] = true
		best.edits += 1
	end
	best.actor:SendMessage("Job", job)
	return true
end

--[[
	Cancels jobs by id (see the header): their callbacks never run. Unknown or finished ids are
	ignored. Returns how many were still in flight.
]]
function WorkerPool.cancel(self: WorkerPool, ids: { number }): number
	local byWorker: { [Worker]: { number } } = {}
	local n = 0
	for _, id in ids do
		local owner = self.owners[id]
		if owner and self.callbacks[id] ~= nil then
			self.callbacks[id] = nil
			local list = byWorker[owner]
			if list == nil then
				list = {}
				byWorker[owner] = list
			end
			table.insert(list, id)
			n += 1
		end
	end
	for worker, list in byWorker do
		worker.actor:SendMessage("Cancel", list)
	end
	return n
end

-- Jobs currently being processed (cancelled ones count until their worker confirms).
function WorkerPool.busy(self: WorkerPool): number
	local n = 0
	for _, worker in self.workers do
		n += worker.inFlight
	end
	return n
end

return WorkerPool
