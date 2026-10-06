--[[
	Fire (Minecraft 1.20.1's FireBlock): the flammability table (BlockList `flammable`, FireBlock
	.bootStrap), the shared rules (Shared/Fire: survival, the sides a fire clings to, its outline,
	its planes, the animation's frames), the server's behaviour (Behaviours/Fire: new fires and
	their age, going out without fuel or support, burning blocks away, spreading through a wooden
	floor, water washing it away), flint and steel (its recipe, flint from gravel, lighting only
	where fire can burn), lava setting things alight (LavaFluid.randomTick), players and dropped
	items burning in it (Players/Burning), its sounds and its drops (none).
]]

return function(t, shared, require, server)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local Crafting = require(shared.Crafting)
	local SharedFire = require(shared.Fire)
	local Sounds = require(shared.Sounds)
	local GameMode = require(shared.GameMode)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local WorldServer = require(server.World.WorldServer)
	local BlockTicker = require(server.World.BlockTicker)
	local Behaviours = require(server.Behaviours)
	local Fire = require(server.Behaviours.Fire)
	local Fluid = require(server.Behaviours.Fluid)
	local Drops = require(server.Behaviours.Drops)
	local Burning = require(server.Players.Burning)
	local EditRules = require(server.Network.EditRules)

	local B, I = Blocks.id, Items.id
	local AIR, STONE, FIRE = Blocks.AIR, B.Stone, B.Fire
	local LAVA = Blocks.fluidId("Lava", 0)
	local WATER = Blocks.fluidId("Water", 0)
	local SURVIVAL, CREATIVE = GameMode.SURVIVAL, GameMode.CREATIVE

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

	-- A random cycling through `values`.
	local function cycle(values: { number }): () -> number
		local i = 0
		return function(): number
			i += 1
			return values[(i - 1) % #values + 1]
		end
	end

	-- A seeded random in [0, 1).
	local function seeded(seed: number): () -> number
		return function(): number
			seed = (seed * 1103515245 + 12345) % 2147483648
			return seed / 2147483648
		end
	end

	--[[ A flat world of stone, its top at FLOOR - 1, with a ticker ]]

	local FLOOR = 10
	local CROP = 32
	local flat = {
		generate = function(level: number, nx: number, nz: number)
			local data = ChunkLayout.create(CROP)
			for y = 0, FLOOR - 1 do
				for i = 0, ChunkLayout.LAYER - 1 do
					buffer.writeu16(data, (y * ChunkLayout.LAYER + i) * 2, STONE)
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
			return FLOOR, 1, 0, STONE
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
		local dropped = {}
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

	local function run(ticker: any, ticks: number)
		for _ = 1, ticks do
			ticker:step()
		end
	end

	local function count(world: any, block: number, x0: number, x1: number, y0: number, y1: number): number
		local n = 0
		for x = x0, x1 do
			for z = x0, x1 do
				for y = y0, y1 do
					if world:peekBlock(x, y, z) == block then
						n += 1
					end
				end
			end
		end
		return n
	end

	--[[ What burns ]]

	t.test("fire: Minecraft's flammability table (FireBlock.bootStrap) for the game's blocks", function()
		local expected: { [string]: { number } } = {
			Planks = { 5, 20 },
			JunglePlanks = { 5, 20 },
			OakLog = { 5, 5 },
			SpruceLog = { 5, 5 },
			OakLeaves = { 30, 60 },
			AcaciaLeaves = { 30, 60 },
			ShortGrass = { 60, 100 },
			Fern = { 60, 100 },
			DeadBush = { 60, 100 },
			TallGrass = { 60, 100 },
			TallGrassTop = { 60, 100 },
			Poppy = { 60, 100 },
			Sunflower = { 60, 100 },
			PeonyTop = { 60, 100 },
			GlowLichen = { 15, 100 },
			GlowLichenUp = { 15, 100 },
			CaveGlowLichenNorth = { 15, 100 },
			CoalBlock = { 5, 5 },
			-- Not flammable in Minecraft: saplings, mushrooms, stone, chests, crafting tables...
			OakSapling = { 0, 0 },
			BrownMushroom = { 0, 0 },
			Stone = { 0, 0 },
			Chest = { 0, 0 },
			CraftingTable = { 0, 0 },
			Cactus = { 0, 0 },
			Fire = { 0, 0 },
			Air = { 0, 0 },
		}
		for name, odds in expected do
			t.eq(Blocks.igniteOdds(B[name]), odds[1], `{name} ignite`)
			t.eq(Blocks.burnOdds(B[name]), odds[2], `{name} burn`)
			t.eq(Blocks.isFlammable(B[name]), odds[1] > 0, `{name} flammable`)
		end
		t.eq(Blocks.igniteOdds(-1), 0, "unknown ids")
		t.ok(not Blocks.isFlammable(Blocks.count), "past the end")
		-- Every flammable block is a plant, leaves, a log, planks, glow lichen or coal.
		for id, def in Blocks.defs do
			if def.ignite > 0 then
				t.ok(def.burn > 0, `{def.name} burns`)
			end
		end
	end)

	--[[ The shared rules ]]

	t.test("fire: survives on a sturdy block or next to a flammable one (FireBlock.canSurvive)", function()
		local onStone = sparse({ ["0,-1,0"] = STONE })
		t.eq(SharedFire.canSurvive(onStone, 0, 0, 0), true, "on stone")
		t.ok(SharedFire.canPlaceAt(onStone, 0, 0, 0), "flint and steel may light it there")
		t.eq(SharedFire.canSurvive(sparse({}), 0, 0, 0), false, "in the air")
		t.ok(not SharedFire.canPlaceAt(sparse({}), 0, 0, 0))
		local byLog = sparse({ ["1,0,0"] = B.OakLog })
		t.eq(SharedFire.canSurvive(byLog, 0, 0, 0), true, "clinging to a log")
		t.eq(SharedFire.canSurvive(sparse({ ["0,-1,0"] = B.OakLeaves }), 0, 0, 0), true, "on leaves (flammable)")
		t.eq(SharedFire.canSurvive(sparse({ ["0,-1,0"] = B.Glass }), 0, 0, 0), true, "glass is sturdy")
		t.eq(SharedFire.canSurvive(sparse({ ["0,-1,0"] = B.Torch }), 0, 0, 0), false, "a torch holds nothing")
		t.eq(SharedFire.canSurvive(sparse({ ["0,-1,0"] = false }), 0, 0, 0), nil, "unknown: wait")
		t.eq(SharedFire.canSurvive(sparse({ ["0,-1,0"] = STONE, ["1,0,0"] = false }), 0, 0, 0), true)
		t.ok(not SharedFire.canPlaceAt(sparse({ ["0,-1,0"] = STONE, ["0,0,0"] = WATER }), 0, 0, 0), "not in water")
		t.ok(SharedFire.canPlaceAt(sparse({ ["0,-1,0"] = STONE, ["0,0,0"] = B.CaveAir }), 0, 0, 0), "cave air")
		-- Ignite odds: an empty cell takes the best of its neighbours'.
		local corner = sparse({ ["0,-1,0"] = B.Planks, ["1,0,0"] = B.OakLeaves })
		t.eq(SharedFire.igniteOddsAt(corner, 0, 0, 0), 30)
		t.eq(SharedFire.igniteOddsAt(corner, 1, 0, 0), 0, "a block is no empty cell")
		t.eq(SharedFire.igniteOddsAt(corner, 5, 5, 5), 0)
	end)

	t.test("fire: on the floor or clinging to its flammable sides; outlines and planes", function()
		local F = SharedFire
		t.eq(F.sides(sparse({ ["0,-1,0"] = STONE, ["1,0,0"] = B.OakLog }), 0, 0, 0), 0, "on stone: the floor")
		t.eq(F.sides(sparse({ ["0,-1,0"] = B.Planks }), 0, 0, 0), 0, "on planks: the floor")
		local walls =
			sparse({ ["1,0,0"] = B.OakLog, ["0,0,-1"] = B.OakLeaves, ["0,1,0"] = B.Planks, ["-1,0,0"] = STONE })
		t.eq(F.sides(walls, 0, 0, 0), F.EAST + F.NORTH + F.UP, "the flammable sides only")
		-- Outlines: Minecraft's slabs.
		local floor = F.outline(0)
		t.eq(floor[5], 1 / 16, "a pixel thick floor slab")
		local east = F.outline(F.EAST)
		t.eq(east[1], 15 / 16)
		t.eq(east[4], 1)
		local both = F.outline(F.EAST + F.WEST)
		t.eq(both[1], 0)
		t.eq(both[4], 1, "one box around both slabs")
		local outlineAt = F.outlineAt(walls)
		t.eq(outlineAt(FIRE, 0, 0, 0), F.outline(F.EAST + F.NORTH + F.UP))
		t.eq(outlineAt(B.Torch, 0, 0, 0), Blocks.outline(B.Torch), "other blocks: Blocks.outline")
		t.eq(outlineAt(STONE, 0, 0, 0), nil)
		-- Planes: four leaning floor planes and the box of sides; one plane per wall.
		local planes = F.planes(0)
		t.eq(#planes, 5)
		local doubles = 0
		for _, plane in planes do
			if plane.faces == "double" then
				doubles += 1
				t.near(plane.size[2], 22.4 / math.cos(math.rad(22.5)), 1e-9, "rescaled")
				t.eq(math.abs(plane.orientation[1]), 22.5, "leaning 22.5 degrees")
				-- Its foot stays in the cell, its top reaches above it (1.4 blocks).
				local half = plane.size[2] / 2 * math.cos(math.rad(22.5))
				t.ok(plane.offset[2] - half > -8 and plane.offset[2] - half < -7, "foot near the floor")
				t.ok(plane.offset[2] + half > 14, "top above the cell")
				t.ok(math.abs(plane.offset[1]) < 8 and math.abs(plane.offset[3]) < 8, "inside the cell")
			end
		end
		t.eq(doubles, 4)
		t.eq(planes[5].faces, "box")
		t.eq(planes[5].size[2], 22.4)
		local clinging = F.planes(F.EAST + F.NORTH + F.UP)
		t.eq(#clinging, 3)
		for _, plane in clinging do
			t.eq(plane.faces, "front", "facing into the cell")
		end
		-- The east wall's plane looks west (-X): orientation (0, 90, 0) turns -Z to -X.
		local eastPlane = F.planes(F.EAST)[1]
		t.near(eastPlane.offset[1], 7.99, 1e-9)
		t.eq(eastPlane.orientation[2], 90)
	end)

	t.test("fire: the animation steps through the 8 frames of the sheet, 2 ticks each", function()
		t.eq(SharedFire.TEXTURE, "rbxassetid://124923986221566")
		t.eq(SharedFire.FRAMES, 8)
		t.eq(SharedFire.frameAt(0), 0)
		t.eq(SharedFire.frameAt(0.099), 0)
		t.eq(SharedFire.frameAt(0.1), 1, "a frame every 2 ticks")
		t.eq(SharedFire.frameAt(0.75), 7)
		t.eq(SharedFire.frameAt(0.8), 0, "loops every 0.8 s")
		t.eq(SharedFire.frameAt(1234.56), math.floor(1234.56 * 10) % 8)
		t.ok(SharedFire.frameAt(-0.05) >= 0, "never negative")
		local x, y = SharedFire.rectOffset(3)
		t.eq(x, 0)
		t.eq(y, 1536, "frames go down the 512 x 4096 sheet")
		t.eq(select(2, SharedFire.rectOffset(7)), 4096 - 512)
	end)

	--[[ The server's behaviour ]]

	t.test("fire: a new fire ages from 0 or its spreader's age; out at once where it can't burn", function()
		local world, ticker = newWorld()
		-- Placed by anyone (an explosion, flint and steel): age 0, its first tick in 30..39.
		world:setBlock(0, FLOOR, 0, FIRE)
		t.eq(Fire.age(world, 0, FLOOR, 0), 0)
		local due = ticker.scheduled[require(shared.World.Coords).posKey(0, FLOOR, 0)]
		t.ok(due ~= nil and due - ticker.tick >= 30 and due - ticker.tick <= 39, "FireBlock.getFireTickDelay")
		-- Placed by a spreading fire: its age.
		t.ok(Fire.ignite(world, 2, FLOOR, 0, 7))
		t.eq(Fire.age(world, 2, FLOOR, 0), 7)
		-- In the air with nothing to burn: out on the next tick (BaseFireBlock.onPlace).
		world:setBlock(0, FLOOR + 5, 0, FIRE)
		t.eq(world:peekBlock(0, FLOOR + 5, 0), FIRE, "its neighbours see it for a tick")
		run(ticker, 1)
		t.eq(world:peekBlock(0, FLOOR + 5, 0), AIR, "nothing holds it")
		-- Clinging to a log, then the log goes: out (FireBlock.updateShape).
		world:setBlock(5, FLOOR + 3, 5, B.OakLog)
		t.ok(Fire.ignite(world, 6, FLOOR + 3, 5, 0))
		t.eq(world:peekBlock(6, FLOOR + 3, 5), FIRE)
		world:setBlock(5, FLOOR + 3, 5, STONE)
		t.eq(world:peekBlock(6, FLOOR + 3, 5), AIR, "its log gone")
		t.eq(Fire.age(world, 6, FLOOR + 3, 5), nil)
	end)

	t.test("fire: on stone with nothing to burn it goes out once older than 3 (checkBurnOut)", function()
		local world, ticker = newWorld()
		world:setBlock(0, FLOOR, 0, FIRE)
		-- Rolls of 0.9: it ages by 1 each tick (rand(3) / 2 = 1).
		local ticks = 0
		while world:peekBlock(0, FLOOR, 0) == FIRE and ticks < 20 do
			Fire.tick(world, ticker, 0, FLOOR, 0, cycle({ 0.9 }))
			ticks += 1
		end
		t.eq(world:peekBlock(0, FLOOR, 0), AIR, "burnt out")
		t.eq(ticks, 5, "ages 0..3 stay, the tick at age 4 puts it out")
		-- Left alone, the ticker does the same within a few seconds.
		world:setBlock(3, FLOOR, 3, FIRE)
		math.randomseed(5)
		run(ticker, 1200)
		t.eq(world:peekBlock(3, FLOOR, 3), AIR, "out within a minute")
		-- doFireTick off: nothing happens.
		local Config = require(shared.Config)
		Config.Server.Fire.Tick = false
		world:setBlock(4, FLOOR, 4, FIRE)
		for _ = 1, 20 do
			Fire.tick(world, ticker, 4, FLOOR, 4, cycle({ 0.9 }))
		end
		Config.Server.Fire.Tick = true
		t.eq(world:peekBlock(4, FLOOR, 4), FIRE, "doFireTick off")
	end)

	t.test("fire: burns its neighbours away by their burn odds, sometimes into fire", function()
		local world, ticker = newWorld()
		-- A fire on stone between two logs and under leaves.
		world:setBlock(1, FLOOR, 0, B.OakLog)
		world:setBlock(-1, FLOOR, 0, B.OakLeaves)
		world:setBlock(0, FLOOR + 1, 0, B.OakLeaves)
		world:setBlock(0, FLOOR, 0, FIRE)
		-- Rolls of 0: every checkBurnOut hits (rand(chance) 0 < odds), and rand(age + 10) 0 < 5
		-- turns the block into fire; spreading rolls 0 too.
		Fire.tick(world, ticker, 0, FLOOR, 0, cycle({ 0 }))
		t.eq(world:peekBlock(1, FLOOR, 0), FIRE, "the log into fire")
		t.eq(world:peekBlock(-1, FLOOR, 0), FIRE, "the leaves into fire")
		-- (The leaves above burnt into fire too, but that fire has nothing to hold it: out.)
		run(ticker, 1)
		t.eq(world:peekBlock(0, FLOOR + 1, 0), AIR, "above: burnt, and the fire there went out")
		-- Rolls near 1: nothing burns (rand(300) 299 >= any odds).
		local world2, ticker2 = newWorld()
		world2:setBlock(1, FLOOR, 0, B.Planks)
		world2:setBlock(0, FLOOR, 0, FIRE)
		Fire.tick(world2, ticker2, 0, FLOOR, 0, cycle({ 0.999 }))
		t.eq(world2:peekBlock(1, FLOOR, 0), B.Planks)
		-- A tall plant's top burnt into air takes its lower half (no drop, Minecraft's updateShape).
		local world3, ticker3, dropped = newWorld()
		world3:setBlock(1, FLOOR - 1, 0, B.Dirt)
		world3:setBlock(1, FLOOR, 0, B.Sunflower)
		world3:setBlock(1, FLOOR + 1, 0, B.SunflowerTop)
		world3:setBlock(0, FLOOR + 1, 0, FIRE)
		world3:setBlock(0, FLOOR, 0, STONE)
		-- (Rolls: the next tick's delay, the age, 0 to burn the east neighbour (the top), 0.99 for
		-- rand(age + 10): into air; then 0.99, so nothing else burns or catches.)
		local rolls = { 0.6, 0.5, 0 }
		local n = 0
		Fire.tick(world3, ticker3, 0, FLOOR + 1, 0, function(): number
			n += 1
			return rolls[n] or 0.99
		end)
		run(ticker3, 5)
		t.eq(world3:peekBlock(1, FLOOR + 1, 0), AIR, "the top burnt")
		t.eq(world3:peekBlock(1, FLOOR, 0), AIR, "the lower half with it")
		t.eq(#dropped, 0, "nothing dropped")
	end)

	t.test("fire: spreads through a wooden floor and burns it away; stone stays", function()
		local world, ticker = newWorld()
		-- A 9 x 9 oak floor one block above the stone, with a log pillar in the middle.
		for x = -4, 4 do
			for z = -4, 4 do
				world:setBlock(x, FLOOR, z, B.Planks)
			end
		end
		world:setBlock(0, FLOOR + 1, 0, FIRE)
		math.randomseed(11)
		local most = 0
		for _ = 1, 60 do
			run(ticker, 100)
			most = math.max(most, count(world, FIRE, -6, 6, FLOOR, FLOOR + 3))
		end
		t.ok(most >= 5, `it spread (at most {most} fires at once)`)
		local planks = count(world, B.Planks, -4, 4, FLOOR, FLOOR)
		t.ok(planks < 81 / 2, `the floor burnt away ({planks} of 81 planks left)`)
		t.eq(count(world, STONE, -4, 4, FLOOR - 1, FLOOR - 1), 81, "stone never burns")
		-- In the end every fire is out (nothing left to burn on bare stone).
		run(ticker, 4000)
		t.eq(count(world, FIRE, -6, 6, FLOOR, FLOOR + 3), 0, "all out")
	end)

	t.test("fire: water washes it away with no drop; a random tick restarts a lost tick", function()
		local world, ticker, dropped = newWorld()
		world:setBlock(1, FLOOR, 0, FIRE)
		world:setBlock(0, FLOOR, 0, WATER)
		run(ticker, 20)
		t.ok(world:peekBlock(1, FLOOR, 0) ~= FIRE, "water flowed over it")
		t.eq(#dropped, 0, "fire drops nothing")
		t.eq(EditRules.drops(FIRE, false, nil), nil, "punched out: nothing")
		t.eq(Blocks.get(FIRE).hardness, 0, "breaks at once")
		t.ok(Blocks.isReplaceable(FIRE), "a block placed into it replaces it")
		-- A fire whose tick was lost (its chunk unloaded) ticks again after a random tick.
		local Coords = require(shared.World.Coords)
		world:setBlock(5, FLOOR, 5, FIRE)
		local key = Coords.posKey(5, FLOOR, 5)
		ticker.scheduled[key] = nil
		Fire.onRandomTick(world, ticker, 5, FLOOR, 5, FIRE, cycle({ 0.5 }))
		t.ok(ticker.scheduled[key] ~= nil, "scheduled again")
		t.ok(Behaviours.byId[FIRE] == Fire, "Fire's behaviour")
	end)

	--[[ Lighting fires ]]

	t.test("fire: flint and steel (iron ingot + flint), flint from gravel, 64 uses", function()
		local made = Crafting.match({
			[1] = { item = I.IronIngot, count = 1 },
			[4] = { item = I.Flint, count = 1 },
		}, 2)
		t.ok(made ~= nil and made.item == I.FlintAndSteel, "shapeless, in the 2 x 2 grid")
		t.eq(Items.get(I.FlintAndSteel).durability, 64)
		t.eq(Items.maxStack(I.FlintAndSteel), 1)
		t.eq(Items.displayName(I.FlintAndSteel), "Flint and Steel")
		-- Gravel gives flint one time in 10.
		local flint = Items.randomDrop(B.Gravel, cycle({ 0.05 }))
		t.ok(flint ~= nil and flint.item == I.Flint and flint.count == 1)
		t.eq(Items.randomDrop(B.Gravel, cycle({ 0.5 })), nil)
		t.eq(Items.randomDrop(STONE, cycle({ 0 })), nil, "only gravel")
		local flints = 0
		math.randomseed(3)
		for _ = 1, 2000 do
			local stack = EditRules.drops(B.Gravel, false, nil)
			t.ok(stack ~= nil, "gravel always drops")
			if stack and stack.item == I.Flint then
				flints += 1
			end
		end
		t.ok(flints > 140 and flints < 260, `about 200 flint in 2000 ({flints})`)
		t.eq(EditRules.drops(B.Gravel, true, nil), nil, "creative: no drops")
	end)

	t.test("fire: flint and steel lights the cell in front of the clicked face where fire burns", function()
		local world = newWorld()
		local x, y, z = Fire.light(world, 0, FLOOR - 1, 0, 0, 1, 0)
		t.ok(x == 0 and y == FLOOR and z == 0, "on top of stone")
		t.eq(world:peekBlock(0, FLOOR, 0), FIRE)
		t.eq(Fire.age(world, 0, FLOOR, 0), 0)
		-- The side of a stone block in mid air: nothing holds the fire.
		world:setBlock(5, FLOOR + 3, 5, STONE)
		t.eq(Fire.light(world, 5, FLOOR + 3, 5, 1, 0, 0), nil, "stone doesn't burn")
		t.eq(world:peekBlock(6, FLOOR + 3, 5), AIR)
		-- The side of a log: it clings to it.
		world:setBlock(8, FLOOR + 3, 8, B.OakLog)
		t.ok(Fire.light(world, 8, FLOOR + 3, 8, 0, 0, 1) ~= nil, "a log burns")
		t.eq(world:peekBlock(8, FLOOR + 3, 9), FIRE)
		-- Only into an empty cell.
		world:setBlock(2, FLOOR, 0, B.Planks)
		t.eq(Fire.light(world, 1, FLOOR, 0, 1, 0, 0), nil, "not into planks")
		t.eq(Fire.light(world, 0, FLOOR, 0, 0, 0, 0), nil, "not into the fire itself")
		t.eq(Sounds.find("item.flintandsteel.use") ~= nil, true)
	end)

	t.test("fire: lava sets the air next to flammable blocks alight (LavaFluid.randomTick)", function()
		local world, ticker = newWorld()
		world:setBlock(0, FLOOR, 0, LAVA)
		-- A step up (rand(3) = 1, offsets 0): the cell above the lava, next to a log there.
		world:setBlock(1, FLOOR + 1, 0, B.OakLog)
		local x, y, z = Fire.lavaTick(world, 0, FLOOR, 0, cycle({ 0.5, 0.5, 0.5 }))
		t.ok(x == 0 and y == FLOOR + 1 and z == 0, "lit above the lava")
		t.eq(world:peekBlock(0, FLOOR + 1, 0), FIRE)
		-- Stopped by a solid block in the way.
		local world2 = newWorld()
		world2:setBlock(0, FLOOR, 0, LAVA)
		world2:setBlock(0, FLOOR + 1, 0, STONE)
		world2:setBlock(0, FLOOR + 2, 0, B.OakLog)
		t.eq(Fire.lavaTick(world2, 0, FLOOR, 0, cycle({ 0.9, 0.5, 0.5 })), nil, "blocked")
		-- rand(3) = 0: three cells at its level; the air above a flammable one catches.
		local world3 = newWorld()
		world3:setBlock(0, FLOOR, 0, LAVA)
		world3:setBlock(1, FLOOR, 0, B.Planks)
		x, y, z = Fire.lavaTick(world3, 0, FLOOR, 0, cycle({ 0.1, 0.9, 0.5 }))
		t.ok(x == 1 and y == FLOOR + 1 and z == 0, "above the planks")
		t.eq(world3:peekBlock(1, FLOOR + 1, 0), FIRE)
		-- Through the Fluid behaviour's random tick: lava does, water never.
		local world4 = newWorld()
		world4:setBlock(0, FLOOR, 0, WATER)
		world4:setBlock(1, FLOOR, 0, B.Planks)
		Fluid.onRandomTick(world4, ticker, 0, FLOOR, 0, WATER, cycle({ 0.1, 0.9, 0.5 }))
		t.eq(world4:peekBlock(1, FLOOR + 1, 0), AIR, "water lights nothing")
		world4:setBlock(0, FLOOR, 0, B.CaveLava)
		Fluid.onRandomTick(world4, ticker, 0, FLOOR, 0, B.CaveLava, cycle({ 0.1, 0.9, 0.5 }))
		t.eq(world4:peekBlock(1, FLOOR + 1, 0), FIRE, "cave lava too")
	end)

	--[[ Harm ]]

	t.test("fire: players in it take 1 every 10 ticks and catch fire after a second (inFire)", function()
		local get = sparse({ ["0,0,0"] = FIRE })
		local touching = Burning.touchingAt(get, 0.5, 0, 0.5, 0.6, 1.8)
		t.ok(bit32.btest(touching, Burning.FIRE), "standing in a fire block")
		t.eq(Burning.touchingAt(get, 0.5, 1, 0.5, 0.6, 1.8), 0, "above it")
		t.ok(bit32.btest(Burning.touchingAt(get, -0.25, 1.5, 0.5, 0.6, 1.8), Burning.FIRE) == false)
		t.ok(bit32.btest(Burning.touchingAt(get, 1.25, 0.5, 0.5, 0.6, 1.8), Burning.FIRE), "the box reaches in")
		local state = Burning.newPlayer()
		local total, hurts = 0, {}
		for tick = 1, 40 do
			local damage = Burning.tickPlayer(state, SURVIVAL, Burning.FIRE)
			if damage > 0 then
				total += damage
				table.insert(hurts, tick)
			end
			if tick == 19 then
				t.ok(not Burning.onFire(state), "not burning yet")
			end
		end
		t.eq(hurts[1], 1, "at once")
		t.eq(hurts[2] - hurts[1], 10, "under the hurt cooldown")
		t.eq(total, 4, "1 every 10 ticks")
		t.ok(Burning.onFire(state), "burning after 20 ticks in it")
		-- Out of it: 8 s of burning, 1 every 20 ticks.
		local burnt = 0
		for _ = 1, 400 do
			burnt += Burning.tickPlayer(state, SURVIVAL, 0)
		end
		t.ok(burnt >= 7 and burnt <= 9, `about 8 burns ({burnt})`)
		t.ok(not Burning.onFire(state))
		-- Stepping in and out never catches fire; water puts it out; creative never burns.
		local quick = Burning.newPlayer()
		for _ = 1, 10 do
			for _ = 1, 15 do
				Burning.tickPlayer(quick, SURVIVAL, Burning.FIRE)
			end
			Burning.tickPlayer(quick, SURVIVAL, 0)
		end
		t.ok(not Burning.onFire(quick), "15 ticks at a time")
		local creative = Burning.newPlayer()
		for _ = 1, 100 do
			t.eq(Burning.tickPlayer(creative, CREATIVE, Burning.FIRE), 0)
		end
		t.ok(not Burning.onFire(creative))
		-- Armor softens it (in_fire doesn't bypass armor).
		local armored = Burning.newPlayer()
		t.ok(Burning.tickPlayer(armored, SURVIVAL, Burning.FIRE, 20, 8) < 1)
	end)

	t.test("fire: dropped items burn away in it within a few ticks", function()
		local item = Burning.newItem()
		local ticks = 0
		local gone = false
		while not gone and ticks < 20 do
			gone = Burning.tickItem(item, Burning.FIRE)
			ticks += 1
		end
		t.ok(gone and ticks <= 5, `gone in {ticks} ticks`)
	end)

	--[[ Sounds and the block ]]

	t.test("fire: punching it out hisses; it crackles; no item, light 15, see-through", function()
		local extinguish = Sounds.get(Sounds.block(FIRE, "break") :: number)
		t.eq(extinguish and extinguish.name, "block.fire.extinguish", "level event 1009")
		t.eq(Sounds.get(Sounds.block(FIRE, "step") :: number).name, "block.wool.step", "wool otherwise")
		t.eq((Sounds.get("block.fire.ambient") :: any).side, "client")
		t.eq(Items.ofBlock(FIRE), nil, "no item")
		t.eq(Blocks.light(FIRE), 15)
		t.ok(not Blocks.isSolid(FIRE) and not Blocks.isOpaque(FIRE), "no collision, see-through")
		t.ok(Blocks.isTargetable(FIRE), "aimed at, to punch it out")
		t.eq(Blocks.get(FIRE).behaviour, "Fire")
		t.ok(Blocks.get(FIRE).brokenByFluid)
	end)
end
