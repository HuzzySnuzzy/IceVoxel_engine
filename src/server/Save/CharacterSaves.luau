--!strict
--[[
	Characters in a key-value store, the rules without Roblox (Terraria's player files:
	Shared/Characters; the bytes: Save/CharacterCodec), as Save/WorldStore is for worlds. Server
	Players/CharacterStore gives it the DataStore Config.Characters.StoreName
	("IceVoxelCharacters_v1") with World/WorldSave's kind of Env, or a store in memory
	(`memoryStore`) for characters that last for the session (Studio without API access,
	Config.Save.Enabled off, a user whose list could not be read); the specs give it a fake
	DataStore with budgets, cooldowns and failures. Requests go through Save/SaveScheduler: three
	tries, 2 then 4 seconds apart (2^n s), within the request budgets and the 6 s a key.

	  Keys      "u<UserId>"          the user's index (CharacterCodec.Index: the list, the next id,
	                                 whether the migration ran)
	            "u<UserId>/c<id>"    a character (CharacterCodec.value: its bytes, its progress
	                                 and its lock, so loading with the lock and every save are one
	                                 UpdateAsync each)
	            The longest, "u12345678901/c4294967295", has 23 of the 50 characters a key may have.
	  Index     `readIndex`: true and the index (nil and why when it holds what this version can't
	            read: never written over), or false when it could not be read at all: the caller
	            writes nothing for that user this session.
	  Create    the record first (an UpdateAsync: written with this server's lock when it is
	            selected at once; refused only when another server's live lock sits on that key, an
	            orphan of an earlier create whose index write failed), then the index (an
	            UpdateAsync: appended, `next` moved past its id, refused at Characters.MAX). An
	            index that refused leaves a record nobody lists: harmless, and written over by the
	            next create of that id. Ids come from `next` and are never used twice.
	  Select    one UpdateAsync that reads the record and takes its lock (SaveLock.acquire,
	            Config.Save.LockTimeout), the bytes kept exactly as stored: "busy" while another
	            server's live lock holds it (that server is still saving it; the caller asks again
	            for Config.Characters.LockWait), and while this server's own last save of it (a
	            `release`: its player left, maybe to rejoin here) is still under way, as a lock
	            of this server counts as free and the record read would be the one before that
	            save; "missing", "damaged" (another version, or bytes this one can't read: never
	            written over) or "failed" (the store).
	  Save      an UpdateAsync that writes only while the lock in the value is still this server's
	            (SaveLock.renew; "lost" otherwise, and nothing is written: the caller stops saving
	            that character), giving it back (`release`) with the last save. Without a record it
	            only renews or gives back the lock (a character this version can't save keeps its
	            bytes). Each save carries an order number (later captures higher): one older than a
	            save already under way or done for that character is never written ("skipped"), so
	            an autosave's retry can't put back what a leaving player had.
	  Delete    refused while another server's live lock holds the character; then off the index
	            first, then the record removed (one left behind is unreachable).
	  Rename    the record (refused while another server holds it or this one's last save of it
	            is under way, and for one holding items this version doesn't know: writing it
	            would lose them), then the index.
	  Touch     a character's line in the index written again (name, dead, time played, last
	            played: what the list shows), and the migration's mark.
	  Peek      a character read without its lock (its look for the list's preview).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Characters = require(Shared.Characters)
local Config = require(Shared.Config)

local CharacterCodec = require(script.Parent.CharacterCodec)
local SaveLock = require(script.Parent.SaveLock)
local SaveScheduler = require(script.Parent.SaveScheduler)
local WorldStore = require(script.Parent.WorldStore)

type Record = CharacterCodec.Record
type Index = CharacterCodec.Index

export type Saves = {
	store: WorldStore.Store,
	env: WorldStore.Env,
	scheduler: SaveScheduler.Scheduler,
	-- The order of the newest save under way or done, by record key.
	order: { [string]: number },
	-- Last saves (`release`) under way, by record key (see the header's Select).
	releasing: { [string]: number },
}

export type SelectStatus = "ok" | "busy" | "missing" | "damaged" | "failed"
export type SaveStatus = "ok" | "lost" | "failed" | "skipped"

local CharacterSaves = {}

-- What a full list says.
CharacterSaves.FULL = `you have {Characters.MAX} characters: delete one to make another`
CharacterSaves.ELSEWHERE = "it is open on another server"
CharacterSaves.STILL_SAVING = "it is still being saved"

-- Three tries, 2 then 4 seconds apart.
local OPTIONS: SaveScheduler.Options = { attempts = 3, backoff = 2, maxBackoff = 4 }

function CharacterSaves.new(store: WorldStore.Store, env: WorldStore.Env, options: SaveScheduler.Options?): Saves
	local merged: SaveScheduler.Options = table.clone(OPTIONS)
	for key, value in (options or {}) :: { [string]: any } do
		(merged :: any)[key] = value
	end
	return { store = store, env = env, scheduler = SaveScheduler.new(env, merged), order = {}, releasing = {} }
end

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = deepCopy(v)
	end
	return out
end

--[[
	A store kept in this server's memory (session-only characters): never fails, every value
	copied in and out as a DataStore's JSON would be.
]]
function CharacterSaves.memoryStore(): WorldStore.Store
	local data: { [string]: any } = {}
	return {
		get = function(key: string): (boolean, unknown)
			return true, deepCopy(data[key])
		end,
		set = function(key: string, value: unknown, _userIds: { number }?): (boolean, string?)
			data[key] = deepCopy(value)
			return true, nil
		end,
		update = function(key: string, transform: (unknown) -> unknown?): (boolean, unknown)
			local new = transform(deepCopy(data[key]))
			if new ~= nil then
				data[key] = deepCopy(new)
			end
			return true, deepCopy(data[key])
		end,
		remove = function(key: string): (boolean, string?)
			data[key] = nil
			return true, nil
		end,
	}
end

--[[ Keys ]]

local function whole(n: number): string
	return string.format("%.0f", n)
end

function CharacterSaves.indexKey(userId: number): string
	return `u{whole(userId)}`
end

function CharacterSaves.recordKey(userId: number, id: number): string
	return `u{whole(userId)}/c{whole(id)}`
end

--[[ Requests ]]

local function timeout(): number
	return math.max(10, Config.Save.LockTimeout)
end

local function runOne(saves: Saves, job: SaveScheduler.Job, deadline: number?): boolean
	local result = SaveScheduler.run(saves.scheduler, { job }, deadline)
	return result.ok == 1
end

local function read(saves: Saves, key: string): (boolean, unknown)
	local value: unknown = nil
	local job = SaveScheduler.job(key, "get", function(): (boolean, string?)
		local ok, result = saves.store.get(key)
		if ok then
			value = result
			return true, nil
		end
		return false, tostring(result)
	end)
	if runOne(saves, job) then
		return true, value
	end
	return false, job.err or "failed"
end

-- One UpdateAsync (`userId`'s, for the DataStore's user ids): ok, or false and why.
local function update(
	saves: Saves,
	key: string,
	transform: (unknown) -> unknown?,
	deadline: number?
): (boolean, string?)
	local job = SaveScheduler.job(key, "update", function(): (boolean, string?)
		local ok, result = saves.store.update(key, transform)
		return ok, if ok then nil else tostring(result)
	end)
	if runOne(saves, job, deadline) then
		return true, nil
	end
	return false, job.err or "failed"
end

--[[ The index ]]

--[[
	User `userId`'s index (see the header): true and the index (a new one when nothing is saved;
	`fresh` true then), or true, nil and why (what this version can't read), or false and why (it
	could not be read).
]]
function CharacterSaves.readIndex(saves: Saves, userId: number): (boolean, Index?, string?, boolean)
	local ok, value = read(saves, CharacterSaves.indexKey(userId))
	if not ok then
		return false, nil, `the list could not be read ({value})`, false
	end
	local index, why = CharacterCodec.readIndex(value)
	return true, index, why, value == nil
end

--[[
	Writes `index`'s line for `summary` again (the one of its id; nothing when it is not listed)
	and the migration's mark when `migrated` (see the header): the index as stored, or nil and why.
]]
function CharacterSaves.touch(
	saves: Saves,
	userId: number,
	summary: Characters.Summary?,
	migrated: boolean?,
	deadline: number?
): (Index?, string?)
	local stored: Index? = nil
	local problem: string? = nil
	local ok, err = update(saves, CharacterSaves.indexKey(userId), function(old: unknown): unknown?
		stored, problem = nil, nil
		local current, why = CharacterCodec.readIndex(old)
		if current == nil then
			problem = why
			return nil
		end
		local changed = false
		if migrated and not current.migrated then
			current.migrated = true
			changed = true
		end
		if summary then
			for i, line in current.chars do
				if line.id == summary.id then
					current.chars[i] = table.clone(summary)
					changed = true
				end
			end
		end
		Characters.sort(current.chars)
		stored = current
		return if changed then CharacterCodec.indexValue(current) else nil
	end, deadline)
	if not ok then
		return nil, `the list could not be saved ({err})`
	end
	return stored, problem
end

--[[ Creating ]]

--[[
	Makes `record` (its id: the index's `next`) for user `userId` with `progress`, then lists it
	(see the header); `lock`: this server takes its lock at once (it is the one selected). The
	index as stored after, or nil and why not. `migrated` marks the index's migration as done.
]]
function CharacterSaves.create(
	saves: Saves,
	userId: number,
	record: Record,
	progress: unknown?,
	lock: boolean,
	migrated: boolean?
): (Index?, string?)
	local env = saves.env
	local refused: string? = nil
	local okRecord, err = update(saves, CharacterSaves.recordKey(userId, record.id), function(old: unknown): unknown?
		refused = nil
		local now = env.time()
		if old ~= nil then
			local _, _, oldLock = CharacterCodec.readValue(old)
			if oldLock and SaveLock.heldByOther(oldLock, env.job, now, timeout()) then
				refused = CharacterSaves.ELSEWHERE
				return nil
			end
		end
		local newLock = if lock then SaveLock.acquire(nil, env.job, now, timeout()) else nil
		return CharacterCodec.value(record, progress, newLock)
	end)
	if not okRecord then
		return nil, `it could not be saved ({err})`
	elseif refused then
		return nil, refused
	end
	local listed: Index? = nil
	local problem: string? = nil
	local okIndex, indexErr = update(saves, CharacterSaves.indexKey(userId), function(old: unknown): unknown?
		listed, problem = nil, nil
		local current, why = CharacterCodec.readIndex(old)
		if current == nil then
			problem = why or "the list is damaged"
			return nil
		end
		for _, line in current.chars do
			if line.id == record.id then
				listed = current
				return nil
			end
		end
		if #current.chars >= Characters.MAX then
			problem = CharacterSaves.FULL
			return nil
		end
		table.insert(current.chars, CharacterCodec.summary(record))
		current.next = math.max(current.next, record.id + 1)
		current.migrated = current.migrated or migrated == true
		Characters.sort(current.chars)
		listed = current
		return CharacterCodec.indexValue(current)
	end)
	if not okIndex then
		return nil, `the list could not be saved ({indexErr})`
	end
	return listed, if listed then nil else problem
end

--[[ Selecting and saving ]]

--[[
	Loads character `id` of user `userId` and takes its lock in one UpdateAsync (see the header):
	the status, and with "ok" the record and its stored progress; why for "damaged" and "failed".
]]
function CharacterSaves.select(saves: Saves, userId: number, id: number): (SelectStatus, Record?, unknown?, string?)
	local env = saves.env
	local key = CharacterSaves.recordKey(userId, id)
	if (saves.releasing[key] or 0) > 0 then
		-- (This server's last save of it is under way: asked again once it is done.)
		return "busy", nil, nil, CharacterSaves.STILL_SAVING
	end
	local status: SelectStatus = "failed"
	local record: Record? = nil
	local progress: unknown? = nil
	local why: string? = nil
	local ok, err = update(saves, key, function(old: unknown): unknown?
		record, progress, why = nil, nil, nil
		if old == nil then
			status = "missing"
			return nil
		end
		local found, stored, _, problem = CharacterCodec.readValue(old)
		if found == nil then
			status = "damaged"
			why = problem
			return nil
		end
		local value = old :: { [string]: any }
		local taken = SaveLock.acquire(value.lock, env.job, env.time(), timeout())
		if taken == nil then
			status = "busy"
			return nil
		end
		status = "ok"
		record, progress = found, stored
		-- (The bytes exactly as stored: a record holding what this version doesn't know keeps it.)
		return { v = value.v, data = value.data, progress = value.progress, lock = taken }
	end)
	if not ok then
		return "failed", nil, nil, err
	end
	return status, record, progress, why
end

--[[
	Character `id` of user `userId` as stored, without its lock (the list's preview of a character
	not selected): the record, or nil when there is none or it can't be read. Yields.
]]
function CharacterSaves.peek(saves: Saves, userId: number, id: number): Record?
	local ok, value = read(saves, CharacterSaves.recordKey(userId, id))
	if not ok then
		return nil
	end
	return (CharacterCodec.readValue(value))
end

--[[
	Saves character `id` of user `userId` (see the header): `record` and `progress` (nil record:
	the stored bytes and progress stay, only the lock is renewed or given back), `order` its
	capture's number, `release` gives the lock back. Yields until written or given up.
]]
function CharacterSaves.save(
	saves: Saves,
	userId: number,
	id: number,
	record: Record?,
	progress: unknown?,
	order: number?,
	release: boolean?,
	deadline: number?
): SaveStatus
	local env = saves.env
	local key = CharacterSaves.recordKey(userId, id)
	local data = if record then CharacterCodec.toText(record) else nil
	local lost = false
	local skipped = false
	local job = SaveScheduler.job(key, "update", function(): (boolean, string?)
		local newest = saves.order[key]
		if order and newest and order < newest then
			skipped = true
			return true, nil
		end
		if order then
			saves.order[key] = order
		end
		local ok, result = saves.store.update(key, function(old: unknown): unknown?
			lost = false
			if type(old) ~= "table" then
				lost = true
				return nil
			end
			local value = old :: { [string]: any }
			if value.v ~= CharacterCodec.VALUE_VERSION then
				-- (A newer server's: never written over.)
				lost = true
				return nil
			end
			local now = env.time()
			local lock, gone = SaveLock.renew(value.lock, env.job, now)
			if gone or lock == nil then
				lost = true
				return nil
			end
			if release then
				lock = SaveLock.release(value.lock, env.job, now)
			end
			return {
				v = CharacterCodec.VALUE_VERSION,
				data = data or value.data,
				progress = if data then progress else value.progress,
				lock = lock,
			}
		end)
		return ok, if ok then nil else tostring(result)
	end)
	if release then
		saves.releasing[key] = (saves.releasing[key] or 0) + 1
	end
	local done = runOne(saves, job, deadline)
	if release then
		local left = (saves.releasing[key] or 1) - 1
		if left > 0 then
			saves.releasing[key] = left
		else
			saves.releasing[key] = nil
		end
	end
	if not done then
		return "failed"
	elseif skipped then
		return "skipped"
	end
	return if lost then "lost" else "ok"
end

--[[ Deleting and renaming ]]

--[[
	Deletes character `id` of user `userId` (see the header): the index as stored after, or nil
	and why not. Yields.
]]
function CharacterSaves.delete(saves: Saves, userId: number, id: number): (Index?, string?)
	local env = saves.env
	local key = CharacterSaves.recordKey(userId, id)
	local ok, value = read(saves, key)
	if not ok then
		return nil, `it could not be read ({value})`
	end
	if value ~= nil then
		local _, _, lock = CharacterCodec.readValue(value)
		if lock and SaveLock.heldByOther(lock, env.job, env.time(), timeout()) then
			return nil, CharacterSaves.ELSEWHERE
		end
	end
	local listed: Index? = nil
	local problem: string? = nil
	local okIndex, err = update(saves, CharacterSaves.indexKey(userId), function(old: unknown): unknown?
		listed, problem = nil, nil
		local current, why = CharacterCodec.readIndex(old)
		if current == nil then
			problem = why or "the list is damaged"
			return nil
		end
		local kept: { Characters.Summary } = {}
		for _, line in current.chars do
			if line.id ~= id then
				table.insert(kept, line)
			end
		end
		local changed = #kept ~= #current.chars
		current.chars = kept
		listed = current
		return if changed then CharacterCodec.indexValue(current) else nil
	end)
	if not okIndex then
		return nil, `the list could not be saved ({err})`
	elseif listed == nil then
		return nil, problem
	end
	-- (Best effort: a record left behind is unreachable.)
	local job = SaveScheduler.job(key, "remove", function(): (boolean, string?)
		return saves.store.remove(key)
	end)
	runOne(saves, job)
	saves.order[key] = nil
	return listed, nil
end

--[[
	Renames character `id` of user `userId` to `name` (a clean name, filtered: the caller's): the
	index as stored after, or nil and why not. Yields.
]]
function CharacterSaves.rename(saves: Saves, userId: number, id: number, name: string): (Index?, string?)
	local env = saves.env
	local key = CharacterSaves.recordKey(userId, id)
	if (saves.releasing[key] or 0) > 0 then
		return nil, CharacterSaves.STILL_SAVING
	end
	local refused: string? = nil
	local ok, err = update(saves, key, function(old: unknown): unknown?
		refused = nil
		if old == nil then
			refused = "it is gone"
			return nil
		end
		local record, _, lock, why = CharacterCodec.readValue(old)
		if record == nil then
			refused = why or "it can't be read"
			return nil
		elseif lock and SaveLock.heldByOther(lock, env.job, env.time(), timeout()) then
			refused = CharacterSaves.ELSEWHERE
			return nil
		elseif record.dropped > 0 then
			refused = "it holds items this version doesn't know"
			return nil
		end
		record.name = name
		local value = old :: { [string]: any }
		return {
			v = CharacterCodec.VALUE_VERSION,
			data = CharacterCodec.toText(record),
			progress = value.progress,
			lock = value.lock,
		}
	end)
	if not ok then
		return nil, `it could not be saved ({err})`
	elseif refused then
		return nil, refused
	end
	local listed: Index? = nil
	local problem: string? = nil
	local okIndex, indexErr = update(saves, CharacterSaves.indexKey(userId), function(old: unknown): unknown?
		listed, problem = nil, nil
		local current, why = CharacterCodec.readIndex(old)
		if current == nil then
			problem = why or "the list is damaged"
			return nil
		end
		for _, line in current.chars do
			if line.id == id then
				line.name = name
			end
		end
		listed = current
		return CharacterCodec.indexValue(current)
	end)
	if not okIndex then
		return nil, `the list could not be saved ({indexErr})`
	end
	return listed, if listed then nil else problem
end

return CharacterSaves
