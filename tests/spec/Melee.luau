--[[
	The melee rework (Shared/Weapons/Melee; the weapons design's section 8): the heavy attack's
	damage for every listed weapon and none for the rest, the heavy flag counting only with a
	listed weapon, exhaustion counts, knockback, the guard's share by weapon and by the front cone,
	the finisher's conditions (knives only, unaware, from behind, the health cap),
	Config.Weapons.Melee.Enabled false turning all of it off, and server Mobs/MobWorld.attack with
	heavy hits and finishers through a small fake world; Mobs/Mobs' Attack handler gating the
	client's heavy flag with Melee.heavy before anything uses it. The client's
	Interaction/MeleeInput on a fake client (tests/lib/FakeClient; stand-ins for the inventory, the
	network and the sounds): a click lands a light hit on release, a hold of HeavyHold a heavy one,
	other items hit at once, the guard sends its Weapon ops and ends with the hand's change.
]]

local fs = require("@lune/fs")
local LuneTask = require("@lune/task")
local FakeClient = require("../lib/FakeClient")

return function(t, shared, require, server)
	local Items = require(shared.Items)
	local Config = require(shared.Config)
	local Combat = require(shared.Entities.Combat)
	local Weapons = require(shared.Weapons)
	local Melee = require(shared.Weapons.Melee)
	local Blocks = require(shared.Blocks)
	local MobList = require(shared.Entities.MobList)
	local GameMode = require(shared.GameMode)
	local MobWorld = require(server.Mobs.MobWorld)

	local I = Items.id
	local settings = Config.Weapons.Melee

	-- Runs `body` with Config.Weapons.Melee's `field` set to `value`, then puts it back.
	local function with(field: string, value: any, body: () -> ())
		local old = (settings :: any)[field];
		(settings :: any)[field] = value
		local ok, err = pcall(body);
		(settings :: any)[field] = old
		if not ok then
			error(err, 0)
		end
	end

	-- The weapons design's table (3.6): light damage and speed, heavy damage, guard share, finisher.
	local TABLE = {
		{ "KitchenKnife", 4, 2.0, 7, 0.3, true },
		{ "HuntingKnife", 5, 1.8, 9, 0.35, true },
		{ "Machete", 6, 1.6, 11, 0.5, false },
		{ "BaseballBat", 5, 1.0, 10, 0.6, false },
		{ "SpikedBat", 7, 0.9, 13, 0.6, false },
		{ "Crowbar", 5, 1.2, 9, 0.6, false },
		{ "FireAxe", 9, 0.9, 16, 0.6, false },
		{ "PipeWrench", 6, 1.0, 11, 0.6, false },
		{ "Sledgehammer", 8, 0.6, 18, 0.7, false },
	}

	t.test("melee: every listed weapon's light, heavy, guard and finisher numbers", function()
		t.eq(#Weapons.MELEE, #TABLE, "nine melee weapons")
		for _, row in TABLE do
			local name, light, speed, heavy, guard, finisher = row[1], row[2], row[3], row[4], row[5], row[6]
			local item = I[name]
			local spec = Melee.spec(item) :: Weapons.MeleeSpec
			t.ok(spec ~= nil, `{name} is listed`)
			local damage, attackSpeed = Combat.attackOf(item)
			t.eq(damage, light, `{name}'s light attack`)
			t.near(attackSpeed, speed, 1e-9, `{name}'s speed`)
			t.eq(Melee.heavyDamage(item, damage), heavy, `{name}'s heavy attack`)
			t.ok(heavy >= 1.5 * light, `{name}'s heavy hit is much harder`)
			t.eq(spec.guard, guard, `{name}'s guard`)
			t.eq(spec.finisher, finisher, `{name}'s finisher`)
		end
		-- Everything else: the light attack's damage, no heavy one.
		for _, item in { I.IronSword, I.DiamondAxe, I.Stick, I.Pistol, I.Rounds9mm } do
			local base = Combat.attackOf(item)
			t.eq(Melee.spec(item), nil, `{Items.displayName(item)} is no melee weapon`)
			t.eq(Melee.heavyDamage(item, base), base, `{Items.displayName(item)}: as a light hit`)
		end
		t.eq(Melee.heavyDamage(nil, 1), 1, "the hand")
	end)

	t.test("melee: the heavy flag counts only with a listed weapon", function()
		t.eq(Melee.heavy(I.BaseballBat, true), true)
		t.eq(Melee.heavy(I.BaseballBat, false), false)
		t.eq(Melee.heavy(I.BaseballBat, nil), false)
		t.eq(Melee.heavy(I.IronSword, true), false, "a sword has no heavy attack")
		t.eq(Melee.heavy(nil, true), false, "nor the hand")
		with("Enabled", false, function()
			t.eq(Melee.heavy(I.BaseballBat, true), false, "off: never")
		end)
	end)

	t.test("melee: a press held 0.45 s with a listed weapon is a heavy attack, shorter a light one", function()
		t.eq(Melee.heavyHold(I.FireAxe, 0.45), true)
		t.eq(Melee.heavyHold(I.FireAxe, 2), true)
		t.eq(Melee.heavyHold(I.FireAxe, 0.44), false, "a click")
		t.eq(Melee.heavyHold(I.FireAxe, 0), false)
		t.eq(Melee.heavyHold(I.IronSword, 5), false, "a sword never")
		t.eq(Melee.heavyHold(nil, 5), false, "nor the hand")
		with("HeavyHold", 1, function()
			t.eq(Melee.heavyHold(I.FireAxe, 0.6), false, "a longer hold set")
		end)
		with("Enabled", false, function()
			t.eq(Melee.heavyHold(I.FireAxe, 5), false)
		end)
	end)

	t.test("melee: a heavy hit's knockback and exhaustion", function()
		t.eq(Melee.knockback(false), Combat.KNOCKBACK, "a light hit: Minecraft's")
		t.eq(Melee.knockback(true), 0.8, "a heavy one: twice")
		t.eq(Melee.knockback(true), 2 * Combat.KNOCKBACK)
		t.eq(Melee.exhaustion(false), 1)
		t.eq(Melee.exhaustion(true), 3, "three times a light hit's food")
		with("HeavyExhaustion", 2.7, function()
			t.eq(Melee.exhaustion(true), 2, "whole times")
		end)
		with("HeavyExhaustion", 0, function()
			t.eq(Melee.exhaustion(true), 1, "at least once")
		end)
	end)

	t.test("melee: the guard blocks the weapon's share of a hit from the front cone only", function()
		local bat, knife, sledge = I.BaseballBat, I.KitchenKnife, I.Sledgehammer
		-- Looking along +z; the zombie straight ahead.
		t.eq(Melee.guardShare(bat, true, 0, 1, 0, 3), 0.6)
		t.eq(Melee.guardShare(knife, true, 0, 1, 0, 3), 0.3)
		t.eq(Melee.guardShare(sledge, true, 0, 1, 0, 3), 0.7)
		-- The cone: 60 degrees either side (cosine 0.5) is in, a little more is out.
		local function at(degrees: number): (number, number)
			local r = math.rad(degrees)
			return 2 * math.sin(r), 2 * math.cos(r)
		end
		local x, z = at(59)
		t.eq(Melee.guardShare(bat, true, 0, 1, x, z), 0.6, "59 degrees")
		x, z = at(-59)
		t.eq(Melee.guardShare(bat, true, 0, 1, x, z), 0.6, "the other side")
		x, z = at(62)
		t.eq(Melee.guardShare(bat, true, 0, 1, x, z), 0, "62 degrees: past the cone")
		t.eq(Melee.guardShare(bat, true, 0, 1, 3, 0), 0, "from the side")
		t.eq(Melee.guardShare(bat, true, 0, 1, 0, -3), 0, "from behind")
		-- A look tilted up or down still counts by its horizontal part; any length.
		t.eq(Melee.guardShare(bat, true, 0, 0.2, 0, 5), 0.6)
		t.eq(Melee.guardShare(bat, true, -0.3, 0, -10, 1), 0.6, "looking along -x")
		-- No horizontal look, the zombie on top: nothing.
		t.eq(Melee.guardShare(bat, true, 0, 0, 0, 3), 0)
		t.eq(Melee.guardShare(bat, true, 0, 1, 0, 0), 0)
		-- Not guarding, or nothing to guard with.
		t.eq(Melee.guardShare(bat, false, 0, 1, 0, 3), 0)
		t.eq(Melee.guardShare(I.IronSword, true, 0, 1, 0, 3), 0, "a sword doesn't guard")
		t.eq(Melee.guardShare(nil, true, 0, 1, 0, 3), 0, "nor the hand")
		with("GuardCone", 0.9, function()
			x, z = at(30)
			t.eq(Melee.guardShare(bat, true, 0, 1, x, z), 0, "a narrower cone")
		end)
	end)

	t.test("melee: a finisher takes a knife, an unaware zombie, its back and a small one", function()
		local knife, hunting = I.KitchenKnife, I.HuntingKnife
		t.eq(Melee.finisher(knife, false, -1, 20), true, "straight behind an ordinary zombie")
		t.eq(Melee.finisher(hunting, false, -0.5, 30), true, "the cone's edge, the health cap")
		t.eq(Melee.finisher(knife, true, -1, 20), false, "it knows you are there")
		t.eq(Melee.finisher(knife, false, -0.49, 20), false, "not quite behind")
		t.eq(Melee.finisher(knife, false, 1, 20), false, "from the front")
		t.eq(Melee.finisher(knife, false, -1, 31), false, "too strong")
		t.eq(Melee.finisher(knife, false, -1, 60), false, "a brute never")
		for _, name in { "Machete", "BaseballBat", "SpikedBat", "Crowbar", "FireAxe", "PipeWrench", "Sledgehammer" } do
			t.eq(Melee.finisher(I[name], false, -1, 20), false, `{name} is no knife`)
		end
		t.eq(Melee.finisher(I.IronSword, false, -1, 20), false)
		t.eq(Melee.finisher(nil, false, -1, 20), false)
		with("FinisherMaxHealth", 60, function()
			t.eq(Melee.finisher(knife, false, -1, 60), true, "a bigger cap")
		end)
	end)

	t.test("melee: switched off, every attack is a light one as before", function()
		with("Enabled", false, function()
			for _, item in Weapons.MELEE do
				t.eq(Melee.spec(item), nil)
				t.eq(Melee.heavyDamage(item, 5), 5)
				t.eq(Melee.guardShare(item, true, 0, 1, 0, 3), 0)
				t.eq(Melee.finisher(item, false, -1, 20), false)
			end
			t.eq(Melee.knockback(true), Combat.KNOCKBACK)
			t.eq(Melee.exhaustion(true), 1)
		end)
	end)

	--[[ Through MobWorld ]]

	local FLOOR = 64
	local function getBlock(_x: number, y: number, _z: number): number?
		return if y < FLOOR then Blocks.id.Stone else Blocks.AIR
	end
	local function newWorld()
		return MobWorld.new(getBlock, {
			maxMobs = 10,
			forgetTicks = 6000,
			random = function(): number
				return 0.5
			end,
		})
	end
	-- A survival player at (x, z) swinging `item`, fully recovered.
	local function attacker(x: number, z: number, item: number, heavy: boolean): MobWorld.Attacker
		return {
			key = "p",
			x = x,
			y = FLOOR,
			z = z,
			eye = 1.62,
			mode = GameMode.SURVIVAL,
			alive = true,
			item = item,
			ticks = 100,
			heavy = heavy,
		}
	end
	-- The horizontal speed of a mob (its knockback).
	local function speed(world, id: number): number
		local body = (world:get(id) :: any).body
		return math.sqrt(body.vx * body.vx + body.vz * body.vz)
	end

	t.test("melee: MobWorld lands a heavy hit twice as hard, with twice the knockback", function()
		local world = newWorld()
		local zombie = MobList.find("Zombie") :: number
		local light = world:spawn(zombie, 2.5, FLOOR, 0.5)
		local heavy = world:spawn(zombie, 2.5, FLOOR, 8.5)
		local lightLanded = world:attack(light, attacker(0.5, 0.5, I.BaseballBat, false)) :: number
		local heavyLanded = world:attack(heavy, attacker(0.5, 8.5, I.BaseballBat, true)) :: number
		t.ok(lightLanded > 0, "a light hit lands")
		t.near(heavyLanded, 2 * lightLanded, 1e-6, "10 against 5, through the same armour")
		t.near(speed(world, heavy), 2 * speed(world, light), 1e-6, "0.8 against 0.4")
		-- A heavy flag with a sword: MobWorld takes the sword's own damage.
		local sword = world:spawn(zombie, 2.5, FLOOR, 4.5)
		local swordLight = world:spawn(zombie, -1.5, FLOOR, 4.5)
		local swordHeavy = world:attack(sword, attacker(0.5, 4.5, I.IronSword, true)) :: number
		local swordPlain = world:attack(swordLight, attacker(0.5, 4.5, I.IronSword, false)) :: number
		t.near(swordHeavy, swordPlain, 1e-6, "no heavy damage without a listed weapon")
	end)

	t.test("melee: the server's Attack counts the heavy flag only with a listed weapon in hand", function()
		-- Mobs/Mobs' Attack handler (Roblox glue, read as text): the flag the client sent goes
		-- through Melee.heavy with the held item before the Attacker and the exhaustion see it.
		local source = fs.readFile("src/server/Mobs/Mobs.luau")
		local start = string.find(source, "local function onAttack(", 1, true) :: number
		t.ok(start ~= nil, "the Attack handler")
		local stop = string.find(source, "\nend\n", start, true) :: number
		local body = string.sub(source, start, stop)
		local gate = string.find(body, "heavy = Melee.heavy(held, heavy)", 1, true)
		local attack = string.find(body, "mobs:attack(", 1, true)
		local food = string.find(body, "Melee.exhaustion(heavy)", 1, true)
		t.ok(gate ~= nil and attack ~= nil and food ~= nil, "gate, attack and exhaustion in the handler")
		t.ok((gate :: number) < (attack :: number), "gated before the Attacker is built")
		t.ok((gate :: number) < (food :: number), "and before the food it costs")
		-- What the gate makes of a sword's flag: a light hit's knockback and food.
		local world = newWorld()
		local zombie = MobList.find("Zombie") :: number
		local swung = world:spawn(zombie, 2.5, FLOOR, 0.5)
		local plain = world:spawn(zombie, 2.5, FLOOR, 8.5)
		world:attack(swung, attacker(0.5, 0.5, I.IronSword, Melee.heavy(I.IronSword, true)))
		world:attack(plain, attacker(0.5, 8.5, I.IronSword, false))
		t.near(speed(world, swung), speed(world, plain), 1e-9, "a sword's flag: Minecraft's knockback")
		t.eq(Melee.exhaustion(Melee.heavy(I.IronSword, true)), 1, "and a light hit's food")
		t.eq(Melee.exhaustion(Melee.heavy(I.BaseballBat, true)), 3, "a bat's heavy hit costs three")
	end)

	t.test("melee: MobWorld's finisher kills an unaware small zombie from behind with a knife", function()
		local world = newWorld()
		local zombie = MobList.find("Zombie") :: number
		local brute = MobList.find("ZombieBrute") :: number
		-- Facing +x (yaw pi/2: facing is (sin yaw, cos yaw)); the attacker at its back, at -x.
		local function spawnFacing(kind: number, z: number, yaw: number): number
			local id = world:spawn(kind, 2.5, FLOOR, z)
			local mob = world:get(id) :: any
			mob.body.yaw = yaw
			mob.ai.target = nil
			mob.ai.hunt = nil
			return id
		end
		local back = spawnFacing(zombie, 0.5, math.pi / 2)
		local landed = world:attack(back, attacker(0.5, 0.5, I.KitchenKnife, false)) :: number
		t.ok(landed >= 20, "its whole health and more")
		local dead = world:get(back) :: any
		t.ok(dead == nil or dead.dead or dead.health <= 0, "dead")
		-- From the front: an ordinary knife hit.
		local front = spawnFacing(zombie, 4.5, -math.pi / 2)
		local stab = world:attack(front, attacker(0.5, 4.5, I.KitchenKnife, false)) :: number
		t.ok(stab > 0 and stab < 20, "a stab, not a kill")
		t.ok(not (world:get(front) :: any).dead)
		-- Aware of someone: no finisher.
		local aware = spawnFacing(zombie, 8.5, math.pi / 2);
		(world:get(aware) :: any).ai.target = "someone"
		local noticed = world:attack(aware, attacker(0.5, 8.5, I.KitchenKnife, false)) :: number
		t.ok(noticed > 0 and noticed < 20, "it noticed: a stab")
		-- A brute is too strong, a bat no knife.
		local big = spawnFacing(brute, 12.5, math.pi / 2)
		local cut = world:attack(big, attacker(0.5, 12.5, I.HuntingKnife, false)) :: number
		t.ok(cut > 0 and cut < 60, "a brute only bleeds")
		local batted = spawnFacing(zombie, 16.5, math.pi / 2)
		local bat = world:attack(batted, attacker(0.5, 16.5, I.BaseballBat, false)) :: number
		t.ok(bat > 0 and bat < 20, "a bat from behind is a bat")
		-- Off: no finisher.
		with("Enabled", false, function()
			local off = spawnFacing(zombie, 20.5, math.pi / 2)
			local poke = world:attack(off, attacker(0.5, 20.5, I.KitchenKnife, false)) :: number
			t.ok(poke > 0 and poke < 20, "the rework off: a plain hit")
		end)
	end)

	--[[ The client's input ]]

	t.test("melee input: light on release, heavy after a hold, others at once, the guard's ops", function()
		local Protocol = require(shared.Net.Protocol)
		local WeaponSync = require(shared.Net.WeaponSync)
		local bat: Items.Stack = { item = I.BaseballBat, count = 1 }
		local held: Items.Stack? = bat
		local selected = 1
		local ops: { number } = {}
		local sounds: { string } = {}
		local heartbeat = FakeClient.signal()
		local load = FakeClient.loader(shared, require, {
			["src/client/Inventory/ClientInventory.luau"] = {
				selectedStack = function()
					return held
				end,
				selected = function()
					return selected
				end,
			},
			["src/client/Net/ClientNet.luau"] = {
				send = function(kind: number, payload: buffer)
					t.eq(kind, Protocol.ClientMessage.Weapon, "only Weapon messages")
					table.insert(ops, WeaponSync.decodeWeapon(payload) :: number)
				end,
			},
			["src/client/Audio/SoundPlayer.luau"] = {
				playFlat = function(name: string): boolean
					table.insert(sounds, name)
					return true
				end,
			},
			["src/client/Entities/MobRenderer.luau"] = {},
		}, { RunService = { Heartbeat = heartbeat } })
		local MeleeInput = load("src/client/Interaction/MeleeInput.luau")
		MeleeInput.start()
		local hits: { { id: number, heavy: boolean } } = {}
		local function attack(mob: any, heavy: boolean?)
			table.insert(hits, { id = mob.id, heavy = heavy == true })
		end
		local zombie, other = { id = 7 }, { id = 8 }
		-- A click: nothing on the press, a light hit at the mob in reach on the release.
		MeleeInput.press("mouse", zombie, held, attack)
		t.eq(#hits, 0, "nothing on the press")
		MeleeInput.release("mouse", other, attack)
		t.eq(#hits, 1)
		t.eq(hits[1].id, 8, "the mob in reach at the release")
		t.eq(hits[1].heavy, false)
		t.eq(sounds[1], "item.melee.swing")
		-- Released with nothing in reach: a miss. Another source's release is not this press's.
		MeleeInput.press("mouse", zombie, held, attack)
		MeleeInput.release("mouse", nil, attack)
		t.eq(#hits, 1, "a miss sends nothing")
		MeleeInput.press("mouse", zombie, held, attack)
		MeleeInput.press("gamepad", zombie, held, attack)
		MeleeInput.release("gamepad", zombie, attack)
		t.eq(#hits, 1, "one press at a time")
		MeleeInput.release("mouse", zombie, attack)
		t.eq(#hits, 2)
		-- A sword (and the hand) hits at once on the press, as before.
		MeleeInput.press("mouse", zombie, { item = I.IronSword, count = 1 }, attack)
		MeleeInput.press("mouse", zombie, nil, attack)
		t.eq(#hits, 4, "at once")
		t.ok(not hits[3].heavy and not hits[4].heavy)
		MeleeInput.release("mouse", zombie, attack)
		t.eq(#hits, 4, "nothing on their release")
		-- Held HeavyHold: heavy.
		MeleeInput.press("mouse", zombie, held, attack)
		t.ok(MeleeInput.charge() < 1, "winding up")
		LuneTask.wait(settings.HeavyHold + 0.05)
		t.eq(MeleeInput.charge(), 1, "wound up")
		MeleeInput.release("mouse", zombie, attack)
		t.eq(#hits, 5)
		t.eq(hits[5].heavy, true, "a heavy attack")
		t.eq(sounds[#sounds], "item.melee.heavy")
		t.eq(MeleeInput.charge(), 0)
		-- Another slot drops a held press.
		MeleeInput.press("mouse", zombie, held, attack)
		selected = 2
		heartbeat:Fire(1 / 60)
		selected = 1
		MeleeInput.release("mouse", zombie, attack)
		t.eq(#hits, 5, "dropped with the slot change")
		-- The guard: its op, no attacks while it lasts, its own source's release ends it.
		t.eq(MeleeInput.guardPress("mouse"), true)
		t.eq(MeleeInput.guarding(), true)
		t.eq(ops[#ops], WeaponSync.Op.Guard)
		MeleeInput.press("mouse", zombie, held, attack)
		MeleeInput.release("mouse", zombie, attack)
		t.eq(#hits, 5, "no attack while guarding")
		t.eq(MeleeInput.guardPress("gamepad"), true, "taken: already guarding")
		MeleeInput.guardRelease("gamepad")
		t.eq(MeleeInput.guarding(), true, "another source's release")
		MeleeInput.guardRelease("mouse")
		t.eq(MeleeInput.guarding(), false)
		t.eq(ops[#ops], WeaponSync.Op.Unguard)
		t.eq(#ops, 2, "one Guard, one Unguard")
		-- Putting the weapon away ends the guard.
		MeleeInput.guardPress("mouse")
		held = { item = I.Stone, count = 64 }
		heartbeat:Fire(1 / 60)
		t.eq(MeleeInput.guarding(), false)
		t.eq(ops[#ops], WeaponSync.Op.Unguard)
		-- Nothing to guard with; the rework off: no guard, and a bat hits at once.
		t.eq(MeleeInput.guardPress("mouse"), false, "stone doesn't guard")
		held = bat
		with("Enabled", false, function()
			t.eq(MeleeInput.guardPress("mouse"), false, "off")
			MeleeInput.press("mouse", zombie, held, attack)
			t.eq(#hits, 6, "off: at once")
			t.eq(hits[6].heavy, false)
		end)
		t.eq(#ops, 4, "nothing more sent")
	end)
end
