--!strict
--[[
	The shapes the server's machines share (Machines/MachineWorld, EnergyNet), in a module of
	their own so those can type each other without requiring each other.

	  Machine    one Mekanism machine (Shared/Machines) at a block position: its kind and energy
	             spec, its container (the same table Players/Containers keeps and its viewers'
	             windows hold), its energy network, and what its last Machines record said
	  Component  an energy network: the Universal Cables and machines joined by cables or by
	             touching each other, the machines in key order and the cables' throughput
	  World      the whole state (MachineWorld.new); Env is what it needs from the game

	Positions are Shared/World/Coords pos keys (server Transmitters/Grid).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Machines = require(Shared.Machines)
local Protocol = require(Shared.Net.Protocol)
local InventoryTypes = require(Shared.Inventory.Types)

local Containers = require(script.Parent.Parent.Players.Containers)
local TransmitterTypes = require(script.Parent.Parent.Transmitters.Types)

export type Container = InventoryTypes.Container
export type MachineRecord = Protocol.MachineRecord
export type MachineTank = Protocol.MachineTank

export type Machine = {
	key: number,
	x: number,
	y: number,
	z: number,
	block: number,
	kind: Machines.Kind,
	energy: Machines.EnergySpec,
	role: Machines.Role?,
	container: Container,
	-- The energy network it belongs to (nil while the networks around it are worked out again).
	component: Component?,
	-- Its data as it was after the last step, and its slot stacks before this tick (to tell
	-- viewers what changed: pipes and buckets change tanks between steps).
	previous: { number },
	previousSlots: { [number]: any },
	-- The record clients last got (a new machine's is the default one) and the tick it went.
	sent: MachineRecord,
	sentAt: number,
}

export type Component = {
	id: number,
	-- Every member: cables and machines.
	keys: { number },
	-- The machines, by pos key (the even split's order).
	machines: { Machine },
	cables: number,
	-- J per tick it moves at most: its cables' capacities summed, math.huge without cables.
	throughput: number,
}

export type Env = {
	-- The block at (x, y, z), nil when the server does not know it. Never generates terrain.
	getBlock: (x: number, y: number, z: number) -> number?,
	-- Where machines keep their contents (Players/Containers).
	containers: Containers.Store,
	-- The slots of the chest at (x, y, z) changed (a machine pushed its results into it: its
	-- viewers need a snapshot).
	inventoryChanged: ((x: number, y: number, z: number) -> ())?,
	-- The Universal Cables (Transmitters/TransmitterWorld's energy nodes), if any.
	transmitters: TransmitterTypes.World?,
	-- Minecraft's day time now (ticks 0..24000), for kinds that care (solar panels).
	dayTime: (() -> number)?,
	-- Does cell (x, y, z) see the sky straight up (Machines/SkyCheck over the server's world)?
	-- Uncached; never generates terrain. nil: the cells above are read with `getBlock`.
	sky: ((x: number, y: number, z: number) -> boolean)?,
	-- Results left a furnace's or machine's output at (x, y, z) on their own (pushed out, or
	-- pulled by a pipe): Players/Inventories.resultsTaken credits them as smelted to the
	-- player who last used its window (Progression), as if taken out by hand.
	resultsTaken: ((x: number, y: number, z: number, container: Container, stack: InventoryTypes.Stack) -> ())?,
}

export type World = {
	env: Env,
	-- Simulation ticks run so far.
	tick: number,
	machines: { [number]: Machine },
	count: number,
	-- Pos keys of the machines in each chunk (Coords.chunkKey).
	byChunk: { [number]: { [number]: boolean } },
	components: { [Component]: boolean },
	componentOf: { [number]: Component },
	nextComponent: number,
	-- Positions whose energy links may have changed (machines that came or went), the queue of
	-- positions to flood fill into networks again (a set marks the live entries), and the fill
	-- in progress, carried over between ticks.
	dirty: { [number]: boolean },
	seeds: { number },
	seedSet: { [number]: boolean },
	job: { visited: { [number]: boolean }, frontier: { number }, members: { number } }?,
	-- Machines whose slots / data changed in the last tick (for their viewers' snapshots).
	slotsChanged: { [number]: Machine },
	dataChanged: { [number]: Machine },
	-- Machines whose record may have changed.
	dirtyRecords: { [number]: boolean },
	-- J moved through energy networks in the last tick (statistics).
	moved: number,
	-- Kinds whose tick failed (reported once each).
	failed: { [string]: boolean },
	-- Whether cells see the sky (TickContext `sky`), by column (the pos key of (x, 0, z)) and y,
	-- and how many cells that is; an answer goes when a block above its cell changes.
	sky: { [number]: { [number]: boolean } },
	skyCells: number,
	-- The tick context lent to kinds (one table, refilled per machine).
	ctx: Machines.TickContext,
}

-- (Types only; a module must still return something.)
return table.freeze({})
