--!strict
--[[
	Explosions, pure: Minecraft 1.20.1's Explosion.explode / finalizeExplosion and
	getSeenPercent, with nothing but a block reader, so the server (World/Explosions) and the
	tests run the same maths.

	  Blocks   `affected`: 16 x 16 x 16 points on the surface of a cube around the centre (the
	           1352 with an index of 0 or 15 on some axis) give the directions of 1352 rays. Each
	           starts at the centre with an intensity of power x (0.7 + random x 0.6) and steps
	           0.3 blocks at a time; every step costs 0.22500001, plus (resistance + 0.3) x 0.3
	           when the cell is not air (Blocks `blastResistance`: stone 6, dirt 0.5, fluids
	           100, fuel 0), and a cell the ray reaches with intensity left is affected. So TNT
	           (power 4) reaches about 6.9 blocks through air, crumbles dirt within 3 to 4 and
	           bites less than 2 into stone; and an explosion in water breaks nothing (the first
	           step's 30 swallows any power up to 23). Air cells count too (Minecraft's toBlow
	           holds them: fire lands there). A ray stops at the world's floor and ceiling and at
	           blocks that are not loaded (getBlock nil), which are never touched.
	  Entities `hit`: an entity whose position (feet) is within 2 x power of the centre takes
	           impact = (1 - distance / (2 x power)) x seen, where `seen` (`seenPercent`) is the
	           share of points sampled over its box with a clear line to the centre (no solid
	           block between); damage = floor((impact^2 + impact) / 2 x 7 x 2 x power + 1) half
	           hearts (TNT at its centre: 57; behind a wall still 1), and it is pushed by impact
	           blocks per tick away from the centre, aimed at its eyes (Minecraft's
	           setDeltaMovement add; armor's Blast Protection would soften that, but nothing here
	           is enchanted).
	  Drops    each destroyed block drops with chance 1 / power (`dropChance`: the
	           survives_explosion loot condition of blocks broken by an explosion).
	  Fire     a fiery explosion (a ghast's fireball, a bed in the Nether, here burning fuel) sets
	           Fire on one in three of its affected cells that are air after the blast with an
	           opaque block below (`fireSpots`: random.nextInt(3) == 0, isAir, isSolidRender).

	Costs: a ray reads a block once per cell it enters (about one in three steps), so a power 4
	blast in open air reads about 9 000 blocks (1.7 ms interpreted) and power 12 about 26 000
	(7 ms); `affected` returns the count, for World/Explosions' per-tick budget.
]]

local Blocks = require(script.Parent.Parent.Blocks)
local Shapes = require(script.Parent.Parent.Blocks.Shapes)
local Config = require(script.Parent.Parent.Config)
local Coords = require(script.Parent.Coords)
local VoxelRaycast = require(script.Parent.VoxelRaycast)

export type GetBlock = (x: number, y: number, z: number) -> number?

local Explosion = {}

-- Minecraft's numbers (Explosion.explode).
Explosion.GRID = 16
Explosion.STEP = 0.3
Explosion.ATTENUATION = 0.22500001
-- Where an entity's damage and push run out: 2 x power.
Explosion.REACH = 2
-- One fiery cell in FIRE_ODDS gets fire (random.nextInt(3) == 0).
Explosion.FIRE_ODDS = 3

local HEIGHT = Config.WorldHeight
local AIR, CAVE_AIR = Blocks.AIR, Blocks.CAVE_AIR
local RESISTANCE = Blocks.blastResistanceLut
local readf32 = buffer.readf32
local floor = math.floor
local sqrt = math.sqrt
local posKey = Coords.posKey

-- The rays' unit directions, flat (x, y, z per ray), in Minecraft's loop order.
local RAYS: { number } = {}
do
	local last = Explosion.GRID - 1
	for j = 0, last do
		for k = 0, last do
			for l = 0, last do
				if j == 0 or j == last or k == 0 or k == last or l == 0 or l == last then
					local dx, dy, dz = j / last * 2 - 1, k / last * 2 - 1, l / last * 2 - 1
					local length = sqrt(dx * dx + dy * dy + dz * dz)
					table.insert(RAYS, dx / length)
					table.insert(RAYS, dy / length)
					table.insert(RAYS, dz / length)
				end
			end
		end
	end
end
Explosion.RAY_COUNT = #RAYS // 3
Explosion.RAYS = table.freeze(RAYS)

-- Does a ray lose intensity in `block` beyond the step's own (everything but air)?
local function costOf(block: number): number
	if block == AIR or block == CAVE_AIR then
		return 0
	end
	return (readf32(RESISTANCE, block * 4) + 0.3) * 0.3
end

--[[
	The cells an explosion of `power` at (x, y, z) (blocks) reaches: their Coords.posKey, each
	once, in the order the rays first reached them (air cells included). Also the block reads it
	took. `random` rolls in [0, 1).
]]
function Explosion.affected(
	getBlock: GetBlock,
	x: number,
	y: number,
	z: number,
	power: number,
	random: () -> number
): ({ number }, number)
	local cells: { number } = {}
	local seen: { [number]: boolean } = {}
	local reads = 0
	if not (power > 0) then
		return cells, 0
	end
	local step, attenuation = Explosion.STEP, Explosion.ATTENUATION
	for ray = 0, Explosion.RAY_COUNT - 1 do
		local dx, dy, dz = RAYS[ray * 3 + 1] * step, RAYS[ray * 3 + 2] * step, RAYS[ray * 3 + 3] * step
		local intensity = power * (0.7 + random() * 0.6)
		local px, py, pz = x, y, z
		-- The cell the ray is in (read once while it stays there).
		local cx, cy, cz = math.huge, math.huge, math.huge
		local cost, key = 0, 0
		while intensity > 0 do
			local bx, by, bz = floor(px), floor(py), floor(pz)
			if bx ~= cx or by ~= cy or bz ~= cz then
				if by < 0 or by >= HEIGHT then
					break
				end
				local block = getBlock(bx, by, bz)
				reads += 1
				if block == nil then
					break
				end
				cx, cy, cz = bx, by, bz
				cost = costOf(block)
				key = posKey(bx, by, bz)
			end
			intensity -= cost
			if intensity > 0 and not seen[key] then
				seen[key] = true
				table.insert(cells, key)
			end
			px += dx
			py += dy
			pz += dz
			intensity -= attenuation
		end
	end
	return cells, reads
end

-- Is the line from (ax, ay, az) to (bx, by, bz) blocked by a solid block (Minecraft's clip with
-- the blocks' collision shapes, fluids ignored)?
local function blocked(
	getBlock: GetBlock,
	ax: number,
	ay: number,
	az: number,
	bx: number,
	by: number,
	bz: number
): boolean
	local dx, dy, dz = bx - ax, by - ay, bz - az
	local length = sqrt(dx * dx + dy * dy + dz * dz)
	if length < 1e-9 then
		return false
	end
	-- (Through what collides, by its boxes: Minecraft's ClipContext COLLIDER; a closed door shields.)
	local stops, outline = Shapes.sight(getBlock)
	return VoxelRaycast.cast(ax, ay, az, dx, dy, dz, length, getBlock, stops, outline) ~= nil
end

--[[
	Minecraft's Explosion.getSeenPercent: the share (0..1) of points over the box
	(minX, minY, minZ)-(maxX, maxY, maxZ) with a clear line to (x, y, z). The points are spaced
	1 / (2 x size + 1) of the box apart on each axis (a player: 3 x 5 x 3, an item 2 x 2 x 2),
	shifted to centre them across.
]]
function Explosion.seenPercent(
	getBlock: GetBlock,
	x: number,
	y: number,
	z: number,
	minX: number,
	minY: number,
	minZ: number,
	maxX: number,
	maxY: number,
	maxZ: number
): number
	local sx = 1 / ((maxX - minX) * 2 + 1)
	local sy = 1 / ((maxY - minY) * 2 + 1)
	local sz = 1 / ((maxZ - minZ) * 2 + 1)
	if not (sx > 0 and sy > 0 and sz > 0) then
		return 0
	end
	local shiftX = (1 - floor(1 / sx) * sx) / 2
	local shiftZ = (1 - floor(1 / sz) * sz) / 2
	local clear, total = 0, 0
	local a = 0
	while a <= 1 do
		local b = 0
		while b <= 1 do
			local c = 0
			while c <= 1 do
				local px = minX + (maxX - minX) * a + shiftX
				local py = minY + (maxY - minY) * b
				local pz = minZ + (maxZ - minZ) * c + shiftZ
				if not blocked(getBlock, px, py, pz, x, y, z) then
					clear += 1
				end
				total += 1
				c += sz
			end
			b += sy
		end
		a += sx
	end
	return clear / total
end

-- Half hearts an entity takes from `impact` (0..1) of an explosion of `power`.
function Explosion.damage(power: number, impact: number): number
	return floor((impact * impact + impact) / 2 * 7 * (Explosion.REACH * power) + 1)
end

--[[
	What an explosion of `power` at (x, y, z) does to an entity at (px, py, pz) (feet) with its
	eyes at `eyeY`, `seen` (0..1, `seenPercent`) of it in the open: nil when out of reach (or
	exactly at the centre, which Minecraft skips), else the damage (half hearts) and the push
	(blocks per tick) to add to its velocity.
]]
function Explosion.hit(
	x: number,
	y: number,
	z: number,
	power: number,
	px: number,
	py: number,
	pz: number,
	eyeY: number,
	seen: number
): (number?, number, number, number)
	local reach = Explosion.REACH * power
	if not (reach > 0) then
		return nil, 0, 0, 0
	end
	local distance = sqrt((px - x) ^ 2 + (py - y) ^ 2 + (pz - z) ^ 2) / reach
	if distance > 1 then
		return nil, 0, 0, 0
	end
	local dx, dy, dz = px - x, eyeY - y, pz - z
	local length = sqrt(dx * dx + dy * dy + dz * dz)
	if length == 0 then
		return nil, 0, 0, 0
	end
	local impact = (1 - distance) * seen
	local push = impact / length
	return Explosion.damage(power, impact), dx * push, dy * push, dz * push
end

-- The chance a block destroyed by an explosion of `power` drops its items (1 / power).
function Explosion.dropChance(power: number): number
	return if power > 1 then 1 / power else 1
end

--[[
	Where a fiery explosion sets fire, after its blocks are gone: one in FIRE_ODDS of the affected
	cells (`cells`, Coords.posKey) that are air with an opaque block below. `random` rolls in
	[0, 1) once per cell, as Minecraft's nextInt(3) does.
]]
function Explosion.fireSpots(getBlock: GetBlock, cells: { number }, random: () -> number): { number }
	local spots = {}
	for _, key in cells do
		if random() * Explosion.FIRE_ODDS < 1 then
			local x, y, z = Coords.decodePosKey(key)
			local block = getBlock(x, y, z)
			local below = getBlock(x, y - 1, z)
			if (block == AIR or block == CAVE_AIR) and below ~= nil and Blocks.isOpaque(below) then
				table.insert(spots, key)
			end
		end
	end
	return spots
end

return Explosion
