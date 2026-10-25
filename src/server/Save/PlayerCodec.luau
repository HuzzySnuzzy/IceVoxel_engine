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
	            Climate Clemency left), each optional; Terraria's mana and the Mana Crystals used
	            (optional, version 2: Players/Mana; with characters the character keeps them);
	            the running status effects (effect, amplifier, ticks left or -1, ambient); and the
	            zombie apocalypse's survivor record (alive ticks since the last death, zombie
	            kills, blood moons survived) and its bite's infection progress (0 healthy: server
	            Apocalypse/Survival; version 3; with characters the character keeps them); and
	            Minecraft's food bar (food, saturation, exhaustion, timer: Shared/Hunger; optional,
	            version 4; with characters the character keeps it); and the radiation dose (Sv:
	            Shared/Radiation, server Players/Radiation; optional, version 5; with characters the
	            character keeps it).
	  Bytes     u8 VERSION, the record's palette (Save/SaveCodec: names, not ids: its items, the
	            fluids in their data, its effects), u8 flags (bit 0 position, 1 thirst, 2
	            temperature, 3 hidden looks, 4 mana, 5 survivor record, 6 hunger, 7 radiation),
	            [f64 x, y, z, f32 yaw], f32 health, u8 mode and u8 previous (GameMode ids, 255
	            none), u8 selected, [u16 hidden], u8 n + n x (u8 place: Inventory/Types.PLACE_*:
	            1..36 slots, 37..40 armor, 41 cursor, 42..48 accessories, 49..52 vanity armor,
	            53..59 vanity accessories; stack), [5 x f32 thirst], [10 x f32 temperature],
	            [f32 mana, u8 crystals], u8 n + n x (varint effect, u8 amplifier, i32 ticks, u8
	            ambient), [u32 alive, u16 kills, u16 moons, u32 infection] (only when not all 0),
	            [4 x f32 hunger], [f32 dose] (only when above 0). Typical: 100-700 bytes.
	  Versions  6 keeps names (the palette). A record of versions 1 to 5 (before it: ids that were
	            that version's) is refused, never misread (SaveCodec.OLDER: Save/WorldStore gives
	            the player a fresh record, World/WorldSave tells them), and an older server
	            refuses a newer one, so it never writes over what it can't keep.
	Decoding checks every number: non-finite ones, unknown modes and slots are a damaged record
	(nil); names this version doesn't know are left out: items are dropped (SaveCodec.readStack)
	and counted (`dropped`: such a record is not written back this session, World/WorldSave),
	effects skipped.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Effects = require(Shared.Effects)
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local Types = require(Shared.Inventory.Types)

local SaveCodec = require(script.Parent.SaveCodec)

type Stack = Items.Stack
type Palette = SaveCodec.Palette

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
-- Minecraft's food bar (Shared/Hunger.State).
export type Hunger = { food: number, saturation: number, exhaustion: number, timer: number }

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
	-- Terraria's mana (nil: none kept, the player starts full) and the Mana Crystals used.
	mana: number?,
	crystals: number,
	effects: { Effect },
	-- The zombie apocalypse's survivor record (since the last death) and its bite's infection
	-- progress (0: healthy).
	alive: number,
	kills: number,
	moons: number,
	infection: number,
	-- Minecraft's food bar (nil: none kept, the player starts full).
	hunger: Hunger?,
	-- The radiation dose (Sv; 0: none).
	radiation: number,
	-- Stacks of items this version doesn't know, left out while reading (never written).
	dropped: number,
}

local PlayerCodec = {}

-- (6 since palettes: older ones are refused. 5 brought the radiation dose, 4 the food bar, 3 the
-- zombie apocalypse's survivor record and infection, 2 the equipment.)
PlayerCodec.VERSION = 6
-- The most dose a record keeps (Sv).
PlayerCodec.MAX_DOSE = 1e6
local NONE = 255
local CURSOR = Types.PLACE_CURSOR
local THIRST_FIELDS = { "thirst", "hydration", "exhaustion", "effect", "timer" }
local TEMPERATURE_FIELDS =
	{ "value", "target", "drift", "frozen", "heat", "timer", "wet", "warmth", "chill", "clemency" }
PlayerCodec.HUNGER_FIELDS = table.freeze({ "food", "saturation", "exhaustion", "timer" })

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
		mana = nil,
		crystals = 0,
		effects = {},
		alive = 0,
		kills = 0,
		moons = 0,
		infection = 0,
		hunger = nil,
		radiation = 0,
		dropped = 0,
	}
end

-- What a player has live now (World/WorldSave's capture).
export type Live = {
	-- A character stands: its place and health are captured.
	standing: boolean,
	-- Players/ToughAsNails has their thirst, temperature and food bar (a character made them).
	climate: boolean,
	-- Players/Effects has their effects (a character made them).
	effects: boolean,
	-- Players/Mana has their mana (restored, or made by a character).
	mana: boolean,
	-- Apocalypse/Survival has their survivor record (a character made it, or it was restored).
	survivor: boolean?,
	-- Players/Radiation has their dose (a character made it).
	radiation: boolean?,
}

--[[
	`record` (captured now) completed from the saved record `waiting` that no character has used
	yet (the player sits on the title screen, or their client never finished loading): where they
	stood and their health while no character stands, Tough As Nails and the food bar, the effects, the survivor
	record and the radiation dose while nothing live has them yet. The inventory and game mode came back at once, so they are `record`'s own.
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
		record.hunger = waiting.hunger
	end
	if not live.effects then
		record.effects = table.clone(waiting.effects)
	end
	if not live.mana then
		record.mana, record.crystals = waiting.mana, waiting.crystals
	end
	if not live.survivor then
		record.alive, record.kills, record.moons = waiting.alive, waiting.kills, waiting.moons
		record.infection = waiting.infection
	end
	if not live.radiation then
		record.radiation = waiting.radiation
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

--[[
	The record's bytes. `palette`: one to start from (default an empty one), its names keeping
	their indices: the specs' stand-in for a version whose content came in another order.
]]
function PlayerCodec.encode(record: Record, palette: Palette?): buffer
	local names = palette or SaveCodec.palette()
	-- (What follows the palette first, gathering it.)
	local w = SaveCodec.writer(256)
	local position = record.position and finite(record.x) and finite(record.y) and finite(record.z)
	local hidden = if finite(record.hidden or 0) then math.clamp(math.floor(record.hidden or 0), 0, 65535) else 0
	local mana = record.mana
	local hasMana = mana ~= nil and finite(mana)
	local function whole(value: number?, limit: number): number
		return if type(value) == "number" and finite(value) then math.clamp(math.floor(value), 0, limit) else 0
	end
	local alive, kills = whole(record.alive, 4294967295), whole(record.kills, 65535)
	local moons, infection = whole(record.moons, 65535), whole(record.infection, 4294967295)
	local hasSurvivor = alive + kills + moons + infection > 0
	local hunger = record.hunger
	local dose = record.radiation
	local hasDose = type(dose) == "number" and finite(dose) and dose > 0
	local flags = (if position then 1 else 0)
		+ (if record.thirst then 2 else 0)
		+ (if record.temperature then 4 else 0)
		+ (if hidden ~= 0 then 8 else 0)
		+ (if hasMana then 16 else 0)
		+ (if hasSurvivor then 32 else 0)
		+ (if hunger then 64 else 0)
		+ (if hasDose then 128 else 0)
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
		SaveCodec.stack(w, entry.stack, names)
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
	if hasMana then
		SaveCodec.f32(w, math.clamp(mana :: number, 0, Config.Mana.Max))
		local crystals = if finite(record.crystals) then math.floor(record.crystals) else 0
		SaveCodec.u8(w, math.clamp(crystals, 0, Config.Mana.MaxCrystals))
	end
	local effects: { Effect } = {}
	for _, effect in record.effects do
		if Effects.isValid(effect.effect) and #effects < 255 then
			table.insert(effects, effect)
		end
	end
	SaveCodec.u8(w, #effects)
	for _, effect in effects do
		SaveCodec.varint(w, SaveCodec.indexOf(names, "effect", effect.effect))
		SaveCodec.u8(w, math.clamp(math.floor(effect.amplifier), 0, Effects.MAX_AMPLIFIER))
		SaveCodec.i32(w, math.clamp(math.floor(effect.ticks), -1, 2147483647))
		SaveCodec.u8(w, if effect.ambient then 1 else 0)
	end
	if hasSurvivor then
		SaveCodec.u32(w, alive)
		SaveCodec.u16(w, kills)
		SaveCodec.u16(w, moons)
		SaveCodec.u32(w, infection)
	end
	if hunger then
		for _, field in PlayerCodec.HUNGER_FIELDS do
			local value = (hunger :: any)[field]
			SaveCodec.f32(w, if type(value) == "number" and finite(value) then value else 0)
		end
	end
	if hasDose then
		-- (Far above any dose a source gives: an f32 keeps it.)
		SaveCodec.f32(w, math.min(dose, PlayerCodec.MAX_DOSE))
	end
	local out = SaveCodec.writer(w.n + 128)
	SaveCodec.u8(out, PlayerCodec.VERSION)
	SaveCodec.writePalette(out, names)
	SaveCodec.bytes(out, w.b, w.n)
	return SaveCodec.finish(out)
end

local function decode(bytes: buffer): Record
	local r = SaveCodec.reader(bytes)
	local version = SaveCodec.readU8(r)
	if version > PlayerCodec.VERSION then
		error(SaveCodec.NEWER, 0)
	elseif version < 1 then
		error("not a player record", 0)
	elseif version < PlayerCodec.VERSION then
		-- (Before palettes: its ids were that version's. Never read.)
		error(SaveCodec.OLDER, 0)
	end
	local palette = SaveCodec.readPalette(r)
	local record = PlayerCodec.new()
	local flags = SaveCodec.readU8(r)
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
	local lastPlace = Types.PLACE_END
	local parts = stores(record)
	for _ = 1, SaveCodec.readU8(r) do
		local place = SaveCodec.readU8(r)
		local stack, lost = SaveCodec.readStack(r, palette)
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
	if bit32.btest(flags, 16) then
		local mana = SaveCodec.readF32(r)
		local crystals = SaveCodec.readU8(r)
		if not finite(mana) or crystals > Config.Mana.MaxCrystals then
			error("bad mana", 0)
		end
		record.mana, record.crystals = math.clamp(mana, 0, Config.Mana.Max), crystals
	end
	for _ = 1, SaveCodec.readU8(r) do
		local index = SaveCodec.readVarint(r)
		local amplifier = SaveCodec.readU8(r)
		local ticks = SaveCodec.readI32(r)
		local ambient = SaveCodec.readU8(r)
		local effect = SaveCodec.idOf(palette, "effect", index)
		if index == 0 or ticks < -1 or ambient > 1 then
			error("bad effect", 0)
		end
		-- (One this version doesn't know is skipped.)
		if effect then
			table.insert(
				record.effects,
				{ effect = effect, amplifier = amplifier, ticks = ticks, ambient = ambient == 1 }
			)
		end
	end
	if bit32.btest(flags, 32) then
		record.alive = SaveCodec.readU32(r)
		record.kills = SaveCodec.readU16(r)
		record.moons = SaveCodec.readU16(r)
		record.infection = SaveCodec.readU32(r)
	end
	if bit32.btest(flags, 64) then
		local hunger: any = {}
		for _, field in PlayerCodec.HUNGER_FIELDS do
			local value = SaveCodec.readF32(r)
			if not finite(value) then
				error("bad hunger", 0)
			end
			hunger[field] = value
		end
		record.hunger = hunger
	end
	if bit32.btest(flags, 128) then
		local dose = SaveCodec.readF32(r)
		if not finite(dose) or dose < 0 then
			error("bad radiation dose", 0)
		end
		record.radiation = dose
	end
	if not SaveCodec.atEnd(r) then
		error("player record has bytes left over", 0)
	end
	return record
end

-- The record in `bytes`, or nil and why not (damaged, or from another version: SaveCodec.NEWER,
-- SaveCodec.OLDER).
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
