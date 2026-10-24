--!strict
--[[
	The server's turret simulation, pure (no Roblox APIs, so the tests run it): every turret's aim
	and target, its scans and sight checks, its shots (traced like a player's: Weapons/Ballistics,
	Weapons/FireRules), the noise they make and the lure, and what clients are told. Server
	Turrets/Turrets runs it in the game; its `step` is the service every turret's machine tick
	asks (Shared/Turrets/Types: an Order in, an Outcome out; Machines/Kinds/Turret keeps the
	books: energy, the round taken, the cadence, the packed state).

	The API (frozen: the glue, the specs and the machine kind are built on it):
	  new(env)                         a world over the game's Env (below)
	  step(world, order, out)          the Service: one turret's machine tick; fills and returns
	                                   `out` (status, fired, tracking, feed)
	  blockChanged(world, x, y, z, old, new)   a turret gone: forget it
	  takeShots(world)                 this frame's Shots records (Net/WeaponSync: shooter 0, the
	                                   stand-in gun, the turret's own counter, origins at the
	                                   muzzles, `plain` for a suppressed one), for the glue to send
	  takeRecords(world)               the Turrets records that changed (Net/Protocol
	                                   TurretRecord), chunkRecords(world, cx, cz) a chunk's
	                                   non-default ones, sent with its edit list
	  stats(world)                     turrets, tracking, scans, sights, shots, ms (F3, specs)
	State per turret is by Grid key and not saved: turrets come back idle after a load.

	Env (what it needs from the game; the glue builds it):
	  getBlock   the blocks the machines read (Machines.knownBlock): never generates terrain
	  hostiles   fills a reused list with the live, unfrozen mobs whose kind is `hostile`
	             (MobList: every zombie, any later monster), returns how many: never players,
	             never animals
	  mob        one of them by id (nil: dead, gone or frozen)
	  hurt       Mobs.weaponDamage with no player (nobody is credited), returns the damage done
	  noise      Apocalypse/NoiseBus.emit
	  lureTime   night (not DayCycle.isDay) or a blood moon
	  feed       the feeder rule at a turret (Transmitters/TransmitterWorld.feedTier)
	  random     a uniform 0..1
	  settings   Config.Turrets and Config.Weapons (the specs tune copies)

	STUB (turret builder A implements Shared/Turrets' design: targeting and firing, noise and the
	lure, records): `step` answers from the order alone (No power, Blocked, No ammo, else No
	target), never fires, never tracks, feed 0; the world keeps nothing, sends nothing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local MobList = require(Shared.Entities.MobList)
local Protocol = require(Shared.Net.Protocol)
local WeaponSync = require(Shared.Net.WeaponSync)
local Turrets = require(Shared.Turrets)
local TurretTypes = require(Shared.Turrets.Types)

export type Order = TurretTypes.Order
export type Outcome = TurretTypes.Outcome

-- A hostile mob a turret may aim at (feet in blocks, facing (sin yaw, cos yaw)).
export type Target = {
	id: number,
	kind: MobList.Kind,
	variant: number,
	x: number,
	y: number,
	z: number,
	yaw: number,
}

-- What the simulation needs from the game (see the header).
export type Env = {
	getBlock: (x: number, y: number, z: number) -> number?,
	hostiles: (into: { Target }) -> number,
	mob: (id: number) -> Target?,
	hurt: (id: number, amount: number, ox: number, oz: number, knockback: number, head: boolean) -> number,
	noise: (x: number, y: number, z: number, radius: number) -> (),
	lureTime: () -> boolean,
	feed: (x: number, y: number, z: number) -> number,
	random: () -> number,
	settings: { turrets: typeof(Config.Turrets), weapons: typeof(Config.Weapons) },
}

-- The simulation's counts (F3's turret line, the specs' budgets): turrets known, tracking now;
-- scans, sight checks and shots in the last machine tick; ms the last tick took.
export type Stats = { turrets: number, tracking: number, scans: number, sights: number, shots: number, ms: number }

-- The whole state (builder A gives it the per-turret state, the tick's grid and budgets).
export type World = {
	env: Env,
	-- The last machine tick seen (Order `tick`).
	tick: number,
}

local STATUS = Turrets.STATUS

local TurretWorld = {}

function TurretWorld.new(env: Env): World
	return { env = env, tick = 0 }
end

-- The game's settings for an Env (Config.Turrets and Config.Weapons as they are).
function TurretWorld.settings(): { turrets: typeof(Config.Turrets), weapons: typeof(Config.Weapons) }
	return { turrets = Config.Turrets, weapons = Config.Weapons }
end

--[[
	The Service (Shared/Turrets/Types): one turret's machine tick. STUB (builder A): the status
	from the order alone, in the design's precedence without a target: No power, Blocked, No ammo
	(no round), No target; never fires, never tracks, feed 0.
]]
function TurretWorld.step(world: World, order: Order, out: Outcome): Outcome
	world.tick = order.tick
	out.fired, out.tracking, out.feed = false, false, 0
	if not order.powered then
		out.status = STATUS.NO_POWER
	elseif order.blocked then
		out.status = STATUS.BLOCKED
	elseif order.ammo < 1 then
		out.status = STATUS.NO_AMMO
	else
		out.status = STATUS.NO_TARGET
	end
	return out
end

-- Block (x, y, z) changed from `old` to `new` (WorldServer.onChanged): a turret gone is forgotten.
-- STUB (builder A): nothing is kept yet.
function TurretWorld.blockChanged(_world: World, _x: number, _y: number, _z: number, _old: number, _new: number) end

-- This frame's shots (Net/WeaponSync records, origins at the muzzles). STUB (builder A): none.
function TurretWorld.takeShots(_world: World): { WeaponSync.Shot }
	return {}
end

-- The Turrets records that changed since they were last taken. STUB (builder A): none.
function TurretWorld.takeRecords(_world: World): { Protocol.TurretRecord }
	return {}
end

-- The records of chunk (cx, cz)'s turrets that are not idle (sent with its edit list). STUB
-- (builder A): none.
function TurretWorld.chunkRecords(_world: World, _cx: number, _cz: number): { Protocol.TurretRecord }
	return {}
end

-- The simulation's counts (see Stats). STUB (builder A): nothing counted.
function TurretWorld.stats(_world: World): Stats
	return { turrets = 0, tracking = 0, scans = 0, sights = 0, shots = 0, ms = 0 }
end

return TurretWorld
