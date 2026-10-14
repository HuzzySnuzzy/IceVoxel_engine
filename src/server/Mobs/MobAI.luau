--!strict
--!native
--[[
	What mobs want to do (pure, run by Mobs/MobWorld once a tick for every live, ticking mob):
	Minecraft 1.20.1's goals cut down to direct steering, no path finding. Each tick a mob picks a
	facing and how hard it walks along it (`forward`, Shared/Entities/MobPhysics' input) and
	whether it jumps.

	  Float      in water deeper than 0.4 (FloatGoal; lava too) it jumps 4 ticks in 5, so it swims
	             up and stays at the surface.
	  Wander     idle, one tick in 120 (RandomStrollGoal's interval) it picks a spot 3-10 blocks
	             away and walks there at its `wander` speed, giving up after 100 ticks or when
	             the way is blocked; between strolls it stands (idle pauses of ~6 s).
	  Panic      creatures hurt by anything (PanicGoal) run at their `panic` speed for 3-5 s,
	             away from whoever hurt them, picking a new spot whenever they get there.
	  Steering   straight at the spot (or the target): it faces it and walks; a wall in the way
	             is jumped (a block up: Minecraft's JumpControl). It never
	             walks off a drop of more than 3 blocks (the path finder's max fall), nor into
	             lava, fire, a campfire, oil or fuel, nor where the ground isn't loaded: it stops
	             (a stroll ends there). A zombie pressed against the cells ahead lines up with the
	             nearest gap in them its box fits through within a block across (a doorway, the
	             13/16 an open door leaves: Minecraft's path finder walks cell centres, which a
	             brute's 0.75 wide box would scrape the door on).
	  Targets    monsters notice the nearest living survival or adventure player within `follow`
	             (24 for most zombies) blocks they can see (NearestAttackableTargetGoal with
	             mustSee; creative and spectator players are never targets), looking again every 10
	             ticks, and hunt them until they are out of range, can't be hurt any more, or out
	             of sight for 60 ticks (unseenMemoryTicks). A monster hurt by a player hunts that
	             player (HurtByTargetGoal).
	  Melee      zombies hit a target within Minecraft's reach (MeleeAttackGoal: the distance
	             between them under sqrt((2 x width)^2 + target width): a zombie 1.43) that they
	             can see, every 20 ticks, for their `attack` damage with a 0.4 knockback; the
	             swing shows for 8 ticks (`swing`: the Mobs message's Attack flag).

	The zombie apocalypse's rules (MobList `zombie` kinds), in this order each tick:
	  Leave      a zombie the director sent away (`leave` ticks, Mobs/ZombieDirector's leave
	             rounds) walks away from the nearest player at its `wander` speed, towards a spot
	             16 blocks further out on the line from that player (a new one when it gets there
	             or the way is blocked), and does nothing else; MobWorld removes it once it is far
	             enough and out of sight. A player's hit calls it back (MobAI.hurt).
	  Thinning   an idle or strolling zombie (no target, hunt, noise or block in hand) with no
	             player within Apocalypse.Zombies.ThinDistance (32) thinks only every 4th tick
	             (by its age and id); on the others it stands (physics still runs), so it can't
	             walk on unchecked off a ledge or into lava.
	  Sight      while chasing, the line of sight to the target is checked every SightInterval
	             (3) ticks, staggered by id, and kept (`visible`); the unseen count goes up in
	             those steps, except while it breaks a block (BreakDoorGoal needs no sight): then
	             the target is not forgotten.
	  Noise      a zombie with no target hears every noise of the tick (Mobs/Mobs hands it
	             Apocalypse/NoiseBus's, louder at night, muffled by rain) within the noise's
	             radius times its `hearing`: it takes the loudest (by how far inside that reach it
	             is), unless it already investigates a louder one, goes to look (`investigate`, at
	             0.9 of its chase speed, to a spot within 1.5 blocks of the noise picked by its id,
	             so a crowd spreads out) for Noise.InvestigateTicks, and looks for a player at
	             once. There it strolls about for up to 60 ticks, then stands.
	  Hunt       through a blood moon the director gives a zombie a player to hunt (`hunt`, and
	             `persistent`): it steers at them with no need to see them; seen, it is an
	             ordinary chase that keeps the hunt, kept up to Zombies.HuntKeep (56) blocks
	             away. A hunter that closed less than a block on its player in Leave.StuckTicks
	             (400) and isn't breaking or fighting gives up and leaves.
	  Breaking   blocked (walking into a wall for 10 ticks with less than 0.05 blocks of progress a
	             tick; the cell ahead at its feet or head has a collision shape: a closed door
	             counts; it starts only standing on the ground, so a zombie jumping at a cliff
	             judges levels and cells from its feet on the floor) by blocks it can break (Blocks.zombieBreak: all of the blocked cells; an
	             iron block or a chest in the way stops it), and only when what it heads for is
	             near and level with it (a target within Zombies.BreakReach (8) blocks
	             horizontally, a hunted player within HuntBreakReach (16), the noise it
	             investigates within BreakReach; and their feet from 1 block below its own to 2
	             above, so it never digs towards a player on a cliff or under the ground): it
	             faces the softer cell, stands and hits it, `breakPower` a tick on the block's
	             shared damage (MobWorld.damageBlock: two zombies on a door break it in half the
	             time; a door's halves share it), with a thud every Breaking.HitInterval ticks,
	             until it gives way (MobWorld reports it; Mobs/Mobs removes the block, both halves
	             of a door, and drops nothing). It stops when the block changes, it is pushed more
	             than 1.5 blocks away, or what it went for is gone.
	  Screamer   a screamer that gains a target with its cooldown over shrieks for 40 ticks
	             (standing, facing it): the sound, and a noise of its `scream` radius (48) that
	             sends every zombie in reach to look, at most every `scream.cooldown` (400) ticks.
	             The shriek counts down every tick whatever the screamer does (sent away or
	             thinned too), so it never shows longer than 40 ticks.
	With Config.Apocalypse.Enabled false a zombie hears nothing, breaks nothing and is never
	hunted or sent away (Mobs/Mobs passes no noises, and no director runs).

	The mob's world gives it what it needs: the blocks, the players (feet, eyes, game modes, alive),
	the day time and the open sky, random numbers and the events it emits (hits on players, sounds,
	block hits and breaks, noises).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Shapes = require(Shared.Blocks.Shapes)
local Config = require(Shared.Config)
local Fluids = require(Shared.Fluids)
local GameMode = require(Shared.GameMode)
local Hash = require(Shared.Util.Hash)
local MobList = require(Shared.Entities.MobList)
local MobPhysics = require(Shared.Entities.MobPhysics)
local Combat = require(Shared.Entities.Combat)
local VoxelRaycast = require(Shared.World.VoxelRaycast)

export type Goal = "idle" | "wander" | "panic" | "chase" | "investigate" | "leave"

export type State = {
	goal: Goal,
	-- Where a stroll, a panic, an investigation or a leaving walk heads (blocks) and the ticks it
	-- has left.
	tx: number,
	tz: number,
	timer: number,
	-- The player hunted (a key of the world's players) and ticks it was out of sight.
	target: any?,
	unseen: number,
	-- Ticks to the next melee hit.
	cooldown: number,
	-- (Zombies.) The player hunted through a blood moon (a key; Mobs/ZombieDirector), and ticks
	-- left walking away (the director's leave rounds; 0: none).
	hunt: any?,
	leave: number,
	-- Was the target in sight at the last check?
	visible: boolean,
	-- The cell it is breaking (nil: none), the block there when it began, ticks it has hit it.
	bx: number?,
	by: number,
	bz: number,
	bblock: number,
	breakTicks: number,
	-- Ticks the Attack flag shows after a swing; the screamer's shriek and its cooldown.
	swing: number,
	scream: number,
	screamCooldown: number,
	-- Walking into a wall: ticks blocked, and where it was a tick ago.
	blockedTicks: number,
	lastX: number,
	lastZ: number,
	-- A hunter's progress: ticks since the last check and its distance then (-1: none yet).
	progressTimer: number,
	progressDistance: number,
	-- The noise it investigates and how loud it was (reach - distance).
	nx: number,
	ny: number,
	nz: number,
	heard: number,
}

-- A player as mobs see them (blocks: feet, eye height above them).
export type PlayerView = {
	key: any,
	x: number,
	y: number,
	z: number,
	eye: number,
	mode: string,
	alive: boolean,
}

-- A noise zombies hear this tick (server Apocalypse/NoiseBus): where, and how far it carries.
export type Noise = { x: number, y: number, z: number, radius: number }

local MobAI = {}

-- Minecraft's numbers.
MobAI.STROLL_INTERVAL = 120
MobAI.STROLL_MIN = 3
MobAI.STROLL_RANGE = 10
MobAI.STROLL_TICKS = 100
MobAI.PANIC_TICKS = 60
MobAI.PANIC_EXTRA = 40
MobAI.RETARGET_INTERVAL = 10
MobAI.UNSEEN_MEMORY = 60
MobAI.MELEE_COOLDOWN = 20
MobAI.MAX_FALL = 3
MobAI.FLOAT_CHANCE = 0.8
-- The zombie apocalypse's.
MobAI.SWING_TICKS = 8
MobAI.SCREAM_TICKS = 40
MobAI.SCREAM_SOUND = "entity.zombie_screamer.scream"
-- Blocked: this many ticks against a wall with less than BLOCKED_PROGRESS blocks a tick.
MobAI.BLOCKED_TICKS = 10
MobAI.BLOCKED_PROGRESS = 0.05
-- Pushed this far (blocks, horizontally from the cell's centre) from the block it breaks, it stops.
MobAI.BREAK_LEAVE = 1.5
-- An investigation's spot: within this many blocks of the noise (by the zombie's id); it arrives
-- this close to it, then strolls about for STROLL_AFTER ticks.
MobAI.INVESTIGATE_SPREAD = 1.5
MobAI.ARRIVE = 1
MobAI.STROLL_AFTER = 60
MobAI.INVESTIGATE_SPEED = 0.9
-- Thinking every THIN_EVERY ticks when thinned; a leaving zombie heads LEAVE_LEG blocks out.
MobAI.THIN_EVERY = 4
MobAI.LEAVE_LEG = 16
-- A zombie pressed against a wall moves at most this far across its way to line up with a gap,
-- heading for a spot this far on.
MobAI.SQUEEZE_REACH = 1
MobAI.SQUEEZE_AHEAD = 0.2

local sqrt = math.sqrt
local atan2 = math.atan2
local floor = math.floor
local sin = math.sin
local cos = math.cos
local abs = math.abs

local Apocalypse = Config.Apocalypse
local Zombies = Apocalypse.Zombies
local EMPTY: { Noise } = table.freeze({})

local FIRE = Blocks.find("Fire")
local CAMPFIRE = Blocks.find("Campfire")
-- Fluids a mob won't walk into: those that hurt (lava) or are lava-like or explosive (oil, fuel);
-- water is fine.
local AVOIDED_FLUID: { [number]: boolean } = {}
for id, fluid in Fluids.list do
	AVOIDED_FLUID[id] = fluid.damage > 0 or fluid.physics == "lava" or fluid.name == "Fuel"
end

function MobAI.new(): State
	return {
		goal = "idle",
		tx = 0,
		tz = 0,
		timer = 0,
		target = nil,
		unseen = 0,
		cooldown = 0,
		hunt = nil,
		leave = 0,
		visible = false,
		bx = nil,
		by = 0,
		bz = 0,
		bblock = 0,
		breakTicks = 0,
		swing = 0,
		scream = 0,
		screamCooldown = 0,
		blockedTicks = 0,
		lastX = 0,
		lastZ = 0,
		progressTimer = 0,
		progressDistance = -1,
		nx = 0,
		ny = 0,
		nz = 0,
		heard = 0,
	}
end

-- Is `block` something a mob won't step into (fire, a campfire, lava, oil, fuel)?
function MobAI.hazard(block: number?): boolean
	if block == nil then
		return false
	end
	if block == FIRE or block == CAMPFIRE then
		return true
	end
	return AVOIDED_FLUID[buffer.readu8(Fluids.blockLut, block)] == true
end

-- Is there a clear line between two points (nothing that collides in the way, by its collision boxes:
-- Minecraft's ClipContext COLLIDER; a closed door's panel hides a player, its open doorway does
-- not; Blocks/Shapes.sight)?
function MobAI.canSee(
	getBlock: MobPhysics.GetBlock,
	ax: number,
	ay: number,
	az: number,
	bx: number,
	by: number,
	bz: number
): boolean
	local dx, dy, dz = bx - ax, by - ay, bz - az
	local length = sqrt(dx * dx + dy * dy + dz * dz)
	if length < 1e-6 then
		return true
	end
	local stops, outline = Shapes.sight(getBlock)
	return VoxelRaycast.cast(ax, ay, az, dx, dy, dz, length, getBlock, stops, outline) == nil
end

-- May mobs hunt this player (alive, and a game mode that can be hurt)?
function MobAI.attackable(player: PlayerView): boolean
	return player.alive and not GameMode.invulnerable(player.mode)
end

--[[
	Is a step of `body` (a mob of `kind`) along its facing safe: the ground ahead loaded, no drop
	of more than MAX_FALL blocks, and no hazard where it would stand or under it?
]]
function MobAI.safeAhead(getBlock: MobPhysics.GetBlock, body: MobPhysics.Body, kind: MobList.Kind): boolean
	local reach = kind.width / 2 + 0.4
	local ax = body.x + sin(body.yaw) * reach
	local az = body.z + cos(body.yaw) * reach
	local feet = floor(body.y + 0.001)
	local bx, bz = floor(ax), floor(az)
	-- (Where it would stand, and the cell above for a step up.)
	for dy = 0, 1 do
		local block = getBlock(bx, feet + dy, bz)
		if block == nil or MobAI.hazard(block) then
			return false
		end
	end
	local drop = MobPhysics.dropAt(getBlock, ax, body.y, az, MobAI.MAX_FALL)
	if drop == nil then
		return false
	end
	return not MobAI.hazard(getBlock(bx, feet - 1 - drop, bz))
end

-- Faces (x, z) from the body; returns the horizontal distance.
local function face(body: MobPhysics.Body, x: number, z: number): number
	local dx, dz = x - body.x, z - body.z
	local distance = sqrt(dx * dx + dz * dz)
	if distance > 1e-4 then
		body.yaw = atan2(dx, dz)
	end
	return distance
end

-- A mob's walking input at speed modifier `modifier` (Mob.setSpeed: attribute x modifier, then
-- aiStep's x 0.98).
local function walk(kind: MobList.Kind, modifier: number): number
	return kind.speed * modifier * 0.98
end

-- The world as the AI sees it (Mobs/MobWorld).
export type World = {
	getBlock: MobPhysics.GetBlock,
	random: () -> number,
	-- Events (Mobs/MobWorld's takeChanges).
	hitPlayer: (self: any, mob: any, player: PlayerView, damage: number, kx: number, ky: number, kz: number) -> (),
	sound: (self: any, name: string, x: number, y: number, z: number) -> (),
	-- (Zombies.) `power` more damage on the block at (x, y, z), shared with every zombie hitting it:
	-- its damage so far and what breaks it (Blocks.zombieBreak).
	damageBlock: (self: any, x: number, y: number, z: number, power: number) -> (number, number),
	-- A zombie's hit on a block (the thud) and a block giving way.
	blockHit: (self: any, mob: any, x: number, y: number, z: number, block: number) -> (),
	breakBlock: (self: any, mob: any, x: number, y: number, z: number, block: number) -> (),
	-- A noise it makes (a screamer's shriek), heard by the others next tick.
	noise: (self: any, x: number, y: number, z: number, radius: number) -> (),
}

export type Context = {
	players: { PlayerView },
	dayTime: number,
	skyOpen: (x: number, y: number, z: number) -> boolean?,
	-- (Zombies.) This tick's noises (nil: none), whether it is night, and whether zombies break
	-- blocks (Apocalypse.Breaking.Enabled).
	noises: { Noise }?,
	night: boolean?,
	breaking: boolean?,
}

-- The mob (Mobs/MobWorld's record) as far as the AI goes.
type Mob = {
	id: number,
	kind: MobList.Kind,
	body: MobPhysics.Body,
	ai: State,
	age: number,
	removed: boolean,
	-- (Zombies: hunting through a blood moon, so it never idles away.)
	persistent: boolean?,
}

local function randomInt(world: World, n: number): number
	return floor(world.random() * n)
end

-- The player with key `key` among the context's, if any.
local function playerOf(context: Context, key: any): PlayerView?
	if key == nil then
		return nil
	end
	for _, player in context.players do
		if player.key == key then
			return player
		end
	end
	return nil
end

-- The nearest player the mob may notice now (see the header), or nil.
local function findTarget(world: World, context: Context, mob: Mob): PlayerView?
	local kind, body = mob.kind, mob.body
	local follow = kind.follow or MobList.FOLLOW
	local best: PlayerView? = nil
	local bestDistance = follow * follow
	local ex, ey, ez = body.x, body.y + kind.eye, body.z
	for _, player in context.players do
		if MobAI.attackable(player) then
			local dx, dy, dz = player.x - body.x, player.y - body.y, player.z - body.z
			local distance = dx * dx + dy * dy + dz * dz
			if
				distance <= bestDistance
				and MobAI.canSee(world.getBlock, ex, ey, ez, player.x, player.y + player.eye, player.z)
			then
				best, bestDistance = player, distance
			end
		end
	end
	return best
end

-- Picks a stroll or panic destination `min`..`range` blocks away (away from (fx, fz) when given,
-- within `spread` radians either side: 90 degrees by default).
local function pickSpot(world: World, mob: Mob, min: number, range: number, fx: number?, fz: number?, spread: number?)
	local body, ai = mob.body, mob.ai
	local angle = world.random() * math.pi * 2
	if fx and fz then
		-- (Away from the attacker.)
		angle = atan2(body.x - fx, body.z - fz) + (world.random() - 0.5) * (spread or math.pi)
	end
	local distance = min + world.random() * (range - min)
	ai.tx = body.x + sin(angle) * distance
	ai.tz = body.z + cos(angle) * distance
end

--[[
	A creature or monster was hurt (by `player`, a PlayerView key, when a player hit it; from
	(fx, fz) when the hurt came from somewhere): creatures panic, monsters hunt the player (a
	leaving zombie turns back for them).
]]
function MobAI.hurt(world: World, mob: Mob, player: any?, fx: number?, fz: number?)
	local ai = mob.ai
	if mob.kind.hostile then
		if player ~= nil then
			ai.target = player
			ai.unseen = 0
			ai.visible = false
			ai.leave = 0
			ai.goal = "chase"
		end
		return
	end
	if mob.kind.panic then
		ai.goal = "panic"
		ai.timer = MobAI.PANIC_TICKS + randomInt(world, MobAI.PANIC_EXTRA)
		pickSpot(world, mob, 5, 10, fx, fz)
	end
end

-- Walks towards (x, z) at `modifier`: (forward, jump, whether the way ahead is safe). Stops at
-- drops and hazards.
local function steer(world: World, mob: Mob, x: number, z: number, modifier: number): (number, boolean, boolean)
	local body, kind = mob.body, mob.kind
	face(body, x, z)
	if not MobAI.safeAhead(world.getBlock, body, kind) then
		return 0, false, false
	end
	local jump = body.horizontalCollision and body.onGround
	return walk(kind, modifier), jump, true
end

--[[ The zombie apocalypse ]]

-- Squared distance from the body's feet to the nearest player in the context (any player).
local function nearestPlayer(context: Context, body: MobPhysics.Body): (PlayerView?, number)
	local best: PlayerView? = nil
	local bestDistance = math.huge
	for _, player in context.players do
		local dx, dy, dz = player.x - body.x, player.y - body.y, player.z - body.z
		local distance = dx * dx + dy * dy + dz * dz
		if distance < bestDistance then
			best, bestDistance = player, distance
		end
	end
	return best, bestDistance
end

local function stopBreaking(ai: State)
	ai.bx = nil
	ai.breakTicks = 0
	ai.blockedTicks = 0
end

-- The leaving walk (see the header): away from the nearest player.
local function leaveStep(world: World, context: Context, mob: Mob, jump: boolean): (number, boolean)
	local ai, body, kind = mob.ai, mob.body, mob.kind
	ai.leave -= 1
	if ai.leave <= 0 then
		ai.leave = 0
		ai.goal = "idle"
		ai.timer = 0
		return 0, jump
	end
	local player = nearestPlayer(context, body)
	if player == nil then
		return 0, jump
	end
	local dx, dz = ai.tx - body.x, ai.tz - body.z
	if ai.goal ~= "leave" or dx * dx + dz * dz < MobAI.ARRIVE * MobAI.ARRIVE then
		ai.goal = "leave"
		pickSpot(world, mob, MobAI.LEAVE_LEG, MobAI.LEAVE_LEG, player.x, player.z, math.pi * 2 / 3)
	end
	local forward, hop, ok = steer(world, mob, ai.tx, ai.tz, kind.wander)
	if not ok then
		-- (Another way out next tick.)
		pickSpot(world, mob, MobAI.LEAVE_LEG, MobAI.LEAVE_LEG, player.x, player.z, math.pi * 2 / 3)
	end
	return forward, jump or hop
end

-- Goes to look at `noise` (see the header), `loud` blocks inside its reach.
local function investigate(mob: Mob, noise: Noise, loud: number)
	local ai = mob.ai
	if ai.goal ~= "investigate" then
		stopBreaking(ai)
	end
	ai.goal = "investigate"
	ai.nx, ai.ny, ai.nz = noise.x, noise.y, noise.z
	ai.heard = loud
	-- (A spot near it of the zombie's own, so a crowd spreads around a noise.)
	local h = Hash.hash2(mob.id, 0x4E01, 0x5E)
	local angle = (h % 4096) / 4096 * math.pi * 2
	local radius = (h // 4096 % 4096) / 4096 * MobAI.INVESTIGATE_SPREAD
	ai.tx = noise.x + sin(angle) * radius
	ai.tz = noise.z + cos(angle) * radius
	ai.timer = Apocalypse.Noise.InvestigateTicks
end

--[[
	The cells in front of a blocked mob that stop it (see the header): along the dominant axis of
	its facing first, then the other, the cells just past its box at its feet and (taller than a
	block) its head with a collision shape. Fills `out` with x, y, z, block per cell; returns how
	many.
]]
local blockedScratch: { number } = table.create(8)
local function blockedCells(getBlock: MobPhysics.GetBlock, body: MobPhysics.Body, kind: MobList.Kind): number
	local out = blockedScratch
	local sx, sz = sin(body.yaw), cos(body.yaw)
	local reach = kind.width / 2 + 0.1
	local feet = floor(body.y + 0.001)
	local top = if kind.height > 1 then feet + 1 else feet
	local xFirst = abs(sx) >= abs(sz)
	for pass = 1, 2 do
		local alongX = (pass == 1) == xFirst
		local component = if alongX then sx else sz
		if abs(component) >= 0.2 then
			local step = if component > 0 then reach else -reach
			local cx = if alongX then floor(body.x + step) else floor(body.x)
			local cz = if alongX then floor(body.z) else floor(body.z + step)
			local n = 0
			for y = feet, top do
				local block = getBlock(cx, y, cz)
				if block ~= nil and Shapes.collisionAt(getBlock, cx, y, cz, block) ~= false then
					out[n * 4 + 1], out[n * 4 + 2], out[n * 4 + 3], out[n * 4 + 4] = cx, y, cz, block
					n += 1
				end
			end
			if n > 0 then
				return n
			end
		end
	end
	return 0
end

--[[
	Starts breaking what blocks the mob, if it may (see the header): every blocked cell breakable,
	the softest first. Returns whether it started.
]]
local function startBreaking(world: World, mob: Mob): boolean
	local ai, body, kind = mob.ai, mob.body, mob.kind
	local n = blockedCells(world.getBlock, body, kind)
	if n == 0 then
		return false
	end
	local out = blockedScratch
	local best, bestTicks = 0, math.huge
	for i = 0, n - 1 do
		local ticks = Blocks.zombieBreak(out[i * 4 + 4])
		if ticks <= 0 then
			-- (Something it can't break is in the way: breaking the rest wouldn't let it pass.)
			return false
		end
		if ticks < bestTicks then
			best, bestTicks = i, ticks
		end
	end
	ai.bx, ai.by, ai.bz, ai.bblock = out[best * 4 + 1], out[best * 4 + 2], out[best * 4 + 3], out[best * 4 + 4]
	ai.breakTicks = 0
	return true
end

-- One tick of breaking (see the header): (still breaking?).
local function breakStep(world: World, mob: Mob): boolean
	local ai, body, kind = mob.ai, mob.body, mob.kind
	local bx = ai.bx :: number
	local by, bz = ai.by, ai.bz
	local cx, cz = bx + 0.5, bz + 0.5
	local dx, dz = cx - body.x, cz - body.z
	if world.getBlock(bx, by, bz) ~= ai.bblock or dx * dx + dz * dz > MobAI.BREAK_LEAVE * MobAI.BREAK_LEAVE then
		stopBreaking(ai)
		return false
	end
	face(body, cx, cz)
	local progress, needed = world:damageBlock(bx, by, bz, kind.breakPower or 1)
	if ai.breakTicks % math.max(1, Apocalypse.Breaking.HitInterval) == 0 then
		world:blockHit(mob, bx, by, bz, ai.bblock)
	end
	ai.breakTicks += 1
	if needed > 0 and progress >= needed then
		world:breakBlock(mob, bx, by, bz, ai.bblock)
		stopBreaking(ai)
		return false
	end
	return true
end

--[[
	Lining up with a gap (see the header's Steering): a zombie pressed against the row of cells
	ahead (along the main axis of its facing, at its feet and, taller than a block, its head) looks
	for the free stretch across its way nearest its middle, within SQUEEZE_REACH blocks, that is
	wide enough for its box: a doorway, or an open door's 13/16. Returns the coordinate across its
	way to steer at and whether it moves along X, or nil when it is lined up already or no gap fits.
]]
local spans: { number } = table.create(16)
local function squeeze(getBlock: MobPhysics.GetBlock, body: MobPhysics.Body, kind: MobList.Kind): (number?, boolean)
	local sx, sz = sin(body.yaw), cos(body.yaw)
	local alongX = abs(sx) >= abs(sz)
	local half = kind.width / 2
	local ahead = half + 0.1
	-- (Across: the coordinate across the way; row: the cells' coordinate along it.)
	local across = if alongX then body.z else body.x
	local row = if alongX
		then floor(body.x + (if sx > 0 then ahead else -ahead))
		else floor(body.z + (if sz > 0 then ahead else -ahead))
	local feet = floor(body.y + 0.001)
	local top = if kind.height > 1 then feet + 1 else feet
	local first = floor(across - half) - 1
	local last = floor(across + half) + 1
	-- The blocked stretches across the way, as lo, hi pairs.
	local n = 0
	for c = first, last do
		for y = feet, top do
			local cx = if alongX then row else c
			local cz = if alongX then c else row
			local block = getBlock(cx, y, cz)
			local shape = if block == nil then true else Shapes.collisionAt(getBlock, cx, y, cz, block)
			if shape == true then
				spans[n + 1], spans[n + 2] = c, c + 1
				n += 2
			elseif type(shape) == "table" then
				for _, box in shape do
					local lo = if alongX then box.minZ else box.minX
					local hi = if alongX then box.maxZ else box.maxX
					spans[n + 1], spans[n + 2] = c + lo, c + hi
					n += 2
				end
			end
		end
	end
	if n == 0 then
		return nil, alongX
	end
	-- The free stretches between them (within first..last + 1), the best one fitting the box.
	local best: number? = nil
	local bestShift = MobAI.SQUEEZE_REACH
	local cursor = first
	local limit = last + 1
	while cursor < limit do
		-- The next blocked stretch starting at or after the cursor that covers it, if any.
		local covered = false
		for i = 1, n, 2 do
			if spans[i] <= cursor + 1e-9 and spans[i + 1] > cursor + 1e-9 then
				cursor = spans[i + 1]
				covered = true
				break
			end
		end
		if not covered then
			local stop = limit
			for i = 1, n, 2 do
				if spans[i] > cursor + 1e-9 and spans[i] < stop then
					stop = spans[i]
				end
			end
			if stop - cursor >= kind.width + 0.02 then
				local lo, hi = cursor + half + 0.01, stop - half - 0.01
				local at = math.clamp(across, lo, hi)
				local shift = abs(at - across)
				if shift < 1e-3 then
					-- (Lined up with a gap already: what stops it is elsewhere.)
					return nil, alongX
				end
				if shift <= bestShift then
					best, bestShift = at, shift
				end
			end
			cursor = stop
		end
	end
	return best, alongX
end

-- Is (x, y, z) (feet) near enough and level with the mob to break towards (see the header)?
local function breakable(body: MobPhysics.Body, x: number, y: number, z: number, reach: number): boolean
	local dx, dz = x - body.x, z - body.z
	if dx * dx + dz * dz > reach * reach then
		return false
	end
	local feet = floor(body.y + 0.001)
	local level = floor(y + 0.001)
	return level >= feet - 1 and level <= feet + 2
end

-- Walks at (x, z) and breaks what blocks the way when it may (`reach`: how near the goal at
-- (gx, gy, gz) must be; 0: never). (forward, jump).
local function advance(
	world: World,
	context: Context,
	mob: Mob,
	x: number,
	z: number,
	modifier: number,
	gx: number,
	gy: number,
	gz: number,
	reach: number,
	jump: boolean
): (number, boolean)
	local ai, body = mob.ai, mob.body
	if ai.bx ~= nil then
		if breakStep(world, mob) then
			return 0, jump
		end
	end
	-- Blocked?
	local mx, mz = body.x - ai.lastX, body.z - ai.lastZ
	ai.lastX, ai.lastZ = body.x, body.z
	-- (Pressed against the wall behind a ladder it climbs: not blocked.)
	local feetBlock = world.getBlock(floor(body.x), floor(body.y), floor(body.z))
	local climbing = feetBlock ~= nil and Blocks.isClimbable(feetBlock)
	if
		body.horizontalCollision
		and not climbing
		and mx * mx + mz * mz < MobAI.BLOCKED_PROGRESS * MobAI.BLOCKED_PROGRESS
	then
		ai.blockedTicks += 1
	else
		ai.blockedTicks = 0
	end
	local squeezing = false
	if body.horizontalCollision then
		-- (Pressed against something: line up with a gap in it, if one fits, sideways and a
		-- little on, without jumping.)
		local across, alongX = squeeze(world.getBlock, body, mob.kind)
		if across then
			local sx, sz = sin(body.yaw), cos(body.yaw)
			if alongX then
				x, z = body.x + (if sx > 0 then MobAI.SQUEEZE_AHEAD else -MobAI.SQUEEZE_AHEAD), across
			else
				x, z = across, body.z + (if sz > 0 then MobAI.SQUEEZE_AHEAD else -MobAI.SQUEEZE_AHEAD)
			end
			ai.blockedTicks = 0
			squeezing = true
		end
	end
	local forward, hop = steer(world, mob, x, z, modifier)
	if squeezing then
		hop = false
	end
	-- (Only from the ground: a zombie jumping at a wall counts blocked in the air too, and its
	-- feet up there would make a target 3 up look level and the cells above its head look ahead.)
	if
		ai.blockedTicks >= MobAI.BLOCKED_TICKS
		and body.onGround
		and reach > 0
		and context.breaking == true
		and breakable(body, gx, gy, gz, reach)
		and startBreaking(world, mob)
	then
		ai.blockedTicks = 0
		breakStep(world, mob)
		return 0, jump
	end
	return forward, jump or hop
end

-- The screamer's shriek (see the header).
local function scream(world: World, mob: Mob)
	local ai, kind, body = mob.ai, mob.kind, mob.body
	local spec = kind.scream
	if spec == nil or ai.screamCooldown > 0 then
		return
	end
	ai.scream = MobAI.SCREAM_TICKS
	ai.screamCooldown = spec.cooldown
	world:sound(MobAI.SCREAM_SOUND, body.x, body.y + kind.eye, body.z)
	world:noise(body.x, body.y + kind.eye, body.z, spec.radius)
end

-- A zombie's tick (see the header): (forward, jump); a nil forward when it has nothing to do
-- but stroll or stand (MobAI.step's idle rules).
local function zombieStep(world: World, context: Context, mob: Mob, jump: boolean): (number?, boolean)
	local kind, body, ai = mob.kind, mob.body, mob.ai
	if ai.swing > 0 then
		ai.swing -= 1
	end
	if ai.screamCooldown > 0 then
		ai.screamCooldown -= 1
	end
	-- (The shriek counts down whatever the zombie does, so one sent away or thinned mid-shriek
	-- shows it no longer than SCREAM_TICKS.)
	if ai.scream > 0 then
		ai.scream -= 1
	end

	-- Leave.
	if ai.leave > 0 then
		ai.target, ai.hunt = nil, nil
		stopBreaking(ai)
		return leaveStep(world, context, mob, jump)
	end

	-- Thinning: far from every player, an idle or strolling zombie thinks every 4th tick (but
	-- every tick that has noises: one lasts a tick).
	local noises = context.noises or EMPTY
	if
		ai.target == nil
		and ai.hunt == nil
		and ai.bx == nil
		and (ai.goal == "idle" or ai.goal == "wander")
		and #noises == 0
	then
		local _, distance = nearestPlayer(context, body)
		local thin = Zombies.ThinDistance
		if distance > thin * thin and (mob.age + mob.id) % MobAI.THIN_EVERY ~= 0 then
			return 0, jump
		end
	end

	-- The hunted player: gone, safe or too far, the hunt ends.
	local hunted: PlayerView? = nil
	if ai.hunt ~= nil then
		hunted = playerOf(context, ai.hunt)
		local keep = Zombies.HuntKeep
		local ok = hunted ~= nil and MobAI.attackable(hunted)
		if ok and hunted then
			local dx, dy, dz = hunted.x - body.x, hunted.y - body.y, hunted.z - body.z
			ok = dx * dx + dy * dy + dz * dz <= keep * keep
		end
		if not ok then
			ai.hunt, hunted = nil, nil
			mob.persistent = false
			ai.progressTimer, ai.progressDistance = 0, -1
		end
	end

	-- Target.
	local target = playerOf(context, ai.target)
	if target then
		local keep = if ai.hunt ~= nil and ai.hunt == ai.target then Zombies.HuntKeep else kind.follow or MobList.FOLLOW
		local dx, dy, dz = target.x - body.x, target.y - body.y, target.z - body.z
		if not MobAI.attackable(target) or dx * dx + dy * dy + dz * dz > keep * keep then
			target = nil
		end
	end
	local gained = false
	local sightTick = (mob.age + mob.id) % math.max(1, Zombies.SightInterval) == 0
	if target == nil and hunted and sightTick then
		-- (A hunter that sees its player chases them, however far within HuntKeep.)
		if
			MobAI.canSee(world.getBlock, body.x, body.y + kind.eye, body.z, hunted.x, hunted.y + hunted.eye, hunted.z)
		then
			target, gained = hunted, true
		end
	end
	if target == nil and (mob.age + mob.id) % MobAI.RETARGET_INTERVAL == 0 then
		target = findTarget(world, context, mob)
		gained = target ~= nil
	end

	-- Noise.
	if target == nil and #noises > 0 then
		local hearing = kind.hearing or 1
		local loudest: Noise? = nil
		local loud = if ai.goal == "investigate" then ai.heard else 0
		for _, noise in noises do
			local reach = noise.radius * hearing
			local dx, dy, dz = noise.x - body.x, noise.y - body.y, noise.z - body.z
			local distance = dx * dx + dy * dy + dz * dz
			if distance <= reach * reach then
				local margin = reach - sqrt(distance)
				if loudest == nil and margin >= loud or margin > loud then
					loudest, loud = noise, margin
				end
			end
		end
		if loudest then
			investigate(mob, loudest, loud)
			target = findTarget(world, context, mob)
			gained = target ~= nil
		end
	end

	if gained then
		ai.unseen = 0
		ai.visible = true
	end
	ai.target = if target then target.key else nil
	if target then
		if ai.goal ~= "chase" then
			ai.goal = "chase"
		end
	elseif ai.goal == "chase" then
		ai.goal = "idle"
		ai.timer = 0
	end
	if gained then
		scream(world, mob)
	end

	-- Sight while chasing (every SightInterval ticks; the count frozen while breaking).
	if target and sightTick and not gained then
		local visible =
			MobAI.canSee(world.getBlock, body.x, body.y + kind.eye, body.z, target.x, target.y + target.eye, target.z)
		ai.visible = visible
		if visible then
			ai.unseen = 0
		elseif ai.bx == nil then
			ai.unseen += math.max(1, Zombies.SightInterval)
		end
		if ai.unseen > MobAI.UNSEEN_MEMORY then
			-- (Forgotten; a hunter still steers at its player below.)
			ai.target, target = nil, nil
			ai.visible = false
			ai.goal = "idle"
			ai.timer = 0
		end
	end

	-- A stuck hunter gives up (see the header).
	if hunted and (target == nil or target == hunted) then
		ai.progressTimer += 1
		local dx, dz = hunted.x - body.x, hunted.z - body.z
		local distance = sqrt(dx * dx + dz * dz)
		if ai.progressDistance < 0 then
			ai.progressDistance, ai.progressTimer = distance, 0
		elseif ai.progressTimer >= Zombies.Leave.StuckTicks then
			local dy = hunted.y - body.y
			local reach = (2 * kind.width) ^ 2 + 0.6
			local fighting = distance * distance + dy * dy <= reach
			if ai.progressDistance - distance < 1 and ai.bx == nil and not fighting then
				ai.hunt, hunted = nil, nil
				mob.persistent = false
				ai.target, target = nil, nil
				ai.goal = "idle"
				ai.leave = Zombies.Leave.Ticks
				ai.progressTimer, ai.progressDistance = 0, -1
				stopBreaking(ai)
				return 0, jump
			end
			ai.progressDistance, ai.progressTimer = distance, 0
		end
	end

	-- The shriek: it stands facing its target (from the tick it starts, SCREAM_TICKS in all).
	if ai.scream > 0 then
		if target then
			face(body, target.x, target.z)
		end
		return 0, jump
	end

	if target then
		local dx, dy, dz = target.x - body.x, target.y - body.y, target.z - body.z
		local distance = dx * dx + dy * dy + dz * dz
		if kind.attack then
			-- MeleeAttackGoal: in reach, seen, cooled down.
			local reach = (2 * kind.width) ^ 2 + 0.6
			if distance <= reach and ai.visible and ai.cooldown <= 0 then
				ai.cooldown = MobAI.MELEE_COOLDOWN
				ai.swing = MobAI.SWING_TICKS
				local kx, ky, kz = Combat.knockback(Combat.KNOCKBACK, body.x, body.z, target.x, target.z, 0, 0, 0, true)
				world:hitPlayer(mob, target, kind.attack, kx, ky, kz)
			end
			if distance <= reach * 0.5 then
				-- (Close enough: no need to walk into the player.)
				face(body, target.x, target.z)
				stopBreaking(ai)
				return 0, jump
			end
		end
		local reach = if ai.hunt ~= nil and ai.hunt == ai.target then Zombies.HuntBreakReach else Zombies.BreakReach
		return advance(
			world,
			context,
			mob,
			target.x,
			target.z,
			kind.chase or 1,
			target.x,
			target.y,
			target.z,
			reach,
			jump
		)
	end
	if hunted then
		return advance(
			world,
			context,
			mob,
			hunted.x,
			hunted.z,
			kind.chase or 1,
			hunted.x,
			hunted.y,
			hunted.z,
			Zombies.HuntBreakReach,
			jump
		)
	end
	if ai.goal == "investigate" then
		if ai.bx == nil then
			ai.timer -= 1
		end
		if ai.timer <= 0 then
			ai.goal = "idle"
			ai.timer = 0
			stopBreaking(ai)
			return 0, jump
		end
		local dx, dz = ai.tx - body.x, ai.tz - body.z
		if ai.bx == nil and dx * dx + dz * dz <= MobAI.ARRIVE * MobAI.ARRIVE then
			-- (There: a look about.)
			ai.goal = "wander"
			ai.timer = MobAI.STROLL_AFTER
			pickSpot(world, mob, MobAI.STROLL_MIN, MobAI.STROLL_RANGE, nil, nil)
			return 0, jump
		end
		return advance(
			world,
			context,
			mob,
			ai.tx,
			ai.tz,
			(kind.chase or 1) * MobAI.INVESTIGATE_SPEED,
			ai.nx,
			ai.ny,
			ai.nz,
			Zombies.BreakReach,
			jump
		)
	end
	stopBreaking(ai)
	return nil, jump
end

--[[
	One tick of a live mob's AI in `world` with `context`: what it does (see the header). Returns
	the walking input (`forward`, 0..1 along its yaw) and whether it jumps.
]]
function MobAI.step(world: World, context: Context, mob: Mob): (number, boolean)
	local kind, body, ai = mob.kind, mob.body, mob.ai
	if ai.cooldown > 0 then
		ai.cooldown -= 1
	end
	-- FloatGoal.
	local jump = false
	if body.waterDepth > MobPhysics.FLUID_JUMP_THRESHOLD or body.lavaDepth > 0 then
		jump = world.random() < MobAI.FLOAT_CHANCE
	end

	if kind.zombie then
		-- (The zombie's rules; nil forward: it has nothing to do but stroll, below.)
		local forward, hop = zombieStep(world, context, mob, jump)
		if forward ~= nil then
			return forward, hop
		end
	end

	-- Monsters: who they hunt.
	local target: PlayerView? = nil
	if kind.hostile and not kind.zombie then
		target = playerOf(context, ai.target)
		local follow = kind.follow or MobList.FOLLOW
		if target then
			local dx, dy, dz = target.x - body.x, target.y - body.y, target.z - body.z
			if not MobAI.attackable(target) or dx * dx + dy * dy + dz * dz > follow * follow then
				target = nil
			end
		end
		if target == nil and (mob.age + mob.id) % MobAI.RETARGET_INTERVAL == 0 then
			target = findTarget(world, context, mob)
			ai.unseen = 0
		end
		ai.target = if target then target.key else nil
		if target then
			ai.goal = "chase"
		elseif ai.goal == "chase" then
			ai.goal = "idle"
			ai.timer = 0
		end
	end

	if target then
		local ex, ey, ez = body.x, body.y + kind.eye, body.z
		local visible = MobAI.canSee(world.getBlock, ex, ey, ez, target.x, target.y + target.eye, target.z)
		if visible then
			ai.unseen = 0
		else
			ai.unseen += 1
			if ai.unseen > MobAI.UNSEEN_MEMORY then
				ai.target = nil
				ai.goal = "idle"
				ai.timer = 0
				return 0, jump
			end
		end
		local dx, dy, dz = target.x - body.x, target.y - body.y, target.z - body.z
		local distance = sqrt(dx * dx + dy * dy + dz * dz)
		if kind.attack then
			-- MeleeAttackGoal: in reach, seen, cooled down.
			local reach = (2 * kind.width) ^ 2 + 0.6
			if distance * distance <= reach and visible and ai.cooldown <= 0 then
				ai.cooldown = MobAI.MELEE_COOLDOWN
				ai.swing = MobAI.SWING_TICKS
				local kx, ky, kz = Combat.knockback(Combat.KNOCKBACK, body.x, body.z, target.x, target.z, 0, 0, 0, true)
				world:hitPlayer(mob, target, kind.attack, kx, ky, kz)
			end
			if distance * distance <= reach * 0.5 then
				-- (Close enough: no need to walk into the player.)
				face(body, target.x, target.z)
				return 0, jump
			end
		end
		local forward, hop = steer(world, mob, target.x, target.z, kind.chase or 1)
		return forward, jump or hop
	end

	-- Panic, stroll, or stand.
	if ai.goal == "panic" then
		ai.timer -= 1
		if ai.timer <= 0 then
			ai.goal = "idle"
		else
			local dx, dz = ai.tx - body.x, ai.tz - body.z
			if dx * dx + dz * dz < 1 then
				pickSpot(world, mob, 5, 10, nil, nil)
			end
			local forward, hop, ok = steer(world, mob, ai.tx, ai.tz, kind.panic or 1.25)
			if not ok then
				pickSpot(world, mob, 5, 10, nil, nil)
			end
			return forward, jump or hop
		end
	end
	if ai.goal == "wander" then
		ai.timer -= 1
		local dx, dz = ai.tx - body.x, ai.tz - body.z
		if ai.timer <= 0 or dx * dx + dz * dz < 1 then
			ai.goal = "idle"
			return 0, jump
		end
		local forward, hop, ok = steer(world, mob, ai.tx, ai.tz, kind.wander)
		if not ok then
			ai.goal = "idle"
		end
		return forward, jump or hop
	end
	if randomInt(world, MobAI.STROLL_INTERVAL) == 0 then
		ai.goal = "wander"
		ai.timer = MobAI.STROLL_TICKS
		pickSpot(world, mob, MobAI.STROLL_MIN, MobAI.STROLL_RANGE, nil, nil)
	end
	return 0, jump
end

return MobAI
