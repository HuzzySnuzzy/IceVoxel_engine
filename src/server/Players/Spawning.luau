--!strict
--[[
	Puts characters on the surface at the world spawn (dry land near the origin, found from the
	generator) and publishes the spawn point so clients can start streaming terrain there before
	their character exists.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)

local WorldServer = require(script.Parent.Parent.World.WorldServer)

local BLOCK = Config.BlockSize

local Spawning = {}

function Spawning.start(world: WorldServer.World)
	local sx, _, sz = world.generator.findSpawn()

	local function spawnPosition(): Vector3
		local top = world:topBlock(sx, sz)
		-- Root part sits ~3 studs above the ground for default characters; add a little margin.
		return Vector3.new((sx + 0.5) * BLOCK, (top + 1) * BLOCK + 3.5, (sz + 0.5) * BLOCK)
	end

	Shared:SetAttribute("SpawnPosition", spawnPosition())

	local function onCharacter(character: Model)
		if character:WaitForChild("HumanoidRootPart", 10) then
			character:PivotTo(CFrame.new(spawnPosition()))
		end
	end

	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(onCharacter)
		if player.Character then
			task.spawn(onCharacter, player.Character)
		end
	end

	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
end

return Spawning
