--!strict
--[[
	A shot's flight, pure (server Weapons/ traces every shot with it; the server builder owns it).
	Hitscan along a gravity arc: a bullet leaves the eyes lifted by its gun's zero angle
	(`zeroLift`: the path crosses the sight line at the zero distance), flies at its round's
	velocity under Config.Weapons.Gravity, and is stepped in Config.Weapons.SegmentSeconds of
	flight, each segment a straight ray, until `maxRange` (its round's range x 2.5, at most
	Config.Weapons.MaxRange). Hits resolve at once.

	  Blocks   Shared/World/VoxelRaycast on Shared/Blocks/Shapes.sight's collision boxes (a torch
	           passes, a fence's arms stop it). A block that is not loaded (nil) stops it. Glass
	           (Config.Weapons.ShatterBlocks) shatters when the shooter may build and the bullet
	           goes on with GlassShare of its damage; leaves pass (PassLeaves); anything else stops
	           it (no penetration).
	  Targets  every candidate's body and head boxes (`mobBoxes`, `playerBoxes`; a mob's also where
	           the shooter's client last saw it, within Config.Weapons.LagCompMax), slab-tested
	           along each segment: the nearest hit along the path wins, block or box. A target is
	           hit once a pellet; the shooter is never one.
	  Damage   the round's damage x the gun's scale x `share` (1 out to the round's range, then
	           down to its falloffMin at maxRange) x GlassShare per pane passed; a head hit times
	           ZombieHead (HelmetShare of that under a helmet), MobHead or PlayerHead.
	  Spread   `spreadDir`: uniform over the cone's disc (radius cone x sqrt(u), angle 2 pi v);
	           each pellet takes the shot's direction, then its own pellet cone.

	Boxes are { minX, minY, minZ, maxX, maxY, maxZ } in blocks. Heads (`mobBoxes`): a standing kind
	(1 block tall or more) x/z +- min(width / 2, 0.3), y from eye - 0.22 to max(height, eye + 0.2)
	above the feet (an ordinary zombie's 1.52..1.95); a low kind (the crawler) a 0.5 x 0.4 x 0.5
	head 0.25 blocks forward along its yaw (facing (sin yaw, cos yaw)), 0.2..0.6 up. A player's
	(`playerBoxes`): the body 0.6 wide from the feet to the eyes + 0.2, the head x/z +- 0.25 from
	the eyes - 0.22 to + 0.2 (the pose-aware eyes, server Players/PlayerPositions.eye).

	FOUNDATION lands the types, the boxes, the spread, the zero and the falloff; `trace` is the
	server builder's (until then it hits nothing: {}), with Shared/World/VoxelRaycast and
	Shared/Blocks/Shapes.sight.
]]

local Config = require(script.Parent.Parent.Config)
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
}

local Ballistics = {}

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

--[[ The flight ]]

--[[
	One projectile from `origin` along unit `dir` (its spread already applied): the impacts along
	its flight in order (panes of glass it went through, then where it stopped: a block, a target,
	or "none" at the end of its flight). The server builder's; until then it hits nothing.
]]
function Ballistics.trace(
	_getBlock: (x: number, y: number, z: number) -> number?,
	_origin: Vec,
	_dir: Vec,
	_shot: ShotSpec,
	_targets: { Target },
	_rules: BlockRules
): { Impact }
	return {}
end

return Ballistics
