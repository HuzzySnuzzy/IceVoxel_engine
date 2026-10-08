--!strict
--[[
	Debug worlds (Minecraft's Debug Mode world type, and two more in its spirit), on
	Generation/LayeredGenerator, for Generation/WorldTypes. They show what the game has, laid out
	in a grid, with nothing else around.

	All Blocks   Minecraft's DebugLevelSource: every block id but air and cave air (every variant:
	             wall torches, both halves of tall plants, each fluid level, structure blocks), once,
	             ordered by id, at y = BLOCK_Y (70) over the void. Not the cave twins (CaveGlowLichen*,
	             CaveLava, CaveOil, the mineshafts' Cave*: Blocks.isCaveTwin) either: they look
	             exactly like their twin, which is there, and while caves are hidden (the Caves
	             setting's default, and far terrain always) the mesher draws a twin as cave air,
	             a stone cap where it touches open air. The grid is W = ceil(sqrt(n)) wide; block
	             k stands at
	             x = 2 * (k // W) + 1, z = 2 * (k % W) + 1 (Minecraft's: odd x and z, one air cell
	             between neighbours), so 220 blocks take 15 x 15 spots, a 30 x 30 square. Nothing
	             stands under them, as in Minecraft: blocks that need support (plants, torches,
	             lanterns, glow lichen, the upper half of a tall plant alone) and fluids (sources
	             and every flowing level) are shown as they are, because the world type turns ticks
	             off (WorldTypes `ticks = false`: no block updates and no random ticks, Minecraft's
	             debug world), so nothing falls, flows, burns, grows or breaks for lack of support,
	             even next to an edit.
	             Below y = 0 the game counts everything as bedrock, so a player who falls lands on
	             the world's floor (Minecraft's debug world has a barrier floor at y = 60). The
	             spawn stands on block 0 (bedrock, at 1, 70, 1); the type suggests spectator mode.
	All Structures  every template of the structure library (Structures/Library, sorted by name:
	             each piece on its own, rotation 0, as saved), then every generated jigsaw
	             structure assembled whole (from a seed of its own, on flat ground), on a grass floor
	             (first air at FLOOR, 65: above the sea level the generator's terrain matching
	             pieces respect). Shelf packing: ceil(sqrt(n)) per row from x = 0, z = 0 eastwards,
	             each GAP (5) blocks after the last one's box, rows ROW_GAP (8) apart after their
	             deepest box. Each has a name tag: a structure block in SAVE mode on the floor
	             LABEL (3) blocks north of its box's west corner, named after it, its region the
	             box (up to 48 a side: Config.Structures.MaxSize), so WAILA reads its name and F3
	             shows its outline (the server seeds those records from the generator's `labels`,
	             Structures/StructureBlocks). Pieces write through Generation/StructureGen with a
	             fixed layout, so a piece crossing chunk borders is written by every chunk alike,
	             far levels point sample them, and generated chests hold their loot. Then, in a
	             row of their own (in chunks of their own), "mineshaft" and "mineshaft/overgrown"
	             (named as the library's are: structure names hold no spaces):
	             a fixed sample each (Mineshafts.sample: a room, a rail corridor with whole beams,
	             torches and a chest, a crossing, a spider corridor and stairs down), dug by
	             Generation/Mineshafts into the floor's stone (MINESHAFT_DEPTH under the floor,
	             in full detail chunks, as the Default's), the overgrown one with its entrance at
	             the room's centre: the collar and headframe on the floor and a rope all the way
	             down. Their name tags' regions reach down to them.
	All Biomes   strips STRIP (16) blocks wide along x, one per biome in BiomeList order and
	             again (x // 16 mod the biome count), each a column of the biome's own ground
	             (stone, its filler, its top block; first air at FLOOR) with its trees and ground
	             plants, so WAILA's biome line, Tough As Nails' temperatures, foliage tints and the
	             map can be compared side by side. Spawn in the plains strip.

	None spawns mobs (WorldTypes `mobs = false`) and none has weather or fire to tick; All Blocks
	and All Structures have no ticks at all (`ticks = false`: leaves stay without logs nearby,
	sand floats, a showcase stays as generated), All Biomes ticks as any world does.
]]

local Blocks = require(script.Parent.Parent.Blocks)
local Biomes = require(script.Parent.Parent.Biomes)
local Config = require(script.Parent.Parent.Config)
local Hash = require(script.Parent.Parent.Util.Hash)
local Jigsaw = require(script.Parent.Parent.Structures.Jigsaw)
local Library = require(script.Parent.Parent.Structures.Library)
local LayeredGenerator = require(script.Parent.LayeredGenerator)
local StructureGen = require(script.Parent.StructureGen)
local TerrainGenerator = require(script.Parent.TerrainGenerator)
local Mineshafts = require(script.Parent.Mineshafts)
local ChunkLayout = require(script.Parent.Parent.World.ChunkLayout)

type Start = StructureGen.Start
type Piece = Jigsaw.Piece

local DebugWorlds = {}

DebugWorlds.BLOCK_Y = 70
DebugWorlds.FLOOR = 65
DebugWorlds.GAP = 5
DebugWorlds.ROW_GAP = 8
DebugWorlds.LABEL = 3
DebugWorlds.STRIP = 16
-- The sample mineshafts' room floor lies this far under the floor of All Structures.
DebugWorlds.MINESHAFT_DEPTH = 24

local PLAINS = (Biomes.byName("Plains") :: Biomes.Biome).index

--[[ All Blocks ]]

-- Every block id the grid shows, in order (all but air, cave air and the cave twins).
function DebugWorlds.gridBlocks(): { number }
	local list: { number } = {}
	for id = 0, Blocks.count - 1 do
		if id ~= Blocks.AIR and id ~= Blocks.CAVE_AIR and not Blocks.isCaveTwin(id) then
			table.insert(list, id)
		end
	end
	return list
end

-- The grid's width (blocks per row) for `n` blocks.
function DebugWorlds.gridWidth(n: number): number
	return math.max(1, math.ceil(math.sqrt(n)))
end

-- Where block number `k` (0-based) of a grid `width` wide stands: x, z (y is BLOCK_Y).
function DebugWorlds.gridPosition(k: number, width: number): (number, number)
	return 2 * (k // width) + 1, 2 * (k % width) + 1
end

function DebugWorlds.allBlocks(seed: number): TerrainGenerator.Generator
	local list = DebugWorlds.gridBlocks()
	local width = DebugWorlds.gridWidth(#list)
	local placed: { number } = {}
	for k, block in list do
		local x, z = DebugWorlds.gridPosition(k - 1, width)
		table.insert(placed, x)
		table.insert(placed, DebugWorlds.BLOCK_Y)
		table.insert(placed, z)
		table.insert(placed, block)
	end
	local sx, sz = DebugWorlds.gridPosition(0, width)
	return LayeredGenerator.new({
		seed = seed,
		stack = LayeredGenerator.EMPTY,
		biome = PLAINS,
		blocks = placed,
		spawn = { sx, sz },
	})
end

--[[ All Structures ]]

export type Entry = {
	name: string,
	-- The box's west north corner on the floor and its size (blocks).
	x: number,
	z: number,
	sizeX: number,
	sizeZ: number,
	start: Start,
	label: TerrainGenerator.Label,
	-- A sample mineshaft (its `start` has no pieces: Generation/Mineshafts writes it).
	mineshaft: Mineshafts.Plan?,
}

-- A piece moved by (dx, dz).
local function moved(piece: Piece, dx: number, dz: number): Piece
	local b = piece.box
	return {
		template = piece.template,
		x = piece.x + dx,
		y = piece.y,
		z = piece.z + dz,
		rotation = piece.rotation,
		projection = piece.projection,
		depth = piece.depth,
		box = { b[1] + dx, b[2], b[3] + dz, b[4] + dx, b[5], b[6] + dz },
	}
end

--[[
	Every structure of `library` laid out (see the header), in write order: its templates, then
	its generated structures assembled with seeds from `seed`.
]]
function DebugWorlds.structureLayout(seed: number, library: Library.Library): { Entry }
	local floor = DebugWorlds.FLOOR
	local function ground(): number
		return floor
	end

	-- What to lay out: { name, pieces, templates } at any position, then moved into place.
	type Item = { name: string, pieces: { Piece }, templates: { Library.Template } }
	local items: { Item } = {}
	for _, name in library.names do
		local template = library.template(name)
		if template then
			local size = template.size
			local x, y, z = 0, floor - 1, 0
			table.insert(items, {
				name = name,
				pieces = {
					{
						template = name,
						x = x,
						y = y,
						z = z,
						rotation = 0,
						projection = Jigsaw.RIGID,
						depth = 0,
						box = { x, y, z, x + size[1] - 1, y + size[2] - 1, z + size[3] - 1 },
					},
				},
				templates = { template },
			})
		end
	end
	for index, structure in library.structures do
		local pieces = Jigsaw.assemble({
			seed = Hash.hash3(seed, index, structure.salt, 0x5D1E),
			startPool = structure.startPool,
			startJigsawName = structure.startJigsawName,
			x = 0,
			z = 0,
			startHeight = structure.startHeight,
			projectToHeightmap = structure.projectToHeightmap,
			firstFreeHeight = ground,
			maxDepth = structure.size,
			maxDistance = structure.maxDistance,
			pool = library.pool,
			template = library.template,
		})
		local kept: { Piece } = {}
		local templates: { Library.Template } = {}
		for _, piece in pieces do
			local template = library.template(piece.template)
			if template then
				table.insert(kept, piece)
				table.insert(templates, template)
			end
		end
		if #kept > 0 then
			table.insert(items, { name = structure.name, pieces = kept, templates = templates })
		end
	end

	-- Shelf packing, rows of ceil(sqrt(n)).
	local entries: { Entry } = {}
	local perRow = math.max(1, math.ceil(math.sqrt(#items)))
	local maxSize, maxOffset = Config.Structures.MaxSize, Config.Structures.MaxOffset
	local cursorX, rowZ, rowDepth = 0, 0, 0
	for k, item in items do
		if (k - 1) % perRow == 0 and k > 1 then
			rowZ += rowDepth + DebugWorlds.ROW_GAP
			cursorX, rowDepth = 0, 0
		end
		local bounds = Jigsaw.bounds(item.pieces) :: { number }
		local dx, dz = cursorX - bounds[1], rowZ - bounds[3]
		local pieces: { Piece } = {}
		for i, piece in item.pieces do
			pieces[i] = moved(piece, dx, dz)
		end
		local sizeX, sizeY, sizeZ = bounds[4] - bounds[1] + 1, bounds[5] - bounds[2] + 1, bounds[6] - bounds[3] + 1
		local x, z = cursorX, rowZ
		local labelX, labelY, labelZ = x, floor, z - DebugWorlds.LABEL
		table.insert(entries, {
			name = item.name,
			x = x,
			z = z,
			sizeX = sizeX,
			sizeZ = sizeZ,
			start = {
				name = item.name,
				index = k,
				chunkX = x // 16,
				chunkZ = z // 16,
				x = x,
				z = z,
				pieces = pieces,
				templates = item.templates,
				bounds = { x, bounds[2], z, x + sizeX - 1, bounds[5], z + sizeZ - 1 },
				foundation = false,
			},
			label = {
				x = labelX,
				y = labelY,
				z = labelZ,
				name = item.name,
				offset = {
					0,
					math.clamp(bounds[2] - labelY, -maxOffset, maxOffset),
					math.min(DebugWorlds.LABEL, maxOffset),
				},
				size = { math.min(sizeX, maxSize), math.min(sizeY, maxSize), math.min(sizeZ, maxSize) },
			},
		})
		cursorX += sizeX + DebugWorlds.GAP
		rowDepth = math.max(rowDepth, sizeZ)
	end

	-- The sample mineshafts, in a row of chunks after every other entry's. Mineshafts.sample's
	-- bounds reach 1 block west of the room's corner and 18 north, and the room's centre must lie
	-- in a chunk's core columns 3..12 (the entrance's rule): the corner at 3 mod 16.
	local roomY = floor - 1 - DebugWorlds.MINESHAFT_DEPTH
	local roomZ = ((rowZ + rowDepth + DebugWorlds.ROW_GAP + 18) // 16 + 2) * 16 + 3
	local roomX = 3
	for k, name in { "mineshaft", "mineshaft/overgrown" } do
		local plan = Mineshafts.sample(roomX, roomY, roomZ, k == 2, floor)
		local b = plan.bounds
		local sizeX, sizeY, sizeZ = b[4] - b[1] + 1, b[5] - b[2] + 1, b[6] - b[3] + 1
		local x, z = b[1], b[3]
		local labelX, labelY, labelZ = x, floor, z - DebugWorlds.LABEL
		table.insert(entries, {
			name = name,
			x = x,
			z = z,
			sizeX = sizeX,
			sizeZ = sizeZ,
			start = {
				name = name,
				index = #entries + 1,
				chunkX = x // 16,
				chunkZ = z // 16,
				x = x,
				z = z,
				pieces = {},
				templates = {},
				bounds = { x, b[2], z, b[4], b[5], b[6] },
				foundation = false,
			},
			label = {
				x = labelX,
				y = labelY,
				z = labelZ,
				name = name,
				offset = {
					0,
					math.clamp(b[2] - labelY, -maxOffset, maxOffset),
					math.min(DebugWorlds.LABEL, maxOffset),
				},
				size = { math.min(sizeX, maxSize), math.min(sizeY, maxSize), math.min(sizeZ, maxSize) },
			},
			mineshaft = plan,
		})
		-- The next one a chunk apart.
		roomX += (sizeX // 16 + 2) * 16
	end
	return entries
end

-- The floor of the structures world: bedrock, stone, 3 dirt and grass, first air at FLOOR.
local function floorStack(): LayeredGenerator.Stack
	local floor = DebugWorlds.FLOOR
	return LayeredGenerator.stack({
		{ block = Blocks.id.Bedrock, count = 1 },
		{ block = Blocks.id.Stone, count = floor - 5 },
		{ block = Blocks.id.Dirt, count = 3 },
		{ block = Blocks.id.Grass, count = 1 },
	})
end

function DebugWorlds.allStructures(seed: number, library: Library.Library?): TerrainGenerator.Generator
	local lib = library or Library.load()
	local entries = DebugWorlds.structureLayout(seed, lib)
	local starts: { Start } = {}
	local labels: { TerrainGenerator.Label } = {}
	local placed: { number } = {}
	local tag = Blocks.structureBlock("save") :: number
	local samples: { Mineshafts.Plan } = {}
	for _, entry in entries do
		if entry.mineshaft then
			table.insert(samples, entry.mineshaft)
		else
			table.insert(starts, entry.start)
		end
		table.insert(labels, entry.label)
		table.insert(placed, entry.label.x)
		table.insert(placed, entry.label.y)
		table.insert(placed, entry.label.z)
		table.insert(placed, tag)
	end
	local function layout(minX: number, minZ: number, maxX: number, maxZ: number): { Start }
		local list: { Start } = {}
		for _, start in starts do
			local b = start.bounds
			if b[1] <= maxX and b[4] >= minX and b[3] <= maxZ and b[6] >= minZ then
				table.insert(list, start)
			end
		end
		return list
	end
	local floor = DebugWorlds.FLOOR
	local placer = StructureGen.new(seed, lib, {
		firstFreeHeight = function(): number
			return floor
		end,
		biome = function(): number
			return PLAINS
		end,
		land = function(): boolean
			return true
		end,
	}, layout)
	local gen = LayeredGenerator.new({
		seed = seed,
		stack = floorStack(),
		biome = PLAINS,
		blocks = placed,
		placer = placer,
		labels = labels,
		spawn = { -2, -2 * DebugWorlds.LABEL },
	})

	-- The sample mineshafts, written over the flat chunks at full detail as the Default does.
	local function sampleLayout(minX: number, minZ: number, maxX: number, maxZ: number): { Mineshafts.Plan }
		local list: { Mineshafts.Plan } = {}
		for _, plan in samples do
			local b = plan.bounds
			if b[1] <= maxX and b[4] >= minX and b[3] <= maxZ and b[6] >= minZ then
				table.insert(list, plan)
			end
		end
		return list
	end
	local mineshafts = Mineshafts.new(seed, {
		height = function(): number
			return floor
		end,
		biome = function(): number
			return PLAINS
		end,
	}, sampleLayout)
	local flatHeights = table.create(ChunkLayout.PADDED * ChunkLayout.PADDED, floor)
	local generate = gen.generate
	local size = ChunkLayout.SIZE
	local wrapped = table.clone(gen)
	wrapped.generate = function(
		level: number,
		nx: number,
		nz: number,
		yield: (() -> ())?,
		extras: boolean?
	): TerrainGenerator.ChunkResult
		local r = generate(level, nx, nz, yield, extras)
		if level == 0 then
			local originX, originZ = nx * size, nz * size
			local list = mineshafts.plans(originX - 1, originZ - 1, originX + size, originZ + size)
			if #list > 0 then
				local lowest, top, map =
					mineshafts.write(list, r.data, originX, originZ, r.height, flatHeights, r.carved)
				r.carved = map
				r.solidBelow = math.min(r.solidBelow, lowest)
				r.emptyAbove = math.max(r.emptyAbove, math.min(top, r.height))
			end
		end
		return r
	end
	wrapped.structureContainer = function(x: number, y: number, z: number): { StructureGen.ContainerItem }?
		return gen.structureContainer(x, y, z) or mineshafts.container(x, y, z)
	end
	wrapped.mineshafts = function(minX: number, minZ: number, maxX: number, maxZ: number): { Mineshafts.Plan }
		return mineshafts.plans(minX, minZ, maxX, maxZ)
	end
	return wrapped
end

--[[ All Biomes ]]

-- The biome index of the strip holding column x.
function DebugWorlds.biomeAt(x: number): number
	return (x // DebugWorlds.STRIP) % Biomes.count + 1
end

function DebugWorlds.allBiomes(seed: number): TerrainGenerator.Generator
	local floor = DebugWorlds.FLOOR
	local stacks: { LayeredGenerator.Stack } = {}
	for i, biome in Biomes.list do
		local depth = math.clamp(biome.fillerDepth, 0, floor - 2)
		local layers: { LayeredGenerator.Layer } = {
			{ block = Blocks.id.Bedrock, count = 1 },
			{ block = Blocks.id.Stone, count = floor - 2 - depth },
		}
		if depth > 0 then
			table.insert(layers, { block = biome.filler, count = depth })
		end
		table.insert(layers, { block = biome.top, count = 1 })
		stacks[i] = LayeredGenerator.stack(layers)
	end
	local strip = DebugWorlds.STRIP
	return LayeredGenerator.new({
		seed = seed,
		columnAt = function(x: number, _z: number): (LayeredGenerator.Stack, number)
			local b = DebugWorlds.biomeAt(x)
			return stacks[b], b
		end,
		decoration = true,
		spawn = { (PLAINS - 1) * strip + strip // 2, strip // 2 },
	})
end

return DebugWorlds
