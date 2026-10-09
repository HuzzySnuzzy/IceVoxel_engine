--!strict
--[[
	A player's record in a saved world (Minecraft's playerdata/<uuid>.dat): where they stood and
	looked, their health, game mode, inventory, Tough As Nails state and status effects, as bytes
	(Save/SaveCodec) for World/WorldSave, which keeps one key per player per world. Knowledge,
	Ages and skills are not here: Players/ProgressStore keeps them per player for every world.
	With Config.Characters on, the character carries all but the place and the game mode
	(Save/CharacterCodec, Save/WorldCharacterCodec) and these records are only read, once, by the
	migration (Players/CharacterStore). Pure, so the specs run it.

	  Record    position (the feet, blocks) and yaw (radians, the character's facing: the
	            client's camera starts from it), or none (`position` false: a player who was dead
	            or nowhere comes back at the spawn); health in half hearts (0..20, Minecraft's,
	            scaled to the character's MaxHealth on both ends); the game mode and the previous
	            one (F3 + N's); the selected hotbar slot; the 36 slots, 4 armor pieces and the
	            stack on the cursor (it goes back into the inventory), Terraria's 7 accessories,
	            4 vanity armor and 7 vanity accessories and the hidden looks' bits
	            (Inventory/Types, version 2); Tough As Nails' thirst
	            (thirst, hydration, exhaustion, Thirst effect, timer) and temperature (value,
	            target, drift, hypothermia, hyperthermia, timer, wet, Internal Warmth and Chill,
	            Climate Clemency left), each optional; and the running status effects (effect,
	            amplifier, ticks left or -1, ambient).
	  Bytes     u8 VERSION, u8 flags (bit 0 position, 1 thirst, 2 temperature, 3 hidden looks),
	            [f64 x, y, z, f32 yaw], f32 health, u8 mode and u8 previous (GameMode ids, 255
	            none), u8 selected, [u16 hidden], u8 n + n x (u8 place: Inventory/Types.PLACE_*:
	            1..36 slots, 37..40 armor, 41 cursor, 42..48 accessories, 49..52 vanity armor,
	            53..59 vanity accessories; stack), [5 x f32 thirst], [10 x f32 temperature], u8 n +
	            n x (u8 effect, u8 amplifier, i32 ticks, u8 ambient). Typical: 60-400 bytes.
	  Versions  2 added the equipment places and the hidden bits; a version 1 record (places up to
	            41, flags up to 7) still reads, and an older server refuses a version 2 one, so it
	            never writes over equipment it can't keep.
	Decoding checks every number: non-finite ones, unknown modes, slots and effects are a damaged
	record (nil), and unknown items are dropped (SaveCodec.readStack) and counted (`dropped`: such
	a record is not written back this session, World/WorldSave).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Effects = require(Shared.Effects)
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local Types = require(Shared.Inventory.Types)

local SaveCodec = require(script.Parent.SaveCodec)

type Stack = Items.Stack

export type Thirst = { thirst: number, hydration: number, exhaustion: number, effect: number, timer: number }
export type Temperature = {
	value: number,
	target: number,
	drift: number,
	frozen: number,
	heat: number,
	timer: number,
	wet: number,
	warmth: number,
	chill: number,
	clemency: number,
}
export type Effect = { effect: number, amplifier: number, ticks: number, ambient: boolean }

export type Record = {
	position: boolean,
	x: number,
	y: number,
	z: number,
	yaw: number,
	health: number,
	mode: string?,
	previous: string?,
	selected: number,
	slots: { [number]: Stack? },
	armor: { [number]: Stack? },
	cursor: Stack?,
	accessories: { [number]: Stack? },
	vanityArmor: { [number]: Stack? },
	vanityAccessories: { [number]: Stack? },
	-- Inventory/Types' hidden bits.
	hidden: number,
	thirst: Thirst?,
	temperature: Temperature?,
	effects: { Effect },
	-- Stacks of items this version doesn't know, left out while reading (never written).
	dropped: number,
}

local PlayerCodec = {}

PlayerCodec.VERSION = 2
local NONE = 255
local CURSOR = Types.PLACE_CURSOR
local THIRST_FIELDS = { "thirst", "hydration", "exhaustion", "effect", "timer" }
local TEMPERATURE_FIELDS =
	{ "value", "target", "drift", "frozen", "heat", "timer", "wet", "warmth", "chill", "clemency" }

-- An empty record: no position, full health, nothing held.
function PlayerCodec.new(): Record
	return {
		position = false,
		x = 0,
		y = 0,
		z = 0,
		yaw = 0,
		health = 20,
		mode = nil,
		previous = nil,
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
		dropped = 0,
	}
end

-- What a player has live now (World/WorldSave's capture).
export type Live = {
	-- A character stands: its place and health are captured.
	standing: boolean,
	-- Players/ToughAsNails has their thirst and temperature (a character made them).
	climate: boolean,
	-- Players/Effects has their effects (a character made them).
	effects: boolean,
}

--[[
	`record` (captured now) completed from the saved record `waiting` that no character has used
	yet (the player sits on the title screen, or their client never finished loading): where they
	stood and their health while no character stands, Tough As Nails and the effects while nothing
	live has them yet. The inventory and game mode came back at once, so they are `record`'s own.
	Without it, leaving (or an autosave) before their first character would write a fresh player
	over the saved one. nil `waiting`: `record` as it is.
]]
function PlayerCodec.withWaiting(record: Record, waiting: Record?, live: Live): Record
	if waiting == nil then
		return record
	end
	if not live.standing then
		record.position = waiting.position
		record.x, record.y, record.z, record.yaw = waiting.x, waiting.y, waiting.z, waiting.yaw
		record.health = waiting.health
	end
	if not live.climate then
		record.thirst, record.temperature = waiting.thirst, waiting.temperature
	end
	if not live.effects then
		record.effects = table.clone(waiting.effects)
	end
	return record
end

local function finite(value: number): boolean
	return value == value and math.abs(value) ~= math.huge
end

-- (first place, store, size) of each part of the inventory kept, in place order (the cursor is
-- PLACE_CURSOR, between the armor and the accessories).
local function stores(record: Record): { { any } }
	return {
		{ 1, record.slots, Types.INVENTORY_SIZE },
		{ Types.PLACE_ARMOR, record.armor, Types.ARMOR_SIZE },
		{ Types.PLACE_ACCESSORY, record.accessories, Types.ACCESSORY_SIZE },
		{ Types.PLACE_VANITY_ARMOR, record.vanityArmor, Types.VANITY_ARMOR_SIZE },
		{ Types.PLACE_VANITY_ACCESSORY, record.vanityAccessories, Types.VANITY_ACCESSORY_SIZE },
	}
end

function PlayerCodec.encode(record: Record): buffer
	local w = SaveCodec.writer(256)
	SaveCodec.u8(w, PlayerCodec.VERSION)
	local position = record.position and finite(record.x) and finite(record.y) and finite(record.z)
	local hidden = if finite(record.hidden or 0) then math.clamp(math.floor(record.hidden or 0), 0, 65535) else 0
	local flags = (if position then 1 else 0)
		+ (if record.thirst then 2 else 0)
		+ (if record.temperature then 4 else 0)
		+ (if hidden ~= 0 then 8 else 0)
	SaveCodec.u8(w, flags)
	if position then
		SaveCodec.f64(w, record.x)
		SaveCodec.f64(w, record.y)
		SaveCodec.f64(w, record.z)
		SaveCodec.f32(w, if finite(record.yaw) then record.yaw else 0)
	end
	SaveCodec.f32(w, if finite(record.health) then math.clamp(record.health, 0, 20) else 20)
	SaveCodec.u8(w, if record.mode and GameMode.isValid(record.mode) then GameMode.id(record.mode) else NONE)
	SaveCodec.u8(
		w,
		if record.previous and GameMode.isValid(record.previous) then GameMode.id(record.previous) else NONE
	)
	SaveCodec.u8(w, math.clamp(math.floor(record.selected), 1, Types.HOTBAR_SIZE))
	if hidden ~= 0 then
		SaveCodec.u16(w, hidden)
	end
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
		table.insert(held, { place = CURSOR, stack = cursor })
	end
	table.sort(held, function(a, b)
		return a.place < b.place
	end)
	SaveCodec.u8(w, #held)
	for _, entry in held do
		SaveCodec.u8(w, entry.place)
		SaveCodec.stack(w, entry.stack)
	end
	local thirst = record.thirst
	if thirst then
		for _, field in THIRST_FIELDS do
			local value = (thirst :: any)[field]
			SaveCodec.f32(w, if type(value) == "number" and finite(value) then value else 0)
		end
	end
	local temperature = record.temperature
	if temperature then
		for _, field in TEMPERATURE_FIELDS do
			local value = (temperature :: any)[field]
			SaveCodec.f32(w, if type(value) == "number" and finite(value) then value else 0)
		end
	end
	local effects: { Effect } = {}
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
	return SaveCodec.finish(w)
end

local function decode(bytes: buffer): Record
	local r = SaveCodec.reader(bytes)
	local version = SaveCodec.readU8(r)
	if version < 1 or version > PlayerCodec.VERSION then
		error("not a player record of this version", 0)
	end
	local record = PlayerCodec.new()
	local flags = SaveCodec.readU8(r)
	if flags > (if version >= 2 then 15 else 7) then
		error("bad player flags", 0)
	end
	if bit32.btest(flags, 1) then
		record.position = true
		record.x, record.y, record.z = SaveCodec.readFinite(r), SaveCodec.readFinite(r), SaveCodec.readFinite(r)
		record.yaw = SaveCodec.readF32(r)
		if not finite(record.yaw) then
			error("bad yaw", 0)
		end
	end
	local health = SaveCodec.readF32(r)
	if not finite(health) then
		error("bad health", 0)
	end
	record.health = math.clamp(health, 0, 20)
	local mode, previous = SaveCodec.readU8(r), SaveCodec.readU8(r)
	record.mode = if mode == NONE then nil else GameMode.fromId(mode)
	record.previous = if previous == NONE then nil else GameMode.fromId(previous)
	if (mode ~= NONE and record.mode == nil) or (previous ~= NONE and record.previous == nil) then
		error("bad game mode", 0)
	end
	record.selected = SaveCodec.readU8(r)
	if record.selected < 1 or record.selected > Types.HOTBAR_SIZE then
		error("bad selected slot", 0)
	end
	if bit32.btest(flags, 8) then
		record.hidden = SaveCodec.readU16(r)
	end
	-- (Version 1 knew the slots, the armor and the cursor only.)
	local lastPlace = if version >= 2 then Types.PLACE_END else CURSOR
	local parts = stores(record)
	for _ = 1, SaveCodec.readU8(r) do
		local place = SaveCodec.readU8(r)
		local stack, lost = SaveCodec.readStack(r)
		if lost then
			record.dropped += 1
		end
		local placed = false
		if place == CURSOR then
			record.cursor = stack
			placed = true
		elseif place >= 1 and place <= lastPlace then
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
			error("bad inventory slot", 0)
		end
	end
	if bit32.btest(flags, 2) then
		local thirst: any = {}
		for _, field in THIRST_FIELDS do
			local value = SaveCodec.readF32(r)
			if not finite(value) then
				error("bad thirst", 0)
			end
			thirst[field] = value
		end
		record.thirst = thirst
	end
	if bit32.btest(flags, 4) then
		local temperature: any = {}
		for _, field in TEMPERATURE_FIELDS do
			local value = SaveCodec.readF32(r)
			if not finite(value) then
				error("bad temperature", 0)
			end
			temperature[field] = value
		end
		record.temperature = temperature
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
	if not SaveCodec.atEnd(r) then
		error("player record has bytes left over", 0)
	end
	return record
end

-- The record in `bytes`, or nil and why not (damaged, or from a newer version).
function PlayerCodec.decode(bytes: buffer): (Record?, string?)
	local ok, result = pcall(decode, bytes)
	if ok then
		return result, nil
	end
	return nil, tostring(result)
end

-- The record as the text World/WorldSave stores (base85).
function PlayerCodec.toText(record: Record): string
	return SaveCodec.toText(PlayerCodec.encode(record))
end

-- The record in stored text, or nil and why not.
function PlayerCodec.fromText(text: unknown): (Record?, string?)
	if type(text) ~= "string" then
		return nil, "not a player record"
	end
	local bytes = SaveCodec.fromText(text)
	if bytes == nil then
		return nil, "not a player record"
	end
	return PlayerCodec.decode(bytes)
end

return PlayerCodec
