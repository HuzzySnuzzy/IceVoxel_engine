--!strict
--[[
	Zombie rig probe (a LocalScript in StarterPlayer.StarterPlayerScripts of a copy of the IceVoxel
	place; Play, stand somewhere open, wait). Not part of the game, and not in the Rojo tree.

	Puts ZOMBIES zombies of every kind and look round the player (circles of 3 to 62 blocks,
	breathing in and out, walking both ways round, a fifth of them aggressive, every BURNING-th
	one on fire) and draws them with the game's own code (client Entities/MobRigPool and MobRig,
	and Entities/MobParts, MobRenderer's parts: real Parts, one BulkMoveTo a frame, the flames a
	Fire that MobRigPool moves from tier to tier), in its own folder, beside whatever the game
	draws. Each frame's whole rig update, the server updates' glides, tiers, poses, CFrames and
	the move, runs inside a MicroProfiler label (`IceVoxelZombieRigs`: Ctrl+F6, or the Developer
	Console's MicroProfiler on a phone), and is timed with os.clock. Two passes of MEASURE seconds
	after WARM_UP seconds each:
	  rigs    Config.Mobs.Rig as it is: 16 full and 24 reduced rigs, the rest as two boxes
	  boxes   every zombie its two boxes (MaxRigs 0): what the rigs add over the old drawing
	and one line each:

	   [ZombieRigProbe] pass | Lua ms median / p90 / max | frame ms mean / p90 | parts moved |
	                     full / reduced rigs | parts made after the warm-up | flames lost

	The Lua column is what the game's MobRenderer.draw adds a frame (the Lune specs measure the
	same work without CFrame.new and BulkMoveTo: tests/spec/MobRigPool's cost test); the frame
	columns, compared between the passes, show the engine's side (moving 464 parts, their
	shadows, drawing them). Parts moved is the most in one frame and the rigs are that frame's
	(16 full at most; reduced rigs take what is left of MaxRigs, 40, so 24 when 16 are full).
	`flames lost` counts frames a burning zombie's Fire was not on the part its tier burns on (0:
	MobRigPool's flames glue works on real Instances). Run it on a PC and on a low-end phone; the
	budget is 1.2 ms of Lua a frame and no part made after the warm-up (tools/probes/README.md).

	tests/spec/ZombieRigProbe runs this file in Lune on Lune's Roblox instances, with a stand-in
	clock, RenderStepped and BulkMoveTo, so it is known to finish and count right before it is
	run on a device (it measures no time there).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ZOMBIES = 60
local BURNING = 6
local WARM_UP = 10
local MEASURE = 30
local LABEL = "IceVoxelZombieRigs"

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared:WaitForChild("Config")) :: any
local MobList = require(Shared:WaitForChild("Entities"):WaitForChild("MobList")) :: any
local Origin = require(Shared:WaitForChild("World"):WaitForChild("Origin")) :: any
local Client = (Players.LocalPlayer :: Player):WaitForChild("PlayerScripts"):WaitForChild("IceVoxel")
local Entities = Client:WaitForChild("Entities")
local MobModel = require(Entities:WaitForChild("MobModel")) :: any
local MobParts = require(Entities:WaitForChild("MobParts")) :: any
local MobRigPool = require(Entities:WaitForChild("MobRigPool")) :: any

local BLOCK = Config.BlockSize

local folder = Instance.new("Folder")
folder.Name = "IceVoxelZombieRigProbe"
folder.Parent = workspace

-- The player's feet in world blocks (the camera's focus as a fallback).
local function centre(): (number, number, number)
	local character = (Players.LocalPlayer :: Player).Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local point = if root and root:IsA("BasePart")
		then root.Position - Vector3.new(0, 3, 0)
		else (workspace.CurrentCamera :: Camera).Focus.Position
	local x, y, z = Origin.renderToBlocks(point)
	return x, y, z
end

local function median(list: { number }, share: number): number
	table.sort(list)
	return list[math.max(1, math.floor(#list * share))] or 0
end

local function pass(name: string, settings: any)
	local pool = MobRigPool.new(MobParts.factory(folder), settings)
	local kinds = {}
	for _, kind in MobList.kinds do
		if kind.zombie then
			table.insert(kinds, kind)
		end
	end
	local cx, cy, cz = centre()
	local mobs = {}
	local function at(i: number, time: number): (number, number)
		local radius = math.max(1.5, 3 + (i - 1) + 12 * math.sin(0.3 * time + i))
		local angle = i * 0.7 + (if i % 2 == 0 then 1 else -1) * time * (0.05 + (i % 7) * 0.02)
		return cx + math.cos(angle) * radius, cz + math.sin(angle) * radius
	end
	local start = os.clock()
	for i = 1, ZOMBIES do
		local kind = kinds[(i - 1) % #kinds + 1]
		local variant = MobList.randomVariant(kind, math.random)
		local x, z = at(i, 0)
		local mob =
			MobModel.new(1000000 + i, kind, variant, { x = x, y = cy, z = z, yaw = 0, health = 20, flags = 0 }, start)
		mobs[i] = mob
		MobRigPool.add(pool, mob)
	end
	local fires: { [number]: Fire } = {}
	for i = BURNING, ZOMBIES, BURNING do
		local flames = MobParts.flames(mobs[i].kind.height)
		fires[i] = flames
		MobRigPool.setFlames(pool, mobs[i].id, flames)
	end
	local lost = 0
	local cframes: { CFrame } = {}
	local lua, frames = {}, {}
	local sync = 0
	local madeAtWarm: number? = nil
	local moved, full, reduced = 0, 0, 0
	local done = false
	local connection
	connection = RunService.RenderStepped:Connect(function(dt: number)
		local now = os.clock()
		local elapsed = now - start
		debug.profilebegin(LABEL)
		local begin = os.clock()
		while sync <= elapsed do
			for i, mob in mobs do
				local x, z = at(i, sync)
				local flags = if i % 5 == 0 then MobModel.AGGRESSIVE else 0
				local yaw = math.atan2(x - mob.x, z - mob.z)
				MobModel.apply(mob, { x = x, y = cy, z = z, yaw = yaw, health = 20, flags = flags }, start + sync)
			end
			sync += 0.1
		end
		MobRigPool.frame(pool, now, cx, cy + 1, cz, Origin.x, Origin.z)
		MobParts.move(pool, cframes)
		local ms = (os.clock() - begin) * 1000
		debug.profileend()
		for i, flames in fires do
			if flames.Parent == nil or flames.Parent ~= MobRigPool.anchor(pool.entries[mobs[i].id]) then
				lost += 1
			end
		end
		if elapsed >= WARM_UP and madeAtWarm == nil then
			madeAtWarm = pool.created
		end
		if elapsed >= WARM_UP and elapsed < WARM_UP + MEASURE then
			table.insert(lua, ms)
			table.insert(frames, dt * 1000)
			if pool.count > moved then
				moved, full, reduced = pool.count, pool.fullRigs, pool.reducedRigs
			end
		elseif elapsed >= WARM_UP + MEASURE then
			done = true
		end
	end)
	while not done do
		task.wait(0.5)
	end
	connection:Disconnect()
	local frameTotal = 0
	for _, ms in frames do
		frameTotal += ms
	end
	print(
		string.format(
			"[ZombieRigProbe] %-5s | Lua ms %.3f / %.3f / %.3f | frame ms %.2f / %.2f | %d parts moved | %d / %d rigs | %d parts made after the warm-up | %d flames lost",
			name,
			median(table.clone(lua), 0.5),
			median(table.clone(lua), 0.9),
			median(table.clone(lua), 1),
			frameTotal / math.max(1, #frames),
			median(frames, 0.9),
			moved,
			full,
			reduced,
			pool.created - (madeAtWarm or 0),
			lost
		)
	)
	MobRigPool.clear(pool)
	for _, flames in fires do
		flames:Destroy()
	end
end

task.wait(5)
pass("rigs", Config.Mobs.Rig)
local boxes = table.clone(Config.Mobs.Rig)
boxes.MaxRigs = 0
boxes.MaxFull = 0
pass("boxes", boxes)
folder:Destroy()
print("[ZombieRigProbe] done (BLOCK " .. BLOCK .. " studs)")
