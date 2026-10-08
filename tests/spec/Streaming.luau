--[[
	The streamer (client Streaming/): LoadPriority, RemeshQueue, SwapUnits and TeleportMode as pure
	modules, LodTree's seams, ClientWorld's job edits, and the real ChunkStreamer and ClientWorld in a
	simulation with a fake worker pool, a fake renderer (ChunkRenderer's API: lanes, commit groups,
	show / clear / trash) and a fake network that answers edit list requests.

	Every simulated frame checks what the player would see: no two shown nodes overlap (an
	ancestor and a descendant), and no ground that was covered stops being covered (no gap), while
	walking, through LOD swaps budgeted in swap units, failures and settings changes; and that
	edits on a chunk border go live in one frame through the edit lanes, failed jobs come back, late
	generation results are patched instead of generated again, the view loads before what is behind,
	and a teleport drops the old area at once, cancels its jobs and unfreezes quickly. The fake pool
	returns real SectionGraphs and horizon verdicts, so the cave view (no revealed section on screen
	ever opens onto one that does not draw its caves) and hidden terrain (held nodes, giving parts
	back and building them again, the setting switched mid-session) run in the same simulation. It
	can also run on the real generator: walking down a real cave entrance reveals the cave beyond
	within frames, and under the open sky of a pit or a ravine full detail keeps its range (the
	underground split only once shut in).

	The floating origin (Shared/World/Origin): the simulation's camera is placed in render studs, so
	with the origin moved far away the streamer selects, loads and swaps exactly as at the world's
	0; the viewer comes from the hull hook (`viewerFeet`), else the world spawn attribute (world
	studs), else the camera read back into world blocks.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame

return function(t, shared, require, _server, client)
	local Config = require(shared.Config)
	local Coords = require(shared.World.Coords)
	local LodTree = require(shared.World.LodTree)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Blocks = require(shared.Blocks)
	local Protocol = require(shared.Net.Protocol)
	local PlayerSettings = require(shared.PlayerSettings)
	local SectionGraph = require(shared.World.SectionGraph)
	local Horizon = require(shared.World.Horizon)
	local Caves = require(shared.Generation.Caves)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)
	local Origin = require(shared.World.Origin)
	local LoadPriority = require(client.Streaming.LoadPriority)
	local RemeshQueue = require(client.Streaming.RemeshQueue)
	local SwapUnits = require(client.Streaming.SwapUnits)
	local TeleportMode = require(client.Streaming.TeleportMode)
	local CaveReach = require(client.Streaming.CaveReach)
	local RenderSchedule = require(client.Rendering.RenderSchedule)

	local SIZE = Config.ChunkSize
	local SECTION = Config.SectionHeight
	local P = ChunkLayout.PADDED
	local MAX_LEVEL = LodTree.MAX_LEVEL
	local STONE = Blocks.id.Stone

	-- Deterministic pseudo random numbers.
	local function rng(seed: number): (n: number) -> number
		local state = seed
		return function(n: number): number
			state = (state * 1103515245 + 12345) % 2147483648
			return (state // 65536) % n
		end
	end

	--[[ LoadPriority ]]

	t.test("load priority: ring under the player, view, near behind, then the rest", function()
		local score = LoadPriority.score
		t.eq(score(10, false, true), 10, "the ring under the player ignores view and occlusion")
		t.eq(score(300, true, false), 300, "in view")
		t.eq(score(100, false, false), 200, "near behind")
		t.eq(score(300, false, false), 300 + LoadPriority.OUT_OF_VIEW, "far behind")
		t.eq(score(300, true, true), 300 + LoadPriority.OCCLUDED, "hidden in view")
		t.eq(score(300, false, true), 300 + LoadPriority.OUT_OF_VIEW + LoadPriority.OCCLUDED)
		t.ok(score(1000, true, false) < score(130, false, false), "anything in view before far behind")
		t.ok(score(1000, true, false) > score(100, false, false), "the near ring behind before far views")
	end)

	t.test("load priority: the view wedge", function()
		-- Looking along +X with a 70 degree, 16:9 camera: half the wedge ~66 degrees.
		local view = LoadPriority.view(0, 0, 1, 0, 70, 16 / 9)
		t.near(math.deg(view.half), math.deg(LoadPriority.horizontalFov(70, 16 / 9)) / 2 + 15, 1e-6)
		local function sees(x0: number, z0: number, size: number): boolean
			return LoadPriority.inView(view, x0, z0, size)
		end
		t.ok(sees(100, -8, 16), "straight ahead")
		t.ok(not sees(-116, -8, 16), "straight behind")
		t.ok(sees(-8, -8, 16), "the viewer's own node")
		t.ok(sees(-17, -1, 16), "within the margin around the viewer")
		t.ok(not sees(-21, -1, 16), "a node just behind is not")
		t.ok(not sees(-200, 100, 16), "behind to the side")
		-- 60 degrees to the side is inside, 75 degrees outside; a big node straddling the edge is in.
		t.ok(sees(math.cos(math.rad(60)) * 200 - 1, math.sin(math.rad(60)) * 200 - 1, 2))
		t.ok(not sees(math.cos(math.rad(75)) * 200 - 1, math.sin(math.rad(75)) * 200 - 1, 2))
		t.ok(sees(0, 150, 300), "a node spanning the edge")
		-- Looking along -X: the wedge wraps round +-180 degrees.
		local back = LoadPriority.view(0, 0, -1, 0, 70, 16 / 9)
		t.ok(LoadPriority.inView(back, -100, -8, 16) and LoadPriority.inView(back, -100, 10, 16))
		t.ok(not LoadPriority.inView(back, 100, -8, 16))
		-- Looking straight down: every direction.
		t.ok(LoadPriority.inView(LoadPriority.view(0, 0, 0, 0, 70, 1), -100, -100, 16))
	end)

	t.test("load priority: replacement groups share their best score; sorted queues", function()
		local a, b, c, d = { priority = 5 }, { priority = 300 }, { priority = 1e5 + 40 }, { priority = 7 }
		LoadPriority.share({ g1 = { a, b, c }, g2 = { d } })
		t.eq(a.priority, 5)
		t.eq(b.priority, 5)
		t.eq(c.priority, 5)
		t.eq(d.priority, 7)
		local queue = {}
		local rand = rng(3)
		local function priority(x)
			return x.priority
		end
		for i = 1, 200 do
			LoadPriority.insert(queue, { priority = rand(50), i = i }, priority)
		end
		for i = 2, #queue do
			t.ok(queue[i - 1].priority >= queue[i].priority, "most urgent last")
		end
		LoadPriority.sort(queue, priority)
		t.eq(#queue, 200)
	end)

	--[[ RemeshQueue ]]

	-- Commit groups as ChunkRenderer keeps them: holds, and when the last one closed.
	local function fakeGroups()
		local log = { opened = 0, completed = 0, held = 0 }
		local groups = {
			open = function()
				log.opened += 1
				return { holds = 1, id = log.opened }
			end,
			hold = function(group)
				assert(group.holds > 0, "hold on a completed group")
				group.holds += 1
				log.held += 1
			end,
			close = function(group)
				group.holds -= 1
				assert(group.holds >= 0, "a group closed more often than held")
				if group.holds == 0 then
					log.completed += 1
				end
			end,
		}
		return groups, log
	end

	t.test("remesh queue: one batch of edits on two chunks is one commit group", function()
		local groups, log = fakeGroups()
		local q = RemeshQueue.new(groups)
		local a, b = { name = "a" }, { name = "b" }
		q:mark(a, 3, RemeshQueue.EDIT)
		q:mark(a, 4, RemeshQueue.EDIT)
		q:mark(b, 3, RemeshQueue.EDIT)
		q:mark(b, 9, RemeshQueue.REVEAL)
		local jobs = {}
		local n = q:dispatch(function(job)
			table.insert(jobs, job)
			return true
		end, function()
			return true
		end, function()
			return 0
		end, 0, 0)
		t.eq(n, 2, "two edit jobs, no near job (cap 0)")
		t.ok(jobs[1].edit and jobs[2].edit)
		t.ok(jobs[1].group ~= nil and jobs[1].group == jobs[2].group, "same group")
		t.eq(#jobs[1].sections + #jobs[2].sections, 3, "only edited sections")
		local group = jobs[1].group
		t.eq(group.holds, 2, "the batch's own hold was released once every member was sent")
		q:done(jobs[1], false)
		t.eq(log.completed, 0)
		q:done(jobs[2], false)
		t.eq(log.completed, 1, "complete when both jobs queued their builds")
		t.ok(q:isDirty(b, 9), "the reveal section waits for a near job")
		t.ok(q:current(a, 3, jobs[1].token) and q:current(b, 3, jobs[2].token))
	end)

	t.test("remesh queue: a batch waits for members the pool had no room for", function()
		local groups, log = fakeGroups()
		local q = RemeshQueue.new(groups)
		local a, b = {}, {}
		q:mark(a, 0, RemeshQueue.EDIT)
		q:mark(b, 0, RemeshQueue.EDIT)
		local room = 1
		local jobs = {}
		local function submit(job)
			if room == 0 then
				return false
			end
			room -= 1
			table.insert(jobs, job)
			return true
		end
		local function yes()
			return true
		end
		local function zero()
			return 0
		end
		q:dispatch(submit, yes, zero, 0, 0)
		t.eq(#jobs, 1)
		local group = jobs[1].group
		t.eq(group.holds, 2, "own hold kept: a member still waits")
		-- (Only a job sent holds it: ChunkStreamer opens the renderer's group with the first.)
		t.eq(log.held, 1, "the member the pool had no room for did not hold it")
		q:done(jobs[1], false)
		t.eq(log.completed, 0, "not complete while a member waits")
		-- A new edit in the meantime joins the same batch.
		local c = {}
		q:mark(c, 1, RemeshQueue.EDIT)
		room = 5
		q:dispatch(submit, yes, zero, 0, 0)
		t.eq(#jobs, 3)
		t.ok(jobs[2].group == group and jobs[3].group == group, "the late members share the group")
		q:done(jobs[2], false)
		q:done(jobs[3], false)
		t.eq(log.completed, 1)
		t.eq(log.opened, 1)
	end)

	t.test("remesh queue: failures mark again and wait; newer jobs win; not ready leaves the batch", function()
		local groups, log = fakeGroups()
		local q = RemeshQueue.new(groups)
		local a, b = {}, {}
		local ready = { [a] = true, [b] = false }
		local jobs = {}
		local function submit(job)
			table.insert(jobs, job)
			return true
		end
		local function isReady(node)
			return ready[node]
		end
		local function zero()
			return 0
		end
		q:mark(a, 2, RemeshQueue.EDIT)
		q:mark(b, 2, RemeshQueue.EDIT)
		q:dispatch(submit, isReady, zero, 0, 0)
		t.eq(#jobs, 1, "b is not ready")
		t.eq(jobs[1].group.holds, 1, "b left the batch, whose own hold went: only a's job holds it")
		-- A newer edit job for the same section supersedes the first.
		q:mark(a, 2, RemeshQueue.EDIT)
		q:dispatch(submit, isReady, zero, 0, 0)
		t.eq(#jobs, 2)
		t.ok(not q:current(a, 2, jobs[1].token) and q:current(a, 2, jobs[2].token))
		-- The newer one fails: its section is dirty again, and a waits FAIL_DELAY.
		q:done(jobs[1], false)
		q:done(jobs[2], true, 10)
		t.ok(q:isDirty(a, 2), "marked again")
		q:dispatch(submit, isReady, zero, 0, 10.1)
		t.eq(#jobs, 2, "waiting after the failure")
		q:dispatch(submit, isReady, zero, 0, 10 + RemeshQueue.FAIL_DELAY + 0.01)
		t.eq(#jobs, 3, "sent again")
		q:done(jobs[3], false)
		-- The older failed job never marks a section a newer job took.
		ready[b] = true
		q:dispatch(submit, isReady, zero, 0, 20)
		t.eq(#jobs, 4)
		q:mark(b, 2, RemeshQueue.EDIT)
		q:dispatch(submit, isReady, zero, 0, 20)
		q:done(jobs[4], true, 20)
		t.ok(not q:isDirty(b, 2), "superseded: not marked again")
		q:done(jobs[5], false)
		t.eq(log.completed, log.opened, "every group completed")
	end)

	t.test("remesh queue: near jobs by reason then distance, one per node, capped", function()
		local groups = fakeGroups()
		local q = RemeshQueue.new(groups)
		local nodes = {}
		for i = 1, 6 do
			nodes[i] = { d = 100 - i * 10 }
		end
		q:mark(nodes[1], 0, RemeshQueue.PLANTS)
		q:mark(nodes[2], 0, RemeshQueue.SEAM)
		q:mark(nodes[3], 0, RemeshQueue.REVEAL)
		q:mark(nodes[4], 0, RemeshQueue.REVEAL)
		q:mark(nodes[5], 0, RemeshQueue.SEAM)
		q:mark(nodes[6], 0, RemeshQueue.PLANTS)
		local order = {}
		local function submit(job)
			table.insert(order, job.node)
			return true
		end
		local function yes()
			return true
		end
		local function distance(node)
			return node.d
		end
		q:dispatch(submit, yes, distance, 3, 0)
		t.eq(#order, 3, "capped")
		t.ok(order[1] == nodes[4] and order[2] == nodes[3], "reveal first, nearest first")
		t.ok(order[3] == nodes[5], "then seams by distance")
		-- More dirt on a node with a job in flight waits for that job.
		q:mark(nodes[4], 1, RemeshQueue.REVEAL)
		q:dispatch(submit, yes, distance, 10, 0)
		t.eq(#order, 6)
		for _, node in order do
			t.ok(node ~= nodes[4] or order[1] == node, "one near job per node")
		end
	end)

	t.test("remesh queue: small reveal passes are commit groups, big ones are not", function()
		local groups, log = fakeGroups()
		local q = RemeshQueue.new(groups)
		local a, b = {}, {}
		q:beginPass()
		q:mark(a, 1, RemeshQueue.REVEAL)
		q:mark(b, 1, RemeshQueue.REVEAL)
		t.eq(q:endPass(10), 2)
		local jobs = {}
		local function submit(job)
			table.insert(jobs, job)
			return true
		end
		local function yes()
			return true
		end
		local function zero()
			return 0
		end
		q:dispatch(submit, yes, zero, 10, 0)
		t.ok(jobs[1].group ~= nil and jobs[1].group == jobs[2].group, "one group")
		q:done(jobs[1], false)
		q:done(jobs[2], false)
		t.eq(log.completed, 1)
		q:beginPass()
		for s = 0, 20 do
			q:mark(a, s, RemeshQueue.REVEAL)
		end
		q:endPass(10)
		q:dispatch(submit, yes, zero, 10, 0)
		t.eq(jobs[3].group, nil, "too big for a group")
	end)

	t.test("remesh queue: hiding passes are one batch whatever their size; batches being sent pass the cap", function()
		local groups = fakeGroups()
		local q = RemeshQueue.new(groups)
		local nodes = {}
		for i = 1, 5 do
			nodes[i] = { i = i }
		end
		q:beginPass()
		for _, node in nodes do
			for s = 0, 29 do
				q:mark(node, s, RemeshQueue.REVEAL)
			end
		end
		-- 150 sections: the 60 of the two hiding nodes are one batch; the other 90 fit the limit
		-- on their own: another.
		t.eq(q:endPass(96, { [nodes[1]] = true, [nodes[2]] = true }), 150)
		local hide = q:groupOf(nodes[1], 3)
		t.ok(hide ~= nil and q:groupOf(nodes[2], 29) == hide, "the hiding nodes share a group")
		local rest = q:groupOf(nodes[3], 0)
		t.ok(rest ~= nil and rest ~= hide and q:groupOf(nodes[5], 7) == rest, "the rest (90 sections) another")
		t.eq(q:groupOf(nodes[1], 30), nil, "a section that is not dirty has none")
		q:beginPass()
		local other = {}
		for s = 0, 99 do
			q:mark(other, s, RemeshQueue.REVEAL)
		end
		q:endPass(96)
		t.eq(q:groupOf(other, 0), nil, "a big pass with nothing hidden is no batch")
		-- With distances: batches of at most the limit, nearest first.
		local q2 = RemeshQueue.new(fakeGroups())
		local far = {}
		for i = 1, 6 do
			far[i] = { i = i }
		end
		q2:beginPass()
		for _, node in far do
			for s = 0, 39 do
				q2:mark(node, s, RemeshQueue.REVEAL)
			end
		end
		q2:endPass(96, nil, function(node)
			return -node.i
		end)
		t.ok(q2:groupOf(far[6], 0) ~= nil and q2:groupOf(far[6], 0) == q2:groupOf(far[5], 0), "nearest two")
		t.ok(q2:groupOf(far[4], 0) ~= q2:groupOf(far[5], 0), "then the next batch")
		t.ok(q2:groupOf(far[1], 0) ~= nil and q2:groupOf(far[1], 0) == q2:groupOf(far[2], 0))
		-- Cap 1: the nearest goes; its batch's other member follows past the cap; the rest waits.
		local jobs = {}
		q:dispatch(function(job)
			table.insert(jobs, job)
			return true
		end, function()
			return true
		end, function(node)
			return node.i or 99
		end, 1, 0)
		t.eq(#jobs, 2, "the batch being sent passes the cap")
		t.ok(jobs[1].node == nodes[1] and jobs[2].node == nodes[2] and jobs[2].group == hide)
		t.eq(q.nearInFlight, 2)
	end)

	t.test("remesh queue: a node removed with jobs in flight closes its holds", function()
		local groups, log = fakeGroups()
		local q = RemeshQueue.new(groups)
		local a, b = {}, {}
		q:mark(a, 0, RemeshQueue.EDIT)
		q:mark(b, 0, RemeshQueue.EDIT)
		local jobs = {}
		q:dispatch(function(job)
			table.insert(jobs, job)
			return true
		end, function()
			return true
		end, function()
			return 0
		end, 0, 0)
		q:forget(a)
		q:done(jobs[1], true)
		q:done(jobs[2], false)
		t.eq(log.completed, 1)
		t.ok(not q:isDirty(a, 0))
	end)

	t.test("remesh queue: random marks, failures and removals leave no group open", function()
		for seed = 1, 60 do
			local rand = rng(seed)
			local groups, log = fakeGroups()
			local q = RemeshQueue.new(groups)
			local nodes = {}
			for i = 1, 6 do
				nodes[i] = { i = i, ready = rand(4) > 0 }
			end
			local live: { [any]: boolean } = {}
			for _, node in nodes do
				live[node] = true
			end
			local inFlight = {}
			local near = 0
			local room = 3
			local now = 0
			local function submit(job)
				assert(live[job.node], "a job for a removed node")
				if #inFlight >= room then
					return false
				end
				-- (Past the cap only for a member of a batch being sent.)
				assert(job.edit or near < 2 or job.group ~= nil, "near jobs capped")
				table.insert(inFlight, job)
				if not job.edit then
					near += 1
				end
				return true
			end
			local function ready(node)
				return node.ready
			end
			local function distance(node)
				return node.i
			end
			for _ = 1, 300 do
				now += 1 / 60
				local roll = rand(10)
				local node = nodes[1 + rand(#nodes)]
				if roll < 4 and live[node] then
					if roll == 0 then
						q:beginPass()
						q:mark(node, rand(8), RemeshQueue.REVEAL)
						local other = nodes[1 + rand(#nodes)]
						if live[other] then
							q:mark(other, rand(8), RemeshQueue.REVEAL)
						end
						q:endPass(3)
					else
						q:mark(node, rand(8), 1 + rand(4))
					end
				elseif roll == 4 then
					node.ready = not node.ready
				elseif roll == 5 and live[node] and rand(6) == 0 then
					live[node] = false
					q:forget(node)
				end
				q:dispatch(submit, ready, distance, 2, now)
				t.ok(q.nearInFlight == near, "near jobs counted")
				-- Finish some jobs, some failing.
				while #inFlight > 0 and rand(3) > 0 do
					local job = table.remove(inFlight, 1 + rand(#inFlight))
					if not job.edit then
						near -= 1
					end
					q:done(job, rand(5) == 0, now)
				end
			end
			-- Drain: everything ready, no more marks.
			for _, node in nodes do
				node.ready = true
			end
			for _ = 1, 400 do
				now += 1 / 60
				q:dispatch(submit, ready, distance, 2, now)
				for _, job in inFlight do
					if not job.edit then
						near -= 1
					end
					q:done(job, false, now)
				end
				table.clear(inFlight)
			end
			t.eq(q:pending(), 0, `seed {seed}: nothing left dirty`)
			t.eq(q.nearInFlight, 0)
			t.eq(log.completed, log.opened, `seed {seed}: every group completed`)
		end
	end)

	--[[ SwapUnits ]]

	local function entry(level: number, nx: number, nz: number, leaving: boolean, cost: number, priority: number)
		return {
			node = `{level},{nx},{nz}`,
			level = level,
			nx = nx,
			nz = nz,
			leaving = leaving,
			cost = cost,
			priority = priority,
		}
	end

	t.test("swap units: a replaced node and its replacements go together", function()
		local units = SwapUnits.build({
			-- A level 2 node split into its four level 1 children (one of them further split).
			entry(2, 0, 0, true, 100, 50),
			entry(1, 0, 0, false, 30, 40),
			entry(1, 1, 0, false, 30, 41),
			entry(1, 0, 1, false, 30, 42),
			entry(0, 2, 2, false, 10, 43),
			-- Elsewhere: four fine nodes merged into a coarse one.
			entry(0, 40, 40, true, 5, 9),
			entry(0, 41, 40, true, 5, 9),
			entry(1, 20, 20, false, 12, 8),
			-- A node beyond the view, nothing replaces it.
			entry(3, -9, -9, true, 70, 900),
			-- A fresh node.
			entry(0, -40, 8, false, 9, 20),
		})
		t.eq(#units, 4)
		t.eq(#units[1].members, 3, "the merge first (priority 8)")
		t.eq(units[1].cost, 22)
		t.eq(#units[2].members, 1, "the fresh node")
		t.eq(#units[3].members, 5, "the split, its grandchild included")
		t.eq(units[3].cost, 200)
		t.eq(units[4].priority, 900)
		t.eq(#SwapUnits.take(units, 31), 2, "within the allowance")
		t.eq(#SwapUnits.take(units, 30), 1, "the next unit would not fit")
		t.eq(#SwapUnits.take(units, 10), 1, "at least one")
		t.eq(#SwapUnits.take(units, math.huge), 4)
		t.eq(#SwapUnits.take({}, 10), 0)
		-- Teleport mode: units that only show nodes are free, the rest stays in order.
		local taken = SwapUnits.take(units, 10, SwapUnits.fresh)
		t.eq(#taken, 2)
		t.ok(taken[1] == units[1] and taken[2] == units[2], "the first, then the fresh one")
		t.ok(SwapUnits.fresh(units[2]) and not SwapUnits.fresh(units[1]))
	end)

	t.test("swap units: negative coordinates", function()
		local units = SwapUnits.build({ entry(3, -1, -1, true, 1, 1), entry(0, -3, -5, false, 1, 2) })
		t.eq(#units, 1, "(-3, -5) at level 0 lies in (-1, -1) at level 3")
	end)

	--[[ TeleportMode ]]

	t.test("teleport mode: jumps, the order the old area leaves, when it ends", function()
		t.ok(TeleportMode.isJump(0, 0, 100, 100, 128) and not TeleportMode.isJump(0, 0, 80, 80, 128))
		local plan = TeleportMode.plan({
			{ level = 0, nx = 1000, nz = 0 },
			{ level = 0, nx = 2, nz = 0 },
			{ level = 3, nx = 0, nz = 0 },
		}, 40, 8, 64)
		t.eq(plan[1].distance, 0, "the node the destination lies in")
		t.ok(plan[1].immediate and plan[2].immediate and not plan[3].immediate)
		t.ok(plan[2].node.nx == 2 and plan[3].node.nx == 1000, "nearest first")
		local mode = TeleportMode.new(10, 4)
		t.ok(not mode:update(0, true, 0), "inactive")
		mode:enter(5)
		t.ok(not mode:update(6, false, 0), "the ground is not there yet")
		t.ok(not mode:update(6, true, 9), "too much left")
		t.ok(mode:update(6, true, 4) and not mode.active, "settled")
		mode:enter(20)
		t.ok(mode:update(30.5, false, 100), "timed out")
	end)

	--[[ LodTree seams ]]

	t.test("lod tree: seams only change next to coarse nodes that changed", function()
		LodTree.configure(1024, 2, 2, 3)
		local ok, err = pcall(function()
			local rand = rng(11)
			local x, z = 100.5, -300.5
			local desired = LodTree.select(x, z)
			local versions = LodTree.version()
			for _ = 1, 120 do
				x += rand(200) - 100
				z += rand(200) - 100
				local nextSet = LodTree.select(x, z, desired)
				local changed = {}
				for key, level in nextSet do
					if desired[key] == nil then
						changed[key] = level
					end
				end
				for key, level in desired do
					if nextSet[key] == nil then
						changed[key] = level
					end
				end
				local affected = LodTree.seamsAffected(changed, nextSet)
				for key, level in nextSet do
					if level == 0 and desired[key] ~= nil and not affected[key] then
						local _, nx, nz = Coords.decodeNodeKey(key)
						local before = LodTree.coarserSides(desired, 0, nx, nz)
						local after = LodTree.coarserSides(nextSet, 0, nx, nz)
						for i = 1, 4 do
							t.eq(after[i], before[i], "an unaffected chunk's seams did not change")
						end
					end
				end
				desired = nextSet
			end
			t.eq(LodTree.version(), versions, "selecting does not change the version")
			LodTree.setFoliageDistance(LodTree.foliageDistance() + 1)
			t.eq(LodTree.version(), versions + 1)
			t.eq(LodTree.coarserSides({}, 0, 0, 0), LodTree.NO_COARSER)
		end)
		LodTree.configure(
			Config.Lod.ViewDistance,
			Config.Lod.SplitDistance,
			Config.Lod.SplitDistanceL1,
			Config.Lod.UndergroundSplitDistanceL1
		)
		LodTree.setFoliageDistance(Config.Lod.FoliageDistance)
		if not ok then
			error(err, 0)
		end
	end)

	--[[ Loading client modules with fakes ]]

	local GLOBALS = "script, require, game, workspace, Vector3, Vector2, CFrame, os, warn"
	local function withHeader(source: string): string
		local lines = string.split(source, "\n")
		local i = 1
		while lines[i] and string.sub(lines[i], 1, 3) == "--!" do
			i += 1
		end
		lines[i] = `local {GLOBALS} = ...; ` .. (lines[i] or "")
		return table.concat(lines, "\n")
	end
	local sources: { [string]: string } = {}

	--[[
		A fresh copy of the client modules: `fakes` replaces modules by path; `env` provides game,
		workspace and os. Shared modules come from the runner's require.
	]]
	local function loader(env: any, fakes: { [string]: any }): (any) -> any
		local cache: { [any]: any } = {}
		local function req(node: any): any
			local path = rawget(node, "__path")
			if type(path) ~= "string" or string.sub(path, 1, 10) ~= "src/client" then
				return require(node)
			end
			if fakes[path] ~= nil then
				return fakes[path]
			end
			local cached = cache[node]
			if cached ~= nil then
				return cached
			end
			local source = sources[path]
			if source == nil then
				source = withHeader(fs.readFile(path))
				sources[path] = source
			end
			local chunk = luau.load(source, { debugName = path })
			local result = chunk(node, req, env.game, env.workspace, Vector3, roblox.Vector2, CFrame, env.os, env.warn)
			cache[node] = result
			return result
		end
		return req
	end

	-- The game services and camera the streamer reads.
	local function newEnv(): any
		-- `clockStep`: seconds os.clock advances per call within a frame (time budgets).
		local env: any = { time = 0, warnings = {}, clockStep = 0, extra = 0 }
		env.camera = {
			CFrame = CFrame.new(),
			ViewportSize = roblox.Vector2.new(1600, 900),
			FieldOfView = 70,
		}
		env.workspace = { CurrentCamera = env.camera }
		env.os = {
			clock = function(): number
				env.extra += env.clockStep
				return env.time + env.extra
			end,
			time = os.time,
		}
		env.warn = function(...)
			table.insert(env.warnings, table.concat({ ... }, " "))
		end
		local services: { [string]: any } = {
			ReplicatedStorage = shared.Parent,
			Players = { LocalPlayer = { Character = nil } },
			Lighting = {
				FogEnd = 1e5,
				FogStart = 0,
				FindFirstChildOfClass = function()
					return nil
				end,
			},
			UserInputService = { TouchEnabled = false, KeyboardEnabled = true },
		}
		env.game = {
			GetService = function(_, name: string)
				return services[name] or error(`no fake service {name}`)
			end,
		}
		return env
	end

	-- ClientNet: edit list requests answered (empty lists, or `serverEdits`) a few frames later.
	local function fakeNet(sim: any): any
		local handlers: { [number]: (buffer) -> () } = {}
		sim.replies = {}
		return {
			on = function(kind: number, handler: (buffer) -> ())
				handlers[kind] = handler
			end,
			send = function(kind: number, payload: buffer)
				if kind == Protocol.ClientMessage.RequestChunks then
					local lists = {}
					for _, c in Protocol.decodeChunkRequest(payload) or {} do
						local key = Coords.chunkKey(c[1], c[2])
						table.insert(lists, { cx = c[1], cz = c[2], edits = table.clone(sim.serverEdits[key] or {}) })
					end
					table.insert(sim.replies, { at = sim.frame + 2, payload = Protocol.encodeChunkEdits(lists) })
				end
			end,
			handlers = handlers,
		}
	end

	--[[ ClientWorld: job edits ]]

	-- The edit pairs a generation job of chunk (cx, cz) needs, the way ClientWorld always made them.
	local function referenceEdits(edits: any, cx: number, cz: number): { [number]: number }
		local out = {}
		local function add(list, filter)
			if type(list) ~= "table" then
				return
			end
			for index, block in list do
				local lx, y, lz = ChunkLayout.fromLocalIndex(index)
				local px, pz = filter(lx, lz)
				if px and pz then
					out[(y * P + pz) * P + px] = block
				end
			end
		end
		add(edits[Coords.chunkKey(cx, cz)], function(lx, lz)
			return lx + 1, lz + 1
		end)
		add(edits[Coords.chunkKey(cx - 1, cz)], function(lx, lz)
			return if lx == SIZE - 1 then 0 else nil, lz + 1
		end)
		add(edits[Coords.chunkKey(cx + 1, cz)], function(lx, lz)
			return if lx == 0 then P - 1 else nil, lz + 1
		end)
		add(edits[Coords.chunkKey(cx, cz - 1)], function(lx, lz)
			return lx + 1, if lz == SIZE - 1 then 0 else nil
		end)
		add(edits[Coords.chunkKey(cx, cz + 1)], function(lx, lz)
			return lx + 1, if lz == 0 then P - 1 else nil
		end)
		return out
	end

	t.test("client world: job edits from cached border columns match reading every list", function()
		local env = newEnv()
		local sim = { frame = 0, serverEdits = {} }
		local net = fakeNet(sim)
		local req = loader(env, { ["src/client/Net/ClientNet.luau"] = net })
		local ClientWorld = req(client.World.ClientWorld)
		local world = ClientWorld.new()
		local rand = rng(5)
		-- Known lists for a 4 x 4 block of chunks, many edits on borders.
		for cx = 0, 3 do
			for cz = 0, 3 do
				local list = {}
				for _ = 1, 60 do
					local lx = if rand(2) == 0 then rand(2) * (SIZE - 1) else rand(SIZE)
					local lz = if rand(2) == 0 then rand(2) * (SIZE - 1) else rand(SIZE)
					list[ChunkLayout.localIndex(lx, rand(40), lz)] = 1 + rand(5)
				end
				world.edits[Coords.chunkKey(cx, cz)] = list
			end
		end
		local function check(label: string)
			for cx = 1, 2 do
				for cz = 1, 2 do
					local got = world:collectJobEdits(cx, cz)
					local want = referenceEdits(world.edits, cx, cz)
					local n = 0
					for i = 1, #got, 2 do
						t.eq(want[got[i]], got[i + 1], `{label}: pair in the reference`)
						n += 1
					end
					local m = 0
					for _ in want do
						m += 1
					end
					t.eq(n, m, `{label}: as many pairs`)
				end
			end
		end
		check("first")
		-- Edits after the borders were cached (server edits update known lists).
		for _ = 1, 40 do
			local x = rand(4 * SIZE)
			local z = rand(4 * SIZE)
			world:applyEdit(x, rand(40), z, 1 + rand(5))
		end
		world:applyEdit(SIZE - 1, 3, 5, STONE)
		world:applyEdit(2 * SIZE, 3, 2 * SIZE + 4, STONE)
		check("after edits")
	end)

	t.test("client world: applyJobEdits grows the chunk and keeps its bounds", function()
		local env = newEnv()
		local sim = { frame = 0, serverEdits = {} }
		local req = loader(env, { ["src/client/Net/ClientNet.luau"] = fakeNet(sim) })
		local ClientWorld = req(client.World.ClientWorld)
		local chunk = { data = ChunkLayout.create(16), height = 16, solidBelow = 0, emptyAbove = 4 }
		local high = (40 * P + 3) * P + 3
		local low = (2 * P + 5) * P + 5
		ClientWorld.applyJobEdits(chunk, { high, STONE, low, Blocks.AIR })
		t.ok(chunk.height >= 41, "grown for the block at y 40")
		t.eq(chunk.emptyAbove, 41)
		t.eq(buffer.readu16(chunk.data, high * 2), STONE)
		t.eq(chunk.solidBelow, 0, "air keeps solidBelow at the lowest open cell")
	end)

	--[[ The streamer, simulated ]]

	--[[
		ChunkRenderer's API on the real RenderSchedule, so builds go live in ChunkRenderer's order:
		a section's meshes go live oldest first (one uncommitted task per section: a newer one
		waits for it, or replaces one not started yet, taking over its callbacks, theirs first; a
		newer one of the same commit group drops it), commit groups go live together once every
		hold closed and every task is built, and a group open longer than GROUP_TIMEOUT seconds
		stops waiting. Each lane builds its most urgent task first, `buildFrames` frames from the
		frame it started in. `shown` is what is on screen, `live` the section meshes on screen per
		node (what the last build to go live had), `built` the builds queued per node.
	]]
	-- ChunkRenderer's GROUP_TIMEOUT (seconds).
	local GROUP_TIMEOUT = 2
	local LANES = {
		edit = RenderSchedule.EDIT,
		near = RenderSchedule.NEAR,
		normal = RenderSchedule.NORMAL,
		background = RenderSchedule.BACKGROUND,
	}
	local function fakeRenderer(sim: any): any
		local schedule = RenderSchedule.new(function(task: any): boolean
			return task.data.started
		end)
		local r: any = {
			frame = 0,
			schedule = schedule,
			-- Tasks whose group completed outside a step (they go live at the next).
			ready = {},
			shown = {},
			commits = {},
			trashed = {},
			cleared = {},
			frozen = false,
			partsPerNode = 100,
			buildFrames = 1,
			live = {},
			built = {},
		}
		r.overlay = {
			paused = false,
			busy = false,
			pause = function(self)
				self.paused = true
			end,
			resume = function(self)
				self.paused = false
			end,
			setStreamerBusy = function(self, busy)
				self.busy = busy
			end,
		}
		local function now(): number
			return sim.frame / 60
		end
		local function commit(task)
			schedule:committed(task)
			local node = task.node
			if node.removed then
				return
			end
			table.insert(r.commits, {
				frame = r.frame,
				node = node,
				section = task.section,
				lane = task.data.lane,
				group = task.group,
			})
			local live = r.live[node]
			if live == nil then
				live = {}
				r.live[node] = live
			end
			live[task.section] = if buffer.len(task.data.boxes) > 0 then task.data.boxes else nil
			for _, callback in task.data.callbacks do
				callback()
			end
		end
		local function commitAll(tasks)
			for _, task in tasks or {} do
				commit(task)
			end
		end
		function r.build(self, node, section, boxes, options)
			assert(type(options) == "table", "builds use BuildOptions")
			assert(not node.removed, "built for a removed node")
			local lane = options.lane or "normal"
			assert(LANES[lane] ~= nil, "known lane")
			-- (Only a group that timed out goes live before the jobs holding it added their tasks.)
			local group = options.group
			assert(group == nil or not group.done or group.forced, "a task added to a group that went live")
			r.built[node] = (r.built[node] or 0) + 1
			local task = {
				node = node,
				section = section,
				lane = LANES[lane],
				priority = options.priority,
				group = group,
				state = 0,
				seq = 0,
				data = {
					boxes = boxes,
					lane = lane,
					callbacks = { options.onDone },
					started = false,
					due = nil,
				},
			}
			local replaced = schedule:add(task)
			if replaced then
				local callbacks = {}
				for _, old in replaced do
					table.move(old.data.callbacks, 1, #old.data.callbacks, #callbacks + 1, callbacks)
				end
				table.move(task.data.callbacks, 1, #task.data.callbacks, #callbacks + 1, callbacks)
				task.data.callbacks = callbacks
			end
		end
		function r.openGroup(self)
			return schedule:openGroup(now())
		end
		function r.holdGroup(self, group)
			schedule:hold(group)
		end
		function r.closeGroup(self, group)
			assert(group.holds > 0, "group closed more often than held")
			for _, task in schedule:close(group) or {} do
				table.insert(r.ready, task)
			end
		end
		local function drop(node)
			local _, live = schedule:drop(node)
			for _, task in live do
				table.insert(r.ready, task)
			end
		end
		function r.show(self, node)
			assert(not node.removed, "showing a removed node")
			assert(not r.shown[node], "shown twice")
			r.shown[node] = true
		end
		function r.clear(self, node)
			assert(node.removed, "cleared before being marked removed")
			r.shown[node] = nil
			r.live[node] = nil
			table.insert(r.cleared, node)
			drop(node)
		end
		function r.trashNode(self, node, distance, immediate)
			assert(node.removed, "trashed before being marked removed")
			r.shown[node] = nil
			r.live[node] = nil
			table.insert(r.trashed, { node = node, distance = distance, immediate = immediate })
			drop(node)
		end
		function r.partsOf(self, node)
			return r.partsPerNode
		end
		function r.trashParts(self)
			return 0
		end
		function r.reprioritise(self)
			schedule:reprioritise()
		end
		function r.setFrozen(self, frozen)
			r.frozen = frozen
		end
		function r.wantsQuads(self)
			return false
		end
		function r.setQuads(self) end
		function r.step(self, dt)
			r.frame += 1
			-- Groups that completed outside a step, and those that waited too long.
			local ready = r.ready
			r.ready = {}
			commitAll(ready)
			commitAll(schedule:expire(now(), GROUP_TIMEOUT))
			-- Each lane's next task starts (it is done `buildFrames` frames after the frame it
			-- started in) and goes on to the next once built, most urgent first.
			for lane = RenderSchedule.EDIT, RenderSchedule.BACKGROUND do
				while true do
					local task = schedule:peek(lane)
					if task == nil then
						break
					end
					local data = task.data
					if not data.started then
						data.started = true
						data.due = r.frame - 1 + r.buildFrames
					end
					if data.due > r.frame then
						break
					end
					schedule:pop(lane)
					commitAll(schedule:stage(task))
				end
			end
		end
		function r.pending(self)
			return schedule:count()
		end
		function r.busy(self)
			return r:pending() > 0 or #r.ready > 0
		end
		return r
	end

	-- A fake mesh: one box whose first bytes say what the job was told (revealed, cave caps).
	local function fakeBox(revealed: boolean, caps: number): buffer
		local box = buffer.create(14)
		buffer.writeu8(box, 0, if revealed then 1 else 0)
		buffer.writeu8(box, 1, caps)
		return box
	end

	-- { section, mask, ... } -> { [section] = mask }; a list as a set.
	local function capMapOf(list: { number }?): { [number]: number }
		local map = {}
		for i = 1, #(list or {}), 2 do
			map[(list :: { number })[i]] = (list :: { number })[i + 1]
		end
		return map
	end
	local function setOfList(list: { number }?): { [number]: boolean }
		local set = {}
		for _, v in list or {} do
			set[v] = true
		end
		return set
	end

	--[[
		The cave world's full detail chunks (sim.cave): CAVE_HEIGHT cells of stone, a cave tunnel
		along X at z 8 (chunk row 0), y 20..21 (section 1), and a cave in chunk (0, 1) at z 24
		behind rock. All of it is below the generated surface (buried). `cavern` (sim.cavern): also
		cave air at y 18..40 under every chunk, so entering it changes more sections than one
		commit group holds (Streaming.RevealGroupSections).
	]]
	local CAVE_HEIGHT = 48
	local function caveData(cx: number, cz: number, cavern: boolean?): buffer
		local data = ChunkLayout.create(CAVE_HEIGHT)
		local LAYER = ChunkLayout.LAYER
		for i = 0, CAVE_HEIGHT * LAYER - 1 do
			buffer.writeu16(data, i * 2, STONE)
		end
		for pz = 0, P - 1 do
			for px = 0, P - 1 do
				local x, z = cx * SIZE + px - 1, cz * SIZE + pz - 1
				local tunnel = z == 8
				local side = z == 24 and x >= 4 and x <= 12
				if tunnel or side then
					for y = 20, 21 do
						buffer.writeu16(data, ((y * P + pz) * P + px) * 2, Blocks.CAVE_AIR)
					end
				end
				if cavern then
					for y = 18, 40 do
						buffer.writeu16(data, ((y * P + pz) * P + px) * 2, Blocks.CAVE_AIR)
					end
				end
			end
		end
		return data
	end

	--[[
		A real full detail chunk (sim.real: a TerrainGenerator), as ChunkWorker answers its
		generation job: the generated blocks with the job's edits, and the cave graph built the
		worker's way (the lattice hint, the sections holding air carved below the surface read cell
		by cell, the surface as the sky line); every section's mesh is a fakeBox.
	]]
	local function realChunk(gen: any, job: any, reveal: { [number]: boolean }, caps: { [number]: number }): any
		local r = gen.generate(0, job.nx, job.nz, nil, true)
		local data, height = r.data, r.height
		local solidBelow, emptyAbove = r.solidBelow, r.emptyAbove
		local exact: { [number]: boolean } = {}
		local edits = job.edits or {}
		for i = 1, #edits, 2 do
			local index, block = edits[i], edits[i + 1]
			local y = index // ChunkLayout.LAYER
			if y < height then
				buffer.writeu16(data, index * 2, block)
				exact[y // SECTION] = true
				if buffer.readu8(Blocks.cullLutHiddenCaves, block) == 0 then
					solidBelow = math.min(solidBelow, y)
				end
			end
		end
		if r.structureSpan then
			for s = r.structureSpan[1] // SECTION, r.structureSpan[2] // SECTION do
				exact[s] = true
			end
		end
		SectionGraph.dugSections(data, height, r.surface, solidBelow, exact)
		local extra = {}
		for s in exact do
			table.insert(extra, s)
		end
		local caveSections = SectionGraph.carvedSections(r.carved, Caves.CELL_Y, extra)
		local graph = SectionGraph.build(data, height, r.solidBelow, caveSections, {
			carved = r.carved,
			cellXZ = Caves.CELL_XZ,
			cellY = Caves.CELL_Y,
			originX = job.nx * SIZE,
			originZ = job.nz * SIZE,
			surface = r.surface,
			exact = exact,
		})
		local sections, meshes = {}, {}
		for s = 0, math.ceil(height / SECTION) - 1 do
			table.insert(sections, s)
			table.insert(meshes, fakeBox(reveal[s] == true, caps[s] or 0))
		end
		return {
			id = job.id,
			data = data,
			height = height,
			solidBelow = solidBelow,
			emptyAbove = emptyAbove,
			sections = sections,
			meshes = meshes,
			plants = {},
			summary = r.summary,
			graph = graph,
			bury = r.solidBelow,
			caveSections = caveSections,
		}
	end

	--[[
		WorkerPool's API: results `latency(job)` frames after submitting, `fail(job)` makes a job
		fail, `horizon(job)` the hidden node keys a horizon job answers. Level 0 data is one section
		of air with a stone floor (in a cave sim: caveData, with a real SectionGraph). Every
		generation result has a summary; meshes say what their job was told (fakeBox).
	]]
	local function fakePool(sim: any): any
		local pool: any = { nextId = 0, inFlight = {}, submitted = {}, cancelled = {}, capacity = 12 }
		pool.latency = function(_job)
			return 2
		end
		pool.fail = function(_job)
			return false
		end
		pool.horizon = function(_job): { number }
			return {}
		end
		local function count()
			local n = 0
			for _ in pool.inFlight do
				n += 1
			end
			return n
		end
		function pool.hasCapacity(self, edit)
			return count() < pool.capacity + (if edit then 4 else 0)
		end
		function pool.submit(self, job, callback)
			if not pool:hasCapacity(job.edit == true) then
				return false
			end
			pool.nextId += 1
			job.id = pool.nextId
			-- (Actor messages copy buffers.)
			local copy = table.clone(job)
			for _, field in { "data", "graph" } do
				if type(job[field]) == "buffer" then
					copy[field] = buffer.create(buffer.len(job[field]))
					buffer.copy(copy[field], 0, job[field])
				end
			end
			pool.inFlight[job.id] = { job = copy, callback = callback, at = sim.frame + pool.latency(copy) }
			table.insert(pool.submitted, copy)
			return true
		end
		function pool.cancel(self, ids)
			local n = 0
			for _, id in ids do
				if pool.inFlight[id] then
					pool.inFlight[id] = nil
					table.insert(pool.cancelled, id)
					n += 1
				end
			end
			return n
		end
		function pool.busy(self)
			return count()
		end
		local function result(job)
			if pool.fail(job) then
				return { id = job.id, failed = true, sections = {}, meshes = {} }
			end
			if job.kind == "horizon" then
				return { id = job.id, hidden = pool.horizon(job) }
			end
			local box = buffer.create(14)
			local reveal, caps = setOfList(job.reveal), capMapOf(job.caps)
			if job.kind == "mesh" then
				local meshes = {}
				for i, s in job.sections do
					meshes[i] = fakeBox(reveal[s] == true, caps[s] or 0)
				end
				local graph = job.graph
				if type(graph) == "buffer" then
					SectionGraph.refresh(graph, job.data, job.height, job.graphSections or job.sections)
				end
				return { id = job.id, sections = job.sections, meshes = meshes, plants = {}, graph = graph }
			end
			local summary = buffer.create(Horizon.SUMMARY_BYTES)
			if job.level == 0 and sim.real then
				return realChunk(sim.real, job, reveal, caps)
			end
			if job.level == 0 and sim.cave then
				local data = caveData(job.nx, job.nz, sim.cavern)
				for i = 1, #(job.edits or {}), 2 do
					local index = job.edits[i]
					if index < ChunkLayout.LAYER * CAVE_HEIGHT then
						buffer.writeu16(data, index * 2, job.edits[i + 1])
					end
				end
				local sections, meshes = { 0, 1, 2 }, {}
				for i, s in sections do
					meshes[i] = fakeBox(reveal[s] == true, caps[s] or 0)
				end
				return {
					id = job.id,
					data = data,
					height = CAVE_HEIGHT,
					solidBelow = 0,
					emptyAbove = CAVE_HEIGHT,
					sections = sections,
					meshes = meshes,
					plants = {},
					summary = summary,
					graph = SectionGraph.build(data, CAVE_HEIGHT, CAVE_HEIGHT, sections),
					bury = CAVE_HEIGHT,
					caveSections = sections,
				}
			end
			if job.level == 0 then
				local data = buffer.create(ChunkLayout.LAYER * 16 * 2)
				for x = 0, P - 1 do
					for z = 0, P - 1 do
						buffer.writeu16(data, (z * P + x) * 2, STONE)
					end
				end
				for i = 1, #(job.edits or {}), 2 do
					local index = job.edits[i]
					if index < ChunkLayout.LAYER * 16 then
						buffer.writeu16(data, index * 2, job.edits[i + 1])
					end
				end
				return {
					id = job.id,
					data = data,
					height = 16,
					solidBelow = 0,
					emptyAbove = 1,
					sections = { 0 },
					meshes = { box },
					plants = {},
					summary = summary,
				}
			end
			return {
				id = job.id,
				height = 16,
				solidBelow = 0,
				emptyAbove = 1,
				sections = { 0 },
				meshes = { box },
				summary = summary,
			}
		end
		function pool.step(self)
			local due = {}
			for id, entry in pool.inFlight do
				if entry.at <= sim.frame then
					table.insert(due, id)
				end
			end
			table.sort(due)
			for _, id in due do
				local entry = pool.inFlight[id]
				pool.inFlight[id] = nil
				entry.callback(result(entry.job))
			end
		end
		return pool
	end

	--[[
		A streamer with fakes around it, at (x, z) blocks looking along +X, with a small view
		(256 blocks, falloff 2) bound through ViewSettings and `applyView`. `cave`: the camera is in
		the cave world's tunnel (caveData, surface at 100), cave view 128.
	]]
	local function newSim(x: number, z: number, view: number?, cave: boolean?, real: any?): any
		local sim: any = {
			frame = 0,
			serverEdits = {},
			gaps = 0,
			overlaps = 0,
			checkGaps = true,
			cave = cave == true or real ~= nil,
			real = real,
			surface = if cave then 100 else 0,
			eyeY = if cave then 20.6 else 30,
			voids = 0,
		}
		local env = newEnv()
		sim.env = env
		local net = fakeNet(sim)
		sim.net = net
		local req = loader(env, {
			["src/client/Net/ClientNet.luau"] = net,
			["src/client/Rendering/ChunkRenderer.luau"] = {},
			["src/client/Streaming/WorkerPool.luau"] = {},
		})
		local ClientWorld = req(client.World.ClientWorld)
		local ViewSettings = req(client.Rendering.ViewSettings)
		local ChunkStreamer = req(client.Streaming.ChunkStreamer)
		local values = PlayerSettings.defaults(false)
		values.renderDistance = view or 256
		values.detailFalloff = 2
		values.fullDetail = 2
		values.caveView = if cave then 128 else 64
		values.plants = 0
		ViewSettings.bind(values)
		sim.values = values
		local world = ClientWorld.new()
		local renderer = fakeRenderer(sim)
		local pool = fakePool(sim)
		local generator = real or {
			column = function()
				return sim.surface
			end,
		}
		local streamer = ChunkStreamer.new(generator :: any, world, pool, renderer)
		streamer:applyView()
		sim.world, sim.renderer, sim.pool, sim.streamer = world, renderer, pool, streamer
		sim.teleportModes = {}
		streamer.onTeleportMode = function(active)
			table.insert(sim.teleportModes, active)
		end

		-- (The camera in render studs: world studs minus the floating origin, Shared/World/Origin.)
		function sim.place(self, px: number, pz: number, yaw: number?)
			self.x, self.z = px, pz
			local angle = yaw or 0
			local eye = Vector3.new(
				px * Config.BlockSize - Origin.x,
				self.eyeY * Config.BlockSize,
				pz * Config.BlockSize - Origin.z
			)
			env.camera.CFrame = CFrame.lookAt(eye, eye + Vector3.new(math.cos(angle), 0, math.sin(angle)))
		end
		sim:place(x, z)

		-- What covers chunk column (cx, cz): the shown node over it, or nil.
		local function coverOf(cx: number, cz: number): any
			for level = 0, MAX_LEVEL do
				local f = bit32.lshift(1, level)
				local node = streamer.nodes[Coords.nodeKey(level, cx // f, cz // f)]
				if node and renderer.shown[node] then
					return node
				end
			end
			return nil
		end
		sim.coverOf = coverOf
		local covered: { [number]: boolean } = {}

		-- Does a followed pocket of section `s` of `node` touch its face `f` (0-based, -X +X -Z +Z
		-- -Y +Y)? True without a graph.
		local function touchesFace(node: any, s: number, f: number): boolean
			local graph = node.graph
			return graph == nil
				or bit32.btest(buffer.readu32(graph, s * 4), bit32.lshift(1, SectionGraph.FACES_SHIFT + f))
		end

		function sim.step(self)
			self.frame += 1
			env.time = self.frame / 60
			env.extra = 0
			local i = 1
			while i <= #self.replies do
				local reply = self.replies[i]
				if reply.at <= self.frame then
					table.remove(self.replies, i)
					net.handlers[Protocol.ServerMessage.ChunkEdits](reply.payload)
				else
					i += 1
				end
			end
			pool:step()
			streamer:update(1 / 60)
			-- No overlaps: nothing on screen has something on screen above it (old models of a
			-- teleport still waiting to be trashed included), and a live node on screen is shown.
			local onScreen: { [number]: boolean } = {}
			for node in renderer.shown do
				local key = Coords.nodeKey(node.level, node.nx, node.nz)
				if onScreen[key] then
					self.overlaps += 1
				end
				onScreen[key] = true
				if not node.removed and not node.shown then
					self.overlaps += 1
				end
			end
			for node in renderer.shown do
				for level = node.level + 1, MAX_LEVEL do
					local f = bit32.lshift(1, level - node.level)
					if onScreen[Coords.nodeKey(level, node.nx // f, node.nz // f)] then
						self.overlaps += 1
					end
				end
			end
			-- No gaps: ground covered last frame within 128 blocks is still covered.
			local now: { [number]: boolean } = {}
			local ccx, ccz = math.floor(self.x) // SIZE, math.floor(self.z) // SIZE
			for dz = -8, 8 do
				for dx = -8, 8 do
					local key = Coords.chunkKey(ccx + dx, ccz + dz)
					local cover = coverOf(ccx + dx, ccz + dz)
					now[key] = cover ~= nil
					if self.checkGaps and covered[key] and not cover then
						self.gaps += 1
					end
				end
			end
			covered = now
			-- Caves: no revealed section on screen is open towards something that does not draw
			-- the cave next door (a hidden section, a coarser node, nothing): that would be a
			-- hole into the void.
			if self.cave then
				for node in renderer.shown do
					local live = renderer.live[node]
					if node.level ~= 0 or live == nil then
						continue
					end
					for s, box in live do
						if buffer.readu8(box, 0) ~= 1 then
							continue
						end
						local caps = buffer.readu8(box, 1)
						for d, side in
							{ { -1, 0, 0 }, { 1, 0, 0 }, { 0, -1, 0 }, { 0, 1, 0 }, { 0, 0, -1 }, { 0, 0, 1 } }
						do
							if bit32.btest(caps, bit32.lshift(1, d - 1)) or s + side[3] < 0 then
								continue
							end
							local other = streamer.nodes[Coords.chunkKey(node.nx + side[1], node.nz + side[2])]
							-- (Only where cave air meets the face on either side, as the graphs say:
							-- elsewhere a cap changes nothing and the streamer leaves it, see its
							-- capFaces. Real chunks have many such faces.)
							if
								not touchesFace(node, s, d - 1)
								and not (
									other
									and other.graph
									and touchesFace(other, s + side[3], bit32.bxor(d - 1, 1))
								)
							then
								continue
							end
							local otherLive = if other and renderer.shown[other] then renderer.live[other] else nil
							local mesh = if otherLive then otherLive[s + side[3]] else nil
							if mesh == nil or buffer.readu8(mesh, 0) ~= 1 then
								self.voids += 1
							end
						end
					end
				end
			end
		end

		function sim.idle(self): boolean
			local stats = streamer:stats()
			if stats.waiting + stats.queued + stats.working + stats.failed > 0 or renderer:busy() then
				return false
			end
			for key in streamer.desired do
				local node = streamer.nodes[key]
				if node == nil or not node.shown then
					return false
				end
			end
			for key in streamer.nodes do
				if not streamer.desired[key] then
					return false
				end
			end
			return true
		end

		function sim.run(self, frames: number, until_: (() -> boolean)?): number
			for f = 1, frames do
				self:step()
				if until_ and until_() then
					return f
				end
			end
			return frames
		end

		function sim.close(self)
			-- (ViewSettings.applyLod set the shared LodTree and Config.Render.Foliage.)
			LodTree.configure(
				Config.Lod.ViewDistance,
				Config.Lod.SplitDistance,
				Config.Lod.SplitDistanceL1,
				Config.Lod.UndergroundSplitDistanceL1
			)
			LodTree.setFoliageDistance(Config.Lod.FoliageDistance)
			Config.Render.Foliage = sim.foliage
		end
		return sim
	end

	-- Runs `fn(sim)` with a fresh simulation, restoring the shared state afterwards.
	local function simulate(x: number, z: number, fn: (any) -> (), view: number?, cave: boolean?, real: any?)
		local foliage = Config.Render.Foliage
		local swapParts = Config.Render.SwapPartsPerFrame
		local sim
		local ok, err = pcall(function()
			sim = newSim(x, z, view, cave, real)
			sim.foliage = foliage
			fn(sim)
		end)
		Config.Render.SwapPartsPerFrame = swapParts
		if sim then
			sim:close()
		end
		Config.Render.Foliage = foliage
		if not ok then
			error(err, 0)
		end
	end

	local function shownCount(sim: any): number
		local n = 0
		for _ in sim.renderer.shown do
			n += 1
		end
		return n
	end

	t.test("streamer: loads the view, the ground under the player first, no overlaps", function()
		simulate(40.5, 40.5, function(sim)
			local readyAt = nil
			local frames = sim:run(600, function()
				if readyAt == nil and sim.streamer:isReady(40, 40) then
					readyAt = sim.frame
				end
				return sim:idle()
			end)
			t.ok(sim:idle(), `loaded ({frames} frames)`)
			t.ok(readyAt ~= nil and readyAt < frames / 2, `3x3 shown early ({readyAt} of {frames})`)
			t.eq(sim.overlaps, 0, "no overlaps")
			t.eq(sim.gaps, 0, "no gaps")
			t.eq(sim.teleportModes[1], true, "the first load pauses map tiles")
			t.eq(sim.teleportModes[2], false, "and ends")
			t.ok(not sim.renderer.overlay.paused, "far meshes resumed")
			t.eq(#sim.renderer.trashed, 0, "nothing to drop on the first load")
		end)
	end)

	t.test("streamer: the view loads before what is behind", function()
		simulate(40.5, 40.5, function(sim)
			sim:run(600, function()
				return sim:idle()
			end)
			-- Order of generation jobs for nodes at least 128 blocks away.
			local view = LoadPriority.view(40.5, 40.5, 1, 0, 70, 16 / 9)
			local sumIn, nIn, sumOut, nOut = 0, 0, 0, 0
			for i, job in sim.pool.submitted do
				if job.kind == "generate" then
					local size = LodTree.nodeSize(job.level)
					if LodTree.distance(job.level, job.nx, job.nz, 40.5, 40.5) >= 128 then
						if LoadPriority.inView(view, job.nx * size, job.nz * size, size) then
							sumIn += i
							nIn += 1
						else
							sumOut += i
							nOut += 1
						end
					end
				end
			end
			t.ok(nIn > 0 and nOut > 0)
			t.ok(sumIn / nIn < sumOut / nOut, `in view first: mean order {sumIn / nIn} vs {sumOut / nOut}`)
		end)
	end)

	t.test("streamer: walking swaps levels without overlaps or gaps, in budgeted units", function()
		simulate(40.5, 40.5, function(sim)
			sim:run(600, function()
				return sim:idle()
			end)
			Config.Render.SwapPartsPerFrame = 250
			local maxSwapped = 0
			local before = {}
			for f = 1, 400 do
				sim:place(40.5 + f * 1.5, 40.5 + f * 0.7)
				for node in sim.renderer.shown do
					before[node] = true
				end
				sim:step()
				local entered, left = 0, 0
				for node in sim.renderer.shown do
					if not before[node] then
						entered += 1
					end
				end
				for node in before do
					if not sim.renderer.shown[node] then
						left += 1
					end
				end
				maxSwapped = math.max(maxSwapped, (entered + left) * sim.renderer.partsPerNode)
				table.clear(before)
			end
			sim:run(600, function()
				return sim:idle()
			end)
			t.ok(sim:idle(), "caught up")
			t.eq(sim.overlaps, 0, "no overlaps")
			t.eq(sim.gaps, 0, "no gaps")
			t.ok(#sim.renderer.cleared > 20, "levels changed")
			-- A single unit may exceed the allowance (at least one a frame); units of 5 nodes at most.
			t.ok(maxSwapped <= 250 + 5 * sim.renderer.partsPerNode, `parts swapped per frame {maxSwapped}`)
			t.eq(#sim.renderer.trashed, 0, "walking never drops models")
		end)
	end)

	t.test("streamer: an edit on a chunk border goes live in both chunks in one frame", function()
		simulate(40.5, 40.5, function(sim)
			sim:run(600, function()
				return sim:idle()
			end)
			local pool, renderer = sim.pool, sim.renderer
			-- The +X neighbour's job comes back later than the edited chunk's.
			pool.latency = function(job)
				return if job.kind == "mesh" and job.nx == 3 then 6 else 1
			end
			local submitted = #pool.submitted
			local commits = #renderer.commits
			-- Block (47, 0, 40): chunk (2, 2) at local x 15, so chunk (3, 2) pads it.
			sim.world:applyEdit(2 * SIZE + SIZE - 1, 0, 40, Blocks.AIR)
			sim:run(20)
			local jobs = {}
			for i = submitted + 1, #pool.submitted do
				if pool.submitted[i].kind ~= "horizon" then
					table.insert(jobs, pool.submitted[i])
				end
			end
			t.eq(#jobs, 2, "one job per chunk")
			t.ok(jobs[1].kind == "mesh" and jobs[1].edit == true and jobs[2].edit == true, "edit jobs")
			local live = {}
			for i = commits + 1, #renderer.commits do
				table.insert(live, renderer.commits[i])
			end
			t.eq(#live, 2, "both sections went live")
			t.eq(live[1].lane, "edit")
			t.ok(live[1].group ~= nil and live[1].group == live[2].group, "one commit group")
			t.eq(live[1].frame, live[2].frame, "in the same frame")
			t.eq(sim.world:getBlock(2 * SIZE + SIZE - 1, 0, 40), Blocks.AIR)
		end)
	end)

	t.test("streamer: a failed remesh comes back; the rest of its batch does not wait", function()
		simulate(40.5, 40.5, function(sim)
			sim:run(600, function()
				return sim:idle()
			end)
			local pool, renderer = sim.pool, sim.renderer
			local failures = 0
			pool.fail = function(job)
				if job.kind == "mesh" and job.nx == 3 and failures == 0 then
					failures += 1
					return true
				end
				return false
			end
			local commits = #renderer.commits
			sim.world:applyEdit(2 * SIZE + SIZE - 1, 0, 40, Blocks.AIR)
			sim:run(10)
			local first = {}
			for i = commits + 1, #renderer.commits do
				table.insert(first, renderer.commits[i])
			end
			t.eq(#first, 1, "the chunk whose job worked went live")
			t.eq(first[1].node.nx, 2)
			sim:run(90)
			local all = #renderer.commits - commits
			t.eq(all, 2, "the failed chunk's section was remeshed again")
			t.eq(failures, 1)
		end)
	end)

	t.test("streamer: a failed generation keeps the cover and retries", function()
		simulate(40.5, 40.5, function(sim)
			sim:run(600, function()
				return sim:idle()
			end)
			local pool = sim.pool
			local attempts = 0
			local target = nil
			pool.fail = function(job)
				if job.kind == "generate" and job.level == 0 and target == nil then
					target = { job.nx, job.nz }
				end
				if
					target
					and job.kind == "generate"
					and job.nx == target[1]
					and job.nz == target[2]
					and job.level == 0
				then
					attempts += 1
					return attempts <= 2
				end
				return false
			end
			-- Walk until a new full detail chunk is generated, then wait for its retries.
			local x = 40.5
			for _ = 1, 600 do
				if target == nil then
					x += 0.5
					sim:place(x, 40.5)
				end
				sim:step()
				if attempts >= 3 then
					break
				end
			end
			t.ok(target ~= nil, "a chunk was generated")
			t.eq(attempts, 3, "two failures, then retried")
			sim:run(600, function()
				return sim:idle()
			end)
			t.ok(sim:idle())
			t.eq(sim.gaps, 0, "its area stayed covered meanwhile")
			t.eq(sim.overlaps, 0)
		end)
	end)

	t.test("streamer: an edit during generation patches the result and only meshes it", function()
		simulate(40.5, 40.5, function(sim)
			local pool = sim.pool
			-- The chunk under the player takes 20 frames to generate.
			pool.latency = function(job)
				return if job.kind == "generate" and job.level == 0 and job.nx == 2 and job.nz == 2 then 20 else 2
			end
			local edited = false
			sim:run(300, function()
				local node = sim.streamer.nodes[Coords.chunkKey(2, 2)]
				if not edited and node and node.state == "working" then
					edited = true
					-- The server's edit arrives while the job runs (the edit list knows it too).
					sim.world:applyEdit(2 * SIZE + 4, 5, 2 * SIZE + 4, STONE)
				end
				return edited and sim:idle()
			end)
			t.ok(edited and sim:idle())
			local generated, meshed = 0, 0
			for _, job in pool.submitted do
				if job.nx == 2 and job.nz == 2 and (job.level == 0 or job.kind == "mesh") then
					if job.kind == "generate" then
						generated += 1
					else
						meshed += 1
					end
				end
			end
			t.eq(generated, 1, "not generated again")
			t.eq(meshed, 1, "meshed once")
			t.eq(sim.world:getBlock(2 * SIZE + 4, 5, 2 * SIZE + 4), STONE, "the late edit is in the data")
			t.ok(sim.streamer:isReady(40, 40))
		end)
	end)

	t.test("streamer: a teleport drops the old area at once and unfreezes quickly", function()
		simulate(40.5, 40.5, function(sim)
			sim:run(600, function()
				return sim:idle()
			end)
			local old = {}
			for node in sim.renderer.shown do
				table.insert(old, node)
			end
			-- Slow workers, so jobs are in flight when the teleport comes.
			sim.pool.latency = function()
				return 30
			end
			sim:place(5000.5, 40.5)
			sim.streamer:teleported(Vector3.new(5000.5, 30, 40.5))
			sim.checkGaps = false
			sim:step()
			for _, node in old do
				t.ok(node.removed and sim.streamer.nodes[node.key] ~= node, "every old node dropped at once")
			end
			-- Their models go to the renderer over the next frames (none overlaps the new area).
			local frames = sim:run(20, function()
				return #sim.renderer.trashed == #old
			end)
			t.eq(#sim.renderer.trashed, #old, "every old model trashed")
			t.ok(frames <= math.ceil(#old / 64), `within {frames} frames`)
			for _, entry in sim.renderer.trashed do
				t.ok(entry.node.removed and not entry.immediate, "far from the destination")
			end
			for node in sim.renderer.shown do
				t.ok(not node.removed, "no old model left on screen")
			end
			t.ok(sim.renderer.overlay.paused and sim.streamer:stats().teleporting)
			t.eq(sim.teleportModes[#sim.teleportModes], true)
			-- Jobs of the old area that were in flight are cancelled (new ones start right away).
			sim.pool.latency = function()
				return 2
			end
			local readyAt = sim:run(600, function()
				return sim.streamer:isReady(5000, 40)
			end)
			t.ok(readyAt < 60, `the 3x3 under the player in {readyAt} frames`)
			sim:run(600, function()
				return sim:idle() and not sim.streamer:stats().teleporting
			end)
			t.ok(sim:idle(), "the new area loaded")
			t.ok(not sim.renderer.overlay.paused, "far meshes resumed")
			t.eq(sim.teleportModes[#sim.teleportModes], false)
			t.eq(sim.overlaps, 0)
		end)
	end)

	t.test("streamer: a teleport hands far models over in later frames, nearest first", function()
		simulate(40.5, 40.5, function(sim)
			sim:run(600, function()
				return sim:idle()
			end)
			local old = shownCount(sim)
			sim:place(5000.5, 40.5)
			sim.streamer:teleported(Vector3.new(5000.5, 30, 40.5))
			sim.checkGaps = false
			sim:step()
			local first = #sim.renderer.trashed
			t.ok(first > 0 and first < old, `some trashed in the teleport frame ({first} of {old})`)
			sim:run(60, function()
				return #sim.renderer.trashed == old
			end)
			t.eq(#sim.renderer.trashed, old, "all trashed a few frames later")
			for i = 2, #sim.renderer.trashed do
				t.ok(sim.renderer.trashed[i].distance >= sim.renderer.trashed[i - 1].distance, "nearest first")
			end
		end)
		simulate(40.5, 40.5, function(sim)
			sim:run(600, function()
				return sim:idle()
			end)
			local old = shownCount(sim)
			local oldNodes = table.clone(sim.renderer.shown)
			sim.checkGaps = false
			-- Away and straight back: models still waiting to be trashed that the new selection
			-- reaches go at once (never under or over a node shown there).
			sim:place(3000.5, 40.5)
			sim.streamer:teleported(Vector3.new(3000.5, 30, 40.5))
			sim:step()
			t.ok(#sim.renderer.trashed < old, "deferred")
			sim:place(40.5, 40.5)
			sim.streamer:teleported(Vector3.new(40.5, 30, 40.5))
			sim:step()
			local trashed = {}
			for _, entry in sim.renderer.trashed do
				trashed[entry.node] = true
			end
			for node in oldNodes do
				t.ok(trashed[node], "the rest trashed when the selection came back")
			end
			sim:run(600, function()
				return sim:idle()
			end)
			t.ok(sim:idle())
			t.eq(sim.overlaps, 0)
		end)
	end)

	t.test("streamer: a teleport cancels the old area's jobs; a short one stays seamless", function()
		simulate(40.5, 40.5, function(sim)
			sim.pool.latency = function()
				return 1000
			end
			sim:run(30)
			-- A jump the streamer notices by itself at its next refresh.
			sim:place(-3000.5, 40.5)
			sim.checkGaps = false
			local inFlight = 0
			for _ = 1, 20 do
				inFlight = sim.pool:busy()
				sim:step()
				if #sim.pool.cancelled > 0 then
					break
				end
			end
			t.ok(inFlight > 0, "jobs were in flight")
			t.eq(#sim.pool.cancelled, inFlight, "every job of the old area cancelled")
			t.ok(sim.streamer:stats().teleporting)
		end)
		simulate(40.5, 40.5, function(sim)
			sim:run(600, function()
				return sim:idle()
			end)
			-- 100 blocks: an immediate refresh at the destination, the usual seamless swaps.
			sim:place(140.5, 40.5)
			sim.streamer:teleported(Vector3.new(140.5, 30, 40.5))
			sim:run(600, function()
				return sim:idle()
			end)
			t.eq(#sim.renderer.trashed, 0, "nothing trashed")
			t.ok(sim:idle())
			t.eq(sim.overlaps, 0)
		end)
	end)

	t.test("streamer: applyView reselects at once; swap units drop what is beyond the view", function()
		simulate(40.5, 40.5, function(sim)
			sim:run(900, function()
				return sim:idle()
			end)
			local before = 0
			for _ in sim.streamer.nodes do
				before += 1
			end
			Config.Render.SwapPartsPerFrame = 300
			sim.values.renderDistance = 128
			sim.streamer:applyView()
			sim:step()
			t.eq(LodTree.viewDistance(), 128)
			local frames = sim:run(600, function()
				return sim:idle()
			end)
			local after = 0
			for _ in sim.streamer.nodes do
				after += 1
			end
			t.ok(after < before, `fewer nodes ({before} -> {after})`)
			t.ok(frames > 1, "removed over several frames")
			t.eq(sim.overlaps, 0)
		end, 512)
	end)

	t.test("streamer: random walks, jumps, edits and failures keep the invariants", function()
		for seed = 1, 6 do
			simulate(40.5, 40.5, function(sim)
				local rand = rng(seed * 7919)
				local pool = sim.pool
				pool.latency = function()
					return 1 + rand(6)
				end
				pool.fail = function()
					return rand(25) == 0
				end
				sim.renderer.buildFrames = 1 + rand(3)
				Config.Render.SwapPartsPerFrame = 100 + rand(600)
				local x, z = 40.5, 40.5
				local yaw = 0
				for _ = 1, 500 do
					local roll = rand(100)
					if roll < 2 then
						-- A teleport (told, or noticed as a jump).
						x += (rand(2) * 2 - 1) * (300 + rand(3000))
						sim.checkGaps = false
						sim:place(x, z, yaw)
						if rand(2) == 0 then
							sim.streamer:teleported(Vector3.new(x, 30, z))
						end
					elseif roll < 60 then
						x += (rand(5) - 2) * 0.6
						z += (rand(5) - 2) * 0.6
						yaw += (rand(3) - 1) * 0.1
						sim:place(x, z, yaw)
					elseif roll < 70 then
						-- An edit near the player (border columns often).
						local bx = math.floor(x) + rand(40) - 20
						local bz = math.floor(z) + rand(40) - 20
						sim.world:applyEdit(bx, rand(4), bz, if rand(2) == 0 then Blocks.AIR else STONE)
					end
					sim:step()
					if not sim.streamer:stats().teleporting then
						sim.checkGaps = true
					end
				end
				pool.fail = function()
					return false
				end
				-- (A remesh that failed waits a little before it is sent again.)
				sim:run(2000, function()
					return sim:idle() and sim.streamer.remesh:pending() == 0
				end)
				t.ok(sim:idle(), `seed {seed}: settles`)
				t.eq(sim.overlaps, 0, `seed {seed}: no overlaps`)
				t.eq(sim.gaps, 0, `seed {seed}: no gaps outside teleports`)
				t.eq(sim.streamer.remesh:pending(), 0, `seed {seed}: no dirty section left`)
			end)
		end
	end)

	t.test("streamer: with the render origin far away it selects and loads as at the world's 0", function()
		-- One load and a step, with the origin at (ox, oz) studs and the camera in render studs.
		local function run(ox: number, oz: number): any
			Origin.reset()
			Origin.set(ox, oz)
			local out: any = {}
			simulate(40.5, -20.5, function(sim)
				out.frames = sim:run(600, function()
					return sim:idle()
				end)
				out.idle = sim:idle()
				out.viewer = sim.streamer.viewer
				out.eye = sim.streamer.eye
				out.modes = #sim.teleportModes
				local keys = {}
				for key in sim.streamer.desired do
					table.insert(keys, key)
				end
				table.sort(keys)
				out.desired = table.concat(keys, ",")
				out.shown = shownCount(sim)
				out.overlaps, out.gaps = sim.overlaps, sim.gaps
				-- A step on: the next refresh sees a block of walking, no teleport.
				sim:place(sim.x + 1, sim.z)
				sim:run(15)
				out.walked = sim.streamer.viewer
				out.trashed = #sim.renderer.trashed
			end)
			return out
		end
		local ok, err = pcall(function()
			local home, away = run(0, 0), run(7680, -7680)
			t.ok(home.idle and away.idle, "both loaded")
			t.eq(away.frames, home.frames, "in as many frames")
			t.eq(away.desired, home.desired, "the same selection")
			t.eq(away.shown, home.shown, "as many nodes shown")
			t.ok(away.viewer:FuzzyEq(home.viewer, 1e-4), `the viewer in world blocks: {away.viewer}`)
			t.ok(away.eye:FuzzyEq(home.eye, 1e-4), `the eye in world blocks: {away.eye}`)
			t.eq(away.modes, home.modes, "teleport mode as at 0")
			t.ok(away.walked:FuzzyEq(home.walked, 1e-4), "walking on")
			t.eq(away.trashed, 0, "no teleport")
			t.eq(away.overlaps + away.gaps, 0, "no overlaps or gaps")
		end)
		Origin.reset()
		if not ok then
			error(err, 0)
		end
	end)

	t.test("streamer: the viewer is the hull hook, else the world spawn, else the camera", function()
		Origin.reset()
		Origin.set(3072, 1536)
		local ok, err = pcall(function()
			simulate(40.5, 40.5, function(sim)
				local streamer = sim.streamer
				sim:run(15)
				t.ok(
					streamer.viewer:FuzzyEq(Vector3.new(40.5, sim.eyeY, 40.5), 1e-4),
					`the camera, in world blocks: {streamer.viewer}`
				)
				-- No hull yet: the world spawn (world studs).
				shared:SetAttribute("SpawnPosition", Vector3.new(90 * 3, 33 * 3, -60 * 3))
				local feet: { number }? = nil
				streamer.viewerFeet = function(): (number?, number, number)
					if feet then
						return feet[1], feet[2], feet[3]
					end
					return nil, 0, 0
				end
				sim:run(15)
				t.ok(streamer.viewer:FuzzyEq(Vector3.new(90, 33, -60), 1e-4), `the spawn: {streamer.viewer}`)
				-- The hull (world blocks).
				feet = { 41.25, 30, 39.75 }
				sim:run(15)
				t.ok(streamer.viewer:FuzzyEq(Vector3.new(41.25, 30, 39.75), 1e-4), `the hull: {streamer.viewer}`)
				t.ok(streamer.eye:FuzzyEq(Vector3.new(40.5, sim.eyeY, 40.5), 1e-4), "the eye is the camera's")
			end)
		end)
		shared:SetAttribute("SpawnPosition", nil)
		Origin.reset()
		if not ok then
			error(err, 0)
		end
	end)

	t.test("streamer: the frozen flag and far-mesh gate reach the renderer", function()
		simulate(40.5, 40.5, function(sim)
			sim.streamer:setFrozen(true)
			t.ok(sim.renderer.frozen)
			sim:step()
			t.ok(sim.renderer.overlay.busy, "busy while loading")
			sim:run(600, function()
				return sim:idle()
			end)
			sim:step()
			t.ok(not sim.renderer.overlay.busy, "idle again")
			sim.streamer:setFrozen(false)
			t.ok(not sim.renderer.frozen)
		end)
	end)

	--[[ The cave view in the streamer (cave sims: caveData, real SectionGraphs) ]]

	-- Runs until loaded, no remesh is dirty or in flight, for a couple of refreshes; `hold`: then
	-- long enough for the open-space radius to shrink back (CaveReach's tracker) and settles again.
	local function settle(sim: any, hold: boolean?): boolean
		local function quietly(): boolean
			local quiet = 0
			sim:run(1500, function()
				local busy = not sim:idle() or sim.streamer.remesh:pending() > 0 or next(sim.pool.inFlight) ~= nil
				quiet = if busy then 0 else quiet + 1
				return quiet >= 30
			end)
			return quiet >= 30
		end
		local ok = quietly()
		if hold then
			-- (The radius shrinks after 2 s, what it revealed beyond the reach goes 2 s later.)
			sim:run(300)
			ok = quietly() and ok
		end
		return ok
	end

	-- Is section `s` of chunk (cx, cz) on screen revealed, and with which caps?
	local function liveReveal(sim: any, cx: number, cz: number, s: number): (boolean, number)
		local node = sim.streamer.nodes[Coords.chunkKey(cx, cz)]
		local live = node and sim.renderer.live[node]
		local box = live and live[s]
		if box == nil then
			return false, -1
		end
		return buffer.readu8(box, 0) == 1, buffer.readu8(box, 1)
	end

	-- The caps section `s` of chunk (cx, cz) should have once settled: open only towards revealed
	-- sections on screen, drawing their caves (every one while caves are always shown).
	local function wantedCaps(sim: any, cx: number, cz: number, s: number): number
		local streamer = sim.streamer
		local mask = 0
		for d, face in { { -1, 0, 0 }, { 1, 0, 0 }, { 0, -1, 0 }, { 0, 1, 0 }, { 0, 0, -1 }, { 0, 0, 1 } } do
			local x, z, ns = cx + face[1], cz + face[2], s + face[3]
			if ns >= 0 then
				local node = streamer.nodes[Coords.chunkKey(x, z)]
				local open = node ~= nil
					and node.shown
					and streamer.desired[Coords.chunkKey(x, z)] ~= nil
					and (streamer.alwaysCaves or streamer.cave:reveals(x, z, ns))
					and (liveReveal(sim, x, z, ns))
				if not open then
					mask += bit32.lshift(1, d - 1)
				end
			end
		end
		return mask
	end

	t.test("streamer: underground, what the search reaches is revealed with its caps, never onto the void", function()
		simulate(8.5, 8.5, function(sim)
			t.ok(settle(sim, true), "settles")
			local streamer = sim.streamer
			local view = streamer.caveView
			t.ok(view ~= nil, "underground")
			t.eq(view.reach, Config.Caves.RevealReach, "a tunnel: the tunnel reach")
			local revealed = 0
			for cx = -6, 6 do
				local dx = (cx + 0.5) * SIZE - 8.5
				local within = math.abs(dx) < view.reach
				t.eq(streamer.cave:reveals(cx, 0, 1), within, `tunnel chunk {cx}: revealed within the reach`)
				local on, caps = liveReveal(sim, cx, 0, 1)
				t.eq(on, within, `chunk {cx}: on screen as wanted`)
				if within then
					revealed += 1
					t.eq(caps, wantedCaps(sim, cx, 0, 1), `chunk {cx}: caps`)
					t.eq(bit32.btest(caps, 1), cx == -5, `chunk {cx}: -X capped only at the end`)
					t.eq(bit32.btest(caps, 2), cx == 5, `chunk {cx}: +X capped only at the end`)
				end
			end
			t.eq(revealed, 11, "the tunnel 88 blocks each way")
			t.ok(not streamer.cave:reveals(0, 1, 1), "the cave behind rock stays hidden")
			t.ok(not streamer.cave:reveals(0, 0, 2) and not streamer.cave:reveals(0, 0, 0), "and the rock around")
			t.eq(sim.voids, 0, "never open onto the void")
			t.ok(streamer:stats().searchMs < 50, "search time is measured")
		end, 256, true)
	end)

	t.test("streamer: walking the tunnel, a cap opening and the section behind it go live together", function()
		simulate(8.5, 8.5, function(sim)
			t.ok(settle(sim, true), "settles")
			local renderer = sim.renderer
			local streamer = sim.streamer
			t.ok(not streamer.cave:reveals(6, 0, 1), "beyond the reach")
			local n5 = streamer.nodes[Coords.chunkKey(5, 0)]
			local n6 = streamer.nodes[Coords.chunkKey(6, 0)]
			t.ok(n5 and n5.shown and n6 and n6.shown, "both chunks on screen (full detail)")
			local commits = #renderer.commits
			-- Eight blocks on: section (6, 0, 1) comes within the reach, (-5, 0, 1) drops out.
			sim:place(16.5, 8.5)
			sim:run(40)
			t.ok(streamer.cave:reveals(6, 0, 1), "revealed")
			local frames, groups = {}, {}
			for i = commits + 1, #renderer.commits do
				local c = renderer.commits[i]
				if c.section == 1 and (c.node == n5 or c.node == n6) then
					frames[c.node] = c.frame
					groups[c.node] = c.group
				end
			end
			t.ok(frames[n5] ~= nil and frames[n6] ~= nil, "both remeshed")
			t.eq(frames[n5], frames[n6], "in the same frame")
			t.ok(groups[n5] ~= nil and groups[n5] == groups[n6], "one commit group")
			local on, caps = liveReveal(sim, 5, 0, 1)
			t.ok(on and not bit32.btest(caps, 2), "the old end opened")
			-- The far -X end is held a while, then hidden.
			t.ok((liveReveal(sim, -5, 0, 1)), "held")
			sim:run(150)
			t.ok(not (liveReveal(sim, -5, 0, 1)), "hidden after the hold")
			t.ok(settle(sim))
			t.eq(sim.voids, 0, "never open onto the void")
		end, 256, true)
	end)

	t.test("streamer: a tunnel never opens towards a chunk that is not on screen yet", function()
		simulate(8.5, 8.5, function(sim)
			t.ok(settle(sim, true), "settles")
			local streamer = sim.streamer
			-- New full detail chunks along the tunnel take five seconds to generate; the search
			-- reveals their sections (pending) as soon as it reaches them.
			sim.pool.latency = function(job)
				return if job.kind == "generate" and job.level == 0 then 300 else 2
			end
			local pendingSeen = false
			for _ = 1, 8 do
				sim:place(sim.x + 8, 8.5)
				sim:run(13)
				for key in streamer.cave.revealed do
					local cx, cz = SectionGraph.decode(key)
					local node = streamer.nodes[Coords.chunkKey(cx, cz)]
					if node and not node.shown then
						pendingSeen = true
					end
				end
			end
			t.ok(pendingSeen, "sections of chunks not shown yet were revealed")
			t.ok(settle(sim, true), "settles")
			t.eq(sim.voids, 0, "never open onto the void")
			local on, caps = liveReveal(sim, 7, 0, 1)
			t.ok(on and not bit32.btest(caps, 1), "the tunnel goes on once they are shown")
		end, 256, true)
	end)

	t.test("streamer: edit jobs bring the graph back; digging into a cave reveals it", function()
		simulate(8.5, 8.5, function(sim)
			t.ok(settle(sim, true), "settles")
			local streamer = sim.streamer
			t.ok(not streamer.cave:reveals(0, 1, 1), "hidden behind rock")
			local submitted = #sim.pool.submitted
			for z = 9, 23 do
				sim.world:applyEdit(8, 20, z, Blocks.AIR)
			end
			t.ok(settle(sim), "settles again")
			local withGraph = 0
			for i = submitted + 1, #sim.pool.submitted do
				local job = sim.pool.submitted[i]
				if job.kind == "mesh" and job.edit and job.graph then
					withGraph += 1
					t.ok(table.find(job.graphSections, 1) ~= nil, "the edited section is recomputed")
				end
			end
			t.ok(withGraph >= 2, `edit jobs carry the graph ({withGraph})`)
			local node = streamer.nodes[Coords.chunkKey(0, 1)]
			local chunk = node.chunk
			local expect = SectionGraph.compute(chunk.data, chunk.height, 1, true)
			t.eq(buffer.readu32(node.graph, 4), expect, "the chunk's graph matches its blocks")
			t.ok(streamer.cave:reveals(0, 1, 1), "the cave behind is revealed")
			t.ok((liveReveal(sim, 0, 1, 1)), "and on screen")
			t.eq(sim.voids, 0)
		end, 256, true)
	end)

	t.test("streamer: a late result's mesh job recomputes the graph of the late edits", function()
		simulate(8.5, 8.5, function(sim)
			local pool = sim.pool
			pool.latency = function(job)
				return if job.kind == "generate" and job.level == 0 and job.nx == 2 and job.nz == 0 then 20 else 2
			end
			local edited = false
			sim:run(400, function()
				local node = sim.streamer.nodes[Coords.chunkKey(2, 0)]
				if not edited and node and node.state == "working" then
					edited = true
					-- Seals the tunnel inside chunk (2, 0).
					sim.world:applyEdit(40, 20, 8, STONE)
					sim.world:applyEdit(40, 21, 8, STONE)
				end
				return edited and sim:idle()
			end)
			t.ok(edited)
			local found = nil
			for _, job in pool.submitted do
				if job.kind == "mesh" and job.nx == 2 and job.nz == 0 and not job.edit and job.graph then
					found = job
				end
			end
			t.ok(found and table.find(found.graphSections, 1), "the late result's mesh job recomputes section 1")
			local node = sim.streamer.nodes[Coords.chunkKey(2, 0)]
			t.eq(
				buffer.readu32(node.graph, 4),
				SectionGraph.compute(node.chunk.data, node.chunk.height, 1, true),
				"graph of the edited data"
			)
			t.ok(settle(sim))
			t.ok(not sim.streamer.cave:reveals(3, 0, 1), "the tunnel beyond the seal is hidden")
			t.eq(sim.voids, 0)
		end, 256, true)
	end)

	t.test("streamer: coming above ground hides the caves after the hold", function()
		simulate(8.5, 8.5, function(sim)
			t.ok(settle(sim, true), "settles")
			t.ok((liveReveal(sim, 0, 0, 1)), "revealed")
			sim.surface = 0
			sim:run(60)
			t.eq(sim.streamer.caveView, nil, "above ground")
			t.ok((liveReveal(sim, 0, 0, 1)), "held a while")
			sim:run(120)
			t.ok(settle(sim), "settles")
			t.eq(sim.streamer.cave.count, 0, "nothing revealed")
			for cx = -5, 5 do
				t.ok(not (liveReveal(sim, cx, 0, 1)), `chunk {cx} hidden again`)
			end
			t.eq(sim.voids, 0)
		end, 256, true)
	end)

	t.test("streamer: a chunk leaving full detail waits until the tunnels next door are capped", function()
		simulate(8.5, 8.5, function(sim)
			t.ok(settle(sim, true), "settles")
			local streamer = sim.streamer
			-- A big cavern's reach (its open space plus a section) runs to the edge of full detail.
			streamer.tunnelReach = 400
			streamer.caveDirty = true
			t.ok(settle(sim, true), "settles")
			t.ok(streamer.cave:reveals(-6, 0, 1) and streamer.cave:reveals(7, 0, 1), "revealed to the edge")
			-- Reveal remeshes take half a second (a busy pool): walking on, the chunks the selection
			-- drops at the trailing edge have their coarser replacement ready long before the
			-- remesh closing the tunnel next door is live.
			sim.pool.latency = function(job)
				return if job.kind == "mesh" and not job.edit then 30 else 2
			end
			local cleared = #sim.renderer.cleared
			local x = 8.5
			for _ = 1, 60 * 12 do
				x += 4.3 / 60
				sim:place(x, 8.5)
				sim:step()
			end
			local left = 0
			for i = cleared + 1, #sim.renderer.cleared do
				if sim.renderer.cleared[i].level == 0 then
					left += 1
				end
			end
			t.ok(left > 0, `full detail chunks left the screen ({left})`)
			t.eq(sim.voids, 0, "never open onto the void")
			t.eq(sim.gaps, 0, "no gaps")
			t.eq(sim.overlaps, 0, "no overlaps")
		end, 256, true)
	end)

	t.test("streamer: entering a cavern, too big for one commit group, never opens onto the void", function()
		simulate(8.5, 8.5, function(sim)
			sim.cavern = true
			sim.surface = 0
			t.ok(settle(sim, true), "settles above ground")
			local streamer = sim.streamer
			t.eq(streamer.cave.count, 0, "nothing revealed above ground")
			-- Reveal remeshes come back after 2..26 frames, in no particular order.
			sim.pool.latency = function(job)
				if job.kind == "mesh" and not job.edit then
					return 2 + (job.nx * 7 + job.nz * 13) % 25
				end
				return 2
			end
			local biggest = 0
			local remesh = streamer.remesh
			local endPass = remesh.endPass
			remesh.endPass = function(self, limit)
				local n = endPass(self, limit)
				biggest = math.max(biggest, n)
				return n
			end
			local capped = false
			sim.surface = 100
			sim:run(600, function()
				-- (Near jobs at the Streaming.RemeshJobs cap while the underground split generates.)
				if remesh.nearInFlight >= Config.Streaming.RemeshJobs and #streamer.queue > 0 then
					capped = true
				end
				return false
			end)
			t.ok(biggest > Config.Streaming.RevealGroupSections, `a pass too big for one group ({biggest})`)
			t.ok(capped, "near jobs waited behind the cap")
			t.ok(settle(sim, true), "settles")
			t.eq(sim.voids, 0, "never open onto the void")
			-- Then the tunnels closed meanwhile open between the chunks.
			for cx = -3, 3 do
				for s = 1, 2 do
					local on, caps = liveReveal(sim, cx, 0, s)
					t.ok(on, `({cx}, 0, {s}) revealed`)
					t.eq(caps, wantedCaps(sim, cx, 0, s), `({cx}, 0, {s}) caps`)
				end
			end
		end, 256, true)
	end)

	t.test(
		"streamer: the Caves setting shows every full detail cave and hides them again, never onto the void",
		function()
			simulate(8.5, 8.5, function(sim)
				sim.cavern = true
				sim.surface = 0
				t.ok(settle(sim, true), "settles above ground")
				local streamer = sim.streamer
				t.ok(not streamer.alwaysCaves, "hidden until seen by default (Config.Caves.AlwaysShow)")
				t.eq(streamer.cave.count, 0, "nothing revealed above ground")
				-- The cavern's sections (1 and 2) of the full detail chunks on screen: how many show
				-- their caves, how many don't.
				local function onScreen(): { any }
					local list = {}
					for _, node in streamer.nodes do
						if node.level == 0 and node.shown then
							table.insert(list, node)
						end
					end
					return list
				end
				local function shown(): (number, number)
					local on, off = 0, 0
					for _, node in onScreen() do
						for s = 1, 2 do
							if liveReveal(sim, node.nx, node.nz, s) then
								on += 1
							else
								off += 1
							end
						end
					end
					return on, off
				end
				local on, off = shown()
				t.ok(on == 0 and off > 0, "every cave hidden")
				-- Reveal remeshes come back after 2..26 frames, in no particular order.
				sim.pool.latency = function(job)
					if job.kind == "mesh" and not job.edit then
						return 2 + (job.nx * 7 + job.nz * 13) % 25
					end
					return 2
				end
				-- Switches the setting as the Settings controller does (the "caves" effect); the frame
				-- after it refreshes and checks every full detail section (`passMs`).
				local passMs = 0
				local function switch(value: number): (number, number, number, number)
					local submitted, frame = #sim.pool.submitted, sim.frame
					sim.values.alwaysCaves = value
					streamer:applyView()
					local t0 = os.clock()
					sim:step()
					passMs = (os.clock() - t0) * 1000
					t.ok(settle(sim), "settles")
					local jobs, sections, generated = 0, 0, 0
					for i = submitted + 1, #sim.pool.submitted do
						local job = sim.pool.submitted[i]
						if job.kind == "mesh" then
							jobs += 1
							sections += #job.sections
						elseif job.kind == "generate" then
							generated += 1
						end
					end
					return jobs, sections, generated, sim.frame - frame
				end

				local jobs, sections, generated, frames = switch(1)
				t.ok(streamer.alwaysCaves and streamer:stats().alwaysCaves, "always shown")
				t.eq(generated, 0, "nothing generated again")
				local chunks = #onScreen()
				on, off = shown()
				t.eq(off, 0, `every cave of the {chunks} full detail chunks shown ({on} sections)`)
				-- Sections 0..2 hold blocks: each is remeshed once, and again where a cap opened once the
				-- section beyond it went live (another commit group).
				t.ok(sections >= chunks * 3 and sections <= chunks * 3 * 2, `remeshed {sections} sections`)
				print(
					string.format(
						"    hidden -> always shown: %d full detail chunks, %d mesh jobs, %d sections remeshed (%.2f per section with blocks), settled in %d frames; the switching frame %.1f ms",
						chunks,
						jobs,
						sections,
						sections / (chunks * 3),
						frames,
						passMs
					)
				)
				-- Open between full detail chunks on screen, closed towards the coarser nodes around.
				local closedOutside = 0
				for _, node in onScreen() do
					for s = 1, 2 do
						local _, caps = liveReveal(sim, node.nx, node.nz, s)
						local want = wantedCaps(sim, node.nx, node.nz, s)
						t.eq(bit32.band(caps, 15), bit32.band(want, 15), `({node.nx}, {node.nz}, {s}) caps`)
						if bit32.band(caps, 15) ~= 0 then
							closedOutside += 1
						end
					end
				end
				t.ok(closedOutside > 0, "the edge of full detail is capped")
				t.eq(streamer.cave.count, 0, "no search")
				t.eq(sim.voids, 0, "never open onto the void")

				-- Walking on, the chunks coming into full detail show their caves at once.
				local x = 8.5
				for _ = 1, 60 * 4 do
					x += 4.3 / 60
					sim:place(x, 8.5)
					sim:step()
				end
				t.ok(settle(sim), "settles")
				on, off = shown()
				t.ok(on > 0 and off == 0, "every cave shown after walking")
				t.eq(sim.voids, 0, "never open onto the void while walking")

				jobs, sections, generated, frames = switch(0)
				t.ok(not streamer.alwaysCaves, "hidden until seen")
				t.eq(generated, 0, "nothing generated again")
				on, off = shown()
				t.ok(on == 0 and off > 0, "every cave hidden again")
				print(
					string.format(
						"    always shown -> hidden: %d mesh jobs, %d sections remeshed, settled in %d frames; the switching frame %.1f ms",
						jobs,
						sections,
						frames,
						passMs
					)
				)
				t.eq(sim.voids, 0, "never open onto the void")
				t.eq(sim.gaps, 0, "no gaps")
				t.eq(sim.overlaps, 0, "no overlaps")
			end, 256, true)
		end
	)

	t.test("streamer: underground with caves always shown, the camera still selects the underground split", function()
		simulate(8.5, 8.5, function(sim)
			sim.values.alwaysCaves = 1
			sim.streamer:applyView()
			t.ok(settle(sim, true), "settles")
			local streamer = sim.streamer
			local view = streamer.caveView
			t.ok(view ~= nil and view.enclosed, "in the tunnel, shut in")
			t.ok(streamer.underground, "the underground split")
			t.eq(view.reach, 0, "no search reach")
			t.eq(streamer.cave.count, 0, "no search")
			t.ok((liveReveal(sim, 0, 1, 1)), "the cave behind rock is shown")
			t.ok((liveReveal(sim, 0, 0, 2)), "and the rock around it is meshed shown")
			t.eq(sim.voids, 0)
			-- Back to hidden underground: the search starts from the camera at once; what it
			-- reaches stays, the rest hides.
			sim.values.alwaysCaves = 0
			streamer:applyView()
			t.ok(settle(sim), "settles")
			t.ok(streamer.cave:reveals(0, 0, 1), "the tunnel is revealed by the search")
			t.ok((liveReveal(sim, 0, 0, 1)), "and on screen")
			t.ok(not (liveReveal(sim, 0, 1, 1)), "the cave behind rock is hidden again")
			t.eq(sim.voids, 0)
		end, 256, true)
	end)

	t.test("streamer: a teleport out of a cave selects the destination above ground at once", function()
		simulate(8.5, 8.5, function(sim)
			t.ok(settle(sim, true), "settles")
			local streamer = sim.streamer
			t.ok(streamer.underground and streamer.caveView ~= nil, "underground: the underground split")
			-- Teleported onto the ground 2048 blocks away; the camera is still in the cave this frame.
			local tx, tz = 2056.5, 8.5
			streamer:teleported(Vector3.new(tx, sim.surface, tz))
			sim:step()
			t.eq(streamer.caveView, nil, "the cave view is judged at the destination")
			t.ok(not streamer.underground, "no underground hold")
			local plain = 0
			for _, level in LodTree.select(tx, tz, nil, false, nil) do
				if level == 0 then
					plain += 1
				end
			end
			local wanted = 0
			for _, level in streamer.desired do
				if level == 0 then
					wanted += 1
				end
			end
			t.eq(wanted, plain, "full detail as above ground")
		end, 256, true)
	end)

	--[[ Hidden terrain in the streamer ]]

	-- The records of a horizon job: node key -> level.
	local function recordsOf(job: any): { [number]: number }
		local out = {}
		for i = 0, job.count - 1 do
			local key = buffer.readf64(job.records, i * Horizon.RECORD_BYTES)
			out[key] = Coords.decodeNodeKey(key)
		end
		return out
	end

	-- A fake verdict: every record of level `minLevel` or more farther than `keep` blocks from the eye.
	local function hideFar(minLevel: number, keep: number): (job: any) -> { number }
		return function(job: any): { number }
			local hidden = {}
			for key, level in recordsOf(job) do
				local _, nx, nz = Coords.decodeNodeKey(key)
				if level >= minLevel and LodTree.distance(level, nx, nz, job.x, job.z) >= keep then
					table.insert(hidden, key)
				end
			end
			return hidden
		end
	end

	local function horizonJobs(sim: any): number
		local n = 0
		for _, job in sim.pool.submitted do
			if job.kind == "horizon" then
				n += 1
			end
		end
		return n
	end

	t.test("streamer: horizon jobs about once a second while moving, after 8 blocks, not standing", function()
		simulate(40.5, 40.5, function(sim)
			local loading = 0
			sim:run(600, function()
				if sim.streamer:stats().teleporting then
					loading = horizonJobs(sim)
				end
				return sim:idle()
			end)
			t.eq(loading, 0, "none during the first load (nothing has a summary yet)")
			sim:run(150)
			t.ok(horizonJobs(sim) >= 1, "evaluated once loaded")
			local standing = horizonJobs(sim)
			sim:run(300)
			t.eq(horizonJobs(sim), standing, "none while standing still")
			-- 3 blocks a second for 5 seconds: about one a second.
			for f = 1, 300 do
				sim:place(40.5 + f * 0.05, 40.5)
				sim:step()
			end
			local walking = horizonJobs(sim) - standing
			t.ok(walking >= 3 and walking <= 6, `walking: {walking} in 5 s`)
			-- A 10-block step: at the next refresh.
			sim:run(60)
			local before = horizonJobs(sim)
			sim:place(sim.x + 10, 40.5)
			sim:run(13)
			t.eq(horizonJobs(sim), before + 1, "after 8 blocks")
			local job = nil
			for _, submitted in sim.pool.submitted do
				if submitted.kind == "horizon" then
					job = submitted
				end
			end
			t.ok(job.count > 0 and buffer.len(job.records) == job.count * Horizon.RECORD_BYTES, "records")
			t.eq(job.raise, 16)
			t.eq(job.keep, 64)
		end)
	end)

	t.test("streamer: hidden nodes load last; estimates stand in for nodes not generated", function()
		simulate(40.5, 40.5, function(sim)
			local pool = sim.pool
			sim:run(600, function()
				return sim:idle()
			end)
			pool.horizon = hideFar(1, 64)
			-- Generation stalls; the viewer walks so nodes split and merge.
			pool.latency = function(job)
				return if job.kind == "generate" then 1e9 else 2
			end
			for f = 1, 60 do
				sim:place(40.5 + f, 40.5)
				sim:step()
			end
			sim:run(130)
			local streamer = sim.streamer
			local last = nil
			for _, job in pool.submitted do
				if job.kind == "horizon" then
					last = job
				end
			end
			local estimated, hiddenWaiting = 0, 0
			for key in recordsOf(last) do
				local node = streamer.nodes[key]
				if node and node.summary == nil then
					estimated += 1
				end
			end
			t.ok(estimated > 0, `nodes not generated yet go in as estimates ({estimated})`)
			for key, node in streamer.nodes do
				if not node.ready and node.retireSince == nil then
					if node.priority >= LoadPriority.OCCLUDED then
						t.ok(streamer.hidden[key], "the last tier is for hidden nodes")
					end
					-- (A hidden node in a replacement group takes its visible siblings' score.)
					if streamer.hidden[key] and node.priority >= LoadPriority.OCCLUDED then
						hiddenWaiting += 1
					end
				end
			end
			t.ok(hiddenWaiting > 0, `hidden nodes waiting last ({hiddenWaiting})`)
			t.ok(streamer:stats().hidden > 0)
		end)
	end)

	-- Walks along +X (2 blocks a refresh) until a node is held; returns how far.
	local function walkUntilHeld(sim: any): number
		local start = sim.x
		for _ = 1, 150 do
			sim:place(sim.x + 2, sim.z)
			sim:run(12)
			if sim.streamer:stats().held > 0 then
				break
			end
		end
		return sim.x - start
	end

	-- Does `node` show any parts (a committed section that is not empty)?
	local function showsParts(sim: any, node: any): boolean
		return next(sim.renderer.live[node] or {}) ~= nil
	end

	t.test("streamer: skip hidden terrain gives back hidden far nodes' parts and builds them once seen", function()
		simulate(40.5, 40.5, function(sim)
			local pool, renderer, streamer = sim.pool, sim.renderer, sim.streamer
			sim.values.skipHidden = 1
			pool.horizon = hideFar(1, 96)
			sim:run(900, function()
				return sim:idle()
			end)
			t.ok(sim:idle(), "loads")
			-- Two verdicts in a row find the far nodes hidden: their parts go, their meshes stay.
			for _ = 1, 3 do
				sim:place(sim.x + 1, sim.z)
				sim:run(75)
			end
			local held = {}
			for node in streamer.held do
				held[node] = true
				t.ok(node.level >= 1, "far nodes only")
				t.ok(node.ready and node.shown, "ready and shown")
				t.ok(not showsParts(sim, node), "no parts on screen")
				t.ok(node.kept ~= nil and node.held == node.kept, "meshes kept")
				t.ok(streamer.hidden[node.key], "hidden")
				t.ok(LodTree.distance(node.level, node.nx, node.nz, sim.x, sim.z) >= 64, "never within 64 blocks")
			end
			t.ok(next(held) ~= nil, `held: {streamer:stats().held} nodes`)
			-- Walking on: nodes splitting and merging are judged from the nodes they replace and
			-- some are generated hidden: never built at all.
			local before = {}
			for node in streamer.held do
				before[node] = true
			end
			walkUntilHeld(sim)
			local neverBuilt = 0
			for _ = 1, 20 do
				for node in streamer.held do
					if not before[node] and renderer.built[node] == nil then
						neverBuilt += 1
					end
				end
				if neverBuilt > 0 then
					break
				end
				sim:place(sim.x + 4, sim.z)
				sim:run(30)
			end
			t.ok(neverBuilt > 0, `nodes generated hidden are never built ({neverBuilt})`)
			t.eq(sim.gaps, 0)
			t.eq(sim.overlaps, 0)
			-- The verdict changes: they build again.
			pool.horizon = function()
				return {}
			end
			local now = {}
			for node in streamer.held do
				now[node] = true
			end
			sim:place(sim.x + 10, 40.5)
			sim:run(60)
			t.eq(streamer:stats().held, 0, "nothing held")
			for node in now do
				if not node.removed then
					t.ok(showsParts(sim, node), "built once seen")
				end
			end
			-- Switched off: everything builds; the meshes stay kept for when it is on again.
			pool.horizon = hideFar(1, 96)
			for _ = 1, 3 do
				sim:place(sim.x + 1, sim.z)
				sim:run(75)
			end
			t.ok(streamer:stats().held > 0, "held again")
			sim.values.skipHidden = 0
			sim:place(sim.x + 2, 40.5)
			sim:run(13)
			sim:run(200, function()
				return sim:idle()
			end)
			t.eq(streamer:stats().held, 0, "switched off")
			for _, node in streamer.nodes do
				t.eq(node.kept ~= nil, node.level > 0 and node.ready, "far nodes keep their meshes")
			end
			t.eq(sim.gaps, 0)
			t.eq(sim.overlaps, 0)
		end)
	end)

	t.test("streamer: skip hidden terrain switched on after loading holds what was built meanwhile", function()
		simulate(40.5, 40.5, function(sim)
			local pool, streamer = sim.pool, sim.streamer
			pool.horizon = hideFar(1, 96)
			sim:run(900, function()
				return sim:idle()
			end)
			t.ok(sim:idle(), "loads with the setting off")
			for _ = 1, 3 do
				sim:place(sim.x + 1, sim.z)
				sim:run(75)
			end
			t.eq(streamer:stats().held, 0, "nothing held while off")
			-- Switched on (the menu, or the Low preset): read at the next refresh.
			sim.values.skipHidden = 1
			for _ = 1, 3 do
				sim:place(sim.x + 1, sim.z)
				sim:run(75)
			end
			local held = 0
			for node in streamer.held do
				held += 1
				t.ok(node.ready and node.shown and node.level >= 1, "a far node on screen")
				t.ok(not showsParts(sim, node), "its parts went back")
			end
			t.ok(held > 0, `far nodes built while it was off are held ({held})`)
			-- Off and on again: still held.
			sim.values.skipHidden = 0
			sim:place(sim.x + 1, sim.z)
			sim:run(30)
			t.eq(streamer:stats().held, 0, "off")
			sim.values.skipHidden = 1
			for _ = 1, 3 do
				sim:place(sim.x + 1, sim.z)
				sim:run(75)
			end
			t.ok(streamer:stats().held > 0, "on again: held again")
			t.eq(sim.gaps, 0)
			t.eq(sim.overlaps, 0)
		end)
	end)

	t.test("streamer: edits of full detail chunks update their Horizon summaries", function()
		simulate(40.5, 40.5, function(sim)
			local streamer = sim.streamer
			sim:run(900, function()
				return sim:idle()
			end)
			local node = streamer.nodes[Coords.chunkKey(2, 2)]
			t.ok(node and node.summary, "a full detail chunk with a summary")
			local tile = (9 // 4) * 4 + 9 // 4
			t.eq(Horizon.top(node.summary, tile), 0, "flat")
			streamer.summariesChanged = false
			sim.world:applyEdit(2 * SIZE + 9, 6, 2 * SIZE + 9, STONE)
			t.eq(Horizon.top(node.summary, tile), 7, "a built block raises its tile's top")
			t.ok(streamer.summariesChanged, "the next horizon job sees it")
		end)
	end)

	t.test("streamer: a held node builds once the camera leaves the verdict's eyes", function()
		simulate(40.5, 40.5, function(sim)
			local pool, streamer = sim.pool, sim.streamer
			sim.values.skipHidden = 1
			pool.horizon = hideFar(1, 96)
			sim:run(900, function()
				return sim:idle()
			end)
			walkUntilHeld(sim)
			t.ok(streamer:stats().held > 0, "some held")
			-- No new verdict comes back; the camera moves 20 blocks (beyond the side eyes).
			pool.latency = function(job)
				return if job.kind == "horizon" then 1e9 else 2
			end
			sim:place(sim.x + 20, 40.5)
			sim:run(30)
			t.eq(streamer:stats().held, 0, "released")
			-- A teleport drops the verdict and cancels the job in flight.
			local jobs = #pool.submitted
			streamer:teleported(Vector3.new(5000.5, 0, 40.5))
			sim:place(5000.5, 40.5)
			sim:step()
			t.eq(next(streamer.hidden), nil, "no verdict after a teleport")
			local cancelled = 0
			for i = 1, jobs do
				local job = pool.submitted[i]
				if job.kind == "horizon" and table.find(pool.cancelled, job.id) then
					cancelled += 1
				end
			end
			t.eq(cancelled, 1, "the job in flight was cancelled")
		end)
	end)

	--[[ Surface caves: a real cave entrance in the streamer ]]

	--[[
		The way down a real cave entrance (seed `gen`): air carved below the surface that touches
		cave air, found in the chunks around (cx, cz), and the way out from it through carved air
		to the open sky, mouth first; and the cave air it meets ({ x, y, z }).
	]]
	local function entranceWay(gen: any, cx: number, cz: number, r: number): ({ { number } }?, { number }?)
		local chunks: { [number]: any } = {}
		local function chunk(x: number, z: number): any
			local key = Coords.chunkKey(x, z)
			local c = chunks[key]
			if c == nil then
				c = gen.generate(0, x, z, nil, true)
				chunks[key] = c
			end
			return c
		end
		local function block(x: number, y: number, z: number): number
			local c = chunk(x // SIZE, z // SIZE)
			return if y >= c.height then Blocks.AIR else ChunkLayout.get(c.data, x % SIZE, y, z % SIZE)
		end
		local function surface(x: number, z: number): number
			local c = chunk(x // SIZE, z // SIZE)
			return buffer.readu16(c.surface, ((z % SIZE) * SIZE + x % SIZE) * 2)
		end
		local dirs = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }
		local tried: { [string]: boolean } = {}
		local function wayOut(x0: number, y0: number, z0: number): { { number } }?
			local from: { [string]: { number } | false } = { [`{x0},{y0},{z0}`] = false }
			local queue = { { x0, y0, z0 } }
			local head = 1
			while head <= #queue do
				local p = queue[head]
				head += 1
				if p[2] + 1 >= surface(p[1], p[3]) then
					local path = {}
					local q: { number }? = p
					while q do
						table.insert(path, q)
						q = from[`{q[1]},{q[2]},{q[3]}`] or nil
					end
					return path
				end
				for _, d in dirs do
					local x, y, z = p[1] + d[1], p[2] + d[2], p[3] + d[3]
					local k = `{x},{y},{z}`
					if from[k] == nil and block(x, y, z) == Blocks.AIR and y < surface(x, z) then
						from[k] = p
						tried[k] = true
						table.insert(queue, { x, y, z })
					end
				end
			end
			return nil
		end
		for ring = 0, r do
			for dz = -ring, ring do
				for dx = -ring, ring do
					if math.abs(dx) ~= ring and math.abs(dz) ~= ring then
						continue
					end
					local c = chunk(cx + dx, cz + dz)
					for z = 0, SIZE - 1 do
						for x = 0, SIZE - 1 do
							local top = buffer.readu16(c.surface, (z * SIZE + x) * 2)
							for y = math.max(c.solidBelow, 1), top - 1 do
								local wx, wz = (cx + dx) * SIZE + x, (cz + dz) * SIZE + z
								if ChunkLayout.get(c.data, x, y, z) ~= Blocks.AIR or tried[`{wx},{y},{wz}`] then
									continue
								end
								for _, d in dirs do
									if block(wx + d[1], y + d[2], wz + d[3]) == Blocks.CAVE_AIR then
										local path = wayOut(wx, y, wz)
										if path then
											return path, { wx + d[1], y + d[2], wz + d[3] }
										end
										break
									end
								end
							end
						end
					end
				end
			end
		end
		return nil, nil
	end

	t.test("streamer: walking down a real cave entrance reveals the cave beyond within frames", function()
		local gen = TerrainGenerator.new(12345)
		local path, cave = entranceWay(gen, 0, 6, 5)
		assert(path and cave, "a cave entrance near chunk 0, 6")
		local mouth = path[1]
		local caveX, caveZ, caveS = cave[1] // SIZE, cave[3] // SIZE, cave[2] // SECTION
		simulate(mouth[1] + 0.5, mouth[3] + 0.5, function(sim)
			-- Standing at the mouth: above ground, nothing revealed, the cave drawn as rock.
			sim.eyeY = gen.column(mouth[1], mouth[3]) + 1.6
			sim:place(mouth[1] + 0.5, mouth[3] + 0.5)
			t.ok(settle(sim, true), "settles above ground")
			local streamer = sim.streamer
			t.eq(streamer.caveView, nil, "above ground")
			t.eq(streamer.cave.count, 0, "nothing revealed")
			-- Down the entrance at a run (a block every 4 frames), to where it meets the cave.
			local on, shown, most, under = nil, nil, 0, nil
			for _, c in path do
				sim.eyeY = c[2] + 0.6
				sim:place(c[1] + 0.5, c[3] + 0.5)
				if under == nil and sim.eyeY < gen.column(c[1], c[3]) - 1 then
					-- (The eye is below its column's surface from the next frame on.)
					under = sim.frame + 1
				end
				for _ = 1, 4 do
					sim:step()
					if on == nil and streamer.caveView ~= nil then
						on = sim.frame
					end
					if shown == nil and (liveReveal(sim, caveX, caveZ, caveS)) then
						shown = sim.frame
					end
					most = math.max(most, streamer:stats().reached)
				end
			end
			assert(on and under, "the cave view came on in the entrance")
			t.ok(shown ~= nil, "the cave beyond is revealed on screen")
			print(
				string.format(
					"    entrance %d,%d,%d (%d blocks): cave view on %d frames after the eye went under, the cave on screen %d frames later; at most %d sections reached",
					mouth[1],
					mouth[2],
					mouth[3],
					#path,
					on - under,
					(shown or 0) - on,
					most
				)
			)
			-- (The cave view is judged every refresh: Streaming.UpdateInterval.)
			local refresh = math.ceil(Config.Streaming.UpdateInterval * 60) + 1
			t.ok(on >= under and on - under <= refresh, "on as the eye goes below the surface")
			t.ok(shown ~= nil and shown - on <= 30, "the cave beyond on screen within half a second")
			t.ok(most < 600, "the search stays out of the sky")
			t.ok(settle(sim), "settles")
			t.eq(sim.voids, 0, "never open onto the void")
			t.eq(sim.gaps, 0, "no gaps")
			t.eq(sim.overlaps, 0, "no overlaps")
		end, 256, nil, gen)
	end)

	t.test("streamer: on real terrain the Caves setting switches both ways, generating nothing again", function()
		local gen = TerrainGenerator.new(12345)
		local path = entranceWay(gen, 0, 6, 5)
		assert(path, "a cave entrance near chunk 0, 6")
		local mouth = path[1]
		simulate(mouth[1] + 0.5, mouth[3] + 0.5, function(sim)
			-- Above ground at a cave entrance's mouth: nothing revealed, then every cave shown.
			sim.eyeY = gen.column(mouth[1], mouth[3]) + 1.6
			sim:place(mouth[1] + 0.5, mouth[3] + 0.5)
			t.ok(settle(sim, true), "settles above ground")
			local streamer = sim.streamer
			for _, value in { 1, 0 } do
				local submitted, frame = #sim.pool.submitted, sim.frame
				sim.values.alwaysCaves = value
				streamer:applyView()
				local t0 = os.clock()
				sim:step()
				local ms = (os.clock() - t0) * 1000
				t.ok(settle(sim), "settles")
				local jobs, sections, generated = 0, 0, 0
				for i = submitted + 1, #sim.pool.submitted do
					local job = sim.pool.submitted[i]
					if job.kind == "mesh" then
						jobs += 1
						sections += #job.sections
					elseif job.kind == "generate" then
						generated += 1
					end
				end
				-- Sections holding terrain (below emptyAbove), and how many the jobs were told shown.
				local chunks, terrain, wrong = 0, 0, 0
				for _, node in streamer.nodes do
					if node.level == 0 and node.shown then
						chunks += 1
						for s = 0, math.ceil(node.chunk.emptyAbove / SECTION) - 1 do
							terrain += 1
							if (node.reveal[s] == true) ~= (value == 1) then
								wrong += 1
							end
						end
					end
				end
				print(
					string.format(
						"    real terrain, to %s: %d chunks, %d sections of terrain, %d mesh jobs, %d sections remeshed, settled in %d frames; the switching frame %.1f ms",
						if value == 1 then "always shown" else "hidden",
						chunks,
						terrain,
						jobs,
						sections,
						sim.frame - frame,
						ms
					)
				)
				t.eq(generated, 0, "nothing generated again")
				t.eq(wrong, 0, "every section of terrain meshed as the setting says")
				t.ok(sections >= terrain and sections <= terrain * 2, "each remeshed once, or twice for a cap")
				t.eq(sim.voids, 0, "never open onto the void")
			end
			t.eq(sim.gaps, 0, "no gaps")
			t.eq(sim.overlaps, 0, "no overlaps")
		end, 256, nil, gen)
	end)

	-- Full detail chunks in a selection (node key -> level).
	local function fullDetailCount(nodes: { [number]: number }): number
		local n = 0
		for _, level in nodes do
			if level == 0 then
				n += 1
			end
		end
		return n
	end

	--[[
		Steps from above ground at (x, z) down to an eye at `eyeY` under the open sky (a pit's open
		mouth, a ravine's floor) in a settled streamer on the real generator: the cave view comes on
		but full detail stays as above ground (the underground split needs the camera shut in:
		CaveReach.enclosed). The cave view setting is 128 blocks, so the underground split is wider.
	]]
	local function stepUnderOpenSky(sim: any, gen: any, x: number, z: number, eyeY: number, label: string)
		local streamer = sim.streamer
		local plain = fullDetailCount(LodTree.select(x, z, nil, false))
		local wider = fullDetailCount(LodTree.select(x, z, nil, true))
		t.ok(wider > plain, `{label}: the underground split is wider`)
		sim.eyeY = eyeY
		sim:place(x, z)
		local on, split = false, false
		for _ = 1, 60 do
			sim:step()
			on = on or streamer.caveView ~= nil
			split = split or streamer.underground
		end
		t.ok(eyeY < gen.column(math.floor(x), math.floor(z)) - 1 and on, `{label}: the cave view comes on`)
		t.ok(not CaveReach.enclosed(function(bx, by, bz)
			return sim.world:getBlock(bx, by, bz)
		end, x, eyeY, z, gen.column(math.floor(x), math.floor(z))), `{label}: under the open sky`)
		print(
			string.format(
				"    %s, eye %.1f under the surface: %d full detail chunks (above ground %d, underground split %d)",
				label,
				gen.column(math.floor(x), math.floor(z)) - eyeY,
				fullDetailCount(streamer.desired),
				plain,
				wider
			)
		)
		t.ok(not split, `{label}: no underground split`)
		t.ok(fullDetailCount(streamer.desired) <= plain, `{label}: full detail as above ground`)
	end

	t.test("streamer: under the open sky of a pit or a ravine full detail stays; shut in it reaches further", function()
		local gen = TerrainGenerator.new(12345)
		-- A pit: the way down a real cave entrance, its mouth open to the sky.
		local path, cave = entranceWay(gen, 0, 6, 5)
		assert(path and cave, "a cave entrance near chunk 0, 6")
		local mouth = path[1]
		simulate(mouth[1] + 0.5, mouth[3] + 0.5, function(sim)
			sim.values.caveView = 128
			sim.streamer:applyView()
			sim.eyeY = gen.column(mouth[1], mouth[3]) + 1.6
			sim:place(mouth[1] + 0.5, mouth[3] + 0.5)
			t.ok(settle(sim, true), "settles above ground")
			local function getBlock(bx: number, by: number, bz: number): number?
				return sim.world:getBlock(bx, by, bz)
			end
			-- The first step of the way down under the generated surface but open to the sky.
			local open = nil
			for i, c in path do
				local surface = gen.column(c[1], c[3])
				local eye = c[2] + 0.6
				if eye < surface - 1 and not CaveReach.enclosed(getBlock, c[1] + 0.5, eye, c[3] + 0.5, surface) then
					open = i
					break
				end
			end
			assert(open, "the entrance's mouth is open to the sky below the surface")
			local c = path[open]
			stepUnderOpenSky(sim, gen, c[1] + 0.5, c[3] + 0.5, c[2] + 0.6, "pit")
			-- On down the entrance into the cave: shut in, full detail reaches further.
			for i = open + 1, #path do
				c = path[i]
				sim.eyeY = c[2] + 0.6
				sim:place(c[1] + 0.5, c[3] + 0.5)
				sim:run(4)
			end
			sim.eyeY = cave[2] + 0.6
			sim:place(cave[1] + 0.5, cave[3] + 0.5)
			sim:run(30)
			local streamer = sim.streamer
			t.ok(streamer.caveView ~= nil and streamer.caveView.enclosed, "in the cave: shut in")
			t.ok(streamer.underground, "the underground split")
			local plain = fullDetailCount(LodTree.select(cave[1] + 0.5, cave[3] + 0.5, nil, false))
			t.ok(fullDetailCount(streamer.desired) > plain, "full detail reaches further")
			t.ok(settle(sim), "settles")
			t.eq(sim.voids, 0, "never open onto the void")
			t.eq(sim.overlaps, 0, "no overlaps")
		end, 256, nil, gen)

		-- A ravine: the deepest cut open to the sky in chunks every 2 near 540, -420.
		local best, camera = 0, nil
		for cz = -30, -24, 2 do
			for cx = 30, 38, 2 do
				local r = gen.generate(0, cx, cz, nil, true)
				for z = 0, SIZE - 1 do
					for x = 0, SIZE - 1 do
						local top = buffer.readu16(r.surface, (z * SIZE + x) * 2)
						local y = top - 1
						while y > 0 and ChunkLayout.get(r.data, x, y, z) == Blocks.AIR do
							y -= 1
						end
						if top - 1 - y > best then
							best, camera = top - 1 - y, { cx * SIZE + x, y + 1, cz * SIZE + z }
						end
					end
				end
			end
		end
		assert(camera and best >= 15, `a ravine near 540, -420 (deepest cut {best})`)
		local x, z = camera[1] + 0.5, camera[3] + 0.5
		simulate(x, z, function(sim)
			sim.values.caveView = 128
			sim.streamer:applyView()
			sim.eyeY = gen.column(camera[1], camera[3]) + 1.6
			sim:place(x, z)
			t.ok(settle(sim, true), "settles above the ravine")
			stepUnderOpenSky(sim, gen, x, z, camera[2] + 0.6, "ravine")
			t.eq(sim.overlaps, 0, "no overlaps")
		end, 256, nil, gen)
	end)
end
