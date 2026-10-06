--!strict
--!native
--[[
	Cave carving for full detail (LOD 0) chunks, modelled on JJThunder To The Max: dry caves that
	grow with depth, and the "Underlands", a huge cavern under the highest mountains.

	A cave density F is computed from the depth below the column's surface, in the datapack's height
	unit (d = depth / Relief.LAND_BLOCKS, ~450 blocks); rock is carved where F < 0.
	  * d < 0.02 (~9 blocks): solid; up to d = 0.05 (~22 blocks) caves fade in.
	  * Cave sets "small", "medium" and "large" take over at d = 0.1, 0.35 and 0.7 (~45, 158 and
	    315 blocks deep), blended with smoothsteps. Each set mixes
	      old  blobs: one 3D noise (wavelength 24 / 32 / 48 blocks),
	      new  strata: a smooth sawtooth over height (period 39 / 79 / 157 blocks) tilted by a
	           kilometre-scale noise, plus 3D noise and 2D jagged noise,
	    by `barrier1` (a very wide 3D noise, so most caves are a mix of both kinds).
	  * `barrier2` (3D, ~190 blocks) gates every set: below 0 there are no caves, from 0.5 on the
	    sets are at full strength. Caves come in regions that way, and ~14% of the rock is air.
	  * Beyond d = 0.7 the large set blends into the Underlands, which take over completely at d = 1:
	    the datapack's analytic ygrad - 1.6 H (no noise, no barrier). Under high ground it is
	    strongly negative early in the blend, so the cavern opens ~330 blocks below the surface,
	    down to a floor that sinks as the surface rises: it appears under surfaces above ~540 and
	    is up to ~600 blocks tall under the highest peaks.
	Feature sizes are 0.75 of the datapack's (the player is not scaled down with the terrain), the
	depths scale with the terrain (0.43).

	Evaluating 3D noise per block is far too slow, so F is computed on a world-aligned lattice every
	4 x 8 x 4 blocks and interpolated trilinearly. A lattice cell whose eight corners are all
	positive is solid throughout and skipped; so are lattice points where barrier2 rules caves out
	(one noise call). Chunks agree on their borders because the lattice is aligned to the world.

	Caves are carved as CaveAir and never come within Config.Caves.SurfaceMargin blocks of the
	surface on their own, so the client only meshes cave walls close to the camera (see
	Blocks.cullLutHiddenCaves). What opens them up is SurfaceCaves.luau: cave entrances and ravines,
	carved as Air after this carver (the cave air they run into stays cave air). `Caves.regions`
	gives it barrier2 (the same values), so its entrances can head for the cave regions.
]]

local Config = require(script.Parent.Parent.Config)
local Blocks = require(script.Parent.Parent.Blocks)
local ChunkLayout = require(script.Parent.Parent.World.ChunkLayout)
local Noise = require(script.Parent.Noise)
local Relief = require(script.Parent.Relief)

local SIZE = ChunkLayout.SIZE
local P = ChunkLayout.PADDED
local LAYER = ChunkLayout.LAYER

-- Lattice spacing (blocks).
local GRID_XZ = 4
local GRID_Y = 8

-- Cave feature size relative to the datapack.
local CAVE_SCALE = 0.75
-- Blocks per depth unit (datapack H).
local DEPTH_UNIT = Relief.LAND_BLOCKS

-- Depth knots (H): fade-in, first caves, small / medium / large sets, Underlands.
local D_FADE, D_START = 0.02, 0.05
local D_SMALL, D_MEDIUM, D_LARGE, D_UNDER = 0.1, 0.35, 0.7, 1.0

-- Standard deviation of the datapack's single octave noise (cave_layer) and jagged noise.
local STD_CL, STD_JAGGED = 0.314, 0.341

local floor = math.floor
local huge = math.huge
local writeu16 = buffer.writeu16

local function smoothstep01(t: number): number
	if t <= 0 then
		return 0
	elseif t >= 1 then
		return 1
	end
	return t * t * (3 - 2 * t)
end

-- Smooth sawtooth between +1 and -1 with half period `half` (the datapack's cave baselines).
local function strata(y: number, half: number): number
	local s = y / half
	local k = floor(s)
	local f = s - k
	local smooth = f * f * (3 - 2 * f)
	return if k % 2 == 0 then 1 - 2 * smooth else -1 + 2 * smooth
end

-- (x, z) -> surface height (blocks, the first air block) at full detail.
export type SurfaceSampler = (x: number, z: number) -> number

--[[
	`heights[pz * P + px + 1]` is the terrain height of every padded column, `cells` the chunk's
	buffer height (cells above it are air anyway). `yield` is called regularly (carving a chunk over
	the Underlands is a lot of blocks) so callers can spread the work over several frames.

	Returns where the chunk may hold cave air (Carved), nil when nowhere: cave decoration
	(CaveDecor) only looks there.
]]
export type Carver = (
	data: buffer,
	originX: number,
	originZ: number,
	heights: { number },
	cells: number,
	yield: (() -> ())?
) -> Carved?

--[[
	The lattice cells (CELL_XZ x CELL_Y x CELL_XZ blocks, world aligned) the carver carved in: a
	superset of the cells holding cave air. Cell (lx, ly, lz) starts at world block
	(x + lx * CELL_XZ, y + ly * CELL_Y, z + lz * CELL_XZ); `flags` holds a u8 per cell at index
	(ly * nz + lz) * nx + lx: 0 not carved, 1 carved in, 2 cave air throughout (as far as the
	chunk's padded box goes).
]]
export type Carved = {
	x: number,
	y: number,
	z: number,
	nx: number,
	ny: number,
	nz: number,
	flags: buffer,
}

local Caves = {}

-- Size of the lattice cells in Carved (blocks).
Caves.CELL_XZ = GRID_XZ
Caves.CELL_Y = GRID_Y

-- One cave set: noises in our blocks.
type CaveSet = {
	old: Noise.Sampler3,
	new: Noise.Sampler3,
	jagged: Noise.OctaveSampler2,
	-- Half period of the strata (blocks).
	half: number,
}

--[[
	Marks the lattice cells holding any block of the box (x0..x1, y0..y1, z0..z1, world blocks) as
	carved in (flag 0 becomes 1; 2 stays), for what later passes put into the rock as cave cells
	(Generation/Lava's underground lakes, Generation/OilWells' deposits: cave twins and cave air
	where the carver left rock). `carved` is the chunk's lattice (nil: none yet) for the padded
	chunk whose first core column is (originX, originZ); it is created or grown upwards as needed
	(the same world-aligned cells the carver uses) and returned. The box may reach past the padded
	chunk: only its part inside is marked. Marking a cell that holds no cave cell only costs a read
	(World/SectionGraph reads marked cells instead of assuming rock).
]]
function Caves.mark(
	carved: Carved?,
	originX: number,
	originZ: number,
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number
): Carved?
	-- The carver's lattice over the padded chunk.
	local gx0 = (originX - 1) // GRID_XZ
	local gz0 = (originZ - 1) // GRID_XZ
	local nx = (originX + SIZE) // GRID_XZ + 1 - gx0
	local nz = (originZ + SIZE) // GRID_XZ + 1 - gz0
	x0, z0 = math.max(x0, originX - 1), math.max(z0, originZ - 1)
	x1, z1 = math.min(x1, originX + SIZE), math.min(z1, originZ + SIZE)
	y0 = math.max(y0, 0)
	if x0 > x1 or z0 > z1 or y0 > y1 then
		return carved
	end
	local ly1 = y1 // GRID_Y
	local map: Carved
	if carved == nil then
		local gy0 = math.min(Config.Caves.MinY // GRID_Y, y0 // GRID_Y)
		map = {
			x = gx0 * GRID_XZ,
			y = gy0 * GRID_Y,
			z = gz0 * GRID_XZ,
			nx = nx,
			ny = ly1 - gy0 + 1,
			nz = nz,
			flags = buffer.create(nx * nz * (ly1 - gy0 + 1)),
		}
	else
		map = carved
		local gy0 = map.y // GRID_Y
		if ly1 - gy0 + 1 > map.ny then
			-- Grow upwards: the layers are the outermost index, so the old ones keep their place.
			local ny = ly1 - gy0 + 1
			local flags = buffer.create(map.nx * map.nz * ny)
			buffer.copy(flags, 0, map.flags)
			map = { x = map.x, y = map.y, z = map.z, nx = map.nx, ny = ny, nz = map.nz, flags = flags }
		end
		y0 = math.max(y0, map.y)
	end
	local flags, mnx, mnz = map.flags, map.nx, map.nz
	for ly = (y0 - map.y) // GRID_Y, (y1 - map.y) // GRID_Y do
		for lz = (z0 - map.z) // GRID_XZ, (z1 - map.z) // GRID_XZ do
			local row = (ly * mnz + lz) * mnx
			for lx = (x0 - map.x) // GRID_XZ, (x1 - map.x) // GRID_XZ do
				if buffer.readu8(flags, row + lx) == 0 then
					buffer.writeu8(flags, row + lx, 1)
				end
			end
		end
	end
	return map
end

-- 3D cave noise with the datapack's spread (Noise.noise3 has a standard deviation of 1/3).
local function caveNoise3(seed: number, salt: string, wavelength: number, wavelengthY: number?): Noise.Sampler3
	local n = Noise.noise3(seed, salt, 1 / (wavelength * CAVE_SCALE), wavelength / (wavelengthY or wavelength))
	local k = STD_CL * 3
	return function(x: number, y: number, z: number): number
		return n(x, y, z) * k
	end
end

--[[
	The cave regions: the carver's `barrier2` gate (one 3D noise, ~190 blocks). Below 0 there are
	no caves, from 0.5 on the cave sets are at full strength. Surface caves (SurfaceCaves) steer
	their entrances towards it, so most lead into the cave network.
]]
function Caves.regions(seed: number): Noise.Sampler3
	return caveNoise3(seed, "caves.barrier2", 256)
end

function Caves.new(seed: number, surfaceAt: SurfaceSampler): Carver
	local function noise3(salt: string, wavelength: number, wavelengthY: number?): Noise.Sampler3
		return caveNoise3(seed, salt, wavelength, wavelengthY)
	end
	local function set(name: string, old: number, newXZ: number, newY: number, jagged: number, period: number): CaveSet
		return {
			old = noise3("caves.old." .. name, old),
			new = noise3("caves.new." .. name, newXZ, newY),
			jagged = Noise.octaves2(seed, "caves.jagged." .. name, jagged * CAVE_SCALE, 4, STD_JAGGED),
			half = period * CAVE_SCALE / 2,
		}
	end
	-- Datapack wavelengths: old 256 / xz, new 256 / xz and 256 / y, jagged 65536 / xz, strata period.
	local sets: { CaveSet } = {
		set("small", 32, 25.6, 64, 65.5, 52.4),
		set("medium", 42.7, 51.2, 128, 131, 104.8),
		set("large", 64, 102.4, 256, 262, 209.6),
	}
	local barrier1 = noise3("caves.barrier1", 512)
	local barrier2 = noise3("caves.barrier2", 256)
	-- Tilt of the strata (blocks): the datapack's 0.307 std in its height gradient units.
	local tiltNoise = Noise.octaves2(seed, "caves.tilt", 8533 * CAVE_SCALE, 4, 0.307 * 1048 * CAVE_SCALE)

	local margin = Config.Caves.SurfaceMargin
	local minY = Config.Caves.MinY
	local caveAir = Blocks.CAVE_AIR
	local caveDepth = D_FADE * DEPTH_UNIT

	-- Density of set `k` at a lattice point (`g2` > 0: barrier2's gate, `t1`: old / new mix).
	local function setDensity(
		k: number,
		x: number,
		y: number,
		z: number,
		tilt: number,
		jag: number,
		g2: number,
		t1: number
	): number
		local s = sets[k]
		local old = s.old(x, y, z)
		local new = strata(y + tilt, s.half) + 1.5 * s.new(x, y, z) + 0.5 * jag
		return 0.1 + g2 * (old + (new - old) * t1 - 0.1)
	end

	--[[
		F at a lattice point at height y below a column whose surface is `surface` (`jags`: that
		column's jagged values per set, `tilt` its strata tilt, `under` its Underlands constant).
	]]
	local function density(
		x: number,
		y: number,
		z: number,
		surface: number,
		tilt: number,
		jags: { number },
		under: number
	): number
		local d = (surface - y) / DEPTH_UNIT
		if d < D_FADE then
			return 1
		end
		-- Underlands: the datapack's ygrad(-256 .. 1016 : 1 .. -1) - 1.6 H, with H of the surface.
		local underlands = huge
		if d > D_LARGE then
			local yd = 984 + 1048 * Relief.toH(y)
			underlands = 1 - 2 * (yd + 256) / 1272 - under
			if d >= D_UNDER then
				return underlands
			end
		end

		local b2 = barrier2(x, y, z)
		local g2 = smoothstep01(b2 / 0.5)
		local caves
		local dd = if d < D_START then D_START else d
		if g2 <= 0 then
			caves = 0.1
		else
			local t1 = smoothstep01((barrier1(x, y, z) + 1) / 2)
			if dd <= D_SMALL then
				caves = setDensity(1, x, y, z, tilt, jags[1], g2, t1)
			elseif dd <= D_MEDIUM then
				local a = setDensity(1, x, y, z, tilt, jags[1], g2, t1)
				local b = setDensity(2, x, y, z, tilt, jags[2], g2, t1)
				caves = a + (b - a) * smoothstep01((dd - D_SMALL) / (D_MEDIUM - D_SMALL))
			elseif dd <= D_LARGE then
				local a = setDensity(2, x, y, z, tilt, jags[2], g2, t1)
				local b = setDensity(3, x, y, z, tilt, jags[3], g2, t1)
				caves = a + (b - a) * smoothstep01((dd - D_MEDIUM) / (D_LARGE - D_MEDIUM))
			else
				caves = setDensity(3, x, y, z, tilt, jags[3], g2, t1)
			end
		end
		if d > D_LARGE then
			caves += (underlands - caves) * smoothstep01((d - D_LARGE) / (D_UNDER - D_LARGE))
		end
		-- (The fade-in from solid rock above D_START is applied per block, with the block's own depth.)
		return caves
	end

	-- Lattice scratch (reused; each worker actor has its own copy of this module).
	local field: { number } = {}
	local colSurface: { number }, colTilt: { number }, colUnder: { number } = {}, {}, {}
	local colJags: { { number } } = {}

	return function(
		data: buffer,
		originX: number,
		originZ: number,
		heights: { number },
		cells: number,
		yield: (() -> ())?
	): Carved?
		-- Highest block any cave may reach in this chunk.
		local maxTop = -huge
		for i = 1, P * P do
			local top = heights[i] - margin
			if top > maxTop then
				maxTop = top
			end
		end
		maxTop = math.min(maxTop, cells)
		if maxTop <= minY then
			return nil
		end

		-- Lattice covering the padded chunk.
		local gx0 = (originX - 1) // GRID_XZ
		local gz0 = (originZ - 1) // GRID_XZ
		local nxg = (originX + SIZE) // GRID_XZ + 2 - gx0
		local nzg = (originZ + SIZE) // GRID_XZ + 2 - gz0

		-- Per lattice column: surface, strata tilt, jagged values, Underlands constant.
		local highestCave = -huge
		for lz = 0, nzg - 1 do
			for lx = 0, nxg - 1 do
				local c = lz * nxg + lx + 1
				local x, z = (gx0 + lx) * GRID_XZ, (gz0 + lz) * GRID_XZ
				local surface = surfaceAt(x, z)
				colSurface[c] = surface
				colTilt[c] = tiltNoise(x, z)
				colUnder[c] = 1.6 * Relief.toH(surface)
				local jags = colJags[c]
				if jags == nil then
					jags = {}
					colJags[c] = jags
				end
				for k = 1, 3 do
					jags[k] = sets[k].jagged(x, z)
				end
				highestCave = math.max(highestCave, surface - caveDepth)
			end
		end
		local gy0 = minY // GRID_Y
		local gy1 = math.min(floor(math.min(highestCave, maxTop) / GRID_Y) + 1, (cells - 1) // GRID_Y + 1)
		if gy1 <= gy0 then
			return nil
		end
		local nyg = gy1 - gy0 + 1
		local layer = nxg * nzg

		-- Density at every lattice point.
		local i = 1
		for ly = 0, nyg - 1 do
			if yield and ly % 4 == 3 then
				yield()
			end
			local y = (gy0 + ly) * GRID_Y
			for lz = 0, nzg - 1 do
				local z = (gz0 + lz) * GRID_XZ
				for lx = 0, nxg - 1 do
					local c = lz * nxg + lx + 1
					field[i] = density((gx0 + lx) * GRID_XZ, y, z, colSurface[c], colTilt[c], colJags[c], colUnder[c])
					i += 1
				end
			end
		end

		-- Carve every lattice cell that is not solid at all eight corners.
		local stride = LAYER * 2
		local carved: Carved? = nil
		for ly = 0, nyg - 2 do
			if yield then
				yield()
			end
			local cellY = (gy0 + ly) * GRID_Y
			for lz = 0, nzg - 2 do
				local cellZ = (gz0 + lz) * GRID_XZ
				for lx = 0, nxg - 2 do
					local i000 = ly * layer + lz * nxg + lx + 1
					local f000, f100 = field[i000], field[i000 + 1]
					local f010, f110 = field[i000 + nxg], field[i000 + nxg + 1]
					local i001 = i000 + layer
					local f001, f101 = field[i001], field[i001 + 1]
					local f011, f111 = field[i001 + nxg], field[i001 + nxg + 1]
					if f000 < 0 or f100 < 0 or f010 < 0 or f110 < 0 or f001 < 0 or f101 < 0 or f011 < 0 or f111 < 0 then
						local map: Carved
						if carved then
							map = carved
						else
							map = {
								x = gx0 * GRID_XZ,
								y = gy0 * GRID_Y,
								z = gz0 * GRID_XZ,
								nx = nxg - 1,
								ny = nyg - 1,
								nz = nzg - 1,
								flags = buffer.create((nxg - 1) * (nyg - 1) * (nzg - 1)),
							}
							carved = map
						end
						-- Air at every corner is air throughout (below the fade-in).
						local open = f000 < 0
							and f100 < 0
							and f010 < 0
							and f110 < 0
							and f001 < 0
							and f101 < 0
							and f011 < 0
							and f111 < 0
						local cellX = (gx0 + lx) * GRID_XZ
						-- Padded chunk coordinates of the cell's blocks.
						local px0 = math.max(cellX - originX + 1, 0)
						local px1 = math.min(cellX + GRID_XZ - 1 - originX + 1, P - 1)
						local pz0 = math.max(cellZ - originZ + 1, 0)
						local pz1 = math.min(cellZ + GRID_XZ - 1 - originZ + 1, P - 1)
						local y0 = math.max(cellY, minY)
						local y1 = math.min(cellY + GRID_Y - 1, cells - 1)
						-- Whether every block of the cell in the chunk becomes cave air.
						local full = open and y0 == cellY and y1 == cellY + GRID_Y - 1
						for pz = pz0, pz1 do
							local tz = (originZ + pz - 1 - cellZ) / GRID_XZ
							for px = px0, px1 do
								local tx = (originX + px - 1 - cellX) / GRID_XZ
								local top = heights[pz * P + px + 1] - margin
								local surface = top + margin
								local last = math.min(y1, top - 1, floor(surface - caveDepth))
								local base = (pz * P + px) * 2
								if open and last < surface - D_START * DEPTH_UNIT then
									for y = y0, last do
										writeu16(data, base + y * stride, caveAir)
									end
									if last < y1 then
										full = false
									end
									continue
								end
								full = false
								-- Bilinear in x / z at the cell's bottom and top.
								local b0 = f000 + (f100 - f000) * tx
								local b1 = f010 + (f110 - f010) * tx
								local bottom = b0 + (b1 - b0) * tz
								local t0 = f001 + (f101 - f001) * tx
								local t1 = f011 + (f111 - f011) * tx
								local upper = t0 + (t1 - t0) * tz
								if bottom < 0 or upper < 0 then
									for y = y0, last do
										local f = bottom + (upper - bottom) * (y - cellY) / GRID_Y
										local d = (surface - y) / DEPTH_UNIT
										if d < D_START then
											-- Fade in from solid rock (lattice depths are off on steep slopes).
											f = d + (f - d) * smoothstep01((d - D_FADE) / (D_START - D_FADE))
										end
										if f < 0 then
											writeu16(data, base + y * stride, caveAir)
										end
									end
								end
							end
						end
						buffer.writeu8(map.flags, (ly * (nzg - 1) + lz) * (nxg - 1) + lx, if full then 2 else 1)
					end
				end
			end
		end
		return carved
	end
end

return Caves
