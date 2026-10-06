--[[
	Glow lichen in generated caves (Generation/CaveDecor): cave twins on walls and ceilings only,
	13+ blocks below the surface, on rock, in patches; full detail only; determinism, and the
	padding argument (a padding cell can't see past the buffer, so it may differ from the
	neighbouring core, which is harmless because cave air and cave twins cull alike: meshing with
	either gives the same boxes); how many per chunk and near a player in a cave; the cost.
]]
return function(t, shared, require)
	local Config = require(shared.Config)
	local Blocks = require(shared.Blocks)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Hash = require(shared.Util.Hash)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)
	local CaveDecor = require(shared.Generation.CaveDecor)
	local Caves = require(shared.Generation.Caves)
	local GreedyMesher = require(shared.Meshing.GreedyMesher)

	local SIZE = ChunkLayout.SIZE
	local P = ChunkLayout.PADDED
	local LAYER = ChunkLayout.LAYER
	local CAVE = Blocks.CAVE_AIR
	local SEED = 12345
	local gen = TerrainGenerator.new(SEED, { structures = false })

	local isTwin: { [number]: boolean } = {}
	local isLichen: { [number]: boolean } = {}
	for id = 0, Blocks.count - 1 do
		isTwin[id] = Blocks.isCaveTwin(id)
		isLichen[id] = string.find(Blocks.get(id).name, "GlowLichen") ~= nil
	end
	local generatedTwins: { [number]: boolean } = {}
	for _, id in CaveDecor.TWINS do
		generatedTwins[id] = true
	end

	local function padded(r: any, px: number, y: number, pz: number): number
		if y < 0 or y >= r.height then
			return Blocks.AIR
		end
		return buffer.readu16(r.data, ChunkLayout.index(px, y, pz) * 2)
	end

	--[[
		Sample chunks with caves (spread over the world, lowlands and mountains), each with its
		east and south neighbours. Generated once.
	]]
	local cache: { [string]: any } = {}
	local function chunk(cx: number, cz: number): any
		local k = `{cx},{cz}`
		local r = cache[k]
		if r == nil then
			r = gen.generate(0, cx, cz)
			cache[k] = r
		end
		return r
	end
	local function caveCells(r: any): number
		local n = 0
		for i = 0, buffer.len(r.data) // 2 - 1 do
			local id = buffer.readu16(r.data, i * 2)
			if id == CAVE or isTwin[id] then
				n += 1
			end
		end
		return n
	end
	local samples: { { number } } = {}
	do
		local rng = Hash.rng(77)
		local tries = 0
		while #samples < 12 and tries < 200 do
			tries += 1
			local cx, cz = rng:int(-3000, 3000), rng:int(-3000, 3000)
			if caveCells(chunk(cx, cz)) > 2000 then
				table.insert(samples, { cx, cz })
			end
		end
	end

	t.test("lichen: cave twins on rock walls and ceilings, 13+ blocks deep", function()
		t.ok(#samples >= 8, `sample chunks with caves: {#samples}`)
		local count, surfaceLichen = 0, 0
		for _, s in samples do
			local r = chunk(s[1], s[2])
			for pz = 0, P - 1 do
				for px = 0, P - 1 do
					local h = gen.column(s[1] * SIZE + px - 1, s[2] * SIZE + pz - 1)
					for y = 0, r.height - 1 do
						local id = padded(r, px, y, pz)
						if isLichen[id] and not isTwin[id] then
							surfaceLichen += 1
						elseif isTwin[id] then
							count += 1
							local where = `{Blocks.get(id).name} at {px},{y},{pz} of chunk {s[1]},{s[2]}`
							t.ok(generatedTwins[id], `{where}: not a wall or ceiling form`)
							t.ok(y <= h - CaveDecor.DEPTH, `{where}: only {h - y} blocks deep`)
							local dx, dy, dz = Blocks.supportOffset(id)
							assert(dx and dy and dz, "twins hang on something")
							local sx, sz = px + dx, pz + dz
							-- (The padding's outward neighbour is outside the buffer.)
							t.ok(sx >= 0 and sx < P and sz >= 0 and sz < P, `{where}: faces outside the buffer`)
							t.ok(CaveDecor.isRock(padded(r, sx, y + dy, sz)), `{where}: not on rock`)
							t.ok(Blocks.isSturdy(padded(r, sx, y + dy, sz)), `{where}: on a block it can't hang on`)
						end
					end
				end
			end
		end
		t.ok(count > 100, `lichen checked: {count}`)
		t.eq(surfaceLichen, 0, "generated lichen that is not a cave twin")
	end)

	t.test("lichen: deterministic, full detail chunks only", function()
		local s = samples[1]
		local again = TerrainGenerator.new(SEED, { structures = false }).generate(0, s[1], s[2])
		t.eq(buffer.tostring(again.data), buffer.tostring(chunk(s[1], s[2]).data), "same seed, same lichen")
		for level = 1, 2 do
			local span = SIZE * 2 ^ level
			local r = gen.generate(level, (s[1] * SIZE) // span, (s[2] * SIZE) // span)
			local found = 0
			for i = 0, buffer.len(r.data) // 2 - 1 do
				if isLichen[buffer.readu16(r.data, i * 2)] then
					found += 1
				end
			end
			t.eq(found, 0, `lichen in a level {level} chunk`)
		end
	end)

	t.test("lichen: padding grows the neighbour's lichen, except facing out of the buffer", function()
		local compared, lichen, differ = 0, 0, 0
		for _, s in samples do
			local a = chunk(s[1], s[2])
			for _, d in { { 1, 0 }, { 0, 1 } } do
				local b = chunk(s[1] + d[1], s[2] + d[2])
				-- Both ways: a's padding against b's core and b's padding against a's core.
				for _, side in { { a, b, d[1], d[2] }, { b, a, -d[1], -d[2] } } do
					local from, to, ox, oz = side[1], side[2], side[3], side[4]
					for pz = 0, P - 1 do
						for px = 0, P - 1 do
							local lx, lz = px - 1 - ox * SIZE, pz - 1 - oz * SIZE
							if lx >= 0 and lx < SIZE and lz >= 0 and lz < SIZE then
								for y = 0, math.min(from.height, to.height) - 1 do
									local mine = padded(from, px, y, pz)
									local theirs = padded(to, lx + 1, y, lz + 1)
									compared += 1
									if isTwin[theirs] then
										lichen += 1
									end
									-- (Ores are only in each chunk's core: stone in the padding.)
									if
										mine ~= theirs and not (mine == Blocks.id.Stone and CaveDecor.isRock(theirs))
									then
										differ += 1
										local where = `{px},{y},{pz} of chunk {s[1]},{s[2]}`
										-- Only lichen against cave air (or another face) ...
										t.ok(mine == CAVE or isTwin[mine], `{where}: {Blocks.get(mine).name}`)
										-- ... where the core's lichen hangs on a block past `from`'s padding.
										local dx, _, dz = Blocks.supportOffset(theirs)
										local ok = isTwin[theirs] and dx ~= nil and dz ~= nil
										if ok then
											local sx, sz = px + (dx :: number), pz + (dz :: number)
											ok = sx < 0 or sx >= P or sz < 0 or sz >= P
										end
										t.ok(ok, `{where}: {Blocks.get(theirs).name} in the core`)
									end
								end
							end
						end
					end
				end
			end
		end
		t.ok(compared > 100000, `cells compared: {compared}`)
		t.ok(lichen > 0, "lichen on the borders compared")
		print(`    {differ} of {lichen} border lichen differ in the neighbour's padding`)
	end)

	t.test("lichen: cave air and twins in the padding mesh alike (both cave modes)", function()
		-- Swap every padding cell of cave air for a twin and every padding twin for cave air: the
		-- core's boxes must not change, with caves hidden or shown.
		local sections, boxes = 0, 0
		for k = 1, 4 do
			local s = samples[k]
			local r = chunk(s[1], s[2])
			local swapped = buffer.create(buffer.len(r.data))
			buffer.copy(swapped, 0, r.data)
			local twin = CaveDecor.TWINS[1]
			local changed = 0
			for y = 0, r.height - 1 do
				for pz = 0, P - 1 do
					for px = 0, P - 1 do
						if px == 0 or pz == 0 or px == P - 1 or pz == P - 1 then
							local i = ChunkLayout.index(px, y, pz) * 2
							local id = buffer.readu16(swapped, i)
							if id == CAVE then
								buffer.writeu16(swapped, i, twin)
								changed += 1
							elseif isTwin[id] then
								buffer.writeu16(swapped, i, CAVE)
								changed += 1
							end
						end
					end
				end
			end
			t.ok(changed > 0, "padding cells swapped")
			local section = Config.SectionHeight
			for y0 = 0, r.height - 1, section do
				local y1 = math.min(y0 + section, r.height)
				local any = false
				for y = y0, y1 - 1 do
					for i = 0, LAYER - 1 do
						local id = buffer.readu16(r.data, (y * LAYER + i) * 2)
						if id == CAVE or isTwin[id] then
							any = true
							break
						end
					end
					if any then
						break
					end
				end
				if any then
					for _, hide in { true, false } do
						local m1, n1 = GreedyMesher.mesh(r.data, r.height, y0, y1, hide)
						local m2, n2 = GreedyMesher.mesh(swapped, r.height, y0, y1, hide)
						t.eq(n2, n1, `boxes of section {y0} (hide {hide})`)
						t.eq(buffer.tostring(m2), buffer.tostring(m1), `section {y0} (hide {hide})`)
						boxes += n1
					end
					sections += 1
				end
			end
		end
		t.ok(sections > 10, `cave sections meshed: {sections}`)
		t.ok(boxes > 0)
	end)

	t.test("lichen: patches on a few percent of the cave walls", function()
		local total, cave, walls, chunks = 0, 0, 0, 0
		local perChunk: { number } = {}
		local clustered = 0
		for _, s in samples do
			local r = chunk(s[1], s[2])
			local cells: { { number } } = {}
			local at: { [string]: boolean } = {}
			for lz = 0, SIZE - 1 do
				for lx = 0, SIZE - 1 do
					local h = gen.column(s[1] * SIZE + lx, s[2] * SIZE + lz)
					for y = 1, r.height - 2 do
						local id = ChunkLayout.get(r.data, lx, y, lz)
						if id == CAVE or isTwin[id] then
							cave += 1
							-- A wall or ceiling cell deep enough: what lichen may cover.
							local function rock(dx: number, dy: number, dz: number): boolean
								return CaveDecor.isRock(ChunkLayout.getPadded(r.data, lx + dx, y + dy, lz + dz))
							end
							if
								y <= h - CaveDecor.DEPTH
								and (
									rock(0, 1, 0)
									or rock(1, 0, 0)
									or rock(-1, 0, 0)
									or rock(0, 0, 1)
									or rock(0, 0, -1)
								)
							then
								walls += 1
							end
						end
						if isTwin[id] then
							table.insert(cells, { lx, y, lz })
							at[`{lx},{y},{lz}`] = true
						end
					end
				end
			end
			-- A lichen with another within 2 blocks (any direction) is part of a patch.
			for _, c in cells do
				local near = false
				for dy = -2, 2 do
					for dz = -2, 2 do
						for dx = -2, 2 do
							if (dx ~= 0 or dy ~= 0 or dz ~= 0) and at[`{c[1] + dx},{c[2] + dy},{c[3] + dz}`] then
								near = true
							end
						end
					end
				end
				if near then
					clustered += 1
				end
			end
			total += #cells
			chunks += 1
			table.insert(perChunk, #cells)
		end
		table.sort(perChunk)
		local share = total / walls
		print(
			string.format(
				"    lichen per cave chunk: mean %.1f, median %d, max %d; %.1f%% of wall and ceiling cells,"
					.. " %.2f per 1000 cave cells; %.0f%% in patches",
				total / chunks,
				perChunk[(chunks + 1) // 2],
				perChunk[chunks],
				share * 100,
				total / cave * 1000,
				clustered / math.max(total, 1) * 100
			)
		)
		-- Dotted, not covered: a few percent of the walls.
		t.ok(share > 0.015 and share < 0.06, `share of wall and ceiling cells with lichen: {share}`)
		t.ok(clustered / total > 0.7, `share of lichen in patches: {clustered / total}`)
	end)

	t.test("lichen: how many glow around a player in a cave", function()
		-- A camera in the middle of the most open cave of the sample chunks.
		local best, camera = -1, nil
		for _, s in samples do
			local r = chunk(s[1], s[2])
			for y = 8, r.height - 8, 4 do
				local open = 0
				for lz = 4, 11, 7 do
					for lx = 4, 11, 7 do
						if ChunkLayout.get(r.data, lx, y, lz) == CAVE then
							open += 1
						end
					end
				end
				if open > best then
					best, camera = open, { s[1] * SIZE + 8, y, s[2] * SIZE + 8 }
				end
			end
		end
		assert(camera, "a cave")
		-- The reveal radius on phones and computers (Config.Caves; in big caverns it grows).
		local mobile = (Config.Caves :: any).Mobile
		local radii = { if mobile then mobile.RevealRadius else 48, Config.Caves.RevealRadius }
		local counts = { 0, 0 }
		-- The renderer lights one lichen per LIGHT_BOX^3 block box (GreedyMesher's sparse lights):
		-- the boxes with lichen within each radius are the PointLights there.
		local box = (GreedyMesher :: any).LIGHT_BOX or 8
		local lit: { { [string]: boolean } } = { {}, {} }
		local litCounts = { 0, 0 }
		local reach = math.max(radii[1], radii[2])
		for cx = (camera[1] - reach) // SIZE, (camera[1] + reach) // SIZE do
			for cz = (camera[3] - reach) // SIZE, (camera[3] + reach) // SIZE do
				local r = chunk(cx, cz)
				for y = math.max(0, camera[2] - reach), math.min(r.height - 1, camera[2] + reach) do
					for lz = 0, SIZE - 1 do
						for lx = 0, SIZE - 1 do
							if isTwin[ChunkLayout.get(r.data, lx, y, lz)] then
								local x, z = cx * SIZE + lx, cz * SIZE + lz
								local dx, dy, dz = x - camera[1], y - camera[2], z - camera[3]
								local d = math.sqrt(dx * dx + dy * dy + dz * dz)
								local k = `{x // box},{y // box},{z // box}`
								for i, radius in radii do
									if d <= radius then
										counts[i] += 1
										if not lit[i][k] then
											lit[i][k] = true
											litCounts[i] += 1
										end
									end
								end
							end
						end
					end
				end
			end
		end
		print(
			string.format(
				"    around a camera in a cave (%d, %d, %d): %d lichen within %d blocks (%d lit), %d within %d (%d lit)",
				camera[1],
				camera[2],
				camera[3],
				counts[1],
				radii[1],
				litCounts[1],
				counts[2],
				radii[2],
				litCounts[2]
			)
		)
		t.ok(counts[2] > 0, "lichen near a cave")
		t.ok(counts[1] < 1500, `lichen within the reveal radius: {counts[1]}`)
		t.ok(litCounts[1] < 400, `lit lichen within the reveal radius: {litCounts[1]}`)
	end)

	t.test("lichen: costs little generation time", function()
		-- Each chunk generated without caves, then carved and decorated as `generate` does (the
		-- carver's own map of carved cells), timing both: the result must be the generated chunk.
		-- (Without surface caves, which `generate` carves in between.)
		local entrances, ravines = Config.Caves.Entrances, Config.Caves.Ravines
		local wereOn = { entrances.Enabled, ravines.Enabled }
		entrances.Enabled, ravines.Enabled = false, false
		local Relief = require(shared.Generation.Relief)
		local relief = Relief.new(SEED)
		local carve = Caves.new(SEED, function(x: number, z: number): number
			return (relief.height(x, z, 0))
		end)
		local decorate = CaveDecor.new(SEED)
		local before = Config.Caves.Enabled
		Config.Caves.Enabled = false
		local flat = TerrainGenerator.new(SEED, { structures = false })
		Config.Caves.Enabled = before
		local carveTime, decorTime, generateTime, placed = 0, 0, 0, 0
		local fresh = TerrainGenerator.new(SEED, { structures = false })
		for k = 1, 8 do
			local s = samples[k]
			local t00 = os.clock()
			local r = fresh.generate(0, s[1], s[2])
			generateTime += os.clock() - t00
			local data = flat.generate(0, s[1], s[2]).data
			t.eq(buffer.len(data), buffer.len(r.data), "same crop")
			local heights = {}
			for pz = 0, P - 1 do
				for px = 0, P - 1 do
					heights[pz * P + px + 1] = (gen.column(s[1] * SIZE + px - 1, s[2] * SIZE + pz - 1))
				end
			end
			local t0 = os.clock()
			local carved = carve(data, s[1] * SIZE, s[2] * SIZE, heights, r.height)
			local t1 = os.clock()
			if carved then
				placed += decorate(data, r.height, s[1] * SIZE, s[2] * SIZE, heights, carved)
			end
			local t2 = os.clock()
			carveTime += t1 - t0
			decorTime += t2 - t1
			t.eq(buffer.tostring(data), buffer.tostring(r.data), "carved and decorated as generated")
		end
		print(
			string.format(
				"    per cave chunk: lichen %.2f ms (%d placed), caves %.2f ms, the whole chunk %.2f ms",
				decorTime / 8 * 1000,
				placed // 8,
				carveTime / 8 * 1000,
				generateTime / 8 * 1000
			)
		)
		-- (This harness runs modules in a custom environment, without Luau's fast builtins, which
		-- slows buffer-heavy code like this most: in a normal VM, as in Roblox, lichen is ~5% of a
		-- chunk with caves.)
		entrances.Enabled, ravines.Enabled = wereOn[1], wereOn[2]
		t.ok(decorTime < 0.2 * generateTime, "lichen costs less than a fifth of generation")
	end)
end
