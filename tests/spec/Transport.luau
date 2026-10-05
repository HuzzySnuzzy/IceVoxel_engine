--[[
	Mekanism pipes on the server, items: Transmitters/TransmitterWorld and Transport on a fake world
	(a table of blocks and a Containers store). Pulling from a chest into another, the speed and
	pull amount of each tier, the nearest destination, route costs (restrictive and slow
	transporters), colours, the furnace's sides, full destinations (re-routing, going home,
	waiting), broken transporters dropping their items, nothing pulled without a destination,
	what is replicated, the Configurator's cycles, the bucket rules, and a conservation fuzz.
]]

return function(t, shared, require, server)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local Coords = require(shared.World.Coords)
	local Protocol = require(shared.Net.Protocol)
	local Transmitters = require(shared.Transmitters)
	local Hash = require(shared.Util.Hash)
	local Containers = require(server.Players.Containers)
	local TransmitterWorld = require(server.Transmitters.TransmitterWorld)
	local UseRules = require(server.Transmitters.UseRules)

	local B, I = Blocks.id, Items.id
	local AIR = Blocks.AIR
	local M = Transmitters.MODES
	local DOWN, UP, NORTH, SOUTH, WEST, EAST = 0, 1, 2, 3, 4, 5
	local Y = 10
	local TIER_NAMES = { "Basic", "Advanced", "Elite", "Ultimate" }
	local T = {}
	for tier, name in TIER_NAMES do
		T[tier] = B[`{name}LogisticalTransporter`]
	end
	local RESTRICTIVE = B.RestrictiveTransporter
	local CHEST, FURNACE = B.Chest, B.Furnace
	local COBBLE, DIRT = B.Cobblestone, B.Dirt
	local REASON = Protocol.TransportRemoveReason

	local function S(item: number, count: number, damage: number?)
		return { item = item, count = count, damage = damage }
	end

	-- A world of blocks in a table (air elsewhere) with chests in a Containers store.
	local function newWorld()
		local blocks: { [number]: number } = {}
		local containers = Containers.new()
		local drops = {}
		local changed: { [number]: number } = {}
		local world = TransmitterWorld.new({
			getBlock = function(x: number, y: number, z: number): number?
				return blocks[Coords.posKey(x, y, z)] or AIR
			end,
			containers = containers,
			inventoryChanged = function(x: number, y: number, z: number)
				local key = Coords.posKey(x, y, z)
				changed[key] = (changed[key] or 0) + 1
			end,
			drop = function(x: number, y: number, z: number, stack)
				table.insert(drops, { x = x, y = y, z = z, stack = stack })
			end,
		})
		local w = { world = world, containers = containers, drops = drops, changed = changed, blocks = blocks }
		function w.block(x: number, y: number, z: number): number
			return blocks[Coords.posKey(x, y, z)] or AIR
		end
		function w.set(x: number, y: number, z: number, block: number)
			local key = Coords.posKey(x, y, z)
			local old = blocks[key] or AIR
			blocks[key] = if block == AIR then nil else block
			TransmitterWorld.blockChanged(world, x, y, z, old, block)
		end
		-- Transporters (or anything) along X from x0 to x1 at (Y, z).
		function w.line(x0: number, x1: number, block: number, z: number?)
			for x = x0, x1 do
				w.set(x, Y, z or 0, block)
			end
		end
		function w.slots(x: number, y: number, z: number)
			return containers:get(x, y, z, w.block(x, y, z)).slots
		end
		-- Items (of `item`, or all) in the inventory at (x, y, z).
		function w.count(x: number, y: number, z: number, item: number?): number
			local container = containers:peek(x, y, z)
			local total = 0
			if container then
				for _, stack in container.slots do
					if stack and (item == nil or stack.item == item) then
						total += stack.count
					end
				end
			end
			return total
		end
		function w.step(n: number?)
			for _ = 1, n or 1 do
				TransmitterWorld.step(world)
			end
		end
		-- Steps until `done` holds; returns the tick count.
		function w.run(done: () -> boolean, max: number): number
			for i = 1, max do
				TransmitterWorld.step(world)
				if done() then
					return i
				end
			end
			error("never happened", 2)
		end
		-- Every item: in containers, in transit and dropped.
		function w.total(): number
			local total = 0
			for _, entry in containers.entries do
				for _, stack in entry.container.slots do
					if stack then
						total += stack.count
					end
				end
			end
			for _, item in world.items do
				total += item.stack.count
			end
			for _, drop in drops do
				total += drop.stack.count
			end
			return total
		end
		function w.ops()
			return TransmitterWorld.takeTransport(world)
		end
		return w
	end

	-- Chest A at x = 0, `length` transporters of `block` pulling from it (the first one's west side
	-- set to PULL) and chest B at the end.
	local function chestToChest(length: number, block: number)
		local w = newWorld()
		w.set(0, Y, 0, CHEST)
		w.line(1, length, block)
		w.set(length + 1, Y, 0, CHEST)
		t.ok(TransmitterWorld.setMode(w.world, 1, Y, 0, WEST, M.PULL), "PULL side set")
		return w
	end

	--[[ Pulling and moving ]]

	t.test("transport: a PULL side moves a chest's items to the chest at the other end", function()
		local w = chestToChest(5, T[1])
		w.slots(0, Y, 0)[1] = S(COBBLE, 10)
		local ticks = w.run(function()
			return w.count(6, Y, 0, COBBLE) == 10
		end, 1000)
		-- One item every 10 ticks (the first at tick 1); each needs 20 ticks a transporter.
		t.eq(ticks, 1 + 9 * 10 + 5 * 20, "the last item arrives")
		t.eq(w.count(0, Y, 0), 0, "the source is empty")
		t.eq(w.world.itemCount, 0, "nothing left in transit")
		t.ok((w.changed[Coords.posKey(6, Y, 0)] or 0) >= 1, "the destination's viewers hear of it")
		t.ok((w.changed[Coords.posKey(0, Y, 0)] or 0) >= 1, "and the source's")
		t.eq(#w.drops, 0, "nothing dropped")
	end)

	t.test("transport: speed and pull amount per tier (Mekanism's TransporterTier)", function()
		for tier = 1, 4 do
			local w = chestToChest(5, T[tier])
			w.slots(0, Y, 0)[1] = S(COBBLE, 64)
			w.step()
			local item = w.world.items[1]
			t.ok(item, "an item was pulled at once")
			t.eq(item.stack.count, Transmitters.TIERS[tier].transporterPull, `{TIER_NAMES[tier]} pulls`)
			local speed = Transmitters.TIERS[tier].transporterSpeed
			local ticks = w.run(function()
				return w.count(6, Y, 0) > 0
			end, 500)
			-- Pulled at tick 1, then 100 / speed ticks per transporter.
			t.eq(1 + ticks, 1 + 5 * (100 // speed), `{TIER_NAMES[tier]} takes 100 / {speed} ticks a block`)
			t.eq(w.count(6, Y, 0), Transmitters.TIERS[tier].transporterPull, "all of it arrived")
		end
	end)

	t.test("transport: items go to the nearest inventory that takes them, then the next", function()
		local w = chestToChest(6, T[1])
		-- A nearer chest on top of the third transporter.
		w.set(3, Y + 1, 0, CHEST)
		w.slots(0, Y, 0)[1] = S(COBBLE, 3)
		w.run(function()
			return w.count(0, Y, 0) == 0 and w.world.itemCount == 0
		end, 1000)
		t.eq(w.count(3, Y + 1, 0), 3, "the nearer chest got everything")
		t.eq(w.count(7, Y, 0), 0, "the far one nothing")
		-- Full of dirt (no room for cobblestone): the far chest's turn.
		local near = w.slots(3, Y + 1, 0)
		for slot = 1, 27 do
			near[slot] = S(DIRT, 64)
		end
		w.slots(0, Y, 0)[1] = S(COBBLE, 2)
		w.run(function()
			return w.count(7, Y, 0) == 2
		end, 1000)
		t.eq(w.count(0, Y, 0), 0, "pulled")
	end)

	t.test("transport: routes avoid restrictive transporters and prefer faster tiers", function()
		local w = newWorld()
		w.set(0, Y, 0, CHEST)
		-- The short way passes a Restrictive Transporter (cost 1000)...
		w.set(1, Y, 0, T[1])
		w.set(2, Y, 0, T[1])
		w.set(3, Y, 0, RESTRICTIVE)
		w.set(4, Y, 0, T[1])
		w.set(5, Y, 0, CHEST)
		-- ...the long way over it seven basic ones (cost 70).
		for _, p in { { 2, 1 }, { 2, 2 }, { 3, 2 }, { 4, 2 }, { 4, 1 } } do
			w.set(p[1], Y + p[2], 0, T[1])
		end
		TransmitterWorld.setMode(w.world, 1, Y, 0, WEST, M.PULL)
		w.slots(0, Y, 0)[1] = S(COBBLE, 2)
		w.step()
		local add = w.ops()[1]
		t.eq(add.op, "add")
		t.eq(
			table.concat(add.path, ","),
			table.concat({ EAST, UP, UP, EAST, EAST, DOWN, DOWN, EAST }, ","),
			"the detour"
		)
		-- Without the detour the restrictive way is the only one, and it is used.
		w.set(3, Y + 2, 0, AIR)
		w.step(10)
		local second = w.ops()
		t.eq(second[#second].op, "add")
		t.eq(table.concat(second[#second].path, ","), table.concat({ EAST, EAST, EAST, EAST }, ","), "straight through")
		t.eq(Transmitters.pathCost(RESTRICTIVE), 1000)

		-- Two basic transporters on the way (cost 20) lose to four ultimate ones (cost 4).
		local v = newWorld()
		v.set(0, Y, 0, CHEST)
		v.line(1, 3, T[1])
		v.set(4, Y, 0, CHEST)
		for x = 1, 4 do
			v.set(x, Y + 1, 0, T[4])
		end
		TransmitterWorld.setMode(v.world, 1, Y, 0, WEST, M.PULL)
		v.slots(0, Y, 0)[1] = S(COBBLE, 1)
		v.step()
		local op = v.ops()[1]
		t.eq(op.op, "add")
		t.eq(table.concat(op.path, ","), table.concat({ UP, EAST, EAST, EAST, DOWN }, ","), "over the ultimate ones")
	end)

	t.test("transport: colours keep lines apart (Mekanism's canInsertToTransporter)", function()
		local w = newWorld()
		w.set(0, Y, 0, CHEST)
		w.set(1, Y, 0, T[1])
		-- East: a red transporter to a near chest.
		w.set(2, Y, 0, T[1])
		w.set(3, Y, 0, CHEST)
		t.ok(TransmitterWorld.setColour(w.world, 2, Y, 0, 15), "red")
		-- Up: two uncoloured ones to a farther chest.
		w.set(1, Y + 1, 0, T[1])
		w.set(1, Y + 2, 0, T[1])
		w.set(1, Y + 3, 0, CHEST)
		TransmitterWorld.setMode(w.world, 1, Y, 0, WEST, M.PULL)
		t.ok(bit32.btest(TransmitterWorld.node(w.world, 1, Y, 0).links, bit32.lshift(1, EAST)), "red joins uncoloured")
		w.slots(0, Y, 0)[1] = S(COBBLE, 2)
		w.run(function()
			return w.count(0, Y, 0) == 0 and w.world.itemCount == 0
		end, 1000)
		t.eq(w.count(1, Y + 3, 0), 2, "uncoloured items keep off the red transporter")
		t.eq(w.count(3, Y, 0), 0)

		-- A red puller makes red items, which may take the red way.
		TransmitterWorld.setColour(w.world, 1, Y, 0, 15)
		w.slots(0, Y, 0)[1] = S(COBBLE, 1)
		w.run(function()
			return w.world.itemCount == 1
		end, 100)
		local item = w.world.items[w.world.nextItem - 1]
		t.eq(item.colour, 15, "the item takes the puller's colour")
		w.run(function()
			return w.world.itemCount == 0
		end, 500)
		t.eq(w.count(3, Y, 0), 1, "red items take the nearer red way")

		-- Blue next to red: no joint at all.
		TransmitterWorld.setColour(w.world, 2, Y, 0, 12)
		t.ok(not bit32.btest(TransmitterWorld.node(w.world, 1, Y, 0).links, bit32.lshift(1, EAST)), "red and blue part")

		-- An uncoloured puller whose only way is coloured pulls nothing.
		local v = newWorld()
		v.set(0, Y, 0, CHEST)
		v.set(1, Y, 0, T[1])
		v.set(2, Y, 0, T[1])
		v.set(3, Y, 0, CHEST)
		TransmitterWorld.setColour(v.world, 2, Y, 0, 4)
		TransmitterWorld.setMode(v.world, 1, Y, 0, WEST, M.PULL)
		v.slots(0, Y, 0)[1] = S(COBBLE, 5)
		v.step(100)
		t.eq(v.count(0, Y, 0), 5, "nothing pulled")
		t.eq(v.world.itemCount, 0)
	end)

	t.test("transport: a furnace takes ore through its top and only fuel through its sides", function()
		local w = newWorld()
		w.set(0, Y, 0, CHEST)
		w.set(1, Y, 0, T[2])
		w.set(2, Y, 0, T[2])
		w.set(3, Y, 0, FURNACE)
		TransmitterWorld.setMode(w.world, 1, Y, 0, WEST, M.PULL)
		local source = w.slots(0, Y, 0)
		source[1] = S(I.RawIron, 3)
		source[2] = S(I.Coal, 5)
		source[3] = S(COBBLE, 4)
		w.step(200)
		local furnace = w.slots(3, Y, 0)
		t.eq(furnace[2] and furnace[2].item, I.Coal, "coal went into the fuel slot through the side")
		t.eq(furnace[2] and furnace[2].count, 5)
		t.eq(furnace[1], nil, "nothing into the input from the side")
		t.eq(w.count(0, Y, 0, I.RawIron), 3, "the ore stays")
		t.eq(w.count(0, Y, 0, COBBLE), 4, "cobblestone is no fuel: it stays")
		t.eq(w.world.itemCount, 0)

		-- A transporter on top reaches the input: the ore goes in (then the cobblestone has no room).
		w.set(2, Y + 1, 0, T[2])
		w.set(3, Y + 1, 0, T[2])
		w.step(200)
		t.eq(furnace[1] and furnace[1].item, I.RawIron, "ore into the input from the top")
		t.eq(furnace[1] and furnace[1].count, 3)
		t.eq(w.count(0, Y, 0, COBBLE), 4, "one input slot, taken")
		t.eq(furnace[3], nil, "nothing into the output")
	end)

	t.test("transport: a full destination re-routes, then sends home, then waits", function()
		local w = chestToChest(5, T[1])
		-- A second chest beside the line, full at first.
		w.set(5, Y, 1, CHEST)
		local side = w.slots(5, Y, 1)
		for slot = 1, 27 do
			side[slot] = S(DIRT, 64)
		end
		w.slots(0, Y, 0)[1] = S(COBBLE, 1)
		w.step()
		t.eq(w.world.itemCount, 1, "on its way")
		local route = w.world.items[1].route
		t.eq(route[#route], Coords.posKey(6, Y, 0), "to the end chest")
		-- The end chest fills up meanwhile; the side chest has room again.
		local target = w.slots(6, Y, 0)
		for slot = 1, 27 do
			target[slot] = S(DIRT, 64)
		end
		side[27] = nil
		w.run(function()
			return w.world.itemCount == 0
		end, 500)
		t.eq(w.count(5, Y, 1, COBBLE), 1, "re-routed into the side chest")

		-- Nowhere to go: home.
		side[27] = S(DIRT, 64)
		target[27] = nil
		w.slots(0, Y, 0)[1] = S(COBBLE, 1)
		w.run(function()
			return w.world.itemCount == 1
		end, 100)
		target[27] = S(DIRT, 64)
		w.run(function()
			return w.world.itemCount == 0
		end, 500)
		t.eq(w.count(0, Y, 0, COBBLE), 1, "back home")

		-- No home either: it waits, and goes on when a chest turns up.
		target[27] = nil
		w.run(function()
			return w.world.itemCount == 1
		end, 100)
		target[27] = S(DIRT, 64)
		w.set(0, Y, 0, AIR)
		w.step(150)
		local item = w.world.items[w.world.nextItem - 1]
		t.ok(item ~= nil and item.target == nil, "waiting")
		t.eq(item.progress, 50, "in the middle of its transporter")
		w.ops()
		w.set(4, Y + 1, 0, CHEST)
		local ticks = w.run(function()
			return w.world.itemCount == 0
		end, 200)
		t.ok(ticks <= 20 + 2 * 20 + 20, "found the new chest within its retry time")
		t.eq(w.count(4, Y + 1, 0, COBBLE), 1)
		t.eq(#w.drops, 0)
	end)

	t.test("transport: a broken transporter drops the items in it", function()
		local w = chestToChest(5, T[1])
		w.slots(0, Y, 0)[1] = S(COBBLE, 2)
		w.step(25)
		local item = w.world.items[1]
		t.eq(item.route[item.hop], Coords.posKey(2, Y, 0), "in the second transporter")
		w.ops()
		w.set(2, Y, 0, AIR)
		t.eq(#w.drops, 1, "dropped")
		t.eq(w.drops[1].x, 2)
		t.eq(w.drops[1].stack.item, COBBLE)
		t.eq(w.drops[1].stack.count, 1)
		local ops = w.ops()
		t.eq(ops[1].op, "remove")
		t.eq(ops[1].id, 1)
		t.eq(ops[1].reason, REASON.Dropped)
		t.eq(w.world.itemCount, 1, "the second item, still in the first transporter, stays")
		-- The line is cut: the second item finds no way and goes home.
		w.step(100)
		t.eq(w.world.itemCount, 0)
		t.eq(w.count(0, Y, 0), 1, "back home")
		t.eq(w.total(), 2, "nothing lost")
	end)

	t.test("transport: waiting items and pulls share a search budget per tick", function()
		local Transport = require(server.Transmitters.Transport)
		local w = newWorld()
		-- A 32 x 32 sheet of transporters: every search visits all 1024 of them.
		local SIDE = 32
		for x = 0, SIDE - 1 do
			for z = 0, SIDE - 1 do
				w.set(x, Y, z, T[1])
			end
		end
		local perTick = math.ceil(Transport.SEARCH_BUDGET / (SIDE * SIDE))
		t.ok(perTick >= 1 and perTick < 6, "a few searches of the sheet per tick")
		-- Items waiting all over it, all due to look for a way on the next tick.
		local waiting = 3 * perTick
		for i = 1, waiting do
			local id = w.world.nextItem
			w.world.nextItem += 1
			w.world.items[id] = {
				id = id,
				stack = S(DIRT, 1),
				colour = 0,
				route = { Coords.posKey(i, Y, (i * 7) % SIDE) },
				hop = 1,
				target = nil,
				face = 0,
				progress = 50,
				wait = 1,
				home = nil,
				sentHop = 1,
				sentSpeed = 0,
			}
			w.world.itemCount += 1
		end
		local function looked(): number
			local n = 0
			for _, item in w.world.items do
				-- (One that looked and found nothing waits RETRY_TICKS again; one still due is at 0.)
				if item.target ~= nil or item.wait > 0 then
					n += 1
				end
			end
			return n
		end
		w.step()
		t.eq(looked(), perTick, "only as many searches as the budget allows")
		t.ok(w.world.searchBudget <= 0 and w.world.searchBudget > -Transport.MAX_SEARCH, "the budget is spent")
		w.step()
		t.eq(looked(), 2 * perTick, "the others look on the next ticks")
		w.step()
		t.eq(looked(), waiting, "every item looked")
		for _, item in w.world.items do
			t.eq(item.target, nil, "still nowhere to go")
		end
		-- With a chest to go to, they find it as the budget allows, and a pull waits for a tick
		-- with searches left.
		for _, item in w.world.items do
			item.wait = 1
		end
		w.set(SIDE, Y, 0, CHEST)
		w.set(-1, Y, 5, CHEST)
		TransmitterWorld.setMode(w.world, 0, Y, 5, WEST, M.PULL)
		w.slots(-1, Y, 5)[1] = S(COBBLE, 10)
		for tick = 1, 3 do
			w.step()
			t.eq(w.count(-1, Y, 5), 10, `tick {tick}: the searches went to the waiting items`)
		end
		local routed = 0
		for _, item in w.world.items do
			if item.target == "dest" then
				routed += 1
			end
		end
		t.eq(routed, waiting, "every waiting item found the chest")
		w.step()
		t.eq(w.count(-1, Y, 5), 9, "then the pull")
		w.run(function()
			return w.world.itemCount == 0 and w.count(-1, Y, 5) == 0
		end, 4000)
		t.eq(w.count(SIDE, Y, 0, DIRT), waiting, "delivered")
		t.eq(w.count(SIDE, Y, 0, COBBLE), 10)
	end)

	t.test("transport: nothing is pulled without a destination", function()
		local w = newWorld()
		w.set(0, Y, 0, CHEST)
		w.line(1, 3, T[1])
		TransmitterWorld.setMode(w.world, 1, Y, 0, WEST, M.PULL)
		w.slots(0, Y, 0)[1] = S(COBBLE, 5)
		w.step(200)
		t.eq(w.count(0, Y, 0), 5)
		t.eq(w.changed[Coords.posKey(0, Y, 0)], nil, "the chest was never touched")
		t.ok(TransmitterWorld.node(w.world, 1, Y, 0).pullFailures >= 4, "it backs off")
		-- A PULL side never gives: a chest only reached through one is no destination.
		w.set(4, Y, 0, CHEST)
		TransmitterWorld.setMode(w.world, 3, Y, 0, EAST, M.PULL)
		w.step(200)
		t.eq(w.count(4, Y, 0), 0, "not through a PULL side")
		-- PUSH gives.
		TransmitterWorld.setMode(w.world, 3, Y, 0, EAST, M.PUSH)
		w.step(300)
		t.eq(w.count(4, Y, 0), 5, "PUSH gives")
		-- NONE cuts.
		TransmitterWorld.setMode(w.world, 3, Y, 0, EAST, M.NONE)
		w.slots(0, Y, 0)[1] = S(COBBLE, 1)
		w.step(200)
		t.eq(w.count(4, Y, 0), 5, "NONE cuts")
	end)

	--[[ Replication ]]

	t.test("transport: adds carry the path, removes the reason; records and chunks", function()
		local w = chestToChest(3, T[1])
		w.slots(0, Y, 0)[1] = S(COBBLE, 1)
		w.step()
		local ops = w.ops()
		t.eq(#ops, 1)
		local add = ops[1]
		t.eq(add.op, "add")
		t.eq(add.item, COBBLE)
		t.eq(add.count, 1)
		t.eq(add.x, 1)
		t.eq(add.y, Y)
		t.eq(add.z, 0)
		t.eq(add.progress, 0)
		t.eq(add.speed, 5)
		t.eq(table.concat(add.path, ","), "5,5,5", "east three times, the last into the chest")
		-- It encodes.
		local decoded = Protocol.decodeTransport(Protocol.encodeTransport(ops))
		t.ok(decoded and decoded[1].op == "add")
		w.step(60)
		ops = w.ops()
		t.eq(#ops, 1, "nothing per block")
		t.eq(ops[1].op, "remove")
		t.eq(ops[1].reason, REASON.Arrived)

		-- A new item later in another tier's transporter is sent again (its speed changes).
		local v = newWorld()
		v.set(0, Y, 0, CHEST)
		v.set(1, Y, 0, T[1])
		v.set(2, Y, 0, T[4])
		v.set(3, Y, 0, CHEST)
		TransmitterWorld.setMode(v.world, 1, Y, 0, WEST, M.PULL)
		v.slots(0, Y, 0)[1] = S(COBBLE, 1)
		v.step(21)
		local again = v.ops()
		t.eq(#again, 2, "added, then added again at the faster transporter")
		t.eq(again[2].speed, 50)
		t.eq(again[2].x, 2)
		t.eq(#again[2].path, 1)

		-- A route longer than a message holds (255 sides) is sent again on the way.
		local long = chestToChest(300, T[4])
		long.slots(0, Y, 0)[1] = S(COBBLE, 1)
		long.step()
		local first = long.ops()[1]
		t.eq(first.op, "add")
		t.eq(#first.path, Protocol.MAX_PATH, "the first 255 sides")
		-- Two ticks a block: 128 blocks on, it is sent again with the rest of its way.
		long.step(128 * 2)
		local resent = long.ops()
		t.eq(#resent, 1, "once")
		t.eq(resent[1].op, "add")
		t.eq(resent[1].x, 1 + 128)
		t.eq(#resent[1].path, 300 - 128, "the rest, into the chest")
		long.run(function()
			return long.count(301, Y, 0) == 1
		end, 400)

		-- Records: the PULL side set above, once.
		local records, tanks = TransmitterWorld.takeRecords(w.world)
		t.eq(#records, 1)
		t.eq(records[1].x, 1)
		t.eq(records[1].modes, Transmitters.withMode(0, WEST, M.PULL))
		t.eq(records[1].colour, 0)
		t.eq(records[1].fluid, 0)
		t.eq(#tanks, 0)
		records = TransmitterWorld.takeRecords(w.world)
		t.eq(#records, 0, "not twice")
		local chunk = TransmitterWorld.chunkRecords(w.world, 0, 0)
		t.eq(#chunk, 1, "the chunk's non-default transmitters")
		t.eq(chunk[1].x, 1)
		t.eq(#TransmitterWorld.chunkRecords(w.world, 5, 5), 0)
		-- Back to the default state: a record says so.
		TransmitterWorld.setMode(w.world, 1, Y, 0, WEST, M.NORMAL)
		records = TransmitterWorld.takeRecords(w.world)
		t.eq(#records, 1)
		t.eq(records[1].modes, 0)
		t.eq(#TransmitterWorld.chunkRecords(w.world, 0, 0), 0, "default states need no record")
	end)

	--[[ The Configurator ]]

	t.test("configurator: sides cycle normal, push, pull, none, and the joint matches", function()
		local w = newWorld()
		w.line(0, 2, T[1])
		local expected = { M.PUSH, M.PULL, M.NONE, M.NORMAL }
		for _, mode in expected do
			t.eq(TransmitterWorld.cycleMode(w.world, 1, Y, 0, EAST), mode)
			local modes = TransmitterWorld.state(w.world, 1, Y, 0)
			local other = TransmitterWorld.state(w.world, 2, Y, 0)
			t.eq(Transmitters.modeOf(modes, EAST), mode, "this side")
			t.eq(Transmitters.modeOf(other, WEST), mode, "the neighbour's side facing back")
			local joined = bit32.btest(TransmitterWorld.node(w.world, 1, Y, 0).links, bit32.lshift(1, EAST))
			t.eq(joined, mode ~= M.NONE, "joined unless NONE")
		end
		t.eq(TransmitterWorld.cycleMode(w.world, 5, Y, 0, EAST), nil, "no transmitter there")
		t.eq(TransmitterWorld.cycleMode(w.world, 1, Y, 0, 6), nil, "bad side")
		-- A pipe beside a transporter keeps its side.
		w.set(1, Y + 1, 0, B.BasicMechanicalPipe)
		TransmitterWorld.cycleMode(w.world, 1, Y, 0, UP)
		t.eq(Transmitters.modeOf((TransmitterWorld.state(w.world, 1, Y + 1, 0)), DOWN), M.NORMAL, "another kind")

		-- Colours: none, the 16 dyes, none again; pipes have none.
		for colour = 1, 16 do
			t.eq(TransmitterWorld.cycleColour(w.world, 1, Y, 0), colour)
		end
		t.eq(TransmitterWorld.cycleColour(w.world, 1, Y, 0), 0)
		t.eq(TransmitterWorld.cycleColour(w.world, 1, Y + 1, 0), nil, "pipes have no colour")
		t.eq(UseRules.modeNotice(M.PULL), "Connection type changed to pull")
		t.eq(UseRules.modeNotice(M.NONE), "Connection type changed to none")
		t.eq(UseRules.colourNotice(15), "Colour bumped to: red")
		t.eq(UseRules.colourNotice(9), "Colour bumped to: light grey")
		t.eq(UseRules.colourNotice(0), "Colour bumped to: none")
	end)

	--[[ Buckets ]]

	t.test("buckets: Minecraft's filled results, creative, tanks and where water goes", function()
		local bucket, water = I.Bucket, I.WaterBucket
		-- A stack of three: one fills, the water bucket is handed over.
		local held, give = UseRules.fillFromWorld(S(bucket, 3), false, false)
		t.eq(held and held.item, bucket)
		t.eq(held and held.count, 2)
		t.eq(give and give.item, water)
		held, give = UseRules.fillFromWorld(S(bucket, 1), false, false)
		t.eq(held and held.item, water, "the last bucket becomes the water bucket")
		t.eq(give, nil)
		-- Creative keeps the bucket and gets a water bucket unless it has one.
		held, give = UseRules.fillFromWorld(S(bucket, 1), true, false)
		t.eq(held and held.item, bucket)
		t.eq(held and held.count, 1)
		t.eq(give and give.item, water)
		held, give = UseRules.fillFromWorld(S(bucket, 1), true, true)
		t.eq(give, nil, "no duplicates")
		-- From a tank: creative players get nothing (Mekanism).
		held, give = UseRules.fillFromTank(S(bucket, 2), false)
		t.eq(held and held.count, 1)
		t.eq(give and give.item, water)
		held, give = UseRules.fillFromTank(S(bucket, 1), true)
		t.eq(held and held.item, bucket)
		t.eq(give, nil)
		-- Emptied: an empty bucket, or the same water bucket in creative.
		held, give = UseRules.emptied(S(water, 1), false)
		t.eq(held and held.item, bucket)
		t.eq(give, nil)
		held = UseRules.emptied(S(water, 1), true)
		t.eq(held and held.item, water)

		-- Where water goes: the block if replaceable, else beyond the side.
		local w = newWorld()
		w.set(0, Y, 0, B.Stone)
		local function get(x: number, y: number, z: number): number?
			return w.block(x, y, z)
		end
		local x, y, z = UseRules.waterTarget(get, 0, Y + 1, 0, UP)
		t.eq(x, 0, "air takes it")
		t.eq(y, Y + 1)
		x, y, z = UseRules.waterTarget(get, 0, Y, 0, UP)
		t.eq(y, Y + 1, "beyond the clicked side of stone")
		t.eq(z, 0)
		w.set(0, Y + 1, 0, B.Stone)
		t.eq((UseRules.waterTarget(get, 0, Y, 0, UP)), nil, "stone both ways")
		w.set(0, Y + 1, 0, UseRules.WATER_SOURCE)
		x = UseRules.waterTarget(get, 0, Y, 0, UP)
		t.eq(x, 0, "water is replaceable")
		t.eq((UseRules.waterTarget(get, 0, 1023, 0, UP)), 0, "air at the top")
		t.eq((UseRules.waterTarget(function()
			return B.Stone
		end, 0, 1023, 0, UP)), nil, "not above the world")
		t.ok(UseRules.isWaterSource(Blocks.fluidId("Water", 0)))
		t.ok(not UseRules.isWaterSource(Blocks.fluidId("Water", 3)), "flowing water is no source")

		-- Tanks: full or empty.
		w.set(5, Y, 0, B.BasicFluidTank)
		local WATER = Transmitters.FLUIDS.WATER
		t.eq(TransmitterWorld.drainTank(w.world, 5, Y, 0, 1000, true), 0, "an empty tank gives nothing")
		t.eq(TransmitterWorld.fillTank(w.world, 5, Y, 0, WATER, 1000), 1000)
		t.eq(TransmitterWorld.fillTank(w.world, 5, Y, 0, Transmitters.FLUIDS.NONE, 1000), 0, "no fluid")
		local amount, fluid = TransmitterWorld.drainTank(w.world, 5, Y, 0, 1000, true)
		t.eq(amount, 1000)
		t.eq(fluid, WATER)
		t.eq(TransmitterWorld.tank(w.world, 5, Y, 0).amount, 1000, "simulating changes nothing")
		TransmitterWorld.tank(w.world, 5, Y, 0).amount = 31500
		t.eq(TransmitterWorld.fillTank(w.world, 5, Y, 0, WATER, 1000, true), 500, "room for half a bucket")
		t.eq(TransmitterWorld.fillTank(w.world, 6, Y, 0, WATER, 1000), 0, "no tank")
		TransmitterWorld.drainTank(w.world, 5, Y, 0, 31500)
		t.eq(TransmitterWorld.tank(w.world, 5, Y, 0).fluid, Transmitters.FLUIDS.NONE, "empty again")
	end)

	t.test("buckets: the held stack is replaced and water buckets handed over (InventoryState)", function()
		local InventoryState = require(server.Players.InventoryState)
		local state = InventoryState.new(Containers.new())
		state:join("p")
		local inventory = state:window("p").inventory
		inventory.selected = 2
		inventory.slots[2] = S(I.Bucket, 3)
		t.ok(not state:has("p", I.WaterBucket))
		local held, give = UseRules.fillFromWorld(state:heldStack("p"), false, state:has("p", I.WaterBucket))
		state:takeDirty()
		state:setHeld("p", held)
		t.eq(state:give("p", give), nil, "it fits")
		t.eq(inventory.slots[2].count, 2, "one bucket fewer in hand")
		t.eq(inventory.slots[1] and inventory.slots[1].item, I.WaterBucket, "the water bucket in the first free slot")
		t.ok(state:has("p", I.WaterBucket))
		t.eq(#state:takeDirty(), 1, "a snapshot is due")
		state:setHeld("p", nil)
		t.eq(inventory.slots[2], nil, "emptied")
		state:setHeld("p", S(I.Bucket, 0))
		t.eq(inventory.slots[2], nil, "a count below 1 empties it")
		-- A full inventory gives back what does not fit.
		for slot = 1, 36 do
			inventory.slots[slot] = S(COBBLE, 64)
		end
		local left = state:give("p", S(I.WaterBucket, 1))
		t.eq(left and left.item, I.WaterBucket, "nothing fits")
		t.eq(state:give("nobody", S(COBBLE, 2)) and 2, 2, "no such player: all of it back")
	end)

	--[[ Conservation ]]

	t.test("transport: no item is lost or made (fuzz)", function()
		local rng = Hash.rng(1234)
		local blocks = { T[1], T[2], T[3], T[4], RESTRICTIVE, CHEST, CHEST, FURNACE, AIR, AIR }
		local itemsPool = { COBBLE, DIRT, I.Coal, I.RawIron, I.Stick, I.IronIngot }
		local arrived, dropped, rerouted = 0, 0, 0
		for round = 1, 40 do
			local w = newWorld()
			local removed = 0
			local function place(x: number, y: number, z: number, block: number)
				local old = w.block(x, y, z)
				if old == CHEST or old == FURNACE then
					local container = w.containers:take(x, y, z)
					if container then
						for _, stack in container.slots do
							if stack then
								removed += stack.count
							end
						end
					end
				end
				w.set(x, y, z, block)
			end
			for x = 0, 4 do
				for y = Y, Y + 2 do
					for z = 0, 2 do
						place(x, y, z, blocks[rng:int(1, #blocks)])
					end
				end
			end
			local initial = 0
			for x = 0, 4 do
				for y = Y, Y + 2 do
					for z = 0, 2 do
						local block = w.block(x, y, z)
						if block == CHEST then
							local slots = w.slots(x, y, z)
							for slot = 1, 5 do
								local count = rng:int(1, 64)
								slots[slot] = S(itemsPool[rng:int(1, #itemsPool)], count)
								initial += count
							end
						elseif Transmitters.isTransmitter(block) then
							for side = 0, 5 do
								if rng:float() < 0.3 then
									TransmitterWorld.setMode(w.world, x, y, z, side, rng:int(0, 3))
								end
							end
							if rng:float() < 0.2 then
								TransmitterWorld.setColour(w.world, x, y, z, rng:int(0, 3))
							end
						end
					end
				end
			end
			for _ = 1, 30 do
				w.step(rng:int(1, 40))
				local seen: { [number]: boolean } = {}
				for _, op in w.ops() do
					if op.op == "remove" then
						arrived += if op.reason == REASON.Arrived then 1 else 0
						dropped += if op.reason == REASON.Dropped then 1 else 0
					elseif seen[op.id] then
						rerouted += 1
					end
					seen[op.id] = true
				end
				local x, y, z = rng:int(0, 4), rng:int(Y, Y + 2), rng:int(0, 2)
				local roll = rng:float()
				if roll < 0.4 then
					place(x, y, z, blocks[rng:int(1, #blocks)])
				elseif roll < 0.8 and Transmitters.isTransmitter(w.block(x, y, z)) then
					TransmitterWorld.cycleMode(w.world, x, y, z, rng:int(0, 5))
				elseif Transmitters.isTransmitter(w.block(x, y, z)) then
					TransmitterWorld.cycleColour(w.world, x, y, z)
				end
				t.eq(w.total() + removed, initial, `round {round}: items conserved`)
			end
			for _, item in w.world.items do
				t.ok(item.stack.count >= 1 and item.stack.count <= Items.maxStack(item.stack.item), "a stack at most")
			end
		end
		-- (The fuzz did move things: deliveries, drops and re-routes all happened.)
		t.ok(arrived > 100, `items arrived ({arrived})`)
		t.ok(dropped > 5, `items dropped ({dropped})`)
		t.ok(rerouted > 5, `items re-routed ({rerouted})`)
	end)
end
