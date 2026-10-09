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
	  Loading   WorldAction from an operator while no world exists (World/WorldSave, given to
	            `start` as `saves`): list (answered with WorldList), load (the world's lock, its
	            record and regions read: everyone's title screen shows "Loading world: 12 / 40",
	            then World/WorldInfo.create runs the boot's startWorld with its settings, as
	            Creating does; a load that fails is answered with CreateWorldResult and why, and
	            the server waits on), delete and rename (the name through the text filter first;
	            each answered with the list again and how it went). Only the player's own worlds
	            (the ones they created: `claim` before creating one), and the game's for the
	            game's own people (World/WorldSave's owners). A list a second per player (one
	            asked faster gets the last list again: the screen waits for an answer), and a
	            load, delete or rename a second, as CreateWorld.
	  Entering  EnterWorld (Join World, or the creator's client once its world is made): when the
	            world exists the player's character loads (Player:LoadCharacterAsync, or
	            LoadCharacter on an engine without it), once their record in a saved world was
	            read (`saves.beforeEnter`: their place, inventory and the rest come back on that
	            first character; a few seconds at most). Roblox loads none
	            on its own (Players.CharacterAutoLoads is off from the start), so nobody stands
	            anywhere before the world exists, and the dead are respawned here,
	            Players.RespawnTime after dying (Roblox's own rule), while they are in the world.
	            With Config.Characters on, EnterWorld names the character played
	            (Net/CharacterSync.encodeEnter): it must be the one the player selected, loaded
	            and alive (Players/CharacterStore.enter puts it into the world: its entry there,
	            its things; a refusal disconnects the player with why, as their screen is gone
	            already), and every body spawns with its look: Player
	            :LoadCharacterWithHumanoidDescriptionAsync with the character's
	            HumanoidDescription (Players/CharacterLooks; the older name, then
	            LoadCharacterAsync, when that fails), never again before the last one loaded
	            (`loading`). The parking, the client's placement and the floating origin don't
	            change: they work on whatever body spawned.
	Started only with Config.MainMenu.Enabled (before the world, on the lobby's net,
	Network/LobbyNet); without it the boot creates the world at once and Roblox loads characters.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local CharacterSync = require(Shared.Net.CharacterSync)
local Config = require(Shared.Config)
local Protocol = require(Shared.Net.Protocol)
local WorldSettings = require(Shared.WorldSettings)
local WorldTypes = require(Shared.Generation.WorldTypes)

local ServerNet = require(script.Parent.Parent.Network.ServerNet)
local WorldInfo = require(script.Parent.Parent.World.WorldInfo)
local CharacterLooks = require(script.Parent.CharacterLooks)
local CharacterStore = require(script.Parent.CharacterStore)
local Operators = require(script.Parent.Operators)

-- Seconds between a player's CreateWorld requests.
local REQUEST_INTERVAL = 1

local WorldMenu = {}

-- What the title screen asks of saved worlds (World/WorldSave).
export type Saves = {
	-- Whether worlds can be saved and loaded here (Protocol.SaveState) and why not.
	status: () -> (number, string?),
	-- The saved worlds `player` may open (yields), or nil and why not.
	list: (player: Player) -> ({ Protocol.WorldEntry }?, string?),
	-- `player` creates the next world (its owner): true, or false and why not (their list is full).
	claim: (player: Player) -> (boolean, string?),
	-- Opens a saved world of `player`'s for startWorld (yields): its settings, or nil and why not.
	prepare: (
		id: string,
		progress: (done: number, total: number) -> (),
		player: Player
	) -> (WorldSettings.Settings?, string?),
	-- A world did not start: never save it, give it back.
	abandon: () -> (),
	delete: (id: string, player: Player) -> (boolean, string?),
	rename: (id: string, name: string, player: Player) -> (boolean, string?),
	-- Yields (a few seconds at most) until the player's record in the world was read.
	beforeEnter: (player: Player) -> (),
	-- Tells everyone the keys a load read (the title screen's progress).
	progress: (done: number, total: number, name: string) -> (),
}

local net: ServerNet.ServerNet? = nil
-- Players who entered the world (their character loads, and comes back after death).
local entered: { [Player]: boolean } = {}
local loading: { [Player]: boolean } = {}
local lastRequest: { [Player]: number } = {}
-- Per player: the last list request and the last load, delete or rename.
local lastAction: { [Player]: { [string]: number } } = {}
-- Per player: the last list sent (a list asked too fast gets it again).
local lastList: { [Player]: { Protocol.WorldEntry } } = {}
local savesInUse: Saves? = nil
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

-- `player`'s method `name` (Roblox's current name for it), else `older` (nil: neither).
local function method(player: Player, name: string, older: string): ((...any) -> ...any)?
	local anyPlayer = player :: any
	for _, key in { name, older } do
		local found, value = pcall(function(): unknown
			return anyPlayer[key]
		end)
		if found and type(value) == "function" then
			return value :: (...any) -> ...any
		end
	end
	return nil
end

--[[
	Loads the character (yields until it is there): with a character selected (Config.Characters),
	Player:LoadCharacterWithHumanoidDescriptionAsync with its look; else, or when that fails,
	Player:LoadCharacterAsync (Roblox's current names; the older ones on an engine without them).
]]
local function spawnCharacter(player: Player): (boolean, unknown)
	local look = if Config.Characters.Enabled then CharacterStore.look(player) else nil
	if look then
		local load = method(player, "LoadCharacterWithHumanoidDescriptionAsync", "LoadCharacterWithHumanoidDescription")
		if load then
			local description = CharacterLooks.description(look)
			local ok, err = pcall(load, player, description)
			if ok then
				return true, nil
			end
			warn(`[IceVoxel] {player.Name}'s character did not load with its look ({err}); loading it without`)
		end
	end
	local load = method(player, "LoadCharacterAsync", "LoadCharacter")
	if load == nil then
		return false, "no way to load a character"
	end
	return pcall(load, player)
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

local function onEnter(player: Player, payload: buffer)
	local charId = CharacterSync.decodeEnter(payload)
	if charId == nil then
		return
	end
	if not WorldInfo.exists() then
		-- (Not yet: the title screen's state may be behind.)
		sendState(player)
		return
	end
	if entered[player] then
		return
	end
	entered[player] = true
	if Config.Characters.Enabled then
		task.spawn(function()
			-- (The character the title screen chose goes into the world: its place and things.)
			local ok, why = CharacterStore.enter(player, charId)
			if not ok then
				entered[player] = nil
				warn(`[IceVoxel] {player.Name} could not enter: {why}`)
				if player.Parent then
					player:Kick(`Your character could not enter the world ({why}). Please rejoin.`)
				end
				return
			end
			if player.Character == nil and entered[player] then
				loadCharacter(player)
			end
		end)
	elseif player.Character == nil then
		task.spawn(function()
			-- (A saved world's player comes back as they were: their record first.)
			local saves = savesInUse
			if saves then
				saves.beforeEnter(player)
			end
			loadCharacter(player)
		end)
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
	-- (Yields: the creator's world list must have room for it, when worlds are saved.)
	local saves = savesInUse
	if saves then
		local room, full = saves.claim(player)
		if not room then
			busy = false
			answer(false, `You can't make another world: {full}`)
			broadcastState()
			return
		end
	end
	-- (Yields: a web call.)
	settings.name = filterName(settings.name, player.UserId)
	local ok, err = WorldInfo.create(settings, start)
	busy = false
	if not ok and saves then
		saves.abandon()
	end
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

-- The saved worlds for `player`, with `message` (how the last action went). `again`: the list
-- sent last (asked too fast: no read).
local function sendList(saves: Saves, player: Player, message: string?, again: boolean?)
	local network = net
	local worlds: { Protocol.WorldEntry }?, problem: string? = nil, nil
	if again then
		worlds = lastList[player]
	else
		worlds, problem = saves.list(player)
		if worlds and player.Parent then
			lastList[player] = worlds
		end
	end
	local state = saves.status()
	if network and player.Parent then
		network.send(
			player,
			Protocol.ServerMessage.WorldList,
			Protocol.encodeWorldList(
				worlds or {},
				state == Protocol.SaveState.On or state == Protocol.SaveState.Off,
				problem or message or ""
			)
		)
	end
end

local function onWorldAction(saves: Saves, start: (WorldSettings.Settings) -> (), player: Player, payload: buffer)
	local action, id, name = Protocol.decodeWorldAction(payload)
	if action == nil then
		return
	end
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
	local now = os.clock()
	local load = action == Protocol.WorldAction.Load
	local kind = if action == Protocol.WorldAction.List then "list" else "change"
	local times = lastAction[player]
	if times == nil then
		times = {}
		lastAction[player] = times
	end
	if now - (times[kind] or -math.huge) < REQUEST_INTERVAL then
		-- (Every request is answered: the screen waits for one.)
		if load then
			answer(false, "Too fast: try again in a moment")
		elseif kind == "change" then
			sendList(saves, player, "Too fast: try again in a moment")
		else
			sendList(saves, player, if lastList[player] then nil else "Too fast: try again in a moment", true)
		end
		return
	end
	times[kind] = now
	local refusal = WorldInfo.refusal(Operators.isOperator(player), busy)
	if refusal then
		refusal = string.gsub(refusal, "create the world", "load worlds")
		if load then
			answer(false, refusal)
		else
			sendList(saves, player, refusal)
		end
		return
	end
	if action == Protocol.WorldAction.List then
		sendList(saves, player, nil)
	elseif action == Protocol.WorldAction.Delete then
		busy = true
		local ok, problem = saves.delete(id, player)
		busy = false
		sendList(saves, player, if ok then "The world was deleted" else `It could not be deleted: {problem}`)
	elseif action == Protocol.WorldAction.Rename then
		busy = true
		local filtered = filterName(WorldSettings.cleanName(name), player.UserId)
		local ok, problem = saves.rename(id, filtered, player)
		busy = false
		sendList(saves, player, if ok then `Renamed to "{filtered}"` else `It could not be renamed: {problem}`)
	elseif load then
		busy = true
		broadcastState()
		local settings, problem = saves.prepare(id, function(done: number, total: number)
			saves.progress(done, total, "")
		end, player)
		if settings == nil then
			busy = false
			warn(`[IceVoxel] the world {id} could not be loaded: {problem}`)
			answer(false, `The world could not be loaded: {problem}`)
			broadcastState()
			return
		end
		local ok, err = WorldInfo.create(settings, start)
		busy = false
		if ok then
			print(`[IceVoxel] {player.Name} loaded the world "{settings.name}" ({id})`)
		else
			saves.abandon()
			warn(`[IceVoxel] the loaded world could not start: {err}`)
		end
		answer(ok, if ok then "" else "The world could not be started; the server needs a restart")
		broadcastState()
	end
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
	called once with the world's settings when the operator creates it (World/WorldInfo.create)
	or loads one of `saves` (World/WorldSave; nil: no Load World).
]]
function WorldMenu.start(serverNet: ServerNet.ServerNet, start: (WorldSettings.Settings) -> (), saves: Saves?)
	assert(net == nil, "WorldMenu.start was already called")
	net = serverNet
	savesInUse = saves
	Players.CharacterAutoLoads = false
	serverNet.on(Protocol.ClientMessage.CreateWorld, function(player: Player, payload: buffer)
		onCreate(start, player, payload)
	end)
	if saves then
		serverNet.on(Protocol.ClientMessage.WorldAction, function(player: Player, payload: buffer)
			onWorldAction(saves, start, player, payload)
		end)
	end
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
		lastAction[player] = nil
		lastList[player] = nil
	end)
	-- (Who the operator is shows on the title screen.)
	Operators.changed:Connect(broadcastSoon)
end

return WorldMenu
