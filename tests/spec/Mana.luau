--[[
	Mana and magic (Terraria's, Config.Mana): the numbers (20 to start, 20 a Mana Crystal up to 200,
	400 at most), Mana Sickness (effect 25), the items (Fallen Stars, Mana Crystals, the mana potions
	and the magic weapons with their costs), the sounds, and the messages (Net/MagicSync: held
	uses, the mana status, projectiles; malformed ones refused).
]]

return function(t, shared, require)
	local Config = require(shared.Config)
	local Effects = require(shared.Effects)
	local Items = require(shared.Items)
	local MagicSync = require(shared.Net.MagicSync)
	local Protocol = require(shared.Net.Protocol)
	local Sounds = require(shared.Sounds)

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
end
