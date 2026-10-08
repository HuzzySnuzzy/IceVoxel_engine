--[[
	The floating origin (Shared/World/Origin, pure): conversions between world blocks and render
	studs round-trip exactly for block centres anywhere up to 1e6 blocks out (float32, the origin
	within one snap); the origin is a multiple of Snap (blocks, chunks, the lighting grid and texture
	tiles line up); `plan`'s hard, soft and hidden thresholds on both axes and signs, `planTo` for
	teleports; a long flight keeps the camera within RebaseDistance of the origin; `set` returns the
	move, counts epochs and calls listeners in order, disconnects; with Config.Origin.Enabled off
	nothing plans a move and every conversion is the identity; `reset`. And Movement/Rig's placement
	helpers: `rootCFrame` is MovementController's formula (Rig.feet reads it back), `yaw` survives a
	body lying flat, `deathCFrame` rolls a body onto its side about its feet.

	Origin's (and Rig's) Vector3 / CFrame functions read Roblox's globals when called: this spec
	lends them Lune's (float32, like Roblox's) and takes them back at the end.
]]

local roblox = require("@lune/roblox")

return function(t, shared, require, _server, _client)
	local Config = require(shared.Config)
	local Origin = require(shared.World.Origin)
	local Hash = require(shared.Util.Hash)

	local V3 = roblox.Vector3
	local CF = roblox.CFrame
	local BLOCK = Config.BlockSize
	local Settings = Config.Origin
	local wasEnabled = Settings.Enabled

	-- (Globals the loaded modules see; whatever was there comes back at the end.)
	local lentVector3, lentCFrame = Vector3, CFrame
	Vector3, CFrame = V3, CF
	Origin.reset()

	local function enabled(on: boolean)
		Settings.Enabled = on
	end

	-- The difference of two angles (radians), wrapped into [0, pi].
	local function angle(a: number, b: number): number
		local d = (a - b) % (2 * math.pi)
		return math.min(d, 2 * math.pi - d)
	end

	t.test("origin: the snap lines up blocks, chunks, the lighting grid and texture tiles", function()
		local snap = Settings.Snap
		t.eq(snap % BLOCK, 0, "a whole number of blocks")
		t.eq(snap % (BLOCK * Config.ChunkSize), 0, "a whole number of chunks")
		t.eq(snap % 4, 0, "the 4-stud lighting grid")
		t.eq(snap % 256, 0, "power-of-two texture tiles up to 256 studs")
		for _, studs in { 0, 1, 383, 384, 385, 767, 768, -1, -383, -385, -768, 8191.5, 1e6 * 3 + 1.5, -3e6 } do
			local s = Origin.snap(studs)
			t.eq(s % snap, 0, `snap({studs}) is a multiple`)
			t.ok(math.abs(s - studs) <= snap / 2, `snap({studs}) = {s} is the nearest`)
		end
	end)

	t.test("origin: off (and at 0) every conversion is the identity and nothing moves", function()
		enabled(false)
		Origin.reset()
		t.eq(Origin.blocksToRender(10, 64, -20), V3.new(30, 192, -60), "blocksToRender")
		t.eq(Origin.blockCentreToRender(10, 64, -20), V3.new(31.5, 193.5, -58.5), "blockCentreToRender")
		t.eq(Origin.studsToRender(30, 192, -60), V3.new(30, 192, -60), "studsToRender")
		t.eq(Origin.renderX(123.25), 123.25)
		t.eq(Origin.renderZ(-123.25), -123.25)
		local v = V3.new(1234567, 89, -7654321)
		t.eq(Origin.toRender(v), v, "toRender")
		t.eq(Origin.toWorld(v), v, "toWorld")
		local cf = CF.new(5, 6, 7) * CF.Angles(0, 1, 0)
		t.eq(Origin.cframeToRender(cf), cf, "cframeToRender")
		local x, y, z = Origin.renderToBlocks(V3.new(30, 192, -60))
		t.eq(x, 10)
		t.eq(y, 64)
		t.eq(z, -20)
		local sx, sy, sz = Origin.renderToStuds(V3.new(30, 192, -60))
		t.eq(sx, 30)
		t.eq(sy, 192)
		t.eq(sz, -60)
		t.eq(Origin.offset(), V3.new(0, 0, 0), "offset")
		-- Nothing plans a move, however far the camera or a teleport goes.
		t.eq(Origin.plan(1e7, -1e7, true), nil, "plan")
		t.eq(Origin.planTo(3e6, 3e6), nil, "planTo")
	end)

	t.test("origin: block centres round-trip exactly up to 1e6 blocks out (float32)", function()
		local rng = Hash.rng(7)
		local inexact = 0
		for i = 1, 20000 do
			local x = rng:int(-1000000, 1000000)
			local z = rng:int(-1000000, 1000000)
			local y = rng:int(0, 1023)
			-- The origin anywhere within one snap of the block (the camera may be up to that far).
			local shift = (i % 3 - 1) * Settings.Snap
			Origin.reset()
			Origin.set(Origin.snap((x + 0.5) * BLOCK) + shift, Origin.snap((z + 0.5) * BLOCK) - shift)
			local v = Origin.blockCentreToRender(x, y, z)
			local bx, by, bz = Origin.renderToBlocks(v)
			if bx ~= x + 0.5 or by ~= y + 0.5 or bz ~= z + 0.5 then
				inexact += 1
			end
			-- And corners (block faces) the same way.
			local c = Origin.blocksToRender(x, y, z)
			local cx, cy, cz = Origin.renderToBlocks(c)
			if cx ~= x or cy ~= y or cz ~= z then
				inexact += 1
			end
		end
		t.eq(inexact, 0, "inexact round trips")
		Origin.reset()
	end)

	t.test("origin: far out, positions near the origin keep 1/1024 stud (at 0 they lose 0.1)", function()
		local rng = Hash.rng(11)
		local worstNear, worstAtZero = 0, 0
		for _ = 1, 2000 do
			-- Anything (an item, a mob, a player between ticks) about 1e6 blocks out.
			local x = rng:int(999000, 1000000) + rng:float()
			local z = -rng:int(999000, 1000000) - rng:float()
			local y = rng:int(0, 1023) + rng:float()
			-- The camera (so the origin) within RebaseDistance of it.
			Origin.reset()
			Origin.set(Origin.snap(x * BLOCK - Settings.RebaseDistance), Origin.snap(z * BLOCK + 1000))
			local bx, _, bz = Origin.renderToBlocks(Origin.blocksToRender(x, y, z))
			worstNear = math.max(worstNear, math.abs(bx - x) * BLOCK, math.abs(bz - z) * BLOCK)
			Origin.reset()
			bx, _, bz = Origin.renderToBlocks(Origin.blocksToRender(x, y, z))
			worstAtZero = math.max(worstAtZero, math.abs(bx - x) * BLOCK, math.abs(bz - z) * BLOCK)
		end
		t.ok(worstNear <= 1 / 1024, `near the origin: {worstNear} studs`)
		t.ok(worstAtZero >= 0.1, `with no origin: {worstAtZero} studs`)
	end)

	t.test("origin: conversions subtract the origin from X and Z only", function()
		Origin.reset()
		Origin.set(7680, -15360)
		t.eq(Origin.blocksToRender(2600, 70, -5100), V3.new(2600 * 3 - 7680, 210, -5100 * 3 + 15360))
		t.eq(Origin.studsToRender(8000, 5, -15000), V3.new(320, 5, 360))
		t.eq(Origin.renderX(8000), 320)
		t.eq(Origin.renderZ(-15000), 360)
		t.eq(Origin.toRender(V3.new(8000, 5, -15000)), V3.new(320, 5, 360))
		t.eq(Origin.toWorld(V3.new(320, 5, 360)), V3.new(8000, 5, -15000))
		t.eq(Origin.offset(), V3.new(7680, 0, -15360))
		local cf = Origin.cframeToRender(CF.new(8000, 5, -15000) * CF.Angles(0, 0.5, 0))
		t.eq(cf.Position, V3.new(320, 5, 360), "cframe position")
		t.ok(cf.LookVector:FuzzyEq(CF.Angles(0, 0.5, 0).LookVector, 1e-6), "cframe rotation kept")
		local sx, sy, sz = Origin.renderToStuds(V3.new(320, 5, 360))
		t.eq(sx, 8000)
		t.eq(sy, 5)
		t.eq(sz, -15000)
		local x, y, z = Origin.renderToBlocks(V3.new(-180, 210, 60))
		t.eq(x, 2500)
		t.eq(y, 70)
		t.eq(z, -5100)
		Origin.reset()
	end)

	t.test("origin: plan moves at RebaseDistance, or at SoftDistance when hidden, on both axes", function()
		enabled(true)
		local hard, soft = Settings.RebaseDistance, Settings.SoftDistance
		for _, start in { { 0, 0 }, { 768 * 5, -768 * 9 } } do
			Origin.reset()
			Origin.set(start[1], start[2])
			local ox, oz = Origin.x, Origin.z
			for _, sign in { 1, -1 } do
				-- Within: nothing, hidden or not.
				t.eq(Origin.plan(sign * hard, 0, false), nil, "at the hard distance")
				t.eq(Origin.plan(0, sign * soft, true), nil, "at the soft distance, hidden")
				t.eq(Origin.plan(sign * (soft + 1), sign * 100, false), nil, "past soft, not hidden")
				-- Past the hard distance on X: the origin goes under the camera.
				local x, z = Origin.plan(sign * (hard + 0.5), 100, false)
				t.eq(x, Origin.snap(ox + sign * (hard + 0.5)), "hard X")
				t.eq(z, oz, "hard X leaves Z (100 snaps to 0)")
				-- On Z.
				x, z = Origin.plan(-200, sign * (hard + 10), false)
				t.eq(x, ox, "hard Z leaves X")
				t.eq(z, Origin.snap(oz + sign * (hard + 10)), "hard Z")
				-- Hidden, past the soft distance.
				x, z = Origin.plan(sign * (soft + 1), 0, true)
				t.eq(x, Origin.snap(ox + sign * (soft + 1)), "soft X")
				t.eq(z, oz, "soft X leaves Z")
				x, z = Origin.plan(0, sign * (soft + 1), true)
				t.eq(z, Origin.snap(oz + sign * (soft + 1)), "soft Z")
			end
			-- Never for a camera that isn't finite.
			t.eq(Origin.plan(0 / 0, 0, true), nil, "NaN")
			t.eq(Origin.plan(math.huge, 0, true), nil, "inf")
		end
		Origin.reset()
		enabled(wasEnabled)
	end)

	t.test("origin: planTo moves to a teleport's destination beyond SoftDistance", function()
		enabled(true)
		Origin.reset()
		local soft = Settings.SoftDistance
		t.eq(Origin.planTo(soft, -soft), nil, "within the soft distance")
		local x, z = Origin.planTo(soft + 1, 10)
		t.eq(x, Origin.snap(soft + 1))
		t.eq(z, 0)
		x, z = Origin.planTo(-3e6 + 0.5, 3e6 - 0.5)
		t.eq(x, Origin.snap(-3e6 + 0.5))
		t.eq(z, Origin.snap(3e6 - 0.5))
		Origin.set(x :: number, z :: number)
		t.eq(Origin.planTo(-3e6 + 100, 3e6 - 100), nil, "already there")
		t.eq(Origin.planTo(0 / 0, 0), nil, "NaN")
		Origin.reset()
		enabled(wasEnabled)
	end)

	t.test("origin: a long flight keeps the camera within RebaseDistance of the origin", function()
		enabled(true)
		Origin.reset()
		local hard = Settings.RebaseDistance
		local moves, worst = 0, 0
		-- Spectator speed (about 87 blocks a second) for 1e6 blocks diagonally, a frame at 60 Hz.
		local step = 87 * BLOCK / 60
		local wx, wz = 0, 0
		while wx < 1e6 * BLOCK do
			wx += step
			wz -= step * 0.6
			local rx, rz = Origin.renderX(wx), Origin.renderZ(wz)
			local x, z = Origin.plan(rx, rz, false)
			if x and z then
				Origin.set(x, z)
				moves += 1
				rx, rz = Origin.renderX(wx), Origin.renderZ(wz)
				t.ok(
					math.abs(rx) <= Settings.Snap / 2 and math.abs(rz) <= Settings.Snap / 2,
					"the camera near 0 after a move"
				)
			end
			worst = math.max(worst, math.abs(rx), math.abs(rz))
		end
		t.ok(worst <= hard + step, `the camera stays within {hard} studs ({worst})`)
		-- About one move every (hard - snap / 2) studs of travel along X.
		local expected = 1e6 * BLOCK / (hard - Settings.Snap / 2)
		t.ok(moves >= expected * 0.9 and moves <= expected * 1.1, `{moves} moves ({expected} expected)`)
		Origin.reset()
		enabled(wasEnabled)
	end)

	t.test("origin: set returns the move, counts epochs and calls listeners in order", function()
		Origin.reset()
		local calls = {}
		local disconnectA = Origin.onRebase(function(dx, dz, epoch)
			table.insert(calls, { "a", dx, dz, epoch })
		end)
		Origin.onRebase(function(dx, dz, epoch)
			table.insert(calls, { "b", dx, dz, epoch })
		end)
		local dx, dz = Origin.set(768, -1536)
		t.eq(dx, 768)
		t.eq(dz, -1536)
		t.eq(Origin.x, 768)
		t.eq(Origin.z, -1536)
		t.eq(Origin.epoch, 1)
		t.eq(#calls, 2, "both listeners")
		t.eq(calls[1][1], "a", "in order")
		t.eq(calls[2][1], "b")
		t.eq(calls[2][2], 768)
		t.eq(calls[2][3], -1536)
		t.eq(calls[2][4], 1, "with the epoch")
		-- Setting it where it is: nothing.
		dx, dz = Origin.set(768, -1536)
		t.eq(dx, 0)
		t.eq(dz, 0)
		t.eq(Origin.epoch, 1, "no epoch for no move")
		t.eq(#calls, 2, "no calls for no move")
		-- A disconnected listener hears nothing more.
		disconnectA()
		disconnectA()
		Origin.set(0, 0)
		t.eq(#calls, 3)
		t.eq(calls[3][1], "b")
		t.eq(calls[3][2], -768)
		t.eq(calls[3][3], 1536)
		t.eq(calls[3][4], 2)
		-- A listener may disconnect itself while being called.
		local disconnectC
		local heardC = 0
		disconnectC = Origin.onRebase(function()
			heardC += 1
			disconnectC()
		end)
		Origin.set(768, 0)
		Origin.set(0, 0)
		t.eq(heardC, 1, "once")
		t.ok(not pcall(Origin.set, 0 / 0, 0), "a NaN origin is refused")
		-- Reset: back to 0, epoch 0, nobody listening.
		Origin.reset()
		t.eq(Origin.x, 0)
		t.eq(Origin.z, 0)
		t.eq(Origin.epoch, 0)
		local before = #calls
		Origin.set(768, 768)
		t.eq(#calls, before, "no listeners after reset")
		Origin.reset()
	end)

	--[[ Rig's placement helpers (render feet in, a root CFrame out) ]]

	local Rig = require(shared.Movement.Rig)
	local lentEnum = Enum
	Enum = roblox.Enum

	-- A character just big enough for Rig: an R15 root 2 studs tall over a 2-stud hip.
	local function character(): any
		local root: any = { Size = V3.new(2, 2, 1), CFrame = CF.new(), Position = V3.zero }
		function root.IsA(_, class: string): boolean
			return class == "BasePart"
		end
		local humanoid = { RigType = roblox.Enum.HumanoidRigType.R15, HipHeight = 2 }
		return {
			root = root,
			FindFirstChild = function(_, name: string)
				return if name == "HumanoidRootPart" then root else nil
			end,
			FindFirstChildOfClass = function(_, class: string)
				return if class == "Humanoid" then humanoid else nil
			end,
		}
	end

	t.test("rig: rootCFrame is MovementController's placement, and Rig.feet reads it back", function()
		local body = character()
		for _, case in
			{
				{ V3.new(30, 192, -60), 0, 0, math.pi / 2 },
				{ V3.new(-1000.5, 66, 2000.25), 2.5, 1, math.pi / 2 },
				{ V3.new(7, 100, 7), -1, 0.5, 0.3 },
				{ V3.new(7, 100, 7), 4, 0.75, math.pi },
			}
		do
			local feet, yaw, tilt, bodyPitch = case[1], case[2], case[3], case[4]
			local cf = Rig.rootCFrame(body, feet, yaw, tilt, bodyPitch)
			-- (MovementController's own lines, with view.feet * BLOCK = feet.)
			local rootHeight = Rig.rootHeight(body, tilt)
			local want = CF.new(feet + V3.new(0, rootHeight, 0))
				* CF.Angles(0, yaw, 0)
				* CF.Angles(-bodyPitch * tilt, 0, 0)
			t.ok(cf.Position:FuzzyEq(want.Position, 1e-4), "position")
			t.ok(cf.LookVector:FuzzyEq(want.LookVector, 1e-6), "look")
			t.ok(cf.UpVector:FuzzyEq(want.UpVector, 1e-6), "up")
			-- The yaw comes back at any body pitch (ToOrientation's is lost lying flat).
			t.ok(angle(Rig.yaw(cf), yaw) <= 1e-5, `yaw {Rig.yaw(cf)} for {yaw} at tilt {tilt}`)
			if bodyPitch == math.pi / 2 then
				body.root.CFrame, body.root.Position = cf, cf.Position
				local back = Rig.feet(body) :: any
				t.ok((back * BLOCK):FuzzyEq(feet, 1e-3), `Rig.feet {back * BLOCK} for {feet}`)
			end
		end
	end)

	t.test("rig: deathCFrame rolls the body onto its side about the feet, as Minecraft's", function()
		local base = CF.new(10, 50, -20) * CF.Angles(0, 1.2, 0)
		local h = 3
		local feetAt = function(cf: any): any
			return (cf * CF.new(0, -h, 0)).Position
		end
		t.ok(Rig.deathCFrame(base, 0, h).UpVector:FuzzyEq(base.UpVector, 1e-6), "standing at first")
		local half = Rig.deathCFrame(base, 0.1, h)
		local expected = math.sqrt(0.16) * math.pi / 2
		t.near(math.acos(math.clamp(half.UpVector:Dot(base.UpVector), -1, 1)), expected, 1e-4, "sqrt pace")
		for _, progress in { 0.625, 1, 5 } do
			local dead = Rig.deathCFrame(base, progress, h)
			t.ok(dead.UpVector:FuzzyEq(-base.RightVector, 1e-5), "on its left side")
			t.ok(dead.LookVector:FuzzyEq(base.LookVector, 1e-5), "still facing the same way")
			t.ok(feetAt(dead):FuzzyEq(feetAt(base), 1e-4), "the feet stay")
		end
		t.ok(Rig.deathCFrame(base, 1).Position:FuzzyEq(base.Position, 1e-5), "no height: about the root")
	end)

	Enum = lentEnum
	Origin.reset()
	enabled(wasEnabled)
	Vector3, CFrame = lentVector3, lentCFrame
end
