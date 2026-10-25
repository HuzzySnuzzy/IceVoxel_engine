--[[
	Content/Define, the helpers content packs build entries with: each generator's entries (names,
	the fields it sets and the ones it leaves to the pack), and every helper its header lists being
	there as `define.<name>`.
]]

return function(t, shared, require)
	local Define = require(shared.Content.Define)
	local Schema = require(shared.Content.Schema)

	-- Every entry passes the schema (a generator never makes a field no entry may have).
	local function valid(kind: string, entries: { any })
		for _, entry in entries do
			local problem = Schema.check(kind, entry)
			t.ok(problem == nil, `{entry.name}: {problem}`)
		end
	end

	local function names(list: { any }): string
		local out = {}
		for _, entry in list do
			table.insert(out, entry.name)
		end
		return table.concat(out, " ")
	end

	t.test("define: a fluid's nine blocks, `flowing` on its flows only; cave twins", function()
		local fluid = Define.fluid("Goo", { name = "Goo", color = { 1, 2, 3 }, material = "Glass" }, 7, {
			flammable = { ignite = 1, burn = 2 },
		})
		t.eq(names(fluid), "Goo GooFlow1 GooFlow2 GooFlow3 GooFlow4 GooFlow5 GooFlow6 GooFlow7 GooFalling")
		for level, entry in fluid do
			t.eq(entry.fluid.level, level - 1)
			t.eq(entry.fluid.tickDelay, 7)
			t.eq(entry.placeable, level == 1, "only the source is an item")
			t.eq(entry.flammable ~= nil, level > 1, "flowing fields on the flows")
		end
		valid("blocks", fluid)
		local twin = Define.caveFluid(fluid[1])
		t.eq(twin.name, "CaveGoo")
		t.eq(twin.caveTwin, "Goo")
		t.eq(twin.item, "Goo")
		t.eq(twin.displayName, "Goo", "shown by the source's name")
		t.eq(twin.placeable, false)
		local vine = Define.caveTwin({ name = "VineNorth", item = "Vine" }, { seasonless = true })
		t.eq(vine.name, "CaveVineNorth")
		t.eq(vine.item, "Vine", "a variant's twin names the variant's item")
		t.eq(vine.seasonless, true, "the extra fields")
	end)

	t.test("define: a door's 32 halves, a fence's 16 variants, a layered block's 8 heights", function()
		local door = Define.door({
			wood = "Test",
			color = { 100, 100, 100 },
			upper = function(_c)
				return { Define.doorPiece(-8, 8, -8, 8) }
			end,
		})
		t.eq(#door, 32)
		local seen, items = {}, 0
		for _, half in door do
			t.ok(not seen[half.name], `{half.name} once`)
			seen[half.name] = true
			if half.placeable then
				items += 1
				t.eq(half.name, "TestDoor", "the lower half facing North, hinged left, closed is the item")
			else
				t.eq(half.item, "TestDoor")
			end
			t.eq(half.insulation, if half.door.open then nil else 0.1, "closed, a wall face")
		end
		t.eq(items, 1)
		t.ok(seen.TestDoorEastRightOpenTop, "named by facing, hinge, open and half")
		valid("blocks", door)
		local fence = Define.fence({ name = "TestFence", hardness = 2, flammable = { ignite = 5, burn = 20 } })
		t.eq(#fence, 16)
		for mask, variant in fence do
			t.eq(variant.fence, mask - 1)
			t.eq(variant.placeable, mask == 1)
			t.eq(variant.hardness, 2, "the fence's own fields on every variant")
			local arms = 0
			for bit = 0, 3 do
				arms += bit32.extract(mask - 1, bit)
			end
			t.eq(#variant.collision, 1 + arms, "the post and an arm a side")
		end
		t.eq(fence[16].name, "TestFenceNorthSouthWestEast")
		t.eq(fence[2].item, "TestFence")
		valid("blocks", fence)
		local layers = Define.layers({ name = "Ash", drops = "Ash1", insulation = 0.5 }, { 1, 1, 1, 1, 1, 1, 1, 0.5 })
		t.eq(names(layers), "Ash1 Ash2 Ash3 Ash4 Ash5 Ash6 Ash7 Ash8")
		t.eq(layers[8].insulation, 0.5, "only the full height is a wall face")
		t.eq(layers[7].insulation, nil)
		t.eq(layers[8].speedFactor, 0.5)
		t.eq(layers[3].dropCount, 3)
		t.eq(layers[3].item, "Ash1")
		valid("blocks", layers)
	end)

	t.test("define: plants, tall plants and flowers; transmitters, cables, tanks, machines", function()
		local tall = Define.tallFlower("Bloom", { 1, 2, 3 }, { Define.stem(6) }, { Define.stem(4) }, {})
		t.eq(names(tall), "Bloom BloomTop")
		t.eq(tall[1].plant.top, "BloomTop")
		t.eq(tall[2].plant.bottom, "Bloom")
		t.eq(tall[2].item, "Bloom", "the upper half is the lower's")
		t.eq(tall[2].drops, false)
		t.eq(tall[1].support, "Down")
		t.eq(tall[1].flammable.ignite, 60, "flowers burn")
		local tulip = Define.tulip("TestTulip", { 200, 0, 0 })
		t.eq(#tulip.shape, 4)
		t.eq(tulip.bounds, Define.FLOWER_BOUNDS)
		t.eq(Define.sapling("TestSapling", { 0, 100, 0 }, "Test Sapling").flammable, nil, "saplings don't burn")
		t.ok(
			not pcall(Define.plant, { name = "Bush", plant = { soil = "dirt" }, shape = table.create(5, {}) }),
			"at most 4 boxes"
		)
		valid("blocks", tall)
		local pipe = Define.transmitter(
			{ name = "TestPipe", transmitter = { kind = "fluid", tier = 1 } },
			{ 1, 1, 1 },
			{ 2, 2, 2 }
		)
		t.eq(#pipe.shape, 13, "a glass cube and twelve edges")
		t.eq(#pipe.icon, 17, "and two arms with collars")
		local cable = Define.cable({ name = "TestCable", transmitter = { kind = "energy", tier = 1 } }, { 1, 1, 1 })
		t.eq(cable.shape[1].material, "SmoothPlastic", "the conductor")
		local tank = Define.tank({ name = "TestTank", tank = { tier = 1, capacity = 1000 } }, { 3, 3, 3 })
		t.eq(tank.sturdy, true)
		local machine = Define.machine("TestHeater", "heater", { 1, 1, 1 }, { capacity = 100, input = 10 })
		t.eq(machine.decor, "TestHeater")
		valid("blocks", { pipe, cable, tank, machine })
	end)

	t.test("define: armor and tool sets, potions, bottles and buckets", function()
		local armor = Define.armorSet({
			name = "Tin",
			color = { 1, 1, 1 },
			material = "Metal",
			points = { 1, 2, 3, 4 },
			toughness = 1,
		})
		t.eq(names(armor), "TinHelmet TinChestplate TinLeggings TinBoots")
		t.eq(armor[3].armor.defense, 3)
		t.eq(armor[4].armor.slot, "Feet")
		t.eq(armor[1].equipSound, nil, "a material naming nothing more gives its pieces nothing more")
		t.eq(armor[1].lore, nil)
		t.eq(armor[1].icon, nil)
		-- What every piece says of itself, named once by the material; icons piece by piece.
		local dressed = Define.armorSet({
			name = "Tin",
			color = { 1, 1, 1 },
			material = "Metal",
			points = { 1, 2, 3, 4 },
			toughness = 1,
			equipSound = "item.armor.equip_iron",
			lore = "Tin plate.",
			age = "iron",
			icons = { Helmet = "", Boots = "rbxassetid://1" },
		})
		for _, piece in dressed do
			t.eq(piece.equipSound, "item.armor.equip_iron", `{piece.name}'s equip sound`)
			t.eq(piece.lore, "Tin plate.")
			t.eq(piece.age, "iron")
		end
		t.eq(dressed[1].icon, "", "the helmet's icon")
		t.eq(dressed[2].icon, nil, "a piece the icons leave out")
		t.eq(dressed[4].icon, "rbxassetid://1")
		t.ok(not pcall(Define.armorSet, {
			name = "Tin",
			color = { 1, 1, 1 },
			material = "Metal",
			points = { 1, 2, 3, 4 },
			toughness = 1,
			icons = { Helmett = "" },
		}), "an icon for no piece")
		local tools = Define.toolSet({
			name = "Tin",
			speed = 3,
			level = 1,
			durability = 99,
			color = { 1, 1, 1 },
			material = "Metal",
			attack = { Sword = { 4, 1.6 }, Shovel = { 2, 1 }, Pickaxe = { 2, 1 }, Axe = { 7, 1 }, Hoe = { 1, 1 } },
		})
		t.eq(names(tools), "TinSword TinShovel TinPickaxe TinAxe TinHoe")
		t.eq(tools[4].tool.kind, "axe")
		t.eq(tools[4].attack.damage, 7)
		t.eq(tools[1].lore, nil, "a tier naming nothing more gives its tools nothing more")
		t.eq(tools[1].fuel, nil)
		-- Lore and icons by shape, as `attack`; the Age and fuel of every tool.
		local tier = {
			name = "Tin",
			speed = 3,
			level = 1,
			durability = 99,
			color = { 1, 1, 1 },
			material = "Metal",
			attack = { Sword = { 4, 1.6 }, Shovel = { 2, 1 }, Pickaxe = { 2, 1 }, Axe = { 7, 1 }, Hoe = { 1, 1 } },
			lore = { Sword = "A tin blade.", Hoe = "A tin hoe." },
			icons = { Sword = "", Shovel = "", Pickaxe = "", Axe = "", Hoe = "" },
			age = "iron",
			fuel = 50,
		}
		local named = Define.toolSet(tier)
		t.eq(named[1].lore, "A tin blade.")
		t.eq(named[5].lore, "A tin hoe.")
		t.eq(named[2].lore, nil, "a shape the lore leaves out")
		for _, tool in named do
			t.eq(tool.icon, "", `{tool.name}'s icon`)
			t.eq(tool.age, "iron")
			t.eq(tool.fuel, 50)
		end
		tier.lore = { Pickax = "?" }
		t.ok(not pcall(Define.toolSet, tier), "a line for no shape")
		local potion = Define.potion({ item = "PotionOfTest", displayName = "Potion of Test" }, { 9, 9, 9 })
		t.eq(potion.maxStack, 1)
		t.eq(potion.model[#potion.model].color[1], 9, "the bottle's liquid in the effect's colour")
		t.eq(potion.lore, nil)
		local brewed = Define.potion(
			{ item = "PotionOfTest", displayName = "Potion of Test" },
			{ 9, 9, 9 },
			{ lore = "Brewed for a test.", icon = "", age = "iron" }
		)
		t.eq(brewed.lore, "Brewed for a test.", "`extra`'s fields put over it")
		t.eq(brewed.icon, "")
		t.eq(brewed.age, "iron")
		t.eq(brewed.maxStack, 1, "and the potion's own kept")
		t.eq(#Define.bottle(nil) + 1, #Define.bottle({ 1, 2, 3 }), "a filled bottle shows its liquid")
		t.eq(#Define.filledBucket({ 1, 2, 3 }, "Glass"), #Define.bucket({}) + 2)
		valid("items", armor)
		valid("items", dressed)
		valid("items", tools)
		valid("items", named)
		valid("items", { potion, brewed })
	end)

	t.test("define: every helper its header lists is there", function()
		for _, name in
			{
				"Config",
				"append",
				"shade",
				"lump",
				"ingot",
				"nugget",
				"armorSet",
				"toolSet",
				"bottle",
				"bucket",
				"filledBucket",
				"potion",
				"onWall",
				"wallBounds",
				"fluid",
				"caveTwin",
				"caveFluid",
				"torch",
				"wallTorch",
				"lean",
				"lantern",
				"transmitter",
				"cable",
				"tank",
				"door",
				"doorPiece",
				"darker",
				"fence",
				"layers",
				"machine",
				"plant",
				"tallIcon",
				"tallPlant",
				"tallFlower",
				"flower",
				"tulip",
				"mushroom",
				"sapling",
				"herb",
				"shaped",
				"shapeless",
				"smelting",
				"storage",
				"metal",
			}
		do
			t.ok((Define :: any)[name] ~= nil, `define.{name}`)
		end
	end)
end
