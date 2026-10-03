--!strict
--[[
	A pool of Actors running ChunkWorker, so terrain generation and meshing run in parallel on
	several cores (Parallel Luau) instead of on the main thread.

	Jobs and results only contain numbers, strings, buffers, dense arrays and string-keyed tables,
	which is what survives being copied across actor boundaries.
]]

local Players = game:GetService("Players")

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("IceVoxel").Config)

export type Result = { [string]: any }
export type Callback = (result: Result) -> ()

type Worker = {
	actor: Actor,
	ready: boolean,
	inFlight: number,
}

export type WorkerPool = {
	workers: { Worker },
	callbacks: { [number]: Callback },
	owners: { [number]: Worker },
	nextId: number,
	perWorker: number,

	hasCapacity: (self: WorkerPool) -> boolean,
	submit: (self: WorkerPool, job: { [string]: any }, callback: Callback, overflow: boolean?) -> boolean,
	busy: (self: WorkerPool) -> number,
}

local WorkerPool = {}
WorkerPool.__index = WorkerPool

function WorkerPool.new(template: LocalScript, count: number?): WorkerPool
	local self = (
		setmetatable({
			workers = {},
			callbacks = {},
			owners = {},
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

		local worker: Worker = { actor = actor, ready = false, inFlight = 0 }
		table.insert(self.workers, worker)

		resultEvent.Event:Connect(function(result: Result)
			if result.ready then
				worker.ready = true
				return
			end
			local id = result.id :: number
			local callback = self.callbacks[id]
			self.callbacks[id] = nil
			self.owners[id] = nil
			worker.inFlight -= 1
			if callback then
				callback(result)
			end
		end)

		local script = template:Clone()
		script.Parent = actor
		actor.Parent = container
	end

	return self
end

function WorkerPool.hasCapacity(self: WorkerPool): boolean
	for _, worker in self.workers do
		if worker.ready and worker.inFlight < self.perWorker then
			return true
		end
	end
	return false
end

--[[
	Sends a job to the least busy ready worker. Returns false if every worker is full.
	`overflow` lets a small, low priority job (map tiles) use one extra slot per worker, so it still
	makes progress while chunk streaming keeps every regular slot busy.
]]
function WorkerPool.submit(self: WorkerPool, job: { [string]: any }, callback: Callback, overflow: boolean?): boolean
	local limit = if overflow then self.perWorker + 1 else self.perWorker
	local best: Worker? = nil
	for _, worker in self.workers do
		if worker.ready and worker.inFlight < limit and (best == nil or worker.inFlight < best.inFlight) then
			best = worker
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
	best.actor:SendMessage("Job", job)
	return true
end

-- Jobs currently being processed.
function WorkerPool.busy(self: WorkerPool): number
	local n = 0
	for _, worker in self.workers do
		n += worker.inFlight
	end
	return n
end

return WorkerPool
