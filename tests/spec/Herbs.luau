--[[
	Tough As Nails' herbs, bowls and teas: the Mint and Wild Ginger plants (plants placed by their
	herb items, ItemList `places`; their drops, outlines and models), where generation grows them
	(BiomeList `foliage.herbs`: rare patches on flat test chunks, and the right herb in the right
	biome in generated terrain), their spreading on random ticks (Behaviours/Herb), placing them
	back with the herb item (EditRules, InventoryState), the Bowl and its water (Drinks' tables:
	fill, drink, the empty bowl back), mint's cure for dirty water and the furnace's, the teas
	(Internal Chill and Warmth) and what JEI, WAILA and the creative inventory show of them.
]]

return function(t, shared, require, server, client)
	local Blocks = require(shared.Blocks)
	local Biomes = require(shared.Biomes)
	local Config = require(shared.Config)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Crafting = require(shared.Crafting)
	local Smelting = require(shared.Crafting.Smelting)
	local Foliage = require(shared.Generation.Foliage)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)
	local Hash = require(shared.Util.Hash)
	local Items = require(shared.Items)
	local ToughAsNails = require(shared.ToughAsNails)
	local WorldServer = require(server.World.WorldServer)
	local BlockTicker = require(server.World.BlockTicker)
	local RandomTicker = require(server.World.RandomTicker)
	local Behaviours = require(server.Behaviours)
	local Herb = require(server.Behaviours.Herb)
	local Plant = require(server.Behaviours.Plant)
	local Drops = require(server.Behaviours.Drops)
	local EditRules = require(server.Network.EditRules)
	local InventoryState = require(server.Players.InventoryState)
	local JeiData = require(client.Ui.Jei.JeiData)
	local WailaInfo = require(client.Ui.WailaInfo)

	local Thirst = ToughAsNails.Thirst
	local Temperature = ToughAsNails.Temperature
	local Drinks = ToughAsNails.Drinks
	local Boiling = ToughAsNails.Boiling
	local B, I = Blocks.id, Items.id
	local AIR, STONE, GRASS = Blocks.AIR, B.Stone, B.Grass
	local MINT, GINGER = B.Mint, B.WildGinger
	local HERBS = { [MINT] = I.MintLeaves, [GINGER] = I.GingerRoot }
	local SIZE = ChunkLayout.SIZE
	local P = ChunkLayout.PADDED

	-- A random that answers `values` in turn (then 0.5).
	local function rolls(values: { number }): () -> number
		local i = 0
		return function(): number
			i += 1
			return values[i] or 0.5
		end
	end

	--[[ The plants ]]

	-- A box corner turned by CFrame.Angles(rx, ry, rz) = Rx * Ry * Rz (degrees), as Plants' spec.
	local function turn(v: { number }, r: { number }): { number }
		local ax, ay, az = math.rad(r[1]), math.rad(r[2]), math.rad(r[3])
		local x, y, z = v[1], v[2], v[3]
		x, y = x * math.cos(az) - y * math.sin(az), x * math.sin(az) + y * math.cos(az)
		x, z = x * math.cos(ay) + z * math.sin(ay), -x * math.sin(ay) + z * math.cos(ay)
		y, z = y * math.cos(ax) - z * math.sin(ax), y * math.sin(ax) + z * math.cos(ax)
		return { x, y, z }
	end

	t.test("herbs: Mint and Wild Ginger are plants that their herb items place and drop", function()
		for block, item in HERBS do
			local def = Blocks.get(block)
			local name = def.name
			t.ok(Blocks.isPlant(block), `{name} is a plant`)
			t.eq(def.plant and def.plant.soil, "dirt", `{name} grows on the dirt set`)
			t.eq(def.behaviour, "Herb", `{name} spreads`)
			t.ok(not def.placeable and table.find(Blocks.placeable, block) == nil, `{name} is no item of its own`)
			t.eq(Items.get(block), nil, `{name} has no block item`)
			t.ok(not def.solid and def.hardness == 0 and def.brokenByFluid, `{name} breaks like a flower`)
			t.eq(Blocks.soundType(block), "grass")
			t.ok(def.scatter and def.support == "Down")
			t.ok(Blocks.igniteOdds(block) == 60 and Blocks.burnOdds(block) == 100, `{name} burns like a flower`)
			t.eq(def.textures and def.textures.sprite, string.lower(def.displayName or name), `{name} sprite`)
			-- The herb item: places it (ItemNameBlockItem), is what it drops and what pick block takes.
			local herb = Items.get(item) :: Items.ItemDef
			t.eq(herb.block, block, `{herb.name} places {name}`)
			t.ok(herb.model ~= nil and #herb.model > 0, `{herb.name} is drawn from its own boxes`)
			t.eq(Items.ofBlock(block), item, `{name}'s item`)
			for _, tool in { nil :: number?, I.Shears, I.IronAxe } do
				local drop = Items.drops(block, tool) :: Items.Stack
				t.ok(drop and drop.item == item and drop.count == 1, `{name} drops one {herb.name}`)
			end
			t.eq((Items.blockDrops(block) :: Items.Stack).item, item, "popping off too")
			t.eq(EditRules.drops(block, true, nil), nil, "creative: nothing")
			t.ok(not Items.isReplacedBy(block, item), "its own item goes beside it")
			t.ok(Items.isReplacedBy(B.ShortGrass, item), "short grass is planted over")
			-- At most 4 boxes, inside the outline whichever way the scatter turns it.
			local shape = def.shape :: { Blocks.ShapeBox }
			t.ok(#shape >= 1 and #shape <= 4, `{name}: {#shape} boxes`)
			local b = def.bounds
			local half = math.min(8 - b.min[1], b.max[1] - 8, 8 - b.min[3], b.max[3] - 8)
			for i, box in shape do
				t.ok(box.material == "SmoothPlastic" and box.color ~= nil, `{name} box {i} look`)
				for _, sx in { -1, 1 } do
					for _, sy in { -1, 1 } do
						for _, sz in { -1, 1 } do
							local c = turn(
								{ box.size[1] / 2 * sx, box.size[2] / 2 * sy, box.size[3] / 2 * sz },
								box.rotation or { 0, 0, 0 }
							)
							local x, y, z = c[1] + box.offset[1], c[2] + box.offset[2], c[3] + box.offset[3]
							t.ok(math.sqrt(x ^ 2 + z ^ 2) <= half + 1e-9, `{name} box {i} leaves the outline`)
							t.ok(math.sqrt(x ^ 2 + z ^ 2) + 3 <= 9, `{name} box {i} scattered out of its cell`)
							t.ok(y >= -9 and y <= b.max[2] - 8 + 1e-9, `{name} box {i} height {y}`)
						end
					end
				end
			end
		end
		t.eq(Blocks.get(MINT).displayName, "Mint")
		t.eq(Blocks.get(GINGER).displayName, "Wild Ginger")
		t.eq(Items.displayName(I.MintLeaves), "Mint Leaves")
		t.eq(Items.displayName(I.GingerRoot), "Ginger Root")
	end)

	t.test("herbs: planted back by their items on dirt and grass, survival uses one up", function()
		local function world(soil: number)
			return function(x: number, y: number, z: number): number?
				return if y == 9 then soil else AIR
			end
		end
		for block, item in HERBS do
			t.ok(EditRules.mayPlace(block, AIR), `{Blocks.get(block).name} may be placed`)
			t.ok(EditRules.mayPlace(block, B.ShortGrass), "over short grass")
			t.ok(not EditRules.mayPlace(block, block), "not into itself")
			for _, soil in { GRASS, B.Dirt, B.Podzol, B.CoarseDirt } do
				t.ok(EditRules.supported(block, world(soil), 0, 10, 0), `on {Blocks.get(soil).name}`)
				t.eq(Blocks.placementFor(block, 0, 1, 0, 0, -1, 0, world(soil), 0, 10, 0), block, "the plant itself")
			end
			for _, soil in { STONE, B.Sand, AIR } do
				t.ok(not EditRules.supported(block, world(soil), 0, 10, 0), `not on {Blocks.get(soil).name}`)
				t.eq(Blocks.placementFor(block, 0, 1, 0, 0, -1, 0, world(soil), 0, 10, 0), nil)
			end
			-- Survival: the held herb is used up; anything else held refuses it.
			local state = InventoryState.new()
			state:join("a")
			local inventory = state:window("a").inventory
			inventory.slots[1] = { item = item, count = 2 }
			local ok, from = state:place("a", block, 1, false)
			t.ok(ok and from and from.item == item, "placed from the herb")
			t.eq(inventory.slots[1].count, 1, "one used up")
			inventory.slots[1] = { item = I.Stick, count = 2 }
			t.ok(not state:place("a", block, 2, false), "not from a stick")
		end
		-- Their plants are no block items, so a herb item is the only way to place them.
		t.ok(not EditRules.mayPlace(B.TallGrassTop, AIR), "(an upper half still never is)")
	end)

	--[[ Generation ]]

	-- Grows biome `index`'s plants on N x N flat chunks of its top block side by side (patches
	-- whole), from chunk (x0, z0): the herbs found, by (x, z).
	local place = Foliage.new(12345)
	local function flatHerbs(index: number, n: number, x0: number, z0: number): { [string]: number }
		local biome = Biomes.list[index]
		local found: { [string]: number } = {}
		for cx = x0, x0 + n - 1 do
			for cz = z0, z0 + n - 1 do
				local data = ChunkLayout.create(8)
				for pz = -1, SIZE do
					for px = -1, SIZE do
						ChunkLayout.setPadded(data, px, 0, pz, B.Bedrock)
						ChunkLayout.setPadded(data, px, 1, pz, biome.top)
					end
				end
				local ox, oz = cx * SIZE, cz * SIZE
				place(data, 8, ox, oz, table.create(P * P, index), table.create(P * P, 1))
				for lz = 0, SIZE - 1 do
					for lx = 0, SIZE - 1 do
						local block = ChunkLayout.get(data, lx, 2, lz)
						if HERBS[block] then
							found[`{ox + lx},{oz + lz}`] = block
						end
					end
				end
			end
		end
		return found
	end

	-- Herbs within 4 blocks of each other: the sizes of the patches.
	local function patches(found: { [string]: number }): { number }
		local seen: { [string]: boolean } = {}
		local sizes = {}
		for key in found do
			if not seen[key] then
				seen[key] = true
				local stack, size = { key }, 0
				while #stack > 0 do
					local x, z = string.match(table.remove(stack) :: string, "(-?%d+),(-?%d+)")
					size += 1
					for dx = -4, 4 do
						for dz = -4, 4 do
							local other = `{tonumber(x) :: number + dx},{tonumber(z) :: number + dz}`
							if found[other] and not seen[other] then
								seen[other] = true
								table.insert(stack, other)
							end
						end
					end
				end
				table.insert(sizes, size)
			end
		end
		return sizes
	end

	local GROWS = {
		Plains = MINT,
		Meadow = MINT,
		Jungle = MINT,
		Forest = GINGER,
		BirchForest = GINGER,
		Taiga = GINGER,
		OldGrowthTaiga = GINGER,
	}

	t.test("herbs: rare patches of mint on grassland, of wild ginger in forests and taigas", function()
		for index, biome in Biomes.list do
			local herbs = biome.foliage and biome.foliage.herbs
			local expected = GROWS[biome.name]
			t.eq(herbs ~= nil, expected ~= nil, `{biome.name} grows herbs`)
			if herbs and expected then
				t.eq(#herbs.blocks, 1)
				t.eq(herbs.blocks[1], expected, `{biome.name} grows {Blocks.get(expected).name}`)
			end
		end
		-- On open ground, 9 squares of 8 x 8 chunks far apart (147 456 columns), measured on the
		-- seed.
		for _, name in { "Plains", "Taiga", "Forest", "Jungle" } do
			local biome = Biomes.byName(name) :: Biomes.Biome
			local count, patchCount = 0, 0
			for i = 0, 8 do
				local found = flatHerbs(biome.index, 8, (i % 3) * 600 - 600, (i // 3) * 700 - 700)
				for _, block in found do
					count += 1
					t.eq(block, GROWS[name], `only {Blocks.get(GROWS[name]).name} in {name}`)
				end
				patchCount += #patches(found)
			end
			local area = 9 * (8 * SIZE) ^ 2
			t.near(count / area, (biome.foliage :: Biomes.Foliage).herbChance, 0.0012, `{name}: {count} herbs`)
			local mean = count / patchCount
			t.ok(mean >= 2.5 and mean <= 8, `{name}: {patchCount} patches of {mean} herbs on average`)
			-- One patch per 20..45 blocks square: rare, but a walk away.
			local spacing = math.sqrt(area / patchCount)
			t.ok(spacing >= 20 and spacing <= 45, `{name}: a patch every {spacing} blocks`)
		end
	end)

	t.test("herbs: generated terrain grows each herb only where its biome is", function()
		local gen = TerrainGenerator.new(12345)
		local rng = Hash.rng(77)
		local wanted: { [string]: number } = {}
		local chunks: { { number } } = {}
		for _ = 1, 6000 do
			local cx, cz = rng:int(-3000, 3000), rng:int(-3000, 3000)
			local h, index = gen.column(cx * SIZE + 8, cz * SIZE + 8)
			local name = Biomes.list[index].name
			if GROWS[name] and (wanted[name] or 0) < 5 and h > Config.SeaLevel + 2 then
				wanted[name] = (wanted[name] or 0) + 1
				table.insert(chunks, { cx, cz })
			end
		end
		local counts: { [number]: number } = { [MINT] = 0, [GINGER] = 0 }
		for _, c in chunks do
			local r = gen.generate(0, c[1], c[2])
			for lz = 0, SIZE - 1 do
				for lx = 0, SIZE - 1 do
					local x, z = c[1] * SIZE + lx, c[2] * SIZE + lz
					local h, index = gen.column(x, z)
					local block = if h < r.height then ChunkLayout.get(r.data, lx, h, lz) else AIR
					if HERBS[block] then
						counts[block] += 1
						local biome = Biomes.list[index]
						t.eq(GROWS[biome.name], block, `{Blocks.get(block).name} in {biome.name}`)
						t.ok(Blocks.mayPlaceOn(block, ChunkLayout.get(r.data, lx, h - 1, lz)), "on its soil")
					end
				end
			end
		end
		t.ok(#chunks >= 30, `chunks sampled: {#chunks}`)
		t.ok(counts[MINT] > 0, `mint grown: {counts[MINT]}`)
		t.ok(counts[GINGER] > 0, `wild ginger grown: {counts[GINGER]}`)
	end)

	--[[ Spreading (Behaviours/Herb, MushroomBlock.randomTick) ]]

	local FLOOR = 10
	local flat = {
		generate = function(level: number, nx: number, nz: number)
			local data = ChunkLayout.create(32)
			for y = 0, FLOOR - 1 do
				local block = if y == FLOOR - 1 then GRASS else STONE
				for i = 0, ChunkLayout.LAYER - 1 do
					buffer.writeu16(data, (y * ChunkLayout.LAYER + i) * 2, block)
				end
			end
			return {
				data = data,
				level = level,
				nx = nx,
				nz = nz,
				height = 32,
				solidBelow = FLOOR,
				emptyAbove = FLOOR,
			}
		end,
		column = function()
			return FLOOR, 1, 0, GRASS
		end,
		findSpawn = function()
			return 0, FLOOR, 0
		end,
	}
	local function newWorld()
		local world = WorldServer.new(flat :: any)
		local ticker = BlockTicker.new(world, Behaviours.byId, 100000)
		world.onChanged = function(x, y, z)
			ticker:blockChanged(x, y, z)
		end
		local dropped: { Items.Stack } = {}
		Drops.set(function(_x, _y, _z, stack)
			table.insert(dropped, stack)
		end)
		for cx = -1, 1 do
			for cz = -1, 1 do
				world:getChunk(cx, cz)
			end
		end
		return world, ticker, dropped
	end
	local function count(world: any, block: number): number
		local n = 0
		for x = -12, 28 do
			for z = -12, 28 do
				for y = FLOOR - 1, FLOOR + 1 do
					if world:peekBlock(x, y, z) == block then
						n += 1
					end
				end
			end
		end
		return n
	end

	t.test("herbs: spread like Minecraft's mushrooms, up to 5 in 9 x 3 x 9, onto their soil", function()
		local world, ticker = newWorld()
		t.eq(Behaviours.byId[MINT], Herb)
		t.eq(Herb.onTick, Plant.onTick, "kept up like any plant")
		t.ok(RandomTicker.new(world, ticker).ticking[GINGER] ~= nil, "random ticks reach them")
		world:setBlock(8, FLOOR, 8, MINT)
		-- A roll above the chance: nothing.
		Herb.onRandomTick(world, ticker, 8, FLOOR, 8, MINT, rolls({ Config.Server.HerbSpread + 0.01 }))
		t.eq(count(world, MINT), 1, "lost the roll")
		-- Steps of +1 x (0.9 -> 1; 0.5, 0.5 -> dy 0; 0.5 -> dz 0) walk east onto grass.
		local x, y, z = Herb.spread(world, 8, FLOOR, 8, MINT, rolls({ 0.9, 0.5, 0.5, 0.5 }))
		t.ok(x ~= nil and y == FLOOR, "grew")
		t.eq(world:getBlock(x :: number, FLOOR, z :: number), MINT)
		t.eq(count(world, MINT), 2)
		-- Not onto stone: the walk stays where it may stand, the end must be soil.
		local w2 = newWorld()
		w2:setBlock(8, FLOOR, 8, GINGER)
		for dx = -6, 6 do
			for dz = -6, 6 do
				if dx ~= 0 or dz ~= 0 then
					w2:setBlock(8 + dx, FLOOR - 1, 8 + dz, STONE)
				end
			end
		end
		for _ = 1, 50 do
			Herb.spread(w2, 8, FLOOR, 8, GINGER, math.random)
		end
		t.eq(count(w2, GINGER), 1, "no soil around: no spreading")
		-- Many random ticks: a patch, at most 5 within 4 blocks of each, all on grass.
		local w3, ticker3 = newWorld()
		w3:setBlock(8, FLOOR, 8, MINT)
		local seed = 5
		local function rand(): number
			seed = (seed * 1103515245 + 12345) % 2147483648
			return seed / 2147483648
		end
		for _ = 1, 3000 do
			for px = -4, 20 do
				for pz = -4, 20 do
					if w3:peekBlock(px, FLOOR, pz) == MINT then
						Herb.onRandomTick(w3, ticker3, px, FLOOR, pz, MINT, rand)
					end
				end
			end
			if count(w3, MINT) >= 8 then
				break
			end
		end
		local grown = count(w3, MINT)
		t.ok(grown >= 5, `a patch: {grown}`)
		for px = -12, 28 do
			for pz = -12, 28 do
				if w3:peekBlock(px, FLOOR, pz) == MINT then
					t.eq(w3:peekBlock(px, FLOOR - 1, pz), GRASS, "on grass")
				end
			end
		end
		-- Hemmed in: 5 within the box stops it.
		local w4 = newWorld()
		for i = 0, 4 do
			w4:setBlock(4 + i * 2, FLOOR, 8, MINT)
		end
		for _ = 1, 40 do
			t.eq(Herb.spread(w4, 8, FLOOR, 8, MINT, math.random), nil)
		end
		t.eq(count(w4, MINT), 5, "5 around: no more")
		-- It pops off with its herb when its soil goes.
		local w5, ticker5, dropped = newWorld()
		w5:setBlock(8, FLOOR, 8, GINGER)
		w5:setBlock(8, FLOOR - 1, 8, AIR)
		for _ = 1, 5 do
			ticker5:step()
		end
		t.eq(w5:getBlock(8, FLOOR, 8), AIR)
		t.ok(#dropped == 1 and dropped[1].item == I.GingerRoot, "dropped its root")
	end)

	--[[ Bowls ]]

	-- A crafting grid from { [slot] = item }.
	local function craft(cells: { [number]: number }, width: number): Items.Stack?
		local grid = {}
		for slot, item in cells do
			grid[slot] = { item = item, count = 1 }
		end
		return Crafting.match(grid, width)
	end

	t.test("bowls: three planks in a V make four; they fill at water and give the bowl back", function()
		local bowls = craft({ [1] = I.Planks, [3] = I.BirchPlanks, [5] = I.SprucePlanks }, 3) :: Items.Stack
		t.ok(bowls and bowls.item == I.Bowl and bowls.count == 4, "any planks")
		t.eq(craft({ [4] = I.Planks, [6] = I.Planks, [8] = I.Planks }, 3).item, I.Bowl, "lower down too")
		t.eq(craft({ [1] = I.Planks, [2] = I.Planks, [3] = I.Planks }, 3), nil, "a row is no bowl")
		t.eq(Smelting.fuel(I.Bowl), 100, "a bowl burns 100 ticks")
		t.eq(Items.maxStack(I.Bowl), 64)
		t.eq(Items.maxStack(I.DirtyWaterBowl), 16)
		t.eq(Items.maxStack(I.PurifiedWaterBowl), 16)
		-- Filling (Drinks' tables): a bowl at water is a dirty water bowl.
		t.ok(Drinks.isContainer(I.Bowl) and Drinks.isWaterItem(I.Bowl))
		t.eq(Drinks.action({ item = I.Bowl, count = 3 }, true, true, true), "fill")
		t.eq(Drinks.action({ item = I.Bowl, count = 3 }, false, true, true), nil, "nothing to fill from")
		local held, extra = Drinks.fill({ item = I.Bowl, count = 3 }, false, function()
			return false
		end)
		t.eq((held :: Items.Stack).count, 2, "one bowl used")
		t.eq((extra :: Items.Stack).item, I.DirtyWaterBowl, "the full one goes into the inventory")
		held = Drinks.fill({ item = I.Bowl, count = 1 }, false, function()
			return false
		end)
		t.eq((held :: Items.Stack).item, I.DirtyWaterBowl, "the last one fills in the hand")
		-- Drinking: one is used up and the Bowl comes back.
		for _, full in { I.DirtyWaterBowl, I.PurifiedWaterBowl, I.MintTea, I.GingerTea, I.HerbalTea } do
			t.ok(Drinks.isDrink(full), `{Items.displayName(full)} is a drink`)
			t.eq(Drinks.emptyOf(full), I.Bowl, "its bowl back")
			t.eq(Drinks.action({ item = full, count = 1 }, true, true, true), "drink", "drunk, at water too")
			local after, back = Drinks.afterDrinking({ item = full, count = 1 }, false)
			t.eq((after :: Items.Stack).item, I.Bowl, "the last leaves the bowl in hand")
			t.eq(back, nil)
			local same = Drinks.afterDrinking({ item = full, count = 1 }, true)
			t.eq((same :: Items.Stack).item, full, "creative drinks for nothing")
		end
		local after, back = Drinks.afterDrinking({ item = I.PurifiedWaterBowl, count = 3 }, false)
		t.eq((after :: Items.Stack).count, 2)
		t.eq((back :: Items.Stack).item, I.Bowl, "the bowl into the inventory")
		-- A bowl holds a little more than a bottle.
		local dirty, purified = Drinks.of(I.DirtyWaterBowl) :: any, Drinks.of(I.PurifiedWaterBowl) :: any
		t.ok(dirty.thirst >= Drinks.DIRTY.thirst and dirty.hydration > Drinks.DIRTY.hydration)
		t.ok(purified.thirst > Drinks.PURIFIED.thirst and purified.hydration > Drinks.PURIFIED.hydration)
		t.eq(dirty.chance, 0.5, "dirty water's risk")
		t.eq(purified.chance, 0)
		local state = Thirst.new()
		state.thirst, state.hydration = 5, 0
		t.ok(not Drinks.apply(state, purified, rolls({})))
		t.eq(state.thirst, 12, "a purified bowl: 7")
	end)

	t.test("bowls: mint cures dirty water in a grid; a furnace purifies a bowl too", function()
		for dirty, purified in Drinks.PURIFIED_OF do
			local cured = craft({ [1] = dirty, [4] = I.MintLeaves }, 2)
			t.eq(cured and cured.item, purified, `{Items.displayName(dirty)} + Mint Leaves, in the 2 x 2 grid`)
			t.eq(cured and cured.count, 1)
			t.eq(craft({ [9] = I.MintLeaves, [2] = dirty }, 3).item, purified, "any slots")
			t.eq((Smelting.result(dirty) :: Items.Stack).item, purified, "and smelting")
		end
		t.eq(craft({ [1] = I.DirtyWaterBottle, [2] = I.GingerRoot }, 2), nil, "ginger cures nothing")
		-- A part-drunk canteen keeps its sips (as boiled on a campfire): mint cures water, it never
		-- makes more of it.
		for _, at in { { 1, 4 }, { 4, 1 } } do
			local grid = {
				[at[1]] = { item = I.DirtyWaterCanteen, count = 1, damage = 2 },
				[at[2]] = { item = I.MintLeaves, count = 1 },
			}
			local cured = Crafting.match(grid, 2) :: Items.Stack
			t.eq(cured.item, I.PurifiedWaterCanteen)
			t.eq(cured.damage, 2, "one sip left, as before")
			t.eq(Drinks.sips(cured), 1)
		end
		local fresh = craft({ [1] = I.DirtyWaterCanteen, [2] = I.MintLeaves }, 2) :: Items.Stack
		t.eq(fresh.damage, nil, "a full one stays full")
		t.eq(Drinks.sips(fresh), 3)
		t.eq(
			Boiling.boil({ item = I.DirtyWaterCanteen, count = 1, damage = 2 }, false, function()
				return false
			end).damage,
			2,
			"the campfire's rule"
		)
		local leaves = Crafting.match({
			{ item = I.DirtyWaterBottle, count = 1, damage = 5 },
			{ item = I.MintLeaves, count = 1 },
		}, 2) :: Items.Stack
		t.eq(leaves.damage, nil, "wear only where the result wears (a bottle doesn't)")
		t.eq(Drinks.purifiedOf(I.DirtyWaterBowl), I.PurifiedWaterBowl)
		t.ok(Drinks.isDirty(I.DirtyWaterBowl) and not Drinks.isDirty(I.PurifiedWaterBowl))
		-- A furnace with coal purifies a stack of dirty bowls one by one.
		local furnace = {
			slots = { { item = I.DirtyWaterBowl, count = 2 }, { item = I.Coal, count = 1 } } :: { [number]: Items.Stack? },
			data = nil :: { number }?,
		}
		for _ = 1, Smelting.COOK_TIME * 2 do
			Smelting.tick(furnace)
		end
		t.eq(furnace.slots[1], nil, "both cooked")
		t.eq((furnace.slots[3] :: Items.Stack).item, I.PurifiedWaterBowl)
		t.eq((furnace.slots[3] :: Items.Stack).count, 2)
	end)

	t.test("teas: brewed from a purified water bowl and a herb; chill, warmth or both", function()
		local function brew(...: number): Items.Stack?
			local cells = {}
			for i, item in { ... } do
				cells[i] = item
			end
			return craft(cells, 2)
		end
		t.eq((brew(I.PurifiedWaterBowl, I.MintLeaves) :: Items.Stack).item, I.MintTea)
		t.eq((brew(I.GingerRoot, I.PurifiedWaterBowl) :: Items.Stack).item, I.GingerTea)
		t.eq((brew(I.MintLeaves, I.PurifiedWaterBowl, I.GingerRoot) :: Items.Stack).item, I.HerbalTea)
		t.eq((brew(I.DirtyWaterBowl, I.GingerRoot)), nil, "dirty water brews nothing")
		t.eq((brew(I.PurifiedWaterBottle, I.MintLeaves)), nil, "a tea is a bowl's")
		for _, tea in { I.MintTea, I.GingerTea, I.HerbalTea } do
			t.eq(Items.maxStack(tea), 1, `{Items.displayName(tea)} stacks to 1, like a stew`)
			local drink = Drinks.of(tea) :: any
			t.eq(drink.chance, 0, "no Thirst effect")
			t.ok(drink.thirst >= Drinks.PURIFIED_BOWL.thirst, "never less than its water")
			t.ok(drink.hydration > Drinks.PURIFIED_BOWL.hydration, "more hydration")
		end
		-- Drinking them: Internal Chill / Warmth for the body (2 minutes; herbal tea 1 of each).
		local function drink(tea: number): (any, any)
			local thirst, body = Thirst.new(), Temperature.new()
			thirst.thirst, thirst.hydration = 4, 0
			Drinks.apply(thirst, Drinks.of(tea) :: any, rolls({}), body)
			return thirst, body
		end
		local thirst, body = drink(I.MintTea)
		t.eq(body.chill, 2400, "mint: 2 minutes of Internal Chill")
		t.eq(body.warmth, 0)
		t.eq(thirst.thirst, 11)
		t.near(thirst.hydration, 7 * 0.6 * 2, 1e-9)
		t.eq(Temperature.adjusted(body, 9), 4, "the desert's 9 held at 4: no heat stroke")
		thirst, body = drink(I.GingerTea)
		t.eq(body.warmth, 2400, "ginger: 2 minutes of Internal Warmth")
		t.eq(body.chill, 0)
		t.eq(Temperature.adjusted(body, -10), -5, "the tundra's -10 held at -5: no freezing")
		t.eq(Temperature.zone(Temperature.adjusted(body, -10)), Temperature.COLD)
		thirst, body = drink(I.HerbalTea)
		t.eq(body.warmth, 1200)
		t.eq(body.chill, 1200)
		t.eq(thirst.thirst, 12)
		t.eq(Temperature.zone(Temperature.adjusted(body, -10)), Temperature.COLD, "no icy")
		t.eq(Temperature.zone(Temperature.adjusted(body, 10)), Temperature.WARM, "no hot")

		-- A tea is drunk for its warmth or chill whenever temperature is on: not thirsty (a full
		-- respawn), or with thirst off (Drinks.drinkable: thirsty, thirst on, temperature on).
		for _, tea in { I.MintTea, I.GingerTea, I.HerbalTea } do
			local name, it = Items.displayName(tea), Drinks.of(tea)
			t.ok(Drinks.tempers(it), `{name} tempers`)
			t.ok(Drinks.drinkable(it, false, true, true), `{name}: drunk with full thirst`)
			t.ok(Drinks.drinkable(it, false, false, true), `{name}: drunk with thirst off`)
			t.ok(not Drinks.drinkable(it, false, true, false), `{name}: not with full thirst and temperature off`)
			t.ok(Drinks.drinkable(it, true, true, false), `{name}: as water with temperature off`)
			t.eq(
				Drinks.action({ item = tea, count = 1 }, false, Drinks.drinkable(it, false, true, true), true),
				"drink",
				`{name}: a right click with full thirst drinks it`
			)
		end
		for _, water in { I.PurifiedWaterBowl, I.DirtyWaterBottle, I.PurifiedWaterCanteen } do
			local name, it = Items.displayName(water), Drinks.of(water)
			t.ok(not Drinks.tempers(it), `{name} doesn't temper`)
			t.ok(not Drinks.drinkable(it, false, true, true), `{name}: only while thirsty`)
			t.ok(not Drinks.drinkable(it, true, false, true), `{name}: never with thirst off`)
			t.ok(Drinks.drinkable(it, true, true, false))
		end
		t.ok(not Drinks.drinkable(Drinks.HAND, false, true, true), "a sip from the water: only while thirsty")
		t.ok(not Drinks.drinkable(nil, true, true, true), "no drink")
		-- With thirst off, a tea gives only its warmth or chill (no thirst state).
		local warmOnly = Temperature.new()
		t.ok(not Drinks.apply(nil, Drinks.of(I.GingerTea) :: any, rolls({ 0 }), warmOnly))
		t.eq(warmOnly.warmth, 2400, "warmth without thirst")
		t.ok(not Drinks.apply(nil, Drinks.DIRTY, rolls({ 0 })), "no Thirst effect without thirst")
	end)

	--[[ What the screens show ]]

	t.test("herbs and bowls in JEI, WAILA and the creative inventory", function()
		local function categories(groups: { JeiData.Group }): { [string]: number }
			local out = {}
			for _, group in groups do
				out[group.category] = #group.entries
			end
			return out
		end
		t.eq(categories(JeiData.recipes(I.Bowl)).crafting, 1, "the bowl's recipe")
		t.eq(categories(JeiData.uses(I.Bowl)).fuel, 1, "a fuel")
		local purified = categories(JeiData.recipes(I.PurifiedWaterBowl))
		t.eq(purified.crafting, 1, "mint")
		t.eq(purified.smelting, 1, "the furnace")
		-- Mint Leaves: the three cures, Mint Tea and Herbal Tea.
		t.eq(categories(JeiData.uses(I.MintLeaves)).crafting, 5)
		t.eq(categories(JeiData.uses(I.GingerRoot)).crafting, 2)
		t.eq(categories(JeiData.uses(I.PurifiedWaterBowl)).crafting, 3, "the three teas")
		t.ok(JeiData.has("recipes", I.HerbalTea))
		-- WAILA: the plant's name, its herb's icon.
		t.eq(WailaInfo.blockName(MINT), "Mint")
		t.eq(WailaInfo.blockName(GINGER), "Wild Ginger")
		t.eq(WailaInfo.blockIcon(MINT).item, I.MintLeaves)
		t.eq(WailaInfo.blockIcon(GINGER).item, I.GingerRoot)
		-- The creative inventory lists the items, not the plants.
		local listed: { [number]: boolean } = {}
		for _, def in Items.list do
			listed[def.id] = true
		end
		for _, item in { I.MintLeaves, I.GingerRoot, I.Bowl, I.DirtyWaterBowl, I.PurifiedWaterBowl } do
			t.ok(listed[item], `{Items.displayName(item)} is listed`)
		end
		for _, item in { I.MintTea, I.GingerTea, I.HerbalTea } do
			t.ok(listed[item], `{Items.displayName(item)} is listed`)
		end
		t.ok(not listed[MINT] and not listed[GINGER], "the plants are no items")
		local found = Items.search("mint")
		t.ok(#found >= 2, "search finds the mint items")
	end)
end
