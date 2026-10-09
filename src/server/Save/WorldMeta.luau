--!strict
--[[
	The records of saved worlds in the DataStore (Config.Save.StoreName, "IceVoxelWorlds_v1") and
	their keys, for World/WorldSave. Pure, so the specs run it. Every record carries a version `v`;
	one from a newer version is refused, never half read or overwritten.

	  Keys      "index"                         the game's world list: { v, worlds = { entry } },
	                                            an entry per world (id, name, type, seed, game
	                                            mode, owner, created, last played, bytes), last
	                                            played first: the worlds made with the title
	                                            screen off (owner 0, the game's)
	            "index/<userId>"                a player's world list: the worlds they created
	                                            on the title screen (their owner)
	            "<id>/meta"                     the world (Meta)
	            "<id>/lock"                     who has it open (Save/SaveLock)
	            "<id>/r/<rx>_<rz>"              a region's head: its first part and how many
	                                            parts it has, in which slot (Save/RegionCodec)
	            "<id>/r/<rx>_<rz>/<slot>_<i>"   its part i (2, 3...) when one key can't hold it
	            "<id>/p/<userId>"               a player's record (Save/PlayerCodec): the world's own
	                                            inventories, before characters (and with
	                                            Config.Characters.Enabled off)
	            "<id>/c/<userId>_<charId>"      what the world keeps of a character (Save/
	                                            WorldCharacterCodec: where it stood, its game mode)
	            Ids are "w" + 8 base 36 digits; the longest key ("w12345678/r/-1954_-1954/1_9")
	            stays far below the 50 characters a DataStore key may have (a character's at most
	            "w12345678/c/12345678901_4294967295", 34).
	  Meta      v, id, name, worldType, options (WorldTypes.encodeOptions), seed (its digits:
	            Minecraft's /seed text, exact to 2^53, where JSON numbers may not be), difficulty,
	            gameMode (new players'), allowCommands, owner (the user id of the player who
	            created it on the title screen; 0: the game's), created and lastPlayed (os.time),
	            gen (the saves made), regions (name -> bytes stored), players (user id -> bytes),
	            characters ("<userId>_<charId>" -> bytes), legacyImported (user id -> the character
	            that took that user's old player record in: the migration's, once per user per
	            world, Players/CharacterStore), operators (user ids: the world's op list),
	            sections (name -> a value other parts of the game keep with the world:
	            `registerSection`, the clock, the weather).
	  Owners    a world is listed in its owner's list only, and only its owner or the game's own
	            people (`mayManage`: Config.Gameplay.Admins, the game's owner, Studio) may load,
	            rename or delete it: a stranger first into an empty server (its operator until
	            the world exists) sees and touches only worlds they made. A list holds at most
	            MAX_WORLDS; a new world past that is refused (`withEntry`), never one dropped.
	  Regions   a head is { v, gen, w, parts, slot, d }, a further part { v, gen, w, i, d }; `d`
	            is base85 text, `w` the writing server's tag (`writerTag`: two servers that both
	            believe they hold the world never number their saves alike). Parts 2.. are
	            written before the head and the head last, in the slot the last save did not use
	            (0 or 1), so the head is the save's commit: until it is written, the old head
	            still names the old slot's parts, which are intact. A head whose parts carry
	            another `gen` or `w` is a damaged save (refused, never joined).
	  Sizes     a key counts its JSON: the text plus the record around it (VALUE_OVERHEAD, a
	            generous 96 characters). A world's bytes are its meta, regions, players and
	            characters.
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
	-- The user id of the player who created it (0: the game's).
	owner: number,
	created: number,
	lastPlayed: number,
	gen: number,
	regions: { [string]: number },
	players: { [string]: number },
	-- "<userId>_<charId>" -> bytes of what the world keeps of that character.
	characters: { [string]: number },
	-- User id (text) -> the character that imported their old player record here.
	legacyImported: { [string]: number },
	operators: { number },
	sections: { [string]: any },
}

export type Entry = {
	id: string,
	name: string,
	worldType: string,
	seed: string,
	gameMode: string,
	owner: number,
	created: number,
	lastPlayed: number,
	bytes: number,
}

export type Index = { v: number, worlds: { Entry } }

export type Head = { gen: number, writer: string, parts: number, slot: number, text: string }

-- Who asks to load, rename or delete a world (nil: the server itself, the boot's LoadLatest).
export type Requester = { userId: number, permanent: boolean }

local WorldMeta = {}

WorldMeta.VERSION = 1
-- Characters a stored value takes besides its text (the JSON record around it).
WorldMeta.VALUE_OVERHEAD = 96
WorldMeta.INDEX = "index"
-- Most worlds a list holds (a new world past it is refused: none is ever dropped).
WorldMeta.MAX_WORLDS = 200

--[[ Keys ]]

-- The key of `owner`'s world list (0: the game's, "index").
function WorldMeta.indexKey(owner: number?): string
	if owner == nil or owner == 0 then
		return WorldMeta.INDEX
	end
	return `{WorldMeta.INDEX}/{string.format("%.0f", owner)}`
end

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

-- The name a world gives one character of one user ("<userId>_<charId>": meta.characters' keys).
function WorldMeta.characterName(userId: number, charId: number): string
	return `{string.format("%.0f", userId)}_{string.format("%.0f", charId)}`
end

-- The user id and character id in a character's name (nil, nil for anything else).
function WorldMeta.parseCharacterName(name: string): (number?, number?)
	local user, char = string.match(name, "^(%-?%d+)_(%d+)$")
	if user == nil or char == nil then
		return nil, nil
	end
	return tonumber(user), tonumber(char)
end

function WorldMeta.characterKey(id: string, userId: number, charId: number): string
	return `{id}/c/{WorldMeta.characterName(userId, charId)}`
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

-- A user id as an owner (0 for nothing that is one).
local function ownerOf(value: unknown): number
	if type(value) == "number" and value == value and math.abs(value) ~= math.huge and value == math.floor(value) then
		return value
	end
	return 0
end

--[[
	May `who` load, rename or delete a world of `owner` (see the header)? nil `who` is the server
	itself (always); a player only their own worlds, unless they are one of the game's own people.
]]
function WorldMeta.mayManage(owner: number, who: Requester?): boolean
	if who == nil or who.permanent then
		return true
	end
	return owner ~= 0 and owner == who.userId
end

--[[
	A short tag of the server `job` writing a world (FNV-1a of its JobId in base 36): a save's
	heads and parts carry it, so two servers' saves of the same `gen` never pass for one.
]]
function WorldMeta.writerTag(job: string): string
	local hash = 2166136261
	for i = 1, #job do
		hash = bit32.bxor(hash, string.byte(job, i))
		-- (x 16777619, kept to 32 bits without losing precision: 2^24 + 403.)
		hash = (bit32.lshift(hash, 24) + hash * 403) % 4294967296
	end
	local digits = "0123456789abcdefghijklmnopqrstuvwxyz"
	local out = {}
	repeat
		local d = hash % 36
		table.insert(out, 1, string.sub(digits, d + 1, d + 1))
		hash = hash // 36
	until hash == 0
	return table.concat(out)
end

--[[ Meta ]]

-- A new world's record (`owner`: its creator's user id; 0 or nil: the game's).
function WorldMeta.new(id: string, settings: WorldSettings.Settings, now: number, owner: number?): Meta
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
		owner = ownerOf(owner),
		created = now,
		lastPlayed = now,
		gen = 0,
		regions = {},
		players = {},
		characters = {},
		legacyImported = {},
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

-- User id (text) -> a character id (whole, positive): the meta's legacyImported.
local function importers(value: unknown): { [string]: number }
	local out: { [string]: number } = {}
	if type(value) == "table" then
		for key, charId in value :: { [any]: any } do
			local n = number(charId)
			if type(key) == "string" and n and n >= 1 and n == math.floor(n) then
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
		owner = ownerOf(stored.owner),
		created = number(stored.created) or 0,
		lastPlayed = number(stored.lastPlayed) or 0,
		gen = math.max(0, math.floor(number(stored.gen) or 0)),
		regions = sizes(stored.regions),
		players = sizes(stored.players),
		characters = sizes(stored.characters),
		legacyImported = importers(stored.legacyImported),
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
		owner = meta.owner,
		created = meta.created,
		lastPlayed = meta.lastPlayed,
		gen = meta.gen,
		regions = table.clone(meta.regions),
		players = table.clone(meta.players),
		characters = table.clone(meta.characters),
		legacyImported = table.clone(meta.legacyImported),
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
	for name in meta.characters do
		bytes += #name + 16
	end
	for userId in meta.legacyImported do
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
	for _, bytes in meta.characters do
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

-- `writer`: the writing server's tag (`writerTag`).
function WorldMeta.headValue(gen: number, parts: number, slot: number, text: string, writer: string?): { [string]: any }
	return { v = WorldMeta.VERSION, gen = gen, w = writer or "", parts = parts, slot = slot, d = text }
end

function WorldMeta.partValue(gen: number, index: number, text: string, writer: string?): { [string]: any }
	return { v = WorldMeta.VERSION, gen = gen, w = writer or "", i = index, d = text }
end

local function writerOf(value: unknown): string
	return if type(value) == "string" then value else ""
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
	return { gen = gen, writer = writerOf(stored.w), parts = parts, slot = slot :: number, text = stored.d }, nil
end

-- Part `index` of a region whose head says `gen` and `writer`: its text, or nil and why not.
function WorldMeta.readPart(value: unknown, gen: number, index: number, writer: string?): (string?, string?)
	if type(value) ~= "table" then
		return nil, "region part missing"
	end
	local stored = value :: { [string]: any }
	if
		number(stored.v) ~= WorldMeta.VERSION
		or number(stored.gen) ~= gen
		or number(stored.i) ~= index
		or writerOf(stored.w) ~= (writer or "")
	then
		return nil, "region part from another save"
	elseif type(stored.d) ~= "string" then
		return nil, "damaged region part"
	end
	return stored.d, nil
end

-- A player's stored value (a character's per-world entry is stored the same way).
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
					owner = ownerOf(entry.owner),
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
		owner = meta.owner,
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

-- Is the list full for world `id` (not in it, and MAX_WORLDS others are)?
function WorldMeta.full(index: Index, id: string): boolean
	return WorldMeta.find(index, id) == nil and #index.worlds >= WorldMeta.MAX_WORLDS
end

--[[
	The index with `entry` in place of the world of its id (or added), or nil when the list is
	full for it (`full`: no world is ever dropped to make room).
]]
function WorldMeta.withEntry(index: Index, entry: Entry): Index?
	if WorldMeta.full(index, entry.id) then
		return nil
	end
	local worlds: { Entry } = { entry }
	for _, other in index.worlds do
		if other.id ~= entry.id then
			table.insert(worlds, other)
		end
	end
	sortWorlds(worlds)
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
