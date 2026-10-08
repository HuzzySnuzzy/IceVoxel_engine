--!strict
--[[
	Frame-time models for the renderer. Pure Luau, tested in tests/spec/RenderPipeline.

	Adaptive build budget (`FrameBudget.new`, ChunkRenderer with Render.AutoBudget): how many
	milliseconds a frame may spend building parts.
	  * `usual` is the shortest frame of the last WINDOW frames: what this device achieves right
	    now (with vsync, the refresh interval; on a device already below it, its own pace).
	  * A frame longer than Threshold x `usual` (it missed vsync, or took 10% longer) cuts the
	    budget by Lower, down to Min, and remembers the budget that overran: for CALM frames the
	    budget only recovers to 90% of it, so one overrun does not turn into a missed frame every
	    few frames.
	  * While builds are waiting and frames have room, it grows by Raise ms per frame, up to Max
	    (after the calm period it probes above the remembered budget again).
	  * With nothing waiting it drifts back to the base (Render.BuildBudgetMs).
	  * While the player is frozen waiting for terrain nothing is playable, so it may grow up to
	    FrozenMax and only shrinks when frames get FrozenThreshold x longer than usual.
	A fixed budget (`auto` false) is just the base.

	Measured on a frame model (perf/build/R/measure_budget.luau: 600 ms of part building after a
	teleport, vsync at 60 Hz): a fast device (8 ms of other work) loads in 1.4 s instead of 2.5 s,
	a device with ~4 ms to spare misses fewer frames than with the fixed 4 ms, a device already at
	30 fps loads twice as fast at the same frame rate.

	Motion (`FrameBudget.motion`): the camera's average speed over a time window, from one
	position a frame (path length over elapsed time). MeshOverlay builds no far mesh while it is
	high: regions keep changing while the camera moves (perf/research_settings 6.1).
]]

export type Options = {
	Min: number,
	Max: number,
	FrozenMax: number,
	Threshold: number,
	FrozenThreshold: number,
	Raise: number,
	Lower: number,
}

export type Budget = {
	options: Options,
	-- Milliseconds: typical frame (see the header), a short average of recent frames (for
	-- display), and the current budget.
	usual: number,
	recent: number,
	budget: number,
	-- The last WINDOW frame times (ring), and where the next goes.
	frames: { number },
	slot: number,
	-- The budget that last overran, and frames left before probing above it again.
	ceiling: number,
	calm: number,

	update: (self: Budget, frameMs: number, pending: boolean, frozen: boolean, base: number, auto: boolean) -> number,
}

export type Motion = {
	window: number,
	times: { number },
	-- Path length (studs) up to each sample, and where the last sample was.
	lengths: { number },
	head: number,
	x: number,
	y: number,
	z: number,
	total: number,

	update: (self: Motion, x: number, y: number, z: number, now: number) -> number,
	speed: (self: Motion) -> number,
}

local FrameBudget = {}

FrameBudget.DEFAULTS = table.freeze({
	Min = 2,
	Max = 8,
	FrozenMax = 12,
	Threshold = 1.1,
	FrozenThreshold = 2,
	Raise = 0.25,
	Lower = 0.8,
})

-- Frames `usual` looks back over, frames after an overrun before probing above it, and how much
-- of the budget that overran it recovers to meanwhile.
local WINDOW = 90
local CALM = 120
local RECOVER = 0.9
-- Timer noise (ms) never counts as a long frame.
local SLOP = 0.5
-- Weight of the newest frame in `recent`.
local RECENT = 0.25
-- Back towards the base per frame with nothing to build.
local SETTLE = 0.1
-- Frame times beyond this (ms) are hitches (loading, a stalled frame): ignored.
local HITCH_MS = 250

local Budget = {}
Budget.__index = Budget

function FrameBudget.new(options: Options?, base: number?): Budget
	local start = base or 4
	local self = {
		options = options or FrameBudget.DEFAULTS,
		usual = 1000 / 60,
		recent = 1000 / 60,
		budget = start,
		frames = {},
		slot = 1,
		ceiling = math.huge,
		calm = 0,
	}
	return (setmetatable(self, Budget) :: any) :: Budget
end

-- Feeds one frame's length (ms); returns the budget for the next frame (ms).
function Budget.update(
	self: Budget,
	frameMs: number,
	pending: boolean,
	frozen: boolean,
	base: number,
	auto: boolean
): number
	if frameMs <= 0 or frameMs >= HITCH_MS then
		return self.budget
	end
	local frames = self.frames
	frames[self.slot] = frameMs
	self.slot = self.slot % WINDOW + 1
	local usual = math.huge
	for _, ms in frames do
		if ms < usual then
			usual = ms
		end
	end
	self.usual = usual
	self.recent += (frameMs - self.recent) * RECENT
	if not auto then
		self.budget = base
		return base
	end
	local o = self.options
	local limit = if frozen then o.FrozenMax else o.Max
	local threshold = usual * (if frozen then o.FrozenThreshold else o.Threshold) + SLOP
	local budget = self.budget
	if frameMs > threshold then
		self.ceiling = budget
		self.calm = CALM
		budget *= o.Lower
	elseif pending then
		local cap = limit
		if self.calm > 0 then
			self.calm -= 1
			cap = math.min(limit, math.max(o.Min, self.ceiling * RECOVER))
		end
		if budget < cap then
			budget = math.min(cap, budget + o.Raise)
		end
	else
		budget += (math.clamp(base, o.Min, o.Max) - budget) * SETTLE
	end
	budget = math.clamp(budget, o.Min, limit)
	self.budget = budget
	return budget
end

local Motion = {}
Motion.__index = Motion

--[[
	Average camera speed over the last `window` seconds (studs per second). Positions are world
	studs (doubles: MeshOverlay adds the render origin, Shared/World/Origin), so a move of the
	floating origin is no jump.
]]
function FrameBudget.motion(window: number): Motion
	local self = {
		window = window,
		times = {},
		lengths = {},
		head = 1,
		x = 0,
		y = 0,
		z = 0,
		total = 0,
	}
	return (setmetatable(self, Motion) :: any) :: Motion
end

-- Adds the position at `now` (seconds); returns the average speed over the window.
function Motion.update(self: Motion, x: number, y: number, z: number, now: number): number
	local times, lengths = self.times, self.lengths
	if #times >= self.head then
		local dx, dy, dz = x - self.x, y - self.y, z - self.z
		self.total += math.sqrt(dx * dx + dy * dy + dz * dz)
	end
	self.x, self.y, self.z = x, y, z
	table.insert(times, now)
	table.insert(lengths, self.total)
	-- Drop samples older than the window, keeping one at or before its start.
	local head = self.head
	while head < #times and times[head + 1] <= now - self.window do
		head += 1
	end
	-- Compact now and then (head indices instead of table.remove(list, 1)).
	if head > 64 and head > #times // 2 then
		table.move(times, head, #times, 1)
		table.move(lengths, head, #lengths, 1)
		local keep = #times - head + 1
		for i = #times, keep + 1, -1 do
			times[i] = nil
			lengths[i] = nil
		end
		head = 1
	end
	self.head = head
	return self:speed()
end

function Motion.speed(self: Motion): number
	local times = self.times
	local last = #times
	local head = self.head
	if last <= head then
		return 0
	end
	local elapsed = times[last] - times[head]
	if elapsed <= 0 then
		return 0
	end
	-- Over less than a full window (just started) the average still counts the whole window, so
	-- a single jump does not read as an enormous speed for one frame and nothing after it.
	return (self.lengths[last] - self.lengths[head]) / math.max(elapsed, self.window * 0.5)
end

return FrameBudget
