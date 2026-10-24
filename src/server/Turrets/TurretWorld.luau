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
	  settings()                       Config.Turrets and Config.Weapons, an Env's `settings`
	State per turret is by Grid key and not saved: turrets come back idle after a load. What
	takeShots and takeRecords return is lent: their lists and records are the world's, reused, so
	the glue sends them before the next step (it does: right after the machines' ticks).

	Env (what it needs from the game; the glue builds it):
	  getBlock   the blocks the machines read (Machines.knownBlock): never generates terrain
	  hostiles   fills a reused list with the live, unfrozen mobs whose kind is `hostile`
	             (MobList: every zombie, any later monster), returns how many: never players,
	             never animals (Mobs.hostiles)
	  mob        one of them by id (nil: dead, gone or frozen; Mobs.target); the table may be
	             lent, read at once
	  hurt       Mobs.weaponDamage with no player (nobody is credited), returns the damage done
	  noise      Apocalypse/NoiseBus.emit (the director's night, rain and snow factors follow)
	  lureTime   night (not DayCycle.isDay) or a blood moon
	  feed       the feeder rule at a turret (Transmitters/TransmitterWorld.feedTier)
	  random     a uniform 0..1
	  settings   Config.Turrets and Config.Weapons (the specs tune copies; the shared rules,
	             TurretRules, read Config.Turrets itself)

	One turret's tick (Config.Turrets is `s`):
	  Status     in the design's precedence: No power (it holds still and keeps its target), then
	             Blocked (the cell over the gun: it drops its target), then with a target Firing
	             within FiringTicks of its last shot, No ammo unarmed, else Targeting; without
	             one No ammo with no round, else No target. Disabled is the kind's.
	  Feed       the feeder rule (`env.feed`) at its first tick and every FeedTicks after,
	             staggered by its cell; the Outcome's `feed` every tick.
	  Targets    only `env.hostiles`' and `env.mob`'s: never a player or an animal. The aim point
	             is the centre of its body box (Ballistics.mobBoxes), its head box's for a scoped
	             sniper (Shared/Turrets.optic `head`); a target is in reach when that point is
	             between MinRange and the range (TurretRules.range: a scope's factor, at most
	             MaxRange) of the pivot and within the pitch limits (TurretRules.inPitch: below
	             PitchMin is a dead zone).
	  Scans      with no target, every ScanTicks (a Laser Sight's `scan`: 5) staggered by its
	             cell, at most MaxScansPerTick for every turret together (one over waits for the
	             next tick): the hostiles in reach (from the tick's grid: hostiles hashed into
	             16-block columns once a machine tick, only when a turret scans or shoots) ranked
	             by TurretRules.score (distance + 0.05 a degree to turn: one two blocks nearer but
	             behind the gun loses), the best MaxSightChecks looked at in that order
	             (FireRules.wallBetween's rule, on VoxelRaycast.distance: Shapes.sight's collision
	             boxes, so glass and leaves stop sight, torches and water don't), the first in
	             sight taken.
	  Tracking   sticky (never a switch to a nearer one): turning at its turn rate
	             (TurretRules.turn, `turn` degrees a second), its sight checked every SightTicks,
	             lost after LoseTicks unseen, at once when it is gone (env.mob nil: dead, removed,
	             frozen) or out of reach. No target, powered and not blocked: the pitch eases back
	             to level at the turn rate, the yaw holds (the client does the same: nothing is
	             sent for it). Without power nothing turns. The turret's own cell reads as air for
	             its sight and its shots, so it shoots down past its own edge.
	  Firing     tracking, the target seen at the last check, the order ready, armed, powered and
	             not blocked, the gun within `settle` degrees of the aim point, and the tick's
	             MaxShotsPerTick not used up (a shot over it waits a tick: the kind holds the credit
	             at CREDIT, so none is lost). The shot: from the pivot along the exact aim, spread
	             by TurretRules.spread (Ballistics.spreadDir: a Laser Sight halves the cone, a
	             working Suppressor narrows it); the round's flight (its velocity, range and
	             falloff, zeroed at the aim's distance, ending at the round's range x 2.5 or the
	             turret's range + ExtraFlight, the nearer), its damage x the type's damageScale; the
	             hostiles near the flight its only targets (FireRules.mobTarget's, filled into
	             pooled tables; no lag compensation), so a player or an animal in the line is flown
	             through; FireRules.blockRules(weapons, false): glass is never shattered, leaves
	             are flown through (PassLeaves); Ballistics.trace. A hit hurts through
	             `env.hurt` (Ballistics.damage: a head hit times ZombieHead, HelmetShare of that
	             under a helmet, through no armour; the bullet's knockback away from the turret).
	             One bullet a shot (the turrets' rounds are single bullets).
	  Noise      a shot's noise at the muzzle (TurretRules.shotNoise: the stand-in gun's with its
	             muzzle device x NoiseScale) and its impact's (FireRules.impactNoise, ImpactNoise
	             blocks) at most once every ShotNoiseTicks a turret.
	  The lure   powered, not blocked, armed, no target, its Lure on, Lure.Enabled: every
	             Lure.Ticks (staggered by its cell) while `env.lureTime()`, a Lure.Noise noise at
	             the pivot, at most one in each Lure.Cell x Lure.Cell cell of the world an interval
	             for every turret together. A muzzle device never quiets it (servos, not shots).
	  Records    a Turrets record (its cell, yaw, pitch, target, flags, rounds held after the tick)
	             when the target, the flags or the rounds changed, or, tracking, the aim moved
	             RecordAngle degrees since sent or RecordRefresh ticks went by; at most every
	             RecordTicks a turret. A turret never recorded is idle to clients (yaw 0, level, no
	             target, no flags, no rounds): `chunkRecords` gives the others.
	An order for a block that is no turret is answered from the order alone (No power, Blocked, No
	ammo, No target) and nothing is kept for it.
	Nothing in scans, sight checks, tracking, the lure or records allocates (lists, the grid, the
	targets and the records are the world's, reused); a shot allocates only what Ballistics.trace
	makes for it (its impacts, about 1 KB). `aimPoint`, `fillTarget` and `sightBlocked` are
	exported for the specs, which hold them to Ballistics.mobBoxes, FireRules.mobTarget and
	FireRules.wallBetween.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local Coords = require(Shared.World.Coords)
local Items = require(Shared.Items)
local MobList = require(Shared.Entities.MobList)
local Protocol = require(Shared.Net.Protocol)
local WeaponSync = require(Shared.Net.WeaponSync)
local Turrets = require(Shared.Turrets)
local TurretRules = require(Shared.Turrets.TurretRules)
local TurretTypes = require(Shared.Turrets.Types)
local Weapons = require(Shared.Weapons)
local Handling = require(Shared.Weapons.Handling)
local Ballistics = require(Shared.Weapons.Ballistics)
local Shapes = require(Shared.Blocks.Shapes)
local VoxelRaycast = require(Shared.World.VoxelRaycast)

local FireRules = require(script.Parent.Parent.Weapons.FireRules)

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

type Spec = Turrets.Spec

-- One turret's state (see the header; angles in radians, ticks the machines').
type Turret = {
	key: number,
	x: number,
	y: number,
	z: number,
	block: number,
	spec: Spec,
	-- Its stagger (scans, the feed, the lure) and its chunk's key (`chunkRecords`).
	phase: number,
	chunk: number,
	yaw: number,
	pitch: number,
	-- The mob it tracks (0: none), the tick it was last seen and last looked at, and whether
	-- it was in sight then; a scan waiting for the next tick's budget.
	target: number,
	seenAt: number,
	sightAt: number,
	visible: boolean,
	scanDue: boolean,
	-- Its last shot and its last noise (ticks), its feeder tier and whether it was asked yet,
	-- its shot counter (u16).
	shotAt: number,
	noiseAt: number,
	feed: number,
	fed: boolean,
	counter: number,
	-- Its flags (Protocol.TurretFlag) and rounds after its last tick.
	flags: number,
	ammo: number,
	-- What clients were last told (`record`) and when.
	sentYaw: number,
	sentPitch: number,
	sentTarget: number,
	sentFlags: number,
	sentAmmo: number,
	sentAt: number,
	queued: boolean,
	removed: boolean,
	record: Protocol.TurretRecord,
}

-- The whole state (see the header).
export type World = {
	env: Env,
	-- The last machine tick seen (Order `tick`).
	tick: number,
	turrets: { [number]: Turret },
	-- Turrets by chunk (Coords.chunkKey).
	byChunk: { [number]: { Turret } },
	count: number,
	tracking: number,
	-- This tick's counts and time (ms).
	scans: number,
	sights: number,
	shots: number,
	ms: number,
	-- The tick's grid of hostiles (`gridTick`: the tick it was built for): the list env.hostiles
	-- fills, how many, each 16-block column's first index and each entry's next (0: the last).
	gridTick: number,
	hostiles: { Target },
	hostileCount: number,
	heads: { [number]: number },
	nexts: { number },
	-- A scan's candidates (index into `hostiles`, score, aim point).
	candidates: { number },
	scores: { number },
	aimX: { number },
	aimY: { number },
	aimZ: { number },
	-- A shot's targets (from the pool), its last impact (for FireRules.impactNoise), its origin,
	-- direction and flight, the block rules (no glass shattered).
	targets: { Ballistics.Target },
	targetPool: { Ballistics.Target },
	finals: { Ballistics.Impact },
	origin: Ballistics.Vec,
	dir: Ballistics.Vec,
	flight: Ballistics.ShotSpec,
	rules: Ballistics.BlockRules,
	-- The cell `sight` reads as air (the turret looking or shooting), and `sight`: env.getBlock
	-- but for it.
	ownX: number,
	ownY: number,
	ownZ: number,
	sight: (x: number, y: number, z: number) -> number?,
	-- Shapes.sight of `sight`: which blocks stop a ray, and their outlines.
	stops: (id: number) -> boolean,
	outline: (id: number, x: number, y: number, z: number) -> { number }?,
	-- Shots records waiting for takeShots (the first `shotCount` of the pool), the list handed
	-- out; turrets whose record waits for takeRecords, the list handed out.
	shotPool: { WeaponSync.Shot },
	shotCount: number,
	shotList: { WeaponSync.Shot },
	queue: { Turret },
	recordList: { Protocol.TurretRecord },
	-- Each lure cell's last lure (tick), by Coords.chunkKey of the cell.
	lures: { [number]: number },
}

local STATUS = Turrets.STATUS
local Flag = Protocol.TurretFlag
local AIR = Blocks.AIR
-- The grid's columns (blocks).
local GRID = 16
-- Shots records kept for takeShots at most (a glue that never takes them loses no more memory).
local MAX_PENDING_SHOTS = 1024
-- Blocks a shot's candidates may stand beyond its flight's box, and their box's centre from its
-- chord beyond half their height and width (the arc's sag, a head reaching out).
local FLIGHT_MARGIN = 2
local FLIGHT_REACH = 0.75
-- The coordinates a Shots message may carry (Net/WeaponSync): sideways, and up or down.
local LIMIT = Protocol.MAX_COORDINATE + 64
local Y_LIMIT = 4096
-- Items whose flags the records carry.
local LASER = rawget(Items.id :: any, "LaserSight") :: number?
local SCOPE = rawget(Items.id :: any, "RifleScope") :: number?

local TurretWorld = {}

--[[ The world ]]

function TurretWorld.new(env: Env): World
	local world: World
	local function sight(x: number, y: number, z: number): number?
		if x == world.ownX and y == world.ownY and z == world.ownZ then
			return AIR
		end
		return world.env.getBlock(x, y, z)
	end
	local stops, outline = Shapes.sight(sight)
	world = {
		env = env,
		tick = 0,
		turrets = {},
		byChunk = {},
		count = 0,
		tracking = 0,
		scans = 0,
		sights = 0,
		shots = 0,
		ms = 0,
		gridTick = -math.huge,
		hostiles = {},
		hostileCount = 0,
		heads = {},
		nexts = {},
		candidates = {},
		scores = {},
		aimX = {},
		aimY = {},
		aimZ = {},
		targets = {},
		targetPool = {},
		finals = {},
		origin = { x = 0, y = 0, z = 0 },
		dir = { x = 0, y = 0, z = 1 },
		flight = {
			velocity = 0,
			gravity = 0,
			zero = 0,
			range = 0,
			maxRange = 0,
			falloffMin = 0,
			damage = 0,
			segment = 0.05,
			shooter = nil,
		},
		rules = FireRules.blockRules(env.settings.weapons, false),
		ownX = math.huge,
		ownY = math.huge,
		ownZ = math.huge,
		sight = sight,
		stops = stops,
		outline = outline,
		shotPool = {},
		shotCount = 0,
		shotList = {},
		queue = {},
		recordList = {},
		lures = {},
	}
	return world
end

-- The game's settings for an Env (Config.Turrets and Config.Weapons as they are).
function TurretWorld.settings(): { turrets: typeof(Config.Turrets), weapons: typeof(Config.Weapons) }
	return { turrets = Config.Turrets, weapons = Config.Weapons }
end

-- A new machine tick: its counts start over, its grid is stale, old lure cells go.
local function beginTick(world: World, tick: number)
	world.tick = tick
	world.scans, world.sights, world.shots, world.ms = 0, 0, 0, 0
	local lure = world.env.settings.turrets.Lure
	local ticks = math.max(1, lure.Ticks)
	if tick % ticks == 0 then
		local lures = world.lures
		for cell, last in lures do
			if tick - last >= ticks then
				lures[cell] = nil
			end
		end
	end
end

-- (Whole numbers 0..n - 1 from a cell, so neighbours never share a phase.)
local function phaseOf(x: number, y: number, z: number): number
	return (x + 3 * z + 7 * y) % 997
end

local function newTurret(order: Order, spec: Spec): Turret
	local x, y, z = order.x, order.y, order.z
	local cx, cz = Coords.blockToChunk(x, z)
	return {
		key = order.key,
		x = x,
		y = y,
		z = z,
		block = order.block,
		spec = spec,
		phase = phaseOf(x, y, z),
		chunk = Coords.chunkKey(cx, cz),
		yaw = 0,
		pitch = 0,
		target = 0,
		seenAt = -math.huge,
		sightAt = -math.huge,
		visible = false,
		scanDue = false,
		shotAt = -math.huge,
		noiseAt = -math.huge,
		feed = 0,
		fed = false,
		counter = 0,
		flags = 0,
		ammo = 0,
		sentYaw = 0,
		sentPitch = 0,
		sentTarget = 0,
		sentFlags = 0,
		sentAmmo = 0,
		sentAt = -math.huge,
		queued = false,
		removed = false,
		record = { x = x, y = y, z = z, yaw = 0, pitch = 0, target = 0, flags = 0, ammo = 0 },
	}
end

local function forget(world: World, turret: Turret)
	turret.removed = true
	world.turrets[turret.key] = nil
	world.count -= 1
	if turret.target ~= 0 then
		world.tracking -= 1
	end
	local list = world.byChunk[turret.chunk]
	if list then
		local index = table.find(list, turret)
		if index then
			list[index] = list[#list]
			list[#list] = nil
		end
		if #list == 0 then
			world.byChunk[turret.chunk] = nil
		end
	end
end

-- The turret of `order` (a new one, idle, the first time; a fresh one when its block changed).
local function turretOf(world: World, order: Order, spec: Spec): Turret
	local turret = world.turrets[order.key]
	if
		turret
		and turret.block == order.block
		and turret.x == order.x
		and turret.y == order.y
		and turret.z == order.z
	then
		return turret
	elseif turret then
		forget(world, turret)
	end
	local made = newTurret(order, spec)
	world.turrets[made.key] = made
	world.count += 1
	local list = world.byChunk[made.chunk]
	if list == nil then
		list = {}
		world.byChunk[made.chunk] = list
	end
	table.insert(list, made)
	return made
end

local function setTarget(world: World, turret: Turret, id: number)
	if (turret.target ~= 0) ~= (id ~= 0) then
		world.tracking += if id ~= 0 then 1 else -1
	end
	turret.target = id
end

--[[ Targets ]]

--[[
	Where a turret aims at `target`: the centre of its body box, or with `head` of its head box
	(Ballistics.mobBoxes' boxes, worked out here without making them: the body square about the
	feet, the head turned with the mob).
]]
local function aimPoint(target: Target, head: boolean): (number, number, number)
	local boxes = Ballistics.kindBoxes(target.kind)
	if head then
		local h = boxes.head
		local lx, lz = (h[1] + h[4]) / 2, (h[3] + h[6]) / 2
		local c, s = math.cos(target.yaw), math.sin(target.yaw)
		return target.x + c * lx + s * lz, target.y + (h[2] + h[5]) / 2, target.z - s * lx + c * lz
	end
	local b = boxes.body
	return target.x + (b[1] + b[4]) / 2, target.y + (b[2] + b[5]) / 2, target.z + (b[3] + b[6]) / 2
end
-- (For the specs, as `fillTarget`: they hold both to Ballistics.mobBoxes and FireRules.mobTarget.)
TurretWorld.aimPoint = aimPoint

-- Builds the tick's grid of hostiles once (see the header).
local function ensureGrid(world: World)
	if world.gridTick == world.tick then
		return
	end
	world.gridTick = world.tick
	local list = world.hostiles
	local n = world.env.hostiles(list)
	world.hostileCount = n
	local heads, nexts = world.heads, world.nexts
	table.clear(heads)
	for i = 1, n do
		local mob = list[i]
		local key = Coords.chunkKey(mob.x // GRID, mob.z // GRID)
		nexts[i] = heads[key] or 0
		heads[key] = i
	end
end

--[[
	Is a block between (ax, ay, az) and (bx, by, bz), cell (cx, cy, cz) read as air?
	FireRules.wallBetween's rule (Shapes.sight's collision boxes) on VoxelRaycast.distance, which
	makes no Hit: a sight check allocates nothing, a blocked one neither. (For the specs too, which
	hold it to FireRules.wallBetween.)
]]
local function sightBlocked(
	world: World,
	cx: number,
	cy: number,
	cz: number,
	ax: number,
	ay: number,
	az: number,
	bx: number,
	by: number,
	bz: number
): boolean
	world.ownX, world.ownY, world.ownZ = cx, cy, cz
	local dx, dy, dz = bx - ax, by - ay, bz - az
	local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
	if distance < 1e-6 then
		return false
	end
	local hit = VoxelRaycast.distance(ax, ay, az, dx, dy, dz, distance, world.sight, world.stops, world.outline)
	return hit ~= nil and hit < distance - 1e-6
end
TurretWorld.sightBlocked = sightBlocked

-- Is a block between the turret's pivot and a point (its own cell air)? A sight check counted.
local function wall(
	world: World,
	turret: Turret,
	px: number,
	py: number,
	pz: number,
	x: number,
	y: number,
	z: number
): boolean
	world.sights += 1
	return sightBlocked(world, turret.x, turret.y, turret.z, px, py, pz, x, y, z)
end

--[[
	A scan (see the header): the best hostile in reach and in sight becomes the target. True when
	one did.
]]
local function scan(world: World, turret: Turret, range: number, head: boolean): boolean
	local s = world.env.settings.turrets
	ensureGrid(world)
	world.scans += 1
	local px, py, pz = TurretRules.pivot(turret.x, turret.y, turret.z)
	local list, heads, nexts = world.hostiles, world.heads, world.nexts
	local candidates, scores = world.candidates, world.scores
	local aimX, aimY, aimZ = world.aimX, world.aimY, world.aimZ
	local far, near = range * range, s.MinRange * s.MinRange
	local yaw, pitch = turret.yaw, turret.pitch
	local n = 0
	for cx = (px - range) // GRID, (px + range) // GRID do
		for cz = (pz - range) // GRID, (pz + range) // GRID do
			local i = heads[Coords.chunkKey(cx, cz)] or 0
			while i ~= 0 do
				local x, y, z = aimPoint(list[i], head)
				local dx, dy, dz = x - px, y - py, z - pz
				local d2 = dx * dx + dy * dy + dz * dz
				if d2 <= far and d2 >= near then
					local wantYaw, wantPitch, distance = TurretRules.aim(px, py, pz, x, y, z)
					if TurretRules.inPitch(wantPitch) then
						n += 1
						candidates[n] = i
						scores[n] = TurretRules.score(distance, TurretRules.offAngle(yaw, pitch, wantYaw, wantPitch))
						aimX[n], aimY[n], aimZ[n] = x, y, z
					end
				end
				i = nexts[i]
			end
		end
	end
	-- The best few in order (each found by a pass: nothing sorted, nothing made).
	for _ = 1, math.min(n, s.MaxSightChecks) do
		local best, bestScore = 0, math.huge
		for k = 1, n do
			if scores[k] < bestScore then
				best, bestScore = k, scores[k]
			end
		end
		if best == 0 then
			break
		end
		scores[best] = math.huge
		if not wall(world, turret, px, py, pz, aimX[best], aimY[best], aimZ[best]) then
			setTarget(world, turret, list[candidates[best]].id)
			turret.seenAt, turret.sightAt, turret.visible = world.tick, world.tick, true
			return true
		end
	end
	return false
end

--[[ Shots ]]

-- The next pooled Shots record (nil: MAX_PENDING_SHOTS wait already).
local function nextShot(world: World): WeaponSync.Shot?
	if world.shotCount >= MAX_PENDING_SHOTS then
		return nil
	end
	world.shotCount += 1
	local pool = world.shotPool
	local shot = pool[world.shotCount]
	if shot == nil then
		shot = {
			shooter = 0,
			item = 0,
			shot = 0,
			suppressed = false,
			jammed = false,
			refused = false,
			plain = false,
			ox = 0,
			oy = 0,
			oz = 0,
			pellets = { { x = 0, y = 0, z = 0, hit = 0 } },
		}
		pool[world.shotCount] = shot
	end
	return shot
end

--[[
	`mob` as a shot's target (FireRules.mobTarget's: its Ballistics.mobBoxes, whether it is a
	zombie and wears a helmet; no lag compensation), filled into the pooled `target` and its boxes.
]]
local function fillTarget(target: Ballistics.Target, mob: Target)
	local kind = mob.kind
	local boxes = Ballistics.kindBoxes(kind)
	local b, h = boxes.body, boxes.head
	local x, y, z = mob.x, mob.y, mob.z
	local body, head = target.body, target.head
	body[1], body[2], body[3], body[4], body[5], body[6] = x + b[1], y + b[2], z + b[3], x + b[4], y + b[5], z + b[6]
	-- (The head turns with the mob: mobBoxes' centre along the yaw, the turned box's bounds.)
	local c, s = math.cos(mob.yaw), math.sin(mob.yaw)
	local lx, lz = (h[1] + h[4]) / 2, (h[3] + h[6]) / 2
	local hx, hz = (h[4] - h[1]) / 2, (h[6] - h[3]) / 2
	local cx, cz = x + c * lx + s * lz, z - s * lx + c * lz
	local ex, ez = math.abs(c) * hx + math.abs(s) * hz, math.abs(s) * hx + math.abs(c) * hz
	head[1], head[2], head[3], head[4], head[5], head[6] = cx - ex, y + h[2], cz - ez, cx + ex, y + h[5], cz + ez
	target.key = mob.id
	target.zombie = MobList.isZombie(kind)
	target.helmet = FireRules.helmet(kind, mob.variant)
end
TurretWorld.fillTarget = fillTarget

-- The hostiles near a flight (see the header) as its targets, in the pool's tables.
local function flightTargets(world: World, length: number)
	local targets, pool = world.targets, world.targetPool
	table.clear(targets)
	ensureGrid(world)
	local origin, dir, flight = world.origin, world.dir, world.flight
	local x0, y0, z0, x1, y1, z1 = Ballistics.bounds(origin, dir, flight)
	local m = FLIGHT_MARGIN
	x0, y0, z0, x1, y1, z1 = x0 - m, y0 - m, z0 - m, x1 + m, y1 + m, z1 + m
	local ox, oy, oz = origin.x, origin.y, origin.z
	local ux, uy, uz = dir.x, dir.y, dir.z
	local list, heads, nexts = world.hostiles, world.heads, world.nexts
	for cx = x0 // GRID, x1 // GRID do
		for cz = z0 // GRID, z1 // GRID do
			local i = heads[Coords.chunkKey(cx, cz)] or 0
			while i ~= 0 do
				local mob = list[i]
				local kind = mob.kind
				local x, y, z = mob.x, mob.y, mob.z
				if x >= x0 and x <= x1 and z >= z0 and z <= z1 and y <= y1 and y + kind.height >= y0 then
					-- (Near the chord from the origin to the flight's end: its box's centre.)
					local cy = y + kind.height / 2
					local along = math.clamp((x - ox) * ux + (cy - oy) * uy + (z - oz) * uz, 0, length)
					local dx, dy, dz = ox + ux * along - x, oy + uy * along - cy, oz + uz * along - z
					local reach = (kind.height + kind.width) / 2 + FLIGHT_REACH
					if dx * dx + dy * dy + dz * dz <= reach * reach then
						local n = #targets + 1
						local target = pool[n]
						if target == nil then
							local made: Ballistics.Target =
								{ kind = "mob", key = 0, body = table.create(6, 0), head = table.create(6, 0) }
							target = made
							pool[n] = made
						end
						fillTarget(target, mob)
						targets[n] = target
					end
				end
				i = nexts[i]
			end
		end
	end
end

--[[
	One shot of `turret` at the aim point (ax, ay, az), `distance` from its pivot, with the order's
	optic and muzzle device (see the header's Firing and Noise).
]]
local function shoot(
	world: World,
	turret: Turret,
	order: Order,
	range: number,
	ax: number,
	ay: number,
	az: number,
	distance: number
)
	local env = world.env
	local s, weapons = env.settings.turrets, env.settings.weapons
	local spec = turret.spec
	local round = Weapons.ammo(spec.ammo) :: Weapons.AmmoSpec
	local tick = world.tick
	world.shots += 1
	turret.shotAt = tick
	-- The flight.
	local px, py, pz = TurretRules.pivot(turret.x, turret.y, turret.z)
	local cone = TurretRules.spread(spec, order.optic, order.muzzle, order.muzzleFraction)
	local dx, dy, dz = Ballistics.spreadDir(
		(ax - px) / distance,
		(ay - py) / distance,
		(az - pz) / distance,
		cone,
		env.random(),
		env.random()
	)
	local origin, dir, flight = world.origin, world.dir, world.flight
	origin.x, origin.y, origin.z = px, py, pz
	dir.x, dir.y, dir.z = dx, dy, dz
	flight.velocity = round.velocity
	flight.gravity = weapons.Gravity
	flight.zero = distance
	flight.range = round.range
	flight.maxRange = math.min(round.range * 2.5, range + s.ExtraFlight)
	flight.falloffMin = round.falloffMin
	flight.damage = round.damage * spec.damageScale
	flight.segment = weapons.SegmentSeconds
	flightTargets(world, flight.maxRange)
	world.ownX, world.ownY, world.ownZ = turret.x, turret.y, turret.z
	local impacts = Ballistics.trace(world.sight, origin, dir, flight, world.targets, world.rules)
	local final = impacts[#impacts]
	-- The hit.
	if final and final.kind == "mob" and final.target then
		local amount = Ballistics.damage(flight, final, weapons)
		if amount > 0 then
			env.hurt(final.target.key, amount, px, pz, FireRules.knockback(1, 1, weapons), final.head)
		end
	end
	-- Its noise and its impact's, under the turret's cooldown.
	local mx, my, mz = TurretRules.muzzle(turret.x, turret.y, turret.z, turret.yaw, turret.pitch, spec.barrel)
	if tick - turret.noiseAt >= s.ShotNoiseTicks then
		turret.noiseAt = tick
		env.noise(mx, my, mz, TurretRules.shotNoise(spec, order.muzzle, order.muzzleFraction))
		if final then
			local finals = world.finals
			finals[1] = final
			local ix, iy, iz = FireRules.impactNoise(finals, px, py, pz, weapons)
			finals[1] = nil
			if ix ~= nil then
				env.noise(ix, iy, iz, weapons.ImpactNoise)
			end
		end
	end
	-- The record.
	turret.counter = (turret.counter + 1) % 65536
	local record = nextShot(world)
	if record == nil then
		return
	end
	local muzzle = if spec.muzzles[order.muzzle] then order.muzzle else nil
	local suppressed = Handling.suppressed(muzzle, order.muzzleFraction)
	local device = if muzzle then Weapons.attachment(muzzle) else nil
	record.shooter = 0
	record.item = spec.firearm
	record.shot = turret.counter
	record.suppressed = suppressed
	record.jammed = false
	record.refused = false
	record.plain = suppressed and device ~= nil and device.glow == false
	record.ox, record.oy, record.oz = mx, my, mz
	local pellet = record.pellets[1]
	if final then
		pellet.x = math.clamp(final.x, -LIMIT, LIMIT)
		pellet.y = math.clamp(final.y, -Y_LIMIT, Y_LIMIT)
		pellet.z = math.clamp(final.z, -LIMIT, LIMIT)
		pellet.hit = FireRules.hitKind(final)
	else
		pellet.x, pellet.y, pellet.z, pellet.hit = mx, my, mz, WeaponSync.Hit.None
	end
end

--[[ The lure ]]

-- The lure's turn (see the header): the turret is powered, armed, idle, its Lure on.
local function lure(world: World, turret: Turret)
	local settings = world.env.settings.turrets.Lure
	local tick = world.tick
	local ticks = math.max(1, settings.Ticks)
	if not settings.Enabled or (tick + turret.phase) % ticks ~= 0 or not world.env.lureTime() then
		return
	end
	local size = math.max(1, settings.Cell)
	local cell = Coords.chunkKey(turret.x // size, turret.z // size)
	local last = world.lures[cell]
	if last ~= nil and tick - last < ticks then
		return
	end
	world.lures[cell] = tick
	local px, py, pz = TurretRules.pivot(turret.x, turret.y, turret.z)
	world.env.noise(px, py, pz, settings.Noise)
end

--[[ Records ]]

-- Queues the turret's record as it is now (see the header's Records).
local function record(world: World, turret: Turret)
	turret.sentYaw, turret.sentPitch = turret.yaw, turret.pitch
	turret.sentTarget, turret.sentFlags, turret.sentAmmo = turret.target, turret.flags, turret.ammo
	turret.sentAt = world.tick
	local out = turret.record
	out.yaw, out.pitch = turret.yaw, turret.pitch
	out.target, out.flags, out.ammo = turret.target, turret.flags, turret.ammo
	if not turret.queued then
		turret.queued = true
		table.insert(world.queue, turret)
	end
end

-- Is a record due (see the header's Records)?
local function recordDue(world: World, turret: Turret): boolean
	local s = world.env.settings.turrets
	local since = world.tick - turret.sentAt
	if since < s.RecordTicks then
		return false
	end
	if turret.target ~= turret.sentTarget or turret.flags ~= turret.sentFlags or turret.ammo ~= turret.sentAmmo then
		return true
	elseif turret.target == 0 then
		return false
	end
	return since >= s.RecordRefresh
		or TurretRules.offAngle(turret.yaw, turret.pitch, turret.sentYaw, turret.sentPitch)
			> math.rad(s.RecordAngle)
end

--[[ The service ]]

-- The answer from the order alone (a block that is no turret: nothing kept).
local function fromOrder(order: Order, out: Outcome): Outcome
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

local function stepTurret(world: World, order: Order, out: Outcome, spec: Spec): Outcome
	local env = world.env
	local s = env.settings.turrets
	local tick = world.tick
	local turret = turretOf(world, order, spec)
	-- The feed.
	if not turret.fed or (tick + turret.phase) % math.max(1, s.FeedTicks) == 0 then
		local feed = env.feed(turret.x, turret.y, turret.z)
		turret.feed = if feed == feed then math.clamp(math.floor(feed), 0, Turrets.TIERS) else 0
		turret.fed = true
	end
	-- What is mounted.
	local optic = order.optic
	local opticSpec = Turrets.optic(spec, optic)
	local head = opticSpec.head
	local range = TurretRules.range(spec, optic)
	local fits = spec.optics[optic] == true
	local laser = fits and optic == LASER
	local scope = fits and optic == SCOPE
	local mounted = spec.muzzles[order.muzzle] == true
	local powered, blocked = order.powered == true, order.blocked == true
	local step = math.rad(spec.turn) / TurretRules.TICK_RATE
	local fired = false
	local status: number
	if not powered then
		-- It holds still and keeps its target while it lasts.
		if turret.target ~= 0 and env.mob(turret.target) == nil then
			setTarget(world, turret, 0)
		end
		status = STATUS.NO_POWER
	elseif blocked then
		setTarget(world, turret, 0)
		status = STATUS.BLOCKED
	else
		local px, py, pz = TurretRules.pivot(turret.x, turret.y, turret.z)
		local ax, ay, az, wantYaw, wantPitch, distance = 0, 0, 0, 0, 0, 0
		-- The target held: still there, in reach and, every SightTicks, in sight?
		if turret.target ~= 0 then
			local mob = env.mob(turret.target)
			if mob == nil then
				setTarget(world, turret, 0)
			else
				ax, ay, az = aimPoint(mob, head)
				wantYaw, wantPitch, distance = TurretRules.aim(px, py, pz, ax, ay, az)
				if distance > range or distance < s.MinRange or not TurretRules.inPitch(wantPitch) then
					setTarget(world, turret, 0)
				elseif tick - turret.sightAt >= s.SightTicks then
					turret.sightAt = tick
					turret.visible = not wall(world, turret, px, py, pz, ax, ay, az)
					if turret.visible then
						turret.seenAt = tick
					elseif tick - turret.seenAt >= s.LoseTicks then
						setTarget(world, turret, 0)
					end
				end
			end
		end
		-- No target: a scan when one is due and the tick's budget allows.
		if turret.target == 0 then
			local every = math.max(1, opticSpec.scan)
			if (tick + turret.phase) % every == 0 then
				turret.scanDue = true
			end
			if turret.scanDue and world.scans < s.MaxScansPerTick then
				turret.scanDue = false
				if scan(world, turret, range, head) then
					local mob = env.mob(turret.target)
					if mob == nil then
						setTarget(world, turret, 0)
					else
						ax, ay, az = aimPoint(mob, head)
						wantYaw, wantPitch, distance = TurretRules.aim(px, py, pz, ax, ay, az)
					end
				end
			end
		end
		if turret.target ~= 0 then
			turret.scanDue = false
			turret.yaw, turret.pitch = TurretRules.turn(turret.yaw, turret.pitch, wantYaw, wantPitch, step)
			if
				turret.visible
				and order.ready
				and order.armed
				and world.shots < s.MaxShotsPerTick
				and TurretRules.offAngle(turret.yaw, turret.pitch, wantYaw, wantPitch)
					<= math.rad(spec.settle) + 1e-9
			then
				shoot(world, turret, order, range, ax, ay, az, distance)
				fired = true
			end
			if tick - turret.shotAt < s.FiringTicks then
				status = STATUS.FIRING
			elseif not order.armed then
				status = STATUS.NO_AMMO
			else
				status = STATUS.TARGETING
			end
		else
			-- Idle: level again at the turn rate, the yaw held.
			local _, pitch = TurretRules.turn(turret.yaw, turret.pitch, turret.yaw, 0, step)
			turret.pitch = pitch
			if order.lure and order.armed then
				lure(world, turret)
			end
			status = if order.ammo < 1 then STATUS.NO_AMMO else STATUS.NO_TARGET
		end
	end
	local tracking = turret.target ~= 0 and powered and not blocked
	turret.flags = (if powered then Flag.Powered else 0)
		+ (if status == STATUS.FIRING then Flag.Firing else 0)
		+ (if blocked then Flag.Blocked else 0)
		+ (if laser then Flag.Laser else 0)
		+ (if scope then Flag.Scope else 0)
		+ (if mounted then Flag.Suppressor else 0)
		+ (if tracking then Flag.Tracking else 0)
	local rounds = (if order.ammo == order.ammo then order.ammo else 0) - (if fired then 1 else 0)
	turret.ammo = math.clamp(math.floor(rounds), 0, 255)
	if recordDue(world, turret) then
		record(world, turret)
	end
	out.status, out.fired, out.tracking, out.feed = status, fired, tracking, turret.feed
	return out
end

--[[
	The Service (Shared/Turrets/Types): one turret's machine tick (see the header). An order for a
	block that is no turret is answered from the order alone (No power, Blocked, No ammo, No
	target; nothing kept).
]]
function TurretWorld.step(world: World, order: Order, out: Outcome): Outcome
	local start = os.clock()
	if order.tick ~= world.tick then
		beginTick(world, order.tick)
	end
	local spec = Turrets.spec(order.block)
	local answer = if spec then stepTurret(world, order, out, spec) else fromOrder(order, out)
	world.ms += (os.clock() - start) * 1000
	return answer
end

-- Block (x, y, z) changed from `old` to `new` (WorldServer.onChanged): a turret gone is forgotten.
function TurretWorld.blockChanged(world: World, x: number, y: number, z: number, _old: number, new: number)
	if y < 0 or y >= 1024 then
		return
	end
	local turret = world.turrets[Coords.posKey(x, y, z)]
	if turret and new ~= turret.block then
		forget(world, turret)
	end
end

-- This frame's shots (Net/WeaponSync records, origins at the muzzles): lent until the next step.
function TurretWorld.takeShots(world: World): { WeaponSync.Shot }
	local list, pool = world.shotList, world.shotPool
	table.clear(list)
	for i = 1, world.shotCount do
		list[i] = pool[i]
	end
	world.shotCount = 0
	return list
end

-- The Turrets records that changed since they were last taken: lent until the next step.
function TurretWorld.takeRecords(world: World): { Protocol.TurretRecord }
	local list = world.recordList
	table.clear(list)
	for _, turret in world.queue do
		turret.queued = false
		if not turret.removed then
			table.insert(list, turret.record)
		end
	end
	table.clear(world.queue)
	return list
end

-- The records of chunk (cx, cz)'s turrets that are not idle (sent with its edit list): new tables.
function TurretWorld.chunkRecords(world: World, cx: number, cz: number): { Protocol.TurretRecord }
	local found: { Protocol.TurretRecord } = {}
	local list = world.byChunk[Coords.chunkKey(cx, cz)]
	if list == nil then
		return found
	end
	for _, turret in list do
		if turret.target ~= 0 or turret.flags ~= 0 or turret.ammo ~= 0 or turret.pitch ~= 0 or turret.yaw ~= 0 then
			table.insert(found, {
				x = turret.x,
				y = turret.y,
				z = turret.z,
				yaw = turret.yaw,
				pitch = turret.pitch,
				target = turret.target,
				flags = turret.flags,
				ammo = turret.ammo,
			})
		end
	end
	return found
end

-- The simulation's counts (see Stats).
function TurretWorld.stats(world: World): Stats
	return {
		turrets = world.count,
		tracking = world.tracking,
		scans = world.scans,
		sights = world.sights,
		shots = world.shots,
		ms = world.ms,
	}
end

return TurretWorld
