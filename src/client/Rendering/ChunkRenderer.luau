--!strict
--[[
	Turns mesh boxes into parts.

	Each chunk node owns a Folder ("model"); each mesh section is a Folder inside it. Building a
	section happens outside the workspace, spread over frames within Config.Render.BuildBudgetMs,
	and the finished folder replaces the old one in a single step, so remeshing never flickers.

	A node's model stays out of the workspace until the streamer calls `show`, which lets the
	streamer reveal a whole chunk at once and remove the chunk it replaces in the same frame.

	MeshOverlay sits on top: it may merge stable far nodes into MeshParts and unparent their
	models meanwhile; it is told about every show, clear and rebuild so it can put them back.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GreedyMesher = require(Shared.Meshing.GreedyMesher)
local ChunkLayout = require(Shared.World.ChunkLayout)
local Blocks = require(Shared.Blocks)

local PartPool = require(script.Parent.PartPool)
local MeshOverlay = require(script.Parent.MeshOverlay)

local BOX = GreedyMesher.BOX_BYTES
local FLUID_FULL = Blocks.FLUID_FULL
local readu16 = buffer.readu16
-- Longest side of a part in studs (engine limit).
local MAX_PART = 2048

-- What the renderer needs to know about a chunk node.
export type RenderNode = {
	level: number,
	nx: number,
	nz: number,
	removed: boolean,
	model: Folder?,
	sections: { [number]: Folder },
}

type Task = {
	node: RenderNode,
	section: number,
	boxes: buffer,
	count: number,
	cursor: number,
	folder: Folder?,
	onDone: (() -> ())?,
}

export type ChunkRenderer = {
	root: Folder,
	pool: PartPool.PartPool,
	overlay: MeshOverlay.MeshOverlay,
	-- Parts currently owned by sections (including ones not shown yet).
	partCount: number,
	urgent: { Task },
	normal: { Task },

	build: (
		self: ChunkRenderer,
		node: RenderNode,
		section: number,
		boxes: buffer,
		urgent: boolean,
		onDone: (() -> ())?
	) -> (),
	show: (self: ChunkRenderer, node: RenderNode) -> (),
	clear: (self: ChunkRenderer, node: RenderNode) -> (),
	wantsQuads: (self: ChunkRenderer, level: number) -> boolean,
	setQuads: (self: ChunkRenderer, node: RenderNode, quads: buffer, count: number) -> (),
	step: (self: ChunkRenderer) -> (),
	pending: (self: ChunkRenderer) -> number,
}

local ChunkRenderer = {}
ChunkRenderer.__index = ChunkRenderer

function ChunkRenderer.new(): ChunkRenderer
	local root = Instance.new("Folder")
	root.Name = "IceVoxelWorld"
	root.Parent = workspace

	local self = {
		root = root,
		pool = PartPool.new(Config.Render.PoolLimit),
		overlay = MeshOverlay.new(root),
		partCount = 0,
		urgent = {},
		normal = {},
	}
	return (setmetatable(self, ChunkRenderer) :: any) :: ChunkRenderer
end

local function modelOf(node: RenderNode): Folder
	local model = node.model
	if model == nil then
		local folder = Instance.new("Folder")
		folder.Name = `L{node.level} {node.nx},{node.nz}`
		node.model = folder
		return folder
	end
	return model
end

local function releaseFolder(self: ChunkRenderer, folder: Folder)
	folder.Parent = nil
	local children = folder:GetChildren()
	self.partCount -= #children
	for _, child in children do
		self.pool:release(child :: BasePart)
	end
end

-- Queues building `boxes` as section `section` of `node`, replacing what was there.
function ChunkRenderer.build(
	self: ChunkRenderer,
	node: RenderNode,
	section: number,
	boxes: buffer,
	urgent: boolean,
	onDone: (() -> ())?
)
	local task: Task = {
		node = node,
		section = section,
		boxes = boxes,
		count = buffer.len(boxes) // BOX,
		cursor = 0,
		folder = nil,
		onDone = onDone,
	}
	table.insert(if urgent then self.urgent else self.normal, task)
end

-- Puts the node's model into the workspace.
function ChunkRenderer.show(self: ChunkRenderer, node: RenderNode)
	modelOf(node).Parent = self.root
	self.overlay:onShow(node)
end

-- Removes everything the node displays. Pending builds for it are dropped when reached.
function ChunkRenderer.clear(self: ChunkRenderer, node: RenderNode)
	self.overlay:onClear(node)
	local model = node.model
	if model then
		model.Parent = nil
	end
	for section, folder in node.sections do
		releaseFolder(self, folder)
		node.sections[section] = nil
	end
end

-- Builds part of a task; returns true when the task is finished.
local function work(self: ChunkRenderer, t: Task, deadline: number): boolean
	local node = t.node
	if node.removed then
		if t.folder then
			releaseFolder(self, t.folder)
		end
		return true
	end

	if t.count > 0 then
		local folder: Folder = t.folder or Instance.new("Folder")
		if t.folder == nil then
			folder.Name = tostring(t.section)
			t.folder = folder
		end

		local step, stepY = ChunkLayout.steps(node.level)
		local scale = step * Config.BlockSize
		local scaleY = stepY * Config.BlockSize
		local originX = node.nx * Config.ChunkSize * scale
		local originZ = node.nz * Config.ChunkSize * scale
		local far = node.level > 0
		local plain = far and self.overlay:plainLevel(node.level)
		local boxes = t.boxes
		local pool = self.pool

		-- Parts can be at most MAX_PART studs long: wide boxes of coarse levels and tall boxes in
		-- high terrain are split.
		local maxCells = math.max(1, MAX_PART // scale)
		local maxCellsY = math.max(1, MAX_PART // scaleY)
		while t.cursor < t.count do
			local o = t.cursor * BOX
			local x, y, z = readu16(boxes, o), readu16(boxes, o + 2), readu16(boxes, o + 4)
			local sx, sy, sz = readu16(boxes, o + 6), readu16(boxes, o + 8), readu16(boxes, o + 10)
			local appearance, surface = GreedyMesher.decodeKey(readu16(boxes, o + 12))
			-- Fluid surface below the top of its cell (flowing water steps down).
			local lower = if surface > 0 then (FLUID_FULL - surface) / FLUID_FULL * Config.BlockSize else 0
			for py = y, y + sy - 1, maxCellsY do
				local wy = math.min(maxCellsY, y + sy - py)
				local height = wy * scaleY - (if py + wy == y + sy then lower else 0)
				local cy = py * scaleY + height * 0.5
				for px = x, x + sx - 1, maxCells do
					local wx = math.min(maxCells, x + sx - px)
					for pz = z, z + sz - 1, maxCells do
						local wz = math.min(maxCells, z + sz - pz)
						local part = pool:acquire(appearance, far, plain)
						part.Size = Vector3.new(wx * scale, height, wz * scale)
						part.CFrame =
							CFrame.new(originX + (px + wx * 0.5) * scale, cy, originZ + (pz + wz * 0.5) * scale)
						part.Parent = folder
						self.partCount += 1
					end
				end
			end
			t.cursor += 1
			if t.cursor % 32 == 0 and os.clock() > deadline then
				return false
			end
		end
	end

	-- Swap in the finished section.
	local old = node.sections[t.section]
	local folder = t.folder
	if folder then
		node.sections[t.section] = folder
		folder.Parent = modelOf(node)
	else
		node.sections[t.section] = nil
	end
	if old then
		releaseFolder(self, old)
		-- A merged mesh may still show the old content.
		self.overlay:onChanged(node)
	end
	if t.onDone then
		t.onDone()
	end
	return true
end

-- Should the workers also make quads (for far meshes) for nodes of this level?
function ChunkRenderer.wantsQuads(self: ChunkRenderer, level: number): boolean
	return self.overlay:wantsQuads(level)
end

function ChunkRenderer.setQuads(self: ChunkRenderer, node: RenderNode, quads: buffer, count: number)
	self.overlay:setQuads(node, quads, count)
end

-- Runs queued builds until the frame budget is used. Call once per frame.
function ChunkRenderer.step(self: ChunkRenderer)
	self.overlay:step()
	local deadline = os.clock() + Config.Render.BuildBudgetMs / 1000
	for _, queue in { self.urgent, self.normal } do
		while #queue > 0 do
			if not work(self, queue[1], deadline) then
				return
			end
			table.remove(queue, 1)
			if os.clock() > deadline then
				return
			end
		end
	end
end

function ChunkRenderer.pending(self: ChunkRenderer): number
	return #self.urgent + #self.normal
end

return ChunkRenderer
