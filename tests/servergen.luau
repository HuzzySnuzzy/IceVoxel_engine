--[[
	The server's preloading around players, before and after World/GenQueue, on the real Default
	generator (seed 12345), at 60 Hz simulated frames (the work in a frame is real, the rest of the
	frame is not slept).

	    lune run tests/servergen <scenario> [old|new|both]

	Scenarios: walk1, join1, join8, sprint8, fly8, sprintfly8 (players spread 6-18k blocks apart,
	moving diagonally at Minecraft's walking, sprinting, flying and sprint-flying speeds; join:
	standing still from t = 0).

	  before  the old World/Simulation: every 0.5 s a scan queues the missing chunks of every
	          player's 7 x 7 window (closest first); each frame generates ONE whole chunk inline
	          (world:getChunk on the world's generator)
	  after   World/GenQueue on a second generator, GenQueue.budget with Config.Server (4 ms a
	          frame, 8 while a player's 3 x 3 is missing or more than 49 chunks wait), installs
	          through world:install, scans every 0.5 s

	Per scenario: frames that generated and their ms (mean, p99, max), frames over 10 and 16.7 ms
	(share of all frames), chunks/s, backlog (missing near chunks at each scan: mean, max, at the
	end), how long a player's own 3 x 3 stayed incomplete (max), and for joins the time until
	every window was complete. Timings move with the machine's load: run it on a quiet one.
]]

local process = require("@lune/process")
local Loader = require("./lib/Loader")

local env = Loader.new()
local shared = env.mount("src/shared", "ReplicatedStorage", "IceVoxel")
local server = env.mount("src/server", "ServerScriptService", "IceVoxel")
local require = env.require
local WorldTypes = require(shared.Generation.WorldTypes)
local Coords = require(shared.World.Coords)
local WorldServer = require(server.World.WorldServer)
local GenQueue = require(server.World.GenQueue)

local SEED = 12345
local RADIUS = 3
local FPS = 60
local SCAN = 0.5
local CACHE = 192
local Config = require(shared.Config)
local LIMITS = {
	normal = Config.Server.GenerationBudgetMs,
	urgent = Config.Server.UrgentGenerationBudgetMs,
	backlog = Config.Server.UrgentBacklog,
	frame = Config.Server.FrameBudgetMs,
	least = Config.Server.MinGenerationBudgetMs,
}

local scenarios = {
	walk1 = { players = 1, speed = 4.317, seconds = 30 },
	sprint8 = { players = 8, speed = 5.612, seconds = 20 },
	fly8 = { players = 8, speed = 10.89, seconds = 15 },
	sprintfly8 = { players = 8, speed = 21.78, seconds = 12 },
	join8 = { players = 8, speed = 0, seconds = 8 },
	join1 = { players = 1, speed = 0, seconds = 3 },
}

local name = process.args[1] or "walk1"
local which = process.args[2] or "both"
-- (The rest of the frame does nothing here: the budget is GenQueue.budget with 0 ms spent.)
local sc = scenarios[name]
assert(sc, `unknown scenario {name}`)

local players = {}
for i = 1, sc.players do
	local angle = (i - 1) / sc.players * math.pi * 2 + 0.3
	local dist = if i == 1 then 0 else 6000
	local x0 = 512 + math.cos(angle) * dist * (1 + i % 3)
	local z0 = -128 + math.sin(angle) * dist * (1 + i % 3)
	local dir = angle + math.pi / 4
	table.insert(players, { x0 = x0, z0 = z0, dx = math.cos(dir), dz = math.sin(dir) })
end

local function positions(t: number): { number }
	local centers = {}
	for _, p in players do
		local x, z = p.x0 + p.dx * sc.speed * t, p.z0 + p.dz * sc.speed * t
		table.insert(centers, math.floor(x / 16))
		table.insert(centers, math.floor(z / 16))
	end
	return centers
end

local function pct(list: { number }, p: number): number
	if #list == 0 then
		return 0
	end
	local s = table.clone(list)
	table.sort(s)
	return s[math.clamp(math.ceil(#s * p), 1, #s)]
end
local function mean(list: { number }): number
	local s = 0
	for _, v in list do
		s += v
	end
	return if #list > 0 then s / #list else 0
end

local function run(kind: string)
	local world = WorldServer.new(WorldTypes.create("default", SEED, {}))
	local frames = sc.seconds * FPS
	local genMs: { number } = {}
	local over8, over16 = 0, 0
	local chunks = 0
	local backlogs: { number } = {}
	local ownSince: { number? } = {}
	local ownWorst = 0
	local allDone: number? = nil

	local function missingNear(centers: { number }): (number, { boolean })
		local seen = {}
		local missing = 0
		for i = 1, #centers, 2 do
			for dz = -RADIUS, RADIUS do
				for dx = -RADIUS, RADIUS do
					local key = Coords.chunkKey(centers[i] + dx, centers[i + 1] + dz)
					if not seen[key] then
						seen[key] = true
						if world.chunks[key] == nil then
							missing += 1
						end
					end
				end
			end
		end
		local own = {}
		for i = 1, #centers, 2 do
			local complete = true
			for dz = -1, 1 do
				for dx = -1, 1 do
					if world.chunks[Coords.chunkKey(centers[i] + dx, centers[i + 1] + dz)] == nil then
						complete = false
					end
				end
			end
			own[(i + 1) // 2] = complete
		end
		return missing, own
	end

	-- before
	local queue: { { number } } = {}
	local wanted: { [number]: boolean } = {}
	local function oldScan(centers: { number })
		wanted = {}
		queue = {}
		for i = 1, #centers, 2 do
			local pcx, pcz = centers[i], centers[i + 1]
			for dz = -RADIUS - 1, RADIUS + 1 do
				for dx = -RADIUS - 1, RADIUS + 1 do
					local cx, cz = pcx + dx, pcz + dz
					wanted[Coords.chunkKey(cx, cz)] = true
					if math.abs(dx) <= RADIUS and math.abs(dz) <= RADIUS and not world:peekChunk(cx, cz) then
						table.insert(queue, { cx, cz, dx * dx + dz * dz })
					end
				end
			end
		end
		table.sort(queue, function(a, b)
			return a[3] > b[3]
		end)
		world:evict(function(cx, cz)
			return wanted[Coords.chunkKey(cx, cz)] == true
		end, CACHE)
	end

	-- after
	local background = WorldTypes.create("default", SEED, {})
	local q = GenQueue.new({
		radius = RADIUS,
		generate = function(cx: number, cz: number, yield: () -> ()): (buffer, number)
			local r = background.generate(0, cx, cz, yield)
			return r.data, r.height
		end,
		install = function(cx: number, cz: number, data: buffer, height: number): boolean
			local _, fresh = world:install(cx, cz, data, height)
			return fresh
		end,
		loaded = function(cx: number, cz: number): boolean
			return world:peekChunk(cx, cz) ~= nil
		end,
	})

	local elapsed = SCAN
	for f = 0, frames - 1 do
		local t = f / FPS
		local centers = positions(t)
		elapsed += 1 / FPS
		if elapsed >= SCAN then
			elapsed = 0
			if kind == "old" then
				oldScan(centers)
			else
				q:update(centers)
				world:evict(function(cx, cz)
					return q:keeps(cx, cz)
				end, CACHE)
			end
			local missing = missingNear(centers)
			table.insert(backlogs, missing)
		end
		local start = os.clock()
		local did = false
		if kind == "old" then
			local entry = table.remove(queue)
			if entry then
				if world:peekChunk(entry[1], entry[2]) == nil then
					chunks += 1
					did = true
				end
				world:getChunk(entry[1], entry[2])
			end
		else
			local budget = q:budget(LIMITS, 0) / 1000
			local before = q.generated
			if q:backlog() > 0 or q:stats().inFlight then
				did = true
			end
			q:step(budget)
			chunks += q.generated - before
		end
		local ms = (os.clock() - start) * 1000
		if did then
			table.insert(genMs, ms)
			if ms > 10 then
				over8 += 1
			end
			if ms > 1000 / 60 then
				over16 += 1
			end
		end
		local missing, own = missingNear(centers)
		for i, complete in own do
			if complete then
				local since = ownSince[i]
				if since then
					ownWorst = math.max(ownWorst, t - since)
					ownSince[i] = nil
				end
			elseif ownSince[i] == nil then
				ownSince[i] = t
			end
		end
		if allDone == nil and missing == 0 and f > 0 then
			allDone = t
		end
	end
	local t = sc.seconds
	for _, since in ownSince do
		if since then
			ownWorst = math.max(ownWorst, t - since)
		end
	end
	local missingEnd = missingNear(positions(t - 1 / FPS))
	print(
		string.format(
			"%-6s %-10s frames generating %4d/%d: mean %5.2f p50 %5.2f p99 %5.2f max %5.2f ms; >10 ms %4.1f%%, >16.7 ms %4.1f%% of frames; %5.1f chunks/s; backlog mean %5.1f max %3d end %3d; own 3x3 incomplete max %.2f s%s",
			kind,
			name,
			#genMs,
			frames,
			mean(genMs),
			pct(genMs, 0.5),
			pct(genMs, 0.99),
			pct(genMs, 1),
			over8 / frames * 100,
			over16 / frames * 100,
			chunks / sc.seconds,
			mean(backlogs),
			pct(backlogs, 1),
			missingEnd,
			ownWorst,
			if allDone then string.format("; all windows complete at %.2f s", allDone) else ""
		)
	)
end

if which == "old" or which == "both" then
	run("old")
end
if which == "new" or which == "both" then
	run("new")
end
