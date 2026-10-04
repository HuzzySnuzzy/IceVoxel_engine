--!strict
--[[
	Decides what terrain exists on the client and keeps it up to date.

	Every Config.Streaming.UpdateInterval it asks LodTree which chunk nodes should be visible around
	the player, then each frame it:
	  1. waits for the server's edit lists of new full detail chunks (and their neighbours),
	  2. hands generation jobs to the worker pool, closest / most in-view first,
	  3. remeshes sections of full detail chunks that were edited or whose cave visibility changed,
	  4. lets the renderer build parts within its frame budget.

	Seamless LOD changes: a node that is no longer wanted stays visible until every node covering
	its area is fully built, then it is removed in the same frame the last replacement appears. A
	built node whose area is still shown by a coarser node waits (unshown) until then, so two
	levels of detail are never drawn on top of each other.

	Node states: waiting (for edit lists) -> queued -> working (in a worker) -> built (parts being
	created) -> ready (visible).

	Borders (GreedyMesher.Border): a node next to a coarser node is meshed knowing that node's
	level, so it draws the border cells the coarser node leaves open (no see-through seams), and a
	section with visible caves next to hidden caves closes its tunnels. Both depend on the
	neighbours, so nodes are remeshed when their neighbourhood changes.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Coords = require(Shared.World.Coords)
local LodTree = require(Shared.World.LodTree)
local GreedyMesher = require(Shared.Meshing.GreedyMesher)
local TerrainGenerator = require(Shared.Generation.TerrainGenerator)

local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local WorkerPool = require(script.Parent.WorkerPool)
local ChunkRenderer = require(script.Parent.Parent.Rendering.ChunkRenderer)

local SIZE = Config.ChunkSize
local SECTION = Config.SectionHeight
local SECTIONS = Config.WorldHeight // Config.SectionHeight
local BLOCK = Config.BlockSize
local MAX_LEVEL = LodTree.MAX_LEVEL
local EDIT_RETRY = 5
local MAX_FAILURES = 2

local NEIGHBOURS = { { 0, 0 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
-- Border sides in GreedyMesher order: -X, +X, -Z, +Z.
local SIDES = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }
local NO_COARSER = table.freeze({ 0, 0, 0, 0 })

export type Node = {
	-- RenderNode fields
	level: number,
	nx: number,
	nz: number,
	removed: boolean,
	model: Folder?,
	sections: { [number]: Folder },

	key: number,
	state: string,
	priority: number,
	stale: boolean,
	failures: number,
	since: number,
	retireSince: number?,
	pendingBuilds: number,
	-- Built (all parts created) / in the workspace.
	ready: boolean,
	shown: boolean,
	chunk: ClientWorld.ChunkData?,
	reveal: { [number]: boolean },
	dirty: { [number]: boolean },
	meshing: boolean,
	-- Level of the coarser node on each side (0 = none): wanted now / used by the current mesh.
	coarser: { number },
	coarserUsed: { number }?,
	-- Cave cap mask each section was meshed with.
	caps: { [number]: number },
	-- Incremented per generation job; results of older jobs are ignored.
	job: number,
}

export type Stats = {
	nodes: { [number]: number },
	waiting: number,
	queued: number,
	working: number,
	building: number,
	busyWorkers: number,
}

export type ChunkStreamer = {
	generator: TerrainGenerator.Generator,
	world: ClientWorld.ClientWorld,
	pool: WorkerPool.WorkerPool,
	renderer: ChunkRenderer.ChunkRenderer,
	nodes: { [number]: Node },
	desired: { [number]: number },
	queue: { Node },
	waiting: { [Node]: boolean },
	dirtyNodes: { [Node]: boolean },
	-- Ready nodes waiting for a coarser node over their area to go away.
	unshown: { [Node]: boolean },
	sinceRefresh: number,

	update: (self: ChunkStreamer, dt: number) -> (),
	isReady: (self: ChunkStreamer, x: number, z: number) -> boolean,
	stats: (self: ChunkStreamer) -> Stats,
}

local ChunkStreamer = {}
ChunkStreamer.__index = ChunkStreamer

--[[ Helpers ]]

local function viewerPosition(): Vector3
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	local spawn = Shared:GetAttribute("SpawnPosition")
	if typeof(spawn) == "Vector3" then
		return spawn
	end
	return workspace.CurrentCamera.CFrame.Position
end

-- Camera position in blocks, or nil while it is above the terrain surface (caves stay hidden then).
local function caveViewpoint(self: ChunkStreamer): Vector3?
	local camera = workspace.CurrentCamera.CFrame.Position / BLOCK
	local surface = self.generator.column(math.floor(camera.X), math.floor(camera.Z))
	if camera.Y < surface - 1 then
		return camera
	end
	return nil
end

-- Should section `s` of full detail chunk (cx, cz) be meshed with caves visible?
local function wantsRevealAt(cx: number, cz: number, s: number, camera: Vector3?): boolean
	if camera == nil then
		return false
	end
	local dx = (cx + 0.5) * SIZE - camera.X
	local dz = (cz + 0.5) * SIZE - camera.Z
	local dy = (s + 0.5) * SECTION - camera.Y
	local reach = Config.Caves.RevealRadius + SECTION
	return dx * dx + dy * dy + dz * dz < reach * reach
end

local function wantsReveal(node: Node, s: number, camera: Vector3?): boolean
	return wantsRevealAt(node.nx, node.nz, s, camera)
end

local function revealList(node: Node, camera: Vector3?): { number }
	if camera == nil then
		return {}
	end
	local list = {}
	for s = 0, SECTIONS - 1 do
		if wantsReveal(node, s, camera) then
			table.insert(list, s)
		end
	end
	return list
end

local function toSet(list: { number }): { [number]: boolean }
	local set = {}
	for _, v in list do
		set[v] = true
	end
	return set
end

-- Lower is more urgent: distance, stretched for nodes behind the camera.
local function priorityOf(node: Node, pos: Vector3, look: Vector3): number
	local size = LodTree.nodeSize(node.level)
	local distance = LodTree.distance(node.level, node.nx, node.nz, pos.X, pos.Z)
	local dx, dz = (node.nx + 0.5) * size - pos.X, (node.nz + 0.5) * size - pos.Z
	local length = math.sqrt(dx * dx + dz * dz)
	local facing = if length > 1e-3 then (dx * look.X + dz * look.Z) / length else 1
	return distance * (1.4 - 0.4 * facing)
end

-- Levels of the coarser nodes next to each side of a node in `desired` (0 = same or finer).
local function coarserSides(desired: { [number]: number }, level: number, nx: number, nz: number): { number }
	local out = { 0, 0, 0, 0 }
	for i, side in SIDES do
		local x, z = nx + side[1], nz + side[2]
		for coarse = level + 1, MAX_LEVEL do
			local f = bit32.lshift(1, coarse - level)
			if desired[Coords.nodeKey(coarse, x // f, z // f)] then
				out[i] = coarse
				break
			end
		end
	end
	return out
end

-- Does a mesh made with coarser sides `used` leave holes next to the neighbours `wanted`?
local function seamsChanged(used: { number }?, wanted: { number }): boolean
	for i = 1, 4 do
		if wanted[i] ~= 0 and (used == nil or used[i] ~= wanted[i]) then
			return true
		end
	end
	return false
end

-- GreedyMesher.Border hidden mask of revealed section `s` of chunk (cx, cz): the sides beyond
-- which caves are hidden (neighbours that are not revealed full detail chunks / sections).
local function capMask(desired: { [number]: number }, cx: number, cz: number, s: number, camera: Vector3?): number
	local mask = 0
	for i, side in SIDES do
		local x, z = cx + side[1], cz + side[2]
		if desired[Coords.chunkKey(x, z)] == nil or not wantsRevealAt(x, z, s, camera) then
			mask += bit32.lshift(1, i - 1)
		end
	end
	if s > 0 and not wantsRevealAt(cx, cz, s - 1, camera) then
		mask += GreedyMesher.HIDDEN_BELOW
	end
	if s < SECTIONS - 1 and not wantsRevealAt(cx, cz, s + 1, camera) then
		mask += GreedyMesher.HIDDEN_ABOVE
	end
	return mask
end

-- Cap masks for the revealed sections in `reveal`, recorded on the node. Returned as a flat
-- { section, mask, ... } list (actor messages only copy plain arrays reliably).
local function capsFor(
	self: ChunkStreamer,
	node: Node,
	sections: { number },
	reveal: { number },
	camera: Vector3?
): { number }
	local caps: { number } = {}
	for _, s in sections do
		node.caps[s] = 0
	end
	for _, s in reveal do
		local mask = capMask(self.desired, node.nx, node.nz, s, camera)
		table.insert(caps, s)
		table.insert(caps, mask)
		node.caps[s] = mask
	end
	return caps
end

--[[ Construction ]]

function ChunkStreamer.new(
	generator: TerrainGenerator.Generator,
	world: ClientWorld.ClientWorld,
	pool: WorkerPool.WorkerPool,
	renderer: ChunkRenderer.ChunkRenderer
): ChunkStreamer
	local self = (
		setmetatable({
			generator = generator,
			world = world,
			pool = pool,
			renderer = renderer,
			nodes = {},
			desired = {},
			queue = {},
			waiting = {},
			dirtyNodes = {},
			unshown = {},
			sinceRefresh = math.huge,
		}, ChunkStreamer) :: any
	) :: ChunkStreamer

	world.onSectionDirty = function(cx, cz, section)
		local node = self.nodes[Coords.chunkKey(cx, cz)]
		if node and node.chunk and section >= 0 and section < SECTIONS then
			node.dirty[section] = true
			self.dirtyNodes[node] = true
		end
	end

	world.onChunkTouched = function(cx, cz)
		local node = self.nodes[Coords.chunkKey(cx, cz)]
		if node and node.state == "working" then
			-- The generation job was sent before this edit; its result is outdated.
			node.stale = true
		end
	end

	return self
end

--[[ Node lifecycle ]]

local function newNode(key: number, level: number, nx: number, nz: number): Node
	return {
		level = level,
		nx = nx,
		nz = nz,
		removed = false,
		model = nil,
		sections = {},
		key = key,
		state = "queued",
		priority = 0,
		stale = false,
		failures = 0,
		since = os.clock(),
		retireSince = nil,
		pendingBuilds = 0,
		ready = false,
		shown = false,
		chunk = nil,
		reveal = {},
		dirty = {},
		meshing = false,
		coarser = NO_COARSER,
		coarserUsed = nil,
		caps = {},
		job = 0,
	}
end

local function removeNode(self: ChunkStreamer, node: Node)
	node.removed = true
	self.renderer:clear(node)
	if node.chunk then
		self.world:detach(node.nx, node.nz)
		node.chunk = nil
	end
	self.nodes[node.key] = nil
	self.waiting[node] = nil
	self.dirtyNodes[node] = nil
	self.unshown[node] = nil
end

local function isReadyKey(self: ChunkStreamer, key: number): boolean
	local node = self.nodes[key]
	return node ~= nil and node.ready
end

local function descendantsReady(self: ChunkStreamer, level: number, nx: number, nz: number): boolean
	if level == 0 then
		return true
	end
	for dz = 0, 1 do
		for dx = 0, 1 do
			local cx, cz = nx * 2 + dx, nz * 2 + dz
			local key = Coords.nodeKey(level - 1, cx, cz)
			if self.desired[key] then
				if not isReadyKey(self, key) then
					return false
				end
			elseif not descendantsReady(self, level - 1, cx, cz) then
				return false
			end
		end
	end
	return true
end

-- Is the area of `node` fully displayed by wanted nodes that are ready?
local function covered(self: ChunkStreamer, node: Node): boolean
	local level, x, z = node.level, node.nx, node.nz
	while level < MAX_LEVEL do
		level += 1
		x = x // 2
		z = z // 2
		local key = Coords.nodeKey(level, x, z)
		if self.desired[key] then
			return isReadyKey(self, key)
		end
	end
	return descendantsReady(self, node.level, node.nx, node.nz)
end

-- Is a coarser node still showing (part of) this node's area?
local function hiddenByAncestor(self: ChunkStreamer, node: Node): boolean
	for level = node.level + 1, MAX_LEVEL do
		local shift = level - node.level
		local ancestor =
			self.nodes[Coords.nodeKey(level, node.nx // bit32.lshift(1, shift), node.nz // bit32.lshift(1, shift))]
		if ancestor and ancestor.shown then
			return true
		end
	end
	return false
end

local function show(self: ChunkStreamer, node: Node)
	node.shown = true
	self.unshown[node] = nil
	self.renderer:show(node)
end

local function retire(self: ChunkStreamer)
	local now = os.clock()
	local timeout = Config.Streaming.ReplaceTimeout
	local removed = false
	for _, node in self.nodes do
		local since = node.retireSince
		if since and (not node.ready or now - since > timeout or covered(self, node)) then
			removeNode(self, node)
			removed = true
		end
	end
	-- Show the nodes that were waiting for what was just removed, in the same frame. Coarser
	-- ones first: a waiting node may itself cover other waiting nodes (when the node above both
	-- timed out), and those must keep waiting for it.
	if removed and next(self.unshown) then
		local waiting = {}
		for node in self.unshown do
			table.insert(waiting, node)
		end
		table.sort(waiting, function(a, b)
			return a.level > b.level
		end)
		for _, node in waiting do
			if not hiddenByAncestor(self, node) then
				show(self, node)
			end
		end
	end
end

local function markReady(self: ChunkStreamer, node: Node)
	node.ready = true
	-- A regenerated node may already have a newer job queued or running.
	if node.state ~= "queued" and node.state ~= "working" then
		node.state = "ready"
	end
	if not node.shown then
		if hiddenByAncestor(self, node) then
			self.unshown[node] = true
		else
			show(self, node)
		end
	end
	-- Remove whatever this node replaces in the same frame.
	retire(self)
end

local function enqueue(self: ChunkStreamer, node: Node)
	node.state = "queued"
	-- The queue is sorted with the most urgent node last; requeued nodes go to the front of the line.
	table.insert(self.queue, node)
end

--[[ Jobs ]]

local function onGenerated(self: ChunkStreamer, node: Node, job: number, result: WorkerPool.Result, reveal: { number })
	if node.removed or job ~= node.job then
		return
	end
	if result.failed then
		node.failures += 1
		if node.failures <= MAX_FAILURES then
			enqueue(self, node)
		else
			node.state = "failed"
			markReady(self, node)
		end
		return
	end
	if node.stale then
		node.stale = false
		enqueue(self, node)
		return
	end

	node.state = "built"
	if node.level == 0 then
		local chunk: ClientWorld.ChunkData = {
			data = result.data,
			height = result.height,
			solidBelow = result.solidBelow,
			emptyAbove = result.emptyAbove,
		}
		node.chunk = chunk
		node.reveal = toSet(reveal)
		self.world:attach(node.nx, node.nz, chunk)
	end

	local sections = result.sections :: { number }
	local meshes = result.meshes :: { buffer }
	node.pendingBuilds = #sections
	if #sections == 0 then
		markReady(self, node)
		return
	end
	for i, section in sections do
		self.renderer:build(node, section, meshes[i], false, function()
			node.pendingBuilds -= 1
			if node.pendingBuilds == 0 and not node.removed then
				markReady(self, node)
			end
		end)
	end
end

local function dispatchGenerate(self: ChunkStreamer, node: Node): boolean
	local job: { [string]: any } =
		{ kind = "generate", level = node.level, nx = node.nx, nz = node.nz, coarser = node.coarser }
	node.coarserUsed = node.coarser
	local reveal: { number } = {}
	if node.level == 0 then
		job.edits = self.world:collectJobEdits(node.nx, node.nz)
		local camera = caveViewpoint(self)
		reveal = revealList(node, camera)
		job.reveal = reveal
		local all = {}
		for s = 0, SECTIONS - 1 do
			all[s + 1] = s
		end
		job.caps = capsFor(self, node, all, reveal, camera)
	end
	node.state = "working"
	node.stale = false
	node.job += 1
	local token = node.job
	return self.pool:submit(job, function(result)
		onGenerated(self, node, token, result, reveal)
	end)
end

local function dispatchRemesh(self: ChunkStreamer, node: Node): boolean
	local chunk = node.chunk
	if chunk == nil then
		return false
	end
	-- A mesh made for other neighbours has to be redone everywhere, not only where edited.
	if seamsChanged(node.coarserUsed, node.coarser) then
		for s = 0, (chunk.emptyAbove - 1) // SECTION do
			node.dirty[s] = true
		end
	end
	local camera = caveViewpoint(self)
	local sections, reveal = {}, {}
	for s in node.dirty do
		table.insert(sections, s)
		if wantsReveal(node, s, camera) then
			table.insert(reveal, s)
		end
	end
	node.dirty = {}
	self.dirtyNodes[node] = nil
	node.meshing = true

	node.coarserUsed = node.coarser
	local job = {
		kind = "mesh",
		nx = node.nx,
		nz = node.nz,
		coarser = node.coarser,
		data = chunk.data,
		height = chunk.height,
		solidBelow = chunk.solidBelow,
		emptyAbove = chunk.emptyAbove,
		sections = sections,
		reveal = reveal,
		caps = capsFor(self, node, sections, reveal, camera),
	}
	return self.pool:submit(job, function(result)
		node.meshing = false
		if node.removed then
			return
		end
		local revealed = toSet(reveal)
		local meshes = result.meshes :: { buffer }
		for i, section in result.sections :: { number } do
			node.reveal[section] = revealed[section] == true
			self.renderer:build(node, section, meshes[i], true)
		end
		if next(node.dirty) then
			self.dirtyNodes[node] = true
		end
	end)
end

local function dispatch(self: ChunkStreamer)
	local pool = self.pool
	-- Edits first: they are small and the player is waiting for them.
	for node in self.dirtyNodes do
		if not pool:hasCapacity() then
			return
		end
		if node.ready and not node.meshing then
			dispatchRemesh(self, node)
		end
	end
	while pool:hasCapacity() do
		local node = table.remove(self.queue)
		if node == nil then
			return
		end
		if node.state == "queued" and not node.removed and node.retireSince == nil then
			dispatchGenerate(self, node)
		end
	end
end

--[[ Periodic refresh ]]

local function requestEdits(self: ChunkStreamer, node: Node)
	for _, offset in NEIGHBOURS do
		self.world:requestEdits(node.nx + offset[1], node.nz + offset[2])
	end
end

local function editsReady(self: ChunkStreamer, node: Node): boolean
	for _, offset in NEIGHBOURS do
		if not self.world:editsKnown(node.nx + offset[1], node.nz + offset[2]) then
			return false
		end
	end
	return true
end

local function updateReveal(self: ChunkStreamer)
	local camera = caveViewpoint(self)
	for _, node in self.nodes do
		local chunk = node.chunk
		if chunk and node.ready then
			for s = 0, SECTIONS - 1 do
				local want = wantsReveal(node, s, camera)
				if
					want
					and node.reveal[s]
					and not node.dirty[s]
					and capMask(self.desired, node.nx, node.nz, s, camera) ~= (node.caps[s] or 0)
				then
					-- Still revealed, but caves around it were revealed or hidden.
					node.dirty[s] = true
					self.dirtyNodes[node] = true
				elseif want ~= (node.reveal[s] == true) then
					if
						GreedyMesher.isTrivial(
							s * SECTION,
							(s + 1) * SECTION,
							chunk.solidBelow,
							chunk.emptyAbove,
							false
						)
					then
						node.reveal[s] = want
					elseif not node.dirty[s] then
						node.dirty[s] = true
						self.dirtyNodes[node] = true
					end
				end
			end
		end
	end
end

local function refresh(self: ChunkStreamer)
	local pos = viewerPosition() / BLOCK
	local lookVector = workspace.CurrentCamera.CFrame.LookVector
	local look = Vector3.new(lookVector.X, 0, lookVector.Z)
	look = if look.Magnitude > 1e-3 then look.Unit else Vector3.new(0, 0, -1)

	local desired = LodTree.select(pos.X, pos.Z, self.desired)
	self.desired = desired

	local keepEdits: { [number]: boolean } = {}
	for key, level in desired do
		local node = self.nodes[key]
		if node == nil then
			local _, nx, nz = Coords.decodeNodeKey(key)
			node = newNode(key, level, nx, nz)
			self.nodes[key] = node
			if level == 0 then
				node.state = "waiting"
				self.waiting[node] = true
				requestEdits(self, node)
			end
		end
		node.retireSince = nil
		if level == 0 then
			local _, nx, nz = Coords.decodeNodeKey(key)
			for _, offset in NEIGHBOURS do
				keepEdits[Coords.chunkKey(nx + offset[1], nz + offset[2])] = true
			end
		end
		node.coarser = coarserSides(desired, level, node.nx, node.nz)
		if node.coarserUsed and seamsChanged(node.coarserUsed, node.coarser) then
			-- A coarser neighbour appeared or changed level: the border must be redrawn.
			local chunk = node.chunk
			if node.state == "working" then
				node.stale = true
			elseif chunk then
				-- Remeshed as soon as the node is ready (dispatch waits for that).
				for s = 0, (chunk.emptyAbove - 1) // SECTION do
					node.dirty[s] = true
				end
				self.dirtyNodes[node] = true
			elseif node.state == "ready" then
				-- LOD nodes keep no block data: generate again. (A node still building is
				-- handled at the first refresh after it is ready.)
				node.state = "queued"
			end
		end
	end
	self.world:forgetEditsExcept(keepEdits)

	local now = os.clock()
	local queue = {}
	for key, node in self.nodes do
		if not desired[key] then
			if node.retireSince == nil then
				node.retireSince = now
			end
		elseif node.state == "queued" then
			node.priority = priorityOf(node, pos, look)
			table.insert(queue, node)
		end
	end
	table.sort(queue, function(a, b)
		return a.priority > b.priority
	end)
	self.queue = queue

	updateReveal(self)
	retire(self)
end

--[[ Public ]]

function ChunkStreamer.update(self: ChunkStreamer, dt: number)
	self.sinceRefresh += dt
	if self.sinceRefresh >= Config.Streaming.UpdateInterval then
		self.sinceRefresh = 0
		refresh(self)
	end

	local now = os.clock()
	for node in self.waiting do
		if editsReady(self, node) then
			self.waiting[node] = nil
			enqueue(self, node)
		elseif now - node.since > EDIT_RETRY then
			-- A request got lost (e.g. rate limited): ask again.
			node.since = now
			for _, offset in NEIGHBOURS do
				local key = Coords.chunkKey(node.nx + offset[1], node.nz + offset[2])
				if self.world.edits[key] == false then
					self.world.edits[key] = nil
				end
			end
			requestEdits(self, node)
		end
	end

	dispatch(self)
	self.world:flush()
	self.renderer:step()
end

-- Are the full detail chunk containing block (x, z) and the eight around it visible (so a
-- character released there has solid ground to walk on in every direction)?
function ChunkStreamer.isReady(self: ChunkStreamer, x: number, z: number): boolean
	local cx, cz = x // SIZE, z // SIZE
	for dz = -1, 1 do
		for dx = -1, 1 do
			local node = self.nodes[Coords.chunkKey(cx + dx, cz + dz)]
			if node == nil or not node.shown then
				return false
			end
		end
	end
	return true
end

function ChunkStreamer.stats(self: ChunkStreamer): Stats
	local stats: Stats = {
		nodes = {},
		waiting = 0,
		queued = 0,
		working = 0,
		building = self.renderer:pending(),
		busyWorkers = self.pool:busy(),
	}
	for _, node in self.nodes do
		stats.nodes[node.level] = (stats.nodes[node.level] or 0) + 1
		if node.state == "waiting" then
			stats.waiting += 1
		elseif node.state == "queued" then
			stats.queued += 1
		elseif node.state == "working" then
			stats.working += 1
		end
	end
	return stats
end

return ChunkStreamer
