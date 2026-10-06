--!strict
--[[
	Far meshes: merges stable regions of far LOD chunks into a few MeshParts built with EditableMesh.

	Parts stay the source of truth. Every far node is built and shown as parts exactly as without
	meshes (the streamer's protocol is unchanged); MeshRegions decides when a region of nodes has been
	stable long enough to merge. The merge runs on a builder thread:

	  quads of every member (QuadMesher, made by the workers)
	    -> MeshGeometry arrays (centred, split at Render.FarMeshes.MaxTriangles)
	    -> one scratch EditableMesh, reused for the whole session (BatchAdd vertices and triangles,
	       vertex colours through the automatically created colour ids)
	    -> AssetService:CreateDataModelContentAsync (bake: static content outside the editable
	       memory budget), scratch:Clear()
	    -> AssetService:CreateMeshPartAsync -> MeshPart placed at the mesh's centre.

	When it is done and the members are unchanged, the MeshParts are parented and, Render.SwapFrames
	frames later (at least one), the members' part folders are unparented (kept, not released). Any
	change to a member of the mesh (removed, or rebuilt) demotes the region: the members' parts go
	back into the workspace and the mesh is destroyed Render.SwapFrames frames after the last of
	them, so the two never leave a gap. Hiding and showing members both count their parts against
	Render.SwapPartsPerFrame, shared with the frame's level of detail swaps (`step`'s allowance and
	what the swaps used; ChunkRenderer counts the parts): a node that would go over it waits for the
	next frame, except the first one the overlay moves in a frame (so meshes never wait forever
	behind the swaps). A failed build just leaves the parts. So the screen never waits for a mesh.

	When builds run: one at a time, at most one every BuildInterval, never right after a hitch,
	never while the camera moved faster than MaxBuildSpeed blocks/s on average over the last
	SpeedWindow seconds (regions keep changing while it moves, and every MeshPart costs a 20-30 ms
	frame), never while the streamer is busy (`setStreamerBusy`), and never while paused (`pause`,
	teleports; the builder also stops a running build between MeshParts). Parts keep drawing
	meanwhile. `setUserEnabled(false)` (settings) demotes everything but keeps the quads, so
	switching back on is instant; it cannot switch on meshes that were off from the start.

	Why one scratch mesh: the client budget charges every growable EditableMesh a flat 10 MiB of
	80 MiB on PC (the "8 EditableMesh limit"), and memory of destroyed meshes reportedly comes back
	only after many seconds. Baked content does not count against that budget.

	Startup probe (before anything is merged): creates the scratch mesh, builds an off-centre block
	and a flat sheet to check placement, and times a full-size mesh against the usual frame time
	(up to three tries, a few seconds after joining); meshes stay off when anything fails or a build
	makes frames more than MaxBlockingMs longer than usual. If meshes are off from the start, far
	parts keep their normal look. Off on phones by default. The block is timed the same way
	(`tinyFrameMs`: what a region's small looks cost), then built again in a look (UVs, Material
	and MaterialVariant written, as Far Materials does): when that fails, meshes stay on but plain
	(`dropLooks`: merged levels stay plain whatever the setting).

	Looks (`setLooks`, from Rendering/TextureLooks through ChunkRenderer). A MeshPart has one
	Material and one MaterialVariant. Far Materials off (as before): the parts of merged levels take
	the plain look (`plainLevel`: SmoothPlastic, opaque, no images) and every mesh is plain too, its
	vertices in the plain colours (`plainOf`: what each face averages to on screen, so near and far
	match). Far Materials on: merged levels are not plain, their parts take the far look, and
	MeshGeometry splits each region's quads by look (`lookOf(appearance, face)`: a whole number,
	MeshGeometry.PLAIN = 0 for the plain look) with its LookMinShare / MaxLooks / LookRemainder
	rule; a mesh of look L takes `lookInfo(L)`'s Material, MaterialVariant, Transparency and
	Reflectance, box-mapped UVs (UvStuds per tile) when it is textured, white part colour (vertex
	colours tint it), and casts no shadow when see-through. Any change bumps the look generation:
	the running build stops and is dropped, every mesh is demoted (parts back first, as always),
	and regions are built again once every member's parts carry the current look (`isCurrent`, set
	by the renderer), so a mesh is never built from parts about to be restyled. When the overlay
	changes `plainLevel`'s answer on its own (`dropLooks`), it calls `onLooks` (set by the
	renderer) to restyle what was drawn in the old look.
]]

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Blocks = require(Shared.Blocks)
local ChunkLayout = require(Shared.World.ChunkLayout)
local LodTree = require(Shared.World.LodTree)
local MeshGeometry = require(Shared.Meshing.MeshGeometry)
local QuadMesher = require(Shared.Meshing.QuadMesher)

local MeshRegions = require(script.Parent.MeshRegions)
local ViewSettings = require(script.Parent.ViewSettings)
local FrameBudget = require(script.Parent.FrameBudget)

local Settings = Config.Render.FarMeshes
local BLOCK = Config.BlockSize
local SIZE = Config.ChunkSize
-- Elements per batch call (one third-party report saw failures above ~38k).
local BATCH = 16000
-- Seconds of array preparation per frame on the builder thread.
local SLICE = 0.003
-- Frames between showing a new mesh and hiding the parts under it, and between showing parts
-- again and destroying the mesh (something new may need a frame before it is drawn; the overlap
-- is invisible, both look the same): Render.SwapFrames, at least one.
local function swapFrames(): number
	return math.max(1, Config.Render.SwapFrames)
end
-- Seconds after startup before the probe runs.
local PROBE_DELAY = 5
local FIDELITY = {
	RenderFidelity = Enum.RenderFidelity.Precise,
	CollisionFidelity = Enum.CollisionFidelity.Box,
}

type Node = any

type RegionParts = {
	parts: { MeshPart },
	triangles: number,
	-- Previous mesh, destroyed once the new one hid its members.
	retiring: { MeshPart },
	retiringTriangles: number,
	-- Members whose part folders are unparented.
	hidden: { [Node]: boolean },
	-- Members to hide (from hideFrame on, from hideIndex on, within the allowance).
	pendingHide: { Node }?,
	hideFrame: number,
	hideIndex: number,
}

-- A demoted mesh: destroyed SwapFrames frames after its members are all parts again.
type Dying = {
	parts: { MeshPart },
	triangles: number,
	waiting: number,
	due: number?,
}

type Done = {
	job: MeshRegions.Job,
	parts: { MeshPart }?,
	triangles: number,
	err: string?,
}

type QuadsEntry = { buffer: buffer, count: number }

-- A look's MeshPart properties (Rendering/TextureLooks.lookInfo; `variant` "" for none), and the
-- colour its texture averages to (r, g, b 0..1; nil: unknown) for the "largest" remainder's tint.
export type LookInfo = {
	material: Enum.Material,
	variant: string,
	transparency: number,
	reflectance: number,
	average: { number }?,
}
export type LookOf = MeshGeometry.LookOf
export type PlainOf = MeshGeometry.PlainOf
export type LookInfoOf = (look: number) -> LookInfo?

-- What a build uses, fixed when it starts (MeshRegions.Job.payload).
type Payload = {
	quads: { QuadsEntry },
	lookGen: number,
	options: MeshGeometry.Options?,
	lookInfo: LookInfoOf?,
}

export type Stats = {
	status: string,
	-- Why no build starts now ("" when one may): "off", "paused", "moving", "busy".
	gate: string,
	regions: number,
	meshedRegions: number,
	nodes: number,
	meshedNodes: number,
	meshParts: number,
	builds: number,
	failures: number,
	lastBuildMs: number,
	slowestFrameMs: number,
	-- Triangles in shown meshes / baked this session.
	triangles: number,
	baked: number,
	-- Far Materials on, MeshParts shown in a look other than plain, and how much longer than usual
	-- the probe's one-block mesh made frames (ms, like slowestFrameMs).
	looks: boolean,
	lookParts: number,
	tinyFrameMs: number,
}

export type MeshOverlay = {
	root: Folder,
	-- Folder that node models are parented to when shown (the renderer's root).
	partsRoot: Instance,
	-- Configured on (merged levels use the plain part look even if the probe later fails).
	configured: boolean,
	-- Building meshes right now.
	active: boolean,
	status: string,
	regions: MeshRegions.MeshRegions,
	quads: { [Node]: QuadsEntry },
	instances: { [MeshRegions.Region]: RegionParts },
	pending: MeshRegions.Job?,
	done: { Done },
	frame: number,
	lastBuild: number,
	lastFrameTime: number,
	averageFrameTime: number,
	failuresInRow: number,
	pausedUntil: number,
	-- Triangles of the meshes in the world, and baked in total.
	liveTriangles: number,
	baked: number,
	stats: Stats,
	-- Switched off in the settings (quads kept), paused (teleports), streamer busy, stop the build
	-- running now (checked between MeshParts).
	userOff: boolean,
	paused: boolean,
	streamerBusy: boolean,
	abort: boolean,
	-- The camera's average speed (studs/s) and shadows of new meshes.
	motion: FrameBudget.Motion,
	farShadows: boolean,
	-- Members to put back into the workspace (FIFO from unhideHead), and the dying mesh each one
	-- belongs to (nil: cancelled).
	unhide: { Node },
	unhideHead: number,
	unhiding: { [Node]: Dying },
	dying: { Dying },
	-- Parts in a node's model (set by ChunkRenderer; 0 without it).
	countParts: (node: Node) -> number,
	-- Far Materials (see the header): on now, asked for (the setting), possible here (false once
	-- the probe could not build a mesh in a look); the look callbacks, the options builds use and
	-- the look generation (bumped by every setLooks).
	looks: boolean,
	lookWanted: boolean,
	lookable: boolean,
	lookOf: LookOf?,
	lookInfo: LookInfoOf?,
	plainOf: PlainOf?,
	lookOptions: MeshGeometry.Options?,
	lookGen: number,
	-- Do the node's parts carry the current look (set by ChunkRenderer; true without it)? Regions
	-- are only built from members that do.
	isCurrent: (node: Node) -> boolean,
	-- `plainLevel`'s answer changed without a setLooks call (`dropLooks`): the renderer restyles
	-- what it drew in the old look (set by ChunkRenderer; nothing without it).
	onLooks: () -> (),

	mergedLevel: (self: MeshOverlay, level: number) -> boolean,
	plainLevel: (self: MeshOverlay, level: number) -> boolean,
	setLooks: (
		self: MeshOverlay,
		enabled: boolean,
		lookOf: LookOf?,
		lookInfo: LookInfoOf?,
		plainOf: PlainOf?
	) -> boolean,
	dropLooks: (self: MeshOverlay, reason: string) -> (),
	wantsQuads: (self: MeshOverlay, level: number) -> boolean,
	setQuads: (self: MeshOverlay, node: Node, quads: buffer, count: number) -> (),
	onShow: (self: MeshOverlay, node: Node) -> (),
	onClear: (self: MeshOverlay, node: Node) -> (),
	onChanged: (self: MeshOverlay, node: Node) -> (),
	step: (self: MeshOverlay, allowance: number?, used: number?) -> number,
	demoteAll: (self: MeshOverlay) -> (),
	getStats: (self: MeshOverlay) -> Stats,
	setUserEnabled: (self: MeshOverlay, on: boolean) -> boolean,
	pause: (self: MeshOverlay) -> (),
	resume: (self: MeshOverlay) -> (),
	setStreamerBusy: (self: MeshOverlay, busy: boolean) -> (),
	restyle: (self: MeshOverlay, farShadows: boolean) -> (),
	gate: (self: MeshOverlay, now: number) -> string,
}

local MeshOverlay = {}
MeshOverlay.__index = MeshOverlay

--[[ Building (builder thread only: these calls yield) ]]

local colorCache: { [number]: Color3 } = {}
local function colorOf(appearance: number): Color3
	local cached: Color3? = colorCache[appearance]
	if cached then
		return cached
	end
	local c = Blocks.appearances[appearance].color
	local color = Color3.fromRGB(c[1], c[2], c[3])
	colorCache[appearance] = color
	return color
end

-- Yields to the next frame when this frame's slice of array work is used up.
local sliceStart = 0
local function slice()
	if os.clock() - sliceStart > SLICE then
		task.wait()
		sliceStart = os.clock()
	end
end

local function batchAdd(em: EditableMesh, attr: Enum.MeshAttribute, data: { any }): { number }
	local ids: { number } = table.create(#data)
	for first = 1, #data, BATCH do
		local last = math.min(first + BATCH - 1, #data)
		local chunk = if first == 1 and last == #data then data else table.move(data, first, last, 1, {})
		local got = em:BatchAdd(attr, chunk)
		if #got ~= #chunk then
			error(`BatchAdd returned {#got} of {#chunk} elements`)
		end
		table.move(got, 1, #got, first, ids)
	end
	return ids
end

-- Does a mesh of this look show a texture (so it needs UVs)?
local function textured(info: LookInfo?): boolean
	return info ~= nil and (info.material ~= Enum.Material.SmoothPlastic or info.variant ~= "")
end

--[[
	Builds one MeshPart from MeshGeometry arrays using the scratch mesh, in look `info` (nil: the
	plain look). Returns the part or an error.
]]
local function buildMesh(
	em: EditableMesh,
	mesh: MeshGeometry.Mesh,
	castShadow: boolean,
	info: LookInfo?
): (MeshPart?, string?)
	em:Clear()
	local positions = mesh.positions
	local vertexCount = #positions // 3
	local vectors: { Vector3 } = table.create(vertexCount)
	for i = 1, vertexCount do
		local j = i * 3 - 2
		vectors[i] = Vector3.new(positions[j], positions[j + 1], positions[j + 2])
		if i % 4096 == 0 then
			slice()
		end
	end
	local vertexIds = batchAdd(em, Enum.MeshAttribute.Vertex, vectors)

	local faces: { { number } } = table.create(mesh.quads * 2)
	for q = 0, mesh.quads - 1 do
		local a, b, c, d = vertexIds[q * 4 + 1], vertexIds[q * 4 + 2], vertexIds[q * 4 + 3], vertexIds[q * 4 + 4]
		faces[q * 2 + 1] = { a, b, c }
		faces[q * 2 + 2] = { a, c, d }
		if q % 2048 == 0 then
			slice()
		end
	end
	batchAdd(em, Enum.MeshAttribute.Face, faces)

	-- Every vertex got its own colour id (white) and UV id ((0, 0)) when its first face was added:
	-- colour them (the look's colours, else the block colours), and give textured looks their UVs.
	local quadColors: { Color3 } = table.create(mesh.quads)
	local looked = mesh.colors
	for q = 1, mesh.quads do
		if looked then
			quadColors[q] = Color3.new(looked[q * 3 - 2], looked[q * 3 - 1], looked[q * 3])
		else
			quadColors[q] = colorOf(mesh.appearances[q])
		end
	end
	local uvs = if textured(info) then mesh.uvs else nil
	local function setAttribute(attribute: Enum.MeshAttribute, valueOf: (vertex: number) -> any)
		local attributeIds: { number } = table.create(vertexCount)
		local values: { any } = table.create(vertexCount)
		for first = 1, vertexCount, BATCH do
			local last = math.min(first + BATCH - 1, vertexCount)
			local nested = em:BatchGetVertexAttributes(attribute, table.move(vertexIds, first, last, 1, {}))
			if #nested ~= last - first + 1 then
				error("BatchGetVertexAttributes returned too few vertices")
			end
			for k, ids in nested do
				local i = first + k - 1
				local id = (ids :: { number })[1]
				if id == nil then
					error(`vertex without a {attribute.Name} id`)
				end
				attributeIds[i] = id
				values[i] = valueOf(i)
			end
		end
		for first = 1, vertexCount, BATCH do
			local last = math.min(first + BATCH - 1, vertexCount)
			em:BatchSetValues(table.move(attributeIds, first, last, 1, {}), table.move(values, first, last, 1, {}))
		end
	end
	setAttribute(Enum.MeshAttribute.Color, function(i: number): any
		return quadColors[(i - 1) // 4 + 1]
	end)
	if uvs then
		setAttribute(Enum.MeshAttribute.UV, function(i: number): any
			return Vector2.new(uvs[i * 2 - 1], uvs[i * 2])
		end)
	end

	local results = { AssetService:CreateDataModelContentAsync(Content.fromObject(em), FIDELITY) }
	em:Clear()
	local result, content = results[1], results[2]
	if result ~= Enum.CreateContentResult.Success then
		return nil, `bake {tostring(result)}`
	end
	local part = AssetService:CreateMeshPartAsync(content :: Content, FIDELITY)
	part.Name = "FarMesh"
	part.Anchored = true
	part.Locked = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	local transparency = if info then info.transparency else 0
	-- (See-through looks never cast shadows, like PartPool's parts.)
	part.CastShadow = castShadow and transparency == 0
	part.EnableFluidForces = false
	part.Material = if info then info.material else Enum.Material.SmoothPlastic
	if info then
		part.MaterialVariant = info.variant
	end
	part.Transparency = transparency
	part.Reflectance = if info then info.reflectance else 0
	-- White: the vertex colours carry the colour (they multiply the material's texture).
	part.Color = Color3.new(1, 1, 1)
	pcall(function()
		part.AudioCanCollide = false
	end)
	-- The part is centred on its mesh; check it has the expected size before trusting placement.
	local size = mesh.size
	local got = part.Size
	local tolerance = 0.02 + 1e-4 * math.max(size[1], size[2], size[3])
	if
		math.abs(got.X - size[1]) > tolerance
		or math.abs(got.Y - size[2]) > tolerance
		or math.abs(got.Z - size[3]) > tolerance
	then
		part:Destroy()
		return nil, `mesh part size {got} instead of {size[1]}, {size[2]}, {size[3]}`
	end
	part.CFrame = CFrame.new(mesh.center[1], mesh.center[2], mesh.center[3])
	return part, nil
end

local function destroyAll(parts: { MeshPart })
	for _, part in parts do
		part:Destroy()
	end
end

-- Builds every MeshPart of a region. Returns the parts and their triangles, or nil and an error.
local function buildRegion(self: MeshOverlay, em: EditableMesh, job: MeshRegions.Job): ({ MeshPart }?, number, string?)
	-- The members' quads and the looks as they were when the build started (see MeshOverlay.step).
	local payload = job.payload :: Payload
	local builder = MeshGeometry.builder(BLOCK, Settings.Overlap, Settings.MaxTriangles, payload.options)
	local snapshot = payload.quads
	for i, node in job.members do
		local entry = snapshot[i]
		if entry == nil then
			return nil, 0, "member without quads"
		end
		local step, stepY = ChunkLayout.steps(node.level)
		local scale = step * BLOCK
		builder:add(entry.buffer, entry.count, node.nx * SIZE * scale, node.nz * SIZE * scale, scale, stepY * BLOCK)
		slice()
	end
	local parts: { MeshPart } = {}
	local triangles = 0
	for _, mesh in builder:finish() do
		-- Paused (a teleport): stop between MeshParts, each costs a long frame.
		if self.abort then
			destroyAll(parts)
			return nil, 0, "aborted"
		end
		local lookInfo = payload.lookInfo
		local info = if mesh.look ~= MeshGeometry.PLAIN and lookInfo then lookInfo(mesh.look) else nil
		local ok, part, err = pcall(buildMesh, em, mesh, self.farShadows, info)
		if not ok or part == nil then
			destroyAll(parts)
			return nil, 0, if ok then err else tostring(part)
		end
		table.insert(parts, part :: MeshPart)
		triangles += mesh.quads * 2
		self.baked += mesh.quads * 2
	end
	return parts, triangles, nil
end

-- A mesh made of `quads` (MeshGeometry builder input) for the probe, plain or with `options`
-- in look `info`.
local function probeMesh(
	em: EditableMesh,
	fill: (builder: MeshGeometry.Builder) -> (),
	options: MeshGeometry.Options?,
	info: LookInfo?
): (MeshPart?, string?, MeshGeometry.Mesh?)
	local builder = MeshGeometry.builder(BLOCK, 0, 20000, options)
	fill(builder)
	local mesh = builder:finish()[1]
	local ok, part, err = pcall(buildMesh, em, mesh, false, info)
	if not ok then
		return nil, tostring(part), mesh
	end
	return part, err, mesh
end

-- The usual frame time just before a timed probe mesh (s): the mean of 30 frames.
local function usualFrame(): number
	local usual = 0
	for _ = 1, 30 do
		usual += task.wait()
	end
	return usual / 30
end

--[[
	probeMesh, watching the frames meanwhile: also how much longer than `usual` the slowest frame
	got (s; a build's cost is the long frame it causes, not its time across the yields) and the
	time it took (s).
]]
local function timedMesh(
	em: EditableMesh,
	usual: number,
	fill: (builder: MeshGeometry.Builder) -> ()
): (MeshPart?, string?, number, number)
	local slowest = 0
	local connection = RunService.Heartbeat:Connect(function(dt)
		slowest = math.max(slowest, dt)
	end)
	local started = os.clock()
	local part, err = probeMesh(em, fill)
	local elapsed = os.clock() - started
	task.wait()
	connection:Disconnect()
	return part, err, math.max(slowest - usual, 0), elapsed
end

-- The look the probe builds a mesh in: a material, so UVs, Material and MaterialVariant are written.
local PROBE_LOOK: LookInfo = {
	material = Enum.Material.Slate,
	variant = "",
	transparency = 0,
	reflectance = 0,
}
local PROBE_OPTIONS: MeshGeometry.Options = {
	lookOf = function(_appearance: number, _face: number): (number, number, number, number)
		return 1, 1, 1, 1
	end,
	uvStuds = Settings.UvStuds,
}

-- Quads of a flat test terrain: `cells` x `cells` blocks, every block a little step (many quads).
local function testQuads(cells: number, flat: boolean): (buffer, number)
	local data = ChunkLayout.create(8)
	local stone = Blocks.id.Stone
	for z = 0, math.min(cells, SIZE) - 1 do
		for x = 0, math.min(cells, SIZE) - 1 do
			local top = if flat then 1 else 1 + (x + z) % 3
			for y = 0, top do
				ChunkLayout.set(data, x, y, z, stone)
			end
		end
	end
	return QuadMesher.mesh(data, 8, 0, 8, true)
end

-- Runs the startup probe. Returns nil when meshes can be used, else the reason.
local function probe(self: MeshOverlay, em: EditableMesh): string?
	-- 1. Placement: an off-centre single block far from the origin, timed like the full-size mesh
	-- below (a region's small looks make such tiny meshes: `tinyFrameMs`).
	local quads, count = testQuads(1, true)
	local function block(builder: MeshGeometry.Builder)
		builder:add(quads, count, 3000, -1500, BLOCK, BLOCK)
	end
	local placed, placedErr, tinyExcess = timedMesh(em, usualFrame(), block)
	self.stats.tinyFrameMs = tinyExcess * 1000
	if not placed then
		return `probe mesh failed: {placedErr}`
	end
	placed:Destroy()
	-- The same in a look, as Far Materials builds them: without it meshes stay on, but plain.
	local looked, lookedErr = probeMesh(em, block, PROBE_OPTIONS, PROBE_LOOK)
	if looked then
		looked:Destroy()
	else
		self:dropLooks(`a mesh in a material failed: {lookedErr}`)
	end

	-- 2. A flat sheet (its box gets an anchor quad).
	local sheet = buffer.create(16)
	buffer.writeu16(sheet, 0, 2) -- +Y
	buffer.writeu16(sheet, 8, 16)
	buffer.writeu16(sheet, 10, 16)
	buffer.writeu16(sheet, 12, Blocks.get(Blocks.id.Stone).appearance)
	local flat, flatErr = probeMesh(em, function(builder)
		builder:add(sheet, 1, 0, 0, 32, BLOCK)
	end)
	if not flat then
		return `flat mesh failed: {flatErr}`
	end
	flat:Destroy()

	-- 3. Timing: a mesh of about MaxTriangles triangles. Its cost is how much longer frames get
	-- while it is built than the usual frame time just before (other startup work may cause
	-- hitches too, so it gets up to three tries).
	quads, count = testQuads(SIZE, false)
	local perNode = count * 2
	local nodes = math.max(1, Settings.MaxTriangles // math.max(perNode, 1))
	local excess = math.huge
	for attempt = 1, 3 do
		local timed, timedErr, slower, elapsed = timedMesh(em, usualFrame(), function(builder)
			for i = 0, nodes - 1 do
				builder:add(quads, count, (i % 8) * SIZE * BLOCK, (i // 8) * SIZE * BLOCK, BLOCK, BLOCK)
			end
		end)
		if not timed then
			return `timing mesh failed: {timedErr}`
		end
		timed:Destroy()
		excess = math.min(excess, slower)
		self.stats.lastBuildMs = elapsed * 1000
		self.stats.slowestFrameMs = excess * 1000
		if excess * 1000 <= Settings.MaxBlockingMs then
			return nil
		end
		if attempt < 3 then
			task.wait(15)
		end
	end
	return string.format("too slow here: a %d-triangle mesh made frames %.0f ms longer", nodes * perNode, excess * 1000)
end

local function builderLoop(self: MeshOverlay)
	-- The scratch mesh lives for the whole session (see the header).
	local ok, em = pcall(function()
		return AssetService:CreateEditableMesh()
	end)
	if not ok or em == nil then
		-- Known before any part is built: far parts keep their normal look.
		self.status = if ok then "off: no editable memory budget" else "off: mesh APIs unavailable"
		warn(`[IceVoxel] far meshes {self.status} ({if ok then "nil" else tostring(em)})`)
		self.active = false
		self.configured = false
		return
	end
	local scratch = em :: EditableMesh
	self.status = "probing"
	-- Let joining settle first (the probe compares against the usual frame time).
	task.wait(PROBE_DELAY)
	local reason = probe(self, scratch)
	if reason then
		self.status = `off: {reason}`
		warn(`[IceVoxel] far meshes {self.status}`)
		self.active = false
		self.configured = false
		return
	end
	self.status = "on"

	local slowest = 0
	local connection: RBXScriptConnection? = nil
	while true do
		local job = self.pending
		if job == nil then
			task.wait()
			continue
		end
		slowest = 0
		-- (A pause, the settings switch or new looks may come before the build starts.)
		self.abort = self.paused or self.userOff or (job.payload :: Payload).lookGen ~= self.lookGen
		connection = RunService.Heartbeat:Connect(function(dt)
			slowest = math.max(slowest, dt)
		end)
		sliceStart = os.clock()
		local started = os.clock()
		local okRun, parts, triangles, err = pcall(buildRegion, self, scratch, job)
		pcall(function()
			scratch:Clear()
		end);
		(connection :: RBXScriptConnection):Disconnect()
		self.stats.lastBuildMs = (os.clock() - started) * 1000
		local excess = math.max(slowest - self.averageFrameTime, 0)
		self.stats.slowestFrameMs = math.max(self.stats.slowestFrameMs * 0.9, excess * 1000)
		self.pending = nil
		if okRun and parts then
			table.insert(self.done, { job = job, parts = parts, triangles = triangles })
		else
			table.insert(self.done, { job = job, triangles = 0, err = if okRun then err else tostring(parts) })
		end
	end
end

--[[ Applying (main thread, never yields) ]]

local function partsOf(self: MeshOverlay, region: MeshRegions.Region): RegionParts
	local entry = self.instances[region]
	if entry == nil then
		entry = {
			parts = {},
			triangles = 0,
			retiring = {},
			retiringTriangles = 0,
			hidden = {},
			pendingHide = nil,
			hideFrame = 0,
			hideIndex = 1,
		}
		self.instances[region] = entry
	end
	return entry :: RegionParts
end

-- A node waiting to be put back for a dying mesh no longer needs it (hidden again, or removed).
local function cancelUnhide(self: MeshOverlay, node: Node)
	local dying = self.unhiding[node]
	if dying then
		self.unhiding[node] = nil
		dying.waiting -= 1
		if dying.waiting <= 0 then
			dying.due = self.frame + swapFrames()
		end
	end
end

--[[
	Mesh going: every member is drawn by its parts again (put back within the allowance, see
	step), then the mesh is destroyed SwapFrames frames after the last one.
]]
local function demote(self: MeshOverlay, region: MeshRegions.Region)
	local entry = self.instances[region]
	if entry then
		local parts = table.clone(entry.parts)
		table.move(entry.retiring, 1, #entry.retiring, #parts + 1, parts)
		local dying: Dying = {
			parts = parts,
			triangles = entry.triangles + entry.retiringTriangles,
			waiting = 0,
			due = nil,
		}
		for node in entry.hidden do
			if not node.removed and node.model then
				cancelUnhide(self, node)
				self.unhiding[node] = dying
				dying.waiting += 1
				table.insert(self.unhide, node)
			end
		end
		if dying.waiting == 0 then
			dying.due = self.frame + swapFrames()
		end
		table.insert(self.dying, dying)
		self.instances[region] = nil
	end
	self.regions:demoted(region, os.clock())
end

local function apply(self: MeshOverlay, finished: Done)
	local job = finished.job
	local now = os.clock()
	local payload = job.payload :: Payload?
	local stale = payload ~= nil and payload.lookGen ~= self.lookGen
	if finished.err == "aborted" or ((self.userOff or stale) and finished.parts) then
		-- Stopped, or finished just after meshes were switched off in the settings or the looks
		-- changed (built in the old ones).
		if finished.parts then
			destroyAll(finished.parts :: { MeshPart })
		end
		self.regions:abort(job)
		return
	end
	if finished.parts == nil then
		self.regions:finish(job, false, now)
		self.stats.failures += 1
		self.failuresInRow += 1
		local err = finished.err or "?"
		warn(`[IceVoxel] far mesh build failed: {err}`)
		if string.find(err, "StorageLimitExceeded") or string.find(err, "PermissionDenied") then
			self.status = `off: {err}`
			self.active = false
		elseif self.failuresInRow >= 3 then
			self.status = "paused after failures"
			self.pausedUntil = now + 60
			self.failuresInRow = 0
		end
		return
	end
	local parts = finished.parts :: { MeshPart }
	if not self.regions:finish(job, true, now) then
		-- Members changed while it was built.
		destroyAll(parts)
		return
	end
	self.failuresInRow = 0
	self.stats.builds += 1
	local region = job.region
	local entry = partsOf(self, region)
	destroyAll(entry.retiring)
	self.liveTriangles -= entry.retiringTriangles
	entry.retiring, entry.retiringTriangles = entry.parts, entry.triangles
	entry.parts, entry.triangles = parts, finished.triangles
	self.liveTriangles += finished.triangles
	for _, part in parts do
		local cast = self.farShadows and part.Transparency == 0
		if part.CastShadow ~= cast then
			part.CastShadow = cast
		end
		part.Parent = self.root
	end
	entry.pendingHide = job.members
	entry.hideFrame = self.frame + swapFrames()
	entry.hideIndex = 1
end

--[[
	Puts back members of demoted meshes while they fit in the allowance (`used`: parts moved this
	frame so far; `moved`: the overlay moved a node this frame, else the next one goes anyway).
	Returns both again.
]]
local function unhideStep(self: MeshOverlay, allowance: number, used: number, moved: boolean): (number, boolean)
	local list = self.unhide
	local head = self.unhideHead
	while head <= #list do
		local node = list[head]
		local dying = self.unhiding[node]
		local back = dying ~= nil and not node.removed and node.model ~= nil
		local cost = if back then self.countParts(node) else 0
		if moved and used + cost > allowance then
			break
		end
		head += 1
		if dying then
			self.unhiding[node] = nil
			if back then
				node.model.Parent = self.partsRoot
				used += cost
				moved = true
			end
			dying.waiting -= 1
			if dying.waiting <= 0 then
				dying.due = self.frame + swapFrames()
			end
		end
	end
	if head > #list then
		table.clear(list)
		head = 1
	end
	self.unhideHead = head
	return used, moved
end

-- After the swap delay: hide the parts the new meshes draw (within the allowance, as unhideStep),
-- then drop the previous mesh.
local function finishSwaps(self: MeshOverlay, allowance: number, used: number, moved: boolean): (number, boolean)
	for region, entry in self.instances do
		local nodes = entry.pendingHide
		if nodes and self.frame >= entry.hideFrame then
			local meshed = region.meshed
			local i = entry.hideIndex
			while i <= #nodes do
				local node = nodes[i]
				local model = node.model
				local hides = meshed ~= nil and meshed[node] ~= nil and not node.removed and model ~= nil
				local leaves = hides and self.unhiding[node] == nil and model.Parent ~= nil
				local cost = if leaves then self.countParts(node) else 0
				if moved and used + cost > allowance then
					break
				end
				i += 1
				if hides then
					if self.unhiding[node] then
						-- Still out of the workspace for a dying mesh: stays out.
						cancelUnhide(self, node)
					elseif leaves then
						model.Parent = nil
						used += cost
						moved = true
					end
					entry.hidden[node] = true
				end
			end
			entry.hideIndex = i
			if i > #nodes then
				entry.pendingHide = nil
				destroyAll(entry.retiring)
				self.liveTriangles -= entry.retiringTriangles
				entry.retiring, entry.retiringTriangles = {}, 0
			end
		end
	end
	return used, moved
end

-- Destroys demoted meshes whose members have been parts for the swap delay.
local function buryDying(self: MeshOverlay)
	local list = self.dying
	local i = 1
	while i <= #list do
		local dying = list[i]
		local due = dying.due
		if due and self.frame >= due then
			destroyAll(dying.parts)
			self.liveTriangles -= dying.triangles
			list[i] = list[#list]
			list[#list] = nil
		else
			i += 1
		end
	end
end

--[[ Public ]]

function MeshOverlay.new(root: Instance): MeshOverlay
	local folder = Instance.new("Folder")
	folder.Name = "IceVoxelFarMeshes"
	folder.Parent = root

	local configured = Settings.Enabled and (Settings.Mobile or not ViewSettings.isMobile())
	local self = {
		root = folder,
		partsRoot = root,
		configured = configured,
		active = configured,
		status = if configured then "starting" else "off (Config.Render.FarMeshes)",
		regions = MeshRegions.new({
			minLevel = Settings.MinLevel,
			regionNodes = Settings.RegionNodes,
			maxRegionBlocks = Settings.MaxRegionBlocks,
			stableSeconds = Settings.StableSeconds,
			rebuildSeconds = Settings.RebuildSeconds,
			nodeSize = LodTree.nodeSize,
		}),
		quads = {},
		instances = {},
		pending = nil,
		done = {},
		frame = 0,
		lastBuild = 0,
		lastFrameTime = 0,
		averageFrameTime = 1 / 60,
		failuresInRow = 0,
		pausedUntil = 0,
		liveTriangles = 0,
		baked = 0,
		userOff = false,
		paused = false,
		streamerBusy = false,
		abort = false,
		motion = FrameBudget.motion(Settings.SpeedWindow),
		farShadows = Config.Render.FarShadows,
		unhide = {},
		unhideHead = 1,
		unhiding = {},
		dying = {},
		countParts = function(_node: Node): number
			return 0
		end,
		looks = false,
		lookWanted = false,
		lookable = true,
		lookOf = nil,
		lookInfo = nil,
		plainOf = nil,
		lookOptions = nil,
		lookGen = 0,
		isCurrent = function(_node: Node): boolean
			return true
		end,
		onLooks = function() end,
		stats = {
			status = "",
			gate = "",
			regions = 0,
			meshedRegions = 0,
			nodes = 0,
			meshedNodes = 0,
			meshParts = 0,
			builds = 0,
			failures = 0,
			lastBuildMs = 0,
			slowestFrameMs = 0,
			triangles = 0,
			baked = 0,
			looks = false,
			lookParts = 0,
			tinyFrameMs = 0,
		},
	}
	setmetatable(self, MeshOverlay)
	local overlay = (self :: any) :: MeshOverlay
	if configured then
		task.spawn(builderLoop, overlay)
		RunService.Heartbeat:Connect(function(dt)
			overlay.lastFrameTime = dt
			overlay.averageFrameTime += (dt - overlay.averageFrameTime) * 0.05
		end)
	end
	return overlay
end

-- Are nodes of this level merged into meshes (when meshes are configured)?
function MeshOverlay.mergedLevel(self: MeshOverlay, level: number): boolean
	return self.configured and self.regions:keyOf(level, 0, 0) ~= nil
end

--[[
	Do parts of this level take the plain look of the meshes (so swapping is invisible)? Merged
	levels do, unless Far Materials is on: then their parts take the far look, like the meshes.
]]
function MeshOverlay.plainLevel(self: MeshOverlay, level: number): boolean
	return not self.looks and self:mergedLevel(level)
end

--[[
	MeshGeometry options for builds with these looks: Far Materials off, every quad plain in its
	plain colour (`plainOf`, else lookOf's colour: one look, the meshes of before with calibrated
	colours); on, the looks, their share rule (Config.Render.FarMeshes) and UVs. nil without
	`lookOf` (block colours, as before).
]]
local function lookOptions(
	enabled: boolean,
	lookOf: LookOf?,
	lookInfo: LookInfoOf?,
	plainOf: PlainOf?
): MeshGeometry.Options?
	if lookOf == nil then
		return nil
	end
	local PLAIN = MeshGeometry.PLAIN
	if not enabled then
		return {
			lookOf = function(appearance: number, face: number): (number, number, number, number)
				if plainOf then
					local r, g, b = plainOf(appearance, face)
					return PLAIN, r, g, b
				end
				local _, r, g, b = lookOf(appearance, face)
				return PLAIN, r, g, b
			end,
		}
	end
	return {
		lookOf = lookOf,
		plainOf = plainOf,
		minShare = Settings.LookMinShare,
		maxLooks = Settings.MaxLooks,
		remainder = Settings.LookRemainder,
		-- (The remainder may only join a look that hides what is behind it.)
		opaque = function(look: number): boolean
			if look == PLAIN or lookInfo == nil then
				return true
			end
			local info = lookInfo(look)
			return info == nil or info.transparency == 0
		end,
		averageOf = function(look: number): { number }?
			local info = if lookInfo then lookInfo(look) else nil
			return if info then info.average else nil
		end,
		uvStuds = Settings.UvStuds,
	}
end

--[[
	New looks (see the header): Far Materials on or off (`enabled`: the setting), and the callbacks
	(Rendering/TextureLooks): every quad's look and vertex colour (`lookOf(appearance, face)`, face
	= QuadMesher direction), every look's MeshPart properties (`lookInfo`), and the plain look's
	colours (`plainOf(appearance, face)`, for the plain remainder and Far Materials off; nil:
	lookOf's colours). nil `lookOf`: block colours, as before there were looks. Call it at startup
	and whenever the far looks change. Stops a running build, demotes every mesh (rebuilt later
	with the new looks, once the members are current). Returns true when `plainLevel`'s answer
	changed: the renderer must restyle the sections of merged levels. After `dropLooks`, Far
	Materials stays off whatever `enabled` says.
]]
function MeshOverlay.setLooks(
	self: MeshOverlay,
	enabled: boolean,
	lookOf: LookOf?,
	lookInfo: LookInfoOf?,
	plainOf: PlainOf?
): boolean
	local on = enabled and self.lookable
	local changed = on ~= self.looks and self.configured
	self.looks = on
	self.lookWanted = enabled
	self.lookOf = lookOf
	self.lookInfo = lookInfo
	self.plainOf = plainOf
	self.lookOptions = lookOptions(on, lookOf, lookInfo, plainOf)
	self.lookGen += 1
	if self.pending ~= nil then
		self.abort = true
	end
	self:demoteAll()
	return changed
end

--[[
	Far Materials cannot work here (the probe could not build a mesh in a look): meshes stay plain
	and merged levels plain whatever the setting, said once with `reason`. When they were on, the
	looks change (setLooks) and the renderer restyles the merged levels (`onLooks`).
]]
function MeshOverlay.dropLooks(self: MeshOverlay, reason: string)
	if not self.lookable then
		return
	end
	self.lookable = false
	warn(`[IceVoxel] Far Materials off: {reason} (far meshes stay plain)`)
	if self:setLooks(self.lookWanted, self.lookOf, self.lookInfo, self.plainOf) then
		self.onLooks()
	end
end

-- Should the workers make quads for nodes of this level?
function MeshOverlay.wantsQuads(self: MeshOverlay, level: number): boolean
	return self.active and self.regions:keyOf(level, 0, 0) ~= nil
end

function MeshOverlay.setQuads(self: MeshOverlay, node: Node, quads: buffer, count: number)
	self.quads[node] = { buffer = quads, count = count }
end

-- The node's parts were just put into the workspace.
function MeshOverlay.onShow(self: MeshOverlay, node: Node)
	if self.configured then
		self.regions:add(node, os.clock())
	end
end

-- The node is going away (call before its parts are released).
function MeshOverlay.onClear(self: MeshOverlay, node: Node)
	self.quads[node] = nil
	cancelUnhide(self, node)
	-- Only its own region can hide it (node -> region index, not a loop over every region).
	local member = self.regions:regionOfNode(node)
	local region = self.regions:remove(node, os.clock())
	if region then
		demote(self, region)
	end
	if member then
		local entry = self.instances[member]
		if entry then
			entry.hidden[node] = nil
		end
	end
end

-- The node's parts were rebuilt.
function MeshOverlay.onChanged(self: MeshOverlay, node: Node)
	local region = self.regions:changed(node, os.clock())
	if region then
		demote(self, region)
	end
end

-- Back to parts everywhere (e.g. when meshes are switched off).
function MeshOverlay.demoteAll(self: MeshOverlay)
	for _, region in self.regions:meshedRegions() do
		demote(self, region)
	end
end

-- Why no build may start now ("" when one may).
function MeshOverlay.gate(self: MeshOverlay, _now: number): string
	if not self.active or self.userOff then
		return "off"
	elseif self.paused then
		return "paused"
	elseif self.motion:speed() > Settings.MaxBuildSpeed * BLOCK then
		return "moving"
	elseif self.streamerBusy then
		return "busy"
	end
	return ""
end

--[[
	Once per frame: apply finished builds, put back members of demoted meshes and hide members of
	new ones (at most `allowance` parts this frame, counting the `used` ones the frame's swaps
	moved already; at least one node), destroy meshes that are done, start the next build. Returns
	the parts the overlay moved in or out of the workspace.
]]
function MeshOverlay.step(self: MeshOverlay, allowance: number?, used: number?): number
	self.frame += 1
	local now = os.clock()
	local camera = workspace.CurrentCamera
	if camera then
		local p = camera.CFrame.Position
		self.motion:update(p.X, p.Y, p.Z, now)
	end
	while #self.done > 0 do
		apply(self, table.remove(self.done, 1) :: Done)
	end
	local limit = allowance or math.huge
	local before = used or 0
	local total, moved = unhideStep(self, limit, before, false)
	total = finishSwaps(self, limit, total, moved)
	buryDying(self)

	if not self.active and next(self.quads) then
		-- Meshes are off: quads are no longer needed.
		table.clear(self.quads)
	end
	if
		self:gate(now) == ""
		and self.status ~= "probing"
		and self.status ~= "starting"
		and self.pending == nil
		and now >= self.pausedUntil
		and now - self.lastBuild >= Settings.BuildInterval
		and self.lastFrameTime <= math.max(self.averageFrameTime * 1.5, Settings.MaxFrameTime)
		and self.liveTriangles < Settings.MaxLiveTriangles
	then
		if self.status == "paused after failures" then
			self.status = "on"
		end
		-- (Only members whose parts carry the current look: one being restyled would demote the
		-- mesh again when it commits.)
		local region = self.regions:candidate(now, function(node)
			return self.quads[node] ~= nil and self.isCurrent(node)
		end)
		if region then
			self.lastBuild = now
			local job = self.regions:begin(region)
			-- Quads and looks as they are now: a member may be removed before the builder runs.
			local snapshot = table.create(#job.members)
			for i, node in job.members do
				snapshot[i] = self.quads[node]
			end
			local payload: Payload = {
				quads = snapshot,
				lookGen = self.lookGen,
				options = self.lookOptions,
				lookInfo = self.lookInfo,
			}
			job.payload = payload
			self.pending = job
		end
	end
	return total - before
end

--[[
	The settings switch. Off: every region goes back to parts, no builds, quads kept (switching on
	again needs no regeneration). On: returns false when meshes were off from the start of the
	session (configuration, phone, or the probe failed): that applies on rejoin.
]]
function MeshOverlay.setUserEnabled(self: MeshOverlay, on: boolean): boolean
	if not on then
		if not self.userOff then
			self.userOff = true
			self.abort = self.pending ~= nil
			self:demoteAll()
		end
		return true
	end
	-- (Cleared even when meshes cannot come on, so the status gives the real reason.)
	self.userOff = false
	return self.configured
end

-- No builds (a teleport); a build running now stops before its next MeshPart.
function MeshOverlay.pause(self: MeshOverlay)
	self.paused = true
	if self.pending ~= nil then
		self.abort = true
	end
end

function MeshOverlay.resume(self: MeshOverlay)
	self.paused = false
end

-- The streamer has a lot queued or building: no new builds until it settles.
function MeshOverlay.setStreamerBusy(self: MeshOverlay, busy: boolean)
	self.streamerBusy = busy
end

-- Far shadows on or off: the meshes now and the ones built later (see-through looks never cast).
function MeshOverlay.restyle(self: MeshOverlay, farShadows: boolean)
	if farShadows == self.farShadows then
		return
	end
	self.farShadows = farShadows
	local function set(parts: { MeshPart })
		for _, part in parts do
			part.CastShadow = farShadows and part.Transparency == 0
		end
	end
	for _, entry in self.instances do
		set(entry.parts)
		set(entry.retiring)
	end
	for _, dying in self.dying do
		set(dying.parts)
	end
end

function MeshOverlay.getStats(self: MeshOverlay): Stats
	local s = self.regions:stats()
	local stats = self.stats
	stats.status = if self.userOff then "off (settings)" else self.status
	stats.gate = self:gate(os.clock())
	stats.regions = s.regions
	stats.meshedRegions = s.meshed
	stats.nodes = s.nodes
	stats.meshedNodes = s.meshedNodes
	local parts, lookParts = 0, 0
	local function count(list: { MeshPart })
		parts += #list
		for _, part in list do
			if part.Material ~= Enum.Material.SmoothPlastic or part.MaterialVariant ~= "" then
				lookParts += 1
			end
		end
	end
	for _, entry in self.instances do
		count(entry.parts)
	end
	for _, dying in self.dying do
		count(dying.parts)
	end
	stats.meshParts = parts
	stats.lookParts = lookParts
	stats.looks = self.looks
	stats.triangles = self.liveTriangles
	stats.baked = self.baked
	return stats
end

return MeshOverlay
