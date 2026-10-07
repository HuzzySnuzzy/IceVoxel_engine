--!strict
--[[
	Players' game modes (Shared/GameMode), the /gamemode chat command and the client's switching
	(the F3 + F4 game mode switcher and F3 + N: Protocol SetGameMode).

	  Modes     a player's mode is the Player attribute GameMode.ATTRIBUTE, which replicates to
	            every client. Joining players get Config.Gameplay.DefaultGameMode. Changing modes
	            changes nothing else: the inventory stays, as in Minecraft.
	  Previous  the mode before the last change is GameMode.PREVIOUS_ATTRIBUTE (none until the
	            mode changes once; setting the mode it already is changes nothing), for F3 + N
	            and the switcher. Minecraft's client keeps it the same way (MultiPlayerGameMode
	            .setLocalMode; the server's copy is MC-259571, which Paper fixes like this).
	  Permission GameMode.PERMISSION_ATTRIBUTE: may the player change their own mode
	            (Config.Gameplay.GameModeCommand, or the operators' permission: Players/Operators)?
	            Set on joining, again on every command and switch and whenever their operator
	            status changes, so clients can refuse F3 + N / F3 + F4 themselves (Minecraft's
	            permission level 2).
	  Command   `/gamemode <survival|creative|adventure|spectator> [player]`, alias `/gm`, parsed
	            and checked by Players/GameModeCommand. With TextChatService it is a
	            TextChatCommand made here (the message is not shown to anyone; Triggered fires on
	            the server with the sender's TextSource). With the legacy chat it is read from
	            Player.Chatted.
	  Switching SetGameMode messages (a GameType id) go through GameModeCommand.switchOwn: the
	            command's permission and answer, nothing when the mode is already that one. At
	            most SWITCHES_PER_SECOND a player (a token bucket), as each switch replicates.
	  Operators other players' modes need the operators' permission (Players/Operators.permitted:
	            operators, among them Config.Gameplay.Admins, the game's owner and everyone in
	            Studio; everyone in a world that allows commands), which also lets them change
	            their own where Config.Gameplay.GameModeCommand doesn't.
	  Owner     `isOwner`: the creator when a user owns the game, or the group's owner for group
	            games (GroupService, looked up once per server; a failed lookup is tried again,
	            after OWNER_RETRY seconds doubling up to OWNER_RETRY_MAX), for Players/Operators.
	  Feedback  goes to the players as Notice messages, shown in their chat (client Net/Notices).
]]

local GroupService = game:GetService("GroupService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local WorldSettings = require(Shared.WorldSettings)
local GameMode = require(Shared.GameMode)
local Protocol = require(Shared.Net.Protocol)

local ServerNet = require(script.Parent.Parent.Network.ServerNet)
local GameModeCommand = require(script.Parent.GameModeCommand)
local Operators = require(script.Parent.Operators)

-- Game mode switches (SetGameMode) a player may make per second, and at most this many at once.
local SWITCHES_PER_SECOND = 4
local SWITCH_BURST = 4
-- Seconds before a failed lookup of a group game's owner is tried again, doubling up to the most.
local OWNER_RETRY = 5
local OWNER_RETRY_MAX = 300

local GameModes = {}

local changedEvent = Instance.new("BindableEvent")
-- Fires (player: Player, mode: string, previous: string?) after a player's game mode changed.
GameModes.changed = changedEvent.Event

-- Pure permission checks (GameModeCommand), for other scripts.
GameModes.allowed = GameModeCommand.allowed
GameModes.isAdmin = GameModeCommand.isAdmin

local net: ServerNet.ServerNet? = nil
-- Group games: the user id of the group's owner (0 = none), once looked up.
local groupOwner: number? = nil
-- SetGameMode token buckets per player.
local switchBuckets: { [Player]: { tokens: number, last: number } } = {}

local function notify(player: Player, text: string)
	if net and player.Parent then
		net.send(player, Protocol.ServerMessage.Notice, Protocol.encodeNotice(text))
	end
end

-- May `player` change their own mode (Config.Gameplay.GameModeCommand, or an operator)?
local function mayChangeOwn(player: Player): boolean
	return GameModeCommand.allowed(player.UserId, Config.Gameplay.GameModeCommand, false, false)
		or Operators.permitted(player)
end

-- Tells the player's clients whether they may change their own mode (GameMode.mayChangeOwn).
local function setPermission(player: Player)
	if player.Parent then
		player:SetAttribute(GameMode.PERMISSION_ATTRIBUTE, mayChangeOwn(player))
	end
end

-- Is this a group game (whose owner has to be looked up)?
local function isGroupGame(): boolean
	return game.CreatorId ~= 0 and game.CreatorType == Enum.CreatorType.Group
end

--[[
	Looks a group game's owner up (yields: a web call) unless it is known. Returns whether the
	owner is known now; a failure is not remembered, so the next call tries again.
]]
local function lookUpGroupOwner(): boolean
	if groupOwner ~= nil then
		return true
	end
	local ok, info = pcall(GroupService.GetGroupInfoAsync, GroupService, game.CreatorId)
	if not ok or type(info) ~= "table" then
		return false
	end
	-- (Another lookup may have finished while this one yielded.)
	if groupOwner == nil then
		local owner = info.Owner
		groupOwner = if type(owner) == "table" and type(owner.Id) == "number" then owner.Id else 0
	end
	return true
end

-- Does `player` own this game? May yield the first time (a web call, for group games).
local function isOwner(player: Player): boolean
	if game.CreatorId == 0 then
		return false
	elseif game.CreatorType == Enum.CreatorType.User then
		return player.UserId == game.CreatorId
	end
	return lookUpGroupOwner() and groupOwner ~= 0 and player.UserId == groupOwner
end

-- Does `player` own this game (the user, or a group game's group owner)? May yield the first time
-- (a web call for group games); Players/Operators asks when they join.
GameModes.isOwner = isOwner

-- Is `isOwner`'s answer final (not a group game whose owner is still unknown)?
function GameModes.ownerKnown(): boolean
	return not isGroupGame() or groupOwner ~= nil
end

-- A player's game mode.
function GameModes.get(player: Player): string
	return GameMode.of(player)
end

-- A player's previous game mode (nil until it has changed once).
function GameModes.previous(player: Player): string?
	return GameMode.previousOf(player)
end

--[[
	Sets a player's game mode (one of GameMode.ALL). When it changes, the old mode becomes the
	previous one. `announce` tells them ("Your game mode has been updated to Creative Mode").
]]
function GameModes.set(player: Player, mode: string, announce: boolean?)
	assert(GameMode.isValid(mode), `Unknown game mode {mode}`)
	local old = player:GetAttribute(GameMode.ATTRIBUTE)
	local previous = GameModeCommand.previousAfter(old, mode)
	if previous then
		player:SetAttribute(GameMode.PREVIOUS_ATTRIBUTE, previous)
	end
	player:SetAttribute(GameMode.ATTRIBUTE, mode)
	if announce then
		notify(player, `Your game mode has been updated to {GameModeCommand.modeName(mode)}`)
	end
	if old ~= mode then
		changedEvent:Fire(player, mode, previous)
	end
end

-- The command's view of the players in the game, and the one that is `player` (nil when they
-- left, e.g. while an ownership check yielded).
local function candidatesFor(player: Player): ({ GameModeCommand.Candidate }, GameModeCommand.Candidate?)
	local candidates: { GameModeCommand.Candidate } = {}
	local source: GameModeCommand.Candidate? = nil
	for _, other in Players:GetPlayers() do
		local candidate = { key = other, name = other.Name, displayName = other.DisplayName }
		table.insert(candidates, candidate)
		if other == player then
			source = candidate
		end
	end
	return candidates, source
end

local function modeOf(key: any): string
	return GameMode.of(key :: Player)
end

-- Applies what the command (or a switch) decided and tells everyone concerned.
local function apply(player: Player, result: GameModeCommand.Result)
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

-- Runs a chat message as the /gamemode command (ignores anything else).
local function run(player: Player, text: string)
	if not GameModeCommand.matches(text) then
		return
	end
	setPermission(player)
	local candidates, source = candidatesFor(player)
	if source == nil then
		return
	end
	local operator = Operators.permitted(player)
	local result = GameModeCommand.run(text, {
		source = source,
		players = candidates,
		-- (Operators may always: GameModeCommand.allowed's "always" argument.)
		mayUse = GameModeCommand.allowed(player.UserId, Config.Gameplay.GameModeCommand, operator, false),
		mayTarget = operator,
		modeOf = modeOf,
	})
	if result then
		apply(player, result)
	end
end

-- May the player switch modes now (SWITCHES_PER_SECOND)?
local function takeSwitch(player: Player): boolean
	local now = os.clock()
	local bucket = switchBuckets[player]
	if bucket == nil then
		bucket = { tokens = SWITCH_BURST, last = now }
		switchBuckets[player] = bucket
	end
	bucket.tokens = math.min(SWITCH_BURST, bucket.tokens + (now - bucket.last) * SWITCHES_PER_SECOND)
	bucket.last = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

-- A SetGameMode message: the player switches their own mode (the switcher, F3 + N).
local function onSetGameMode(player: Player, payload: buffer)
	local mode = Protocol.decodeSetGameMode(payload)
	if mode == nil or not takeSwitch(player) then
		return
	end
	setPermission(player)
	local _, source = candidatesFor(player)
	if source == nil then
		return
	end
	local operator = Operators.permitted(player)
	apply(
		player,
		GameModeCommand.switchOwn(mode, {
			source = source,
			players = {},
			mayUse = GameModeCommand.allowed(player.UserId, Config.Gameplay.GameModeCommand, operator, false),
			mayTarget = operator,
			modeOf = modeOf,
		})
	)
end

local function listenToTextChat()
	local command = Instance.new("TextChatCommand")
	command.Name = "IceVoxelGameMode"
	command.PrimaryAlias = GameModeCommand.ALIASES[1]
	command.SecondaryAlias = GameModeCommand.ALIASES[2]
	-- (The chat suggests it to those who may change their own mode.)
	command:SetAttribute(WorldSettings.COMMAND_ATTRIBUTE, WorldSettings.COMMAND_GAMEMODE)
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
	local default = GameMode.default()
	local legacy = TextChatService.ChatVersion == Enum.ChatVersion.LegacyChatService

	local function onPlayer(player: Player)
		if player:GetAttribute(GameMode.ATTRIBUTE) == nil then
			GameModes.set(player, default, false)
		end
		setPermission(player)
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
	Players.PlayerRemoving:Connect(function(player: Player)
		switchBuckets[player] = nil
	end)
	if not legacy then
		listenToTextChat()
	end
	serverNet.on(Protocol.ClientMessage.SetGameMode, onSetGameMode)
	-- (Becoming or no longer being an operator, and the world's Allow Commands.)
	Operators.changed:Connect(setPermission)

	-- The owner is an operator once the lookup works (Players/Operators asks too): keep trying
	-- until it does (a web call can fail).
	if isGroupGame() then
		task.spawn(function()
			local delay = OWNER_RETRY
			while not lookUpGroupOwner() do
				task.wait(delay)
				delay = math.min(delay * 2, OWNER_RETRY_MAX)
			end
		end)
	end
end

return GameModes
