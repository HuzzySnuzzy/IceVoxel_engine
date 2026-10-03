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
	its area is fully built, then it is removed in the same frame the last replacement appears.

	Node states: waiting (for edit lists) -> queued -> working (in a worker) -> built (parts being
	created) -> ready (visible).
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
	ready: boolean,
	chunk: ClientWorld.ChunkData?,
	reveal: { [number]: boolean },
	dirty: { [number]: boolean },
	meshing: boolean,
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

-- Should section `s` of a full detail chunk be meshed with caves visible?
local function wantsReveal(node: Node, s: number, camera: Vector3?): boolean
	if camera == nil then
		return false
	end
	local dx = (node.nx + 0.5) * SIZE - camera.X
	local dz = (node.nz + 0.5) * SIZE - camera.Z
	local dy = (s + 0.5) * SECTION - camera.Y
	local reach = Config.Caves.RevealRadius + SECTION
	return dx * dx + dy * dy + dz * dz < reach * reach
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
		chunk = nil,
		reveal = {},
		dirty = {},
		meshing = false,
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

local function retire(self: ChunkStreamer)
	local now = os.clock()
	local timeout = Config.Streaming.ReplaceTimeout
	for _, node in self.nodes do
		local since = node.retireSince
		if since and (not node.ready or now - since > timeout or covered(self, node)) then
			removeNode(self, node)
		end
	end
end

local function markReady(self: ChunkStreamer, node: Node)
	node.ready = true
	node.state = "ready"
	self.renderer:show(node)
	-- Remove whatever this node replaces in the same frame.
	retire(self)
end

local function enqueue(self: ChunkStreamer, node: Node)
	node.state = "queued"
	-- The queue is sorted with the most urgent node last; requeued nodes go to the front of the line.
	table.insert(self.queue, node)
end

--[[ Jobs ]]

local function onGenerated(self: ChunkStreamer, node: Node, result: WorkerPool.Result, reveal: { number })
	if node.removed then
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
	local job: { [string]: any } = { kind = "generate", level = node.level, nx = node.nx, nz = node.nz }
	local reveal: { number } = {}
	if node.level == 0 then
		job.edits = self.world:collectJobEdits(node.nx, node.nz)
		reveal = revealList(node, caveViewpoint(self))
		job.reveal = reveal
	end
	node.state = "working"
	node.stale = false
	return self.pool:submit(job, function(result)
		onGenerated(self, node, result, reveal)
	end)
end

local function dispatchRemesh(self: ChunkStreamer, node: Node): boolean
	local chunk = node.chunk
	if chunk == nil then
		return false
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

	local job = {
		kind = "mesh",
		data = chunk.data,
		height = chunk.height,
		solidBelow = chunk.solidBelow,
		emptyAbove = chunk.emptyAbove,
		sections = sections,
		reveal = reveal,
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
				if want ~= (node.reveal[s] == true) then
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

-- Is the full detail chunk containing block (x, z) visible?
function ChunkStreamer.isReady(self: ChunkStreamer, x: number, z: number): boolean
	local node = self.nodes[Coords.chunkKey(x // SIZE, z // SIZE)]
	return node ~= nil and node.ready
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
