--!strict
--[[
	Turrets seen (Shared/Turrets): the gun on every turret block near the camera, turning and
	firing as the server's Turrets records say (Net/Protocol message Turrets: aim, target, flags,
	rounds), drawn from pooled parts in their models (Rendering/TurretModel), with a Laser Sight's
	beam and the servo's loop. Their shots are Rendering/ShotView's (Shots records with no shooter:
	the flash and tracer start at the shooter's drawn barrel's end, `muzzleNear`, else at the
	record's origin, the server's muzzle).

	The API (frozen: the client script, WAILA and F3 are built on it):
	  start(world, shown?)  once, after Rendering/ShotView: turret positions from the world's edits
	                   (World/ClientWorld), the records, the parts, the frame loop. `shown(cx, cz)`
	                   (optional, as Rendering/TransmitterRenderer's) says whether the full detail
	                   chunk is on screen; without it a chunk whose data is loaded counts
	  state(x, y, z)   the record the turret at block (x, y, z) last got (nil: none, idle), for
	                   WAILA's turret lines (frozen tables: read only)
	  stats()          drawn turrets, records known, tracking, parts in use (F3's turret line)
	and besides: `describe()` (F3's line), `muzzleNear(ox, oy, oz)` (the drawn muzzle of the turret
	whose shot started there: the one whose pivot is its barrel's length from it, ShotView, given
	it at `start`) and SERVO (the loop's event).

	Turrets: where they are only comes from edits (a turret is placed), so a chunk's are found in
	its edit list when its data is loaded (ClientWorld onChunkLoaded, knownEdits), followed through
	its block changes (onBlockChanged) and dropped with its data, as the pipes are.
	Records: by position, as the server sends them (a record replaces what was known; a turret
	without one is idle, TurretModel.idle, and an idle record is forgotten). They are kept for
	chunks whose edit list is known or asked for, or whose data is loaded, and forgotten when
	neither is (they come again with the edit list). A change of a position's block forgets its
	record (the server starts a new turret idle); when this player's own predicted break took it,
	it is kept UNDO_WINDOW seconds and comes back if the server refuses the break (then dropped).
	A record that says Dry (Protocol.TurretFlag: it tracks and would fire now with no round, the
	server's No ammo) after one that did not clicks item.firearm.dry (Rendering/ShotRules.DRY) at
	the gun, once: a fed turret's next round comes before its cadence is ready, so it never clicks;
	one that runs dry does, also when its last round killed its target and it takes the next.
	Drawn: every REFRESH_INTERVAL (and when something changed) the turrets within Config.Turrets
	.Client.DrawDistance of the camera whose chunk is shown, nothing over the gun
	(Shared/Turrets.headClear of the cell above, as the client sees it) and the record not
	Blocked, the nearest MaxDrawn of them, get a head: TurretModel.MAX_PARTS parts and the beam,
	pooled (at most MaxParts parts in all: never more heads than that allows), made once, re-dressed
	(size, colour, material) only when what is mounted changes. Every frame each drawn gun turns
	towards TurretModel.want (the target as Entities/MobRenderer.aimPoint draws it, else the
	record's aim; idle, level) at its turn rate (TurretModel.step: TurretRules.turn), and a head
	that came into view starts where the record says (no sweep from yaw 0). With the turrets off
	(Config.Turrets.Enabled false) no records come: the guns stand idle, level at yaw 0.
	Beam: a Laser Sight on a powered turret draws a thin red Neon bar from the emitter along the
	drawn aim to the first block that stops sight (Shared/World/VoxelRaycast with Blocks/Shapes
	.sight, the turret's own cell left out: as the server's sight), looked at every BEAM_INTERVAL
	seconds and as soon as the drawn aim turned BEAM_TURN since the last look, or to the target it
	passes, at most Config.Turrets.Client.BeamLength.
	Servo: block.turret.servo (SERVO; a developer's Sound of that name in the override folder
	replaces it: Audio/SoundPlayer) loops at the ServoLoops nearest turrets that turned within
	SERVO_HOLD seconds, on that many loops of its own (SoundPlayer.setLoop).

	Performance: a head is moved only when its aim or the render origin changed or it was just
	dressed; every part that moves goes in one workspace:BulkMoveTo a frame, after the camera.
	Nothing is created per frame but the CFrames (and a beam's Size while its length changes): one
	reused list of numbers for TurretModel.place, reused lists for BulkMoveTo, aim points as
	numbers (MobRenderer.aimPoint); a still gun costs its aim's few sums.

	The floating origin (Shared/World/Origin): turrets, records, aims and beams stay in world blocks
	(doubles) and are converted to render studs as each CFrame is built; a head remembers the
	Origin.epoch it was placed for, so a move of the origin rewrites every drawn head that frame
	(no render position is ever kept across a rebase, and no Rendering/Rebase mover is needed:
	Rebase moves the origin before this frame's step, at Camera - 3). Hidden heads' parts are
	invisible and placed again when shown.

	`workspace` (the Workspace service) and RunService are touched only in `start` and the frame
	step; specs load this module with fakes (tests/spec/TurretClient).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local ChunkLayout = require(Shared.World.ChunkLayout)
local Config = require(Shared.Config)
local Coords = require(Shared.World.Coords)
local Origin = require(Shared.World.Origin)
local Protocol = require(Shared.Net.Protocol)
local Shapes = require(Shared.Blocks.Shapes)
local Turrets = require(Shared.Turrets)
local TurretRules = require(Shared.Turrets.TurretRules)
local VoxelRaycast = require(Shared.World.VoxelRaycast)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local MobRenderer = require(script.Parent.Parent.Entities.MobRenderer)
local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)
local ShotRules = require(script.Parent.ShotRules)
local ShotView = require(script.Parent.ShotView)
local TurretModel = require(script.Parent.TurretModel)

-- F3's counts (see the header).
export type Stats = { drawn: number, records: number, tracking: number, parts: number }

type Spec = Turrets.Spec
type Record = Protocol.TurretRecord

local BLOCK = Config.BlockSize
local SIZE = Config.ChunkSize
local HEIGHT = Config.WorldHeight
local Flag = Protocol.TurretFlag
local STRIDE = TurretModel.STRIDE
local posKey = Coords.posKey

--[[ Tunables ]]

-- After the camera, as the mobs and the shots.
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1
-- Seconds between looks at which turrets are drawn (and as soon as something changed).
local REFRESH_INTERVAL = 0.25
-- A head's parts: the gun's boxes and the beam (the last).
local PARTS_PER_HEAD = TurretModel.MAX_PARTS + 1
-- The longest frame turned at once (seconds: after a hitch the guns catch up over a few frames).
local MAX_DT = 0.25
-- Seconds between looks at the block a beam ends on, and how far (radians) the drawn aim turns
-- before one at once; the beam's thickness (blocks), its transparency, the smallest change of its
-- length worth a resize (blocks), and how near a target it passes to end there (blocks).
local BEAM_INTERVAL = 0.1
local BEAM_TURN = math.rad(1)
local BEAM_WIDTH = 0.03
local BEAM_TRANSPARENCY = 0.2
local BEAM_SLACK = 0.01
local BEAM_TARGET = 0.6
-- A gun counts as turning (its servo heard) this long after it last moved (seconds).
local SERVO_HOLD = 0.2
-- How far (blocks) a shot's origin may be off a barrel's length from a turret's pivot for it to be
-- the shooter (the server's muzzle is exactly that; the record's float32 rounding is added).
local SHOOTER_SLACK = 0.02
-- Seconds the record of a turret this player broke is kept, in case the server refuses the break.
local UNDO_WINDOW = 5

local MATERIALS: { [TurretModel.Material]: Enum.Material } = {
	metal = Enum.Material.Metal,
	plastic = Enum.Material.SmoothPlastic,
	neon = Enum.Material.Neon,
}
local BEAM_COLOUR = Color3.fromRGB(TurretModel.BEAM_COLOUR[1], TurretModel.BEAM_COLOUR[2], TurretModel.BEAM_COLOUR[3])

-- A drawn gun's parts and what they show.
type Head = {
	parts: { Part },
	look: TurretModel.Look?,
	-- Boxes showing (the beam apart), and the beam's length (blocks; 0: hidden).
	shown: number,
	beam: number,
	-- Placed for this aim and Origin.epoch (false: not placed yet).
	placed: boolean,
	yaw: number,
	pitch: number,
	epoch: number,
}

-- A turret the client knows of (its block from the edits).
type Entry = {
	key: number,
	x: number,
	y: number,
	z: number,
	chunk: number,
	block: number,
	spec: Spec,
	-- The cell above lets the gun show (Shared/Turrets.headClear).
	clear: boolean,
	head: Head?,
	-- The drawn aim, and when it last moved (the view's clock).
	yaw: number,
	pitch: number,
	turnedAt: number,
	-- Squared distance (blocks) to the camera at the last refresh.
	distance: number,
	-- The beam's reach to the first block (blocks), when it is looked at next, and the drawn aim
	-- it was looked at for.
	reach: number,
	reachAt: number,
	reachYaw: number,
	reachPitch: number,
}

local TurretView = {}

-- The servo's loop (Shared/Sounds; overridable by a Sound of this name: Audio/SoundPlayer).
TurretView.SERVO = "block.turret.servo"

local started = false
local world: ClientWorld.ClientWorld? = nil
local folder: Folder? = nil

local entries: { [number]: Entry } = {}
local entriesByChunk: { [number]: { [number]: boolean } } = {}
local records: { [number]: Record } = {}
local recordsByChunk: { [number]: { [number]: boolean } } = {}
local recordCount = 0
local undone: { [number]: { block: number, at: number, record: Record } } = {}

local drawn: { Entry } = {}
local candidates: { Entry } = {}
local freeHeads: { Head } = {}
local headsMade = 0
local maxHeads = 0
local dirty = true
local sinceRefresh = math.huge
-- The view's clock: seconds of frames drawn (the frames' own times, so the beam's looks and the
-- servo's hold follow the frames).
local clock = 0

-- The frame's buffers (reused): TurretModel.place's numbers, the parts and CFrames moved.
local numbers: { number } = table.create(TurretModel.MAX_PARTS * STRIDE, 0)
local moveParts: { BasePart } = {}
local moveFrames: { CFrame } = {}
local moveCount = 0

-- The servo's loops: their keys (SoundPlayer.setLoop) and which play.
local servoKeys: { string } = {}
local servoOn: { boolean } = {}
local servoPicked: { Entry } = {}
local servoDistances: { number } = {}

-- Whether the full detail chunk (cx, cz) shows its turrets (see `start`).
local isShown: (cx: number, cz: number) -> boolean = function(cx: number, cz: number): boolean
	local w = world
	return w ~= nil and w.chunks[Coords.chunkKey(cx, cz)] ~= nil
end

--[[ The beam's sight ]]

-- The block the beam meets at (x, y, z): the world's, the turret's own cell left out.
local skipX, skipY, skipZ = 0, -1, 0
local function beamBlock(x: number, y: number, z: number): number?
	if x == skipX and y == skipY and z == skipZ then
		return Blocks.AIR
	end
	local w = world
	return if w then w:getBlock(x, y, z) else nil
end
local beamStops, beamOutline = Shapes.sight(beamBlock)

-- How far the beam of `entry` (with `look`) at its drawn aim reaches before a block stops it.
local function reachOf(entry: Entry, look: TurretModel.Look): number
	local reach = Config.Turrets.Client.BeamLength
	local sx, sy, sz = TurretModel.laserStart(look, entry.x, entry.y, entry.z, entry.yaw, entry.pitch)
	if sx == nil or sy == nil or sz == nil then
		return 0
	end
	local dx, dy, dz = TurretRules.direction(entry.yaw, entry.pitch)
	skipX, skipY, skipZ = entry.x, entry.y, entry.z
	local hit = VoxelRaycast.distance(sx, sy, sz, dx, dy, dz, reach, beamBlock, beamStops, beamOutline)
	skipY = -1
	return if hit then hit else reach
end

--[[ Records ]]

local function chunkOfKey(key: number): number
	local x, _, z = Coords.decodePosKey(key)
	return Coords.chunkKey(x // SIZE, z // SIZE)
end

-- Is the record of a position in column (x, z) wanted (its chunk's edit list known or asked for,
-- or its data loaded)?
local function wanted(x: number, z: number): boolean
	local w = world
	if w == nil then
		return false
	end
	local chunk = Coords.chunkKey(x // SIZE, z // SIZE)
	return w.edits[chunk] ~= nil or w.chunks[chunk] ~= nil
end

local function blockedBy(record: Record?): boolean
	return record ~= nil and bit32.btest(record.flags, Flag.Blocked)
end

local function setRecord(key: number, record: Record)
	local old = records[key]
	if old == nil then
		recordCount += 1
		local chunk = chunkOfKey(key)
		local list = recordsByChunk[chunk]
		if list == nil then
			list = {}
			recordsByChunk[chunk] = list
		end
		list[key] = true
	end
	records[key] = record
	if blockedBy(old) ~= blockedBy(record) and entries[key] then
		dirty = true
	end
end

local function dropRecord(key: number)
	local old = records[key]
	if old == nil then
		return
	end
	records[key] = nil
	recordCount -= 1
	local chunk = chunkOfKey(key)
	local list = recordsByChunk[chunk]
	if list then
		list[key] = nil
		if next(list) == nil then
			recordsByChunk[chunk] = nil
		end
	end
	if blockedBy(old) and entries[key] then
		dirty = true
	end
end

-- Forgets the records of chunk `chunk`: its turrets look idle until records come again.
local function dropChunkRecords(chunk: number)
	local list = recordsByChunk[chunk]
	if list then
		for key in table.clone(list) do
			dropRecord(key)
			undone[key] = nil
		end
	end
end

-- Does `record` say it would fire now and has no round (TurretFlag.Dry: the server's No ammo while
-- it tracks)?
local function dry(record: Record): boolean
	return bit32.btest(record.flags, Flag.Dry)
end

local function onRecords(list: { Record })
	for _, record in list do
		local x, y, z = record.x, record.y, record.z
		if y >= 0 and y < HEIGHT and wanted(x, z) then
			local key = posKey(x, y, z)
			local old = records[key]
			local entry = entries[key]
			-- It would fire and has no round (it was not so last): the gun clicks, once.
			if entry and old and dry(record) and not dry(old) then
				local px, py, pz = TurretRules.pivot(x, y, z)
				SoundPlayer.play(ShotRules.DRY, px, py, pz)
			end
			if TurretModel.idle(record) then
				dropRecord(key)
			else
				setRecord(key, table.freeze(record))
			end
		end
	end
end

--[[ Heads ]]

local function newHead(): Head
	local parts: { Part } = table.create(PARTS_PER_HEAD)
	for i = 1, PARTS_PER_HEAD do
		local part = Instance.new("Part")
		part.Name = if i == PARTS_PER_HEAD then "Beam" else "Gun"
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Transparency = 1
		part.Size = Vector3.one * 0.1
		if i == PARTS_PER_HEAD then
			part.Material = Enum.Material.Neon
			part.Color = BEAM_COLOUR
		end
		part.Parent = folder
		parts[i] = part
	end
	headsMade += 1
	return { parts = parts, look = nil, shown = 0, beam = 0, placed = false, yaw = 0, pitch = 0, epoch = -1 }
end

-- Dresses `head`'s parts as `look`'s boxes (the others and the beam hidden).
local function dress(head: Head, look: TurretModel.Look)
	local boxes = look.boxes
	for i = 1, TurretModel.MAX_PARTS do
		local part = head.parts[i]
		local box = boxes[i]
		if box then
			local size, colour = box.size, box.colour
			part.Size = Vector3.new(size[1] * BLOCK, size[2] * BLOCK, size[3] * BLOCK)
			part.Color = Color3.fromRGB(colour[1], colour[2], colour[3])
			part.Material = MATERIALS[box.material]
			part.CastShadow = box.name == "Receiver"
			part.Transparency = 0
		elseif part.Transparency ~= 1 then
			part.Transparency = 1
		end
	end
	head.parts[PARTS_PER_HEAD].Transparency = 1
	head.look = look
	head.shown = #boxes
	head.beam = 0
	head.placed = false
end

-- Hides `head`'s parts.
local function hide(head: Head)
	for _, part in head.parts do
		if part.Transparency ~= 1 then
			part.Transparency = 1
		end
	end
	head.look = nil
	head.shown = 0
	head.beam = 0
	head.placed = false
end

-- Where the gun of `entry` aims at its target as the client draws it (nil: no target drawn).
local function targetPoint(entry: Entry, record: Record?): (number?, number?, number?)
	if record == nil or record.target == 0 or not bit32.btest(record.flags, Flag.Powered) then
		return nil, nil, nil
	end
	return MobRenderer.aimPoint(record.target, TurretModel.aimsAtHead(entry.spec, record.flags))
end

local function release(entry: Entry)
	local head = entry.head
	if head == nil then
		return
	end
	entry.head = nil
	hide(head)
	table.insert(freeHeads, head)
	local index = table.find(drawn, entry)
	if index then
		drawn[index] = drawn[#drawn]
		drawn[#drawn] = nil
	end
end

local function acquire(entry: Entry)
	local head = table.remove(freeHeads)
	if head == nil then
		if headsMade >= maxHeads then
			return
		end
		head = newHead()
	end
	entry.head = head
	-- (It starts where the record says: no sweep from yaw 0 as it comes into view.)
	local record = records[entry.key]
	local ax, ay, az = targetPoint(entry, record)
	local yaw, pitch = TurretModel.want(record, entry.x, entry.y, entry.z, ax, ay, az, entry.spec)
	-- (In (-pi, pi], as TurretRules.turn keeps it: a still gun's aim never changes its form.)
	entry.yaw, entry.pitch = TurretRules.wrap(yaw), pitch
	entry.turnedAt = -math.huge
	entry.reachAt = 0
	table.insert(drawn, entry)
end

--[[ Turrets ]]

local function headClearAt(x: number, y: number, z: number): boolean
	local w = world
	return Turrets.headClear(if w then w:getBlock(x, y + 1, z) else nil)
end

local function addEntry(x: number, y: number, z: number, block: number)
	local spec = Turrets.spec(block)
	if spec == nil then
		return
	end
	local key = posKey(x, y, z)
	local entry = entries[key]
	if entry then
		entry.block = block
		entry.spec = spec
		entry.clear = headClearAt(x, y, z)
		dirty = true
		return
	end
	local chunk = Coords.chunkKey(x // SIZE, z // SIZE)
	entries[key] = {
		key = key,
		x = x,
		y = y,
		z = z,
		chunk = chunk,
		block = block,
		spec = spec,
		clear = headClearAt(x, y, z),
		head = nil,
		yaw = 0,
		pitch = 0,
		turnedAt = -math.huge,
		distance = math.huge,
		reach = 0,
		reachAt = 0,
		reachYaw = 0,
		reachPitch = 0,
	}
	local list = entriesByChunk[chunk]
	if list == nil then
		list = {}
		entriesByChunk[chunk] = list
	end
	list[key] = true
	dirty = true
end

local function removeEntry(key: number)
	local entry = entries[key]
	if entry == nil then
		return
	end
	release(entry)
	entries[key] = nil
	local list = entriesByChunk[entry.chunk]
	if list then
		list[key] = nil
		if next(list) == nil then
			entriesByChunk[entry.chunk] = nil
		end
	end
	dirty = true
end

--[[ World events ]]

local function onBlockChanged(x: number, y: number, z: number, block: number, previous: number, predicted: boolean)
	-- The cell over a turret: does the gun still show?
	if y >= 1 then
		local below = entries[posKey(x, y - 1, z)]
		if below then
			below.clear = Turrets.headClear(block)
			dirty = true
		end
	end
	local key = posKey(x, y, z)
	local now = clock
	local stash = undone[key]
	undone[key] = nil
	if Turrets.isTurret(previous) or Turrets.isTurret(block) then
		-- A new block is a new turret on the server, idle (no record comes for it). This player's
		-- own break may still be refused: keep what it took a while.
		local old = records[key]
		if predicted and old and Turrets.isTurret(previous) then
			undone[key] = { block = previous, at = now, record = old }
		end
		dropRecord(key)
		if not predicted and stash and stash.block == block and now - stash.at <= UNDO_WINDOW then
			setRecord(key, stash.record)
		end
	end
	if Turrets.isTurret(block) then
		addEntry(x, y, z, block)
	elseif entries[key] then
		removeEntry(key)
	end
end

local function onChunkLoaded(cx: number, cz: number, loaded: boolean)
	local chunk = Coords.chunkKey(cx, cz)
	local w = world
	local found: { [number]: boolean } = {}
	if loaded and w then
		local list = w:knownEdits(cx, cz)
		if list then
			for index, block in list do
				if Turrets.isTurret(block) then
					local lx, y, lz = ChunkLayout.fromLocalIndex(index)
					local x, z = cx * SIZE + lx, cz * SIZE + lz
					-- (The chunk's data has every edit; check anyway.)
					if w:getBlock(x, y, z) == block then
						addEntry(x, y, z, block)
						found[posKey(x, y, z)] = true
					end
				end
			end
		end
	end
	local list = entriesByChunk[chunk]
	if list then
		for key in table.clone(list) do
			if not found[key] then
				removeEntry(key)
			end
		end
	end
	if loaded and w then
		-- (Records of positions that are no turret in the chunk's data are stale.)
		local states = recordsByChunk[chunk]
		if states then
			for key in table.clone(states) do
				local x, y, z = Coords.decodePosKey(key)
				if not Turrets.isTurret(w:getBlock(x, y, z)) then
					dropRecord(key)
				end
			end
		end
	elseif w and w.edits[chunk] == nil then
		-- Neither its data nor its edit list: its records are no longer kept up to date.
		dropChunkRecords(chunk)
	end
	dirty = true
end

local function onEditList(cx: number, cz: number, known: boolean)
	local chunk = Coords.chunkKey(cx, cz)
	local w = world
	if not known and w and w.chunks[chunk] == nil then
		dropChunkRecords(chunk)
	end
end

--[[ Every frame ]]

-- The camera's position in world blocks (doubles).
local function cameraBlocks(): (number, number, number)
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return 0, 0, 0
	end
	return Origin.renderToBlocks(camera.CFrame.Position)
end

local function nearer(a: Entry, b: Entry): boolean
	return a.distance < b.distance
end

-- Which turrets get a head (see the header).
local function refresh()
	sinceRefresh = 0
	dirty = false
	-- (A stashed record past UNDO_WINDOW is not wanted again: the break stood.)
	for key, stash in undone do
		if clock - stash.at > UNDO_WINDOW then
			undone[key] = nil
		end
	end
	local ex, ey, ez = cameraBlocks()
	local reach = Config.Turrets.Client.DrawDistance
	local limit = reach * reach
	table.clear(candidates)
	for _, entry in entries do
		local dx, dy, dz = entry.x + 0.5 - ex, entry.y + 1 - ey, entry.z + 0.5 - ez
		local distance = dx * dx + dy * dy + dz * dz
		entry.distance = distance
		if
			entry.clear
			and distance <= limit
			and not blockedBy(records[entry.key])
			and isShown(entry.x // SIZE, entry.z // SIZE)
		then
			table.insert(candidates, entry)
		elseif entry.head then
			release(entry)
		end
	end
	local count = #candidates
	if count > maxHeads then
		table.sort(candidates, nearer)
		for i = maxHeads + 1, count do
			release(candidates[i])
		end
		count = maxHeads
	end
	for i = 1, count do
		local entry = candidates[i]
		if entry.head == nil then
			acquire(entry)
		end
	end
	table.clear(candidates)
end

local function move(part: BasePart, frame: CFrame)
	moveCount += 1
	moveParts[moveCount] = part
	moveFrames[moveCount] = frame
end

-- One drawn turret's frame: its aim, its look, its parts and its beam.
local function drawEntry(entry: Entry, head: Head, dt: number, now: number, epoch: number)
	local record = records[entry.key]
	local flags = if record then record.flags else 0
	local spec = entry.spec
	local look = TurretModel.look(spec, flags)
	if head.look ~= look then
		dress(head, look)
	end
	local x, y, z = entry.x, entry.y, entry.z
	local ax, ay, az = targetPoint(entry, record)
	local wantYaw, wantPitch = TurretModel.want(record, x, y, z, ax, ay, az, spec)
	local yaw, pitch = TurretModel.step(spec, entry.yaw, entry.pitch, wantYaw, wantPitch, dt)
	if yaw ~= entry.yaw or pitch ~= entry.pitch then
		entry.turnedAt = now
	end
	entry.yaw, entry.pitch = yaw, pitch
	local ox, oz = Origin.x, Origin.z
	local moved = not head.placed or head.yaw ~= yaw or head.pitch ~= pitch or head.epoch ~= epoch
	if moved then
		local n = TurretModel.place(look, x, y, z, yaw, pitch, numbers, 1)
		local parts = head.parts
		for i = 0, n - 1 do
			local o = i * STRIDE
			move(
				parts[i + 1],
				CFrame.new(
					numbers[o + 1] * BLOCK - ox,
					numbers[o + 2] * BLOCK,
					numbers[o + 3] * BLOCK - oz,
					numbers[o + 4],
					numbers[o + 5],
					numbers[o + 6],
					numbers[o + 7],
					numbers[o + 8],
					numbers[o + 9],
					numbers[o + 10],
					numbers[o + 11],
					numbers[o + 12]
				)
			)
		end
		head.placed = true
		head.yaw, head.pitch, head.epoch = yaw, pitch, epoch
	end
	-- The beam: to the first block, or to the target it passes.
	local beam = 0
	local laser = look.laser
	if laser and bit32.btest(flags, Flag.Powered) then
		if
			now >= entry.reachAt
			or (
				(yaw ~= entry.reachYaw or pitch ~= entry.reachPitch)
				and TurretRules.offAngle(yaw, pitch, entry.reachYaw, entry.reachPitch) > BEAM_TURN
			)
		then
			entry.reach = reachOf(entry, look)
			entry.reachAt = now + BEAM_INTERVAL
			entry.reachYaw, entry.reachPitch = yaw, pitch
		end
		beam = entry.reach
		if ax and ay and az then
			local sx, sy, sz = TurretModel.laserStart(look, x, y, z, yaw, pitch)
			local fx, fy, fz = TurretRules.direction(yaw, pitch)
			if sx and sy and sz then
				local along = (ax - sx) * fx + (ay - sy) * fy + (az - sz) * fz
				if along > 0 and along < beam then
					local mx, my, mz = sx + fx * along - ax, sy + fy * along - ay, sz + fz * along - az
					if mx * mx + my * my + mz * mz <= BEAM_TARGET * BEAM_TARGET then
						beam = along
					end
				end
			end
		end
	end
	local part = head.parts[PARTS_PER_HEAD]
	if beam > 0 and laser then
		local resized = head.beam <= 0 or math.abs(beam - head.beam) > BEAM_SLACK
		if resized then
			part.Size = Vector3.new(BEAM_WIDTH * BLOCK, BEAM_WIDTH * BLOCK, beam * BLOCK)
			if head.beam <= 0 then
				part.Transparency = BEAM_TRANSPARENCY
			end
			head.beam = beam
		end
		if moved or resized then
			local length = head.beam
			local cx, cy, cz = TurretModel.point(x, y, z, yaw, pitch, laser[1], laser[2], laser[3] + length / 2)
			local rx, ry, rz, ux, uy, uz, fx, fy, fz = TurretModel.basis(yaw, pitch)
			move(part, CFrame.new(cx * BLOCK - ox, cy * BLOCK, cz * BLOCK - oz, rx, ux, -fx, ry, uy, -fy, rz, uz, -fz))
		end
	elseif head.beam > 0 then
		part.Transparency = 1
		head.beam = 0
	end
end

-- The servo's loops at the nearest turning turrets.
local function servo(now: number)
	local loops = Config.Turrets.Client.ServoLoops
	local listener = SoundPlayer.listener()
	local picked = 0
	if listener then
		local lx, ly, lz = listener.X, listener.Y, listener.Z
		for _, entry in drawn do
			if now - entry.turnedAt <= SERVO_HOLD then
				local px, py, pz = TurretRules.pivot(entry.x, entry.y, entry.z)
				local d = (px - lx) ^ 2 + (py - ly) ^ 2 + (pz - lz) ^ 2
				-- (Kept nearest first, at most `loops`: a farther one past the last is dropped.)
				local at = picked + 1
				while at > 1 and servoDistances[at - 1] > d do
					at -= 1
				end
				if at <= loops then
					for i = math.min(picked, loops - 1), at, -1 do
						servoPicked[i + 1] = servoPicked[i]
						servoDistances[i + 1] = servoDistances[i]
					end
					servoPicked[at] = entry
					servoDistances[at] = d
					if picked < loops then
						picked += 1
					end
				end
			end
		end
	end
	for slot = 1, math.max(loops, #servoKeys) do
		local key = servoKeys[slot]
		if key == nil then
			key = `turret.servo.{slot}`
			servoKeys[slot] = key
			servoOn[slot] = false
		end
		local entry = if slot <= picked then servoPicked[slot] else nil
		if entry then
			local px, py, pz = TurretRules.pivot(entry.x, entry.y, entry.z)
			SoundPlayer.setLoop(key, TurretView.SERVO, px, py, pz)
			servoOn[slot] = true
		elseif servoOn[slot] then
			SoundPlayer.setLoop(key, nil, 0, 0, 0)
			servoOn[slot] = false
		end
	end
	table.clear(servoPicked)
end

local function frame(dt: number)
	local seconds = math.clamp(if dt == dt then dt else 0, 0, MAX_DT)
	clock += seconds
	local now = clock
	sinceRefresh += seconds
	if dirty or sinceRefresh >= REFRESH_INTERVAL then
		refresh()
	end
	local epoch = Origin.epoch
	local before = moveCount
	moveCount = 0
	for _, entry in drawn do
		local head = entry.head
		if head then
			drawEntry(entry, head, seconds, now, epoch)
		end
	end
	-- (The lists hold exactly this frame's parts.)
	for i = moveCount + 1, before do
		moveParts[i] = nil :: any
		moveFrames[i] = nil :: any
	end
	if moveCount > 0 then
		Workspace:BulkMoveTo(moveParts, moveFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
	servo(now)
end

--[[ API ]]

--[[
	Starts the view over the client's world (see the header). `shown(cx, cz)` (optional) tells
	whether the full detail chunk (cx, cz) is on screen (ChunkStreamer: its node is shown).
]]
function TurretView.start(clientWorld: ClientWorld.ClientWorld, shown: ((cx: number, cz: number) -> boolean)?)
	if started then
		return
	end
	started = true
	world = clientWorld
	if shown then
		isShown = function(cx: number, cz: number): boolean
			return clientWorld.chunks[Coords.chunkKey(cx, cz)] ~= nil and shown(cx, cz)
		end
	end
	local settings = Config.Turrets.Client
	maxHeads = math.max(math.min(settings.MaxDrawn, settings.MaxParts // PARTS_PER_HEAD), 0)
	local container = Instance.new("Folder")
	container.Name = "IceVoxelTurrets"
	container.Parent = Workspace
	folder = container

	clientWorld:onBlockChanged(onBlockChanged)
	clientWorld:onChunkLoaded(onChunkLoaded)
	clientWorld:onEditList(onEditList)
	-- Chunks loaded before this started.
	for key in clientWorld.chunks do
		local cx, cz = Coords.decodeChunkKey(key)
		onChunkLoaded(cx, cz, true)
	end
	ClientNet.on(Protocol.ServerMessage.Turrets, function(payload: buffer)
		local ok, list = pcall(Protocol.decodeTurrets, payload)
		if not ok or list == nil then
			warn("[IceVoxel] Bad Turrets message")
			return
		end
		onRecords(list)
	end)
	-- The turrets' shots start at the drawn barrels.
	ShotView.setTurretMuzzle(TurretView.muzzleNear)
	RunService:BindToRenderStep("IceVoxelTurrets", RENDER_PRIORITY, frame)
end

-- The last record of the turret at block (x, y, z), nil when none came (or an idle one).
function TurretView.state(x: number, y: number, z: number): Protocol.TurretRecord?
	if y < 0 or y >= HEIGHT then
		return nil
	end
	return records[posKey(x, y, z)]
end

--[[
	The drawn muzzle (world blocks) of the turret whose shot started at (ox, oy, oz) (a Shots
	record's origin: the server's muzzle, exactly its barrel from its pivot along its aim, as a
	float32). The shooter is the turret around there whose pivot is its barrel's length from the
	origin, within SHOOTER_SLACK; of two, the one whose barrel's end (where it is drawn, else at
	its record's aim) is nearer the origin. Its drawn barrel's end, whatever its drawn aim (which
	may lag the server's); nil when the shooter is not drawn or none is there.
]]
function TurretView.muzzleNear(ox: number, oy: number, oz: number): (number?, number?, number?)
	local bx, by, bz = math.floor(ox), math.floor(oy - TurretRules.PIVOT), math.floor(oz)
	local slack = SHOOTER_SLACK + (math.abs(ox) + math.abs(oy) + math.abs(oz)) * 2 ^ -24
	local shooter: Entry? = nil
	local bestMiss = math.huge
	for dy = -1, 1 do
		local y = by + dy
		if y >= 0 and y < HEIGHT then
			for dx = -1, 1 do
				for dz = -1, 1 do
					local entry = entries[posKey(bx + dx, y, bz + dz)]
					if entry then
						local barrel = entry.spec.barrel
						local px, py, pz = TurretRules.pivot(entry.x, entry.y, entry.z)
						local reach = math.sqrt((ox - px) ^ 2 + (oy - py) ^ 2 + (oz - pz) ^ 2)
						if math.abs(reach - barrel) <= slack then
							local yaw, pitch = entry.yaw, entry.pitch
							local record = records[entry.key]
							if entry.head == nil then
								-- (Not drawn: at its record's aim, idle without one.)
								yaw, pitch = 0, 0
								if record then
									yaw, pitch = record.yaw, record.pitch
								end
							end
							local mx, my, mz = TurretRules.muzzle(entry.x, entry.y, entry.z, yaw, pitch, barrel)
							local miss = (mx - ox) ^ 2 + (my - oy) ^ 2 + (mz - oz) ^ 2
							if miss < bestMiss then
								shooter, bestMiss = entry, miss
							end
						end
					end
				end
			end
		end
	end
	if shooter == nil or shooter.head == nil then
		return nil, nil, nil
	end
	local record = records[shooter.key]
	local look = TurretModel.look(shooter.spec, if record then record.flags else 0)
	return TurretModel.muzzle(look, shooter.x, shooter.y, shooter.z, shooter.yaw, shooter.pitch)
end

-- What the view holds now (see Stats).
function TurretView.stats(): Stats
	local tracking, parts = 0, 0
	for _, record in records do
		if bit32.btest(record.flags, Flag.Tracking) then
			tracking += 1
		end
	end
	for _, entry in drawn do
		local head = entry.head
		if head then
			parts += head.shown + (if head.beam > 0 then 1 else 0)
		end
	end
	return { drawn = #drawn, records = recordCount, tracking = tracking, parts = parts }
end

-- F3's turret line (Debug/DebugOverlay).
function TurretView.describe(): string
	local stats = TurretView.stats()
	return `turrets {stats.drawn} drawn / {stats.records} records, {stats.tracking} tracking, {stats.parts} parts`
end

return TurretView
