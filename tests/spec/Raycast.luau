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
end
