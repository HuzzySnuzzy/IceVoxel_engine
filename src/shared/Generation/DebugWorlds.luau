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
	             down. Their name tags' regions reach down to them. Last, after every other entry
	             (its footprint's corner on a chunk's corner), "city": the zombie apocalypse's
	             sample town (Cities.sample: one parcel of every kind, a bunker shed), written over
	             the floor as the Default writes its cities at levels 0..Config.Cities.LodLevels:
	             the streets' surface over the grass (with its filler at full detail, in the
	             ground's top cell beyond), the buildings (massing beyond full detail), each chunk
	             grown to hold them; its containers (its buildings' and its wrecks' crates) hold
	             their loot, the map paints it (`cities`), /locate lists it and `cityAt` marks its
	             footprint (Players/SafeSpot keeps to its full floors).
	All Biomes   strips STRIP (16) blocks wide along x, one per biome in BiomeList order and
	             again (x // 16 mod the biome count), each a column of the biome's own ground
	             (stone, its filler, its top block; first air at FLOOR) with its trees and ground
	             plants, so WAILA's biome line, Tough As Nails' temperatures, foliage tints and the
	             map can be compared side by side. Spawn in the plains strip.

	None spawns mobs (WorldTypes `mobs = false`) and none has weather or fire to tick; All Blocks
	and All Structures have no ticks at all (`ticks = false`: leaves stay without logs nearby,
	sand floats, a showcase stays as generated), All Biomes ticks as any world does.

	/locate in All Biomes: its `climateScale` (a quarter) has the biome search sample every 8
	blocks, so no strip falls between two samples. In All Structures (Generation/Locate): its
	`locateList` holds every generated jigsaw
	structure laid out (at its start piece's centre, by its id) and the two sample mineshafts
	("mineshaft", "mineshaft_overgrown" at their room's centre, and the overgrown one's
	"mineshaft_entrance") and the sample town ("city", at its centre); `poiBlocks` adds the
	samples' containers.
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
local Cities = require(script.Parent.Cities)
local CityLayout = require(script.Parent.CityLayout)
local ScavengeLoot = require(script.Parent.ScavengeLoot)
local Locate = require(script.Parent.Locate)
local ChunkLayout = require(script.Parent.Parent.World.ChunkLayout)
local Horizon = require(script.Parent.Parent.World.Horizon)

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
	-- The sample town (its `start` has no pieces: Generation/CityLayout writes it).
	city: CityLayout.Plan?,
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

	-- The sample town (Cities.sample), after every other entry: its footprint's corner on a
	-- chunk's corner, its name tag ROW_GAP south of the furthest box.
	local furthest = 0
	for _, e in entries do
		furthest = math.max(furthest, e.start.bounds[6])
	end
	local radius = 2 * 32 + 3
	local townX, townZ = 0, ((furthest + DebugWorlds.ROW_GAP + DebugWorlds.LABEL) // 16 + 1) * 16
	local town = Cities.sample(townX + radius, townZ + radius, floor)
	local side = 2 * radius + 1
	local townTop = CityLayout.topIn(town, townX, townZ, townX + side - 1, townZ + side - 1)
	table.insert(entries, {
		name = "city",
		x = townX,
		z = townZ,
		sizeX = side,
		sizeZ = side,
		start = {
			name = "city",
			index = #entries + 1,
			chunkX = townX // 16,
			chunkZ = townZ // 16,
			x = townX,
			z = townZ,
			pieces = {},
			templates = {},
			bounds = { townX, floor - 1, townZ, townX + side - 1, townTop - 1, townZ + side - 1 },
			foundation = false,
		},
		label = {
			x = townX,
			y = floor,
			z = townZ - DebugWorlds.LABEL,
			name = "city",
			offset = { 0, -1, math.min(DebugWorlds.LABEL, maxOffset) },
			size = { math.min(side, maxSize), math.min(townTop - floor + 1, maxSize), math.min(side, maxSize) },
		},
		city = town,
	})
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
	local towns: { CityLayout.Plan } = {}
	for _, entry in entries do
		if entry.mineshaft then
			table.insert(samples, entry.mineshaft)
		elseif entry.city then
			table.insert(towns, entry.city)
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

	-- The sample towns whose footprint reaches the block rectangle (inclusive).
	local function townsIn(minX: number, minZ: number, maxX: number, maxZ: number): { CityLayout.Plan }
		local list: { CityLayout.Plan } = {}
		for _, plan in towns do
			local R = plan.radius
			if plan.x - R <= maxX and plan.x + R >= minX and plan.z - R <= maxZ and plan.z + R >= minZ then
				table.insert(list, plan)
			end
		end
		return list
	end
	-- The sample towns over chunk `r` (see the header).
	local function writeTowns(r: TerrainGenerator.ChunkResult, level: number, nx: number, nz: number, extras: boolean?)
		local step, stepY = ChunkLayout.steps(level)
		local originX, originZ = nx * size * step, nz * size * step
		local x0, z0, x1, z1 = CityLayout.span(level, originX, originZ)
		local list = townsIn(x0, z0, x1, z1)
		if #list == 0 then
			return
		end
		local top = 0
		for _, plan in list do
			top = math.max(top, CityLayout.topIn(plan, x0, z0, x1, z1))
		end
		local cells = ChunkLayout.croppedHeight(top // stepY + 2, stepY)
		if cells > r.height then
			r.data = ChunkLayout.grow(r.data, cells)
			r.height = cells
		end
		local data = r.data
		local P, LAYER = ChunkLayout.PADDED, ChunkLayout.LAYER
		if level == 0 then
			-- The streets' surface over the floor's grass, their filler over its dirt.
			for _, plan in list do
				local side = 2 * plan.radius
				for z = math.max(z0, plan.z0), math.min(z1, plan.z0 + side) do
					for x = math.max(x0, plan.x0), math.min(x1, plan.x0 + side) do
						local block, filler = CityLayout.surface(plan, x, z)
						if block and filler then
							local column = ((z - z0) * P + (x - x0)) * 2
							buffer.writeu16(data, (floor - 1) * LAYER * 2 + column, block)
							for y = floor - 4, floor - 2 do
								buffer.writeu16(data, y * LAYER * 2 + column, filler)
							end
						end
					end
				end
			end
		else
			-- Far nodes (up to LodLevels, as the buildings): the streets' surface in the ground's
			-- top cell of each column whose sample block lies on one (a skirt column, whose top
			-- cell lies lower, keeps its grass).
			local ground = LayeredGenerator.topCellOf(floor, stepY, stepY // 2)
			for _, plan in list do
				local side = 2 * plan.radius
				for pz = 0, P - 1 do
					local z = z0 + pz * step
					if z < plan.z0 or z > plan.z0 + side then
						continue
					end
					for px = 0, P - 1 do
						local x = x0 + px * step
						if x < plan.x0 or x > plan.x0 + side then
							continue
						end
						local block = CityLayout.surface(plan, x, z)
						local at = (ground * LAYER + pz * P + px) * 2
						if block and ground >= 0 and buffer.readu16(data, at) ~= Blocks.AIR then
							buffer.writeu16(data, at, block)
						end
					end
				end
			end
		end
		CityLayout.begin(data, r.height, level, originX, originZ)
		for _, plan in list do
			local n = plan.n
			for pv = math.max(0, (z0 - plan.z0) // 32), math.min(n - 1, (z1 - plan.z0) // 32) do
				for pu = math.max(0, (x0 - plan.x0) // 32), math.min(n - 1, (x1 - plan.x0) // 32) do
					CityLayout.writeLot(plan, CityLayout.lot(plan, pu, pv))
				end
			end
			CityLayout.writeStreetCars(plan)
		end
		local lowest, written = CityLayout.finish()
		if lowest == math.huge then
			return
		end
		r.solidBelow = math.min(r.solidBelow, lowest)
		r.emptyAbove = math.max(r.emptyAbove, math.min(written, r.height))
		if extras then
			local span = r.structureSpan
			r.structureSpan = if span
				then { math.min(span[1], lowest), math.max(span[2], written - 1) }
				else { lowest, written - 1 }
			-- (The Horizon summary again: its tiles' tops reach the buildings now.)
			local ground = LayeredGenerator.topCellOf(floor, stepY, stepY // 2)
			local topCells = table.create(ChunkLayout.PADDED * ChunkLayout.PADDED, ground)
			r.summary = Horizon.summarise(data, r.height, r.emptyAbove, topCells, stepY)
		end
	end
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
		if level <= Config.Cities.LodLevels then
			writeTowns(r, level, nx, nz, extras)
		end
		return r
	end
	-- (The sample towns' containers: Cities' loot salt of this seed.)
	local townLoot = Hash.hash2(seed, Hash.string("cities.loot"), 0x0C17)
	local function townContainers(
		minX: number,
		minZ: number,
		maxX: number,
		maxZ: number,
		visit: (x: number, y: number, z: number, block: number, loot: string) -> ()
	)
		-- (Its buildings' and its wrecks' crates, as a city's: CityLayout.containersIn.)
		for _, plan in townsIn(minX, minZ, maxX, maxZ) do
			CityLayout.containersIn(plan, minX, minZ, maxX, maxZ, visit)
		end
	end
	wrapped.structureContainer = function(x: number, y: number, z: number): { StructureGen.ContainerItem }?
		local found = gen.structureContainer(x, y, z) or mineshafts.container(x, y, z)
		if found then
			return found
		end
		townContainers(x, z, x, z, function(cx: number, cy: number, cz: number, _block: number, loot: string)
			if cy == y and found == nil then
				found = ScavengeLoot.roll(loot, townLoot, cx, cy, cz)
			end
		end)
		return found
	end
	wrapped.cities = function(
		minX: number,
		minZ: number,
		maxX: number,
		maxZ: number,
		_yield: (() -> ())?
	): { Cities.Site }
		local out: { Cities.Site } = {}
		for _, plan in townsIn(minX, minZ, maxX, maxZ) do
			table.insert(out, {
				gx = plan.gx,
				gz = plan.gz,
				x = plan.x,
				z = plan.z,
				radius = plan.radius,
				y = plan.y,
				salt = plan.salt,
			})
		end
		return out
	end
	wrapped.cityAt = function(x: number, z: number): number
		return if #townsIn(x, z, x, z) > 0 then 1 else 0
	end
	wrapped.mineshafts = function(
		minX: number,
		minZ: number,
		maxX: number,
		maxZ: number,
		yield: (() -> ())?
	): { Mineshafts.Plan }
		return mineshafts.plans(minX, minZ, maxX, maxZ, yield)
	end

	-- /locate: the laid out generated structures and the sample mineshafts (see the header).
	local listed: { Locate.Listed } = {}
	for _, entry in entries do
		local plan = entry.mineshaft
		if plan then
			local box = plan.pieces[1].box
			local id = if plan.overgrown then "mineshaft_overgrown" else "mineshaft"
			local x, z = (box[1] + box[4]) // 2, (box[3] + box[6]) // 2
			table.insert(listed, { id = id, x = x, y = plan.y + 1, z = z, showY = true })
			local entrance = plan.entrance
			if entrance then
				table.insert(listed, {
					id = "mineshaft_entrance",
					x = entrance.x,
					y = entrance.top,
					z = entrance.z,
					showY = true,
				})
			end
		elseif entry.city then
			table.insert(listed, { id = "city", x = entry.city.x, y = floor, z = entry.city.z, showY = false })
		elseif lib.structure(entry.name) and #entry.start.pieces > 0 then
			local box = entry.start.pieces[1].box
			table.insert(listed, {
				id = Locate.snake(entry.name),
				x = (box[1] + box[4]) // 2,
				y = floor,
				z = (box[3] + box[6]) // 2,
				showY = false,
			})
		end
	end
	wrapped.locateList = function(): { Locate.Listed }
		return listed
	end
	local poiBlocks = gen.poiBlocks
	wrapped.poiBlocks = function(
		minX: number,
		minZ: number,
		maxX: number,
		maxZ: number,
		lut: buffer,
		yield: (() -> ())?
	): { number }
		local out = if poiBlocks then poiBlocks(minX, minZ, maxX, maxZ, lut, yield) else {}
		Mineshafts.poiBlocks(sampleLayout(minX, minZ, maxX, maxZ), lut, minX, minZ, maxX, maxZ, out)
		townContainers(minX, minZ, maxX, maxZ, function(x: number, y: number, z: number, block: number, _loot: string)
			if buffer.readu8(lut, block) ~= 0 then
				table.insert(out, x)
				table.insert(out, y)
				table.insert(out, z)
				table.insert(out, block)
			end
		end)
		return out
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
	local gen = LayeredGenerator.new({
		seed = seed,
		columnAt = function(x: number, _z: number): (LayeredGenerator.Stack, number)
			local b = DebugWorlds.biomeAt(x)
			return stacks[b], b
		end,
		decoration = true,
		spawn = { (PLAINS - 1) * strip + strip // 2, strip // 2 },
	})
	-- (Biomes 16 blocks wide: /locate biome samples them 8 apart, a quarter of its 32.)
	gen.climateScale = strip / 64
	return gen
end

return DebugWorlds
