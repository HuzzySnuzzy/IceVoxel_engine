--[[
	The camera in the manner of DayZ, through its pure rules (Player/CameraRules): the views and
	Toggle Perspective (none while raised or for spectators; V's sights only from third person),
	the rig's profiles by stance and DayZ's blend times, SmoothCD against Enforce's formula, the
	rig easing without overshoot, the shoulder's side, the jump's lag, the collision's clip and
	boom, the first-person eye point, the targeting ray's eye-plane skip, the ground heading,
	freelook (its room across the +-pi wrap, the snap back and input during it, hold and toggle),
	the body turning to the aim, focus and the view bob's share; Config.Camera's numbers (DayZ's
	cameras in studs); and the require rules of the camera's modules (Player/CameraRig needs no
	Ui/ or Interaction/ module nor the movement or the aim camera; Player/FirstPersonBody only the
	rig, its rules, the spectators' rules and Config).
]]

local fs = require("@lune/fs")

return function(t, shared, require, _server, client)
	local Config = require(shared.Config)
	local CameraRules = require(client.Player.CameraRules)

	local C = Config.Camera
	local DT = 1 / 60
	local rad = math.rad

	local function stance(fields: { [string]: any }?): any
		local s = {
			sprinting = false,
			sneaking = false,
			tilt = 0,
			climbing = false,
			swimming = false,
			flying = false,
			onGround = true,
		}
		for key, value in fields or {} do
			(s :: any)[key] = value
		end
		return s
	end

	--[[ Views ]]

	t.test("camera rules: the view, Toggle Perspective (not while raised, not for spectators)", function()
		local view = CameraRules.view
		t.eq(view("third", "lowered", false), "third")
		t.eq(view("third", "raised", false), "third", "raised over the shoulder")
		t.eq(view("third", "sights", false), "sights", "V from third person: the sights at the eyes")
		t.eq(view("first", "lowered", false), "first")
		t.eq(view("first", "raised", false), "first")
		t.eq(view("first", "sights", false), "first", "the sights from first person stay first person")
		for _, chosen in { "third", "first" } do
			for _, posture in { "lowered", "raised", "sights" } do
				t.eq(view(chosen :: any, posture :: any, true), "first", "spectators see from the eyes")
			end
		end
		local toggle = CameraRules.toggle
		t.eq(toggle("third", "lowered", false), "first")
		t.eq(toggle("first", "lowered", false), "third")
		t.eq(toggle("third", "raised", false), "third", "no toggle while raised (DayZ's camChange)")
		t.eq(toggle("first", "sights", false), "first", "nor in the sights")
		t.eq(toggle("third", "lowered", true), "third", "nor for spectators")
		t.eq(toggle("first", "lowered", true), "first")
		t.eq(CameraRules.bobShare("third"), 0, "no view bob over the shoulder")
		t.eq(CameraRules.bobShare("first"), 1)
		t.eq(CameraRules.bobShare("sights"), 1)
	end)

	--[[ The rig ]]

	t.test("camera rules: Config.Camera's rigs are DayZ's cameras in studs", function()
		t.eq(C.Enabled, true)
		t.eq(C.DefaultView, "third")
		local expect = {
			standing = { 4.8, 0.9, 0.25, 0 },
			sprinting = { 6.0, 0.45, 0.1, 0 },
			crouching = { 4.2, 0.9, 0.3, 0.3 },
			lying = { 3.0, 1.5, 0.6, 0 },
			climbing = { 3.6, 0.9, 0.3, 0 },
			flying = { 6.0, 0.9, 0.25, 0 },
			raised = { 2.4, 1.5, 0.0, 0.6 },
			raisedHands = { 3.6, 1.2, 0.0, 0.6 },
			crouchRaised = { 2.4, 1.5, 0.1, 0.3 },
		}
		local count = 0
		for key, row in expect do
			count += 1
			local p = CameraRules.profile(key)
			t.eq(p.distance, row[1], `{key}'s distance`)
			t.eq(p.shoulder, row[2], `{key}'s shoulder`)
			t.eq(p.height, row[3], `{key}'s height`)
			t.eq(p.forward, row[4], `{key}'s forward`)
		end
		local configured = 0
		for _ in C.Profiles :: any do
			configured += 1
		end
		t.eq(configured, count, "every rig pinned")
		-- DayZ's metres x 3: Erc 1.6 m behind and 0.3 m over, ErcRaised 0.8 and 0.5.
		t.near(CameraRules.profile("standing").distance, 1.6 * 3, 1e-9)
		t.near(CameraRules.profile("raised").shoulder, 0.5 * 3, 1e-9)
		t.eq(CameraRules.profile("nope"), CameraRules.profile("standing"), "an unknown rig is standing's")
		local numbers = {
			FreelookYaw = 160,
			FreelookYawFirst = 100,
			SnapBackSeconds = 0.14,
			Margin = 0.3,
			EaseOut = 6,
			FirstForward = 0.15,
			FirstDownPush = 0.35,
			NearClear = 0.6,
			IdleTurnSeconds = 0.12,
			IdleTurnMaxLag = 60,
			IdleTurnSpeed = 0.5,
			FocusFov = 45,
			FocusSprintFov = 70,
			FocusSeconds = 0.1,
		}
		for key, value in numbers do
			t.eq((C :: any)[key], value, `Config.Camera.{key}`)
		end
		t.eq(table.concat(C.Radius, ","), "0.45,0.3", "the boom's rays cover the near plane")
		t.eq(C.FirstPersonBody, true)
		t.eq(C.FreelookToggle, false)
	end)

	t.test("camera rules: the rig by stance, posture and guard", function()
		local key = CameraRules.profileKey
		t.eq(key(stance(), "lowered", false), "standing")
		t.eq(key(stance({ sprinting = true }), "lowered", false), "sprinting")
		t.eq(key(stance({ sneaking = true }), "lowered", false), "crouching")
		t.eq(key(stance({ tilt = 0.6 }), "lowered", false), "lying", "crawling or swimming")
		t.eq(key(stance({ tilt = 0.4 }), "lowered", false), "standing", "half way down: not yet")
		t.eq(key(stance({ climbing = true }), "lowered", false), "climbing")
		t.eq(key(stance({ flying = true }), "lowered", false), "flying")
		t.eq(key(stance(), "raised", false), "raised")
		t.eq(key(stance(), "sights", false), "raised", "the sights keep the raised rig")
		t.eq(key(stance({ sneaking = true }), "raised", false), "crouchRaised")
		t.eq(key(stance({ sprinting = true }), "raised", false), "raised", "raised wins over sprinting")
		t.eq(key(stance(), "lowered", true), "raisedHands", "a melee guard")
		t.eq(key(stance({ tilt = 1 }), "raised", false), "lying", "lying wins")
		t.eq(key(stance({ climbing = true }), "raised", true), "climbing")
	end)

	t.test("camera rules: every DayZ blend time, and the default", function()
		local pairs_ = {
			{ "standing", "raised", 0.2 },
			{ "raised", "standing", 0.2 },
			{ "standing", "raisedHands", 0.2 },
			{ "raisedHands", "standing", 0.2 },
			{ "standing", "sprinting", 0.6 },
			{ "sprinting", "standing", 0.3 },
			{ "standing", "crouching", 0.4 },
			{ "crouching", "standing", 0.4 },
			{ "standing", "lying", 0.8 },
			{ "lying", "standing", 0.9 },
			{ "crouching", "crouchRaised", 0.2 },
			{ "crouchRaised", "crouching", 0.2 },
		}
		for _, row in pairs_ do
			t.eq(CameraRules.transition(row[1], row[2]), row[3], `{row[1]} -> {row[2]}`)
		end
		t.eq(CameraRules.transition("sprinting", "lying"), 0.3, "the default")
		t.eq(CameraRules.transition("climbing", "flying"), CameraRules.DEFAULT_TRANSITION)
		t.eq(CameraRules.transition("raised", "raised"), 0, "no change, no blend")
	end)

	t.test("camera rules: SmoothCD is Enforce's (Game Programming Gems 4) formula", function()
		-- The formula written out again, independently.
		local function reference(cur: number, target: number, vel: number, smooth: number, dt: number)
			local omega = 2 / smooth
			local x = omega * dt
			local e = 1 / (1 + x + 0.48 * x ^ 2 + 0.235 * x ^ 3)
			local change = cur - target
			local temp = (vel + omega * change) * dt
			return target + (change + temp) * e, (vel - omega * temp) * e
		end
		local samples = {
			{ 0, 1, 0, 0.3, 1 / 60 },
			{ 2, -1, 0.5, 0.14, 1 / 30 },
			{ 0.25, 0, -3, 0.1, 0.05 },
			{ -4, 4, 10, 0.06, 1 / 240 },
			{ 1, 1, 0, 0.2, 0.5 },
		}
		for i, s in samples do
			local value, vel = CameraRules.smoothCD(s[1], s[2], s[3], s[4], s[5])
			local rv, rvel = reference(s[1], s[2], s[3], s[4], s[5])
			t.near(value, rv, 1e-12, `sample {i}'s value`)
			t.near(vel, rvel, 1e-12, `sample {i}'s velocity`)
		end
		-- (Worked by hand: 0 towards 1 over 0.3 s, a 60 Hz frame from rest.)
		local value, vel = CameraRules.smoothCD(0, 1, 0, 0.3, 1 / 60)
		t.near(value, 0.005592010361, 1e-9)
		t.near(vel, 0.662938659759, 1e-9)
		t.eq(select(1, CameraRules.smoothCD(3, 7, 2, 0, DT)), 7, "no smooth time: there at once")
		t.eq(select(1, CameraRules.smoothCD(3, 7, 2, 0.2, 0)), 3, "no time: no move")
	end)

	t.test("camera rules: the rig eases to a new profile without overshoot, at any frame rate", function()
		for _, dt in { 1 / 240, 1 / 60, 1 / 20, 0.25 } do
			local from, to = CameraRules.profile("standing"), CameraRules.profile("raised")
			local rig = CameraRules.newRig(from, 1)
			local seconds = CameraRules.transition("standing", "raised")
			local last = { distance = rig.distance, shoulder = rig.shoulder, forward = rig.forward }
			local elapsed = 0
			while elapsed < 1 do
				CameraRules.easeRig(rig, to, -1, dt, seconds)
				elapsed += dt
				-- Distance falls to 2.4, the shoulder grows to 1.5, forward to 0.6: monotonic, never past.
				t.ok(rig.distance <= last.distance + 1e-12 and rig.distance >= to.distance - 1e-12, "distance")
				t.ok(rig.shoulder >= last.shoulder - 1e-12 and rig.shoulder <= to.shoulder + 1e-12, "shoulder")
				t.ok(rig.forward >= last.forward - 1e-12 and rig.forward <= to.forward + 1e-12, "forward")
				t.ok(rig.side <= 1 + 1e-12 and rig.side >= -1 - 1e-12, "the side stays within its range")
				last.distance, last.shoulder, last.forward = rig.distance, rig.shoulder, rig.forward
			end
			t.near(rig.distance, to.distance, 1e-3, `there within a second at {dt}`)
			t.near(rig.height, to.height, 1e-3)
			t.near(rig.side, -1, 1e-3, "the left shoulder")
		end
		-- A 0.2 s blend is mostly done in 0.2 s (smooth time 0.06).
		local rig = CameraRules.newRig(CameraRules.profile("standing"), 1)
		for _ = 1, 12 do
			CameraRules.easeRig(rig, CameraRules.profile("raised"), 1, DT, 0.2)
		end
		t.ok(math.abs(rig.distance - 2.4) < 0.05 * 2.4, `0.2 s: {rig.distance}`)
		-- 0 seconds: at once.
		CameraRules.easeRig(rig, CameraRules.profile("lying"), 1, DT, 0)
		t.eq(rig.distance, 3.0)
	end)

	t.test("camera rules: the pivot over the right shoulder is +X at yaw 0; the left mirrors it", function()
		local rig = CameraRules.newRig(CameraRules.profile("standing"), 1)
		local x, y, z = CameraRules.pivot(10, 20, 30, 0, rig)
		t.near(x, 10 + 0.9, 1e-9, "right is +X")
		t.near(y, 20 + 0.25, 1e-9, "up by the height")
		t.near(z, 30, 1e-9)
		rig.side = -1
		local lx, _, lz = CameraRules.pivot(10, 20, 30, 0, rig)
		t.near(lx, 10 - 0.9, 1e-9, "left mirrors it")
		t.near(lz, 30, 1e-9)
		-- Forward is the facing (-Z at yaw 0); turned a quarter left (yaw pi/2: facing -X, right -Z).
		local raised = CameraRules.newRig(CameraRules.profile("raised"), 1)
		local fx, _, fz = CameraRules.pivot(0, 0, 0, 0, raised)
		t.near(fx, 1.5, 1e-9)
		t.near(fz, -0.6, 1e-9, "ahead is -Z")
		local qx, _, qz = CameraRules.pivot(0, 0, 0, math.pi / 2, raised)
		t.near(qx, -0.6, 1e-9, "facing -X")
		t.near(qz, -1.5, 1e-9, "the right shoulder at -Z")
		-- The jump's lag lowers the pivot.
		raised.lag = -0.5
		local _, ly = CameraRules.pivot(0, 0, 0, 0, raised)
		t.near(ly, -0.5, 1e-9)
	end)

	t.test("camera rules: the jump's lag holds 0.15 s, then a quarter of the rise; 0 on the ground", function()
		local lag, vel = CameraRules.jumpLag(0, 0, 1.2, 0.1, DT)
		t.near(lag, -1.2, 1e-12, "the pivot keeps its height at first")
		t.eq(vel, 0)
		local elapsed = 0.15
		for _ = 1, 120 do
			lag, vel = CameraRules.jumpLag(lag, vel, 1.2, elapsed, DT)
			elapsed += DT
		end
		t.near(lag, -0.3, 1e-3, "then follows all but 25 % of the rise")
		t.eq(select(1, CameraRules.jumpLag(-0.3, 1, 1.2, 0, DT)), 0, "on the ground: none")
		t.eq(select(1, CameraRules.jumpLag(0, 0, -2, 0.05, DT)), 0, "falling below the take-off: none")
	end)

	t.test("camera rules: clip and boom pull in at once and ease out at 6/s", function()
		t.eq(CameraRules.clip(math.huge, 2, 0.3), 2, "nothing in the way")
		t.near(CameraRules.clip(1.5, 2, 0.3), 1.2, 1e-12, "the margin short of the block")
		t.eq(CameraRules.clip(0.1, 2, 0.3), 0, "never behind the eyes")
		t.near(CameraRules.clip(2.2, 2, 0.3), 1.9, 1e-12, "a block just past the pivot")
		-- In at once.
		t.eq(CameraRules.boom(4.8, 1.5, DT), 1.5)
		t.eq(CameraRules.boom(4.8, -1, DT), 0, "never negative")
		-- Out: the remaining way's share 1 - e^(-6 dt) a frame.
		local boom = CameraRules.boom(1.5, 4.8, 0.1)
		t.near(boom, 1.5 + 3.3 * (1 - math.exp(-0.6)), 1e-12, "eases out")
		local length, elapsed = 1.5, 0
		while length < 4.8 and elapsed < 5 do
			length = CameraRules.boom(length, 4.8, DT)
			elapsed += DT
		end
		t.eq(length, 4.8, "arrives exactly")
		-- 3.3 studs to within 1e-3: ln(3300) / 6 s.
		t.near(elapsed, math.log(3300) / 6, 2 * DT, "at 6 a second")
	end)

	--[[ First person and targeting ]]

	t.test("camera rules: the first-person eye pushes 0.15 level and 0.5 looking straight down", function()
		local x, y, z = CameraRules.firstPersonEye(1, 2, 3, 0, 0)
		t.near(x, 1, 1e-12)
		t.eq(y, 2, "only along the ground")
		t.near(z, 3 - 0.15, 1e-12, "0.15 ahead, level")
		_, _, z = CameraRules.firstPersonEye(1, 2, 3, 0, -math.pi / 2)
		t.near(z, 3 - 0.5, 1e-12, "0.5 looking straight down")
		_, _, z = CameraRules.firstPersonEye(1, 2, 3, 0, math.pi / 2)
		t.near(z, 3 - 0.15, 1e-12, "looking up pushes no more")
		x, _, z = CameraRules.firstPersonEye(0, 0, 0, math.pi / 2, rad(-30))
		t.near(x, -(0.15 + 0.35 * 0.5), 1e-12, "along the body's facing (-X at a quarter left)")
		t.near(z, 0, 1e-12)
	end)

	t.test("camera rules: the eye-plane skip is 0 in front of the camera, positive behind", function()
		-- First person: the eyes behind the eye point (0.15 back): nothing to skip.
		t.eq(CameraRules.eyePlaneSkip(0, 0, -0.15, 0, 0, -1, 0, 0, 0), 0)
		t.eq(CameraRules.eyePlaneSkip(5, 5, 5, 1, 0, 0, 5, 5, 5), 0, "at the eyes")
		-- Over the shoulder: the eyes 4.8 ahead along the view and 0.9 to the side.
		t.near(CameraRules.eyePlaneSkip(0.9, 0, 4.8, 0, 0, -1, 0, 0, 0), 4.8, 1e-12)
		-- Looking down from behind and above.
		local d = 1 / math.sqrt(2)
		t.near(CameraRules.eyePlaneSkip(0, 2, 2, 0, -d, -d, 0, 0, 0), 4 * d, 1e-12)
	end)

	t.test("camera rules: the ground heading is the control scripts'", function()
		-- Looking down -Z, level.
		local x, z = CameraRules.heading(1, 0, 0, 0, 1)
		t.near(x, 0, 1e-12)
		t.near(z, -1, 1e-12)
		-- Turned a quarter left (yaw pi/2: CFrame.Angles(0, pi/2, 0) has r02 = 1, r22 = 0).
		x, z = CameraRules.heading(0, 0, 1, 0, 0)
		t.near(x, -1, 1e-12)
		t.near(z, 0, 1e-12)
		t.near(CameraRules.yawOf(x, z), math.pi / 2, 1e-12)
		-- Straight down (r12 = 1 after pitching -90 at yaw 0: the up vector's heading).
		x, z = CameraRules.heading(1, 0, 0, 1, 0)
		t.near(x, 0, 1e-12)
		t.near(z, -1, 1e-12)
		t.eq(select(2, CameraRules.heading(0, 0, 0, 0, 0)), -1, "degenerate: -Z")
	end)

	--[[ Freelook ]]

	-- Roblox's camera with MouseLook's hook: the queued turn (x right, y down) and the input added
	-- at its next update, the turn clamped to the room.
	local function camera(): any
		return { yaw = 0, pitch = 0, queuedX = 0, queuedY = 0 }
	end
	local function update(cam: any, inputYaw: number, inputPitch: number)
		cam.yaw += inputYaw - cam.queuedX
		cam.pitch += inputPitch - cam.queuedY
		cam.queuedX, cam.queuedY = 0, 0
	end

	t.test("camera rules: freelook's room is +-160 (+-100 first person) across the +-pi wrap", function()
		local look = CameraRules.newLook()
		local huge = { CameraRules.clampRoom(look, 1, 0, "third") }
		t.eq(huge[1], math.huge, "no room limit when not freelooking")
		t.eq(huge[4], math.huge)
		-- Aim at 170 degrees, then freelook.
		CameraRules.aim(look, rad(170), 0)
		local started, ended = CameraRules.freelook(look, true, true, false, true)
		t.ok(started and not ended, "started")
		-- The camera at -170 (190): 20 degrees left of the aim, across the wrap.
		local left, right, up, down = CameraRules.clampRoom(look, rad(-170), 0, "third")
		t.near(left, rad(140), 1e-9, "left room")
		t.near(right, rad(180), 1e-9, "right room")
		t.near(up, CameraRules.FREELOOK_PITCH, 1e-12)
		t.near(down, CameraRules.FREELOOK_PITCH, 1e-12)
		left, right = CameraRules.clampRoom(look, rad(-170), 0, "first")
		t.near(left, rad(80), 1e-9, "first person: 100 each way")
		t.near(right, rad(120), 1e-9)
		-- At the limit: no more room that way.
		left, right = CameraRules.clampRoom(look, rad(170 + 160), 0, "third")
		t.near(left, 0, 1e-9)
		t.near(right, rad(320), 1e-9)
		left = CameraRules.clampRoom(look, rad(170 + 170), 0, "third")
		t.eq(left, 0, "past it: none, never negative")
		-- Pitch: from an aim 30 degrees down, looking 40 up.
		CameraRules.freelook(look, false, true, false, false)
		look.snapping = false
		CameraRules.aim(look, 0, rad(-30))
		CameraRules.freelook(look, true, true, false, true)
		local _, _, u, d = CameraRules.clampRoom(look, 0, rad(40), "third")
		t.near(u, rad(85 - 70), 1e-9)
		t.near(d, rad(85 + 70), 1e-9)
	end)

	t.test("camera rules: the snap back from 160 ends within 0.7 s, 95 % in a third of one", function()
		local look = CameraRules.newLook()
		local cam = camera()
		CameraRules.aim(look, cam.yaw, cam.pitch)
		CameraRules.freelook(look, true, true, false, true)
		-- Turn 160 left and 20 up while the aim holds.
		update(cam, rad(160), rad(20))
		local aimYaw, aimPitch = CameraRules.aim(look, cam.yaw, cam.pitch)
		t.eq(aimYaw, 0, "the aim held")
		t.eq(aimPitch, 0)
		t.ok(CameraRules.freelook(look, true, true, false, false) == false, "held: nothing new")
		local _, ended = CameraRules.freelook(look, false, true, false, false)
		t.ok(ended and look.snapping, "let go: it comes back")
		local elapsed, at95 = 0, nil
		while look.snapping and elapsed < 2 do
			update(cam, 0, 0)
			CameraRules.aim(look, cam.yaw, cam.pitch)
			cam.queuedX, cam.queuedY = CameraRules.snapStep(look, cam.yaw, cam.pitch, DT)
			elapsed += DT
			if at95 == nil and math.abs(look.yaw) < 0.05 * rad(160) then
				at95 = elapsed
			end
			t.near(look.aimYaw, 0, 1e-9, "no input: the aim stays")
		end
		update(cam, 0, 0)
		t.ok(not look.snapping, "ended")
		t.ok(elapsed < 0.7, `under SNAP_END in {elapsed} s (SmoothCD 0.14 from 160 degrees)`)
		t.ok(at95 ~= nil and at95 < 0.36, `95 % back in {at95} s`)
		t.near(cam.yaw, 0, 1e-12, "the camera is back on the aim exactly")
		t.near(cam.pitch, 0, 1e-12)
		local yaw, pitch = CameraRules.aim(look, cam.yaw, cam.pitch)
		t.near(yaw, 0, 1e-12)
		t.near(pitch, 0, 1e-12)
		t.eq(select(1, CameraRules.snapStep(look, cam.yaw, cam.pitch, DT)), 0, "not snapping: no turn")
	end)

	t.test("camera rules: input during the snap moves the aim", function()
		local look = CameraRules.newLook()
		local cam = camera()
		CameraRules.aim(look, 0, 0)
		CameraRules.freelook(look, true, true, false, true)
		update(cam, rad(-90), 0)
		CameraRules.aim(look, cam.yaw, cam.pitch)
		CameraRules.freelook(look, false, true, false, false)
		local frames = 0
		while look.snapping and frames < 200 do
			-- The mouse turns 0.01 left a frame for the first 10 frames.
			local input = if frames < 10 then 0.01 else 0
			update(cam, input, 0)
			CameraRules.aim(look, cam.yaw, cam.pitch)
			cam.queuedX, cam.queuedY = CameraRules.snapStep(look, cam.yaw, cam.pitch, DT)
			frames += 1
		end
		update(cam, 0, 0)
		local yaw = CameraRules.aim(look, cam.yaw, cam.pitch)
		t.near(yaw, 0.1, 1e-9, "the aim took the input")
		t.near(cam.yaw, 0.1, 1e-9, "and the camera came back to it")
	end)

	t.test("camera rules: freelook holds, toggles, and stops when not allowed", function()
		local look = CameraRules.newLook()
		CameraRules.aim(look, 0, 0)
		-- Hold mode.
		CameraRules.freelook(look, true, true, false, true)
		t.ok(look.active)
		CameraRules.freelook(look, false, true, false, false)
		t.ok(not look.active)
		t.ok(not look.snapping, "no offset: nothing to snap")
		-- Toggle mode: a press on, a press off; holding means nothing.
		CameraRules.freelook(look, true, true, true, true)
		t.ok(look.active, "toggled on")
		CameraRules.freelook(look, false, true, true, false)
		t.ok(look.active, "let go: still on")
		CameraRules.aim(look, 0.5, 0)
		local _, ended = CameraRules.freelook(look, true, true, true, true)
		t.ok(ended and not look.active and look.snapping, "pressed again: off, back it comes")
		-- Not allowed (the sights, a screen...): ends at once, and the toggle is forgotten.
		look = CameraRules.newLook()
		CameraRules.aim(look, 0, 0)
		CameraRules.freelook(look, true, true, true, true)
		CameraRules.aim(look, -0.2, 0)
		CameraRules.freelook(look, true, false, true, false)
		t.ok(not look.active and look.snapping and not look.toggled, "not allowed: stops")
		CameraRules.freelook(look, false, true, true, false)
		t.ok(not look.active, "and stays off")
		t.ok(not select(1, CameraRules.freelook(look, true, false, false, true)), "never starts unallowed")
		-- Starting again during the snap freezes the aim where it is.
		local aimYaw = look.aimYaw
		CameraRules.freelook(look, true, true, false, true)
		t.ok(look.active and not look.snapping)
		t.eq(look.aimYaw, aimYaw)
	end)

	--[[ The body ]]

	t.test("camera rules: the body turns to the aim at once when flagged, else lags at most 60", function()
		local yaw, vel = CameraRules.followYaw(0, 2, 5, DT, true)
		t.eq(yaw, 2, "instant")
		t.eq(vel, 0)
		-- Idle: a sudden 150 degree turn of the aim.
		local body, v = 0, 0
		local aim = rad(150)
		local maxLag = 0
		for _ = 1, 120 do
			body, v = CameraRules.followYaw(body, aim, v, DT, false)
			maxLag = math.max(maxLag, math.abs(CameraRules.wrap(aim - body)))
		end
		t.ok(maxLag <= rad(60) + 1e-9, `lags at most 60 degrees ({math.deg(maxLag)})`)
		t.near(body, aim, 1e-3, "and catches up")
		-- Across the wrap: the short way round.
		body, v = rad(170), 0
		aim = rad(-170)
		local first = select(1, CameraRules.followYaw(body, aim, v, DT, false))
		t.ok(CameraRules.wrap(first - body) > 0, "turns left, through 180")
		for _ = 1, 120 do
			body, v = CameraRules.followYaw(body, aim, v, DT, false)
			t.ok(body > -math.pi - 1e-12 and body <= math.pi + 1e-12, "within (-pi, pi]")
		end
		t.near(CameraRules.wrap(body - aim), 0, 1e-3)
		t.near(CameraRules.wrap(rad(190)), rad(-170), 1e-12)
		t.near(CameraRules.wrap(-math.pi), math.pi, 1e-12)
	end)

	--[[ Focus ]]

	t.test("camera rules: focus gives 45, 70 sprinting, nothing raised, never wider", function()
		t.eq(CameraRules.focusFov(70, false, true, false), 45)
		t.eq(CameraRules.focusFov(70, true, true, false), 70, "sprinting: DayZ's shallow focus")
		t.eq(CameraRules.focusFov(90, true, true, false), 70)
		t.eq(CameraRules.focusFov(90, false, true, true), 90, "raised: the sights' own zoom")
		t.eq(CameraRules.focusFov(90, false, false, false), 90, "not held")
		t.eq(CameraRules.focusFov(40, false, true, false), 40, "never wider than the setting")
		t.eq(CameraRules.focusFov(30, true, true, false), 30)
	end)

	--[[ Require rules ]]

	t.test("camera rules: the camera's modules keep out of the require cycles", function()
		-- The client modules a client file requires through script.Parent... (as WeaponClient's walk).
		local function fileOf(parts: { string }): string?
			local path = "src/client/" .. table.concat(parts, "/")
			if fs.isFile(path .. ".luau") then
				return path .. ".luau"
			elseif fs.isFile(path .. "/init.luau") then
				return path .. "/init.luau"
			end
			return nil
		end
		local function requires(parts: { string }): { { string } }
			local found = {}
			local file = fileOf(parts)
			if file == nil then
				return found
			end
			for chain in string.gmatch(fs.readFile(file), "require%(script(%.[%w%.]+)%)") do
				local at = table.clone(parts)
				for step in string.gmatch(chain, "%.(%w+)") do
					if step == "Parent" then
						table.remove(at)
					else
						table.insert(at, step)
					end
				end
				table.insert(found, at)
			end
			return found
		end
		local function reach(parts: { string }): { [string]: boolean }
			local seen: { [string]: boolean } = {}
			local function walk(at: { string })
				local key = table.concat(at, "/")
				if seen[key] or fileOf(at) == nil then
					return
				end
				seen[key] = true
				for _, nextParts in requires(at) do
					walk(nextParts)
				end
			end
			walk(parts)
			return seen
		end
		local rig = reach({ "Player", "CameraRig" })
		for key in rig do
			t.ok(string.sub(key, 1, 3) ~= "Ui/", `CameraRig reaches {key}`)
			t.ok(string.sub(key, 1, 12) ~= "Interaction/", `CameraRig reaches {key}`)
		end
		t.ok(not rig["Player/MovementController"], "CameraRig reaches MovementController")
		t.ok(not rig["Player/AimCamera"], "CameraRig reaches AimCamera")
		t.ok(rig["Player/CameraRules"], "the walk reaches its rules")
		-- FirstPersonBody: the rig, its rules, the spectators' rules (and Shared's Config).
		local allowed = {
			["Player/CameraRig"] = true,
			["Player/FirstPersonRules"] = true,
			["Player/SpectatorRules"] = true,
		}
		for _, parts in requires({ "Player", "FirstPersonBody" }) do
			local key = table.concat(parts, "/")
			t.ok(allowed[key], `FirstPersonBody requires {key}`)
		end
		local body = reach({ "Player", "FirstPersonBody" })
		for _, banned in { "Player/MovementController", "Player/AimCamera", "Player/HeldItems" } do
			t.ok(not body[banned], `FirstPersonBody reaches {banned}`)
		end
		-- CameraRules is pure: no Roblox service but ReplicatedStorage's Shared.
		local source = fs.readFile("src/client/Player/CameraRules.luau")
		local services = {}
		for name in string.gmatch(source, 'GetService%("(%w+)"%)') do
			table.insert(services, name)
		end
		t.eq(table.concat(services, ","), "ReplicatedStorage", "only Shared")
		t.eq(#requires({ "Player", "CameraRules" }), 0, "no client module")
	end)
end
