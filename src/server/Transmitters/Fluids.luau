--!strict
--[[
	Water in Mechanical Pipes: Mekanism's MechanicalPipe and FluidNetwork, simplified.
	Transmitters/TransmitterWorld runs `step` 20 times a second over its networks (the pipes joined
	into one: a connected component) and its fluid tanks. Pure.

	A network has one buffer: one fluid (only water exists) and up to the sum of its pipes'
	capacities (2 000 / 8 000 / 32 000 / 128 000 mB a pipe, Basic to Ultimate). Each tick:

	  1. Pull (MechanicalPipe.pullFromAcceptors): every pipe side set to PULL on a tank takes up to
	     the pipe's pull amount (250 / 1 000 / 8 000 / 32 000 mB) from it, as far as the buffer has
	     room, and only the buffer's fluid when it holds any.
	  2. Push (FluidNetwork.tickEmit, EmitUtils.sendToAcceptors): the buffer is split evenly over
	     the tanks on NORMAL or PUSH sides of its pipes that have room for its fluid (each tank
	     once, however many pipes touch it); a tank that takes less than its share leaves the rest
	     to the others, and the whole mB left over by rounding goes to the last ones. What nobody
	     takes stays in the buffer.

	Merging and splitting buffers when pipes join or part is TransmitterWorld's (by capacity).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Transmitters = require(Shared.Transmitters)

local Grid = require(script.Parent.Grid)
local Types = require(script.Parent.Types)

type World = Types.World
type Network = Types.Network
type Tank = Types.Tank

local NONE = Transmitters.FLUIDS.NONE
local PULL = Transmitters.MODES.PULL

local modeOf = Transmitters.modeOf

local Fluids = {}

local function has(mask: number, side: number): boolean
	return bit32.btest(mask, bit32.lshift(1, side))
end

-- May `tank` take water of `fluid`: empty, or holding the same?
local function accepts(tank: Tank, fluid: number): boolean
	return tank.amount < tank.capacity and (tank.amount <= 0 or tank.fluid == NONE or tank.fluid == fluid)
end

local function changed(world: World, tank: Tank)
	if tank.amount <= 0 then
		tank.amount = 0
		tank.fluid = NONE
	end
	world.dirtyTanks[tank.key] = true
end

--[[
	Splits `amount` evenly over targets with room `rooms` (each takes at most its room), smallest
	room first so the others get what those cannot take; what rounding leaves goes to the later
	ones and what nobody takes is not given. Returns what each target gets, in `rooms` order.
]]
function Fluids.split(amount: number, rooms: { number }): { number }
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

-- One tick of `network`.
local function tick(world: World, network: Network)
	local ports = network.ports
	if next(ports) == nil then
		return
	end
	local tanks = world.tanks

	-- 1. Pull from tanks on PULL sides.
	for key, node in ports do
		for side = 0, 5 do
			if has(node.acceptors, side) and modeOf(node.modes, side) == PULL then
				local neighbour = Grid.neighbour(key, side)
				local tank = if neighbour then tanks[neighbour] else nil
				if tank and tank.amount > 0 and (network.amount <= 0 or network.fluid == tank.fluid) then
					local take =
						math.min(Transmitters.pullAmount(node.block), tank.amount, network.capacity - network.amount)
					if take > 0 then
						network.fluid = tank.fluid
						network.amount += take
						tank.amount -= take
						changed(world, tank)
					end
				end
			end
		end
	end

	-- 2. Push evenly into tanks on NORMAL / PUSH sides.
	if network.amount <= 0 then
		network.fluid = NONE
		return
	end
	local fluid = network.fluid
	local seen: { [number]: boolean } = {}
	local targets: { Tank } = {}
	for key, node in ports do
		for side = 0, 5 do
			if has(node.acceptors, side) and Transmitters.outputs(modeOf(node.modes, side)) then
				local neighbour = Grid.neighbour(key, side)
				local tank = if neighbour then tanks[neighbour] else nil
				if neighbour and tank and not seen[neighbour] and accepts(tank, fluid) then
					seen[neighbour] = true
					table.insert(targets, tank)
				end
			end
		end
	end
	if #targets == 0 then
		return
	end
	table.sort(targets, function(a, b)
		return a.key < b.key
	end)
	local rooms = table.create(#targets)
	for i, tank in targets do
		rooms[i] = tank.capacity - tank.amount
	end
	local given = Fluids.split(network.amount, rooms)
	for i, tank in targets do
		local amount = given[i]
		if amount > 0 then
			tank.fluid = fluid
			tank.amount += amount
			network.amount -= amount
			changed(world, tank)
		end
	end
	if network.amount <= 0 then
		network.amount = 0
		network.fluid = NONE
	end
end

-- One tick of every network.
function Fluids.step(world: World)
	for network in world.networks do
		tick(world, network)
	end
end

return Fluids
