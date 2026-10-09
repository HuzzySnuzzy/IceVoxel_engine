--!strict
--[[
	Players' characters on the server (Terraria's player files, Config.Characters; the rules:
	Shared/Characters, Save/CharacterSaves; the bytes: Save/CharacterCodec), on the lobby's net
	(Network/LobbyNet), so the title screen's character pages (client Ui/MainMenu) work before
	any world exists.

	  Store      the DataStore Config.Characters.StoreName ("IceVoxelCharacters_v1"), looked at
	             once at boot (Config.Save.Enabled off, or Studio without API access: every
	             character lasts for the session, kept in this server's memory, and the list says
	             so). Writes name the user (RTBF: UpdateAsync's user ids).
	  Joining    each player's list is read once (Save/CharacterSaves.readIndex: three tries, 2
	             then 4 s apart). One that could not be read, or holds what this version can't
	             read, is never written this session: the list says why and new characters last
	             for the session (memory). Then the migration (Config.Characters.Migrate:
	             Save/CharacterMigration): a user whose list has not looked at their old progress
	             yet gets "Character 1" made from it (Players/ProgressStore read once; a failed
	             read decides nothing), and the list goes to the client (ServerMessage.Characters:
	             Net/CharacterSync).
	  Actions    CharacterAction (Net/CharacterSync): list; create (the name through Roblox's
	             filter for everyone, as world names are; the look kept only over this server's
	             snapshot of the user's avatar, Appearance.sanitize; at most Characters.MAX; made
	             and selected at once); delete and rename (refused while another server has the
	             character); select (loads it and takes its lock, waiting up to
	             Config.Characters.LockWait for another server still saving it, then "This
	             character is open on another server"; a dead one is refused); avatar (the user's
	             own avatar for the editor: ServerMessage.Avatar, and the editor's preview rig);
	             preview (a listed character's rig, wearing its armour, vanity and accessories:
	             `dressedOf`) and edit preview (the editor's rig with an edited look):
	             Players/CharacterLooks. A change a second (create, delete, rename, select),
	             lists and previews four a second; one change at a time per player
	             (`busy` in the list meanwhile). Once a player entered the world their character
	             is theirs for the session: switching means leaving and rejoining.
	  Entering   `enter` (Players/WorldMenu's EnterWorld, or the title screen off): the selected,
	             loaded, living character goes into the world: World/WorldSave.enterCharacter
	             (where it stood there, its game mode, an old record taken in: only by a
	             character that is saved, in a world that saves progress, not in creative; the
	             world's mark waits for this character's first save with it, confirmImport), then its
	             inventory and equipment (Players/Inventories.restore, restoreEquipment), Tough
	             As Nails, effects, mana and crystals (Players/Mana) and progress
	             (Players/Progression.restore); its health on its first body, the leftovers of an
	             old record dropped at its feet, the nametag (Humanoid.DisplayName) its name.
	             `look` gives Players/WorldMenu the look it spawns with.
	  Saving     every Config.Characters.SaveInterval seconds (jittered) while selected (the
	             lock's heartbeat too: a character not in the world yet only renews its lock), on
	             leaving, at shutdown (BindToClose, within 25 of its 30 s) and on /save-all
	             (WorldSave.onSaveAll), each capture numbered (an older one never writes over a
	             newer); the last save gives the lock back and writes the character's line in the
	             list (time played, last played, dead). A lost lock stops saving that character
	             (the player is told). What a leaving player had is taken from the last look at
	             them (every 2 s), as the parts that keep it forget them as they leave (mana and
	             crystals from Players/Mana while it still has them). Progress is written where
	             the world saves progress (Progression.savesProgress); elsewhere the progress the
	             character came with is written back unchanged.
	  Fair       a character carries its things from world to world (Terraria), so they leave a
	             world only from a fair visit: one where the world saves progress (no Allow
	             Commands, not superflat or debug) and the player was never in creative. From the
	             moment a visit stops being fair (entering such a world, or in creative mode;
	             switching to creative later: `kept`), the things the character had then are
	             what is saved: inventory, armor, equipment, Mana Crystals, mana and effects (what
	             creative or a cheat world makes stays in that world, as Terraria keeps Journey
	             characters apart). The player is told once.
	  Death      every death counts (`deaths`); Classic characters keep everything
	             (`keepsInventory`, Players/Inventories' keep rule), Mediumcore and Hardcore drop
	             it; a Hardcore character dies for good: marked dead and saved at once, its player
	             a spectator for the rest of the session. Respawns come with full mana.
	  No title   with Config.MainMenu.Enabled off (Roblox loads characters itself), each player
	             plays their most recently played living character, or one made from their avatar
	             (the default difficulty) when they have none living (one that can't be loaded,
	             busy on another server or the store failing, is never replaced by a new one: the
	             player is kicked with the reason, to rejoin), entered as soon as the world is
	             ready; its look goes
	             onto each body Roblox makes (Humanoid:ApplyDescriptionResetAsync: the only live
	             apply, accepted for this mode).
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Appearance = require(Shared.Characters.Appearance)
local CharacterSync = require(Shared.Net.CharacterSync)
local Characters = require(Shared.Characters)
local Config = require(Shared.Config)
local Accessories = require(Shared.Items.Accessories)
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local Protocol = require(Shared.Net.Protocol)
local Types = require(Shared.Inventory.Types)

local Server = script.Parent.Parent
local ServerNet = require(Server.Network.ServerNet)
local CharacterCodec = require(Server.Save.CharacterCodec)
local CharacterMigration = require(Server.Save.CharacterMigration)
local CharacterSaves = require(Server.Save.CharacterSaves)
local SaveScheduler = require(Server.Save.SaveScheduler)
local WorldStore = require(Server.Save.WorldStore)
local WorldInfo = require(Server.World.WorldInfo)
local WorldSave = require(Server.World.WorldSave)
local Bodies = require(script.Parent.Characters)
local CharacterLooks = require(script.Parent.CharacterLooks)
local Effects = require(script.Parent.Effects)
local GameModes = require(script.Parent.GameModes)
local Inventories = require(script.Parent.Inventories)
local Mana = require(script.Parent.Mana)
local Progression = require(script.Parent.Progression)
local ProgressStore = require(script.Parent.ProgressStore)
local ToughAsNails = require(script.Parent.ToughAsNails)

type Record = CharacterCodec.Record
type Stack = Items.Stack

-- Seconds between a player's changes (create, delete, rename, select), and between lists and
-- previews.
local CHANGE_INTERVAL = 1
local LIST_INTERVAL = 0.25
-- Seconds BindToClose spends saving (of Roblox's 30), and between looks at what players have.
local CLOSE_SECONDS = 25
local CACHE_INTERVAL = 2
-- Looks at players' progress every this many cache steps (it is the largest to copy).
local PROGRESS_EVERY = 5
-- The list's words.
local SESSION_NOTE = "Characters last for this session only"
local UNFAIR_WORLD =
	"This world can't change your character (it allows commands, or is superflat or debug): it leaves with the things and progress it brought"
local CREATIVE_NOTE = "Your character is in creative: it leaves this world with the things it had until now"
local A = CharacterSync.Action

-- What a player left with, as last seen (the parts that keep it forget players as they leave).
type Cache = {
	health: number?,
	mana: number?,
	crystals: number?,
	thirst: any,
	temperature: any,
	effects: any,
	progress: unknown?,
}

-- The character a player selected (loaded and locked).
type Selected = {
	id: number,
	-- As loaded, then as last captured (its look, name and the rest).
	record: Record,
	-- Its progress as stored, and whether a newer version's (then written back as it is).
	progress: unknown?,
	progressWritable: boolean,
	-- Its bytes may be written (false: it holds items this version doesn't know).
	canSave: boolean,
	-- Another server took its lock: nothing is written any more.
	lost: boolean,
	-- In the world: the live parts hold its state.
	applied: boolean,
	enteredAt: number,
	playedBase: number,
	inventory: Types.Inventory?,
	cache: Cache,
	nextSave: number,
	saving: boolean,
	-- Its health for its first body, and what an old record left to drop at its feet.
	pendingHealth: number?,
	leftovers: { Stack },
	bodies: number,
	-- The things it had when this visit stopped being fair (see the header: written back instead of
	-- the live ones), nil while it is fair.
	kept: Record?,
	-- The world whose old record it took in, until a save with it was written (then the world's
	-- mark: WorldSave.confirmImport).
	importing: string?,
}

type User = {
	saves: CharacterSaves.Saves,
	-- Kept between sessions (the DataStore), else in this server's memory.
	saving: boolean,
	loaded: boolean,
	index: CharacterCodec.Index,
	-- Why the list is as it is (loading problems), shown until an action says something else.
	note: string,
	busy: boolean,
	selected: Selected?,
	entered: boolean,
	leaving: boolean,
	-- The index still has to record that the migration ran.
	migrateMark: boolean,
	lastList: number,
	lastChange: number,
	-- Looks of listed characters read for their previews, and what they wear there (`dressedOf`).
	looks: { [number]: Appearance.Appearance },
	dressed: { [number]: string },
}

local CharacterStore = {}

local net: ServerNet.ServerNet? = nil
local durable: CharacterSaves.Saves? = nil
local memory: CharacterSaves.Saves? = nil
local probed = false
local storeNote: string? = nil
local closing = false
-- Last saves of players who left, under way (BindToClose waits for them too).
local releasing = 0
local users: { [Player]: User } = {}
local captures = 0
local progressStore: ProgressStore.Store? = nil
local progressStoreOpened = false

--[[ Messages ]]

local function send(player: Player, kind: number, payload: buffer)
	local network = net
	if network and player.Parent then
		network.send(player, kind, payload)
	end
end

local function notify(player: Player, text: string)
	send(player, Protocol.ServerMessage.Notice, Protocol.encodeNotice(text))
end

-- The user's list as the client shows it (the selected character's line as it is now).
local function summaries(user: User): { Characters.Summary }
	local list: { Characters.Summary } = {}
	local selected = user.selected
	for _, line in user.index.chars do
		if selected and line.id == selected.id then
			table.insert(list, CharacterCodec.summary(selected.record))
		else
			table.insert(list, line)
		end
	end
	Characters.sort(list)
	return list
end

local function sendList(player: Player, user: User, message: string?)
	local selected = user.selected
	send(
		player,
		Protocol.ServerMessage.Characters,
		CharacterSync.encodeCharacters({
			saving = user.saving,
			busy = user.busy or not user.loaded,
			selected = if selected then selected.id else 0,
			max = Characters.MAX,
			message = message or user.note,
			characters = summaries(user),
		})
	)
end

--[[ The store ]]

local function describe(err: unknown): string
	local text = tostring(err)
	if
		RunService:IsStudio() and (string.find(text, "403") or string.find(text, "API") or string.find(text, "publish"))
	then
		return "Studio has no API access"
	end
	return `the DataStore can't be reached ({string.sub(text, 1, 80)})`
end

local function requestType(kind: SaveScheduler.Kind): Enum.DataStoreRequestType
	if kind == "get" then
		return Enum.DataStoreRequestType.GetAsync
	elseif kind == "update" then
		return Enum.DataStoreRequestType.UpdateAsync
	end
	return Enum.DataStoreRequestType.SetIncrementAsync
end

-- The user ids a key is about ("u<UserId>..."), for the DataStore (only real users).
local function userIdsOf(key: string): { number }?
	local id = tonumber(string.match(key, "^u(%-?%d+)"))
	return if id and id > 0 then { id } else nil
end

local function adapter(dataStore: DataStore): WorldStore.Store
	return {
		get = function(key: string): (boolean, unknown)
			return pcall(function(): unknown
				return dataStore:GetAsync(key)
			end)
		end,
		set = function(key: string, value: unknown, userIds: { number }?): (boolean, string?)
			local ok, err = pcall(function()
				dataStore:SetAsync(key, value, userIds or userIdsOf(key))
			end)
			return ok, if ok then nil else tostring(err)
		end,
		update = function(key: string, transform: (unknown) -> unknown?): (boolean, unknown)
			local userIds = userIdsOf(key)
			return pcall(function(): unknown
				return dataStore:UpdateAsync(key, function(old: unknown): (unknown?, { number }?)
					local new = transform(old)
					if new == nil then
						return nil
					end
					return new, userIds
				end)
			end)
		end,
		remove = function(key: string): (boolean, string?)
			local ok, err = pcall(function()
				dataStore:RemoveAsync(key)
			end)
			return ok, if ok then nil else tostring(err)
		end,
	}
end

local function newEnv(unlimited: boolean): WorldStore.Env
	local random = Random.new()
	local job = game.JobId
	if job == "" then
		job = `studio-{HttpService:GenerateGUID(false)}`
	end
	return {
		now = os.clock,
		budget = function(kind: SaveScheduler.Kind): number
			if unlimited then
				return math.huge
			end
			local ok, budget = pcall(function(): number
				return DataStoreService:GetRequestBudgetForRequestType(requestType(kind))
			end)
			return if ok then budget else 1
		end,
		wait = function(seconds: number)
			task.wait(seconds)
		end,
		spawn = function(fn: () -> ())
			task.spawn(fn)
		end,
		time = os.time,
		job = job,
		random = function(): number
			return random:NextNumber()
		end,
	}
end

-- Opens the DataStore and reads one key (see the header): the saves, or nil and why not.
local function probe(): (CharacterSaves.Saves?, string?)
	if not Config.Save.Enabled then
		return nil, "saving is off in this game"
	end
	local okStore, store = pcall(function(): DataStore
		return DataStoreService:GetDataStore(Config.Characters.StoreName)
	end)
	if not okStore then
		return nil, describe(store)
	end
	local readOk, err: unknown = false, nil
	for attempt = 1, 2 do
		readOk, err = pcall(function(): unknown
			return (store :: DataStore):GetAsync("probe")
		end)
		if readOk then
			break
		elseif attempt == 1 then
			task.wait(2)
		end
	end
	if not readOk then
		warn(`[IceVoxel] characters will last for the session only: {err}`)
		return nil, describe(err)
	end
	return CharacterSaves.new(adapter(store :: DataStore), newEnv(false)), nil
end

local function waitForProbe()
	local deadline = os.clock() + 20
	while not probed and os.clock() < deadline do
		task.wait(0.1)
	end
end

local function memorySaves(): CharacterSaves.Saves
	local saves = memory
	if saves == nil then
		saves = CharacterSaves.new(CharacterSaves.memoryStore(), newEnv(true), { cooldown = 0, attempts = 1 })
		memory = saves
	end
	return saves :: CharacterSaves.Saves
end

--[[ Names ]]

--[[
	`text` as a character's name everyone may read (Roblox's filter for a broadcast); when it
	can't be used, "Character <id>". In Studio a filter that can't be reached keeps the name.
]]
local function filterName(text: string, userId: number, id: number): string
	local fallback = `Character {id}`
	local clean = Characters.cleanName(text)
	if clean == nil then
		return fallback
	end
	local ok, result = pcall(function(): string
		local filtered = TextService:FilterStringAsync(clean, userId, Enum.TextFilterContext.PublicChat)
		return filtered:GetNonChatStringForBroadcastAsync()
	end)
	if ok and type(result) == "string" then
		return Characters.cleanName(result) or fallback
	elseif RunService:IsStudio() then
		return clean
	end
	warn(`[IceVoxel] a character's name could not be filtered ({result}): it is "{fallback}"`)
	return fallback
end

--[[ Selection ]]

local function newSelected(record: Record, progress: unknown?): Selected
	return {
		id = record.id,
		record = record,
		progress = progress,
		progressWritable = true,
		canSave = record.dropped == 0,
		lost = false,
		applied = false,
		enteredAt = os.clock(),
		playedBase = record.played,
		inventory = nil,
		cache = {},
		nextSave = os.clock() + Config.Characters.SaveInterval * (0.9 + 0.2 * math.random()),
		saving = false,
		pendingHealth = nil,
		leftovers = {},
		bodies = 0,
		kept = nil,
		importing = nil,
	}
end

--[[
	What `record` wears on its preview rig (Items/Accessories.looks: armour or its vanity, the
	accessories with a `worn` place, hidden ones left out). Every accessory row counts: the list
	doesn't know the character's Age, and a row its Age closed holds something only after /age.
]]
local function dressedOf(record: Record): string
	local inventory = Types.newInventory()
	inventory.armor = record.armor
	inventory.accessories = record.accessories
	inventory.vanityArmor = record.vanityArmor
	inventory.vanityAccessories = record.vanityAccessories
	inventory.hidden = record.hidden
	inventory.accessorySlots = Types.ACCESSORY_SIZE
	return Accessories.looks(inventory)
end

-- The character as it is now (see the header): a new record over the selected one's.
local function capture(player: Player, user: User, selected: Selected): Record
	local base = selected.record
	if not selected.applied then
		return base
	end
	local record = CharacterCodec.new(base.id, base.name, base.difficulty, base.appearance, base.created)
	record.dead, record.legacy, record.deaths = base.dead, base.legacy, base.deaths
	record.maxHealth = base.maxHealth
	record.imported = base.imported
	record.played = selected.playedBase + math.max(0, os.clock() - selected.enteredAt)
	record.lastPlayed = os.time()
	local inventory = selected.inventory
	if inventory then
		record.slots, record.armor, record.cursor = inventory.slots, inventory.armor, inventory.cursor
		record.selected = inventory.selected
		record.accessories = inventory.accessories
		record.vanityArmor = inventory.vanityArmor
		record.vanityAccessories = inventory.vanityAccessories
		record.hidden = inventory.hidden
	else
		-- (No live inventory to read: never an empty one over what the character had.)
		record.slots, record.armor, record.cursor = base.slots, base.armor, base.cursor
		record.selected = base.selected
		record.accessories, record.vanityArmor = base.accessories, base.vanityArmor
		record.vanityAccessories, record.hidden = base.vanityAccessories, base.hidden
	end
	-- (Tough As Nails, effects and the body give nothing once they forgot a leaving player: the
	-- cache then. Mana always would, a fresh one: the cache for a leaving player.)
	local cache = selected.cache
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 and humanoid.MaxHealth > 0 then
		record.health = humanoid.Health / humanoid.MaxHealth * 20
	else
		record.health = cache.health or base.health
	end
	-- (Players/Mana while it keeps the player: the crystal a leaving player just used too.)
	local mana = Mana.peek(player)
	if mana then
		record.mana, record.crystals = mana.mana, mana.crystals
	else
		record.mana = cache.mana or base.mana
		record.crystals = cache.crystals or base.crystals
	end
	local thirst, temperature = ToughAsNails.export(player)
	record.thirst = (thirst or cache.thirst or base.thirst) :: any
	record.temperature = (temperature or cache.temperature or base.temperature) :: any
	local effects = Effects.export(player)
	record.effects = (effects or cache.effects or base.effects) :: any
	local kept = selected.kept
	if kept then
		-- (Not a fair visit: the things it had then.)
		CharacterCodec.keepThings(record, kept)
	end
	selected.record = record
	return record
end

--[[
	The visit stops being fair (see the header): the things the character has now are what it
	leaves with. Once a visit.
]]
local function freeze(player: Player, user: User, selected: Selected, message: string)
	if selected.kept or not selected.applied then
		return
	end
	local now = capture(player, user, selected)
	local kept = CharacterCodec.new(now.id, now.name, now.difficulty, now.appearance, now.created)
	CharacterCodec.keepThings(kept, now)
	selected.kept = kept
	notify(player, message)
end

-- The progress saved with the character (see the header).
local function progressOf(player: Player, user: User, selected: Selected): unknown?
	if not selected.progressWritable or not selected.applied or not Progression.savesProgress() then
		return selected.progress
	end
	-- (Nothing once Progression forgot a leaving player: the cache then.)
	local live = Progression.export(player)
	return live or selected.cache.progress or selected.progress
end

--[[
	Saves the selected character (see the header); `release` gives its lock back and writes its
	line in the list. Yields.
]]
local function save(player: Player, user: User, selected: Selected, release: boolean?, deadline: number?)
	if selected.lost then
		return
	end
	captures += 1
	local order = captures
	local record = if selected.canSave then capture(player, user, selected) else nil
	local writes = record ~= nil and (selected.applied or release == true)
	-- (An old record taken in: this save has it when the character is in the world.)
	local importing = if writes and selected.applied then selected.importing else nil
	local status = CharacterSaves.save(
		user.saves,
		player.UserId,
		selected.id,
		if writes then record else nil,
		progressOf(player, user, selected),
		order,
		release,
		deadline
	)
	if status == "lost" then
		selected.lost = true
		warn(`[IceVoxel] {player.Name}'s character "{selected.record.name}" was opened on another server`)
		notify(player, "Your character is no longer saved here: it was opened on another server")
		return
	end
	if status == "ok" and importing and selected.importing == importing then
		-- (Saved with what it took in: now the world may say it was taken.)
		selected.importing = nil
		WorldSave.confirmImport(player.UserId, selected.id, importing)
	end
	if release and status ~= "failed" and selected.canSave then
		local listed = CharacterSaves.touch(
			user.saves,
			player.UserId,
			CharacterCodec.summary(selected.record),
			user.migrateMark or nil,
			deadline
		)
		if listed then
			user.index = listed
			user.migrateMark = false
		end
	end
end

-- Saves the selected character now unless a save is under way (the periodic and /save-all's).
local function saveSoon(player: Player, user: User)
	local selected = user.selected
	if selected == nil or selected.saving or selected.lost then
		return
	end
	selected.saving = true
	selected.nextSave = os.clock() + Config.Characters.SaveInterval * (0.9 + 0.2 * math.random())
	save(player, user, selected)
	selected.saving = false
end

-- Lets go of the selected character: its last save, its lock given back. Yields.
local function release(player: Player, user: User, deadline: number?)
	local selected = user.selected
	if selected == nil then
		return
	end
	user.selected = nil
	save(player, user, selected, true, deadline)
end

--[[ Actions ]]

local function findLine(user: User, id: number): Characters.Summary?
	for _, line in user.index.chars do
		if line.id == id then
			return line
		end
	end
	return nil
end

-- Selects character `id` (see the header): what to tell the player.
local function select(player: Player, user: User, id: number): string
	if user.entered then
		return "You are in the world: leave and rejoin to play another character"
	end
	local current = user.selected
	if current and current.id == id then
		return ""
	end
	local line = findLine(user, id)
	if line == nil then
		return "There is no such character"
	elseif line.dead then
		return `{line.name} is dead: it can only be deleted`
	end
	release(player, user)
	local deadline = os.clock() + Config.Characters.LockWait
	local delay = 2
	local status: CharacterSaves.SelectStatus, record: Record?, progress: unknown?, why: string? =
		"failed", nil, nil, nil
	while true do
		status, record, progress, why = CharacterSaves.select(user.saves, player.UserId, id)
		if status ~= "busy" or player.Parent == nil or os.clock() + delay > deadline then
			break
		end
		local here = why == CharacterSaves.STILL_SAVING
		sendList(
			player,
			user,
			`{line.name} is still being saved{if here then "" else " by another server"}: waiting...`
		)
		task.wait(delay)
		delay = math.min(delay * 2, 8)
	end
	if status == "busy" then
		if why == CharacterSaves.STILL_SAVING then
			return `{line.name} is still being saved: try again in a moment`
		end
		return `{line.name} is open on another server`
	elseif status == "missing" then
		return `{line.name} is gone`
	elseif status == "damaged" then
		return `{line.name} can't be read ({why or "damaged"})`
	elseif status == "failed" or record == nil then
		return `{line.name} could not be loaded ({why or "the store"})`
	end
	local loaded = record :: Record
	local selected = newSelected(loaded, progress)
	if users[player] ~= user or user.leaving or loaded.dead then
		-- (Gone meanwhile, or died elsewhere: given back as it was.)
		selected.canSave = false
		save(player, user, selected, true)
		return if loaded.dead then `{loaded.name} is dead: it can only be deleted` else ""
	end
	user.selected = selected
	user.looks[id] = loaded.appearance
	user.dressed[id] = dressedOf(loaded)
	if loaded.dropped > 0 then
		return `{loaded.name} holds items this version doesn't know: it plays, but is not saved`
	end
	return ""
end

local function create(player: Player, user: User, request: CharacterSync.Request): string
	if user.entered then
		return "You are in the world: leave and rejoin to make another character"
	elseif #user.index.chars >= Characters.MAX then
		return `You can't make another character: {CharacterSaves.FULL}`
	end
	local id = user.index.next
	local name = filterName(request.name or "", player.UserId, id)
	local snapshot = CharacterLooks.snapshot(player)
	local look = Appearance.sanitize(request.appearance or snapshot, snapshot)
	local difficulty = request.difficulty or Characters.DEFAULT_DIFFICULTY
	release(player, user)
	local record = CharacterCodec.new(id, name, difficulty, look, os.time())
	local listed, why = CharacterSaves.create(user.saves, player.UserId, record, nil, true, user.migrateMark)
	if listed == nil then
		return `{name} could not be made: {why or "the store"}`
	end
	user.index = listed
	user.migrateMark = false
	local selected = newSelected(record, nil)
	if users[player] ~= user or user.leaving then
		-- (Gone meanwhile: given back.)
		save(player, user, selected, true)
		return ""
	end
	user.selected = selected
	user.looks[id] = look
	user.dressed[id] = ""
	if Config.MainMenu.Enabled then
		CharacterLooks.preview(player, `c{id}`, look)
	end
	print(`[IceVoxel] {player.Name} made the character "{name}" ({Characters.DIFFICULTIES[difficulty]})`)
	return `Made {name}`
end

local function delete(player: Player, user: User, id: number): string
	local line = findLine(user, id)
	if line == nil then
		return "There is no such character"
	end
	local selected = user.selected
	if selected and selected.id == id then
		if user.entered then
			return "You are playing that character"
		end
		-- (Given back unsaved: it is about to go.)
		user.selected = nil
		selected.canSave = false
		save(player, user, selected, true)
	end
	local listed, why = CharacterSaves.delete(user.saves, player.UserId, id)
	if listed == nil then
		return `{line.name} could not be deleted: {why or "the store"}`
	end
	user.index = listed
	user.looks[id] = nil
	user.dressed[id] = nil
	return `Deleted {line.name}`
end

local function rename(player: Player, user: User, id: number, text: string): string
	local line = findLine(user, id)
	if line == nil then
		return "There is no such character"
	end
	local name = filterName(text, player.UserId, id)
	local listed, why = CharacterSaves.rename(user.saves, player.UserId, id, name)
	if listed == nil then
		return `{line.name} could not be renamed: {why or "the store"}`
	end
	user.index = listed
	local selected = user.selected
	if selected and selected.id == id then
		selected.record.name = name
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.DisplayName = name
		end
	end
	return `Renamed to {name}`
end

--[[
	The look of listed character `id` and what it wears (`dressedOf`): the selected one's, one
	read before, or read now.
]]
local function lookOf(player: Player, user: User, id: number): (Appearance.Appearance?, string?)
	local selected = user.selected
	if selected and selected.id == id then
		return selected.record.appearance, dressedOf(selected.record)
	end
	local known = user.looks[id]
	if known then
		return known, user.dressed[id]
	elseif findLine(user, id) == nil then
		return nil, nil
	end
	local record = CharacterSaves.peek(user.saves, player.UserId, id)
	if record then
		user.looks[id] = record.appearance
		user.dressed[id] = dressedOf(record)
		return record.appearance, user.dressed[id]
	end
	return nil, nil
end

local function onAction(player: Player, payload: buffer)
	local user = users[player]
	local request = CharacterSync.decodeAction(payload)
	if user == nil or request == nil then
		return
	end
	local now = os.clock()
	local action = request.action
	if action == A.List or action == A.Avatar or action == A.Preview or action == A.EditPreview then
		if now - user.lastList < LIST_INTERVAL then
			return
		end
		user.lastList = now
		if action == A.List then
			-- (Before the list was read, it comes when it is.)
			if user.loaded then
				sendList(player, user)
			end
		elseif action == A.Avatar then
			task.spawn(function()
				local snapshot = CharacterLooks.snapshot(player)
				send(
					player,
					Protocol.ServerMessage.Avatar,
					CharacterSync.encodeAvatar(CharacterSync.AvatarPurpose.Own, snapshot)
				)
				CharacterLooks.preview(player, CharacterLooks.EDITOR, snapshot)
			end)
		elseif action == A.Preview and request.id then
			local id = request.id
			task.spawn(function()
				local look, dressed = lookOf(player, user, id)
				if look then
					CharacterLooks.preview(player, `c{id}`, look, dressed)
				end
			end)
		elseif action == A.EditPreview and request.appearance then
			local edited = request.appearance
			task.spawn(function()
				local snapshot = CharacterLooks.snapshot(player)
				CharacterLooks.preview(player, CharacterLooks.EDITOR, Appearance.sanitize(edited, snapshot))
			end)
		end
		return
	end
	-- A change: one a second, one at a time (every request is answered: the screen waits).
	if now - user.lastChange < CHANGE_INTERVAL then
		sendList(player, user, "Too fast: try again in a moment")
		return
	elseif user.busy or not user.loaded then
		sendList(player, user, "Still busy with the last request")
		return
	end
	user.lastChange = now
	user.busy = true
	sendList(player, user)
	task.spawn(function()
		local ok, message = pcall(function(): string
			if action == A.Create then
				return create(player, user, request)
			elseif action == A.Delete and request.id then
				return delete(player, user, request.id)
			elseif action == A.Rename and request.id and request.name then
				return rename(player, user, request.id, request.name)
			elseif action == A.Select and request.id then
				return select(player, user, request.id)
			end
			return ""
		end)
		if not ok then
			warn(`[IceVoxel] a character request of {player.Name} failed: {message}`)
			message = "That did not work (see the server's output)"
		end
		user.busy = false
		if users[player] == user then
			sendList(player, user, if message ~= "" then message else nil)
		end
	end)
end

--[[ Joining and leaving ]]

-- The migration (see the header) for a user whose list hasn't looked at their old progress.
local function migrate(player: Player, user: User)
	if not (Config.Progression.Enabled and Config.Progression.Save) then
		user.migrateMark = true
		return
	end
	if not progressStoreOpened then
		progressStoreOpened = true
		progressStore = ProgressStore.open(true)
	end
	local store = progressStore
	if store == nil then
		-- (Decides nothing: tried again next session.)
		return
	end
	local ok, old = store:load(player)
	if not ok or users[player] ~= user then
		return
	elseif old == nil or #user.index.chars >= Characters.MAX then
		user.migrateMark = true
		return
	end
	local id = user.index.next
	local name = filterName(player.DisplayName, player.UserId, id)
	local record = CharacterMigration.legacy(id, name, CharacterLooks.snapshot(player), os.time())
	local listed, why = CharacterSaves.create(user.saves, player.UserId, record, old, false, true)
	if listed then
		user.index = listed
		user.migrateMark = false
		user.note = `Your progress from before is now {record.name}'s (Mediumcore)`
		print(`[IceVoxel] {player.Name}'s old progress became the character "{record.name}"`)
	else
		warn(`[IceVoxel] {player.Name}'s old progress could not become a character: {why}`)
	end
end

local autoPlay: (player: Player, user: User) -> ()

local function join(player: Player)
	if users[player] then
		return
	end
	local user: User = {
		saves = memorySaves(),
		saving = false,
		loaded = false,
		index = CharacterCodec.newIndex(),
		note = "",
		busy = false,
		selected = nil,
		entered = false,
		leaving = false,
		migrateMark = false,
		lastList = -math.huge,
		lastChange = -math.huge,
		looks = {},
		dressed = {},
	}
	users[player] = user
	waitForProbe()
	local saves = durable
	if saves then
		local ok, index, why = CharacterSaves.readIndex(saves, player.UserId)
		if users[player] ~= user then
			return
		end
		if ok and index then
			user.saves, user.saving, user.index = saves, true, index
			if Config.Characters.Migrate and not index.migrated then
				migrate(player, user)
			end
		else
			warn(`[IceVoxel] the characters of {player.Name} could not be read: {why}`)
			user.note = if ok
				then `Your characters can't be read here ({why}): new ones last for this session`
				else "Your characters could not be loaded: new ones last for this session"
		end
	else
		user.note = `{SESSION_NOTE} ({storeNote or "no DataStore"})`
	end
	if not user.saving then
		-- (This server's memory: what this session made, a rejoin within it too.)
		local _, index = CharacterSaves.readIndex(user.saves, player.UserId)
		user.index = index or CharacterCodec.newIndex()
	end
	if users[player] ~= user then
		return
	end
	user.loaded = true
	sendList(player, user)
	if not Config.MainMenu.Enabled then
		autoPlay(player, user)
	end
end

local function leave(player: Player)
	local user = users[player]
	if user == nil then
		return
	end
	user.leaving = true
	users[player] = nil
	if not closing then
		releasing += 1
		release(player, user)
		releasing -= 1
	end
end

--[[ In the world ]]

-- What the player has now, for when they leave (see the header).
local function refreshCache(player: Player, selected: Selected, progress: boolean)
	local cache = selected.cache
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 and humanoid.MaxHealth > 0 then
		cache.health = humanoid.Health / humanoid.MaxHealth * 20
	end
	local mana = Mana.export(player)
	cache.mana, cache.crystals = mana.mana, mana.crystals
	local thirst, temperature = ToughAsNails.export(player)
	if thirst then
		cache.thirst, cache.temperature = thirst, temperature
	end
	local effects = Effects.export(player)
	if effects then
		cache.effects = effects
	end
	if progress then
		local exported = Progression.export(player)
		if exported ~= nil then
			cache.progress = exported
		end
	end
end

-- Applies `look` onto a body Roblox made itself (the title screen off: see the header).
local function applyLook(humanoid: Humanoid, look: Appearance.Appearance)
	local description = CharacterLooks.description(look)
	local anyHumanoid = humanoid :: any
	local ok, err = pcall(function()
		local method = anyHumanoid.ApplyDescriptionResetAsync or anyHumanoid.ApplyDescriptionReset
		method(anyHumanoid, description)
	end)
	if not ok then
		warn(`[IceVoxel] a character's look could not be applied: {err}`)
	end
end

-- A character of the player's died (every death counts; a Hardcore one dies for good).
local function died(player: Player)
	local user = users[player]
	local selected = user and user.selected
	if user == nil or selected == nil or not selected.applied then
		return
	end
	local record = selected.record
	record.deaths += 1
	if Characters.diesForGood(record.difficulty) and not record.dead then
		record.dead = true
		GameModes.set(player, GameMode.SPECTATOR, false)
		notify(player, `{record.name} died for good: you watch the rest of this visit as a spectator`)
		print(`[IceVoxel] {player.Name}'s Hardcore character "{record.name}" died`)
		task.spawn(function()
			-- (After a save under way, so this one has the death.)
			while selected.saving do
				task.wait(0.2)
			end
			saveSoon(player, user)
			if selected.canSave and not selected.lost then
				local listed = CharacterSaves.touch(user.saves, player.UserId, CharacterCodec.summary(selected.record))
				if listed then
					user.index = listed
				end
			end
		end)
	end
end

local function onCharacter(player: Player, character: Model)
	local user = users[player]
	local selected = user and user.selected
	if user == nil or selected == nil or not selected.applied then
		return
	end
	selected.bodies += 1
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid == nil or not humanoid:IsA("Humanoid") then
		return
	end
	humanoid.DisplayName = selected.record.name
	humanoid.Died:Connect(function()
		died(player)
	end)
	if not Config.MainMenu.Enabled then
		-- (Roblox made this body from the user's avatar: the character's look goes onto it.)
		task.spawn(applyLook, humanoid, selected.record.appearance)
	end
	local health = selected.pendingHealth
	selected.pendingHealth = nil
	if health then
		task.defer(function()
			Bodies.restoreHealth(player, health)
		end)
	elseif selected.bodies > 1 then
		-- (A respawn: Terraria's full mana.)
		Mana.add(player, math.huge)
	end
	local leftovers = selected.leftovers
	if #leftovers > 0 then
		selected.leftovers = {}
		task.delay(1, function()
			if player.Character == character and character.Parent then
				for _, stack in leftovers do
					Inventories.give(player, stack)
				end
			end
		end)
	end
end

-- Puts the selected character's state into the live parts (see the header).
local function apply(player: Player, user: User, selected: Selected, leftovers: { Stack })
	local record = selected.record
	Inventories.restore(player, record.slots, record.armor, record.selected, record.cursor)
	Inventories.restoreEquipment(player, {
		accessories = record.accessories,
		vanityArmor = record.vanityArmor,
		vanityAccessories = record.vanityAccessories,
		hidden = record.hidden,
	})
	ToughAsNails.restore(player, record.thirst :: any, record.temperature :: any)
	Effects.restore(player, record.effects :: any)
	selected.progressWritable = Progression.restore(player, selected.progress)
	-- (Mana after the progress and the accessory slots its Age opens: the max it is held to from
	-- the next tick counts every accessory the character wears, a Band of Starpower included.)
	Inventories.refreshSlots(player)
	Mana.restore(player, record.mana, record.crystals)
	local window = Inventories.get(player)
	selected.inventory = window and window.inventory
	selected.applied = true
	selected.enteredAt = os.clock()
	selected.playedBase = record.played
	selected.leftovers = leftovers
	selected.cache = {
		health = record.health,
		mana = record.mana,
		crystals = record.crystals,
		thirst = record.thirst,
		temperature = record.temperature,
		effects = record.effects,
		progress = selected.progress,
	}
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if character and humanoid and humanoid.Health > 0 then
		-- (Already standing: the title screen off.)
		Bodies.restoreHealth(player, record.health)
		task.spawn(onCharacter, player, character)
	else
		selected.pendingHealth = record.health
	end
	CharacterLooks.clear(player)
	if not Progression.savesProgress() then
		freeze(player, user, selected, UNFAIR_WORLD)
	elseif GameMode.instabuild(GameMode.of(player)) then
		freeze(player, user, selected, CREATIVE_NOTE)
	end
end

--[[
	The player enters the world with character `id` (see the header): true, or false and why not.
	Yields (the world's entry is read). Config.Characters.Enabled off: true, nothing to do.
]]
function CharacterStore.enter(player: Player, id: number): (boolean, string?)
	if not Config.Characters.Enabled then
		return true, nil
	end
	local user = users[player]
	if user == nil or not user.loaded then
		return false, "your characters were not loaded yet"
	end
	local selected = user.selected
	if selected == nil or selected.id ~= id then
		return false, "that character is not the one selected"
	elseif selected.record.dead then
		return false, "that character is dead"
	elseif user.entered then
		return true, nil
	end
	user.entered = true
	-- (Only a character that is saved takes an old record in, and only on a fair visit: see the
	-- header; WorldSave checks the game mode it enters with.)
	local mayImport = user.saving and selected.canSave and not selected.lost and Progression.savesProgress()
	local leftovers, imported = WorldSave.enterCharacter(player, selected.record, mayImport)
	if users[player] ~= user or user.selected ~= selected then
		return false, "the player left"
	end
	apply(player, user, selected, leftovers)
	if imported then
		-- (An old record was taken in: saved at once, after a save under way; the world's mark
		-- waits for it.)
		selected.importing = imported
		task.spawn(function()
			while selected.saving do
				task.wait(0.2)
			end
			saveSoon(player, user)
		end)
	end
	return true, nil
end

-- The look `player`'s character spawns with (nil: none selected, or characters are off).
function CharacterStore.look(player: Player): Appearance.Appearance?
	local user = users[player]
	local selected = user and user.selected
	return if selected then selected.record.appearance else nil
end

-- Does `player`'s character keep everything when it dies (Classic; Players/Inventories' rule)?
function CharacterStore.keepsInventory(player: Player): boolean
	local user = users[player]
	local selected = user and user.selected
	return selected ~= nil and selected.applied and Characters.keepsInventory(selected.record.difficulty)
end

-- Saves every selected character now (/save-all).
function CharacterStore.saveAll()
	for player, user in users do
		task.spawn(saveSoon, player, user)
	end
end

--[[ The title screen off ]]

autoPlay = function(player: Player, user: User)
	if not Config.Characters.Enabled then
		return
	end
	local chosen: Characters.Summary? = nil
	for _, line in user.index.chars do
		if not line.dead then
			chosen = line
			break
		end
	end
	local why = ""
	if chosen then
		why = select(player, user, chosen.id)
		if user.selected == nil then
			-- (Never a new character in its place: see the header.)
			warn(`[IceVoxel] {player.Name}'s character "{chosen.name}" could not be played: {why}`)
			if player.Parent then
				player:Kick(`Your character could not be loaded ({why}). Please rejoin.`)
			end
			return
		end
	else
		local look = CharacterMigration.allWorn(CharacterLooks.snapshot(player))
		why = create(player, user, {
			action = A.Create,
			name = player.DisplayName,
			difficulty = Characters.DEFAULT_DIFFICULTY,
			appearance = look,
		})
	end
	local selected = user.selected
	if selected == nil then
		warn(`[IceVoxel] {player.Name} has no character to play: {why}`)
		notify(player, `You have no character to play ({why}): nothing is saved for you this visit`)
		return
	end
	sendList(player, user)
	-- (Entering puts the look on the body standing, and on every later one: `onCharacter`.)
	WorldInfo.onReady(function()
		task.spawn(CharacterStore.enter, player, selected.id)
	end)
end

--[[ Starting ]]

--[[
	Starts the characters on the lobby's net, before the world (the boot, just before
	WorldSave.start): the DataStore looked at, every player's list read as they join, the title
	screen's requests, saving and shutdown. Config.Characters.Enabled off: nothing.
]]
function CharacterStore.start(lobby: ServerNet.ServerNet)
	if not Config.Characters.Enabled then
		return
	end
	assert(net == nil, "CharacterStore.start was already called")
	net = lobby
	CharacterLooks.start()
	task.spawn(function()
		local saves, why = probe()
		durable = saves
		storeNote = why
		probed = true
	end)
	lobby.on(Protocol.ClientMessage.CharacterAction, onAction)
	WorldSave.onSaveAll(CharacterStore.saveAll)
	-- (Creative from now on: the visit stops being fair, see the header.)
	GameModes.changed:Connect(function(player: Player, mode: string)
		local user = users[player]
		local selected = user and user.selected
		if user and selected and GameMode.instabuild(mode) then
			freeze(player, user, selected, CREATIVE_NOTE)
		end
	end)

	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(function(character: Model)
			onCharacter(player, character)
		end)
		join(player)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayer, player)
	end
	Players.PlayerRemoving:Connect(leave)

	-- Saving and the look at what players have.
	task.spawn(function()
		local steps = 0
		while not closing do
			task.wait(CACHE_INTERVAL)
			steps += 1
			local now = os.clock()
			for player, user in users do
				local selected = user.selected
				if selected and selected.applied and not user.leaving then
					refreshCache(player, selected, steps % PROGRESS_EVERY == 0)
				end
				if selected and not selected.saving and not selected.lost and now >= selected.nextSave then
					task.spawn(saveSoon, player, user)
				end
			end
		end
	end)

	game:BindToClose(function()
		closing = true
		local deadline = os.clock() + CLOSE_SECONDS
		local pending = 0
		for player, user in users do
			if user.selected then
				pending += 1
				task.spawn(function()
					user.leaving = true
					release(player, user, deadline)
					pending -= 1
				end)
			end
		end
		while (pending > 0 or releasing > 0) and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

return CharacterStore
