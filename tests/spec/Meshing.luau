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
		if app == 0 then
			return 0, false
		end
		local kind = Blocks.appearances[app].kind
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
		if kind == OPAQUE then
			for _, d in dirs do
				local n = neighbour(d[1], d[2], d[3])
				if n ~= nil and buffer.readu8(cull, n) == 0 then
					return app, false
				end
			end
			return 0, true
		elseif kind == FLUID then
			for _, d in dirs do
				local n = neighbour(d[1], d[2], d[3])
				if n ~= nil and buffer.readu8(cull, n) == 0 and n ~= id then
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
		end
		return app, false
	end

	local function verify(data: buffer, height: number, y0: number, y1: number, hideCaves: boolean): number
		local boxes, count = GreedyMesher.mesh(data, height, y0, y1, hideCaves)
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
			for y = by, by + sy - 1 do
				for z = bz, bz + sz - 1 do
					for x = bx, bx + sx - 1 do
						local need, wild = classify(data, height, x, y, z, hideCaves)
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
					local need = classify(data, height, x, y, z, hideCaves)
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
		local glowstone = Blocks.get(Blocks.id.Glowstone).appearance
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
				ChunkLayout.set(data, x, 1, z, Blocks.id.Glowstone)
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
		for _, decor in { "Chest", "CraftingTable", "Furnace" } do
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
			if def.block == nil then
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
		local total = 0
		for _, p in { { 0, 0 }, { 3, -8 }, { -20, 11 } } do
			local r = gen.generate(0, p[1], p[2])
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
end
