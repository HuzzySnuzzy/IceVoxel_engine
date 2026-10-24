--[[
	The client's turrets: the gun's model (Rendering/TurretModel: its boxes by type, tier and what
	is mounted, the pivot, the barrel along the aim and never turned half a turn, the muzzle the
	server's, never into its own block at any aim the pitch limits allow), the view's rules (where
	a drawn gun turns to, at its turn rate, the short way across +-180 degrees),
	Rendering/TurretView on fakes (records decoded into its state, heads pooled, hidden and freed,
	the floating origin, the beam, the servo, the dry click, a turret shot's drawn muzzle, its cost
	a frame with 48 turrets), the turret shots' effects (Rendering/ShotRules: `plain`, the stand-in
	gun's class sound, suppressed and far), Entities/MobRenderer.aimPoint, WAILA's turret lines
	(Ui/WailaInfo) and F3's (Debug/DebugOverlay).
]]

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")

local FakeClient = require("../lib/FakeClient")

return function(t, shared, require, _server, client)
	local Ballistics = require(shared.Weapons.Ballistics)
	local Blocks = require(shared.Blocks)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Config = require(shared.Config)
	local Coords = require(shared.World.Coords)
	local Items = require(shared.Items)
	local Machines = require(shared.Machines)
	local MobList = require(shared.Entities.MobList)
	local Origin = require(shared.World.Origin)
	local Protocol = require(shared.Net.Protocol)
	local Tiers = require(shared.Transmitters.Tiers)
	local Turrets = require(shared.Turrets)
	local TurretRules = require(shared.Turrets.TurretRules)
	local Weapons = require(shared.Weapons)
	local ShotRules = require(client.Rendering.ShotRules)
	local TurretModel = require(client.Rendering.TurretModel)
	local WailaInfo = require(client.Ui.WailaInfo)

	local CFrame, Vector3 = roblox.CFrame, roblox.Vector3
	local B = Blocks.id
	local I = Items.id
	local Flag = Protocol.TurretFlag
	local SIZE = Config.ChunkSize
	local BLOCK = Config.BlockSize
	local CLIENT = Config.Turrets.Client
	local PER_HEAD = TurretModel.MAX_PARTS + 1

	local function spec(turretType: string, tier: number): Turrets.Spec
		return Turrets.of(turretType :: any, tier)
	end

	local function boxNamed(look: TurretModel.Look, name: string): TurretModel.Box?
		for _, box in look.boxes do
			if box.name == name then
				return box
			end
		end
		return nil
	end

	local function names(look: TurretModel.Look): string
		local list = {}
		for _, box in look.boxes do
			table.insert(list, box.name)
		end
		return table.concat(list, ",")
	end

	-- A box's eight corners (world blocks) as `place` puts it.
	local function corners(numbers: { number }, at: number, box: TurretModel.Box): { { number } }
		local o = (at - 1) * TurretModel.STRIDE
		local cx, cy, cz = numbers[o + 1], numbers[o + 2], numbers[o + 3]
		local r = { numbers[o + 4], numbers[o + 5], numbers[o + 6], numbers[o + 7], numbers[o + 8], numbers[o + 9] }
		local r2 = { numbers[o + 10], numbers[o + 11], numbers[o + 12] }
		local out = {}
		for _, sx in { -1, 1 } do
			for _, sy in { -1, 1 } do
				for _, sz in { -1, 1 } do
					local a, b, c = sx * box.size[1] / 2, sy * box.size[2] / 2, sz * box.size[3] / 2
					table.insert(out, {
						cx + r[1] * a + r[2] * b + r[3] * c,
						cy + r[4] * a + r[5] * b + r[6] * c,
						cz + r2[1] * a + r2[2] * b + r2[3] * c,
					})
				end
			end
		end
		return out
	end

	--[[ The model ]]

	t.test("turret client: every type and tier has its boxes, at most 14, the tier's own", function()
		for _, s in Turrets.SPECS do
			local scopes = s.optics[I.RifleScope] == true
			for bits = 0, 7 do
				local flags = (if bits % 2 == 1 then Flag.Laser else 0)
					+ (if (bits // 2) % 2 == 1 then Flag.Scope else 0)
					+ (if bits >= 4 then Flag.Suppressor else 0)
					+ Flag.Powered
					+ Flag.Tracking
				local look = TurretModel.look(s, flags)
				local laser, scope, suppressor = bits % 2 == 1, (bits // 2) % 2 == 1 and scopes, bits >= 4
				-- Base 2, receiver, barrel, tip, feeder, belt; a band a tier up to two, the shroud
				-- from Elite, the eye at Ultimate; the laser, the scope.
				local expected = 7
					+ math.min(s.tier, 2)
					+ (if s.tier >= 3 then 1 else 0)
					+ (if s.tier >= 4 then 1 else 0)
					+ (if laser then 1 else 0)
					+ (if scope then 1 else 0)
				t.eq(#look.boxes, expected, `{s.name} {bits}: {names(look)}`)
				t.ok(#look.boxes <= TurretModel.MAX_PARTS, `{s.name}: at most {TurretModel.MAX_PARTS}`)
				t.eq(look.spec, s, "its spec")
				t.eq(look.laser ~= nil, laser, `{s.name}: the beam's start with a laser only`)
				t.eq(boxNamed(look, "Laser") ~= nil, laser, `{s.name}: the emitter`)
				t.eq(boxNamed(look, "Scope") ~= nil, scope, `{s.name}: a scope only where one fits`)
				t.eq(boxNamed(look, "Suppressor") ~= nil, suppressor, `{s.name}: the can`)
				local tipName = if s.type == "sniper" then "MuzzleBrake" else "FlashHider"
				t.eq(boxNamed(look, tipName) ~= nil, not suppressor, `{s.name}: the {tipName} unless a can`)
				t.ok(boxNamed(look, "Receiver") and boxNamed(look, "Barrel") and boxNamed(look, "Feeder"), "the gun")
				t.eq(TurretModel.look(s, flags), look, "one look for the same flags (shared)")
				t.ok(table.isfrozen(look) and table.isfrozen(look.boxes), "frozen")
				-- The tier's colour on its bands, the module's eye glowing.
				local band = boxNamed(look, "Band") :: TurretModel.Box
				t.eq(band.colour, Tiers.TIERS[s.tier].colour, `{s.name}: the tier's colour`)
				local eye = boxNamed(look, "Eye")
				t.eq(eye ~= nil, s.tier == 4, "the Ultimate's eye")
				if eye then
					t.eq(eye.material, "neon", "glowing")
				end
				for _, box in look.boxes do
					t.ok(box.size[1] > 0 and box.size[2] > 0 and box.size[3] > 0, `{s.name} {box.name}: a size`)
					local base = box.name == "Turntable" or box.name == "Post"
					t.eq(box.frame, if base then "base" else "gun", `{box.name}'s frame`)
				end
			end
			-- Flags that change nothing: the same look.
			t.eq(
				TurretModel.look(s, 0),
				TurretModel.look(s, Flag.Powered + Flag.Firing + Flag.Tracking),
				"status flags"
			)
			if not scopes then
				t.eq(TurretModel.look(s, Flag.Scope), TurretModel.look(s, 0), `{s.name} takes no scope: none drawn`)
			end
		end
		-- The barrels by type: an SMG's short and thick, a rifle's long, a sniper's longest.
		local function barrel(turretType: string): TurretModel.Box
			return boxNamed(TurretModel.look(spec(turretType, 1), 0), "Barrel") :: TurretModel.Box
		end
		t.ok(barrel("smg").size[3] < barrel("rifle").size[3], "the SMG's barrel is shorter than the rifle's")
		t.ok(barrel("rifle").size[3] < barrel("sniper").size[3], "and the rifle's than the sniper's")
		t.ok(barrel("smg").size[1] > barrel("rifle").size[1], "and thicker")
		t.ok(barrel("rifle").size[1] > barrel("sniper").size[1], "the sniper's the thinnest")
		local ultimate = TurretModel.look(spec("sniper", 4), Flag.Laser + Flag.Scope + Flag.Suppressor)
		t.eq(#ultimate.boxes, 13, "an Ultimate sniper with everything mounted")
	end)

	t.test("turret client: the bore runs through the pivot to the server's muzzle", function()
		for _, s in Turrets.SPECS do
			for _, flags in { 0, Flag.Suppressor, Flag.Laser + Flag.Scope } do
				local look = TurretModel.look(s, flags)
				t.eq(look.muzzle, s.barrel, `{s.name}: the muzzle Spec.barrel out`)
				-- The tip's (or the can's) front is the muzzle, on the bore; the barrel ends inside it.
				local tip = boxNamed(
					look,
					if bit32.btest(flags, Flag.Suppressor)
						then "Suppressor"
						elseif s.type == "sniper" then "MuzzleBrake"
						else "FlashHider"
				) :: TurretModel.Box
				t.near(tip.offset[3] + tip.size[3] / 2, s.barrel, 1e-12, `{s.name}: the tip's front`)
				local bore = boxNamed(look, "Barrel") :: TurretModel.Box
				t.ok(bore.offset[1] == 0 and bore.offset[2] == 0, "the barrel on the bore")
				t.ok(tip.offset[1] == 0 and tip.offset[2] == 0, "the tip on the bore")
				t.ok(bore.offset[3] + bore.size[3] / 2 < s.barrel, "the barrel's end inside the tip (no shared face)")
				t.ok(bore.offset[3] - bore.size[3] / 2 > 0, "the barrel ahead of the pivot")
			end
		end
		-- Anywhere, at any aim: the drawn muzzle is TurretRules.muzzle, the gun's axes orthonormal and
		-- right-handed, the back column minus the aim (a part's LookVector is the aim).
		local s = spec("rifle", 3)
		local look = TurretModel.look(s, Flag.Laser)
		local numbers = {}
		local cases = {
			{ 0, 0 },
			{ math.pi / 2, 0 },
			{ math.pi, 0.4 },
			{ -2.5, -0.9 },
			{ 3.1, 1.2 },
			{ 1.234, -1.0 },
		}
		for _, case in cases do
			local yaw, pitch = case[1], case[2]
			local x, y, z = 1000003, 70, -2999987
			local mx, my, mz = TurretModel.muzzle(look, x, y, z, yaw, pitch)
			local ex, ey, ez = TurretRules.muzzle(x, y, z, yaw, pitch, s.barrel)
			t.near(mx, ex, 1e-9, "muzzle x")
			t.near(my, ey, 1e-9, "muzzle y")
			t.near(mz, ez, 1e-9, "muzzle z")
			local dx, dy, dz = TurretRules.direction(yaw, pitch)
			local rx, ry, rz, ux, uy, uz, fx, fy, fz = TurretModel.basis(yaw, pitch)
			t.near(fx, dx, 1e-12, "forward is the aim")
			t.near(fy, dy, 1e-12)
			t.near(fz, dz, 1e-12)
			t.near(rx * ux + ry * uy + rz * uz, 0, 1e-12, "right . up")
			t.near(rx * fx + ry * fy + rz * fz, 0, 1e-12, "right . forward")
			t.near(ux * fx + uy * fy + uz * fz, 0, 1e-12, "up . forward")
			-- right x up = back = -forward
			t.near(ry * uz - rz * uy, -fx, 1e-12, "right-handed x")
			t.near(rz * ux - rx * uz, -fy, 1e-12, "right-handed y")
			t.near(rx * uy - ry * ux, -fz, 1e-12, "right-handed z")
			t.near(ry, 0, 1e-12, "right stays level")
			local n = TurretModel.place(look, x, y, z, yaw, pitch, numbers)
			t.eq(n, #look.boxes, "every box placed")
			local px, py, pz = TurretRules.pivot(x, y, z)
			for i, box in look.boxes do
				local o = (i - 1) * TurretModel.STRIDE
				local cf = CFrame.new(
					0,
					0,
					0,
					numbers[o + 4],
					numbers[o + 5],
					numbers[o + 6],
					numbers[o + 7],
					numbers[o + 8],
					numbers[o + 9],
					numbers[o + 10],
					numbers[o + 11],
					numbers[o + 12]
				)
				local cx, cy, cz = numbers[o + 1], numbers[o + 2], numbers[o + 3]
				local want = if box.frame == "gun"
					then { TurretModel.point(x, y, z, yaw, pitch, box.offset[1], box.offset[2], box.offset[3]) }
					else { TurretModel.point(x, y, z, yaw, 0, box.offset[1], box.offset[2], box.offset[3]) }
				t.near(cx, want[1], 1e-9, `{box.name}: centre x`)
				t.near(cy, want[2], 1e-9, `{box.name}: centre y`)
				t.near(cz, want[3], 1e-9, `{box.name}: centre z`)
				local look3 = cf.LookVector
				if box.frame == "gun" then
					-- (Lune's CFrame from twelve numbers: the matrix as Roblox reads it.)
					t.near(look3.X, dx, 1e-5, `{box.name}: LookVector is the aim, not reversed`)
					t.near(look3.Y, dy, 1e-5)
					t.near(look3.Z, dz, 1e-5)
				else
					local hx, hz = math.sin(yaw), math.cos(yaw)
					t.near(look3.X, hx, 1e-5, `{box.name}: turns with the yaw`)
					t.near(look3.Y, 0, 1e-5, `{box.name}: never pitches`)
					t.near(look3.Z, hz, 1e-5)
				end
				if box.name == "Barrel" then
					-- On the aim's line through the pivot, ahead of it.
					local vx, vy, vz = cx - px, cy - py, cz - pz
					local along = vx * dx + vy * dy + vz * dz
					t.ok(along > 0, "the barrel ahead")
					t.near(vx - dx * along, 0, 1e-9, "on the line")
					t.near(vy - dy * along, 0, 1e-9)
					t.near(vz - dz * along, 0, 1e-9)
				end
			end
			-- The laser's beam starts on the emitter's front.
			local sx, sy, sz = TurretModel.laserStart(look, x, y, z, yaw, pitch)
			local emitter = boxNamed(look, "Laser") :: TurretModel.Box
			local qx, qy, qz = TurretModel.point(
				x,
				y,
				z,
				yaw,
				pitch,
				emitter.offset[1],
				emitter.offset[2],
				emitter.offset[3] + emitter.size[3] / 2
			)
			t.near((sx :: number) - qx, 0, 1e-9, "the beam from the emitter's front")
			t.near((sy :: number) - qy, 0, 1e-9)
			t.near((sz :: number) - qz, 0, 1e-9)
		end
		t.eq(TurretModel.laserStart(TurretModel.look(s, 0), 0, 0, 0, 0, 0), nil, "no laser, no beam")
	end)

	-- How far (blocks) the box `place` wrote at `at` goes down into the block (x, y, z) (0: not into
	-- it): the block's top less the box's lowest point over the block's footprint, which is a corner
	-- over it, where an edge crosses the footprint's side, or where one of the footprint's four
	-- upright edges passes through the box. Exact for a box; nothing allocated.
	local axisX, axisY, axisZ, half = { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }
	local function depthIn(
		numbers: { number },
		at: number,
		box: TurretModel.Box,
		x: number,
		y: number,
		z: number
	): number
		local o = (at - 1) * TurretModel.STRIDE
		-- (From the middle of the block's top.)
		local cx, cy, cz = numbers[o + 1] - x - 0.5, numbers[o + 2] - y - 1, numbers[o + 3] - z - 0.5
		local down, acrossX, acrossZ = 0, 0, 0
		for i = 1, 3 do
			axisX[i], axisY[i], axisZ[i] = numbers[o + 3 + i], numbers[o + 6 + i], numbers[o + 9 + i]
			half[i] = box.size[i] / 2
			down += half[i] * math.abs(axisY[i])
			acrossX += half[i] * math.abs(axisX[i])
			acrossZ += half[i] * math.abs(axisZ[i])
		end
		-- Wholly over the top or beside the footprint.
		if cy - down >= 0 or math.abs(cx) - acrossX >= 0.5 or math.abs(cz) - acrossZ >= 0.5 then
			return 0
		end
		local lowest = math.huge
		-- The edges along each axis (from the corner at its minus end), their ends the corners.
		for i = 1, 3 do
			local j, k = i % 3 + 1, (i + 1) % 3 + 1
			local dx, dy, dz = 2 * half[i] * axisX[i], 2 * half[i] * axisY[i], 2 * half[i] * axisZ[i]
			for sj = -1, 1, 2 do
				for sk = -1, 1, 2 do
					local sx = cx + sj * half[j] * axisX[j] + sk * half[k] * axisX[k] - dx / 2
					local sy = cy + sj * half[j] * axisY[j] + sk * half[k] * axisY[k] - dy / 2
					local sz = cz + sj * half[j] * axisZ[j] + sk * half[k] * axisZ[k] - dz / 2
					for c = 1, 6 do
						local along = if c == 1
							then 0
							elseif c == 2 then 1
							elseif c <= 4 then (if dx ~= 0 then ((if c == 3 then -0.5 else 0.5) - sx) / dx else -1)
							else (if dz ~= 0 then ((if c == 5 then -0.5 else 0.5) - sz) / dz else -1)
						if along >= 0 and along <= 1 then
							local px, py, pz = sx + dx * along, sy + dy * along, sz + dz * along
							if math.abs(px) <= 0.5 + 1e-12 and math.abs(pz) <= 0.5 + 1e-12 and py < lowest then
								lowest = py
							end
						end
					end
				end
			end
		end
		-- The footprint's upright edges through the box: (q - centre) . axis within its half.
		for qx = -0.5, 0.5, 1 do
			for qz = -0.5, 0.5, 1 do
				local lo, hi = -math.huge, math.huge
				for i = 1, 3 do
					local k = (qx - cx) * axisX[i] + (qz - cz) * axisZ[i] - cy * axisY[i]
					if math.abs(axisY[i]) < 1e-12 then
						if math.abs(k) > half[i] then
							lo = math.huge
						end
					else
						local a, b = (-half[i] - k) / axisY[i], (half[i] - k) / axisY[i]
						lo, hi = math.max(lo, math.min(a, b)), math.min(hi, math.max(a, b))
					end
				end
				if lo <= hi and lo < lowest then
					lowest = lo
				end
			end
		end
		return if lowest < 0 then -lowest else 0
	end

	t.test("turret client: the gun sits on the base, level in the cell above, never into its block", function()
		local numbers = {}
		local x, y, z = 10, 64, -7
		local settings = Config.Turrets
		-- A sniper's can pointing straight down goes in (what is checked does see it).
		local straight = TurretModel.look(spec("sniper", 1), Flag.Suppressor)
		TurretModel.place(straight, x, y, z, 0, math.rad(-90), numbers)
		local canAt = table.find(straight.boxes, boxNamed(straight, "Suppressor")) :: number
		local straightDepth = depthIn(numbers, canAt, straight.boxes[canAt], x, y, z)
		t.near(straightDepth, 2 - TurretRules.PIVOT, 1e-9, "straight down: its front a block under the pivot")
		local placed = 0
		for _, s in Turrets.SPECS do
			-- Every mount (the Scope flag only where it fits: one look for both).
			local seen = {}
			for bits = 0, 7 do
				local look = TurretModel.look(
					s,
					(if bits % 2 == 1 then Flag.Laser else 0)
						+ (if (bits // 2) % 2 == 1 then Flag.Scope else 0)
						+ (if bits >= 4 then Flag.Suppressor else 0)
				)
				if not seen[look] then
					seen[look] = true
					-- The turntable on the block's top (no face shared with it), the pivot over it.
					local turntable = boxNamed(look, "Turntable") :: TurretModel.Box
					local bottom = y + TurretRules.PIVOT + turntable.offset[2] - turntable.size[2] / 2
					t.ok(bottom > y + 1 and bottom < y + 1.01, `{s.name}: the turntable on the top ({bottom - y})`)
					-- Held level, under the cell above's top (no face shared with a block over it).
					TurretModel.place(look, x, y, z, 0, 0, numbers)
					for i, box in look.boxes do
						for _, corner in corners(numbers, i, box) do
							t.ok(corner[2] < y + 2 - 1e-3, `{s.name} {box.name}: level, in the cell above`)
						end
					end
					-- Every 5 degrees of yaw round the turn, every degree from its type's pitchMin to
					-- PitchMax: never into its own block, and the server's shot origin out of it.
					for yawDeg = 0, 355, 5 do
						local yaw = math.rad(yawDeg)
						for pitchDeg = s.pitchMin, settings.PitchMax do
							local pitch = math.rad(pitchDeg)
							TurretModel.place(look, x, y, z, yaw, pitch, numbers)
							placed += 1
							for i, box in look.boxes do
								local depth = depthIn(numbers, i, box, x, y, z)
								if depth > 1e-9 then
									t.ok(
										false,
										`{s.name} {box.name}: {depth} into its block at {yawDeg}°, {pitchDeg}°`
									)
								end
								local o = (i - 1) * TurretModel.STRIDE
								local reach =
									math.max(math.abs(numbers[o + 1] - x - 0.5), math.abs(numbers[o + 3] - z - 0.5))
								if reach > 0.5 + s.barrel then
									t.ok(false, `{s.name} {box.name}: near its block ({reach})`)
								end
							end
							local mx, my, mz = TurretRules.muzzle(x, y, z, yaw, pitch, s.barrel)
							if my < y + 1 and math.abs(mx - x - 0.5) < 0.5 and math.abs(mz - z - 0.5) < 0.5 then
								t.ok(false, `{s.name}: the muzzle in its block at {yawDeg}°, {pitchDeg}°`)
							end
						end
					end
				end
			end
		end
		local aims = 0
		for _, s in Turrets.SPECS do
			-- (Looks: an SMG's four, the others' eight with the scope.)
			aims += (if s.type == "smg" then 4 else 8) * 72 * (settings.PitchMax - s.pitchMin + 1)
		end
		t.eq(placed, aims, "every look and aim")
		-- Each type's lowest pitch is the lowest whole degree that clears every tier and mount at every
		-- half degree of a quarter turn (every yaw: the block's footprint turns into itself): clear at
		-- it, and a degree under it into its block, unless it is PitchMin, the lowest any type aims at.
		local function deepest(turretType: string, pitchDeg: number): number
			local most = 0
			for tier = 1, 4 do
				local s = spec(turretType, tier)
				for bits = 0, 7 do
					local look = TurretModel.look(
						s,
						(if bits % 2 == 1 then Flag.Laser else 0)
							+ (if (bits // 2) % 2 == 1 then Flag.Scope else 0)
							+ (if bits >= 4 then Flag.Suppressor else 0)
					)
					for tenths = 0, 900, 5 do
						TurretModel.place(look, x, y, z, math.rad(tenths / 10), math.rad(pitchDeg), numbers)
						for i, box in look.boxes do
							most = math.max(most, depthIn(numbers, i, box, x, y, z))
						end
					end
				end
			end
			return most
		end
		for _, turretType in Turrets.TYPES do
			local low = spec(turretType, 1).pitchMin
			t.eq(deepest(turretType, low), 0, `{turretType} at {low}°: clear`)
			if low > settings.PitchMin then
				local under = deepest(turretType, low - 1)
				t.ok(under > 1e-9, `{turretType} at {low - 1}°: {under} into its block, so {low} is its lowest`)
			end
		end
		t.ok(spec("smg", 1).pitchMin < spec("sniper", 1).pitchMin, "the SMG's short barrel aims lower")
	end)

	--[[ The view's rules ]]

	t.test("turret client: a drawn gun turns at its turn rate, the short way across 180 degrees", function()
		local s = spec("smg", 1)
		local rate = math.rad(s.turn)
		-- One step: at most the turn rate times the frame, never past.
		local yaw, pitch = TurretModel.step(s, 0, 0, math.rad(90), math.rad(-30), 0.1)
		t.near(yaw, rate * 0.1, 1e-12, "yaw at the turn rate")
		t.near(pitch, -rate * 0.1, 1e-12, "pitch at the turn rate")
		local frames = 0
		yaw, pitch = 0, 0
		while yaw ~= math.rad(90) and frames < 1000 do
			local before = yaw
			yaw, pitch = TurretModel.step(s, yaw, pitch, math.rad(90), math.rad(-30), 1 / 60)
			t.ok(yaw - before <= rate / 60 + 1e-12, "never faster")
			t.ok(yaw <= math.rad(90), "never past")
			frames += 1
		end
		t.eq(yaw, math.rad(90), "there exactly")
		t.eq(pitch, math.rad(-30), "both axes")
		t.eq(frames, math.ceil(90 / s.turn * 60 - 1e-9), "in 90 / turn seconds")
		-- Across +-180: from 170 to -170 degrees is 20 degrees the short way, through 180.
		yaw = math.rad(170)
		local seen = {}
		for _ = 1, 120 do
			yaw = TurretModel.step(s, yaw, 0, math.rad(-170), 0, 1 / 60)
			table.insert(seen, yaw)
			t.ok(yaw > -math.pi and yaw <= math.pi, "kept in (-pi, pi]")
		end
		t.near(seen[1], math.rad(170) + rate / 60, 1e-12, "it turns up through 180")
		t.near(yaw, math.rad(-170), 1e-12, "and reaches -170")
		t.ok(seen[#seen // 2] < 0 and seen[1] > 0, "crossing 180, not back through 0")
		-- The record's yaw in 0..2 pi (as decoded) is the same aim.
		local a = TurretModel.step(s, math.rad(-10), 0, math.rad(350), 0, 1)
		t.near(a, math.rad(-10), 1e-12, "350 degrees is -10")
		-- Faster tiers turn faster; no time, no turn; nonsense dt none.
		local fast = spec("smg", 4)
		t.ok(TurretModel.step(fast, 0, 0, 1, 0, 0.1) > TurretModel.step(s, 0, 0, 1, 0, 0.1), "tiers turn faster")
		t.eq(TurretModel.step(s, 0.3, 0, 1, 0, 0), 0.3, "dt 0")
		t.eq(TurretModel.step(s, 0.3, 0, 1, 0, 0 / 0), 0.3, "NaN dt")
		t.eq(TurretModel.step(s, 0.3, 0, 1, 0, -1), 0.3, "negative dt")
	end)

	t.test("turret client: where a drawn gun turns: the drawn target, else the record, idle level", function()
		local function record(flags: number, target: number?, yaw: number?, pitch: number?): Protocol.TurretRecord
			return {
				x = 4,
				y = 64,
				z = 9,
				yaw = yaw or 1,
				pitch = pitch or 0.3,
				target = target or 0,
				flags = flags,
				ammo = 2,
			}
		end
		local wy, wp = TurretModel.want(nil, 4, 64, 9)
		t.ok(wy == 0 and wp == 0, "no record: idle, yaw 0, level")
		wy, wp = TurretModel.want(record(Flag.Powered), 4, 64, 9)
		t.ok(wy == 1 and wp == 0, "idle: the yaw held, the pitch back to level")
		-- Tracking a target the client draws: at its aim point, from the pivot.
		local tracking = Flag.Powered + Flag.Tracking
		wy, wp = TurretModel.want(record(tracking, 7), 4, 64, 9, 10.5, 65.2, 3)
		local px, py, pz = TurretRules.pivot(4, 64, 9)
		local ay, ap = TurretRules.aim(px, py, pz, 10.5, 65.2, 3)
		t.near(wy, ay, 1e-12, "at the target's yaw")
		t.near(wp, ap, 1e-12, "and pitch")
		-- Below the pitch limit: as low as its type goes (no spec: the lowest any type goes).
		wy, wp = TurretModel.want(record(tracking, 7), 4, 64, 9, 4.6, 40, 9.5)
		t.near(wp, math.rad(Config.Turrets.PitchMin), 1e-12, "the pitch limit")
		for _, s in Turrets.SPECS do
			wy, wp = TurretModel.want(record(tracking, 7), 4, 64, 9, 4.6, 40, 9.5, s)
			t.near(wp, math.rad(s.pitchMin), 1e-12, `{s.name}: its type's pitch limit`)
		end
		-- The target not drawn, or no power (it holds still): the record's aim.
		wy, wp = TurretModel.want(record(tracking, 7), 4, 64, 9)
		t.ok(wy == 1 and wp == 0.3, "not drawn: the record's aim")
		wy, wp = TurretModel.want(record(Flag.Tracking, 7), 4, 64, 9, 10, 64, 9)
		t.ok(wy == 1 and wp == 0.3, "no power: it holds still")
		wy, wp = TurretModel.want(record(Flag.Tracking), 4, 64, 9)
		t.ok(wy == 1 and wp == 0.3, "tracking: the record's aim")
		-- A target at the pivot itself: the record's.
		wy, wp = TurretModel.want(record(tracking, 7), 4, 64, 9, px, py, pz)
		t.ok(wy == 1 and wp == 0.3, "a target at the pivot")
		-- Heads: a scoped sniper's only.
		t.ok(TurretModel.aimsAtHead(spec("sniper", 2), Flag.Scope), "a scoped sniper aims at heads")
		t.ok(not TurretModel.aimsAtHead(spec("sniper", 2), Flag.Laser), "an unscoped one at bodies")
		t.ok(not TurretModel.aimsAtHead(spec("rifle", 4), Flag.Scope), "a scoped rifle at bodies")
		t.ok(not TurretModel.aimsAtHead(spec("smg", 4), Flag.Scope), "an SMG takes no scope")
		-- Idle records.
		t.ok(TurretModel.idle({ x = 0, y = 0, z = 0, yaw = 0, pitch = 0, target = 0, flags = 0, ammo = 0 }), "idle")
		t.ok(not TurretModel.idle(record(0)), "rounds held are not idle")
		t.ok(
			not TurretModel.idle({ x = 0, y = 0, z = 0, yaw = 0, pitch = 0, target = 0, flags = 1, ammo = 0 }),
			"powered"
		)
	end)

	--[[ The view, on fakes ]]

	-- A TurretView loaded on fakes: a world of chunks and edits, the camera and BulkMoveTo, the
	-- net, sounds, the mobs drawn and ShotView's hook.
	local function boot(): any
		Origin.reset()
		local h: any = {
			handlers = {},
			plays = {},
			loops = {},
			mobs = {},
			moved = 0,
			bulk = 0,
			listener = Vector3.new(0.5, 66, 0.5),
		}
		local blocks: { [string]: number } = {}
		local world: any = { chunks = {}, edits = {}, blockFns = {}, chunkFns = {}, editFns = {} }
		function world.getBlock(_self: any, x: number, y: number, z: number): number?
			if y < 0 then
				return B.Bedrock
			end
			if world.chunks[Coords.chunkKey(x // SIZE, z // SIZE)] == nil then
				return nil
			end
			return blocks[`{x},{y},{z}`] or B.Air
		end
		function world.onBlockChanged(_self: any, fn: any)
			table.insert(world.blockFns, fn)
			return function() end
		end
		function world.onChunkLoaded(_self: any, fn: any)
			table.insert(world.chunkFns, fn)
			return function() end
		end
		function world.onEditList(_self: any, fn: any)
			table.insert(world.editFns, fn)
			return function() end
		end
		function world.knownEdits(_self: any, cx: number, cz: number): any
			local list = world.edits[Coords.chunkKey(cx, cz)]
			return if type(list) == "table" then list else nil
		end
		h.world = world
		-- A block edit (in its chunk's edit list), heard when the chunk is loaded.
		function h.set(x: number, y: number, z: number, block: number, predicted: boolean?)
			local cx, cz = x // SIZE, z // SIZE
			local key = Coords.chunkKey(cx, cz)
			local list = world.edits[key]
			if type(list) ~= "table" then
				list = {}
				world.edits[key] = list
			end
			local previous = world:getBlock(x, y, z) or B.Air
			blocks[`{x},{y},{z}`] = block
			list[ChunkLayout.localIndex(x - cx * SIZE, y, z - cz * SIZE)] = block
			if world.chunks[key] then
				for _, fn in world.blockFns do
					fn(x, y, z, block, previous, predicted == true)
				end
			end
		end
		function h.load(cx: number, cz: number)
			local key = Coords.chunkKey(cx, cz)
			if type(world.edits[key]) ~= "table" then
				world.edits[key] = {}
			end
			world.chunks[key] = {}
			for _, fn in world.chunkFns do
				fn(cx, cz, true)
			end
		end
		function h.unload(cx: number, cz: number, forget: boolean?)
			local key = Coords.chunkKey(cx, cz)
			world.chunks[key] = nil
			for _, fn in world.chunkFns do
				fn(cx, cz, false)
			end
			if forget then
				world.edits[key] = nil
				for _, fn in world.editFns do
					fn(cx, cz, false)
				end
			end
		end
		local workspace = FakeClient.Instance.new("Folder")
		workspace.Name = "Workspace"
		h.workspace = workspace
		function h.camera(x: number, y: number, z: number)
			workspace.CurrentCamera = { CFrame = CFrame.new(x * BLOCK - Origin.x, y * BLOCK, z * BLOCK - Origin.z) }
		end
		h.camera(0.5, 66, 0.5)
		workspace.BulkMoveTo = function(_self: any, parts: { any }, frames: { any }, mode: any)
			assert(#parts == #frames, "as many CFrames as parts")
			assert(mode == roblox.Enum.BulkMoveMode.FireCFrameChanged, "FireCFrameChanged")
			h.bulk += 1
			h.moved += #parts
			for i, part in parts do
				part.CFrame = frames[i]
			end
		end
		local stubs = {
			["src/client/Net/ClientNet.luau"] = {
				on = function(kind: number, fn: any)
					h.handlers[kind] = fn
				end,
				send = function() end,
			},
			["src/client/Audio/SoundPlayer.luau"] = {
				play = function(name: any, x: number, y: number, z: number): boolean
					table.insert(h.plays, { name = name, x = x, y = y, z = z })
					return true
				end,
				setLoop = function(key: any, name: string?, x: number, y: number, z: number)
					h.loops[key] = if name then { name = name, x = x, y = y, z = z } else nil
				end,
				listener = function(): any
					return h.listener
				end,
			},
			["src/client/Entities/MobRenderer.luau"] = {
				aimPoint = function(id: number, head: boolean?): (number?, number?, number?)
					local mob = h.mobs[id]
					h.head = head
					if mob == nil then
						return nil, nil, nil
					end
					return mob[1], mob[2], mob[3]
				end,
			},
			["src/client/Rendering/ShotView.luau"] = {
				setTurretMuzzle = function(finder: any)
					h.finder = finder
				end,
			},
			["src/client/World/ClientWorld.luau"] = {},
		}
		local services = {
			RunService = {
				BindToRenderStep = function(_self: any, name: string, priority: number, fn: any)
					h.stepName, h.priority, h.step = name, priority, fn
				end,
			},
			Workspace = workspace,
		}
		local load = FakeClient.loader(shared, require, stubs, services)
		h.View = load("src/client/Rendering/TurretView.luau")
		h.View.start(world)
		function h.frame(dt: number?)
			h.step(dt or 1 / 60)
		end
		function h.send(records: { Protocol.TurretRecord })
			h.handlers[Protocol.ServerMessage.Turrets](Protocol.encodeTurrets(records))
		end
		function h.parts(): { any }
			return workspace:FindFirstChild("IceVoxelTurrets"):GetChildren()
		end
		-- The visible parts.
		function h.showing(): number
			local n = 0
			for _, part in h.parts() do
				if part.Transparency < 1 then
					n += 1
				end
			end
			return n
		end
		return h
	end

	local function rec(x: number, y: number, z: number, fields: { [string]: any }?): Protocol.TurretRecord
		local r: any = { x = x, y = y, z = z, yaw = 0, pitch = 0, target = 0, flags = Flag.Powered, ammo = 1 }
		for key, value in fields or {} do
			r[key] = value
		end
		return r
	end

	-- The part dressed as `name` nearest the turret at (x, y, z) (render studs -> blocks).
	local function partNamed(h: any, look: TurretModel.Look, name: string, x: number, y: number, z: number): any
		local box = boxNamed(look, name) :: TurretModel.Box
		local px, py, pz = TurretRules.pivot(x, y, z)
		local best, bestD = nil, math.huge
		for _, part in h.parts() do
			if part.Transparency < 1 and part.CFrame and part.Name == "Gun" then
				local size = part.Size
				if
					math.abs(size.X - box.size[1] * BLOCK) < 1e-4
					and math.abs(size.Y - box.size[2] * BLOCK) < 1e-4
					and math.abs(size.Z - box.size[3] * BLOCK) < 1e-4
				then
					local bx, by, bz = Origin.renderToBlocks(part.CFrame.Position)
					local d = (bx - px) ^ 2 + (by - py) ^ 2 + (bz - pz) ^ 2
					if d < bestD then
						best, bestD = part, d
					end
				end
			end
		end
		return best
	end

	t.test("turret view: records become its state, kept while their chunk is wanted", function()
		local h = boot()
		t.eq(h.stepName, "IceVoxelTurrets", "its render step")
		t.eq(h.priority, roblox.Enum.RenderPriority.Camera.Value + 1, "after the camera")
		t.ok(h.finder ~= nil, "ShotView is given the drawn muzzles")
		local block = B.EliteSmgTurret
		h.set(2, 64, 3, block)
		h.load(0, 0)
		local yaw = 1.0
		h.send({ rec(2, 64, 3, { yaw = yaw, pitch = 0.2, target = 5, flags = Flag.Powered + Flag.Tracking, ammo = 3 }) })
		local state = h.View.state(2, 64, 3)
		t.ok(state ~= nil, "the record kept")
		t.near(state.yaw, yaw, 2 * math.pi / 65536, "its yaw (a 65536th of a turn)")
		t.eq(state.pitch, math.rad(11), "its pitch, whole degrees")
		t.eq(state.target, 5)
		t.eq(state.ammo, 3)
		t.ok(table.isfrozen(state), "read only")
		local stats = h.View.stats()
		t.eq(stats.records, 1, "one record")
		t.eq(stats.tracking, 1, "tracking")
		-- An idle record is no record; a record in a chunk neither loaded nor asked for is dropped.
		h.send({ rec(2, 64, 3, { flags = 0, ammo = 0 }) })
		t.eq(h.View.state(2, 64, 3), nil, "idle: forgotten")
		t.eq(h.View.stats().records, 0)
		h.send({ rec(500, 64, 500) })
		t.eq(h.View.state(500, 64, 500), nil, "an unwanted chunk's record")
		-- The edit list asked for (false) is wanted, before the data comes.
		h.world.edits[Coords.chunkKey(500 // SIZE, 500 // SIZE)] = false
		h.send({ rec(500, 64, 500, { ammo = 2 }) })
		t.eq(h.View.state(500, 64, 500).ammo, 2, "an edit list asked for: kept")
		-- A malformed message changes nothing.
		h.handlers[Protocol.ServerMessage.Turrets](buffer.create(3))
		t.eq(h.View.stats().records, 1, "malformed: ignored")
		-- The chunk's data and edit list go: its records go.
		h.send({ rec(2, 64, 3, { ammo = 2 }) })
		t.eq(h.View.stats().records, 2)
		h.unload(0, 0)
		t.ok(h.View.state(2, 64, 3) ~= nil, "the edit list still known: kept")
		h.unload(0, 0, true)
		t.eq(h.View.state(2, 64, 3), nil, "neither: forgotten")
		-- A block change forgets the record (a new turret is idle) unless the server refuses this
		-- player's own break.
		h.load(0, 0)
		h.send({ rec(2, 64, 3, { ammo = 4, flags = Flag.Powered + Flag.Laser }) })
		h.set(2, 64, 3, B.Air, true)
		t.eq(h.View.state(2, 64, 3), nil, "broken: no record")
		h.set(2, 64, 3, block)
		t.eq(h.View.state(2, 64, 3).ammo, 4, "the break refused: the record back")
		h.set(2, 64, 3, B.Air)
		h.set(2, 64, 3, block)
		t.eq(h.View.state(2, 64, 3), nil, "a new turret: idle")
		t.eq(h.View.state(2, -1, 3), nil, "out of the world")
	end)

	t.test("turret view: a broken turret's record is kept UNDO_WINDOW, then dropped", function()
		local h = boot()
		local x, y, z = 4, 64, 4
		local s = spec("rifle", 3)
		h.set(x, y, z, s.block)
		h.load(0, 0)
		h.send({ rec(x, y, z, { flags = Flag.Powered + Flag.Laser + Flag.Scope, ammo = 3, yaw = 2 }) })
		-- This player breaks it and the server agrees (the same air: nothing heard). Six seconds of
		-- frames on, another player places one there: a new turret, idle.
		h.set(x, y, z, B.Air, true)
		for _ = 1, 24 do
			h.frame(0.25)
		end
		h.set(x, y, z, s.block)
		t.eq(h.View.state(x, y, z), nil, "a new turret: idle, the old record gone")
		-- Refused two seconds on: the record back.
		h.send({ rec(x, y, z, { flags = Flag.Powered, ammo = 2 }) })
		h.set(x, y, z, B.Air, true)
		for _ = 1, 8 do
			h.frame(0.25)
		end
		h.set(x, y, z, s.block)
		t.eq(h.View.state(x, y, z).ammo, 2, "refused within the window: back")
	end)

	t.test("turret view: a drawn gun is the model at its aim, starting where the record says", function()
		local h = boot()
		local x, y, z = 3, 64, 5
		local block = B.UltimateSniperTurret
		local s = Turrets.spec(block) :: Turrets.Spec
		h.set(x, y, z, block)
		-- The record before the chunk loads (it comes with the edit list): tracking a mob the
		-- client does not draw.
		local tracking = Flag.Powered + Flag.Tracking
		h.send({
			rec(x, y, z, { yaw = 2.5, pitch = math.rad(-10), target = 9, flags = tracking + Flag.Scope, ammo = 2 }),
		})
		h.load(0, 0)
		h.frame()
		local stats = h.View.stats()
		t.eq(stats.drawn, 1, "drawn")
		local look = TurretModel.look(s, Flag.Scope)
		t.eq(stats.parts, #look.boxes, "its boxes showing")
		t.eq(h.showing(), #look.boxes, "as many parts visible")
		t.eq(#h.parts(), PER_HEAD, "one head made")
		-- No sweep from yaw 0: it starts at the record's aim; the tip's front is the server's muzzle.
		local record = h.View.state(x, y, z)
		local tip = partNamed(h, look, "MuzzleBrake", x, y, z)
		t.ok(tip ~= nil, "the muzzle brake drawn")
		local front = tip.CFrame:PointToWorldSpace(Vector3.new(0, 0, -tip.Size.Z / 2))
		local fx, fy, fz = Origin.renderToBlocks(front)
		local mx, my, mz = TurretRules.muzzle(x, y, z, record.yaw, record.pitch, s.barrel)
		t.near(fx, mx, 1e-3, "the front of the brake is the muzzle (x)")
		t.near(fy, my, 1e-3, "(y)")
		t.near(fz, mz, 1e-3, "(z)")
		local dx, dy, dz = TurretRules.direction(record.yaw, record.pitch)
		local lookVector = tip.CFrame.LookVector
		t.near(lookVector.X, dx, 1e-4, "it looks along the aim")
		t.near(lookVector.Y, dy, 1e-4)
		t.near(lookVector.Z, dz, 1e-4)
		-- The receiver casts the gun's shadow; the parts are inert.
		local receiver = partNamed(h, look, "Receiver", x, y, z)
		t.ok(receiver.CastShadow and receiver.Anchored, "the receiver's shadow, anchored")
		t.ok(not receiver.CanCollide and not receiver.CanQuery and not receiver.CanTouch, "collides with nothing")
		t.eq(receiver.Material, roblox.Enum.Material.Metal, "steel")
		-- Still: nothing moves.
		local moved = h.moved
		h.frame()
		h.frame()
		t.eq(h.moved, moved, "a still gun is not moved again")
		-- A Laser Sight fitted: dressed again (the emitter, the beam).
		h.send({
			rec(x, y, z, { yaw = 2.5, pitch = math.rad(-10), target = 9, flags = tracking + Flag.Scope + Flag.Laser }),
		})
		h.frame()
		local laser = TurretModel.look(s, Flag.Scope + Flag.Laser)
		t.ok(h.moved > moved, "re-dressed and placed")
		t.ok(h.View.stats().parts >= #laser.boxes, "the emitter shows")
	end)

	t.test("turret view: guns turn towards the drawn target at the tier's rate, the short way", function()
		local h = boot()
		local x, y, z = 0, 64, 0
		local block = B.BasicRifleTurret
		local s = Turrets.spec(block) :: Turrets.Spec
		h.set(x, y, z, block)
		h.load(0, 0)
		local tracking = Flag.Powered + Flag.Tracking
		h.send({ rec(x, y, z, { yaw = 0, target = 7, flags = tracking }) })
		-- The mob is not drawn: the record's aim.
		h.frame()
		local px, py, pz = TurretRules.pivot(x, y, z)
		-- Now it is, to the gun's right (+X): it turns at the rate.
		h.mobs[7] = { px + 10, py, pz }
		local rate = math.rad(s.turn)
		local before = h.View.muzzleNear(TurretRules.muzzle(x, y, z, 0, 0, s.barrel))
		t.ok(before ~= nil, "the drawn muzzle found from the server's")
		h.frame(0.1)
		local mx, _, mz = h.View.muzzleNear(TurretRules.muzzle(x, y, z, 0, 0, s.barrel))
		t.ok(mx ~= nil, "still found, a little turned")
		local drawnYaw = math.atan2((mx :: number) - px, (mz :: number) - pz)
		t.near(drawnYaw, rate * 0.1, 1e-6, "turned the turn rate times the frame")
		for _ = 1, 120 do
			h.frame(1 / 60)
		end
		local wantYaw = math.atan2(10, 0)
		local ex, _, ez = TurretRules.muzzle(x, y, z, wantYaw, 0, s.barrel)
		mx, _, mz = h.View.muzzleNear(ex, py, ez)
		t.near(mx :: number, ex, 1e-9, "on the target")
		t.near(mz :: number, ez, 1e-9)
		t.eq(h.head, false, "a rifle aims at bodies")
		-- Across 180: from 179 to -179 degrees it turns 2 degrees, not 358.
		h.mobs[7] = nil
		h.send({ rec(x, y, z, { yaw = math.rad(179), target = 7, flags = tracking }) })
		for _ = 1, 200 do
			h.frame(1 / 30)
		end
		h.send({ rec(x, y, z, { yaw = math.rad(-179), target = 7, flags = tracking }) })
		h.frame(1 / 240)
		local ax, _, az = h.View.muzzleNear(TurretRules.muzzle(x, y, z, math.pi, 0, s.barrel))
		local yawNow = math.atan2((ax :: number) - px, (az :: number) - pz)
		t.ok(math.abs(yawNow) > math.rad(179), `through 180 ({math.deg(yawNow)})`)
		for _ = 1, 30 do
			h.frame(1 / 60)
		end
		ax, _, az = h.View.muzzleNear(TurretRules.muzzle(x, y, z, math.rad(-179), 0, s.barrel))
		yawNow = math.atan2((ax :: number) - px, (az :: number) - pz)
		t.near(yawNow, math.rad(-179), 2 * math.pi / 65536 + 1e-9, "there")
		-- A scoped sniper aims at the head.
		h.set(0, 64, 4, B.EliteSniperTurret)
		h.send({ rec(0, 64, 4, { target = 7, flags = tracking + Flag.Scope }) })
		h.mobs[7] = { 5, 65, 4 }
		h.head = nil
		h.frame()
		t.eq(h.head, true, "the scoped sniper asks for the head")
	end)

	t.test("turret view: heads are pooled, the nearest 48 drawn, freed when gone, blocked or far", function()
		local h = boot()
		-- 60 turrets in a row along +X from the camera; chunks 0..4.
		local count = 60
		for i = 1, count do
			h.set(i, 64, 0, B.BasicSmgTurret)
		end
		for cx = 0, 4 do
			h.load(cx, 0)
		end
		h.frame()
		local stats = h.View.stats()
		local most = math.min(CLIENT.MaxDrawn, CLIENT.MaxParts // PER_HEAD)
		t.eq(stats.drawn, most, "MaxDrawn turrets drawn")
		t.ok(#h.parts() <= CLIENT.MaxParts, `at most MaxParts parts ({#h.parts()})`)
		t.eq(#h.parts(), most * PER_HEAD, "a head each, made once")
		-- The nearest: the turret at x = 1 is drawn, the one at 60 is not.
		local s = spec("smg", 1)
		t.ok(h.View.muzzleNear(TurretRules.muzzle(1, 64, 0, 0, 0, s.barrel)) ~= nil, "the nearest drawn")
		t.eq(h.View.muzzleNear(TurretRules.muzzle(60, 64, 0, 0, 0, s.barrel)), nil, "the farthest not")
		-- One broken: its head goes to the next nearest, no part made.
		h.set(1, 64, 0, B.Air)
		h.frame()
		t.eq(h.View.stats().drawn, most, "still MaxDrawn")
		t.eq(#h.parts(), most * PER_HEAD, "the freed head reused")
		t.ok(h.View.muzzleNear(TurretRules.muzzle(most + 1, 64, 0, 0, 0, s.barrel)) ~= nil, "the next one drawn")
		-- A block over a turret hides its gun; taken away, it shows again.
		h.set(2, 65, 0, B.Stone)
		h.frame()
		t.eq(h.View.muzzleNear(TurretRules.muzzle(2, 64, 0, 0, 0, s.barrel)), nil, "covered: hidden")
		h.set(2, 65, 0, B.Torch)
		h.frame()
		t.ok(h.View.muzzleNear(TurretRules.muzzle(2, 64, 0, 0, 0, s.barrel)) ~= nil, "a torch over it: shown")
		-- The server says Blocked: hidden.
		h.send({ rec(3, 64, 0, { flags = Flag.Powered + Flag.Blocked }) })
		h.frame()
		t.eq(h.View.muzzleNear(TurretRules.muzzle(3, 64, 0, 0, 0, s.barrel)), nil, "Blocked: hidden")
		h.send({ rec(3, 64, 0, { flags = Flag.Powered }) })
		h.frame()
		t.ok(h.View.muzzleNear(TurretRules.muzzle(3, 64, 0, 0, 0, s.barrel)) ~= nil, "clear again: shown")
		-- Out of DrawDistance: none.
		h.camera(1000.5, 66, 0.5)
		for _ = 1, 20 do
			h.frame(0.05)
		end
		t.eq(h.View.stats().drawn, 0, "far away: none drawn")
		t.eq(h.showing(), 0, "every part hidden")
		h.camera(0.5, 66, 0.5)
		h.frame(0.3)
		t.eq(h.View.stats().drawn, most, "back")
		-- A chunk unloaded: its turrets gone.
		h.unload(0, 0)
		h.frame()
		t.eq(h.View.muzzleNear(TurretRules.muzzle(2, 64, 0, 0, 0, s.barrel)), nil, "unloaded: gone")
		t.ok(h.View.stats().drawn <= most, "the rest")
	end)

	t.test("turret view: every head is placed again in the frame the render origin moves", function()
		local h = boot()
		local x, y, z = 4, 64, 4
		h.set(x, y, z, B.AdvancedSmgTurret)
		h.load(0, 0)
		h.send({ rec(x, y, z, { yaw = 0.7, pitch = 0.1 }) })
		h.frame()
		local positions: { [any]: any } = {}
		for _, part in h.parts() do
			if part.Transparency < 1 then
				positions[part] = part.CFrame.Position
			end
		end
		local moved = h.moved
		h.frame()
		t.eq(h.moved, moved, "still: not moved")
		-- The origin moves (Rendering/Rebase sets it before this step): every part rewritten from
		-- world blocks, as far back as the origin went.
		Origin.set(Config.Origin.Snap * 4, -Config.Origin.Snap * 2)
		h.camera(x + 0.5, 66, z + 0.5)
		h.frame()
		local count = 0
		for part, before in positions do
			count += 1
			local after = part.CFrame.Position
			t.near(after.X, before.X - Config.Origin.Snap * 4, 1e-3, "moved back by the origin (x)")
			t.near(after.Y, before.Y, 1e-6, "Y never shifts")
			t.near(after.Z, before.Z + Config.Origin.Snap * 2, 1e-3, "(z)")
		end
		t.ok(count > 0, "parts drawn")
		t.eq(h.moved - moved, count, "every shown part, once")
		-- The drawn muzzle stays in world blocks.
		local s = spec("smg", 2)
		-- (Idle: the record's yaw, level.)
		local wx, _, wz = h.View.muzzleNear(TurretRules.muzzle(x, y, z, 0.7, 0, s.barrel))
		local ex, _, ez = TurretRules.muzzle(x, y, z, h.View.state(x, y, z).yaw, 0, s.barrel)
		t.near(wx :: number, ex, 1e-9, "world blocks, whatever the origin")
		t.near(wz :: number, ez, 1e-9)
		Origin.reset()
	end)

	t.test("turret view: a Laser Sight's beam ends on the first block, or on the target it passes", function()
		local h = boot()
		local x, y, z = 0, 64, 0
		local block = B.EliteRifleTurret
		local s = Turrets.spec(block) :: Turrets.Spec
		h.set(x, y, z, block)
		-- A wall 6 blocks ahead (+Z), the ground under it.
		for wy = 60, 70 do
			for wx = -3, 3 do
				h.set(wx, wy, 7, B.Stone)
			end
		end
		h.load(0, 0)
		h.send({ rec(x, y, z, { flags = Flag.Powered + Flag.Laser }) })
		h.frame()
		local look = TurretModel.look(s, Flag.Laser)
		local sx, sy, sz = TurretModel.laserStart(look, x, y, z, 0, 0)
		local beam = nil
		for _, part in h.parts() do
			if part.Name == "Beam" and part.Transparency < 1 then
				beam = part
			end
		end
		t.ok(beam ~= nil, "the beam shows")
		t.near(beam.Size.Z / BLOCK, 7 - (sz :: number), 1e-6, "to the wall")
		t.eq(beam.Material, roblox.Enum.Material.Neon, "Neon")
		local look3 = beam.CFrame.LookVector
		t.near(look3.Z, 1, 1e-6, "along the aim")
		local bx, by, bz = Origin.renderToBlocks(beam.CFrame.Position)
		t.near(bx, sx :: number, 1e-4, "from the emitter (x)")
		t.near(by, sy :: number, 1e-4, "(y)")
		t.near(bz, ((sz :: number) + 7) / 2, 1e-4, "its middle halfway to the wall")
		t.eq(h.View.stats().parts, #look.boxes + 1, "the beam counted")
		-- A drawn target 3 blocks out on the line: the beam ends there.
		h.send({ rec(x, y, z, { target = 4, flags = Flag.Powered + Flag.Laser + Flag.Tracking }) })
		local px, py, pz = TurretRules.pivot(x, y, z)
		h.mobs[4] = { px, py, pz + 3 }
		h.frame()
		t.near(beam.Size.Z / BLOCK, pz + 3 - (sz :: number), 0.02, "to the target")
		-- No power: no beam.
		h.send({ rec(x, y, z, { flags = Flag.Laser }) })
		h.frame()
		t.eq(beam.Transparency, 1, "unpowered: no beam")
		-- Nothing ahead: BeamLength.
		h.set(0, 64, 7, B.Air)
		h.send({ rec(x, y, z, { flags = Flag.Powered + Flag.Laser, pitch = math.rad(5) }) })
		for _ = 1, 30 do
			h.frame(1 / 30)
		end
		h.set(0, 65, 7, B.Air)
		h.set(0, 66, 7, B.Air)
		for _ = 1, 10 do
			h.frame(1 / 30)
		end
		t.ok(beam.Transparency < 1, "shown again")
		t.ok(beam.Size.Z / BLOCK <= CLIENT.BeamLength + 1e-6, "at most BeamLength")
	end)

	t.test("turret view: a turning gun's beam stops at the wall it turns onto, that frame", function()
		local h = boot()
		local x, y, z = 0, 64, 0
		local s = spec("smg", 4)
		h.set(x, y, z, s.block)
		-- A pillar a block wide 3 blocks ahead (+Z), as high as the beam.
		for wy = 60, 70 do
			h.set(0, wy, 3, B.Stone)
		end
		h.load(0, 0)
		local flags = Flag.Powered + Flag.Laser + Flag.Tracking
		h.send({ rec(x, y, z, { yaw = math.rad(60), target = 9, flags = flags }) })
		h.frame(1 / 60)
		-- It turns onto the pillar at 360 degrees a second: 6 a frame, a look at the beam's block
		-- every 0.1 s would leave it through the pillar for frames.
		h.send({ rec(x, y, z, { yaw = 0, target = 9, flags = flags }) })
		local beam = nil
		for _, part in h.parts() do
			if part.Name == "Beam" then
				beam = part
			end
		end
		local worst, onIt = 0, 0
		for _ = 1, 30 do
			h.frame(1 / 60)
			if beam.Transparency < 1 then
				-- The beam's start and aim, and where it reaches the pillar's face (z 3, x 0..1).
				local aim = beam.CFrame.LookVector
				local length = beam.Size.Z / BLOCK
				local cx, _, cz = Origin.renderToBlocks(beam.CFrame.Position)
				local sx, sz = cx - aim.X * length / 2, cz - aim.Z * length / 2
				local toWall = (3 - sz) / aim.Z
				local hx = sx + aim.X * toWall
				if hx >= 0 and hx <= 1 then
					onIt += 1
					worst = math.max(worst, length - toWall)
				end
			end
		end
		t.ok(onIt > 0, "it aims at the pillar")
		t.ok(worst < 0.02, `the beam ends on the pillar ({worst} past its face)`)
	end)

	t.test("turret view: the servo loops at the nearest turning guns, a dry gun clicks", function()
		local h = boot()
		local tracking = Flag.Powered + Flag.Tracking
		for i = 1, 6 do
			h.set(i * 2, 64, 0, B.BasicSmgTurret)
		end
		h.load(0, 0)
		h.frame()
		t.eq(next(h.loops), nil, "nothing turns: no servo")
		local records = {}
		for i = 1, 6 do
			table.insert(records, rec(i * 2, 64, 0, { target = 10 + i, flags = tracking, ammo = 2 }))
			h.mobs[10 + i] = { i * 2 + 0.5, 65, 20 }
		end
		h.send(records)
		h.listener = Vector3.new(0.5, 65, 0.5)
		h.frame(1 / 60)
		local loops = 0
		for key, loop in h.loops do
			loops += 1
			t.eq(loop.name, "block.turret.servo", "the servo's loop")
			t.eq(loop.name, h.View.SERVO)
			t.ok(type(key) == "string", "on loops of its own")
		end
		t.eq(loops, CLIENT.ServoLoops, "at most ServoLoops")
		-- The nearest to the listener.
		local px = TurretRules.pivot(2, 64, 0)
		t.near(h.loops["turret.servo.1"].x, px, 1e-12, "the nearest first")
		for _, loop in h.loops do
			t.ok(loop.x <= TurretRules.pivot(2 * CLIENT.ServoLoops, 64, 0) + 1e-9, "only the nearest")
		end
		-- Settled: the loops stop.
		for _ = 1, 120 do
			h.frame(1 / 30)
		end
		t.eq(next(h.loops), nil, "settled: silent")
		-- Ran dry while tracking: a click at the gun; a record that starts empty says nothing.
		h.send({ rec(2, 64, 0, { target = 11, flags = tracking, ammo = 0 }) })
		local click = h.plays[#h.plays]
		t.ok(click and click.name == ShotRules.DRY, "the dry click")
		local cx, cy, cz = TurretRules.pivot(2, 64, 0)
		t.ok(click.x == cx and click.y == cy and click.z == cz, "at the gun")
		local played = #h.plays
		h.send({ rec(40, 64, 0, { target = 3, flags = tracking, ammo = 0 }) })
		h.send({ rec(4, 64, 0, { flags = Flag.Powered, ammo = 2 }) })
		h.send({ rec(4, 64, 0, { flags = Flag.Powered, ammo = 0 }) })
		t.eq(#h.plays, played, "no click without a fall to 0 while tracking (no turret, idle)")
		h.send({ rec(6, 64, 0, { target = 13, flags = tracking, ammo = 0 }) })
		t.eq(#h.plays, played + 1, "tracking when it fell to 0: a click")
	end)

	t.test("turret view: a fed one-round turret never clicks dry; run dry, it clicks once", function()
		local h = boot()
		local x, y, z = 2, 64, 3
		local s = spec("rifle", 1)
		t.eq(s.buffer, 1, "one round")
		h.set(x, y, z, s.block)
		h.load(0, 0)
		local function clicks(): number
			local n = 0
			for _, play in h.plays do
				if play.name == ShotRules.DRY then
					n += 1
				end
			end
			return n
		end
		local tracking = Flag.Powered + Flag.Tracking
		local firing = tracking + Flag.Firing
		-- Fed as the server sends it: none held after each shot (Firing), the next round a tick or
		-- two later.
		h.send({ rec(x, y, z, { target = 5, flags = tracking, ammo = 1 }) })
		for _ = 1, 10 do
			h.send({ rec(x, y, z, { target = 5, flags = firing, ammo = 0 }) })
			h.frame(0.1)
			h.send({ rec(x, y, z, { target = 5, flags = firing, ammo = 1 }) })
			h.frame(0.1)
		end
		t.eq(clicks(), 0, "fed: never a dry click")
		-- The last round shot and none coming: when Firing ends (the server's No ammo), one click.
		h.send({ rec(x, y, z, { target = 5, flags = firing, ammo = 0 }) })
		t.eq(clicks(), 0, "still Firing")
		h.send({ rec(x, y, z, { target = 5, flags = tracking, ammo = 0 }) })
		t.eq(clicks(), 1, "run dry: a click")
		local click = h.plays[#h.plays]
		local px, py, pz = TurretRules.pivot(x, y, z)
		t.ok(click.x == px and click.y == py and click.z == pz, "at the gun")
		h.send({ rec(x, y, z, { target = 5, flags = tracking, ammo = 0, yaw = 0.5 }) })
		t.eq(clicks(), 1, "once")
		-- A round, the shot that kills its target: no longer tracking, nothing to click at.
		h.send({ rec(x, y, z, { target = 5, flags = tracking, ammo = 1 }) })
		h.send({ rec(x, y, z, { flags = Flag.Powered, ammo = 0 }) })
		t.eq(clicks(), 1, "not tracking: no click")
	end)

	t.test("turret view: a turret's shot leaves its drawn barrel", function()
		local h = boot()
		local x, y, z = 6, 64, 6
		local s = spec("smg", 3)
		h.set(x, y, z, s.block)
		h.load(0, 0)
		h.send({ rec(x, y, z, { yaw = 1.2, pitch = 0.15, target = 1, flags = Flag.Powered + Flag.Tracking }) })
		h.frame()
		local record = h.View.state(x, y, z)
		local ox, oy, oz = TurretRules.muzzle(x, y, z, record.yaw, record.pitch, s.barrel)
		-- The record's origin is a float32.
		local f32 = buffer.create(12)
		buffer.writef32(f32, 0, ox)
		buffer.writef32(f32, 4, oy)
		buffer.writef32(f32, 8, oz)
		local mx, my, mz = h.finder(buffer.readf32(f32, 0), buffer.readf32(f32, 4), buffer.readf32(f32, 8))
		t.near(mx :: number, ox, 1e-9, "the drawn muzzle (x)")
		t.near(my :: number, oy, 1e-9, "(y)")
		t.near(mz :: number, oz, 1e-9, "(z)")
		-- The drawn gun lags the server: the shot leaves where it is drawn.
		h.send({ rec(x, y, z, { yaw = 1.6, pitch = 0.15, target = 1, flags = Flag.Powered + Flag.Tracking }) })
		h.frame(0.05)
		local sx, sy, sz = TurretRules.muzzle(x, y, z, 1.6, record.pitch, s.barrel)
		local dx, dy, dz = h.finder(sx, sy, sz)
		t.ok(dx ~= nil, "found")
		local yawDrawn = math.atan2((dx :: number) - (x + 0.5), (dz :: number) - (z + 0.5))
		t.near(yawDrawn, record.yaw + math.rad(s.turn) * 0.05, 1e-6, "where it is drawn")
		t.ok(math.abs((dy :: number) - sy) < 1e-9, "the same height")
		-- Nothing near: the origin stands (nil).
		t.eq(h.finder(ox + 3, oy, oz), nil, "no barrel there")
		t.eq(h.finder(ox, oy + 2.5, oz), nil, "nor there")
		-- A covered turret (not drawn) next to a drawn one aiming elsewhere: its shot starts at its
		-- origin, a barrel's length from the neighbour's pivot but not at its drawn muzzle.
		local sniper = spec("sniper", 1)
		local ax, ay, az, bx, by, bz = 2, 64, 2, 3, 64, 3
		h.set(ax, ay, az, sniper.block)
		h.set(ax, ay + 1, az, B.Stone)
		h.set(bx, by, bz, sniper.block)
		h.send({
			rec(ax, ay, az, { yaw = math.pi / 2, target = 1, flags = Flag.Powered + Flag.Tracking }),
			rec(bx, by, bz, { yaw = 0, target = 2, flags = Flag.Powered + Flag.Tracking }),
		})
		h.frame()
		local ex, ey, ez = TurretRules.muzzle(ax, ay, az, math.pi / 2, 0, sniper.barrel)
		local px, py, pz = TurretRules.pivot(bx, by, bz)
		t.near(math.sqrt((ex - px) ^ 2 + (ey - py) ^ 2 + (ez - pz) ^ 2), sniper.barrel, 1e-9, "the barrel's length")
		t.eq(h.finder(ex, ey, ez), nil, "not the neighbour's barrel")
		local nx, ny, nz = TurretRules.muzzle(bx, by, bz, 0, 0, sniper.barrel)
		local fx, _, fz = h.finder(nx, ny, nz)
		t.ok(fx == nx and fz == nz, "the neighbour's own shot: its barrel")
		-- ShotView's own code: shooterless turret shots go through the finder, players' don't.
		local source = fs.readFile("src/client/Rendering/ShotView.luau")
		t.ok(
			string.find(source, "if shooter == nil and ShotRules.isTurret(shot) then", 1, true) ~= nil,
			"ShotView asks the finder for turret shots only"
		)
		t.ok(
			string.find(
				fs.readFile("src/client/Rendering/TurretView.luau"),
				"ShotView.setTurretMuzzle(TurretView.muzzleNear)",
				1,
				true
			) ~= nil,
			"TurretView gives it"
		)
	end)

	t.test("turret view: a frame with 48 turrets turning, and with 48 still", function()
		local h = boot()
		local tracking = Flag.Powered + Flag.Tracking + Flag.Laser + Flag.Suppressor
		local records = {}
		local n = 0
		for row = 0, 5 do
			for col = 0, 7 do
				n += 1
				local x, z = col * 3, row * 3
				local s = Turrets.SPECS[(n - 1) % #Turrets.SPECS + 1]
				h.set(x, 64, z, s.block)
				table.insert(records, rec(x, 64, z, { target = n, flags = tracking + Flag.Scope, ammo = 2 }))
				h.mobs[n] = { x + 5, 65, z + 5 }
			end
		end
		for cx = 0, 1 do
			for cz = 0, 1 do
				h.load(cx, cz)
			end
		end
		h.send(records)
		h.camera(10, 66, 8)
		h.listener = Vector3.new(10, 66, 8)
		h.frame()
		t.eq(h.View.stats().drawn, 48, "48 drawn")
		t.ok(h.View.stats().parts <= CLIENT.MaxParts, "within MaxParts")
		-- Turning: every target moves every frame.
		local times = {}
		local movedBefore = h.moved
		local frames = 60
		for f = 1, frames do
			for i = 1, n do
				local mob = h.mobs[i]
				mob[1] += 0.05 * math.sin(f + i)
				mob[3] += 0.05 * math.cos(f + i)
			end
			local start = os.clock()
			h.frame(1 / 60)
			table.insert(times, os.clock() - start)
		end
		table.sort(times)
		local turning = times[frames // 2] * 1000
		local perFrame = (h.moved - movedBefore) / frames
		t.ok(perFrame > 48 * 9, `every head moved ({perFrame} parts a frame)`)
		-- Still: nothing moves, the frame is only the aims.
		for i = 1, n do
			h.mobs[i] = nil
		end
		h.send((function()
			local idle = {}
			for _, r in records do
				table.insert(idle, rec(r.x, r.y, r.z, { flags = Flag.Powered + Flag.Laser, ammo = 2 }))
			end
			return idle
		end)())
		for _ = 1, 120 do
			h.frame(1 / 30)
		end
		local still = {}
		local stillMoved = h.moved
		for _ = 1, frames do
			local start = os.clock()
			h.frame(1 / 60)
			table.insert(still, os.clock() - start)
		end
		table.sort(still)
		local idleMs = still[frames // 2] * 1000
		t.eq(h.moved, stillMoved, "still guns move nothing")
		-- The model's maths alone, 48 turrets.
		local numbers = {}
		local looks = {}
		for i = 1, 48 do
			looks[i] = TurretModel.look(Turrets.SPECS[(i - 1) % #Turrets.SPECS + 1], Flag.Laser + Flag.Scope)
		end
		local mathTimes = {}
		for f = 1, 20 do
			local start = os.clock()
			for i = 1, 48 do
				TurretModel.place(looks[i], i, 64, 0, f * 0.01 + i, 0.1, numbers)
			end
			table.insert(mathTimes, os.clock() - start)
		end
		table.sort(mathTimes)
		local mathMs = mathTimes[10] * 1000
		print(
			string.format(
				"    (48 turrets: %.3f ms a frame turning (%.0f parts moved, under Lune's fake Instances), %.3f ms still, %.3f ms the model's maths)",
				turning,
				perFrame,
				idleMs,
				mathMs
			)
		)
		t.ok(mathMs < 2, `the maths of 48 heads within 2 ms ({mathMs})`)
		t.ok(idleMs < 2, `48 still turrets within 2 ms ({idleMs})`)
		t.ok(turning < 25, `48 turning turrets within 25 ms in Lune ({turning})`)
	end)

	--[[ Shots ]]

	t.test("turret client: a turret's shot sounds as its stand-in gun, plain when suppressed", function()
		local out = ShotRules.newEffects()
		local function shot(turretType: string, fields: { [string]: any }?): any
			local s = spec(turretType, 2)
			local made: any = {
				shooter = ShotRules.TURRET,
				item = s.firearm,
				shot = 1,
				suppressed = false,
				jammed = false,
				refused = false,
				ox = 1,
				oy = 65,
				oz = 1,
				pellets = { { x = 5, y = 65, z = 1, hit = 3 } },
			}
			for key, value in fields or {} do
				made[key] = value
			end
			return made
		end
		t.eq(ShotRules.TURRET, 0, "no player")
		t.ok(ShotRules.isTurret(shot("smg")), "a turret's")
		ShotRules.effects(shot("smg"), 12345, 10, true, out)
		t.eq(out.sound, "item.firearm.smg.fire", "the SMG's class")
		t.ok(out.flash and out.tracer == (Config.Weapons.Tracers == true) and out.glow, "flash, tracers that glow")
		t.ok(out.impacts and not out.own and not out.stop, "impacts; never the player's own")
		ShotRules.effects(shot("rifle"), 12345, 10, true, out)
		t.eq(out.sound, (Weapons.firearm(spec("rifle", 1).firearm) :: Weapons.FirearmSpec).sound, "the rifle's")
		ShotRules.effects(shot("sniper"), 12345, 10, true, out)
		t.eq(out.sound, "item.firearm.heavy.fire", "the sniper's heavy shot")
		-- A Suppressor: suppressed and plain. An Improvised Suppressor: suppressed, glowing.
		ShotRules.effects(shot("smg", { suppressed = true, plain = true }), 12345, 10, true, out)
		t.ok(out.sound == ShotRules.SUPPRESSED and not out.flash and not out.glow, "suppressed, no flash, plain")
		ShotRules.effects(shot("smg", { suppressed = true, plain = false }), 12345, 10, true, out)
		t.ok(out.sound == ShotRules.SUPPRESSED and not out.flash and out.glow, "improvised: its tracers glow")
		-- Far: the far roll; suppressed and far: unheard.
		ShotRules.effects(shot("rifle"), 12345, Config.Weapons.FarSound + 1, true, out)
		t.eq(out.sound, ShotRules.FAR, "far")
		ShotRules.effects(
			shot("rifle", { suppressed = true, plain = true }),
			12345,
			Config.Weapons.FarSound + 1,
			true,
			out
		)
		t.eq(out.sound, nil, "suppressed far away: unheard")
		-- Never the player's own, whatever their id.
		ShotRules.effects(shot("smg"), 0, 10, true, out)
		t.ok(not out.own and out.flash, "a player id 0 still sees it")
		-- A player's shot is as before: `plain` absent, the glow the caller's.
		local player = shot("smg", { shooter = 777, item = I.Pistol })
		player.plain = nil
		ShotRules.effects(player, 12345, 10, true, out)
		t.ok(out.glow and out.sound == "item.firearm.pistol.fire", "a player's shot")
		ShotRules.effects(player, 12345, 10, false, out)
		t.ok(not out.glow, "a suppressor's held look")
		ShotRules.effects(player, 777, 10, true, out)
		t.ok(out.own and not out.flash, "the player's own")
	end)

	t.test("turret client: MobRenderer.aimPoint is the drawn mob's body or head centre", function()
		local handlers = {}
		local load = FakeClient.loader(shared, require, {
			["src/client/Net/ClientNet.luau"] = {
				on = function(kind: number, fn: any)
					handlers[kind] = fn
				end,
			},
			["src/client/Audio/SoundPlayer.luau"] = {
				play = function() end,
				listener = function(): any
					return nil
				end,
			},
			["src/client/Player/MovementController.luau"] = { knockback = function() end },
			["src/client/World/ClientWorld.luau"] = {},
		}, {
			RunService = { BindToRenderStep = function() end },
		})
		local MobRenderer = load("src/client/Entities/MobRenderer.luau")
		local zombie = MobList.find("Zombie") :: number
		local payload = Protocol.encodeMobs({
			{
				op = "spawn",
				id = 9,
				kind = zombie,
				variant = 1,
				x = 10.5,
				y = 64,
				z = 5.25,
				yaw = 0.75,
				health = 20,
				flags = 0,
			},
		})
		handlers[Protocol.ServerMessage.Mobs](payload)
		local op = (Protocol.decodeMobs(payload, MobList.COUNT) :: any)[1]
		local kind = MobList.get(zombie) :: MobList.Kind
		local body, head = Ballistics.mobBoxes(kind, op.x, op.y, op.z, op.yaw)
		local x, y, z = MobRenderer.aimPoint(9)
		t.near(x :: number, (body[1] + body[4]) / 2, 1e-9, "the body's centre (x)")
		t.near(y :: number, (body[2] + body[5]) / 2, 1e-9, "(y)")
		t.near(z :: number, (body[3] + body[6]) / 2, 1e-9, "(z)")
		x, y, z = MobRenderer.aimPoint(9, true)
		t.near(x :: number, (head[1] + head[4]) / 2, 1e-9, "the head's centre (x)")
		t.near(y :: number, (head[2] + head[5]) / 2, 1e-9, "(y)")
		t.near(z :: number, (head[3] + head[6]) / 2, 1e-9, "(z)")
		t.ok(y :: number > (body[2] + body[5]) / 2, "above the body's")
		t.eq(MobRenderer.aimPoint(10), nil, "a mob not drawn")
		handlers[Protocol.ServerMessage.Mobs](Protocol.encodeMobs({ { op = "remove", id = 9 } }))
		t.eq(MobRenderer.aimPoint(9), nil, "gone")
	end)

	--[[ WAILA and F3 ]]

	t.test("turret client: WAILA says the rounds, the feed and what is mounted; F3 the record", function()
		local block = B.EliteSmgTurret
		local s = Turrets.spec(block) :: Turrets.Spec
		local function machine(status: number, feed: number): WailaInfo.MachineFacts
			return {
				energy = 40000,
				capacity = s.capacity,
				input = 0,
				output = 0,
				rate = -24,
				active = true,
				state = Turrets.packState(status, feed, true, true),
			}
		end
		local record = {
			x = 1,
			y = 64,
			z = 2,
			yaw = math.rad(90),
			pitch = math.rad(-12),
			target = 5,
			flags = Flag.Powered + Flag.Tracking + Flag.Laser + Flag.Suppressor,
			ammo = 3,
		}
		local facts = WailaInfo.turretFacts(record)
		local info = WailaInfo.block(block, nil, 1, 64, 2, false, {
			machine = machine(Turrets.STATUS.TARGETING, 3),
			turret = facts,
		})
		local texts = table.concat(WailaInfo.texts(info), "\n")
		t.ok(string.find(texts, "Elite SMG Turret", 1, true), "its name")
		t.ok(string.find(texts, "\nTargeting\n", 1, true), `its status ({texts})`)
		t.ok(string.find(texts, "\nAmmo 3 / 4 · 9mm\n", 1, true), "the rounds of its buffer and calibre")
		t.ok(string.find(texts, "\nFeed: Elite\n", 1, true), "the feed")
		t.ok(string.find(texts, "\nFitted: Laser Sight, Suppressor\n", 1, true), "what is mounted")
		t.ok(not string.find(texts, "Turret target", 1, true), "the record's details with F3 only")
		-- The feed as the panel says it, the panel's own line.
		for feed = 0, 4 do
			local view = {
				block = block,
				energy = 0,
				capacity = s.capacity,
				input = 0,
				output = 0,
				rate = 0,
				active = false,
				state = Turrets.packState(0, feed, true, false),
			}
			local panel = nil
			for _, line in Machines.lines(block, view) do
				if string.sub(line, 1, 5) == "Feed:" then
					panel = line
				end
			end
			t.eq(`Feed: {WailaInfo.feedText(block, view.state)}`, panel, `feed {feed}: the panel's words`)
		end
		t.eq(WailaInfo.feedText(block, Turrets.packState(0, 1, true, false)), "Basic → 90 rpm", "a lower feeder")
		t.eq(WailaInfo.feedText(block, Turrets.packState(0, 0, true, false)), "by hand", "none")
		-- The other calibres; no record: no rounds (red), nothing mounted.
		local rifle =
			WailaInfo.turretLines(B.BasicRifleTurret, WailaInfo.turretFacts(nil), Turrets.packState(0, 0, true, false))
		t.eq(WailaInfo.text(rifle[1]), "Ammo 0 / 1 · 5.56", "a rifle's")
		t.eq(rifle[1][2].colour, "red", "none held: red")
		t.eq(#rifle, 2, "nothing mounted: no line")
		local sniper = WailaInfo.turretLines(
			B.UltimateSniperTurret,
			WailaInfo.turretFacts({
				x = 0,
				y = 0,
				z = 0,
				yaw = 0,
				pitch = 0,
				target = 0,
				flags = Flag.Scope,
				ammo = 2,
			}),
			0
		)
		t.eq(WailaInfo.text(sniper[1]), "Ammo 2 / 2 · .308", "a sniper's")
		t.eq(sniper[1][2].colour, "white")
		t.eq(WailaInfo.text(sniper[3]), "Fitted: Rifle Scope", "its scope")
		-- F3: the target, the aim and the flags.
		local extended = WailaInfo.block(block, nil, 1, 64, 2, true, {
			machine = machine(Turrets.STATUS.FIRING, 4),
			turret = facts,
		})
		local details = table.concat(WailaInfo.texts(extended), "\n")
		t.ok(
			string.find(details, "Turret target mob 5, yaw 90.0, pitch -12", 1, true),
			`the target and aim ({details})`
		)
		t.ok(string.find(details, "Flags 105 (powered, laser, suppressor, tracking), 3 rounds", 1, true), "the flags")
		local idle = WailaInfo.block(block, nil, 1, 64, 2, true, {
			machine = machine(Turrets.STATUS.NO_TARGET, 0),
			turret = WailaInfo.turretFacts(nil),
		})
		t.ok(string.find(table.concat(WailaInfo.texts(idle), "\n"), "Turret: no record (idle)", 1, true), "no record")
		-- Waila asks TurretView for the record.
		local waila = fs.readFile("src/client/Ui/Waila.luau")
		t.ok(
			string.find(waila, "WailaInfo.turretFacts(TurretView.state(hit.x, hit.y, hit.z))", 1, true),
			"Waila's facts"
		)
		t.ok(string.find(waila, "turret = turret,", 1, true), "in the context")
	end)

	t.test("turret client: F3's turret line", function()
		local h = boot()
		h.set(1, 64, 1, B.BasicRifleTurret)
		h.set(3, 64, 1, B.BasicSmgTurret)
		h.load(0, 0)
		h.send({
			rec(1, 64, 1, { target = 2, flags = Flag.Powered + Flag.Tracking + Flag.Laser }),
			rec(3, 64, 1, { ammo = 2 }),
		})
		h.frame()
		local stats = h.View.stats()
		t.eq(stats.drawn, 2, "two drawn")
		t.eq(stats.records, 2, "two records")
		t.eq(stats.tracking, 1, "one tracking")
		t.eq(
			h.View.describe(),
			`turrets 2 drawn / 2 records, 1 tracking, {stats.parts} parts`,
			"turrets N drawn / M records, K tracking, P parts"
		)
		local rifle = TurretModel.look(spec("rifle", 1), Flag.Laser)
		local smg = TurretModel.look(spec("smg", 1), 0)
		t.ok(stats.parts >= #rifle.boxes + #smg.boxes, "their parts")
		local overlay = fs.readFile("src/client/Debug/DebugOverlay.luau")
		t.ok(string.find(overlay, "TurretView.describe(),", 1, true), "in the overlay, after the mobs")
	end)
end
