--!strict
--[[
	Server side of the cosmetic characters.

	Players move as a Minecraft-style hull on their own client (Player/MovementController); the
	Roblox character only shows where the hull is. So on the server:
	  * every character part goes into a collision group that collides with nothing (Rig), so Roblox
	    physics never pushes characters around; a dead character's parts go back to Default so the
	    body falls onto the terrain,
	  * `teleport` moves a character and tells its client the exact feet position (attributes), so
	    the hull moves with it,
	  * landings reported by the client turn into fall damage (Config.Movement.FallDamage), like
	    Minecraft: ceil(distance - 3) half hearts of 20, scaled to the Humanoid's MaxHealth.
	    Survival players only: creative players never take fall damage (they may fly).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Protocol = require(Shared.Net.Protocol)
local Rig = require(Shared.Movement.Rig)

local ServerNet = require(script.Parent.Parent.Network.ServerNet)

local BLOCK = Config.BlockSize
-- Minecraft players have 20 health points (half hearts) and take damage from falls past 3 blocks.
local MINECRAFT_HEALTH = 20
local SAFE_FALL = 3
-- Landings a player may report per second (a real one needs a fall first).
local MAX_LANDINGS_PER_SECOND = 4

local Characters = {}

local function setGroup(part: Instance, group: string)
	if part:IsA("BasePart") then
		part.CollisionGroup = group
	end
end

--[[
	Moves a character so its feet stand centred on block (x, y, z) (y = the block the feet are in),
	keeping its rotation, and tells its client where the hull now is.
]]
function Characters.teleport(character: Model, x: number, y: number, z: number)
	local feet = Vector3.new(x + 0.5, y, z + 0.5)
	local root = character:FindFirstChild("HumanoidRootPart")
	local rotation = if root and root:IsA("BasePart") then root.CFrame.Rotation else CFrame.identity
	local position = feet * BLOCK + Vector3.new(0, Rig.rootOffset(character), 0)
	character:PivotTo(CFrame.new(position) * rotation)
	character:SetAttribute(Rig.TELEPORT_FEET, feet)
	character:SetAttribute(Rig.TELEPORT_COUNT, ((character:GetAttribute(Rig.TELEPORT_COUNT) :: number?) or 0) + 1)
end

function Characters.start(net: ServerNet.ServerNet)
	if not workspace:IsCollisionGroupRegistered(Rig.COLLISION_GROUP) then
		workspace:RegisterCollisionGroup(Rig.COLLISION_GROUP)
	end
	-- Every group registered so far (Default, this one, a game's own); groups registered later
	-- collide with characters unless the game turns that off itself.
	for _, group in workspace:GetRegisteredCollisionGroups() do
		workspace:CollisionGroupSetCollidable(Rig.COLLISION_GROUP, group.name, false)
	end

	local function onCharacter(character: Model)
		for _, part in character:GetDescendants() do
			setGroup(part, Rig.COLLISION_GROUP)
		end
		local added = character.DescendantAdded:Connect(function(part)
			setGroup(part, Rig.COLLISION_GROUP)
		end)
		-- Parts leaving the character (a dropped tool) collide normally again.
		local removing = character.DescendantRemoving:Connect(function(part)
			setGroup(part, "Default")
		end)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") then
			humanoid.Died:Connect(function()
				added:Disconnect()
				removing:Disconnect()
				for _, part in character:GetDescendants() do
					setGroup(part, "Default")
				end
			end)
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

	-- Fall damage reported by the client when it lands.
	local landings: { [Player]: { count: number, since: number } } = {}
	net.on(Protocol.ClientMessage.Fall, function(player: Player, payload: buffer)
		if not Config.Movement.FallDamage or GameMode.of(player) ~= GameMode.SURVIVAL then
			return
		end
		local distance = Protocol.decodeFall(payload)
		if distance == nil then
			return
		end
		local now = os.clock()
		local rate = landings[player]
		if rate == nil or now - rate.since >= 1 then
			rate = { count = 0, since = now }
			landings[player] = rate
		end
		rate.count += 1
		if rate.count > MAX_LANDINGS_PER_SECOND then
			return
		end
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid == nil or humanoid.Health <= 0 then
			return
		end
		local halfHearts = math.ceil(distance - SAFE_FALL)
		if halfHearts > 0 then
			-- TakeDamage respects ForceFields (e.g. spawn protection).
			humanoid:TakeDamage(halfHearts / MINECRAFT_HEALTH * humanoid.MaxHealth)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		landings[player] = nil
	end)
end

return Characters
