--[[
	The new ores: copper, lead, zinc (brass's other metal), brass, sulfur, saltpetre and uranium.
	Their blocks (ids after the Ammo Press), items, drops and harvest tiers, sounds, storage
	recipes and smelting, the brass alloy, black powder and the Nuke's uranium core, their Ages,
	knowledge, lore, blank textures, and the Metal Miner copying every one. Generation, radiation
	and the Ammo Press's brass and lead are checked in their own specs.
]]

return function(t, shared, require, _server, _client)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local Crafting = require(shared.Crafting)
	local Smelting = require(shared.Crafting.Smelting)
	local Ages = require(shared.Progression.Ages)
	local Knowledge = require(shared.Progression.Knowledge)
	local MinerRules = require(shared.Machines.MinerRules)
	local LoreList = require(shared.Items.LoreList)
	local TexturePack = require(shared.TexturePack)

	local B = Blocks.id
	local I = Items.id

	local METALS = { "Copper", "Lead", "Zinc", "Uranium" }
	-- In id order, from 500.
	local BLOCKS = {
		"CopperOre",
		"CopperBlock",
		"RawCopperBlock",
		"LeadOre",
		"LeadBlock",
		"RawLeadBlock",
		"ZincOre",
		"ZincBlock",
		"RawZincBlock",
		"BrassBlock",
		"SulfurOre",
		"SaltpetreOre",
		"UraniumOre",
		"UraniumBlock",
		"RawUraniumBlock",
	}
	local ITEMS = {
		"RawCopper",
		"CopperIngot",
		"CopperNugget",
		"RawLead",
		"LeadIngot",
		"LeadNugget",
		"RawZinc",
		"ZincIngot",
		"ZincNugget",
		"BrassIngot",
		"BrassNugget",
		"Sulfur",
		"Saltpetre",
		"RawUranium",
		"UraniumIngot",
		"UraniumNugget",
		"HazmatHelmet",
		"HazmatChestplate",
		"HazmatLeggings",
		"HazmatBoots",
	}

	local function nine(item: number)
		local grid = {}
		for slot = 1, 9 do
			grid[slot] = { item = item, count = 1 }
		end
		return grid
	end
	local function grid(items: { number }): { [number]: Items.Stack }
		local g = {}
		for slot, item in items do
			g[slot] = { item = item, count = 1 }
		end
		return g
	end

	t.test("ores: fifteen blocks after the Ammo Press, twenty items after the turrets'", function()
		for index, name in BLOCKS do
			t.eq(B[name], B.AmmoPress + index, `{name}'s id`)
			t.eq(I[name], B[name], `{name} is its block's item`)
			t.ok(type(LoreList[name]) == "string", `{name}'s lore`)
			local faces = TexturePack.Blocks[name]
			t.ok(faces ~= nil and faces.All ~= nil, `{name} has a texture entry`)
			local texture = faces and TexturePack.Textures[faces.All :: string]
			t.eq(texture and texture.Color, "", `{name}'s texture is blank until made`)
		end
		t.eq(Blocks.count, B.AmmoPress + #BLOCKS + 1, "the last blocks")
		for index, name in ITEMS do
			t.eq(I[name], I.LaserSight + index, `{name}'s id`)
			t.ok(type(LoreList[name]) == "string", `{name}'s lore`)
			t.eq(TexturePack.Icons[name], "", `{name}'s icon is blank until made`)
		end
		t.eq(Items.list[#Items.list].name, "HazmatBoots", "the last item")
		t.eq(Items.displayName(I.CopperBlock), "Block of Copper")
		t.eq(Items.displayName(I.RawUraniumBlock), "Block of Raw Uranium")
		t.eq(Items.displayName(I.SaltpetreOre), "Saltpetre Ore")
		t.eq(Items.displayName(I.HazmatChestplate), "Hazmat Gown", "Mekanism's names")
	end)

	t.test("ores: drops, harvest tiers and sounds", function()
		for _, metal in METALS do
			local level = if metal == "Uranium" then 2 else 1
			local ore = Blocks.get(B[`{metal}Ore`])
			t.eq(ore.hardness, 3, `{metal} ore: Minecraft's ores' hardness`)
			t.eq(ore.toolLevel, level, `{metal} ore's tier`)
			t.eq(Blocks.soundType(ore.id), "stone")
			local below = if level == 2 then I.StonePickaxe else I.WoodenPickaxe
			local at = if level == 2 then I.IronPickaxe else I.StonePickaxe
			t.eq(Items.drops(ore.id, below), nil, `{metal} ore needs a better pickaxe`)
			local drop = Items.drops(ore.id, at)
			t.ok(drop and drop.item == I[`Raw{metal}`] and drop.count == 1, `{metal} ore drops one raw {metal}`)
			t.eq(Blocks.soundType(B[`{metal}Block`]), "metal", `the Block of {metal}`)
			t.eq(Blocks.soundType(B[`Raw{metal}Block`]), "stone", `the raw block`)
			for _, name in { `{metal}Block`, `Raw{metal}Block` } do
				local drop2 = Items.drops(B[name], at)
				t.eq(drop2 and drop2.item, I[name], `{name} drops itself`)
				t.eq(Items.drops(B[name], below), nil, `{name} needs the ore's tier`)
			end
		end
		for ore, item in { SulfurOre = "Sulfur", SaltpetreOre = "Saltpetre" } do
			t.eq(Blocks.get(B[ore]).toolLevel, 0, `{ore}: any pickaxe, as coal`)
			t.eq(Items.drops(B[ore]), nil, `{ore}: nothing by hand`)
			local drop = Items.drops(B[ore], I.WoodenPickaxe)
			t.ok(drop and drop.item == I[item] and drop.count == 1, `{ore} drops one {item}`)
		end
		t.eq(Blocks.soundType(B.BrassBlock), "metal")
		-- Every ore looks like no other block.
		for _, name in BLOCKS do
			local def = Blocks.get(B[name])
			for id = 0, Blocks.count - 1 do
				if id ~= def.id then
					t.ok(Blocks.get(id).appearance ~= def.appearance, `{Blocks.get(id).name} looks like {name}`)
				end
			end
		end
		-- The Hazmat suit is armor, Leather's points.
		for i, piece in { "Helmet", "Chestplate", "Leggings", "Boots" } do
			local armor = Items.get(I[`Hazmat{piece}`]).armor
			local leather = Items.get(I[`Leather{piece}`]).armor
			t.ok(armor and leather and armor.slot == i and armor.defense == leather.defense, `Hazmat {piece}`)
		end
	end)

	t.test("ores: storage, smelting, brass, black powder and the Nuke", function()
		local pairs = {}
		for _, metal in METALS do
			table.insert(pairs, { `{metal}Nugget`, `{metal}Ingot` })
			table.insert(pairs, { `{metal}Ingot`, `{metal}Block` })
			table.insert(pairs, { `Raw{metal}`, `Raw{metal}Block` })
			for _, input in { `Raw{metal}`, `{metal}Ore` } do
				local result = Smelting.result(I[input])
				t.eq(result and result.item, I[`{metal}Ingot`], `{input} smelts into an ingot`)
			end
		end
		table.insert(pairs, { "BrassNugget", "BrassIngot" })
		table.insert(pairs, { "BrassIngot", "BrassBlock" })
		for _, pair in pairs do
			local packed = Crafting.match(nine(I[pair[1]]), 3)
			t.ok(packed and packed.item == I[pair[2]] and packed.count == 1, `9 {pair[1]} -> {pair[2]}`)
			local unpacked = Crafting.match({ [5] = { item = I[pair[2]], count = 1 } }, 3)
			t.ok(unpacked and unpacked.item == I[pair[1]] and unpacked.count == 9, `{pair[2]} -> 9 {pair[1]}`)
		end
		t.eq((Smelting.result(I.SulfurOre) :: any).item, I.Sulfur)
		t.eq((Smelting.result(I.SaltpetreOre) :: any).item, I.Saltpetre)
		t.eq(Smelting.result(I.BrassIngot), nil, "ingots don't smelt")
		local C, Z = I.CopperIngot, I.ZincIngot
		local brass = Crafting.match(grid({ C, Z, C, C }), 2) :: any
		t.ok(brass and brass.item == I.BrassIngot and brass.count == 4, "three copper and a zinc: four brass")
		t.eq(Crafting.match(grid({ C, Z, C }), 2), nil, "two copper are not enough")
		local S, P = I.Sulfur, I.Saltpetre
		for _, coal in { I.Coal, I.Charcoal } do
			local powder = Crafting.match(grid({ P, coal, S, P }), 2) :: any
			t.ok(powder and powder.item == I.Gunpowder and powder.count == 4, "black powder: four")
		end
		t.eq(Crafting.match(grid({ P, I.Coal, S }), 2), nil, "one saltpetre is not enough")
		local T = I.Tnt
		local nuke = Crafting.match(grid({ T, T, T, T, I.UraniumBlock, T, T, T, T }), 3) :: any
		t.eq(nuke and nuke.item, I.Nuke, "the Nuke's core is uranium")
		-- The Hazmat suit: lead and wool in the armor shapes.
		local L, W, G = I.LeadIngot, I.WhiteWool, I.Glass
		local mask = Crafting.match(grid({ W, L, W, L, G, L }), 3) :: any
		t.eq(mask and mask.item, I.HazmatHelmet, "the mask, a glass visor")
		local boots = Crafting.match(grid({ [1] = L, [3] = L, [4] = W, [6] = W }), 3) :: any
		t.eq(boots and boots.item, I.HazmatBoots)
	end)

	t.test("ores: Ages, knowledge and the Metal Miner", function()
		local function ageOf(name: string): string
			for _, age in Ages.list do
				if table.find(age.recipes, name) then
					return age.id
				end
			end
			return "stone"
		end
		for _, name in { "CopperIngot", "CopperNugget", "CopperBlock", "RawCopperBlock", "Sulfur", "Saltpetre" } do
			t.eq(ageOf(name), "stone", `{name}: the Stone Age's`)
		end
		for _, metal in { "Lead", "Zinc", "Brass" } do
			for _, name in { `{metal}Ingot`, `{metal}Nugget`, `{metal}Block` } do
				t.eq(ageOf(name), "iron", `{name}: the Iron Age's`)
			end
		end
		for _, piece in { "Helmet", "Chestplate", "Leggings", "Boots" } do
			t.eq(ageOf(`Hazmat{piece}`), "iron", `the Hazmat {piece}: before uranium is smelted`)
		end
		for _, name in { "UraniumIngot", "UraniumNugget", "UraniumBlock", "RawUraniumBlock", "Nuke" } do
			t.eq(ageOf(name), "atomic", `{name}: the Atomic Age's`)
		end
		for _, name in { "CopperOre", "LeadOre", "ZincOre", "SulfurOre", "SaltpetreOre", "UraniumOre" } do
			t.ok((Knowledge.ORES :: any)[name] ~= nil, `{name} gives knowledge when mined`)
		end
		-- The miner: the six old ores first (their order is saved), then the new ones.
		local names = {}
		for _, ore in MinerRules.ORES do
			table.insert(names, ore.name)
		end
		t.eq(
			table.concat(names, ","),
			"CoalOre,IronOre,OsmiumOre,GoldOre,EmeraldOre,DiamondOre,CopperOre,LeadOre,ZincOre,SulfurOre,SaltpetreOre,UraniumOre"
		)
		for _, ore in MinerRules.ORES do
			t.eq(MinerRules.ore(ore.block), ore, `{ore.name} is mined`)
		end
		local code, index = MinerRules.unpackState(MinerRules.packState(MinerRules.STATE.MINING, 12))
		t.ok(code == MinerRules.STATE.MINING and index == 12, "the last ore's index packs and reads back")
	end)
end
