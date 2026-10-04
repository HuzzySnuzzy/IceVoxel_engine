--!strict
--[[
	Players' game modes (Shared/GameMode) and the /gamemode chat command.

	  Modes     a player's mode is the Player attribute GameMode.ATTRIBUTE, which replicates to
	            every client. Joining players get Config.Gameplay.DefaultGameMode. Changing modes
	            changes nothing else: the inventory stays, as in Minecraft.
	  Command   `/gamemode <survival|creative|s|c|0|1> [player]`, alias `/gm`, parsed and checked
	            by Players/GameModeCommand. With TextChatService it is a TextChatCommand made here
	            (the message is not shown to anyone; Triggered fires on the server with the
	            sender's TextSource). With the legacy chat it is read from Player.Chatted.
	  Owner     the game's owner may always use it: the creator when a user owns the game, or the
	            group's owner for group games (GroupService, looked up once per server). So may
	            everyone in Studio.
	  Feedback  goes to the players as Notice messages, shown in their chat (client Net/Notices).
]]

local GroupService = game:GetService("GroupService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Protocol = require(Shared.Net.Protocol)

local ServerNet = require(script.Parent.Parent.Network.ServerNet)
local GameModeCommand = require(script.Parent.GameModeCommand)

local GameModes = {}

local changedEvent = Instance.new("BindableEvent")
-- Fires (player: Player, mode: string) after a player's game mode changed.
GameModes.changed = changedEvent.Event

-- Pure permission checks (GameModeCommand), for other scripts.
GameModes.allowed = GameModeCommand.allowed
GameModes.isAdmin = GameModeCommand.isAdmin

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

-- A player's game mode.
function GameModes.get(player: Player): string
	return GameMode.of(player)
end

--[[
	Sets a player's game mode (GameMode.SURVIVAL / CREATIVE). `announce` tells them ("Your game mode
	has been updated to Creative Mode").
]]
function GameModes.set(player: Player, mode: string, announce: boolean?)
	assert(mode == GameMode.SURVIVAL or mode == GameMode.CREATIVE, `Unknown game mode {mode}`)
	local old = player:GetAttribute(GameMode.ATTRIBUTE)
	player:SetAttribute(GameMode.ATTRIBUTE, mode)
	if announce then
		notify(player, `Your game mode has been updated to {GameModeCommand.modeName(mode)}`)
	end
	if old ~= mode then
		changedEvent:Fire(player, mode)
	end
end

-- Runs a chat message as the /gamemode command (ignores anything else).
local function run(player: Player, text: string)
	if not GameModeCommand.matches(text) then
		return
	end
	local owner = isOwner(player)
	local studio = RunService:IsStudio()
	local candidates: { GameModeCommand.Candidate } = {}
	local source: GameModeCommand.Candidate? = nil
	for _, other in Players:GetPlayers() do
		local candidate = { key = other, name = other.Name, displayName = other.DisplayName }
		table.insert(candidates, candidate)
		if other == player then
			source = candidate
		end
	end
	if source == nil then
		-- Left while the ownership check yielded.
		return
	end
	local result = GameModeCommand.run(text, {
		source = source,
		players = candidates,
		mayUse = GameModeCommand.allowed(player.UserId, Config.Gameplay.GameModeCommand, owner, studio),
		mayTarget = GameModeCommand.isAdmin(player.UserId, Config.Gameplay.Admins, owner, studio),
		modeOf = function(key: any): string
			return GameMode.of(key :: Player)
		end,
	})
	if result == nil then
		return
	end
	for _, change in result.changes do
		local target = change.key :: Player
		if target.Parent then
			GameModes.set(target, change.mode, false)
		end
	end
	for _, message in result.feedback do
		notify(player, message)
	end
	for _, notice in result.notices do
		notify(notice.key :: Player, notice.text)
	end
end

local function listenToTextChat()
	local command = Instance.new("TextChatCommand")
	command.Name = "IceVoxelGameMode"
	command.PrimaryAlias = GameModeCommand.ALIASES[1]
	command.SecondaryAlias = GameModeCommand.ALIASES[2]
	command.Triggered:Connect(function(source: TextSource, text: string)
		local player = Players:GetPlayerByUserId(source.UserId)
		if player then
			run(player, text)
		end
	end)
	-- Commands work when parented to TextChatService (replicated, so clients sink the message).
	command.Parent = TextChatService
end

function GameModes.start(serverNet: ServerNet.ServerNet)
	assert(net == nil, "GameModes.start was already called")
	net = serverNet
	local default = GameMode.parse(Config.Gameplay.DefaultGameMode) or GameMode.SURVIVAL
	local legacy = TextChatService.ChatVersion == Enum.ChatVersion.LegacyChatService

	local function onPlayer(player: Player)
		if player:GetAttribute(GameMode.ATTRIBUTE) == nil then
			GameModes.set(player, default, false)
		end
		if legacy then
			player.Chatted:Connect(function(message: string)
				run(player, message)
			end)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayer, player)
	end
	if not legacy then
		listenToTextChat()
	end
end

return GameModes
