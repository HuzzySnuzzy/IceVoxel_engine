--[[
	Mekanism's osmium: the ore, Raw Osmium, the ingot and nugget and the two storage blocks (their
	drops, harvest levels, mining times, sounds and models), their storage recipes and smelting, and
	what JEI and WAILA show for them. Ore generation is checked in Generation.
]]

return function(t, shared, require, _server, client)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local ItemList = require(shared.Items.ItemList)
	local Mining = require(shared.Mining)
	local Crafting = require(shared.Crafting)
	local Smelting = require(shared.Crafting.Smelting)
	local WailaInfo = require(client.Ui.WailaInfo)
	local JeiData = require(client.Ui.Jei.JeiData)

	local B = Blocks.id
	local I = Items.id

	-- A 3 x 3 grid with `item` in every slot, and one with `item` alone in the middle.
	local function nine(item: number)
		local grid = {}
		for slot = 1, 9 do
			grid[slot] = { item = item, count = 1 }
		end
		return grid
	end
	local function one(item: number)
		return { [5] = { item = item, count = 1 } }
	end

	local function spec(name: string)
		for _, item in ItemList do
			if item.name == name then
				return item
			end
		end
		error(`no item {name}`)
	end

	t.test("osmium: blocks and items exist with Mekanism's names and numbers", function()
		for name, display in
			{
				OsmiumOre = "Osmium Ore",
				OsmiumBlock = "Block of Osmium",
				RawOsmiumBlock = "Block of Raw Osmium",
				RawOsmium = "Raw Osmium",
				OsmiumIngot = "Osmium Ingot",
				OsmiumNugget = "Osmium Nugget",
			}
		do
			t.eq(Items.displayName(I[name]), display, name)
			t.eq(Items.maxStack(I[name]), 64, `{name} stacks to 64`)
		end
		-- The blocks are block items; the others are not.
		for _, name in { "OsmiumOre", "OsmiumBlock", "RawOsmiumBlock" } do
			t.eq(I[name], B[name], `{name} is its block's item`)
			t.eq(Items.ofBlock(B[name]), I[name], `{name} item of the block`)
		end
		for _, name in { "RawOsmium", "OsmiumIngot", "OsmiumNugget" } do
			t.ok(I[name] >= Items.ITEM_BASE, `{name} is an item`)
			t.eq(Items.get(I[name]).block, nil, `{name} places nothing`)
		end
		local ore, block, raw = Blocks.get(B.OsmiumOre), Blocks.get(B.OsmiumBlock), Blocks.get(B.RawOsmiumBlock)
		t.eq(ore.hardness, 3, "ore hardness (Minecraft's ores)")
		t.eq(block.hardness, 7.5, "Block of Osmium hardness (Mekanism's)")
		t.eq(raw.hardness, 7.5, "Block of Raw Osmium hardness (Mekanism's)")
		for _, def in { ore, block, raw } do
			t.eq(def.tool, "pickaxe", `{def.name} tool`)
			t.eq(def.toolLevel, 1, `{def.name} needs a stone pickaxe`)
			t.ok(Blocks.isOpaque(def.id) and Blocks.isSolid(def.id), `{def.name} is a full cube`)
			t.ok(Blocks.isSturdy(def.id), `{def.name} holds torches`)
			t.eq(def.container, 0, `{def.name} holds nothing`)
		end
		-- Bluish: more blue than red in every one of them.
		for _, colour in { ore.color, block.color, raw.color, Items.get(I.OsmiumIngot).color } do
			t.ok(colour[3] > colour[1] + 20, "bluish colour")
		end
	end)

	t.test("osmium: the ore drops raw osmium with a stone pickaxe or better", function()
		t.eq(Items.drops(B.OsmiumOre), nil, "by hand: nothing")
		t.eq(Items.drops(B.OsmiumOre, I.WoodenPickaxe), nil, "a wooden pickaxe: nothing")
		t.eq(Items.drops(B.OsmiumOre, I.GoldenPickaxe), nil, "gold is wood tier")
		t.eq(Items.drops(B.OsmiumOre, I.StoneShovel), nil, "the wrong tool")
		for _, pickaxe in { I.StonePickaxe, I.IronPickaxe, I.DiamondPickaxe } do
			local drop = Items.drops(B.OsmiumOre, pickaxe)
			assert(drop)
			t.eq(drop.item, I.RawOsmium, "raw osmium")
			t.eq(drop.count, 1, "one")
		end
		for _, name in { "OsmiumBlock", "RawOsmiumBlock" } do
			t.eq(Items.drops(B[name], I.WoodenPickaxe), nil, `{name} needs stone`)
			local drop = Items.drops(B[name], I.StonePickaxe)
			t.eq(drop and drop.item, I[name], `{name} drops itself`)
		end
		-- Mined like iron ore (same hardness and tier); the blocks take Mekanism's 7.5.
		t.eq(
			Mining.ticks(B.OsmiumOre, true, false, I.StonePickaxe),
			Mining.ticks(B.IronOre, true, false, I.StonePickaxe),
			"as fast as iron ore"
		)
		t.eq(Mining.ticks(B.OsmiumOre, true, false, I.WoodenPickaxe), 150, "can't harvest: / 100 (3 * 100 / 2)")
		t.eq(Mining.ticks(B.OsmiumBlock, true, false, I.IronPickaxe), 38, "ceil(7.5 * 30 / 6) ticks")
		t.eq(
			Mining.ticks(B.OsmiumBlock, true, false, I.IronPickaxe),
			Mining.ticks(B.RawOsmiumBlock, true, false, I.IronPickaxe),
			"the raw block as fast"
		)
	end)

	t.test("osmium: sounds and models like the game's other ores and metals", function()
		t.eq(Blocks.soundType(B.OsmiumOre), "stone", "ore")
		t.eq(Blocks.soundType(B.RawOsmiumBlock), "stone", "raw block")
		t.eq(Blocks.soundType(B.OsmiumBlock), "metal", "metal block")
		t.eq(Blocks.soundType(B.OsmiumBlock), Blocks.soundType(B.IronBlock), "like the Block of Iron")
		-- The items use the iron shapes (lump, ingot, nugget) in their own colours.
		for osmium, iron in { RawOsmium = "RawIron", OsmiumIngot = "IronIngot", OsmiumNugget = "IronNugget" } do
			local a, b = spec(osmium), spec(iron)
			t.eq(#a.model, #b.model, `{osmium} shaped like {iron}`)
			for i, box in a.model do
				t.eq(box.size[1], b.model[i].size[1], `{osmium} box {i}`)
			end
			t.eq(a.tilt, b.tilt, `{osmium} tilt`)
			t.eq(a.material, b.material, `{osmium} material`)
			t.ok(a.color ~= nil and b.color ~= nil and a.color[3] ~= b.color[3], `{osmium} has its own colour`)
		end
		-- The ore is a speckled stone, apart from every other block's look.
		local ore = Blocks.get(B.OsmiumOre)
		for id = 0, Blocks.count - 1 do
			if id ~= ore.id then
				t.ok(Blocks.get(id).appearance ~= ore.appearance, `{Blocks.get(id).name} looks like osmium ore`)
			end
		end
	end)

	t.test("osmium: storage recipes both ways", function()
		for _, pair in
			{ { "OsmiumNugget", "OsmiumIngot" }, { "OsmiumIngot", "OsmiumBlock" }, { "RawOsmium", "RawOsmiumBlock" } }
		do
			local small, big = I[pair[1]], I[pair[2]]
			local packed = Crafting.match(nine(small), 3)
			assert(packed, `9 {pair[1]}`)
			t.eq(packed.item, big, `9 {pair[1]} -> {pair[2]}`)
			t.eq(packed.count, 1, `one {pair[2]}`)
			t.eq(Crafting.match(nine(small), 2), nil, "needs the crafting table")
			local unpacked = Crafting.match(one(big), 3)
			assert(unpacked, `{pair[2]} unpacks`)
			t.eq(unpacked.item, small, `{pair[2]} -> {pair[1]}`)
			t.eq(unpacked.count, 9, "nine")
			local inSmallGrid = Crafting.match({ [3] = { item = big, count = 1 } }, 2)
			t.eq(inSmallGrid and inSmallGrid.item, small, "unpacks in the 2 x 2 grid too")
		end
		-- Eight nuggets are not enough.
		local eight = nine(I.OsmiumNugget)
		eight[9] = nil
		t.eq(Crafting.match(eight, 3), nil, "8 nuggets")
	end)

	t.test("osmium: raw osmium and the ore smelt into ingots", function()
		t.eq(Smelting.result(I.RawOsmium).item, I.OsmiumIngot, "raw osmium")
		t.eq(Smelting.result(I.OsmiumOre).item, I.OsmiumIngot, "the ore (silk touch in Minecraft)")
		t.eq(Smelting.result(I.RawOsmium).count, 1, "one ingot")
		t.eq(Smelting.result(I.OsmiumIngot), nil, "ingots don't smelt")
		t.eq(Smelting.fuel(I.OsmiumBlock), 0, "not a fuel")
		local furnace = {
			slots = { [1] = { item = I.RawOsmium, count = 2 }, [2] = { item = I.Coal, count = 1 } },
			data = Smelting.newData(),
		}
		for _ = 1, Smelting.COOK_TIME do
			Smelting.tick(furnace)
		end
		t.eq(furnace.slots[3] and furnace.slots[3].item, I.OsmiumIngot, "an ingot after 200 ticks")
		t.eq(furnace.slots[1].count, 1, "one raw osmium used")
	end)

	t.test("osmium: JEI shows its recipes and uses, WAILA its harvest tier", function()
		local function categories(groups): string
			local names = {}
			for _, group in groups do
				table.insert(names, group.category)
			end
			return table.concat(names, ",")
		end
		t.eq(categories(JeiData.recipes(I.OsmiumIngot)), "crafting,smelting", "ingot: nuggets / block, smelting")
		local smelting = JeiData.recipes(I.OsmiumIngot)[2].entries
		t.eq(#smelting, 2, "from raw osmium and from the ore")
		t.eq(categories(JeiData.uses(I.RawOsmium)), "crafting,smelting", "raw osmium: block, smelting")
		t.eq(categories(JeiData.recipes(I.OsmiumBlock)), "crafting", "the block is crafted")
		t.ok(JeiData.has("recipes", I.RawOsmium), "raw osmium unpacks from its block")
		t.ok(not JeiData.has("recipes", I.OsmiumOre), "the ore is only found")
		t.eq(#JeiData.filter("osmium"), 6, "the list finds all six")
		t.eq(#Items.search("Osmium"), 6, "and so does the creative search")

		local C, X = WailaInfo.CHECK, WailaInfo.CROSS
		local function texts(held: number?): string
			return table.concat(WailaInfo.texts(WailaInfo.block(B.OsmiumOre, held, 0, 40, 0, false)), " | ")
		end
		t.ok(string.find(texts(nil), "Osmium Ore", 1, true) ~= nil, "named")
		t.ok(string.find(texts(I.WoodenPickaxe), `{X} Requires Stone Pickaxe`, 1, true) ~= nil, "wood: cross")
		t.ok(string.find(texts(I.StonePickaxe), `{C} Requires Stone Pickaxe`, 1, true) ~= nil, "stone: check")
	end)
end
