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
	  natural     the seasons' natural map (World/WorldServer `natural`: chunk key -> local index
	              -> the generated block), beside the edits of the cells it is for
	  thaw        the weather's ice (World/WorldServer `thaw`: chunk key -> local index -> the
	              block it thaws back to), the cells still holding the ice the weather froze

	Stream: u8 version (VERSION, 3), zigzag rx, zigzag rz, varint RegionChunks, then records (u8
	tag, varint length, payload), each read back exactly to its length (anything else is a
	damaged save). The first record is the region's palette (Save/SaveCodec: names, not ids): every
	block, item, fluid and mob kind the others hold is its index there, so content can be added,
	removed or reordered between versions without moving a block. A region of version 1 or 2
	(before palettes: ids that were another version's) is refused, never misread (SaveCodec.OLDER:
	Save/WorldStore starts it afresh from the seed), and a newer one too (never written over).
	 14 PALETTE    the palette (SaveCodec.writePalette: the writer's place version, then the
	               names), first
	  1 EDITS      u16 chunk (lcx x RegionChunks + lcz, its place in the region), varint runs, then
	               per run: varint gap (cells skipped since the last run's end: local indices are
	               ChunkLayout's, x then z then y, so a dug tunnel or a wall is a few runs),
	               varint (length - 1) x 2 + same (1: the previous run's block), varint block
	               (when not the same). A chunk's whole 16 x 16 layer of one block is one run.
	  2 CONTAINER  position (u16 x, y, z within the region), u8 kind (Inventory/Types KINDS),
	               varint block, u8 size, u8 n + n x f64 data, u8 stacks + stacks x (u8 slot,
	               stack). The data's ids are palette indices too: a furnace's cooking item
	               (Crafting/Smelting.ID_FIELDS), a machine's fields holding ids and its tanks'
	               fluids (Shared/Machines.idFields: the Metal Miner's ore, the Electric Furnace's
	               item)
	  3 SOURCED    varint n + n x position
	  4 STRUCTURE  position, Structures/Settings' structure format
	  5 JIGSAW     position, its jigsaw format
	  6 PIPE       position, u16 modes, u8 colour, varint fluid, varint mB
	  7 TANK       position, varint fluid, varint mB
	  8 TRANSPORT  position, u8 colour, stack
	  9 ITEM       f64 x, y, z, varint age, varint pickup delay, stack
	 10 MOB        varint kind, u8 variant, f64 x, y, z, f32 yaw, f32 health
	 11 TICKS      varint n + n x (position, varint delay)
	 12 NATURAL    what the seed generated at cells the seasons' weather changed (World/
	               WorldServer's natural map: snow and ice that melting deletes), as EDITS: u16
	               chunk, varint runs of index gap + block
	 13 THAW       the weather's ice (World/WorldServer's thaw map: what each cell thaws back
	               to), as EDITS
	Names this version doesn't know (a newer version's, or content since removed) are counted
	(`dropped`, and by name in `unknown`) one by one: an edit of such a block becomes Air, a
	natural or thaw entry is left out, a container of such a block goes (its stacks with it), a
	stack is dropped (or, for an id in its data, that key), a pipe's or tank's fluid empties, a
	mob goes, an id in a container's data becomes 0 (nothing: what the machine works on starts
	over). The region's `placeVersion` (its writer's) tells Save/WorldStore which they are
	(SaveCodec.newerNames).

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
local Machines = require(Shared.Machines)
local MobList = require(Shared.Entities.MobList)
local Settings = require(Shared.Structures.Settings)
local Smelting = require(Shared.Crafting.Smelting)
local Types = require(Shared.Inventory.Types)

local SaveCodec = require(script.Parent.SaveCodec)

type Writer = SaveCodec.Writer
type Reader = SaveCodec.Reader
type Palette = SaveCodec.Palette
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
	-- Chunk key -> local index -> the block the seed generated (World/WorldServer `natural`).
	natural: { [number]: { [number]: number } },
	-- Chunk key -> local index -> the block the weather's ice thaws back to (World/WorldServer
	-- `thaw`).
	thaw: { [number]: { [number]: number } },
	-- What was left out while reading, one by one: names this version doesn't know (see the
	-- header), and each such name with how many things of it.
	dropped: number,
	unknown: { [string]: number },
	-- Read: the place version of the server that wrote it (0: unknown, Studio; SaveCodec's
	-- `newerNames` says whether what was left out may be a newer version's content).
	placeVersion: number,
}

local RegionCodec = {}

-- The version regions are written with (see the header: older ones are refused).
RegionCodec.VERSION = 3
local SIZE = Config.ChunkSize
local HEIGHT = Config.WorldHeight
local CELLS = SIZE * SIZE * HEIGHT
local AIR = Blocks.AIR

local EDITS, CONTAINER, SOURCED, STRUCTURE, JIGSAW, PIPE, TANK, TRANSPORT, ITEM, MOB, TICKS =
	1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11
local NATURAL, THAW, PALETTE = 12, 13, 14
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
	NATURAL = NATURAL,
	THAW = THAW,
	PALETTE = PALETTE,
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
		natural = {},
		thaw = {},
		dropped = 0,
		unknown = {},
		placeVersion = 0,
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
		and next(region.natural) == nil
		and next(region.thaw) == nil
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

local function encodeEdits(
	w: Writer,
	region: Region,
	chunkKey: number,
	edits: { [number]: number },
	scratch: Writer,
	palette: Palette,
	tag: number?
)
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
			SaveCodec.varint(runs, SaveCodec.indexOf(palette, "block", block))
		end
		count += 1
		expected = start + length
		previous = block
		i += length
	end
	SaveCodec.varint(scratch, count)
	SaveCodec.bytes(scratch, runs.b, runs.n)
	record(w, tag or EDITS, scratch)
end

--[[
	The data indices of `container` holding a content id, and what of, by the kind of its block
	today: a furnace's cooking item (Crafting/Smelting), a machine's typed fields and tanks' fluids
	(Shared/Machines.idFields). nil: none.
]]
local function idFields(container: Types.Container): { [number]: SaveCodec.PaletteKind }?
	if container.kind == "furnace" then
		return Smelting.ID_FIELDS :: any
	elseif container.kind == Machines.CONTAINER_KIND then
		return Machines.idFields(container.block) :: any
	end
	return nil
end

local function encodeContainer(w: Writer, region: Region, entry: ContainerRecord, scratch: Writer, palette: Palette)
	local container = entry.container
	local code = KIND_CODE[container.kind]
	if code == nil then
		return
	end
	scratch.n = 0
	position(scratch, region, entry.x, entry.y, entry.z)
	SaveCodec.u8(scratch, code)
	SaveCodec.varint(scratch, SaveCodec.indexOf(palette, "block", container.block))
	local size = math.clamp(container.size, 0, Types.MAX_CONTAINER)
	SaveCodec.u8(scratch, size)
	local data = container.data
	local count = if data then math.min(#data, Types.MAX_CONTAINER_DATA) else 0
	local ids = idFields(container)
	SaveCodec.u8(scratch, count)
	for i = 1, count do
		local value = (data :: { number })[i]
		local kind = if ids then ids[i] else nil
		if kind then
			-- (An id as its palette index: 0, nothing, for none and anything that is no id.)
			value = SaveCodec.indexOf(palette, kind, value)
		end
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
			SaveCodec.stack(scratch, stack, palette)
		end
	end
	record(w, CONTAINER, scratch)
end

--[[
	The region's bytes (records in a fixed order: the same region always encodes alike), its
	palette first, written by place version `place` (this server's game.PlaceVersion; default
	0, unknown). `palette`: one to start from (default an empty one), its names keeping their
	indices: the specs' stand-in for a version whose content came in another order.
]]
function RegionCodec.encode(region: Region, place: number?, palette: Palette?): buffer
	local names = palette or SaveCodec.palette()
	if place then
		names.place = place
	end
	-- (The records first, gathering the palette, which goes before them.)
	local w = SaveCodec.writer(4096)
	local scratch = SaveCodec.writer(1024)

	local chunkKeys: { number } = {}
	for key in region.chunks do
		table.insert(chunkKeys, key)
	end
	table.sort(chunkKeys)
	for _, key in chunkKeys do
		encodeEdits(w, region, key, region.chunks[key], scratch, names)
	end
	for _, entry in region.containers do
		encodeContainer(w, region, entry, scratch, names)
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
		SaveCodec.varint(scratch, SaveCodec.indexOf(names, "fluid", entry.fluid))
		SaveCodec.varint(scratch, math.max(0, math.floor(entry.amount)))
		record(w, PIPE, scratch)
	end
	for _, entry in region.tanks do
		scratch.n = 0
		position(scratch, region, entry.x, entry.y, entry.z)
		SaveCodec.varint(scratch, SaveCodec.indexOf(names, "fluid", entry.fluid))
		SaveCodec.varint(scratch, math.max(0, math.floor(entry.amount)))
		record(w, TANK, scratch)
	end
	for _, entry in region.transport do
		scratch.n = 0
		position(scratch, region, entry.x, entry.y, entry.z)
		SaveCodec.u8(scratch, entry.colour)
		SaveCodec.stack(scratch, entry.stack, names)
		record(w, TRANSPORT, scratch)
	end
	for _, entry in region.items do
		scratch.n = 0
		SaveCodec.f64(scratch, entry.x)
		SaveCodec.f64(scratch, entry.y)
		SaveCodec.f64(scratch, entry.z)
		SaveCodec.varint(scratch, math.max(0, math.floor(entry.age)))
		SaveCodec.varint(scratch, math.clamp(math.floor(entry.pickupDelay), 0, 32767))
		SaveCodec.stack(scratch, entry.stack, names)
		record(w, ITEM, scratch)
	end
	for _, entry in region.mobs do
		local kind = SaveCodec.indexOf(names, "mob", entry.kind)
		if kind > 0 then
			scratch.n = 0
			SaveCodec.varint(scratch, kind)
			SaveCodec.u8(scratch, math.clamp(entry.variant, 0, 255))
			SaveCodec.f64(scratch, entry.x)
			SaveCodec.f64(scratch, entry.y)
			SaveCodec.f64(scratch, entry.z)
			SaveCodec.f32(scratch, entry.yaw)
			SaveCodec.f32(scratch, entry.health)
			record(w, MOB, scratch)
		end
	end
	local naturalKeys: { number } = {}
	for key in region.natural do
		table.insert(naturalKeys, key)
	end
	table.sort(naturalKeys)
	for _, key in naturalKeys do
		encodeEdits(w, region, key, region.natural[key], scratch, names, NATURAL)
	end
	local thawKeys: { number } = {}
	for key in region.thaw do
		table.insert(thawKeys, key)
	end
	table.sort(thawKeys)
	for _, key in thawKeys do
		encodeEdits(w, region, key, region.thaw[key], scratch, names, THAW)
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

	local out = SaveCodec.writer(w.n + 256)
	SaveCodec.u8(out, RegionCodec.VERSION)
	SaveCodec.zigzag(out, region.rx)
	SaveCodec.zigzag(out, region.rz)
	SaveCodec.varint(out, RegionCodec.chunks())
	scratch.n = 0
	SaveCodec.writePalette(scratch, names)
	record(out, PALETTE, scratch)
	SaveCodec.bytes(out, w.b, w.n)
	return SaveCodec.finish(out)
end

--[[ Decoding ]]

--[[
	An EDITS record into `into` (default the region's edits; the seasons' maps for NATURAL and
	THAW). A block this version doesn't know is counted, and becomes Air in edits (Minecraft's
	unknown blocks) or is left out of a map.
]]
local function decodeEdits(r: Reader, region: Region, palette: Palette, into: { [number]: { [number]: number } }?)
	local chunks = into or region.chunks
	local n = RegionCodec.chunks()
	local place = SaveCodec.readU16(r)
	local lcx, lcz = place // n, place % n
	if lcx >= n then
		error("chunk outside its region", 0)
	end
	local key = Coords.chunkKey(region.rx * n + lcx, region.rz * n + lcz)
	local edits = chunks[key]
	if edits == nil then
		edits = {}
		chunks[key] = edits
	end
	local runs = SaveCodec.readVarint(r)
	local cell = 0
	local saved: number? = nil
	for _ = 1, runs do
		cell += SaveCodec.readVarint(r)
		local shape = SaveCodec.readVarint(r)
		local length = shape // 2 + 1
		if shape % 2 == 0 then
			saved = SaveCodec.readVarint(r)
		elseif saved == nil then
			error("run repeats no block", 0)
		end
		if cell + length > CELLS then
			error("edit outside its chunk", 0)
		end
		-- (Looked up for each run: one this version doesn't know is counted cell by cell.)
		local block = SaveCodec.idOf(palette, "block", saved :: number, length)
		local placed = block or (if into == nil then AIR else nil)
		if block == nil then
			region.dropped += length
		end
		if placed ~= nil then
			for index = cell, cell + length - 1 do
				edits[index] = placed
			end
		end
		cell += length
	end
	if next(edits) == nil then
		chunks[key] = nil
	end
end

local function decodeContainer(r: Reader, region: Region, palette: Palette)
	local x, y, z = readPosition(r, region)
	local kind = Types.KINDS[SaveCodec.readU8(r)]
	local block = SaveCodec.idOf(palette, "block", SaveCodec.readVarint(r))
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
		local stack, lost = SaveCodec.readStack(r, palette)
		if lost then
			region.dropped += 1
		end
		if slot >= 1 and slot <= size then
			slots[slot] = stack
		end
	end
	if block == nil or not Blocks.isValid(block) then
		region.dropped += 1
		return
	end
	local container: Types.Container = { kind = kind, block = block, size = size, slots = slots, data = data }
	local ids = idFields(container)
	if ids and data then
		-- (The ids in its data, today's again: one this version doesn't know is nothing, 0.)
		for i, idKind in ids do
			local index = data[i]
			if index ~= nil then
				if index < 0 or index ~= math.floor(index) then
					error("bad palette index in save", 0)
				end
				local id = SaveCodec.idOf(palette, idKind, index)
				if id == nil then
					region.dropped += 1
				end
				data[i] = id or 0
			end
		end
	end
	table.insert(region.containers, { x = x, y = y, z = z, container = container })
end

-- A fluid's palette index read back: today's id, NONE (0) for one this version doesn't know.
local function readFluid(r: Reader, region: Region, palette: Palette): number
	local fluid = SaveCodec.idOf(palette, "fluid", SaveCodec.readVarint(r))
	if fluid == nil then
		region.dropped += 1
		return 0
	end
	return fluid
end

local function decodeRecord(r: Reader, region: Region, tag: number, palette: Palette)
	if tag == EDITS then
		decodeEdits(r, region, palette)
	elseif tag == CONTAINER then
		decodeContainer(r, region, palette)
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
		local modes = SaveCodec.readU16(r)
		local colour = SaveCodec.readU8(r)
		local fluid = readFluid(r, region, palette)
		local amount = SaveCodec.readVarint(r)
		table.insert(region.pipes, {
			x = x,
			y = y,
			z = z,
			modes = modes,
			colour = colour,
			fluid = fluid,
			-- (A fluid this version doesn't know empties it.)
			amount = if fluid == 0 then 0 else amount,
		})
	elseif tag == TANK then
		local x, y, z = readPosition(r, region)
		local fluid = readFluid(r, region, palette)
		local amount = SaveCodec.readVarint(r)
		table.insert(region.tanks, { x = x, y = y, z = z, fluid = fluid, amount = if fluid == 0 then 0 else amount })
	elseif tag == TRANSPORT then
		local x, y, z = readPosition(r, region)
		local colour = SaveCodec.readU8(r)
		local stack, lost = SaveCodec.readStack(r, palette)
		if lost then
			region.dropped += 1
		end
		if stack then
			table.insert(region.transport, { x = x, y = y, z = z, colour = colour, stack = stack })
		end
	elseif tag == ITEM then
		local x, y, z = SaveCodec.readFinite(r), SaveCodec.readFinite(r), SaveCodec.readFinite(r)
		local age = SaveCodec.readVarint(r)
		local pickupDelay = SaveCodec.readVarint(r)
		local stack, lost = SaveCodec.readStack(r, palette)
		if lost then
			region.dropped += 1
		end
		if stack then
			table.insert(region.items, { x = x, y = y, z = z, stack = stack, age = age, pickupDelay = pickupDelay })
		end
	elseif tag == MOB then
		local kind = SaveCodec.idOf(palette, "mob", SaveCodec.readVarint(r))
		local variant = SaveCodec.readU8(r)
		local x, y, z = SaveCodec.readFinite(r), SaveCodec.readFinite(r), SaveCodec.readFinite(r)
		local yaw, health = SaveCodec.readF32(r), SaveCodec.readF32(r)
		if kind and MobList.get(kind) and yaw == yaw and health == health then
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
	elseif tag == NATURAL then
		decodeEdits(r, region, palette, region.natural)
	elseif tag == THAW then
		decodeEdits(r, region, palette, region.thaw)
	else
		error(`unknown record {tag} in save`, 0)
	end
end

--[[
	The region in `bytes` (errors with the reason when they are damaged, or from another version:
	SaveCodec.NEWER, SaveCodec.OLDER; use `tryDecode` for a nil instead). `rx`, `rz`: the region
	the key is for (it must match).
]]
function RegionCodec.decode(bytes: buffer, rx: number?, rz: number?): Region
	local r = SaveCodec.reader(bytes)
	local version = SaveCodec.readU8(r)
	if version > RegionCodec.VERSION then
		error(SaveCodec.NEWER, 0)
	elseif version < 1 then
		error("not a region", 0)
	elseif version < RegionCodec.VERSION then
		-- (Before palettes: its ids were that version's. Never read.)
		error(SaveCodec.OLDER, 0)
	end
	local region = RegionCodec.new(SaveCodec.readZigzag(r), SaveCodec.readZigzag(r))
	if SaveCodec.readVarint(r) ~= RegionCodec.chunks() then
		error("saved with another Config.Save.RegionChunks", 0)
	end
	if (rx ~= nil and rx ~= region.rx) or (rz ~= nil and rz ~= region.rz) then
		error("region saved under another key", 0)
	end
	local palette: Palette? = nil
	while not SaveCodec.atEnd(r) do
		local tag = SaveCodec.readU8(r)
		local length = SaveCodec.readVarint(r)
		local stop = r.o + length
		if stop > r.len then
			error("truncated save", 0)
		end
		local inner = SaveCodec.reader(r.b, r.o, stop)
		if tag == PALETTE then
			if palette then
				error("a second palette in save", 0)
			end
			local read = SaveCodec.readPalette(inner)
			palette = read
			region.placeVersion = read.place
			-- (Counted into while the records are read.)
			region.unknown = read.unknown
		elseif palette == nil then
			error(`record {tag} before the palette`, 0)
		else
			decodeRecord(inner, region, tag, palette)
		end
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
