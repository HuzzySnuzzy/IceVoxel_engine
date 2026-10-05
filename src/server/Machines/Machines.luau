--!strict
--[[
	Mekanism's machines in the game: runs Machines/MachineWorld (the pure simulation: machine
	ticks, energy networks, sustained data) at 20 ticks a second (`update`, every frame from the
	server script after the pipes: a fixed step that catches up at most a few ticks per frame) and
	replicates it.

	  World     the server script chains `blockChanged` onto WorldServer.onChanged after
	            Players/Inventories (which drops a broken machine's slots and closes its window)
	            and Transmitters (which relinks the Universal Cables around it), so every machine
	            placed or broken (by players, block updates or the Api) comes through. Blocks are
	            read with peekBlock, falling back to a chunk's edit list, as the pipes do: machines
	            and cables only come from edits, so they keep working wherever no player is.
	  Cables    are Transmitters/TransmitterWorld's nodes (side modes, the Configurator, records);
	            MachineWorld reads them for its energy networks.
	  Sun       solar panels run on the server's clock (World/TimeOfDay) and ask whether they see
	            the sky (Machines/SkyCheck: the loaded chunk, else the edits over the generator's
	            ground height, never generating terrain; MachineWorld caches the answers and drops
	            them when a block above changes).
	  Energy    a machine broken by a survival player keeps its energy in its item, and placing
	            that item puts it back (MachineWorld.blockDataHooks, registered with ServerNet's
	            `addBlockData`: Mekanism's sustained data).
	  Viewers   players with a machine's window open get a snapshot (Players/Inventories) at once
	            when its slots change, and every DATA_INTERVAL ticks while only its data (energy,
	            gauges) moves, like furnaces; a chest a machine pushed its results into
	            (Transmitters/Eject) gets them through Inventories.containerChanged.
	  Records   Machines records (energy, capacity, the network's input and output, the machine's
	            rate, active, its kind's state code) for WAILA and the world: a chunk's non-default
	            ones go to a player right after its edit list (`sendChunks`, from ServerNet's
	            `chunksSent` rule) and changes, at most 4 a second per machine, to every player
	            within RECORD_RANGE blocks (sideways), as Tanks records do.

	Nothing is saved: machines' energy and contents last for the session, like chests.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local ChunkLayout = require(Shared.World.ChunkLayout)
local Config = require(Shared.Config)
local Coords = require(Shared.World.Coords)
local Protocol = require(Shared.Net.Protocol)
local Rig = require(Shared.Movement.Rig)

local WorldServer = require(script.Parent.Parent.World.WorldServer)
local EditRules = require(script.Parent.Parent.Network.EditRules)
local Containers = require(script.Parent.Parent.Players.Containers)
local Inventories = require(script.Parent.Parent.Players.Inventories)
local Transmitters = require(script.Parent.Parent.Transmitters.Transmitters)
local TimeOfDay = require(script.Parent.Parent.World.TimeOfDay)
local MachineWorld = require(script.Parent.MachineWorld)
local SkyCheck = require(script.Parent.SkyCheck)

type MachineRecord = Protocol.MachineRecord

-- Only what this uses of ServerNet.ServerNet.
type Net = {
	send: (player: Player, kind: number, payload: buffer) -> (),
	addBlockData: (hooks: EditRules.BlockDataHooks) -> (),
}

local HEIGHT = Config.WorldHeight
local TICK = 1 / 20
-- Ticks run at most per frame (a long hitch does not fast-forward the machines).
local MAX_TICKS_PER_FRAME = 4
-- Ticks between viewers' snapshots while only a machine's data changes (a furnace's pace).
local DATA_INTERVAL = 2
-- Blocks sideways around a player's feet whose machine changes they get.
local RECORD_RANGE = 192
-- Positions players may report (blocks); anything else is ignored.
local LIMIT = Protocol.MAX_COORDINATE + 64

local Machines = {}

local state: MachineWorld.World? = nil
local net: Net? = nil
local started = false
local lastFeet: { [Player]: Vector3 } = {}

-- The simulation (nil before `start`).
function Machines.world(): MachineWorld.World?
	return state
end

-- For WorldServer.onChanged: block (x, y, z) changed from `old` to `new`.
function Machines.blockChanged(x: number, y: number, z: number, old: number, new: number)
	local world = state
	if world then
		MachineWorld.blockChanged(world, x, y, z, old, new)
	end
end

local function feetOf(player: Player): Vector3?
	local character = player.Character
	local feet = if character then Rig.feet(character) else nil
	if feet and feet.X == feet.X and feet.Z == feet.Z and math.abs(feet.X) <= LIMIT and math.abs(feet.Z) <= LIMIT then
		lastFeet[player] = feet
		return feet
	end
	return lastFeet[player]
end

local function send(sender: Net, player: Player, records: { MachineRecord })
	if #records > 0 then
		sender.send(player, Protocol.ServerMessage.Machines, Protocol.encodeMachines(records))
	end
end

--[[
	ServerNet's `chunksSent` rule (with the pipes'): the player was just sent the edit lists of
	chunks `coords`, so send the records of the machines there that are not in the default state.
]]
function Machines.sendChunks(player: Player, coords: { { number } })
	local world, sender = state, net
	if world == nil or sender == nil then
		return
	end
	local records: { MachineRecord } = {}
	for _, coord in coords do
		local chunk = MachineWorld.chunkRecords(world, coord[1], coord[2])
		table.move(chunk, 1, #chunk, #records + 1, records)
	end
	send(sender, player, records)
end

-- Changed records to every player near them (every one to players not seen in the world yet).
local function sendRecords(sender: Net, records: { MachineRecord })
	if #records == 0 then
		return
	end
	for _, player in Players:GetPlayers() do
		local feet = feetOf(player)
		if feet == nil then
			send(sender, player, records)
		else
			local near: { MachineRecord } = {}
			for _, record in records do
				if
					math.abs(record.x + 0.5 - feet.X) <= RECORD_RANGE
					and math.abs(record.z + 0.5 - feet.Z) <= RECORD_RANGE
				then
					table.insert(near, record)
				end
			end
			send(sender, player, near)
		end
	end
end

--[[
	Starts the machines: the simulation, its sustained data hooks and replication (`update` runs
	them). Players/Inventories and Transmitters must have started (containers, cables).
]]
function Machines.start(serverNet: Net, world: WorldServer.World)
	assert(not started, "Machines.start was already called")
	started = true
	net = serverNet

	-- Blocks without generating terrain: the edit list knows every machine and cable of a chunk
	-- the server has not generated (nil: generated terrain, none of those).
	local function knownBlock(x: number, y: number, z: number): number?
		local block = world:peekBlock(x, y, z)
		if block ~= nil then
			return block
		elseif y < 0 or y >= HEIGHT then
			return nil
		end
		local cx, cz, lx, lz = Coords.blockToChunk(x, z)
		local edits = world:chunkEdits(cx, cz)
		return if edits then edits[ChunkLayout.localIndex(lx, y, lz)] else nil
	end

	-- Whether a cell sees the sky (solar panels): the chunk if the server has it, else its edits
	-- over the generator's ground height; MachineWorld caches it.
	local function seesSky(x: number, y: number, z: number): boolean
		return SkyCheck.open(world, x, y, z)
	end

	local simulation = MachineWorld.new({
		getBlock = knownBlock,
		containers = Containers.default,
		inventoryChanged = Inventories.containerChanged,
		transmitters = Transmitters.world(),
		dayTime = TimeOfDay.get,
		sky = seesSky,
	})
	state = simulation
	-- A machine's energy stays in its item (Mekanism's sustained data).
	serverNet.addBlockData(MachineWorld.blockDataHooks(simulation))

	Players.PlayerRemoving:Connect(function(player)
		lastFeet[player] = nil
	end)
end

local accumulator = 0
local ticks = 0
-- Containers of machines whose data changed since viewers last got a snapshot.
local pendingData: { [any]: boolean } = {}

-- Snapshots for the players whose open window is one of `containers`.
local function markViewers(containers: { [any]: boolean })
	if next(containers) == nil then
		return
	end
	for _, player in Players:GetPlayers() do
		local window = Inventories.get(player)
		local container = window and window.container
		if container and containers[container] then
			Inventories.markDirty(player)
		end
	end
end

--[[
	Runs the machines' ticks due after `dt` seconds and replicates them. The server script calls it
	every frame (Heartbeat) right after the pipes, so a client knows a machine's block before its
	state.
]]
function Machines.update(dt: number)
	local simulation, sender = state, net
	if simulation == nil or sender == nil then
		return
	end
	accumulator = math.min(accumulator + dt, TICK * MAX_TICKS_PER_FRAME)
	local slotsNow: { [any]: boolean } = {}
	while accumulator >= TICK do
		accumulator -= TICK
		MachineWorld.step(simulation)
		ticks += 1
		local slots, data = MachineWorld.takeChanges(simulation)
		for _, machine in slots do
			slotsNow[machine.container] = true
			pendingData[machine.container] = nil
		end
		for _, machine in data do
			if not slotsNow[machine.container] then
				pendingData[machine.container] = true
			end
		end
		if ticks % DATA_INTERVAL == 0 then
			for container in pendingData do
				slotsNow[container] = true
			end
			table.clear(pendingData)
		end
	end
	markViewers(slotsNow)
	sendRecords(sender, MachineWorld.takeRecords(simulation))
end

return Machines
