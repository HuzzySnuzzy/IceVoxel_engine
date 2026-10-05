--!strict
--[[
	The server's Mekanism machines, pure (no Roblox APIs, so the tests run it): every machine
	block's state, their ticks, the energy networks (Machines/EnergyNet), sustained data and what
	has to be replicated. Machines/Machines runs it in the game.

	State (Machines/Types), all in memory like chests: nothing is saved.
	  Machines  one per machine block (Shared/Machines), made and dropped by `blockChanged` (the
	            server chains it onto WorldServer.onChanged, so every placement, break and Api
	            change comes through). Its contents are a container of kind "machine" in
	            Players/Containers (created here when the block appears, so a machine works before
	            anyone opens it), the same table its viewers' windows hold.
	  Networks  Universal Cables (Transmitters/TransmitterWorld's energy nodes) and machines joined
	            into energy networks (EnergyNet), worked out again where links change.

	Each `step` (20 a second, Shared/Machines' order): queued network work, then every machine's
	kind tick (Machines.tick: its own work, energy kept within its capacity), then the energy
	networks move energy (EnergyNet.solve). A kind whose tick errors is reported once and skipped.
	Every Eject.INTERVAL (10) ticks a machine with output slots also pushes its results into the
	chests next to it after its tick (Transmitters/Eject, Mekanism's ejector; the transporters
	around take theirs themselves). Afterwards `takeChanges` says whose slots and whose data
	changed (their viewers need a snapshot).

	The sky. Kinds ask whether a cell sees the sky straight up (TickContext `sky`: solar panels).
	`seesSky` answers from a cache per cell, filled by the game's uncached look (Env `sky`:
	Machines/SkyCheck over the server's world, which never generates terrain; without one, the
	cells above are read with `getBlock`). `blockChanged` keeps it true without looking again: an
	opaque block put above a cell covers it at once, and a cell whose roof may have gone is looked
	at again when next asked. A machine's own cell is forgotten when it goes; at most MAX_SKY_CELLS
	answers are kept in all (then they start over).

	Sustained data (Mekanism): a machine broken by a survival player keeps its energy (and its
	kind's `keep` fields) in its item, and placing that item puts them back (`blockDataHooks`,
	registered with ServerNet's `addBlockData`). Its slots drop as items (Players/Inventories, as
	chests).

	Replication. `takeRecords` gives the Machines records (energy, capacity, the network's input
	and output, the machine's own rate, active, its kind's state code) that changed since they
	were last sent, each at most every RECORD_INTERVAL ticks (4 a second). `chunkRecords` gives a
	chunk's records that are not in the default state (empty, idle, the block's capacity, state
	0), to send with its edit list.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local Coords = require(Shared.World.Coords)
local Items = require(Shared.Items)
local Machines = require(Shared.Machines)

local EditRules = require(script.Parent.Parent.Network.EditRules)
local Eject = require(script.Parent.Parent.Transmitters.Eject)
local Grid = require(script.Parent.Parent.Transmitters.Grid)
local EnergyNet = require(script.Parent.EnergyNet)
local Types = require(script.Parent.Types)

export type World = Types.World
export type Machine = Types.Machine
export type Component = Types.Component
export type Env = Types.Env
type MachineRecord = Types.MachineRecord

local ENERGY, CAPACITY, INPUT, OUTPUT, RATE, ACTIVE =
	Machines.ENERGY, Machines.CAPACITY, Machines.INPUT, Machines.OUTPUT, Machines.RATE, Machines.ACTIVE

local MachineWorld = {}

-- Ticks between two records of one machine (4 a second).
MachineWorld.RECORD_INTERVAL = 5
-- Day time used when the game gives none (noon).
local NOON = 6000
-- Sky answers kept at most (far more than the solar panels players build: a panel asks about its
-- own cell only).
MachineWorld.MAX_SKY_CELLS = 65536
local HEIGHT = Config.WorldHeight

function MachineWorld.new(env: Env): World
	local world: World = {
		env = env,
		tick = 0,
		machines = {},
		count = 0,
		byChunk = {},
		components = {},
		componentOf = {},
		nextComponent = 0,
		dirty = {},
		seeds = {},
		seedSet = {},
		job = nil,
		slotsChanged = {},
		dataChanged = {},
		dirtyRecords = {},
		moved = 0,
		failed = {},
		sky = {},
		skyCells = 0,
		ctx = {
			block = 0,
			x = 0,
			y = 0,
			z = 0,
			energy = { capacity = 1 },
			tick = 0,
			dayTime = NOON,
			getBlock = env.getBlock,
			sky = nil,
		},
	}
	world.ctx.sky = function(x: number, y: number, z: number): boolean
		return MachineWorld.seesSky(world, x, y, z)
	end
	return world
end

--[[ Lookups ]]

function MachineWorld.machine(world: World, x: number, y: number, z: number): Machine?
	local key = Grid.key(x, y, z)
	return if key then world.machines[key] else nil
end

--[[
	The energy network at (x, y, z) (a cable or a machine): how many machines and cables it has
	and the J per tick it moves at most (math.huge without cables); nil when there is none (or it
	is being worked out again).
]]
function MachineWorld.network(world: World, x: number, y: number, z: number): Component?
	local key = Grid.key(x, y, z)
	return if key then world.componentOf[key] else nil
end

-- The record a machine's clients see by default (none sent): empty, idle, the block's capacity.
local function defaultRecord(machine: Machine): MachineRecord
	return {
		x = machine.x,
		y = machine.y,
		z = machine.z,
		energy = 0,
		capacity = machine.energy.capacity,
		input = 0,
		output = 0,
		rate = 0,
		active = false,
		state = 0,
	}
end

-- The record of a machine as it is now.
function MachineWorld.record(machine: Machine): MachineRecord
	local data = machine.container.data :: { number }
	return {
		x = machine.x,
		y = machine.y,
		z = machine.z,
		energy = data[ENERGY],
		capacity = data[CAPACITY],
		input = data[INPUT],
		output = data[OUTPUT],
		rate = data[RATE],
		active = data[ACTIVE] ~= 0,
		state = Machines.state(machine.container),
	}
end

local function sameRecord(a: MachineRecord, b: MachineRecord): boolean
	return a.energy == b.energy
		and a.capacity == b.capacity
		and a.input == b.input
		and a.output == b.output
		and a.rate == b.rate
		and a.active == b.active
		and a.state == b.state
end

--[[ The sky ]]

-- The key of column (x, z) in the sky cache (nil outside the world).
local function columnKey(x: number, z: number): number?
	return Grid.key(x, 0, z)
end

-- The uncached look: the game's (SkyCheck), else the cells above read one by one.
local function lookUp(env: Env, x: number, y: number, z: number): boolean
	local sky = env.sky
	if sky then
		return sky(x, y, z)
	end
	local getBlock = env.getBlock
	for cy = math.max(y + 1, 0), HEIGHT - 1 do
		local block = getBlock(x, cy, z)
		-- (Unknown cells count as air.)
		if block and Blocks.isOpaque(block) then
			return false
		end
	end
	return true
end

--[[
	Does cell (x, y, z) see the sky straight up: nothing opaque in any cell above it (Minecraft's
	canSeeSky)? Kinds get it as TickContext `sky`. Cached per cell (see the header); never
	generates terrain.
]]
function MachineWorld.seesSky(world: World, x: number, y: number, z: number): boolean
	local key = columnKey(x, z)
	if key == nil or y < 0 or y >= HEIGHT then
		return lookUp(world.env, x, y, z)
	end
	local column: { [number]: boolean }? = world.sky[key]
	local known = if column then column[y] else nil
	if known ~= nil then
		return known
	end
	local open = lookUp(world.env, x, y, z)
	if world.skyCells >= MachineWorld.MAX_SKY_CELLS then
		table.clear(world.sky)
		world.skyCells = 0
		column = nil
	end
	local cells: { [number]: boolean } = column or {}
	world.sky[key] = cells
	cells[y] = open
	world.skyCells += 1
	return open
end

--[[
	Block (x, y, z) went from `old` to `new`: the sky answers of the cells below it in its column
	follow. An opaque block covers them; one that was opaque may have uncovered the covered ones,
	which are looked at again when next asked.
]]
local function skyChanged(world: World, x: number, y: number, z: number, old: number, new: number)
	local key = columnKey(x, z)
	local column = if key then world.sky[key] else nil
	if key == nil or column == nil then
		return
	end
	local covers = Blocks.isValid(new) and Blocks.isOpaque(new)
	local uncovers = not covers and Blocks.isValid(old) and Blocks.isOpaque(old)
	if not (covers or uncovers) then
		return
	end
	for cy, open in column do
		if cy < y then
			if covers then
				column[cy] = false
			elseif not open then
				column[cy] = nil
				world.skyCells -= 1
			end
		end
	end
	if next(column) == nil then
		world.sky[key] = nil
	end
end

-- Forgets the sky answer of cell (x, y, z) (a machine that went).
local function forgetSky(world: World, x: number, y: number, z: number)
	local key = columnKey(x, z)
	local column = if key then world.sky[key] else nil
	if key and column and column[y] ~= nil then
		column[y] = nil
		world.skyCells -= 1
		if next(column) == nil then
			world.sky[key] = nil
		end
	end
end

--[[ Block changes ]]

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

local function removeMachine(world: World, machine: Machine)
	local key = machine.key
	world.machines[key] = nil
	world.count -= 1
	world.slotsChanged[key] = nil
	world.dataChanged[key] = nil
	world.dirtyRecords[key] = nil
	world.dirty[key] = true
	unindex(world, key, machine.x, machine.z)
	forgetSky(world, machine.x, machine.y, machine.z)
	-- (Players/Inventories took it already in the game, dropping its slots: this only tidies.)
	local containers = world.env.containers
	local stored = containers:peek(machine.x, machine.y, machine.z)
	if stored == machine.container then
		containers:take(machine.x, machine.y, machine.z)
	end
end

local function addMachine(world: World, key: number, x: number, y: number, z: number, block: number)
	local kind = Machines.kindOf(block) :: Machines.Kind
	local energy = Machines.energyOf(block) :: Machines.EnergySpec
	local container = world.env.containers:get(x, y, z, block)
	local machine: Machine = {
		key = key,
		x = x,
		y = y,
		z = z,
		block = block,
		kind = kind,
		energy = energy,
		role = Machines.role(block),
		container = container,
		component = nil,
		previous = table.clone(container.data :: { number }),
		previousSlots = {},
		sent = (nil :: any) :: MachineRecord,
		sentAt = -math.huge,
	}
	machine.sent = defaultRecord(machine)
	world.machines[key] = machine
	world.count += 1
	world.dirty[key] = true
	world.dirtyRecords[key] = true
	index(world, key, x, z)
end

--[[
	Block (x, y, z) changed from `old` to `new` (WorldServer.onChanged): a machine that went is
	dropped (its container too, if nothing took it yet), a new one starts empty (placing it from
	an item with data fills it after this: `blockDataHooks`), and the energy networks around are
	worked out again. Every change also keeps the sky answers of the cells below it true.
]]
function MachineWorld.blockChanged(world: World, x: number, y: number, z: number, old: number, new: number)
	if old == new then
		return
	end
	skyChanged(world, x, y, z, old, new)
	if not (Machines.isMachine(old) or Machines.isMachine(new)) then
		return
	end
	local key = Grid.key(x, y, z)
	if key == nil then
		return
	end
	local machine = world.machines[key]
	if machine then
		removeMachine(world, machine)
	end
	if Machines.isMachine(new) then
		addMachine(world, key, x, y, z, new)
	end
end

--[[ Ticking ]]

-- Copies `data` into `into` (reused table).
local function remember(into: { number }, data: { number })
	for i = 1, math.max(#into, #data) do
		into[i] = data[i]
	end
end

local function changedFrom(previous: { number }, data: { number }): boolean
	if #previous ~= #data then
		return true
	end
	for i = 1, #data do
		if previous[i] ~= data[i] then
			return true
		end
	end
	return false
end

-- One simulation tick (Shared/Machines' order: kinds, then the energy networks).
function MachineWorld.step(world: World)
	world.tick += 1
	EnergyNet.rebuild(world, EnergyNet.MAX_REBUILD)
	table.clear(world.slotsChanged)
	table.clear(world.dataChanged)
	local ctx = world.ctx
	local dayTime = world.env.dayTime
	ctx.tick = world.tick
	ctx.dayTime = if dayTime then dayTime() else NOON
	local eject = world.tick % Eject.INTERVAL == 0
	for _, machine in world.machines do
		local container = machine.container
		local data = container.data :: { number }
		remember(machine.previous, data)
		local slots, previousSlots = container.slots, machine.previousSlots
		for slot = 1, container.size do
			previousSlots[slot] = slots[slot]
		end
		ctx.block, ctx.x, ctx.y, ctx.z, ctx.energy = machine.block, machine.x, machine.y, machine.z, machine.energy
		local ok, err = pcall(Machines.tick, container, ctx)
		if not ok and not world.failed[machine.kind.name] then
			world.failed[machine.kind.name] = true
			warn(`[IceVoxel] machine kind {machine.kind.name} failed to tick: {err}`)
		end
		if eject and #machine.kind.outputs > 0 then
			Eject.push(world.env, machine.x, machine.y, machine.z, container)
		end
		data = container.data :: { number }
		data[INPUT], data[OUTPUT] = 0, 0
		-- (A kind may have replaced the slots table itself.)
		slots = container.slots
		for slot = 1, container.size do
			if slots[slot] ~= previousSlots[slot] then
				world.slotsChanged[machine.key] = machine
				break
			end
		end
	end
	world.moved = EnergyNet.solve(world)
	for key, machine in world.machines do
		if changedFrom(machine.previous, machine.container.data :: { number }) then
			world.dataChanged[key] = machine
			world.dirtyRecords[key] = true
		end
	end
end

--[[
	The machines whose slots and whose data changed in the last tick (read only; replaced by the
	next step). Their viewers need a snapshot: slots at once, data at the caller's pace.
]]
function MachineWorld.takeChanges(world: World): ({ [number]: Machine }, { [number]: Machine })
	return world.slotsChanged, world.dataChanged
end

--[[ Sustained data (Mekanism keeps a machine's energy in its item) ]]

--[[
	The machines' sustained data hooks, for ServerNet.addBlockData: a broken machine's item keeps
	its energy (Machines.save), and a machine placed from such an item gets it back
	(Machines.restore), in creative too.
]]
function MachineWorld.blockDataHooks(world: World): EditRules.BlockDataHooks
	return {
		save = function(x: number, y: number, z: number, block: number): Items.Data?
			local machine = MachineWorld.machine(world, x, y, z)
			if machine == nil or machine.block ~= block then
				return nil
			end
			return Machines.save(machine.container)
		end,
		placed = function(_player: any, x: number, y: number, z: number, block: number, stack: Items.Stack?)
			local machine = MachineWorld.machine(world, x, y, z)
			if stack == nil or stack.data == nil or machine == nil or machine.block ~= block then
				return
			end
			if Machines.restore(machine.container, stack.data) then
				world.dirtyRecords[machine.key] = true
				world.dataChanged[machine.key] = machine
			end
		end,
	}
end

--[[ Replication ]]

--[[
	The Machines records that changed since they were last sent (each replaces what clients know of
	its position). A machine whose record went less than RECORD_INTERVAL ticks ago waits.
]]
function MachineWorld.takeRecords(world: World): { MachineRecord }
	local records: { MachineRecord } = {}
	for key in world.dirtyRecords do
		local machine = world.machines[key]
		if machine == nil then
			world.dirtyRecords[key] = nil
		elseif world.tick - machine.sentAt >= MachineWorld.RECORD_INTERVAL then
			world.dirtyRecords[key] = nil
			local record = MachineWorld.record(machine)
			if not sameRecord(record, machine.sent) then
				machine.sent, machine.sentAt = record, world.tick
				table.insert(records, record)
			end
		end
	end
	return records
end

-- The records of chunk (cx, cz)'s machines that are not in the default state (sent with its edit
-- list).
function MachineWorld.chunkRecords(world: World, cx: number, cz: number): { MachineRecord }
	local records: { MachineRecord } = {}
	local keys = world.byChunk[Coords.chunkKey(cx, cz)]
	if keys then
		for key in keys do
			local machine = world.machines[key]
			if machine then
				local record = MachineWorld.record(machine)
				if not sameRecord(record, defaultRecord(machine)) then
					table.insert(records, record)
				end
			end
		end
	end
	return records
end

return MachineWorld
