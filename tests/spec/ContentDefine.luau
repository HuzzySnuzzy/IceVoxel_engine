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
		local fluid = Define.fluid(
			"Goo",
			{ name = "Goo", color = { 1, 2, 3 }, material = "Glass", lore = "Sticky.", heats = true },
			7,
			{
				flammable = { ignite = 1, burn = 2 },
			}
		)
		t.eq(names(fluid), "Goo GooFlow1 GooFlow2 GooFlow3 GooFlow4 GooFlow5 GooFlow6 GooFlow7 GooFalling")
		for level, entry in fluid do
			t.eq(entry.fluid.level, level - 1)
			t.eq(entry.fluid.tickDelay, 7)
			t.eq(entry.placeable, level == 1, "only the source is an item")
			t.eq(entry.flammable ~= nil, level > 1, "flowing fields on the flows")
			-- (The fluid's own fields, its item's lore and its warmth, are the source's alone.)
			t.eq(entry.lore, if level == 1 then "Sticky." else nil, "lore on the source")
			t.eq(entry.heats, if level == 1 then true else nil, "heats on the source")
		end
		valid("blocks", fluid)
		local twin = Define.caveFluid(fluid[1])
		t.eq(twin.name, "CaveGoo")
		t.eq(twin.caveTwin, "Goo")
		t.eq(twin.item, "Goo")
		t.eq(twin.displayName, "Goo", "shown by the source's name")
		t.eq(twin.placeable, false)
		t.eq(twin.lore, nil, "a twin is no item")
		t.eq(twin.heats, nil, "the fluid's name warms its twin")
		local vine = Define.caveTwin({
			name = "VineNorth",
			item = "Vine",
			lore = "Green.",
			texture = { Front = "vine" },
			flammable = {
				ignite = 15,
				burn = 100,
			},
		}, { seasonless = true })
		t.eq(vine.name, "CaveVineNorth")
		t.eq(vine.item, "Vine", "a variant's twin names the variant's item")
		t.eq(vine.seasonless, true, "the extra fields")
		t.ok(vine.lore == nil and vine.texture == nil, "none of its item's own fields")
		t.eq(vine.flammable and vine.flammable.ignite, 15, "and the rest of its twin's")
	end)

	t.test("define: a door's 32 halves, a fence's 16 variants, a layered block's 8 heights", function()
		local door = Define.door({
			wood = "Test",
			color = { 100, 100, 100 },
			texture = { Front = "test door bottom" },
			topTexture = { Front = "test door top" },
			lore = "A test door.",
			fuel = 200,
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
				t.ok(half.lore == "A test door." and half.fuel == 200, "the door's own fields on its item")
				t.eq(half.texture and half.texture.Front, "test door bottom", "the lower halves' picture")
			else
				t.eq(half.item, "TestDoor")
				t.ok(half.lore == nil and half.fuel == nil, `{half.name}: none on the other halves`)
				local top = if half.name == "TestDoorTop" then "test door top" else nil
				t.eq(half.texture and half.texture.Front, top, `{half.name}: the upper halves' picture on one`)
			end
			t.eq(half.insulation, if half.door.open then nil else 0.1, "closed, a wall face")
		end
		t.eq(items, 1)
		t.ok(seen.TestDoorEastRightOpenTop, "named by facing, hinge, open and half")
		valid("blocks", door)
		local fence = Define.fence({
			name = "TestFence",
			hardness = 2,
			flammable = { ignite = 5, burn = 20 },
			lore = "A test fence.",
			fuel = 300,
		})
		t.eq(#fence, 16)
		for mask, variant in fence do
			t.eq(variant.fence, mask - 1)
			t.eq(variant.placeable, mask == 1)
			t.eq(variant.hardness, 2, "the fence's fields on every variant")
			-- (Its item's own, lore and fuel, on the lone post alone.)
			t.eq(variant.lore, if mask == 1 then "A test fence." else nil)
			t.eq(variant.fuel, if mask == 1 then 300 else nil)
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

	t.test("define: what a door's, a layered block's, an armor set's and a herb's entries say of themselves", function()
		-- A door's item takes the wood's own fields (lore, Age, its `texture`), and its upper half
		-- facing North its `topTexture`.
		local door = Define.door({
			wood = "Felt",
			color = { 100, 100, 100 },
			upper = function(_c)
				return { Define.doorPiece(-8, 8, -8, 8) }
			end,
			lore = "Soft.",
			age = "iron",
			texture = { Front = "felt door bottom" },
			topTexture = { Front = "felt door top" },
		})
		for _, half in door do
			local own = half.name == "FeltDoor" or half.name == "FeltDoorTop"
			t.eq(half.texture ~= nil, own, `{half.name}: only the two entries the texture pack keys by`)
			t.eq(half.lore, if half.name == "FeltDoor" then "Soft." else nil, `{half.name}'s lore`)
		end
		valid("blocks", door)
		-- A layered block's item fields and its texture are layer 1's alone (its other heights are
		-- no items, and layer 1's texture covers them).
		local layers = Define.layers(
			{ name = "Ash", drops = "Ash1", lore = "Grey.", texture = { All = "ash" }, age = "iron" },
			{ 1, 1, 1, 1, 1, 1, 1, 1 }
		)
		t.eq(layers[1].lore, "Grey.")
		t.eq(layers[1].texture and layers[1].texture.All, "ash")
		t.eq(layers[1].age, "iron")
		for n = 2, 8 do
			t.ok(layers[n].lore == nil and layers[n].texture == nil and layers[n].age == nil, `Ash{n}: none`)
			t.eq(layers[n].drops, "Ash1", "the block's own fields stay")
		end
		-- An armor set's lore, icon and equip sound on every piece.
		local armor = Define.armorSet({
			name = "Felt",
			color = { 1, 1, 1 },
			material = "Fabric",
			points = { 1, 1, 1, 1 },
			toughness = 0,
			lore = "Soft.",
			icon = "",
			equipSound = "item.armor.equip_leather",
		})
		for _, piece in armor do
			t.eq(piece.lore, "Soft.")
			t.eq(piece.icon, "")
			t.eq(piece.equipSound, "item.armor.equip_leather")
		end
		valid("items", armor)
		-- A herb from its own fields: a plant on dirt, no item, spreading by its behaviour.
		local herb = Define.herb({
			name = "Sage",
			color = { 1, 2, 3 },
			shape = { Define.stem(6) },
			bounds = Define.FLOWER_BOUNDS,
			texture = { Sprite = "sage" },
		})
		t.eq(herb.placeable, false)
		t.eq(herb.behaviour, "Herb")
		t.eq(herb.plant and herb.plant.soil, "dirt")
		t.eq(herb.support, "Down")
		t.eq(herb.texture and herb.texture.Sprite, "sage")
		valid("blocks", { herb })
	end)

	t.test("define: plants, tall plants and flowers; transmitters, cables, tanks, machines", function()
		-- (The flower generators take the entry itself, so its lore and texture sit with it.)
		local tall = Define.tallFlower({
			name = "Bloom",
			color = { 1, 2, 3 },
			shape = { Define.stem(6) },
			lore = "A test bloom.",
			texture = { Sprite = "bloom bottom" },
		}, { shape = { Define.stem(4) }, texture = { Sprite = "bloom top" } }, {})
		t.eq(names(tall), "Bloom BloomTop")
		t.eq(tall[1].plant.top, "BloomTop")
		t.eq(tall[2].plant.bottom, "Bloom")
		t.eq(tall[2].item, "Bloom", "the upper half is the lower's")
		t.eq(tall[2].drops, false)
		t.eq(tall[2].displayName, "Bloom", "shown as the lower half")
		t.eq(tall[1].support, "Down")
		t.eq(tall[1].flammable.ignite, 60, "flowers burn")
		t.eq(tall[1].lore, "A test bloom.", "the entry's own fields")
		t.eq(tall[2].lore, nil, "the upper half is no item")
		t.eq(tall[2].texture and tall[2].texture.Sprite, "bloom top", "each half its own picture")
		local tulip = Define.tulip({ name = "TestTulip", color = { 200, 0, 0 }, lore = "A test tulip." })
		t.eq(#tulip.shape, 4)
		t.eq(tulip.bounds, Define.FLOWER_BOUNDS)
		t.eq(tulip.lore, "A test tulip.")
		local sapling = Define.sapling({ name = "TestSapling", displayName = "Test Sapling", color = { 0, 100, 0 } })
		t.eq(sapling.flammable, nil, "saplings don't burn")
		t.eq(sapling.behaviour, "Sapling")
		valid("blocks", { tulip, sapling })
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
		-- (A machine is made from its own fields now, so its entry shows its lore and Age too.)
		local machine = Define.machine({
			name = "TestHeater",
			color = { 1, 1, 1 },
			machine = { kind = "heater" },
			energy = { capacity = 100, input = 10 },
			age = "iron",
		})
		t.eq(machine.decor, "TestHeater")
		t.eq(machine.hardness, 3.5)
		t.eq(machine.age, "iron", "its own fields kept")
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

	t.test("define: a potion's variants, and the items and recipes brewing makes of it", function()
		local potion = {
			name = "Test",
			displayName = "Testing",
			ingredient = "Stick",
			effect = "Speed",
			seconds = 10,
			long = 30,
			lore = { base = "Brewed for a test.", long = "Brewed longer." },
			icon = { long = "rbxassetid://5" },
			age = { base = "iron", strong = "industrial", long = "industrial" },
		}
		local variants = Define.potionVariants(potion)
		t.eq(#variants, 2, "the base and the long one (no strong)")
		t.eq(variants[1].item, "PotionOfTest")
		t.eq(variants[1].displayName, "Potion of Testing")
		t.ok(variants[1].ticks == 200 and variants[1].amplifier == 0 and variants[1].form == "base")
		t.ok(
			variants[1].from == "PurifiedWaterBottle" and variants[1].with == "Stick",
			"a water bottle and its ingredient"
		)
		t.eq(variants[2].item, "LongPotionOfTest")
		t.ok(variants[2].ticks == 600 and variants[2].from == "PotionOfTest" and variants[2].with == "#coals")
		local strong =
			Define.potionVariants({ name = "Hurt", ingredient = "Stick", effect = "InstantDamage", strong = true })
		t.ok(strong[1].ticks == 1 and strong[2].ticks == 1 and strong[2].amplifier == 1, "an instant one: a tick")
		t.ok(strong[2].item == "StrongPotionOfHurt" and strong[2].with == "GlowDust")
		local brew = Define.brew(potion, { 9, 9, 9 })
		t.eq(#brew.items, 2)
		t.eq(brew.items[1].lore, "Brewed for a test.", "each item's line")
		t.eq(brew.items[1].icon, "", "blank where it gives none")
		t.eq(brew.items[2].icon, "rbxassetid://5")
		t.eq(brew.items[1].age, "iron")
		t.eq(brew.items[2].age, "industrial")
		t.eq(brew.items[1].color[1], 9, "its effect's colour")
		t.eq(brew.recipes[2].type, "shapeless")
		t.eq(table.concat(brew.recipes[2].ingredients, " "), "PotionOfTest #coals")
		t.eq(brew.recipes[2].result, "LongPotionOfTest")
		valid("items", brew.items)
		valid("recipes", brew.recipes)
	end)

	t.test("define: a block sound type's five events and a mob's voice, sound events of the schema", function()
		-- (The scaling per action is tests/spec/Sounds'.)
		local events = Define.blockSounds({
			name = "felt",
			volume = 0.8,
			pitch = 0.7,
			dig = { id = Define.SHIPPED.LAND },
			step = { id = Define.SHIPPED.STEPS },
		})
		t.eq(names(events), "block.felt.break block.felt.place block.felt.hit block.felt.step block.felt.fall")
		valid("sounds", events)
		for index, action in Define.BLOCK_ACTIONS do
			t.eq(events[index].category, `block.{action.name}`, "each action's category")
			t.eq(events[index].side, action.side)
		end
		local voice = Define.mobVoice({ kind = "goat", hurt = 1.2, death = 1.1 })
		t.eq(names(voice), "entity.goat.hurt entity.goat.death")
		valid("sounds", voice)
		t.eq(voice[1].category, "entity.mob.hurt")
		t.eq(voice[2].category, "entity.mob.death")
		t.eq(voice[1].pitch, 1.2, "its hurt's pitch")
		t.eq(voice[2].pitch, 1.1, "its death's")
		for name, id in Define.SHIPPED do
			t.ok(string.find(id, "^rbxasset://sounds/") ~= nil, `SHIPPED.{name} ships with every client`)
		end
		for name, id in Define.RECORDINGS do
			t.ok(string.find(id, "^rbxassetid://%d+$") ~= nil, `RECORDINGS.{name} is an upload`)
		end
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
				"potionVariants",
				"brew",
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
				"SHIPPED",
				"RECORDINGS",
				"ONE_STEP",
				"BLOCK_ACTIONS",
				"blockSounds",
				"mobVoice",
			}
		do
			t.ok((Define :: any)[name] ~= nil, `define.{name}`)
		end
	end)
end
