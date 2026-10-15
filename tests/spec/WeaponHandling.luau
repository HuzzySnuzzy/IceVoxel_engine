--[[
	Weapon handling (Shared/Weapons/Handling): the cadence both sides keep (slack and credit, and
	no run of shots faster than the rate), spread, recoil (deterministic, recovering), sway and
	holding breath, the condition levels against the survival look's (Ui/Theme), jam chances,
	noise with suppressors, reload times and zoom, how long a weapon action locks the gun
	(`actionLock`, the one rule of server Weapons/WeaponActions and client Interaction/Firearms),
	and what a gun changed in hand by anything else costs (`changeLock`, theirs too).
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

	t.test("handling: a weapon action's lock, from what it did to the gun", function()
		local function gun(name: string, data: { [string]: any }?): Items.Stack
			local stack: Items.Stack = { item = I[name], count = 1 }
			return if data then Items.withData(stack, data) else stack
		end
		local s = Config.Weapons
		local pistol, revolver = spec("Pistol"), spec("Revolver")
		local mag, nine, r357 = I.PistolMagazine, I.Rounds9mm, I.Rounds357
		local function loaded(n: number, extra: { [string]: any }?): Items.Stack
			local data: { [string]: any } = { mag = mag, n = n, ammo = nine, ch = nine }
			for k, v in extra or {} do
				data[k] = v
			end
			return gun("Pistol", data)
		end
		-- Op 1, a detachable feed.
		local kind, ticks, chambered = Handling.actionLock(1, gun("Pistol"), loaded(14))
		t.eq(kind, "reload", "a magazine in")
		t.eq(ticks, pistol.reloadTicks + pistol.chamberTicks, "and a round chambered")
		t.eq(chambered, true)
		kind, ticks, chambered = Handling.actionLock(1, loaded(2), loaded(15))
		t.ok(kind == "reload" and ticks == pistol.reloadTicks and not chambered, "a fuller one, chambered already")
		kind, ticks = Handling.actionLock(1, loaded(2, { magD = 0 }), loaded(2, { magD = 30 }))
		t.ok(kind == "reload" and ticks == pistol.reloadTicks, "as full, in another condition")
		local unchambered = gun("Pistol", { mag = mag, n = 5, ammo = nine })
		kind, ticks, chambered = Handling.actionLock(1, unchambered, loaded(4))
		t.eq(kind, "chamber", "the magazine stayed: only chambered")
		t.eq(ticks, pistol.chamberTicks)
		t.eq(chambered, true)
		t.eq((Handling.actionLock(1, loaded(5), loaded(5))), nil, "nothing better: nothing")
		-- Op 1 on an internal feed and op 2: a round in.
		kind, ticks = Handling.actionLock(1, gun("Revolver"), gun("Revolver", { ch = r357 }))
		t.ok(kind == "round" and ticks == revolver.roundTicks, "R on an internal magazine: a round")
		kind, ticks = Handling.actionLock(
			2,
			gun("Revolver", { ch = r357, n = 2, ammo = r357 }),
			gun("Revolver", { ch = r357, n = 3, ammo = r357 })
		)
		t.ok(kind == "round" and ticks == revolver.roundTicks, "a round by hand")
		local jammedRevolver = gun("Revolver", { ch = r357, jam = true, n = 2, ammo = r357 })
		t.eq((Handling.actionLock(2, jammedRevolver, table.clone(jammedRevolver))), nil, "refused: as it was")
		-- Op 3, op 4, op 5, op 6.
		kind, ticks = Handling.actionLock(3, loaded(3, { jam = true }), loaded(2))
		t.ok(kind == "unjam" and ticks == s.UnjamTicks, "a jam cleared")
		t.eq((Handling.actionLock(3, loaded(2), loaded(2))), nil, "nothing stuck")
		kind, ticks = Handling.actionLock(4, gun("Smg"), gun("Smg", { mode = 2 }))
		t.ok(kind == "mode" and ticks == s.ModeTicks, "the fire mode")
		local lit = loaded(2, { light = I.WeaponFlashlight, lit = true })
		t.eq((Handling.actionLock(5, loaded(2, { light = I.WeaponFlashlight }), lit)), nil, "the light: none")
		t.eq((Handling.actionLock(6, loaded(2), gun("Pistol", { ch = nine }))), nil, "detaching: none")
		-- Nothing in hand, another item, no firearm.
		t.eq((Handling.actionLock(1, nil, loaded(2))), nil)
		t.eq((Handling.actionLock(1, loaded(2), nil)), nil)
		t.eq((Handling.actionLock(1, loaded(2), gun("Smg", { ch = nine }))), nil, "another item")
		t.eq((Handling.actionLock(1, gun("Machete"), gun("Machete"))), nil, "no firearm")
		t.eq(select(2, Handling.actionLock(1, loaded(5), loaded(5))), 0, "no ticks for nothing")
		-- The settings given (the server's) rather than Config's.
		local own = table.clone(s)
		own.UnjamTicks = 7
		t.eq(select(2, Handling.actionLock(3, loaded(3, { jam = true }), loaded(2), own)), 7)
	end)

	t.test("handling: a gun changed in hand by no weapon op comes down and locks as the ops would", function()
		local function gun(name: string, data: { [string]: any }?): Items.Stack
			local stack: Items.Stack = { item = I[name], count = 1 }
			return if data then Items.withData(stack, data) else stack
		end
		local s = Config.Weapons
		local pistol, revolver = spec("Pistol"), spec("Revolver")
		local mag, nine, r357 = I.PistolMagazine, I.Rounds9mm, I.Rounds357
		local function loaded(n: number, extra: { [string]: any }?): Items.Stack
			local data: { [string]: any } = { mag = mag, n = n, ammo = nine, ch = nine }
			for k, v in extra or {} do
				data[k] = v
			end
			return gun("Pistol", data)
		end
		local function change(before: Items.Stack?, after: Items.Stack?): (boolean, string?, number)
			return Handling.changeLock(before, after)
		end
		-- Nothing changed, or no firearm: nothing.
		t.eq((change(nil, nil)), false)
		t.eq((change(loaded(5), loaded(5))), false, "the same gun")
		t.eq((change(gun("Machete"), gun("Machete", nil))), false, "no firearm")
		t.eq((change({ item = I.Stone, count = 3 }, { item = I.Stone, count = 2 })), false, "no firearm")
		-- Another stack in its place, or none: down, no lock beyond the raise.
		local lowers, kind, ticks = change(loaded(5), nil)
		t.ok(lowers and kind == nil and ticks == 0, "thrown or taken away")
		lowers, kind, ticks = change(nil, loaded(5))
		t.ok(lowers and kind == nil and ticks == 0, "put in hand")
		lowers, kind, ticks = change(loaded(5), gun("Smg", { ch = nine }))
		t.ok(lowers and kind == nil and ticks == 0, "another gun")
		lowers, kind, ticks = change(gun("Machete"), loaded(5))
		t.ok(lowers and ticks == 0, "a gun for a knife")
		-- A detachable feed: a magazine in, a round chambered by hand, both.
		local full = gun("Pistol", { mag = mag, n = 15, ammo = nine })
		lowers, kind, ticks = change(gun("Pistol", { mag = mag }), full)
		t.ok(lowers and kind == "reload" and ticks == pistol.reloadTicks, "a magazine clicked in")
		lowers, kind, ticks = change(full, loaded(15))
		t.ok(lowers and kind == "chamber" and ticks == pistol.chamberTicks, "a round chambered by hand")
		lowers, kind, ticks = change(gun("Pistol"), loaded(15))
		t.eq(ticks, pistol.reloadTicks + pistol.chamberTicks, "another gun of the kind, loaded: R's both")
		t.eq(kind, "reload")
		lowers, kind, ticks = change(loaded(2, { magD = 0 }), loaded(2, { magD = 30 }))
		t.ok(kind == "reload" and ticks == pistol.reloadTicks, "as full, in another condition")
		-- An internal feed: a round's ticks each, as R round by round.
		lowers, kind, ticks = change(gun("Revolver"), gun("Revolver", { ch = r357, n = 5, ammo = r357 }))
		t.ok(lowers and kind == "round", "rounds clicked in")
		t.eq(ticks, 6 * revolver.roundTicks, "six rounds' ticks")
		lowers, kind, ticks = change(
			gun("Revolver", { ch = r357, n = 2, ammo = r357 }),
			gun("Revolver", { ch = r357, n = 3, ammo = r357 })
		)
		t.eq(ticks, revolver.roundTicks, "one more")
		-- Taken out, mounted, lit: down, no lock.
		lowers, kind, ticks = change(loaded(5), gun("Pistol", { ch = nine }))
		t.ok(lowers and kind == nil and ticks == 0, "the magazine out")
		lowers, kind, ticks = change(gun("Revolver", { ch = r357, n = 3, ammo = r357 }), gun("Revolver"))
		t.ok(lowers and ticks == 0, "unloaded")
		lowers, kind, ticks = change(loaded(5), loaded(5, { optic = I.RedDotSight }))
		t.ok(lowers and ticks == 0, "a sight mounted")
		lowers, kind, ticks =
			change(loaded(5, { light = I.WeaponFlashlight }), loaded(5, { light = I.WeaponFlashlight, lit = true }))
		t.ok(lowers and ticks == 0, "lit")
		-- A jam gone and the fire mode changed: the ops' locks, added up.
		lowers, kind, ticks = change(loaded(3, { jam = true }), loaded(14))
		t.ok(lowers and kind == "reload", "a jammed gun swapped for a loaded one")
		t.eq(ticks, s.UnjamTicks + pistol.reloadTicks, "clearing the jam and a magazine in")
		lowers, kind, ticks = change(loaded(3, { jam = true }), loaded(3))
		t.ok(kind == "unjam" and ticks == s.UnjamTicks, "only the jam gone")
		lowers, kind, ticks = change(gun("Smg"), gun("Smg", { mode = 2 }))
		t.ok(kind == "mode" and ticks == s.ModeTicks, "the fire mode")
		-- The settings given (the server's) rather than Config's.
		local own = table.clone(s)
		own.UnjamTicks = 7
		t.eq(select(3, Handling.changeLock(loaded(3, { jam = true }), loaded(3), own)), 7)
	end)
end
