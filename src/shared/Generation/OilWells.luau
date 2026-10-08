--!strict
--!native
--[[
	Oil wells: BuildCraft's oil (OilPopulate, BuildCraft 7.1), on this world's terms.

	Placement. The world is cut into Spacing x Spacing block cells (Config.Caves.OilWells), each
	with one candidate at a hashed column (INSET blocks from the cell's sides, so a well never
	reaches past its cell). It becomes a well with a chance by the biome at that column: the
	`Biomes` listed (deserts, savannas and plains, BuildCraft's oil biomes with their bonus) are
	much more likely than other land (`Chance`), and columns under the sea (`Sea`) give undersea
	pockets. Never within SpawnClearance blocks of the spawn, nor where a library structure's
	piece comes within MARGIN blocks of it. Sizes by share (`Sizes`): large and medium wells have
	a geyser on land, small ones never; undersea pockets are all of `SeaSize` (small).

	A well (decided from the seed, its cell and the full detail terrain only, so every chunk and
	LOD level agrees, and kept in a small cache per generator):
	  * the deposit: a sphere of `radius` (BuildCraft's distance <= radius^2) whose centre lies
	    Depth blocks below the surface, pushed down to keep COVER blocks of rock above it under
	    every column it spans and up to keep it off the bedrock (a deposit under a shallow sea
	    floor shrinks to fit, or there is none), and moved up or down out of the deep caves'
	    regions (Caves.regions, where no cave is carved; no well when it can't be), so it is
	    buried in rock rather than hollowed out by a cave. Its cells of rock (opaque, not
	    bedrock) become CaveOil, the cave twin of an oil source: cave air while caves are
	    hidden, so a buried deposit costs nothing. Cave entrances and ravines are carved before
	    it: where one cuts into the sphere the deposit keeps CLEAR under its cells (asked of the
	    worms, Terrain.carved, so padding agrees), so no CaveOil faces their open-sky air;
	  * the geyser (large and medium wells on land more than 2 above the sea), BuildCraft's spout
	    and surface deposit:
	      - its lake (BuildCraft's generateSurfaceDeposit): oil `lakeDepth` deep with its top one
	        below the ground (the top block over it is dug away), grown from the centre by
	        tendrils with BuildCraft's falling chance (radius - w + 4) / (radius + 4), holes
	        filled, on columns no higher than the centre and at most one lower (so uneven ground
	        gives a smaller, ragged lake, as BuildCraft's); a column whose neighbour outside the
	        lake is lower than the oil's top is left out, so the lake never has an open side (the
	        centre stays: it is the spout's). Its radius shrinks until two rings of the ground
	        around it are dry (above SEA + 1): no geyser on the shore itself;
	      - its spout: a 1 wide column of oil sources from the deposit up through the lake to
	        `spout` blocks over the ground (BuildCraft's 16 for large wells, 6 for medium ones).
	        Below the lake it is CaveOil (cave twins replace rock, cave air and lava alike, so it
	        runs on through a cave as a pillar), in the lake and above it ordinary Oil.
	    Surface caves leave the lake's square and MARGIN blocks around it alone (TerrainGenerator
	    protects it), trees stay out of it. LOD chunks up to Config.StructureMaxLevel point-sample
	    the lake (oil in the top cell of a column whose sample block lies in it) and draw the
	    spout in the cell holding its column, so geysers show from afar; the map paints them.
	  * undersea pockets: wells under the sea are small deposits (`SeaSize`) without a geyser.
	Generated oil is sources, static until something changes next to it: a broken block beside
	the spout makes it pour out (Behaviours/Fluid), as BuildCraft's does.
]]

local Config = require(script.Parent.Parent.Config)
local Blocks = require(script.Parent.Parent.Blocks)
local Biomes = require(script.Parent.Parent.Biomes)
local ChunkLayout = require(script.Parent.Parent.World.ChunkLayout)
local Hash = require(script.Parent.Parent.Util.Hash)
local Caves = require(script.Parent.Caves)

local P = ChunkLayout.PADDED
local LAYER = ChunkLayout.LAYER
local SEA = Config.SeaLevel
local MIN_Y = Config.Caves.MinY

-- Tuning --------------------------------------------------------------------------------------------
local INSET = 32 -- a candidate lies this far from its cell's sides
local MARGIN = 2 -- no structure piece within this many blocks; surface caves keep this far off a lake
local COVER = 6 -- blocks of rock kept over a deposit
-- A deposit's cells in a column stay at least CLEAR below the lowest cell a cave entrance or
-- ravine carves there or in a neighbouring column (none on or next to one).
local CLEAR = 2
local SAMPLE = 4 -- the deposit's cover is checked on a grid this coarse (blocks)
-- A deposit keeps out of the deep caves: Caves.regions (their barrier2 gate: no caves below 0,
-- hardly any up to ~0.1) at most GATE at its centre and on SPHERE's points of its surface (no cave
-- cell was found in 58 deposits at 0.05), else it moves DODGE blocks up or down at a time within
-- its range, or there is no well.
local GATE = 0.05
local DODGE = 4
local SPHERE: { { number } } = { { 0, 0, 0 } }
for _, o in { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } } do
	table.insert(SPHERE, o)
end
for _, sx in { -1, 1 } do
	for _, sy in { -1, 1 } do
		for _, sz in { -1, 1 } do
			table.insert(SPHERE, { sx * 0.577, sy * 0.577, sz * 0.577 })
		end
	end
end

local readu8 = buffer.readu8
local writeu8 = buffer.writeu8
local readu16 = buffer.readu16
local writeu16 = buffer.writeu16
local huge = math.huge

local id = Blocks.id
local AIR, OIL, CAVE_OIL, BEDROCK = Blocks.AIR, id.Oil, id.CaveOil, id.Bedrock

-- Rock a deposit replaces: opaque, not bedrock.
local rock = buffer.create(Blocks.count)
for blockId = 0, Blocks.count - 1 do
	if blockId ~= BEDROCK and readu8(Blocks.cullLut, blockId) == 1 then
		writeu8(rock, blockId, 1)
	end
end

export type Size = {
	name: string,
	share: number,
	radius: { number },
	lake: { number },
	spout: number,
}

--[[
	A well. `x`, `z`: its column (the deposit's centre and the geyser); `surface`: that column's
	height (first air); `y`, `radius`: the deposit's centre and radius; `geyser`: whether it has
	a lake and a spout (`lakeRadius`, `lakeDepth`; the oil's top cell `lakeLevel`, the spout's top
	cell `spoutTop`). The lake's columns (`lakeMask`, see OilWells.lakeOf) are worked out when
	first needed.
]]
export type Well = {
	cellX: number,
	cellZ: number,
	x: number,
	z: number,
	size: string,
	biome: number,
	undersea: boolean,
	surface: number,
	y: number,
	radius: number,
	geyser: boolean,
	lakeRadius: number,
	lakeDepth: number,
	lakeLevel: number,
	spoutTop: number,
	lakeSeed: number,
}

--[[
	What wells need of the terrain at full detail (TerrainGenerator), as Lava.Terrain, and the deep
	caves' regions (Caves.regions, nil without caves): no cave is carved where they are below 0.
]]
export type Terrain = {
	height: (x: number, z: number) -> number,
	biome: (x: number, z: number) -> number,
	free: (minX: number, minZ: number, maxX: number, maxZ: number) -> boolean,
	spawn: () -> (number, number),
	regions: ((x: number, y: number, z: number) -> number)?,
	-- The lowest block a cave entrance or ravine carves in column (x, z), nil where none does
	-- (SurfaceCaves.lowestCarved at full detail, from the worms alone); nil: no surface caves.
	carved: ((x: number, z: number) -> number?)?,
}

export type Wells = {
	-- Every well with a block within MARGIN of the rectangle (inclusive), in cell order.
	find: (minX: number, minZ: number, maxX: number, maxZ: number) -> { Well },
	-- The square a geyser's lake (and MARGIN around it) takes, nil for a well without one.
	lakeBox: (well: Well) -> (number?, number?, number?, number?),
	--[[
		The lake's columns: a u8 per column of the (2 lakeRadius + 1)^2 square around the well,
		at (dz + r) * (2r + 1) + dx + r: 1 oil, 0 none. Computed once per well.
	]]
	lakeOf: (well: Well) -> buffer,
	--[[
		Writes `wells` into the padded `level` chunk (first core column originX, originZ; `cells`
		tall). Level 0: deposits, spouts and lakes; up to Config.StructureMaxLevel: the geysers'
		lakes and spouts, point-sampled. `topCells` drop below the dug lake. Returns the lowest
		cell written with something that is neither opaque nor a cave cell (math.huge: none), one
		above the highest cell written, the lattice marked where cave twins went into rock
		(level 0), and the oil cells written (deposit twins, other oil).
	]]
	write: (
		wells: { Well },
		data: buffer,
		level: number,
		originX: number,
		originZ: number,
		cells: number,
		topCells: { number },
		carved: Caves.Carved?
	) -> (number, number, Caves.Carved?, number, number),
	-- The well of cell (gx, gz) (nil: none) without filling the cache: /locate's probe
	-- (Generation/Locate) looks at thousands of cells.
	peek: (gx: number, gz: number) -> Well?,
}

local OilWells = {}

OilWells.INSET = INSET
OilWells.MARGIN = MARGIN
OilWells.COVER = COVER

-- The configured sizes, in order (shares sum to 1).
local function sizes(): { Size }
	local list: { Size } = {}
	local total = 0
	for _, s in Config.Caves.OilWells.Sizes do
		total += s.Share
	end
	for _, s in Config.Caves.OilWells.Sizes do
		table.insert(list, {
			name = s.Name,
			share = s.Share / total,
			radius = s.Radius,
			lake = s.Lake,
			spout = s.Spout,
		})
	end
	return list
end

local function cellKey(cx: number, cz: number): number
	return (cx + 2097152) * 4194304 + (cz + 2097152)
end

function OilWells.new(seed: number, terrain: Terrain): Wells
	local cfg = Config.Caves.OilWells
	local salt = Hash.hash2(seed, Hash.string("oil.wells"), 0x0177)
	local spacing = cfg.Spacing
	local sizeList = sizes()
	local seaSize: Size = sizeList[#sizeList]
	local seaSized = false
	for _, s in sizeList do
		if s.name == cfg.SeaSize then
			seaSize, seaSized = s, true
		end
	end
	assert(seaSized, "OilWells.SeaSize is not one of its Sizes")
	local biomeChance: { number } = {}
	for i, biome in Biomes.list do
		biomeChance[i] = cfg.Biomes[biome.name] or cfg.Chance
	end
	assert(spacing > 2 * INSET + 2 * 24, "OilWells.Spacing too small for a well")

	local recent: { [number]: { well: Well? } } = {}
	local older: { [number]: { well: Well? } } = {}
	local count = 0
	local lakes: { [Well]: buffer } = setmetatable({}, { __mode = "k" }) :: any

	local function decide(gx: number, gz: number): Well?
		if not cfg.Enabled then
			return nil
		end
		local rng = Hash.rng(Hash.hash2(salt, gx, gz))
		local x = gx * spacing + INSET + rng:int(0, spacing - 2 * INSET - 1)
		local z = gz * spacing + INSET + rng:int(0, spacing - 2 * INSET - 1)
		local surface = terrain.height(x, z)
		local undersea = surface < SEA
		local roll = rng:float()
		local pick = rng:float()
		-- Undersea pockets are all of SeaSize: the sea floor holds only small pockets.
		local size = seaSize
		if not undersea then
			size = sizeList[#sizeList]
			for _, s in sizeList do
				if pick < s.share then
					size = s
					break
				end
				pick -= s.share
			end
		end
		local depth = rng:int(cfg.Depth[1], cfg.Depth[2])
		local radius = rng:int(size.radius[1], size.radius[2])
		local lakeRadius = rng:int(size.lake[1], size.lake[2])
		local lakeDepth = rng:int(cfg.LakeDepth[1], cfg.LakeDepth[2])
		local lakeSeed = rng:next()

		local biome = terrain.biome(x, z)
		if roll >= (if undersea then cfg.Sea else biomeChance[biome]) then
			return nil
		end
		if cfg.SpawnClearance > 0 then
			local sx, sz = terrain.spawn()
			if (x - sx) ^ 2 + (z - sz) ^ 2 < cfg.SpawnClearance ^ 2 then
				return nil
			end
		end
		local reach = math.max(radius, lakeRadius) + MARGIN
		if not terrain.free(x - reach, z - reach, x + reach, z + reach) then
			return nil
		end

		-- The deposit: Depth below the surface, COVER under the lowest ground above it, off the
		-- bedrock.
		local lowest = surface
		for dz = -radius - SAMPLE, radius + SAMPLE, SAMPLE do
			for dx = -radius - SAMPLE, radius + SAMPLE, SAMPLE do
				if dx * dx + dz * dz <= (radius + SAMPLE) ^ 2 then
					lowest = math.min(lowest, terrain.height(x + dx, z + dz))
				end
			end
		end
		local fit = (lowest - COVER - (MIN_Y + 1)) // 2
		if fit < radius then
			radius = fit
		end
		if radius < 2 then
			return nil
		end
		local low, high = MIN_Y + 1 + radius, lowest - COVER - radius
		local y = math.clamp(surface - depth, low, high)
		-- Out of the deep caves' regions (seed only, so every chunk agrees): the nearest height
		-- still Depth below the surface, in steps of DODGE, where the sphere's centre and 14
		-- points on it are clear.
		low = math.max(low, math.min(surface - cfg.Depth[2], y))
		high = math.min(high, math.max(surface - cfg.Depth[1], y))
		local regions = terrain.regions
		if regions then
			local function clear(cy: number): boolean
				for _, o in SPHERE do
					if regions(x + o[1] * radius, cy + o[2] * radius, z + o[3] * radius) > GATE then
						return false
					end
				end
				return true
			end
			local found = clear(y)
			local k = 1
			while not found and (y - k * DODGE >= low or y + k * DODGE <= high) do
				for _, cy in { y - k * DODGE, y + k * DODGE } do
					if cy >= low and cy <= high and clear(cy) then
						y, found = cy, true
						break
					end
				end
				k += 1
			end
			if not found then
				return nil
			end
		end

		-- The geyser (large and medium wells on land): its lake shrinks until the ground on two
		-- rings around it is dry (above SEA + 1), none on the shore itself. Uneven ground only
		-- shapes the lake (lakeOf).
		local geyser = size.spout > 0 and not undersea and surface > SEA + 2
		if geyser then
			local function wet(lr: number): boolean
				for ring = 1, 2 do
					local r = if ring == 1 then lr + 1 else math.max(lr // 2, 1)
					local k = if ring == 1 then 16 else 8
					for i = 0, k - 1 do
						local a = 2 * math.pi * i / k
						if
							terrain.height(x + math.round(r * math.cos(a)), z + math.round(r * math.sin(a)))
							<= SEA + 1
						then
							return true
						end
					end
				end
				return false
			end
			while lakeRadius > 0 and wet(lakeRadius) do
				lakeRadius -= 1
			end
			geyser = lakeRadius > 0
		end
		local lakeLevel = surface - 2
		return table.freeze({
			cellX = gx,
			cellZ = gz,
			x = x,
			z = z,
			size = size.name,
			biome = biome,
			undersea = undersea,
			surface = surface,
			y = y,
			radius = radius,
			geyser = geyser,
			lakeRadius = if geyser then lakeRadius else 0,
			lakeDepth = if geyser then lakeDepth else 0,
			lakeLevel = if geyser then lakeLevel else 0,
			spoutTop = if geyser then surface - 1 + size.spout else 0,
			lakeSeed = lakeSeed,
		})
	end

	local function cell(gx: number, gz: number): Well?
		local key = cellKey(gx, gz)
		local entry = recent[key]
		if entry == nil then
			entry = older[key] or { well = decide(gx, gz) }
			if count >= 1024 then
				older, recent, count = recent, {}, 0
			end
			recent[key] = entry
			count += 1
		end
		return entry.well
	end

	local function find(minX: number, minZ: number, maxX: number, maxZ: number): { Well }
		local list: { Well } = {}
		for gz = (minZ - MARGIN) // spacing, (maxZ + MARGIN) // spacing do
			for gx = (minX - MARGIN) // spacing, (maxX + MARGIN) // spacing do
				local well = cell(gx, gz)
				if well then
					local r = math.max(well.radius, well.lakeRadius) + MARGIN
					if well.x - r <= maxX and well.x + r >= minX and well.z - r <= maxZ and well.z + r >= minZ then
						table.insert(list, well)
					end
				end
			end
		end
		return list
	end

	local function lakeBox(well: Well): (number?, number?, number?, number?)
		if not well.geyser then
			return nil
		end
		local r = well.lakeRadius + MARGIN
		return well.x - r, well.z - r, well.x + r, well.z + r
	end

	-- BuildCraft's generateSurfaceDeposit on the full detail heights (see the header).
	local function lakeOf(well: Well): buffer
		local cached = lakes[well]
		if cached then
			return cached
		end
		local r = well.lakeRadius
		local w = 2 * r + 1
		local mask = buffer.create(w * w)
		if not well.geyser then
			lakes[well] = mask
			return mask
		end
		local level = well.lakeLevel
		local heights: { [number]: number } = {}
		local function height(dx: number, dz: number): number
			local k = (dz + r + 1) * (w + 2) + dx + r + 1
			local h = heights[k]
			if h == nil then
				h = terrain.height(well.x + dx, well.z + dz)
				heights[k] = h
			end
			return h
		end
		local function isOil(dx: number, dz: number): boolean
			if dx < -r or dx > r or dz < -r or dz > r then
				return false
			end
			return readu8(mask, (dz + r) * w + dx + r) == 1
		end
		-- BuildCraft's setOilColumnForLake: oil where the column's top is the oil's top cell or
		-- the cell over it.
		local function column(dx: number, dz: number)
			if dx < -r or dx > r or dz < -r or dz > r then
				return
			end
			local h = height(dx, dz)
			if h == level + 1 or h == level + 2 then
				writeu8(mask, (dz + r) * w + dx + r, 1)
			end
		end
		local rng = Hash.rng(well.lakeSeed)
		local function try(proba: number, dx: number, dz: number)
			if rng:float() <= proba then
				if isOil(dx + 1, dz) or isOil(dx - 1, dz) or isOil(dx, dz + 1) or isOil(dx, dz - 1) then
					column(dx, dz)
				end
			end
		end
		column(0, 0)
		for d = 1, r do
			local proba = (r - d + 4) / (r + 4)
			try(proba, 0, d)
			try(proba, 0, -d)
			try(proba, d, 0)
			try(proba, -d, 0)
			for i = 1, d do
				try(proba, i, d)
				try(proba, i, -d)
				try(proba, d, i)
				try(proba, -d, i)
				try(proba, -i, d)
				try(proba, -i, -d)
				try(proba, d, -i)
				try(proba, -d, -i)
			end
		end
		-- Fill in holes.
		for dx = -r, r do
			for dz = -r, r do
				if
					not isOil(dx, dz)
					and isOil(dx + 1, dz)
					and isOil(dx - 1, dz)
					and isOil(dx, dz + 1)
					and isOil(dx, dz - 1)
				then
					column(dx, dz)
				end
			end
		end
		-- No open sides: a neighbour outside the lake must be solid at the oil's top. (The centre
		-- stays: it is the spout's column, open over the ground anyway.)
		local drop: { number } = {}
		for dz = -r, r do
			for dx = -r, r do
				if isOil(dx, dz) and (dx ~= 0 or dz ~= 0) then
					for _, o in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
						local nx, nz = dx + o[1], dz + o[2]
						if not isOil(nx, nz) and height(nx, nz) <= level then
							table.insert(drop, (dz + r) * w + dx + r)
							break
						end
					end
				end
			end
		end
		for _, i in drop do
			writeu8(mask, i, 0)
		end
		lakes[well] = mask
		return mask
	end

	--[[
		The lowest cell a cave entrance or ravine carves in column (x, z) or one next to it
		(math.huge: none) of `well`'s deposit, from the worms alone, so a chunk's padding agrees
		with its neighbour's core. None carves in a geyser's lake square (TerrainGenerator protects
		it). Remembered per column while a chunk is written.
	]]
	local carvedAt = terrain.carved
	local lowestAt: { [number]: number } = {}
	local function below(well: Well, x: number, z: number): number
		if carvedAt == nil then
			return huge
		end
		local lake = if well.geyser then well.lakeRadius + MARGIN else -1
		local lowest = huge
		for i = 0, 4 do
			local cx = if i == 1 then x + 1 elseif i == 2 then x - 1 else x
			local cz = if i == 3 then z + 1 elseif i == 4 then z - 1 else z
			if math.abs(cx - well.x) <= lake and math.abs(cz - well.z) <= lake then
				continue
			end
			local k = cellKey(cx, cz)
			local c = lowestAt[k]
			if c == nil then
				c = carvedAt(cx, cz) or huge
				lowestAt[k] = c
			end
			lowest = math.min(lowest, c)
		end
		return lowest
	end

	local function write(
		wells: { Well },
		data: buffer,
		level: number,
		originX: number,
		originZ: number,
		cells: number,
		topCells: { number },
		carved: Caves.Carved?
	): (number, number, Caves.Carved?, number, number)
		local lowest, top = huge, 0
		local twins, oil = 0, 0
		table.clear(lowestAt)
		local step, stepY = ChunkLayout.steps(level)
		local half = step // 2
		local minX, minZ = originX - step, originZ - step
		local maxX, maxZ = minX + P * step - 1, minZ + P * step - 1
		for _, well in wells do
			local wx, wz = well.x, well.z
			if level == 0 then
				-- The deposit, kept CLEAR under the cells a cave entrance or ravine carves (`below`).
				local r = well.radius
				local r2 = r * r
				local xa, xb = math.max(wx - r, minX), math.min(wx + r, maxX)
				local za, zb = math.max(wz - r, minZ), math.min(wz + r, maxZ)
				local ya, yb = math.max(well.y - r, 1), math.min(well.y + r, cells - 1)
				if xa <= xb and za <= zb and ya <= yb then
					for z = za, zb do
						local dz = z - wz
						for x = xa, xb do
							local dx = x - wx
							local reach = r2 - dx * dx - dz * dz
							if reach < 0 then
								continue
							end
							-- The column's cells within the sphere, up to CLEAR under the lowest
							-- cell a surface cave carves in it or next to it.
							local dy = math.floor(math.sqrt(reach))
							local y1 = math.min(well.y + dy, yb, below(well, x, z) - CLEAR)
							local col = ((z - minZ) * P + x - minX) * 2
							for y = math.max(well.y - dy, ya), y1 do
								local o = y * LAYER * 2 + col
								if readu8(rock, readu16(data, o)) == 1 then
									writeu16(data, o, CAVE_OIL)
									twins += 1
								end
							end
						end
					end
					carved = Caves.mark(carved, originX, originZ, xa, ya, za, xb, yb, zb)
				end
				if not well.geyser then
					continue
				end
				local mask = lakeOf(well)
				local lr = well.lakeRadius
				local lw = 2 * lr + 1
				local surfaceY = well.lakeLevel
				local bottom = surfaceY - well.lakeDepth + 1
				-- The spout below the lake: twins through rock, caves and lava alike.
				if wx >= minX and wx <= maxX and wz >= minZ and wz <= maxZ then
					local col = (wz - minZ) * P + wx - minX
					local from, to = math.max(well.y + r + 1, 1), math.min(bottom - 1, cells - 1)
					for y = from, to do
						local o = (y * LAYER + col) * 2
						local block = readu16(data, o)
						if block ~= BEDROCK and block ~= CAVE_OIL then
							writeu16(data, o, CAVE_OIL)
							twins += 1
						end
					end
					if from <= to then
						carved = Caves.mark(carved, originX, originZ, wx, from, wz, wx, to, wz)
					end
				end
				-- The lake.
				for dz = -lr, lr do
					local z = wz + dz
					if z < minZ or z > maxZ then
						continue
					end
					for dx = -lr, lr do
						local x = wx + dx
						if x < minX or x > maxX or readu8(mask, (dz + lr) * lw + dx + lr) == 0 then
							continue
						end
						local col = (z - minZ) * P + x - minX
						for y = math.max(bottom, 1), math.min(surfaceY, cells - 1) do
							local o = (y * LAYER + col) * 2
							if readu16(data, o) ~= BEDROCK then
								writeu16(data, o, OIL)
								oil += 1
							end
						end
						if surfaceY + 1 < cells and readu16(data, ((surfaceY + 1) * LAYER + col) * 2) ~= AIR then
							writeu16(data, ((surfaceY + 1) * LAYER + col) * 2, AIR)
						end
						if bottom <= topCells[col + 1] then
							topCells[col + 1] = bottom - 1
						end
						lowest = math.min(lowest, bottom)
					end
				end
				-- The spout over the lake.
				if wx >= minX and wx <= maxX and wz >= minZ and wz <= maxZ then
					local col = (wz - minZ) * P + wx - minX
					for y = surfaceY + 1, math.min(well.spoutTop, cells - 1) do
						writeu16(data, (y * LAYER + col) * 2, OIL)
						oil += 1
					end
					top = math.max(top, math.min(well.spoutTop, cells - 1) + 1)
					lowest = math.min(lowest, surfaceY + 1)
				end
			elseif well.geyser then
				-- Point-sampled lake: oil in the top cell of columns whose sample block is in it.
				local mask = lakeOf(well)
				local lr = well.lakeRadius
				local lw = 2 * lr + 1
				for pz = 0, P - 1 do
					local dz = minZ + pz * step + half - wz
					if dz < -lr or dz > lr then
						continue
					end
					for px = 0, P - 1 do
						local dx = minX + px * step + half - wx
						if dx < -lr or dx > lr or readu8(mask, (dz + lr) * lw + dx + lr) == 0 then
							continue
						end
						local col = pz * P + px
						local cell = topCells[col + 1]
						if cell >= 1 and cell < cells then
							writeu16(data, (cell * LAYER + col) * 2, OIL)
							oil += 1
							topCells[col + 1] = cell - 1
							lowest = math.min(lowest, cell)
						end
					end
				end
				-- The spout, in the cell holding its column.
				local px, pz = (wx - minX) // step, (wz - minZ) // step
				if px >= 0 and px < P and pz >= 0 and pz < P then
					local col = pz * P + px
					local last = math.min(well.spoutTop // stepY, cells - 1)
					for cy = math.max(topCells[col + 1] + 1, 1), last do
						writeu16(data, (cy * LAYER + col) * 2, OIL)
						oil += 1
						lowest = math.min(lowest, cy)
					end
					top = math.max(top, last + 1)
				end
			end
		end
		return lowest, top, carved, twins, oil
	end

	local function peek(gx: number, gz: number): Well?
		local key = cellKey(gx, gz)
		local entry = recent[key] or older[key]
		if entry then
			return entry.well
		end
		return decide(gx, gz)
	end

	return {
		find = find,
		lakeBox = lakeBox,
		lakeOf = lakeOf,
		write = write,
		peek = peek,
	}
end

return OilWells
