--!strict
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
	             (a stroll ends there).
	  Targets    monsters notice the nearest living survival or adventure player within `follow`
	             (16) blocks they can see (NearestAttackableTargetGoal with mustSee; creative and
	             spectator players are never targets), looking again every 10 ticks, and hunt
	             them until they are out of range, can't be hurt any more, or out of sight for 60
	             ticks (unseenMemoryTicks). A monster hurt by a player hunts that player
	             (HurtByTargetGoal).
	  Melee      zombies hit a target within Minecraft's reach (MeleeAttackGoal: the distance
	             between them under sqrt((2 x width)^2 + target width): a zombie 1.43) that they
	             can see, every 20 ticks, for their `attack` damage with a 0.4 knockback.

	The mob's world gives it what it needs: the blocks, the players (feet, eyes, game modes, alive),
	the day time and the open sky, random numbers and the events it emits (hits on players,
	sounds).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Shapes = require(Shared.Blocks.Shapes)
local Fluids = require(Shared.Fluids)
local GameMode = require(Shared.GameMode)
local MobList = require(Shared.Entities.MobList)
local MobPhysics = require(Shared.Entities.MobPhysics)
local Combat = require(Shared.Entities.Combat)
local VoxelRaycast = require(Shared.World.VoxelRaycast)

export type Goal = "idle" | "wander" | "panic" | "chase"

export type State = {
	goal: Goal,
	-- Where a stroll or a panic heads (blocks) and the ticks it has left.
	tx: number,
	tz: number,
	timer: number,
	-- The player hunted (a key of the world's players) and ticks it was out of sight.
	target: any?,
	unseen: number,
	-- Ticks to the next melee hit.
	cooldown: number,
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

local sqrt = math.sqrt
local atan2 = math.atan2
local floor = math.floor

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
	local ax = body.x + math.sin(body.yaw) * reach
	local az = body.z + math.cos(body.yaw) * reach
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
}

export type Context = {
	players: { PlayerView },
	dayTime: number,
	skyOpen: (x: number, y: number, z: number) -> boolean?,
}

-- The mob (Mobs/MobWorld's record) as far as the AI goes.
type Mob = {
	id: number,
	kind: MobList.Kind,
	body: MobPhysics.Body,
	ai: State,
	age: number,
	removed: boolean,
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

-- Picks a stroll or panic destination `min`..`range` blocks away (away from (fx, fz) when given).
local function pickSpot(world: World, mob: Mob, min: number, range: number, fx: number?, fz: number?)
	local body, ai = mob.body, mob.ai
	local angle = world.random() * math.pi * 2
	if fx and fz then
		-- (Away from the attacker, within 90 degrees either side.)
		angle = atan2(body.x - fx, body.z - fz) + (world.random() - 0.5) * math.pi
	end
	local distance = min + world.random() * (range - min)
	ai.tx = body.x + math.sin(angle) * distance
	ai.tz = body.z + math.cos(angle) * distance
end

--[[
	A creature or monster was hurt (by `player`, a PlayerView key, when a player hit it; from
	(fx, fz) when the hurt came from somewhere): creatures panic, monsters hunt the player.
]]
function MobAI.hurt(world: World, mob: Mob, player: any?, fx: number?, fz: number?)
	local ai = mob.ai
	if mob.kind.hostile then
		if player ~= nil then
			ai.target = player
			ai.unseen = 0
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

-- Walks towards (x, z) at `modifier`: (forward, jump). Stops at drops and hazards.
local function steer(world: World, mob: Mob, x: number, z: number, modifier: number): (number, boolean, boolean)
	local body, kind = mob.body, mob.kind
	face(body, x, z)
	if not MobAI.safeAhead(world.getBlock, body, kind) then
		return 0, false, false
	end
	local jump = body.horizontalCollision and body.onGround
	return walk(kind, modifier), jump, true
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

	-- Monsters: who they hunt.
	local target: PlayerView? = nil
	if kind.hostile then
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
