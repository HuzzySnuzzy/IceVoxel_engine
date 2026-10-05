--!strict
--[[
	Mekanism's ejector, for the plain inventories next to a furnace or machine: what its output
	slots hold (Transmitters.ejectSlots: a furnace's output, a machine's output slots) is pushed
	out on its own, every INTERVAL (10) ticks, into the chests on its six sides (and any other
	plain inventory: Transmitters.isPlain), each through its face towards the furnace. Never
	straight into another furnace or machine, which would make surprise chains (cobblestone into
	stone into smooth stone); transporters still lead results into machines when players build
	them so. The transporters around take theirs themselves (Transmitters/Transport: their NORMAL
	and PULL sides receive).

	A push is Mekanism's TransitRequest: the item types the output slots hold, in slot order; the
	first that fits anywhere goes out, up to a stack, filling the inventories around in side
	order (Down, Up, North, South, West, East) as far as they have room. What does not fit stays.

	Pure (no Roblox APIs, so the tests run it): blocks come from Env.getBlock, which never
	generates terrain (peekBlock, falling back to the edit list, as the pipes read them), and
	contents from Players/Containers. Both containers' viewers hear of a change through
	Env.inventoryChanged, and a furnace is ticked again (its output has room now).

	Who runs it: Players/Inventories' furnace loop, every INTERVAL furnace ticks, for every
	furnace with results (`furnaces`); Machines/MachineWorld, every INTERVAL ticks, for every
	machine with output slots (`push`).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Items = require(Shared.Items)
local Transmitters = require(Shared.Transmitters)
local InventoryTypes = require(Shared.Inventory.Types)

local Containers = require(script.Parent.Parent.Players.Containers)

type Container = InventoryTypes.Container
type Slots = Transmitters.Slots
type Stack = Items.Stack

export type Env = {
	-- The block at (x, y, z), nil when the server does not know it. Never generates terrain.
	getBlock: (x: number, y: number, z: number) -> number?,
	-- Chests, furnaces and machines (Players/Containers).
	containers: Containers.Store,
	-- The slots of the inventory at (x, y, z) changed (its viewers need a snapshot).
	inventoryChanged: ((x: number, y: number, z: number) -> ())?,
}

local Eject = {}

-- Ticks between two pushes of a furnace or machine (Mekanism's ejector: 10).
Eject.INTERVAL = 10

local EMPTY: Slots = table.freeze({})

-- A plain inventory next to the furnace: where, its block and its face towards the furnace.
type Target = { x: number, y: number, z: number, block: number, face: number }

-- Puts `slots` (a new table from Transmitters' maths) into `container`, stack tables replaced as
-- Inventory/Menu does, so its viewers' windows (the same table) see it.
local function store(container: Container, slots: Slots)
	local current = container.slots
	for slot in current do
		if slots[slot] == nil then
			current[slot] = nil
		end
	end
	for slot, stack in slots do
		current[slot] = stack
	end
end

local function changed(env: Env, x: number, y: number, z: number)
	local inventoryChanged = env.inventoryChanged
	if inventoryChanged then
		inventoryChanged(x, y, z)
	end
end

--[[
	One push of the furnace or machine whose contents are `container`, at (x, y, z): its results
	into the plain inventories around it (see the header). Returns how many items moved.
]]
function Eject.push(env: Env, x: number, y: number, z: number, container: Container): number
	local block = container.block
	local types = Transmitters.results(block, container.slots)
	if #types == 0 then
		return 0
	end
	local targets: { Target } = {}
	for side = 0, 5 do
		local dx, dy, dz = Transmitters.offset(side)
		local tx, ty, tz = x + dx, y + dy, z + dz
		local target = env.getBlock(tx, ty, tz)
		if target ~= nil and Transmitters.isPlain(target) then
			table.insert(targets, { x = tx, y = ty, z = tz, block = target, face = Transmitters.opposite(side) })
		end
	end
	if #targets == 0 then
		return 0
	end
	local containers = env.containers
	for _, kind in types do
		-- Up to a stack of the first type that fits somewhere.
		local left = math.min(kind.count, Items.maxStack(kind.item), Items.MAX_STACK)
		local moved = 0
		for _, target in targets do
			if left < 1 then
				break
			end
			local stored = containers:peek(target.x, target.y, target.z)
			local slots = if stored and stored.block == target.block then stored.slots else EMPTY
			-- What goes in decides what comes out, so nothing is lost or made.
			local into, rest =
				Transmitters.insert(target.block, target.face, slots, Items.withCount(kind, left) :: Stack)
			local fits = left - (if rest then rest.count else 0)
			if fits >= 1 then
				local remaining, taken = Transmitters.takeResults(block, container.slots, fits, kind)
				if taken and taken.count == fits then
					store(container, remaining)
					store(containers:get(target.x, target.y, target.z, target.block), into)
					changed(env, target.x, target.y, target.z)
					left -= fits
					moved += fits
				end
			end
		end
		if moved > 0 then
			changed(env, x, y, z)
			-- (A furnace whose output was full cooks again.)
			containers:markActive(x, y, z)
			return moved
		end
	end
	return 0
end

--[[
	One push of every furnace whose output holds results (Containers' `ejectingFurnaces`) into the
	plain inventories around it. A furnace whose block is no longer there (its container not
	taken yet) is skipped. Returns how many items moved in all.
]]
function Eject.furnaces(env: Env): number
	local moved = 0
	for _, entry in env.containers:ejectingFurnaces() do
		local container = entry.container
		if env.getBlock(entry.x, entry.y, entry.z) == container.block then
			moved += Eject.push(env, entry.x, entry.y, entry.z, container)
		end
	end
	return moved
end

return Eject
