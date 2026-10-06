--!strict
--[[
	Fluids in Mechanical Pipes: Mekanism's MechanicalPipe and FluidNetwork, simplified, for every
	fluid pipes carry (Shared/Fluids: water, lava, oil and fuel). Transmitters/TransmitterWorld runs
	`step` 20 times a second over its networks (the pipes joined into one: a connected component)
	and the acceptors around them: Fluid Tanks, and machines with fluid tanks (Shared/Machines,
	their container in Players/Containers). Pure.

	A network has one buffer: one fluid at a time and up to the sum of its pipes' capacities
	(2 000 / 8 000 / 32 000 / 128 000 mB a pipe, Basic to Ultimate). Each tick:

	  1. Pull (MechanicalPipe.pullFromAcceptors): every pipe side set to PULL takes up to the pipe's
	     pull amount (250 / 1 000 / 8 000 / 32 000 mB) from the acceptor there, as far as the
	     buffer has room, and only the buffer's fluid when it holds any: out of a Fluid Tank, or
	     out of a machine's output tanks (Machines.extractFluid: a machine gives pipes its outputs
	     only, never what its input tanks hold).
	  2. Push (FluidNetwork.tickEmit, EmitUtils.sendToAcceptors): the buffer is split evenly over
	     the acceptors on NORMAL or PUSH sides of its pipes that have room for its fluid (each
	     once, however many pipes touch it): Fluid Tanks that are empty or hold that fluid, and
	     machines whose input tanks take it (Machines.fluidRoom / insertFluid: the first input
	     tank taking it fills first). One that takes less than its share leaves the rest to the
	     others, and the whole mB left over by rounding goes to the last ones. What nobody takes
	     stays in the buffer.

	Machines push their output tanks out on their own (`eject`, which Machines/MachineWorld runs
	after a machine's tick: Mekanism's ejector at fluidAutoEjectRate, Machines.FLUID_EJECT_RATE mB a
	tick): split evenly the same way over the Fluid Tanks next to them that take it, and the pipes
	next to them whose side takes it (Transmitters.receives: NORMAL and PULL, Mekanism's
	canReceiveFrom), whose buffer is empty or holds that fluid (up to its room) and whose network
	leads it somewhere: an acceptor on a NORMAL or PUSH side that takes that fluid (a Fluid Tank
	empty or holding it, another machine whose input tanks take it). Without that last rule the
	pipe feeding a machine would fill up with what the machine makes and stop feeding it (the
	refinery's fuel in its oil line): Mekanism avoids it with per-side configuration, which blocks
	here don't have (they have no facing), so the ejector only pushes into pipes that go somewhere
	for it, as transporters only take items that have a destination. For the same reason it skips
	a Fluid Tank next to it that a pipe PULLs from into a network leading that fluid nowhere: the
	supply tank of another line (the refinery's oil tank right next to it), which, once empty,
	would take the fuel, and its oil line would then pull that fuel into its buffer, never deliver
	it and never pull oil again. Never straight into another machine.

	Merging and splitting buffers when pipes join or part is TransmitterWorld's (by capacity; pipes
	holding different fluids stay apart).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Coords = require(Shared.World.Coords)
local Fluids = require(Shared.Fluids)
local Machines = require(Shared.Machines)
local Transmitters = require(Shared.Transmitters)
local InventoryTypes = require(Shared.Inventory.Types)

local Grid = require(script.Parent.Grid)
local Types = require(script.Parent.Types)

type World = Types.World
type Network = Types.Network
type Node = Types.Node
type Tank = Types.Tank
type Container = InventoryTypes.Container

-- Somewhere a share of fluid goes: a Fluid Tank, a machine's input tanks or a pipe network's
-- buffer, with its room for the fluid.
type Target = { key: number, room: number, tank: Tank?, container: Container?, network: Network? }

local NONE = Fluids.NONE
local PULL = Transmitters.MODES.PULL

local modeOf = Transmitters.modeOf

local PipeFluids = {}

local function has(mask: number, side: number): boolean
	return bit32.btest(mask, bit32.lshift(1, side))
end

-- mB of `fluid` a Fluid Tank has room for: empty, or holding the same.
local function tankRoom(tank: Tank, fluid: number): number
	if tank.amount > 0 and tank.fluid ~= NONE and tank.fluid ~= fluid then
		return 0
	end
	return math.max(tank.capacity - tank.amount, 0)
end

local function changed(world: World, tank: Tank)
	if tank.amount <= 0 then
		tank.amount = 0
		tank.fluid = NONE
	end
	world.dirtyTanks[tank.key] = true
end

--[[
	The container of the machine with fluid tanks at pos key `key` (Players/Containers keeps it;
	server/Machines made it when the block appeared), nil for anything else.
]]
function PipeFluids.machineAt(world: World, key: number): Container?
	local x, y, z = Coords.decodePosKey(key)
	local container = world.env.containers:peek(x, y, z)
	if container and container.kind == Machines.CONTAINER_KIND and Machines.hasTanks(container.block) then
		return container
	end
	return nil
end

--[[
	Splits `amount` evenly over targets with room `rooms` (each takes at most its room), smallest
	room first so the others get what those cannot take; what rounding leaves goes to the later
	ones and what nobody takes is not given. Returns what each target gets, in `rooms` order.
]]
function PipeFluids.split(amount: number, rooms: { number }): { number }
	local n = #rooms
	local order = table.create(n)
	for i = 1, n do
		order[i] = i
	end
	table.sort(order, function(a, b)
		if rooms[a] ~= rooms[b] then
			return rooms[a] < rooms[b]
		end
		return a < b
	end)
	local given = table.create(n, 0)
	local left = amount
	for rank, index in order do
		local share = left // (n - rank + 1)
		local give = math.min(rooms[index], share)
		given[index] = give
		left -= give
	end
	return given
end

--[[
	Gives `targets` (in key order) up to `amount` mB of `fluid`, split evenly (`split`). Returns
	how much they took.
]]
local function deliver(world: World, targets: { Target }, fluid: number, amount: number): number
	if #targets == 0 or amount <= 0 then
		return 0
	end
	table.sort(targets, function(a, b)
		return a.key < b.key
	end)
	local rooms = table.create(#targets)
	for i, target in targets do
		rooms[i] = target.room
	end
	local given = PipeFluids.split(amount, rooms)
	local total = 0
	for i, target in targets do
		local share = given[i]
		if share > 0 then
			local tank, container, network = target.tank, target.container, target.network
			if tank then
				tank.fluid = fluid
				tank.amount += share
				changed(world, tank)
			elseif container then
				-- (`room` came from fluidRoom, so it all fits.)
				share = Machines.insertFluid(container, fluid, share)
			elseif network then
				network.fluid = fluid
				network.amount += share
			end
			total += share
		end
	end
	return total
end

-- One tick of `network`.
local function tick(world: World, network: Network)
	local ports = network.ports
	if next(ports) == nil then
		return
	end
	local tanks = world.tanks

	-- 1. Pull from the acceptors on PULL sides.
	for key, node in ports do
		for side = 0, 5 do
			if has(node.acceptors, side) and modeOf(node.modes, side) == PULL then
				local neighbour = Grid.neighbour(key, side)
				local room = network.capacity - network.amount
				if neighbour == nil or room <= 0 then
					continue
				end
				local pull = math.min(Transmitters.pullAmount(node.block), room)
				local tank = tanks[neighbour]
				if tank then
					if tank.amount > 0 and (network.amount <= 0 or network.fluid == tank.fluid) then
						local take = math.min(pull, tank.amount)
						if take > 0 then
							network.fluid = tank.fluid
							network.amount += take
							tank.amount -= take
							changed(world, tank)
						end
					end
				else
					local container = PipeFluids.machineAt(world, neighbour)
					if container then
						local wanted = if network.amount > 0 then network.fluid else nil
						local fluid, take = Machines.extractFluid(container, pull, wanted)
						if take > 0 then
							network.fluid = fluid
							network.amount += take
						end
					end
				end
			end
		end
	end

	-- 2. Push evenly into the acceptors on NORMAL / PUSH sides.
	if network.amount <= 0 then
		network.amount = 0
		network.fluid = NONE
		return
	end
	local fluid = network.fluid
	local seen: { [number]: boolean } = {}
	local targets: { Target } = {}
	for key, node in ports do
		for side = 0, 5 do
			if has(node.acceptors, side) and Transmitters.outputs(modeOf(node.modes, side)) then
				local neighbour = Grid.neighbour(key, side)
				if neighbour == nil or seen[neighbour] then
					continue
				end
				seen[neighbour] = true
				local tank = tanks[neighbour]
				if tank then
					local room = tankRoom(tank, fluid)
					if room > 0 then
						table.insert(targets, { key = neighbour, room = room, tank = tank })
					end
				else
					local container = PipeFluids.machineAt(world, neighbour)
					local room = if container then Machines.fluidRoom(container, fluid) else 0
					if container and room > 0 then
						table.insert(targets, { key = neighbour, room = room, container = container })
					end
				end
			end
		end
	end
	network.amount -= deliver(world, targets, fluid, network.amount)
	if network.amount <= 0 then
		network.amount = 0
		network.fluid = NONE
	end
end

-- One tick of every network.
function PipeFluids.step(world: World)
	for network in world.networks do
		tick(world, network)
	end
end

--[[
	Does `network` lead `fluid` somewhere: an acceptor on a NORMAL or PUSH side of its pipes that
	takes that fluid (a Fluid Tank empty or holding it, a machine whose input tanks take it)? Room
	does not matter: the buffer waits. Worked out once a tick per network and fluid (every machine
	next to a big network asks).
]]
local function leadsSomewhere(world: World, network: Network, fluid: number): boolean
	if network.leadsTick ~= world.tick then
		network.leadsTick = world.tick
		table.clear(network.leads)
	end
	local known = network.leads[fluid]
	if known ~= nil then
		return known
	end
	local found = false
	for key, node in network.ports do
		for side = 0, 5 do
			if has(node.acceptors, side) and Transmitters.outputs(modeOf(node.modes, side)) then
				local neighbour = Grid.neighbour(key, side)
				local tank = if neighbour then world.tanks[neighbour] else nil
				if tank then
					found = tank.amount <= 0 or tank.fluid == NONE or tank.fluid == fluid
				elseif neighbour then
					local container = PipeFluids.machineAt(world, neighbour)
					found = container ~= nil and Machines.takesFluid(container.block, fluid)
				end
				if found then
					break
				end
			end
		end
		if found then
			break
		end
	end
	network.leads[fluid] = found
	return found
end

--[[
	Does a pipe PULL from the Fluid Tank at pos key `key` into a network that leads `fluid`
	nowhere (`leadsSomewhere`; or one not built yet, to be safe)? Then the tank is another line's
	supply, and `fluid` put into it would be pulled into that line and stay there (see the header).
]]
local function suppliesElsewhere(world: World, key: number, fluid: number): boolean
	for side = 0, 5 do
		local neighbour = Grid.neighbour(key, side)
		local node = if neighbour then world.nodes[neighbour] else nil
		if node and node.kind == "fluid" then
			-- (The pipe's side facing the tank.)
			local back = Transmitters.opposite(side)
			local network = node.network
			if
				has(node.acceptors, back)
				and modeOf(node.modes, back) == PULL
				and (network == nil or not leadsSomewhere(world, network, fluid))
			then
				return true
			end
		end
	end
	return false
end

--[[
	The machine with fluid tanks at (x, y, z) (`container`) pushes its output tanks out (Mekanism's
	ejector): up to Machines.FLUID_EJECT_RATE mB a tick, of the first output tank that holds
	anything (Machines.extractFluid), split evenly over the Fluid Tanks next to it that take it
	(but not another line's supply: `suppliesElsewhere`) and the pipes next to it whose side facing
	it receives (NORMAL or PULL), whose buffer is empty or holds that fluid and whose network leads
	it somewhere (see the header). Returns how much went out.
]]
function PipeFluids.eject(world: World, x: number, y: number, z: number, container: Container): number
	local fluid, available = Machines.extractFluid(container, Machines.FLUID_EJECT_RATE, nil, true)
	if available <= 0 then
		return 0
	end
	local key = Grid.key(x, y, z)
	if key == nil then
		return 0
	end
	local targets: { Target } = {}
	for side = 0, 5 do
		local neighbour = Grid.neighbour(key, side)
		if neighbour == nil then
			continue
		end
		local tank = world.tanks[neighbour]
		local node = world.nodes[neighbour]
		if tank then
			local room = tankRoom(tank, fluid)
			if room > 0 and not suppliesElsewhere(world, neighbour, fluid) then
				table.insert(targets, { key = neighbour, room = room, tank = tank })
			end
		elseif node and node.kind == "fluid" then
			-- (The pipe's side facing back must be joined to this machine and take things in.)
			local back = Transmitters.opposite(side)
			local network = node.network
			if
				network
				and has(node.acceptors, back)
				and Transmitters.receives(modeOf(node.modes, back))
				and (network.amount <= 0 or network.fluid == fluid)
				and leadsSomewhere(world, network, fluid)
			then
				local room = network.capacity - network.amount
				if room > 0 then
					table.insert(targets, { key = neighbour, room = room, network = network })
				end
			end
		end
	end
	-- (Two pipes of one network next to the machine share its room: count it once.)
	local networks: { [Network]: boolean } = {}
	local kept: { Target } = {}
	for _, target in targets do
		local network = target.network
		if network == nil or not networks[network] then
			if network then
				networks[network] = true
			end
			table.insert(kept, target)
		end
	end
	local sent = deliver(world, kept, fluid, available)
	if sent > 0 then
		Machines.extractFluid(container, sent, fluid)
	end
	return sent
end

return PipeFluids
