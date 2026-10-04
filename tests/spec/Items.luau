--[[
	Items, drops, mining times, game modes and the inventory / entity / notice messages.
]]

return function(t, shared, require)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local Mining = require(shared.Mining)
	local GameMode = require(shared.GameMode)
	local Protocol = require(shared.Net.Protocol)
	local Types = require(shared.Inventory.Types)

	t.test("items: block items share the block's id, other items start at ITEM_BASE", function()
		t.eq(Items.id.Stone, Blocks.id.Stone)
		t.eq(Items.get(Blocks.id.Stone).block, Blocks.id.Stone)
		t.eq(Items.ofBlock(Blocks.id.Stone), Blocks.id.Stone)
		t.eq(Items.ofBlock(Blocks.id.Bedrock), nil, "bedrock is not placeable")
		t.eq(Items.ofBlock(Blocks.AIR), nil)
		t.eq(Items.ofBlock(Blocks.fluidId("Water", 3)), nil, "only the water source is an item")
		t.eq(Items.ofBlock(Blocks.fluidId("Water", 0)), Blocks.fluidId("Water", 0))
		t.eq(Items.id.LeatherHelmet, Items.ITEM_BASE)
		t.eq(Items.get(Items.id.DiamondBoots).displayName, "Diamond Boots")
		t.eq(Items.get(Items.id.OakLog).displayName, "Oak Log")
		t.eq(Items.maxStack(Items.id.IronChestplate), 1)
		t.eq(Items.maxStack(Items.id.Dirt), 64)
		t.eq(Items.armorSlot(Items.id.GoldLeggings), 3)
		t.eq(Items.armorSlot(Items.id.Dirt), nil)
		t.ok(not pcall(function()
			return Items.id.NoSuchItem
		end), "unknown names error")
		-- Creative order: blocks first, armor last.
		t.eq(Items.list[1].name, "Stone")
		t.eq(Items.list[#Items.list].name, "DiamondBoots")
	end)

	t.test("items: drops follow Minecraft (stone -> cobblestone, grass -> dirt, glass -> nothing)", function()
		t.eq(Items.drops(Blocks.id.Stone).item, Items.id.Cobblestone)
		t.eq(Items.drops(Blocks.id.Grass).item, Items.id.Dirt)
		t.eq(Items.drops(Blocks.id.Podzol).item, Items.id.Dirt)
		t.eq(Items.drops(Blocks.id.Dirt).item, Items.id.Dirt)
		t.eq(Items.drops(Blocks.id.DiamondOre).item, Items.id.DiamondOre)
		t.eq(Items.drops(Blocks.id.Glass), nil)
		t.eq(Items.drops(Blocks.id.OakLeaves), nil)
		t.eq(Items.drops(Blocks.id.Ice), nil)
		t.eq(Items.drops(Blocks.fluidId("Water", 0)), nil)
		t.eq(Items.drops(Blocks.id.Bedrock), nil)
		t.eq(Items.drops(Blocks.id.Chest).item, Items.id.Chest)
		t.eq(Blocks.get(Blocks.id.Chest).container, 27)
	end)

	t.test("items: search matches names and display names in any case", function()
		local found = Items.search("  oak LOG ")
		t.eq(#found, 1)
		t.eq(found[1].name, "OakLog")
		local ores = Items.search("ore")
		t.eq(#ores, 5, "coal, iron, gold, diamond and emerald ore")
		t.eq(#Items.search(""), #Items.list)
		t.eq(#Items.search("zzz"), 0)
	end)

	t.test("items: armor points and Minecraft's damage reduction", function()
		local full = {
			{ item = Items.id.DiamondHelmet, count = 1 },
			{ item = Items.id.DiamondChestplate, count = 1 },
			{ item = Items.id.DiamondLeggings, count = 1 },
			{ item = Items.id.DiamondBoots, count = 1 },
		}
		local points, toughness = Items.armorPoints(full)
		t.eq(points, 20)
		t.eq(toughness, 8)
		-- A helmet in the boots slot counts for nothing.
		t.eq((Items.armorPoints({ [4] = { item = Items.id.IronHelmet, count = 1 } })), 0)
		-- 20 points, 8 toughness against 10 damage: min(20, max(4, 20 - 10 / 4)) = 17.5 -> 70% blocked.
		t.near(Items.damageAfterArmor(10, 20, 8), 3, 1e-9)
		t.near(Items.damageAfterArmor(10, 0, 0), 10, 1e-9)
	end)

	t.test("mining: Minecraft's bare hand times", function()
		t.eq(Mining.ticks(Blocks.id.Stone), 45, "stone 2.25 s")
		t.eq(Mining.ticks(Blocks.id.Dirt), 15)
		t.eq(Mining.ticks(Blocks.id.OakLeaves), 6)
		t.eq(Mining.ticks(Blocks.id.DiamondOre), 90)
		t.eq(Mining.ticks(Blocks.id.Stone, false), 225, "five times slower in the air")
		t.eq(Mining.ticks(Blocks.id.Stone, true, true), 225, "and under water")
		t.eq(Mining.ticks(Blocks.id.Bedrock), math.huge)
		t.ok(not Mining.mayBreak(Blocks.id.Bedrock, 1000))
		t.ok(not Mining.mayBreak(Blocks.id.Stone, 1.0), "stone after 1 s")
		t.ok(Mining.mayBreak(Blocks.id.Stone, 1.6), "stone after 70% of 2.25 s")
		t.ok(Mining.mayBreak(Blocks.id.OakLeaves, 0.2))
	end)

	t.test("game modes parse like /gamemode", function()
		t.eq(GameMode.parse("Creative"), GameMode.CREATIVE)
		t.eq(GameMode.parse("c"), GameMode.CREATIVE)
		t.eq(GameMode.parse("1"), GameMode.CREATIVE)
		t.eq(GameMode.parse("SURVIVAL"), GameMode.SURVIVAL)
		t.eq(GameMode.parse("0"), GameMode.SURVIVAL)
		t.eq(GameMode.parse("adventure"), nil)
	end)

	t.test("protocol: edits carry the inventory action number; mine and use messages", function()
		local action, x, y, z, block, seq = Protocol.decodeEdit(Protocol.encodeEdit(2, -5, 70, 9, 3, 123456))
		t.eq(action, 2)
		t.eq(x, -5)
		t.eq(y, 70)
		t.eq(z, 9)
		t.eq(block, 3)
		t.eq(seq, 123456)
		local started, mx, my, mz = Protocol.decodeMine(Protocol.encodeMine(true, -1, 1000, 2))
		t.eq(started, true)
		t.eq(mx, -1)
		t.eq(my, 1000)
		t.eq(mz, 2)
		t.eq((Protocol.decodeMine(Protocol.encodeMine(false, 0, 0, 0))), false)
		t.eq((Protocol.decodeMine(buffer.create(3))), nil)
		local ux, uy, uz = Protocol.decodeUse(Protocol.encodeUse(7, 8, -9))
		t.eq(ux, 7)
		t.eq(uy, 8)
		t.eq(uz, -9)
		t.eq((Protocol.decodeUse(buffer.create(11))), nil)
	end)

	t.test("protocol: inventory actions round trip, malformed ones are rejected", function()
		local actions: { any } = {
			{ kind = "click", window = 3, slot = Types.OUTSIDE, clickType = 1, button = 1 },
			{ kind = "drag", window = 0, mode = 1, slots = { 4, 5, 39 } },
			{ kind = "select", slot = 9 },
			{ kind = "drop", all = true },
			{ kind = "creative", window = 0, slot = Types.CURSOR, item = Items.id.IronHelmet, count = 1 },
			{ kind = "close", window = 2 },
		}
		for i, action in actions do
			local seq, decoded = Protocol.decodeInventoryAction(Protocol.encodeInventoryAction(i * 1000, action))
			t.eq(seq, i * 1000)
			assert(decoded)
			for key, value in action do
				if type(value) == "table" then
					t.eq(#(decoded :: any)[key], #value, key)
					for j, v in value do
						t.eq((decoded :: any)[key][j], v, key)
					end
				else
					t.eq((decoded :: any)[key], value, `{action.kind}.{key}`)
				end
			end
		end
		t.eq((Protocol.decodeInventoryAction(buffer.create(5))), nil, "too short")
		local bad = Protocol.encodeInventoryAction(1, { kind = "drag", window = 0, mode = 0, slots = { 1, 2 } })
		buffer.writeu8(bad, 7, 3)
		t.eq((Protocol.decodeInventoryAction(bad)), nil, "drag count does not match length")
		local unknown = buffer.create(6)
		buffer.writeu8(unknown, 4, 99)
		t.eq((Protocol.decodeInventoryAction(unknown)), nil, "unknown kind")
	end)

	t.test("protocol: inventory snapshots round trip with and without a container", function()
		local inventory = Types.newInventory()
		inventory.selected = 4
		inventory.slots[1] = { item = Items.id.Dirt, count = 64 }
		inventory.slots[36] = { item = Items.id.Glass, count = 1 }
		inventory.armor[2] = { item = Items.id.IronChestplate, count = 1 }
		inventory.cursor = { item = Items.id.Sand, count = 12 }
		local snapshot = Protocol.decodeInventory(
			Protocol.encodeInventory({ ack = 77, inventory = inventory, window = 0, container = nil })
		)
		t.eq(snapshot.ack, 77)
		t.eq(snapshot.inventory.selected, 4)
		t.eq(snapshot.inventory.slots[1].count, 64)
		t.eq(snapshot.inventory.slots[36].item, Items.id.Glass)
		t.eq(snapshot.inventory.slots[2], nil)
		t.eq(snapshot.inventory.armor[2].item, Items.id.IronChestplate)
		t.eq(snapshot.inventory.cursor.count, 12)
		t.eq(snapshot.window, 0)
		t.eq(snapshot.container, nil)

		local chest = { block = Blocks.id.Chest, size = 27, slots = { [27] = { item = Items.id.Brick, count = 5 } } }
		local opened = Protocol.decodeInventory(
			Protocol.encodeInventory({ ack = 1, inventory = inventory, window = 9, container = chest })
		)
		t.eq(opened.window, 9)
		assert(opened.container)
		t.eq(opened.container.block, Blocks.id.Chest)
		t.eq(opened.container.size, 27)
		t.eq(opened.container.slots[27].count, 5)
		t.eq(opened.container.slots[1], nil)
	end)

	t.test("protocol: entity updates and notices round trip", function()
		local ops = Protocol.decodeEntities(Protocol.encodeEntities({
			{
				op = "spawn",
				id = 1,
				item = Items.id.Dirt,
				count = 3,
				x = 1.5,
				y = 70.25,
				z = -2,
				vx = 0.1,
				vy = 0.2,
				vz = 0,
				age = 10,
			},
			{ op = "sync", id = 2, x = 0, y = 1, z = 2, vx = 0, vy = -0.5, vz = 0 },
			{ op = "count", id = 3, count = 64 },
			{ op = "remove", id = 4, collector = 4123456789 },
		}))
		t.eq(#ops, 4)
		local spawn = ops[1] :: any
		t.eq(spawn.op, "spawn")
		t.eq(spawn.item, Items.id.Dirt)
		t.eq(spawn.count, 3)
		t.eq(spawn.y, 70.25)
		t.near(spawn.vx, 0.1, 1e-6)
		t.eq(spawn.age, 10)
		t.eq((ops[2] :: any).vy, -0.5)
		t.eq((ops[3] :: any).count, 64)
		t.eq((ops[4] :: any).collector, 4123456789)
		t.eq(Protocol.decodeNotice(Protocol.encodeNotice("Game mode: Creative")), "Game mode: Creative")
	end)
end
