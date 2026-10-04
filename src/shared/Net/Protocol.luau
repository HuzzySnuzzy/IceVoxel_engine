--!strict
--[[
	Network protocol.

	All traffic goes through one RemoteEvent (see Net/Remotes) as `(messageType, payload: buffer)`.
	Using one remote keeps server -> client messages strictly ordered, which the client relies on:
	a chunk's edit list and later live edits for that chunk must arrive in the order they were sent.

	Terrain itself is never sent: everyone generates it from the seed. Only edits travel.

	Client -> server
	  RequestChunks  u16 count, count x (i32 cx, i32 cz)
	  Edit           u8 action, i32 x, u16 y, i32 z, u16 block, u32 seq (the inventory action
	                 number of a placement, see Inventory below; 0 for breaking)
	  Teleport       i32 x, i32 z
	  SaveWaypoints  waypoint list (below)
	  Fall           f32 fall distance (blocks) of a landing, for fall damage
	  Mine           u8 started (1 started mining the block, 0 stopped), i32 x, u16 y, i32 z
	  Inventory      u32 seq, u8 kind, then by kind (Inventory/Types Action):
	                   1 click     u8 window, i16 slot, u8 clickType, u8 button
	                   2 drag      u8 window, u8 mode, u8 count, count x u16 slot
	                   3 select    u8 slot (1..9)
	                   4 drop      u8 all (0 / 1)
	                   5 creative  u8 window, i16 slot (-1 = cursor), u16 item, u8 count
	                   6 close     u8 window
	  Use            i32 x, u16 y, i32 z: right click on a usable block (opens a chest)

	Server -> client
	  ChunkEdits     u16 chunkCount, per chunk: i32 cx, i32 cz, u32 count, count x (u32 localIndex, u16 block)
	  Edits          u32 count, count x (i32 x, u16 y, i32 z, u16 block)
	  Waypoints      waypoint list (below)
	  Inventory      the player's inventory after their action `ack`: u32 ack, u8 selected,
	                 4 armor + 36 inventory + 1 cursor stacks, u8 window, u16 containerBlock,
	                 u8 containerSize, containerSize stacks. A stack is u16 item, u8 count (0 = empty).
	  Entities       u16 count, count x entity update (u8 op, u32 id, then by op):
	                   1 spawn   u16 item, u8 count, f32 x, y, z, vx, vy, vz (blocks, per tick), u16 age (ticks)
	                   2 sync    f32 x, y, z, vx, vy, vz
	                   3 count   u8 count
	                   4 remove  f64 collector (UserId of the player who picked it up, 0 = none)
	  Notice         u16 length, text: a message for the player (shown in the chat)

	Waypoint list: u32 revision, u8 count, count x (i32 x, i32 y, i32 z, u8 r, u8 g, u8 b, u8 nameLength, name)
	  The client numbers its changes (revision); the server echoes the revision it answers (0 = the
	  list loaded on join), so neither side ever applies an older list over a newer one.
]]

local InventoryTypes = require(script.Parent.Parent.Inventory.Types)

local Protocol = {}

Protocol.ClientMessage = {
	RequestChunks = 1,
	Edit = 2,
	Teleport = 3,
	SaveWaypoints = 4,
	Fall = 5,
	Mine = 6,
	Inventory = 7,
	Use = 8,
}

Protocol.ServerMessage = {
	ChunkEdits = 1,
	Edits = 2,
	Waypoints = 3,
	Inventory = 4,
	Entities = 5,
	Notice = 6,
}

Protocol.EditAction = {
	Break = 1,
	Place = 2,
}

-- Limits enforced when decoding untrusted client data.
Protocol.MAX_CHUNKS_PER_REQUEST = 256
Protocol.EDIT_BYTES = 12
Protocol.MAX_WAYPOINTS = 64
Protocol.MAX_WAYPOINT_NAME = 32
-- Edits and teleports outside this many blocks from the origin are rejected.
Protocol.MAX_COORDINATE = 1000000

export type Waypoint = {
	name: string,
	x: number,
	y: number,
	z: number,
	color: { number },
}

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

function Protocol.encodeEdit(action: number, x: number, y: number, z: number, block: number, seq: number?): buffer
	local b = buffer.create(17)
	buffer.writeu8(b, 0, action)
	buffer.writei32(b, 1, x)
	buffer.writeu16(b, 5, y)
	buffer.writei32(b, 7, z)
	buffer.writeu16(b, 11, block)
	buffer.writeu32(b, 13, seq or 0)
	return b
end

-- action (nil when malformed), x, y, z, block, seq.
function Protocol.decodeEdit(b: buffer): (number?, number, number, number, number, number)
	if buffer.len(b) ~= 17 then
		return nil, 0, 0, 0, 0, 0
	end
	return buffer.readu8(b, 0),
		buffer.readi32(b, 1),
		buffer.readu16(b, 5),
		buffer.readi32(b, 7),
		buffer.readu16(b, 11),
		buffer.readu32(b, 13)
end

--[[ Mining and using blocks ]]

function Protocol.encodeMine(started: boolean, x: number, y: number, z: number): buffer
	local b = buffer.create(11)
	buffer.writeu8(b, 0, if started then 1 else 0)
	buffer.writei32(b, 1, x)
	buffer.writeu16(b, 5, y)
	buffer.writei32(b, 7, z)
	return b
end

-- started (nil when malformed), x, y, z.
function Protocol.decodeMine(b: buffer): (boolean?, number, number, number)
	if buffer.len(b) ~= 11 then
		return nil, 0, 0, 0
	end
	local flag = buffer.readu8(b, 0)
	if flag > 1 then
		return nil, 0, 0, 0
	end
	return flag == 1, buffer.readi32(b, 1), buffer.readu16(b, 5), buffer.readi32(b, 7)
end

function Protocol.encodeUse(x: number, y: number, z: number): buffer
	local b = buffer.create(10)
	buffer.writei32(b, 0, x)
	buffer.writeu16(b, 4, y)
	buffer.writei32(b, 6, z)
	return b
end

-- x (nil when malformed), y, z.
function Protocol.decodeUse(b: buffer): (number?, number, number)
	if buffer.len(b) ~= 10 then
		return nil, 0, 0
	end
	return buffer.readi32(b, 0), buffer.readu16(b, 4), buffer.readi32(b, 6)
end

--[[ Inventory actions (client -> server) ]]

local ACTION_CLICK, ACTION_DRAG, ACTION_SELECT, ACTION_DROP, ACTION_CREATIVE, ACTION_CLOSE = 1, 2, 3, 4, 5, 6

-- Encodes inventory action number `seq`. `place` actions travel inside Edit messages instead.
function Protocol.encodeInventoryAction(seq: number, action: InventoryTypes.Action): buffer
	local b
	if action.kind == "click" then
		b = buffer.create(10)
		buffer.writeu8(b, 4, ACTION_CLICK)
		buffer.writeu8(b, 5, action.window)
		buffer.writei16(b, 6, action.slot)
		buffer.writeu8(b, 8, action.clickType)
		buffer.writeu8(b, 9, action.button)
	elseif action.kind == "drag" then
		local count = math.min(#action.slots, InventoryTypes.MAX_DRAG)
		b = buffer.create(8 + count * 2)
		buffer.writeu8(b, 4, ACTION_DRAG)
		buffer.writeu8(b, 5, action.window)
		buffer.writeu8(b, 6, action.mode)
		buffer.writeu8(b, 7, count)
		for i = 1, count do
			buffer.writeu16(b, 8 + (i - 1) * 2, action.slots[i])
		end
	elseif action.kind == "select" then
		b = buffer.create(6)
		buffer.writeu8(b, 4, ACTION_SELECT)
		buffer.writeu8(b, 5, action.slot)
	elseif action.kind == "drop" then
		b = buffer.create(6)
		buffer.writeu8(b, 4, ACTION_DROP)
		buffer.writeu8(b, 5, if action.all then 1 else 0)
	elseif action.kind == "creative" then
		b = buffer.create(11)
		buffer.writeu8(b, 4, ACTION_CREATIVE)
		buffer.writeu8(b, 5, action.window)
		buffer.writei16(b, 6, action.slot)
		buffer.writeu16(b, 8, action.item)
		buffer.writeu8(b, 10, action.count)
	elseif action.kind == "close" then
		b = buffer.create(6)
		buffer.writeu8(b, 4, ACTION_CLOSE)
		buffer.writeu8(b, 5, action.window)
	else
		error(`Inventory action {action.kind} is not sent on its own`)
	end
	buffer.writeu32(b, 0, seq)
	return b
end

--[[
	seq and action, or nil when the payload is malformed. Only the shape is checked here; whether
	the action is allowed (slot numbers, items, game mode) is up to Inventory/Menu and the server.
]]
function Protocol.decodeInventoryAction(b: buffer): (number?, InventoryTypes.Action?)
	local len = buffer.len(b)
	if len < 6 then
		return nil, nil
	end
	local seq = buffer.readu32(b, 0)
	local kind = buffer.readu8(b, 4)
	if kind == ACTION_CLICK and len == 10 then
		return seq,
			{
				kind = "click",
				window = buffer.readu8(b, 5),
				slot = buffer.readi16(b, 6),
				clickType = buffer.readu8(b, 8),
				button = buffer.readu8(b, 9),
			}
	elseif kind == ACTION_DRAG and len >= 8 then
		local count = buffer.readu8(b, 7)
		if count > InventoryTypes.MAX_DRAG or len ~= 8 + count * 2 then
			return nil, nil
		end
		local slots = table.create(count)
		for i = 1, count do
			slots[i] = buffer.readu16(b, 8 + (i - 1) * 2)
		end
		return seq, { kind = "drag", window = buffer.readu8(b, 5), mode = buffer.readu8(b, 6), slots = slots }
	elseif kind == ACTION_SELECT and len == 6 then
		return seq, { kind = "select", slot = buffer.readu8(b, 5) }
	elseif kind == ACTION_DROP and len == 6 then
		return seq, { kind = "drop", all = buffer.readu8(b, 5) ~= 0 }
	elseif kind == ACTION_CREATIVE and len == 11 then
		return seq,
			{
				kind = "creative",
				window = buffer.readu8(b, 5),
				slot = buffer.readi16(b, 6),
				item = buffer.readu16(b, 8),
				count = buffer.readu8(b, 10),
			}
	elseif kind == ACTION_CLOSE and len == 6 then
		return seq, { kind = "close", window = buffer.readu8(b, 5) }
	end
	return nil, nil
end

--[[ Inventory snapshot (server -> client) ]]

local function writeStack(b: buffer, o: number, stack: InventoryTypes.Stack?): number
	if stack and stack.count > 0 then
		buffer.writeu16(b, o, stack.item)
		buffer.writeu8(b, o + 2, math.min(stack.count, 255))
	else
		buffer.writeu16(b, o, 0)
		buffer.writeu8(b, o + 2, 0)
	end
	return o + 3
end

local function readStack(b: buffer, o: number): InventoryTypes.Stack?
	local count = buffer.readu8(b, o + 2)
	if count == 0 then
		return nil
	end
	return { item = buffer.readu16(b, o), count = count }
end

function Protocol.encodeInventory(snapshot: InventoryTypes.Snapshot): buffer
	local container = snapshot.container
	local size = if container then container.size else 0
	local b = buffer.create(4 + 1 + 41 * 3 + 4 + size * 3)
	local inventory = snapshot.inventory
	buffer.writeu32(b, 0, snapshot.ack)
	buffer.writeu8(b, 4, inventory.selected)
	local o = 5
	for slot = 1, InventoryTypes.ARMOR_SIZE do
		o = writeStack(b, o, inventory.armor[slot])
	end
	for slot = 1, InventoryTypes.INVENTORY_SIZE do
		o = writeStack(b, o, inventory.slots[slot])
	end
	o = writeStack(b, o, inventory.cursor)
	buffer.writeu8(b, o, snapshot.window)
	buffer.writeu16(b, o + 1, if container then container.block else 0)
	buffer.writeu8(b, o + 3, size)
	o += 4
	if container then
		for slot = 1, size do
			o = writeStack(b, o, container.slots[slot])
		end
	end
	return b
end

function Protocol.decodeInventory(b: buffer): InventoryTypes.Snapshot
	local inventory = InventoryTypes.newInventory()
	inventory.selected = buffer.readu8(b, 4)
	local o = 5
	for slot = 1, InventoryTypes.ARMOR_SIZE do
		inventory.armor[slot] = readStack(b, o)
		o += 3
	end
	for slot = 1, InventoryTypes.INVENTORY_SIZE do
		inventory.slots[slot] = readStack(b, o)
		o += 3
	end
	inventory.cursor = readStack(b, o)
	o += 3
	local window = buffer.readu8(b, o)
	local block = buffer.readu16(b, o + 1)
	local size = buffer.readu8(b, o + 3)
	o += 4
	local container: InventoryTypes.Container? = nil
	if size > 0 then
		local slots = {}
		for slot = 1, size do
			slots[slot] = readStack(b, o)
			o += 3
		end
		container = { block = block, size = size, slots = slots }
	end
	return { ack = buffer.readu32(b, 0), inventory = inventory, window = window, container = container }
end

--[[ Entities (server -> client) ]]

export type EntityOp =
	{
		op: "spawn",
		id: number,
		item: number,
		count: number,
		x: number,
		y: number,
		z: number,
		vx: number,
		vy: number,
		vz: number,
		age: number,
	}
	| { op: "sync", id: number, x: number, y: number, z: number, vx: number, vy: number, vz: number }
	| { op: "count", id: number, count: number }
	| { op: "remove", id: number, collector: number }

local OP_SPAWN, OP_SYNC, OP_COUNT, OP_REMOVE = 1, 2, 3, 4
local OP_SIZE = { [OP_SPAWN] = 5 + 3 + 24 + 2, [OP_SYNC] = 5 + 24, [OP_COUNT] = 5 + 1, [OP_REMOVE] = 5 + 8 }
local OP_CODE = { spawn = OP_SPAWN, sync = OP_SYNC, count = OP_COUNT, remove = OP_REMOVE }

function Protocol.encodeEntities(ops: { EntityOp }): buffer
	local size = 2
	for _, op in ops do
		size += OP_SIZE[OP_CODE[op.op]]
	end
	local b = buffer.create(size)
	buffer.writeu16(b, 0, #ops)
	local o = 2
	for _, op in ops do
		buffer.writeu8(b, o, OP_CODE[op.op])
		buffer.writeu32(b, o + 1, op.id)
		o += 5
		if op.op == "spawn" then
			buffer.writeu16(b, o, op.item)
			buffer.writeu8(b, o + 2, op.count)
			o += 3
		end
		if op.op == "spawn" or op.op == "sync" then
			buffer.writef32(b, o, op.x)
			buffer.writef32(b, o + 4, op.y)
			buffer.writef32(b, o + 8, op.z)
			buffer.writef32(b, o + 12, op.vx)
			buffer.writef32(b, o + 16, op.vy)
			buffer.writef32(b, o + 20, op.vz)
			o += 24
		end
		if op.op == "spawn" then
			buffer.writeu16(b, o, math.clamp(op.age, 0, 65535))
			o += 2
		elseif op.op == "count" then
			buffer.writeu8(b, o, op.count)
			o += 1
		elseif op.op == "remove" then
			buffer.writef64(b, o, op.collector)
			o += 8
		end
	end
	return b
end

function Protocol.decodeEntities(b: buffer): { EntityOp }
	local ops: { EntityOp } = {}
	local count = buffer.readu16(b, 0)
	local o = 2
	for _ = 1, count do
		local code = buffer.readu8(b, o)
		local id = buffer.readu32(b, o + 1)
		o += 5
		if code == OP_SPAWN then
			table.insert(ops, {
				op = "spawn",
				id = id,
				item = buffer.readu16(b, o),
				count = buffer.readu8(b, o + 2),
				x = buffer.readf32(b, o + 3),
				y = buffer.readf32(b, o + 7),
				z = buffer.readf32(b, o + 11),
				vx = buffer.readf32(b, o + 15),
				vy = buffer.readf32(b, o + 19),
				vz = buffer.readf32(b, o + 23),
				age = buffer.readu16(b, o + 27),
			})
			o += 29
		elseif code == OP_SYNC then
			table.insert(ops, {
				op = "sync",
				id = id,
				x = buffer.readf32(b, o),
				y = buffer.readf32(b, o + 4),
				z = buffer.readf32(b, o + 8),
				vx = buffer.readf32(b, o + 12),
				vy = buffer.readf32(b, o + 16),
				vz = buffer.readf32(b, o + 20),
			})
			o += 24
		elseif code == OP_COUNT then
			table.insert(ops, { op = "count", id = id, count = buffer.readu8(b, o) })
			o += 1
		elseif code == OP_REMOVE then
			table.insert(ops, { op = "remove", id = id, collector = buffer.readf64(b, o) })
			o += 8
		else
			error(`Unknown entity op {code}`)
		end
	end
	return ops
end

--[[ Notices ]]

Protocol.MAX_NOTICE = 1000

function Protocol.encodeNotice(text: string): buffer
	local cut = string.sub(text, 1, Protocol.MAX_NOTICE)
	local b = buffer.create(2 + #cut)
	buffer.writeu16(b, 0, #cut)
	buffer.writestring(b, 2, cut)
	return b
end

function Protocol.decodeNotice(b: buffer): string
	return buffer.readstring(b, 2, buffer.readu16(b, 0))
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

--[[ Teleport ]]

function Protocol.encodeTeleport(x: number, z: number): buffer
	local b = buffer.create(8)
	buffer.writei32(b, 0, x)
	buffer.writei32(b, 4, z)
	return b
end

function Protocol.decodeTeleport(b: buffer): (number?, number)
	if buffer.len(b) ~= 8 then
		return nil, 0
	end
	local x, z = buffer.readi32(b, 0), buffer.readi32(b, 4)
	if math.abs(x) > Protocol.MAX_COORDINATE or math.abs(z) > Protocol.MAX_COORDINATE then
		return nil, 0
	end
	return x, z
end

--[[ Fall damage ]]

-- Longest fall a landing can report (blocks).
Protocol.MAX_FALL = 2048

function Protocol.encodeFall(distance: number): buffer
	local b = buffer.create(4)
	buffer.writef32(b, 0, distance)
	return b
end

-- Fall distance, or nil when the payload is malformed.
function Protocol.decodeFall(b: buffer): number?
	if buffer.len(b) ~= 4 then
		return nil
	end
	local distance = buffer.readf32(b, 0)
	if distance ~= distance or distance < 0 or distance > Protocol.MAX_FALL then
		return nil
	end
	return distance
end

--[[ Waypoints ]]

-- Cuts a name to MAX_WAYPOINT_NAME bytes without splitting a UTF-8 character.
function Protocol.truncateName(name: string): string
	local cut = Protocol.MAX_WAYPOINT_NAME
	if #name <= cut then
		return name
	end
	-- Step back while the first byte after the cut is a continuation byte (10xxxxxx).
	while cut > 0 and bit32.band(string.byte(name, cut + 1), 0xC0) == 0x80 do
		cut -= 1
	end
	return string.sub(name, 1, cut)
end

function Protocol.encodeWaypoints(list: { Waypoint }, revision: number): buffer
	local count = math.min(#list, Protocol.MAX_WAYPOINTS)
	local size = 5
	local names = table.create(count)
	for i = 1, count do
		names[i] = Protocol.truncateName(list[i].name)
		size += 16 + #names[i]
	end
	local b = buffer.create(size)
	buffer.writeu32(b, 0, revision)
	buffer.writeu8(b, 4, count)
	local o = 5
	for i = 1, count do
		local w = list[i]
		buffer.writei32(b, o, w.x)
		buffer.writei32(b, o + 4, w.y)
		buffer.writei32(b, o + 8, w.z)
		buffer.writeu8(b, o + 12, w.color[1])
		buffer.writeu8(b, o + 13, w.color[2])
		buffer.writeu8(b, o + 14, w.color[3])
		buffer.writeu8(b, o + 15, #names[i])
		buffer.writestring(b, o + 16, names[i])
		o += 16 + #names[i]
	end
	return b
end

-- Returns the list and its revision, or nil when the payload is malformed.
function Protocol.decodeWaypoints(b: buffer): ({ Waypoint }?, number)
	local len = buffer.len(b)
	if len < 5 then
		return nil, 0
	end
	local revision = buffer.readu32(b, 0)
	local count = buffer.readu8(b, 4)
	if count > Protocol.MAX_WAYPOINTS then
		return nil, 0
	end
	local list: { Waypoint } = {}
	local o = 5
	for _ = 1, count do
		if o + 16 > len then
			return nil, 0
		end
		local nameLength = buffer.readu8(b, o + 15)
		if nameLength > Protocol.MAX_WAYPOINT_NAME or o + 16 + nameLength > len then
			return nil, 0
		end
		local x, y, z = buffer.readi32(b, o), buffer.readi32(b, o + 4), buffer.readi32(b, o + 8)
		if math.abs(x) > Protocol.MAX_COORDINATE or math.abs(z) > Protocol.MAX_COORDINATE or math.abs(y) > 4096 then
			return nil, 0
		end
		table.insert(list, {
			x = x,
			y = y,
			z = z,
			color = { buffer.readu8(b, o + 12), buffer.readu8(b, o + 13), buffer.readu8(b, o + 14) },
			name = buffer.readstring(b, o + 16, nameLength),
		})
		o += 16 + nameLength
	end
	if o ~= len then
		return nil, 0
	end
	return list, revision
end

return Protocol
