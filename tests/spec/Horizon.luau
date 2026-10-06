--[[
	Far nodes hidden behind terrain (World/Horizon): node summaries (from data and from the
	generator), the sweep (walls, gaps, the margin eyes, nodes kept near the camera), that every
	node it hides really is hidden (rays against the occluders from every eye), estimates for nodes
	not generated yet, and records; and the streamer's side (Streaming/HiddenTerrain): when to
	evaluate, which verdict counts, when it holds, and the records it sends.
]]

return function(t, shared, require, _server, client)
	local Blocks = require(shared.Blocks)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Coords = require(shared.World.Coords)
	local Horizon = require(shared.World.Horizon)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)

	local SIZE = ChunkLayout.SIZE
	local P = ChunkLayout.PADDED
	local STONE = Blocks.id.Stone
	local WATER = Blocks.fluidId("Water", 0)
	local LOG = Blocks.id.OakLog or STONE

	t.test("horizon: summaries from a column's data", function()
		local height = 48
		local data = ChunkLayout.create(height)
		local topCells = table.create(P * P, 0)
		-- Ground at 10 + px, except tile (1, 2) holding a dip to 3; a tree on tile (0, 0); water on
		-- tile (3, 3) up to 30.
		for pz = 0, P - 1 do
			for px = 0, P - 1 do
				local top = 10 + px
				if px >= 5 and px <= 8 and pz >= 9 and pz <= 12 then
					top = if px == 6 and pz == 10 then 3 else top
				end
				topCells[pz * P + px + 1] = top
				for y = 0, top do
					ChunkLayout.setPadded(data, px - 1, y, pz - 1, STONE)
				end
			end
		end
		for y = 12, 25 do
			ChunkLayout.set(data, 1, y, 1, LOG)
		end
		for y = 30, 30 do
			for z = 12, 15 do
				for x = 12, 15 do
					ChunkLayout.set(data, x, y, z, WATER)
				end
			end
		end
		local summary = Horizon.summarise(data, height, 40, topCells, 1)
		t.eq(buffer.len(summary), Horizon.SUMMARY_BYTES, "64 bytes")
		-- Tile (tx, tz) covers padded columns 1 + 4 tx .. 4 + 4 tx.
		t.eq(Horizon.ground(summary, 0), 12, "tile 0: lowest top 11, ground 12 blocks")
		t.eq(Horizon.top(summary, 0), 26, "tile 0: the tree")
		t.eq(Horizon.ground(summary, 2 * 4 + 1), 4, "the dip")
		t.eq(Horizon.top(summary, 2 * 4 + 1), 10 + 8 + 1, "its highest terrain")
		t.eq(Horizon.ground(summary, 15), 10 + 13 + 1, "water is not ground")
		t.eq(Horizon.top(summary, 15), 31, "water is a top")
		-- Coarse levels count in blocks.
		local coarse = Horizon.summarise(data, height, 40, topCells, 4)
		t.eq(Horizon.ground(coarse, 0), 12 * 4, "cells of 4 blocks")
	end)

	t.test("horizon: generated summaries agree with the terrain", function()
		local gen = TerrainGenerator.new(12345)
		for _, n in { { 0, 30, -10 }, { 2, 50, -228 }, { 4, 12, -57 } } do
			local level, nx, nz = n[1], n[2], n[3]
			local r = gen.generate(level, nx, nz, nil, true)
			local summary = r.summary :: buffer
			t.ok(summary ~= nil, "a summary")
			local step, stepY = ChunkLayout.steps(level)
			for tile = 0, 15 do
				local ground, top = Horizon.ground(summary, tile), Horizon.top(summary, tile)
				t.ok(ground >= stepY and ground <= top, `level {level} tile {tile}: ground {ground} top {top}`)
				-- Every core column's highest drawn cell is under the top; ground is at most the
				-- lowest drawn terrain.
				local tx, tz = tile % 4, tile // 4
				local lowest = math.huge
				for z = tz * 4, tz * 4 + 3 do
					for x = tx * 4, tx * 4 + 3 do
						local high = 0
						for y = r.height - 1, 0, -1 do
							if ChunkLayout.get(r.data, x, y, z) > Blocks.CAVE_AIR then
								high = (y + 1) * stepY
								break
							end
						end
						t.ok(high <= top, `column under the tile's top ({high} > {top})`)
						local h = gen.column(nx * SIZE * step + x * step, nz * SIZE * step + z * step)
						if level == 0 then
							lowest = math.min(lowest, h)
						end
					end
				end
				if level == 0 then
					t.eq(ground, lowest, "full detail ground: the terrain height")
				end
			end
		end
		t.eq(gen.generate(0, 3, 3).summary, nil, "only when asked")
	end)

	--[[ Synthetic nodes for the sweep: a summary with every tile at one ground / top. ]]

	local function flat(ground: number, top: number): buffer
		local s = buffer.create(Horizon.SUMMARY_BYTES)
		for i = 0, 15 do
			buffer.writeu16(s, i * 2, ground)
			buffer.writeu16(s, 32 + i * 2, top)
		end
		return s
	end

	type Scene = { keys: { number }, summaries: { buffer } }
	local function scene(): Scene
		return { keys = {}, summaries = {} }
	end
	local function add(sc: Scene, level: number, nx: number, nz: number, summary: buffer): number
		local key = Coords.nodeKey(level, nx, nz)
		table.insert(sc.keys, key)
		table.insert(sc.summaries, summary)
		return key
	end
	local function hiddenSet(
		sc: Scene,
		x: number,
		y: number,
		z: number,
		options: Horizon.Options?
	): { [number]: boolean }
		local records = Horizon.pack(sc.keys, sc.summaries)
		local set = {}
		for _, key in Horizon.evaluate(records, #sc.keys, x, y, z, options) do
			set[key] = true
		end
		return set
	end

	t.test("horizon: a ridge hides the low land behind it, not what rises above it", function()
		local sc = scene()
		-- The eye at (8, 70, 8) on flat land at 64. A ridge (ground 200) of level 1 nodes 160 blocks
		-- out along +X, from z -256 to +256; level 1 nodes behind it.
		for nz = -8, 7 do
			add(sc, 1, 5, nz, flat(200, 200))
		end
		for nx = -2, 4 do
			for nz = -2, 1 do
				add(sc, 1, nx, nz, flat(64, 64))
			end
		end
		local behind = add(sc, 1, 9, 0, flat(64, 70))
		local tall = add(sc, 1, 9, 1, flat(64, 400))
		local farBehind = add(sc, 2, 6, -1, flat(64, 80))
		local hidden = hiddenSet(sc, 8, 70, 8)
		t.ok(hidden[behind], "low node behind the ridge")
		t.ok(hidden[farBehind], "far node behind the ridge")
		t.ok(not hidden[tall], "a peak above the ridge shows")
		t.ok(not hidden[Coords.nodeKey(1, 5, 0)], "the ridge itself shows")
		t.ok(not hidden[Coords.nodeKey(1, 1, 0)], "nothing in front of it is hidden")
		-- A gap in the ridge in front of `behind` (and the nodes beside it) shows it again.
		local gap = scene()
		for i, key in sc.keys do
			local _, nx, nz = Coords.decodeNodeKey(key)
			local level = Coords.decodeNodeKey(key)
			if not (level == 1 and nx == 5 and nz >= -1 and nz <= 1) then
				add(gap, level, nx, nz, sc.summaries[i])
			end
		end
		add(gap, 1, 5, -1, flat(64, 64))
		add(gap, 1, 5, 0, flat(64, 64))
		add(gap, 1, 5, 1, flat(64, 64))
		local open = hiddenSet(gap, 8, 70, 8)
		t.ok(not open[behind], "seen through the gap")
	end)

	t.test("horizon: edits lower dug ground, not under a tunnel, and raise built tops", function()
		local gen = TerrainGenerator.new(12345)
		local r = gen.generate(0, 30, -10, nil, true)
		local summary = r.summary :: buffer
		local before = buffer.create(Horizon.SUMMARY_BYTES)
		buffer.copy(before, 0, summary)
		local data, height = r.data, r.height
		local edits: { number } = {}
		local function edit(x: number, y: number, z: number, block: number)
			local index = (y * P + z + 1) * P + x + 1
			buffer.writeu16(data, index * 2, block)
			table.insert(edits, index)
			table.insert(edits, block)
		end
		-- A quarry down to y 20 over tile 0 (cells 0..3, 0..3).
		for z = 0, 3 do
			for x = 0, 3 do
				for y = 20, height - 1 do
					if ChunkLayout.get(data, x, y, z) ~= Blocks.AIR then
						edit(x, y, z, Blocks.AIR)
					end
				end
			end
		end
		-- A tunnel under tile 5 (cells 4..7), well below its ground.
		local ground5 = Horizon.ground(summary, 5)
		for x = 4, 7 do
			edit(x, ground5 - 12, 5, Blocks.AIR)
			edit(x, ground5 - 11, 5, Blocks.AIR)
		end
		-- A tower on tile 10 (cells 8..11).
		local top10 = Horizon.top(summary, 10)
		edit(9, top10 + 5, 9, STONE)
		-- Padding cells belong to the neighbours.
		local padding = (30 * P + 0) * P + 0
		table.insert(edits, padding)
		table.insert(edits, Blocks.AIR)
		t.ok(Horizon.applyEdits(summary, data, height, edits, Blocks.cullLut), "changed")
		t.eq(Horizon.ground(summary, 0), 20, "the quarry's floor")
		t.eq(Horizon.ground(summary, 5), ground5, "a tunnel keeps the ground")
		t.eq(Horizon.top(summary, 10), top10 + 6, "the tower's top")
		for tile = 0, 15 do
			if tile ~= 0 and tile ~= 10 then
				t.eq(Horizon.ground(summary, tile), Horizon.ground(before, tile), `tile {tile} ground`)
			end
			if tile ~= 10 then
				t.eq(Horizon.top(summary, tile), Horizon.top(before, tile), `tile {tile} top`)
			end
		end
		t.ok(not Horizon.applyEdits(summary, data, height, edits, Blocks.cullLut), "applied twice: no change")

		-- What it hides: a ridge of full detail chunks (stone up to 110) in front of a far node.
		local function ridgeScene(ridge: buffer): Scene
			local sc = scene()
			for nx = -2, 3 do
				for nz = -4, 4 do
					add(sc, 0, nx, nz, flat(60, 60))
				end
			end
			for nx = 4, 6 do
				for nz = -4, 4 do
					add(sc, 0, nx, nz, ridge)
				end
			end
			add(sc, 2, 5, 0, flat(70, 75))
			return sc
		end
		local far = Coords.nodeKey(2, 5, 0)
		local ridgeData = ChunkLayout.create(112)
		local digs: { number } = {}
		for y = 0, 111 do
			for pz = 0, P - 1 do
				for px = 0, P - 1 do
					local index = (y * P + pz) * P + px
					local dug = y >= 40 and px >= 1 and px <= SIZE and pz >= 1 and pz <= SIZE
					buffer.writeu16(ridgeData, index * 2, if y < 110 and not dug then STONE else Blocks.AIR)
					if dug and y < 110 then
						table.insert(digs, index)
						table.insert(digs, Blocks.AIR)
					end
				end
			end
		end
		local ridge = flat(110, 110)
		t.ok(hiddenSet(ridgeScene(ridge), 8, 61.6, 32)[far], "hidden behind the ridge as generated")
		Horizon.applyEdits(ridge, ridgeData, 112, digs, Blocks.cullLut)
		t.eq(Horizon.ground(ridge, 0), 40, "the ridge dug down to 40")
		t.ok(not hiddenSet(ridgeScene(ridge), 8, 61.6, 32)[far], "seen once the ridge is dug away")
	end)

	t.test("horizon: margin eyes, nodes near the camera, unknown tops", function()
		local sc = scene()
		-- A wall just high enough to hide a node from eye height, not from 16 above.
		for nz = -4, 3 do
			add(sc, 1, 3, nz, flat(76, 76))
		end
		local node = add(sc, 1, 6, 0, flat(64, 72))
		local exact = hiddenSet(sc, 8.5, 70, 5.5, { raise = 0, spread = 0 })
		t.ok(exact[node], "hidden from the eye itself")
		local raised = hiddenSet(sc, 8.5, 70, 5.5, { raise = 16, spread = 0 })
		t.ok(not raised[node], "not from 16 blocks higher")
		-- A short wall: hidden from the centre, not from an eye 40 blocks to the side.
		local short = scene()
		add(short, 1, 3, 0, flat(120, 120))
		local narrow = add(short, 1, 7, 0, flat(64, 70))
		t.ok(hiddenSet(short, 8, 70, 8, { raise = 0, spread = 0 })[narrow], "behind a short wall")
		t.ok(not hiddenSet(short, 8, 70, 8, { raise = 0, spread = 40 })[narrow], "seen from the side eye")
		-- Never within `keep`, never with an unknown top.
		local near = scene()
		add(near, 0, 3, 0, flat(200, 200))
		local close = add(near, 0, 4, 0, flat(64, 64))
		t.ok(not hiddenSet(near, 8, 70, 8, { raise = 0, spread = 0 })[close], "kept within 64 blocks")
		t.ok(hiddenSet(near, 8, 70, 8, { raise = 0, spread = 0, keep = 32 })[close], "keep is an option")
		local unknown = scene()
		add(unknown, 1, 3, 0, flat(500, 500))
		local u = add(unknown, 1, 6, 0, flat(0, Horizon.UNKNOWN))
		t.ok(not hiddenSet(unknown, 8, 70, 8)[u], "unknown tops are never hidden")
	end)

	t.test("horizon: whatever it hides is behind terrain from every eye (random terrain)", function()
		local state = 99
		local function random(): number
			state = (state * 1103515245 + 12345) % 2147483648
			return state / 2147483648
		end
		-- Occluder boxes of a scene (every tile with ground > 0).
		local function blocked(
			boxes: { { number } },
			ex: number,
			ey: number,
			ez: number,
			px: number,
			py: number,
			pz: number
		): boolean
			local dx, dy, dz = px - ex, py - ey, pz - ez
			for _, b in boxes do
				-- Segment / box (slab test), the box [x0, x1] x [0, h] x [z0, z1], before the point.
				local t0, t1 = 0, 0.999
				local ok = true
				for axis = 1, 3 do
					local o, d, lo, hi
					if axis == 1 then
						o, d, lo, hi = ex, dx, b[1], b[2]
					elseif axis == 2 then
						o, d, lo, hi = ey, dy, 0, b[5]
					else
						o, d, lo, hi = ez, dz, b[3], b[4]
					end
					if math.abs(d) < 1e-9 then
						if o < lo or o > hi then
							ok = false
							break
						end
					else
						local a, c = (lo - o) / d, (hi - o) / d
						if a > c then
							a, c = c, a
						end
						t0, t1 = math.max(t0, a), math.min(t1, c)
						if t0 > t1 then
							ok = false
							break
						end
					end
				end
				if ok then
					return true
				end
			end
			return false
		end
		local checked = 0
		for round = 1, 4 do
			local sc = scene()
			local boxes = {}
			local tops: { [number]: buffer } = {}
			-- A ring of level 1 / 2 nodes with random tiles around the origin.
			for nz = -6, 5 do
				for nx = -6, 5 do
					local level = if math.max(math.abs(nx + 0.5), math.abs(nz + 0.5)) > 3 then 2 else 1
					local gx, gz = if level == 2 then nx // 2 else nx, if level == 2 then nz // 2 else nz
					local key = Coords.nodeKey(level, gx, gz)
					if tops[key] == nil then
						local s = buffer.create(Horizon.SUMMARY_BYTES)
						local w = 4 * bit32.lshift(1, level)
						local ox, oz = gx * SIZE * bit32.lshift(1, level), gz * SIZE * bit32.lshift(1, level)
						for tile = 0, 15 do
							local ground = math.floor(60 + random() * 120 * (round / 2))
							local top = ground + math.floor(random() * 30)
							buffer.writeu16(s, tile * 2, ground)
							buffer.writeu16(s, 32 + tile * 2, top)
							local x0, z0 = ox + (tile % 4) * w, oz + (tile // 4) * w
							table.insert(boxes, { x0, x0 + w, z0, z0 + w, ground })
						end
						tops[key] = s
						add(sc, level, gx, gz, s)
					end
				end
			end
			local ex, ey, ez = 5.5, 150 + round * 10, -3.5
			local raise, spread = 16, 16
			local records = Horizon.pack(sc.keys, sc.summaries)
			local hidden = Horizon.evaluate(records, #sc.keys, ex, ey, ez, { raise = raise, spread = spread })
			for _, key in hidden do
				local level, nx, nz = Coords.decodeNodeKey(key)
				local s = tops[key]
				local w = 4 * bit32.lshift(1, level)
				local ox, oz = nx * SIZE * bit32.lshift(1, level), nz * SIZE * bit32.lshift(1, level)
				for tile = 0, 15 do
					local top = buffer.readu16(s, 32 + tile * 2)
					local x0, z0 = ox + (tile % 4) * w, oz + (tile // 4) * w
					-- Corners and the middle of the tile's top, from each eye.
					for _, p in { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 }, { 0.5, 0.5 } } do
						for _, e in { { 0, 0 }, { spread, 0 }, { -spread, 0 }, { 0, spread }, { 0, -spread } } do
							local px, pz = x0 + p[1] * w, z0 + p[2] * w
							t.ok(
								blocked(boxes, ex + e[1], ey + raise, ez + e[2], px, top, pz),
								`round {round}: hidden node {level},{nx},{nz} tile {tile} is visible`
							)
							checked += 1
						end
					end
				end
			end
		end
		t.ok(checked > 1000, `only {checked} rays checked`)
	end)

	t.test("horizon: estimates for nodes not generated yet, records", function()
		-- From an ancestor: each tile lies in one ancestor tile; its top plus a coarse cell.
		local parent = buffer.create(Horizon.SUMMARY_BYTES)
		for i = 0, 15 do
			buffer.writeu16(parent, i * 2, 50)
			buffer.writeu16(parent, 32 + i * 2, 100 + i)
		end
		local child = Horizon.estimate(1, 1, 0, { { level = 2, nx = 0, nz = 0, summary = parent } })
		-- Child (1, 1, 0) is the +X / -Z quarter of parent (2, 0, 0): parent tiles x 2-3, z 0-1.
		t.eq(Horizon.top(child, 0), 100 + 2 + 4, "child tile 0 in parent tile 2, plus 4 blocks")
		t.eq(Horizon.top(child, 15), 100 + 4 + 3 + 4, "child tile 15 in parent tile 7")
		t.eq(Horizon.ground(child, 0), 0, "estimates never occlude")
		-- From children: the highest of the covered tiles; uncovered tiles stay unknown.
		local kid = buffer.create(Horizon.SUMMARY_BYTES)
		for i = 0, 15 do
			buffer.writeu16(kid, 32 + i * 2, 60 + i)
		end
		local up = Horizon.estimate(2, 0, 0, { { level = 1, nx = 0, nz = 0, summary = kid } })
		t.eq(Horizon.top(up, 0), 60 + 5, "max of child tiles 0, 1, 4, 5")
		t.eq(Horizon.top(up, 3), Horizon.UNKNOWN, "not covered")
		-- Records.
		local records = Horizon.pack({ Coords.nodeKey(3, -2, 5) }, { kid })
		t.eq(buffer.len(records), Horizon.RECORD_BYTES, "one record")
		t.eq(buffer.readf64(records, 0), Coords.nodeKey(3, -2, 5), "key first")
		t.eq(buffer.readu16(records, 8 + 32 + 2), 61, "then the summary")
		-- Spans wrap around and stay under pi.
		local lo, hi = Horizon.span(0, 0, -10, -1, -5, 1)
		t.ok(lo >= 0 and lo < 2 * math.pi and hi > lo and hi - lo < math.pi, "span across the -X axis")
	end)

	--[[ The streamer's side (HiddenTerrain) ]]

	t.test("hidden terrain: once a second while moving, after 8 blocks, one job at a time", function()
		local HiddenTerrain = require(client.Streaming.HiddenTerrain)
		local state = HiddenTerrain.new()
		t.ok(state:due(0, 0, 70, 0, false), "the first one")
		local token = state:sent(0, 0, 70, 0)
		t.ok(not state:due(5, 50, 70, 0, true), "not while one is in flight")
		t.ok(state:received(token, { 11, 12 }, 0.1), "its answer counts")
		t.eq(state.count, 2)
		t.ok(state.hidden[11] and state.hidden[12])
		t.ok(not state:due(0.5, 0, 70, 0, true), "too soon")
		t.ok(not state:due(2, 0, 70, 0, false), "standing still, nothing new")
		t.ok(state:due(2, 0, 70, 0, true), "new summaries, a second later")
		t.ok(state:due(1.1, 3, 70, 0, false), "moving, a second later")
		t.ok(state:due(0.2, 8, 70, 0, false), "8 blocks: at once")
		-- An older answer (a teleport reset in between) is ignored.
		local old = state:sent(1, 8, 70, 0)
		state:reset()
		t.ok(not state:received(old, { 5 }, 1.2), "ignored after a reset")
		t.eq(next(state.hidden), nil)
		t.ok(state:due(1.3, 8, 70, 0, false), "a reset asks again")
		-- A failed job asks again at once.
		local failed = state:sent(2, 8, 70, 0)
		t.ok(not state:received(failed, nil, 2.1))
		t.ok(state:due(2.2, 8, 70, 0, false))
	end)

	t.test("hidden terrain: the camera's speed over the last seconds", function()
		local HiddenTerrain = require(client.Streaming.HiddenTerrain)
		local state = HiddenTerrain.new()
		t.eq(state:speed(), 0, "no samples")
		for i = 0, 20 do
			state:track(i * 0.2, i * 0.2 * 4.3, 0)
		end
		t.ok(math.abs(state:speed() - 4.3) < 1e-6, "walking")
		t.ok(state:speed() <= HiddenTerrain.MAX_SPEED, "walking may give parts back")
		for i = 21, 40 do
			state:track(i * 0.2, 4.3 * 4 + (i - 20) * 0.2 * 10.9, 0)
		end
		t.ok(state:speed() > HiddenTerrain.MAX_SPEED, "flying may not")
		t.ok(#state.samples <= HiddenTerrain.SPEED_WINDOW / 0.2 + 2, "old samples dropped")
		state:reset()
		t.eq(state:speed(), 0, "a teleport forgets")
	end)

	t.test("hidden terrain: a verdict holds within the eyes it was made from", function()
		local HiddenTerrain = require(client.Streaming.HiddenTerrain)
		local state = HiddenTerrain.new()
		t.ok(not state:holds(0, 70, 0), "no verdict yet")
		state:received(state:sent(0, 100, 70, 100), {}, 0.1)
		t.ok(state:holds(100, 70, 100))
		t.ok(state:holds(110, 75, 104), "within the side eyes")
		t.ok(state:holds(100, 20, 100), "any lower (a lower eye sees less over terrain)")
		t.ok(not state:holds(110, 70, 110), "beyond the side eyes (|dx| + |dz| > 16)")
		t.ok(not state:holds(100, 90, 100), "above the raised eye")
	end)

	t.test("hidden terrain: records: own summaries, else estimates from an ancestor or descendants", function()
		local HiddenTerrain = require(client.Streaming.HiddenTerrain)
		local function summary(top: number): buffer
			local b = buffer.create(Horizon.SUMMARY_BYTES)
			for i = 0, 15 do
				buffer.writeu16(b, i * 2, top // 2)
				buffer.writeu16(b, 32 + i * 2, top)
			end
			return b
		end
		local summaries = {
			[Coords.nodeKey(2, 0, 0)] = summary(100), -- ancestor of (1, 1, 0)
			[Coords.nodeKey(1, 4, 4)] = summary(60), -- children of (2, 2, 2): two of four
			[Coords.nodeKey(1, 5, 4)] = summary(70),
			[Coords.nodeKey(0, 40, 40)] = summary(80), -- its own
		}
		local desired = {
			[Coords.nodeKey(1, 1, 0)] = 1,
			[Coords.nodeKey(2, 2, 2)] = 2,
			[Coords.nodeKey(0, 40, 40)] = 0,
			[Coords.nodeKey(3, 9, 9)] = 3, -- nothing known: left out
		}
		local records, count = HiddenTerrain.records(desired, function(key: number): buffer?
			return summaries[key]
		end)
		t.eq(count, 3, "the node nothing is known about is left out")
		local byKey = {}
		for i = 0, count - 1 do
			local key = buffer.readf64(records, i * Horizon.RECORD_BYTES)
			byKey[key] = i * Horizon.RECORD_BYTES + 8
		end
		local own = byKey[Coords.nodeKey(0, 40, 40)]
		t.eq(buffer.readu16(records, own + 32), 80, "its own summary")
		t.eq(buffer.readu16(records, own), 40, "with its ground")
		local fromAncestor = byKey[Coords.nodeKey(1, 1, 0)]
		t.eq(buffer.readu16(records, fromAncestor), 0, "estimates never occlude")
		t.eq(buffer.readu16(records, fromAncestor + 32), 100 + 4, "the ancestor's top, plus its cell")
		local fromChildren = byKey[Coords.nodeKey(2, 2, 2)]
		t.eq(buffer.readu16(records, fromChildren + 32), 60, "a tile the children cover")
		t.eq(buffer.readu16(records, fromChildren + 32 + 2 * 15), Horizon.UNKNOWN, "a tile they don't")
	end)
end
