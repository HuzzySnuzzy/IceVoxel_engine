--!strict
--[[
	IVS1, the text a structure template is kept as (Structures/Template's header has the format),
	below the blocks: its bytes (base64url, CRC-32, varints and strings), its frame round the body
	(the "IVS1:" prefix, the version, the body's length and the checksum: `open`) and what stands at
	the head of the body (`head`: the template's name, its size and its palette's block names).

	It requires nothing, so Shared/Content reads the palettes of the packs' templates with it as the
	packs load (before Blocks, which builds itself from them, exists); Template.encode and
	Template.decode build on it.

	Reading never errors: a Reader's functions raise a Failure (`fail`) that `open`, `head` and
	Template.decode turn into their message for the player.
]]

local TemplateText = {}

TemplateText.VERSION = 1
TemplateText.PREFIX = "IVS1:"
-- Longest text `open` reads (characters, whitespace included) and payload (bytes): far above
-- any real structure (a busy 48 x 48 x 48 one is ~150,000 characters), so these only stop junk.
TemplateText.MAX_TEXT = 3000000
TemplateText.MAX_PAYLOAD = 2097152

--[[ CRC-32 and base64url ]]

local CRC_TABLE: { number } = table.create(256, 0)
for i = 0, 255 do
	local c = i
	for _ = 1, 8 do
		if bit32.band(c, 1) == 1 then
			c = bit32.bxor(0xEDB88320, bit32.rshift(c, 1))
		else
			c = bit32.rshift(c, 1)
		end
	end
	CRC_TABLE[i + 1] = c
end

-- CRC-32 (IEEE 802.3, as zip and PNG) of bytes [from, to) of `b`.
function TemplateText.crc32(b: buffer, from: number, to: number): number
	local crc = 0xFFFFFFFF
	local band, bxor, rshift = bit32.band, bit32.bxor, bit32.rshift
	for i = from, to - 1 do
		crc = bxor(CRC_TABLE[band(bxor(crc, buffer.readu8(b, i)), 0xFF) + 1], rshift(crc, 8))
	end
	return bxor(crc, 0xFFFFFFFF)
end

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local ENCODE = buffer.create(64)
buffer.writestring(ENCODE, 0, ALPHABET)
-- Per byte: its 6-bit value, WHITESPACE (skipped) or INVALID.
local WHITESPACE, INVALID = 254, 255
local DECODE = buffer.create(256)
buffer.fill(DECODE, 0, INVALID)
for i = 1, 64 do
	buffer.writeu8(DECODE, string.byte(ALPHABET, i), i - 1)
end
-- Bytes `open` cuts off the end of a text: whitespace and closing quotes.
local TRAILING: { [number]: boolean } = {}
for _, c in { " ", "\t", "\n", "\r", "\v", "\f" } do
	buffer.writeu8(DECODE, string.byte(c), WHITESPACE)
	TRAILING[string.byte(c)] = true
end
for _, c in { '"', "'", "`" } do
	TRAILING[string.byte(c)] = true
end

-- The first `n` bytes of `data` in base64url without padding.
function TemplateText.base64(data: buffer, n: number?): string
	local count = n or buffer.len(data)
	local out = buffer.create((count * 4 + 2) // 3)
	local o = 0
	local i = 0
	while i + 3 <= count do
		local v = buffer.readu8(data, i) * 65536 + buffer.readu8(data, i + 1) * 256 + buffer.readu8(data, i + 2)
		buffer.writeu8(out, o, buffer.readu8(ENCODE, v // 262144))
		buffer.writeu8(out, o + 1, buffer.readu8(ENCODE, v // 4096 % 64))
		buffer.writeu8(out, o + 2, buffer.readu8(ENCODE, v // 64 % 64))
		buffer.writeu8(out, o + 3, buffer.readu8(ENCODE, v % 64))
		i += 3
		o += 4
	end
	local rest = count - i
	if rest == 1 then
		local v = buffer.readu8(data, i)
		buffer.writeu8(out, o, buffer.readu8(ENCODE, v // 4))
		buffer.writeu8(out, o + 1, buffer.readu8(ENCODE, v % 4 * 16))
	elseif rest == 2 then
		local v = buffer.readu8(data, i) * 256 + buffer.readu8(data, i + 1)
		buffer.writeu8(out, o, buffer.readu8(ENCODE, v // 1024))
		buffer.writeu8(out, o + 1, buffer.readu8(ENCODE, v // 16 % 64))
		buffer.writeu8(out, o + 2, buffer.readu8(ENCODE, v % 16 * 4))
	end
	return buffer.tostring(out)
end

--[[
	The bytes of base64url `text` from character `from` on (whitespace skipped), or nil and a
	message for a character outside the alphabet. A trailing group of 2 or 3 characters gives 1 or
	2 bytes; a lone trailing character (a cut paste) is ignored.
]]
function TemplateText.unbase64(text: string, from: number?): (buffer?, string?)
	local start = from or 1
	local out = buffer.create((#text - start + 1) * 3 // 4 + 3)
	local o = 0
	local acc, bits = 0, 0
	for i = start, #text do
		local c = string.byte(text, i)
		local v = buffer.readu8(DECODE, c)
		if v == INVALID then
			local shown = if c >= 33 and c <= 126 then string.char(c) else string.format("\\%d", c)
			return nil, `The structure data has a character that doesn't belong in it ('{shown}' at character {i})`
		elseif v ~= WHITESPACE then
			acc = acc * 64 + v
			bits += 6
			if bits >= 8 then
				bits -= 8
				local byte = acc // 2 ^ bits
				buffer.writeu8(out, o, byte)
				o += 1
				acc -= byte * 2 ^ bits
			end
		end
	end
	local result = buffer.create(o)
	buffer.copy(result, 0, out, 0, o)
	return result, nil
end

--[[ Reading ]]

-- Raised while reading with a message for the player.
export type Failure = { failure: string }

function TemplateText.fail(message: string): never
	error({ failure = message } :: Failure, 0)
end
local fail = TemplateText.fail

-- What reading raised, as the message for the player (an error of anything else: "damaged").
function TemplateText.failure(raised: any): string
	if type(raised) == "table" and type(raised.failure) == "string" then
		return raised.failure
	end
	return "The structure data is damaged"
end

-- Bytes being read: the buffer, the next byte's offset and the end (exclusive).
export type Reader = { b: buffer, o: number, len: number }

function TemplateText.readByte(r: Reader): number
	if r.o >= r.len then
		fail("The structure data ends too early")
	end
	local v = buffer.readu8(r.b, r.o)
	r.o += 1
	return v
end
local readByte = TemplateText.readByte

-- A varint of at most 5 bytes (values below 2^35).
function TemplateText.readVarint(r: Reader): number
	local value, scale = 0, 1
	for _ = 1, 5 do
		local byte = readByte(r)
		value += (byte % 128) * scale
		if byte < 128 then
			return value
		end
		scale *= 128
	end
	return fail("The structure data has a number that is too long")
end
local readVarint = TemplateText.readVarint

-- A varint count of `what`, at most `cap`.
function TemplateText.readCount(r: Reader, cap: number, what: string): number
	local n = readVarint(r)
	if n > cap then
		fail(`The structure has too many {what} ({n}, at most {cap})`)
	end
	return n
end
local readCount = TemplateText.readCount

-- A string (varint byte length, then UTF-8) of at most `cap` bytes, named `what` in messages.
function TemplateText.readString(r: Reader, cap: number, what: string): string
	local n = readVarint(r)
	if n > cap then
		fail(`The structure's {what} is too long ({n} bytes, at most {cap})`)
	elseif r.o + n > r.len then
		fail("The structure data ends too early")
	end
	local s = buffer.readstring(r.b, r.o, n)
	r.o += n
	if utf8.len(s) == nil then
		fail(`The structure's {what} is not text`)
	end
	return s
end
local readString = TemplateText.readString

--[[
	The body of IVS1 `text`, to read: a Reader at the body's first byte whose end is the checksum's
	start; or nil and a message for the player (not IVS1, from a newer version, cut, damaged, too
	long, two pasted together). Whitespace anywhere and quotes (" ' `) around the whole text are
	ignored.
]]
function TemplateText.open(text: any): (Reader?, string?)
	if type(text) ~= "string" then
		return nil, "No structure data"
	end
	if #text > TemplateText.MAX_TEXT then
		return nil, `The structure data is too long ({#text} characters, at most {TemplateText.MAX_TEXT})`
	end
	-- The prefix, after whitespace and an opening quote.
	local first, last = string.find(text, "^[%s\"'`]*IVS1:")
	if first == nil or last == nil then
		if string.find(text, "^[%s\"'`]*IVS%d+:") then
			return nil, "The structure data is from a newer version of this game"
		end
		return nil, "That is not structure data: it starts with IVS1:"
	end
	-- (A closing quote and whitespace after the data, cut by a backward scan: a pattern anchored
	-- at the end would rescan every whitespace run inside the text to its end, quadratic.)
	local stop = #text
	while stop > last and TRAILING[string.byte(text, stop)] do
		stop -= 1
	end
	local payload, problem = TemplateText.unbase64(string.sub(text, last + 1, stop))
	if payload == nil then
		return nil, problem
	end
	local len = buffer.len(payload)
	if len > TemplateText.MAX_PAYLOAD then
		return nil, "The structure data is too long"
	end
	local r: Reader = { b = payload, o = 0, len = len }
	local ok, raised = pcall(function()
		-- (Junk after the prefix usually fails here: say so plainly.)
		local headerOk, version, bodyLength = pcall(function(): (number, number)
			return readVarint(r), readVarint(r)
		end)
		if not headerOk then
			fail("The structure data is damaged or cut off")
		end
		if version > TemplateText.VERSION then
			fail(`The structure data is from a newer version of this game (format {version})`)
		elseif version ~= TemplateText.VERSION then
			fail(`That is not structure data this game knows (format {version})`)
		end
		local expected = r.o + bodyLength + 4
		if bodyLength > TemplateText.MAX_PAYLOAD then
			fail("The structure data is too long")
		elseif len < expected then
			fail(`The structure data is cut off: it has {len} of its {expected} bytes. Copy all of it`)
		elseif len > expected then
			fail("The structure data has something extra at its end (two pasted together?)")
		end
		if buffer.readu32(payload, len - 4) ~= TemplateText.crc32(payload, 0, len - 4) then
			fail("The structure data is damaged (its checksum doesn't match): copy it again")
		end
		r.len = len - 4
	end)
	if not ok then
		return nil, TemplateText.failure(raised)
	end
	return r, nil
end

-- What stands at the head of a template's body.
export type Head = {
	-- The template's name ("outpost/houses/hut").
	name: string,
	-- { x, y, z }, as written.
	size: { number },
	-- The palette: the block names its cells use, in the text's order.
	blocks: { string },
}

--[[
	The name, size and palette's block names of the template in IVS1 `text`, or nil and a message
	for the player (`open`'s, or a body that ends inside its head). Only the head is read: whether
	the rest is a good template is Template.decode's to say.
]]
function TemplateText.head(text: any): (Head?, string?)
	local r, problem = TemplateText.open(text)
	if r == nil then
		return nil, problem
	end
	local reader: Reader = r
	-- (No caps beyond the body's own length here: the decode has the format's.)
	local cap = reader.len
	local ok, result = pcall(function(): Head
		local name = readString(reader, cap, "name")
		local size = { readVarint(reader), readVarint(reader), readVarint(reader) }
		local count = readCount(reader, cap, "kinds of blocks")
		local blocks: { string } = {}
		for _ = 1, count do
			table.insert(blocks, readString(reader, cap, "block name"))
		end
		return { name = name, size = size, blocks = blocks }
	end)
	if not ok then
		return nil, TemplateText.failure(result)
	end
	return result, nil
end

return TemplateText
