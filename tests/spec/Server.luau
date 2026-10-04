--[[
	The server's world: the protocol's world messages, WorldServer (edits, eviction, cropped
	chunks), block updates (falling sand, water, grass), safe spawn spots and furnaces cooking
	(Players/Containers.tickFurnaces).
]]

return function(t, shared, require, server)
	local Blocks = require(shared.Blocks)
	local Config = require(shared.Config)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Protocol = require(shared.Net.Protocol)
	local WorldServer = require(server.World.WorldServer)
	local BlockTicker = require(server.World.BlockTicker)
	local Behaviours = require(server.Behaviours)

	local STONE, AIR = Blocks.id.Stone, Blocks.AIR
	local FLOOR = 10 -- first air block of the flat test world
	local WATER = Blocks.fluidId("Water", 0)

	-- A flat stone world: y < FLOOR is stone, the rest is air (chunks cropped at CROP, like the
	-- real generator crops them a little above the terrain).
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
		local function settle(maxTicks: number?): number
			for i = 1, maxTicks or 2000 do
				ticker:step()
				if ticker:pendingCount() == 0 then
					return i
				end
			end
			error("block updates never settled")
		end
		return world, ticker, settle
	end

	t.test("protocol round trips and rejects malformed requests", function()
		local coords = Protocol.decodeChunkRequest(Protocol.encodeChunkRequest({ { 1, -2 }, { -300, 400 } }))
		assert(coords)
		t.eq(#coords, 2)
		t.eq(coords[2][1], -300)
		t.eq(coords[2][2], 400)
		t.eq(Protocol.decodeChunkRequest(buffer.create(1)), nil, "too short")
		local bad = buffer.create(2 + 8)
		buffer.writeu16(bad, 0, 5)
		t.eq(Protocol.decodeChunkRequest(bad), nil, "count does not match length")

		local action, x, y, z, block = Protocol.decodeEdit(Protocol.encodeEdit(2, -5, 70, 9, STONE))
		t.eq(action, 2)
		t.eq(x, -5)
		t.eq(y, 70)
		t.eq(z, 9)
		t.eq(block, STONE)
		t.eq((Protocol.decodeEdit(buffer.create(3))), nil)

		local seen = {}
		Protocol.forEachEdit(Protocol.encodeEdits({ 1, 2, 3, 4, -5, 6, -7, 8 }), function(...)
			table.insert(seen, { ... })
		end)
		t.eq(#seen, 2)
		t.eq(seen[2][1], -5)
		t.eq(seen[2][3], -7)

		local lists = Protocol.decodeChunkEdits(Protocol.encodeChunkEdits({
			{ cx = 3, cz = -4, edits = { [10] = STONE, [65535] = AIR } },
			{ cx = 0, cz = 0, edits = {} },
		}))
		t.eq(#lists, 2)
		t.eq(lists[1].edits[10], STONE)
		t.eq(lists[1].edits[65535], AIR)
		t.eq(next(lists[2].edits), nil)
	end)

	t.test("teleport and waypoint messages round trip and reject bad input", function()
		local x, z = Protocol.decodeTeleport(Protocol.encodeTeleport(-12345, 678))
		t.eq(x, -12345)
		t.eq(z, 678)
		t.eq((Protocol.decodeTeleport(Protocol.encodeTeleport(Protocol.MAX_COORDINATE + 1, 0))), nil, "too far")
		t.eq((Protocol.decodeTeleport(buffer.create(3))), nil, "wrong length")

		local list = {
			{ name = "Home", x = 10, y = 70, z = -20, color = { 255, 0, 10 } },
			{ name = "Mine ⛏", x = -400, y = 12, z = 999, color = { 1, 2, 3 } },
		}
		local decoded, revision = Protocol.decodeWaypoints(Protocol.encodeWaypoints(list, 7))
		assert(decoded)
		t.eq(revision, 7)
		t.eq(#decoded, 2)
		t.eq(decoded[2].name, "Mine ⛏")
		t.eq(decoded[2].x, -400)
		t.eq(decoded[1].color[1], 255)

		local long = { { name = string.rep("a", 100), x = 0, y = 0, z = 0, color = { 0, 0, 0 } } }
		local trimmed = Protocol.decodeWaypoints(Protocol.encodeWaypoints(long, 1))
		assert(trimmed)
		t.eq(#trimmed[1].name, Protocol.MAX_WAYPOINT_NAME, "names are capped")
		local emoji = Protocol.truncateName(string.rep("a", 31) .. "⛏⛏")
		t.eq(emoji, string.rep("a", 31), "never splits a UTF-8 character")
		t.ok(utf8.len(Protocol.truncateName(string.rep("é", 40))) ~= nil, "still valid UTF-8")

		local bad = Protocol.encodeWaypoints(list, 2)
		t.eq((Protocol.decodeWaypoints(buffer.create(0))), nil, "empty")
		local truncated = buffer.create(buffer.len(bad) - 1)
		buffer.copy(truncated, 0, bad, 0, buffer.len(truncated))
		t.eq((Protocol.decodeWaypoints(truncated)), nil, "truncated")
		local tooMany = buffer.create(5)
		buffer.writeu8(tooMany, 4, Protocol.MAX_WAYPOINTS + 1)
		t.eq((Protocol.decodeWaypoints(tooMany)), nil, "too many")
	end)

	t.test("world records edits, queues replication and survives eviction", function()
		local world = newWorld()
		t.eq(world:peekBlock(0, 5, 0), nil, "nothing generated yet")
		t.eq(world:getBlock(0, 5, 0), STONE)
		t.eq(world:getBlock(-1, FLOOR, -1), AIR)

		t.ok(world:setBlock(-1, FLOOR, -1, Blocks.id.Planks))
		t.ok(not world:setBlock(-1, FLOOR, -1, Blocks.id.Planks), "same block is not a change")
		t.ok(not world:setBlock(0, Config.WorldHeight, 0, STONE), "outside the world")
		local pending = world:takePending()
		t.eq(#pending, 4)
		t.eq(pending[4], Blocks.id.Planks)
		t.eq(#world:takePending(), 0)
		t.eq(world:topBlock(-1, -1), FLOOR)

		world:evict(function()
			return false
		end, 0)
		t.eq(world.chunkCount, 0)
		t.eq(world:getBlock(-1, FLOOR, -1), Blocks.id.Planks, "edit re-applied after regeneration")
		local edits = world:chunkEdits(-1, -1)
		assert(edits)
		t.eq(edits[ChunkLayout.localIndex(15, FLOOR, 15)], Blocks.id.Planks)
	end)

	t.test("cropped chunks grow for blocks placed above them", function()
		local world = newWorld()
		local high = Config.WorldHeight - 5
		t.eq(world:getBlock(2, high, 2), AIR, "air above the crop")
		t.eq(world:getChunk(0, 0).height, CROP)
		t.ok(not world:setBlock(2, high, 2, AIR), "air above the crop is no change")
		t.eq(world:getChunk(0, 0).height, CROP, "air does not grow the chunk")
		t.ok(world:setBlock(2, high, 2, Blocks.id.Planks))
		local chunk = world:getChunk(0, 0)
		t.ok(chunk.height > high and chunk.height <= Config.WorldHeight, `grown to {chunk.height}`)
		t.eq(buffer.len(chunk.data), ChunkLayout.LAYER * chunk.height * 2, "buffer matches the height")
		t.eq(world:getBlock(2, high, 2), Blocks.id.Planks)
		t.eq(world:getBlock(2, FLOOR - 1, 2), STONE, "terrain kept")
		t.eq(world:getBlock(2, high - 1, 2), AIR)
		t.eq(world:topBlock(2, 2), high)
		t.eq(world:topBlock(3, 2), FLOOR - 1)

		-- Regenerated after eviction: the edit lies above the generated crop again.
		world:evict(function()
			return false
		end, 0)
		t.eq(world:getBlock(2, high, 2), Blocks.id.Planks, "edit above the crop re-applied")
		t.eq(world:getBlock(2, FLOOR - 1, 2), STONE)

		-- An air edit above the crop is kept as an edit but needs no room.
		t.ok(world:setBlock(2, high, 2, AIR))
		world:evict(function()
			return false
		end, 0)
		t.eq(world:getBlock(2, high, 2), AIR)
		t.eq(world:getChunk(0, 0).height, CROP, "air edits do not grow regenerated chunks")
	end)

	t.test("sand falls until it lands", function()
		local world, _, settle = newWorld()
		world:setBlock(3, FLOOR + 12, 3, Blocks.id.Sand)
		settle()
		t.eq(world:getBlock(3, FLOOR, 3), Blocks.id.Sand)
		t.eq(world:getBlock(3, FLOOR + 1, 3), AIR)
		t.eq(world:getBlock(3, FLOOR + 12, 3), AIR)
	end)

	t.test("water spreads seven blocks, then dries up when the source is removed", function()
		local world, _, settle = newWorld()
		-- Block updates never generate chunks, so load the area the water will reach.
		for cz = -1, 0 do
			for cx = -1, 0 do
				world:getChunk(cx, cz)
			end
		end
		world:setBlock(0, FLOOR, 0, WATER)
		settle()
		local count = 0
		for dz = -9, 9 do
			for dx = -9, 9 do
				local fluid = Blocks.get(world:getBlock(dx, FLOOR, dz)).fluid
				if fluid then
					count += 1
					t.eq(fluid.level, math.abs(dx) + math.abs(dz), `level at {dx},{dz}`)
				end
			end
		end
		t.eq(count, 113, "diamond of radius 7")

		world:setBlock(0, FLOOR, 0, AIR)
		settle()
		for dz = -9, 9 do
			for dx = -9, 9 do
				t.eq(world:getBlock(dx, FLOOR, dz), AIR, "all water gone")
			end
		end
	end)

	t.test("water pours off a pillar, and two sources make a third", function()
		local world, _, settle = newWorld()
		for cz = 0, 2 do
			for cx = 0, 2 do
				world:getChunk(cx, cz)
			end
		end
		for y = FLOOR, FLOOR + 5 do
			world:setBlock(20, y, 20, STONE)
		end
		world:setBlock(20, FLOOR + 6, 20, WATER)
		settle()
		t.eq(world:getBlock(21, FLOOR + 6, 20), Blocks.fluidId("Water", 1), "spreads on top of the pillar")
		t.eq(world:getBlock(21, FLOOR + 3, 20), Blocks.fluidId("Water", 8), "falls down its side")
		t.eq(world:getBlock(21, FLOOR, 20), Blocks.fluidId("Water", 8), "column reaches the floor")
		t.eq(world:getBlock(22, FLOOR, 20), Blocks.fluidId("Water", 1), "spreads where it lands")

		local world2, _, settle2 = newWorld()
		for cz = 1, 3 do
			for cx = 1, 3 do
				world2:getChunk(cx, cz)
			end
		end
		world2:setBlock(40, FLOOR, 40, WATER)
		world2:setBlock(42, FLOOR, 40, WATER)
		settle2()
		t.eq(world2:getBlock(41, FLOOR, 40), WATER, "infinite source")
	end)

	t.test("water spreads only towards the nearest way down", function()
		local world, _, settle = newWorld()
		for cz = -1, 0 do
			for cx = -1, 0 do
				world:getChunk(cx, cz)
			end
		end
		-- A one block pit three blocks east of the source.
		world:setBlock(3, FLOOR - 1, 0, AIR)
		world:setBlock(0, FLOOR, 0, WATER)
		settle()
		t.ok(Blocks.get(world:getBlock(3, FLOOR - 1, 0)).fluid ~= nil, "the pit fills")
		for x = 1, 2 do
			t.ok(Blocks.get(world:getBlock(x, FLOOR, 0)).fluid ~= nil, `flows east at {x}`)
		end
		for _, p in { { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { 2, 1 } } do
			t.eq(world:getBlock(p[1], FLOOR, p[2]), AIR, `dry at {p[1]},{p[2]}`)
		end

		-- The search follows open blocks for 4 blocks past the neighbour, so a pit 5 blocks away is
		-- found and draws the water east; with no way down within reach (a pit 6 blocks away) it
		-- spreads everywhere (the diamond above).
		local function pitAt(distance: number)
			local w, _, settleW = newWorld()
			for cz = -1, 0 do
				for cx = -1, 0 do
					w:getChunk(cx, cz)
				end
			end
			w:setBlock(distance, FLOOR - 1, 0, AIR)
			w:setBlock(0, FLOOR, 0, WATER)
			settleW()
			return w
		end
		local near = pitAt(5)
		t.eq(near:getBlock(-1, FLOOR, 0), AIR, "a pit 5 blocks away keeps the west dry")
		t.ok(Blocks.get(near:getBlock(5, FLOOR - 1, 0)).fluid ~= nil, "and fills")
		local far = pitAt(6)
		t.ok(Blocks.get(far:getBlock(-1, FLOOR, 0)).fluid ~= nil, "a pit 6 blocks away is out of reach: west too")
		t.ok(Blocks.get(far:getBlock(0, FLOOR, 1)).fluid ~= nil, "and sideways")
	end)

	t.test("two sources make a third even under falling water (Minecraft's getNewLiquid order)", function()
		local world, _, settle = newWorld()
		for cz = -1, 1 do
			for cx = -1, 1 do
				world:getChunk(cx, cz)
			end
		end
		world:setBlock(7, FLOOR, 8, WATER)
		world:setBlock(9, FLOOR, 8, WATER)
		-- A source floating above the gap pours into it.
		world:setBlock(8, FLOOR + 2, 8, WATER)
		settle()
		t.eq(world:getBlock(8, FLOOR, 8), WATER, "the gap between the sources is a source")
	end)

	t.test("water waits at unloaded chunks and continues once they load", function()
		local world, ticker, _ = newWorld()
		world:setBlock(8, FLOOR, 8, WATER) -- chunk (0, 0); chunk (-1, 0) is not loaded
		for _ = 1, 200 do
			ticker:step()
		end
		-- Spreading west would look for a way down into the unloaded chunk (up to 5 blocks away),
		-- so the water stops where its search would reach it instead of guessing.
		t.eq(world:getBlock(4, FLOOR, 8), Blocks.fluidId("Water", 4), "spread while the search stays loaded")
		t.eq(world:getBlock(3, FLOOR, 8), AIR, "waits where the search reaches the unloaded chunk")
		t.ok(ticker:pendingCount() > 0, "edge blocks keep retrying")
		world:getChunk(-1, 0)
		for _ = 1, 400 do
			ticker:step()
		end
		t.eq(world:getBlock(1, FLOOR, 8), Blocks.fluidId("Water", 7), "continued once it loaded")
	end)

	t.test("safe spots avoid water, leaves, cactus, low ceilings and caves", function()
		local SafeSpot = require(server.Players.SafeSpot)
		local world = newWorld()
		t.ok(SafeSpot.isSafe(world, 0, FLOOR, 0), "flat ground")
		t.ok(not SafeSpot.isSafe(world, 0, FLOOR - 1, 0), "inside the ground")

		world:setBlock(0, FLOOR, 0, WATER)
		t.ok(not SafeSpot.isSafe(world, 0, FLOOR, 0), "standing in water")

		world:setBlock(5, FLOOR, 5, Blocks.id.Cactus)
		t.ok(not SafeSpot.isSafe(world, 4, FLOOR, 5), "next to a cactus")

		world:setBlock(8, FLOOR + 1, 8, Blocks.id.Planks)
		t.ok(not SafeSpot.isSafe(world, 8, FLOOR, 8), "head inside a block")
		t.eq(SafeSpot.column(world, 8, 8), FLOOR + 2, "stands on top of the block instead")

		world:setBlock(12, FLOOR, 12, Blocks.id.OakLeaves)
		t.ok(not SafeSpot.isSafe(world, 12, FLOOR + 1, 12), "standing on leaves")

		-- A water pool around the target: the closest dry spot is found.
		for dz = -2, 2 do
			for dx = -2, 2 do
				world:setBlock(30 + dx, FLOOR - 1, 30 + dz, WATER)
				world:setBlock(30 + dx, FLOOR, 30 + dz, WATER)
			end
		end
		local x, y, z = SafeSpot.find(world, 30, 30)
		assert(x)
		t.eq(y, FLOOR)
		t.eq(math.max(math.abs(x - 30), math.abs(z - 30)), 3, "first ring outside the pool")

		-- Never below the natural surface (no spawning in caves).
		world:setBlock(40, FLOOR - 1, 40, AIR)
		world:setBlock(40, FLOOR - 2, 40, AIR)
		world:setBlock(40, FLOOR - 3, 40, AIR)
		t.eq(SafeSpot.column(world, 40, 40), nil, "a pit below the surface is not a spawn")
	end)

	t.test("grass under a block turns into dirt", function()
		local world, _, settle = newWorld()
		world:setBlock(5, FLOOR - 1, 5, Blocks.id.Grass)
		settle()
		t.eq(world:getBlock(5, FLOOR - 1, 5), Blocks.id.Grass, "uncovered grass stays")
		world:setBlock(5, FLOOR, 5, STONE)
		settle()
		t.eq(world:getBlock(5, FLOOR - 1, 5), Blocks.id.Dirt)
	end)

	--[[ Furnaces (Players/Containers) ]]

	local Items = require(shared.Items)
	local Smelting = require(shared.Crafting.Smelting)
	local Containers = require(server.Players.Containers)
	local FURNACE, CHEST = Blocks.id.Furnace, Blocks.id.Chest
	local RAW_IRON, COAL, INGOT = Items.id.RawIron, Items.id.Coal, Items.id.IronIngot

	-- Runs `n` furnace ticks; returns every change reported, in order.
	local function tickFurnaces(store, n: number): { any }
		local all = {}
		for _ = 1, n do
			for _, change in store:tickFurnaces() do
				table.insert(all, change)
			end
		end
		return all
	end

	t.test("furnaces: tickFurnaces smelts what a viewer put in and says where and what changed", function()
		local store = Containers.new()
		local furnace = store:get(4, 5, -6, FURNACE)
		t.eq(#store:tickFurnaces(), 0, "nothing is ticked before it is marked")
		furnace.slots[1] = { item = RAW_IRON, count = 2 }
		furnace.slots[2] = { item = COAL, count = 1 }
		t.eq(#store:tickFurnaces(), 0, "still not marked")
		store:markActive(4, 5, -6)

		local first = store:tickFurnaces()
		t.eq(#first, 1)
		t.eq(first[1].x, 4)
		t.eq(first[1].y, 5)
		t.eq(first[1].z, -6)
		t.ok(first[1].slots, "the coal was used up to light it")
		t.eq(furnace.slots[2], nil)
		t.eq(furnace.data[1], Smelting.fuel(COAL), "lit with coal's burn time")
		t.eq(furnace.data[3], 1, "cooking")

		local second = store:tickFurnaces()
		t.eq(#second, 1)
		t.ok(not second[1].slots, "only the flame and the arrow moved")

		-- The first ingot after 200 ticks of cooking (198 more), then the second.
		local changes = tickFurnaces(store, 198)
		t.eq(#changes, 198, "it changes every tick while it cooks")
		t.ok(changes[198].slots, "the ingot came out")
		for i = 1, 197 do
			t.ok(not changes[i].slots, `data only at tick {i + 2}`)
		end
		t.eq(furnace.slots[3].item, INGOT)
		t.eq(furnace.slots[3].count, 1)
		t.eq(furnace.slots[1].count, 1)
		tickFurnaces(store, 200)
		t.eq(furnace.slots[3].count, 2)
		t.eq(furnace.slots[1], nil, "the raw iron is used up")

		-- It burns on with nothing to cook (coal lasts 1600 ticks after the one that lit it), then
		-- goes out and settles.
		t.eq(#tickFurnaces(store, 1601 - 400), 1201, "burning down")
		t.eq(furnace.data[1], 0, "out")
		t.eq(#store:tickFurnaces(), 0, "settled")
		t.eq(next(store.active), nil, "and no longer ticked")
		t.eq(store:peek(4, 5, -6), furnace, "its ingots keep it")
	end)

	t.test("furnaces: idle ones leave the active set; burning ones are kept, then forgotten", function()
		local store = Containers.new()
		-- Fuel alone does nothing.
		local fuelOnly = store:get(0, 1, 0, FURNACE)
		fuelOnly.slots[2] = { item = COAL, count = 5 }
		store:markActive(0, 1, 0)
		t.eq(#store:tickFurnaces(), 0)
		t.eq(next(store.active), nil, "nothing to do: not ticked again")

		-- Something to smelt but the output holds something else: the furnace notes the item
		-- once, then nothing changes and it stops being ticked.
		local blocked = store:get(0, 2, 0, FURNACE)
		blocked.slots[1] = { item = RAW_IRON, count = 1 }
		blocked.slots[2] = { item = COAL, count = 1 }
		blocked.slots[3] = { item = Items.id.Dirt, count = 1 }
		store:markActive(0, 2, 0)
		t.eq(#tickFurnaces(store, 5), 1, "one change")
		t.eq(next(store.active), nil)
		t.eq(blocked.slots[2].count, 1, "the coal was not wasted")

		-- Marking a chest, or where nothing is stored, does nothing.
		store:get(0, 3, 0, CHEST).slots[1] = { item = COAL, count = 1 }
		store:markActive(0, 3, 0)
		store:markActive(9, 9, 9)
		t.eq(next(store.active), nil)

		-- A furnace that smelted its one item burns on: emptied and closed, it is kept until the
		-- fire goes out, then forgotten like an empty chest.
		local burning = store:get(0, 4, 0, FURNACE)
		store:addViewer(0, 4, 0, "a")
		burning.slots[1] = { item = RAW_IRON, count = 1 }
		burning.slots[2] = { item = COAL, count = 1 }
		store:markActive(0, 4, 0)
		tickFurnaces(store, 200)
		t.eq(burning.slots[3].item, INGOT)
		burning.slots[3] = nil
		store:removeViewer(0, 4, 0, "a")
		t.eq(store:peek(0, 4, 0), burning, "still burning: kept")
		local before = store.count
		tickFurnaces(store, Smelting.fuel(COAL) + 1 - 200)
		t.eq(burning.data[1], 0, "gone out")
		t.eq(store:peek(0, 4, 0), burning, "forgotten on the tick that finds it idle")
		t.eq(#store:tickFurnaces(), 0)
		t.eq(store:peek(0, 4, 0), nil, "forgotten")
		t.eq(store.count, before - 1)

		-- An empty, unlit furnace is forgotten when its last viewer leaves, as chests are.
		store:get(0, 5, 0, FURNACE)
		store:addViewer(0, 5, 0, "a")
		store:removeViewer(0, 5, 0, "a")
		t.eq(store:peek(0, 5, 0), nil)
	end)

	t.test("furnaces: a broken furnace stops cooking; nobody needs to watch one", function()
		local store = Containers.new()
		local furnace = store:get(7, 7, 7, FURNACE)
		furnace.slots[1] = { item = RAW_IRON, count = 3 }
		furnace.slots[2] = { item = COAL, count = 1 }
		store:markActive(7, 7, 7)
		t.eq(#store:viewers(7, 7, 7), 0, "no viewers")
		tickFurnaces(store, 10)
		t.eq(furnace.data[3], 10, "cooks unwatched")
		local taken = store:take(7, 7, 7)
		t.eq(taken, furnace)
		t.eq(next(store.active), nil, "taking it stops its ticks")
		t.eq(#store:tickFurnaces(), 0)
		-- A new furnace in the same place starts afresh, unmarked.
		local fresh = store:get(7, 7, 7, FURNACE)
		t.ok(fresh ~= furnace)
		t.eq(#store:tickFurnaces(), 0)
	end)

	t.test("furnaces: through the inventory, shift-clicked ore and coal cook for every viewer", function()
		local InventoryState = require(server.Players.InventoryState)
		local Menu = require(shared.Inventory.Menu)
		local store = Containers.new()
		local state = InventoryState.new(store)
		state:join("a")
		state:join("b")
		local inventory = state:window("a").inventory
		inventory.slots[1] = { item = RAW_IRON, count = 3 }
		inventory.slots[2] = { item = COAL, count = 2 }
		state:open("a", 1, 2, 3, FURNACE)
		state:open("b", 1, 2, 3, FURNACE)
		local window = state:window("a")
		local furnace = window.container
		t.eq(state:window("b").container, furnace, "one shared furnace")
		state:takeDirty()

		-- What Players/Inventories does with an action in a furnace window.
		local seq = 0
		local function shiftClick(slot: number)
			seq += 1
			local open = state:window("a").container
			local x, y, z = state:openPosition("a")
			state:apply("a", seq, {
				kind = "click",
				window = window.id,
				slot = Menu.windowIndex(window, "inventory", slot),
				clickType = Menu.ClickType.QuickMove,
				button = 0,
			}, false)
			if x ~= nil and open and open.kind == "furnace" then
				store:markActive(x, y, z)
			end
		end
		shiftClick(1)
		shiftClick(2)
		t.eq(furnace.slots[1].item, RAW_IRON, "ore into the input")
		t.eq(furnace.slots[2].item, COAL, "coal into the fuel slot")
		t.eq(#state:takeDirty(), 2, "both viewers see it")

		local changes = tickFurnaces(store, 200 * 3)
		t.eq(furnace.slots[3].count, 3, "three ingots")
		t.eq(furnace.slots[2].count, 1, "one coal burnt")
		local outputs = 0
		for _, change in changes do
			t.eq(change.x, 1)
			if change.slots then
				outputs += 1
			end
		end
		t.eq(outputs, 4, "slots changed four times: lighting and three ingots")

		-- Closing keeps it cooking (it is still burning), and nobody's window is needed for that.
		state:close("a")
		state:close("b")
		t.eq(store:peek(1, 2, 3), furnace)
		t.ok(store.active["1,2,3"], "still burning")
	end)
end
