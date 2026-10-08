--!strict
--[[
	The bytes of saved worlds (World/WorldSave, Save/RegionCodec, Save/PlayerCodec): a growing
	byte writer and a bounds-checked reader, the numbers they use, item stacks, and the text the
	bytes are kept as in a DataStore. Pure, so the specs run it.

	  Writer    `writer()` grows a buffer as it is written (doubling); `finish` gives the bytes
	            written. Numbers are little endian, as Net/Protocol's: u8, u16, u32, i32, f32,
	            f64, `varint` (LEB128: 7 bits a byte, low first, for whole numbers 0..2^53; a
	            block id is 1-2 bytes, a run of 16 cells 1) and `zigzag` (signed whole numbers
	            as varints: 0, -1, 1, -2 ... become 0, 1, 2, 3 ...). Texts are u16 length +
	            UTF-8 bytes.
	  Reader    `reader(b)` reads them back and errors ("truncated save", "bad varint") on
	            anything that runs past the end or is out of range; decoders run it under pcall,
	            so a damaged save is refused as a whole, never half read.
	  Stacks    u16 item, varint count (1..255), varint damage (a tool's wear, 0 new), then the
	            item data in Net/Protocol's format (Protocol.writeData / readData: Minecraft's
	            item NBT made flat, checked by Items.validData). An item this version doesn't
	            know (a save from a newer one) reads back as nil and `lost` (the decoders count
	            it: a world or player holding one is never written back, Save/WorldStore): the
	            stack is dropped, not the save.
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
local Items = require(Shared.Items)
local Protocol = require(Shared.Net.Protocol)

export type Writer = { b: buffer, n: number }
export type Reader = { b: buffer, o: number, len: number }
export type Stack = Items.Stack

local SaveCodec = {}

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

--[[ Stacks ]]

-- Writes `stack` (nil or an empty one: item 0).
function SaveCodec.stack(w: Writer, stack: Stack?)
	if stack == nil or stack.count < 1 or not Items.isValid(stack.item) then
		SaveCodec.u16(w, 0)
		return
	end
	SaveCodec.u16(w, stack.item)
	SaveCodec.varint(w, math.clamp(math.floor(stack.count), 1, 255))
	SaveCodec.varint(w, math.clamp(Items.cleanDamage(stack.damage) or 0, 0, 65535))
	local size = Protocol.dataSize(stack.data)
	ensure(w, size)
	w.n = Protocol.writeData(w.b, w.n, stack.data)
end

-- A stack written by `stack` (nil: empty, or an item this version doesn't know: then `lost` true).
function SaveCodec.readStack(r: Reader): (Stack?, boolean)
	local item = SaveCodec.readU16(r)
	if item == 0 then
		return nil, false
	end
	local count = SaveCodec.readVarint(r)
	local damage = SaveCodec.readVarint(r)
	local ok, data, after = Protocol.readData(r.b, r.o, r.len)
	if not ok then
		error("bad item data in save", 0)
	end
	r.o = after
	if not Items.isValid(item) or count < 1 or count > 255 then
		return nil, true
	end
	local stack = Items.newStack(item, count, if damage > 0 then damage else nil, data)
	return stack, stack == nil
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
