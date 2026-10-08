--[[
	UnionProbe: settles the numbers the Lune measurements of CSG unions for chunks could only
	estimate (tools/probes/README.md). Not part of the game, and not in the Rojo tree.

	Setup (a copy of the IceVoxel place, or any place with MaterialService.IceVoxel):
	  1. UnionProbeSections.luau -> ModuleScript ReplicatedStorage.UnionProbeSections
	  2. this file     -> LocalScript in StarterPlayerScripts (CSG on the client needs client-made parts)
	  3. Play (or a published test place, on a phone too), open the Developer Console (F9) and read
	     the "[UnionProbe]" lines; Shift+F2 shows draw calls while both copies are on screen.

	For each real section (seed 12345, mountains) and each look in it: builds the boxes as Parts,
	unions them with GeometryService:UnionAsync (Precise render fidelity, Box collision, one
	result), and prints the wall time, the worst frame during the call, the union's TriangleCount,
	and whether it failed. Then it re-unions one look with a box removed (what a block edit costs),
	and compares client memory for the parts against the unions. The parts stay on the left
	(x < 0), the unions on the right, both with the look's MaterialVariant, to check by eye whether
	textures still tile one per block on the unions (box-mapped UVs).
]]

local GeometryService = game:GetService("GeometryService")
local MaterialService = game:GetService("MaterialService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")

local sections = require(ReplicatedStorage:WaitForChild("UnionProbeSections"))
local BLOCK = 3
local OPTIONS = {
	RenderFidelity = Enum.RenderFidelity.Precise,
	CollisionFidelity = Enum.CollisionFidelity.Box,
	SplitApart = false,
}

local worst = 0
RunService.Heartbeat:Connect(function(dt)
	worst = math.max(worst, dt)
end)

local partsFolder = Instance.new("Folder")
partsFolder.Name = "UnionProbeParts"
partsFolder.Parent = workspace
local unionFolder = Instance.new("Folder")
unionFolder.Name = "UnionProbeUnions"
unionFolder.Parent = workspace

local function variantOf(look: string): string?
	local texture = string.split(look, "|")[1]
	local name = "IV_" .. string.gsub(texture, " ", "_")
	local folder = MaterialService:FindFirstChild("IceVoxel")
	return if folder and folder:FindFirstChild(name) then name else nil
end

local function makeParts(list: { { number } }, look: string, origin: Vector3): { BasePart }
	local fields = string.split(look, "|")
	local material = (Enum.Material :: any)[fields[2]] or Enum.Material.SmoothPlastic
	local variant = variantOf(look)
	local parts = {}
	for _, b in list do
		local p = Instance.new("Part")
		p.Anchored = true
		p.Material = material
		if variant then
			p.MaterialVariant = variant
		end
		p.Transparency = tonumber(fields[3]) or 0
		p.Color = Color3.fromRGB(b[7], b[8], b[9])
		local size = Vector3.new(b[4], b[5], b[6])
		p.Size = size * BLOCK
		p.CFrame = CFrame.new(origin + (Vector3.new(b[1], b[2] - 512, b[3]) + size / 2) * BLOCK)
		table.insert(parts, p)
	end
	return parts
end

local function union(parts: { BasePart }): (BasePart?, number, number, string?)
	local others = table.move(parts, 2, #parts, 1, {})
	worst = 0
	local t0 = os.clock()
	local ok, result = pcall(GeometryService.UnionAsync, GeometryService, parts[1], others, OPTIONS)
	local wall = os.clock() - t0
	if not ok then
		return nil, wall, worst, tostring(result)
	end
	return result[1], wall, worst, nil
end

task.wait(8) -- let the place settle
local memBefore = Stats:GetTotalMemoryUsageMb()
local partCount, unionCount, triangles, totalWall = 0, 0, 0, 0
local slowest = 0
local sample: any = nil
for i, section in sections do
	for look, list in section do
		local origin = Vector3.new(-200 - i * 60, 0, 0)
		local shown = makeParts(list, look, origin)
		for _, p in shown do
			p.Parent = partsFolder
		end
		partCount += #shown
		local inputs = makeParts(list, look, origin + Vector3.new(400 + i * 120, 0, 0))
		local result, wall, frame, err = union(inputs)
		totalWall += wall
		slowest = math.max(slowest, wall)
		if result then
			result.Parent = unionFolder
			unionCount += 1
			triangles += (result :: any).TriangleCount
			print(
				string.format(
					"[UnionProbe] section %d %-28s %3d boxes -> %5d tris in %6.1f ms (worst frame %5.1f ms)",
					i,
					look,
					#list,
					(result :: any).TriangleCount,
					wall * 1000,
					frame * 1000
				)
			)
			if #list >= 30 and sample == nil then
				sample = { list = list, look = look, origin = origin + Vector3.new(400 + i * 120, 0, 0) }
			end
		else
			warn(`[UnionProbe] section {i} {look} {#list} boxes FAILED after {math.floor(wall * 1000)} ms: {err}`)
		end
		for _, p in inputs do
			p:Destroy()
		end
	end
end
print(
	string.format(
		"[UnionProbe] %d parts -> %d unions, %d triangles; union time total %.0f ms, slowest %.0f ms",
		partCount,
		unionCount,
		triangles,
		totalWall * 1000,
		slowest * 1000
	)
)

-- A block edit: the same look with one box gone, re-unioned from scratch.
if sample then
	local edited = table.move(sample.list, 2, #sample.list, 1, {})
	local inputs = makeParts(edited, sample.look, sample.origin + Vector3.new(0, 0, 120))
	local result, wall, frame, err = union(inputs)
	print(
		string.format(
			"[UnionProbe] edit re-union of %d boxes: %.1f ms (worst frame %.1f ms) %s",
			#edited,
			wall * 1000,
			frame * 1000,
			err or ""
		)
	)
	if result then
		result.Parent = unionFolder
	end
	for _, p in inputs do
		p:Destroy()
	end
end

task.wait(3)
print(
	string.format(
		"[UnionProbe] client memory %.1f MB -> %.1f MB (parts + unions)",
		memBefore,
		Stats:GetTotalMemoryUsageMb()
	)
)
for _, tag in
	{
		Enum.DeveloperMemoryTag.Instances,
		Enum.DeveloperMemoryTag.BaseParts,
		Enum.DeveloperMemoryTag.GraphicsParts,
		Enum.DeveloperMemoryTag.GraphicsSolidModels,
		Enum.DeveloperMemoryTag.GeometryCSG,
		Enum.DeveloperMemoryTag.PhysicsCollision,
	}
do
	print(string.format("[UnionProbe]   %s %.1f MB", tag.Name, Stats:GetMemoryUsageMbForTag(tag)))
end
partsFolder.Parent = nil
task.wait(3)
print(
	string.format(
		"[UnionProbe] without the parts: %.1f MB, GraphicsSolidModels %.1f MB",
		Stats:GetTotalMemoryUsageMb(),
		Stats:GetMemoryUsageMbForTag(Enum.DeveloperMemoryTag.GraphicsSolidModels)
	)
)
partsFolder.Parent = workspace
