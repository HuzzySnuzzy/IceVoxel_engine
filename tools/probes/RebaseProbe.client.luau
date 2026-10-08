--!strict
--[[
	Floating-origin rebase probe (Studio or a live client; put it in StarterPlayerScripts, or paste
	it into the command bar in Play mode as a LocalScript body). Not part of the game, and not in
	the Rojo tree.

	Builds N anchored parts like the terrain renderer's (boxes 3-48 studs, spread over the default
	view, about half CanQuery like near terrain), looks over them from a fixed camera, lets
	them render, then times one rebase as Rendering/Rebase does it, the camera moved with the parts
	(so the frames after it draw the same scene):
	  gather   read every part's CFrame and subtract the shift (the Luau side)
	  move     workspace:BulkMoveTo(parts, cframes, FireCFrameChanged)
	  frames   the frame times (RenderStepped dt) of the 30 frames after it against 30 before. The
	           gather and the move run inside a RenderStepped, so the first frame after already
	           holds them; the second holds what the engine left for later (broadphase, render
	           clusters, lighting).
	  hitch    what the first two frames took beyond the mean before: the move's whole cost, never
	           add gather and move to it again.
	for N = 17k, 35k, 80k and 140k (parts on screen from the spawn with far meshes up to
	underground in the highest mountains, docs/ARCHITECTURE.md). Prints a table. Run it on a PC
	and on a phone; the hitch picks Config.Origin's distances (tools/probes/README.md).
]]

local RunService = game:GetService("RunService")

local COUNTS = { 17000, 35000, 80000, 140000 }
local SHIFT = Vector3.new(7680, 0, -7680)
local SPREAD = 6144

local folder = Instance.new("Folder")
folder.Name = "IceVoxelRebaseProbe"
folder.Parent = workspace

local random = Random.new(12345)
local parts: { BasePart } = {}

local function grow(count: number)
	while #parts < count do
		local part = Instance.new("Part")
		part.Anchored = true
		part.CanTouch = false
		-- (Near solid terrain collides and is queried, PartPool's templates; far terrain neither.)
		part.CanQuery = random:NextNumber() < 0.5
		part.CanCollide = part.CanQuery
		part.CastShadow = random:NextNumber() < 0.7
		local w = 3 * random:NextInteger(1, 16)
		part.Size = Vector3.new(w, 3 * random:NextInteger(1, 4), 3 * random:NextInteger(1, 16))
		part.CFrame = CFrame.new(
			3 * random:NextInteger(-SPREAD // 3, SPREAD // 3),
			3 * random:NextInteger(0, 300),
			3 * random:NextInteger(-SPREAD // 3, SPREAD // 3)
		)
		part.Color = Color3.fromHSV(random:NextNumber(), 0.4, 0.8)
		part.Parent = folder
		table.insert(parts, part)
	end
end

-- Frame times (ms) of the next `n` frames, into `out`; returns their mean and the worst.
local function frames(n: number, out: { number }): (number, number)
	table.clear(out)
	local total, worst = 0, 0
	for i = 1, n do
		local dt = RunService.RenderStepped:Wait() * 1000
		out[i] = dt
		total += dt
		worst = math.max(worst, dt)
	end
	return total / n, worst
end

-- A fixed view over the parts, written after every camera script each frame (the game's camera
-- follows the moved world the same way: Rebase moves its CFrame and Focus with the parts).
local camera = workspace.CurrentCamera
local cameraType = camera.CameraType
local view = CFrame.lookAt(Vector3.new(0, 300, 0), Vector3.new(600, 150, 600))
local CAMERA_STEP = "IceVoxelRebaseProbeCamera"
RunService:BindToRenderStep(CAMERA_STEP, Enum.RenderPriority.Camera.Value + 10, function()
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = view
	camera.Focus = view
end)

print("[RebaseProbe] parts | gather ms | BulkMoveTo ms | before mean/max | after: 1st, 2nd, rest max | hitch ms")
local before: { number } = {}
local after: { number } = {}
local sign = 1
for _, count in COUNTS do
	grow(count)
	-- Let the new parts settle (render clusters, lighting).
	for _ = 1, 120 do
		RunService.RenderStepped:Wait()
	end
	local beforeMean, beforeMax = frames(30, before)
	-- (Inside this RenderStepped, as Rebase's step.)
	local delta = SHIFT * sign
	local t0 = os.clock()
	local cframes = table.create(#parts)
	for i, part in parts do
		cframes[i] = part.CFrame - delta
	end
	local t1 = os.clock()
	workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	local t2 = os.clock()
	view -= delta
	camera.CFrame = view
	camera.Focus = view
	frames(30, after)
	local rest = 0
	for i = 3, #after do
		rest = math.max(rest, after[i])
	end
	local hitch = math.max(0, after[1] - beforeMean) + math.max(0, after[2] - beforeMean)
	print(
		string.format(
			"[RebaseProbe] %6d | %7.2f | %7.2f | %5.1f / %5.1f | %5.1f, %5.1f, %5.1f | %6.1f",
			#parts,
			(t1 - t0) * 1000,
			(t2 - t1) * 1000,
			beforeMean,
			beforeMax,
			after[1],
			after[2],
			rest,
			hitch
		)
	)
	sign = -sign
end
folder:Destroy()
RunService:UnbindFromRenderStep(CAMERA_STEP)
camera.CameraType = cameraType
print("[RebaseProbe] done")
