--[[
	The underground fade's target (client Rendering/SkyExposure): the camera's depth under the
	natural ground, raised by open sky straight up (a pit) or a few blocks away (a tunnel into a
	hillside, stairs dug up to the surface, a quarry under an overhang), on small made-up worlds;
	and on generated surface caves: a cave entrance is lit at its mouth and darkens on the way
	down, a ravine's floor is under the open sky.
]]

return function(t, shared, require, _server, client)
	local Blocks = require(shared.Blocks)
	local Config = require(shared.Config)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Coords = require(shared.World.Coords)
	local DayCycle = require(shared.DayCycle)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)
	local SkyExposure = require(client.Rendering.SkyExposure)

	local STONE, AIR = Blocks.id.Stone, Blocks.AIR
	local SETTINGS = { Start = 4, End = 16 }

	-- A world from a natural ground height per column, with `dug` cells (keyed "x,y,z") made air
	-- and `placed` ones stone. Returns the ground and block readers.
	local function world(
		height: (x: number, z: number) -> number,
		dug: { [string]: boolean },
		placed: { [string]: boolean }?
	)
		local function ground(x: number, z: number): number
			return height(x, z)
		end
		local function getBlock(x: number, y: number, z: number): number?
			local key = `{x},{y},{z}`
			if placed and placed[key] then
				return STONE
			elseif dug[key] then
				return AIR
			end
			return if y < height(x, z) then STONE else AIR
		end
		return ground, getBlock
	end

	local function flat(level: number)
		return function(_x: number, _z: number): number
			return level
		end
	end

	-- Ground 64 for x < 0, a hill 100 high from x = 0 on.
	local function hillside(x: number, _z: number): number
		return if x < 0 then 64 else 100
	end

	-- A 1 x 2 tunnel along +x at feet height 64 (z = 0), `length` cells into the hill.
	local function tunnel(length: number): { [string]: boolean }
		local dug = {}
		for x = 0, length - 1 do
			dug[`{x},64,0`] = true
			dug[`{x},65,0`] = true
		end
		return dug
	end

	t.test("sky exposure: depth alone, and open sky straight up", function()
		local ground, getBlock = world(flat(64), {})
		t.eq(SkyExposure.target(0.5, 65.6, 0.5, ground, getBlock, SETTINGS), 1, "on the ground")
		t.eq(SkyExposure.target(0.5, 62, 0.5, ground, nil, SETTINGS), 1, "a little under it")
		t.near(
			SkyExposure.target(0.5, 54, 0.5, ground, nil, SETTINGS),
			DayCycle.skyExposure(10, 4, 16),
			1e-9,
			"without blocks only the depth counts"
		)
		-- A closed pocket 30 deep is dark.
		local pocket = {}
		for x = -1, 1 do
			for y = 33, 35 do
				for z = -1, 1 do
					pocket[`{x},{y},{z}`] = true
				end
			end
		end
		local pg, pb = world(flat(64), pocket)
		t.eq(SkyExposure.target(0.5, 34.6, 0.5, pg, pb, SETTINGS), 0, "a closed pocket")
		-- A shaft from the surface down to it: open to the sky.
		local shaft = table.clone(pocket)
		for y = 36, 63 do
			shaft[`0,{y},0`] = true
		end
		local sg, sb = world(flat(64), shaft)
		t.eq(SkyExposure.target(0.5, 34.6, 0.5, sg, sb, SETTINGS), 1, "under a shaft")
		t.eq(SkyExposure.target(1.5, 34.6, 0.5, sg, sb, SETTINGS), 1 - 1 / 16, "next to a shaft")
		-- Unknown blocks are rock.
		local unloaded = function(x: number, y: number, z: number): number?
			return if y >= 33 and y <= 35 then AIR else nil
		end
		t.eq(SkyExposure.target(0.5, 34.6, 0.5, pg, unloaded, SETTINGS), 0, "unloaded")
	end)

	t.test("sky exposure: a tunnel into a hillside fades with the distance from its mouth", function()
		local ground, getBlock = world(hillside, tunnel(40))
		local last = 2
		for depth = 0, 30 do
			local exposure = SkyExposure.target(depth + 0.5, 65.62, 0.5, ground, getBlock, SETTINGS)
			-- The first cell outside (x = -1) is depth + 1 blocks away.
			local expected = math.max(0, 1 - (depth + 1) / 16)
			t.near(exposure, expected, 1e-9, `{depth} blocks in`)
			t.ok(exposure <= last, `darker further in ({depth})`)
			last = exposure
		end
		-- Without the block data the hill's depth alone would make it dark at once.
		t.eq(SkyExposure.target(3.5, 65.62, 0.5, ground, nil, SETTINGS), 0, "depth alone")
		-- The mouth bricked up: dark.
		local closed = tunnel(40)
		local cg, cb = world(hillside, closed, { ["-1,64,0"] = true, ["-1,65,0"] = true })
		t.eq(SkyExposure.target(3.5, 65.62, 0.5, cg, cb, SETTINGS), 0, "a closed tunnel")
		t.ok(SkyExposure.target(3.5, 65.62, 0.5, ground, getBlock, SETTINGS) > 0.7, "the open one")
	end)

	t.test("sky exposure: stairs dug up to the surface, a quarry under an overhang", function()
		-- Stairs down into the hill: step x has its feet at 64 - x.
		local stairs = {}
		for x = 0, 20 do
			stairs[`{x},{64 - x},0`] = true
			stairs[`{x},{65 - x},0`] = true
		end
		local ground, getBlock = world(hillside, stairs)
		local exposure = SkyExposure.target(4.5, 61.62, 0.5, ground, getBlock, SETTINGS)
		t.near(exposure, 1 - 5 * math.sqrt(2) / 16, 1e-9, "the rising ray leaves at x = -1")
		t.eq(SkyExposure.target(14.5, 51.62, 0.5, ground, getBlock, SETTINGS), 0, "too far down")

		-- A quarry 20 deep with one stone block bridging it over the camera.
		local pit = {}
		for x = -5, 5 do
			for y = 44, 63 do
				for z = -5, 5 do
					pit[`{x},{y},{z}`] = true
				end
			end
		end
		local qg, qb = world(flat(64), pit, { ["0,60,0"] = true })
		t.eq(SkyExposure.target(0.5, 45.62, 0.5, qg, qb, SETTINGS), 1 - 1 / 16, "next to open sky")
		t.eq(SkyExposure.target(1.5, 45.62, 0.5, qg, qb, SETTINGS), 1, "under open sky")
	end)

	t.test("sky exposure: a closed cavern stays dark and the probe stays cheap", function()
		local cavern = {}
		for x = -30, 30 do
			for y = 100, 160 do
				for z = -30, 30 do
					cavern[`{x},{y},{z}`] = true
				end
			end
		end
		local ground, inner = world(flat(400), cavern)
		local reads = 0
		local function getBlock(x: number, y: number, z: number): number?
			reads += 1
			return inner(x, y, z)
		end
		t.eq(SkyExposure.target(0.5, 101.62, 0.5, ground, getBlock, SETTINGS), 0, "dark")
		-- The camera's own look up (to the ceiling), 16 rays of up to 16 cells, the sky budget.
		t.ok(reads < 62 + 16 * 16 + 2048 + 16, `{reads} blocks read`)
	end)

	--[[ Generated surface caves ]]

	local SIZE = Config.ChunkSize
	local DIRS = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }

	-- Generated full detail chunks: block and natural ground readers, and the generated surface.
	local function generated(gen: any)
		local chunks: { [number]: any } = {}
		local function chunk(x: number, z: number): any
			local key = Coords.chunkKey(x, z)
			local c = chunks[key]
			if c == nil then
				c = gen.generate(0, x, z, nil, true)
				chunks[key] = c
			end
			return c
		end
		local function getBlock(x: number, y: number, z: number): number?
			if y < 0 then
				return nil
			end
			local c = chunk(x // SIZE, z // SIZE)
			return if y >= c.height then AIR else ChunkLayout.get(c.data, x % SIZE, y, z % SIZE)
		end
		local function ground(x: number, z: number): number
			return (gen.column(x, z))
		end
		return chunk, getBlock, ground
	end

	t.test("sky exposure: a generated cave entrance is lit at its mouth and darkens on the way down", function()
		local gen = TerrainGenerator.new(12345)
		local chunk, getBlock, ground = generated(gen)
		-- The longest way down an entrance near chunk 0, 6: from carved air below the surface
		-- that touches cave air, breadth first through carved air to the open sky.
		local best: { { number } }? = nil
		for cz = 4, 8 do
			for cx = -3, 2 do
				local c = chunk(cx, cz)
				for z = 0, SIZE - 1 do
					for x = 0, SIZE - 1 do
						local top = buffer.readu16(c.surface, (z * SIZE + x) * 2)
						for y = math.max(c.solidBelow, 1), top - 1 do
							if ChunkLayout.get(c.data, x, y, z) ~= AIR then
								continue
							end
							local wx, wz = cx * SIZE + x, cz * SIZE + z
							local junction = false
							for _, d in DIRS do
								if getBlock(wx + d[1], y + d[2], wz + d[3]) == Blocks.CAVE_AIR then
									junction = true
								end
							end
							if not junction then
								continue
							end
							local from: { [string]: { number } | false } = { [`{wx},{y},{wz}`] = false }
							local queue = { { wx, y, wz } }
							local head = 1
							while head <= #queue and #queue < 20000 do
								local p = queue[head]
								head += 1
								if p[2] + 1 >= ground(p[1], p[3]) then
									local path = {}
									local q: { number }? = p
									while q do
										table.insert(path, q)
										q = from[`{q[1]},{q[2]},{q[3]}`] or nil
									end
									if best == nil or #path > #best then
										best = path
									end
									break
								end
								for _, d in DIRS do
									local nx, ny, nz = p[1] + d[1], p[2] + d[2], p[3] + d[3]
									local k = `{nx},{ny},{nz}`
									if from[k] == nil and getBlock(nx, ny, nz) == AIR and ny < ground(nx, nz) then
										from[k] = p
										table.insert(queue, { nx, ny, nz })
									end
								end
							end
						end
					end
				end
			end
		end
		assert(best and #best > 24, "a way down a cave entrance near chunk 0, 6")
		local path = best :: { { number } }
		local underground = Config.Lighting.Underground
		local values = {}
		for i, c in path do
			values[i] = SkyExposure.target(c[1] + 0.5, c[2] + 0.62, c[3] + 0.5, ground, getBlock, underground)
		end
		t.ok(values[1] >= 0.9 and values[2] >= 0.9, `lit at the mouth ({values[1]}, {values[2]})`)
		-- Deep down (as deep as the fade's End, as far from the mouth as that) it is dark.
		local deep = path[#path]
		local depth = ground(deep[1], deep[3]) - deep[2]
		t.ok(depth >= underground.End, `the entrance goes deep ({depth} blocks)`)
		t.ok(values[#path] <= 0.05, `dark where it meets the cave ({values[#path]})`)
		-- Darker on the way down: never brighter than anything a quarter of the way nearer.
		local quarter = math.max(1, #path // 4)
		for i = quarter + 1, #path do
			t.ok(values[i] <= values[i - quarter] + 1e-9, `step {i}: {values[i]} after {values[i - quarter]}`)
		end
		local half, dark = #path, #path
		for i = #path, 1, -1 do
			if values[i] < 0.5 then
				half = i
			end
			if values[i] <= 0 then
				dark = i
			end
		end
		print(
			string.format(
				"    entrance at %d,%d,%d, %d blocks down to %d deep: %.2f at the mouth, below half from block %d, dark from block %d, %.2f at the cave",
				path[1][1],
				path[1][2],
				path[1][3],
				#path,
				depth,
				values[1],
				half,
				dark,
				values[#path]
			)
		)
	end)

	t.test("sky exposure: the floor of a generated ravine is under the open sky", function()
		local gen = TerrainGenerator.new(12345)
		local chunk, getBlock, ground = generated(gen)
		local deepest, at = 0, nil
		for cz = -30, -24, 2 do
			for cx = 30, 38, 2 do
				local c = chunk(cx, cz)
				for z = 0, SIZE - 1 do
					for x = 0, SIZE - 1 do
						local top = buffer.readu16(c.surface, (z * SIZE + x) * 2)
						local y = top - 1
						while y > 0 and ChunkLayout.get(c.data, x, y, z) == AIR do
							y -= 1
						end
						if top - 1 - y > deepest then
							deepest, at = top - 1 - y, { cx * SIZE + x, y + 1, cz * SIZE + z }
						end
					end
				end
			end
		end
		assert(at and deepest >= 15, `a ravine near 540, -420 ({deepest} deep)`)
		local x, y, z = at[1] + 0.5, at[2] + 0.62, at[3] + 0.5
		t.eq(DayCycle.skyExposure(ground(at[1], at[3]) - y, 4, 16), 0, "deep enough to be dark by depth alone")
		t.eq(SkyExposure.target(x, y, z, ground, getBlock, Config.Lighting.Underground), 1, "full sky light")
	end)
end
