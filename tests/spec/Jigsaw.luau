--[[
	Structures/Transform and Structures/Jigsaw: rotation and mirror maths, canAttach, rigid
	chains, rotations, Minecraft's free space rules (no overlaps, children inside parents, the
	max distance box), depth limits and fallback pools, empty elements, terrain matching y, the
	start piece (heightmap projection, start jigsaw), the jigsaw's Generate button, writing pieces
	(rotation, final states, keep), weighted draws, the work cap on wasteful data, determinism,
	and a 7 deep village of 30+ pieces (timed).

	Templates are built in memory (the Template table filled directly), so these tests do not
	depend on the IVS1 codec.
]]
return function(t, shared, require)
	local Blocks = require(shared.Blocks)
	local Transform = require(shared.Structures.Transform)
	local Jigsaw = require(shared.Structures.Jigsaw)

	local id = Blocks.id
	local AIR = Blocks.AIR
	local STONE = id.Stone
	local PLANKS = rawget(id, "Planks") or id.Stone
	local COBBLE = id.Cobblestone
	local DIRS = { "North", "East", "South", "West" }

	--[[ Building templates in memory ]]

	type JigsawSpec = { number | string }

	-- A template of sx × sy × sz; `fill(x, y, z)` gives a block id or nil (keep). `jigsaws`:
	-- { x, y, z, front, top, name, target, pool, finalState?, joint? }.
	local function template(name: string, sx: number, sy: number, sz: number, fill: any, jigsaws: { any }?): any
		local palette = {}
		local index = {}
		local cells = buffer.create(sx * sy * sz * 2)
		for y = 0, sy - 1 do
			for z = 0, sz - 1 do
				for x = 0, sx - 1 do
					local block = if type(fill) == "function" then fill(x, y, z) else fill
					if block ~= nil then
						local p = index[block]
						if p == nil then
							table.insert(palette, block)
							p = #palette
							index[block] = p
						end
						buffer.writeu16(cells, ((y * sz + z) * sx + x) * 2, p)
					end
				end
			end
		end
		local list = {}
		for _, j in jigsaws or {} do
			table.insert(list, {
				x = j[1],
				y = j[2],
				z = j[3],
				front = j[4],
				top = j[5],
				name = j[6],
				target = j[7],
				pool = j[8],
				finalState = j[9] or "Air",
				joint = j[10] or (if j[4] == "Up" or j[4] == "Down" then "rollable" else "aligned"),
			})
		end
		return {
			name = name,
			size = { sx, sy, sz },
			palette = palette,
			cells = cells,
			jigsaws = list,
			markers = {},
			containers = {},
		}
	end

	local function library(templates: { any }, pools: { any })
		local byName = {}
		for _, tp in templates do
			byName[tp.name] = tp
		end
		local byPool = {}
		for _, p in pools do
			byPool[p.name] = p
		end
		return function(name)
			return byPool[name]
		end, function(name)
			return byName[name]
		end
	end

	local function element(name: string?, weight: number?, projection: string?)
		return { template = name, weight = weight or 1, projection = projection or "rigid" }
	end

	local function flat(height: number)
		return function(_x: number, _z: number): number
			return height
		end
	end

	local function overlaps(a: { number }, b: { number }): boolean
		return a[1] <= b[4] and a[4] >= b[1] and a[2] <= b[5] and a[5] >= b[2] and a[3] <= b[6] and a[6] >= b[3]
	end

	local function within(inner: { number }, outer: { number }): boolean
		return inner[1] >= outer[1]
			and inner[2] >= outer[2]
			and inner[3] >= outer[3]
			and inner[4] <= outer[4]
			and inner[5] <= outer[5]
			and inner[6] <= outer[6]
	end

	local function noOverlaps(pieces: { any }, allowInside: boolean?)
		for i = 1, #pieces do
			for j = i + 1, #pieces do
				local a, b = pieces[i].box, pieces[j].box
				if overlaps(a, b) then
					local nested = allowInside and (within(a, b) or within(b, a))
					t.ok(nested, `pieces {i} ({pieces[i].template}) and {j} ({pieces[j].template}) overlap`)
				end
			end
		end
	end

	-- World position and direction of jigsaw `j` of a placed piece.
	local function worldJigsaw(piece: any, tp: any, j: any): (number, number, number, string, string)
		local x, y, z = Transform.position(j.x, j.y, j.z, tp.size[1], tp.size[3], piece.rotation)
		return piece.x + x,
			piece.y + y,
			piece.z + z,
			Transform.direction(j.front, piece.rotation),
			Transform.direction(j.top, piece.rotation)
	end

	-- Every child is attached to a jigsaw of an earlier piece: some jigsaw of the child sits right
	-- in front of a jigsaw of another piece and canAttach holds.
	local function connected(pieces: { any }, getTemplate: any, rigidOnly: boolean): boolean
		for i = 2, #pieces do
			local child = pieces[i]
			local ct = getTemplate(child.template)
			local found = false
			for k = 1, #pieces do
				if k ~= i and not found then
					local parent = pieces[k]
					local pt = getTemplate(parent.template)
					for _, pj in pt.jigsaws do
						local px, py, pz, pf, ptop = worldJigsaw(parent, pt, pj)
						local o = Transform.OFFSETS[pf]
						for _, cj in ct.jigsaws do
							local cx, cy, cz, cf, ctop = worldJigsaw(child, ct, cj)
							local yOk = cy == py + o[2] or not rigidOnly
							if cx == px + o[1] and yOk and cz == pz + o[3] then
								if
									Jigsaw.canAttach(
										{ front = pf, top = ptop, name = pj.name, target = pj.target, joint = pj.joint },
										{ front = cf, top = ctop, name = cj.name, target = cj.target, joint = cj.joint }
									)
								then
									found = true
								end
							end
						end
					end
				end
			end
			if not found then
				return false
			end
		end
		return true
	end

	--[[ Transform ]]

	t.test("Transform: one quarter turn maps (x, z) to (sz - 1 - z, x) and swaps the size", function()
		local x, y, z = Transform.position(1, 2, 0, 4, 3, 1)
		t.eq(x, 2, "x")
		t.eq(y, 2, "y")
		t.eq(z, 1, "z")
		local sx, sy, sz = Transform.size(4, 5, 3, 1)
		t.eq(sx, 3, "turned width")
		t.eq(sy, 5, "height")
		t.eq(sz, 4, "turned depth")
		t.eq(Transform.direction("North", 1), "East")
		t.eq(Transform.direction("North", 2), "South")
		t.eq(Transform.direction("North", 3), "West")
		t.eq(Transform.direction("West", 1), "North")
		t.eq(Transform.direction("Up", 3), "Up")
		t.eq(Transform.direction("North", 0, "leftRight"), "South")
		t.eq(Transform.direction("East", 0, "leftRight"), "East")
		t.eq(Transform.direction("East", 0, "frontBack"), "West")
		-- Mirror first, then turn: North -> (leftRight) South -> (1 turn) West.
		t.eq(Transform.direction("North", 1, "leftRight"), "West")
	end)

	t.test("Transform: positions stay in the turned box, invert, and turn with directions", function()
		for _, size in { { 1, 1, 1 }, { 4, 2, 3 }, { 7, 3, 5 }, { 2, 1, 9 } } do
			local sx, sy, sz = size[1], size[2], size[3]
			for rotation = 0, 3 do
				for _, mirror in Transform.MIRRORS do
					local tx, _, tz = Transform.size(sx, sy, sz, rotation)
					local seen = {}
					for x = 0, sx - 1 do
						for z = 0, sz - 1 do
							local px, py, pz = Transform.position(x, 1, z, sx, sz, rotation, mirror)
							t.ok(px >= 0 and px < tx and pz >= 0 and pz < tz, "inside the turned box")
							t.eq(py, 1, "y kept")
							local key = px * 100 + pz
							t.ok(not seen[key], "one to one")
							seen[key] = true
							local ix, _, iz = Transform.inverse(px, 1, pz, sx, sz, rotation, mirror)
							t.eq(ix, x, "inverse x")
							t.eq(iz, z, "inverse z")
							-- The neighbour in direction d turns into the neighbour in d turned.
							for _, d in DIRS do
								local o = Transform.OFFSETS[d]
								local nx, nz = x + o[1], z + o[3]
								if nx >= 0 and nx < sx and nz >= 0 and nz < sz then
									local qx, _, qz = Transform.position(nx, 1, nz, sx, sz, rotation, mirror)
									local turned = Transform.OFFSETS[Transform.direction(d, rotation, mirror)]
									t.eq(qx - px, turned[1], `{d} turned x`)
									t.eq(qz - pz, turned[3], `{d} turned z`)
								end
							end
						end
					end
				end
			end
		end
	end)

	t.test("Transform: anchor matches Minecraft's pivot-0 turn", function()
		-- CLOCKWISE_90 with pivot 0: (x, z) -> (-z, x); the box spans x in [-(sz - 1), 0].
		local dx, dz = Transform.anchor(4, 3, 1)
		t.eq(dx, -2, "x")
		t.eq(dz, 0, "z")
		dx, dz = Transform.anchor(4, 3, 2)
		t.eq(dx, -3)
		t.eq(dz, -2)
		dx, dz = Transform.anchor(4, 3, 3)
		t.eq(dx, 0)
		t.eq(dz, -3)
		dx, dz = Transform.anchor(4, 3, 0, "leftRight")
		t.eq(dx, 0)
		t.eq(dz, -2)
		local box = Transform.box(10, 20, 30, 4, 2, 3, 1)
		t.eq(table.concat(box, ","), "10,20,30,12,21,33", "turned box")
	end)

	--[[ canAttach ]]

	t.test("canAttach: facing each other, same top unless rollable, target = name", function()
		local a = { front = "East", top = "Up", name = "x", target = "door", joint = "aligned" }
		t.ok(Jigsaw.canAttach(a, { front = "West", top = "Up", name = "door", target = "x" }), "matching")
		t.ok(not Jigsaw.canAttach(a, { front = "East", top = "Up", name = "door", target = "x" }), "same front")
		t.ok(not Jigsaw.canAttach(a, { front = "North", top = "Up", name = "door", target = "x" }), "sideways")
		t.ok(not Jigsaw.canAttach(a, { front = "West", top = "Up", name = "window", target = "x" }), "wrong name")
		local up = { front = "Up", top = "North", name = "x", target = "y", joint = "aligned" }
		t.ok(Jigsaw.canAttach(up, { front = "Down", top = "North", name = "y", target = "" }), "aligned, same top")
		t.ok(not Jigsaw.canAttach(up, { front = "Down", top = "East", name = "y", target = "" }), "aligned top")
		local roll = { front = "Up", top = "North", name = "x", target = "y", joint = "rollable" }
		t.ok(Jigsaw.canAttach(roll, { front = "Down", top = "East", name = "y", target = "" }), "rollable")
		-- Default joint: rollable for vertical fronts, aligned for horizontal ones.
		local default = { front = "Up", top = "North", name = "x", target = "y" }
		t.ok(Jigsaw.canAttach(default, { front = "Down", top = "West", name = "y", target = "" }), "vertical default")
		-- Only the source's joint counts.
		t.ok(
			not Jigsaw.canAttach(
				{ front = "Down", top = "East", name = "y", target = "x", joint = "aligned" },
				{ front = "Up", top = "North", name = "x", target = "y", joint = "rollable" }
			),
			"source aligned"
		)
	end)

	--[[ Assembly ]]

	-- A straight corridor along X with a jigsaw at each end, both "a" -> "a" in pool "corridor".
	local corridor = template("test/corridor", 5, 3, 3, STONE, {
		{ 0, 1, 1, "West", "Up", "a", "a", "corridor" },
		{ 4, 1, 1, "East", "Up", "a", "a", "corridor" },
	})
	local cap = template("test/cap", 1, 3, 3, COBBLE, {
		{ 0, 1, 1, "West", "Up", "a", "", "empty" },
	})

	t.test("rigid chain: corridors line up end to end, at the parent's height, one per side per level", function()
		local pool, get = library({ corridor }, { { name = "corridor", elements = { element("test/corridor") } } })
		for _, depth in { 0, 1, 3, 5 } do
			local pieces = Jigsaw.assemble({
				seed = 7,
				startPool = "corridor",
				x = 100,
				z = -40,
				projectToHeightmap = true,
				firstFreeHeight = flat(64),
				maxDepth = depth,
				pool = pool,
				template = get,
			})
			t.eq(#pieces, 1 + 2 * depth, `pieces at depth {depth}`)
			for _, p in pieces do
				-- Layer 0 on the ground's top layer: minY = 64 - 1.
				t.eq(p.y, 63, "rigid children keep the start's y")
				t.eq(p.box[2], 63)
				t.ok(p.depth <= depth, "depth")
			end
			noOverlaps(pieces)
			t.ok(connected(pieces, get, true), "every child is attached to a jigsaw")
			-- All on one line through the start piece.
			local start = pieces[1]
			local along = if start.rotation % 2 == 0 then 3 else 1
			for _, p in pieces do
				t.eq(p.box[along], start.box[along], "in line")
			end
		end
	end)

	t.test("rotations: a child turns until its jigsaw faces the source", function()
		-- The start's jigsaw faces North; the child's faces East in its template, so the child
		-- needs the turn that maps East to South (one quarter turn clockwise).
		local start = template("test/start", 3, 2, 3, STONE, { { 1, 1, 0, "North", "Up", "s", "c", "kids" } })
		local child = template("test/child", 4, 2, 2, PLANKS, { { 3, 0, 1, "East", "Up", "c", "s", "empty" } })
		local pool, get = library({ start, child }, {
			{ name = "starts", elements = { element("test/start") } },
			{ name = "kids", elements = { element("test/child") } },
		})
		for seed = 1, 20 do
			local pieces = Jigsaw.assemble({
				seed = seed,
				startPool = "starts",
				x = 0,
				z = 0,
				projectToHeightmap = false,
				startHeight = 10,
				firstFreeHeight = flat(0),
				maxDepth = 1,
				pool = pool,
				template = get,
			})
			t.eq(#pieces, 2, "start and child")
			local s, c = pieces[1], pieces[2]
			-- Without projection the start drops one block (Minecraft's groundLevelDelta).
			t.eq(s.y, 9, "start y")
			local sx, sy, sz, sf = worldJigsaw(s, start, start.jigsaws[1])
			local o = Transform.OFFSETS[sf]
			local cx, cy, cz, cf = worldJigsaw(c, child, child.jigsaws[1])
			t.eq(cx, sx + o[1], "child jigsaw x")
			t.eq(cy, sy, "child jigsaw y (rigid, horizontal)")
			t.eq(cz, sz + o[3], "child jigsaw z")
			t.eq(cf, Transform.OPPOSITE[sf], "facing the source")
			t.eq(c.rotation, (s.rotation + 1) % 4, "one more quarter turn than the start")
			t.ok(not overlaps(s.box, c.box), "no overlap")
		end
	end)

	t.test("vertical jigsaws: rigid children stack one block up, rollable joints ignore tops", function()
		local base = template("test/base", 3, 3, 3, STONE, { { 1, 2, 1, "Up", "North", "up", "down", "tops" } })
		local top = template("test/top", 3, 2, 3, PLANKS, { { 1, 0, 1, "Down", "East", "down", "up", "empty" } })
		local pool, get = library({ base, top }, {
			{ name = "bases", elements = { element("test/base") } },
			{ name = "tops", elements = { element("test/top") } },
		})
		local pieces = Jigsaw.assemble({
			seed = 3,
			startPool = "bases",
			x = 5,
			z = 5,
			projectToHeightmap = true,
			firstFreeHeight = flat(30),
			maxDepth = 2,
			pool = pool,
			template = get,
		})
		t.eq(#pieces, 2, "the top attaches (rollable source)")
		t.eq(pieces[2].y, pieces[1].y + 3, "right above")
		-- With an aligned source the tops must match: the child turns so its top matches.
		-- (Templates are immutable once used: a new one.)
		local aligned = template(
			"test/aligned",
			3,
			3,
			3,
			STONE,
			{ { 1, 2, 1, "Up", "North", "up", "down", "tops", "Air", "aligned" } }
		)
		pool, get = library({ aligned, top }, {
			{ name = "bases", elements = { element("test/aligned") } },
			{ name = "tops", elements = { element("test/top") } },
		})
		local again = Jigsaw.assemble({
			seed = 3,
			startPool = "bases",
			x = 5,
			z = 5,
			projectToHeightmap = true,
			firstFreeHeight = flat(30),
			maxDepth = 2,
			pool = pool,
			template = get,
		})
		t.eq(#again, 2, "aligned still attaches by turning")
		local _, _, _, _, sourceTop = worldJigsaw(again[1], aligned, aligned.jigsaws[1])
		local _, _, _, _, childTop = worldJigsaw(again[2], top, top.jigsaws[1])
		t.eq(childTop, sourceTop, "tops aligned")
	end)

	t.test("free space: children inside a parent stay inside it; too big ones are refused", function()
		-- A hall whose jigsaw points into itself; the alcove must fit in what is left of the hall.
		local hall = template("test/hall", 9, 5, 11, AIR, {
			{ 4, 1, 1, "South", "Up", "in", "alcove", "alcoves" },
			{ 4, 1, 9, "North", "Up", "in", "alcove", "alcoves" },
		})
		local alcove = template("test/alcove", 3, 3, 3, PLANKS, { { 1, 1, 0, "North", "Up", "alcove", "", "empty" } })
		local wide = template("test/wide", 11, 3, 3, PLANKS, { { 5, 1, 0, "North", "Up", "alcove", "", "empty" } })
		local narrowHall = template("test/hall2", 9, 5, 11, AIR, {
			{ 4, 1, 1, "South", "Up", "in", "alcove", "wides" },
			{ 4, 1, 9, "North", "Up", "in", "alcove", "wides" },
		})
		local pool, get = library({ hall, alcove, wide, narrowHall }, {
			{ name = "halls", elements = { element("test/hall") } },
			{ name = "halls2", elements = { element("test/hall2") } },
			{ name = "alcoves", elements = { element("test/alcove") } },
			{ name = "wides", elements = { element("test/wide") } },
		})
		local options = {
			seed = 11,
			startPool = "halls",
			x = 0,
			z = 0,
			projectToHeightmap = true,
			firstFreeHeight = flat(10),
			maxDepth = 3,
			pool = pool,
			template = get,
		}
		local pieces = Jigsaw.assemble(options)
		t.eq(#pieces, 3, "both alcoves")
		for i = 2, 3 do
			t.ok(within(pieces[i].box, pieces[1].box), "alcove inside the hall")
		end
		noOverlaps({ pieces[2], pieces[3] })
		-- 11 wide does not fit in a 9 wide hall, although the world outside is empty.
		options.startPool = "halls2"
		local refused = Jigsaw.assemble(options)
		t.eq(#refused, 1, "too wide for the hall")
	end)

	t.test("free space: pieces stay within the start's centre ± maxDistance", function()
		local pool, get = library({ corridor }, { { name = "corridor", elements = { element("test/corridor") } } })
		local pieces = Jigsaw.assemble({
			seed = 5,
			startPool = "corridor",
			x = 0,
			z = 0,
			projectToHeightmap = true,
			firstFreeHeight = flat(20),
			maxDepth = 7,
			maxDistance = 12,
			pool = pool,
			template = get,
		})
		-- Centre x 2 (or z 2), so ±12 holds the start and 2 corridors each side (5 wide each).
		t.eq(#pieces, 5, "chain cut by the distance box")
		local s = pieces[1].box
		local cx, cz = (s[1] + s[4]) // 2, (s[3] + s[6]) // 2
		for _, p in pieces do
			t.ok(p.box[1] >= cx - 12 and p.box[4] <= cx + 12, "x within")
			t.ok(p.box[3] >= cz - 12 and p.box[6] <= cz + 12, "z within")
		end
	end)

	t.test("depth limits: below maxDepth the pool, at maxDepth only the fallback (end caps)", function()
		local pool, get = library({ corridor, cap }, {
			{ name = "corridor", fallback = "caps", elements = { element("test/corridor") } },
			{ name = "caps", elements = { element("test/cap") } },
		})
		local pieces = Jigsaw.assemble({
			seed = 99,
			startPool = "corridor",
			x = 0,
			z = 0,
			projectToHeightmap = true,
			firstFreeHeight = flat(5),
			maxDepth = 2,
			pool = pool,
			template = get,
		})
		local corridors, caps = 0, 0
		for _, p in pieces do
			if p.template == "test/corridor" then
				corridors += 1
				t.ok(p.depth <= 2, "corridor depth")
			else
				caps += 1
				t.eq(p.depth, 3, "caps come from the fallback at max depth")
			end
		end
		t.eq(corridors, 5, "1 + 2 per level")
		t.eq(caps, 2, "both ends capped")
		noOverlaps(pieces)
		t.ok(connected(pieces, get, true), "attached")
		-- maxDepth 0: the start alone, no fallback either (Minecraft's size 0).
		local alone = Jigsaw.assemble({
			seed = 99,
			startPool = "corridor",
			x = 0,
			z = 0,
			projectToHeightmap = true,
			firstFreeHeight = flat(5),
			maxDepth = 0,
			pool = pool,
			template = get,
		})
		t.eq(#alone, 1, "start only")
	end)

	t.test("empty elements: an empty start gives nothing; an empty candidate stops the jigsaw", function()
		local hopeful = template("test/hopeful", 5, 3, 3, STONE, {
			{ 0, 1, 1, "West", "Up", "a", "a", "mostlyEmpty" },
			{ 4, 1, 1, "East", "Up", "a", "a", "mostlyEmpty" },
		})
		local pool, get = library({ corridor, hopeful }, {
			{ name = "nothing", elements = { element(nil, 1) } },
			{ name = "hopeful", elements = { element("test/hopeful", 1) } },
			{ name = "mostlyEmpty", elements = { element(nil, 150), element("test/corridor", 1) } },
		})
		local none = Jigsaw.assemble({
			seed = 1,
			startPool = "nothing",
			x = 0,
			z = 0,
			projectToHeightmap = true,
			firstFreeHeight = flat(5),
			maxDepth = 3,
			pool = pool,
			template = get,
		})
		t.eq(#none, 0, "empty start element")
		-- Jigsaws pointing at a pool that is almost always empty: mostly no children.
		local total = 0
		for seed = 1, 50 do
			total += #Jigsaw.assemble({
				seed = seed,
				startPool = "hopeful",
				x = 0,
				z = 0,
				projectToHeightmap = true,
				firstFreeHeight = flat(5),
				maxDepth = 3,
				pool = pool,
				template = get,
			})
		end
		t.ok(total < 60, `empty elements win by weight ({total} pieces over 50 starts)`)
	end)

	t.test("missing pools are skipped with one warning each; 'empty' is silent", function()
		local lonely = template("test/lonely", 3, 1, 3, STONE, {
			{ 0, 0, 1, "West", "Up", "a", "a", "nowhere" },
			{ 2, 0, 1, "East", "Up", "a", "a", "nowhere" },
			{ 1, 0, 0, "North", "Up", "a", "a", "empty" },
			{ 1, 0, 2, "South", "Up", "a", "a", "minecraft:empty" },
		})
		local pool, get = library({ lonely }, { { name = "lonely", elements = { element("test/lonely") } } })
		local warnings = {}
		local pieces = Jigsaw.assemble({
			seed = 1,
			startPool = "lonely",
			x = 0,
			z = 0,
			projectToHeightmap = true,
			firstFreeHeight = flat(5),
			maxDepth = 2,
			pool = pool,
			template = get,
			warn = function(message)
				table.insert(warnings, message)
			end,
		})
		t.eq(#pieces, 1, "start only")
		t.eq(#warnings, 1, "one warning")
		t.eq(warnings[1], "Empty or non-existent pool: nowhere")
	end)

	t.test("terrain matching: children sit on the ground at the source jigsaw's column", function()
		-- Ground rising one block every 2 blocks east.
		local function ground(x: number, _z: number): number
			return 40 + x // 2
		end
		local plaza = template("test/plaza", 5, 2, 5, STONE, { { 4, 1, 2, "East", "Up", "p", "path", "paths" } })
		local path = template("test/path", 6, 1, 3, COBBLE, {
			{ 0, 0, 1, "West", "Up", "path", "p", "empty" },
			{ 5, 0, 1, "East", "Up", "path", "path", "paths" },
		})
		local pool, get = library({ plaza, path }, {
			{ name = "plazas", elements = { element("test/plaza") } },
			{ name = "paths", elements = { element("test/path", 1, "terrain_matching") } },
		})
		local pieces = Jigsaw.assemble({
			seed = 4,
			startPool = "plazas",
			x = 0,
			z = 0,
			projectToHeightmap = true,
			firstFreeHeight = ground,
			maxDepth = 3,
			pool = pool,
			template = get,
		})
		t.ok(#pieces >= 2, "paths attached")
		local s = pieces[1]
		t.eq(s.y, ground((s.box[1] + s.box[4]) // 2, 0) - 1, "start: layer 0 on the ground at its centre")
		for i = 2, #pieces do
			local p = pieces[i]
			t.eq(p.projection, "terrain_matching")
			-- Find its parent's jigsaw: the cell in front of its own West jigsaw (turned).
			local pt = get(p.template)
			local found = false
			for k = 1, #pieces do
				local parent = pieces[k]
				local partT = get(parent.template)
				for _, pj in partT.jigsaws do
					local jx, jy, jz, jf = worldJigsaw(parent, partT, pj)
					local o = Transform.OFFSETS[jf]
					for _, cj in pt.jigsaws do
						local cx, _, cz = worldJigsaw(p, pt, cj)
						if k ~= i and cx == jx + o[1] and cz == jz + o[3] and cj.name == pj.target then
							found = true
							-- Its jigsaw's y is the ground at the source's column.
							t.eq(p.y + cj.y, ground(jx, jz), "child jigsaw on the ground")
							local _ = jy
						end
					end
				end
			end
			t.ok(found, "path attached to a jigsaw")
		end
		-- Writing: every column of a terrain matching piece follows the ground (y = h - 1 + ly).
		local p = pieces[2]
		local b = p.box
		for x = b[1], b[4] do
			for z = b[3], b[6] do
				t.eq(Jigsaw.baseY(p, ground(x, z)), ground(x, z) - 1, "base y")
				t.eq(Jigsaw.blockAt(p, path, x, ground(x, z) - 1, z, ground) ~= nil, true, "path on the ground")
				t.eq(Jigsaw.blockAt(p, path, x, ground(x, z), z, ground), nil, "nothing above the path")
			end
		end
	end)

	t.test("start: startJigsawName puts that jigsaw on the start position", function()
		local hub = template("test/hub", 7, 3, 5, STONE, {
			{ 3, 0, 0, "North", "Up", "anchor", "", "empty" },
			{ 6, 1, 2, "East", "Up", "door", "x", "empty" },
		})
		local pool, get = library({ hub }, { { name = "hubs", elements = { element("test/hub") } } })
		for seed = 1, 12 do
			local pieces = Jigsaw.assemble({
				seed = seed,
				startPool = "hubs",
				startJigsawName = "anchor",
				x = 32,
				z = 48,
				projectToHeightmap = true,
				startHeight = 2,
				firstFreeHeight = flat(70),
				maxDepth = 0,
				pool = pool,
				template = get,
			})
			t.eq(#pieces, 1)
			local p = pieces[1]
			local jx, jy, jz = worldJigsaw(p, hub, hub.jigsaws[1])
			t.eq(jx, 32, "anchor x")
			t.eq(jz, 48, "anchor z")
			-- minY + 1 = startHeight + firstFreeHeight(centre).
			t.eq(p.y, 2 + 70 - 1, "projected")
			t.eq(jy, p.y, "anchor on layer 0")
		end
		local warnings = {}
		local missing = Jigsaw.assemble({
			seed = 1,
			startPool = "hubs",
			startJigsawName = "nope",
			x = 0,
			z = 0,
			projectToHeightmap = true,
			firstFreeHeight = flat(70),
			maxDepth = 0,
			pool = pool,
			template = get,
			warn = function(m)
				table.insert(warnings, m)
			end,
		})
		t.eq(#missing, 0, "no start jigsaw, no structure")
		t.eq(warnings[1], "No starting jigsaw nope found in start pool hubs")
	end)

	t.test("generateFrom: the Generate button attaches to the world jigsaw and grows `levels` deep", function()
		local pool, get = library({ corridor, cap }, {
			{ name = "corridor", fallback = "caps", elements = { element("test/corridor") } },
			{ name = "caps", elements = { element("test/cap") } },
		})
		local source = { x = 10, y = 50, z = 10, front = "East", top = "Up", pool = "corridor", target = "a" }
		for _, levels in { 0, 1, 3 } do
			local pieces = Jigsaw.generateFrom({
				seed = 123,
				source = source,
				levels = levels,
				firstFreeHeight = flat(0),
				pool = pool,
				template = get,
			})
			local first = pieces[1]
			t.ok(first ~= nil, "a first piece")
			t.eq(first.depth, 0, "depth 0")
			-- Its West jigsaw (turned) right in front of the source, at the same y.
			local ok = false
			for _, j in corridor.jigsaws do
				local x, y, z, f = worldJigsaw(first, corridor, j)
				if x == 11 and y == 50 and z == 10 and f == "West" then
					ok = true
				end
			end
			t.ok(ok, "attached to the source")
			t.ok(first.box[1] == 11, "east of the source")
			-- The chain only grows away from the source: levels corridors, then a cap.
			t.eq(#pieces, if levels == 0 then 1 else levels + 2, `pieces for {levels} levels`)
			noOverlaps(pieces)
		end
		local warnings = {}
		local nothing = Jigsaw.generateFrom({
			seed = 1,
			source = { x = 0, y = 0, z = 0, front = "East", top = "Up", pool = "corridor", target = "zzz" },
			levels = 2,
			firstFreeHeight = flat(0),
			pool = pool,
			template = get,
			warn = function(m)
				table.insert(warnings, m)
			end,
		})
		t.eq(#nothing, 0, "no jigsaw named zzz")
		t.eq(#warnings, 1, "explained")
	end)

	t.test("writing: rotated blocks, final states, keep cells", function()
		local torch = id.WallTorchNorth
		-- A 3 × 1 × 2 piece: a north facing wall torch at (0, 0, 0), a void (keep) at (2, 0, 1), a
		-- jigsaw at (1, 0, 0) whose final state is cobblestone.
		local jigsawBlock = if Blocks.jigsawBlock then Blocks.jigsawBlock("North", "Up") else STONE
		local piece = template("test/write", 3, 1, 2, function(x, _y, z)
			if x == 0 and z == 0 then
				return torch
			elseif x == 2 and z == 1 then
				return nil
			elseif x == 1 and z == 0 then
				return jigsawBlock
			end
			return PLANKS
		end, { { 1, 0, 0, "North", "Up", "j", "", "empty", "minecraft:cobblestone" } })
		for rotation = 0, 3 do
			local sx, sy, sz = Transform.size(3, 1, 2, rotation)
			local p = {
				template = "test/write",
				x = 100,
				y = 7,
				z = -3,
				rotation = rotation,
				projection = "rigid",
				depth = 0,
				box = Transform.box(100, 7, -3, 3, 1, 2, rotation),
			}
			t.eq(p.box[4] - p.box[1] + 1, sx)
			t.eq(p.box[6] - p.box[3] + 1, sz)
			t.eq(sy, 1)
			local function at(lx: number, lz: number): number?
				local x, _, z = Transform.position(lx, 0, lz, 3, 2, rotation)
				return Jigsaw.blockAt(p, piece, 100 + x, 7, -3 + z, flat(0))
			end
			t.eq(at(0, 0), Blocks.rotate(torch, rotation, "none"), "torch turned")
			t.eq(Blocks.get(at(0, 0) :: number).name, "WallTorch" .. Transform.direction("North", rotation))
			t.eq(at(2, 1), nil, "keep")
			t.eq(at(1, 0), COBBLE, "final state")
			t.eq(at(1, 1), PLANKS, "plain block")
			t.eq(Jigsaw.blockAt(p, piece, 100 - 1, 7, -3, flat(0)), nil, "outside")
			t.eq(Jigsaw.blockAt(p, piece, 100, 8, -3, flat(0)), nil, "above")
			-- keepJigsaws leaves the jigsaw (turned).
			local x, _, z = Transform.position(1, 0, 0, 3, 2, rotation)
			t.eq(
				Jigsaw.blockAt(p, piece, 100 + x, 7, -3 + z, flat(0), true),
				Blocks.rotate(jigsawBlock, rotation, "none"),
				"kept jigsaw"
			)
			local count = 0
			Jigsaw.eachBlock(p, piece, flat(0), function(wx, wy, wz, block)
				count += 1
				t.eq(Jigsaw.blockAt(p, piece, wx, wy, wz, flat(0)), block, "eachBlock agrees")
			end)
			t.eq(count, 5, "every cell but the void")
			-- writeTables gives the same blocks for hot loops.
			local palette, finals = Jigsaw.writeTables(p, piece)
			for ly = 0, 0 do
				for lz = 0, 1 do
					for lx = 0, 2 do
						local index = (ly * 2 + lz) * 3 + lx
						local v = buffer.readu16(piece.cells, index * 2)
						local final = finals[index]
						local block = if v == 0
							then nil
							elseif final then (if final < 0 then nil else final)
							else palette[v]
						t.eq(block, Jigsaw.cellBlock(p, piece, lx, ly, lz), "writeTables")
					end
				end
			end
		end
		t.eq(Jigsaw.finalStateBlock("Air"), AIR)
		t.eq(Jigsaw.finalStateBlock("minecraft:stone_bricks"), id.StoneBricks)
		t.eq(Jigsaw.finalStateBlock("no such block"), AIR, "unknown: air")
	end)

	--[[ A village ]]

	-- Plains-village style: a rigid centre, terrain matching streets (straights, a crossing) with
	-- side jigsaws for houses, rigid houses of several sizes, and terminators as the streets'
	-- fallback. `dense`: four house jigsaws per street instead of two (a stress case).
	local function village(dense: boolean?)
		local list = {}
		local function add(tp)
			table.insert(list, tp)
			return tp
		end
		add(template("v/centre", 9, 6, 9, STONE, {
			{ 4, 0, 0, "North", "Up", "street", "street", "v/streets" },
			{ 4, 0, 8, "South", "Up", "street", "street", "v/streets" },
			{ 0, 0, 4, "West", "Up", "street", "street", "v/streets" },
			{ 8, 0, 4, "East", "Up", "street", "street", "v/streets" },
		}))
		for _, length in { 9, 13, 17 } do
			-- A street along Z: ends North and South, house doors East and West halfway.
			local jigsaws = {
				{ 1, 0, 0, "North", "Up", "street", "street", "v/streets" },
				{ 1, 0, length - 1, "South", "Up", "street", "street", "v/streets" },
				{ 0, 0, length // 2, "West", "Up", "side", "door", "v/houses" },
				{ 2, 0, length // 2, "East", "Up", "side", "door", "v/houses" },
			}
			if dense then
				table.insert(jigsaws, { 0, 0, 2, "West", "Up", "side", "door", "v/houses" })
				table.insert(jigsaws, { 2, 0, length - 3, "East", "Up", "side", "door", "v/houses" })
			end
			add(template(`v/streets/straight_{length}`, 3, 1, length, COBBLE, jigsaws))
		end
		add(template("v/streets/crossing", 7, 1, 7, COBBLE, {
			{ 3, 0, 0, "North", "Up", "street", "street", "v/streets" },
			{ 3, 0, 6, "South", "Up", "street", "street", "v/streets" },
			{ 0, 0, 3, "West", "Up", "street", "street", "v/streets" },
			{ 6, 0, 3, "East", "Up", "street", "street", "v/streets" },
		}))
		add(template("v/ends/plain", 3, 1, 1, COBBLE, { { 1, 0, 0, "North", "Up", "street", "", "empty" } }))
		for i, size in { { 5, 5, 5 }, { 7, 5, 6 }, { 9, 7, 7 }, { 5, 4, 7 }, { 11, 6, 9 } } do
			-- A house whose door jigsaw is on its north side, facing north.
			add(template(`v/houses/house_{i}`, size[1], size[2], size[3], PLANKS, {
				{ size[1] // 2, 1, 0, "North", "Up", "door", "", "empty" },
			}))
		end
		local pools = {
			{ name = "v/centres", elements = { element("v/centre") } },
			{
				name = "v/streets",
				fallback = "v/ends",
				elements = {
					element("v/streets/straight_9", 4, "terrain_matching"),
					element("v/streets/straight_13", 3, "terrain_matching"),
					element("v/streets/straight_17", 2, "terrain_matching"),
					element("v/streets/crossing", 2, "terrain_matching"),
				},
			},
			{ name = "v/ends", elements = { element("v/ends/plain", 1, "terrain_matching") } },
			{
				name = "v/houses",
				elements = {
					element("v/houses/house_1", 4),
					element("v/houses/house_2", 3),
					element("v/houses/house_3", 2),
					element("v/houses/house_4", 3),
					element("v/houses/house_5", 1),
					element(nil, 3),
				},
			},
		}
		return list, pools
	end

	local function hills(x: number, z: number): number
		return 64 + math.floor(4 * math.sin(x / 23) + 3 * math.cos(z / 17))
	end

	t.test("village: 7 deep, 30+ pieces, no overlaps, every piece within the distance box", function()
		for _, dense in { false, true } do
			local templates, pools = village(dense)
			local pool, get = library(templates, pools)
			local counts = {}
			local worst = math.huge
			for seed = 1, 20 do
				local pieces = Jigsaw.assemble({
					seed = seed * 7919,
					startPool = "v/centres",
					x = 1024,
					z = -512,
					projectToHeightmap = true,
					firstFreeHeight = hills,
					maxDepth = 7,
					pool = pool,
					template = get,
					warn = function(m: string)
						t.ok(false, `no warning expected: {m}`)
					end,
				})
				table.insert(counts, #pieces)
				worst = math.min(worst, #pieces)
				-- Children never overlap: houses and streets each take their own space.
				noOverlaps(pieces)
				t.ok(connected(pieces, get, false), "every piece attached")
				local s = pieces[1].box
				local cx, cz = (s[1] + s[4]) // 2, (s[3] + s[6]) // 2
				for _, p in pieces do
					t.ok(p.box[1] >= cx - 80 and p.box[4] <= cx + 80, "x within 80")
					t.ok(p.box[3] >= cz - 80 and p.box[6] <= cz + 80, "z within 80")
					t.ok(p.depth <= 8, "depth")
				end
			end
			table.sort(counts)
			local kind = if dense then "dense village" else "village"
			print(`    {kind} pieces over 20 seeds: min {counts[1]}, median {counts[10]}, max {counts[20]}`)
			t.ok(worst >= 20, `at least 20 pieces (worst {worst})`)
			t.ok(counts[10] >= 30, `median 30+ pieces ({counts[10]})`)
		end
	end)

	t.test("robustness: bad seeds, malformed jigsaws and runaway structures never error", function()
		local odd = template("test/odd", 3, 2, 3, STONE, {
			{ 1, 1, 0, "North", "Up", "a", "a", "corridor" },
			{ 1.5, 1, 2, "South", "Up", "a", "a", "corridor" },
			{ 1, 1, 2, "Sideways", "Up", "a", "a", "corridor" },
		})
		table.insert(odd.jigsaws, { x = 0, y = 0, z = 1, front = "West", top = "Up" } :: any)
		local pool, get = library({ odd, corridor }, {
			{ name = "odd", elements = { element("test/odd") } },
			{ name = "corridor", elements = { element("test/corridor") } },
		})
		for _, seed in { 0 / 0, math.huge, -math.huge, 2 ^ 60, -7.5 } do
			local pieces = Jigsaw.assemble({
				seed = seed,
				startPool = "odd",
				x = 0,
				z = 0,
				projectToHeightmap = true,
				firstFreeHeight = flat(10),
				maxDepth = 2,
				pool = pool,
				template = get,
			})
			t.ok(#pieces >= 1, "assembled")
		end
		-- Only the well formed jigsaw (1, 1, 0) grows a corridor (and corridors grow on).
		local pieces = Jigsaw.assemble({
			seed = 1,
			startPool = "odd",
			x = 0,
			z = 0,
			projectToHeightmap = true,
			firstFreeHeight = flat(10),
			maxDepth = 1,
			pool = pool,
			template = get,
		})
		t.eq(#pieces, 2, "one usable jigsaw")
		-- The piece cap stops an assembly, with a warning.
		local templates, pools = village()
		local vpool, vget = library(templates, pools)
		local saved = Jigsaw.MAX_PIECES
		Jigsaw.MAX_PIECES = 10
		local warnings = {}
		local capped = Jigsaw.assemble({
			seed = 1,
			startPool = "v/centres",
			x = 0,
			z = 0,
			projectToHeightmap = true,
			firstFreeHeight = hills,
			maxDepth = 7,
			pool = vpool,
			template = vget,
			warn = function(m)
				table.insert(warnings, m)
			end,
		})
		Jigsaw.MAX_PIECES = saved
		t.eq(#capped, 10, "capped")
		t.eq(warnings[1], "Assembly stopped at 10 pieces: the structure is too big")
	end)

	t.test("robustness: work that leads nowhere counts, so wasteful data stops early", function()
		-- A slab whose top is covered in jigsaws pointing at a big pool where nothing has their
		-- target's name, and side jigsaws chaining more slabs (within every template limit). Each
		-- top jigsaw draws the whole pool and tries each element in 4 rotations; that work used to
		-- go uncounted (seconds of a frozen server for the Generate button at 7 levels).
		local templates = {}
		local waste = {}
		for i = 1, 255 do
			local tp = template(`w/{i}`, 1, 1, 1, STONE)
			table.insert(templates, tp)
			table.insert(waste, element(tp.name))
		end
		local jigsaws: { any } = {
			{ 8, 0, 0, "North", "Up", "link", "link", "g" },
			{ 8, 0, 15, "South", "Up", "link", "link", "g" },
			{ 0, 0, 8, "West", "Up", "link", "link", "g" },
			{ 15, 0, 8, "East", "Up", "link", "link", "g" },
		}
		for x = 0, 15 do
			for z = 0, 15 do
				table.insert(jigsaws, { x, 1, z, "Up", "North", "x", "nothing-matches", "w" })
			end
		end
		table.insert(
			templates,
			template("g/slab", 16, 2, 16, function(_x: number, y: number): number?
				return if y == 0 then STONE else nil
			end, jigsaws)
		)
		local pool, get = library(templates, {
			{ name = "w", elements = waste },
			{ name = "g", elements = { element("g/slab") } },
		})
		local lookups, heights = 0, 0
		local function run(warnings: { string }): { any }
			return Jigsaw.generateFrom({
				seed = 1,
				source = { x = 0, y = 64, z = 0, front = "North", top = "Up", pool = "g", target = "link" },
				levels = 7,
				firstFreeHeight = function(_x: number, _z: number): number
					heights += 1
					return 64
				end,
				pool = pool,
				template = function(name: string): any
					lookups += 1
					return get(name)
				end,
				warn = function(m: string)
					table.insert(warnings, m)
				end,
			})
		end
		local warnings = {}
		local t0 = os.clock()
		local pieces = run(warnings)
		local ms = (os.clock() - t0) * 1000
		print(string.format("    wasteful slabs: %d pieces, %d candidates tried, %.0f ms", #pieces, lookups, ms))
		t.ok(#pieces >= 1, "the first slab still attaches")
		t.eq(warnings[1], `Assembly stopped at {#pieces} pieces: the structure is too big`)
		-- Each candidate tried costs at least itself and its 4 rotations, so the budget bounds them
		-- (it used to try ~6.7 million here).
		t.ok(lookups <= Jigsaw.MAX_WORK / 5, `candidates tried are bounded ({lookups})`)
		t.ok(heights <= Jigsaw.MAX_WORK / Jigsaw.HEIGHT_WORK + 1, "height reads are bounded")
		-- The cut is part of the result: the same data stops at the same place everywhere.
		local again = run({})
		t.eq(#again, #pieces, "deterministic")
		for i, p in pieces do
			t.eq(table.concat(again[i].box, ","), table.concat(p.box, ","), "same pieces")
		end

		-- Ground reads count too: terrain matching slabs read the ground for every jigsaw.
		local reads = 0
		local terrainPool, terrainGet = library(templates, {
			{ name = "w", elements = waste },
			{ name = "g", elements = { element("g/slab", 1, "terrain_matching") } },
		})
		Jigsaw.generateFrom({
			seed = 1,
			source = { x = 0, y = 64, z = 0, front = "North", top = "Up", pool = "g", target = "link" },
			levels = 7,
			firstFreeHeight = function(x: number, z: number): number
				reads += 1
				return 64 + (x + z) % 3
			end,
			pool = terrainPool,
			template = terrainGet,
		})
		t.ok(reads <= Jigsaw.MAX_WORK / Jigsaw.HEIGHT_WORK + 1, `ground reads are bounded ({reads})`)
	end)

	t.test("weighted order: candidates are drawn by weight without replacement", function()
		-- 37 elements weighing 1..7; only every third has a jigsaw that fits the source, so the
		-- first piece is the first of those drawn: each with probability weight / their total.
		local templates, elements = {}, {}
		local weights: { [string]: number } = {}
		local fitting = 0
		for i = 1, 37 do
			local name = `o/{i}`
			local fits = i % 3 == 0
			table.insert(
				templates,
				template(name, 1, 1, 1, STONE, if fits then { { 0, 0, 0, "West", "Up", "a", "", "empty" } } else {})
			)
			local w = i % 7 + 1
			table.insert(elements, element(name, w))
			if fits then
				weights[name] = w
				fitting += w
			end
		end
		local pool, get = library(templates, { { name = "o", elements = elements } })
		local counts: { [string]: number } = {}
		local runs = 2000
		for seed = 1, runs do
			local first = Jigsaw.generateFrom({
				seed = seed,
				source = { x = 0, y = 64, z = 0, front = "East", top = "Up", pool = "o", target = "a" },
				levels = 0,
				firstFreeHeight = flat(64),
				pool = pool,
				template = get,
			})[1]
			counts[first.template] = (counts[first.template] or 0) + 1
		end
		for name, w in weights do
			local expected = runs * w / fitting
			local got = counts[name] or 0
			t.ok(math.abs(got - expected) <= 4 * math.sqrt(expected) + 5, `{name}: {got} for ~{expected}`)
		end
		for name in counts do
			t.ok(weights[name] ~= nil, `only fitting elements attach ({name})`)
		end
	end)

	t.test("determinism: same options, same pieces; other seeds differ", function()
		local templates, pools = village()
		local pool, get = library(templates, pools)
		local function run(seed: number): string
			local parts = {}
			for _, p in
				Jigsaw.assemble({
					seed = seed,
					startPool = "v/centres",
					x = 0,
					z = 0,
					projectToHeightmap = true,
					firstFreeHeight = hills,
					maxDepth = 7,
					pool = pool,
					template = get,
				})
			do
				table.insert(parts, `{p.template}@{table.concat(p.box, ",")}r{p.rotation}d{p.depth}`)
			end
			return table.concat(parts, ";")
		end
		t.eq(run(42), run(42), "same seed")
		-- Fresh template tables (no cached data) give the same result.
		local templates2, pools2 = village()
		local pool2, get2 = library(templates2, pools2)
		local again = {}
		for _, p in
			Jigsaw.assemble({
				seed = 42,
				startPool = "v/centres",
				x = 0,
				z = 0,
				projectToHeightmap = true,
				firstFreeHeight = hills,
				maxDepth = 7,
				pool = pool2,
				template = get2,
			})
		do
			table.insert(again, `{p.template}@{table.concat(p.box, ",")}r{p.rotation}d{p.depth}`)
		end
		t.eq(table.concat(again, ";"), run(42), "fresh templates")
		local differ = 0
		for seed = 43, 52 do
			if run(seed) ~= run(42) then
				differ += 1
			end
		end
		t.ok(differ >= 9, "other seeds give other villages")
	end)

	t.test("village assembly time", function()
		for _, dense in { false, true } do
			local templates, pools = village(dense)
			local pool, get = library(templates, pools)
			local heightCalls = 0
			local function counted(x: number, z: number): number
				heightCalls += 1
				return hills(x, z)
			end
			local runs = 200
			local pieces = 0
			local slowest = 0
			local t0 = os.clock()
			for seed = 1, runs do
				local s = os.clock()
				pieces += #Jigsaw.assemble({
					seed = seed,
					startPool = "v/centres",
					x = seed * 1000,
					z = 0,
					projectToHeightmap = true,
					firstFreeHeight = counted,
					maxDepth = 7,
					pool = pool,
					template = get,
				})
				slowest = math.max(slowest, os.clock() - s)
			end
			local ms = (os.clock() - t0) * 1000 / runs
			print(
				string.format(
					"    %s (7 deep): %.2f ms per assembly, slowest %.2f ms, %.1f pieces, %.1f height samples",
					if dense then "dense village" else "village",
					ms,
					slowest * 1000,
					pieces / runs,
					heightCalls / runs
				)
			)
			t.ok(ms < 20, "fast enough to assemble per worker")
		end
	end)
end
