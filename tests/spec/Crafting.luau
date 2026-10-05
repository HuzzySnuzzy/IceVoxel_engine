--[[
	Crafting recipes (Minecraft's shaped, shapeless and repair matching) and furnaces.
]]

return function(t, shared, require)
	local Items = require(shared.Items)
	local Crafting = require(shared.Crafting)
	local Smelting = require(shared.Crafting.Smelting)

	local id = Items.id

	-- A grid from { [slot] = item id or { item, count } }.
	local function grid(cells)
		local out = {}
		for slot, cell in cells do
			out[slot] = if type(cell) == "table"
				then { item = cell[1], count = cell[2] }
				else { item = cell, count = 1 }
		end
		return out
	end

	local function result(cells, width)
		return Crafting.match(grid(cells), width)
	end

	t.test("crafting: wood, sticks and the crafting table in the 2 x 2 grid", function()
		local planks = result({ [4] = id.OakLog }, 2)
		assert(planks)
		t.eq(planks.item, id.Planks)
		t.eq(planks.count, 4)
		t.eq(result({ [1] = id.BirchLog }, 2).item, id.BirchPlanks)
		t.eq(result({ [1] = id.OakLog, [2] = id.OakLog }, 2), nil, "two logs make nothing")
		local sticks = result({ [2] = id.Planks, [4] = id.BirchPlanks }, 2)
		assert(sticks)
		t.eq(sticks.item, id.Stick, "any planks, stacked vertically")
		t.eq(sticks.count, 4)
		t.eq(result({ [1] = id.Planks, [2] = id.Planks }, 2), nil, "side by side is not a stick")
		t.eq(result({ id.Planks, id.Planks, id.Planks, id.Planks }, 2).item, id.CraftingTable)
		t.eq(result({}, 2), nil)
	end)

	t.test("crafting: shaped recipes fit anywhere in the 3 x 3 grid, mirrored, with nothing else", function()
		t.eq(result({ [5] = id.Planks, [6] = id.Planks, [8] = id.Planks, [9] = id.Planks }, 3).item, id.CraftingTable)
		local pickaxe = { id.Cobblestone, id.Cobblestone, id.Cobblestone, nil, id.Stick, nil, nil, id.Stick }
		t.eq(result(pickaxe, 3).item, id.StonePickaxe)
		t.eq(Crafting.match(grid(pickaxe), 2), nil, "a pickaxe needs the crafting table")
		-- The axe, as written and mirrored.
		local I, S = id.IronIngot, id.Stick
		t.eq(result({ [1] = I, [2] = I, [4] = I, [5] = S, [8] = S }, 3).item, id.IronAxe)
		t.eq(result({ [2] = I, [3] = I, [6] = I, [5] = S, [8] = S }, 3).item, id.IronAxe, "mirrored")
		t.eq(result({ [1] = I, [2] = I, [4] = S, [5] = I, [7] = S }, 3).item, id.IronAxe, "mirrored, on the left")
		t.eq(result({ [1] = I, [2] = I, [3] = I, [4] = S }, 3), nil)
		-- Anything extra spoils it.
		t.eq(result({ [1] = id.Planks, [2] = id.Planks, [4] = id.Planks, [5] = id.Planks, [9] = id.Stick }, 3), nil)
		local ring = {}
		for slot = 1, 9 do
			ring[slot] = if slot == 5 then nil else id.Cobblestone
		end
		t.eq(result(ring, 3).item, id.Furnace)
		ring[5] = id.Cobblestone
		t.eq(result(ring, 3), nil, "a full grid of cobblestone is not a furnace")
		local chest = {}
		for slot = 1, 9 do
			chest[slot] = if slot == 5 then nil else id.SprucePlanks
		end
		t.eq(result(chest, 3).item, id.Chest)
	end)

	t.test("crafting: shapeless recipes and storage blocks both ways", function()
		local andesite = result({ [3] = id.Cobblestone, [1] = id.Diorite }, 2)
		assert(andesite)
		t.eq(andesite.item, id.Andesite)
		t.eq(andesite.count, 2)
		t.eq(result({ [9] = id.Diorite, [2] = id.Cobblestone }, 3).item, id.Andesite)
		local nine = {}
		for slot = 1, 9 do
			nine[slot] = id.IronIngot
		end
		t.eq(result(nine, 3).item, id.IronBlock)
		local ingots = result({ [5] = id.IronBlock }, 3)
		assert(ingots)
		t.eq(ingots.item, id.IronIngot)
		t.eq(ingots.count, 9)
		local nuggets = result({ [1] = id.IronIngot }, 2)
		assert(nuggets)
		t.eq(nuggets.item, id.IronNugget, "one ingot breaks into nuggets")
		t.eq(nuggets.count, 9)
		for slot = 1, 9 do
			nine[slot] = id.Ice
		end
		t.eq(result(nine, 3).item, id.PackedIce)
		t.eq(result({ id.Snowball, id.Snowball, id.Snowball, id.Snowball }, 2).item, id.Snow)
	end)

	t.test("crafting: two worn tools of a kind repair into one (+5%)", function()
		local repaired = Crafting.match({
			[1] = { item = id.WoodenPickaxe, count = 1, damage = 50 },
			[4] = { item = id.WoodenPickaxe, count = 1, damage = 40 },
		}, 2)
		assert(repaired)
		t.eq(repaired.item, id.WoodenPickaxe)
		-- 59 max: (59 - 50) + (59 - 40) + 59 * 5 // 100 = 30 left.
		t.eq(repaired.damage, 29)
		local fresh = Crafting.match({
			[1] = { item = id.IronSword, count = 1, damage = 3 },
			[9] = { item = id.IronSword, count = 1 },
		}, 3)
		assert(fresh)
		t.eq(fresh.damage, nil, "fully repaired")
		t.eq(
			Crafting.match({ [1] = { item = id.IronSword, count = 1 }, [2] = { item = id.GoldenSword, count = 1 } }, 2),
			nil
		)
		t.eq(Crafting.match({ [1] = { item = id.Dirt, count = 1 }, [2] = { item = id.Dirt, count = 1 } }, 2), nil)
	end)

	t.test("crafting: grids that almost match a nine ingredient recipe are quick to refuse", function()
		local cells = {}
		for slot = 1, 8 do
			cells[slot] = id.Ice
		end
		cells[9] = id.Dirt
		local started = os.clock()
		for _ = 1, 20 do
			t.eq(result(cells, 3), nil)
		end
		cells[9] = id.Ice
		t.eq(result(cells, 3).item, id.PackedIce)
		t.ok(os.clock() - started < 0.05, "no backtracking blow-up")
	end)

	t.test("crafting: consuming takes one from every used slot (new tables)", function()
		local before = {
			[2] = { item = id.Planks, count = 3 },
			[5] = { item = id.Planks, count = 1 },
			[7] = { item = id.IronPickaxe, count = 1, damage = 4 },
			[8] = { item = id.IronPickaxe, count = 2, damage = 4 },
		}
		local after = Crafting.consume(before, 3)
		t.eq(after[2].count, 2)
		t.eq(after[5], nil)
		t.eq(after[7], nil)
		t.eq(after[8].damage, 4)
		t.ok(after[2] ~= before[2], "a new stack")
		t.eq(before[2].count, 3, "the grid is untouched")
	end)

	t.test("crafting: every recipe can be crafted (none hides another)", function()
		local first = function(set)
			return (next(set))
		end
		for _, recipe in Crafting.recipes do
			local cells = {}
			if recipe.kind == "shaped" then
				for y = 0, recipe.height - 1 do
					for x = 0, recipe.width - 1 do
						local cell = recipe.cells[y * recipe.width + x + 1]
						if cell then
							cells[y * 3 + x + 1] = first(cell)
						end
					end
				end
			else
				for slot, cell in recipe.cells do
					cells[slot] = first(cell)
				end
			end
			local made = result(cells, 3)
			t.ok(made ~= nil and made.item == recipe.result, `{Items.get(recipe.result).name} is craftable`)
		end
		t.eq(#Crafting.recipes, 99, "recipes compiled")
	end)

	t.test("smelting: recipes and fuel follow Minecraft", function()
		t.eq(Smelting.result(id.RawIron).item, id.IronIngot)
		t.eq(Smelting.result(id.GoldOre).item, id.GoldIngot)
		t.eq(Smelting.result(id.Sand).item, id.Glass)
		t.eq(Smelting.result(id.Cobblestone).item, id.Stone)
		t.eq(Smelting.result(id.JungleLog).item, id.Charcoal)
		t.eq(Smelting.result(id.IronPickaxe).item, id.IronNugget)
		t.eq(Smelting.result(id.ChainmailHelmet).item, id.IronNugget)
		t.eq(Smelting.result(id.Dirt), nil)
		t.eq(Smelting.fuel(id.Coal), 1600)
		t.eq(Smelting.fuel(id.CoalBlock), 16000)
		t.eq(Smelting.fuel(id.BirchPlanks), 300)
		t.eq(Smelting.fuel(id.OakLog), 300)
		t.eq(Smelting.fuel(id.Stick), 100)
		t.eq(Smelting.fuel(id.WoodenSword), 200)
		t.eq(Smelting.fuel(id.Dirt), 0)
	end)

	t.test("smelting: a furnace lights, cooks for 200 ticks and burns down", function()
		local furnace = {
			slots = { [1] = { item = id.RawIron, count = 2 }, [2] = { item = id.Coal, count = 1 } },
			data = Smelting.newData(),
		}
		t.ok(Smelting.active(furnace))
		t.ok(Smelting.tick(furnace))
		t.eq(furnace.data[1], 1600, "lit by the coal")
		t.eq(furnace.slots[2], nil, "the coal is used up")
		t.eq(furnace.data[3], 1)
		for _ = 2, 199 do
			Smelting.tick(furnace)
		end
		t.eq(furnace.slots[3], nil, "not yet")
		Smelting.tick(furnace)
		t.eq(furnace.slots[3].item, id.IronIngot)
		t.eq(furnace.slots[1].count, 1)
		t.eq(furnace.data[3], 0)
		t.eq(furnace.data[1], 1401)

		-- Another input with the same result starts over.
		for _ = 1, 50 do
			Smelting.tick(furnace)
		end
		t.eq(furnace.data[3], 50)
		furnace.slots[1] = { item = id.IronOre, count = 1 }
		Smelting.tick(furnace)
		t.eq(furnace.data[3], 1, "progress restarted")

		-- Something that doesn't fit the output stops it; the fire burns on.
		furnace.slots[1] = { item = id.Sand, count = 1 }
		Smelting.tick(furnace)
		t.eq(furnace.data[3], 0)
		t.eq(furnace.data[1], 1600 - 251, "lit on the first tick, burning on every one after")
	end)

	t.test("smelting: progress falls back when the fire is out; a full output doesn't light", function()
		local cold = {
			slots = { [1] = { item = id.RawGold, count = 1 } },
			data = { 0, 1600, 100, 200, id.RawGold },
		}
		Smelting.tick(cold)
		t.eq(cold.data[3], 98)
		local full = {
			slots = {
				[1] = { item = id.RawIron, count = 1 },
				[2] = { item = id.Coal, count = 3 },
				[3] = { item = id.IronIngot, count = 64 },
			},
			data = Smelting.newData(),
		}
		Smelting.tick(full)
		t.eq(full.data[1], 0, "not lit")
		t.eq(full.slots[2].count, 3, "fuel kept")
		local idle = { slots = { [1] = { item = id.Dirt, count = 1 }, [2] = { item = id.Coal, count = 1 } } }
		Smelting.tick(idle)
		t.eq(idle.slots[2].count, 1, "nothing to smelt: no fire")
		t.ok(not Smelting.active({ slots = {}, data = Smelting.newData() }))
	end)
end
