--!strict
--[[
	Puts characters on a safe spot at the world spawn and publishes the spawn point so clients can
	start streaming terrain there before their character exists.

	The spawn column comes from the generator (dry land near the origin). Every spawn re-checks the
	spot against the real world (players may have built or poured water there) and searches nearby
	for a new one when it is no longer safe (rules in SpawnUnsafeBlocks).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)

local WorldServer = require(script.Parent.Parent.World.WorldServer)
local SafeSpot = require(script.Parent.SafeSpot)

local BLOCK = Config.BlockSize
-- The root part sits ~3 studs above the ground for default characters; add a little margin.
local ROOT_HEIGHT = 3.5

local Spawning = {}

-- Studs position for a character root standing with its feet in block (x, y, z).
function Spawning.rootPosition(x: number, y: number, z: number): Vector3
	return Vector3.new((x + 0.5) * BLOCK, y * BLOCK + ROOT_HEIGHT, (z + 0.5) * BLOCK)
end

function Spawning.start(world: WorldServer.World)
	local sx, _, sz = world.generator.findSpawn()
	local spot: { number }? = nil

	local function spawnPosition(): Vector3
		if spot == nil or not SafeSpot.isSafe(world, spot[1], spot[2], spot[3]) then
			local x, y, z = SafeSpot.find(world, sx, sz)
			if x == nil then
				warn("[IceVoxel] no safe spawn found near the world spawn; using the top of its column")
				spot = { sx, world:topBlock(sx, sz) + 1, sz }
			else
				spot = { x, y, z }
			end
		end
		local s = spot :: { number }
		return Spawning.rootPosition(s[1], s[2], s[3])
	end

	Shared:SetAttribute("SpawnPosition", spawnPosition())

	local function onCharacter(character: Model)
		if character:WaitForChild("HumanoidRootPart", 10) then
			local position = spawnPosition()
			Shared:SetAttribute("SpawnPosition", position)
			character:PivotTo(CFrame.new(position))
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
