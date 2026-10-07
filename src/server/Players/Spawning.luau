--!strict
--[[
	Puts characters on a safe spot at the world spawn and publishes the spawn point so clients can
	start streaming terrain there before their character exists.

	The spawn column comes from the generator (dry land near the origin). Every spawn re-checks the
	spot against the real world (players may have built or poured water there) and searches nearby
	for a new one when it is no longer safe (rules in SpawnUnsafeBlocks).

	A saved world puts a returning player back where they were (World/WorldSave's `placement`,
	`setPlacement`): asked on every new character, it gives their saved feet and facing once (the
	first character after their record loaded); every other spawn is the world spawn.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)

local WorldServer = require(script.Parent.Parent.World.WorldServer)
local SafeSpot = require(script.Parent.SafeSpot)
local Characters = require(script.Parent.Characters)

local BLOCK = Config.BlockSize
-- The root part sits ~3 studs above the ground for default characters; add a little margin.
local ROOT_HEIGHT = 3.5
-- Seconds between searches while the spawn area has no safe spot.
local RETRY_DELAY = 30

local Spawning = {}

-- Where a player's next character stands instead of the spawn (feet in blocks, yaw in radians),
-- nil: the spawn (World/WorldSave: a saved player's place, once).
local placement: ((player: Player) -> (Vector3?, number?))? = nil

function Spawning.setPlacement(fn: ((player: Player) -> (Vector3?, number?))?)
	placement = fn
end

-- Studs position for a character root standing with its feet in block (x, y, z).
function Spawning.rootPosition(x: number, y: number, z: number): Vector3
	return Vector3.new((x + 0.5) * BLOCK, y * BLOCK + ROOT_HEIGHT, (z + 0.5) * BLOCK)
end

function Spawning.start(world: WorldServer.World)
	local sx, _, sz = world.generator.findSpawn()
	local spot: { number }? = nil
	-- When no safe spot exists nearby, searching again on every spawn would generate chunks and
	-- scan thousands of columns each time, so wait a while before the next search.
	local retryAt = -math.huge

	-- Feet block of the spawn (x, y, z).
	local function spawnSpot(): { number }
		local current = spot
		if
			current == nil or (os.clock() >= retryAt and not SafeSpot.isSafe(world, current[1], current[2], current[3]))
		then
			local x, y, z = SafeSpot.find(world, sx, sz)
			if x == nil then
				warn("[IceVoxel] no safe spawn found near the world spawn; using the top of its column")
				current = { sx, world:topBlock(sx, sz) + 1, sz }
				retryAt = os.clock() + RETRY_DELAY
			else
				current = { x, y, z }
				retryAt = -math.huge
			end
			spot = current
		end
		return current :: { number }
	end

	local first = spawnSpot()
	Shared:SetAttribute("SpawnPosition", Spawning.rootPosition(first[1], first[2], first[3]))

	local function onCharacter(player: Player, character: Model)
		local root = character:WaitForChild("HumanoidRootPart", 10)
		if root == nil then
			return
		end
		local place = placement
		local feet, yaw = nil, nil
		if place then
			feet, yaw = place(player)
		end
		if feet then
			-- (Facing first: the teleport keeps the rotation, and the client starts from it.)
			if yaw and root:IsA("BasePart") then
				character:PivotTo(CFrame.new(character:GetPivot().Position) * CFrame.Angles(0, yaw, 0))
			end
			Characters.teleportFeet(character, feet)
		else
			local s = spawnSpot()
			Shared:SetAttribute("SpawnPosition", Spawning.rootPosition(s[1], s[2], s[3]))
			Characters.teleport(character, s[1], s[2], s[3])
		end
	end

	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(function(character)
			onCharacter(player, character)
		end)
		if player.Character then
			task.spawn(onCharacter, player, player.Character)
		end
	end

	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
end

return Spawning
