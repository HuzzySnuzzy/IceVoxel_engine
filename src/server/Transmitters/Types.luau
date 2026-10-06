--!strict
--[[
	The shapes the server's Mekanism pipes share (Transmitters/TransmitterWorld, Transport, Fluids),
	in a module of their own so those can type each other without requiring each other.

	  Node     one transmitter (a Logistical Transporter, the Restrictive Transporter, a
	           Mechanical Pipe or a Universal Cable) at a block position: its side modes and
	           colour, which of its sides join other transmitters (`links`) and acceptors
	           (`acceptors`), a pipe's network, a transporter's pull timer, and what its last
	           Transmitters record said
	  Network  the pipes joined into one (a connected component): their shared fluid buffer
	  Tank     a Fluid Tank's contents
	  Item     a stack travelling through transporters: where it is, its route and why
	  World    the whole state (TransmitterWorld.new); Env is what it needs from the game

	Positions are Shared/World/Coords pos keys; sides are Shared/Transmitters' (0 Down .. 5 East).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Items = require(Shared.Items)
local Protocol = require(Shared.Net.Protocol)

local Containers = require(script.Parent.Parent.Players.Containers)

export type Stack = Items.Stack
export type Kind = "item" | "fluid" | "energy"

export type Network = {
	id: number,
	nodes: { [number]: Node },
	size: number,
	-- mB: the sum of the member pipes' capacities.
	capacity: number,
	-- The fluid in the buffer (Shared/Fluids id: 0 none, 1 water, 2 lava, 3 oil, 4 fuel; one at a
	-- time) and mB of it.
	fluid: number,
	amount: number,
	-- Members with at least one side joined to an acceptor (a Fluid Tank, a machine with tanks).
	ports: { [number]: Node },
	-- The fill byte and fluid id last given to the members' records (-1: check now), and the tick
	-- of that check (fills are sent at most every FILL_INTERVAL ticks).
	sentFill: number,
	sentFluid: number,
	checkedAt: number,
	-- Whether it leads each fluid somewhere (Transmitters/Fluids: the machines' ejector asks),
	-- worked out once in the tick `leadsTick`.
	leads: { [number]: boolean },
	leadsTick: number,
}

export type Node = {
	key: number,
	x: number,
	y: number,
	z: number,
	block: number,
	kind: Kind,
	-- Packed side modes (Transmitters.packModes) and colour (0 none, 1..16).
	modes: number,
	colour: number,
	-- Bit `side` set: that side joins a transmitter / an acceptor (Transmitters.connections).
	links: number,
	acceptors: number,
	-- Mechanical pipes: the network they belong to (always one, a lone pipe's own).
	network: Network?,
	-- Transporters: ticks until the PULL sides pull again (and the NORMAL sides take what
	-- furnaces and machines push out), and failed pulls in a row (backoff).
	pullDelay: number,
	pullFailures: number,
	-- The record clients last got (a new transmitter is in the default state: 0, 0, 0, 0): modes,
	-- colour, a pipe's fill byte and its fluid id.
	sentModes: number,
	sentColour: number,
	sentFluid: number,
	sentFluidId: number,
}

export type Tank = {
	key: number,
	x: number,
	y: number,
	z: number,
	block: number,
	capacity: number,
	fluid: number,
	amount: number,
	-- The record clients last got, and the tick it was sent (at most every FILL_INTERVAL ticks).
	sentFluid: number,
	sentAmount: number,
	sentAt: number,
}

export type Item = {
	id: number,
	stack: Stack,
	-- The colour of the transporter that pulled it (0 none): it only enters transporters that
	-- carry it (Transmitters.carries).
	colour: number,
	-- Pos keys from where it started to where it goes: transporters, then the inventory last
	-- (for a destination or home). `hop` is the index of the transporter it is in.
	route: { number },
	hop: number,
	-- "dest" (an inventory that takes it), "home" (back where it came from) or nil: waiting in
	-- place for somewhere to go (route is then just its transporter).
	target: ("dest" | "home")?,
	-- The inventory's side it enters by (opposite of the route's last step).
	face: number,
	-- 0..100 through the transporter it is in (Transmitters.BLOCK_PROGRESS).
	progress: number,
	-- Waiting: ticks until it looks for a way again.
	wait: number,
	-- The inventory it was taken from (pos key), never a destination for it, and the one it may
	-- go back to when no destination takes it: the same, but nil for a furnace's or machine's
	-- results, which never go back in.
	from: number?,
	home: number?,
	-- The hop and speed of the last Transport add sent for it (a long route is sent again on the
	-- way, and a change of speed is sent).
	sentHop: number,
	sentSpeed: number,
}

export type Env = {
	-- The block at (x, y, z), nil when the server does not know it. Never generates terrain.
	getBlock: (x: number, y: number, z: number) -> number?,
	-- Chests, furnaces and machines (Players/Containers): pipes reach a machine's fluid tanks
	-- through its container.
	containers: Containers.Store,
	-- The slots of the inventory at (x, y, z) changed (its viewers need a snapshot, a furnace may
	-- cook).
	inventoryChanged: ((x: number, y: number, z: number) -> ())?,
	-- Drops a stack as an item entity at block (x, y, z) (a broken transporter's items).
	drop: ((x: number, y: number, z: number, stack: Stack) -> ())?,
}

export type TransportOp = Protocol.TransportOp
export type TransmitterRecord = Protocol.TransmitterRecord
export type TankRecord = Protocol.TankRecord

export type World = {
	env: Env,
	-- Simulation ticks run so far.
	tick: number,
	nodes: { [number]: Node },
	tanks: { [number]: Tank },
	networks: { [Network]: boolean },
	nextNetwork: number,
	-- Pos keys of the transmitters and tanks in each chunk (Coords.chunkKey).
	byChunk: { [number]: { [number]: boolean } },
	-- Pipes whose network has to be worked out again (a queue with a set marking the live
	-- entries), and the flood fill in progress, carried over between ticks (with the fluid its
	-- pipes hold so far: 0 none; a pipe holding another stays out).
	seeds: { number },
	seedSet: { [number]: boolean },
	job: { visited: { [number]: boolean }, frontier: { number }, members: { Node }, fluid: number }?,
	-- Transporters with a PULL side on an inventory, or a NORMAL side on a furnace or machine
	-- that pushes its results out (Transmitters.ejects).
	pullers: { [number]: Node },
	items: { [number]: Item },
	itemCount: number,
	nextItem: number,
	-- Items on their way to each inventory (pos key), to predict what it will hold.
	incoming: { [number]: { [number]: Item } },
	-- Transporters the tick's route searches may still visit before waiting items and pulls stop
	-- looking (Transmitters/Transport.SEARCH_BUDGET a tick).
	searchBudget: number,
	-- Transport ops since the last takeTransport (adds carry startTime 0: the caller sets it).
	ops: { TransportOp },
	-- Transmitters and tanks whose record may have changed.
	dirtyNodes: { [number]: boolean },
	dirtyTanks: { [number]: boolean },
	-- Universal Cables that came, went or joined something new: the energy networks
	-- (server/Machines/EnergyNet) work out their part again and clear this.
	energyDirty: { [number]: boolean },
	-- mB of fluid lost with broken pipes and tanks (for conservation checks).
	lost: number,
}

-- (Types only; a module must still return something.)
return table.freeze({})
