--!strict
--[[
	Saved worlds in a key-value store, the rules without Roblox: World/WorldSave gives it the
	DataStore (`Store`: get, set, update, remove, each yielding and answering ok or why not) and the
	clock, budget and tasks (`Env`, Save/SaveScheduler's), and the specs give it a fake one with
	budgets, cooldowns, latency and failures. Keys and records: Save/WorldMeta; locks:
	Save/SaveLock; regions: Save/RegionCodec; players: Save/PlayerCodec.

	  list     the index (the worlds, last played first).
	  create   a new world's handle (an id no listed world has); nothing is written until it is
	           saved, which takes its lock first.
	  load     takes the world's lock (refused while another live server holds it), reads its
	           record and every region it lists (heads, then the parts of long ones, as many at
	           once as the scheduler allows, `progress(done, total)` after each key), joins and
	           decodes them. Any failure gives the lock back and returns nil and why: a world
	           that could not be read whole is never started, so nothing is ever written over it.
	  save     writes what changed (see `save`): never for a world that can't be saved
	           (`canSave` false: its lock was lost, or it was refused), never past
	           Config.Save.MaxWorldBytes (refused as a whole, and said so), parts before heads
	           before the record, failed writes tried again (the scheduler) and what still failed
	           kept for the next save (a region whose parts failed is not committed: its old head
	           and parts stay intact).
	  players  `loadPlayer` reads one player's record with retries: false when it could not be
	           read (the caller then never writes that player this session, so an outage can't
	           replace a saved inventory with an empty one); their records go out with `save`.
	  lock     `heartbeat` renews it (false: lost to another server, saving stops), `release`
	           gives it back at shutdown or after a failed load.
	  delete   takes the lock (a world open elsewhere can't be deleted), takes the world off the
	           index, then removes its keys (best effort, within the budget: what is left is
	           unreachable).
	  rename   the index's and the record's name (not while another server has it open).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local WorldSettings = require(Shared.WorldSettings)

local PlayerCodec = require(script.Parent.PlayerCodec)
local RegionCodec = require(script.Parent.RegionCodec)
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
	lockHeld: boolean,
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
}

local WorldStore = {}

function WorldStore.new(store: Store, env: Env, options: SaveScheduler.Options?): Saves
	return {
		store = store,
		env = env,
		scheduler = SaveScheduler.new(env, options),
		known = {},
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

--[[ The list ]]

-- The world list (last played first), or nil and why not.
function WorldStore.list(saves: Saves): (WorldMeta.Index?, string?)
	local ok, value = read(saves, WorldMeta.INDEX)
	if not ok then
		return nil, `the world list could not be read ({value})`
	end
	local index, why = WorldMeta.readIndex(value)
	if index then
		saves.known = WorldMeta.ids(index)
	end
	return index, why
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

-- Renews the world's lock; false when it was lost (saving stops: `canSave` false).
function WorldStore.heartbeat(saves: Saves, world: World): boolean
	if not world.lockHeld then
		return world.canSave
	end
	local env = saves.env
	local lost = false
	local ok = update(saves, WorldMeta.lockKey(world.id), function(old: unknown): unknown?
		local lock, gone = SaveLock.renew(old, env.job, env.time())
		lost = gone
		return lock
	end)
	if ok and lost then
		world.lockHeld = false
		world.canSave = false
		world.reason = "another server opened it"
		return false
	end
	-- (A failed heartbeat is tried again next time: the lock stays ours until it goes stale.)
	return true
end

-- Gives the world's lock back (shutdown).
function WorldStore.release(saves: Saves, world: World, deadline: number?)
	if world.lockHeld then
		world.lockHeld = false
		releaseId(saves, world.id, deadline)
	end
end

--[[ Creating and loading ]]

-- A new world's handle (not written yet: its first save writes it).
function WorldStore.create(saves: Saves, settings: WorldSettings.Settings): World
	local id = WorldMeta.newId(saves.env.random, saves.known)
	saves.known[id] = true
	return {
		id = id,
		meta = WorldMeta.new(id, settings, saves.env.time()),
		regions = {},
		players = {},
		lockHeld = false,
		canSave = true,
		reason = nil,
	}
end

--[[
	Opens world `id` (see the header): its handle, settings and regions, or nil and why not. Yields.
	`progress(done, total)` follows the keys read.
]]
function WorldStore.load(saves: Saves, id: string, progress: ((number, number) -> ())?): (Loaded?, string?)
	if not WorldMeta.validId(id) then
		return nil, "there is no such world"
	end
	local locked, refusal = WorldStore.lock(saves, id)
	if not locked then
		return nil, refusal
	end
	local function fail(reason: string): (Loaded?, string?)
		releaseId(saves, id)
		return nil, reason
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
	if #result.failed > 0 then
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
					local text, partProblem = WorldMeta.readPart(stored, head.gen, index)
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
	if #result.failed > 0 then
		return fail(`a region could not be read ({result.failed[1].err})`)
	elseif broken then
		return fail(broken)
	end

	local world: World = {
		id = id,
		meta = meta,
		regions = {},
		players = {},
		lockHeld = true,
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
	Writes the records of players who left (user id -> PlayerCodec text) at once, without the rest
	of the world (Minecraft saves a player's data when they leave). Only for a world that holds
	its lock (a new world's first save writes them instead). Yields. Returns those written.
]]
function WorldStore.savePlayers(
	saves: Saves,
	world: World,
	players: { [number]: string },
	deadline: number?
): { [number]: boolean }
	local written: { [number]: boolean } = {}
	if not world.canSave or not world.lockHeld then
		return written
	end
	local jobs: { SaveScheduler.Job } = {}
	local entries: { { userId: number, key: string, text: string } } = {}
	for userId, text in players do
		local key = string.format("%.0f", userId)
		if world.players[key] ~= text then
			local storeKey = WorldMeta.playerKey(world.id, userId)
			table.insert(entries, { userId = userId, key = key, text = text })
			table.insert(
				jobs,
				SaveScheduler.job(storeKey, "set", function(): (boolean, string?)
					return saves.store.set(storeKey, WorldMeta.playerValue(text), { userId })
				end)
			)
		else
			written[userId] = true
		end
	end
	run(saves, jobs, deadline)
	for i, job in jobs do
		if job.ok then
			local entry = entries[i]
			world.players[entry.key] = entry.text
			world.meta.players[entry.key] = WorldMeta.valueBytes(entry.text)
			written[entry.userId] = true
		end
	end
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

	-- The lock (a new world's first save takes it).
	if not world.lockHeld then
		local locked, refusal = WorldStore.lock(saves, world.id, deadline)
		if not locked then
			result.refused = true
			result.message = `The world could not be saved: {refusal}`
			if refusal == "it is open on another server" then
				world.canSave = false
				world.reason = refusal
			end
			return result
		end
		world.lockHeld = true
	end

	local store = saves.store
	-- Players and further parts.
	local jobs: { SaveScheduler.Job } = {}
	local partJobs: { [string]: { SaveScheduler.Job } } = {}
	for _, entry in players do
		local key = WorldMeta.playerKey(world.id, entry.userId)
		table.insert(
			jobs,
			SaveScheduler.job(key, "set", function(): (boolean, string?)
				return store.set(key, WorldMeta.playerValue(entry.text), { entry.userId })
			end)
		)
	end
	local playerJobs = #jobs
	for _, plan in planned do
		local list: { SaveScheduler.Job } = {}
		partJobs[plan.name] = list
		for index = 2, #plan.parts do
			local key = WorldMeta.partKey(world.id, plan.name, plan.slot, index)
			local text = plan.parts[index]
			local job = SaveScheduler.job(key, "set", function(): (boolean, string?)
				return store.set(key, WorldMeta.partValue(gen, index, text))
			end)
			table.insert(list, job)
			table.insert(jobs, job)
		end
	end
	local first = run(saves, jobs, deadline)
	result.failed += #first.failed
	for i = 1, playerJobs do
		local job = jobs[i]
		if job.ok then
			local entry = players[i]
			world.players[entry.key] = entry.text
			meta.players[entry.key] = WorldMeta.valueBytes(entry.text)
			result.written[entry.userId] = true
			result.playersWritten += 1
		end
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
					return store.set(key, WorldMeta.headValue(gen, #plan.parts, plan.slot, plan.parts[1]))
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

	-- The world's record, then its line in the index.
	meta.gen = gen
	meta.lastPlayed = saves.env.time()
	meta.sections = input.sections
	meta.operators = input.operators
	local metaKey = WorldMeta.metaKey(world.id)
	local stored = WorldMeta.stored(meta)
	local metaJob = SaveScheduler.job(metaKey, "set", function(): (boolean, string?)
		return store.set(metaKey, stored)
	end)
	local third = run(saves, { metaJob }, deadline)
	result.failed += #third.failed
	local bytes = WorldMeta.total(meta)
	result.bytes = bytes
	local entry = WorldMeta.entry(meta, bytes)
	local indexed = false
	if metaJob.ok then
		local ok = update(saves, WorldMeta.INDEX, function(old: unknown): unknown?
			local index = WorldMeta.readIndex(old)
			if index == nil then
				return nil
			end
			return WorldMeta.withEntry(index, entry)
		end, deadline)
		indexed = ok
		if not ok then
			result.failed += 1
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

-- Deletes world `id` (see the header): true, or false and why not. Yields.
function WorldStore.delete(saves: Saves, id: string): (boolean, string?)
	if not WorldMeta.validId(id) then
		return false, "there is no such world"
	end
	local locked, refusal = WorldStore.lock(saves, id)
	if not locked then
		return false, refusal
	end
	local _, value = read(saves, WorldMeta.metaKey(id))
	local meta = WorldMeta.read(value)
	local ok, err = update(saves, WorldMeta.INDEX, function(old: unknown): unknown?
		local index = WorldMeta.readIndex(old)
		if index == nil then
			return nil
		end
		return WorldMeta.without(index, id)
	end)
	if not ok then
		releaseId(saves, id)
		return false, `the world list could not be changed ({err})`
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

-- Renames world `id` to `name` (cleaned): true, or false and why not. Yields.
function WorldStore.rename(saves: Saves, id: string, name: string): (boolean, string?)
	if not WorldMeta.validId(id) then
		return false, "there is no such world"
	end
	local clean = WorldSettings.cleanName(name)
	local locked, refusal = WorldStore.lock(saves, id)
	if not locked then
		return false, refusal
	end
	local ok, err = update(saves, WorldMeta.metaKey(id), function(old: unknown): unknown?
		local meta = WorldMeta.read(old)
		if meta == nil then
			return nil
		end
		meta.name = clean
		return WorldMeta.stored(meta)
	end)
	if ok then
		ok, err = update(saves, WorldMeta.INDEX, function(old: unknown): unknown?
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
