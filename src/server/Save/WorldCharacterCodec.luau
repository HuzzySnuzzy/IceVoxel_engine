--!strict
--[[
	What a saved world keeps of each character that played in it (Terraria keeps the rest in the
	player file: Save/CharacterCodec): where it stood and looked, its game mode and the previous one
	(F3 + N's), and a spawn point (Terraria's bed spawns are per world; no beds yet, so nothing
	writes one). World/WorldSave keeps one key per character per world, "<id>/c/<userId>_<charId>".
	Pure, so the specs run it.

	  Entry     position (feet, blocks) and yaw (radians), or none (`position` false: the world
	            spawn); mode and previous (GameMode, nil none); spawn (whole blocks, or nil).
	  Bytes     u8 VERSION, u8 flags (bit 0 position, bit 1 spawn), [f64 x, y, z, f32 yaw],
	            u8 mode and u8 previous (GameMode ids, 255 none), [i32 x, i32 y, i32 z]: 4 to 44
	            bytes. Non-finite numbers, unknown modes, flags or bytes left over are a damaged
	            entry (nil).
	  Legacy    `fromLegacy`: the where and the mode of an old per-world player record
	            (Save/PlayerCodec, version 1, which also held an inventory: the migration moves
	            that into a character, see Players/CharacterStore).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local GameMode = require(Shared.GameMode)

local PlayerCodec = require(script.Parent.PlayerCodec)
local SaveCodec = require(script.Parent.SaveCodec)

export type Entry = {
	position: boolean,
	x: number,
	y: number,
	z: number,
	yaw: number,
	mode: string?,
	previous: string?,
	-- A spawn point's feet block (whole blocks), nil: the world spawn.
	spawn: { number }?,
}

local WorldCharacterCodec = {}

WorldCharacterCodec.VERSION = 1
local NONE = 255
local SPAWN_LIMIT = 2 ^ 31

local function finite(value: number): boolean
	return value == value and math.abs(value) ~= math.huge
end

-- Nowhere yet: the world spawn, the world's game mode.
function WorldCharacterCodec.new(): Entry
	return { position = false, x = 0, y = 0, z = 0, yaw = 0, mode = nil, previous = nil, spawn = nil }
end

-- The entry an old per-world player record gives (its place and modes; its inventory is not here).
function WorldCharacterCodec.fromLegacy(record: PlayerCodec.Record): Entry
	return {
		position = record.position,
		x = record.x,
		y = record.y,
		z = record.z,
		yaw = record.yaw,
		mode = record.mode,
		previous = record.previous,
		spawn = nil,
	}
end

local function validSpawn(spawn: { number }?): boolean
	if spawn == nil then
		return false
	end
	for i = 1, 3 do
		local value = spawn[i]
		if type(value) ~= "number" or value ~= math.floor(value) or math.abs(value) >= SPAWN_LIMIT then
			return false
		end
	end
	return true
end

function WorldCharacterCodec.encode(entry: Entry): buffer
	local w = SaveCodec.writer(48)
	SaveCodec.u8(w, WorldCharacterCodec.VERSION)
	local position = entry.position and finite(entry.x) and finite(entry.y) and finite(entry.z)
	local spawn = entry.spawn
	local hasSpawn = validSpawn(spawn)
	SaveCodec.u8(w, (if position then 1 else 0) + (if hasSpawn then 2 else 0))
	if position then
		SaveCodec.f64(w, entry.x)
		SaveCodec.f64(w, entry.y)
		SaveCodec.f64(w, entry.z)
		SaveCodec.f32(w, if finite(entry.yaw) then entry.yaw else 0)
	end
	SaveCodec.u8(w, if entry.mode and GameMode.isValid(entry.mode) then GameMode.id(entry.mode) else NONE)
	SaveCodec.u8(w, if entry.previous and GameMode.isValid(entry.previous) then GameMode.id(entry.previous) else NONE)
	if hasSpawn and spawn then
		SaveCodec.i32(w, spawn[1])
		SaveCodec.i32(w, spawn[2])
		SaveCodec.i32(w, spawn[3])
	end
	return SaveCodec.finish(w)
end

local function decode(bytes: buffer): Entry
	local r = SaveCodec.reader(bytes)
	local version = SaveCodec.readU8(r)
	if version < 1 or version > WorldCharacterCodec.VERSION then
		error("not a world's character entry of this version", 0)
	end
	local flags = SaveCodec.readU8(r)
	if flags > 3 then
		error("bad entry flags", 0)
	end
	local entry = WorldCharacterCodec.new()
	if bit32.btest(flags, 1) then
		entry.position = true
		entry.x, entry.y, entry.z = SaveCodec.readFinite(r), SaveCodec.readFinite(r), SaveCodec.readFinite(r)
		entry.yaw = SaveCodec.readF32(r)
		if not finite(entry.yaw) then
			error("bad yaw", 0)
		end
	end
	local mode, previous = SaveCodec.readU8(r), SaveCodec.readU8(r)
	entry.mode = if mode == NONE then nil else GameMode.fromId(mode)
	entry.previous = if previous == NONE then nil else GameMode.fromId(previous)
	if (mode ~= NONE and entry.mode == nil) or (previous ~= NONE and entry.previous == nil) then
		error("bad game mode", 0)
	end
	if bit32.btest(flags, 2) then
		entry.spawn = { SaveCodec.readI32(r), SaveCodec.readI32(r), SaveCodec.readI32(r) }
	end
	if not SaveCodec.atEnd(r) then
		error("entry has bytes left over", 0)
	end
	return entry
end

-- The entry in `bytes`, or nil and why not.
function WorldCharacterCodec.decode(bytes: buffer): (Entry?, string?)
	local ok, result = pcall(decode, bytes)
	if ok then
		return result, nil
	end
	return nil, tostring(result)
end

function WorldCharacterCodec.toText(entry: Entry): string
	return SaveCodec.toText(WorldCharacterCodec.encode(entry))
end

function WorldCharacterCodec.fromText(text: unknown): (Entry?, string?)
	if type(text) ~= "string" then
		return nil, "not a world's character entry"
	end
	local bytes = SaveCodec.fromText(text)
	if bytes == nil then
		return nil, "not a world's character entry"
	end
	return WorldCharacterCodec.decode(bytes)
end

return WorldCharacterCodec
