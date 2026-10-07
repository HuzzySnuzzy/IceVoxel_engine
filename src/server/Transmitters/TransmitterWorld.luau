--!strict
--[[
	The server's Mekanism pipes, pure (no Roblox APIs, so the tests run it): every transmitter's
	state, the pipes' networks and their fluids (Shared/Fluids: water, lava, oil, fuel), the Fluid
	Tanks, the items in transporters, and what has to be replicated. Transmitters/Transmitters runs it in the game. Universal Cables are
	nodes too (their side modes, links to cables and energy blocks); their energy networks are
	server/Machines/EnergyNet's, which reads the nodes and `energyDirty` (cables that came, went
	or changed links).

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
	            buffer of one fluid, up to the sum of their capacities. A pipe that changes links
	            queues itself and the pipes it joined or left; queued pipes are flood filled,
	            MAX_REBUILD pipes per tick at most and the rest carried over, while the old
	            networks keep working. A finished fill becomes one network and takes from each
	            old network the share of its buffer that its pipes held (by capacity): merging
	            adds buffers up, splitting shares one out. A broken pipe takes its share with it
	            (lost, counted in `lost`), as in Mekanism. A fill never crosses into pipes whose
	            network holds another fluid than the pipes it has taken in (Mekanism's
	            MechanicalPipe.isValidTransmitter: pipes holding different fluids don't join), so
	            fluids never mix; they stay separate networks until a later fill finds one empty.
	            (If a fill carried over between ticks meets that anyway, the fluid of the largest
	            share wins and the others' shares are lost.)
	  Tanks     a Fluid Tank's fluid and mB. Breaking one loses what it held, unless a survival
	            player broke it: then its item keeps it (Mekanism's sustained data, `tankData`,
	            through ServerNet's hooks, `blockDataHooks`) and placing that item puts it back
	            (`restoreTank`).
	  Items     stacks in Logistical Transporters (Transmitters/Transport).

	Each `step` (20 a second): queued network work, then Transport.step (items move, transporters
	pull, and take what furnaces and machines push out), then Fluids.step (pipes pull from and
	push into Fluid Tanks and machines' fluid tanks: Transmitters/Fluids), then pipe fills.
	Machines push their output tanks into the pipes and Fluid Tanks around them on their own
	(`ejectFluid`, run by server/Machines/MachineWorld after their tick).

	Replication. `takeRecords` gives the Transmitters records (modes, colour, a pipe's fill byte and
	the fluid id its network holds) and Tanks
	records that changed since the last call (compared with what was last sent, so nothing is sent
	twice); a network's fill and a tank's contents go at most every FILL_INTERVAL ticks (4 a
	second). `chunkRecords` gives a chunk's records that are not in the default state, to send
	with its edit list. `takeTransport` gives the Transport ops (Transmitters/Transport).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Coords = require(Shared.World.Coords)
local Fluids = require(Shared.Fluids)
local Items = require(Shared.Items)
local Transmitters = require(Shared.Transmitters)
local InventoryTypes = require(Shared.Inventory.Types)

local EditRules = require(script.Parent.Parent.Network.EditRules)

local PipeFluids = require(script.Parent.Fluids)
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
local NONE = Fluids.NONE
local NORMAL = Transmitters.MODES.NORMAL
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
		energyDirty = {},
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
		sentFluid = -1,
		checkedAt = world.tick,
		leads = {},
		leadsTick = -1,
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
	network.sentFluid = -1
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
	-- (Shares are worked out before anyone leaves: the capacity each old network gives up, in the
	-- order the fill met them, so a tie between fluids is decided the same way every time.)
	local moving: { [Network]: number } = {}
	local olds: { Network } = {}
	for _, node in alive do
		local old = node.network
		if old then
			if moving[old] == nil then
				table.insert(olds, old)
			end
			moving[old] = (moving[old] or 0) + Transmitters.pipeCapacity(node.block)
		end
	end
	local network = newNetwork(world)
	local portions: { { network: Network, amount: number } } = {}
	for _, old in olds do
		local capacity = moving[old]
		local portion = if capacity >= old.capacity then old.amount else (old.amount * capacity) // old.capacity
		if portion > 0 then
			table.insert(portions, { network = old, amount = portion })
		end
	end
	-- One fluid per buffer: the fill keeps pipes of other fluids out, so there is normally one;
	-- otherwise the largest share's fluid stays and the rest is lost.
	local totals: { [number]: number } = {}
	local kept, keptTotal = NONE, 0
	for _, portion in portions do
		local fluid = portion.network.fluid
		totals[fluid] = (totals[fluid] or 0) + portion.amount
		if totals[fluid] > keptTotal then
			kept, keptTotal = fluid, totals[fluid]
		end
	end
	for _, portion in portions do
		local old = portion.network
		if old.fluid == kept then
			network.fluid = kept
			network.amount += portion.amount
		else
			world.lost += portion.amount
		end
		old.amount -= portion.amount
	end
	for _, node in alive do
		leave(world, node, false)
		join(network, node)
	end
end

-- The fluid the network of pipe `node` holds (NONE while it is empty).
local function heldFluid(node: Node): number
	local network = node.network
	return if network and network.amount > 0 then network.fluid else NONE
end

--[[
	Flood fills queued pipes into networks, visiting at most `budget` pipes (a fill in progress
	carries over to the next call). A pipe visited by a fill needs no fill of its own, unless it
	changes again afterwards. A fill takes in no pipe whose network holds another fluid than the
	pipes it has taken in so far.
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
			job = { visited = { [key] = true }, frontier = { key }, members = {}, fluid = heldFluid(node) }
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
						local fluid = if other and other.kind == "fluid" then heldFluid(other) else NONE
						-- (A pipe holding another fluid stays out: fluids never mix.)
						if
							other
							and other.kind == "fluid"
							and (fluid == NONE or job.fluid == NONE or fluid == job.fluid)
						then
							if job.fluid == NONE then
								job.fluid = fluid
							end
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
	Does a NORMAL side of transporter `node` on an acceptor (`acceptors`) face a furnace or machine
	that pushes its results out on its own (Transmitters.ejects)? Such a side takes them
	(Transmitters/Transport), so the transporter pulls.
]]
local function receivesEjected(world: World, node: Node, acceptors: number): boolean
	for side = 0, 5 do
		if has(acceptors, side) and Transmitters.modeOf(node.modes, side) == NORMAL then
			local dx, dy, dz = Transmitters.offset(side)
			local block = blockAt(world, node.x + dx, node.y + dy, node.z + dz)
			if block ~= nil and Transmitters.ejects(block) then
				return true
			end
		end
	end
	return false
end

--[[
	Works out again which sides of `node` join transmitters and acceptors (Transmitters.connections)
	and what follows: a pipe whose links changed is queued for its network with the pipes it
	joined or left; a pipe's network knows its pipes on tanks; transporters with PULL sides on
	inventories, or NORMAL sides on furnaces and machines that push their results out, are the
	pullers.
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
	local oldLinks, oldAcceptors = node.links, node.acceptors
	node.links, node.acceptors = links, acceptors
	if node.kind == "energy" then
		-- (Energy networks are server/Machines/EnergyNet's.)
		if links ~= oldLinks or acceptors ~= oldAcceptors then
			world.energyDirty[node.key] = true
		end
	elseif node.kind == "fluid" then
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
	elseif bit32.band(acceptors, pullMask(node.modes)) ~= 0 or receivesEjected(world, node, acceptors) then
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
	local kind: Types.Kind = Transmitters.kindOf(block) or "fluid"
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
		sentFluidId = 0,
	}
	world.nodes[key] = node
	index(world, key, x, z)
	if kind == "fluid" then
		-- (A lone pipe is a network of its own until a flood fill joins it to its neighbours.)
		join(newNetwork(world), node)
	elseif kind == "energy" then
		world.energyDirty[key] = true
	end
	relink(world, node)
end

local function removeNode(world: World, node: Node)
	Transport.dropFrom(world, node)
	world.lost += leave(world, node, true)
	world.nodes[node.key] = nil
	world.pullers[node.key] = nil
	world.dirtyNodes[node.key] = nil
	if node.kind == "energy" then
		world.energyDirty[node.key] = true
	end
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

-- Does a change from or to `block` matter to transmitters (one, a tank, an inventory, an energy
-- block)?
local function matters(block: number): boolean
	return Transmitters.isTransmitter(block)
		or Transmitters.isTank(block)
		or Transmitters.isItemAcceptor(block)
		or Transmitters.isEnergyAcceptor(block)
end

--[[
	Block (x, y, z) changed from `old` to `new` (WorldServer.onChanged): a transmitter or tank that
	went is dropped (a transporter's items drop there, a pipe's share of its network's fluid and a
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
	Puts up to `amount` mB of `fluid` (a fluid pipes and tanks carry: Fluids.carriable) into the
	tank at (x, y, z); returns how much it took (0: no tank, no such fluid, another fluid, full).
	`simulate` changes nothing.
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
	if tank == nil or not Fluids.carriable(fluid) or not (amount > 0) or (tank.amount > 0 and tank.fluid ~= fluid) then
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

--[[ Sustained data (Mekanism keeps a Fluid Tank's contents in its item) ]]

--[[
	The item data the tank at (x, y, z) keeps when broken: `{ fluid = id, amount = mB }` while it
	holds anything, nil when it is empty (so an empty tank's item stacks with new ones) or there is
	no tank.
]]
function TransmitterWorld.tankData(world: World, x: number, y: number, z: number): Items.Data?
	local tank = TransmitterWorld.tank(world, x, y, z)
	if tank == nil or tank.amount <= 0 or tank.fluid == NONE then
		return nil
	end
	local data: Items.Data = { fluid = tank.fluid, amount = tank.amount }
	return table.freeze(data)
end

--[[
	Puts a tank item's data (`tankData`) into the tank at (x, y, z), which was just placed: what it
	held is replaced. `fluid` must be a fluid tanks carry (Fluids.carriable) and `amount` at
	least 1 mB (whole mB; more than the tank holds is cut to its capacity). Returns whether the
	tank took anything (false: no tank, no data or data of something else).
]]
function TransmitterWorld.restoreTank(world: World, x: number, y: number, z: number, data: Items.Data?): boolean
	local tank = TransmitterWorld.tank(world, x, y, z)
	if tank == nil or data == nil then
		return false
	end
	local fluid, amount = Items.dataNumber(data, "fluid"), Items.dataNumber(data, "amount")
	if fluid == nil or not Fluids.carriable(fluid) or amount == nil or not (amount >= 1) or amount == math.huge then
		return false
	end
	tank.fluid = fluid
	tank.amount = math.min(math.floor(amount), tank.capacity)
	world.dirtyTanks[tank.key] = true
	return true
end

--[[
	The tanks' sustained data hooks, for ServerNet.addBlockData: a broken tank's item keeps its
	fluid (`tankData`), and a tank placed from such an item gets it back (`restoreTank`), in
	creative too.
]]
function TransmitterWorld.blockDataHooks(world: World): EditRules.BlockDataHooks
	return {
		save = function(x: number, y: number, z: number, block: number): Items.Data?
			if not Transmitters.isTank(block) then
				return nil
			end
			return TransmitterWorld.tankData(world, x, y, z)
		end,
		placed = function(_player: any, x: number, y: number, z: number, block: number, stack: Items.Stack?)
			if stack and stack.data and Transmitters.isTank(block) then
				TransmitterWorld.restoreTank(world, x, y, z, stack.data)
			end
		end,
	}
end

--[[ Ticking ]]

-- Networks whose fill byte or fluid changed get their pipes' records re-sent (at most every
-- FILL_INTERVAL ticks).
local function checkFills(world: World)
	for network in world.networks do
		if network.sentFill < 0 or network.sentFluid < 0 or world.tick - network.checkedAt >= FILL_INTERVAL then
			network.checkedAt = world.tick
			local fill = Transmitters.fillLevel(network.amount, network.capacity)
			local fluid = if fill > 0 then network.fluid else NONE
			if fill ~= network.sentFill or fluid ~= network.sentFluid then
				network.sentFill, network.sentFluid = fill, fluid
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
	PipeFluids.step(world)
	checkFills(world)
end

--[[
	The machine with fluid tanks at (x, y, z) (its `container`, Players/Containers') pushes its
	output tanks into the pipes and Fluid Tanks next to it (Transmitters/Fluids.eject: Mekanism's
	ejector, Machines.FLUID_EJECT_RATE mB a tick). server/Machines/MachineWorld runs it after the
	machine's tick. Returns the mB that went out.
]]
function TransmitterWorld.ejectFluid(
	world: World,
	x: number,
	y: number,
	z: number,
	container: InventoryTypes.Container
): number
	return PipeFluids.eject(world, x, y, z, container)
end

--[[ Replication ]]

-- The fill byte and fluid id a pipe's record shows (its network's, as last checked); 0, 0 for
-- transporters and cables.
local function fillOf(node: Node): (number, number)
	local network = node.network
	if network == nil then
		return 0, NONE
	end
	return math.max(network.sentFill, 0), math.max(network.sentFluid, NONE)
end

local function nodeRecord(node: Node, fill: number, fluidId: number): TransmitterRecord
	return {
		x = node.x,
		y = node.y,
		z = node.z,
		modes = node.modes,
		colour = node.colour,
		fluid = fill,
		fluidId = fluidId,
	}
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
			local fill, fluidId = fillOf(node)
			if
				node.modes ~= node.sentModes
				or node.colour ~= node.sentColour
				or fill ~= node.sentFluid
				or fluidId ~= node.sentFluidId
			then
				node.sentModes, node.sentColour, node.sentFluid, node.sentFluidId =
					node.modes, node.colour, fill, fluidId
				table.insert(records, nodeRecord(node, fill, fluidId))
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
				local fill, fluidId = fillOf(node)
				if node.modes ~= 0 or node.colour ~= 0 or fill ~= 0 or fluidId ~= 0 then
					table.insert(records, nodeRecord(node, fill, fluidId))
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

--[[ Saving (World/WorldSave, Save/WorldSnapshot) ]]

export type SavedNode = {
	x: number,
	y: number,
	z: number,
	modes: number,
	colour: number,
	fluid: number,
	amount: number,
}
export type SavedTank = { x: number, y: number, z: number, fluid: number, amount: number }
export type SavedItem = { x: number, y: number, z: number, colour: number, stack: Types.Stack }

--[[
	What a saved world keeps of the pipes: every transmitter's side modes and colour, each pipe's
	share of its network's fluid (Mekanism splits a network's buffer by the pipes' capacities; the
	rest of the division goes to the first pipes by position, so nothing is lost), every tank's
	contents and the stacks in transporters (where they are).
]]
function TransmitterWorld.saveState(world: World): ({ SavedNode }, { SavedTank }, { SavedItem })
	local shares: { [number]: number } = {}
	for network in world.networks do
		local amount = network.amount
		if amount > 0 and network.capacity > 0 then
			local keys: { number } = {}
			for key in network.nodes do
				table.insert(keys, key)
			end
			table.sort(keys)
			local given = 0
			for _, key in keys do
				local share = (amount * Transmitters.pipeCapacity(network.nodes[key].block)) // network.capacity
				shares[key] = share
				given += share
			end
			-- (The division's rest, into the pipes with room, first by position.)
			local rest = amount - given
			for _, key in keys do
				if rest <= 0 then
					break
				end
				local room = Transmitters.pipeCapacity(network.nodes[key].block) - shares[key]
				local add = math.min(room, rest)
				if add > 0 then
					shares[key] += add
					rest -= add
				end
			end
		end
	end
	local nodes: { SavedNode } = {}
	for key, node in world.nodes do
		local network = node.network
		local share = shares[key] or 0
		table.insert(nodes, {
			x = node.x,
			y = node.y,
			z = node.z,
			modes = node.modes,
			colour = node.colour,
			fluid = if share > 0 and network then network.fluid else NONE,
			amount = share,
		})
	end
	local tanks: { SavedTank } = {}
	for _, tank in world.tanks do
		if tank.amount > 0 then
			table.insert(tanks, { x = tank.x, y = tank.y, z = tank.z, fluid = tank.fluid, amount = tank.amount })
		end
	end
	local items: { SavedItem } = {}
	for _, item in world.items do
		local x, y, z = Grid.decode(item.route[item.hop])
		table.insert(items, { x = x, y = y, z = z, colour = item.colour, stack = item.stack })
	end
	return nodes, tanks, items
end

--[[
	Puts a saved world's pipes back, after `blockChanged` made the nodes and tanks of its blocks
	(fresh, default): each node's modes and colour, a pipe's share into its own network (the
	flood fills join the pipes' networks again over the next ticks, adding the shares up), the
	tanks' contents (at most their capacity) and the stacks in transporters (waiting there:
	Transport.restore). Saved state of a position with no node or tank of its kind any more is
	skipped. Returns how many records were taken.
]]
function TransmitterWorld.restoreState(
	world: World,
	nodes: { SavedNode },
	tanks: { SavedTank },
	items: { SavedItem }
): number
	local taken = 0
	local touched: { Node } = {}
	for _, saved in nodes do
		local key = Grid.key(saved.x, saved.y, saved.z)
		local node = if key then world.nodes[key] else nil
		if node then
			taken += 1
			if saved.modes >= 0 and saved.modes < 4096 and saved.modes == math.floor(saved.modes) then
				node.modes = saved.modes
			end
			if node.kind == "item" and Transmitters.isColour(saved.colour) then
				node.colour = saved.colour
			end
			local network = node.network
			if node.kind == "fluid" and network and saved.amount > 0 and Fluids.carriable(saved.fluid) then
				if network.amount <= 0 or network.fluid == saved.fluid then
					network.fluid = saved.fluid
					network.amount = math.min(network.amount + math.floor(saved.amount), network.capacity)
					network.sentFill = -1
				end
			end
			world.dirtyNodes[node.key] = true
			table.insert(touched, node)
		end
	end
	-- (Every mode is in place before any side is worked out again.)
	for _, node in touched do
		relink(world, node)
	end
	for _, saved in tanks do
		local tank = TransmitterWorld.tank(world, saved.x, saved.y, saved.z)
		if tank and saved.amount > 0 and Fluids.carriable(saved.fluid) then
			taken += 1
			tank.fluid = saved.fluid
			tank.amount = math.min(math.floor(saved.amount), tank.capacity)
			world.dirtyTanks[tank.key] = true
		end
	end
	for _, saved in items do
		local node = TransmitterWorld.node(world, saved.x, saved.y, saved.z)
		if node and Transport.restore(world, node, saved.stack, saved.colour) then
			taken += 1
		end
	end
	return taken
end

return TransmitterWorld
