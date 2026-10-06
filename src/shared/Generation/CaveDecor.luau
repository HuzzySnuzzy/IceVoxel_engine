--!strict
--!native
--[[
	Cave decoration for full detail (LOD 0) chunks: glow lichen on cave walls and ceilings,
	Minecraft 1.20.1's `glow_lichen` feature.

	Minecraft places it with 104-157 tries per chunk: a random cave air (or water) block 13+
	blocks below the surface (SurfaceRelativeThresholdFilter on OCEAN_FLOOR_WG), on the faces of
	stone-type blocks next to it (stone, andesite, diorite, granite, calcite, tuff, deepslate,
	dripstone), ceilings and walls only (can_place_on_floor false), and spreading from there to
	neighbouring faces half the time. So lichen comes in small patches here and there.

	Here lichen grows in patches, and every cell is decided from the seed, its world position and
	its own neighbourhood, so a chunk's padding grows what the neighbouring core grows:
	  1. patches: the world is cut into GRID^3 block cells, each holding a patch with
	     PATCH_CHANCE at a hashed centre with a hashed radius (MIN_RADIUS..MAX_RADIUS). A chunk
	     visits the patches whose sphere reaches its padded box, and in them only the cells of the
	     cave lattice cells the carver carved, but not those that are cave air throughout with
	     cave air all around (Caves.Carved: no cell there can touch rock), so skipping the rest
	     changes nothing. The work follows the cave walls near patches, not the rock or the cave
	     volume (an Underlands chunk has 100k+ cells of cave air);
	  2. a cell in a patch's sphere must be CaveAir at least DEPTH blocks below its column's
	     surface (y <= height - 13);
	  3. a face is a candidate when the block on that side (above, or north / south / west /
	     east) is rock: the stone types above (this world has no tuff, deepslate or dripstone)
	     and every block Ores places. Ores only ever replace stone, and only in each chunk's own
	     core, so counting them as rock makes a cell next to an ore decide alike in every chunk;
	  4. a per-cell hash is rolled against PEAK, fading linearly to 0 at the sphere's edge:
	     Minecraft's tries-and-spreading as clusters. Where patches overlap, each tests the same
	     roll against its own fade, so a cell grows lichen when any of them lets it, whatever
	     order they are visited in;
	  5. one face per cell (this game's lichen covers one face): the first candidate in a hashed
	     rotation of Up, North, East, South, West, and the cell becomes the cave twin on that face
	     (CaveGlowLichenUp, CaveGlowLichenNorth ...), which looks, drops and behaves like
	     GlowLichen* but counts as cave air while caves are hidden.

	Padding: a cell in the outermost padding ring can't see its outward neighbour (outside the
	buffer), which then never counts as rock, so it may differ from the neighbouring chunk's core:
	cave air here, lichen there, or another face. That is harmless: the mesher only draws core
	cells, and cave air and cave twins cull alike in both modes (neither hides anything when caves
	are shown, both are rock when they are hidden: Blocks.cullLut, Blocks.cullLutHiddenCaves).
	tests/spec/CaveLichen checks both by meshing.

	Run after caves and ores (and structures, so lichen only clings to rock that is still there).
]]

local Config = require(script.Parent.Parent.Config)
local Blocks = require(script.Parent.Parent.Blocks)
local ChunkLayout = require(script.Parent.Parent.World.ChunkLayout)
local Hash = require(script.Parent.Parent.Util.Hash)
local Ores = require(script.Parent.Ores)
local Caves = require(script.Parent.Caves)

local P = ChunkLayout.PADDED
local STRIDE = ChunkLayout.LAYER * 2
local CAVE_AIR = Blocks.CAVE_AIR

-- Tuning --------------------------------------------------------------------------------------------
-- Blocks below the column's surface height (first air) a lichen must be: Minecraft's -13.
local DEPTH = 13
-- Patch grid (blocks), the chance a grid cell holds a patch, and the patches' radii (blocks).
-- (One patch in about 30 grid cells: lichen is a find in a cave, not every corner of it.)
local GRID = 8
local PATCH_CHANCE = 0.08
local MIN_RADIUS, MAX_RADIUS = 2, 4
-- Chance of a candidate cell at a patch's centre (fading to 0 at its edge).
local PEAK = 0.6

local CELL_XZ, CELL_Y = Caves.CELL_XZ, Caves.CELL_Y

local readu16 = buffer.readu16
local writeu16 = buffer.writeu16
local readu8 = buffer.readu8
local writeu8 = buffer.writeu8
local bxor = bit32.bxor
local rshift = bit32.rshift
local btest = bit32.btest

local CaveDecor = {}

-- Rock lichen clings to (u8 per block id): Minecraft's stone types this world has, and everything
-- Ores places.
local ROCK = buffer.create(Blocks.count)
for _, name in { "Stone", "Andesite", "Diorite", "Granite", "Calcite" } do
	buffer.writeu8(ROCK, Blocks.id[name], 1)
end
for _, ore in Ores.FEATURES do
	buffer.writeu8(ROCK, ore.block, 1)
end

-- The same as a table (1 / 0 by id; -1, the unknown block past the padding, is no rock).
local rock: { [number]: number } = { [-1] = 0 }
for id = 0, Blocks.count - 1 do
	rock[id] = readu8(ROCK, id)
end

-- Is `block` rock lichen grows on?
function CaveDecor.isRock(block: number): boolean
	return block >= 0 and block < Blocks.count and readu8(ROCK, block) == 1
end

CaveDecor.DEPTH = DEPTH
CaveDecor.GRID = GRID
CaveDecor.PATCH_CHANCE = PATCH_CHANCE
CaveDecor.MAX_RADIUS = MAX_RADIUS
CaveDecor.PEAK = PEAK

-- The cave twin for each face, in the order a cell tries them: Up, North, East, South, West.
local FACES = { "Up", "North", "East", "South", "West" }
local TWINS: { number } = {}
for i, face in FACES do
	TWINS[i] = Blocks.id["CaveGlowLichen" .. face]
end
CaveDecor.TWINS = table.freeze(table.clone(TWINS))

--[[
	A cell's u32 hash: its position folded into 32 bits by odd multipliers (exact for |x|, |z| <
	2^26 and |y| < 2^14), then MurmurHash3's finaliser with the salt, its products split in 16-bit
	halves so they stay exact.
]]
local function cellHash(salt: number, x: number, y: number, z: number): number
	local h = bxor(salt, (x * 0x3243F6B + z * 0x2B7E151 + y * 0x1B873) % 4294967296)
	h = bxor(h, rshift(h, 16))
	h = ((h % 65536) * 0x85EBCA6B + (h // 65536) * 0xCA6B % 65536 * 65536) % 4294967296
	h = bxor(h, rshift(h, 13))
	h = ((h % 65536) * 0xC2B2AE35 + (h // 65536) * 0xAE35 % 65536 * 65536) % 4294967296
	return bxor(h, rshift(h, 16))
end

--[[
	Grows lichen in the padded LOD 0 chunk `data` (`cells` tall) whose first core column is
	(originX, originZ); `heights[pz * PADDED + px + 1]` is each padded column's surface height
	(first air) and `carved` where the carver may have left cave air (Caves.Carver). Returns how
	many lichen it placed.
]]
export type Decorator = (
	data: buffer,
	cells: number,
	originX: number,
	originZ: number,
	heights: { number },
	carved: Caves.Carved
) -> number

function CaveDecor.new(seed: number): Decorator
	local patchSalt = Hash.hash2(seed, Hash.string("caves.lichenPatches"), 0x9A7C)
	local cellSalt = Hash.hash2(seed, Hash.string("caves.lichen"), 0x11C4)
	local minY = math.max(1, Config.Caves.MinY)
	local chance = math.floor(PATCH_CHANCE * 65536)
	-- Which lattice cells to visit (reused; each worker actor has its own decorator).
	local scratch = buffer.create(1024)

	return function(
		data: buffer,
		cells: number,
		originX: number,
		originZ: number,
		heights: { number },
		carved: Caves.Carved
	): number
		local flags = carved.flags
		local fx, fy, fz = carved.x, carved.y, carved.z
		local nx, ny, nz = carved.nx, carved.ny, carved.nz
		-- Lowest and highest cell any lichen may take.
		local lowest = math.max(minY, fy)
		local highest = -1
		for i = 1, P * P do
			local top = heights[i] - DEPTH
			if top > highest then
				highest = top
			end
		end
		highest = math.min(highest, cells - 2, fy + ny * CELL_Y - 1)
		if highest < lowest then
			return 0
		end
		-- The padded box in world blocks.
		local x0, z0 = originX - 1, originZ - 1
		local x1, z1 = x0 + P - 1, z0 + P - 1
		local placed = 0

		--[[
			What to visit in each lattice cell: 0 nothing (not carved, or cave air throughout with
			cave air all around), 1 everything (carved in), 2 + sides for a cell that is cave air
			throughout: only its blocks on the sides (bits 1 west, 2 east, 4 north, 8 south, 16 up)
			whose neighbouring lattice cell isn't, as no other block of it can touch rock. Lattice
			cells past the padded box count as cave air (their blocks are unknown, never rock); above
			the lattice is rock. (Floors grow no lichen, so the side below doesn't matter.)
		]]
		local visit = scratch
		if buffer.len(visit) < nx * ny * nz then
			visit = buffer.create(nx * ny * nz)
			scratch = visit
		end
		for ly = 0, ny - 1 do
			for lz = 0, nz - 1 do
				for lx = 0, nx - 1 do
					local i = (ly * nz + lz) * nx + lx
					local flag = readu8(flags, i)
					local v = flag
					if flag == 2 then
						local sides = 0
						if lx > 0 and readu8(flags, i - 1) ~= 2 then
							sides += 1
						end
						if lx < nx - 1 and readu8(flags, i + 1) ~= 2 then
							sides += 2
						end
						if lz > 0 and readu8(flags, i - nx) ~= 2 then
							sides += 4
						end
						if lz < nz - 1 and readu8(flags, i + nx) ~= 2 then
							sides += 8
						end
						if ly == ny - 1 or readu8(flags, i + nx * nz) ~= 2 then
							sides += 16
						end
						v = if sides == 0 then 0 else 2 + sides
					end
					writeu8(visit, i, v)
				end
			end
		end

		for gy = (lowest - MAX_RADIUS) // GRID, (highest + MAX_RADIUS) // GRID do
			for gz = (z0 - MAX_RADIUS) // GRID, (z1 + MAX_RADIUS) // GRID do
				for gx = (x0 - MAX_RADIUS) // GRID, (x1 + MAX_RADIUS) // GRID do
					local h = cellHash(patchSalt, gx, gy, gz)
					if h % 65536 >= chance then
						continue
					end
					-- The patch: centre and radius from the hash's upper bits.
					local bits = h // 65536
					local cx = gx * GRID + bits % GRID
					local cy = gy * GRID + (bits // GRID) % GRID
					local cz = gz * GRID + (bits // (GRID * GRID)) % GRID
					local r = MIN_RADIUS + (bits // (GRID * GRID * GRID)) % (MAX_RADIUS - MIN_RADIUS + 1)
					local ya, yb = math.max(cy - r, lowest), math.min(cy + r, highest)
					local za, zb = math.max(cz - r, z0), math.min(cz + r, z1)
					local xa, xb = math.max(cx - r, x0), math.min(cx + r, x1)
					if ya > yb or za > zb or xa > xb then
						continue
					end
					-- Only patches reaching a lattice cell worth visiting.
					local near = false
					local la, lb = (xa - fx) // CELL_XZ, (xb - fx) // CELL_XZ
					for ly = (ya - fy) // CELL_Y, (yb - fy) // CELL_Y do
						for lz = (za - fz) // CELL_XZ, (zb - fz) // CELL_XZ do
							local row = (ly * nz + lz) * nx
							for lx = la, lb do
								if readu8(visit, row + lx) ~= 0 then
									near = true
									break
								end
							end
							if near then
								break
							end
						end
						if near then
							break
						end
					end
					if not near then
						continue
					end
					local reach2 = (r + 0.5) * (r + 0.5)
					for y = ya, yb do
						local dy = y - cy
						local layer = (y - fy) // CELL_Y * nz
						for z = za, zb do
							local dz = z - cz
							-- The sphere's row: |dx| <= w.
							local left = reach2 - dy * dy - dz * dz
							if left < 0 then
								continue
							end
							local w = math.floor(math.sqrt(left))
							local ra, rb = math.max(cx - w, x0), math.min(cx + w, x1)
							if ra > rb then
								continue
							end
							local pz = z - z0
							local row = (y * P + pz) * P - x0
							local lz = (z - fz) // CELL_XZ
							local cellRow = (layer + lz) * nx
							-- The row's place in its lattice cells: first / last row along z, top
							-- layer.
							local zIn = z - fz - lz * CELL_XZ
							local rowSides = (if zIn == 0 then 4 else 0)
								+ (if zIn == CELL_XZ - 1 then 8 else 0)
								+ (if (y - fy) % CELL_Y == CELL_Y - 1 then 16 else 0)
							-- Only the stretches of the lattice cells worth visiting.
							for lx = (ra - fx) // CELL_XZ, (rb - fx) // CELL_XZ do
								local v = readu8(visit, cellRow + lx)
								if v == 0 then
									continue
								end
								local ax = fx + lx * CELL_XZ
								local sa = math.max(ra, ax)
								local sb = math.min(rb, ax + CELL_XZ - 1)
								-- A cell of cave air throughout: its west / east column, or the
								-- whole row on a side that matters, or nothing.
								local sa2, sb2 = 1, 0
								if v >= 2 and not btest(v - 2, rowSides) then
									local sides = v - 2
									local west, east = btest(sides, 1), btest(sides, 2)
									if west and east then
										sa2, sb2 = math.max(sa, ax + CELL_XZ - 1), sb
										sb = math.min(sb, ax)
									elseif west then
										sb = math.min(sb, ax)
									elseif east then
										sa = math.max(sa, ax + CELL_XZ - 1)
									else
										continue
									end
								end
								for part = 1, 2 do
									if part == 2 then
										sa, sb = sa2, sb2
									end
									if sa > sb then
										continue
									end
									-- Along the row each cell is read once: the one before is the west
									-- neighbour, the one after the east one (a big cavern is mostly
									-- open cells with no rock around them, so reads are the cost).
									local west = if sa > x0 then readu16(data, (row + sa - 1) * 2) else -1
									local here = readu16(data, (row + sa) * 2)
									for x = sa, sb do
										local at = (row + x) * 2
										local px = x - x0
										local east = if px < P - 1 then readu16(data, at + 2) else -1
										local block = here
										local before = west
										west, here = here, east
										if block ~= CAVE_AIR or y > heights[pz * P + px + 1] - DEPTH then
											continue
										end
										-- Candidate faces as bits (1 Up, 2 North, 4 East, 8 South,
										-- 16 West); the outward side of the outermost padding ring is
										-- unknown (-1), so never rock.
										local faces = rock[readu16(data, at + STRIDE)]
											+ rock[east] * 4
											+ rock[before] * 16
										if pz > 0 then
											faces += rock[readu16(data, at - P * 2)] * 2
										end
										if pz < P - 1 then
											faces += rock[readu16(data, at + P * 2)] * 8
										end
										if faces == 0 then
											continue
										end
										-- The roll: PEAK at the centre, 0 at the sphere's edge.
										local k = cellHash(cellSalt, x, y, z)
										local dx = x - cx
										local fade = 1 - math.sqrt((dx * dx + dy * dy + dz * dz) / reach2)
										if (k % 65536) / 65536 >= PEAK * fade then
											continue
										end
										local first = (k // 65536) % 5
										for i = 0, 4 do
											local face = (first + i) % 5
											if btest(faces, bit32.lshift(1, face)) then
												writeu16(data, at, TWINS[face + 1])
												placed += 1
												break
											end
										end
									end
								end
							end
						end
					end
				end
			end
		end
		return placed
	end
end

return CaveDecor
