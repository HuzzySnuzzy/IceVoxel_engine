--[[
	Plants on the server: the Plant behaviour (popping off when their soil or other half goes, with
	their drops, once per tall plant; waiting for unloaded blocks), the edit rules for plants
	(upper halves are never placed by players, tall plants need room for their top, placing sets
	both halves, breaking either half removes both with one drop from the lower half, the breaker's
	tool and one wear), building over replaceable plants, water washing them away and a water
	bucket poured into them (UseRules.pour), falling sand and gravel replacing or breaking on them,
	and the rules that need no change: safe spots in plants, the sky through them, grass under them.
]]

return function(t, shared, require, server)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local Config = require(shared.Config)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local WorldServer = require(server.World.WorldServer)
	local BlockTicker = require(server.World.BlockTicker)
	local Behaviours = require(server.Behaviours)
	local Plant = require(server.Behaviours.Plant)
	local Drops = require(server.Behaviours.Drops)
	local EditRules = require(server.Network.EditRules)
	local UseRules = require(server.Transmitters.UseRules)
	local InventoryState = require(server.Players.InventoryState)

	local B, I = Blocks.id, Items.id
	local AIR, STONE, GRASS, SAND = Blocks.AIR, B.Stone, B.Grass, B.Sand
	local WATER = Blocks.fluidId("Water", 0)
	local SHEARS = I.Shears
	local HEIGHT = Config.WorldHeight

	local TALL = {
		TallGrass = "TallGrassTop",
		LargeFern = "LargeFernTop",
		Sunflower = "SunflowerTop",
		Lilac = "LilacTop",
		RoseBush = "RoseBushTop",
		Peony = "PeonyTop",
	}

	-- A sparse world for the pure rules: unset blocks are air, `false` = not loaded.
	local function sparse(blocks: { [string]: number | false })
		return function(x: number, y: number, z: number): number?
			local b = blocks[`{x},{y},{z}`]
			if b == false then
				return nil
			end
			return b or AIR
		end
	end

	--[[ A flat world: stone, grass on top at FLOOR - 1, air from FLOOR up ]]

	local FLOOR = 10
	local CROP = 32
	local flat = {
		generate = function(level: number, nx: number, nz: number)
			local data = ChunkLayout.create(CROP)
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
				height = CROP,
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

	type Drop = { x: number, y: number, z: number, item: number, count: number }

	-- The flat world with block updates; drops are collected in `dropped`.
	local function newWorld()
		local world = WorldServer.new(flat :: any)
		local ticker = BlockTicker.new(world, Behaviours.byId, 100000)
		world.onChanged = function(x, y, z)
			ticker:blockChanged(x, y, z)
		end
		local dropped: { Drop } = {}
		Drops.set(function(x, y, z, stack)
			table.insert(dropped, { x = x, y = y, z = z, item = stack.item, count = stack.count })
		end)
		local function settle()
			for _ = 1, 2000 do
				ticker:step()
				if ticker:pendingCount() == 0 then
					return
				end
			end
			error("block updates never settled")
		end
		for cx = -1, 1 do
			for cz = -1, 1 do
				world:getChunk(cx, cz)
			end
		end
		return world, settle, dropped, ticker
	end

	-- A tall plant `lower` at (x, FLOOR, z), both halves.
	local function tall(world, x: number, z: number, lower: number)
		world:setBlock(x, FLOOR, z, lower)
		world:setBlock(x, FLOOR + 1, z, Blocks.plantTop(lower) :: number)
	end

	-- "item x count" per drop, sorted.
	local function summary(dropped: { Drop }): string
		local list = {}
		for _, drop in dropped do
			table.insert(list, `{Items.get(drop.item).name} x{drop.count}`)
		end
		table.sort(list)
		return table.concat(list, ", ")
	end

	local function name(world, x: number, y: number, z: number): string
		return Blocks.get(world:getBlock(x, y, z)).name
	end

	--[[ The Plant behaviour ]]

	t.test("plant behaviour: every plant has it; what keeps a plant up (Plant.stays)", function()
		local plants = 0
		for block = 0, Blocks.count - 1 do
			if Blocks.isPlant(block) then
				plants += 1
				local behaviour = Behaviours.byId[block]
				if string.sub(Blocks.get(block).name, -7) == "Sapling" then
					-- (Saplings also grow: Behaviours/Sapling keeps them up with Plant's tick.)
					t.eq((behaviour :: any).onTick, Plant.onTick, `{Blocks.get(block).name} stays up like a plant`)
				else
					t.eq(behaviour, Plant, `{Blocks.get(block).name} runs the Plant behaviour`)
				end
			end
		end
		t.eq(plants, 34, "29 plants and the 5 saplings")
		t.eq(Plant.tickDelay, 1)

		local function stays(block: number, blocks: { [string]: number | false }): boolean?
			return Plant.stays(block, sparse(blocks), 0, 5, 0)
		end
		t.eq(stays(B.Dandelion, { ["0,4,0"] = GRASS }), true, "a flower on grass")
		t.eq(stays(B.Dandelion, { ["0,4,0"] = STONE }), false, "not on stone")
		t.eq(stays(B.Dandelion, {}), false, "nor in the air")
		t.eq(stays(B.DeadBush, { ["0,4,0"] = SAND }), true, "a dead bush on sand")
		t.eq(stays(B.ShortGrass, { ["0,4,0"] = SAND }), false, "grass not on sand")
		t.eq(stays(B.RedMushroom, { ["0,4,0"] = STONE }), true, "a mushroom on stone")
		t.eq(stays(B.RedMushroom, { ["0,4,0"] = B.Glass }), false, "not on glass")
		-- Tall plants: the lower half needs its own top, the top its own lower half.
		t.eq(stays(B.Sunflower, { ["0,4,0"] = GRASS, ["0,6,0"] = B.SunflowerTop }), true)
		t.eq(stays(B.Sunflower, { ["0,4,0"] = GRASS }), false, "a lower half without its top")
		t.eq(stays(B.Sunflower, { ["0,4,0"] = GRASS, ["0,6,0"] = B.LilacTop }), false, "another plant's top")
		t.eq(stays(B.SunflowerTop, { ["0,4,0"] = B.Sunflower }), true)
		t.eq(stays(B.SunflowerTop, { ["0,4,0"] = GRASS }), false, "a top without its lower half")
		t.eq(stays(B.SunflowerTop, { ["0,4,0"] = B.Lilac }), false, "on another plant's lower half")
		-- Unloaded blocks are not guessed.
		t.eq(stays(B.Dandelion, { ["0,4,0"] = false }), nil)
		t.eq(stays(B.Sunflower, { ["0,4,0"] = GRASS, ["0,6,0"] = false }), nil)
		t.eq(stays(B.SunflowerTop, { ["0,4,0"] = false }), nil)
	end)

	t.test("plant behaviour: plants pop off with their drops when their soil goes", function()
		local world, settle, dropped = newWorld()
		world:setBlock(0, FLOOR, 0, B.Dandelion)
		world:setBlock(2, FLOOR, 0, B.ShortGrass)
		world:setBlock(4, FLOOR - 1, 0, SAND)
		world:setBlock(4, FLOOR, 0, B.DeadBush)
		world:setBlock(6, FLOOR - 1, 0, STONE)
		world:setBlock(6, FLOOR, 0, B.BrownMushroom)
		world:setBlock(8, FLOOR, 0, B.Poppy)
		settle()
		t.eq(#dropped, 0, "plants on their soil stay")
		t.eq(name(world, 0, FLOOR, 0), "Dandelion")
		t.eq(name(world, 4, FLOOR, 0), "DeadBush")
		t.eq(name(world, 6, FLOOR, 0), "BrownMushroom")

		-- A neighbour that is not the soil changes nothing; grass turned to dirt still holds them.
		world:setBlock(1, FLOOR, 0, STONE)
		world:setBlock(8, FLOOR - 1, 0, B.Dirt)
		settle()
		t.eq(name(world, 0, FLOOR, 0), "Dandelion")
		t.eq(name(world, 8, FLOOR, 0), "Poppy")

		world:setBlock(0, FLOOR - 1, 0, AIR)
		world:setBlock(2, FLOOR - 1, 0, STONE)
		world:setBlock(4, FLOOR - 1, 0, B.Glass)
		world:setBlock(6, FLOOR - 1, 0, B.Glass)
		world:setBlock(8, FLOOR - 1, 0, WATER)
		settle()
		for x = 0, 8, 2 do
			t.eq(world:getBlock(x, FLOOR, 0), AIR, `the plant at x = {x} popped`)
		end
		-- Short grass drops nothing without Shears, a dead bush a stick, flowers and mushrooms
		-- themselves, in the plant's cell.
		t.eq(summary(dropped), "BrownMushroom x1, Dandelion x1, Poppy x1, Stick x1")
		for _, drop in dropped do
			t.eq(drop.y, FLOOR)
		end
		Drops.set(nil)
	end)

	t.test("plant behaviour: a tall plant losing its soil drops once, from the lower half", function()
		local world, settle, dropped = newWorld()
		tall(world, 0, 0, B.Sunflower)
		tall(world, 2, 0, B.TallGrass)
		tall(world, 4, 0, B.Peony)
		settle()
		t.eq(#dropped, 0, "complete tall plants stay")
		t.eq(name(world, 0, FLOOR + 1, 0), "SunflowerTop")

		world:setBlock(0, FLOOR - 1, 0, AIR)
		world:setBlock(2, FLOOR - 1, 0, AIR)
		settle()
		t.eq(world:getBlock(0, FLOOR, 0), AIR)
		t.eq(world:getBlock(0, FLOOR + 1, 0), AIR, "the top went with it")
		t.eq(world:getBlock(2, FLOOR + 1, 0), AIR)
		t.eq(summary(dropped), "Sunflower x1", "one sunflower; tall grass drops nothing")
		t.eq(dropped[1].y, FLOOR, "where the lower half was")

		-- Its top removed (by anything but a player's break): the lower half pops and drops.
		table.clear(dropped)
		world:setBlock(4, FLOOR + 1, 0, AIR)
		settle()
		t.eq(world:getBlock(4, FLOOR, 0), AIR)
		t.eq(summary(dropped), "Peony x1")
		Drops.set(nil)
	end)

	t.test("plant behaviour: a half standing alone pops; only a lower half drops anything", function()
		local world, settle, dropped = newWorld()
		world:setBlock(0, FLOOR, 0, B.Lilac)
		world:setBlock(2, FLOOR, 0, B.LilacTop)
		world:setBlock(4, FLOOR + 1, 0, B.TallGrassTop)
		world:setBlock(6, FLOOR, 0, B.LargeFern)
		-- A top on the wrong lower half.
		world:setBlock(8, FLOOR, 0, B.RoseBush)
		world:setBlock(8, FLOOR + 1, 0, B.PeonyTop)
		settle()
		for x = 0, 8, 2 do
			t.eq(world:getBlock(x, FLOOR, 0), AIR, `x = {x}`)
			t.eq(world:getBlock(x, FLOOR + 1, 0), AIR, `x = {x}, above`)
		end
		-- (A lilac or rose bush lower half drops itself; tops, tall grass and large ferns nothing.)
		t.eq(summary(dropped), "Lilac x1, RoseBush x1")
		Drops.set(nil)
	end)

	t.test("plant behaviour: generated plants stay until a neighbour changes", function()
		-- (Block updates only run around changes: a plant the generator put down is never ticked
		-- until something next to it changes.)
		local world, settle, dropped, ticker = newWorld()
		world:setBlock(0, FLOOR, 0, B.Fern)
		settle()
		t.eq(ticker:pendingCount(), 0)
		world:setBlock(0, FLOOR - 1, 0, B.Podzol)
		t.ok(ticker:pendingCount() > 0, "the soil changing wakes it up")
		settle()
		t.eq(name(world, 0, FLOOR, 0), "Fern", "podzol holds a fern")
		t.eq(#dropped, 0)
		Drops.set(nil)
	end)

	--[[ Edits: placing ]]

	t.test("edits: upper halves are never placeable; plants go over replaceable plants", function()
		for lower, top in TALL do
			t.ok(EditRules.mayPlace(B[lower], AIR), `{lower} is placeable`)
			t.ok(not EditRules.mayPlace(B[top], AIR), `{top} is set by the server only`)
			t.ok(not EditRules.mayPlace(B[top], WATER), `{top} not into water either`)
		end
		t.ok(EditRules.mayPlace(B.Dandelion, AIR))
		t.ok(EditRules.mayPlace(B.Dandelion, B.ShortGrass), "over short grass")
		t.ok(EditRules.mayPlace(STONE, B.TallGrassTop), "anything over tall grass")
		t.ok(EditRules.mayPlace(STONE, B.DeadBush))
		t.ok(EditRules.mayPlace(B.Sunflower, B.TallGrass), "a tall flower over tall grass")
		t.ok(not EditRules.mayPlace(STONE, B.Dandelion), "flowers are not replaceable")
		t.ok(not EditRules.mayPlace(STONE, B.SunflowerTop))
		t.ok(not EditRules.mayPlace(STONE, B.RedMushroom))
		t.ok(not EditRules.mayPlace(B.ShortGrass, B.ShortGrass), "not the same block")
		t.ok(EditRules.mayPlace(B.Fern, B.ShortGrass))

		-- Items: placing a tall plant uses up its item; its top is no item of its own.
		local state = InventoryState.new()
		state:join("a")
		local inventory = state:window("a").inventory
		inventory.slots[1] = { item = I.Sunflower, count = 2 }
		t.ok(state:place("a", B.Sunflower, 1, false))
		t.eq(inventory.slots[1].count, 1)
		t.eq(Items.ofBlock(B.SunflowerTop), I.Sunflower)
	end)

	t.test("edits: plants need their soil, tall plants room for their top (EditRules.supported)", function()
		local function supported(block: number, blocks: { [string]: number | false }, y: number?): boolean
			return EditRules.supported(block, sparse(blocks), 0, y or 5, 0)
		end
		t.ok(supported(B.Poppy, { ["0,4,0"] = GRASS }))
		t.ok(supported(B.Poppy, { ["0,4,0"] = B.CoarseDirt }))
		t.ok(not supported(B.Poppy, { ["0,4,0"] = STONE }), "not on stone")
		t.ok(not supported(B.Poppy, { ["0,4,0"] = false }), "nor on an unloaded block")
		t.ok(supported(B.DeadBush, { ["0,4,0"] = SAND }))
		t.ok(supported(B.BrownMushroom, { ["0,4,0"] = B.Mycelium }))
		t.ok(supported(B.BrownMushroom, { ["0,4,0"] = B.Cobblestone }), "any sturdy opaque block")
		t.ok(not supported(B.BrownMushroom, { ["0,4,0"] = B.OakLeaves }))

		t.ok(supported(B.Lilac, { ["0,4,0"] = GRASS }), "room above")
		t.ok(supported(B.Lilac, { ["0,4,0"] = GRASS, ["0,6,0"] = B.ShortGrass }), "short grass makes room")
		t.ok(supported(B.Lilac, { ["0,4,0"] = GRASS, ["0,6,0"] = WATER }), "so does water")
		t.ok(not supported(B.Lilac, { ["0,4,0"] = GRASS, ["0,6,0"] = STONE }), "no room")
		t.ok(not supported(B.Lilac, { ["0,4,0"] = GRASS, ["0,6,0"] = B.Dandelion }), "a flower is in the way")
		t.ok(not supported(B.Lilac, { ["0,4,0"] = GRASS, ["0,6,0"] = false }), "above is not loaded")
		local top = HEIGHT - 1
		t.ok(not supported(B.Lilac, { [`0,{top - 1},0`] = GRASS }, top), "no room at the top of the world")
		t.ok(supported(B.Poppy, { [`0,{top - 1},0`] = GRASS }, top), "a short plant fits there")
		t.ok(not supported(B.LilacTop, { ["0,4,0"] = GRASS }), "an upper half alone")
		t.ok(EditRules.supported(STONE, sparse({}), 0, 5, 0), "stone needs nothing")
	end)

	t.test("edits: placing a tall plant sets both halves (EditRules.setPlaced)", function()
		local world, settle, dropped = newWorld()
		t.ok(EditRules.setPlaced(world, 0, FLOOR, 0, B.Sunflower))
		t.eq(name(world, 0, FLOOR, 0), "Sunflower")
		t.eq(name(world, 0, FLOOR + 1, 0), "SunflowerTop")
		-- Over short grass (top) and tall grass (both halves): replaced, nothing drops.
		world:setBlock(2, FLOOR + 1, 0, B.ShortGrass)
		tall(world, 4, 0, B.TallGrass)
		settle()
		t.ok(EditRules.setPlaced(world, 2, FLOOR, 0, B.Lilac))
		t.ok(EditRules.setPlaced(world, 4, FLOOR, 0, B.RoseBush))
		t.ok(EditRules.setPlaced(world, 6, FLOOR, 0, B.Dandelion), "single plants as they are")
		t.ok(EditRules.setPlaced(world, 8, FLOOR, 0, STONE))
		settle()
		t.eq(name(world, 2, FLOOR + 1, 0), "LilacTop")
		t.eq(name(world, 4, FLOOR, 0), "RoseBush")
		t.eq(name(world, 4, FLOOR + 1, 0), "RoseBushTop")
		t.eq(name(world, 6, FLOOR + 1, 0), "Air")
		t.eq(name(world, 0, FLOOR + 1, 0), "SunflowerTop", "they stay")
		t.eq(#dropped, 0)

		-- Without room for the top (it went since the check): nothing is set.
		local pending = #world:takePending()
		t.ok(pending > 0)
		world:setBlock(10, FLOOR + 1, 0, STONE)
		world:takePending()
		t.ok(not EditRules.setPlaced(world, 10, FLOOR, 0, B.Peony))
		t.eq(world:getBlock(10, FLOOR, 0), AIR)
		t.eq(#world:takePending(), 0, "no edit at all")
		Drops.set(nil)
	end)

	--[[ Edits: breaking ]]

	-- What ServerNet's performBreak does: the drop from the harvested block, then both halves go.
	local function playerBreak(world, x: number, y: number, z: number, creative: boolean, tool: number?)
		local current = world:getBlock(x, y, z)
		local peek = function(bx: number, by: number, bz: number): number?
			return world:peekBlock(bx, by, bz)
		end
		local block, by = EditRules.harvested(current, peek, x, y, z)
		local drop = EditRules.breakDrop(EditRules.newBlockData(), x, by, z, block, creative, tool)
		local removed = EditRules.removeBroken(world, x, y, z, current)
		return removed, drop, EditRules.wear(current, creative, tool)
	end

	t.test("edits: either half of a tall plant finds the other (EditRules.pairedHalf, harvested)", function()
		local world = sparse({ ["0,5,0"] = B.TallGrass, ["0,6,0"] = B.TallGrassTop, ["2,6,0"] = B.SunflowerTop })
		t.eq(EditRules.pairedHalf(B.TallGrass, world, 0, 5, 0), 6)
		t.eq(select(2, EditRules.pairedHalf(B.TallGrass, world, 0, 5, 0)), B.TallGrassTop)
		t.eq(EditRules.pairedHalf(B.TallGrassTop, world, 0, 6, 0), 5)
		t.eq(EditRules.pairedHalf(B.SunflowerTop, world, 2, 6, 0), nil, "alone")
		t.eq(EditRules.pairedHalf(B.Dandelion, world, 0, 5, 0), nil, "a single plant")
		t.eq(EditRules.pairedHalf(STONE, world, 0, 5, 0), nil)
		t.eq(EditRules.pairedHalf(B.TallGrass, sparse({ ["0,6,0"] = false }), 0, 5, 0), nil, "not loaded")

		local block, y = EditRules.harvested(B.TallGrassTop, world, 0, 6, 0)
		t.eq(block, B.TallGrass, "the top harvests the lower half")
		t.eq(y, 5)
		block, y = EditRules.harvested(B.TallGrass, world, 0, 5, 0)
		t.eq(block, B.TallGrass)
		t.eq(y, 5)
		block, y = EditRules.harvested(B.SunflowerTop, world, 2, 6, 0)
		t.eq(block, B.SunflowerTop, "a top alone harvests itself")
		t.eq(EditRules.drops(block, false, nil), nil, "which is nothing")
		block = EditRules.harvested(STONE, world, 9, 9, 9)
		t.eq(block, STONE)
	end)

	t.test("edits: breaking either half removes both, one drop by the lower half and the tool", function()
		local world, settle, dropped = newWorld()
		for x = 0, 14, 2 do
			tall(world, x, 0, if x < 8 then B.TallGrass else B.Sunflower)
		end
		settle()
		local function check(x: number, y: number, creative: boolean, tool: number?, expected: string?, wear: number)
			local removed, drop, worn = playerBreak(world, x, y, 0, creative, tool)
			t.ok(removed, `x = {x} removed`)
			t.eq(world:getBlock(x, FLOOR, 0), AIR, `x = {x} lower half`)
			t.eq(world:getBlock(x, FLOOR + 1, 0), AIR, `x = {x} upper half`)
			t.eq(if drop then `{Items.get(drop.item).name} x{drop.count}` else nil, expected, `x = {x} drop`)
			t.eq(worn, wear, `x = {x} wear`)
		end
		-- Tall grass: 2 short grass with Shears, from either half; by hand a Straw (Items.strawDrop:
		-- always from tall grass); Shears wear 1.
		check(0, FLOOR + 1, false, SHEARS, "ShortGrass x2", 1)
		check(2, FLOOR, false, SHEARS, "ShortGrass x2", 1)
		check(4, FLOOR + 1, false, nil, "Straw x1", 0)
		check(6, FLOOR + 1, true, SHEARS, nil, 0)
		-- A sunflower: itself from either half, whatever the tool; never in creative.
		check(8, FLOOR + 1, false, nil, "Sunflower x1", 0)
		check(10, FLOOR, false, I.DiamondPickaxe, "Sunflower x1", 0)
		check(12, FLOOR + 1, false, SHEARS, "Sunflower x1", 1)
		check(14, FLOOR + 1, true, nil, nil, 0)
		-- The other half went with it, so nothing pops afterwards.
		settle()
		t.eq(#dropped, 0, "no drop from block updates")

		-- Large ferns: 2 ferns.
		tall(world, 0, 2, B.LargeFern)
		local _, drop = playerBreak(world, 0, FLOOR + 1, 2, false, SHEARS)
		t.eq(drop and drop.item, I.Fern)
		t.eq(drop and drop.count, 2)

		-- A half alone (its other half already popped or not yet replicated): just that half.
		world:setBlock(0, FLOOR + 1, 4, B.PeonyTop)
		local removed, alone = playerBreak(world, 0, FLOOR + 1, 4, false, nil)
		t.ok(removed)
		t.eq(alone, nil, "an upper half drops nothing of its own")
		-- Single plants and other blocks are untouched by the rule.
		world:setBlock(2, FLOOR, 4, B.ShortGrass)
		world:setBlock(2, FLOOR + 1, 4, B.ShortGrass)
		local _, grass, worn = playerBreak(world, 2, FLOOR, 4, false, SHEARS)
		t.eq(grass and grass.item, I.ShortGrass)
		t.eq(worn, 1)
		t.eq(world:getBlock(2, FLOOR + 1, 4), B.ShortGrass, "the block above stays")
		t.ok(not EditRules.removeBroken(world, 4, FLOOR, 4, AIR), "nothing to break")
		Drops.set(nil)
	end)

	t.test("edits: Shears in hand wear once per tall plant and harvest it", function()
		local world, settle = newWorld()
		local state = InventoryState.new()
		state:join("a")
		local inventory = state:window("a").inventory
		inventory.slots[1] = { item = SHEARS, count = 1 }
		local durability = Items.get(SHEARS).durability :: number
		tall(world, 0, 0, B.TallGrass)
		settle()
		local held = state:heldStack("a")
		local _, drop, wear = playerBreak(world, 0, FLOOR + 1, 0, false, held and held.item)
		t.eq(drop and drop.count, 2)
		t.ok(not state:wearHeld("a", wear))
		local after = state:heldStack("a")
		t.ok(after ~= nil and after.item == SHEARS)
		t.eq((after :: any).damage, 1, "worn once for both halves")
		t.eq(durability, 238)
	end)

	t.test("edits: building over a replaceable plant replaces it; the other half pops", function()
		local world, settle, dropped = newWorld()
		world:setBlock(0, FLOOR, 0, B.DeadBush)
		tall(world, 2, 0, B.TallGrass)
		tall(world, 4, 0, B.LargeFern)
		settle()
		-- (EditRules.mayPlace said yes to all of these.)
		t.ok(EditRules.setPlaced(world, 0, FLOOR, 0, STONE))
		t.ok(EditRules.setPlaced(world, 2, FLOOR, 0, B.Planks), "over the lower half")
		t.ok(EditRules.setPlaced(world, 4, FLOOR + 1, 0, B.Glass), "over the upper half")
		settle()
		t.eq(name(world, 0, FLOOR, 0), "Stone")
		t.eq(name(world, 2, FLOOR, 0), "Planks")
		t.eq(name(world, 2, FLOOR + 1, 0), "Air", "the orphaned top popped")
		t.eq(name(world, 4, FLOOR, 0), "Air", "the orphaned lower half popped")
		t.eq(name(world, 4, FLOOR + 1, 0), "Glass")
		t.eq(#dropped, 0, "replaced plants drop nothing; tall grass and ferns drop nothing by themselves")

		-- A tall flower's top replaced by something else (an Api edit): the flower drops.
		tall(world, 6, 0, B.Lilac)
		settle()
		world:setBlock(6, FLOOR + 1, 0, STONE)
		settle()
		t.eq(name(world, 6, FLOOR, 0), "Air")
		t.eq(summary(dropped), "Lilac x1")
		Drops.set(nil)
	end)

	--[[ Water ]]

	t.test("water: flowing water washes plants away with their drops, a tall plant once", function()
		local world, settle, dropped = newWorld()
		world:setBlock(1, FLOOR, 0, B.Dandelion)
		world:setBlock(2, FLOOR, 0, B.ShortGrass)
		world:setBlock(0, FLOOR, 1, B.RedMushroom)
		world:setBlock(0, FLOOR - 1, 2, SAND)
		world:setBlock(0, FLOOR, 2, B.DeadBush)
		tall(world, 3, 0, B.Sunflower)
		tall(world, 0, 3, B.TallGrass)
		settle()
		world:setBlock(0, FLOOR, 0, WATER)
		settle()
		for _, cell in { { 1, 0 }, { 2, 0 }, { 0, 1 }, { 0, 2 }, { 3, 0 }, { 0, 3 } } do
			local block = world:getBlock(cell[1], FLOOR, cell[2])
			t.ok(Blocks.get(block).fluid ~= nil, `water took ({cell[1]}, {cell[2]})`)
		end
		t.eq(world:getBlock(3, FLOOR + 1, 0), AIR, "the sunflower's top went")
		t.eq(world:getBlock(0, FLOOR + 1, 3), AIR, "the tall grass's top went")
		t.eq(summary(dropped), "Dandelion x1, RedMushroom x1, Stick x1, Sunflower x1")

		-- Falling water on a tall flower's top: the top washes away, the flower drops once.
		table.clear(dropped)
		tall(world, 10, 10, B.RoseBush)
		settle()
		world:setBlock(10, FLOOR + 2, 10, WATER)
		settle()
		t.ok(Blocks.get(world:getBlock(10, FLOOR, 10)).fluid ~= nil, "water down to the ground")
		t.eq(summary(dropped), "RoseBush x1")
		Drops.set(nil)
	end)

	t.test("water: a water bucket poured into a plant replaces it, which drops (UseRules.pour)", function()
		local world, settle, dropped = newWorld()
		world:setBlock(0, FLOOR - 1, 0, SAND)
		world:setBlock(0, FLOOR, 0, B.DeadBush)
		world:setBlock(2, FLOOR, 0, B.ShortGrass)
		tall(world, 4, 0, B.TallGrass)
		tall(world, 6, 0, B.Sunflower)
		world:setBlock(8, FLOOR, 0, B.Poppy)
		settle()
		local function peek(x: number, y: number, z: number): number?
			return world:peekBlock(x, y, z)
		end
		local UP = 1 -- (Transmitters' side numbers: the top face.)
		for _, x in { 0, 2 } do
			local tx, ty = UseRules.waterTarget(peek, x, FLOOR, 0, UP)
			t.eq(tx, x, "into the replaceable plant's own cell")
			t.eq(ty, FLOOR)
			t.ok(UseRules.pour(world, x, FLOOR, 0))
			t.eq(world:getBlock(x, FLOOR, 0), WATER)
		end
		-- Into tall grass's top: the lower half pops (dropping nothing).
		t.ok(UseRules.pour(world, 4, FLOOR + 1, 0))
		-- Flowers aren't replaceable: the water goes beyond the clicked face and flows in.
		local fx, fy = UseRules.waterTarget(peek, 8, FLOOR, 0, UP)
		t.eq(fx, 8)
		t.eq(fy, FLOOR + 1, "above the poppy")
		t.ok(UseRules.pour(world, 8, FLOOR + 1, 0))
		settle()
		t.ok(Blocks.get(world:getBlock(4, FLOOR, 0)).fluid ~= nil, "water where the tall grass stood")
		t.ok(Blocks.get(world:getBlock(8, FLOOR, 0)).fluid ~= nil, "the poppy was washed away")
		t.eq(world:getBlock(6, FLOOR + 1, 0), AIR, "the spreading water took the sunflower too")
		t.eq(summary(dropped), "Poppy x1, Stick x1, Sunflower x1")
		-- Air and water drop nothing; into a source the bucket still empties.
		table.clear(dropped)
		t.ok(UseRules.pour(world, 20, FLOOR + 5, 20))
		t.ok(UseRules.pour(world, 20, FLOOR + 5, 20), "into a water source")
		t.ok(not UseRules.pour(world, 100, FLOOR, 100), "not loaded")
		t.eq(#dropped, 0)
		Drops.set(nil)
	end)

	--[[ Falling sand and gravel ]]

	-- The column (x, z) from the floor up, by name.
	local function column(world, x: number, z: number, height: number): string
		local names = {}
		for y = FLOOR, FLOOR + height - 1 do
			table.insert(names, Blocks.get(world:getBlock(x, y, z)).name)
		end
		return table.concat(names, " ")
	end

	t.test("gravity: sand replaces replaceable plants, and breaks into an item on flowers", function()
		local world, settle, dropped = newWorld()
		world:setBlock(0, FLOOR, 0, B.ShortGrass)
		tall(world, 2, 0, B.TallGrass)
		world:setBlock(4, FLOOR, 0, B.Dandelion)
		tall(world, 6, 0, B.Sunflower)
		world:setBlock(8, FLOOR - 1, 0, B.Mycelium)
		world:setBlock(8, FLOOR, 0, B.RedMushroom)
		settle()
		for x = 0, 8, 2 do
			world:setBlock(x, FLOOR + 5, 0, SAND)
		end
		settle()
		t.eq(column(world, 0, 0, 3), "Sand Air Air", "short grass replaced")
		t.eq(column(world, 2, 0, 3), "Sand Air Air", "tall grass replaced, down to its soil")
		t.eq(column(world, 4, 0, 3), "Dandelion Air Air", "the flower stays")
		t.eq(column(world, 6, 0, 3), "Sunflower SunflowerTop Air", "past both halves")
		t.eq(column(world, 8, 0, 3), "RedMushroom Air Air")
		t.eq(#dropped, 3, "three sand items")
		for _, drop in dropped do
			t.eq(drop.item, I.Sand)
			t.eq(drop.y, FLOOR, "in the plant's (lower) cell")
		end

		-- Placed right on a flower, gravel stays (it is no free cell).
		table.clear(dropped)
		world:setBlock(4, FLOOR + 1, 0, B.Gravel)
		settle()
		t.eq(column(world, 4, 0, 3), "Dandelion Gravel Air")
		t.eq(#dropped, 0)
		Drops.set(nil)
	end)

	--[[ Rules that need no change ]]

	t.test("unchanged: spawns may stand in plants, the sun shines through them, grass stays", function()
		local SafeSpot = require(server.Players.SafeSpot)
		local SkyCheck = require(server.Machines.SkyCheck)
		local world, settle, dropped = newWorld()
		world:setBlock(0, FLOOR, 0, B.ShortGrass)
		tall(world, 2, 0, B.Peony)
		world:setBlock(4, FLOOR, 0, B.Dandelion)
		settle()
		-- Plants aren't solid: feet (and head) may be in them, but nobody stands on them.
		t.ok(SafeSpot.isSafe(world, 0, FLOOR, 0), "in short grass")
		t.ok(SafeSpot.isSafe(world, 2, FLOOR, 0), "in both halves of a peony")
		t.ok(not SafeSpot.isSafe(world, 0, FLOOR + 1, 0), "not on top of grass")
		t.eq(SafeSpot.column(world, 4, 0), FLOOR, "the spot is the flower's cell")
		t.eq(SafeSpot.column(world, 2, 0), FLOOR)

		-- Not opaque: the sky shows through, loaded or not (Machines' solar panels).
		t.ok(SkyCheck.open(world, 2, FLOOR - 1, 0), "under a peony")
		t.ok(SkyCheck.open(world, 0, FLOOR - 1, 0), "under short grass")
		world:setBlock(4, FLOOR + 1, 0, STONE)
		t.ok(not SkyCheck.open(world, 4, FLOOR - 1, 0), "a stone above still covers it")
		-- (An unloaded chunk: its edits over the natural ground.)
		world:setBlock(100, FLOOR, 0, B.Lilac)
		world:setBlock(100, FLOOR + 1, 0, B.LilacTop)
		world:evict(function()
			return false
		end, 0)
		t.eq(world:peekChunk(100 // Config.ChunkSize, 0), nil, "evicted")
		t.ok(SkyCheck.open(world, 100, FLOOR - 1, 0), "edits of plants let the sky through")

		-- Grass under a plant stays grass (only something opaque turns it into dirt).
		for x = 0, 4, 2 do
			t.eq(world:getBlock(x, FLOOR - 1, 0), GRASS, `grass under the plant at x = {x}`)
		end
		world:setBlock(0, FLOOR, 0, B.Fern)
		settle()
		t.eq(world:getBlock(0, FLOOR - 1, 0), GRASS, "a fresh plant on it")
		world:setBlock(6, FLOOR, 0, STONE)
		settle()
		t.eq(world:getBlock(6, FLOOR - 1, 0), B.Dirt, "stone on it does")
		t.eq(#dropped, 0)
		Drops.set(nil)
	end)
end
