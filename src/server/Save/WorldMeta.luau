--!strict
--[[
	The records of saved worlds in the DataStore (Config.Save.StoreName, "IceVoxelWorlds_v1") and
	their keys, for World/WorldSave. Pure, so the specs run it. Every record carries a version `v`;
	one from a newer version is refused, never half read or overwritten.

	  Keys      "index"                         the world list: { v, worlds = { entry } }, an
	                                            entry per world (id, name, type, seed, game mode,
	                                            created, last played, bytes), newest first
	            "<id>/meta"                     the world (Meta)
	            "<id>/lock"                     who has it open (Save/SaveLock)
	            "<id>/r/<rx>_<rz>"              a region's head: its first part and how many
	                                            parts it has, in which slot (Save/RegionCodec)
	            "<id>/r/<rx>_<rz>/<slot>_<i>"   its part i (2, 3...) when one key can't hold it
	            "<id>/p/<userId>"               a player's record (Save/PlayerCodec)
	            Ids are "w" + 8 base 36 digits; the longest key ("w12345678/r/-1954_-1954/1_9")
	            stays far below the 50 characters a DataStore key may have.
	  Meta      v, id, name, worldType, options (WorldTypes.encodeOptions), seed (its digits:
	            Minecraft's /seed text, exact to 2^53, where JSON numbers may not be), difficulty,
	            gameMode (new players'), allowCommands, created and lastPlayed (os.time), gen (the
	            saves made), regions (name -> bytes stored), players (user id -> bytes),
	            operators (user ids: the world's op list), sections (name -> a value other parts
	            of the game keep with the world: `registerSection`, the clock, the weather).
	  Regions   a head is { v, gen, parts, slot, d }, a further part { v, gen, i, d }; `d` is
	            base85 text. Parts 2.. are written before the head and the head last, in the
	            slot the last save did not use (0 or 1), so the head is the save's commit: until
	            it is written, the old head still names the old slot's parts, which are intact.
	            A head whose parts carry another `gen` is a damaged save.
	  Sizes     a key counts its JSON: the text plus the record around it (VALUE_OVERHEAD, a
	            generous 96 characters). A world's bytes are its meta, regions and players.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local WorldSettings = require(Shared.WorldSettings)
local WorldTypes = require(Shared.Generation.WorldTypes)

export type Meta = {
	v: number,
	id: string,
	name: string,
	worldType: string,
	options: string,
	seed: string,
	difficulty: number,
	gameMode: string,
	allowCommands: boolean,
	created: number,
	lastPlayed: number,
	gen: number,
	regions: { [string]: number },
	players: { [string]: number },
	operators: { number },
	sections: { [string]: any },
}

export type Entry = {
	id: string,
	name: string,
	worldType: string,
	seed: string,
	gameMode: string,
	created: number,
	lastPlayed: number,
	bytes: number,
}

export type Index = { v: number, worlds: { Entry } }

export type Head = { gen: number, parts: number, slot: number, text: string }

local WorldMeta = {}

WorldMeta.VERSION = 1
-- Characters a stored value takes besides its text (the JSON record around it).
WorldMeta.VALUE_OVERHEAD = 96
WorldMeta.INDEX = "index"
-- Most worlds the index lists (the oldest beyond it are dropped from the list, not deleted).
WorldMeta.MAX_WORLDS = 200

--[[ Keys ]]

function WorldMeta.metaKey(id: string): string
	return `{id}/meta`
end

function WorldMeta.lockKey(id: string): string
	return `{id}/lock`
end

function WorldMeta.regionKey(id: string, region: string): string
	return `{id}/r/{region}`
end

function WorldMeta.partKey(id: string, region: string, slot: number, index: number): string
	return `{id}/r/{region}/{slot}_{index}`
end

function WorldMeta.playerKey(id: string, userId: number): string
	return `{id}/p/{string.format("%.0f", userId)}`
end

-- Is `id` a world id this module makes?
function WorldMeta.validId(id: unknown): boolean
	return type(id) == "string" and string.match(id, "^w[0-9a-z]+$") ~= nil and #id <= 16
end

-- A new world id ("w" + 8 base 36 digits) that is not in `taken`; `random` gives 0..1.
function WorldMeta.newId(random: () -> number, taken: { [string]: boolean }?): string
	local digits = "0123456789abcdefghijklmnopqrstuvwxyz"
	for _ = 1, 100 do
		local chars = { "w" }
		for _ = 1, 8 do
			local d = math.clamp(math.floor(random() * 36), 0, 35) + 1
			table.insert(chars, string.sub(digits, d, d))
		end
		local id = table.concat(chars)
		if taken == nil or not taken[id] then
			return id
		end
	end
	error("no free world id")
end

--[[ Meta ]]

-- A new world's record.
function WorldMeta.new(id: string, settings: WorldSettings.Settings, now: number): Meta
	return {
		v = WorldMeta.VERSION,
		id = id,
		name = settings.name,
		worldType = settings.worldType,
		options = WorldTypes.encodeOptions(settings.options),
		seed = WorldSettings.seedText(settings.seed),
		difficulty = settings.difficulty,
		gameMode = settings.gameMode,
		allowCommands = settings.allowCommands,
		created = now,
		lastPlayed = now,
		gen = 0,
		regions = {},
		players = {},
		operators = {},
		sections = {},
	}
end

local function number(value: unknown): number?
	if type(value) == "number" and value == value and math.abs(value) ~= math.huge then
		return value
	end
	return nil
end

local function sizes(value: unknown): { [string]: number }
	local out: { [string]: number } = {}
	if type(value) == "table" then
		for key, bytes in value :: { [any]: any } do
			local n = number(bytes)
			if type(key) == "string" and n and n >= 0 then
				out[key] = n
			end
		end
	end
	return out
end

--[[
	The record a DataStore value holds, or nil and why not ("saved by a newer version", "not a
	world"). What is missing gets its default; nothing unknown is kept.
]]
function WorldMeta.read(value: unknown): (Meta?, string?)
	if type(value) ~= "table" then
		return nil, "not a world"
	end
	local stored = value :: { [string]: any }
	local version = number(stored.v)
	if version == nil or version < 1 then
		return nil, "not a world"
	elseif version > WorldMeta.VERSION then
		return nil, "saved by a newer version"
	end
	if not WorldMeta.validId(stored.id) or type(stored.worldType) ~= "string" or type(stored.seed) ~= "string" then
		return nil, "not a world"
	end
	local operators: { number } = {}
	if type(stored.operators) == "table" then
		for _, userId in stored.operators do
			local n = number(userId)
			if n and n == math.floor(n) then
				table.insert(operators, n)
			end
		end
	end
	local sections: { [string]: any } = {}
	if type(stored.sections) == "table" then
		for name, section in stored.sections do
			if type(name) == "string" then
				sections[name] = section
			end
		end
	end
	return {
		v = WorldMeta.VERSION,
		id = stored.id,
		name = if type(stored.name) == "string"
			then WorldSettings.cleanName(stored.name)
			else WorldSettings.DEFAULT_NAME,
		worldType = stored.worldType,
		options = if type(stored.options) == "string" then stored.options else "",
		seed = stored.seed,
		difficulty = math.clamp(math.floor(number(stored.difficulty) or 2), 0, 3),
		gameMode = if GameMode.isValid(stored.gameMode) then stored.gameMode else GameMode.SURVIVAL,
		allowCommands = stored.allowCommands == true,
		created = number(stored.created) or 0,
		lastPlayed = number(stored.lastPlayed) or 0,
		gen = math.max(0, math.floor(number(stored.gen) or 0)),
		regions = sizes(stored.regions),
		players = sizes(stored.players),
		operators = operators,
		sections = sections,
	},
		nil
end

-- The world's settings (for the boot's startWorld), or nil and why not.
function WorldMeta.settings(meta: Meta): (WorldSettings.Settings?, string?)
	local worldType = WorldTypes.get(meta.worldType)
	if worldType == nil then
		return nil, `its world type '{meta.worldType}' is gone`
	end
	local seed = tonumber(meta.seed)
	if seed == nil or seed ~= math.floor(seed) then
		return nil, "its seed is damaged"
	end
	local options = WorldTypes.decodeOptions(meta.options)
	local structures = options[WorldSettings.STRUCTURES]
	return {
		name = meta.name,
		gameMode = meta.gameMode,
		difficulty = meta.difficulty,
		allowCommands = meta.allowCommands,
		worldType = worldType.id,
		options = WorldSettings.validateOptions(worldType, options, structures ~= false),
		seed = seed,
	},
		nil
end

-- The record as stored (a fresh table: meta itself can change while a write waits).
function WorldMeta.stored(meta: Meta): { [string]: any }
	return {
		v = meta.v,
		id = meta.id,
		name = meta.name,
		worldType = meta.worldType,
		options = meta.options,
		seed = meta.seed,
		difficulty = meta.difficulty,
		gameMode = meta.gameMode,
		allowCommands = meta.allowCommands,
		created = meta.created,
		lastPlayed = meta.lastPlayed,
		gen = meta.gen,
		regions = table.clone(meta.regions),
		players = table.clone(meta.players),
		operators = table.clone(meta.operators),
		sections = table.clone(meta.sections),
	}
end

-- Characters the meta takes stored (an estimate from its parts: names and sizes).
function WorldMeta.metaBytes(meta: Meta): number
	local bytes = 400 + #meta.name + #meta.options + #meta.seed + #meta.worldType
	for name in meta.regions do
		bytes += #name + 16
	end
	for userId in meta.players do
		bytes += #userId + 16
	end
	bytes += #meta.operators * 16
	for name, section in meta.sections do
		bytes += #name + (if type(section) == "string" then #section else 256)
	end
	return bytes
end

-- The world's bytes in the store, and its largest key's.
function WorldMeta.total(meta: Meta): (number, number)
	local total = WorldMeta.metaBytes(meta)
	local largest = total
	for _, bytes in meta.regions do
		total += bytes
	end
	for _, bytes in meta.players do
		total += bytes
	end
	return total, largest
end

-- Characters a stored value with `text` takes.
function WorldMeta.valueBytes(text: string): number
	return #text + WorldMeta.VALUE_OVERHEAD
end

--[[
	Where a world's size stands against its most (Config.Save.MaxWorldBytes): "ok", "warn" (past
	`warnShare` of it) or "over".
]]
function WorldMeta.sizeState(bytes: number, max: number, warnShare: number): "ok" | "warn" | "over"
	if bytes > max then
		return "over"
	elseif bytes >= max * warnShare then
		return "warn"
	end
	return "ok"
end

--[[ Region values ]]

function WorldMeta.headValue(gen: number, parts: number, slot: number, text: string): { [string]: any }
	return { v = WorldMeta.VERSION, gen = gen, parts = parts, slot = slot, d = text }
end

function WorldMeta.partValue(gen: number, index: number, text: string): { [string]: any }
	return { v = WorldMeta.VERSION, gen = gen, i = index, d = text }
end

-- A region's head, or nil and why not.
function WorldMeta.readHead(value: unknown): (Head?, string?)
	if type(value) ~= "table" then
		return nil, "region missing"
	end
	local stored = value :: { [string]: any }
	local version = number(stored.v)
	if version == nil or version < 1 then
		return nil, "not a region"
	elseif version > WorldMeta.VERSION then
		return nil, "region saved by a newer version"
	end
	local gen, parts, slot = number(stored.gen), number(stored.parts), number(stored.slot)
	if gen == nil or parts == nil or parts < 1 or parts ~= math.floor(parts) or (slot ~= 0 and slot ~= 1) then
		return nil, "damaged region"
	elseif type(stored.d) ~= "string" then
		return nil, "damaged region"
	end
	return { gen = gen, parts = parts, slot = slot :: number, text = stored.d }, nil
end

-- Part `index` of a region whose head says `gen`: its text, or nil and why not.
function WorldMeta.readPart(value: unknown, gen: number, index: number): (string?, string?)
	if type(value) ~= "table" then
		return nil, "region part missing"
	end
	local stored = value :: { [string]: any }
	if number(stored.v) ~= WorldMeta.VERSION or number(stored.gen) ~= gen or number(stored.i) ~= index then
		return nil, "region part from another save"
	elseif type(stored.d) ~= "string" then
		return nil, "damaged region part"
	end
	return stored.d, nil
end

-- A player's stored value.
function WorldMeta.playerValue(text: string): { [string]: any }
	return { v = WorldMeta.VERSION, d = text }
end

-- The text of a stored player value (nil: none saved), or false and why not.
function WorldMeta.readPlayer(value: unknown): (string? | boolean, string?)
	if value == nil then
		return nil, nil
	elseif type(value) ~= "table" then
		return false, "not a player record"
	end
	local stored = value :: { [string]: any }
	local version = number(stored.v)
	if version == nil or version > WorldMeta.VERSION or type(stored.d) ~= "string" then
		return false, if version and version > WorldMeta.VERSION then "saved by a newer version" else "damaged"
	end
	return stored.d, nil
end

--[[ The index ]]

-- The world list a DataStore value holds (bad entries dropped; nothing: an empty list).
function WorldMeta.readIndex(value: unknown): (Index?, string?)
	local index: Index = { v = WorldMeta.VERSION, worlds = {} }
	if value == nil then
		return index, nil
	elseif type(value) ~= "table" then
		return nil, "the world list is damaged"
	end
	local stored = value :: { [string]: any }
	if (number(stored.v) or 0) > WorldMeta.VERSION then
		return nil, "the world list was saved by a newer version"
	end
	if type(stored.worlds) == "table" then
		for _, entry in stored.worlds do
			if type(entry) == "table" and WorldMeta.validId(entry.id) then
				table.insert(index.worlds, {
					id = entry.id,
					name = if type(entry.name) == "string" then entry.name else WorldSettings.DEFAULT_NAME,
					worldType = if type(entry.worldType) == "string" then entry.worldType else WorldTypes.DEFAULT,
					seed = if type(entry.seed) == "string" then entry.seed else "0",
					gameMode = if GameMode.isValid(entry.gameMode) then entry.gameMode else GameMode.SURVIVAL,
					created = number(entry.created) or 0,
					lastPlayed = number(entry.lastPlayed) or 0,
					bytes = number(entry.bytes) or 0,
				})
			end
		end
	end
	return index, nil
end

-- The index entry of a world.
function WorldMeta.entry(meta: Meta, bytes: number): Entry
	return {
		id = meta.id,
		name = meta.name,
		worldType = meta.worldType,
		seed = meta.seed,
		gameMode = meta.gameMode,
		created = meta.created,
		lastPlayed = meta.lastPlayed,
		bytes = bytes,
	}
end

-- Sorts worlds as the list shows them: last played first, then by name.
local function sortWorlds(worlds: { Entry })
	table.sort(worlds, function(a, b)
		if a.lastPlayed ~= b.lastPlayed then
			return a.lastPlayed > b.lastPlayed
		end
		return a.id < b.id
	end)
end

-- The index with `entry` in place of the world of its id (or added), at most MAX_WORLDS.
function WorldMeta.withEntry(index: Index, entry: Entry): Index
	local worlds: { Entry } = { entry }
	for _, other in index.worlds do
		if other.id ~= entry.id then
			table.insert(worlds, other)
		end
	end
	sortWorlds(worlds)
	while #worlds > WorldMeta.MAX_WORLDS do
		table.remove(worlds)
	end
	return { v = WorldMeta.VERSION, worlds = worlds }
end

-- The index without world `id`.
function WorldMeta.without(index: Index, id: string): Index
	local worlds: { Entry } = {}
	for _, other in index.worlds do
		if other.id ~= id then
			table.insert(worlds, other)
		end
	end
	return { v = WorldMeta.VERSION, worlds = worlds }
end

-- The entry of world `id` (nil: not listed).
function WorldMeta.find(index: Index, id: string): Entry?
	for _, entry in index.worlds do
		if entry.id == id then
			return entry
		end
	end
	return nil
end

-- The ids the index lists.
function WorldMeta.ids(index: Index): { [string]: boolean }
	local ids: { [string]: boolean } = {}
	for _, entry in index.worlds do
		ids[entry.id] = true
	end
	return ids
end

--[[ Limits ]]

-- Config.Save's limits, sane: the most a key's text may have and a world's bytes.
function WorldMeta.limits(): (number, number, number)
	local save = Config.Save
	local keyLimit = math.max(1024, save.KeyLimit)
	local maxText = math.clamp(save.MaxKeyBytes, 1024, keyLimit - WorldMeta.VALUE_OVERHEAD)
	return maxText, keyLimit, math.max(1024, save.MaxWorldBytes)
end

return WorldMeta
