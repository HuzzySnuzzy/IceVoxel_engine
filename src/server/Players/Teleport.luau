--!strict
--[[
	Teleports players ask for:

	  Map        Teleport messages from the world map. The server decides: permission
	             (Config.Map.Teleport), cooldown, and a safe landing spot near the requested column
	             (SafeSpot / SpawnUnsafeBlocks).
	  Spectator  SpectatorTeleport messages (the spectator menu's "Teleport to Player", Minecraft's
	             handleTeleportToEntityPacket): a spectator goes to another player's feet, exactly
	             (no safe spot: spectators fly through everything), the target in the game with a
	             character (GameModeRules.spectatorTeleport), at most one every
	             SPECTATOR_COOLDOWN seconds. The spectator keeps looking where they looked.

	Positions are Players/PlayerPositions' (feet, blocks, doubles), and the teleports go through it
	(Players/Characters): the player alone is told where they now are.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Protocol = require(Shared.Net.Protocol)

local WorldServer = require(script.Parent.Parent.World.WorldServer)
local ServerNet = require(script.Parent.Parent.Network.ServerNet)
local SafeSpot = require(script.Parent.SafeSpot)
local Characters = require(script.Parent.Characters)
local GameModeRules = require(script.Parent.GameModeRules)
local PlayerPositions = require(script.Parent.PlayerPositions)

-- Blocks around the requested column searched for a safe spot.
local LANDING_RADIUS = 24
-- Seconds between one spectator's teleports to players (each moves their character and its
-- client's hull, and streams the world around the target).
local SPECTATOR_COOLDOWN = 0.25

local Teleport = {}

function Teleport.allowed(player: Player): boolean
	local rule = Config.Map.Teleport
	if type(rule) == "table" then
		return table.find(rule, player.UserId) ~= nil
	end
	return rule == true
end

function Teleport.start(world: WorldServer.World, net: ServerNet.ServerNet)
	local lastTeleport: { [Player]: number } = {}

	net.on(Protocol.ClientMessage.Teleport, function(player: Player, payload: buffer)
		if not Teleport.allowed(player) then
			return
		end
		local x, z = Protocol.decodeTeleport(payload)
		if x == nil then
			return
		end
		local now = os.clock()
		if now - (lastTeleport[player] or -math.huge) < Config.Map.TeleportCooldown then
			return
		end
		lastTeleport[player] = now

		local character = player.Character
		if character == nil or PlayerPositions.feet(player) == nil then
			return
		end
		local fx, fy, fz = SafeSpot.find(world, x, z, LANDING_RADIUS)
		if fx == nil then
			return
		end
		Characters.teleport(character, fx, fy, fz)
	end)

	local lastSpectatorTeleport: { [Player]: number } = {}
	net.on(Protocol.ClientMessage.SpectatorTeleport, function(player: Player, payload: buffer)
		local userId = Protocol.decodeSpectatorTeleport(payload)
		if userId == nil or not GameMode.isSpectatorOf(player) then
			return
		end
		local now = os.clock()
		if now - (lastSpectatorTeleport[player] or -math.huge) < SPECTATOR_COOLDOWN then
			return
		end
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local target = Players:GetPlayerByUserId(userId)
		local tx, ty, tz = nil, 0, 0
		if target then
			tx, ty, tz = PlayerPositions.feet(target)
		end
		if character == nil or humanoid == nil or humanoid.Health <= 0 or tx == nil then
			return
		end
		local x, y, z = GameModeRules.spectatorTeleport(GameMode.of(player), player.UserId, userId, tx, ty, tz)
		if x == nil then
			return
		end
		lastSpectatorTeleport[player] = now
		Characters.teleportTo(player, x, y, z)
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastTeleport[player] = nil
		lastSpectatorTeleport[player] = nil
	end)
end

return Teleport
