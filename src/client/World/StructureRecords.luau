--!strict
--[[
	What the client knows about structure blocks and jigsaw blocks, without any Roblox APIs (the
	tests drive it; Net/StructureNet feeds it, Ui/StructureScreen, Ui/Waila and
	Rendering/StructureBoxes read it).

	  records   the server's StructureBlocks and Jigsaws messages (Net/Protocol): a record replaces
	            what was known about its position, one without settings forgets it. They come with
	            a chunk's edit list and when they change near the player, so a block broken while
	            the player was far away can leave a stale record: `prune` drops records whose
	            loaded block is no longer a structure block or jigsaw, and readers check the block
	            anyway.
	  regions   the box a structure block outlines (`region`): Minecraft's StructureBlockRenderer
	            draws SAVE's region always and LOAD's when "Show Bounding Box" is on, nothing for
	            CORNER and DATA or with any side 0. LOAD's box is the template's turned box where
	            the server places it (Structures/Transform.anchor: Minecraft turns around the
	            block's offset position).
	  outbox    structure text the player pasted goes to the server in Protocol StructureData
	            pieces, at most Config.Structures.DataPiecesPerSecond (a burst of a second's worth),
	            followed by the request that names it (the LOAD): `Outbox` paces any messages.
	  saves     a SAVE's text comes back in pieces (Protocol.joinStructureData); `Downloads` keeps
	            the finished texts of the last few blocks the player saved from. The pieces don't
	            name their block: a text goes to the oldest SAVE still expected with its name and
	            size (the server answers SAVEs in order; the ones before it were refused).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local Coords = require(Shared.World.Coords)
local Protocol = require(Shared.Net.Protocol)
local Settings = require(Shared.Structures.Settings)
local Template = require(Shared.Structures.Template)
local Transform = require(Shared.Structures.Transform)

type StructureSettings = Settings.StructureSettings
type JigsawSettings = Settings.JigsawSettings

local HEIGHT = Config.WorldHeight

local StructureRecords = {}

export type Records = {
	structures: { [number]: StructureSettings },
	jigsaws: { [number]: JigsawSettings },
	-- Bumped whenever a record changes (readers redraw when it does).
	version: number,
}

function StructureRecords.new(): Records
	return { structures = {}, jigsaws = {}, version = 0 }
end

local function valid(x: number, y: number, z: number): boolean
	return y >= 0
		and y < HEIGHT
		and math.abs(x) <= Protocol.MAX_COORDINATE
		and math.abs(z) <= Protocol.MAX_COORDINATE
		and x == math.floor(x)
		and z == math.floor(z)
end

-- Takes the records of a StructureBlocks message.
function StructureRecords.applyStructures(r: Records, records: { Protocol.StructureBlockRecord })
	for _, record in records do
		if valid(record.x, record.y, record.z) then
			local key = Coords.posKey(record.x, record.y, record.z)
			local settings = record.settings
			if settings then
				r.structures[key] = settings
			else
				r.structures[key] = nil
			end
		end
	end
	r.version += 1
end

-- Takes the records of a Jigsaws message.
function StructureRecords.applyJigsaws(r: Records, records: { Protocol.JigsawRecord })
	for _, record in records do
		if valid(record.x, record.y, record.z) then
			local key = Coords.posKey(record.x, record.y, record.z)
			local settings = record.settings
			if settings then
				r.jigsaws[key] = settings
			else
				r.jigsaws[key] = nil
			end
		end
	end
	r.version += 1
end

function StructureRecords.structure(r: Records, x: number, y: number, z: number): StructureSettings?
	if not valid(x, y, z) then
		return nil
	end
	return r.structures[Coords.posKey(x, y, z)]
end

function StructureRecords.jigsaw(r: Records, x: number, y: number, z: number): JigsawSettings?
	if not valid(x, y, z) then
		return nil
	end
	return r.jigsaws[Coords.posKey(x, y, z)]
end

--[[
	Forgets records whose block is loaded (`getBlock` gives a block, not nil) and is no longer a
	structure block (or jigsaw). Returns how many went.
]]
function StructureRecords.prune(r: Records, getBlock: (x: number, y: number, z: number) -> number?): number
	local removed = 0
	for key in r.structures do
		local x, y, z = Coords.decodePosKey(key)
		local block = getBlock(x, y, z)
		if block ~= nil and not Blocks.isStructureBlock(block) then
			r.structures[key] = nil
			removed += 1
		end
	end
	for key in r.jigsaws do
		local x, y, z = Coords.decodePosKey(key)
		local block = getBlock(x, y, z)
		if block ~= nil and not Blocks.isJigsaw(block) then
			r.jigsaws[key] = nil
			removed += 1
		end
	end
	if removed > 0 then
		r.version += 1
	end
	return removed
end

--[[
	The box { minX, minY, minZ, maxX, maxY, maxZ } (inclusive, world blocks) the structure block at
	(x, y, z) with `s` outlines, nil when it draws none (see the header). `mode` is the block's
	(Blocks.structureMode), which wins over the settings'.
]]
function StructureRecords.region(x: number, y: number, z: number, s: StructureSettings, mode: string?): { number }?
	local shown = mode or s.mode
	local size = s.size
	if size[1] < 1 or size[2] < 1 or size[3] < 1 then
		return nil
	end
	local ox, oy, oz = x + s.offset[1], y + s.offset[2], z + s.offset[3]
	if shown == "save" then
		return { ox, oy, oz, ox + size[1] - 1, oy + size[2] - 1, oz + size[3] - 1 }
	elseif shown == "load" and s.showBoundingBox then
		local mirror: Transform.Mirror = if s.mirror == "leftRight"
			then "leftRight"
			elseif s.mirror == "frontBack" then "frontBack"
			else "none"
		local dx, dz = Transform.anchor(size[1], size[3], s.rotation, mirror)
		return Transform.box(ox + dx, oy, oz + dz, size[1], size[2], size[3], s.rotation)
	end
	return nil
end

--[[
	The structure blocks with a region to outline within `range` blocks (sideways) of (x, z),
	nearest first, at most `limit`: { x, y, z, settings } each. Only blocks that are structure
	blocks (`getBlock`) count, in their block's mode. `override` (the screen being edited)
	replaces the record of its position, in the screen's mode, and counts even without a record.
]]
export type Outlined = { x: number, y: number, z: number, settings: StructureSettings }
function StructureRecords.outlined(
	r: Records,
	x: number,
	z: number,
	range: number,
	limit: number,
	getBlock: (x: number, y: number, z: number) -> number?,
	override: Outlined?
): { Outlined }
	local found: { Outlined } = {}
	local seen: { [number]: boolean } = {}
	-- (`edited`: the screen's settings, whose mode is the one being edited.)
	local function consider(bx: number, by: number, bz: number, s: StructureSettings, edited: boolean)
		local key = Coords.posKey(bx, by, bz)
		if seen[key] or math.abs(bx + 0.5 - x) > range or math.abs(bz + 0.5 - z) > range then
			return
		end
		seen[key] = true
		local block = getBlock(bx, by, bz)
		local mode = if block then Blocks.structureMode(block) else nil
		if mode and edited then
			mode = s.mode
		end
		if mode and StructureRecords.region(bx, by, bz, s, mode) then
			table.insert(found, { x = bx, y = by, z = bz, settings = s })
		end
	end
	if override then
		consider(override.x, override.y, override.z, override.settings, true)
	end
	for key, s in r.structures do
		local bx, by, bz = Coords.decodePosKey(key)
		consider(bx, by, bz, s, false)
	end
	table.sort(found, function(a, b)
		local da = (a.x - x) ^ 2 + (a.z - z) ^ 2
		local db = (b.x - x) ^ 2 + (b.z - z) ^ 2
		if da ~= db then
			return da < db
		end
		return Coords.posKey(a.x, a.y, a.z) < Coords.posKey(b.x, b.y, b.z)
	end)
	while #found > limit do
		table.remove(found)
	end
	return found
end

--[[ Outbox: messages paced per second ]]

export type Message = { kind: number, payload: buffer }

export type Outbox = {
	queue: { Message },
	tokens: number,
	rate: number,
	-- Queues messages; they go out in order.
	push: (self: Outbox, messages: { Message }) -> (),
	-- The messages that may go now, `dt` seconds after the last step.
	step: (self: Outbox, dt: number) -> { Message },
	pending: (self: Outbox) -> number,
	clear: (self: Outbox) -> (),
}

-- An outbox sending at most `rate` messages a second (a burst of `rate`).
function StructureRecords.outbox(rate: number): Outbox
	local box = { queue = {}, tokens = rate, rate = rate }
	function box.push(self: Outbox, messages: { Message })
		table.move(messages, 1, #messages, #self.queue + 1, self.queue)
	end
	function box.step(self: Outbox, dt: number): { Message }
		self.tokens = math.min(self.rate, self.tokens + dt * self.rate)
		local out = {}
		while self.tokens >= 1 and #self.queue > 0 do
			self.tokens -= 1
			table.insert(out, table.remove(self.queue, 1) :: Message)
		end
		return out
	end
	function box.pending(self: Outbox): number
		return #self.queue
	end
	function box.clear(self: Outbox)
		table.clear(self.queue)
	end
	return (box :: any) :: Outbox
end

--[[ Downloads: SAVE's text, per block ]]

-- A SAVE the player asked for whose text has not come: the block (Coords.posKey), the name and
-- size it sent and when (seconds, the caller's clock).
export type Expected = { key: number, name: string, size: { number }, at: number }

export type Downloads = {
	assemblies: { [number]: Protocol.StructureDataAssembly },
	-- Finished texts by structure block (Coords.posKey), the newest last in `order`.
	texts: { [number]: string },
	order: { number },
	-- The SAVEs whose texts have not come, oldest first.
	expected: { Expected },
	-- Notes the player asked block (x, y, z) to SAVE the structure `name` of `size` at `now`.
	expect: (self: Downloads, x: number, y: number, z: number, name: string, size: { number }, now: number) -> (),
	--[[
		Takes a piece (at `now`); returns the key of the block whose SAVE made it and its text once
		the text is whole, or an error.
	]]
	add: (self: Downloads, piece: Protocol.StructureDataPiece, now: number) -> (number?, string?, string?),
	text: (self: Downloads, x: number, y: number, z: number) -> string?,
}

-- Saved texts kept (one per block), SAVEs waiting for theirs at most, and how long (seconds).
StructureRecords.KEPT_DOWNLOADS = 4
StructureRecords.KEPT_EXPECTED = 8
StructureRecords.EXPECT_SECONDS = 30

-- Characters of an IVS1 text's head that hold its name and size (see `head`).
local HEAD_CHARS = 208

--[[
	The name and size at the head of IVS1 `text`, nil when it doesn't read. Structures/Template's
	format: "IVS1:", then base64url of varint version, varint body length, the name (varint
	length, bytes) and varint size x, y, z; at most 156 bytes, so only the head is decoded (a whole
	decode of a 48^3 build takes about a tenth of a second).
]]
local function head(text: string): (string?, { number }?)
	local prefix = Template.PREFIX
	if string.sub(text, 1, #prefix) ~= prefix then
		return nil, nil
	end
	local bytes = Template.unbase64(string.sub(text, #prefix + 1, #prefix + HEAD_CHARS))
	if bytes == nil then
		return nil, nil
	end
	local b: buffer = bytes
	local len, o = buffer.len(b), 0
	local function varint(): number?
		local value, scale = 0, 1
		for _ = 1, 5 do
			if o >= len then
				return nil
			end
			local byte = buffer.readu8(b, o)
			o += 1
			value += (byte % 128) * scale
			if byte < 128 then
				return value
			end
			scale *= 128
		end
		return nil
	end
	local version, body, n = varint(), varint(), varint()
	if version ~= Template.VERSION or body == nil or n == nil or o + n > len then
		return nil, nil
	end
	local name = buffer.readstring(b, o, n)
	o += n
	local sx, sy, sz = varint(), varint(), varint()
	if sx == nil or sy == nil or sz == nil then
		return nil, nil
	end
	return name, { sx, sy, sz }
end

--[[
	SAVE texts come back without their block, so each goes to the oldest SAVE still expected whose
	name and size are the text's (any when its head doesn't read). The server answers a player's
	SAVEs in order (one transfer after another), so the SAVEs expected before that one were refused
	or failed (rate limit, range, a bad region): they are forgotten, and so are SAVEs older than
	EXPECT_SECONDS.
]]
function StructureRecords.downloads(): Downloads
	local d = { assemblies = {}, texts = {}, order = {}, expected = {} }
	function d.expect(self: Downloads, x: number, y: number, z: number, name: string, size: { number }, now: number)
		if not valid(x, y, z) then
			return
		end
		table.insert(self.expected, { key = Coords.posKey(x, y, z), name = name, size = table.clone(size), at = now })
		while #self.expected > StructureRecords.KEPT_EXPECTED do
			table.remove(self.expected, 1)
		end
	end
	function d.add(self: Downloads, piece: Protocol.StructureDataPiece, now: number): (number?, string?, string?)
		local text, err = Protocol.joinStructureData(self.assemblies, piece)
		if err then
			return nil, nil, err
		end
		if text == nil then
			return nil, nil, nil
		end
		local expected = self.expected
		while expected[1] and now - expected[1].at > StructureRecords.EXPECT_SECONDS do
			table.remove(expected, 1)
		end
		local name, size = head(text)
		local found: number? = nil
		for i, e in expected do
			if
				name == nil
				or size == nil
				or (e.name == name and e.size[1] == size[1] and e.size[2] == size[2] and e.size[3] == size[3])
			then
				found = i
				break
			end
		end
		if found == nil then
			return nil, nil, nil
		end
		local key = expected[found].key
		for _ = 1, found do
			table.remove(expected, 1)
		end
		self.texts[key] = text
		local index = table.find(self.order, key)
		if index then
			table.remove(self.order, index)
		end
		table.insert(self.order, key)
		while #self.order > StructureRecords.KEPT_DOWNLOADS do
			self.texts[table.remove(self.order, 1) :: number] = nil
		end
		return key, text, nil
	end
	function d.text(self: Downloads, x: number, y: number, z: number): string?
		if not valid(x, y, z) then
			return nil
		end
		return self.texts[Coords.posKey(x, y, z)]
	end
	return (d :: any) :: Downloads
end

return StructureRecords
