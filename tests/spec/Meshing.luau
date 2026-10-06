return function(t, shared, require, _server, client)
	local Config = require(shared.Config)
	local Blocks = require(shared.Blocks)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local GreedyMesher = require(shared.Meshing.GreedyMesher)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)

	local SIZE = ChunkLayout.SIZE
	local OPAQUE, FLUID = Blocks.KIND_OPAQUE, Blocks.KIND_FLUID

	-- Straightforward reference for which cells must be drawn / may be skipped.
	local function classify(data: buffer, height: number, x: number, y: number, z: number, hideCaves: boolean)
		local cull = if hideCaves then Blocks.cullLutHiddenCaves else Blocks.cullLut
		local id = ChunkLayout.get(data, x, y, z)
		local app = Blocks.get(id).appearance
		local function neighbour(dx: number, dy: number, dz: number): number?
			local ny = y + dy
			if ny < 0 then
				return nil -- below the world: counts as solid
			elseif ny >= height then
				return Blocks.AIR
			end
			return ChunkLayout.getPadded(data, x + dx, ny, z + dz)
		end
		local dirs = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }
		-- (Cave twins are cave air while caves are hidden; a cave cell touching open space that is
		-- not cave is a stone cap then, any other is rock nobody sees: a wildcard.)
		if hideCaves and (id == Blocks.CAVE_AIR or buffer.readu8(Blocks.caveTwinLut, id) == 1) then
			for _, d in dirs do
				local n = neighbour(d[1], d[2], d[3])
				if n ~= nil and buffer.readu8(cull, n) == 0 then
					return Blocks.get(Blocks.id.Stone).appearance, false
				end
			end
			return 0, true
		end
		if app == 0 then
			return 0, false
		end
		local kind = Blocks.appearances[app].kind
		if kind == OPAQUE then
			for _, d in dirs do
				local n = neighbour(d[1], d[2], d[3])
				if n ~= nil and buffer.readu8(cull, n) == 0 then
					return app, false
				end
			end
			return 0, true
		elseif kind == FLUID then
			-- (A cave twin is its source: CaveLava next to Lava is the same fluid.)
			local form = Blocks.surfaceForm(id)
			for _, d in dirs do
				local n = neighbour(d[1], d[2], d[3])
				local nForm = if n ~= nil and Blocks.get(n).fluid then Blocks.surfaceForm(n) else n
				if n ~= nil and buffer.readu8(cull, n) == 0 and nForm ~= form then
					-- Visible; lowered to its level unless the same fluid continues above.
					local above = neighbour(0, 1, 0)
					local surface = buffer.readu8(Blocks.fluidHeightLut, id)
					if surface < Blocks.FLUID_FULL and Blocks.get(above :: number).appearance ~= app then
						return app + surface * GreedyMesher.KEY_STRIDE, false
					end
					return app, false
				end
			end
			return 0, false
		elseif buffer.readu8(Blocks.tintedLut, app) == 1 then
			-- A tinted plant: its soil's foliage tint in the key (under a tall plant's top, the soil
			-- is below its lower half).
			local soil = if y >= 1 then ChunkLayout.get(data, x, y - 1, z) else Blocks.AIR
			if buffer.readu8(Blocks.tintedLut, Blocks.get(soil).appearance) == 1 then
				soil = if y >= 2 then ChunkLayout.get(data, x, y - 2, z) else Blocks.AIR
			end
			return app + buffer.readu8(Blocks.tintLut, soil) * GreedyMesher.KEY_STRIDE, false
		end
		return app, false
	end

	--[[
		The cells of y0 .. y1 - 1 carrying a sparse light, by local index, with what their key gains:
		per LIGHT_BOX box the drawn glow lichen nearest its centre (surface field 1), and per
		FLUID_LIGHT_BOX box apart from those the drawn lava (FLUID_LIT on its height); the first in
		y, z, x order on a tie.
	]]
	local function sparseLights(data: buffer, height: number, y0: number, y1: number, hideCaves: boolean)
		local best: { [string]: { score: number, index: number, gain: number } } = {}
		for y = y0, y1 - 1 do
			for z = 0, SIZE - 1 do
				for x = 0, SIZE - 1 do
					local need = classify(data, height, x, y, z, hideCaves)
					local app = need % GreedyMesher.KEY_STRIDE
					if need ~= 0 and buffer.readu8(GreedyMesher.sparseLightLut, app) == 1 then
						local fluid = Blocks.appearances[app].kind == FLUID
						local box = if fluid then GreedyMesher.FLUID_LIGHT_BOX else GreedyMesher.LIGHT_BOX
						local key = `{if fluid then "fluid" else "lichen"} {x // box},{y // box},{z // box}`
						local score = GreedyMesher.lightScore(x, y, z, box)
						if best[key] == nil or score < best[key].score then
							local gain = if fluid then GreedyMesher.FLUID_LIT else 1
							best[key] = { score = score, index = (y * SIZE + z) * SIZE + x, gain = gain }
						end
					end
				end
			end
		end
		local lit: { [number]: number } = {}
		for _, chosen in best do
			lit[chosen.index] = chosen.gain
		end
		return lit
	end

	--[[
		Meshes cells y0 .. y1 - 1 and checks every box against the reference: inside the section, a
		decorated block one box each, every needed cell covered exactly once by a box of its own key,
		opaque boxes over nothing else but wildcards. With `align` (odd boxes), every box of a
		Blocks.alignLut appearance is an odd number of cells along all three axes. Returns the count.
	]]
	local function verify(
		data: buffer,
		height: number,
		y0: number,
		y1: number,
		hideCaves: boolean,
		align: boolean?
	): number
		local boxes, count = GreedyMesher.mesh(data, height, y0, y1, hideCaves, nil, nil, nil, align)
		local lit = sparseLights(data, height, y0, y1, hideCaves)
		-- What a cell must be covered by: its appearance, plus the light flag of a sparse light.
		local function expected(x: number, y: number, z: number): (number, boolean)
			local need, wild = classify(data, height, x, y, z, hideCaves)
			local gain = lit[(y * SIZE + z) * SIZE + x]
			if gain then
				need += gain * GreedyMesher.KEY_STRIDE
			end
			return need, wild
		end
		local coverage: { [number]: number } = {}
		for b = 0, count - 1 do
			local o = b * GreedyMesher.BOX_BYTES
			local bx, by, bz = buffer.readu16(boxes, o), buffer.readu16(boxes, o + 2), buffer.readu16(boxes, o + 4)
			local sx, sy, sz = buffer.readu16(boxes, o + 6), buffer.readu16(boxes, o + 8), buffer.readu16(boxes, o + 10)
			local app = buffer.readu16(boxes, o + 12) -- appearance + fluid surface height (see GreedyMesher)
			local opaqueBox = Blocks.appearances[app % GreedyMesher.KEY_STRIDE].kind == OPAQUE
			assert(bx + sx <= SIZE and bz + sz <= SIZE and by >= y0 and by + sy <= y1, "box outside the section")
			if buffer.readu8(Blocks.singleLut, app % GreedyMesher.KEY_STRIDE) == 1 then
				assert(sx == 1 and sy == 1 and sz == 1, `decorated block box ({bx},{by},{bz}) is {sx}x{sy}x{sz}`)
			end
			if align and buffer.readu8(Blocks.alignLut, app % GreedyMesher.KEY_STRIDE) == 1 then
				assert(
					sx % 2 == 1 and sy % 2 == 1 and sz % 2 == 1,
					`odd box ({bx},{by},{bz}) of appearance {app % GreedyMesher.KEY_STRIDE} is {sx}x{sy}x{sz}`
				)
			end
			for y = by, by + sy - 1 do
				for z = bz, bz + sz - 1 do
					for x = bx, bx + sx - 1 do
						local need, wild = expected(x, y, z)
						if need == app then
							local key = (y * SIZE + z) * SIZE + x
							coverage[key] = (coverage[key] or 0) + 1
						elseif not (wild and opaqueBox) then
							error(`box covers cell ({x},{y},{z}) it must not cover (need {need}, wild {wild})`)
						end
					end
				end
			end
		end
		for y = y0, y1 - 1 do
			for z = 0, SIZE - 1 do
				for x = 0, SIZE - 1 do
					local need = expected(x, y, z)
					if need ~= 0 then
						local n = coverage[(y * SIZE + z) * SIZE + x] or 0
						if n ~= 1 then
							error(`visible cell ({x},{y},{z}) covered {n} times`)
						end
					end
				end
			end
		end
		return count
	end

	t.test("single block becomes a single box", function()
		local data = ChunkLayout.create(4)
		ChunkLayout.set(data, 5, 1, 7, Blocks.id.Stone)
		t.eq(verify(data, 4, 0, 4, false), 1)
	end)

	t.test("a flat layer merges into one box and buried blocks are free", function()
		local data = ChunkLayout.create(8)
		for z = -1, SIZE do
			for x = -1, SIZE do
				for y = 0, 3 do
					ChunkLayout.setPadded(data, x, y, z, Blocks.id.Stone)
				end
				ChunkLayout.setPadded(data, x, 4, z, Blocks.id.Grass)
			end
		end
		t.eq(verify(data, 8, 0, 8, false), 1, "only the grass layer is visible")
		-- Dig a hole: the stone around it becomes visible and must be covered exactly.
		ChunkLayout.set(data, 8, 4, 8, Blocks.AIR)
		ChunkLayout.set(data, 8, 3, 8, Blocks.AIR)
		local count = verify(data, 8, 0, 8, false)
		t.ok(count > 1 and count < 12, `hole produced {count} boxes`)
	end)

	t.test("flowing water is lowered per level and only equal levels merge", function()
		local data = ChunkLayout.create(8)
		for z = -1, SIZE do
			for x = -1, SIZE do
				ChunkLayout.setPadded(data, x, 0, z, Blocks.id.Stone)
			end
		end
		-- A source with a row of weaker and weaker flowing water next to it, plus a falling column.
		ChunkLayout.set(data, 0, 1, 0, Blocks.fluidId("Water", 0))
		for level = 1, 7 do
			ChunkLayout.set(data, level, 1, 0, Blocks.fluidId("Water", level))
		end
		for y = 1, 4 do
			ChunkLayout.set(data, 10, y, 10, Blocks.fluidId("Water", 8))
		end
		local boxes, count = GreedyMesher.mesh(data, 8, 0, 8, false)
		local heights: { [number]: number } = {}
		for b = 0, count - 1 do
			local o = b * GreedyMesher.BOX_BYTES
			local appearance, surface = GreedyMesher.decodeKey(buffer.readu16(boxes, o + 12))
			if Blocks.appearances[appearance].kind == FLUID then
				heights[buffer.readu16(boxes, o) * 100 + buffer.readu16(boxes, o + 4)] = surface
			end
		end
		t.eq(heights[0], 8, "source surface is 8/9")
		t.eq(heights[300], 5, "level 3 is 5/9")
		t.eq(heights[700], 1, "level 7 is 1/9")
		t.eq(heights[1010], 0, "falling water is full height")
		verify(data, 8, 0, 8, false)
	end)

	-- Boxes of `data` (one section 0..height) as { x, y, z, sx, sy, sz, appearance } lists.
	local function boxList(data: buffer, height: number): { { number } }
		local boxes, count = GreedyMesher.mesh(data, height, 0, height, false)
		local list = {}
		for b = 0, count - 1 do
			local o = b * GreedyMesher.BOX_BYTES
			local row = {}
			for k = 0, 6 do
				row[k + 1] = buffer.readu16(boxes, o + k * 2)
			end
			table.insert(list, row)
		end
		return list
	end

	local function stoneFloor(height: number): buffer
		local data = ChunkLayout.create(height)
		for z = -1, SIZE do
			for x = -1, SIZE do
				ChunkLayout.setPadded(data, x, 0, z, Blocks.id.Stone)
			end
		end
		return data
	end

	t.test("decorated blocks: every chest is its own box, a row of stone stays one box", function()
		local chest = Blocks.get(Blocks.id.Chest).appearance
		local stone = Blocks.get(Blocks.id.Stone).appearance
		t.eq(buffer.readu8(Blocks.singleLut, chest), 1, "chests are meshed one box per block")
		t.eq(buffer.readu8(Blocks.singleLut, stone), 0, "stone merges")
		for _, name in { "CraftingTable", "Furnace" } do
			t.eq(buffer.readu8(Blocks.singleLut, Blocks.get(Blocks.id[name]).appearance), 1, name)
		end

		local data = stoneFloor(4)
		ChunkLayout.set(data, 3, 1, 3, Blocks.id.Chest)
		ChunkLayout.set(data, 4, 1, 3, Blocks.id.Chest)
		for x = 0, 5 do
			ChunkLayout.set(data, x, 1, 8, Blocks.id.Stone)
		end
		verify(data, 4, 0, 4, false)
		local chests, row = 0, 0
		for _, b in boxList(data, 4) do
			if b[7] == chest then
				chests += 1
				t.eq(b[4] * b[5] * b[6], 1, "a chest box is one block")
				t.eq(b[2], 1, "chest box height")
			elseif b[7] == stone and b[2] == 1 then
				row += 1
				t.eq(b[4], 6, "the stone row is one box along x")
			end
		end
		t.eq(chests, 2, "two adjacent chests give two boxes")
		t.eq(row, 1, "a row of stone stays one box")
	end)

	t.test("decorated blocks: stacks and walls never merge, hidden ones may be swallowed", function()
		local table_ = Blocks.get(Blocks.id.CraftingTable).appearance
		local furnace = Blocks.get(Blocks.id.Furnace).appearance
		local data = stoneFloor(6)
		-- A 2 x 2 x 2 cube of crafting tables and a wall of furnaces.
		for y = 1, 2 do
			for z = 2, 3 do
				for x = 2, 3 do
					ChunkLayout.set(data, x, y, z, Blocks.id.CraftingTable)
				end
			end
			for x = 6, 10 do
				ChunkLayout.set(data, x, y, 6, Blocks.id.Furnace)
			end
		end
		verify(data, 6, 0, 6, false)
		local tables, furnaces = 0, 0
		for _, b in boxList(data, 6) do
			if b[7] == table_ then
				tables += 1
			elseif b[7] == furnace then
				furnaces += 1
			end
		end
		t.eq(tables, 8, "one box per crafting table")
		t.eq(furnaces, 10, "one box per furnace")

		-- A chest buried in stone is never seen: the stone around it may cover it in one box.
		local buried = ChunkLayout.create(6)
		for z = -1, SIZE do
			for x = -1, SIZE do
				for y = 0, 4 do
					ChunkLayout.setPadded(buried, x, y, z, Blocks.id.Stone)
				end
			end
		end
		ChunkLayout.set(buried, 7, 2, 7, Blocks.id.Chest)
		t.eq(verify(buried, 6, 0, 6, false), 1, "the buried chest is swallowed by the stone box")
	end)

	t.test("light blocks: torches never merge and hide nothing; glowstone is one box per block", function()
		local torch = Blocks.get(Blocks.id.Torch).appearance
		local wall = Blocks.get(Blocks.id.WallTorchEast).appearance
		local glowstone = Blocks.get(Blocks.id.GlowBlock).appearance
		local stone = Blocks.get(Blocks.id.Stone).appearance
		t.ok(torch ~= wall, "each shape is its own appearance")
		for _, app in { torch, wall, glowstone, Blocks.get(Blocks.id.Lantern).appearance } do
			t.eq(buffer.readu8(Blocks.singleLut, app), 1)
		end

		-- A row and a stack of torches on a floor, a wall torch on a pillar, glowstone in a 2 x 2.
		local data = stoneFloor(6)
		for x = 2, 6 do
			ChunkLayout.set(data, x, 1, 2, Blocks.id.Torch)
		end
		for y = 1, 3 do
			ChunkLayout.set(data, 9, y, 9, Blocks.id.Torch)
		end
		ChunkLayout.set(data, 12, 1, 4, Blocks.id.Stone)
		ChunkLayout.set(data, 13, 1, 4, Blocks.id.WallTorchEast)
		for z = 6, 7 do
			for x = 12, 13 do
				ChunkLayout.set(data, x, 1, z, Blocks.id.GlowBlock)
			end
		end
		verify(data, 6, 0, 6, false)
		local counts: { [number]: number } = {}
		for _, b in boxList(data, 6) do
			local app = b[7]
			counts[app] = (counts[app] or 0) + 1
			if app == torch or app == wall or app == glowstone then
				t.eq(b[4] * b[5] * b[6], 1, "one block per box")
			end
		end
		t.eq(counts[torch], 8, "one box per torch")
		t.eq(counts[wall], 1)
		t.eq(counts[glowstone], 4, "one box (and light) per glowstone")

		-- A torch sealed inside solid stone: the stone around it has no other open side, yet it is
		-- drawn, since torches hide nothing (and no stone box may run through the torch).
		local buried = ChunkLayout.create(8)
		for z = -1, SIZE do
			for x = -1, SIZE do
				for y = 0, 5 do
					ChunkLayout.setPadded(buried, x, y, z, Blocks.id.Stone)
				end
			end
		end
		ChunkLayout.set(buried, 7, 4, 7, Blocks.id.Torch)
		verify(buried, 8, 0, 8, false)
		local covered = false
		for _, b in boxList(buried, 8) do
			if b[7] == stone and b[1] <= 7 and 7 < b[1] + b[4] and b[3] <= 7 and 7 < b[3] + b[6] then
				if b[2] <= 3 and 3 < b[2] + b[5] then
					covered = true
				end
			end
		end
		t.ok(covered, "the stone under the torch is drawn")
	end)

	t.test("glow lichen: one light per box; cave twins vanish with hidden caves and count as rock", function()
		local box = GreedyMesher.LIGHT_BOX
		local lichen = Blocks.get(Blocks.id.GlowLichen).appearance
		local twin = Blocks.id.CaveGlowLichen
		t.eq(Blocks.get(twin).appearance, lichen, "a twin looks like its lichen")
		for _, name in { "GlowLichen", "GlowLichenUp", "GlowLichenNorth", "CaveGlowLichenEast" } do
			t.eq(buffer.readu8(GreedyMesher.sparseLightLut, Blocks.get(Blocks.id[name]).appearance), 1, name)
		end
		for _, name in { "Torch", "Lantern", "GlowBlock", "Stone" } do
			t.eq(buffer.readu8(GreedyMesher.sparseLightLut, Blocks.get(Blocks.id[name]).appearance), 0, name)
		end

		-- A carpet of lichen on a stone floor: every cell drawn, one light per LIGHT_BOX box.
		local data = stoneFloor(4)
		for z = 0, SIZE - 1 do
			for x = 0, SIZE - 1 do
				ChunkLayout.set(data, x, 1, z, Blocks.id.GlowLichen)
			end
		end
		verify(data, 4, 0, 4, false)
		local lit, drawn = 0, 0
		local litAt: { [string]: { number } } = {}
		for _, b in boxList(data, 4) do
			local app, surface = GreedyMesher.decodeKey(b[7])
			if app == lichen then
				drawn += 1
				if surface == 1 then
					lit += 1
					local key = `{b[1] // box},{b[3] // box}`
					t.ok(litAt[key] == nil, "one light per box")
					litAt[key] = { b[1], b[2], b[3] }
				end
			end
		end
		t.eq(drawn, SIZE * SIZE, "every lichen is drawn")
		t.eq(lit, (SIZE // box) ^ 2, "one light per box")
		-- (Nearest the box's centre: the middle of the box, rows 3..4.)
		for _, at in litAt do
			t.ok(at[1] % box == box // 2 - 1 and at[3] % box == box // 2 - 1, "the light is near the centre")
		end
		-- The same blocks always light the same cells (meshing twice changes nothing), and removing
		-- an unlit lichen moves no light.
		local again: { [string]: boolean } = {}
		for _, b in boxList(data, 4) do
			local app, surface = GreedyMesher.decodeKey(b[7])
			if app == lichen and surface == 1 then
				again[`{b[1]},{b[3]}`] = true
			end
		end
		ChunkLayout.set(data, 0, 1, 0, Blocks.AIR)
		for _, at in litAt do
			t.ok(again[`{at[1]},{at[3]}`], "lit again")
		end
		for _, b in boxList(data, 4) do
			local app, surface = GreedyMesher.decodeKey(b[7])
			if app == lichen and surface == 1 then
				t.ok(again[`{b[1]},{b[3]}`], "no light moved")
			end
		end

		-- A cave: stone around a tunnel of cave air with twins on its floor and walls.
		local cave = ChunkLayout.create(12)
		for z = -1, SIZE do
			for x = -1, SIZE do
				for y = 0, 11 do
					ChunkLayout.setPadded(cave, x, y, z, Blocks.id.Stone)
				end
			end
		end
		for x = 2, 12 do
			for y = 4, 6 do
				ChunkLayout.set(cave, x, y, 7, Blocks.CAVE_AIR)
			end
			ChunkLayout.set(cave, x, 4, 7, Blocks.id.CaveGlowLichen)
		end
		ChunkLayout.set(cave, 5, 5, 7, Blocks.id.CaveGlowLichenNorth)
		ChunkLayout.set(cave, 9, 6, 7, Blocks.id.CaveGlowLichenUp)
		verify(cave, 12, 0, 12, false)
		verify(cave, 12, 0, 12, true)
		local hidden, hiddenCount = GreedyMesher.mesh(cave, 12, 0, 12, true)
		-- (Only the top of the stone, open to the sky, is drawn.)
		t.eq(hiddenCount, 1, "a hidden cave draws neither its lichen nor its walls")
		t.eq(buffer.readu16(hidden, 2), 11, "the top")
		local visibleLichen = 0
		local shown, shownCount = GreedyMesher.mesh(cave, 12, 0, 12, false)
		for b = 0, shownCount - 1 do
			local app = GreedyMesher.decodeKey(buffer.readu16(shown, b * GreedyMesher.BOX_BYTES + 12))
			if buffer.readu8(GreedyMesher.sparseLightLut, app) == 1 then
				visibleLichen += 1
			end
		end
		t.eq(visibleLichen, 13, "a revealed cave draws every lichen")
		-- The same tunnel with plain cave air instead of lichen gives the same walls.
		local plain = buffer.create(buffer.len(cave))
		buffer.copy(plain, 0, cave)
		for i = 0, buffer.len(plain) // 2 - 1 do
			if Blocks.isCaveTwin(buffer.readu16(plain, i * 2)) then
				buffer.writeu16(plain, i * 2, Blocks.CAVE_AIR)
			end
		end
		local _, plainCount = GreedyMesher.mesh(plain, 12, 0, 12, false)
		t.eq(shownCount - visibleLichen, plainCount, "twins hide nothing when caves are shown")

		-- Capped: a twin in the boundary layer next to hidden space becomes stone, like cave air.
		local capped =
			GreedyMesher.applyBorder(cave, 12, 5, 12, false, { open = nil, hidden = GreedyMesher.HIDDEN_BELOW })
		t.eq(ChunkLayout.get(capped, 5, 5, 7), Blocks.id.Stone, "own twin capped")
		t.eq(ChunkLayout.get(capped, 4, 4, 7), Blocks.id.Stone, "twin beyond counts as rock")
	end)

	t.test("decorated faces: every decor draws all six faces inside the 16 x 16 grid", function()
		local BlockDecor = require(client.Rendering.BlockDecor)
		local grid = BlockDecor.GRID
		local decors: { [string]: boolean } = {}
		for _, appearance in Blocks.appearances do
			if appearance.decor then
				decors[appearance.decor] = true
			end
		end
		t.ok(decors.Chest and decors.CraftingTable and decors.Furnace, "the three decorated blocks")
		t.ok(decors.CreativeEnergyCube and decors.HeatGenerator and decors.ElectricFurnace, "and Mekanism's machines")
		t.ok(
			decors.BasicBattery and decors.AdvancedBattery and decors.EliteBattery and decors.UltimateBattery,
			"and its energy cubes"
		)
		for decor in decors do
			local faces = BlockDecor.faces(decor)
			t.ok(faces ~= nil, `faces of {decor}`)
			assert(faces)
			for _, face in BlockDecor.FACES do
				local rects = faces[face]
				t.ok(rects ~= nil and #rects > 0, `{decor} has a {face} face`)
				for i, r in rects do
					t.ok(r.w > 0 and r.h > 0, `{decor} {face} rect {i} is empty`)
					t.ok(
						r.x >= 0 and r.y >= 0 and r.x + r.w <= grid and r.y + r.h <= grid,
						`{decor} {face} rect {i} out of the face`
					)
					t.eq(#r.colour, 3, `{decor} {face} rect {i} colour`)
					for _, c in r.colour do
						t.ok(c >= 0 and c <= 255 and c == math.floor(c), `{decor} {face} rect {i} colour value {c}`)
					end
				end
				-- Item model layers: drawn rects stack above every earlier one they overlap.
				local layers = BlockDecor.layers(rects, true)
				for i, r in rects do
					t.eq(layers[i] == 0, r.surfaceOnly == true, `{decor} {face} rect {i} drawn on item models`)
				end
			end
			-- Item models (icons, dropped and held items) stay cheap.
			local parts = BlockDecor.partCount(decor)
			t.ok(parts > 0 and parts < 40, `{decor} item model slabs: {parts}`)
		end
		t.eq(BlockDecor.faces("Nothing"), nil)
	end)

	t.test("decorated faces: the face axes are right handed, seen from outside", function()
		local BlockDecor = require(client.Rendering.BlockDecor)
		local seen: { [string]: boolean } = {}
		for _, face in BlockDecor.FACES do
			local n, r, u = BlockDecor.basis(face)
			local cross = { r[2] * u[3] - r[3] * u[2], r[3] * u[1] - r[1] * u[3], r[1] * u[2] - r[2] * u[1] }
			t.ok(cross[1] == n[1] and cross[2] == n[2] and cross[3] == n[3], `{face}: right x up = normal`)
			seen[`{n[1]},{n[2]},{n[3]}`] = true
			if face ~= "Top" and face ~= "Bottom" then
				t.ok(u[2] == 1, `{face} is upright`)
			end
		end
		for _, key in { "1,0,0", "-1,0,0", "0,1,0", "0,-1,0", "0,0,1", "0,0,-1" } do
			t.ok(seen[key], `a face points {key}`)
		end
	end)

	t.test("decorated faces: overlapping rects stack, separate ones stay on the block", function()
		local BlockDecor = require(client.Rendering.BlockDecor)
		local black = { 0, 0, 0 }
		local rects = {
			{ x = 0, y = 0, w = 16, h = 16, colour = black },
			{ x = 1, y = 1, w = 4, h = 4, colour = black },
			{ x = 8, y = 8, w = 4, h = 4, colour = black, surfaceOnly = true },
			{ x = 2, y = 2, w = 1, h = 1, colour = black },
			{ x = 10, y = 10, w = 1, h = 1, colour = black },
		}
		local items = BlockDecor.layers(rects :: any, true)
		t.eq(table.concat(items, ","), "1,2,0,3,2", "item model layers")
		local world = BlockDecor.layers(rects :: any, false)
		t.eq(table.concat(world, ","), "1,2,2,3,3", "world layers")
	end)

	t.test("decorated faces: item model tops and bottoms look the same turned by a quarter", function()
		-- (SurfaceGuis may turn those faces differently from BlockDecor.basis; see there.)
		local BlockDecor = require(client.Rendering.BlockDecor)
		local function picture(rects: { any }): { string }
			local cells = table.create(256, "")
			for _, r in rects do
				if not r.surfaceOnly then
					for y = r.y, r.y + r.h - 1 do
						for x = r.x, r.x + r.w - 1 do
							cells[y * 16 + x + 1] = table.concat(r.colour, ",")
						end
					end
				end
			end
			return cells
		end
		for _, decor in
			{
				"Chest",
				"CraftingTable",
				"Furnace",
				"CreativeEnergyCube",
				"HeatGenerator",
				"ElectricFurnace",
				"BasicBattery",
				"AdvancedBattery",
				"EliteBattery",
				"UltimateBattery",
			}
		do
			local faces = BlockDecor.faces(decor)
			assert(faces)
			for _, face in { "Top", "Bottom" } do
				local cells = picture(faces[face])
				for y = 0, 15 do
					for x = 0, 15 do
						local turned = cells[x * 16 + (15 - y) + 1]
						t.eq(cells[y * 16 + x + 1], turned, `{decor} {face} at {x},{y}`)
					end
				end
			end
		end
	end)

	t.test("item models: boxes are well formed and fit their cube", function()
		local Items = require(shared.Items)
		local models = 0
		for _, def in Items.list do
			-- (Items drawn from boxes: those of ItemList, the herbs that place a plant too.)
			if def.block == nil or def.model ~= nil then
				local boxes = def.model
				t.ok(boxes ~= nil and #boxes > 0, `{def.name} has a model`)
				assert(boxes)
				models += 1
				local tilt = math.rad(def.tilt)
				for i, box in boxes do
					t.ok(#box.size == 3 and #box.offset == 3, `{def.name} box {i} vectors`)
					for k = 1, 3 do
						t.ok(box.size[k] > 0, `{def.name} box {i} size`)
					end
					t.ok(box.shape == nil or box.shape == "Ball" or box.shape == "Cylinder", `{def.name} box {i} shape`)
					t.ok(box.color == nil or #box.color == 3, `{def.name} box {i} colour`)
					-- Corners in the icon's plane, turned by the box's rotation and the item's tilt.
					local r = math.rad(box.rotation or 0)
					for _, sx in { -1, 1 } do
						for _, sy in { -1, 1 } do
							local hx, hy = box.size[1] / 2 * sx, box.size[2] / 2 * sy
							local x = box.offset[1] + hx * math.cos(r) - hy * math.sin(r)
							local y = box.offset[2] + hx * math.sin(r) + hy * math.cos(r)
							local tx = x * math.cos(tilt) - y * math.sin(tilt)
							local ty = x * math.sin(tilt) + y * math.cos(tilt)
							-- The cube is 8 pixels each way: Minecraft's sprites fill it, 3D boxes a bit more.
							t.ok(
								math.abs(tx) <= 10 and math.abs(ty) <= 10,
								`{def.name} box {i} sticks out ({tx}, {ty})`
							)
						end
					end
				end
			end
		end
		t.ok(models >= 45, `models checked ({models})`)
		-- Tools and sticks lie diagonally like Minecraft's icons (head at the top right).
		for _, name in { "Stick", "WoodenPickaxe", "DiamondSword", "IronHoe" } do
			t.eq(Items.get(Items.id[name]).tilt, -45, `{name} tilt`)
		end
	end)

	t.test("glass and water are covered correctly", function()
		local data = ChunkLayout.create(8)
		local water = Blocks.fluidId("Water", 0)
		for z = -1, SIZE do
			for x = -1, SIZE do
				ChunkLayout.setPadded(data, x, 0, z, Blocks.id.Sand)
				for y = 1, 3 do
					ChunkLayout.setPadded(data, x, y, z, water)
				end
			end
		end
		ChunkLayout.set(data, 2, 2, 2, Blocks.id.Glass)
		ChunkLayout.set(data, 2, 3, 2, Blocks.id.Glass)
		verify(data, 8, 0, 8, false)
	end)

	t.test("generated chunks: every visible block covered once, nothing visible over-covered", function()
		local gen = TerrainGenerator.new(777)
		local sectionHeight = Config.SectionHeight
		local total, plants, tinted = 0, 0, 0
		-- (The last two: a savanna and a jungle with their plants, tinted ones on dry grass.)
		for _, p in { { 0, 0 }, { 3, -8 }, { -20, 11 }, { -1760, 24 }, { -1340, 20 } } do
			local r = gen.generate(0, p[1], p[2])
			for i = 0, buffer.len(r.data) // 2 - 1 do
				local block = buffer.readu16(r.data, i * 2)
				if Blocks.isPlant(block) and i >= ChunkLayout.LAYER then
					plants += 1
					if
						Blocks.get(block).tinted
						and Blocks.get(buffer.readu16(r.data, (i - ChunkLayout.LAYER) * 2)).name == "DryGrass"
					then
						tinted += 1
					end
				end
			end
			for y0 = 0, r.height - 1, sectionHeight do
				local y1 = y0 + sectionHeight
				for _, hide in { true, false } do
					if GreedyMesher.isTrivial(y0, y1, r.solidBelow, r.emptyAbove, hide) then
						local _, count = GreedyMesher.mesh(r.data, r.height, y0, y1, hide)
						t.eq(count, 0, "trivial section produced boxes")
					else
						total += verify(r.data, r.height, y0, y1, hide)
					end
				end
			end
		end
		t.ok(total > 0)
		t.ok(plants > 30, `plants in the generated chunks: {plants}`)
		t.ok(tinted > 5, `grass and ferns on dry grass: {tinted}`)
	end)

	t.test("LOD chunks mesh correctly as a whole column", function()
		local gen = TerrainGenerator.new(4242)
		for level = 1, 4 do
			local r = gen.generate(level, 1, 2)
			verify(r.data, r.height, 0, r.height, true)
		end
	end)

	-- Opaque cells covered by the boxes of `meshes` ({ boxes, count } pairs), keyed by local index.
	local function coverage(meshes: { { any } }): { [number]: boolean }
		local covered: { [number]: boolean } = {}
		for _, m in meshes do
			local boxes, count = m[1] :: buffer, m[2] :: number
			for b = 0, count - 1 do
				local o = b * GreedyMesher.BOX_BYTES
				local app = GreedyMesher.decodeKey(buffer.readu16(boxes, o + 12))
				if Blocks.appearances[app].kind == OPAQUE then
					local x, y, z = buffer.readu16(boxes, o), buffer.readu16(boxes, o + 2), buffer.readu16(boxes, o + 4)
					for yy = y, y + buffer.readu16(boxes, o + 8) - 1 do
						for zz = z, z + buffer.readu16(boxes, o + 10) - 1 do
							for xx = x, x + buffer.readu16(boxes, o + 6) - 1 do
								covered[ChunkLayout.localIndex(xx, yy, zz)] = true
							end
						end
					end
				end
			end
		end
		return covered
	end

	-- Meshes a generated node the way ChunkWorker does (caves hidden).
	local function meshNode(level: number, r: any, border: GreedyMesher.Border?): { { any } }
		local below = math.min(r.solidBelow, GreedyMesher.lowestOpen(border and border.open))
		local meshes = {}
		if level == 0 then
			for y0 = 0, r.height - 1, Config.SectionHeight do
				local y1 = y0 + Config.SectionHeight
				if not GreedyMesher.isTrivial(y0, y1, below, r.emptyAbove, true) then
					table.insert(meshes, { GreedyMesher.mesh(r.data, r.height, y0, y1, true, border) })
				end
			end
		else
			local y0, y1 = GreedyMesher.activeRange(below, r.emptyAbove, r.height)
			table.insert(meshes, { GreedyMesher.mesh(r.data, r.height, y0, y1, true, border) })
		end
		return meshes
	end

	local function isTerrain(id: number): boolean
		local name = Blocks.get(id).name
		return Blocks.isOpaque(id) and not (string.find(name, "Log") or string.find(name, "Leaves") or name == "Cactus")
	end

	t.test("LOD seams: the finer side draws every border cell its coarser neighbour leaves open", function()
		local gen = TerrainGenerator.new(12345)
		local sx, _, sz = gen.findSpawn()
		local checked = 0
		-- Plains around spawn and steep mountains, at several level pairs.
		for _, case in { { 0, sx, sz }, { 1, sx, sz }, { 0, 4544, -7488 }, { 1, 4544, -7488 }, { 2, 4544, -7488 } } do
			local level = case[1]
			local step, stepY = ChunkLayout.steps(level)
			local cs, csY = ChunkLayout.steps(level + 1)
			local span = SIZE * step
			local nx, nz = case[2] // span, case[3] // span
			local r = gen.generate(level, nx, nz)
			for side = 1, 4 do
				local coarser = { 0, 0, 0, 0 }
				coarser[side] = level + 1
				local open = gen.seamLimits(level, nx, nz, coarser) :: buffer
				local covered = coverage(meshNode(level, r, { open = open, hidden = 0 }))
				local coarseNodes: { [string]: any } = {}
				for i = 0, SIZE - 1 do
					local limit = buffer.readu16(open, ((side - 1) * SIZE + i) * 2)
					local lx = if side == 1 then 0 elseif side == 2 then SIZE - 1 else i
					local lz = if side == 3 then 0 elseif side == 4 then SIZE - 1 else i
					-- The limit is where the coarser node's generated terrain ends next to this cell.
					local px = nx * span + (lx + (if side == 1 then -1 elseif side == 2 then 1 else 0)) * step
					local pz = nz * span + (lz + (if side == 3 then -1 elseif side == 4 then 1 else 0)) * step
					local cnx, cnz = px // (SIZE * cs), pz // (SIZE * cs)
					local key = `{cnx},{cnz}`
					local coarse = coarseNodes[key] or gen.generate(level + 1, cnx, cnz)
					coarseNodes[key] = coarse
					local clx, clz = (px - cnx * SIZE * cs) // cs, (pz - cnz * SIZE * cs) // cs
					local top = 1
					while top < coarse.height and isTerrain(ChunkLayout.get(coarse.data, clx, top, clz)) do
						top += 1
					end
					t.eq(limit * stepY, top * csY, `seam limit vs coarse terrain (level {level}, side {side}, {i})`)
					-- Every opaque fine cell from there up is visible across the seam, so it is drawn.
					for y = limit, r.height - 1 do
						if Blocks.isOpaque(ChunkLayout.get(r.data, lx, y, lz)) then
							checked += 1
							t.ok(
								covered[ChunkLayout.localIndex(lx, y, lz)],
								`border cell ({lx},{y},{lz}) of level {level} node {nx},{nz} not drawn (side {side})`
							)
						end
					end
				end
			end
		end
		t.ok(checked > 100, `enough exposed border cells checked ({checked})`)
	end)

	t.test("LOD seams: border cells facing a coarser node's ravine are drawn", function()
		local gen = TerrainGenerator.new(12345)
		-- The deepest open cut (a ravine: carved air open to the sky) in chunks along a stretch.
		local deepest, rx, rz = 0, 0, 0
		for cz = -30, -24, 2 do
			for cx = 30, 38, 2 do
				local c = gen.generate(0, cx, cz, nil, true)
				for z = 0, SIZE - 1 do
					for x = 0, SIZE - 1 do
						local top = buffer.readu16(c.surface, (z * SIZE + x) * 2)
						local y = top - 1
						while y > 0 and ChunkLayout.get(c.data, x, y, z) == Blocks.AIR do
							y -= 1
						end
						if top - 1 - y > deepest then
							deepest, rx, rz = top - 1 - y, cx * SIZE + x, cz * SIZE + z
						end
					end
				end
			end
		end
		assert(deepest >= 15, `a ravine near 540, -420 ({deepest} deep)`)
		-- Nodes around it at levels 0 and 1, each side next to a coarser node: every opaque border
		-- cell whose coarser neighbour is not terrain there (the cut) must be drawn.
		local holes, facing = 0, 0
		local coarseNodes: { [string]: any } = {}
		for level = 0, 1 do
			local step, stepY = ChunkLayout.steps(level)
			local cs, csY = ChunkLayout.steps(level + 1)
			local span = SIZE * step
			for dz = -1, 1 do
				for dx = -1, 1 do
					local nx, nz = rx // span + dx, rz // span + dz
					local r = gen.generate(level, nx, nz)
					for side = 1, 4 do
						local coarser = { 0, 0, 0, 0 }
						coarser[side] = level + 1
						local open = gen.seamLimits(level, nx, nz, coarser) :: buffer
						local covered = coverage(meshNode(level, r, { open = open, hidden = 0 }))
						for i = 0, SIZE - 1 do
							local lx = if side == 1 then 0 elseif side == 2 then SIZE - 1 else i
							local lz = if side == 3 then 0 elseif side == 4 then SIZE - 1 else i
							local px = nx * span + (lx + (if side == 1 then -1 elseif side == 2 then 1 else 0)) * step
							local pz = nz * span + (lz + (if side == 3 then -1 elseif side == 4 then 1 else 0)) * step
							local cnx, cnz = px // (SIZE * cs), pz // (SIZE * cs)
							local key = `{level + 1},{cnx},{cnz}`
							local coarse = coarseNodes[key] or gen.generate(level + 1, cnx, cnz)
							coarseNodes[key] = coarse
							local clx, clz = (px - cnx * SIZE * cs) // cs, (pz - cnz * SIZE * cs) // cs
							-- (Up to the coarse column's terrain height: above it the plain seam rule holds.)
							local h = gen.column(px, pz)
							for y = 1, math.min(r.height, h // stepY) - 1 do
								local cy = (y * stepY) // csY
								if
									cy < coarse.height
									and not isTerrain(ChunkLayout.get(coarse.data, clx, cy, clz))
									and Blocks.isOpaque(ChunkLayout.get(r.data, lx, y, lz))
								then
									facing += 1
									if not covered[ChunkLayout.localIndex(lx, y, lz)] then
										holes += 1
									end
								end
							end
						end
					end
				end
			end
		end
		print(
			`    ravine {deepest} deep at {rx}, {rz}: {facing} border cells face a coarser node's cut, {holes} not drawn`
		)
		t.ok(facing > 0, "border cells face the ravine across a seam")
		t.eq(holes, 0, "border cells facing a coarser node's ravine are drawn (TerrainGenerator.seamLimits)")
	end)

	t.test("cave caps: tunnels running into a hidden section end in stone, not the void", function()
		local gen = TerrainGenerator.new(12345)
		local section = Config.SectionHeight
		-- Undrawn opaque cells reachable from the open caves of the revealed sections.
		local function holes(r: any, boundary: number, capped: boolean): number
			local meshes = {}
			for s = 0, r.height // section - 1 do
				local y0, y1 = s * section, (s + 1) * section
				local hide = y0 < boundary
				if not GreedyMesher.isTrivial(y0, y1, r.solidBelow, r.emptyAbove, hide) then
					local border = if capped and y0 == boundary
						then { open = nil, hidden = GreedyMesher.HIDDEN_BELOW }
						else nil
					table.insert(meshes, { GreedyMesher.mesh(r.data, r.height, y0, y1, hide, border) })
				end
			end
			local covered = coverage(meshes)
			local seen: { [number]: boolean } = {}
			local queue = {}
			for y = boundary + 1, r.height - 1 do
				for z = 0, SIZE - 1 do
					for x = 0, SIZE - 1 do
						local i = ChunkLayout.localIndex(x, y, z)
						if ChunkLayout.get(r.data, x, y, z) == Blocks.CAVE_AIR and not covered[i] then
							seen[i] = true
							table.insert(queue, { x, y, z })
						end
					end
				end
			end
			local found, head = 0, 1
			while head <= #queue do
				local p = queue[head]
				head += 1
				if Blocks.isOpaque(ChunkLayout.get(r.data, p[1], p[2], p[3])) then
					found += 1
				else
					for _, d in { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } } do
						local x, y, z = p[1] + d[1], p[2] + d[2], p[3] + d[3]
						if x >= 0 and x < SIZE and z >= 0 and z < SIZE and y >= 0 and y < r.height then
							local i = ChunkLayout.localIndex(x, y, z)
							if not seen[i] and not covered[i] then
								seen[i] = true
								table.insert(queue, { x, y, z })
							end
						end
					end
				end
			end
			return found
		end
		-- The section boundary of a chunk crossed by the most tunnels (0 = none).
		local function busiestBoundary(r: any): (number, number)
			local boundary, most = 0, 0
			for s = 1, r.height // section - 1 do
				local count = 0
				for z = 0, SIZE - 1 do
					for x = 0, SIZE - 1 do
						if
							ChunkLayout.get(r.data, x, s * section, z) == Blocks.CAVE_AIR
							and ChunkLayout.get(r.data, x, s * section - 1, z) == Blocks.CAVE_AIR
						then
							count += 1
						end
					end
				end
				if count > most then
					boundary, most = s * section, count
				end
			end
			return boundary, most
		end
		-- Caves come in regions: test the first chunks along a line that have tunnels across sections.
		local before, tested = 0, 0
		for cx = -40, 120, 3 do
			local r = gen.generate(0, cx, -11)
			local boundary, most = busiestBoundary(r)
			if most > 0 then
				before += holes(r, boundary, false)
				t.eq(holes(r, boundary, true), 0, `holes at the cave boundary of chunk {cx},-11`)
				tested += 1
				if tested == 3 then
					break
				end
			end
		end
		t.eq(tested, 3, "chunks with a tunnel crossing a section boundary")
		t.ok(before > 0, "without caps the tunnels would end in the void")
	end)

	--[[
		Void faces of a full detail chunk meshed section by section, revealed where `reveal` says
		(caps towards every hidden section and the neighbouring chunks, as the streamer does):
		a cell that is open where it is meshed (not opaque, and not cave air in a hidden section)
		next to one that is solid where *that* one is meshed, but drawn by no opaque box. Looking
		from the first at the second shows the void. Returns the count and the meshes.
	]]
	local function voids(r: any, reveal: { [number]: boolean }): (number, { { any } })
		local section = Config.SectionHeight
		local sections = math.ceil(r.height / section)
		local meshes = {}
		-- The cells as each revealed section meshes them: its caps are stone.
		local seen = buffer.create(buffer.len(r.data))
		buffer.copy(seen, 0, r.data)
		for s = 0, sections - 1 do
			local y0, y1 = s * section, math.min((s + 1) * section, r.height)
			local hide = not reveal[s]
			local border: GreedyMesher.Border? = nil
			if not hide then
				local hidden = 1 + 2 + 4 + 8
				if s > 0 and not reveal[s - 1] then
					hidden += GreedyMesher.HIDDEN_BELOW
				end
				if not reveal[s + 1] then
					hidden += GreedyMesher.HIDDEN_ABOVE
				end
				border = { open = nil, hidden = hidden }
				local copy = GreedyMesher.applyBorder(r.data, r.height, y0, y1, false, border :: any)
				local from, bytes = y0 * ChunkLayout.LAYER * 2, (y1 - y0) * ChunkLayout.LAYER * 2
				buffer.copy(seen, from, copy, from, bytes)
			end
			if not GreedyMesher.isTrivial(y0, y1, r.solidBelow, r.emptyAbove, hide) then
				table.insert(meshes, { GreedyMesher.mesh(r.data, r.height, y0, y1, hide, border, true) })
			end
		end
		local covered = coverage(meshes)
		local function open(x: number, y: number, z: number): boolean
			if covered[ChunkLayout.localIndex(x, y, z)] then
				return false
			end
			local cull = if reveal[y // section] then Blocks.cullLut else Blocks.cullLutHiddenCaves
			return buffer.readu8(cull, ChunkLayout.get(seen, x, y, z)) == 0
		end
		local found = 0
		for y = 0, r.height - 1 do
			for z = 0, SIZE - 1 do
				for x = 0, SIZE - 1 do
					if open(x, y, z) then
						for _, d in { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } } do
							local nx, ny, nz = x + d[1], y + d[2], z + d[3]
							if
								nx >= 0
								and nx < SIZE
								and nz >= 0
								and nz < SIZE
								and ny >= 0
								and ny < r.height
								and not open(nx, ny, nz)
								and not covered[ChunkLayout.localIndex(nx, ny, nz)]
							then
								found += 1
							end
						end
					end
				end
			end
		end
		return found, meshes
	end

	-- Every reveal pattern of sections 0 .. n - 1 (bit s: section s revealed).
	local function patterns(n: number): { { [number]: boolean } }
		local list = {}
		for bits = 0, bit32.lshift(1, n) - 1 do
			local reveal = {}
			for s = 0, n - 1 do
				reveal[s] = bit32.btest(bits, bit32.lshift(1, s))
			end
			table.insert(list, reveal)
		end
		return list
	end

	t.test("hidden caves: a shaft dug into a cave ends in a stone cap, not the void", function()
		local height = 64
		local data = ChunkLayout.create(height)
		local stone, air, caveAir = Blocks.id.Stone, Blocks.AIR, Blocks.CAVE_AIR
		local twin = -1
		for id = 0, Blocks.count - 1 do
			if buffer.readu8(Blocks.caveTwinLut, id) == 1 then
				twin = id
				break
			end
		end
		-- Rock up to the surface at 48 (padding too), a cave in sections 1 and 2 with lichen
		-- (cave twins) on its floor, a shaft dug from the surface into its ceiling, a tunnel dug
		-- into its side across the section boundary at 32, and the neighbouring chunk's own shaft
		-- (in the padding) beside its -X end.
		for y = 0, 47 do
			for z = -1, SIZE do
				for x = -1, SIZE do
					ChunkLayout.setPadded(data, x, y, z, stone)
				end
			end
		end
		for y = 20, 35 do
			for z = 2, 12 do
				for x = 0, 12 do
					ChunkLayout.set(data, x, y, z, caveAir)
				end
			end
		end
		for z = 3, 11 do
			ChunkLayout.set(data, 6, 20, z, twin)
		end
		ChunkLayout.set(data, 7, 36, 7, twin) -- lichen on the shaft's rim, under the shaft
		for y = 37, 47 do
			ChunkLayout.set(data, 7, y, 7, air)
		end
		for x = 13, 15 do
			ChunkLayout.set(data, x, 31, 7, air)
			ChunkLayout.set(data, x, 32, 7, air)
		end
		for y = 22, 47 do
			ChunkLayout.setPadded(data, -1, y, 7, air)
		end
		local r = { data = data, height = height, solidBelow = 20, emptyAbove = 48 }

		-- Every section hidden (the camera above ground): the shaft, the tunnel and the
		-- neighbour's shaft look at stone where they meet the cave.
		local found, meshes = voids(r, {})
		t.eq(found, 0, "no void anywhere with every section hidden")
		local covered = coverage(meshes)
		t.ok(covered[ChunkLayout.localIndex(7, 36, 7)], "the shaft's floor (a cave twin) is a stone cap")
		t.ok(covered[ChunkLayout.localIndex(12, 31, 7)], "the dug tunnel's end is a stone cap")
		t.ok(covered[ChunkLayout.localIndex(0, 30, 7)], "the cave beside the neighbour's shaft is capped")
		-- What the caps are: stone, exactly the cave cells next to the dug air.
		local stoneApp = Blocks.get(stone).appearance
		for _, m in meshes do
			local boxes, n = m[1] :: buffer, m[2] :: number
			for b = 0, n - 1 do
				local o = b * GreedyMesher.BOX_BYTES
				local app = GreedyMesher.decodeKey(buffer.readu16(boxes, o + 12))
				local x, y, z = buffer.readu16(boxes, o), buffer.readu16(boxes, o + 2), buffer.readu16(boxes, o + 4)
				local id = ChunkLayout.get(data, x, y, z)
				if id == caveAir or id == twin then
					t.eq(app, stoneApp, "a cap is stone")
				end
			end
		end
		-- The mesher's invariants hold section by section, with the caps (and revealed).
		for y0 = 16, 32, 16 do
			verify(data, height, y0, y0 + 16, true)
			verify(data, height, y0, y0 + 16, false)
		end
		-- Every mix of revealed and hidden sections (the cave view's caps between them).
		for _, reveal in patterns(4) do
			t.eq((voids(r, reveal)), 0, "no void with a mix of revealed and hidden sections")
		end
	end)

	t.test("hidden caves: real surface caves meet hidden caves in stone; invariants hold", function()
		local gen = TerrainGenerator.new(12345)
		-- Chunks around (0, 6) where air carved below the surface (cave entrances) touches cave air.
		local found = 0
		for ring = 0, 4 do
			for dz = -ring, ring do
				for dx = -ring, ring do
					if found >= 2 or (math.abs(dx) ~= ring and math.abs(dz) ~= ring) then
						continue
					end
					local cx, cz = dx + 0, 6 + dz
					local r = gen.generate(0, cx, cz, nil, true)
					local junctions = 0
					for z = 0, SIZE - 1 do
						for x = 0, SIZE - 1 do
							local top = buffer.readu16(r.surface, (z * SIZE + x) * 2)
							for y = math.max(r.solidBelow, 1), top - 1 do
								if ChunkLayout.get(r.data, x, y, z) == Blocks.AIR then
									for _, d in
										{
											{ 1, 0, 0 },
											{ -1, 0, 0 },
											{ 0, 1, 0 },
											{ 0, -1, 0 },
											{ 0, 0, 1 },
											{ 0, 0, -1 },
										}
									do
										local id = ChunkLayout.getPadded(r.data, x + d[1], y + d[2], z + d[3])
										if id == Blocks.CAVE_AIR then
											junctions += 1
										end
									end
								end
							end
						end
					end
					if junctions == 0 then
						continue
					end
					found += 1
					-- Caves hidden everywhere (the camera above ground): every junction is capped.
					local holes, meshes = voids(r, {})
					t.eq(holes, 0, `chunk {cx},{cz}: no void where the entrance meets the cave`)
					-- Every cave cell next to open space that is not cave is a cap, drawn.
					local covered = coverage(meshes)
					local capped = 0
					for z = 0, SIZE - 1 do
						for x = 0, SIZE - 1 do
							for y = 1, r.height - 2 do
								if ChunkLayout.get(r.data, x, y, z) ~= Blocks.CAVE_AIR then
									continue
								end
								for _, d in
									{ { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }
								do
									local id = ChunkLayout.getPadded(r.data, x + d[1], y + d[2], z + d[3])
									if buffer.readu8(Blocks.cullLutHiddenCaves, id) == 0 then
										capped += 1
										t.ok(covered[ChunkLayout.localIndex(x, y, z)], `cap ({x},{y},{z}) drawn`)
										break
									end
								end
							end
						end
					end
					t.ok(capped > 0, "stone caps drawn")
					-- The invariants, section by section, hidden and revealed.
					local sections = math.ceil(r.height / Config.SectionHeight)
					for s = 0, sections - 1 do
						local y0, y1 = s * Config.SectionHeight, math.min((s + 1) * Config.SectionHeight, r.height)
						for _, hide in { true, false } do
							if not GreedyMesher.isTrivial(y0, y1, r.solidBelow, r.emptyAbove, hide) then
								verify(r.data, r.height, y0, y1, hide)
							end
						end
					end
					-- Mixes of revealed and hidden sections (the cave view's caps between them).
					local all, even, odd = {}, {}, {}
					for s = 0, sections - 1 do
						all[s] = true
						even[s] = s % 2 == 0
						odd[s] = s % 2 == 1
					end
					for _, reveal in { all, even, odd } do
						t.eq((voids(r, reveal)), 0, `chunk {cx},{cz}: no void with revealed sections`)
					end
					print(`    chunk {cx},{cz}: {junctions} junction faces, {capped} stone caps`)
				end
			end
		end
		t.eq(found, 2, "chunks where a surface cave meets a cave")
	end)

	--[[ Odd boxes (GreedyMesher's `align`: Config.Textures.OddBoxes, full detail only) ]]

	local KEY_STRIDE = GreedyMesher.KEY_STRIDE

	-- Every box of a mesh as "x,y,z,sx,sy,sz,key", by appearance, in order.
	local function boxLists(boxes: buffer, count: number): { [number]: { string } }
		local lists: { [number]: { string } } = {}
		for b = 0, count - 1 do
			local o = b * GreedyMesher.BOX_BYTES
			local fields = {}
			for k = 0, 6 do
				fields[k + 1] = buffer.readu16(boxes, o + k * 2)
			end
			local app = fields[7] % KEY_STRIDE
			local list = lists[app] or {}
			lists[app] = list
			table.insert(list, table.concat(fields, ","))
		end
		return lists
	end

	local function sameBuffers(a: buffer, b: buffer): boolean
		return buffer.len(a) == buffer.len(b) and buffer.tostring(a) == buffer.tostring(b)
	end

	-- Sections of chunk `r` as the streamer meshes them, each (data, y0, y1, hideCaves) with its
	-- border already applied (GreedyMesher.applyBorder's copy meshes like the original with the
	-- border): caves hidden, caves revealed, the cave view (revealed, capped towards hidden space on
	-- every side) and seams (every side next to a coarser node, caves hidden).
	local function sectionCases(gen: any, r: any, each: (data: buffer, y0: number, y1: number, hide: boolean) -> ())
		local open = gen.seamLimits(0, r.nx, r.nz, { 1, 1, 1, 1 })
		local all = GreedyMesher.HIDDEN_BELOW + GreedyMesher.HIDDEN_ABOVE + 1 + 2 + 4 + 8
		for y0 = 0, r.height - 1, Config.SectionHeight do
			local y1 = math.min(y0 + Config.SectionHeight, r.height)
			for _, case in { "hidden", "revealed", "caveview", "seams" } do
				local hide = case == "hidden" or case == "seams"
				local below = if case == "seams"
					then math.min(r.solidBelow, GreedyMesher.lowestOpen(open))
					else r.solidBelow
				if GreedyMesher.isTrivial(y0, y1, below, r.emptyAbove, hide) then
					continue
				end
				local data = r.data
				if case == "caveview" then
					data = GreedyMesher.applyBorder(r.data, r.height, y0, y1, false, { hidden = all })
				elseif case == "seams" then
					data = GreedyMesher.applyBorder(r.data, r.height, y0, y1, true, { open = open, hidden = 0 })
				end
				-- (The border copy is the mesher's scratch: copy it before meshing anything else.)
				if data ~= r.data then
					local copy = buffer.create(buffer.len(data))
					buffer.copy(copy, 0, data)
					data = copy
				end
				each(data, y0, y1, hide)
			end
		end
	end

	t.test("odd boxes: off, as by default, every box is what it always was", function()
		local gen = TerrainGenerator.new(777)
		local saved = buffer.create(buffer.len(Blocks.alignLut))
		buffer.copy(saved, 0, Blocks.alignLut)
		local sections = 0
		for _, p in { { 0, 0 }, { -20, 11 }, { -1340, 20 } } do
			local r = gen.generate(0, p[1], p[2])
			sectionCases(gen, r, function(data, y0, y1, hide)
				for _, foliage in { false, true } do
					local today, n = GreedyMesher.mesh(data, r.height, y0, y1, hide, nil, foliage)
					local off, nOff = GreedyMesher.mesh(data, r.height, y0, y1, hide, nil, foliage, nil, false)
					t.ok(n == nOff and sameBuffers(today, off), "align false = no align")
					-- The rule's code path itself changes nothing when no appearance asks for it.
					buffer.fill(Blocks.alignLut, 0, 0)
					local none, nNone = GreedyMesher.mesh(data, r.height, y0, y1, hide, nil, foliage, nil, true)
					buffer.copy(Blocks.alignLut, 0, saved)
					t.ok(n == nNone and sameBuffers(today, none), "align with an empty LUT = no align")
				end
				sections += 1
			end)
		end
		t.ok(sections > 20, `sections compared: {sections}`)
	end)

	t.test("odd boxes: a flat layer takes four odd boxes; an even run extends into hidden rock", function()
		local function stoneWorld(height: number, top: number): buffer
			local data = ChunkLayout.create(height)
			for z = -1, SIZE do
				for x = -1, SIZE do
					for y = 0, top do
						ChunkLayout.setPadded(data, x, y, z, Blocks.id.Stone)
					end
				end
			end
			return data
		end
		-- A flat layer of grass: 16 is even on X and Z, so the fewest odd boxes is four.
		local flat = stoneWorld(8, 3)
		for z = -1, SIZE do
			for x = -1, SIZE do
				ChunkLayout.setPadded(flat, x, 4, z, Blocks.id.Grass)
			end
		end
		t.eq(verify(flat, 8, 0, 8, false), 1, "one box without the rule")
		t.eq(verify(flat, 8, 0, 8, false, true), 4, "four odd boxes with it")
		local sizes = {}
		for _, list in boxLists(GreedyMesher.mesh(flat, 8, 0, 8, false, nil, nil, nil, true)) do
			for _, box in list do
				local f = string.split(box, ",")
				table.insert(sizes, `{f[4]}x{f[5]}x{f[6]}`)
			end
		end
		table.sort(sizes)
		t.eq(table.concat(sizes, " "), "15x1x1 15x1x15 1x1x1 1x1x15")

		-- Stone under a stone roof with a 2-wide slot (x = 1, 2) open to the sky and a glass wall
		-- at x = 3: the slot's floor is a 2-cell run, which starts one cell earlier, inside the
		-- hidden rock at x = 0, instead of losing a cell.
		local slot = stoneWorld(6, 3)
		for z = -1, SIZE do
			ChunkLayout.setPadded(slot, 1, 3, z, Blocks.AIR)
			ChunkLayout.setPadded(slot, 2, 3, z, Blocks.AIR)
			ChunkLayout.setPadded(slot, 3, 2, z, Blocks.id.Glass)
		end
		verify(slot, 6, 0, 6, false, true)
		local plain = boxLists(GreedyMesher.mesh(slot, 6, 0, 6, false))
		local odd = boxLists(GreedyMesher.mesh(slot, 6, 0, 6, false, nil, nil, nil, true))
		local stone = Blocks.get(Blocks.id.Stone).appearance
		t.ok(table.find(plain[stone], `1,2,0,2,1,16,{stone}`) ~= nil, "the slot floor is one 2 x 16 box today")
		t.ok(table.find(odd[stone], `0,2,0,3,1,15,{stone}`) ~= nil, "extended into the rock, then 15 long")
		t.ok(table.find(odd[stone], `0,2,15,3,1,1,{stone}`) ~= nil, "and the last row the same way")
	end)

	t.test("odd boxes: generated chunks, every textured box odd, coverage exact, others unchanged", function()
		local aligned = 0
		for app = 1, #Blocks.appearances do
			aligned += buffer.readu8(Blocks.alignLut, app)
		end
		t.ok(aligned > 10, `appearances with odd boxes: {aligned}`)
		local gen = TerrainGenerator.new(777)
		local before, after, sections = 0, 0, 0
		-- Plains, hills, a savanna, a jungle, and the chunk with the most caves in its region.
		for _, p in { { 0, 0 }, { 3, -8 }, { -20, 11 }, { -1760, 24 }, { -1340, 20 }, { -30, 40 } } do
			local r = gen.generate(0, p[1], p[2])
			sectionCases(gen, r, function(data, y0, y1, hide)
				local today, n = GreedyMesher.mesh(data, r.height, y0, y1, hide)
				local count = verify(data, r.height, y0, y1, hide, true)
				local odd = GreedyMesher.mesh(data, r.height, y0, y1, hide, nil, nil, nil, true)
				-- Appearances without the rule: the same boxes in the same order.
				local mine, theirs = boxLists(odd, count), boxLists(today, n)
				for app, list in theirs do
					if buffer.readu8(Blocks.alignLut, app) == 0 then
						t.eq(table.concat(mine[app] or {}, ";"), table.concat(list, ";"), `appearance {app} unchanged`)
					end
				end
				for app in mine do
					t.ok(theirs[app] ~= nil, `appearance {app} only with the rule`)
				end
				before += n
				after += count
				sections += 1
			end)
		end
		t.ok(after > before, "odd boxes cost boxes")
		t.ok(after < before * 1.6, `but not too many ({before} -> {after})`)
		print(
			string.format(
				"    odd boxes: %d -> %d boxes (%+.1f%%) over %d sections (hidden, revealed, cave view, seams)",
				before,
				after,
				(after / before - 1) * 100,
				sections
			)
		)
	end)
end
