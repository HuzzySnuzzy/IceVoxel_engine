--!strict
--[[
	Minecraft Java Edition (1.20) player movement, tick for tick.

	The player is an axis-aligned box (Hull) moved through the block grid at a fixed 20 ticks per
	second, with Minecraft's numbers and order of operations (LocalPlayer.aiStep, LivingEntity.aiStep
	/ travel, Entity.move / collide, fluid pushing):

	  ground   input acceleration speed * 0.216 / friction^3 (speed 0.1, sprinting 0.13), then the
	           velocity is multiplied by friction * 0.91 (block friction 0.6, ice 0.98);
	  air      acceleration 0.02 (sprinting 0.026), horizontal drag 0.91, gravity 0.08 and vertical
	           drag 0.98;
	  jumping  vertical speed 0.42, plus 0.2 along the facing direction when sprinting; holding jump
	           jumps again on landing (10 tick delay);
	  stepping up 0.6 blocks (State.stepHeight; IceVoxel uses more, see Config.Movement.StepHeight);
	           sneaking (input x 0.3) never walks off an edge; crouching (1.5 tall)
	           when sneaking or when there is no room to stand, crawling (0.6 tall) when there is no
	           room to crouch either;
	  sprint   starts with the sprint key or a double tap forward (not while crouching), stops without
	           forward input, when running into a wall (not when sliding along one) or when swimming
	           at the surface; crouching does not stop it (sprint-sneaking, as in 1.20);
	  water    acceleration 0.02, drag 0.8 (0.9 horizontally when sprinting), slow sinking (gravity / 16),
	           jump swims up and sneak down (0.04 per tick), the current pushes (0.014), and swimming
	           against a ledge just above the water hops out (0.3); sprinting under water swims (0.6
	           tall, no sinking, up and down where the view points);
	  lava     (LivingEntity.travel's lava branch) acceleration 0.02, then drag 0.5 every way while
	           it is deeper than 0.4 (FLUID_JUMP_THRESHOLD), else 0.5 sideways and 0.8 up and down
	           with water's slow sinking; gravity / 4 on top; jump rises 0.04 a tick (jumpInLiquid),
	           the flow pushes 0.0023, the same hop out onto a ledge; the fall distance halves every
	           tick in it (Entity.baseTick). No swimming, no sinking by sneaking;
	  fluids   each fluid moves the player by its record (Shared/Fluids): `physics` "water" (water,
	           fuel: the water branch, `drag` its 0.8, `swim`) or "lava" (lava, oil: the lava
	           branch, `drag` its 0.5), its `push` on the flow. Minecraft's tags: the water branch
	           comes first when the player touches both. `inWater` / `inLava` say which touch, and
	           `eyeFluid` which fluid the eyes are in (Entity.updateFluidOnEyes);
	  falling  the fall distance is counted while airborne and turned into damage on landing
	           (ceil(distance - 3) half hearts); water resets it. Players who may fly (creative,
	           spectator) never take fall damage;
	  flying   (State.mayFly: creative) double tapping jump within 7 ticks toggles it: air
	           acceleration the flying speed (State.flyingSpeed, 0.05; doubled sprinting: 10.89 and
	           21.78 m/s), jump / sneak add 3 x the flying speed (0.15) up / down per tick and the
	           vertical speed keeps 0.6 of itself (at most 0.375 blocks per tick), no gravity,
	           crouching, edge back-off or swimming; landing stops it;
	  spectator (State.noClip, Player.noPhysics) always flying, through everything: no collision,
	           never on the ground, no fall distance, untouched by fluids (no water, swimming or
	           currents), always standing, no pushing out of blocks. Only the height is kept
	           within NO_CLIP_MIN_Y .. NO_CLIP_MAX_Y. The mouse wheel changes the flying speed
	           (scrollFlyingSpeed: steps of 0.005 between 0 and 0.2, MouseHandler.onScroll);
	  in a wall  `isInWall` (Entity.isInWall): the eyes in a block the player suffocates in, which
	           hurts (the server's Players/GameModeRules.inWall), e.g. after leaving spectator in rock.

	`setGameMode` gives a state the abilities of a game mode (Shared/GameMode), as Minecraft's
	GameType.updatePlayerAbilities does. `knockback` adds an explosion's push to the velocity
	(not for spectators or creative flight).

	Units are blocks and ticks: positions in blocks (feet centre), velocities in blocks per tick.
	Speeds of Minecraft's Abilities are floats, so they are kept rounded to floats here too.
	Pure Luau and deterministic, so the same code can run on the server or in tests.
]]

local Blocks = require(script.Parent.Parent.Blocks)
local Config = require(script.Parent.Parent.Config)
local Fluids = require(script.Parent.Parent.Fluids)
local GameMode = require(script.Parent.Parent.GameMode)
local FluidFlow = require(script.Parent.Parent.World.FluidFlow)
local Hull = require(script.Parent.Hull)

type Box = Hull.Box

local PlayerPhysics = {}

-- Ticks per second.
PlayerPhysics.TICK_RATE = 20

-- Minecraft constants (floats where Minecraft uses floats).
local GRAVITY = 0.08
local VERTICAL_DRAG = 0.98
local AIR_DRAG = 0.91
local WALK_SPEED = 0.1
local SPRINT_SPEED = 0.13 -- walk speed * 1.3 (sprinting modifier)
local AIR_ACCELERATION = 0.02
local SPRINT_AIR_ACCELERATION = 0.025999999
local GROUND_FACTOR = 0.21600002 -- = 0.6^3: speed is unchanged on normal blocks
local JUMP_POWER = 0.42
local SPRINT_JUMP_BOOST = 0.2
-- Minecraft's player step height. Also how far below the feet sneaking looks for ground at an edge
-- (whatever the state's own step height), so sneaking always stops at block edges.
local STEP_HEIGHT = 0.6
local INPUT_SCALE = 0.98
local SNEAK_FACTOR = 0.3
local JUMP_DELAY = 10
local MIN_VELOCITY = 0.003
local SPRINT_IMPULSE = 0.8
local DOUBLE_TAP_TICKS = 7
local MINOR_COLLISION_ANGLE = 0.13962634 -- 8 degrees

local WATER_ACCELERATION = 0.019999999552965164 -- 0.02F
local WATER_DRAG = 0.800000011920929 -- 0.8F
local LAVA_DRAG = 0.5
local WATER_SPRINT_DRAG = 0.8999999761581421 -- 0.9F
local WATER_VERTICAL_DRAG = 0.800000011920929
local WATER_JUMP = 0.03999999910593033 -- 0.04F
local WATER_EXIT_HOP = 0.30000001192092896 -- 0.3F
local WATER_EXIT_RISE = 0.6000000238418579 -- 0.6F
local FLUID_JUMP_THRESHOLD = 0.4
-- Lava's travel branch (LivingEntity.travel): its vertical drag over shallow lava, and gravity / 4.
local LAVA_VERTICAL_DRAG = 0.800000011920929
local LAVA_GRAVITY = GRAVITY / 4
-- Entity.baseTick: in lava the fall distance halves every tick (0.5F).
local LAVA_FALL_FACTOR = 0.5

-- The fluid of each block (Shared/Fluids id per block id, 0 none: every level and cave twin).
local fluidLut = Fluids.blockLut
-- Per fluid id: moves the player like lava (LivingEntity.travel's isInLava branch) rather than
-- like water, its drag, push and whether the player swims in it (FluidList).
local LAVA_LIKE: { [number]: boolean } = {}
local DRAG: { [number]: number } = {}
local PUSH: { [number]: number } = {}
local SWIM: { [number]: boolean } = {}
for id, fluid in Fluids.list do
	LAVA_LIKE[id] = fluid.physics == "lava"
	DRAG[id] = fluid.drag
	PUSH[id] = fluid.push
	SWIM[id] = fluid.swim
end

local FALL_SAFE = 3

-- Flight (Abilities.flyingSpeed 0.05F, doubled when sprinting; jump / sneak add it x 3). The
-- spectators' mouse wheel changes it in steps of 0.005F between 0 and 0.2F.
local FLYING_SPEED = 0.05000000074505806 -- 0.05F
local MAX_FLYING_SPEED = 0.20000000298023224 -- 0.2F
local FLYING_SPEED_STEP = 0.004999999888241291 -- 0.005F
local FLYING_VERTICAL_DRAG = 0.6
PlayerPhysics.FLYING_SPEED = FLYING_SPEED
PlayerPhysics.MAX_FLYING_SPEED = MAX_FLYING_SPEED
PlayerPhysics.FLYING_SPEED_STEP = FLYING_SPEED_STEP

-- Heights (feet, blocks) a spectator moves between: the bottom of the world and 64 blocks past its
-- top. Below the bottom there is no void as in Minecraft: everything there is bedrock to the client
-- and the server, so nothing to see, and a spectator leaving the mode there would be walled in.
local NO_CLIP_MIN_Y = 0
local NO_CLIP_MAX_Y = Config.WorldHeight + 64
PlayerPhysics.NO_CLIP_MIN_Y = NO_CLIP_MIN_Y
PlayerPhysics.NO_CLIP_MAX_Y = NO_CLIP_MAX_Y

-- Rounds to the nearest float (Java's float arithmetic: one double operation on floats, then
-- rounded, gives the same float).
local floatScratch = buffer.create(4)
local function float(value: number): number
	buffer.writef32(floatScratch, 0, value)
	return buffer.readf32(floatScratch, 0)
end

-- Box sizes (width, height, eye height) of each pose.
export type Pose = "standing" | "crouching" | "crawling"
export type Dimensions = { width: number, height: number, eye: number }
local POSES: { [string]: Dimensions } = {
	standing = { width = 0.6, height = 1.8, eye = 1.62 },
	crouching = { width = 0.6, height = 1.5, eye = 1.27 },
	crawling = { width = 0.6, height = 0.6, eye = 0.4 },
}
PlayerPhysics.STANDING = POSES.standing

function PlayerPhysics.dimensions(pose: Pose): Dimensions
	return POSES[pose]
end

export type State = {
	-- Feet centre (blocks) and velocity (blocks per tick).
	x: number,
	y: number,
	z: number,
	vx: number,
	vy: number,
	vz: number,
	pose: Pose,
	-- Highest step walked up without jumping (blocks).
	stepHeight: number,
	onGround: boolean,
	horizontalCollision: boolean,
	minorHorizontalCollision: boolean,
	verticalCollision: boolean,
	sprinting: boolean,
	-- Shift held (this tick: edge safe; last tick's value makes it slow) and crouched (sneaking
	-- or no room to stand).
	sneaking: boolean,
	crouching: boolean,
	-- Block the player stands on (x, z), when on the ground (Entity.mainSupportingBlockPos).
	supportX: number?,
	supportZ: number?,
	fallDistance: number,
	noJumpDelay: number,
	sprintTriggerTime: number,
	-- Had enough forward input to sprint last tick (for the double tap).
	hadSprintImpulse: boolean,
	-- Touching water (a fluid moving the player like water: water, fuel), how high it reaches above
	-- the feet (blocks), whether the eyes are in it (and were last tick: under water), and
	-- swimming (sprinting under water: 0.6 tall, steered by the view's pitch).
	inWater: boolean,
	waterHeight: number,
	eyeInWater: boolean,
	underWater: boolean,
	swimming: boolean,
	-- Touching lava (a fluid moving the player like lava: lava, oil) and how high it reaches.
	inLava: boolean,
	lavaHeight: number,
	-- The fluid the eyes are in (Shared/Fluids id, 0 none; Entity.updateFluidOnEyes).
	eyeFluid: number,
	-- Flight: allowed (creative, spectator), flying now, ticks left to double tap jump
	-- (Player.jumpTriggerTime) and whether jump was held last tick. setGameMode sets these.
	mayFly: boolean,
	flying: boolean,
	jumpTriggerTime: number,
	wasJumping: boolean,
	-- Spectator (Player.noPhysics): always flying, through blocks, untouched by fluids.
	noClip: boolean,
	-- Abilities.flyingSpeed (a float): flying acceleration, x 2 sprinting, x 3 up and down.
	flyingSpeed: number,
}

export type Input = {
	-- Wanted movement direction in world space (x, z), length up to 1 (already turned by the camera).
	moveX: number,
	moveZ: number,
	-- How much of that is "forward" (0..1): sprinting needs 0.8.
	forward: number,
	-- Direction the player faces (x, z unit vector): where a sprint jump goes.
	facingX: number,
	facingZ: number,
	-- Vertical part of the view direction (-1 down .. 1 up): where swimming goes.
	lookY: number,
	jump: boolean,
	sneak: boolean,
	-- Sprint key held.
	sprint: boolean,
}

export type World = {
	-- Block id at (x, y, z), or nil where nothing is loaded (treated as solid rock).
	getBlock: (x: number, y: number, z: number) -> number?,
}

export type Events = {
	jumped: boolean,
	-- Height (blocks) stepped up onto something this tick, 0 if none.
	stepUp: number,
	-- Landed this tick after falling `fallDistance` blocks; `damage` in half hearts (0 = none).
	landed: boolean,
	fallDistance: number,
	damage: number,
}

local floor = math.floor
local abs = math.abs
local sqrt = math.sqrt

function PlayerPhysics.new(x: number, y: number, z: number): State
	return {
		x = x,
		y = y,
		z = z,
		vx = 0,
		vy = 0,
		vz = 0,
		pose = "standing",
		stepHeight = STEP_HEIGHT,
		onGround = false,
		horizontalCollision = false,
		minorHorizontalCollision = false,
		verticalCollision = false,
		sprinting = false,
		sneaking = false,
		crouching = false,
		supportX = nil,
		supportZ = nil,
		fallDistance = 0,
		noJumpDelay = 0,
		sprintTriggerTime = 0,
		hadSprintImpulse = false,
		inWater = false,
		waterHeight = 0,
		eyeInWater = false,
		underWater = false,
		swimming = false,
		inLava = false,
		lavaHeight = 0,
		eyeFluid = 0,
		mayFly = false,
		flying = false,
		jumpTriggerTime = 0,
		wasJumping = false,
		noClip = false,
		flyingSpeed = FLYING_SPEED,
	}
end

--[[
	Gives the player the movement abilities of game `mode` (GameType.updatePlayerAbilities, then the
	abilities the server sends, which reset the flying speed):
	  creative          may fly; flying stays as it was (from spectator it keeps flying);
	  spectator         flies through everything (noClip), always;
	  survival, adventure  no flying: the player falls.
	Leaving or entering spectator also forgets the collision flags.
]]
function PlayerPhysics.setGameMode(state: State, mode: string)
	local noClip = GameMode.noClip(mode)
	state.mayFly = GameMode.mayFly(mode)
	if GameMode.alwaysFlying(mode) then
		state.flying = true
	elseif not state.mayFly then
		state.flying = false
	end
	if noClip ~= state.noClip then
		state.noClip = noClip
		state.onGround = false
		state.horizontalCollision = false
		state.minorHorizontalCollision = false
		state.verticalCollision = false
		state.supportX, state.supportZ = nil, nil
		state.fallDistance = 0
	end
	state.flyingSpeed = FLYING_SPEED
end

--[[
	The mouse wheel while spectating (MouseHandler.onScroll): `steps` whole notches (positive:
	faster) change the flying speed by 0.005 each, kept within 0 .. 0.2. Returns the new speed.
]]
function PlayerPhysics.scrollFlyingSpeed(state: State, steps: number): number
	local speed = float(state.flyingSpeed + float(steps * FLYING_SPEED_STEP))
	state.flyingSpeed = math.clamp(speed, 0, MAX_FLYING_SPEED)
	return state.flyingSpeed
end

-- Box of the player in its current pose.
function PlayerPhysics.box(state: State): Box
	local dims = POSES[state.pose]
	return Hull.box(state.x, state.y, state.z, dims.width, dims.height)
end

function PlayerPhysics.eyeHeight(state: State): number
	return POSES[state.pose].eye
end

-- Moves the player to (x, y, z) at rest (teleports, respawns).
function PlayerPhysics.place(state: State, x: number, y: number, z: number)
	state.x, state.y, state.z = x, y, z
	state.vx, state.vy, state.vz = 0, 0, 0
	state.fallDistance = 0
	state.onGround = false
	state.sprinting = false
end

--[[
	An explosion's knockback (kx, ky, kz blocks per tick; the server's Explosion message, Shared/
	World/Explosion.hit), added to the velocity as Minecraft's client does with the explosion
	packet's. Not for spectators (noClip) nor a player flying who may fly (Minecraft's server
	leaves creative flight out of the packet's knockback). Returns whether it was applied.
]]
function PlayerPhysics.knockback(state: State, kx: number, ky: number, kz: number): boolean
	if state.noClip or (state.flying and state.mayFly) then
		return false
	end
	if not (kx == kx and ky == ky and kz == kz) or (kx == 0 and ky == 0 and kz == 0) then
		return false
	end
	state.vx += kx
	state.vy += ky
	state.vz += kz
	return true
end

local function solidChecker(world: World): Hull.SolidAt
	local getBlock = world.getBlock
	return function(x: number, y: number, z: number): boolean
		local block = getBlock(x, y, z)
		return block == nil or Blocks.isSolid(block)
	end
end

--[[
	LocalPlayer.suffocatesAt: does block column (bx, bz), over the height of the hull, hold a block
	the player would suffocate in (a solid, opaque one; unloaded counts too)?
]]
local function suffocatesAt(world: World, state: State, bx: number, bz: number): boolean
	local height = POSES[state.pose].height
	local minY, maxY = state.y + 1.0e-7, state.y + height - 1.0e-7
	for by = math.floor(minY), math.ceil(maxY) - 1 do
		local block = world.getBlock(bx, by, bz)
		if block == nil or (Blocks.isSolid(block) and Blocks.isOpaque(block)) then
			return true
		end
	end
	return false
end

-- Width of the box at the eyes that suffocates (Entity.isInWall: 0.8 of the player's 0.6).
local IN_WALL_WIDTH = 0.48000001907348633 -- 0.6F * 0.8F

--[[
	Entity.isInWall: are the eyes at (x, eyeY, z) (blocks) in a wall, that is does a box
	IN_WALL_WIDTH wide and 1e-6 tall around them overlap a block the player suffocates in (solid and
	opaque, suffocatesAt's test; never an unloaded one)? Minecraft hurts players in a wall every
	tick (LivingEntity.baseTick), which the server does (Players/GameModeRules.inWall). Spectators
	(noPhysics) never are; that is the caller's to check. The position must be in the world (finite).
]]
function PlayerPhysics.isInWall(world: World, x: number, eyeY: number, z: number): boolean
	local half = IN_WALL_WIDTH / 2
	for bx = floor(x - half), math.ceil(x + half) - 1 do
		for by = floor(eyeY - 5.0e-7), math.ceil(eyeY + 5.0e-7) - 1 do
			for bz = floor(z - half), math.ceil(z + half) - 1 do
				local block = world.getBlock(bx, by, bz)
				if block ~= nil and Blocks.isSolid(block) and Blocks.isOpaque(block) then
					return true
				end
			end
		end
	end
	return false
end

-- West, east, north, south, in Minecraft's order.
local PUSH_SIDES = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }

--[[
	LocalPlayer.moveTowardsClosestSpace: a player stuck in a block (placed on them, sand fallen on
	them) is pushed at 0.1 blocks per tick towards the nearest side that is free.
]]
local function moveTowardsClosestSpace(world: World, state: State, x: number, z: number)
	local bx, bz = math.floor(x), math.floor(z)
	if not suffocatesAt(world, state, bx, bz) then
		return
	end
	local dx, dz = x - bx, z - bz
	local best, push = math.huge, nil
	for _, side in PUSH_SIDES do
		local along = if side[1] ~= 0 then dx else dz
		local distance = if side[1] + side[2] > 0 then 1 - along else along
		if distance < best and not suffocatesAt(world, state, bx + side[1], bz + side[2]) then
			best, push = distance, side
		end
	end
	if push then
		if push[1] ~= 0 then
			state.vx = 0.1 * push[1]
		else
			state.vz = 0.1 * push[2]
		end
	end
end

-- The fluid of a block (Shared/Fluids id, 0: none or unloaded).
local function fluidOf(block: number?): number
	return if block then buffer.readu8(fluidLut, block) else 0
end

-- Can the player swim in `block` (Fluids `swim`: water, fuel)?
local function isSwimmable(block: number?): boolean
	return SWIM[fluidOf(block)] == true
end

-- Height of the surface of fluid `fluid` in block (x, y, z) above its bottom (FluidState.getHeight):
-- full when the same fluid is above, else its level's height.
local function fluidHeight(world: World, x: number, y: number, z: number, block: number, fluid: number): number
	if fluidOf(world.getBlock(x, y + 1, z)) == fluid then
		return 1
	end
	return buffer.readu8(Blocks.fluidHeightLut, block) / Blocks.FLUID_FULL
end

-- Any fluid overlapping the box (Level.containsAnyLiquid)?
local function containsFluid(world: World, box: Box): boolean
	for x = floor(box.minX), math.ceil(box.maxX) - 1 do
		for y = floor(box.minY), math.ceil(box.maxY) - 1 do
			for z = floor(box.minZ), math.ceil(box.maxZ) - 1 do
				if fluidOf(world.getBlock(x, y, z)) ~= 0 then
					return true
				end
			end
		end
	end
	return false
end

-- Does any water (a fluid moving the player like water) reach into the box (deflated by 0.001)?
local function touchesWater(state: State, world: World): boolean
	local box = PlayerPhysics.box(state)
	local minY = box.minY + 0.001
	for x = floor(box.minX + 0.001), math.ceil(box.maxX - 0.001) - 1 do
		for y = floor(minY), math.ceil(box.maxY - 0.001) - 1 do
			for z = floor(box.minZ + 0.001), math.ceil(box.maxZ - 0.001) - 1 do
				local block = world.getBlock(x, y, z)
				local fluid = fluidOf(block)
				if
					fluid ~= 0
					and not LAVA_LIKE[fluid]
					and y + fluidHeight(world, x, y, z, block :: number, fluid) >= minY
				then
					return true
				end
			end
		end
	end
	return false
end

--[[
	The fluids of one kind around the player (Entity.updateFluidHeightAndDoFluidPushing for one
	tag: `lava` false, water and fuel; true, lava and oil): whether any touches the box, how high
	it reaches above the box bottom, the drag of the deepest (Fluids `drag`), and the flow's push
	added to the velocity (each cell's flow times its fluid's `push`).
]]
local function updateFluid(state: State, world: World, lava: boolean): (boolean, number, number)
	local box = PlayerPhysics.box(state)
	local minX, minY, minZ = box.minX + 0.001, box.minY + 0.001, box.minZ + 0.001
	local maxX, maxY, maxZ = box.maxX - 0.001, box.maxY - 0.001, box.maxZ - 0.001
	local height = 0
	local touching = false
	local drag = if lava then LAVA_DRAG else WATER_DRAG
	local px, py, pz, cells = 0, 0, 0, 0
	for x = floor(minX), math.ceil(maxX) - 1 do
		for y = floor(minY), math.ceil(maxY) - 1 do
			for z = floor(minZ), math.ceil(maxZ) - 1 do
				local block = world.getBlock(x, y, z)
				local fluid = fluidOf(block)
				if fluid ~= 0 and LAVA_LIKE[fluid] == lava then
					local surface = y + fluidHeight(world, x, y, z, block :: number, fluid)
					if surface >= minY then
						touching = true
						if surface - minY >= height then
							drag = DRAG[fluid]
						end
						height = math.max(surface - minY, height)
						local fx, fy, fz = FluidFlow.at(world.getBlock, x, y, z)
						-- (`height` is the deepest so far, not this cell's: Minecraft's quirk.)
						if height < 0.4 then
							fx, fy, fz = fx * height, fy * height, fz * height
						end
						local push = PUSH[fluid]
						px, py, pz = px + fx * push, py + fy * push, pz + fz * push
						cells += 1
					end
				end
			end
		end
	end
	local length = sqrt(px * px + py * py + pz * pz)
	-- A flying player is not pushed by currents (Player.isPushedByFluid).
	if length > 0 and not state.flying then
		px, py, pz = px / cells, py / cells, pz / cells
		length = length / cells
		if abs(state.vx) < MIN_VELOCITY and abs(state.vz) < MIN_VELOCITY and length < 0.0045 then
			px, py, pz = px / length * 0.0045, py / length * 0.0045, pz / length * 0.0045
		end
		state.vx += px
		state.vy += py
		state.vz += pz
	end
	return touching, height, drag
end

--[[
	Fluids around the player (Entity.updateInWaterStateAndDoFluidPushing, then updateFluidOnEyes
	and updateSwimming): water first (it resets the fall distance), then lava; the fluid at the
	eyes; swimming. Returns the drag of the deepest water and of the deepest lava touched (Fluids
	`drag`; Minecraft's 0.8 and 0.5 when none).
]]
local function updateFluids(state: State, world: World): (number, number)
	local touching, height, waterDrag = updateFluid(state, world, false)
	state.inWater = touching
	state.waterHeight = height
	if touching then
		state.fallDistance = 0
	end
	local inLava, lavaHeight, lavaDrag = updateFluid(state, world, true)
	state.inLava = inLava
	state.lavaHeight = lavaHeight

	-- The fluid at the eyes (Entity.updateFluidOnEyes); "under water" uses last tick's eyes.
	local eyeY = state.y + PlayerPhysics.eyeHeight(state) - 0.1111111119389534
	local bx, by, bz = floor(state.x), floor(eyeY), floor(state.z)
	local block = world.getBlock(bx, by, bz)
	local eyeFluid = fluidOf(block)
	if eyeFluid ~= 0 and by + fluidHeight(world, bx, by, bz, block :: number, eyeFluid) <= eyeY then
		eyeFluid = 0
	end
	state.underWater = state.eyeInWater and touching
	state.eyeFluid = eyeFluid
	state.eyeInWater = eyeFluid ~= 0 and not LAVA_LIKE[eyeFluid]

	-- Swimming (Entity.updateSwimming): sprinting under water, until sprinting stops or the water
	-- ends. Never while flying (Player.updateSwimming), only in a fluid one swims in (Fluids
	-- `swim`: the water tag).
	if state.flying then
		state.swimming = false
	elseif state.swimming then
		state.swimming = state.sprinting and touching
	else
		local feet = world.getBlock(floor(state.x), floor(state.y), floor(state.z))
		state.swimming = state.sprinting and state.underWater and isSwimmable(feet)
	end
	return waterDrag, lavaDrag
end

-- Friction of the block the player walks on (getBlockPosBelowThatAffectsMyMovement): below the
-- supporting block when standing on one (also at an edge, where the block under the centre is air).
local function frictionBelow(state: State, world: World): number
	local x, z = state.supportX or floor(state.x), state.supportZ or floor(state.z)
	local block = world.getBlock(x, floor(state.y - 0.500001), z)
	return if block then Blocks.get(block).friction else 0.6
end

-- The solid block under the feet closest to the player (Entity.checkSupportingBlock).
local function findSupport(state: State, solidAt: Hull.SolidAt): (number?, number?)
	local box = PlayerPhysics.box(state)
	local bestX, bestZ, best = nil, nil, math.huge
	local y = floor(box.minY - 1.0e-6)
	for x = floor(box.minX + Hull.EPSILON), floor(box.maxX - Hull.EPSILON) do
		for z = floor(box.minZ + Hull.EPSILON), floor(box.maxZ - Hull.EPSILON) do
			if solidAt(x, y, z) then
				local dx, dy, dz = x + 0.5 - state.x, y + 0.5 - state.y, z + 0.5 - state.z
				local d = dx * dx + dy * dy + dz * dz
				if d < best then
					bestX, bestZ, best = x, z, d
				end
			end
		end
	end
	return bestX, bestZ
end

--[[
	Entity.move: back off edges when sneaking, collide, update collision flags, ground state and the
	fall distance, and stop the velocity on the axes that hit something.
]]
local function move(state: State, solidAt: Hull.SolidAt, world: World, inputX: number, inputZ: number, events: Events)
	local dx, dy, dz = state.vx, state.vy, state.vz
	local box = PlayerPhysics.box(state)

	-- Sneaking never walks off an edge (Player.maybeBackOffFromEdge), except when flying.
	if state.sneaking and not state.flying and dy <= 0 then
		local aboveGround = state.onGround
			or (
				state.fallDistance < STEP_HEIGHT
				and not Hull.noCollision(solidAt, Hull.offset(box, 0, state.fallDistance - STEP_HEIGHT, 0))
			)
		if aboveGround then
			dx, dz = Hull.backOffFromEdge(solidAt, box, dx, dz, STEP_HEIGHT)
		end
	end

	local rx, ry, rz, stepped = Hull.collide(solidAt, box, dx, dy, dz, state.stepHeight, state.onGround)
	if stepped and ry > 0 then
		events.stepUp = ry
	end
	if rx * rx + ry * ry + rz * rz > 1.0e-7 then
		state.x += rx
		state.y += ry
		state.z += rz
	end

	local hitX = abs(dx - rx) >= 1.0e-5
	local hitZ = abs(dz - rz) >= 1.0e-5
	state.horizontalCollision = hitX or hitZ
	state.verticalCollision = dy ~= ry
	local landedNow = state.verticalCollision and dy < 0
	state.onGround = landedNow

	-- Running into a wall head on stops sprinting; sliding along it at a shallow angle does not.
	state.minorHorizontalCollision = false
	if state.horizontalCollision then
		local inputLength = inputX * inputX + inputZ * inputZ
		local moved = rx * rx + rz * rz
		if inputLength >= 1.0e-5 and moved >= 1.0e-5 then
			local cos = (inputX * rx + inputZ * rz) / sqrt(inputLength * moved)
			state.minorHorizontalCollision = math.acos(math.clamp(cos, -1, 1)) < MINOR_COLLISION_ANGLE
		end
	end

	if state.onGround then
		state.supportX, state.supportZ = findSupport(state, solidAt)
	else
		state.supportX, state.supportZ = nil, nil
	end

	-- Fall distance and landing (Entity.checkFallDamage); landing in water first resets it. Players
	-- who may fly take no fall damage at all (Player.causeFallDamage).
	if state.onGround and not state.inWater and touchesWater(state, world) then
		state.fallDistance = 0
	end
	if state.onGround then
		if state.fallDistance > 0 then
			events.landed = true
			events.fallDistance = state.fallDistance
			events.damage = if state.mayFly then 0 else math.max(0, math.ceil(state.fallDistance - FALL_SAFE))
		end
		state.fallDistance = 0
	elseif ry < 0 then
		state.fallDistance -= ry
	end

	if hitX then
		state.vx = 0
	end
	if hitZ then
		state.vz = 0
	end
	if state.verticalCollision then
		state.vy = 0
	end
end

--[[
	Entity.move for a spectator (noPhysics): straight to the new position, touching nothing. Only
	the height stays within NO_CLIP_MIN_Y .. NO_CLIP_MAX_Y.
]]
local function moveNoClip(state: State)
	state.x += state.vx
	state.y = math.clamp(state.y + state.vy, NO_CLIP_MIN_Y, NO_CLIP_MAX_Y)
	state.z += state.vz
	state.onGround = false
	state.horizontalCollision = false
	state.minorHorizontalCollision = false
	state.verticalCollision = false
	state.supportX, state.supportZ = nil, nil
	state.fallDistance = 0
end

-- Adds the input acceleration (Entity.moveRelative; the input is already in world space).
local function accelerate(state: State, speed: number, inputX: number, inputZ: number)
	local lengthSq = inputX * inputX + inputZ * inputZ
	if lengthSq < 1.0e-7 then
		return
	end
	if lengthSq > 1 then
		local length = sqrt(lengthSq)
		inputX, inputZ = inputX / length, inputZ / length
	end
	state.vx += inputX * speed
	state.vz += inputZ * speed
end

local function fits(solidAt: Hull.SolidAt, state: State, pose: Pose): boolean
	local dims = POSES[pose]
	local box = Hull.box(state.x, state.y, state.z, dims.width - 2.0e-7, dims.height - 2.0e-7)
	return Hull.noCollision(solidAt, Hull.offset(box, 0, 1.0e-7, 0))
end

--[[
	Advances the player one tick. Returns what happened (jumps, landings with fall damage).
]]
function PlayerPhysics.tick(state: State, input: Input, world: World): Events
	local solidAt = solidChecker(world)
	local events: Events = { jumped = false, stepUp = 0, landed = false, fallDistance = 0, damage = 0 }

	-- The game mode changed between ticks (the server updates the abilities): no flying without
	-- being allowed to; spectators always fly (LocalPlayer.aiStep: isAlwaysFlying).
	local noClip = state.noClip
	if noClip then
		state.flying = true
	elseif not state.mayFly then
		state.flying = false
	end

	-- Entity.baseTick: water, lava and their currents; in lava the fall distance halves.
	-- Spectators ignore fluids altogether.
	local waterDrag, lavaDrag = WATER_DRAG, LAVA_DRAG
	if noClip then
		state.inWater, state.waterHeight, state.eyeInWater, state.underWater = false, 0, false, false
		state.inLava, state.lavaHeight, state.eyeFluid = false, 0, 0
		state.swimming = false
	else
		waterDrag, lavaDrag = updateFluids(state, world)
		if state.inLava then
			state.fallDistance *= LAVA_FALL_FACTOR
		end
	end

	-- LocalPlayer.aiStep: crouching, input, sprinting. (Shift is read as it was last tick until the
	-- input updates, as in Minecraft, so sneaking slows the player one tick late.)
	if state.sprintTriggerTime > 0 then
		state.sprintTriggerTime -= 1
	end
	local prevShift = state.sneaking
	local prevImpulse = state.hadSprintImpulse
	local prevJump = state.wasJumping
	state.wasJumping = input.jump
	state.crouching = not state.flying
		and not state.swimming
		and fits(solidAt, state, "crouching")
		and (prevShift or not fits(solidAt, state, "standing"))
	local inputX, inputZ, forward = input.moveX, input.moveZ, input.forward
	-- Slow when crouching or crawling (the swimming pose out of water: isVisuallyCrawling).
	if state.crouching or (state.pose == "crawling" and not state.inWater) then
		inputX, inputZ, forward = inputX * SNEAK_FACTOR, inputZ * SNEAK_FACTOR, forward * SNEAK_FACTOR
	end
	state.sneaking = input.sneak
	local impulse = forward >= SPRINT_IMPULSE or (state.underWater and forward > 1.0e-5)
	state.hadSprintImpulse = impulse
	-- Out of blocks the player is stuck in, checked at four points inside the hull (not
	-- spectators, who belong in blocks).
	if not noClip then
		local inset = POSES[state.pose].width * 0.35
		moveTowardsClosestSpace(world, state, state.x - inset, state.z + inset)
		moveTowardsClosestSpace(world, state, state.x - inset, state.z - inset)
		moveTowardsClosestSpace(world, state, state.x + inset, state.z - inset)
		moveTowardsClosestSpace(world, state, state.x + inset, state.z + inset)
	end
	if prevShift then
		state.sprintTriggerTime = 0
	end
	-- Double tap forward: arms on the first tap, sprints on a second within DOUBLE_TAP_TICKS (or at
	-- once while the sprint key is held).
	if
		not state.sprinting
		and impulse
		and (state.onGround or state.underWater)
		and not prevShift
		and not prevImpulse
	then
		if state.sprintTriggerTime <= 0 and not input.sprint then
			state.sprintTriggerTime = DOUBLE_TAP_TICKS
		else
			state.sprinting = true
		end
	end
	if not state.sprinting and impulse and input.sprint and (not state.inWater or state.underWater) then
		state.sprinting = true
	end
	-- (Uses last tick's collision flags.)
	if state.sprinting then
		local noForward = forward <= 1.0e-5
		if state.swimming then
			if (not state.onGround and not input.sneak and noForward) or not state.inWater then
				state.sprinting = false
			end
		elseif
			noForward
			or (state.horizontalCollision and not state.minorHorizontalCollision)
			or (state.inWater and not state.underWater)
		then
			state.sprinting = false
		end
	end
	-- Double tapping jump toggles flying: the first press arms it for DOUBLE_TAP_TICKS (counted down
	-- in Player.aiStep below), a second press within them toggles (not while swimming, and never
	-- for spectators, who always fly).
	if state.mayFly and not noClip and input.jump and not prevJump then
		if state.jumpTriggerTime == 0 then
			state.jumpTriggerTime = DOUBLE_TAP_TICKS
		elseif not state.swimming then
			state.flying = not state.flying
			state.jumpTriggerTime = 0
		end
	end
	-- Sneaking in water sinks (LocalPlayer.goDownInWater). A flying player is not affected by
	-- fluids at all (Player.isAffectedByFluids): no sinking, swimming up or water movement.
	if state.inWater and input.sneak and not state.flying then
		state.vy -= WATER_JUMP
	end
	-- Flying: jump rises, sneak sinks, by 3 x the flying speed (a float).
	if state.flying then
		local direction = (if input.jump then 1 else 0) - (if input.sneak then 1 else 0)
		if direction ~= 0 then
			state.vy += float(float(direction * state.flyingSpeed) * 3)
		end
	end

	-- Player.aiStep.
	if state.jumpTriggerTime > 0 then
		state.jumpTriggerTime -= 1
	end

	-- LivingEntity.aiStep: jump delay, tiny velocities, jumping.
	if state.noJumpDelay > 0 then
		state.noJumpDelay -= 1
	end
	if abs(state.vx) < MIN_VELOCITY then
		state.vx = 0
	end
	if abs(state.vy) < MIN_VELOCITY then
		state.vy = 0
	end
	if abs(state.vz) < MIN_VELOCITY then
		state.vz = 0
	end
	if input.jump and not state.flying then
		-- (Minecraft reads the lava's height when in lava, else the water's.)
		local height = if state.inLava then state.lavaHeight elseif state.inWater then state.waterHeight else 0
		local swimming = state.inWater and height > 0
		local deep = not state.onGround or height > FLUID_JUMP_THRESHOLD
		if swimming and deep then
			state.vy += WATER_JUMP
		elseif state.inLava and deep then
			-- jumpInLiquid(LAVA): the same 0.04 a tick.
			state.vy += WATER_JUMP
		elseif (state.onGround or (swimming and height <= FLUID_JUMP_THRESHOLD)) and state.noJumpDelay == 0 then
			state.vy = JUMP_POWER
			if state.sprinting then
				state.vx += input.facingX * SPRINT_JUMP_BOOST
				state.vz += input.facingZ * SPRINT_JUMP_BOOST
			end
			state.noJumpDelay = JUMP_DELAY
			events.jumped = true
		end
	else
		state.noJumpDelay = 0
	end
	inputX, inputZ = inputX * INPUT_SCALE, inputZ * INPUT_SCALE

	-- Player.travel: swimming steers up and down with the view (not up out of the water by
	-- looking alone).
	if state.swimming then
		local look = input.lookY
		local rate = if look < -0.2 then 0.085 else 0.06
		if
			look <= 0
			or input.jump
			or fluidOf(world.getBlock(floor(state.x), floor(state.y + 0.9), floor(state.z))) ~= 0
		then
			state.vy += (look - state.vy) * rate
		end
	end

	-- LivingEntity.travel (Player.travel keeps the vertical speed from before it when flying).
	local flyingVy = state.vy
	if state.inWater and not state.flying then
		local startY = state.y
		local drag = if state.sprinting then WATER_SPRINT_DRAG else waterDrag
		accelerate(state, WATER_ACCELERATION, inputX, inputZ)
		move(state, solidAt, world, inputX, inputZ, events)
		state.vx *= drag
		state.vy *= WATER_VERTICAL_DRAG
		state.vz *= drag
		-- Gravity in water is a sixteenth, none while sprinting (Entity.getFluidFallingAdjustedMovement;
		-- its -0.003 case only applies with slow falling).
		if not state.sprinting then
			state.vy -= GRAVITY / 16
		end
		-- Swimming against a ledge just above the water hops out.
		if state.horizontalCollision then
			local box =
				Hull.offset(PlayerPhysics.box(state), state.vx, state.vy + WATER_EXIT_RISE - state.y + startY, state.vz)
			if Hull.noCollision(solidAt, box) and not containsFluid(world, box) then
				state.vy = WATER_EXIT_HOP
			end
		end
	elseif state.inLava and not state.flying then
		-- LivingEntity.travel's lava branch (oil too: Fluids `physics` "lava", its `drag`).
		local startY = state.y
		accelerate(state, WATER_ACCELERATION, inputX, inputZ)
		move(state, solidAt, world, inputX, inputZ, events)
		if state.lavaHeight <= FLUID_JUMP_THRESHOLD then
			-- Shallow: dragged sideways, and up and down like water, with its slow sinking
			-- (getFluidFallingAdjustedMovement: none while sprinting).
			state.vx *= lavaDrag
			state.vy *= LAVA_VERTICAL_DRAG
			state.vz *= lavaDrag
			if not state.sprinting then
				state.vy -= GRAVITY / 16
			end
		else
			state.vx *= lavaDrag
			state.vy *= lavaDrag
			state.vz *= lavaDrag
		end
		state.vy -= LAVA_GRAVITY
		-- Against a ledge just above the lava: hop out (as in water).
		if state.horizontalCollision then
			local box =
				Hull.offset(PlayerPhysics.box(state), state.vx, state.vy + WATER_EXIT_RISE - state.y + startY, state.vz)
			if Hull.noCollision(solidAt, box) and not containsFluid(world, box) then
				state.vy = WATER_EXIT_HOP
			end
		end
	else
		-- Friction and drag come from where the player stood before this tick's move.
		local friction = if state.onGround then frictionBelow(state, world) else 0.6
		local drag = if state.onGround then friction * AIR_DRAG else AIR_DRAG
		-- In the air: Player.getFlyingSpeed (flying or not; x 2 is exact in floats).
		local airSpeed = if state.flying
			then (if state.sprinting then state.flyingSpeed * 2 else state.flyingSpeed)
			else (if state.sprinting then SPRINT_AIR_ACCELERATION else AIR_ACCELERATION)
		local speed = if state.onGround
			then (if state.sprinting then SPRINT_SPEED else WALK_SPEED) * (GROUND_FACTOR / (friction * friction * friction))
			else airSpeed
		accelerate(state, speed, inputX, inputZ)
		if noClip then
			moveNoClip(state)
		else
			move(state, solidAt, world, inputX, inputZ, events)
		end
		state.vx *= drag
		state.vy = (state.vy - GRAVITY) * VERTICAL_DRAG
		state.vz *= drag
	end
	if state.flying then
		state.vy = flyingVy * FLYING_VERTICAL_DRAG
		state.fallDistance = 0
	end

	-- LocalPlayer.aiStep, after the move: touching the ground stops flying.
	if state.onGround and state.flying then
		state.flying = false
	end

	-- Player.updatePlayerPose: swim, crouch when sneaking (not when flying), and crouch or crawl
	-- whenever there is no room to stand. Stuck in blocks (not even crawling fits), the pose stays
	-- as it is. Spectators fly, so they stand, wherever they are.
	if noClip then
		state.pose = "standing"
	elseif fits(solidAt, state, "crawling") then
		local wanted: Pose = if state.swimming
			then "crawling"
			elseif input.sneak and not state.flying then "crouching"
			else "standing"
		if fits(solidAt, state, wanted) then
			state.pose = wanted
		elseif fits(solidAt, state, "crouching") then
			state.pose = "crouching"
		else
			state.pose = "crawling"
		end
	end

	return events
end

return PlayerPhysics
