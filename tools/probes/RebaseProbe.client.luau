--!strict
--[[
	Floating-origin rebase probe (Studio or a live client; put it in StarterPlayerScripts, or paste
	it into the command bar in Play mode as a LocalScript body). Not part of the game, and not in
	the Rojo tree.

	Builds N anchored parts like the terrain renderer's (boxes 3-48 studs, spread over the default
	view, about half CanQuery like near terrain), lets them render, then times one rebase:
	  gather   read every part's CFrame and subtract the shift (the Luau side)
	  move     workspace:BulkMoveTo(parts, cframes, FireCFrameChanged)
	  after    the frame times (RenderStepped dt) of the next 30 frames against 30 frames before
	for N = 17k, 35k, 80k and 140k (parts on screen from the spawn with far meshes up to
	underground in the highest mountains, docs/ARCHITECTURE.md). Prints a table. Run it on a PC
	and on a phone; the results pick Config.Origin's distances (tools/probes/README.md).
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

-- Frame times (ms) of the next `n` frames.
local function frames(n: number): (number, number)
	local total, worst = 0, 0
	for _ = 1, n do
		local dt = RunService.RenderStepped:Wait() * 1000
		total += dt
		worst = math.max(worst, dt)
	end
	return total / n, worst
end

print("[RebaseProbe] parts | gather ms | BulkMoveTo ms | frames before mean/max | after mean/max")
local sign = 1
for _, count in COUNTS do
	grow(count)
	-- Let the new parts settle (render clusters, lighting).
	for _ = 1, 120 do
		RunService.RenderStepped:Wait()
	end
	local beforeMean, beforeMax = frames(30)
	local delta = SHIFT * sign
	local t0 = os.clock()
	local cframes = table.create(#parts)
	for i, part in parts do
		cframes[i] = part.CFrame - delta
	end
	local t1 = os.clock()
	workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	local t2 = os.clock()
	local afterMean, afterMax = frames(30)
	print(
		string.format(
			"[RebaseProbe] %6d | %7.2f | %7.2f | %5.1f / %5.1f | %5.1f / %5.1f",
			#parts,
			(t1 - t0) * 1000,
			(t2 - t1) * 1000,
			beforeMean,
			beforeMax,
			afterMean,
			afterMax
		)
	)
	sign = -sign
end
folder:Destroy()
print("[RebaseProbe] done")
