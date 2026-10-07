--!strict
--[[
	Server operators in the game: Minecraft's ops (the rules, tested: Players/OperatorList), /op and
	/deop, and the one check every operators' command asks.

	  Who        the first player to join becomes the operator ("Name is the server operator", to
	             everyone), and while players are here one of them always is one (the longest here
	             takes over when the last operator leaves). Config.Gameplay.Admins and everyone in
	             Studio are operators from the start; the game's owner (Players/GameModes.isOwner:
	             the user, or a group game's owner, a web call looked up again until it works) as
	             soon as that is known.
	  Check      `permitted(player)`: may use the operators' commands (/time, /gamerule, /gamemode
	             for others, /effect, /summon, /kill, /knowledge, /age; structure blocks in
	             creative): an operator, or anyone in a world created with Allow Commands
	             (`setAllowCommands`). `isOperator(player)` is the real thing (/op, /deop, the
	             title screen's Create World).
	  Attribute  WorldSettings.OPERATOR_ATTRIBUTE on the Player (true / false) for the clients;
	             `changed` fires (player) whenever a player's status or permission changes
	             (Players/GameModes tells their client again whether they may switch modes).
	  Commands   `/op <player>`, `/deop <player>`: TextChatCommands (the message is shown to
	             nobody), or Player.Chatted with the legacy chat. Answers and announcements are
	             Notice messages (client Net/Notices: the chat).
	Started first of all, on the lobby's net (Network/LobbyNet): the world may wait for its
	operator (Players/WorldMenu).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Protocol = require(Shared.Net.Protocol)
local WorldSettings = require(Shared.WorldSettings)

local ServerNet = require(script.Parent.Parent.Network.ServerNet)
local OperatorList = require(script.Parent.OperatorList)

-- Seconds before a group game's owner is looked up again, doubling up to the most.
local OWNER_RETRY = 5
local OWNER_RETRY_MAX = 300

local Operators = {}

local list = OperatorList.new()
local net: ServerNet.ServerNet? = nil

local changedEvent = Instance.new("BindableEvent")
-- Fires (player: Player) when the player's operator status or permission changed.
Operators.changed = changedEvent.Event

-- Is `player` an operator?
function Operators.isOperator(player: Player): boolean
	return OperatorList.isOperator(list, player.UserId)
end

-- May `player` use the operators' commands (an operator, or anyone with commands allowed)?
function Operators.permitted(player: Player): boolean
	return OperatorList.permitted(list, player.UserId)
end

-- The operators here, longest here first.
function Operators.present(): { Player }
	local found = {}
	for _, member in OperatorList.presentOperators(list) do
		local player = Players:GetPlayerByUserId(member.key :: number)
		if player then
			table.insert(found, player)
		end
	end
	return found
end

local function notify(player: Player, text: string)
	local network = net
	if network and player.Parent then
		network.send(player, Protocol.ServerMessage.Notice, Protocol.encodeNotice(text))
	end
end

-- Sets the attributes, tells everyone concerned.
local function apply(result: OperatorList.Result, source: Player?)
	for _, userId in result.changed do
		local player = Players:GetPlayerByUserId(userId)
		if player then
			player:SetAttribute(WorldSettings.OPERATOR_ATTRIBUTE, OperatorList.isOperator(list, userId))
			changedEvent:Fire(player)
		end
	end
	for _, text in result.broadcast do
		for _, player in Players:GetPlayers() do
			notify(player, text)
		end
	end
	for _, notice in result.notices do
		local player = Players:GetPlayerByUserId(notice.userId)
		if player then
			notify(player, notice.text)
		end
	end
	if source then
		for _, text in result.feedback do
			notify(source, text)
		end
	end
end

-- Commands for everyone (the world's Allow Commands) or operators only.
function Operators.setAllowCommands(allow: boolean)
	apply(OperatorList.setAllowCommands(list, allow))
end

local function run(player: Player, text: string)
	local result = OperatorList.run(list, text, player.UserId)
	if result then
		apply(result, player)
	end
end

local function command(name: string, alias: string)
	local instance = Instance.new("TextChatCommand")
	instance.Name = name
	instance.PrimaryAlias = alias
	-- (Operators only: the chat suggests it to them alone.)
	instance:SetAttribute(WorldSettings.COMMAND_ATTRIBUTE, WorldSettings.COMMAND_OPERATOR)
	instance.Triggered:Connect(function(source: TextSource, text: string)
		local player = Players:GetPlayerByUserId(source.UserId)
		if player then
			run(player, text)
		end
	end)
	-- Commands work when parented to TextChatService (replicated, so clients sink the message).
	instance.Parent = TextChatService
end

--[[
	Starts keeping the operators. `isOwner` (may yield: a web call) says whether a player owns the
	game, `ownerKnown` whether that answer is final (a group game's owner may not be known yet).
]]
function Operators.start(serverNet: ServerNet.ServerNet, isOwner: (Player) -> boolean, ownerKnown: () -> boolean)
	assert(net == nil, "Operators.start was already called")
	net = serverNet
	local studio = RunService:IsStudio()
	local legacy = TextChatService.ChatVersion == Enum.ChatVersion.LegacyChatService

	local function onPlayer(player: Player)
		local permanent = studio or table.find(Config.Gameplay.Admins, player.UserId) ~= nil
		apply(
			OperatorList.join(
				list,
				{ key = player.UserId, name = player.Name, displayName = player.DisplayName },
				permanent
			)
		)
		if legacy then
			player.Chatted:Connect(function(message: string)
				run(player, message)
			end)
		end
		if permanent then
			return
		end
		-- The owner, once known (a group game's owner: retried until the lookup works).
		task.spawn(function()
			local delay = OWNER_RETRY
			while player.Parent do
				if isOwner(player) then
					if player.Parent then
						apply(OperatorList.setPermanent(list, player.UserId, true))
					end
					return
				elseif ownerKnown() then
					return
				end
				task.wait(delay)
				delay = math.min(delay * 2, OWNER_RETRY_MAX)
			end
		end)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayer, player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		apply(OperatorList.leave(list, player.UserId))
	end)
	if not legacy then
		command("IceVoxelOp", OperatorList.OP_ALIASES[1])
		command("IceVoxelDeop", OperatorList.DEOP_ALIASES[1])
	end
end

return Operators
