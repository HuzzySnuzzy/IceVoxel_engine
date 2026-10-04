--!strict
--[[
	Terrain is generated on the client, so a fresh or teleported character could fall through the
	world before the ground under it is built. This keeps the character anchored (locally; the
	client owns its character's physics) until the full detail chunks under and around it are
	visible.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)

local BLOCK = Config.BlockSize
-- The server moves new characters to the spawn point; don't trust positions far from it at first.
local SETTLE_TIME = 3
local GIVE_UP = 30
-- A jump further than this (studs per 0.1 s) is treated as a teleport.
local TELEPORT_DISTANCE = 150

type Streamer = { isReady: (self: any, x: number, z: number) -> boolean }

local SpawnGuard = {}

function SpawnGuard.start(streamer: Streamer)
	local guarding = false

	local function ready(root: BasePart): boolean
		local position = root.Position
		return streamer:isReady(math.floor(position.X / BLOCK), math.floor(position.Z / BLOCK))
	end

	-- Anchors the root until the ground under it is visible. `settle` also waits for the server to
	-- move a fresh character to the spawn point first.
	local function hold(character: Model, root: BasePart, settle: boolean)
		guarding = true
		root.Anchored = true
		local started = os.clock()
		while character.Parent and os.clock() - started < GIVE_UP do
			local spawn = Shared:GetAttribute("SpawnPosition")
			local settled = not settle
				or os.clock() - started > SETTLE_TIME
				or typeof(spawn) ~= "Vector3"
				or (root.Position - spawn).Magnitude < 40
			if settled and ready(root) then
				break
			end
			task.wait(0.1)
		end
		root.Anchored = false
		guarding = false
	end

	local function watch(character: Model)
		local root = character:WaitForChild("HumanoidRootPart", 10)
		if root == nil or not root:IsA("BasePart") then
			return
		end
		hold(character, root, true)

		-- Teleports (map, server scripts) land in terrain that may not exist yet either.
		local last = root.Position
		while character.Parent do
			task.wait(0.1)
			local position = root.Position
			if not guarding and (position - last).Magnitude > TELEPORT_DISTANCE and not ready(root) then
				hold(character, root, false)
				position = root.Position
			end
			last = position
		end
	end

	local player = Players.LocalPlayer
	player.CharacterAdded:Connect(watch)
	if player.Character then
		task.spawn(watch, player.Character)
	end
end

return SpawnGuard
