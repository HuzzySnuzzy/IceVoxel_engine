--!strict
--!native
--[[
	Layered generator: a whole TerrainGenerator.Generator built from a stack of block layers per
	column (Minecraft's FlatLevelSource: the superflat presets, the void) and blocks laid over the
	stacks (the debug worlds, Generation/DebugWorlds), for Generation/WorldTypes. Everything the
	server, the client's streamer, the chunk workers, the map and the far terrain ask of a
	generator works on it, at every LOD level:

	  Stacks     `LayeredGenerator.stack(layers)` turns { { block, count } } (bottom up, from
	             y = 0) into a Stack: its blocks by height, its `height` (the first air above it;
	             air layers on top don't count), its `ground` (the same without the run of water
	             layers on top: that water is the world's sea, as the Default's) and `surface` (the
	             ground's top block; Blocks.AIR when there is no ground). A world has one stack
	             everywhere (`Spec.stack`, `Spec.biome`) or one per column (`Spec.columnAt`, pure:
	             every machine asks it the same).
	  Chunks     each padded column is the stack at its sample point (the cell centre), cell by
	             cell as TerrainGenerator fills its own: a cell holds the block at its sample height,
	             the ground's top cell shows `surface` (grass stays green from afar), and the top
	             cells of a stack too thin for a far level's cells still show as cell 0 (a 4 block
	             classic flat world does not vanish at 16 block cells: it is drawn a cell tall).
	             LOD border columns lower their ground by one cell (TerrainGenerator's skirt; water
	             fills the cell when the ground lies under water), and the seam limits follow the
	             same rounding, so LOD seams show no cracks.
	  Blocks     `Spec.blocks` (x, y, z, block, ... world positions) are written after the stacks
	             into the cell that holds each (every level: a lone debug block does not vanish
	             between far sample points; a later one in the same cell wins). A column's highest
	             placed block above its ground is what `column` reports (height and surface): the
	             map shows it, spawning stands on it, sky checks see it.
	  Structures `Spec.placer` (Generation/StructureGen, with a fixed layout) writes library
	             templates over the stacks up to Config.StructureMaxLevel, as the Default writes its
	             jigsaw structures (point sampled on far levels); `structures` and
	             `structureContainer` answer from it.
	  Decoration `Spec.decoration`: the biome's trees (Generation/Structures, up to
	             StructureMaxLevel, keeping clear of the placer's pieces) and ground plants
	             (Generation/Foliage, full detail) on the ground, never under water.
	  Nothing else: no caves (`carved` nil), no surface caves (`surfaceCaves` carves nothing), no
	  oil wells, lava or water lakes or puddles (empty lists), so the culling sees an exact sky line
	  (`surface`: the stacks' ground) and every query a server or client makes is cheap.

	The rest of the contract: `seaLevel` is the top of the stack's water when it ends in water
	(else 0: no sea; Players/SafeSpot, the map and structures read it), `findSpawn` is
	`Spec.spawn`'s column (default 0, 0) standing on what `column` reports there, `labels` the
	placer's name tags (Spec.labels). /locate (Generation/Locate): no structure kinds; `biomes` is
	the one biome of a world with one stack (nil with `columnAt`: any), and `poiBlocks` the placed
	blocks and the placer's pieces' blocks of a set (chests, structure blocks...).

	Costs: each stack's cells are worked out once per level (`planOf`). One stack everywhere is
	written a whole layer at a time, a layer like the one below being a buffer.copy, then the
	border columns' few differing cells (a 237 block tunnelers' dream: 0.05 ms a full detail chunk
	in Lune, the Default's ~1.3); a stack per column is a write per cell up to its top. Then the
	placed blocks (scanned in a list, rejected by their bounding box) and the structures and trees
	that reach the chunk (decoration: 0.2-0.4 ms).
]]

local Config = require(script.Parent.Parent.Config)
local Blocks = require(script.Parent.Parent.Blocks)
local Biomes = require(script.Parent.Parent.Biomes)
local ChunkLayout = require(script.Parent.Parent.World.ChunkLayout)
local Coords = require(script.Parent.Parent.World.Coords)
local Horizon = require(script.Parent.Parent.World.Horizon)
local Foliage = require(script.Parent.Foliage)
local Structures = require(script.Parent.Structures)
local Writer = require(script.Parent.Structures.Writer)
local StructureGen = require(script.Parent.StructureGen)
local SurfaceCaves = require(script.Parent.SurfaceCaves)
local TerrainGenerator = require(script.Parent.TerrainGenerator)

local SIZE = ChunkLayout.SIZE
local P = ChunkLayout.PADDED
local LAYER = ChunkLayout.LAYER
local STRIDE = LAYER * 2
local WORLD_HEIGHT = Config.WorldHeight
local AIR = Blocks.AIR
-- Blocks above the stacks kept in a chunk's buffer for trees (TerrainGenerator's STRUCTURE_ROOM).
local TREE_ROOM = 32

local readu16 = buffer.readu16
local writeu16 = buffer.writeu16
local readu8 = buffer.readu8
local huge = math.huge
-- Cells that never lower solidBelow (opaque blocks, cave air, cave twins).
local cullHidden = Blocks.cullLutHiddenCaves

export type Layer = { block: number, count: number }

export type Stack = {
	layers: { Layer },
	-- u16 block id per height, 0 .. height - 1.
	blocks: buffer,
	-- First air above the stack (air layers on top left out).
	height: number,
	-- First air above the ground: `height` without the water layers on top.
	ground: number,
	-- The ground's top block (Blocks.AIR: no ground).
	surface: number,
}

export type Spec = {
	seed: number,
	-- One stack and biome index everywhere, or a stack and biome per column (pure).
	stack: Stack?,
	biome: number?,
	columnAt: ((x: number, z: number) -> (Stack, number))?,
	-- The biomes' trees and ground plants on the ground.
	decoration: boolean?,
	-- Blocks laid over the stacks: x, y, z, block, ... (world positions, written in this order).
	blocks: { number }?,
	-- Library structures (a StructureGen placer, usually with a fixed layout).
	placer: StructureGen.Placer?,
	-- The spawn column { x, z } (default 0, 0).
	spawn: { number }?,
	-- Generated structure blocks with settings (TerrainGenerator.Label).
	labels: { TerrainGenerator.Label }?,
}

local LayeredGenerator = {}

LayeredGenerator.TREE_ROOM = TREE_ROOM

-- A surface caves object that carves nothing (the Generator's `surfaceCaves`).
local NO_SURFACE_CAVES: SurfaceCaves.SurfaceCaves = {
	carve = function(): number
		return huge
	end,
	carvesTop = function(): boolean
		return false
	end,
	lowestCarved = function(): number?
		return nil
	end,
	mayCarve = function(): boolean
		return false
	end,
	worms = function(): { any }
		return {}
	end,
	built = function(): number
		return 0
	end,
	start = function(): (number?, number)
		return nil, 0
	end,
	wormOf = function(): any
		return nil
	end,
} :: any
LayeredGenerator.NO_SURFACE_CAVES = NO_SURFACE_CAVES

local function isWater(block: number): boolean
	local fluid = Blocks.get(block).fluid
	return fluid ~= nil and fluid.group == "Water"
end

--[[
	A stack from `layers` (bottom up; counts are whole numbers >= 1). Errors when it is taller
	than the world (callers that read layers from players check that first: Generation/Superflat).
]]
function LayeredGenerator.stack(layers: { Layer }): Stack
	local total = 0
	for _, layer in layers do
		assert(layer.count >= 1 and layer.count % 1 == 0, "LayeredGenerator.stack: bad layer count")
		assert(Blocks.isValid(layer.block), "LayeredGenerator.stack: unknown block")
		total += layer.count
	end
	assert(total <= WORLD_HEIGHT, "LayeredGenerator.stack: taller than the world")
	local blocks = buffer.create(math.max(total, 1) * 2)
	local y = 0
	for _, layer in layers do
		for _ = 1, layer.count do
			writeu16(blocks, y * 2, layer.block)
			y += 1
		end
	end
	-- Air on top is no part of the stack, the water on top is the sea.
	local height = total
	while height > 0 and readu16(blocks, (height - 1) * 2) == AIR do
		height -= 1
	end
	local ground = height
	while ground > 0 and isWater(readu16(blocks, (ground - 1) * 2)) do
		ground -= 1
	end
	return {
		layers = table.clone(layers),
		blocks = blocks,
		height = height,
		ground = ground,
		surface = if ground > 0 then readu16(blocks, (ground - 1) * 2) else AIR,
	}
end

-- The empty stack (nothing but air: the void).
LayeredGenerator.EMPTY = LayeredGenerator.stack({})

--[[
	The top cell (index) of `blocks` blocks of a column at a level with cells `stepY` tall (centre
	`halfY`): the highest cell whose sample height lies inside them, at least cell 0 when there is
	anything (-1 for nothing).
]]
local function topCellOf(blocks: number, stepY: number, halfY: number): number
	if blocks <= 0 then
		return -1
	end
	local cell = (blocks - halfY + stepY - 1) // stepY - 1
	return if cell < 0 then 0 else cell
end
LayeredGenerator.topCellOf = topCellOf

function LayeredGenerator.new(spec: Spec): TerrainGenerator.Generator
	local seed = spec.seed
	local constantStack = spec.stack or LayeredGenerator.EMPTY
	local constantBiome = spec.biome or 1
	local columnAt = spec.columnAt
	local decoration = spec.decoration == true
	local placer = spec.placer
	assert(Biomes.list[constantBiome], "LayeredGenerator: unknown biome")

	local function stackAt(x: number, z: number): (Stack, number)
		if columnAt then
			return columnAt(x, z)
		end
		return constantStack, constantBiome
	end

	-- The sea: the water on top of the stack (one stack everywhere), or none.
	local seaLevel = if columnAt == nil and constantStack.height > constantStack.ground then constantStack.height else 0

	-- Placed blocks: their bounding box (rejects most chunks at once), and each column's highest.
	local placed = spec.blocks or {}
	assert(#placed % 4 == 0, "LayeredGenerator: blocks come as x, y, z, block")
	local px0, py0, pz0, px1, py1, pz1 = huge, huge, huge, -huge, -huge, -huge
	local placedTop: { [number]: { number } } = {}
	for i = 1, #placed, 4 do
		local x, y, z, block = placed[i], placed[i + 1], placed[i + 2], placed[i + 3]
		assert(y >= 0 and y < WORLD_HEIGHT and Blocks.isValid(block), "LayeredGenerator: bad placed block")
		px0, py0, pz0 = math.min(px0, x), math.min(py0, y), math.min(pz0, z)
		px1, py1, pz1 = math.max(px1, x), math.max(py1, y), math.max(pz1, z)
		if block ~= AIR then
			local key = Coords.chunkKey(x, z)
			local top = placedTop[key]
			if top == nil or y + 1 > top[1] then
				placedTop[key] = { y + 1, block }
			end
		end
	end

	-- (height (first air), biome, vegetation chance, surface block): see the header.
	local function column(x: number, z: number): (number, number, number, number)
		local stack, biome = stackAt(x, z)
		local top = placedTop[Coords.chunkKey(x, z)]
		if top and top[1] > stack.height then
			return top[1], biome, 0, top[2]
		end
		local vegetation = if decoration and stack.height == stack.ground then Biomes.list[biome].vegetation else 0
		return stack.ground, biome, vegetation, stack.surface
	end

	local growFoliage = if decoration then Foliage.new(seed) else nil

	-- Per padded column scratch, reused between chunks (each worker actor has its own copy).
	local stacks: { Stack } = table.create(P * P, constantStack)
	local biomes: { number } = table.create(P * P, constantBiome)
	local topCells: { number } = table.create(P * P, 0)

	--[[
		A stack's column at `level` (`border`: a LOD border column, its ground a cell lower): the
		block of each cell from 0 up to its top cell (the ground's top cell shows the surface, the
		others the block at their sample height: within the ground below it, within the water above
		it), its ground's top cell, its top cell and its lowest cell that is neither opaque nor cave
		air (at most the top cell + 1). Worked out once per stack and level.
	]]
	type Plan = { blocks: { number }, groundCell: number, topCell: number, open: number }
	local plans: { [Stack]: { [number]: Plan } } = {}
	local function planOf(stack: Stack, level: number, border: boolean): Plan
		local byLevel = plans[stack]
		if byLevel == nil then
			byLevel = {}
			plans[stack] = byLevel
		end
		local key = level * 2 + (if border then 1 else 0)
		local cached = byLevel[key]
		if cached then
			return cached
		end
		local _, stepY = ChunkLayout.steps(level)
		local halfY = stepY // 2
		local height, ground, blocks = stack.height, stack.ground, stack.blocks
		local topCell = topCellOf(height, stepY, halfY)
		local groundCell = if ground == height then topCell else topCellOf(ground, stepY, halfY)
		if border and groundCell >= 0 then
			groundCell -= 1
			if ground == height then
				topCell = groundCell
			end
		end
		local list: { number } = table.create(topCell + 1, AIR)
		local open = topCell + 1
		for cy = 0, topCell do
			local block
			if cy == groundCell then
				block = stack.surface
			else
				local y = cy * stepY + halfY
				if cy < groundCell then
					y = math.min(y, ground - 1)
				else
					y = math.min(math.max(y, ground), height - 1)
				end
				block = readu16(blocks, y * 2)
			end
			list[cy + 1] = block
			if cy < open and readu8(cullHidden, block) == 0 then
				open = cy
			end
		end
		local plan: Plan = { blocks = list, groundCell = groundCell, topCell = topCell, open = open }
		byLevel[key] = plan
		return plan
	end

	local function generate(
		level: number,
		nx: number,
		nz: number,
		yield: (() -> ())?,
		extras: boolean?
	): TerrainGenerator.ChunkResult
		local step, stepY = ChunkLayout.steps(level)
		local half = step // 2
		local originX, originZ = nx * SIZE * step, nz * SIZE * step
		local span = SIZE * step
		local minX, minZ = originX - step, originZ - step
		local maxX, maxZ = originX + span + step - 1, originZ + span + step - 1

		-- 1. The stack and biome of every padded column, at its sample point.
		local highest, highestGround = 0, 0
		for pz = 0, P - 1 do
			local wz = minZ + pz * step + half
			for px = 0, P - 1 do
				local stack, biome = stackAt(minX + px * step + half, wz)
				local i = pz * P + px + 1
				stacks[i], biomes[i] = stack, biome
				if stack.height > highest then
					highest = stack.height
				end
				if stack.ground > highestGround then
					highestGround = stack.ground
				end
			end
		end

		-- Room: the stacks, the trees above them, the placed blocks and the structures here.
		local needed = (highest + stepY - 1) // stepY
		local structural = level <= Config.StructureMaxLevel
		if decoration and structural then
			needed = math.max(needed, (highestGround + TREE_ROOM + stepY - 1) // stepY)
		end
		local anyPlaced = #placed > 0 and px0 <= maxX and px1 >= minX and pz0 <= maxZ and pz1 >= minZ
		if anyPlaced then
			needed = math.max(needed, py1 // stepY + 2)
		end
		local starts: { StructureGen.Start }? = nil
		if placer and structural then
			local reach = if decoration then 2 * Structures.RADIUS else 0
			local found = placer.starts(minX - reach, minZ - reach, maxX + reach, maxZ + reach)
			if #found > 0 then
				starts = found
				-- (StructureGen lifts terrain matching pieces to the Default's sea level.)
				local top = placer.top(found, minX, minZ, maxX, maxZ, math.max(highestGround, Config.SeaLevel))
				needed = math.max(needed, top // stepY + 2)
			end
		end
		local cells = ChunkLayout.croppedHeight(math.max(needed, 1), stepY)
		local data = ChunkLayout.create(cells)

		-- 2. Fill the stacks (see the header: the ground's top cell shows the surface, LOD border
		-- columns lower the ground a cell), from each stack's column plan.
		local solidBelow, emptyAbove = cells, 0
		if columnAt == nil then
			-- One stack everywhere: every core column is alike, so it is written a whole layer
			-- at a time (a layer like the one below is a copy), then the border columns' cells that
			-- differ (LOD skirts).
			local inner = planOf(constantStack, level, false)
			local outer = if level > 0 then planOf(constantStack, level, true) else inner
			local top = math.min(inner.topCell, cells - 1)
			local below = AIR
			for cy = 0, top do
				local block = inner.blocks[cy + 1]
				if block ~= AIR then
					local offset = cy * STRIDE
					if block == below then
						buffer.copy(data, offset, data, offset - STRIDE, STRIDE)
					else
						for j = 0, LAYER - 1 do
							writeu16(data, offset + j * 2, block)
						end
					end
				end
				below = block
			end
			for i = 1, P * P do
				topCells[i] = inner.groundCell
			end
			if outer ~= inner then
				local last = math.min(math.max(inner.topCell, outer.topCell), cells - 1)
				for pz = 0, P - 1 do
					for px = 0, P - 1 do
						if px == 0 or pz == 0 or px == P - 1 or pz == P - 1 then
							topCells[pz * P + px + 1] = outer.groundCell
							local base = (pz * P + px) * 2
							for cy = 0, last do
								local block = outer.blocks[cy + 1] or AIR
								if block ~= (inner.blocks[cy + 1] or AIR) then
									writeu16(data, base + cy * STRIDE, block)
								end
							end
						end
					end
				end
			end
			solidBelow = math.min(inner.open, outer.open)
			emptyAbove = math.max(inner.topCell, outer.topCell) + 1
		else
			for pz = 0, P - 1 do
				for px = 0, P - 1 do
					local i = pz * P + px + 1
					local plan =
						planOf(stacks[i], level, level > 0 and (px == 0 or pz == 0 or px == P - 1 or pz == P - 1))
					topCells[i] = plan.groundCell
					local base = (pz * P + px) * 2
					local blocks = plan.blocks
					for cy = 0, math.min(plan.topCell, cells - 1) do
						local block = blocks[cy + 1]
						if block ~= AIR then
							writeu16(data, base + cy * STRIDE, block)
						end
					end
					if plan.open < solidBelow then
						solidBelow = plan.open
					end
					if plan.topCell + 1 > emptyAbove then
						emptyAbove = plan.topCell + 1
					end
				end
			end
		end
		solidBelow = math.clamp(solidBelow, 0, cells)
		if yield then
			yield()
		end

		-- 3. Placed blocks, into the cell holding each.
		local lowestWritten, highestWritten = huge, -1
		if anyPlaced then
			for i = 1, #placed, 4 do
				local x, y, z = placed[i], placed[i + 1], placed[i + 2]
				if x < minX or x > maxX or z < minZ or z > maxZ then
					continue
				end
				local block = placed[i + 3]
				local cy = y // stepY
				if cy >= cells then
					continue
				end
				writeu16(data, (((cy * P) + (z - minZ) // step) * P + (x - minX) // step) * 2, block)
				if block ~= AIR then
					emptyAbove = math.max(emptyAbove, cy + 1)
					highestWritten = math.max(highestWritten, cy)
					lowestWritten = math.min(lowestWritten, cy)
				end
				if cy < solidBelow and readu8(cullHidden, block) == 0 then
					solidBelow = cy
				end
			end
		end

		-- 4. Trees (point sampled on far levels, keeping clear of the structures' pieces), then
		-- the structures over them, as TerrainGenerator does.
		if structural and decoration then
			local w = Writer.new(data, originX, originZ, step, stepY, cells)
			local accept: ((x: number, z: number, biome: number) -> boolean)? = nil
			if placer and starts then
				local p, list = placer, starts
				accept = function(x: number, z: number): boolean
					return p.treeAllowed(list, x, z)
				end
			end
			Structures.populate(seed, column, w, minX, minZ, maxX, maxZ, accept)
			if w.top() > emptyAbove then
				emptyAbove = w.top()
			end
		end
		if placer and starts then
			local top, lowest = placer.write(starts, {
				data = data,
				cells = cells,
				level = level,
				originX = originX,
				originZ = originZ,
				biomes = biomes,
				topCells = topCells,
			})
			if top > emptyAbove then
				emptyAbove = top
			end
			if lowest < solidBelow then
				solidBelow = lowest
			end
			if top > 0 then
				highestWritten = math.max(highestWritten, top - 1)
				lowestWritten = math.min(lowestWritten, lowest)
			end
		end

		-- 5. Ground plants (full detail only).
		if level == 0 and growFoliage then
			local top = growFoliage(data, cells, originX, originZ, biomes, topCells)
			if top > emptyAbove then
				emptyAbove = top
			end
		end

		-- 6. For the client's culling: the Horizon summary and the ground of every core column.
		local summary, surface = nil, nil
		if extras then
			summary = Horizon.summarise(data, cells, emptyAbove, topCells, stepY)
			if level == 0 then
				local heightsOut = buffer.create(SIZE * SIZE * 2)
				for z = 0, SIZE - 1 do
					for x = 0, SIZE - 1 do
						writeu16(heightsOut, (z * SIZE + x) * 2, math.max(topCells[(z + 1) * P + x + 2] + 1, 0))
					end
				end
				surface = heightsOut
			end
		end

		local structureSpan: { number }? = nil
		if extras and highestWritten >= 0 then
			structureSpan = { math.max(lowestWritten, 0), highestWritten }
		end
		return {
			data = data,
			level = level,
			nx = nx,
			nz = nz,
			height = cells,
			solidBelow = solidBelow,
			emptyAbove = math.min(emptyAbove, cells),
			carved = nil,
			summary = summary,
			surface = surface,
			structureSpan = structureSpan,
		}
	end

	--[[
		Seam limits (TerrainGenerator's contract): for each side whose node is coarser, how high
		that node's ground goes at each padding column, rounded as `generate` fills it there.
	]]
	local function seamLimits(level: number, nx: number, nz: number, coarser: { number }): buffer?
		local out: buffer? = nil
		local step, stepY = ChunkLayout.steps(level)
		local half = step // 2
		local originX, originZ = nx * SIZE * step, nz * SIZE * step
		for side = 1, 4 do
			local coarse = coarser[side]
			if coarse and coarse > level then
				local limits = out or buffer.create(4 * SIZE * 2)
				if out == nil then
					buffer.fill(limits, 0, 0xFF)
					out = limits
				end
				local cs, csY = ChunkLayout.steps(coarse)
				local halfC, halfCY = cs // 2, csY // 2
				for i = 0, SIZE - 1 do
					local along = i * step + half
					local x, z
					if side == 1 then
						x, z = originX - step + half, originZ + along
					elseif side == 2 then
						x, z = originX + SIZE * step + half, originZ + along
					elseif side == 3 then
						x, z = originX + along, originZ - step + half
					else
						x, z = originX + along, originZ + SIZE * step + half
					end
					local stack = stackAt((x // cs) * cs + halfC, (z // cs) * cs + halfC)
					-- Blocks below this are drawn by the coarse node.
					local solidTop = (topCellOf(stack.ground, csY, halfCY) + 1) * csY
					writeu16(limits, ((side - 1) * SIZE + i) * 2, math.max(solidTop // stepY, 1))
				end
			end
		end
		return out
	end

	local function farSeamLimits(level: number, nx: number, nz: number): buffer?
		local maxLevel = Config.Lod.Levels - 1
		if level >= maxLevel then
			return nil
		end
		local up = level + 1
		local limits = seamLimits(level, nx, nz, { up, up, up, up }) :: buffer
		if level + 2 <= maxLevel then
			local up2 = level + 2
			local other = seamLimits(level, nx, nz, { up2, up2, up2, up2 }) :: buffer
			for i = 0, buffer.len(limits) - 2, 2 do
				local b = readu16(other, i)
				if b < readu16(limits, i) then
					writeu16(limits, i, b)
				end
			end
		end
		return limits
	end

	local spawn = spec.spawn or { 0, 0 }
	local function findSpawn(): (number, number, number)
		local x, z = spawn[1], spawn[2]
		local h = column(x, z)
		return x, h, z
	end

	local function structureContainer(x: number, y: number, z: number): { StructureGen.ContainerItem }?
		return if placer then placer.container(x, y, z) else nil
	end

	local function structuresIn(minX: number, minZ: number, maxX: number, maxZ: number): { StructureGen.Start }
		return if placer then placer.starts(minX, minZ, maxX, maxZ) else {}
	end

	local labels = spec.labels or {}
	local function none(): { any }
		return {}
	end

	-- Placed blocks and the placer's pieces' blocks marked in `lut` in the rectangle.
	local function poiBlocks(minX: number, minZ: number, maxX: number, maxZ: number, lut: buffer): { number }
		local out: { number } = {}
		if px0 <= maxX and px1 >= minX and pz0 <= maxZ and pz1 >= minZ then
			for i = 1, #placed, 4 do
				local x, z, block = placed[i], placed[i + 2], placed[i + 3]
				if x >= minX and x <= maxX and z >= minZ and z <= maxZ and readu8(lut, block) ~= 0 then
					table.insert(out, x)
					table.insert(out, placed[i + 1])
					table.insert(out, z)
					table.insert(out, block)
				end
			end
		end
		if placer then
			placer.pieceBlocks(placer.starts(minX, minZ, maxX, maxZ), lut, minX, minZ, maxX, maxZ, out)
		end
		return out
	end

	return {
		seed = seed,
		column = column,
		generate = generate,
		findSpawn = findSpawn,
		seamLimits = seamLimits,
		farSeamLimits = farSeamLimits,
		structureContainer = structureContainer,
		structures = structuresIn,
		surfaceCaves = NO_SURFACE_CAVES,
		oilWells = none,
		oilLake = function(): buffer
			return buffer.create(0)
		end,
		lavaLakes = none,
		waterLakes = none,
		puddles = none,
		seaLevel = seaLevel,
		labels = function(): { TerrainGenerator.Label }
			return labels
		end,
		biomes = if columnAt then nil else { constantBiome },
		poiBlocks = poiBlocks,
	}
end

return LayeredGenerator
