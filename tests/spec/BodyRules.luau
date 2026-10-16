--[[
	The body's motion in the manner of DayZ, through its pure rules (Player/BodyRules): the way the
	feet move from the body's facing; the legs' twist (none ahead, 45 degrees on a pure strafe,
	folded walking backwards, none standing) and the hysteresis about a pure strafe; the idle-turn
	shuffle's threshold and cap; the waist's idle lead and freelook share (the neck's 70, then the
	waist's 30: DayZ's 100 in first person), and their clamps; easing; the numbers; and that the
	rules are pure and Player/BodyTwist keeps to its joints (the hips and the waist, never a
	Transform) at Camera + 6, out of the animator's require cycle.
]]

local fs = require("@lune/fs")

return function(t, shared, require, _server, client)
	local Config = require(shared.Config)
	local BodyRules = require(client.Player.BodyRules)

	local rad = math.rad
	local EPS = 1e-9
	local WALK = 1.5 -- blocks a second: walking

	-- The feet's move for a heading `angle` from a body facing `yaw` (the inverse of moveAngle).
	local function step(angle: number, yaw: number): (number, number)
		local heading = yaw + angle
		return -math.sin(heading), -math.cos(heading)
	end

	t.test("body rules: the numbers (45 degrees of legs, 1.2 rad/s shuffles, 70 + 30 of freelook)", function()
		t.near(BodyRules.LEG_YAW, rad(45), EPS)
		t.eq(BodyRules.MOVING, Config.Camera.IdleTurnSpeed, "standing below the body's idle-turn speed")
		t.eq(BodyRules.MOVING, 0.5)
		t.eq(BodyRules.SHUFFLE_RATE, 1.2)
		t.eq(BodyRules.SHUFFLE_SHARE, 0.25)
		t.eq(BodyRules.SHUFFLE_MAX, 0.6)
		t.near(BodyRules.LEAD, rad(45), EPS)
		t.near(BodyRules.NECK_YAW, rad(70), EPS)
		t.near(BodyRules.WAIST_YAW, rad(30), EPS)
		t.near(
			math.deg(BodyRules.NECK_YAW + BodyRules.WAIST_YAW),
			Config.Camera.FreelookYawFirst,
			1e-9,
			"neck and waist make first person's freelook"
		)
		t.eq(BodyRules.PELVIS, 0, "the hips turn the legs alone")
	end)

	t.test("body rules: the way the feet move from the body's facing", function()
		local moveAngle = BodyRules.moveAngle
		-- A body at yaw 0 looks down -Z; positive angles are to its left (-X).
		t.near(moveAngle(0, -1, 0), 0, EPS, "ahead")
		t.near(moveAngle(-1, 0, 0), rad(90), EPS, "to the left")
		t.near(moveAngle(1, 0, 0), rad(-90), EPS, "to the right")
		t.near(math.abs(moveAngle(0, 1, 0)), math.pi, EPS, "behind")
		t.eq(moveAngle(0, 0, 1.3), 0, "standing still")
		-- Turned: the angle is the body's own, whatever its yaw (across the wrap too).
		for _, yaw in { -3.1, -2, -0.5, 0, 0.7, 2.5, 3.14159 } do
			for _, angle in { -2.6, -1.57, -0.3, 0, 0.4, 1.57, 2.9 } do
				local dx, dz = step(angle, yaw)
				t.near(moveAngle(dx * 0.07, dz * 0.07, yaw), angle, 1e-9, `angle {angle} at yaw {yaw}`)
			end
		end
		local fx, fz = step(rad(170), rad(170))
		local wrapped = moveAngle(fx, fz, rad(170))
		t.near(wrapped, rad(170), 1e-9)
		t.ok(wrapped <= math.pi and wrapped > -math.pi, "within (-pi, pi]")
	end)

	t.test("body rules: the legs twist to a strafe, 45 at most, none ahead", function()
		local legYaw = BodyRules.legYaw
		local yaw, back = legYaw(0, WALK)
		t.eq(yaw, 0, "ahead: no twist")
		t.eq(back, false)
		yaw, back = legYaw(rad(90), WALK)
		t.near(yaw, rad(45), EPS, "a pure strafe left: 45 left")
		t.eq(back, false, "a pure strafe walks forwards")
		yaw = legYaw(rad(-90), WALK)
		t.near(yaw, rad(-45), EPS, "and right")
		yaw = legYaw(rad(30), WALK)
		t.near(yaw, rad(30), EPS, "a diagonal under 45 is followed")
		yaw = legYaw(rad(-60), WALK)
		t.near(yaw, rad(-45), EPS, "beyond 45 held at 45")
		t.eq(BodyRules.walkSign(0), 1)
		t.eq(BodyRules.walkSign(rad(90)), 1)
		t.eq(BodyRules.walkSign(rad(-90)), 1)
		t.eq(BodyRules.walkSign(rad(91)), -1)
		t.eq(BodyRules.walkSign(math.pi), -1)
		t.eq(BodyRules.walkSign(rad(-120)), -1)
		t.eq(BodyRules.walkSign(rad(270)), 1, "wrapped: 270 is -90")
	end)

	t.test("body rules: backwards reverses the walk, diagonals folded", function()
		local legYaw = BodyRules.legYaw
		local yaw, back = legYaw(math.pi, WALK)
		t.near(yaw, 0, EPS, "a straight backpedal: the legs face ahead")
		t.eq(back, true)
		yaw, back = legYaw(-math.pi, WALK)
		t.near(yaw, 0, EPS)
		t.eq(back, true)
		-- Back and to the left: the legs face front-right, walking backwards.
		yaw, back = legYaw(rad(135), WALK)
		t.near(yaw, rad(-45), EPS, "back-left: legs 45 right")
		t.eq(back, true)
		yaw, back = legYaw(rad(-135), WALK)
		t.near(yaw, rad(45), EPS, "back-right: legs 45 left")
		t.eq(back, true)
		yaw = legYaw(rad(160), WALK)
		t.near(yaw, rad(-20), EPS, "folded within 45")
		yaw = legYaw(rad(100), WALK)
		t.near(yaw, rad(-45), EPS, "just behind a strafe: folded and held")
		-- Folding is the twist for a known way of walking.
		t.near(BodyRules.fold(rad(135), true), rad(-45), EPS)
		t.near(BodyRules.fold(rad(135), false), rad(45), EPS, "walked forwards: held at 45")
		t.near(BodyRules.fold(rad(10), true), rad(-45), EPS)
		t.near(BodyRules.fold(math.pi, true), 0, EPS)
		-- Every angle: within 45, and the feet's way is the legs' facing, or its opposite backwards.
		for i = -180, 180, 5 do
			local angle = rad(i)
			local legs, backwards = legYaw(angle, WALK)
			t.ok(math.abs(legs) <= BodyRules.LEG_YAW + EPS, `within 45 at {i}`)
			local facing = if backwards then BodyRules.wrap(angle - math.pi) else angle
			t.ok(math.abs(BodyRules.wrap(facing - legs)) <= rad(45) + EPS, `the legs lean the move's way at {i}`)
		end
	end)

	t.test("body rules: standing (under 0.5 blocks/s) gives no twist", function()
		for _, angle in { 0, rad(45), rad(90), rad(135), math.pi, rad(-100) } do
			local yaw, back = BodyRules.legYaw(angle, 0.49)
			t.eq(yaw, 0, "too slow")
			t.eq(back, false)
			yaw, back = BodyRules.legs(angle, 0.2, true)
			t.eq(yaw, 0, "too slow (with hysteresis)")
			t.eq(back, false, "standing ends the backpedal")
		end
		local yaw = BodyRules.legYaw(rad(90), 0.5)
		t.near(yaw, rad(45), EPS, "0.5 itself is moving")
	end)

	t.test("body rules: the hysteresis about a pure strafe", function()
		local legs = BodyRules.legs
		local band = BodyRules.BACK_BAND
		t.near(band, rad(20), EPS)
		-- Walking forwards it stays forwards up to 90 + the band...
		local yaw, back = legs(rad(105), WALK, false)
		t.eq(back, false, "forwards just behind the strafe")
		t.near(yaw, rad(45), EPS, "the legs keep the strafe's side")
		yaw, back = legs(rad(111), WALK, false)
		t.eq(back, true, "past the band: backwards")
		t.near(yaw, rad(-45), EPS)
		-- ...and backwards it stays backwards down to 90 - the band.
		yaw, back = legs(rad(75), WALK, true)
		t.eq(back, true, "backwards just ahead of the strafe")
		t.near(yaw, rad(-45), EPS)
		yaw, back = legs(rad(69), WALK, true)
		t.eq(back, false, "past the band: forwards")
		t.near(yaw, rad(45), EPS)
		-- Right side alike.
		t.eq(select(2, legs(rad(-105), WALK, false)), false)
		t.eq(select(2, legs(rad(-75), WALK, true)), true)
		-- A strafe wavering about 90 never flips (starting either way).
		for _, start in { false, true } do
			local backwards = start
			for i = 0, 200 do
				local angle = rad(90 + 15 * math.sin(i * 0.37))
				local _, now = legs(angle, WALK, backwards)
				t.eq(now, start, `wavering at {math.deg(angle)}`)
				backwards = now
			end
		end
		-- Straight ahead and straight back are unambiguous.
		t.eq(select(2, legs(0, WALK, true)), false)
		t.eq(select(2, legs(math.pi, WALK, false)), true)
	end)

	t.test("body rules: the idle-turn shuffle's threshold and cap", function()
		local shuffle = BodyRules.shuffle
		t.eq(shuffle(1.2, 0, true), 0, "at the threshold: none")
		t.near(shuffle(1.21, 0, true), 0.25 * 1.21, EPS, "just over: a quarter of the rate")
		t.near(shuffle(-2, 0, true), 0.5, EPS, "either way")
		t.near(shuffle(2.4, 0, true), 0.6, EPS, "the cap reached")
		t.eq(shuffle(10, 0, true), 0.6, "capped")
		t.eq(shuffle(0.5, 0, true), 0, "a slow turn")
		t.eq(shuffle(3, 0, false), 0, "not in the air")
		t.eq(shuffle(3, 0.5, true), 0, "not while moving (the walk plays)")
		t.near(shuffle(3, 0.49, true), 0.6, EPS, "creeping still shuffles")
		for rate = 1.3, 4, 0.1 do
			local s = shuffle(rate, 0, true)
			t.ok(s >= 0.3 and s <= 0.6, `between 0.3 and 0.6 at {rate}`)
		end
	end)

	t.test("body rules: the waist leads an idle turn and takes freelook beyond the neck", function()
		local waist = BodyRules.waist
		t.eq(waist(0, 0, 0), 0)
		t.near(waist(rad(30), 0, 0), rad(30), EPS, "the lead")
		t.near(waist(rad(-30), 0, 0), rad(-30), EPS)
		t.near(waist(rad(60), 0, 0), rad(45), EPS, "the lead within 45")
		t.near(waist(rad(-60), 0, 0), rad(-45), EPS)
		t.near(waist(rad(350), 0, 0), rad(-10), EPS, "the lead wrapped")
		-- Freelook: the neck turns 70 first, the waist the next 30.
		t.eq(waist(0, 0, rad(50)), 0, "within the neck's 70")
		t.near(waist(0, 0, rad(80)), rad(10), EPS)
		t.near(waist(0, 0, rad(-90)), rad(-20), EPS)
		t.near(waist(0, 0, rad(160)), rad(30), EPS, "third person's 160: the waist's 30 at most")
		t.near(waist(0, 0, rad(-160)), rad(-30), EPS)
		t.near(waist(rad(60), 0, rad(160)), rad(75), EPS, "both, each within its own")
		t.near(BodyRules.neck(rad(50)), rad(50), EPS)
		t.near(BodyRules.neck(rad(100)), rad(70), EPS, "the head's 70")
		t.near(BodyRules.neck(rad(-160)), rad(-70), EPS)
		t.near(BodyRules.neck(rad(100)) + waist(0, 0, rad(100)), rad(100), EPS, "neck and waist make 100")
		-- The legs' twist stays at the hips: the pelvis turns none of it (PELVIS 0).
		t.eq(waist(0, rad(45), 0), 0)
		t.near(waist(rad(20), rad(-45), 0), rad(20), EPS)
	end)

	t.test("body rules: easing is exponential and frame-rate independent", function()
		local ease = BodyRules.ease
		t.eq(ease(1, 0, 0, 1 / 60), 0, "no time constant: at once")
		t.near(ease(1, 0, 0.1, 0.1), math.exp(-1), 1e-12, "one time constant: 1/e left")
		t.eq(ease(0.3, 0.3, 0.1, 1 / 60), 0.3, "at the target stays")
		t.eq(ease(0.5, 0, 0.1, 0), 0.5, "no time: no change")
		-- 60 frames of 1/60 s or 10 of 1/10 s end at the same place.
		local a, b = 1, 1
		for _ = 1, 60 do
			a = ease(a, 0, 0.12, 1 / 60)
		end
		for _ = 1, 10 do
			b = ease(b, 0, 0.12, 1 / 10)
		end
		t.near(a, b, 1e-12)
		-- Never past the target.
		local x = -2
		for _ = 1, 100 do
			local before = x
			x = ease(x, 1, 0.05, 0.03)
			t.ok(x >= before and x <= 1, "towards it, never past")
		end
	end)

	--[[ The modules' rules ]]

	t.test("body rules: pure, and BodyTwist keeps to its joints at Camera + 6", function()
		local rules = fs.readFile("src/client/Player/BodyRules.luau")
		local services = {}
		for name in string.gmatch(rules, 'GetService%("(%w+)"%)') do
			table.insert(services, name)
		end
		t.eq(table.concat(services, ","), "ReplicatedStorage", "only Shared")
		t.ok(string.find(rules, "require%(script") == nil, "no client module")
		local twist = fs.readFile("src/client/Player/BodyTwist.luau")
		t.ok(string.find(twist, "Enum.RenderPriority.Camera.Value + 6", 1, true) ~= nil, "Camera + 6")
		t.ok(string.find(twist, "%.Transform%s*=") == nil, "never Transform")
		-- Only the hips' and the waist's C0 (MovementController owns the root, the weapons' poses and
		-- the first-person body the shoulders and the neck).
		for _, joint in { '"LeftHip"', '"RightHip"', '"Waist"' } do
			t.ok(string.find(twist, joint, 1, true) ~= nil, `turns {joint}`)
		end
		for _, other in { '"Root"', '"Neck"', "Shoulder", "Elbow", "Wrist", '"LeftKnee"', '"RightKnee"' } do
			t.ok(string.find(twist, other, 1, true) == nil, `leaves {other}`)
		end
		-- The animator asks the twist; the twist never reaches the animator (a cycle). (The client
		-- modules a file requires through script.Parent..., as CameraRules' walk.)
		local function fileOf(parts: { string }): string?
			local path = "src/client/" .. table.concat(parts, "/")
			if fs.isFile(path .. ".luau") then
				return path .. ".luau"
			elseif fs.isFile(path .. "/init.luau") then
				return path .. "/init.luau"
			end
			return nil
		end
		local reach: { [string]: boolean } = {}
		local function walk(at: { string })
			local key = table.concat(at, "/")
			local file = fileOf(at)
			if reach[key] or file == nil then
				return
			end
			reach[key] = true
			for chain in string.gmatch(fs.readFile(file), "require%(script(%.[%w%.]+)%)") do
				local nextParts = table.clone(at)
				for part in string.gmatch(chain, "%.(%w+)") do
					if part == "Parent" then
						table.remove(nextParts)
					else
						table.insert(nextParts, part)
					end
				end
				walk(nextParts)
			end
		end
		walk({ "Player", "BodyTwist" })
		t.ok(not reach["Player/CharacterAnimator"], "BodyTwist reaches CharacterAnimator")
		t.ok(reach["Player/BodyRules"], "the walk reaches the rules")
		t.ok(reach["Player/MovementController"], "the walk follows the requires")
		local animator = fs.readFile("src/client/Player/CharacterAnimator.luau")
		t.ok(string.find(animator, "require(script.Parent.BodyTwist)", 1, true) ~= nil, "the animator asks the twist")
	end)
end
