--!strict
--[[
	Which chunks the server generates around players, in what order, and the job that generates
	them a slice of a frame at a time (Minecraft's chunk loading tickets around players, spread over
	ticks). Pure: no services, no instances; World/Simulation is the glue (positions every 0.5 s,
	Heartbeat, eviction, /genstats), and a spec drives it with a fake world or the real generator.

	  Windows   each player stands in a chunk (pcx, pcz). The chunks within `radius` of it
	            (Chebyshev; Config.Server.SimulationRadius 3: a 7 x 7 window) are near: generated,
	            and where block updates, random ticks and mobs run (`active`). One ring wider
	            (9 x 9) is kept: eviction never drops those, so walking back and forth along a
	            window's edge regenerates nothing.
	  Order     `update` (every scan) rebuilds the queue: every near chunk neither generated nor
	            in flight, closest to its nearest player first (dx² + dz², so a player's own chunk
	            and the 8 around it lead), ties by age (queued in an earlier update first), then by
	            coordinates (a total order: the same input always gives the same order). Chunks
	            that left every window are dropped from it; the job in flight is abandoned when its
	            chunk did (a generator never resumed leaves nothing half done: every cache it fills
	            takes an entry only once complete, as with the client's cancelled worker jobs).
	  Job       one at a time: a coroutine running `generate(cx, cz, yield)` on a generator
	            instance of its own, never the world's. One instance can't run two calls at once
	            (its column scratch would be shared, 14 chunks in 15 came out wrong when tried);
	            two instances can, since no generation module keeps module-level scratch across a
	            yield (180 of 180 chunks identical with the world's generator run at every yield).
	            `yield` suspends it once the step's deadline has passed; `step(budget)` resumes
	            it, installs it when it finishes (World/WorldServer.install: the chunk's edits as
	            they are then, onGenerated once; a chunk made meanwhile by getChunk keeps its own
	            and the late terrain is dropped) and starts the next while time is left.
	  Slices    a step lasts its budget plus the stretch from the deadline to the generator's next
	            yield: on 600 cold chunks p99 3.6 ms and at most ~5 ms, since Generation/Lakes'
	            puddle decisions, SurfaceCaves' worms and the tail of TerrainGenerator.generate
	            yield inside (before: p99 9.2 ms, max 10.7 ms, in one puddle decision).
	  Budget    `budget(limits, spent)`: `normal` ms a frame, `urgent` while a player's own 3 x 3
	            is missing or more than `backlog` chunks wait, within what the frame has left of
	            `frame`, at least `least` (Config.Server: 4, 8, 49, 12, 1).
	  Stats     what the steps did over the last STATS_SECONDS (chunks/s, ms/s, the worst step),
	            the backlog and the totals: `describe`, for /genstats.

	Why one serial job and not an Actor pool (origin-servergen.md, measured in Lune, native code):
	a chunk costs 3.4-3.75 ms along a walk and ~11 ms alone; 8 sprinting players need ~1.3 ms of
	generation a frame, and Roblox gives a small server one Parallel Luau thread. What hurt was
	one whole chunk a frame: 16-45 ms frames whenever one generated, and at most 60 chunks/s, so
	joins, teleports and fast flyers left a backlog. Replayed on the same traces (8 players spread
	out; Lune, native): the worst generating frame 18-21 ms -> ~12 ms (p99 10.6-11.7 -> 8.6-9.0),
	8 joining at once complete in 3.2 s instead of 6.5, 8 sprint-flyers get 99 chunks/s instead of
	60, and a player's own 3 x 3 waits at most ~0.7 s instead of 1.2-2.2 (docs/ARCHITECTURE.md,
	Server chunk generation).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Coords = require(Shared.World.Coords)

local chunkKey = Coords.chunkKey

-- Seconds of steps the stats look back over.
local STATS_SECONDS = 10

export type Options = {
	-- Chunks generated around each player (Chebyshev; one more ring is kept).
	radius: number,
	-- Generates chunk (cx, cz) at full detail on the background generator, calling `yield` now and
	-- then; returns its data and height.
	generate: (cx: number, cz: number, yield: () -> ()) -> (buffer, number),
	-- Puts the chunk into the world (World/WorldServer.install); false: it was there already.
	install: (cx: number, cz: number, data: buffer, height: number) -> boolean,
	-- Is chunk (cx, cz) generated?
	loaded: (cx: number, cz: number) -> boolean,
	-- Seconds (default os.clock).
	clock: (() -> number)?,
	-- Told when a chunk fails to generate (it is not tried again by the queue).
	warn: ((message: string) -> ())?,
}

type Entry = {
	cx: number,
	cz: number,
	key: number,
	-- Squared distance (chunks) to the nearest player.
	d2: number,
	-- The update that first queued it.
	since: number,
}

type Job = {
	cx: number,
	cz: number,
	key: number,
	thread: thread,
	-- Seconds spent in it so far.
	spent: number,
}

-- What a frame may spend (ms; World/Simulation reads them from Config.Server): `normal`, or
-- `urgent` while a player's own 3 x 3 is missing or more than `backlog` chunks wait; never past
-- `frame` with what the frame spent before, but at least `least`.
export type Limits = {
	normal: number,
	urgent: number,
	backlog: number,
	frame: number,
	least: number,
}

export type Stats = {
	-- Over the last STATS_SECONDS (or since the queue started, if sooner).
	chunksPerSecond: number,
	msPerSecond: number,
	worstStepMs: number,
	-- Now.
	backlog: number,
	inFlight: { cx: number, cz: number, ms: number }?,
	-- Since the queue started.
	generated: number,
	dropped: number,
	abandoned: number,
	failed: number,
}

export type Queue = {
	radius: number,
	-- Keys of the near chunks (generated or not), refreshed by `update`.
	active: { number },
	-- Number of updates so far.
	updates: number,
	-- Totals since the queue started.
	generated: number,
	dropped: number,
	abandoned: number,
	failed: number,

	update: (self: Queue, centers: { number }) -> (),
	keeps: (self: Queue, cx: number, cz: number) -> boolean,
	isNear: (self: Queue, cx: number, cz: number) -> boolean,
	urgent: (self: Queue) -> boolean,
	budget: (self: Queue, limits: Limits, spentMs: number) -> number,
	step: (self: Queue, budget: number) -> number,
	backlog: (self: Queue) -> number,
	stats: (self: Queue) -> Stats,
	describe: (self: Queue) -> { string },
}

type State = Queue & {
	options: Options,
	clock: () -> number,
	started: number,
	-- Flat cx, cz of the players' chunks (copied by `update`).
	centers: { number },
	near: { [number]: boolean },
	kept: { [number]: boolean },
	-- Waiting entries, last = next; and by key.
	pending: { Entry },
	queued: { [number]: Entry },
	job: Job?,
	-- Chunks whose generation failed (never queued again).
	broken: { [number]: boolean },
	deadline: number,
	pause: () -> (),
	-- Stats ring, one slot per second: the second it holds, step ms, chunks installed, worst step.
	statSecond: { number },
	statMs: { number },
	statChunks: { number },
	statWorst: { number },
}

local GenQueue = {}
GenQueue.__index = GenQueue
GenQueue.STATS_SECONDS = STATS_SECONDS

function GenQueue.new(options: Options): Queue
	local clock = options.clock or os.clock
	local self = {
		radius = options.radius,
		active = {},
		updates = 0,
		generated = 0,
		dropped = 0,
		abandoned = 0,
		failed = 0,
		options = options,
		clock = clock,
		started = clock(),
		centers = {},
		near = {},
		kept = {},
		pending = {},
		queued = {},
		job = nil,
		broken = {},
		deadline = -math.huge,
		pause = function() end,
		statSecond = table.create(STATS_SECONDS, -1),
		statMs = table.create(STATS_SECONDS, 0),
		statChunks = table.create(STATS_SECONDS, 0),
		statWorst = table.create(STATS_SECONDS, 0),
	}
	-- The generator's yield: suspends the job once the step's time is up.
	self.pause = function()
		if clock() >= self.deadline then
			coroutine.yield()
		end
	end
	return (setmetatable(self, GenQueue) :: any) :: Queue
end

-- Does `a` come after `b` (lower priority)? The pending list is kept in this order, next last.
local function after(a: Entry, b: Entry): boolean
	if a.d2 ~= b.d2 then
		return a.d2 > b.d2
	elseif a.since ~= b.since then
		return a.since > b.since
	elseif a.cz ~= b.cz then
		return a.cz > b.cz
	end
	return a.cx > b.cx
end

--[[
	The players stand in chunks centers[1], centers[2], centers[3], centers[4], ... (flat cx, cz):
	rebuilds the near and kept windows and the queue, and abandons the job in flight if its chunk
	is near nobody any more.
]]
function GenQueue.update(self: State, centers: { number })
	local radius = self.radius
	local loaded = self.options.loaded
	local job = self.job
	self.updates += 1
	local update = self.updates
	table.clear(self.centers)
	table.move(centers, 1, #centers, 1, self.centers)

	local near: { [number]: boolean } = {}
	local kept: { [number]: boolean } = {}
	local active: { number } = {}
	local old = self.queued
	local queued: { [number]: Entry } = {}
	local pending: { Entry } = {}
	for i = 1, #centers - 1, 2 do
		local pcx, pcz = centers[i], centers[i + 1]
		for dz = -radius - 1, radius + 1 do
			for dx = -radius - 1, radius + 1 do
				local cx, cz = pcx + dx, pcz + dz
				local key = chunkKey(cx, cz)
				kept[key] = true
				if math.abs(dx) > radius or math.abs(dz) > radius then
					continue
				end
				if not near[key] then
					near[key] = true
					table.insert(active, key)
				end
				local d2 = dx * dx + dz * dz
				local entry = queued[key]
				if entry then
					if d2 < entry.d2 then
						entry.d2 = d2
					end
				elseif not (job and job.key == key) and not self.broken[key] and not loaded(cx, cz) then
					entry = old[key] or { cx = cx, cz = cz, key = key, d2 = d2, since = update }
					assert(entry)
					entry.d2 = d2
					queued[key] = entry
					table.insert(pending, entry)
				end
			end
		end
	end
	table.sort(pending, after)
	self.near, self.kept, self.active = near, kept, active
	self.queued, self.pending = queued, pending

	if job and not near[job.key] then
		-- (Dropped where it stands: see the header.)
		self.job = nil
		self.abandoned += 1
	end
end

-- Is chunk (cx, cz) within a player's kept window (eviction keeps it)?
function GenQueue.keeps(self: State, cx: number, cz: number): boolean
	return self.kept[chunkKey(cx, cz)] == true
end

-- Is chunk (cx, cz) within a player's near window?
function GenQueue.isNear(self: State, cx: number, cz: number): boolean
	return self.near[chunkKey(cx, cz)] == true
end

-- Is a player's own chunk, or one of the 8 around it, not generated yet (just joined or
-- teleported)? Simulation gives the steps a bigger budget then.
function GenQueue.urgent(self: State): boolean
	local loaded = self.options.loaded
	local centers = self.centers
	for i = 1, #centers - 1, 2 do
		local pcx, pcz = centers[i], centers[i + 1]
		for dz = -1, 1 do
			for dx = -1, 1 do
				if not loaded(pcx + dx, pcz + dz) then
					return true
				end
			end
		end
	end
	return false
end

-- This frame's budget in ms (see Limits), the frame having spent `spentMs` so far.
function GenQueue.budget(self: State, limits: Limits, spentMs: number): number
	local want = if #self.pending > limits.backlog or GenQueue.urgent(self) then limits.urgent else limits.normal
	return math.max(math.min(want, limits.frame - spentMs), limits.least)
end

-- The next chunk to generate (skipping those generated meanwhile), off the queue; nil: none.
local function pop(self: State): Entry?
	local pending = self.pending
	local loaded = self.options.loaded
	for i = #pending, 1, -1 do
		local entry = pending[i]
		pending[i] = nil
		self.queued[entry.key] = nil
		if not loaded(entry.cx, entry.cz) then
			return entry
		end
	end
	return nil
end

-- Adds a step that lasted `ms` and installed `chunks` to the stats ring.
local function record(self: State, now: number, ms: number, chunks: number)
	local second = math.floor(now)
	local i = second % STATS_SECONDS + 1
	if self.statSecond[i] ~= second then
		self.statSecond[i] = second
		self.statMs[i], self.statChunks[i], self.statWorst[i] = 0, 0, 0
	end
	self.statMs[i] += ms
	self.statChunks[i] += chunks
	if ms > self.statWorst[i] then
		self.statWorst[i] = ms
	end
end

--[[
	Generates for about `budget` seconds: resumes the job in flight, installs it when it finishes,
	then starts the next, until the time is up or nothing is left (it overshoots by the stretch to
	the generator's next yield). Returns the number of chunks it installed.
]]
function GenQueue.step(self: State, budget: number): number
	local clock = self.clock
	local start = clock()
	self.deadline = start + budget
	local installed = 0
	local worked = false
	while true do
		local job = self.job
		if job == nil then
			local entry = pop(self)
			if entry == nil then
				break
			end
			local cx, cz = entry.cx, entry.cz
			local generate, pause = self.options.generate, self.pause
			job = {
				cx = cx,
				cz = cz,
				key = entry.key,
				thread = coroutine.create(function(): (buffer, number)
					return generate(cx, cz, pause)
				end),
				spent = 0,
			}
			self.job = job
		end
		assert(job)
		worked = true
		local resumed = clock()
		local ok, data, height = coroutine.resume(job.thread)
		job.spent += clock() - resumed
		if not ok then
			self.job = nil
			self.failed += 1
			self.broken[job.key] = true
			local warn = self.options.warn
			if warn then
				warn(`chunk ({job.cx}, {job.cz}) failed to generate: {data}`)
			end
		elseif coroutine.status(job.thread) == "dead" then
			self.job = nil
			if self.options.install(job.cx, job.cz, data :: any, height :: any) then
				self.generated += 1
				installed += 1
			else
				self.dropped += 1
			end
		end
		if clock() >= self.deadline then
			break
		end
	end
	if worked then
		local now = clock()
		record(self, now, (now - start) * 1000, installed)
	end
	return installed
end

-- Chunks waiting (not counting the one in flight).
function GenQueue.backlog(self: State): number
	return #self.pending
end

function GenQueue.stats(self: State): Stats
	local now = self.clock()
	local second = math.floor(now)
	local ms, chunks, worst = 0, 0, 0
	for i = 1, STATS_SECONDS do
		local s = self.statSecond[i]
		if s > second - STATS_SECONDS and s <= second then
			ms += self.statMs[i]
			chunks += self.statChunks[i]
			worst = math.max(worst, self.statWorst[i])
		end
	end
	-- (The window is the last STATS_SECONDS whole seconds and this one so far.)
	local span = math.clamp(now - math.max(self.started, second - STATS_SECONDS + 1), 1e-3, STATS_SECONDS)
	local job = self.job
	return {
		chunksPerSecond = chunks / span,
		msPerSecond = ms / span,
		worstStepMs = worst,
		backlog = #self.pending,
		inFlight = if job then { cx = job.cx, cz = job.cz, ms = job.spent * 1000 } else nil,
		generated = self.generated,
		dropped = self.dropped,
		abandoned = self.abandoned,
		failed = self.failed,
	}
end

-- The stats as chat lines (/genstats).
function GenQueue.describe(self: State): { string }
	local s = GenQueue.stats(self)
	local lines = {
		string.format(
			"Background generation, last %d s: %.1f chunks/s, %.1f ms/s (%.1f%% of the time), worst frame %.1f ms",
			STATS_SECONDS,
			s.chunksPerSecond,
			s.msPerSecond,
			s.msPerSecond / 10,
			s.worstStepMs
		),
	}
	local flight = s.inFlight
	table.insert(
		lines,
		if flight
			then string.format(
				"Backlog: %d chunks, generating chunk (%d, %d) for %.1f ms so far",
				s.backlog,
				flight.cx,
				flight.cz,
				flight.ms
			)
			else string.format("Backlog: %d chunks", s.backlog)
	)
	table.insert(
		lines,
		string.format(
			"Since the start: %d generated, %d dropped (made meanwhile), %d abandoned (players left), %d failed",
			s.generated,
			s.dropped,
			s.abandoned,
			s.failed
		)
	)
	return lines
end

return GenQueue
