--[[
	Where the crosshair may aim with the camera over the shoulder (Interaction/TargetRules): the
	camera's ray starts at the eyes' plane (none skipped in first person, nor with the camera at the
	eyes); a camera at the eyes aims exactly as before (the ray VoxelRaycast always cast, nothing
	hidden, on random worlds and rays); over the shoulder a block seen past a pillar from the camera
	but not from the eyes picks the pillar, with its own face, a block's face the eyes can't see gives
	the face they do see, a mob (a point in the open) behind cover is hidden and one in view is not,
	the ray's end counts when it hits nothing, and a torch's box is passed beside; and the rules are
	pure.
]]

local fs = require("@lune/fs")

return function(t, shared, require, _server, client)
	local VoxelRaycast = require(shared.World.VoxelRaycast)
	local CameraRules = require(client.Player.CameraRules)
	local TargetRules = require(client.Interaction.TargetRules)

	local BLOCK = 3
	local AIR, STONE, TORCH = 0, 1, 2
	local TORCH_BOX = { 0.4, 0, 0.4, 0.6, 0.6, 0.6 }

	-- A small world of cells: world.set(x, y, z, id); world.get is VoxelRaycast's getBlock.
	local function newWorld()
		local cells: { [string]: number } = {}
		local world = {}
		function world.set(x: number, y: number, z: number, id: number)
			cells[`{x},{y},{z}`] = id
		end
		function world.get(x: number, y: number, z: number): number?
			return cells[`{x},{y},{z}`] or AIR
		end
		return world
	end
	local function isTarget(id: number): boolean
		return id ~= AIR
	end
	local function outline(id: number, _x: number, _y: number, _z: number): { number }?
		return if id == TORCH then TORCH_BOX else nil
	end

	local function unit(x: number, y: number, z: number): (number, number, number)
		local l = math.sqrt(x * x + y * y + z * z)
		return x / l, y / l, z / l
	end

	-- A seeded generator (Park and Miller's): random.next(lo, hi).
	local function newRandom(seed: number)
		local state = seed
		return {
			next = function(lo: number, hi: number): number
				state = state * 16807 % 2147483647
				return lo + (hi - lo) * state / 2147483647
			end,
		}
	end

	-- The camera's ray from C towards P, started at the eyes' plane: start, direction, skip and the
	-- distance from the start to P.
	local function rayTo(c: { number }, p: { number }, e: { number })
		local dx, dy, dz = unit(p[1] - c[1], p[2] - c[2], p[3] - c[3])
		local skip = TargetRules.skip(c[1], c[2], c[3], dx, dy, dz, e[1], e[2], e[3])
		local sx, sy, sz = c[1] + dx * skip, c[2] + dy * skip, c[3] + dz * skip
		local length = math.sqrt((p[1] - sx) ^ 2 + (p[2] - sy) ^ 2 + (p[3] - sz) ^ 2)
		return { sx = sx, sy = sy, sz = sz, dx = dx, dy = dy, dz = dz, skip = skip, length = length }
	end

	-- The scene of the Studio checklist: eyes at a body's, a camera over its right shoulder (1.5
	-- right, 1.6 behind), a pillar ahead-left of the body and a wall beyond it.
	local EYES = { 0.5, 1.62, 0.5 }
	local CAMERA = { 2.0, 1.72, 2.1 }
	local WALL_POINT = { -0.9, 1.62, -5 }
	local function scene(pillar: boolean, wall: boolean, pillarId: number?)
		local world = newWorld()
		if pillar then
			for y = 0, 2 do
				world.set(-1, y, -2, pillarId or STONE)
			end
		end
		if wall then
			for x = -6, 6 do
				for y = 0, 4 do
					world.set(x, y, -6, STONE)
				end
			end
		end
		return world
	end

	--[[ The start ]]

	t.test("target rules: the ray starts at the eyes' plane, none skipped in first person", function()
		-- The camera at the eyes (the rig off: CameraRig.eyes is the camera): nothing to skip.
		local random = newRandom(7)
		for _ = 1, 200 do
			local cx, cy, cz = random.next(-50, 50), random.next(0, 100), random.next(-50, 50)
			local dx, dy, dz = unit(random.next(-1, 1), random.next(-1, 1), random.next(-1, 1))
			t.eq(TargetRules.skip(cx, cy, cz, dx, dy, dz, cx, cy, cz), 0, "the camera at the eyes")
			-- The ray's start on the near plane, ahead of the camera along the ray: still none.
			local near = 0.1 / BLOCK
			t.eq(
				TargetRules.skip(cx + dx * near, cy + dy * near, cz + dz * near, dx, dy, dz, cx, cy, cz),
				0,
				"the near plane's start"
			)
			-- Rounding (a start a hair behind the eyes' plane) is no skip either.
			local hair = 1e-8
			t.eq(
				TargetRules.skip(cx - dx * hair, cy - dy * hair, cz - dz * hair, dx, dy, dz, cx, cy, cz),
				0,
				"rounding"
			)
		end
		-- First person (the rig): the camera ahead of the eyes (CameraRules.firstPersonEye), the
		-- centre ray along the look: the ray starts at the camera, as it always did.
		for _ = 1, 200 do
			local yaw = random.next(-math.pi, math.pi)
			local pitch = random.next(-math.rad(80), math.rad(80))
			local ex, ey, ez = random.next(-20, 20), random.next(0, 60), random.next(-20, 20)
			local fx, fy, fz = CameraRules.firstPersonEye(ex * BLOCK, ey * BLOCK, ez * BLOCK, yaw, pitch)
			local cx, cy, cz = fx / BLOCK, fy / BLOCK, fz / BLOCK
			-- (CFrame.fromEulerAnglesYXZ(pitch, yaw, 0).LookVector.)
			local lx, ly, lz = -math.sin(yaw) * math.cos(pitch), math.sin(pitch), -math.cos(yaw) * math.cos(pitch)
			t.eq(TargetRules.skip(cx, cy, cz, lx, ly, lz, ex, ey, ez), 0, "first person skips nothing")
		end
		-- Over the shoulder: the start moves to the eyes' plane.
		local ray = rayTo(CAMERA, WALL_POINT, EYES)
		t.ok(ray.skip > 1.5, "the camera behind the eyes skips to them")
		t.near(
			(ray.sx - EYES[1]) * ray.dx + (ray.sy - EYES[2]) * ray.dy + (ray.sz - EYES[3]) * ray.dz,
			0,
			1e-12,
			"the start is on the eyes' plane"
		)
		t.near(
			ray.skip,
			CameraRules.eyePlaneSkip(CAMERA[1], CAMERA[2], CAMERA[3], ray.dx, ray.dy, ray.dz, 0.5, 1.62, 0.5),
			0,
			"CameraRules' skip"
		)
	end)

	t.test("target rules: the eyes along the ray see what it hits", function()
		local dx, dy, dz = unit(1, -0.3, 0.2)
		t.ok(TargetRules.alongRay(1, 2, 3, dx, dy, dz, 1, 2, 3), "at the start")
		t.ok(TargetRules.alongRay(1, 2, 3, dx, dy, dz, 1 - dx * 0.5, 2 - dy * 0.5, 3 - dz * 0.5), "behind on its line")
		t.ok(TargetRules.alongRay(1, 2, 3, dx, dy, dz, 1, 2 + 5e-4, 3), "within the line's epsilon")
		t.ok(not TargetRules.alongRay(1, 2, 3, dx, dy, dz, 1, 2.01, 3), "beside it")
		t.ok(
			not TargetRules.alongRay(1, 2, 3, dx, dy, dz, 1 + dx * 0.01, 2 + dy * 0.01, 3 + dz * 0.01),
			"ahead of the start"
		)
		-- Looking along the ray, nothing is ever hidden: no cast at all.
		local world = scene(true, true)
		local calls = 0
		local function counted(x: number, y: number, z: number): number?
			calls += 1
			return world.get(x, y, z)
		end
		local hit, ux, uy, uz = TargetRules.hidden(1, 2, 3, dx, dy, dz, 4, 1, 2, 3, counted, isTarget, outline)
		t.eq(hit, nil)
		t.eq(calls, 0, "no cast")
		t.eq(ux + uy + uz, 0)
	end)

	t.test("target rules: a camera at the eyes aims exactly as before (random worlds and rays)", function()
		local random = newRandom(1103)
		local world = newWorld()
		for x = -8, 8 do
			for y = -8, 8 do
				for z = -8, 8 do
					local roll = random.next(0, 1)
					if roll < 0.12 then
						world.set(x, y, z, STONE)
					elseif roll < 0.15 then
						world.set(x, y, z, TORCH)
					end
				end
			end
		end
		local hits = 0
		for i = 1, 2000 do
			local cx, cy, cz = random.next(-3, 3), random.next(-3, 3), random.next(-3, 3)
			local dx, dy, dz = unit(random.next(-1, 1), random.next(-1, 1), random.next(-1, 1))
			if i % 4 == 0 then
				-- (Axis rays too.)
				dx, dy, dz = 0, if i % 8 == 0 then 1 else -1, 0
			end
			-- The ray's start: the camera, or its near plane just ahead (the eyes are the camera).
			local near = if i % 2 == 0 then 0.1 / BLOCK else 0
			local ox, oy, oz = cx + dx * near, cy + dy * near, cz + dz * near
			local skip = TargetRules.skip(ox, oy, oz, dx, dy, dz, cx, cy, cz)
			t.eq(skip, 0, "nothing skipped")
			local before = VoxelRaycast.cast(ox, oy, oz, dx, dy, dz, 12, world.get, isTarget, outline)
			local hidden = TargetRules.hidden(
				ox,
				oy,
				oz,
				dx,
				dy,
				dz,
				if before then before.distance else 12,
				cx,
				cy,
				cz,
				world.get,
				isTarget,
				outline
			)
			t.eq(hidden, nil, "nothing hidden from eyes at the camera")
			if before then
				hits += 1
			end
		end
		t.ok(hits > 1000, `most rays hit something ({hits})`)
	end)

	--[[ Over the shoulder ]]

	t.test("target rules: over the shoulder, a block seen past a pillar picks the pillar", function()
		local world = scene(true, true)
		local ray = rayTo(CAMERA, WALL_POINT, EYES)
		local seen = VoxelRaycast.cast(ray.sx, ray.sy, ray.sz, ray.dx, ray.dy, ray.dz, 20, world.get, isTarget, outline)
		assert(seen, "the camera's ray hits the wall")
		t.eq(seen.x, -1)
		t.eq(seen.y, 1)
		t.eq(seen.z, -6, "the camera sees the wall past the pillar")
		t.eq(seen.nz, 1)
		t.near(seen.distance, ray.length, 1e-9)
		local hit, ux, uy, uz = TargetRules.hidden(
			ray.sx,
			ray.sy,
			ray.sz,
			ray.dx,
			ray.dy,
			ray.dz,
			seen.distance,
			EYES[1],
			EYES[2],
			EYES[3],
			world.get,
			isTarget,
			outline
		)
		assert(hit, "the eyes see the pillar instead")
		t.eq(hit.x, -1)
		t.eq(hit.y, 1)
		t.eq(hit.z, -2, "the pillar")
		t.eq(hit.nx, 1, "its own face: the one towards the eyes")
		t.eq(hit.ny, 0)
		t.eq(hit.nz, 0)
		-- Along the eyes' ray (from the eyes to the wall's point).
		local ex, ey, ez = unit(WALL_POINT[1] - EYES[1], WALL_POINT[2] - EYES[2], WALL_POINT[3] - EYES[3])
		t.near(ux, ex, 1e-12)
		t.near(uy, ey, 1e-12)
		t.near(uz, ez, 1e-12)
		t.near(hit.distance, 0.5 / 1.4 * math.sqrt(1.4 ^ 2 + 5.5 ^ 2), 1e-9, "where the eyes' ray enters the pillar")
		-- Without the pillar the eyes see the wall: nothing changes.
		local open = scene(false, true)
		local clear, cx, cy, cz = TargetRules.hidden(
			ray.sx,
			ray.sy,
			ray.sz,
			ray.dx,
			ray.dy,
			ray.dz,
			seen.distance,
			EYES[1],
			EYES[2],
			EYES[3],
			open.get,
			isTarget,
			outline
		)
		t.eq(clear, nil, "the eyes see the wall")
		t.near(cx * ex + cy * ey + cz * ez, 1, 1e-12, "the eyes' ray was checked")
	end)

	t.test("target rules: a face the eyes can't see gives the face they do", function()
		local world = newWorld()
		world.set(-1, 1, -3, STONE)
		-- The camera out to the left sees the block's west face; the eyes, east of it, can't.
		local camera = { -3, 1.7, -1 }
		local point = { -1, 1.6, -2.5 }
		local ray = rayTo(camera, point, EYES)
		local seen = VoxelRaycast.cast(ray.sx, ray.sy, ray.sz, ray.dx, ray.dy, ray.dz, 20, world.get, isTarget, outline)
		assert(seen, "the camera's ray hits the block")
		t.eq(seen.nx, -1, "its west face")
		local hit = TargetRules.hidden(
			ray.sx,
			ray.sy,
			ray.sz,
			ray.dx,
			ray.dy,
			ray.dz,
			seen.distance,
			EYES[1],
			EYES[2],
			EYES[3],
			world.get,
			isTarget,
			outline
		)
		assert(hit, "the eyes reach it sooner, through another face")
		t.eq(hit.x, -1)
		t.eq(hit.y, 1)
		t.eq(hit.z, -3, "the same block")
		t.eq(hit.nx, 0)
		t.eq(hit.nz, 1, "the face towards the eyes: placing goes there")
	end)

	t.test("target rules: a mob behind cover is hidden, one in view is not", function()
		-- A mob's point in the open (MobRenderer's pick along the camera's ray) past the pillar.
		local mob = { -0.9, 1.62, -4 }
		local covered = scene(true, false)
		local ray = rayTo(CAMERA, mob, EYES)
		t.eq(
			VoxelRaycast.cast(
				ray.sx,
				ray.sy,
				ray.sz,
				ray.dx,
				ray.dy,
				ray.dz,
				ray.length,
				covered.get,
				isTarget,
				outline
			),
			nil,
			"the camera sees the mob"
		)
		local hit = TargetRules.hidden(
			ray.sx,
			ray.sy,
			ray.sz,
			ray.dx,
			ray.dy,
			ray.dz,
			ray.length,
			EYES[1],
			EYES[2],
			EYES[3],
			covered.get,
			isTarget,
			outline
		)
		assert(hit, "the eyes don't: behind cover")
		t.eq(hit.z, -2, "the pillar covers it")
		local open = scene(false, false)
		t.eq(
			(
				TargetRules.hidden(
					ray.sx,
					ray.sy,
					ray.sz,
					ray.dx,
					ray.dy,
					ray.dz,
					ray.length,
					EYES[1],
					EYES[2],
					EYES[3],
					open.get,
					isTarget,
					outline
				)
			),
			nil,
			"in view"
		)
	end)

	t.test("target rules: the ray's end counts when it hits nothing; a torch is passed beside", function()
		-- No wall: the camera's ray ends in the open; the eyes' way there crosses the pillar.
		local world = scene(true, false)
		local ray = rayTo(CAMERA, WALL_POINT, EYES)
		t.eq(
			VoxelRaycast.cast(ray.sx, ray.sy, ray.sz, ray.dx, ray.dy, ray.dz, ray.length, world.get, isTarget, outline),
			nil
		)
		local hit = TargetRules.hidden(
			ray.sx,
			ray.sy,
			ray.sz,
			ray.dx,
			ray.dy,
			ray.dz,
			ray.length,
			EYES[1],
			EYES[2],
			EYES[3],
			world.get,
			isTarget,
			outline
		)
		assert(hit, "the pillar")
		t.eq(hit.z, -2)
		-- A column of torches instead of stone: the eyes' ray at 1.62 passes over the one in its
		-- cell (its box is 0.6 tall), so nothing hides the wall.
		local torches = scene(true, true, TORCH)
		local seen =
			VoxelRaycast.cast(ray.sx, ray.sy, ray.sz, ray.dx, ray.dy, ray.dz, 20, torches.get, isTarget, outline)
		assert(seen and seen.z == -6, "the camera sees the wall")
		t.eq(
			(
				TargetRules.hidden(
					ray.sx,
					ray.sy,
					ray.sz,
					ray.dx,
					ray.dy,
					ray.dz,
					seen.distance,
					EYES[1],
					EYES[2],
					EYES[3],
					torches.get,
					isTarget,
					outline
				)
			),
			nil,
			"past the torch's box"
		)
	end)

	t.test("target rules: pure (only Shared and the camera's rules)", function()
		local source = fs.readFile("src/client/Interaction/TargetRules.luau")
		local services = {}
		for name in string.gmatch(source, 'GetService%("(%w+)"%)') do
			table.insert(services, name)
		end
		t.eq(table.concat(services, ","), "ReplicatedStorage", "only Shared")
		local requires = {}
		for chain in string.gmatch(source, "require%(script([%.%w]+)%)") do
			table.insert(requires, chain)
		end
		t.eq(table.concat(requires, ","), ".Parent.Parent.Player.CameraRules", "the camera's rules alone")
		-- BlockInteraction aims through these rules and the rig.
		local interaction = fs.readFile("src/client/Interaction/BlockInteraction.luau")
		t.ok(string.find(interaction, "TargetRules.skip(", 1, true) ~= nil, "the eyes' plane")
		t.ok(string.find(interaction, "TargetRules.hidden(", 1, true) ~= nil, "the eyes' sight")
		t.ok(string.find(interaction, "CameraRig.locked()", 1, true) ~= nil, "the crosshair on a locked mouse")
	end)
end
