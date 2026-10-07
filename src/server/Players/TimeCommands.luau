--!strict
--[[
	The /time and /gamerule chat commands (parsed and checked by Players/TimeCommand), applied to the
	world's clock (World/TimeOfDay) and the weather's (World/WeatherServer: doWeatherCycle).

	  Commands  `/time set|add|query ...` and `/gamerule doDaylightCycle|doWeatherCycle
	            [true|false]`. With
	            TextChatService they are TextChatCommands made here (the message is not shown to
	            anyone; Triggered fires on the server with the sender's TextSource). With the legacy
	            chat they are read from Player.Chatted.
	  Who may   changing the time or a game rule: the operators' permission (Players/Operators:
	            operators, among them Config.Gameplay.Admins, the game's owner and Studio
	            sessions; everyone in a world created with Allow Commands); queries: anyone.
	  Feedback  goes to the player as Notice messages, shown in their chat (client Net/Notices).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Protocol = require(Shared.Net.Protocol)

local ServerNet = require(script.Parent.Parent.Network.ServerNet)
local TimeOfDay = require(script.Parent.Parent.World.TimeOfDay)
local WeatherServer = require(script.Parent.Parent.World.WeatherServer)
local Operators = require(script.Parent.Operators)
local TimeCommand = require(script.Parent.TimeCommand)

local TimeCommands = {}

local net: ServerNet.ServerNet? = nil

local function notify(player: Player, text: string)
	if net and player.Parent then
		net.send(player, Protocol.ServerMessage.Notice, Protocol.encodeNotice(text))
	end
end

-- Runs a chat message as /time or /gamerule (ignores anything else).
local function run(player: Player, text: string)
	if not TimeCommand.matches(text) then
		return
	end
	if player.Parent == nil then
		return
	end
	local result = TimeCommand.run(text, {
		mayUse = Operators.permitted(player),
		dayTime = TimeOfDay.get(),
		gameTime = TimeOfDay.gameTime(),
		cycle = TimeOfDay.cycle(),
		weatherCycle = WeatherServer.cycle(),
	})
	if result == nil then
		return
	end
	if result.cycle ~= nil then
		TimeOfDay.setCycle(result.cycle)
	end
	if result.weatherCycle ~= nil then
		WeatherServer.setCycle(result.weatherCycle)
	end
	if result.dayTime ~= nil then
		TimeOfDay.set(result.dayTime)
	end
	for _, message in result.feedback do
		notify(player, message)
	end
end

local function command(name: string, alias: string)
	local instance = Instance.new("TextChatCommand")
	instance.Name = name
	instance.PrimaryAlias = alias
	instance.Triggered:Connect(function(source: TextSource, text: string)
		local player = Players:GetPlayerByUserId(source.UserId)
		if player then
			run(player, text)
		end
	end)
	-- Commands work when parented to TextChatService (replicated, so clients sink the message).
	instance.Parent = TextChatService
end

function TimeCommands.start(serverNet: ServerNet.ServerNet)
	assert(net == nil, "TimeCommands.start was already called")
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
		command("IceVoxelTime", TimeCommand.TIME_ALIASES[1])
		command("IceVoxelGameRule", TimeCommand.GAMERULE_ALIASES[1])
	end
end

return TimeCommands
