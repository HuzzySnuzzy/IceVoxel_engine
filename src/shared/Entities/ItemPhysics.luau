--!strict
--[[
	Movement of dropped items, one 20 Hz tick at a time: Minecraft Java Edition 1.20.1's
	ItemEntity.tick with Entity.baseTick's fluid handling and Entity.move.

	An item is a 0.25 x 0.25 block box (Hull); its position is the bottom centre. Fluids come in
	Minecraft's two tags by their record's `physics` (Shared/Fluids): "water" (water, fuel) and
	"lava" (lava, oil), cave twins with their source. Every tick:

	  fluids    touching a fluid pushes the item along its current, water's tag first, then
	            lava's: the flow direction normalised (as for every entity that is not a player)
	            times the fluid's `push` (water and fuel 0.014, lava and oil 0.0023333), at least
	            0.0045 while the item is nearly still sideways (Entity.updateFluidHeightAndDo-
	            FluidPushing);
	  gravity   0.04 down, unless a fluid reaches more than eye height - 1/9 (0.1014) above the box
	            bottom: then the item floats, 0.0005 up while slower than 0.06, its horizontal speed
	            x 0.99 in water's tag (setUnderwaterMovement; Forge's FluidType.setItemMovement for
	            modded fluids) or x 0.95 in lava's (setUnderLavaMovement), water winning when both
	            are deep enough. Items rise to the surface and bob there;
	  stuck     an item inside a block (one was placed on it, sand fell on it) moves out towards the
	            nearest open side (north, south, west, east or up), through the blocks;
	  move      only while in the air, sliding (horizontal speed^2 > 1e-5) or every fourth tick
	            ((age + id) % 4 == 0), so resting items cost little. Collides like any entity,
	            without stepping up; landing or hitting a ceiling zeroes the vertical speed
	            (Block.updateEntityAfterFallOn), so items do not bounce off plain blocks;
	  friction  x 0.98 in the air and vertically; on the ground the supporting block's friction
	            x 0.98 horizontally (0.588 on stone, 0.96 on ice, so items slide far on ice);
	  fluids    the fluid check and current push run a second time at the end, as ItemEntity.tick
	            does, so currents carry items twice as fast as other entities.

	Minecraft picks the push-out speed at random (0.1..0.3); here it is always 0.2, so the client
	and the server, which both run this, stay in step given the same blocks. An item whose own
	block is not loaded (`getBlock` returns nil there) is frozen, like entities in unloaded
	chunks; other unloaded blocks count as solid.

	Units are blocks and ticks. Pure Luau, deterministic.
]]

local Blocks = require(script.Parent.Parent.Blocks)
local Fluids = require(script.Parent.Parent.Fluids)
local FluidFlow = require(script.Parent.Parent.World.FluidFlow)
local Hull = require(script.Parent.Parent.Movement.Hull)

type Box = Hull.Box

export type GetBlock = (x: number, y: number, z: number) -> number?

export type Body = {
	-- Bottom centre of the box (blocks) and velocity (blocks per tick).
	x: number,
	y: number,
	z: number,
	vx: number,
	vy: number,
	vz: number,
	onGround: boolean,
	-- Ticks lived (Minecraft's tickCount): drives the every-fourth-tick rule.
	age: number,
}

local ItemPhysics = {}

ItemPhysics.TICK_RATE = 20
ItemPhysics.WIDTH = 0.25
ItemPhysics.HEIGHT = 0.25

-- Minecraft's numbers (floats widened to doubles where Minecraft does).
local GRAVITY = 0.04
local DRAG = 0.9800000190734863 -- 0.98F
local VERTICAL_DRAG = 0.98
local BOUNCE = -0.5
local WATER_DRAG = 0.9900000095367432 -- 0.99F
local LAVA_DRAG = 0.949999988079071 -- 0.95F
local BUOYANCY = 0.0005000000237487257 -- 5.0E-4F
local BUOYANCY_LIMIT = 0.05999999865889549 -- 0.06F
-- A fluid must reach above eye height (0.85 x 0.25) - 0.11111111 for the item to float.
local FLOAT_DEPTH = 0.2125 - 0.1111111119389534
local RESTING_SPEED_SQ = 9.999999747378752e-6 -- 1.0E-5F
-- A current pushes a nearly still item (sideways speed under 0.003) at least this hard.
local MIN_PUSH = 0.0045000000000000005
local STILL_SPEED = 0.003
local PUSH_OUT_SPEED = 0.2
local MOVE_EPSILON_SQ = 1.0e-7
-- Mth.equal: how much an axis may be cut short before it counts as a collision.
local HIT_EPSILON = 9.999999747378752e-6
local SUPPORT_OFFSET = 0.500001

local floor = math.floor
local ceil = math.ceil
local sqrt = math.sqrt
local abs = math.abs

-- The block getter of the tick in progress, so collision callbacks need no closure per call.
local current: GetBlock = function(_x: number, _y: number, _z: number): number?
	return nil
end

local function solidAt(x: number, y: number, z: number): boolean
	local block = current(x, y, z)
	return block == nil or Blocks.isSolid(block)
end

-- The fluid of each block (Shared/Fluids id, 0 none; every level and cave twin), and per fluid
-- id whether it is in lava's tag (`physics` "lava": lava, oil) and its current's push.
local fluidLut = Fluids.blockLut
local LAVA_LIKE: { [number]: boolean } = {}
local PUSH: { [number]: number } = {}
for id, fluid in Fluids.list do
	LAVA_LIKE[id] = fluid.physics == "lava"
	PUSH[id] = fluid.push
end

local function fluidOf(block: number?): number
	return if block then buffer.readu8(fluidLut, block) else 0
end

-- Height of the surface of fluid `fluid` in block (x, y, z) above its bottom (FluidState.getHeight:
-- the whole block when the same fluid is above).
local function fluidHeight(x: number, y: number, z: number, block: number, fluid: number): number
	if fluidOf(current(x, y + 1, z)) == fluid then
		return 1
	end
	return buffer.readu8(Blocks.fluidHeightLut, block) / Blocks.FLUID_FULL
end

function ItemPhysics.new(x: number, y: number, z: number, vx: number?, vy: number?, vz: number?): Body
	return { x = x, y = y, z = z, vx = vx or 0, vy = vy or 0, vz = vz or 0, onGround = false, age = 0 }
end

function ItemPhysics.box(body: Body): Box
	return Hull.box(body.x, body.y, body.z, ItemPhysics.WIDTH, ItemPhysics.HEIGHT)
end

--[[
	Entity.updateFluidHeightAndDoFluidPushing for one tag (`lava` false: water and fuel; true: lava
	and oil): how high its fluids reach above the bottom of the box (0 when it touches none), after
	adding their current's push to the velocity.
]]
local function updateFluid(body: Body, lava: boolean): number
	local half = ItemPhysics.WIDTH / 2
	local minX, minY, minZ = body.x - half + 0.001, body.y + 0.001, body.z - half + 0.001
	local maxX, maxY, maxZ = body.x + half - 0.001, body.y + ItemPhysics.HEIGHT - 0.001, body.z + half - 0.001
	local depth = 0
	local push = 0
	local px, py, pz = 0, 0, 0
	for x = floor(minX), ceil(maxX) - 1 do
		for y = floor(minY), ceil(maxY) - 1 do
			for z = floor(minZ), ceil(maxZ) - 1 do
				local block = current(x, y, z)
				local fluid = fluidOf(block)
				if fluid ~= 0 and LAVA_LIKE[fluid] == lava then
					local surface = y + fluidHeight(x, y, z, block :: number, fluid)
					if surface >= minY then
						-- (The deepest fluid's push: one tag's fluids share Minecraft's.)
						if surface - minY >= depth then
							push = PUSH[fluid]
						end
						depth = math.max(surface - minY, depth)
						local fx, fy, fz = FluidFlow.at(current, x, y, z)
						-- (`depth` is the deepest so far, not this cell's: Minecraft's quirk.)
						if depth < 0.4 then
							fx, fy, fz = fx * depth, fy * depth, fz * depth
						end
						px, py, pz = px + fx, py + fy, pz + fz
					end
				end
			end
		end
	end
	local length = sqrt(px * px + py * py + pz * pz)
	if length > 0 then
		-- Averaged, then normalised (only players keep the length), so the push is always the
		-- fluid's, or the least push a nearly still item gets.
		if abs(body.vx) < STILL_SPEED and abs(body.vz) < STILL_SPEED and push < MIN_PUSH then
			push = MIN_PUSH
		end
		local scale = push / length
		body.vx += px * scale
		body.vy += py * scale
		body.vz += pz * scale
	end
	return depth
end

--[[
	Entity.moveTowardsClosestSpace: of the open sides of the block at the box's centre (north,
	south, west, east, up), the nearest one; up if none is open. The velocity towards it becomes
	the push-out speed and the other axes slow down to 0.75.
]]
local function pushOut(body: Body)
	local cx, cy, cz = body.x, body.y + ItemPhysics.HEIGHT / 2, body.z
	local bx, by, bz = floor(cx), floor(cy), floor(cz)
	local fx, fy, fz = cx - bx, cy - by, cz - bz
	-- Axis (1 = X, 2 = Y, 3 = Z) and sign of the best side; up by default.
	local axis, sign, best = 2, 1, math.huge
	local function consider(dx: number, dy: number, dz: number, a: number, s: number, distance: number)
		if distance < best and not solidAt(bx + dx, by + dy, bz + dz) then
			axis, sign, best = a, s, distance
		end
	end
	consider(0, 0, -1, 3, -1, fz) -- north
	consider(0, 0, 1, 3, 1, 1 - fz) -- south
	consider(-1, 0, 0, 1, -1, fx) -- west
	consider(1, 0, 0, 1, 1, 1 - fx) -- east
	consider(0, 1, 0, 2, 1, 1 - fy) -- up
	body.vx *= 0.75
	body.vy *= 0.75
	body.vz *= 0.75
	if axis == 1 then
		body.vx = sign * PUSH_OUT_SPEED
	elseif axis == 2 then
		body.vy = sign * PUSH_OUT_SPEED
	else
		body.vz = sign * PUSH_OUT_SPEED
	end
end

-- Friction of the block that carries the item: under the closest solid block below the box
-- (Entity.getBlockPosBelowThatAffectsMyMovement), else under the centre.
local function groundFriction(body: Body): number
	local half = ItemPhysics.WIDTH / 2
	local y = floor(body.y - 1.0e-6)
	local bestX, bestZ, best = floor(body.x), floor(body.z), math.huge
	for x = floor(body.x - half + Hull.EPSILON), floor(body.x + half - Hull.EPSILON) do
		for z = floor(body.z - half + Hull.EPSILON), floor(body.z + half - Hull.EPSILON) do
			if solidAt(x, y, z) then
				local dx, dy, dz = x + 0.5 - body.x, y + 0.5 - body.y, z + 0.5 - body.z
				local d = dx * dx + dy * dy + dz * dz
				if d < best then
					bestX, bestZ, best = x, z, d
				end
			end
		end
	end
	local block = current(bestX, floor(body.y - SUPPORT_OFFSET), bestZ)
	return if block then Blocks.get(block).friction else 0.6
end

-- Entity.move: collide (or pass through blocks when stuck), update the ground state and stop the
-- velocity on the axes that hit something.
local function move(body: Body, stuck: boolean)
	local dx, dy, dz = body.vx, body.vy, body.vz
	if stuck then
		-- noPhysics: straight through, the ground state stays as it was.
		body.x += dx
		body.y += dy
		body.z += dz
		return
	end
	local rx, ry, rz = Hull.collide(solidAt, ItemPhysics.box(body), dx, dy, dz, 0, body.onGround)
	if rx * rx + ry * ry + rz * rz > MOVE_EPSILON_SQ then
		body.x += rx
		body.y += ry
		body.z += rz
	end
	local vertical = dy ~= ry
	body.onGround = vertical and dy < 0
	if math.abs(dx - rx) >= HIT_EPSILON then
		body.vx = 0
	end
	if math.abs(dz - rz) >= HIT_EPSILON then
		body.vz = 0
	end
	if vertical then
		body.vy = 0
	end
end

--[[
	Advances the item one tick. `id` is the entity id (it staggers the resting items' moves);
	`getBlock` returns nil for blocks that are not loaded. Returns false (and changes nothing) when
	the item's own block is not loaded.
]]
function ItemPhysics.tick(body: Body, id: number, getBlock: GetBlock): boolean
	if getBlock(floor(body.x), floor(body.y), floor(body.z)) == nil then
		return false
	end
	local previous = current
	current = getBlock
	body.age += 1

	-- Entity.baseTick: the fluids and their currents, water's tag first.
	local waterDepth = updateFluid(body, false)
	local lavaDepth = updateFluid(body, true)

	-- Floating, or gravity.
	if waterDepth > FLOAT_DEPTH or lavaDepth > FLOAT_DEPTH then
		local drag = if waterDepth > FLOAT_DEPTH then WATER_DRAG else LAVA_DRAG
		body.vx *= drag
		body.vz *= drag
		if body.vy < BUOYANCY_LIMIT then
			body.vy += BUOYANCY
		end
	else
		body.vy -= GRAVITY
	end

	-- Stuck inside a block (the box shrunk by 1e-7 overlaps one): head for open space.
	local half = ItemPhysics.WIDTH / 2 - 1.0e-7
	local inner: Box = {
		minX = body.x - half,
		minY = body.y + 1.0e-7,
		minZ = body.z - half,
		maxX = body.x + half,
		maxY = body.y + ItemPhysics.HEIGHT - 1.0e-7,
		maxZ = body.z + half,
	}
	local stuck = not Hull.noCollision(solidAt, inner)
	if stuck then
		pushOut(body)
	end

	if not body.onGround or body.vx * body.vx + body.vz * body.vz > RESTING_SPEED_SQ or (body.age + id) % 4 == 0 then
		move(body, stuck)
		local friction = DRAG
		if body.onGround then
			friction = groundFriction(body) * DRAG
		end
		body.vx *= friction
		body.vy *= VERTICAL_DRAG
		body.vz *= friction
		if body.onGround and body.vy < 0 then
			body.vy *= BOUNCE
		end
	end

	-- ItemEntity.tick checks the fluids (and pushes) once more.
	updateFluid(body, false)
	updateFluid(body, true)

	current = previous
	return true
end

return ItemPhysics
