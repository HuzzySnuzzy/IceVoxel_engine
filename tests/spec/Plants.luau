--[[
	Plants (Minecraft 1.20.1's ground foliage) and Shears: the 29 plant blocks and their fields,
	what they stand on (Blocks.mayPlaceOn, canSurvive, canPlace: BushBlock, DeadBushBlock,
	MushroomBlock, DoublePlantBlock), which block a placement makes (placementFor never gives an
	upper half), the halves of tall plants (plantTop, plantBottom, otherHalf, variants, the item),
	drops with and without Shears, Shears' speed and wear, the foliage colour lookup tables and
	appearance flags, the models (box counts, inside the outline whichever way the scatter turns
	them) and the Shears item and recipe.
]]

return function(t, shared, require, server)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local Mining = require(shared.Mining)
	local Config = require(shared.Config)
	local Crafting = require(shared.Crafting)
	local EditRules = require(server.Network.EditRules)

	local B, I = Blocks.id, Items.id
	local AIR, STONE = Blocks.AIR, B.Stone
	local WATER = Blocks.fluidId("Water", 0)
	local SHEARS = I.Shears

	-- Every plant, in BlockList order, with its display name and kind.
	local PLANTS = {
		{ "ShortGrass", "Short Grass", "grass" },
		{ "Fern", "Fern", "grass" },
		{ "TallGrass", "Tall Grass", "lower" },
		{ "TallGrassTop", "Tall Grass", "upper" },
		{ "LargeFern", "Large Fern", "lower" },
		{ "LargeFernTop", "Large Fern", "upper" },
		{ "DeadBush", "Dead Bush", "deadbush" },
		{ "Dandelion", "Dandelion", "flower" },
		{ "Poppy", "Poppy", "flower" },
		{ "BlueOrchid", "Blue Orchid", "flower" },
		{ "Allium", "Allium", "flower" },
		{ "AzureBluet", "Azure Bluet", "flower" },
		{ "RedTulip", "Red Tulip", "flower" },
		{ "OrangeTulip", "Orange Tulip", "flower" },
		{ "WhiteTulip", "White Tulip", "flower" },
		{ "PinkTulip", "Pink Tulip", "flower" },
		{ "OxeyeDaisy", "Oxeye Daisy", "flower" },
		{ "Cornflower", "Cornflower", "flower" },
		{ "LilyOfTheValley", "Lily of the Valley", "flower" },
		{ "Sunflower", "Sunflower", "lower" },
		{ "SunflowerTop", "Sunflower", "upper" },
		{ "Lilac", "Lilac", "lower" },
		{ "LilacTop", "Lilac", "upper" },
		{ "RoseBush", "Rose Bush", "lower" },
		{ "RoseBushTop", "Rose Bush", "upper" },
		{ "Peony", "Peony", "lower" },
		{ "PeonyTop", "Peony", "upper" },
		{ "BrownMushroom", "Brown Mushroom", "mushroom" },
		{ "RedMushroom", "Red Mushroom", "mushroom" },
	}
	-- Lower half -> upper half.
	local TALL = {
		TallGrass = "TallGrassTop",
		LargeFern = "LargeFernTop",
		Sunflower = "SunflowerTop",
		Lilac = "LilacTop",
		RoseBush = "RoseBushTop",
		Peony = "PeonyTop",
	}
	local REPLACEABLE = {
		ShortGrass = true,
		Fern = true,
		TallGrass = true,
		TallGrassTop = true,
		LargeFern = true,
		LargeFernTop = true,
		DeadBush = true,
	}
	local TINTED = {
		ShortGrass = true,
		Fern = true,
		TallGrass = true,
		TallGrassTop = true,
		LargeFern = true,
		LargeFernTop = true,
	}
	local LEAVES = { B.OakLeaves, B.BirchLeaves, B.SpruceLeaves, B.AcaciaLeaves, B.JungleLeaves }
	local DIRT_SET = { B.Grass, B.DryGrass, B.Dirt, B.CoarseDirt, B.Podzol, B.Mycelium }

	-- A sparse world: unset blocks are air, `false` = not loaded.
	local function sparse(blocks: { [string]: number | false })
		return function(x: number, y: number, z: number): number?
			local b = blocks[`{x},{y},{z}`]
			if b == false then
				return nil
			end
			return b or AIR
		end
	end
	-- `block` standing on `soil` at (0, 10, 0), with `above` at y 11.
	local function onSoil(soil: number | false, above: (number | false)?)
		return sparse({ ["0,9,0"] = soil, ["0,11,0"] = if above == nil then AIR else above })
	end

	-- A box corner turned by CFrame.Angles(rx, ry, rz) = Rx * Ry * Rz (degrees).
	local function turn(v: { number }, r: { number }): { number }
		local ax, ay, az = math.rad(r[1]), math.rad(r[2]), math.rad(r[3])
		local x, y, z = v[1], v[2], v[3]
		x, y = x * math.cos(az) - y * math.sin(az), x * math.sin(az) + y * math.cos(az)
		x, z = x * math.cos(ay) + z * math.sin(ay), -x * math.sin(ay) + z * math.cos(ay)
		y, z = y * math.cos(ax) - z * math.sin(ax), y * math.sin(ax) + z * math.cos(ax)
		return { x, y, z }
	end
	-- Every corner of `shape`'s boxes (pixels from the cell's centre).
	local function corners(shape: { Blocks.ShapeBox }): { { number } }
		local out = {}
		for _, box in shape do
			for _, sx in { -1, 1 } do
				for _, sy in { -1, 1 } do
					for _, sz in { -1, 1 } do
						local c = turn(
							{ box.size[1] / 2 * sx, box.size[2] / 2 * sy, box.size[3] / 2 * sz },
							box.rotation or { 0, 0, 0 }
						)
						table.insert(out, { c[1] + box.offset[1], c[2] + box.offset[2], c[3] + box.offset[3] })
					end
				end
			end
		end
		return out
	end

	t.test("plants: the 29 blocks, at the end of BlockList in Minecraft's order and names", function()
		local first = B.ShortGrass
		for i, entry in PLANTS do
			local block = B[entry[1]]
			t.eq(block, first + i - 1, `{entry[1]} id`)
			local def = Blocks.get(block)
			local shown = if entry[3] == "upper" then def.displayName else Items.displayName(block)
			t.eq(shown, entry[2], `{entry[1]} name`)
			t.ok(Blocks.isPlant(block), `{entry[1]} is a plant`)
		end
		t.ok(not Blocks.isPlant(STONE) and not Blocks.isPlant(AIR) and not Blocks.isPlant(B.Torch))
		t.ok(not Blocks.isPlant(-1) and not Blocks.isPlant(Blocks.count), "unknown ids")
		t.eq(Items.displayName(I.ShortGrass), "Short Grass")
		t.eq(Items.displayName(I.LilyOfTheValley), "Lily of the Valley")
	end)

	t.test("plants: not solid, instant, grass sounds, washed away, scattered, the Plant behaviour", function()
		for _, entry in PLANTS do
			local name, kind = entry[1], entry[3]
			local block = B[name]
			local def = Blocks.get(block)
			local upper = kind == "upper"
			t.ok(not def.solid and not Blocks.isSolid(block), `{name} is not solid`)
			t.ok(not def.sturdy and not Blocks.isOpaque(block), `{name} holds nothing up and hides nothing`)
			t.eq(Blocks.obstruction(block), nil, `{name} has no collision box`)
			t.eq(def.hardness, 0, `{name} breaks at once`)
			t.ok(def.breakable, `{name} is breakable`)
			t.eq(Blocks.soundType(block), "grass", `{name} sounds like grass`)
			t.ok(def.brokenByFluid, `{name} is washed away`)
			t.eq(def.behaviour, "Plant", `{name} behaviour`)
			t.ok(def.scatter, `{name} is scattered`)
			t.eq(def.kind, Blocks.KIND_TRANSPARENT, `{name} renders like glass`)
			t.ok(Blocks.isTargetable(block), `{name} can be aimed at`)
			t.eq(def.light, 0, `{name} gives no light`)
			t.eq(def.placeable, not upper, `{name} placeable`)
			t.eq(table.find(Blocks.placeable, block) ~= nil, not upper, `{name} in the placeable list`)
			t.eq(def.support, if upper then nil else "Down", `{name} support`)
			t.eq(Blocks.isReplaceable(block), REPLACEABLE[name] == true, `{name} replaceable`)
			t.eq(def.tinted, TINTED[name] == true, `{name} tinted`)
			t.ok(def.plant ~= nil, `{name} plant`)
			t.eq(def.item, if upper then Blocks.get(Blocks.plantBottom(block) :: number).name else nil, `{name} item`)
		end
		-- Leaves and flowers stay what they were: only leaves get Shears drops among old blocks.
		for _, leaves in LEAVES do
			t.eq(Blocks.get(leaves).shearDrops, true, `{Blocks.get(leaves).name} shear drops`)
			t.ok(not Blocks.isPlant(leaves), "leaves are no plant")
		end
	end)

	t.test("plants: soil sets (BushBlock, DeadBushBlock, MushroomBlock)", function()
		local dirtSet: { [number]: boolean } = {}
		for _, soil in DIRT_SET do
			dirtSet[soil] = true
		end
		local others = {
			AIR,
			Blocks.CAVE_AIR,
			STONE,
			B.Sand,
			B.Gravel,
			B.Glass,
			B.OakLeaves,
			B.Snow,
			B.Ice,
			B.OakLog,
			B.Chest,
			B.Torch,
			B.Lantern,
			B.BasicFluidTank,
			B.BasicLogisticalTransporter,
			B.SolarPanel,
			WATER,
			Blocks.fluidId("Water", 3),
			B.ShortGrass,
			B.TallGrass,
			B.Calcite,
			B.PackedMud,
		}
		for _, entry in PLANTS do
			local name, kind = entry[1], entry[3]
			local plant = B[name]
			for _, soil in DIRT_SET do
				local expected = kind ~= "upper"
				t.eq(Blocks.mayPlaceOn(plant, soil), expected, `{name} on {Blocks.get(soil).name}`)
				t.eq(Blocks.canSurvive(plant, onSoil(soil), 0, 10, 0), expected, `{name} survives on it`)
			end
			for _, soil in others do
				local expected = (kind == "deadbush" and soil == B.Sand)
					or (kind == "mushroom" and Blocks.isSturdy(soil) and Blocks.isOpaque(soil))
				t.eq(Blocks.mayPlaceOn(plant, soil), expected, `{name} on {Blocks.get(soil).name}`)
				-- (Tall grass's top stands on tall grass: the halves are tested below.)
				local survives = expected or Blocks.plantBottom(plant) == soil
				t.eq(Blocks.canSurvive(plant, onSoil(soil), 0, 10, 0), survives, `{name} survives on it`)
			end
			-- Unloaded soil holds nothing up; unknown ids are no soil.
			t.ok(not Blocks.canSurvive(plant, onSoil(false), 0, 10, 0), `{name} over an unloaded block`)
			t.ok(not Blocks.mayPlaceOn(plant, -1) and not Blocks.mayPlaceOn(plant, Blocks.count), "unknown soil")
		end
		-- Mushrooms: mycelium and podzol, and any sturdy opaque full block (no light check here).
		for _, soil in { B.Mycelium, B.Podzol, STONE, B.Dirt, B.Grass, B.Cobblestone, B.OakLog, B.GlowBlock } do
			t.ok(Blocks.mayPlaceOn(B.RedMushroom, soil), `a mushroom on {Blocks.get(soil).name}`)
		end
		for _, soil in { B.Glass, B.OakLeaves, B.Chest, B.BasicFluidTank, B.Torch, AIR, WATER, B.Cactus } do
			t.ok(not Blocks.mayPlaceOn(B.BrownMushroom, soil), `no mushroom on {Blocks.get(soil).name}`)
		end
		-- Dead bushes: sand and the dirt set, not stone or gravel.
		t.ok(Blocks.mayPlaceOn(B.DeadBush, B.Sand) and Blocks.mayPlaceOn(B.DeadBush, B.Podzol))
		t.ok(not Blocks.mayPlaceOn(B.DeadBush, STONE) and not Blocks.mayPlaceOn(B.DeadBush, B.Gravel))
		-- Grass and flowers don't grow on sand.
		t.ok(not Blocks.mayPlaceOn(B.ShortGrass, B.Sand) and not Blocks.mayPlaceOn(B.Poppy, B.Sand))
		-- Not plants: nothing to stand on.
		t.ok(not Blocks.mayPlaceOn(STONE, B.Grass) and not Blocks.mayPlaceOn(B.Torch, STONE))
	end)

	t.test("plants: tall plants' halves (DoublePlantBlock)", function()
		for lowerName, upperName in TALL do
			local lower, upper = B[lowerName], B[upperName]
			t.eq(Blocks.plantTop(lower), upper, `{lowerName} top`)
			t.eq(Blocks.plantBottom(upper), lower, `{upperName} bottom`)
			t.eq(Blocks.plantTop(upper), nil)
			t.eq(Blocks.plantBottom(lower), nil)
			t.eq(Blocks.otherHalf(lower), 1, `{lowerName} partner above`)
			t.eq(Blocks.otherHalf(upper), -1, `{upperName} partner below`)
			-- An upper half stands on its own lower half only.
			t.ok(Blocks.canSurvive(upper, onSoil(lower), 0, 10, 0), `{upperName} on its bottom`)
			for _, below in { B.Grass, AIR, STONE, B.ShortGrass, upper } do
				t.ok(not Blocks.canSurvive(upper, onSoil(below), 0, 10, 0), `{upperName} needs its bottom`)
			end
			t.ok(not Blocks.canSurvive(upper, onSoil(false), 0, 10, 0), `{upperName} over an unloaded block`)
			-- The lower half needs its soil, whatever is above (its top is the server's business).
			t.ok(Blocks.canSurvive(lower, onSoil(B.Grass, STONE), 0, 10, 0), `{lowerName} survives under stone`)
			t.ok(not Blocks.canSurvive(lower, onSoil(STONE, upper), 0, 10, 0), `{lowerName} needs soil`)
		end
		-- The other halves of tall plants are their own: no mixing.
		t.ok(not Blocks.canSurvive(B.TallGrassTop, onSoil(B.LargeFern), 0, 10, 0))
		t.ok(not Blocks.canSurvive(B.SunflowerTop, onSoil(B.Lilac), 0, 10, 0))
		-- Single plants and other blocks have no other half.
		for _, block in { B.ShortGrass, B.Poppy, B.DeadBush, B.RedMushroom, STONE, AIR, B.Torch, 9999 } do
			t.eq(Blocks.plantTop(block), nil)
			t.eq(Blocks.plantBottom(block), nil)
			t.eq(Blocks.otherHalf(block), nil)
		end
	end)

	t.test("plants: canPlace needs room for a tall plant's top, inside the world", function()
		local top = Config.WorldHeight - 1
		for lowerName in TALL do
			local lower = B[lowerName]
			-- Replaceable above: air, water, short grass, a fern, a dead bush.
			for _, above in { AIR, WATER, Blocks.fluidId("Water", 5), B.ShortGrass, B.Fern, B.DeadBush } do
				t.ok(Blocks.canPlace(lower, onSoil(B.Grass, above), 0, 10, 0), `{lowerName} under {above}`)
			end
			-- No room: a block, a flower, a torch, an unloaded cell.
			for _, above in { STONE, B.Poppy, B.Torch, B.Glass, B.OakLeaves } do
				t.ok(not Blocks.canPlace(lower, onSoil(B.Grass, above), 0, 10, 0), `{lowerName} under {above}`)
			end
			t.ok(not Blocks.canPlace(lower, onSoil(B.Grass, false), 0, 10, 0), `{lowerName} under unloaded`)
			-- Its soil still matters.
			t.ok(not Blocks.canPlace(lower, onSoil(STONE), 0, 10, 0), `{lowerName} on stone`)
			-- The world's top: the upper half must fit below Config.WorldHeight.
			local atTop = sparse({ [`0,{top - 1},0`] = B.Grass })
			local belowTop = sparse({ [`0,{top - 2},0`] = B.Grass })
			t.ok(not Blocks.canPlace(lower, atTop, 0, top, 0), `{lowerName} in the top layer`)
			t.ok(Blocks.canPlace(lower, belowTop, 0, top - 1, 0), `{lowerName} just under the top`)
			t.ok(Blocks.canSurvive(lower, atTop, 0, top, 0), "it would survive there")
		end
		-- Single plants and other blocks: canPlace is canSurvive.
		for _, block in { B.ShortGrass, B.Poppy, B.DeadBush, B.BrownMushroom, B.Torch, B.Lantern, STONE } do
			for _, world in { onSoil(B.Grass, STONE), onSoil(STONE), onSoil(B.Sand), onSoil(false) } do
				t.eq(
					Blocks.canPlace(block, world, 0, 10, 0),
					Blocks.canSurvive(block, world, 0, 10, 0),
					`{Blocks.get(block).name} canPlace`
				)
			end
		end
		-- A short plant needs no room above, even in the top layer.
		local atTop = sparse({ [`0,{top - 1},0`] = B.Grass })
		t.ok(Blocks.canPlace(B.Poppy, atTop, 0, top, 0), "a poppy in the top layer")
	end)

	t.test("plants: placementFor gives the plant or nil, never an upper half", function()
		local normals = { { 0, 1, 0 }, { 0, -1, 0 }, { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 }, { 0, 0, 0 } }
		local looks = { { 0, -1, 0 }, { 0.3, -0.9, 0.2 }, { 1, 0, 0 }, { -0.2, 0.5, -0.8 }, { 0, 1, 0 } }
		local worlds = {
			{ onSoil(B.Grass), true },
			{ onSoil(B.Grass, STONE), false },
			{ onSoil(STONE), false },
			{ onSoil(B.Sand), false },
			{ onSoil(false), false },
		}
		for _, entry in PLANTS do
			local name, kind = entry[1], entry[3]
			if kind ~= "upper" then
				local plant = B[name]
				for _, w in worlds do
					local world, fits = w[1], w[2]
					-- (A short plant fits under stone; a dead bush fits on sand.)
					local expected = Blocks.canPlace(plant, world, 0, 10, 0)
					if kind == "lower" then
						expected = fits
					end
					for _, n in normals do
						for _, l in looks do
							local got = Blocks.placementFor(plant, n[1], n[2], n[3], l[1], l[2], l[3], world, 0, 10, 0)
							t.ok(got == nil or got == plant, `{name} places itself or nothing`)
							t.eq(got ~= nil, expected, `{name} placement`)
						end
					end
				end
			end
		end
		-- Torches still pick their variant.
		local wall = sparse({ ["1,10,0"] = STONE })
		t.eq(Blocks.placementFor(B.Torch, -1, 0, 0, 1, 0, 0, wall, 0, 10, 0), B.WallTorchWest)
		t.eq(Blocks.placementFor(B.Torch, 0, 1, 0, 0, -1, 0, onSoil(STONE), 0, 10, 0), B.Torch)
	end)

	t.test("plants: upper halves are variants of their lower half and answer its item", function()
		for lowerName, upperName in TALL do
			local lower, upper = B[lowerName], B[upperName]
			t.eq(Items.ofBlock(upper), I[lowerName], `{upperName}'s item`)
			t.eq(Items.ofBlock(lower), I[lowerName], `{lowerName}'s item`)
			t.eq(Items.get(upper), nil, `{upperName} is no item`)
			t.ok(table.find(Blocks.variants(lower), upper) ~= nil, `{upperName} is a variant`)
			t.eq(Blocks.variants(upper)[1], lower, "the group starts with the lower half")
			t.eq(Blocks.supportOffset(upper), nil, `{upperName} hangs on nothing`)
			t.eq(Blocks.variantFor(lower, 0, 1, 0), lower, "clicking a top face places the lower half")
		end
	end)

	t.test("plants: a replaceable plant is not replaced by its own item (canBeReplaced)", function()
		-- The client's placement target (BlockInteraction): into the clicked block when
		-- Items.isReplacedBy, else against the clicked face. The server never places a block into
		-- itself (EditRules.mayPlace), so a click with the plant's own item goes beside it.
		for _, entry in PLANTS do
			local name = entry[1]
			local block = B[name]
			local own = Items.ofBlock(block) :: number
			t.eq(Items.isReplacedBy(block, own), false, `{name} is not replaced by its own item`)
			t.eq(Items.isReplacedBy(block, nil), REPLACEABLE[name] == true, `{name} with nothing in hand`)
			t.eq(Items.isReplacedBy(block, I.Dirt), REPLACEABLE[name] == true, `{name} replaced by Dirt`)
			if REPLACEABLE[name] and own == block then
				t.eq(EditRules.mayPlace(block, block), false, `the server never places {name} into itself`)
			end
		end
		-- Short grass and tall grass replace each other; air, water and stone are as before.
		t.ok(Items.isReplacedBy(B.ShortGrass, I.TallGrass), "tall grass replaces short grass")
		t.ok(Items.isReplacedBy(B.TallGrassTop, I.ShortGrass), "short grass replaces tall grass's top")
		t.ok(Items.isReplacedBy(AIR, I.ShortGrass) and Items.isReplacedBy(WATER, I.Dirt), "air and water")
		t.eq(Items.isReplacedBy(STONE, nil), false, "stone")
		t.eq(Items.isReplacedBy(B.Poppy, I.Dandelion), false, "flowers are not replaceable")
	end)

	t.test("plants: drops by hand, with tools and with Shears", function()
		local function drop(block: number, tool: number?): (number?, number?)
			local stack = Items.drops(block, tool)
			return if stack then stack.item else nil, if stack then stack.count else nil
		end
		local hands = { nil, I.WoodenShovel, I.DiamondPickaxe, I.IronSword, I.Stick, I.Dirt }
		for i = 1, #hands + 1 do
			local tool = hands[i]
			-- Grass and ferns: nothing (Minecraft's seeds: there is no wheat).
			t.eq(drop(B.ShortGrass, tool), nil, "short grass")
			t.eq(drop(B.Fern, tool), nil, "a fern")
			t.eq(drop(B.TallGrass, tool), nil, "tall grass")
			t.eq(drop(B.LargeFern, tool), nil, "a large fern")
			-- A dead bush: a stick (Minecraft 0-2).
			t.eq(drop(B.DeadBush, tool), I.Stick, "a dead bush")
			-- Leaves: nothing.
			for _, leaves in LEAVES do
				t.eq(drop(leaves, tool), nil, "leaves")
			end
		end
		-- Shears.
		local item, count = drop(B.ShortGrass, SHEARS)
		t.eq(item, I.ShortGrass, "short grass with shears")
		t.eq(count, 1)
		item, count = drop(B.Fern, SHEARS)
		t.eq(item, I.Fern)
		t.eq(count, 1)
		item, count = drop(B.TallGrass, SHEARS)
		t.eq(item, I.ShortGrass, "tall grass gives short grass")
		t.eq(count, 2, "two of it")
		item, count = drop(B.LargeFern, SHEARS)
		t.eq(item, I.Fern, "a large fern gives ferns")
		t.eq(count, 2)
		item, count = drop(B.DeadBush, SHEARS)
		t.eq(item, I.DeadBush, "a dead bush gives itself")
		t.eq(count, 1)
		for _, leaves in LEAVES do
			item, count = drop(leaves, SHEARS)
			t.eq(item, leaves, `{Blocks.get(leaves).name} with shears`)
			t.eq(count, 1)
		end
		-- Flowers, tall flowers and mushrooms: themselves either way; upper halves: nothing.
		for _, entry in PLANTS do
			local name, kind = entry[1], entry[3]
			local block = B[name]
			if kind == "upper" then
				for _, tool in { SHEARS, I.DiamondAxe } do
					t.eq(drop(block, tool), nil, `{name} drops nothing`)
				end
				t.eq(drop(block), nil, `{name} by hand`)
				t.eq(Items.blockDrops(block), nil, `{name} by itself`)
			elseif kind == "flower" or kind == "mushroom" or TALL[name] and not REPLACEABLE[name] then
				for _, tool in { SHEARS, I.DiamondAxe } do
					t.eq(drop(block, tool), I[name], `{name} drops itself`)
				end
				t.eq(drop(block), I[name], `{name} by hand`)
				t.eq((Items.blockDrops(block) :: Items.Stack).item, I[name], `{name} by itself`)
			end
		end
		-- Breaking by itself (the Plant behaviour, water): as by hand.
		t.eq(Items.blockDrops(B.TallGrass), nil)
		t.eq((Items.blockDrops(B.DeadBush) :: Items.Stack).item, I.Stick)
		-- Shears change nothing on other blocks: dirt by shears is dirt, stone needs a pickaxe.
		t.eq(drop(B.Dirt, SHEARS), I.Dirt)
		t.eq(drop(B.Grass, SHEARS), I.Dirt)
		t.eq(drop(STONE, SHEARS), nil)
		t.eq(drop(B.Glass, SHEARS), nil)
		-- The creative rule is the server's (no drops at all).
		t.eq(EditRules.drops(B.TallGrass, true, SHEARS), nil, "creative")
		local survival = EditRules.drops(B.TallGrass, false, SHEARS)
		t.ok(survival ~= nil and survival.item == I.ShortGrass and survival.count == 2, "survival")
		t.ok(Items.isShears(SHEARS) and not Items.isShears(I.IronSword) and not Items.isShears(nil))
		t.ok(Items.canHarvest(B.OakLeaves, SHEARS) and Items.canHarvest(B.TallGrass, SHEARS))
	end)

	t.test("shears: 15 on what they harvest, worn by every block they break", function()
		local def = Items.get(SHEARS) :: Items.ItemDef
		t.eq(def.durability, 238)
		t.eq(Items.maxStack(SHEARS), 1, "shears don't stack")
		local tool = Items.tool(SHEARS) :: { kind: string, speed: number, level: number }
		t.eq(tool.kind, "shears")
		t.eq(tool.speed, 15)
		for _, leaves in LEAVES do
			t.eq(Mining.toolSpeed(leaves, SHEARS), 15, "leaves")
			-- Hardness 0.2: 15 / 0.2 / 30 = 2.5 a tick, so the first tick breaks them.
			t.eq(Mining.ticks(leaves, true, false, SHEARS), 1, "leaves at once")
		end
		t.eq(Mining.ticks(B.OakLeaves), 6, "leaves by hand: 0.3 s")
		t.eq(Mining.toolSpeed(B.TallGrass, SHEARS), 15, "grass")
		t.eq(Mining.toolSpeed(STONE, SHEARS), 1, "stone")
		t.eq(Mining.toolSpeed(B.Dirt, SHEARS), 1, "dirt")
		t.eq(Mining.toolSpeed(B.Poppy, SHEARS), 1, "flowers are not sheared")
		t.eq(Mining.ticks(STONE, true, false, SHEARS), 150, "stone: like a hand")
		-- Wear: 1 on every block, instant ones too; other tools as before.
		for block = 0, Blocks.count - 1 do
			t.eq(Mining.wear(block, SHEARS), 1, `shears on {Blocks.get(block).name}`)
		end
		t.eq(Mining.wear(9999, SHEARS), 0, "unknown block")
		for _, entry in PLANTS do
			local block = B[entry[1]]
			t.eq(Mining.wear(block, I.DiamondPickaxe), 0, `{entry[1]}: instant for other tools`)
			t.eq(Mining.wear(block, I.IronSword), 0)
			t.eq(Mining.wear(block, nil), 0)
			t.eq(Mining.progressPerTick(block, true, false, SHEARS), 1, "breaks at once")
		end
		t.eq(Mining.wear(STONE, I.WoodenPickaxe), 1)
		t.eq(Mining.wear(STONE, I.IronSword), 2)
		-- Creative players' tools never wear (the callers' rule).
		t.eq(EditRules.wear(B.TallGrass, false, SHEARS), 1, "survival")
		t.eq(EditRules.wear(B.TallGrass, true, SHEARS), 0, "creative")
		t.eq(EditRules.wear(STONE, true, SHEARS), 0, "creative")
	end)

	t.test("shears: the item model and Minecraft's recipe", function()
		local def = Items.get(SHEARS) :: Items.ItemDef
		t.eq(def.displayName, "Shears")
		t.ok(def.model ~= nil and #(def.model :: { any }) >= 4, "blades and handles")
		t.eq(def.tilt, -45, "lies diagonally like the tools")
		local ingot = I.IronIngot
		local function craft(cells: { [number]: number }, width: number): Items.Stack?
			local grid = {}
			for slot, item in cells do
				grid[slot] = { item = item, count = 1 }
			end
			return Crafting.match(grid, width)
		end
		-- " #", "# " in the inventory's 2 x 2 grid, and mirrored.
		local made = craft({ [2] = ingot, [3] = ingot }, 2)
		t.ok(made ~= nil and made.item == SHEARS and made.count == 1, "the inventory grid")
		made = craft({ [1] = ingot, [4] = ingot }, 2)
		t.ok(made ~= nil and made.item == SHEARS, "mirrored")
		-- Anywhere in the 3 x 3 grid.
		made = craft({ [6] = ingot, [8] = ingot }, 3)
		t.ok(made ~= nil and made.item == SHEARS, "the crafting table")
		t.eq(craft({ [1] = ingot, [2] = ingot }, 2), nil, "side by side is no shears")
		local nuggets = craft({ [1] = ingot }, 2)
		t.ok(nuggets ~= nil and nuggets.item == I.IronNugget, "one ingot makes nuggets")
		t.eq(craft({ [2] = ingot, [3] = I.GoldIngot }, 2), nil, "iron only")
	end)

	t.test("plants: foliage colours, tint lookup tables and appearance flags", function()
		-- Only DryGrass has a foliage colour: tint 1.
		t.eq(#Blocks.FOLIAGE_TINTS, 1)
		t.ok(table.isfrozen(Blocks.FOLIAGE_TINTS) and table.isfrozen(Blocks.FOLIAGE_TINTS[1]), "read only")
		t.eq(buffer.len(Blocks.tintLut), Blocks.count)
		for block = 0, Blocks.count - 1 do
			t.eq(buffer.readu8(Blocks.tintLut, block), if block == B.DryGrass then 1 else 0, Blocks.get(block).name)
			t.eq(Blocks.foliageColorOf(block) ~= nil, block == B.DryGrass, "foliageColorOf")
		end
		t.eq(Blocks.foliageColorOf(-1), nil)
		t.eq(Blocks.foliageColorOf(Blocks.count), nil)
		local dry = Blocks.foliageColorOf(B.DryGrass) :: { number }
		local grass = Blocks.get(B.Grass).color
		for k = 1, 3 do
			t.near(Blocks.FOLIAGE_TINTS[1][k], dry[k] / grass[k], 1e-12, "multiplier")
		end
		-- Savanna grass is yellower than plains grass: more red against green.
		t.ok(dry[1] / dry[2] > grass[1] / grass[2] + 0.3, "yellow-green")
		-- Per appearance: tinted and foliage, sized for every appearance id.
		t.eq(buffer.len(Blocks.tintedLut), #Blocks.appearances + 1)
		t.eq(buffer.len(Blocks.foliageLut), #Blocks.appearances + 1)
		local plantAppearances: { [number]: number } = {}
		for _, entry in PLANTS do
			local name, kind = entry[1], entry[3]
			local def = Blocks.get(B[name])
			local appearance = Blocks.appearances[def.appearance]
			t.ok(def.appearance > 0, `{name} is drawn`)
			t.eq(plantAppearances[def.appearance], nil, `{name} has an appearance of its own`)
			plantAppearances[def.appearance] = B[name]
			t.eq(appearance.foliage, true, `{name} foliage`)
			t.eq(appearance.scatter, true, `{name} scatter`)
			t.eq(appearance.tinted, TINTED[name] == true, `{name} tinted`)
			t.eq(appearance.upperHalf, kind == "upper", `{name} upper half`)
			t.eq(buffer.readu8(Blocks.tintedLut, def.appearance), if TINTED[name] then 1 else 0)
			t.eq(buffer.readu8(Blocks.foliageLut, def.appearance), 1)
			t.eq(buffer.readu8(Blocks.singleLut, def.appearance), 1, `{name} is drawn box by box`)
		end
		-- No other block shares a plant's appearance, and other appearances are no foliage.
		for block = 0, Blocks.count - 1 do
			local def = Blocks.get(block)
			if not Blocks.isPlant(block) and def.appearance > 0 then
				t.eq(plantAppearances[def.appearance], nil, `{def.name} looks like a plant`)
				local appearance = Blocks.appearances[def.appearance]
				t.ok(not appearance.foliage and not appearance.tinted and not appearance.scatter, def.name)
				t.ok(not appearance.upperHalf, def.name)
				t.eq(buffer.readu8(Blocks.foliageLut, def.appearance), 0, def.name)
				t.eq(buffer.readu8(Blocks.tintedLut, def.appearance), 0, def.name)
			end
		end
	end)

	t.test("plants: models are at most 4 boxes, inside the outline whichever way they turn", function()
		t.ok(Blocks.MAX_SHAPE_BOXES >= 4)
		local common = { ShortGrass = true, Fern = true, TallGrass = true, TallGrassTop = true }
		for _, entry in PLANTS do
			local name, kind = entry[1], entry[3]
			local def = Blocks.get(B[name])
			local shape = def.shape :: { Blocks.ShapeBox }
			t.ok(shape ~= nil and #shape >= 1, `{name} has a shape`)
			t.ok(#shape <= 4 and #shape <= Blocks.MAX_SHAPE_BOXES, `{name}: {#shape} boxes`)
			if common[name] then
				t.eq(#shape, 3, `{name} is common: 3 boxes`)
			end
			-- Minecraft's outlines. Tall plants keep a full block's (DoublePlantBlock has no shape
			-- of its own): aimed at as a whole cell, no outline of their own.
			local b = def.bounds
			local tall = kind == "lower" or kind == "upper"
			local expected = if kind == "flower"
				then { 5, 0, 5, 11, 10, 11 }
				elseif kind == "mushroom" then { 5, 0, 5, 11, 6, 11 }
				elseif tall then { 0, 0, 0, 16, 16, 16 }
				else { 2, 0, 2, 14, 13, 14 }
			local got = { b.min[1], b.min[2], b.min[3], b.max[1], b.max[2], b.max[3] }
			for k = 1, 6 do
				t.eq(got[k], expected[k], `{name} outline {k}`)
				if not tall then
					t.near((Blocks.outline(B[name]) :: { number })[k], expected[k] / 16, 1e-12, `{name} aimed outline`)
				end
			end
			if tall then
				t.eq(Blocks.outline(B[name]), nil, `{name} is aimed at as a full block`)
			end
			--[[
				Every corner (CFrame.Angles maths, as Blocks' shapeBounds) is inside the outline at
				any turn about the vertical axis (its distance from the middle at most the outline's
				half width; tall plants' models keep to grass's 2..14), so the scatter's 3 pixels
				take it at most a pixel out of its cell. It may sink a pixel into the ground (hidden)
				but never rise above the outline.
			]]
			local half = if tall then 6 else math.min(8 - b.min[1], b.max[1] - 8, 8 - b.min[3], b.max[3] - 8)
			for i, c in corners(shape) do
				t.ok(math.sqrt(c[1] ^ 2 + c[3] ^ 2) <= half + 1e-9, `{name} corner {i} leaves the outline`)
				t.ok(c[2] >= -9 and c[2] <= b.max[2] - 8 + 1e-9, `{name} corner {i} height {c[2]}`)
				t.ok(math.sqrt(c[1] ^ 2 + c[3] ^ 2) + 3 <= 9, `{name} corner {i} scattered`)
			end
			for i, box in shape do
				for k = 1, 3 do
					t.ok(box.size[k] >= 0.3, `{name} box {i} is at least 0.3 pixels thick`)
				end
				t.ok(box.material == "SmoothPlastic", `{name} box {i} material`)
				local c = box.color :: { number }
				t.ok(c ~= nil and #c == 3, `{name} box {i} colour`)
				-- Tinted plants are green all over: every box takes the soil's tint.
				if TINTED[name] then
					t.ok(c[2] > c[1] and c[2] > c[3], `{name} box {i} is green`)
				end
			end
		end
	end)

	t.test("plants: flowers have a coloured head and the sunflower faces east", function()
		local function green(c: { number }): boolean
			return c[2] > c[1] + 10 and c[2] > c[3] + 10
		end
		for _, entry in PLANTS do
			local name, kind = entry[1], entry[3]
			if kind == "flower" or kind == "mushroom" then
				local headed = false
				for _, box in Blocks.get(B[name]).shape :: { Blocks.ShapeBox } do
					headed = headed or not green(box.color :: { number })
				end
				t.ok(headed, `{name} has a head`)
			end
		end
		-- The disc's middle is in front of it, towards +X (east).
		local shape = Blocks.get(B.SunflowerTop).shape :: { Blocks.ShapeBox }
		local disc, middle = shape[2], shape[4]
		t.ok(middle.offset[1] > disc.offset[1] and math.abs(middle.offset[3] - disc.offset[3]) < 1e-9, "faces east")
		t.ok(disc.size[1] < 1 and disc.size[2] > 5 and disc.size[3] > 5, "a disc across X")
	end)

	t.test("plants: tall plants' items show the lower half first, fitted in one cell", function()
		for lowerName in TALL do
			local def = Blocks.get(B[lowerName])
			local icon = def.icon :: { Blocks.ShapeBox }
			local shape = def.shape :: { Blocks.ShapeBox }
			t.ok(icon ~= nil and #icon > #shape, `{lowerName} has an item model`)
			for i, box in shape do
				t.eq(icon[i], box, `{lowerName} item starts with the shape`)
			end
			for i, c in corners(icon) do
				for k = 1, 3 do
					t.ok(math.abs(c[k]) <= 9, `{lowerName} item corner {i} fits the cell`)
				end
			end
		end
		-- Single plants are their shape.
		t.eq(Blocks.get(B.Poppy).icon, nil)
		t.eq(Blocks.get(B.ShortGrass).icon, nil)
	end)
end
