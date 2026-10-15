--[[
	Weapon handling (Shared/Weapons/Handling): the cadence both sides keep (slack and credit, and
	no run of shots faster than the rate), spread, recoil (deterministic, recovering), sway and
	holding breath, the condition levels against the survival look's (Ui/Theme), jam chances,
	noise with suppressors, reload times and zoom.
]]

return function(t, shared, require, _server, client)
	local Items = require(shared.Items)
	local Config = require(shared.Config)
	local Weapons = require(shared.Weapons)
	local Handling = require(shared.Weapons.Handling)
	local Theme = require(client.Ui.Theme)

	local I = Items.id
	local TICK = 1 / 20

	local function spec(name: string): Weapons.FirearmSpec
		return Weapons.firearm(I[name]) :: Weapons.FirearmSpec
	end

	t.test("handling: shot times by mode, ready with a tick of slack, after with two of credit", function()
		local pistol, smg = spec("Pistol"), spec("Smg")
		t.near(Handling.shotTicks(pistol, 1), 4, 1e-9, "300 rpm: 4 ticks")
		t.near(Handling.shotTicks(smg, 1), 3, 1e-9, "400 rpm")
		t.near(Handling.shotTicks(smg, 2), 1200 / 700, 1e-9, "700 rpm")
		t.near(Handling.shotTicks(smg, "auto"), 1200 / 700, 1e-9, "by name")
		t.near(Handling.shotTicks(smg, "semi"), 3, 1e-9)
		t.near(Handling.shotTicks(smg, 9), 3, 1e-9, "an unknown mode: the first")
		t.near(Handling.shotTicks(pistol, "auto"), 4, 1e-9, "no such mode: the first")
		t.near(Handling.shotTicks(spec("BoltActionRifle"), 1), 30, 1e-9, "40 rpm: the bolt in it")
		t.eq(Handling.slack(4), 1, "one tick")
		t.near(Handling.slack(1200 / 700), 0.5 * 1200 / 700, 1e-9, "at most half a shot")
		-- ready
		t.ok(Handling.ready(nil, 0, 4), "the first shot")
		t.ok(Handling.ready(10, 10 + 3 * TICK, 4), "a tick early")
		t.ok(not Handling.ready(10, 10 + 2.9 * TICK, 4), "too early")
		t.ok(Handling.ready(10, 10 + 4 * TICK, 4))
		-- after: due when early within the slack or late within two ticks, else now
		t.near(Handling.after(nil, 7, 4), 7, 1e-12, "the first counts from now")
		t.near(Handling.after(10, 10 + 3 * TICK, 4), 10 + 4 * TICK, 1e-12, "early: from when it was due")
		t.near(Handling.after(10, 10 + 5.9 * TICK, 4), 10 + 4 * TICK, 1e-12, "late within the credit")
		t.near(Handling.after(10, 10 + 6.5 * TICK, 4), 10 + 6.5 * TICK, 1e-12, "after a pause: from now")
	end)

	t.test("handling: 100 shots at 700 rpm never come faster than the rate (but for the slack)", function()
		local smg = spec("Smg")
		local ticks = Handling.shotTicks(smg, 2)
		-- A client sending each shot as early as the server takes it, at millisecond steps.
		local last: number? = nil
		local now = 0
		local first: number? = nil
		local accepted = 0
		while accepted < 100 do
			if Handling.ready(last, now, ticks) then
				last = Handling.after(last, now, ticks)
				first = first or now
				accepted += 1
				if accepted == 100 then
					break
				end
			end
			now += 0.001
		end
		local span = now - (first :: number)
		local fastest = 99 * ticks * TICK - Handling.slack(ticks) * TICK
		t.ok(span >= fastest - 1e-6, `100 shots took {span} s, never under {fastest} s`)
		-- And a jittery client (late by up to two ticks now and then) keeps the rate on average.
		last, now, accepted = nil, 0, 0
		local jitter = { 0, 0.07, 0, 0.02, 0.09, 0, 0.01 }
		local start = 0
		while accepted < 100 do
			if Handling.ready(last, now, ticks) then
				last = Handling.after(last, now, ticks)
				if accepted == 0 then
					start = now
				end
				accepted += 1
				now += jitter[accepted % #jitter + 1] * TICK * 10
			end
			now += 0.001
		end
		t.ok(now - start >= fastest - 1e-6, "jitter earns no extra shots")
	end)

	t.test("handling: spread by stance and a working muzzle device", function()
		local s = Config.Weapons
		local pistol = spec("Pistol")
		t.near(Handling.spread(pistol, { sights = true }), 0.8, 1e-12, "in the sights: the gun's")
		t.near(Handling.spread(pistol, {}), 0.8 * s.ShoulderSpread, 1e-12, "over the shoulder")
		t.near(Handling.spread(pistol, { sights = true, moving = true }), 0.8 * s.MovingSpread, 1e-12)
		t.near(Handling.spread(pistol, { sights = true, crouching = true }), 0.8 * s.CrouchSpread, 1e-12)
		t.near(
			Handling.spread(pistol, { moving = true, crouching = true }),
			0.8 * s.ShoulderSpread * s.MovingSpread * s.CrouchSpread,
			1e-12
		)
		t.near(Handling.spread(pistol, { sights = true }, I.Suppressor, 1), 0.8 * 0.9, 1e-12, "a suppressor")
		t.near(Handling.spread(pistol, { sights = true }, I.ImprovisedSuppressor, 1), 0.8, 1e-12, "a bottle")
		t.near(Handling.spread(pistol, { sights = true }, I.Suppressor, 0.2), 0.8, 1e-12, "a Ruined one")
		t.near(Handling.spread(pistol, { sights = true }, I.RedDotSight, 1), 0.8, 1e-12, "no muzzle device")
	end)

	t.test("handling: recoil is deterministic from the shot counter, and partly recovers", function()
		local s = Config.Weapons
		local rifle = spec("AssaultRifle")
		local pitch, yaw = Handling.recoil(rifle, { sights = true }, 12345, 7)
		local pitch2, yaw2 = Handling.recoil(rifle, { sights = true }, 12345, 7)
		t.eq(pitch, pitch2, "the same shot, the same kick")
		t.eq(yaw, yaw2)
		local other = Handling.recoil(rifle, { sights = true }, 12345, 8)
		t.ok(other ~= pitch, "the next shot another")
		local seen = 0
		for counter = 1, 200 do
			local p, y = Handling.recoil(rifle, { sights = true }, 99, counter)
			t.ok(p >= 0.9 * rifle.recoil - 1e-9 and p <= 1.1 * rifle.recoil + 1e-9, "pitch within 10%")
			t.ok(math.abs(y) <= rifle.recoil * rifle.recoilYaw + 1e-9, "yaw within its share")
			if y > 0 then
				seen += 1
			end
		end
		t.ok(seen > 50 and seen < 150, "kicks both ways")
		local crouched = Handling.recoil(rifle, { sights = true, crouching = true }, 12345, 7)
		t.near(crouched, pitch * s.CrouchRecoil, 1e-9, "crouching")
		local shoulder = Handling.recoil(rifle, {}, 12345, 7)
		t.near(shoulder, pitch * s.ShoulderRecoil, 1e-9, "over the shoulder")
		t.near(Handling.recoverable(2), 2 * s.RecoilRecover, 1e-12)
		t.eq(Handling.recoverStep(0), 0)
		t.near(Handling.recoverStep(s.RecoilRecoverSeconds), 1 - math.exp(-3), 1e-9, "95% within the time")
		-- Frame by frame comes to the same.
		local owed = Handling.recoverable(rifle.recoil)
		local back = 0
		for _ = 1, 15 do
			local step = owed * Handling.recoverStep(1 / 60)
			owed -= step
			back += step
		end
		t.near(back, Handling.recoverable(rifle.recoil) * (1 - math.exp(-3)), 1e-6)
	end)

	t.test("handling: sway stays within its amplitude; breath holds, runs out and comes back", function()
		local s = Config.Weapons
		local rifle = spec("HuntingRifle")
		local a = Handling.swayAmplitude(rifle, { sights = true })
		t.near(a, rifle.sway, 1e-12, "standing in the sights")
		t.near(Handling.swayAmplitude(rifle, { sights = true, moving = true }), rifle.sway * s.MovingSway, 1e-12)
		t.near(Handling.swayAmplitude(rifle, { sights = true, crouching = true }), rifle.sway * s.CrouchSway, 1e-12)
		t.near(Handling.swayAmplitude(rifle, { sights = true, hurt = true }), rifle.sway * s.HurtSway, 1e-12)
		t.near(Handling.swayAmplitude(rifle, {}), rifle.sway * s.ShoulderSway, 1e-12)
		t.near(Handling.swayAmplitude(rifle, { sights = true }, 0.15), rifle.sway * 0.15, 1e-12, "holding breath")
		local biggestYaw, biggestPitch = 0, 0
		for step = 0, 2000 do
			local yaw, pitch = Handling.sway(rifle, { sights = true }, step * 0.01)
			biggestYaw = math.max(biggestYaw, math.abs(yaw))
			biggestPitch = math.max(biggestPitch, math.abs(pitch))
		end
		t.ok(biggestYaw <= a + 1e-9 and biggestYaw > 0.9 * a, "yaw swings to the amplitude")
		t.ok(biggestPitch <= 0.6 * a + 1e-9 and biggestPitch > 0.5 * a, "pitch to 0.6 of it")
		-- Breath.
		local breath = Handling.newBreath()
		t.eq(Handling.breathFactor(breath), 1)
		t.eq(Handling.breathStep(breath, false, 1), 1, "not holding")
		t.eq(Handling.breathStep(breath, true, 0.1), s.HoldBreathSway, "held: steady")
		t.eq(breath.phase, "holding")
		Handling.breathStep(breath, true, s.HoldBreathSeconds - 0.2)
		t.eq(breath.phase, "holding", "still")
		t.eq(Handling.breathStep(breath, true, 0.25), s.OutOfBreathSway, "then out of breath")
		t.eq(breath.phase, "out")
		t.eq(Handling.breathStep(breath, true, 1), s.OutOfBreathSway, "no holding while out")
		Handling.breathStep(breath, false, s.OutOfBreathSeconds)
		t.eq(breath.phase, "normal", "back after a while")
		Handling.breathStep(breath, true, 0.1)
		t.eq(Handling.breathStep(breath, false, 0.1), 1, "letting go early: normal at once")
		t.eq(breath.phase, "normal")
	end)

	t.test("handling: condition levels are the survival look's; jam chances add up", function()
		for index, condition in Theme.CONDITIONS do
			if index < #Theme.CONDITIONS then
				t.eq(Handling.level(condition.above + 1e-9), index, `just above {condition.above}`)
				t.eq(Handling.level(condition.above), index + 1, `at {condition.above}`)
			end
		end
		t.eq(Handling.level(1), 1)
		t.eq(Handling.level(0), 5)
		t.ok(Handling.usable(0.21) and not Handling.usable(0.2), "Ruined never fires")
		local J = Config.Weapons.JamChance
		local pistol = spec("Pistol")
		t.eq(Handling.jamChance(pistol, 1, 1), 0, "pristine")
		t.eq(Handling.jamChance(pistol, 0.7, nil), J[2], "worn, no magazine")
		t.near(Handling.jamChance(pistol, 0.7, 0.5), J[2] + J[3], 1e-12, "worn gun, damaged magazine")
		t.near(Handling.jamChance(pistol, 0.3, 0.3), 2 * J[4], 1e-12, "both badly damaged")
		t.eq(Handling.jamChance(pistol, 1, 0.1), 1, "a Ruined magazine jams every shot")
		t.eq(Handling.jamChance(pistol, 0.1, 1), 1, "at most 1")
		t.eq(Handling.jamChance(spec("Revolver"), 0.3, nil), 0, "a revolver never jams")
		t.eq(Handling.jamChance(spec("DoubleBarrelShotgun"), 0.1, nil), 0)
	end)

	t.test("handling: noise with suppressors (Ruined is loud), reload ticks and zoom", function()
		local s = Config.Weapons
		local pistol = spec("Pistol")
		t.eq(Handling.noise(pistol), 48)
		t.eq(Handling.noise(pistol, I.Suppressor, 1), 12, "x0.25")
		t.near(Handling.noise(pistol, I.ImprovisedSuppressor, 0.5), 48 * 0.45, 1e-9, "x0.45")
		t.eq(Handling.noise(pistol, I.Suppressor, 0.2), 48, "a Ruined suppressor muffles nothing")
		t.eq(Handling.noise(pistol, I.RedDotSight, 1), 48, "an optic is no muzzle device")
		t.eq(Handling.noise(spec("SmallBoreRifle"), I.Suppressor, 1), s.SuppressedMinNoise, "at least 8")
		t.eq(Handling.noise(spec("Crossbow")), 6, "a crossbow's own")
		t.eq(Handling.noise(spec("BoltActionRifle")), 96)
		t.ok(Handling.suppressed(I.Suppressor, 1) and Handling.suppressed(I.ImprovisedSuppressor, 0.3))
		t.ok(not Handling.suppressed(I.ImprovisedSuppressor, 0.2), "Ruined: as unsuppressed")
		t.ok(not Handling.suppressed(nil, 1) and not Handling.suppressed(I.RedDotSight, 1))
		t.ok(Handling.muzzleWorks(I.Suppressor, nil), "no wear given: whole")
		t.eq(Handling.reloadTicks(pistol, false), 40)
		t.eq(Handling.reloadTicks(pistol, true), 50, "and chambering")
		t.eq(Handling.reloadTicks(spec("AssaultRifle"), true), 62)
		t.eq(Handling.zoom(pistol, nil), s.IronSightsZoom, "iron sights")
		t.eq(Handling.zoom(pistol, I.RedDotSight), 1.4)
		t.eq(Handling.zoom(spec("AssaultRifle"), I.RifleScope), 4)
		t.eq(Handling.zoom(spec("HuntingRifle"), nil), 4, "its own scope")
		t.eq(Handling.zoom(spec("HuntingRifle"), I.RedDotSight), 4, "the built-in scope wins")
		t.eq(Handling.zoom(pistol, I.Suppressor), s.IronSightsZoom, "no optic")
	end)
end
