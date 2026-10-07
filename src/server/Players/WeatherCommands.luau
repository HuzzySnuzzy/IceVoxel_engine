--!strict
--[[
	The /weather chat command (parsed and checked by Players/WeatherCommand), applied to the world's
	weather (World/WeatherServer).

	  Command   `/weather clear|rain|thunder [duration]` and `/weather query`. With
	            TextChatService it is a TextChatCommand made here (the message is not shown to
	            anyone; Triggered fires on the server with the sender's TextSource). With the legacy
	            chat it is read from Player.Chatted.
	  Who may   setting the weather: the operators' permission (Players/Operators, as /time); the
	            query: anyone (so the command carries no permission attribute, as /time).
	  Feedback  goes to the player as Notice messages, shown in their chat (client Net/Notices).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Protocol = require(Shared.Net.Protocol)
local Rig = require(Shared.Movement.Rig)
local Weather = require(Shared.Weather)

local ServerNet = require(script.Parent.Parent.Network.ServerNet)
local WeatherServer = require(script.Parent.Parent.World.WeatherServer)
local Operators = require(script.Parent.Operators)
local WeatherCommand = require(script.Parent.WeatherCommand)

local WeatherCommands = {}

local net: ServerNet.ServerNet? = nil
local random = Random.new()

local function notify(player: Player, text: string)
	if net and player.Parent then
		net.send(player, Protocol.ServerMessage.Notice, Protocol.encodeNotice(text))
	end
end

-- The weather where `player` stands, for the query.
local function here(player: Player): string
	local character = player.Character
	local feet = if character then Rig.feet(character) else nil
	if feet == nil then
		return Weather.CLEAR
	end
	return WeatherServer.describe(feet.X, feet.Y, feet.Z)
end

-- Runs a chat message as /weather (ignores anything else).
local function run(player: Player, text: string)
	if not WeatherCommand.matches(text) or player.Parent == nil then
		return
	end
	local result = WeatherCommand.run(text, {
		mayUse = Operators.permitted(player),
		enabled = WeatherServer.enabled(),
		here = here(player),
		random = function(): number
			return random:NextNumber()
		end,
	})
	if result == nil then
		return
	end
	if result.kind and result.ticks then
		WeatherServer.setOverride(result.kind, result.ticks / Weather.TICKS_PER_SECOND)
	end
	for _, message in result.feedback do
		notify(player, message)
	end
end

function WeatherCommands.start(serverNet: ServerNet.ServerNet)
	assert(net == nil, "WeatherCommands.start was already called")
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
		instance.Name = "IceVoxelWeather"
		instance.PrimaryAlias = WeatherCommand.ALIASES[1]
		instance.Triggered:Connect(function(source: TextSource, text: string)
			local player = Players:GetPlayerByUserId(source.UserId)
			if player then
				run(player, text)
			end
		end)
		-- Commands work when parented to TextChatService (replicated, so clients sink the message).
		instance.Parent = TextChatService
	end
end

return WeatherCommands
