--!strict
--[[
	Network protocol.

	All traffic goes through one RemoteEvent (see Net/Remotes) as `(messageType, payload: buffer)`.
	Using one remote keeps server -> client messages strictly ordered, which the client relies on:
	a chunk's edit list and later live edits for that chunk must arrive in the order they were sent.

	Terrain itself is never sent: everyone generates it from the seed. Only edits travel.

	Client -> server
	  RequestChunks  u16 count, count x (i32 cx, i32 cz)
	  Edit           u8 action, i32 x, u16 y, i32 z, u16 block

	Server -> client
	  ChunkEdits     u16 chunkCount, per chunk: i32 cx, i32 cz, u32 count, count x (u32 localIndex, u16 block)
	  Edits          u32 count, count x (i32 x, u16 y, i32 z, u16 block)
]]

local Protocol = {}

Protocol.ClientMessage = {
	RequestChunks = 1,
	Edit = 2,
}

Protocol.ServerMessage = {
	ChunkEdits = 1,
	Edits = 2,
}

Protocol.EditAction = {
	Break = 1,
	Place = 2,
}

-- Limits enforced when decoding untrusted client data.
Protocol.MAX_CHUNKS_PER_REQUEST = 256
Protocol.EDIT_BYTES = 12

export type ChunkCoord = { number }
export type ChunkEditList = { cx: number, cz: number, edits: { [number]: number } }

--[[ Client -> server ]]

function Protocol.encodeChunkRequest(coords: { ChunkCoord }): buffer
	local b = buffer.create(2 + #coords * 8)
	buffer.writeu16(b, 0, #coords)
	for i, coord in coords do
		local o = 2 + (i - 1) * 8
		buffer.writei32(b, o, coord[1])
		buffer.writei32(b, o + 4, coord[2])
	end
	return b
end

-- Returns nil when the payload is malformed.
function Protocol.decodeChunkRequest(b: buffer): { ChunkCoord }?
	local len = buffer.len(b)
	if len < 2 then
		return nil
	end
	local count = buffer.readu16(b, 0)
	if count > Protocol.MAX_CHUNKS_PER_REQUEST or len ~= 2 + count * 8 then
		return nil
	end
	local coords = table.create(count)
	for i = 1, count do
		local o = 2 + (i - 1) * 8
		coords[i] = { buffer.readi32(b, o), buffer.readi32(b, o + 4) }
	end
	return coords
end

function Protocol.encodeEdit(action: number, x: number, y: number, z: number, block: number): buffer
	local b = buffer.create(13)
	buffer.writeu8(b, 0, action)
	buffer.writei32(b, 1, x)
	buffer.writeu16(b, 5, y)
	buffer.writei32(b, 7, z)
	buffer.writeu16(b, 11, block)
	return b
end

function Protocol.decodeEdit(b: buffer): (number?, number, number, number, number)
	if buffer.len(b) ~= 13 then
		return nil, 0, 0, 0, 0
	end
	return buffer.readu8(b, 0), buffer.readi32(b, 1), buffer.readu16(b, 5), buffer.readi32(b, 7), buffer.readu16(b, 11)
end

--[[ Server -> client ]]

function Protocol.encodeChunkEdits(lists: { ChunkEditList }): buffer
	local size = 2
	local counts = table.create(#lists, 0)
	for i, list in lists do
		local n = 0
		for _ in list.edits do
			n += 1
		end
		counts[i] = n
		size += 12 + n * 6
	end

	local b = buffer.create(size)
	buffer.writeu16(b, 0, #lists)
	local o = 2
	for i, list in lists do
		buffer.writei32(b, o, list.cx)
		buffer.writei32(b, o + 4, list.cz)
		buffer.writeu32(b, o + 8, counts[i])
		o += 12
		for index, block in list.edits do
			buffer.writeu32(b, o, index)
			buffer.writeu16(b, o + 4, block)
			o += 6
		end
	end
	return b
end

function Protocol.decodeChunkEdits(b: buffer): { ChunkEditList }
	local lists = {}
	local count = buffer.readu16(b, 0)
	local o = 2
	for _ = 1, count do
		local list: ChunkEditList = { cx = buffer.readi32(b, o), cz = buffer.readi32(b, o + 4), edits = {} }
		local n = buffer.readu32(b, o + 8)
		o += 12
		for _ = 1, n do
			list.edits[buffer.readu32(b, o)] = buffer.readu16(b, o + 4)
			o += 6
		end
		table.insert(lists, list)
	end
	return lists
end

-- `edits` is a flat array: x1, y1, z1, block1, x2, ...
function Protocol.encodeEdits(edits: { number }, first: number?, last: number?): buffer
	local from = first or 1
	local to = last or #edits
	local count = (to - from + 1) // 4
	local b = buffer.create(4 + count * Protocol.EDIT_BYTES)
	buffer.writeu32(b, 0, count)
	local o = 4
	for i = from, to, 4 do
		buffer.writei32(b, o, edits[i])
		buffer.writeu16(b, o + 4, edits[i + 1])
		buffer.writei32(b, o + 6, edits[i + 2])
		buffer.writeu16(b, o + 10, edits[i + 3])
		o += Protocol.EDIT_BYTES
	end
	return b
end

-- Calls `callback(x, y, z, block)` for every edit in the message.
function Protocol.forEachEdit(b: buffer, callback: (number, number, number, number) -> ())
	local count = buffer.readu32(b, 0)
	local o = 4
	for _ = 1, count do
		callback(buffer.readi32(b, o), buffer.readu16(b, o + 4), buffer.readi32(b, o + 6), buffer.readu16(b, o + 10))
		o += Protocol.EDIT_BYTES
	end
end

return Protocol
