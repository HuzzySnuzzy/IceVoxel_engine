--!strict
--[[
	Energy networks: Universal Cables and Mekanism machines joined into connected components, and
	the energy moved through each of them every tick. Pure (the tests run it on tables of blocks).

	Graph. Nodes are Universal Cables (Transmitters/TransmitterWorld's "energy" nodes) and
	machines (MachineWorld). Edges:
	  * cable - cable    the cables' `links` (Shared/Transmitters.connects: neither side NONE);
	  * cable - machine  the cable's `acceptors` (an energy block on a side that is not NONE);
	  * machine - machine  directly adjacent energy blocks, always: a generator next to a machine
	                     works without a cable.
	Configurator modes on a cable's sides: NONE cuts, PUSH and PULL act as NORMAL (a machine's
	part is its own role, Shared/Machines.role).

	Rebuilding. Positions whose links may have changed (cables that came, went or relinked:
	TransmitterWorld's `energyDirty`; machines that came or went: MachineWorld's `dirty`) dissolve
	their network and their neighbours' networks; every member is queued and flood filled into new
	networks, at most a budget of positions a tick (the rest carries over; positions waiting for
	their network move no energy meanwhile). A change at or next to a position the fill in progress
	visited starts it over; changes elsewhere leave it going.

	Each tick, per network (`solve`; Shared/Machines energy maths, exact in quanta):
	  1. supply = what each producer has, at most its output rate this tick;
	  2. demand = each consumer's room, at most its input rate;
	  3. moved = min(supply, demand, throughput), where throughput is the sum of the cables'
	     capacities (Mekanism's CableTier) or unlimited without cables. The consumers get it with
	     Mekanism's even split (Machines.share) and the producers give it the same way;
	  4. backup: what producers still have charges storage (batteries) up to their input rates,
	     within the throughput left; what consumers still need is then covered by storage
	     discharging up to their output rates, within what is left after that.
	Storage never charges storage. Every amount is a multiple of Machines.QUANTUM, so what is
	taken is exactly what is given: energy is never made or lost. Each machine's data records what
	the network put in (INPUT) and took out (OUTPUT) this tick.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Machines = require(Shared.Machines)
local Transmitters = require(Shared.Transmitters)

local Grid = require(script.Parent.Parent.Transmitters.Grid)
local Types = require(script.Parent.Types)

type World = Types.World
type Machine = Types.Machine
type Component = Types.Component

local ENERGY, INPUT, OUTPUT = Machines.ENERGY, Machines.INPUT, Machines.OUTPUT

local EnergyNet = {}

-- Positions a rebuild visits per tick at most (as TransmitterWorld's pipe networks).
EnergyNet.MAX_REBUILD = 4096

local function has(mask: number, side: number): boolean
	return bit32.btest(mask, bit32.lshift(1, side))
end

-- The Universal Cable at `key` (a TransmitterWorld node of kind "energy"), if any.
local function cableAt(world: World, key: number): any
	local transmitters = world.env.transmitters
	local node = if transmitters then transmitters.nodes[key] else nil
	return if node and node.kind == "energy" then node else nil
end

local function isMember(world: World, key: number): boolean
	return world.machines[key] ~= nil or cableAt(world, key) ~= nil
end

-- Calls `visit(neighbour)` for every position joined to `key` in the graph.
local function eachLink(world: World, key: number, visit: (number) -> ())
	local cable = cableAt(world, key)
	if cable then
		for side = 0, 5 do
			local linked, accepting = has(cable.links, side), has(cable.acceptors, side)
			if linked or accepting then
				local neighbour = Grid.neighbour(key, side)
				if
					neighbour and ((linked and cableAt(world, neighbour)) or (accepting and world.machines[neighbour]))
				then
					visit(neighbour)
				end
			end
		end
	elseif world.machines[key] then
		for side = 0, 5 do
			local neighbour = Grid.neighbour(key, side)
			if neighbour then
				if world.machines[neighbour] then
					visit(neighbour)
				else
					local other = cableAt(world, neighbour)
					if other and has(other.acceptors, Transmitters.opposite(side)) then
						visit(neighbour)
					end
				end
			end
		end
	end
end

--[[ Rebuilding ]]

local function seed(world: World, key: number)
	if not world.seedSet[key] then
		world.seedSet[key] = true
		table.insert(world.seeds, key)
	end
end

-- Takes a network apart: its members wait for a network again.
local function dissolve(world: World, component: Component?)
	if component == nil or not world.components[component] then
		return
	end
	world.components[component] = nil
	for _, key in component.keys do
		if world.componentOf[key] == component then
			world.componentOf[key] = nil
		end
		local machine = world.machines[key]
		if machine and machine.component == component then
			machine.component = nil
		end
		seed(world, key)
	end
end

-- A finished flood fill: its members (those still there) become one network.
local function finish(world: World, members: { number })
	local keys: { number } = {}
	local machines: { Machine } = {}
	local cables, throughput = 0, 0
	for _, key in members do
		if world.componentOf[key] == nil then
			local machine = world.machines[key]
			local cable = cableAt(world, key)
			if machine then
				table.insert(keys, key)
				table.insert(machines, machine)
			elseif cable then
				table.insert(keys, key)
				cables += 1
				throughput += Transmitters.cableCapacity(cable.block)
			end
		end
	end
	if #keys == 0 then
		return
	end
	table.sort(machines, function(a: Machine, b: Machine): boolean
		return a.key < b.key
	end)
	world.nextComponent += 1
	local component: Component = {
		id = world.nextComponent,
		keys = keys,
		machines = machines,
		cables = cables,
		throughput = if cables > 0 then throughput else math.huge,
	}
	world.components[component] = true
	for _, key in keys do
		world.componentOf[key] = component
	end
	for _, machine in machines do
		machine.component = component
	end
end

--[[
	Does a change at one of `keys` touch the fill in progress: a position it visited, or one next to
	such a position? Every link that changes marks a position at one of its ends (cables relinked,
	machines that came or went), so a change that touches none of the fill's positions leaves every
	link it walked or will walk from them as it was.
]]
local function touches(job: { visited: { [number]: boolean } }, keys: { [number]: boolean }): boolean
	local visited = job.visited
	for key in keys do
		if visited[key] then
			return true
		end
		for side = 0, 5 do
			local neighbour = Grid.neighbour(key, side)
			if neighbour and visited[neighbour] then
				return true
			end
		end
	end
	return false
end

--[[
	Works out the networks again around the positions whose links changed, flood filling at most
	`budget` positions (a fill in progress carries over to the next call).
]]
function EnergyNet.rebuild(world: World, budget: number)
	local transmitters = world.env.transmitters
	if transmitters and next(transmitters.energyDirty) ~= nil then
		for key in transmitters.energyDirty do
			world.dirty[key] = true
		end
		table.clear(transmitters.energyDirty)
	end
	if next(world.dirty) ~= nil then
		local job = world.job
		if job and touches(job, world.dirty) then
			-- (Its view of the graph may be out of date: start it over. A change elsewhere leaves it
			-- going, so edits far away never starve a big network's fill.)
			world.job = nil
			for key in job.visited do
				seed(world, key)
			end
		end
		for key in world.dirty do
			dissolve(world, world.componentOf[key])
			seed(world, key)
			for side = 0, 5 do
				local neighbour = Grid.neighbour(key, side)
				if neighbour then
					dissolve(world, world.componentOf[neighbour])
					seed(world, neighbour)
				end
			end
		end
		table.clear(world.dirty)
	end
	while budget > 0 do
		local job = world.job
		if job == nil then
			local key = table.remove(world.seeds)
			if key == nil then
				return
			end
			local live = world.seedSet[key]
			world.seedSet[key] = nil
			if not live or world.componentOf[key] ~= nil or not isMember(world, key) then
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
		if isMember(world, key) then
			world.seedSet[key] = nil
			table.insert(job.members, key)
			local visited, frontier = job.visited, job.frontier
			eachLink(world, key, function(neighbour: number)
				if not visited[neighbour] then
					visited[neighbour] = true
					table.insert(frontier, neighbour)
				end
			end)
		end
	end
end

-- Is network work still queued (or a flood fill in progress)?
function EnergyNet.rebuilding(world: World): boolean
	if world.job or next(world.dirty) ~= nil then
		return true
	end
	local transmitters = world.env.transmitters
	if transmitters and next(transmitters.energyDirty) ~= nil then
		return true
	end
	for _, key in world.seeds do
		if world.seedSet[key] and world.componentOf[key] == nil and isMember(world, key) then
			return true
		end
	end
	return false
end

--[[ Moving energy ]]

local function sum(values: { number }): number
	local total = 0
	for _, value in values do
		total += value
	end
	return total
end

-- Takes `amounts[i]` out of `machines[i]` (OUTPUT records it); a creative cube never runs dry.
local function take(machines: { Machine }, amounts: { number })
	for i, machine in machines do
		local amount = amounts[i]
		if amount > 0 then
			local data = machine.container.data :: { number }
			if data[ENERGY] ~= math.huge then
				data[ENERGY] -= amount
			end
			data[OUTPUT] += amount
		end
	end
end

-- Puts `amounts[i]` into `machines[i]` (INPUT records it).
local function give(machines: { Machine }, amounts: { number })
	for i, machine in machines do
		local amount = amounts[i]
		if amount > 0 then
			local data = machine.container.data :: { number }
			data[ENERGY] += amount
			data[INPUT] += amount
		end
	end
end

-- One tick of one network (see the header). Returns the J moved.
local function solveComponent(component: Component): number
	local producers: { Machine }, avails: { number } = {}, {}
	local consumers: { Machine }, needs: { number } = {}, {}
	local storages: { Machine }, chargeable: { number }, dischargeable: { number } = {}, {}, {}
	for _, machine in component.machines do
		local container = machine.container
		local input, output = Machines.rates(container)
		local role = machine.role
		if role == "producer" then
			local avail = math.min(Machines.energy(container), output)
			if avail > 0 then
				table.insert(producers, machine)
				table.insert(avails, avail)
			end
		elseif role == "consumer" then
			local need = Machines.quantise(math.min(Machines.room(container), input))
			if need > 0 then
				table.insert(consumers, machine)
				table.insert(needs, need)
			end
		elseif role == "storage" then
			table.insert(storages, machine)
			table.insert(dischargeable, math.min(Machines.energy(container), output))
			table.insert(chargeable, Machines.quantise(math.min(Machines.room(container), input)))
		end
	end
	if #producers == 0 and (#consumers == 0 or #storages == 0) then
		return 0
	end
	local throughput = component.throughput
	-- 1-3: producers to consumers.
	local supply, demand = sum(avails), sum(needs)
	local moved = Machines.quantise(math.min(supply, demand, throughput))
	local gives = Machines.share(moved, needs)
	local given = sum(gives)
	local takes = Machines.share(given, avails)
	take(producers, takes)
	give(consumers, gives)
	local total = given
	local left = throughput - given
	-- 4: the producers' surplus charges storage...
	if #storages > 0 and #producers > 0 and left > 0 then
		local surplus: { number } = table.create(#producers, 0)
		for i, avail in avails do
			surplus[i] = avail - takes[i]
		end
		local charge = Machines.quantise(math.min(sum(surplus), sum(chargeable), left))
		if charge > 0 then
			local charges = Machines.share(charge, chargeable)
			local charged = sum(charges)
			take(producers, Machines.share(charged, surplus))
			give(storages, charges)
			total += charged
			left -= charged
		end
	end
	-- ...and storage covers what the consumers still need.
	if #storages > 0 and #consumers > 0 and left > 0 then
		local short: { number } = table.create(#consumers, 0)
		for i, need in needs do
			short[i] = need - gives[i]
		end
		local discharge = Machines.quantise(math.min(sum(short), sum(dischargeable), left))
		if discharge > 0 then
			local covers = Machines.share(discharge, short)
			local covered = sum(covers)
			take(storages, Machines.share(covered, dischargeable))
			give(consumers, covers)
			total += covered
		end
	end
	return total
end

--[[
	Moves one tick's energy through every network (see the header). Machines' INPUT and OUTPUT
	must have been reset (MachineWorld.step does). Returns the J moved in all.
]]
function EnergyNet.solve(world: World): number
	local total = 0
	for component in world.components do
		if #component.machines >= 2 then
			total += solveComponent(component)
		end
	end
	return total
end

return EnergyNet
