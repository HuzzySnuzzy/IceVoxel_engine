--!strict
--[[
	The title screen's character messages (Shared/Characters; server Players/CharacterStore on the
	lobby's net, client Ui/MainMenu), apart from Net/Protocol as Net/PlayerSync is: codecs only,
	pure. Ids: Protocol.ClientMessage.CharacterAction, EnterWorld; Protocol.ServerMessage
	.Characters, Avatar. Texts are u16 length + UTF-8 bytes; a look is u16 length + Characters/
	Appearance's bytes.

	Client -> server
	  CharacterAction  u8 action (Action), then by action:
	                     1 list         nothing: send the list again
	                     2 create       u8 difficulty, text name, look: make a character (its look
	                                    sanitized over the server's snapshot of the user's avatar)
	                     3 delete       u32 id
	                     4 rename       u32 id, text name
	                     5 select       u32 id: load it and take its lock (the one played when the
	                                    player enters a world)
	                     6 avatar       nothing: the user's own avatar for the editor (answered with
	                                    Avatar) and its preview rig
	                     7 preview      u32 id: build that character's preview rig
	                     8 editPreview  look: build the editor's preview rig with this look
	                   An unknown action, a name that is no Characters.cleanName, an unknown
	                   difficulty, id 0, a bad look or bytes left over are malformed (nil).
	  EnterWorld       u32 character id (the selected one); empty (or 0): no character (Config
	                   .Characters.Enabled off)
	Server -> client
	  Characters       u8 flags (bit 0 characters are saved between sessions, bit 1 busy), u32
	                   selected (0 none), u8 max, text message (what the last action did, or why
	                   not), u8 n + n x summary (u32 id, text name, u8 difficulty, u8 flags (bit 0
	                   dead, bit 1 legacy), f64 created, f64 lastPlayed, f64 played): the user's
	                   characters, last played first (Characters.sort)
	  Avatar           u8 purpose (1 the user's own avatar for the editor), look
]]

local Appearance = require(script.Parent.Parent.Characters.Appearance)
local Characters = require(script.Parent.Parent.Characters)

export type Request = {
	action: number,
	id: number?,
	name: string?,
	difficulty: number?,
	appearance: Appearance.Appearance?,
}

export type List = {
	-- Characters are kept between sessions (false: this session only, or the list could not load).
	saving: boolean,
	busy: boolean,
	selected: number,
	max: number,
	message: string,
	characters: { Characters.Summary },
}

local CharacterSync = {}

CharacterSync.Action = table.freeze({
	List = 1,
	Create = 2,
	Delete = 3,
	Rename = 4,
	Select = 5,
	Avatar = 6,
	Preview = 7,
	EditPreview = 8,
})
CharacterSync.AvatarPurpose = table.freeze({ Own = 1 })

-- Longest message (bytes) a list carries, and the longest look.
CharacterSync.MAX_MESSAGE = 256
CharacterSync.MAX_LOOK = 32 + Appearance.MAX_ASSETS * 12

local A = CharacterSync.Action

--[[ Helpers ]]

-- `text` cut to at most `limit` bytes at the start of a character (it stays valid UTF-8).
local function cut(text: string, limit: number): string
	if #text <= limit then
		return text
	end
	local stop = limit
	while stop > 0 do
		local byte = string.byte(text, stop + 1)
		if byte < 0x80 or byte >= 0xC0 then
			break
		end
		stop -= 1
	end
	return string.sub(text, 1, stop)
end

-- A growing list of parts written in one go (sizes known first).
type Parts = { size: number, write: { (b: buffer, o: number) -> number } }

local function newParts(): Parts
	return { size = 0, write = {} }
end

local function u8(parts: Parts, value: number)
	parts.size += 1
	table.insert(parts.write, function(b, o)
		buffer.writeu8(b, o, value)
		return o + 1
	end)
end

local function u32(parts: Parts, value: number)
	parts.size += 4
	table.insert(parts.write, function(b, o)
		buffer.writeu32(b, o, value)
		return o + 4
	end)
end

local function f64(parts: Parts, value: number)
	parts.size += 8
	table.insert(parts.write, function(b, o)
		buffer.writef64(b, o, value)
		return o + 8
	end)
end

local function text(parts: Parts, value: string)
	parts.size += 2 + #value
	table.insert(parts.write, function(b, o)
		buffer.writeu16(b, o, #value)
		buffer.writestring(b, o + 2, value)
		return o + 2 + #value
	end)
end

local function look(parts: Parts, appearance: Appearance.Appearance)
	local bytes = Appearance.encode(appearance)
	local length = buffer.len(bytes)
	parts.size += 2 + length
	table.insert(parts.write, function(b, o)
		buffer.writeu16(b, o, length)
		buffer.copy(b, o + 2, bytes, 0, length)
		return o + 2 + length
	end)
end

local function finish(parts: Parts): buffer
	local b = buffer.create(parts.size)
	local o = 0
	for _, write in parts.write do
		o = write(b, o)
	end
	return b
end

-- A bounds-checked reader: every read errors past the end (the decoders pcall).
type Reader = { b: buffer, o: number, len: number }

local function need(r: Reader, count: number)
	if r.o + count > r.len then
		error("short", 0)
	end
end

local function readU8(r: Reader): number
	need(r, 1)
	r.o += 1
	return buffer.readu8(r.b, r.o - 1)
end

local function readU32(r: Reader): number
	need(r, 4)
	r.o += 4
	return buffer.readu32(r.b, r.o - 4)
end

local function readF64(r: Reader): number
	need(r, 8)
	r.o += 8
	local value = buffer.readf64(r.b, r.o - 8)
	if value ~= value or math.abs(value) == math.huge then
		error("bad number", 0)
	end
	return value
end

local function readText(r: Reader, limit: number): string
	need(r, 2)
	local length = buffer.readu16(r.b, r.o)
	if length > limit then
		error("long text", 0)
	end
	need(r, 2 + length)
	local value = buffer.readstring(r.b, r.o + 2, length)
	r.o += 2 + length
	if utf8.len(value) == nil then
		error("bad text", 0)
	end
	return value
end

local function readName(r: Reader): string
	local raw = readText(r, Characters.MAX_NAME_BYTES)
	local name = Characters.cleanName(raw)
	if name == nil or name ~= raw then
		error("bad name", 0)
	end
	return name
end

local function readLook(r: Reader): Appearance.Appearance
	need(r, 2)
	local length = buffer.readu16(r.b, r.o)
	if length > CharacterSync.MAX_LOOK then
		error("long look", 0)
	end
	need(r, 2 + length)
	local bytes = buffer.create(length)
	buffer.copy(bytes, 0, r.b, r.o + 2, length)
	r.o += 2 + length
	local appearance = Appearance.decode(bytes)
	if appearance == nil then
		error("bad look", 0)
	end
	return appearance
end

local function readId(r: Reader): number
	local id = readU32(r)
	if id == 0 then
		error("no id", 0)
	end
	return id
end

-- Runs `read` over all of `b`: its result, nil when it errors or bytes are left over.
local function decodeAll<T>(b: buffer, read: (r: Reader) -> T): T?
	local r: Reader = { b = b, o = 0, len = buffer.len(b) }
	local ok, result = pcall(read, r)
	if not ok or r.o ~= r.len then
		return nil
	end
	return result
end

--[[ Client -> server ]]

function CharacterSync.encodeAction(request: Request): buffer
	local parts = newParts()
	local action = request.action
	u8(parts, action)
	if action == A.Create then
		u8(parts, request.difficulty or Characters.DEFAULT_DIFFICULTY)
		text(parts, cut(request.name or "", Characters.MAX_NAME_BYTES))
		look(parts, request.appearance or Appearance.default())
	elseif action == A.Delete or action == A.Select or action == A.Preview then
		u32(parts, request.id or 0)
	elseif action == A.Rename then
		u32(parts, request.id or 0)
		text(parts, cut(request.name or "", Characters.MAX_NAME_BYTES))
	elseif action == A.EditPreview then
		look(parts, request.appearance or Appearance.default())
	end
	return finish(parts)
end

-- The request, nil when the payload is malformed (see the header).
function CharacterSync.decodeAction(b: buffer): Request?
	return decodeAll(b, function(r: Reader): Request
		local action = readU8(r)
		if action == A.List or action == A.Avatar then
			return { action = action }
		elseif action == A.Create then
			local difficulty = readU8(r)
			if not Characters.isDifficulty(difficulty) then
				error("bad difficulty", 0)
			end
			local name = readName(r)
			return { action = action, difficulty = difficulty, name = name, appearance = readLook(r) }
		elseif action == A.Delete or action == A.Select or action == A.Preview then
			return { action = action, id = readId(r) }
		elseif action == A.Rename then
			local id = readId(r)
			return { action = action, id = id, name = readName(r) }
		elseif action == A.EditPreview then
			return { action = action, appearance = readLook(r) }
		end
		error("unknown action", 0)
	end)
end

-- EnterWorld's payload: the character played (0: none).
function CharacterSync.encodeEnter(id: number): buffer
	local b = buffer.create(4)
	buffer.writeu32(b, 0, math.clamp(math.floor(id), 0, 4294967295))
	return b
end

-- The character an EnterWorld names: 0 for none (an empty payload too), nil when malformed.
function CharacterSync.decodeEnter(b: buffer): number?
	local len = buffer.len(b)
	if len == 0 then
		return 0
	elseif len ~= 4 then
		return nil
	end
	return buffer.readu32(b, 0)
end

--[[ Server -> client ]]

function CharacterSync.encodeCharacters(list: List): buffer
	local parts = newParts()
	u8(parts, (if list.saving then 1 else 0) + (if list.busy then 2 else 0))
	u32(parts, list.selected)
	u8(parts, math.clamp(list.max, 0, 255))
	text(parts, cut(list.message, CharacterSync.MAX_MESSAGE))
	local count = math.min(#list.characters, 255)
	u8(parts, count)
	for i = 1, count do
		local summary = list.characters[i]
		u32(parts, summary.id)
		text(parts, cut(summary.name, Characters.MAX_NAME_BYTES))
		u8(parts, summary.difficulty)
		u8(parts, (if summary.dead then 1 else 0) + (if summary.legacy then 2 else 0))
		f64(parts, summary.created)
		f64(parts, summary.lastPlayed)
		f64(parts, summary.played)
	end
	return finish(parts)
end

-- The list, nil when malformed (unknown flags or difficulties, bad names, ids 0).
function CharacterSync.decodeCharacters(b: buffer): List?
	return decodeAll(b, function(r: Reader): List
		local flags = readU8(r)
		if flags > 3 then
			error("bad flags", 0)
		end
		local selected = readU32(r)
		local max = readU8(r)
		local message = readText(r, CharacterSync.MAX_MESSAGE)
		local characters: { Characters.Summary } = {}
		for _ = 1, readU8(r) do
			local id = readId(r)
			local name = readName(r)
			local difficulty = readU8(r)
			local summaryFlags = readU8(r)
			if not Characters.isDifficulty(difficulty) or summaryFlags > 3 then
				error("bad summary", 0)
			end
			table.insert(characters, {
				id = id,
				name = name,
				difficulty = difficulty,
				dead = bit32.btest(summaryFlags, 1),
				legacy = bit32.btest(summaryFlags, 2),
				created = readF64(r),
				lastPlayed = readF64(r),
				played = readF64(r),
			})
		end
		return {
			saving = bit32.btest(flags, 1),
			busy = bit32.btest(flags, 2),
			selected = selected,
			max = max,
			message = message,
			characters = characters,
		}
	end)
end

function CharacterSync.encodeAvatar(purpose: number, appearance: Appearance.Appearance): buffer
	local parts = newParts()
	u8(parts, purpose)
	look(parts, appearance)
	return finish(parts)
end

-- The purpose (nil when malformed) and the look.
function CharacterSync.decodeAvatar(b: buffer): (number?, Appearance.Appearance?)
	local result = decodeAll(b, function(r: Reader): { purpose: number, appearance: Appearance.Appearance }
		local purpose = readU8(r)
		if purpose ~= CharacterSync.AvatarPurpose.Own then
			error("bad purpose", 0)
		end
		return { purpose = purpose, appearance = readLook(r) }
	end)
	if result == nil then
		return nil, nil
	end
	return result.purpose, result.appearance
end

return CharacterSync
