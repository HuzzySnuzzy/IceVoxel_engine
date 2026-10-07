--!strict
--[[
	The server's authoritative view of the world.

	The terrain is regenerated from the seed whenever it is needed, so the only state that really
	matters is the list of edits per chunk (`edits[chunkKey][localIndex] = block`). Chunks are
	generated lazily (block updates, edit validation, players nearby) and evicted again when unused;
	their edits stay.

	Every change goes through `setBlock`, which records the edit, queues it for replication and
	calls `onChanged` (the block ticker uses that to wake up neighbouring blocks).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Blocks = require(Shared.Blocks)
local ChunkLayout = require(Shared.World.ChunkLayout)
local Coords = require(Shared.World.Coords)
local TerrainGenerator = require(Shared.Generation.TerrainGenerator)

local SIZE = ChunkLayout.SIZE
local P = ChunkLayout.PADDED
local HEIGHT = Config.WorldHeight
local AIR = Blocks.AIR

local readu16 = buffer.readu16
local writeu16 = buffer.writeu16

export type Chunk = {
	cx: number,
	cz: number,
	-- Cropped column buffer (ChunkLayout): cells from `height` up are air.
	data: buffer,
	height: number,
	lastUsed: number,
}

export type World = {
	generator: TerrainGenerator.Generator,
	chunks: { [number]: Chunk },
	chunkCount: number,
	edits: { [number]: { [number]: number } },
	-- Flat list x, y, z, block of changes not yet sent to clients.
	pending: { number },
	-- Called after every successful setBlock.
	onChanged: ((x: number, y: number, z: number, old: number, new: number) -> ())?,
	-- Called when a chunk is generated (with its edits), before anything reads it: a loaded
	-- world's block updates due there are scheduled again (World/WorldSave).
	onGenerated: ((cx: number, cz: number) -> ())?,
	clock: () -> number,

	getChunk: (self: World, cx: number, cz: number) -> Chunk,
	peekChunk: (self: World, cx: number, cz: number) -> Chunk?,
	getBlock: (self: World, x: number, y: number, z: number) -> number,
	peekBlock: (self: World, x: number, y: number, z: number) -> number?,
	setBlock: (self: World, x: number, y: number, z: number, block: number) -> boolean,
	topBlock: (self: World, x: number, z: number) -> number,
	chunkEdits: (self: World, cx: number, cz: number) -> { [number]: number }?,
	takePending: (self: World) -> { number },
	evict: (self: World, keep: (cx: number, cz: number) -> boolean, capacity: number) -> number,
}

local WorldServer = {}
WorldServer.__index = WorldServer

function WorldServer.new(generator: TerrainGenerator.Generator, clock: (() -> number)?): World
	local self = {
		generator = generator,
		chunks = {},
		chunkCount = 0,
		edits = {},
		pending = {},
		onChanged = nil,
		onGenerated = nil,
		clock = clock or os.clock,
	}
	return (setmetatable(self, WorldServer) :: any) :: World
end

-- Returns the chunk, generating it (and applying its edits) if needed.
function WorldServer.getChunk(self: World, cx: number, cz: number): Chunk
	local key = Coords.chunkKey(cx, cz)
	local chunk = self.chunks[key]
	if chunk then
		chunk.lastUsed = self.clock()
		return chunk
	end

	local result = self.generator.generate(0, cx, cz)
	local data, height = result.data, result.height
	local edits = self.edits[key]
	if edits then
		-- Edits may lie above the generated terrain's crop.
		local top = 0
		for index, block in edits do
			if block ~= AIR then
				local _, y = ChunkLayout.fromLocalIndex(index)
				top = math.max(top, y + 1)
			end
		end
		if top > height then
			height = ChunkLayout.croppedHeight(top, 1)
			data = ChunkLayout.grow(data, height)
		end
		for index, block in edits do
			local lx, y, lz = ChunkLayout.fromLocalIndex(index)
			if y < height then
				writeu16(data, ((y * P + lz + 1) * P + lx + 1) * 2, block)
			end
		end
	end

	local created: Chunk = { cx = cx, cz = cz, data = data, height = height, lastUsed = self.clock() }
	self.chunks[key] = created
	self.chunkCount += 1
	local onGenerated = self.onGenerated
	if onGenerated then
		onGenerated(cx, cz)
	end
	return created
end

-- Returns the chunk only if it is already generated.
function WorldServer.peekChunk(self: World, cx: number, cz: number): Chunk?
	return self.chunks[Coords.chunkKey(cx, cz)]
end

function WorldServer.getBlock(self: World, x: number, y: number, z: number): number
	if y < 0 then
		return Blocks.id.Bedrock
	elseif y >= HEIGHT then
		return AIR
	end
	local cx, cz = x // SIZE, z // SIZE
	local chunk = WorldServer.getChunk(self, cx, cz)
	if y >= chunk.height then
		return AIR
	end
	return readu16(chunk.data, ((y * P + z - cz * SIZE + 1) * P + x - cx * SIZE + 1) * 2)
end

-- Like getBlock, but returns nil instead of generating missing chunks.
function WorldServer.peekBlock(self: World, x: number, y: number, z: number): number?
	if y < 0 then
		return Blocks.id.Bedrock
	elseif y >= HEIGHT then
		return AIR
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

-- Changes a block. Returns false if nothing changed (same block or outside the world).
function WorldServer.setBlock(self: World, x: number, y: number, z: number, block: number): boolean
	if y < 0 or y >= HEIGHT or not Blocks.isValid(block) then
		return false
	end
	local cx, cz = x // SIZE, z // SIZE
	local lx, lz = x - cx * SIZE, z - cz * SIZE
	local chunk = WorldServer.getChunk(self, cx, cz)
	if y >= chunk.height then
		if block == AIR then
			return false
		end
		chunk.height = ChunkLayout.croppedHeight(y + 1, 1)
		chunk.data = ChunkLayout.grow(chunk.data, chunk.height)
	end
	local offset = ((y * P + lz + 1) * P + lx + 1) * 2
	local old = readu16(chunk.data, offset)
	if old == block then
		return false
	end
	writeu16(chunk.data, offset, block)

	local key = Coords.chunkKey(cx, cz)
	local edits = self.edits[key]
	if edits == nil then
		edits = {}
		self.edits[key] = edits
	end
	edits[ChunkLayout.localIndex(lx, y, lz)] = block

	local pending = self.pending
	local n = #pending
	pending[n + 1] = x
	pending[n + 2] = y
	pending[n + 3] = z
	pending[n + 4] = block

	if self.onChanged then
		self.onChanged(x, y, z, old, block)
	end
	return true
end

-- Y of the highest non-air block in a column (-1 if the column is empty).
function WorldServer.topBlock(self: World, x: number, z: number): number
	local chunk = WorldServer.getChunk(self, x // SIZE, z // SIZE)
	for y = chunk.height - 1, 0, -1 do
		local block = WorldServer.getBlock(self, x, y, z)
		if block ~= AIR and block ~= Blocks.CAVE_AIR then
			return y
		end
	end
	return -1
end

function WorldServer.chunkEdits(self: World, cx: number, cz: number): { [number]: number }?
	return self.edits[Coords.chunkKey(cx, cz)]
end

-- Returns and clears the changes made since the last call.
function WorldServer.takePending(self: World): { number }
	local pending = self.pending
	self.pending = {}
	return pending
end

-- Drops generated chunks that `keep` rejects, least recently used first, until at most
-- `capacity` of them remain. Returns the number of chunks evicted.
function WorldServer.evict(self: World, keep: (cx: number, cz: number) -> boolean, capacity: number): number
	if self.chunkCount <= capacity then
		return 0
	end
	local candidates: { { key: number, chunk: Chunk } } = {}
	for key, chunk in self.chunks do
		if not keep(chunk.cx, chunk.cz) then
			table.insert(candidates, { key = key, chunk = chunk })
		end
	end
	table.sort(candidates, function(a, b)
		return a.chunk.lastUsed < b.chunk.lastUsed
	end)
	local evicted = 0
	for _, entry in candidates do
		if self.chunkCount <= capacity then
			break
		end
		self.chunks[entry.key] = nil
		self.chunkCount -= 1
		evicted += 1
	end
	return evicted
end

return WorldServer
