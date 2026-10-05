--!strict
--[[
	Structure templates: what a structure block saves and what the structure library holds, in
	memory and as compact text ("IVS1").

	In memory (Template):
	  name        Minecraft-style name, slashes allowed ("outpost/houses/hut_1"); 1..128 letters,
	              digits and `_ . / : -` (Settings.validName)
	  size        { x, y, z }, each 1..MAX_SIZE (Config.Structures.MaxSize, 48)
	  palette     block ids: cell value i (1..#palette) is palette[i]; 0 is "keep" (a structure
	              void: leave the world as it is), which is never in the palette
	  cells       u16 per cell, x fastest, then z, then y: index = (y * sizeZ + z) * sizeX + x
	              (0-based coordinates), read with buffer.readu16(cells, index * 2)
	  jigsaws     jigsaw blocks (their cells hold the Jigsaw* block of their front and top too)
	              with their settings (Settings.JigsawSettings)
	  markers     DATA structure blocks: their position and data string (their cells are air)
	  containers  blocks with items (chests, furnaces, machines): position and slots. Item data
	              (Minecraft's NBT: a tank's water, a battery's charge) is not kept, nor are a
	              tool's enchantments; wear (`damage`) is
	Positions are local, 0-based from the template's minimum corner.

	As text: "IVS1:" followed by the payload in base64url (A-Z a-z 0-9 - _, no padding), so it
	pastes into chat and into a Luau string literal as it is. `decode` ignores whitespace anywhere
	(wrapped pastes) and quotes around the whole text. The payload is a byte stream of LEB128
	varints (unsigned) and strings (a varint byte length, then UTF-8):

	  varint   version (1)
	  varint   body length: the bytes from the next one up to the checksum (so a cut paste is
	           reported as cut, with how much is missing)
	  body:
	    string   name
	    varint   size x, y, z
	    varint   palette count (at most MAX_PALETTE), then that many strings: block names (names
	             survive id changes; a name this game doesn't know decodes to air, with a warning)
	    varint   cell encoding, the smaller of:
	               0 runs:   pairs of varint palette index (0 = keep) and varint run length (1+),
	                         covering every cell in index order exactly
	               1 packed: u8 bits per cell (1..16), then the cells' indices packed in that many
	                         bits each, lowest bit first (a busy build with no long runs)
	    varint   jigsaw count, each: varint x, y, z, u8 orientation (front * 6 + top, directions
	             numbered Down 0, Up 1, North 2, South 3, West 4, East 5), string name, target,
	             pool, final state, u8 joint (0 rollable, 1 aligned)
	    varint   marker count, each: varint x, y, z, string data
	    varint   container count, each: varint x, y, z, varint item count, each: varint slot
	             (1-based), string item name, varint count (1..64), varint damage
	  u32      CRC-32 (IEEE) of every byte before it, little endian
	Records are written sorted by cell index and items by slot, so equal templates encode alike.

	`decode` never errors: it returns nil and a message for the player for anything malformed (a
	cut or mistyped paste, a wrong checksum, positions outside the box, duplicates, strings and
	counts over their caps), and its warnings (unknown blocks and items) as a third value.

	Also: `capture` builds a template from the world with the structure block's SAVE rules,
	`toTable` / `fromTable` convert to and from an editable table with one character per block in
	ASCII layers (tests/structure, builder scripts), and `get`, `set`, `count`, `counts`, `check`,
	`equal`, `clone` work on templates.
]]

local Blocks = require(script.Parent.Parent.Blocks)
local Config = require(script.Parent.Parent.Config)
local Items = require(script.Parent.Parent.Items)
local Settings = require(script.Parent.Settings)

export type Jigsaw = {
	x: number,
	y: number,
	z: number,
	front: string,
	top: string,
	name: string,
	target: string,
	pool: string,
	finalState: string,
	joint: string,
}
export type Marker = { x: number, y: number, z: number, data: string }
export type ContainerItem = { slot: number, item: string, count: number, damage: number }
export type Container = { x: number, y: number, z: number, items: { ContainerItem } }
export type Template = {
	name: string,
	size: { number },
	palette: { number },
	cells: buffer,
	jigsaws: { Jigsaw },
	markers: { Marker },
	containers: { Container },
}

-- What `capture` reads the world with (positions are world blocks).
export type CaptureOptions = {
	name: string,
	-- The region's minimum corner and size.
	x: number,
	y: number,
	z: number,
	size: { number },
	-- The block at a position; nil (not loaded) is saved as air.
	getBlock: (x: number, y: number, z: number) -> number?,
	-- A jigsaw's settings (nil: the defaults for its front).
	jigsaw: ((x: number, y: number, z: number) -> Settings.JigsawSettings?)?,
	-- A DATA structure block's data string (nil: "").
	marker: ((x: number, y: number, z: number) -> string?)?,
	-- What a block with slots holds (nil or empty: no record).
	container: ((x: number, y: number, z: number) -> { ContainerItem }?)?,
}

local Template = {}

Template.VERSION = 1
Template.PREFIX = "IVS1:"
Template.MAX_SIZE = Config.Structures.MaxSize
Template.MAX_NAME = Settings.MAX_NAME
-- Jigsaw names, targets, pools, final states and marker data.
Template.MAX_STRING = 128
-- Block and item names.
Template.MAX_BLOCK_NAME = 64
Template.MAX_PALETTE = 1024
Template.MAX_JIGSAWS = 1024
Template.MAX_MARKERS = 1024
Template.MAX_CONTAINERS = 1024
-- Items in one container, and in all of them together; slots are 1..MAX_SLOT.
Template.MAX_CONTAINER_ITEMS = 64
Template.MAX_ITEMS = 4096
Template.MAX_SLOT = 255
Template.MAX_STACK = 64
Template.MAX_DAMAGE = 65535
-- Longest text `decode` reads (characters, whitespace included) and payload (bytes): far above
-- any real structure (a busy 48 x 48 x 48 one is ~150,000 characters), so these only stop junk.
Template.MAX_TEXT = 3000000
Template.MAX_PAYLOAD = 2097152

Template.DIRECTIONS = table.freeze({ "Down", "Up", "North", "South", "West", "East" })
local DIRECTION_CODE: { [string]: number } = {}
for code, name in Template.DIRECTIONS do
	DIRECTION_CODE[name] = code - 1
end
local JOINT_CODE: { [string]: number } = { rollable = 0, aligned = 1 }
local JOINTS = { [0] = "rollable", [1] = "aligned" }

local AIR = Blocks.AIR

--[[ Templates in memory ]]

-- A new template of `size` ({ x, y, z }) holding "keep" in every cell.
function Template.new(name: string, size: { number }): Template
	local sx, sy, sz = size[1], size[2], size[3]
	for k = 1, 3 do
		local n = size[k]
		assert(n == math.floor(n) and n >= 1 and n <= Template.MAX_SIZE, `Bad template size {sx} x {sy} x {sz}`)
	end
	return {
		name = name,
		size = { sx, sy, sz },
		palette = {},
		cells = buffer.create(sx * sy * sz * 2),
		jigsaws = {},
		markers = {},
		containers = {},
	}
end

-- Is (x, y, z) a cell of `t`?
function Template.inside(t: Template, x: number, y: number, z: number): boolean
	local s = t.size
	return x >= 0
		and y >= 0
		and z >= 0
		and x < s[1]
		and y < s[2]
		and z < s[3]
		and x == math.floor(x)
		and y == math.floor(y)
		and z == math.floor(z)
end

-- The cell index of (x, y, z) (0-based; the u16 is at index * 2).
function Template.index(t: Template, x: number, y: number, z: number): number
	local s = t.size
	return (y * s[3] + z) * s[1] + x
end

-- The block at (x, y, z), nil for "keep" or outside the template.
function Template.get(t: Template, x: number, y: number, z: number): number?
	if not Template.inside(t, x, y, z) then
		return nil
	end
	local p = buffer.readu16(t.cells, Template.index(t, x, y, z) * 2)
	if p == 0 then
		return nil
	end
	return t.palette[p]
end

-- Palette index of each block per template (rebuilt when the palette changed under it).
local paletteIndex: { [Template]: { n: number, of: { [number]: number } } } = setmetatable({} :: any, { __mode = "k" })

local function indexOf(t: Template, block: number): number
	local cache = paletteIndex[t]
	if cache == nil or cache.n ~= #t.palette then
		local of = {}
		for i, id in t.palette do
			if of[id] == nil then
				of[id] = i
			end
		end
		cache = { n = #t.palette, of = of }
		paletteIndex[t] = cache
	end
	local index = cache.of[block]
	if index == nil then
		table.insert(t.palette, block)
		index = #t.palette
		assert(index <= 65535, "Too many blocks in one template")
		cache.of[block] = index
		cache.n = index
	end
	return index
end

-- Sets (x, y, z) to `block` (nil: "keep"). Outside the template it does nothing.
function Template.set(t: Template, x: number, y: number, z: number, block: number?)
	if not Template.inside(t, x, y, z) then
		return
	end
	local p = if block == nil then 0 else indexOf(t, block)
	buffer.writeu16(t.cells, Template.index(t, x, y, z) * 2, p)
end

-- How many cells hold a block other than air ("keep" and air don't count): what a structure
-- block reports as "N blocks".
function Template.count(t: Template): number
	local cells = t.cells
	local palette = t.palette
	local n = 0
	for i = 0, buffer.len(cells) // 2 - 1 do
		local p = buffer.readu16(cells, i * 2)
		if p ~= 0 and palette[p] ~= AIR then
			n += 1
		end
	end
	return n
end

-- How many cells hold each block (air included), and how many are "keep".
function Template.counts(t: Template): ({ [number]: number }, number)
	local counts: { [number]: number } = {}
	local keep = 0
	local palette = t.palette
	local cells = t.cells
	for i = 0, buffer.len(cells) // 2 - 1 do
		local p = buffer.readu16(cells, i * 2)
		if p == 0 then
			keep += 1
		else
			local id = palette[p]
			counts[id] = (counts[id] or 0) + 1
		end
	end
	return counts, keep
end

-- A deep copy of `t`.
function Template.clone(t: Template): Template
	local copy = buffer.create(buffer.len(t.cells))
	buffer.copy(copy, 0, t.cells)
	local jigsaws = {}
	for i, j in t.jigsaws do
		jigsaws[i] = table.clone(j)
	end
	local markers = {}
	for i, m in t.markers do
		markers[i] = table.clone(m)
	end
	local containers = {}
	for i, c in t.containers do
		local items = {}
		for k, item in c.items do
			items[k] = table.clone(item)
		end
		containers[i] = { x = c.x, y = c.y, z = c.z, items = items }
	end
	return {
		name = t.name,
		size = table.clone(t.size),
		palette = table.clone(t.palette),
		cells = copy,
		jigsaws = jigsaws,
		markers = markers,
		containers = containers,
	}
end

-- Records sorted by cell index (copies of the lists).
local function sortedByCell<T>(t: Template, list: { T }): { T }
	local sorted = table.clone(list)
	table.sort(sorted, function(a: any, b: any)
		return Template.index(t, a.x, a.y, a.z) < Template.index(t, b.x, b.y, b.z)
	end)
	return sorted
end

local function sortedItems(items: { ContainerItem }): { ContainerItem }
	local sorted = table.clone(items)
	table.sort(sorted, function(a, b)
		return a.slot < b.slot
	end)
	return sorted
end

--[[
	Do `a` and `b` hold the same structure: name, size, the block (or keep) in every cell, and the
	same jigsaws, markers and containers in any order? Palettes may differ. Returns the first
	difference as a message when they don't.
]]
function Template.equal(a: Template, b: Template): (boolean, string?)
	if a.name ~= b.name then
		return false, `name {a.name} ~= {b.name}`
	end
	for k = 1, 3 do
		if a.size[k] ~= b.size[k] then
			return false, "size"
		end
	end
	for i = 0, buffer.len(a.cells) // 2 - 1 do
		local pa, pb = buffer.readu16(a.cells, i * 2), buffer.readu16(b.cells, i * 2)
		local ba = if pa == 0 then nil else a.palette[pa]
		local bb = if pb == 0 then nil else b.palette[pb]
		if ba ~= bb then
			return false, `cell {i}: {ba} ~= {bb}`
		end
	end
	local function same(listA: { any }, listB: { any }, what: string): string?
		if #listA ~= #listB then
			return `{what} count {#listA} ~= {#listB}`
		end
		local sa, sb = sortedByCell(a, listA), sortedByCell(b, listB)
		for i, ra in sa do
			local rb = sb[i]
			for key, value in ra do
				if key == "items" then
					local ia, ib = sortedItems(value), sortedItems(rb.items)
					if #ia ~= #ib then
						return `{what} {i} item count`
					end
					for k, item in ia do
						local other = ib[k]
						if
							item.slot ~= other.slot
							or item.item ~= other.item
							or item.count ~= other.count
							or item.damage ~= other.damage
						then
							return `{what} {i} item {k}`
						end
					end
				elseif rb[key] ~= value then
					return `{what} {i} {key}: {value} ~= {rb[key]}`
				end
			end
		end
		return nil
	end
	local problem = same(a.jigsaws, b.jigsaws, "jigsaw")
		or same(a.markers, b.markers, "marker")
		or same(a.containers, b.containers, "container")
	if problem then
		return false, problem
	end
	return true, nil
end

local function validString(value: any, cap: number): boolean
	return type(value) == "string" and #value <= cap and utf8.len(value) ~= nil
end

--[[
	What is wrong with `t` (nil: nothing): a bad name or size, palette entries that are no block
	or cells beyond the palette, records outside the box or on the same cell, jigsaws whose cell
	doesn't hold their block, bad orientations, joints, strings, slots, counts or caps. Every
	template `decode` returns passes; `encode` refuses one that doesn't.
]]
function Template.check(t: Template): string?
	if not Settings.validName(t.name) or t.name == "" then
		return `bad name '{t.name}'`
	end
	local size = t.size
	if type(size) ~= "table" or #size ~= 3 then
		return "bad size"
	end
	for k = 1, 3 do
		local n = size[k]
		if type(n) ~= "number" or n ~= math.floor(n) or n < 1 or n > Template.MAX_SIZE then
			return "bad size"
		end
	end
	if buffer.len(t.cells) ~= size[1] * size[2] * size[3] * 2 then
		return "the cells don't match the size"
	end
	if #t.palette > Template.MAX_PALETTE then
		return "too many kinds of blocks"
	end
	for _, id in t.palette do
		if not Blocks.isValid(id) then
			return `unknown block {id} in the palette`
		end
	end
	local n = #t.palette
	for i = 0, buffer.len(t.cells) // 2 - 1 do
		if buffer.readu16(t.cells, i * 2) > n then
			return `cell {i} is beyond the palette`
		end
	end
	local taken: { [string]: { [number]: boolean } } = { jigsaw = {}, marker = {}, container = {} }
	local function place(what: string, r: { x: number, y: number, z: number }): string?
		if not Template.inside(t, r.x, r.y, r.z) then
			return `{what} at {r.x}, {r.y}, {r.z} is outside the structure`
		end
		local index = Template.index(t, r.x, r.y, r.z)
		if taken[what][index] then
			return `two {what}s at {r.x}, {r.y}, {r.z}`
		end
		taken[what][index] = true
		return nil
	end
	if #t.jigsaws > Template.MAX_JIGSAWS then
		return "too many jigsaws"
	end
	for _, j in t.jigsaws do
		local problem = place("jigsaw", j)
		if problem then
			return problem
		end
		local block = Blocks.jigsawBlock(j.front, j.top)
		if block == nil then
			return `jigsaw at {j.x}, {j.y}, {j.z} has a bad orientation`
		elseif Template.get(t, j.x, j.y, j.z) ~= block then
			return `jigsaw at {j.x}, {j.y}, {j.z} is not in its cell`
		elseif JOINT_CODE[j.joint] == nil then
			return `jigsaw at {j.x}, {j.y}, {j.z} has a bad joint`
		end
		for _, field in { "name", "target", "pool", "finalState" } do
			if not validString((j :: any)[field], Template.MAX_STRING) then
				return `jigsaw at {j.x}, {j.y}, {j.z} has a bad {field}`
			end
		end
	end
	if #t.markers > Template.MAX_MARKERS then
		return "too many data markers"
	end
	for _, m in t.markers do
		local problem = place("marker", m)
		if problem then
			return problem
		elseif not validString(m.data, Template.MAX_STRING) then
			return `marker at {m.x}, {m.y}, {m.z} has bad data`
		end
	end
	if #t.containers > Template.MAX_CONTAINERS then
		return "too many containers"
	end
	local items = 0
	for _, c in t.containers do
		local problem = place("container", c)
		if problem then
			return problem
		end
		if #c.items > Template.MAX_CONTAINER_ITEMS then
			return `container at {c.x}, {c.y}, {c.z} holds too many stacks`
		end
		items += #c.items
		local slots: { [number]: boolean } = {}
		for _, item in c.items do
			local slot, count, damage = item.slot, item.count, item.damage
			if
				type(slot) ~= "number"
				or slot ~= math.floor(slot)
				or slot < 1
				or slot > Template.MAX_SLOT
				or slots[slot]
			then
				return `container at {c.x}, {c.y}, {c.z} has a bad slot`
			end
			slots[slot] = true
			if type(count) ~= "number" or count ~= math.floor(count) or count < 1 or count > Template.MAX_STACK then
				return `container at {c.x}, {c.y}, {c.z} has a bad count`
			elseif
				type(damage) ~= "number"
				or damage ~= math.floor(damage)
				or damage < 0
				or damage > Template.MAX_DAMAGE
			then
				return `container at {c.x}, {c.y}, {c.z} has a bad damage`
			elseif not validString(item.item, Template.MAX_BLOCK_NAME) then
				return `container at {c.x}, {c.y}, {c.z} has a bad item name`
			end
		end
	end
	if items > Template.MAX_ITEMS then
		return "too many items in containers"
	end
	return nil
end

--[[ Capturing the world (a structure block's SAVE) ]]

--[[
	A template of the region `options` describes, with Minecraft's SAVE rules:
	  * air is saved as air (it clears the world where the structure is placed), and a Structure
	    Void as "keep" (it leaves the world alone there);
	  * a DATA structure block becomes a data marker with its string, and air; other structure
	    blocks are saved as air;
	  * jigsaws keep their block and get a record with their settings;
	  * cave air is saved as air and cave twins as their twin (Blocks.surfaceForm);
	  * blocks with slots get a container record with their items (if any).
	Positions in the records are local. Returns the template and warnings (records over the caps
	are left out).
]]
function Template.capture(options: CaptureOptions): (Template, { string })
	local t = Template.new(options.name, options.size)
	local warnings: { string } = {}
	local ox, oy, oz = options.x, options.y, options.z
	local sx, sy, sz = t.size[1], t.size[2], t.size[3]
	local void = Blocks.id.StructureVoid
	local items = 0
	for y = 0, sy - 1 do
		for z = 0, sz - 1 do
			for x = 0, sx - 1 do
				local wx, wy, wz = ox + x, oy + y, oz + z
				local block = options.getBlock(wx, wy, wz) or AIR
				if not Blocks.isValid(block) then
					block = AIR
				end
				local saved: number? = Blocks.surfaceForm(block)
				local def = Blocks.get(block)
				if block == void then
					saved = nil
				elseif def.structureMode then
					saved = AIR
					if def.structureMode == "data" then
						if #t.markers < Template.MAX_MARKERS then
							local data = if options.marker then options.marker(wx, wy, wz) else nil
							table.insert(t.markers, {
								x = x,
								y = y,
								z = z,
								data = Settings.cut(if type(data) == "string" then data else "", Template.MAX_STRING),
							})
						else
							table.insert(warnings, `Too many data markers: the one at {wx}, {wy}, {wz} is left out`)
						end
					end
				elseif def.jigsaw then
					if #t.jigsaws < Template.MAX_JIGSAWS then
						local front, top = def.jigsaw.front, def.jigsaw.top
						local raw = if options.jigsaw then options.jigsaw(wx, wy, wz) else nil
						local settings = Settings.clampJigsaw(raw, front)
						table.insert(t.jigsaws, {
							x = x,
							y = y,
							z = z,
							front = front,
							top = top,
							name = settings.name,
							target = settings.target,
							pool = settings.pool,
							finalState = settings.finalState,
							joint = settings.joint,
						})
					else
						saved = AIR
						table.insert(warnings, `Too many jigsaws: the one at {wx}, {wy}, {wz} is saved as air`)
					end
				elseif (def.container > 0 or def.machine ~= nil) and options.container then
					local list = options.container(wx, wy, wz)
					if list and #list > 0 then
						local kept: { ContainerItem } = {}
						local slots: { [number]: boolean } = {}
						for _, item in list do
							local slot = math.floor(tonumber(item.slot) or 0)
							local count = math.floor(tonumber(item.count) or 0)
							if
								slot >= 1
								and slot <= Template.MAX_SLOT
								and not slots[slot]
								and count >= 1
								and type(item.item) == "string"
								and Items.isValid(rawget(Items.id :: any, item.item) or -1)
								and #kept < Template.MAX_CONTAINER_ITEMS
								and items < Template.MAX_ITEMS
							then
								slots[slot] = true
								items += 1
								table.insert(kept, {
									slot = slot,
									item = item.item,
									count = math.min(count, Template.MAX_STACK),
									damage = math.clamp(math.floor(tonumber(item.damage) or 0), 0, Template.MAX_DAMAGE),
								})
							end
						end
						if #kept < #list then
							table.insert(warnings, `Some items in the container at {wx}, {wy}, {wz} are left out`)
						end
						if #kept > 0 then
							if #t.containers < Template.MAX_CONTAINERS then
								table.sort(kept, function(a, b)
									return a.slot < b.slot
								end)
								table.insert(t.containers, { x = x, y = y, z = z, items = kept })
							else
								table.insert(
									warnings,
									`Too many containers: the items at {wx}, {wy}, {wz} are left out`
								)
							end
						end
					end
				end
				Template.set(t, x, y, z, saved)
			end
		end
	end
	return t, warnings
end

--[[ Bytes: varints, strings, CRC-32, base64url ]]

-- A growable byte buffer.
type Writer = { b: buffer, n: number }

local function newWriter(capacity: number): Writer
	return { b = buffer.create(math.max(capacity, 64)), n = 0 }
end

local function reserve(w: Writer, bytes: number)
	local need = w.n + bytes
	local size = buffer.len(w.b)
	if need > size then
		while size < need do
			size *= 2
		end
		local grown = buffer.create(size)
		buffer.copy(grown, 0, w.b, 0, w.n)
		w.b = grown
	end
end

local function writeByte(w: Writer, value: number)
	reserve(w, 1)
	buffer.writeu8(w.b, w.n, value)
	w.n += 1
end

local function writeVarint(w: Writer, value: number)
	assert(value >= 0 and value == math.floor(value) and value < 2 ^ 35, "varint out of range")
	reserve(w, 5)
	while value >= 128 do
		buffer.writeu8(w.b, w.n, value % 128 + 128)
		w.n += 1
		value = value // 128
	end
	buffer.writeu8(w.b, w.n, value)
	w.n += 1
end

local function varintSize(value: number): number
	local n = 1
	while value >= 128 do
		value = value // 128
		n += 1
	end
	return n
end

local function writeString(w: Writer, value: string)
	writeVarint(w, #value)
	reserve(w, #value)
	buffer.writestring(w.b, w.n, value)
	w.n += #value
end

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
function Template.crc32(b: buffer, from: number, to: number): number
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
-- Bytes `decode` cuts off the end of a text: whitespace and closing quotes.
local TRAILING: { [number]: boolean } = {}
for _, c in { " ", "\t", "\n", "\r", "\v", "\f" } do
	buffer.writeu8(DECODE, string.byte(c), WHITESPACE)
	TRAILING[string.byte(c)] = true
end
for _, c in { '"', "'", "`" } do
	TRAILING[string.byte(c)] = true
end

-- The first `n` bytes of `data` in base64url without padding.
function Template.base64(data: buffer, n: number?): string
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
function Template.unbase64(text: string, from: number?): (buffer?, string?)
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

--[[ Encoding ]]

-- Bits holding indices 0..n.
local function bitsFor(n: number): number
	local bits = 1
	while 2 ^ bits <= n do
		bits += 1
	end
	return bits
end

--[[
	`t` as IVS1 text. Unused palette entries are left out and records are sorted, so equal
	templates give equal text. Errors when `t` breaks the format's rules (Template.check says
	which): templates from `new`, `capture`, `decode` and `fromTable` are fine as long as their
	records stay within the caps.
]]
function Template.encode(t: Template): string
	local problem = Template.check(t)
	if problem then
		error(`Template.encode: {problem}`, 2)
	end
	local size = t.size
	local volume = size[1] * size[2] * size[3]
	local cells = t.cells

	-- The used palette entries in order of first use, numbered from 1; distinct ids only.
	local remap: { [number]: number } = {}
	local used: { number } = {}
	local byId: { [number]: number } = {}
	for i = 0, volume - 1 do
		local p = buffer.readu16(cells, i * 2)
		if p ~= 0 and remap[p] == nil then
			local id = t.palette[p]
			local index = byId[id]
			if index == nil then
				table.insert(used, id)
				index = #used
				byId[id] = index
			end
			remap[p] = index
		end
	end
	remap[0] = 0

	-- Runs, and what each encoding costs.
	local runs: { number } = {}
	local runBytes = 0
	local i = 0
	while i < volume do
		local p = remap[buffer.readu16(cells, i * 2)]
		local j = i + 1
		while j < volume and remap[buffer.readu16(cells, j * 2)] == p do
			j += 1
		end
		table.insert(runs, p)
		table.insert(runs, j - i)
		runBytes += varintSize(p) + varintSize(j - i)
		i = j
	end
	local bits = bitsFor(#used)
	local packedBytes = 1 + (volume * bits + 7) // 8

	local w = newWriter(256 + math.min(runBytes, packedBytes))
	writeString(w, t.name)
	for k = 1, 3 do
		writeVarint(w, size[k])
	end
	writeVarint(w, #used)
	for _, id in used do
		writeString(w, Blocks.get(id).name)
	end
	if runBytes <= packedBytes then
		writeVarint(w, 0)
		for r = 1, #runs do
			writeVarint(w, runs[r])
		end
	else
		writeVarint(w, 1)
		writeByte(w, bits)
		reserve(w, packedBytes - 1)
		local acc, have = 0, 0
		for c = 0, volume - 1 do
			acc += remap[buffer.readu16(cells, c * 2)] * 2 ^ have
			have += bits
			while have >= 8 do
				local byte = acc % 256
				buffer.writeu8(w.b, w.n, byte)
				w.n += 1
				acc = (acc - byte) / 256
				have -= 8
			end
		end
		if have > 0 then
			buffer.writeu8(w.b, w.n, acc)
			w.n += 1
		end
	end

	local jigsaws = sortedByCell(t, t.jigsaws)
	writeVarint(w, #jigsaws)
	for _, j in jigsaws do
		writeVarint(w, j.x)
		writeVarint(w, j.y)
		writeVarint(w, j.z)
		writeByte(w, DIRECTION_CODE[j.front] * 6 + DIRECTION_CODE[j.top])
		writeString(w, j.name)
		writeString(w, j.target)
		writeString(w, j.pool)
		writeString(w, j.finalState)
		writeByte(w, JOINT_CODE[j.joint])
	end
	local markers = sortedByCell(t, t.markers)
	writeVarint(w, #markers)
	for _, m in markers do
		writeVarint(w, m.x)
		writeVarint(w, m.y)
		writeVarint(w, m.z)
		writeString(w, m.data)
	end
	local containers = sortedByCell(t, t.containers)
	writeVarint(w, #containers)
	for _, c in containers do
		writeVarint(w, c.x)
		writeVarint(w, c.y)
		writeVarint(w, c.z)
		local items = sortedItems(c.items)
		writeVarint(w, #items)
		for _, item in items do
			writeVarint(w, item.slot)
			writeString(w, item.item)
			writeVarint(w, item.count)
			writeVarint(w, item.damage)
		end
	end

	-- Version, body length, body, checksum.
	local out = newWriter(w.n + 16)
	writeVarint(out, Template.VERSION)
	writeVarint(out, w.n)
	reserve(out, w.n + 4)
	buffer.copy(out.b, out.n, w.b, 0, w.n)
	out.n += w.n
	buffer.writeu32(out.b, out.n, Template.crc32(out.b, 0, out.n))
	out.n += 4
	return Template.PREFIX .. Template.base64(out.b, out.n)
end

--[[ Decoding ]]

-- Raised inside `decode` with a message for the player.
type Failure = { failure: string }

local function fail(message: string): never
	error({ failure = message } :: Failure, 0)
end

type Reader = { b: buffer, o: number, len: number }

local function readByte(r: Reader): number
	if r.o >= r.len then
		fail("The structure data ends too early")
	end
	local v = buffer.readu8(r.b, r.o)
	r.o += 1
	return v
end

-- A varint of at most 5 bytes (values below 2^35).
local function readVarint(r: Reader): number
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

local function readCount(r: Reader, cap: number, what: string): number
	local n = readVarint(r)
	if n > cap then
		fail(`The structure has too many {what} ({n}, at most {cap})`)
	end
	return n
end

local function readString(r: Reader, cap: number, what: string): string
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

-- A position inside the template (varint x, y, z).
local function readPosition(r: Reader, t: Template, what: string): (number, number, number)
	local x, y, z = readVarint(r), readVarint(r), readVarint(r)
	if not Template.inside(t, x, y, z) then
		fail(`The structure has a {what} outside its box ({x}, {y}, {z})`)
	end
	return x, y, z
end

local function decodeBody(r: Reader, warnings: { string }): Template
	local name = readString(r, Template.MAX_NAME, "name")
	if name == "" or not Settings.validName(name) then
		fail(`The structure's name '{name}' is not a valid name`)
	end
	local size = { readVarint(r), readVarint(r), readVarint(r) }
	for k = 1, 3 do
		if size[k] < 1 or size[k] > Template.MAX_SIZE then
			fail(`The structure's size {size[1]} x {size[2]} x {size[3]} is outside 1..{Template.MAX_SIZE}`)
		end
	end
	local t = Template.new(name, size)
	local volume = size[1] * size[2] * size[3]

	-- The palette, with unknown names as air and repeated blocks merged.
	local count = readCount(r, Template.MAX_PALETTE, "kinds of blocks")
	local remap: { number } = table.create(count + 1, 0)
	local unknown: { [string]: boolean } = {}
	for p = 1, count do
		local blockName = readString(r, Template.MAX_BLOCK_NAME, "block name")
		local found = Blocks.find(blockName)
		if found == nil and not unknown[blockName] then
			unknown[blockName] = true
			table.insert(warnings, `Unknown block '{blockName}' was replaced by air`)
		end
		remap[p + 1] = indexOf(t, found or AIR)
	end

	local cells = t.cells
	local mode = readVarint(r)
	if mode == 0 then
		local i = 0
		while i < volume do
			local p = readVarint(r)
			local length = readVarint(r)
			if p > count then
				fail(`The structure has a block beyond its palette ({p} of {count})`)
			elseif length < 1 or i + length > volume then
				fail("The structure's blocks don't fill its box exactly")
			end
			local value = remap[p + 1]
			for c = i, i + length - 1 do
				buffer.writeu16(cells, c * 2, value)
			end
			i += length
		end
	elseif mode == 1 then
		local bits = readByte(r)
		if bits < 1 or bits > 16 then
			fail("The structure's blocks are packed in a way this game doesn't know")
		end
		local bytes = (volume * bits + 7) // 8
		if r.o + bytes > r.len then
			fail("The structure data ends too early")
		end
		local acc, have = 0, 0
		local o = r.o
		local mask = 2 ^ bits
		for c = 0, volume - 1 do
			while have < bits do
				acc += buffer.readu8(r.b, o) * 2 ^ have
				o += 1
				have += 8
			end
			local p = acc % mask
			acc = (acc - p) / mask
			have -= bits
			if p > count then
				fail(`The structure has a block beyond its palette ({p} of {count})`)
			end
			buffer.writeu16(cells, c * 2, remap[p + 1])
		end
		r.o += bytes
	else
		fail("The structure's blocks are stored in a way this game doesn't know")
	end

	local taken: { [number]: boolean } = {}
	local jigsawCount = readCount(r, Template.MAX_JIGSAWS, "jigsaws")
	for _ = 1, jigsawCount do
		local x, y, z = readPosition(r, t, "jigsaw")
		local code = readByte(r)
		local front, top = Template.DIRECTIONS[code // 6 + 1], Template.DIRECTIONS[code % 6 + 1]
		local block = if front and top then Blocks.jigsawBlock(front, top) else nil
		if block == nil or front == nil or top == nil then
			fail(`The structure has a jigsaw with a bad orientation at {x}, {y}, {z}`)
		end
		local jigsaw: Jigsaw = {
			x = x,
			y = y,
			z = z,
			front = front,
			top = top,
			name = readString(r, Template.MAX_STRING, "jigsaw name"),
			target = readString(r, Template.MAX_STRING, "jigsaw target"),
			pool = readString(r, Template.MAX_STRING, "jigsaw pool"),
			finalState = readString(r, Template.MAX_STRING, "jigsaw final state"),
			joint = JOINTS[readByte(r)] or fail(`The structure has a jigsaw with a bad joint at {x}, {y}, {z}`),
		}
		local index = Template.index(t, x, y, z)
		if taken[index] then
			fail(`The structure has two jigsaws at {x}, {y}, {z}`)
		end
		taken[index] = true
		-- (Only when its cell holds its block: an unknown block name made it air, say.)
		if Template.get(t, x, y, z) == block then
			table.insert(t.jigsaws, jigsaw)
		else
			table.insert(warnings, `The jigsaw at {x}, {y}, {z} is not in its cell and was left out`)
		end
	end

	table.clear(taken)
	local markerCount = readCount(r, Template.MAX_MARKERS, "data markers")
	for _ = 1, markerCount do
		local x, y, z = readPosition(r, t, "data marker")
		local data = readString(r, Template.MAX_STRING, "data marker")
		local index = Template.index(t, x, y, z)
		if taken[index] then
			fail(`The structure has two data markers at {x}, {y}, {z}`)
		end
		taken[index] = true
		table.insert(t.markers, { x = x, y = y, z = z, data = data })
	end

	table.clear(taken)
	local items = 0
	local containerCount = readCount(r, Template.MAX_CONTAINERS, "containers")
	for _ = 1, containerCount do
		local x, y, z = readPosition(r, t, "container")
		local index = Template.index(t, x, y, z)
		if taken[index] then
			fail(`The structure has two containers at {x}, {y}, {z}`)
		end
		taken[index] = true
		local n = readCount(r, Template.MAX_CONTAINER_ITEMS, "stacks in one container")
		items += n
		if items > Template.MAX_ITEMS then
			fail(`The structure has too many items in containers (at most {Template.MAX_ITEMS})`)
		end
		local list: { ContainerItem } = {}
		local slots: { [number]: boolean } = {}
		for _ = 1, n do
			local slot = readVarint(r)
			local item = readString(r, Template.MAX_BLOCK_NAME, "item name")
			local stack = readVarint(r)
			local damage = readVarint(r)
			if slot < 1 or slot > Template.MAX_SLOT or slots[slot] then
				fail(`The structure has a container with a bad slot at {x}, {y}, {z}`)
			elseif stack < 1 or stack > Template.MAX_STACK or damage > Template.MAX_DAMAGE then
				fail(`The structure has a container with a bad stack at {x}, {y}, {z}`)
			end
			slots[slot] = true
			if rawget(Items.id :: any, item) == nil then
				table.insert(warnings, `Unknown item '{item}' in the container at {x}, {y}, {z} was left out`)
			else
				table.insert(list, { slot = slot, item = item, count = stack, damage = damage })
			end
		end
		if #list > 0 then
			table.insert(t.containers, { x = x, y = y, z = z, items = list })
		end
	end
	return t
end

--[[
	The template in IVS1 `text`, or nil and a message for the player. Never errors. Whitespace
	anywhere and quotes (" ' `) around the whole text are ignored. The third value lists warnings
	(unknown blocks replaced by air, unknown items left out).
]]
function Template.decode(text: any): (Template?, string?, { string }?)
	if type(text) ~= "string" then
		return nil, "No structure data", nil
	end
	if #text > Template.MAX_TEXT then
		return nil, `The structure data is too long ({#text} characters, at most {Template.MAX_TEXT})`, nil
	end
	-- The prefix, after whitespace and an opening quote.
	local first, last = string.find(text, "^[%s\"'`]*IVS1:")
	if first == nil or last == nil then
		if string.find(text, "^[%s\"'`]*IVS%d+:") then
			return nil, "The structure data is from a newer version of this game", nil
		end
		return nil, "That is not structure data: it starts with IVS1:", nil
	end
	-- (A closing quote and whitespace after the data, cut by a backward scan: a pattern anchored
	-- at the end would rescan every whitespace run inside the text to its end, quadratic.)
	local stop = #text
	while stop > last and TRAILING[string.byte(text, stop)] do
		stop -= 1
	end
	local payload, problem = Template.unbase64(string.sub(text, last + 1, stop))
	if payload == nil then
		return nil, problem, nil
	end
	local len = buffer.len(payload)
	if len > Template.MAX_PAYLOAD then
		return nil, "The structure data is too long", nil
	end
	local warnings: { string } = {}
	local ok, result = pcall(function(): Template
		local r: Reader = { b = payload, o = 0, len = len }
		-- (Junk after the prefix usually fails here: say so plainly.)
		local headerOk, version, bodyLength = pcall(function(): (number, number)
			return readVarint(r), readVarint(r)
		end)
		if not headerOk then
			fail("The structure data is damaged or cut off")
		end
		if version > Template.VERSION then
			fail(`The structure data is from a newer version of this game (format {version})`)
		elseif version ~= Template.VERSION then
			fail(`That is not structure data this game knows (format {version})`)
		end
		local expected = r.o + bodyLength + 4
		if bodyLength > Template.MAX_PAYLOAD then
			fail("The structure data is too long")
		elseif len < expected then
			fail(`The structure data is cut off: it has {len} of its {expected} bytes. Copy all of it`)
		elseif len > expected then
			fail("The structure data has something extra at its end (two pasted together?)")
		end
		if buffer.readu32(payload, len - 4) ~= Template.crc32(payload, 0, len - 4) then
			fail("The structure data is damaged (its checksum doesn't match): copy it again")
		end
		r.len = len - 4
		local t = decodeBody(r, warnings)
		if r.o ~= r.len then
			fail("The structure data has bytes this game doesn't understand")
		end
		return t
	end)
	if ok then
		return result, nil, warnings
	end
	local failure = result :: any
	if type(failure) == "table" and type(failure.failure) == "string" then
		return nil, failure.failure, nil
	end
	return nil, "The structure data is damaged", nil
end

--[[ Editable tables: ASCII layers ]]

--[[
	A template as an editable table:

	  {
	    name = "outpost/houses/hut_1",
	    size = { x, y, z },
	    legend = { ["."] = "Air", [" "] = false, A = "OakLog", ... },  -- false: keep
	    layers = { { "AAAAAAA", ... }, ... },  -- y = 0 first; z rows (north first) of x (west first)
	    jigsaws = { Jigsaw... }, markers = { Marker... }, containers = { Container... },
	  }

	Every cell is `width` characters (1 unless the palette is too big for one). Air is "." and
	keep " " (a space); other blocks get the first free character of their name (capital, then
	small letters), else the next free one of SYMBOLS.
]]
Template.SYMBOLS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789#$%&*+-/:;<=>?@^~!|_,()[]{}"

export type TemplateTable = {
	name: string,
	size: { number },
	width: number?,
	legend: { [string]: string | false },
	layers: { { string } },
	jigsaws: { Jigsaw }?,
	markers: { Marker }?,
	containers: { Container }?,
}

function Template.toTable(t: Template): TemplateTable
	local counts = Template.counts(t)
	-- Blocks used, most common first (stable by id), Air aside.
	local blocks: { number } = {}
	for id in counts do
		if id ~= AIR then
			table.insert(blocks, id)
		end
	end
	table.sort(blocks, function(a, b)
		if counts[a] ~= counts[b] then
			return counts[a] > counts[b]
		end
		return a < b
	end)
	local symbols = Template.SYMBOLS
	local width = if #blocks <= #symbols then 1 else 2
	local legend: { [string]: string | false } = { ["."] = "Air", [" "] = false }
	local symbolOf: { [number]: string } = { [AIR] = string.rep(".", width) }
	local function free(symbol: string): boolean
		return legend[symbol] == nil
	end
	for _, id in blocks do
		local name = Blocks.get(id).name
		local chosen: string? = nil
		if width == 1 then
			-- (Its initial, its other capitals, then its other letters, then any symbol.)
			local first = string.sub(name, 1, 1)
			local candidates = string.upper(first) .. string.lower(first)
			for c in string.gmatch(string.sub(name, 2), "%u") do
				candidates ..= c .. string.lower(c)
			end
			for c in string.gmatch(string.sub(name, 2), "%l") do
				candidates ..= string.upper(c) .. c
			end
			candidates ..= symbols
			for i = 1, #candidates do
				local c = string.sub(candidates, i, i)
				if free(c) and string.find(symbols, c, 1, true) then
					chosen = c
					break
				end
			end
		else
			for i = 1, #symbols do
				for k = 1, #symbols do
					local pair = string.sub(symbols, i, i) .. string.sub(symbols, k, k)
					if free(pair) then
						chosen = pair
						break
					end
				end
				if chosen then
					break
				end
			end
		end
		assert(chosen, "out of symbols")
		legend[chosen] = name
		symbolOf[id] = chosen
	end
	if width == 2 then
		legend["."], legend[" "] = nil, nil
		legend[".."], legend["  "] = "Air", false
	end
	local keep = string.rep(" ", width)
	local sx, sy, sz = t.size[1], t.size[2], t.size[3]
	local layers: { { string } } = {}
	for y = 0, sy - 1 do
		local rows: { string } = {}
		for z = 0, sz - 1 do
			local row = table.create(sx)
			for x = 0, sx - 1 do
				local id = Template.get(t, x, y, z)
				row[x + 1] = if id == nil then keep else symbolOf[id]
			end
			rows[z + 1] = table.concat(row)
		end
		layers[y + 1] = rows
	end
	local copy = Template.clone(t)
	return {
		name = t.name,
		size = table.clone(t.size),
		width = width,
		legend = legend,
		layers = layers,
		jigsaws = sortedByCell(t, copy.jigsaws),
		markers = sortedByCell(t, copy.markers),
		containers = sortedByCell(t, copy.containers),
	}
end

-- The template a table in `toTable`'s form describes, or nil and what is wrong with it.
function Template.fromTable(source: any): (Template?, string?)
	if type(source) ~= "table" then
		return nil, "not a table"
	end
	local name, size, layers = source.name, source.size, source.layers
	if type(name) ~= "string" or not Settings.validName(name) or name == "" then
		return nil, "name: 1..128 letters, digits and _ . / : -"
	elseif type(layers) ~= "table" then
		return nil, "layers: a list of layers"
	end
	local width = source.width or 1
	if width ~= 1 and width ~= 2 then
		return nil, "width: 1 or 2"
	end
	if type(size) ~= "table" then
		-- (From the layers: the first row's length, the layer count and the first layer's rows.)
		local rows = layers[1]
		local x = if type(rows) == "table" and type(rows[1]) == "string" then #rows[1] // width else 0
		local z = if type(rows) == "table" then #rows else 0
		size = { x, #layers, z }
	end
	for k = 1, 3 do
		local n = size[k]
		if type(n) ~= "number" or n ~= math.floor(n) or n < 1 or n > Template.MAX_SIZE then
			return nil, `size: three whole numbers 1..{Template.MAX_SIZE}`
		end
	end
	local legend: { [string]: number | false } = {}
	legend[string.rep(".", width)] = AIR
	legend[string.rep(" ", width)] = false
	if source.legend ~= nil and type(source.legend) ~= "table" then
		return nil, "legend: symbol = block name (or false to keep)"
	end
	for symbol, value in source.legend or {} do
		if type(symbol) ~= "string" or #symbol ~= width then
			return nil, `legend: symbols are {width} character(s)`
		end
		if value == false then
			legend[symbol] = false
		else
			local id = Blocks.find(value)
			if id == nil then
				return nil, `legend: unknown block '{value}'`
			end
			legend[symbol] = id
		end
	end
	local t = Template.new(name, size)
	if #layers ~= size[2] then
		return nil, `layers: {size[2]} layers (y = 0 first)`
	end
	for y = 0, size[2] - 1 do
		local rows = layers[y + 1]
		if type(rows) ~= "table" or #rows ~= size[3] then
			return nil, `layer {y}: {size[3]} rows`
		end
		for z = 0, size[3] - 1 do
			local row = rows[z + 1]
			if type(row) ~= "string" or #row ~= size[1] * width then
				return nil, `layer {y} row {z}: {size[1] * width} characters`
			end
			for x = 0, size[1] - 1 do
				local symbol = string.sub(row, x * width + 1, x * width + width)
				local value = legend[symbol]
				if value == nil then
					return nil, `layer {y} row {z}: '{symbol}' is not in the legend`
				end
				Template.set(t, x, y, z, if value == false then nil else value :: number)
			end
		end
	end
	local function copyList(list: any, what: string): ({ any }?, string?)
		if list == nil then
			return {}, nil
		elseif type(list) ~= "table" then
			return nil, `{what}: a list`
		end
		local out = {}
		for i, record in list do
			if type(record) ~= "table" then
				return nil, `{what} {i}: a table`
			end
			local copy = table.clone(record)
			if what == "containers" then
				if type(copy.items) ~= "table" then
					return nil, `{what} {i}: items`
				end
				local items = {}
				for k, item in copy.items do
					if type(item) ~= "table" then
						return nil, `{what} {i}: item {k}`
					end
					local stack = table.clone(item)
					stack.damage = stack.damage or 0
					items[k] = stack
				end
				copy.items = items
			end
			out[i] = copy
		end
		return out, nil
	end
	local jigsaws, problem = copyList(source.jigsaws, "jigsaws")
	if jigsaws == nil then
		return nil, problem
	end
	local markers, markerProblem = copyList(source.markers, "markers")
	if markers == nil then
		return nil, markerProblem
	end
	local containers, containerProblem = copyList(source.containers, "containers")
	if containers == nil then
		return nil, containerProblem
	end
	t.jigsaws = jigsaws :: any
	t.markers = markers :: any
	t.containers = containers :: any
	for _, j in t.jigsaws do
		local defaults = Settings.defaultJigsaw(j.front)
		for key, value in defaults :: any do
			if (j :: any)[key] == nil then
				(j :: any)[key] = value
			end
		end
	end
	local ok, err = pcall(Template.check, t)
	if not ok then
		return nil, "a record is malformed"
	elseif err then
		return nil, err
	end
	return t, nil
end

return Template
