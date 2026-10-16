return function(t, shared, require)
	local VoxelRaycast = require(shared.World.VoxelRaycast)

	local solid: { [string]: number } = {}
	local function put(x: number, y: number, z: number)
		solid[`{x},{y},{z}`] = 1
	end
	local function get(x: number, y: number, z: number): number?
		return solid[`{x},{y},{z}`] or 0
	end
	local function isTarget(id: number): boolean
		return id ~= 0
	end

	put(5, 0, 0)
	put(-3, 2, -3)
	put(0, -4, 0)

	t.test("straight ray hits the first block and reports the face", function()
		local hit = VoxelRaycast.cast(0.5, 0.5, 0.5, 1, 0, 0, 20, get, isTarget)
		assert(hit)
		t.eq(hit.x, 5)
		t.eq(hit.nx, -1)
		t.near(hit.distance, 4.5, 1e-9)
	end)

	t.test("downwards and diagonal rays", function()
		local down = VoxelRaycast.cast(0.5, 3.2, 0.5, 0, -1, 0, 20, get, isTarget)
		assert(down)
		t.eq(down.y, -4)
		t.eq(down.ny, 1)
		local diag = VoxelRaycast.cast(0.5, 0.5, 0.5, -1, 0.5, -1, 20, get, isTarget)
		assert(diag)
		t.eq(diag.x, -3)
		t.eq(diag.z, -3)
	end)

	t.test("misses return nil and respect max distance", function()
		t.eq(VoxelRaycast.cast(0.5, 0.5, 0.5, 0, 1, 0, 50, get, isTarget), nil)
		t.eq(VoxelRaycast.cast(0.5, 0.5, 0.5, 1, 0, 0, 3, get, isTarget), nil)
	end)

	t.test("distance is cast's distance (random rays, outlines, axis rays, starts inside)", function()
		-- A random world in -6..6: whole blocks (1), small boxes (2: a torch's), two-box blocks
		-- (3: a pipe's core and an arm), air (0) and unloaded cells (nil) that rays pass.
		-- (Park and Miller's generator, exact in doubles: Lune has no Random.)
		local seed = 20261016
		local function uniform(lo: number, hi: number): number
			seed = seed * 16807 % 2147483647
			return lo + (hi - lo) * seed / 2147483647
		end
		local cells: { [number]: number } = {}
		local function index(x: number, y: number, z: number): number
			return (x + 8) * 400 + (y + 8) * 20 + (z + 8)
		end
		for x = -6, 6 do
			for y = -6, 6 do
				for z = -6, 6 do
					local roll = uniform(0, 1)
					if roll < 0.05 then
						cells[index(x, y, z)] = 1
					elseif roll < 0.08 then
						cells[index(x, y, z)] = 2
					elseif roll < 0.1 then
						cells[index(x, y, z)] = 3
					elseif roll < 0.12 then
						cells[index(x, y, z)] = 4
					elseif roll < 0.9 then
						cells[index(x, y, z)] = 0
					end
				end
			end
		end
		local function getBlock(x: number, y: number, z: number): number?
			if x < -6 or x > 6 or y < -6 or y > 6 or z < -6 or z > 6 then
				return nil
			end
			return cells[index(x, y, z)]
		end
		-- (4: a block nothing stops at.)
		local function stops(id: number): boolean
			return id ~= 0 and id ~= 4
		end
		local TORCH = { 0.4375, 0, 0.4375, 0.5625, 0.625, 0.5625 }
		local PIPE = { 0.3125, 0.3125, 0.3125, 0.6875, 0.6875, 0.6875, 0.3125, 0.6875, 0.3125, 0.6875, 1, 0.6875 }
		local function outline(id: number, _x: number, _y: number, _z: number): { number }?
			return if id == 2 then TORCH elseif id == 3 then PIPE else nil
		end
		local hits, misses, partial = 0, 0, 0
		for i = 1, 4000 do
			local ox, oy, oz = uniform(-5, 5), uniform(-5, 5), uniform(-5, 5)
			local dx, dy, dz = uniform(-1, 1), uniform(-1, 1), uniform(-1, 1)
			if i % 10 == 0 then
				-- Along an axis (the other two components exactly 0).
				local axis = i % 3
				dx, dy, dz = if axis == 0 then dx else 0, if axis == 1 then dy else 0, if axis == 2 then dz else 0
			end
			local max = uniform(0, 12)
			local useOutline = if i % 2 == 0 then outline else nil
			local hit = VoxelRaycast.cast(ox, oy, oz, dx, dy, dz, max, getBlock, stops, useOutline)
			local d = VoxelRaycast.distance(ox, oy, oz, dx, dy, dz, max, getBlock, stops, useOutline)
			if hit then
				hits += 1
				t.eq(d, hit.distance, `ray {i}: the same distance`)
				if hit.block ~= 1 then
					partial += 1
				end
			else
				misses += 1
				t.eq(d, nil, `ray {i}: a miss both ways`)
			end
		end
		t.ok(hits > 500 and misses > 500 and partial > 50, `hits {hits}, misses {misses}, outlines {partial}`)
		-- The fixed world's rays above, and the degenerate ones.
		t.near(VoxelRaycast.distance(0.5, 0.5, 0.5, 1, 0, 0, 20, get, isTarget) :: number, 4.5, 1e-9)
		t.eq(VoxelRaycast.distance(0.5, 0.5, 0.5, 1, 0, 0, 3, get, isTarget), nil, "beyond the max")
		t.eq(VoxelRaycast.distance(0.5, 0.5, 0.5, 0, 0, 0, 20, get, isTarget), nil, "no direction")
		t.eq(VoxelRaycast.distance(5.5, 0.5, 0.5, 0, 1, 0, 20, get, isTarget), 0, "starting inside a block")
	end)
end
