--!strict
--[[
	The settings of every structure block and jigsaw block in the world, by block position, for the
	session (Minecraft's StructureBlockEntity and JigsawBlockEntity; like chests, nothing is saved).
	Pure, so the tests can run it.

	Entries follow the blocks (`blockChanged`, chained onto WorldServer.onChanged by the server
	script, so placing, breaking, LOAD, Generate and the Api all come through):
	  * a structure block appearing gets the default settings of its mode (Settings.
	    defaultStructure: the block is the mode, Blocks.structureMode), and one structure block
	    turning into another (a mode change swaps the block) keeps its settings with the new mode;
	  * a jigsaw appearing gets the default settings for its front (Settings.defaultJigsaw), and
	    one turning into another keeps them;
	  * any other block there forgets them (Minecraft's broken block entity).
	These blocks only ever come from edits (generation writes jigsaws as their final state and
	data markers as air), so every one in the world has an entry.

	Replication: `chunkRecords` gives a chunk's entries (sent with its edit list), and every entry
	created, changed or forgotten is marked dirty until `takeDirty` (a forgotten one is a record
	without settings: the client drops what it knew). `corners` finds a DETECT's CORNER blocks.

	Settings tables are never changed in place: `setStructure` / `setJigsaw` store a copy, so a
	table handed out stays as it was (records encoded later, the caller's own).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Coords = require(Shared.World.Coords)
local Protocol = require(Shared.Net.Protocol)
local Settings = require(Shared.Structures.Settings)

type StructureSettings = Settings.StructureSettings
type JigsawSettings = Settings.JigsawSettings
type StructureBlockRecord = Protocol.StructureBlockRecord
type JigsawRecord = Protocol.JigsawRecord

export type Store = {
	-- Settings by Coords.posKey.
	structures: { [number]: StructureSettings },
	jigsaws: { [number]: JigsawSettings },
	-- Positions (posKeys) with an entry of either kind, by Coords.chunkKey.
	byChunk: { [number]: { [number]: boolean } },
	-- Positions whose structure block / jigsaw record is due (created, changed or forgotten).
	dirtyStructures: { [number]: boolean },
	dirtyJigsaws: { [number]: boolean },

	blockChanged: (self: Store, x: number, y: number, z: number, old: number, new: number) -> (),
	structure: (self: Store, x: number, y: number, z: number) -> StructureSettings?,
	jigsaw: (self: Store, x: number, y: number, z: number) -> JigsawSettings?,
	setStructure: (self: Store, x: number, y: number, z: number, settings: StructureSettings) -> boolean,
	setJigsaw: (self: Store, x: number, y: number, z: number, settings: JigsawSettings) -> boolean,
	corners: (self: Store, x: number, z: number, range: number, name: string) -> { { number } },
	structureRecord: (self: Store, x: number, y: number, z: number) -> StructureBlockRecord,
	jigsawRecord: (self: Store, x: number, y: number, z: number) -> JigsawRecord,
	chunkRecords: (self: Store, cx: number, cz: number) -> ({ StructureBlockRecord }, { JigsawRecord }),
	takeDirty: (self: Store) -> ({ StructureBlockRecord }, { JigsawRecord }),
}

local Store = {}
Store.__index = Store

local SIZE = 16

local function chunkKeyOf(x: number, z: number): number
	return Coords.chunkKey(x // SIZE, z // SIZE)
end

-- Files `key` under its chunk (or takes it out when it holds neither kind any more).
local function index(self: Store, x: number, y: number, z: number)
	local key = Coords.posKey(x, y, z)
	local chunk = chunkKeyOf(x, z)
	local held = self.structures[key] ~= nil or self.jigsaws[key] ~= nil
	local keys = self.byChunk[chunk]
	if held then
		if keys == nil then
			keys = {}
			self.byChunk[chunk] = keys
		end
		keys[key] = true
	elseif keys then
		keys[key] = nil
		if next(keys) == nil then
			self.byChunk[chunk] = nil
		end
	end
end

local function cloneStructure(s: StructureSettings): StructureSettings
	local copy = table.clone(s)
	copy.offset = table.clone(s.offset)
	copy.size = table.clone(s.size)
	return copy
end

function Store.blockChanged(self: Store, x: number, y: number, z: number, old: number, new: number)
	if old == new then
		return
	end
	local key = Coords.posKey(x, y, z)
	local changed = false
	-- Structure blocks: the mode is the block.
	local mode = Blocks.structureMode(new)
	local existing = self.structures[key]
	if mode then
		local settings = if existing and Blocks.structureMode(old) ~= nil
			then cloneStructure(existing)
			else Settings.defaultStructure(mode)
		settings.mode = mode
		self.structures[key] = settings
		self.dirtyStructures[key] = true
		changed = true
	elseif existing then
		self.structures[key] = nil
		self.dirtyStructures[key] = true
		changed = true
	end
	-- Jigsaws: the orientation is the block; the settings stay when it turns.
	local front = Blocks.jigsawOrientation(new)
	local jigsaw = self.jigsaws[key]
	if front then
		if jigsaw == nil or not Blocks.isJigsaw(old) then
			self.jigsaws[key] = Settings.defaultJigsaw(front)
			self.dirtyJigsaws[key] = true
			changed = true
		end
	elseif jigsaw then
		self.jigsaws[key] = nil
		self.dirtyJigsaws[key] = true
		changed = true
	end
	if changed then
		index(self, x, y, z)
	end
end

-- The structure block settings at (x, y, z), nil when there is no structure block. Read only.
function Store.structure(self: Store, x: number, y: number, z: number): StructureSettings?
	return self.structures[Coords.posKey(x, y, z)]
end

-- The jigsaw settings at (x, y, z), nil when there is no jigsaw. Read only.
function Store.jigsaw(self: Store, x: number, y: number, z: number): JigsawSettings?
	return self.jigsaws[Coords.posKey(x, y, z)]
end

--[[
	Stores a copy of `settings` (clamped: Settings.clampStructure) for the structure block at
	(x, y, z); its record is due when they differ from what was there. false when no structure
	block has an entry there. The mode is the caller's to keep equal to the block's.
]]
function Store.setStructure(self: Store, x: number, y: number, z: number, settings: StructureSettings): boolean
	local key = Coords.posKey(x, y, z)
	local existing = self.structures[key]
	if existing == nil then
		return false
	end
	local clamped = Settings.clampStructure(settings)
	if not Settings.sameStructure(existing, clamped) then
		self.structures[key] = clamped
		self.dirtyStructures[key] = true
	end
	return true
end

-- The same for a jigsaw's settings (Settings.clampJigsaw). false when there is no jigsaw there.
function Store.setJigsaw(self: Store, x: number, y: number, z: number, settings: JigsawSettings): boolean
	local key = Coords.posKey(x, y, z)
	local existing = self.jigsaws[key]
	if existing == nil then
		return false
	end
	local clamped = Settings.clampJigsaw(settings)
	if not Settings.sameJigsaw(existing, clamped) then
		self.jigsaws[key] = clamped
		self.dirtyJigsaws[key] = true
	end
	return true
end

--[[
	The positions ({ x, y, z }) of the CORNER structure blocks named `name` within `range` blocks of
	(x, z) on both horizontal axes, at any height (Minecraft's getRelatedCorners: +-80, the whole
	build height), sorted by position.
]]
function Store.corners(self: Store, x: number, z: number, range: number, name: string): { { number } }
	local found: { { number } } = {}
	local c0x, c1x = (x - range) // SIZE, (x + range) // SIZE
	local c0z, c1z = (z - range) // SIZE, (z + range) // SIZE
	for cx = c0x, c1x do
		for cz = c0z, c1z do
			local keys = self.byChunk[Coords.chunkKey(cx, cz)]
			if keys then
				for key in keys do
					local s = self.structures[key]
					if s and s.mode == "corner" and s.name == name then
						local bx, by, bz = Coords.decodePosKey(key)
						if math.abs(bx - x) <= range and math.abs(bz - z) <= range then
							table.insert(found, { bx, by, bz })
						end
					end
				end
			end
		end
	end
	table.sort(found, function(a, b)
		if a[1] ~= b[1] then
			return a[1] < b[1]
		elseif a[2] ~= b[2] then
			return a[2] < b[2]
		end
		return a[3] < b[3]
	end)
	return found
end

-- The record of the structure block at (x, y, z) (settings nil: none there).
function Store.structureRecord(self: Store, x: number, y: number, z: number): StructureBlockRecord
	return { x = x, y = y, z = z, settings = self.structures[Coords.posKey(x, y, z)] }
end

-- The record of the jigsaw at (x, y, z) (settings nil: none there).
function Store.jigsawRecord(self: Store, x: number, y: number, z: number): JigsawRecord
	return { x = x, y = y, z = z, settings = self.jigsaws[Coords.posKey(x, y, z)] }
end

-- Every structure block's and jigsaw's record in chunk (cx, cz), sorted by position.
function Store.chunkRecords(self: Store, cx: number, cz: number): ({ StructureBlockRecord }, { JigsawRecord })
	local structures: { StructureBlockRecord } = {}
	local jigsaws: { JigsawRecord } = {}
	local keys = self.byChunk[Coords.chunkKey(cx, cz)]
	if keys then
		local sorted: { number } = {}
		for key in keys do
			table.insert(sorted, key)
		end
		table.sort(sorted)
		for _, key in sorted do
			local x, y, z = Coords.decodePosKey(key)
			local s = self.structures[key]
			if s then
				table.insert(structures, { x = x, y = y, z = z, settings = s })
			end
			local j = self.jigsaws[key]
			if j then
				table.insert(jigsaws, { x = x, y = y, z = z, settings = j })
			end
		end
	end
	return structures, jigsaws
end

-- The records due since the last call (settings nil: forgotten), sorted by position.
function Store.takeDirty(self: Store): ({ StructureBlockRecord }, { JigsawRecord })
	local function take<T>(
		dirty: { [number]: boolean },
		map: { [number]: T }
	): { { x: number, y: number, z: number, settings: T? } }
		local keys: { number } = {}
		for key in dirty do
			table.insert(keys, key)
		end
		table.clear(dirty)
		table.sort(keys)
		local records = table.create(#keys)
		for i, key in keys do
			local x, y, z = Coords.decodePosKey(key)
			records[i] = { x = x, y = y, z = z, settings = map[key] }
		end
		return records
	end
	return take(self.dirtyStructures, self.structures), take(self.dirtyJigsaws, self.jigsaws)
end

local StructureStore = {}

-- An empty store.
function StructureStore.new(): Store
	local self = { structures = {}, jigsaws = {}, byChunk = {}, dirtyStructures = {}, dirtyJigsaws = {} }
	return (setmetatable(self, Store) :: any) :: Store
end

return StructureStore
