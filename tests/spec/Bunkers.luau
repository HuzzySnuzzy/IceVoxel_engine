--[[
	Bunkers (Generation/Bunkers): the zombie apocalypse's hidden hideouts. Plans are deterministic
	(generators, caches, chunk orders, yields or none); a chunk's padding equals its neighbour's
	core (cave twins as cave air); solidBelow and emptyAbove hold cell by cell; the layout's rules
	(an airlock under the shaft, a corridor, exactly one bunk room and one storeroom among 3-6
	rooms, the shell, cave air inside, every room within REACH); the shaft (plain ladders in a
	column of open cells from the floor to the ground's top layer, each held by its south wall,
	the hatch at the column's first air, a flush collar); climbing out (Shared/Movement/
	PlayerPhysics, as tests/spec/MineshaftClimbing: from the airlock's floor, pressed against the
	ladder, through the open hatch onto the collar unhurt; a shut hatch holds the climber's head
	under it); hidden caves: the insides are cave air, the
	decorations cave twins or opaque, the lattice hint gives the exact cave graph and a bunker adds
	no drawn box until it is reached; no wild bunker near a mineshaft, library piece, lake, puddle,
	lava lake or oil well (mineshafts in three dimensions), nor within SpawnClearance of the spawn
	(a spawn put on a hatch moves the wild bunker and takes a shed's away); the cities' sheds'
	bunkers (a fake cities: inside their footprint, clear of each other even where two sheds' would
	overlap alone, and of the wild ones); every
	container yields its table's loot and every container and hatch is a point of interest; the
	off switches; 0.25-0.7 per km² on three seeds; plan builds yield every PAUSE lookups and
	never run longer than a worker's slice between yields; cost against the same world without
	them (chunks over bunkers and far nodes, warm and from cold generators; cold plan lookups
	against plain chunks; plain chunks spread over the world at levels 0-4); the debug
	structures world's sample.
]]
return function(t, shared, require)
	local Config = require(shared.Config)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local Poi = require(shared.Poi)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local SectionGraph = require(shared.World.SectionGraph)
	local GreedyMesher = require(shared.Meshing.GreedyMesher)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)
	local Bunkers = require(shared.Generation.Bunkers)
	local Cities = require(shared.Generation.Cities)
	local Caves = require(shared.Generation.Caves)
	local Ores = require(shared.Generation.Ores)
	local Locate = require(shared.Generation.Locate)
	local ScavengeLoot = require(shared.Generation.ScavengeLoot)
	local DebugWorlds = require(shared.Generation.DebugWorlds)
	local Relief = require(shared.Generation.Relief)
	local Hash = require(shared.Util.Hash)
	local PlayerPhysics = require(shared.Movement.PlayerPhysics)

	local SIZE = ChunkLayout.SIZE
	local P = ChunkLayout.PADDED
	local LAYER = ChunkLayout.LAYER
	local SECTION = Config.SectionHeight
	local SEED = 12345
	local SPAWN = { 512, -128 }
	local B = Blocks.id
	local AIR, CAVE_AIR, STONE = Blocks.AIR, Blocks.CAVE_AIR, B.Stone
	local readu16, readu8 = buffer.readu16, buffer.readu8
	local cfg = Config.Bunkers
	local CULL = Blocks.cullLutHiddenCaves

	local gen = TerrainGenerator.new(SEED)
	-- The same world without bunkers (mineshafts, lakes and the rest alike).
	Config.Bunkers.Enabled = false
	local off = TerrainGenerator.new(SEED)
	Config.Bunkers.Enabled = true

	local isFluid: { [number]: boolean } = {}
	for id = 0, Blocks.count - 1 do
		isFluid[id] = Blocks.get(id).fluid ~= nil
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
	-- The chunks over a plan and one more to the west and north: comparing each one's east and
	-- south borders then covers every border a bunker's cells can lie on (its bounds may start at
	-- a chunk's column 0, inside the western neighbour's padding).
	local function bordersOf(plan: any): { { number } }
		local b = plan.bounds
		local out = {}
		for cz = b[3] // SIZE - 1, b[6] // SIZE do
			for cx = b[1] // SIZE - 1, b[4] // SIZE do
				table.insert(out, { cx, cz })
			end
		end
		return out
	end
	-- Border cells of chunk (cx, cz) and its east and south neighbours that disagree (padding
	-- against the neighbour's core, both ways), and how many were compared.
	local function borderMismatches(g: any, cx: number, cz: number): (number, number)
		local a = chunk(g, cx, cz)
		local east = chunk(g, cx + 1, cz)
		local south = chunk(g, cx, cz + 1)
		local mismatches, compared = 0, 0
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
		return mismatches, compared
	end
	local function inBox(b: { number }, x: number, y: number, z: number): boolean
		return x >= b[1] and x <= b[4] and y >= b[2] and y <= b[5] and z >= b[3] and z <= b[6]
	end
	-- The room whose inside holds (x, y, z), or nil.
	local function roomAt(plan: any, x: number, y: number, z: number): any
		for _, room in plan.rooms do
			if inBox(room.inner, x, y, z) then
				return room
			end
		end
		return nil
	end

	-- Climbing out (Shared/Movement/PlayerPhysics over `getBlock`, the hatch open or shut): from
	-- the airlock's floor in the ladder's cell, pressed against the ladder (south, its wall) the
	-- whole way, until standing on the collar south of the shaft. Returns the highest feet, whether
	-- the climber stood on the collar's top clear of the shaft, the damage taken, the ticks and
	-- whether they climbed.
	local function climb(getBlock: (x: number, y: number, z: number) -> number, plan: any, open: boolean)
		local hx, h, hz = plan.x, plan.y, plan.z
		local world = {
			getBlock = function(x: number, y: number, z: number): number?
				if x == hx and y == h and z == hz then
					return if open then B.BunkerHatchOpen else B.BunkerHatch
				end
				return getBlock(x, y, z)
			end,
		}
		local state = PlayerPhysics.new(hx + 0.5, plan.floor, hz + 0.5)
		state.onGround = true
		local press = {
			moveX = 0,
			moveZ = 1,
			forward = 1,
			facingX = 0,
			facingZ = 1,
			lookY = 0,
			jump = false,
			sneak = false,
			sprint = false,
		}
		local top, damage, climbed = -math.huge, 0, false
		for tick = 1, 600 do
			local events = PlayerPhysics.tick(state, press :: any, world)
			damage += events.damage
			top = math.max(top, state.y)
			climbed = climbed or state.climbing
			-- (Clear of the shaft: the 0.6 wide body wholly over the collar's southern row.)
			if state.onGround and state.y >= h - 1e-9 and state.z - 0.3 >= hz + 1 then
				return top, math.abs(state.y - h) < 1e-9, damage, tick, climbed
			end
		end
		return top, false, damage, 600, climbed
	end
	-- Asserts a bunker is climbed out of through its open hatch and that its shut hatch holds a
	-- climber in.
	local function climbsOut(getBlock: (x: number, y: number, z: number) -> number, plan: any, what: string): number
		local top, out, damage, ticks, climbed = climb(getBlock, plan, true)
		t.ok(climbed, `{what}: up the ladder`)
		t.ok(out, `{what}: out through the open hatch onto the collar (highest feet {top}, hatch at {plan.y})`)
		t.eq(damage, 0, `{what}: unhurt`)
		local shutTop, shutOut = climb(getBlock, plan, false)
		t.ok(not shutOut, `{what}: a shut hatch keeps them in`)
		t.near(shutTop, plan.y - 1.8, 1e-6, `{what}: the head under the shut hatch`)
		return ticks
	end

	-- The plans around the spawn, nearest first.
	local AREA = 2500
	local list = (gen.bunkers :: any)(SPAWN[1] - AREA, SPAWN[2] - AREA, SPAWN[1] + AREA, SPAWN[2] + AREA)
	table.sort(list, function(a: any, b: any): boolean
		return (a.x - SPAWN[1]) ^ 2 + (a.z - SPAWN[2]) ^ 2 < (b.x - SPAWN[1]) ^ 2 + (b.z - SPAWN[2]) ^ 2
	end)
	assert(#list >= 6, `bunkers near the spawn: {#list}`)
	-- Two bunkers near the spawn, written whole.
	local near = { list[1], list[2] }
	local both: { { number } } = {}
	for _, plan in near do
		for _, c in chunksOf(plan) do
			table.insert(both, c)
		end
	end

	--[[ Plans ]]

	t.test("bunkers: the layout (airlock, corridor, one bunk room and one storeroom of 3-6, REACH)", function()
		local counts: { [string]: number } = {}
		local lit, overrun = 0, 0
		for _, plan in list do
			t.ok(not plan.city, "wild")
			t.eq(plan.rooms[1].kind, "airlock", "the airlock first")
			t.eq(plan.rooms[2].kind, "corridor", "the corridor second")
			local a = plan.rooms[1].inner
			t.eq(a[4] - a[1] + 1, 5, "airlock 5 wide")
			t.eq(a[6] - a[3] + 1, 5, "airlock 5 deep")
			t.eq(a[5] - a[2] + 1, Bunkers.AIRLOCK_TALL, "airlock 4 tall")
			t.ok(inBox(a, plan.x, plan.floor, plan.z), "the shaft comes down into the airlock")
			t.eq(plan.z, a[6], "by its south wall")
			t.ok(plan.dir ~= "South", "the corridor leaves the ladder's wall alone")
			local c = plan.rooms[2].inner
			t.eq(math.min(c[4] - c[1], c[6] - c[3]) + 1, 3, "corridor 3 wide")
			t.eq(c[5] - c[2] + 1, Bunkers.TALL, "corridor 3 tall")
			local kinds: { [string]: number } = {}
			for i = 3, #plan.rooms do
				local room = plan.rooms[i]
				kinds[room.kind] = (kinds[room.kind] or 0) + 1
				counts[room.kind] = (counts[room.kind] or 0) + 1
				local size = Bunkers.KINDS[room.kind]
				local b = room.inner
				local w, d = b[4] - b[1] + 1, b[6] - b[3] + 1
				t.ok(
					(w == size.along and d == size.deep) or (w == size.deep and d == size.along),
					`{room.kind}: {w} x {d}`
				)
				t.eq(#room.doors, 3, "one doorway")
				-- The doorway opens from the corridor's inside into the room's.
				local dx, dy, dz = room.doors[1], room.doors[2], room.doors[3]
				local openings = 0
				for _, o in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
					if inBox(c, dx + o[1], dy, dz + o[2]) or inBox(b, dx + o[1], dy, dz + o[2]) then
						openings += 1
					end
				end
				t.eq(openings, 2, "a doorway between the corridor and the room")
			end
			t.eq(kinds.bunks, 1, "one bunk room")
			t.eq(kinds.storage, 1, "one storeroom")
			t.ok((kinds.generator or 0) <= 1 and (kinds.armory or 0) <= 1, "one generator room, one armory at most")
			t.ok(#plan.rooms - 2 >= cfg.Rooms[1] and #plan.rooms - 2 <= cfg.Rooms[2], "3..6 rooms")
			-- Insides never overlap; the bounds hold every room and lie within REACH of the hatch.
			for i, ra in plan.rooms do
				for j = i + 1, #plan.rooms do
					local p, q = ra.inner, plan.rooms[j].inner
					local overlap = p[1] <= q[4]
						and p[4] >= q[1]
						and p[2] <= q[5]
						and p[5] >= q[2]
						and p[3] <= q[6]
						and p[6] >= q[3]
					t.ok(not overlap, `{ra.kind} and {plan.rooms[j].kind} overlap`)
				end
				local o, bb = ra.box, plan.bounds
				t.ok(o[1] >= bb[1] and o[4] <= bb[4] and o[3] >= bb[3] and o[6] <= bb[6], "in the bounds")
			end
			-- (Exactly: every room's box, the collar and the plants over it, KEEP_OUT (2) around the
			-- hatch and up to two over its ground.)
			local union = { plan.x - 2, plan.floor - 1, plan.z - 2, plan.x + 2, plan.y + 2, plan.z + 2 }
			for _, room in plan.rooms do
				for k = 1, 3 do
					union[k] = math.min(union[k], room.box[k])
					union[k + 3] = math.max(union[k + 3], room.box[k + 3])
				end
			end
			t.eq(table.concat(plan.bounds, " "), table.concat(union, " "), "the bounds")
			local bb = plan.bounds
			t.ok(
				bb[1] >= plan.x - Bunkers.REACH
					and bb[4] <= plan.x + Bunkers.REACH
					and bb[3] >= plan.z - Bunkers.REACH
					and bb[6] <= plan.z + Bunkers.REACH,
				"within REACH"
			)
			-- The hatch in a chunk's core columns 2..13; the floor Depth under it, over the lava sea.
			t.ok(plan.x % SIZE >= 2 and plan.x % SIZE <= 13 and plan.z % SIZE >= 2 and plan.z % SIZE <= 13, "core")
			t.eq(plan.y, (gen.column(plan.x, plan.z)), "the hatch at the column's first air")
			local depth = plan.y - plan.floor
			t.ok(depth >= cfg.Depth[1] and depth <= cfg.Depth[2], `depth {depth}`)
			t.ok(plan.floor - 1 >= Config.Caves.LavaLevel, "above the lava sea")
			lit += if plan.lit then 1 else 0
			overrun += if plan.overrun then 1 else 0
			-- Lamps: none in a dark bunker; in a lit one not overrun, one every 5 cells of the
			-- corridor, one in the airlock, one or two in each room.
			local lamps = 0
			for _, room in plan.rooms do
				lamps += #room.lamps // 3
				if plan.lit and not plan.overrun then
					local n = #room.lamps // 3
					if room.kind == "corridor" then
						local len = math.max(c[4] - c[1], c[6] - c[3]) + 1
						t.eq(n, (len - 3) // 5 + 1, "corridor lamps")
					else
						t.ok(n == 1 or n == 2, `{room.kind} lamps`)
					end
				end
			end
			if not plan.lit then
				t.eq(lamps, 0, "a dark bunker")
			end
		end
		local parts = {}
		for kind, n in counts do
			table.insert(parts, `{n} {kind}`)
		end
		table.sort(parts)
		print(`    {#list} bunkers: {table.concat(parts, ", ")}; {lit} lit, {overrun} overrun`)
		t.ok(lit > 0 and lit < #list, "lit and dark ones")
	end)

	t.test("bunkers: deterministic across generators, caches, chunk orders and yields", function()
		-- Another generator, asked from the other side first, plans alike.
		local other = TerrainGenerator.new(SEED)
		local plan = near[1]
		local b = plan.bounds;
		(other.bunkers :: any)(b[4] + 800, b[6] + 800, b[4] + 900, b[6] + 900)
		local found = nil
		for _, p in (other.bunkers :: any)(b[1], b[3], b[4], b[6]) do
			if p.x == plan.x and p.z == plan.z then
				found = p
			end
		end
		t.ok(found ~= nil, "the same plan")
		t.eq(#found.rooms, #plan.rooms, "rooms")
		for i, room in plan.rooms do
			t.eq(table.concat(found.rooms[i].box, " "), table.concat(room.box, " "), `room {i}`)
			t.eq(table.concat(found.rooms[i].containers, " "), table.concat(room.containers, " "), `containers {i}`)
			t.eq(table.concat(found.rooms[i].lamps, " "), table.concat(room.lamps, " "), `lamps {i}`)
		end
		t.eq(found.salt, plan.salt)
		-- Chunk bytes: a cold generator asked for the chunk alone (with a yield), and one that
		-- made its neighbours first, in reverse order.
		local yields = 0
		local function yield()
			yields += 1
		end
		for _, c in { { plan.x // SIZE, plan.z // SIZE }, chunksOf(plan)[1] } do
			local cold = TerrainGenerator.new(SEED).generate(0, c[1], c[2], yield, true)
			local warm = TerrainGenerator.new(SEED)
			for dz = 1, -1, -1 do
				for dx = 1, -1, -1 do
					warm.generate(0, c[1] + dx, c[2] + dz)
				end
			end
			local w = warm.generate(0, c[1], c[2])
			local r = chunk(gen, c[1], c[2])
			t.eq(buffer.tostring(cold.data), buffer.tostring(r.data), "cold cache, with a yield")
			t.eq(buffer.tostring(w.data), buffer.tostring(r.data), "another order")
			t.eq(cold.solidBelow, r.solidBelow)
			t.eq(cold.emptyAbove, r.emptyAbove)
			t.eq(w.emptyAbove, r.emptyAbove)
		end
		t.ok(yields > 0, "yielded")
		-- The bunker is there (the world without them differs).
		local c = { plan.x // SIZE, plan.z // SIZE }
		t.ok(buffer.tostring(chunk(gen, c[1], c[2]).data) ~= buffer.tostring(chunk(off, c[1], c[2]).data), "written")
	end)

	t.test("bunkers: padding equals the neighbours' cores; solidBelow and emptyAbove hold", function()
		local mismatches, compared = 0, 0
		for _, plan in near do
			for _, c in bordersOf(plan) do
				local m, n = borderMismatches(gen, c[1], c[2])
				mismatches += m
				compared += n
			end
		end
		for _, c in both do
			local a = chunk(gen, c[1], c[2])
			for y = 0, a.height - 1 do
				for i = 0, LAYER - 1 do
					local id = readu16(a.data, (y * LAYER + i) * 2)
					if y < a.solidBelow and readu8(CULL, id) == 0 then
						error(`chunk {c[1]},{c[2]}: open cell {id} at y {y} below solidBelow {a.solidBelow}`)
					end
					if y >= a.emptyAbove and id ~= AIR then
						error(`chunk {c[1]},{c[2]}: block {id} at y {y} above emptyAbove {a.emptyAbove}`)
					end
				end
			end
		end
		t.eq(mismatches, 0, `border cells that disagree (of {compared})`)
		t.ok(compared > 100000, "compared")
	end)

	--[[ The shaft ]]

	t.test("bunkers: an open column of plain ladders, the hatch at the first air, a flush collar", function()
		local function get(x: number, y: number, z: number): number?
			return blockAt(gen, x, y, z)
		end
		for _, plan in near do
			local x, h, z = plan.x, plan.y, plan.z
			t.eq(blockAt(gen, x, h, z), B.BunkerHatch, "the hatch, shut")
			t.eq(table.concat(plan.hatch, " "), `{x} {h} {z}`, "the plan's hatch")
			t.eq(h, (gen.column(x, z)), "at the column's first air")
			for y = plan.floor, h - 1 do
				local id = blockAt(gen, x, y, z)
				t.eq(id, B.Ladder, `a plain ladder at {x} {y} {z}`)
				t.ok(not Blocks.isCaveTwin(id), "no twin")
				t.ok(Blocks.canSurvive(id, get, x, y, z), "held by its wall")
				t.ok(Blocks.isSturdy(blockAt(gen, x, y, z + 1)), "on the shaft's south wall")
			end
			t.ok(Blocks.isSturdy(blockAt(gen, x, plan.floor - 1, z)), "a floor under the ladder")
			-- The shaft's walls from the airlock's ceiling up, and the collar.
			for dz = -1, 1 do
				for dx = -1, 1 do
					if dx == 0 and dz == 0 then
						continue
					end
					for y = plan.floor + Bunkers.AIRLOCK_TALL, h - 2 do
						t.ok(Blocks.isOpaque(blockAt(gen, x + dx, y, z + dz)), "the shaft walled")
					end
					local collar = blockAt(gen, x + dx, h - 1, z + dz)
					t.ok(collar == B.Concrete or collar == B.MossyConcrete, "the collar")
					local above = blockAt(gen, x + dx, h, z + dz)
					t.ok(not Blocks.isOpaque(above), "flush: nothing over the collar")
				end
			end
			-- No trunk on the collar's 5 x 5 (the keep-out box; a crown from outside may reach in).
			for dz = -2, 2 do
				for dx = -2, 2 do
					for y = h, h + 1 do
						local name = Blocks.get(blockAt(gen, x + dx, y, z + dz)).name
						t.ok(string.find(name, "Log") == nil, `a trunk by a hatch at {x + dx} {y} {z + dz}`)
					end
				end
			end
		end
	end)

	t.test("bunkers: climbed out from the airlock's floor through the open hatch; shut, it holds", function()
		-- (The open hatch stands up against its cell's north side, across the shaft from the
		-- ladder: a climber pressed against the ladder rises past it.)
		local function get(x: number, y: number, z: number): number
			return blockAt(gen, x, y, z)
		end
		for k = 1, 3 do
			local plan = list[k]
			local ticks = climbsOut(get, plan, `bunker {plan.x} {plan.y} {plan.z}`)
			print(`    {plan.x} {plan.y} {plan.z} ({plan.dir}): out in {ticks} ticks from {plan.y - plan.floor} down`)
		end
	end)

	--[[ Caves hidden ]]

	t.test("bunkers: cave air inside; decorations cave twins or opaque; every attached block holds", function()
		local function get(x: number, y: number, z: number): number?
			return blockAt(gen, x, y, z)
		end
		local twins, furnished, attached = 0, 0, 0
		for _, plan in near do
			for _, room in plan.rooms do
				local b = room.inner
				for y = b[2], b[5] do
					for z = b[3], b[6] do
						for x = b[1], b[4] do
							local id = blockAt(gen, x, y, z)
							if x == plan.x and z == plan.z then
								t.eq(id, B.Ladder, "the ladder in the airlock")
								continue
							end
							t.ok(
								id == CAVE_AIR or Blocks.isCaveTwin(id) or Blocks.isOpaque(id),
								`{Blocks.get(id).name} inside at {x} {y} {z}`
							)
							if Blocks.isCaveTwin(id) then
								twins += 1
							elseif id ~= CAVE_AIR then
								furnished += 1
							end
							if Blocks.supportOffset(id) ~= nil then
								attached += 1
								t.ok(Blocks.canSurvive(id, get, x, y, z), `{Blocks.get(id).name} held`)
							end
						end
					end
				end
				-- The shell: opaque all round (doorways and the corridor's mouth aside).
				local o = room.box
				for _, y in { o[2], o[5] } do
					for z = o[3], o[6] do
						for x = o[1], o[4] do
							if not (x == plan.x and z == plan.z) and roomAt(plan, x, y, z) == nil then
								t.ok(Blocks.isOpaque(blockAt(gen, x, y, z)), `the shell at {x} {y} {z}`)
							end
						end
					end
				end
			end
		end
		print(`    {furnished} furnishings, {twins} cave twins, {attached} attached blocks`)
		t.ok(furnished > 20, "furnished")
	end)

	t.test("bunkers: an overrun one: mossy shells, cave cobwebs under the ceilings, lamps gone", function()
		-- (A lit one, so that half its lamps are gone; further out if none is near the spawn.)
		local function find(area: { any }): any
			for _, p in area do
				if p.overrun and p.lit then
					return p
				end
			end
			return nil
		end
		local plan = find(list) or find((gen.bunkers :: any)(-4000, -4000, 4000, 4000))
		t.ok(plan ~= nil, "a lit overrun bunker")
		local mossy, webs, lamps, kept = 0, 0, 0, 0
		local lamp = Blocks.caveTwinFor(B.CeilingLamp)
		for _, room in plan.rooms do
			kept += #room.lamps // 3
		end
		local o = plan.bounds
		for y = plan.floor - 1, plan.floor + Bunkers.AIRLOCK_TALL do
			for z = o[3], o[6] do
				for x = o[1], o[4] do
					local id = blockAt(gen, x, y, z)
					if id == B.MossyConcrete then
						mossy += 1
					elseif id == B.CaveCobweb then
						webs += 1
						local inside = roomAt(plan, x, y, z)
						t.ok(inside ~= nil and y == inside.inner[5], "under a ceiling")
					elseif id == lamp then
						lamps += 1
					end
				end
			end
		end
		print(`    {mossy} mossy shell cells, {webs} cobwebs, {lamps} lamps`)
		t.ok(mossy > 20 and webs > 3, "mossy and webbed")
		t.eq(lamps, kept, "the lamps the plan keeps")
		-- About half the lamps a lit bunker of its layout would have.
		local full = 0
		for _, room in plan.rooms do
			local c = plan.rooms[2].inner
			if room.kind == "corridor" then
				full += (math.max(c[4] - c[1], c[6] - c[3]) + 1 - 3) // 5 + 1
			elseif
				room.kind ~= "airlock"
				and (room.inner[6] - room.inner[3] + 1 >= 9 or room.inner[4] - room.inner[1] + 1 >= 9)
			then
				full += 2
			else
				full += 1
			end
		end
		t.ok(kept < full, `{kept} of {full} lamps kept`)
	end)

	-- The cave visibility graph a worker builds (lattice hint, dug sections read cell by cell)
	-- against reading every cell (as tests/spec/Mineshafts).
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

	t.test("bunkers: the lattice hint gives the exact cave graph, every cave cell listed", function()
		local sections = 0
		for _, c in both do
			sections += graphsAgree(c[1], c[2])
		end
		t.ok(sections > 20, `sections compared: {sections}`)
	end)

	t.test("bunkers: hidden caves draw nothing of a bunker (the same boxes as without it)", function()
		-- Sections where the bunker wrote something drawn (the shaft, the hatch, the collar, plants,
		-- a wall bared by a surface cave) or the two worlds differ above the ground (trees kept off
		-- the collar) are skipped: a cell that changed and is drawn, or touches a drawn one.
		local same, skipped, boxes, changed = 0, 0, 0, 0
		local function drawn(r: any, px: number, y: number, pz: number): boolean
			if px < 0 or px >= P or pz < 0 or pz >= P or y < 0 then
				return false
			end
			return readu8(CULL, at(r, px, y, pz)) == 0
		end
		for k = 1, 4 do
			local plan = list[k]
			local b = plan.bounds
			for _, c in chunksOf(plan) do
				for y0 = (b[2] // SECTION) * SECTION, b[5], SECTION do
					local r = chunk(gen, c[1], c[2])
					local p = chunk(off, c[1], c[2])
					if y0 + SECTION > math.min(r.height, p.height) then
						skipped += 1
						continue
					end
					local visible, differs = false, false
					for y = math.max(y0 - 1, 0), math.min(y0 + SECTION, r.height - 1, p.height - 1) do
						for pz = 0, P - 1 do
							for px = 0, P - 1 do
								local a, q = at(r, px, y, pz), at(p, px, y, pz)
								if a == q then
									continue
								end
								differs = true
								if readu8(CULL, a) == 0 or readu8(CULL, q) == 0 then
									visible = true
								else
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
										if
											drawn(r, px + d[1], y + d[2], pz + d[3])
											or drawn(p, px + d[1], y + d[2], pz + d[3])
										then
											visible = true
										end
									end
								end
								if visible then
									break
								end
							end
							if visible then
								break
							end
						end
						if visible then
							break
						end
					end
					if visible then
						skipped += 1
						continue
					end
					local m1, n1 = GreedyMesher.mesh(r.data, r.height, y0, y0 + SECTION, true)
					local m2, n2 = GreedyMesher.mesh(p.data, p.height, y0, y0 + SECTION, true)
					t.eq(n1, n2, `chunk {c[1]},{c[2]} section {y0}: boxes`)
					t.eq(buffer.tostring(m1), buffer.tostring(m2), `chunk {c[1]},{c[2]} section {y0}: the same boxes`)
					same += 1
					boxes += n1
					if differs then
						changed += 1
					end
				end
			end
		end
		print(
			`    {same} sections through a bunker drawn as without it ({changed} holding its rooms, {boxes} boxes), {skipped} skipped`
		)
		t.ok(changed >= 8, "sections holding rooms compared")
	end)

	--[[ Keeping clear ]]

	t.test("bunkers: clear of mineshafts, library pieces, lakes, puddles, lava lakes, wells; off the spawn", function()
		local margin = Bunkers.MARGIN
		local sx, _, sz = gen.findSpawn()
		local under = 0
		for _, plan in list do
			local b = plan.bounds
			local x0, z0, x1, z1 = b[1] - margin, b[3] - margin, b[4] + margin, b[6] + margin
			t.eq(#gen.waterLakes(x0, z0, x1, z1), 0, "no water lake")
			t.eq(#gen.lavaLakes(x0, z0, x1, z1), 0, "no lava lake")
			t.eq(#gen.puddles(x0, z0, x1, z1), 0, "no puddle")
			t.eq(#gen.oilWells(x0, z0, x1, z1), 0, "no oil well")
			for _, start in gen.structures(x0, z0, x1, z1) do
				for _, piece in start.pieces do
					local o = piece.box
					t.ok(not (o[1] <= x1 and o[4] >= x0 and o[3] <= z1 and o[6] >= z0), "no library piece")
				end
			end
			-- Mineshafts in three dimensions: no piece or entrance shaft within MARGIN of a room's
			-- shell or of the shaft's column (the collar and plants over it, its walls under it).
			local solids = {}
			for _, room in plan.rooms do
				table.insert(solids, room.box)
			end
			table.insert(solids, { plan.x - 2, plan.floor - 1, plan.z - 2, plan.x + 2, plan.y + 2, plan.z + 2 })
			local function near3(o: { number }): boolean
				for _, s in solids do
					if
						o[1] <= s[4] + margin
						and o[4] >= s[1] - margin
						and o[2] <= s[5] + margin
						and o[5] >= s[2] - margin
						and o[3] <= s[6] + margin
						and o[6] >= s[3] - margin
					then
						return true
					end
				end
				return false
			end
			local flat = false
			for _, shaft in (gen.mineshafts :: any)(x0, z0, x1, z1) do
				for _, piece in shaft.pieces do
					local o = piece.outer
					t.ok(not near3(o), "no mineshaft piece")
					flat = flat or (o[1] <= x1 and o[4] >= x0 and o[3] <= z1 and o[6] >= z0)
				end
				local e = shaft.entrance
				if e then
					t.ok(not near3(e.shaft), "no mineshaft entrance")
				end
			end
			under += if flat then 1 else 0
			local dx = math.max(b[1] - sx, 0, sx - b[4])
			local dz = math.max(b[3] - sz, 0, sz - b[6])
			t.ok(dx * dx + dz * dz >= cfg.SpawnClearance ^ 2, "SpawnClearance from the spawn")
		end
		print(`    {#list} bunkers clear; {under} over a deeper mineshaft's footprint`)
	end)

	t.test("bunkers: a spawn put on a hatch moves the wild bunker off it, and takes a shed's away", function()
		-- Bunkers over the generator's own heights (nothing blocked, no surface caves), first with
		-- the spawn far away, then on a hatch: that cell's search moves on to another candidate
		-- (or none), and no bunker's bounds come within SpawnClearance of the spawn.
		local spawnX, spawnZ = 10 ^ 6, 10 ^ 6
		local spot: { number } = {}
		local cityAt = 1
		local fakeCities = {
			bunkerSpots = function(minX: number, minZ: number, maxX: number, maxZ: number): { number }
				local x, z = spot[1], spot[3]
				if x and x >= minX and x <= maxX and z >= minZ and z <= maxZ then
					return { x, spot[2], z }
				end
				return {}
			end,
			cityAt = function(): number
				return cityAt
			end,
		}
		local function bunkersWith(): any
			return Bunkers.new(SEED, {
				height = function(x: number, z: number): number
					return (gen.column(x, z))
				end,
				biome = function(): number
					return 1
				end,
				river = function(): number
					return 0
				end,
				blocked = function(): { number }
					return {}
				end,
				spawn = function(): (number, number)
					return spawnX, spawnZ
				end,
				carvesTop = function(): boolean
					return false
				end,
				cities = fakeCities :: any,
				surface = function(x: number, z: number): number
					return (gen.column(x, z))
				end,
			})
		end
		local grid = cfg.Grid
		local moved = 0
		for k = 1, 3 do
			local real = list[k]
			local gx, gz = real.x // grid, real.z // grid
			spawnX, spawnZ = 10 ^ 6, 10 ^ 6
			local function cellPlan(b: any): any
				for _, p in b.plans(gx * grid, gz * grid, gx * grid + grid - 1, gz * grid + grid - 1) do
					if not p.city and p.x // grid == gx and p.z // grid == gz then
						return p
					end
				end
				return nil
			end
			local before = cellPlan(bunkersWith())
			t.ok(before ~= nil, "a bunker in the cell with the spawn far away")
			spawnX, spawnZ = before.x, before.z
			local after = cellPlan(bunkersWith())
			t.ok(after == nil or after.x ~= before.x or after.z ~= before.z, "moved off the spawn")
			if after then
				moved += 1
				local b = after.bounds
				local dx = math.max(b[1] - spawnX, 0, spawnX - b[4])
				local dz = math.max(b[3] - spawnZ, 0, spawnZ - b[6])
				t.ok(dx * dx + dz * dz >= cfg.SpawnClearance ^ 2, "SpawnClearance from the new spawn")
				print(
					string.format(
						"    a spawn on %d %d: the bunker moved to %d %d (%.1f blocks off)",
						before.x,
						before.z,
						after.x,
						after.z,
						math.sqrt(dx * dx + dz * dz)
					)
				)
			end
		end
		t.ok(moved > 0, "some bunker moved rather than went")
		-- A shed's spot (a town all round it): a bunker under it with the spawn far away, none with
		-- the spawn on its hatch.
		local real = list[1]
		local sx, sz = real.x + 3, real.z + 3
		spot = { sx, (gen.column(sx, sz)), sz }
		local function shedPlan(): any
			for _, p in bunkersWith().plans(sx, sz, sx, sz) do
				if p.city then
					return p
				end
			end
			return nil
		end
		spawnX, spawnZ = 10 ^ 6, 10 ^ 6
		t.ok(shedPlan() ~= nil, "a shed's bunker with the spawn far away")
		spawnX, spawnZ = sx, sz
		t.eq(shedPlan(), nil, "none with the spawn on the shed's hatch")
		spawnX, spawnZ = sx + cfg.SpawnClearance + Bunkers.REACH + 1, sz
		t.ok(shedPlan() ~= nil, "one again with the spawn beyond SpawnClearance of every layout")
	end)

	--[[ Loot and points of interest ]]

	t.test("bunkers: every container yields its table's loot; containers and hatches are points of interest", function()
		local lootSalt = Hash.hash2(SEED, Hash.string("bunkers.loot"), 0xB0B5)
		local fresh = TerrainGenerator.new(SEED)
		local containers, stacks, onFloor = 0, 0, 0
		local tables: { [string]: number } = {}
		for k, plan in list do
			if k > 8 then
				break
			end
			for _, room in plan.rooms do
				local cs = room.containers
				for i = 1, #cs, 5 do
					local x, y, z, block, loot = cs[i], cs[i + 1], cs[i + 2], cs[i + 3], cs[i + 4]
					containers += 1
					local name = Bunkers.TABLES[loot]
					tables[name] = (tables[name] or 0) + 1
					t.ok(ScavengeLoot.TABLES[name] ~= nil, `a table: {name}`)
					t.ok(block == B.Chest or block == B.SupplyCrate or block == B.MedicineCabinet, "a container")
					local items = gen.structureContainer(x, y, z)
					t.ok(items ~= nil, "its loot")
					if items == nil then
						continue
					end
					t.ok(gen.structureContainer(x, y, z) ~= items, "a fresh table")
					local again = fresh.structureContainer(x, y, z) :: any
					t.eq(#again, #items, "a cold generator answers alike")
					local expected = Bunkers.loot(lootSalt, loot, plan.overrun, x, y, z)
					t.eq(#expected, #items, "its table rolled")
					if not plan.overrun then
						local rolled = ScavengeLoot.roll(name, lootSalt, x, y, z)
						t.eq(#rolled, #items, "ScavengeLoot's roll")
						for j, item in items do
							t.eq(rolled[j].item, item.item)
							t.eq(rolled[j].count, item.count)
							t.eq(rolled[j].slot, item.slot)
						end
					end
					local slots: { [number]: boolean } = {}
					for j, item in items do
						t.eq(again[j].item, item.item)
						t.eq(again[j].slot, item.slot)
						local id = Items.find(item.item)
						t.ok(id ~= nil, `{item.item} exists`)
						t.ok(item.count >= 1 and item.count <= Items.maxStack(id :: number), "a stack")
						t.ok(item.slot >= 1 and item.slot <= ScavengeLoot.SLOTS and not slots[item.slot], "a free slot")
						slots[item.slot] = true
						stacks += 1
					end
					t.eq(gen.structureContainer(x, y + 5, z), nil, "nothing over it")
					if k <= #near and blockAt(gen, x, y, z) == block then
						onFloor += 1
					end
				end
			end
		end
		print(`    {containers} containers ({stacks} stacks), {onFloor} written in the two nearest`)
		t.ok(tables.bunker_storage and tables.bunker_medical, "storerooms and medical rooms")
		t.ok(onFloor >= 6, "containers in the world")
		-- An overrun bunker's containers: its table with another salt, and Bone and Rotten Flesh.
		local bones = 0
		for i = 1, 40 do
			for _, item in Bunkers.loot(lootSalt, 1, true, i, 40, -i) do
				if item.item == "Bone" or item.item == "RottenFlesh" then
					bones += 1
				end
			end
		end
		t.eq(bones, 80, "Bone and Rotten Flesh in every overrun container")
		-- Points of interest: every container and hatch from the plans, as written.
		local lut = Poi.lutOf({ "chest", "supply_crate", "medicine_cabinet", "bunker_hatch" })
		for _, plan in near do
			local b = plan.bounds
			local out = (gen.poiBlocks :: any)(b[1], b[3], b[4], b[6], lut)
			local hatch, kept = false, 0
			for i = 1, #out, 4 do
				local x, y, z, block = out[i], out[i + 1], out[i + 2], out[i + 3]
				if block == B.BunkerHatch and x == plan.x and y == plan.y and z == plan.z then
					hatch = true
				end
				if blockAt(gen, x, y, z) == block then
					kept += 1
				end
			end
			t.ok(hatch, "the hatch listed")
			local total = 1
			for _, room in plan.rooms do
				total += #room.containers // 5
			end
			t.ok(#out // 4 >= total, "every container listed")
			t.ok(kept >= total, "as written")
		end
	end)

	--[[ Off switches ]]

	t.test("bunkers: none without the ruins, structures, Generate Structures or Bunkers.Enabled", function()
		local plan = near[1]
		local c = { plan.x // SIZE, plan.z // SIZE }
		local without = chunk(off, c[1], c[2])
		for _, options in { { ruins = false }, { structures = false } } do
			local g = TerrainGenerator.new(SEED, options :: any)
			t.eq(#(g.bunkers :: any)(-3000, -3000, 3000, 3000), 0, "no bunkers")
		end
		local ruinsOff = TerrainGenerator.new(SEED, { ruins = false })
		t.eq(
			buffer.tostring(ruinsOff.generate(0, c[1], c[2]).data),
			buffer.tostring(without.data),
			"ruins off: the world without"
		)
		local generate = Config.Structures.Generate
		Config.Structures.Generate = false
		local bare = TerrainGenerator.new(SEED)
		Config.Structures.Generate = generate
		t.eq(#(bare.bunkers :: any)(-3000, -3000, 3000, 3000), 0, "Generate Structures off")
		t.eq(#(off.bunkers :: any)(-3000, -3000, 3000, 3000), 0, "Bunkers.Enabled off")
		-- (/locate: TerrainGenerator lists its kinds when first asked, by the config then; with
		-- Bunkers.Enabled off at its making it has none to find.)
		local kinds = {}
		for _, kind in (off.locateKinds :: any)() do
			if kind.id == "bunker" then
				table.insert(kinds, kind)
			end
		end
		local stats = { probes = 0, verified = 0 }
		t.eq(Locate.nearest(kinds, plan.x, plan.z, nil, stats), nil, "/locate finds none")
		t.eq(stats.verified, 0, "no probe answers")
	end)

	--[[ Cities ]]

	-- A fake cities (Generation/Cities' interface): one square town levelled flat at H around
	-- (cx, cz), half side R, blended over 24 blocks, with two sheds' spots in its outer ring.
	local function fakeCities(cx: number, cz: number, R: number, H: number, spots: { number })
		local MARGIN = 24
		return function(_seed: number, raw: any, _options: any): any
			local fake = Cities.none(raw)
			local function weight(x: number, z: number): number
				local d = math.max(math.abs(x - cx), math.abs(z - cz)) - R
				if d <= 0 then
					return 1
				end
				return math.max(0, 1 - d / MARGIN)
			end
			fake.relief = {
				height = function(x: number, z: number, level: number): (number, number, number, number)
					local y, u, s, river = raw.height(x, z, level)
					local w = weight(x, z)
					return y + (H - y) * w, u, s, river * (1 - w)
				end,
				selector = raw.selector,
			}
			fake.cityAt = weight
			fake.protects = function(x: number, z: number): boolean
				return weight(x, z) > 0
			end
			fake.treeAllowed = function(x: number, z: number): boolean
				return weight(x, z) == 0
			end
			fake.blocked = function(minX: number, minZ: number, maxX: number, maxZ: number): { number }
				local x0, z0, x1, z1 = cx - R - MARGIN, cz - R - MARGIN, cx + R + MARGIN, cz + R + MARGIN
				if x0 <= maxX and x1 >= minX and z0 <= maxZ and z1 >= minZ then
					return { x0, z0, x1, z1 }
				end
				return {}
			end
			fake.bunkerSpots = function(minX: number, minZ: number, maxX: number, maxZ: number): { number }
				local out = {}
				for i = 1, #spots, 2 do
					local x, z = spots[i], spots[i + 1]
					if x >= minX and x <= maxX and z >= minZ and z <= maxZ then
						table.insert(out, x)
						table.insert(out, H)
						table.insert(out, z)
					end
				end
				return out
			end
			local grid = Config.Cities.Grid
			fake.locateKind = function(): any
				return {
					id = "city",
					grid = grid,
					slack = 0,
					rings = 4,
					showY = false,
					probe = function(gx: number, gz: number): (number?, number, number)
						if gx == cx // grid and gz == cz // grid then
							return cx, cz, 0
						end
						return nil, 0, 0
					end,
				}
			end
			return fake
		end
	end

	t.test("bunkers: under the cities' sheds (a fake cities): inside the town, apart, written, located", function()
		-- A town on dry land away from the spawn.
		local cx, cz = 2600, 1800
		local H = (gen.column(cx, cz))
		t.ok(H > Config.SeaLevel + 3, `dry land for the town: {H}`)
		local R = 99
		-- (Two sheds PAIR blocks apart, whose bunkers would overlap planned alone, and a third.)
		local PAIR = 15
		local a, b = { cx - 80, cz - 70 }, { cx - 80 + PAIR, cz - 70 }
		local spots = { a[1], a[2], b[1], b[2], cx + 70, cz + 75 }
		local new = Cities.new
		-- The shed bunker at (x, z) of a town holding `only` those spots.
		local function alone(only: { number }, x: number, z: number): any
			Cities.new = fakeCities(cx, cz, R, H, only) :: any
			for _, plan in (TerrainGenerator.new(SEED).bunkers :: any)(x, z, x, z) do
				if plan.city and plan.x == x and plan.z == z then
					return plan
				end
			end
			return nil
		end
		local ok, err = pcall(function()
			local soloA, soloB = alone(a, a[1], a[2]), alone(b, b[1], b[2])
			t.ok(soloA ~= nil and soloB ~= nil, "each shed's bunker alone")
			local function overlap(p: { number }, q: { number }): boolean
				return p[1] <= q[4] and p[4] >= q[1] and p[3] <= q[6] and p[6] >= q[3]
			end
			t.ok(overlap(soloA.bounds, soloB.bounds), "planned alone, the two sheds' bunkers would overlap")
			Cities.new = fakeCities(cx, cz, R, H, spots) :: any
			local city = TerrainGenerator.new(SEED)
			local pairA, pairB = nil, nil
			for _, plan in (city.bunkers :: any)(a[1], a[2], b[1], b[2]) do
				if plan.city and plan.x == a[1] and plan.z == a[2] then
					pairA = plan
				elseif plan.city and plan.x == b[1] and plan.z == b[2] then
					pairB = plan
				end
			end
			t.ok(pairA ~= nil and pairB ~= nil, "both sheds keep a bunker")
			t.ok(not overlap(pairA.bounds, pairB.bounds), "planned together, apart")
			-- Neither reaches the other's airlock and collar (what every layout of the other's
			-- keeps: x - 3..x + 3, z - 5..z + 2).
			print(`    two sheds {PAIR} apart: {soloA.dir} and {soloB.dir} alone, {pairA.dir} and {pairB.dir} together`)
			for _, pq in { { pairA, pairB }, { pairB, pairA } } do
				local p, q = pq[1], pq[2]
				local airlock = { q.x - 3, 0, q.z - 5, q.x + 3, 0, q.z + 2 }
				t.ok(not overlap(p.bounds, airlock), "clear of the other's airlock and collar")
			end
			local found = (city.bunkers :: any)(cx - 300, cz - 300, cx + 300, cz + 300)
			local mine: { any } = {}
			for _, plan in found do
				if plan.city then
					table.insert(mine, plan)
				else
					-- Wild ones keep out of the town's blocked area.
					local b = plan.bounds
					t.ok(
						b[4] < cx - R - 24 - Bunkers.MARGIN
							or b[1] > cx + R + 24 + Bunkers.MARGIN
							or b[6] < cz - R - 24 - Bunkers.MARGIN
							or b[3] > cz + R + 24 + Bunkers.MARGIN,
						"a wild bunker in the town"
					)
				end
			end
			t.eq(#mine, #spots // 2, "a bunker under every shed")
			for i, plan in mine do
				t.eq(plan.y, H, "the hatch on the shed's floor")
				t.eq(plan.floor, H - Bunkers.CITY_DEPTH, "CITY_DEPTH under it")
				local b = plan.bounds
				t.ok(b[1] > cx - R and b[4] < cx + R and b[3] > cz - R and b[6] < cz + R, "inside the town's footprint")
				for j = i + 1, #mine do
					local o = mine[j].bounds
					local overlap = b[1] <= o[4] and b[4] >= o[1] and b[3] <= o[6] and b[6] >= o[3]
					t.ok(not overlap, "two sheds' bunkers apart")
				end
				t.eq(blockAt(city, plan.x, plan.y, plan.z), B.BunkerHatch, "the hatch")
				for y = plan.floor, plan.y - 1 do
					t.eq(blockAt(city, plan.x, y, plan.z), B.Ladder, "the ladder")
				end
			end
			-- Climbed out through the shed's open hatch.
			climbsOut(function(x: number, y: number, z: number): number
				return blockAt(city, x, y, z)
			end, mine[1], "a shed's bunker")
			-- Their chunks' padding equals the neighbours' cores (every border they can touch).
			local mismatches = 0
			for _, c in bordersOf(mine[1]) do
				mismatches += (borderMismatches(city, c[1], c[2]))
			end
			t.eq(mismatches, 0, "border cells that disagree")
			-- /locate structure bunker finds the town's nearest bunker, the brute force's.
			local kinds = {}
			for _, kind in (city.locateKinds :: any)() do
				if kind.id == "bunker" then
					table.insert(kinds, kind)
				end
			end
			t.eq(#kinds, 1, "the bunker kind")
			for _, point in { { cx, cz }, { cx + 40, cz + 90 } } do
				local f = Locate.nearest(kinds, point[1], point[2]) :: any
				t.ok(f ~= nil, "found")
				local best = math.huge
				local r = f.distance + 2
				for _, plan in (city.bunkers :: any)(point[1] - r, point[2] - r, point[1] + r, point[2] + r) do
					best = math.min(best, math.sqrt((plan.x - point[1]) ^ 2 + (plan.z - point[2]) ^ 2))
				end
				t.near(f.distance, best, 1e-6, "the nearest")
				t.eq(f.y, H, "standing on the hatch")
			end
			caches[city] = nil
		end)
		Cities.new = new
		if not ok then
			error(err, 0)
		end
	end)

	--[[
		D's smallest town (Generation/CityLayout, half 1: R = 35): a street cross through its
		centre and round its edge (7 wide), four parcels of 25 x 25 between them, each of four
		12-block lots 13 apart; a shed's middle lies 3-8 blocks into its lot, the first of those
		(from a hashed one) in core columns 2..13 of its chunk. The lots' sheds here stand at the
		cell nearest the town's edge that passes, the worst case: an outer lot's shed is 10-12
		blocks from the edge, 22-25 from the centre.
	]]
	local SMALL = 35
	-- A shed's middle along one axis in the lot starting `l0` blocks from the centre `c`: its cell
	-- nearest the edge (3 or 8 into the lot) in core columns 2..13, else the next one inwards.
	local function shedAlong(c: number, l0: number): number
		local first, last, step = l0 + 3, l0 + 8, 1
		if l0 > 0 then
			first, last, step = last, first, -1
		end
		for v = first, last, step do
			local m = (c + v) % SIZE
			if m >= 2 and m <= SIZE - 3 then
				return c + v
			end
		end
		error("no core cell in the lot")
	end
	-- The lots' starts from a small town's centre, along either axis (west or north first).
	local LOTS = { -SMALL + 7, -SMALL + 20, 4, 17 }
	-- Bunkers over a fake cities of small towns (each `towns` entry: cx, cz; of radius `radius`,
	-- SMALL when nil) levelled at 80 over a sea floor (nothing wild passes, so only the sheds count
	-- and cost), with the sheds' spots (x, z each), the spawn far away.
	local function smallTowns(towns: { { number } }, spots: { number }, radius: number?): any
		local H = 80
		local R = radius or SMALL
		local function weight(x: number, z: number): number
			local best = 0
			for _, c in towns do
				local d = math.max(math.abs(x - c[1]), math.abs(z - c[2])) - R
				best = math.max(best, if d <= 0 then 1 else math.max(0, 1 - d / 24))
			end
			return best
		end
		local fake = {
			bunkerSpots = function(minX: number, minZ: number, maxX: number, maxZ: number): { number }
				local out = {}
				for i = 1, #spots, 2 do
					local x, z = spots[i], spots[i + 1]
					if x >= minX and x <= maxX and z >= minZ and z <= maxZ then
						table.insert(out, x)
						table.insert(out, H)
						table.insert(out, z)
					end
				end
				return out
			end,
			cityAt = weight,
		}
		return Bunkers.new(SEED, {
			height = function(): number
				return Config.SeaLevel - 10
			end,
			biome = function(): number
				return 1
			end,
			river = function(): number
				return 0
			end,
			blocked = function(): { number }
				return {}
			end,
			spawn = function(): (number, number)
				return 10 ^ 6, 10 ^ 6
			end,
			carvesTop = function(): boolean
				return false
			end,
			cities = fake :: any,
			surface = function(): number
				return H
			end,
		})
	end
	-- The city bunker at shed (x, z) of `b`, or nil.
	local function shedBunker(b: any, x: number, z: number, yield: (() -> ())?): any
		for _, p in b.plans(x, z, x, z, yield) do
			if p.city and p.x == x and p.z == z then
				return p
			end
		end
		return nil
	end
	-- Inside the small town at (cx, cz): the bounds GUARD + 1 inside its footprint (the levelled
	-- ground, as Bunkers asks), within REACH of the hatch.
	local function insideSmall(plan: any, cx: number, cz: number): boolean
		local b, m = plan.bounds, Bunkers.GUARD + 1
		return b[1] - m >= cx - SMALL
			and b[4] + m <= cx + SMALL
			and b[3] - m >= cz - SMALL
			and b[6] + m <= cz + SMALL
			and b[1] >= plan.x - Bunkers.REACH
			and b[4] <= plan.x + Bunkers.REACH
			and b[3] >= plan.z - Bunkers.REACH
			and b[6] <= plan.z + Bunkers.REACH
	end

	t.test("bunkers: every lot's shed of D's smallest town gets one, on every side and in every corner", function()
		-- Each of the 16 lots' sheds alone in a town (its own centre, so the chunk columns vary).
		local sides: { [string]: { number } } = {}
		local dirs: { [string]: number } = {}
		local oneSided = 0
		local k = 0
		for _, lz in LOTS do
			for _, lx in LOTS do
				k += 1
				local cx, cz = 3000 + 997 * k, -2000 + 389 * k
				local x, z = shedAlong(cx, lx), shedAlong(cz, lz)
				local dx, dz = x - cx, z - cz
				local side = if math.min(math.abs(dx), math.abs(dz)) >= 20
					then "corner"
					elseif math.abs(dz) >= math.abs(dx) then (if dz < 0 then "north" else "south")
					else (if dx < 0 then "west" else "east")
				local plan = shedBunker(smallTowns({ { cx, cz } }, { x, z }), x, z)
				local count = sides[side] or { 0, 0 }
				sides[side] = count
				count[2] += 1
				if plan then
					count[1] += 1
					dirs[plan.dir] = (dirs[plan.dir] or 0) + 1
					t.ok(insideSmall(plan, cx, cz), `the shed {dx} {dz}'s bunker inside the town`)
					local kinds = {}
					for _, room in plan.rooms do
						kinds[room.kind] = (kinds[room.kind] or 0) + 1
					end
					t.eq(kinds.bunks, 1, "its bunk room")
					t.eq(kinds.storage, 1, "its storeroom")
					-- (One-sided: every room on the same side of the corridor.)
					local corridor = plan.rooms[2].inner
					local before, after = 0, 0
					for i = 3, #plan.rooms do
						local inner = plan.rooms[i].inner
						local first = if plan.dir == "North" then inner[4] < corridor[1] else inner[6] < corridor[3]
						if first then
							before += 1
						else
							after += 1
						end
					end
					if before == 0 or after == 0 then
						oneSided += 1
					end
				else
					t.ok(false, `the shed {dx} {dz} ({side}) of a small town gets no bunker`)
				end
			end
		end
		for _, side in { "north", "east", "south", "west", "corner" } do
			local count = sides[side] or { 0, 0 }
			print(`    {side}: {count[1]} of {count[2]} sheds with a bunker`)
			t.ok(count[2] > 0, `sheds on the {side} side`)
		end
		print(
			`    headings {dirs.North or 0} north, {dirs.East or 0} east, {dirs.West or 0} west; {oneSided} one-sided`
		)
		t.ok(oneSided > 0, "the sheds near the north edge put every room on one side")
	end)

	t.test("bunkers: two sheds of D's smallest town get one each, apart, in every pair of parcels", function()
		-- Every pair of lots in different parcels (D gives a town at most two sheds, in two
		-- parcels), at their cells nearest the edge.
		local pairs, both = 0, 0
		local longest, yields = 0, 0
		local k = 0
		for a = 1, 16 do
			for b = a + 1, 16 do
				local ax, az = LOTS[(a - 1) % 4 + 1], LOTS[(a - 1) // 4 + 1]
				local bx, bz = LOTS[(b - 1) % 4 + 1], LOTS[(b - 1) // 4 + 1]
				-- (A parcel holds lots 1-2 or 3-4 of LOTS each way.)
				if (ax > 0) == (bx > 0) and (az > 0) == (bz > 0) then
					continue
				end
				k += 1
				pairs += 1
				local cx, cz = 3000 + 997 * k, 9000 + 389 * k
				local x1, z1 = shedAlong(cx, ax), shedAlong(cz, az)
				local x2, z2 = shedAlong(cx, bx), shedAlong(cz, bz)
				local bunkers = smallTowns({ { cx, cz } }, { x1, z1, x2, z2 })
				-- (Planned with a yield that times the stretches between its calls.)
				local last = os.clock()
				local function yield()
					local now = os.clock()
					longest = math.max(longest, now - last)
					yields += 1
					last = now
				end
				local p = shedBunker(bunkers, x1, z1, yield)
				local q = shedBunker(bunkers, x2, z2, yield)
				longest = math.max(longest, os.clock() - last)
				if p and q then
					both += 1
					t.ok(insideSmall(p, cx, cz) and insideSmall(q, cx, cz), "both inside the town")
					local pb, qb = p.bounds, q.bounds
					t.ok(
						not (pb[1] <= qb[4] and pb[4] >= qb[1] and pb[3] <= qb[6] and pb[6] >= qb[3]),
						"two sheds' bunkers apart"
					)
				else
					t.ok(false, `sheds at {x1 - cx} {z1 - cz} and {x2 - cx} {z2 - cz}: a bunker each`)
				end
			end
		end
		print(
			string.format(
				"    %d of %d pairs of sheds in two parcels both get a bunker; %d yields, the longest stretch %.2f ms",
				both,
				pairs,
				yields,
				longest * 1000
			)
		)
		t.eq(pairs, 96, "every pair of lots in two parcels")
		t.ok(longest < 0.003, "no stretch over 3 ms between yields")
	end)

	t.test("bunkers: two sheds at a small town's north edge: written, climbed out of, padding agrees", function()
		-- The real generator over a fake town of radius 35 (SMALL) with D's two sheds in its two
		-- northern parcels: one in the north-west corner lot, 10 blocks from both edges, one in
		-- the north-east parcel's west lot, 10 blocks from the north edge.
		local cx, cz = 2595, 1795
		local H = (gen.column(cx, cz))
		t.ok(H > Config.SeaLevel + 3, `dry land for the town: {H}`)
		local sheds = {
			{ shedAlong(cx, LOTS[1]), shedAlong(cz, LOTS[1]) },
			{ shedAlong(cx, LOTS[3]), shedAlong(cz, LOTS[1]) },
		}
		t.eq(sheds[1][1] - cx, -25, "the corner shed 10 blocks from the west edge")
		t.eq(sheds[1][2] - cz, -25, "and from the north edge")
		t.eq(sheds[2][2] - cz, -25, "the other 10 blocks from the north edge")
		local new = Cities.new
		Cities.new = fakeCities(cx, cz, SMALL, H, { sheds[1][1], sheds[1][2], sheds[2][1], sheds[2][2] }) :: any
		local ok, err = pcall(function()
			local city = TerrainGenerator.new(SEED)
			local plans = {}
			for _, shed in sheds do
				local x, z = shed[1], shed[2]
				local plan = nil
				for _, p in (city.bunkers :: any)(x, z, x, z) do
					if p.city and p.x == x and p.z == z then
						plan = p
					end
				end
				t.ok(plan ~= nil, `a bunker under the shed {x - cx} {z - cz} of the town`)
				table.insert(plans, plan)
				print(`    the shed {x - cx} {z - cz}: heading {plan.dir}, {#plan.rooms - 2} rooms`)
				t.ok(insideSmall(plan, cx, cz), "inside the town")
				t.eq(blockAt(city, plan.x, plan.y, plan.z), B.BunkerHatch, "the hatch")
				for y = plan.floor, plan.y - 1 do
					t.eq(blockAt(city, plan.x, y, plan.z), B.Ladder, "the ladder")
				end
				climbsOut(function(bx: number, by: number, bz: number): number
					return blockAt(city, bx, by, bz)
				end, plan, "a small town's shed's bunker")
				local mismatches = 0
				for _, c in bordersOf(plan) do
					mismatches += (borderMismatches(city, c[1], c[2]))
				end
				t.eq(mismatches, 0, "border cells that disagree")
			end
			local p, q = plans[1].bounds, plans[2].bounds
			t.ok(not (p[1] <= q[4] and p[4] >= q[1] and p[3] <= q[6] and p[6] >= q[3]), "apart")
			caches[city] = nil
		end)
		Cities.new = new
		if not ok then
			error(err, 0)
		end
	end)

	t.test("bunkers: a lone shed 10-14 blocks inside a town's north edge: 3-5 rooms, all on the far side", function()
		-- Towns of D's three sizes (half 1-3: R = 35, 67, 99), a shed alone in every lot of the
		-- outer northern row at every middle cell (3-8 into the lot) in core columns, 10-14
		-- blocks inside the north edge (an outer lot starts 7 in; core rows only). No corridor
		-- heads south, so the rooms go to the corridor's south side, and a drawn sixth room never
		-- fits there (the header and the README's Limitations give these counts: 411 sheds, 93
		-- with 3 rooms, 193 with 4, 125 with 5).
		local rooms: { [number]: number } = {}
		local sheds, k = 0, 0
		local lo, hi = Config.Bunkers.Rooms[1], Config.Bunkers.Rooms[2]
		for half = 1, 3 do
			local R = 32 * half + 3
			for pu = 0, 2 * half - 1 do
				for _, inLot in { 7, 20 } do
					for d = 10, 14 do
						k += 1
						local cx, cz = -7000 + 1009 * k, 5000 + 331 * k
						local z = cz - R + d
						for along = 3, 8 do
							local x = cx - R + 32 * pu + inLot + along
							if x % SIZE < 2 or x % SIZE > SIZE - 3 or z % SIZE < 2 or z % SIZE > SIZE - 3 then
								continue
							end
							sheds += 1
							local plan = shedBunker(smallTowns({ { cx, cz } }, { x, z }, R), x, z)
							if plan == nil then
								t.ok(false, `R {R}: the shed {x - cx} {z - cz} gets no bunker`)
								continue
							end
							local n = #plan.rooms - 2
							rooms[n] = (rooms[n] or 0) + 1
							t.ok(n >= lo and n < hi, `R {R}: the shed {x - cx} {z - cz} keeps 3-5 rooms ({n})`)
							t.ok(plan.dir ~= "North", "its corridor heads east or west")
							local corridor = plan.rooms[2].inner
							local far = true
							for i = 3, #plan.rooms do
								far = far and plan.rooms[i].inner[3] > corridor[6]
							end
							t.ok(far, `R {R}: the shed {x - cx} {z - cz}'s rooms all south of its corridor`)
						end
					end
				end
			end
		end
		local parts = {}
		for n = 2, hi do
			table.insert(parts, `{n}: {rooms[n] or 0}`)
		end
		print(`    {sheds} sheds; rooms {table.concat(parts, ", ")}`)
		t.ok(sheds > 300, "sheds tried")
		for n = lo, hi - 1 do
			t.ok((rooms[n] or 0) > 0, `some with {n} rooms`)
		end
	end)

	--[[ Frequency, yields, cost ]]

	t.test("bunkers: 0.25-0.7 per km² (wild) over 8 km squares on three seeds", function()
		local R = 4000
		local overrun, all = 0, 0
		for _, seed in { SEED, 777, 2024 } do
			local fresh = TerrainGenerator.new(seed)
			local count = 0
			for _, plan in (fresh.bunkers :: any)(-R, -R, R - 1, R - 1) do
				if plan.x >= -R and plan.x < R and plan.z >= -R and plan.z < R then
					count += 1
					all += 1
					overrun += if plan.overrun then 1 else 0
				end
			end
			local perKm2 = count / (2 * R / 1000) ^ 2
			print(`    seed {seed}: {count} bunkers in 64 km²: {string.format("%.2f", perKm2)} per km²`)
			t.ok(perKm2 >= 0.25 and perKm2 <= 0.7, `seed {seed}: {perKm2} per km²`)
		end
		t.ok(overrun > 0 and overrun < all / 3, `overrun ones: {overrun} of {all}`)
	end)

	t.test("bunkers: a cold plan search yields every PAUSE lookups and runs at most a slice between yields", function()
		-- Counted: a column's height, river or surface cave one lookup, a `blocked` or
		-- `mineshafts` query PAUSE (they decide lakes, puddles and mineshafts, and are handed the
		-- yield too).
		local PAUSE = Bunkers.PAUSE
		local work, most, yields, handed, mineshafts = 0, 0, 0, 0, 0
		local function spend(n: number)
			work += n
			most = math.max(most, work)
		end
		local function yield()
			yields += 1
			work = 0
		end
		local terrain = {
			height = function(x: number, z: number): number
				spend(1)
				return (gen.column(x, z))
			end,
			biome = function(): number
				return 1
			end,
			river = function(): number
				spend(1)
				return 0
			end,
			blocked = function(_: number, _: number, _: number, _: number, y: (() -> ())?): { number }
				spend(PAUSE)
				if y then
					handed += 1
				end
				return {}
			end,
			spawn = function(): (number, number)
				return SPAWN[1], SPAWN[2]
			end,
			carvesTop = function(): boolean
				spend(1)
				return false
			end,
			mineshafts = function(_: number, _: number, _: number, _: number, y: (() -> ())?): { number }
				spend(PAUSE)
				if y then
					mineshafts += 1
				end
				return {}
			end,
		}
		local counted = Bunkers.new(SEED, terrain :: any)
		for k, plan in list do
			if k > 8 then
				break
			end
			work = 0
			counted.plans(plan.x - 1, plan.z - 1, plan.x + 1, plan.z + 1, yield)
		end
		print(`    {counted.built()} plans built: {yields} yields, at most {most} lookups between two (PAUSE {PAUSE})`)
		t.ok(counted.built() >= 8, "plans built")
		t.ok(most <= PAUSE + 16, `lookups between two yields: {most}`)
		t.ok(handed > 0, "blocked is handed the yield")
		t.ok(mineshafts > 0, "mineshafts.boxes is handed the yield")
		-- Timed, on the generator's own terrain (its lakes, puddles and mineshafts worked out cold,
		-- the yield handed to mineshafts.boxes): the longest stretch between two yields of a fresh
		-- generator's searches over the bunkers' cells (the spawn found first: every planner asks
		-- for it), the least of three fresh runs (a busy machine's spikes aside).
		local worst = math.huge
		local searched = 0
		for _ = 1, 3 do
			local fresh = TerrainGenerator.new(SEED)
			fresh.findSpawn()
			local longest, last = 0, os.clock()
			local function timed()
				local now = os.clock()
				longest = math.max(longest, now - last)
				last = now
			end
			for k, plan in list do
				if k > 6 then
					break
				end
				last = os.clock();
				(fresh.bunkers :: any)(plan.x, plan.z, plan.x, plan.z, timed)
				timed()
				searched += 1
			end
			worst = math.min(worst, longest)
		end
		print(string.format("    %d cold searches: the longest stretch between yields %.2f ms", searched, worst * 1000))
		t.ok(worst <= Config.Workers.SliceBudgetMs / 1000, `longest stretch {worst * 1000} ms`)
	end)

	t.test("bunkers: cost (full detail chunks over them, far nodes; warm and from cold generators)", function()
		-- The same world with and without bunkers: full detail chunks over the two nearest, and far
		-- nodes (levels 1 and 2: they only ask for the collars), the generators in turn, each first
		-- every other round, the best round of each kept (a busy machine slows both alike). Warm:
		-- the same two generators every round (what a chunk costs once its plans are known: the
		-- writing). Cold: two fresh generators every round (each also decides its lakes, puddles
		-- and mineshafts there from nothing), so the bunkers' plan searches are paid in the chunks.
		local function nearChunks(g: any): number
			local s = os.clock()
			for _, c in both do
				g.generate(0, c[1], c[2])
			end
			return (os.clock() - s) / #both
		end
		local farCount = 0
		local function far(g: any): number
			local s = os.clock()
			local n = 0
			for level = 1, 2 do
				local span = SIZE * 2 ^ level
				for _, plan in near do
					local b = plan.bounds
					for nz = b[3] // span, b[6] // span do
						for nx = b[1] // span, b[4] // span do
							g.generate(level, nx, nz)
							n += 1
						end
					end
				end
			end
			farCount = n
			return (os.clock() - s) / n
		end
		local function pair(): (any, any)
			local with = TerrainGenerator.new(SEED)
			Config.Bunkers.Enabled = false
			local without = TerrainGenerator.new(SEED)
			Config.Bunkers.Enabled = true
			return with, without
		end
		-- The best of `rounds` (fresh: a new pair each round) of `measure` with and without.
		local function best(rounds: number, fresh: boolean, measure: (g: any) -> number): (number, number)
			local with, without = pair()
			local w, n = math.huge, math.huge
			for round = 1, rounds do
				if fresh and round > 1 then
					with, without = pair()
				end
				if round % 2 == 1 then
					w = math.min(w, measure(with))
					n = math.min(n, measure(without))
				else
					n = math.min(n, measure(without))
					w = math.min(w, measure(with))
				end
			end
			return w, n
		end
		local nw, nn = best(6, false, nearChunks)
		local fw, fn = best(6, false, far)
		local cw, cn = best(4, true, nearChunks)
		local cfw, cfn = best(4, true, far)
		print(
			string.format(
				"    %d full detail chunks: %.2f ms with bunkers, %.2f ms without (bound %.2f); cold %.2f ms, %.2f ms (bound %.2f)",
				#both,
				nw * 1000,
				nn * 1000,
				(nn * 1.15 + 0.002) * 1000,
				cw * 1000,
				cn * 1000,
				(cn * 1.15 + 0.002) * 1000
			)
		)
		print(
			string.format(
				"    %d far nodes: %.2f ms with, %.2f ms without (bound %.2f); cold %.2f ms, %.2f ms (+%.2f ms: the two plan searches)",
				farCount,
				fw * 1000,
				fn * 1000,
				(fn * 1.05 + 0.0005) * 1000,
				cfw * 1000,
				cfn * 1000,
				(cfw - cfn) * 1000
			)
		)
		t.ok(nw <= nn * 1.15 + 0.002, "full detail: x1.15 + 2 ms")
		t.ok(cw <= cn * 1.15 + 0.002, "full detail from cold generators: x1.15 + 2 ms")
		t.ok(fw <= fn * 1.05 + 0.0005, "far nodes: x1.05 + 0.5 ms")
	end)

	t.test("bunkers: cold plan lookups against plain chunks", function()
		-- As tests/spec/Mineshafts: a fresh generator (the spawn found first) looks up each plan at
		-- its hatch (building every cell whose hatches may reach it: one, two by a cell's side),
		-- against a plain full detail chunk made by another fresh generator (no structures)
		-- between two lookups, so a busy machine slows both alike; then the cells the hash keeps
		-- whose search finds no site (seas, mountains, towns), looked up at their middle. A
		-- search decides the mineshafts and surface caves around its hatch (each about half a
		-- plain chunk cold): about a chunk and a quarter in all, its worst a few chunks.
		local fresh = TerrainGenerator.new(SEED)
		fresh.findSpawn()
		local unit = TerrainGenerator.new(SEED, { structures = false })
		local times: { number } = {}
		local chunkTimes: { number } = {}
		local function plain(x: number, z: number)
			local s = os.clock()
			unit.generate(0, x // SIZE + 3, z // SIZE)
			table.insert(chunkTimes, (os.clock() - s) * 1000)
		end
		for k, plan in list do
			if k > 24 then
				break
			end
			local s = os.clock();
			(fresh.bunkers :: any)(plan.x, plan.z, plan.x, plan.z)
			table.insert(times, (os.clock() - s) * 1000)
			plain(plan.x, plan.z)
		end
		local grid = cfg.Grid
		local salt = Hash.hash2(SEED, Hash.string("bunkers"), 0xB0)
		local have: { [string]: boolean } = {}
		local WIDE = 4000
		for _, plan in (gen.bunkers :: any)(-WIDE, -WIDE, WIDE, WIDE) do
			have[`{plan.x // grid},{plan.z // grid}`] = true
		end
		local failing: { number } = {}
		for gz = -WIDE // grid + 1, WIDE // grid - 1 do
			for gx = -WIDE // grid + 1, WIDE // grid - 1 do
				local kept = Hash.rng(Hash.hash3(salt, gx, 0, gz)):float() < cfg.Chance
				if kept and not have[`{gx},{gz}`] and #failing < 12 then
					local x, z = gx * grid + grid // 2, gz * grid + grid // 2
					local s = os.clock();
					(fresh.bunkers :: any)(x, z, x, z)
					table.insert(failing, (os.clock() - s) * 1000)
					plain(x, z)
				end
			end
		end
		table.sort(times)
		table.sort(chunkTimes)
		table.sort(failing)
		local median, worst = times[#times // 2 + 1], math.max(times[#times], failing[#failing] or 0)
		local chunkMedian = chunkTimes[#chunkTimes // 2 + 1]
		print(
			string.format(
				"    %d lookups at a plan: median %.2f ms, worst %.2f ms; %d kept cells with no site: median %.2f ms, worst %.2f ms; a plain chunk %.2f ms",
				#times,
				median,
				times[#times],
				#failing,
				failing[#failing // 2 + 1] or 0,
				failing[#failing] or 0,
				chunkMedian
			)
		)
		t.ok(#failing > 0, "kept cells with no site looked up")
		t.ok(median < chunkMedian * 2, "a plan search in less than two plain chunks' time (median)")
		t.ok(worst < chunkMedian * 10, "the worst in less than 10 plain chunks' time")
	end)

	t.test("bunkers: plain chunks spread over the world cost the same (levels 0-4, fresh generators)", function()
		-- 3 x 3 groups of chunks (a streamed view's patch) at spots hashed over 12 km, not chosen
		-- near bunkers, each round by a fresh generator (the spawn found first) with and without
		-- bunkers, the generators in turn: the median chunk (the best round's) within x1.05 +
		-- 0.5 ms at every level. The mean also pays the plan searches of the cells first met
		-- (every group meets new ones here: a streamed view meets each cell once and spreads it
		-- over its 2304 full detail chunks, 144 level 2 nodes).
		local GROUPS, G = 12, 3
		for level = 0, 4 do
			local rng = Hash.rng(Hash.hash2(99, level, 7))
			local span = SIZE * 2 ^ level
			local spots = {}
			for _ = 1, GROUPS do
				table.insert(spots, { rng:int(-6000, 6000) // span, rng:int(-6000, 6000) // span })
			end
			local function run(enabled: boolean): (number, number)
				Config.Bunkers.Enabled = enabled
				local g = TerrainGenerator.new(SEED)
				Config.Bunkers.Enabled = true
				g.findSpawn()
				local times: { number } = {}
				local total = 0
				for _, spot in spots do
					for dz = 0, G - 1 do
						for dx = 0, G - 1 do
							local s = os.clock()
							g.generate(level, spot[1] + dx, spot[2] + dz)
							local dt = os.clock() - s
							total += dt
							table.insert(times, dt)
						end
					end
				end
				table.sort(times)
				return times[#times // 2 + 1], total / #times
			end
			local wm, nm, wa, na = math.huge, math.huge, math.huge, math.huge
			for round = 1, 4 do
				for _, enabled in (if round % 2 == 1 then { true, false } else { false, true }) do
					local m, a = run(enabled)
					if enabled then
						wm, wa = math.min(wm, m), math.min(wa, a)
					else
						nm, na = math.min(nm, m), math.min(na, a)
					end
				end
			end
			print(
				string.format(
					"    level %d (%d chunks): median %.2f ms with bunkers, %.2f ms without (bound %.2f); mean %.2f ms, %.2f ms (%+.0f%%)",
					level,
					GROUPS * G * G,
					wm * 1000,
					nm * 1000,
					(nm * 1.05 + 0.0005) * 1000,
					wa * 1000,
					na * 1000,
					(wa / na - 1) * 100
				)
			)
			t.ok(wm <= nm * 1.05 + 0.0005, `level {level}: the median chunk within x1.05 + 0.5 ms`)
		end
	end)

	--[[ The debug structures world ]]

	t.test("debug structures: the sample bunker, every kind of room, its loot, ladder and hatch", function()
		local world = DebugWorlds.allStructures(SEED)
		local samples = (world :: any).bunkers(-100000, -100000, 100000, 100000)
		t.eq(#samples, 1, "one sample")
		local plan = samples[1]
		local kinds: { [string]: boolean } = {}
		for _, room in plan.rooms do
			kinds[room.kind] = true
		end
		for _, kind in { "airlock", "corridor", "bunks", "storage", "medical", "generator", "armory", "mess" } do
			t.ok(kinds[kind], `a {kind}`)
		end
		t.ok(plan.lit and not plan.overrun, "lit, not overrun")
		t.eq(plan.y, DebugWorlds.FLOOR, "the hatch on the floor")
		local function get(x: number, y: number, z: number): number
			local r = world.generate(0, x // SIZE, z // SIZE)
			return if y < r.height then ChunkLayout.get(r.data, x % SIZE, y, z % SIZE) else AIR
		end
		t.eq(get(plan.x, plan.y, plan.z), B.BunkerHatch, "the hatch")
		for y = plan.floor, plan.y - 1 do
			t.eq(get(plan.x, y, plan.z), B.Ladder, `the ladder at {y}`)
		end
		climbsOut(function(x: number, y: number, z: number): number
			return blockAt(world, x, y, z)
		end, plan, "the sample")
		local n: { [number]: number } = {}
		local b = plan.bounds
		for z = b[3], b[6] do
			for x = b[1], b[4] do
				for y = plan.floor, plan.floor + 3 do
					local id = get(x, y, z)
					n[id] = (n[id] or 0) + 1
				end
			end
		end
		for _, name in { "SupplyCrate", "Chest", "MedicineCabinet", "Furnace", "CraftingTable", "WhiteWool", "Planks" } do
			t.ok((n[B[name]] or 0) > 0, `a {name}`)
		end
		t.ok((n[Blocks.caveTwinFor(B.CeilingLamp) :: number] or 0) > 0, "lamps")
		for _, room in plan.rooms do
			local cs = room.containers
			for i = 1, #cs, 5 do
				t.ok(world.structureContainer(cs[i], cs[i + 1], cs[i + 2]) ~= nil, "a container's loot")
			end
		end
		local listed = false
		for _, thing in (world.locateList :: any)() do
			if thing.id == "bunker" and thing.x == plan.x and thing.z == plan.z then
				listed = true
			end
		end
		t.ok(listed, "/locate lists it")
		caches[world] = nil
	end)

	-- (Relief is required for the fake's types only.)
	local _ = Relief
end
