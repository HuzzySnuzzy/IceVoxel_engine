--!strict
--!native
--[[
	A shot's flight, pure (server Weapons/ traces every shot with it). Hitscan along a gravity arc:
	a bullet leaves the eyes lifted by its gun's zero angle (`zeroLift`: the path crosses the sight
	line again at the zero distance), flies at its round's velocity under Config.Weapons.Gravity,
	and is stepped in Config.Weapons.SegmentSeconds of flight, each segment a straight ray (the
	chord of the arc), until it has flown `maxRange` blocks along its path (its round's range x 2.5,
	at most Config.Weapons.MaxRange). Hits resolve at once: the velocity only bends the path.

	  Blocks   Shared/World/VoxelRaycast on Shared/Blocks/Shapes.sight's collision boxes, so a
	           torch, a flower or water lets it by and a fence's arms or a closed door's panel
	           stop it. Consecutive segments share their ends and the traversal visits every cell a
	           segment crosses, so no wall is ever stepped over however fast the round. A cell that
	           is not loaded (`getBlock` nil) stops it: the flight ends there ("none"). Glass
	           (`rules.isGlass`) shatters when the shooter may (`rules.shatter`): the bullet goes on
	           with `rules.glassShare` of what it had (a "glass" impact for each pane, at most
	           MAX_PANES of them; the next stops it as any block). Blocks that `rules.passes`
	           (leaves) are flown through; anything else stops it ("block": no penetration). The
	           server shatters the panes itself after the trace, so every pellet of a shot meets the
	           same world.
	  Targets  every candidate's body and head boxes (`mobBoxes`, `playerBoxes`), and a mob's where
	           the shooter's client last saw it (`seenBody`, `seenHead`: server Weapons/ sets them
	           only within Config.Weapons.LagCompMax of where it is): each segment is slab-tested
	           against them (`enter`), the nearer of the two places counting. The nearest hit along
	           the path wins, block or box; the bullet stops in the first target it meets (a target
	           is hit once a pellet). The shooter (`shot.shooter`, a Target's `key`) is never one.
	  Heads    a ray that meets the head box counts as a head hit when the head is the first of
	           the two boxes it enters, or when it enters the body box at the head's height or
	           above (beside the head, where the box is only air). A ray that goes in through the
	           chest and on up into the head hits the chest.
	  Damage   the round's damage x the gun's scale (`shot.damage`) x `share` (1 out to the round's
	           range, then linearly down to its falloffMin at maxRange) x GlassShare per pane
	           passed; a head hit times `headFactor`: ZombieHead for zombie kinds (HelmetShare of
	           that when the look wears a helmet, hard hat or fire helmet), MobHead for other mobs,
	           PlayerHead for players. Armour is server Weapons/' and Players/Characters' affair.
	  Spread   `spreadDir`: uniform over the cone's disc (radius cone x sqrt(u), angle 2 pi v);
	           `pellets`: each pellet takes the shot's direction, then its own pellet cone (at most
	           12 pellets).
	  Bounds   `bounds`: the box a flight stays in (every segment's end), so the server asks for
	           the mobs near a shot once (Mobs/Mobs.targets) however long or bent its path.

	Boxes are { minX, minY, minZ, maxX, maxY, maxZ } in blocks. Heads (`mobBoxes`): a standing kind
	(1 block tall or more) x/z +- min(width / 2, 0.3), y from eye - 0.22 to max(height, eye + 0.2)
	above the feet (an ordinary zombie's 1.52..1.95); a low kind (the crawler) a 0.5 x 0.4 x 0.5
	head 0.25 blocks forward along its yaw (facing (sin yaw, cos yaw)), 0.2..0.6 up. A player's
	(`playerBoxes`): the body 0.6 wide from the feet to the eyes + 0.2, the head x/z +- 0.25 from
	the eyes - 0.22 to + 0.2 (the pose-aware eyes, server Players/PlayerPositions.eye).

	`trace` keeps what its block callbacks need at module level (it never yields), so a shot
	allocates only its impacts.
]]

local Config = require(script.Parent.Parent.Config)
local Blocks = require(script.Parent.Parent.Blocks)
local Shapes = require(script.Parent.Parent.Blocks.Shapes)
local VoxelRaycast = require(script.Parent.Parent.World.VoxelRaycast)
local Weapons = require(script.Parent)

-- A point or a direction (blocks).
export type Vec = { x: number, y: number, z: number }

-- { minX, minY, minZ, maxX, maxY, maxZ } (blocks).
export type Box = { number }

-- What `mobBoxes` reads of a mob kind (Shared/Entities/MobList.Kind has it).
export type BoxKind = { width: number, height: number, eye: number }

-- One projectile's flight (a bullet, a pellet or a bolt).
export type ShotSpec = {
	-- Blocks a second, blocks a second squared, the zero distance (blocks).
	velocity: number,
	gravity: number,
	zero: number,
	-- Full damage out to `range`; the flight ends at `maxRange`, where `falloffMin` of it is left.
	range: number,
	maxRange: number,
	falloffMin: number,
	-- Half hearts at full range (the round's damage x the gun's damageScale).
	damage: number,
	-- Seconds of flight a segment (Config.Weapons.SegmentSeconds).
	segment: number,
	-- Never a target (a Target's `key`: the shooter's Player).
	shooter: any?,
}

-- Something a shot may hit.
export type Target = {
	kind: "mob" | "player",
	-- A mob's id, or the Player.
	key: any,
	body: Box,
	head: Box,
	-- (Mobs) where the shooter's client last saw it, when within LagCompMax: also tested.
	seenBody: Box?,
	seenHead: Box?,
	-- (Mobs) a zombie kind, and whether its look wears a helmet, hard hat or fire helmet.
	zombie: boolean?,
	helmet: boolean?,
}

-- What blocks do to a shot (the server builds it from Config.Weapons and the shooter).
export type BlockRules = {
	-- Shatters on a hit (glass), when the shooter may build (`shatter`).
	isGlass: (block: number) -> boolean,
	shatter: boolean,
	-- Passed through (leaves).
	passes: (block: number) -> boolean,
	-- The damage share a shot keeps through each pane of glass.
	glassShare: number,
}

export type ImpactKind = "none" | "block" | "glass" | "mob" | "player"

-- Where a projectile hit something (or, "none", where its flight ended).
export type Impact = {
	kind: ImpactKind,
	x: number,
	y: number,
	z: number,
	-- Along the path (blocks).
	distance: number,
	-- The mob or player hit ("mob", "player").
	target: Target?,
	head: boolean,
	-- The block hit ("block", "glass"): its cell and id.
	cell: { number }?,
	block: number?,
	-- The damage share left there: falloff x glass passed (head and armour not counted).
	share: number,
	-- The way it was flying there (a unit vector; the server backs a recovered bolt out along it).
	dx: number?,
	dy: number?,
	dz: number?,
}

-- What Config.Weapons holds (the server may hand its own copy to the pure functions).
export type Settings = typeof(Config.Weapons)

type GetBlock = (x: number, y: number, z: number) -> number?
type Outline = (id: number, x: number, y: number, z: number) -> { number }?

local Ballistics = {}

-- Panes of glass one projectile goes through at most (the next stops it as any block).
Ballistics.MAX_PANES = 8
-- Segments of one flight at most (a guard: the slowest round, the crossbow's bolt, needs 50).
Ballistics.MAX_SEGMENTS = 1024

--[[ Boxes ]]

-- A mob's body and head boxes at (x, y, z) (its feet) facing `yaw` (see the header).
function Ballistics.mobBoxes(kind: BoxKind, x: number, y: number, z: number, yaw: number): (Box, Box)
	local half = kind.width / 2
	local body = { x - half, y, z - half, x + half, y + kind.height, z + half }
	if kind.height >= 1 then
		local h = math.min(half, 0.3)
		return body, { x - h, y + kind.eye - 0.22, z - h, x + h, y + math.max(kind.height, kind.eye + 0.2), z + h }
	end
	local cx, cz = x + math.sin(yaw) * 0.25, z + math.cos(yaw) * 0.25
	return body, { cx - 0.25, y + 0.2, cz - 0.25, cx + 0.25, y + 0.6, cz + 0.25 }
end

-- A player's body and head boxes from their feet and their eyes' height `eyeY` (world blocks).
function Ballistics.playerBoxes(fx: number, fy: number, fz: number, eyeY: number): (Box, Box)
	return { fx - 0.3, fy, fz - 0.3, fx + 0.3, eyeY + 0.2, fz + 0.3 }, {
		fx - 0.25,
		eyeY - 0.22,
		fz - 0.25,
		fx + 0.25,
		eyeY + 0.2,
		fz + 0.25,
	}
end

--[[
	Where the ray from (ox, oy, oz) along unit (ux, uy, uz) enters `box` within `limit` blocks (the
	slab test, as client Ui/WailaInfo.rayBox): its distance (0 when it starts inside), nil when it
	misses the box or meets it only beyond `limit`.
]]
function Ballistics.enter(
	box: Box,
	ox: number,
	oy: number,
	oz: number,
	ux: number,
	uy: number,
	uz: number,
	limit: number
): number?
	local near, far = 0, limit
	-- x
	local lo, hi = box[1], box[4]
	if math.abs(ux) < 1e-12 then
		if ox < lo or ox > hi then
			return nil
		end
	else
		local t1, t2 = (lo - ox) / ux, (hi - ox) / ux
		if t1 > t2 then
			t1, t2 = t2, t1
		end
		if t1 > near then
			near = t1
		end
		if t2 < far then
			far = t2
		end
		if near > far then
			return nil
		end
	end
	-- y
	lo, hi = box[2], box[5]
	if math.abs(uy) < 1e-12 then
		if oy < lo or oy > hi then
			return nil
		end
	else
		local t1, t2 = (lo - oy) / uy, (hi - oy) / uy
		if t1 > t2 then
			t1, t2 = t2, t1
		end
		if t1 > near then
			near = t1
		end
		if t2 < far then
			far = t2
		end
		if near > far then
			return nil
		end
	end
	-- z
	lo, hi = box[3], box[6]
	if math.abs(uz) < 1e-12 then
		if oz < lo or oz > hi then
			return nil
		end
	else
		local t1, t2 = (lo - oz) / uz, (hi - oz) / uz
		if t1 > t2 then
			t1, t2 = t2, t1
		end
		if t1 > near then
			near = t1
		end
		if t2 < far then
			far = t2
		end
		if near > far then
			return nil
		end
	end
	return near
end

-- Where a ray meets a body and head pair within `limit` (see the header's Heads): the distance and
-- whether it is a head hit; nil when it meets neither.
local function boxesHit(
	body: Box,
	head: Box,
	ox: number,
	oy: number,
	oz: number,
	ux: number,
	uy: number,
	uz: number,
	limit: number
): (number?, boolean)
	local enter = Ballistics.enter
	local tb = enter(body, ox, oy, oz, ux, uy, uz, limit)
	local th = enter(head, ox, oy, oz, ux, uy, uz, limit)
	if th ~= nil and (tb == nil or th <= tb or oy + uy * tb >= head[2]) then
		return th, true
	end
	return tb, false
end

--[[
	Where a ray from (ox, oy, oz) along unit (ux, uy, uz) meets `target` within `limit` blocks:
	the distance and whether it is a head hit (see the header's Heads), the nearer of where it is
	and where it was seen; nil when it misses.
]]
function Ballistics.hit(
	target: Target,
	ox: number,
	oy: number,
	oz: number,
	ux: number,
	uy: number,
	uz: number,
	limit: number
): (number?, boolean)
	local t, head = boxesHit(target.body, target.head, ox, oy, oz, ux, uy, uz, limit)
	local seenBody, seenHead = target.seenBody, target.seenHead
	if seenBody and seenHead then
		local st, sh = boxesHit(seenBody, seenHead, ox, oy, oz, ux, uy, uz, if t then t else limit)
		if st ~= nil and (t == nil or st < t) then
			return st, sh
		end
	end
	return t, head
end

--[[ Spread, zero, falloff ]]

--[[
	A direction within `cone` degrees (half angle) of unit (dx, dy, dz), uniform over the cone's
	disc: radius cone x sqrt(u), angle 2 pi v (u, v in [0, 1)).
]]
function Ballistics.spreadDir(
	dx: number,
	dy: number,
	dz: number,
	cone: number,
	u: number,
	v: number
): (number, number, number)
	if not (cone > 0) then
		return dx, dy, dz
	end
	-- Two unit vectors square to the direction and to each other.
	local ax, ay, az
	if math.abs(dy) < 0.9 then
		-- d x up
		ax, ay, az = -dz, 0, dx
	else
		-- d x east
		ax, ay, az = 0, dz, -dy
	end
	local length = math.sqrt(ax * ax + ay * ay + az * az)
	ax, ay, az = ax / length, ay / length, az / length
	local bx, by, bz = dy * az - dz * ay, dz * ax - dx * az, dx * ay - dy * ax
	local radius = math.rad(cone * math.sqrt(math.clamp(u, 0, 1)))
	local angle = 2 * math.pi * v
	local c, s = math.cos(radius), math.sin(radius)
	local ca, sa = math.cos(angle), math.sin(angle)
	local x = c * dx + s * (ca * ax + sa * bx)
	local y = c * dy + s * (ca * ay + sa * by)
	local z = c * dz + s * (ca * az + sa * bz)
	local n = math.sqrt(x * x + y * y + z * z)
	return x / n, y / n, z / n
end

--[[
	The directions of a shot's `count` pellets (1..12) aimed along unit (dx, dy, dz): the shot's
	own direction within `cone` degrees, then each pellet within `pelletCone` of that (a single
	pellet takes the shot's direction). `random` gives numbers in [0, 1).
]]
function Ballistics.pellets(
	dx: number,
	dy: number,
	dz: number,
	cone: number,
	pelletCone: number,
	count: number,
	random: () -> number
): { Vec }
	local n = math.clamp(math.floor(count), 1, 12)
	local bx, by, bz = Ballistics.spreadDir(dx, dy, dz, cone, random(), random())
	local out: { Vec } = table.create(n)
	for i = 1, n do
		if n == 1 or not (pelletCone > 0) then
			out[i] = { x = bx, y = by, z = bz }
		else
			local px, py, pz = Ballistics.spreadDir(bx, by, bz, pelletCone, random(), random())
			out[i] = { x = px, y = py, z = pz }
		end
	end
	return out
end

-- The angle (radians) a shot is lifted above the sight line so its arc crosses it again at
-- `zero` blocks: atan(g x zero / (2 v^2)).
function Ballistics.zeroLift(velocity: number, gravity: number, zero: number): number
	if not (velocity > 0) then
		return 0
	end
	return math.atan(gravity * zero / (2 * velocity * velocity))
end

-- Where a round's flight ends (blocks): its range x 2.5, at most Config.Weapons.MaxRange.
function Ballistics.maxRange(ammo: Weapons.AmmoSpec): number
	return math.min(ammo.range * 2.5, Config.Weapons.MaxRange)
end

-- The damage share left at `distance` (see the header): 1 out to the range, then linearly down to
-- falloffMin at maxRange (and beyond).
function Ballistics.share(ammo: Weapons.AmmoSpec, distance: number): number
	if distance <= ammo.range then
		return 1
	end
	local far = Ballistics.maxRange(ammo)
	if far <= ammo.range or distance >= far then
		return ammo.falloffMin
	end
	local t = (distance - ammo.range) / (far - ammo.range)
	return 1 + (ammo.falloffMin - 1) * t
end

-- `share` for a flight's own numbers (its range, maxRange and falloffMin).
local function falloff(shot: ShotSpec, distance: number): number
	if distance <= shot.range then
		return 1
	end
	local far = shot.maxRange
	if far <= shot.range or distance >= far then
		return shot.falloffMin
	end
	return 1 + (shot.falloffMin - 1) * (distance - shot.range) / (far - shot.range)
end

-- What a head hit on `target` is times (see the header's Damage); `settings` default
-- Config.Weapons.
function Ballistics.headFactor(target: Target, settings: Settings?): number
	local s = settings or Config.Weapons
	if target.kind == "player" then
		return s.PlayerHead
	elseif target.zombie then
		return s.ZombieHead * (if target.helmet then s.HelmetShare else 1)
	end
	return s.MobHead
end

-- The half hearts an impact of `shot` deals before armour: its damage x the impact's share x the
-- head factor on a head hit; 0 for impacts on no target.
function Ballistics.damage(shot: ShotSpec, impact: Impact, settings: Settings?): number
	local target = impact.target
	if target == nil then
		return 0
	end
	local amount = shot.damage * impact.share
	if impact.head then
		amount *= Ballistics.headFactor(target, settings)
	end
	return amount
end

--[[ The flight ]]

--[[
	The velocity (blocks a second) a projectile leaves with along unit (dx, dy, dz): `shot`'s
	velocity, lifted by its zero angle in the vertical plane of the aim (straight up or down is not
	lifted).
]]
function Ballistics.launch(dx: number, dy: number, dz: number, shot: ShotSpec): (number, number, number)
	local v = shot.velocity
	local flat = math.sqrt(dx * dx + dz * dz)
	if flat < 1e-6 then
		return dx * v, dy * v, dz * v
	end
	local pitch = math.atan2(dy, flat) + Ballistics.zeroLift(v, shot.gravity, shot.zero)
	local c = math.cos(pitch)
	return c * dx / flat * v, math.sin(pitch) * v, c * dz / flat * v
end

--[[
	The box a flight from `origin` along unit `dir` stays in until it ends (see the header's
	Bounds): minX, minY, minZ, maxX, maxY, maxZ.
]]
function Ballistics.bounds(origin: Vec, dir: Vec, shot: ShotSpec): (number, number, number, number, number, number)
	local vx, vy, vz = Ballistics.launch(dir.x, dir.y, dir.z, shot)
	local g = shot.gravity
	local px, py, pz = origin.x, origin.y, origin.z
	local minX, minY, minZ, maxX, maxY, maxZ = px, py, pz, px, py, pz
	local travelled, t = 0, 0
	for _ = 1, Ballistics.MAX_SEGMENTS do
		if travelled >= shot.maxRange then
			break
		end
		t += shot.segment
		local qx, qy, qz = origin.x + vx * t, origin.y + vy * t - 0.5 * g * t * t, origin.z + vz * t
		local sx, sy, sz = qx - px, qy - py, qz - pz
		local length = math.sqrt(sx * sx + sy * sy + sz * sz)
		if length < 1e-9 then
			break
		end
		local left = shot.maxRange - travelled
		if length > left then
			local k = left / length
			qx, qy, qz = px + sx * k, py + sy * k, pz + sz * k
			length = left
		end
		minX, minY, minZ = math.min(minX, qx), math.min(minY, qy), math.min(minZ, qz)
		maxX, maxY, maxZ = math.max(maxX, qx), math.max(maxY, qy), math.max(maxZ, qz)
		travelled += length
		px, py, pz = qx, qy, qz
	end
	return minX, minY, minZ, maxX, maxY, maxZ
end

-- (`trace`'s block callbacks read these: one trace at a time, which never yields.)
local AIR = Blocks.AIR
-- What the traversal is told an unloaded cell holds: stops the flight.
local UNLOADED = -1
local traceGet: GetBlock = function(_x: number, _y: number, _z: number): number?
	return nil
end
local traceStops: (id: number) -> boolean = function(_id: number): boolean
	return true
end
local traceOutline: Outline = function(_id: number, _x: number, _y: number, _z: number): { number }?
	return nil
end
local tracePasses: (block: number) -> boolean = function(_block: number): boolean
	return false
end
-- The cells of the panes this flight went through (x, y, z each): air to it from then on.
local passed: { number } = table.create(Ballistics.MAX_PANES * 3, 0)
local passedCount = 0

local function peek(x: number, y: number, z: number): number?
	for i = 1, passedCount * 3, 3 do
		if passed[i] == x and passed[i + 1] == y and passed[i + 2] == z then
			return AIR
		end
	end
	local block = traceGet(x, y, z)
	return if block == nil then UNLOADED else block
end

local function stops(id: number): boolean
	if id == UNLOADED then
		return true
	elseif tracePasses(id) then
		return false
	end
	return traceStops(id)
end

local function outline(id: number, x: number, y: number, z: number): { number }?
	if id == UNLOADED then
		return nil
	end
	return traceOutline(id, x, y, z)
end

-- Does the box overlap the segment's box (minX..maxZ)?
local function overlaps(
	box: Box,
	minX: number,
	minY: number,
	minZ: number,
	maxX: number,
	maxY: number,
	maxZ: number
): boolean
	return box[1] <= maxX and box[4] >= minX and box[2] <= maxY and box[5] >= minY and box[3] <= maxZ and box[6] >= minZ
end

-- Might the segment's box meet the target anywhere it is tested (its boxes, its seen ones)?
local function near(
	target: Target,
	minX: number,
	minY: number,
	minZ: number,
	maxX: number,
	maxY: number,
	maxZ: number
): boolean
	if
		overlaps(target.body, minX, minY, minZ, maxX, maxY, maxZ)
		or overlaps(target.head, minX, minY, minZ, maxX, maxY, maxZ)
	then
		return true
	end
	local seenBody, seenHead = target.seenBody, target.seenHead
	return seenBody ~= nil
		and seenHead ~= nil
		and (
			overlaps(seenBody, minX, minY, minZ, maxX, maxY, maxZ)
			or overlaps(seenHead, minX, minY, minZ, maxX, maxY, maxZ)
		)
end

--[[
	One projectile from `origin` along unit `dir` (its spread already applied): the impacts along
	its flight in order (panes of glass it went through, then where it stopped: a block, a target,
	or "none" where its flight ended or met an unloaded cell). See the header.
]]
function Ballistics.trace(
	getBlock: (x: number, y: number, z: number) -> number?,
	origin: Vec,
	dir: Vec,
	shot: ShotSpec,
	targets: { Target },
	rules: BlockRules
): { Impact }
	local impacts: { Impact } = {}
	traceGet = getBlock
	traceStops, traceOutline = Shapes.sight(getBlock)
	tracePasses = rules.passes
	passedCount = 0
	local shooter = shot.shooter
	local vx, vy, vz = Ballistics.launch(dir.x, dir.y, dir.z, shot)
	local g = shot.gravity
	local px, py, pz = origin.x, origin.y, origin.z
	local ux, uy, uz = dir.x, dir.y, dir.z
	local travelled, t = 0, 0
	local glass = 1
	local ended = false
	for _ = 1, Ballistics.MAX_SEGMENTS do
		if travelled >= shot.maxRange then
			break
		end
		t += shot.segment
		local qx, qy, qz = origin.x + vx * t, origin.y + vy * t - 0.5 * g * t * t, origin.z + vz * t
		local sx, sy, sz = qx - px, qy - py, qz - pz
		local length = math.sqrt(sx * sx + sy * sy + sz * sz)
		if length < 1e-9 then
			break
		end
		local left = shot.maxRange - travelled
		if length > left then
			local k = left / length
			qx, qy, qz = px + sx * k, py + sy * k, pz + sz * k
			sx, sy, sz = qx - px, qy - py, qz - pz
			length = left
		end
		ux, uy, uz = sx / length, sy / length, sz / length
		local minX, minY, minZ = math.min(px, qx), math.min(py, qy), math.min(pz, qz)
		local maxX, maxY, maxZ = math.max(px, qx), math.max(py, qy), math.max(pz, qz)
		-- (Again from the segment's start after each pane: the panes passed read as air.)
		while true do
			local hit = VoxelRaycast.cast(px, py, pz, ux, uy, uz, length, peek, stops, outline)
			local limit = if hit then math.min(hit.distance, length) else length
			local best: number? = nil
			local bestTarget: Target? = nil
			local bestHead = false
			for _, target in targets do
				if target.key ~= shooter and near(target, minX, minY, minZ, maxX, maxY, maxZ) then
					local d, head = Ballistics.hit(target, px, py, pz, ux, uy, uz, if best then best else limit)
					if d ~= nil and (best == nil or d < best) then
						best, bestTarget, bestHead = d, target, head
					end
				end
			end
			if best ~= nil and bestTarget ~= nil then
				local distance = travelled + best
				table.insert(impacts, {
					kind = bestTarget.kind,
					x = px + ux * best,
					y = py + uy * best,
					z = pz + uz * best,
					distance = distance,
					target = bestTarget,
					head = bestHead,
					share = falloff(shot, distance) * glass,
					dx = ux,
					dy = uy,
					dz = uz,
				})
				ended = true
				break
			end
			if hit == nil then
				break
			end
			local d = hit.distance
			local distance = travelled + d
			local x, y, z = px + ux * d, py + uy * d, pz + uz * d
			local block = hit.block
			if block == UNLOADED then
				table.insert(impacts, {
					kind = "none",
					x = x,
					y = y,
					z = z,
					distance = distance,
					head = false,
					share = falloff(shot, distance) * glass,
					dx = ux,
					dy = uy,
					dz = uz,
				})
				ended = true
				break
			end
			local pane = rules.shatter and passedCount < Ballistics.MAX_PANES and rules.isGlass(block)
			table.insert(impacts, {
				kind = if pane then "glass" else "block",
				x = x,
				y = y,
				z = z,
				distance = distance,
				head = false,
				cell = { hit.x, hit.y, hit.z },
				block = block,
				share = falloff(shot, distance) * glass,
				dx = ux,
				dy = uy,
				dz = uz,
			})
			if not pane then
				ended = true
				break
			end
			glass *= rules.glassShare
			local o = passedCount * 3
			passed[o + 1], passed[o + 2], passed[o + 3] = hit.x, hit.y, hit.z
			passedCount += 1
		end
		if ended then
			break
		end
		travelled += length
		px, py, pz = qx, qy, qz
	end
	if not ended then
		table.insert(impacts, {
			kind = "none",
			x = px,
			y = py,
			z = pz,
			distance = travelled,
			head = false,
			share = falloff(shot, travelled) * glass,
			dx = ux,
			dy = uy,
			dz = uz,
		})
	end
	passedCount = 0
	return impacts
end

return Ballistics
