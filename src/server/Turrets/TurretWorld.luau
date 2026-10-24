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
	             within FiringTicks of its last shot, No ammo unarmed while its cadence is ready
	             and no round is coming (it would fire now: with none held and its feed 0, by hand
	             or its line stopped bringing them, its record says Dry; a round held without a
	             shot's energy is No ammo too, not dry), else Targeting (waiting on its cadence, or
	             fed on its belt: a line slower than its cadence never shows No ammo); without one
	             No ammo with no round, else No target. Disabled is the kind's.
	  Feed       the feeder rule (`env.feed`) at its first tick and every FeedTicks after,
	             staggered by its cell; the Outcome's `feed` every tick.
	  Targets    only `env.hostiles`' and `env.mob`'s: never a player or an animal. The aim point
	             is the centre of its body box (Ballistics.mobBoxes), its head box's for a scoped
	             sniper (Shared/Turrets.optic `head`); a target is in reach when that point is
	             between MinRange and the range (TurretRules.range: a scope's factor, at most
	             MaxRange) of the pivot and within its type's pitch limits (TurretRules.inPitch:
	             below the Spec's pitchMin, SMG and rifle -60 degrees, sniper -51, is a dead
	             zone).
	  Scans      with no target, every ScanTicks (a Laser Sight's `scan`: 5) staggered by its
	             cell, at most MaxScansPerTick for every turret together (one over waits for the
	             next tick, the longest waiting first: of n due none waits more than
	             ceil(n / MaxScansPerTick) ticks; see Gate): the hostiles in reach (from the tick's
	             grid: hostiles hashed into 16-block columns with their body's aim point once a
	             machine tick, only when a turret scans or shoots, their head's once a tick a
	             scoped sniper scans; none killed this tick) ranked by TurretRules.score (distance
	             + 0.05 a degree to turn: one two blocks nearer but behind the gun loses; worked
	             out only for those near enough to rank), MaxSightChecks of them looked at
	             (FireRules.wallBetween's rule, on VoxelRaycast.distance: Shapes.sight's collision
	             boxes, so glass and leaves stop sight, torches and water don't, and a cell the
	             server does not hold stops it, as it stops the shot's trace; the answer the cast
	             from the pivot's, as the trace runs, so a line exactly through a cell's edge or
	             corner meets what a shot would, looked along from the candidate first where that
	             is sure: see sightCheck), the first in sight taken. Which: the scans make passes
	             down the ranking. Each looks, best first, at those its pass has not looked at yet
	             (by id: up to RECORD, 48, of those it looked at in vain; past them the walk's
	             floor, the last looked at in vain, so one come in between the 48th and the floor
	             waits for the next pass), and its best TOP_CHECKS (3) again once their last look
	             is RELOOK (2) scans old; none left, a new pass from the best; one taken ends it.
	             So one in sight is taken within ceil(r / MaxSightChecks) scans, r its rank among
	             those not looked at in the pass (a scan more when the best three come due on the
	             way): one come in by the gun with a horde hidden at a wall ranked above it at the
	             next scan or the one after, and before one in sight further down the ranking.
	             While the ranking holds, the k-th of a fresh pass is looked at within
	             ceil(k / 4.5) scans (6 a scan, less the best three every second scan); one looked
	             at in vain is looked at again in the next pass, or within RELOOK scans among the
	             best three.
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
	             at CREDIT, so none is lost; those waiting go first, so every turret gets its share).
	             The shot: from the pivot along the exact aim, spread by TurretRules.spread
	             (Ballistics.spreadDir: a Laser Sight halves the cone, a working Suppressor narrows
	             it); the round's flight (its velocity, range and falloff, zeroed at the aim's
	             distance, ending at the round's range x 2.5 or the turret's range + ExtraFlight,
	             the nearer), its damage x the type's damageScale; the hostiles near the flight its
	             only targets (FireRules.mobTarget's, filled into pooled tables; no lag
	             compensation), so a player or an animal in the line is flown through;
	             FireRules.blockRules(weapons, false): glass is never shattered, leaves are flown
	             through (PassLeaves); Ballistics.trace. A hit hurts through `env.hurt`
	             (Ballistics.damage: a head hit times ZombieHead, HelmetShare of that under a
	             helmet, through no armour; the bullet's knockback away from the turret); one it
	             kills (env.mob nil after) is gone for the tick's later scans and shots. One bullet
	             a shot (the turrets' rounds are single bullets).
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
	makes for it (its impacts, about 1 KB; a turret's pass record is made with it, sized for
	RECORD). `aimPoint`, `fillTarget`, `sightBlocked` and `sightCheck` are exported for the specs,
	which hold them to Ballistics.mobBoxes, FireRules.mobTarget, FireRules.wallBetween and the
	cast from the pivot, and RECORD, TOP_CHECKS and RELOOK for their model of the scans.
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
	-- it was in sight then; the tick its due scan and its shot have waited since for the
	-- tick's budget (math.huge: none waits).
	target: number,
	seenAt: number,
	sightAt: number,
	visible: boolean,
	scanSince: number,
	shotSince: number,
	-- Its scans so far, and their pass (see scan): the candidates looked at in vain in it (id:
	-- the scan of its last look; at most RECORD, the table sized for them when made) and how
	-- many; past those the walk's floor, the last looked at in vain (score and id; -math.huge:
	-- none), and the cover, the first the record could not hold (math.huge: none).
	scans: number,
	looked: { [number]: number },
	lookedCount: number,
	floorScore: number,
	floorId: number,
	coverScore: number,
	coverId: number,
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

--[[
	A budget every turret shares (MaxScansPerTick, MaxShotsPerTick), fairly: those refused one
	tick go first the next, oldest first, so of n waiting none waits more than ceil(n / budget)
	ticks. A request's age is the tick it has waited since and its turret's turn that tick
	(`ageOf`), so of those waiting since the same tick the last the machines tick are not always
	the last served. `waiting` holds this tick's refusals (their ages, the first `count`); from the
	last tick's, those older than `cutoff` go, then `quota` more of age `cutoff`, `reserved` of
	them still to come; the others only while the budget less those reserved allows.
]]
type Gate = {
	waiting: { number },
	count: number,
	cutoff: number,
	quota: number,
	reserved: number,
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
	-- This tick's counts and time (ms), the scans' and the shots' budgets.
	scans: number,
	sights: number,
	shots: number,
	ms: number,
	scanGate: Gate,
	shotGate: Gate,
	-- The tick's grid of hostiles (`gridTick`: the tick it was built for): the list env.hostiles
	-- fills, how many, each 16-block column's first index and each entry's next (0: the last),
	-- each one's body aim point, and its head's once a scoped sniper scans (`headTick`: the tick
	-- they were worked out for); the ids of those killed since it was built.
	gridTick: number,
	hostiles: { Target },
	hostileCount: number,
	heads: { [number]: number },
	nexts: { number },
	bodyX: { number },
	bodyY: { number },
	bodyZ: { number },
	headTick: number,
	headX: { number },
	headY: { number },
	headZ: { number },
	gone: { [number]: boolean },
	-- A scan's candidates (index into `hostiles`, distance, aim point, the scan of its last look
	-- this pass: 0 none; due again: the scan's `stamp`), the nearest (`rank`: distance,
	-- candidate), those it scored (candidate, score).
	candidates: { number },
	distances: { number },
	aimX: { number },
	aimY: { number },
	aimZ: { number },
	looks: { number },
	due: { number },
	stamp: number,
	nearest: { number },
	nearestAt: { number },
	picks: { number },
	scores: { number },
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
	-- but for it (a shot's trace stops at a nil cell itself); `look`: `sight` with a nil cell
	-- as UNKNOWN, for sight checks.
	ownX: number,
	ownY: number,
	ownZ: number,
	sight: (x: number, y: number, z: number) -> number?,
	look: (x: number, y: number, z: number) -> number?,
	-- Shapes.sight of `sight`: which blocks stop a ray, and their outlines (UNKNOWN stops it as
	-- a whole block); `edge`: `outline` keeping the cell it was asked for and whether it is
	-- whole (sightCheck's look from the candidate's end).
	stops: (id: number) -> boolean,
	outline: (id: number, x: number, y: number, z: number) -> { number }?,
	edge: (id: number, x: number, y: number, z: number) -> { number }?,
	hitX: number,
	hitY: number,
	hitZ: number,
	whole: boolean,
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
-- What a sight check reads in a cell the server does not hold (nil): it stops sight, as the
-- shot's trace stops there (Ballistics.trace), so no round goes into terrain it doesn't know.
local UNKNOWN = -1
-- The grid's columns (blocks).
local GRID = 16
-- Shots records kept for takeShots at most (a glue that never takes them loses no more memory).
local MAX_PENDING_SHOTS = 1024
-- How far inside a cell (blocks along the line) sightCheck's look from the candidate's end must
-- find the line for the cast from the pivot to meet that cell too (theirs differ only by rounding).
local EDGE = 1e-6
-- Blocks a shot's candidates may stand beyond its flight's box, and their box's centre from its
-- chord beyond half their height and width (the arc's sag, a head reaching out).
local FLIGHT_MARGIN = 2
local FLIGHT_REACH = 0.75
-- The coordinates a Shots message may carry (Net/WeaponSync): sideways, and up or down.
local LIMIT = Protocol.MAX_COORDINATE + 64
local Y_LIMIT = 4096
-- The candidates a scans' pass keeps by id (past them, the walk's floor), and the best of the
-- ranking looked at again in a pass (at most half of MaxSightChecks) once their last look is
-- RELOOK scans old.
local RECORD = 48
local TOP_CHECKS = 3
local RELOOK = 2
-- What a turn adds to a candidate's score a radian (TurretRules.score, blocks).
local PER_RADIAN = TurretRules.score(0, math.pi) / math.pi
local HALF_PI = math.pi / 2
-- Items whose flags the records carry.
local LASER = rawget(Items.id :: any, "LaserSight") :: number?
local SCOPE = rawget(Items.id :: any, "RifleScope") :: number?

local TurretWorld = {}

-- (The scans' pass, for the specs.)
TurretWorld.RECORD = RECORD
TurretWorld.TOP_CHECKS = TOP_CHECKS
TurretWorld.RELOOK = RELOOK

--[[ The world ]]

function TurretWorld.new(env: Env): World
	local world: World
	local function sight(x: number, y: number, z: number): number?
		if x == world.ownX and y == world.ownY and z == world.ownZ then
			return AIR
		end
		return world.env.getBlock(x, y, z)
	end
	local function look(x: number, y: number, z: number): number?
		local block = sight(x, y, z)
		return if block == nil then UNKNOWN else block
	end
	local shapeStops, shapeOutline = Shapes.sight(sight)
	local function stops(id: number): boolean
		return id == UNKNOWN or shapeStops(id)
	end
	local function outline(id: number, x: number, y: number, z: number): { number }?
		if id == UNKNOWN then
			return nil
		end
		return shapeOutline(id, x, y, z)
	end
	local function edge(id: number, x: number, y: number, z: number): { number }?
		local box = outline(id, x, y, z)
		world.hitX, world.hitY, world.hitZ, world.whole = x, y, z, box == nil
		return box
	end
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
		scanGate = { waiting = {}, count = 0, cutoff = -math.huge, quota = 0, reserved = 0 },
		shotGate = { waiting = {}, count = 0, cutoff = -math.huge, quota = 0, reserved = 0 },
		gridTick = -math.huge,
		hostiles = {},
		hostileCount = 0,
		heads = {},
		nexts = {},
		bodyX = {},
		bodyY = {},
		bodyZ = {},
		headTick = -math.huge,
		headX = {},
		headY = {},
		headZ = {},
		gone = {},
		candidates = {},
		distances = {},
		aimX = {},
		aimY = {},
		aimZ = {},
		looks = {},
		due = {},
		stamp = 0,
		nearest = {},
		nearestAt = {},
		picks = {},
		scores = {},
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
		look = look,
		stops = stops,
		outline = outline,
		edge = edge,
		hitX = 0,
		hitY = 0,
		hitZ = 0,
		whole = false,
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

--[[ The budgets (see Gate) ]]

-- A request's age: the tick it has waited since, and its turret's turn that tick (0..1: the
-- turrets' spread evenly, each one's moving on every tick).
local function ageOf(turret: Turret, since: number): number
	return since + (turret.phase * 0.6180339887 + since * 0.7548776662) % 1
end

-- A new tick's turns, from the last tick's refusals, `most` going a tick.
local function openGate(gate: Gate, tick: number, most: number)
	local waiting, count = gate.waiting, gate.count
	if most < 1 then
		gate.cutoff, gate.quota, gate.reserved = -math.huge, 0, 0
	elseif count <= most then
		-- (All of them go, before any new one.)
		gate.cutoff, gate.quota, gate.reserved = tick, 0, count
	else
		-- (The `most` oldest go: those older than the most-th, and of its age what is left.)
		table.sort(waiting)
		local cutoff = waiting[most]
		local older = 0
		while waiting[older + 1] < cutoff do
			older += 1
		end
		gate.cutoff, gate.quota, gate.reserved = cutoff, most - older, most
	end
	table.clear(waiting)
	gate.count = 0
end

-- May a request of age `age` go, `used` of the tick's `most` gone? (Counted when it may.)
local function admit(gate: Gate, age: number, used: number, most: number): boolean
	if used >= most then
		return false
	elseif age < gate.cutoff or (age == gate.cutoff and gate.quota > 0) then
		if age == gate.cutoff then
			gate.quota -= 1
		end
		gate.reserved = math.max(gate.reserved - 1, 0)
		return true
	end
	return used + gate.reserved < most
end

-- A request of age `age` was refused: it goes first next tick.
local function refuse(gate: Gate, age: number)
	gate.count += 1
	gate.waiting[gate.count] = age
end

-- A new machine tick: its counts start over, the budgets go to those that waited, its grid is
-- stale, old lure cells go.
local function beginTick(world: World, tick: number)
	world.tick = tick
	world.scans, world.sights, world.shots, world.ms = 0, 0, 0, 0
	local s = world.env.settings.turrets
	openGate(world.scanGate, tick, s.MaxScansPerTick)
	openGate(world.shotGate, tick, s.MaxShotsPerTick)
	local lure = s.Lure
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

-- A table whose hash part holds `n` keys without growing (filled, then cleared: table.clear keeps
-- the room).
local function presized(n: number): { [number]: number }
	local made = {}
	for i = 1, n do
		made[-i] = 0
	end
	table.clear(made)
	return made
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
		scanSince = math.huge,
		shotSince = math.huge,
		scans = 0,
		looked = presized(RECORD),
		lookedCount = 0,
		floorScore = -math.huge,
		floorId = 0,
		coverScore = math.huge,
		coverId = 0,
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
	local bodyX, bodyY, bodyZ = world.bodyX, world.bodyY, world.bodyZ
	table.clear(heads)
	table.clear(world.gone)
	for i = 1, n do
		local mob = list[i]
		local key = Coords.chunkKey(mob.x // GRID, mob.z // GRID)
		nexts[i] = heads[key] or 0
		heads[key] = i
		bodyX[i], bodyY[i], bodyZ[i] = aimPoint(mob, false)
	end
end

--[[
	Is a block between (ax, ay, az) and (bx, by, bz), cell (cx, cy, cz) read as air and a cell
	the server does not hold (nil) as a block? FireRules.wallBetween's rule (Shapes.sight's
	collision boxes) on VoxelRaycast.distance, which makes no Hit: a sight check allocates
	nothing, a blocked one neither. (For the specs too, which hold it to FireRules.wallBetween.)
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
	local hit = VoxelRaycast.distance(ax, ay, az, dx, dy, dz, distance, world.look, world.stops, world.outline)
	return hit ~= nil and hit < distance - 1e-6
end
TurretWorld.sightBlocked = sightBlocked

-- Where the line from `o` along `u` (a unit vector's part) is inside the slab lo..lo + 1, within
-- `enter`..`leave` (none: `enter` past `leave`). Parallel to it, inside means the cell the casts
-- stay in.
local function inSlab(o: number, u: number, lo: number, enter: number, leave: number): (number, number)
	if u == 0 then
		return if math.floor(o) == lo then enter else math.huge, leave
	end
	local a, b = (lo - o) / u, (lo + 1 - o) / u
	if a > b then
		a, b = b, a
	end
	return math.max(enter, a), math.min(leave, b)
end

--[[
	A sight check: sightBlocked from (ax, ay, az) to (bx, by, bz), cell (cx, cy, cz) air, the same
	answer, cheaper where it matters. The cast from (ax, ay, az), the pivot, is the shot's trace's
	way (a line exactly through a cell's edge or corner meets the cells the trace meets, whichever
	way the point lies), but it walks every cell from the gun to a far wall. So it looks along from
	the point first (the wall a horde presses on stands near it: a hidden one's ray ends after a
	block or two): a whole cell that stops sight there, which the line goes through more than EDGE
	inside and leaves or ends in more than EDGE before the point, is met by the cast from the pivot
	too (or one before it), so the answer is blocked; anything else (met by an edge or a corner,
	part of a cell, nothing) is the cast from the pivot's. (For the specs too, which hold it to
	sightBlocked on lines through cells' corners.)
]]
local function sightCheck(
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
	if distance >= 1e-6 then
		local back = VoxelRaycast.distance(bx, by, bz, -dx, -dy, -dz, distance, world.look, world.stops, world.edge)
		if back ~= nil and world.whole then
			-- (Where the line from the pivot is inside the cell met.)
			local ux, uy, uz = dx / distance, dy / distance, dz / distance
			local enter, leave = inSlab(ax, ux, world.hitX, 0, distance)
			enter, leave = inSlab(ay, uy, world.hitY, enter, leave)
			enter, leave = inSlab(az, uz, world.hitZ, enter, leave)
			if leave - enter > EDGE and enter < distance - 1e-6 - EDGE then
				return true
			end
		end
	end
	return sightBlocked(world, cx, cy, cz, ax, ay, az, bx, by, bz)
end
TurretWorld.sightCheck = sightCheck

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
	return sightCheck(world, turret.x, turret.y, turret.z, px, py, pz, x, y, z)
end

-- Candidate k's score from the pivot (px, py, pz), the gun along (gx, gy, gz).
local function scoreOf(
	world: World,
	k: number,
	px: number,
	py: number,
	pz: number,
	gx: number,
	gy: number,
	gz: number
): number
	local d = world.distances[k]
	local along = ((world.aimX[k] - px) * gx + (world.aimY[k] - py) * gy + (world.aimZ[k] - pz) * gz) / d
	return TurretRules.score(d, math.acos(math.clamp(along, -1, 1)))
end

-- Is (score, id) ranked after (otherScore, otherId) (TurretRules.score, then the id)?
local function after(score: number, id: number, otherScore: number, otherId: number): boolean
	return score > otherScore or (score == otherScore and id > otherId)
end

--[[
	Scores the `n` candidates of the turret's scan that may be among its best `most`, into `picks`
	and `scores`; returns how many, and how many of them are not just due again. With `pass` only
	those its pass may look at (see scan): not looked at in it yet, before the cover or after the
	floor, or due again; else every one. A score is at least the distance, so none further than
	the worst score of the `most` nearest surely among them needs its angle worked out (one acos,
	from the gun's direction: TurretRules.offAngle's angle), nor one whose angle's chord (cheap:
	the angle is between it and pi / 2 times it) puts it past the cut or surely between the cover
	and the floor.
]]
local function rank(world: World, turret: Turret, n: number, most: number, pass: boolean): (number, number)
	if most < 1 then
		return 0, 0
	end
	local list, candidates, distances = world.hostiles, world.candidates, world.distances
	local aimX, aimY, aimZ = world.aimX, world.aimY, world.aimZ
	local looks, due, stamp = world.looks, world.due, world.stamp
	local floorScore, floorId, coverScore, coverId = -math.huge, 0, math.huge, 0
	if pass then
		floorScore, floorId, coverScore, coverId = turret.floorScore, turret.floorId, turret.coverScore, turret.coverId
	end
	local px, py, pz = TurretRules.pivot(turret.x, turret.y, turret.z)
	local gx, gy, gz = TurretRules.direction(turret.yaw, turret.pitch)
	-- The `most` nearest of those surely among them (not looked at and past the floor, or due).
	local nearest, nearestAt, found = world.nearest, world.nearestAt, 0
	for k = 1, n do
		local d = distances[k]
		if
			(not pass or due[k] == stamp or (looks[k] == 0 and d > floorScore))
			and (found < most or d < nearest[most])
		then
			local j = if found < most then found + 1 else most
			found = math.max(found, j)
			while j > 1 and nearest[j - 1] > d do
				nearest[j], nearestAt[j] = nearest[j - 1], nearestAt[j - 1]
				j -= 1
			end
			nearest[j], nearestAt[j] = d, k
		end
	end
	local cut = math.huge
	if found >= most then
		cut = 0
		for j = 1, most do
			cut = math.max(cut, scoreOf(world, nearestAt[j], px, py, pz, gx, gy, gz))
		end
	end
	-- Those within the cut, which falls to the `most`-th best score found so far (`nearest` now).
	local picks, scores = world.picks, world.scores
	local count, fresh, held = 0, 0, 0
	for k = 1, n do
		local d = distances[k]
		local again = pass and due[k] == stamp
		if d <= cut and (again or not pass or looks[k] == 0) then
			-- (Not looked at, or due; within the cut and not surely between the cover and the
			-- floor by its angle's bounds: scoreOf's sums.)
			local along = ((aimX[k] - px) * gx + (aimY[k] - py) * gy + (aimZ[k] - pz) * gz) / d
			along = math.clamp(along, -1, 1)
			local chord = math.sqrt(2 - 2 * along)
			if
				d + PER_RADIAN * chord - 1e-9 > cut
				or not (again or d + PER_RADIAN * HALF_PI * chord + 1e-9 >= floorScore or d <= coverScore)
			then
				continue
			end
			local score = TurretRules.score(d, math.acos(along))
			local id = list[candidates[k]].id
			if
				score <= cut
				and (again or after(coverScore, coverId, score, id) or after(score, id, floorScore, floorId))
			then
				count += 1
				picks[count], scores[count] = k, score
				if not again then
					fresh += 1
				end
				local j = if held < most then held + 1 else most
				held = math.max(held, j)
				while j > 1 and nearest[j - 1] > score do
					nearest[j] = nearest[j - 1]
					j -= 1
				end
				nearest[j] = score
				if held == most then
					cut = math.min(cut, nearest[most])
				end
			end
		end
	end
	return count, fresh
end

-- A new pass of the turret's scans: nothing looked at in it.
local function newPass(turret: Turret)
	table.clear(turret.looked)
	turret.lookedCount = 0
	turret.floorScore, turret.floorId = -math.huge, 0
	turret.coverScore, turret.coverId = math.huge, 0
end

--[[
	Picks out, in order, the best `most` of the `count` candidates `rank` scored (each found by a
	pass over them: nothing sorted, nothing made): with `look` the turret's sight checks (the first
	in sight becomes the target, a new pass starts; one hidden is kept as looked at in vain), else
	those of its best few due again marked (their last look RELOOK scans old). True when one was
	taken.
]]
local function lookAt(world: World, turret: Turret, count: number, most: number, look: boolean): boolean
	local list, candidates = world.hostiles, world.candidates
	local aimX, aimY, aimZ = world.aimX, world.aimY, world.aimZ
	local picks, scores, looks, due = world.picks, world.scores, world.looks, world.due
	local px, py, pz = TurretRules.pivot(turret.x, turret.y, turret.z)
	local now, looked = turret.scans, turret.looked
	for _ = 1, math.min(count, most) do
		local best, bestScore, bestId = 0, math.huge, 0
		for m = 1, count do
			local score = scores[m]
			if score <= bestScore and score < math.huge then
				local id = list[candidates[picks[m]]].id
				if score < bestScore or id < bestId then
					best, bestScore, bestId = m, score, id
				end
			end
		end
		if best == 0 then
			break
		end
		scores[best] = math.huge
		local k = picks[best]
		if not look then
			if looks[k] > 0 and now - looks[k] >= RELOOK then
				due[k] = world.stamp
			end
		elseif not wall(world, turret, px, py, pz, aimX[k], aimY[k], aimZ[k]) then
			setTarget(world, turret, bestId)
			turret.seenAt, turret.sightAt, turret.visible = world.tick, world.tick, true
			newPass(turret)
			return true
		elseif looked[bestId] ~= nil or turret.lookedCount < RECORD then
			-- (Looked at in vain: kept, or its last look moved on.)
			if looked[bestId] == nil then
				turret.lookedCount += 1
			end
			looked[bestId] = now
		elseif turret.coverScore == math.huge then
			-- (The record full: the cover and the walk's floor from here.)
			turret.coverScore, turret.coverId = bestScore, bestId
			turret.floorScore, turret.floorId = bestScore, bestId
		elseif after(bestScore, bestId, turret.floorScore, turret.floorId) then
			turret.floorScore, turret.floorId = bestScore, bestId
		else
			turret.coverScore, turret.coverId = bestScore, bestId
		end
	end
	return false
end

--[[
	A scan (see the header): the best hostile in reach and in sight becomes the target. True when
	one did.
]]
local function scan(world: World, turret: Turret, range: number, head: boolean): boolean
	local s = world.env.settings.turrets
	ensureGrid(world)
	world.scans += 1
	world.stamp += 1
	turret.scans += 1
	local px, py, pz = TurretRules.pivot(turret.x, turret.y, turret.z)
	local list, heads, nexts, gone = world.hostiles, world.heads, world.nexts, world.gone
	local pointX, pointY, pointZ = world.bodyX, world.bodyY, world.bodyZ
	if head then
		-- (The heads' aim points once a tick, for every scoped sniper's scans.)
		pointX, pointY, pointZ = world.headX, world.headY, world.headZ
		if world.headTick ~= world.tick then
			world.headTick = world.tick
			for i = 1, world.hostileCount do
				pointX[i], pointY[i], pointZ[i] = aimPoint(list[i], true)
			end
		end
	end
	local candidates, distances = world.candidates, world.distances
	local aimX, aimY, aimZ, looks = world.aimX, world.aimY, world.aimZ, world.looks
	local looked = turret.looked
	local far, near = range * range, s.MinRange * s.MinRange
	-- (TurretRules.inPitch's limits for its type, as the sines of the pitch: no angle worked out.)
	local lowest, highest = TurretRules.pitchLimits(turret.spec)
	local low = math.sin(math.clamp(lowest - 1e-9, -HALF_PI, HALF_PI))
	local high = math.sin(math.clamp(highest + 1e-9, -HALF_PI, HALF_PI))
	local killed = next(gone) ~= nil
	local n = 0
	for cx = (px - range) // GRID, (px + range) // GRID do
		for cz = (pz - range) // GRID, (pz + range) // GRID do
			local i = heads[Coords.chunkKey(cx, cz)] or 0
			while i ~= 0 do
				local mob = list[i]
				if not (killed and gone[mob.id]) then
					local x, y, z = pointX[i], pointY[i], pointZ[i]
					local dx, dy, dz = x - px, y - py, z - pz
					local d2 = dx * dx + dy * dy + dz * dz
					if d2 <= far and d2 >= near then
						local distance = math.sqrt(d2)
						if dy >= distance * low and dy <= distance * high then
							n += 1
							candidates[n], distances[n] = i, distance
							aimX[n], aimY[n], aimZ[n] = x, y, z
							looks[n] = looked[mob.id] or 0
						end
					end
				end
				i = nexts[i]
			end
		end
	end
	local most = s.MaxSightChecks
	-- Its best few due again (their last look RELOOK scans old) ...
	local top = math.min(TOP_CHECKS, most // 2)
	if top > 0 and turret.lookedCount > 0 then
		lookAt(world, turret, (rank(world, turret, n, top, false)), top, false)
	end
	-- ... and, best first, those its pass has not looked at; none left, a new pass from the best.
	local count, fresh = rank(world, turret, n, most, true)
	if fresh == 0 and (turret.lookedCount > 0 or turret.coverScore < math.huge) then
		newPass(turret)
		count = rank(world, turret, n, most, false)
	end
	return lookAt(world, turret, count, most, true)
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
	local list, heads, nexts, gone = world.hostiles, world.heads, world.nexts, world.gone
	for cx = x0 // GRID, x1 // GRID do
		for cz = z0 // GRID, z1 // GRID do
			local i = heads[Coords.chunkKey(cx, cz)] or 0
			while i ~= 0 do
				local mob = list[i]
				local kind = mob.kind
				local x, y, z = mob.x, mob.y, mob.z
				if
					x >= x0
					and x <= x1
					and z >= z0
					and z <= z1
					and y <= y1
					and y + kind.height >= y0
					and not gone[mob.id]
				then
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
	-- The hit (one it kills is gone for the tick's later scans and shots).
	if final and final.kind == "mob" and final.target then
		local amount = Ballistics.damage(flight, final, weapons)
		local id = final.target.key
		if amount > 0 then
			env.hurt(id, amount, px, pz, FireRules.knockback(1, 1, weapons), final.head)
			if env.mob(id) == nil then
				world.gone[id] = true
			end
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
	local fired, dry = false, false
	local status: number
	-- (A shot waits on only while it is refused tick after tick.)
	local shotSince = turret.shotSince
	turret.shotSince = math.huge
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
				if distance > range or distance < s.MinRange or not TurretRules.inPitch(wantPitch, spec) then
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
		-- No target: a scan when one is due and the tick's budget allows (oldest due first).
		if turret.target == 0 then
			local every = math.max(1, opticSpec.scan)
			if (tick + turret.phase) % every == 0 then
				turret.scanSince = math.min(turret.scanSince, tick)
			end
			local since = turret.scanSince
			if since <= tick then
				local age = ageOf(turret, since)
				if admit(world.scanGate, age, world.scans, s.MaxScansPerTick) then
					turret.scanSince = math.huge
					if scan(world, turret, range, head) then
						local mob = env.mob(turret.target)
						if mob == nil then
							setTarget(world, turret, 0)
						else
							ax, ay, az = aimPoint(mob, head)
							wantYaw, wantPitch, distance = TurretRules.aim(px, py, pz, ax, ay, az)
						end
					end
				else
					refuse(world.scanGate, age)
				end
			end
		end
		if turret.target ~= 0 then
			turret.scanSince = math.huge
			turret.yaw, turret.pitch = TurretRules.turn(turret.yaw, turret.pitch, wantYaw, wantPitch, step)
			-- A shot when the tick's budget allows (the longest waiting first).
			if
				turret.visible
				and order.ready
				and order.armed
				and TurretRules.offAngle(turret.yaw, turret.pitch, wantYaw, wantPitch)
					<= math.rad(spec.settle) + 1e-9
			then
				local since = math.min(shotSince, tick)
				local age = ageOf(turret, since)
				if admit(world.shotGate, age, world.shots, s.MaxShotsPerTick) then
					shoot(world, turret, order, range, ax, ay, az, distance)
					fired = true
				else
					turret.shotSince = since
					refuse(world.shotGate, age)
				end
			end
			if tick - turret.shotAt < s.FiringTicks then
				status = STATUS.FIRING
			elseif not order.armed and order.ready and (order.ammo >= 1 or turret.feed == 0) then
				-- (It would fire now: dry with no round and none coming, by hand or its line
				-- stopped. A fed one waiting on its belt, or on its cadence, is Targeting.)
				status = STATUS.NO_AMMO
				dry = order.ammo < 1
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
		+ (if dry then Flag.Dry else 0)
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
