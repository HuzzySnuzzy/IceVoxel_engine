--!strict
--[[
	Teleport requests from the world map. The server decides: permission (Config.Map.Teleport),
	cooldown, and a safe landing spot near the requested column (SafeSpot / SpawnUnsafeBlocks).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Protocol = require(Shared.Net.Protocol)

local WorldServer = require(script.Parent.Parent.World.WorldServer)
local ServerNet = require(script.Parent.Parent.Network.ServerNet)
local SafeSpot = require(script.Parent.SafeSpot)
local Characters = require(script.Parent.Characters)

-- Blocks around the requested column searched for a safe spot.
local LANDING_RADIUS = 24

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
		if character == nil or character:FindFirstChild("HumanoidRootPart") == nil then
			return
		end
		local fx, fy, fz = SafeSpot.find(world, x, z, LANDING_RADIUS)
		if fx == nil then
			return
		end
		Characters.teleport(character, fx, fy, fz)
	end)

	game:GetService("Players").PlayerRemoving:Connect(function(player)
		lastTeleport[player] = nil
	end)
end

return Teleport
