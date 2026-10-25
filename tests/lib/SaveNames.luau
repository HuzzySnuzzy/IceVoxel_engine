--[[
	Saved records with their palette's names changed (server Save/SaveCodec: names, not ids), the
	specs' stand-in for another version's content: what an older version named otherwise (a
	RENAMED name), content it had that this one doesn't (a removed name), or the same content in
	another order (names swapped: what was saved as one name is read as today's id of another).

	  region(SaveCodec, bytes, rename, place?)
	                                    a region's bytes (Save/RegionCodec: the palette is its
	                                    first record) with every palette name `rename(kind, name)`
	                                    (the same name: unchanged), and `place` as the place
	                                    version that wrote it (default: as it was)
	  record(SaveCodec, bytes, rename, place?)
	                                    the same for a player or character record (Save/
	                                    PlayerCodec, Save/CharacterCodec: the palette follows the
	                                    version byte)
	  regionNames(SaveCodec, bytes), recordNames(SaveCodec, bytes)
	                                    their palette as read (names by kind, index order)

	SaveCodec is passed in: the module the spec required (tests/lib modules have no env require).
]]

local SaveNames = {}

type Rename = (kind: string, name: string) -> string

local function renamed(SaveCodec: any, palette: any, rename: Rename, place: number?): any
	if place then
		palette.place = place
	end
	for _, kind in SaveCodec.PALETTE_KINDS do
		local names = palette.names[kind]
		for i, name in names do
			names[i] = rename(kind, name)
		end
	end
	return palette
end

-- The rest of `r`'s bytes, from where it stands, onto `w`.
local function rest(SaveCodec: any, w: any, r: any)
	local count = r.len - r.o
	local tail = buffer.create(count)
	buffer.copy(tail, 0, r.b, r.o, count)
	SaveCodec.bytes(w, tail)
end

-- A region's header and its palette record: the reader after them, the palette and the header.
local function readRegionHead(SaveCodec: any, bytes: buffer): (any, any, { number })
	local r = SaveCodec.reader(bytes)
	local header = { SaveCodec.readU8(r), SaveCodec.readZigzag(r), SaveCodec.readZigzag(r), SaveCodec.readVarint(r) }
	local tag = SaveCodec.readU8(r)
	local length = SaveCodec.readVarint(r)
	assert(tag == 14, "a region's first record is its palette")
	local inner = SaveCodec.reader(r.b, r.o, r.o + length)
	local palette = SaveCodec.readPalette(inner)
	r.o += length
	return r, palette, header
end

function SaveNames.regionNames(SaveCodec: any, bytes: buffer): { [string]: { string } }
	local _, palette = readRegionHead(SaveCodec, bytes)
	return palette.names
end

function SaveNames.recordNames(SaveCodec: any, bytes: buffer): { [string]: { string } }
	local r = SaveCodec.reader(bytes)
	SaveCodec.readU8(r)
	return SaveCodec.readPalette(r).names
end

function SaveNames.region(SaveCodec: any, bytes: buffer, rename: Rename, place: number?): buffer
	local r, palette, header = readRegionHead(SaveCodec, bytes)
	local w = SaveCodec.writer(buffer.len(bytes) + 64)
	SaveCodec.u8(w, header[1])
	SaveCodec.zigzag(w, header[2])
	SaveCodec.zigzag(w, header[3])
	SaveCodec.varint(w, header[4])
	local body = SaveCodec.writer(256)
	SaveCodec.writePalette(body, renamed(SaveCodec, palette, rename, place))
	SaveCodec.u8(w, 14)
	SaveCodec.varint(w, body.n)
	SaveCodec.bytes(w, body.b, body.n)
	rest(SaveCodec, w, r)
	return SaveCodec.finish(w)
end

function SaveNames.record(SaveCodec: any, bytes: buffer, rename: Rename, place: number?): buffer
	local r = SaveCodec.reader(bytes)
	local version = SaveCodec.readU8(r)
	local palette = SaveCodec.readPalette(r)
	local w = SaveCodec.writer(buffer.len(bytes) + 64)
	SaveCodec.u8(w, version)
	SaveCodec.writePalette(w, renamed(SaveCodec, palette, rename, place))
	rest(SaveCodec, w, r)
	return SaveCodec.finish(w)
end

return SaveNames
