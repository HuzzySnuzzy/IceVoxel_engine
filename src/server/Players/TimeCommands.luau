--!strict
--[[
	The /time and /gamerule chat commands (parsed and checked by Players/TimeCommand), applied to the
	world's clock (World/TimeOfDay).

	  Commands  `/time set|add|query ...` and `/gamerule doDaylightCycle [true|false]`. With
	            TextChatService they are TextChatCommands made here (the message is not shown to
	            anyone; Triggered fires on the server with the sender's TextSource). With the legacy
	            chat they are read from Player.Chatted.
	  Who may   changing the time or a game rule: Config.Gameplay.Admins, the game's owner and
	            Studio sessions (the rule for changing other players' game modes); queries: anyone.
	            The owner is the creator when a user owns the game, or the group's owner for group
	            games (GroupService, looked up once per server), as in Players/GameModes.
	  Feedback  goes to the player as Notice messages, shown in their chat (client Net/Notices).
]]

local GroupService = game:GetService("GroupService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Protocol = require(Shared.Net.Protocol)

local ServerNet = require(script.Parent.Parent.Network.ServerNet)
local TimeOfDay = require(script.Parent.Parent.World.TimeOfDay)
local TimeCommand = require(script.Parent.TimeCommand)

local TimeCommands = {}

local net: ServerNet.ServerNet? = nil
-- Group games: the user id of the group's owner (0 = none), once looked up.
local groupOwner: number? = nil

local function notify(player: Player, text: string)
	if net and player.Parent then
		net.send(player, Protocol.ServerMessage.Notice, Protocol.encodeNotice(text))
	end
end

-- Does `player` own this game? May yield the first time (a web call, for group games).
local function isOwner(player: Player): boolean
	if game.CreatorId == 0 then
		return false
	elseif game.CreatorType == Enum.CreatorType.User then
		return player.UserId == game.CreatorId
	end
	if groupOwner == nil then
		local ok, info = pcall(GroupService.GetGroupInfoAsync, GroupService, game.CreatorId)
		if not ok or type(info) ~= "table" then
			-- Try again next time rather than remember a failure.
			return false
		end
		local owner = info.Owner
		groupOwner = if type(owner) == "table" and type(owner.Id) == "number" then owner.Id else 0
	end
	return groupOwner ~= 0 and player.UserId == groupOwner
end

-- Runs a chat message as /time or /gamerule (ignores anything else).
local function run(player: Player, text: string)
	if not TimeCommand.matches(text) then
		return
	end
	local studio = RunService:IsStudio()
	local mayUse = TimeCommand.mayUse(player.UserId, Config.Gameplay.Admins, studio or isOwner(player), studio)
	if player.Parent == nil then
		-- Left while the ownership check yielded.
		return
	end
	local result = TimeCommand.run(text, {
		mayUse = mayUse,
		dayTime = TimeOfDay.get(),
		gameTime = TimeOfDay.gameTime(),
		cycle = TimeOfDay.cycle(),
	})
	if result == nil then
		return
	end
	if result.cycle ~= nil then
		TimeOfDay.setCycle(result.cycle)
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
