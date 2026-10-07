--!strict
--[[
	Mob movement, one 20 Hz tick at a time: Minecraft Java Edition 1.20.1's LivingEntity.aiStep and
	travel for a Mob walking where its AI steers it (server Mobs/MobWorld runs it, Mobs/MobAI
	steers), on the hitbox of its kind (Shared/Entities/MobList) through `Hull`.

	  Input     `forward` (0..1: Minecraft's zza, speed x the goal's modifier, x 0.98 as aiStep
	            does) along the body's `yaw` (radians: facing (sin yaw, cos yaw), 0 = +Z), and
	            `jump`.
	  Jumping   on the ground, 10 ticks apart (noJumpDelay): 0.42 up (jumpFromGround); in a fluid
	            deeper than 0.4 (fluidJumpThreshold) 0.04 up a tick (jumpInLiquid), which is how
	            Minecraft's FloatGoal keeps mobs at the surface.
	  Ground    acceleration speed x 0.216 / f^3 (f the friction of the block under it: 0.6, so the
	            speed itself; ice 0.98 slides), then gravity 0.08, x 0.98 vertically and f x 0.91
	            sideways: a zombie (0.23) walks 0.114 blocks a tick, 2.3 a second.
	  Air       acceleration 0.02 (Mob's flying speed), x 0.91 sideways.
	  Water     water's tag (water, fuel: Shared/Fluids `physics`): acceleration 0.02, everything
	            x 0.8, sinking 0.005 a tick (gravity / 16); lava's tag (lava, oil): x 0.5 (x 0.8
	            vertically when shallow), gravity / 4. Walking into a wall at the surface hops out
	            (0.3 up, LivingEntity's jumpOutOfFluid). The fall distance is cleared in water and
	            halved every tick in lava.
	  Climbing  `climbs` (spiders: Spider.onClimbable): pushing into a wall climbs it at 0.2 a tick.
	  Chickens  `slowFall`: falling speed x 0.6 a tick (Chicken.aiStep), no fall damage there.
	  Collision Hull.collide with Minecraft's mob step height 0.6, so a mob must jump a full
	            block (its AI does); unloaded blocks are solid. `horizontalCollision` says when a
	            wall stopped it (the AI jumps, a spider climbs).
	  Falling   the fall distance counts up while it falls; on landing `tick` returns it (fall
	            damage is ceil(distance - 3), LivingEntity.causeFallDamage, MobWorld's).

	Units are blocks and ticks. Pure Luau, deterministic.
]]

local Blocks = require(script.Parent.Parent.Blocks)
local Fluids = require(script.Parent.Parent.Fluids)
local Hull = require(script.Parent.Parent.Movement.Hull)

export type GetBlock = (x: number, y: number, z: number) -> number?

export type Body = {
	-- Feet centre (blocks) and velocity (blocks per tick).
	x: number,
	y: number,
	z: number,
	vx: number,
	vy: number,
	vz: number,
	-- Facing (radians): (sin yaw, cos yaw).
	yaw: number,
	onGround: boolean,
	horizontalCollision: boolean,
	fallDistance: number,
	jumpDelay: number,
	-- How high water's (and lava's) tag reach above the feet this tick (0: none).
	waterDepth: number,
	lavaDepth: number,
}

-- What moves: a kind's hitbox and abilities (Shared/Entities/MobList).
export type Shape = {
	width: number,
	height: number,
	speed: number,
	climbs: boolean?,
	slowFall: boolean?,
}

local MobPhysics = {}

MobPhysics.TICK_RATE = 20
MobPhysics.STEP_HEIGHT = 0.6
MobPhysics.JUMP_POWER = 0.42
MobPhysics.JUMP_DELAY = 10
-- Above this depth a fluid lifts a jumping mob (Entity.getFluidJumpThreshold).
MobPhysics.FLUID_JUMP_THRESHOLD = 0.4
MobPhysics.SAFE_FALL = 3

local GRAVITY = 0.08
local VERTICAL_DRAG = 0.9800000190734863 -- 0.98F
local AIR_DRAG = 0.9100000262260437 -- 0.91F
local GROUND_FACTOR = 0.21600002
local AIR_ACCELERATION = 0.02
local FLUID_ACCELERATION = 0.019999999552965164 -- 0.02F
local WATER_DRAG = 0.800000011920929 -- 0.8F
local LAVA_DRAG = 0.5
local LAVA_VERTICAL_DRAG = 0.800000011920929
local WATER_JUMP = 0.03999999910593033 -- 0.04F
local FLUID_EXIT_HOP = 0.30000001192092896 -- 0.3F
local CLIMB_SPEED = 0.2
local SLOW_FALL = 0.6
local MIN_VELOCITY = 0.003
local HIT_EPSILON = 9.999999747378752e-6

local floor = math.floor
local ceil = math.ceil
local sin = math.sin
local cos = math.cos
local max = math.max

-- The block getter of the tick in progress, so collision callbacks need no closure per call.
local current: GetBlock = function(_x: number, _y: number, _z: number): number?
	return nil
end

local function solidAt(x: number, y: number, z: number): boolean
	local block = current(x, y, z)
	return block == nil or Blocks.isSolid(block)
end

-- Per block: its fluid (Shared/Fluids id, 0 none), and per fluid id whether it is in lava's tag.
local fluidLut = Fluids.blockLut
local LAVA_LIKE: { [number]: boolean } = {}
for id, fluid in Fluids.list do
	LAVA_LIKE[id] = fluid.physics == "lava"
end

local function fluidOf(block: number?): number
	return if block then buffer.readu8(fluidLut, block) else 0
end

function MobPhysics.new(x: number, y: number, z: number, yaw: number?): Body
	return {
		x = x,
		y = y,
		z = z,
		vx = 0,
		vy = 0,
		vz = 0,
		yaw = yaw or 0,
		onGround = false,
		horizontalCollision = false,
		fallDistance = 0,
		jumpDelay = 0,
		waterDepth = 0,
		lavaDepth = 0,
	}
end

function MobPhysics.box(body: Body, shape: Shape): Hull.Box
	return Hull.box(body.x, body.y, body.z, shape.width, shape.height)
end

--[[
	How high water's tag and lava's tag reach above the bottom of the box (Entity.
	updateFluidHeightAndDoFluidPushing, without the current's push): 0 when it touches none.
]]
local function fluidDepths(body: Body, shape: Shape): (number, number)
	local half = shape.width / 2
	local minX, minY, minZ = body.x - half + 0.001, body.y + 0.001, body.z - half + 0.001
	local maxX, maxY, maxZ = body.x + half - 0.001, body.y + shape.height - 0.001, body.z + half - 0.001
	local water, lava = 0, 0
	for x = floor(minX), ceil(maxX) - 1 do
		for z = floor(minZ), ceil(maxZ) - 1 do
			for y = floor(minY), ceil(maxY) - 1 do
				local block = current(x, y, z)
				local fluid = fluidOf(block)
				if fluid ~= 0 then
					local height = if fluidOf(current(x, y + 1, z)) == fluid
						then 1
						else buffer.readu8(Blocks.fluidHeightLut, block :: number) / Blocks.FLUID_FULL
					local depth = y + height - minY
					if depth >= 0 then
						if LAVA_LIKE[fluid] then
							lava = max(lava, depth)
						else
							water = max(water, depth)
						end
					end
				end
			end
		end
	end
	return water, lava
end

-- The friction of the block carrying the body (under its centre, Minecraft's
-- getBlockPosBelowThatAffectsMyMovement, 0.5 down).
local function groundFriction(body: Body): number
	local block = current(floor(body.x), floor(body.y - 0.500001), floor(body.z))
	return if block then Blocks.get(block).friction else 0.6
end

-- Entity.moveRelative: `amount` of acceleration along the facing, `forward` of it (|forward| <= 1).
local function moveRelative(body: Body, amount: number, forward: number)
	if forward == 0 then
		return
	end
	local push = forward * amount
	body.vx += sin(body.yaw) * push
	body.vz += cos(body.yaw) * push
end

-- Entity.move: collide, update the ground and wall state, stop the axes that hit something; the
-- fall distance (checkFallDamage). Returns the fall distance of a landing (0: none).
local function move(body: Body, shape: Shape): number
	local dx, dy, dz = body.vx, body.vy, body.vz
	local rx, ry, rz =
		Hull.collide(solidAt, MobPhysics.box(body, shape), dx, dy, dz, MobPhysics.STEP_HEIGHT, body.onGround)
	body.x += rx
	body.y += ry
	body.z += rz
	local hitX = math.abs(dx - rx) >= HIT_EPSILON
	local hitZ = math.abs(dz - rz) >= HIT_EPSILON
	local vertical = dy ~= ry
	body.horizontalCollision = hitX or hitZ
	local wasOnGround = body.onGround
	body.onGround = vertical and dy < 0
	if hitX then
		body.vx = 0
	end
	if hitZ then
		body.vz = 0
	end
	if vertical then
		body.vy = 0
	end
	local landed = 0
	if body.onGround then
		if body.fallDistance > 0 then
			landed = body.fallDistance
		end
		body.fallDistance = 0
	elseif ry < 0 then
		body.fallDistance -= ry
	end
	if wasOnGround and not body.onGround and ry > 0 then
		-- (Stepping up is no fall.)
		body.fallDistance = 0
	end
	return landed
end

-- May the box move `dy` up from where it is without hitting anything (Entity.isFree)?
local function free(body: Body, shape: Shape, dx: number, dy: number, dz: number): boolean
	return Hull.noCollision(solidAt, Hull.offset(MobPhysics.box(body, shape), dx, dy, dz))
end

--[[
	Advances the body one tick with `forward` (0..1, along its yaw) and `jump`, against
	`getBlock` (nil: not loaded). Returns the fall distance of a landing this tick (0: none).
]]
function MobPhysics.tick(body: Body, shape: Shape, forward: number, jump: boolean, getBlock: GetBlock): number
	local previous = current
	current = getBlock

	local water, lava = fluidDepths(body, shape)
	body.waterDepth, body.lavaDepth = water, lava
	if water > 0 then
		body.fallDistance = 0
	elseif lava > 0 then
		body.fallDistance *= 0.5
	end

	-- LivingEntity.aiStep: tiny speeds stop, then the jump.
	if math.abs(body.vx) < MIN_VELOCITY then
		body.vx = 0
	end
	if math.abs(body.vy) < MIN_VELOCITY then
		body.vy = 0
	end
	if math.abs(body.vz) < MIN_VELOCITY then
		body.vz = 0
	end
	if body.jumpDelay > 0 then
		body.jumpDelay -= 1
	end
	if jump then
		local depth = max(water, lava)
		if depth > 0 and (depth > MobPhysics.FLUID_JUMP_THRESHOLD or not body.onGround) then
			body.vy += WATER_JUMP
		elseif body.onGround and body.jumpDelay == 0 then
			body.vy = MobPhysics.JUMP_POWER
			body.jumpDelay = MobPhysics.JUMP_DELAY
		end
	else
		body.jumpDelay = 0
	end

	local landed
	if water > 0 or lava > 0 then
		-- LivingEntity.travel's fluid branches.
		local y0 = body.y
		moveRelative(body, FLUID_ACCELERATION, forward)
		landed = move(body, shape)
		if water > 0 then
			body.vx *= WATER_DRAG
			body.vy *= WATER_DRAG
			body.vz *= WATER_DRAG
			body.vy -= GRAVITY / 16
		else
			if lava <= MobPhysics.FLUID_JUMP_THRESHOLD then
				body.vx *= LAVA_DRAG
				body.vy *= LAVA_VERTICAL_DRAG
				body.vz *= LAVA_DRAG
			else
				body.vx *= LAVA_DRAG
				body.vy *= LAVA_DRAG
				body.vz *= LAVA_DRAG
			end
			body.vy -= GRAVITY / 4
		end
		-- Walking into a ledge at the surface hops out (jumpOutOfFluid).
		if body.horizontalCollision and free(body, shape, body.vx, body.vy + 0.6 - body.y + y0, body.vz) then
			body.vy = FLUID_EXIT_HOP
		end
	else
		local friction = if body.onGround then groundFriction(body) else 1
		local acceleration = if body.onGround
			then shape.speed * (GROUND_FACTOR / (friction * friction * friction))
			else AIR_ACCELERATION
		moveRelative(body, acceleration, forward)
		if shape.climbs and body.horizontalCollision and forward > 0 then
			-- (Spider.onClimbable: a wall in the way is climbed.)
			body.vy = CLIMB_SPEED
			body.fallDistance = 0
		end
		landed = move(body, shape)
		body.vy -= GRAVITY
		body.vy *= VERTICAL_DRAG
		local drag = if body.onGround then friction * AIR_DRAG else AIR_DRAG
		body.vx *= drag
		body.vz *= drag
	end
	if shape.slowFall and not body.onGround and body.vy < 0 then
		body.vy *= SLOW_FALL
	end

	current = previous
	return landed
end

--[[
	The ground under a step of the body to (x, z) (blocks): how far the floor is below its feet
	there (0: level, -1: one block up), nil when no floor is within `depth` blocks (a drop) or
	the cell is not loaded. For the AI's "don't walk off a cliff" check.
]]
function MobPhysics.dropAt(getBlock: GetBlock, x: number, y: number, z: number, depth: number): number?
	local bx, bz = floor(x), floor(z)
	local feet = floor(y + 0.001)
	for d = 0, depth do
		local block = getBlock(bx, feet - 1 - d, bz)
		if block == nil then
			return nil
		end
		if Blocks.isSolid(block) or fluidOf(block) ~= 0 then
			return d
		end
	end
	return nil
end

return MobPhysics
