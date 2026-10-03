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
	normal edit path.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Blocks = require(Shared.Blocks)
local ChunkLayout = require(Shared.World.ChunkLayout)
local Coords = require(Shared.World.Coords)
local Protocol = require(Shared.Net.Protocol)
local Remotes = require(Shared.Net.Remotes)

local SIZE = ChunkLayout.SIZE
local P = ChunkLayout.PADDED
local HEIGHT = Config.WorldHeight
local SECTION = Config.SectionHeight
local AIR = Blocks.AIR
local cullHidden = Blocks.cullLutHiddenCaves

local readu16 = buffer.readu16
local writeu16 = buffer.writeu16

export type ChunkData = {
	data: buffer,
	height: number,
	solidBelow: number,
	emptyAbove: number,
}

export type ClientWorld = {
	-- Edit lists: nil = unknown, false = requested, table = known.
	edits: { [number]: { [number]: number } | false },
	chunks: { [number]: ChunkData },
	requestQueue: { { number } },
	remote: RemoteEvent,

	-- Set by the streamer.
	onSectionDirty: (cx: number, cz: number, section: number) -> (),
	onChunkTouched: (cx: number, cz: number) -> (),

	requestEdits: (self: ClientWorld, cx: number, cz: number) -> (),
	editsKnown: (self: ClientWorld, cx: number, cz: number) -> boolean,
	forgetEditsExcept: (self: ClientWorld, keep: { [number]: boolean }) -> (),
	collectJobEdits: (self: ClientWorld, cx: number, cz: number) -> { number },
	attach: (self: ClientWorld, cx: number, cz: number, chunk: ChunkData) -> (),
	detach: (self: ClientWorld, cx: number, cz: number) -> (),
	getBlock: (self: ClientWorld, x: number, y: number, z: number) -> number?,
	isLoaded: (self: ClientWorld, x: number, z: number) -> boolean,
	applyEdit: (self: ClientWorld, x: number, y: number, z: number, block: number) -> (),
	breakBlock: (self: ClientWorld, x: number, y: number, z: number) -> (),
	placeBlock: (self: ClientWorld, x: number, y: number, z: number, block: number) -> (),
	flush: (self: ClientWorld) -> (),
}

local ClientWorld = {}
ClientWorld.__index = ClientWorld

function ClientWorld.new(): ClientWorld
	local self = (
		setmetatable({
			edits = {},
			chunks = {},
			requestQueue = {},
			remote = Remotes.net(),
			onSectionDirty = function() end,
			onChunkTouched = function() end,
		}, ClientWorld) :: any
	) :: ClientWorld

	self.remote.OnClientEvent:Connect(function(kind: number, payload: buffer)
		if kind == Protocol.ServerMessage.ChunkEdits then
			for _, list in Protocol.decodeChunkEdits(payload) do
				local key = Coords.chunkKey(list.cx, list.cz)
				-- Only accept lists we asked for (and still want).
				if self.edits[key] == false then
					self.edits[key] = list.edits
				end
			end
		elseif kind == Protocol.ServerMessage.Edits then
			Protocol.forEachEdit(payload, function(x, y, z, block)
				self:applyEdit(x, y, z, block)
			end)
		end
	end)

	return self
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
	for key, list in self.edits do
		if not keep[key] and list ~= false then
			self.edits[key] = nil
		end
	end
end

--[[
	Flat list of (padded cell index, block) pairs to apply to a freshly generated chunk: the
	chunk's own edits plus the neighbours' edits on the shared border (they live in our padding).
]]
function ClientWorld.collectJobEdits(self: ClientWorld, cx: number, cz: number): { number }
	local out: { number } = {}
	local function add(list: { [number]: number } | false | nil, filter: (lx: number, lz: number) -> (number?, number?))
		if type(list) ~= "table" then
			return
		end
		for index, block in list do
			local lx, y, lz = ChunkLayout.fromLocalIndex(index)
			local px, pz = filter(lx, lz)
			if px and pz then
				table.insert(out, (y * P + pz) * P + px)
				table.insert(out, block)
			end
		end
	end
	local edits = self.edits
	add(edits[Coords.chunkKey(cx, cz)], function(lx, lz)
		return lx + 1, lz + 1
	end)
	add(edits[Coords.chunkKey(cx - 1, cz)], function(lx, lz)
		return if lx == SIZE - 1 then 0 else nil, lz + 1
	end)
	add(edits[Coords.chunkKey(cx + 1, cz)], function(lx, lz)
		return if lx == 0 then P - 1 else nil, lz + 1
	end)
	add(edits[Coords.chunkKey(cx, cz - 1)], function(lx, lz)
		return lx + 1, if lz == SIZE - 1 then 0 else nil
	end)
	add(edits[Coords.chunkKey(cx, cz + 1)], function(lx, lz)
		return lx + 1, if lz == 0 then P - 1 else nil
	end)
	return out
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
		self.remote:FireServer(Protocol.ClientMessage.RequestChunks, Protocol.encodeChunkRequest(coords))
	end
	self.requestQueue = {}
end

--[[ Loaded chunk data ]]

function ClientWorld.attach(self: ClientWorld, cx: number, cz: number, chunk: ChunkData)
	self.chunks[Coords.chunkKey(cx, cz)] = chunk
end

function ClientWorld.detach(self: ClientWorld, cx: number, cz: number)
	self.chunks[Coords.chunkKey(cx, cz)] = nil
end

function ClientWorld.getBlock(self: ClientWorld, x: number, y: number, z: number): number?
	if y < 0 or y >= HEIGHT then
		return if y < 0 then Blocks.id.Bedrock else AIR
	end
	local cx, cz = x // SIZE, z // SIZE
	local chunk = self.chunks[Coords.chunkKey(cx, cz)]
	if chunk == nil then
		return nil
	end
	return readu16(chunk.data, ((y * P + z - cz * SIZE + 1) * P + x - cx * SIZE + 1) * 2)
end

function ClientWorld.isLoaded(self: ClientWorld, x: number, z: number): boolean
	return self.chunks[Coords.chunkKey(x // SIZE, z // SIZE)] ~= nil
end

--[[ Edits ]]

-- Writes a cell (padded coordinates) of a loaded chunk; returns true if it changed.
local function writeCell(
	self: ClientWorld,
	cx: number,
	cz: number,
	px: number,
	y: number,
	pz: number,
	block: number
): boolean
	local chunk = self.chunks[Coords.chunkKey(cx, cz)]
	if chunk == nil then
		return false
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

-- Applies an edit from any source (server or prediction).
function ClientWorld.applyEdit(self: ClientWorld, x: number, y: number, z: number, block: number)
	if y < 0 or y >= HEIGHT or not Blocks.isValid(block) then
		return
	end
	local cx, cz, lx, lz = Coords.blockToChunk(x, z)
	local list = self.edits[Coords.chunkKey(cx, cz)]
	if type(list) == "table" then
		list[ChunkLayout.localIndex(lx, y, lz)] = block
	end

	local section = y // SECTION
	if writeCell(self, cx, cz, lx, y, lz, block) then
		self.onSectionDirty(cx, cz, section)
		-- The block above / below in the neighbouring section can change visibility too.
		if y % SECTION == 0 and section > 0 then
			self.onSectionDirty(cx, cz, section - 1)
		elseif y % SECTION == SECTION - 1 and y + 1 < HEIGHT then
			self.onSectionDirty(cx, cz, section + 1)
		end
	end
	self.onChunkTouched(cx, cz)

	-- Border blocks also live in the neighbour's padding.
	local function neighbour(ncx: number, ncz: number, px: number, pz: number)
		if writeCell(self, ncx, ncz, px, y, pz, block) then
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
end

function ClientWorld.breakBlock(self: ClientWorld, x: number, y: number, z: number)
	ClientWorld.applyEdit(self, x, y, z, AIR)
	self.remote:FireServer(Protocol.ClientMessage.Edit, Protocol.encodeEdit(Protocol.EditAction.Break, x, y, z, AIR))
end

function ClientWorld.placeBlock(self: ClientWorld, x: number, y: number, z: number, block: number)
	ClientWorld.applyEdit(self, x, y, z, block)
	self.remote:FireServer(Protocol.ClientMessage.Edit, Protocol.encodeEdit(Protocol.EditAction.Place, x, y, z, block))
end

return ClientWorld
