--[[
	The client's firearms in the manner of DayZ, through their pure rules: Player/AimRules (the
	raised / sights state machine, the trigger and its cadence, timed actions and their locks,
	internal magazines' round-by-round loading, speed, zoom and field of view, the crosshair and
	the dot, recoil kicks and their recovery, the model's kick, the sway's growing in, the first-
	person hip pose aimed at the screen's centre, the third-person arms and gun, the aim's ray
	tests) and Rendering/ShotRules (near, far and suppressed fire sounds, flashes, tracer glow,
	impacts by hit, pumps' and bolts' racks, own shots against others', look keys); every gun's
	look block against its model; and the require-cycle rule (nothing reachable from
	Interaction/Firearms requires Interaction/BlockInteraction, which requires it).
]]

local fs = require("@lune/fs")

return function(t, shared, require, _server, client)
	local Config = require(shared.Config)
	local Handling = require(shared.Weapons.Handling)
	local Items = require(shared.Items)
	local WeaponState = require(shared.Weapons.WeaponState)
	local WeaponSync = require(shared.Net.WeaponSync)
	local Weapons = require(shared.Weapons)
	local AimRules = require(client.Player.AimRules)
	local ShotRules = require(client.Rendering.ShotRules)

	local I = Items.id
	local TICK = 1 / 20
	local W = Config.Weapons

	local function spec(name: string): Weapons.FirearmSpec
		return Weapons.firearm(I[name]) :: Weapons.FirearmSpec
	end

	local function stack(name: string, data: { [string]: any }?): Items.Stack
		local s: Items.Stack = { item = I[name], count = 1 }
		if data then
			return Items.withData(s, data)
		end
		return s
	end

	local function input(held: boolean, raise: boolean, blocked: boolean?, firstPerson: boolean?): AimRules.Input
		return { held = held, raise = raise, blocked = blocked == true, firstPerson = firstPerson == true }
	end

	-- Seconds until a raised gun may fire (RaiseTicks and the margin).
	local SETTLE = (W.RaiseTicks + AimRules.RAISE_MARGIN_TICKS) * TICK

	--[[ The posture ]]

	t.test("weapon client: raising, the sights, lowering and what the server hears", function()
		local aim = AimRules.new()
		t.eq(aim.posture, "lowered", "lowered at first")
		t.eq(AimRules.step(aim, input(true, false), 0), nil, "nothing held up: nothing to say")
		t.eq(AimRules.step(aim, input(true, true), 1), "raise", "the raise control: raise")
		t.eq(aim.posture, "raised", "over the shoulder in third person")
		t.eq(aim.raisedAt, 1, "from now")
		t.eq(AimRules.step(aim, input(true, true), 1.5), nil, "held: said once")
		t.eq(aim.raisedAt, 1, "raised at the first frame")
		t.ok(AimRules.toggleSights(aim), "V while raised")
		AimRules.step(aim, input(true, true), 1.6)
		t.eq(aim.posture, "sights", "V: down the sights from third person")
		t.ok(AimRules.toggleSights(aim), "V again")
		AimRules.step(aim, input(true, true), 1.7)
		t.eq(aim.posture, "raised", "and back over the shoulder")
		AimRules.step(aim, input(true, true, false, true), 1.8)
		t.eq(aim.posture, "sights", "first person: the sights")
		AimRules.toggleSights(aim)
		t.eq(AimRules.step(aim, input(true, false), 2), "lower", "let go: lower")
		t.eq(aim.posture, "lowered")
		t.eq(aim.raisedAt, nil)
		t.ok(not aim.sights, "lowering forgets V")
		t.ok(not AimRules.toggleSights(aim), "V does nothing lowered")
		-- Anything that blocks lowers it, even with the control held; so does another item.
		AimRules.step(aim, input(true, true), 3)
		t.eq(AimRules.step(aim, input(true, true, true), 3.1), "lower", "a screen, death...: lowered")
		t.eq(AimRules.step(aim, input(true, true), 3.2), "raise", "up again once nothing blocks")
		t.eq(AimRules.step(aim, input(false, true), 3.3), "lower", "no firearm in hand: lowered")
		t.eq(AimRules.step(aim, input(false, true), 3.4), nil)
	end)

	t.test("weapon client: a raised gun settles RaiseTicks (and a tick of margin) before it fires", function()
		local aim = AimRules.new()
		t.ok(not AimRules.settled(aim, 0), "lowered never")
		t.eq(AimRules.raiseProgress(aim, 0), 0)
		AimRules.step(aim, input(true, true), 10)
		t.ok(not AimRules.settled(aim, 10 + SETTLE - 0.01), "not yet")
		t.ok(AimRules.settled(aim, 10 + SETTLE), "settled")
		t.ok(SETTLE >= W.RaiseTicks * TICK, "never before the server's RaiseTicks")
		t.near(AimRules.raiseProgress(aim, 10 + SETTLE / 2), 0.5, 1e-9, "the raise bar")
		t.eq(AimRules.raiseProgress(aim, 99), 1)
		t.eq(AimRules.swayBlend(aim, 10), 0, "the sway grows in from nothing")
		t.eq(AimRules.swayBlend(aim, 10 + AimRules.SWAY_IN), 1, "to all of it")
	end)

	--[[ The trigger ]]

	-- A gun raised at 0 and settled.
	local function raised(): AimRules.Aim
		local aim = AimRules.new()
		AimRules.step(aim, input(true, true), 0)
		return aim
	end

	t.test("weapon client: a semi-automatic fires once a press, a press too early waits its turn", function()
		local aim = raised()
		local ticks = Handling.shotTicks(spec("Pistol"), 1)
		local now = SETTLE / 2
		t.eq(AimRules.pull(aim, now, true, false, ticks, true, nil), nil, "not settled yet")
		now = SETTLE
		t.eq(AimRules.pull(aim, now, true, false, ticks, true, nil), "fire", "settled: the press fires")
		t.eq(AimRules.pull(aim, now + 1, true, false, ticks, true, nil), nil, "held: once a press")
		t.eq(AimRules.pull(aim, now + 1.01, false, false, ticks, true, nil), nil, "let go")
		local early = now + 1.02
		-- (The shot counted from `now`; a new press one second on is long past its time.)
		t.eq(AimRules.pull(aim, early, true, false, ticks, true, nil), "fire", "pressed again")
		AimRules.pull(aim, early + 0.01, false, false, ticks, true, nil)
		t.eq(AimRules.pull(aim, early + 0.02, true, false, ticks, true, nil), nil, "too soon: waits")
		t.eq(AimRules.pull(aim, early + ticks * TICK, true, false, ticks, true, nil), "fire", "its turn")
	end)

	t.test("weapon client: automatic fire keeps its rate over uneven frames", function()
		local smg = spec("Smg")
		local ticks = Handling.shotTicks(smg, 2)
		for _, fps in { 60, 37, 144 } do
			local aim = raised()
			local frame = 1 / fps
			local now = SETTLE
			local shots: { number } = {}
			while now < SETTLE + 3 do
				if AimRules.pull(aim, now, true, true, ticks, true, nil) == "fire" then
					table.insert(shots, now)
				end
				now += frame
			end
			local expected = 3 / (ticks * TICK)
			t.ok(math.abs(#shots - expected) <= 1.5, `{fps} fps: {#shots} shots in 3 s at 700 rpm ({expected})`)
			-- Never closer than the server takes (Handling.ready's slack).
			for i = 2, #shots do
				local gap = shots[i] - shots[i - 1]
				t.ok(gap >= (ticks - Handling.slack(ticks)) * TICK - 1e-9, `{fps} fps: shot {i} {gap} s after the last`)
			end
		end
	end)

	t.test("weapon client: dry and jam clicks once a press; busy, lowered and stopped guns don't fire", function()
		local aim = raised()
		local now = SETTLE + 1
		t.eq(AimRules.pull(aim, now, true, false, 4, false, WeaponState.EMPTY), "dry", "empty: the dry click")
		t.eq(AimRules.pull(aim, now + 0.5, true, false, 4, false, WeaponState.EMPTY), nil, "once a press")
		AimRules.pull(aim, now + 0.6, false, false, 4, false, nil)
		t.eq(AimRules.pull(aim, now + 0.7, true, true, 4, false, WeaponState.JAMMED), "jam", "jammed: the jam click")
		AimRules.pull(aim, now + 0.8, false, false, 4, false, nil)
		t.eq(AimRules.pull(aim, now + 0.9, true, true, 4, false, WeaponState.RUINED), "jam", "Ruined: the jam click")
		AimRules.pull(aim, now + 1, false, false, 4, false, nil)
		-- An automatic stopped (refused, jammed) waits for the trigger to be let go.
		t.eq(AimRules.pull(aim, now + 2, true, true, 2, true, nil), "fire")
		AimRules.stop(aim)
		t.eq(AimRules.pull(aim, now + 3, true, true, 2, true, nil), nil, "stopped")
		AimRules.pull(aim, now + 3.1, false, true, 2, true, nil)
		t.eq(AimRules.pull(aim, now + 3.2, true, true, 2, true, nil), "fire", "pressed again")
		-- A timed action locks the trigger.
		AimRules.startBusy(aim, "reload", now + 4, 40)
		t.ok(AimRules.busy(aim, now + 4.5), "busy")
		t.eq(AimRules.pull(aim, now + 4.5, true, true, 2, true, nil), nil, "no shot while reloading")
		t.eq(AimRules.pull(aim, now + 6.01, true, true, 2, true, nil), "fire", "after it")
		-- Lowered never fires.
		AimRules.step(aim, input(true, false), now + 7)
		t.eq(AimRules.pull(aim, now + 8, true, true, 2, true, nil), nil, "lowered")
	end)

	--[[ Timed actions ]]

	t.test("weapon client: locks as the server times them, progress and the closing once", function()
		local ar, pump, bolt = spec("AssaultRifle"), spec("PumpShotgun"), spec("BoltActionRifle")
		t.eq(AimRules.lockTicks(ar, 1, false), 50, "a magazine swap")
		t.eq(AimRules.lockTicks(ar, 1, true), 62, "and chambering")
		t.eq(AimRules.lockTicks(pump, 1, false), 14, "an internal magazine's reload is a round")
		t.eq(AimRules.lockTicks(bolt, 2, false), 16, "a round by hand")
		t.eq(AimRules.lockTicks(ar, 3, false), W.UnjamTicks, "clearing a jam")
		t.eq(AimRules.lockTicks(ar, 4, false), W.ModeTicks, "the fire mode")
		t.eq(AimRules.lockTicks(ar, 5, false), 0, "the light takes no time")
		local aim = AimRules.new()
		t.eq(AimRules.progress(aim, 0), nil, "nothing running")
		AimRules.startBusy(aim, "reload", 10, 50)
		local progress, kind = AimRules.progress(aim, 11.25)
		t.near(progress :: number, 0.5, 1e-9, "half way")
		t.eq(kind, "reload")
		local p2, k2, finished = AimRules.progress(aim, 12.5)
		t.eq(p2, nil, "ended")
		t.eq(k2, nil)
		t.eq(finished, "reload", "its end said once")
		local _, _, again = AimRules.progress(aim, 12.6)
		t.eq(again, nil, "only once")
		AimRules.startBusy(aim, "mode", 20, 0)
		t.ok(not AimRules.busy(aim, 20), "no ticks: nothing starts")
	end)

	t.test("weapon client: what a weapon op did, and when an internal magazine wants a round", function()
		local mag, rounds = I.RifleMagazine, I.Rounds556
		local empty = stack("AssaultRifle")
		local loaded = stack("AssaultRifle", { mag = mag, n = 30, ammo = rounds })
		local changed, chambered = AimRules.outcome(empty, loaded)
		t.ok(changed and not chambered, "a magazine in: changed, nothing chambered")
		changed, chambered =
			AimRules.outcome(loaded, stack("AssaultRifle", { mag = mag, n = 29, ammo = rounds, ch = rounds }))
		t.ok(changed and chambered, "chambered")
		changed = AimRules.outcome(loaded, stack("AssaultRifle", { mag = mag, n = 30, ammo = rounds }))
		t.ok(not changed, "the same")
		local shells = I.Buckshot
		t.ok(AimRules.wantsRound(stack("PumpShotgun")), "an empty pump wants a shell")
		t.ok(AimRules.wantsRound(stack("PumpShotgun", { n = 4, ammo = shells, ch = shells })), "5 of 6")
		t.ok(not AimRules.wantsRound(stack("PumpShotgun", { n = 5, ammo = shells, ch = shells })), "full")
		t.ok(not AimRules.wantsRound(stack("PumpShotgun", { n = 2, ammo = shells, ch = shells, jam = true })), "jammed")
		t.ok(not AimRules.wantsRound(stack("AssaultRifle")), "a detachable feed never")
		t.ok(AimRules.wantsRound(stack("Crossbow")), "a crossbow without its bolt")
		t.ok(not AimRules.wantsRound(stack("Crossbow", { ch = I.CrossbowBolt })), "with it")
		t.ok(not AimRules.wantsRound(nil), "nothing")
	end)

	--[[ Speed and view ]]

	t.test("weapon client: speed, zoom and field of view, the crosshair and the dot", function()
		local factor, noSprint = AimRules.speed("lowered")
		t.ok(factor == 1 and not noSprint, "lowered: as ever")
		factor, noSprint = AimRules.speed("raised")
		t.ok(factor == W.RaisedSpeed and noSprint, "raised")
		factor, noSprint = AimRules.speed("sights")
		t.ok(factor == W.SightsSpeed and noSprint, "in the sights")
		factor, noSprint = AimRules.speed("lowered", true)
		t.ok(factor == W.GuardSpeed and noSprint, "guarding")
		local pistol, hunting, ar = spec("Pistol"), spec("HuntingRifle"), spec("AssaultRifle")
		t.eq(AimRules.zoom("lowered", pistol, nil), 1)
		t.eq(AimRules.zoom("raised", pistol, nil), 1, "over the shoulder: no zoom")
		t.eq(AimRules.zoom("sights", pistol, nil), W.IronSightsZoom, "iron sights")
		t.eq(AimRules.zoom("sights", pistol, I.RedDotSight), 1.4, "a red dot")
		t.eq(AimRules.zoom("sights", ar, I.RifleScope), 4, "a rifle scope")
		t.eq(AimRules.zoom("sights", hunting, nil), 4, "the built-in scope")
		t.eq(AimRules.zoom("sights", nil, nil), 1, "no gun")
		t.ok(AimRules.scoped(4) and not AimRules.scoped(1.4) and not AimRules.scoped(W.IronSightsZoom), "scopes")
		t.near(AimRules.fov(70, W.IronSightsZoom), 70 / 1.15, 1e-9, "70 in iron sights")
		t.near(AimRules.fov(70, 4), 17.5, 1e-9, "70 through a scope")
		t.near(AimRules.fov(110, 1), 110, 1e-9)
		t.eq(AimRules.fov(500, 1), AimRules.MAX_FOV, "Roblox's widest")
		t.eq(AimRules.fov(2, 4), AimRules.MIN_FOV, "and narrowest")
		t.near(AimRules.sensitivity(4), 0.25, 1e-12, "a scope turns a quarter as fast")
		t.eq(AimRules.sensitivity(1), 1)
		-- Easing: gets there, snaps at the end, never overshoots.
		local zoom = 1
		for _ = 1, 120 do
			local before = zoom
			zoom = AimRules.ease(zoom, 4, 1 / 60, 14)
			t.ok(zoom >= before and zoom <= 4, "eased up")
		end
		t.eq(zoom, 4, "there")
		t.ok(AimRules.hidesCrosshair("raised") and AimRules.hidesCrosshair("sights"), "raised: no crosshair")
		t.ok(not AimRules.hidesCrosshair("lowered"))
		t.eq(AimRules.showsDot("raised"), W.ShoulderDot, "the shoulder dot")
		t.ok(not AimRules.showsDot("sights") and not AimRules.showsDot("lowered"), "only over the shoulder")
	end)

	--[[ Recoil, kick, sway ]]

	t.test("weapon client: a kick reaches the camera once and its share comes back", function()
		local recoil = AimRules.newRecoil()
		AimRules.kick(recoil, 2, 0.3)
		local pitch, yaw = AimRules.takeKick(recoil)
		t.ok(pitch == 2 and yaw == 0.3, "the kick")
		pitch, yaw = AimRules.takeKick(recoil)
		t.ok(pitch == 0 and yaw == 0, "taken once")
		t.near(recoil.back, 2 * W.RecoilRecover, 1e-12, "the share to come back")
		local back = 0
		local steps = math.floor(W.RecoilRecoverSeconds * 240 + 0.5)
		for _ = 1, steps do
			back += AimRules.recover(recoil, 1 / 240)
		end
		t.near(back, 2 * W.RecoilRecover * (1 - math.exp(-3)), 0.01, "95% within RecoilRecoverSeconds")
		for _ = 1, 600 do
			back += AimRules.recover(recoil, 1 / 60)
		end
		t.near(back, 2 * W.RecoilRecover, 1e-9, "all of it, no more")
		t.eq(recoil.back, 0, "nothing left")
		t.eq(AimRules.recover(recoil, 1), 0)
		AimRules.kick(recoil, 1, 1)
		AimRules.clearRecoil(recoil)
		t.ok(recoil.pitch == 0 and recoil.yaw == 0 and recoil.back == 0, "cleared")
	end)

	t.test("weapon client: automatic fire climbs, a pause brings most of it back", function()
		local smg = spec("Smg")
		local ticks = Handling.shotTicks(smg, 2)
		local recoil = AimRules.newRecoil()
		local stance = { sights = true }
		local view = 0
		local frame = 1 / 60
		local now, nextShot, shots = 0, 0, 0
		local kicked = 0
		local peak = 0
		while now < 2 do
			if shots < 20 and now >= nextShot then
				shots += 1
				nextShot += ticks * TICK
				local p = Handling.recoil(smg, stance, 99, shots)
				kicked += p
				AimRules.kick(recoil, p, 0)
			end
			local p = AimRules.takeKick(recoil)
			view += p - AimRules.recover(recoil, frame)
			peak = math.max(peak, view)
			now += frame
		end
		t.ok(peak > kicked * (1 - W.RecoilRecover), `the aim climbed ({peak} of {kicked} degrees kicked)`)
		t.near(view, kicked * (1 - W.RecoilRecover), 0.05, "settles at the share that stays")
	end)

	t.test("weapon client: the model's kick, and the sway within its amplitude", function()
		local back, up = AimRules.modelKick(0)
		t.ok(back == AimRules.KICK_BACK and up == AimRules.KICK_UP, "the full kick at the shot")
		local halfBack, halfUp = AimRules.modelKick(AimRules.KICK_SECONDS / 2)
		t.near(halfBack, AimRules.KICK_BACK * 0.25, 1e-12, "settling")
		t.near(halfUp, AimRules.KICK_UP * 0.25, 1e-12)
		local doneBack, doneUp = AimRules.modelKick(AimRules.KICK_SECONDS)
		t.ok(doneBack == 0 and doneUp == 0, "settled")
		local beforeBack = AimRules.modelKick(-1)
		t.eq(beforeBack, 0, "nothing before a shot")
		-- The sway stays within its amplitude, and holding breath shrinks it.
		local rifle = spec("AssaultRifle")
		local stance = { sights = true }
		local amplitude = Handling.swayAmplitude(rifle, stance)
		local steady = Handling.swayAmplitude(rifle, stance, W.HoldBreathSway)
		local most, mostSteady = 0, 0
		for i = 0, 600 do
			local yaw, pitch = Handling.sway(rifle, stance, i / 60)
			most = math.max(most, math.abs(yaw), math.abs(pitch))
			local y2, p2 = Handling.sway(rifle, stance, i / 60, W.HoldBreathSway)
			mostSteady = math.max(mostSteady, math.abs(y2), math.abs(p2))
		end
		t.ok(most <= amplitude + 1e-9 and most > 0.9 * amplitude, `sway within {amplitude} degrees ({most})`)
		t.ok(mostSteady <= steady + 1e-9 and steady < amplitude, "holding breath steadies it")
	end)

	--[[ Poses ]]

	t.test("weapon client: the hip pose aims at the centre, the arms and gun follow the look", function()
		local x, y, z, yaw, pitch = AimRules.hipPose()
		t.ok(x > 0 and y < 0 and z < 0, "low on the right, ahead")
		-- The barrel from the grip, turned left by yaw and up by pitch, meets the view axis.
		local dx, dy, dz = -math.sin(yaw) * math.cos(pitch), math.sin(pitch), -math.cos(yaw) * math.cos(pitch)
		local s = -x / dx
		t.near(y + dy * s, 0, 1e-9, "level with the centre where it crosses")
		t.near(z + dz * s, -AimRules.AIM_DEPTH, 1e-9, "AIM_DEPTH ahead")
		local look = math.rad(20)
		for _, long in { true, false } do
			local rx, _, _, lx, _, _, leftPinned, head = AimRules.armPose("raised", look, long)
			t.near(rx, math.pi / 2 + look, 1e-12, "the right arm along the look")
			t.ok(leftPinned and lx >= math.pi / 2, "the left arm forward too")
			t.near(head :: number, look * 0.8, 1e-12, "the head turned with the look")
			local gunYaw, gunPitch = AimRules.gunAngles("raised", look, long)
			t.ok(gunYaw == 0 and gunPitch == look, "the gun along the look")
			local lowYaw, lowPitch = AimRules.gunAngles("lowered", look, long)
			t.ok(lowPitch < 0 and lowYaw >= 0, "lowered: down and to the left")
		end
		local _, _, _, _, _, _, pistolLeft, pistolHead = AimRules.armPose("lowered", 0, false)
		t.ok(not pistolLeft and pistolHead == nil, "a lowered handgun leaves the left arm and head alone")
		local _, _, _, _, _, _, rifleLeft = AimRules.armPose("lowered", 0, true)
		t.ok(rifleLeft, "a lowered long gun takes both hands")
		t.ok(AimRules.longGun(spec("AssaultRifle")) and AimRules.longGun(spec("Smg")), "long guns")
		t.ok(not AimRules.longGun(spec("Pistol")) and not AimRules.longGun(spec("Revolver")), "handguns")
		t.ok(not AimRules.longGun(nil))
	end)

	t.test("weapon client: a melee weapon guards across the chest and winds a heavy attack up", function()
		local rx, ry, _, lx, ly, _, leftPinned = AimRules.meleeArms(true, 0)
		t.ok(rx and rx > math.pi / 2 and ry > 0, "guarding: the right arm up and across")
		t.ok(leftPinned and lx > 1 and ly < 0, "both hands on it")
		local guardAgain = AimRules.meleeArms(true, 0.7)
		t.eq(guardAgain, rx, "the guard wins over a wind-up")
		local half = AimRules.meleeArms(false, 0.5)
		local full, _, _, _, _, _, windLeft = AimRules.meleeArms(false, 1)
		t.ok(half and full and full > half and full > math.pi / 2, "the arm draws up as it winds")
		t.ok(not windLeft, "the left arm left to the animation")
		t.eq(AimRules.meleeArms(false, 0), nil, "neither: the animation's arms")
		t.eq(AimRules.meleeArms(false, 3), AimRules.meleeArms(false, 1), "a wind-up past 1 is 1")
		local x, y, z, roll, tip = AimRules.meleeView(0, 0)
		t.ok(x == 0 and y == 0 and z == 0 and roll == 0 and tip == 0, "at rest: no shift")
		x, _, _, roll = AimRules.meleeView(1, 0)
		t.ok(x < 0 and roll > 0, "guarding: across to the middle, laid over")
		local _, wy, wz, _, wtip = AimRules.meleeView(0, 1)
		t.ok(wy > 0 and wz > 0 and wtip > 0, "winding up: up and back")
		local factor, noSprint = AimRules.speed("lowered", true)
		t.ok(factor == W.GuardSpeed and noSprint, "guarding slows to GuardSpeed")
	end)

	t.test("weapon client: the aim's ray meets boxes, and turns to the eyes", function()
		t.near(AimRules.rayBox(0, 0, 0, 1, 0, 0, 5, -1, -1, 6, 1, 1) :: number, 5, 1e-12, "a box ahead")
		t.eq(AimRules.rayBox(0, 0, 0, 1, 0, 0, 5, 2, -1, 6, 3, 1), nil, "beside it")
		t.eq(AimRules.rayBox(0, 0, 0, 1, 0, 0, -6, -1, -1, -5, 1, 1), nil, "behind")
		t.eq(AimRules.rayBox(0, 0, 0, 0, 1, 0, -1, -1, -1, 1, 1, 1), 0, "starting inside")
		t.eq(AimRules.rayBox(0, 0, 0, 0, 0, 1, 2, -1, -1, 3, 1, 9), nil, "parallel, outside")
		-- From eyes below the camera's line towards what it points at.
		local ax, ay, az = AimRules.aimFrom(0, 0, 0, 10, 1, 0, 1, 0, 0)
		t.near(ax * ax + ay * ay + az * az, 1, 1e-9, "a unit vector")
		t.ok(ay > 0 and ax > 0.99, "up a little to meet it")
		local bx, by, bz = AimRules.aimFrom(0, 0, 0, -3, 0, 0, 1, 0, 0)
		t.ok(bx == 1 and by == 0 and bz == 0, "a point behind the eyes: the camera's direction")
		t.ok(AimRules.moving(2) and not AimRules.moving(0.1), "moving")
	end)

	--[[ Shots ]]

	t.test("weapon client: fire sounds near, far and suppressed; flashes and tracers' glow", function()
		local pistol = spec("Pistol")
		t.eq(ShotRules.fireSound(pistol, false, 10), "item.firearm.pistol.fire", "the class shot")
		t.eq(ShotRules.fireSound(spec("Crossbow"), false, 10), "item.crossbow.fire", "the crossbow's")
		t.eq(ShotRules.fireSound(spec("HuntingRifle"), false, 10), "item.firearm.heavy.fire")
		t.eq(ShotRules.fireSound(pistol, true, 10), ShotRules.SUPPRESSED, "suppressed")
		t.eq(ShotRules.fireSound(pistol, false, W.FarSound + 1), ShotRules.FAR, "far")
		t.eq(ShotRules.fireSound(pistol, false, W.FarSound), pistol.sound, "up to FarSound: near")
		t.eq(ShotRules.fireSound(pistol, true, W.FarSound + 1), nil, "suppressed and far: unheard")
		t.eq(ShotRules.fireSound(nil, false, 1), nil, "no gun")
		t.ok(ShotRules.flash(false) and not ShotRules.flash(true), "no flash suppressed")
		t.ok(not ShotRules.glow(I.Suppressor, 1), "a suppressor's tracers don't glow")
		t.ok(ShotRules.glow(I.ImprovisedSuppressor, 1), "an improvised one's do")
		t.ok(ShotRules.glow(I.Suppressor, 0.1), "nor once it is Ruined")
		t.ok(ShotRules.glow(nil, nil), "no device")
		t.eq(ShotRules.DRY, "item.firearm.dry")
		t.eq(ShotRules.JAM, "item.firearm.jam")
	end)

	t.test("weapon client: impacts by hit, and pumps' and bolts' racks", function()
		local Hit = WeaponSync.Hit
		t.eq(ShotRules.impact(Hit.Block), "block")
		t.eq(ShotRules.impact(Hit.Glass), nil, "glass: the edit shatters it")
		t.eq(ShotRules.impact(Hit.None), nil, "the flight ended in the air")
		for _, hit in { Hit.Mob, Hit.MobHead, Hit.Player, Hit.PlayerHead } do
			t.eq(ShotRules.impact(hit), "blood", `hit {hit}`)
			t.eq(ShotRules.impactSound(hit), ShotRules.FLESH)
		end
		t.eq(ShotRules.impactSound(Hit.Block), ShotRules.IMPACT)
		t.eq(ShotRules.impactSound(Hit.Glass), nil)
		t.near(ShotRules.cycleDelay(spec("PumpShotgun"), 1) :: number, 0.4, 1e-12, "a pump racks 0.4 of 1 s on")
		t.near(ShotRules.cycleDelay(spec("BoltActionRifle"), 1) :: number, 0.6, 1e-12, "a bolt 0.4 of 1.5 s")
		t.eq(ShotRules.cycleDelay(spec("Pistol"), 1), nil, "a pistol doesn't")
		t.eq(ShotRules.cycleDelay(spec("DoubleBarrelShotgun"), 1), nil)
	end)

	t.test("weapon client: own shots add impacts and stop automatic fire, others' are drawn whole", function()
		local me, them = 42, 7
		local function shot(shooter: number, flags: { [string]: boolean }?): WeaponSync.Shot
			local f = flags or {}
			return {
				shooter = shooter,
				item = I.AssaultRifle,
				shot = 1,
				suppressed = f.suppressed == true,
				jammed = f.jammed == true,
				refused = f.refused == true,
				ox = 0,
				oy = 64,
				oz = 0,
				pellets = if f.refused then {} else { { x = 10, y = 64, z = 0, hit = WeaponSync.Hit.Block } },
			}
		end
		local out = ShotRules.newEffects()
		ShotRules.effects(shot(me), me, 0, true, out)
		t.ok(out.own and out.impacts, "own: the authoritative impacts")
		t.ok(not out.flash and not out.tracer and out.sound == nil, "drawn already when fired")
		t.ok(not out.stop, "accepted: keeps firing")
		ShotRules.effects(shot(me, { refused = true }), me, 0, true, out)
		t.ok(out.stop and not out.impacts, "refused: stops, nothing to draw")
		ShotRules.effects(shot(me, { jammed = true }), me, 0, true, out)
		t.ok(out.stop and out.jammed and out.impacts, "jammed: stops")
		ShotRules.effects(shot(them), me, 20, true, out)
		t.ok(not out.own and out.flash and out.impacts, "another's: the flash and impacts")
		t.eq(out.tracer, W.Tracers == true, "tracers as Config says")
		t.eq(out.sound, "item.firearm.rifle.fire", "its class shot")
		ShotRules.effects(shot(them, { suppressed = true }), me, 20, false, out)
		t.ok(not out.flash and out.sound == ShotRules.SUPPRESSED and not out.glow, "suppressed")
		ShotRules.effects(shot(them), me, W.FarSound + 50, true, out)
		t.eq(out.sound, ShotRules.FAR, "far away")
		t.ok(not out.stop, "another's never stops this player's fire")
	end)

	t.test("weapon client: look keys read back into their parts", function()
		local key = WeaponState.lookKey(stack("AssaultRifle", {
			mag = I.RifleMagazine,
			optic = I.RifleScope,
			muzzle = I.Suppressor,
			light = I.WeaponFlashlight,
			lit = true,
		}))
		local mag, optic, muzzle, light, lit = ShotRules.lookParts(key)
		t.ok(mag == I.RifleMagazine and optic == I.RifleScope and muzzle == I.Suppressor, "the parts")
		t.ok(light == I.WeaponFlashlight and lit, "the light, on")
		mag, optic, muzzle, light, lit = ShotRules.lookParts(WeaponState.lookKey(stack("Pistol")))
		t.ok(mag == 0 and optic == 0 and muzzle == 0 and light == 0 and not lit, "a bare gun")
		for _, bad in { "", "1,2,3", "a,b,c,d,e", "1,2,3,4,7" } do
			local m, o, d, l, on = ShotRules.lookParts(bad)
			t.ok(m == 0 and o == 0 and d == 0 and l == 0 and not on, `malformed "{bad}": nothing`)
		end
		local nothing = ShotRules.lookParts(nil)
		t.eq(nothing, 0)
	end)

	--[[ Looks ]]

	t.test("weapon client: every gun's look lies on its model", function()
		for _, id in Weapons.FIREARMS do
			local gun = Weapons.firearm(id) :: Weapons.FirearmSpec
			local def = Items.get(id) :: Items.ItemDef
			local model = def.model :: { Items.ModelBox }
			local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
			local topAtGrip = -math.huge
			local look = gun.look
			for _, box in model do
				minX = math.min(minX, box.offset[1] - box.size[1] / 2)
				maxX = math.max(maxX, box.offset[1] + box.size[1] / 2)
				minY = math.min(minY, box.offset[2] - box.size[2] / 2)
				maxY = math.max(maxY, box.offset[2] + box.size[2] / 2)
				if math.abs(box.offset[1] - look.grip[1]) <= box.size[1] / 2 then
					topAtGrip = math.max(topAtGrip, box.offset[2] + box.size[2] / 2)
				end
			end
			t.near(look.muzzle[1], maxX, 0.6, `{gun.name}: the muzzle at the barrel's end`)
			t.ok(look.grip[1] > minX and look.grip[1] < maxX, `{gun.name}: the grip on the gun`)
			t.ok(look.grip[2] >= minY and look.grip[2] <= maxY, `{gun.name}: the grip within it`)
			t.ok(look.sight >= topAtGrip - 1e-9, `{gun.name}: the sight line clears the gun at the grip`)
			t.ok(look.sight <= maxY + 1.5, `{gun.name}: and stays on it`)
		end
	end)

	--[[ The require-cycle rule ]]

	t.test("weapon client: nothing Interaction/Firearms requires requires Interaction/BlockInteraction", function()
		-- A module's file from its path in the client tree (a folder's init.luau).
		local function fileOf(parts: { string }): string?
			local path = "src/client/" .. table.concat(parts, "/")
			if fs.isFile(path .. ".luau") then
				return path .. ".luau"
			elseif fs.isFile(path .. "/init.luau") then
				return path .. "/init.luau"
			end
			return nil
		end
		-- The client modules `file` (its place: `parts`) requires through script.Parent...
		local function requires(parts: { string }, file: string): { { string } }
			local found: { { string } } = {}
			local source = fs.readFile(file)
			for chain in string.gmatch(source, "require%(script(%.[%w%.]+)%)") do
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
		local seen: { [string]: boolean } = {}
		local reached: { string } = {}
		local function walk(parts: { string })
			local file = fileOf(parts)
			if file == nil or seen[file] then
				return
			end
			seen[file] = true
			table.insert(reached, file)
			-- (A module's `script` is itself; its folder is script.Parent.)
			for _, next in requires(parts, file) do
				walk(next)
			end
		end
		walk({ "Interaction", "Firearms" })
		t.ok(seen["src/client/Player/AimCamera.luau"], "the walk reaches the aim camera")
		t.ok(seen["src/client/Rendering/ShotView.luau"], "and the shots")
		t.ok(seen["src/client/Player/HeldItems.luau"], "and the held items")
		t.ok(
			not seen["src/client/Interaction/BlockInteraction.luau"],
			`a cycle: {table.concat(reached, ", ")} reaches BlockInteraction`
		)
		t.ok(#reached > 20, `modules reached ({#reached})`)
	end)
end
