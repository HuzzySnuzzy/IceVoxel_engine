--!strict
--[[
	Turrets in the game (Shared/Turrets): runs Turrets/TurretWorld, the pure simulation, as the
	service every turret's machine tick asks, and replicates it.

	  Service   `start` builds the simulation over the game and hands its `step` to the machines
	            (Machines.setTurretService; server Machines never requires this:
	            Players/ToughAsNails requires Machines, Mobs requires ToughAsNails). Its Env:
	              getBlock  Machines.knownBlock (the loaded chunk, else its edit list; never
	                        generating terrain)
	              hostiles  Mobs.hostiles (the live, unfrozen monsters: never players or
	                        animals), mob Mobs.target (into one reused table)
	              hurt      Mobs.weaponDamage with no player: nobody is credited (no Knowledge,
	                        no survivor kill count, no `byPlayer` loot), as Minecraft's iron
	                        golem kills; a player's hit within 100 ticks still claims the kill
	              noise     Apocalypse/NoiseBus.emit (the director's night, rain and snow
	                        factors apply as to any noise)
	              lureTime  night (not DayCycle.isDay of World/TimeOfDay) or a blood moon
	                        (Apocalypse/BloodMoon.active, with the apocalypse on)
	              feed      the feeder rule: Transmitters/TransmitterWorld.feedTier of the
	                        pipes' world at the turret (the simulation asks every FeedTicks)
	              random    the server's Random; settings Config.Turrets and Config.Weapons
	            The server script starts it after Weapons/.
	  World     the server script chains `blockChanged` onto WorldServer.onChanged after
	            Machines/Machines, so a turret broken or replaced is forgotten.
	  Records   Turrets records (Net/Protocol, message Turrets): a chunk's non-default ones right
	            after its edit list (`sendChunks`, from ServerNet's `chunksSent` rule after the
	            machines'), changes to players within Config.Turrets.RecordRange sideways of their
	            feet (`update`, every frame right after Machines.update; every change to a player
	            not in the world yet unless positions are the server's own, as Machines records).
	  Shots     each frame's turret shots (Net/WeaponSync records: shooter 0, the stand-in gun,
	            the turret's counter, from its muzzle, `suppressed` and `plain`) as Shots messages,
	            at most WeaponSync.MAX_SHOTS each, to every player within
	            Config.Weapons.ShotBroadcast blocks sideways of each shot's origin: the glue's own
	            audience (FireRules.audience puts a shooter first; a turret has none).
	With Config.Turrets.Enabled false nothing starts: no simulation, no service (turrets show
	"Disabled"), no messages.

	The API (frozen): start(net, world), update(dt), blockChanged(x, y, z, old, new),
	sendChunks(player, coords), world().
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local DayCycle = require(Shared.DayCycle)
local BloodMoon = require(Shared.Apocalypse.BloodMoon)
local Protocol = require(Shared.Net.Protocol)
local WeaponSync = require(Shared.Net.WeaponSync)
local TurretTypes = require(Shared.Turrets.Types)

local WorldServer = require(script.Parent.Parent.World.WorldServer)
local TimeOfDay = require(script.Parent.Parent.World.TimeOfDay)
local Machines = require(script.Parent.Parent.Machines.Machines)
local Transmitters = require(script.Parent.Parent.Transmitters.Transmitters)
local TransmitterWorld = require(script.Parent.Parent.Transmitters.TransmitterWorld)
local PlayerPositions = require(script.Parent.Parent.Players.PlayerPositions)
local Mobs = require(script.Parent.Parent.Mobs.Mobs)
local NoiseBus = require(script.Parent.Parent.Apocalypse.NoiseBus)
local TurretWorld = require(script.Parent.TurretWorld)

-- Only what this uses of ServerNet.ServerNet.
type Net = {
	send: (player: Player, kind: number, payload: buffer) -> (),
}

local Turrets = {}

local state: TurretWorld.World? = nil
local net: Net? = nil
local started = false
-- (Each frame's lists for one player, reused.)
local nearShots: { WeaponSync.Shot } = {}
local nearRecords: { Protocol.TurretRecord } = {}

-- The simulation (nil before `start`, and with the turrets off).
function Turrets.world(): TurretWorld.World?
	return state
end

-- For WorldServer.onChanged: block (x, y, z) changed from `old` to `new`.
function Turrets.blockChanged(x: number, y: number, z: number, old: number, new: number)
	local world = state
	if world then
		TurretWorld.blockChanged(world, x, y, z, old, new)
	end
end

local function sendRecords(sender: Net, player: Player, records: { Protocol.TurretRecord })
	if #records > 0 then
		sender.send(player, Protocol.ServerMessage.Turrets, Protocol.encodeTurrets(records))
	end
end

-- `shots` to `player`: one Shots message, more past WeaponSync.MAX_SHOTS.
local function sendShots(sender: Net, player: Player, shots: { WeaponSync.Shot })
	local most = WeaponSync.MAX_SHOTS
	if #shots == 0 then
		return
	elseif #shots <= most then
		sender.send(player, Protocol.ServerMessage.Shots, WeaponSync.encodeShots(shots))
		return
	end
	for first = 1, #shots, most do
		sender.send(
			player,
			Protocol.ServerMessage.Shots,
			WeaponSync.encodeShots(table.move(shots, first, math.min(first + most - 1, #shots), 1, {}))
		)
	end
end

--[[
	ServerNet's `chunksSent` rule (with the pipes' and the machines'): the player was just sent the
	edit lists of chunks `coords`, so send the records of the turrets there that are not idle.
]]
function Turrets.sendChunks(player: Player, coords: { { number } })
	local world, sender = state, net
	if world == nil or sender == nil then
		return
	end
	local records: { Protocol.TurretRecord } = {}
	for _, coord in coords do
		local chunk = TurretWorld.chunkRecords(world, coord[1], coord[2])
		table.move(chunk, 1, #chunk, #records + 1, records)
	end
	sendRecords(sender, player, records)
end

-- Is it the lure's time: night, or a blood moon?
local function lureTime(): boolean
	local dayTime = TimeOfDay.get()
	if not DayCycle.isDay(dayTime) then
		return true
	end
	local apocalypse = Config.Apocalypse
	return apocalypse.Enabled and BloodMoon.active(dayTime, apocalypse.BloodMoon)
end

--[[
	Starts the turrets: the simulation and the service (see the header). Machines must have
	started (the blocks it reads), and Mobs and Weapons (its targets and shots).
]]
function Turrets.start(serverNet: Net, _world: WorldServer.World)
	assert(not started, "Turrets.start was already called")
	started = true
	if not Config.Turrets.Enabled then
		return
	end
	net = serverNet
	local random = Random.new()
	-- (Env `mob`'s answer, lent: the simulation reads it at once.)
	local found: TurretWorld.Target? = nil
	local simulation = TurretWorld.new({
		getBlock = Machines.knownBlock,
		hostiles = Mobs.hostiles,
		mob = function(id: number): TurretWorld.Target?
			local target = Mobs.target(id, found)
			if target then
				found = target
			end
			return target
		end,
		hurt = function(id: number, amount: number, ox: number, oz: number, knockback: number, head: boolean): number
			return Mobs.weaponDamage(id, amount, nil, ox, oz, knockback, head)
		end,
		noise = NoiseBus.emit,
		lureTime = lureTime,
		feed = function(x: number, y: number, z: number): number
			local pipes = Transmitters.world()
			local block = Machines.knownBlock(x, y, z)
			return if pipes and block then TransmitterWorld.feedTier(pipes, x, y, z, block) else 0
		end,
		random = function(): number
			return random:NextNumber()
		end,
		settings = TurretWorld.settings(),
	})
	state = simulation
	Machines.setTurretService(function(order: TurretTypes.Order, out: TurretTypes.Outcome): TurretTypes.Outcome
		return TurretWorld.step(simulation, order, out)
	end)
end

--[[
	Replicates the simulation after `dt` seconds: the server script calls it every frame right
	after Machines.update (whose machine ticks ran the turrets). Shots go to the players within
	ShotBroadcast of each, records to those within RecordRange (see the header).
]]
function Turrets.update(_dt: number)
	local world, sender = state, net
	if world == nil or sender == nil then
		return
	end
	local shots = TurretWorld.takeShots(world)
	local records = TurretWorld.takeRecords(world)
	if #shots == 0 and #records == 0 then
		return
	end
	local everything = not PlayerPositions.networked()
	local broadcast = Config.Weapons.ShotBroadcast
	local hear = broadcast * broadcast
	local range = Config.Turrets.RecordRange
	for _, player in Players:GetPlayers() do
		local fx, _, fz = PlayerPositions.feet(player)
		if fx == nil then
			-- (Not in the world yet: every change, as the machines' records.)
			if everything then
				sendRecords(sender, player, records)
			end
			continue
		end
		table.clear(nearShots)
		for _, shot in shots do
			local dx, dz = shot.ox - fx, shot.oz - fz
			if dx * dx + dz * dz <= hear then
				table.insert(nearShots, shot)
			end
		end
		sendShots(sender, player, nearShots)
		table.clear(nearRecords)
		for _, record in records do
			if math.abs(record.x + 0.5 - fx) <= range and math.abs(record.z + 0.5 - fz) <= range then
				table.insert(nearRecords, record)
			end
		end
		sendRecords(sender, player, nearRecords)
	end
	table.clear(nearShots)
	table.clear(nearRecords)
end

return Turrets
