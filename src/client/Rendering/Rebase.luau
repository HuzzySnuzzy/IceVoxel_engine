--!strict
--[[
	Moves the client's render origin (Shared/World/Origin) and everything placed in its frame, in one
	render step, so far from the world's 0 the camera and what is near it stay within 8192 studs of
	the origin (float32: 1/1024 stud) instead of losing precision (a quarter stud at a million
	blocks: jitter, cracks between parts).

	When (Origin.plan / planTo, Config.Origin):
	  hard      the camera farther than RebaseDistance (8192 studs, 2731 blocks) from the origin
	            along X or Z: at once, a hitch about every 2600 blocks of travel;
	  soft      farther than SoftDistance (3072) while something hides a hitch: `setHidden(reason,
	            true)` from the world map, inventory screens, menus, the death screen, the
	            streamer's teleport mode;
	  teleport  `request(destination)` (a teleport, a respawn): the origin goes to the destination
	            at the next step, before the hull snaps and the character is placed there.
	With Config.Origin.Enabled false nothing ever moves (the step returns at once).

	How (one RenderStepped step, "IceVoxelOrigin" at Camera - 3 (197): before the remote players
	(198), the local character (199), the camera (200) and everything that draws from world
	positions after them):
	  1. plan (a pending request first, else the camera's render position);
	  2. Origin.set: its listeners shift caches (Origin.onRebase);
	  3. every registered mover appends (part, part.CFrame - d) for its parented parts that stay
	     where they were put (two arrays reused from move to move; no de-duplication: walks visit
	     each part once), and may move what isn't a part (PivotTo models, attachments);
	  4. one workspace:BulkMoveTo(parts, cframes, FireCFrameChanged);
	  5. the camera's CFrame and Focus - d (CameraModule then follows its subject like a teleport);
	  6. stats and one line: "[IceVoxel] origin moved by (dx, dz) studs: N parts in T ms".
	The engine draws once after RenderStepped, so no frame shows the world half moved. A mover that
	errors is warned about and its parts are left out (the others still move).

	Movers (Rebase.register) come from the renderers that place parts once: terrain, far meshes,
	pipes, fire, structure boxes, weather, waypoints...; per-frame writers (characters, items, mobs,
	held items) only convert and need none. Unparented containers are fixed when shown (their
	owners compare the origin they were placed for with Origin's).

	`workspace` and RunService are touched only in `start`, `step` and `perform` (specs load this
	module with fakes).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Origin = require(Shared.World.Origin)

local Settings = Config.Origin
-- Camera - 3: before every placement in the frame (see the header).
local RENDER_STEP = "IceVoxelOrigin"
local RENDER_OFFSET = -3

-- Appends (part, part.CFrame - Vector3.new(dx, 0, dz)) to `parts` and `cframes` for every
-- parented part it keeps in place; may also move what isn't a part.
export type Mover = (dx: number, dz: number, parts: { BasePart }, cframes: { CFrame }) -> ()

export type Stats = {
	-- Origin's epoch and where it is (world studs).
	epoch: number,
	x: number,
	z: number,
	-- Moves so far, and the last one's time (ms) and parts.
	count: number,
	lastMs: number,
	lastParts: number,
}

local Rebase = {}

local movers: { { name: string, mover: Mover } } = {}
local hiddenReasons: { [string]: boolean } = {}
local hiddenCount = 0
local requestX: number? = nil
local requestZ: number? = nil
local forced = false
local started = false
-- Reused by every move (cleared after, so no part is kept alive).
local parts: { BasePart } = {}
local cframes: { CFrame } = {}
local stats: Stats = { epoch = 0, x = 0, z = 0, count = 0, lastMs = 0, lastParts = 0 }

-- Adds a mover, called at every move in the order registered; returns its removal.
function Rebase.register(name: string, mover: Mover): () -> ()
	local entry = { name = name, mover = mover }
	table.insert(movers, entry)
	return function()
		local index = table.find(movers, entry)
		if index then
			table.remove(movers, index)
		end
	end
end

-- Something that hides a hitch is showing (`reason`: "map", "screen", "menu", "teleport", "dead")
-- or not any more: while any is, the origin moves at SoftDistance.
function Rebase.setHidden(reason: string, on: boolean)
	local was = hiddenReasons[reason] == true
	if on == was then
		return
	end
	if on then
		hiddenReasons[reason] = true
		hiddenCount += 1
	else
		hiddenReasons[reason] = nil
		hiddenCount -= 1
	end
end

-- Is a hitch hidden now?
function Rebase.hidden(): boolean
	return hiddenCount > 0
end

-- A teleport or respawn to world studs (x, z): at the next step the origin goes there when it is
-- farther than SoftDistance (before the camera's own plan).
function Rebase.request(worldStudsX: number, worldStudsZ: number)
	requestX, requestZ = worldStudsX, worldStudsZ
end

-- Debug: move the origin at the next step, under the camera (or by one snap along X when it is
-- under the camera already), to see a move happen.
function Rebase.now()
	forced = true
end

-- The moves so far (the same table every call: read it, don't change it).
function Rebase.stats(): Stats
	stats.epoch, stats.x, stats.z = Origin.epoch, Origin.x, Origin.z
	return stats
end

--[[
	Moves the origin to world studs (nx, nz) and everything in its frame with it (steps 2-6 of the
	header); `camera` is shifted too. Returns the move (0, 0 when it was there already).
]]
function Rebase.perform(nx: number, nz: number, camera: Camera?): (number, number)
	local t0 = os.clock()
	local dx, dz = Origin.set(nx, nz)
	if dx == 0 and dz == 0 then
		return 0, 0
	end
	local d = Vector3.new(dx, 0, dz)
	for _, entry in movers do
		local before = #parts
		local ok, problem = pcall(function(): any
			entry.mover(dx, dz, parts, cframes)
			return nil
		end)
		if not ok or #cframes ~= #parts then
			warn(`[IceVoxel] origin mover {entry.name} failed: {if ok then "unpaired parts" else problem}`)
			-- (Its parts stay where they are rather than moving a misaligned list.)
			for i = #parts, before + 1, -1 do
				parts[i] = nil
			end
			for i = #cframes, before + 1, -1 do
				cframes[i] = nil
			end
		end
	end
	local count = #parts
	if count > 0 then
		workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
	table.clear(parts)
	table.clear(cframes)
	if camera then
		camera.CFrame = camera.CFrame - d
		camera.Focus = camera.Focus - d
	end
	local ms = (os.clock() - t0) * 1000
	stats.count += 1
	stats.lastMs, stats.lastParts = ms, count
	print(`[IceVoxel] origin moved by ({dx}, {dz}) studs: {count} parts in {string.format("%.1f", ms)} ms`)
	return dx, dz
end

-- One step (the render step's body): plans a move and performs it.
function Rebase.step()
	if not Settings.Enabled then
		requestX, requestZ, forced = nil, nil, false
		return
	end
	local camera = workspace.CurrentCamera
	local nx, nz = nil, nil
	if requestX and requestZ then
		nx, nz = Origin.planTo(requestX, requestZ)
	end
	if nx == nil and camera then
		local position = camera.CFrame.Position
		nx, nz = Origin.plan(position.X, position.Z, hiddenCount > 0)
		if nx == nil and forced then
			nx, nz = Origin.snap(Origin.x + position.X), Origin.snap(Origin.z + position.Z)
			if nx == Origin.x and nz == Origin.z then
				nx = Origin.x + Settings.Snap
			end
		end
	end
	requestX, requestZ, forced = nil, nil, false
	if nx == nil or nz == nil then
		return
	end
	Rebase.perform(nx, nz, camera)
end

-- Binds the step (once, in the world).
function Rebase.start()
	if started then
		return
	end
	started = true
	local RunService = game:GetService("RunService")
	RunService:BindToRenderStep(RENDER_STEP, Enum.RenderPriority.Camera.Value + RENDER_OFFSET, Rebase.step)
end

return Rebase
