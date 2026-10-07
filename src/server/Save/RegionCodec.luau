--!strict
--[[
	A saved region: everything of the world that sits in Config.Save.RegionChunks x RegionChunks
	chunks (32 x 32, 512 x 512 blocks: Minecraft's region files), as one stream of bytes
	(Save/SaveCodec) kept in one DataStore key, or in parts when it is long. Pure, so the specs run
	it; Save/WorldSnapshot fills regions from the server's state and puts them back.

	What a region holds (Region):
	  chunks      each chunk's edit list (World/WorldServer `edits`: local index -> block, the
	              blocks that differ from what the seed generates, player-placed leaves among
	              them, which never decay), the only terrain state there is
	  containers  chests, furnaces (with their cook progress and fuel: Crafting/Smelting's data)
	              and machines (their energy, gauges and tanks are their container's data:
	              Shared/Machines), with their slots (Players/Containers)
	  sourced     positions of generated structures' chests already asked about (filled once,
	              looted or not: Containers' `sourced`), so a looted one never fills again
	  structures  structure blocks' and jigsaws' settings (Structures/StructureStore)
	  pipes       Mekanism transmitters: side modes, colour, and a pipe's share of its network's
	              fluid (TransmitterWorld.saveState: by capacity, as Mekanism splits a network)
	  tanks       Fluid Tanks' fluid and mB
	  transport   stacks travelling in Logistical Transporters (they come back waiting in the
	              transporter they were in and look for a way again)
	  items       dropped items: position, stack, age (they still despawn on time), pickup delay
	  mobs        farm animals: kind, colour, position, facing, health
	  ticks       scheduled block updates still due (flowing fluids, falling blocks), in ticks
	              from the save; they are scheduled again when their chunk is generated

	Stream: u8 VERSION, zigzag rx, zigzag rz, varint RegionChunks, then records (u8 tag, varint
	length, payload), each read back exactly to its length (anything else is a damaged save):
	  1 EDITS      u16 chunk (lcx x RegionChunks + lcz, its place in the region), varint runs, then
	               per run: varint gap (cells skipped since the last run's end: local indices are
	               ChunkLayout's, x then z then y, so a dug tunnel or a wall is a few runs),
	               varint (length - 1) x 2 + same (1: the previous run's block), varint block
	               (when not the same). A chunk's whole 16 x 16 layer of one block is one run.
	  2 CONTAINER  position (u16 x, y, z within the region), u8 kind (Inventory/Types KINDS), u16
	               block, u8 size, u8 n + n x f64 data, u8 stacks + stacks x (u8 slot, stack)
	  3 SOURCED    varint n + n x position
	  4 STRUCTURE  position, Structures/Settings' structure format
	  5 JIGSAW     position, its jigsaw format
	  6 PIPE       position, u16 modes, u8 colour, u8 fluid, varint mB
	  7 TANK       position, u8 fluid, varint mB
	  8 TRANSPORT  position, u8 colour, stack
	  9 ITEM       f64 x, y, z, varint age, varint pickup delay, stack
	 10 MOB        u8 kind, u8 variant, f64 x, y, z, f32 yaw, f32 health
	 11 TICKS      varint n + n x (position, varint delay)
	Unknown block ids, items and mob kinds (a save from a newer version) are dropped one by one.

	Parts (`split` / `join`): a stream longer than a key holds is cut into parts of at most
	`maxText` characters of base85 text each (4 bytes are 5 characters; the cuts fall anywhere,
	the parts are joined before reading). World/WorldSave keeps part 1 in the region's own key and
	the others in keys of their own (Save/WorldMeta).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local ChunkLayout = require(Shared.World.ChunkLayout)
local Config = require(Shared.Config)
local Coords = require(Shared.World.Coords)
local Items = require(Shared.Items)
local MobList = require(Shared.Entities.MobList)
local Settings = require(Shared.Structures.Settings)
local Types = require(Shared.Inventory.Types)

local SaveCodec = require(script.Parent.SaveCodec)

type Writer = SaveCodec.Writer
type Reader = SaveCodec.Reader
type Stack = Items.Stack

export type ContainerRecord = { x: number, y: number, z: number, container: Types.Container }
export type StructureRecord = { x: number, y: number, z: number, settings: Settings.StructureSettings }
export type JigsawRecord = { x: number, y: number, z: number, settings: Settings.JigsawSettings }
export type PipeRecord = {
	x: number,
	y: number,
	z: number,
	modes: number,
	colour: number,
	fluid: number,
	amount: number,
}
export type TankRecord = { x: number, y: number, z: number, fluid: number, amount: number }
export type TransportRecord = { x: number, y: number, z: number, colour: number, stack: Stack }
export type ItemRecord = { x: number, y: number, z: number, stack: Stack, age: number, pickupDelay: number }
export type MobRecord = {
	kind: number,
	variant: number,
	x: number,
	y: number,
	z: number,
	yaw: number,
	health: number,
}
export type TickRecord = { x: number, y: number, z: number, delay: number }

export type Region = {
	rx: number,
	rz: number,
	-- Chunk key (Coords.chunkKey) -> local index -> block.
	chunks: { [number]: { [number]: number } },
	containers: { ContainerRecord },
	-- Pos keys (Coords.posKey).
	sourced: { number },
	structures: { StructureRecord },
	jigsaws: { JigsawRecord },
	pipes: { PipeRecord },
	tanks: { TankRecord },
	transport: { TransportRecord },
	items: { ItemRecord },
	mobs: { MobRecord },
	ticks: { TickRecord },
	-- Edits, items and mobs dropped while reading (ids this version doesn't know).
	dropped: number,
}

local RegionCodec = {}

RegionCodec.VERSION = 1
local SIZE = Config.ChunkSize
local HEIGHT = Config.WorldHeight
local CELLS = SIZE * SIZE * HEIGHT

local EDITS, CONTAINER, SOURCED, STRUCTURE, JIGSAW, PIPE, TANK, TRANSPORT, ITEM, MOB, TICKS =
	1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11
RegionCodec.TAGS = table.freeze({
	EDITS = EDITS,
	CONTAINER = CONTAINER,
	SOURCED = SOURCED,
	STRUCTURE = STRUCTURE,
	JIGSAW = JIGSAW,
	PIPE = PIPE,
	TANK = TANK,
	TRANSPORT = TRANSPORT,
	ITEM = ITEM,
	MOB = MOB,
	TICKS = TICKS,
})

local KIND_CODE: { [string]: number } = {}
for code, kind in Types.KINDS do
	KIND_CODE[kind] = code
end

-- Chunks per region side (Config.Save.RegionChunks, at least 1).
function RegionCodec.chunks(): number
	return math.max(1, math.floor(Config.Save.RegionChunks))
end

-- Blocks per region side.
function RegionCodec.blocks(): number
	return RegionCodec.chunks() * SIZE
end

-- The region of chunk (cx, cz).
function RegionCodec.regionOf(cx: number, cz: number): (number, number)
	local n = RegionCodec.chunks()
	return cx // n, cz // n
end

-- The region of block (x, z).
function RegionCodec.regionOfBlock(x: number, z: number): (number, number)
	local n = RegionCodec.blocks()
	return x // n, z // n
end

-- A region's name in keys and tables: "rx_rz".
function RegionCodec.name(rx: number, rz: number): string
	return `{rx}_{rz}`
end

-- The region a name stands for (nil: no region name).
function RegionCodec.parseName(name: string): (number?, number?)
	local a, b = string.match(name, "^(%-?%d+)_(%-?%d+)$")
	if a == nil or b == nil then
		return nil, nil
	end
	return tonumber(a), tonumber(b)
end

function RegionCodec.new(rx: number, rz: number): Region
	return {
		rx = rx,
		rz = rz,
		chunks = {},
		containers = {},
		sourced = {},
		structures = {},
		jigsaws = {},
		pipes = {},
		tanks = {},
		transport = {},
		items = {},
		mobs = {},
		ticks = {},
		dropped = 0,
	}
end

-- Does the region hold nothing at all?
function RegionCodec.isEmpty(region: Region): boolean
	return next(region.chunks) == nil
		and #region.containers == 0
		and #region.sourced == 0
		and #region.structures == 0
		and #region.jigsaws == 0
		and #region.pipes == 0
		and #region.tanks == 0
		and #region.transport == 0
		and #region.items == 0
		and #region.mobs == 0
		and #region.ticks == 0
end

-- Edits in the region.
function RegionCodec.editCount(region: Region): number
	local count = 0
	for _, edits in region.chunks do
		for _ in edits do
			count += 1
		end
	end
	return count
end

--[[ Encoding ]]

local function position(w: Writer, region: Region, x: number, y: number, z: number)
	local n = RegionCodec.blocks()
	SaveCodec.u16(w, x - region.rx * n)
	SaveCodec.u16(w, y)
	SaveCodec.u16(w, z - region.rz * n)
end

local function readPosition(r: Reader, region: Region): (number, number, number)
	local n = RegionCodec.blocks()
	local lx, y, lz = SaveCodec.readU16(r), SaveCodec.readU16(r), SaveCodec.readU16(r)
	if lx >= n or lz >= n or y >= HEIGHT then
		error("position outside its region", 0)
	end
	return region.rx * n + lx, y, region.rz * n + lz
end

-- Appends record `tag` with the payload `body` wrote.
local function record(w: Writer, tag: number, body: Writer)
	SaveCodec.u8(w, tag)
	SaveCodec.varint(w, body.n)
	SaveCodec.bytes(w, body.b, body.n)
end

local function encodeEdits(w: Writer, region: Region, chunkKey: number, edits: { [number]: number }, scratch: Writer)
	local indices: { number } = {}
	for index in edits do
		table.insert(indices, index)
	end
	if #indices == 0 then
		return
	end
	table.sort(indices)
	local cx, cz = Coords.decodeChunkKey(chunkKey)
	local n = RegionCodec.chunks()
	scratch.n = 0
	SaveCodec.u16(scratch, (cx - region.rx * n) * n + (cz - region.rz * n))
	-- (The run count goes first: the runs are written to a second pass's writer.)
	local runs = SaveCodec.writer(#indices * 2)
	local count = 0
	local expected, previous = 0, -1
	local i, total = 1, #indices
	while i <= total do
		local start = indices[i]
		local block = edits[start]
		local length = 1
		while i + length <= total and indices[i + length] == start + length and edits[start + length] == block do
			length += 1
		end
		local same = block == previous
		SaveCodec.varint(runs, start - expected)
		SaveCodec.varint(runs, (length - 1) * 2 + (if same then 1 else 0))
		if not same then
			SaveCodec.varint(runs, block)
		end
		count += 1
		expected = start + length
		previous = block
		i += length
	end
	SaveCodec.varint(scratch, count)
	SaveCodec.bytes(scratch, runs.b, runs.n)
	record(w, EDITS, scratch)
end

local function encodeContainer(w: Writer, region: Region, entry: ContainerRecord, scratch: Writer)
	local container = entry.container
	local code = KIND_CODE[container.kind]
	if code == nil then
		return
	end
	scratch.n = 0
	position(scratch, region, entry.x, entry.y, entry.z)
	SaveCodec.u8(scratch, code)
	SaveCodec.u16(scratch, container.block)
	local size = math.clamp(container.size, 0, Types.MAX_CONTAINER)
	SaveCodec.u8(scratch, size)
	local data = container.data
	local count = if data then math.min(#data, Types.MAX_CONTAINER_DATA) else 0
	SaveCodec.u8(scratch, count)
	for i = 1, count do
		local value = (data :: { number })[i]
		SaveCodec.f64(scratch, if value == value then value else 0)
	end
	local stacks = 0
	for slot = 1, size do
		local stack = container.slots[slot]
		if stack and stack.count >= 1 then
			stacks += 1
		end
	end
	SaveCodec.u8(scratch, stacks)
	for slot = 1, size do
		local stack = container.slots[slot]
		if stack and stack.count >= 1 then
			SaveCodec.u8(scratch, slot)
			SaveCodec.stack(scratch, stack)
		end
	end
	record(w, CONTAINER, scratch)
end

-- The region's bytes (records in a fixed order: the same region always encodes alike).
function RegionCodec.encode(region: Region): buffer
	local w = SaveCodec.writer(4096)
	local scratch = SaveCodec.writer(1024)
	SaveCodec.u8(w, RegionCodec.VERSION)
	SaveCodec.zigzag(w, region.rx)
	SaveCodec.zigzag(w, region.rz)
	SaveCodec.varint(w, RegionCodec.chunks())

	local chunkKeys: { number } = {}
	for key in region.chunks do
		table.insert(chunkKeys, key)
	end
	table.sort(chunkKeys)
	for _, key in chunkKeys do
		encodeEdits(w, region, key, region.chunks[key], scratch)
	end
	for _, entry in region.containers do
		encodeContainer(w, region, entry, scratch)
	end
	if #region.sourced > 0 then
		scratch.n = 0
		SaveCodec.varint(scratch, #region.sourced)
		for _, key in region.sourced do
			local x, y, z = Coords.decodePosKey(key)
			position(scratch, region, x, y, z)
		end
		record(w, SOURCED, scratch)
	end
	for _, entry in region.structures do
		scratch.n = 0
		position(scratch, region, entry.x, entry.y, entry.z)
		SaveCodec.ensure(scratch, Settings.structureBytes(entry.settings))
		scratch.n = Settings.writeStructure(scratch.b, scratch.n, entry.settings)
		record(w, STRUCTURE, scratch)
	end
	for _, entry in region.jigsaws do
		scratch.n = 0
		position(scratch, region, entry.x, entry.y, entry.z)
		SaveCodec.ensure(scratch, Settings.jigsawBytes(entry.settings))
		scratch.n = Settings.writeJigsaw(scratch.b, scratch.n, entry.settings)
		record(w, JIGSAW, scratch)
	end
	for _, entry in region.pipes do
		scratch.n = 0
		position(scratch, region, entry.x, entry.y, entry.z)
		SaveCodec.u16(scratch, entry.modes)
		SaveCodec.u8(scratch, entry.colour)
		SaveCodec.u8(scratch, entry.fluid)
		SaveCodec.varint(scratch, math.max(0, math.floor(entry.amount)))
		record(w, PIPE, scratch)
	end
	for _, entry in region.tanks do
		scratch.n = 0
		position(scratch, region, entry.x, entry.y, entry.z)
		SaveCodec.u8(scratch, entry.fluid)
		SaveCodec.varint(scratch, math.max(0, math.floor(entry.amount)))
		record(w, TANK, scratch)
	end
	for _, entry in region.transport do
		scratch.n = 0
		position(scratch, region, entry.x, entry.y, entry.z)
		SaveCodec.u8(scratch, entry.colour)
		SaveCodec.stack(scratch, entry.stack)
		record(w, TRANSPORT, scratch)
	end
	for _, entry in region.items do
		scratch.n = 0
		SaveCodec.f64(scratch, entry.x)
		SaveCodec.f64(scratch, entry.y)
		SaveCodec.f64(scratch, entry.z)
		SaveCodec.varint(scratch, math.max(0, math.floor(entry.age)))
		SaveCodec.varint(scratch, math.clamp(math.floor(entry.pickupDelay), 0, 32767))
		SaveCodec.stack(scratch, entry.stack)
		record(w, ITEM, scratch)
	end
	for _, entry in region.mobs do
		scratch.n = 0
		SaveCodec.u8(scratch, entry.kind)
		SaveCodec.u8(scratch, math.clamp(entry.variant, 0, 255))
		SaveCodec.f64(scratch, entry.x)
		SaveCodec.f64(scratch, entry.y)
		SaveCodec.f64(scratch, entry.z)
		SaveCodec.f32(scratch, entry.yaw)
		SaveCodec.f32(scratch, entry.health)
		record(w, MOB, scratch)
	end
	if #region.ticks > 0 then
		scratch.n = 0
		SaveCodec.varint(scratch, #region.ticks)
		for _, entry in region.ticks do
			position(scratch, region, entry.x, entry.y, entry.z)
			SaveCodec.varint(scratch, math.max(1, math.floor(entry.delay)))
		end
		record(w, TICKS, scratch)
	end
	return SaveCodec.finish(w)
end

--[[ Decoding ]]

local function decodeEdits(r: Reader, region: Region)
	local n = RegionCodec.chunks()
	local place = SaveCodec.readU16(r)
	local lcx, lcz = place // n, place % n
	if lcx >= n then
		error("chunk outside its region", 0)
	end
	local key = Coords.chunkKey(region.rx * n + lcx, region.rz * n + lcz)
	local edits = region.chunks[key]
	if edits == nil then
		edits = {}
		region.chunks[key] = edits
	end
	local runs = SaveCodec.readVarint(r)
	local cell, block = 0, -1
	for _ = 1, runs do
		cell += SaveCodec.readVarint(r)
		local shape = SaveCodec.readVarint(r)
		local length = shape // 2 + 1
		if shape % 2 == 0 then
			block = SaveCodec.readVarint(r)
		elseif block < 0 then
			error("run repeats no block", 0)
		end
		if cell + length > CELLS then
			error("edit outside its chunk", 0)
		end
		if Blocks.isValid(block) then
			for index = cell, cell + length - 1 do
				edits[index] = block
			end
		else
			region.dropped += length
		end
		cell += length
	end
	if next(edits) == nil then
		region.chunks[key] = nil
	end
end

local function decodeContainer(r: Reader, region: Region)
	local x, y, z = readPosition(r, region)
	local kind = Types.KINDS[SaveCodec.readU8(r)]
	local block = SaveCodec.readU16(r)
	local size = SaveCodec.readU8(r)
	local count = SaveCodec.readU8(r)
	if kind == nil or size > Types.MAX_CONTAINER or count > Types.MAX_CONTAINER_DATA then
		error("bad container in save", 0)
	end
	local data: { number }? = nil
	if count > 0 then
		local values = table.create(count, 0)
		for i = 1, count do
			local value = SaveCodec.readF64(r)
			values[i] = if value == value then value else 0
		end
		data = values
	end
	local slots: { [number]: Stack? } = {}
	for _ = 1, SaveCodec.readU8(r) do
		local slot = SaveCodec.readU8(r)
		local stack = SaveCodec.readStack(r)
		if slot >= 1 and slot <= size then
			slots[slot] = stack
		end
	end
	if not Blocks.isValid(block) then
		region.dropped += 1
		return
	end
	table.insert(region.containers, {
		x = x,
		y = y,
		z = z,
		container = { kind = kind, block = block, size = size, slots = slots, data = data },
	})
end

local function decodeRecord(r: Reader, region: Region, tag: number)
	if tag == EDITS then
		decodeEdits(r, region)
	elseif tag == CONTAINER then
		decodeContainer(r, region)
	elseif tag == SOURCED then
		for _ = 1, SaveCodec.readVarint(r) do
			local x, y, z = readPosition(r, region)
			table.insert(region.sourced, Coords.posKey(x, y, z))
		end
	elseif tag == STRUCTURE then
		local x, y, z = readPosition(r, region)
		local ok, settings, after = Settings.readStructure(r.b, r.o, r.len)
		if not ok or settings == nil then
			error("bad structure block in save", 0)
		end
		r.o = after
		table.insert(region.structures, { x = x, y = y, z = z, settings = settings })
	elseif tag == JIGSAW then
		local x, y, z = readPosition(r, region)
		local ok, settings, after = Settings.readJigsaw(r.b, r.o, r.len)
		if not ok or settings == nil then
			error("bad jigsaw in save", 0)
		end
		r.o = after
		table.insert(region.jigsaws, { x = x, y = y, z = z, settings = settings })
	elseif tag == PIPE then
		local x, y, z = readPosition(r, region)
		table.insert(region.pipes, {
			x = x,
			y = y,
			z = z,
			modes = SaveCodec.readU16(r),
			colour = SaveCodec.readU8(r),
			fluid = SaveCodec.readU8(r),
			amount = SaveCodec.readVarint(r),
		})
	elseif tag == TANK then
		local x, y, z = readPosition(r, region)
		table.insert(
			region.tanks,
			{ x = x, y = y, z = z, fluid = SaveCodec.readU8(r), amount = SaveCodec.readVarint(r) }
		)
	elseif tag == TRANSPORT then
		local x, y, z = readPosition(r, region)
		local colour = SaveCodec.readU8(r)
		local stack = SaveCodec.readStack(r)
		if stack then
			table.insert(region.transport, { x = x, y = y, z = z, colour = colour, stack = stack })
		else
			region.dropped += 1
		end
	elseif tag == ITEM then
		local x, y, z = SaveCodec.readFinite(r), SaveCodec.readFinite(r), SaveCodec.readFinite(r)
		local age = SaveCodec.readVarint(r)
		local pickupDelay = SaveCodec.readVarint(r)
		local stack = SaveCodec.readStack(r)
		if stack then
			table.insert(region.items, { x = x, y = y, z = z, stack = stack, age = age, pickupDelay = pickupDelay })
		else
			region.dropped += 1
		end
	elseif tag == MOB then
		local kind = SaveCodec.readU8(r)
		local variant = SaveCodec.readU8(r)
		local x, y, z = SaveCodec.readFinite(r), SaveCodec.readFinite(r), SaveCodec.readFinite(r)
		local yaw, health = SaveCodec.readF32(r), SaveCodec.readF32(r)
		if MobList.get(kind) and yaw == yaw and health == health then
			table.insert(
				region.mobs,
				{ kind = kind, variant = variant, x = x, y = y, z = z, yaw = yaw, health = health }
			)
		else
			region.dropped += 1
		end
	elseif tag == TICKS then
		for _ = 1, SaveCodec.readVarint(r) do
			local x, y, z = readPosition(r, region)
			table.insert(region.ticks, { x = x, y = y, z = z, delay = math.max(1, SaveCodec.readVarint(r)) })
		end
	else
		error(`unknown record {tag} in save`, 0)
	end
end

--[[
	The region in `bytes` (errors with the reason when they are damaged, or from a newer version:
	use `tryDecode` for a nil instead). `rx`, `rz`: the region the key is for (it must match).
]]
function RegionCodec.decode(bytes: buffer, rx: number?, rz: number?): Region
	local r = SaveCodec.reader(bytes)
	local version = SaveCodec.readU8(r)
	if version > RegionCodec.VERSION then
		error("saved by a newer version", 0)
	elseif version < 1 then
		error("not a region", 0)
	end
	local region = RegionCodec.new(SaveCodec.readZigzag(r), SaveCodec.readZigzag(r))
	if SaveCodec.readVarint(r) ~= RegionCodec.chunks() then
		error("saved with another Config.Save.RegionChunks", 0)
	end
	if (rx ~= nil and rx ~= region.rx) or (rz ~= nil and rz ~= region.rz) then
		error("region saved under another key", 0)
	end
	while not SaveCodec.atEnd(r) do
		local tag = SaveCodec.readU8(r)
		local length = SaveCodec.readVarint(r)
		local stop = r.o + length
		if stop > r.len then
			error("truncated save", 0)
		end
		local inner = SaveCodec.reader(r.b, r.o, stop)
		decodeRecord(inner, region, tag)
		if inner.o ~= stop then
			error(`record {tag} has bytes left over`, 0)
		end
		r.o = stop
	end
	return region
end

-- `decode`, or nil and why not.
function RegionCodec.tryDecode(bytes: buffer, rx: number?, rz: number?): (Region?, string?)
	local ok, result = pcall(RegionCodec.decode, bytes, rx, rz)
	if ok then
		return result, nil
	end
	return nil, tostring(result)
end

--[[ Parts ]]

-- Bytes one part holds: what fits `maxText` characters of base85.
function RegionCodec.partBytes(maxText: number): number
	return math.max(4, math.floor(maxText / 5) * 4)
end

-- `bytes` as base85 texts of at most `maxText` characters each (at least one, maybe empty).
function RegionCodec.split(bytes: buffer, maxText: number): { string }
	local per = RegionCodec.partBytes(maxText)
	local total = buffer.len(bytes)
	local parts: { string } = {}
	local from = 0
	repeat
		local count = math.min(per, total - from)
		table.insert(parts, SaveCodec.toText(bytes, from, count))
		from += count
	until from >= total
	return parts
end

-- The bytes of `parts` (texts `split` made, in order); nil when one is no base85 text.
function RegionCodec.join(parts: { string }): buffer?
	local decoded: { buffer } = {}
	local total = 0
	for i, text in parts do
		local bytes = SaveCodec.fromText(text)
		if bytes == nil then
			return nil
		end
		decoded[i] = bytes
		total += buffer.len(bytes)
	end
	local out = buffer.create(total)
	local o = 0
	for _, bytes in decoded do
		buffer.copy(out, o, bytes)
		o += buffer.len(bytes)
	end
	return out
end

-- The local index of block (x, y, z) in its chunk, and the chunk's key.
function RegionCodec.cell(x: number, y: number, z: number): (number, number)
	local cx, cz, lx, lz = Coords.blockToChunk(x, z)
	return Coords.chunkKey(cx, cz), ChunkLayout.localIndex(lx, y, lz)
end

return RegionCodec
