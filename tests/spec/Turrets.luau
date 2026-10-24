--[[
	Turrets and the Metal Miner, the foundation (Shared/Turrets, Shared/Turrets/TurretRules,
	Machines/Kinds/Turret, Miner and AmmoPress, Machines/MinerRules, the Turrets message,
	WeaponSync's `plain` in Weapons): the registries in their order (blocks, items, lore, icons,
	sounds, Ages), the twelve Specs against their blocks, calibres, stand-in guns and fits; the
	pure maths (aim, muzzle, turning the short way and never past, the exact cadence and the two
	ways to get it wrong, the packed state, spread, range and noise with every attachment, a
	Ruined one and NoiseScale); the turret kind on a fake service (idle, tracking and shot energy,
	no power, blocked by what is over it, snow layers 1 and 2, no ammo, the feed's cap by tier,
	hand-filled it fires its buffer then shows "No ammo", the Lure kept in the item, attachments
	never worn, the ammo slot taking only its calibre up to its buffer, no transporter reaching the
	attachments, inert with the turrets off or no service), the simulation's statuses from the
	order alone (no turret block, no hostiles),
	MachineWorld handing the service once a step, the panels and their lines (the range with the
	optic), the miner's and the press's frozen layouts, the decor, and the game with the features
	switched off.
]]

local Loader = require("../lib/Loader")

return function(t, shared, require, server, client)
	local Blocks = require(shared.Blocks)
	local Config = require(shared.Config)
	local Coords = require(shared.World.Coords)
	local Crafting = require(shared.Crafting)
	local Items = require(shared.Items)
	local LoreList = require(shared.Items.LoreList)
	local Machines = require(shared.Machines)
	local MinerRules = require(shared.Machines.MinerRules)
	local Progression = require(shared.Progression)
	local Protocol = require(shared.Net.Protocol)
	local Sounds = require(shared.Sounds)
	local TexturePack = require(shared.TexturePack)
	local Transmitters = require(shared.Transmitters)
	local Turrets = require(shared.Turrets)
	local TurretRules = require(shared.Turrets.TurretRules)
	local Weapons = require(shared.Weapons)
	local Containers = require(server.Players.Containers)
	local MachineWorld = require(server.Machines.MachineWorld)
	local TurretWorld = require(server.Turrets.TurretWorld)
	local BlockDecor = require(client.Rendering.BlockDecor)
	local MenuLayout = require(client.Ui.MenuLayout)

	local B, I = Blocks.id, Items.id
	local AIR = Blocks.AIR
	local STATUS = Turrets.STATUS
	local SLOT = Turrets.SLOT
	local HEADER = Machines.HEADER
	local ENERGY, RATE = Machines.ENERGY, Machines.RATE
	local CREDIT = TurretRules.CREDIT
	local TIERS = { "Basic", "Advanced", "Elite", "Ultimate" }
	local TYPES = { smg = "Smg", rifle = "Rifle", sniper = "Sniper" }
	local LABELS = { smg = "SMG", rifle = "Rifle", sniper = "Sniper" }
	local PARTS = {
		"SmgBarrel",
		"RifleBarrel",
		"SniperBarrel",
		"BeltFeeder",
		"Receiver",
		"ServoMotor",
		"TargetingModule",
		"LaserSight",
	}

	-- A random number generator of its own (deterministic).
	local function rng(seed: number): () -> number
		local state = seed
		return function(): number
			state = (state * 1103515245 + 12345) % 2147483648
			return state / 2147483648
		end
	end

	--[[ The registries ]]

	t.test("turrets: twelve turrets after the seasons, the miner and the press; the parts after the weapons", function()
		local id = 486
		for _, turretType in Turrets.TYPES do
			for tier, tierName in TIERS do
				local name = `{tierName}{TYPES[turretType]}Turret`
				t.eq(B[name], id, `{name}'s id`)
				local def = Blocks.get(id)
				t.eq(def.displayName, `{tierName} {LABELS[turretType]} Turret`, `{name}'s name`)
				t.eq(def.decor, name, `{name}'s decor`)
				t.eq(def.machine and def.machine.kind, `turret_{turretType}_{tier}`, `{name}'s kind`)
				local capacity = Config.Turrets.Capacity[tier]
				t.ok(def.energy and def.energy.capacity == capacity and def.energy.input == capacity, `{name}'s store`)
				t.ok(not Blocks.isSturdy(id), `{name}: nothing rests on its top`)
				t.eq(def.hardness, 3.5)
				t.eq(def.toolLevel, 0, "a pickaxe drops it")
				t.eq(Blocks.soundType(id), "metal")
				t.eq(Blocks.zombieBreak(id), 0, "zombies never break machines")
				t.ok(type(LoreList[name]) == "string", `{name}'s lore`)
				t.eq(TexturePack.Blocks[name], nil, `{name} is never textured`)
				id += 1
			end
		end
		t.eq(B.MetalMiner, 498)
		t.eq(B.AmmoPress, 499)
		t.eq(Blocks.count, 500, "the last blocks")
		for _, name in { "MetalMiner", "AmmoPress" } do
			local def = Blocks.get(B[name])
			t.eq(def.decor, name)
			t.ok(Blocks.isSturdy(B[name]), `{name} is a full machine cube`)
			t.ok(type(LoreList[name]) == "string", `{name}'s lore`)
			t.eq(TexturePack.Blocks[name], nil, `{name} is never textured`)
		end
		t.eq(Machines.energyOf(B.MetalMiner).capacity, Config.Miner.Capacity)
		t.eq(Machines.energyOf(B.AmmoPress).capacity, Config.AmmoPress.Capacity)
		for index, name in PARTS do
			t.eq(I[name], 4311 + index, `{name}'s id`)
			t.eq(TexturePack.Icons[name], "", `{name}'s icon is blank until made`)
			t.ok(type(LoreList[name]) == "string", `{name}'s lore`)
			t.eq(Items.maxStack(I[name]), if name == "LaserSight" then 1 else 64, `{name}'s stack`)
		end
		t.eq(Items.list[#Items.list].name, "LaserSight", "the last item")
		t.eq(Weapons.attachment(I.LaserSight), nil, "the Laser Sight fits no hand-held gun")
	end)

	t.test("turrets: the sounds after the seasons', the client's; the machines' the fifth sheet's hums", function()
		local first = Sounds.id["block.turret.servo"]
		for i, name in { "block.turret.servo", "block.metal_miner.hum", "block.ammo_press.hum" } do
			local event = Sounds.get(name)
			t.ok(event ~= nil, `{name} is in the catalogue`)
			assert(event)
			t.eq(Sounds.id[name], first + i - 1, `{name} in order`)
			t.eq(event.side, "client", `{name} is the client's`)
			t.eq(event.source, "blocks")
		end
		t.ok(string.find((Sounds.get("block.turret.servo") :: any).id, "^rbxasset://") ~= nil, "the servo's stand-in")
		t.eq((Sounds.get("block.metal_miner.hum") :: any).category, "machine.heavy_hum", "the miner's heavy hum")
		t.eq((Sounds.get("block.ammo_press.hum") :: any).category, "machine.hum", "the press's hum")
		t.eq(Sounds.id["ambient.season.heat_wave"], first - 1, "right after the seasons'")
		t.eq(Sounds.id["item.firearm.9mm.fire"], first + 3, "then the fifth sheet's")
	end)

	t.test(
		"turrets: the parts, the Laser Sight and three tiers are the Electric Age's, the Ultimates the Atomic's",
		function()
			local function age(name: string): number?
				local found = Progression.requirement(I[name])
				return if found then found.index else nil
			end
			for _, name in PARTS do
				t.eq(age(name), 4, `{name}: the Electric Age`)
			end
			t.eq(age("MetalMiner"), 4)
			t.eq(age("AmmoPress"), 4)
			for _, typeName in TYPES do
				for tier, tierName in TIERS do
					t.eq(age(`{tierName}{typeName}Turret`), if tier == 4 then 5 else 4, `{tierName} {typeName}`)
				end
			end
		end
	)

	--[[ The Specs ]]

	t.test("turrets: twelve Specs: blocks, calibres, stand-in guns, numbers and fits", function()
		t.eq(#Turrets.SPECS, 12)
		local calibres = { smg = "9mm", rifle = "556", sniper = "308" }
		local rounds = { smg = I.Rounds9mm, rifle = I.Rounds556, sniper = I.Rounds308 }
		local guns = { smg = I.Smg, rifle = I.AssaultRifle, sniper = I.HuntingRifle }
		for t0, turretType in Turrets.TYPES do
			local numbers = Config.Turrets.Types[turretType]
			for tier = 1, 4 do
				local spec = Turrets.SPECS[(t0 - 1) * 4 + tier]
				t.eq(Turrets.of(turretType, tier), spec, "of")
				t.eq(Turrets.spec(spec.block), spec, "by block")
				t.ok(Turrets.isTurret(spec.block))
				t.eq(spec.type, turretType)
				t.eq(spec.tier, tier)
				t.eq(spec.kind, `turret_{turretType}_{tier}`)
				t.eq(Machines.kindOf(spec.block) and (Machines.kindOf(spec.block) :: any).name, spec.kind, "its kind")
				t.eq(spec.calibre, calibres[turretType])
				t.eq(spec.ammo, rounds[turretType])
				t.eq(spec.firearm, guns[turretType])
				t.eq(spec.range, numbers.range[tier])
				t.eq(spec.rpm, numbers.rpm[tier])
				t.eq(spec.buffer, numbers.buffer[tier])
				t.eq(spec.turn, numbers.turn[tier])
				t.eq(spec.spread, numbers.spread[tier])
				t.eq(spec.settle, numbers.settle)
				t.eq(spec.barrel, numbers.barrel)
				t.eq(spec.pitchMin, numbers.pitchMin)
				t.eq(spec.shot, numbers.shot)
				t.eq(spec.damageScale, numbers.damageScale)
				t.eq(spec.capacity, Config.Turrets.Capacity[tier])
				t.eq(spec.idle, Config.Turrets.IdleJoules[tier])
				t.eq(spec.tracking, Config.Turrets.TrackingJoules[tier])
				t.ok(spec.optics[I.LaserSight], "a Laser Sight fits every type")
				t.eq(spec.optics[I.RifleScope] == true, turretType ~= "smg", "a scope: rifles and snipers")
				t.ok(spec.optics[I.RedDotSight] == nil, "no red dot")
				t.ok(spec.muzzles[I.Suppressor] and spec.muzzles[I.ImprovisedSuppressor], "both suppressors")
				t.ok(spec.muzzles[I.WeaponFlashlight] == nil, "no flashlight")
				t.ok(table.isfrozen(spec), "frozen")
			end
		end
		t.ok(not Turrets.isTurret(B.ElectricFurnace) and not Turrets.isTurret(nil))
		t.eq(Turrets.spec(B.Stone), nil)
		-- The feeder rule.
		local smg4, smg2, smg1 = Turrets.of("smg", 4), Turrets.of("smg", 2), Turrets.of("smg", 1)
		t.eq(Turrets.rpm(smg4, 0), 360, "by hand: its own")
		t.eq(Turrets.rpm(smg4, 1), 90, "a Basic feeder: the Basic's")
		t.eq(Turrets.rpm(smg4, 3), 240)
		t.eq(Turrets.rpm(smg4, 4), 360)
		t.eq(Turrets.rpm(smg2, 4), 150, "never above its own")
		t.eq(Turrets.rpm(smg1, 2), 90)
		t.eq(Turrets.rpm(smg4, 0 / 0), 360, "NaN: by hand")
	end)

	--[[ The maths ]]

	t.test("turret rules: the pivot, the aim, the direction and the muzzle agree", function()
		local px, py, pz = TurretRules.pivot(3, 64, -7)
		t.eq(px, 3.5)
		t.near(py, 65.82, 1e-9)
		t.eq(pz, -6.5)
		local dx, dy, dz = TurretRules.direction(0, 0)
		t.near(dx, 0, 1e-12)
		t.near(dy, 0, 1e-12)
		t.near(dz, 1, 1e-12, "yaw 0 faces +Z")
		dx, dy, dz = TurretRules.direction(math.pi / 2, 0)
		t.near(dx, 1, 1e-12, "and grows towards +X (mobs' facing)")
		t.near(dz, 0, 1e-12)
		local _, up = TurretRules.direction(0, math.pi / 2)
		t.near(up, 1, 1e-12, "pitch up")
		local random = rng(7)
		for _ = 1, 200 do
			local tx, ty, tz = (random() - 0.5) * 100, (random() - 0.5) * 60, (random() - 0.5) * 100
			local yaw, pitch, distance = TurretRules.aim(0, 0, 0, tx, ty, tz)
			local ax, ay, az = TurretRules.direction(yaw, pitch)
			t.near(ax * distance, tx, 1e-9)
			t.near(ay * distance, ty, 1e-9)
			t.near(az * distance, tz, 1e-9)
			t.ok(yaw > -math.pi - 1e-12 and yaw <= math.pi + 1e-12, "yaw in range")
			local mx, my, mz = TurretRules.muzzle(2, 64, 3, yaw, pitch, 0.85)
			local qx, qy, qz = TurretRules.pivot(2, 64, 3)
			t.near(mx, qx + ax * 0.85, 1e-12)
			t.near(my, qy + ay * 0.85, 1e-12)
			t.near(mz, qz + az * 0.85, 1e-12)
		end
		local yaw0, pitch0, d0 = TurretRules.aim(1, 2, 3, 1, 2, 3)
		t.ok(yaw0 == 0 and pitch0 == 0 and d0 == 0, "the same point")
		local yawUp, pitchUp = TurretRules.aim(0, 0, 0, 0, 5, 0)
		t.eq(yawUp, 0, "straight up: yaw 0")
		t.near(pitchUp, math.pi / 2, 1e-12)
		t.near(TurretRules.offAngle(1, 0.2, 1, 0.2), 0, 1e-6)
		t.near(TurretRules.offAngle(0, 0, math.pi, 0), math.pi, 1e-9, "behind")
		t.near(TurretRules.offAngle(0, 0, 0.1, 0), 0.1, 1e-9)
		-- Each type's lowest pitch, its own (the SMG's and the rifle's PitchMin, -60; the sniper's
		-- longer barrel -51); without a spec the lowest any type aims at.
		local lows = { smg = -60, rifle = -60, sniper = -51 }
		for _, s in Turrets.SPECS do
			local low = lows[s.type]
			t.eq(s.pitchMin, low, `{s.name}: its type's pitchMin`)
			t.ok(TurretRules.inPitch(math.rad(low), s) and TurretRules.inPitch(math.rad(75), s), "the limits are in")
			t.ok(
				not TurretRules.inPitch(math.rad(low - 1), s) and not TurretRules.inPitch(math.rad(76), s),
				"beyond not"
			)
			local a, b = TurretRules.pitchLimits(s)
			t.ok(a == math.rad(low) and b == math.rad(75), "pitchLimits")
		end
		t.eq(Config.Turrets.PitchMin, -60)
		t.ok(TurretRules.inPitch(math.rad(-60)) and not TurretRules.inPitch(math.rad(-61)), "no spec: PitchMin")
		-- Nearest first, with 0.05 a degree of turning: a zombie 2 blocks nearer but behind loses.
		t.ok(TurretRules.score(10, math.pi) > TurretRules.score(12, 0), "behind loses")
		t.near(TurretRules.score(10, math.rad(20)), 11, 1e-9)
	end)

	t.test("turret rules: turning never overshoots and goes the short way across +-pi", function()
		-- From 3 to -3 radians the short way is up through pi (0.28 rad), not down (5.7 rad).
		local yaw = TurretRules.turn(3, 0, -3, 0, 0.1)
		t.near(yaw, 3.1, 1e-12, "up towards pi")
		local steps = 0
		local y, p = 3, 0
		repeat
			y, p = TurretRules.turn(y, p, -3, 0.5, 0.1)
			steps += 1
		until (y == -3 and p == 0.5) or steps > 100
		t.ok(steps <= 6, `reached in {steps} steps, exactly`)
		local random = rng(11)
		for _ = 1, 2000 do
			local fromYaw, fromPitch = (random() - 0.5) * 4 * math.pi, (random() - 0.5) * 2
			local wantYaw, wantPitch = (random() - 0.5) * 2 * math.pi, (random() - 0.5) * 2
			local step = random() * 0.5
			local newYaw, newPitch = TurretRules.turn(fromYaw, fromPitch, wantYaw, wantPitch, step)
			local before = math.abs(TurretRules.wrap(wantYaw - fromYaw))
			local after = math.abs(TurretRules.wrap(wantYaw - newYaw))
			t.ok(math.abs(TurretRules.wrap(newYaw - fromYaw)) <= step + 1e-9, "a step at most")
			t.ok(after <= before + 1e-9, "never further")
			if before <= step then
				t.near(after, 0, 1e-12, "reached exactly")
			else
				t.near(after, before - step, 1e-9, "the short way")
			end
			t.ok(newYaw > -math.pi - 1e-12 and newYaw <= math.pi + 1e-12, "in (-pi, pi]")
			t.ok(math.abs(newPitch - fromPitch) <= step + 1e-12, "pitch a step at most")
			t.ok(math.abs(wantPitch - newPitch) <= math.abs(wantPitch - fromPitch) + 1e-12, "pitch never past")
		end
	end)

	t.test("turret rules: the cadence fires exactly rpm x 10 shots in 12 000 ticks; the pitfalls don't", function()
		local rates: { [number]: boolean } = {}
		for _, spec in Turrets.SPECS do
			rates[spec.rpm] = true
		end
		for rpm in rates do
			local credit, shots = 0, 0
			for _ = 1, 12000 do
				local fires
				credit, fires = TurretRules.cadence(credit, rpm, true)
				if fires then
					shots += 1
				end
				t.ok(credit >= 0 and credit <= CREDIT, "the credit within 0..CREDIT")
			end
			t.eq(shots, rpm * 10, `{rpm} rounds a minute`)
		end
		-- A float credit (rate / 20 a tick): 0.1 x 10 < 1, so 2 a second fires every 11 ticks.
		local float, floatShots = 0, 0
		for _ = 1, 12000 do
			float += (120 / 60) / 20
			if float >= 1 then
				float -= 1
				floatShots += 1
			end
		end
		t.ok(floatShots < 1200, `a float credit: {floatShots} of 1200`)
		-- Capping before taking the shot's off: 90 a minute fires every 14 ticks.
		local capped, cappedShots = 0, 0
		for _ = 1, 12000 do
			capped = math.min(capped + 90, CREDIT)
			if capped >= CREDIT then
				capped -= CREDIT
				cappedShots += 1
			end
		end
		t.ok(cappedShots < 900, `capping first: {cappedShots} of 900`)
		-- A shot that may not go waits with the credit held: none is lost, only that tick.
		local credit, fires = TurretRules.cadence(1150, 90, false)
		t.eq(credit, CREDIT, "held at CREDIT")
		t.eq(fires, false)
		credit, fires = TurretRules.cadence(credit, 90, true)
		t.ok(fires and credit == 90, "fires next tick, keeping the rest")
		-- An unpowered tick adds nothing.
		t.eq((TurretRules.cadence(400, 0, true)), 400)
	end)

	t.test("turrets: the packed state round-trips in a byte; anything else reads as idle", function()
		local most = 0
		for status = 0, 6 do
			for feed = 0, 4 do
				for _, lure in { false, true } do
					for _, tracking in { false, true } do
						local state = Turrets.packState(status, feed, lure, tracking)
						most = math.max(most, state)
						t.eq(state, status + 8 * feed + (if lure then 64 else 0) + (if tracking then 128 else 0))
						local s, f, l, tr = Turrets.unpackState(state)
						t.ok(s == status and f == feed and l == lure and tr == tracking, `{state} round-trips`)
					end
				end
			end
		end
		t.ok(most <= Machines.MAX_STATE, `a byte: {most}`)
		for _, bad in { -1, 256, 1.5, 7, 5 * 8, 0 / 0 } do
			local s, f, l, tr = Turrets.unpackState(bad)
			t.ok(s == STATUS.NO_TARGET and f == 0 and not l and not tr, `{bad} reads as idle`)
		end
		local s, f = Turrets.unpackState(Turrets.packState(99, 9, false, false))
		t.ok(s == STATUS.NO_TARGET and f == 4, "out of range goes as its nearest")
		for status = 0, 6 do
			t.ok(type(Turrets.STATUS_NAMES[status]) == "string", `status {status} has a line`)
		end
		t.eq(Turrets.STATUS_NAMES[STATUS.NO_AMMO], "No ammo")
		t.eq(Turrets.STATUS_NAMES[STATUS.DISABLED], "Disabled")
	end)

	t.test("turret rules: spread, range and noise with each attachment, a Ruined one and NoiseScale", function()
		local smg, rifle, sniper = Turrets.of("smg", 1), Turrets.of("rifle", 4), Turrets.of("sniper", 4)
		t.near(TurretRules.spread(smg, 0, 0, 1), 1.6, 1e-12, "the cone")
		t.near(TurretRules.spread(smg, I.LaserSight, nil, nil), 0.8, 1e-12, "a Laser Sight halves it")
		t.near(TurretRules.spread(smg, nil, I.Suppressor, 1), 1.6 * 0.9, 1e-12, "a suppressor's 0.9")
		t.near(TurretRules.spread(smg, I.LaserSight, I.Suppressor, 1), 0.8 * 0.9, 1e-12, "both")
		t.near(TurretRules.spread(smg, nil, I.ImprovisedSuppressor, 1), 1.6, 1e-12, "the bottle: no change")
		t.near(TurretRules.spread(smg, nil, I.Suppressor, 0), 1.6, 1e-12, "a Ruined one does nothing")
		t.near(TurretRules.spread(smg, I.RifleScope, nil, nil), 1.6, 1e-12, "a scope doesn't fit an SMG")
		t.near(TurretRules.spread(smg, I.RedDotSight, I.WeaponFlashlight, 1), 1.6, 1e-12, "no other device")
		t.eq(TurretRules.range(rifle, nil), 48)
		t.eq(TurretRules.range(rifle, I.RifleScope), 60, "a scope's 1.25")
		t.eq(TurretRules.range(sniper, I.RifleScope), 80, "up to MaxRange")
		t.eq(TurretRules.range(smg, I.RifleScope), 16, "an SMG takes no scope")
		t.eq(TurretRules.range(sniper, I.LaserSight), 64, "a laser reaches no further")
		local max = Config.Turrets.MaxRange
		Config.Turrets.MaxRange = 70
		local capped = TurretRules.range(sniper, I.RifleScope)
		Config.Turrets.MaxRange = max
		t.eq(capped, 70, "MaxRange caps it")
		t.eq(Turrets.optic(smg, I.LaserSight).scan, 5, "a laser rescans every 5 ticks")
		t.eq(Turrets.optic(smg, nil).scan, Config.Turrets.ScanTicks)
		t.eq(Turrets.optic(sniper, I.RifleScope).head, true, "a scoped sniper aims at heads")
		t.eq(Turrets.optic(rifle, I.RifleScope).head, false, "a scoped rifle doesn't")
		t.eq(Turrets.optic(smg, I.RifleScope).range, 1, "not on an SMG")
		local expected = {
			smg = { 36, 9, 48 * 0.45 * 0.75 },
			rifle = { 60, 15, 80 * 0.45 * 0.75 },
			sniper = { 72, 18, 96 * 0.45 * 0.75 },
		}
		for turretType, numbers in expected do
			local spec = Turrets.of(turretType, 1)
			t.near(TurretRules.shotNoise(spec, nil, nil), numbers[1], 1e-9, `{turretType}'s gunfire`)
			t.near(TurretRules.shotNoise(spec, I.Suppressor, 1), numbers[2], 1e-9, `{turretType} suppressed`)
			t.near(TurretRules.shotNoise(spec, I.ImprovisedSuppressor, 1), numbers[3], 1e-9, `{turretType} improvised`)
			t.near(TurretRules.shotNoise(spec, I.Suppressor, 0), numbers[1], 1e-9, "a Ruined suppressor: loud")
		end
		local scale = Config.Turrets.NoiseScale
		Config.Turrets.NoiseScale = 1
		local full = TurretRules.shotNoise(smg, nil, nil)
		Config.Turrets.NoiseScale = scale
		t.near(full, 48, 1e-9, "NoiseScale times the gun's")
	end)

	--[[ The turret kind, on a fake service ]]

	--[[
		A turret of `spec` in a context of its own: full of energy, nothing above it (`above` sets
		what is), and a fake service that fires whenever it may (unless `hold`), reports
		`status`, `feed` and `tracking` and keeps the last order it got.
	]]
	local function rig(spec: Turrets.Spec): any
		local container = Machines.newContainer(spec.block)
		container.data[ENERGY] = spec.capacity
		local r: any = {
			container = container,
			above = AIR,
			hold = false,
			feed = 0,
			tracking = false,
			shots = 0,
			calls = 0,
			order = nil,
		}
		r.service = function(order: any, out: any): any
			r.calls += 1
			r.order = table.clone(order)
			out.fired = not r.hold and order.ready and order.armed and order.powered and not order.blocked
			out.status = if out.fired then STATUS.FIRING elseif not order.armed then STATUS.NO_AMMO else STATUS.TARGETING
			out.feed = r.feed
			out.tracking = r.tracking
			if out.fired then
				r.shots += 1
			end
			return out
		end
		r.ctx = {
			block = spec.block,
			x = 4,
			y = 64,
			z = -2,
			energy = assert(Machines.energyOf(spec.block)),
			tick = 0,
			dayTime = 6000,
			getBlock = function(x: number, y: number, z: number): number?
				if x == 4 and y == 65 and z == -2 then
					return r.above
				end
				return nil
			end,
			turret = r.service,
		}
		function r.tick(n: number?)
			for _ = 1, n or 1 do
				r.ctx.tick += 1
				Machines.tick(container, r.ctx)
			end
		end
		function r.load(count: number)
			container.slots[SLOT.AMMO] = if count > 0 then Items.newStack(spec.ammo, count) else nil
		end
		function r.rounds(): number
			local stack = container.slots[SLOT.AMMO]
			return if stack then stack.count else 0
		end
		function r.state(): (number, number, boolean, boolean)
			return Turrets.unpackState(Machines.get(container, "state"))
		end
		return r
	end

	t.test("turret kind: idle, tracking and a shot's energy; without a whole tick's energy it takes nothing", function()
		local spec = Turrets.of("rifle", 2)
		local r = rig(spec)
		r.hold = true
		r.tick()
		t.eq(Machines.energy(r.container), spec.capacity - spec.idle, "idle")
		t.eq(r.container.data[RATE], -spec.idle, "RATE: minus the J used")
		t.ok(r.order.powered, "powered")
		t.eq(r.order.key, Coords.posKey(4, 64, -2), "the order's key")
		t.eq(r.order.block, spec.block)
		r.tracking = true
		r.tick()
		t.eq(Machines.energy(r.container), spec.capacity - 2 * spec.idle, "the tick it starts tracking: idle")
		local _, _, _, tracking = r.state()
		t.ok(tracking, "the state says it tracks")
		r.tick()
		t.eq(Machines.energy(r.container), spec.capacity - 2 * spec.idle - spec.tracking, "then tracking")
		-- A shot: a round and its energy, CREDIT off the credit.
		r.load(2)
		r.hold = false
		Machines.set(r.container, "credit", CREDIT)
		local before = Machines.energy(r.container)
		local stack = r.container.slots[SLOT.AMMO]
		r.tick()
		t.eq(r.shots, 1, "fired")
		t.eq(r.rounds(), 1, "a round taken")
		t.ok(r.container.slots[SLOT.AMMO] ~= stack, "a new stack table")
		t.eq(Machines.energy(r.container), before - spec.tracking - spec.shot, "tracking and the shot")
		t.eq(r.container.data[RATE], -(spec.tracking + spec.shot))
		t.eq(Machines.get(r.container, "credit"), spec.rpm, "the rest of the credit kept")
		local status = r.state()
		t.eq(status, STATUS.FIRING)
		t.eq(Machines.get(r.container, "active"), 1, "ACTIVE while firing")
		-- Too little for a tick: nothing taken, no shot, the order says so.
		r.tracking = false
		r.tick()
		r.container.data[ENERGY] = spec.idle - 1
		Machines.set(r.container, "credit", CREDIT)
		local shots = r.shots
		r.tick()
		t.eq(Machines.energy(r.container), spec.idle - 1, "all or nothing")
		t.eq(r.container.data[RATE], 0)
		t.ok(not r.order.powered, "not powered")
		t.eq(r.shots, shots, "no shot without power")
	end)

	t.test(
		"turret kind: blocked by a block, a transporter or deeper snow over it; not by snow 1, torches, water",
		function()
			local spec = Turrets.of("smg", 1)
			local cases = {
				{ AIR, false },
				{ B.Stone, true },
				{ B.SnowLayer1, false },
				{ B.SnowLayer2, true },
				{ B.Torch, false },
				{ B.Water, false },
				{ B.BasicLogisticalTransporter, true },
				{ B.Glass, true },
				{ B.Grass, true },
			}
			for _, case in cases do
				local r = rig(spec)
				r.load(1)
				Machines.set(r.container, "credit", CREDIT)
				r.above = case[1]
				r.tick()
				local name = Blocks.get(case[1]).name
				t.eq(r.order.blocked, case[2], `{name} over it`)
				t.eq(r.shots, if case[2] then 0 else 1, `{name}: fires only when clear`)
				t.eq(Turrets.headClear(case[1]), not case[2])
			end
			local r = rig(spec)
			r.above = nil
			r.tick()
			t.ok(not r.order.blocked, "an unknown cell is clear")
			t.ok(Turrets.headClear(nil) and Turrets.headClear(99999), "unknown ids too")
		end
	)

	t.test(
		"turret kind: armed needs a round and a shot's energy; hand filled it fires its buffer, then No ammo",
		function()
			local spec = Turrets.of("smg", 4)
			local r = rig(spec)
			r.tick()
			t.ok(not r.order.armed, "no round: unarmed")
			t.eq(r.order.ammo, 0)
			local status = r.state()
			t.eq(status, STATUS.NO_AMMO)
			r.load(1)
			r.container.data[ENERGY] = spec.idle + spec.shot - 1
			r.hold = true
			r.tick()
			t.ok(not r.order.armed, "a round but too little for a shot")
			t.eq(r.order.ammo, 1, "the order counts the rounds")
			-- By hand (no transporter: feed 0) it fires its own rate until the buffer is empty.
			r = rig(spec)
			r.load(spec.buffer)
			local ticks = 0
			repeat
				r.tick()
				ticks += 1
			until r.rounds() == 0 or ticks > 1000
			t.eq(r.shots, spec.buffer, "every round")
			t.ok(ticks <= math.ceil(spec.buffer * CREDIT / spec.rpm) + 1, `at its own rate ({ticks} ticks)`)
			r.tick(20)
			t.eq(r.shots, spec.buffer, "then nothing")
			status = r.state()
			t.eq(status, STATUS.NO_AMMO, "No ammo")
			t.eq(Machines.status(spec.block, Machines.view(r.container)), "No ammo")
		end
	)

	t.test("turret kind: the feed caps its rate at the feeder's tier, from the next tick", function()
		local spec = Turrets.of("smg", 4)
		for feed = 0, 4 do
			local r = rig(spec)
			r.feed = feed
			r.tick()
			r.shots = 0
			for _ = 1, 12000 do
				r.load(spec.buffer)
				r.container.data[ENERGY] = spec.capacity
				r.tick()
			end
			local rpm = Turrets.rpm(spec, feed)
			t.ok(math.abs(r.shots - rpm * 10) <= 1, `feed {feed}: {r.shots} shots, {rpm * 10} expected`)
			local _, packed = r.state()
			t.eq(packed, feed, "the state keeps the feed")
		end
	end)

	t.test("turret kind: the Lure toggles, starts on and stays in the item either way", function()
		local spec = Turrets.of("sniper", 3)
		local r = rig(spec)
		t.eq(Machines.get(r.container, "lure"), 1, "on when fresh")
		r.tick()
		local _, _, lure = r.state()
		t.ok(lure, "the state says so")
		t.ok(r.order.lure)
		t.ok(Machines.button(r.container, spec.block, 0), "the Lure button")
		t.eq(Machines.get(r.container, "lure"), 0, "off")
		r.tick()
		_, _, lure = r.state()
		t.ok(not lure, "the state follows")
		local data = Machines.save(r.container) :: any
		t.eq(data and data.lure, 0, "off is kept in the item")
		local placed = Machines.newContainer(spec.block)
		t.ok(Machines.restore(placed, data))
		t.eq(Machines.get(placed, "lure"), 0, "and comes back")
		Machines.button(r.container, spec.block, 0)
		local onData = Machines.save(r.container) :: any
		t.eq(onData and onData.lure, nil, "on (the default) needs nothing kept")
		local again = Machines.newContainer(spec.block)
		Machines.restore(again, onData)
		t.eq(Machines.get(again, "lure"), 1, "on again")
		t.eq(Machines.button(r.container, spec.block, 7), false, "no other button")
	end)

	t.test("turret kind: attachments never wear; the ammo slot takes its calibre up to its buffer", function()
		local spec = Turrets.of("rifle", 3)
		local r = rig(spec)
		local laser = Items.newStack(I.LaserSight, 1) :: any
		local suppressor = Items.newStack(I.Suppressor, 1, 100) :: any
		r.container.slots[SLOT.OPTIC] = laser
		r.container.slots[SLOT.MUZZLE] = suppressor
		for _ = 1, 400 do
			r.load(spec.buffer)
			r.tick()
		end
		t.ok(r.shots > 30, `fired {r.shots}`)
		t.ok(rawequal(r.container.slots[SLOT.OPTIC], laser), "the laser's stack untouched")
		t.ok(rawequal(r.container.slots[SLOT.MUZZLE], suppressor), "the suppressor's stack untouched")
		t.eq(suppressor.damage, 100, "no wear")
		t.eq(r.order.optic, I.LaserSight, "the order names the optic")
		t.eq(r.order.muzzle, I.Suppressor)
		t.near(r.order.muzzleFraction, 1 - 100 / 400, 1e-9, "and the muzzle device's durability left")
		-- What each slot takes, and how many.
		local block = spec.block
		t.ok(Machines.mayPlace(block, SLOT.AMMO, I.Rounds556), "its round")
		t.ok(not Machines.mayPlace(block, SLOT.AMMO, I.Rounds9mm), "no other calibre")
		t.ok(not Machines.mayPlace(block, SLOT.AMMO, I.Rounds308))
		t.eq(Machines.slotLimit(block, SLOT.AMMO, I.Rounds556), spec.buffer, "its buffer")
		t.ok(Machines.mayPlace(block, SLOT.OPTIC, I.LaserSight) and Machines.mayPlace(block, SLOT.OPTIC, I.RifleScope))
		t.ok(not Machines.mayPlace(Turrets.of("smg", 1).block, SLOT.OPTIC, I.RifleScope), "no scope on an SMG")
		t.ok(not Machines.mayPlace(block, SLOT.OPTIC, I.RedDotSight))
		t.ok(
			Machines.mayPlace(block, SLOT.MUZZLE, I.Suppressor)
				and Machines.mayPlace(block, SLOT.MUZZLE, I.ImprovisedSuppressor)
		)
		t.ok(Machines.mayPlace(Turrets.of("sniper", 1).block, SLOT.MUZZLE, I.Suppressor), "a sniper takes one too")
		t.ok(not Machines.mayPlace(block, SLOT.MUZZLE, I.WeaponFlashlight))
		t.eq(Machines.slotLimit(block, SLOT.OPTIC, I.LaserSight), 1)
		t.eq(Machines.slotLimit(block, SLOT.MUZZLE, I.Suppressor), 1)
		-- Shift-click by what each slot takes.
		t.eq(table.concat(Machines.quickMoveTargets(block, I.Rounds556), ","), "1")
		t.eq(table.concat(Machines.quickMoveTargets(block, I.LaserSight), ","), "2")
		t.eq(table.concat(Machines.quickMoveTargets(block, I.Suppressor), ","), "3")
		-- Transporters: the ammo slot through every face but Up, nothing out, never the attachments.
		for face = 0, 5 do
			local into = Transmitters.insertSlots(block, face)
			t.eq(table.concat(into, ","), if face == 1 then "" else "1", `face {face} puts into`)
			t.eq(#Transmitters.extractSlots(block, face), 0, `face {face} takes nothing out`)
			local full = { [1] = Items.newStack(I.Rounds556, 1), [2] = laser, [3] = suppressor }
			t.eq(#Transmitters.available(block, face, full), 0, `face {face} gives nothing`)
		end
		local slots, left = Transmitters.insert(block, 2, {}, Items.newStack(I.Rounds556, 40) :: any)
		t.eq(slots[1] and slots[1].count, spec.buffer, "a transporter fills it to its buffer")
		t.eq(left and left.count, 40 - spec.buffer, "the rest stays")
		local _, none = Transmitters.insert(block, 1, {}, Items.newStack(I.Rounds556, 4) :: any)
		t.eq(none and none.count, 4, "nothing through its top")
		t.eq(Transmitters.room(block, 2, {}, Items.newStack(I.LaserSight, 1) :: any), 0, "no attachment by pipe")
		t.ok(Machines.demands(block), "it demands its rounds")
		t.ok(not Machines.demands(B.ElectricFurnace) and not Machines.demands(B.Chest), "nothing else does")
	end)

	t.test("turret kind: inert without a service or with the turrets off; the simulation without targets", function()
		local spec = Turrets.of("smg", 2)
		local r = rig(spec)
		r.ctx.turret = nil
		r.load(2)
		r.tick()
		local status = r.state()
		t.eq(status, STATUS.DISABLED, "no service: Disabled")
		t.eq(Machines.energy(r.container), spec.capacity, "nothing taken")
		t.eq(r.container.data[RATE], 0)
		t.eq(r.rounds(), 2, "nothing fired")
		t.eq(Machines.status(spec.block, Machines.view(r.container)), "Disabled")
		r.ctx.turret = r.service
		Config.Turrets.Enabled = false
		local ok, err = pcall(r.tick)
		Config.Turrets.Enabled = true
		assert(ok, err)
		status = r.state()
		t.eq(status, STATUS.DISABLED, "the turrets off: Disabled")
		t.eq(r.calls, 0, "the service never asked")
		t.eq(Machines.energy(r.container), spec.capacity, "nothing taken")
		-- The simulation (server Turrets/TurretWorld; tests/spec/TurretWorld has the rest): an order
		-- for a block that is no turret is answered from the order alone, nothing kept.
		local world = TurretWorld.new({
			getBlock = function(): number?
				return nil
			end,
			hostiles = function(_into: any): number
				return 0
			end,
			mob = function(): any
				return nil
			end,
			hurt = function(): number
				return 0
			end,
			noise = function() end,
			lureTime = function(): boolean
				return false
			end,
			feed = function(): number
				return 0
			end,
			random = math.random,
			settings = TurretWorld.settings(),
		})
		local function answer(order: any): any
			return TurretWorld.step(world, order, { status = -1, fired = true, tracking = true, feed = 3 })
		end
		local base = { tick = 9, powered = true, blocked = false, armed = true, ready = true, ammo = 2 }
		local function with(changes: any): any
			local order = table.clone(base)
			for key, value in changes do
				order[key] = value
			end
			return order
		end
		for _, case in
			{
				{ {}, STATUS.NO_TARGET },
				{ { powered = false, blocked = true, ammo = 0 }, STATUS.NO_POWER },
				{ { blocked = true, ammo = 0 }, STATUS.BLOCKED },
				{ { ammo = 0, armed = false }, STATUS.NO_AMMO },
			}
		do
			local out = answer(with(case[1]))
			t.eq(out.status, case[2], Turrets.STATUS_NAMES[case[2]])
			t.ok(not out.fired and not out.tracking and out.feed == 0, "never fires, tracks or feeds")
		end
		t.eq(world.tick, 9, "it saw the tick")
		local stats = TurretWorld.stats(world)
		t.eq(stats.turrets, 0)
		t.eq(#TurretWorld.takeShots(world), 0)
		t.eq(#TurretWorld.takeRecords(world), 0)
		t.eq(#TurretWorld.chunkRecords(world, 0, 0), 0)
		-- The kind on the simulation with no hostiles about: No ammo, then No target.
		r = rig(spec)
		r.ctx.turret = function(order: any, out: any): any
			return TurretWorld.step(world, order, out)
		end
		r.tick()
		status = r.state()
		t.eq(status, STATUS.NO_AMMO, "No ammo")
		r.load(1)
		r.tick()
		status = r.state()
		t.eq(status, STATUS.NO_TARGET, "No target")
		t.eq(r.rounds(), 1, "never firing")
	end)

	t.test("turret kind: MachineWorld hands the service from its Env once a step", function()
		local spec = Turrets.of("rifle", 1)
		local blocks: { [number]: number } = {}
		local asked = 0
		local service: any = nil
		local machines = MachineWorld.new({
			getBlock = function(x: number, y: number, z: number): number?
				return blocks[Coords.posKey(x, y, z)] or AIR
			end,
			containers = Containers.new(),
			turret = function(): any
				asked += 1
				return service
			end,
		})
		local function set(x: number, y: number, z: number, block: number)
			local key = Coords.posKey(x, y, z)
			local old = blocks[key] or AIR
			blocks[key] = block
			MachineWorld.blockChanged(machines, x, y, z, old, block)
		end
		set(0, 64, 0, spec.block)
		set(1, 64, 0, spec.block)
		set(0, 63, 0, B.CreativeEnergyCube)
		MachineWorld.step(machines)
		t.eq(asked, 1, "asked once a step, not once a turret")
		local machine = MachineWorld.machine(machines, 0, 64, 0) :: any
		local status = Turrets.unpackState(Machines.get(machine.container, "state"))
		t.eq(status, STATUS.DISABLED, "none yet: Disabled")
		local orders = 0
		service = function(_order: any, out: any): any
			orders += 1
			out.status = STATUS.TARGETING
			return out
		end
		MachineWorld.step(machines)
		MachineWorld.step(machines)
		t.eq(asked, 3)
		t.eq(orders, 4, "both turrets, both steps")
		status = Turrets.unpackState(Machines.get(machine.container, "state"))
		t.eq(status, STATUS.TARGETING, "registered later, used from the next step")
		local record = MachineWorld.record(machine)
		t.eq(Turrets.unpackState(record.state), STATUS.TARGETING, "the Machines record carries the state")
	end)

	--[[ What players see ]]

	t.test("turret kind: its status and panel lines (the feed rate only with the window's data)", function()
		local spec = Turrets.of("smg", 2)
		local view = {
			block = spec.block,
			energy = 0,
			capacity = spec.capacity,
			input = 0,
			output = 0,
			rate = 0,
			active = false,
			state = Turrets.packState(STATUS.FIRING, 3, true, true),
		}
		t.eq(Machines.status(spec.block, view), "Firing")
		local lines = Machines.lines(spec.block, view)
		t.eq(table.concat(lines, "|"), "Range 20 · 150 rpm|Feed: Elite|Lure: on", "WAILA's: no feed rate")
		local data = Machines.newData(spec.block)
		data[Machines.field(spec.block, "feedRate") :: number] = 2.44
		lines = Machines.lines(spec.block, view, data)
		t.eq(table.concat(lines, "|"), "Range 20 · 150 rpm|Feed: Elite|In: 2.4/s|Lure: on", "the panel's")
		view.state = Turrets.packState(STATUS.TARGETING, 1, false, false)
		t.eq(Machines.lines(spec.block, view)[2], "Feed: Basic → 90 rpm", "a lower feeder")
		t.eq(Machines.lines(spec.block, view)[3], "Lure: off")
		view.state = Turrets.packState(STATUS.NO_TARGET, 0, true, false)
		t.eq(Machines.lines(spec.block, view)[2], "Feed: by hand")
		local info = Machines.info(spec.block)
		t.ok(
			info.range == 20 and info.rpm == 150 and info.buffer == 3 and info.idle == 8 and info.tracking == 16,
			"its info"
		)
		t.eq(info.shot, 30)
		-- The feed rate: rounds arriving, averaged.
		local rate = 0
		for _ = 1, 2000 do
			rate = TurretRules.feedRate(rate, 0.1)
		end
		t.near(rate, 2, 1e-6, "a round every 10 ticks: 2 a second")
		t.eq(TurretRules.feedRate(5, -3), 5 - 5 / Config.Turrets.FeedRateTicks, "nothing arriving decays it")
	end)

	t.test("turret kind: the panel's range is the one it engages at, with its optic (written every tick)", function()
		-- The review's: an Advanced rifle (32 blocks) with a Rifle Scope engages at 40.
		local spec = Turrets.of("rifle", 2)
		local r = rig(spec)
		r.hold = true
		r.container.slots[SLOT.OPTIC] = Items.newStack(I.RifleScope, 1)
		r.tick()
		t.eq(Machines.get(r.container, "range"), 40)
		t.eq(MenuLayout.lineTexts(r.container)[1], "Range 40 · 75 rpm", "the scoped range")
		r.container.slots[SLOT.OPTIC] = nil
		r.tick()
		t.eq(MenuLayout.lineTexts(r.container)[1], "Range 32 · 75 rpm", "taken out: its own")
		-- Every turret with each optic it takes and none: TurretRules.range, as the simulation's.
		for _, each in Turrets.SPECS do
			local optics: { number } = { 0 }
			for item in each.optics do
				table.insert(optics, item)
			end
			for _, optic in optics do
				local rigged = rig(each)
				rigged.hold = true
				rigged.container.slots[SLOT.OPTIC] = if optic ~= 0 then Items.newStack(optic, 1) else nil
				rigged.tick()
				local want = `Range {TurretRules.range(each, optic)} · {each.rpm} rpm`
				t.eq(MenuLayout.lineTexts(rigged.container)[1], want, `{each.name}, optic {optic}`)
			end
		end
		t.eq(MenuLayout.lineTexts(rig(Turrets.of("sniper", 4)).container)[1], "Range 64 · 40 rpm", "before a tick")
		-- Inert (no service) it still says what it would engage at.
		local inert = rig(Turrets.of("sniper", 4))
		inert.ctx.turret = nil
		inert.container.slots[SLOT.OPTIC] = Items.newStack(I.RifleScope, 1)
		inert.tick()
		t.eq(MenuLayout.lineTexts(inert.container)[1], "Range 80 · 40 rpm", "64 x 1.25 to MaxRange")
		-- No data, or a range from elsewhere: its own.
		local view = Machines.view(r.container)
		t.eq(Machines.lines(spec.block, view)[1], "Range 32 · 75 rpm", "no window data")
		local data = Machines.newData(spec.block)
		local index = Machines.field(spec.block, "range") :: number
		for _, bad in { 0 / 0, -1, 0, 1e9, math.huge } do
			data[index] = bad
			t.eq(Machines.lines(spec.block, view, data)[1], "Range 32 · 75 rpm", `{bad}: its own`)
		end
	end)

	t.test("panels: the turrets', the miner's and the press's slots, lines and buttons fit", function()
		local blocks = { Turrets.of("smg", 1).block, Turrets.of("sniper", 4).block, B.MetalMiner, B.AmmoPress }
		for _, block in blocks do
			local name = Blocks.get(block).name
			local container = Machines.newContainer(block)
			local panel = MenuLayout.panel(container)
			t.eq(panel.kind, "machine")
			t.eq(#panel.slots, #(Machines.kindOf(block) :: any).slots, `{name}'s slots`)
			local bar = panel.energy :: any
			t.ok(bar ~= nil, `{name}: the energy bar`)
			for _, slot in panel.slots do
				t.ok(slot.x >= 0 and slot.x + 16 <= bar.x and slot.y >= 0 and slot.y + 16 <= panel.height, "inside")
			end
			for _, button in panel.buttons do
				t.ok(button.x >= 0 and button.x + button.w <= bar.x, `{name}: {button.label} left of the energy bar`)
				t.ok(button.y >= 0 and button.y + button.h <= panel.height, "inside the panel")
				for _, line in panel.lines do
					local clear = line.y + MenuLayout.LINE_TEXT <= button.y
						or line.y >= button.y + button.h
						or line.x >= button.x + button.w
					t.ok(clear, `{name}: a line clear of {button.label}`)
				end
				for _, slot in panel.slots do
					local clear = slot.x + 16 <= button.x
						or slot.x >= button.x + button.w
						or slot.y + 16 <= button.y
						or slot.y >= button.y + button.h
					t.ok(clear, `{name}: slot {slot.slot} clear of {button.label}`)
				end
			end
			-- (The lines a kind gives: the miner's two, over its cards.)
			local shown = if block == B.MetalMiner then 2 else #panel.lines
			for i, line in panel.lines do
				for _, slot in if i <= shown then panel.slots else {} do
					local clear = line.y + MenuLayout.LINE_TEXT <= slot.y
						or line.y >= slot.y + 16
						or line.x >= slot.x + 16
						or line.x + 60 <= slot.x
					t.ok(clear, `{name}: a line clear of slot {slot.slot}`)
				end
			end
		end
		local turret = MenuLayout.panel(Machines.newContainer(Turrets.of("smg", 1).block))
		t.eq(#turret.lines, 4, "the turret's four lines")
		t.eq(#turret.buttons, 1)
		t.eq(turret.buttons[1].label, "Lure")
		for _, slot in turret.slots do
			t.ok(slot.ghost ~= nil, `slot {slot.slot}'s outline`)
		end
		-- The panel passes its window's data to the lines.
		local container = Machines.newContainer(Turrets.of("smg", 1).block)
		container.data[Machines.field(container.block, "feedRate") :: number] = 1.5
		t.ok(table.find(MenuLayout.lineTexts(container), "In: 1.5/s") ~= nil, "the feed rate")
		local press = Machines.newContainer(B.AmmoPress)
		t.eq(MenuLayout.lineTexts(press)[1], "16 9mm Rounds", "the press's calibre")
	end)

	--[[ The miner's and the press's frozen layouts ]]

	t.test("turrets: the frozen data layouts of the turrets, the miner and the press", function()
		local function fields(block: number, names: { string })
			for i, name in names do
				t.eq(Machines.field(block, name), HEADER + i, `{Blocks.get(block).name}: {name} is field {HEADER + i}`)
			end
		end
		for _, spec in Turrets.SPECS do
			fields(spec.block, { "credit", "state", "lure", "held", "feedRate", "activeDelay", "range" })
			local kind = Machines.kindOf(spec.block) :: any
			t.eq(#kind.slots, 3)
			t.eq(kind.slots[1].limit, spec.buffer)
			t.eq(kind.state, HEADER + 2, "the state")
			t.eq(table.concat(kind.keep, ","), "lure")
		end
		fields(B.MetalMiner, { "progress", "ticksRequired", "energyPerTick", "mining", "state", "activeDelay" })
		fields(B.AmmoPress, { "progress", "ticksRequired", "energyPerTick", "calibre", "state", "activeDelay" })
		-- The miner: its output, its cards, its ores in their frozen order.
		local miner = Machines.kindOf(B.MetalMiner) :: any
		t.eq(#miner.slots, 3)
		t.ok(miner.slots[1].output and miner.slots[1].big and miner.slots[1].x == 116, "the output")
		t.ok(Machines.mayPlace(B.MetalMiner, 2, I.SpeedUpgrade) and Machines.mayPlace(B.MetalMiner, 3, I.EnergyUpgrade))
		t.eq(table.concat(Machines.outputSlots(B.MetalMiner), ","), "1", "pushed out")
		local names = { "CoalOre", "IronOre", "OsmiumOre", "GoldOre", "EmeraldOre", "DiamondOre" }
		local drops = { "Coal", "RawIron", "RawOsmium", "RawGold", "Emerald", "Diamond" }
		for index, name in names do
			local ore = MinerRules.ORES[index]
			t.eq(ore.name, name, `ore {index}`)
			t.eq(ore.block, B[name])
			t.eq(ore.drop, I[drops[index]], `{name} gives {drops[index]}`)
			t.eq(MinerRules.ore(B[name]), ore)
			t.eq(ore.ticks, Config.Miner.Ores[name].ticks)
		end
		t.eq(MinerRules.ORES[1].floor, 400000, "coal's floor")
		t.eq(MinerRules.ore(B.Stone), nil)
		local view = Machines.view(Machines.newContainer(B.MetalMiner))
		local function minerStatus(code: number, index: number): string?
			view.state = MinerRules.packState(code, index)
			return Machines.status(B.MetalMiner, view)
		end
		t.eq(minerStatus(MinerRules.STATE.MINING, 6), "Mining Diamond Ore")
		t.eq(minerStatus(MinerRules.STATE.NO_POWER, 6), "No power")
		t.eq(minerStatus(MinerRules.STATE.OUTPUT_FULL, 1), "Output full")
		t.eq(minerStatus(MinerRules.STATE.NO_ORE, 0), "No ore below")
		t.eq(minerStatus(MinerRules.STATE.MINING, 0), "Idle")
		t.eq(MinerRules.packState(MinerRules.STATE.NO_ORE, 6), 3 + 8 * 6, "code + 8 x ore")
		local code, index = MinerRules.unpackState(3 + 8 * 6)
		t.ok(code == 3 and index == 6)
		t.eq(Machines.info(B.MetalMiner).DiamondOreTicks, 4800)
		t.eq(Machines.info(B.MetalMiner).capacity, 200000)
		-- The press: ingot, gunpowder, output, cards; the Calibre button kept in the item.
		local press = Machines.kindOf(B.AmmoPress) :: any
		t.eq(#press.slots, 5)
		t.ok(Machines.mayPlace(B.AmmoPress, 1, I.IronIngot) and not Machines.mayPlace(B.AmmoPress, 1, I.Gunpowder))
		t.ok(Machines.mayPlace(B.AmmoPress, 2, I.Gunpowder) and not Machines.mayPlace(B.AmmoPress, 2, I.IronIngot))
		t.ok(Machines.isOutput(B.AmmoPress, 3), "the output")
		local container = Machines.newContainer(B.AmmoPress)
		t.eq(Machines.get(container, "calibre"), 1, "9mm when fresh")
		Machines.button(container, B.AmmoPress, 0)
		t.eq(Machines.get(container, "calibre"), 2, "5.56")
		t.eq(MenuLayout.lineTexts(container)[1], "10 5.56 Rounds")
		local kept = Machines.save(container) :: any
		t.eq(kept and kept.calibre, 2, "kept in the item")
		Machines.button(container, B.AmmoPress, 0)
		Machines.button(container, B.AmmoPress, 0)
		t.eq(Machines.get(container, "calibre"), 1, "round again")
		t.eq(Machines.info(B.AmmoPress).Rounds308, 5)
		t.eq(Machines.info(B.AmmoPress).ticks, 200)
		-- The press's stub tick (builder D): state 0, nothing used. The miner's tick (builder C,
		-- tests/spec/Miner): on a diamond ore it mines at once, 800 J a tick.
		for _, block in { B.MetalMiner, B.AmmoPress } do
			local mining = block == B.MetalMiner
			local stub = Machines.newContainer(block)
			stub.data[ENERGY] = 1000
			Machines.tick(stub, {
				block = block,
				x = 0,
				y = 64,
				z = 0,
				energy = assert(Machines.energyOf(block)),
				tick = 1,
				dayTime = 6000,
				getBlock = function(): number?
					return B.DiamondOre
				end,
			})
			local state = if mining then MinerRules.packState(MinerRules.STATE.MINING, 6) else 0
			t.eq(Machines.state(stub), state, `{Blocks.get(block).name}: state {state}`)
			t.eq(Machines.energy(stub), if mining then 1000 - 800 else 1000, "the miner's 800 J, else nothing used")
			t.eq(select(1, Machines.rates(stub)), Machines.capacity(stub), "takes its capacity a tick")
		end
	end)

	--[[ The wire ]]

	t.test("turrets: the Turrets message round-trips in 19 bytes a turret; malformed ones are refused", function()
		t.eq(Protocol.ServerMessage.Turrets, 34, "after Shots")
		t.eq(Protocol.TURRET_BYTES, 19)
		local F = Protocol.TurretFlag
		t.ok(F.Powered == 1 and F.Firing == 2 and F.Blocked == 4 and F.Laser == 8, "flags")
		t.ok(F.Scope == 16 and F.Suppressor == 32 and F.Tracking == 64 and F.Dry == 128)
		t.eq(Protocol.MAX_TURRET_FLAGS, 255, "every bit a flag")
		local records = {
			{
				x = -1000,
				y = 64,
				z = 999999,
				yaw = 1.2345,
				pitch = math.rad(-40.4),
				target = 77,
				flags = 255,
				ammo = 6,
			},
			{ x = 0, y = 1023, z = 0, yaw = -2.5, pitch = math.rad(74.6), target = 0, flags = 1, ammo = 0 },
			{ x = 5, y = 0, z = -5, yaw = 0, pitch = 0, target = 4294967295, flags = 0, ammo = 255 },
		}
		local b = Protocol.encodeTurrets(records)
		t.eq(buffer.len(b), 2 + 3 * 19)
		local back = Protocol.decodeTurrets(b) :: { Protocol.TurretRecord }
		t.ok(back ~= nil and #back == 3, "three records")
		for i, record in records do
			local got = back[i]
			t.ok(got.x == record.x and got.y == record.y and got.z == record.z, `{i}: its block`)
			t.near(TurretRules.wrap(got.yaw - record.yaw), 0, math.pi / 65536 + 1e-9, `{i}: its yaw`)
			t.ok(got.yaw >= 0 and got.yaw < 2 * math.pi, "yaw in 0..2 pi")
			t.near(got.pitch, math.rad(math.round(math.deg(record.pitch))), 1e-12, `{i}: whole degrees`)
			t.ok(got.target == record.target and got.flags == record.flags and got.ammo == record.ammo, `{i}: the rest`)
		end
		t.eq(#(Protocol.decodeTurrets(Protocol.encodeTurrets({})) :: any), 0, "none")
		local cut = buffer.create(buffer.len(b) - 1)
		buffer.copy(cut, 0, b, 0, buffer.len(cut))
		t.eq(Protocol.decodeTurrets(cut), nil, "cut short")
		t.eq(Protocol.decodeTurrets(buffer.create(1)), nil, "no count")
		local nan = Protocol.decodeTurrets(Protocol.encodeTurrets({
			{ x = 1, y = 2, z = 3, yaw = 0 / 0, pitch = 0 / 0, target = 0 / 0, flags = 0 / 0, ammo = 0 / 0 },
		})) :: { Protocol.TurretRecord }
		t.ok(nan[1].yaw == 0 and nan[1].pitch == 0 and nan[1].target == 0, "NaN goes as 0")
	end)

	--[[ The decor ]]

	t.test("decor: the turrets' bases, the miner's grille and the press's window", function()
		local names = { "MetalMiner", "AmmoPress" }
		for _, spec in Turrets.SPECS do
			table.insert(names, spec.name)
		end
		for _, name in names do
			local faces = BlockDecor.faces(name) :: any
			t.ok(faces ~= nil, name)
			local parts = BlockDecor.partCount(name)
			t.ok(parts > 0 and parts < 40, `{name} item model slabs: {parts}`)
			for _, face in { "Top", "Bottom" } do
				local cells = {}
				for _, r in faces[face] do
					if not r.surfaceOnly then
						for y = r.y, r.y + r.h - 1 do
							for x = r.x, r.x + r.w - 1 do
								cells[y * 16 + x] = table.concat(r.colour, ",")
							end
						end
					end
				end
				for y = 0, 15 do
					for x = 0, 15 do
						t.eq(cells[y * 16 + x], cells[x * 16 + (15 - y)], `{name} {face} at {x},{y}`)
					end
				end
			end
		end
		for name, window in { MetalMiner = BlockDecor.MINER_WINDOW, AmmoPress = BlockDecor.PRESS_WINDOW } do
			local faces = BlockDecor.faces(name) :: any
			for _, face in { "Front", "Back", "Left", "Right" } do
				local found = false
				for _, r in faces[face] do
					if r.x == window.x and r.y == window.y and r.w == window.w and r.h == window.h then
						found = true
					end
				end
				t.ok(found, `{name} {face}: its window`)
			end
		end
		-- Each tier's colour on its base.
		for tier, tierName in TIERS do
			local faces = BlockDecor.faces(`{tierName}SmgTurret`) :: any
			t.eq(table.concat(faces.Front[5].colour, ","), table.concat(Transmitters.TIERS[tier].colour, ","))
		end
	end)

	--[[ Switched off ]]

	t.test("turrets: switched off, the game is as before: no recipes, no Ages, no demand; blocks kept", function()
		local env = Loader.new()
		local root = env.mount("src/shared", "ReplicatedStorage", "IceVoxel")
		local OffConfig = env.require(root.Config)
		OffConfig.Turrets.Enabled = false
		OffConfig.Miner.Enabled = false
		OffConfig.AmmoPress.Enabled = false
		local OffCrafting = env.require(root.Crafting)
		local OffAges = env.require(root.Progression.Ages)
		local OffMachines = env.require(root.Machines)
		local OffBlocks = env.require(root.Blocks)
		local OffItems = env.require(root.Items)
		t.eq(OffBlocks.count, 500, "the blocks stay")
		t.eq(#OffCrafting.recipes, 224, "the recipes before them")
		local results: { [number]: boolean } = {}
		for _, recipe in OffCrafting.recipes do
			results[recipe.result] = true
		end
		for _, name in { "ServoMotor", "LaserSight", "SmgBarrel", "BasicSmgTurret", "MetalMiner", "AmmoPress" } do
			t.ok(not results[OffItems.id[name]], `no recipe for {name}`)
			t.eq(OffAges.ofName(name), 1, `no Age names {name}`)
		end
		t.ok(not OffMachines.demands(OffBlocks.id.BasicSmgTurret), "no demand")
		-- The press on its own still needs servos.
		local pressEnv = Loader.new()
		local pressRoot = pressEnv.mount("src/shared", "ReplicatedStorage", "IceVoxel")
		pressEnv.require(pressRoot.Config).Turrets.Enabled = false
		local PressCrafting = pressEnv.require(pressRoot.Crafting)
		local PressItems = pressEnv.require(pressRoot.Items)
		local made: { [number]: boolean } = {}
		for _, recipe in PressCrafting.recipes do
			made[recipe.result] = true
		end
		t.ok(made[PressItems.id.ServoMotor] and made[PressItems.id.AmmoPress], "servos and the press")
		t.ok(made[PressItems.id.MetalMiner], "the miner")
		t.ok(not made[PressItems.id.BasicRifleTurret] and not made[PressItems.id.Receiver], "no turret, no part")
	end)
end
