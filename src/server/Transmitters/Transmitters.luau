--!strict
--[[
	Mekanism's pipes in the game: runs Transmitters/TransmitterWorld (the pure simulation) at 20
	ticks a second (`update`, every frame from the server script after the world's edits went out:
	a fixed step that catches up at most a few ticks per frame) and replicates it.

	  World     the server script chains `blockChanged` onto WorldServer.onChanged, so every
	            transmitter and tank placed or broken (by players, block updates or the Api) and
	            every chest or furnace next to one comes through. Blocks are read with peekBlock,
	            falling back to a chunk's edit list where the server has not generated it:
	            transmitters, tanks, chests and furnaces only ever come from edits, so networks
	            and the items in them keep working wherever no player is (like furnaces cooking
	            unwatched), and terrain is never generated for them.
	  Inventory chests and furnaces are Players/Containers' (the same tables their viewers' windows
	            hold); Players/Inventories.containerChanged sends viewers a snapshot and wakes a
	            furnace after a transporter put something in or took something out.
	  Drops     a broken transporter's items drop where it was (Entities.dropBlock).
	  Tanks     a Fluid Tank broken by a survival player keeps its fluid in its item, and placing
	            that item puts it back (TransmitterWorld.blockDataHooks, registered with
	            ServerNet's `addBlockData`: Mekanism's sustained data).
	  Records   Transmitters (side modes, colour, pipe fill and fluid id) and Tanks records: a chunk's
	            non-default ones go to a player right after its edit list (ServerNet's
	            `chunksSent` rule calls `sendChunks`), and changes go once per frame to every
	            player within RECORD_RANGE blocks (sideways) of them, which covers the chunks a
	            client keeps in full detail (players without a character yet get them all; none
	            with the server's own positions, Config.Players.ServerPositions, whose chunk edit
	            lists, and the records sent with them, wait for the player to come near). Feet
	            are Players/PlayerPositions'.
	  Transport items in transporters are tracked per player within TRACK_RANGE blocks of their
	            feet, like dropped items: an add when one appears, is re-routed or changes speed,
	            a remove when it leaves; every SCAN_INTERVAL ticks, items coming into range are
	            sent with their current state and those beyond UNTRACK_RANGE removed. An add's
	            startTime is workspace:GetServerTimeNow() of the tick that produced it.

	Nothing is saved: transmitter states, network fluids, tank contents and items in transit last
	for the session, like chests.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local ChunkLayout = require(Shared.World.ChunkLayout)
local Config = require(Shared.Config)
local Coords = require(Shared.World.Coords)
local Protocol = require(Shared.Net.Protocol)
local SharedTransmitters = require(Shared.Transmitters)

local WorldServer = require(script.Parent.Parent.World.WorldServer)
local EditRules = require(script.Parent.Parent.Network.EditRules)
local Containers = require(script.Parent.Parent.Players.Containers)
local Entities = require(script.Parent.Parent.Entities.Entities)
local Inventories = require(script.Parent.Parent.Players.Inventories)
local PlayerPositions = require(script.Parent.Parent.Players.PlayerPositions)
local TransmitterWorld = require(script.Parent.TransmitterWorld)

type TransportOp = Protocol.TransportOp
type TransmitterRecord = Protocol.TransmitterRecord
type TankRecord = Protocol.TankRecord

-- Only what this uses of ServerNet.ServerNet.
type Net = {
	send: (player: Player, kind: number, payload: buffer) -> (),
	addBlockData: (hooks: EditRules.BlockDataHooks) -> (),
}

local HEIGHT = Config.WorldHeight
local TICK = 1 / SharedTransmitters.TICK_RATE
-- Ticks run at most per frame (a long hitch does not fast-forward the pipes).
local MAX_TICKS_PER_FRAME = 4
-- Blocks around a player's feet: items in transporters they see, and where they are forgotten.
local TRACK_RANGE = 64
local UNTRACK_RANGE = 72
-- Blocks sideways around a player's feet whose transmitter and tank changes they get.
local RECORD_RANGE = 192
-- Ticks between checks for items coming into and going out of players' range.
local SCAN_INTERVAL = 10
-- Positions players may report (blocks); anything else is ignored.
local LIMIT = Protocol.MAX_COORDINATE + 64

local Transmitters = {}

local state: TransmitterWorld.World? = nil
-- Per player: the items their client knows, and their last sane feet position (blocks).
local tracked: { [Player]: { [number]: boolean } } = {}
local lastFeet: { [Player]: { number } } = {}

-- The simulation (nil before `start`): Players/ItemUse configures transmitters and fills tanks.
function Transmitters.world(): TransmitterWorld.World?
	return state
end

-- For WorldServer.onChanged: block (x, y, z) changed from `old` to `new`.
function Transmitters.blockChanged(x: number, y: number, z: number, old: number, new: number)
	local world = state
	if world then
		TransmitterWorld.blockChanged(world, x, y, z, old, new)
	end
end

-- The player's feet (Players/PlayerPositions, blocks), else where they were last seen; nil, 0, 0
-- when never.
local function feetOf(player: Player): (number?, number, number)
	local x, y, z = PlayerPositions.feet(player)
	local last = lastFeet[player]
	if x and math.abs(x) <= LIMIT and math.abs(z) <= LIMIT then
		if last == nil then
			lastFeet[player] = { x, y, z }
		else
			last[1], last[2], last[3] = x, y, z
		end
		return x, y, z
	elseif last then
		return last[1], last[2], last[3]
	end
	return nil, 0, 0
end

local function send(net: Net, player: Player, records: { TransmitterRecord }, tanks: { TankRecord })
	if #records > 0 then
		net.send(player, Protocol.ServerMessage.Transmitters, Protocol.encodeTransmitters(records))
	end
	if #tanks > 0 then
		net.send(player, Protocol.ServerMessage.Tanks, Protocol.encodeTanks(tanks))
	end
end

local started = false
local net: Net? = nil

--[[
	ServerNet's `chunksSent` rule: the player was just sent the edit lists of chunks `coords`, so
	send the records of the transmitters and tanks there that are not in the default state.
]]
function Transmitters.sendChunks(player: Player, coords: { { number } })
	local world, sender = state, net
	if world == nil or sender == nil then
		return
	end
	local records: { TransmitterRecord } = {}
	local tanks: { TankRecord } = {}
	for _, coord in coords do
		local chunkRecords, chunkTanks = TransmitterWorld.chunkRecords(world, coord[1], coord[2])
		table.move(chunkRecords, 1, #chunkRecords, #records + 1, records)
		table.move(chunkTanks, 1, #chunkTanks, #tanks + 1, tanks)
	end
	send(sender, player, records, tanks)
end

-- Changed records to every player near them.
local function sendRecords(sender: Net, records: { TransmitterRecord }, tanks: { TankRecord })
	if #records == 0 and #tanks == 0 then
		return
	end
	local everything = not PlayerPositions.networked()
	for _, player in Players:GetPlayers() do
		local px, _, pz = feetOf(player)
		if px == nil then
			-- (Never seen in the world yet, while its client already streams the chunks around
			-- the spawn point: it gets every change, and its client keeps those of the chunks it
			-- asked for. Range alone would leave those chunks' records stale. With the server's
			-- own positions those chunks' lists wait for the player, records and all: nothing.)
			if everything then
				send(sender, player, records, tanks)
			end
		else
			local near: { TransmitterRecord } = {}
			for _, record in records do
				if math.abs(record.x + 0.5 - px) <= RECORD_RANGE and math.abs(record.z + 0.5 - pz) <= RECORD_RANGE then
					table.insert(near, record)
				end
			end
			local nearTanks: { TankRecord } = {}
			for _, tank in tanks do
				if math.abs(tank.x + 0.5 - px) <= RECORD_RANGE and math.abs(tank.z + 0.5 - pz) <= RECORD_RANGE then
					table.insert(nearTanks, tank)
				end
			end
			send(sender, player, near, nearTanks)
		end
	end
end

local function within(x: number, y: number, z: number, fx: number, fy: number, fz: number, range: number): boolean
	local dx, dy, dz = x + 0.5 - fx, y + 0.5 - fy, z + 0.5 - fz
	return dx * dx + dy * dy + dz * dz <= range * range
end

--[[
	The frame's Transport ops to the players who see them, and (`scan`) items coming into and
	going out of each player's range; `lastTick` is the server time of the last tick (the state
	new watchers get is that tick's).
]]
local function sendTransport(
	sender: Net,
	world: TransmitterWorld.World,
	ops: { TransportOp },
	scan: boolean,
	lastTick: number
)
	for _, player in Players:GetPlayers() do
		local known = tracked[player]
		if known == nil then
			known = {}
			tracked[player] = known
		end
		local fx, fy, fz = feetOf(player)
		local out: { TransportOp } = {}
		for _, op in ops do
			if op.op == "add" then
				if known[op.id] or (fx and within(op.x, op.y, op.z, fx, fy, fz, TRACK_RANGE)) then
					known[op.id] = true
					table.insert(out, op)
				end
			elseif known[op.id] then
				known[op.id] = nil
				table.insert(out, op)
			end
		end
		if scan then
			for id in known do
				local item = world.items[id]
				local gone = item == nil
				if item and fx then
					local x, y, z = TransmitterWorld.itemPosition(item)
					gone = not within(x, y, z, fx, fy, fz, UNTRACK_RANGE)
				end
				if gone then
					known[id] = nil
					table.insert(out, { op = "remove", id = id, reason = Protocol.TransportRemoveReason.Gone })
				end
			end
			if fx then
				for id, item in world.items do
					if not known[id] then
						local x, y, z = TransmitterWorld.itemPosition(item)
						if within(x, y, z, fx, fy, fz, TRACK_RANGE) then
							local op = TransmitterWorld.itemOp(world, item)
							if op.op == "add" then
								op.startTime = lastTick
							end
							known[id] = true
							table.insert(out, op)
						end
					end
				end
			end
		end
		if #out > 0 then
			sender.send(player, Protocol.ServerMessage.Transport, Protocol.encodeTransport(out))
		end
	end
end

--[[
	Starts the pipes: the simulation and its replication (`update` runs them). Entities and
	Players/Inventories must have started (drops, chests and furnaces).
]]
function Transmitters.start(serverNet: Net, world: WorldServer.World)
	assert(not started, "Transmitters.start was already called")
	started = true
	net = serverNet

	-- Blocks without generating terrain: the edit list knows every transmitter, tank, chest and
	-- furnace of a chunk the server has not generated (nil: generated terrain, none of those).
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

	local simulation = TransmitterWorld.new({
		getBlock = knownBlock,
		containers = Containers.default,
		inventoryChanged = Inventories.containerChanged,
		resultsTaken = Inventories.resultsTaken,
		drop = Entities.dropBlock,
	})
	state = simulation
	-- A tank's fluid stays in its item (Mekanism's sustained data).
	serverNet.addBlockData(TransmitterWorld.blockDataHooks(simulation))

	Players.PlayerRemoving:Connect(function(player)
		tracked[player] = nil
		lastFeet[player] = nil
	end)
end

local accumulator = 0
local ticks = 0
local lastTick = 0

--[[
	Runs the pipes' ticks due after `dt` seconds and replicates them. The server script calls it
	every frame (Heartbeat) right after ServerNet's flush, so the frame's world edits reach clients
	before the state of the transmitters they made.
]]
function Transmitters.update(dt: number)
	local simulation, sender = state, net
	if simulation == nil or sender == nil then
		return
	end
	accumulator = math.min(accumulator + dt, TICK * MAX_TICKS_PER_FRAME)
	local now = Workspace:GetServerTimeNow()
	local ops: { TransportOp } = {}
	local scan = false
	local function collect()
		for _, op in TransmitterWorld.takeTransport(simulation) do
			if op.op == "add" then
				op.startTime = lastTick
			end
			table.insert(ops, op)
		end
	end
	-- (Items dropped by blocks broken since the last frame.)
	collect()
	while accumulator >= TICK do
		accumulator -= TICK
		-- (The moment this tick's state belongs to: ticks run late, within the frame.)
		lastTick = now - accumulator
		TransmitterWorld.step(simulation)
		ticks += 1
		scan = scan or ticks % SCAN_INTERVAL == 0
		collect()
	end
	if #ops > 0 or scan then
		sendTransport(sender, simulation, ops, scan, lastTick)
	end
	local records, tanks = TransmitterWorld.takeRecords(simulation)
	sendRecords(sender, records, tanks)
end

return Transmitters
