--[[
	Mana and magic (Terraria's, Config.Mana): the numbers (20 to start, 20 a Mana Crystal up to 200,
	400 at most), Mana Sickness (effect 25), the items (Fallen Stars, Mana Crystals, the mana potions
	and the magic weapons with their costs), the sounds, and the messages (Net/MagicSync: held
	uses, the mana status, projectiles; malformed ones refused). Shared/Mana: the capacity
	(crystals, a Band of Starpower, the cap), Terraria 1.4.4's regeneration table run at 20 Hz
	(standing and moving, full and empty, max 20 and 200; the delay after spending, 0.525 s to
	3.325 s), spending and adding, the full chime, Mana Sickness's stacking and damage cut, the
	mana potions; Mana/StarFall: the night, the chance, the ring, the landing column and simulated
	nights' stars; client Ui/ManaStars: the HUD's stars, rows and when they show.
]]

return function(t, shared, require, _server, client)
	local Config = require(shared.Config)
	local Effects = require(shared.Effects)
	local Items = require(shared.Items)
	local MagicSync = require(shared.Net.MagicSync)
	local Protocol = require(shared.Net.Protocol)
	local Sounds = require(shared.Sounds)
	local Blocks = require(shared.Blocks)
	local Mana = require(shared.Mana)
	local StarFall = require(shared.Mana.StarFall)
	local Drinks = require(shared.ToughAsNails.Drinks)
	local Types = require(shared.Inventory.Types)
	local Hash = require(shared.Util.Hash)
	local ManaStars = require(client.Ui.ManaStars)

	local id = Items.id

	t.test("mana: Terraria's numbers, Mana Sickness and the items", function()
		t.eq(Config.Mana.Base, 20)
		t.eq(Config.Mana.Base + Config.Mana.PerCrystal * Config.Mana.MaxCrystals, 200, "nine crystals: 200")
		t.eq(Config.Mana.Max, 400)
		local sickness = Effects.get(Effects.id.ManaSickness) :: Effects.Effect
		t.eq(sickness.id, 25)
		t.eq(sickness.category, "harmful")
		t.eq(sickness.displayName, "Mana Sickness")
		t.eq(Effects.find("mana_sickness"), sickness.id)
		t.eq(Config.Mana.SicknessSeconds * 2, Config.Mana.SicknessMax, "two potions reach the most")
		local spark = Items.magic(id.WandOfSparking) :: Items.MagicSpec
		local staff = Items.magic(id.EmeraldStaff) :: Items.MagicSpec
		local water = Items.magic(id.WaterBolt) :: Items.MagicSpec
		t.eq(spark.mana, 2)
		t.eq(spark.fire, 0.5)
		t.eq(staff.mana, 6)
		t.eq(staff.projectile, "bolt")
		t.eq(water.mana, 10)
		t.eq(water.projectile, "water")
		for _, magic in { spark, staff, water } do
			t.ok(magic.useTicks >= 1 and magic.damage > 0)
		end
		t.eq(Items.magic(id.Stick), nil)
		t.ok(Items.get(id.FallenStar) ~= nil and Items.get(id.ManaCrystal) ~= nil)
		for _, name in
			{
				"entity.player.double_jump",
				"item.mana_crystal.use",
				"item.magic.cast",
				"entity.magic.hit",
				"entity.fallen_star.fall",
				"entity.player.mana_full",
			}
		do
			t.ok(Sounds.find(name) ~= nil, `the sound {name}`)
		end
	end)

	t.test("mana: held uses and the mana status round trip; malformed ones are refused", function()
		t.eq(Protocol.ClientMessage.HeldUse, 26)
		t.eq(Protocol.ServerMessage.Mana, 30)
		t.eq(Protocol.ServerMessage.Projectiles, 31)
		local use = MagicSync.decodeHeldUse(MagicSync.encodeHeldUse({
			seq = 65537,
			slot = 3,
			item = id.WandOfSparking,
			dx = 0.6,
			dy = 0,
			dz = -0.8,
		})) :: MagicSync.HeldUse
		t.eq(use.seq, 1, "wraps")
		t.eq(use.slot, 3)
		t.eq(use.item, id.WandOfSparking)
		t.near(use.dz, -0.8, 1e-6)
		local function bad(change: (buffer) -> ()): MagicSync.HeldUse?
			local b = MagicSync.encodeHeldUse({ seq = 1, slot = 1, item = 1, dx = 1, dy = 0, dz = 0 })
			change(b)
			return MagicSync.decodeHeldUse(b)
		end
		t.eq(
			bad(function(b)
				buffer.writeu8(b, 2, 10)
			end),
			nil,
			"slot 10"
		)
		t.eq(
			bad(function(b)
				buffer.writef32(b, 5, 0 / 0)
			end),
			nil,
			"NaN"
		)
		t.eq(
			bad(function(b)
				buffer.writef32(b, 5, 5)
			end),
			nil,
			"not a unit vector"
		)
		t.eq(MagicSync.decodeHeldUse(buffer.create(3)), nil)
		local status = MagicSync.decodeMana(
			MagicSync.encodeMana({ mana = 37.9, max = 60, refused = true, full = false })
		) :: MagicSync.ManaStatus
		t.eq(status.mana, 37, "whole mana")
		t.eq(status.max, 60)
		t.eq(status.refused, true)
		t.eq(status.full, false)
		local over = MagicSync.encodeMana({ mana = 10, max = 20, refused = false, full = true })
		buffer.writeu16(over, 0, 30)
		t.eq(MagicSync.decodeMana(over), nil, "mana above the max")
	end)

	t.test("mana: projectile ops round trip; malformed ones are refused", function()
		local ops: { MagicSync.ProjectileOp } = {
			{
				op = "spawn",
				id = 9,
				kind = 2,
				owner = -1,
				seq = 70000,
				x = 1000.5,
				y = 64.25,
				z = -2000.75,
				vx = 1.5,
				vy = 0,
				vz = -0.5,
			},
			{ op = "sync", id = 9, x = 1001, y = 64, z = -2001, vx = -1.5, vy = 0.1, vz = 0 },
			{ op = "end", id = 9, x = 1010, y = 63, z = -2001, reason = MagicSync.Reason.Mob },
		}
		local back = MagicSync.decodeProjectiles(MagicSync.encodeProjectiles(ops), 3) :: { MagicSync.ProjectileOp }
		t.eq(#back, 3)
		t.eq(back[1].op, "spawn")
		t.eq(back[1].kind, 2)
		t.eq(back[1].owner, -1, "Studio's negative test users")
		t.eq(back[1].seq, 70000 % 65536)
		t.near(back[1].x, 1000.5, 1e-3)
		t.near(back[1].vz :: number, -0.5, 1e-6)
		t.eq(back[2].op, "sync")
		t.near(back[2].vy :: number, 0.1, 1e-6)
		t.eq(back[3].op, "end")
		t.eq(back[3].reason, MagicSync.Reason.Mob)
		t.eq(#(MagicSync.decodeProjectiles(MagicSync.encodeProjectiles({}), 3) :: any), 0)
		t.eq(MagicSync.decodeProjectiles(MagicSync.encodeProjectiles(ops), 1), nil, "kind 2 of 1")
		local fast = table.clone(ops[2])
		fast.vx = MagicSync.MAX_SPEED + 1
		t.eq(MagicSync.decodeProjectiles(MagicSync.encodeProjectiles({ fast }), 3), nil, "too fast")
		local far = table.clone(ops[3])
		far.x = Protocol.MAX_COORDINATE * 2
		t.eq(MagicSync.decodeProjectiles(MagicSync.encodeProjectiles({ far }), 3), nil, "too far")
		local reason = table.clone(ops[3])
		reason.reason = 7
		t.eq(MagicSync.decodeProjectiles(MagicSync.encodeProjectiles({ reason }), 3), nil, "an unknown reason")
		local bytes = MagicSync.encodeProjectiles(ops)
		local longer = buffer.create(buffer.len(bytes) + 1)
		buffer.copy(longer, 0, bytes)
		t.eq(MagicSync.decodeProjectiles(longer, 3), nil, "bytes left over")
		local short = buffer.create(buffer.len(bytes) - 1)
		buffer.copy(short, 0, bytes, 0, buffer.len(short))
		t.eq(MagicSync.decodeProjectiles(short, 3), nil, "cut short")
		local op = buffer.create(buffer.len(bytes))
		buffer.copy(op, 0, bytes)
		buffer.writeu8(op, 2, 9)
		t.eq(MagicSync.decodeProjectiles(op, 3), nil, "an unknown op")
	end)

	--[[ Shared/Mana ]]

	-- Mana a second gained over one tick from `mana` of `max` (no delay).
	local function measured(mana: number, max: number, still: boolean): number
		local state = { mana = mana, delay = 0 }
		Mana.tick(state, max, still)
		return (state.mana - mana) * 20
	end

	t.test("mana: the capacity (crystals, a Band of Starpower, the cap)", function()
		t.eq(Mana.capacity(0), 20, "a new character")
		t.eq(Mana.capacity(4), 100)
		t.eq(Mana.capacity(9), 200, "nine crystals")
		t.eq(Mana.capacity(12), 200, "never more than nine count")
		t.eq(Mana.capacity(-3), 20)
		t.eq(Mana.capacity(9, 20), 220, "a Band of Starpower on top")
		t.eq(Mana.capacity(9, 1000), Config.Mana.Max, "400 at most")
		t.ok(Mana.canUseCrystal(8) and not Mana.canUseCrystal(9), "a crystal while fewer than nine")
		local inventory = Types.newInventory()
		inventory.accessorySlots = 5
		t.eq(Mana.maxOf(3, inventory), 80, "nothing worn")
		inventory.accessories[2] = { item = id.BandOfStarpower, count = 1 }
		t.eq(Mana.maxOf(3, inventory), 100, "the band's 20")
		inventory.accessories[4] = { item = id.BandOfStarpower, count = 1 }
		t.eq(Mana.maxOf(3, inventory), 100, "a second band counts once (Terraria wears one)")
		inventory.accessorySlots = 1
		t.eq(Mana.maxOf(3, inventory), 80, "in a slot that isn't open it does nothing")
		t.eq(Mana.maxOf(3, nil), 80)
		t.eq(Mana.stars(20), 1)
		t.eq(Mana.stars(200), 10)
		t.eq(Mana.stars(210), 11, "a part star is a star")
		t.eq(Mana.stars(400), 20)
	end)

	t.test("mana: Terraria 1.4.4's regeneration, a second (max 20 and 200)", function()
		local rows = {
			{ max = 20, stillFull = 7.47, stillEmpty = 1.49, movingFull = 1.72, movingEmpty = 0.35 },
			{ max = 200, stillFull = 74.2, stillEmpty = 14.8, movingFull = 16.7, movingEmpty = 3.33 },
		}
		for _, row in rows do
			local max = row.max
			t.near(Mana.rate(max, max, true), row.stillFull, 0.05, `max {max} standing, full`)
			t.near(Mana.rate(0, max, true), row.stillEmpty, 0.05, `max {max} standing, empty`)
			t.near(Mana.rate(max, max, false), row.movingFull, 0.05, `max {max} moving, full`)
			t.near(Mana.rate(0, max, false), row.movingEmpty, 0.05, `max {max} moving, empty`)
			-- The ticks give the same (a tick from empty, and one at 90%, measured: within 2%, as
			-- mana rising in the tick quickens it a little).
			t.near(measured(0, max, true), row.stillEmpty, row.stillEmpty * 0.02, `max {max}: a tick standing at empty`)
			t.near(
				measured(0, max, false),
				row.movingEmpty,
				row.movingEmpty * 0.02,
				`max {max}: a tick moving at empty`
			)
			t.near(measured(max * 0.9, max, false), Mana.rate(max * 0.9, max, false), 0.05, "a tick at 90%")
		end
		-- Floats: a max of 20 moving from empty still comes back (Terraria's whole numbers would
		-- round a step's 0.69 / 120 away into its counter, slowly).
		local state = { mana = 0, delay = 0 }
		for _ = 1, 20 do
			Mana.tick(state, 20, false)
		end
		t.ok(state.mana > 0.3, `a second from empty: {state.mana}`)
	end)

	t.test("mana: the delay after spending (0.525 s full, 3.325 s empty, half standing)", function()
		t.near(Mana.delayFor(20, 20) / 60, 0.525, 1e-9, "full")
		t.near(Mana.delayFor(0, 20) / 60, 3.325, 1e-9, "empty")
		t.near(Mana.delayFor(100, 200) / 60, 0.7 * (45 + 120) / 60, 1e-9, "half")
		-- Seconds until mana comes back after spending `amount` at `mana` of `max`.
		local function wait(mana: number, max: number, amount: number, still: boolean): number
			local state = { mana = mana, delay = 0 }
			assert(Mana.spend(state, max, amount))
			local spent = state.mana
			for tick = 1, 400 do
				Mana.tick(state, max, still)
				if state.mana > spent then
					return tick / 20
				end
			end
			return math.huge
		end
		t.near(wait(20, 20, 2, false), 0.525, 0.05, "spent at full")
		t.near(wait(2, 20, 2, false), 0.7 * (45 + 240 * 0.9) / 60, 0.05, "spent at 2 of 20 (the mana before)")
		t.near(wait(20, 20, 2, true), 0.525 / 2, 0.05, "standing still counts it down twice as fast")
		t.near(wait(200, 200, 200, false), 0.525, 0.05, "the mana before the spend sets it")
	end)

	t.test("mana: spending, adding, clamping and the full chime", function()
		local state = Mana.new(20)
		t.eq(state.mana, 20)
		t.ok(Mana.spend(state, 20, 6), "6 of 20")
		t.eq(state.mana, 14)
		t.ok(state.delay > 0)
		t.ok(not Mana.spend(state, 20, 15), "not more than there is")
		t.eq(state.mana, 14, "nothing taken")
		t.ok(not Mana.spend(state, 20, 0 / 0), "NaN")
		t.ok(Mana.spend(state, 20, 0), "nothing costs nothing")
		t.eq(Mana.add(state, 20, 50), 6, "a potion fills to the max")
		t.eq(state.mana, 20)
		t.eq(Mana.add(state, 20, 5), 0, "full")
		state.mana = 80
		Mana.clamp(state, 60)
		t.eq(state.mana, 60, "a band taken off: down to the new max")
		-- Regeneration filling it says so once.
		state = { mana = 19.99, delay = 0 }
		t.ok(Mana.tick(state, 20, false), "filled")
		t.eq(state.mana, 20)
		t.ok(not Mana.tick(state, 20, false), "already full")
		state = { mana = 10, delay = 500 }
		t.ok(not Mana.tick(state, 20, true), "waiting")
		t.eq(state.mana, 10, "nothing during the delay")
		t.near(state.delay, 494, 1e-9, "standing still: 2 a step, 3 steps a tick")
	end)

	t.test("mana: Mana Sickness (5 s a potion up to 10 s) and the damage cut", function()
		t.eq(Mana.sicknessTicks(0), 100, "one potion: 5 s")
		t.eq(Mana.sicknessTicks(100), 200, "two: 10 s")
		t.eq(Mana.sicknessTicks(150), 200, "never past 10 s")
		t.eq(Mana.sicknessTicks(-5), 100)
		t.eq(Mana.damageFactor(0), 1)
		t.near(Mana.damageFactor(100), 0.75, 1e-9, "5 s left: 25% less")
		t.near(Mana.damageFactor(200), 0.5, 1e-9, "10 s left: half")
		t.near(Mana.damageFactor(10), 0.975, 1e-9, "half a second: 2.5%")
	end)

	t.test("mana: the mana potions (Drinks: 50 and 100, any time, the bottle back)", function()
		local lesser, potion = Drinks.of(id.LesserManaPotion), Drinks.of(id.ManaPotion)
		t.eq(Drinks.manaOf(lesser), 50)
		t.eq(Drinks.manaOf(potion), 100)
		t.eq(Drinks.manaOf(Drinks.of(id.PurifiedWaterBottle)), 0)
		t.eq(Drinks.emptyOf(id.LesserManaPotion), id.GlassBottle)
		t.eq(Drinks.emptyOf(id.ManaPotion), id.GlassBottle)
		for _, drink in { lesser, potion } do
			t.ok(Drinks.isPotion(drink), "a potion")
			t.ok(Drinks.drinkable(drink, false, false, false), "drunk with Tough As Nails off")
			t.ok(Drinks.drinkable(drink, false, true, true), "and not thirsty")
			t.eq((drink :: Drinks.Drink).thirst, 0, "no water")
		end
		t.ok(not Drinks.isPotion(Drinks.of(id.PurifiedWaterBottle)), "water is no potion")
		t.eq(Items.maxStack(id.LesserManaPotion), 16)
		local held, give = Drinks.afterDrinking({ item = id.ManaPotion, count = 3 }, false)
		t.eq(held and held.count, 2)
		t.eq(give and give.item, id.GlassBottle)
	end)

	--[[ Fallen Stars (Mana/StarFall) ]]

	t.test("mana: Fallen Stars fall at night, about five a player", function()
		local stars = Config.Mana.Stars
		t.ok(not StarFall.isNight(6000) and StarFall.isNight(13000) and StarFall.isNight(18000))
		t.ok(not StarFall.isNight(23000), "dawn")
		t.ok(StarFall.isNight(24000 * 3 + 14000), "any day")
		t.ok(StarFall.dawned(22990, 23010), "the clock passing dawn")
		t.ok(StarFall.dawned(18000, 1000), "/time set day")
		t.ok(not StarFall.dawned(1000, 6000) and not StarFall.dawned(12990, 13010))
		t.near(StarFall.nightSeconds(Config.Time.DayLength), 500, 1e-9, "a 20-minute day's night")
		t.near(StarFall.chance(1200), stars.PerNight / 500, 1e-12)
		t.near(StarFall.chance(600), stars.PerNight / 250, 1e-12, "a shorter day, the same count")
		-- Simulated nights: a second's roll each, as Players/FallenStars does.
		local random = Hash.rng(1234)
		local chance = StarFall.chance(1200)
		local total, nights, inRange = 0, 200, 0
		for _ = 1, nights do
			local count = 0
			for _ = 1, 500 do
				if random:float() < chance then
					count += 1
				end
			end
			total += count
			if count >= 3 and count <= 8 then
				inRange += 1
			end
		end
		t.near(total / nights, stars.PerNight, 0.5, "five a night on average")
		t.ok(inRange / nights > 0.7, `most nights 3..8 ({inRange} of {nights})`)
		-- The ring.
		local rolls = Hash.rng(7)
		for _ = 1, 200 do
			local x, z = StarFall.pick(function()
				return rolls:float()
			end, 100.3, -40.7)
			local d = math.sqrt((x - 100.3) ^ 2 + (z + 40.7) ^ 2)
			t.ok(d >= stars.MinDistance - 1.5 and d <= stars.MaxDistance + 1.5, `on the ring: {d}`)
			t.eq(x % 1, 0.5, "a column's centre")
		end
	end)

	t.test("mana: a star lands on the column's top, never where the world isn't generated", function()
		local column: { [number]: number } = { [0] = Blocks.id.Stone, [1] = Blocks.id.Stone, [2] = Blocks.id.Dirt }
		local function getBlock(_x: number, y: number, _z: number): number?
			return column[y] or Blocks.AIR
		end
		t.eq(StarFall.topY(getBlock, 3.5, 4.5, 63), 2, "the dirt on top")
		column[9] = Blocks.CAVE_AIR
		t.eq(StarFall.topY(getBlock, 3.5, 4.5, 63), 2, "cave air is air")
		column[20] = Blocks.id.OakLeaves
		t.eq(StarFall.topY(getBlock, 3.5, 4.5, 63), 20, "a tree's top")
		t.eq(StarFall.spawnY(20), 20 + 1 + Config.Mana.Stars.FallHeight, "FallHeight above it")
		t.eq(
			StarFall.topY(function()
				return nil
			end, 0, 0, 63),
			nil,
			"not generated"
		)
		t.eq(
			StarFall.topY(function()
				return Blocks.AIR
			end, 0, 0, 63),
			nil,
			"the void"
		)
	end)

	--[[ The HUD's stars (client Ui/ManaStars) ]]

	t.test("mana: the HUD's stars (halves, rows going up, when they show)", function()
		t.eq(ManaStars.state(20, 1), 2, "full")
		t.eq(ManaStars.state(19, 1), 1, "a part: half")
		t.eq(ManaStars.state(1, 1), 1)
		t.eq(ManaStars.state(0, 1), 0, "empty")
		t.eq(ManaStars.state(39, 2), 1)
		t.eq(ManaStars.state(20, 2), 0)
		t.eq(ManaStars.state(400, 20), 2)
		-- Ten a row, 8 px apart, rows 10 px up from the bottom one.
		t.eq(ManaStars.rows(20), 1)
		t.eq(ManaStars.rows(200), 1)
		t.eq(ManaStars.rows(220), 2)
		t.eq(ManaStars.rows(400), 2)
		local x, y = ManaStars.position(1)
		t.eq(x, 0)
		t.eq(y, 0)
		x, y = ManaStars.position(10)
		t.eq(x, 72)
		t.eq(y, 0)
		x, y = ManaStars.position(11)
		t.eq(x, 0)
		t.eq(y, -10, "the second row above")
		-- Where the bottom row goes and how far the name and the status row move up.
		local bottom, raise = ManaStars.layout(21, 200, false)
		t.eq(bottom, 21, "in the armor's row when no armor shows")
		t.eq(raise, 0, "the name's row stays clear")
		bottom, raise = ManaStars.layout(21, 200, true)
		t.eq(bottom, 11, "above the armor")
		t.eq(raise, 10, "the name moves up a row")
		bottom, raise = ManaStars.layout(21, 400, false)
		t.eq(bottom, 21)
		t.eq(raise, 10, "two rows reach the name's row")
		bottom, raise = ManaStars.layout(21, 400, true)
		t.eq(bottom, 11)
		t.eq(raise, 20)
		-- When they show: survival-like modes, with a magic item, mana missing, or just changed.
		local linger = Config.Mana.HudLinger
		t.ok(ManaStars.shown(true, true, 20, 20, math.huge), "a wand in hand")
		t.ok(ManaStars.shown(true, false, 19, 20, math.huge), "mana missing")
		t.ok(ManaStars.shown(true, false, 20, 20, linger - 0.1), "just filled")
		t.ok(not ManaStars.shown(true, false, 20, 20, linger + 0.1), "full and put away")
		t.ok(not ManaStars.shown(false, true, 5, 20, 0), "creative and spectators: never")
		t.ok(not ManaStars.shown(true, true, 0, 0, 0), "no mana at all (Config.Mana off)")
	end)
end
