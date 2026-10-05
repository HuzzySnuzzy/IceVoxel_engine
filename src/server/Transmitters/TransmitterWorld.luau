--!strict
--[[
	The server's Mekanism pipes, pure (no Roblox APIs, so the tests run it): every transmitter's
	state, the pipes' networks and their water, the fluid tanks, the items in transporters, and
	what has to be replicated. Transmitters/Transmitters runs it in the game.

	State (Transmitters/Types), all in memory like chests: nothing is saved.
	  Nodes     one per transmitter block, made and dropped by `blockChanged` (the server chains
	            it onto WorldServer.onChanged, so every placement, break and Api change comes
	            through): its six side modes and colour (the Configurator's `cycleMode`,
	            `cycleColour`), and which sides join transmitters and acceptors. Those `links`
	            and `acceptors` masks are Shared/Transmitters.connections, the rule the client
	            draws arms with, worked out again whenever the transmitter, its modes or colour,
	            or a neighbouring block changes. Neighbours come from the nodes and tanks
	            themselves and otherwise from Env.getBlock, which never generates terrain.
	  Networks  Mechanical Pipes joined into one (connected components over `links`) share a
	            water buffer of up to the sum of their capacities. A pipe that changes links
	            queues itself and the pipes it joined or left; queued pipes are flood filled,
	            MAX_REBUILD pipes per tick at most and the rest carried over, while the old
	            networks keep working. A finished fill becomes one network and takes from each
	            old network the share of its buffer that its pipes held (by capacity): merging
	            adds buffers up, splitting shares one out. A broken pipe takes its share with it
	            (lost, counted in `lost`), as in Mekanism.
	  Tanks     a fluid tank's fluid and mB. Breaking one loses what it held.
	  Items     stacks in Logistical Transporters (Transmitters/Transport).

	Each `step` (20 a second): queued network work, then Transport.step (items move, transporters
	pull), then Fluids.step (pipes pull from and push into tanks), then pipe fills.

	Replication. `takeRecords` gives the Transmitters records (modes, colour, pipe fill) and Tanks
	records that changed since the last call (compared with what was last sent, so nothing is sent
	twice); a network's fill and a tank's contents go at most every FILL_INTERVAL ticks (4 a
	second). `chunkRecords` gives a chunk's records that are not in the default state, to send
	with its edit list. `takeTransport` gives the Transport ops (Transmitters/Transport).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Coords = require(Shared.World.Coords)
local Transmitters = require(Shared.Transmitters)

local Fluids = require(script.Parent.Fluids)
local Grid = require(script.Parent.Grid)
local Transport = require(script.Parent.Transport)
local Types = require(script.Parent.Types)

export type World = Types.World
export type Node = Types.Node
export type Network = Types.Network
export type Tank = Types.Tank
export type Item = Types.Item
export type Env = Types.Env
type TransmitterRecord = Types.TransmitterRecord
type TankRecord = Types.TankRecord
type TransportOp = Types.TransportOp

-- Pipes a network rebuild visits per tick at most (the rest waits for the next tick).
local MAX_REBUILD = 4096
-- Ticks between two records of a network's fill or a tank's contents (4 a second).
local FILL_INTERVAL = 5
local NONE = Transmitters.FLUIDS.NONE
local PULL = Transmitters.MODES.PULL

local TransmitterWorld = {}

TransmitterWorld.MAX_REBUILD = MAX_REBUILD
TransmitterWorld.FILL_INTERVAL = FILL_INTERVAL

local function has(mask: number, side: number): boolean
	return bit32.btest(mask, bit32.lshift(1, side))
end

-- The sides of packed `modes` set to PULL, as a mask.
local function pullMask(modes: number): number
	local mask = 0
	for side = 0, 5 do
		if Transmitters.modeOf(modes, side) == PULL then
			mask = bit32.bor(mask, bit32.lshift(1, side))
		end
	end
	return mask
end

function TransmitterWorld.new(env: Env): World
	return {
		env = env,
		tick = 0,
		nodes = {},
		tanks = {},
		networks = {},
		nextNetwork = 0,
		byChunk = {},
		seeds = {},
		seedSet = {},
		job = nil,
		pullers = {},
		items = {},
		itemCount = 0,
		nextItem = 1,
		incoming = {},
		searchBudget = 0,
		ops = {},
		dirtyNodes = {},
		dirtyTanks = {},
		lost = 0,
	}
end

--[[ Lookups ]]

function TransmitterWorld.node(world: World, x: number, y: number, z: number): Node?
	local key = Grid.key(x, y, z)
	return if key then world.nodes[key] else nil
end

function TransmitterWorld.tank(world: World, x: number, y: number, z: number): Tank?
	local key = Grid.key(x, y, z)
	return if key then world.tanks[key] else nil
end

-- The network of the pipe at (x, y, z), if there is one.
function TransmitterWorld.network(world: World, x: number, y: number, z: number): Network?
	local node = TransmitterWorld.node(world, x, y, z)
	return if node then node.network else nil
end

--[[
	The block at (x, y, z) as the connection rule should see it: transmitters and tanks are only
	what this world knows of (a transmitter the world holds but no node stands for is nothing),
	anything else comes from Env.getBlock (nil: unknown, joins nothing).
]]
local function blockAt(world: World, x: number, y: number, z: number): number?
	local key = Grid.key(x, y, z)
	if key == nil then
		return nil
	end
	local node = world.nodes[key]
	if node then
		return node.block
	end
	local tank = world.tanks[key]
	if tank then
		return tank.block
	end
	local block = world.env.getBlock(x, y, z)
	if block ~= nil and (Transmitters.isTransmitter(block) or Transmitters.isTank(block)) then
		return nil
	end
	return block
end

local function index(world: World, key: number, x: number, z: number)
	local chunk = Grid.chunkKey(x, z)
	local set = world.byChunk[chunk]
	if set == nil then
		set = {}
		world.byChunk[chunk] = set
	end
	set[key] = true
end

local function unindex(world: World, key: number, x: number, z: number)
	local chunk = Grid.chunkKey(x, z)
	local set = world.byChunk[chunk]
	if set then
		set[key] = nil
		if next(set) == nil then
			world.byChunk[chunk] = nil
		end
	end
end

--[[ Networks ]]

local function seed(world: World, key: number)
	if not world.seedSet[key] then
		world.seedSet[key] = true
		table.insert(world.seeds, key)
	end
end

local function newNetwork(world: World): Network
	world.nextNetwork += 1
	local network: Network = {
		id = world.nextNetwork,
		nodes = {},
		size = 0,
		capacity = 0,
		fluid = NONE,
		amount = 0,
		ports = {},
		sentFill = -1,
		checkedAt = world.tick,
	}
	world.networks[network] = true
	return network
end

local function join(network: Network, node: Node)
	network.nodes[node.key] = node
	network.size += 1
	network.capacity += Transmitters.pipeCapacity(node.block)
	if node.acceptors ~= 0 then
		network.ports[node.key] = node
	end
	node.network = network
end

-- Takes `node` out of its network. Returns the share of the buffer it takes along (by capacity:
-- all of it for the last pipe).
local function leave(world: World, node: Node, share: boolean): number
	local network = node.network
	if network == nil then
		return 0
	end
	local capacity = Transmitters.pipeCapacity(node.block)
	local taken = 0
	if share then
		taken = if capacity >= network.capacity then network.amount else (network.amount * capacity) // network.capacity
		network.amount -= taken
	end
	network.nodes[node.key] = nil
	network.ports[node.key] = nil
	network.size -= 1
	network.capacity -= capacity
	network.sentFill = -1
	if network.amount <= 0 then
		network.amount = 0
		network.fluid = NONE
	end
	if network.size <= 0 then
		world.networks[network] = nil
	end
	node.network = nil
	return taken
end

-- A finished flood fill: `members` (those still there) become one network, with the share of
-- every old network's buffer their capacity stood for.
local function finish(world: World, members: { Node })
	local alive: { Node } = {}
	for _, node in members do
		if world.nodes[node.key] == node then
			table.insert(alive, node)
		end
	end
	if #alive == 0 then
		return
	end
	local first = alive[1].network
	local same = first ~= nil and first.size == #alive
	for _, node in alive do
		if node.network ~= first then
			same = false
			break
		end
	end
	if same then
		return
	end
	-- (Shares are worked out before anyone leaves: the capacity each old network gives up.)
	local moving: { [Network]: number } = {}
	for _, node in alive do
		local old = node.network
		if old then
			moving[old] = (moving[old] or 0) + Transmitters.pipeCapacity(node.block)
		end
	end
	local network = newNetwork(world)
	for old, capacity in moving do
		local portion = if capacity >= old.capacity then old.amount else (old.amount * capacity) // old.capacity
		if portion > 0 then
			network.fluid = old.fluid
			network.amount += portion
			old.amount -= portion
		end
	end
	for _, node in alive do
		leave(world, node, false)
		join(network, node)
	end
end

--[[
	Flood fills queued pipes into networks, visiting at most `budget` pipes (a fill in progress
	carries over to the next call). A pipe visited by a fill needs no fill of its own, unless it
	changes again afterwards.
]]
function TransmitterWorld.rebuild(world: World, budget: number)
	while budget > 0 do
		local job = world.job
		if job == nil then
			local key = table.remove(world.seeds)
			if key == nil then
				return
			end
			local node = world.nodes[key]
			if not world.seedSet[key] or node == nil or node.kind ~= "fluid" then
				world.seedSet[key] = nil
				continue
			end
			job = { visited = { [key] = true }, frontier = { key }, members = {} }
			world.job = job
		end
		assert(job, "rebuild job")
		local key = table.remove(job.frontier)
		if key == nil then
			world.job = nil
			finish(world, job.members)
			continue
		end
		budget -= 1
		local node = world.nodes[key]
		if node and node.kind == "fluid" then
			world.seedSet[key] = nil
			table.insert(job.members, node)
			for side = 0, 5 do
				if has(node.links, side) then
					local neighbour = Grid.neighbour(key, side)
					if neighbour and not job.visited[neighbour] then
						local other = world.nodes[neighbour]
						if other and other.kind == "fluid" then
							job.visited[neighbour] = true
							table.insert(job.frontier, neighbour)
						end
					end
				end
			end
		end
	end
end

-- Is network work still queued (or a flood fill in progress)?
function TransmitterWorld.rebuilding(world: World): boolean
	if world.job then
		return true
	end
	for _, key in world.seeds do
		if world.seedSet[key] then
			return true
		end
	end
	return false
end

--[[ Links ]]

--[[
	Works out again which sides of `node` join transmitters and acceptors (Transmitters.connections)
	and what follows: a pipe whose links changed is queued for its network with the pipes it
	joined or left; a pipe's network knows its pipes on tanks; transporters with PULL sides on
	inventories are the pullers.
]]
local function relink(world: World, node: Node)
	local function getBlock(x: number, y: number, z: number): number?
		return blockAt(world, x, y, z)
	end
	local function getState(x: number, y: number, z: number): (number, number)
		local key = Grid.key(x, y, z)
		local other = if key then world.nodes[key] else nil
		if other then
			return other.modes, other.colour
		end
		return 0, 0
	end
	local links, acceptors =
		Transmitters.connections(node.block, node.modes, node.colour, node.x, node.y, node.z, getBlock, getState)
	local oldLinks = node.links
	node.links, node.acceptors = links, acceptors
	if node.kind == "fluid" then
		if links ~= oldLinks then
			seed(world, node.key)
			local changed = bit32.bxor(links, oldLinks)
			for side = 0, 5 do
				local neighbour = if has(changed, side) then Grid.neighbour(node.key, side) else nil
				if neighbour then
					seed(world, neighbour)
				end
			end
		end
		local network = node.network
		if network and acceptors ~= 0 then
			network.ports[node.key] = node
		elseif network then
			network.ports[node.key] = nil
		end
	elseif bit32.band(acceptors, pullMask(node.modes)) ~= 0 then
		world.pullers[node.key] = node
	else
		world.pullers[node.key] = nil
	end
end

-- Relinks the transmitters around `key`.
local function relinkAround(world: World, key: number)
	for side = 0, 5 do
		local neighbour = Grid.neighbour(key, side)
		local node = if neighbour then world.nodes[neighbour] else nil
		if node then
			relink(world, node)
		end
	end
end

--[[ Block changes ]]

local function addNode(world: World, key: number, x: number, y: number, z: number, block: number)
	local kind: Types.Kind = if Transmitters.kindOf(block) == "item" then "item" else "fluid"
	local node: Node = {
		key = key,
		x = x,
		y = y,
		z = z,
		block = block,
		kind = kind,
		modes = Transmitters.DEFAULT_MODES,
		colour = Transmitters.NO_COLOUR,
		links = 0,
		acceptors = 0,
		network = nil,
		pullDelay = 0,
		pullFailures = 0,
		sentModes = 0,
		sentColour = 0,
		sentFluid = 0,
	}
	world.nodes[key] = node
	index(world, key, x, z)
	if kind == "fluid" then
		-- (A lone pipe is a network of its own until a flood fill joins it to its neighbours.)
		join(newNetwork(world), node)
	end
	relink(world, node)
end

local function removeNode(world: World, node: Node)
	Transport.dropFrom(world, node)
	world.lost += leave(world, node, true)
	world.nodes[node.key] = nil
	world.pullers[node.key] = nil
	world.dirtyNodes[node.key] = nil
	unindex(world, node.key, node.x, node.z)
end

local function addTank(world: World, key: number, x: number, y: number, z: number, block: number)
	world.tanks[key] = {
		key = key,
		x = x,
		y = y,
		z = z,
		block = block,
		capacity = Transmitters.tankCapacity(block),
		fluid = NONE,
		amount = 0,
		sentFluid = NONE,
		sentAmount = 0,
		sentAt = -FILL_INTERVAL,
	}
	index(world, key, x, z)
end

local function removeTank(world: World, tank: Tank)
	world.lost += tank.amount
	world.tanks[tank.key] = nil
	world.dirtyTanks[tank.key] = nil
	unindex(world, tank.key, tank.x, tank.z)
end

-- Does a change from or to `block` matter to transmitters (one, a tank, an inventory)?
local function matters(block: number): boolean
	return Transmitters.isTransmitter(block) or Transmitters.isTank(block) or Transmitters.isItemAcceptor(block)
end

--[[
	Block (x, y, z) changed from `old` to `new` (WorldServer.onChanged): a transmitter or tank that
	went is dropped (a transporter's items drop there, a pipe's share of its network's water and a
	tank's contents are lost), a new one starts in the default state, and the transmitters around
	work out their sides again (an inventory or tank appearing or going there too).
]]
function TransmitterWorld.blockChanged(world: World, x: number, y: number, z: number, old: number, new: number)
	if old == new or not (matters(old) or matters(new)) then
		return
	end
	local key = Grid.key(x, y, z)
	if key == nil then
		return
	end
	local node = world.nodes[key]
	if node then
		removeNode(world, node)
	end
	local tank = world.tanks[key]
	if tank then
		removeTank(world, tank)
	end
	if Transmitters.isTransmitter(new) then
		addNode(world, key, x, y, z, new)
	elseif Transmitters.isTank(new) then
		addTank(world, key, x, y, z, new)
	end
	relinkAround(world, key)
end

--[[ Configuration (the Configurator) ]]

local function setModes(world: World, node: Node, modes: number)
	if modes == node.modes then
		return
	end
	node.modes = modes
	world.dirtyNodes[node.key] = true
	relink(world, node)
	relinkAround(world, node.key)
end

-- The packed side modes and colour of the transmitter at (x, y, z), nil when there is none.
function TransmitterWorld.state(world: World, x: number, y: number, z: number): (number?, number)
	local node = TransmitterWorld.node(world, x, y, z)
	if node == nil then
		return nil, 0
	end
	return node.modes, node.colour
end

--[[
	Sets side `side` of the transmitter at (x, y, z) to `mode` (Transmitters.MODES). False when
	there is no transmitter or the side or mode is bad.
]]
function TransmitterWorld.setMode(world: World, x: number, y: number, z: number, side: number, mode: number): boolean
	local node = TransmitterWorld.node(world, x, y, z)
	if node == nil or not Transmitters.isSide(side) or not Transmitters.isMode(mode) then
		return false
	end
	setModes(world, node, Transmitters.withMode(node.modes, side, mode))
	return true
end

--[[
	The Configurator's right click on side `side` of the transmitter at (x, y, z): the side's mode
	goes NORMAL -> PUSH -> PULL -> NONE -> NORMAL, and a transmitter of the same kind on that side
	gets the same mode on its side facing back, so both ends of a joint read alike and a joint cut
	from one end is joined again from either. (Mekanism's TileEntityTransmitter.onSneakRightClick
	only changes the clicked side, so a cut joint is joined again only from the end that cut it.
	Between transmitters PUSH and PULL act as NORMAL anyway: only NONE matters there.) Returns the
	new mode, nil when there is no transmitter (or a bad side).
]]
function TransmitterWorld.cycleMode(world: World, x: number, y: number, z: number, side: number): number?
	local node = TransmitterWorld.node(world, x, y, z)
	if node == nil or not Transmitters.isSide(side) then
		return nil
	end
	local mode = Transmitters.nextMode(Transmitters.modeOf(node.modes, side))
	setModes(world, node, Transmitters.withMode(node.modes, side, mode))
	local neighbour = Grid.neighbour(node.key, side)
	local other = if neighbour then world.nodes[neighbour] else nil
	if other and other.kind == node.kind then
		setModes(world, other, Transmitters.withMode(other.modes, Transmitters.opposite(side), mode))
	end
	return mode
end

-- Colours the transporter at (x, y, z) (0 none, 1..16). False for anything else.
function TransmitterWorld.setColour(world: World, x: number, y: number, z: number, colour: number): boolean
	local node = TransmitterWorld.node(world, x, y, z)
	if node == nil or node.kind ~= "item" or not Transmitters.isColour(colour) then
		return false
	end
	if colour ~= node.colour then
		node.colour = colour
		world.dirtyNodes[node.key] = true
		relink(world, node)
		relinkAround(world, node.key)
	end
	return true
end

--[[
	The Configurator's sneak + right click on a transporter at (x, y, z): its next colour (none ->
	white -> ... -> black -> none, Transmitters.nextColour). Returns it; nil for anything that is
	no transporter (Mechanical Pipes have no colour).
]]
function TransmitterWorld.cycleColour(world: World, x: number, y: number, z: number): number?
	local node = TransmitterWorld.node(world, x, y, z)
	if node == nil or node.kind ~= "item" then
		return nil
	end
	local colour = Transmitters.nextColour(node.colour)
	TransmitterWorld.setColour(world, x, y, z, colour)
	return colour
end

--[[ Tanks (buckets) ]]

--[[
	Puts up to `amount` mB of `fluid` into the tank at (x, y, z); returns how much it took (0: no
	tank, another fluid, full). `simulate` changes nothing.
]]
function TransmitterWorld.fillTank(
	world: World,
	x: number,
	y: number,
	z: number,
	fluid: number,
	amount: number,
	simulate: boolean?
): number
	local tank = TransmitterWorld.tank(world, x, y, z)
	if tank == nil or fluid == NONE or not (amount > 0) or (tank.amount > 0 and tank.fluid ~= fluid) then
		return 0
	end
	local taken = math.min(math.floor(amount), tank.capacity - tank.amount)
	if taken > 0 and not simulate then
		tank.fluid = fluid
		tank.amount += taken
		world.dirtyTanks[tank.key] = true
	end
	return math.max(taken, 0)
end

--[[
	Takes up to `amount` mB out of the tank at (x, y, z): how much and of which fluid (0, NONE: no
	tank or empty). `simulate` changes nothing.
]]
function TransmitterWorld.drainTank(
	world: World,
	x: number,
	y: number,
	z: number,
	amount: number,
	simulate: boolean?
): (number, number)
	local tank = TransmitterWorld.tank(world, x, y, z)
	if tank == nil or tank.amount <= 0 or not (amount > 0) then
		return 0, NONE
	end
	local fluid = tank.fluid
	local taken = math.min(math.floor(amount), tank.amount)
	if not simulate then
		tank.amount -= taken
		if tank.amount <= 0 then
			tank.amount = 0
			tank.fluid = NONE
		end
		world.dirtyTanks[tank.key] = true
	end
	return taken, fluid
end

--[[ Ticking ]]

-- Networks whose fill byte changed get their pipes' records re-sent (at most every
-- FILL_INTERVAL ticks).
local function checkFills(world: World)
	for network in world.networks do
		if network.sentFill < 0 or world.tick - network.checkedAt >= FILL_INTERVAL then
			network.checkedAt = world.tick
			local fill = Transmitters.fillLevel(network.amount, network.capacity)
			if fill ~= network.sentFill then
				network.sentFill = fill
				for key in network.nodes do
					world.dirtyNodes[key] = true
				end
			end
		end
	end
end

-- One simulation tick (Transmitters.TICK_RATE a second).
function TransmitterWorld.step(world: World)
	world.tick += 1
	TransmitterWorld.rebuild(world, MAX_REBUILD)
	Transport.step(world)
	Fluids.step(world)
	checkFills(world)
end

--[[ Replication ]]

-- The fill byte a pipe's record shows (its network's, as last checked); 0 for transporters.
local function fillOf(node: Node): number
	local network = node.network
	return if network then math.max(network.sentFill, 0) else 0
end

local function nodeRecord(node: Node, fluid: number): TransmitterRecord
	return { x = node.x, y = node.y, z = node.z, modes = node.modes, colour = node.colour, fluid = fluid }
end

local function tankRecord(tank: Tank): TankRecord
	return { x = tank.x, y = tank.y, z = tank.z, fluid = tank.fluid, amount = tank.amount }
end

--[[
	The Transmitters and Tanks records that changed since the last call (each one replaces what
	clients know of its position). A tank changed within FILL_INTERVAL ticks of its last record
	waits.
]]
function TransmitterWorld.takeRecords(world: World): ({ TransmitterRecord }, { TankRecord })
	local records: { TransmitterRecord } = {}
	for key in world.dirtyNodes do
		local node = world.nodes[key]
		if node then
			local fluid = fillOf(node)
			if node.modes ~= node.sentModes or node.colour ~= node.sentColour or fluid ~= node.sentFluid then
				node.sentModes, node.sentColour, node.sentFluid = node.modes, node.colour, fluid
				table.insert(records, nodeRecord(node, fluid))
			end
		end
	end
	table.clear(world.dirtyNodes)
	local tanks: { TankRecord } = {}
	for key in world.dirtyTanks do
		local tank = world.tanks[key]
		if tank == nil then
			world.dirtyTanks[key] = nil
		elseif world.tick - tank.sentAt >= FILL_INTERVAL then
			world.dirtyTanks[key] = nil
			if tank.fluid ~= tank.sentFluid or tank.amount ~= tank.sentAmount then
				tank.sentFluid, tank.sentAmount, tank.sentAt = tank.fluid, tank.amount, world.tick
				table.insert(tanks, tankRecord(tank))
			end
		end
	end
	return records, tanks
end

-- The records of chunk (cx, cz) that are not in the default state (sent with its edit list).
function TransmitterWorld.chunkRecords(world: World, cx: number, cz: number): ({ TransmitterRecord }, { TankRecord })
	local records: { TransmitterRecord } = {}
	local tanks: { TankRecord } = {}
	local keys = world.byChunk[Coords.chunkKey(cx, cz)]
	if keys then
		for key in keys do
			local node = world.nodes[key]
			local tank = world.tanks[key]
			if node then
				local fluid = fillOf(node)
				if node.modes ~= 0 or node.colour ~= 0 or fluid ~= 0 then
					table.insert(records, nodeRecord(node, fluid))
				end
			elseif tank and tank.amount > 0 then
				table.insert(tanks, tankRecord(tank))
			end
		end
	end
	return records, tanks
end

-- The Transport ops since the last call (adds with startTime 0: the caller sets the clock).
function TransmitterWorld.takeTransport(world: World): { TransportOp }
	local ops = world.ops
	world.ops = {}
	return ops
end

TransmitterWorld.itemOp = Transport.op
TransmitterWorld.itemPosition = Transport.position

return TransmitterWorld
