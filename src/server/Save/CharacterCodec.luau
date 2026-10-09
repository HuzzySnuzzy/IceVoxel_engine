--!strict
--[[
	A character (Shared/Characters: Terraria's player file) as bytes, its DataStore value and its
	user's index, for server Players/CharacterStore (DataStore Config.Characters.StoreName,
	"IceVoxelCharacters_v1"). Pure, so the specs run it.

	  Record    everything a character carries from world to world: id (per user, never reused),
	            name, difficulty (Shared/Characters), dead (a Hardcore character that died),
	            legacy (made from a returning player's old progress), created / lastPlayed (os.time),
	            played (seconds in worlds), deaths, its look (Characters/Appearance), health and
	            max health (half hearts, 20: Minecraft's), mana and the Mana Crystals used
	            (Shared/Mana), the inventory (36 slots, 4 armor, the cursor, the selected hotbar
	            slot) and Terraria's equipment (7 accessories, 4 vanity armor, 7 vanity accessories,
	            the hidden bits: Inventory/Types), Tough As Nails' thirst and temperature and the
	            status effects (as Save/PlayerCodec's), and the worlds whose old per-world record
	            it has imported (`imported`: the migration's, once each). Where it stands and its
	            game mode are each world's (Save/WorldCharacterCodec); its Knowledge, Ages and
	            skills are a table beside the bytes in the value (Shared/Progression.toRecord).
	  Bytes     u8 VERSION, u8 flags (bit 0 thirst, 1 temperature, 2 dead, 3 legacy), u32 id,
	            text name, u8 difficulty, f64 created, f64 lastPlayed, f64 played, u32 deaths,
	            u16 n + n bytes of look (Appearance.encode), f32 health, f32 maxHealth, f32 mana,
	            u8 crystals, u8 selected, u16 hidden, u8 n + n x (u8 place (Types.PLACE_*: 1..36
	            slots, 37..40 armor, 41 cursor, 42..48 accessories, 49..52 vanity armor, 53..59
	            vanity accessories), stack (Save/SaveCodec)), [5 x f32 thirst], [10 x f32
	            temperature], u8 n + n x (u8 effect, u8 amplifier, i32 ticks, u8 ambient), u8 n +
	            n x text (imported world ids). 100 bytes to 3 KB: far below a key's 4 MB.
	            Decoding checks every number; anything odd is a damaged record (nil), an unknown
	            item is dropped and counted (`dropped`, as PlayerCodec's: such a record is not
	            written back this session).
	  Things    `keepThings`: one record's inventory, equipment, mana, Mana Crystals and effects
	            copied into another (Players/CharacterStore saves a visit that stopped being fair
	            with the things it had then).
	  Value     what the DataStore key "u<UserId>/c<id>" holds: { v = 1, data = base85 bytes,
	            progress = Progression's record or nil, lock = { job, at, released? } } (the lock is
	            Save/SaveLock's, inside the value so that loading with it and every later save are
	            one UpdateAsync each). `readValue` refuses another `v` (a newer server's) so it is
	            never written over.
	  Index     the key "u<UserId>": { v = 1, next = the next id, chars = { summary },
	            migrated = true once the user's old progress was looked at (Players/CharacterStore's
	            migration: done, or there was none) } (Characters.Summary: what the list shows).
	            `readIndex` of nil is a new empty index; one with a malformed summary or another `v`
	            is refused whole (never written over).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Appearance = require(Shared.Characters.Appearance)
local Characters = require(Shared.Characters)
local Config = require(Shared.Config)
local Effects = require(Shared.Effects)
local Items = require(Shared.Items)
local Types = require(Shared.Inventory.Types)

local PlayerCodec = require(script.Parent.PlayerCodec)
local SaveCodec = require(script.Parent.SaveCodec)
local SaveLock = require(script.Parent.SaveLock)

type Stack = Items.Stack

export type Record = {
	id: number,
	name: string,
	difficulty: number,
	dead: boolean,
	legacy: boolean,
	created: number,
	lastPlayed: number,
	played: number,
	deaths: number,
	appearance: Appearance.Appearance,
	health: number,
	maxHealth: number,
	mana: number,
	crystals: number,
	selected: number,
	slots: { [number]: Stack? },
	armor: { [number]: Stack? },
	cursor: Stack?,
	accessories: { [number]: Stack? },
	vanityArmor: { [number]: Stack? },
	vanityAccessories: { [number]: Stack? },
	hidden: number,
	thirst: PlayerCodec.Thirst?,
	temperature: PlayerCodec.Temperature?,
	effects: { PlayerCodec.Effect },
	-- World ids whose old per-world record this character imported.
	imported: { string },
	-- Stacks of items this version doesn't know, left out while reading (never written).
	dropped: number,
}

export type Index = {
	next: number,
	chars: { Characters.Summary },
	-- The user's old progress was looked at (the migration ran, or had nothing to do).
	migrated: boolean,
}

local CharacterCodec = {}

CharacterCodec.VERSION = 1
CharacterCodec.VALUE_VERSION = 1
CharacterCodec.INDEX_VERSION = 1
-- Most imported world ids a record keeps (the oldest go first).
CharacterCodec.MAX_IMPORTED = 64

local THIRST_FIELDS = { "thirst", "hydration", "exhaustion", "effect", "timer" }
local TEMPERATURE_FIELDS =
	{ "value", "target", "drift", "frozen", "heat", "timer", "wet", "warmth", "chill", "clemency" }
local MAX_HEALTH = 20

local function finite(value: number): boolean
	return value == value and math.abs(value) ~= math.huge
end

-- A new character: `appearance`, full health and mana, nothing held, made at `now` (os.time).
function CharacterCodec.new(
	id: number,
	name: string,
	difficulty: number,
	appearance: Appearance.Appearance,
	now: number
): Record
	return {
		id = id,
		name = name,
		difficulty = difficulty,
		dead = false,
		legacy = false,
		created = now,
		lastPlayed = now,
		played = 0,
		deaths = 0,
		appearance = appearance,
		health = MAX_HEALTH,
		maxHealth = MAX_HEALTH,
		mana = Config.Mana.Base,
		crystals = 0,
		selected = 1,
		slots = {},
		armor = {},
		cursor = nil,
		accessories = {},
		vanityArmor = {},
		vanityAccessories = {},
		hidden = 0,
		thirst = nil,
		temperature = nil,
		effects = {},
		imported = {},
		dropped = 0,
	}
end

-- What the character list shows of `record`.
function CharacterCodec.summary(record: Record): Characters.Summary
	return {
		id = record.id,
		name = record.name,
		difficulty = record.difficulty,
		dead = record.dead,
		legacy = record.legacy,
		created = record.created,
		lastPlayed = record.lastPlayed,
		played = record.played,
	}
end

local function copyStore(from: { [number]: Stack? }, size: number): { [number]: Stack? }
	local out: { [number]: Stack? } = {}
	for slot = 1, size do
		out[slot] = Items.copyStack(from[slot])
	end
	return out
end

--[[
	Sets `record`'s things to copies of `from`'s: the inventory (slots, armor, cursor, the selected
	slot), the equipment and its hidden bits, mana, the Mana Crystals and the effects. Players/
	CharacterStore saves a visit that stopped being fair with the things it had then.
]]
function CharacterCodec.keepThings(record: Record, from: Record)
	record.selected = from.selected
	record.slots = copyStore(from.slots, Types.INVENTORY_SIZE)
	record.armor = copyStore(from.armor, Types.ARMOR_SIZE)
	record.cursor = Items.copyStack(from.cursor)
	record.accessories = copyStore(from.accessories, Types.ACCESSORY_SIZE)
	record.vanityArmor = copyStore(from.vanityArmor, Types.VANITY_ARMOR_SIZE)
	record.vanityAccessories = copyStore(from.vanityAccessories, Types.VANITY_ACCESSORY_SIZE)
	record.hidden = from.hidden
	record.mana, record.crystals = from.mana, from.crystals
	local effects: { PlayerCodec.Effect } = {}
	for _, effect in from.effects do
		table.insert(effects, table.clone(effect))
	end
	record.effects = effects
end

-- (place, store, size) of each part of the inventory kept, in place order.
local function stores(record: Record): { { any } }
	return {
		{ 1, record.slots, Types.INVENTORY_SIZE },
		{ Types.PLACE_ARMOR, record.armor, Types.ARMOR_SIZE },
		{ Types.PLACE_ACCESSORY, record.accessories, Types.ACCESSORY_SIZE },
		{ Types.PLACE_VANITY_ARMOR, record.vanityArmor, Types.VANITY_ARMOR_SIZE },
		{ Types.PLACE_VANITY_ACCESSORY, record.vanityAccessories, Types.VANITY_ACCESSORY_SIZE },
	}
end

local function writeFields(w: SaveCodec.Writer, values: any, fields: { string })
	for _, field in fields do
		local value = values[field]
		SaveCodec.f32(w, if type(value) == "number" and finite(value) then value else 0)
	end
end

function CharacterCodec.encode(record: Record): buffer
	local w = SaveCodec.writer(512)
	SaveCodec.u8(w, CharacterCodec.VERSION)
	local flags = (if record.thirst then 1 else 0)
		+ (if record.temperature then 2 else 0)
		+ (if record.dead then 4 else 0)
		+ (if record.legacy then 8 else 0)
	SaveCodec.u8(w, flags)
	SaveCodec.u32(w, record.id)
	SaveCodec.text(w, record.name)
	SaveCodec.u8(w, record.difficulty)
	for _, time in { record.created, record.lastPlayed, record.played } do
		SaveCodec.f64(w, if finite(time) then math.max(time, 0) else 0)
	end
	SaveCodec.u32(w, math.clamp(math.floor(record.deaths), 0, 4294967295))
	local look = Appearance.encode(record.appearance)
	SaveCodec.u16(w, buffer.len(look))
	SaveCodec.bytes(w, look)
	SaveCodec.f32(w, if finite(record.health) then math.clamp(record.health, 0, MAX_HEALTH) else MAX_HEALTH)
	SaveCodec.f32(w, if finite(record.maxHealth) then math.clamp(record.maxHealth, 1, 1024) else MAX_HEALTH)
	SaveCodec.f32(w, if finite(record.mana) then math.clamp(record.mana, 0, Config.Mana.Max) else 0)
	SaveCodec.u8(w, math.clamp(math.floor(record.crystals), 0, Config.Mana.MaxCrystals))
	SaveCodec.u8(w, math.clamp(math.floor(record.selected), 1, Types.HOTBAR_SIZE))
	SaveCodec.u16(w, math.clamp(math.floor(record.hidden), 0, 65535))
	local held: { { place: number, stack: Stack } } = {}
	for _, part in stores(record) do
		local first, store, size = part[1] :: number, part[2] :: { [number]: Stack? }, part[3] :: number
		for slot = 1, size do
			local stack = store[slot]
			if stack and stack.count >= 1 then
				table.insert(held, { place = first + slot - 1, stack = stack })
			end
		end
	end
	local cursor = record.cursor
	if cursor and cursor.count >= 1 then
		table.insert(held, { place = Types.PLACE_CURSOR, stack = cursor })
	end
	table.sort(held, function(a, b)
		return a.place < b.place
	end)
	SaveCodec.u8(w, #held)
	for _, entry in held do
		SaveCodec.u8(w, entry.place)
		SaveCodec.stack(w, entry.stack)
	end
	if record.thirst then
		writeFields(w, record.thirst, THIRST_FIELDS)
	end
	if record.temperature then
		writeFields(w, record.temperature, TEMPERATURE_FIELDS)
	end
	local effects: { PlayerCodec.Effect } = {}
	for _, effect in record.effects do
		if Effects.isValid(effect.effect) and #effects < 255 then
			table.insert(effects, effect)
		end
	end
	SaveCodec.u8(w, #effects)
	for _, effect in effects do
		SaveCodec.u8(w, effect.effect)
		SaveCodec.u8(w, math.clamp(math.floor(effect.amplifier), 0, Effects.MAX_AMPLIFIER))
		SaveCodec.i32(w, math.clamp(math.floor(effect.ticks), -1, 2147483647))
		SaveCodec.u8(w, if effect.ambient then 1 else 0)
	end
	local imported = record.imported
	local first = math.max(1, #imported - CharacterCodec.MAX_IMPORTED + 1)
	SaveCodec.u8(w, #imported - first + 1)
	for i = first, #imported do
		SaveCodec.text(w, imported[i])
	end
	return SaveCodec.finish(w)
end

local function readFields(r: SaveCodec.Reader, fields: { string }, what: string): any
	local values: any = {}
	for _, field in fields do
		local value = SaveCodec.readF32(r)
		if not finite(value) then
			error(`bad {what}`, 0)
		end
		values[field] = value
	end
	return values
end

local function decode(bytes: buffer): Record
	local r = SaveCodec.reader(bytes)
	local version = SaveCodec.readU8(r)
	if version < 1 or version > CharacterCodec.VERSION then
		error("not a character of this version", 0)
	end
	local flags = SaveCodec.readU8(r)
	if flags > 15 then
		error("bad character flags", 0)
	end
	local id = SaveCodec.readU32(r)
	local name = SaveCodec.readText(r)
	local difficulty = SaveCodec.readU8(r)
	if id < 1 or Characters.cleanName(name) ~= name or not Characters.isDifficulty(difficulty) then
		error("bad character id, name or difficulty", 0)
	end
	local times = { SaveCodec.readFinite(r), SaveCodec.readFinite(r), SaveCodec.readFinite(r) }
	local deaths = SaveCodec.readU32(r)
	local lookLength = SaveCodec.readU16(r)
	if r.o + lookLength > r.len then
		error("truncated save", 0)
	end
	local look = buffer.create(lookLength)
	buffer.copy(look, 0, r.b, r.o, lookLength)
	r.o += lookLength
	local appearance = Appearance.decode(look)
	if appearance == nil then
		error("bad look", 0)
	end
	local record = CharacterCodec.new(id, name, difficulty, appearance, times[1])
	record.dead = bit32.btest(flags, 4)
	record.legacy = bit32.btest(flags, 8)
	record.lastPlayed, record.played, record.deaths = times[2], times[3], deaths
	local health, maxHealth, mana = SaveCodec.readF32(r), SaveCodec.readF32(r), SaveCodec.readF32(r)
	if not (finite(health) and finite(maxHealth) and finite(mana)) then
		error("bad health or mana", 0)
	end
	record.health = math.clamp(health, 0, MAX_HEALTH)
	record.maxHealth = math.clamp(maxHealth, 1, 1024)
	record.mana = math.clamp(mana, 0, Config.Mana.Max)
	record.crystals = SaveCodec.readU8(r)
	record.selected = SaveCodec.readU8(r)
	record.hidden = SaveCodec.readU16(r)
	if record.crystals > Config.Mana.MaxCrystals or record.selected < 1 or record.selected > Types.HOTBAR_SIZE then
		error("bad crystals or selected slot", 0)
	end
	local parts = stores(record)
	for _ = 1, SaveCodec.readU8(r) do
		local place = SaveCodec.readU8(r)
		local stack, lost = SaveCodec.readStack(r)
		if lost then
			record.dropped += 1
		end
		local placed = false
		if place == Types.PLACE_CURSOR then
			record.cursor = stack
			placed = true
		else
			for _, part in parts do
				local first, store, size = part[1] :: number, part[2] :: { [number]: Stack? }, part[3] :: number
				if place >= first and place < first + size then
					store[place - first + 1] = stack
					placed = true
					break
				end
			end
		end
		if not placed then
			error("bad inventory place", 0)
		end
	end
	if bit32.btest(flags, 1) then
		record.thirst = readFields(r, THIRST_FIELDS, "thirst")
	end
	if bit32.btest(flags, 2) then
		record.temperature = readFields(r, TEMPERATURE_FIELDS, "temperature")
	end
	for _ = 1, SaveCodec.readU8(r) do
		local effect = SaveCodec.readU8(r)
		local amplifier = SaveCodec.readU8(r)
		local ticks = SaveCodec.readI32(r)
		local ambient = SaveCodec.readU8(r)
		if not Effects.isValid(effect) or ticks < -1 or ambient > 1 then
			error("bad effect", 0)
		end
		table.insert(record.effects, { effect = effect, amplifier = amplifier, ticks = ticks, ambient = ambient == 1 })
	end
	for _ = 1, SaveCodec.readU8(r) do
		table.insert(record.imported, SaveCodec.readText(r))
	end
	if not SaveCodec.atEnd(r) then
		error("character has bytes left over", 0)
	end
	return record
end

-- The record in `bytes`, or nil and why not (damaged, or from a newer version).
function CharacterCodec.decode(bytes: buffer): (Record?, string?)
	local ok, result = pcall(decode, bytes)
	if ok then
		return result, nil
	end
	return nil, tostring(result)
end

-- The record as base85 text.
function CharacterCodec.toText(record: Record): string
	return SaveCodec.toText(CharacterCodec.encode(record))
end

-- The record in stored text, or nil and why not.
function CharacterCodec.fromText(text: unknown): (Record?, string?)
	if type(text) ~= "string" then
		return nil, "not a character"
	end
	local bytes = SaveCodec.fromText(text)
	if bytes == nil then
		return nil, "not a character"
	end
	return CharacterCodec.decode(bytes)
end

--[[ The DataStore values ]]

-- The value of a character's key: its bytes, its progress (Progression.toRecord) and its lock.
function CharacterCodec.value(record: Record, progress: unknown?, lock: SaveLock.Lock?): { [string]: any }
	return { v = CharacterCodec.VALUE_VERSION, data = CharacterCodec.toText(record), progress = progress, lock = lock }
end

--[[
	A character key's stored value: the record (nil: nothing saved there), its progress table as
	stored, its lock (SaveLock.read: nil for none) and why it can't be read (nil when it can).
	Another `v` or damaged bytes give the reason and no record: never write over such a value.
]]
function CharacterCodec.readValue(value: unknown): (Record?, unknown?, SaveLock.Lock?, string?)
	if value == nil then
		return nil, nil, nil, nil
	end
	if type(value) ~= "table" then
		return nil, nil, nil, "not a character"
	end
	local stored = value :: { [string]: any }
	local lock = SaveLock.read(stored.lock)
	if stored.v ~= CharacterCodec.VALUE_VERSION then
		return nil, nil, lock, "a character from another version"
	end
	local record, why = CharacterCodec.fromText(stored.data)
	if record == nil then
		return nil, nil, lock, why
	end
	return record, stored.progress, lock, nil
end

-- A user with no characters yet.
function CharacterCodec.newIndex(): Index
	return { next = 1, chars = {}, migrated = false }
end

-- The value of a user's index key.
function CharacterCodec.indexValue(index: Index): { [string]: any }
	local chars = table.create(#index.chars)
	for i, summary in index.chars do
		chars[i] = table.clone(summary)
	end
	return {
		v = CharacterCodec.INDEX_VERSION,
		next = index.next,
		chars = chars,
		migrated = if index.migrated then true else nil,
	}
end

--[[
	A user's index from its stored value (nil: none yet, a new index), or nil and why not (another
	version, a malformed summary, a summary's id at or past `next`, an id twice, more than
	Characters.MAX): never write over such an index. The list comes sorted (Characters.sort).
]]
function CharacterCodec.readIndex(value: unknown): (Index?, string?)
	if value == nil then
		return CharacterCodec.newIndex(), nil
	end
	if type(value) ~= "table" then
		return nil, "not a character list"
	end
	local stored = value :: { [string]: any }
	if stored.v ~= CharacterCodec.INDEX_VERSION then
		return nil, "a character list from another version"
	end
	local nextId = stored.next
	if type(nextId) ~= "number" or nextId < 1 or nextId ~= math.floor(nextId) or nextId >= 2 ^ 32 then
		return nil, "a damaged character list"
	end
	if type(stored.chars) ~= "table" or #stored.chars > Characters.MAX then
		return nil, "a damaged character list"
	end
	local seen: { [number]: boolean } = {}
	local chars: { Characters.Summary } = {}
	for _, entry in stored.chars do
		if not Characters.validSummary(entry) then
			return nil, "a damaged character list"
		end
		local summary = table.clone(entry) :: Characters.Summary
		if seen[summary.id] or summary.id >= nextId then
			return nil, "a damaged character list"
		end
		seen[summary.id] = true
		table.insert(chars, summary)
	end
	Characters.sort(chars)
	return { next = nextId, chars = chars, migrated = stored.migrated == true }, nil
end

return CharacterCodec
