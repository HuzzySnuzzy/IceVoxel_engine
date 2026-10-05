--[[
	Drawing plants (client side, pure parts): the foliage tint the mesher packs into tinted plants'
	box keys (GreedyMesher: the soil below, or below a tall plant's lower half, also across a
	section's bottom and through a border copy), `hideFoliage` (Config.Render.Foliage off or a chunk
	too far: no plant boxes, nothing else changes; plant cells counted either way), which chunks
	draw plants (LodTree.drawsFoliage: the foliage distance, its band, phones), the mesher's
	invariants with every plant on generated terrain,
	the scatter offsets and turns (Meshing/Scatter: deterministic, in range, both halves of a tall
	plant alike, the sunflower facing east) with every box inside its cell as the renderer places
	it, and plant item models fitting the cube ItemModels builds them in.
]]

return function(t, shared, require)
	local Blocks = require(shared.Blocks)
	local Config = require(shared.Config)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local GreedyMesher = require(shared.Meshing.GreedyMesher)
	local Scatter = require(shared.Meshing.Scatter)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)

	local B = Blocks.id
	local SIZE = ChunkLayout.SIZE
	local STRIDE = GreedyMesher.KEY_STRIDE
	local BOX = GreedyMesher.BOX_BYTES
	local SECTION = Config.SectionHeight
	local OPAQUE, FLUID = Blocks.KIND_OPAQUE, Blocks.KIND_FLUID
	local DRY = buffer.readu8(Blocks.tintLut, B.DryGrass)

	local function appearanceOf(name: string): number
		return Blocks.get(B[name]).appearance
	end

	-- Every plant block, and the tall plants' lower halves.
	local plants: { number } = {}
	local lowers: { number } = {}
	for id = 0, Blocks.count - 1 do
		if Blocks.isPlant(id) then
			table.insert(plants, id)
			if Blocks.plantTop(id) then
				table.insert(lowers, id)
			end
		end
	end

	-- Box keys by cell, "x,y,z" -> key, of a mesh.
	local function keysOf(boxes: buffer, count: number): { [string]: number }
		local keys = {}
		for b = 0, count - 1 do
			local o = b * BOX
			local x, y, z = buffer.readu16(boxes, o), buffer.readu16(boxes, o + 2), buffer.readu16(boxes, o + 4)
			keys[`{x},{y},{z}`] = buffer.readu16(boxes, o + 12)
		end
		return keys
	end

	-- A floor of `soil` at y = 0 .. 1 over every padded column.
	local function floor(height: number, soil: number): buffer
		local data = ChunkLayout.create(height)
		for z = -1, SIZE do
			for x = -1, SIZE do
				ChunkLayout.setPadded(data, x, 0, z, B.Stone)
				ChunkLayout.setPadded(data, x, 1, z, soil)
			end
		end
		return data
	end

	t.test("tint keys: tinted plants carry their soil's foliage tint, others none", function()
		t.ok(DRY > 0 and Blocks.FOLIAGE_TINTS[DRY] ~= nil, "DryGrass has a foliage tint")
		t.eq(buffer.readu8(Blocks.tintLut, B.Grass), 0, "Grass keeps the authored green")
		local data = floor(8, B.Grass)
		for x = 0, SIZE - 1 do
			ChunkLayout.set(data, x, 1, 5, B.DryGrass)
		end
		ChunkLayout.set(data, 1, 1, 1, B.Podzol)
		-- On Grass: no tint.
		ChunkLayout.set(data, 0, 2, 0, B.ShortGrass)
		ChunkLayout.set(data, 1, 2, 1, B.Fern)
		ChunkLayout.set(data, 2, 2, 0, B.TallGrass)
		ChunkLayout.set(data, 2, 3, 0, B.TallGrassTop)
		-- On DryGrass: tinted, both halves of tall ones; flowers and dead bushes never.
		ChunkLayout.set(data, 0, 2, 5, B.ShortGrass)
		ChunkLayout.set(data, 1, 2, 5, B.Fern)
		ChunkLayout.set(data, 2, 2, 5, B.TallGrass)
		ChunkLayout.set(data, 2, 3, 5, B.TallGrassTop)
		ChunkLayout.set(data, 3, 2, 5, B.LargeFern)
		ChunkLayout.set(data, 3, 3, 5, B.LargeFernTop)
		ChunkLayout.set(data, 4, 2, 5, B.Dandelion)
		ChunkLayout.set(data, 5, 2, 5, B.Sunflower)
		ChunkLayout.set(data, 5, 3, 5, B.SunflowerTop)
		ChunkLayout.set(data, 6, 2, 5, B.DeadBush)
		local keys = keysOf(GreedyMesher.mesh(data, 8, 0, 8, false))
		local function expect(x: number, y: number, z: number, name: string, tint: number)
			local key = keys[`{x},{y},{z}`]
			t.ok(key ~= nil, `{name} at ({x},{y},{z}) has a box`)
			local app, surface = GreedyMesher.decodeKey(key :: number)
			t.eq(app, appearanceOf(name), `{name} appearance`)
			t.eq(surface, tint, `{name} at ({x},{y},{z}) tint`)
		end
		expect(0, 2, 0, "ShortGrass", 0)
		expect(1, 2, 1, "Fern", 0)
		expect(2, 2, 0, "TallGrass", 0)
		expect(2, 3, 0, "TallGrassTop", 0)
		expect(0, 2, 5, "ShortGrass", DRY)
		expect(1, 2, 5, "Fern", DRY)
		expect(2, 2, 5, "TallGrass", DRY)
		expect(2, 3, 5, "TallGrassTop", DRY)
		expect(3, 2, 5, "LargeFern", DRY)
		expect(3, 3, 5, "LargeFernTop", DRY)
		expect(4, 2, 5, "Dandelion", 0)
		expect(5, 2, 5, "Sunflower", 0)
		expect(5, 3, 5, "SunflowerTop", 0)
		expect(6, 2, 5, "DeadBush", 0)
	end)

	t.test("tint keys: across a section's bottom, through a border copy and at the world's bottom", function()
		local height = 48
		local data = ChunkLayout.create(height)
		for z = -1, SIZE do
			for x = -1, SIZE do
				for y = 0, SECTION - 3 do
					ChunkLayout.setPadded(data, x, y, z, B.Stone)
				end
				ChunkLayout.setPadded(data, x, SECTION - 2, z, B.DryGrass)
			end
		end
		-- The lower half in the section below, the top at the section's bottom; grass at its bottom.
		ChunkLayout.set(data, 3, SECTION - 1, 3, B.TallGrass)
		ChunkLayout.set(data, 3, SECTION, 3, B.TallGrassTop)
		ChunkLayout.set(data, 8, SECTION - 1, 8, B.LargeFern)
		ChunkLayout.set(data, 8, SECTION, 8, B.LargeFernTop)
		local plain = keysOf(GreedyMesher.mesh(data, height, SECTION, 2 * SECTION, false))
		t.eq(plain[`3,{SECTION},3`], appearanceOf("TallGrassTop") + DRY * STRIDE, "tall grass top")
		t.eq(plain[`8,{SECTION},8`], appearanceOf("LargeFernTop") + DRY * STRIDE, "large fern top")

		-- A border makes the mesher work on a scratch copy: the soil two cells down must be in it,
		-- whatever an earlier call left there.
		local other = ChunkLayout.create(height)
		for z = -1, SIZE do
			for x = -1, SIZE do
				for y = 0, height - 1 do
					ChunkLayout.setPadded(other, x, y, z, B.Stone)
				end
			end
		end
		local border: GreedyMesher.Border = { open = nil, hidden = GreedyMesher.HIDDEN_BELOW }
		GreedyMesher.mesh(other, height, SECTION, 2 * SECTION, false, border)
		local bordered = keysOf(GreedyMesher.mesh(data, height, SECTION, 2 * SECTION, false, border))
		t.eq(bordered[`3,{SECTION},3`], plain[`3,{SECTION},3`], "same key through the border copy")
		t.eq(bordered[`8,{SECTION},8`], plain[`8,{SECTION},8`], "same key through the border copy")
		local open = buffer.create(4 * SIZE * 2)
		buffer.fill(open, 0, 0xFF)
		GreedyMesher.mesh(other, height, SECTION, 2 * SECTION, false, border)
		local seamed = keysOf(GreedyMesher.mesh(data, height, SECTION, 2 * SECTION, true, { open = open, hidden = 0 }))
		t.eq(seamed[`3,{SECTION},3`], plain[`3,{SECTION},3`], "same key with seams")

		-- Nothing below the world: no tint, no error.
		local bottom = ChunkLayout.create(4)
		ChunkLayout.set(bottom, 0, 0, 0, B.TallGrass)
		ChunkLayout.set(bottom, 0, 1, 0, B.TallGrassTop)
		ChunkLayout.set(bottom, 2, 0, 2, B.ShortGrass)
		local keys = keysOf(GreedyMesher.mesh(bottom, 4, 0, 4, false))
		t.eq(keys["0,0,0"], appearanceOf("TallGrass"), "lower half at y = 0")
		t.eq(keys["0,1,0"], appearanceOf("TallGrassTop"), "top at y = 1")
		t.eq(keys["2,0,2"], appearanceOf("ShortGrass"), "grass at y = 0")
	end)

	--[[ Invariants with plants (an independent reference, like tests/spec/Meshing) ]]

	-- The key cell (x, y, z) must be covered with (0 = none), and whether it is a hidden opaque
	-- cell any opaque box may cover.
	local function classify(
		data: buffer,
		height: number,
		x: number,
		y: number,
		z: number,
		hideCaves: boolean,
		hideFoliage: boolean
	): (number, boolean)
		local cull = if hideCaves then Blocks.cullLutHiddenCaves else Blocks.cullLut
		local id = ChunkLayout.get(data, x, y, z)
		local app = Blocks.get(id).appearance
		-- (Cave twins, the glow lichen of caves, are cave air while caves are hidden.)
		if app == 0 or (hideCaves and Blocks.isCaveTwin(id)) then
			return 0, false
		end
		local info = Blocks.appearances[app]
		if info.foliage and hideFoliage then
			return 0, false
		end
		local function neighbour(dx: number, dy: number, dz: number): number?
			local ny = y + dy
			if ny < 0 then
				return nil
			elseif ny >= height then
				return Blocks.AIR
			end
			return ChunkLayout.getPadded(data, x + dx, ny, z + dz)
		end
		local dirs = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }
		if info.kind == OPAQUE then
			for _, d in dirs do
				local n = neighbour(d[1], d[2], d[3])
				if n ~= nil and buffer.readu8(cull, n) == 0 then
					return app, false
				end
			end
			return 0, true
		elseif info.kind == FLUID then
			for _, d in dirs do
				local n = neighbour(d[1], d[2], d[3])
				if n ~= nil and buffer.readu8(cull, n) == 0 and n ~= id then
					local above = neighbour(0, 1, 0)
					local surface = buffer.readu8(Blocks.fluidHeightLut, id)
					if surface < Blocks.FLUID_FULL and Blocks.get(above :: number).appearance ~= app then
						return app + surface * STRIDE, false
					end
					return app, false
				end
			end
			return 0, false
		end
		if info.tinted then
			-- The soil: below, or below the lower half under a tall plant's top.
			local soil = if y >= 1 then ChunkLayout.get(data, x, y - 1, z) else nil
			if soil and Blocks.get(soil).tinted then
				soil = if y >= 2 then ChunkLayout.get(data, x, y - 2, z) else nil
			end
			return app + (if soil then buffer.readu8(Blocks.tintLut, soil) else 0) * STRIDE, false
		end
		return app, false
	end

	local function verify(
		data: buffer,
		height: number,
		y0: number,
		y1: number,
		hideCaves: boolean,
		hideFoliage: boolean
	): (number, number)
		local boxes, count = GreedyMesher.mesh(data, height, y0, y1, hideCaves, nil, hideFoliage)
		-- Sparse lights (glow lichen): the cell of each LIGHT_BOX box nearest its centre carries the
		-- light (surface field 1; the first in y, z, x order on a tie), see GreedyMesher.
		local light = GreedyMesher.LIGHT_BOX
		local best: { [string]: { number } } = {}
		for y = y0, y1 - 1 do
			for z = 0, SIZE - 1 do
				for x = 0, SIZE - 1 do
					local need = classify(data, height, x, y, z, hideCaves, hideFoliage)
					if need ~= 0 and need < STRIDE and buffer.readu8(GreedyMesher.sparseLightLut, need) == 1 then
						local key = `{x // light},{y // light},{z // light}`
						local score = GreedyMesher.lightScore(x, y, z)
						if best[key] == nil or score < best[key][1] then
							best[key] = { score, (y * SIZE + z) * SIZE + x }
						end
					end
				end
			end
		end
		local lit: { [number]: boolean } = {}
		for _, chosen in best do
			lit[chosen[2]] = true
		end
		local function expected(x: number, y: number, z: number): (number, boolean)
			local need, wild = classify(data, height, x, y, z, hideCaves, hideFoliage)
			if lit[(y * SIZE + z) * SIZE + x] then
				need += STRIDE
			end
			return need, wild
		end
		local coverage: { [number]: number } = {}
		local plantBoxes = 0
		for b = 0, count - 1 do
			local o = b * BOX
			local bx, by, bz = buffer.readu16(boxes, o), buffer.readu16(boxes, o + 2), buffer.readu16(boxes, o + 4)
			local sx, sy, sz = buffer.readu16(boxes, o + 6), buffer.readu16(boxes, o + 8), buffer.readu16(boxes, o + 10)
			local key = buffer.readu16(boxes, o + 12)
			local info = Blocks.appearances[key % STRIDE]
			if info.foliage then
				plantBoxes += 1
				assert(sx == 1 and sy == 1 and sz == 1, `plant box ({bx},{by},{bz}) is {sx}x{sy}x{sz}`)
				assert(not hideFoliage, "a plant drawn with foliage hidden")
			end
			for y = by, by + sy - 1 do
				for z = bz, bz + sz - 1 do
					for x = bx, bx + sx - 1 do
						local need, wild = expected(x, y, z)
						if need == key then
							local cell = (y * SIZE + z) * SIZE + x
							coverage[cell] = (coverage[cell] or 0) + 1
						elseif not (wild and info.kind == OPAQUE) then
							error(`box covers cell ({x},{y},{z}) it must not (key {key}, need {need})`)
						end
					end
				end
			end
		end
		for y = y0, y1 - 1 do
			for z = 0, SIZE - 1 do
				for x = 0, SIZE - 1 do
					if expected(x, y, z) ~= 0 then
						local n = coverage[(y * SIZE + z) * SIZE + x] or 0
						assert(n == 1, `visible cell ({x},{y},{z}) covered {n} times`)
					end
				end
			end
		end
		return count, plantBoxes
	end

	--[[
		A generated chunk with a plant on every column whose surface can hold one (cycling through
		every plant, tall ones where they fit), the surface turned to dry grass on every third
		column so tints show up. Returns the data, its height, the plant cells planted and the
		data without them.
	]]
	local function plantedChunk(seed: number, cx: number, cz: number): (buffer, number, number, buffer)
		local gen = TerrainGenerator.new(seed)
		local r = gen.generate(0, cx, cz)
		local height = r.height
		local data = r.data
		local bare = buffer.create(buffer.len(data))
		local cursor = 0
		for z = 0, SIZE - 1 do
			for x = 0, SIZE - 1 do
				local top = -1
				for y = height - 1, 0, -1 do
					if ChunkLayout.get(data, x, y, z) ~= Blocks.AIR then
						top = y
						break
					end
				end
				if top >= 0 and top + 2 < height then
					if (x + z) % 3 == 0 and ChunkLayout.get(data, x, top, z) == B.Grass then
						ChunkLayout.set(data, x, top, z, B.DryGrass)
					end
					local get = function(gx: number, gy: number, gz: number): number?
						if gy < 0 or gy >= height then
							return Blocks.AIR
						end
						return ChunkLayout.get(data, gx, gy, gz)
					end
					for _ = 1, #plants do
						cursor = cursor % #plants + 1
						local plant = plants[cursor]
						if Blocks.plantBottom(plant) == nil and Blocks.canPlace(plant, get, x, top + 1, z) then
							ChunkLayout.set(data, x, top + 1, z, plant)
							local upper = Blocks.plantTop(plant)
							if upper then
								ChunkLayout.set(data, x, top + 2, z, upper)
							end
							break
						end
					end
				end
			end
		end
		-- The same chunk without its plants (padding untouched: plants were set in the core).
		buffer.copy(bare, 0, data, 0, buffer.len(data))
		local planted = 0
		for y = 0, height - 1 do
			for z = 0, SIZE - 1 do
				for x = 0, SIZE - 1 do
					if Blocks.isPlant(ChunkLayout.get(bare, x, y, z)) then
						ChunkLayout.set(bare, x, y, z, Blocks.AIR)
						planted += 1
					end
				end
			end
		end
		return data, height, planted, bare
	end

	t.test("invariants: every visible cell covered once with plants, one box per plant", function()
		local total, tinted = 0, 0
		-- Plains, a forest, a taiga and a savanna.
		for _, p in { { 777, 150, 100 }, { 777, 0, -350 }, { 777, -300, -300 }, { 99, -20, 11 } } do
			local data, height, planted = plantedChunk(p[1], p[2], p[3])
			t.ok(planted > 0, `seed {p[1]} grew plants`)
			local drawn = 0
			for y0 = 0, height - 1, SECTION do
				for _, hide in { true, false } do
					local _, plantBoxes = verify(data, height, y0, math.min(y0 + SECTION, height), hide, false)
					if hide then
						drawn += plantBoxes
					end
				end
			end
			t.eq(drawn, planted, "every plant is one box")
			total += planted
			-- Some tinted keys made it in.
			local boxes, count = GreedyMesher.mesh(data, height, 0, height, true)
			for b = 0, count - 1 do
				local app, surface = GreedyMesher.decodeKey(buffer.readu16(boxes, b * BOX + 12))
				if Blocks.appearances[app].tinted and surface > 0 then
					tinted += 1
				end
			end
		end
		t.ok(total > 300, `plants checked ({total})`)
		t.ok(tinted > 10, `tinted plants on dry grass ({tinted})`)
	end)

	-- Plant cells in the core of layers y0 .. y1-1.
	local function plantCells(data: buffer, y0: number, y1: number): number
		local n = 0
		for y = y0, y1 - 1 do
			for z = 0, SIZE - 1 do
				for x = 0, SIZE - 1 do
					if Blocks.isPlant(ChunkLayout.get(data, x, y, z)) then
						n += 1
					end
				end
			end
		end
		return n
	end

	t.test("hideFoliage: no plant boxes, and every other box exactly as without the plants", function()
		for _, p in { { 777, 150, 100 }, { 99, -20, 11 } } do
			local data, height, planted, bare = plantedChunk(p[1], p[2], p[3])
			local counted = 0
			for y0 = 0, height - 1, SECTION do
				local y1 = math.min(y0 + SECTION, height)
				local cells = plantCells(data, y0, y1)
				for _, hide in { true, false } do
					local count = verify(data, height, y0, y1, hide, true)
					local hidden, hiddenCount, hiddenPlants = GreedyMesher.mesh(data, height, y0, y1, hide, nil, true)
					local plain, plainCount, plainPlants = GreedyMesher.mesh(bare, height, y0, y1, hide)
					local _, _, shownPlants = GreedyMesher.mesh(data, height, y0, y1, hide)
					t.eq(hiddenCount, count, "verified count")
					t.eq(hiddenCount, plainCount, `section {y0} box count`)
					t.eq(buffer.tostring(hidden), buffer.tostring(plain), `section {y0} boxes`)
					-- Plant cells are counted, drawn or not (the streamer remeshes those sections).
					t.eq(hiddenPlants, cells, `section {y0} plants counted when hidden`)
					t.eq(shownPlants, cells, `section {y0} plants counted when drawn`)
					t.eq(plainPlants, 0, `section {y0} without plants`)
					if hide then
						counted += cells
					end
				end
			end
			t.eq(counted, planted, "every plant counted in its section")
			-- The whole column as LOD chunks mesh it.
			local _, withCount = GreedyMesher.mesh(data, height, 0, height, true, nil, true)
			local _, bareCount = GreedyMesher.mesh(bare, height, 0, height, true)
			t.eq(withCount, bareCount, "whole column")
		end
		-- On by default: plants are drawn.
		t.eq(Config.Render.Foliage, true, "Config.Render.Foliage")
		local data = floor(4, B.Grass)
		ChunkLayout.set(data, 4, 2, 4, B.Poppy)
		local _, shown = GreedyMesher.mesh(data, 4, 0, 4, false)
		local _, hidden = GreedyMesher.mesh(data, 4, 0, 4, false, nil, true)
		local _, explicit = GreedyMesher.mesh(data, 4, 0, 4, false, nil, false)
		t.eq(shown, hidden + 1, "the poppy is one box, left out with hideFoliage")
		t.eq(explicit, shown, "hideFoliage = false draws it")
		-- A section holding nothing but a plant: no box when hidden, but the plant is counted.
		local top = floor(8, B.Grass)
		ChunkLayout.set(top, 3, 2, 3, B.TallGrass)
		ChunkLayout.set(top, 3, 3, 3, B.TallGrassTop)
		local _, none, counted = GreedyMesher.mesh(top, 8, 3, 8, false, nil, true)
		t.eq(none, 0, "only a hidden plant: no boxes")
		t.eq(counted, 1, "the tall grass's top is counted")
	end)

	--[[ Foliage distance ]]

	t.test("foliage distance: only full detail chunks near the viewer draw plants", function()
		local LodTree = require(shared.World.LodTree)
		local Coords = require(shared.World.Coords)
		local distance = Config.Lod.FoliageDistance
		local band = LodTree.FOLIAGE_HYSTERESIS
		t.eq(LodTree.foliageDistance(), distance, "Config.Lod.FoliageDistance")
		t.ok(distance > 0 and distance < 2 * Config.Lod.SplitDistanceL1 * SIZE, "closer than full detail reaches")
		-- Level 0 only, by the distance to the chunk (LodTree.distance), with a band for chunks
		-- already drawing them.
		local x, z = 8, 8
		t.ok(LodTree.drawsFoliage(0, 0, 0, x, z), "the viewer's chunk")
		t.eq(LodTree.drawsFoliage(1, 0, 0, x, z), false, "a level 1 node never does")
		-- Chunks east of the viewer: one within the distance, one beyond the band.
		local near, far = 1, (x + distance + band) // SIZE + 1
		t.ok(LodTree.distance(0, near, 0, x, z) < distance, "near chunk")
		t.ok(LodTree.distance(0, far, 0, x, z) >= distance + band, "far chunk")
		t.ok(LodTree.drawsFoliage(0, near, 0, x, z), "a chunk within the distance")
		t.eq(LodTree.drawsFoliage(0, far, 0, x, z), false, "a chunk beyond it")
		t.eq(LodTree.drawsFoliage(0, far, 0, x, z, true), false, "beyond the band too")
		-- Walking away from chunk 6: drawn while closer than the distance, kept (when drawn) while
		-- closer than the distance plus the band.
		local inBand = false
		for step = 0, 8 * SIZE do
			local px = 6 * SIZE - step
			local dd = LodTree.distance(0, 6, 0, px, z)
			local drawn = LodTree.drawsFoliage(0, 6, 0, px, z, false)
			local keeps = LodTree.drawsFoliage(0, 6, 0, px, z, true)
			t.eq(drawn, dd < distance, "threshold")
			t.eq(keeps, dd < distance + band, "band")
			inBand = inBand or (not drawn and keeps)
		end
		t.ok(inBand, "the band is crossed")
		-- Far fewer chunks than full detail has: every viewer position across a chunk.
		local most, mostKept, level0 = 0, 0, 0
		for ix = 0, SIZE, 2 do
			for iz = 0, SIZE, 2 do
				local drawn, kept, full = 0, 0, 0
				for key, level in LodTree.select(ix, iz) do
					local _, nx, nz = Coords.decodeNodeKey(key)
					full += if level == 0 then 1 else 0
					drawn += if LodTree.drawsFoliage(level, nx, nz, ix, iz) then 1 else 0
					kept += if LodTree.drawsFoliage(level, nx, nz, ix, iz, true) then 1 else 0
				end
				most, mostKept, level0 = math.max(most, drawn), math.max(mostKept, kept), math.max(level0, full)
			end
		end
		t.ok(most > 0 and mostKept <= level0 / 3, `{most} (kept: {mostKept}) of {level0} full detail chunks`)
		-- Off: no chunk draws them.
		Config.Render.Foliage = false
		local ok, err = pcall(function()
			t.eq(LodTree.drawsFoliage(0, 0, 0, x, z, true), false, "Render.Foliage off")
		end)
		Config.Render.Foliage = true
		assert(ok, err)
		-- Phones: a shorter distance (Rendering/ViewSettings).
		local phones = Config.Lod.Mobile.FoliageDistance
		t.ok(phones > 0 and phones < distance, "shorter on phones")
		-- (A chunk between the two distances: drawn on computers only.)
		local between = math.ceil((x + phones) / SIZE)
		local d = LodTree.distance(0, between, 0, x, z)
		t.ok(d >= phones and d < distance, "a chunk between the distances")
		t.ok(LodTree.drawsFoliage(0, between, 0, x, z), "drawn on computers")
		LodTree.setFoliageDistance(phones)
		t.eq(LodTree.foliageDistance(), phones, "set")
		t.eq(LodTree.drawsFoliage(0, between, 0, x, z), false, "not on phones")
		LodTree.setFoliageDistance(distance)
	end)

	--[[ Scatter ]]

	t.test("scatter: deterministic, within 3 pixels, every way round, independent of the seed", function()
		local sumX, sumZ, n = 0, 0, 0
		local yaws: { [number]: boolean } = {}
		local offsets: { [string]: boolean } = {}
		local distinctYaws, distinctOffsets = 0, 0
		for x = -40, 40, 3 do
			for z = -40, 40, 3 do
				for _, y in { 0, 70, 300, 1023 } do
					local dx, dz, yaw = Scatter.of(x, y, z)
					local dx2, dz2, yaw2 = Scatter.of(x, y, z)
					assert(dx == dx2 and dz == dz2 and yaw == yaw2, "deterministic")
					assert(math.abs(dx) <= Scatter.MAX_OFFSET and math.abs(dz) <= Scatter.MAX_OFFSET, "offset range")
					assert(yaw >= 0 and yaw < 2 * math.pi, "yaw range")
					sumX += dx
					sumZ += dz
					n += 1
					if not yaws[yaw] then
						yaws[yaw] = true
						distinctYaws += 1
					end
					local key = `{dx},{dz}`
					if not offsets[key] then
						offsets[key] = true
						distinctOffsets += 1
					end
				end
			end
		end
		t.eq(Scatter.MAX_OFFSET, 3, "Minecraft-like offset, kept to 3 pixels")
		t.ok(math.abs(sumX / n) < 0.3 and math.abs(sumZ / n) < 0.3, `offsets centred ({sumX / n}, {sumZ / n})`)
		t.ok(distinctYaws >= 60, `turns vary ({distinctYaws})`)
		t.ok(distinctOffsets >= 200, `offsets vary ({distinctOffsets})`)
		-- Neighbours differ.
		local a1, b1, c1 = Scatter.of(10, 70, 10)
		local a2, b2, c2 = Scatter.of(11, 70, 10)
		t.ok(a1 ~= a2 or b1 ~= b2 or c1 ~= c2, "neighbours differ")
	end)

	t.test("scatter: both halves of a tall plant alike, the sunflower facing east", function()
		for _, lower in lowers do
			local upper = Blocks.plantTop(lower) :: number
			local lowerApp, upperApp = Blocks.get(lower).appearance, Blocks.get(upper).appearance
			t.ok(Blocks.appearances[upperApp].upperHalf, `{Blocks.get(upper).name} is an upper half`)
			for x = -6, 6, 2 do
				for z = -6, 6, 3 do
					local y = 64 + x
					local a, b, c = Scatter.at(lowerApp, x, y, z)
					local d, e, f = Scatter.at(upperApp, x, y + 1, z)
					assert(a == d and b == e and c == f, `{Blocks.get(lower).name} halves differ at ({x},{y},{z})`)
				end
			end
		end
		local turned = 0
		for _, id in plants do
			local app = Blocks.get(id).appearance
			local name = Blocks.get(id).name
			local facing = name == "Sunflower" or name == "SunflowerTop"
			t.eq(Scatter.keepsFacing(app), facing, `{name} keeps its facing`)
			for x = 0, 15 do
				local dx, dz, yaw = Scatter.at(app, x, 65, -x)
				local ox, oz = Scatter.of(x, if Blocks.plantBottom(id) then 64 else 65, -x)
				t.eq(dx, ox, `{name} offset x`)
				t.eq(dz, oz, `{name} offset z`)
				if facing then
					t.eq(yaw, 0, `{name} is not turned`)
				elseif yaw ~= 0 then
					turned += 1
				end
			end
		end
		t.ok(turned > 300, `other plants are turned ({turned})`)
		-- Non-plants: their own position, any turn (the renderer only asks for scattered ones).
		local dx, dz, yaw = Scatter.at(appearanceOf("Stone"), 1, 2, 3)
		local ox, oz, oyaw = Scatter.of(1, 2, 3)
		t.ok(dx == ox and dz == oz and yaw == oyaw, "non-plants use their own position")
		-- Turning matches CFrame.Angles(0, yaw, 0): +X a quarter turn goes to -Z.
		local x, z = Scatter.turn(1, 0, math.pi / 2)
		t.near(x, 0, 1e-9, "turned x")
		t.near(z, -1, 1e-9, "turned z")
		x, z = Scatter.turn(0, 1, math.pi / 2)
		t.near(x, 1, 1e-9, "turned x")
		t.near(z, 0, 1e-9, "turned z")
	end)

	-- The corners of `box` (pixels from the cell's centre) placed as ChunkRenderer does: the box's
	-- rotation, its offset, the scatter turn about the cell's vertical axis, then the offset.
	local function corners(box: Blocks.ShapeBox, dx: number, dz: number, yaw: number): { { number } }
		local r = box.rotation or { 0, 0, 0 }
		local ax, ay, az = math.rad(r[1]), math.rad(r[2]), math.rad(r[3])
		local out = {}
		for _, sx in { -1, 1 } do
			for _, sy in { -1, 1 } do
				for _, sz in { -1, 1 } do
					-- CFrame.Angles(ax, ay, az) = Rx * Ry * Rz.
					local x, y, z = box.size[1] / 2 * sx, box.size[2] / 2 * sy, box.size[3] / 2 * sz
					x, y = x * math.cos(az) - y * math.sin(az), x * math.sin(az) + y * math.cos(az)
					x, z = x * math.cos(ay) + z * math.sin(ay), -x * math.sin(ay) + z * math.cos(ay)
					y, z = y * math.cos(ax) - z * math.sin(ax), y * math.sin(ax) + z * math.cos(ax)
					x, y, z = x + box.offset[1], y + box.offset[2], z + box.offset[3]
					x, z = Scatter.turn(x, z, yaw)
					table.insert(out, { x + dx, y, z + dz })
				end
			end
		end
		return out
	end

	t.test("scatter: every plant's boxes stay within a pixel of their cell as drawn", function()
		local worst = 0
		for _, id in plants do
			local def = Blocks.get(id)
			local app = def.appearance
			t.ok(Blocks.appearances[app].scatter, `{def.name} is scattered`)
			local shape = def.shape :: { Blocks.ShapeBox }
			for x = -8, 8 do
				for z = -8, 8, 4 do
					local dx, dz, yaw = Scatter.at(app, x, 70, z)
					for i, box in shape do
						for _, c in corners(box, dx, dz, yaw) do
							local out = math.max(math.abs(c[1]) - 8, math.abs(c[3]) - 8, c[2] - 8, -8 - c[2])
							worst = math.max(worst, out)
							assert(out <= 1 + 1e-6, `{def.name} box {i} is {out} px out of its cell`)
						end
					end
				end
			end
		end
		t.ok(worst <= 1, `at most a pixel out ({worst})`)
		-- The sunflower's disc faces east: thin along X, its middle on the east side of the petals.
		local top = Blocks.get(B.SunflowerTop).shape :: { Blocks.ShapeBox }
		local disc, middle = top[2], top[4]
		t.ok(disc.size[1] < disc.size[2] and disc.size[1] < disc.size[3], "disc thin along X")
		t.ok(middle.offset[1] > disc.offset[1], "the brown middle is on the east side")
	end)

	--[[ Item models ]]

	t.test("item models: plants fit the cube ItemModels builds them in", function()
		local Items = require(shared.Items)
		for _, id in plants do
			local def = Blocks.get(id)
			local item = Items.ofBlock(id)
			t.ok(item ~= nil, `{def.name} has an item`)
			if Blocks.plantBottom(id) == nil then
				t.eq(item, id, `{def.name} is its own item`)
				-- ItemModels draws `icon` (else `shape`) around the outline's centre, in a cube of
				-- 16 pixels (a leaning blade's foot may poke a little below the ground: allow a
				-- pixel); the icon starts with the shape's boxes (they take its part templates).
				local boxes = def.icon or def.shape :: { Blocks.ShapeBox }
				local shape = def.shape :: { Blocks.ShapeBox }
				for i, box in shape do
					t.eq(boxes[i], box, `{def.name} icon box {i} is its shape's`)
				end
				local b = def.bounds
				local cx, cy, cz =
					(b.min[1] + b.max[1]) / 2 - 8, (b.min[2] + b.max[2]) / 2 - 8, (b.min[3] + b.max[3]) / 2 - 8
				for i, box in boxes do
					for _, c in corners(box, 0, 0, 0) do
						local out = math.max(math.abs(c[1] - cx), math.abs(c[2] - cy), math.abs(c[3] - cz))
						assert(out <= 9, `{def.name} item box {i} sticks out of its cube ({out})`)
					end
				end
			else
				-- An upper half is the lower half's item (pick block, WAILA).
				t.eq(item, Blocks.plantBottom(id), `{def.name} item`)
			end
		end
		-- Shears are a tool, held by the handles like the others.
		local shears = Items.get(Items.id.Shears)
		t.ok(shears.block == nil and shears.model ~= nil and shears.tool ~= nil, "Shears have a model and are a tool")
		t.eq(shears.tilt, -45, "Shears lie diagonally like tools")
	end)
end
