--!strict
--[[
	The client's view of the world's *state*: block data of loaded full detail chunks and the edit
	lists the server sent for them.

	Terrain is generated locally, so before a full detail chunk is generated the client asks the
	server for that chunk's edit list (and its neighbours', whose border blocks end up in the chunk's
	padding). Live edits arrive on the same remote, in order, and are applied to edit lists and to
	loaded chunk data; the streamer is told which mesh sections need rebuilding.

	Block edits made by this player are applied immediately (prediction) and sent to the server.
	If the server rejects one, it answers with the real block and the prediction is undone by the
	normal edit path. A placement carries the inventory action number of the item it uses up.

	Other modules can follow the world (Rendering/TransmitterRenderer does, for Mekanism's pipes):
	  onBlockChanged(fn)  fn(x, y, z, block, previous, predicted) after an edit changed a cell of a
	                      loaded chunk (its own cells, not a neighbour's padding); `predicted`: this
	                      player's own break or placement, which the server may still undo (with
	                      an ordinary edit back to the real block)
	  onChunkLoaded(fn)   fn(cx, cz, loaded) after a full detail chunk's data is attached (again
	                      when it is regenerated) or detached
	  onEditList(fn)      fn(cx, cz, known) after a chunk's edit list arrived or was forgotten
	  knownEdits(cx, cz)  that edit list (local index -> block, ChunkLayout.localIndex), read only
	Each `on...` returns a function that removes the listener. Listeners must not edit the world.

	`collectJobEdits` (every generation job of a full detail chunk) needs the chunk's own edits and
	its four neighbours' edits on the shared border. The border columns of each list are kept ready
	(`borders`, dropped when that list changes), so the neighbours' whole lists are not read again
	for every job. `applyJobEdits` writes such a list into chunk data on the main thread (a
	generation result that came back after an edit is kept and patched, not generated again).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Blocks = require(Shared.Blocks)
local ChunkLayout = require(Shared.World.ChunkLayout)
local Coords = require(Shared.World.Coords)
local Protocol = require(Shared.Net.Protocol)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)

local SIZE = ChunkLayout.SIZE
local P = ChunkLayout.PADDED
local HEIGHT = Config.WorldHeight
local SECTION = Config.SectionHeight
local AIR = Blocks.AIR
local cullHidden = Blocks.cullLutHiddenCaves

local readu16 = buffer.readu16
local writeu16 = buffer.writeu16
local tintLut = Blocks.tintLut

export type ChunkData = {
	-- Cropped column buffer (ChunkLayout): cells from `height` up are air. Edits above it grow
	-- the buffer, so keep a reference to this table rather than to `data`.
	data: buffer,
	height: number,
	solidBelow: number,
	emptyAbove: number,
}

-- Listeners (see the header): a cell changed, a chunk was attached / detached, an edit list
-- arrived / was forgotten.
export type BlockListener = (x: number, y: number, z: number, block: number, previous: number, predicted: boolean) -> ()
export type ChunkListener = (cx: number, cz: number, loaded: boolean) -> ()
export type EditListListener = (cx: number, cz: number, known: boolean) -> ()

-- A known edit list's border columns, as (padded index, block) pairs in the padding of the
-- neighbour that uses them: `west` (local x 0) for the chunk at -X, `east` for +X, `north` (local
-- z 0) for -Z, `south` for +Z.
type Borders = { west: { number }, east: { number }, north: { number }, south: { number } }

export type ClientWorld = {
	-- Edit lists: nil = unknown, false = requested, table = known.
	edits: { [number]: { [number]: number } | false },
	-- Border columns of known edit lists (built when first needed, dropped when a list changes).
	borders: { [number]: Borders },
	chunks: { [number]: ChunkData },
	requestQueue: { { number } },
	blockListeners: { BlockListener },
	chunkListeners: { ChunkListener },
	editListeners: { EditListListener },

	-- Set by the streamer.
	onSectionDirty: (cx: number, cz: number, section: number) -> (),
	onChunkTouched: (cx: number, cz: number) -> (),

	requestEdits: (self: ClientWorld, cx: number, cz: number) -> (),
	editsKnown: (self: ClientWorld, cx: number, cz: number) -> boolean,
	forgetEditsExcept: (self: ClientWorld, keep: { [number]: boolean }) -> (),
	collectJobEdits: (self: ClientWorld, cx: number, cz: number) -> { number },
	applyJobEdits: (chunk: ChunkData, edits: { number }) -> (),
	attach: (self: ClientWorld, cx: number, cz: number, chunk: ChunkData) -> (),
	detach: (self: ClientWorld, cx: number, cz: number) -> (),
	getBlock: (self: ClientWorld, x: number, y: number, z: number) -> number?,
	isLoaded: (self: ClientWorld, x: number, z: number) -> boolean,
	applyEdit: (self: ClientWorld, x: number, y: number, z: number, block: number) -> (),
	breakBlock: (self: ClientWorld, x: number, y: number, z: number) -> (),
	placeBlock: (self: ClientWorld, x: number, y: number, z: number, block: number, seq: number) -> (),
	flush: (self: ClientWorld) -> (),
	onBlockChanged: (self: ClientWorld, listener: BlockListener) -> () -> (),
	onChunkLoaded: (self: ClientWorld, listener: ChunkListener) -> () -> (),
	onEditList: (self: ClientWorld, listener: EditListListener) -> () -> (),
	knownEdits: (self: ClientWorld, cx: number, cz: number) -> { [number]: number }?,
}

local ClientWorld = {}
ClientWorld.__index = ClientWorld

function ClientWorld.new(): ClientWorld
	local self = (
		setmetatable({
			edits = {},
			borders = {},
			chunks = {},
			requestQueue = {},
			blockListeners = {},
			chunkListeners = {},
			editListeners = {},
			onSectionDirty = function() end,
			onChunkTouched = function() end,
		}, ClientWorld) :: any
	) :: ClientWorld

	ClientNet.on(Protocol.ServerMessage.ChunkEdits, function(payload)
		for _, list in Protocol.decodeChunkEdits(payload) do
			local key = Coords.chunkKey(list.cx, list.cz)
			-- Only accept lists we asked for (and still want).
			if self.edits[key] == false then
				self.edits[key] = list.edits
				self.borders[key] = nil
				for _, listener in table.clone(self.editListeners) do
					listener(list.cx, list.cz, true)
				end
			end
		end
	end)
	ClientNet.on(Protocol.ServerMessage.Edits, function(payload)
		Protocol.forEachEdit(payload, function(x, y, z, block)
			self:applyEdit(x, y, z, block)
		end)
	end)

	return self
end

--[[ Listeners ]]

-- Adds `listener` to `list`; the function returned takes it out again.
local function listen<T>(list: { T }, listener: T): () -> ()
	table.insert(list, listener)
	return function()
		local index = table.find(list, listener)
		if index then
			table.remove(list, index)
		end
	end
end

function ClientWorld.onBlockChanged(self: ClientWorld, listener: BlockListener): () -> ()
	return listen(self.blockListeners, listener)
end

function ClientWorld.onChunkLoaded(self: ClientWorld, listener: ChunkListener): () -> ()
	return listen(self.chunkListeners, listener)
end

function ClientWorld.onEditList(self: ClientWorld, listener: EditListListener): () -> ()
	return listen(self.editListeners, listener)
end

local function chunkLoaded(self: ClientWorld, cx: number, cz: number, loaded: boolean)
	-- (A copy: a listener may remove itself.)
	for _, listener in table.clone(self.chunkListeners) do
		listener(cx, cz, loaded)
	end
end

--[[ Edit lists ]]

function ClientWorld.requestEdits(self: ClientWorld, cx: number, cz: number)
	local key = Coords.chunkKey(cx, cz)
	if self.edits[key] == nil then
		self.edits[key] = false
		table.insert(self.requestQueue, { cx, cz })
	end
end

function ClientWorld.editsKnown(self: ClientWorld, cx: number, cz: number): boolean
	return type(self.edits[Coords.chunkKey(cx, cz)]) == "table"
end

-- Drops edit lists that are no longer needed; they will be requested again if needed later.
function ClientWorld.forgetEditsExcept(self: ClientWorld, keep: { [number]: boolean })
	local forgotten: { number }? = nil
	for key, list in self.edits do
		if not keep[key] and list ~= false then
			self.edits[key] = nil
			self.borders[key] = nil
			if #self.editListeners > 0 then
				forgotten = forgotten or {}
				table.insert(forgotten :: { number }, key)
			end
		end
	end
	if forgotten then
		for _, key in forgotten do
			local cx, cz = Coords.decodeChunkKey(key)
			for _, listener in table.clone(self.editListeners) do
				listener(cx, cz, false)
			end
		end
	end
end

-- The known edit list of chunk (cx, cz) (ChunkLayout.localIndex -> block), or nil while it is
-- unknown. Read only: the world keeps it up to date.
function ClientWorld.knownEdits(self: ClientWorld, cx: number, cz: number): { [number]: number }?
	local list = self.edits[Coords.chunkKey(cx, cz)]
	return if type(list) == "table" then list else nil
end

-- The border columns of a known edit list (see Borders), built once per version of the list.
local function bordersOf(self: ClientWorld, key: number): Borders?
	local cached = self.borders[key]
	if cached then
		return cached
	end
	local list = self.edits[key]
	if type(list) ~= "table" then
		return nil
	end
	local borders: Borders = { west = {}, east = {}, north = {}, south = {} }
	for index, block in list do
		local lx, y, lz = ChunkLayout.fromLocalIndex(index)
		if lx == 0 then
			-- In the -X neighbour's padding at px = P - 1.
			table.insert(borders.west, (y * P + lz + 1) * P + P - 1)
			table.insert(borders.west, block)
		elseif lx == SIZE - 1 then
			table.insert(borders.east, (y * P + lz + 1) * P)
			table.insert(borders.east, block)
		end
		if lz == 0 then
			table.insert(borders.north, (y * P + P - 1) * P + lx + 1)
			table.insert(borders.north, block)
		elseif lz == SIZE - 1 then
			table.insert(borders.south, (y * P) * P + lx + 1)
			table.insert(borders.south, block)
		end
	end
	self.borders[key] = borders
	return borders
end

local function append(out: { number }, pairs: { number })
	table.move(pairs, 1, #pairs, #out + 1, out)
end

--[[
	Flat list of (padded cell index, block) pairs to apply to a freshly generated chunk: the
	chunk's own edits plus the neighbours' edits on the shared border (they live in our padding).
]]
function ClientWorld.collectJobEdits(self: ClientWorld, cx: number, cz: number): { number }
	local out: { number } = {}
	local own = self.edits[Coords.chunkKey(cx, cz)]
	if type(own) == "table" then
		for index, block in own do
			local lx, y, lz = ChunkLayout.fromLocalIndex(index)
			table.insert(out, (y * P + lz + 1) * P + lx + 1)
			table.insert(out, block)
		end
	end
	local west = bordersOf(self, Coords.chunkKey(cx - 1, cz))
	if west then
		append(out, west.east)
	end
	local east = bordersOf(self, Coords.chunkKey(cx + 1, cz))
	if east then
		append(out, east.west)
	end
	local north = bordersOf(self, Coords.chunkKey(cx, cz - 1))
	if north then
		append(out, north.south)
	end
	local south = bordersOf(self, Coords.chunkKey(cx, cz + 1))
	if south then
		append(out, south.north)
	end
	return out
end

--[[
	Writes a collectJobEdits list into chunk data, as the worker does with a generation job's
	edits: grows the buffer for blocks above its crop and keeps solidBelow / emptyAbove right.
]]
function ClientWorld.applyJobEdits(chunk: ChunkData, edits: { number })
	local top = 0
	for i = 1, #edits, 2 do
		if edits[i + 1] ~= AIR then
			top = math.max(top, edits[i] // ChunkLayout.LAYER + 1)
		end
	end
	if top > chunk.height then
		local height = ChunkLayout.croppedHeight(top, 1)
		chunk.data = ChunkLayout.grow(chunk.data, height)
		chunk.height = height
	end
	local data, height = chunk.data, chunk.height
	for i = 1, #edits, 2 do
		local index, block = edits[i], edits[i + 1]
		local y = index // ChunkLayout.LAYER
		if y < height then
			writeu16(data, index * 2, block)
			if block ~= AIR and y + 1 > chunk.emptyAbove then
				chunk.emptyAbove = y + 1
			end
			if buffer.readu8(cullHidden, block) == 0 and y < chunk.solidBelow then
				chunk.solidBelow = y
			end
		end
	end
end

-- Sends queued edit list requests. Called once per frame.
function ClientWorld.flush(self: ClientWorld)
	local queue = self.requestQueue
	if #queue == 0 then
		return
	end
	local batch = Config.Streaming.DiffRequestBatch
	for first = 1, #queue, batch do
		local coords = table.move(queue, first, math.min(first + batch - 1, #queue), 1, {})
		ClientNet.send(Protocol.ClientMessage.RequestChunks, Protocol.encodeChunkRequest(coords))
	end
	self.requestQueue = {}
end

--[[ Loaded chunk data ]]

function ClientWorld.attach(self: ClientWorld, cx: number, cz: number, chunk: ChunkData)
	self.chunks[Coords.chunkKey(cx, cz)] = chunk
	chunkLoaded(self, cx, cz, true)
end

function ClientWorld.detach(self: ClientWorld, cx: number, cz: number)
	local key = Coords.chunkKey(cx, cz)
	if self.chunks[key] ~= nil then
		self.chunks[key] = nil
		chunkLoaded(self, cx, cz, false)
	end
end

function ClientWorld.getBlock(self: ClientWorld, x: number, y: number, z: number): number?
	if y < 0 or y >= HEIGHT then
		return if y < 0 then Blocks.id.Bedrock else AIR
	end
	local cx, cz = x // SIZE, z // SIZE
	local chunk = self.chunks[Coords.chunkKey(cx, cz)]
	if chunk == nil then
		return nil
	elseif y >= chunk.height then
		return AIR
	end
	return readu16(chunk.data, ((y * P + z - cz * SIZE + 1) * P + x - cx * SIZE + 1) * 2)
end

function ClientWorld.isLoaded(self: ClientWorld, x: number, z: number): boolean
	return self.chunks[Coords.chunkKey(x // SIZE, z // SIZE)] ~= nil
end

--[[ Edits ]]

--[[
	Gives a loaded chunk room up to `top` cells. The new rows' padding gets the neighbours' border
	columns: copied from loaded neighbours, and from the known edit lists of the others (above our
	old crop their generated terrain is air, so their edits are all there is), so meshing the new
	rows sees the right neighbours.
]]
local function grow(self: ClientWorld, cx: number, cz: number, chunk: ChunkData, top: number)
	local old = chunk.height
	local height = ChunkLayout.croppedHeight(top, 1)
	local data = ChunkLayout.grow(chunk.data, height)
	local function copyFrom(ncx: number, ncz: number, fromX: number?, fromZ: number?, toX: number?, toZ: number?)
		local n = self.chunks[Coords.chunkKey(ncx, ncz)]
		if n == nil then
			return
		end
		for y = old, math.min(height, n.height) - 1 do
			for i = 0, SIZE - 1 do
				local sx, sz = fromX or i, fromZ or i
				local dx, dz = toX or i, toZ or i
				local block = readu16(n.data, ((y * P + sz + 1) * P + sx + 1) * 2)
				writeu16(data, ((y * P + dz + 1) * P + dx + 1) * 2, block)
			end
		end
	end
	copyFrom(cx - 1, cz, SIZE - 1, nil, -1, nil)
	copyFrom(cx + 1, cz, 0, nil, SIZE, nil)
	copyFrom(cx, cz - 1, nil, SIZE - 1, nil, -1)
	copyFrom(cx, cz + 1, nil, 0, nil, SIZE)
	local layer = ChunkLayout.LAYER
	local edits = ClientWorld.collectJobEdits(self, cx, cz)
	for i = 1, #edits, 2 do
		local index = edits[i]
		local y = index // layer
		if y >= old and y < height then
			local cell = index % layer
			local px, pz = cell % P, cell // P
			local ncx = if px == 0 then cx - 1 elseif px == P - 1 then cx + 1 else cx
			local ncz = if pz == 0 then cz - 1 elseif pz == P - 1 then cz + 1 else cz
			if (ncx ~= cx or ncz ~= cz) and self.chunks[Coords.chunkKey(ncx, ncz)] == nil then
				writeu16(data, index * 2, edits[i + 1])
			end
		end
	end
	chunk.data, chunk.height = data, height
end

-- Writes a cell (padded coordinates) of a loaded chunk; returns true if it changed. `own` is
-- false for writes into a neighbour's padding, which never grow that chunk (it has no cells there).
local function writeCell(
	self: ClientWorld,
	cx: number,
	cz: number,
	px: number,
	y: number,
	pz: number,
	block: number,
	own: boolean
): boolean
	local chunk = self.chunks[Coords.chunkKey(cx, cz)]
	if chunk == nil then
		return false
	end
	if y >= chunk.height then
		if block == AIR or not own then
			return false
		end
		grow(self, cx, cz, chunk, y + 1)
	end
	local offset = ((y * P + pz + 1) * P + px + 1) * 2
	if readu16(chunk.data, offset) == block then
		return false
	end
	writeu16(chunk.data, offset, block)
	if block ~= AIR and y + 1 > chunk.emptyAbove then
		chunk.emptyAbove = y + 1
	end
	if buffer.readu8(cullHidden, block) == 0 and y < chunk.solidBelow then
		chunk.solidBelow = y
	end
	return true
end

-- Applies an edit (`predicted`: this player's own, not yet confirmed by the server).
local function apply(self: ClientWorld, x: number, y: number, z: number, block: number, predicted: boolean)
	if y < 0 or y >= HEIGHT or not Blocks.isValid(block) then
		return
	end
	local cx, cz, lx, lz = Coords.blockToChunk(x, z)
	local key = Coords.chunkKey(cx, cz)
	local list = self.edits[key]
	if type(list) == "table" then
		list[ChunkLayout.localIndex(lx, y, lz)] = block
		if lx == 0 or lx == SIZE - 1 or lz == 0 or lz == SIZE - 1 then
			self.borders[key] = nil
		end
	end

	local section = y // SECTION
	-- A soil's foliage colour tints the plants up to two cells above it (the top of a tall plant;
	-- GreedyMesher), which may be in the next section.
	local tintsAbove = y % SECTION == SECTION - 2 and y + 2 < HEIGHT
	-- (Read before the write, for the listeners and tints; nil when the chunk is not loaded.)
	local previous = if #self.blockListeners > 0 or tintsAbove then ClientWorld.getBlock(self, x, y, z) else nil
	local changed = writeCell(self, cx, cz, lx, y, lz, block, true)
	if changed then
		self.onSectionDirty(cx, cz, section)
		-- The block above / below in the neighbouring section can change visibility too.
		if y % SECTION == 0 and section > 0 then
			self.onSectionDirty(cx, cz, section - 1)
		elseif y % SECTION == SECTION - 1 and y + 1 < HEIGHT then
			self.onSectionDirty(cx, cz, section + 1)
		elseif tintsAbove and previous ~= nil and buffer.readu8(tintLut, previous) ~= buffer.readu8(tintLut, block) then
			self.onSectionDirty(cx, cz, section + 1)
		end
	end
	self.onChunkTouched(cx, cz)

	-- Border blocks also live in the neighbour's padding.
	local function neighbour(ncx: number, ncz: number, px: number, pz: number)
		if writeCell(self, ncx, ncz, px, y, pz, block, false) then
			self.onSectionDirty(ncx, ncz, section)
		end
		self.onChunkTouched(ncx, ncz)
	end
	if lx == 0 then
		neighbour(cx - 1, cz, SIZE, lz)
	elseif lx == SIZE - 1 then
		neighbour(cx + 1, cz, -1, lz)
	end
	if lz == 0 then
		neighbour(cx, cz - 1, lx, SIZE)
	elseif lz == SIZE - 1 then
		neighbour(cx, cz + 1, lx, -1)
	end

	-- Last, so listeners see the whole edit (neighbours' padding included).
	if changed and previous ~= nil then
		for _, listener in table.clone(self.blockListeners) do
			listener(x, y, z, block, previous, predicted)
		end
	end
end

-- Applies an edit from the server.
function ClientWorld.applyEdit(self: ClientWorld, x: number, y: number, z: number, block: number)
	apply(self, x, y, z, block, false)
end

function ClientWorld.breakBlock(self: ClientWorld, x: number, y: number, z: number)
	apply(self, x, y, z, AIR, true)
	ClientNet.send(Protocol.ClientMessage.Edit, Protocol.encodeEdit(Protocol.EditAction.Break, x, y, z, AIR))
end

-- `seq` is the number of the inventory action that uses the item up (ClientInventory.place), so
-- the server can acknowledge it even when it rejects the placement.
function ClientWorld.placeBlock(self: ClientWorld, x: number, y: number, z: number, block: number, seq: number)
	apply(self, x, y, z, block, true)
	ClientNet.send(Protocol.ClientMessage.Edit, Protocol.encodeEdit(Protocol.EditAction.Place, x, y, z, block, seq))
end

return ClientWorld
