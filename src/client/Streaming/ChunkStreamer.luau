--!strict
--[[
	Decides what terrain exists on the client and keeps it up to date.

	Every Config.Streaming.UpdateInterval it asks LodTree which chunk nodes should be visible around
	the player (`refresh`), then each frame it:
	  1. waits for the server's edit lists of new full detail chunks (and their neighbours),
	  2. hands jobs to the worker pool: remeshes first (RemeshQueue: edits, then cave reveal by
	     distance, seams, plants), then generation, most urgent first (LoadPriority),
	  3. swaps levels of detail (`swap`) and lets the renderer build parts within its budget.

	Node states: waiting (for edit lists) -> queued -> working (generation job in a worker) ->
	built (parts being created) -> ready (all parts built; shown when nothing covers its area).
	Also: failed (waiting to retry), meshing (a late generation result being meshed again).

	Load order (LoadPriority's hybrid score, recomputed every refresh for nodes not ready yet):
	the ring under the player, then what is in the camera's view wedge by distance, the near ring
	behind, then the rest; nodes hidden behind terrain (`hidden`) last. All the wanted nodes under
	one node being replaced share their best score, since it only goes when all of them are
	ready. The renderer builds generation tasks in the same order (node.priority, `reprioritise`).

	Seamless LOD changes: a node that is no longer wanted stays visible until every node covering
	its area is ready; a ready node whose area a coarser node still shows waits (unshown). Once a
	frame, after a node became ready or the selection changed, `swap` groups the nodes that may
	leave and the nodes waiting to be shown into swap units (SwapUnits: connected through the LOD
	tree) and does whole units, nearest first, until Render.SwapPartsPerFrame parts went out and
	in: within a unit the old nodes are cleared and the new ones shown in the same frame, so two
	levels never overlap and never leave a gap (and ChunkRenderer keeps cleared models
	Render.SwapFrames frames under their replacements).

	Edits (RemeshQueue, ChunkRenderer's commit groups): every section one batch of edits dirtied
	(the edited chunk, and the neighbours whose padding changed) is remeshed by an edit job (the
	workers' and the renderer's edit lanes: never behind generation) and goes live in the same
	frame. A remesh that failed marks its sections dirty again. A node may have several remesh jobs
	in flight; a result only counts for the sections no newer job took.

	Robustness: a node whose generation failed keeps whatever covers its area and retries after
	Streaming.RetryDelay seconds, doubling up to RetryMax. A generation result that comes back
	after an edit touched the chunk (`stale`) is kept: the chunk's current edits are written into
	its data here and only a mesh job is sent, so continuous edits can never starve a chunk.

	Teleports (TeleportMode): MovementController's teleport handler (`teleported`) or a jump of
	more than Streaming.TeleportDistance blocks between refreshes selects at the destination at
	once, without hysteresis, and drops every old node in one pass: their builds and worker jobs
	are cancelled and their models trashed (ChunkRenderer.trashNode: those near the destination
	leave the workspace at once, the rest nearest first within Render.UnparentPartsPerFrame), with
	no seamless-swap bookkeeping. Shown models that overlap nothing wanted are handed to the
	renderer over the next frames (TRASH_PER_FRAME a frame), so the teleport frame stays short. Until
	the 3x3 chunks under the player are shown and the work left is small, or
	Streaming.TeleportTimeout seconds, far meshes and map tiles wait (`onTeleportMode`). The first
	load works the same way. The camera follows the character a frame late, so after `teleported`
	the cave view is judged from the eye above the destination's feet, and a teleport ends the
	underground hold: the destination is selected with the right full detail range at once.

	Far meshes wait while the streamer is busy (MeshOverlay.setStreamerBusy). While the player is
	frozen waiting for terrain the renderer may build longer per frame (`setFrozen`).

	Borders (GreedyMesher.Border): a full detail chunk next to a coarser node is meshed knowing that
	node's level (LodTree.coarserSides), so it draws the border cells the coarser node leaves open
	(no see-through seams), and a section with visible caves next to hidden caves closes its
	tunnels. Both depend on the neighbours, so those chunks are remeshed when their neighbourhood
	changes (only chunks next to a coarse node that changed are looked at: LodTree.seamsAffected).
	Far nodes use borders that hold for any neighbours and never change once built.

	Cave view (CaveReach.view, World/SectionGraph): underground, the sections the camera can see
	into through connected cave air are revealed (meshed with their cave walls), out to the cave
	view's tunnel reach (ViewSettings.revealReach) or, in big caverns, the open space around the
	camera (CaveReach's probe and tracker, ViewSettings.revealRadii) plus a section, within
	Caves.RevealBudget sections. Workers return each full detail chunk's graph (one u32 per
	section) with its generation and recompute it for the sections an edit job remeshes (an edit
	can open or seal a cave); the search runs again when the camera changes section, the reach
	changes, or a graph or a full detail chunk near the camera changed. A section stays revealed
	Caves.RevealHold seconds after the search stopped reaching it; sections of chunks not generated
	yet that the search would enter count as revealed, so the chunk is generated with them revealed.
	Each revealed section is capped (GreedyMesher.Border) where it meets hidden space, and towards
	chunks that are not full detail on screen (a coarser node draws nothing underground). A tunnel
	never opens onto the void: what is on screen is tracked per section (`live`, `liveCaps`, set
	as each mesh goes live: `wentLive`), and a face opens only towards a section whose revealed
	mesh is live or goes live in the same commit group (`drawsCaves`); a section goes hidden only
	together with the caps closing towards it (`canHideNow`, `mayHide`); a full detail chunk
	leaves the screen only once no tunnel next door is open towards it (`swap`). A cap closed
	meanwhile opens once the section beyond is live (`liveCheck`). Only the sections whose reveal
	flag or caps may have changed (the changed keys and their neighbours, chunks next to full
	detail chunks that came, went or were shown, nodes that became ready, meshes that went live)
	are checked (`updateReveal`, `checkPass`); a reveal pass goes live in commit groups of at most
	Streaming.RevealGroupSections sections, nearest first (a cap opening and the tunnel behind it
	together), and what it hides in one group of its own. Caves only exist in full detail chunks,
	so full detail reaches further too: LodTree.select runs with `underground` (the underground
	split distance) while the cave view is active and for Lod.UndergroundSeconds after it ends.

	Hidden terrain (HiddenTerrain, World/Horizon): every generated node carries a summary (lowest
	ground and highest top of 4 x 4 tiles; edits of full detail chunks update theirs:
	Horizon.applyEdits, in the worker and here). About once a second while the camera moves, or
	after HiddenTerrain.MOVE blocks (not in teleport mode: nothing new has a summary yet), a
	worker sweeps the wanted nodes front to back from the camera (raised and spread for safety) and
	returns the far nodes hidden behind nearer terrain (`hidden`): they load last (LoadPriority's
	hidden tier; a node not generated yet is judged from the nodes it replaces). With the "Skip
	hidden terrain" setting (ViewSettings "skipHidden", read every refresh) a hidden far node shows
	no parts (`held`): one generated hidden is never built, and a built one found hidden by
	HiddenTerrain.STREAK verdicts in a row gives its parts back; both count as ready, so swaps go
	on (the nodes they replace go, visible siblings show). Their parts are built again as soon as
	a verdict sees them, or the camera leaves the eyes the verdict was made from. Every far node
	keeps its meshes (`kept`: the buffers its sections show, so they cost no memory of their own),
	so the setting also applies to terrain built while it was off. Nodes within HiddenTerrain.KEEP
	blocks are never hidden.

	Plants: every box of a plant is a part, so only full detail chunks near the viewer draw them
	(LodTree.drawsFoliage). Each job says whether its chunk does (`foliage`), and the worker says
	which sections hold plants; when a chunk starts or stops drawing them, those sections are
	remeshed.

	Hot spots: LodTree.select is skipped while the viewer moved less than a block (and the
	underground switch and LodTree.version are unchanged), and `covered` only recurses into areas
	that hold wanted nodes (`desiredBelow`).

	Settings (`applyView`): LodTree's four distances and plants from ViewSettings, the cave view's
	reach and radii, and an immediate refresh.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Coords = require(Shared.World.Coords)
local LodTree = require(Shared.World.LodTree)
local ChunkLayout = require(Shared.World.ChunkLayout)
local SectionGraph = require(Shared.World.SectionGraph)
local GreedyMesher = require(Shared.Meshing.GreedyMesher)
local TerrainGenerator = require(Shared.Generation.TerrainGenerator)
local PlayerPhysics = require(Shared.Movement.PlayerPhysics)
local Horizon = require(Shared.World.Horizon)
local Blocks = require(Shared.Blocks)

local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local WorkerPool = require(script.Parent.WorkerPool)
local ChunkRenderer = require(script.Parent.Parent.Rendering.ChunkRenderer)
local ViewSettings = require(script.Parent.Parent.Rendering.ViewSettings)
local CaveReach = require(script.Parent.CaveReach)
local LoadPriority = require(script.Parent.LoadPriority)
local RemeshQueue = require(script.Parent.RemeshQueue)
local SwapUnits = require(script.Parent.SwapUnits)
local TeleportMode = require(script.Parent.TeleportMode)
local HiddenTerrain = require(script.Parent.HiddenTerrain)

local SIZE = Config.ChunkSize
local SECTION = Config.SectionHeight
local SECTIONS = Config.WorldHeight // Config.SectionHeight
local BLOCK = Config.BlockSize
local MAX_LEVEL = LodTree.MAX_LEVEL
local LAYER = ChunkLayout.LAYER
local Streaming = Config.Streaming
local Caves = Config.Caves
-- The camera above the feet (blocks), standing.
local EYE_HEIGHT = PlayerPhysics.dimensions("standing").eye
-- Seconds before edit lists are asked for again (a request got lost).
local EDIT_RETRY = 5
-- A selection change bigger than this redoes every chunk's seams instead of the affected ones.
local SEAM_BATCH = 64
-- A teleport's remaining old models handed to the renderer per frame (~10 us each).
local TRASH_PER_FRAME = 64

local EDIT = RemeshQueue.EDIT
local REVEAL = RemeshQueue.REVEAL
local SEAM = RemeshQueue.SEAM
local PLANTS = RemeshQueue.PLANTS

local NEIGHBOURS = { { 0, 0 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local NO_COARSER = LodTree.NO_COARSER
local ALL_SECTIONS: { number } = {}
for s = 0, SECTIONS - 1 do
	ALL_SECTIONS[s + 1] = s
end

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
	-- LoadPriority score (lower is sooner; ChunkRenderer reads it too).
	priority: number,
	-- An edit (or a seam change) came after the generation job was sent.
	stale: boolean,
	failures: number,
	retryAt: number,
	-- The next retry only meshes the kept data (a late result whose mesh job failed).
	meshOnly: boolean,
	since: number,
	retireSince: number?,
	pendingBuilds: number,
	-- Built (all parts created) / in the workspace.
	ready: boolean,
	shown: boolean,
	chunk: ClientWorld.ChunkData?,
	-- Sections meshed with caves visible, and the cave cap mask of each section (as the last job
	-- that took the section was told), and how many are revealed.
	reveal: { [number]: boolean },
	revealCount: number,
	caps: { [number]: number },
	-- What is on screen: sections whose live mesh was meshed revealed, with its caps; and the
	-- commit group of the remesh job last sent for a section, until that mesh goes live.
	live: { [number]: boolean },
	liveCaps: { [number]: number },
	sentGroup: { [number]: any },
	-- Level of the coarser node on each side (0 = none): wanted now / used by the current mesh.
	coarser: { number },
	coarserUsed: { number }?,
	-- Whether its meshes draw plants (what its jobs were told), and the sections holding plants.
	foliage: boolean,
	plants: { [number]: boolean },
	-- Incremented per generation (or late mesh) job; results of older jobs are ignored.
	job: number,
	-- Worker job ids in flight: the generation job, and remesh jobs.
	jobId: number?,
	remeshJobs: { [number]: RemeshQueue.Job },
	-- Full detail: the chunk's cave visibility graph (SectionGraph, one u32 per section), the
	-- token of the edit job recomputing each section, and the sections a late result's mesh job
	-- recomputes.
	graph: buffer?,
	graphJobs: { [number]: number },
	graphSections: { number }?,
	-- The node's Horizon summary (every level, once generated).
	summary: buffer?,
	-- Far nodes: their meshes (the buffers the renderer shows), kept to build them again; set as
	-- `held` while skip hidden terrain shows no parts because the node is hidden.
	kept: Meshes?,
	held: Meshes?,
}

type Meshes = { sections: { number }, meshes: { buffer } }

-- The underground camera (blocks) and how far the search reveals caves (blocks, to section
-- centres).
type CaveView = { position: Vector3, reach: number }

export type Stats = {
	nodes: { [number]: number },
	waiting: number,
	queued: number,
	working: number,
	building: number,
	busyWorkers: number,
	-- The cave view: how far caves are revealed (the search's reach, blocks; 0 above ground) and
	-- whether full detail reaches further (Lod.UndergroundSplitDistanceL1); sections revealed,
	-- reached by the last search, and how long it took (ms).
	revealRadius: number,
	underground: boolean,
	revealed: number,
	reached: number,
	searchMs: number,
	-- Hidden terrain: nodes hidden behind terrain (last verdict), held without parts.
	hidden: number,
	held: number,
	-- Generations waiting to retry, late results being meshed, dirty sections waiting for a job.
	failed: number,
	meshing: number,
	remeshing: number,
	-- Teleport mode (or the first load) is on; parts of dropped models still in the workspace.
	teleporting: boolean,
	trashParts: number,
}

export type ChunkStreamer = {
	generator: TerrainGenerator.Generator,
	world: ClientWorld.ClientWorld,
	pool: WorkerPool.WorkerPool,
	renderer: ChunkRenderer.ChunkRenderer,
	nodes: { [number]: Node },
	desired: { [number]: number },
	-- Wanted nodes under each node key (any level above), for `covered`.
	desiredBelow: { [number]: number },
	-- Queued nodes, most urgent last.
	queue: { Node },
	waiting: { [Node]: boolean },
	retrying: { [Node]: boolean },
	-- Late results waiting for a worker to mesh them.
	meshQueue: { Node },
	-- Ready nodes not shown yet, and nodes no longer wanted.
	unshown: { [Node]: boolean },
	leaving: { [Node]: boolean },
	-- Shown nodes under each node key (any level above).
	shownBelow: { [number]: number? },
	counts: { [string]: number },
	remesh: RemeshQueue.RemeshQueue,
	sinceRefresh: number,
	caveReach: CaveReach.Tracker,
	-- The largest open-space radius (blocks), and how far tunnels are seen (blocks).
	revealMax: number,
	tunnelReach: number,
	-- Updated every refresh; nil while the camera is above the terrain.
	caveView: CaveView?,
	-- The revealed sections, and whether the search must run again (a graph or a full detail
	-- chunk near the camera changed); the graph lookup it uses.
	cave: CaveReach.View,
	caveDirty: boolean,
	graphLookup: SectionGraph.Lookup,
	-- Keeps LodTree's underground split a few seconds after the cave view ended, and whether the
	-- last selection used it.
	undergroundHold: CaveReach.Hold,
	underground: boolean,
	-- The viewer's position (blocks) at the last refresh, and the view wedge then.
	viewer: Vector3,
	view: LoadPriority.View,
	-- Node keys of nodes hidden behind terrain (the horizon verdict). They load last
	-- (LoadPriority.OCCLUDED), and with skipHidden far ones build no parts (`held`).
	hidden: { [number]: boolean },
	horizon: HiddenTerrain.State,
	horizonJobId: number?,
	-- New summaries or a new selection since the last horizon job; a verdict came since the last
	-- refresh.
	summariesChanged: boolean,
	verdictNew: boolean,
	skipHidden: boolean,
	held: { [Node]: boolean },
	-- The camera (blocks) at the last refresh.
	eye: Vector3,
	-- Where the last selection was made, LodTree.version then, and a forced one (settings).
	selectedAt: Vector3?,
	lodVersion: number,
	forceSelect: boolean,
	refreshed: boolean,
	-- Something may be swapped (a node became ready, the selection changed, a unit waits).
	swapDue: boolean,
	-- Nodes with revealed sections; nodes to check for the cave view at the next refresh.
	revealed: { [Node]: boolean },
	revealCheck: { [Node]: boolean },
	-- Full detail chunks shown since the last check (their neighbours' caps may open), and
	-- section keys whose revealed mesh went live since the last frame (the same).
	capCheck: { [number]: boolean },
	liveCheck: { [number]: boolean },
	foliageCheck: { [Node]: boolean },
	teleport: TeleportMode.Mode,
	teleportTarget: Vector3?,
	-- Old models of a teleport still to trash (nearest first, from `trashHead`).
	trashLater: { TeleportMode.Leaving },
	trashHead: number,
	-- Called when teleport mode (or the first load) starts and ends (map tiles wait meanwhile).
	onTeleportMode: ((active: boolean) -> ())?,
	busy: boolean,

	update: (self: ChunkStreamer, dt: number) -> (),
	teleported: (self: ChunkStreamer, feet: Vector3) -> (),
	setFrozen: (self: ChunkStreamer, frozen: boolean) -> (),
	applyView: (self: ChunkStreamer) -> (),
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

local function toSet(list: { number }): { [number]: boolean }
	local set = {}
	for _, v in list do
		set[v] = true
	end
	return set
end

local function setState(self: ChunkStreamer, node: Node, state: string)
	local counts = self.counts
	counts[node.state] = (counts[node.state] or 1) - 1
	node.state = state
	counts[state] = (counts[state] or 0) + 1
end

local function ancestorKey(node: Node, level: number): number
	local f = bit32.lshift(1, level - node.level)
	return Coords.nodeKey(level, node.nx // f, node.nz // f)
end

--[[ The cave view ]]

--[[
	Underground (the camera, `eye`, below its column's terrain surface), the cave view is on: the
	search reaches the tunnel reach, or in big caverns the open space around the camera
	(CaveReach) plus a section. Above ground the revealed sections go after Caves.RevealHold
	seconds.
]]
local function updateCaveView(self: ChunkStreamer, now: number)
	local camera = self.eye
	local surface = self.generator.column(math.floor(camera.X), math.floor(camera.Z))
	if camera.Y >= surface - 1 then
		self.caveReach:update(nil, now)
		self.caveView = nil
		return
	end
	local open = CaveReach.probe(function(x, y, z)
		return self.world:getBlock(x, y, z)
	end, camera.X, camera.Y, camera.Z, self.revealMax)
	local radius = self.caveReach:update(open, now)
	self.caveView = { position = camera, reach = CaveReach.searchReach(self.tunnelReach, radius) }
end

-- Is section `s` of the full detail chunk `node` meshed with caves visible (revealed)?
local function wantsReveal(self: ChunkStreamer, node: Node, s: number): boolean
	return self.cave:reveals(node.nx, node.nz, s)
end

--[[
	May a tunnel next door open towards section `s` of `node`: does it draw its caves on screen
	whenever the tunnel's mesh does? It is revealed, its last job was told so and that mesh is live,
	or its revealed mesh goes live in the same commit as the job being sent (commit group `group`:
	the section waits for a job of that group, which takes the cave view as it is when it is sent,
	or its job of that group has not gone live yet). A section that is only dirty or in flight
	otherwise may go live any number of frames later (behind Streaming.RemeshJobs, or in a reveal
	pass too big to be one group), and until then it meshes its cave air as rock: the tunnel would
	open onto the void. (`pass`: while a pass marks sections, before its group exists, a section
	the pass marked counts: `checkCaps`.)
]]
local function drawsCaves(self: ChunkStreamer, node: Node, s: number, group: any?, pass: boolean?): boolean
	if not self.cave:reveals(node.nx, node.nz, s) then
		return false
	end
	local together = if pass
		then self.remesh:isDirty(node, s) and self.remesh:inPass(node)
		else group ~= nil and self.remesh:groupOf(node, s) == group
	if together then
		return true
	end
	return node.reveal[s] == true and (node.live[s] == true or (group ~= nil and node.sentGroup[s] == group))
end

-- Neighbours of a section by face (GreedyMesher.Border's order): chunk x, chunk z, section.
local FACES = { { -1, 0, 0 }, { 1, 0, 0 }, { 0, -1, 0 }, { 0, 1, 0 }, { 0, 0, -1 }, { 0, 0, 1 } }

-- Can the cave air of section `s` of `node` reach its face `f` (0-based, FACES order)? Its graph
-- says whether a followed pocket touches it (every cave pocket is followed); true without one.
local function touches(node: Node, s: number, f: number): boolean
	local graph = node.graph
	return graph == nil or bit32.btest(buffer.readu32(graph, s * 4), bit32.lshift(1, SectionGraph.FACES_SHIFT + f))
end

-- Is section `s` of `node` revealed on screen with its tunnel open at face `f` (0-based)?
local function openOnScreen(node: Node, s: number, f: number): boolean
	return node.live[s] == true and not bit32.btest(node.liveCaps[s] or 0, bit32.lshift(1, f)) and touches(node, s, f)
end

--[[
	The GreedyMesher.Border hidden mask of revealed section `s` of `node` (meshed by a job of
	commit group `group`): the faces its tunnels are closed in stone at. A face is open only
	towards a section that draws its caves too (`drawsCaves`; `job`: the reveal flags of the
	sections meshed by the same job), in a full detail chunk on screen: a hidden section treats
	cave air as rock and draws no wall there, and a coarser node draws nothing underground, so a
	tunnel open towards either would show the void. A side towards a chunk the selection dropped
	closes in its next job (and the chunk stays on screen until that is live: `swap`); one
	towards a chunk being shown opens once it is (`capCheck`), one towards a section revealed in
	the same small pass with the reveal (`updateReveal`: one commit group), and one towards a
	section revealed otherwise once its revealed mesh is live (`liveCheck`, `updateReveal`).
]]
local function capsOf(
	self: ChunkStreamer,
	node: Node,
	s: number,
	job: { [number]: boolean }?,
	group: any?,
	pass: boolean?
): number
	local mask = 0
	for d, face in FACES do
		local ns = s + face[3]
		if ns < 0 or ns >= SECTIONS then
			continue
		end
		local open
		if face[3] ~= 0 then
			local told = if job then job[ns] else nil
			if told ~= nil then
				open = told
			else
				open = drawsCaves(self, node, ns, group, pass)
			end
		else
			local key = Coords.chunkKey(node.nx + face[1], node.nz + face[2])
			local other = self.nodes[key]
			open = other ~= nil and other.shown and self.desired[key] ~= nil and drawsCaves(self, other, s, group, pass)
		end
		if not open then
			mask += bit32.lshift(1, d - 1)
		end
	end
	return mask
end

-- A graph of a chunk near the camera changed: the cave view searches again.
local function graphChanged(self: ChunkStreamer, node: Node)
	local view = self.caveView
	if view then
		local p = view.position
		local reach = view.reach + SIZE
		local dx = math.max(node.nx * SIZE - p.X, 0, p.X - (node.nx + 1) * SIZE)
		local dz = math.max(node.nz * SIZE - p.Z, 0, p.Z - (node.nz + 1) * SIZE)
		if dx * dx + dz * dz <= reach * reach then
			self.caveDirty = true
		end
	end
end

-- Writes sections `sections` of `from` (a worker's copy of the node's graph) into node.graph.
local function mergeGraph(self: ChunkStreamer, node: Node, from: buffer, sections: { number }, token: number?)
	local graph = node.graph
	if graph == nil or buffer.len(from) ~= buffer.len(graph) then
		return
	end
	local changed = false
	for _, s in sections do
		if s >= 0 and s < SECTIONS and (token == nil or node.graphJobs[s] == token) then
			if token then
				node.graphJobs[s] = nil
			end
			local value = buffer.readu32(from, s * 4)
			if value ~= buffer.readu32(graph, s * 4) then
				buffer.writeu32(graph, s * 4, value)
				changed = true
			end
		end
	end
	if changed then
		graphChanged(self, node)
	end
end

-- The sections a chunk's job edits (ClientWorld.collectJobEdits pairs) touch.
local function editedSections(edits: { number }): { number }
	local found: { [number]: boolean } = {}
	local list = {}
	for i = 1, #edits, 2 do
		local s = edits[i] // LAYER // SECTION
		if not found[s] then
			found[s] = true
			table.insert(list, s)
		end
	end
	return list
end

local function setReveal(self: ChunkStreamer, node: Node, s: number, on: boolean)
	if (node.reveal[s] == true) == on then
		return
	end
	node.reveal[s] = on
	node.revealCount += if on then 1 else -1
	if node.revealCount > 0 then
		self.revealed[node] = true
	else
		self.revealed[node] = nil
	end
end

--[[
	May section `s` of `node`, revealed on screen, go hidden in a remesh job of commit group
	`group` (meshing `job`'s sections)? Not while a neighbour on screen shows its tunnel open
	towards it, unless the mesh closing that tunnel goes live in the same commit (it waits for a
	job of that group, which closes towards a section no longer revealed, or its job of that group
	was told so): the tunnel would open onto cave air meshed as rock. Such a section is meshed
	revealed once more (closed towards what is not revealed), and hidden once the neighbour's cap
	is live (`wentLive`, `updateReveal`).
]]
local function mayHide(self: ChunkStreamer, node: Node, s: number, group: any?, job: { [number]: boolean }): boolean
	if node.live[s] ~= true then
		return true
	end
	for d, face in FACES do
		local ns = s + face[3]
		if ns < 0 or ns >= SECTIONS then
			continue
		end
		local other: Node? = node
		if face[3] == 0 then
			other = self.nodes[Coords.chunkKey(node.nx + face[1], node.nz + face[2])]
		elseif job[ns] then
			-- (Meshed by the same job.)
			continue
		end
		local back = bit32.bxor(d - 1, 1)
		if other == nil or not other.shown or not openOnScreen(other, ns, back) then
			continue
		end
		local closing = group ~= nil
			and (
				self.remesh:groupOf(other, ns) == group
				or (
					other.sentGroup[ns] == group
					and (other.reveal[ns] ~= true or bit32.btest(other.caps[ns] or 0, bit32.lshift(1, back)))
				)
			)
		if not closing then
			return false
		end
	end
	return true
end

--[[
	The sections of `sections` a job meshes revealed: those the cave view reveals, and (a remesh
	job of commit group `group`: `remesh`) those revealed on screen that may not go hidden yet
	(`mayHide`).
]]
local function revealList(
	self: ChunkStreamer,
	node: Node,
	sections: { number },
	remesh: boolean?,
	group: any?
): { number }
	local list = {}
	local job: { [number]: boolean }? = nil
	for _, s in sections do
		if self.cave.count > 0 and wantsReveal(self, node, s) then
			table.insert(list, s)
		elseif remesh and node.live[s] then
			if job == nil then
				job = toSet(sections)
			end
			if not mayHide(self, node, s, group, job :: { [number]: boolean }) then
				table.insert(list, s)
			end
		end
	end
	return list
end

-- Cave caps of the revealed sections `reveal` of a job meshing `sections` (commit group `group`),
-- as a flat { section, mask, ... } list (actor messages only copy plain arrays reliably).
local function capsList(
	self: ChunkStreamer,
	node: Node,
	sections: { number },
	reveal: { number },
	group: any?
): { number }
	local caps: { number } = {}
	if #reveal == 0 then
		return caps
	end
	local job: { [number]: boolean } = {}
	for _, s in sections do
		job[s] = false
	end
	for _, s in reveal do
		job[s] = true
	end
	for _, s in reveal do
		table.insert(caps, s)
		table.insert(caps, capsOf(self, node, s, job, group))
	end
	return caps
end

-- Records what the job just sent for `sections` was told: which are revealed, and their caps.
local function recordReveal(self: ChunkStreamer, node: Node, sections: { number }, reveal: { number }, caps: { number })
	local revealed = toSet(reveal)
	for _, s in sections do
		node.caps[s] = nil
		setReveal(self, node, s, revealed[s] == true)
	end
	for i = 1, #caps, 2 do
		node.caps[caps[i]] = caps[i + 1]
	end
end

--[[
	Section `s` of a full detail chunk went live meshed revealed (`on`) or not, with cave caps
	`caps` (by a job of commit group `group`). When that changed, the sections around check again
	at the next refresh (`liveCheck`, `updateReveal`): a tunnel closed towards a section that did
	not draw its caves yet opens, a section kept revealed until the tunnels next door were closed
	goes hidden (`canHideNow`); and a chunk waiting to leave may go once no tunnel next door is
	open towards it (`swap`).
]]
local function wentLive(self: ChunkStreamer, node: Node, s: number, on: boolean, caps: number?, group: any?)
	if node.removed then
		return
	end
	if group ~= nil and node.sentGroup[s] == group then
		node.sentGroup[s] = nil
	end
	local was, wasCaps = node.live[s] == true, node.liveCaps[s]
	if on then
		node.live[s] = true
		node.liveCaps[s] = caps or 0
	else
		node.live[s] = nil
		node.liveCaps[s] = nil
	end
	-- (A cap opening frees nothing.)
	if on ~= was or (on and bit32.band(caps or 0, bit32.bnot(wasCaps or 0)) ~= 0) then
		self.liveCheck[SectionGraph.key(node.nx, node.nz, s)] = true
	end
	if next(self.leaving) ~= nil then
		self.swapDue = true
	end
end

--[[ Seams ]]

-- Does a mesh made with coarser sides `used` leave holes next to the neighbours `wanted`?
local function seamsChanged(used: { number }?, wanted: { number }): boolean
	for i = 1, 4 do
		if wanted[i] ~= 0 and (used == nil or used[i] ~= wanted[i]) then
			return true
		end
	end
	return false
end

local function markAll(self: ChunkStreamer, node: Node, reason: number)
	local chunk = node.chunk
	if chunk then
		for s = 0, (chunk.emptyAbove - 1) // SECTION do
			self.remesh:mark(node, s, reason)
		end
	end
end

-- A full detail chunk's coarser neighbours from the selection; remeshed if its border changed.
local function updateSeams(self: ChunkStreamer, node: Node)
	node.coarser = LodTree.coarserSides(self.desired, 0, node.nx, node.nz)
	if node.coarserUsed and seamsChanged(node.coarserUsed, node.coarser) then
		if node.state == "working" then
			node.stale = true
		elseif node.chunk then
			-- (Every job from now on uses the new sides.)
			node.coarserUsed = node.coarser
			markAll(self, node, SEAM)
		end
	end
end

--[[ Node lifecycle ]]

local function newNode(key: number, level: number, nx: number, nz: number, now: number): Node
	return {
		level = level,
		nx = nx,
		nz = nz,
		removed = false,
		model = nil,
		sections = {},
		key = key,
		state = "new",
		priority = 0,
		stale = false,
		failures = 0,
		retryAt = 0,
		meshOnly = false,
		since = now,
		retireSince = nil,
		pendingBuilds = 0,
		ready = false,
		shown = false,
		chunk = nil,
		reveal = {},
		revealCount = 0,
		caps = {},
		live = {},
		liveCaps = {},
		sentGroup = {},
		coarser = NO_COARSER,
		coarserUsed = nil,
		foliage = false,
		plants = {},
		job = 0,
		jobId = nil,
		remeshJobs = {},
		graph = nil,
		graphJobs = {},
		graphSections = nil,
		summary = nil,
		kept = nil,
		held = nil,
	}
end

local function countShown(self: ChunkStreamer, node: Node, delta: number)
	local below = self.shownBelow
	for level = node.level + 1, MAX_LEVEL do
		local key = ancestorKey(node, level)
		local n = (below[key] or 0) + delta
		below[key] = if n > 0 then n else nil :: number?
	end
end

-- The worker jobs of a node, to cancel (its remesh jobs release their commit group holds).
local function collectJobs(self: ChunkStreamer, node: Node, ids: { number })
	if node.jobId then
		table.insert(ids, node.jobId)
		node.jobId = nil
	end
	for id, job in node.remeshJobs do
		table.insert(ids, id)
		self.remesh:done(job, true)
	end
	table.clear(node.remeshJobs)
end

--[[
	Takes a node out (`node.removed` must already be set on every node leaving in this pass, so
	clearing one never puts parts of another back: MeshOverlay). `trash` (teleports): its model
	leaves without the swap delay, or (`later`) is handed to the renderer in a later frame; the
	jobs to cancel go into `cancel`.
]]
local function removeNode(
	self: ChunkStreamer,
	node: Node,
	cancel: { number },
	trash: TeleportMode.Leaving?,
	later: boolean?
)
	if trash then
		if later then
			table.insert(self.trashLater, trash)
		else
			self.renderer:trashNode(node, trash.distance, trash.immediate)
		end
	else
		self.renderer:clear(node)
	end
	self.remesh:forget(node)
	collectJobs(self, node, cancel)
	if node.chunk then
		self.world:detach(node.nx, node.nz)
		node.chunk = nil
	end
	if node.shown then
		node.shown = false
		countShown(self, node, -1)
	end
	self.counts[node.state] = (self.counts[node.state] or 1) - 1
	self.nodes[node.key] = nil
	self.waiting[node] = nil
	self.retrying[node] = nil
	self.unshown[node] = nil
	self.leaving[node] = nil
	self.revealed[node] = nil
	self.revealCheck[node] = nil
	self.foliageCheck[node] = nil
	self.held[node] = nil
	node.held = nil
end

local function isReadyKey(self: ChunkStreamer, key: number): boolean
	local node = self.nodes[key]
	return node ~= nil and node.ready
end

-- Are all wanted nodes in the area of node (level, nx, nz) ready? (Only areas holding wanted
-- nodes are visited; `memo` is per swap pass.)
local function descendantsReady(
	self: ChunkStreamer,
	level: number,
	nx: number,
	nz: number,
	memo: { [number]: boolean }
): boolean
	if level == 0 then
		return true
	end
	local key = Coords.nodeKey(level, nx, nz)
	if self.desiredBelow[key] == nil then
		return true
	end
	local known = memo[key]
	if known ~= nil then
		return known
	end
	local result = true
	for dz = 0, 1 do
		for dx = 0, 1 do
			local cx, cz = nx * 2 + dx, nz * 2 + dz
			local child = Coords.nodeKey(level - 1, cx, cz)
			if self.desired[child] then
				if not isReadyKey(self, child) then
					result = false
				end
			elseif not descendantsReady(self, level - 1, cx, cz, memo) then
				result = false
			end
			if not result then
				break
			end
		end
		if not result then
			break
		end
	end
	memo[key] = result
	return result
end

-- Is the area of `node` fully displayed by wanted nodes that are ready?
local function covered(self: ChunkStreamer, node: Node, memo: { [number]: boolean }): boolean
	for level = node.level + 1, MAX_LEVEL do
		local key = ancestorKey(node, level)
		if self.desired[key] then
			return isReadyKey(self, key)
		end
	end
	return descendantsReady(self, node.level, node.nx, node.nz, memo)
end

-- Is a coarser node still showing (part of) this node's area?
local function hiddenByAncestor(self: ChunkStreamer, node: Node): boolean
	for level = node.level + 1, MAX_LEVEL do
		local ancestor = self.nodes[ancestorKey(node, level)]
		if ancestor and ancestor.shown then
			return true
		end
	end
	return false
end

local function show(self: ChunkStreamer, node: Node)
	node.shown = true
	countShown(self, node, 1)
	self.unshown[node] = nil
	self.renderer:show(node)
	if node.level == 0 then
		-- (Revealed tunnels next door may open towards it now.)
		self.capCheck[node.key] = true
	end
end

local function markReady(self: ChunkStreamer, node: Node)
	node.ready = true
	if node.state ~= "queued" and node.state ~= "working" then
		setState(self, node, "ready")
	end
	if not node.shown then
		self.unshown[node] = true
	end
	self.swapDue = true
	if node.level == 0 then
		self.revealCheck[node] = true
		self.foliageCheck[node] = true
	end
end

local function enqueue(self: ChunkStreamer, node: Node)
	setState(self, node, "queued")
	LoadPriority.insert(self.queue, node, function(n: Node): number
		return n.priority
	end)
end

--[[
	Does a shown full detail chunk next to full detail chunk `node` (not one of `going`) still show
	a revealed section whose tunnel is open towards it (its mesh on screen: `live`)? Taking `node`
	away would open that tunnel onto the coarser node, which draws nothing underground. Only
	sections whose cave air can reach that face count (their graph: a followed pocket touches it).
]]
local function tunnelOpenTowards(self: ChunkStreamer, node: Node, going: { [Node]: boolean }): boolean
	for d = 1, 4 do
		local face = FACES[d]
		local other = self.nodes[Coords.chunkKey(node.nx + face[1], node.nz + face[2])]
		if other == nil or not other.shown or going[other] or next(other.live) == nil then
			continue
		end
		-- (Its face towards `node` is the opposite one.)
		local back = bit32.bxor(d - 1, 1)
		for s in other.live do
			if openOnScreen(other, s, back) then
				return true
			end
		end
	end
	return false
end

--[[
	Once a frame when something changed: removes the nodes that may go (replaced and covered, or
	never shown) and shows the ready nodes nothing covers any more, swap unit by swap unit within
	Render.SwapPartsPerFrame (in teleport mode, nodes shown where nothing leaves are not counted).
	A unit taking away a full detail chunk that a revealed tunnel next door is still open towards
	waits until that tunnel's cap is live (`tunnelOpenTowards`; its remesh was marked when the
	selection dropped the chunk), or Streaming.ReplaceTimeout.
]]
local function swap(self: ChunkStreamer, now: number)
	self.swapDue = false
	local timeout = Streaming.ReplaceTimeout
	local memo: { [number]: boolean } = {}
	local renderer = self.renderer
	local viewer = self.viewer
	local entries: { SwapUnits.Entry } = {}
	local unseen: { Node } = {}
	local going: { [Node]: boolean } = {}
	local overdue: { [Node]: boolean } = {}
	for node in self.leaving do
		local since = node.retireSince or now
		local late = now - since > timeout
		if not node.ready or late or covered(self, node, memo) then
			if node.shown then
				going[node] = true
				overdue[node] = late
				table.insert(entries, {
					node = node,
					level = node.level,
					nx = node.nx,
					nz = node.nz,
					leaving = true,
					cost = renderer:partsOf(node),
					priority = LodTree.distance(node.level, node.nx, node.nz, viewer.X, viewer.Z),
				})
			else
				table.insert(unseen, node)
			end
		end
	end
	local cancel: { number } = {}
	-- Nodes never on screen go at once.
	for _, node in unseen do
		node.removed = true
	end
	for _, node in unseen do
		removeNode(self, node, cancel)
	end
	for node in self.unshown do
		-- A node under a shown node that is not going yet keeps waiting (and costs nothing now).
		local blocked = false
		for level = node.level + 1, MAX_LEVEL do
			local ancestor = self.nodes[ancestorKey(node, level)]
			if ancestor and ancestor.shown and not going[ancestor] then
				blocked = true
				break
			end
		end
		if blocked then
			continue
		end
		table.insert(entries, {
			node = node,
			level = node.level,
			nx = node.nx,
			nz = node.nz,
			leaving = false,
			cost = renderer:partsOf(node),
			priority = node.priority,
		})
	end
	if #entries > 0 then
		local units: { SwapUnits.Unit } = {}
		for _, unit in SwapUnits.build(entries) do
			local leaving: { [Node]: boolean } = {}
			for _, member in unit.members do
				if member.leaving then
					leaving[member.node :: Node] = true
				end
			end
			local wait = false
			for node in leaving do
				if node.level == 0 and not overdue[node] and tunnelOpenTowards(self, node, leaving) then
					wait = true
					break
				end
			end
			if not wait then
				table.insert(units, unit)
			end
		end
		local taken = SwapUnits.take(
			units,
			Config.Render.SwapPartsPerFrame,
			if self.teleport.active then SwapUnits.fresh else nil
		)
		for _, unit in taken do
			for _, member in unit.members do
				if member.leaving then
					(member.node :: Node).removed = true
				end
			end
		end
		for _, unit in taken do
			local waiting: { Node } = {}
			for _, member in unit.members do
				local node = member.node :: Node
				if member.leaving then
					removeNode(self, node, cancel)
				else
					table.insert(waiting, node)
				end
			end
			-- Coarser first: a waiting node may itself cover other waiting nodes (when the node
			-- above both timed out), and those must keep waiting for it.
			table.sort(waiting, function(a, b)
				return a.level > b.level
			end)
			for _, node in waiting do
				if not hiddenByAncestor(self, node) and self.shownBelow[node.key] == nil then
					show(self, node)
				end
			end
		end
		if #taken < #units then
			self.swapDue = true
		end
	end
	if #cancel > 0 then
		self.pool:cancel(cancel)
	end
end

--[[ Jobs ]]

-- Skip hidden terrain: does far node `node` keep its meshes without building parts for now?
local function keepsHidden(self: ChunkStreamer, node: Node): boolean
	if not self.skipHidden or node.level == 0 or node.removed or not self.hidden[node.key] then
		return false
	end
	local eye = self.eye
	return self.horizon:holds(eye.X, eye.Y, eye.Z)
end

-- A held node's parts are built again (it is ready and maybe shown: they appear as built).
local function release(self: ChunkStreamer, node: Node)
	local held = node.held
	node.held = nil
	self.held[node] = nil
	if held == nil or node.removed then
		return
	end
	local viewer = self.viewer
	local size = LodTree.nodeSize(node.level)
	local distance = LodTree.distance(node.level, node.nx, node.nz, viewer.X, viewer.Z)
	local inView = LoadPriority.inView(self.view, node.nx * size, node.nz * size, size)
	node.priority = LoadPriority.score(distance, inView, false)
	for i, section in held.sections do
		if buffer.len(held.meshes[i]) > 0 then
			self.renderer:build(node, section, held.meshes[i], { lane = "normal", priority = node.priority })
		end
	end
end

--[[
	Builds a node's first meshes; it is ready when they are all live. A hidden far node with skip
	hidden terrain on keeps them instead (`held`) and is ready at once: nothing it covers can be
	seen, and the nodes it replaces may go.
]]
local function buildFirst(self: ChunkStreamer, node: Node, sections: { number }, meshes: { buffer })
	setState(self, node, "built")
	if node.level == 0 then
		-- (Not on screen before all of it is live: it goes live as told.)
		table.clear(node.live)
		table.clear(node.liveCaps)
		table.clear(node.sentGroup)
		for s, on in node.reveal do
			if on then
				node.live[s] = true
			end
		end
		for s, mask in node.caps do
			node.liveCaps[s] = mask
		end
	end
	node.kept = if node.level > 0 then { sections = sections, meshes = meshes } else nil
	if keepsHidden(self, node) then
		node.held = node.kept
		self.held[node] = true
		node.pendingBuilds = 0
		markReady(self, node)
		return
	end
	local count = 0
	for i in sections do
		if buffer.len(meshes[i]) > 0 then
			count += 1
		end
	end
	node.pendingBuilds = count
	if count == 0 then
		markReady(self, node)
		return
	end
	local function onDone()
		node.pendingBuilds -= 1
		if node.pendingBuilds == 0 and not node.removed then
			markReady(self, node)
		end
	end
	for i, section in sections do
		if buffer.len(meshes[i]) > 0 then
			self.renderer:build(node, section, meshes[i], { lane = "normal", onDone = onDone })
		end
	end
end

local function retryLater(self: ChunkStreamer, node: Node, now: number)
	node.failures += 1
	node.retryAt = now + math.min(Streaming.RetryMax, Streaming.RetryDelay * 2 ^ (node.failures - 1))
	if node.failures == 3 then
		warn(`[IceVoxel] chunk node L{node.level} {node.nx},{node.nz} failed {node.failures} times; retrying`)
	end
	setState(self, node, "failed")
	self.retrying[node] = true
end

local function dispatchMesh(self: ChunkStreamer, node: Node): boolean
	local chunk = node.chunk :: ClientWorld.ChunkData
	local sections = {}
	for s = 0, math.ceil(chunk.height / SECTION) - 1 do
		table.insert(sections, s)
	end
	local reveal = revealList(self, node, sections)
	local caps = capsList(self, node, sections, reveal)
	local job: { [string]: any } = {
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
		caps = caps,
		foliage = node.foliage,
	}
	-- (The edits written into the late result may have opened or sealed caves.)
	local graphSections = node.graphSections
	if node.graph and graphSections and #graphSections > 0 then
		job.graph = node.graph
		job.graphSections = graphSections
	end
	local token = node.job + 1
	local ok = self.pool:submit(job, function(result)
		if node.removed or token ~= node.job then
			return
		end
		node.jobId = nil
		if result.failed then
			retryLater(self, node, os.clock())
			return
		end
		node.failures = 0
		node.meshOnly = false
		if graphSections and type(result.graph) == "buffer" then
			mergeGraph(self, node, result.graph, graphSections)
			node.graphSections = nil
		end
		for _, s in (result.plants or {}) :: { number } do
			node.plants[s] = true
		end
		buildFirst(self, node, result.sections :: { number }, result.meshes :: { buffer })
	end)
	if ok then
		node.job = token
		node.jobId = job.id
		node.coarserUsed = node.coarser
		recordReveal(self, node, sections, reveal, caps)
	end
	return ok
end

local function onGenerated(
	self: ChunkStreamer,
	node: Node,
	token: number,
	result: WorkerPool.Result,
	reveal: { number }
)
	if node.removed or token ~= node.job then
		return
	end
	node.jobId = nil
	local now = os.clock()
	if result.failed then
		-- Whatever covers its area stays until a retry succeeds.
		retryLater(self, node, now)
		return
	end
	node.failures = 0
	if result.quads then
		self.renderer:setQuads(node, result.quads, result.quadCount)
	end
	if type(result.summary) == "buffer" then
		node.summary = result.summary
		self.summariesChanged = true
	end
	if node.level == 0 then
		local chunk: ClientWorld.ChunkData = {
			data = result.data,
			height = result.height,
			solidBelow = result.solidBelow,
			emptyAbove = result.emptyAbove,
		}
		node.graph = if type(result.graph) == "buffer" then result.graph else nil
		table.clear(node.graphJobs)
		node.graphSections = nil
		graphChanged(self, node)
		if node.stale then
			-- An edit (or a coarser neighbour) came after the job was sent: keep the data, write
			-- the chunk's current edits into it and only mesh it again (and recompute the graph
			-- of the sections they touch).
			node.stale = false
			local edits = self.world:collectJobEdits(node.nx, node.nz)
			ClientWorld.applyJobEdits(chunk, edits)
			local summary = node.summary
			if summary then
				Horizon.applyEdits(summary, chunk.data, chunk.height, edits, Blocks.cullLut)
			end
			node.graphSections = editedSections(edits)
			node.chunk = chunk
			node.plants = {}
			self.world:attach(node.nx, node.nz, chunk)
			node.meshOnly = true
			setState(self, node, "meshing")
			table.insert(self.meshQueue, node)
			return
		end
		node.chunk = chunk
		node.plants = toSet(result.plants or {})
		self.world:attach(node.nx, node.nz, chunk)
	elseif node.stale then
		node.stale = false
		enqueue(self, node)
		return
	end
	local _ = reveal
	buildFirst(self, node, result.sections :: { number }, result.meshes :: { buffer })
end

-- Should `node` draw its plants now (LodTree.drawsFoliage, from the last refresh's viewer)?
local function wantsFoliage(self: ChunkStreamer, node: Node): boolean
	local viewer = self.viewer
	return LodTree.drawsFoliage(node.level, node.nx, node.nz, viewer.X, viewer.Z, node.foliage)
end

local function dispatchGenerate(self: ChunkStreamer, node: Node): boolean
	node.foliage = wantsFoliage(self, node)
	local job: { [string]: any } = {
		kind = "generate",
		level = node.level,
		nx = node.nx,
		nz = node.nz,
		coarser = node.coarser,
		quads = self.renderer:wantsQuads(node.level),
		foliage = node.foliage,
	}
	local reveal: { number } = {}
	if node.level == 0 then
		job.edits = self.world:collectJobEdits(node.nx, node.nz)
		reveal = revealList(self, node, ALL_SECTIONS)
		job.reveal = reveal
		job.caps = capsList(self, node, ALL_SECTIONS, reveal)
	end
	local token = node.job + 1
	local ok = self.pool:submit(job, function(result)
		onGenerated(self, node, token, result, reveal)
	end)
	if ok then
		node.job = token
		node.jobId = job.id
		node.stale = false
		node.coarserUsed = node.coarser
		if node.level == 0 then
			recordReveal(self, node, ALL_SECTIONS, reveal, job.caps)
		end
		setState(self, node, "working")
	end
	return ok
end

--[[
	A remesh job's result: builds of the sections it still owns, in its lane and commit group
	(`told`, `caps`: what the job was told, on screen once each build goes live).
]]
local function onRemeshed(
	self: ChunkStreamer,
	node: Node,
	job: RemeshQueue.Job,
	id: number,
	result: WorkerPool.Result,
	told: { [number]: boolean },
	caps: { [number]: number }
)
	node.remeshJobs[id] = nil
	if node.removed then
		self.remesh:done(job, true)
		return
	end
	local remesh = self.remesh
	if result.failed then
		for _, section in job.sections do
			if remesh:current(node, section, job.token) and node.sentGroup[section] == job.group then
				node.sentGroup[section] = nil
			end
		end
		remesh:done(job, true, os.clock())
		return
	end
	local lane = if job.edit then "edit" else "near"
	local priority = if job.edit then nil else LodTree.distance(0, node.nx, node.nz, self.viewer.X, self.viewer.Z)
	local meshes = result.meshes :: { buffer }
	local group = job.group
	for i, section in result.sections :: { number } do
		if remesh:current(node, section, job.token) then
			node.plants[section] = nil
			local on, mask = told[section] == true, caps[section]
			self.renderer:build(node, section, meshes[i], {
				lane = lane,
				group = group,
				priority = priority,
				onDone = function()
					wentLive(self, node, section, on, mask, group)
				end,
			})
		end
	end
	for _, section in (result.plants or {}) :: { number } do
		if remesh:current(node, section, job.token) then
			node.plants[section] = true
		end
	end
	if type(result.graph) == "buffer" then
		mergeGraph(self, node, result.graph, job.sections, job.token)
	end
	remesh:done(job, false)
end

local function submitRemesh(self: ChunkStreamer, job: RemeshQueue.Job): boolean
	local node = job.node :: Node
	local chunk = node.chunk :: ClientWorld.ChunkData
	local sections = job.sections
	local reveal = revealList(self, node, sections, true, job.group)
	local caps = capsList(self, node, sections, reveal, job.group)
	local work: { [string]: any } = {
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
		caps = caps,
		foliage = node.foliage,
		edit = if job.edit then true else nil,
	}
	-- Edits can open or seal caves: an edit job recomputes its sections' graph values.
	local graph = if job.edit then node.graph else nil
	if graph then
		work.graph = graph
		work.graphSections = sections
	end
	local told, capMap = toSet(reveal), {}
	for i = 1, #caps, 2 do
		capMap[caps[i]] = caps[i + 1]
	end
	local ok = self.pool:submit(work, function(result)
		onRemeshed(self, node, job, work.id, result, told, capMap)
	end)
	if ok then
		node.remeshJobs[work.id] = job
		node.coarserUsed = node.coarser
		recordReveal(self, node, sections, reveal, caps)
		for _, s in sections do
			node.sentGroup[s] = job.group
		end
		if graph then
			for _, s in sections do
				node.graphJobs[s] = job.token
			end
		end
	end
	return ok
end

local function dispatch(self: ChunkStreamer, now: number)
	local pool = self.pool
	local counts = self.counts
	-- Remeshes: edits first (their own slots), then cave reveal, seams and plants, leaving some
	-- workers to generation while it has work.
	local generating = #self.queue > 0 or (counts.waiting or 0) > 0 or #self.meshQueue > 0
	local viewer = self.viewer
	self.remesh:dispatch(function(job: RemeshQueue.Job): boolean
		local edit = job.edit
		if not pool:hasCapacity(edit) then
			return false
		end
		return submitRemesh(self, job)
	end, function(node: Node): boolean
		return node.ready and node.chunk ~= nil and not node.removed
	end, function(node: Node): number
		return LodTree.distance(0, node.nx, node.nz, viewer.X, viewer.Z)
	end, if generating then Streaming.RemeshJobs else math.huge, now)

	-- Late results to mesh, then generation, most urgent last in the queue.
	local meshQueue = self.meshQueue
	while #meshQueue > 0 and pool:hasCapacity() do
		local node = table.remove(meshQueue, 1) :: Node
		if not node.removed and node.state == "meshing" and node.jobId == nil then
			if not dispatchMesh(self, node) then
				table.insert(meshQueue, 1, node)
				break
			end
		end
	end
	local queue = self.queue
	while pool:hasCapacity() do
		local node = table.remove(queue)
		if node == nil then
			break
		end
		if node.state == "queued" and not node.removed and node.retireSince == nil then
			if not dispatchGenerate(self, node) then
				table.insert(queue, node)
				break
			end
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

--[[
	The cave view of one section of a ready full detail chunk, in two passes (see `checkPass`):
	`checkFlag` remeshes it (REVEAL) when it should be revealed and isn't, or the other way round
	(a section of air, with nothing to mesh either way, only changes its flag; returns whether it
	was marked); `checkCaps` remeshes a revealed section whose caps changed on a face where they
	matter (`capFaces`; returns the faces it closes). A section with a job waiting needs nothing:
	the job takes the cave view as it is when it is sent. In a pass (`later` given), a section
	whose caps would only open towards sections that pass marked is not marked but put in
	`later`: that only pays if the pass is one commit group.
]]
local function checkFlag(self: ChunkStreamer, node: Node, s: number, hides: { [number]: Node }?): boolean
	local want = wantsReveal(self, node, s)
	if want == (node.reveal[s] == true) then
		return false
	end
	local remesh = self.remesh
	if remesh:isDirty(node, s) then
		return false
	end
	local chunk = node.chunk :: ClientWorld.ChunkData
	if GreedyMesher.isTrivial(s * SECTION, (s + 1) * SECTION, chunk.solidBelow, chunk.emptyAbove, false) then
		setReveal(self, node, s, want)
		node.caps[s] = nil
		wentLive(self, node, s, want, nil, nil)
		return false
	end
	if hides and not want and node.live[s] then
		-- (Marked by checkPass if the tunnels next door can close with it.)
		hides[SectionGraph.key(node.nx, node.nz, s)] = node
		return true
	end
	remesh:mark(node, s, REVEAL)
	return true
end

--[[
	Can section `s` of `node`, revealed on screen, go hidden in the pass being collected (`hides`:
	the sections it would hide, `whole`: the nodes of its hiding group)? Every neighbour on screen
	whose tunnel is open towards it must close it in the same group: it hides too (a neighbour
	waiting to hide is added to `more`, unless `rejected`), or its waiting job (which closes
	towards a section no longer revealed) joins the group. Otherwise it waits: its neighbour's cap
	going live checks it again (`wentLive`), and no remesh is spent keeping it revealed meanwhile
	(`mayHide`).
]]
local function canHideNow(
	self: ChunkStreamer,
	node: Node,
	s: number,
	hides: { [number]: Node },
	whole: { [Node]: boolean },
	more: { [number]: Node },
	rejected: { [number]: boolean }
): boolean
	local remesh = self.remesh
	for d, face in FACES do
		local ns = s + face[3]
		if ns < 0 or ns >= SECTIONS then
			continue
		end
		local other: Node? = node
		if face[3] == 0 then
			other = self.nodes[Coords.chunkKey(node.nx + face[1], node.nz + face[2])]
		end
		if other == nil or not other.shown or not openOnScreen(other, ns, bit32.bxor(d - 1, 1)) then
			continue
		end
		local key = SectionGraph.key(other.nx, other.nz, ns)
		if hides[key] or more[key] then
			continue
		end
		if not remesh:isDirty(other, ns) then
			if
				not rejected[key]
				and other.ready
				and other.chunk ~= nil
				and other.reveal[ns] == true
				and not wantsReveal(self, other, ns)
			then
				-- (It waits to hide too: they go together.)
				more[key] = other
				continue
			end
			return false
		end
		if other ~= node then
			-- (Not when its node already waits in another batch.)
			if remesh:groupOf(other, ns) ~= nil then
				return false
			end
			remesh:mark(other, ns, REVEAL)
			whole[other] = true
		end
	end
	return true
end

--[[
	The faces of section `s` of `node` where its cave caps change its mesh: those its cave air
	reaches, or the cave air of the full detail section beyond (a closed face does not draw the
	rock walling that in), as far as the graphs know.
]]
local function capFaces(self: ChunkStreamer, node: Node, s: number): number
	local mask = 0
	for d, face in FACES do
		local f = d - 1
		local ns = s + face[3]
		if ns < 0 or ns >= SECTIONS then
			continue
		end
		local other = if face[3] == 0 then self.nodes[Coords.chunkKey(node.nx + face[1], node.nz + face[2])] else node
		if touches(node, s, f) or (other ~= nil and other.graph ~= nil and touches(other, ns, bit32.bxor(f, 1))) then
			mask += bit32.lshift(1, f)
		end
	end
	return mask
end

local function checkCaps(self: ChunkStreamer, node: Node, s: number, later: { any }?): number
	if node.reveal[s] ~= true or not wantsReveal(self, node, s) or self.remesh:isDirty(node, s) then
		return 0
	end
	-- (As its job in flight, if any, saw them: a section of that job's group still counts.)
	local group = node.sentGroup[s]
	local caps = capsOf(self, node, s, nil, group)
	local was = node.caps[s] or 0
	local faces = capFaces(self, node, s)
	if bit32.band(bit32.bxor(caps, was), faces) == 0 then
		if later and bit32.band(bit32.bxor(capsOf(self, node, s, nil, group, true), was), faces) ~= 0 then
			table.insert(later, node)
			table.insert(later, s)
		end
		return 0
	end
	local chunk = node.chunk :: ClientWorld.ChunkData
	if GreedyMesher.isTrivial(s * SECTION, (s + 1) * SECTION, chunk.solidBelow, chunk.emptyAbove, false) then
		node.caps[s] = caps
		if node.live[s] then
			node.liveCaps[s] = caps
		end
		return 0
	end
	self.remesh:mark(node, s, REVEAL)
	-- (The faces it closes.)
	return bit32.band(caps, bit32.bnot(was))
end

-- The section keys of `node` that are revealed or meshed revealed, into `check`.
local function addSections(self: ChunkStreamer, node: Node, check: { [number]: boolean })
	local base = SectionGraph.key(node.nx, node.nz, 0)
	if node.revealCount > 0 then
		for s, on in node.reveal do
			if on then
				check[base + s] = true
			end
		end
	end
	if self.cave.count > 0 then
		for _, s in SectionGraph.sectionsOf(self.cave.revealed, node.nx, node.nz) do
			check[base + s] = true
		end
	end
end

--[[
	One cave view pass over the section keys `check` (RemeshQueue.beginPass / endPass): flags first
	(`checkFlag`), then the caps of those sections and the neighbours of the flipped ones
	(`checkCaps`), so a section opening towards one revealed in this pass is marked in the same
	pass (one commit group; a big pass is cut into groups, nearest first), whatever order the
	sections come in. Sections being hidden and the caps closing towards them are one group of
	their own whatever its size (RemeshQueue.endPass's `whole`), so the tunnels next door close
	as they go hidden; a section whose neighbour cannot close in that group waits
	(`canHideNow`). Caps that would open towards a section revealed in this pass are only
	remeshed in it when the pass is small enough to be one commit group; otherwise they open
	once that section is live (`liveCheck`).
]]
local function checkPass(self: ChunkStreamer, check: { [number]: boolean })
	local nodes = self.nodes
	local remesh = self.remesh
	remesh:beginPass()
	local flipped: { number } = {}
	local hiding: { [number]: boolean } = {}
	local whole: { [Node]: boolean } = {}
	-- Sections to hide that are revealed on screen: marked below if they can go now.
	local hides: { [number]: Node } = {}
	for key in check do
		local cx, cz, s = SectionGraph.decode(key)
		local node = nodes[Coords.chunkKey(cx, cz)]
		if node and node.chunk and node.ready and not node.removed and checkFlag(self, node, s, hides) then
			table.insert(flipped, key)
			if node.reveal[s] then
				hiding[key] = true
				if hides[key] == nil then
					whole[node] = true
				end
			end
		end
	end
	for key in SectionGraph.neighbourhood(flipped) do
		check[key] = true
	end
	local later: { any } = {}
	for key in check do
		local cx, cz, s = SectionGraph.decode(key)
		local node = nodes[Coords.chunkKey(cx, cz)]
		if node and node.chunk and node.ready and not node.removed then
			local closes = checkCaps(self, node, s, later)
			if closes ~= 0 and not whole[node] and next(hiding) ~= nil then
				for d, face in FACES do
					if
						bit32.btest(closes, bit32.lshift(1, d - 1))
						and hiding[SectionGraph.key(cx + face[1], cz + face[2], s + face[3])]
					then
						whole[node] = true
						break
					end
				end
			end
		end
	end
	if #later > 0 and remesh:passSize() + #later // 2 <= Streaming.RevealGroupSections then
		for i = 1, #later, 2 do
			remesh:mark(later[i], later[i + 1], REVEAL)
		end
	end
	-- Hides whose tunnels next door cannot all close with them wait (and so may others then);
	-- sections waiting to hide that they are open to join them.
	local rejected: { [number]: boolean } = {}
	local changed = next(hides) ~= nil
	while changed do
		changed = false
		local more: { [number]: Node } = {}
		for key, node in hides do
			local _, _, s = SectionGraph.decode(key)
			if not canHideNow(self, node, s, hides, whole, more, rejected) then
				hides[key] = nil
				rejected[key] = true
				changed = true
			end
		end
		for key, node in more do
			if hides[key] == nil and not rejected[key] then
				hides[key] = node
				changed = true
			end
		end
	end
	for key, node in hides do
		local _, _, s = SectionGraph.decode(key)
		remesh:mark(node, s, REVEAL)
		whole[node] = true
	end
	local viewer = self.viewer
	remesh:endPass(Streaming.RevealGroupSections, whole, function(node: Node): number
		return LodTree.distance(0, node.nx, node.nz, viewer.X, viewer.Z)
	end)
end

--[[
	The cave view after a refresh (`changed`: the node keys the selection added or removed, if it
	changed): the search runs if needed (CaveReach.view), then only the sections whose reveal flag
	or caps may differ are checked: the sections revealed or hidden and their neighbours, the
	sections of chunks next to full detail chunks that came or went, and those of nodes that became
	ready since. One pass's remeshes are one commit group when few (RemeshQueue.beginPass).
]]
local function updateReveal(self: ChunkStreamer, changed: { [number]: number }?, now: number)
	local view = self.caveView
	local dirty = self.caveDirty
	self.caveDirty = false
	if view and changed and not dirty then
		-- Full detail chunks within reach came or went: the search's lookup changed.
		local p = view.position
		local reach = view.reach + SIZE
		for key, level in changed do
			if level == 0 then
				local cx, cz = Coords.decodeChunkKey(key)
				local dx = math.max(cx * SIZE - p.X, 0, p.X - (cx + 1) * SIZE)
				local dz = math.max(cz * SIZE - p.Z, 0, p.Z - (cz + 1) * SIZE)
				if dx * dx + dz * dz <= reach * reach then
					dirty = true
					break
				end
			end
		end
	end
	local p = if view then view.position else nil
	local added, removed = self.cave:update(
		self.graphLookup,
		if p then p.X else nil,
		if p then p.Y else nil,
		if p then p.Z else nil,
		if view then view.reach else 0,
		now,
		dirty
	)
	local check: { [number]: boolean } = {}
	if #added + #removed > 0 then
		table.move(removed, 1, #removed, #added + 1, added)
		check = SectionGraph.neighbourhood(added)
	end
	-- Chunks next to full detail chunks that came, went or were shown.
	local around = self.capCheck
	if changed then
		for key, level in changed do
			if level == 0 then
				around[key] = true
			end
		end
	end
	local nodes = self.nodes
	for key in around do
		local cx, cz = Coords.decodeChunkKey(key)
		for _, offset in NEIGHBOURS do
			local node = nodes[Coords.chunkKey(cx + offset[1], cz + offset[2])]
			if node then
				addSections(self, node, check)
			end
		end
	end
	table.clear(around)
	for node in self.revealCheck do
		addSections(self, node, check)
	end
	table.clear(self.revealCheck)
	-- Sections whose mesh on screen changed (`wentLive`), and their neighbours: a tunnel closed
	-- towards a section while it did not draw its caves yet opens now, a section kept revealed
	-- while a tunnel next door was open towards it goes hidden now (`canHideNow`).
	if next(self.liveCheck) ~= nil then
		local keys: { number } = {}
		for key in self.liveCheck do
			table.insert(keys, key)
		end
		table.clear(self.liveCheck)
		for key in SectionGraph.neighbourhood(keys) do
			check[key] = true
		end
	end
	if next(check) == nil then
		return
	end
	checkPass(self, check)
end

--[[
	Full detail chunks that should start or stop drawing their plants (the viewer moved, or the
	plant setting changed) remesh the sections holding them. Nodes with a generation job queued or
	running are left alone: that job takes the current answer.
]]
local function updateFoliageNode(self: ChunkStreamer, node: Node)
	if
		node.level == 0
		and node.chunk ~= nil
		and node.ready
		and node.state ~= "queued"
		and node.state ~= "working"
		and node.retireSince == nil
	then
		local want = wantsFoliage(self, node)
		if want ~= node.foliage then
			node.foliage = want
			for s in node.plants do
				self.remesh:mark(node, s, PLANTS)
			end
		end
	end
end

-- Wanted nodes under each node key, for `covered`.
local function countDesired(self: ChunkStreamer)
	local below: { [number]: number } = {}
	for key, level in self.desired do
		local _, nx, nz = Coords.decodeNodeKey(key)
		for l = level + 1, MAX_LEVEL do
			local f = bit32.lshift(1, l - level)
			local k = Coords.nodeKey(l, nx // f, nz // f)
			below[k] = (below[k] or 0) + 1
		end
	end
	self.desiredBelow = below
end

-- New and unwanted nodes after the selection changed (`changed`: keys added or removed).
local function applySelection(self: ChunkStreamer, changed: { [number]: number }, count: number, now: number)
	local desired = self.desired
	local newChunks: { Node } = {}
	for key, level in changed do
		local node = self.nodes[key]
		if desired[key] then
			if node == nil then
				local _, nx, nz = Coords.decodeNodeKey(key)
				local n = newNode(key, level, nx, nz, now)
				self.nodes[key] = n
				if level == 0 then
					setState(self, n, "waiting")
					self.waiting[n] = true
					requestEdits(self, n)
					table.insert(newChunks, n)
				else
					setState(self, n, "queued")
				end
			else
				-- Wanted again before it went.
				node.retireSince = nil
				self.leaving[node] = nil
			end
		elseif node and node.retireSince == nil then
			node.retireSince = now
			self.leaving[node] = true
		end
	end
	-- Seams: new chunks, and chunks next to a coarse node that appeared or went away.
	if count > SEAM_BATCH then
		for key, level in desired do
			if level == 0 then
				local node = self.nodes[key]
				if node then
					updateSeams(self, node)
				end
			end
		end
	else
		for _, node in newChunks do
			node.coarser = LodTree.coarserSides(desired, 0, node.nx, node.nz)
		end
		for key in LodTree.seamsAffected(changed, desired) do
			local node = self.nodes[key]
			if node then
				updateSeams(self, node)
			end
		end
	end
	-- Edit lists of full detail chunks and their neighbours.
	local keep: { [number]: boolean } = {}
	for key, level in desired do
		if level == 0 then
			local _, nx, nz = Coords.decodeNodeKey(key)
			for _, offset in NEIGHBOURS do
				keep[Coords.chunkKey(nx + offset[1], nz + offset[2])] = true
			end
		end
	end
	self.world:forgetEditsExcept(keep)
	countDesired(self)
end

-- Does a wanted node lie on, over or under `node`'s area?
local function overlapsWanted(self: ChunkStreamer, node: Node): boolean
	if self.desired[node.key] ~= nil or self.desiredBelow[node.key] ~= nil then
		return true
	end
	for level = node.level + 1, MAX_LEVEL do
		if self.desired[ancestorKey(node, level)] then
			return true
		end
	end
	return false
end

-- Hands deferred old models to the renderer, TRASH_PER_FRAME of them nearest first; `wanted`:
-- instead all of those a wanted node now overlaps.
local function trashSome(self: ChunkStreamer, wanted: boolean?)
	local list = self.trashLater
	local renderer = self.renderer
	if wanted then
		local keep = {}
		for i = self.trashHead, #list do
			local entry = list[i]
			if overlapsWanted(self, entry.node) then
				renderer:trashNode(entry.node, entry.distance, true)
			else
				table.insert(keep, entry)
			end
		end
		self.trashLater = keep
		self.trashHead = 1
		return
	end
	local head = self.trashHead
	local last = math.min(#list, head + TRASH_PER_FRAME - 1)
	while head <= last do
		local entry = list[head]
		head += 1
		renderer:trashNode(entry.node, entry.distance, entry.immediate)
	end
	if head > #list then
		table.clear(list)
		head = 1
	end
	self.trashHead = head
end

-- Teleport: every node no longer wanted goes now (see the header).
local function dropOldArea(self: ChunkStreamer, pos: Vector3)
	local old: { Node } = {}
	for key, node in self.nodes do
		if not self.desired[key] then
			table.insert(old, node)
		end
	end
	local near = 1.5 * LodTree.splitDistanceL1(self.underground) * LodTree.nodeSize(1)
	local plan = TeleportMode.plan(old, pos.X, pos.Z, near)
	for _, entry in plan do
		entry.node.removed = true
	end
	local cancel: { number } = {}
	for _, entry in plan do
		local node = entry.node
		-- Shown models that overlap nothing wanted can wait a few frames (nothing is shown over
		-- or under them meanwhile; a refresh trashes at once those a new selection overlaps).
		local later = node.shown and not entry.immediate and not overlapsWanted(self, node)
		removeNode(self, node, cancel, entry, later)
	end
	if #cancel > 0 then
		self.pool:cancel(cancel)
	end
end

-- Scores of the nodes not ready yet (LoadPriority), the queue sorted again.
local function prioritise(self: ChunkStreamer)
	local view = self.view
	local viewer = self.viewer
	local hidden = self.hidden
	local nodes = self.nodes
	local groups: { [Node]: { Node } } = {}
	local queue: { Node } = {}
	-- (Replacement groups only exist while shown nodes are being replaced.)
	local replacing = next(self.leaving) ~= nil
	for key, node in nodes do
		if node.ready or node.retireSince then
			continue
		end
		local level = node.level
		local size = LodTree.nodeSize(level)
		local distance = LodTree.distance(level, node.nx, node.nz, viewer.X, viewer.Z)
		local inView = LoadPriority.inView(view, node.nx * size, node.nz * size, size)
		node.priority = LoadPriority.score(distance, inView, hidden[key] == true)
		-- The replacement group: wanted nodes under the same shown node being replaced.
		for l = level + 1, if replacing then MAX_LEVEL else level do
			local ancestor = nodes[ancestorKey(node, l)]
			if ancestor and ancestor.shown then
				if ancestor.retireSince then
					local group = groups[ancestor]
					if group == nil then
						group = {}
						groups[ancestor] = group
					end
					table.insert(group, node)
				end
				break
			end
		end
		if node.state == "queued" then
			table.insert(queue, node)
		end
	end
	LoadPriority.share(groups :: any)
	LoadPriority.sort(queue, function(n: Node): number
		return n.priority
	end)
	self.queue = queue
	self.renderer:reprioritise()
end

--[[ Hidden terrain ]]

local function onHorizon(self: ChunkStreamer, token: number, result: WorkerPool.Result)
	if token == self.horizon.inFlight then
		self.horizonJobId = nil
	end
	local hidden = if result.failed then nil else result.hidden :: { number }?
	if self.horizon:received(token, hidden, os.clock()) then
		self.hidden = self.horizon.hidden
		self.verdictNew = true
	end
end

--[[
	Sends a horizon job when one is due (HiddenTerrain), in the pool's overflow slot (it must not
	wait for loading to finish: it orders the loading). Not in teleport mode (and the first load):
	no node of the new area has a summary yet, so nothing could be found hidden, and the workers
	are better used generating.
]]
local function updateHorizon(self: ChunkStreamer, now: number)
	local eye = self.eye
	local state = self.horizon
	if
		self.teleport.active
		or not state:due(now, eye.X, eye.Y, eye.Z, self.summariesChanged)
		or not self.pool:hasCapacity(false, true)
	then
		return
	end
	local nodes = self.nodes
	local records, count = HiddenTerrain.records(self.desired, function(key: number): buffer?
		local node = nodes[key]
		return if node then node.summary else nil
	end)
	if count == 0 then
		return
	end
	self.summariesChanged = false
	local job: { [string]: any } = {
		kind = "horizon",
		records = records,
		count = count,
		x = eye.X,
		y = eye.Y,
		z = eye.Z,
		raise = state.raise,
		spread = state.spread,
		keep = state.keep,
		bins = state.bins,
	}
	local token = state:sent(now, eye.X, eye.Y, eye.Z)
	if self.pool:submit(job, function(result)
		onHorizon(self, token, result)
	end, true) then
		self.horizonJobId = job.id
	else
		state:received(token, nil, now)
	end
end

local EMPTY = buffer.create(0)

--[[
	Skip hidden terrain, once a refresh: held nodes whose verdict changed or stopped holding (or
	skipping was switched off: far nodes keep their meshes, for when it is on again) build their
	parts again; after a new verdict, built far nodes it
	found hidden HiddenTerrain.STREAK times in a row give theirs back (empty builds, in the
	background lane), keeping their meshes, unless the camera moves faster than
	HiddenTerrain.MAX_SPEED (the next verdict would come too late to hold). Levels the far meshes merge (MeshOverlay, unless
	switched off) are left alone: their parts leave the workspace under a MeshPart anyway, and
	changing them would undo the merge.
]]
local function updateHeld(self: ChunkStreamer, switchedOff: boolean)
	if not self.skipHidden then
		self.verdictNew = false
		if switchedOff then
			for node in table.clone(self.held) do
				release(self, node)
			end
		end
		return
	end
	for node in table.clone(self.held) do
		if not keepsHidden(self, node) then
			release(self, node)
		end
	end
	if not self.verdictNew then
		return
	end
	self.verdictNew = false
	if self.horizon:speed() > HiddenTerrain.MAX_SPEED then
		return
	end
	local streak = self.horizon.streak
	local renderer = self.renderer
	local overlay = renderer.overlay
	local merging = overlay.active and not overlay.userOff
	for key, node in self.nodes do
		local kept = node.kept
		if
			kept
			and node.held == nil
			and node.ready
			and node.shown
			and (streak[key] or 0) >= HiddenTerrain.STREAK
			and not (merging and renderer:wantsQuads(node.level))
			and keepsHidden(self, node)
		then
			node.held = kept
			self.held[node] = true
			for i, section in kept.sections do
				if buffer.len(kept.meshes[i]) > 0 then
					renderer:build(node, section, EMPTY, { lane = "background" })
				end
			end
		end
	end
end

-- Teleports: the verdict was for somewhere else.
local function resetHorizon(self: ChunkStreamer)
	local id = self.horizonJobId
	if id then
		self.pool:cancel({ id })
		self.horizonJobId = nil
	end
	self.horizon:reset()
	self.hidden = self.horizon.hidden
	self.summariesChanged = true
end

local function refresh(self: ChunkStreamer, now: number)
	local target = self.teleportTarget
	self.teleportTarget = nil
	local pos = if target then target else viewerPosition() / BLOCK
	-- (The first load works like a teleport, with nothing to drop.)
	local teleport = not self.refreshed
		or TeleportMode.isJump(self.viewer.X, self.viewer.Z, pos.X, pos.Z, Streaming.TeleportDistance)
	self.refreshed = true
	self.viewer = pos
	local camera = workspace.CurrentCamera
	local look = camera.CFrame.LookVector
	local viewport = camera.ViewportSize
	local aspect = if viewport.Y > 0 then viewport.X / viewport.Y else 16 / 9
	self.view = LoadPriority.view(pos.X, pos.Z, look.X, look.Z, camera.FieldOfView, aspect)
	-- (After `teleported` the camera follows the character a frame later: the eye is put above
	-- the destination's feet.)
	self.eye = if target then Vector3.new(target.X, target.Y + EYE_HEIGHT, target.Z) else camera.CFrame.Position / BLOCK
	self.horizon:track(now, self.eye.X, self.eye.Z)
	local skipWas = self.skipHidden
	self.skipHidden = ViewSettings.get("skipHidden") == 1

	-- The cave view first: underground, full detail reaches further (see the header). A teleport
	-- judges it at the destination at once: the old place's open space and underground hold
	-- would select the destination with the underground split for Lod.UndergroundSeconds.
	if teleport then
		self.undergroundHold:reset()
		self.caveReach:reset()
	end
	updateCaveView(self, now)
	local underground = self.undergroundHold:update(self.caveView ~= nil, now)
	local selectedAt = self.selectedAt
	local version = LodTree.version()
	local reselect = teleport
		or self.forceSelect
		or version ~= self.lodVersion
		or underground ~= self.underground
		or selectedAt == nil
		or (Vector3.new(pos.X - selectedAt.X, 0, pos.Z - selectedAt.Z)).Magnitude >= 1
	local selectionChanged: { [number]: number }? = nil
	if reselect then
		local old = self.desired
		local desired = LodTree.select(
			pos.X,
			pos.Z,
			if teleport then nil else old,
			underground,
			if teleport then nil else self.underground
		)
		self.desired = desired
		self.selectedAt = pos
		self.lodVersion = version
		self.forceSelect = false
		local changed: { [number]: number } = {}
		local count = 0
		for key, level in desired do
			if old[key] == nil then
				changed[key] = level
				count += 1
			end
		end
		for key, level in old do
			if desired[key] == nil then
				changed[key] = level
				count += 1
			end
		end
		if count > 0 then
			selectionChanged = changed
			self.summariesChanged = true
			applySelection(self, changed, count, now)
			if self.trashHead <= #self.trashLater then
				-- (Old models of an earlier teleport the new selection reaches go now.)
				trashSome(self, true)
			end
		end
	end
	self.underground = underground
	if teleport then
		dropOldArea(self, pos)
		resetHorizon(self)
		if not self.teleport.active then
			self.renderer.overlay:pause()
			local callback = self.onTeleportMode
			if callback then
				callback(true)
			end
		end
		self.teleport:enter(now)
	end

	updateHorizon(self, now)
	updateHeld(self, skipWas and not self.skipHidden)
	prioritise(self)
	updateReveal(self, selectionChanged, now)
	if reselect then
		for _, node in self.nodes do
			updateFoliageNode(self, node)
		end
	else
		for node in self.foliageCheck do
			updateFoliageNode(self, node)
		end
	end
	table.clear(self.foliageCheck)
	self.remesh:invalidate()
	self.swapDue = true
end

--[[ Construction ]]

function ChunkStreamer.new(
	generator: TerrainGenerator.Generator,
	world: ClientWorld.ClientWorld,
	pool: WorkerPool.WorkerPool,
	renderer: ChunkRenderer.ChunkRenderer
): ChunkStreamer
	local revealMin, revealMax = ViewSettings.revealRadii()
	local self = (
		setmetatable({
			generator = generator,
			world = world,
			pool = pool,
			renderer = renderer,
			nodes = {},
			desired = {},
			desiredBelow = {},
			queue = {},
			waiting = {},
			retrying = {},
			meshQueue = {},
			unshown = {},
			leaving = {},
			shownBelow = {},
			counts = {},
			remesh = RemeshQueue.new({
				open = function()
					return renderer:openGroup()
				end,
				hold = function(group)
					renderer:holdGroup(group)
				end,
				close = function(group)
					renderer:closeGroup(group)
				end,
			}),
			sinceRefresh = math.huge,
			caveReach = CaveReach.tracker(revealMin, revealMax, SECTION, 2),
			revealMax = revealMax,
			tunnelReach = ViewSettings.revealReach(),
			caveView = nil,
			cave = CaveReach.view(Caves.RevealHold, Caves.RevealBudget),
			caveDirty = false,
			graphLookup = nil :: any,
			undergroundHold = CaveReach.hold(Config.Lod.UndergroundSeconds),
			underground = false,
			viewer = Vector3.zero,
			view = LoadPriority.view(0, 0, 0, 0, 70, 16 / 9),
			hidden = {},
			horizon = HiddenTerrain.new(),
			horizonJobId = nil,
			summariesChanged = false,
			verdictNew = false,
			skipHidden = false,
			held = {},
			eye = Vector3.zero,
			selectedAt = nil,
			lodVersion = LodTree.version(),
			forceSelect = false,
			refreshed = false,
			swapDue = false,
			revealed = {},
			revealCheck = {},
			capCheck = {},
			liveCheck = {},
			foliageCheck = {},
			teleport = TeleportMode.new(Streaming.TeleportTimeout, Streaming.TeleportSettle),
			teleportTarget = nil,
			trashLater = {},
			trashHead = 1,
			onTeleportMode = nil,
			busy = false,
		}, ChunkStreamer) :: any
	) :: ChunkStreamer

	self.hidden = self.horizon.hidden
	-- The search's view of the graphs: full detail chunks' buffers, false for those not generated
	-- yet, nil elsewhere (no caves).
	self.graphLookup = function(cx: number, cz: number): (buffer | false)?
		local key = Coords.chunkKey(cx, cz)
		if self.desired[key] == nil then
			return nil
		end
		local node = self.nodes[key]
		local graph = if node then node.graph else nil
		return graph or false
	end

	world.onSectionDirty = function(cx, cz, section)
		local node = self.nodes[Coords.chunkKey(cx, cz)]
		if node and node.chunk and section >= 0 and section < SECTIONS then
			self.remesh:mark(node, section, EDIT)
		end
	end

	-- An edit of a full detail chunk changes its Horizon summary (dug ground, built blocks).
	local P = ChunkLayout.PADDED
	world:onBlockChanged(function(x, y, z, block)
		local cx, cz, lx, lz = Coords.blockToChunk(x, z)
		local node = self.nodes[Coords.chunkKey(cx, cz)]
		local chunk = if node then node.chunk else nil
		local summary = if node then node.summary else nil
		if chunk and summary then
			local index = (y * P + lz + 1) * P + lx + 1
			if Horizon.applyEdits(summary, chunk.data, chunk.height, { index, block }, Blocks.cullLut) then
				self.summariesChanged = true
			end
		end
	end)

	world.onChunkTouched = function(cx, cz)
		local node = self.nodes[Coords.chunkKey(cx, cz)]
		if node and node.state == "working" then
			-- The generation job was sent before this edit; its result is patched (onGenerated).
			node.stale = true
		end
	end

	return self
end

--[[ Public ]]

function ChunkStreamer.update(self: ChunkStreamer, dt: number)
	local now = os.clock()
	self.sinceRefresh += dt
	if self.teleportTarget or self.sinceRefresh >= Streaming.UpdateInterval then
		self.sinceRefresh = 0
		refresh(self, now)
	end

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
	for node in self.retrying do
		if now >= node.retryAt then
			self.retrying[node] = nil
			if node.meshOnly then
				setState(self, node, "meshing")
				table.insert(self.meshQueue, node)
			else
				enqueue(self, node)
			end
		end
	end

	dispatch(self, now)
	self.world:flush()
	if self.trashHead <= #self.trashLater then
		trashSome(self)
	end
	if self.swapDue then
		swap(self, now)
	end
	self.renderer:step(dt)

	-- Far meshes wait while there is much to load; teleport mode ends once the ground is there.
	local counts = self.counts
	local loading = (counts.waiting or 0) + (counts.queued or 0) + (counts.working or 0) + (counts.meshing or 0)
	local pending = self.renderer:pending()
	local busy = self.teleport.active or loading > Streaming.BusyJobs or pending > Streaming.BusyBuilds
	if busy ~= self.busy then
		self.busy = busy
		self.renderer.overlay:setStreamerBusy(busy)
	end
	if self.teleport.active then
		local viewer = self.viewer
		if self.teleport:update(now, self:isReady(math.floor(viewer.X), math.floor(viewer.Z)), loading + pending) then
			self.renderer.overlay:resume()
			local callback = self.onTeleportMode
			if callback then
				callback(false)
			end
		end
	end
end

--[[
	MovementController's teleport handler: the character was put at `feet` (blocks). The streamer
	selects there in this frame; further than Streaming.TeleportDistance it drops the old area
	(teleport mode).
]]
function ChunkStreamer.teleported(self: ChunkStreamer, feet: Vector3)
	self.teleportTarget = feet
end

-- The player is frozen waiting for terrain: the renderer may build longer per frame.
function ChunkStreamer.setFrozen(self: ChunkStreamer, frozen: boolean)
	if self.renderer.frozen ~= frozen then
		self.renderer:setFrozen(frozen)
	end
end

--[[
	The view settings changed (Settings effects "lod", "caves", "foliage"): LodTree's four
	distances, plants, the cave view's tunnel reach and open-space radii from ViewSettings, then a
	refresh this frame (the search runs again). "Skip hidden terrain" needs no call: it is read at
	every refresh.
]]
function ChunkStreamer.applyView(self: ChunkStreamer)
	ViewSettings.applyLod()
	local revealMin, revealMax = ViewSettings.revealRadii()
	self.caveReach = CaveReach.tracker(revealMin, revealMax, SECTION, 2)
	self.revealMax = revealMax
	self.tunnelReach = ViewSettings.revealReach()
	self.caveDirty = true
	self.forceSelect = true
	self.sinceRefresh = math.huge
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
	local counts = self.counts
	local stats: Stats = {
		nodes = {},
		waiting = counts.waiting or 0,
		queued = counts.queued or 0,
		working = (counts.working or 0) + (counts.meshing or 0),
		building = self.renderer:pending(),
		busyWorkers = self.pool:busy(),
		revealRadius = if self.caveView then (self.caveView :: CaveView).reach else 0,
		underground = self.underground,
		revealed = self.cave.count,
		reached = self.cave.reached,
		searchMs = self.cave.searchMs,
		hidden = self.horizon.count,
		held = 0,
		failed = counts.failed or 0,
		meshing = counts.meshing or 0,
		remeshing = self.remesh:pending(),
		teleporting = self.teleport.active,
		trashParts = self.renderer:trashParts(),
	}
	for _, node in self.nodes do
		stats.nodes[node.level] = (stats.nodes[node.level] or 0) + 1
	end
	for _ in self.held do
		stats.held += 1
	end
	return stats
end

return ChunkStreamer
