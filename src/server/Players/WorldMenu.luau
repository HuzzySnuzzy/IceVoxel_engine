--!strict
--[[
	The title screen's server side (Minecraft's title screen and Create World screen; the client's
	Ui/MainMenu): the world waits for its operator to create it, and players get a character once
	they enter it.

	  State     MenuState messages (Protocol): waiting for the operator, creating, ready or failed,
	            with the operator's name (the operator here longest, Players/Operators) and the
	            world's; to each player as they join and to everyone when either changes.
	  Creating  CreateWorld from an operator (Operators.isOperator: not just Allow Commands) while
	            no world exists: decoded (Protocol: malformed ones never get further), checked
	            (WorldSettings.validate: a world type the menu offers, one of the screen's game
	            modes and difficulties, at most 32 characters of seed; the name cleaned), the name
	            put through Roblox's text filter (TextService, for everyone: every player reads
	            it; when the filter can't be reached the world is "New World"), then
	            World/WorldInfo.create runs the boot's startWorld once (WorldInfo.refusal: only
	            an operator, only while there is no world). One request a second per player
	            (faster ones are refused), one creation at a time, each answered with
	            CreateWorldResult. No seed typed: a random one, 1..2^31 - 2 (as with Config.Seed
	            unset).
	  Entering  EnterWorld (Join World, or the creator's client once its world is made): when the
	            world exists the player's character loads (Player:LoadCharacterAsync, or
	            LoadCharacter on an engine without it). Roblox loads none
	            on its own (Players.CharacterAutoLoads is off from the start), so nobody stands
	            anywhere before the world exists, and the dead are respawned here,
	            Players.RespawnTime after dying (Roblox's own rule), while they are in the world.
	Started only with Config.MainMenu.Enabled (before the world, on the lobby's net,
	Network/LobbyNet); without it the boot creates the world at once and Roblox loads characters.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Protocol = require(Shared.Net.Protocol)
local WorldSettings = require(Shared.WorldSettings)
local WorldTypes = require(Shared.Generation.WorldTypes)

local ServerNet = require(script.Parent.Parent.Network.ServerNet)
local WorldInfo = require(script.Parent.Parent.World.WorldInfo)
local Operators = require(script.Parent.Operators)

-- Seconds between a player's CreateWorld requests.
local REQUEST_INTERVAL = 1

local WorldMenu = {}

local net: ServerNet.ServerNet? = nil
-- Players who entered the world (their character loads, and comes back after death).
local entered: { [Player]: boolean } = {}
local loading: { [Player]: boolean } = {}
local lastRequest: { [Player]: number } = {}
-- A creation is under way (the name's filter yields before WorldInfo.create).
local busy = false

local function menuState(): number
	local state = WorldInfo.state()
	if state == "ready" then
		return Protocol.MenuState.Ready
	elseif state == "failed" then
		return Protocol.MenuState.Failed
	elseif state == "creating" or busy then
		return Protocol.MenuState.Creating
	end
	return Protocol.MenuState.Waiting
end

local function sendState(player: Player)
	local network = net
	if network == nil or player.Parent == nil then
		return
	end
	local first = Operators.present()[1]
	local settings = WorldInfo.get()
	network.send(
		player,
		Protocol.ServerMessage.MenuState,
		Protocol.encodeMenuState(
			menuState(),
			if first then first.DisplayName else "",
			if settings then settings.name else ""
		)
	)
end

local function broadcastState()
	for _, player in Players:GetPlayers() do
		sendState(player)
	end
end

-- Everyone's state at the end of the frame, once however many changes come (Allow Commands
-- changes every player's permission at once).
local statePending = false
local function broadcastSoon()
	if not statePending then
		statePending = true
		task.defer(function()
			statePending = false
			broadcastState()
		end)
	end
end

-- The world's name as everyone may read it (Roblox's filter, for a broadcast).
local function filterName(name: string, userId: number): string
	local ok, result = pcall(function(): string
		local filtered = TextService:FilterStringAsync(name, userId, Enum.TextFilterContext.PublicChat)
		return filtered:GetNonChatStringForBroadcastAsync()
	end)
	if ok and type(result) == "string" then
		return WorldSettings.cleanName(result)
	end
	warn(`[IceVoxel] the world's name could not be filtered ({result}); it is {WorldSettings.DEFAULT_NAME}`)
	return WorldSettings.DEFAULT_NAME
end

-- Loads the character (yields until it is there): Player:LoadCharacterAsync, Roblox's current
-- name for it, or LoadCharacter on an engine without it.
local function spawnCharacter(player: Player): (boolean, unknown)
	local anyPlayer = player :: any
	local found, method = pcall(function(): unknown
		return anyPlayer.LoadCharacterAsync
	end)
	if found and type(method) == "function" then
		return pcall(method :: (Player) -> (), player)
	end
	return pcall(function()
		anyPlayer:LoadCharacter()
	end)
end

local function loadCharacter(player: Player)
	if loading[player] or player.Parent == nil then
		return
	end
	loading[player] = true
	local ok, err = spawnCharacter(player)
	loading[player] = nil
	if not ok then
		warn(`[IceVoxel] {player.Name}'s character did not load: {err}`)
	end
end

local function onEnter(player: Player, _payload: buffer)
	if not WorldInfo.exists() then
		-- (Not yet: the title screen's state may be behind.)
		sendState(player)
		return
	end
	entered[player] = true
	if player.Character == nil then
		task.spawn(loadCharacter, player)
	end
end

local function onCreate(start: (WorldSettings.Settings) -> (), player: Player, payload: buffer)
	local function answer(ok: boolean, message: string)
		local network = net
		if network and player.Parent then
			network.send(
				player,
				Protocol.ServerMessage.CreateWorldResult,
				Protocol.encodeCreateWorldResult(ok, message)
			)
		end
	end
	-- (Answered even when too fast: the screen waits for an answer.)
	local now = os.clock()
	if now - (lastRequest[player] or -math.huge) < REQUEST_INTERVAL then
		answer(false, "Too fast: try again in a moment")
		return
	end
	lastRequest[player] = now
	local request = Protocol.decodeCreateWorld(payload)
	if request == nil then
		answer(false, "That request makes no sense")
		return
	end
	local refusal = WorldInfo.refusal(Operators.isOperator(player), busy)
	if refusal then
		answer(false, refusal)
		return
	end
	local settings, problem = WorldSettings.validate({
		name = request.name,
		gameMode = request.gameMode,
		difficulty = request.difficulty,
		allowCommands = request.allowCommands,
		worldType = request.worldType,
		options = WorldTypes.decodeOptions(request.options),
		structures = request.structures,
		seed = request.seed,
	}, function(): number
		return Random.new():NextInteger(1, 2_147_483_646)
	end)
	if settings == nil then
		answer(false, problem or "Those settings can't make a world")
		return
	end
	busy = true
	broadcastState()
	-- (Yields: a web call.)
	settings.name = filterName(settings.name, player.UserId)
	local ok, err = WorldInfo.create(settings, start)
	busy = false
	if ok then
		print(
			`[IceVoxel] {player.Name} created the world "{settings.name}" ({settings.worldType}, seed {WorldSettings.seedText(
				settings.seed
			)})`
		)
	else
		warn(`[IceVoxel] the world could not be created: {err}`)
	end
	answer(ok, if ok then "" else "The world could not be created; the server needs a restart")
	broadcastState()
end

local function watchCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid == nil or not humanoid:IsA("Humanoid") then
		return
	end
	humanoid.Died:Connect(function()
		task.wait(Players.RespawnTime)
		if player.Parent and entered[player] and player.Character == character then
			loadCharacter(player)
		end
	end)
end

--[[
	Starts the title screen's server side on the lobby's net. `start` is the boot's startWorld,
	called once with the world's settings when the operator creates it (World/WorldInfo.create).
]]
function WorldMenu.start(serverNet: ServerNet.ServerNet, start: (WorldSettings.Settings) -> ())
	assert(net == nil, "WorldMenu.start was already called")
	net = serverNet
	Players.CharacterAutoLoads = false
	serverNet.on(Protocol.ClientMessage.CreateWorld, function(player: Player, payload: buffer)
		onCreate(start, player, payload)
	end)
	serverNet.on(Protocol.ClientMessage.EnterWorld, onEnter)

	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(function(character)
			watchCharacter(player, character)
		end)
		-- (One Roblox loaded before the boot turned that off: nobody stands in no world.)
		local early = player.Character
		if early and not entered[player] then
			player.Character = nil
			early:Destroy()
		end
		sendState(player)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayer, player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		entered[player] = nil
		loading[player] = nil
		lastRequest[player] = nil
	end)
	-- (Who the operator is shows on the title screen.)
	Operators.changed:Connect(broadcastSoon)
end

return WorldMenu
