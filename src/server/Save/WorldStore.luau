--!strict
--[[
	Saved worlds in a key-value store, the rules without Roblox: World/WorldSave gives it the
	DataStore (`Store`: get, set, update, remove, each yielding and answering ok or why not) and the
	clock, budget and tasks (`Env`, Save/SaveScheduler's), and the specs give it a fake one with
	budgets, cooldowns, latency and failures. Keys and records: Save/WorldMeta; locks:
	Save/SaveLock; regions: Save/RegionCodec; players: Save/PlayerCodec.

	  list     an owner's list (WorldMeta's owners: a player's own, or the game's), last
	           played first; `room` whether it takes one more world.
	  create   a new world's handle (an id no listed world has, its owner); nothing is written
	           until it is saved, which takes its lock first (and, the first time, looks that its
	           owner's list has room: a world that can't be listed is refused whole, never
	           written unlisted, and never pushes another out).
	  load     takes the world's lock (refused while another live server holds it), reads its
	           record and every region it lists (heads, then the parts of long ones, as many at
	           once as the scheduler allows, `progress(done, total)` after each key), joins and
	           decodes them, renewing the lock every third of its timeout while it reads (a long
	           load never leaves a running server holding a stale lock). Any failure gives the
	           lock back and returns nil and why: a world that could not be read whole is never
	           started, so nothing is ever written over it. A world holding blocks, items or mobs
	           this version doesn't know (saved by a newer one) opens, but is never saved
	           (`canSave` false): writing it would lose them.
	  save     writes what changed (see `save`): never for a world that can't be saved
	           (`canSave` false: its lock was lost, or it was refused), never past
	           Config.Save.MaxWorldBytes (refused as a whole, and said so), and only once the
	           lock is known to be this server's still (renewed first when its last renewal is a
	           sixth of the timeout old: before the writes and again before the commit); parts
	           before heads before the record, each head and part tagged with this server
	           (WorldMeta.writerTag), failed writes tried again (the scheduler) and what still
	           failed kept for the next save (a region whose parts failed is not committed: its
	           old head and parts stay intact).
	  players  `loadPlayer` reads one player's record with retries: false when it could not be
	           read (the caller then never writes that player this session, so an outage can't
	           replace a saved inventory with an empty one); their records go out with `save`
	           and `savePlayers`, each with its order (`order`: later captures are higher), and
	           a record older than one already written (or being written) for that player is
	           never written: an autosave's retry can't put back what a leaving player had
	           minutes before.
	  characters  with Config.Characters on, what the world keeps of each character (Save/
	           WorldCharacterCodec: where it stood, its game mode) instead of a player record:
	           `loadCharacter`, `saveCharacters` and `save`'s `characters`, by name
	           "<userId>_<charId>" (WorldMeta.characterName), with the same rules (a failed read
	           is never written over, the same order numbers). The old player records stay as
	           they are (the migration reads them: Players/CharacterStore).
	  lock     `heartbeat` renews it (false: lost to another server, saving stops), `release`
	           gives it back at shutdown or after a failed load.
	  delete   only the world's owner or the game's own people (WorldMeta.mayManage); takes the
	           lock (a world open elsewhere can't be deleted), takes the world off its owner's
	           list, then removes its keys (best effort, within the budget: what is left is
	           unreachable).
	  rename   the list's and the record's name (the owner's, as delete; not while another
	           server has it open).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local WorldSettings = require(Shared.WorldSettings)

local PlayerCodec = require(script.Parent.PlayerCodec)
local RegionCodec = require(script.Parent.RegionCodec)
local WorldCharacterCodec = require(script.Parent.WorldCharacterCodec)
local SaveLock = require(script.Parent.SaveLock)
local SaveScheduler = require(script.Parent.SaveScheduler)
local WorldMeta = require(script.Parent.WorldMeta)

export type Store = {
	-- ok, the value (nil: none); or false and why.
	get: (key: string) -> (boolean, unknown),
	-- ok; or false and why. `userIds`: the players the value is about (Roblox's user ids).
	set: (key: string, value: unknown, userIds: { number }?) -> (boolean, string?),
	-- Runs `transform` on the stored value: its result is stored (nil: nothing changes). ok and
	-- the value stored after; or false and why.
	update: (key: string, transform: (unknown) -> unknown?) -> (boolean, unknown),
	remove: (key: string) -> (boolean, string?),
}

export type Env = {
	now: () -> number,
	budget: (kind: SaveScheduler.Kind) -> number,
	wait: (seconds: number) -> (),
	spawn: (fn: () -> ()) -> (),
	-- Seconds since 1970 (os.time), for records and locks.
	time: () -> number,
	-- This server's lock name (its JobId, or a session GUID in Studio).
	job: string,
	random: () -> number,
}

export type RegionState = { parts: { string }, slot: number, gen: number, bytes: number, largest: number }

export type World = {
	id: string,
	meta: WorldMeta.Meta,
	-- What the store holds of each region (committed heads).
	regions: { [string]: RegionState },
	-- The text last written for each player (user id as text).
	players: { [string]: string },
	-- The order of the newest record written, or being written, for each player (user id as
	-- text): an older one is never written after it.
	order: { [string]: number },
	-- The same for characters' entries, by WorldMeta.characterName.
	characters: { [string]: string },
	characterOrder: { [string]: number },
	lockHeld: boolean,
	-- When the lock was last taken or renewed (Env.now).
	renewedAt: number,
	-- Listed in its owner's list (loaded, or a save put it there).
	listed: boolean,
	canSave: boolean,
	reason: string?,
}

export type Loaded = {
	world: World,
	settings: WorldSettings.Settings,
	regions: { RegionCodec.Region },
	-- Edits, items and mobs dropped while reading (from a newer version).
	dropped: number,
}

export type SaveInput = {
	-- Encoded regions (RegionCodec.encode) to write when they changed.
	regions: { [string]: buffer },
	-- Regions that hold nothing: written only when the store has them already.
	empty: { [string]: boolean }?,
	-- Player records (PlayerCodec.toText) by user id.
	players: { [number]: string },
	-- Each record's order (user id -> a number later captures make higher; none: always written).
	order: { [number]: number }?,
	-- Characters' entries (WorldCharacterCodec.toText) by WorldMeta.characterName, and their order.
	characters: { [string]: string }?,
	characterOrder: { [string]: number }?,
	sections: { [string]: any },
	operators: { number },
}

export type SaveResult = {
	ok: boolean,
	refused: boolean,
	bytes: number,
	largest: number,
	max: number,
	keyLimit: number,
	regionsWritten: number,
	playersWritten: number,
	-- Players whose record was written (the caller's "last written").
	written: { [number]: boolean },
	-- Characters' entries written (by name).
	writtenCharacters: { [string]: boolean },
	failed: number,
	state: "ok" | "warn" | "over",
	message: string?,
}

export type Saves = {
	store: Store,
	env: Env,
	scheduler: SaveScheduler.Scheduler,
	-- The ids the last list had (new ids avoid them).
	known: { [string]: boolean },
	-- This server's tag on the heads and parts it writes (WorldMeta.writerTag).
	writer: string,
}

local WorldStore = {}

function WorldStore.new(store: Store, env: Env, options: SaveScheduler.Options?): Saves
	return {
		store = store,
		env = env,
		scheduler = SaveScheduler.new(env, options),
		known = {},
		writer = WorldMeta.writerTag(env.job),
	}
end

-- Runs `jobs`; returns the scheduler's result.
local function run(saves: Saves, jobs: { SaveScheduler.Job }, deadline: number?): SaveScheduler.Result
	if #jobs == 0 then
		return { ok = 0, failed = {}, timedOut = false }
	end
	return SaveScheduler.run(saves.scheduler, jobs, deadline)
end

-- One read through the scheduler: ok and the value, or false and why.
local function read(saves: Saves, key: string, deadline: number?): (boolean, unknown)
	local value: unknown = nil
	local job = SaveScheduler.job(key, "get", function(): (boolean, string?)
		local ok, result = saves.store.get(key)
		if ok then
			value = result
			return true, nil
		end
		return false, tostring(result)
	end)
	local result = run(saves, { job }, deadline)
	if result.ok == 1 then
		return true, value
	end
	return false, job.err or "failed"
end

-- One update through the scheduler: ok and the stored value, or false and why.
local function update(
	saves: Saves,
	key: string,
	transform: (unknown) -> unknown?,
	deadline: number?
): (boolean, unknown)
	local value: unknown = nil
	local job = SaveScheduler.job(key, "update", function(): (boolean, string?)
		local ok, result = saves.store.update(key, transform)
		if ok then
			value = result
			return true, nil
		end
		return false, tostring(result)
	end)
	local result = run(saves, { job }, deadline)
	if result.ok == 1 then
		return true, value
	end
	return false, job.err or "failed"
end

local function timeout(): number
	return math.max(10, Config.Save.LockTimeout)
end

local FULL = `the world list is full ({WorldMeta.MAX_WORLDS} worlds): delete one to save another`

--[[ The list ]]

-- `owner`'s world list (nil or 0: the game's), last played first, or nil and why not.
function WorldStore.list(saves: Saves, owner: number?): (WorldMeta.Index?, string?)
	local ok, value = read(saves, WorldMeta.indexKey(owner))
	if not ok then
		return nil, `the world list could not be read ({value})`
	end
	local index, why = WorldMeta.readIndex(value)
	if index then
		for id in WorldMeta.ids(index) do
			saves.known[id] = true
		end
	end
	return index, why
end

-- Whether `owner`'s list takes one more world: true, or false and why not (true when it can't
-- be read: the world's first save looks again).
function WorldStore.room(saves: Saves, owner: number?): (boolean, string?)
	local index = WorldStore.list(saves, owner)
	if index and #index.worlds >= WorldMeta.MAX_WORLDS then
		return false, FULL
	end
	return true, nil
end

--[[ Locks ]]

-- Takes world `id`'s lock: ok, or false and why ("open on another server", or the error).
function WorldStore.lock(saves: Saves, id: string, deadline: number?): (boolean, string?)
	local env = saves.env
	local refusal: string? = nil
	local ok, err = update(saves, WorldMeta.lockKey(id), function(old: unknown): unknown?
		local lock, why = SaveLock.acquire(old, env.job, env.time(), timeout())
		refusal = why
		return lock
	end, deadline)
	if not ok then
		return false, `its lock could not be taken ({err})`
	elseif refusal then
		return false, "it is open on another server"
	end
	return true, nil
end

-- Gives world `id`'s lock back (when it is this server's).
local function releaseId(saves: Saves, id: string, deadline: number?)
	local env = saves.env
	update(saves, WorldMeta.lockKey(id), function(old: unknown): unknown?
		return SaveLock.release(old, env.job, env.time())
	end, deadline)
end

-- Renews world `id`'s lock: "ok", "lost" (another server holds it, or it was released or
-- removed) or "failed" (the store could not be reached).
local function renewId(saves: Saves, id: string, deadline: number?): "ok" | "lost" | "failed"
	local env = saves.env
	local lost = false
	local ok = update(saves, WorldMeta.lockKey(id), function(old: unknown): unknown?
		local lock, gone = SaveLock.renew(old, env.job, env.time())
		lost = gone
		return lock
	end, deadline)
	if not ok then
		return "failed"
	end
	return if lost then "lost" else "ok"
end

local function lose(world: World)
	world.lockHeld = false
	world.canSave = false
	world.reason = "another server opened it"
end

-- Renews the world's lock; false when it was lost (saving stops: `canSave` false).
function WorldStore.heartbeat(saves: Saves, world: World): boolean
	if not world.lockHeld then
		return world.canSave
	end
	local renewed = renewId(saves, world.id)
	if renewed == "lost" then
		lose(world)
		return false
	elseif renewed == "ok" then
		world.renewedAt = saves.env.now()
	end
	-- (A failed heartbeat is tried again next time: the lock stays ours until it goes stale.)
	return true
end

--[[
	Before writing: is the world's lock still this server's? Renewed first unless its last
	renewal is less than a sixth of the timeout old (nobody can take it before the timeout).
	false and why when it was lost (`canSave` false), or could not be renewed while too old to be
	sure (this save is refused; the next one tries again).
]]
local function ensureLock(saves: Saves, world: World, deadline: number?): (boolean, string?)
	if not world.lockHeld then
		return true, nil
	end
	local env = saves.env
	if env.now() - world.renewedAt < timeout() / 6 then
		return true, nil
	end
	local renewed = renewId(saves, world.id, deadline)
	if renewed == "lost" then
		lose(world)
		return false, world.reason
	elseif renewed == "ok" then
		world.renewedAt = env.now()
		return true, nil
	elseif env.now() - world.renewedAt < timeout() / 2 then
		-- (Not renewed, but still too young for another server to have taken it.)
		return true, nil
	end
	return false, "its lock could not be renewed"
end

-- Gives the world's lock back (shutdown).
function WorldStore.release(saves: Saves, world: World, deadline: number?)
	if world.lockHeld then
		world.lockHeld = false
		releaseId(saves, world.id, deadline)
	end
end

--[[ Creating and loading ]]

-- A new world's handle (not written yet: its first save writes it). `owner`: its creator's
-- user id (nil or 0: the game's).
function WorldStore.create(saves: Saves, settings: WorldSettings.Settings, owner: number?): World
	local id = WorldMeta.newId(saves.env.random, saves.known)
	saves.known[id] = true
	return {
		id = id,
		meta = WorldMeta.new(id, settings, saves.env.time(), owner),
		regions = {},
		players = {},
		order = {},
		characters = {},
		characterOrder = {},
		lockHeld = false,
		renewedAt = -math.huge,
		listed = false,
		canSave = true,
		reason = nil,
	}
end

--[[
	Opens world `id` (see the header): its handle, settings and regions, or nil and why not. Yields.
	`progress(done, total)` follows the keys read; `who` (nil: the server itself) must be allowed
	to (WorldMeta.mayManage).
]]
function WorldStore.load(
	saves: Saves,
	id: string,
	progress: ((number, number) -> ())?,
	who: WorldMeta.Requester?
): (Loaded?, string?)
	if not WorldMeta.validId(id) then
		return nil, "there is no such world"
	end
	local env = saves.env
	local locked, refusal = WorldStore.lock(saves, id)
	if not locked then
		return nil, refusal
	end
	local function fail(reason: string): (Loaded?, string?)
		releaseId(saves, id)
		return nil, reason
	end
	-- The lock, renewed every third of its timeout while the keys are read.
	local renewedAt = env.now()
	local renewing = false
	local lost = false
	local function keepLock()
		if renewing or lost or env.now() - renewedAt < timeout() / 3 then
			return
		end
		renewing = true
		local renewed = renewId(saves, id)
		renewing = false
		if renewed == "lost" then
			lost = true
		elseif renewed == "ok" then
			renewedAt = env.now()
		end
	end
	local okMeta, value = read(saves, WorldMeta.metaKey(id))
	if not okMeta then
		return fail(`its record could not be read ({value})`)
	elseif value == nil then
		return fail("it is gone")
	end
	local meta, why = WorldMeta.read(value)
	if meta == nil then
		return fail(why or "its record is damaged")
	elseif meta.id ~= id then
		return fail("its record belongs to another world")
	elseif not WorldMeta.mayManage(meta.owner, who) then
		return fail("it is not yours")
	end
	local settings, problem = WorldMeta.settings(meta)
	if settings == nil then
		return fail(problem or "its settings are damaged")
	end

	local names: { string } = {}
	for name in meta.regions do
		table.insert(names, name)
	end
	table.sort(names)
	local total = #names
	local done = 0
	local function step()
		done += 1
		if progress then
			progress(done, total)
		end
		keepLock()
	end
	if progress then
		progress(0, total)
	end
	-- Heads, then the parts they name.
	local heads: { [string]: WorldMeta.Head } = {}
	local jobs: { SaveScheduler.Job } = {}
	local broken: string? = nil
	for _, name in names do
		local key = WorldMeta.regionKey(id, name)
		table.insert(
			jobs,
			SaveScheduler.job(key, "get", function(): (boolean, string?)
				local ok, stored = saves.store.get(key)
				if not ok then
					return false, tostring(stored)
				end
				local head, headProblem = WorldMeta.readHead(stored)
				if head == nil then
					broken = broken or `region {name}: {headProblem}`
				else
					heads[name] = head
					total += head.parts - 1
				end
				step()
				return true, nil
			end)
		)
	end
	local result = run(saves, jobs)
	keepLock()
	if lost then
		return fail("it was opened on another server")
	elseif #result.failed > 0 then
		return fail(`a region could not be read ({result.failed[1].err})`)
	elseif broken then
		return fail(broken)
	end
	local texts: { [string]: { string } } = {}
	jobs = {}
	for _, name in names do
		local head = heads[name]
		local list = { head.text }
		texts[name] = list
		for index = 2, head.parts do
			local key = WorldMeta.partKey(id, name, head.slot, index)
			table.insert(
				jobs,
				SaveScheduler.job(key, "get", function(): (boolean, string?)
					local ok, stored = saves.store.get(key)
					if not ok then
						return false, tostring(stored)
					end
					local text, partProblem = WorldMeta.readPart(stored, head.gen, index, head.writer)
					if text == nil then
						broken = broken or `region {name}: {partProblem}`
					else
						list[index] = text
					end
					step()
					return true, nil
				end)
			)
		end
	end
	result = run(saves, jobs)
	keepLock()
	if lost then
		return fail("it was opened on another server")
	elseif #result.failed > 0 then
		return fail(`a region could not be read ({result.failed[1].err})`)
	elseif broken then
		return fail(broken)
	end

	local world: World = {
		id = id,
		meta = meta,
		regions = {},
		players = {},
		order = {},
		characters = {},
		characterOrder = {},
		lockHeld = true,
		renewedAt = renewedAt,
		listed = true,
		canSave = true,
		reason = nil,
	}
	local regions: { RegionCodec.Region } = {}
	local dropped = 0
	for _, name in names do
		local head = heads[name]
		local parts = texts[name]
		local bytes = RegionCodec.join(parts)
		local rx, rz = RegionCodec.parseName(name)
		if bytes == nil or rx == nil or rz == nil then
			return fail(`region {name} is damaged`)
		end
		local region, decodeProblem = RegionCodec.tryDecode(bytes, rx, rz)
		if region == nil then
			return fail(`region {name}: {decodeProblem}`)
		end
		dropped += region.dropped
		table.insert(regions, region)
		local size, largest = 0, 0
		for _, text in parts do
			local partBytes = WorldMeta.valueBytes(text)
			size += partBytes
			largest = math.max(largest, partBytes)
		end
		world.regions[name] = { parts = parts, slot = head.slot, gen = head.gen, bytes = size, largest = largest }
		meta.regions[name] = size
	end
	if dropped > 0 then
		-- (Written back, they would be gone for good: a newer version's world is played here, not saved.)
		world.canSave = false
		world.reason = "it holds blocks, items or mobs this version doesn't know (saved by a newer version)"
	end
	return { world = world, settings = settings, regions = regions, dropped = dropped }, nil
end

--[[ Players ]]

--[[
	A player's record in the world: true and the record (nil: none saved yet, a new player), or
	false when it could not be read (or is damaged, or from a newer version): then never write
	that player this session. Yields.
]]
function WorldStore.loadPlayer(saves: Saves, world: World, userId: number): (boolean, PlayerCodec.Record?)
	local ok, value = read(saves, WorldMeta.playerKey(world.id, userId))
	if not ok then
		return false, nil
	end
	local text = WorldMeta.readPlayer(value)
	if text == nil then
		return true, nil
	elseif type(text) ~= "string" then
		return false, nil
	end
	local record = PlayerCodec.fromText(text)
	if record == nil then
		return false, nil
	end
	world.players[string.format("%.0f", userId)] = text
	return true, record
end

--[[
	A job writing `text` as player `userId`'s record, of order `order` (see the header): done
	without writing when a newer record was written, or is being written, for them. Those written
	go in `written`.
]]
local function playerJob(
	saves: Saves,
	world: World,
	userId: number,
	text: string,
	order: number?,
	written: { [number]: boolean }
): SaveScheduler.Job
	local key = string.format("%.0f", userId)
	local storeKey = WorldMeta.playerKey(world.id, userId)
	return SaveScheduler.job(storeKey, "set", function(): (boolean, string?)
		local newest = world.order[key]
		if order and newest and order < newest then
			-- (Older than what went out: never written after it.)
			return true, nil
		end
		if order then
			world.order[key] = order
		end
		local ok, err = saves.store.set(storeKey, WorldMeta.playerValue(text), { userId })
		if ok then
			if order == nil or world.order[key] == nil or order >= world.order[key] then
				world.players[key] = text
				world.meta.players[key] = WorldMeta.valueBytes(text)
			end
			written[userId] = true
		end
		return ok, err
	end)
end

--[[
	Writes the records of players who left (user id -> PlayerCodec text, `order` as the save's) at
	once, without the rest of the world (Minecraft saves a player's data when they leave). Only for
	a world that holds its lock, still (a new world's first save writes them instead). Yields.
	Returns those written (or already stored).
]]
function WorldStore.savePlayers(
	saves: Saves,
	world: World,
	players: { [number]: string },
	deadline: number?,
	order: { [number]: number }?
): { [number]: boolean }
	local written: { [number]: boolean } = {}
	if not world.canSave or not world.lockHeld or not ensureLock(saves, world, deadline) then
		return written
	end
	local jobs: { SaveScheduler.Job } = {}
	for userId, text in players do
		local key = string.format("%.0f", userId)
		if world.players[key] ~= text then
			table.insert(jobs, playerJob(saves, world, userId, text, order and order[userId], written))
		else
			written[userId] = true
		end
	end
	run(saves, jobs, deadline)
	return written
end

--[[ Characters ]]

--[[
	What the world keeps of character `charId` of user `userId`: true and the entry (nil: none yet,
	its first visit), or false when it could not be read (or is damaged, or from a newer version):
	then never write that entry this session. Yields.
]]
function WorldStore.loadCharacter(
	saves: Saves,
	world: World,
	userId: number,
	charId: number
): (boolean, WorldCharacterCodec.Entry?)
	local ok, value = read(saves, WorldMeta.characterKey(world.id, userId, charId))
	if not ok then
		return false, nil
	end
	local text = WorldMeta.readPlayer(value)
	if text == nil then
		return true, nil
	elseif type(text) ~= "string" then
		return false, nil
	end
	local entry = WorldCharacterCodec.fromText(text)
	if entry == nil then
		return false, nil
	end
	world.characters[WorldMeta.characterName(userId, charId)] = text
	return true, entry
end

-- A job writing a character's entry `text` (by its name), as `playerJob` does a player's record.
local function characterJob(
	saves: Saves,
	world: World,
	name: string,
	text: string,
	order: number?,
	written: { [string]: boolean }
): SaveScheduler.Job?
	local userId, charId = WorldMeta.parseCharacterName(name)
	if userId == nil or charId == nil then
		return nil
	end
	local storeKey = WorldMeta.characterKey(world.id, userId, charId)
	return SaveScheduler.job(storeKey, "set", function(): (boolean, string?)
		local newest = world.characterOrder[name]
		if order and newest and order < newest then
			return true, nil
		end
		if order then
			world.characterOrder[name] = order
		end
		local ok, err = saves.store.set(storeKey, WorldMeta.playerValue(text), { userId })
		if ok then
			if order == nil or world.characterOrder[name] == nil or order >= world.characterOrder[name] then
				world.characters[name] = text
				world.meta.characters[name] = WorldMeta.valueBytes(text)
			end
			written[name] = true
		end
		return ok, err
	end)
end

--[[
	Writes the entries of characters that left (name -> WorldCharacterCodec text, `order` as the
	save's) at once, as `savePlayers`. Returns those written (or already stored).
]]
function WorldStore.saveCharacters(
	saves: Saves,
	world: World,
	entries: { [string]: string },
	deadline: number?,
	order: { [string]: number }?
): { [string]: boolean }
	local written: { [string]: boolean } = {}
	if not world.canSave or not world.lockHeld or not ensureLock(saves, world, deadline) then
		return written
	end
	local jobs: { SaveScheduler.Job } = {}
	for name, text in entries do
		if world.characters[name] ~= text then
			local job = characterJob(saves, world, name, text, order and order[name], written)
			if job then
				table.insert(jobs, job)
			end
		else
			written[name] = true
		end
	end
	run(saves, jobs, deadline)
	return written
end

--[[ Saving ]]

local function sameParts(a: { string }, b: { string }): boolean
	if #a ~= #b then
		return false
	end
	for i, text in a do
		if b[i] ~= text then
			return false
		end
	end
	return true
end

type Planned = { name: string, parts: { string }, slot: number, bytes: number, largest: number }

--[[
	Saves what changed of `world` (see the header) and returns what happened: written regions and
	players, the world's bytes and largest key after it (Save/WorldMeta's accounting, as the toast
	shows them), whether it nears or passes its most. Yields; `deadline` (Env.now) stops starting
	requests (shutdown). In order: players and the long regions' further parts, then the regions'
	heads (only for regions whose parts all went out), then the world's record, then the index.
]]
function WorldStore.save(saves: Saves, world: World, input: SaveInput, deadline: number?): SaveResult
	local maxText, keyLimit, maxBytes = WorldMeta.limits()
	local result: SaveResult = {
		ok = false,
		refused = false,
		bytes = 0,
		largest = 0,
		max = maxBytes,
		keyLimit = keyLimit,
		regionsWritten = 0,
		playersWritten = 0,
		written = {},
		writtenCharacters = {},
		failed = 0,
		state = "ok",
		message = nil,
	}
	if not world.canSave then
		result.refused = true
		result.message = `This world is not being saved: {world.reason or "it could not be read"}`
		return result
	end
	local meta = world.meta
	local gen = meta.gen + 1

	-- What changed.
	local planned: { Planned } = {}
	local empty = input.empty or {}
	for name, bytes in input.regions do
		local old = world.regions[name]
		if old == nil and empty[name] then
			continue
		end
		local parts = RegionCodec.split(bytes, maxText)
		if old and sameParts(old.parts, parts) then
			continue
		end
		local size, largest = 0, 0
		for _, text in parts do
			local partBytes = WorldMeta.valueBytes(text)
			size += partBytes
			largest = math.max(largest, partBytes)
		end
		table.insert(planned, {
			name = name,
			parts = parts,
			slot = if old then 1 - old.slot else 0,
			bytes = size,
			largest = largest,
		})
	end
	table.sort(planned, function(a, b)
		return a.name < b.name
	end)
	local players: { { userId: number, key: string, text: string } } = {}
	for userId, text in input.players do
		local key = string.format("%.0f", userId)
		if world.players[key] ~= text then
			table.insert(players, { userId = userId, key = key, text = text })
		end
	end
	local characters: { { name: string, text: string } } = {}
	local entries: { [string]: string } = input.characters or {}
	for name, text in entries do
		if world.characters[name] ~= text and WorldMeta.parseCharacterName(name) ~= nil then
			table.insert(characters, { name = name, text = text })
		end
	end

	-- Sizes after it (refused as a whole past the most).
	local after = WorldMeta.stored(meta)
	local largest = 0
	for name, state in world.regions do
		largest = math.max(largest, state.largest)
		after.regions[name] = state.bytes
	end
	for _, plan in planned do
		after.regions[plan.name] = plan.bytes
		largest = math.max(largest, plan.largest)
	end
	for _, entry in players do
		after.players[entry.key] = WorldMeta.valueBytes(entry.text)
		largest = math.max(largest, WorldMeta.valueBytes(entry.text))
	end
	for _, entry in characters do
		after.characters[entry.name] = WorldMeta.valueBytes(entry.text)
	end
	after.sections = input.sections
	after.operators = input.operators
	local total, metaBytes = WorldMeta.total(after :: any)
	largest = math.max(largest, metaBytes)
	for _, bytes in after.players do
		largest = math.max(largest, bytes)
	end
	result.bytes, result.largest = total, largest
	result.state = WorldMeta.sizeState(total, maxBytes, Config.Save.WarnShare)
	if result.state == "over" then
		result.refused = true
		result.message = `The world is too large to save: it would take {total} of its {maxBytes} bytes`
		return result
	end

	local function refuse(message: string): SaveResult
		result.refused = true
		result.message = message
		return result
	end
	-- A world not listed yet: its owner's list must have room (refused whole, nothing written).
	if not world.listed then
		local okIndex, value = read(saves, WorldMeta.indexKey(meta.owner), deadline)
		local index = if okIndex then WorldMeta.readIndex(value) else nil
		if index and WorldMeta.full(index, world.id) then
			world.canSave = false
			world.reason = FULL
			return refuse(`The world could not be saved: {FULL}`)
		end
	end
	-- The lock (a new world's first save takes it); a held one must still be this server's.
	if not world.lockHeld then
		local locked, refusal = WorldStore.lock(saves, world.id, deadline)
		if not locked then
			if refusal == "it is open on another server" then
				world.canSave = false
				world.reason = refusal
			end
			return refuse(`The world could not be saved: {refusal}`)
		end
		world.lockHeld = true
		world.renewedAt = saves.env.now()
	else
		local held, why = ensureLock(saves, world, deadline)
		if not held then
			return refuse(`The world could not be saved: {why}`)
		end
	end

	local store = saves.store
	local writer = saves.writer
	-- Players and further parts.
	local jobs: { SaveScheduler.Job } = {}
	local partJobs: { [string]: { SaveScheduler.Job } } = {}
	local order = input.order
	for _, entry in players do
		table.insert(
			jobs,
			playerJob(saves, world, entry.userId, entry.text, order and order[entry.userId], result.written)
		)
	end
	local characterOrder = input.characterOrder
	for _, entry in characters do
		local job = characterJob(
			saves,
			world,
			entry.name,
			entry.text,
			characterOrder and characterOrder[entry.name],
			result.writtenCharacters
		)
		if job then
			table.insert(jobs, job)
		end
	end
	for _, plan in planned do
		local list: { SaveScheduler.Job } = {}
		partJobs[plan.name] = list
		for index = 2, #plan.parts do
			local key = WorldMeta.partKey(world.id, plan.name, plan.slot, index)
			local text = plan.parts[index]
			local job = SaveScheduler.job(key, "set", function(): (boolean, string?)
				return store.set(key, WorldMeta.partValue(gen, index, text, writer))
			end)
			table.insert(list, job)
			table.insert(jobs, job)
		end
	end
	local first = run(saves, jobs, deadline)
	result.failed += #first.failed
	for _ in result.written do
		result.playersWritten += 1
	end

	-- The lock again before the commit (a long save: still this server's?).
	local still, lostWhy = ensureLock(saves, world, deadline)
	if not still then
		result.failed += 1
		result.message = `The world could not be saved: {lostWhy}`
		return result
	end

	-- Heads (the commit of each region).
	local heads: { SaveScheduler.Job } = {}
	local headPlans: { Planned } = {}
	for _, plan in planned do
		local ready = true
		for _, job in partJobs[plan.name] do
			if not job.ok then
				ready = false
			end
		end
		if ready then
			local key = WorldMeta.regionKey(world.id, plan.name)
			table.insert(
				heads,
				SaveScheduler.job(key, "set", function(): (boolean, string?)
					return store.set(key, WorldMeta.headValue(gen, #plan.parts, plan.slot, plan.parts[1], writer))
				end)
			)
			table.insert(headPlans, plan)
		end
	end
	local second = run(saves, heads, deadline)
	result.failed += #second.failed
	for i, job in heads do
		if job.ok then
			local plan = headPlans[i]
			world.regions[plan.name] =
				{ parts = plan.parts, slot = plan.slot, gen = gen, bytes = plan.bytes, largest = plan.largest }
			meta.regions[plan.name] = plan.bytes
			result.regionsWritten += 1
		end
	end

	-- The world's record, then its line in its owner's list.
	meta.gen = gen
	meta.lastPlayed = saves.env.time()
	meta.sections = input.sections
	meta.operators = input.operators
	local metaKey = WorldMeta.metaKey(world.id)
	local stored = WorldMeta.stored(meta)
	local metaJob = SaveScheduler.job(metaKey, "set", function(): (boolean, string?)
		return store.set(metaKey, stored)
	end)
	local held, why = ensureLock(saves, world, deadline)
	if not held then
		result.failed += 1
		result.message = `The world could not be saved: {why}`
		return result
	end
	local third = run(saves, { metaJob }, deadline)
	result.failed += #third.failed
	local bytes = WorldMeta.total(meta)
	result.bytes = bytes
	local entry = WorldMeta.entry(meta, bytes)
	local indexed = false
	if metaJob.ok then
		local full = false
		local ok = update(saves, WorldMeta.indexKey(meta.owner), function(old: unknown): unknown?
			local index = WorldMeta.readIndex(old)
			if index == nil then
				return nil
			end
			local listed = WorldMeta.withEntry(index, entry)
			full = listed == nil
			return listed
		end, deadline)
		indexed = ok and not full
		if full then
			-- (Filled meanwhile by another server: this world is not saved again, unlisted.)
			world.canSave = false
			world.reason = FULL
			result.failed += 1
			result.message = `The world could not be saved: {FULL}`
		elseif not ok then
			result.failed += 1
		else
			world.listed = true
		end
	end
	saves.known[world.id] = true
	result.ok = result.failed == 0 and metaJob.ok and indexed
	if not result.ok and result.message == nil then
		result.message =
			`{result.failed} write{if result.failed == 1 then "" else "s"} failed: tried again at the next save`
	end
	return result
end

--[[ Deleting and renaming ]]

--[[
	Deletes world `id` (see the header) for `who` (nil: the server itself): true, or false and why
	not. Yields. A world whose record is gone or damaged is deleted from the lists `who` may
	change (their own, the game's for its own people) where it is listed, and only then.
]]
function WorldStore.delete(saves: Saves, id: string, who: WorldMeta.Requester?): (boolean, string?)
	if not WorldMeta.validId(id) then
		return false, "there is no such world"
	end
	local locked, refusal = WorldStore.lock(saves, id)
	if not locked then
		return false, refusal
	end
	local okMeta, value = read(saves, WorldMeta.metaKey(id))
	if not okMeta then
		releaseId(saves, id)
		return false, `its record could not be read ({value})`
	end
	local meta = WorldMeta.read(value)
	local owners: { number } = {}
	if meta then
		if not WorldMeta.mayManage(meta.owner, who) then
			releaseId(saves, id)
			return false, "it is not yours"
		end
		owners = { meta.owner }
	elseif who == nil then
		owners = { 0 }
	else
		owners = if who.permanent then { who.userId, 0 } else { who.userId }
	end
	local listed = false
	for _, owner in owners do
		local found = false
		local ok, err = update(saves, WorldMeta.indexKey(owner), function(old: unknown): unknown?
			local index = WorldMeta.readIndex(old)
			if index == nil or WorldMeta.find(index, id) == nil then
				return nil
			end
			found = true
			return WorldMeta.without(index, id)
		end)
		if not ok then
			releaseId(saves, id)
			return false, `the world list could not be changed ({err})`
		end
		listed = listed or found
	end
	if meta == nil and who ~= nil and not listed then
		-- (Nothing says whose it is: only a world in one's own list is deleted.)
		releaseId(saves, id)
		return false, "there is no such world"
	end
	saves.known[id] = nil
	-- Its keys, best effort (what is left is unreachable).
	local keys: { string } = { WorldMeta.metaKey(id) }
	if meta then
		local maxText = WorldMeta.limits()
		for name, bytes in meta.regions do
			table.insert(keys, WorldMeta.regionKey(id, name))
			local parts = math.ceil(bytes / (maxText + WorldMeta.VALUE_OVERHEAD))
			for index = 2, parts do
				for slot = 0, 1 do
					table.insert(keys, WorldMeta.partKey(id, name, slot, index))
				end
			end
		end
		for userId in meta.players do
			local n = tonumber(userId)
			if n then
				table.insert(keys, WorldMeta.playerKey(id, n))
			end
		end
		for name in meta.characters do
			local userId, charId = WorldMeta.parseCharacterName(name)
			if userId and charId then
				table.insert(keys, WorldMeta.characterKey(id, userId, charId))
			end
		end
	end
	table.insert(keys, WorldMeta.lockKey(id))
	local jobs: { SaveScheduler.Job } = {}
	for _, key in keys do
		table.insert(
			jobs,
			SaveScheduler.job(key, "remove", function(): (boolean, string?)
				return saves.store.remove(key)
			end)
		)
	end
	run(saves, jobs)
	return true, nil
end

-- Renames world `id` to `name` (cleaned) for `who` (as delete): true, or false and why not. Yields.
function WorldStore.rename(saves: Saves, id: string, name: string, who: WorldMeta.Requester?): (boolean, string?)
	if not WorldMeta.validId(id) then
		return false, "there is no such world"
	end
	local clean = WorldSettings.cleanName(name)
	local locked, refusal = WorldStore.lock(saves, id)
	if not locked then
		return false, refusal
	end
	local owner: number? = nil
	local refused: string? = nil
	local ok, err = update(saves, WorldMeta.metaKey(id), function(old: unknown): unknown?
		local meta = WorldMeta.read(old)
		if meta == nil then
			refused = "there is no such world"
			return nil
		elseif not WorldMeta.mayManage(meta.owner, who) then
			refused = "it is not yours"
			return nil
		end
		refused = nil
		owner = meta.owner
		meta.name = clean
		return WorldMeta.stored(meta)
	end)
	if ok and refused then
		releaseId(saves, id)
		return false, refused
	end
	if ok then
		ok, err = update(saves, WorldMeta.indexKey(owner), function(old: unknown): unknown?
			local index = WorldMeta.readIndex(old)
			local entry = if index then WorldMeta.find(index, id) else nil
			if index == nil or entry == nil then
				return nil
			end
			local renamed = table.clone(entry)
			renamed.name = clean
			return WorldMeta.withEntry(index, renamed)
		end)
	end
	releaseId(saves, id)
	if not ok then
		return false, `the world could not be renamed ({err})`
	end
	return true, nil
end

return WorldStore
