--[[
	Mineshafts (Generation/Mineshafts): Minecraft's abandoned mineshafts under the local surface,
	overgrown ones in humid biomes and their entrances with a rope all the way down. Plans are
	deterministic (generators, caches, chunk orders); a chunk's padding equals its neighbour's core
	(cave twins as cave air); solidBelow and emptyAbove hold cell by cell; no piece goes below
	MinY, near a lake, puddle, lava lake, oil well or library piece, or opens onto the surface, so
	every lava and water cell stays held in; the lattice hint gives the exact cave graph; hidden
	caves draw nothing of a tunnel; entrances (an Air shaft, a continuous rope hanging from a log
	beam, no trees, in one chunk's core) on about EntranceChance of the overgrown ones; overgrowth
	by humidity; every attached block holds; the off switches; loot; frequency; cost; the debug
	structures world's samples.
]]
return function(t, shared, require)
	local Config = require(shared.Config)
	local Blocks = require(shared.Blocks)
	local Biomes = require(shared.Biomes)
	local Items = require(shared.Items)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local SectionGraph = require(shared.World.SectionGraph)
	local GreedyMesher = require(shared.Meshing.GreedyMesher)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)
	local Mineshafts = require(shared.Generation.Mineshafts)
	local Caves = require(shared.Generation.Caves)
	local Ores = require(shared.Generation.Ores)
	local DebugWorlds = require(shared.Generation.DebugWorlds)

	local SIZE = ChunkLayout.SIZE
	local P = ChunkLayout.PADDED
	local LAYER = ChunkLayout.LAYER
	local SECTION = Config.SectionHeight
	local SEED = 12345
	local B = Blocks.id
	local AIR, CAVE_AIR, STONE = Blocks.AIR, Blocks.CAVE_AIR, B.Stone
	local ROPE, LOG = B.Rope, B.OakLog
	local readu16, readu8 = buffer.readu16, buffer.readu8
	local cfg = Config.Mineshafts
	local SPAWN = { 512, -128 }

	local gen = TerrainGenerator.new(SEED)
	local plain = TerrainGenerator.new(SEED, { structures = false })

	local isFluid: { [number]: boolean } = {}
	local isLava: { [number]: boolean } = {}
	local isWater: { [number]: boolean } = {}
	local isTreePart: { [number]: boolean } = {}
	local isLog: { [number]: boolean } = {}
	for id = 0, Blocks.count - 1 do
		local def = Blocks.get(id)
		isFluid[id] = def.fluid ~= nil
		isLava[id] = def.fluid ~= nil and def.fluid.group == "Lava"
		isWater[id] = def.fluid ~= nil and def.fluid.group == "Water"
		isTreePart[id] = string.find(def.name, "Log") ~= nil or string.find(def.name, "Leaves") ~= nil
		isLog[id] = string.find(def.name, "Log") ~= nil
	end
	-- Ores and stone varieties only in each chunk's own core; twins in the padding ring may differ
	-- from the neighbour's core (they can't see past it), so they count as the cave air they are.
	local rockLike: { [number]: boolean } = { [STONE] = true }
	for _, ore in Ores.FEATURES do
		rockLike[ore.block] = true
	end
	local function norm(id: number): number
		if rockLike[id] then
			return STONE
		elseif Blocks.isCaveTwin(id) and not isFluid[id] then
			return CAVE_AIR
		end
		return id
	end

	-- Chunk caches per generator.
	local caches: { [any]: { [string]: any } } = {}
	local function chunk(g: any, cx: number, cz: number): any
		local cache = caches[g]
		if cache == nil then
			cache = {}
			caches[g] = cache
		end
		local key = `{cx},{cz}`
		local r = cache[key]
		if r == nil then
			r = g.generate(0, cx, cz, nil, true)
			cache[key] = r
		end
		return r
	end
	local function blockAt(g: any, x: number, y: number, z: number): number
		local r = chunk(g, x // SIZE, z // SIZE)
		if y < 0 then
			return B.Bedrock
		elseif y >= r.height then
			return AIR
		end
		return ChunkLayout.get(r.data, x % SIZE, y, z % SIZE)
	end
	local function at(r: any, px: number, y: number, pz: number): number
		if y >= r.height then
			return AIR
		end
		return readu16(r.data, ((y * P + pz) * P + px) * 2)
	end

	-- The plans around the spawn; a normal one and an overgrown one with an entrance, nearest it.
	local AREA = 1600
	local list = gen.mineshafts(SPAWN[1] - AREA, SPAWN[2] - AREA, SPAWN[1] + AREA, SPAWN[2] + AREA)
	local function nearest(want: (any) -> boolean): any
		local best, bestD = nil, math.huge
		for _, plan in list do
			local d = (plan.x - SPAWN[1]) ^ 2 + (plan.z - SPAWN[2]) ^ 2
			if want(plan) and d < bestD then
				best, bestD = plan, d
			end
		end
		return best
	end
	local normal = nearest(function(plan)
		return not plan.overgrown
	end)
	local grown = nearest(function(plan)
		return plan.overgrown and plan.entrance ~= nil
	end)
	assert(normal and grown, "a normal and an overgrown mineshaft near the spawn")

	-- The chunks a plan's bounds reach.
	local function chunksOf(plan: any): { { number } }
		local b = plan.bounds
		local out = {}
		for cz = b[3] // SIZE, b[6] // SIZE do
			for cx = b[1] // SIZE, b[4] // SIZE do
				table.insert(out, { cx, cz })
			end
		end
		return out
	end
	local both = {}
	for _, c in chunksOf(normal) do
		table.insert(both, c)
	end
	for _, c in chunksOf(grown) do
		table.insert(both, c)
	end

	-- The cave visibility graph a worker builds (lattice hint, dug sections read cell by cell)
	-- against reading every cell, and every section with cave cells or air below the sky line
	-- listed (as tests/spec/LavaGeneration). Returns the sections compared.
	local function graphsAgree(cx: number, cz: number): number
		local r = chunk(gen, cx, cz)
		local exact: { [number]: boolean } = {}
		if r.structureSpan then
			for s = r.structureSpan[1] // SECTION, r.structureSpan[2] // SECTION do
				exact[s] = true
			end
		end
		SectionGraph.dugSections(r.data, r.height, r.surface, r.solidBelow, exact)
		local extra = {}
		for s in exact do
			table.insert(extra, s)
		end
		local sections = SectionGraph.carvedSections(r.carved, Caves.CELL_Y, extra)
		local hint: SectionGraph.Hint = {
			carved = r.carved,
			cellXZ = Caves.CELL_XZ,
			cellY = Caves.CELL_Y,
			originX = cx * SIZE,
			originZ = cz * SIZE,
			surface = r.surface,
			exact = exact,
		}
		local fast = SectionGraph.build(r.data, r.height, r.solidBelow, sections, hint, nil, r.surface)
		local slow = SectionGraph.build(r.data, r.height, r.solidBelow, sections, nil, nil, r.surface)
		local listed: { [number]: boolean } = {}
		for _, s in sections do
			listed[s] = true
		end
		for s = 0, SectionGraph.SECTIONS - 1 do
			t.eq(SectionGraph.get(fast, s), SectionGraph.get(slow, s), `chunk {cx},{cz} section {s}`)
			if not listed[s] and s * SECTION < r.height then
				local cave, _, _, _, under = SectionGraph.masks(r.data, r.height, s, r.surface)
				t.eq(cave, 0, `chunk {cx},{cz}: cave cells in section {s} left out`)
				t.eq(under, 0, `chunk {cx},{cz}: air below the sky line in section {s} left out`)
			end
		end
		return #sections
	end

	--[[ Plans ]]

	t.test("mineshafts: Minecraft's pieces, deterministic across generators, caches and chunk orders", function()
		local kinds: { [string]: number } = {}
		for _, plan in list do
			t.eq(plan.pieces[1].kind, "room", "the start room first")
			local room = plan.pieces[1].box
			t.ok(room[4] - room[1] + 1 >= 8 and room[4] - room[1] + 1 <= 13, "room 8..13 wide")
			t.ok(room[5] - room[2] + 1 >= 5 and room[5] - room[2] + 1 <= 10, "room 5..10 tall")
			for i, piece in plan.pieces do
				kinds[piece.kind] = (kinds[piece.kind] or 0) + 1
				t.ok(piece.depth <= cfg.MaxDepth + 1, "depth")
				local b = piece.box
				if piece.kind == "corridor" then
					local along = math.max(b[4] - b[1], b[6] - b[3]) + 1
					t.eq(along, piece.sections * Mineshafts.SECTION, "5 n long")
					t.ok(piece.sections >= 1 and piece.sections <= 4, "1..4 sections")
					t.eq(b[5] - b[2], 2, "3 tall")
				elseif piece.kind == "crossing" then
					t.ok(b[5] - b[2] == 2 or b[5] - b[2] == 6, "3 or 7 tall")
				end
				-- No overlap within a mineshaft.
				for j = i + 1, #plan.pieces do
					local o = plan.pieces[j].box
					local overlap = b[1] <= o[4]
						and b[4] >= o[1]
						and b[2] <= o[5]
						and b[5] >= o[2]
						and b[3] <= o[6]
						and b[6] >= o[3]
					t.ok(not overlap, "pieces overlap")
				end
			end
		end
		local total = (kinds.corridor or 0) + (kinds.crossing or 0) + (kinds.stairs or 0)
		print(
			`    {#list} mineshafts: {kinds.room} rooms, {kinds.corridor} corridors, {kinds.crossing} crossings, {kinds.stairs} stairs`
		)
		-- Minecraft's 70 / 20 / 10 by draw; crossings have more children, refusals cut corridors.
		t.ok((kinds.corridor or 0) / total > 0.6, "mostly corridors")

		-- Another generator, asked from the other side first, plans alike.
		local other = TerrainGenerator.new(SEED)
		local b = grown.bounds
		other.mineshafts(b[4], b[6], b[4] + 300, b[6] + 300)
		local again = other.mineshafts(b[1], b[3], b[4], b[6])
		local found = nil
		for _, plan in again do
			if plan.x == grown.x and plan.z == grown.z then
				found = plan
			end
		end
		t.ok(found ~= nil, "the same plan")
		if found then
			t.eq(#found.pieces, #grown.pieces, "pieces")
			for i, piece in grown.pieces do
				t.eq(table.concat(found.pieces[i].box, " "), table.concat(piece.box, " "), `piece {i}`)
				t.eq(found.pieces[i].salt, piece.salt)
			end
			t.eq(found.entrance and found.entrance.x, grown.entrance.x, "entrance")
			t.eq(found.entrance and found.entrance.top, grown.entrance.top)
		end
		-- Chunk bytes: a cold generator asked for the chunk alone, and one that made its neighbours
		-- first, in reverse order.
		local e = grown.entrance
		for _, c in { { e.x // SIZE, e.z // SIZE }, { grown.x // SIZE, grown.z // SIZE } } do
			local cold = TerrainGenerator.new(SEED).generate(0, c[1], c[2])
			local warm = TerrainGenerator.new(SEED)
			for dz = 1, -1, -1 do
				for dx = 1, -1, -1 do
					warm.generate(0, c[1] + dx, c[2] + dz)
				end
			end
			local w = warm.generate(0, c[1], c[2])
			local r = chunk(gen, c[1], c[2])
			t.eq(buffer.tostring(cold.data), buffer.tostring(r.data), "cold cache")
			t.eq(buffer.tostring(w.data), buffer.tostring(r.data), "another order")
			t.eq(cold.solidBelow, r.solidBelow)
			t.eq(w.emptyAbove, r.emptyAbove)
		end
	end)

	t.test("mineshafts: padding equals the neighbours' cores; solidBelow and emptyAbove hold", function()
		local mismatches, compared = 0, 0
		local cull = Blocks.cullLutHiddenCaves
		for _, c in both do
			local a = chunk(gen, c[1], c[2])
			local east = chunk(gen, c[1] + 1, c[2])
			local south = chunk(gen, c[1], c[2] + 1)
			for y = 0, math.max(a.height, east.height, south.height) - 1 do
				for i = 1, SIZE do
					if norm(at(a, P - 1, y, i)) ~= norm(at(east, 1, y, i)) then
						mismatches += 1
					end
					if norm(at(east, 0, y, i)) ~= norm(at(a, SIZE, y, i)) then
						mismatches += 1
					end
					if norm(at(a, i, y, P - 1)) ~= norm(at(south, i, y, 1)) then
						mismatches += 1
					end
					if norm(at(south, i, y, 0)) ~= norm(at(a, i, y, SIZE)) then
						mismatches += 1
					end
					compared += 4
				end
			end
			for y = 0, a.height - 1 do
				for i = 0, LAYER - 1 do
					local id = readu16(a.data, (y * LAYER + i) * 2)
					if y < a.solidBelow and readu8(cull, id) == 0 then
						error(`chunk {c[1]},{c[2]}: open cell {id} at y {y} below solidBelow {a.solidBelow}`)
					end
					if y >= a.emptyAbove and id ~= AIR then
						error(`chunk {c[1]},{c[2]}: block {id} at y {y} above emptyAbove {a.emptyAbove}`)
					end
				end
			end
		end
		t.eq(mismatches, 0, `border cells that disagree (of {compared})`)
	end)

	t.test("mineshafts: above MinY, under Cover, away from lakes, wells, lava lakes, puddles and pieces", function()
		local margin = Mineshafts.MARGIN
		local checked = 0
		for k, plan in list do
			if k > 24 then
				break
			end
			for _, piece in plan.pieces do
				local b = piece.box
				t.ok(b[2] - 1 >= cfg.MinY, "above MinY")
				local x0, z0, x1, z1 = b[1] - margin, b[3] - margin, b[4] + margin, b[6] + margin
				t.eq(#gen.waterLakes(x0, z0, x1, z1), 0, "no water lake")
				t.eq(#gen.lavaLakes(x0, z0, x1, z1), 0, "no lava lake")
				t.eq(#gen.puddles(x0, z0, x1, z1), 0, "no puddle")
				t.eq(#gen.oilWells(x0, z0, x1, z1), 0, "no oil well")
				for _, start in gen.structures(x0, z0, x1, z1) do
					for _, p in start.pieces do
						local o = p.box
						t.ok(not (o[1] <= x1 and o[4] >= x0 and o[3] <= z1 and o[6] >= z0), "no library piece")
					end
				end
				checked += 1
			end
		end
		t.ok(checked > 500, `pieces checked: {checked}`)
		-- In the chunks: what the mineshafts opened (rock become cave air or a decoration inside a
		-- piece; an underground lava lake moved by them aside) keeps GUARD blocks of ground over it
		-- and beside it (the entrance's shaft aside), no decoration lies below MinY (log pillars
		-- may), and every lava and water cell stays held in beside and below.
		local e = grown.entrance
		local decor: { [number]: boolean } = {}
		for id = 0, Blocks.count - 1 do
			local name = Blocks.get(Blocks.caveTwinOf(id) or id).name
			for _, part in { "Rail", "OakFence", "Cobweb", "WallTorch", "MossCarpet", "Vine", "HangingRoots", "Rope" } do
				if string.find(name, part, 1, true) then
					decor[id] = true
				end
			end
		end
		local opened, leaks = 0, 0
		for _, c in both do
			local r = chunk(gen, c[1], c[2])
			local p = chunk(plain, c[1], c[2])
			local x0, z0 = c[1] * SIZE, c[2] * SIZE
			local near: { { number } } = {}
			for _, plan in { normal, grown } do
				for _, piece in plan.pieces do
					local o = piece.outer
					if o[1] <= x0 + 15 and o[4] >= x0 and o[3] <= z0 + 15 and o[6] >= z0 then
						table.insert(near, o)
					end
				end
			end
			local function inPiece(x: number, y: number, z: number): boolean
				for _, o in near do
					if x >= o[1] and x <= o[4] and y >= o[2] and y <= o[5] and z >= o[3] and z <= o[6] then
						return true
					end
				end
				return false
			end
			for y = 1, math.min(r.height, p.height) - 1 do
				for lz = 0, SIZE - 1 do
					for lx = 0, SIZE - 1 do
						local id = ChunkLayout.get(r.data, lx, y, lz)
						local before = ChunkLayout.get(p.data, lx, y, lz)
						local x, z = x0 + lx, z0 + lz
						if decor[id] then
							t.ok(y >= cfg.MinY, `a mineshaft decoration below MinY at {x} {y} {z}`)
						end
						if
							id ~= before
							and not Blocks.isOpaque(id)
							and Blocks.isOpaque(before)
							and inPiece(x, y, z)
						then
							local inShaft = math.abs(x - e.x) <= 2 and math.abs(z - e.z) <= 2
							t.ok(y >= cfg.MinY, `opened below MinY at {x} {y} {z}`)
							if not inShaft then
								opened += 1
								local h = gen.column(x, z)
								local low = math.min(
									h - 1,
									(gen.column(x - 1, z)),
									(gen.column(x + 1, z)),
									(gen.column(x, z - 1)),
									(gen.column(x, z + 1))
								)
								t.ok(y <= low - 1 - Mineshafts.GUARD, `opened at {x} {y} {z} near the surface`)
							end
						end
						if isLava[id] or isWater[id] then
							for _, d in { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 }, { 0, -1, 0 } } do
								local n = ChunkLayout.getPadded(r.data, lx + d[1], y + d[2], lz + d[3])
								if not Blocks.isOpaque(n) and not isFluid[n] then
									leaks += 1
								end
							end
						end
					end
				end
			end
		end
		t.ok(opened > 1000, `cells the mineshafts opened: {opened}`)
		t.eq(leaks, 0, "lava and water cells with an open side or bottom")
	end)

	--[[ Caves hidden ]]

	t.test("mineshafts: the lattice hint gives the exact cave graph, every cave cell listed", function()
		local sections = 0
		for k, c in both do
			if k % 3 == 0 then
				sections += graphsAgree(c[1], c[2])
			end
		end
		local e = grown.entrance
		sections += graphsAgree(e.x // SIZE, e.z // SIZE)
		t.ok(sections > 50, `sections compared: {sections}`)
	end)

	t.test("mineshafts: hidden caves draw nothing of a tunnel (the same boxes as without it)", function()
		local cull = Blocks.cullLutHiddenCaves
		local same, skipped, boxes = 0, 0, 0
		local sections: { { number } } = {}
		for _, plan in { normal, grown } do
			local b = plan.bounds
			for _, c in chunksOf(plan) do
				for y0 = (b[2] // SECTION) * SECTION, b[5], SECTION do
					table.insert(sections, { c[1], c[2], y0 })
				end
			end
		end
		for _, section in sections do
			local c, y0 = section, section[3]
			local r = chunk(gen, c[1], c[2])
			local p = chunk(plain, c[1], c[2])
			if #gen.structures(c[1] * SIZE, c[2] * SIZE, c[1] * SIZE + 15, c[2] * SIZE + 15) > 0 then
				continue
			end
			do
				-- Sections where the mineshaft wrote something visible (into a surface cave's air)
				-- or the two differ above the ground (trees) are skipped.
				local visible = false
				for y = math.max(y0 - 1, 0), math.min(y0 + SECTION, r.height - 1, p.height - 1) do
					for i = 0, LAYER - 1 do
						local o = (y * LAYER + i) * 2
						local a, q = readu16(r.data, o), readu16(p.data, o)
						if a ~= q and (readu8(cull, a) == 0 or readu8(cull, q) == 0) then
							visible = true
							break
						end
					end
					if visible then
						break
					end
				end
				if visible or y0 + SECTION > math.min(r.height, p.height) then
					skipped += 1
					continue
				end
				local m1, n1 = GreedyMesher.mesh(r.data, r.height, y0, y0 + SECTION, true)
				local m2, n2 = GreedyMesher.mesh(p.data, p.height, y0, y0 + SECTION, true)
				t.eq(n1, n2, `chunk {c[1]},{c[2]} section {y0}: boxes`)
				t.eq(buffer.tostring(m1), buffer.tostring(m2), `chunk {c[1]},{c[2]} section {y0}: the same boxes`)
				same += 1
				boxes += n1
			end
		end
		print(`    {same} sections through a mineshaft drawn as without it ({boxes} boxes), {skipped} skipped`)
		t.ok(same > 50, "sections compared")
	end)

	--[[ Entrances ]]

	t.test("entrances: an Air shaft to the floor, a rope hanging all the way down from a log beam", function()
		local checked = 0
		for _, plan in list do
			local e = plan.entrance
			if e == nil then
				continue
			end
			checked += 1
			t.ok(plan.overgrown, "only overgrown mineshafts")
			-- Every opening column in one chunk's core, off its outer columns.
			for d = -1, 1 do
				t.ok((e.x + d) % SIZE >= 2 and (e.x + d) % SIZE <= 13, "x in the core")
				t.ok((e.z + d) % SIZE >= 2 and (e.z + d) % SIZE <= 13, "z in the core")
			end
			t.ok(e.top - e.bottom >= cfg.Cover, "a shaft down to a piece")
			local function get(x: number, y: number, z: number): number?
				return blockAt(gen, x, y, z)
			end
			-- The rope: continuous from under the beam to the floor, each one held.
			for y = e.bottom, e.top + 1 do
				t.eq(blockAt(gen, e.x, y, e.z), ROPE, `rope at {e.x} {y} {e.z}`)
				t.ok(Blocks.canSurvive(ROPE, get, e.x, y, e.z), "the rope holds")
			end
			t.ok(Blocks.isSturdy(blockAt(gen, e.x, e.bottom - 1, e.z)), "the rope's end above a floor")
			t.eq(blockAt(gen, e.x, e.top + 2, e.z), LOG, "the beam")
			t.ok(Blocks.isSturdy(LOG), "a sturdy beam")
			-- The opening: open from the floor to the sky (ropes and vines aside).
			for dz = -1, 1 do
				for dx = -1, 1 do
					for y = e.bottom, e.top + 1 do
						local id = blockAt(gen, e.x + dx, y, e.z + dz)
						local name = Blocks.get(id).name
						t.ok(
							id == AIR or id == ROPE or string.find(name, "Vine") ~= nil,
							`open at {e.x + dx} {y} {e.z + dz}: {name}`
						)
						t.ok(not Blocks.isCaveTwin(id), "no cave twins in the open")
					end
				end
			end
			-- The collar.
			for dz = -2, 2 do
				for dx = -2, 2 do
					if math.max(math.abs(dx), math.abs(dz)) == 2 then
						t.eq(blockAt(gen, e.x + dx, e.top - 1, e.z + dz), B.MossyCobblestone, "the collar")
					end
				end
			end
			-- No tree grows in its box at levels 0..2 (no trunk on its ground; a crown from outside may
			-- reach in), and none overhangs the collar.
			local box = e.box
			for x = box[1], box[3] do
				for z = box[2], box[4] do
					local collar = math.abs(x - e.x) <= 2 and math.abs(z - e.z) <= 2
					for y = e.top - 1, e.top + (if collar then 24 else 1) do
						local id = blockAt(gen, x, y, z)
						if (collar and isTreePart[id] or isLog[id]) and not (id == LOG and y == e.top + 2) then
							t.ok(false, `a tree at {x} {y} {z} by an entrance`)
						end
					end
				end
			end
			for level = 1, Config.StructureMaxLevel do
				local step = ChunkLayout.steps(level)
				local span = SIZE * step
				for nz = box[2] // span, box[4] // span do
					for nx = box[1] // span, box[3] // span do
						local r = gen.generate(level, nx, nz)
						for pz = 1, SIZE do
							for px = 1, SIZE do
								local x = nx * span + (px - 1) * step + step // 2
								local z = nz * span + (pz - 1) * step + step // 2
								if math.abs(x - e.x) <= 2 and math.abs(z - e.z) <= 2 then
									for y = 0, r.height - 1 do
										t.ok(not isTreePart[at(r, px, y, pz)], `L{level}: a tree by an entrance`)
									end
								end
							end
						end
					end
				end
			end
			if checked >= 4 then
				break
			end
		end
		t.ok(checked >= 2, `entrances checked: {checked}`)
	end)

	--[[ Overgrowth, attached blocks ]]

	t.test("overgrown: moss, carpets, vines and roots in humid biomes only; every attached block holds", function()
		for _, plan in list do
			local room = plan.pieces[1].box
			local cx, cz = plan.x + (room[4] - room[1]) // 2, plan.z + (room[6] - room[3]) // 2
			local _, b = gen.column(cx, cz)
			local humidity = Biomes.list[b].humidity
			if humidity <= cfg.OvergrownHumidity[1] then
				t.ok(not plan.overgrown, `overgrown in a dry biome ({Biomes.list[b].name})`)
			end
			if plan.overgrown then
				t.eq(plan.webs, 0.3, "fewer cobwebs")
				for _, piece in plan.pieces do
					t.ok(not piece.spider, "no spider corridors")
				end
			end
		end
		local function count(plan: any): { [string]: number }
			local n: { [string]: number } = {}
			for _, c in chunksOf(plan) do
				local r = chunk(gen, c[1], c[2])
				for y = 1, r.height - 1 do
					for lz = 0, SIZE - 1 do
						for lx = 0, SIZE - 1 do
							local id = ChunkLayout.get(r.data, lx, y, lz)
							local name = Blocks.get(Blocks.caveTwinOf(id) or id).name
							if string.find(name, "Vine") then
								name = "Vine"
							elseif string.find(name, "WallTorch") then
								name = "WallTorch"
							elseif name == "RailEastWest" then
								name = "Rail"
							end
							n[name] = (n[name] or 0) + 1
						end
					end
				end
			end
			return n
		end
		local a, g = count(normal), count(grown)
		for _, name in { "MossBlock", "MossCarpet", "Vine", "HangingRoots" } do
			t.eq(a[name] or 0, 0, `no {name} in a normal mineshaft`)
			t.ok((g[name] or 0) > 0, `{name} in an overgrown one`)
		end
		for _, name in { "Planks", "OakFence" } do
			t.ok((a[name] or 0) > 0 and (g[name] or 0) > 0, `{name} in both`)
		end
		print(
			`    normal: {a.Planks} planks, {a.OakFence or 0} posts, {a.Rail or 0} rails, {a.Cobweb or 0} cobwebs, {a.WallTorch or 0} torches, {a.Chest or 0} chests`
		)
		print(
			`    overgrown: {g.MossBlock} moss, {g.MossCarpet} carpets, {g.Vine} vines, {g.HangingRoots} roots, {g.Cobweb or 0} cobwebs`
		)

		-- Every attached block in the chunks' cores holds (canSurvive with the world's blocks).
		local function get(x: number, y: number, z: number): number?
			return blockAt(gen, x, y, z)
		end
		local attached, falling = 0, 0
		for _, c in both do
			local r = chunk(gen, c[1], c[2])
			for y = 1, r.height - 2 do
				for lz = 0, SIZE - 1 do
					for lx = 0, SIZE - 1 do
						local id = ChunkLayout.get(r.data, lx, y, lz)
						if Blocks.supportOffset(id) ~= nil then
							attached += 1
							if not Blocks.canSurvive(id, get, c[1] * SIZE + lx, y, c[2] * SIZE + lz) then
								falling += 1
								print(
									`      {Blocks.get(id).name} without support at {c[1] * SIZE + lx} {y} {c[2] * SIZE + lz}`
								)
							end
						end
					end
				end
			end
		end
		t.ok(attached > 200, `attached blocks checked: {attached}`)
		t.eq(falling, 0, "attached blocks without their support")
	end)

	--[[ Off switches ]]

	t.test("mineshafts: none with structures off, Generate Structures off or Mineshafts.Enabled off", function()
		t.eq(#plain.mineshafts(-3000, -3000, 3000, 3000), 0, "structures = false")
		local c = { normal.x // SIZE, normal.z // SIZE }
		local p = chunk(plain, c[1], c[2])
		t.eq(
			#gen.structures(c[1] * SIZE - 32, c[2] * SIZE - 32, c[1] * SIZE + 48, c[2] * SIZE + 48),
			0,
			"no outpost there"
		)
		t.ok(buffer.tostring(chunk(gen, c[1], c[2]).data) ~= buffer.tostring(p.data), "the mineshaft is there")
		local function without(set: () -> (), reset: () -> ())
			set()
			local off = TerrainGenerator.new(SEED)
			reset()
			t.eq(#off.mineshafts(-3000, -3000, 3000, 3000), 0, "no mineshafts")
			t.eq(buffer.tostring(off.generate(0, c[1], c[2]).data), buffer.tostring(p.data), "plain terrain")
		end
		local generate = Config.Structures.Generate
		without(function()
			Config.Structures.Generate = false
		end, function()
			Config.Structures.Generate = generate
		end)
		without(function()
			Config.Mineshafts.Enabled = false
		end, function()
			Config.Mineshafts.Enabled = true
		end)
	end)

	--[[ Loot ]]

	t.test("loot: a fresh table per chest, deterministic, only items that exist, only where chests are", function()
		local chests, found, items = 0, 0, 0
		local fresh = TerrainGenerator.new(SEED)
		for _, plan in { normal, grown } do
			for _, piece in plan.pieces do
				local list3 = piece.chests
				for i = 1, #list3, 3 do
					local x, y, z = list3[i], list3[i + 1], list3[i + 2]
					chests += 1
					local a = gen.structureContainer(x, y, z)
					t.ok(a ~= nil, "a chest's items")
					if a then
						t.ok(gen.structureContainer(x, y, z) ~= a, "a fresh table")
						local b = fresh.structureContainer(x, y, z) :: any
						t.eq(#b, #a, "a cold generator answers alike")
						local slots: { [number]: boolean } = {}
						for k, item in a do
							t.eq(b[k].item, item.item)
							t.eq(b[k].count, item.count)
							t.eq(b[k].slot, item.slot)
							local id = Items.find(item.item)
							t.ok(id ~= nil, `{item.item} exists`)
							t.ok(item.count >= 1 and item.count <= Items.maxStack(id :: number), "a stack")
							t.ok(
								item.slot >= 1 and item.slot <= Mineshafts.SLOTS and not slots[item.slot],
								"a free slot"
							)
							slots[item.slot] = true
							items += 1
						end
					end
					t.eq(gen.structureContainer(x, y + 1, z), nil, "nothing above it")
					if blockAt(gen, x, y, z) == B.Chest then
						found += 1
					end
				end
			end
		end
		print(`    {chests} chest spots, {found} chests on a floor, {items} stacks`)
		t.ok(chests > 0 and found > 0, "chests in the world")
		-- Every entry of the table is an item.
		for _, pool in Mineshafts.LOOT do
			for _, entry in pool.entries do
				t.ok(entry[1] == false or Items.find(entry[1]) ~= nil, `loot item {entry[1]}`)
			end
		end
		-- The pools' share over many chests: an iron pickaxe in about 5 / 71.
		local picks = 0
		for i = 1, 2000 do
			for _, item in Mineshafts.loot(7, i, 40, -i) do
				if item.item == "IronPickaxe" then
					picks += 1
				end
			end
		end
		t.ok(picks > 2000 * 5 / 71 * 0.6 and picks < 2000 * 5 / 71 * 1.4, `iron pickaxes: {picks}`)
	end)

	--[[ Frequency, cost ]]

	t.test("mineshafts: about 15 per km², overgrown by humidity, about EntranceChance with an entrance", function()
		local R = 3000
		local fresh = TerrainGenerator.new(SEED)
		local all = fresh.mineshafts(-R, -R, R - 1, R - 1)
		local count = 0
		local overgrown, entrances = 0, 0
		local wet, wetOvergrown = 0, 0
		for _, plan in all do
			if plan.x >= -R and plan.x < R and plan.z >= -R and plan.z < R then
				count += 1
				if plan.overgrown then
					overgrown += 1
					if plan.entrance then
						entrances += 1
					end
				end
				local room = plan.pieces[1].box
				local _, b = fresh.column((room[1] + room[4]) // 2, (room[3] + room[6]) // 2)
				if Biomes.list[b].humidity >= cfg.OvergrownHumidity[2] then
					wet += 1
					if plan.overgrown then
						wetOvergrown += 1
					end
				end
			end
		end
		local perKm2 = count / (2 * R / 1000) ^ 2
		print(
			`    {count} mineshafts in {(2 * R / 1000) ^ 2} km²: {string.format("%.1f", perKm2)} per km², {overgrown} overgrown, {entrances} with an entrance; {wetOvergrown} of {wet} in the wettest biomes overgrown`
		)
		t.ok(perKm2 > 7.5 and perKm2 < 22.5, "about 15 per km²")
		t.ok(overgrown > 0, "some overgrown")
		local share = entrances / overgrown
		t.ok(share > cfg.EntranceChance - 0.2 and share < cfg.EntranceChance + 0.1, `entrance share {share}`)
		if wet >= 10 then
			t.ok(wetOvergrown / wet > cfg.OvergrownChance - 0.3, "the wettest biomes mostly overgrown")
		end
	end)

	t.test("mineshafts: cost (plans, full detail chunks, far nodes)", function()
		-- Plans, built by a fresh generator (its lakes and puddles worked out too): a lookup at a
		-- plan's room builds every plan that may reach it (one or two).
		local fresh = TerrainGenerator.new(SEED)
		local times: { number } = {}
		for k, plan in list do
			if k > 30 then
				break
			end
			local s = os.clock()
			fresh.mineshafts(plan.x, plan.z, plan.x, plan.z)
			table.insert(times, (os.clock() - s) * 1000)
		end
		table.sort(times)
		local median, worst = times[#times // 2 + 1], times[#times]
		print(
			string.format(
				"    plan lookups (building the plans in reach): median %.2f ms, worst %.2f ms",
				median,
				worst
			)
		)
		t.ok(median < 5, "a plan in under 5 ms (median)")
		t.ok(worst < 30, "two plans in under 30 ms")
		-- Two fresh generators, the same world with and without mineshafts (library structures
		-- and the rest alike).
		local both = TerrainGenerator.new(SEED)
		Config.Mineshafts.Enabled = false
		local none = TerrainGenerator.new(SEED)
		Config.Mineshafts.Enabled = true
		-- Full detail chunks around the overgrown mineshaft, and far nodes (levels 1 and 2: they
		-- only ask for entrances' squares) over it, with and without: the best of 5 rounds, the
		-- two generators in turn, each first every other round (a busy machine slows both alike;
		-- far nodes only add an entrance lookup, so their bound is the noise of the machine).
		local list2 = chunksOf(grown)
		local function near(g: any): number
			local s = os.clock()
			for _, c in list2 do
				g.generate(0, c[1], c[2])
			end
			return (os.clock() - s) / #list2
		end
		local function far(g: any): number
			local s = os.clock()
			for level = 1, 2 do
				local span = SIZE * 2 ^ level
				local b = grown.bounds
				for nz = b[3] // span, b[6] // span do
					for nx = b[1] // span, b[4] // span do
						g.generate(level, nx, nz)
					end
				end
			end
			return os.clock() - s
		end
		local with, without, fw, fp = math.huge, math.huge, math.huge, math.huge
		for round = 1, 6 do
			local a, b = both, none
			if round % 2 == 0 then
				a, b = none, both
			end
			local na, nb = near(a), near(b)
			local fa, fb = far(a), far(b)
			if a == none then
				na, nb, fa, fb = nb, na, fb, fa
			end
			with, without = math.min(with, na), math.min(without, nb)
			fw, fp = math.min(fw, fa), math.min(fp, fb)
		end
		print(
			string.format(
				"    %d chunks: %.2f ms with mineshafts, %.2f ms without",
				#list2,
				with * 1000,
				without * 1000
			)
		)
		t.ok(with < without * 1.3 + 0.003, "full detail chunks")
		print(string.format("    far nodes: %.2f ms with, %.2f ms without", fw * 1000, fp * 1000))
		t.ok(fw < fp * 1.2 + 0.005, "far nodes")
	end)

	--[[ The debug structures world ]]

	t.test("debug structures: the two sample mineshafts, the overgrown one's rope to the floor", function()
		local world = DebugWorlds.allStructures(SEED)
		local samples = (world :: any).mineshafts(-100000, -100000, 100000, 100000)
		t.eq(#samples, 2, "two samples")
		local entries = DebugWorlds.structureLayout(SEED, require(shared.Structures.Library).load())
		local names = {}
		for _, e in entries do
			if e.mineshaft then
				table.insert(names, e.name)
			end
		end
		t.eq(table.concat(names, ", "), "mineshaft, mineshaft/overgrown")
		for k, plan in samples do
			local kinds: { [string]: boolean } = {}
			for _, piece in plan.pieces do
				kinds[piece.kind] = true
			end
			t.ok(kinds.room and kinds.corridor and kinds.crossing and kinds.stairs, "every kind of piece")
			local n: { [string]: number } = {}
			local b = plan.bounds
			for cz = b[3] // SIZE, b[6] // SIZE do
				for cx = b[1] // SIZE, b[4] // SIZE do
					local r = world.generate(0, cx, cz)
					for y = 1, r.height - 1 do
						for lz = 0, SIZE - 1 do
							for lx = 0, SIZE - 1 do
								local id = ChunkLayout.get(r.data, lx, y, lz)
								local name = Blocks.get(Blocks.caveTwinOf(id) or id).name
								n[name] = (n[name] or 0) + 1
							end
						end
					end
				end
			end
			for _, name in { "Planks", "OakFence", "Cobweb", "Chest", "WallTorchNorth" } do
				local total = n[name] or 0
				if name == "WallTorchNorth" then
					total = (n.WallTorchNorth or 0)
						+ (n.WallTorchSouth or 0)
						+ (n.WallTorchWest or 0)
						+ (n.WallTorchEast or 0)
				end
				t.ok(total > 0, `sample {k}: {name}`)
			end
			t.ok((n.Rail or 0) + (n.RailEastWest or 0) > 0, `sample {k}: rails`)
			local chest = plan.pieces[2].chests
			t.ok(world.structureContainer(chest[1], chest[2], chest[3]) ~= nil, "the chest's loot")
			if plan.overgrown then
				local e = plan.entrance
				t.ok(e ~= nil, "the overgrown one's entrance")
				if e then
					t.eq(e.top, DebugWorlds.FLOOR)
					local r = world.generate(0, e.x // SIZE, e.z // SIZE)
					for y = e.bottom, e.top + 1 do
						t.eq(ChunkLayout.get(r.data, e.x % SIZE, y, e.z % SIZE), ROPE, `the rope at y {y}`)
					end
					t.eq(ChunkLayout.get(r.data, e.x % SIZE, e.top + 2, e.z % SIZE), LOG, "the beam")
					t.ok((n.MossBlock or 0) > 0, "moss")
				end
			end
		end
	end)
end
