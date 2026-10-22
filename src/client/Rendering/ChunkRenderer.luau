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
	the build budget. Looks come from Rendering/TextureLooks; when they change (the Textures or Far
	Materials setting, texture averages measured, ids that failed: its `changed` signal) every
	section whose parts carry an older look is rebuilt off-screen in the background lane and
	swapped like any other build: a record keeps the look generation its parts were made with
	(PartPool: the plain one in plain far levels, the part one elsewhere) and whether it was drawn
	plain, so a section is rebuilt only when either differs from now (plain levels keep their parts
	when only the near looks changed; Far Materials flips merged levels between plain and full
	look). Only where no build waits to start (which uses the new look anyway); any newer build
	replaces a restyle (RenderSchedule), so an edit never waits behind one. The far meshes get the
	new looks (MeshOverlay:setLooks) and merge a node only once its records are current
	(`overlay.isCurrent`); when the overlay drops Far Materials on its own (its startup probe could
	not build a mesh in a look: `overlay.onLooks`), the merged levels are rebuilt plain the same way.

	Render.SwapPartsPerFrame is one allowance per frame for the streamer's level of detail swaps
	and MeshOverlay's: `show` counts the parts it puts into the workspace, and the overlay gets
	what is left at the next step.

	Shaped blocks (torches, lanterns: BlockList `shape`) come out of the mesher one cell per box
	(Blocks.singleLut); each becomes one part per shape box, sized and placed from the shape (in
	pixels, 1/16 of a cell) and turned by the box's rotation. PartPool keeps a template per box,
	the glowing one carrying the block's PointLight.

	Sparse lights (glow lichen and lava: GreedyMesher.sparseLightLut) carry their PointLight only
	where the mesher marked the cell (lichen: surface field 1, one per GreedyMesher.LIGHT_BOX box;
	lava: FLUID_LIT on its height, one per FLUID_LIGHT_BOX box, GreedyMesher.fluidSurface); the
	other cells get PartPool's dark template for the light's box (a lava box: its whole part). A
	revealed cavern holds a few hundred, all on by default; a finite Caves.LichenLightDistance
	(lichen) or Caves.LavaLightDistance (lava) switches off those farther from the camera
	(ViewSettings; every SPARSE_SWEEP seconds, off again SPARSE_HYSTERESIS blocks further). Lichen
	and lava whose light is off still glow: both are Neon.

	Plants (Blocks.appearances `scatter`, `tinted`) are shaped blocks too:
	  * scattered ones are drawn off their cell's centre and turned about its vertical axis
	    (Meshing/Scatter.at, from the world block position: the node's origin plus the cell); each
	    box goes to the cell's centre plus the offset, turned by the yaw, then by its own rotation;
	  * tinted ones (grass, ferns) take their soil's foliage colour, which the mesher packs into
	    the box key (GreedyMesher.decodeKey's surface field): every box's colour times
	    Blocks.FOLIAGE_TINTS[tint], clamped. Their parts' colour is always set, tint or none,
	    because a pooled part may come back from a cell with another tint;
	  * with a sprite (TextureLooks.spriteOf: a filled Sprite texture, Textures and Config.Textures.
	    Sprites on) a plant's cell is drawn in full detail as two crossed planes along its
	    diagonals instead of its boxes (BlockSize x sqrt 2 wide, a cell tall, PartPool.SPRITE_BOX),
	    placed and turned like the boxes; tinted ones get their soil's tint on the planes' Decals
	    (written only when the part's tint differs: `spriteTints`). Their Bounds still aim and
	    outline them. Rope, cobwebs and hanging roots draw their sprites the same way.
	Shaped blocks build only the boxes TextureLooks.drawnBoxes names: with a Front image drawn
	(ladders, rails, vines, glow lichen) the plate carrying it and the glowing boxes, so the picture
	replaces the rails and rungs; without one every box but a fully see-through plate (the
	ladder's image carrier).

	The floating origin (Shared/World/Origin, Rendering/Rebase): parts are placed at world studs
	minus the render origin. A build takes the origin when it starts (`Build.ox/oz`; its
	`originX/originZ` are the node's corner in that frame, exact doubles) and every node records
	the origin its parts are placed for (`NodeState.ox/oz`). The renderer's Rebase mover
	("terrain") moves, in the one BulkMoveTo of a move, only what is in the workspace: the live
	parts of nodes whose model is parented, retiring models, folders and lists still parented,
	trashed models still there, and the far meshes (MeshOverlay.gather); the sparse lights' cached
	positions follow. What is out of the workspace is fixed when it goes in (the lazy rule: a part
	goes into the workspace only placed for the current origin):
	  * a build's new parts (out of the workspace until the commit) are moved to their node's
	    origin just before the commit parents them (plain CFrame writes);
	  * a node model shown again (`show`, or the far meshes putting it back: overlay.settle) after
	    the origin moved is moved by (its origin - the current one) with one BulkMoveTo right
	    after it is parented, in the same Luau step (BulkMoveTo outside a WorldRoot is
	    undocumented).
	So a move costs only the parts on screen; the tens of thousands kept out of the workspace under
	far meshes are fixed a node at a time when they come back. With Config.Origin off the origin
	stays 0 and none of this moves a part.

	Seasons (Shared/Seasons/Foliage, driven by Rendering/SeasonTint; `season` is nil until it calls
	`setSeasonClass` or `setSeason`, so with Config.Seasons off none of this runs and every colour
	is the template's). Grass tops, leaves, tinted plants and vines change colour in place, never
	their materials, variants or images (ARCHITECTURE's rule):
	  * a palette (`setSeason(targets)`: each seasonal appearance's colour per biome class) is
	    kept per class and appearance with the generation it came in (`since`); a colour within
	    TARGET_SLACK of the one in effect is not a change, and a palette with no change starts
	    nothing. Colours become paints (part Color, image and Decal Color3s per drawn mode, shape
	    box and soil tint) through TextureLooks.seasonalTint, cached per class until the next
	    palette or a change of looks;
	  * the biome class is per chunk column, at every level: a box takes the class of the chunk
	    its centre stands on (a far node spanning several classes paints each of its chunks
	    with its own, as its children will), asked of `setSeasonClass`'s function once and kept
	    in a direct-mapped cache of CLASS_SIDE x CLASS_SIDE columns (a 4096-block view with its
	    farthest nodes fits, 1.3 MB, made with the first class asked);
	  * every record keeps each part's palette generation (`tone`, parallel to its parts, moved
	    with the parts a diff keeps and refreshed from the old record when it commits) and the
	    oldest among its seasonal parts (`painted`; math.huge without any);
	  * new and pooled parts are painted as they are built (the tinted plants' rule extended),
	    once some palette other than the authored one was applied (`dirty`; until then nothing
	    is written, exactly as without seasons);
	  * a palette with changes starts a sweep (`seasonSweep(writes, ms)`, every frame from
	    SeasonTint) over the nodes that may hold seasonal parts (`holders`: every node when the
	    seasons start, then those a record with seasonal parts commits in; one whose records
	    hold none leaves when the sweep passes it): their list is copied at the start and ranked
	    a few at a time into rings of RING_STUDS by distance from the camera, each ring sorted
	    (numbers, no comparator) when the walk reaches it, so the nodes nearest the camera come
	    first and nothing costs a long frame. Every live record of each, re-read from the node's
	    state every frame, so a part not live in a record (retiring, released, in the pool's
	    quarantine) is never touched. A part whose tone is older than its colour's `since` is
	    written (once: its tone says it is current), a newer one only takes the new tone; at
	    most `writes` property writes and `ms` a frame, the ranking, the walk over nodes and
	    sections and the classes asked included, nothing allocated (the rings are kept). Records
	    committed with parts of an older palette after the sweep passed them are swept last;
	    records of an older look are left to the restyle that rebuilds them (and paints them);
	  * far meshes take the far palette (`setFarSeason`): MeshOverlay colours their seasonal
	    quads per chunk column's class (the same cache) and rebuilds a mesh whose palette
	    drifted too far.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GreedyMesher = require(Shared.Meshing.GreedyMesher)
local Scatter = require(Shared.Meshing.Scatter)
local ChunkLayout = require(Shared.World.ChunkLayout)
local Coords = require(Shared.World.Coords)
local LodTree = require(Shared.World.LodTree)
local Origin = require(Shared.World.Origin)
local Blocks = require(Shared.Blocks)
local Foliage = require(Shared.Seasons.Foliage)

local PartPool = require(script.Parent.PartPool)
local Rebase = require(script.Parent.Rebase)
local MeshOverlay = require(script.Parent.MeshOverlay)
local TextureLooks = require(script.Parent.TextureLooks)
local ViewSettings = require(script.Parent.ViewSettings)
local SectionDiff = require(script.Parent.SectionDiff)
local RenderSchedule = require(script.Parent.RenderSchedule)
local FrameBudget = require(script.Parent.FrameBudget)

local BOX = GreedyMesher.BOX_BYTES
local FLUID_FULL = Blocks.FLUID_FULL
local LAYER_LUT = Blocks.layerLut
local MAX_LEVEL = LodTree.MAX_LEVEL
local readu16 = buffer.readu16
local Render = Config.Render
-- Longest side of a part in studs (engine limit).
local MAX_PART = 2048
-- Sparse lights (glow lichen, lava) near the camera are on: checked this often (seconds), and one
-- that is on goes off this many blocks beyond the distance.
local SPARSE_SWEEP = 0.25
local SPARSE_HYSTERESIS = 8
-- A commit group open longer than this (seconds) stops waiting for its missing tasks.
local GROUP_TIMEOUT = 2
-- Sprite planes: one along each diagonal of the cell.
local SPRITE_BOX = PartPool.SPRITE_BOX
local SPRITE_TURNS = { CFrame.Angles(0, math.pi / 4, 0), CFrame.Angles(0, -math.pi / 4, 0) }
local SQRT2 = math.sqrt(2)
-- Seasons (see the header): what a part is drawn as (near, far, plain), the box slots a paint
-- key tells apart (0 a cube, 1.. a shape's boxes, SPRITE_BOX a sprite plane) and the soil tints.
local NEAR_MODE, FAR_MODE, PLAIN_MODE = 0, 1, 2
local BOX_SLOTS = SPRITE_BOX + 1
local TINT_SLOTS = 65
local SEASONAL = Foliage.kindLut
local FOLIAGE_TINT_COUNT = #Blocks.FOLIAGE_TINTS

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
	-- The look generation the parts were made with (PartPool.generationOf), and whether they were
	-- drawn plain (MeshOverlay.plainLevel).
	texture: number,
	plain: boolean,
	-- Seasons: the palette generation each part's colour is (parallel to `parts`; 0: its
	-- template's; nil: all 0), and the oldest one among its seasonal parts.
	tone: { number }?,
	painted: number,
}

type NodeState = {
	records: { [number]: Record },
	-- Parts in live records.
	parts: number,
	-- The render origin (world studs) everything in the node's model is placed for: the current
	-- one while the model is in the workspace (see the header).
	ox: number,
	oz: number,
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
	-- Placement: the render origin when the build started (world studs) and the node's corner in
	-- that frame (studs).
	ox: number,
	oz: number,
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
	-- Seasons: each part's palette generation (parallel to `parts`, nil without seasons) and the
	-- oldest one a seasonal part got.
	tone: { number }?,
	minTone: number,
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

-- (`lava`: a lit fluid's, which follows the lava light distance; `position`: render studs for the
-- current origin, wherever the part is now.)
type SparseEntry = { light: PointLight, position: Vector3, on: boolean, lava: boolean }

type WalkEntry = { node: RenderNode, section: number }

--[[
	A paint: what one seasonal part is written with for a palette and biome class
	(TextureLooks.seasonalTint): its Color (nil: unchanged) and its images' Color3 in PartPool.images
	order (false: unchanged), the property writes that costs, and an id unique among paints (sprite
	planes remember theirs in `spriteTints`).
]]
type Paint = {
	color: Color3?,
	images: { Color3 | false }?,
	writes: number,
	id: number,
}

-- The seasons' state (see the header; nil until Rendering/SeasonTint calls setSeason).
type Season = {
	-- Per biome class and appearance: the colour in effect (nil: the authored one) and the
	-- palette generation it came in with (a part whose tone is at least that shows it).
	applied: { { [number]: Foliage.Rgb } },
	since: { { [number]: number } },
	-- The palette generation: bumped whenever some colour changes.
	gen: number,
	-- Some part may show other than its template's colour (a palette other than the authored one
	-- was applied): from then on every seasonal part is painted when built.
	dirty: boolean,
	-- The biome class of a chunk column (setSeasonClass's function), and the classes asked so far
	-- (`chunkClass`; nil until the first).
	classAt: (cx: number, cz: number) -> number,
	classes: buffer?,
	-- Per class index: TextureLooks.seasonalTint per appearance, and paints by paint key.
	tints: { { [number]: TextureLooks.Seasonal } },
	paints: { { [number]: Paint } },
	nextPaint: number,
	-- Nodes that may hold seasonal parts, and each one's index in the list.
	holders: { RenderNode },
	holderAt: { [RenderNode]: number },
	-- The sweep: the holders when it started (`order`), how many of them are ranked, where the
	-- camera stood then (world studs), the rings (keys: distance x 8 x KEY_SPAN + order index;
	-- `ringTop` the farthest one used) and the ring walked and the next key in it; the node
	-- being swept and its sections, the record being painted and where (box, part index).
	sweeping: boolean,
	order: { RenderNode },
	ranked: number,
	fromX: number,
	fromZ: number,
	rings: { { number } },
	ringTop: number,
	ring: number,
	ringIndex: number,
	node: RenderNode?,
	sections: { number },
	sectionIndex: number,
	record: Record?,
	box: number,
	part: number,
	-- The record comes from the late list; it holds seasonal parts.
	fromLate: boolean,
	seen: boolean,
	-- Sections committed with parts of an older palette (swept after the order).
	lateNodes: { RenderNode },
	lateSections: { number },
	lateIndex: number,
	-- This sweep's writes and frames, the last finished sweep's, and sweeps finished.
	writes: number,
	frames: number,
	lastWrites: number,
	lastFrames: number,
	sweeps: number,
}

-- The seasons' figures (F3): palette generation, whether a sweep runs and its writes and frames
-- so far, the last sweep's, sweeps finished, sections waiting after the order.
export type SeasonStats = {
	gen: number,
	sweeping: boolean,
	writes: number,
	frames: number,
	lastWrites: number,
	lastFrames: number,
	sweeps: number,
	late: number,
}

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
	-- The PointLights of sparse lights (glow lichen, lava) by their part, with where they are
	-- (studs); how many there are and how many are on (near the camera), and of those lava's.
	sparseLights: { [BasePart]: SparseEntry },
	sparseCount: number,
	sparseOn: number,
	lavaCount: number,
	lavaOn: number,
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
	-- The soil tint each tinted sprite plane's Decals carry (weak; seasons: the paint's id, < 0).
	spriteTints: { [BasePart]: number },
	-- Seasonal foliage colours (nil until setSeason).
	season: Season?,

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
	setSeason: (self: ChunkRenderer, targets: Foliage.Targets?) -> boolean,
	setSeasonClass: (self: ChunkRenderer, classAt: (cx: number, cz: number) -> number) -> (),
	setFarSeason: (self: ChunkRenderer, targets: Foliage.Targets?, id: number) -> (),
	seasonSweep: (self: ChunkRenderer, writes: number, ms: number) -> (number, boolean),
	seasonStats: (self: ChunkRenderer) -> SeasonStats,
}

local ChunkRenderer = {}
ChunkRenderer.__index = ChunkRenderer

-- (Below: the look of a node now, and what a change of looks rebuilds; the origin's moves.)
local isCurrent: (self: ChunkRenderer, node: RenderNode) -> boolean
local looksChanged: (self: ChunkRenderer, changes: TextureLooks.Changes) -> ()
local settle: (self: ChunkRenderer, node: RenderNode) -> ()
local gather: (self: ChunkRenderer, dx: number, dz: number, parts: { BasePart }, cframes: { CFrame }) -> ()

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
		lavaCount = 0,
		lavaOn = 0,
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
		spriteTints = setmetatable({}, { __mode = "k" }) :: any,
		season = nil,
	}
	local renderer = (setmetatable(self, ChunkRenderer) :: any) :: ChunkRenderer
	-- The overlay budgets hiding and showing nodes by their parts, and merges a node only once its
	-- parts carry the current look.
	renderer.overlay.countParts = function(node: any): number
		return renderer:partsOf(node)
	end
	renderer.overlay.isCurrent = function(node: any): boolean
		return isCurrent(renderer, node)
	end
	-- (The overlay dropped Far Materials on its own: merged levels are plain again.)
	renderer.overlay.onLooks = function()
		looksChanged(renderer, { parts = false, plain = false, meshes = false, items = false })
	end
	renderer.overlay:setLooks(
		TextureLooks.farMaterials(),
		TextureLooks.lookOf,
		TextureLooks.lookInfo,
		TextureLooks.plainRgb
	)
	TextureLooks.changed:Connect(function(changes: TextureLooks.Changes)
		looksChanged(renderer, changes)
	end)
	-- The floating origin (see the header): what is on screen moves with it, models the far
	-- meshes put back are placed for it.
	renderer.overlay.settle = function(node: any)
		settle(renderer, node)
	end
	Rebase.register("terrain", function(dx: number, dz: number, parts: { BasePart }, cframes: { CFrame })
		gather(renderer, dx, dz, parts, cframes)
	end)
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
		-- (Nothing in it yet: placed for the origin now.)
		state = { records = {}, parts = 0, ox = Origin.x, oz = Origin.z }
		self.states[node] = state
	end
	return state :: NodeState
end

local function nodeKey(level: number, nx: number, nz: number): number
	return Coords.nodeKey(level, nx, nz)
end

--[[ Lights ]]

-- Is a sparse light `distance` studs from the camera on (`on`: it is now; `lava`: a lit fluid's)?
local function sparseWanted(distance: number, on: boolean, lava: boolean): boolean
	local limit = if lava then ViewSettings.lavaLightDistance() else ViewSettings.lichenLightDistance()
	local reach = (limit + (if on then SPARSE_HYSTERESIS else 0)) * Config.BlockSize
	return distance < reach
end

-- A part with a light was built by `b`: its light on (sparse lights: when near the camera; `lava`:
-- a lit fluid's).
local function lightOn(self: ChunkRenderer, b: Build, part: BasePart, sparse: boolean, lava: boolean)
	self.lightCount += 1
	local light = self.pool:light(part)
	if light == nil then
		return
	end
	if not sparse then
		light.Enabled = true
		return
	end
	-- (Where it shows for the current origin: the build may have started before the last move.)
	local position = part.Position
	if b.ox ~= Origin.x or b.oz ~= Origin.z then
		position += Vector3.new(b.ox - Origin.x, 0, b.oz - Origin.z)
	end
	local on = sparseWanted((position - workspace.CurrentCamera.CFrame.Position).Magnitude, false, lava)
	light.Enabled = on
	self.sparseLights[part] = { light = light, position = position, on = on, lava = lava }
	self.sparseCount += 1
	if lava then
		self.lavaCount += 1
	end
	if on then
		self.sparseOn += 1
		if lava then
			self.lavaOn += 1
		end
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
		if entry.lava then
			self.lavaCount -= 1
		end
		if entry.on then
			self.sparseOn -= 1
			if entry.lava then
				self.lavaOn -= 1
			end
		end
	end
end

-- Switches sparse lights on near the camera and off far from it.
local function sweepSparse(self: ChunkRenderer)
	local camera = workspace.CurrentCamera.CFrame.Position
	local count, lava = 0, 0
	for _, entry in self.sparseLights do
		local was = entry.on
		local on = sparseWanted((entry.position - camera).Magnitude, was, entry.lava)
		if on ~= was then
			entry.on = on
			entry.light.Enabled = on
		end
		if on then
			count += 1
			if entry.lava then
				lava += 1
			end
		end
	end
	self.sparseOn = count
	self.lavaOn = lava
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

--[[ Seasons (see the header) ]]

local decodeKey = GreedyMesher.decodeKey
local NO_BOXES: { number } = {}
local CHUNK = Config.ChunkSize
-- Target colours closer than this (0..255, every channel) count as unchanged: no new palette.
local TARGET_SLACK = 0.25
-- The sweep looks at the clock every this many parts it paints, and every this many steps of its
-- walk (a node ranked, a node's sections listed, a record passed).
local CLOCK_EVERY = 8
local WALK_EVERY = 16
-- The chunk classes' cache (see the header): CLASS_SIDE x CLASS_SIDE slots of a u32 each (the
-- column's tag x 256 + its class; 0: empty), a slot per column modulo CLASS_SIDE, so a view up to
-- 4096 blocks (256 chunks each way, plus a far node) never puts two columns in one.
local CLASS_SIDE = 576
local CLASS_TAGS = 4096
-- The sweep's rings (studs wide, the last one holding everything farther) and its keys' room
-- for the order index (see Season).
local RING_STUDS = CHUNK * Config.BlockSize
local MAX_RING = 1024
local KEY_SPAN = 2 ^ 21

--[[
	The biome class (Foliage.classIndex) of chunk column (cx, cz), from the cache or asked of
	`classAt` (then kept), and whether it was asked (a generator column: a caller on a budget looks
	at the clock).
]]
local function chunkClass(season: Season, cx: number, cz: number): (number, boolean)
	local cache = season.classes
	if cache == nil then
		cache = buffer.create(CLASS_SIDE * CLASS_SIDE * 4)
		season.classes = cache
	end
	local slot = ((cx % CLASS_SIDE) * CLASS_SIDE + cz % CLASS_SIDE) * 4
	local tag = ((cx // CLASS_SIDE) % CLASS_TAGS) * CLASS_TAGS + (cz // CLASS_SIDE) % CLASS_TAGS
	local entry = buffer.readu32(cache :: buffer, slot)
	if entry ~= 0 and entry // 256 == tag then
		return entry % 256, false
	end
	local class = season.classAt(cx, cz)
	buffer.writeu32(cache :: buffer, slot, tag * 256 + class)
	return class, true
end

-- The chunk column the centre of box `o` (byte offset) of a node of `step` stands on.
local function chunkOf(node: RenderNode, step: number, boxes: buffer, o: number): (number, number)
	local x = node.nx * CHUNK + readu16(boxes, o) + readu16(boxes, o + 6) * 0.5
	local z = node.nz * CHUNK + readu16(boxes, o + 4) + readu16(boxes, o + 10) * 0.5
	return math.floor(x * step / CHUNK), math.floor(z * step / CHUNK)
end

-- A node may hold seasonal parts: the sweeps visit it (see the header).
local function addHolder(season: Season, node: RenderNode)
	if season.holderAt[node] == nil then
		table.insert(season.holders, node)
		season.holderAt[node] = #season.holders
	end
end

local function removeHolder(season: Season, node: RenderNode)
	local at = season.holderAt[node]
	if at == nil then
		return
	end
	local list = season.holders
	local last = list[#list]
	list[at] = last
	season.holderAt[last] = at
	list[#list] = nil
	season.holderAt[node] = nil
end

-- TextureLooks.seasonalTint of `appearance` in class `class` for the palette now (cached).
local function seasonalTint(season: Season, class: number, appearance: number): TextureLooks.Seasonal
	local byClass = season.tints[class]
	if byClass == nil then
		byClass = {}
		season.tints[class] = byClass
	end
	local tint = byClass[appearance]
	if tint == nil then
		local applied = season.applied[class]
		tint = TextureLooks.seasonalTint(appearance, if applied then applied[appearance] else nil)
		byClass[appearance] = tint
	end
	return tint :: TextureLooks.Seasonal
end

-- The paint of a part: box `slot` (0 a cube, SPRITE_BOX a sprite plane) of `appearance`, drawn
-- `mode`, on soil tint `tint` (1: none), in biome class `class`.
local function makePaint(
	season: Season,
	class: number,
	appearance: number,
	slot: number,
	mode: number,
	tint: number
): Paint
	local seasonal = seasonalTint(season, class, appearance)
	local color: Color3? = nil
	local images: { Color3 | false }? = nil
	if slot == 0 then
		if mode == NEAR_MODE then
			color = seasonal.near
			for _, image in seasonal.images do
				if image then
					images = seasonal.images
					break
				end
			end
		elseif mode == FAR_MODE then
			color = seasonal.far
		else
			color = seasonal.plain
		end
	elseif slot == SPRITE_BOX then
		local sprite = seasonal.sprite
		if sprite then
			local c = sprite[tint] or sprite[1]
			images = { c, c }
		end
	else
		local shape = Blocks.appearances[appearance].shape
		local front = seasonal.front
		if front and mode ~= PLAIN_MODE and shape and slot == TextureLooks.plateBox(shape) then
			-- (A Front plate is see-through: its image is what shows, on both sides for a door.)
			images = { front, front }
		else
			local boxes = seasonal.boxes
			local colours = if boxes then boxes[slot] else nil
			if colours then
				color = colours[tint] or colours[1]
			end
		end
	end
	local writes = if color then 1 else 0
	if images then
		for _, c in images do
			if c then
				writes += 1
			end
		end
	end
	season.nextPaint -= 1
	return { color = color, images = images, writes = writes, id = season.nextPaint }
end

local function paintFor(
	self: ChunkRenderer,
	class: number,
	appearance: number,
	slot: number,
	mode: number,
	tint: number
): Paint
	local season = self.season :: Season
	local byClass = season.paints[class]
	if byClass == nil then
		byClass = {}
		season.paints[class] = byClass
	end
	local key = ((appearance * BOX_SLOTS + slot) * 3 + mode) * TINT_SLOTS + tint
	local paint = byClass[key]
	if paint == nil then
		paint = makePaint(season, class, appearance, slot, mode, tint)
		byClass[key] = paint
	end
	return paint :: Paint
end

-- Writes a paint on a part (its images through PartPool.images); returns the writes.
local function applyPaint(pool: PartPool.PartPool, part: BasePart, paint: Paint): number
	local writes = 0
	local color = paint.color
	if color then
		part.Color = color
		writes = 1
	end
	local list = paint.images
	if list then
		local images = pool:images(part)
		if images then
			for i, c in list do
				if c then
					local image = images[i]
					if image then
						image.Color3 = c :: Color3
						writes += 1
					end
				end
			end
		end
	end
	return writes
end

local function newSeason(): Season
	return {
		applied = {},
		since = {},
		gen = 0,
		dirty = false,
		classAt = function(_cx: number, _cz: number): number
			return Foliage.TEMPERATE
		end,
		classes = nil,
		tints = {},
		paints = {},
		nextPaint = 0,
		holders = {},
		holderAt = {},
		sweeping = false,
		order = {},
		ranked = 0,
		fromX = 0,
		fromZ = 0,
		rings = {},
		ringTop = 0,
		ring = 0,
		ringIndex = 1,
		node = nil,
		sections = {},
		sectionIndex = 1,
		record = nil,
		box = 0,
		part = 0,
		fromLate = false,
		seen = false,
		lateNodes = {},
		lateSections = {},
		lateIndex = 1,
		writes = 0,
		frames = 0,
		lastWrites = 0,
		lastFrames = 0,
		sweeps = 0,
	}
end

--[[
	Takes a palette's colours into `season.applied` where they differ from the ones in effect by
	more than TARGET_SLACK (nil: the authored colours), with generation `gen` in `season.since`.
	Returns whether any changed, and whether any is other than authored now.
]]
local function applyTargets(season: Season, targets: Foliage.Targets?, gen: number): (boolean, boolean)
	local changed, seasonal = false, false
	for class in Foliage.CLASSES do
		local applied = season.applied[class]
		if applied == nil then
			applied = {}
			season.applied[class] = applied
			season.since[class] = {}
		end
		local since = season.since[class] :: { [number]: number }
		local colours = if targets then targets.colours[class] else nil
		for _, appearance in Foliage.appearances() do
			local new = if colours then colours[appearance] else nil
			local old = applied[appearance]
			local a = old or Foliage.authored(appearance) :: Foliage.Rgb
			local b = new or Foliage.authored(appearance) :: Foliage.Rgb
			if
				math.abs(a[1] - b[1]) <= TARGET_SLACK
				and math.abs(a[2] - b[2]) <= TARGET_SLACK
				and math.abs(a[3] - b[3]) <= TARGET_SLACK
			then
				if old then
					seasonal = true
				end
				continue
			end
			changed = true
			since[appearance] = gen
			if new then
				applied[appearance] = { new[1], new[2], new[3] }
				seasonal = true
			else
				applied[appearance] = nil
			end
		end
	end
	return changed, seasonal
end

local function copyTargets(t: Foliage.Targets): Foliage.Targets
	local colours = {}
	for class, list in t.colours do
		local copy = {}
		for appearance, c in list do
			copy[appearance] = { c[1], c[2], c[3] }
		end
		colours[class] = copy
	end
	return { time = t.time, p = t.p, covers = table.clone(t.covers), colours = colours }
end

-- Starts a sweep over the holders' live sections, nearest node first (see the header).
local function startSweep(season: Season)
	local order = season.order
	table.clear(order)
	table.move(season.holders, 1, #season.holders, 1, order)
	season.ranked = 0
	local camera = workspace.CurrentCamera
	local cx, cz = 0, 0
	if camera then
		local position = camera.CFrame.Position
		cx, cz = position.X, position.Z
	end
	season.fromX, season.fromZ = cx + Origin.x, cz + Origin.z
	for r = 1, season.ringTop do
		local ring = season.rings[r]
		if ring then
			table.clear(ring)
		end
	end
	season.ringTop = 0
	season.ring = 0
	season.ringIndex = 1
	season.node = nil
	table.clear(season.sections)
	season.sectionIndex = 1
	season.record = nil
	season.box = 0
	season.part = 0
	table.clear(season.lateNodes)
	table.clear(season.lateSections)
	season.lateIndex = 1
	season.writes = 0
	season.frames = 0
	season.sweeping = true
end

--[[
	A record was committed: its node holds seasonal parts when the record does, and one with parts
	of an older palette is swept after the order (see the header).
]]
local function lateRecord(self: ChunkRenderer, node: RenderNode, section: number, record: Record)
	local season = self.season
	if season == nil then
		return
	end
	if record.painted ~= math.huge then
		addHolder(season, node)
	end
	if record.painted < season.gen then
		table.insert(season.lateNodes, node)
		table.insert(season.lateSections, section)
		if not season.sweeping then
			season.sweeping = true
			season.writes = 0
			season.frames = 0
		end
	end
end

--[[
	The record the sweep is at (moving past what is current), or nil when it is done; `advance`
	moves past it. Ranks the order into rings first, then walks them nearest first (see the
	header). Looks at the clock every WALK_EVERY steps: past `deadline`, nil and true.
]]
local function sweepRecord(self: ChunkRenderer, season: Season, deadline: number): (RenderNode?, Record?, boolean)
	local gen = season.gen
	local steps = 0
	while true do
		steps += 1
		if steps >= WALK_EVERY then
			steps = 0
			if os.clock() > deadline then
				return nil, nil, true
			end
		end
		local node = season.node
		local ring = season.rings[season.ring]
		if node then
			local state = self.states[node]
			local index = season.sectionIndex
			if state and index <= #season.sections then
				local record = state.records[season.sections[index]]
				if record and record.painted < gen then
					season.fromLate = false
					return node, record, false
				end
				season.sectionIndex = index + 1
			else
				if state then
					-- (Its records hold no seasonal part: no sweep visits it until one commits.)
					local bare = true
					for _, record in state.records do
						if record.painted ~= math.huge then
							bare = false
							break
						end
					end
					if bare then
						removeHolder(season, node)
					end
				end
				season.node = nil
			end
		elseif season.ranked < #season.order then
			-- The next node into the ring of its distance from where the camera stood.
			local i = season.ranked + 1
			season.ranked = i
			local ranked = season.order[i]
			local size = CHUNK * ChunkLayout.steps(ranked.level) * Config.BlockSize
			local dx = (ranked.nx + 0.5) * size - season.fromX
			local dz = (ranked.nz + 0.5) * size - season.fromZ
			local distance = math.sqrt(dx * dx + dz * dz)
			local r = math.min(distance // RING_STUDS, MAX_RING) + 1
			local list = season.rings[r]
			if list == nil then
				list = {}
				season.rings[r] = list
			end
			table.insert(list, math.floor(distance * 8) * KEY_SPAN + i)
			if r > season.ringTop then
				season.ringTop = r
			end
		elseif ring and season.ringIndex <= #ring then
			local key = ring[season.ringIndex]
			season.ringIndex += 1
			local nextNode = season.order[key % KEY_SPAN]
			local state = self.states[nextNode]
			if state then
				local sections = season.sections
				table.clear(sections)
				for section in state.records do
					table.insert(sections, section)
				end
				season.node = nextNode
				season.sectionIndex = 1
			end
		elseif season.ring < season.ringTop then
			-- The next ring, its nodes nearest first (numbers: no comparator).
			season.ring += 1
			season.ringIndex = 1
			local list = season.rings[season.ring]
			if list and #list > 1 then
				table.sort(list)
			end
		elseif season.lateIndex <= #season.lateNodes then
			local i = season.lateIndex
			local lateNode = season.lateNodes[i]
			local state = self.states[lateNode]
			local record = if state then state.records[season.lateSections[i]] else nil
			if record and record.painted < gen then
				season.fromLate = true
				return lateNode, record, false
			end
			season.lateIndex = i + 1
		else
			return nil, nil, false
		end
	end
end

-- The sweep moves past the record `sweepRecord` gave.
local function advance(season: Season)
	if season.fromLate then
		season.lateIndex += 1
	else
		season.sectionIndex += 1
	end
	season.record = nil
	season.box = 0
	season.part = 0
	season.seen = false
end

--[[
	Paints a record's seasonal parts that are not current, from the sweep's cursor, until `limit`
	writes are done or the clock passes `deadline`. Returns the writes done and whether the record
	is done.
]]
local function paintRecord(
	self: ChunkRenderer,
	season: Season,
	node: RenderNode,
	record: Record,
	done: number,
	limit: number,
	deadline: number
): (number, boolean)
	local pool = self.pool
	if record.texture ~= pool:generationOf(record.plain) then
		-- (Built in an older look: the restyle rebuilding it paints its parts as it builds them.)
		return done, true
	end
	if season.record ~= record then
		-- (A record replaced since the last frame starts over: its parts' tones say what is left.)
		season.record = record
		season.box = 0
		season.part = 0
		season.seen = false
	end
	local gen = season.gen
	local step = ChunkLayout.steps(node.level)
	local far = node.level > 0
	local mode = if not far then NEAR_MODE elseif record.plain then PLAIN_MODE else FAR_MODE
	-- (A record made before the seasons started: every part in its template's colour.)
	local tones: { number } = record.tone or table.create(#record.parts, 0)
	record.tone = tones
	local boxes, first, parts = record.boxes, record.first, record.parts
	local spriteTints = self.spriteTints
	local count = record.count
	local checks = 0
	local i = season.box
	while i < count do
		local appearance, surface = decodeKey(readu16(boxes, i * BOX + 12))
		if buffer.readu8(SEASONAL, appearance) == 0 then
			i += 1
			season.part = 0
			continue
		end
		season.seen = true
		-- Its chunk column's class (see the header); one asked of the generator costs, so the
		-- clock is looked at after it.
		local class, asked = chunkClass(season, chunkOf(node, step, boxes, i * BOX))
		if asked and os.clock() > deadline then
			season.box = i
			return done, false
		end
		local from, to = first[i + 1], first[i + 2] - 1
		local p = if season.part > 0 then season.part else from
		local shape = shapes[appearance]
		local boxPaint: Paint? = nil
		local sprite = false
		local drawn: { number } = NO_BOXES
		local tint = 1
		if shape == nil then
			boxPaint = paintFor(self, class, appearance, 0, mode, 1)
		else
			if tintColours[appearance] then
				tint = math.min(surface, FOLIAGE_TINT_COUNT) + 1
			end
			sprite = not far and TextureLooks.spriteOf(appearance) ~= nil
			if sprite then
				boxPaint = paintFor(self, class, appearance, SPRITE_BOX, mode, tint)
			else
				drawn = (TextureLooks.drawnBoxes(appearance, record.plain) or NO_BOXES) :: { number }
			end
		end
		local perCell = math.max(1, #drawn)
		-- (A part whose tone is at least this already shows the colour in effect.)
		local sinceOf = season.since[class]
		local since = if sinceOf then sinceOf[appearance] or 0 else 0
		while p <= to do
			local tone = tones[p]
			if tone < gen and tone >= since then
				tones[p] = gen
			elseif tone ~= gen then
				local part = parts[p]
				local paint = boxPaint or paintFor(self, class, appearance, drawn[(p - from) % perCell + 1], mode, tint)
				-- (Never more than `limit` writes, unless one paint alone is more.)
				if done > 0 and done + paint.writes > limit then
					season.box = i
					season.part = p
					return done, false
				end
				local written = applyPaint(pool, part, paint)
				if sprite then
					spriteTints[part] = paint.id
				end
				tones[p] = gen
				done += written
				checks += 1
				if done >= limit or (checks >= CLOCK_EVERY and os.clock() > deadline) then
					season.box = i
					season.part = p + 1
					return done, false
				end
				if checks >= CLOCK_EVERY then
					checks = 0
				end
			end
			p += 1
		end
		i += 1
		season.part = 0
	end
	-- (A record without seasonal parts is never visited again.)
	record.painted = if season.seen then gen else math.huge
	return done, true
end

--[[ Building ]]

--[[
	Adds a part just built to the task (`sparse`: a sparse light's, `lava` a lit fluid's; `tone`: a
	seasonal part's palette generation, 0 when it was left in its template's colour).
]]
local function addPart(self: ChunkRenderer, b: Build, part: BasePart, sparse: boolean, lava: boolean?, tone: number?)
	table.insert(b.parts, part)
	local tones = b.tone
	if tones then
		tones[#b.parts] = tone or 0
		if tone and tone < b.minTone then
			b.minTone = tone
		end
	end
	local folder = b.folder
	if folder then
		part.Parent = folder
	else
		table.insert(b.added, part)
	end
	if self.pool:hasLight(part) then
		table.insert(b.lights, part)
		lightOn(self, b, part, sparse, lava == true)
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
	-- Seasons: a seasonal part's palette generation (nil: not seasonal), whether it is painted
	-- now (once a palette other than the authored one was applied) and in which biome class (its
	-- chunk column's; see the header).
	local season = self.season
	local tone: number? = nil
	local painting = false
	local class = Foliage.TEMPERATE
	if season and buffer.readu8(SEASONAL, appearance) ~= 0 then
		painting = season.dirty
		tone = if painting then season.gen else 0
		if painting then
			class = chunkClass(season, chunkOf(node, b.step, boxes, o))
		end
	end
	local mode = if not far then NEAR_MODE elseif plain then PLAIN_MODE else FAR_MODE
	if shape then
		-- One part per shape box in every cell (shaped boxes are single cells), or two sprite
		-- planes (plants with a sprite, full detail only).
		local pixel = Vector3.new(scale, scaleY, scale) / 16
		local scatter = scattered[appearance]
		-- (For tinted plants the surface field is the soil's tint; see GreedyMesher.)
		local tints = tintColours[appearance]
		local tint = if tints then math.min(surface, #Blocks.FOLIAGE_TINTS) + 1 else 1
		-- (For sparse lights it says whether this cell carries the light.)
		local sparseLight = buffer.readu8(GreedyMesher.sparseLightLut, appearance) == 1
		local dark = sparseLight and surface == 0
		local sprite = if far then nil else TextureLooks.spriteOf(appearance)
		-- (The boxes built: a Front image replaces the others.)
		local drawn: { number } = TextureLooks.drawnBoxes(appearance, plain) or {}
		local perCell = if sprite then #SPRITE_TURNS else #drawn
		for cy = y, y + sy - 1 do
			for cz = z, z + sz - 1 do
				for cx = x, x + sx - 1 do
					if k + perCell <= skip then
						k += perCell
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
					if sprite then
						local frame = cell or CFrame.new(centre)
						local colour = sprite.tints[tint] or sprite.tints[1]
						for _, turn in SPRITE_TURNS do
							if k < skip then
								k += 1
								continue
							end
							if self.windowBuilt > 0 and os.clock() > deadline then
								b.sub = k
								return false
							end
							local part = pool:acquire(appearance, far, plain, SPRITE_BOX)
							part.Size = Vector3.new(scale * SQRT2, scaleY, PartPool.SPRITE_THICKNESS)
							part.CFrame = frame * turn
							if painting then
								local paint = paintFor(self, class, appearance, SPRITE_BOX, mode, tint)
								if self.spriteTints[part] ~= paint.id then
									self.spriteTints[part] = paint.id
									applyPaint(pool, part, paint)
								end
							else
								local images = if sprite.tinted then pool:images(part) else nil
								if images and self.spriteTints[part] ~= tint then
									self.spriteTints[part] = tint
									for _, decal in images do
										decal.Color3 = colour
									end
								end
							end
							addPart(self, b, part, false, nil, tone)
							k += 1
						end
						continue
					end
					for _, index in drawn do
						if k < skip then
							k += 1
							continue
						end
						local box = shape[index]
						if self.windowBuilt > 0 and os.clock() > deadline then
							b.sub = k
							return false
						end
						local part = pool:acquire(appearance, far, plain, index, dark)
						part.Size = box.size * pixel
						part.CFrame = if cell
							then cell * CFrame.new(box.offset * pixel) * box.rotation
							else CFrame.new(centre + box.offset * pixel) * box.rotation
						if painting then
							applyPaint(pool, part, paintFor(self, class, appearance, index, mode, tint))
						elseif tints then
							part.Color = tints[index][tint]
						end
						addPart(self, b, part, sparseLight, nil, tone)
						k += 1
					end
				end
			end
		end
		return true
	end
	-- Fluid surface below the top of its cell (flowing water steps down). Parts are at most
	-- MAX_PART studs long: wide boxes of coarse levels and tall boxes in high terrain are split.
	-- A lit fluid (lava) carries its light only in the cell the mesher marked: every other box of
	-- it is dark (GreedyMesher.fluidSurface).
	local lit = buffer.readu8(GreedyMesher.sparseLightLut, appearance) == 1
	local fluidHeight, carries = surface, false
	if lit then
		fluidHeight, carries = GreedyMesher.fluidSurface(surface)
	end
	local dark = lit and not carries
	local lower = if fluidHeight > 0 then (FLUID_FULL - fluidHeight) / FLUID_FULL * Config.BlockSize else 0
	-- A snow layer's box ends at its layers' height (2 pixels a layer: Blocks.layerLut).
	local layers = buffer.readu8(LAYER_LUT, appearance)
	if layers > 0 then
		lower = (Blocks.MAX_LAYERS - layers) / Blocks.MAX_LAYERS * Config.BlockSize
	end
	local maxCells, maxCellsY = b.maxCells, b.maxCellsY
	local cubePaint = if painting then paintFor(self, class, appearance, 0, mode, 1) else nil
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
				local part = pool:acquire(appearance, far, plain, 0, dark)
				part.Size = Vector3.new(wx * scale, height, wz * scale)
				part.CFrame = CFrame.new(originX + (px + wx * 0.5) * scale, cy, originZ + (pz + wz * 0.5) * scale)
				if cubePaint then
					applyPaint(pool, part, cubePaint)
				end
				addPart(self, b, part, lit, lit, tone)
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
	-- The look: merged far levels may be plain (MeshOverlay), each with its own generation.
	b.far = node.level > 0
	b.plain = b.far and self.overlay:plainLevel(node.level)
	b.texture = self.pool:generationOf(b.plain)
	local sameLook = base ~= nil and base.texture == b.texture and base.plain == b.plain
	if b.restyle then
		-- Rebuild what is live now, unless a newer build already used the current look.
		if base == nil or sameLook then
			b.noop = true
			return
		end
		b.boxes, b.count = base.boxes, base.count
	end
	b.first = table.create(b.count + 1)
	if base and base.count > 0 and b.count > 0 and sameLook and base.folder then
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
	-- (The node's corner in render studs for the origin now: exact doubles; the parts are placed
	-- for it and moved to the node's origin at the commit if it moved meanwhile.)
	b.ox, b.oz = Origin.x, Origin.z
	b.originX = node.nx * Config.ChunkSize * b.scale - b.ox
	b.originZ = node.nz * Config.ChunkSize * b.scale - b.oz
	b.maxCells = math.max(1, MAX_PART // b.scale)
	b.maxCellsY = math.max(1, MAX_PART // b.scaleY)
	-- Seasons: the parts' palette generations (see the header).
	if self.season then
		b.tone = {}
		b.minTone = math.huge
	end
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
			-- Kept: the live parts of the identical old box (with their palette generations).
			local from, to = base.first[j + 1], base.first[j + 2] - 1
			local n = #parts
			table.move(base.parts, from, to, n + 1, parts)
			local tones = b.tone
			if tones then
				local baseTones = base.tone
				for k = from, to do
					tones[n + 1 + k - from] = if baseTones then baseTones[k] else 0
				end
			end
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

--[[
	A build's new parts (out of the workspace) to the origin their node's parts are placed for,
	before the commit parents them: (world - b.o) + (b.o - state.o). Nothing unless the origin
	moved while it was built.
]]
local function placeBuilt(b: Build, state: NodeState, parts: { BasePart })
	local dx, dz = b.ox - state.ox, b.oz - state.oz
	if dx == 0 and dz == 0 then
		return
	end
	local d = Vector3.new(dx, 0, dz)
	for _, part in parts do
		part.CFrame += d
	end
end

-- The oldest palette generation among the seasonal parts a build made (math.huge when it made
-- none; 0 without seasons, or when it started before them).
local function paintedBy(self: ChunkRenderer, b: Build): number
	if self.season == nil or b.tone == nil then
		return 0
	end
	return b.minTone
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
			placeBuilt(b, state, b.parts)
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
				plain = b.plain,
				tone = b.tone,
				painted = paintedBy(self, b),
			}
		else
			local live = (base :: Record).folder :: Folder
			local old = base :: Record
			placeBuilt(b, state, b.added)
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
			-- Kept parts' palette generations as they are now (the sweep may have painted them in
			-- the old record since the build took them).
			local tones = b.tone
			if tones then
				local oldTones = old.tone
				for index, j in b.matched :: { number } do
					if j >= 0 then
						local from, at = old.first[j + 1], b.first[index]
						for k = 0, old.first[j + 2] - from - 1 do
							tones[at + k] = if oldTones then oldTones[from + k] else 0
						end
					end
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
				plain = b.plain,
				tone = b.tone,
				painted = math.min(paintedBy(self, b), old.painted),
			}
		end
		state.parts += (if record then #record.parts else 0) - (if base then #base.parts else 0)
		if record then
			state.records[section] = record
			lateRecord(self, node, section, record)
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
		ox = 0,
		oz = 0,
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
		tone = nil,
		minTone = math.huge,
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
	settle(self, node)
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
		if self.season then
			removeHolder(self.season, node)
		end
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
	Applies a new shadow / far shadow / texture / far materials style: PartPool templates now, live
	parts within the build budget (shadows); Textures and Far Materials go through PartPool to
	TextureLooks, whose change rebuilds the sections it touches (`looksChanged`). Returns what
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
	return changes
end

-- Whether a node's parts are drawn plain now, and the look generation they take.
local function lookNow(self: ChunkRenderer, node: RenderNode): (boolean, number)
	local plain = node.level > 0 and self.overlay:plainLevel(node.level)
	return plain, self.pool:generationOf(plain)
end

-- Do all of a node's live sections carry the current look (MeshOverlay merges only those)?
function isCurrent(self: ChunkRenderer, node: RenderNode): boolean
	local state = self.states[node]
	if state == nil then
		return true
	end
	local plain, generation = lookNow(self, node)
	for _, record in state.records do
		if record.texture ~= generation or record.plain ~= plain then
			return false
		end
	end
	return true
end

--[[
	TextureLooks' looks changed (or the overlay's plain levels, `changes` all false): PartPool takes
	the new generations, the far meshes the new looks, and every live section with an older look
	(or drawn plain when it no longer is, or the other way round) is rebuilt in the background lane,
	as are first builds that may have started with the old look.
]]
function looksChanged(self: ChunkRenderer, changes: TextureLooks.Changes)
	self.pool:syncLooks()
	if changes.meshes then
		self.overlay:setLooks(
			TextureLooks.farMaterials(),
			TextureLooks.lookOf,
			TextureLooks.lookInfo,
			TextureLooks.plainRgb
		)
	end
	-- Seasons: paints follow the looks (the rebuilds below paint with the new ones), and so do the
	-- far meshes' seasonal colours.
	local season = self.season
	if season then
		table.clear(season.tints)
		table.clear(season.paints)
	end
	local farSeason = self.overlay.season
	if farSeason then
		ChunkRenderer.setFarSeason(self, farSeason.targets, farSeason.id)
	end
	local schedule = self.schedule
	local sections: { WalkEntry } = {}
	for node, state in self.states do
		local plain, generation = lookNow(self, node)
		for section, record in state.records do
			if record.texture ~= generation or record.plain ~= plain then
				table.insert(sections, { node = node, section = section })
			end
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
		-- (A build that starts later uses the new look.)
		if not schedule:startsLater(entry.node, entry.section) then
			local task = newTask(entry.node, entry.section, BACKGROUND, newBuild(buffer.create(0), true))
			task.restyle = true
			addTask(self, task)
		end
	end
end

--[[ The floating origin (see the header) ]]

-- Appends every part of `records` with its CFrame moved by -shift.
local function appendRecords(records: { Record }, shift: Vector3, parts: { BasePart }, cframes: { CFrame })
	local n = #parts
	for _, record in records do
		for _, part in record.parts do
			n += 1
			parts[n] = part
			cframes[n] = part.CFrame - shift
		end
	end
end

--[[
	The Rebase mover: every part of ours in the workspace, with its CFrame for the new origin
	(the far meshes' too); the nodes in the workspace are placed for the new origin from now on and
	the sparse lights' positions follow. What is out of the workspace stays where it is (fixed when
	it goes in). Each part is visited once: a record's parts are its own (a diff build's kept parts
	are only in its base record until the commit), retiring and trashed records were taken out of
	their nodes.
]]
function gather(self: ChunkRenderer, dx: number, dz: number, parts: { BasePart }, cframes: { CFrame })
	local ox, oz = Origin.x, Origin.z
	local d = Vector3.new(dx, 0, dz)
	for node, state in self.states do
		local model = node.model
		if model == nil or model.Parent == nil then
			continue
		end
		-- (Placed for the old origin, as every model in the workspace is: the shift is the move.)
		local sx, sz = ox - state.ox, oz - state.oz
		state.ox, state.oz = ox, oz
		if sx == 0 and sz == 0 then
			continue
		end
		local shift = if sx == dx and sz == dz then d else Vector3.new(sx, 0, sz)
		local n = #parts
		for _, record in state.records do
			for _, part in record.parts do
				n += 1
				parts[n] = part
				cframes[n] = part.CFrame - shift
			end
		end
	end
	-- Retiring models, folders and removed parts still in the workspace (the swap delay).
	local retiring = self.retiring
	for i = self.retiringHead, #retiring do
		local entry = retiring[i]
		if entry.done then
			continue
		end
		local model = entry.model
		local folder = entry.folder
		local list = entry.list
		if model then
			if model.Parent ~= nil and entry.records then
				appendRecords(entry.records, d, parts, cframes)
			end
		elseif folder then
			local parent = folder.Parent
			if parent ~= nil and parent.Parent ~= nil and entry.records then
				appendRecords(entry.records, d, parts, cframes)
			end
		elseif list then
			local inFolder = entry.inFolder
			local parent = if inFolder then inFolder.Parent else nil
			if parent ~= nil and parent.Parent ~= nil then
				local n = #parts
				for _, part in list do
					n += 1
					parts[n] = part
					cframes[n] = part.CFrame - d
				end
			end
		end
	end
	-- Trashed models still in the workspace (teleports).
	for _, entry in self.trash do
		if not entry.done and entry.model.Parent ~= nil then
			appendRecords(entry.records, d, parts, cframes)
		end
	end
	self.overlay:gather(d, parts, cframes)
	for _, entry in self.sparseLights do
		entry.position -= d
	end
end

--[[
	The node's model was just put into the workspace (`show`, or the far meshes putting it back):
	when the origin moved since its parts were placed, everything in it (live sections, and any
	retiring folder or removed parts still inside) moves by (its origin - the current one) in one
	BulkMoveTo, before anything yields.
]]
function settle(self: ChunkRenderer, node: RenderNode)
	local state = self.states[node]
	local model = node.model
	if state == nil or model == nil or model.Parent == nil then
		return
	end
	local ox, oz = Origin.x, Origin.z
	if state.ox == ox and state.oz == oz then
		return
	end
	local d = Vector3.new(state.ox - ox, 0, state.oz - oz)
	state.ox, state.oz = ox, oz
	local parts: { BasePart } = {}
	local cframes: { CFrame } = {}
	-- (A node's model holds section folders, and they hold only parts.)
	for _, folder in model:GetChildren() do
		for _, child in folder:GetChildren() do
			local part = child :: BasePart
			table.insert(parts, part)
			table.insert(cframes, part.CFrame + d)
		end
	end
	if #parts > 0 then
		workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
	Rebase.settled(#parts)
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

--[[ Seasons: public (see the header) ]]

local function seasonOf(self: ChunkRenderer): Season
	local season = self.season
	if season == nil then
		local made = newSeason()
		self.season = made
		-- (Nodes built before may hold seasonal parts, in their templates' colours.)
		for node in self.states do
			addHolder(made, node)
		end
		return made
	end
	return season :: Season
end

--[[
	A new palette (Shared/Seasons/Foliage.targets; nil: the authored colours). Returns true when
	some colour changed: a sweep starts (`seasonSweep`) and from then on new parts are painted in
	it. The renderer keeps its own copy.
]]
function ChunkRenderer.setSeason(self: ChunkRenderer, targets: Foliage.Targets?): boolean
	local season = seasonOf(self)
	local changed, seasonal = applyTargets(season, targets, season.gen + 1)
	if not changed then
		return false
	end
	season.gen += 1
	season.dirty = season.dirty or seasonal
	table.clear(season.tints)
	table.clear(season.paints)
	if season.dirty then
		startSweep(season)
	end
	return true
end

--[[
	How a chunk column's biome class is found (Foliage.classIndex of `classAt(cx, cz)`; asked once
	per column and kept, see the header).
]]
function ChunkRenderer.setSeasonClass(self: ChunkRenderer, classAt: (cx: number, cz: number) -> number)
	local season = seasonOf(self)
	season.classAt = classAt
	if season.classes then
		buffer.fill(season.classes :: buffer, 0, 0)
	end
	if season.dirty then
		-- (Chunks may change class: every seasonal colour is written again.)
		season.gen += 1
		for class in Foliage.CLASSES do
			if season.applied[class] == nil then
				season.applied[class] = {}
			end
			local since = season.since[class] or {}
			season.since[class] = since
			for _, appearance in Foliage.appearances() do
				since[appearance] = season.gen
			end
		end
		table.clear(season.tints)
		table.clear(season.paints)
		startSweep(season)
	end
end

--[[
	The far meshes' palette (Foliage.targets at a far step `id`; nil: the authored colours):
	MeshOverlay:setSeason with every seasonal appearance's mesh colours per biome class (from
	TextureLooks.seasonalTint), which rebuilds the meshes whose palette drifted (MeshOverlay).
]]
function ChunkRenderer.setFarSeason(self: ChunkRenderer, targets: Foliage.Targets?, id: number)
	if targets == nil then
		self.overlay:setSeason(nil)
		return
	end
	local copy = copyTargets(targets)
	local colours: { { [number]: { number } } } = {}
	for class in Foliage.CLASSES do
		local list: { [number]: { number } } = {}
		local targetColours = copy.colours[class]
		for _, appearance in Foliage.appearances() do
			local tint = TextureLooks.seasonalTint(appearance, if targetColours then targetColours[appearance] else nil)
			local look, plain = tint.look, tint.plainRgb
			list[appearance] = { look[1], look[2], look[3], plain[1], plain[2], plain[3] }
		end
		colours[class] = list
	end
	local season = seasonOf(self)
	self.overlay:setSeason({
		id = id,
		targets = copy,
		colours = colours,
		classAt = function(cx: number, cz: number): (number, boolean)
			return chunkClass(season, cx, cz)
		end,
		drift = function(from: any, to: any, classes: { number }): number
			return Foliage.drift(from, to, classes)
		end,
		limit = Config.Seasons.Foliage.FarDeltaE,
	})
end

--[[
	Runs the sweep (see the header) for at most `writes` property writes and `ms` milliseconds
	(Config.Seasons.Foliage.SweepWrites, SweepMs: Rendering/SeasonTint calls it every frame), the
	ranking and the walk included. Returns the writes done and whether nothing is left to paint.
	Allocates nothing once its rings are made (they are kept from sweep to sweep).
]]
function ChunkRenderer.seasonSweep(self: ChunkRenderer, writes: number, ms: number): (number, boolean)
	local season = self.season
	if season == nil or not season.sweeping then
		return 0, true
	end
	local deadline = os.clock() + ms / 1000
	local done = 0
	season.frames += 1
	while true do
		local node, record, paused = sweepRecord(self, season, deadline)
		if paused then
			season.writes += done
			return done, false
		end
		if node == nil or record == nil then
			season.sweeping = false
			season.writes += done
			season.lastWrites, season.lastFrames = season.writes, season.frames
			season.sweeps += 1
			table.clear(season.lateNodes)
			table.clear(season.lateSections)
			season.lateIndex = 1
			return done, true
		end
		local finished: boolean
		done, finished = paintRecord(self, season, node, record, done, writes, deadline)
		if not finished then
			season.writes += done
			return done, false
		end
		advance(season)
		if done >= writes or os.clock() > deadline then
			season.writes += done
			return done, false
		end
	end
end

function ChunkRenderer.seasonStats(self: ChunkRenderer): SeasonStats
	local season = self.season
	if season == nil then
		return {
			gen = 0,
			sweeping = false,
			writes = 0,
			frames = 0,
			lastWrites = 0,
			lastFrames = 0,
			sweeps = 0,
			late = 0,
		}
	end
	return {
		gen = season.gen,
		sweeping = season.sweeping,
		writes = season.writes,
		frames = season.frames,
		lastWrites = season.lastWrites,
		lastFrames = season.lastFrames,
		sweeps = season.sweeps,
		late = #season.lateNodes - season.lateIndex + 1,
	}
end

return ChunkRenderer
