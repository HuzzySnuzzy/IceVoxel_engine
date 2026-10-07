--!strict
--[[
	Runs a save's DataStore requests within Roblox's limits, for World/WorldSave. Pure: the clock,
	the request budget, waiting and running in parallel come from its Env, so the specs run it
	against a fake DataStore with budgets, cooldowns, latency and failures.

	  Limits     Roblox gives each server a budget per kind of request, 60 + 10 per player a
	             minute (SetAsync and UpdateAsync share the write budget), and a key takes one
	             write every 6 seconds (`cooldown`). Before each request the scheduler asks
	             Env.budget for what is left of its kind (DataStoreService:
	             GetRequestBudgetForRequestType in the game) less what it already has in flight,
	             and waits while it is short; a key written less than `cooldown` seconds ago waits
	             too (the time is kept across saves, so an autosave right after /save-all waits
	             for the keys that one wrote).
	  Order      jobs start in the order given (World/WorldSave puts players first, then the
	             regions' parts, then their heads, then the world's record), at most
	             `concurrency` at a time (8: a write takes 0.1-0.5 s, so a save of 40 keys takes
	             a few seconds, not twenty).
	  Failures   a request that fails (Env's `run` returns false and why) is tried again after
	             1, 2, 4, 8, 16 s (`backoff`, doubling up to `maxBackoff`), at most `attempts`
	             times in all; then it is reported failed and the save says so.
	  Deadline   `run` stops starting requests at `deadline` (BindToClose has 30 s) and reports
	             what never went out.
]]

-- DataStore request kinds: GetAsync, SetAsync, UpdateAsync, RemoveAsync (SetAsync's budget).
export type Kind = "get" | "set" | "update" | "remove"

export type Job = {
	key: string,
	kind: Kind,
	-- The request (yields): true when it worked, else false and why.
	run: () -> (boolean, string?),
	-- Filled in by the scheduler.
	attempts: number,
	nextAt: number,
	done: boolean,
	ok: boolean,
	err: string?,
}

export type Env = {
	now: () -> number,
	-- Requests of `kind` the server may make now.
	budget: (kind: Kind) -> number,
	-- Yields for `seconds`.
	wait: (seconds: number) -> (),
	-- Runs `fn` alongside (task.spawn).
	spawn: (fn: () -> ()) -> (),
}

export type Options = {
	cooldown: number?,
	attempts: number?,
	backoff: number?,
	maxBackoff: number?,
	concurrency: number?,
	-- Seconds between looks while nothing can start.
	step: number?,
}

export type Result = { ok: number, failed: { Job }, timedOut: boolean }

export type Scheduler = {
	env: Env,
	cooldown: number,
	attempts: number,
	backoff: number,
	maxBackoff: number,
	concurrency: number,
	step: number,
	-- The last write to each key (Env.now), for the cooldown.
	lastWrite: { [string]: number },
	-- Requests in flight, by kind.
	inFlight: { [string]: number },
	-- Every request started, for the specs' accounting.
	started: number,
}

local SaveScheduler = {}

SaveScheduler.COOLDOWN = 6

function SaveScheduler.new(env: Env, options: Options?): Scheduler
	local o: Options = options or {}
	return {
		env = env,
		cooldown = o.cooldown or SaveScheduler.COOLDOWN,
		attempts = o.attempts or 5,
		backoff = o.backoff or 1,
		maxBackoff = o.maxBackoff or 16,
		concurrency = o.concurrency or 8,
		step = o.step or 0.1,
		lastWrite = {},
		inFlight = { get = 0, set = 0, update = 0, remove = 0 },
		started = 0,
	}
end

-- A job for `key`: `run` does the request.
function SaveScheduler.job(key: string, kind: Kind, run: () -> (boolean, string?)): Job
	return { key = key, kind = kind, run = run, attempts = 0, nextAt = -math.huge, done = false, ok = false, err = nil }
end

local function isWrite(kind: Kind): boolean
	return kind ~= "get"
end

-- Requests of `kind`'s budget in flight (SetAsync and RemoveAsync share one).
local function flying(self: Scheduler, kind: Kind): number
	if kind == "set" or kind == "remove" then
		return self.inFlight.set + self.inFlight.remove
	end
	return self.inFlight[kind]
end

-- Seconds until `job` may start (0: now), as far as the clock and the key's cooldown go.
local function waitFor(self: Scheduler, job: Job, now: number): number
	local until_ = job.nextAt
	if isWrite(job.kind) then
		local last = self.lastWrite[job.key]
		if last then
			until_ = math.max(until_, last + self.cooldown)
		end
	end
	return math.max(0, until_ - now)
end

local function total(self: Scheduler): number
	local n = 0
	for _, count in self.inFlight do
		n += count
	end
	return n
end

--[[
	Runs `jobs` (in order, within the limits: see the header) until each worked or failed for
	good, or `deadline` (Env.now) came. Yields. Returns how many worked, those that failed (and,
	timed out, those never finished: in `failed` too, with err "out of time").
]]
function SaveScheduler.run(self: Scheduler, jobs: { Job }, deadline: number?): Result
	local env = self.env
	local pending = 0
	for _, job in jobs do
		if not job.done then
			pending += 1
		end
	end
	local running = 0
	local timedOut = false
	while pending > 0 do
		local now = env.now()
		if deadline and now >= deadline then
			timedOut = true
			break
		end
		local soonest = math.huge
		local startedOne = false
		if total(self) < self.concurrency then
			for _, job in jobs do
				if not job.done and job.nextAt ~= math.huge then
					local wait = waitFor(self, job, now)
					local budget = env.budget(job.kind) - flying(self, job.kind)
					if wait <= 0 and budget >= 1 then
						-- Start it: nextAt = huge marks it in flight.
						job.nextAt = math.huge
						job.attempts += 1
						self.started += 1
						self.inFlight[job.kind] += 1
						if isWrite(job.kind) then
							self.lastWrite[job.key] = now
						end
						running += 1
						startedOne = true
						env.spawn(function()
							local ok, err = job.run()
							self.inFlight[job.kind] -= 1
							running -= 1
							local after = env.now()
							if ok then
								job.done, job.ok, job.err = true, true, nil
								pending -= 1
							elseif job.attempts >= self.attempts then
								job.done, job.ok, job.err = true, false, err or "failed"
								pending -= 1
							else
								job.err = err
								job.nextAt = after + math.min(self.maxBackoff, self.backoff * 2 ^ (job.attempts - 1))
							end
						end)
						break
					elseif wait > 0 then
						soonest = math.min(soonest, wait)
					else
						-- (Short of budget: look again in a moment.)
						soonest = math.min(soonest, self.step)
					end
				end
			end
		end
		if not startedOne and pending > 0 then
			env.wait(math.clamp(if soonest == math.huge then self.step else soonest, self.step, 1))
		end
	end
	-- (Out of time: what is in flight may still land, but is not counted.)
	local ok = 0
	local failed: { Job } = {}
	for _, job in jobs do
		if job.done and job.ok then
			ok += 1
		elseif not job.done then
			job.err = job.err or "out of time"
			table.insert(failed, job)
		else
			table.insert(failed, job)
		end
	end
	return { ok = ok, failed = failed, timedOut = timedOut }
end

return SaveScheduler
