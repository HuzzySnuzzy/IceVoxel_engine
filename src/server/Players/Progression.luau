--!strict
--[[
	Progression on the server: every player's knowledge, Age and skills (the rules are
	Shared/Progression, pure and tested; this plays them out). Config.Progression turns it on and
	off and tunes it.

	  Joining    a fresh state at once (the Stone Age's gate meanwhile), then the saved one from
	             Players/ProgressStore (retried; when it can't be read, nothing is saved this
	             session). Nothing is earned until it is there (a first time missed meanwhile
	             counts the next time). Then the Ages are checked and the client gets its
	             Progress message.
	  Earning    survival and adventure players only (creative and spectator players earn
	             nothing), through Shared/Progression:
	               * a block broken (ServerNet's `mined` rule): its discovery, ores and logs a
	                 repeat; nothing for a block placed after generation (EditRules.placed);
	               * a crafting result taken, every craft of a shift click too, and stacks taken
	                 out of a furnace's or machine's output (the window's `onTake`,
	                 Inventory/Menu): crafting and smelting discoveries and repeats;
	               * the biome stood in, every Config.Progression.BiomeInterval seconds (the
	                 generator's surface biome of the column): a first visit;
	               * other parts of the server: `award`, `discover`, `killed` (mobs).
	             After every change the Ages are checked (Progression.advance): an Age reached is
	             told to everyone in the chat ("Steve has reached the Iron Age", Minecraft's
	             advancement message), and the player's client shows its banner (Ui/AgeToast).
	  Gating     each player's window gets the recipe gate (Window `recipes`: Progression.allows,
	             open to creative players and with Config.Progression.GateRecipes off), so the
	             server never offers a locked crafting result and furnaces and machines take no
	             input that smelts into one (Inventory/Menu). When the Age, the skills or the
	             game mode change, the open grid's result is worked out again.
	  Skills     UnlockSkill messages: Progression.unlock (the Age, the prerequisites, the points)
	             once the saved state is loaded; refusals are answered with a Notice.
	  Perks      what other parts ask: `miningFactor` (ServerNet's timing checks), `wear`
	             (Players/Inventories' tool wear), `thirstRate` and `insulation`
	             (Players/ToughAsNails), `boilSpeed` (Players/ItemUse's campfire).
	  Death      Config.Progression.DeathLoss of the progress into the level (0: none).
	  Sending    a player whose progression changed gets one Progress message a frame at most
	             (Protocol: points, Age, skills, discovery counts, milestones met).
	  Saving     Players/ProgressStore: on leave, on shutdown (BindToClose, waiting up to
	             SHUTDOWN_WAIT seconds) and every Config.Progression.SaveInterval seconds while
	             changed, never for a player whose saved progress could not be read.
	  Commands   /knowledge (/xp) and /age (Players/ProgressionCommand; changing needs the /time
	             rule: Config.Gameplay.Admins, the owner, Studio).

	For the mobs: when a player kills a mob, call `Progression.killed(player, mobName)` (a mob
	kind's first kill is a discovery, 10 points; every kill a repeat of Knowledge.MOBS: animals 1,
	monsters 5, others 3).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Biomes = require(Shared.Biomes)
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local Menu = require(Shared.Inventory.Menu)
local Progression = require(Shared.Progression)
local Protocol = require(Shared.Net.Protocol)
local Types = require(Shared.Inventory.Types)

local ServerNet = require(script.Parent.Parent.Network.ServerNet)
local WorldServer = require(script.Parent.Parent.World.WorldServer)
local GameModeCommand = require(script.Parent.GameModeCommand)
local GameModes = require(script.Parent.GameModes)
local Inventories = require(script.Parent.Inventories)
local ProgressionCommand = require(script.Parent.ProgressionCommand)
local ProgressStore = require(script.Parent.ProgressStore)

local BLOCK = Config.BlockSize
local SHUTDOWN_WAIT = 25
-- UnlockSkill messages a player may send per second.
local UNLOCKS_PER_SECOND = 5

type Entry = {
	state: Progression.State,
	session: Progression.Session,
	-- The saved state was read (or there is none to read); before that, nothing is earned.
	loaded: boolean,
	canSave: boolean,
	-- Changed since the last save / the last Progress message.
	saveDirty: boolean,
	sendDirty: boolean,
	saving: boolean,
	lastSave: number,
	-- The window the gate is on (re-hooked when Inventories makes a new one).
	window: Types.Window?,
	lastBiome: number,
	unlockTokens: number,
	unlockAt: number,
}

local ProgressionServer = {}

local entries: { [Player]: Entry } = {}
local net: ServerNet.ServerNet? = nil
local store: ProgressStore.Store? = nil
local savesInFlight = 0
local started = false

local function enabled(): boolean
	return Config.Progression.Enabled == true
end

-- Does `player` earn knowledge now (survival and adventure: Minecraft's hasExperience)?
local function earns(player: Player): boolean
	return GameMode.isSurvivalLike(GameMode.of(player))
end

local function notify(player: Player, text: string)
	local serverNet = net
	if serverNet and player.Parent then
		serverNet.send(player, Protocol.ServerMessage.Notice, Protocol.encodeNotice(text))
	end
end

-- The open crafting grid's result again (the gate changed), and a snapshot.
local function refreshWindow(player: Player)
	local window = Inventories.get(player)
	if window then
		Menu.updateCraft(window)
		Inventories.markDirty(player)
	end
end

-- Enters the Ages the player's progress opens (told to everyone); whether any was.
local function checkAges(player: Player, entry: Entry): boolean
	local reached = Progression.advance(entry.state, entry.session)
	for _, age in reached do
		for _, other in Players:GetPlayers() do
			notify(other, `{player.DisplayName} has reached the {age.name}`)
		end
	end
	if #reached > 0 then
		refreshWindow(player)
	end
	return #reached > 0
end

-- Something changed: check the Ages, then send and save it.
local function changed(player: Player, entry: Entry)
	entry.sendDirty = true
	entry.saveDirty = true
	checkAges(player, entry)
end

local function entryOf(player: Player): Entry?
	if not enabled() then
		return nil
	end
	return entries[player]
end

-- The player's entry when they earn knowledge now: loaded, in survival or adventure.
local function earner(player: Player): Entry?
	local entry = entryOf(player)
	if entry == nil or not entry.loaded or not earns(player) then
		return nil
	end
	return entry
end

--[[ The API other parts call ]]

-- The player's progression (read only; nil before they joined or with Config.Progression off).
function ProgressionServer.state(player: Player): Progression.State?
	local entry = entryOf(player)
	return if entry then entry.state else nil
end

--[[
	Gives the player `points` of knowledge from `reason` (a Knowledge source: "mob", "other"...;
	perks for it apply), now: no fatigue, no budget, the caller's own reasons for it. Survival and
	adventure players only.
]]
function ProgressionServer.award(player: Player, points: number, reason: string?)
	local entry = earner(player)
	if entry == nil then
		return
	end
	if Progression.award(entry.state, entry.session, points, reason or "other") > 0 then
		changed(player, entry)
	end
end

--[[
	The player did `key` of `category` (Knowledge.CATEGORIES, or a new one) for the first time?
	Its discovery points, once ever. true when it was new.
]]
function ProgressionServer.discover(player: Player, category: string, key: string): boolean
	local entry = earner(player)
	if entry == nil or Progression.found(entry.state, category, key) then
		return false
	end
	Progression.discover(entry.state, entry.session, category, key)
	changed(player, entry)
	return true
end

-- The player killed a mob of kind `mobName` (the mobs' death signal): a discovery and a repeat.
function ProgressionServer.killed(player: Player, mobName: string)
	local entry = earner(player)
	if entry == nil then
		return
	end
	Progression.killed(entry.state, entry.session, mobName, os.clock(), Config.Progression.RepeatBudget)
	changed(player, entry)
end

-- ServerNet's `mined` rule: a survival break of `block`, `placed` after generation or not.
function ProgressionServer.mined(player: Player, block: number, _x: number, _y: number, _z: number, placed: boolean)
	local entry = earner(player)
	if entry == nil or placed or not Blocks.isValid(block) then
		return
	end
	local name = Blocks.get(block).name
	if Progression.mined(entry.state, entry.session, name, false, os.clock(), Config.Progression.RepeatBudget) > 0 then
		changed(player, entry)
	end
end

-- May the player make `item` (crafting and smelting results)? The window's gate.
function ProgressionServer.allows(player: Player, item: number): boolean
	if not enabled() or not Config.Progression.GateRecipes or GameMode.instabuildOf(player) then
		return true
	end
	local entry = entries[player]
	return entry == nil or Progression.allows(entry.state, item)
end

-- The player's mining speed with `tool` (ServerNet's `miningFactor` rule).
function ProgressionServer.miningFactor(player: Player, tool: number?): number
	local entry = entryOf(player)
	return if entry then Progression.miningFactor(entry.state, tool) else 1
end

-- Of `amount` wear points on the player's tool, those that land (Smithing, Tempering).
function ProgressionServer.wear(player: Player, amount: number): number
	local entry = entryOf(player)
	return if entry then Progression.wear(entry.state, amount, math.random) else amount
end

-- How fast the player's thirst drains (Hardy, Endurance).
function ProgressionServer.thirstRate(player: Player): number
	local entry = entryOf(player)
	return if entry then Progression.thirstRate(entry.state) else 1
end

-- Steps of warmth and of cooling the player's perks add to their armor's (Insulation...).
function ProgressionServer.insulation(player: Player): number
	local entry = entryOf(player)
	return if entry then Progression.insulation(entry.state) else 0
end

-- How many times as fast a campfire boils the player's water (Firekeeper).
function ProgressionServer.boilSpeed(player: Player): number
	local entry = entryOf(player)
	return if entry then Progression.boilSpeed(entry.state) else 1
end

--[[ Windows: the gate and what is taken ]]

local function hook(player: Player, entry: Entry)
	local window = Inventories.get(player)
	if window == nil or window == entry.window then
		return
	end
	entry.window = window
	window.recipes = function(item: number): boolean
		return ProgressionServer.allows(player, item)
	end
	window.onTake = function(kind: string, stack: Types.Stack)
		local current = earner(player)
		local def = Items.get(stack.item)
		if current == nil or def == nil then
			return
		end
		local name = def.name
		local now, budget = os.clock(), Config.Progression.RepeatBudget
		local given = if kind == "craft"
			then Progression.crafted(current.state, current.session, name, now, budget)
			else Progression.smelted(current.state, current.session, name, stack.count, now, budget)
		if given > 0 then
			changed(player, current)
		end
	end
	Menu.updateCraft(window)
end

--[[ Saving ]]

-- Saves the player's progress if it changed; keeps saving while it changes during the save.
local function save(player: Player, entry: Entry)
	local target = store
	if target == nil or not entry.loaded or not entry.canSave or entry.saving then
		return
	end
	entry.saving = true
	savesInFlight += 1
	while entry.saveDirty do
		entry.saveDirty = false
		entry.lastSave = os.clock()
		if not target:save(player, Progression.toRecord(entry.state)) then
			entry.saveDirty = true
			break
		end
	end
	entry.saving = false
	savesInFlight -= 1
end

--[[ Players ]]

local function onCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid and humanoid:IsA("Humanoid") then
		humanoid.Died:Connect(function()
			local entry = earner(player)
			local loss = Config.Progression.DeathLoss
			if entry and type(loss) == "number" and loss > 0 then
				local before = entry.state.points
				Progression.die(entry.state, loss)
				if entry.state.points ~= before then
					changed(player, entry)
				end
			end
		end)
	end
end

local function onPlayer(player: Player)
	local entry: Entry = {
		state = Progression.new(),
		session = Progression.Knowledge.newSession(),
		loaded = false,
		canSave = store ~= nil,
		saveDirty = false,
		sendDirty = false,
		saving = false,
		lastSave = os.clock(),
		window = nil,
		lastBiome = 0,
		unlockTokens = UNLOCKS_PER_SECOND,
		unlockAt = os.clock(),
	}
	entries[player] = entry
	hook(player, entry)
	player.CharacterAdded:Connect(function(character)
		onCharacter(player, character)
	end)
	if player.Character then
		task.spawn(onCharacter, player, player.Character)
	end

	local saved = Progression.new()
	local target = store
	if target then
		local ok, record = target:load(player)
		if ok then
			saved = Progression.fromRecord(record)
		else
			entry.canSave = false
		end
	end
	if entries[player] ~= entry then
		-- (Left while it loaded.)
		return
	end
	entry.state = saved
	entry.loaded = true
	entry.sendDirty = true
	-- (Saved again only when an Age was reached on reading it.)
	entry.saveDirty = checkAges(player, entry)
	refreshWindow(player)
end

local function onUnlock(player: Player, payload: buffer)
	local entry = entryOf(player)
	local index = Protocol.decodeUnlockSkill(payload)
	if entry == nil or index == nil then
		return
	end
	local now = os.clock()
	entry.unlockTokens = math.min(UNLOCKS_PER_SECOND, entry.unlockTokens + (now - entry.unlockAt) * UNLOCKS_PER_SECOND)
	entry.unlockAt = now
	if entry.unlockTokens < 1 then
		return
	end
	entry.unlockTokens -= 1
	local skill = Progression.Skills.get(index)
	if skill == nil then
		return
	end
	if not entry.loaded then
		notify(player, "Your progress is still loading")
		return
	end
	local ok, _, text = Progression.unlock(entry.state, skill.id)
	if ok then
		notify(player, `Unlocked {skill.name}`)
		changed(player, entry)
		refreshWindow(player)
	else
		-- (The client's view may be stale: send it again with the reason.)
		entry.sendDirty = true
		notify(player, text or `Can't unlock {skill.name}`)
	end
end

--[[ Commands ]]

local function runCommand(player: Player, text: string)
	if not ProgressionCommand.matches(text) then
		return
	end
	local studio = RunService:IsStudio()
	local owner = studio or GameModes.isOwner(player)
	if player.Parent == nil then
		return
	end
	if not enabled() then
		notify(player, "Progression is turned off here")
		return
	end
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
		return
	end
	local result = ProgressionCommand.run(text, {
		source = source,
		players = candidates,
		mayUse = GameModeCommand.isAdmin(player.UserId, Config.Gameplay.Admins, owner, studio),
		stateOf = function(key: any): Progression.State?
			local entry = entries[key :: Player]
			return if entry and entry.loaded then entry.state else nil
		end,
	})
	if result == nil then
		return
	end
	for _, key in result.changed do
		local target = key :: Player
		local entry = entries[target]
		if entry then
			changed(target, entry)
			refreshWindow(target)
		end
	end
	for _, message in result.feedback do
		notify(player, message)
	end
end

local function listenToCommands()
	if TextChatService.ChatVersion == Enum.ChatVersion.LegacyChatService then
		local function onPlayer(player: Player)
			player.Chatted:Connect(function(message: string)
				runCommand(player, message)
			end)
		end
		Players.PlayerAdded:Connect(onPlayer)
		for _, player in Players:GetPlayers() do
			onPlayer(player)
		end
		return
	end
	local function command(name: string, aliases: { string })
		local instance = Instance.new("TextChatCommand")
		instance.Name = name
		instance.PrimaryAlias = aliases[1]
		instance.SecondaryAlias = aliases[2] or ""
		instance.Triggered:Connect(function(source: TextSource, text: string)
			local player = Players:GetPlayerByUserId(source.UserId)
			if player then
				runCommand(player, text)
			end
		end)
		-- Commands work when parented to TextChatService (replicated, so clients sink the message).
		instance.Parent = TextChatService
	end
	command("IceVoxelKnowledge", ProgressionCommand.KNOWLEDGE_ALIASES)
	command("IceVoxelAge", ProgressionCommand.AGE_ALIASES)
end

--[[ Every frame ]]

local function sampleBiome(world: WorldServer.World, player: Player, entry: Entry)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") or earner(player) == nil then
		return
	end
	local position = root.Position
	local x, z = math.floor(position.X / BLOCK), math.floor(position.Z / BLOCK)
	if math.abs(x) > Protocol.MAX_COORDINATE or math.abs(z) > Protocol.MAX_COORDINATE then
		return
	end
	local _, index = world.generator.column(x, z)
	local biome = Biomes.get(index)
	if biome and not Progression.found(entry.state, "biome", biome.name) then
		Progression.visited(entry.state, entry.session, biome.name)
		changed(player, entry)
	end
end

--[[
	Starts progression. Inventories (the windows) and GameModes must have started; ServerNet's rules
	come from the server script (`mined`, `miningFactor`).
]]
function ProgressionServer.start(serverNet: ServerNet.ServerNet, world: WorldServer.World)
	assert(not started, "Progression.start was already called")
	started = true
	net = serverNet
	if not enabled() then
		return
	end
	store = ProgressStore.open(Config.Progression.Save == true)

	serverNet.on(Protocol.ClientMessage.UnlockSkill, onUnlock)
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayer, player)
	end
	Players.PlayerRemoving:Connect(function(player)
		local entry = entries[player]
		entries[player] = nil
		if entry and entry.loaded then
			save(player, entry)
		end
	end)
	-- Creative players have every recipe: the open grid's result again after a switch.
	GameModes.changed:Connect(function(player: Player)
		if entries[player] then
			refreshWindow(player)
		end
	end)
	listenToCommands()

	game:BindToClose(function()
		local began = os.clock()
		repeat
			local waiting = savesInFlight > 0
			for player, entry in entries do
				if entry.loaded and entry.saveDirty and entry.canSave and not entry.saving then
					task.spawn(save, player, entry)
					waiting = true
				end
			end
			if waiting then
				task.wait(0.2)
			end
		until not waiting or os.clock() - began > SHUTDOWN_WAIT
	end)

	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		local interval = Config.Progression.BiomeInterval
		local saveInterval = Config.Progression.SaveInterval
		for player, entry in entries do
			hook(player, entry)
			if now - entry.lastBiome >= interval then
				entry.lastBiome = now
				sampleBiome(world, player, entry)
			end
			if entry.sendDirty and entry.loaded and player.Parent then
				entry.sendDirty = false
				serverNet.send(
					player,
					Protocol.ServerMessage.Progress,
					Protocol.encodeProgress(Progression.status(entry.state))
				)
			end
			if entry.saveDirty and entry.loaded and entry.canSave and not entry.saving then
				if now - entry.lastSave >= saveInterval then
					task.spawn(save, player, entry)
				end
			end
		end
	end)
end

return ProgressionServer
