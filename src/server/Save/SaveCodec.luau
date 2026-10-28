--!strict
--[[
	The bytes of saved worlds and characters (World/WorldSave, Save/RegionCodec, Save/PlayerCodec,
	Save/CharacterCodec): a growing byte writer and a bounds-checked reader, the numbers they use,
	palettes (names, not ids), item stacks, and the text the bytes are kept as in a DataStore.
	Pure, so the specs run it.

	  Writer    `writer()` grows a buffer as it is written (doubling); `finish` gives the bytes
	            written. Numbers are little endian, as Net/Protocol's: u8, u16, u32, i32, f32,
	            f64, `varint` (LEB128: 7 bits a byte, low first, for whole numbers 0..2^53; a
	            block id is 1-2 bytes, a run of 16 cells 1) and `zigzag` (signed whole numbers
	            as varints: 0, -1, 1, -2 ... become 0, 1, 2, 3 ...). Texts are u16 length +
	            UTF-8 bytes.
	  Reader    `reader(b)` reads them back and errors ("truncated save", "bad varint") on
	            anything that runs past the end or is out of range; decoders run it under pcall,
	            so a damaged save is refused as a whole, never half read.
	  Palettes  names, not ids. Ids are given out as content loads, so another version may give a
	            block or an item another one (or none). A record's writer gathers the names of the
	            blocks, items, fluids, mob kinds and effects it writes (`indexOf`: each id once,
	            numbered 1.. in the order first written; 0 stays 0 for every kind: Air, no item,
	            no fluid) and writes them once (`writePalette`: varint the writer's place version,
	            then for each of PALETTE_KINDS in order varint n + n texts, then the ids in data,
	            below), before what uses them; the reader (`readPalette`) maps each index to
	            today's id of its name (`idOf`; blocks and items through Blocks.find and
	            Items.find, so a RENAMED line keeps a renamed one). A name this version doesn't
	            know reads as nil: a block becomes air, an item is `lost`, a fluid or a mob is
	            dropped, an effect skipped (each decoder says, and counts what it left out), never
	            a refused record. An index the palette doesn't have is a damaged save (but see
	            Ids in data). So content can be added, removed, renamed (with a RENAMED line) and
	            reordered between versions.
	  Ids in    which numbers inside data are ids is code too (Items/ItemData's id keys, Shared/
	  data      Machines `types` and tanks, Crafting/Smelting.ID_FIELDS), and another version may
	            have more or fewer such keys and fields, so the record says which it wrote as
	            palette indices, after the names: varint n + n x (text key, u8 kind: its place in
	            PALETTE_KINDS), the item data keys (`keys`); varint n + n x (varint the block's
	            palette index, u8 m + m x (u8 data index, u8 kind)), the container data indices
	            by the container's block (`fields`). The reader goes by both (`dataId`): a key or
	            field both versions keep an id of the same kind under is mapped by name; one only
	            the writer listed (a newer version's id key, or one this version dropped) or only
	            this version types (an older writer's plain number), or listed as another kind,
	            can't be read and is left out, as is an index the palette doesn't have: counted
	            under the key's or field's name (`unknown`, and the decoders' `dropped`), so the
	            newer-version rule below keeps such a record from being written back, never a
	            refused record. 0 is none in every version: kept.
	  Unknown   which of two a name this version doesn't know is, the place version that wrote
	            the record says (`newerNames`; the glue reads game.PlaceVersion once, 0 in Studio,
	            and passes it in: WorldStore's Env `place`). From this place version or an older
	            one: content since removed, left out, and the record saves as any other (the
	            server says which names went, and how many: `removedNotice`). From a newer one
	            (Roblox runs old and new servers side by side during an update) or when either
	            version is unknown (0: Studio): perhaps content this version lacks, so the record
	            plays but is never written back that session (Save/WorldStore, World/WorldSave,
	            Players/CharacterStore): writing it would lose that content for good.
	  Versions  every record starts with its version: one from a newer version is refused (NEWER:
	            never written over), and so is one from an older one (OLDER), never misread: its
	            ids were that version's. The callers start such a region, player or character
	            afresh and say so (Save/WorldStore, World/WorldSave, Players/CharacterStore).
	  Stacks    varint item (its index in the record's palette, 0: empty), varint count (1..255),
	            varint damage (a tool's wear, 0 new), then the item data in Net/Protocol's format
	            (Protocol.writeData / readData: Minecraft's item NBT made flat, checked by
	            Items.validData), the numbers under Items/ItemData's id keys (a weapon's rounds and
	            attachments, a tank's fluid) indices in the palette too. An item this version
	            doesn't know reads back as nil and `lost` (the decoders count it): the stack is
	            dropped, not the save; an id in its data that can't be read (Ids in data) drops
	            that key and counts the stack `lost` too. A count over today's maxStack (another
	            version's, or an item whose maxStack went down) is cut to it and the rest given
	            back (`extraStacks`, `giveBack`): as more stacks in the empty slots of a place that
	            takes anything (an inventory's 36 slots, a chest) or beside a dropped item, else
	            left out and counted by the item's name like a name this version doesn't know.
	  Text      DataStore values are JSON: binary has to become text. Base85 (Ascii85's
	            arithmetic: 4 bytes are a big-endian u32 written as 5 digits base 85, the last
	            group of k bytes as k + 1 digits) over 85 printable ASCII characters that JSON
	            never escapes and no encoder turns into entities: '!'..'~' without
	            " & ' / < > \ ` and ~. 1.25 characters a byte (base64 takes 1.33, a JSON array
	            of numbers about 3.5). Native buffer values in DataStores were not used: this
	            codebase's Roblox definitions type SetAsync's value as `any` and nothing here
	            can confirm how a buffer is stored or counted against the 4 MB, while text is
	            counted exactly (one character a byte: nothing here is ever escaped).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Effects = require(Shared.Effects)
local Fluids = require(Shared.Fluids)
local ItemData = require(Shared.Items.ItemData)
local Items = require(Shared.Items)
local MobList = require(Shared.Entities.MobList)
local Protocol = require(Shared.Net.Protocol)
-- (Every machine kind defined: their tanks' "<name>Fluid" keys are ItemData id keys.)
require(Shared.Machines)

export type Writer = { b: buffer, n: number }
export type Reader = { b: buffer, o: number, len: number }
export type Stack = Items.Stack

-- What a palette names (see the header): one of PALETTE_KINDS, "block", "item", "fluid", "mob"
-- or "effect".
export type PaletteKind = string
export type Palette = {
	-- The place version of the server that wrote it (game.PlaceVersion; 0: unknown, Studio).
	place: number,
	-- Each kind's names, index i the i-th.
	names: { [PaletteKind]: { string } },
	-- Today's id -> its index (written ids; a read palette's known names too).
	index: { [PaletteKind]: { [number]: number } },
	-- Index -> today's id of its name (false: a name this version doesn't know).
	ids: { [PaletteKind]: { [number]: number | false } },
	-- Reading: names this version doesn't know -> how many things were left out (`idOf`), and
	-- the ids in data that couldn't be read, under their key's or field's name (`dataId`).
	unknown: { [string]: number },
	-- Ids in data (see the header): the item data keys written as palette indices, and of what
	-- kind (writing: those `stack` wrote so; read: the writer's list) ...
	keys: { [string]: PaletteKind },
	-- ... and the container data indices, by the palette index of the container's block
	-- (`fieldIndex`).
	fields: { [number]: { [number]: PaletteKind } },
}

local SaveCodec = {}

-- The kinds a palette names, in the order they are written.
SaveCodec.PALETTE_KINDS = table.freeze({ "block", "item", "fluid", "mob", "effect" } :: { PaletteKind })
-- A kind's place in PALETTE_KINDS (how ids in data say their kind).
local KIND_CODE: { [PaletteKind]: number } = {}
for code, kind in SaveCodec.PALETTE_KINDS do
	KIND_CODE[kind] = code
end
-- Why a record from another version is refused (see the header).
SaveCodec.NEWER = "saved by a newer version"
SaveCodec.OLDER = "saved by an older version"

-- (Id 0 is none for every kind, Air for blocks: never in a palette.)
assert(Blocks.AIR == 0, "SaveCodec keeps Air as 0")

-- The base85 digits, in order (85 characters JSON leaves alone).
local DIGITS: { number } = {}
local DIGIT_OF: { [number]: number } = {}
do
	local skip =
		{ [34] = true, [38] = true, [39] = true, [47] = true, [60] = true, [62] = true, [92] = true, [96] = true }
	for code = 33, 125 do
		if not skip[code] then
			table.insert(DIGITS, code)
			DIGIT_OF[code] = #DIGITS - 1
		end
	end
	assert(#DIGITS == 85, "SaveCodec needs 85 digits")
end
SaveCodec.ALPHABET = (function(): string
	local chars = {}
	for _, code in DIGITS do
		table.insert(chars, string.char(code))
	end
	return table.concat(chars)
end)()

--[[ Writer ]]

function SaveCodec.writer(capacity: number?): Writer
	return { b = buffer.create(math.max(16, capacity or 256)), n = 0 }
end

-- Room for `extra` more bytes.
local function ensure(w: Writer, extra: number)
	local need = w.n + extra
	local size = buffer.len(w.b)
	if need > size then
		local grown = buffer.create(math.max(need, size * 2))
		buffer.copy(grown, 0, w.b, 0, w.n)
		w.b = grown
	end
end
SaveCodec.ensure = ensure

function SaveCodec.u8(w: Writer, value: number)
	ensure(w, 1)
	buffer.writeu8(w.b, w.n, value)
	w.n += 1
end

function SaveCodec.u16(w: Writer, value: number)
	ensure(w, 2)
	buffer.writeu16(w.b, w.n, value)
	w.n += 2
end

function SaveCodec.u32(w: Writer, value: number)
	ensure(w, 4)
	buffer.writeu32(w.b, w.n, value)
	w.n += 4
end

function SaveCodec.i32(w: Writer, value: number)
	ensure(w, 4)
	buffer.writei32(w.b, w.n, value)
	w.n += 4
end

function SaveCodec.f32(w: Writer, value: number)
	ensure(w, 4)
	buffer.writef32(w.b, w.n, value)
	w.n += 4
end

function SaveCodec.f64(w: Writer, value: number)
	ensure(w, 8)
	buffer.writef64(w.b, w.n, value)
	w.n += 8
end

-- A whole number 0..2^53 in 1..8 bytes (LEB128). Anything else is a bug: it errors.
function SaveCodec.varint(w: Writer, value: number)
	assert(value >= 0 and value == math.floor(value) and value <= 9007199254740992, "varint needs a whole number >= 0")
	ensure(w, 8)
	local b, n = w.b, w.n
	while value >= 128 do
		buffer.writeu8(b, n, value % 128 + 128)
		value //= 128
		n += 1
	end
	buffer.writeu8(b, n, value)
	w.n = n + 1
end

-- A signed whole number as a varint (zigzag: 0, -1, 1, -2 ... are 0, 1, 2, 3 ...).
function SaveCodec.zigzag(w: Writer, value: number)
	SaveCodec.varint(w, if value >= 0 then value * 2 else -value * 2 - 1)
end

-- u16 length + the text's bytes (cut to 65535 bytes).
function SaveCodec.text(w: Writer, value: string)
	local length = math.min(#value, 65535)
	ensure(w, 2 + length)
	buffer.writeu16(w.b, w.n, length)
	buffer.writestring(w.b, w.n + 2, value, length)
	w.n += 2 + length
end

-- Appends the first `count` bytes of `source` (all of it by default).
function SaveCodec.bytes(w: Writer, source: buffer, count: number?)
	local length = count or buffer.len(source)
	ensure(w, length)
	buffer.copy(w.b, w.n, source, 0, length)
	w.n += length
end

-- The bytes written (a buffer of exactly that length).
function SaveCodec.finish(w: Writer): buffer
	local out = buffer.create(w.n)
	buffer.copy(out, 0, w.b, 0, w.n)
	return out
end

--[[ Reader ]]

function SaveCodec.reader(b: buffer, from: number?, to: number?): Reader
	return { b = b, o = from or 0, len = to or buffer.len(b) }
end

local function need(r: Reader, count: number)
	if r.o + count > r.len then
		error("truncated save", 0)
	end
end

function SaveCodec.atEnd(r: Reader): boolean
	return r.o >= r.len
end

function SaveCodec.readU8(r: Reader): number
	need(r, 1)
	local value = buffer.readu8(r.b, r.o)
	r.o += 1
	return value
end

function SaveCodec.readU16(r: Reader): number
	need(r, 2)
	local value = buffer.readu16(r.b, r.o)
	r.o += 2
	return value
end

function SaveCodec.readU32(r: Reader): number
	need(r, 4)
	local value = buffer.readu32(r.b, r.o)
	r.o += 4
	return value
end

function SaveCodec.readI32(r: Reader): number
	need(r, 4)
	local value = buffer.readi32(r.b, r.o)
	r.o += 4
	return value
end

function SaveCodec.readF32(r: Reader): number
	need(r, 4)
	local value = buffer.readf32(r.b, r.o)
	r.o += 4
	return value
end

function SaveCodec.readF64(r: Reader): number
	need(r, 8)
	local value = buffer.readf64(r.b, r.o)
	r.o += 8
	return value
end

-- A finite f64 (NaN and infinities are a damaged save).
function SaveCodec.readFinite(r: Reader): number
	local value = SaveCodec.readF64(r)
	if value ~= value or math.abs(value) == math.huge then
		error("bad number in save", 0)
	end
	return value
end

function SaveCodec.readVarint(r: Reader): number
	local value, scale = 0, 1
	for _ = 1, 8 do
		local byte = SaveCodec.readU8(r)
		value += (byte % 128) * scale
		if byte < 128 then
			return value
		end
		scale *= 128
	end
	error("bad varint in save", 0)
end

function SaveCodec.readZigzag(r: Reader): number
	local value = SaveCodec.readVarint(r)
	return if value % 2 == 0 then value // 2 else -(value + 1) // 2
end

function SaveCodec.readText(r: Reader): string
	local length = SaveCodec.readU16(r)
	need(r, length)
	local value = buffer.readstring(r.b, r.o, length)
	r.o += length
	return value
end

--[[ Palettes (names, not ids) ]]

-- The name of `id`, one of `kind`'s, as this version has it (nil: none).
local function nameOf(kind: PaletteKind, id: number): string?
	if kind == "block" then
		return if Blocks.isValid(id) then Blocks.get(id).name else nil
	elseif kind == "item" then
		local def = Items.get(id)
		return if def then def.name else nil
	elseif kind == "fluid" then
		local fluid = Fluids.get(id)
		return if fluid then fluid.name else nil
	elseif kind == "mob" then
		local mob = MobList.get(id)
		return if mob then mob.name else nil
	end
	local effect = Effects.get(id)
	return if effect then effect.name else nil
end

-- Today's id of the `kind` named `name` (nil: none). Blocks and items follow their RENAMED.
local function findId(kind: PaletteKind, name: string): number?
	if kind == "block" then
		return Blocks.find(name)
	elseif kind == "item" then
		return Items.find(name)
	elseif kind == "fluid" then
		return Fluids.find(name)
	elseif kind == "mob" then
		return MobList.find(name)
	end
	return Effects.id[name]
end

-- A place version as kept: a whole number 0.. (anything else: 0, unknown).
local function placeOf(value: any): number
	return if type(value) == "number" and value >= 0 and value == math.floor(value) and value < 2 ^ 53 then value else 0
end

-- An empty palette, written by place version `place` (default 0: unknown).
function SaveCodec.palette(place: number?): Palette
	local palette: Palette =
		{ place = placeOf(place), names = {}, index = {}, ids = {}, unknown = {}, keys = {}, fields = {} }
	for _, kind in SaveCodec.PALETTE_KINDS do
		palette.names[kind] = {}
		palette.index[kind] = {}
		palette.ids[kind] = {}
	end
	return palette
end

--[[
	The index `id` (one of `kind`'s) is written as, its name added to `palette` the first time:
	0 for 0 (Air, no item, no fluid ...) and for an id this version has no such thing for (the
	callers write only ids they checked).
]]
function SaveCodec.indexOf(palette: Palette, kind: PaletteKind, id: number): number
	if id == 0 then
		return 0
	end
	local index = palette.index[kind]
	local at = index[id]
	if at then
		return at
	end
	local name = nameOf(kind, id)
	if name == nil then
		return 0
	end
	local names = palette.names[kind]
	table.insert(names, name)
	local added = #names
	index[id] = added
	palette.ids[kind][added] = id
	return added
end

--[[
	Today's id of index `index` of `kind` in a read `palette`: 0 for 0, nil for a name this version
	doesn't know, then counted in the palette's `unknown` as `count` things (default 1) left out.
	Errors on an index the palette doesn't have (a damaged save).
]]
function SaveCodec.idOf(palette: Palette, kind: PaletteKind, index: number, count: number?): number?
	if index == 0 then
		return 0
	end
	local id = palette.ids[kind][index]
	if id == nil then
		error("bad palette index in save", 0)
	elseif type(id) == "number" then
		return id
	end
	local name = palette.names[kind][index]
	palette.unknown[name] = (palette.unknown[name] or 0) + (count or 1)
	return nil
end

--[[
	The index container data's id `id` (one of `kind`'s) at data index `at` is written as
	(`indexOf`), in a container whose block is index `block` in `palette`: noted in the palette's
	`fields`, so the reader knows that number is an index (see the header's Ids in data).
]]
function SaveCodec.fieldIndex(palette: Palette, block: number, at: number, kind: PaletteKind, id: number): number
	if block > 0 then
		local fields = palette.fields[block]
		if fields == nil then
			fields = {}
			palette.fields[block] = fields
		end
		fields[at] = kind
	end
	return SaveCodec.indexOf(palette, kind, id)
end

--[[
	The number `value` a record's data held under an id key or field, read back with its
	`palette` (see the header's Ids in data). `listed`: the kind of id the writer wrote it as
	(the palette's `keys` or `fields`; nil: a plain number); `mine`: the kind this version keeps
	there (ItemData.idKind, Machines.idFields; nil: a plain number); one of them is set. Returns
	today's id of its name, 0 for 0 (none in every version), or nil when it is left out, counted
	in the palette's `unknown`: under its name when this version doesn't know the name, else under
	`label` (the key or field) when the number can't be read: an id one version keeps there and
	the other doesn't, or of another kind, or an index the palette doesn't have. Never an error:
	an id in data never refuses a record.
]]
function SaveCodec.dataId(
	palette: Palette,
	listed: PaletteKind?,
	mine: PaletteKind?,
	value: any,
	label: string
): number?
	if value == 0 then
		return 0
	end
	if listed ~= nil and listed == mine and type(value) == "number" then
		local id = palette.ids[listed][value]
		if type(id) == "number" then
			return id
		elseif id == false then
			local name = palette.names[listed][value]
			palette.unknown[name] = (palette.unknown[name] or 0) + 1
			return nil
		end
	end
	palette.unknown[label] = (palette.unknown[label] or 0) + 1
	return nil
end

-- Writes `palette`: the writer's place version, its names (for each of PALETTE_KINDS: varint n,
-- then n texts), then the ids in data: its `keys` and its `fields` (see the header).
function SaveCodec.writePalette(w: Writer, palette: Palette)
	SaveCodec.varint(w, placeOf(palette.place))
	for _, kind in SaveCodec.PALETTE_KINDS do
		local names = palette.names[kind]
		SaveCodec.varint(w, #names)
		for _, name in names do
			SaveCodec.text(w, name)
		end
	end
	-- (In order: the same record always writes alike.)
	local keys: { string } = {}
	for key in palette.keys do
		table.insert(keys, key)
	end
	table.sort(keys)
	SaveCodec.varint(w, #keys)
	for _, key in keys do
		SaveCodec.text(w, key)
		SaveCodec.u8(w, KIND_CODE[palette.keys[key]])
	end
	local blocks: { number } = {}
	for block in palette.fields do
		table.insert(blocks, block)
	end
	table.sort(blocks)
	SaveCodec.varint(w, #blocks)
	for _, block in blocks do
		local fields = palette.fields[block]
		local indices: { number } = {}
		for at in fields do
			table.insert(indices, at)
		end
		table.sort(indices)
		SaveCodec.varint(w, block)
		SaveCodec.u8(w, #indices)
		for _, at in indices do
			SaveCodec.u8(w, at)
			SaveCodec.u8(w, KIND_CODE[fields[at]])
		end
	end
end

-- A kind as `writePalette` wrote it (its place in PALETTE_KINDS); anything else is damage.
local function readKind(r: Reader): PaletteKind
	local kind = SaveCodec.PALETTE_KINDS[SaveCodec.readU8(r)]
	if kind == nil then
		error("bad palette in save", 0)
	end
	return kind
end

-- A palette `writePalette` wrote, each name mapped to today's id (false: none by that name).
function SaveCodec.readPalette(r: Reader): Palette
	local palette = SaveCodec.palette(SaveCodec.readVarint(r))
	for _, kind in SaveCodec.PALETTE_KINDS do
		local names, index, ids = palette.names[kind], palette.index[kind], palette.ids[kind]
		for i = 1, SaveCodec.readVarint(r) do
			local name = SaveCodec.readText(r)
			names[i] = name
			local id = findId(kind, name)
			ids[i] = if id then id else false
			if id and index[id] == nil then
				index[id] = i
			end
		end
	end
	for _ = 1, SaveCodec.readVarint(r) do
		local key = SaveCodec.readText(r)
		palette.keys[key] = readKind(r)
	end
	local blocks = #palette.names.block
	for _ = 1, SaveCodec.readVarint(r) do
		local block = SaveCodec.readVarint(r)
		if block < 1 or block > blocks or palette.fields[block] then
			error("bad palette in save", 0)
		end
		local fields: { [number]: PaletteKind } = {}
		palette.fields[block] = fields
		for _ = 1, SaveCodec.readU8(r) do
			local at = SaveCodec.readU8(r)
			fields[at] = readKind(r)
		end
	end
	return palette
end

--[[ Unknown names: content since removed, or a newer version's ]]

--[[
	Whether the names a record left out may be content this version lacks, so this server must
	never write the record back this session: it left something out (`dropped` > 0) and was
	written by place version `writer` that is newer than this server's (`mine`), or either is
	unknown (0, nil: Studio). Otherwise (`dropped` 0, or written by this place version or an older
	one) the names are content since removed and the record saves as any other.
]]
function SaveCodec.newerNames(dropped: number, writer: number?, mine: number?): boolean
	if dropped <= 0 then
		return false
	end
	local written, running = placeOf(writer), placeOf(mine)
	return written == 0 or running == 0 or written > running
end

-- Most names a notice lists.
SaveCodec.NOTICE_NAMES = 10

-- `counts` (name -> things left out) as a list, the most first: "12 OldBlock, 3 OldItem".
function SaveCodec.countList(counts: { [string]: number }): string
	local names: { string } = {}
	for name in counts do
		table.insert(names, name)
	end
	table.sort(names, function(a: string, b: string): boolean
		if counts[a] ~= counts[b] then
			return counts[a] > counts[b]
		end
		return a < b
	end)
	local parts: { string } = {}
	for i = 1, math.min(#names, SaveCodec.NOTICE_NAMES) do
		table.insert(parts, `{counts[names[i]]} {names[i]}`)
	end
	if #names > SaveCodec.NOTICE_NAMES then
		table.insert(parts, `and {#names - SaveCodec.NOTICE_NAMES} more`)
	end
	return table.concat(parts, ", ")
end

-- The server's output line for content since removed that a load left out of `what` (`world
-- "Island"`, a player's things): "[IceVoxel] removed content left out of ...: 12 OldBlock,
-- 3 OldItem".
function SaveCodec.removedNotice(what: string, counts: { [string]: number }): string
	return `[IceVoxel] removed content left out of {what}: {SaveCodec.countList(counts)}`
end

-- Adds `from`'s counts to `into`'s.
function SaveCodec.addCounts(into: { [string]: number }, from: { [string]: number })
	for name, count in from do
		into[name] = (into[name] or 0) + count
	end
end

--[[ Stacks ]]

--[[
	`data` with the numbers under id keys (ItemData) as `palette` indices, each such key noted in
	the palette's `keys`: the same table when it has none; a key whose number is no id of its kind
	is left out. (Keys in order: the same data always adds its names alike.)
]]
local function savedData(data: Items.Data?, palette: Palette): Items.Data?
	if data == nil then
		return nil
	end
	local keys: { string }? = nil
	local kinds: { [string]: string } = {}
	for key in next, data do
		local kind = ItemData.idKind(key)
		if kind then
			local list = keys or {}
			keys = list
			table.insert(list, key)
			kinds[key] = kind
		end
	end
	if keys == nil then
		return data
	end
	table.sort(keys)
	local out: Items.Data = table.clone(data)
	for _, key in keys do
		local value = data[key]
		local index = if type(value) == "number" then SaveCodec.indexOf(palette, kinds[key], value) else 0
		if index > 0 or value == 0 then
			out[key] = index :: any
			palette.keys[key] = kinds[key]
		else
			-- (No id: the key goes.)
			out[key] = nil
		end
	end
	return out
end

--[[
	Data `savedData` wrote, its id keys today's ids again (`dataId`: the writer's `keys` and this
	version's id keys), and whether one was left out: a name this version doesn't know, or a
	number that can't be read (counted under "<key> (item data)").
]]
local function loadedData(data: Items.Data?, palette: Palette): (Items.Data?, boolean)
	if data == nil then
		return nil, false
	end
	local out: Items.Data? = nil
	local lost = false
	for key, value in next, data do
		local listed, mine = palette.keys[key], ItemData.idKind(key)
		if listed or mine then
			local copy: Items.Data = out or table.clone(data)
			out = copy
			local id = SaveCodec.dataId(palette, listed, mine, value, `{key} (item data)`)
			-- (Left out: the key goes.)
			copy[key] = id :: any
			if id == nil then
				lost = true
			end
		end
	end
	if out == nil then
		return data, false
	end
	return Items.cleanData(out), lost
end

-- Writes `stack` (nil or an empty one: item 0), its item and the ids in its data by `palette`.
function SaveCodec.stack(w: Writer, stack: Stack?, palette: Palette)
	if stack == nil or stack.count < 1 or not Items.isValid(stack.item) then
		SaveCodec.varint(w, 0)
		return
	end
	SaveCodec.varint(w, SaveCodec.indexOf(palette, "item", stack.item))
	SaveCodec.varint(w, math.clamp(math.floor(stack.count), 1, 255))
	SaveCodec.varint(w, math.clamp(Items.cleanDamage(stack.damage) or 0, 0, 65535))
	local data = savedData(stack.data, palette)
	local size = Protocol.dataSize(data)
	ensure(w, size)
	w.n = Protocol.writeData(w.b, w.n, data)
end

--[[
	A stack written by `stack` with the record's `palette`: nil for empty; nil and `lost` true for
	an item this version doesn't know; the stack and `lost` true when an id in its data was one
	(that key left out). Third: how many items over today's maxStack were cut off it (0 none; the
	caller gives them back, `extraStacks` and `giveBack`, or counts them left out).
]]
function SaveCodec.readStack(r: Reader, palette: Palette): (Stack?, boolean, number)
	local index = SaveCodec.readVarint(r)
	if index == 0 then
		return nil, false, 0
	end
	local count = SaveCodec.readVarint(r)
	local damage = SaveCodec.readVarint(r)
	local ok, saved, after = Protocol.readData(r.b, r.o, r.len)
	if not ok then
		error("bad item data in save", 0)
	end
	r.o = after
	local item = SaveCodec.idOf(palette, "item", index)
	local data, lostData = loadedData(saved, palette)
	if item == nil or not Items.isValid(item) or count < 1 or count > 255 then
		return nil, true, 0
	end
	-- (Today's maxStack: another version's may be more, or this one's went down since.)
	local most = Items.maxStack(item)
	local stack = Items.newStack(item, math.min(count, most), if damage > 0 then damage else nil, data)
	return stack, stack == nil or lostData, math.max(0, count - most)
end

-- `extra` more of `stack` (its item, wear and data) as stacks of at most its maxStack each.
function SaveCodec.extraStacks(stack: Stack, extra: number): { Stack }
	local out: { Stack } = {}
	local most = Items.maxStack(stack.item)
	local left = extra
	while left > 0 do
		local count = math.min(left, most)
		table.insert(out, Items.newStack(stack.item, count, stack.damage, stack.data) :: Stack)
		left -= count
	end
	return out
end

--[[
	Gives back the `extra` items `readStack` cut off `stack` (over today's maxStack), as
	`extraStacks`, into the empty slots of `store` 1..`size` (a place that takes anything: an
	inventory's 36 slots, a chest; nil: nowhere). What finds no room is left out, counted in
	`palette`'s `unknown` under the item's name; returns whether something was (the caller counts
	it in its `dropped`, so the newer-version rule holds: a newer version's bigger stack is never
	cut and written back).
]]
function SaveCodec.giveBack(
	palette: Palette,
	stack: Stack,
	extra: number,
	store: { [number]: Stack? }?,
	size: number?
): boolean
	if extra <= 0 then
		return false
	end
	local left = 0
	local slot = 1
	for _, more in SaveCodec.extraStacks(stack, extra) do
		if store then
			while slot <= (size or 0) and store[slot] ~= nil do
				slot += 1
			end
		end
		if store and slot <= (size or 0) then
			store[slot] = more
		else
			left += more.count
		end
	end
	if left > 0 then
		local name = (Items.get(stack.item) :: Items.ItemDef).name
		palette.unknown[name] = (palette.unknown[name] or 0) + left
		return true
	end
	return false
end

--[[ Text (base85) ]]

-- `count` bytes of `source` from `from` (all by default) as base85 text.
function SaveCodec.toText(source: buffer, from: number?, count: number?): string
	local start = from or 0
	local length = count or (buffer.len(source) - start)
	local full = length // 4
	local rest = length % 4
	local out = buffer.create(full * 5 + (if rest > 0 then rest + 1 else 0))
	local digits = DIGITS
	local o = 0
	local i = start
	for _ = 1, full do
		local value = (
			(buffer.readu8(source, i) * 256 + buffer.readu8(source, i + 1)) * 256 + buffer.readu8(source, i + 2)
		)
				* 256
			+ buffer.readu8(source, i + 3)
		i += 4
		local d4 = value % 85
		value //= 85
		local d3 = value % 85
		value //= 85
		local d2 = value % 85
		value //= 85
		local d1 = value % 85
		local d0 = value // 85
		buffer.writeu8(out, o, digits[d0 + 1])
		buffer.writeu8(out, o + 1, digits[d1 + 1])
		buffer.writeu8(out, o + 2, digits[d2 + 1])
		buffer.writeu8(out, o + 3, digits[d3 + 1])
		buffer.writeu8(out, o + 4, digits[d4 + 1])
		o += 5
	end
	if rest > 0 then
		local value = 0
		for k = 0, 3 do
			value = value * 256 + (if k < rest then buffer.readu8(source, i + k) else 0)
		end
		local group = table.create(5, 0)
		for k = 5, 1, -1 do
			group[k] = value % 85
			value //= 85
		end
		for k = 1, rest + 1 do
			buffer.writeu8(out, o, digits[group[k] + 1])
			o += 1
		end
	end
	return buffer.tostring(out)
end

-- The bytes base85 `text` holds; nil when it is no such text (a stray character, a cut group).
function SaveCodec.fromText(text: string): buffer?
	local length = #text
	local full = length // 5
	local restChars = length % 5
	if restChars == 1 then
		return nil
	end
	local rest = if restChars > 0 then restChars - 1 else 0
	local source = buffer.fromstring(text)
	local out = buffer.create(full * 4 + rest)
	local digitOf = DIGIT_OF
	local o = 0
	local i = 0
	for _ = 1, full do
		local value = 0
		for k = 0, 4 do
			local digit = digitOf[buffer.readu8(source, i + k)]
			if digit == nil then
				return nil
			end
			value = value * 85 + digit
		end
		if value > 4294967295 then
			return nil
		end
		i += 5
		buffer.writeu8(out, o, value // 16777216)
		buffer.writeu8(out, o + 1, value // 65536 % 256)
		buffer.writeu8(out, o + 2, value // 256 % 256)
		buffer.writeu8(out, o + 3, value % 256)
		o += 4
	end
	if rest > 0 then
		local value = 0
		for k = 0, 4 do
			local digit = if k < restChars then digitOf[buffer.readu8(source, i + k)] else 84
			if digit == nil then
				return nil
			end
			value = value * 85 + digit
		end
		if value > 4294967295 then
			return nil
		end
		local bytes = { value // 16777216, value // 65536 % 256, value // 256 % 256, value % 256 }
		for k = 1, rest do
			buffer.writeu8(out, o, bytes[k])
			o += 1
		end
	end
	return out
end

-- Characters of base85 text for `count` bytes.
function SaveCodec.textLength(count: number): number
	local rest = count % 4
	return (count // 4) * 5 + (if rest > 0 then rest + 1 else 0)
end

return SaveCodec
