--!strict
--[[
	Turrets in the game (Shared/Turrets): runs Turrets/TurretWorld, the pure simulation, as the
	service every turret's machine tick asks, and replicates it.

	  Service   `start` builds the simulation over the game (its Env: the machines' known blocks,
	            the hostile mobs, their hurts with no player credited, Apocalypse/NoiseBus, the
	            night and the blood moon, the feeder rule over Transmitters/TransmitterWorld's
	            transporters) and hands its `step` to the machines (Machines.setTurretService;
	            server Machines never requires this: Players/ToughAsNails requires Machines, Mobs
	            requires ToughAsNails). The server script starts it after Weapons/.
	  World     the server script chains `blockChanged` onto WorldServer.onChanged after
	            Machines/Machines, so a turret broken or replaced is forgotten.
	  Records   Turrets records (Net/Protocol, message Turrets): a chunk's non-default ones right
	            after its edit list (`sendChunks`, from ServerNet's `chunksSent` rule after the
	            machines'), changes to players within Config.Turrets.RecordRange (`update`, every
	            frame right after Machines.update).
	  Shots     each frame's turret shots as one Shots message (Net/WeaponSync) to the players
	            within Config.Weapons.ShotBroadcast of each turret (the glue's own audience:
	            FireRules.audience expects a shooter).
	With Config.Turrets.Enabled false nothing starts: no simulation, no service (turrets show
	"Disabled"), no messages.

	The API (frozen): start(net, world), update(dt), blockChanged(x, y, z, old, new),
	sendChunks(player, coords), world().

	STUB (turret builder A implements the glue): `start` registers the stub simulation with a
	plain Env (no hostiles, no hurts, no noise, never the lure's time; the feeder rule is real);
	`update` and `sendChunks` send nothing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local TurretTypes = require(Shared.Turrets.Types)

local WorldServer = require(script.Parent.Parent.World.WorldServer)
local Machines = require(script.Parent.Parent.Machines.Machines)
local Transmitters = require(script.Parent.Parent.Transmitters.Transmitters)
local TransmitterWorld = require(script.Parent.Parent.Transmitters.TransmitterWorld)
local TurretWorld = require(script.Parent.TurretWorld)

-- Only what this uses of ServerNet.ServerNet.
type Net = {
	send: (player: Player, kind: number, payload: buffer) -> (),
}

local Turrets = {}

local state: TurretWorld.World? = nil
local net: Net? = nil
local started = false

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

--[[
	ServerNet's `chunksSent` rule (with the pipes' and the machines'): the player was just sent the
	edit lists of chunks `coords`, so send the records of the turrets there that are not idle.
	STUB (builder A): the simulation keeps none yet.
]]
function Turrets.sendChunks(_player: Player, _coords: { { number } })
	local world, sender = state, net
	if world == nil or sender == nil then
		return
	end
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
	-- STUB (builder A): the game's Env (Mobs.hostiles and target, Mobs.weaponDamage, NoiseBus,
	-- the night and the blood moon); only the blocks and the feeder rule are real here.
	local simulation = TurretWorld.new({
		getBlock = Machines.knownBlock,
		hostiles = function(into: { TurretWorld.Target }): number
			table.clear(into)
			return 0
		end,
		mob = function(_id: number): TurretWorld.Target?
			return nil
		end,
		hurt = function(
			_id: number,
			_amount: number,
			_ox: number,
			_oz: number,
			_knockback: number,
			_head: boolean
		): number
			return 0
		end,
		noise = function(_x: number, _y: number, _z: number, _radius: number) end,
		lureTime = function(): boolean
			return false
		end,
		feed = function(x: number, y: number, z: number): number
			local pipes = Transmitters.world()
			local block = Machines.knownBlock(x, y, z)
			return if pipes and block then TransmitterWorld.feedTier(pipes, x, y, z, block) else 0
		end,
		random = math.random,
		settings = TurretWorld.settings(),
	})
	state = simulation
	Machines.setTurretService(function(order: TurretTypes.Order, out: TurretTypes.Outcome): TurretTypes.Outcome
		return TurretWorld.step(simulation, order, out)
	end)
end

--[[
	Replicates the simulation after `dt` seconds: the server script calls it every frame right
	after Machines.update (whose machine ticks ran the turrets). STUB (builder A): the shots and
	records it takes go nowhere yet.
]]
function Turrets.update(_dt: number)
	local world, sender = state, net
	if world == nil or sender == nil then
		return
	end
	TurretWorld.takeShots(world)
	TurretWorld.takeRecords(world)
end

return Turrets
