--[[
	The client render pipeline (Rendering/): SectionDiff, RenderSchedule, FrameBudget and
	MeshRegions as pure modules, and ChunkRenderer, PartPool and MeshOverlay in a simulation with
	fake instances (FakeWorld below: parenting, cloning, destroying, a frame counter and a clock
	that advances with every instance operation).

	The simulation checks, frame by frame, what the player would see:
	  * no gaps: with an engine that draws newly parented parts up to L frames late (L <= Render.
	    SwapFrames), every cube box (opaque or see-through: water, glass) that was live L frames
	    ago is still drawn by a part that has been in the workspace for L frames, through edits,
	    LOD swaps and restyles;
	  * lights never double: at most one enabled PointLight per position in the workspace;
	  * quarantine: no part is handed out in the frame it was released, nor while in the workspace;
	  * diffs: after any sequence of edits the parts on screen equal a fresh build of the final
	    meshes (positions, sizes, looks, tints, scatter);
	and the budgets: parts unparented per frame, release time per frame, edit latency, commit
	groups going live together, priorities, the swap delay, teleport trash, restyles, and the far
	mesh overlay's demotion delay, gating and settings switch.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame

--[[ FakeWorld: just enough of Roblox's instances for the renderer ]]

type Fake = any

local CLASS_PARTS: { [string]: boolean } = { Part = true, MeshPart = true }

local function newWorld(shared: any): any
	local world: any = {
		-- The frame being prepared: actions between steps belong to the next step.
		frame = 1,
		clock = 0,
		-- Seconds per operation (rough guesses: only budgets compare against them).
		costs = {
			write = 1e-6,
			parent = 2e-6,
			new = 8e-6,
			clone = 12e-6,
			child = 4e-6,
			destroy = 2e-6,
			call = 0.3e-6,
			clock = 0.02e-6,
		},
		count = { writes = 0, parents = 0, clones = 0, destroys = 0, destroyCalls = 0, entered = 0, left = 0 },
		warnings = {},
	}
	local costs = world.costs
	local count = world.count
	local methods: { [string]: (...any) -> ...any } = {}
	local meta: any = {}
	local DEFAULTS: { [string]: any } = {
		CastShadow = true,
		Transparency = 0,
		Enabled = true,
		Shadows = false,
		Anchored = false,
		CanCollide = true,
		Size = Vector3.new(4, 1, 2),
	}

	local function new(class: string): Fake
		return setmetatable({
			__class = class,
			__props = {},
			__children = {},
			__parent = nil,
			__destroyed = false,
			__at = 0,
			__slot = 0,
		}, meta)
	end
	world.new = new

	local function inWorkspace(o: Fake): boolean
		local p = o
		while p ~= nil do
			if p == world.workspace then
				return true
			end
			p = rawget(p, "__parent")
		end
		return false
	end
	world.inWorkspace = inWorkspace

	local function partsUnder(o: Fake): number
		local n = if CLASS_PARTS[rawget(o, "__class")] then 1 else 0
		for _, child in rawget(o, "__children") do
			n += partsUnder(child)
		end
		return n
	end
	world.partsUnder = partsUnder

	local function detach(o: Fake)
		local old = rawget(o, "__parent")
		if old == nil then
			return
		end
		local list = rawget(old, "__children")
		local i = rawget(o, "__slot")
		local last = list[#list]
		list[i] = last
		rawset(last, "__slot", i)
		list[#list] = nil
		rawset(o, "__parent", nil)
	end

	local function attach(o: Fake, p: Fake)
		local list = rawget(p, "__children")
		table.insert(list, o)
		rawset(o, "__slot", #list)
		rawset(o, "__parent", p)
	end

	local function setParent(o: Fake, p: Fake?)
		if rawget(o, "__destroyed") then
			error(`The Parent property of {tostring(o)} is locked`, 3)
		end
		world.clock += costs.parent
		count.parents += 1
		local old = rawget(o, "__parent")
		if old == p then
			return
		end
		local was = inWorkspace(o)
		detach(o)
		if p ~= nil then
			assert(not rawget(p, "__destroyed"), "parented into a destroyed instance")
			attach(o, p)
		end
		rawset(o, "__at", world.frame)
		local is = inWorkspace(o)
		if was ~= is then
			local n = partsUnder(o)
			if is then
				count.entered += n
			else
				count.left += n
			end
		end
	end

	meta.__index = function(o: Fake, key: string): any
		local m = methods[key]
		if m then
			return m
		end
		if key == "Parent" then
			return rawget(o, "__parent")
		elseif key == "ClassName" then
			return rawget(o, "__class")
		end
		local props = rawget(o, "__props")
		local v = props[key]
		if v ~= nil then
			return v
		end
		if key == "Name" then
			return rawget(o, "__class")
		elseif key == "Position" then
			local cf = props.CFrame
			return if cf then cf.Position else Vector3.zero
		elseif key == "CFrame" then
			return CFrame.new()
		end
		return DEFAULTS[key]
	end
	meta.__newindex = function(o: Fake, key: string, value: any)
		if key == "Parent" then
			setParent(o, value)
			return
		end
		world.clock += costs.write
		count.writes += 1
		rawget(o, "__props")[key] = value
	end
	meta.__tostring = function(o: Fake): string
		return rawget(o, "__props").Name or rawget(o, "__class")
	end

	local function markDestroyed(o: Fake): number
		local n = 1
		rawset(o, "__destroyed", true)
		for _, child in rawget(o, "__children") do
			rawset(child, "__parent", nil)
			n += markDestroyed(child)
		end
		rawset(o, "__children", {})
		return n
	end

	methods.Destroy = function(o: Fake)
		if rawget(o, "__destroyed") then
			return
		end
		local was = inWorkspace(o)
		if was then
			count.left += partsUnder(o)
		end
		count.destroyCalls += 1
		local parts = partsUnder(o)
		detach(o)
		markDestroyed(o)
		count.destroys += parts
		world.clock += costs.destroy * math.max(1, parts)
	end
	local function clone(o: Fake): Fake
		local c = new(rawget(o, "__class"))
		local props = rawget(c, "__props")
		for k, v in rawget(o, "__props") do
			props[k] = v
		end
		for _, child in rawget(o, "__children") do
			attach(clone(child), c)
			world.clock += costs.child
		end
		return c
	end
	methods.Clone = function(o: Fake): Fake
		world.clock += costs.clone
		count.clones += 1
		return clone(o)
	end
	methods.GetChildren = function(o: Fake): { Fake }
		world.clock += costs.call
		return table.clone(rawget(o, "__children"))
	end
	methods.FindFirstChildOfClass = function(o: Fake, class: string): Fake?
		world.clock += costs.call
		for _, child in rawget(o, "__children") do
			if rawget(child, "__class") == class then
				return child
			end
		end
		return nil
	end
	methods.FindFirstChild = function(o: Fake, name: string): Fake?
		world.clock += costs.call
		for _, child in rawget(o, "__children") do
			if child.Name == name then
				return child
			end
		end
		return nil
	end
	methods.IsA = function(o: Fake, class: string): boolean
		local mine = rawget(o, "__class")
		return class == "Instance" or mine == class or (class == "BasePart" and CLASS_PARTS[mine] == true)
	end
	methods.IsDescendantOf = function(o: Fake, ancestor: Fake): boolean
		local p = rawget(o, "__parent")
		while p ~= nil do
			if p == ancestor then
				return true
			end
			p = rawget(p, "__parent")
		end
		return false
	end

	world.Instance = {
		new = function(class: string): Fake
			world.clock += costs.new
			return new(class)
		end,
	}
	local workspace = new("Workspace")
	world.workspace = workspace
	local camera = new("Camera")
	rawget(camera, "__props").CFrame = CFrame.new(0, 100, 0)
	rawget(workspace, "__props").CurrentCamera = camera
	world.camera = camera

	local services: { [string]: any } = {
		ReplicatedStorage = {
			WaitForChild = function(_, name: string)
				assert(name == "IceVoxel")
				return shared
			end,
		},
		RunService = {
			Heartbeat = {
				Connect = function()
					return { Disconnect = function() end }
				end,
			},
		},
		MaterialService = {
			GetMaterialVariant = function()
				return nil
			end,
		},
		Lighting = new("Lighting"),
		UserInputService = { TouchEnabled = false, KeyboardEnabled = true },
		AssetService = {},
		Players = {},
	}
	world.game = {
		GetService = function(_, name: string)
			local service = services[name]
			assert(service, `no fake service {name}`)
			return service
		end,
	}
	world.os = {
		clock = function(): number
			world.clock += costs.clock
			return world.clock
		end,
		time = os.time,
	}
	world.task = {
		spawn = function() end,
		defer = function() end,
		wait = function()
			return 0
		end,
	}
	world.warn = function(...)
		table.insert(world.warnings, table.concat({ ... }, " "))
	end
	-- Frame since which an instance is drawn (the latest parenting on its way up), or nil.
	function world.drawnSince(o: Fake): number?
		local at = 0
		local p = o
		while p ~= nil do
			if p == workspace then
				return at
			end
			at = math.max(at, rawget(p, "__at"))
			p = rawget(p, "__parent")
		end
		return nil
	end
	-- Every part in the workspace, with the frame it is drawn since.
	function world.visibleParts(): { [Fake]: number }
		local out = {}
		local function visit(o: Fake, at: number)
			local here = math.max(at, rawget(o, "__at"))
			if CLASS_PARTS[rawget(o, "__class")] then
				out[o] = here
			end
			for _, child in rawget(o, "__children") do
				visit(child, here)
			end
		end
		for _, child in rawget(workspace, "__children") do
			visit(child, 0)
		end
		return out
	end
	return world
end

-- Arguments every client module gets (as locals, like tests/lib/Loader: fast builtins stay on).
local GLOBALS =
	"script, require, game, workspace, Instance, Vector3, Vector2, CFrame, Color3, UDim2, Enum, Content, os, task, warn"

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

-- Loads src/client/Rendering modules into `world` (shared modules come from the runner's require).
local function rendering(world: any, shared: any, sharedRequire: (any) -> any): (name: string) -> any
	local cache: { [any]: any } = {}
	local folder: any = {}
	local scripts: { [string]: any } = {}
	local function scriptOf(name: string): any
		local s = scripts[name]
		if s == nil then
			s = { __fake = true, Name = name, Parent = folder, path = `src/client/Rendering/{name}.luau` }
			scripts[name] = s
		end
		return s
	end
	setmetatable(folder, {
		__index = function(_, name: string)
			return scriptOf(name)
		end,
	})
	local function req(node: any): any
		if type(node) == "table" and rawget(node, "__fake") then
			local cached = cache[node]
			if cached ~= nil then
				return cached
			end
			local source = sources[node.path]
			if source == nil then
				source = withHeader(fs.readFile(node.path))
				sources[node.path] = source
			end
			local chunk = luau.load(source, { debugName = node.path })
			local result = chunk(
				node,
				req,
				world.game,
				world.workspace,
				world.Instance,
				roblox.Vector3,
				roblox.Vector2,
				roblox.CFrame,
				roblox.Color3,
				roblox.UDim2,
				roblox.Enum,
				{ fromObject = function() end },
				world.os,
				world.task,
				world.warn
			)
			cache[node] = result
			return result
		end
		return sharedRequire(node)
	end
	return function(name: string): any
		return req(scriptOf(name))
	end
end

return function(t, shared, require, _server, client)
	local Config = require(shared.Config)
	local Blocks = require(shared.Blocks)
	local GreedyMesher = require(shared.Meshing.GreedyMesher)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local LodTree = require(shared.World.LodTree)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)
	local SectionDiff = require(client.Rendering.SectionDiff)
	local FrameBudget = require(client.Rendering.FrameBudget)
	local RenderSchedule = require(client.Rendering.RenderSchedule)
	local MeshRegions = require(client.Rendering.MeshRegions)

	local BOX = GreedyMesher.BOX_BYTES
	local SIZE = Config.ChunkSize
	local SECTION = Config.SectionHeight
	local BLOCK = Config.BlockSize
	local B = Blocks.id
	local Render = Config.Render

	-- Runs `fn` with Config.Render values changed, putting them back afterwards.
	local function withRender(values: { [string]: any }, fn: () -> ())
		local saved = {}
		for k, v in values do
			saved[k] = Render[k]
			Render[k] = v
		end
		local ok, err = pcall(fn)
		for k, v in saved do
			Render[k] = v
		end
		if not ok then
			error(err, 0)
		end
	end

	-- Deterministic pseudo random numbers.
	local function rng(seed: number): (n: number) -> number
		local state = seed
		return function(n: number): number
			state = (state * 1103515245 + 12345) % 2147483648
			return (state // 65536) % n
		end
	end

	local function boxesOf(list: { { number } }): buffer
		local b = buffer.create(#list * BOX)
		for i, box in list do
			for k = 1, 7 do
				buffer.writeu16(b, (i - 1) * BOX + (k - 1) * 2, box[k])
			end
		end
		return b
	end

	local stoneApp = Blocks.get(B.Stone).appearance
	local glowApp = Blocks.get(B.GlowBlock).appearance

	--[[ SectionDiff ]]

	t.test("section diff: identical boxes keep their parts, the rest is added or removed", function()
		local old = boxesOf({
			{ 0, 0, 0, 1, 1, 1, stoneApp },
			{ 1, 0, 0, 1, 1, 1, stoneApp },
			{ 0, 0, 0, 1, 1, 1, stoneApp }, -- a duplicate pairs once
			{ 5, 5, 5, 2, 2, 2, glowApp },
		})
		local new = boxesOf({
			{ 5, 5, 5, 2, 2, 2, glowApp },
			{ 0, 0, 0, 1, 1, 1, stoneApp },
			{ 9, 0, 0, 1, 1, 1, stoneApp },
		})
		local matched, removed, kept = SectionDiff.match(old, 4, new, 3)
		t.eq(kept, 2)
		t.eq(matched[1], 3, "moved box found")
		t.eq(matched[2], 0, "first of the equal boxes")
		t.eq(matched[3], -1, "new box built")
		t.eq(#removed, 2)
		t.eq(removed[1], 1)
		t.eq(removed[2], 2)
	end)

	t.test("section diff: random meshes match a multiset count", function()
		local rand = rng(7)
		for _ = 1, 200 do
			local oldList, newList = {}, {}
			for _ = 1, rand(40) do
				table.insert(oldList, { rand(4), rand(3), 0, 1, 1 + rand(2), 1, stoneApp + rand(2) })
			end
			for _ = 1, rand(40) do
				table.insert(newList, { rand(4), rand(3), 0, 1, 1 + rand(2), 1, stoneApp + rand(2) })
			end
			local old, new = boxesOf(oldList), boxesOf(newList)
			local matched, removed, kept = SectionDiff.match(old, #oldList, new, #newList)
			local counts: { [string]: number } = {}
			for i = 0, #oldList - 1 do
				local k = buffer.readstring(old, i * BOX, BOX)
				counts[k] = (counts[k] or 0) + 1
			end
			local expectKept = 0
			for i = 0, #newList - 1 do
				local k = buffer.readstring(new, i * BOX, BOX)
				if (counts[k] or 0) > 0 then
					counts[k] -= 1
					expectKept += 1
				end
			end
			t.eq(kept, expectKept, "kept")
			t.eq(#removed, #oldList - kept, "removed")
			local used = {}
			for i, j in matched do
				if j >= 0 then
					t.ok(not used[j], "an old box kept once")
					used[j] = true
					t.eq(buffer.readstring(old, j * BOX, BOX), buffer.readstring(new, (i - 1) * BOX, BOX), "same bytes")
				end
			end
			for _, j in removed do
				t.ok(not used[j], "removed boxes are not kept")
			end
		end
	end)

	--[[ RenderSchedule ]]

	local function task(node: any, section: number, lane: number, group: any?, priority: number?): any
		return {
			node = node,
			section = section,
			lane = lane,
			priority = priority,
			group = group,
			state = 0,
			seq = 0,
			data = nil,
		}
	end

	t.test("schedule: lanes in order, by priority, edits first in first out", function()
		local s = RenderSchedule.new()
		local far, near, mid = { priority = 9 }, { priority = 1 }, { priority = 5 }
		s:add(task(far, 0, RenderSchedule.NORMAL))
		s:add(task(near, 0, RenderSchedule.NORMAL))
		s:add(task(near, 1, RenderSchedule.NORMAL))
		s:add(task(mid, 0, RenderSchedule.NORMAL))
		local e1 = task({}, 0, RenderSchedule.EDIT)
		local e2 = task({}, 0, RenderSchedule.EDIT)
		s:add(e1)
		s:add(e2)
		t.eq(s:count(), 6)
		t.eq(s:peek(RenderSchedule.EDIT), e1)
		s:pop(RenderSchedule.EDIT)
		t.eq(s:peek(RenderSchedule.EDIT), e2)
		s:pop(RenderSchedule.EDIT)
		t.eq(s:peek(RenderSchedule.EDIT), nil)
		local order = {}
		while true do
			local next = s:peek(RenderSchedule.NORMAL)
			if next == nil then
				break
			end
			s:pop(RenderSchedule.NORMAL)
			table.insert(order, `{next.node.priority}:{next.section}`)
		end
		t.eq(table.concat(order, " "), "1:0 1:1 5:0 9:0", "node priority, then arrival")

		-- Priorities change: reprioritise re-sorts.
		local a, b = { priority = 1 }, { priority = 2 }
		s:add(task(a, 0, RenderSchedule.NORMAL))
		s:add(task(b, 0, RenderSchedule.NORMAL))
		a.priority = 3
		s:reprioritise()
		t.eq(s:peek(RenderSchedule.NORMAL).node, b, "re-sorted")
		-- A task's own priority wins over its node's.
		local c = { priority = 100 }
		s:add(task(c, 0, RenderSchedule.NEAR, nil, 0.5))
		s:add(task(b, 1, RenderSchedule.NEAR))
		t.eq(s:peek(RenderSchedule.NEAR).node, c)
	end)

	t.test("schedule: one uncommitted task per section, newer ones wait or replace", function()
		local s = RenderSchedule.new()
		local node = { priority = 0 }
		local first = task(node, 3, RenderSchedule.EDIT)
		s:add(first)
		local second = task(node, 3, RenderSchedule.EDIT)
		t.eq(s:add(second), nil)
		t.eq(second.state, RenderSchedule.PARKED, "waits")
		local third = task(node, 3, RenderSchedule.EDIT)
		local replaced = s:add(third)
		t.ok(
			replaced and #replaced == 1 and replaced[1] == second,
			"an ungrouped waiting task is replaced by a newer one"
		)
		t.eq(second.state, RenderSchedule.DROPPED)
		t.eq(s:peek(RenderSchedule.EDIT), first)
		s:pop(RenderSchedule.EDIT)
		local live = s:stage(first)
		t.eq(live and #live, 1)
		t.eq(s:peek(RenderSchedule.EDIT), nil, "third waits for the commit")
		s:committed(first)
		t.eq(s:peek(RenderSchedule.EDIT), third)
		t.eq(s:count(), 1)
	end)

	t.test("schedule: commit groups go live together; holds; drops; timeouts", function()
		local s = RenderSchedule.new()
		local a, b = { priority = 0 }, { priority = 0 }
		local g = s:openGroup(0)
		local ta = task(a, 0, RenderSchedule.EDIT, g)
		local tb = task(b, 0, RenderSchedule.NEAR, g)
		s:add(ta)
		s:add(tb)
		s:pop(RenderSchedule.EDIT)
		t.eq(s:stage(ta), nil, "waits for the rest of the group")
		s:pop(RenderSchedule.NEAR)
		t.eq(s:stage(tb), nil, "and for the opener's hold")
		local live = s:close(g)
		t.ok(live and #live == 2 and live[1] == ta and live[2] == tb, "both, in order")
		s:committed(ta)
		s:committed(tb)
		t.eq(s:count(), 0)

		-- A dropped node no longer holds the group back.
		local g2 = s:openGroup(0)
		local c, d = { priority = 0 }, { priority = 0 }
		local tc = task(c, 0, RenderSchedule.EDIT, g2)
		local td = task(d, 0, RenderSchedule.EDIT, g2)
		s:add(tc)
		s:add(td)
		t.eq(s:close(g2), nil)
		s:pop(RenderSchedule.EDIT)
		t.eq(s:stage(tc), nil)
		local dropped, ready = s:drop(d)
		t.eq(#dropped, 1)
		t.eq(#ready, 1, "the rest goes live")
		t.eq(ready[1], tc)
		s:committed(tc)

		-- A group whose job never comes back stops waiting after the timeout.
		local g3 = s:openGroup(10)
		s:hold(g3)
		local e = { priority = 0 }
		local te = task(e, 0, RenderSchedule.EDIT, g3)
		s:add(te)
		s:pop(RenderSchedule.EDIT)
		t.eq(s:stage(te), nil)
		t.eq(#s:expire(11, 2), 0, "not yet")
		local expired = s:expire(12.5, 2)
		t.eq(#expired, 1)
		s:committed(te)
		-- Later tasks of a timed-out group go live alone.
		local tf = task({ priority = 0 }, 0, RenderSchedule.EDIT, g3)
		s:add(tf)
		s:pop(RenderSchedule.EDIT)
		t.eq(#(s:stage(tf) :: { any }), 1)
	end)

	t.test("schedule: a newer task of the same group replaces the uncommitted one (no deadlock)", function()
		local s = RenderSchedule.new()
		local node = { priority = 0 }
		local g = s:openGroup(0)
		local one = task(node, 0, RenderSchedule.EDIT, g)
		s:add(one)
		s:pop(RenderSchedule.EDIT)
		t.eq(s:stage(one), nil)
		local two = task(node, 0, RenderSchedule.EDIT, g)
		local replaced = s:add(two)
		t.ok(replaced and #replaced == 1 and replaced[1] == one, "replaced")
		s:pop(RenderSchedule.EDIT)
		t.eq(s:stage(two), nil)
		local live = s:close(g)
		t.ok(live and #live == 1 and live[1] == two)
	end)

	-- Builds every queued task, most urgent lane first; returns the tasks to put live.
	local function buildAll(s: any, now: number): { any }
		local live = {}
		for lane = RenderSchedule.EDIT, RenderSchedule.BACKGROUND do
			while true do
				local next = s:peek(lane)
				if next == nil then
					break
				end
				s:pop(lane)
				for _, x in s:stage(next) or {} do
					table.insert(live, x)
				end
			end
		end
		for _, x in s:expire(now, 2) do
			table.insert(live, x)
		end
		return live
	end

	t.test("schedule: two tasks of one group behind another group's staged task go live with it", function()
		local s = RenderSchedule.new()
		local a, b = { priority = 0 }, { priority = 0 }
		-- A cave reveal pass (group h) staged on a, waiting for the pass's other jobs.
		local h = s:openGroup(0)
		local reveal = task(a, 3, RenderSchedule.NEAR, h)
		s:add(reveal)
		t.eq(#buildAll(s, 0), 0, "staged")
		-- An edit batch (g) with two jobs for a (a joined the open batch again) and one for b.
		local g = s:openGroup(0.1)
		local one, two, other =
			task(a, 3, RenderSchedule.EDIT, g), task(a, 3, RenderSchedule.EDIT, g), task(b, 3, RenderSchedule.EDIT, g)
		s:add(one)
		local replaced = s:add(two)
		t.ok(replaced and #replaced == 1 and replaced[1] == one, "the older task of the group is dropped")
		s:add(other)
		t.eq(s:close(g), nil, "b is not built yet")
		local live = s:close(h) :: { any }
		t.ok(live and #live == 1 and live[1] == reveal)
		s:committed(reveal)
		live = buildAll(s, 0.2)
		t.ok(
			#live == 2 and live[1] == two and live[2] == other,
			"the edits go live together at once, not after the timeout"
		)
		for _, x in live do
			s:committed(x)
		end
		t.eq(s:count(), 0)

		-- A group's uncommitted task replaced while an ungrouped task waits behind it: that one
		-- (older than the new task) goes first, so the newest mesh is the last to go live.
		local g2 = s:openGroup(1)
		local first = task(a, 3, RenderSchedule.EDIT, g2)
		s:add(first)
		t.eq(#buildAll(s, 1), 0, "staged, the group is held")
		local seam = task(a, 3, RenderSchedule.NEAR)
		t.eq(s:add(seam), nil, "waits")
		local second = task(a, 3, RenderSchedule.EDIT, g2)
		replaced = s:add(second)
		t.ok(replaced and #replaced == 1 and replaced[1] == first)
		t.eq(seam.state, RenderSchedule.QUEUED, "the waiting task is the section's task now")
		t.eq(second.state, RenderSchedule.PARKED, "the newest waits behind it")
		live = buildAll(s, 1)
		t.ok(#live == 1 and live[1] == seam)
		s:committed(seam)
		t.eq(s:close(g2), nil, "second not staged yet")
		live = buildAll(s, 1)
		t.ok(#live == 1 and live[1] == second, "then the group")
		s:committed(second)

		-- A same-group task parked after an ungrouped one: the group's older task goes, the
		-- ungrouped one keeps its place, the new one waits last.
		local g3 = s:openGroup(2)
		local blocker = s:openGroup(2)
		local staged = task(a, 3, RenderSchedule.NEAR, blocker)
		s:add(staged)
		buildAll(s, 2)
		local x1 = task(a, 3, RenderSchedule.EDIT, g3)
		local plain = task(a, 3, RenderSchedule.NEAR)
		local x2 = task(a, 3, RenderSchedule.EDIT, g3)
		s:add(x1)
		s:add(plain)
		replaced = s:add(x2)
		t.ok(replaced and #replaced == 1 and replaced[1] == x1)
		local order = {}
		for _, x in s:tasksOf(a) do
			table.insert(order, x)
		end
		t.ok(order[1] == staged and order[2] == plain and order[3] == x2, "order kept")
	end)

	t.test("schedule: a queued task not started yet gives way to a newer one, in the more urgent lane", function()
		local started: { [any]: boolean } = {}
		local s = RenderSchedule.new(function(x: any): boolean
			return started[x] == true
		end)
		local node = { priority = 5 }
		-- Skip hidden terrain gives the parts back (background), then the node is seen again.
		local empty = task(node, 0, RenderSchedule.BACKGROUND)
		s:add(empty)
		local content = task(node, 0, RenderSchedule.NORMAL)
		local replaced = s:add(content)
		t.ok(replaced and #replaced == 1 and replaced[1] == empty, "the give-back never runs")
		t.eq(content.state, RenderSchedule.QUEUED)
		t.eq(s:laneCount(RenderSchedule.BACKGROUND), 0)
		t.eq(s:peek(RenderSchedule.NORMAL), content)
		-- The other way round: the give-back takes the content's place, in its lane.
		local back = task(node, 0, RenderSchedule.BACKGROUND)
		replaced = s:add(back)
		t.ok(replaced and replaced[1] == content)
		t.eq(back.lane, RenderSchedule.NORMAL, "at least as urgent as the task it replaced")
		-- Started: the newer one waits.
		started[back] = true
		local later = task(node, 0, RenderSchedule.NORMAL)
		t.eq(s:add(later), nil)
		t.eq(later.state, RenderSchedule.PARKED)
		-- Grouped tasks never replace (or get replaced by) an ungrouped one this way.
		local other = { priority = 0 }
		s:add(task(other, 0, RenderSchedule.NEAR))
		local g = s:openGroup(0)
		local edit = task(other, 0, RenderSchedule.EDIT, g)
		t.eq(s:add(edit), nil)
		t.eq(edit.state, RenderSchedule.PARKED)
	end)

	t.test("schedule: restyles never replace a build and give way to any newer one", function()
		local started: { [any]: boolean } = {}
		local s = RenderSchedule.new(function(x: any): boolean
			return started[x] == true
		end)
		local function restyle(node: any, section: number): any
			local x = task(node, section, RenderSchedule.BACKGROUND)
			x.restyle = true
			return x
		end
		local node = { priority = 0 }
		t.eq(s:startsLater(node, 0), false, "nothing pending")
		-- An edit staged in its group, a near remesh parked behind it: a restyle never replaces it.
		local g = s:openGroup(0)
		local edit = task(node, 0, RenderSchedule.EDIT, g)
		s:add(edit)
		buildAll(s, 0)
		local near = task(node, 0, RenderSchedule.NEAR)
		s:add(near)
		t.ok(s:startsLater(node, 0), "the parked build starts later")
		local r = restyle(node, 0)
		t.eq(s:add(r), nil, "the parked remesh stays")
		t.eq(near.state, RenderSchedule.PARKED)
		-- (The renderer does not add one here; when it waits, the next build replaces it.)
		local seam = task(node, 0, RenderSchedule.NEAR)
		local replaced = s:add(seam)
		t.ok(replaced and replaced[1] == r)
		-- A queued restyle, even started, gives way to an edit (no waiting in the background lane).
		local other = { priority = 0 }
		local r2 = restyle(other, 0)
		s:add(r2)
		started[r2] = true
		t.eq(s:startsLater(other, 0), false, "started: a restyle may still be needed")
		local g2 = s:openGroup(0)
		local edit2 = task(other, 0, RenderSchedule.EDIT, g2)
		replaced = s:add(edit2)
		t.ok(replaced and replaced[1] == r2, "replaced")
		t.eq(edit2.lane, RenderSchedule.EDIT)
		t.eq(s:peek(RenderSchedule.EDIT), edit2)
		t.eq(s:laneCount(RenderSchedule.BACKGROUND), 0)
		-- A queued build not started yet: startsLater.
		local third = { priority = 0 }
		s:add(task(third, 1, RenderSchedule.NORMAL))
		t.ok(s:startsLater(third, 1))
	end)

	--[[ FrameBudget ]]

	t.test("frame budget: grows while work waits and frames have room, shrinks when they run long", function()
		local fb = FrameBudget.new(nil, 4)
		local budget = 4
		-- Vsync 60 Hz, 10 ms of other work: frames stay at 16.7 ms while building fits.
		for _ = 1, 300 do
			local work = 10 + budget
			local frame = math.ceil(work / 16.667) * 16.667
			budget = fb:update(frame, true, false, 4, true)
		end
		-- (It probes the edge of the slack: one raise over it, then back down.)
		t.ok(budget >= 4.5 and budget <= 7, `settles within the slack (got {budget})`)
		-- Nothing waiting: back to the base.
		for _ = 1, 100 do
			budget = fb:update(16.667, false, false, 4, true)
		end
		t.near(budget, 4, 0.1, "base")
		-- Frozen: up to 12 ms.
		for _ = 1, 200 do
			budget = fb:update(16.667 * 2, true, true, 4, true)
		end
		t.near(budget, 12, 1e-6, "frozen limit")
		-- Unfrozen with long frames: down to the minimum.
		for _ = 1, 100 do
			budget = fb:update(40, true, false, 4, true)
		end
		t.near(budget, 2, 1e-6, "minimum")
		-- Fixed budget.
		t.eq(fb:update(16.667, true, true, 3, false), 3)

		-- A device already at 30 fps (20 ms of other work): its pace is the usual one, so the
		-- budget uses the room up to the maximum without making frames longer.
		local slow = FrameBudget.new(nil, 4)
		local b2 = 4
		local longer = 0
		for i = 1, 400 do
			local frame = math.ceil((20 + b2) / 16.667) * 16.667
			if i > 90 and frame > 33.4 then
				longer += 1
			end
			b2 = slow:update(frame, true, false, 4, true)
		end
		t.near(b2, 8, 1e-6, "slow device: maximum")
		t.eq(longer, 0, "no longer frames")
	end)

	t.test("frame budget: camera speed over a window", function()
		local m = FrameBudget.motion(2)
		local speed = 0
		for i = 0, 240 do
			speed = m:update(i * 0.1, 0, 0, i / 60) -- 6 studs/s
		end
		t.near(speed, 6, 0.05, "steady speed")
		for i = 241, 600 do
			speed = m:update(24, 0, 0, i / 60)
		end
		t.near(speed, 0, 1e-9, "standing still")
		-- One jump (teleport) reads as speed for the window only.
		speed = m:update(5000, 0, 0, 601 / 60)
		t.ok(speed > 100)
		for i = 602, 800 do
			speed = m:update(5000, 0, 0, i / 60)
		end
		t.near(speed, 0, 1e-9, "after the window")
	end)

	--[[ MeshRegions additions ]]

	t.test("regions: an aborted build is not a failure; node -> region index", function()
		local r = MeshRegions.new({
			minLevel = 2,
			regionNodes = 4,
			maxRegionBlocks = 512,
			stableSeconds = 1,
			rebuildSeconds = 8,
			nodeSize = LodTree.nodeSize,
		})
		local a = { level = 2, nx = 0, nz = 0 }
		r:add(a, 0)
		t.ok(r:regionOfNode(a) ~= nil)
		local region = r:candidate(2, function()
			return true
		end) :: any
		local job = r:begin(region)
		r:abort(job)
		t.eq(region.building, nil)
		t.eq(region.failures, 0)
		t.eq(
			r:candidate(2, function()
				return true
			end),
			region,
			"tried again at once"
		)
		r:remove(a, 3)
		t.eq(r:regionOfNode(a), nil)
	end)

	--[[ Simulation ]]

	local appearances = Blocks.appearances

	-- Is a box drawn as a single cube part, opaque or see-through (checked for gaps)?
	local function solidCube(appearance: number): boolean
		local info = appearances[appearance]
		return info ~= nil and info.kind ~= Blocks.KIND_NONE and info.shape == nil
	end

	local function round(v: number): number
		return math.round(v * 100) / 100
	end

	local function aabbKey(minX: number, minY: number, minZ: number, maxX: number, maxY: number, maxZ: number): string
		return `{round(minX)},{round(minY)},{round(minZ)}|{round(maxX)},{round(maxY)},{round(maxZ)}`
	end

	local function partKey(part: any): string
		local p = part.Position
		local s = part.Size
		return aabbKey(p.X - s.X / 2, p.Y - s.Y / 2, p.Z - s.Z / 2, p.X + s.X / 2, p.Y + s.Y / 2, p.Z + s.Z / 2)
	end

	local function boxKey(node: any, boxes: buffer, i: number): (string, number)
		local step, stepY = ChunkLayout.steps(node.level)
		local s, sy = step * BLOCK, stepY * BLOCK
		local ox, oz = node.nx * SIZE * s, node.nz * SIZE * s
		local o = i * BOX
		local x, y, z = buffer.readu16(boxes, o), buffer.readu16(boxes, o + 2), buffer.readu16(boxes, o + 4)
		local sx, syy, sz = buffer.readu16(boxes, o + 6), buffer.readu16(boxes, o + 8), buffer.readu16(boxes, o + 10)
		local appearance, surface = GreedyMesher.decodeKey(buffer.readu16(boxes, o + 12))
		-- A fluid surface below the top of its cell (as the renderer draws it).
		local info = appearances[appearance]
		local lower = if surface > 0
				and info
				and info.shape == nil
			then (Blocks.FLUID_FULL - surface) / Blocks.FLUID_FULL * BLOCK
			else 0
		return aabbKey(ox + x * s, y * sy, oz + z * s, ox + (x + sx) * s, (y + syy) * sy - lower, oz + (z + sz) * s),
			appearance
	end

	type Sim = any

	--[[
		A renderer in a fake world. `sim.step(n)` runs frames and checks the invariants after each:
		gaps (for every latency up to `sim.latency`), lights, quarantine (in acquire).
	]]
	local function newSim(): Sim
		local world = newWorld(shared)
		local load = rendering(world, shared, require)
		local ChunkRenderer = load("ChunkRenderer")
		local renderer = ChunkRenderer.new()
		local sim: Sim = {
			world = world,
			load = load,
			renderer = renderer,
			PartPool = load("PartPool"),
			latency = math.max(0, Render.SwapFrames),
			shown = {},
			history = {},
			gaps = 0,
			-- Boxes checked for gaps (frames x boxes x latencies).
			checked = 0,
			gapDetail = nil,
			doubled = 0,
			handedEarly = 0,
			maxLeft = 0,
			maxReleaseMs = 0,
			frames = 0,
		}
		local pool = renderer.pool
		local releasedAt: { [any]: number } = {}
		local release, acquire = pool.release, pool.acquire
		pool.release = function(self, part)
			releasedAt[part] = world.frame
			return release(self, part)
		end
		pool.acquire = function(self, ...)
			local part = acquire(self, ...)
			if releasedAt[part] == world.frame or world.inWorkspace(part) then
				sim.handedEarly += 1
			end
			return part
		end

		-- Shown nodes: node -> { from = frame, to = frame? } (the harness calls show and clear).
		function sim.show(node: any)
			renderer:show(node)
			sim.shown[node] = { from = world.frame, to = nil }
		end
		function sim.clear(node: any)
			node.removed = true
			renderer:clear(node)
			local entry = sim.shown[node]
			if entry then
				entry.to = world.frame
			end
		end

		-- Committed records per (node, section) after every frame: { frame, boxes } lists.
		local function snapshot()
			for node, state in renderer.states do
				local sections = sim.history[node]
				if sections == nil then
					sections = {}
					sim.history[node] = sections
				end
				for section, record in state.records do
					local list = sections[section]
					if list == nil then
						list = {}
						sections[section] = list
					end
					local last = list[#list]
					if last == nil or last.boxes ~= record.boxes then
						table.insert(list, { frame = world.frame, boxes = record.boxes })
					end
				end
				for section, list in sections do
					if state.records[section] == nil and list[#list].boxes ~= nil then
						table.insert(list, { frame = world.frame, boxes = nil })
					end
				end
			end
		end

		local function checkGaps(latency: number)
			local frame = world.frame
			local seen = frame - latency
			local drawn: { [string]: boolean } = {}
			for part, at in world.visibleParts() do
				if at <= seen then
					drawn[partKey(part)] = true
				end
			end
			for node, span in sim.shown do
				if span.from <= seen and (span.to == nil or span.to > seen) then
					for _, list in sim.history[node] or {} do
						-- The record live at frame `seen`.
						local live = nil
						for _, entry in list do
							if entry.frame <= seen then
								live = entry.boxes
							end
						end
						if live then
							for i = 0, buffer.len(live) // BOX - 1 do
								local key, appearance = boxKey(node, live, i)
								if solidCube(appearance) then
									sim.checked += 1
								end
								if solidCube(appearance) and not drawn[key] then
									sim.gaps += 1
									sim.gapDetail = sim.gapDetail
										or `frame {frame} latency {latency}: L{node.level} {node.nx},{node.nz} box {key}`
								end
							end
						end
					end
				end
			end
		end

		local function checkLights()
			local at: { [string]: number } = {}
			for part in world.visibleParts() do
				local light = part:FindFirstChildOfClass("PointLight")
				if light and light.Enabled then
					local p = part.Position
					local key = `{round(p.X)},{round(p.Y)},{round(p.Z)}`
					at[key] = (at[key] or 0) + 1
					if at[key] > 1 then
						sim.doubled += 1
					end
				end
			end
		end

		function sim.step(n: number?, checks: boolean?)
			for _ = 1, n or 1 do
				world.clock = math.max(world.clock, world.frame / 60)
				world.count.left = 0
				sim.frameStart = world.clock
				renderer:step(1 / 60)
				sim.frameCost = world.clock - sim.frameStart
				sim.frames += 1
				sim.maxLeft = math.max(sim.maxLeft, world.count.left)
				snapshot()
				if checks ~= false then
					for latency = 0, sim.latency do
						checkGaps(latency)
					end
					checkLights()
				end
				world.frame += 1
			end
		end

		-- Steps until nothing is left to build, swap or release (at most `limit` frames).
		function sim.settle(limit: number?, checks: boolean?)
			for _ = 1, limit or 2000 do
				if not renderer:busy() then
					sim.step(1, checks)
					return
				end
				sim.step(1, checks)
			end
			error("renderer did not settle")
		end
		return sim
	end

	local function newNode(level: number, nx: number, nz: number, priority: number?): any
		return {
			level = level,
			nx = nx,
			nz = nz,
			removed = false,
			model = nil,
			sections = {},
			priority = priority or 0,
		}
	end

	-- Generated terrain for full detail chunks, meshed by section like the workers do.
	local gen = TerrainGenerator.new(12345)
	local spawnX, _, spawnZ = gen.findSpawn()
	local function terrain(cx: number, cz: number): any
		local r = gen.generate(0, cx, cz)
		return { data = r.data, height = r.height, cx = cx, cz = cz }
	end
	local function meshSection(chunk: any, s: number): buffer
		local y0 = s * SECTION
		local y1 = math.min((s + 1) * SECTION, chunk.height)
		if y1 <= y0 then
			return buffer.create(0)
		end
		local boxes = GreedyMesher.mesh(chunk.data, chunk.height, y0, y1, true, nil, false)
		return boxes
	end
	local function sectionsOf(chunk: any): number
		return (chunk.height + SECTION - 1) // SECTION
	end

	-- Every part of each live section, as sorted signatures (position, size, look, colour).
	local function signatures(renderer: any, node: any): { [number]: string }
		local out = {}
		local state = renderer.states[node]
		for section, record in (state and state.records or {}) :: any do
			local list = {}
			for _, part in record.folder:GetChildren() do
				local cf = part.CFrame
				local key = renderer.pool.keyOf[part]
				local look = renderer.pool.templates[key]
				local c = part.Color or (look and look.Color)
				local comps = { cf:GetComponents() }
				for i, v in comps do
					comps[i] = round(v)
				end
				table.insert(
					list,
					`{key % 100000}|{table.concat(comps, ",")}|{partKey(part)}|{if c then tostring(c) else ""}`
				)
			end
			table.sort(list)
			out[section] = table.concat(list, "\n")
		end
		return out
	end

	t.test("render: in-place edits match a fresh build, no gaps, no doubled lights, quarantine", function()
		local sim = newSim()
		local renderer = sim.renderer
		local cx, cz = spawnX // SIZE, spawnZ // SIZE
		local chunks = { terrain(cx, cz), terrain(cx + 1, cz) }
		local nodes = { newNode(0, cx, cz), newNode(0, cx + 1, cz) }
		local meshes = { {}, {} }
		for k, chunk in chunks do
			for s = 0, sectionsOf(chunk) - 1 do
				meshes[k][s] = meshSection(chunk, s)
				if buffer.len(meshes[k][s]) > 0 then
					renderer:build(nodes[k], s, meshes[k][s])
				end
			end
		end
		sim.settle(nil, false)
		for _, node in nodes do
			sim.show(node)
		end
		sim.step(3)

		local rand = rng(99)
		local touched, full = {}, {}
		local AIR = Blocks.AIR
		local placeIds = { B.Stone, B.GlowBlock, B.Torch, B.Dirt }
		for edit = 1, 160 do
			local k = 1 + rand(2)
			local chunk = chunks[k]
			local lx, lz = rand(SIZE), rand(SIZE)
			local top = chunk.height - 1
			while top > 0 and ChunkLayout.get(chunk.data, lx, top, lz) == AIR do
				top -= 1
			end
			local placing = rand(2) == 0
			local y = if placing then top + 1 else top
			if y <= 0 or y >= chunk.height - 1 then
				continue
			end
			local id = if placing then placeIds[1 + rand(#placeIds)] else AIR
			ChunkLayout.set(chunk.data, lx, y, lz, id)
			-- The neighbour's padding (the two chunks share the x border).
			local dirty: { { number } } = { { k, y // SECTION } }
			if k == 1 and lx == SIZE - 1 then
				ChunkLayout.setPadded(chunks[2].data, -1, y, lz, id)
				table.insert(dirty, { 2, y // SECTION })
			elseif k == 2 and lx == 0 then
				ChunkLayout.setPadded(chunks[1].data, SIZE, y, lz, id)
				table.insert(dirty, { 1, y // SECTION })
			end
			if y % SECTION == 0 then
				table.insert(dirty, { k, y // SECTION - 1 })
			elseif y % SECTION == SECTION - 1 then
				table.insert(dirty, { k, y // SECTION + 1 })
			end
			local group = renderer:openGroup()
			local before = renderer.pool.cloned + renderer.pool.reused
			local parts = 0
			for _, d in dirty do
				local mesh = meshSection(chunks[d[1]], d[2])
				meshes[d[1]][d[2]] = mesh
				renderer:build(nodes[d[1]], d[2], mesh, { lane = "edit", group = group })
				local state = renderer.states[nodes[d[1]]]
				local record = state and state.records[d[2]]
				parts += if record then #record.parts else 0
			end
			renderer:closeGroup(group)
			-- Sometimes a second edit comes before the next frame (waiting / replaced tasks).
			if edit % 4 ~= 0 then
				sim.step(1 + rand(3))
				table.insert(touched, renderer.pool.cloned + renderer.pool.reused - before)
				table.insert(full, parts)
			end
		end
		sim.settle()
		t.ok(sim.checked > 100000, `boxes checked for gaps: {sim.checked}`)
		t.eq(sim.gaps, 0, sim.gapDetail or "gaps")
		t.eq(sim.doubled, 0, "doubled lights")
		t.eq(sim.handedEarly, 0, "quarantine")
		if _G.RENDER_VERBOSE then
			print(`    edits checked: {sim.checked} box checks over {sim.frames} frames`)
		end

		-- Same final meshes, built fresh in another world.
		local fresh = newSim()
		local copies = { newNode(0, cx, cz), newNode(0, cx + 1, cz) }
		for k in chunks do
			for s, mesh in meshes[k] do
				if buffer.len(mesh) > 0 then
					fresh.renderer:build(copies[k], s, mesh)
				end
			end
		end
		fresh.settle(nil, false)
		for k in chunks do
			local a, b = signatures(renderer, nodes[k]), signatures(fresh.renderer, copies[k])
			for s, sig in b do
				t.eq(a[s], sig, `chunk {k} section {s} matches a fresh build`)
			end
			for s, sig in a do
				t.ok(b[s] ~= nil or sig == "", `chunk {k} section {s} not in the fresh build`)
			end
			t.eq(renderer:partsOf(nodes[k]), fresh.renderer:partsOf(copies[k]), "part counts")
		end
		t.eq(renderer.partCount, fresh.renderer.partCount, "partCount")
		t.eq(renderer.lightCount, fresh.renderer.lightCount, "lightCount")
		table.sort(touched)
		table.sort(full)
		local median = touched[(#touched + 1) // 2]
		if _G.RENDER_VERBOSE then
			print(
				`    parts built per edit: median {median}, p90 {touched[math.ceil(#touched * 0.9)]}, max {touched[#touched]}; full rebuild of the same sections: median {full[(#full + 1) // 2]} ({#touched} edits)`
			)
		end
		t.ok(median <= 8, `an edit builds few parts (median {median}, a full rebuild {full[(#full + 1) // 2]})`)
	end)

	t.test("render: without the swap delay the gap check sees the gap (control)", function()
		withRender({ SwapFrames = 0 }, function()
			local sim = newSim()
			sim.latency = 1
			local node = newNode(0, 0, 0)
			local mesh = boxesOf({ { 0, 0, 0, 4, 1, 4, stoneApp } })
			sim.renderer:build(node, 0, mesh)
			sim.settle(nil, false)
			sim.show(node)
			sim.step(3)
			-- A block placed on top: the old box is replaced by a taller one.
			sim.renderer:build(node, 0, boxesOf({ { 0, 0, 0, 4, 2, 4, stoneApp } }), { lane = "edit" })
			sim.step(1)
			t.ok(sim.gaps > 0, "a part drawn a frame late leaves a gap when the old one goes at once")
		end)
	end)

	t.test("render: an edit in a lake keeps the water surface drawn through the swap", function()
		local waterApp = Blocks.get(B.Water).appearance
		local function lake(sim: Sim, node: any): number
			local renderer = sim.renderer
			-- The mesher draws the surface as one box; a block placed in it splits it in four.
			renderer:build(node, 0, boxesOf({ { 0, 0, 0, 16, 5, 16, stoneApp }, { 0, 5, 0, 16, 1, 16, waterApp } }))
			sim.settle(nil, false)
			sim.show(node)
			sim.step(3)
			local old = renderer.states[node].records[0].parts[2]
			local checked = sim.checked
			renderer:build(
				node,
				0,
				boxesOf({
					{ 0, 0, 0, 16, 5, 16, stoneApp },
					{ 0, 5, 0, 16, 1, 8, waterApp },
					{ 0, 5, 8, 8, 1, 1, waterApp },
					{ 9, 5, 8, 7, 1, 1, waterApp },
					{ 0, 5, 9, 16, 1, 7, waterApp },
					{ 8, 5, 8, 1, 1, 1, stoneApp },
				}),
				{ lane = "edit" }
			)
			sim.step(1)
			local frames = 0
			while old.Parent ~= nil and frames < 10 do
				sim.step(1)
				frames += 1
			end
			sim.settle()
			t.ok(sim.checked > checked, "water boxes checked")
			return frames
		end
		local sim = newSim()
		local frames = lake(sim, newNode(0, 0, 0))
		t.eq(sim.gaps, 0, sim.gapDetail or "gaps")
		t.eq(frames, Render.SwapFrames, "the old surface leaves SwapFrames steps after the commit")
		-- Control: with the old surface taken away at once, a new one drawn a frame late leaves
		-- the lake without a surface for that frame.
		withRender({ SwapFrames = 0 }, function()
			local control = newSim()
			control.latency = 1
			lake(control, newNode(0, 0, 0))
			t.ok(control.gaps > 0, "the gap check sees the missing surface")
		end)
	end)

	t.test("render: a give-back replaced by the node's own mesh before it ran: never empty, nothing rebuilt", function()
		local sim = newSim()
		local renderer = sim.renderer
		-- The settings menu's smallest build budget, as on the Low preset with Auto at its floor.
		renderer:setBuildBudget(2)
		local rows = {}
		for z = 0, 15 do
			for x = 0, 7 do
				table.insert(rows, { x * 2, 0, z, 2, 1 + (x + z) % 3, 1, stoneApp })
			end
		end
		local mesh = boxesOf(rows)
		local node = newNode(1, 3, 0, 500)
		renderer:build(node, 0, mesh)
		sim.settle(nil, false)
		sim.show(node)
		sim.step(3)
		local parts = {}
		for _, part in renderer.states[node].records[0].parts do
			parts[part] = true
		end
		local full = sim.world.partsUnder(node.model)
		-- Skip hidden terrain holds the node (its parts go back, background lane); before that ran,
		-- a verdict sees it again: the kept mesh is built again (normal lane).
		renderer:build(node, 0, buffer.create(0), { lane = "background" })
		renderer:build(node, 0, mesh, { lane = "normal", priority = 500 })
		local least = math.huge
		for frame = 1, 400 do
			-- Nearer terrain keeps arriving in the normal lane (walking), from the next frame on.
			if frame >= 2 and frame <= 40 then
				renderer:build(newNode(1, 10 + frame, 0, 100 + frame), 0, mesh)
			end
			sim.step(1)
			least = math.min(least, sim.world.partsUnder(node.model))
			if not renderer:busy() then
				break
			end
		end
		t.eq(least, full, "every part drawn every frame")
		for _, part in renderer.states[node].records[0].parts do
			t.ok(parts[part], "the same parts")
		end
		t.eq(sim.gaps, 0, sim.gapDetail or "gaps")
	end)

	t.test("render: LOD swaps keep the old nodes SwapFrames frames, lights off at once", function()
		local sim = newSim()
		local renderer = sim.renderer
		local parent = newNode(1, 0, 0)
		renderer:build(parent, 0, boxesOf({ { 0, 0, 0, 16, 2, 16, stoneApp }, { 3, 2, 3, 1, 1, 1, glowApp } }))
		sim.settle(nil, false)
		sim.show(parent)
		sim.step(3)
		local function children(): { any }
			local list = {}
			for dz = 0, 1 do
				for dx = 0, 1 do
					local child = newNode(0, dx, dz)
					renderer:build(
						child,
						0,
						boxesOf({ { 0, 0, 0, 16, 4, 16, stoneApp }, { 6, 4, 6, 1, 1, 1, glowApp } })
					)
					table.insert(list, child)
				end
			end
			return list
		end
		-- Closer: four full detail chunks replace the level 1 node (far nodes have no lights).
		local near = children()
		sim.settle()
		local model = parent.model
		for _, child in near do
			sim.show(child)
		end
		sim.clear(parent)
		local frames = 0
		while model.Parent ~= nil do
			sim.step(1)
			frames += 1
			t.ok(frames <= 10, "goes eventually")
		end
		t.eq(frames, Render.SwapFrames + 1, "in the workspace for SwapFrames frames after the swap frame")
		sim.settle()
		t.eq(renderer.partCount, 4 * 2, "parent's parts no longer counted")

		-- Away again: the level 1 node replaces them; their lights go off at once.
		local again = newNode(1, 0, 0)
		renderer:build(again, 0, boxesOf({ { 0, 0, 0, 16, 2, 16, stoneApp } }))
		sim.settle()
		local lights = {}
		for _, child in near do
			for _, folder in child.model:GetChildren() do
				for _, part in folder:GetChildren() do
					local light = part:FindFirstChildOfClass("PointLight")
					if light then
						t.ok(light.Enabled, "lit before")
						table.insert(lights, light)
					end
				end
			end
		end
		t.eq(#lights, 4)
		sim.show(again)
		for _, child in near do
			sim.clear(child)
		end
		for _, light in lights do
			t.ok(not light.Enabled, "light off at once")
		end
		sim.settle()
		t.ok(sim.checked > 0, "checked")
		t.eq(sim.gaps, 0, sim.gapDetail or "gaps")
		t.eq(sim.doubled, 0, "doubled lights")
		t.eq(renderer.lightCount, 0)
		t.eq(renderer.partCount, 1)
	end)

	t.test("render: glow lichen's sparse lights through diffs, removals and the distance", function()
		local sim = newSim()
		local renderer = sim.renderer
		local lichen = Blocks.get(B.GlowLichen).appearance
		t.eq(buffer.readu8(GreedyMesher.sparseLightLut, lichen), 1, "glow lichen has sparse lights")
		local STRIDE = GreedyMesher.KEY_STRIDE
		local lit = { 2, 1, 2, 1, 1, 1, lichen + STRIDE }
		local dark = { 3, 1, 2, 1, 1, 1, lichen }
		local floor = { 0, 0, 0, 8, 1, 8, stoneApp }
		local node = newNode(0, 0, 0)
		renderer:build(node, 0, boxesOf({ floor, lit, dark }))
		sim.settle(nil, false)
		sim.show(node)
		sim.step(2)
		t.eq(renderer.sparseCount, 1, "one sparse light")
		t.eq(renderer.sparseOn, 1, "on (any distance by default)")
		t.eq(renderer.lightCount, 1)
		-- An edit elsewhere keeps it (same part, counted once).
		renderer:build(node, 0, boxesOf({ floor, lit, dark, { 6, 1, 6, 1, 1, 1, stoneApp } }), { lane = "edit" })
		sim.step(3)
		t.eq(renderer.sparseCount, 1)
		t.eq(renderer.lightCount, 1)
		-- The lit cell goes (broken): its light goes off and out of the registry at once.
		renderer:build(node, 0, boxesOf({ floor, dark }), { lane = "edit" })
		sim.step(1)
		t.eq(renderer.sparseCount, 0)
		t.eq(renderer.sparseOn, 0)
		t.eq(renderer.lightCount, 0)
		-- A finite distance switches far ones off (ViewSettings reads Caves.LichenLightDistance).
		renderer:build(node, 0, boxesOf({ floor, lit, dark }), { lane = "edit" })
		sim.step(2)
		t.eq(renderer.sparseOn, 1)
		local saved = Config.Caves.LichenLightDistance
		Config.Caves.LichenLightDistance = 4
		sim.world.clock += 1
		sim.step(2)
		Config.Caves.LichenLightDistance = saved
		t.eq(renderer.sparseOn, 0, "beyond the distance")
		t.eq(renderer.sparseCount, 1)
		sim.settle()
		t.eq(sim.gaps, 0, sim.gapDetail or "gaps")
		t.eq(sim.doubled, 0)
	end)

	t.test("render: commit groups go live in the same frame; a lost hold times out", function()
		local sim = newSim()
		local renderer = sim.renderer
		local a, b = newNode(0, 0, 0), newNode(0, 1, 0)
		renderer:build(a, 0, boxesOf({ { 0, 0, 0, 16, 1, 16, stoneApp } }))
		renderer:build(b, 0, boxesOf({ { 0, 0, 0, 16, 1, 16, stoneApp } }))
		sim.settle(nil, false)
		sim.show(a)
		sim.show(b)
		sim.step(2)
		local group = renderer:openGroup()
		renderer:holdGroup(group) -- a second job still running
		local committed = {}
		renderer:build(a, 0, boxesOf({ { 0, 0, 0, 16, 2, 16, stoneApp } }), {
			lane = "edit",
			group = group,
			onDone = function()
				committed.a = sim.world.frame
			end,
		})
		renderer:closeGroup(group)
		sim.step(5)
		t.eq(committed.a, nil, "held while the other job runs")
		renderer:build(b, 0, boxesOf({ { 0, 0, 0, 16, 2, 16, stoneApp } }), {
			lane = "near",
			group = group,
			onDone = function()
				committed.b = sim.world.frame
			end,
		})
		renderer:closeGroup(group)
		sim.step(3)
		t.ok(committed.a ~= nil and committed.a == committed.b, "same frame")

		-- A hold never released: the group gives up after its timeout.
		local lost = renderer:openGroup()
		local done = nil
		renderer:build(a, 0, boxesOf({ { 0, 0, 0, 16, 3, 16, stoneApp } }), {
			lane = "edit",
			group = lost,
			onDone = function()
				done = sim.world.frame
			end,
		})
		sim.step(60)
		t.eq(done, nil, "waits")
		sim.step(100)
		t.ok(done ~= nil, "goes live after the timeout")
		t.eq(sim.gaps, 0, sim.gapDetail or "gaps")
	end)

	t.test("render: builds go by node priority; edits first within their own budget", function()
		local sim = newSim()
		local renderer = sim.renderer
		local order = {}
		local nodes = {}
		for i, p in { 5, 1, 3, 4, 2 } do
			local node = newNode(0, i * 2, 0, p)
			nodes[i] = node
			renderer:build(node, 0, boxesOf({ { 0, 0, 0, 1, 1, 1, stoneApp } }), {
				onDone = function()
					table.insert(order, node.priority)
				end,
			})
		end
		nodes[4].priority = 0
		renderer:reprioritise()
		sim.settle(nil, false)
		t.eq(table.concat(order, " "), "0 1 2 3 5", "reprioritised order")

		-- A big backlog: an edit still goes live in the next frame.
		local backlog = {}
		for z = 0, 15 do
			for x = 0, 15 do
				table.insert(backlog, { x, 0, z, 1, 1, 1, stoneApp })
			end
		end
		for i = 1, 20 do
			renderer:build(newNode(0, 100 + i, 0, i), 0, boxesOf(backlog))
		end
		local edited = nodes[1]
		local live = nil
		renderer:build(edited, 0, boxesOf({ { 0, 0, 0, 1, 2, 1, stoneApp } }), {
			lane = "edit",
			onDone = function()
				live = sim.world.frame
			end,
		})
		local start = sim.world.frame
		sim.step(1, false)
		t.eq(live, start, "edit live in the next step")
		t.ok(renderer:pending() > 0, "backlog still building")
	end)

	t.test("render: teleport trash leaves nearest first within the budget; show never overlaps it", function()
		withRender({ UnparentPartsPerFrame = 600, PoolLimit = 500 }, function()
			local sim = newSim()
			local renderer = sim.renderer
			renderer.pool:setLimit(500)
			local rows = {}
			for z = 0, 9 do
				table.insert(rows, { 0, 0, z, 16, 1, 1, stoneApp })
				table.insert(rows, { 0, 1, z, 16, 1, 1, stoneApp })
			end
			-- 40 level 0 nodes with 200 parts each.
			local many = {}
			for z = 0, 9 do
				for x = 0, 9 do
					table.insert(many, { x, 0, z, 1, 1, 1, stoneApp })
					table.insert(many, { x, 1, z, 1, 1, 1, stoneApp })
				end
			end
			local nodes = {}
			for i = 0, 39 do
				local node = newNode(0, i % 8, i // 8)
				renderer:build(node, 0, boxesOf(many))
				table.insert(nodes, node)
			end
			sim.settle(nil, false)
			for _, node in nodes do
				sim.show(node)
			end
			sim.step(2, false)
			local unparentedAt = {}
			for i, node in nodes do
				node.removed = true
				sim.shown[node] = nil
				renderer:trashNode(node, (i * 37) % 41, i == 40)
			end
			t.ok(nodes[40].model.Parent == nil, "immediate one gone at once")
			-- A new node over (the ancestor of) node 1's area: node 1's model leaves before it shows.
			local over = newNode(1, 0, 0)
			renderer:build(over, 0, boxesOf({ { 0, 0, 0, 16, 1, 16, stoneApp } }))
			local frames = 0
			while renderer:busy() or frames == 0 do
				for i, node in nodes do
					if unparentedAt[i] == nil and node.model.Parent == nil then
						unparentedAt[i] = sim.world.frame
					end
				end
				if renderer.states[over] and renderer.states[over].records[0] and over.model.Parent == nil then
					renderer:show(over)
					for _, child in nodes do
						if child.nx // 2 == 0 and child.nz // 2 == 0 then
							t.eq(child.model.Parent, nil, "trash under the shown node is gone")
						end
					end
				end
				sim.step(1, false)
				frames += 1
				t.ok(frames < 500, "settles")
				t.ok(sim.world.count.left <= 600, `at most the budget leaves per frame (got {sim.world.count.left})`)
			end
			for i, node in nodes do
				if unparentedAt[i] == nil and node.model.Parent == nil then
					unparentedAt[i] = sim.world.frame
				end
			end
			-- Nearest first (among those not taken by `show`).
			local seq = {}
			for i, node in nodes do
				if i ~= 40 and not (node.nx // 2 == 0 and node.nz // 2 == 0) then
					table.insert(seq, { d = (i * 37) % 41, at = unparentedAt[i] })
				end
			end
			table.sort(seq, function(a, b)
				return a.d < b.d
			end)
			for i = 2, #seq do
				t.ok(seq[i].at >= seq[i - 1].at, "nearest first")
			end
			t.ok(renderer.pool.freeCount <= 500, "pool kept to its limit")
			t.ok(sim.world.count.destroyCalls < 40 * 200 / 4, "full pool: whole folders destroyed in one call")
			t.eq(sim.handedEarly, 0, "quarantine")
		end)
	end)

	t.test("render: a node removed within the swap delay of an edit (full pool) releases cleanly", function()
		for _, how in { "trash", "clear" } do
			local sim = newSim()
			local renderer = sim.renderer
			renderer.pool:setLimit(0)
			local node = newNode(0, 0, 0)
			renderer:build(node, 0, boxesOf({ { 0, 0, 0, 4, 1, 4, stoneApp }, { 0, 1, 0, 1, 1, 1, stoneApp } }))
			sim.settle(nil, false)
			sim.show(node)
			sim.step(2, false)
			local removed = renderer.states[node].records[0].parts[2]
			renderer:build(node, 0, boxesOf({ { 0, 0, 0, 4, 1, 4, stoneApp } }), { lane = "edit" })
			sim.step(1, false)
			t.ok(removed.Parent ~= nil, "removed box still shown for the swap delay")
			node.removed = true
			if how == "trash" then
				renderer:trashNode(node, 0, true)
			else
				renderer:clear(node)
			end
			local ok, err = pcall(sim.settle, nil, false)
			t.ok(ok, `{how}: {err}`)
			t.eq(removed.Parent, nil, "taken out")
			t.eq(renderer.partCount, 0)
		end
	end)

	t.test("render: releases stay within their budget per frame", function()
		withRender({ ReleaseBudgetMs = 0.5 }, function()
			local sim = newSim()
			local renderer = sim.renderer
			local many = {}
			for z = 0, 15 do
				for x = 0, 15 do
					table.insert(many, { x, 0, z, 1, 1, 1, stoneApp })
				end
			end
			local nodes = {}
			for i = 0, 29 do
				local node = newNode(0, i, 0)
				renderer:build(node, 0, boxesOf(many))
				table.insert(nodes, node)
			end
			sim.settle(nil, false)
			for _, node in nodes do
				sim.show(node)
			end
			sim.step(1, false)
			for _, node in nodes do
				sim.clear(node)
			end
			-- Measure the clock spent per frame (unparent and release only: nothing to build).
			local worst = 0
			for _ = 1, 200 do
				sim.step(1, false)
				worst = math.max(worst, sim.frameCost)
				if not renderer:busy() then
					break
				end
			end
			t.ok(not renderer:busy(), "all released")
			-- Release budget plus one unparent batch (3000 parts x 2 us) and bookkeeping.
			t.ok(worst * 1000 < 0.5 + 0.5, `worst frame {worst * 1000} ms`)
			t.ok(renderer.pool.freeCount <= Render.PoolLimit)
		end)
	end)

	t.test("render: restyle rewrites shadows within the budget; texture rebuilds swap without gaps", function()
		local sim = newSim()
		local renderer = sim.renderer
		local cx, cz = spawnX // SIZE, spawnZ // SIZE
		local chunk = terrain(cx, cz)
		local node = newNode(0, cx, cz)
		for s = 0, sectionsOf(chunk) - 1 do
			local mesh = meshSection(chunk, s)
			if buffer.len(mesh) > 0 then
				renderer:build(node, s, mesh)
			end
		end
		sim.settle(nil, false)
		sim.show(node)
		sim.step(2)
		local function shadows(): (number, number)
			local on, off = 0, 0
			for _, record in renderer.states[node].records do
				for _, part in record.parts do
					local key = renderer.pool.keyOf[part]
					if renderer.pool.castRule[key] == 1 then
						if part.CastShadow then
							on += 1
						else
							off += 1
						end
					end
				end
			end
			return on, off
		end
		local on = shadows()
		t.ok(on > 0, "near opaque parts cast shadows")
		local changes = renderer:restyle({ shadows = false, farShadows = false, textures = true })
		t.ok(changes.shadows and not changes.farShadows and not changes.textures)
		sim.settle()
		local stillOn, nowOff = shadows()
		t.eq(stillOn, 0, "all rewritten")
		t.eq(nowOff, on)
		-- A part from the pool after the change comes out right too.
		renderer:build(node, 40, boxesOf({ { 0, 0, 0, 1, 1, 1, stoneApp } }))
		sim.settle()
		t.eq(renderer.states[node].records[40].parts[1].CastShadow, false)
		renderer:restyle({ shadows = true, farShadows = false, textures = true })
		sim.settle()

		-- Textures (forced on: no block has one in this game) rebuild every section off-screen.
		sim.PartPool.texturesMatter = true
		local folders = {}
		for s, record in renderer.states[node].records do
			folders[s] = record.folder
		end
		local tex = renderer:restyle({ shadows = true, farShadows = false, textures = false })
		t.ok(tex.textures)
		sim.settle()
		for s, record in renderer.states[node].records do
			t.ok(record.folder ~= folders[s], `section {s} rebuilt`)
			t.eq(record.texture, renderer.pool.textureGen)
		end
		t.eq(sim.gaps, 0, sim.gapDetail or "gaps")
		t.eq(sim.handedEarly, 0, "quarantine")
	end)

	t.test("render: a texture restyle never drops a newer build nor holds an edit back", function()
		local sim = newSim()
		local renderer = sim.renderer
		sim.PartPool.texturesMatter = true
		local node = newNode(0, 0, 0)
		local m0 = boxesOf({ { 0, 0, 0, 4, 1, 4, stoneApp } })
		local m1 = boxesOf({ { 0, 0, 0, 4, 1, 4, stoneApp }, { 0, 1, 0, 1, 1, 1, stoneApp } })
		local m2 =
			boxesOf({ { 0, 0, 0, 4, 1, 4, stoneApp }, { 0, 1, 0, 1, 1, 1, stoneApp }, { 3, 1, 3, 1, 1, 1, stoneApp } })
		renderer:build(node, 0, m0)
		sim.settle(nil, false)
		sim.show(node)
		sim.step(2)
		-- An edit waits for its commit group; a seam remesh of the same section waits behind it.
		local group = renderer:openGroup()
		renderer:build(node, 0, m1, { lane = "edit", group = group })
		local seamDone = false
		renderer:build(node, 0, m2, {
			lane = "near",
			onDone = function()
				seamDone = true
			end,
		})
		sim.step(1)
		t.ok(renderer:restyle({ shadows = true, farShadows = false, textures = false }).textures)
		t.eq(renderer.schedule:laneCount(RenderSchedule.BACKGROUND), 0, "no restyle: the seam starts later")
		renderer:closeGroup(group)
		sim.settle()
		local record = renderer.states[node].records[0]
		t.ok(seamDone)
		t.eq(record.count, 3, "the newest mesh is live")
		t.eq(record.texture, renderer.pool.textureGen, "with the new look")

		-- Restyles queued behind a backlog: an edit replaces its section's restyle and goes live
		-- in the next step.
		for i = 1, 20 do
			renderer:build(newNode(0, 10 + i, 0, i), 0, boxesOf({ { 0, 0, 0, 16, 1, 16, stoneApp } }))
		end
		renderer:restyle({ shadows = true, farShadows = false, textures = true })
		t.ok(renderer.schedule:laneCount(RenderSchedule.BACKGROUND) > 0, "restyles queued")
		local live = nil
		local edit = renderer:openGroup()
		renderer:build(node, 0, m1, {
			lane = "edit",
			group = edit,
			onDone = function()
				live = sim.world.frame
			end,
		})
		renderer:closeGroup(edit)
		local start = sim.world.frame
		sim.step(1)
		t.eq(live, start, "edit live in the next step")
		sim.settle()
		t.eq(renderer.states[node].records[0].texture, renderer.pool.textureGen)

		-- A first build half done when the look changes is built again with the new look.
		renderer:setBuildBudget(0.05)
		local fresh = newNode(0, 40, 0)
		renderer:build(fresh, 0, boxesOf({ { 0, 0, 0, 16, 1, 16, stoneApp } }))
		renderer:build(fresh, 1, boxesOf(table.create(64, { 0, 16, 0, 1, 1, 1, stoneApp })))
		sim.step(1)
		local state = renderer.states[fresh]
		t.ok(state == nil or state.records[1] == nil, "not live yet")
		t.ok(renderer.schedule:tasksOf(fresh)[1].data.started, "started")
		renderer:restyle({ shadows = true, farShadows = false, textures = false })
		renderer:setBuildBudget(nil)
		sim.settle()
		for _, record in renderer.states[fresh].records do
			t.eq(record.texture, renderer.pool.textureGen, "new look")
		end
		t.eq(sim.gaps, 0, sim.gapDetail or "gaps")
	end)

	t.test("render: random mix of builds, groups, swaps, trash and restyles keeps every invariant", function()
		local sim = newSim()
		local renderer = sim.renderer
		-- (perf/build/R/seeds.luau runs this with many seeds through _G.RENDER_SEED.)
		local rand = rng(_G.RENDER_SEED or 2024)
		local looks = { stoneApp, glowApp, Blocks.get(B.Dirt).appearance, Blocks.get(B.Torch).appearance }
		-- Boxes of section `s` (its own 8 cells of height), never overlapping each other.
		local function randomMesh(s: number): buffer
			local list = {}
			local used = {}
			for _ = 1, 4 + rand(24) do
				local x, y, z = rand(8), rand(8), rand(8)
				local key = `{x},{y},{z}`
				if not used[key] then
					used[key] = true
					table.insert(
						list,
						{ x * 2, s * 8 + y, z * 2, 1 + rand(2), 1, 1 + rand(2), looks[1 + rand(#looks)] }
					)
				end
			end
			return boxesOf(list)
		end
		-- Slots of node positions; each holds the node currently there.
		local slots = {}
		for i = 1, 10 do
			local node = newNode(0, i * 3, 0, rand(50))
			for s = 0, 1 do
				renderer:build(node, s, randomMesh(s))
			end
			slots[i] = node
		end
		sim.settle(nil, false)
		for _, node in slots do
			sim.show(node)
		end
		local openGroups = {}
		for _ = 1, 400 do
			for _ = 1, rand(4) do
				local op = rand(100)
				local i = 1 + rand(#slots)
				local node = slots[i]
				if op < 45 then
					local lane = ({ "edit", "near", "normal", "edit" })[1 + rand(4)]
					local group = nil
					if rand(3) == 0 then
						group = openGroups[#openGroups]
						if group == nil or rand(2) == 0 then
							group = renderer:openGroup()
							table.insert(openGroups, group)
						end
					end
					local section = rand(2)
					renderer:build(node, section, randomMesh(section), { lane = lane, group = group })
				elseif op < 60 and #openGroups > 0 then
					renderer:closeGroup(table.remove(openGroups, 1))
				elseif op < 70 then
					-- A replacement for the same place (an LOD change and back): built, then swapped.
					local fresh = newNode(0, node.nx, node.nz, rand(50))
					for s = 0, 1 do
						renderer:build(fresh, s, randomMesh(s), {
							onDone = function()
								if not fresh.removed and slots[i] == node and not node.removed then
									local ready = renderer.states[fresh]
									if ready and ready.records[0] and ready.records[1] then
										sim.show(fresh)
										sim.clear(node)
										slots[i] = fresh
									end
								end
							end,
						})
					end
				elseif op < 74 then
					-- Trashed (a teleport) and rebuilt from scratch.
					node.removed = true
					sim.shown[node] = nil
					renderer:trashNode(node, rand(1000), rand(2) == 0)
					local fresh = newNode(0, node.nx, node.nz, rand(50))
					local pending = 2
					for s = 0, 1 do
						renderer:build(fresh, s, randomMesh(s), {
							onDone = function()
								pending -= 1
								if pending == 0 and not fresh.removed then
									sim.show(fresh)
								end
							end,
						})
					end
					slots[i] = fresh
				elseif op < 77 then
					renderer:restyle({ shadows = rand(2) == 0, farShadows = false, textures = true })
				elseif op < 79 then
					renderer.pool:setLimit(rand(400))
				elseif op < 82 then
					renderer:reprioritise()
				end
			end
			sim.step(1 + rand(2))
		end
		for _, group in openGroups do
			renderer:closeGroup(group)
		end
		sim.settle()
		t.ok(sim.checked > 10000, `checked {sim.checked}`)
		t.eq(sim.gaps, 0, sim.gapDetail or "gaps")
		t.eq(sim.doubled, 0, "doubled lights")
		t.eq(sim.handedEarly, 0, "quarantine")
		-- Bookkeeping: counters match the live sections; folders hold exactly their parts.
		local parts, lights = 0, 0
		for node, state in renderer.states do
			local n = 0
			for _, record in state.records do
				n += #record.parts
				local inFolder = {}
				for _, child in record.folder:GetChildren() do
					inFolder[child] = true
				end
				for _, part in record.parts do
					t.ok(inFolder[part], "part in its folder")
					inFolder[part] = nil
					if renderer.pool:hasLight(part) then
						lights += 1
						t.ok(part:FindFirstChildOfClass("PointLight").Enabled, "live light on")
					end
				end
				t.eq(next(inFolder), nil, "nothing else in the folder")
			end
			t.eq(state.parts, n, "state.parts")
			parts += n
			local _ = node
		end
		t.eq(renderer.partCount, parts, "partCount")
		t.eq(renderer.lightCount, lights, "lightCount")
		t.eq(renderer:pending(), 0)
	end)

	--[[ MeshOverlay ]]

	-- A renderer whose overlay merges level 2 regions, with the builder replaced by `finish`.
	local function overlaySim(): Sim
		local sim = newSim()
		local overlay = sim.renderer.overlay
		overlay.status = "on"
		overlay.active = true
		overlay.configured = true
		-- Finishes the pending build at once with one fake MeshPart.
		function sim.finish(): any?
			local job = overlay.pending
			if job == nil then
				return nil
			end
			overlay.pending = nil
			local part = sim.world.new("MeshPart")
			table.insert(overlay.done, { job = job, parts = { part }, triangles = 2 })
			return part
		end
		return sim
	end

	t.test("far meshes: demotion keeps the mesh until the parts are back; budgets; no gaps", function()
		withRender({ SwapPartsPerFrame = 150 }, function()
			local sim = overlaySim()
			local renderer, overlay = sim.renderer, sim.renderer.overlay
			local members = {}
			local rows = {}
			for z = 0, 15 do
				for x = 0, 3 do
					table.insert(rows, { x * 4, 0, z, 4, 1, 1, stoneApp })
				end
			end
			for i = 0, 3 do
				local node = newNode(2, i, 0)
				renderer:build(node, 0, boxesOf(rows))
				renderer:setQuads(node, buffer.create(16), 1)
				table.insert(members, node)
			end
			sim.settle(nil, false)
			for _, node in members do
				sim.show(node)
			end
			-- Stable for StableSeconds, then a build starts and finishes.
			for _ = 1, 60 * 3 do
				sim.step(1, false)
				if overlay.pending then
					break
				end
			end
			local mesh = sim.finish()
			t.ok(mesh ~= nil, "a build started")
			sim.step(1, false)
			t.ok(mesh.Parent ~= nil, "mesh shown")
			-- Members are hidden over several frames (64 parts each, 150 per frame).
			local hiddenFrames = 0
			while true do
				local all = true
				for _, node in members do
					if node.model.Parent ~= nil then
						all = false
					end
				end
				if all then
					break
				end
				sim.step(1, false)
				hiddenFrames += 1
				t.ok(hiddenFrames < 20)
			end
			t.ok(hiddenFrames >= 2, `hidden within the swap budget ({hiddenFrames} frames)`)

			-- A member goes (LOD swap): the others come back, the mesh stays until SwapFrames after.
			sim.clear(members[1])
			local backAt = nil
			local goneAt = nil
			for _ = 1, 30 do
				sim.step(1, false)
				local back = true
				for i = 2, 4 do
					if members[i].model.Parent == nil then
						back = false
					end
				end
				if back and backAt == nil then
					backAt = sim.world.frame
				end
				if mesh.Parent == nil and goneAt == nil then
					goneAt = sim.world.frame
					t.ok(back, "mesh destroyed only after the parts are back")
				end
			end
			t.ok(backAt ~= nil and goneAt ~= nil)
			t.ok(goneAt - backAt >= math.max(1, Render.SwapFrames), "the swap delay after the last one")
			t.eq(overlay.liveTriangles, 0)
		end)
	end)

	t.test("far meshes: gating by motion, the streamer and pauses; the settings switch keeps quads", function()
		local sim = overlaySim()
		local renderer, overlay = sim.renderer, sim.renderer.overlay
		local members = {}
		for i = 0, 1 do
			local node = newNode(2, i, 0)
			renderer:build(node, 0, boxesOf({ { 0, 0, 0, 16, 1, 16, stoneApp } }))
			renderer:setQuads(node, buffer.create(16), 1)
			table.insert(members, node)
		end
		sim.settle(nil, false)
		for _, node in members do
			sim.show(node)
		end
		-- Moving fast (10 blocks/s): no build.
		for i = 1, 60 * 4 do
			sim.world.camera.CFrame = CFrame.new(i * 10 * BLOCK / 60, 100, 0)
			sim.step(1, false)
		end
		t.eq(overlay.pending, nil, "no build while moving")
		t.eq(overlay:getStats().gate, "moving")
		-- Standing still, but the streamer is busy.
		overlay:setStreamerBusy(true)
		sim.step(60 * 3, false)
		t.eq(overlay.pending, nil, "no build while the streamer is busy")
		t.eq(overlay:getStats().gate, "busy")
		overlay:setStreamerBusy(false)
		sim.step(30, false)
		t.ok(overlay.pending ~= nil, "builds when still and idle")
		-- A pause (teleport) asks the running build to stop.
		overlay:pause()
		t.ok(overlay.abort, "abort requested")
		local job = overlay.pending
		overlay.pending = nil
		table.insert(overlay.done, { job = job, triangles = 0, err = "aborted" })
		sim.step(30, false)
		t.eq(overlay.pending, nil, "paused")
		t.eq(job.region.failures, 0, "not a failure")
		overlay:resume()
		sim.step(30, false)
		local mesh = sim.finish()
		t.ok(mesh ~= nil)
		sim.step(10, false)
		t.eq(members[1].model.Parent, nil, "meshed")

		-- Settings: off demotes and keeps the quads; on again is allowed.
		t.ok(overlay:setUserEnabled(false))
		sim.step(10, false)
		t.ok(members[1].model.Parent ~= nil, "parts back")
		t.eq(mesh.Parent, nil, "mesh gone")
		t.ok(overlay.quads[members[1]] ~= nil, "quads kept")
		t.ok(renderer:wantsQuads(2), "still asks for quads")
		sim.step(60 * 3, false)
		t.eq(overlay.pending, nil, "no build while off")
		t.ok(overlay:setUserEnabled(true))
		sim.step(60 * 3, false)
		t.ok(overlay.pending ~= nil, "builds again")
		-- A build finishing just after meshes were switched off is not shown.
		overlay:setUserEnabled(false)
		local late = sim.finish()
		sim.step(2, false)
		t.eq(late.Parent, nil, "late mesh dropped")
		t.ok(late.__destroyed, "and destroyed")
		overlay:setUserEnabled(true)
		-- Meshes that were off from the start cannot be switched on in this session.
		overlay.configured = false
		t.eq(overlay:setUserEnabled(true), false)

		-- onClear finds the node's region through the index.
		local region = overlay.regions:regionOfNode(members[2])
		t.ok(region ~= nil)
		sim.clear(members[2])
		t.eq(overlay.regions:regionOfNode(members[2]), nil)
	end)

	t.test("far meshes: unavailable ones read the real reason after the setting goes off and on", function()
		local sim = newSim()
		local overlay = sim.renderer.overlay
		-- As on a phone (FarMeshes.Mobile false) or after a failed startup probe.
		overlay.configured = false
		overlay.active = false
		overlay.status = "off: probe failed"
		t.ok(overlay:setUserEnabled(false))
		t.eq(overlay:getStats().status, "off (settings)")
		t.eq(overlay:setUserEnabled(true), false, "cannot come on this session")
		t.eq(overlay:getStats().status, "off: probe failed", "the real reason, not the setting")
	end)

	t.test("far meshes: one swap allowance a frame for the streamer's swaps and the overlay", function()
		withRender({ SwapPartsPerFrame = 600 }, function()
			local sim = overlaySim()
			local renderer, overlay = sim.renderer, sim.renderer.overlay
			-- A 4 x 4 region of level 2 nodes with 256 parts each, merged.
			local rows = {}
			for z = 0, 15 do
				for x = 0, 15 do
					table.insert(rows, { x, 0, z, 1, 1 + (x + z) % 3, 1, stoneApp })
				end
			end
			local members = {}
			for z = 0, 3 do
				for x = 0, 3 do
					local node = newNode(2, x, z)
					renderer:build(node, 0, boxesOf(rows))
					renderer:setQuads(node, buffer.create(16), 1)
					table.insert(members, node)
				end
			end
			sim.settle(nil, false)
			for _, node in members do
				sim.show(node)
			end
			for _ = 1, 60 * 5 do
				sim.step(1, false)
				if overlay.pending then
					break
				end
			end
			t.ok(sim.finish() ~= nil, "a build started")
			sim.step(60, false)
			for _, node in members do
				t.eq(node.model.Parent, nil, "meshed")
			end
			-- The streamer's swap this frame: member 1 replaced by four children of 150 parts each
			-- (one unit within the allowance). The overlay puts the other members back.
			local cells = {}
			for i = 1, 150 do
				table.insert(cells, { (i - 1) % 16, 0, (i - 1) // 16, 1, 1, 1, stoneApp })
			end
			local children = {}
			for k = 0, 3 do
				local child = newNode(1, k % 2, k // 2)
				renderer:build(child, 0, boxesOf(cells))
				table.insert(children, child)
			end
			sim.settle(nil, false)
			local world = sim.world
			local frames = 0
			local most = 0
			world.count.entered, world.count.left = 0, 0
			sim.clear(members[1])
			for _, child in children do
				sim.show(child)
			end
			while true do
				sim.step(1, false)
				frames += 1
				most = math.max(most, world.count.entered + world.count.left)
				world.count.entered, world.count.left = 0, 0
				local back = true
				for i = 2, #members do
					if members[i].model.Parent == nil then
						back = false
					end
				end
				if back or frames > 60 then
					break
				end
			end
			-- At most the allowance, plus the one member the overlay always moves a frame (so it
			-- never waits forever behind the swaps).
			t.ok(most <= 600 + 256, `parts moved in one frame: {most}`)
			t.ok(frames >= math.ceil(15 * 256 / 600), `members put back over {frames} frames`)
		end)
	end)
end
