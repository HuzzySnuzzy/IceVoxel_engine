--!strict
--[[
	Far nodes hidden behind nearer terrain (Shared/World/Horizon), on the streamer's side: when to
	ask a worker for a new verdict, the records it gets, and how long a verdict holds. Pure, tested
	in tests/spec/Horizon.

	  * `records`: every wanted node with a summary goes into the job (Horizon.pack): its own
	    summary once generated (the workers make one with every generation), else an occludee-only
	    estimate (Horizon.estimate) from a generated ancestor still in the tree, or from generated
	    descendants up to two levels down (a node being merged). Nodes with neither are left out:
	    they would hide nothing and never count as hidden.
	  * `due`: a new evaluation once the camera moved `move` blocks from the last one's eye, or
	    `interval` seconds after it while the camera moves or new summaries came in; one job at a
	    time. An evaluation takes a worker 85-180 ms (it yields), so it runs in an Actor.
	  * `received`: the hidden node keys of the latest job (`token`: older or cancelled jobs are
	    ignored, `reset` on teleports), and for each how many verdicts in a row found it hidden
	    (`streak`).
	  * `track` / `speed`: the camera's speed (built nodes only give their parts back below
	    MAX_SPEED).
	  * `holds`: the verdict is safe for skipping builds while the camera stays inside the eyes it
	    was evaluated from (Horizon's raised eye and side eyes: within `spread` blocks sideways,
	    |dx| + |dz|, and at most `raise` blocks higher; a lower eye only sees less over terrain).
	    The streamer always uses the verdict to order loading (LoadPriority's hidden tier); with
	    "Skip hidden terrain" on it also keeps hidden far nodes' boxes without parts (not built
	    when generated hidden, given back once STREAK verdicts in a row found them hidden) until
	    the verdict changes or stops holding.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Coords = require(Shared.World.Coords)
local Horizon = require(Shared.World.Horizon)
local LodTree = require(Shared.World.LodTree)

local MAX_LEVEL = LodTree.MAX_LEVEL

local HiddenTerrain = {}

-- Defaults (blocks / seconds): the eyes' margins (the research's), nodes never hidden this close,
-- compass bins, seconds between evaluations while moving and blocks of movement for a new one.
HiddenTerrain.RAISE = 16
HiddenTerrain.SPREAD = 16
HiddenTerrain.KEEP = 64
HiddenTerrain.BINS = 512
HiddenTerrain.INTERVAL = 1
HiddenTerrain.MOVE = 8
-- Verdicts in a row a built node must be hidden in before its parts go (skip hidden terrain), so
-- a node at the edge of the view does not go and come back with every verdict.
HiddenTerrain.STREAK = 2
-- Built nodes only give their parts back while the camera moved at most this fast (blocks a
-- second, horizontally, over SPEED_WINDOW seconds): a verdict takes a worker most of a second,
-- and faster than this the camera leaves its eyes before the next one comes, which would build
-- everything again (flying at 11 blocks/s: ~18,000 parts a second built and given back).
HiddenTerrain.MAX_SPEED = 6
HiddenTerrain.SPEED_WINDOW = 2

export type Options = {
	raise: number?,
	spread: number?,
	keep: number?,
	bins: number?,
	interval: number?,
	move: number?,
}

export type State = {
	raise: number,
	spread: number,
	keep: number,
	bins: number,
	interval: number,
	move: number,
	-- The job in flight (its token), when and where (eye, blocks) the last one was sent.
	inFlight: number?,
	token: number,
	sentAt: number,
	sentEye: { number }?,
	-- The verdict in use: hidden node keys and the eye it was evaluated from; how many verdicts in
	-- a row found each hidden node hidden.
	hidden: { [number]: boolean },
	count: number,
	eye: { number }?,
	streak: { [number]: number },
	-- Results received, and how long the last one took (seconds, from sending).
	results: number,
	latency: number,
	-- Camera samples for `speed`: time, x, z (oldest first).
	samples: { { number } },

	due: (self: State, now: number, x: number, y: number, z: number, changed: boolean) -> boolean,
	sent: (self: State, now: number, x: number, y: number, z: number) -> number,
	received: (self: State, token: number, hidden: { number }?, now: number) -> boolean,
	holds: (self: State, x: number, y: number, z: number) -> boolean,
	track: (self: State, now: number, x: number, z: number) -> (),
	speed: (self: State) -> number,
	reset: (self: State) -> (),
}

local State = {}
State.__index = State

function HiddenTerrain.new(options: Options?): State
	local o: Options = options or {}
	local self = {
		raise = o.raise or HiddenTerrain.RAISE,
		spread = o.spread or HiddenTerrain.SPREAD,
		keep = o.keep or HiddenTerrain.KEEP,
		bins = o.bins or HiddenTerrain.BINS,
		interval = o.interval or HiddenTerrain.INTERVAL,
		move = o.move or HiddenTerrain.MOVE,
		inFlight = nil,
		token = 0,
		sentAt = -math.huge,
		sentEye = nil,
		hidden = {},
		count = 0,
		eye = nil,
		streak = {},
		results = 0,
		latency = 0,
		samples = {},
	}
	return (setmetatable(self, State) :: any) :: State
end

--[[
	Should a new evaluation be sent now, the camera at (x, y, z) (blocks)? `changed`: new summaries
	arrived or the selection changed since the last one was sent.
]]
function State.due(self: State, now: number, x: number, y: number, z: number, changed: boolean): boolean
	if self.inFlight then
		return false
	end
	local eye = self.sentEye
	if eye == nil then
		return true
	end
	local dx, dy, dz = x - eye[1], y - eye[2], z - eye[3]
	local moved = math.sqrt(dx * dx + dy * dy + dz * dz)
	if moved >= self.move then
		return true
	end
	return now - self.sentAt >= self.interval and (moved >= 0.5 or changed)
end

-- A job was sent from eye (x, y, z): returns its token.
function State.sent(self: State, now: number, x: number, y: number, z: number): number
	self.token += 1
	self.inFlight = self.token
	self.sentAt = now
	self.sentEye = { x, y, z }
	return self.token
end

--[[
	The job `token` answered with the hidden node keys (nil: it failed). Returns whether the
	verdict changed (an older or cancelled job's answer is ignored).
]]
function State.received(self: State, token: number, hidden: { number }?, now: number): boolean
	if token ~= self.inFlight then
		return false
	end
	self.inFlight = nil
	if hidden == nil then
		-- (Failed: the next `due` asks again.)
		self.sentEye = nil
		return false
	end
	local set: { [number]: boolean } = {}
	local streak: { [number]: number } = {}
	local count = 0
	for _, key in hidden do
		set[key] = true
		streak[key] = (self.streak[key] or 0) + 1
		count += 1
	end
	self.hidden = set
	self.streak = streak
	self.count = count
	self.eye = self.sentEye
	self.results += 1
	self.latency = now - self.sentAt
	return true
end

-- Does the verdict hold for a camera at (x, y, z), so hidden nodes may skip building?
function State.holds(self: State, x: number, y: number, z: number): boolean
	local eye = self.eye
	if eye == nil then
		return false
	end
	return math.abs(x - eye[1]) + math.abs(z - eye[3]) <= self.spread and y - eye[2] <= self.raise
end

-- A camera sample (blocks; once a refresh) for `speed`.
function State.track(self: State, now: number, x: number, z: number)
	local samples = self.samples
	table.insert(samples, { now, x, z })
	while #samples > 2 and now - samples[2][1] >= HiddenTerrain.SPEED_WINDOW do
		table.remove(samples, 1)
	end
end

-- The camera's horizontal speed over the last SPEED_WINDOW seconds (blocks a second).
function State.speed(self: State): number
	local samples = self.samples
	local first, last = samples[1], samples[#samples]
	if first == nil or last[1] - first[1] <= 0 then
		return 0
	end
	local dx, dz = last[2] - first[2], last[3] - first[3]
	return math.sqrt(dx * dx + dz * dz) / (last[1] - first[1])
end

-- Teleports: the verdict and any job in flight are dropped.
function State.reset(self: State)
	self.token += 1
	self.inFlight = nil
	self.sentEye = nil
	self.sentAt = -math.huge
	self.hidden = {}
	self.count = 0
	self.eye = nil
	self.streak = {}
	table.clear(self.samples)
end

--[[ Records ]]

local function ancestorKey(level: number, nx: number, nz: number, up: number): number
	local f = bit32.lshift(1, up - level)
	return Coords.nodeKey(up, nx // f, nz // f)
end

-- Generated descendants of node (level, nx, nz) with summaries, up to `depth` levels down.
local function descendants(
	level: number,
	nx: number,
	nz: number,
	depth: number,
	summaryOf: (key: number) -> buffer?,
	out: { Horizon.Source }
)
	if level == 0 or depth == 0 then
		return
	end
	for dz = 0, 1 do
		for dx = 0, 1 do
			local cx, cz = nx * 2 + dx, nz * 2 + dz
			local summary = summaryOf(Coords.nodeKey(level - 1, cx, cz))
			if summary then
				table.insert(out, { level = level - 1, nx = cx, nz = cz, summary = summary })
			else
				descendants(level - 1, cx, cz, depth - 1, summaryOf, out)
			end
		end
	end
end

--[[
	The records of a horizon job for the wanted nodes `desired` (node key -> level): `summaryOf(key)`
	gives a node's summary if it was generated (wanted or not, while it is still in the tree).
	Returns the records (Horizon.pack) and how many.
]]
function HiddenTerrain.records(desired: { [number]: number }, summaryOf: (key: number) -> buffer?): (buffer, number)
	local keys: { number } = {}
	local summaries: { buffer } = {}
	for key, level in desired do
		local summary = summaryOf(key)
		if summary == nil then
			local _, nx, nz = Coords.decodeNodeKey(key)
			local sources: { Horizon.Source } = {}
			for up = level + 1, MAX_LEVEL do
				local ancestor = ancestorKey(level, nx, nz, up)
				local found = summaryOf(ancestor)
				if found then
					local _, ax, az = Coords.decodeNodeKey(ancestor)
					table.insert(sources, { level = up, nx = ax, nz = az, summary = found })
					break
				end
			end
			if #sources == 0 then
				descendants(level, nx, nz, 2, summaryOf, sources)
			end
			if #sources > 0 then
				summary = Horizon.estimate(level, nx, nz, sources)
			end
		end
		if summary then
			table.insert(keys, key)
			table.insert(summaries, summary)
		end
	end
	return Horizon.pack(keys, summaries), #keys
end

return HiddenTerrain
