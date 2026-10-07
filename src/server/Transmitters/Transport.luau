--!strict
--[[
	Items in Logistical Transporters: Mekanism's LogisticalTransporterBase, TransporterStack and
	TransporterPathfinder, simplified. Transmitters/TransmitterWorld runs `step` 20 times a second;
	this module only reads and changes its state (Transmitters/Types), and reaches chests and
	furnaces through its Env, so it is pure.

	Pulling (LogisticalTransporterBase.onUpdateServer). A transporter with PULL sides on inventories
	pulls through each of them, then waits PULL_DELAY (10) ticks; when nothing was there it looks
	again after 3 ticks, and when items were there but could go nowhere it backs off
	min(40, e^failures) ticks. A pull is Mekanism's TransitRequest: the item types the inventory
	gives through its face towards the transporter (Transmitters.available: a chest's anything, a
	furnace's or machine's results only, never its input or fuel), in order; the first type with
	a destination sends up to the tier's pull amount (1 / 16 / 32 / 64, never more than a stack)
	or as many as the destination takes. The destination is found before anything is taken, so
	items are never pulled with nowhere to go. A pulled item takes the transporter's colour.

	Ejected items (Mekanism's ejector: TileComponentEjector into canReceiveFrom sides). A furnace
	or a machine with output slots (Transmitters.ejects) pushes its results out on its own into
	the transporters whose side on it receives (NORMAL or PULL: Transmitters.receives; never PUSH
	or NONE). Here that is the same pass as a pull, on the same timer, one pass per side: a NORMAL
	side on such a block takes what its output slots hold (Transmitters.results), a PULL side what
	its face gives (the results and a fuel slot's leftovers), and on either a whole stack may go
	at once (the ejector's amount) rather than the tier's pull amount. Like pulled items they only
	leave with a destination (never the furnace or machine they came from, which is no home for
	them either: with nowhere left to go they wait) and take the transporter's colour. Chests next
	to a furnace or machine get theirs from Transmitters/Eject.

	Routes (TransporterPathfinder). From the transporter an item is in, a search over joined
	transporters (Dijkstra) adds Mekanism's cost of every transporter entered
	(Transmitters.pathCost: 10 / 5 / 2.5 / 1 from Basic to Ultimate, 1000 for the Restrictive
	Transporter) and only enters transporters that carry the item's colour (Transmitters.carries:
	uncoloured ones and its own colour). An inventory next to a reached transporter costs 1 more;
	the cheapest one (then the fewest steps) that would take at least one of the items through
	the face towards the transporter wins (Transmitters.room, after the items already on their way
	there: Mekanism's TransporterManager predictions). Only NORMAL and PUSH sides give items to an
	inventory (Transmitters.outputs), and the inventory the item came from is never a destination.
	Failing that, the item goes home: back to that inventory through any side joined to it (not
	a furnace's or machine's results: they never go back in). Failing that too, it waits where it
	is (in the middle of its transporter) and looks again every RETRY_TICKS (20) ticks.
	(Mekanism's items wander along the transporters instead.) A search visits MAX_SEARCH (4096)
	transporters at most, and once a tick's searches have visited SEARCH_BUDGET (4096), waiting
	items and pulls wait for a later tick, so big networks full of waiting items cannot stall the
	server.

	Moving. Every tick an item's progress grows by its transporter's speed (5 / 10 / 20 / 50 a
	tick, 100 = one block). Halfway through it checks the way ahead (the next transporter still
	joined and carrying it, or the inventory still joined, giving and taking it) and finds a new
	route if not; at 100 it enters the next transporter (progress - 100) or, at the end, the
	inventory: what fits goes in (Transmitters.insert through that face; viewers see it at once
	and a furnace starts cooking) and the rest finds a new route from the middle of the
	transporter.

	Breaking. The items in a transporter that goes drop there as item entities (Env.drop).

	Item data (Items `data`) rides along: a stack keeps it from the inventory it was pulled from to
	the one it ends in (or the ground), and only joins stacks with the same data.

	Replication (Protocol Transport ops in `world.ops`): an `add` when an item enters, is re-routed
	(also when it waits), changes speed (enters a transporter of another tier) or has travelled
	RESEND_HOPS hops of a route longer than Protocol.MAX_PATH; a `remove` when it arrives, drops
	or is gone. Clients move items along the path themselves; nothing is sent per block.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Items = require(Shared.Items)
local Protocol = require(Shared.Net.Protocol)
local Transmitters = require(Shared.Transmitters)

local Grid = require(script.Parent.Grid)
local Types = require(script.Parent.Types)

type World = Types.World
type Node = Types.Node
type Item = Types.Item
type Stack = Types.Stack
type Slots = Transmitters.Slots
type TransportOp = Types.TransportOp

local BLOCK_PROGRESS = Transmitters.BLOCK_PROGRESS
local HALF = BLOCK_PROGRESS // 2
local PULL_DELAY = Transmitters.PULL_DELAY
-- Ticks between pulls when nothing could be pulled (Mekanism's 3), and the longest wait after
-- pulls that found items but nowhere to send them (Mekanism: min(40, e^failures)).
local IDLE_DELAY = 3
local MAX_BACKOFF = 40
-- Ticks a waiting item waits before it looks for a way again.
local RETRY_TICKS = 20
-- Most transporters one route search visits (a guard against huge networks).
local MAX_SEARCH = 4096
--[[
	Transporters the route searches may visit per tick before waiting items stop looking and
	pulls stop (both carry on the next tick; a search that starts finishes, so a tick visits at
	most this plus MAX_SEARCH for them). Items already moving always find their way. Without it,
	items waiting in a big network (say 200 in 4096 transporters) would each search it every
	RETRY_TICKS ticks, hundreds of milliseconds a tick.
]]
local SEARCH_BUDGET = 4096
-- A route longer than Protocol.MAX_PATH is sent again after this many hops.
local RESEND_HOPS = 128
local REMOVE = Protocol.TransportRemoveReason
local PULL = Transmitters.MODES.PULL
local EMPTY: Slots = table.freeze({})

local modeOf = Transmitters.modeOf
local opposite = Transmitters.opposite

local Transport = {}

Transport.RETRY_TICKS = RETRY_TICKS
Transport.IDLE_DELAY = IDLE_DELAY
Transport.MAX_SEARCH = MAX_SEARCH
Transport.SEARCH_BUDGET = SEARCH_BUDGET

local function has(mask: number, side: number): boolean
	return bit32.btest(mask, bit32.lshift(1, side))
end

--[[ Inventories ]]

-- The item inventory (chest, furnace) at `key`, if there is one there, and its position.
local function inventoryAt(world: World, key: number): (number?, number, number, number)
	local x, y, z = Grid.decode(key)
	local block = world.env.getBlock(x, y, z)
	if block ~= nil and Transmitters.isItemAcceptor(block) then
		return block, x, y, z
	end
	return nil, x, y, z
end

-- The slots of `block`'s inventory at (x, y, z) as they are (read only; none stored: empty).
local function slotsAt(world: World, x: number, y: number, z: number, block: number): Slots
	local container = world.env.containers:peek(x, y, z)
	if container and container.block == block then
		return container.slots
	end
	return EMPTY
end

-- Puts `slots` (Transmitters.insert / extract's new table) into the inventory at (x, y, z), stack
-- tables replaced as Inventory/Menu does, so its viewers' windows (the same container) see it.
local function store(world: World, x: number, y: number, z: number, block: number, slots: Slots)
	local container = world.env.containers:get(x, y, z, block)
	local current = container.slots
	for slot in current do
		if slots[slot] == nil then
			current[slot] = nil
		end
	end
	for slot, stack in slots do
		current[slot] = stack
	end
	local changed = world.env.inventoryChanged
	if changed then
		changed(x, y, z)
	end
end

-- Items on their way to an inventory count against its room (Mekanism's TransporterManager).
local function track(world: World, item: Item)
	if item.target == nil then
		return
	end
	local inventory = item.route[#item.route]
	local list = world.incoming[inventory]
	if list == nil then
		list = {}
		world.incoming[inventory] = list
	end
	list[item.id] = item
end

local function untrack(world: World, item: Item)
	if item.target == nil then
		return
	end
	local inventory = item.route[#item.route]
	local list = world.incoming[inventory]
	if list then
		list[item.id] = nil
		if next(list) == nil then
			world.incoming[inventory] = nil
		end
	end
end

-- The slots of the inventory at `key` once the items on their way there (but `except`) are in.
local function predicted(
	world: World,
	key: number,
	block: number,
	x: number,
	y: number,
	z: number,
	except: Item?
): Slots
	local slots = slotsAt(world, x, y, z, block)
	local list = world.incoming[key]
	if list == nil then
		return slots
	end
	local ordered: { Item } = {}
	for _, item in list do
		if item ~= except then
			table.insert(ordered, item)
		end
	end
	table.sort(ordered, function(a, b)
		return a.id < b.id
	end)
	for _, item in ordered do
		slots = (Transmitters.insert(block, item.face, slots, item.stack))
	end
	return slots
end

--[[ Routes ]]

-- An inventory side reached by a search: its cost and steps, the inventory and its face, the
-- transporter next to it and whether that side gives items (NORMAL / PUSH).
type Candidate = { score: number, hops: number, inventory: number, face: number, via: number, outputs: boolean }

-- (A binary heap of { cost, hops, key }, cheapest first, then fewest hops, then lowest key.)
local function precedes(a: { number }, b: { number }): boolean
	if a[1] ~= b[1] then
		return a[1] < b[1]
	elseif a[2] ~= b[2] then
		return a[2] < b[2]
	end
	return a[3] < b[3]
end

local function push(heap: { { number } }, entry: { number })
	table.insert(heap, entry)
	local i = #heap
	while i > 1 do
		local parent = i // 2
		if not precedes(heap[i], heap[parent]) then
			break
		end
		heap[i], heap[parent] = heap[parent], heap[i]
		i = parent
	end
end

local function pop(heap: { { number } }): { number }
	local top = heap[1]
	local last = table.remove(heap) :: { number }
	local n = #heap
	if n > 0 then
		heap[1] = last
		local i = 1
		while true do
			local l, r = i * 2, i * 2 + 1
			local smallest = i
			if l <= n and precedes(heap[l], heap[smallest]) then
				smallest = l
			end
			if r <= n and precedes(heap[r], heap[smallest]) then
				smallest = r
			end
			if smallest == i then
				break
			end
			heap[i], heap[smallest] = heap[smallest], heap[i]
			i = smallest
		end
	end
	return top
end

--[[
	Every inventory side an item of `colour` in transporter `start` can reach, cheapest first
	(Mekanism's TransporterPathfinder scores: the transporters entered plus 1), and the search's
	back links to build routes with. The transporters it visits count against the tick's
	`world.searchBudget`.
]]
local function search(world: World, start: Node, colour: number): ({ Candidate }, { [number]: number })
	local cost: { [number]: number } = { [start.key] = 0 }
	local hops: { [number]: number } = { [start.key] = 0 }
	local back: { [number]: number } = {}
	local done: { [number]: boolean } = {}
	local heap: { { number } } = { { 0, 0, start.key } }
	local candidates: { Candidate } = {}
	local visited = 0
	while #heap > 0 and visited < MAX_SEARCH do
		local key = pop(heap)[3]
		local node = world.nodes[key]
		if done[key] or node == nil then
			continue
		end
		done[key] = true
		visited += 1
		local c, h = cost[key], hops[key]
		for side = 0, 5 do
			if has(node.acceptors, side) then
				local inventory = Grid.neighbour(key, side)
				if inventory then
					table.insert(candidates, {
						score = c + 1,
						hops = h + 1,
						inventory = inventory,
						face = opposite(side),
						via = key,
						outputs = Transmitters.outputs(modeOf(node.modes, side)),
					})
				end
			elseif has(node.links, side) then
				local nextKey = Grid.neighbour(key, side)
				local nextNode = if nextKey then world.nodes[nextKey] else nil
				if
					nextKey
					and nextNode
					and not done[nextKey]
					and nextNode.kind == "item"
					and Transmitters.carries(nextNode.colour, colour)
				then
					local nc, nh = c + Transmitters.pathCost(nextNode.block), h + 1
					local old = cost[nextKey]
					if old == nil or nc < old or (nc == old and nh < hops[nextKey]) then
						cost[nextKey], hops[nextKey], back[nextKey] = nc, nh, key
						push(heap, { nc, nh, nextKey })
					end
				end
			end
		end
	end
	world.searchBudget -= visited
	table.sort(candidates, function(a, b)
		if a.score ~= b.score then
			return a.score < b.score
		elseif a.hops ~= b.hops then
			return a.hops < b.hops
		elseif a.inventory ~= b.inventory then
			return a.inventory < b.inventory
		end
		return a.face < b.face
	end)
	return candidates, back
end

-- The route to a candidate: pos keys from `start` through the transporters to the inventory.
local function routeTo(back: { [number]: number }, start: number, candidate: Candidate): { number }
	local reversed = { candidate.inventory, candidate.via }
	local key = candidate.via
	while key ~= start do
		key = back[key]
		table.insert(reversed, key)
	end
	local route = table.create(#reversed)
	for i = #reversed, 1, -1 do
		table.insert(route, reversed[i])
	end
	return route
end

--[[
	The first candidate that takes at least one of `stack` and how many it takes. Without `home`:
	inventories on NORMAL / PUSH sides but `skip` (where the item came from). With `home`: only
	that inventory, through any side joined to it. `except` is the item being routed (its own
	prediction does not count).
]]
local function choose(
	world: World,
	candidates: { Candidate },
	stack: Stack,
	skip: number?,
	home: number?,
	except: Item?
): (Candidate?, number)
	local cache: { [number]: Slots } = {}
	for _, candidate in candidates do
		local inventory = candidate.inventory
		local wanted = if home then inventory == home else candidate.outputs and inventory ~= skip
		if wanted then
			local block, x, y, z = inventoryAt(world, inventory)
			if block then
				local slots = cache[inventory]
				if slots == nil then
					slots = predicted(world, inventory, block, x, y, z, except)
					cache[inventory] = slots
				end
				local room = Transmitters.room(block, candidate.face, slots, stack)
				if room >= 1 then
					return candidate, room
				end
			end
		end
	end
	return nil, 0
end

--[[ Replication ]]

-- The Transport add for `item` as it is now (startTime 0: the caller knows the clock), and its
-- speed.
local function addOp(world: World, item: Item): (TransportOp, number)
	local route, hop = item.route, item.hop
	local node = world.nodes[route[hop]]
	local x, y, z = Grid.decode(route[hop])
	local path: { number } = {}
	for i = hop, math.min(#route - 1, hop + Protocol.MAX_PATH - 1) do
		table.insert(path, Grid.sideBetween(route[i], route[i + 1]) or 0)
	end
	local speed = if item.target ~= nil and node then Transmitters.speed(node.block) else 0
	return {
		op = "add",
		id = item.id,
		item = item.stack.item,
		count = item.stack.count,
		x = x,
		y = y,
		z = z,
		progress = math.clamp(math.floor(item.progress), 0, BLOCK_PROGRESS),
		speed = speed,
		startTime = 0,
		path = path,
	},
		speed
end

local function sendAdd(world: World, item: Item)
	local op, speed = addOp(world, item)
	item.sentHop = item.hop
	item.sentSpeed = speed
	table.insert(world.ops, op)
end

local function remove(world: World, item: Item, reason: number)
	untrack(world, item)
	world.items[item.id] = nil
	world.itemCount -= 1
	table.insert(world.ops, { op = "remove", id = item.id, reason = reason })
end

--[[ Moving ]]

--[[
	Finds `item` (in `node`) a new route: a destination, else home, else it waits in the middle of
	`node`. Sends the change, except when a waiting item still finds nothing (`quiet`). True if
	it found a way.
]]
local function reroute(world: World, item: Item, node: Node, quiet: boolean?): boolean
	untrack(world, item)
	local candidates, back = search(world, node, item.colour)
	local target: ("dest" | "home")? = "dest"
	local candidate = choose(world, candidates, item.stack, item.from, nil, item)
	if candidate == nil and item.home then
		target = "home"
		candidate = choose(world, candidates, item.stack, nil, item.home, item)
	end
	if candidate then
		item.route = routeTo(back, node.key, candidate)
		item.hop = 1
		item.target = target
		item.face = candidate.face
		track(world, item)
		sendAdd(world, item)
		return true
	end
	local wasWaiting = item.target == nil
	item.route = { node.key }
	item.hop = 1
	item.target = nil
	item.progress = HALF
	item.wait = RETRY_TICKS
	if not (quiet and wasWaiting) then
		sendAdd(world, item)
	end
	return false
end

-- Does side `side` of `node` still lead to an inventory for an item going to `target` (any joined
-- side home, NORMAL / PUSH ones elsewhere)?
local function delivers(node: Node, side: number, target: ("dest" | "home")?): boolean
	return has(node.acceptors, side) and (target == "home" or Transmitters.outputs(modeOf(node.modes, side)))
end

-- May an item of `colour` go from `node` through `side` into the transporter `nextNode`?
local function canEnter(node: Node, side: number, nextNode: Node?, colour: number): boolean
	return nextNode ~= nil
		and nextNode.kind == "item"
		and has(node.links, side)
		and Transmitters.carries(nextNode.colour, colour)
end

-- Halfway check: is the way ahead of `item` (in `node`) still open?
local function wayAhead(world: World, item: Item, node: Node): boolean
	local nextKey = item.route[item.hop + 1]
	local side = if nextKey then Grid.sideBetween(node.key, nextKey) else nil
	if nextKey == nil or side == nil then
		return false
	end
	if item.hop + 1 == #item.route then
		local block, x, y, z = inventoryAt(world, nextKey)
		return block ~= nil
			and delivers(node, side, item.target)
			and Transmitters.room(block, opposite(side), slotsAt(world, x, y, z, block), item.stack) >= 1
	end
	return canEnter(node, side, world.nodes[nextKey], item.colour)
end

-- `item` (in `node`) reached the end of its route: into the inventory with what fits.
local function arrive(world: World, item: Item, node: Node, inventory: number)
	local side = Grid.sideBetween(node.key, inventory)
	local block, x, y, z = inventoryAt(world, inventory)
	untrack(world, item)
	local left: Stack? = item.stack
	if block and side and delivers(node, side, item.target) then
		local container = world.env.containers:peek(x, y, z)
		local slots = if container and container.block == block then container.slots else EMPTY
		local newSlots, leftover = Transmitters.insert(block, opposite(side), slots, item.stack)
		if leftover == nil or leftover.count < item.stack.count then
			store(world, x, y, z, block, newSlots)
		end
		left = leftover
	end
	if left == nil then
		-- (Untracked already: `remove` would look at the old route.)
		item.target = nil
		remove(world, item, REMOVE.Arrived)
		return
	end
	-- The rest turns round in the middle of the transporter.
	item.stack = left
	item.target = nil
	item.progress = HALF
	reroute(world, item, node)
end

-- One tick of `item`.
local function move(world: World, item: Item)
	local node = world.nodes[item.route[item.hop]]
	if node == nil then
		-- (Breaking a transporter drops its items, so this is only a safety net.)
		remove(world, item, REMOVE.Gone)
		return
	end
	if item.target == nil then
		item.wait -= 1
		-- (With the tick's searches used up it stays due and looks on a later tick.)
		if item.wait <= 0 and world.searchBudget > 0 then
			reroute(world, item, node, true)
		end
		return
	end
	local was = item.progress
	item.progress += Transmitters.speed(node.block)
	if was < HALF and item.progress >= HALF and not wayAhead(world, item, node) then
		reroute(world, item, node)
		return
	end
	if item.progress < BLOCK_PROGRESS then
		return
	end
	local nextKey = item.route[item.hop + 1]
	if nextKey == nil then
		item.progress = HALF
		reroute(world, item, node)
	elseif item.hop + 1 == #item.route then
		arrive(world, item, node, nextKey)
	else
		local side = Grid.sideBetween(node.key, nextKey)
		local nextNode = world.nodes[nextKey]
		if side and nextNode and canEnter(node, side, nextNode, item.colour) then
			item.hop += 1
			item.progress -= BLOCK_PROGRESS
			local speed = Transmitters.speed(nextNode.block)
			local truncated = #item.route - item.sentHop > Protocol.MAX_PATH
			if speed ~= item.sentSpeed or (truncated and item.hop - item.sentHop >= RESEND_HOPS) then
				sendAdd(world, item)
			end
		else
			item.progress = HALF
			reroute(world, item, node)
		end
	end
end

--[[ Pulling ]]

-- Is `item` among a furnace's or machine's `results` (Transmitters.results)?
local function isResult(results: { Stack }, item: number): boolean
	for _, result in results do
		if result.item == item then
			return true
		end
	end
	return false
end

--[[
	One pull of `node` through `side` (Mekanism's TransitRequest): "sent", "failed" (items there,
	nowhere to send them) or "none" (nothing to take). `routes` gives the route search, which is
	the same for every side of the transporter (it is only run when needed). `ejected`: a NORMAL
	side taking what a furnace or machine pushes out (its output slots only), else a PULL side.
]]
local function pullSide(
	world: World,
	node: Node,
	side: number,
	routes: () -> ({ Candidate }, { [number]: number }),
	ejected: boolean
): string
	local inventory = Grid.neighbour(node.key, side)
	if inventory == nil then
		return "none"
	end
	local block, x, y, z = inventoryAt(world, inventory)
	local container = world.env.containers:peek(x, y, z)
	if block == nil or container == nil or container.block ~= block then
		return "none"
	end
	local face = opposite(side)
	local types: { Stack } = if ejected
		then Transmitters.results(block, container.slots)
		else Transmitters.available(block, face, container.slots)
	if #types == 0 then
		return "none"
	end
	local candidates, back = routes()
	-- A furnace or machine pushes a stack out at once (the ejector); other inventories give the
	-- tier's pull amount.
	local ejects = Transmitters.ejects(block)
	-- (Its results' kinds: one of them taken out is smelted, for its last user.)
	local results = if ejected then types elseif ejects then Transmitters.results(block, container.slots) else nil
	local pull = Transmitters.pullAmount(node.block)
	for _, kind in types do
		local most = if ejects then math.min(Items.maxStack(kind.item), Items.MAX_STACK) else pull
		local want = Items.withCount(kind, math.min(kind.count, most)) :: Stack
		local candidate, room = choose(world, candidates, want, inventory, nil, nil)
		if candidate then
			local count = math.min(want.count, room)
			local newSlots: Slots, taken: Stack?
			if ejected then
				newSlots, taken = Transmitters.takeResults(block, container.slots, count, kind)
			else
				newSlots, taken = Transmitters.extract(block, face, container.slots, count, kind)
			end
			if taken then
				store(world, x, y, z, block, newSlots)
				-- (A furnace's or machine's results pulled out: smelted, for its last user.)
				local resultsTaken = world.env.resultsTaken
				if resultsTaken and results and isResult(results, taken.item) then
					resultsTaken(x, y, z, container, taken)
				end
				local id = world.nextItem
				world.nextItem += 1
				local item: Item = {
					id = id,
					stack = taken,
					colour = node.colour,
					route = routeTo(back, node.key, candidate),
					hop = 1,
					target = "dest",
					face = candidate.face,
					progress = 0,
					wait = 0,
					from = inventory,
					-- (A furnace's or machine's results never go back into it.)
					home = if ejects then nil else inventory,
					sentHop = 1,
					sentSpeed = 0,
				}
				world.items[id] = item
				world.itemCount += 1
				track(world, item)
				sendAdd(world, item)
				return "sent"
			end
		end
	end
	return "failed"
end

-- The PULL sides of transporter `node`, and its NORMAL sides on furnaces and machines that push
-- their results out, when its pull timer is up.
local function pull(world: World, node: Node)
	if node.pullDelay > 0 then
		node.pullDelay -= 1
		return
	elseif world.searchBudget <= 0 then
		-- (The tick's searches are used up: it stays due and pulls on a later tick.)
		return
	end
	local sent, failed = false, false
	local candidates: { Candidate }? = nil
	local back: { [number]: number }? = nil
	local function routes(): ({ Candidate }, { [number]: number })
		if candidates == nil or back == nil then
			candidates, back = search(world, node, node.colour)
		end
		return candidates :: { Candidate }, back :: { [number]: number }
	end
	for side = 0, 5 do
		local mode = modeOf(node.modes, side)
		if has(node.acceptors, side) and Transmitters.receives(mode) then
			-- (A NORMAL side only takes what a furnace or machine pushes out: from anything else
			-- there is nothing to take.)
			local result = pullSide(world, node, side, routes, mode ~= PULL)
			if result == "sent" then
				sent = true
			elseif result == "failed" then
				failed = true
			end
		end
	end
	if sent then
		node.pullFailures = 0
		node.pullDelay = PULL_DELAY - 1
	elseif failed then
		node.pullFailures += 1
		node.pullDelay = math.min(MAX_BACKOFF, math.floor(math.exp(node.pullFailures))) - 1
	else
		node.pullDelay = IDLE_DELAY - 1
	end
end

--[[ Entry points ]]

-- One tick: every item moves, then every transporter with PULL sides on inventories pulls.
function Transport.step(world: World)
	world.searchBudget = SEARCH_BUDGET
	for _, item in world.items do
		move(world, item)
	end
	for _, node in world.pullers do
		pull(world, node)
	end
end

-- The transporter `node` is going: its items drop there (Env.drop).
function Transport.dropFrom(world: World, node: Node)
	local drop = world.env.drop
	for _, item in world.items do
		if item.route[item.hop] == node.key then
			if drop then
				drop(node.x, node.y, node.z, item.stack)
			end
			remove(world, item, REMOVE.Dropped)
		end
	end
end

-- The Transport add that shows `item` as it is now (for a player who starts seeing it).
function Transport.op(world: World, item: Item): TransportOp
	return (addOp(world, item))
end

-- Block position of the transporter `item` is in.
function Transport.position(item: Item): (number, number, number)
	return Grid.decode(item.route[item.hop])
end

return Transport
