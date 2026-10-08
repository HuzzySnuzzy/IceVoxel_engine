--!strict
--[[
	The /tp chat command (alias /teleport; parsed and checked by Players/TeleportCommand), moving
	players through Players/PlayerPositions.teleport: their characters today, the private
	Teleport message and a new epoch with server positions on (the floating origin: the client
	re-bases on arrival). Coordinates are true world coordinates either way, and so are the
	players' positions "~" is relative to (PlayerPositions.feet).

	  Command   a TextChatCommand made here (the message is shown to no one; Triggered fires on
	            the server with the sender's TextSource), or Player.Chatted with the legacy chat.
	            It carries the operators' permission (WorldSettings.COMMAND_PERMITTED), so the
	            chat suggests it to those who may use it.
	  Landing   Players/SafeSpot on the world's blocks (a chunk may be generated to look), for
	            survival and adventure players (TeleportCommand.landing).
	  Feedback  Notice messages to whoever typed it (client Net/Notices: the chat).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local GameMode = require(Shared.GameMode)
local Protocol = require(Shared.Net.Protocol)
local WorldSettings = require(Shared.WorldSettings)

local ServerNet = require(script.Parent.Parent.Network.ServerNet)
local WorldServer = require(script.Parent.Parent.World.WorldServer)
local Operators = require(script.Parent.Operators)
local PlayerPositions = require(script.Parent.PlayerPositions)
local SafeSpot = require(script.Parent.SafeSpot)
local TeleportCommand = require(script.Parent.TeleportCommand)

local TeleportCommands = {}

local net: ServerNet.ServerNet? = nil
local world: WorldServer.World? = nil

local function notify(player: Player, text: string)
	if net and player.Parent then
		net.send(player, Protocol.ServerMessage.Notice, Protocol.encodeNotice(text))
	end
end

local function candidate(player: Player): TeleportCommand.Candidate
	local x, y, z = PlayerPositions.feet(player)
	return {
		key = player,
		name = player.Name,
		displayName = player.DisplayName,
		mode = GameMode.of(player),
		x = x,
		y = y,
		z = z,
	}
end

-- Runs a chat message as /tp (ignores anything else).
local function run(player: Player, text: string)
	local blocks = world
	if blocks == nil or not TeleportCommand.matches(text) or player.Parent == nil then
		return
	end
	local source = candidate(player)
	local everyone: { TeleportCommand.Candidate } = {}
	for _, other in Players:GetPlayers() do
		table.insert(everyone, if other == player then source else candidate(other))
	end
	local result = TeleportCommand.run(text, {
		mayUse = Operators.permitted(player),
		source = source,
		players = everyone,
		isSafe = function(x: number, y: number, z: number): boolean
			return SafeSpot.isSafe(blocks, x, y, z)
		end,
		column = function(x: number, z: number): number?
			return SafeSpot.column(blocks, x, z)
		end,
	})
	if result == nil then
		return
	end
	for _, move in result.moves do
		local target = move.key :: Player
		if target.Parent then
			PlayerPositions.teleport(target, move.x, move.y, move.z)
		end
	end
	for _, message in result.feedback do
		notify(player, message)
	end
end

function TeleportCommands.start(serverNet: ServerNet.ServerNet, serverWorld: WorldServer.World)
	assert(net == nil, "TeleportCommands.start was already called")
	net = serverNet
	world = serverWorld
	if TextChatService.ChatVersion == Enum.ChatVersion.LegacyChatService then
		local function onPlayer(player: Player)
			player.Chatted:Connect(function(message: string)
				run(player, message)
			end)
		end
		Players.PlayerAdded:Connect(onPlayer)
		for _, player in Players:GetPlayers() do
			onPlayer(player)
		end
		return
	end
	local command = Instance.new("TextChatCommand")
	command.Name = "IceVoxelTeleport"
	command.PrimaryAlias = TeleportCommand.ALIASES[1]
	command.SecondaryAlias = TeleportCommand.ALIASES[2]
	-- (The operators' permission: the chat suggests it to those who have it.)
	command:SetAttribute(WorldSettings.COMMAND_ATTRIBUTE, WorldSettings.COMMAND_PERMITTED)
	command.Triggered:Connect(function(source: TextSource, text: string)
		local player = Players:GetPlayerByUserId(source.UserId)
		if player then
			run(player, text)
		end
	end)
	command.Parent = TextChatService
end

return TeleportCommands
