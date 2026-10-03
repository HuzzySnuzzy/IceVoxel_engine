--!strict
--[[
	Terrain is generated on the client, so a fresh character could fall through the world before
	the ground under it is built. This keeps the character anchored (locally; the client owns its
	character's physics) until the full detail chunk under it is visible.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)

local BLOCK = Config.BlockSize
-- The server moves new characters to the spawn point; don't trust positions far from it at first.
local SETTLE_TIME = 3
local GIVE_UP = 30

type Streamer = { isReady: (self: any, x: number, z: number) -> boolean }

local SpawnGuard = {}

function SpawnGuard.start(streamer: Streamer)
	local function guard(character: Model)
		local root = character:WaitForChild("HumanoidRootPart", 10)
		if root == nil or not root:IsA("BasePart") then
			return
		end
		root.Anchored = true
		local started = os.clock()
		while character.Parent and os.clock() - started < GIVE_UP do
			local position = root.Position
			local spawn = Shared:GetAttribute("SpawnPosition")
			local settled = os.clock() - started > SETTLE_TIME
				or typeof(spawn) ~= "Vector3"
				or (position - spawn).Magnitude < 40
			if settled and streamer:isReady(math.floor(position.X / BLOCK), math.floor(position.Z / BLOCK)) then
				break
			end
			task.wait(0.1)
		end
		root.Anchored = false
	end

	local player = Players.LocalPlayer
	player.CharacterAdded:Connect(guard)
	if player.Character then
		task.spawn(guard, player.Character)
	end
end

return SpawnGuard
