--!strict
--[[
	Turns mesh boxes into parts.

	Each chunk node owns a Folder ("model"); each mesh section is a Folder inside it. A node's model
	stays out of the workspace until the streamer calls `show`. MeshOverlay sits on top: it may
	merge stable far nodes into MeshParts and unparent their models meanwhile; it is told about
	every show, clear and change so it can put them back.

	Building (`build`): every section build is a task in RenderSchedule's lanes (edit, near,
	normal, background), built within a frame budget and checked part by part:
	  * edits (lane "edit") get their own Render.EditBudgetMs, so they never wait behind loading;
	  * everything else shares the build budget: Render.BuildBudgetMs, or with Render.AutoBudget
	    an adaptive one (FrameBudget: lower when frames run long, higher while work waits and
	    frames have room, up to 12 ms while the player is frozen waiting for terrain);
	  * normal tasks go by their node's `priority` (the streamer's score, lower first), re-read by
	    `reprioritise`.

	In-place remesh (SectionDiff): a section keeps its boxes and the parts of each box. A new mesh
	is matched against the live one by the boxes' 14 bytes; identical boxes keep their parts
	untouched, only new boxes are built (out of the workspace) and only removed ones go. A section
	with nothing on screen yet, or built for an older texture style, is built whole into a new
	folder. One task per section is uncommitted at a time; a newer one waits for it, or replaces
	it while it has not started (RenderSchedule).

	Going live ("commit"), never leaving a gap or doubling a light:
	  * added parts are parented; removed parts and replaced folders stay Render.SwapFrames frames
	    longer, so a part the engine draws a frame late never shows the sky behind it; their
	    PointLights go off at once. See-through ones too: the mesher draws a lake surface as one
	    box, so an edit in the lake replaces the whole surface, and taking it away at once could
	    show the lake bed for a frame. (Two water surfaces overlapping look darker for those
	    frames, only where boxes changed.)
	  * commit groups (`openGroup`, BuildOptions.group): every section of one batch of edits, in
	    both chunks of a border, goes live in the same frame (RenderSchedule);
	  * `clear` (a node replaced by other levels of detail) also keeps the old model Render.
	    SwapFrames frames, lights off.

	Taking things away is budgeted: models and parts leave the workspace at most
	Render.UnparentPartsPerFrame parts a frame, then their parts go back to the pool (quarantined
	until the next frame: PartPool) or, when it is full, a whole folder is destroyed in one call,
	within Render.ReleaseBudgetMs. `trashNode` (teleports) drops a node without the swap delay:
	nearest first, at once near the destination; `show` never puts a node on screen while a
	trashed model above or below it in the LOD tree is still there.

	Restyle (`restyle`, the settings menu): shadow changes rewrite CastShadow on live parts within
	the build budget; a texture change rebuilds every section off-screen in the background lane
	and swaps it like any other build. Only where no build waits to start (which uses the new look
	anyway), and never in plain far levels (no textures); any newer build replaces a restyle
	(RenderSchedule), so an edit never waits behind one.

	Render.SwapPartsPerFrame is one allowance per frame for the streamer's level of detail swaps
	and MeshOverlay's: `show` counts the parts it puts into the workspace, and the overlay gets
	what is left at the next step.

	Shaped blocks (torches, lanterns: BlockList `shape`) come out of the mesher one cell per box
	(Blocks.singleLut); each becomes one part per shape box, sized and placed from the shape (in
	pixels, 1/16 of a cell) and turned by the box's rotation. PartPool keeps a template per box,
	the glowing one carrying the block's PointLight.

	Sparse lights (glow lichen: GreedyMesher.sparseLightLut) carry their PointLight only where the
	mesher marked the cell (surface field 1, one per GreedyMesher.LIGHT_BOX box); the other cells
	get PartPool's dark template for the light's box. A revealed cavern holds a few hundred, all on
	by default; a finite Caves.LichenLightDistance switches off those farther from the camera
	(ViewSettings; every SPARSE_SWEEP seconds, off again SPARSE_HYSTERESIS blocks further). Lichen
	whose light is off still glows: its speck is Neon.

	Plants (Blocks.appearances `scatter`, `tinted`) are shaped blocks too:
	  * scattered ones are drawn off their cell's centre and turned about its vertical axis
	    (Meshing/Scatter.at, from the world block position: the node's origin plus the cell); each
	    box goes to the cell's centre plus the offset, turned by the yaw, then by its own rotation;
	  * tinted ones (grass, ferns) take their soil's foliage colour, which the mesher packs into
	    the box key (GreedyMesher.decodeKey's surface field): every box's colour times
	    Blocks.FOLIAGE_TINTS[tint], clamped. Their parts' colour is always set, tint or none,
	    because a pooled part may come back from a cell with another tint.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GreedyMesher = require(Shared.Meshing.GreedyMesher)
local Scatter = require(Shared.Meshing.Scatter)
local ChunkLayout = require(Shared.World.ChunkLayout)
local Coords = require(Shared.World.Coords)
local LodTree = require(Shared.World.LodTree)
local Blocks = require(Shared.Blocks)

local PartPool = require(script.Parent.PartPool)
local MeshOverlay = require(script.Parent.MeshOverlay)
local ViewSettings = require(script.Parent.ViewSettings)
local SectionDiff = require(script.Parent.SectionDiff)
local RenderSchedule = require(script.Parent.RenderSchedule)
local FrameBudget = require(script.Parent.FrameBudget)

local BOX = GreedyMesher.BOX_BYTES
local FLUID_FULL = Blocks.FLUID_FULL
local MAX_LEVEL = LodTree.MAX_LEVEL
local readu16 = buffer.readu16
local Render = Config.Render
-- Longest side of a part in studs (engine limit).
local MAX_PART = 2048
-- Sparse lights (glow lichen) near the camera are on: checked this often (seconds), and one that
-- is on goes off this many blocks beyond the distance.
local SPARSE_SWEEP = 0.25
local SPARSE_HYSTERESIS = 8
-- A commit group open longer than this (seconds) stops waiting for its missing tasks.
local GROUP_TIMEOUT = 2

local EDIT = RenderSchedule.EDIT
local NEAR = RenderSchedule.NEAR
local NORMAL = RenderSchedule.NORMAL
local BACKGROUND = RenderSchedule.BACKGROUND
local LANE_NAMES: { [string]: number } = { edit = EDIT, near = NEAR, normal = NORMAL, background = BACKGROUND }

-- Release modes of a folder (see release): pool every part, destroy the folder, or both.
local POOL = 1
local DESTROY = 2
local PARTIAL = 3
local LIST = 4

-- The boxes of shaped appearances, in pixels: size, centre from the cell's centre, rotation.
type ShapePart = { size: Vector3, offset: Vector3, rotation: CFrame }
local shapes: { [number]: { ShapePart } } = {}
for _, appearance in Blocks.appearances do
	local shape = appearance.shape
	if shape then
		local parts: { ShapePart } = {}
		for _, box in shape do
			local r = box.rotation or { 0, 0, 0 }
			table.insert(parts, {
				size = Vector3.new(box.size[1], box.size[2], box.size[3]),
				offset = Vector3.new(box.offset[1], box.offset[2], box.offset[3]),
				rotation = CFrame.Angles(math.rad(r[1]), math.rad(r[2]), math.rad(r[3])),
			})
		end
		shapes[appearance.id] = parts
	end
end

-- Scattered appearances (plants: Meshing/Scatter).
local scattered: { [number]: boolean } = {}
--[[
	Colours of tinted appearances' boxes (grass, ferns), per box and tint: [box][1] untinted,
	[box][t + 1] times Blocks.FOLIAGE_TINTS[t], each channel clamped to 255.
]]
local tintColours: { [number]: { { Color3 } } } = {}
for _, appearance in Blocks.appearances do
	local shape = appearance.shape
	if shape and appearance.scatter then
		scattered[appearance.id] = true
	end
	if shape and appearance.tinted then
		local boxes = {}
		for i, box in shape do
			local c = box.color or appearance.color
			local colours = { Color3.fromRGB(c[1], c[2], c[3]) }
			for t, m in Blocks.FOLIAGE_TINTS do
				colours[t + 1] = Color3.fromRGB(
					math.min(255, math.round(c[1] * m[1])),
					math.min(255, math.round(c[2] * m[2])),
					math.min(255, math.round(c[3] * m[3]))
				)
			end
			boxes[i] = colours
		end
		tintColours[appearance.id] = boxes
	end
end

-- What the renderer needs to know about a chunk node (also read: an optional `priority` number).
export type RenderNode = {
	level: number,
	nx: number,
	nz: number,
	removed: boolean,
	model: Folder?,
	sections: { [number]: Folder },
}

export type Group = RenderSchedule.Group

--[[
	How to build a section:
	  lane      "edit" (player and server edits), "near" (cave reveal, plants, seams), "normal"
	            (generation, the default) or "background";
	  priority  lower is sooner (default: the node's `priority`);
	  group     a commit group from `openGroup`: goes live with the rest of the group;
	  onDone    called when the section is live (in the node's model).
]]
export type BuildOptions = {
	lane: string?,
	priority: number?,
	group: Group?,
	onDone: (() -> ())?,
}

-- A section's boxes and parts (live, or what a staged build will make live).
type Record = {
	boxes: buffer,
	count: number,
	-- Parts box by box: box i's are parts[first[i + 1]] .. parts[first[i + 2] - 1].
	parts: { BasePart },
	first: { number },
	folder: Folder?,
	-- Parts carrying a PointLight.
	lights: { BasePart },
	-- PartPool.textureGen the parts were made with.
	texture: number,
}

type NodeState = {
	records: { [number]: Record },
	-- Parts in live records.
	parts: number,
}

-- The renderer's state of one task (RenderSchedule.Task.data).
type Build = {
	boxes: buffer,
	count: number,
	-- Restyle: rebuild whatever the section shows when the task starts.
	restyle: boolean,
	noop: boolean,
	started: boolean,
	-- Next box, and how many parts of it were built already.
	cursor: number,
	sub: number,
	base: Record?,
	-- Diff: the old box each new box keeps (-1: built), and old boxes nothing kept.
	matched: { number }?,
	removed: { number }?,
	parts: { BasePart },
	first: { number },
	lights: { BasePart },
	-- Parts built for the diff (not in any folder of ours until the commit).
	added: { BasePart },
	-- Built whole into a new folder.
	folder: Folder?,
	texture: number,
	callbacks: { () -> () },
	-- Placement.
	originX: number,
	originZ: number,
	scale: number,
	scaleY: number,
	step: number,
	stepY: number,
	far: boolean,
	plain: boolean,
	maxCells: number,
	maxCellsY: number,
}

type Task = RenderSchedule.Task

-- Something leaving the workspace after Render.SwapFrames frames.
type Retiring = {
	due: number,
	parts: number,
	model: Folder?,
	folder: Folder?,
	list: { BasePart }?,
	-- The folder the listed parts are still in.
	inFolder: Folder?,
	records: { Record }?,
	done: boolean?,
}

-- A trashed (teleport) model still in the workspace.
type Trash = {
	key: number,
	level: number,
	nx: number,
	nz: number,
	model: Folder,
	records: { Record },
	parts: number,
	distance: number,
	done: boolean,
}

-- Parts going back to the pool (or destroyed).
type Release = {
	parts: { BasePart },
	folder: Folder?,
	index: number,
	mode: number,
	keep: number,
}

type SparseEntry = { light: PointLight, position: Vector3, on: boolean }

type WalkEntry = { node: RenderNode, section: number }

export type Stats = {
	-- Tasks queued per lane, waiting behind their section's previous task, built and waiting for
	-- their commit group.
	edit: number,
	near: number,
	normal: number,
	background: number,
	parked: number,
	staged: number,
	-- Waiting to leave the workspace (retiring: swap delay; trash: teleports) and parts waiting to
	-- go back to the pool.
	retiring: number,
	trash: number,
	trashParts: number,
	releasing: number,
	-- The build budget and frame times (ms).
	budgetMs: number,
	usualMs: number,
	recentMs: number,
	-- Pool: parts pooled, created, reused, destroyed (totals).
	pooled: number,
	cloned: number,
	reused: number,
	destroyed: number,
}

export type ChunkRenderer = {
	root: Folder,
	pool: PartPool.PartPool,
	overlay: MeshOverlay.MeshOverlay,
	schedule: RenderSchedule.Schedule,
	budget: FrameBudget.Budget,
	states: { [RenderNode]: NodeState },
	frame: number,
	lastStep: number,
	frozen: boolean,
	-- Settings overrides of Render.BuildBudgetMs / Render.AutoBudget (nil: use Config).
	baseBudget: number?,
	autoBudget: boolean?,
	-- Parts built in the current budget window (each window builds at least one).
	windowBuilt: number,
	-- Parts currently owned by sections (including ones not shown yet), and those with a light.
	partCount: number,
	lightCount: number,
	-- The PointLights of sparse lights (glow lichen) by their part, with where they are (studs);
	-- how many there are and how many are on (near the camera).
	sparseLights: { [BasePart]: SparseEntry },
	sparseCount: number,
	sparseOn: number,
	nextSparseSweep: number,
	-- Tasks to put live at the next step (their group completed outside it).
	ready: { Task },
	retiring: { Retiring },
	retiringHead: number,
	-- Sorted farthest first (the nearest is taken from the end).
	trash: { Trash },
	trashAt: { [number]: { Trash } },
	trashBelow: { [number]: number },
	releases: { Release },
	releaseHead: number,
	-- Folders still holding removed parts that wait for the swap delay (how many lists).
	removalsIn: { [Folder]: number },
	-- Sections whose live parts need their shadow style refreshed (looked up when reached).
	walk: { WalkEntry },
	walkIndex: number,
	walkPart: number,
	-- Inside `step` (things done outside it count from the step about to run).
	stepping: boolean,
	-- Parts `show` put into the workspace since the last step (Render.SwapPartsPerFrame).
	swapUsed: number,

	build: (
		self: ChunkRenderer,
		node: RenderNode,
		section: number,
		boxes: buffer,
		options: (boolean | BuildOptions)?,
		onDone: (() -> ())?
	) -> (),
	openGroup: (self: ChunkRenderer) -> Group,
	holdGroup: (self: ChunkRenderer, group: Group) -> (),
	closeGroup: (self: ChunkRenderer, group: Group) -> (),
	show: (self: ChunkRenderer, node: RenderNode) -> (),
	clear: (self: ChunkRenderer, node: RenderNode) -> (),
	trashNode: (self: ChunkRenderer, node: RenderNode, distance: number, immediate: boolean?) -> (),
	partsOf: (self: ChunkRenderer, node: RenderNode) -> number,
	trashParts: (self: ChunkRenderer) -> number,
	reprioritise: (self: ChunkRenderer) -> (),
	setFrozen: (self: ChunkRenderer, frozen: boolean) -> (),
	setBuildBudget: (self: ChunkRenderer, ms: number?) -> (),
	budgetMs: (self: ChunkRenderer) -> number,
	restyle: (self: ChunkRenderer, style: PartPool.Style) -> PartPool.StyleChanges,
	wantsQuads: (self: ChunkRenderer, level: number) -> boolean,
	setQuads: (self: ChunkRenderer, node: RenderNode, quads: buffer, count: number) -> (),
	step: (self: ChunkRenderer, dt: number?) -> (),
	pending: (self: ChunkRenderer) -> number,
	busy: (self: ChunkRenderer) -> boolean,
	stats: (self: ChunkRenderer) -> Stats,
}

local ChunkRenderer = {}
ChunkRenderer.__index = ChunkRenderer

function ChunkRenderer.new(): ChunkRenderer
	local root = Instance.new("Folder")
	root.Name = "IceVoxelWorld"
	root.Parent = workspace

	local self = {
		root = root,
		pool = PartPool.new(Render.PoolLimit),
		overlay = MeshOverlay.new(root),
		schedule = RenderSchedule.new(function(task: Task): boolean
			return (task.data :: Build).started
		end),
		budget = FrameBudget.new(nil, Render.BuildBudgetMs),
		states = {},
		frame = 0,
		lastStep = os.clock(),
		frozen = false,
		baseBudget = nil,
		autoBudget = nil,
		windowBuilt = 0,
		partCount = 0,
		lightCount = 0,
		sparseLights = {},
		sparseCount = 0,
		sparseOn = 0,
		nextSparseSweep = 0,
		ready = {},
		retiring = {},
		retiringHead = 1,
		trash = {},
		trashAt = {},
		trashBelow = {},
		releases = {},
		releaseHead = 1,
		removalsIn = {},
		walk = {},
		walkIndex = 1,
		walkPart = 1,
		stepping = false,
		swapUsed = 0,
	}
	local renderer = (setmetatable(self, ChunkRenderer) :: any) :: ChunkRenderer
	-- The overlay budgets hiding and showing nodes by their parts.
	renderer.overlay.countParts = function(node: any): number
		return renderer:partsOf(node)
	end
	return renderer
end

-- The frame a swap delay counts from: the step running now, or the next one when called between
-- steps (the streamer shows and clears nodes before it steps the renderer).
local function dueFrame(self: ChunkRenderer): number
	return self.frame + (if self.stepping then 0 else 1) + math.max(0, Render.SwapFrames)
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

local function stateOf(self: ChunkRenderer, node: RenderNode): NodeState
	local state = self.states[node]
	if state == nil then
		state = { records = {}, parts = 0 }
		self.states[node] = state
	end
	return state :: NodeState
end

local function nodeKey(level: number, nx: number, nz: number): number
	return Coords.nodeKey(level, nx, nz)
end

--[[ Lights ]]

-- Is a sparse light `distance` studs from the camera on (`on`: it is now)?
local function sparseWanted(distance: number, on: boolean): boolean
	local reach = (ViewSettings.lichenLightDistance() + (if on then SPARSE_HYSTERESIS else 0)) * Config.BlockSize
	return distance < reach
end

-- A part with a light was built: its light on (sparse lights: when near the camera).
local function lightOn(self: ChunkRenderer, part: BasePart, sparse: boolean)
	self.lightCount += 1
	local light = self.pool:light(part)
	if light == nil then
		return
	end
	if not sparse then
		light.Enabled = true
		return
	end
	local position = part.Position
	local on = sparseWanted((position - workspace.CurrentCamera.CFrame.Position).Magnitude, false)
	light.Enabled = on
	self.sparseLights[part] = { light = light, position = position, on = on }
	self.sparseCount += 1
	if on then
		self.sparseOn += 1
	end
end

-- A part with a light leaves its section: light off now (lights never double during swaps).
local function lightOff(self: ChunkRenderer, part: BasePart)
	self.lightCount -= 1
	local light = self.pool:light(part)
	if light then
		light.Enabled = false
	end
	local entry = self.sparseLights[part]
	if entry then
		self.sparseLights[part] = nil
		self.sparseCount -= 1
		if entry.on then
			self.sparseOn -= 1
		end
	end
end

-- Switches sparse lights on near the camera and off far from it.
local function sweepSparse(self: ChunkRenderer)
	local camera = workspace.CurrentCamera.CFrame.Position
	local count = 0
	for _, entry in self.sparseLights do
		local was = entry.on
		local on = sparseWanted((entry.position - camera).Magnitude, was)
		if on ~= was then
			entry.on = on
			entry.light.Enabled = on
		end
		if on then
			count += 1
		end
	end
	self.sparseOn = count
end

--[[ Taking things away ]]

local function queueRelease(self: ChunkRenderer, parts: { BasePart }, folder: Folder?)
	if #parts == 0 and folder == nil then
		return
	end
	table.insert(self.releases, { parts = parts, folder = folder, index = 1, mode = 0, keep = 0 })
end

-- A record's parts leave the section (out of the workspace already, or about to be).
local function releaseRecord(self: ChunkRenderer, record: Record)
	queueRelease(self, record.parts, record.folder)
end

-- A record stops being part of its node: lights off, parts no longer counted.
local function dropRecord(self: ChunkRenderer, record: Record)
	for _, part in record.lights do
		lightOff(self, part)
	end
	self.partCount -= #record.parts
end

local function retire(self: ChunkRenderer, entry: Retiring)
	table.insert(self.retiring, entry)
end

-- Unparents a retiring entry now; returns the parts it took out of the workspace.
local function unparentRetiring(self: ChunkRenderer, entry: Retiring): number
	if entry.done then
		return 0
	end
	entry.done = true
	if entry.model then
		entry.model.Parent = nil
	elseif entry.folder then
		entry.folder.Parent = nil
	elseif entry.list then
		for _, part in entry.list do
			part.Parent = nil
		end
		queueRelease(self, entry.list, nil)
		local folder = entry.inFolder
		if folder then
			local n = (self.removalsIn[folder] or 1) - 1
			if n > 0 then
				self.removalsIn[folder] = n
			else
				self.removalsIn[folder] = nil
			end
		end
	end
	if entry.records then
		for _, record in entry.records do
			releaseRecord(self, record)
		end
	end
	return entry.parts
end

local function unindexTrash(self: ChunkRenderer, entry: Trash)
	local list = self.trashAt[entry.key]
	if list then
		local i = table.find(list, entry)
		if i then
			table.remove(list, i)
		end
		if #list == 0 then
			self.trashAt[entry.key] = nil
		end
	end
	for level = entry.level + 1, MAX_LEVEL do
		local shift = level - entry.level
		local key = nodeKey(level, entry.nx // bit32.lshift(1, shift), entry.nz // bit32.lshift(1, shift))
		local n = (self.trashBelow[key] or 1) - 1
		if n > 0 then
			self.trashBelow[key] = n
		else
			self.trashBelow[key] = nil
		end
	end
end

-- Takes a trashed model out of the workspace now; returns its parts.
local function unparentTrash(self: ChunkRenderer, entry: Trash): number
	if entry.done then
		return 0
	end
	entry.done = true
	unindexTrash(self, entry)
	entry.model.Parent = nil
	for _, record in entry.records do
		releaseRecord(self, record)
	end
	return entry.parts
end

-- Before `node` is shown: trashed models over or under it leave the workspace now.
local function clearTrashAround(self: ChunkRenderer, node: RenderNode)
	if next(self.trashAt) == nil then
		return
	end
	for level = node.level, MAX_LEVEL do
		local shift = level - node.level
		local key = nodeKey(level, node.nx // bit32.lshift(1, shift), node.nz // bit32.lshift(1, shift))
		local list = self.trashAt[key]
		if list then
			for _, entry in table.clone(list) do
				unparentTrash(self, entry)
			end
		end
	end
	if (self.trashBelow[nodeKey(node.level, node.nx, node.nz)] or 0) > 0 then
		for _, entry in table.clone(self.trash) do
			if not entry.done and entry.level < node.level then
				local shift = node.level - entry.level
				if entry.nx // bit32.lshift(1, shift) == node.nx and entry.nz // bit32.lshift(1, shift) == node.nz then
					unparentTrash(self, entry)
				end
			end
		end
	end
end

--[[ Building ]]

-- Adds a part just built to the task.
local function addPart(self: ChunkRenderer, b: Build, part: BasePart, sparse: boolean)
	table.insert(b.parts, part)
	local folder = b.folder
	if folder then
		part.Parent = folder
	else
		table.insert(b.added, part)
	end
	if self.pool:hasLight(part) then
		table.insert(b.lights, part)
		lightOn(self, part, sparse)
	end
	self.partCount += 1
	self.windowBuilt += 1
end

--[[
	Builds the parts of box `i`, skipping the `b.sub` built in an earlier frame. Returns false
	when the deadline passed before the next part (at least one part is built per window).
]]
local function buildBox(self: ChunkRenderer, b: Build, node: RenderNode, i: number, deadline: number): boolean
	local boxes = b.boxes
	local o = i * BOX
	local x, y, z = readu16(boxes, o), readu16(boxes, o + 2), readu16(boxes, o + 4)
	local sx, sy, sz = readu16(boxes, o + 6), readu16(boxes, o + 8), readu16(boxes, o + 10)
	local appearance, surface = GreedyMesher.decodeKey(readu16(boxes, o + 12))
	local pool = self.pool
	local scale, scaleY = b.scale, b.scaleY
	local originX, originZ = b.originX, b.originZ
	local far, plain = b.far, b.plain
	local skip = b.sub
	local k = 0
	local shape = shapes[appearance]
	if shape then
		-- One part per shape box in every cell (shaped boxes are single cells).
		local pixel = Vector3.new(scale, scaleY, scale) / 16
		local scatter = scattered[appearance]
		-- (For tinted plants the surface field is the soil's tint; see GreedyMesher.)
		local tints = tintColours[appearance]
		local tint = if tints then math.min(surface, #Blocks.FOLIAGE_TINTS) + 1 else 1
		-- (For sparse lights it says whether this cell carries the light.)
		local sparseLight = buffer.readu8(GreedyMesher.sparseLightLut, appearance) == 1
		local dark = sparseLight and surface == 0
		for cy = y, y + sy - 1 do
			for cz = z, z + sz - 1 do
				for cx = x, x + sx - 1 do
					if k + #shape <= skip then
						k += #shape
						continue
					end
					local centre =
						Vector3.new(originX + (cx + 0.5) * scale, (cy + 0.5) * scaleY, originZ + (cz + 0.5) * scale)
					-- A plant's offset and turn come from its world block position.
					local cell: CFrame? = nil
					if scatter then
						local dx, dz, yaw = Scatter.at(
							appearance,
							(node.nx * Config.ChunkSize + cx) * b.step,
							cy * b.stepY,
							(node.nz * Config.ChunkSize + cz) * b.step
						)
						cell = CFrame.new(centre + Vector3.new(dx * pixel.X, 0, dz * pixel.Z))
							* CFrame.Angles(0, yaw, 0)
					end
					for index, box in shape do
						if k < skip then
							k += 1
							continue
						end
						if self.windowBuilt > 0 and os.clock() > deadline then
							b.sub = k
							return false
						end
						local part = pool:acquire(appearance, far, plain, index, dark)
						part.Size = box.size * pixel
						part.CFrame = if cell
							then cell * CFrame.new(box.offset * pixel) * box.rotation
							else CFrame.new(centre + box.offset * pixel) * box.rotation
						if tints then
							part.Color = tints[index][tint]
						end
						addPart(self, b, part, sparseLight)
						k += 1
					end
				end
			end
		end
		return true
	end
	-- Fluid surface below the top of its cell (flowing water steps down). Parts are at most
	-- MAX_PART studs long: wide boxes of coarse levels and tall boxes in high terrain are split.
	local lower = if surface > 0 then (FLUID_FULL - surface) / FLUID_FULL * Config.BlockSize else 0
	local maxCells, maxCellsY = b.maxCells, b.maxCellsY
	for py = y, y + sy - 1, maxCellsY do
		local wy = math.min(maxCellsY, y + sy - py)
		local height = wy * scaleY - (if py + wy == y + sy then lower else 0)
		local cy = py * scaleY + height * 0.5
		for px = x, x + sx - 1, maxCells do
			local wx = math.min(maxCells, x + sx - px)
			for pz = z, z + sz - 1, maxCells do
				if k < skip then
					k += 1
					continue
				end
				if self.windowBuilt > 0 and os.clock() > deadline then
					b.sub = k
					return false
				end
				local wz = math.min(maxCells, z + sz - pz)
				local part = pool:acquire(appearance, far, plain)
				part.Size = Vector3.new(wx * scale, height, wz * scale)
				part.CFrame = CFrame.new(originX + (px + wx * 0.5) * scale, cy, originZ + (pz + wz * 0.5) * scale)
				addPart(self, b, part, false)
				k += 1
			end
		end
	end
	return true
end

-- First work on a task: what it builds against, and the diff.
local function startBuild(self: ChunkRenderer, task: Task)
	local b: Build = task.data
	local node: RenderNode = task.node
	local base = stateOf(self, node).records[task.section]
	b.started = true
	b.base = base
	b.texture = self.pool.textureGen
	if b.restyle then
		-- Rebuild what is live now, unless a newer build already used the current look.
		if base == nil or base.texture == b.texture then
			b.noop = true
			return
		end
		b.boxes, b.count = base.boxes, base.count
	end
	b.first = table.create(b.count + 1)
	if base and base.count > 0 and b.count > 0 and base.texture == b.texture and base.folder then
		local matched, removed = SectionDiff.match(base.boxes, base.count, b.boxes, b.count)
		b.matched, b.removed = matched, removed
	elseif b.count > 0 then
		local folder = Instance.new("Folder")
		folder.Name = tostring(task.section)
		b.folder = folder
	end
	local step, stepY = ChunkLayout.steps(node.level)
	b.step, b.stepY = step, stepY
	b.scale = step * Config.BlockSize
	b.scaleY = stepY * Config.BlockSize
	b.originX = node.nx * Config.ChunkSize * b.scale
	b.originZ = node.nz * Config.ChunkSize * b.scale
	b.far = node.level > 0
	b.plain = b.far and self.overlay:plainLevel(node.level)
	b.maxCells = math.max(1, MAX_PART // b.scale)
	b.maxCellsY = math.max(1, MAX_PART // b.scaleY)
end

-- Builds part of a task; returns true when it is built.
local function work(self: ChunkRenderer, task: Task, deadline: number): boolean
	local b: Build = task.data
	if not b.started then
		startBuild(self, task)
	end
	if b.noop then
		return true
	end
	local matched = b.matched
	local base = b.base
	local parts, first = b.parts, b.first
	while b.cursor < b.count do
		local i = b.cursor
		if b.sub == 0 then
			first[i + 1] = #parts + 1
		end
		local j = if matched then matched[i + 1] else -1
		if j >= 0 and base then
			-- Kept: the live parts of the identical old box.
			local from, to = base.first[j + 1], base.first[j + 2] - 1
			table.move(base.parts, from, to, #parts + 1, parts)
		elseif not buildBox(self, b, task.node, i, deadline) then
			return false
		end
		b.cursor = i + 1
		b.sub = 0
	end
	first[b.count + 1] = #parts + 1
	return true
end

-- Releases what a task built that will never go live.
local function discard(self: ChunkRenderer, task: Task)
	local b: Build = task.data
	if not b.started or b.noop then
		return
	end
	for _, part in b.lights do
		lightOff(self, part)
	end
	if b.folder then
		self.partCount -= #b.parts
		queueRelease(self, b.parts, b.folder)
	else
		self.partCount -= #b.added
		queueRelease(self, b.added, nil)
	end
	b.started = false
end

-- Takes a record's folder away (deferred while it is on screen).
local function retireRecord(self: ChunkRenderer, node: RenderNode, record: Record)
	dropRecord(self, record)
	local folder = record.folder
	local model = node.model
	if folder and model and model.Parent ~= nil then
		retire(self, {
			due = dueFrame(self),
			parts = #record.parts,
			folder = folder,
			records = { record },
		})
	else
		if folder then
			folder.Parent = nil
		end
		releaseRecord(self, record)
	end
end

-- Puts a built task live.
local function commit(self: ChunkRenderer, task: Task)
	local b: Build = task.data
	local node: RenderNode = task.node
	self.schedule:committed(task)
	if node.removed then
		discard(self, task)
		return
	end
	if not b.noop then
		local state = stateOf(self, node)
		local section = task.section
		local base = state.records[section]
		local record: Record? = nil
		local changed = true
		if b.count == 0 then
			if base then
				retireRecord(self, node, base)
			else
				changed = false
			end
		elseif b.matched == nil then
			local folder = b.folder :: Folder
			for _, part in b.parts do
				if not self.pool:isCurrent(part) then
					self.pool:refresh(part)
				end
			end
			folder.Parent = modelOf(node)
			if base then
				retireRecord(self, node, base)
			end
			record = {
				boxes = b.boxes,
				count = b.count,
				parts = b.parts,
				first = b.first,
				folder = folder,
				lights = b.lights,
				texture = b.texture,
			}
		else
			local live = (base :: Record).folder :: Folder
			local old = base :: Record
			for _, part in b.added do
				if not self.pool:isCurrent(part) then
					self.pool:refresh(part)
				end
				part.Parent = live
			end
			-- Removed boxes: lights off now, parts after the swap delay (see the header).
			local removedLit: { [BasePart]: boolean } = {}
			local later: { BasePart } = {}
			local pool = self.pool
			for _, j in b.removed :: { number } do
				for k = old.first[j + 1], old.first[j + 2] - 1 do
					local part = old.parts[k]
					if pool:hasLight(part) then
						lightOff(self, part)
						removedLit[part] = true
					end
					table.insert(later, part)
				end
			end
			self.partCount -= #later
			if #later > 0 then
				local model = node.model
				if model and model.Parent ~= nil then
					retire(self, { due = dueFrame(self), parts = #later, list = later, inFolder = live })
					-- Until then the folder must not be destroyed with them inside (releaseStep).
					self.removalsIn[live] = (self.removalsIn[live] or 0) + 1
				else
					for _, part in later do
						part.Parent = nil
					end
					queueRelease(self, later, nil)
				end
			end
			local lights: { BasePart } = {}
			for _, part in old.lights do
				if not removedLit[part] then
					table.insert(lights, part)
				end
			end
			for _, part in b.lights do
				table.insert(lights, part)
			end
			changed = #b.added > 0 or #(b.removed :: { number }) > 0
			record = {
				boxes = b.boxes,
				count = b.count,
				parts = b.parts,
				first = b.first,
				folder = live,
				lights = lights,
				texture = b.texture,
			}
		end
		state.parts += (if record then #record.parts else 0) - (if base then #base.parts else 0)
		if record then
			state.records[section] = record
		else
			state.records[section] = nil
		end
		if record and record.folder then
			node.sections[section] = record.folder :: Folder
		else
			node.sections[section] = nil
		end
		if base and changed then
			-- A merged mesh may still show the old content.
			self.overlay:onChanged(node)
		end
	end
	for _, callback in b.callbacks do
		callback()
	end
end

local function commitAll(self: ChunkRenderer, tasks: { Task }?)
	if tasks then
		for _, task in tasks do
			commit(self, task)
		end
	end
end

local function newTask(node: RenderNode, section: number, lane: number, b: Build): Task
	return {
		node = node,
		section = section,
		lane = lane,
		priority = nil,
		group = nil,
		state = 0,
		seq = 0,
		data = b,
	}
end

local function newBuild(boxes: buffer, restyle: boolean): Build
	return {
		boxes = boxes,
		count = buffer.len(boxes) // BOX,
		restyle = restyle,
		noop = false,
		started = false,
		cursor = 0,
		sub = 0,
		base = nil,
		matched = nil,
		removed = nil,
		parts = {},
		first = {},
		lights = {},
		added = {},
		folder = nil,
		texture = 0,
		callbacks = {},
		originX = 0,
		originZ = 0,
		scale = 0,
		scaleY = 0,
		step = 1,
		stepY = 1,
		far = false,
		plain = false,
		maxCells = 1,
		maxCellsY = 1,
	}
end

local function addTask(self: ChunkRenderer, task: Task)
	local replaced = self.schedule:add(task)
	if replaced then
		-- The newer build takes over the callbacks of those it replaces, theirs first (first
		-- builds count their sections through them).
		local b: Build = task.data
		local callbacks: { () -> () } = {}
		for _, old in replaced do
			local ob: Build = old.data
			table.move(ob.callbacks, 1, #ob.callbacks, #callbacks + 1, callbacks)
			discard(self, old)
		end
		table.move(b.callbacks, 1, #b.callbacks, #callbacks + 1, callbacks)
		b.callbacks = callbacks
	end
end

--[[ Public ]]

--[[
	Queues building `boxes` as section `section` of `node`, replacing what is there. `options`:
	BuildOptions, or (older form) true for the near lane; `onDone` as BuildOptions.onDone.
]]
function ChunkRenderer.build(
	self: ChunkRenderer,
	node: RenderNode,
	section: number,
	boxes: buffer,
	options: (boolean | BuildOptions)?,
	onDone: (() -> ())?
)
	if node.removed then
		return
	end
	local lane = NORMAL
	local b = newBuild(boxes, false)
	local task = newTask(node, section, lane, b)
	local callback = onDone
	if type(options) == "table" then
		local name = options.lane
		if name then
			lane = LANE_NAMES[name] or error(`unknown build lane '{name}'`)
		end
		task.priority = options.priority
		task.group = options.group
		callback = options.onDone or onDone
	elseif options == true then
		lane = NEAR
	end
	task.lane = lane
	if callback then
		table.insert(b.callbacks, callback)
	end
	addTask(self, task)
end

-- A new commit group, held once by the caller (closeGroup when its tasks were all added).
function ChunkRenderer.openGroup(self: ChunkRenderer): Group
	return self.schedule:openGroup(os.clock())
end

-- One more hold (a job that will add tasks to the group).
function ChunkRenderer.holdGroup(self: ChunkRenderer, group: Group)
	self.schedule:hold(group)
end

-- Releases a hold (the job's tasks were added, or it failed). Complete groups go live next step.
function ChunkRenderer.closeGroup(self: ChunkRenderer, group: Group)
	local ready = self.schedule:close(group)
	if ready then
		for _, task in ready do
			table.insert(self.ready, task)
		end
	end
end

-- Puts the node's model into the workspace (trashed models over or under it leave first).
function ChunkRenderer.show(self: ChunkRenderer, node: RenderNode)
	clearTrashAround(self, node)
	local model = modelOf(node)
	if model.Parent == nil then
		self.swapUsed += self:partsOf(node)
	end
	model.Parent = self.root
	self.overlay:onShow(node)
end

-- Everything the node displays stops being its: tasks dropped, lights off. Returns its records.
local function detach(self: ChunkRenderer, node: RenderNode): { Record }
	self.overlay:onClear(node)
	local dropped, live = self.schedule:drop(node)
	for _, task in dropped do
		discard(self, task)
	end
	for _, task in live do
		table.insert(self.ready, task)
	end
	local records: { Record } = {}
	local state = self.states[node]
	if state then
		self.states[node] = nil
		for _, record in state.records do
			dropRecord(self, record)
			table.insert(records, record)
		end
	end
	table.clear(node.sections)
	return records
end

local function partsIn(records: { Record }): number
	local n = 0
	for _, record in records do
		n += #record.parts
	end
	return n
end

--[[
	Removes everything the node displays (a level-of-detail change). Its lights go off now; its
	model stays in the workspace Render.SwapFrames frames longer (its replacement may be drawn a
	frame late), then leaves within the unparent budget. Pending builds for it are dropped.
]]
function ChunkRenderer.clear(self: ChunkRenderer, node: RenderNode)
	local records = detach(self, node)
	local model = node.model
	if model and model.Parent ~= nil then
		retire(self, {
			due = dueFrame(self),
			parts = partsIn(records),
			model = model,
			records = records,
		})
	else
		for _, record in records do
			releaseRecord(self, record)
		end
	end
end

--[[
	Removes a node without the swap delay (teleports: nothing replaces it where it is). Its model
	leaves the workspace at once with `immediate` (near the destination), otherwise nearest
	`distance` first within Render.UnparentPartsPerFrame; `show` takes it away at once when a node
	over or under it appears.
]]
function ChunkRenderer.trashNode(self: ChunkRenderer, node: RenderNode, distance: number, immediate: boolean?)
	local records = detach(self, node)
	local model = node.model
	if model == nil or model.Parent == nil then
		for _, record in records do
			releaseRecord(self, record)
		end
		return
	end
	local entry: Trash = {
		key = nodeKey(node.level, node.nx, node.nz),
		level = node.level,
		nx = node.nx,
		nz = node.nz,
		model = model,
		records = records,
		parts = partsIn(records),
		distance = distance,
		done = false,
	}
	local list = self.trashAt[entry.key]
	if list == nil then
		list = {}
		self.trashAt[entry.key] = list
	end
	table.insert(list, entry)
	for level = node.level + 1, MAX_LEVEL do
		local shift = level - node.level
		local key = nodeKey(level, node.nx // bit32.lshift(1, shift), node.nz // bit32.lshift(1, shift))
		self.trashBelow[key] = (self.trashBelow[key] or 0) + 1
	end
	if immediate then
		unparentTrash(self, entry)
		return
	end
	-- Farthest first; the nearest is taken from the end.
	local trash = self.trash
	local lo, hi = 1, #trash + 1
	while lo < hi do
		local mid = (lo + hi) // 2
		if trash[mid].distance >= distance then
			lo = mid + 1
		else
			hi = mid
		end
	end
	table.insert(trash, lo, entry)
end

-- Parts in the node's live sections (for the streamer's swap budget).
function ChunkRenderer.partsOf(self: ChunkRenderer, node: RenderNode): number
	local state = self.states[node]
	return if state then state.parts else 0
end

-- Parts of trashed models still in the workspace.
function ChunkRenderer.trashParts(self: ChunkRenderer): number
	local n = 0
	for _, entry in self.trash do
		if not entry.done then
			n += entry.parts
		end
	end
	return n
end

-- Re-reads node priorities (call after the streamer changed them).
function ChunkRenderer.reprioritise(self: ChunkRenderer)
	self.schedule:reprioritise()
end

-- The player is frozen waiting for terrain: the adaptive budget may go up to 12 ms.
function ChunkRenderer.setFrozen(self: ChunkRenderer, frozen: boolean)
	self.frozen = frozen
end

-- A fixed build budget (ms), or nil for the adaptive one (base Render.BuildBudgetMs).
function ChunkRenderer.setBuildBudget(self: ChunkRenderer, ms: number?)
	if ms then
		self.baseBudget = ms
		self.autoBudget = false
	else
		self.baseBudget = nil
		self.autoBudget = true
	end
end

-- The build budget in use (ms).
function ChunkRenderer.budgetMs(self: ChunkRenderer): number
	return self.budget.budget
end

--[[
	Applies a new shadow / far shadow / texture style: PartPool templates now, live parts within
	the build budget (shadows), sections rebuilt off-screen and swapped (textures). Returns what
	changed.
]]
function ChunkRenderer.restyle(self: ChunkRenderer, style: PartPool.Style): PartPool.StyleChanges
	local changes = self.pool:setStyle(style)
	self.overlay:restyle(style.farShadows)
	if changes.shadows or changes.farShadows then
		for node, state in self.states do
			local near = node.level == 0
			if (near and changes.shadows) or (not near and changes.farShadows) then
				for section in state.records do
					table.insert(self.walk, { node = node, section = section })
				end
			end
		end
	end
	if changes.textures then
		local schedule = self.schedule
		-- Live sections, and first builds that may have started with the old look.
		local sections: { WalkEntry } = {}
		for node, state in self.states do
			for section in state.records do
				table.insert(sections, { node = node, section = section })
			end
		end
		for node, slots in schedule.slots do
			local state = self.states[node]
			for section in slots do
				if state == nil or state.records[section] == nil then
					table.insert(sections, { node = node, section = section })
				end
			end
		end
		for _, entry in sections do
			local node = entry.node
			-- (Plain far levels have no textures; a build that starts later uses the new look.)
			if
				not (node.level > 0 and self.overlay:plainLevel(node.level))
				and not schedule:startsLater(node, entry.section)
			then
				local task = newTask(node, entry.section, BACKGROUND, newBuild(buffer.create(0), true))
				task.restyle = true
				addTask(self, task)
			end
		end
	end
	return changes
end

-- Should the workers also make quads (for far meshes) for nodes of this level?
function ChunkRenderer.wantsQuads(self: ChunkRenderer, level: number): boolean
	return self.overlay:wantsQuads(level)
end

function ChunkRenderer.setQuads(self: ChunkRenderer, node: RenderNode, quads: buffer, count: number)
	self.overlay:setQuads(node, quads, count)
end

--[[ Per frame ]]

-- Builds one lane's tasks until the deadline; false when time ran out.
local function runLane(self: ChunkRenderer, lane: number, deadline: number): boolean
	local schedule = self.schedule
	while true do
		local task = schedule:peek(lane)
		if task == nil then
			return true
		end
		if not work(self, task, deadline) then
			return false
		end
		schedule:pop(lane)
		commitAll(self, schedule:stage(task))
		if os.clock() > deadline then
			return false
		end
	end
end

-- Takes due retiring and trashed things out of the workspace, within the part allowance.
local function unparentStep(self: ChunkRenderer)
	local allowance = Render.UnparentPartsPerFrame
	local used = 0
	local retiring = self.retiring
	local head = self.retiringHead
	while head <= #retiring do
		local entry = retiring[head]
		if entry.due > self.frame or (used > 0 and used + entry.parts > allowance) then
			break
		end
		used += unparentRetiring(self, entry)
		head += 1
	end
	if head > #retiring then
		table.clear(retiring)
		head = 1
	elseif head > 64 and head > #retiring // 2 then
		table.move(retiring, head, #retiring, 1)
		local keep = #retiring - head + 1
		for i = #retiring, keep + 1, -1 do
			retiring[i] = nil
		end
		head = 1
	end
	self.retiringHead = head
	local trash = self.trash
	while #trash > 0 do
		local entry = trash[#trash]
		if entry.done then
			trash[#trash] = nil
			continue
		end
		if used > 0 and used + entry.parts > allowance then
			break
		end
		trash[#trash] = nil
		used += unparentTrash(self, entry)
	end
end

-- Gives parts back to the pool, or destroys them, until the deadline.
local function releaseStep(self: ChunkRenderer, deadline: number)
	local pool = self.pool
	local releases = self.releases
	local head = self.releaseHead
	local worked = false
	while head <= #releases do
		if worked and os.clock() > deadline then
			break
		end
		local entry = releases[head]
		local parts = entry.parts
		if entry.mode == 0 then
			local remaining = #parts - entry.index + 1
			local room = pool:room()
			if entry.folder == nil or self.removalsIn[entry.folder :: Folder] then
				-- (A folder still holding removed parts that wait for the swap delay is not
				-- destroyed: its own parts go one by one.)
				entry.mode = LIST
			elseif room >= remaining then
				entry.mode = POOL
			elseif room == 0 then
				entry.mode = DESTROY
			else
				entry.mode = PARTIAL
				entry.keep = room
			end
		end
		local mode = entry.mode
		if mode == DESTROY then
			-- Pool full: one call takes the folder and every part left in it.
			(entry.folder :: Folder):Destroy()
			pool.destroyed += #parts - entry.index + 1
			entry.index = #parts + 1
			worked = true
		else
			local i = entry.index
			while i <= #parts do
				if worked and os.clock() > deadline then
					break
				end
				local part = parts[i]
				if mode == PARTIAL then
					if entry.keep <= 0 then
						break
					end
					-- Out of the folder first: the folder is destroyed below.
					part.Parent = nil
					entry.keep -= 1
				end
				pool:release(part)
				i += 1
				worked = true
			end
			entry.index = i
			if mode == PARTIAL and entry.keep <= 0 and i <= #parts then
				(entry.folder :: Folder):Destroy()
				pool.destroyed += #parts - i + 1
				entry.index = #parts + 1
			elseif mode == PARTIAL and i > #parts then
				(entry.folder :: Folder):Destroy()
			end
		end
		if entry.index > #parts then
			head += 1
		else
			break
		end
	end
	if head > #releases then
		table.clear(releases)
		head = 1
	end
	self.releaseHead = head
	pool:trim(deadline)
end

-- Refreshes the shadow style of live parts until the deadline.
local function walkStep(self: ChunkRenderer, deadline: number)
	local walk = self.walk
	local pool = self.pool
	local n = 0
	while self.walkIndex <= #walk do
		local entry = walk[self.walkIndex]
		local state = self.states[entry.node]
		local record = state and state.records[entry.section]
		if record then
			local parts = record.parts
			local i = self.walkPart
			while i <= #parts do
				local part = parts[i]
				if not pool:isCurrent(part) then
					pool:refresh(part)
				end
				i += 1
				n += 1
				if n % 64 == 0 and os.clock() > deadline then
					self.walkPart = i
					return
				end
			end
		end
		self.walkIndex += 1
		self.walkPart = 1
	end
	table.clear(walk)
	self.walkIndex = 1
end

-- Once per frame: swaps, builds within the budgets, retirements and releases.
function ChunkRenderer.step(self: ChunkRenderer, dt: number?)
	self.frame += 1
	self.stepping = true
	local now = os.clock()
	local frameMs = if dt then dt * 1000 else (now - self.lastStep) * 1000
	self.lastStep = now
	self.pool:beginFrame()
	-- One swap allowance a frame: what the streamer's swaps used, then the overlay.
	self.overlay:step(Render.SwapPartsPerFrame, self.swapUsed)
	self.swapUsed = 0
	if now >= self.nextSparseSweep then
		self.nextSparseSweep = now + SPARSE_SWEEP
		sweepSparse(self)
	end

	-- Groups that completed outside a step, and those that waited too long.
	if #self.ready > 0 then
		local ready = self.ready
		self.ready = {}
		commitAll(self, ready)
	end
	commitAll(self, self.schedule:expire(now, GROUP_TIMEOUT))

	local schedule = self.schedule
	local auto = if self.autoBudget ~= nil then self.autoBudget else Render.AutoBudget
	local base = self.baseBudget or Render.BuildBudgetMs
	local budget = self.budget:update(frameMs, schedule:count() > 0, self.frozen, base, auto)

	self.windowBuilt = 0
	runLane(self, EDIT, os.clock() + Render.EditBudgetMs / 1000)
	self.windowBuilt = 0
	local deadline = os.clock() + budget / 1000
	for lane = NEAR, BACKGROUND do
		if not runLane(self, lane, deadline) then
			break
		end
	end
	if #self.walk > 0 and os.clock() < deadline then
		walkStep(self, deadline)
	end

	-- After the builds, so with SwapFrames 0 a swap really happens within one frame.
	unparentStep(self)
	releaseStep(self, os.clock() + Render.ReleaseBudgetMs / 1000)
	self.stepping = false
end

-- Builds not live yet (queued, waiting or staged).
function ChunkRenderer.pending(self: ChunkRenderer): number
	return self.schedule:count()
end

-- Anything left to build, swap, unparent or release?
function ChunkRenderer.busy(self: ChunkRenderer): boolean
	return self.schedule:count() > 0
		or #self.ready > 0
		or self.retiringHead <= #self.retiring
		or #self.trash > 0
		or self.releaseHead <= #self.releases
end

function ChunkRenderer.stats(self: ChunkRenderer): Stats
	local schedule = self.schedule
	local releasing = 0
	for i = self.releaseHead, #self.releases do
		local entry = self.releases[i]
		releasing += #entry.parts - entry.index + 1
	end
	local trash = 0
	for _, entry in self.trash do
		if not entry.done then
			trash += 1
		end
	end
	local pool = self.pool
	return {
		edit = schedule:laneCount(EDIT),
		near = schedule:laneCount(NEAR),
		normal = schedule:laneCount(NORMAL),
		background = schedule:laneCount(BACKGROUND),
		parked = schedule.parkedCount,
		staged = schedule.stagedCount,
		retiring = #self.retiring - self.retiringHead + 1,
		trash = trash,
		trashParts = self:trashParts(),
		releasing = releasing,
		budgetMs = self.budget.budget,
		usualMs = self.budget.usual,
		recentMs = self.budget.recent,
		pooled = pool.freeCount,
		cloned = pool.cloned,
		reused = pool.reused,
		destroyed = pool.destroyed,
	}
end

return ChunkRenderer
