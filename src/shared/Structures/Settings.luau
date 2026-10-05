--!strict
--[[
	Structure block and jigsaw block settings: Minecraft 1.20.1's StructureBlockEntity and
	JigsawBlockEntity fields, their defaults, their ranges and their wire format (Net/Protocol's
	StructureBlock, Jigsaw, StructureBlocks and Jigsaws messages use `write*` / `read*`).

	Structure block (StructureSettings):
	  mode             "save" | "load" | "corner" | "data" (also the block: Blocks.structureBlock)
	  name             the structure's name; CORNER blocks pair by it
	  offset           { x, y, z }: the region's corner relative to the block, each -48..48
	                   (Config.Structures.MaxOffset), default (0, 1, 0)
	  size             { x, y, z }: the region's size, each 0..48 (Config.Structures.MaxSize),
	                   default (5, 5, 5)
	  rotation         0..3 quarter turns clockwise seen from above (LOAD)
	  mirror           "none" | "leftRight" (Z flips) | "frontBack" (X flips) (LOAD)
	  integrity        0..1: the share of blocks LOAD places, chosen with `seed` (default 1)
	  seed             a whole number, 0 = random (LOAD's integrity)
	  showBoundingBox  draw the region's outline (default true)
	  showInvisible    Minecraft's "Show invisible blocks" (showAir; default false)
	  metadata         DATA mode's custom string, the data marker (at most 128 bytes)

	Jigsaw block (JigsawSettings; Minecraft's defaults are "minecraft:empty", here "empty"):
	  name, target, pool  this jigsaw's name, the name of the jigsaw it attaches to, the template
	                      pool its children come from (default "empty")
	  finalState          the block it becomes after generation (a block name, default "Air")
	  joint               "rollable" | "aligned": default aligned for horizontal fronts, rollable
	                      for vertical ones (it only matters for vertical fronts)

	Names (structure names, jigsaw names, targets, pools and final states) are 0..128 characters of
	letters, digits and `_ . / : -` (Minecraft's resource locations, upper case allowed: this
	game's block names are CamelCase). Metadata is at most 128 bytes of text without control
	characters.

	`clampStructure` / `clampJigsaw` bring numbers into Minecraft's ranges (as its block entities
	do when they load) and cut strings to their caps; `checkStructure` / `checkJigsaw` explain
	what is still wrong with the names, in words for the player. Neither errors on any table.

	Wire format (everything little endian, like the rest of Net/Protocol):
	  structure  u8 mode (1 save, 2 load, 3 corner, 4 data), u8 n + name (n <= 128),
	             i8 offset x, y, z, u8 size x, y, z, u8 rotation (0..3), u8 mirror (0 none,
	             1 leftRight, 2 frontBack), f64 integrity, f64 seed, u8 flags (bit 0
	             showBoundingBox, bit 1 showInvisible), u8 n + metadata (n <= 128)
	  jigsaw     u8 n + name, u8 n + target, u8 n + pool, u8 n + finalState (each n <= 128),
	             u8 joint (0 rollable, 1 aligned)
	Reading refuses unknown codes, flags, NaN and strings over their caps (malformed), and clamps
	numbers into range.
]]

local Blocks = require(script.Parent.Parent.Blocks)
local Config = require(script.Parent.Parent.Config)

export type StructureSettings = {
	mode: string,
	name: string,
	offset: { number },
	size: { number },
	rotation: number,
	mirror: string,
	integrity: number,
	seed: number,
	showBoundingBox: boolean,
	showInvisible: boolean,
	metadata: string,
}

export type JigsawSettings = {
	name: string,
	target: string,
	pool: string,
	finalState: string,
	joint: string,
}

local Settings = {}

Settings.MODES = table.freeze({ "save", "load", "corner", "data" })
Settings.MIRRORS = table.freeze({ "none", "leftRight", "frontBack" })
Settings.JOINTS = table.freeze({ "rollable", "aligned" })

Settings.MAX_NAME = 128
Settings.MAX_METADATA = 128
Settings.MAX_OFFSET = Config.Structures.MaxOffset
Settings.MAX_SIZE = Config.Structures.MaxSize
-- Seeds are whole numbers a double holds exactly.
Settings.MAX_SEED = 9007199254740991
-- A jigsaw's Generate: levels 0..7 (Minecraft's slider).
Settings.MAX_LEVELS = 7
-- Minecraft's "minecraft:empty": the empty pool, and the default jigsaw name and target.
Settings.EMPTY = "empty"
Settings.DEFAULT_FINAL_STATE = "Air"

-- (The wire format holds offsets in an i8 and sizes in a u8.)
assert(Settings.MAX_OFFSET >= 1 and Settings.MAX_OFFSET <= 127, "Config.Structures.MaxOffset must be 1..127")
assert(Settings.MAX_SIZE >= 1 and Settings.MAX_SIZE <= 255, "Config.Structures.MaxSize must be 1..255")

local MODE_CODE: { [string]: number } = {}
for code, mode in Settings.MODES do
	MODE_CODE[mode] = code
end
local MIRROR_CODE: { [string]: number } = {}
for code, mirror in Settings.MIRRORS do
	MIRROR_CODE[mirror] = code - 1
end
local JOINT_CODE: { [string]: number } = {}
for code, joint in Settings.JOINTS do
	JOINT_CODE[joint] = code - 1
end

local HORIZONTAL: { [string]: boolean } = { North = true, South = true, West = true, East = true }

--[[ Defaults ]]

-- A new structure block's settings (Minecraft's, with a 5 x 5 x 5 region), in `mode` (default
-- "save").
function Settings.defaultStructure(mode: string?): StructureSettings
	return {
		mode = if mode and MODE_CODE[mode] then mode else "save",
		name = "",
		offset = { 0, 1, 0 },
		size = { 5, 5, 5 },
		rotation = 0,
		mirror = "none",
		integrity = 1,
		seed = 0,
		showBoundingBox = true,
		showInvisible = false,
		metadata = "",
	}
end

-- The joint a jigsaw facing `front` gets by default: aligned for a horizontal front, rollable for
-- a vertical one (and when the front is unknown).
function Settings.defaultJoint(front: string?): string
	return if front and HORIZONTAL[front] then "aligned" else "rollable"
end

-- A new jigsaw's settings, for a jigsaw facing `front`.
function Settings.defaultJigsaw(front: string?): JigsawSettings
	return {
		name = Settings.EMPTY,
		target = Settings.EMPTY,
		pool = Settings.EMPTY,
		finalState = Settings.DEFAULT_FINAL_STATE,
		joint = Settings.defaultJoint(front),
	}
end

--[[ Validation ]]

-- `text` cut to at most `bytes` bytes without splitting a UTF-8 character.
function Settings.cut(text: string, bytes: number): string
	if #text <= bytes then
		return text
	end
	local cut = bytes
	-- Step back while the first byte after the cut is a continuation byte (10xxxxxx).
	while cut > 0 and bit32.band(string.byte(text, cut + 1), 0xC0) == 0x80 do
		cut -= 1
	end
	return string.sub(text, 1, cut)
end

-- Is `name` a valid name: a string of 0..128 letters, digits and `_ . / : -`?
function Settings.validName(name: any): boolean
	return type(name) == "string" and #name <= Settings.MAX_NAME and string.find(name, "^[%w_%./:%-]*$") ~= nil
end

-- Is `text` valid metadata: at most 128 bytes of UTF-8 without control characters?
function Settings.validMetadata(text: any): boolean
	return type(text) == "string"
		and #text <= Settings.MAX_METADATA
		and utf8.len(text) ~= nil
		and string.find(text, "[%c]") == nil
end

-- A finite number, else `default`.
local function number(value: any, default: number): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return default
	end
	return value
end

-- A whole number in low..high (floored, then clamped), `default` for anything that is no number.
local function whole(value: any, low: number, high: number, default: number): number
	return math.clamp(math.floor(number(value, default)), low, high)
end

local function text(value: any, cap: number, default: string): string
	if type(value) ~= "string" then
		return default
	end
	return Settings.cut(value, cap)
end

local function vector(value: any, low: number, high: number, default: { number }): { number }
	local v = if type(value) == "table" then value else default
	return {
		whole(v[1], low, high, default[1]),
		whole(v[2], low, high, default[2]),
		whole(v[3], low, high, default[3]),
	}
end

--[[
	`s` (any value; untrusted) as structure block settings: a new table with numbers floored and
	clamped into Minecraft's ranges (offset +-MaxOffset, size 0..MaxSize, rotation 0..3, integrity
	0..1, seed a whole number), unknown modes and mirrors replaced by the defaults, flags as
	booleans and strings cut to their caps. Never errors; the names may still be invalid
	(`checkStructure`).
]]
function Settings.clampStructure(s: any): StructureSettings
	local defaults = Settings.defaultStructure()
	if type(s) ~= "table" then
		return defaults
	end
	local mode = if type(s.mode) == "string" and MODE_CODE[s.mode] then s.mode else defaults.mode
	local mirror = if type(s.mirror) == "string" and MIRROR_CODE[s.mirror] then s.mirror else "none"
	return {
		mode = mode,
		name = text(s.name, Settings.MAX_NAME, ""),
		offset = vector(s.offset, -Settings.MAX_OFFSET, Settings.MAX_OFFSET, defaults.offset),
		size = vector(s.size, 0, Settings.MAX_SIZE, defaults.size),
		rotation = whole(s.rotation, 0, 3, 0),
		mirror = mirror,
		integrity = math.clamp(number(s.integrity, 1), 0, 1),
		seed = whole(s.seed, -Settings.MAX_SEED, Settings.MAX_SEED, 0),
		showBoundingBox = s.showBoundingBox ~= false,
		showInvisible = s.showInvisible == true,
		metadata = text(s.metadata, Settings.MAX_METADATA, ""),
	}
end

--[[
	What is wrong with a structure block's settings, as a message for the player (nil: nothing):
	a name with characters Minecraft's resource locations don't allow, or bad metadata.
]]
function Settings.checkStructure(s: StructureSettings): string?
	if not Settings.validName(s.name) then
		return `Invalid structure name '{Settings.cut(tostring(s.name), 40)}': use up to {Settings.MAX_NAME} letters, digits and _ . / : -`
	elseif not Settings.validMetadata(s.metadata) then
		return `Invalid data marker: up to {Settings.MAX_METADATA} characters of text`
	end
	return nil
end

-- `j` (any value; untrusted) as jigsaw settings: strings cut to their caps, an unknown joint
-- replaced by the default for `front`. Never errors; the names may still be invalid
-- (`checkJigsaw`).
function Settings.clampJigsaw(j: any, front: string?): JigsawSettings
	local defaults = Settings.defaultJigsaw(front)
	if type(j) ~= "table" then
		return defaults
	end
	return {
		name = text(j.name, Settings.MAX_NAME, defaults.name),
		target = text(j.target, Settings.MAX_NAME, defaults.target),
		pool = text(j.pool, Settings.MAX_NAME, defaults.pool),
		finalState = text(j.finalState, Settings.MAX_NAME, defaults.finalState),
		joint = if type(j.joint) == "string" and JOINT_CODE[j.joint] then j.joint else defaults.joint,
	}
end

--[[
	What is wrong with a jigsaw's settings, as a message for the player (nil: nothing): a name,
	target or pool with characters resource locations don't allow, or a final state that is no
	block (Minecraft would place air).
]]
function Settings.checkJigsaw(j: JigsawSettings): string?
	for _, field in { "name", "target", "pool" } do
		local value = (j :: any)[field]
		if not Settings.validName(value) then
			return `Invalid jigsaw {field} '{Settings.cut(tostring(value), 40)}': use up to {Settings.MAX_NAME} letters, digits and _ . / : -`
		end
	end
	if not Settings.validName(j.finalState) or Blocks.find(j.finalState) == nil then
		return `Unknown block '{Settings.cut(tostring(j.finalState), 40)}' for the final state`
	end
	return nil
end

--[[ Wire format ]]

-- Bytes `s` takes on the wire (its strings cut to their caps).
function Settings.structureBytes(s: StructureSettings): number
	return 1
		+ 1
		+ #Settings.cut(s.name, Settings.MAX_NAME)
		+ 3
		+ 3
		+ 1
		+ 1
		+ 8
		+ 8
		+ 1
		+ 1
		+ #Settings.cut(s.metadata, Settings.MAX_METADATA)
end

local function writeString(b: buffer, o: number, value: string, cap: number): number
	local cut = Settings.cut(value, cap)
	buffer.writeu8(b, o, #cut)
	buffer.writestring(b, o + 1, cut)
	return o + 1 + #cut
end

-- Reads a string of at most `cap` bytes at `o`: ok, the string and the offset after it.
local function readString(b: buffer, o: number, len: number, cap: number): (boolean, string, number)
	if o + 1 > len then
		return false, "", o
	end
	local n = buffer.readu8(b, o)
	if n > cap or o + 1 + n > len then
		return false, "", o
	end
	return true, buffer.readstring(b, o + 1, n), o + 1 + n
end

-- Writes `s` (clamped first, so anything fits its field) at `o`; returns the offset after it.
function Settings.writeStructure(b: buffer, o: number, s: StructureSettings): number
	local c = Settings.clampStructure(s)
	buffer.writeu8(b, o, MODE_CODE[c.mode])
	o = writeString(b, o + 1, c.name, Settings.MAX_NAME)
	for k = 1, 3 do
		buffer.writei8(b, o + k - 1, c.offset[k])
		buffer.writeu8(b, o + 2 + k, c.size[k])
	end
	o += 6
	buffer.writeu8(b, o, c.rotation)
	buffer.writeu8(b, o + 1, MIRROR_CODE[c.mirror])
	buffer.writef64(b, o + 2, c.integrity)
	buffer.writef64(b, o + 10, c.seed)
	buffer.writeu8(b, o + 18, (if c.showBoundingBox then 1 else 0) + (if c.showInvisible then 2 else 0))
	return writeString(b, o + 19, c.metadata, Settings.MAX_METADATA)
end

--[[
	Reads structure block settings at `o` of the first `len` bytes of `b`: ok, the settings
	(clamped into range) and the offset after them. ok = false when malformed: too short, an
	unknown mode, mirror or flag, NaN, or a string over its cap.
]]
function Settings.readStructure(b: buffer, o: number, len: number): (boolean, StructureSettings?, number)
	if o + 1 > len then
		return false, nil, o
	end
	local mode = Settings.MODES[buffer.readu8(b, o)]
	local ok, name
	ok, name, o = readString(b, o + 1, len, Settings.MAX_NAME)
	-- (Offset, size, rotation, mirror, integrity, seed, flags and the metadata's length.)
	if mode == nil or not ok or o + 26 > len then
		return false, nil, o
	end
	local offset = { buffer.readi8(b, o), buffer.readi8(b, o + 1), buffer.readi8(b, o + 2) }
	local size = { buffer.readu8(b, o + 3), buffer.readu8(b, o + 4), buffer.readu8(b, o + 5) }
	o += 6
	local rotation = buffer.readu8(b, o)
	local mirror = Settings.MIRRORS[buffer.readu8(b, o + 1) + 1]
	local integrity = buffer.readf64(b, o + 2)
	local seed = buffer.readf64(b, o + 10)
	local flags = buffer.readu8(b, o + 18)
	if rotation > 3 or mirror == nil or integrity ~= integrity or seed ~= seed or flags > 3 then
		return false, nil, o
	end
	local metadata
	ok, metadata, o = readString(b, o + 19, len, Settings.MAX_METADATA)
	if not ok then
		return false, nil, o
	end
	return true,
		Settings.clampStructure({
			mode = mode,
			name = name,
			offset = offset,
			size = size,
			rotation = rotation,
			mirror = mirror,
			integrity = integrity,
			seed = seed,
			showBoundingBox = bit32.band(flags, 1) ~= 0,
			showInvisible = bit32.band(flags, 2) ~= 0,
			metadata = metadata,
		}),
		o
end

-- Bytes `j` takes on the wire (its strings cut to their caps).
function Settings.jigsawBytes(j: JigsawSettings): number
	local cap = Settings.MAX_NAME
	return 4
		+ #Settings.cut(j.name, cap)
		+ #Settings.cut(j.target, cap)
		+ #Settings.cut(j.pool, cap)
		+ #Settings.cut(j.finalState, cap)
		+ 1
end

-- Writes `j` (clamped first) at `o`; returns the offset after it.
function Settings.writeJigsaw(b: buffer, o: number, j: JigsawSettings): number
	local c = Settings.clampJigsaw(j)
	local cap = Settings.MAX_NAME
	o = writeString(b, o, c.name, cap)
	o = writeString(b, o, c.target, cap)
	o = writeString(b, o, c.pool, cap)
	o = writeString(b, o, c.finalState, cap)
	buffer.writeu8(b, o, JOINT_CODE[c.joint])
	return o + 1
end

-- Reads jigsaw settings at `o` of the first `len` bytes of `b`: ok, the settings and the offset
-- after them; ok = false when malformed (too short, a string over its cap, an unknown joint).
function Settings.readJigsaw(b: buffer, o: number, len: number): (boolean, JigsawSettings?, number)
	local cap = Settings.MAX_NAME
	local values: { string } = {}
	for i = 1, 4 do
		local ok, value
		ok, value, o = readString(b, o, len, cap)
		if not ok then
			return false, nil, o
		end
		values[i] = value
	end
	if o + 1 > len then
		return false, nil, o
	end
	local joint = Settings.JOINTS[buffer.readu8(b, o) + 1]
	if joint == nil then
		return false, nil, o
	end
	return true,
		{ name = values[1], target = values[2], pool = values[3], finalState = values[4], joint = joint },
		o + 1
end

--[[ Comparing ]]

-- Do two structure block settings hold the same values?
function Settings.sameStructure(a: StructureSettings, b: StructureSettings): boolean
	for k = 1, 3 do
		if a.offset[k] ~= b.offset[k] or a.size[k] ~= b.size[k] then
			return false
		end
	end
	return a.mode == b.mode
		and a.name == b.name
		and a.rotation == b.rotation
		and a.mirror == b.mirror
		and a.integrity == b.integrity
		and a.seed == b.seed
		and a.showBoundingBox == b.showBoundingBox
		and a.showInvisible == b.showInvisible
		and a.metadata == b.metadata
end

-- Do two jigsaw settings hold the same values?
function Settings.sameJigsaw(a: JigsawSettings, b: JigsawSettings): boolean
	return a.name == b.name
		and a.target == b.target
		and a.pool == b.pool
		and a.finalState == b.finalState
		and a.joint == b.joint
end

return Settings
