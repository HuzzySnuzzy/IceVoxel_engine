--!strict
--[[
	The /season chat command (parsed and checked by Players/SeasonCommand), applied to the world's
	calendar (World/SeasonClock: only its offset moves, so the time of day, the "Day N" line and
	the blood moons stay).

	  Commands  `/season query` and `/season set <season> [day]`. With TextChatService it is a
	            TextChatCommand made here (the message is not shown to anyone; Triggered fires on
	            the server with the sender's TextSource). With the legacy chat it is read from
	            Player.Chatted.
	  Who may   setting the season: the operators' permission (Players/Operators, as /time);
	            the query: anyone.
	  Feedback  goes to the player as Notice messages, shown in their chat (client Net/Notices).

	Started by Players/TimeCommands.start (the /time and /gamerule glue, whose doSeasonCycle rule
	and /time set's kept calendar also go to World/SeasonClock).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Protocol = require(Shared.Net.Protocol)

local ServerNet = require(script.Parent.Parent.Network.ServerNet)
local SeasonClock = require(script.Parent.Parent.World.SeasonClock)
local TimeOfDay = require(script.Parent.Parent.World.TimeOfDay)
local Operators = require(script.Parent.Operators)
local SeasonCommand = require(script.Parent.SeasonCommand)

local SeasonCommands = {}

local net: ServerNet.ServerNet? = nil

local function notify(player: Player, text: string)
	if net and player.Parent then
		net.send(player, Protocol.ServerMessage.Notice, Protocol.encodeNotice(text))
	end
end

-- Runs a chat message as /season (ignores anything else).
local function run(player: Player, text: string)
	if not SeasonCommand.matches(text) or player.Parent == nil then
		return
	end
	local result = SeasonCommand.run(text, {
		mayUse = Operators.permitted(player),
		enabled = SeasonClock.enabled(),
		dayTime = TimeOfDay.get(),
		state = SeasonClock.state(),
	})
	if result == nil then
		return
	end
	local season = result.season
	if season ~= nil then
		SeasonClock.setSeason(season, result.day)
	end
	for _, message in result.feedback do
		notify(player, message)
	end
end

function SeasonCommands.start(serverNet: ServerNet.ServerNet)
	assert(net == nil, "SeasonCommands.start was already called")
	net = serverNet
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
	else
		local instance = Instance.new("TextChatCommand")
		instance.Name = "IceVoxelSeason"
		instance.PrimaryAlias = SeasonCommand.ALIASES[1]
		instance.Triggered:Connect(function(source: TextSource, text: string)
			local player = Players:GetPlayerByUserId(source.UserId)
			if player then
				run(player, text)
			end
		end)
		-- (Parented to TextChatService: replicated, so clients sink the message.)
		instance.Parent = TextChatService
	end
end

return SeasonCommands
